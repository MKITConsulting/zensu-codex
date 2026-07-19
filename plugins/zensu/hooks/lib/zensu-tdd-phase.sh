#!/bin/bash
set -u

CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

_tdd_context_binding() {
  local session_id="${1:-}" key record records
  key="$(zensu_resolve_session_id "$session_id")" || return 1
  if [ -n "${ZENSU_SESSION_CONTEXT:-}" ]; then
    record="$ZENSU_SESSION_CONTEXT"
    [ "$(basename "$record")" = "$key.json" ] || return 1
    records="$(dirname "$record")"
    printf '%s\n%s\n' claude "$records"
    return 0
  fi
  records="${HOME:-}/.zensu/session-control/codex/v3/records"
  [ -f "$records/$key.json" ] && [ ! -L "$records/$key.json" ] || return 1
  printf '%s\n%s\n' codex "$records"
}

tdd_activation_status() {
  local session_id="${1:-}" key binding state_file status active
  key="$(zensu_resolve_session_id "$session_id")" || { echo invalid; return 0; }
  binding="$(_tdd_context_binding "$key")" || { echo inactive; return 0; }
  state_file="$(tdd_state_file "$key")" || { echo invalid; return 0; }
  status="$(tdd_state_status "$state_file")"
  [ "$status" = "valid" ] || { echo invalid; return 0; }
  active="$(tdd_session_active "$state_file")"
  [ "$active" = "true" ] && echo active || echo inactive
}

tdd_state_file() {
  local session_id="${1:-}"
  local resolved project_root
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  resolved="$(zensu_resolve_session_id "$session_id")" || return 1
  project_root="$(zensu_resolve_project_dir)" || return 1
  echo "${project_root}/.zensu/state/tdd-phase-${resolved}.json"
}

_tdd_bound_project_root() {
  local state_file="${1:-}" session_id="${2:-}" expected project_root
  [ -n "$state_file" ] && [ -n "$session_id" ] || return 1
  expected="$(tdd_state_file "$session_id")" || return 1
  [ "$state_file" = "$expected" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || return 1
  [ "$expected" = "$project_root/.zensu/state/tdd-phase-${session_id}.json" ] || return 1
  printf '%s\n' "$project_root"
}

_tdd_begin_critical() {
  local state_file="$1"
  local session_id="$2"
  local vanilla="$3"
  local project_root
  project_root="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" SID="$session_id" VANILLA="$vanilla" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "active",
        event: "tdd-begin",
      }, () => ({
        active: true,
        vanilla: process.env.VANILLA === "true",
        implComplete: false,
        chainDone: false,
        codeReviewDone: false,
        selfReviewFixed: false,
        workflowActive: false,
        workflowTools: [],
        bypasses: [],
        reviewRound: 0,
        stopBlocks: 0,
        phase: "UNINITIALIZED",
        step_id: "",
        history: [],
      }));
    ' 2>/dev/null
}

tdd_begin_session() {
  local supplied_session="${1:-}" vanilla="${2:-}" session_id state_file
  case "$vanilla" in true|false) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_begin_critical "$state_file" "$session_id" "$vanilla"
}

