#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
SESSION="$PLUGIN/hooks/lib/zensu-session.sh"
PHASE="$PLUGIN/hooks/lib/zensu-tdd-phase.sh"
CORE="$PLUGIN/hooks/lib/session-control-core-v1.js"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
HOME_DIR="$TMP/home"
mkdir -p "$PROJECT" "$HOME_DIR"
PROJECT="$(cd "$PROJECT" && pwd -P)"
HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
mkdir -p "$PROJECT/.zensu/state"
RAW='codex/raw session id'
EXPECTED="$(node "$CORE" session-key "$RAW")"

# These three resolver-only children model hooks without an injected key.
# Clear only their inherited selector; the invoking workflow keeps its binding.
EXPLICIT="$(env -u ZENSU_SESSION_KEY HOME="$HOME_DIR" bash -c "source '$SESSION'; zensu_resolve_session_id '$RAW'" 2>/dev/null)"
[ "$EXPLICIT" = "$EXPECTED" ] && check "explicit hook id becomes the domain-separated key" PASS || check "explicit hook id becomes the domain-separated key" FAIL

if env -u ZENSU_SESSION_KEY HOME="$HOME_DIR" CODEX_THREAD_ID="$RAW" CLAUDE_SESSION_ID='foreign' bash -c "source '$SESSION'; zensu_resolve_session_id ''" >"$TMP/codex-id.out" 2>/dev/null; then
  check "CODEX_THREAD_ID cannot select a helper session without the injected key" FAIL
else
  check "CODEX_THREAD_ID cannot select a helper session without the injected key" PASS
fi

INJECTED_KEY="$(ZENSU_SESSION_KEY="$EXPECTED" CODEX_THREAD_ID='contradictory' bash -c "source '$SESSION'; zensu_resolve_session_id ''" 2>/dev/null)"
[ "$INJECTED_KEY" = "$EXPECTED" ] && check "injected ZENSU_SESSION_KEY is the primary helper identity" PASS || check "injected ZENSU_SESSION_KEY is the primary helper identity" FAIL

if ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id 'different-session'" >"$TMP/cross-session.out" 2>/dev/null; then
  check "explicit helper input cannot escape the injected session binding" FAIL
else
  [ ! -s "$TMP/cross-session.out" ] && check "explicit helper input cannot escape the injected session binding" PASS || check "explicit helper input cannot escape the injected session binding" FAIL
fi

BOUND_EXPLICIT="$(ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id '$RAW'" 2>/dev/null)"
[ "$BOUND_EXPLICIT" = "$EXPECTED" ] && check "matching explicit hook id remains valid inside the injected session" PASS || check "matching explicit hook id remains valid inside the injected session" FAIL

if ZENSU_SESSION_KEY='invalid' CODEX_THREAD_ID="$RAW" bash -c "source '$SESSION'; zensu_resolve_session_id ''" >"$TMP/invalid-key.out" 2>/dev/null; then
  check "an invalid injected key fails closed instead of using CODEX_THREAD_ID" FAIL
else
  check "an invalid injected key fails closed instead of using CODEX_THREAD_ID" PASS
fi

ROUNDTRIP="$(env -u ZENSU_SESSION_KEY HOME="$HOME_DIR" bash -c "source '$SESSION'; zensu_resolve_session_id '$EXPECTED'" 2>/dev/null)"
[ "$ROUNDTRIP" = "$EXPECTED" ] && check "an existing v1 key is not double-hashed" PASS || check "an existing v1 key is not double-hashed" FAIL

if ZENSU_SESSION_KEY='' CODEX_THREAD_ID='' CLAUDE_SESSION_ID='foreign' bash -c "source '$SESSION'; zensu_resolve_session_id ''" >"$TMP/missing.out" 2>/dev/null; then
  check "missing Codex identity fails closed without PPID fallback" FAIL
else
  [ ! -s "$TMP/missing.out" ] && check "missing Codex identity fails closed without PPID fallback" PASS || check "missing Codex identity fails closed without PPID fallback" FAIL
fi

printf '%s\n' 'planted' > "$PROJECT/.zensu/state/session-id-current.txt"
mkdir -p "$TMP/projects/fake"
printf '%s\n' '{}' > "$TMP/projects/fake/transcript.jsonl"
if CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_PROJECTS_DIR="$TMP/projects" ZENSU_SESSION_KEY='' CODEX_THREAD_ID='' bash -c "source '$SESSION'; zensu_resolve_session_id ''" >/dev/null 2>&1; then
  check "project pointers and transcripts are ignored" FAIL
else
  check "project pointers and transcripts are ignored" PASS
fi

printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$RAW" "$PROJECT" \
  | HOME="$HOME_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null

