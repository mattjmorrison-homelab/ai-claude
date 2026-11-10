---
name: homelab-add-app
description: Use this skill whenever the user wants to add a new service/app to their k3s homelab cluster, deploy something new via ArgoCD, or create a new `k8s-<service>` repo. Covers the full checklist beyond just writing Kubernetes manifests — OpenBao secrets wiring, Pi-hole local DNS so the new hostname actually resolves on the LAN, the homepage dashboard entry, and the ArgoCD Application registration in k8s-apps. Trigger on phrases like "add X to the cluster", "deploy a new service", "set up k8s-X", "get X running in k3s" — even if the user only explicitly asks for the Kubernetes manifests, since the DNS and homepage steps are easy to forget and have already caused a real, confusing bug in this homelab.
---

# Adding a new app to the homelab k3s cluster

This homelab runs everything through ArgoCD, with one `k8s-<service>` repo
per app and a central `k8s-apps` repo holding the ArgoCD Application
manifests. Writing the Kubernetes manifests is only part of getting a new app
live — three other repos need updating too, and skipping any of them produces
confusing symptoms rather than an obvious error. For example: forgetting the
Pi-hole entry doesn't cause a Kubernetes error at all — the app deploys fine,
but the browser shows a Cloudflare timeout page, because DNS falls through to
the public internet instead of resolving locally. That's a real bug this
exact workflow already produced once.

## Checklist

For a new service called `<app>` in namespace `<app>`:

### 1. `k8s-<app>` repo — the manifests

- `manifests/namespace.yaml` — dedicated namespace matching the app name
  (this homelab's convention: one namespace per standalone service, not a
  shared one, unless the app naturally belongs to an existing group like
  `monitoring`)
- `manifests/deployment.yaml`, `service.yaml`, plus any `configmap.yaml` /
  `pvc.yaml` the app needs
- `manifests/ingress.yaml` — host `<app>.morrisons.site`, `ingressClassName:
  traefik`. No TLS block needed — `k8s-cert-manager-config` installs a
  cluster-wide wildcard `*.morrisons.site` cert as Traefik's default, so
  every ingress picks it up automatically.
- If the app needs credentials, don't hardcode them into any manifest — these
  repos are public. Follow the OpenBao pattern below instead.

### 2. OpenBao secrets — skip entirely if the app needs none

- `manifests/serviceaccount.yaml` — ServiceAccount named `<app>`
- `manifests/secret-store.yaml` — SecretStore named `openbao`, Vault provider
  pointed at `http://k8s-openbao.openbao.svc:8200`, kv v2, Kubernetes
  auth role `<app>`
- `manifests/external-secret.yaml` — pulls from `kv/homelab/<app>` into a k8s
  Secret the Deployment references
- The OpenBao-side setup (creating the policy + Kubernetes auth role bound to
  the `<app>` ServiceAccount/namespace, and populating the actual secret
  values) is manual, out-of-band, and can't be done by Claude. Tell the user
  exactly what's needed, and if they're tracking this work in a TODO file,
  add it there rather than only saying it in chat.
- If the app needs a *standalone* credential (a bearer token an application
  uses directly, not read via a ServiceAccount) consider whether a small
  bootstrap Job (ArgoCD `PreSync` hook) can mint and store it automatically
  instead of asking the user to click through OpenBao's UI by hand — see
  `k8s-cloudflare`'s or `homelab-woodpecker`'s bootstrap Job for the
  pattern. Automating a manual step is worth the extra complexity when the
  step would otherwise recur or be error-prone to do by hand.
