#!/bin/bash
# evals/tdd/run.sh — reference-eval bridge for tests/run-all.sh.
#   --self-check   deterministic (no API): validate config + fixture + wrapper wiring
#   (default/live) run promptfoo against the codex-exec wrapper (COSTS API CREDITS,
#                  needs an authenticated codex CLI)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-}"
PASS=0; FAIL=0
ck() { [ "$2" = PASS ] && { echo "  PASS  $1"; PASS=$((PASS+1)); } || { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }; }

[ -f "$DIR/promptfooconfig.yaml" ] && ck "promptfooconfig.yaml present" PASS || ck "promptfooconfig.yaml present" FAIL
[ -f "$DIR/scenarios/tdd-happy.yaml" ] && ck "scenario present" PASS || ck "scenario present" FAIL
[ -d "$DIR/test-projects/add-feature" ] && ck "fixture present" PASS || ck "fixture present" FAIL
[ -x "$DIR/../../scripts/codex-promptfoo-wrapper.sh" ] && ck "codex wrapper executable" PASS || ck "codex wrapper executable" FAIL
grep -qF 'codex-promptfoo-wrapper.sh' "$DIR/promptfooconfig.yaml" && ck "config wires the codex wrapper" PASS || ck "config wires the codex wrapper" FAIL

if [ "$MODE" != "--self-check" ]; then
  ROOT="$(cd "$DIR/../.." && pwd)"
  PF=""
  if [ -x "$ROOT/node_modules/.bin/promptfoo" ]; then PF="$ROOT/node_modules/.bin/promptfoo"
  elif command -v promptfoo >/dev/null 2>&1; then PF="promptfoo"
  elif command -v npx >/dev/null 2>&1 && npx --no-install promptfoo --version >/dev/null 2>&1; then PF="npx --no-install promptfoo"
  fi
  MISSING=""
  command -v codex >/dev/null 2>&1 || MISSING="$MISSING codex-cli"
  [ -f "$HOME/.codex/auth.json" ] || MISSING="$MISSING codex-auth"
  [ -n "$PF" ] || MISSING="$MISSING promptfoo"
  if [ -z "$MISSING" ]; then
    echo "  running $PF eval (live, API)…"
    ( cd "$DIR" && $PF eval -c promptfooconfig.yaml ) && ck "promptfoo eval passed" PASS || ck "promptfoo eval passed" FAIL
  else
    ck "live prerequisites present (missing:$MISSING) — a live dispatch must not green-wash" FAIL
  fi
fi

echo "----"; echo "evals/tdd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
