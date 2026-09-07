#!/bin/bash
set -euo pipefail

# Validates that every agents/*.md and skills/*/SKILL.md has well-formed
# YAML frontmatter with the fields Claude Code actually requires, and
# that they're internally consistent (name matches the filename/directory
# it lives in -- a mismatch here is a real, easy-to-make bug: Claude Code
# resolves an agent/skill by that name, not by its path).

failures=0

fail() {
  echo "FAIL $1: $2" >&2
  failures=$((failures + 1))
}

has_frontmatter() {
  local file="$1"
  [ "$(head -n1 "$file")" = "---" ] && [ "$(grep -c '^---$' "$file")" -ge 2 ]
}

# Prints the value of a single-line "field: value" key inside the
# frontmatter block (between the first and second "---" lines). Empty if
# not present -- multi-line/folded YAML values aren't used anywhere in
# this repo today, so this deliberately doesn't try to handle them.
frontmatter_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    /^---$/ { c++; next }
    c == 1 && $0 ~ "^" field ":" {
      sub("^" field ": *", "")
      print
      exit
    }
    c == 2 { exit }
  ' "$file"
}

check_agent() {
  local file="$1"
  local stem
  stem=$(basename "$file" .md)

  if ! has_frontmatter "$file"; then
    fail "$file" "no closed YAML frontmatter block (must start with --- and have a second --- closing it)"
    return
  fi

  local name description model
  name=$(frontmatter_field "$file" name)
  description=$(frontmatter_field "$file" description)
  model=$(frontmatter_field "$file" model)

  if [ -z "$name" ]; then
    fail "$file" "missing required 'name' field"
  elif [ "$name" != "$stem" ]; then
    fail "$file" "name '$name' does not match filename '$stem.md'"
  fi

  if [ -z "$description" ]; then
    fail "$file" "missing required 'description' field"
  fi

  if [ -z "$model" ]; then
    fail "$file" "missing required 'model' field"
  else
    case "$model" in
      sonnet | opus | haiku | inherit) ;;
      *) fail "$file" "model '$model' is not a recognized alias (sonnet, opus, haiku, inherit)" ;;
    esac
  fi
}

check_skill() {
  local file="$1"
  local dir_name
  dir_name=$(basename "$(dirname "$file")")

  if ! has_frontmatter "$file"; then
    fail "$file" "no closed YAML frontmatter block (must start with --- and have a second --- closing it)"
    return
  fi

  local name description
  name=$(frontmatter_field "$file" name)
  description=$(frontmatter_field "$file" description)

  if [ -z "$name" ]; then
    fail "$file" "missing required 'name' field"
  elif [ "$name" != "$dir_name" ]; then
    fail "$file" "name '$name' does not match parent directory '$dir_name'"
  fi

  if [ -z "$description" ]; then
    fail "$file" "missing required 'description' field"
  fi
}

shopt -s nullglob
for f in agents/*.md; do
  check_agent "$f"
done

for f in skills/*/SKILL.md; do
  check_skill "$f"
done
shopt -u nullglob

if [ "$failures" -gt 0 ]; then
  echo "$failures validation failure(s)" >&2
  exit 1
fi

echo "All agents and skills validated OK"
