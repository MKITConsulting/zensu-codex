#!/bin/bash
set -u

# Pins the per-key DEEP MERGE of global (~/.zensu/config.json) under project
# ($CLAUDE_PROJECT_DIR/.zensu/config.json): the project overlay wins per key, but
# keys it omits fall through to global instead of shadowing the whole global file
# (the pre-fix first-match behavior). ZENSU_CONFIG stays a verbatim escape hatch.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CFG="$ROOT/plugins/zensu/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$CFG" ]; then
  check "hooks/lib/zensu-config.sh exists" FAIL
  echo "----"; echo "test-config-merge: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "M0 hooks/lib/zensu-config.sh exists" PASS
bash -n "$CFG" 2>/dev/null && check "M0a bash -n syntax check" PASS || check "M0a bash -n syntax check" FAIL

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
g() { env -u ZENSU_CONFIG HOME="$1" CLAUDE_PROJECT_DIR="$2" bash -c "source '$CFG'; $3" 2>/dev/null; }

# M1 — disjoint keys: global autoTdd=false + project combinedSummary=false → BOTH honored.
HG1="$TMP/h1"; mkdir -p "$HG1/.zensu"; printf '%s' '{"hooks":{"autoTdd":false}}' > "$HG1/.zensu/config.json"
PJ1="$TMP/p1"; mkdir -p "$PJ1/.zensu"; printf '%s' '{"hooks":{"combinedSummary":false}}' > "$PJ1/.zensu/config.json"
A1=$(g "$HG1" "$PJ1" 'zensu_hook_enabled autoTdd && echo EN || echo DIS')
B1=$(g "$HG1" "$PJ1" 'zensu_combined_summary_enabled && echo EN || echo DIS')
[ "$A1" = "DIS" ] && check "M1 global hooks.autoTdd=false survives project overlay (not shadowed)" PASS || check "M1 global key survival (autoTdd got '$A1' expected DIS)" FAIL
[ "$B1" = "DIS" ] && check "M1b project hooks.combinedSummary=false applies" PASS || check "M1b project key (combinedSummary got '$B1' expected DIS)" FAIL

# M2 — same key in both: project value wins.
HG2="$TMP/h2"; mkdir -p "$HG2/.zensu"; printf '%s' '{"hooks":{"autoFixMaxRounds":3}}' > "$HG2/.zensu/config.json"
PJ2="$TMP/p2"; mkdir -p "$PJ2/.zensu"; printf '%s' '{"hooks":{"autoFixMaxRounds":7}}' > "$PJ2/.zensu/config.json"
A2=$(g "$HG2" "$PJ2" 'zensu_autofix_max_rounds')
[ "$A2" = "7" ] && check "M2 same key -> project value wins (autoFixMaxRounds=7)" PASS || check "M2 project override (got '$A2' expected 7)" FAIL

# M3 — nested fall-through: global sets two hook keys, project overrides only one.
HG3="$TMP/h3"; mkdir -p "$HG3/.zensu"; printf '%s' '{"hooks":{"autoTdd":false,"chainEnforcer":false}}' > "$HG3/.zensu/config.json"
PJ3="$TMP/p3"; mkdir -p "$PJ3/.zensu"; printf '%s' '{"hooks":{"autoTdd":true}}' > "$PJ3/.zensu/config.json"
A3=$(g "$HG3" "$PJ3" 'zensu_hook_enabled chainEnforcer && echo EN || echo DIS')
B3=$(g "$HG3" "$PJ3" 'zensu_hook_enabled autoTdd && echo EN || echo DIS')
[ "$A3" = "DIS" ] && check "M3 global hooks.chainEnforcer=false survives when project overrides only hooks.autoTdd" PASS || check "M3 nested fall-through (chainEnforcer got '$A3' expected DIS — first-match shadowing)" FAIL
[ "$B3" = "EN" ] && check "M3b project hooks.autoTdd=true overrides global false" PASS || check "M3b project override (autoTdd got '$B3' expected EN)" FAIL

# M4 — malformed project file degrades to global (does NOT blank it).
HG4="$TMP/h4"; mkdir -p "$HG4/.zensu"; printf '%s' '{"hooks":{"autoTdd":false}}' > "$HG4/.zensu/config.json"
PJ4="$TMP/p4"; mkdir -p "$PJ4/.zensu"; printf '%s' '{bad json not parseable' > "$PJ4/.zensu/config.json"
A4=$(g "$HG4" "$PJ4" 'zensu_hook_enabled autoTdd && echo EN || echo DIS')
[ "$A4" = "DIS" ] && check "M4 malformed project file -> degrades to global (autoTdd stays false)" PASS || check "M4 malformed-degrades (autoTdd got '$A4' expected DIS — broke global)" FAIL

# M5 — ZENSU_CONFIG escape hatch used verbatim (NOT merged).
EC="$TMP/escape.json"; printf '%s' '{"hooks":{"autoTdd":false}}' > "$EC"
A5=$(env HOME="$TMP/none" CLAUDE_PROJECT_DIR="$TMP/none" ZENSU_CONFIG="$EC" bash -c "source '$CFG'; zensu_hook_enabled autoTdd && echo EN || echo DIS" 2>/dev/null)
[ "$A5" = "DIS" ] && check "M5 ZENSU_CONFIG verbatim escape hatch honored" PASS || check "M5 ZENSU_CONFIG (autoTdd got '$A5' expected DIS)" FAIL

# M6 — prototype-pollution guard: a __proto__ key neither crashes nor blocks the sibling real key.
grep -q '__proto__' "$CFG" && check "M6 source carries a __proto__/constructor/prototype merge guard" PASS || check "M6 missing prototype-pollution guard in source" FAIL
HG6="$TMP/h6"; mkdir -p "$HG6/.zensu"; printf '%s' '{}' > "$HG6/.zensu/config.json"
PJ6="$TMP/p6"; mkdir -p "$PJ6/.zensu"; printf '%s' '{"__proto__":{"polluted":1},"hooks":{"autoTdd":false}}' > "$PJ6/.zensu/config.json"
A6=$(g "$HG6" "$PJ6" 'zensu_hook_enabled autoTdd && echo EN || echo DIS')
[ "$A6" = "DIS" ] && check "M6b __proto__-bearing config still merges its real sibling key (autoTdd=false)" PASS || check "M6b __proto__ config (autoTdd got '$A6' expected DIS)" FAIL
J6=$(g "$HG6" "$PJ6" '_zensu_config_json')
printf '%s' "$J6" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{JSON.parse(s);process.exit(({}).polluted===undefined?0:1)}catch(_){process.exit(1)}})' \
  && check "M6c effective config emits valid JSON and Object.prototype stays unpolluted" PASS || check "M6c proto pollution / invalid JSON (got '$J6')" FAIL

# M7 — no config files anywhere -> hardcoded defaults unchanged.
A7=$(g "$TMP/empty" "$TMP/empty" 'zensu_autofix_max_rounds')
B7=$(g "$TMP/empty" "$TMP/empty" 'zensu_hook_enabled autoTdd && echo EN || echo DIS')
[ "$A7" = "5" ] && check "M7 no-config -> autoFixMaxRounds default 5" PASS || check "M7 default rounds (got '$A7' expected 5)" FAIL
[ "$B7" = "EN" ] && check "M7b no-config -> hooks enabled by default" PASS || check "M7b default enabled (autoTdd got '$B7' expected EN)" FAIL

echo "----"
echo "test-config-merge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
