#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

contains() {
  local label="$1" file="$2" literal="$3"
  grep -Fq -- "$literal" "$file" && check "$label" PASS || check "$label" FAIL
}

HOOKS="$PLUGIN/hooks/hooks.json"
CODE="$PLUGIN/agents/zensu-code-reviewer.toml"
ASPECT="$PLUGIN/agents/zensu-review-aspect.toml"
REF_CODE="$ROOT/reference/code-reviewer.md"
REF_ASPECT="$ROOT/reference/review-aspect.md"
TDD="$PLUGIN/skills/tdd/SKILL.md"

node -e '
  const h = require(process.argv[1]).hooks.PreToolUse;
  if (h[0]?.matcher !== ".*" || !h[0]?.hooks?.[0]?.command?.includes("pre-reviewer-capability-gate.sh")) process.exit(1);
' "$HOOKS" \
  && check "defense-in-depth reviewer gate is the first PreToolUse hook" PASS \
  || check "defense-in-depth reviewer gate wiring" FAIL

for file in "$CODE" "$ASPECT"; do
  contains "$(basename "$file") uses read-only sandbox" "$file" 'sandbox_mode = "read-only"'
  contains "$(basename "$file") disables approvals" "$file" 'approval_policy = "never"'
  contains "$(basename "$file") disables login shell" "$file" 'allow_login_shell = false'
  contains "$(basename "$file") disables web search" "$file" 'web_search = "disabled"'
  contains "$(basename "$file") disables image tools" "$file" 'view_image = false'
  if grep -qF 'ZENSU_AGENT_PROFILE' "$file"; then
    check "$(basename "$file") does not rely on an unpropagated environment marker" FAIL
  else
    check "$(basename "$file") does not rely on an unpropagated environment marker" PASS
  fi
  for feature in shell_tool unified_exec multi_agent apps goals; do
    awk -v feature="$feature" '
      /^\[features\]$/ { inside = 1; next }
      inside && /^\[/ { inside = 0 }
      inside && $0 ~ "^[[:space:]]*" feature "[[:space:]]*=[[:space:]]*false([[:space:]]*#.*)?$" { found = 1 }
      END { exit !found }
    ' "$file" \
      && check "$(basename "$file") disables host feature $feature" PASS \
      || check "$(basename "$file") host feature $feature" FAIL
  done
  if awk '
    /^\[mcp_servers\]$/ { inside = 1; found = 1; next }
    inside && /^\[/ { inside = 0 }
    inside && /^[[:space:]]*[^#[:space:]]/ { bad = 1 }
    END { exit !(found && !bad) }
  ' "$file"; then
    check "$(basename "$file") explicitly disables inherited MCP servers" PASS
  else
    check "$(basename "$file") empty mcp_servers table" FAIL
  fi
  awk '
    /^\[agents\]$/ { inside = 1; next }
    inside && /^\[/ { inside = 0 }
    inside && /^[[:space:]]*max_depth[[:space:]]*=[[:space:]]*1([[:space:]]*#.*)?$/ { found = 1 }
    END { exit !found }
  ' "$file" \
    && check "$(basename "$file") caps nesting at agents.max_depth=1" PASS \
    || check "$(basename "$file") agents.max_depth=1" FAIL
  contains "$(basename "$file") declares reviewer-readonly-v1" "$file" 'reviewer-readonly-v1'
  contains "$(basename "$file") requires REVIEW PACKET v1" "$file" 'REVIEW PACKET v1'
  contains "$(basename "$file") is packet-only" "$file" 'Use no tools.'
  if grep -Eq 'Use dedicated (read|`Read`)|direct source reads' "$file"; then
    check "$(basename "$file") does not claim unavailable Codex read tools" FAIL
  else
    check "$(basename "$file") does not claim unavailable Codex read tools" PASS
  fi
done

for file in "$REF_CODE" "$REF_ASPECT"; do
  FRONTMATTER="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$file")"
  printf '%s\n' "$FRONTMATTER" | grep -Fq 'tools: []' \
    && check "$(basename "$file") mirrors packet-only tool profile" PASS \
    || check "$(basename "$file") mirrors packet-only tool profile" FAIL
  printf '%s\n' "$FRONTMATTER" | grep -Fq 'permissionMode: plan' \
    && check "$(basename "$file") mirrors plan permission mode" PASS \
    || check "$(basename "$file") mirrors plan permission mode" FAIL
  contains "$(basename "$file") mirrors reviewer-readonly-v1" "$file" 'reviewer-readonly-v1'
  contains "$(basename "$file") mirrors REVIEW PACKET v1" "$file" 'REVIEW PACKET v1'
done

for field in changed_files implementation_summary requirements_baseline diff_summary governing_guidance source_excerpts test_evidence build_evidence coverage_evidence; do
  contains "TDD handoff includes $field" "$TDD" "\`$field\`"
done
contains "TDD handoff pins reviewer policy" "$TDD" 'policy: reviewer-readonly-v1'
contains "TDD handoff requires complete unified hunks" "$TDD" 'complete relevant unified diff hunks'
contains "TDD handoff declares packet-only reviewers" "$TDD" 'packet-only `reviewer-readonly-v1`'

printf '%s\n' '----' "test-reviewer-readonly-v1: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
