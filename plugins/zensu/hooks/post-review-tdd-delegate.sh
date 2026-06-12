#!/bin/bash
# NOT WIRED ON CODEX. Codex CLI has no PostToolUse event on subagent completion,
# so this auto-fix-loop hook is not registered in hooks/hooks.json. Its behavior
# (route reviewer findings back, loop until PASS or max rounds) is driven by the
# $zensu-tdd skill prose and backstopped by the Stop chain-enforcer on the Codex
# port. Kept here for reference and Claude Code compatibility.
#
# PostToolUse hook fired when the Agent (code-reviewer) tool completes.
# Filters on subagent_type == "zensu:code-reviewer" and routes findings back to
# the MAIN agent (which runs the /zensu:tdd workflow in-thread) via
# additionalContext. On PASS / suggestions-only the main agent closes the chain
# with `zensu-log.sh --chain-done`; on max-rounds this hook sets chainDone
# itself so the Stop-hook backstop releases.
#
# Behavior is configurable via ~/.zensu/config.json (resolution order: env,
# project-local, global):
#   hooks.autoFixIncludeSuggestions=true  -> route ALL severities
#   hooks.autoFixIncludeSuggestions=false -> route Critical+Important only (default, backward-compat)
#   hooks.autoFixMaxRounds=<int 1..99>    -> loop guard (default 5)
#
# Counter state lives at ${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json. claude-code's auto-set CLAUDE_PLUGIN_DATA is intentionally IGNORED (use CLAUDE_PLUGIN_DATA_OVERRIDE to relocate).

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoFix || exit 0

INPUT="$(cat)"

SUBAGENT_TYPE="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      console.log((j.tool_input && j.tool_input.subagent_type) || "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"

if [ "$SUBAGENT_TYPE" != "zensu:code-reviewer" ]; then
  exit 0
fi

SESSION_ID="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const id = j.session_id;
      console.log((typeof id === "string" && id) ? id : "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"

# Mode-aware fix discipline: the per-session `vanilla` flag was frozen into the
# state file by `--tdd-begin`. Read the STATE flag (never live config) so the
# fix-round directive matches the discipline the session actually runs under.
# Sessions with no active chain-state get no directive at all — same activation
# contract as the gate and the Stop enforcer.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
if [ "$(tdd_session_active "$(tdd_state_file "$SESSION_ID")")" != "true" ]; then
  exit 0
fi
if [ "$(tdd_vanilla_mode "$(tdd_state_file "$SESSION_ID")")" = "true" ]; then
  FIX_DISCIPLINE_ALL="in vanilla mode by re-entering the /zensu:tdd workflow's vanilla implementation loop (fix each finding directly — no RED→GREEN cycle required, tests at your discretion; keep the structured CHECKPOINT/AUDIT evidence discipline; the phase-gate passes through in this session)"
  FIX_DISCIPLINE_CI="$FIX_DISCIPLINE_ALL"
  FIX_DONE_PHRASE="After the fixes are applied and verified"
else
  FIX_DISCIPLINE_ALL="under strict TDD discipline by re-entering the /zensu:tdd workflow (for each finding: write or adjust a RED test, then IMPL, then GREEN; the PreToolUse phase-gate is still active in this session)"
  FIX_DISCIPLINE_CI="under strict TDD discipline by re-entering the /zensu:tdd workflow (for each finding: RED test, then IMPL, then GREEN; the PreToolUse phase-gate is still active in this session)"
  FIX_DONE_PHRASE="After the fixes are GREEN"
fi

MAX_ROUNDS="$(zensu_autofix_max_rounds)"
STATE_DIR="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
COUNTER_FILE="$STATE_DIR/rounds-${SESSION_ID}.json"
if [ -L "$COUNTER_FILE" ]; then
  echo "zensu post-review hook: refusing to write through symlink at $COUNTER_FILE — counter NOT updated" >&2
  exit 0
fi
if [ -L "$STATE_DIR" ]; then
  echo "zensu post-review hook: refusing to write under symlinked state dir $STATE_DIR — counter NOT updated" >&2
  exit 0
fi

CURRENT="$(node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const n = j && j.count;
    console.log(Number.isInteger(n) && n >= 0 ? String(n) : "0");
  } catch (_) { console.log("0"); }
' "$COUNTER_FILE" 2>/dev/null)"
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac
NEXT=$((CURRENT + 1))

if [ "$(_zensu_log_style)" = "none" ]; then
  PAYLOAD="$(printf '{"count":%d}' "$NEXT")"
else
  PAYLOAD="$(printf '{"count":%d,"ts":"%s"}' "$NEXT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
