#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
REGISTER="$PLUGIN/hooks/session-start-register-plugin-root.sh"
REGISTRY_LIB="$PLUGIN/hooks/lib/codex-plugin-root-registry.js"
BOOTSTRAP_LIB="$PLUGIN/hooks/lib/codex-plugin-root-bootstrap.js"
READER_SOURCE="$PLUGIN/hooks/lib/codex-plugin-root-resolve-v1.js"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

command -v node >/dev/null 2>&1 || { echo "  SKIP  node unavailable"; exit 0; }
canonical_path() { node -e 'process.stdout.write(require("fs").realpathSync(process.argv[1]))' "$1"; }
PLUGIN_CANON="$(canonical_path "$PLUGIN")"

if [ -f "$REGISTER" ] && bash -n "$REGISTER" 2>/dev/null && [ -f "$REGISTRY_LIB" ] && \
   [ -f "$BOOTSTRAP_LIB" ] && [ -f "$READER_SOURCE" ]; then
  check "R1 registry hook and helper exist" PASS
else
  check "R1 registry hook and helper exist" FAIL
fi

if HOOKS_JSON="$HOOKS_JSON" node - <<'NODE'
const hooks = JSON.parse(require("fs").readFileSync(process.env.HOOKS_JSON, "utf8")).hooks;
const commands = Object.values(hooks).flatMap(groups => groups.flatMap(group => group.hooks || [])).map(hook => hook.command);
if (!commands.length || commands.some(command => !/^bash "\$\{CLAUDE_PLUGIN_ROOT\}\/hooks\/[^"]+"$/.test(command))) process.exit(1);
NODE
then
  check "R1a every Codex hook command quotes a spaced plugin root" PASS
else
  check "R1a Codex hook command schema leaves plugin-root paths unquoted" FAIL
fi

TMP="$(mktemp -d -t zensu-codex-root-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home with space"
PROJECT="$TMP/project"
mkdir -p "$TEST_HOME/.zensu" "$PROJECT"
printf '%s\n' '/tmp/attacker-controlled-legacy-root' > "$TEST_HOME/.zensu/plugin-root"

THREAD_A='thread/a .. with spaces'
THREAD_B='thread-b-concurrent'

payload() {
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$PROJECT"
}

run_register() {
  local register_home="${3:-$TEST_HOME}"
  local register_hook="$2/hooks/session-start-register-plugin-root.sh"
  payload "$1" | env -i PATH="$PATH" HOME="$register_home" CLAUDE_PLUGIN_ROOT="$2" \
    bash "$register_hook" >/dev/null 2>&1
}

run_register_no_root_env() {
  payload "$1" | env -i PATH="$PATH" HOME="$TEST_HOME" bash "$REGISTER" >/dev/null 2>&1
}

copy_registry_runtime() {
  local destination="$1"
  cp "$REGISTRY_LIB" "$destination/hooks/lib/codex-plugin-root-registry.js"
  cp "$BOOTSTRAP_LIB" "$destination/hooks/lib/codex-plugin-root-bootstrap.js"
  cp "$READER_SOURCE" "$destination/hooks/lib/codex-plugin-root-resolve-v1.js"
  cp "$REGISTER" "$destination/hooks/session-start-register-plugin-root.sh"
}

key_for() {
  SID="$1" node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha256").update("codex-session\0").update(process.env.SID).digest("hex"))'
}

CONCURRENT_HOME="$TMP/concurrent home"
mkdir -p "$CONCURRENT_HOME"
run_register 'parallel-thread-a' "$PLUGIN" "$CONCURRENT_HOME" & PID_A=$!
run_register 'parallel-thread-b' "$PLUGIN" "$CONCURRENT_HOME" & PID_B=$!
wait "$PID_A"; wait "$PID_B"
PAR_KEY_A="$(key_for 'parallel-thread-a')"
PAR_KEY_B="$(key_for 'parallel-thread-b')"
if [ -f "$CONCURRENT_HOME/.zensu/plugin-roots/codex/$PAR_KEY_A.json" ] && \
   [ -f "$CONCURRENT_HOME/.zensu/plugin-roots/codex/$PAR_KEY_B.json" ]; then
  check "R1b concurrent first-use registrations both survive directory creation" PASS
else
  check "R1b concurrent first-use registration lost a session" FAIL
fi

run_register "$THREAD_A" "$PLUGIN"
REG_DIR="$TEST_HOME/.zensu/plugin-roots/codex"
READER="$REG_DIR/resolve-v1.js"
KEY_A="$(key_for "$THREAD_A")"
REC_A="$REG_DIR/$KEY_A.json"

if [ -f "$REC_A" ] && [ -f "$READER" ]; then
  check "R2 SessionStart writes the hashed record and stable v1 reader" PASS
else
  check "R2 SessionStart writes the hashed record and stable v1 reader" FAIL
fi

if [ ! -e "$REG_DIR/$THREAD_A.json" ] && [ "$(cat "$TEST_HOME/.zensu/plugin-root")" = '/tmp/attacker-controlled-legacy-root' ]; then
  check "R3 raw session id is not a path component and legacy pointer stays untouched" PASS
else
  check "R3 registry leaked raw id or rewrote the legacy pointer" FAIL
fi

RESOLVED_A="$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" 2>/dev/null)"
if [ "$RESOLVED_A" = "$PLUGIN_CANON" ]; then
  check "R4 exact CODEX_THREAD_ID resolves the registered plugin root" PASS
else
  check "R4 exact resolver output (got '$RESOLVED_A')" FAIL
fi

FAKE_B="$TMP/plugin B"
mkdir -p "$FAKE_B/hooks/lib" "$FAKE_B/.codex-plugin"
cp "$PLUGIN/.codex-plugin/plugin.json" "$FAKE_B/.codex-plugin/plugin.json"
cp "$PLUGIN/hooks/lib/zensu-log.sh" "$FAKE_B/hooks/lib/zensu-log.sh"
copy_registry_runtime "$FAKE_B"
run_register "$THREAD_B" "$FAKE_B"
KEY_B="$(key_for "$THREAD_B")"
REC_B="$REG_DIR/$KEY_B.json"
RESOLVED_B="$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_B" node "$READER" 2>/dev/null)"
FAKE_B_CANON="$(canonical_path "$FAKE_B")"
if [ "$RESOLVED_A" = "$PLUGIN_CANON" ] && [ "$RESOLVED_B" = "$FAKE_B_CANON" ] && [ -f "$REC_B" ]; then
  check "R5 concurrent sessions resolve distinct exact roots without a current pointer" PASS
else
  check "R5 concurrent exact resolution (A='$RESOLVED_A' B='$RESOLVED_B')" FAIL
fi

HOOK_COMMAND="$(HOOKS_JSON="$HOOKS_JSON" node -e 'const h=require(process.env.HOOKS_JSON).hooks.SessionStart[0].hooks[0];process.stdout.write(h.command)')"
HOOK_SPACE_THREAD='thread-hook-command-spaced-root'
payload "$HOOK_SPACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_B" \
  bash -c "$HOOK_COMMAND" >/dev/null 2>&1
HOOK_SPACE_KEY="$(key_for "$HOOK_SPACE_THREAD")"
if [ -f "$REG_DIR/$HOOK_SPACE_KEY.json" ] && \
   [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$HOOK_SPACE_THREAD" node "$READER" 2>/dev/null)" = "$FAKE_B_CANON" ]; then
  check "R5h real hooks.json command registers a plugin root containing spaces" PASS
else
  check "R5h hooks.json command split a spaced plugin root" FAIL
fi

