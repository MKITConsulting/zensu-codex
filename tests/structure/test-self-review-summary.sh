#!/bin/bash
set -u

# Pins the terminal CHAIN-END SUMMARY rendered by $zensu-self-review: narrative
# form, the auto-fix history enumerates EVERY review round (incl. no-op rounds),
# and the one-sentence TL;DR is the LAST section. Codex subagent naming
# (zensu-code-reviewer, not zensu:code-reviewer).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/plugins/zensu/skills/self-review/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL" ]; then
  check "skills/self-review/SKILL.md exists" FAIL
  echo "----"; echo "test-self-review-summary: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "S0 skills/self-review/SKILL.md exists" PASS

grep -qiF "narrative form" "$SKILL" \
  && check "S1 CHAIN-END SUMMARY rendered in narrative form" PASS \
  || check "S1 missing 'narrative form' framing" FAIL

grep -qiE "TL;DR comes LAST|it is the last section" "$SKILL" \
  && check "S2 TL;DR ordered LAST" PASS \
  || check "S2 missing TL;DR-last ordering" FAIL

grep -qF '## TL;DR' "$SKILL" \
  && check "S3 has a ## TL;DR section" PASS \
  || check "S3 missing ## TL;DR section" FAIL

grep -qiE "EVERY code-review round" "$SKILL" \
  && check "S4 auto-fix history lists EVERY review round 1..N (incl. no-op)" PASS \
  || check "S4 auto-fix history does not enumerate every round" FAIL

if grep -qF '## Problem' "$SKILL" && grep -qF '## Open' "$SKILL"; then
  check "S5 narrative sections (## Problem … ## Open) present" PASS
else
  check "S5 missing narrative ## Problem / ## Open sections" FAIL
fi

if grep -qF 'zensu:code-reviewer' "$SKILL"; then
  check "S6 uses Codex subagent naming (no 'zensu:code-reviewer' colon form)" FAIL
else
  check "S6 uses Codex subagent naming (no 'zensu:code-reviewer' colon form)" PASS
fi

echo "----"
echo "test-self-review-summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
