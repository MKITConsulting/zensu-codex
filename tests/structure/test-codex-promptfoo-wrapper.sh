#!/bin/bash
set -u

# Structure test for scripts/codex-promptfoo-wrapper.sh — the promptfoo `exec:`
# provider that bridges to `codex exec`. Fully deterministic: exercises DRY_RUN=1
# (which needs neither the codex CLI nor an API key) to pin the command shape, plus
# source-grep pins for the jq guard and the engine-agnostic state-extraction block.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W="$ROOT/scripts/codex-promptfoo-wrapper.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$W" ]; then
  check "scripts/codex-promptfoo-wrapper.sh exists" FAIL
  echo "----"; echo "test-codex-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"; exit 1
fi

# ── Structure pins ───────────────────────────────────────────────────
[ -x "$W" ] && check "W1 wrapper exists + executable" PASS || check "W1 wrapper exists + executable" FAIL
bash -n "$W" 2>/dev/null && check "W2 bash -n syntax" PASS || check "W2 bash -n syntax" FAIL
grep -qF 'jq not found' "$W" && check "W3 jq guard present" PASS || check "W3 jq guard present" FAIL
grep -qF 'fsm-state-final' "$W" && grep -qF 'chainDone' "$W" \
  && check "W4 emits fsm-state incl. chainDone flag" PASS || check "W4 emits fsm-state incl. chainDone flag" FAIL
grep -qF 'witness-' "$W" && check "W5 extracts witness log" PASS || check "W5 extracts witness log" FAIL
grep -qF 'env -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID' "$W" \
  && check "W18 scrubs inherited session ids at the codex exec boundary" PASS || check "W18 session-id env scrub pin" FAIL
grep -qF 'OPTIONS_JSON="${2:-"{}"}"' "$W" \
  && check "W19a options default quoted (brace-expansion corruption fixed)" PASS || check "W19a options default quoted" FAIL
RC19=0; DRY_RUN=1 bash "$W" "x" '{broken' >/dev/null 2>&1 || RC19=$?
[ "$RC19" = "2" ] && check "W19b invalid options JSON rejected loudly (rc=2)" PASS || check "W19b invalid options JSON rejected (rc=$RC19)" FAIL

# ── DRY_RUN command-shape (no codex CLI / no API needed) ─────────────
OUT="$(DRY_RUN=1 bash "$W" "implement feature X" '{"config":{"working_dir":"."}}' 2>&1)"
RC=$?
[ "$RC" = "0" ] && check "W6 DRY_RUN exits 0 (no codex needed)" PASS || check "W6 DRY_RUN exits 0 (rc=$RC)" FAIL
printf '%s' "$OUT" | grep -qF 'would isolate' && check "W7 DRY_RUN previews fixture isolation" PASS || check "W7 DRY_RUN previews fixture isolation" FAIL
printf '%s' "$OUT" | grep -qE 'codex +exec +--json' && check "W8 DRY_RUN runs 'codex exec --json'" PASS || check "W8 DRY_RUN runs 'codex exec --json'" FAIL
printf '%s' "$OUT" | grep -qF -- '--skip-git-repo-check' && check "W9 passes --skip-git-repo-check" PASS || check "W9 passes --skip-git-repo-check" FAIL
printf '%s' "$OUT" | grep -qF -- '--dangerously-bypass-approvals-and-sandbox' && check "W10 passes bypass-approvals-and-sandbox" PASS || check "W10 passes bypass flag" FAIL
printf '%s' "$OUT" | grep -qE -- '-C +/[^ ]*codex-eval-' && check "W11 sets -C to the isolated codex-eval- dir" PASS || check "W11 sets -C to the isolated codex-eval- dir" FAIL
printf '%s' "$OUT" | grep -qF 'CODEX_HOME=' && check "W12 reports CODEX_HOME" PASS || check "W12 reports CODEX_HOME" FAIL

# ── CODEX_HOME override honored ──────────────────────────────────────
TMPHOME="$(mktemp -d)"; trap 'rm -rf "$TMPHOME"' EXIT
OUT2="$(ZENSU_CODEX_HOME_OVERRIDE="$TMPHOME" DRY_RUN=1 bash "$W" "x" '{"config":{"working_dir":"."}}' 2>&1)"
printf '%s' "$OUT2" | grep -qF "CODEX_HOME=$TMPHOME" \
  && check "W13 ZENSU_CODEX_HOME_OVERRIDE sets CODEX_HOME" PASS || check "W13 ZENSU_CODEX_HOME_OVERRIDE sets CODEX_HOME" FAIL

# ── agent option → in-prompt subagent request (Codex has no --agent flag) ─────
OUT3="$(DRY_RUN=1 bash "$W" "review this" '{"config":{"agent":"zensu-code-reviewer","working_dir":"."}}' 2>&1)"
{ printf '%s' "$OUT3" | grep -qF 'zensu-code-reviewer' && printf '%s' "$OUT3" | grep -qF 'subagent'; } \
  && check "W14 agent option becomes an in-prompt subagent request" PASS || check "W14 agent option in-prompt request" FAIL

