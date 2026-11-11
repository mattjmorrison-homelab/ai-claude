---
name: ad-reporter-investigate
description: Scheduled (via /schedule) investigation skill that polls graph-ad-reporter for unresolved "I just saw an ad" reports, cross-references Pi-hole's query log to find the candidate domain(s), classifies each as a confirmed ad/tracker, confirmed legit, or ambiguous, and acts accordingly (blocks confirmed ads in Pi-hole and posts to Discord, leaves ambiguous ones for a human). Has zero conversational memory between runs -- every fact needed is either in this file or fetched live each run, never assumed carried over from a prior run.
---

# Investigating and auto-blocking reported ads

`graph-ad-reporter` lets anyone on the LAN hit a button ("I just saw an
ad") that records a report (timestamp, client IP). This skill turns each
report into an automated investigation against Pi-hole's query log,
mirroring the hand-run workflow that proved this out manually: find which
domain(s) the reporting device queried right around the report time,
check whether Pi-hole already blocks them, classify anything uncovered,
and either block it (posting to the `ad-blocked` Discord channel) or flag
it for a human (posting to `ad-suspicious` and leaving the report
unresolved on `/unresolved`).

This skill runs on a schedule with **no memory of previous runs** --
nothing here should ever be "as established last time." Every value
below was verified live against the real backend/Pi-hole on 2026-11-11;
if any of these shapes have since changed, trust what the live API
actually returns over this file.

## Credentials

- `VAULT_ADDR=https://openbao.morrisons.site`
- `ROLE_ID`: the `ad_reporter_skill_role_id` output from `admin-openbao`'s
  Terraform (resource `vault_approle_auth_backend_role.ad_reporter_skill`
  in `approle-ad-reporter-skill.tf`). **Not filled in here** -- get the
  real value with `tofu output -raw ad_reporter_skill_role_id` against
  `admin-openbao`'s state (or read it from the OpenBao UI/API), then bake
  it into this file as a literal. It's non-sensitive on its own (useless
  without the separately-issued `secret_id`), same reasoning as
  `nix-control-plane`'s existing `role_id`.
- `SECRET_ID`: supplied via whatever credential/env mechanism `/schedule`
  exposes to a scheduled run -- set up once when creating the schedule,
  read from there each run, never hardcoded here.

Login and read a Discord webhook URL (same pattern as this homelab's
other AppRole consumer, `nix-control-plane`):

```sh
CLIENT_TOKEN=$(curl -sf -X POST "$VAULT_ADDR/v1/auth/approle/login" \
  -d "{\"role_id\":\"$ROLE_ID\",\"secret_id\":\"$SECRET_ID\"}" \
  | jq -r '.auth.client_token')

CONFIRMED_WEBHOOK=$(curl -sf -H "X-Vault-Token: $CLIENT_TOKEN" \
  "$VAULT_ADDR/v1/kv/data/homelab/service/admin-discord/k8s-ad-reporter/confirmed-webhook-url" \
  | jq -r '.data.data.value')

SUSPICIOUS_WEBHOOK=$(curl -sf -H "X-Vault-Token: $CLIENT_TOKEN" \
  "$VAULT_ADDR/v1/kv/data/homelab/service/admin-discord/k8s-ad-reporter/suspicious-webhook-url" \
  | jq -r '.data.data.value')
```

Pi-hole currently has **no password set** -- `POST /api/auth` with
`{"password": ""}` returns `{"session": {"valid": true, "sid": null, ...}}`.
When `sid` is `null`, every later Pi-hole call below needs no `sid`
header at all. If Pi-hole ever gets a password configured, `sid` will
come back non-null and must be sent as header `sid: <sid>` on every
subsequent Pi-hole request in this run.

## 1. Poll for unresolved reports

Direct to the subgraph, not through the federated router -- one fewer
moving part for an unattended job:

```sh
curl -s -X POST https://graph-ad-reporter.morrisons.site/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ ad { unresolved(since: \"<now minus 1 hour, UTC ISO8601>\") { id timestamp clientIp resolved resolutionNote } } }"}'
```

If the response has no reports, stop -- nothing to do this run.

## 2. Per report, pull the Pi-hole query log

```sh
curl -s "https://pihole.morrisons.site/api/queries?length=500"
```

(increase `length` if a report's time window turns out to need more rows
than this captures -- tune empirically, not fixed in stone)

Response shape (verified live):

```json
{"queries": [
  {"time": 1794357587.747464, "status": "GRAVITY", "domain": "example.com",
   "client": {"ip": "192.168.68.55", "name": null}, ...},
  ...
]}
```

Note the client IP is nested at `client.ip`, not a flat field.

- Keep only queries where `status` is one of `FORWARDED`, `CACHE`,
  `CACHE_STALE` -- these are *allowed* queries. Skip `GRAVITY`,
  `GRAVITY_CNAME`, `SPECIAL_DOMAIN` entirely -- Pi-hole already blocked
  those, nothing to investigate.
