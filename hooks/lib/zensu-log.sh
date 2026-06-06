#!/bin/bash
set -u
export ZENSU_BASH_START="${ZENSU_BASH_START:-}"
: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

case "${1:-}" in
  --phase)
    phase_val=""
    step_val=""
    session_val=""
    reason_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --phase)   phase_val="${2:-}";   shift 2 ;;
        --step)    step_val="${2:-}";    shift 2 ;;
        --session) session_val="${2:-}"; shift 2 ;;
        --reason)  reason_val="${2:-}";  shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$phase_val" ]; then
      echo "zensu-log.sh --phase requires a phase value" >&2
      exit 2
    fi
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 --phase $phase_val --step $step_val}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    tdd_write_phase "$session_val" "$step_val" "$phase_val" "$reason_val"
    exit $?
    ;;
  --tdd-begin|--tdd-complete|--chain-done|--code-review-done|--self-review-fixed|--tdd-reset)
    verb="$1"
    session_val=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --session) session_val="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -z "$session_val" ]; then
      export ZENSU_OWN_CMD="${ZENSU_OWN_CMD:-bash $0 $verb}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_val="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"
    fi
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
    case "$verb" in
      --tdd-begin)
        tdd_set_flag "$session_val" active true
        tdd_begin_rc=$?
        rounds_state_dir="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
        rounds_counter_file="${rounds_state_dir}/rounds-${session_val}.json"
        if [ -L "$rounds_counter_file" ]; then
          echo "zensu-log --tdd-begin: refusing to delete through symlink at $rounds_counter_file — rounds counter NOT reset" >&2
        elif [ -L "$rounds_state_dir" ]; then
          echo "zensu-log --tdd-begin: refusing to reset under symlinked state dir $rounds_state_dir — rounds counter NOT reset" >&2
        else
          rm -f -- "$rounds_counter_file"
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