# ── Behavioral coverage of the port-specific code (JSONL flatten + .zensu/ state
#    extraction) via a fake `codex` on PATH — still no real codex CLI and no API. ──
if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  STUB="$(mktemp -d)"; FIX="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME" "$STUB" "$FIX"' EXIT
  cat > "$STUB/codex" <<'FAKE'
#!/bin/bash
# Fake codex: honor -C <dir>, write canned .zensu state+witness there, emit JSONL.
dir=""; while [ $# -gt 0 ]; do case "$1" in -C) dir="$2"; shift 2;; *) shift;; esac; done
[ -z "$dir" ] && dir="$PWD"
printf 'CLAUDE_SESSION_ID=%s CODEX_THREAD_ID=%s\n' "${CLAUDE_SESSION_ID:-unset}" "${CODEX_THREAD_ID:-unset}" > "$dir/.env-probe"
mkdir -p "$dir/.zensu/state" "$dir/.zensu/logs"
printf '%s' '{"phase":"GREEN_PASS","step_id":"s1","chainDone":true,"implComplete":true,"history":[{"step":"s1","phase":"RED_FAIL","ts":"t"},{"step":"s1","phase":"GREEN_PASS","ts":"t"}]}' > "$dir/.zensu/state/tdd-phase-stub.json"
printf 'BASH cmd="node --test" exit=? tail="1 pass" interrupted=false\n' > "$dir/.zensu/logs/witness-stub.log"
printf '%s\n' '{"type":"item.completed","item":{"text":"STUB agent message"}}'
printf '%s\n' '{"type":"turn.completed","turn":{"output_text":"done"}}'
exit 0
FAKE
  chmod +x "$STUB/codex"
  printf '# fixture\n' > "$FIX/AGENTS.md"
  SOUT="$(CLAUDE_SESSION_ID=leak-claude CODEX_THREAD_ID=leak-codex KEEP_ISOLATED=1 \
    PATH="$STUB:$PATH" bash "$W" "do the thing" "$(printf '{"config":{"working_dir":"%s"}}' "$FIX")" 2>"$STUB/err.log")"
  printf '%s' "$SOUT" | grep -qF 'STUB agent message' \
    && check "W15 flattens codex JSONL agent text (item.text + turn.completed)" PASS || check "W15 flattens codex JSONL agent text" FAIL
  { printf '%s' "$SOUT" | grep -qF 'fsm-state-final' && printf '%s' "$SOUT" | grep -qF 'chainDone=true'; } \
    && check "W16 extracts .zensu fsm-state incl. chainDone=true" PASS || check "W16 extracts fsm-state chainDone" FAIL
  { printf '%s' "$SOUT" | grep -qF '===== witness:' && printf '%s' "$SOUT" | grep -qF 'BASH cmd='; } \
    && check "W17 extracts the .zensu witness log" PASS || check "W17 extracts the witness log" FAIL

  ISO="$(sed -n 's/^codex-promptfoo-wrapper: isolated working dir: //p' "$STUB/err.log" | head -1)"
  if [ -n "$ISO" ] && [ -f "$ISO/.env-probe" ] && grep -qF 'CLAUDE_SESSION_ID=unset CODEX_THREAD_ID=unset' "$ISO/.env-probe"; then
    check "W20a env scrub is behavioral — child codex sees neither inherited id" PASS
  else
    check "W20a env scrub behavioral (probe: $(cat "$ISO/.env-probe" 2>/dev/null))" FAIL
  fi
  grep -qF 'KEEP_ISOLATED=1, leaving' "$STUB/err.log" \
    && check "W20b KEEP_ISOLATED branch leaves the dir + says so" PASS || check "W20b KEEP_ISOLATED branch" FAIL
  [ -n "$ISO" ] && rm -rf "$ISO" 2>/dev/null

  cat > "$STUB/codex" <<'FAKE2'
#!/bin/bash
printf '%s\n' '{"weird":"shape-the-filter-does-not-know"}'
exit 0
FAKE2
  chmod +x "$STUB/codex"
  FIX2="$(mktemp -d)"
  printf '# fixture\n' > "$FIX2/AGENTS.md"
  mkdir -p "$FIX2/.zensu/state" "$FIX2/.zensu/logs"
  printf '%s' '{"phase":"GREEN_PASS","chainDone":true}' > "$FIX2/.zensu/state/tdd-phase-stale.json"
  printf 'BASH cmd="stale-run" exit=0\n' > "$FIX2/.zensu/logs/witness-stale.log"
  SOUT2="$(PATH="$STUB:$PATH" bash "$W" "x" "$(printf '{"config":{"working_dir":"%s"}}' "$FIX2")" 2>/dev/null)"
  rm -rf "$FIX2"
  printf '%s' "$SOUT2" | grep -qF 'weird' \
    && check "W21 unknown JSONL shapes fall back to the raw stream" PASS || check "W21 raw-stream fallback" FAIL
  { printf '%s' "$SOUT2" | grep -qF 'stale' || printf '%s' "$SOUT2" | grep -qF 'chainDone=true'; } \
    && check "W22 stale fixture .zensu state purged before the run (leaked into output)" FAIL \
    || check "W22 stale fixture .zensu state purged before the run" PASS
else
  echo "  SKIP  W15-W22 stub-codex behavioral tests — jq/git unavailable"
fi

echo "----"
echo "test-codex-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
