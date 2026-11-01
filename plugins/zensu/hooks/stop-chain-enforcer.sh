#!/bin/bash
# Stop hook — guarantees the post-implementation review chain runs to completion
# in the main-thread TDD model.
#
# In the old subagent model the reviewer auto-spawn was hook-enforced by the
# tdd-manager subagent's Agent-tool completion (post-tdd-review-delegate.sh).
# With TDD running in the MAIN thread that completion event no longer exists, so
# this Stop hook is the replacement hard backstop: it refuses to let the main
# agent end its turn while a TDD session has finished implementation
# (chain-state implComplete=true) but the review/auto-fix chain has not
# terminated (chainDone=true). The reference post-review-tdd-delegate.sh sets
# chainDone at PASS / max-rounds where that completion event exists; on Codex
# that hook never fires (reference-only), so the skill prose plus the
# $zensu-self-review terminus set chainDone instead.
#
# Activation: only when chain-state `active` is true for THIS session. Other
# sessions, non-TDD work, and plain CLI stop normally.
#
# Escapes:
#   ZENSU_CHAIN=off                 -> never block
#   hooks.chainEnforcer=false       -> disable via ~/.zensu/config.json
#   stop-block budget exceeded      -> allow stop + stderr warning (anti-deadlock)

set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled chainEnforcer || exit 0

if [ "${ZENSU_CHAIN:-}" = "off" ]; then exit 0; fi
command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

read_field() {
  PAYLOAD="$INPUT" FIELD="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : (typeof v === "boolean" ? String(v) : ""));
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

SESSION_ID="$(read_field session_id)"
RAW_SESSION_ID="$SESSION_ID"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
unset ZENSU_SESSION_KEY
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
export ZENSU_SESSION_KEY="$SESSION_ID"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_ID")" || STATE_FILE="(unresolved Session Control project state)"

INVALID_STOP_CAP=3
INVALID_COUNT_FILE=''
[[ "$SESSION_ID" =~ ^scv1_[a-f0-9]{64}$ ]] && [ -n "${HOME:-}" ] \
  && INVALID_COUNT_FILE="${HOME}/.zensu/stop-guard/codex/invalid-state-${SESSION_ID}.count"

clear_invalid_stop_count() {
  [ -z "$INVALID_COUNT_FILE" ] || rm -f "$INVALID_COUNT_FILE" 2>/dev/null
  return 0
}

allow_stop() {
  clear_invalid_stop_count
  exit 0
}

record_invalid_stop() {
  local dir previous='' candidate
  [ -n "$INVALID_COUNT_FILE" ] || return 1
  dir="${INVALID_COUNT_FILE%/*}"
  ( umask 077 && mkdir -p "$dir" ) 2>/dev/null || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  if [ -e "$INVALID_COUNT_FILE" ] || [ -L "$INVALID_COUNT_FILE" ]; then
    [ -f "$INVALID_COUNT_FILE" ] && [ ! -L "$INVALID_COUNT_FILE" ] || return 1
    previous="$(head -c 8 "$INVALID_COUNT_FILE" 2>/dev/null)"
  fi
  case "$previous" in ''|*[!0-9]*|?????*) previous=0 ;; esac
  previous=$((10#$previous + 1))
  candidate="${INVALID_COUNT_FILE}.$$.${RANDOM}.candidate"
  ( set -C && umask 077 && printf '%s' "$previous" > "$candidate" ) 2>/dev/null || return 1
  mv -f "$candidate" "$INVALID_COUNT_FILE" 2>/dev/null || { rm -f "$candidate" 2>/dev/null; return 1; }
  printf '%s\n' "$previous"
}

# Corrupt workflow state cannot prove that the session is inactive, that
# implementation never completed, or that the review chain reached its
# terminus. Block before reading any flags.
stop_on_invalid_state() {
  local cause="${1:-the session-state file is not a valid workflow document}"
  local remedy="${2:-Start a fresh Codex session so Session Control v1 creates new state.}"
  local attempt
  if ! attempt="$(record_invalid_stop)"; then
    echo "zensu chain-enforcer: this session's workflow state cannot be trusted (${STATE_FILE}; cause: ${cause}) and the invalid-state stop counter cannot be stored; allowing stop instead of blocking without a bound. The review-chain guarantee cannot be verified for this session, and edits and the chain terminus stay blocked. ${remedy} ZENSU_CHAIN=off remains the explicit, reviewed recovery escape." >&2
    exit 0
  fi
  if [ "$attempt" -gt "$INVALID_STOP_CAP" ]; then
    echo "zensu chain-enforcer: this session's workflow state cannot be trusted (${STATE_FILE}; cause: ${cause}) — ${attempt} consecutive invalid-state stop blocks exceed the cap (${INVALID_STOP_CAP}); allowing stop. The review-chain guarantee cannot be verified for this session, and edits and the chain terminus stay blocked. ${remedy} ZENSU_CHAIN=off remains the explicit, reviewed recovery escape." >&2
    exit 0
  fi
  REASON="STOP intercepted by zensu chain-enforcer because this session's workflow state cannot be trusted (${STATE_FILE}; cause: ${cause}; invalid-state block ${attempt} of ${INVALID_STOP_CAP}). Its active/implComplete/chainDone flags cannot be trusted, so Stop fails closed until that cap while edits and the chain terminus stay blocked. ${remedy} Use ZENSU_CHAIN=off only as an explicit, reviewed recovery escape."
  node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
  echo
  exit 0
}

if [ "$STATE_FILE" = "(unresolved Session Control project state)" ]; then
  printf '%s' "$INPUT" | node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/codex-session-adopt-v1.js" --quiet >/dev/null 2>&1
  STATE_FILE="$(tdd_state_file "$SESSION_ID")" || STATE_FILE="(unresolved Session Control project state)"
fi

if [ "$STATE_FILE" = "(unresolved Session Control project state)" ]; then
  stop_on_invalid_state "$(zensu_resolve_cause "$RAW_SESSION_ID")" \
    "$(node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/codex-retrust-hint-v1.js" 2>/dev/null)"
fi

# A valid inactive main-thread baseline may stop normally. A missing/deleted
# mandatory baseline cannot prove that the session or chain is inactive.
STATE_STATUS="$(tdd_state_status "$STATE_FILE")"
if [ "$STATE_STATUS" = "missing" ]; then
  stop_on_invalid_state "the session-state file is missing"
fi
[ "$STATE_STATUS" = "invalid" ] && stop_on_invalid_state
ACTIVE_STATE="$(tdd_session_active "$STATE_FILE")"
[ "$ACTIVE_STATE" = "invalid" ] && stop_on_invalid_state
[ "$ACTIVE_STATE" = "true" ] || allow_stop
# Implementation not finished -> do not enforce the review chain yet (allow
# legit mid-TDD pauses; TDD progression itself is driven by the gate + skill).
IMPL_COMPLETE_STATE="$(tdd_impl_complete "$STATE_FILE")"
[ "$IMPL_COMPLETE_STATE" = "invalid" ] && stop_on_invalid_state
[ "$IMPL_COMPLETE_STATE" = "true" ] || allow_stop
# Chain already terminated -> allow stop.
CHAIN_DONE_STATE="$(tdd_chain_done "$STATE_FILE")"
[ "$CHAIN_DONE_STATE" = "invalid" ] && stop_on_invalid_state
[ "$CHAIN_DONE_STATE" = "true" ] && allow_stop

# Anti-deadlock budget: cap consecutive Stop-hook blocks so a stalled chain
# (agent never spawns the reviewer, chainDone never set) cannot loop forever.
MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
BLOCKS="$(tdd_increment_counter "$SESSION_ID" stopBlocks)" || stop_on_invalid_state
case "$BLOCKS" in ''|*[!0-9]*) stop_on_invalid_state ;; esac
if [ "$BLOCKS" -gt "$CAP" ]; then
  [ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] && stop_on_invalid_state
  echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); allowing stop. Run \$zensu-reset-review-limit and re-spawn the zensu-code-reviewer subagent to continue, or set ZENSU_CHAIN=off." >&2
  allow_stop