- **If you add a bootstrap Job as a `PreSync` hook, every resource it
  depends on (its ServiceAccount, any ConfigMap it mounts, any
  SecretStore/ExternalSecret feeding it env vars) must ALSO be annotated as
  a `PreSync` hook with a lower `sync-wave` than the Job.** ArgoCD applies
  hooks before regular (non-hook) resources — a ServiceAccount or ConfigMap
  with no hook annotation won't exist yet when a `PreSync` Job tries to use
  it, even though it'd apply fine as part of the normal Sync phase. This
  already caused a real, hard-to-diagnose stuck deploy (the error looked
  like a missing resource, but the actual manifest was correct — it just
  hadn't been created yet). Give the Job's own dependencies waves like
  `-3`, `-2`, `-1` and the Job itself `0`.
- **Also set `hook-delete-policy: BeforeHookCreation,HookSucceeded`** (not
  just `HookSucceeded`) on any hook Job. `HookSucceeded` alone only deletes
  the Job after it succeeds — if it fails, the stale failed Job sticks
  around and blocks all future retries (Jobs are largely immutable, so
  ArgoCD can't just reapply a fresh attempt over it). `BeforeHookCreation`
  makes ArgoCD delete the previous hook resource right before creating a
  new one on every sync, so a failed attempt doesn't require manually
  clearing a stuck finalizer to unblock.
- **Don't assume `:latest` exists.** Some projects (Woodpecker's images,
  for one) have dropped the `latest` tag entirely and ship an image that
  intentionally exits with an error message instead of running, to avoid
  accidental major-version upgrades. Check the project's actual tagging
  scheme rather than defaulting to `:latest` for anything unfamiliar.

### 3. `admin-network` — local DNS (easy to forget)

- Add `<app>.morrisons.site` to the `ingressHosts` list in
  `ingress-hosts.yaml`, matching the existing entries. Don't edit
  `k8s-pihole` directly for this — `admin-network/ingress-hosts.yaml` is
  the single source of truth for `*.morrisons.site` ingress hostnames.
  `k8s-pihole` consumes this file as a shared ArgoCD multi-source values
  file and turns each entry into a static DNS record pointed at
  `piholeAddress` (from `admin-network/local-hosts.yaml`) automatically —
  pushing the change to `admin-network` is enough; no manual trigger or
  edit in `k8s-pihole` itself is needed.
- Why this matters: `morrisons.site` DNS is hosted on Cloudflare, and any
  request that doesn't hit this local override falls through to the public
  internet. Since there's no Cloudflare Tunnel or port-forward reachability
  yet (the homelab is behind CGNAT), the result is a Cloudflare-branded
  timeout page in the browser — which looks like an app or network problem
  but is actually just a missing DNS entry.

### 4. `k8s-homepage` — dashboard entry

- Add an entry to `manifests/configmap.yaml`'s `services.yaml`, under
  whichever group fits (`Infrastructure`, `Monitoring`, `Home`, or a new
  group if none fit) — `href: https://<app>.morrisons.site`, an `icon:`
  guessed from the dashboard-icons naming convention (`<tool-name>.png`;
  fine if the guess doesn't resolve, it just shows a blank icon), and a
  one-line `description`.

### 5. `k8s-apps` — register the ArgoCD Application

- Add `k8s-<app>.yaml`: `metadata.name: k8s-<app>`,
  `spec.source.repoURL` pointing at
  `https://github.com/mattjmorrison-homelab/k8s-<app>`, `path: manifests`,
  `destination.namespace: <app>`, `syncPolicy.automated` with `prune: true`
  / `selfHeal: true` — matches every other app in this repo.
- **If the new app's own repo hasn't been pushed to GitHub yet, don't
  include its Application manifest in the same `k8s-apps` push.** ArgoCD
  will try to sync a repo that doesn't exist yet and fire the
  `ArgoCDAppMissing` Discord alert. Hold it back until both are ready to go
  out together.

## What NOT to do

- Never commit or push any of these repos — per this user's standing
  instruction, they always do that themselves. Leave changes staged locally
  for review.
- Never put real secret values in any manifest — OpenBao is the only source
  of truth for those, populated by the user out-of-band.
- Don't skip steps 3 and 4 just because the user only asked for "the
  manifests." This skill exists specifically so it triggers even on a
  narrower-sounding request, because the DNS and homepage steps are the ones
  that are easy to silently miss.

## After the checklist

Summarize what was created/changed across which repos, call out anything
that still needs manual action (OpenBao policy/role creation, external
OAuth apps, account IDs, etc. — whatever's specific to this app), and if the
user has a TODO file for the current work, offer to add those manual items
to it rather than leaving them only in the conversation.
