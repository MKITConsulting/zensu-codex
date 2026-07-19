#!/usr/bin/env bash
# The distributable plugin must carry every concrete local source routed by
# $zensu-help. Repository-level documentation is not available from an
# installed marketplace plugin root.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_ROOT="$ROOT/plugins/zensu"
HELP="$PLUGIN_ROOT/skills/zensu-help/SKILL.md"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$*"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$*"
}

for doc in README.md CHANGELOG.md LICENSE; do
  if [ -f "$PLUGIN_ROOT/$doc" ] && [ ! -L "$PLUGIN_ROOT/$doc" ]; then
    ok "plugin carries regular $doc"
  else
    bad "plugin $doc is missing or is not a regular packaged file"
    continue
  fi

  if cmp -s "$ROOT/$doc" "$PLUGIN_ROOT/$doc"; then
    ok "plugin $doc is byte-identical to repository $doc"
  else
    bad "plugin $doc drifted from repository $doc"
  fi
done

ROUTED="$(
  sed -n '/^## Topic Routing/,/^## Response Style/p' "$HELP" \
    | grep -oE '`[^`]+`' \
    | tr -d '`' \
    | grep -E '^(LICENSE|[^[:space:]]+\.(md|json|js|cjs|mjs|sh|toml|yaml|yml))$' \
    | grep -v '[<>]' \
    | sort -u
)"

ROUTE_COUNT="$(printf '%s\n' "$ROUTED" | grep -c . || true)"
if [ "$ROUTE_COUNT" -ge 14 ]; then
  ok "zensu-help exposes $ROUTE_COUNT concrete local source routes"
else
  bad "zensu-help route extraction found only $ROUTE_COUNT concrete sources"
fi

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*'..'*)
      bad "zensu-help route escapes the plugin root: $ref"
      continue
      ;;
  esac
  if [ -f "$PLUGIN_ROOT/$ref" ] && [ ! -L "$PLUGIN_ROOT/$ref" ]; then
    ok "zensu-help source is packaged: $ref"
  else
    bad "zensu-help source missing from plugin root: $ref"
  fi
done <<EOF
$ROUTED
EOF

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
