#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

node "$ROOT/scripts/create-local-codex-marketplace.js" "$ROOT" "$TMP/market" >/dev/null
MARKET="$TMP/market/.agents/plugins/marketplace.json"
if jq -e '.name == "zensu" and .plugins[0].source == {source:"local",path:"./plugins/zensu"}' "$MARKET" >/dev/null \
  && cmp -s "$ROOT/plugins/zensu/.codex-plugin/plugin.json" "$TMP/market/plugins/zensu/.codex-plugin/plugin.json"; then
  check "local eval marketplace copies exact checkout bytes behind a local source" PASS
else
  check "local eval marketplace copies exact checkout bytes behind a local source" FAIL
fi

VERSION="$(jq -r .version "$ROOT/plugins/zensu/.codex-plugin/plugin.json")"
if jq -e --arg ref "v$VERSION" \
  '.plugins[0].source.source == "git-subdir" and .plugins[0].source.ref == $ref' \
  "$ROOT/.agents/plugins/marketplace.json" >/dev/null; then
  check "production marketplace remains pinned to the immutable current release tag" PASS
else
  check "production marketplace remains pinned to the immutable current release tag" FAIL
fi

if node "$ROOT/scripts/create-local-codex-marketplace.js" "$ROOT" "$TMP/market" >/dev/null 2>&1; then
  check "fixture generator refuses a non-empty destination" FAIL
else
  check "fixture generator refuses a non-empty destination" PASS
fi

echo "----"
echo "test-local-marketplace-fixture: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