# Registration is rooted in the implementation being executed, not an ambient
# override. It also works when Codex supplies no compatibility root variable.
THREAD_NO_ENV='thread-no-root-env'
run_register_no_root_env "$THREAD_NO_ENV"
KEY_NO_ENV="$(key_for "$THREAD_NO_ENV")"
if [ -f "$REG_DIR/$KEY_NO_ENV.json" ] && \
   [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_NO_ENV" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ]; then
  check "R5b implementation-relative registration needs no ambient root" PASS
else
  check "R5b implementation-relative registration failed without ambient root" FAIL
fi

THREAD_MISMATCH='thread-ambient-mismatch'
KEY_MISMATCH="$(key_for "$THREAD_MISMATCH")"
payload "$THREAD_MISMATCH" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_B" \
  bash "$REGISTER" >/dev/null 2>&1
if REC="$REG_DIR/$KEY_MISMATCH.json" node -e 'const r=require(process.env.REC);process.exit(r.state==="failed"?0:1)' 2>/dev/null; then
  check "R5c ambient root mismatch cannot redirect the authoritative hook" PASS
else
  check "R5c ambient root mismatch registered an injected root" FAIL
fi

# True parallel distinct-root registration (same HOME, same immutable reader).
FAKE_C="$TMP/plugin C"
mkdir -p "$FAKE_C/hooks/lib" "$FAKE_C/.codex-plugin"
cp "$PLUGIN/.codex-plugin/plugin.json" "$FAKE_C/.codex-plugin/plugin.json"
cp "$PLUGIN/hooks/lib/zensu-log.sh" "$FAKE_C/hooks/lib/zensu-log.sh"
copy_registry_runtime "$FAKE_C"
THREAD_PAR_B='parallel-distinct-b'; THREAD_PAR_C='parallel-distinct-c'
run_register "$THREAD_PAR_B" "$FAKE_B" & PID_B=$!
run_register "$THREAD_PAR_C" "$FAKE_C" & PID_C=$!
wait "$PID_B"; RCB=$?; wait "$PID_C"; RCC=$?
KEY_PAR_B="$(key_for "$THREAD_PAR_B")"; KEY_PAR_C="$(key_for "$THREAD_PAR_C")"
ROOT_PAR_B="$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_PAR_B" node "$READER" 2>/dev/null)"
ROOT_PAR_C="$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_PAR_C" node "$READER" 2>/dev/null)"
if [ "$RCB" -eq 0 ] && [ "$RCC" -eq 0 ] && [ "$ROOT_PAR_B" = "$(canonical_path "$FAKE_B")" ] && \
   [ "$ROOT_PAR_C" = "$(canonical_path "$FAKE_C")" ] && [ -f "$REG_DIR/$KEY_PAR_B.json" ] && [ -f "$REG_DIR/$KEY_PAR_C.json" ]; then
  check "R5d parallel distinct roots retain exact independent records" PASS
else
  check "R5d parallel distinct-root registration failed" FAIL
fi

# A lookalike manifest is not a Zensu plugin even if its layout is compatible.
EVIL_PLUGIN="$TMP/not-zensu"
cp -R "$FAKE_C" "$EVIL_PLUGIN"
MANIFEST="$EVIL_PLUGIN/.codex-plugin/plugin.json" node -e '
  const fs=require("fs"), p=process.env.MANIFEST, m=JSON.parse(fs.readFileSync(p));
  m.name="not-zensu"; fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
'
THREAD_EVIL='thread-evil-manifest'; KEY_EVIL="$(key_for "$THREAD_EVIL")"
run_register "$THREAD_EVIL" "$EVIL_PLUGIN"
if REC="$REG_DIR/$KEY_EVIL.json" node -e 'const r=require(process.env.REC);process.exit(r.state==="failed"?0:1)' 2>/dev/null; then
  check "R5e registration rejects a non-Zensu manifest" PASS
else
  check "R5e lookalike manifest was registered" FAIL
fi

# Git Bash exports HOME as /c/... to native Node. Keep this pure function
# directly testable even on non-Windows CI.
if LIB="$REGISTRY_LIB" node -e '
  const {normalizeNativePath}=require(process.env.LIB);
  if (normalizeNativePath("/c/Users/test", true) !== "C:/Users/test") process.exit(1);
  if (normalizeNativePath("/tmp/test", true) !== "/tmp/test") process.exit(2);
'; then
  check "R5f Git Bash HOME normalization is deterministic" PASS
else
  check "R5f Git Bash HOME normalization is missing" FAIL
fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    WIN_HOME_DIR="$TMP/windows-native-home"; mkdir -p "$WIN_HOME_DIR"
    WIN_NATIVE="$(cd "$WIN_HOME_DIR" && pwd -W)"
    WIN_DRIVE="$(printf '%s' "$WIN_NATIVE" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    WIN_HOME="/$WIN_DRIVE${WIN_NATIVE#?:}"
    WIN_THREAD='thread-windows-git-bash'
    run_register "$WIN_THREAD" "$PLUGIN" "$WIN_HOME"
    WIN_READER="$WIN_HOME/.zensu/plugin-roots/codex/resolve-v1.js"
    if [ "$(env -i PATH="$PATH" HOME="$WIN_HOME" CODEX_THREAD_ID="$WIN_THREAD" node "$WIN_READER" 2>/dev/null)" = "$PLUGIN_CANON" ]; then
      check "R5g real Git Bash /c HOME registers and resolves end-to-end" PASS
    else
      check "R5g real Git Bash /c HOME registration failed" FAIL
    fi
    ;;
  *) check "R5g real Git Bash /c HOME covered by Windows CI" PASS ;;
esac

if [ ! -e "$PROJECT/.zensu/state/session-id-current.txt" ] && [ ! -e "$PROJECT/.zensu/state/plugin-root" ]; then
  check "R6 registration creates no project-local locator" PASS
else
  check "R6 project-local locator unexpectedly created" FAIL
fi

if env -i PATH="$PATH" HOME="$TEST_HOME" node "$READER" >/dev/null 2>&1; then
  check "R7 reader fails closed without CODEX_THREAD_ID" FAIL
else
  check "R7 reader fails closed without CODEX_THREAD_ID" PASS
fi
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID='unknown-but-nonempty-thread' node "$READER" >/dev/null 2>&1; then
  check "R7b reader rejects an unknown nonempty thread id" FAIL
else
  check "R7b reader rejects an unknown nonempty thread id" PASS
fi

DIR_MODE="$(stat -f %Lp "$REG_DIR" 2>/dev/null || stat -c %a "$REG_DIR" 2>/dev/null || echo unknown)"
REC_MODE="$(stat -f %Lp "$REC_A" 2>/dev/null || stat -c %a "$REC_A" 2>/dev/null || echo unknown)"
READER_MODE="$(stat -f %Lp "$READER" 2>/dev/null || stat -c %a "$READER" 2>/dev/null || echo unknown)"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) check "R8 private registry modes skipped on Windows" PASS ;;
  *) if [ "$DIR_MODE" = 700 ] && [ "$REC_MODE" = 600 ] && [ "$READER_MODE" = 600 ]; then
       check "R8 registry directory and artifacts are private" PASS
     else
       check "R8 private modes (dir=$DIR_MODE record=$REC_MODE reader=$READER_MODE)" FAIL
     fi ;;
esac

cp "$REC_A" "$TMP/record-a.json"
if REC="$REC_A" node -e '
  const r=JSON.parse(require("fs").readFileSync(process.env.REC));
  if (r.schemaVersion!==2 || r.state!=="ready" || r.readerName!=="resolve-v1.js" ||
      !/^[a-f0-9]{64}$/.test(r.readerSha256||"") || !/^[a-f0-9]{64}$/.test(r.attemptId||"")) process.exit(1);
'; then
  check "R8b record binds the immutable reader digest" PASS
else
  check "R8b record has no valid reader digest" FAIL
fi
REC="$REC_A" node -e 'const fs=require("fs");const p=process.env.REC;const j=JSON.parse(fs.readFileSync(p));j.sessionId="other";fs.writeFileSync(p,JSON.stringify(j));'
chmod 600 "$REC_A" 2>/dev/null || true
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
  check "R9 reader rejects a mismatched record identity" FAIL
else
  check "R9 reader rejects a mismatched record identity" PASS
fi
cp "$TMP/record-a.json" "$REC_A"; chmod 600 "$REC_A" 2>/dev/null || true

printf '%s' '{' > "$REC_A"
chmod 600 "$REC_A" 2>/dev/null || true
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
  check "R10 reader rejects malformed JSON" FAIL
else
  check "R10 reader rejects malformed JSON" PASS
fi
cp "$TMP/record-a.json" "$REC_A"; chmod 600 "$REC_A" 2>/dev/null || true

