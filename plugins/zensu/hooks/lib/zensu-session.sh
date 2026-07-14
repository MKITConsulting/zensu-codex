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

_zensu_sanitize_sid() {
  local s="${1//[^A-Za-z0-9_-]/_}"
  printf '%s' "${s:0:64}"
}

zensu_resolve_session_id() {
  local from_json="${1:-}"
  local sanitized key from_env
  if [ -n "$from_json" ]; then
    sanitized="$(_zensu_sanitize_sid "$from_json")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  # Codex hooks pass session_id explicitly in their JSON payload; model-issued
  # main-thread shell commands carry CODEX_THREAD_ID. A foreign
  # CLAUDE_SESSION_ID inherited from an outer host is intentionally ignored.
  from_env="${CODEX_THREAD_ID:-}"
  if [ -n "$from_env" ]; then
    sanitized="$(_zensu_sanitize_sid "$from_env")"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  key="$(zensu_session_key)"
  echo "fallback_${key}"
}

export -f zensu_session_key _zensu_sanitize_sid zensu_resolve_session_id 2>/dev/null || true