fi
if TMP_FILE="$(mktemp "${STATE_DIR}/rounds-${SESSION_ID}.XXXXXX" 2>/dev/null)"; then
  if printf '%s\n' "$PAYLOAD" > "$TMP_FILE" \
     && mv "$TMP_FILE" "$COUNTER_FILE" 2>/dev/null; then
    :
  else
    rm -f "$TMP_FILE" 2>/dev/null
    echo "zensu post-review hook: failed to persist counter for session ${SESSION_ID} (write/mv)" >&2
    if ! printf '%s\n' "$PAYLOAD" > "$COUNTER_FILE" 2>/dev/null; then
      echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
    fi
  fi
else
  echo "zensu post-review hook: mktemp failed under ${STATE_DIR} for session ${SESSION_ID}" >&2
  if ! printf '%s\n' "$PAYLOAD" > "$COUNTER_FILE" 2>/dev/null; then
    echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
  fi
fi

COMBINED_SUMMARY_DIRECTIVE=""
if zensu_combined_summary_enabled; then
  COMBINED_SUMMARY_DIRECTIVE=$'\n\nAfter your status line, produce a CHAIN-END SUMMARY with three sections (pull data from your own main-thread TDD execution and the prior zensu:code-reviewer Agent results in your context, do NOT re-spawn agents):\n\n## Implementation Summary\nWhat this main-thread TDD session built: feature title, files modified, tests created, build status (passed / skipped / failed), mtime audit verdict, coverage status. Cite the plan + log file paths.\n\n## Review Summary\nFinal zensu:code-reviewer verdict: PASS / PASS with suggestions / max-rounds reached. Findings count by severity. Files reviewed.\n\n## Auto-fix History\nFor each round 1..N: what findings were fixed in-thread, what was changed, what remains. Skip this section if zero rounds (chain ended on first review).'
fi

# When the self-review terminal stage is enabled, the code-reviewer chain hands
# off to /zensu:self-review (a main-thread Skill) instead of closing here:
# self-review owns the chain terminus (--chain-done) and renders the report.
SELF_REVIEW_ON=0
if zensu_hook_enabled selfReview; then SELF_REVIEW_ON=1; fi

if [ "$SELF_REVIEW_ON" = "1" ]; then
  CLOSE_PASS="run 'bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --code-review-done' (PLUGIN_ROOT = contents of ~/.zensu/plugin-root, the value you resolved in Phase 0), then your VERY NEXT action must be the Skill tool with skill='zensu:self-review' — the terminal self-review stage that owns the chain terminus and renders the final CHAIN-END SUMMARY. Do NOT close the chain yourself, do NOT render the summary here, and do NOT end your turn — self-review finalizes the chain."
  TAIL_DIRECTIVE=""
else
  CLOSE_PASS="close the review chain by running 'bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --chain-done' (PLUGIN_ROOT = contents of ~/.zensu/plugin-root, the value you resolved in Phase 0), then stop."
  TAIL_DIRECTIVE="${COMBINED_SUMMARY_DIRECTIVE}"
fi

if [ "$NEXT" -gt "$MAX_ROUNDS" ]; then
  # Max rounds reached. With self-review enabled the chain does NOT terminate
  # here: mark the code-reviewer chain converged (codeReviewDone) and hand off to
  # the terminal self-review stage, which owns --chain-done. With self-review
  # disabled, terminate as before (chainDone) so the Stop-hook backstop releases.
  if [ "$SELF_REVIEW_ON" = "1" ]; then
    bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --code-review-done --session "$SESSION_ID" >/dev/null 2>&1 || true
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The code-reviewer chain is marked converged (codeReviewDone). Do NOT spawn zensu:code-reviewer again and do NOT keep fixing its findings. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — the terminal self-review stage. Carry the remaining reviewer findings forward for it under '### Findings (max rounds reached, manual fix required)' so they land in the final report. /zensu:self-review owns the chain terminus and renders the final summary — do NOT close the chain yourself. To grant another reviewer budget instead of finalizing, the user can invoke the /zensu:reset-review-limit skill."
  else
    bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --session "$SESSION_ID" >/dev/null 2>&1 || true
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The review chain is now marked complete (chainDone) so you MAY end your turn. Do NOT spawn zensu:code-reviewer again and do NOT keep fixing. Reply with the remaining findings under '### Findings (max rounds reached, manual fix required)' and stop. To grant another budget and resume the review/fix cycle in this same session, the user can invoke the /zensu:reset-review-limit skill — surface this hint at the end of your reply so the user knows the escape hatch exists.${COMBINED_SUMMARY_DIRECTIVE}"
  fi
  node -e '
    const msg = process.argv[1];
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: msg
      }
    }));
  ' "$CONV_MSG"
  echo
  exit 0
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_ALL}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering. ${FIX_DONE_PHRASE}, your VERY NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' to re-verify — the Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_CI}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. ${FIX_DONE_PHRASE}, your VERY NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' to re-verify — the Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"

node -e '
  const msg = process.argv[1];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: msg
    }
  }));
' "$EXPANDED_MSG"
echo
