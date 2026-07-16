#!/usr/bin/env bash
# Build an isolated marketplace-style plugin artifact and validate $zensu-help
# without access to repository-parent documentation.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PLUGIN="$ROOT/plugins/zensu"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALLED_PLUGIN="$TMP/marketplace/cache/zensu/zensu/test"
mkdir -p "$INSTALLED_PLUGIN"
cp -R "$SOURCE_PLUGIN/." "$INSTALLED_PLUGIN/"

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
  if [ -f "$INSTALLED_PLUGIN/$doc" ] \
    && [ ! -L "$INSTALLED_PLUGIN/$doc" ] \
    && cmp -s "$ROOT/$doc" "$INSTALLED_PLUGIN/$doc"; then
    ok "isolated install contains exact $doc"
  else
    bad "isolated install lacks an exact regular $doc"
  fi
done

HELP="$INSTALLED_PLUGIN/skills/zensu-help/SKILL.md"
if [ -f "$HELP" ]; then
  ok "isolated install contains zensu-help"
else
  bad "isolated install lacks zensu-help"
fi

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
  ok "isolated zensu-help exposes $ROUTE_COUNT concrete local source routes"
else
  bad "isolated zensu-help route extraction found only $ROUTE_COUNT concrete sources"
fi

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    /*|*'..'*)
      bad "isolated route escapes the installed plugin root: $ref"
      continue
      ;;
  esac
  if [ -f "$INSTALLED_PLUGIN/$ref" ] && [ ! -L "$INSTALLED_PLUGIN/$ref" ]; then
    ok "isolated routed source exists: $ref"
  else
    bad "isolated routed source missing: $ref"
  fi
done <<EOF
$ROUTED
EOF

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
