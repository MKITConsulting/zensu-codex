#!/usr/bin/env bash
# The version invariant (guards against manifest/README/CHANGELOG version drift):
# plugins/zensu/.codex-plugin/plugin.json version == README badge == newest
# CHANGELOG heading, all in the same commit. Machine-enforced here, used by
# .github/workflows/release.yml. The Codex marketplace descriptor pins its
# source ref to the matching immutable release tag, so that ref is part of the
# same invariant.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

MANIFEST="$ROOT/plugins/zensu/.codex-plugin/plugin.json"
V="$(node -e 'process.stdout.write(String(require(process.argv[1]).version || ""))' "$MANIFEST" 2>/dev/null)"
printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && ok "plugin.json version is semver ($V)" || bad "plugin.json version malformed: '$V'"

MARKET_REF="$(jq -r '.plugins[0].source.ref // ""' "$ROOT/.agents/plugins/marketplace.json" 2>/dev/null)"
[ "$MARKET_REF" = "v$V" ] && ok "marketplace source ref == v$V" || bad "marketplace source ref '$MARKET_REF' != 'v$V'"

if [ -f "$ROOT/README.md" ]; then
  grep -qE "badge/version-$V-" "$ROOT/README.md" && ok "README badge carries $V" || bad "README badge does not carry $V"
else
  bad "README.md missing"
fi

if [ -f "$ROOT/CHANGELOG.md" ]; then
  CL="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | tr -d '#[] ')"
  [ "$CL" = "$V" ] && ok "newest CHANGELOG heading == $V" || bad "CHANGELOG newest '$CL' != '$V'"
else
  bad "CHANGELOG.md missing"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