fi

# Two-stage terminus: once the code-reviewer chain has converged
# (codeReviewDone), the terminal self-review stage must run before chainDone.
# The self-review stage is itself a main-thread Skill, so no Agent-completion
# event fires for it — this Stop hook is its hard backstop too.
#
# Fix-discipline wording follows the session's FROZEN mode (state `vanilla`
# flag written at --tdd-begin, never live config): strict sessions are told to
# fix under the gate, vanilla sessions to fix directly while keeping the
# CHECKPOINT/AUDIT evidence discipline. The chain guarantee itself is
# mode-independent. post-review-tdd-delegate never fires on Codex, so this
# Stop hook is the only wired carrier of the mode-aware fix discipline.
VANILLA_STATE="$(tdd_vanilla_mode "$STATE_FILE")"
[ "$VANILLA_STATE" = "invalid" ] && stop_on_invalid_state
if [ "$VANILLA_STATE" = "true" ]; then
  FIX_PHRASE="directly (vanilla mode — no RED→GREEN cycle required; keep the structured CHECKPOINT/AUDIT evidence discipline)"
  SELF_FIX_PHRASE="takes at most one fix round applied directly (vanilla mode — the gate passes through)"
else
  FIX_PHRASE="under the gate"
  SELF_FIX_PHRASE="takes at most one fix round under the still-active TDD phase-gate"
fi
CODE_REVIEW_DONE="$(tdd_code_review_done "$STATE_FILE")"
[ "$CODE_REVIEW_DONE" = "invalid" ] && stop_on_invalid_state
if zensu_hook_enabled selfReview && [ "$CODE_REVIEW_DONE" = "true" ]; then
  REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Your VERY NEXT action MUST be to invoke the \$zensu-self-review skill — it performs a final critical self-reflection over this session's changes, ${SELF_FIX_PHRASE}, and OWNS the chain terminus (it runs 'PLUGIN_ROOT=\"\$(node \"\$HOME/.zensu/session-control/codex/v3/resolve-v3.js\" --field plugin_root)\" && bash \"\$PLUGIN_ROOT/hooks/lib/zensu-log.sh\" --chain-done'). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run --chain-done yourself — let \$zensu-self-review finalize the chain."
else
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu-code-reviewer chain has not completed. Your VERY NEXT action MUST be to spawn the zensu-code-reviewer subagent (Codex multi-agent), passing as the prompt a one-paragraph summary of what was implemented/fixed PLUS the list of changed files (use 'git diff --name-only HEAD' to enumerate). Do NOT end your turn, and do NOT fix anything inline first — review the report, fix any Critical/Important findings ${FIX_PHRASE}, then re-run the reviewer until it PASSes or you hit the round cap. Only valid exception: if implementation produced ZERO file changes, run 'PLUGIN_ROOT=\"\$(node \"\$HOME/.zensu/session-control/codex/v3/resolve-v3.js\" --field plugin_root)\" && bash \"\$PLUGIN_ROOT/hooks/lib/zensu-log.sh\" --chain-done' and then stop."
fi
clear_invalid_stop_count

node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
echo
exit 0
