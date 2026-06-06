#!/bin/bash
# Engine-neutral runtime helpers shared by Zensu hooks. The same hook scripts
# run under both Codex CLI and Claude Code by normalizing the two host-provided
# values the rest of the suite depends on: the plugin root and the project dir.
#
# Plugin root: each hook resolves it on its first line with precedence
#   ZENSU_PLUGIN_ROOT > CODEX_PLUGIN_ROOT > CLAUDE_PLUGIN_ROOT > self-resolution
# (from the hook's own path) and then exports CLAUDE_PLUGIN_ROOT, so every
# `source "$CLAUDE_PLUGIN_ROOT/hooks/lib/..."` works unchanged on either host.
#
# Project dir: Claude Code exports $CLAUDE_PROJECT_DIR; Codex instead passes a
# "cwd" field in the hook stdin payload. zensu_runtime_apply_project_dir reads
# that "cwd" and exports CLAUDE_PROJECT_DIR when it is not already set, so the
# existing `${CLAUDE_PROJECT_DIR:-.}` references throughout the suite resolve to
# the real project root on Codex too. It is a no-op when the var is already set
# or when no payload / node is available (the `.` fallback then applies).

zensu_runtime_apply_project_dir() {
  local payload="${1:-}"
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && return 0
  [ -z "$payload" ] && return 0
  command -v node >/dev/null 2>&1 || return 0
  local cwd
  cwd="$(PAYLOAD="$payload" node -e 'try{const j=JSON.parse(process.env.PAYLOAD||"{}");const c=(typeof j.cwd==="string"&&j.cwd)?j.cwd:"";process.stdout.write(c);}catch(_){}' 2>/dev/null)"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    export CLAUDE_PROJECT_DIR="$cwd"
  fi
  return 0
}

export -f zensu_runtime_apply_project_dir 2>/dev/null || true
