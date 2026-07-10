#!/bin/bash
# e2e-intent-router — the UserPromptSubmit intent-router hook.
#   --self-check   deterministic contract only (no API): hook exists, bash -n,
#                  wired in hooks.json, fail-open on empty stdin.
#   (default/live) live-layer PLACEHOLDER — asserts nothing yet (deepen with a real
#                  `codex exec` run + a hook-log assertion); SKIP-safe, never a false green.
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
ck() { [ "$2" = PASS ] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }; }

[ -f "$HOOK" ] && ck "hook exists" PASS || ck "hook exists" FAIL
bash -n "$HOOK" 2>/dev/null && ck "bash -n syntax" PASS || ck "bash -n syntax" FAIL
node -e 'const h=require(process.argv[1]);const u=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");process.exit(u.some(c=>/user-prompt-intent-router\.sh/.test(c))?0:1)' "$PLUGIN/hooks/hooks.json" 2>/dev/null \
  && ck "wired in hooks.json UserPromptSubmit" PASS || ck "wired in hooks.json UserPromptSubmit" FAIL
OUT="$(printf '' | bash "$HOOK" 2>/dev/null)"; RC=$?
{ [ "$RC" = 0 ] && [ -z "$OUT" ]; } && ck "fail-open on empty stdin (exit 0, silent)" PASS || ck "fail-open on empty stdin" FAIL

if [ "$MODE" != "--self-check" ]; then
  if command -v codex >/dev/null 2>&1 && [ -f "$HOME/.codex/auth.json" ]; then
    echo "  (live: a planning prompt through 'codex exec' should reach the intent-router — deepen as needed)"
  else
    echo "  SKIP  live layer — codex CLI or auth unavailable"
  fi
fi

echo "----"; echo "e2e-intent-router: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