tdd_is_test_path() {
  local path="${1:-}"
  [ -z "$path" ] && { echo "false"; return 0; }

  if [ -L "$path" ]; then
    echo "false"; return 0
  fi

  local lower
  lower=$(echo "$path" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|*/specs/*)
      echo "true"; return 0 ;;
    test/*|tests/*|__tests__/*|spec/*|specs/*)
      echo "true"; return 0 ;;
  esac

  local base
  base=$(basename "$path")

  case "$base" in
    test_*|*_test.*|*_tests.*|*.test.*|*.tests.*|*.spec.*|*.specs.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  local lower_base
  lower_base=$(echo "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower_base" in
    *_test.*|*_tests.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  if [ -f "$path" ]; then
    local link_count
    link_count=$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path" 2>/dev/null || echo "1")
    if [ "${link_count:-1}" -gt 1 ] 2>/dev/null; then
      echo "false"; return 0
    fi
    local header
    header=$(head -n 20 "$path" 2>/dev/null | sed $'1s/^\xef\xbb\xbf//' 2>/dev/null || true)
    if printf '%s\n' "$header" | grep -Eq '^(func Test|describe\(|it\(|test\(|@Test|def test_)' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[test\]' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[cfg\(test\)\]' 2>/dev/null; then
      echo "true"; return 0
    fi
  fi

  echo "false"
}

_tdd_write_phase_critical() {
  local state_file="$1"
  local session_id="$2"
  local step_id="$3"
  local phase="$4"
  local reason="$5"
  local ts="$6"
  local project_root

  project_root="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" SID="$session_id" STEP="$step_id" PHASE="$phase" REASON="$reason" TS="$ts" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: process.env.PHASE.toLowerCase(),
        event: "phase-" + process.env.PHASE.toLowerCase(),
        updatedAt: process.env.TS || undefined,
      }, (state) => {
        if (!Array.isArray(state.history)) state.history = [];
        const entry = { step: process.env.STEP, phase: process.env.PHASE };
        if (process.env.TS) entry.ts = process.env.TS;
        if (process.env.REASON) entry.reason = process.env.REASON;
        state.history.push(entry);
        state.step_id = process.env.STEP;
        state.phase = process.env.PHASE;
        return state;
      });
    ' 2>/dev/null
}

tdd_write_phase() {
  local supplied_session="${1:-}"
  local session_id
  local step_id="${2:-}"
  local phase="${3:-}"
  local reason="${4:-}"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1

  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
}

# --- Chain-state flags (active / implComplete / chainDone) ----------------
# These live in the SAME per-session state file as the FSM phase. They drive
# main-thread hook activation (active), the Stop-hook review gate
# (implComplete), and chain termination (chainDone). All writes go through the
# shared Session Control CAS transaction so concurrent phase/flag writes cannot
# clobber each other or reset an invalid revision.

_tdd_write_flag_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  local val="$4"
  local project_root

  project_root="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" SID="$session_id" KEY="$key" VAL="$val" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const value = process.env.VAL === "true";
      const names = {
        vanilla: "configured",
        active: value ? "active" : "idle",
        implComplete: "implementation_complete",
        chainDone: "complete",
        codeReviewDone: "code_review_complete",
        selfReviewFixed: "self_review_fixed"
      };
      const event = "flag-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase() + "-" + String(value);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY] || "control",
        event,
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state[process.env.KEY] = value;
        if (process.env.KEY === "active" && value) {
          state.reviewRound = 0;
          state.stopBlocks = 0;
        }
        if (process.env.KEY === "codeReviewDone" && value) state.stopBlocks = 0;
        return state;
      });
    ' 2>/dev/null
}

_tdd_increment_counter_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  local project_root

  project_root="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" SID="$session_id" KEY="$key" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const names = { reviewRound: "review_progress", stopBlocks: "stop_guard" };
      if (!Object.prototype.hasOwnProperty.call(names, process.env.KEY)) process.exit(2);
      const next = core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY],
        event: "counter-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase(),
      }, (state) => {
        if (state.active !== true) throw new Error("counter mutation requires an active workflow");
        const current = state[process.env.KEY] === undefined ? 0 : state[process.env.KEY];
        if (!Number.isSafeInteger(current) || current < 0 || current >= 1000000) {
          throw new Error("counter is invalid or exhausted");
        }
        state[process.env.KEY] = current + 1;
        if (process.env.KEY === "reviewRound") state.stopBlocks = 0;
        return state;
      });
      process.stdout.write(String(next[process.env.KEY]));
    ' 2>/dev/null
}

tdd_increment_counter() {
  local supplied_session="${1:-}"
  local key="${2:-}"
  local session_id state_file
  case "$key" in reviewRound|stopBlocks) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")"
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_increment_counter_critical "$state_file" "$session_id" "$key"
}

tdd_reset_review_budget() {
  local supplied_session="${1:-}" expected_revision="${2:-}" session_id state_file
  case "$expected_revision" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected_revision" -ge 1 ] 2>/dev/null || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" EXPECTED_REVISION="$expected_revision" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const state = core.resetReviewBudget({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        expectedRevision: Number(process.env.EXPECTED_REVISION),
      });
      process.stdout.write(JSON.stringify(state));
    ' 2>/dev/null
}

tdd_set_flag() {
  local supplied_session="${1:-}"
  local session_id
  local key="${2:-}"
  local val="${3-true}"
  [ -z "$key" ] && return 1
  case "$val" in true|false) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_flag_critical "$state_file" "$session_id" "$key" "$val"
}

_tdd_write_clear_critical() {
  local state_file="$1"
  local session_id="$2"
  local project_root
  project_root="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "idle",
      event: "session-reset",
    }, (s) => {
      return {
        active: false,
        vanilla: false,
        implComplete: false,
        chainDone: false,
        codeReviewDone: false,
        selfReviewFixed: false,
        workflowActive: false,
        workflowTools: [],
        bypasses: [],
        reviewRound: 0,
        stopBlocks: 0,
        phase: "UNINITIALIZED",
        step_id: "",
        history: [],
      };
    });
  ' 2>/dev/null
}

tdd_clear_session() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_clear_critical "$state_file" "$session_id"
}

_tdd_read_validated_state() {
  local state_file="${1:-}"
  local mode="${2:-status}"
  local arg="${3:-}"
  local state_key project_root
  if [ -z "$state_file" ]; then
    echo "missing"; return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "invalid"; return 0
  fi

  state_key="$(basename "$state_file" | sed -n 's/^tdd-phase-\(scv1_[a-f0-9]\{64\}\)\.json$/\1/p')"
  if [ -z "$state_key" ] || ! project_root="$(_tdd_bound_project_root "$state_file" "$state_key")"; then
    echo "invalid"; return 0
  fi

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" STATE_FILE="$state_file" PROJECT_ROOT="$project_root" READ_MODE="$mode" READ_ARG="$arg" \
    node -e '
      const fs = require("node:fs");
      const path = require("node:path");
      const emit = (status, value) => {
        process.stdout.write(status);
        if (status === "valid" && value !== undefined) process.stdout.write("\n" + String(value));
      };
      const file = process.env.STATE_FILE || "";
      const match = /^tdd-phase-(scv1_[a-f0-9]{64})\.json$/.exec(path.basename(file));
      if (!match) { emit("invalid"); process.exit(0); }
      let stat;
      try { stat = fs.lstatSync(file); }
      catch (error) { emit(error && error.code === "ENOENT" ? "missing" : "invalid"); process.exit(0); }
      if (stat.isSymbolicLink() || !stat.isFile()) { emit("invalid"); process.exit(0); }
      let state;
      try {
        const core = require(process.env.CONTROL_CORE);
        state = core.readWorkflowState({ projectRoot: process.env.PROJECT_ROOT, sessionId: match[1] });
      } catch (_) { emit("invalid"); process.exit(0); }

      const mode = process.env.READ_MODE || "status";
      const arg = process.env.READ_ARG || "";
      if (mode === "status") emit("valid");
      else if (mode === "flag") emit("valid", state[arg] === true ? "true" : "false");
      else if (mode === "phase") emit("valid", state.phase === undefined ? "UNINITIALIZED" : state.phase);
      else if (mode === "step") emit("valid", state.step_id === undefined ? "" : state.step_id);
      else if (mode === "counter") {
        const value = state[arg] === undefined ? 0 : state[arg];
        if (!Number.isSafeInteger(value) || value < 0) emit("invalid");
        else emit("valid", value);
      }
      else if (mode === "red-fail") {
        const hit = Array.isArray(state.history)
          && state.history.some(entry => entry.step === arg && entry.phase === "RED_FAIL");
        emit("valid", hit ? "true" : "false");
      } else emit("invalid");
    ' 2>/dev/null || echo "invalid"
}

tdd_state_status() {
  local result
  result="$(_tdd_read_validated_state "${1:-}" status)"
  case "$result" in valid|missing|invalid) echo "$result" ;; *) echo "invalid" ;; esac
}

tdd_get_flag() {
  local state_file="${1:-}"
  local key="${2:-}"
  if [ -z "$key" ]; then
    echo "false"; return 0
  fi
  case "$key" in
    active|vanilla|implComplete|chainDone|codeReviewDone|selfReviewFixed|workflowActive) ;;
    *) echo "invalid"; return 0 ;;
  esac
  local result status value
  result="$(_tdd_read_validated_state "$state_file" flag "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}

tdd_session_active()    { tdd_get_flag "${1:-}" active; }
tdd_vanilla_mode()      { tdd_get_flag "${1:-}" vanilla; }
tdd_impl_complete()     { tdd_get_flag "${1:-}" implComplete; }
tdd_chain_done()        { tdd_get_flag "${1:-}" chainDone; }
tdd_code_review_done()  { tdd_get_flag "${1:-}" codeReviewDone; }
tdd_self_review_fixed() { tdd_get_flag "${1:-}" selfReviewFixed; }

tdd_get_counter() {
  local state_file="${1:-}"
  local key="${2:-}"
  local result status value
  case "$key" in reviewRound|stopBlocks) ;; *) echo "invalid"; return 0 ;; esac
  result="$(_tdd_read_validated_state "$state_file" counter "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "0"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  value="${result#*$'\n'}"
  case "$value" in ''|*[!0-9]*) echo "invalid" ;; *) echo "$value" ;; esac
}

tdd_phase() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" phase)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "UNINITIALIZED"; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value="UNINITIALIZED"
  echo "$value"
}

tdd_step() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" step)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo ""; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value=""
  echo "$value"
}

tdd_has_red_fail() {
  local state_file="${1:-}"
  local step="${2:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" red-fail "$step")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}

export -f _tdd_context_binding tdd_activation_status tdd_state_file _tdd_bound_project_root _tdd_begin_critical tdd_begin_session tdd_is_test_path tdd_write_phase _tdd_write_phase_critical _tdd_read_validated_state tdd_state_status tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_increment_counter_critical tdd_increment_counter tdd_reset_review_budget _tdd_write_clear_critical tdd_clear_session tdd_get_flag tdd_get_counter tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed 2>/dev/null || true
