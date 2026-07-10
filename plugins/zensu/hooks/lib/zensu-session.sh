#!/bin/bash

zensu_session_key() {
  local proc_start proc_hash
  proc_start="$(LC_ALL=C ps -o lstart= -p "$PPID" 2>/dev/null)"
  if [ -n "$proc_start" ]; then
    proc_hash="$(printf '%s' "$proc_start" | cksum 2>/dev/null | cut -d' ' -f1)"
  fi
  if [ -n "${proc_hash:-}" ]; then
    echo "${PPID}_${proc_hash}"
  else
    echo "${PPID}"
  fi
}

zensu_resolve_session_via_helper() {
  local helper_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$helper_root" ]; then
    helper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  fi
  local helper="${helper_root}/hooks/lib/resolve-session-id.js"
  [ -f "$helper" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  local out
  out="$(node "$helper" "${ZENSU_BASH_START:-}" 2>/dev/null)"
  out="${out//$'\n'/}"
  out="${out//$'\r'/}"
  if [ -n "$out" ]; then
    local sanitized="${out//[^A-Za-z0-9_-]/_}"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  return 1
}

_zensu_sanitize_sid() {
  local s="${1//[^A-Za-z0-9_-]/_}"
  printf '%s' "${s:0:64}"
}

zensu_resolve_session_id() {
  local from_json="${1:-}"
  local sanitized key cache cached helper_out from_env
  if [ -n "$from_json" ]; then
    sanitized="$(_zensu_sanitize_sid "$from_json")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  from_env="${CODEX_THREAD_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -n "$from_env" ]; then
    sanitized="$(_zensu_sanitize_sid "$from_env")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  cache="${CLAUDE_PROJECT_DIR:-.}/.zensu/state/session-id-current.txt"
  if [ -f "$cache" ]; then
    cached="$(cat "$cache" 2>/dev/null)"
    cached="${cached//$'\n'/}"
    cached="${cached//$'\r'/}"
    sanitized="$(_zensu_sanitize_sid "$cached")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  if helper_out="$(zensu_resolve_session_via_helper)"; then
    helper_out="$(_zensu_sanitize_sid "$helper_out")"
    if [ -n "$helper_out" ]; then
      echo "$helper_out"
      return 0
    fi
  fi
  key="$(zensu_session_key)"
  cache="${CLAUDE_PROJECT_DIR:-.}/.zensu/state/session-id-${key}.txt"
  if [ -f "$cache" ]; then
    cached="$(cat "$cache" 2>/dev/null)"
    cached="${cached//$'\n'/}"
    cached="${cached//$'\r'/}"
    sanitized="$(_zensu_sanitize_sid "$cached")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  echo "fallback_${key}"
}

export -f zensu_session_key zensu_resolve_session_via_helper _zensu_sanitize_sid zensu_resolve_session_id 2>/dev/null || true
