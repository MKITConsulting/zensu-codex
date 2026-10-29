#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
HOOK="$PLUGIN/hooks/session-start-session-control.sh"
ADAPTER="$PLUGIN/hooks/lib/codex-session-control-v1.js"
READER_SOURCE="$PLUGIN/hooks/lib/codex-session-control-resolve-v3.js"
CORE="$PLUGIN/hooks/lib/session-control-core-v1.js"

IS_WINDOWS=0
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
esac

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

for artifact in "$HOOK" "$ADAPTER" "$READER_SOURCE" "$CORE"; do
  if [ -f "$artifact" ]; then check "artifact exists: ${artifact#$ROOT/}" PASS
  else check "artifact exists: ${artifact#$ROOT/}" FAIL; fi
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-session-control-codex: $PASS PASS / $FAIL FAIL"
  exit 1
fi

canonical_path() {
  node -e '
    const fs = require("node:fs");
    process.stdout.write(fs.realpathSync.native(process.argv[1]).replaceAll("\\", "/"));
  ' "$1"
}

same_canonical_path() {
  LEFT_PATH="$1" RIGHT_PATH="$2" node -e '
    const fs = require("node:fs");
    const left = fs.realpathSync.native(process.env.LEFT_PATH);
    const right = fs.realpathSync.native(process.env.RIGHT_PATH);
    process.exit(left === right ? 0 : 1);
  '
}