REC="$REC_A" node -e 'require("fs").writeFileSync(process.env.REC,"x".repeat(70000))'
chmod 600 "$REC_A" 2>/dev/null || true
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
  check "R11 reader rejects an oversized record" FAIL
else
  check "R11 reader rejects an oversized record" PASS
fi
cp "$TMP/record-a.json" "$REC_A"; chmod 600 "$REC_A" 2>/dev/null || true

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) check "R12 permissive-mode rejection skipped on Windows" PASS ;;
  *)
    chmod 644 "$REC_A"
    if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
      check "R12 reader rejects a permissive record" FAIL
    else
      check "R12 reader rejects a permissive record" PASS
    fi
    chmod 600 "$REC_A"
    chmod 644 "$READER"
    if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
      check "R13 reader rejects permissive reader permissions" FAIL
    else
      check "R13 reader rejects permissive reader permissions" PASS
    fi
    chmod 600 "$READER"
    ;;
esac

printf '%s\n' '# fixture tamper' >> "$FAKE_B/hooks/lib/zensu-log.sh"
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_B" node "$READER" >/dev/null 2>&1; then
  check "R14 reader rejects a changed helper hash" FAIL
else
  check "R14 reader rejects a changed helper hash" PASS
fi

# A second implementation attempting to publish different bytes as resolve-v1
# must be rejected. The exact old session record is invalidated before failure,
# and the shared reader remains byte-for-byte unchanged.
VERSION_PLUGIN="$TMP/plugin-new-reader"
cp -R "$FAKE_C" "$VERSION_PLUGIN"
printf '\n// incompatible resolve-v1 fixture\n' >> "$VERSION_PLUGIN/hooks/lib/codex-plugin-root-resolve-v1.js"
THREAD_VERSION='thread-reader-version'
run_register "$THREAD_VERSION" "$PLUGIN"
KEY_VERSION="$(key_for "$THREAD_VERSION")"; REC_VERSION="$REG_DIR/$KEY_VERSION.json"
READER_HASH_BEFORE="$(shasum -a 256 "$READER" | cut -d' ' -f1)"
run_register "$THREAD_VERSION" "$VERSION_PLUGIN"
READER_HASH_AFTER="$(shasum -a 256 "$READER" | cut -d' ' -f1)"
if REC="$REC_VERSION" node -e 'const r=require(process.env.REC);process.exit(r.state==="failed"?0:1)' 2>/dev/null && \
   [ "$READER_HASH_BEFORE" = "$READER_HASH_AFTER" ] && \
   ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_VERSION" node "$READER" >/dev/null 2>&1; then
  check "R14b incompatible reader version fails closed without replacing v1" PASS
else
  check "R14b incompatible reader left stale record or replaced v1" FAIL
fi

# Registrar-only maintenance must not change the immutable reader protocol.
REGISTRAR_ONLY="$TMP/plugin-registrar-only"
cp -R "$FAKE_C" "$REGISTRAR_ONLY"
printf '\n// registrar-only maintenance fixture\n' >> "$REGISTRAR_ONLY/hooks/lib/codex-plugin-root-registry.js"
THREAD_REGISTRAR='thread-registrar-only'
READER_HASH_BEFORE="$(shasum -a 256 "$READER" | cut -d' ' -f1)"
run_register "$THREAD_REGISTRAR" "$REGISTRAR_ONLY"
READER_HASH_AFTER="$(shasum -a 256 "$READER" | cut -d' ' -f1)"
if [ "$READER_HASH_BEFORE" = "$READER_HASH_AFTER" ] && \
   [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_REGISTRAR" node "$READER" 2>/dev/null)" = "$(canonical_path "$REGISTRAR_ONLY")" ]; then
  check "R14e registrar-only changes preserve immutable reader compatibility" PASS
else
  check "R14e registrar-only change invalidated reader v1" FAIL
fi

# True same-session overlap: the valid attempt owns the lock first; the invalid
# attempt must wait, then tombstone the ready result and fail closed.
RACE_THREAD='thread-same-session-race'; RACE_KEY="$(key_for "$RACE_THREAD")"
RACE_BARRIER="$TMP/race-barrier"; mkdir -p "$RACE_BARRIER"
payload "$RACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
  NODE_ENV=test ZENSU_CODEX_TEST_BARRIER_DIR="$RACE_BARRIER" bash "$REGISTER" >/dev/null 2>&1 & RACE_VALID_PID=$!
i=0; while [ ! -e "$RACE_BARRIER/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$RACE_BARRIER/registrar.reached" ]; then
  if [ -f "$REG_DIR/.locks/$RACE_KEY.lock" ] && [ ! -L "$REG_DIR/.locks/$RACE_KEY.lock" ]; then
    check "R14f0 session lock is atomically published as complete owner metadata" PASS
  else
    check "R14f0 session lock exposes an ownerless directory initialization window" FAIL
  fi
  payload "$RACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$EVIL_PLUGIN" \
    bash "$EVIL_PLUGIN/hooks/session-start-register-plugin-root.sh" >/dev/null 2>&1 & RACE_INVALID_PID=$!
  : > "$RACE_BARRIER/registrar.release"
  wait "$RACE_VALID_PID"; wait "$RACE_INVALID_PID"
  if REC="$REG_DIR/$RACE_KEY.json" node -e 'const r=require(process.env.REC);process.exit(r.state==="failed"?0:1)' 2>/dev/null && \
     ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$RACE_THREAD" node "$READER" >/dev/null 2>&1 && \
     [ ! -e "$REG_DIR/.locks/$RACE_KEY.lock" ]; then
    check "R14f same-session registration is serialized and last failure wins" PASS
  else
    check "R14f same-session race republished a stale ready record" FAIL
  fi
else
  check "R14f same-session race barrier was not reached" FAIL
  kill "$RACE_VALID_PID" 2>/dev/null || true
fi

# Two global-lock recoverers must not let a slow stale snapshot displace the
# fast contender's newly published live maintenance lock. Bind the winning
# PID/token and its registering record, then require exact bytes to remain
# unchanged while the slow contender resumes.
LOCK_RACE_THREAD='thread-stale-lock-replacement'; LOCK_RACE_KEY="$(key_for "$LOCK_RACE_THREAD")"
( : ) & LOCK_DEAD_PID=$!; wait "$LOCK_DEAD_PID"
mkdir -p "$REG_DIR/.locks"
MAINTENANCE_LOCK="$REG_DIR/.locks/registry-maintenance.lock"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$LOCK_DEAD_PID" "$(printf 'a%.0s' {1..64})" > "$MAINTENANCE_LOCK"
chmod 600 "$MAINTENANCE_LOCK" 2>/dev/null || true
LOCK_SLOW_BARRIER="$TMP/lock-slow-barrier"; LOCK_SLOW_REGISTRAR="$TMP/lock-slow-registrar"; LOCK_FAST_BARRIER="$TMP/lock-fast-barrier"
mkdir -p "$LOCK_SLOW_BARRIER" "$LOCK_SLOW_REGISTRAR" "$LOCK_FAST_BARRIER"
payload "$LOCK_RACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_DIR="$LOCK_SLOW_BARRIER" \
  ZENSU_CODEX_TEST_BARRIER_DIR="$LOCK_SLOW_REGISTRAR" bash "$REGISTER" >/dev/null 2>&1 & LOCK_SLOW_PID=$!
