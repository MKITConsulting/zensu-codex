#!/usr/bin/env bash
# Offline smoke tests for zensu-codex. No network, no Codex, no API key.
# Validates packaging (JSON/TOML/frontmatter), hook script syntax, and — most
# importantly — exercises the PreToolUse TDD phase-gate against synthetic Codex
# `apply_patch` payloads to prove the apply_patch parsing + FSM gate behave.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

hdr "JSON validity"
for j in .mcp.json .codex-plugin/plugin.json .agents/plugins/marketplace.json hooks/hooks.json config.example.json; do
  if node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" 2>/dev/null; then ok "$j"; else bad "$j"; fi
done

hdr "Subagent TOML sanity (name + description + developer_instructions, balanced ''')"
for t in agents/*.toml; do
  miss=""
  grep -q '^name = '            "$t" || miss="$miss name"
  grep -q '^description = '     "$t" || miss="$miss description"
  grep -q '^developer_instructions = ' "$t" || miss="$miss developer_instructions"
  q=$(grep -c "'''" "$t" 2>/dev/null || echo 0)
  [ $((q % 2)) -eq 0 ] || miss="$miss unbalanced-triple-quote"
  [ -z "$miss" ] && ok "$t" || bad "$t (missing:$miss)"
done

hdr "Skill frontmatter (name + description)"
for s in skills/*/SKILL.md; do
  if head -6 "$s" | grep -q '^name: ' && head -8 "$s" | grep -q '^description: '; then ok "$(dirname "$s" | xargs basename)"; else bad "$s"; fi
done

hdr "Hook + lib shell syntax"
for f in hooks/*.sh hooks/lib/*.sh; do
  if bash -n "$f" 2>/tmp/zsynerr; then ok "$f"; else bad "$f"; cat /tmp/zsynerr; fi
done
node --check hooks/lib/resolve-session-id.js 2>/dev/null && ok "resolve-session-id.js" || bad "resolve-session-id.js"

hdr "TDD phase-gate — functional (synthetic Codex apply_patch payloads)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
export ZENSU_PLUGIN_ROOT="$ROOT"
mkdir -p "$TDD_STATE_DIR"
SID="smoketest"
LOG="$ROOT/hooks/lib/zensu-log.sh"
GATE="$ROOT/hooks/pre-edit-tdd-reminder.sh"

# Build a Codex PreToolUse payload for an apply_patch touching the given files.
# $1 = session id; remaining args = file paths.
mk_apply_patch() {
  local sid="$1"; shift
  local patch='*** Begin Patch\n'
  for fp in "$@"; do patch="${patch}*** Update File: ${fp}\n@@\n+x\n"; done
  patch="${patch}*** End Patch"
  printf '{"tool_name":"apply_patch","session_id":"%s","cwd":"%s","tool_input":{"input":"%s"}}' "$sid" "$TMP" "$patch"
}
mk_edit() {  # Claude-style Edit payload
  printf '{"tool_name":"Edit","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$1" "$TMP" "$2"
}
# Returns "DENY" if the gate emitted a deny decision, "ALLOW" otherwise.
run_gate() { local out; out="$(printf '%s' "$1" | bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
expect() { if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1 -> got $3, expected $2"; fi; }

# 0) inactive session = pass-through ALLOW
expect "inactive session, prod file" ALLOW "$(run_gate "$(mk_apply_patch nosess src/foo.js)")"

# arm the session
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
bash "$LOG" --phase RED_WRITE --step s1 --session "$SID" >/dev/null 2>&1
# 1) RED_WRITE: prod allowed
expect "RED_WRITE, prod file" ALLOW "$(run_gate "$(mk_apply_patch "$SID" src/foo.js)")"

bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1
# 2) RED_FAIL: prod DENIED, test ALLOWED
expect "RED_FAIL, prod file"  DENY  "$(run_gate "$(mk_apply_patch "$SID" src/foo.js)")"
expect "RED_FAIL, test file"  ALLOW "$(run_gate "$(mk_apply_patch "$SID" src/foo.test.js)")"
# 2b) RED_FAIL: multi-file patch (test + prod) DENIED because prod violates
expect "RED_FAIL, test+prod patch" DENY "$(run_gate "$(mk_apply_patch "$SID" src/foo.test.js src/foo.js)")"
# 2c) Claude-style Edit on prod also DENIED (cross-engine)
expect "RED_FAIL, Edit prod (Claude)" DENY "$(run_gate "$(mk_edit "$SID" src/foo.js)")"

bash "$LOG" --phase IMPL --step s1 --session "$SID" >/dev/null 2>&1
# 3) IMPL after RED_FAIL: prod allowed
expect "IMPL (post RED_FAIL), prod file" ALLOW "$(run_gate "$(mk_apply_patch "$SID" src/foo.js)")"

# 4) ZENSU_TDD_GATE=off bypasses. Put the session back in RED_FAIL so a prod edit
#    WOULD be denied with the gate on — then prove the env var flips it to ALLOW.
run_gate_off() { local out; out="$(printf '%s' "$1" | ZENSU_TDD_GATE=off bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1
expect "RED_FAIL prod, gate ON (control)"     DENY  "$(run_gate "$(mk_apply_patch "$SID" src/foo.js)")"
expect "RED_FAIL prod, gate OFF (env bypass)" ALLOW "$(run_gate_off "$(mk_apply_patch "$SID" src/foo.js)")"

hdr "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