session_key() {
  SESSION_ID_INPUT="$1" CORE_PATH="$(canonical_path "$CORE")" node -e '
    const core = require(process.env.CORE_PATH);
    process.stdout.write(core.sessionKey(process.env.SESSION_ID_INPUT));
  '
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJECT_A="$TMP/project-a"
PROJECT_B="$TMP/project-b"
PROJECT_C="$TMP/project-c"
PROJECT_D="$TMP/project-d"
PLUGIN_COPY="$TMP/plugin-copy"
mkdir -p "$HOME_DIR" "$PROJECT_A" "$PROJECT_B" "$PROJECT_C" "$PROJECT_D"
HOME_NATIVE="$(canonical_path "$HOME_DIR")"
PLUGIN_NATIVE="$(canonical_path "$PLUGIN")"
SID_A="codex/raw session alpha"
SID_B="codex/raw session beta"
SID_C="codex/runtime conformance"
SID_D="codex/activated state deletion"
KEY_A="$(session_key "$SID_A")"
KEY_B="$(session_key "$SID_B")"
KEY_C="$(session_key "$SID_C")"
KEY_D="$(session_key "$SID_D")"
CONTROL="$HOME_DIR/.zensu/session-control/codex/v3"
READER="$CONTROL/resolve-v3.js"
RECORD_A="$CONTROL/records/$KEY_A.json"
RECORD_B="$CONTROL/records/$KEY_B.json"
RECORD_C="$CONTROL/records/$KEY_C.json"
RECORD_D="$CONTROL/records/$KEY_D.json"
OLD_CONTROL_V1="$HOME_DIR/.zensu/session-control/codex/v1"
OLD_CONTROL_V2="$HOME_DIR/.zensu/session-control/codex/v2"

# A prior reader ABI is persistent user state, not a migration source. New
# sessions must neither execute nor rewrite it.
mkdir -p "$OLD_CONTROL_V1/records" "$OLD_CONTROL_V2/records"
chmod 700 "$HOME_DIR/.zensu" "$HOME_DIR/.zensu/session-control" \
  "$HOME_DIR/.zensu/session-control/codex" \
  "$OLD_CONTROL_V1" "$OLD_CONTROL_V1/records" "$OLD_CONTROL_V2" "$OLD_CONTROL_V2/records"
printf '%s\n' '# inert reader ABI v1 marker' > "$OLD_CONTROL_V1/resolve-v1.js"
printf '%s\n' '# inert reader ABI v2 marker' > "$OLD_CONTROL_V2/resolve-v2.js"
printf '%s\n' '{"inert":true}' > "$OLD_CONTROL_V1/records/legacy.json"
printf '%s\n' '{"inert":true}' > "$OLD_CONTROL_V2/records/legacy.json"
chmod 600 "$OLD_CONTROL_V1/resolve-v1.js" "$OLD_CONTROL_V1/records/legacy.json" \
  "$OLD_CONTROL_V2/resolve-v2.js" "$OLD_CONTROL_V2/records/legacy.json"

payload() {
  local native_cwd
  native_cwd="$(canonical_path "$3")"
  PAYLOAD_EVENT="$1" PAYLOAD_SESSION="$2" PAYLOAD_CWD="$native_cwd" \
    PAYLOAD_AGENT_ID="${4:-}" PAYLOAD_AGENT_TYPE="${5:-}" node -e '
      process.stdout.write(JSON.stringify({
        hook_event_name: process.env.PAYLOAD_EVENT,
        session_id: process.env.PAYLOAD_SESSION,
        cwd: process.env.PAYLOAD_CWD,
        agent_id: process.env.PAYLOAD_AGENT_ID || undefined,
        agent_type: process.env.PAYLOAD_AGENT_TYPE || undefined
      }));
    '
}

run_hook() {
  HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK"
}

run_ambient_marker_hook() {
  HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    ZENSU_AGENT_PROFILE='reviewer-readonly-v1' \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK"
}

run_copy_hook() {
  HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_COPY_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_COPY_NATIVE" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$PLUGIN_COPY/hooks/session-start-session-control.sh"
}

if : | run_hook >"$TMP/empty-payload.out" 2>"$TMP/empty-payload.err"; then
  check "adapter rejects empty stdin without publishing control state" FAIL
elif grep -qF 'hook payload is empty or too large' "$TMP/empty-payload.err" \
  && [ ! -e "$CONTROL" ]; then
  check "adapter rejects empty stdin without publishing control state" PASS
else
  check "adapter rejects empty stdin without publishing control state" FAIL
fi

if printf '%s' '{not-json' | run_hook >"$TMP/invalid-json.out" 2>"$TMP/invalid-json.err"; then
  check "adapter rejects invalid JSON without publishing control state" FAIL
elif grep -qF 'hook payload is invalid JSON' "$TMP/invalid-json.err" \
  && [ ! -e "$CONTROL" ]; then
  check "adapter rejects invalid JSON without publishing control state" PASS
else
  check "adapter rejects invalid JSON without publishing control state" FAIL
fi

if printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$PROJECT_A" \
  | run_hook >"$TMP/missing-session.out" 2>"$TMP/missing-session.err"; then
  check "adapter rejects a missing session id without publishing control state" FAIL
elif grep -qF 'session id is unavailable' "$TMP/missing-session.err" \
  && [ ! -e "$CONTROL" ]; then
  check "adapter rejects a missing session id without publishing control state" PASS
else
  check "adapter rejects a missing session id without publishing control state" FAIL
fi

if node -e 'process.stdout.write("x".repeat(1024 * 1024 + 1))' \
  | run_hook >"$TMP/oversized-payload.out" 2>"$TMP/oversized-payload.err"; then
  check "adapter rejects an oversized payload without publishing control state" FAIL
elif grep -qF 'hook payload is empty or too large' "$TMP/oversized-payload.err" \
  && [ ! -e "$CONTROL" ]; then
  check "adapter rejects an oversized payload without publishing control state" PASS
else
  check "adapter rejects an oversized payload without publishing control state" FAIL
fi

OUT_A="$(payload SessionStart "$SID_A" "$PROJECT_A" | run_hook 2>"$TMP/start-a.err")"
RC_A=$?
if [ "$RC_A" -eq 0 ] && printf '%s' "$OUT_A" | grep -qF '[zensu-session-context]' \
  && printf '%s' "$OUT_A" | grep -qF "ZENSU_SESSION_KEY=$KEY_A"; then
  check "SessionStart injects trusted main context and the hashed session key" PASS
else
  check "SessionStart injects trusted main context and the hashed session key" FAIL
fi

if printf '%s' "$OUT_A" | grep -qF 'CODEX_THREAD_ID is never a Session Control selector' \
  && ! printf '%s' "$OUT_A" | grep -qF 'host-provided optimization'; then
  check "main context identifies CODEX_THREAD_ID as never being a selector" PASS
else
  check "main context identifies CODEX_THREAD_ID as never being a selector" FAIL
fi

if [ -f "$RECORD_A" ] && [ -f "$READER" ]; then
  check "SessionStart publishes per-session record and stable reader" PASS
else
  check "SessionStart publishes per-session record and stable reader" FAIL
fi

STATE_A="$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json"
if STATE_FILE="$STATE_A" node -e '
  const state = require(process.env.STATE_FILE);
  process.exit(
    state.revision === 1
    && state.active === false
    && state.vanilla === false
    && state.implComplete === false
    && state.chainDone === false
    && state.codeReviewDone === false
    && state.selfReviewFixed === false
    && state.workflowActive === false
    && Array.isArray(state.workflowTools) && state.workflowTools.length === 0
    && Array.isArray(state.bypasses) && state.bypasses.length === 0
    && state.reviewRound === 0 && state.stopBlocks === 0
    && state.phase === "UNINITIALIZED" && state.step_id === ""
    && Array.isArray(state.history) && state.history.length === 0
      ? 0 : 1
  );
'; then
  check "SessionStart creates the complete inactive revision-one workflow baseline" PASS
else
  check "SessionStart creates the complete inactive revision-one workflow baseline" FAIL
fi

if node -e '
  const record = require(process.argv[1]);
  process.exit(record.source_revision === record.runtime_digest && record.source_revision !== "unknown" ? 0 : 1);
' "$RECORD_A"; then
  check "normal SessionStart binds source revision to the exact runtime digest" PASS
else
  check "normal SessionStart binds source revision to the exact runtime digest" FAIL
fi

AMBIENT_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
OLD_SOURCE_AUTHORITY='verified-runtime-provenance-v1'
if payload SessionStart 'codex/source retired authority pair' "$PROJECT_A" \
  | HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    ZENSU_SOURCE_REVISION="$AMBIENT_SHA" ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" \
    bash "$HOOK" >"$TMP/source-retired-pair.out" 2>"$TMP/source-retired-pair.err"; then
  check "retired SHA plus authority pair cannot relabel session provenance" FAIL
else
  check "retired SHA plus authority pair cannot relabel session provenance" PASS
fi

if payload SessionStart 'codex/source revision only' "$PROJECT_A" \
  | HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    ZENSU_SOURCE_REVISION="$AMBIENT_SHA" env -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/source-revision-only.out" 2>"$TMP/source-revision-only.err"; then
  check "ambient source revision without authority fails closed" FAIL
else
  check "ambient source revision without authority fails closed" PASS
fi

if payload SessionStart 'codex/source bad format' "$PROJECT_A" \
  | HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    ZENSU_SOURCE_REVISION='not-a-revision' ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" \
    bash "$HOOK" >"$TMP/source-bad.out" 2>"$TMP/source-bad.err"; then
  check "malformed source revision fails closed" FAIL
else
  check "malformed source revision fails closed" PASS
fi

if payload SessionStart 'codex/source authority only' "$PROJECT_A" \
  | HOME="$HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
    ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" env -u ZENSU_SOURCE_REVISION \
    bash "$HOOK" >"$TMP/source-authority-only.out" 2>"$TMP/source-authority-only.err"; then
  check "source authority without a revision fails closed" FAIL
else
  check "source authority without a revision fails closed" PASS
fi

if grep -qF '# inert reader ABI v1 marker' "$OLD_CONTROL_V1/resolve-v1.js" \
  && grep -qF '# inert reader ABI v2 marker' "$OLD_CONTROL_V2/resolve-v2.js" \
  && grep -qF '"inert":true' "$OLD_CONTROL_V1/records/legacy.json" \
  && grep -qF '"inert":true' "$OLD_CONTROL_V2/records/legacy.json" \
  && [ ! -e "$OLD_CONTROL_V1/records/$KEY_A.json" ] \
  && [ ! -e "$OLD_CONTROL_V2/records/$KEY_A.json" ]; then
  check "reader ABI v1/v2 artifacts remain inert and are never migrated" PASS
else
  check "reader ABI v1/v2 artifacts remain inert and are never migrated" FAIL
fi

if [ -f "$RECORD_A" ] && ! grep -R -F -q "$SID_A" "$CONTROL"; then
  check "control directory never persists the raw session id" PASS
else
  check "control directory never persists the raw session id" FAIL
fi

if [ -f "$RECORD_A" ] && [ ! -L "$RECORD_A" ] && [ -f "$READER" ] && [ ! -L "$READER" ]; then
  check "record and reader are regular, non-symlink files" PASS
else
  check "record and reader are regular, non-symlink files" FAIL
fi

if [ "$IS_WINDOWS" -eq 1 ]; then
  check "POSIX 0600 mode assertion is skipped on Windows ACL filesystems" PASS
elif RECORD_PATH="$RECORD_A" READER_PATH="$READER" node -e '
  const fs = require("node:fs");
  for (const file of [process.env.RECORD_PATH, process.env.READER_PATH]) {
    if ((fs.lstatSync(file).mode & 0o777) !== 0o600) process.exit(1);
  }
'; then
  check "record and reader use private POSIX modes" PASS
else
  check "record and reader use private POSIX modes" FAIL
fi

RESOLVED="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --root 2>"$TMP/resolve.err")"
if same_canonical_path "$RESOLVED" "$PLUGIN_NATIVE"; then
  check "stable reader resolves from the injected key without CODEX_THREAD_ID" PASS
else
  check "stable reader resolves from the injected key without CODEX_THREAD_ID" FAIL
fi

cp "$RECORD_A" "$TMP/record-a.source-backup"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.source_revision = "arbitrary-ambient-value";
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
' "$RECORD_A"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' \
  node "$READER" --root >"$TMP/arbitrary-source.out" 2>"$TMP/arbitrary-source.err"; then
  check "stable reader rejects arbitrary persisted source provenance" FAIL
else
  check "stable reader rejects arbitrary persisted source provenance" PASS
fi
cp "$TMP/record-a.source-backup" "$RECORD_A"

node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.source_revision = process.argv[2];
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
' "$RECORD_A" "$AMBIENT_SHA"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' \
  node "$READER" --root >"$TMP/git-source.out" 2>"$TMP/git-source.err"; then
  check "stable reader rejects a persisted Git SHA in the content revision field" FAIL
else
  check "stable reader rejects a persisted Git SHA in the content revision field" PASS
fi
cp "$TMP/record-a.source-backup" "$RECORD_A"

node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.source_revision = `sha256:${"0".repeat(64)}`;
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
' "$RECORD_A"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' \
  node "$READER" --root >"$TMP/mismatched-content-source.out" 2>"$TMP/mismatched-content-source.err"; then
  check "stable reader rejects a content revision different from runtime" FAIL
else
  check "stable reader rejects a content revision different from runtime" PASS
fi
cp "$TMP/record-a.source-backup" "$RECORD_A"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --root >/dev/null 2>&1; then
  check "stable reader recovers after provenance tamper fixture restoration" PASS
else
  check "stable reader recovers after provenance tamper fixture restoration" FAIL
fi

CONTEXT="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID="$SID_B" node "$READER" --context 2>/dev/null)"
if printf '%s' "$CONTEXT" | grep -qF 'principal=main-v1' && ! printf '%s' "$CONTEXT" | grep -qF "$SID_A"; then
  check "injected key is primary over a contradictory CODEX_THREAD_ID" PASS
else
  check "injected key is primary over a contradictory CODEX_THREAD_ID" FAIL
fi

if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY='' CODEX_THREAD_ID="$SID_A" node "$READER" --root >/dev/null 2>&1; then
  check "CODEX_THREAD_ID alone cannot select a main-capable reader context" FAIL
else
  check "CODEX_THREAD_ID alone cannot select a main-capable reader context" PASS
fi

REVIEW_CONTEXT="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --review-context 2>/dev/null)"
if printf '%s' "$REVIEW_CONTEXT" | grep -qF 'reviewer-readonly-v1' && printf '%s' "$REVIEW_CONTEXT" | grep -qF 'must not write'; then
  check "stable reader renders the reviewer capability contract" PASS
else
  check "stable reader renders the reviewer capability contract" FAIL
fi

if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY='' CODEX_THREAD_ID='' node "$READER" --root >"$TMP/no-id.out" 2>"$TMP/no-id.err"; then
  check "stable reader fails closed without an injected key or host identity" FAIL
else
  check "stable reader fails closed without an injected key or host identity" PASS
fi
if grep -qF 'session-control reader-abi-v3:' "$TMP/no-id.err"; then
  check "immutable reader reports its v3 ABI in diagnostics" PASS
else
  check "immutable reader reports its v3 ABI in diagnostics" FAIL
fi

if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY='invalid' CODEX_THREAD_ID="$SID_A" node "$READER" --root >"$TMP/invalid-key.out" 2>"$TMP/invalid-key.err"; then
  check "invalid injected key cannot fall through to CODEX_THREAD_ID" FAIL
else
  check "invalid injected key cannot fall through to CODEX_THREAD_ID" PASS
fi

MISSING_KEY="$(session_key unregistered)"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$MISSING_KEY" CODEX_THREAD_ID='' node "$READER" --root >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  check "stable reader fails closed for an unregistered session" FAIL
else
  check "stable reader fails closed for an unregistered session" PASS
fi

mkdir -p "$HOME_DIR/.zensu/plugin-roots/codex"
printf '{"pluginRoot":"%s"}\n' "$PROJECT_B" > "$HOME_DIR/.zensu/plugin-roots/codex/fake.json"
LEGACY_KEY="$(session_key legacy-only)"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$LEGACY_KEY" CODEX_THREAD_ID='' node "$READER" --root >"$TMP/legacy.out" 2>/dev/null; then
  check "legacy plugin-root registry is inert" FAIL
else
  check "legacy plugin-root registry is inert" PASS
fi

OUT_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-1 zensu-code-reviewer | run_hook 2>"$TMP/review.err")"
if printf '%s' "$OUT_REVIEW" | grep -qF '[zensu-reviewer-context]' && printf '%s' "$OUT_REVIEW" | grep -qF 'reviewer-readonly-v1'; then
  check "SubagentStart injects reviewer context from the parent record" PASS
