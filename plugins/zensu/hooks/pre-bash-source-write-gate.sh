#!/bin/bash
# pre-bash-source-write-gate.sh — PreToolUse shell-tool (shell/Bash/exec_command/exec)
# integrity gate for source files.
#
# The plugin gates apply_patch/Edit/Write/MultiEdit (pre-edit-tdd-reminder.sh), but
# nothing inspected raw Bash commands that write to source files. A low-context
# agent can corrupt tracked source via `printf >> file.rs`, `cat > file.rs <<EOF`,
# `sed -i`, `tee`, `dd of=` — bypassing the edit gate — and worse, can `cd` into a
# sibling/main checkout and clobber another session's working tree. This hook
# closes both holes.
#
# It DENIES a write through one of those channels to a source-extension file when
# either:
#   (A) the file already exists and is git-tracked inside the project (clobbering
#       real tracked source), or
#   (B) the resolved path escapes the session root (CLAUDE_PROJECT_DIR / cwd) into
#       a sibling or main checkout — the cross-session contamination vector.
# Relative targets resolve against a cwd that tracks `cd` across the command, so
# `cd ../main && printf ... >> src/x.rs` is caught by (B).
#
# Engine portability: Codex fires PreToolUse for its shell tools (`shell`,
# `exec_command`, `exec`) and honors the deny schema below identically to Claude
# Code's `Bash`. The command arrives as `tool_input.command` (string or argv
# array), `tool_input.cmd`, `tool_input.input`, or a raw-string `tool_input`
# (the `exec` custom tool), plus a top-level `cwd`; the parser reads all of
# them, and zensu_runtime_apply_project_dir maps `cwd` into CLAUDE_PROJECT_DIR
# so rule (B)'s escape-root check resolves on Codex too.
#
# Deliberately NOT a security boundary — an agent can still bypass via the escape
# hatch (inline `ZENSU_BASH_WRITE_GATE=off` / `ZENSU_MCP_GATE=off`, the process-env
# equivalents, or config `hooks.bashWriteGate:false`). It is a discipline nudge:
# route source edits through the edit tools (observable, gate-aware) and stay
# inside your own worktree. Carve-outs never denied: a NEW file inside the project,
# gitignored/untracked files, non-source extensions, and temp roots ($TMPDIR, /tmp,
# /private/tmp, /var/folders). mv/cp are out of scope, as is the unified-exec
# write_stdin channel (input streamed into an already-running exec_command shell
# arrives as keystrokes, not as a parseable command payload).
set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

command -v node >/dev/null 2>&1 || exit 0

# Drain stdin before any early exit so an upstream writer never sees a broken
# pipe (mirrors post-bash-witness.sh's drain-before-exit ordering).
INPUT="$(cat 2>/dev/null || true)"

# Process-env escapes.
[ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && exit 0
[ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0

[ -z "$INPUT" ] && exit 0

# Codex passes the project root as a payload "cwd" field rather than exporting
# CLAUDE_PROJECT_DIR; normalize it so the parser's rule-(B) escape check resolves.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled bashWriteGate || exit 0

REASON="$(PAYLOAD="$INPUT" node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bash-source-write-parse.js" 2>/dev/null)"
[ -z "$REASON" ] && exit 0

REASON="$REASON" node -e '
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: process.env.REASON
    }
  }));
'
echo
exit 0
