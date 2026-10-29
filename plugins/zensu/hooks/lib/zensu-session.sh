#!/bin/bash

zensu_resolve_error() {
  ZENSU_RESOLVE_ERROR="$(printf '%s' "${1:-}" | tr -d '\r' | tr '\n' ' ' | head -c 300)"
  return 1
}

zensu_resolve_session_id() {
  local raw="${1:-}"
  local lib_dir core resolved trusted
  ZENSU_RESOLVE_ERROR=''
  trusted="${ZENSU_SESSION_KEY:-}"
  if [ -n "$trusted" ]; then
    [ "${#trusted}" -eq 69 ] || { zensu_resolve_error 'ZENSU_SESSION_KEY has an invalid length'; return 1; }
    [[ "$trusted" =~ ^scv1_[a-f0-9]{64}$ ]] || { zensu_resolve_error 'ZENSU_SESSION_KEY has an invalid format'; return 1; }
  fi
  if [ -z "$raw" ]; then
    if [ -n "$trusted" ]; then
      raw="$trusted"
    else
      zensu_resolve_error 'no session id was supplied and ZENSU_SESSION_KEY is unset'
      return 1
    fi
  fi
  command -v node >/dev/null 2>&1 || { zensu_resolve_error 'node is not on PATH'; return 1; }
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || { zensu_resolve_error 'hook library directory is unresolvable'; return 1; }
  core="$lib_dir/session-control-core-v1.js"
  [ -f "$core" ] || { zensu_resolve_error 'session-control-core-v1.js is missing'; return 1; }
  resolved="$(node "$core" session-key "$raw" 2>&1)" || { zensu_resolve_error "session key derivation failed: $resolved"; return 1; }
  if [ -n "$trusted" ] && [ "$resolved" != "$trusted" ]; then
    zensu_resolve_error 'resolved session key does not match ZENSU_SESSION_KEY'
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
  ZENSU_RESOLVE_ERROR=''
  [ "${#trusted}" -eq 69 ] || { zensu_resolve_error 'ZENSU_SESSION_KEY has an invalid length'; return 1; }
  [[ "$trusted" =~ ^scv1_[a-f0-9]{64}$ ]] || { zensu_resolve_error 'ZENSU_SESSION_KEY has an invalid format'; return 1; }
  [ -f "$reader" ] && [ ! -L "$reader" ] || { zensu_resolve_error 'stable reader resolve-v3.js is missing or a symlink'; return 1; }
  candidate="$(node "$reader" --field project_root 2>&1)" || { zensu_resolve_error "stable reader refused: $candidate"; return 1; }
  [ ! -L "$candidate" ] || { zensu_resolve_error 'resolved project root is a symlink'; return 1; }
  [ -d "$candidate" ] || { zensu_resolve_error 'resolved project root is not a directory'; return 1; }
  (cd "$candidate" 2>/dev/null && pwd -P)
}

export -f zensu_session_key zensu_resolve_session_id zensu_resolve_project_dir zensu_resolve_error 2>/dev/null || true