else
  check "SubagentStart injects reviewer context from the parent record" FAIL
fi

mkdir -p "$PLUGIN_COPY"
cp -R "$PLUGIN/.codex-plugin" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/docs" "$PLUGIN_COPY/"
PLUGIN_COPY_NATIVE="$(canonical_path "$PLUGIN_COPY")"
if payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-cross-root zensu-code-reviewer \
  | run_copy_hook >"$TMP/cross-root.out" 2>"$TMP/cross-root.err"; then
  check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" FAIL
else
  grep -qF 'plugin root does not match the parent session' "$TMP/cross-root.err" \
    && check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" PASS \
    || check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" FAIL
fi

# Build a disposable plugin whose runtime surface exercises every independent
# Core/resolver discovery rule without mutating the checkout under test.
mkdir -p "$PLUGIN_COPY/templates" "$PLUGIN_COPY/runtime-extra"
printf '%s\n' '# resolver template' > "$PLUGIN_COPY/templates/resolver-conformance.md"
printf '%s\n' '# manifest-only runtime reference' > "$PLUGIN_COPY/runtime-extra/referenced.md"
printf '%s\n' '# resolver README' > "$PLUGIN_COPY/README.md"
printf '%s\n' '# resolver CHANGELOG' > "$PLUGIN_COPY/CHANGELOG.md"
printf '%s\n' 'resolver test license' > "$PLUGIN_COPY/LICENSE"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  manifest.agents = "./runtime-extra";
  fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
