#!/bin/bash
# e2e-intent-router — the UserPromptSubmit intent-router hook.
#   --self-check   deterministic contract only (no API): hook exists, bash -n,
#                  wired in hooks.json, fail-open on empty stdin.
#   (default/live) live-layer PLACEHOLDER — prints a NOTE and asserts nothing
#                  (deepen with a real `codex exec` run + a hook-log assertion);
#                  never a false green: the NOTE states that no live assertion ran.
#
# The rich deterministic routing assertions (planning payload -> triage/zensu-plm
# signal; non-planning -> silent) live in tests/structure/test-intent-router-hook.sh
# and run in the default (no-arg) suite; this harness adds the wiring + live layer.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$DIR/../../plugins/zensu" && pwd)"
HOOK="$PLUGIN/hooks/user-prompt-intent-router.sh"
MODE="${1:-}"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

[ -f "$HOOK" ] && check "hook exists" PASS || check "hook exists" FAIL
bash -n "$HOOK" 2>/dev/null && check "bash -n syntax" PASS || check "bash -n syntax" FAIL
node -e 'const h=require(process.argv[1]);const u=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");process.exit(u.some(c=>/user-prompt-intent-router\.sh/.test(c))?0:1)' "$PLUGIN/hooks/hooks.json" 2>/dev/null \
  && check "wired in hooks.json UserPromptSubmit" PASS || check "wired in hooks.json UserPromptSubmit" FAIL
OUT="$(printf '' | bash "$HOOK" 2>/dev/null)"; RC=$?
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && check "fail-open on empty stdin (exit 0, silent)" PASS || check "fail-open on empty stdin" FAIL

if [ "$MODE" != "--self-check" ]; then
  echo "  NOTE  live layer is a PLACEHOLDER — no live assertions ran; only the"
  echo "        deterministic hook contract above was verified. Deepen with a real"
  echo "        'codex exec' planning prompt + a hook-log assertion."
fi

echo "----"; echo "e2e-intent-router: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
