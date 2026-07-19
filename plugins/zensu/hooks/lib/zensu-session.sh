#!/bin/bash

zensu_resolve_session_id() {
  local raw="${1:-}"
  local lib_dir core resolved trusted
  trusted="${ZENSU_SESSION_KEY:-}"
  if [ -n "$trusted" ]; then
    [ "${#trusted}" -eq 69 ] || return 1
    [[ "$trusted" =~ ^scv1_[a-f0-9]{64}$ ]] || return 1
  fi
  if [ -z "$raw" ]; then
    if [ -n "$trusted" ]; then
      raw="$trusted"
    else
      return 1
    fi
  fi
  command -v node >/dev/null 2>&1 || return 1
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  core="$lib_dir/session-control-core-v1.js"
  [ -f "$core" ] || return 1
  resolved="$(node "$core" session-key "$raw")" || return 1
  if [ -n "$trusted" ] && [ "$resolved" != "$trusted" ]; then
    return 1
  fi
  printf '%s\n' "$resolved"
}

zensu_session_key() {
  zensu_resolve_session_id "${1:-}"
}

zensu_resolve_project_dir() {
  local candidate trusted="${ZENSU_SESSION_KEY:-}"
  local reader="${HOME:-}/.zensu/session-control/codex/v3/resolve-v3.js"
  [ "${#trusted}" -eq 69 ] || return 1
  [[ "$trusted" =~ ^scv1_[a-f0-9]{64}$ ]] || return 1
  [ -f "$reader" ] && [ ! -L "$reader" ] || return 1
  candidate="$(node "$reader" --field project_root 2>/dev/null)" || return 1
  [ ! -L "$candidate" ] || return 1
  [ -d "$candidate" ] || return 1
  (cd "$candidate" 2>/dev/null && pwd -P)
}

export -f zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