' "$PLUGIN_COPY/.codex-plugin/plugin.json"

CONFORMANCE_READY=0
if payload SessionStart "$SID_C" "$PROJECT_C" | run_copy_hook >"$TMP/start-c.out" 2>"$TMP/start-c.err"; then
  CORE_DIGEST="$(node -e 'const fs=require("node:fs");process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).runtime_digest)' "$RECORD_C")"
  RESOLVER_DIGEST="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' node "$READER" --field runtime_digest 2>"$TMP/conformance.err")"
  RESOLVER_ROOT="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' node "$READER" --root 2>>"$TMP/conformance.err")"
  if [ "$CORE_DIGEST" = "$RESOLVER_DIGEST" ] \
    && same_canonical_path "$RESOLVER_ROOT" "$PLUGIN_COPY_NATIVE"; then
    CONFORMANCE_READY=1
    check "Core and stable resolver agree on the complete runtime digest" PASS
  else
    check "Core and stable resolver agree on the complete runtime digest" FAIL
  fi
else
  check "Core and stable resolver agree on the complete runtime digest" FAIL
fi

assert_runtime_drift_rejected() {
  local label="$1"
  local file="$2"
  local backup="$TMP/runtime-backup-$3"
  if [ "$CONFORMANCE_READY" -ne 1 ]; then
    check "$label" FAIL
    return
  fi
  cp "$file" "$backup"
  printf '%s\n' 'resolver drift' >> "$file"
  local rejected=0
  if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' \
    node "$READER" --root >"$TMP/drift-$3.out" 2>"$TMP/drift-$3.err"; then
    rejected=0
  else
    rejected=1
  fi
  cp "$backup" "$file"
  if [ "$rejected" -eq 1 ] && HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' \
    node "$READER" --root >"$TMP/restored-$3.out" 2>"$TMP/restored-$3.err"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
}

assert_runtime_drift_rejected "stable resolver rejects docs runtime drift" \
  "$PLUGIN_COPY/docs/tdd-manager-workflow.md" docs
assert_runtime_drift_rejected "stable resolver rejects templates runtime drift" \
  "$PLUGIN_COPY/templates/resolver-conformance.md" templates
assert_runtime_drift_rejected "stable resolver rejects README runtime drift" \
  "$PLUGIN_COPY/README.md" readme
assert_runtime_drift_rejected "stable resolver rejects CHANGELOG runtime drift" \
  "$PLUGIN_COPY/CHANGELOG.md" changelog
assert_runtime_drift_rejected "stable resolver rejects LICENSE runtime drift" \
  "$PLUGIN_COPY/LICENSE" license
assert_runtime_drift_rejected "stable resolver rejects manifest-referenced runtime drift" \
  "$PLUGIN_COPY/runtime-extra/referenced.md" manifest-reference

if [ "$IS_WINDOWS" -eq 1 ]; then
  check "runtime symlink assertion is skipped where Git Bash cannot guarantee symlink creation" PASS
else
  TEMPLATE_BACKUP="$TMP/template-symlink-target"
  cp "$PLUGIN_COPY/templates/resolver-conformance.md" "$TEMPLATE_BACKUP"
  rm "$PLUGIN_COPY/templates/resolver-conformance.md"
  ln -s "$TEMPLATE_BACKUP" "$PLUGIN_COPY/templates/resolver-conformance.md"
  SYMLINK_REJECTED=0
  if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' \
    node "$READER" --root >"$TMP/runtime-symlink.out" 2>"$TMP/runtime-symlink.err"; then
    SYMLINK_REJECTED=0
  else
    SYMLINK_REJECTED=1
  fi
  rm "$PLUGIN_COPY/templates/resolver-conformance.md"
  cp "$TEMPLATE_BACKUP" "$PLUGIN_COPY/templates/resolver-conformance.md"
  if [ "$CONFORMANCE_READY" -eq 1 ] && [ "$SYMLINK_REJECTED" -eq 1 ] && \
    HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_C" CODEX_THREAD_ID='' \
    node "$READER" --root >"$TMP/symlink-restored.out" 2>"$TMP/symlink-restored.err"; then
    check "stable resolver rejects a raced runtime symlink" PASS
  else
    check "stable resolver rejects a raced runtime symlink" FAIL
  fi
fi

OUT_NAMESPACED_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-namespace zensu:review-aspect | run_hook 2>"$TMP/review-namespace.err")"
OUT_CUSTOM_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-custom zensu-review-domain | run_hook 2>"$TMP/review-custom.err")"
if printf '%s' "$OUT_NAMESPACED_REVIEW$OUT_CUSTOM_REVIEW" | grep -qF 'principal=host-profile-v1' && \
   ! printf '%s' "$OUT_NAMESPACED_REVIEW$OUT_CUSTOM_REVIEW" | grep -qF 'principal=main-v1' && \
   ! printf '%s' "$OUT_NAMESPACED_REVIEW$OUT_CUSTOM_REVIEW" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "namespaced and custom review-like types remain neutral" PASS
else
  check "namespaced and custom review-like types remain neutral" FAIL
fi

OUT_PATH_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-path /root/zensu_code_reviewer | run_hook 2>"$TMP/review-path.err")"
OUT_UNDERSCORE_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-underscore zensu_review_aspect | run_hook 2>"$TMP/review-underscore.err")"
if printf '%s' "$OUT_PATH_REVIEW$OUT_UNDERSCORE_REVIEW" | grep -qF 'principal=host-profile-v1' && \
   ! printf '%s' "$OUT_PATH_REVIEW$OUT_UNDERSCORE_REVIEW" | grep -qF 'principal=main-v1' && \
   ! printf '%s' "$OUT_PATH_REVIEW$OUT_UNDERSCORE_REVIEW" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "path and underscore reviewer near-misses remain neutral" PASS