i=0; while [ ! -e "$LOCK_SLOW_BARRIER/lock-recovery-snapshot.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$LOCK_SLOW_BARRIER/lock-recovery-snapshot.reached" ]; then
  payload "$LOCK_RACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
    ZENSU_CODEX_TEST_BARRIER_DIR="$LOCK_FAST_BARRIER" bash "$REGISTER" >/dev/null 2>&1 & LOCK_FAST_PID=$!
  i=0; while [ ! -e "$LOCK_FAST_BARRIER/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
  FAST_RECORD="$REG_DIR/$LOCK_RACE_KEY.json"
  FAST_LOCK_BYTES="$(cat "$MAINTENANCE_LOCK" 2>/dev/null || true)"
  FAST_OWNER_PID="$(LOCK="$MAINTENANCE_LOCK" node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.env.LOCK)).pid))}catch{}')"
  FAST_OWNER_TOKEN="$(LOCK="$MAINTENANCE_LOCK" node -e 'try{process.stdout.write(JSON.parse(require("fs").readFileSync(process.env.LOCK)).token||"")}catch{}')"
  FAST_ATTEMPT_ID="$(REC="$FAST_RECORD" node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.env.REC));if(r.state==="registering")process.stdout.write(r.attemptId||"")}catch{}')"
  FAST_MARKER="$(find "$REG_DIR/.pending" -maxdepth 1 -type f -name "attempt.$LOCK_FAST_PID.*.json" 2>/dev/null | head -n 1)"
  : > "$LOCK_SLOW_BARRIER/lock-recovery-snapshot.release"
  sleep 0.2
  if [ -e "$LOCK_FAST_BARRIER/registrar.reached" ] && [ -n "$FAST_OWNER_PID" ] && kill -0 "$FAST_OWNER_PID" 2>/dev/null && \
     [ "${#FAST_OWNER_TOKEN}" -eq 64 ] && [ "${#FAST_ATTEMPT_ID}" -eq 64 ] && [ -n "$FAST_MARKER" ] && \
     [ "$(cat "$MAINTENANCE_LOCK" 2>/dev/null || true)" = "$FAST_LOCK_BYTES" ] && \
     [ "$(REC="$FAST_RECORD" node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.env.REC));process.stdout.write(r.attemptId||"")}catch{}')" = "$FAST_ATTEMPT_ID" ] && \
     kill -0 "$LOCK_SLOW_PID" 2>/dev/null; then
    check "R14f1 stale recovery preserves the bound fast owner and record" PASS
  else
    check "R14f1 stale recovery displaced the bound fast winner" FAIL
  fi
  : > "$LOCK_FAST_BARRIER/registrar.release"
  wait "$LOCK_FAST_PID"; LOCK_FAST_RC=$?
  i=0; while [ ! -e "$LOCK_SLOW_REGISTRAR/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
  [ -e "$LOCK_SLOW_REGISTRAR/registrar.reached" ] && : > "$LOCK_SLOW_REGISTRAR/registrar.release"
  wait "$LOCK_SLOW_PID"; LOCK_SLOW_RC=$?
  if [ "$LOCK_FAST_RC" -eq 0 ] && [ "$LOCK_SLOW_RC" -eq 0 ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$LOCK_RACE_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     [ ! -e "$MAINTENANCE_LOCK" ] && [ ! -e "$REG_DIR/.locks/$LOCK_RACE_KEY.lock" ] && \
     ! PENDING="$REG_DIR/.pending" SID="$LOCK_RACE_THREAD" node -e '
       const fs=require("fs"),p=require("path");process.exit(fs.readdirSync(process.env.PENDING).some(n=>{try{return JSON.parse(fs.readFileSync(p.join(process.env.PENDING,n))).session_id===process.env.SID}catch{return false}})?0:1)
     ' 2>/dev/null; then
    check "R14f1b both contenders exit cleanly with final reader and markers consistent" PASS
  else
    check "R14f1b contender status or final registry state is inconsistent" FAIL
  fi
else
  check "R14f1 stale-lock recovery barrier was not reached" FAIL
  check "R14f1b stale-lock recovery fixture did not complete" FAIL
  kill "$LOCK_SLOW_PID" 2>/dev/null || true
fi

# Claim publication stages bytes under a disjoint `.lock-publish.*` name. A
# simultaneous scanner must ignore that bounded temp, publish its own complete
# claim, and recover the global lock without treating the temp as malformed.
CLAIM_STAGE_THREAD_A='thread-claim-stage-a'; CLAIM_STAGE_THREAD_B='thread-claim-stage-b'
( : ) & CLAIM_STAGE_DEAD_PID=$!; wait "$CLAIM_STAGE_DEAD_PID"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$CLAIM_STAGE_DEAD_PID" "$(printf '1%.0s' {1..64})" > "$MAINTENANCE_LOCK"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$CLAIM_STAGE_DEAD_PID" "$(printf '2%.0s' {1..64})" > "$MAINTENANCE_LOCK.recovery"
chmod 600 "$MAINTENANCE_LOCK" "$MAINTENANCE_LOCK.recovery" 2>/dev/null || true
CLAIM_STAGE_BARRIER="$TMP/claim-stage-barrier"; CLAIM_STAGE_WINNER_BARRIER="$TMP/claim-stage-winner"
mkdir -p "$CLAIM_STAGE_BARRIER" "$CLAIM_STAGE_WINNER_BARRIER"
payload "$CLAIM_STAGE_THREAD_A" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_DIR="$CLAIM_STAGE_BARRIER" \
  ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_NAME='claim-publication-staged' bash "$REGISTER" >/dev/null 2>&1 & CLAIM_STAGE_PID_A=$!
i=0; while [ ! -e "$CLAIM_STAGE_BARRIER/claim-publication-staged.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$CLAIM_STAGE_BARRIER/claim-publication-staged.reached" ]; then
  CLAIM_TEMP="$(find "$REG_DIR/.locks" -maxdepth 1 -type f -name '.lock-publish.*.tmp' -print -quit 2>/dev/null)"
  payload "$CLAIM_STAGE_THREAD_B" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
    ZENSU_CODEX_TEST_BARRIER_DIR="$CLAIM_STAGE_WINNER_BARRIER" bash "$REGISTER" >/dev/null 2>&1 & CLAIM_STAGE_PID_B=$!
  i=0; while [ ! -e "$CLAIM_STAGE_WINNER_BARRIER/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
  if [ -n "$CLAIM_TEMP" ] && [ -e "$CLAIM_STAGE_WINNER_BARRIER/registrar.reached" ]; then
    check "R14f1c simultaneous claim scanner ignores disjoint publication staging" PASS
  else
    check "R14f1c claim publication temp poisoned the simultaneous scanner" FAIL
  fi
  : > "$CLAIM_STAGE_BARRIER/claim-publication-staged.release"
  : > "$CLAIM_STAGE_WINNER_BARRIER/registrar.release"
  wait "$CLAIM_STAGE_PID_B"; CLAIM_STAGE_RC_B=$?
  wait "$CLAIM_STAGE_PID_A"; CLAIM_STAGE_RC_A=$?
  if [ "$CLAIM_STAGE_RC_A" -eq 0 ] && [ "$CLAIM_STAGE_RC_B" -eq 0 ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$CLAIM_STAGE_THREAD_A" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$CLAIM_STAGE_THREAD_B" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     [ ! -e "$MAINTENANCE_LOCK" ] && [ ! -e "$MAINTENANCE_LOCK.recovery" ] && \
     ! find "$REG_DIR/.locks" -maxdepth 1 \( -name '.lock-publish.*.tmp' -o -name 'registry-maintenance.lock.recovery.reclaim.*' \) -print -quit | grep -q .; then
    check "R14f1d simultaneous claim publishers finish with both records intact" PASS
  else
    check "R14f1d simultaneous claim publication left inconsistent state" FAIL
  fi
else
  check "R14f1c claim-publication staging barrier was not reached" FAIL
  check "R14f1d simultaneous claim fixture did not complete" FAIL
  kill "$CLAIM_STAGE_PID_A" 2>/dev/null || true
fi

# A process crash can strand the fixed recovery guard itself. Its complete
# owner metadata must be reclaimable without leaving either the guard or an
# election claim behind.
RECOVERY_CRASH_THREAD='thread-crashed-recovery-guard'; RECOVERY_CRASH_KEY="$(key_for "$RECOVERY_CRASH_THREAD")"
run_register "$RECOVERY_CRASH_THREAD" "$PLUGIN"
( : ) & RECOVERY_DEAD_PID=$!; wait "$RECOVERY_DEAD_PID"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$RECOVERY_DEAD_PID" "$(printf 'c%.0s' {1..64})" > "$REG_DIR/.locks/$RECOVERY_CRASH_KEY.lock.recovery"
chmod 600 "$REG_DIR/.locks/$RECOVERY_CRASH_KEY.lock.recovery" 2>/dev/null || true
run_register "$RECOVERY_CRASH_THREAD" "$PLUGIN"
if [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$RECOVERY_CRASH_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
   [ ! -e "$REG_DIR/.locks/$RECOVERY_CRASH_KEY.lock.recovery" ] && \
   ! find "$REG_DIR/.locks" -maxdepth 1 -name "$RECOVERY_CRASH_KEY.lock.recovery.reclaim.*" -print -quit | grep -q .; then
  check "R14f2 crashed recovery guard is reclaimed without stranded claims" PASS
else
  check "R14f2 crashed recovery guard remained a permanent blocker" FAIL
fi

# The unique election claim is itself a reader guard. If its owner crashes
# before publishing the fixed recovery guard, the next registration reclaims
# that exact tokenized path rather than leaving a permanent blocker.
( : ) & RECOVERY_CLAIM_DEAD_PID=$!; wait "$RECOVERY_CLAIM_DEAD_PID"
RECOVERY_CLAIM_TOKEN="$(printf 'f%.0s' {1..64})"
RECOVERY_CLAIM_PATH="$REG_DIR/.locks/$RECOVERY_CRASH_KEY.lock.recovery.reclaim.$RECOVERY_CLAIM_DEAD_PID.$RECOVERY_CLAIM_TOKEN"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$RECOVERY_CLAIM_DEAD_PID" "$RECOVERY_CLAIM_TOKEN" > "$RECOVERY_CLAIM_PATH"
chmod 600 "$RECOVERY_CLAIM_PATH" 2>/dev/null || true
if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$RECOVERY_CRASH_THREAD" node "$READER" >/dev/null 2>&1; then
  run_register "$RECOVERY_CRASH_THREAD" "$PLUGIN"
  if [ ! -e "$RECOVERY_CLAIM_PATH" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$RECOVERY_CRASH_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ]; then
    check "R14f2b crashed tokenized recovery claim fails closed then self-heals" PASS
  else
    check "R14f2b stale recovery claim remained after a successful retry" FAIL
  fi
else
  check "R14f2b reader ignored an active recovery claim" FAIL
fi

# A stale snapshot is never authority to remove a later live recovery guard.
# Pause after the snapshot, replace the guard with a live owner, and require
# the registrar to wait until that exact owner dies.
RECOVERY_REPLACE_THREAD='thread-recovery-guard-replacement'; RECOVERY_REPLACE_KEY="$(key_for "$RECOVERY_REPLACE_THREAD")"
run_register "$RECOVERY_REPLACE_THREAD" "$PLUGIN"
( : ) & RECOVERY_OLD_PID=$!; wait "$RECOVERY_OLD_PID"
RECOVERY_REPLACE_PATH="$REG_DIR/.locks/$RECOVERY_REPLACE_KEY.lock.recovery"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
  "$RECOVERY_OLD_PID" "$(printf 'd%.0s' {1..64})" > "$RECOVERY_REPLACE_PATH"
chmod 600 "$RECOVERY_REPLACE_PATH" 2>/dev/null || true
RECOVERY_REPLACE_BARRIER="$TMP/recovery-replace-barrier"; mkdir -p "$RECOVERY_REPLACE_BARRIER"
payload "$RECOVERY_REPLACE_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_DIR="$RECOVERY_REPLACE_BARRIER" \
  ZENSU_CODEX_BOOTSTRAP_TEST_BARRIER_NAME='recovery-guard-snapshot' bash "$REGISTER" >/dev/null 2>&1 & RECOVERY_REPLACE_REG_PID=$!
i=0; while [ ! -e "$RECOVERY_REPLACE_BARRIER/recovery-guard-snapshot.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$RECOVERY_REPLACE_BARRIER/recovery-guard-snapshot.reached" ]; then
  sleep 30 & RECOVERY_LIVE_PID=$!
  RECOVERY_LIVE_TOKEN="$(printf 'e%.0s' {1..64})"
  rm -f "$RECOVERY_REPLACE_PATH"
  printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-07-14T00:00:00.000Z"}\n' \
    "$RECOVERY_LIVE_PID" "$RECOVERY_LIVE_TOKEN" > "$RECOVERY_REPLACE_PATH"
  chmod 600 "$RECOVERY_REPLACE_PATH" 2>/dev/null || true
  : > "$RECOVERY_REPLACE_BARRIER/recovery-guard-snapshot.release"
  sleep 0.2
  if kill -0 "$RECOVERY_REPLACE_REG_PID" 2>/dev/null && \
     LOCK="$RECOVERY_REPLACE_PATH" TOKEN="$RECOVERY_LIVE_TOKEN" node -e '
       const j=JSON.parse(require("fs").readFileSync(process.env.LOCK));process.exit(j.token===process.env.TOKEN?0:1)
     ' 2>/dev/null; then
    check "R14f3 stale snapshot never removes a later live recovery guard" PASS
  else
    check "R14f3 stale snapshot displaced a later live recovery guard" FAIL
  fi
  kill "$RECOVERY_LIVE_PID" 2>/dev/null || true; wait "$RECOVERY_LIVE_PID" 2>/dev/null || true
  wait "$RECOVERY_REPLACE_REG_PID"
  if [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$RECOVERY_REPLACE_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     [ ! -e "$RECOVERY_REPLACE_PATH" ]; then
    check "R14f4 registration resumes after the replacement owner exits" PASS
  else
    check "R14f4 replacement recovery guard was not safely reclaimed" FAIL
  fi
else
  check "R14f3 recovery-guard replacement barrier was not reached" FAIL
  check "R14f4 recovery-guard replacement fixture did not complete" FAIL
  kill "$RECOVERY_REPLACE_REG_PID" 2>/dev/null || true
fi

# A missing mutable registrar is discovered only after the bootstrap has
# published its session tombstone, so an older ready record cannot survive.
MISSING_REGISTRAR="$TMP/plugin-missing-registrar"
cp -R "$FAKE_C" "$MISSING_REGISTRAR"
MISSING_THREAD='thread-missing-registrar'; MISSING_KEY="$(key_for "$MISSING_THREAD")"
run_register "$MISSING_THREAD" "$PLUGIN"
rm "$MISSING_REGISTRAR/hooks/lib/codex-plugin-root-registry.js"
run_register "$MISSING_THREAD" "$MISSING_REGISTRAR"
if REC="$REG_DIR/$MISSING_KEY.json" node -e 'const r=require(process.env.REC);process.exit(r.state==="failed"&&r.failureCode==="REGISTRAR_MISSING"?0:1)' 2>/dev/null && \
   ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$MISSING_THREAD" node "$READER" >/dev/null 2>&1; then
  check "R14g missing registrar invalidates the exact old session" PASS
else
  check "R14g missing registrar left an old ready session resolvable" FAIL
fi

NODELESS_THREAD='thread-node-missing'; NODELESS_KEY="$(key_for "$NODELESS_THREAD")"
run_register "$NODELESS_THREAD" "$PLUGIN"
NODELESS_BIN="$TMP/nodeless-bin"; mkdir -p "$NODELESS_BIN"
for tool in bash dirname pwd mkdir cat chmod mv rm; do
  TOOL_PATH="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$TOOL_PATH" ] && ln -s "$TOOL_PATH" "$NODELESS_BIN/$tool" 2>/dev/null
done
payload "$NODELESS_THREAD" | env -i PATH="$NODELESS_BIN" HOME="$TEST_HOME" CODEX_THREAD_ID="$NODELESS_THREAD" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$REGISTER" >/dev/null 2>&1
if PENDING="$REG_DIR/.pending" SID="$NODELESS_THREAD" node -e '
  const fs=require("fs"),p=require("path");
  process.exit(fs.readdirSync(process.env.PENDING).some(n=>{try{return JSON.parse(fs.readFileSync(p.join(process.env.PENDING,n))).session_id===process.env.SID}catch{return false}})?0:1)
' 2>/dev/null && ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$NODELESS_THREAD" node "$READER" >/dev/null 2>&1; then
  check "R14h missing Node leaves a durable exact-session pending guard" PASS
else
  check "R14h restoring Node resurrected an old ready session" FAIL
fi

# A crash before raw payload publication leaves a complete provisional marker,
# never a zero-byte artifact. A fresh marker is globally fail-closed. If the
# dead marker has no trustworthy session identity, it stays globally closed
# until a successful transaction invalidates every prior record before cleanup.
PROVISIONAL_THREAD='thread-provisional-crash'
run_register "$PROVISIONAL_THREAD" "$PLUGIN"
PROVISIONAL_BARRIER="$TMP/provisional-barrier"; mkdir -p "$PROVISIONAL_BARRIER"
payload "$PROVISIONAL_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_SHELL_TEST_BARRIER_DIR="$PROVISIONAL_BARRIER" bash "$REGISTER" >/dev/null 2>&1 & PROVISIONAL_PID=$!
i=0; while [ ! -e "$PROVISIONAL_BARRIER/pending-provisional.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$PROVISIONAL_BARRIER/pending-provisional.reached" ]; then
  PROVISIONAL_MARKER="$(find "$REG_DIR/.pending" -maxdepth 1 -type f -name "attempt.$PROVISIONAL_PID.*.json" 2>/dev/null | head -n 1)"
  if [ -n "$PROVISIONAL_MARKER" ] && MARKER="$PROVISIONAL_MARKER" node -e '
    const fs=require("fs"),j=JSON.parse(fs.readFileSync(process.env.MARKER));
    process.exit(j.state==="capturing"&&Number.isSafeInteger(j.ownerPid)?0:1)
  ' 2>/dev/null; then
    check "R14k shell publishes a complete provisional marker before reading payload" PASS
  else
    check "R14k shell exposed an empty or malformed provisional marker" FAIL
  fi
  if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
    check "R14k1 fresh provisional marker makes the reader fail closed" PASS
  else
    check "R14k1 fresh provisional marker did not block stale ready state" FAIL
  fi
  kill -9 "$PROVISIONAL_PID" 2>/dev/null || true; wait "$PROVISIONAL_PID" 2>/dev/null || true
  [ -n "$PROVISIONAL_MARKER" ] && MARKER="$PROVISIONAL_MARKER" node -e 'const fs=require("fs"),d=new Date(Date.now()-120000);fs.utimesSync(process.env.MARKER,d,d)'
  if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
    PROVISIONAL_RECOVERY_THREAD='thread-provisional-global-recovery'
    run_register "$PROVISIONAL_RECOVERY_THREAD" "$PLUGIN"
    if [ -n "$PROVISIONAL_MARKER" ] && [ ! -e "$PROVISIONAL_MARKER" ] && \
       [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$PROVISIONAL_RECOVERY_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
       ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$PROVISIONAL_THREAD" node "$READER" >/dev/null 2>&1; then
      check "R14k2 indeterminate recovery purges prior records before guard removal" PASS
    else
      check "R14k2 indeterminate guard was removed without safe invalidation" FAIL
    fi
    run_register "$THREAD_A" "$PLUGIN"
  else
    check "R14k2 dead indeterminate marker was unsafely age-ignored" FAIL
  fi
else
  check "R14k provisional publication barrier was not reached" FAIL
  check "R14k1 fresh provisional marker fixture did not complete" FAIL
  check "R14k2 indeterminate recovery fixture did not complete" FAIL
  kill "$PROVISIONAL_PID" 2>/dev/null || true
fi

# Raw payload staging lives outside canonical .pending enumeration. Once a
# crashed capture has complete staged bytes, an aged guard is exact-session:
# unrelated sessions resolve, the target stays closed, and only a successful
# same-session retry removes both artifacts.
STAGED_CRASH_THREAD='thread-staged-payload-crash'
run_register "$STAGED_CRASH_THREAD" "$PLUGIN"
STAGED_BARRIER="$TMP/staged-payload-barrier"; mkdir -p "$STAGED_BARRIER"
payload "$STAGED_CRASH_THREAD" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_SHELL_PAYLOAD_TEST_BARRIER_DIR="$STAGED_BARRIER" bash "$REGISTER" >/dev/null 2>&1 & STAGED_CRASH_PID=$!
i=0; while [ ! -e "$STAGED_BARRIER/pending-payload-staged.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$STAGED_BARRIER/pending-payload-staged.reached" ]; then
  STAGED_MARKER="$(find "$REG_DIR/.pending" -maxdepth 1 -type f -name "attempt.$STAGED_CRASH_PID.*.json" 2>/dev/null | head -n 1)"
  STAGED_NAME="$(MARKER="$STAGED_MARKER" node -e 'const j=JSON.parse(require("fs").readFileSync(process.env.MARKER));process.stdout.write(j.stagingName||"")' 2>/dev/null)"
  STAGED_PAYLOAD="$REG_DIR/.staging/$STAGED_NAME"
  kill -9 "$STAGED_CRASH_PID" 2>/dev/null || true; wait "$STAGED_CRASH_PID" 2>/dev/null || true
  MARKER="$STAGED_MARKER" STAGE="$STAGED_PAYLOAD" node -e '
    const fs=require("fs"),d=new Date(Date.now()-120000);fs.utimesSync(process.env.MARKER,d,d);fs.utimesSync(process.env.STAGE,d,d)
  '
  if [ -f "$STAGED_PAYLOAD" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$STAGED_CRASH_THREAD" node "$READER" >/dev/null 2>&1; then
    check "R14k3 stale staged payload guards only its exact session" PASS
  else
    check "R14k3 staged payload artifact poisoned unrelated resolution or exposed its target" FAIL
  fi
  run_register "$STAGED_CRASH_THREAD" "$PLUGIN"
  if [ ! -e "$STAGED_MARKER" ] && [ ! -e "$STAGED_PAYLOAD" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$STAGED_CRASH_THREAD" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ]; then
    check "R14k4 same-session retry removes staged and canonical guards" PASS
  else
    check "R14k4 same-session retry left a staged or canonical guard" FAIL
  fi
else
  check "R14k3 staged-payload barrier was not reached" FAIL
  check "R14k4 staged-payload recovery fixture did not complete" FAIL
  kill "$STAGED_CRASH_PID" 2>/dev/null || true
fi

# Any aged, dead canonical marker whose JSON has no valid session_id is still
# identity-indeterminate. It remains a global reader guard until a successful
# broad cleanup. The global maintenance lock must serialize that cleanup ahead
# of a distinct-session publisher so neither new ready record is erased.
BROAD_OLD_THREAD='thread-broad-old-record'
run_register "$BROAD_OLD_THREAD" "$PLUGIN"
( : ) & BROAD_DEAD_PID=$!; wait "$BROAD_DEAD_PID"
BROAD_MARKER="$REG_DIR/.pending/attempt.$BROAD_DEAD_PID.777.888.json"
printf '{}\n' > "$BROAD_MARKER"; chmod 600 "$BROAD_MARKER" 2>/dev/null || true
MARKER="$BROAD_MARKER" node -e 'const fs=require("fs"),d=new Date(Date.now()-120000);fs.utimesSync(process.env.MARKER,d,d)'
if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$BROAD_OLD_THREAD" node "$READER" >/dev/null 2>&1; then
  check "R14k5 dead valid JSON without session identity remains fail-closed" PASS
else
  check "R14k5 identity-indeterminate JSON marker was ignored" FAIL
fi
BROAD_THREAD_A='thread-broad-concurrent-a'; BROAD_THREAD_B='thread-broad-concurrent-b'
BROAD_BARRIER_A="$TMP/broad-cleanup-a"; BROAD_BARRIER_B="$TMP/broad-cleanup-b"; mkdir -p "$BROAD_BARRIER_A" "$BROAD_BARRIER_B"
payload "$BROAD_THREAD_A" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
  ZENSU_CODEX_TEST_BARRIER_DIR="$BROAD_BARRIER_A" bash "$REGISTER" >/dev/null 2>&1 & BROAD_PID_A=$!
i=0; while [ ! -e "$BROAD_BARRIER_A/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$BROAD_BARRIER_A/registrar.reached" ]; then
  payload "$BROAD_THREAD_B" | env -i PATH="$PATH" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" NODE_ENV=test \
    ZENSU_CODEX_TEST_BARRIER_DIR="$BROAD_BARRIER_B" bash "$REGISTER" >/dev/null 2>&1 & BROAD_PID_B=$!
  sleep 0.2
  if [ ! -e "$BROAD_BARRIER_B/registrar.reached" ] && kill -0 "$BROAD_PID_B" 2>/dev/null; then
    check "R14k6 global maintenance lock serializes distinct-session publication" PASS
  else
    check "R14k6 distinct-session publisher entered the broad deletion window" FAIL
  fi
  : > "$BROAD_BARRIER_A/registrar.release"
  wait "$BROAD_PID_A"; BROAD_RC_A=$?
  i=0; while [ ! -e "$BROAD_BARRIER_B/registrar.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
  [ -e "$BROAD_BARRIER_B/registrar.reached" ] && : > "$BROAD_BARRIER_B/registrar.release"
  wait "$BROAD_PID_B"; BROAD_RC_B=$?
  if [ "$BROAD_RC_A" -eq 0 ] && [ "$BROAD_RC_B" -eq 0 ] && [ ! -e "$BROAD_MARKER" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$BROAD_THREAD_A" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$BROAD_THREAD_B" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ] && \
     ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$BROAD_OLD_THREAD" node "$READER" >/dev/null 2>&1 && \
     [ ! -e "$MAINTENANCE_LOCK" ]; then
    check "R14k7 broad cleanup preserves both concurrently requested new records" PASS
  else
    check "R14k7 broad cleanup erased a concurrent ready record or leaked its guard" FAIL
  fi
  run_register "$THREAD_A" "$PLUGIN"
else
  check "R14k6 first broad-cleanup registrar barrier was not reached" FAIL
  check "R14k7 concurrent broad-cleanup fixture did not complete" FAIL
  kill "$BROAD_PID_A" 2>/dev/null || true
fi

# The wrapper must persist the raw SessionStart payload before it checks Node.
# CODEX_THREAD_ID is not guaranteed inside hook subprocesses, so restoring Node
# later must still leave the exact old ready record blocked.
PAYLOAD_ONLY_THREAD='thread-node-missing-payload-only'; PAYLOAD_ONLY_KEY="$(key_for "$PAYLOAD_ONLY_THREAD")"
run_register "$PAYLOAD_ONLY_THREAD" "$PLUGIN"
payload "$PAYLOAD_ONLY_THREAD" | env -i PATH="$NODELESS_BIN" HOME="$TEST_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
  bash "$REGISTER" >/dev/null 2>&1
if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$PAYLOAD_ONLY_THREAD" node "$READER" >/dev/null 2>&1; then
  check "R14i payload-backed pre-bootstrap guard survives missing Node without ambient identity" PASS
else
  check "R14i missing Node without CODEX_THREAD_ID resurrected an old ready session" FAIL
fi

# A missing bootstrap fails before the Node coordinator can publish its normal
# tombstone. The shell-owned pending guard must already make the old record
# unusable and remain durable after the wrapper exits.
MISSING_BOOTSTRAP="$TMP/plugin-missing-bootstrap"
cp -R "$FAKE_C" "$MISSING_BOOTSTRAP"
MISSING_BOOTSTRAP_THREAD='thread-missing-bootstrap'; MISSING_BOOTSTRAP_KEY="$(key_for "$MISSING_BOOTSTRAP_THREAD")"
run_register "$MISSING_BOOTSTRAP_THREAD" "$PLUGIN"
rm "$MISSING_BOOTSTRAP/hooks/lib/codex-plugin-root-bootstrap.js"
run_register "$MISSING_BOOTSTRAP_THREAD" "$MISSING_BOOTSTRAP"
if ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$MISSING_BOOTSTRAP_THREAD" node "$READER" >/dev/null 2>&1; then
  check "R14j pre-bootstrap guard blocks stale ready state when coordinator is missing" PASS
else
  check "R14j missing coordinator left an old ready record usable" FAIL
fi

# Benign byte tampering (the script still parses) is detected through the
# record-bound digest. Explicitly removing the corrupt reader lets the trusted
# implementation republish and restore the exact session record.
printf '\n// post-publication tamper\n' >> "$READER"
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" >/dev/null 2>&1; then
  check "R14c reader digest rejects post-publication tampering" FAIL
else
  check "R14c reader digest rejects post-publication tampering" PASS
fi
rm -f "$READER"
run_register "$THREAD_A" "$PLUGIN"
SOURCE_HASH="$(shasum -a 256 "$READER_SOURCE" | cut -d' ' -f1)"
RESTORED_HASH="$(shasum -a 256 "$READER" | cut -d' ' -f1)"
if [ "$SOURCE_HASH" = "$RESTORED_HASH" ] && \
   [ "$(env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_A" node "$READER" 2>/dev/null)" = "$PLUGIN_CANON" ]; then
  check "R14d trusted re-registration restores reader and exact record" PASS
else
  check "R14d reader/record repair failed" FAIL
fi

mv "$FAKE_B" "$FAKE_B-moved"
if env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_B" node "$READER" >/dev/null 2>&1; then
  check "R15 reader rejects a moved or missing registered root" FAIL
else
  check "R15 reader rejects a moved or missing registered root" PASS
fi

THREAD_C='thread-c-symlink'
KEY_C="$(key_for "$THREAD_C")"
OUTSIDE="$TMP/outside.json"
printf '%s\n' 'sentinel' > "$OUTSIDE"
ln -s "$OUTSIDE" "$REG_DIR/$KEY_C.json"
run_register "$THREAD_C" "$PLUGIN"
if [ -L "$REG_DIR/$KEY_C.json" ] && [ "$(cat "$OUTSIDE")" = sentinel ] && \
   ! env -i PATH="$PATH" HOME="$TEST_HOME" CODEX_THREAD_ID="$THREAD_C" node "$READER" >/dev/null 2>&1; then
  check "R16 writer and reader refuse a symlinked record" PASS
else
  check "R16 symlinked record was followed or accepted" FAIL
fi

# Hermetic fail-closed fixtures for registry ancestors, reader, manifest, and
# helper leaves. No symlink target may be modified by registration/resolution.
SYM_REG_HOME="$TMP/symlink-registry-home"; SYM_REG_OUT="$TMP/symlink-registry-out"
mkdir -p "$SYM_REG_HOME/.zensu/plugin-roots" "$SYM_REG_OUT"
printf 'sentinel\n' > "$SYM_REG_OUT/sentinel.txt"
if ln -s "$SYM_REG_OUT" "$SYM_REG_HOME/.zensu/plugin-roots/codex" 2>/dev/null; then
  payload 'thread-symlink-registry-writer' | env -i PATH="$PATH" HOME="$SYM_REG_HOME" CLAUDE_PLUGIN_ROOT="$PLUGIN" \
    bash "$REGISTER" >/dev/null 2>&1
  if [ "$(cat "$SYM_REG_OUT/sentinel.txt")" = sentinel ] && [ ! -e "$SYM_REG_OUT/resolve-v1.js" ]; then
    check "R16b writer refuses a symlinked registry directory" PASS
  else
    check "R16b writer followed a symlinked registry directory" FAIL
  fi
else
  check "R16b symlink fixture unavailable" PASS
fi

NEG_HOME="$TMP/negative-home"; mkdir -p "$NEG_HOME"
NEG_THREAD='thread-negative-artifacts'
run_register "$NEG_THREAD" "$PLUGIN" "$NEG_HOME"
NEG_KEY="$(key_for "$NEG_THREAD")"; NEG_DIR="$NEG_HOME/.zensu/plugin-roots/codex"; NEG_READER="$NEG_DIR/resolve-v1.js"
mv "$NEG_READER" "$NEG_READER.real"
if ln -s "$NEG_READER.real" "$NEG_READER" 2>/dev/null; then
  if ! env -i PATH="$PATH" HOME="$NEG_HOME" CODEX_THREAD_ID="$NEG_THREAD" node "$NEG_READER" >/dev/null 2>&1; then
    check "R16c reader refuses a symlinked installed reader" PASS
  else
    check "R16c symlinked reader was accepted" FAIL
  fi
else
  check "R16c symlink fixture unavailable" PASS
fi
rm -f "$NEG_READER"; mv "$NEG_READER.real" "$NEG_READER"

node -e 'require("fs").appendFileSync(process.argv[1],"\n/*"+"x".repeat(70000)+"*/\n")' "$NEG_READER"
if ! env -i PATH="$PATH" HOME="$NEG_HOME" CODEX_THREAD_ID="$NEG_THREAD" node "$NEG_READER" >/dev/null 2>&1; then
  check "R16d reader rejects an oversized installed reader" PASS
else
  check "R16d oversized reader was accepted" FAIL
fi
cp "$READER_SOURCE" "$NEG_READER"; chmod 600 "$NEG_READER" 2>/dev/null || true

NEG_PLUGIN="$TMP/plugin-negative-leaves"; cp -R "$FAKE_C" "$NEG_PLUGIN"
NEG_LEAF_HOME="$TMP/negative-leaf-home"; mkdir -p "$NEG_LEAF_HOME"
NEG_LEAF_THREAD='thread-negative-leaves'; run_register "$NEG_LEAF_THREAD" "$NEG_PLUGIN" "$NEG_LEAF_HOME"
NEG_LEAF_READER="$NEG_LEAF_HOME/.zensu/plugin-roots/codex/resolve-v1.js"
MANIFEST_REAL="$TMP/plugin-manifest-real.json"
mv "$NEG_PLUGIN/.codex-plugin/plugin.json" "$MANIFEST_REAL"
if ln -s "$MANIFEST_REAL" "$NEG_PLUGIN/.codex-plugin/plugin.json" 2>/dev/null; then
  if ! env -i PATH="$PATH" HOME="$NEG_LEAF_HOME" CODEX_THREAD_ID="$NEG_LEAF_THREAD" node "$NEG_LEAF_READER" >/dev/null 2>&1; then
    check "R16e reader refuses a symlinked plugin manifest" PASS
  else
    check "R16e symlinked plugin manifest was accepted" FAIL
  fi
else
  check "R16e symlink fixture unavailable" PASS
fi
rm -f "$NEG_PLUGIN/.codex-plugin/plugin.json"; mv "$MANIFEST_REAL" "$NEG_PLUGIN/.codex-plugin/plugin.json"

HELPER_REAL="$TMP/zensu-log-real.sh"
mv "$NEG_PLUGIN/hooks/lib/zensu-log.sh" "$HELPER_REAL"
if ln -s "$HELPER_REAL" "$NEG_PLUGIN/hooks/lib/zensu-log.sh" 2>/dev/null; then
  if ! env -i PATH="$PATH" HOME="$NEG_LEAF_HOME" CODEX_THREAD_ID="$NEG_LEAF_THREAD" node "$NEG_LEAF_READER" >/dev/null 2>&1; then
    check "R16f reader refuses a symlinked helper" PASS
  else
    check "R16f symlinked helper was accepted" FAIL
  fi
else
  check "R16f symlink fixture unavailable" PASS
fi
rm -f "$NEG_PLUGIN/hooks/lib/zensu-log.sh"; mv "$HELPER_REAL" "$NEG_PLUGIN/hooks/lib/zensu-log.sh"

MANIFEST="$NEG_PLUGIN/.codex-plugin/plugin.json" node -e '
  const fs=require("fs"),p=process.env.MANIFEST,m=JSON.parse(fs.readFileSync(p));m.padding="x".repeat(70000);fs.writeFileSync(p,JSON.stringify(m));
'
if ! env -i PATH="$PATH" HOME="$NEG_LEAF_HOME" CODEX_THREAD_ID="$NEG_LEAF_THREAD" node "$NEG_LEAF_READER" >/dev/null 2>&1; then
  check "R16g reader rejects an oversized plugin manifest" PASS
else
  check "R16g oversized plugin manifest was accepted" FAIL
fi

NEG_ROOTS="$NEG_HOME/.zensu/plugin-roots"; NEG_ROOTS_REAL="$TMP/plugin-roots-real"
mv "$NEG_ROOTS" "$NEG_ROOTS_REAL"
if ln -s "$NEG_ROOTS_REAL" "$NEG_ROOTS" 2>/dev/null; then
  if ! env -i PATH="$PATH" HOME="$NEG_HOME" CODEX_THREAD_ID="$NEG_THREAD" node "$NEG_ROOTS_REAL/codex/resolve-v1.js" >/dev/null 2>&1; then
    check "R16h reader refuses a symlinked registry ancestor" PASS
  else
    check "R16h symlinked registry ancestor was accepted" FAIL
  fi
else
  check "R16h symlink fixture unavailable" PASS
fi

if ROOT="$ROOT" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.ROOT;
const targets = ["plugins/zensu", "README.md", "AGENTS.md"];
const hits = [];
function scan(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) { for (const name of fs.readdirSync(p)) scan(path.join(p, name)); return; }
  if (!/\.(?:sh|js|json|md)$/.test(p)) return;
  if (/\.zensu\/plugin-root(?!s)/.test(fs.readFileSync(p, "utf8"))) hits.push(path.relative(root, p));
}
for (const rel of targets) { const p=path.join(root,rel); if (fs.existsSync(p)) scan(p); }
if (hits.length) { process.stderr.write(`active legacy plugin-root references: ${hits.join(", ")}\n`); process.exit(1); }
NODE
then
  check "R17 active hooks, skills, and docs contain no legacy pointer consumer" PASS
else
  check "R17 active hooks, skills, and docs contain no legacy pointer consumer" FAIL
fi

if ROOT="$ROOT" node - <<'NODE'
const fs=require("fs"), path=require("path"), root=process.env.ROOT;
const targets=["plugins/zensu/docs","plugins/zensu/skills","plugins/zensu/agents","README.md"];
const bad=[];
function scan(file) {
  const stat=fs.statSync(file);
  if (stat.isDirectory()) { for (const name of fs.readdirSync(file)) scan(path.join(file,name)); return; }
  if (!/\.(?:md|toml|json|yaml|yml)$/.test(file)) return;
  const text=fs.readFileSync(file,"utf8");
  if (/\{PLUGIN_ROOT\}|bash\s+["\x27]?\$\{?(?:CLAUDE_PLUGIN_ROOT|CODEX_PLUGIN_ROOT|ZENSU_PLUGIN_ROOT)/.test(text)) bad.push(path.relative(root,file));
  if (file.endsWith(".md")) {
    for (const match of text.matchAll(/```(?:bash|sh)\s*\n([\s\S]*?)```/g)) {
      const block=match[1];
      if (/\$(?:ROOT|PLUGIN_ROOT)\b|\$\{(?:ROOT|PLUGIN_ROOT)\b/.test(block) &&
          !/plugin-roots\/codex\/resolve-v1\.js/.test(block)) {
        bad.push(`${path.relative(root,file)}:shell-block-reuses-root`);
      }
    }
  } else if (/\$(?:ROOT|PLUGIN_ROOT)\b|\$\{(?:ROOT|PLUGIN_ROOT)\b/.test(text) &&
             !/plugin-roots\/codex\/resolve-v1\.js/.test(text)) {
    bad.push(`${path.relative(root,file)}:structured-root-without-resolver`);
  }
}
for (const rel of targets) if (fs.existsSync(path.join(root,rel))) scan(path.join(root,rel));
for (const rel of ["plugins/zensu/hooks/session-start-primer.sh","plugins/zensu/hooks/post-review-tdd-delegate.sh","plugins/zensu/hooks/stop-chain-enforcer.sh","plugins/zensu/hooks/pre-edit-tdd-reminder.sh"]) {
  const text=fs.readFileSync(path.join(root,rel),"utf8");
  if (/\{PLUGIN_ROOT\}|root\s*\+\s*["\x27]\/hooks\/|bash\s+\$\{?CLAUDE_PLUGIN_ROOT/.test(text)) bad.push(rel);
}
for (const rel of ["plugins/zensu/skills/tdd/SKILL.md","plugins/zensu/skills/self-review/SKILL.md"]) {
  if (!fs.readFileSync(path.join(root,rel),"utf8").includes("plugin-roots/codex/resolve-v1.js")) bad.push(`${rel}:missing-resolver`);
}
if (bad.length) { process.stderr.write(`stale or unquoted model root commands: ${bad.join(", ")}\n`); process.exit(1); }
NODE
then
  check "R17b model workflows use quoted exact-session roots" PASS
else
  check "R17b model workflows still use stale or unquoted roots" FAIL
fi

echo "----"
echo "test-plugin-root-registry: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
