#!/bin/bash
# e2e-context-nudge — the UserPromptSubmit context-nudge hook.
#   --self-check   deterministic contract only (no API): hook exists, bash -n,
#                  wired in hooks.json, fail-open on empty stdin.
#   (default/live) live-layer PLACEHOLDER — asserts nothing yet (deepen with a real
#                  `codex exec` run so the hook reads a genuine transcript); SKIP-safe.
#
# Codex has no context-nudge structure test, so the fail-open contract here is the
# primary deterministic coverage for this hook.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$DIR/../../plugins/zensu" && pwd)"
HOOK="$PLUGIN/hooks/user-prompt-context-nudge.sh"
MODE="${1:-}"
PASS=0; FAIL=0
ck() { [ "$2" = PASS ] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }; }

[ -f "$HOOK" ] && ck "hook exists" PASS || ck "hook exists" FAIL
bash -n "$HOOK" 2>/dev/null && ck "bash -n syntax" PASS || ck "bash -n syntax" FAIL
node -e 'const h=require(process.argv[1]);const u=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");process.exit(u.some(c=>/user-prompt-context-nudge\.sh/.test(c))?0:1)' "$PLUGIN/hooks/hooks.json" 2>/dev/null \
  && ck "wired in hooks.json UserPromptSubmit" PASS || ck "wired in hooks.json UserPromptSubmit" FAIL
RC=0; printf '' | bash "$HOOK" >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ck "fail-open on empty stdin (exit 0)" PASS || ck "fail-open on empty stdin (exit 0)" FAIL
RC=0; printf '%s' '{"prompt":"hi"}' | bash "$HOOK" >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ck "fail-open on payload without transcript (exit 0)" PASS || ck "fail-open on payload without transcript (exit 0)" FAIL

if [ "$MODE" != "--self-check" ]; then
  if command -v codex >/dev/null 2>&1 && [ -f "$HOME/.codex/auth.json" ]; then
    echo "  (live: a real 'codex exec' session produces a transcript the hook reads — deepen as needed)"
  else
    echo "  SKIP  live layer — codex CLI or auth unavailable"
  fi
fi

echo "----"; echo "e2e-context-nudge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