else
  check "path and underscore reviewer near-misses remain neutral" FAIL
fi

OUT_JUDGE_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-judge zensu-review-judge | run_hook 2>"$TMP/review-judge.err")"
if printf '%s' "$OUT_JUDGE_REVIEW" | grep -qF 'principal=reviewer-readonly-v1' && \
   ! printf '%s' "$OUT_JUDGE_REVIEW" | grep -qF 'principal=main-v1'; then
  check "exact judge agent type receives reviewer context" PASS
else
  check "exact judge agent type receives reviewer context" FAIL
fi

OUT_DEFAULT_MARKED="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-default default | run_ambient_marker_hook 2>"$TMP/review-default-marker.err")"
if printf '%s' "$OUT_DEFAULT_MARKED" | grep -qF 'principal=host-profile-v1' && \
   ! printf '%s' "$OUT_DEFAULT_MARKED" | grep -qF 'principal=main-v1' && \
   ! printf '%s' "$OUT_DEFAULT_MARKED" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "ambient reviewer marker cannot classify Codex agent_type=default" PASS
else
  check "ambient reviewer marker cannot classify Codex agent_type=default" FAIL
fi

OUT_DEFAULT_NEUTRAL="$(payload SubagentStart "$SID_A" "$PROJECT_A" neutral-default default | run_hook 2>"$TMP/default-neutral.err")"
if printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF '[zensu-host-context]' && \
   printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'principal=host-profile-v1' && \
   printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'runtime_digest=' && \
   ! printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'ZENSU_SESSION_KEY=' && \
   ! printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'session_id_hash=' && \
   ! printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'plugin_root=' && \
   ! printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'principal=main-v1' && \
   ! printf '%s' "$OUT_DEFAULT_NEUTRAL" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "Codex agent_type=default without the reviewer profile remains neutral" PASS
else
  check "Codex agent_type=default without the reviewer profile remains neutral" FAIL
fi

OUT_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-1 zensu-plm | run_hook 2>"$TMP/plm.err")"
if printf '%s' "$OUT_PLM" | grep -qF '[zensu-host-context]' && \
   printf '%s' "$OUT_PLM" | grep -qF 'principal=host-profile-v1' && \
   ! printf '%s' "$OUT_PLM" | grep -qF 'ZENSU_SESSION_KEY='; then
  check "plugin-defined PLM subagent cannot acquire main authority from its name" PASS
else
  check "plugin-defined PLM subagent cannot acquire main authority from its name" FAIL
fi

OUT_BUILTINS="$(payload SubagentStart "$SID_A" "$PROJECT_A" worker-1 worker | run_hook 2>"$TMP/worker.err")$(payload SubagentStart "$SID_A" "$PROJECT_A" explorer-1 explorer | run_hook 2>"$TMP/explorer.err")"
if printf '%s' "$OUT_BUILTINS" | grep -qF 'principal=host-profile-v1' \
  && ! printf '%s' "$OUT_BUILTINS" | grep -qF 'principal=main-v1' \
  && ! printf '%s' "$OUT_BUILTINS" | grep -qF 'ZENSU_SESSION_KEY='; then
  check "every built-in Codex subagent remains neutral regardless of its name" PASS
else
  check "every built-in Codex subagent remains neutral regardless of its name" FAIL
fi

OUT_UNKNOWN="$(payload SubagentStart "$SID_A" "$PROJECT_A" unknown-1 future-custom-profile | run_hook 2>"$TMP/unknown.err")"
if printf '%s' "$OUT_UNKNOWN" | grep -qF 'principal=host-profile-v1' && \
   ! printf '%s' "$OUT_UNKNOWN" | grep -qF 'principal=main-v1' && \
   ! printf '%s' "$OUT_UNKNOWN" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "unknown future agent types fail closed to neutral context" PASS
else
  check "unknown future agent types fail closed to neutral context" FAIL
fi

OUT_PATH_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-path /root/zensu_plm | run_hook 2>"$TMP/plm-path.err")"
if printf '%s' "$OUT_PATH_PLM" | grep -qF 'principal=host-profile-v1' && ! printf '%s' "$OUT_PATH_PLM" | grep -qF 'principal=main-v1'; then
  check "plugin-agent runtime paths remain neutral" PASS
else
  check "plugin-agent runtime paths remain neutral" FAIL
fi

OUT_MARKED_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-marked /root/zensu_plm | run_ambient_marker_hook 2>"$TMP/plm-marked.err")"
if printf '%s' "$OUT_MARKED_PLM" | grep -qF 'principal=host-profile-v1' && ! printf '%s' "$OUT_MARKED_PLM" | grep -qF 'principal=main-v1'; then
  check "ambient reviewer marker cannot promote a neutral PLM profile" PASS
else
  check "ambient reviewer marker cannot promote a neutral PLM profile" FAIL
fi

if payload SubagentStart 'not-registered' "$PROJECT_A" reviewer-2 zensu-review-aspect | run_hook >"$TMP/sub-missing.out" 2>"$TMP/sub-missing.err"; then
  check "SubagentStart cannot self-register an unknown parent session" FAIL
else
  check "SubagentStart cannot self-register an unknown parent session" PASS
fi

if payload SessionStart "$SID_A" "$PROJECT_B" | run_hook >"$TMP/rebind.out" 2>"$TMP/rebind.err"; then
  check "an active session cannot be rebound to another project" FAIL
else
  check "an active session cannot be rebound to another project" PASS
fi

payload SessionStart "$SID_B" "$PROJECT_B" | run_hook >"$TMP/start-b.out" 2>"$TMP/start-b.err"
if [ -f "$RECORD_A" ] && [ -f "$RECORD_B" ]; then
  check "distinct concurrent sessions retain independent records" PASS
else
  check "distinct concurrent sessions retain independent records" FAIL
fi

ROOT_FIELD="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --field plugin_root 2>/dev/null)"
HASH_FIELD="$(HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --field session_id_hash 2>/dev/null)"
if [ "$ROOT_FIELD" = "$RESOLVED" ] && printf '%s' "$HASH_FIELD" | grep -Eq '^sha256:[a-f0-9]{64}$'; then
  check "stable reader exposes only allowlisted scalar fields" PASS
else
  check "stable reader exposes only allowlisted scalar fields" FAIL
fi

