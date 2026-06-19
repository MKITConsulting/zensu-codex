#!/usr/bin/env bash
# Offline smoke tests for zensu-codex. No network, no Codex, no API key.
# Validates packaging (JSON/TOML/frontmatter), hook script syntax, and — most
# importantly — exercises the PreToolUse TDD phase-gate against synthetic Codex
# `apply_patch` payloads to prove the apply_patch parsing + FSM gate behave.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="$ROOT/plugins/zensu"   # the plugin payload lives in a subdir (marketplace layout)
cd "$P"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

hdr "JSON validity"
for j in .codex-plugin/plugin.json hooks/hooks.json config.example.json "$ROOT/.agents/plugins/marketplace.json"; do
  if node -e "JSON.parse(require('fs').readFileSync('$j','utf8'))" 2>/dev/null; then ok "$(basename "$j")"; else bad "$j"; fi
done

hdr "CLI migration (MCP wiring removed; plugin drives the zensu CLI)"
[ ! -e .mcp.json ] && ok ".mcp.json removed" || bad ".mcp.json still present"
if node -e "process.exit(JSON.parse(require('fs').readFileSync('.codex-plugin/plugin.json','utf8')).mcpServers?1:0)" 2>/dev/null; then ok "plugin.json has no mcpServers key"; else bad "plugin.json still declares mcpServers"; fi
if grep -rqE 'mcp_servers' agents/*.toml 2>/dev/null; then bad "agent .toml still declares mcp_servers"; else ok "agents declare no mcp_servers"; fi
if grep -rqE 'mcp__' skills/ agents/ 2>/dev/null; then bad "skills/agents still contain mcp__ tool refs"; else ok "no mcp__ refs in skills/agents"; fi
for s in bootstrap ghost-scan implement security-review pulse; do
  if grep -qE 'zensu (features|products|security|link|ghost|journeys|tiers|pulse|doc|wiki|subfeatures|knowledge) ' "skills/$s/SKILL.md" 2>/dev/null; then ok "$s drives the zensu CLI"; else bad "$s has no zensu CLI commands"; fi
done

hdr "Subagent TOML sanity (name + description + developer_instructions, balanced ''')"
toml_tq_count() { local c; c=$(grep -c "'''" "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
for t in agents/*.toml; do
  miss=""
  grep -q '^name = '            "$t" || miss="$miss name"
  grep -q '^description = '     "$t" || miss="$miss description"
  grep -q '^developer_instructions = ' "$t" || miss="$miss developer_instructions"
  q=$(toml_tq_count "$t")
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
export ZENSU_PLUGIN_ROOT="$P"
mkdir -p "$TDD_STATE_DIR"
CFG_DEFAULT="$TMP/no-such-config.json"
CFG_VANILLA="$TMP/vanilla-config.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$CFG_VANILLA"
export ZENSU_CONFIG="$CFG_DEFAULT"
SID="smoketest"
LOG="$P/hooks/lib/zensu-log.sh"
GATE="$P/hooks/pre-edit-tdd-reminder.sh"

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

hdr "TDD protocol prominence (skill top block + primer carry the command contract)"
# Ported from the zensu-kiro live finding (eval B5): a headless model following
# this skill skipped --tdd-begin / omitted --step until the commands were stated
# compactly at the TOP of the skill and in the session primer.
TOPBLOCK="$(awk '/^## When to Use/{exit} {print}' skills/tdd/SKILL.md)"
printf '%s' "$TOPBLOCK" | grep -qi "command protocol" && ok "skill top: protocol heading" || bad "skill top: protocol heading missing"
printf '%s' "$TOPBLOCK" | grep -q -- "--tdd-begin" && ok "skill top: --tdd-begin" || bad "skill top: --tdd-begin missing"
for M in RED_WRITE RED_RUN RED_FAIL IMPL GREEN_RUN GREEN_PASS; do
  printf '%s' "$TOPBLOCK" | grep -q -- "--phase $M --step" && ok "skill top: $M --step" || bad "skill top: --phase $M --step missing"
done
printf '%s' "$TOPBLOCK" | grep -qi "REQUIRED on every marker" && ok "skill top: per-marker --step rule" || bad "skill top: per-marker --step rule missing"
printf '%s' "$TOPBLOCK" | grep -qi "per step" && ok "skill top: per-step gate matching stated" || bad "skill top: per-step gate matching missing"
grep -q -- "--tdd-begin" hooks/session-start-primer.sh && ok "primer: --tdd-begin" || bad "primer: --tdd-begin missing"
grep -q -- "--step" hooks/session-start-primer.sh && ok "primer: --step" || bad "primer: --step missing"

hdr "Vanilla mode — state-lib flag plumbing"
# shellcheck disable=SC1091
source hooks/lib/zensu-tdd-phase.sh
SF_L="$(tdd_state_file vanlib)"
tdd_set_flag vanlib vanilla true >/dev/null 2>&1
if type tdd_vanilla_mode >/dev/null 2>&1 && [ "$(tdd_vanilla_mode "$SF_L")" = "true" ]; then ok "tdd_vanilla_mode wrapper reads the flag"; else bad "tdd_vanilla_mode wrapper reads the flag"; fi
tdd_write_phase vanlib SX GREEN_PASS "" >/dev/null 2>&1
if [ "$(tdd_get_flag "$SF_L" vanilla)" = "true" ] && [ "$(tdd_phase "$SF_L")" = "GREEN_PASS" ]; then ok "vanilla flag survives --phase state rebuild"; else bad "vanilla flag survives --phase state rebuild"; fi
SF_L3="$(tdd_state_file vanlibreset)"
tdd_set_flag vanlibreset vanilla true >/dev/null 2>&1
tdd_clear_session vanlibreset >/dev/null 2>&1
if [ "$(tdd_get_flag "$SF_L3" vanilla)" = "false" ]; then ok "tdd_clear_session resets the vanilla flag"; else bad "tdd_clear_session resets the vanilla flag"; fi
SF_L5="$(tdd_state_file vanlibarray)"
printf '%s' '["corrupt"]' > "$SF_L5"
tdd_set_flag vanlibarray active true >/dev/null 2>&1
if [ "$(tdd_get_flag "$SF_L5" active)" = "true" ]; then ok "array-shaped state file recovers on flag write"; else bad "array-shaped state file recovers on flag write"; fi
SF_L5B="$(tdd_state_file vanlibarrayphase)"
printf '%s' '["corrupt"]' > "$SF_L5B"
tdd_write_phase vanlibarrayphase SX IMPL "" >/dev/null 2>&1
if [ "$(tdd_phase "$SF_L5B")" = "IMPL" ] && node -e 'const j=require(process.argv[1]);process.exit(j&&typeof j==="object"&&!Array.isArray(j)?0:1)' "$SF_L5B" 2>/dev/null; then ok "array-shaped state file recovers on phase write"; else bad "array-shaped state file recovers on phase write"; fi
SF_L5C="$(tdd_state_file vanlibarrayclear)"
printf '%s' '["corrupt"]' > "$SF_L5C"
tdd_clear_session vanlibarrayclear >/dev/null 2>&1
if [ "$(tdd_session_active "$SF_L5C")" = "false" ] && node -e 'const j=require(process.argv[1]);process.exit(j&&typeof j==="object"&&!Array.isArray(j)&&j.vanilla===false?0:1)' "$SF_L5C" 2>/dev/null; then ok "array-shaped state file recovers on clear (vanilla reset to false)"; else bad "array-shaped state file recovers on clear (vanilla reset to false)"; fi
tdd_set_flag vanlibgarbage vanilla notabool >/dev/null 2>&1
GARBAGE_RC=$?
if [ "$GARBAGE_RC" -ne 0 ] && [ "$(tdd_get_flag "$(tdd_state_file vanlibgarbage)" vanilla)" = "false" ]; then ok "invalid flag value fails strict (no coerce-to-true un-gating)"; else bad "invalid flag value fails strict (no coerce-to-true un-gating) (rc=$GARBAGE_RC)"; fi
tdd_set_flag vanlibempty vanilla "" >/dev/null 2>&1
EMPTY_RC=$?
if [ "$EMPTY_RC" -ne 0 ] && [ "$(tdd_get_flag "$(tdd_state_file vanlibempty)" vanilla)" = "false" ]; then ok "explicit empty flag value fails strict (no coerce-to-true un-gating)"; else bad "explicit empty flag value fails strict (no coerce-to-true un-gating) (rc=$EMPTY_RC)"; fi
tdd_set_flag vanlibdefault active >/dev/null 2>&1
if [ "$(tdd_get_flag "$(tdd_state_file vanlibdefault)" active)" = "true" ]; then ok "omitted flag value still defaults to true"; else bad "omitted flag value still defaults to true"; fi

hdr "Vanilla mode — --tdd-begin persist + echo, --mode verb"
OUT_BS="$(bash "$LOG" --tdd-begin --session vanbeginstrict 2>/dev/null)"
[ "$OUT_BS" = "mode: strict" ] && ok "default config: --tdd-begin echoes 'mode: strict'" || bad "default config: --tdd-begin echoes 'mode: strict' (got '$OUT_BS')"
[ "$(tdd_get_flag "$(tdd_state_file vanbeginstrict)" vanilla)" = "false" ] && ok "default config: state vanilla=false" || bad "default config: state vanilla=false"
OUT_BV="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session vanbeginvan 2>/dev/null)"
[ "$OUT_BV" = "mode: vanilla" ] && ok "tddImplementation:false: --tdd-begin echoes 'mode: vanilla'" || bad "tddImplementation:false: --tdd-begin echoes 'mode: vanilla' (got '$OUT_BV')"
[ "$(tdd_get_flag "$(tdd_state_file vanbeginvan)" vanilla)" = "true" ] && ok "tddImplementation:false: state vanilla=true" || bad "tddImplementation:false: state vanilla=true"
CFG_STRFALSE="$TMP/strfalse-config.json"
printf '%s' '{"hooks":{"tddImplementation":"false"}}' > "$CFG_STRFALSE"
OUT_SF="$(ZENSU_CONFIG="$CFG_STRFALSE" bash "$LOG" --tdd-begin --session vanstrfalse 2>/dev/null)"
{ [ "$OUT_SF" = "mode: strict" ] && [ "$(tdd_get_flag "$(tdd_state_file vanstrfalse)" vanilla)" = "false" ]; } \
  && ok "non-boolean \"false\" degrades to strict" || bad "non-boolean \"false\" degrades to strict (got '$OUT_SF')"
ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session vanrebegin >/dev/null 2>&1
bash "$LOG" --tdd-reset --session vanrebegin >/dev/null 2>&1
OUT_RB="$(bash "$LOG" --tdd-begin --session vanrebegin 2>/dev/null)"
{ [ "$OUT_RB" = "mode: strict" ] && [ "$(tdd_get_flag "$(tdd_state_file vanrebegin)" vanilla)" = "false" ]; } \
  && ok "strict re-begin after vanilla+reset clears the stale flag" || bad "strict re-begin after vanilla+reset clears the stale flag (got '$OUT_RB')"
unset -f tdd_state_file tdd_is_test_path _tdd_locked_run tdd_write_phase _tdd_write_phase_critical tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_write_clear_critical tdd_clear_session tdd_get_flag tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed 2>/dev/null || true
if type tdd_get_flag >/dev/null 2>&1; then bad "tdd_* functions unset after in-shell lib use (hook subprocesses must source themselves)"; else ok "tdd_* functions unset after in-shell lib use (hook subprocesses must source themselves)"; fi
tdd_state_file() { echo "/nonexistent/poisoned-by-smoke-$1.json"; }
tdd_get_flag() { echo "poisoned"; }
export -f tdd_state_file tdd_get_flag 2>/dev/null || true
[ "$(bash "$LOG" --mode --session vanbeginvan 2>/dev/null)" = "vanilla" ] && ok "--mode echoes vanilla for a vanilla session" || bad "--mode echoes vanilla for a vanilla session"
[ "$(bash "$LOG" --mode --session vanbeginstrict 2>/dev/null)" = "strict" ] && ok "--mode echoes strict for a strict session" || bad "--mode echoes strict for a strict session"
[ "$(bash "$LOG" --mode --session nosuchsessionxyz 2>/dev/null)" = "strict" ] && ok "--mode defaults to strict with no session state" || bad "--mode defaults to strict with no session state"
no_hang() {
  bash "$LOG" "$@" >/dev/null 2>&1 &
  local pid=$! hung=1 i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || { hung=0; break; }
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i+1))
  done
  [ "$hung" = "1" ] && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ "$hung" = "0" ]
}
no_hang --mode --session && ok "dangling --session terminates (no arg-loop spin)" || bad "dangling --session terminates (no arg-loop spin)"
no_hang --phase IMPL --step && ok "dangling --step terminates (no arg-loop spin)" || bad "dangling --step terminates (no arg-loop spin)"
no_hang --tdd-begin --session && ok "dangling --session on --tdd-begin terminates (no arg-loop spin)" || bad "dangling --session on --tdd-begin terminates (no arg-loop spin)"
RO_STATE="$TMP/rostate"; mkdir -p "$RO_STATE"; chmod 555 "$RO_STATE" 2>/dev/null
if touch "$RO_STATE/probe" 2>/dev/null; then
  rm -f "$RO_STATE/probe"
  ok "begin failure path SKIPPED — state dir writable despite chmod (root environment)"
else
  OUT_RF="$(TDD_STATE_DIR="$RO_STATE" bash "$LOG" --tdd-begin --session rofail 2>"$TMP/rofail.err")"
  RC_RF=$?
  if [ "$RC_RF" -ne 0 ] && ! printf '%s' "$OUT_RF" | grep -q "^mode:" && grep -q "session NOT activated" "$TMP/rofail.err"; then ok "unwritable state dir: begin rc!=0, no mode echo, stderr names activation failure"; else bad "unwritable state dir: begin rc!=0, no mode echo, stderr names activation failure (rc=$RC_RF out='$OUT_RF')"; fi
fi
chmod 755 "$RO_STATE" 2>/dev/null

hdr "Vanilla mode — gate bypass, freeze, state-path deny"
# Ordering contract: vanbeginvan (vanilla) and vanbeginstrict (strict) are
# threaded through the gate -> witness -> Stop-chain sections in this order;
# the gate section writes a GREEN_PASS marker into vanbeginvan and the Stop
# section flips implComplete/codeReviewDone/chainDone on it. Do not reorder
# sections or add lifecycle markers to these session ids.
run_gate_cfg() { local out; out="$(printf '%s' "$2" | ZENSU_CONFIG="$1" bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
expect "vanilla session, prod file, no phase markers" ALLOW "$(run_gate "$(mk_apply_patch vanbeginvan src/foo.js)")"
expect "vanilla session, test file" ALLOW "$(run_gate "$(mk_apply_patch vanbeginvan src/foo.test.js)")"
bash "$LOG" --phase GREEN_PASS --step SX --session vanbeginvan >/dev/null 2>&1
expect "vanilla survives phase write, prod at GREEN_PASS" ALLOW "$(run_gate "$(mk_apply_patch vanbeginvan src/foo.js)")"
expect "config flip to default mid-session, vanilla still allowed (frozen)" ALLOW "$(run_gate_cfg "$CFG_DEFAULT" "$(mk_apply_patch vanbeginvan src/foo.js)")"
expect "strict session, prod deny at UNINITIALIZED (characterization)" DENY "$(run_gate "$(mk_apply_patch vanbeginstrict src/foo.js)")"
expect "config flip to vanilla mid-session, strict still denied (frozen)" DENY "$(run_gate_cfg "$CFG_VANILLA" "$(mk_apply_patch vanbeginstrict src/foo.js)")"
expect "strict session, .zensu/state/ edit denied" DENY "$(run_gate "$(mk_apply_patch vanbeginstrict .zensu/state/tdd-phase-evil.json)")"
expect "vanilla session, .zensu/state/ edit denied (bypass excludes state)" DENY "$(run_gate "$(mk_apply_patch vanbeginvan .zensu/state/tdd-phase-evil.json)")"
expect "vanilla session, dot-segment .zensu/./state/ denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan .zensu/./state/tdd-phase-evil.json)")"
expect "vanilla session, case variant .ZENSU/State/ denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan .ZENSU/State/tdd-phase-evil.json)")"
expect "vanilla session, traversal src/../.zensu/state/ denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan src/../.zensu/state/tdd-phase-evil.json)")"
expect "vanilla session, resolved TDD_STATE_DIR override denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TDD_STATE_DIR/tdd-phase-evil.json")")"
expect "vanilla session, multi-file patch with one state file denied whole" DENY "$(run_gate "$(mk_apply_patch vanbeginvan src/innocent.js "$TDD_STATE_DIR/tdd-phase-evil.json")")"
expect "vanilla session, Edit on state file (Claude shape) denied" DENY "$(run_gate "$(mk_edit vanbeginvan .zensu/state/tdd-phase-evil.json)")"
SF_VBV="$TDD_STATE_DIR/tdd-phase-vanbeginvan.json"
if [ -f "$SF_VBV" ]; then ok "alias pins precondition: live state file exists"; else bad "alias pins precondition: live state file exists ($SF_VBV missing — naming drift?)"; fi
ln -s "$TDD_STATE_DIR" "$TMP/alias" 2>/dev/null
if [ -L "$TMP/alias" ]; then
  expect "vanilla session, symlinked dir alias into state denied (realpath)" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TMP/alias/tdd-phase-evil.json")")"
  ln -s "$SF_VBV" "$TMP/innocent-link.json" 2>/dev/null
  expect "vanilla session, file symlink to live state file denied (realpath)" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TMP/innocent-link.json")")"
else
  ok "symlink alias checks SKIPPED — symlinks unavailable on this platform"
  ok "symlink alias checks SKIPPED — symlinks unavailable on this platform"
fi
expect "vanilla session, .zensu/plans/ exemption preserved" ALLOW "$(run_gate "$(mk_apply_patch vanbeginvan .zensu/plans/notes.md)")"
expect "strict session, .zensu/plans/ exemption reached past state deny" ALLOW "$(run_gate "$(mk_apply_patch vanbeginstrict .zensu/plans/notes.md)")"

hdr "Vanilla mode — witness + Stop-chain stay enforced"
export CLAUDE_PROJECT_DIR="$TMP/proj"
mkdir -p "$CLAUDE_PROJECT_DIR"
printf '%s' '{"tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok"},"session_id":"vanbeginvan"}' | ZENSU_CONFIG="$CFG_VANILLA" bash hooks/post-bash-witness.sh >/dev/null 2>&1
WLOG="$CLAUDE_PROJECT_DIR/.zensu/logs/witness-vanbeginvan.log"
if grep -qF 'cmd="npm test"' "$WLOG" 2>/dev/null && grep -qF 'tail="ok"' "$WLOG" 2>/dev/null; then ok "witness records cmd= + tail= in vanilla session"; else bad "witness records cmd= + tail= in vanilla session"; fi
stop_out() { printf '%s' "{\"session_id\":\"$1\"}" | ZENSU_CONFIG="$CFG_VANILLA" bash hooks/stop-chain-enforcer.sh 2>/dev/null; }
case "$(stop_out vanbeginvan)" in *'"decision":"block"'*) bad "Stop allows mid-implementation in vanilla session" ;; *) ok "Stop allows mid-implementation in vanilla session" ;; esac
bash "$LOG" --tdd-complete --session vanbeginvan >/dev/null 2>&1
STOP_D1="$(stop_out vanbeginvan)"
case "$STOP_D1" in *'"decision":"block"'*) ok "implComplete in vanilla: Stop blocks toward review" ;; *) bad "implComplete in vanilla: Stop blocks toward review" ;; esac
case "$STOP_D1" in *zensu-code-reviewer*) ok "block reason routes to zensu-code-reviewer" ;; *) bad "block reason routes to zensu-code-reviewer" ;; esac
if printf '%s' "$STOP_D1" | grep -q "vanilla" && ! printf '%s' "$STOP_D1" | grep -qF "under the gate"; then ok "vanilla session: Stop reason uses vanilla fix wording (no 'under the gate')"; else bad "vanilla session: Stop reason uses vanilla fix wording (no 'under the gate')"; fi
bash "$LOG" --tdd-begin --session stopstrict >/dev/null 2>&1
bash "$LOG" --tdd-complete --session stopstrict >/dev/null 2>&1
STOP_SS="$(stop_out stopstrict)"
if printf '%s' "$STOP_SS" | grep -qF "under the gate"; then ok "strict session: Stop reason keeps gate-flavored fix wording"; else bad "strict session: Stop reason keeps gate-flavored fix wording"; fi
bash "$LOG" --code-review-done --session vanbeginvan >/dev/null 2>&1
STOP_D3="$(stop_out vanbeginvan)"
case "$STOP_D3" in *'"decision":"block"'*) ok "codeReviewDone in vanilla: Stop still blocks toward self-review" ;; *) bad "codeReviewDone in vanilla: Stop still blocks toward self-review" ;; esac
case "$STOP_D3" in *zensu-self-review*) ok "block reason routes to zensu-self-review" ;; *) bad "block reason routes to zensu-self-review" ;; esac
bash "$LOG" --chain-done --session vanbeginvan >/dev/null 2>&1
case "$(stop_out vanbeginvan)" in *'"decision":"block"'*) bad "chainDone in vanilla: Stop allows" ;; *) ok "chainDone in vanilla: Stop allows" ;; esac

hdr "Vanilla mode — banner + primer wording"
hook_ctx() { ZENSU_CONFIG="$2" bash "$1" 2>/dev/null | node -e '
  let s="";process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}});'
}
BN_V="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$CFG_VANILLA" bash hooks/session-start-banner.sh 2>/dev/null)"
if printf '%s' "$BN_V" | grep -q "vanilla" && ! printf '%s' "$BN_V" | grep -qF "strict RED→GREEN TDD"; then ok "banner (vanilla cfg): vanilla wording, no strict flow line"; else bad "banner (vanilla cfg): vanilla wording, no strict flow line"; fi
BN_S="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$CFG_DEFAULT" bash hooks/session-start-banner.sh 2>/dev/null)"
if printf '%s' "$BN_S" | grep -qF "strict RED→GREEN TDD"; then ok "banner (default cfg): strict wording unchanged"; else bad "banner (default cfg): strict wording unchanged"; fi
PRM_V="$(printf '%s' '{"source":"startup"}' | hook_ctx hooks/session-start-primer.sh "$CFG_VANILLA")"
if printf '%s' "$PRM_V" | grep -q "vanilla" && printf '%s' "$PRM_V" | grep -qF '$zensu-tdd' && printf '%s' "$PRM_V" | grep -qF -- "--tdd-begin" && ! printf '%s' "$PRM_V" | grep -qF "strict RED→GREEN TDD"; then ok "primer (vanilla cfg): vanilla orientation, \$zensu-tdd route + --tdd-begin kept"; else bad "primer (vanilla cfg): vanilla orientation, \$zensu-tdd route + --tdd-begin kept"; fi
PRM_S="$(printf '%s' '{"source":"startup"}' | hook_ctx hooks/session-start-primer.sh "$CFG_DEFAULT")"
if printf '%s' "$PRM_S" | grep -qF "strict RED→GREEN TDD"; then ok "primer (default cfg): strict orientation unchanged"; else bad "primer (default cfg): strict orientation unchanged"; fi

hdr "Vanilla mode — plan-approved directive (reference hook) + heredoc parity"
PA_V="$(printf '%s' '{}' | hook_ctx hooks/plan-approved-delegate.sh "$CFG_VANILLA")"
if printf '%s' "$PA_V" | grep -q "vanilla" \
  && printf '%s' "$PA_V" | grep -qF "skill='zensu:tdd'" \
  && printf '%s' "$PA_V" | grep -q "AskUserQuestion" \
  && printf '%s' "$PA_V" | grep -qF "Skipping TDD: docs only" \
  && ! printf '%s' "$PA_V" | grep -qF "strict TDD flow"; then ok "plan-approved (vanilla cfg): vanilla wording + skill route + ask + docs fast-path, no strict text"; else bad "plan-approved (vanilla cfg): vanilla wording + skill route + ask + docs fast-path, no strict text"; fi
PA_S="$(printf '%s' '{}' | hook_ctx hooks/plan-approved-delegate.sh "$CFG_DEFAULT")"
if printf '%s' "$PA_S" | grep -qF "strict TDD flow"; then ok "plan-approved (default cfg): strict directive unchanged"; else bad "plan-approved (default cfg): strict directive unchanged"; fi
parity() {
  local f="$1"; shift
  local d
  d="$(mktemp -d "$TMP/parity-XXXXXX")"
  awk -v dir="$d" '{ if ($0 ~ /^cat <<.JSON.$/) { n++; inb=1; next } if ($0 == "JSON") { inb=0 } if (inb) print > (dir "/b" n) }' "$f"
  if [ ! -f "$d/b1" ] || [ ! -f "$d/b2" ]; then echo "MISSING_BLOCKS"; return; fi
  if [ -f "$d/b3" ]; then echo "EXTRA_BLOCKS"; return; fi
  local p
  for p in "$@"; do
    if ! grep -qF "$p" "$d/b1" || ! grep -qF "$p" "$d/b2"; then echo "DRIFT:$p"; return; fi
  done
  echo "OK"
}
P1="$(parity hooks/plan-approved-delegate.sh "Skipping TDD: docs only" "Skipping TDD: user declined" "AskUserQuestion" "'no tdd', 'skip tdd'" "'use tdd', 'with tdd'" "Auto Mode" "skill='zensu:tdd'")"
if [ "$P1" = "OK" ]; then ok "plan-approved heredocs: shared invariants present in BOTH branches"; else bad "plan-approved heredocs: shared invariants present in BOTH branches ($P1)"; fi
P2="$(parity hooks/session-start-primer.sh "/hooks/lib/zensu-log.sh --tdd-begin" "\$zensu-tdd" "zensu-code-reviewer" "zensu-plm" "\$zensu-bootstrap" "\$zensu-help")"
if [ "$P2" = "OK" ]; then ok "primer heredocs: shared invariants present in BOTH branches"; else bad "primer heredocs: shared invariants present in BOTH branches ($P2)"; fi

hdr "Vanilla mode — post-review fix directive (reference hook)"
rm -f "$CLAUDE_PROJECT_DIR/.zensu/state/rounds-"*.json 2>/dev/null
ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session prvan >/dev/null 2>&1
bash "$LOG" --tdd-begin --session prstrict >/dev/null 2>&1
PR_V="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"prvan"}' | hook_ctx hooks/post-review-tdd-delegate.sh "$CFG_DEFAULT")"
if printf '%s' "$PR_V" | grep -q "vanilla" \
  && printf '%s' "$PR_V" | grep -qF "After the fixes are applied" \
  && ! printf '%s' "$PR_V" | grep -qF "strict TDD discipline" \
  && ! printf '%s' "$PR_V" | grep -qF "After the fixes are GREEN" \
  && printf '%s' "$PR_V" | grep -qF "/zensu:tdd" \
  && printf '%s' "$PR_V" | grep -qF "subagent_type='zensu:code-reviewer'"; then ok "post-review (vanilla session, default live cfg): vanilla fix wording, pinned literals retained — state wins"; else bad "post-review (vanilla session, default live cfg): vanilla fix wording, pinned literals retained — state wins"; fi
PR_S="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"prstrict"}' | hook_ctx hooks/post-review-tdd-delegate.sh "$CFG_DEFAULT")"
if printf '%s' "$PR_S" | grep -qF "strict TDD discipline" && printf '%s' "$PR_S" | grep -qF "After the fixes are GREEN"; then ok "post-review (strict session): strict fix wording + done-phrase unchanged"; else bad "post-review (strict session): strict fix wording + done-phrase unchanged"; fi
PR_X="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"prstrict"}' | hook_ctx hooks/post-review-tdd-delegate.sh "$CFG_VANILLA")"
if printf '%s' "$PR_X" | grep -qF "strict TDD discipline"; then ok "post-review (strict state, vanilla LIVE cfg): strict wording — frozen state wins"; else bad "post-review (strict state, vanilla LIVE cfg): strict wording — frozen state wins"; fi

hdr "Vanilla mode — gate classifier failure handling + alias hardening"
REAL_NODE="$(command -v node)"
SHIMD="$TMP/nodeshim"; mkdir -p "$SHIMD"
cat > "$SHIMD/node" <<SH
#!/bin/bash
case "\$*" in *lownorm*) exit 1 ;; esac
exec "$REAL_NODE" "\$@"
SH
chmod +x "$SHIMD/node"
run_gate_shim() { local out; out="$(printf '%s' "$1" | PATH="$SHIMD:$PATH" bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
expect "classifier failure, vanilla session, textual state path" DENY "$(run_gate_shim "$(mk_apply_patch vanbeginvan .zensu/state/tdd-phase-evil.json)")"
expect "classifier failure, vanilla session, TDD_STATE_DIR path" DENY "$(run_gate_shim "$(mk_apply_patch vanbeginvan "$TDD_STATE_DIR/tdd-phase-evil.json")")"
expect "classifier failure, strict session, .zensu/plans/ exempt (textual fallback)" ALLOW "$(run_gate_shim "$(mk_apply_patch vanbeginstrict .zensu/plans/notes.md)")"
expect "classifier failure, vanilla session, prod path fail-open" ALLOW "$(run_gate_shim "$(mk_apply_patch vanbeginvan src/foo.js)")"
ln -s "$TDD_STATE_DIR/ghost-target.json" "$TMP/dangling.json" 2>/dev/null
if [ -L "$TMP/dangling.json" ]; then
  expect "vanilla session, dangling leaf symlink into state dir denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TMP/dangling.json")")"
  ln -s "$TDD_STATE_DIR/ghost-chain.json" "$TMP/chainB.json" 2>/dev/null
  ln -s "$TMP/chainB.json" "$TMP/chainA.json" 2>/dev/null
  expect "vanilla session, symlink chain via dangling intermediate denied" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TMP/chainA.json")")"
else
  ok "dangling-symlink check SKIPPED — symlinks unavailable on this platform"
  ok "symlink-chain check SKIPPED — symlinks unavailable on this platform"
fi
if [ -f "$SF_VBV" ] && ln "$SF_VBV" "$TMP/hardlink.json" 2>/dev/null; then
  expect "vanilla session, hard link to live state file denied (inode match)" DENY "$(run_gate "$(mk_apply_patch vanbeginvan "$TMP/hardlink.json")")"
else
  ok "hard-link check SKIPPED — hard links unavailable on this platform"
fi
expect "classifier failure, vanilla session, dot-segment state spelling still denied (normalized fallback)" DENY "$(run_gate_shim "$(mk_apply_patch vanbeginvan .zensu/./state/tdd-phase-evil.json)")"
mk_write_content() { printf '{"tool_name":"Write","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s","content":"docs example:\\n*** Update File: %s\\nrest"}}' "$1" "$TMP" "$2" "$3"; }
bash "$LOG" --tdd-begin --session phantomred >/dev/null 2>&1
bash "$LOG" --phase RED_WRITE --step p1 --session phantomred >/dev/null 2>&1
bash "$LOG" --phase RED_FAIL --step p1 --session phantomred >/dev/null 2>&1
expect "strict RED_FAIL, Write on test file whose CONTENT embeds an envelope marker" ALLOW "$(run_gate "$(mk_write_content phantomred src/foo.test.js src/evil.js)")"
expect "vanilla session, Write whose CONTENT embeds a state-path envelope marker" ALLOW "$(run_gate "$(mk_write_content vanbeginvan src/foo.js .zensu/state/evil.json)")"
if grep -qF '$zensu-reset-review-limit' hooks/stop-chain-enforcer.sh && ! grep -qF '/zensu:reset-review-limit' hooks/stop-chain-enforcer.sh; then ok "stop-chain stderr uses Codex skill notation"; else bad "stop-chain stderr uses Codex skill notation"; fi
DBL_STATE="$TMP//state"
DBL_OUT="$(printf '%s' "$(mk_apply_patch vanbeginvan "$TMP/state/tdd-phase-evil2.json")" | TDD_STATE_DIR="$DBL_STATE" PATH="$SHIMD:$PATH" bash "$GATE" 2>/dev/null)"
case "$DBL_OUT" in *'permissionDecision":"deny"'*) ok "classifier failure, non-normalized TDD_STATE_DIR spelling still denied (SD normalized too)" ;; *) bad "classifier failure, non-normalized TDD_STATE_DIR spelling still denied (SD normalized too)" ;; esac
bash -c 'cd "'"$P"'" && source hooks/lib/zensu-tdd-phase.sh && tdd_set_flag inactvan vanilla true' >/dev/null 2>&1
PR_I="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"inactvan"}' | hook_ctx hooks/post-review-tdd-delegate.sh "$CFG_DEFAULT")"
if [ -z "$PR_I" ]; then ok "post-review hook silent for an INACTIVE session (vanilla flag alone is inert)"; else bad "post-review hook silent for an INACTIVE session (vanilla flag alone is inert)"; fi
printf 'name = "x"\ndescription = "y"\ndeveloper_instructions = "z"\n' > "$TMP/zero.toml"
QZ="$(toml_tq_count "$TMP/zero.toml")"
if [ "$QZ" = "0" ] && [ $((QZ % 2)) -eq 0 ]; then ok "TOML triple-quote counter handles zero-occurrence files (single-line 0)"; else bad "TOML triple-quote counter handles zero-occurrence files (got '$QZ')"; fi

hdr "Vanilla mode — content pins (SKILL.md + config.example.json)"
SKILL_TDD="skills/tdd/SKILL.md"
if grep -qF "## Vanilla Implementation Mode" "$SKILL_TDD" \
  && grep -qF "mode: vanilla" "$SKILL_TDD" \
  && grep -qF "DISCIPLINE AUDIT SKIPPED — vanilla mode" "$SKILL_TDD"; then ok "tdd SKILL.md documents vanilla deltas + mode echo + audit skip"; else bad "tdd SKILL.md documents vanilla deltas + mode echo + audit skip"; fi
VAN_SECTION="$(awk '/^## Vanilla Implementation Mode/{f=1;next} /^## /{f=0} f' "$SKILL_TDD")"
if printf '%s' "$VAN_SECTION" | grep -qF "mtime Discipline Audit" \
  && printf '%s' "$VAN_SECTION" | grep -qF "Cross-Layer Value Flow Audit" \
  && printf '%s' "$VAN_SECTION" | grep -qi "precondition"; then ok "vanilla deltas name the skipped audits and keep the precondition check (scoped to the section)"; else bad "vanilla deltas name the skipped audits and keep the precondition check (scoped to the section)"; fi
if grep -qF "zensu-log.sh --mode" "skills/self-review/SKILL.md" && grep -qi "vanilla-mode session" "skills/self-review/SKILL.md"; then ok "self-review SKILL.md detects vanilla via the --mode query verb"; else bad "self-review SKILL.md detects vanilla via the --mode query verb"; fi
if grep -qF '`--tdd-begin` exits non-zero' "$SKILL_TDD"; then ok "tdd SKILL.md Phase 0 carries the abort-on-failed --tdd-begin rule"; else bad "tdd SKILL.md Phase 0 carries the abort-on-failed --tdd-begin rule"; fi
if node -e 'const c=require(process.argv[1]);process.exit(c.hooks&&c.hooks.tddImplementation===true?0:1)' "$PWD/config.example.json" 2>/dev/null; then ok "config.example.json ships hooks.tddImplementation=true"; else bad "config.example.json ships hooks.tddImplementation=true"; fi

hdr "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
