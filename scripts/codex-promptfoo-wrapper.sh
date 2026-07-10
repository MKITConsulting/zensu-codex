#!/bin/bash
set -u

# codex-promptfoo-wrapper.sh — promptfoo `exec:` provider that bridges to `codex exec`.
#
# Codex port of scripts/claude-promptfoo-wrapper.sh (zensu-claude-code). The fixture
# isolation (CoW clone into a throwaway dir) and the post-run `.zensu/` state
# extraction (fsm phase+history, chain flags, witness log, hook events) are
# engine-agnostic and kept verbatim — only the CLI command line and the JSONL event
# flattening differ: `claude --print --output-format stream-json` becomes
# `codex exec --json`, and the claude assistant/tool_use/result shapes become the
# codex `item.*` / `turn.completed` event shapes.

# jq is needed even for DRY_RUN (it parses the options JSON for the preview).
if ! command -v jq >/dev/null 2>&1; then
  echo "codex-promptfoo-wrapper: jq not found on PATH — install jq." >&2
  exit 127
fi

PROMPT="${1:-}"
OPTIONS_JSON="${2:-{}}"

AGENT="$(echo "$OPTIONS_JSON" | jq -r '.config.agent // ""' 2>/dev/null)"
WORKDIR="$(echo "$OPTIONS_JSON" | jq -r '.config.working_dir // "."' 2>/dev/null)"
[ -z "$WORKDIR" ] && WORKDIR="."

# Codex has no `--agent` flag; a subagent is requested in-prompt (Codex runs an
# explicitly-named subagent when asked). The reference TDD eval leaves agent empty.
if [ -n "$AGENT" ]; then
  FULL_PROMPT="Ask Codex to run the ${AGENT} subagent with this task: ${PROMPT}"
else
  FULL_PROMPT="$PROMPT"
fi

# CoW clone probe (APFS `cp -c`), falling back to a deep copy — verbatim from the
# claude wrapper so fixtures are never mutated in place.
CLONE_FLAGS="-cR"
CP_PROBE_SRC="$(mktemp -t cp-probe-src-XXXXXX 2>/dev/null || echo "")"
CP_PROBE_DST="$(mktemp -u -t cp-probe-dst-XXXXXX 2>/dev/null || echo "")"
if [ -n "$CP_PROBE_SRC" ] && [ -n "$CP_PROBE_DST" ]; then
  if ! cp -c "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null; then
    CLONE_FLAGS="-R"
  fi
  rm -f "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null
else
  CLONE_FLAGS="-R"
fi