if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_A" CODEX_THREAD_ID='' node "$READER" --field principal_profiles >"$TMP/object-field.out" 2>/dev/null; then
  check "stable reader rejects object and unknown fields" FAIL
else
  check "stable reader rejects object and unknown fields" PASS
fi

MISMATCH="$TMP/not-plugin"
mkdir -p "$MISMATCH"
MISMATCH_NATIVE="$(canonical_path "$MISMATCH")"
if payload SessionStart 'mismatch' "$PROJECT_A" | HOME="$HOME_NATIVE" PLUGIN_ROOT="$MISMATCH_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" bash "$HOOK" >"$TMP/mismatch.out" 2>"$TMP/mismatch.err"; then
  check "ambient plugin-root mismatch fails closed" FAIL
else
  check "ambient plugin-root mismatch fails closed" PASS
fi

if find "$CONTROL" -type l -print -quit | grep -q .; then
  check "control plane contains no symlink artifacts" FAIL
else
  check "control plane contains no symlink artifacts" PASS
fi

# A completely fresh control home must support true concurrent SessionStart
# publication. This exercises every mkdir plus the immutable reader's
# no-clobber winner path, not merely concurrent record creation after warm-up.
COLD_HOME="$TMP/cold-home"
COLD_PROJECT="$TMP/cold-project"
mkdir -p "$COLD_HOME" "$COLD_PROJECT"
COLD_HOME_NATIVE="$(canonical_path "$COLD_HOME")"
COLD_PROJECT_NATIVE="$(canonical_path "$COLD_PROJECT")"
COLD_CONTROL="$COLD_HOME/.zensu/session-control/codex/v3"
COLD_FAIL=0
COLD_PIDS=""
i=1
while [ "$i" -le 15 ]; do
  (
    PAYLOAD_SESSION="cold-start-$i" PAYLOAD_CWD="$COLD_PROJECT_NATIVE" node -e '
      process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD}));
    ' | HOME="$COLD_HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK" \
      >"$TMP/cold-$i.out" 2>"$TMP/cold-$i.err"
  ) &
  COLD_PIDS="$COLD_PIDS $!"
  i=$((i + 1))
done
for pid in $COLD_PIDS; do wait "$pid" || COLD_FAIL=$((COLD_FAIL + 1)); done
COLD_RECORDS="$(find "$COLD_CONTROL/records" -maxdepth 1 -type f -name 'scv1_*.json' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "$COLD_FAIL" -eq 0 ] && [ "$COLD_RECORDS" = 15 ] \
  && cmp -s "$COLD_CONTROL/resolve-v3.js" "$READER_SOURCE"; then
  check "15 simultaneous cold SessionStarts publish one complete reader and all records" PASS
else
  check "15 simultaneous cold SessionStarts publish one complete reader and all records" FAIL
fi

# Recover the only crash window of hard-link no-clobber publication: the final
# reader link exists, but the private candidate link was not yet removed.
RECOVERY_HOME="$TMP/recovery-home"
RECOVERY_PROJECT="$TMP/recovery-project"
RECOVERY_CONTROL="$RECOVERY_HOME/.zensu/session-control/codex/v3"
mkdir -p "$RECOVERY_CONTROL/records" "$RECOVERY_CONTROL/locks" "$RECOVERY_PROJECT"
chmod 700 "$RECOVERY_HOME" "$RECOVERY_HOME/.zensu" "$RECOVERY_HOME/.zensu/session-control" \
  "$RECOVERY_HOME/.zensu/session-control/codex" "$RECOVERY_CONTROL" "$RECOVERY_CONTROL/records" "$RECOVERY_CONTROL/locks"
RECOVERY_CANDIDATE="$RECOVERY_CONTROL/.resolve-v3.js.123.0123456789abcdef.candidate"
cp "$READER_SOURCE" "$RECOVERY_CANDIDATE"
ln "$RECOVERY_CANDIDATE" "$RECOVERY_CONTROL/resolve-v3.js"
if PAYLOAD_SESSION='reader-publication-recovery' PAYLOAD_CWD="$(canonical_path "$RECOVERY_PROJECT")" node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD}));
' | HOME="$(canonical_path "$RECOVERY_HOME")" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK" \
  >"$TMP/recovery.out" 2>"$TMP/recovery.err" \
  && [ ! -e "$RECOVERY_CANDIDATE" ] \
  && [ "$(node -e 'process.stdout.write(String(require("fs").lstatSync(process.argv[1]).nlink))' "$RECOVERY_CONTROL/resolve-v3.js")" = 1 ] \
  && cmp -s "$RECOVERY_CONTROL/resolve-v3.js" "$READER_SOURCE"; then
  check "reader publication recovers an interrupted linked candidate" PASS
else
  check "reader publication recovers an interrupted linked candidate" FAIL
fi

if cmp -s "$READER" "$READER_SOURCE"; then
  check "published stable reader is byte-identical to its versioned source" PASS
else
  check "published stable reader is byte-identical to its versioned source" FAIL
fi

# SessionStart always creates a mandatory baseline CAS document. Deleting that
# document must close both the edit and Stop gates; there is no activation
# marker or mutable location override to fall back to.
payload SessionStart "$SID_D" "$PROJECT_D" | run_hook >"$TMP/start-d.out" 2>"$TMP/start-d.err"
STATE_D="$PROJECT_D/.zensu/state/tdd-phase-$KEY_D.json"
if HOME="$HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_D" CLAUDE_PROJECT_DIR="$PROJECT_D" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" \
  bash "$PLUGIN/hooks/lib/zensu-log.sh" --tdd-begin >/dev/null 2>"$TMP/activate-d.err" \
  && [ -f "$STATE_D" ]; then
  rm -f "$STATE_D"
  EDIT_AFTER_DELETE="$(printf '%s' '{"tool_name":"apply_patch","session_id":"'"$SID_D"'","tool_input":{"input":"*** Begin Patch\n*** Update File: src/app.js\n@@\n+x\n*** End Patch"}}' \
    | HOME="$HOME_NATIVE" CLAUDE_PROJECT_DIR="$PROJECT_D" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" ZENSU_PLUGIN_ROOT="$PLUGIN_NATIVE" \
      bash "$PLUGIN/hooks/pre-edit-tdd-reminder.sh" 2>/dev/null)"
  STOP_AFTER_DELETE="$(printf '{"session_id":"%s"}' "$SID_D" \
    | HOME="$HOME_NATIVE" CLAUDE_PROJECT_DIR="$PROJECT_D" \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" ZENSU_PLUGIN_ROOT="$PLUGIN_NATIVE" \
      bash "$PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
  if printf '%s' "$EDIT_AFTER_DELETE" | grep -qF '"permissionDecision":"deny"' \
    && printf '%s' "$STOP_AFTER_DELETE" | grep -qF '"decision":"block"'; then
    check "deleted mandatory baseline state fails closed without a marker fallback" PASS
  else
    check "deleted mandatory baseline state fails closed without a marker fallback" FAIL
  fi
  if printf '%s' "$EDIT_AFTER_DELETE" | grep -qF 'cause: the session-state file is missing' \
    && printf '%s' "$STOP_AFTER_DELETE" | grep -qF 'cause: the session-state file is missing' \
    && ! printf '%s%s' "$EDIT_AFTER_DELETE" "$STOP_AFTER_DELETE" | grep -qF '/hooks'; then
    check "deleted baseline denials name the missing state file and carry no re-trust hint" PASS
  else
    check "deleted baseline denials name the missing state file and carry no re-trust hint" FAIL
  fi
