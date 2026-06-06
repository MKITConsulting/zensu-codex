#!/bin/bash

_zensu_resolve_config() {
  if [ -n "${ZENSU_CONFIG:-}" ]; then
    echo "$ZENSU_CONFIG"
    return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.zensu/config.json" ]; then
    echo "$CLAUDE_PROJECT_DIR/.zensu/config.json"
    return 0
  fi
  echo "$HOME/.zensu/config.json"
}

zensu_hook_enabled() {
  local key="$1"
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && return 0
  command -v node >/dev/null 2>&1 || return 0   # node missing → fall back to enabled
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      console.log(j.hooks && j.hooks[process.argv[2]] === false ? '0' : '1');
    } catch (_) { console.log('1'); }
  " "$config" "$key" 2>/dev/null)
  [ -z "$val" ] && return 0                      # any other failure → enabled
  [ "$val" = "1" ]
}

_zensu_log_style() {
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && { echo "wall"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "wall"; return 0; }
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const s = j.logging && j.logging.timestampStyle;
      console.log(s === 'relative' || s === 'none' ? s : 'wall');
    } catch (_) { console.log('wall'); }
  " "$config" 2>/dev/null)
  [ -z "$val" ] && { echo "wall"; return 0; }
  echo "$val"
}

zensu_autofix_include_suggestions() {
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && return 1
  command -v node >/dev/null 2>&1 || return 1
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      console.log(j.hooks && j.hooks.autoFixIncludeSuggestions === true ? '1' : '0');
    } catch (_) { console.log('0'); }
  " "$config" 2>/dev/null)
  [ "$val" = "1" ]
}

zensu_combined_summary_enabled() {
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && return 0
  command -v node >/dev/null 2>&1 || return 0
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      console.log(j.hooks && j.hooks.combinedSummary === false ? '0' : '1');
    } catch (_) { console.log('1'); }
  " "$config" 2>/dev/null)
  [ "$val" = "1" ]
}

zensu_autofix_max_rounds() {
  local default=5
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && { echo "$default"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const n = j.hooks && j.hooks.autoFixMaxRounds;
      if (Number.isInteger(n) && n > 0 && n <= 99) {
        console.log(String(n));
      } else {
        console.log('$default');
      }
    } catch (_) { console.log('$default'); }
  " "$config" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

zensu_context_nudge_enabled() {
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && return 0
  command -v node >/dev/null 2>&1 || return 0
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      console.log(j.context && j.context.compactionNudge === false ? '0' : '1');
    } catch (_) { console.log('1'); }
  " "$config" 2>/dev/null)
  [ -z "$val" ] && return 0
  [ "$val" = "1" ]
}

zensu_context_nudge_threshold() {
  local default=50
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && { echo "$default"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const n = j.context && j.context.nudgeThreshold;
      if (Number.isInteger(n) && n >= 1 && n <= 99) {
        console.log(String(n));
      } else {
        console.log('$default');
      }
    } catch (_) { console.log('$default'); }
  " "$config" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

zensu_context_window_size() {
  # Echoes the configured context.windowSize, or empty when unset/invalid so the
  # caller can auto-detect the tier (200k vs 1M) from observed usage. Hooks are
  # not handed the real window size, so there is no safe numeric default here.
  local config
  config="$(_zensu_resolve_config)"
  [ ! -f "$config" ] && return 0
  command -v node >/dev/null 2>&1 || return 0
  node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      const n = j.context && j.context.windowSize;
      if (Number.isInteger(n) && n >= 1000 && n <= 100000000) console.log(String(n));
    } catch (_) {}
  " "$config" 2>/dev/null
}
