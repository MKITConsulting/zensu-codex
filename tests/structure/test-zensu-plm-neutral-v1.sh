#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
AGENT="$PLUGIN/agents/zensu-plm.toml"
REFERENCE="$ROOT/reference/zensu-plm.md"
ROUTER="$PLUGIN/hooks/user-prompt-intent-router.sh"
HELP="$PLUGIN/skills/zensu-help/SKILL.md"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

for file in "$AGENT" "$REFERENCE" "$ROUTER" "$HELP"; do
  [ -s "$file" ] && check "artifact exists: ${file#"$ROOT/"}" PASS || check "artifact exists: ${file#"$ROOT/"}" FAIL
done

grep -qF 'neutral `host-profile-v1` subagent' "$AGENT" \
  && grep -qF 'Never execute a Zensu' "$AGENT" \
  && grep -qF 'exact skill name to invoke next' "$AGENT" \
  && check "installed PLM is an explicit read-only neutral analyst" PASS \
  || check "installed PLM neutral capability contract" FAIL

grep -qF 'neutral `host-profile-v1` subagent' "$REFERENCE" \
  && grep -qF 'Never execute a Zensu' "$REFERENCE" \
  && grep -qF 'exact skill name to invoke next' "$REFERENCE" \
  && check "canonical PLM reference mirrors the neutral contract" PASS \
  || check "canonical PLM neutral capability contract" FAIL

if grep -Eq 'ALWAYS delegate|orchestrates product lifecycle workflows using the Zensu CLI' "$AGENT" "$REFERENCE"; then
  check "PLM contains no mutation-orchestration instruction" FAIL
else
  check "PLM contains no mutation-orchestration instruction" PASS
fi

grep -qF 'Invoke the matching skill yourself; never delegate mutations to zensu-plm' "$ROUTER" \
  && check "intent router keeps mutations in the top-level thread" PASS \
  || check "intent router main-thread mutation routing" FAIL

grep -qF 'optional read-only planning analyst' "$HELP" \
  && grep -qF 'never performs mutations' "$HELP" \
  && check "zensu-help describes PLM as read-only" PASS \
  || check "zensu-help PLM capability description" FAIL

printf '%s\n' '----' "test-zensu-plm-neutral-v1: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