else
  check "deleted mandatory baseline state fails closed without a marker fallback" FAIL
fi

UPD_HOME="$TMP/update-home"
UPD_PROJECT="$TMP/update-project"
UPD_PROJECT_OTHER="$TMP/update-project-other"
UPD_PLUGIN_A="$TMP/update-plugin-a"
UPD_PLUGIN_B="$TMP/update-plugin-b"
mkdir -p "$UPD_HOME" "$UPD_PROJECT" "$UPD_PROJECT_OTHER" "$UPD_PLUGIN_A"
cp -R "$PLUGIN/.codex-plugin" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/docs" "$UPD_PLUGIN_A/"
UPD_HOME_NATIVE="$(canonical_path "$UPD_HOME")"
UPD_PLUGIN_A_NATIVE="$(canonical_path "$UPD_PLUGIN_A")"
SID_U="codex/update resume"
KEY_U="$(session_key "$SID_U")"
UPD_CONTROL="$UPD_HOME/.zensu/session-control/codex/v3"
RECORD_U="$UPD_CONTROL/records/$KEY_U.json"

run_update_hook() {
  HOME="$UPD_HOME_NATIVE" PLUGIN_ROOT="$1" CLAUDE_PLUGIN_ROOT="$1" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$2/hooks/session-start-session-control.sh"
}

record_field() {
  node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]]));' "$1" "$2"
}

payload SessionStart "$SID_U" "$UPD_PROJECT" | run_update_hook "$UPD_PLUGIN_A_NATIVE" "$UPD_PLUGIN_A" \
  >"$TMP/update-start-1.out" 2>"$TMP/update-start-1.err"
UPD_START_1=$?
UPD_DIGEST_1=''
UPD_CREATED_1=''
if [ "$UPD_START_1" -eq 0 ] && [ -f "$RECORD_U" ]; then
  UPD_DIGEST_1="$(record_field "$RECORD_U" runtime_digest)"
  UPD_CREATED_1="$(record_field "$RECORD_U" created_at)"
  check "update-resume baseline SessionStart publishes the record" PASS
else
  check "update-resume baseline SessionStart publishes the record" FAIL
fi

run_update_gate() {
  PAYLOAD_SESSION="$SID_U" PAYLOAD_CWD="$(canonical_path "$UPD_PROJECT")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,tool_name:"Read",tool_input:{file_path:"README.md"}}));
  ' | HOME="$UPD_HOME_NATIVE" bash "$1/hooks/pre-reviewer-capability-gate.sh" 2>/dev/null
}

UPD_TOUCH="$(find "$UPD_PLUGIN_A/docs" -type f | sort | head -1)"
printf '\n' >> "$UPD_TOUCH"
UPD_GATE_STALE="$(run_update_gate "$UPD_PLUGIN_A")"
if printf '%s' "$UPD_GATE_STALE" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$UPD_GATE_STALE" | grep -qF 'context runtime digest mismatch' \
  && printf '%s' "$UPD_GATE_STALE" | grep -qF 'open /hooks and trust every Zensu hook'; then
  check "capability gate denies a stale record with its cause and the re-trust hint" PASS
else
  check "capability gate denies a stale record with its cause and the re-trust hint" FAIL
fi
if payload SessionStart "$SID_U" "$UPD_PROJECT" | run_update_hook "$UPD_PLUGIN_A_NATIVE" "$UPD_PLUGIN_A" \
  >"$TMP/update-start-2.out" 2>"$TMP/update-start-2.err"; then
  UPD_DIGEST_2="$(record_field "$RECORD_U" runtime_digest)"
  UPD_CREATED_2="$(record_field "$RECORD_U" created_at)"
  if [ -n "$UPD_DIGEST_1" ] && [ "$UPD_DIGEST_2" != "$UPD_DIGEST_1" ] && [ "$UPD_CREATED_2" = "$UPD_CREATED_1" ]; then
    check "resumed SessionStart supersedes the record after a runtime digest change" PASS
  else
    check "resumed SessionStart supersedes the record after a runtime digest change" FAIL
  fi
else
  check "resumed SessionStart supersedes the record after a runtime digest change" FAIL
fi
UPD_GATE_BOUND="$(run_update_gate "$UPD_PLUGIN_A")"
UPD_GATE_BOUND_RC=$?
if [ "$UPD_GATE_BOUND_RC" -eq 0 ] && [ -z "$UPD_GATE_BOUND" ]; then
  check "capability gate allows the main thread once the record is re-bound" PASS
else
  check "capability gate allows the main thread once the record is re-bound" FAIL
fi

cp -R "$UPD_PLUGIN_A" "$UPD_PLUGIN_B"
printf '\n' >> "$UPD_PLUGIN_B/docs/$(basename "$UPD_TOUCH")"
UPD_PLUGIN_B_NATIVE="$(canonical_path "$UPD_PLUGIN_B")"
rm -rf "$UPD_PLUGIN_A"
if payload SessionStart "$SID_U" "$UPD_PROJECT" | run_update_hook "$UPD_PLUGIN_B_NATIVE" "$UPD_PLUGIN_B" \
  >"$TMP/update-start-3.out" 2>"$TMP/update-start-3.err"; then
  UPD_ROOT_3="$(record_field "$RECORD_U" plugin_root)"
  if same_canonical_path "$UPD_ROOT_3" "$UPD_PLUGIN_B_NATIVE" \
    && HOME="$UPD_HOME_NATIVE" ZENSU_SESSION_KEY="$KEY_U" CODEX_THREAD_ID='' \
      node "$UPD_CONTROL/resolve-v3.js" --field project_root >"$TMP/update-resolve.out" 2>"$TMP/update-resolve.err"; then
    check "resumed SessionStart re-binds a vanished plugin root and the stable reader resolves" PASS
  else
    check "resumed SessionStart re-binds a vanished plugin root and the stable reader resolves" FAIL
  fi
