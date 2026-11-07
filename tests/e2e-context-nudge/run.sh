#!/bin/bash
# e2e-context-nudge — the UserPromptSubmit context-nudge hook.
#   --self-check   deterministic contract only (no API): hook exists, bash -n,
#                  wired in hooks.json, fail-open on empty stdin.
#   (default/live) live-layer PLACEHOLDER — prints a NOTE and asserts nothing
#                  (deepen with a real `codex exec` run so the hook reads a
#                  genuine transcript); the NOTE states that no live assertion ran.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$DIR/../../plugins/zensu" && pwd)"
HOOK="$PLUGIN/hooks/user-prompt-context-nudge.sh"
MODE="${1:-}"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

[ -f "$HOOK" ] && check "hook exists" PASS || check "hook exists" FAIL
bash -n "$HOOK" 2>/dev/null && check "bash -n syntax" PASS || check "bash -n syntax" FAIL
node -e 'const h=require(process.argv[1]);const u=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");process.exit(u.some(c=>/user-prompt-context-nudge\.sh/.test(c))?0:1)' "$PLUGIN/hooks/hooks.json" 2>/dev/null \
  && check "wired in hooks.json UserPromptSubmit" PASS || check "wired in hooks.json UserPromptSubmit" FAIL
RC=0; printf '' | bash "$HOOK" >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && check "fail-open on empty stdin (exit 0)" PASS || check "fail-open on empty stdin (exit 0)" FAIL
RC=0; printf '%s' '{"prompt":"hi"}' | bash "$HOOK" >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && check "fail-open on payload without transcript (exit 0)" PASS || check "fail-open on payload without transcript (exit 0)" FAIL

if [ "$MODE" != "--self-check" ]; then
  echo "  NOTE  live layer is a PLACEHOLDER — no live assertions ran; only the"
  echo "        deterministic hook contract above was verified. Deepen with a real"
  echo "        'codex exec' session whose transcript the hook reads."
fi

echo "----"; echo "e2e-context-nudge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
