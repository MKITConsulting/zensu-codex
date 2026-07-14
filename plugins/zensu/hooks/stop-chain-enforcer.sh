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

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"
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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Not a main-thread TDD session -> let the agent stop.
[ "$(tdd_session_active "$STATE_FILE")" = "true" ] || exit 0
# Implementation not finished -> do not enforce the review chain yet (allow
# legit mid-TDD pauses; TDD progression itself is driven by the gate + skill).
[ "$(tdd_impl_complete "$STATE_FILE")" = "true" ] || exit 0
# Chain already terminated -> allow stop.
[ "$(tdd_chain_done "$STATE_FILE")" = "true" ] && exit 0

# Anti-deadlock budget: cap consecutive Stop-hook blocks so a stalled chain
# (agent never spawns the reviewer, chainDone never set) cannot loop forever.
MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
BUDGET_FILE="${STATE_FILE}.stopblocks"
if [ ! -L "$BUDGET_FILE" ]; then
  printf 'x' >> "$BUDGET_FILE" 2>/dev/null || true
fi
BLOCKS=$(wc -c < "$BUDGET_FILE" 2>/dev/null | tr -d '[:space:]')
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=1 ;; esac
if [ "$BLOCKS" -gt "$CAP" ]; then
  echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); allowing stop. Run \$zensu-reset-review-limit and re-spawn the zensu-code-reviewer subagent to continue, or set ZENSU_CHAIN=off." >&2
  exit 0
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
if [ "$(tdd_vanilla_mode "$STATE_FILE")" = "true" ]; then
  FIX_PHRASE="directly (vanilla mode — no RED→GREEN cycle required; keep the structured CHECKPOINT/AUDIT evidence discipline)"
  SELF_FIX_PHRASE="takes at most one fix round applied directly (vanilla mode — the gate passes through)"
else
  FIX_PHRASE="under the gate"
  SELF_FIX_PHRASE="takes at most one fix round under the still-active TDD phase-gate"
fi
CODE_REVIEW_DONE="$(tdd_code_review_done "$STATE_FILE")"
if zensu_hook_enabled selfReview && [ "$CODE_REVIEW_DONE" = "true" ]; then
  REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Your VERY NEXT action MUST be to invoke the \$zensu-self-review skill — it performs a final critical self-reflection over this session's changes, ${SELF_FIX_PHRASE}, and OWNS the chain terminus (it runs 'PLUGIN_ROOT=\"\$(node \"\$HOME/.zensu/plugin-roots/codex/resolve-v1.js\")\" && bash \"\$PLUGIN_ROOT/hooks/lib/zensu-log.sh\" --chain-done'). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run --chain-done yourself — let \$zensu-self-review finalize the chain."
else
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu-code-reviewer chain has not completed. Your VERY NEXT action MUST be to spawn the zensu-code-reviewer subagent (Codex multi-agent), passing as the prompt a one-paragraph summary of what was implemented/fixed PLUS the list of changed files (use 'git diff --name-only HEAD' to enumerate). Do NOT end your turn, and do NOT fix anything inline first — review the report, fix any Critical/Important findings ${FIX_PHRASE}, then re-run the reviewer until it PASSes or you hit the round cap. Only valid exception: if implementation produced ZERO file changes, run 'PLUGIN_ROOT=\"\$(node \"\$HOME/.zensu/plugin-roots/codex/resolve-v1.js\")\" && bash \"\$PLUGIN_ROOT/hooks/lib/zensu-log.sh\" --chain-done' and then stop."
fi

node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
echo
exit 0