OTHER_PROJECT="$TMP/other-project"
mkdir -p "$OTHER_PROJECT"
RESOLVED_PROJECT="$(HOME="$HOME_DIR" ZENSU_SESSION_KEY="$EXPECTED" CLAUDE_PROJECT_DIR="$OTHER_PROJECT" \
  bash -c "source '$SESSION'; zensu_resolve_project_dir")"
[ "$RESOLVED_PROJECT" = "$PROJECT" ] \
  && check "project root comes only from the injected-key reader binding" PASS \
  || check "project root comes only from the injected-key reader binding" FAIL
if HOME="$HOME_DIR" ZENSU_SESSION_KEY='' CLAUDE_PROJECT_DIR="$PROJECT" \
  bash -c "cd '$PROJECT'; source '$SESSION'; zensu_resolve_project_dir" >"$TMP/project-fallback.out" 2>/dev/null; then
  check "project resolution rejects CLAUDE_PROJECT_DIR and pwd without an injected key" FAIL
else
  check "project resolution rejects CLAUDE_PROJECT_DIR and pwd without an injected key" PASS
fi

STATE_PATH="$(HOME="$HOME_DIR" ZENSU_SESSION_KEY="$EXPECTED" CLAUDE_PROJECT_DIR="$OTHER_PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_state_file '$RAW'")"
EXPECTED_STATE="$PROJECT/.zensu/state/tdd-phase-$EXPECTED.json"
[ "$STATE_PATH" = "$EXPECTED_STATE" ] && check "workflow state is keyed only by the hashed session id" PASS || check "workflow state is keyed only by the hashed session id" FAIL

HOME="$HOME_DIR" ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; source '$PHASE'; tdd_write_phase '$RAW' one RED_WRITE ''; tdd_write_phase '$RAW' one RED_FAIL expected"
if [ -f "$EXPECTED_STATE" ]; then check "phase writes converge on the hashed state file" PASS
else check "phase writes converge on the hashed state file" FAIL; fi

REVISION="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.revision))' "$EXPECTED_STATE" 2>/dev/null)"
SCHEMA="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.schema))' "$EXPECTED_STATE" 2>/dev/null)"
HASH="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.session_id_hash))' "$EXPECTED_STATE" 2>/dev/null)"
if [ "$REVISION" = 3 ] && [ "$SCHEMA" = zensu.workflow-state ] && printf '%s' "$HASH" | grep -Eq '^sha256:[a-f0-9]{64}$'; then
  check "each atomic phase mutation increments the schema-versioned revision" PASS
else
  check "each atomic phase mutation increments the schema-versioned revision" FAIL
fi

HOME="$HOME_DIR" ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; source '$PHASE'; tdd_set_flag '$RAW' active true"
REVISION_FLAG="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.revision))' "$EXPECTED_STATE" 2>/dev/null)"
[ "$REVISION_FLAG" = 4 ] && check "each atomic flag mutation increments the same revision" PASS || check "each atomic flag mutation increments the same revision" FAIL

CONCURRENT='codex/concurrent workflow state'
CONCURRENT_KEY="$(node "$CORE" session-key "$CONCURRENT")"
CONCURRENT_STATE="$PROJECT/.zensu/state/tdd-phase-$CONCURRENT_KEY.json"
printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}' "$CONCURRENT" "$PROJECT" \
  | HOME="$HOME_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null
PIDS=""
for lane in $(seq 1 24); do
  HOME="$HOME_DIR" ZENSU_SESSION_KEY="$CONCURRENT_KEY" bash -c "source '$SESSION'; source '$PHASE'; tdd_set_flag '$CONCURRENT' 'lane_$lane' true" &
  PIDS="$PIDS $!"
done
CONCURRENT_FAIL=0
for pid in $PIDS; do wait "$pid" || CONCURRENT_FAIL=1; done
CONCURRENT_RESULT="$(node -e '
  const s=require(process.argv[1]);
  const lanes=Object.keys(s).filter(k => /^lane_[0-9]+$/.test(k) && s[k]===true).length;
  process.stdout.write(`${s.revision}:${lanes}`);
' "$CONCURRENT_STATE" 2>/dev/null)"
if [ "$CONCURRENT_FAIL" -eq 0 ] && [ "$CONCURRENT_RESULT" = "25:24" ] && ! find "$PROJECT/.zensu/state" -maxdepth 1 \( -name '*.lock' -o -name '*.recovery' \) | grep -q .; then
  check "24 real shell mutations share the Core CAS lock without lost revisions" PASS
else
  check "24 real shell mutations share the Core CAS lock without lost revisions (got $CONCURRENT_RESULT)" FAIL
fi

if grep -R -F -q "$RAW" "$PROJECT/.zensu/state"; then
  check "workflow state never persists the raw host session id" FAIL
else
  check "workflow state never persists the raw host session id" PASS
fi

printf '%s\n' "----" "test-session-id-v1: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
