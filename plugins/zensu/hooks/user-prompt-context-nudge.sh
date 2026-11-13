#!/bin/bash
# UserPromptSubmit hook — context-compaction nudge. Reads live context-window
# occupancy from the session transcript and, once usage crosses a configurable
# threshold (default 50%), injects a model-facing additionalContext reminder so
# the MAIN-thread agent proactively proposes `/compact` to the user. It never
# runs compaction itself (only the user can trigger /compact) and never blocks
# the prompt — on any error, missing node, missing transcript, or sub-threshold
# usage it exits 0 silently.
#
# All settings live under the top-level `context` node of .zensu/config.json:
# context.compactionNudge (enable, default on), context.nudgeThreshold (default
# 50, range 1..99), context.windowSize (optional; when unset the denominator
# auto-tiers to 200k or 1M from observed usage). Disable per-project or globally
# by setting context.compactionNudge:false, resolved through the usual
# env -> project-local -> global config order.
#
# Band de-bounce: a state file records the last 10%-band that triggered a nudge,
# so the reminder fires once per band climb (50, 60, 70, …) instead of on every
# prompt, and re-arms after a compaction shrinks the context back down.
set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true
zensu_context_nudge_enabled || exit 0

read_field() {
  PAYLOAD="$INPUT" FIELD="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

TRANSCRIPT="$(read_field transcript_path)"
[ -n "$TRANSCRIPT" ] || exit 0
[ -f "$TRANSCRIPT" ] || exit 0

SESSION_ID="$(read_field session_id)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
unset ZENSU_SESSION_KEY
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
export ZENSU_SESSION_KEY="$SESSION_ID"

THRESHOLD="$(zensu_context_nudge_threshold)"
WINDOW="$(zensu_context_window_size)"
PROJECT_ROOT="$(zensu_resolve_project_dir)" || PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-.}"

TRANSCRIPT="$TRANSCRIPT" WINDOW="$WINDOW" THRESHOLD="$THRESHOLD" \
  CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" \
  PROJECT_DIR="$PROJECT_ROOT" SESSION_KEY="$SESSION_ID" node -e '
  const fs = require("fs");
  try {
    const core = require(process.env.CORE);
    const bandTarget = { projectRoot: process.env.PROJECT_DIR, sessionId: process.env.SESSION_KEY, kind: "context-nudge" };
    const path = process.env.TRANSCRIPT;
    const cfgWindow = parseInt(process.env.WINDOW, 10);
    const threshold = parseInt(process.env.THRESHOLD, 10) || 50;

    // Tail-read the transcript (bounded) and find the most recent usage block.
    const size = fs.statSync(path).size;
    const CAP = 262144;
    const start = size > CAP ? size - CAP : 0;
    const fd = fs.openSync(path, "r");
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    const lines = buf.toString("utf8").split("\n");

    // Most recent NON-ZERO usage block. Claude Code transcripts can end with a
    // trailing assistant record whose usage is all zeros (e.g. a stop/summary
    // record) — reading the literal last usage would mask the real occupancy, so
    // we skip zero-sum blocks and take the latest one that actually carries tokens.
    let occupied = null;
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      let obj;
      try { obj = JSON.parse(line); } catch (_) { continue; }
      const u = (obj && obj.message && obj.message.usage) || (obj && obj.usage);
      if (u && typeof u.input_tokens === "number") {
        const occ = u.input_tokens
          + (typeof u.cache_read_input_tokens === "number" ? u.cache_read_input_tokens : 0)
          + (typeof u.cache_creation_input_tokens === "number" ? u.cache_creation_input_tokens : 0);
        if (occ > 0) { occupied = occ; break; }
      }
    }
    if (occupied === null) process.exit(0);

    // Hooks are not handed the real context-window size (only the statusline is),
    // so when context.windowSize is unset we infer the tier from observed usage:
    // Claude models run at ~200k or ~1M tokens, and occupied can never exceed the
    // true window — anything past 200k must be a 1M-context session. Set
    // context.windowSize explicitly for accurate early-session percentages.
    const window = (Number.isInteger(cfgWindow) && cfgWindow > 0)
      ? cfgWindow
      : (occupied > 200000 ? 1000000 : 200000);

    const pct = Math.round((occupied / window) * 100);
    const band = Math.floor(pct / 10) * 10;

    const recorded = core.inspectSessionFile(bandTarget);
    if (recorded.state === "unusable") process.exit(0);
    let last = -1;
    if (recorded.state === "present") {
      const raw = recorded.data.toString("utf8").trim();
      if (/^-?\d+$/.test(raw)) last = parseInt(raw, 10);
    }

    if (pct >= threshold && band > last) {
      core.writeSessionFile({ ...bandTarget, value: band });
      const msg = "zensu context-nudge: this conversation is at ~" + pct + "% of the context window "
        + "(threshold " + threshold + "%). Proactively and briefly tell the user they can run /compact "
        + "to compact the conversation and reclaim context, then continue with their request. "
        + "Only the user can trigger /compact — do not attempt it via a tool. Mention this at most once.";
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: msg
        }
      }));
    } else if (band < last) {
      // Context shrank (e.g. after a compaction) — re-arm for the next climb.
      core.writeSessionFile({ ...bandTarget, value: band });
    }
  } catch (_) {
    // never block the prompt
  }
  process.exit(0);
'
exit 0