- Keep only queries where `client.ip` equals the report's `clientIp`, and
  `time` falls within the report's `timestamp` +/- a few minutes. Both
  `time` (Pi-hole) and `timestamp` (the report) are already UTC -- compare
  them directly, do **not** convert to America/Chicago for this
  comparison (only convert for human-facing display, e.g. a Discord
  message or `/unresolved`'s UI). Start with a +/-3 minute window; widen
  it if real runs show misses.
- Dedupe the surviving `domain` values -- that's the candidate list for
  this report.
- If the candidate list is empty, treat it the same as "confirmed legit,
  no ad domain found" in step 5.

## 3. Check existing coverage per candidate

```sh
curl -s "https://pihole.morrisons.site/api/search/<domain>?n=3&partial=false"
```

Response shape (verified live):

```json
{"search": {"results": {
  "domains": {"exact": 0, "regex": 0},
  "gravity": {"allow": 0, "block": 2},
  "total": 2
}}}
```

Coverage count = `results.domains.exact + results.domains.regex +
results.gravity.block`. Do **not** count `results.gravity.allow` -- that's
an allowlist hit, the opposite of coverage. If the sum is nonzero, this
candidate is already covered: drop it, don't re-block it, don't post
about it.

## 4. Classify each remaining candidate

Exact heuristics -- don't improvise new ones, don't skip the verification
step for anything that isn't an obvious match:

- **Confirmed ad/tracker** if the domain name contains `rtb`, `bid`,
  `trk`/`track`, `imp`/`impr`/`impression`, `ads`/`advertising`, `adtag`
  -- or matches a known ad-tech/CMP vendor (Moloco, Voodoo/
  `voodoo-adn.com`, Nefta, Appalgo, Airflux, Verve Group, CafeMedia,
  StackAdapt, IAB Tech Lab's compliance domain, Usercentrics) -- or
  matches the structural pattern `<word>-<word>-<year>.com` /
  `<word><word><4digits>.com` (e.g. `delta-sugar-2024.com`,
  `paintdream1010.com`) **and** fired in the same burst (same report, same
  time window) as another already-confirmed candidate. A second domain
  matching that shape alone, with no corroborating burst-mate, is
  ambiguous, not confirmed.
- **Confirmed legit** if it's major-brand infra (Apple/Google/Microsoft/
  Meta/Amazon/Cloudflare/GitHub/Mozilla/etc.) or a mobile game publisher's
  own backend (Azur Games, Kwalee, SayGames's core domain) -- **but** a
  narrowly-scoped ad-specific subdomain of such a publisher (e.g.
  `spt.saygames.io`, not all of `saygames.io`) is still blockable on its
  own, separately from the parent domain.
- **Never classify from name alone when it's not obviously one of the
  above** -- do a web search before concluding either way. (`billvicars.com`
  -- a legitimate ASL-learning site whose name pattern-matched nothing
  obviously wrong -- still needed a real lookup to clear. When in doubt,
  search first.)
- Anything not confidently placed in either bucket above is **ambiguous**.

## 5. Act per candidate

- **Confirmed ad**: escape regex metacharacters in the domain, then:

  ```sh
  curl -s -X POST https://pihole.morrisons.site/api/domains/deny/regex \
    -H "Content-Type: application/json" \
    -d '{"domain": ["(\\.|^)<escaped-domain>\\.<tld>$"], "comment": "ad-reporter-investigate: report <id>, <date>", "enabled": true}'
  ```

  Post one message to the confirmed-ad webhook (domain, which report
  triggered it, why it was classified as an ad). Then:

  ```sh
  curl -s -X POST https://graph-ad-reporter.morrisons.site/graphql \
    -H "Content-Type: application/json" \
    -d '{"query":"mutation { ad { resolve(id: \"<id>\", resolutionNote: \"<domain> blocked\") { id resolved } } }"}'
  ```

- **Confirmed legit, no ad domain found anywhere in this report's whole
  candidate set**:

  ```sh
  curl -s -X POST https://graph-ad-reporter.morrisons.site/graphql \
    -H "Content-Type: application/json" \
    -d '{"query":"mutation { ad { resolve(id: \"<id>\", resolutionNote: \"no ad domain found; candidates confirmed legit\") { id resolved } } }"}'
  ```

- **Ambiguous**: post one summary message to the suspicious webhook
  (domain, reasoning, report id). **Do not call `resolve`** --
  leave `resolved: false`. This is deliberate: the report ages out of the
  next run's `since: now-1h` window and becomes a standing item on
  `/unresolved` for a human, instead of retrying forever.

Discord webhook posts use the standard webhook POST shape:

```sh
curl -s -X POST "$CONFIRMED_WEBHOOK" -H "Content-Type: application/json" \
  -d '{"content": "<message text>"}'
```