ISOLATED_DIR="$(mktemp -d -t "codex-eval-XXXXXX")"
cleanup() {
  if [ "${KEEP_ISOLATED:-0}" = "1" ]; then
    echo "codex-promptfoo-wrapper: KEEP_ISOLATED=1, leaving $ISOLATED_DIR" >&2
  else
    rm -rf "$ISOLATED_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM HUP

CP_CMD=(cp "$CLONE_FLAGS" "$WORKDIR/." "$ISOLATED_DIR/")

# codex exec: non-interactive, JSONL events on stdout, no sandbox/approval prompts
# (autonomous eval run), skip the git-repo guard (fixtures need not be repos), and
# `-C` sets the agent's working root to the isolated fixture.
CMD=(codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -C "$ISOLATED_DIR")

# Optional plugin-under-test: point CODEX_HOME at a pre-seeded home that enables +
# trusts the WORKTREE plugin (see evals/tdd/README.md). When unset, the installed
# `zensu@zensu` plugin (already trusted in ~/.codex/config.toml) is used.
if [ -n "${ZENSU_CODEX_HOME_OVERRIDE:-}" ] && [ -d "$ZENSU_CODEX_HOME_OVERRIDE" ]; then
  export CODEX_HOME="$ZENSU_CODEX_HOME_OVERRIDE"
fi
CMD+=("$FULL_PROMPT")

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would isolate (cwd=$WORKDIR -> isolated=$ISOLATED_DIR):"
  printf '  %q' "${CP_CMD[@]}"
  echo
  echo "DRY_RUN: would execute:"
  printf '  %q' "${CMD[@]}"
  echo
  echo "DRY_RUN: CODEX_HOME=${CODEX_HOME:-<default ~/.codex>}"
  exit 0
fi

# Real run only — DRY_RUN previews above never need the codex CLI installed.
if ! command -v codex >/dev/null 2>&1; then
  echo "codex-promptfoo-wrapper: codex CLI not found on PATH — install the Codex CLI." >&2
  exit 127
fi

if [ ! -d "$WORKDIR" ]; then
  echo "codex-promptfoo-wrapper: cannot cd to working_dir='$WORKDIR'" >&2
  exit 2
fi

if ! "${CP_CMD[@]}" 2>/dev/null; then
  echo "codex-promptfoo-wrapper: failed to clone working_dir='$WORKDIR' into '$ISOLATED_DIR'" >&2
  exit 2
fi

echo "codex-promptfoo-wrapper: isolated working dir: $ISOLATED_DIR" >&2

# `-C` already sets codex's working root; still cd so the post-run `.zensu/`
# extraction below resolves relative paths against the isolated fixture.
cd "$ISOLATED_DIR" || {
  echo "codex-promptfoo-wrapper: cannot cd to isolated dir='$ISOLATED_DIR'" >&2
  exit 2
}

# The TDD witness / git-diff path expects a git repo; seed one if the cloned
# fixture is not already a checkout. (--self-check exits at DRY_RUN and never
# reaches here.)
if ! git -C "$ISOLATED_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ( cd "$ISOLATED_DIR" && git init -q && git config user.email eval@eval \
      && git config user.name eval && git add -A && git commit -qm "eval fixture" ) >/dev/null 2>&1 || true
fi

# Which plugin does this live run actually exercise? Surface it so a run can
# never silently mis-target: the installed zensu@zensu marketplace source points
# at the origin repo, NOT this worktree, unless ZENSU_CODEX_HOME_OVERRIDE is set.
if [ -n "${CODEX_HOME:-}" ]; then
  echo "codex-promptfoo-wrapper: eval target = WORKTREE plugin (CODEX_HOME=$CODEX_HOME)" >&2
else
  echo "codex-promptfoo-wrapper: eval target = INSTALLED zensu@zensu (origin) — set ZENSU_CODEX_HOME_OVERRIDE to eval the worktree plugin" >&2
fi

export ZENSU_HOOK_LOG="$ISOLATED_DIR/.zensu/hook-events.log"
mkdir -p "$(dirname "$ZENSU_HOOK_LOG")" 2>/dev/null || true
: > "$ZENSU_HOOK_LOG" 2>/dev/null || true

# Scrub inherited session ids so the eval'd codex resolves ITS OWN thread id —
# an outer claude/codex session driving this wrapper must not leak into the
# plugin's env-tier session resolution inside the isolated run.
CODEX_RAW="$(env -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID "${CMD[@]}" 2>/dev/null)"
CODEX_RC=$?

# Flatten codex JSONL events to readable text for substring asserts. Codex event
# shapes vary by version, so pull any agent/message text + command lines
# defensively and fall back to the raw stream when the filter yields nothing.
FLAT="$(printf '%s\n' "$CODEX_RAW" | jq -rs '
  map(
    ( .item.text // .item.message
      // ( .item.command // empty | "[command] \(.)" )
      // .text // .message
      // ( if (.type // "") == "turn.completed" then (.turn.output_text // .output // "") else empty end )
      // empty )
  )
  | map(select(type == "string" and . != ""))
  | join("\n")
' 2>/dev/null)"
if [ -n "$FLAT" ]; then printf '%s\n' "$FLAT"; else printf '%s\n' "$CODEX_RAW"; fi

if [ -s "$ZENSU_HOOK_LOG" ]; then
  echo ""
  echo "===== hook events ====="
  cat "$ZENSU_HOOK_LOG"
fi

SAW_STATE=0
shopt -s nullglob
for sf in "$ISOLATED_DIR"/.zensu/state/tdd-phase-*.json; do
  [ -f "$sf" ] || continue
  SAW_STATE=1
  echo ""
  echo "===== fsm state: $(basename "$sf") ====="
  jq -r '
    "[fsm-state-final] phase=\(.phase // "UNINITIALIZED") step=\(.step_id // "?") chainDone=\(.chainDone // false) implComplete=\(.implComplete // false)",
    ((.history // []) | map("[fsm-history] step=\(.step // "?") phase=\(.phase // "?") ts=\(.ts // "?")") | join("\n"))
  ' "$sf" 2>/dev/null
done
shopt -u nullglob

if [ "$SAW_STATE" = "0" ] && [ -s "$ZENSU_HOOK_LOG" ] && grep -qE 'Current phase: UNINITIALIZED[,.]' "$ZENSU_HOOK_LOG"; then
  echo ""
  echo "[fsm-state-final] phase=UNINITIALIZED step=(none) chainDone=false implComplete=false"
fi

shopt -s nullglob
for wf in "$ISOLATED_DIR"/.zensu/logs/witness-*.log; do
  [ -f "$wf" ] || continue
  echo ""
  echo "===== witness: $(basename "$wf") ====="
  cat "$wf"
done
shopt -u nullglob

exit "$CODEX_RC"
