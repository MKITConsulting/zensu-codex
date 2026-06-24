#!/bin/bash
set -u

# Pins the ghost-scan security-classification guidance: classify by the data a
# feature reads/writes (data sensitivity is the rule, path is a weak hint), and
# NEVER default un-triaged code to `internal`. Replaces the old path-bucket
# heuristic that defaulted everything else to internal.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/plugins/zensu/skills/ghost-scan/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL" ]; then
  check "skills/ghost-scan/SKILL.md exists" FAIL
  echo "----"; echo "test-ghost-scan-classification: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "G0 skills/ghost-scan/SKILL.md exists" PASS

grep -qiF "data sensitivity is the rule" "$SKILL" \
  && check "G1 classify by data sensitivity, not path/domain" PASS \
  || check "G1 missing 'data sensitivity is the rule' guidance" FAIL

grep -qiE "never default to .?internal" "$SKILL" \
  && check "G2 forbids defaulting un-triaged code to internal" PASS \
  || check "G2 missing 'never default to internal' rule" FAIL

if grep -qiF "default for all others" "$SKILL"; then
  check "G3 old path-bucket default ('default for all others') removed" FAIL
else
  check "G3 old path-bucket default ('default for all others') removed" PASS
fi

grep -qiE "unsure between .?internal.? and .?confidential.?, choose .?confidential" "$SKILL" \
  && check "G4 ties between internal/confidential resolve to confidential" PASS \
  || check "G4 missing choose-confidential-when-unsure tiebreak" FAIL

for cls in restricted confidential internal public; do
  grep -qE "\`$cls\`" "$SKILL" || { check "G5 all four classes present (missing $cls)" FAIL; CLS_MISS=1; }
done
[ -z "${CLS_MISS:-}" ] && check "G5 all four classes (restricted/confidential/internal/public) documented" PASS

echo "----"
echo "test-ghost-scan-classification: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