else
  check "resumed SessionStart re-binds a vanished plugin root and the stable reader resolves" FAIL
fi

cp "$RECORD_U" "$TMP/update-record-before-mismatch.json"
if payload SessionStart "$SID_U" "$UPD_PROJECT_OTHER" | run_update_hook "$UPD_PLUGIN_B_NATIVE" "$UPD_PLUGIN_B" \
  >"$TMP/update-start-4.out" 2>"$TMP/update-start-4.err"; then
  check "resumed SessionStart in another project root still fails closed" FAIL
elif grep -qF 'immutable session context mismatch' "$TMP/update-start-4.err" \
  && cmp -s "$RECORD_U" "$TMP/update-record-before-mismatch.json"; then
  check "resumed SessionStart in another project root still fails closed" PASS
else
  check "resumed SessionStart in another project root still fails closed" FAIL
fi

SID_V="codex/stop cap probe"
KEY_V="$(session_key "$SID_V")"
COUNT_V="$UPD_HOME_NATIVE/.zensu/stop-guard/codex/invalid-state-$KEY_V.count"
run_cap_stop() {
  printf '{"session_id":"%s"}' "$SID_V" \
    | HOME="$UPD_HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$UPD_PLUGIN_B_NATIVE" ZENSU_PLUGIN_ROOT="$UPD_PLUGIN_B_NATIVE" \
      bash "$UPD_PLUGIN_B/hooks/stop-chain-enforcer.sh" \
      >"$TMP/stop-cap-$1.out" 2>"$TMP/stop-cap-$1.err"
}
STOP_CAP_RELEASED=0
STOP_CAP_BLOCKED=0
i=1
while [ "$i" -le 4 ]; do
  run_cap_stop "$i"
  if grep -qF '"decision":"block"' "$TMP/stop-cap-$i.out"; then
    STOP_CAP_BLOCKED=$((STOP_CAP_BLOCKED + 1))
  elif grep -qF 'exceed the cap' "$TMP/stop-cap-$i.err"; then
    STOP_CAP_RELEASED=$((STOP_CAP_RELEASED + 1))
  fi
  i=$((i + 1))
done
if [ "$STOP_CAP_BLOCKED" -eq 3 ] && [ "$STOP_CAP_RELEASED" -eq 1 ] && [ "$(cat "$COUNT_V" 2>/dev/null)" = 4 ]; then
  check "unresolvable-state stop blocks release at the invalid-state cap with a loud warning" PASS
else
  check "unresolvable-state stop blocks release at the invalid-state cap with a loud warning" FAIL
fi

V_CAUSE='cause: stable reader refused: session-control reader-abi-v3: missing file:'
if grep -qF "$V_CAUSE" "$TMP/stop-cap-1.out"; then
  check "invalid-state deny names the resolver cause" PASS
else
  check "invalid-state deny names the resolver cause" FAIL
fi

EDIT_NO_RECORD="$(printf '%s' '{"tool_name":"apply_patch","session_id":"'"$SID_V"'","tool_input":{"input":"*** Begin Patch\n*** Update File: src/app.js\n@@\n+x\n*** End Patch"}}' \
  | HOME="$UPD_HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$UPD_PLUGIN_B_NATIVE" ZENSU_PLUGIN_ROOT="$UPD_PLUGIN_B_NATIVE" \
    bash "$UPD_PLUGIN_B/hooks/pre-edit-tdd-reminder.sh" 2>/dev/null)"
if printf '%s' "$EDIT_NO_RECORD" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$EDIT_NO_RECORD" | grep -qF "$V_CAUSE" \
  && printf '%s' "$EDIT_NO_RECORD" | grep -qF 'open /hooks and trust every Zensu hook' \
  && grep -qF 'open /hooks and trust every Zensu hook' "$TMP/stop-cap-1.out"; then
  check "invalid-state denials name the cause and point at re-trusting the Zensu hooks" PASS
else
  check "invalid-state denials name the cause and point at re-trusting the Zensu hooks" FAIL
fi

if payload SessionStart "$SID_V" "$UPD_PROJECT" | run_update_hook "$UPD_PLUGIN_B_NATIVE" "$UPD_PLUGIN_B" \
    >"$TMP/stop-cap-start.out" 2>"$TMP/stop-cap-start.err" \
  && run_cap_stop resolved \
  && ! grep -qF '"decision":"block"' "$TMP/stop-cap-resolved.out" \
  && [ ! -e "$COUNT_V" ] \
  && rm -f "$UPD_CONTROL/records/$KEY_V.json" \
  && run_cap_stop broken-again \
  && grep -qF 'invalid-state block 1 of 3' "$TMP/stop-cap-broken-again.out"; then
  check "a resolvable record resets the invalid-state stop count" PASS
else
  check "a resolvable record resets the invalid-state stop count" FAIL
fi

rm -f "$COUNT_V"
mkdir -p "$COUNT_V"
run_cap_stop unstorable
if ! grep -qF '"decision":"block"' "$TMP/stop-cap-unstorable.out" \
  && grep -qF 'invalid-state stop counter cannot be stored' "$TMP/stop-cap-unstorable.err"; then
  check "an invalid-state stop whose count cannot be stored is released loudly instead of blocking unbounded" PASS
else
  check "an invalid-state stop whose count cannot be stored is released loudly instead of blocking unbounded" FAIL
fi
rmdir "$COUNT_V"

if grep -qF '### Session Control trust boundary' "$ROOT/README.md" \
  && grep -qF 'not a cryptographically signed or broker-owned authority' "$ROOT/README.md" \
  && grep -qF 'same-user time-of-check/time-of-use races' "$ROOT/README.md"; then
  check "documentation states the same-user project-process trust boundary honestly" PASS
else
  check "Session Control trust-boundary documentation is present" FAIL
fi

printf '%s\n' "----" "test-session-control-codex: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
