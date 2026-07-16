#!/bin/bash
set -u
export ZENSU_BASH_START="${ZENSU_BASH_START:-}"
CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

case "${1:-}" in
  --phase)
    phase_val=""
    step_val=""
    session_val=""
    reason_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --phase)   phase_val="${2:-}";   shift 2 || break ;;
        --step)    step_val="${2:-}";    shift 2 || break ;;
        --session) session_val="${2:-}"; shift 2 || break ;;
        --reason)  reason_val="${2:-}";  shift 2 || break ;;
        *) shift ;;
      esac
    done
    if [ -z "$phase_val" ]; then
      echo "zensu-log.sh --phase requires a phase value" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: session identity unavailable; refusing workflow mutation" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    tdd_write_phase "$session_val" "$step_val" "$phase_val" "$reason_val"
    exit $?
    ;;
  --mode)
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: session identity unavailable; refusing workflow read" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    state_file="$(tdd_state_file "$session_val")" || exit 1
    mode_value="$(tdd_vanilla_mode "$state_file")"
    case "$mode_value" in
      true) echo "vanilla" ;;
      false) echo "strict" ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
  --tdd-begin|--tdd-complete|--chain-done|--code-review-done|--self-review-fixed|--tdd-reset)
    verb="$1"
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 || break ;;
        *) shift ;;
      esac
    done
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    if ! session_val="$(zensu_resolve_session_id "$session_val")" || [ -z "$session_val" ]; then
      echo "zensu-log.sh: session identity unavailable; refusing workflow mutation" >&2
      exit 2
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --tdd-begin)
        if zensu_tdd_strict_enabled; then
          mode_flag_val="false"
        else
          mode_flag_val="true"
        fi
        if tdd_begin_session "$session_val" "$mode_flag_val"; then
          tdd_begin_rc=0
          [ "$mode_flag_val" = "true" ] && echo "mode: vanilla" || echo "mode: strict"
        else
          tdd_begin_rc=1
          echo "zensu-log --tdd-begin: atomic workflow initialization failed — session NOT activated" >&2
        fi
        exit "$tdd_begin_rc"
        ;;
      --tdd-complete) tdd_set_flag "$session_val" implComplete true ;;
      --chain-done)   tdd_set_flag "$session_val" chainDone true ;;
      --code-review-done)  tdd_set_flag "$session_val" codeReviewDone true ;;
      --self-review-fixed) tdd_set_flag "$session_val" selfReviewFixed true ;;
      --tdd-reset)    tdd_clear_session "$session_val" ;;
    esac
    exit $?
    ;;
esac

cmd="${1:-timestamp}"
case "$cmd" in
  timestamp)
    start="${2:-$(date +%s)}"
    case "$start" in
      ''|*[!0-9]*) start=$(date +%s) ;;
    esac
    style=$(_zensu_log_style)
    case "$style" in
      none)
        printf ""
        ;;
      relative)
        now=$(date +%s)
        diff=$((now - 10#$start))
        [ "$diff" -lt 0 ] && diff=0
        if [ "$diff" -lt 86400 ]; then
          printf "[+%02d:%02d:%02d] " $((diff/3600)) $(((diff%3600)/60)) $((diff%60))
        else
          days=$((diff/86400))
          rem=$((diff%86400))
          printf "[+%dd %02d:%02d:%02d] " "$days" $((rem/3600)) $(((rem%3600)/60)) $((rem%60))
        fi
        ;;
      *)
        printf "[%s] " "$(date +%H:%M:%S)"
        ;;
    esac
    ;;
  style)
    _zensu_log_style
    ;;
  *)
    echo "usage: zensu-log.sh {timestamp <epoch> | style}" >&2
    exit 2
    ;;
esac
