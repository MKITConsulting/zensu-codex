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

ADOPT_HOME="$TMP/adopt-home"
ADOPT_PROJECT="$TMP/adopt-project"
ADOPT_PROJECT_OTHER="$TMP/adopt-project-other"
ADOPT_OLD="$TMP/adopt-cache/zensu/0.6.0"
ADOPT_NEW="$TMP/adopt-cache/zensu/0.6.1"
ADOPT_OUTSIDE="$TMP/adopt-outside/0.6.2"
mkdir -p "$ADOPT_HOME" "$ADOPT_PROJECT" "$ADOPT_PROJECT_OTHER" "$ADOPT_OLD" "$ADOPT_NEW" "$ADOPT_OUTSIDE"

adopt_install() {
  cp -R "$PLUGIN/.codex-plugin" "$PLUGIN/hooks" "$PLUGIN/agents" "$PLUGIN/skills" "$PLUGIN/docs" "$1/"
  MANIFEST="$1/.codex-plugin/plugin.json" VERSION="$2" node -e '
    const fs = require("node:fs");
    const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
    manifest.version = process.env.VERSION;
    fs.writeFileSync(process.env.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
  '
}
adopt_install "$ADOPT_OLD" 0.6.0
adopt_install "$ADOPT_NEW" 0.6.1
adopt_install "$ADOPT_OUTSIDE" 0.6.2
ADOPT_HOME_NATIVE="$(canonical_path "$ADOPT_HOME")"
ADOPT_OLD_NATIVE="$(canonical_path "$ADOPT_OLD")"
ADOPT_NEW_NATIVE="$(canonical_path "$ADOPT_NEW")"
ADOPT_OUTSIDE_NATIVE="$(canonical_path "$ADOPT_OUTSIDE")"
ADOPT_CONTROL="$ADOPT_HOME/.zensu/session-control/codex/v3"

adopt_start() {
  payload SessionStart "$1" "$ADOPT_PROJECT" \
    | HOME="$ADOPT_HOME_NATIVE" PLUGIN_ROOT="$2" CLAUDE_PLUGIN_ROOT="$2" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$2/hooks/session-start-session-control.sh" >/dev/null 2>&1
}

adopt_gate() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$3")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,tool_name:"Read",tool_input:{file_path:"README.md"}}));
  ' | HOME="$ADOPT_HOME_NATIVE" PLUGIN_ROOT="$2" CLAUDE_PLUGIN_ROOT="$2" bash "$2/hooks/pre-reviewer-capability-gate.sh" 2>/dev/null
}

adopt_subagent_gate() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$3")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,agent_id:"subagent-thread",agent_type:"default",tool_name:"Read",tool_input:{file_path:"README.md"}}));
  ' | HOME="$ADOPT_HOME_NATIVE" PLUGIN_ROOT="$2" CLAUDE_PLUGIN_ROOT="$2" bash "$2/hooks/pre-reviewer-capability-gate.sh" 2>/dev/null
}

adopt_prompt() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$3")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,prompt:"continue"}));
  ' | HOME="$ADOPT_HOME_NATIVE" PLUGIN_ROOT="$2" CLAUDE_PLUGIN_ROOT="$2" bash "$2/hooks/user-prompt-session-control.sh" 2>/dev/null
}

adopt_record() {
  printf '%s' "$ADOPT_CONTROL/records/$(session_key "$1").json"
}

SID_ADOPT_GATE="codex/open chat across an update via the gate"
SID_ADOPT_PROMPT="codex/open chat across an update via the prompt"
SID_ADOPT_BACK="codex/open chat facing an older installation"
SID_ADOPT_FOREIGN="codex/open chat used from another project"
SID_ADOPT_OUTSIDE="codex/open chat facing a non-sibling installation"
SID_ADOPT_SUBAGENT="codex/open chat whose subagent calls a tool first"
SID_ADOPT_PROMPT_AGENT="codex/open chat whose subagent prompt arrives first"
SID_ADOPT_STATE_MISSING="codex/open chat without workflow state"
SID_ADOPT_STATE_BAD="codex/open chat with corrupt workflow state"
SID_ADOPT_CORRUPT="codex/open chat with a corrupt record"
SID_ADOPT_STORE="codex/open chat bound to another store"
SID_ADOPT_RACE="codex/open chat with two parallel tool hooks"
SID_ADOPT_EDIT="codex/open chat whose first call is an edit"
SID_ADOPT_EDIT_PAIR="codex/open chat whose first edit meets both gates"
SID_ADOPT_STOP="codex/open chat that only answers in text"
for sid in "$SID_ADOPT_GATE" "$SID_ADOPT_PROMPT" "$SID_ADOPT_FOREIGN" "$SID_ADOPT_OUTSIDE" "$SID_ADOPT_SUBAGENT" \
  "$SID_ADOPT_PROMPT_AGENT" "$SID_ADOPT_STATE_MISSING" "$SID_ADOPT_STATE_BAD" "$SID_ADOPT_CORRUPT" "$SID_ADOPT_STORE" \
  "$SID_ADOPT_RACE" "$SID_ADOPT_EDIT" "$SID_ADOPT_EDIT_PAIR" "$SID_ADOPT_STOP"; do
  adopt_start "$sid" "$ADOPT_OLD_NATIVE"
done
adopt_start "$SID_ADOPT_BACK" "$ADOPT_NEW_NATIVE"
ADOPT_CREATED_GATE="$(record_field "$(adopt_record "$SID_ADOPT_GATE")" created_at)"

cp "$(adopt_record "$SID_ADOPT_BACK")" "$TMP/adopt-back-before.json"
ADOPT_BACK_OUT="$(adopt_gate "$SID_ADOPT_BACK" "$ADOPT_OLD_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_BACK_OUT" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$ADOPT_BACK_OUT" | grep -qF 're-bind refused: the installed plugin is older than the bound one' \
  && cmp -s "$(adopt_record "$SID_ADOPT_BACK")" "$TMP/adopt-back-before.json"; then
  check "the capability gate never re-binds a session to an older installation" PASS
else
  check "the capability gate never re-binds a session to an older installation" FAIL
fi

rm -rf "$ADOPT_OLD"

cp "$(adopt_record "$SID_ADOPT_OUTSIDE")" "$TMP/adopt-outside-before.json"
ADOPT_OUTSIDE_OUT="$(adopt_gate "$SID_ADOPT_OUTSIDE" "$ADOPT_OUTSIDE_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_OUTSIDE_OUT" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$ADOPT_OUTSIDE_OUT" | grep -qF 're-bind refused: the installed plugin is not a sibling of the bound installation' \
  && cmp -s "$(adopt_record "$SID_ADOPT_OUTSIDE")" "$TMP/adopt-outside-before.json"; then
  check "the capability gate never re-binds a session to an installation outside the bound one's parent" PASS
else
  check "the capability gate never re-binds a session to an installation outside the bound one's parent" FAIL
fi

cp "$(adopt_record "$SID_ADOPT_FOREIGN")" "$TMP/adopt-foreign-before.json"
ADOPT_FOREIGN_OUT="$(adopt_gate "$SID_ADOPT_FOREIGN" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT_OTHER")"
if printf '%s' "$ADOPT_FOREIGN_OUT" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$ADOPT_FOREIGN_OUT" | grep -qF 're-bind refused: the hook ran in another project than the recorded one' \
  && cmp -s "$(adopt_record "$SID_ADOPT_FOREIGN")" "$TMP/adopt-foreign-before.json"; then
  check "a tool call from another project never re-binds the session" PASS
else
  check "a tool call from another project never re-binds the session" FAIL
fi

cp "$(adopt_record "$SID_ADOPT_SUBAGENT")" "$TMP/adopt-subagent-before.json"
ADOPT_SUBAGENT_OUT="$(adopt_subagent_gate "$SID_ADOPT_SUBAGENT" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_SUBAGENT_UNCHANGED=no
cmp -s "$(adopt_record "$SID_ADOPT_SUBAGENT")" "$TMP/adopt-subagent-before.json" && ADOPT_SUBAGENT_UNCHANGED=yes
ADOPT_SUBAGENT_MAIN_OUT="$(adopt_gate "$SID_ADOPT_SUBAGENT" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_SUBAGENT_OUT" | grep -qF '"permissionDecision":"deny"' \
  && ! printf '%s' "$ADOPT_SUBAGENT_OUT" | grep -qF 're-bind refused' \
  && [ "$ADOPT_SUBAGENT_UNCHANGED" = yes ] \
  && [ -z "$ADOPT_SUBAGENT_MAIN_OUT" ] \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_SUBAGENT")" plugin_root)" "$ADOPT_NEW_NATIVE"; then
  check "a subagent's tool call never re-binds the session; the gate denies it and the main thread's next call re-binds" PASS
else
  check "a subagent's tool call never re-binds the session; the gate denies it and the main thread's next call re-binds" FAIL
fi

ADOPT_GATE_OUT="$(adopt_gate "$SID_ADOPT_GATE" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_GATE_RC=$?
ADOPT_GATE_RECORD="$(adopt_record "$SID_ADOPT_GATE")"
if [ "$ADOPT_GATE_RC" -eq 0 ] && [ -z "$ADOPT_GATE_OUT" ] \
  && same_canonical_path "$(record_field "$ADOPT_GATE_RECORD" plugin_root)" "$ADOPT_NEW_NATIVE" \
  && [ "$(record_field "$ADOPT_GATE_RECORD" plugin_version)" = 0.6.1 ] \
  && [ "$(record_field "$ADOPT_GATE_RECORD" created_at)" = "$ADOPT_CREATED_GATE" ] \
  && HOME="$ADOPT_HOME_NATIVE" ZENSU_SESSION_KEY="$(session_key "$SID_ADOPT_GATE")" CODEX_THREAD_ID='' \
    node "$ADOPT_CONTROL/resolve-v3.js" --field project_root >/dev/null 2>&1; then
  check "the capability gate re-binds an open session whose installation was replaced by a newer sibling and allows the call" PASS
else
  check "the capability gate re-binds an open session whose installation was replaced by a newer sibling and allows the call" FAIL
fi

ADOPT_PROMPT_OUT="$(adopt_prompt "$SID_ADOPT_PROMPT" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_PROMPT_RC=$?
ADOPT_PROMPT_AGAIN="$(adopt_prompt "$SID_ADOPT_PROMPT" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
if [ "$ADOPT_PROMPT_RC" -eq 0 ] \
  && printf '%s' "$ADOPT_PROMPT_OUT" | grep -qF '"hookEventName":"UserPromptSubmit"' \
  && printf '%s' "$ADOPT_PROMPT_OUT" | grep -qF 're-bound this chat from Zensu 0.6.0 to the installed Zensu 0.6.1' \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_PROMPT")" plugin_root)" "$ADOPT_NEW_NATIVE" \
  && [ -z "$ADOPT_PROMPT_AGAIN" ]; then
  check "the prompt hook re-binds an open session after an update once and then stays silent" PASS
else
  check "the prompt hook re-binds an open session after an update once and then stays silent" FAIL
fi

ADOPT_UNKNOWN_OUT="$(adopt_prompt "codex/never started" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_UNKNOWN_RC=$?
if [ "$ADOPT_UNKNOWN_RC" -eq 0 ] && [ -z "$ADOPT_UNKNOWN_OUT" ] && [ ! -e "$(adopt_record "codex/never started")" ]; then
  check "the prompt hook stays silent and creates nothing for a session without a record" PASS
else
  check "the prompt hook stays silent and creates nothing for a session without a record" FAIL
fi

adopt_hook() {
  HOME="$ADOPT_HOME_NATIVE" PLUGIN_ROOT="$ADOPT_NEW_NATIVE" CLAUDE_PLUGIN_ROOT="$ADOPT_NEW_NATIVE" bash "$ADOPT_NEW_NATIVE/hooks/$1" 2>/dev/null
}

adopt_state_file() {
  printf '%s' "$(canonical_path "$ADOPT_PROJECT")/.zensu/state/tdd-phase-$(session_key "$1").json"
}

adopt_patch_payload() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$ADOPT_PROJECT")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/adopted.js\n+x\n*** End Patch\n"}}));
  '
}

cp "$(adopt_record "$SID_ADOPT_PROMPT_AGENT")" "$TMP/adopt-prompt-agent-before.json"
ADOPT_PROMPT_AGENT_OUT="$(payload UserPromptSubmit "$SID_ADOPT_PROMPT_AGENT" "$ADOPT_PROJECT" subagent-thread default | adopt_hook user-prompt-session-control.sh)"
ADOPT_PROMPT_TYPE_OUT="$(payload UserPromptSubmit "$SID_ADOPT_PROMPT_AGENT" "$ADOPT_PROJECT" "" default | adopt_hook user-prompt-session-control.sh)"
ADOPT_PROMPT_AGENT_SAME=no
cmp -s "$(adopt_record "$SID_ADOPT_PROMPT_AGENT")" "$TMP/adopt-prompt-agent-before.json" && ADOPT_PROMPT_AGENT_SAME=yes
ADOPT_PROMPT_MAIN_OUT="$(payload UserPromptSubmit "$SID_ADOPT_PROMPT_AGENT" "$ADOPT_PROJECT" | adopt_hook user-prompt-session-control.sh)"
if [ -z "$ADOPT_PROMPT_AGENT_OUT" ] && [ -z "$ADOPT_PROMPT_TYPE_OUT" ] && [ "$ADOPT_PROMPT_AGENT_SAME" = yes ] \
  && printf '%s' "$ADOPT_PROMPT_MAIN_OUT" | grep -qF 're-bound this chat from Zensu 0.6.0 to the installed Zensu 0.6.1'; then
  check "the prompt hook never re-binds for a payload with agent fields, and the main thread's next prompt does" PASS
else
  check "the prompt hook never re-binds for a payload with agent fields, and the main thread's next prompt does" FAIL
fi

ADOPT_OUTSIDE_PROMPT="$(adopt_prompt "$SID_ADOPT_OUTSIDE" "$ADOPT_OUTSIDE_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_OUTSIDE_PROMPT" | grep -qF 'cannot re-bind this chat to the installed Zensu plugin: the installed plugin is not a sibling of the bound installation' \
  && printf '%s' "$ADOPT_OUTSIDE_PROMPT" | grep -qF 'Start a new chat to continue the Zensu workflow' \
  && cmp -s "$(adopt_record "$SID_ADOPT_OUTSIDE")" "$TMP/adopt-outside-before.json"; then
  check "a refused prompt re-bind tells the chat why and asks for a new chat" PASS
else
  check "a refused prompt re-bind tells the chat why and asks for a new chat" FAIL
fi

rm -f "$(adopt_state_file "$SID_ADOPT_STATE_MISSING")"
printf 'not json' > "$(adopt_state_file "$SID_ADOPT_STATE_BAD")"
cp "$(adopt_record "$SID_ADOPT_STATE_MISSING")" "$TMP/adopt-state-missing-before.json"
cp "$(adopt_record "$SID_ADOPT_STATE_BAD")" "$TMP/adopt-state-bad-before.json"
ADOPT_STATE_MISSING_OUT="$(adopt_gate "$SID_ADOPT_STATE_MISSING" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_STATE_BAD_OUT="$(adopt_gate "$SID_ADOPT_STATE_BAD" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_STATE_MISSING_OUT" | grep -qF 're-bind refused: its workflow state is missing or unreadable' \
  && printf '%s' "$ADOPT_STATE_BAD_OUT" | grep -qF 're-bind refused: its workflow state is missing or unreadable' \
  && cmp -s "$(adopt_record "$SID_ADOPT_STATE_MISSING")" "$TMP/adopt-state-missing-before.json" \
  && cmp -s "$(adopt_record "$SID_ADOPT_STATE_BAD")" "$TMP/adopt-state-bad-before.json"; then
  check "a session whose workflow state is missing or corrupt is never re-bound" PASS
else
  check "a session whose workflow state is missing or corrupt is never re-bound" FAIL
fi

printf '{' > "$(adopt_record "$SID_ADOPT_CORRUPT")"
RECORD_STORE="$(adopt_record "$SID_ADOPT_STORE")" node -e '
  const fs = require("node:fs");
  const record = JSON.parse(fs.readFileSync(process.env.RECORD_STORE, "utf8"));
  record.plugin_data = "/nonexistent-session-control-store";
  fs.writeFileSync(process.env.RECORD_STORE, JSON.stringify(record));
'
cp "$(adopt_record "$SID_ADOPT_STORE")" "$TMP/adopt-store-before.json"
ADOPT_CORRUPT_OUT="$(adopt_prompt "$SID_ADOPT_CORRUPT" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
ADOPT_STORE_OUT="$(adopt_prompt "$SID_ADOPT_STORE" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_CORRUPT_OUT" | grep -qF 'its Session Control record is unreadable' \
  && [ "$(cat "$(adopt_record "$SID_ADOPT_CORRUPT")")" = '{' ] \
  && printf '%s' "$ADOPT_STORE_OUT" | grep -qF 'its record belongs to another Session Control store' \
  && cmp -s "$(adopt_record "$SID_ADOPT_STORE")" "$TMP/adopt-store-before.json"; then
  check "an unreadable record or one from another store is never re-bound" PASS
else
  check "an unreadable record or one from another store is never re-bound" FAIL
fi

ADOPT_INPLACE="$TMP/adopt-cache/zensu/0.6.3"
mkdir -p "$ADOPT_INPLACE"
adopt_install "$ADOPT_INPLACE" 0.6.3
ADOPT_INPLACE_NATIVE="$(canonical_path "$ADOPT_INPLACE")"
SID_ADOPT_INPLACE="codex/open chat whose installation changed in place"
adopt_start "$SID_ADOPT_INPLACE" "$ADOPT_INPLACE_NATIVE"
printf '\n' >> "$(find "$ADOPT_INPLACE/docs" -type f | sort | head -1)"
cp "$(adopt_record "$SID_ADOPT_INPLACE")" "$TMP/adopt-inplace-before.json"
ADOPT_INPLACE_OUT="$(adopt_gate "$SID_ADOPT_INPLACE" "$ADOPT_INPLACE_NATIVE" "$ADOPT_PROJECT")"
if printf '%s' "$ADOPT_INPLACE_OUT" | grep -qF 're-bind refused: the bound installation changed in place, which is never re-bound' \
  && cmp -s "$(adopt_record "$SID_ADOPT_INPLACE")" "$TMP/adopt-inplace-before.json"; then
  check "an installation that changed in place is never re-bound" PASS
else
  check "an installation that changed in place is never re-bound" FAIL
fi

adopt_gate "$SID_ADOPT_RACE" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT" > "$TMP/adopt-race-1.out" &
ADOPT_RACE_PID_1=$!
adopt_gate "$SID_ADOPT_RACE" "$ADOPT_NEW_NATIVE" "$ADOPT_PROJECT" > "$TMP/adopt-race-2.out" &
ADOPT_RACE_PID_2=$!
wait "$ADOPT_RACE_PID_1" "$ADOPT_RACE_PID_2"
if [ ! -s "$TMP/adopt-race-1.out" ] && [ ! -s "$TMP/adopt-race-2.out" ] \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_RACE")" plugin_root)" "$ADOPT_NEW_NATIVE"; then
  check "two parallel gate calls on a stale record both re-bind or find it re-bound, and both allow" PASS
else
  check "two parallel gate calls on a stale record both re-bind or find it re-bound, and both allow" FAIL
fi

ADOPT_EDIT_OUT="$(adopt_patch_payload "$SID_ADOPT_EDIT" | adopt_hook pre-edit-tdd-reminder.sh)"
if ! printf '%s' "$ADOPT_EDIT_OUT" | grep -qF '"permissionDecision":"deny"' \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_EDIT")" plugin_root)" "$ADOPT_NEW_NATIVE"; then
  check "the edit gate re-binds an open session whose first call is an edit instead of denying it" PASS
else
  check "the edit gate re-binds an open session whose first call is an edit instead of denying it" FAIL
fi

adopt_patch_payload "$SID_ADOPT_EDIT_PAIR" > "$TMP/adopt-edit-pair.json"
adopt_hook pre-edit-tdd-reminder.sh < "$TMP/adopt-edit-pair.json" > "$TMP/adopt-edit-pair-edit.out" &
ADOPT_PAIR_PID_1=$!
adopt_hook pre-reviewer-capability-gate.sh < "$TMP/adopt-edit-pair.json" > "$TMP/adopt-edit-pair-gate.out" &
ADOPT_PAIR_PID_2=$!
wait "$ADOPT_PAIR_PID_1" "$ADOPT_PAIR_PID_2"
if ! grep -qF '"permissionDecision":"deny"' "$TMP/adopt-edit-pair-edit.out" \
  && ! grep -qF '"permissionDecision":"deny"' "$TMP/adopt-edit-pair-gate.out" \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_EDIT_PAIR")" plugin_root)" "$ADOPT_NEW_NATIVE"; then
  check "the edit gate and the capability gate running side by side on a stale record both allow the first edit" PASS
else
  check "the edit gate and the capability gate running side by side on a stale record both allow the first edit" FAIL
fi

ADOPT_STOP_OUT="$(payload Stop "$SID_ADOPT_STOP" "$ADOPT_PROJECT" | adopt_hook stop-chain-enforcer.sh)"
if ! printf '%s' "$ADOPT_STOP_OUT" | grep -qF '"decision":"block"' \
  && same_canonical_path "$(record_field "$(adopt_record "$SID_ADOPT_STOP")" plugin_root)" "$ADOPT_NEW_NATIVE"; then
  check "the Stop enforcer re-binds an open session after a text-only turn instead of blocking" PASS
else
  check "the Stop enforcer re-binds an open session after a text-only turn instead of blocking" FAIL
fi

RA_HOME="$TMP/reanchor-home"
RA_REPO="$TMP/reanchor-repo"
RA_TREES="$TMP/reanchor-trees"
RA_OTHER="$TMP/reanchor-other-repo"
RA_PLUGINS="$TMP/reanchor-cache/zensu"
RA_NO_HOOKS="$TMP/reanchor-no-git-hooks"
mkdir -p "$RA_HOME" "$RA_REPO" "$RA_TREES" "$RA_OTHER" "$RA_PLUGINS/0.7.0" "$RA_PLUGINS/0.7.1" "$RA_NO_HOOKS"

ra_git() {
  git -c user.name=zensu-test -c user.email=zensu-test@example.invalid -c commit.gpgsign=false \
    -c init.defaultBranch=main -c core.hooksPath="$RA_NO_HOOKS" "$@" >/dev/null 2>&1
}

ra_git -C "$RA_REPO" init -q
ra_git -C "$RA_REPO" commit -q --allow-empty --no-verify -m init
for tree in moved open bad combined third; do
  ra_git -C "$RA_REPO" worktree add -q -b "reanchor-$tree" "$RA_TREES/$tree"
done
ra_git -C "$RA_REPO" worktree add -q -b reanchor-inner "$RA_REPO/inner"
ra_git -C "$RA_OTHER" init -q
ra_git -C "$RA_OTHER" commit -q --allow-empty --no-verify -m init
adopt_install "$RA_PLUGINS/0.7.0" 0.7.0
adopt_install "$RA_PLUGINS/0.7.1" 0.7.1
RA_HOME_NATIVE="$(canonical_path "$RA_HOME")"
RA_OLD_NATIVE="$(canonical_path "$RA_PLUGINS/0.7.0")"
RA_NEW_NATIVE="$(canonical_path "$RA_PLUGINS/0.7.1")"
RA_CONTROL="$RA_HOME/.zensu/session-control/codex/v3"
CORE_NATIVE="$(canonical_path "$CORE")"

ra_hook() {
  HOME="$RA_HOME_NATIVE" PLUGIN_ROOT="$1" CLAUDE_PLUGIN_ROOT="$1" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$1/hooks/$2" 2>/dev/null
}

ra_start() {
  payload SessionStart "$1" "$2" | ra_hook "${3:-$PLUGIN_NATIVE}" session-start-session-control.sh >/dev/null
}

ra_prompt() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$2")" PAYLOAD_PROMPT="$3" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,prompt:process.env.PAYLOAD_PROMPT}));
  ' | ra_hook "${4:-$PLUGIN_NATIVE}" user-prompt-session-control.sh
}

ra_agent_prompt() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$2")" PAYLOAD_AGENT_ID="$3" node -e '
    const payload = {hook_event_name:"UserPromptSubmit",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,prompt:"zensu reanchor",agent_type:"default"};
    if (process.env.PAYLOAD_AGENT_ID) payload.agent_id = process.env.PAYLOAD_AGENT_ID;
    process.stdout.write(JSON.stringify(payload));
  ' | ra_hook "$PLUGIN_NATIVE" user-prompt-session-control.sh
}

ra_gate() {
  PAYLOAD_SESSION="$1" PAYLOAD_CWD="$(canonical_path "$2")" node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,prompt:"zensu reanchor",tool_name:"Read",tool_input:{file_path:"README.md"}}));
  ' | ra_hook "${3:-$PLUGIN_NATIVE}" pre-reviewer-capability-gate.sh
}

ra_record() {
  printf '%s' "$RA_CONTROL/records/$(session_key "$1").json"
}

ra_state() {
  printf '%s' "$(canonical_path "$1")/.zensu/state/tdd-phase-$(session_key "$2").json"
}

ra_superseded() {
  find "$RA_CONTROL/records" -name "$(session_key "$1").superseded-reanchor-*.json" | sort
}

ra_document() {
  node -e '
    const state = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    const last = state.history[state.history.length - 1] || {};
    process.stdout.write([state.workflow_state, state.active, state.implComplete, last.phase, last.reason].join("|"));
  ' "$1"
}

SID_RA_MOVE="codex/re-anchor after a worktree move"
SID_RA_FOREIGN="codex/re-anchor into another repository"
SID_RA_AGENT="codex/re-anchor asked through a subagent payload"
SID_RA_OPEN="codex/re-anchor with open work"
SID_RA_BAD="codex/re-anchor onto an unusable workflow state"
SID_RA_NESTED="codex/re-anchor into the checkout that contains the anchor"
SID_RA_COMBINED="codex/re-anchor after a plugin update and a worktree move"
for sid in "$SID_RA_MOVE" "$SID_RA_FOREIGN" "$SID_RA_AGENT" "$SID_RA_OPEN" "$SID_RA_BAD"; do
  ra_start "$sid" "$RA_REPO"
done
ra_start "$SID_RA_NESTED" "$RA_REPO/inner"
ra_start "$SID_RA_COMBINED" "$RA_REPO" "$RA_OLD_NATIVE"

cp "$(ra_record "$SID_RA_MOVE")" "$TMP/reanchor-move-before.json"
RA_NOTICE="$(ra_prompt "$SID_RA_MOVE" "$RA_TREES/moved" 'continue with the task')"
RA_LOOSE="$(ra_prompt "$SID_RA_MOVE" "$RA_TREES/moved" 'zensu reanchor now')"
RA_DENIED="$(ra_gate "$SID_RA_MOVE" "$RA_TREES/moved")"
if printf '%s' "$RA_NOTICE" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && printf '%s' "$RA_LOOSE" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && printf '%s' "$RA_DENIED" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$RA_DENIED" | grep -qF 'tool project does not match immutable context' \
  && printf '%s' "$RA_DENIED" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && ! printf '%s' "$RA_DENIED" | grep -qF 'open /hooks' \
  && cmp -s "$(ra_record "$SID_RA_MOVE")" "$TMP/reanchor-move-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_MOVE")" ] \
  && [ ! -e "$(ra_state "$RA_TREES/moved" "$SID_RA_MOVE")" ]; then
  check "without the user's explicit message a moved chat is never re-anchored, and the prompt hook and the gate name that message" PASS
else
  check "without the user's explicit message a moved chat is never re-anchored, and the prompt hook and the gate name that message" FAIL
fi

cp "$(ra_record "$SID_RA_AGENT")" "$TMP/reanchor-agent-before.json"
RA_AGENT_OUT="$(ra_agent_prompt "$SID_RA_AGENT" "$RA_TREES/moved" subagent-thread)"
RA_AGENT_TYPE_OUT="$(ra_agent_prompt "$SID_RA_AGENT" "$RA_TREES/moved" '')"
RA_AGENT_GATE="$(ra_gate "$SID_RA_AGENT" "$RA_TREES/moved")"
if [ -z "$RA_AGENT_OUT" ] && [ -z "$RA_AGENT_TYPE_OUT" ] \
  && printf '%s' "$RA_AGENT_GATE" | grep -qF '"permissionDecision":"deny"' \
  && cmp -s "$(ra_record "$SID_RA_AGENT")" "$TMP/reanchor-agent-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_AGENT")" ] \
  && [ ! -e "$(ra_state "$RA_TREES/moved" "$SID_RA_AGENT")" ]; then
  check "the message in a payload with agent fields, or in a tool call, never re-anchors the chat" PASS
else
  check "the message in a payload with agent fields, or in a tool call, never re-anchors the chat" FAIL
fi

cp "$(ra_record "$SID_RA_FOREIGN")" "$TMP/reanchor-foreign-before.json"
RA_FOREIGN_NOTICE="$(ra_prompt "$SID_RA_FOREIGN" "$RA_OTHER" 'continue')"
RA_FOREIGN_OUT="$(ra_prompt "$SID_RA_FOREIGN" "$RA_OTHER" 'zensu reanchor')"
if printf '%s' "$RA_FOREIGN_NOTICE" | grep -qF 'The anchor cannot move there because the working directory of this chat belongs to another repository than the anchored project root' \
  && printf '%s' "$RA_FOREIGN_OUT" | grep -qF 'did not re-anchor this chat: the working directory of this chat belongs to another repository than the anchored project root. Nothing was changed.' \
  && cmp -s "$(ra_record "$SID_RA_FOREIGN")" "$TMP/reanchor-foreign-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_FOREIGN")" ] \
  && [ ! -e "$(ra_state "$RA_OTHER" "$SID_RA_FOREIGN")" ]; then
  check "a chat that moved into another repository is never re-anchored, also on the user's message" PASS
else
  check "a chat that moved into another repository is never re-anchored, also on the user's message" FAIL
fi

cp "$(ra_record "$SID_RA_NESTED")" "$TMP/reanchor-nested-before.json"
RA_NESTED_OUT="$(ra_prompt "$SID_RA_NESTED" "$RA_REPO" 'zensu reanchor')"
if printf '%s' "$RA_NESTED_OUT" | grep -qF 'did not re-anchor this chat: the worktree of this chat contains the anchored project root' \
  && cmp -s "$(ra_record "$SID_RA_NESTED")" "$TMP/reanchor-nested-before.json"; then
  check "a re-anchor never widens the anchor to a checkout that contains it" PASS
else
  check "a re-anchor never widens the anchor to a checkout that contains it" FAIL
fi

RA_MOVE_OUT="$(ra_prompt "$SID_RA_MOVE" "$RA_TREES/moved" '  Zensu  Reanchor ')"
RA_MOVE_RECORD="$(ra_record "$SID_RA_MOVE")"
RA_ALLOWED="$(ra_gate "$SID_RA_MOVE" "$RA_TREES/moved")"
RA_ALLOWED_RC=$?
RA_RESOLVED="$(HOME="$RA_HOME_NATIVE" ZENSU_SESSION_KEY="$(session_key "$SID_RA_MOVE")" CODEX_THREAD_ID='' \
  node "$RA_CONTROL/resolve-v3.js" --field project_root 2>/dev/null)"
if printf '%s' "$RA_MOVE_OUT" | grep -qF 're-anchored this chat from' \
  && same_canonical_path "$(record_field "$RA_MOVE_RECORD" project_root)" "$RA_TREES/moved" \
  && [ "$RA_ALLOWED_RC" -eq 0 ] && [ -z "$RA_ALLOWED" ] \
  && [ -n "$RA_RESOLVED" ] && same_canonical_path "$RA_RESOLVED" "$RA_TREES/moved"; then
  check "the user's message re-anchors a moved chat to its worktree, the gate allows the next call there, and the stable reader resolves it" PASS
else
  check "the user's message re-anchors a moved chat to its worktree, the gate allows the next call there, and the stable reader resolves it" FAIL
fi

RA_CHANGED="$(node -e '
  const fs = require("node:fs");
  const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const after = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].sort();
  process.stdout.write(keys.filter((key) => JSON.stringify(before[key]) !== JSON.stringify(after[key])).join(","));
' "$TMP/reanchor-move-before.json" "$RA_MOVE_RECORD")"
RA_SUPERSEDED="$(ra_superseded "$SID_RA_MOVE")"
if [ "$RA_CHANGED" = project_root ] && [ "$(printf '%s\n' "$RA_SUPERSEDED" | grep -c .)" -eq 1 ] \
  && cmp -s "$RA_SUPERSEDED" "$TMP/reanchor-move-before.json"; then
  check "the re-anchor changes only the project root and keeps the previous record beside it unchanged" PASS
else
  check "the re-anchor changes only the project root and keeps the previous record beside it unchanged" FAIL
fi

RA_NEW_DOCUMENT="$(ra_document "$(ra_state "$RA_TREES/moved" "$SID_RA_MOVE")" 2>/dev/null)"
RA_OLD_DOCUMENT="$(ra_document "$(ra_state "$RA_REPO" "$SID_RA_MOVE")" 2>/dev/null)"
RA_EXPECTED_REASON="$(node -e '
  const fs = require("node:fs");
  process.stdout.write(`project-root-reanchored: ${fs.realpathSync.native(process.argv[1])} -> ${fs.realpathSync.native(process.argv[2])}`);
' "$RA_REPO" "$RA_TREES/moved")"
case "$RA_NEW_DOCUMENT" in
  "project_root_reanchored|false|false|PROJECT_ROOT_REANCHORED|$RA_EXPECTED_REASON"*) RA_NEW_OK=yes ;;
  *) RA_NEW_OK=no ;;
esac
case "$RA_OLD_DOCUMENT" in
  "project_root_reanchored|false|false|PROJECT_ROOT_REANCHORED|$RA_EXPECTED_REASON"*) RA_OLD_OK=yes ;;
  *) RA_OLD_OK=no ;;
esac
if [ "$RA_NEW_OK" = yes ] && [ "$RA_OLD_OK" = yes ] \
  && printf '%s' "$RA_MOVE_OUT" | grep -qF 'starts with a fresh, inactive workflow state in the new worktree'; then
  check "the re-anchor creates the chat's workflow state in the new worktree and records the move in both workflow states" PASS
else
  check "the re-anchor creates the chat's workflow state in the new worktree and records the move in both workflow states" FAIL
fi

RA_AGAIN="$(ra_prompt "$SID_RA_MOVE" "$RA_TREES/moved" 'zensu reanchor')"
if printf '%s' "$RA_AGAIN" | grep -qF 'did not re-anchor this chat: it is already anchored to the working directory of this chat' \
  && [ "$(ra_superseded "$SID_RA_MOVE" | grep -c .)" -eq 1 ]; then
  check "a repeated message in the re-anchored worktree changes nothing" PASS
else
  check "a repeated message in the re-anchored worktree changes nothing" FAIL
fi

cp "$RA_MOVE_RECORD" "$TMP/reanchor-move-after.json"
if payload SessionStart "$SID_RA_MOVE" "$RA_TREES/moved" | ra_hook "$PLUGIN_NATIVE" session-start-session-control.sh >/dev/null \
  && cmp -s "$RA_MOVE_RECORD" "$TMP/reanchor-move-after.json"; then
  RA_RESUME_OK=yes
else
  RA_RESUME_OK=no
fi
if [ "$RA_RESUME_OK" = yes ] \
  && ! payload SessionStart "$SID_RA_MOVE" "$RA_REPO" \
    | HOME="$RA_HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" bash "$PLUGIN_NATIVE/hooks/session-start-session-control.sh" \
      >/dev/null 2>"$TMP/reanchor-resume-previous.err" \
  && grep -qF 'immutable session context mismatch' "$TMP/reanchor-resume-previous.err" \
  && ! payload SessionStart "$SID_RA_MOVE" "$RA_TREES/third" \
    | HOME="$RA_HOME_NATIVE" PLUGIN_ROOT="$PLUGIN_NATIVE" CLAUDE_PLUGIN_ROOT="$PLUGIN_NATIVE" bash "$PLUGIN_NATIVE/hooks/session-start-session-control.sh" \
      >/dev/null 2>"$TMP/reanchor-resume-third.err" \
  && grep -qF 'immutable session context mismatch' "$TMP/reanchor-resume-third.err" \
  && [ ! -e "$(ra_state "$RA_TREES/third" "$SID_RA_MOVE")" ] \
  && cmp -s "$RA_MOVE_RECORD" "$TMP/reanchor-move-after.json"; then
  check "a resumed SessionStart in the re-anchored worktree succeeds, and one in the previous root or in a third worktree of the repository fails closed" PASS
else
  check "a resumed SessionStart in the re-anchored worktree succeeds, and one in the previous root or in a third worktree of the repository fails closed" FAIL
fi

CORE_PATH="$CORE_NATIVE" PROJECT="$(canonical_path "$RA_REPO")" SID="$SID_RA_OPEN" node -e '
  const core = require(process.env.CORE_PATH);
  core.mutateWorkflowState({ projectRoot: process.env.PROJECT, sessionId: process.env.SID, workflowState: "active", event: "tdd-begin" },
    (state) => ({ ...state, active: true, implComplete: true }));
'
cp "$(ra_record "$SID_RA_OPEN")" "$TMP/reanchor-open-before.json"
RA_OPEN_NOTICE="$(ra_prompt "$SID_RA_OPEN" "$RA_TREES/open" 'continue')"
RA_OPEN_OUT="$(ra_prompt "$SID_RA_OPEN" "$RA_TREES/open" 'zensu reanchor')"
if printf '%s' "$RA_OPEN_OUT" | grep -qF 'still holds open work (an armed review chain that has not reached its terminus)' \
  && printf '%s' "$RA_OPEN_OUT" | grep -qF '`zensu reanchor --discard-open-work`' \
  && printf '%s' "$RA_OPEN_NOTICE" | grep -qF '`zensu reanchor --discard-open-work`' \
  && cmp -s "$(ra_record "$SID_RA_OPEN")" "$TMP/reanchor-open-before.json" \
  && [ ! -e "$(ra_state "$RA_TREES/open" "$SID_RA_OPEN")" ]; then
  check "open work under the anchored root refuses the re-anchor and names the explicit discard message" PASS
else
  check "open work under the anchored root refuses the re-anchor and names the explicit discard message" FAIL
fi

RA_DISCARD_OUT="$(ra_prompt "$SID_RA_OPEN" "$RA_TREES/open" 'zensu reanchor --discard-open-work')"
RA_DISCARDED="$(ra_document "$(ra_state "$RA_REPO" "$SID_RA_OPEN")" 2>/dev/null)"
case "$RA_DISCARDED" in
  'project_root_reanchored|false|false|PROJECT_ROOT_REANCHORED|'*'; open work discarded: an armed review chain that has not reached its terminus') RA_DISCARD_OK=yes ;;
  *) RA_DISCARD_OK=no ;;
esac
if [ "$RA_DISCARD_OK" = yes ] \
  && printf '%s' "$RA_DISCARD_OUT" | grep -qF 'was abandoned at the user' \
  && same_canonical_path "$(record_field "$(ra_record "$SID_RA_OPEN")" project_root)" "$RA_TREES/open"; then
  check "the explicit discard message re-anchors a chat with open work and closes that work under the previous root" PASS
else
  check "the explicit discard message re-anchors a chat with open work and closes that work under the previous root" FAIL
fi

mkdir -p "$(canonical_path "$RA_TREES/bad")/.zensu/state"
printf 'not json' > "$(ra_state "$RA_TREES/bad" "$SID_RA_BAD")"
cp "$(ra_record "$SID_RA_BAD")" "$TMP/reanchor-bad-before.json"
RA_BAD_OUT="$(ra_prompt "$SID_RA_BAD" "$RA_TREES/bad" 'zensu reanchor')"
if printf '%s' "$RA_BAD_OUT" | grep -qF 'is unsafe or unreadable, and it is never overwritten' \
  && cmp -s "$(ra_record "$SID_RA_BAD")" "$TMP/reanchor-bad-before.json" \
  && [ "$(cat "$(ra_state "$RA_TREES/bad" "$SID_RA_BAD")")" = 'not json' ]; then
  check "an unusable workflow state under the new worktree refuses the re-anchor and is never overwritten" PASS
else
  check "an unusable workflow state under the new worktree refuses the re-anchor and is never overwritten" FAIL
fi

RA_COMBINED_CREATED="$(record_field "$(ra_record "$SID_RA_COMBINED")" created_at)"
RA_COMBINED_NOTICE="$(ra_prompt "$SID_RA_COMBINED" "$RA_TREES/combined" 'continue' "$RA_NEW_NATIVE")"
RA_COMBINED_OUT="$(ra_prompt "$SID_RA_COMBINED" "$RA_TREES/combined" 'zensu reanchor' "$RA_NEW_NATIVE")"
RA_COMBINED_RECORD="$(ra_record "$SID_RA_COMBINED")"
RA_COMBINED_GATE="$(ra_gate "$SID_RA_COMBINED" "$RA_TREES/combined" "$RA_NEW_NATIVE")"
RA_COMBINED_GATE_RC=$?
if printf '%s' "$RA_COMBINED_NOTICE" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && printf '%s' "$RA_COMBINED_OUT" | grep -qF 'also re-bound the chat from Zensu 0.7.0 to the installed Zensu 0.7.1' \
  && same_canonical_path "$(record_field "$RA_COMBINED_RECORD" project_root)" "$RA_TREES/combined" \
  && same_canonical_path "$(record_field "$RA_COMBINED_RECORD" plugin_root)" "$RA_NEW_NATIVE" \
  && [ "$(record_field "$RA_COMBINED_RECORD" plugin_version)" = 0.7.1 ] \
  && [ "$(record_field "$RA_COMBINED_RECORD" created_at)" = "$RA_COMBINED_CREATED" ] \
  && [ "$RA_COMBINED_GATE_RC" -eq 0 ] && [ -z "$RA_COMBINED_GATE" ]; then
  check "after a plugin update and a worktree move the user's message re-anchors and re-binds the chat in one step" PASS
else
  check "after a plugin update and a worktree move the user's message re-anchors and re-binds the chat in one step" FAIL
fi

for tree in wide spot stray; do
  ra_git -C "$RA_REPO" worktree add -q -b "reanchor-$tree" "$RA_TREES/$tree"
done
mv "$RA_TREES/stray" "$RA_TREES/stray-moved"
mkdir -p "$RA_REPO/sub" "$RA_REPO/vanished" "$RA_PLUGINS/0.7.2"
adopt_install "$RA_PLUGINS/0.7.2" 0.7.2
RA_INPLACE_NATIVE="$(canonical_path "$RA_PLUGINS/0.7.2")"
SID_RA_WIDE="codex/re-anchor into a worktree that holds another worktree"
SID_RA_STRAY="codex/re-anchor into an unregistered copy of a worktree"
SID_RA_POSITION="codex/re-anchor to another place in a worktree"
SID_RA_GONE="codex/re-anchor after the anchored root was deleted"
SID_RA_BACK="codex/re-anchor through an older installation"
SID_RA_INPLACE="codex/re-anchor through an installation changed in place"
SID_RA_STOP="codex/moved chat with an open review chain"
SID_RA_FAIL="codex/re-anchor that fails inside Session Control"
ra_start "$SID_RA_WIDE" "$RA_TREES/wide"
ra_start "$SID_RA_STRAY" "$RA_TREES/wide"
ra_start "$SID_RA_POSITION" "$RA_REPO/sub"
ra_start "$SID_RA_GONE" "$RA_REPO/vanished"
ra_start "$SID_RA_BACK" "$RA_REPO" "$RA_NEW_NATIVE"
ra_start "$SID_RA_INPLACE" "$RA_REPO" "$RA_INPLACE_NATIVE"
ra_start "$SID_RA_STOP" "$RA_REPO"
ra_start "$SID_RA_FAIL" "$RA_REPO"
rm -rf "$RA_REPO/vanished"
printf '\n' >> "$(find "$RA_PLUGINS/0.7.2/docs" -type f | sort | head -1)"

ra_refused() {
  cp "$(ra_record "$1")" "$TMP/reanchor-refused-before.json"
  RA_REFUSED_OUT="$(ra_prompt "$1" "$2" 'zensu reanchor' "${4:-$PLUGIN_NATIVE}")"
  printf '%s' "$RA_REFUSED_OUT" | grep -qF "did not re-anchor this chat: $3" \
    && cmp -s "$(ra_record "$1")" "$TMP/reanchor-refused-before.json" \
    && [ -z "$(ra_superseded "$1")" ]
}

if ra_refused "$SID_RA_WIDE" "$RA_REPO" 'other registered worktrees of the repository lie inside the worktree of this chat' \
  && ra_refused "$SID_RA_STRAY" "$RA_TREES/stray-moved" 'the worktree of this chat is not a registered worktree of that repository' \
  && ra_refused "$SID_RA_POSITION" "$RA_TREES/spot" 'the working directory of this chat does not sit at the same place in its worktree' \
  && ra_refused "$SID_RA_GONE" "$RA_TREES/spot" 'the project root it is anchored to no longer exists'; then
  check "a re-anchor never moves into an unregistered worktree, a worktree holding another one or another place in a worktree, nor away from a deleted root" PASS
else
  check "a re-anchor never moves into an unregistered worktree, a worktree holding another one or another place in a worktree, nor away from a deleted root" FAIL
fi

if ra_refused "$SID_RA_BACK" "$RA_TREES/spot" 'the installed plugin is older than the bound one' "$RA_OLD_NATIVE" \
  && ra_refused "$SID_RA_INPLACE" "$RA_TREES/spot" 'the bound installation changed in place, which is never re-bound' "$RA_INPLACE_NATIVE"; then
  check "a re-anchor never re-binds the chat to an older installation or to one that changed in place" PASS
else
  check "a re-anchor never re-binds the chat to an older installation or to one that changed in place" FAIL
fi

SID_RA_GIT="codex/re-anchor while git cannot answer"
ra_start "$SID_RA_GIT" "$RA_REPO"
cp "$(ra_record "$SID_RA_GIT")" "$TMP/reanchor-git-before.json"
RA_GIT_OUT="$(REANCHOR_MODULE="$(canonical_path "$PLUGIN/hooks/lib/codex-session-reanchor-v1.js")" HOME_PATH="$RA_HOME_NATIVE" \
  SID="$SID_RA_GIT" TARGET="$(canonical_path "$RA_TREES/spot")" \
  env -u PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT -u ZENSU_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT \
    -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY node -e '
    const { execFileSync } = require("node:child_process");
    const reanchor = require(process.env.REANCHOR_MODULE);
    const failing = (fields) => () => { throw Object.assign(new Error("git failed"), fields); };
    const listingFails = (fields) => (file, args, options) => (args[0] === "worktree" ? failing(fields)() : execFileSync(file, args, options));
    const attempts = [
      failing({ code: "ENOENT" }),
      failing({ code: "ETIMEDOUT", signal: "SIGTERM", status: null }),
      failing({ status: 129 }),
      () => "--path-format=absolute\n",
      listingFails({ status: 129 }),
      failing({ status: 128 }),
      listingFails({ status: 128 }),
      undefined,
    ];
    const options = { home: process.env.HOME_PATH, sessionId: process.env.SID, cwd: process.env.TARGET };
    const reasons = attempts.map((execGit) => reanchor.reanchorVerdict({ ...options, execGit }).reason || "reanchorable");
    const unanswered = { ...options, execGit: failing({ status: 129 }) };
    const moved = reanchor.outsideAnchorNotice(unanswered);
    const outcome = reanchor.reanchorForHook(unanswered);
    process.stdout.write([
      reasons.join("|"),
      outcome.reason,
      reanchor.reanchorNotice(outcome),
      moved,
      String(reanchor.promptNotice(unanswered) === moved),
    ].join("\n"));
  ')"
ra_git_line() {
  printf '%s\n' "$RA_GIT_OUT" | sed -n "$1p"
}
if [ "$(ra_git_line 1)" = "git-unavailable|git-unavailable|git-unavailable|git-unavailable|git-unavailable|recorded-root-not-in-a-worktree|target-not-a-registered-worktree|reanchorable" ] \
  && [ "$(ra_git_line 2)" = git-unavailable ] \
  && ra_git_line 3 | grep -qF 'did not re-anchor this chat: git did not answer about the anchored project root or the working directory of this chat' \
  && ra_git_line 3 | grep -qF 'Once git answers, sending the message again retries the move' \
  && ra_git_line 4 | grep -qF 'Whether the anchor can move there is unknown, because git did not answer' \
  && ra_git_line 4 | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && [ "$(ra_git_line 5)" = true ] \
  && cmp -s "$(ra_record "$SID_RA_GIT")" "$TMP/reanchor-git-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_GIT")" ] \
  && [ ! -e "$(ra_state "$RA_TREES/spot" "$SID_RA_GIT")" ]; then
  check "a re-anchor refuses as git-unavailable when git is missing, times out or lacks an option, keeps git's own refusal apart, and its directive and moved-chat notices offer a retry" PASS
else
  check "a re-anchor refuses as git-unavailable when git is missing, times out or lacks an option, keeps git's own refusal apart, and its directive and moved-chat notices offer a retry" FAIL
fi

cp "$(ra_record "$SID_RA_WIDE")" "$TMP/reanchor-core-before.json"
RA_CORE_MESSAGES="$(CORE_PATH="$CORE_NATIVE" CONTROL="$(canonical_path "$RA_CONTROL")" SID="$SID_RA_WIDE" PLUGIN="$PLUGIN_NATIVE" \
  WIDE="$(canonical_path "$RA_TREES/wide")" SPOT="$(canonical_path "$RA_TREES/spot")" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const core = require(process.env.CORE_PATH);
    const native = (name) => fs.realpathSync.native(process.env[name]);
    const base = {
      pluginData: native("CONTROL"),
      recordsDir: path.join(native("CONTROL"), "records"),
      host: "codex",
      sessionId: process.env.SID,
      pluginRoot: native("PLUGIN"),
      fromPluginRoot: native("PLUGIN"),
      stamp: "20261102T120000000Z",
    };
    const attempts = [
      { ...base, fromProjectRoot: native("SPOT"), projectRoot: native("SPOT") },
      { ...base, fromProjectRoot: native("WIDE"), projectRoot: native("WIDE") },
      { ...base, fromProjectRoot: native("WIDE"), projectRoot: native("SPOT"), stamp: "now" },
    ];
    process.stdout.write(attempts.map((options) => {
      try {
        core.reanchorContext(options);
        return "moved";
      } catch (error) {
        return error.message;
      }
    }).join("|"));
  ')"
if [ "$RA_CORE_MESSAGES" = "session-control-v1: session context changed before the re-anchor|session-control-v1: re-anchor target is the recorded project root|session-control-v1: superseded record stamp is invalid" ] \
  && cmp -s "$(ra_record "$SID_RA_WIDE")" "$TMP/reanchor-core-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_WIDE")" ]; then
  check "the core re-anchor refuses a stale anchor, an unchanged root and an invalid stamp without touching the record" PASS
else
  check "the core re-anchor refuses a stale anchor, an unchanged root and an invalid stamp without touching the record" FAIL
fi

RA_INSPECT="$TMP/reanchor-inspect"
mkdir -p "$RA_INSPECT/missing" "$RA_INSPECT/unusable" "$RA_INSPECT/present"
RA_CORE_STATE="$(CORE_PATH="$CORE_NATIVE" INSPECT="$(canonical_path "$RA_INSPECT")" node -e '
  const fs = require("node:fs");
  const path = require("node:path");
  const core = require(process.env.CORE_PATH);
  const root = (name) => path.join(fs.realpathSync.native(process.env.INSPECT), name);
  const sessionId = "codex/inspect a workflow state";
  core.initializeWorkflowState({ projectRoot: root("present"), sessionId });
  fs.writeFileSync(path.join(root("unusable"), ".zensu"), "not a directory");
  const states = ["missing", "unusable", "present"].map((name) => core.inspectWorkflowState({ projectRoot: root(name), sessionId }).state);
  const open = {
    ...core.workflowBaseline(), active: true, vanilla: true, implComplete: true, codeReviewDone: true, selfReviewFixed: true,
    workflowActive: true, workflowTools: ["tool"], bypasses: [{ step: "S1" }], reviewRound: 2, stopBlocks: 1,
    phase: "IMPL", step_id: "S1", history: [{ step: "S1", phase: "IMPL" }], revision: 7,
  };
  const discarded = core.discardOpenWork(open);
  const baseline = core.workflowBaseline();
  const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
  const reset = Object.keys(baseline).every((field) => same(discarded[field], core.WORKFLOW_DISCARD_KEEPS.includes(field) ? open[field] : baseline[field]));
  process.stdout.write([
    states.join(","),
    fs.existsSync(path.join(root("missing"), ".zensu")),
    reset,
    discarded.revision,
    core.describeOpenWork(open),
    core.describeOpenWork({ ...baseline, active: true }),
    core.describeOpenWork(discarded) === "",
  ].join("|"));
')"
if [ "$RA_CORE_STATE" = "missing,unusable,present|false|true|7|an open Zensu skill workflow|an armed review chain that has not reached its terminus|true" ]; then
  check "the core inspects a workflow state without creating it and discards open work from its own baseline" PASS
else
  check "the core inspects a workflow state without creating it and discards open work from its own baseline" FAIL
fi

SID_RA_UNBASED="codex/re-bind after the workflow state was removed"
mkdir -p "$TMP/reanchor-unbased"
ra_start "$SID_RA_UNBASED" "$TMP/reanchor-unbased" "$RA_OLD_NATIVE"
rm -rf "$(canonical_path "$TMP/reanchor-unbased")/.zensu"
cp "$(ra_record "$SID_RA_UNBASED")" "$TMP/reanchor-unbased-before.json"
RA_UNBASED_OUT="$(ra_prompt "$SID_RA_UNBASED" "$TMP/reanchor-unbased" 'continue' "$RA_NEW_NATIVE")"
if printf '%s' "$RA_UNBASED_OUT" | grep -qF 'cannot re-bind this chat to the installed Zensu plugin: its workflow state is missing or unreadable' \
  && [ ! -e "$TMP/reanchor-unbased/.zensu" ] \
  && cmp -s "$(ra_record "$SID_RA_UNBASED")" "$TMP/reanchor-unbased-before.json"; then
  check "a re-bind refused for a missing workflow state creates no workflow directory" PASS
else
  check "a re-bind refused for a missing workflow state creates no workflow directory" FAIL
fi

CORE_PATH="$CORE_NATIVE" PROJECT="$(canonical_path "$RA_REPO")" SID="$SID_RA_STOP" node -e '
  const core = require(process.env.CORE_PATH);
  core.mutateWorkflowState({ projectRoot: process.env.PROJECT, sessionId: process.env.SID, workflowState: "active", event: "tdd-begin" },
    (state) => ({ ...state, active: true, implComplete: true }));
'
RA_STOP_MOVED="$(payload Stop "$SID_RA_STOP" "$RA_TREES/spot" | ra_hook "$PLUGIN_NATIVE" stop-chain-enforcer.sh)"
RA_STOP_BLOCKS="$(node -e '
  const state = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(state.stopBlocks || 0));
' "$(ra_state "$RA_REPO" "$SID_RA_STOP")" 2>/dev/null)"
RA_STOP_ANCHORED="$(payload Stop "$SID_RA_STOP" "$RA_REPO" | ra_hook "$PLUGIN_NATIVE" stop-chain-enforcer.sh)"
if [ -z "$RA_STOP_MOVED" ] && [ "$RA_STOP_BLOCKS" = 0 ] \
  && printf '%s' "$RA_STOP_ANCHORED" | grep -qF '"decision":"block"'; then
  check "the Stop enforcer lets a moved chat stop instead of demanding a review it cannot run, and still blocks in the anchored root" PASS
else
  check "the Stop enforcer lets a moved chat stop instead of demanding a review it cannot run, and still blocks in the anchored root" FAIL
fi

RA_STALE="$TMP/reanchor-stale-cache/zensu"
mkdir -p "$RA_STALE/0.7.0" "$RA_STALE/0.7.1"
adopt_install "$RA_STALE/0.7.0" 0.7.0
adopt_install "$RA_STALE/0.7.1" 0.7.1
RA_STALE_NEW_NATIVE="$(canonical_path "$RA_STALE/0.7.1")"
SID_RA_STALE="codex/moved chat whose bound installation was removed"
ra_start "$SID_RA_STALE" "$RA_REPO" "$(canonical_path "$RA_STALE/0.7.0")"
rm -rf "$RA_STALE/0.7.0"
RA_STALE_EDIT="$(PAYLOAD_SESSION="$SID_RA_STALE" PAYLOAD_CWD="$(canonical_path "$RA_TREES/spot")" node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.env.PAYLOAD_SESSION,cwd:process.env.PAYLOAD_CWD,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: src/reanchor.js\n+module.exports = {};\n*** End Patch\n"}}));
' | ra_hook "$RA_STALE_NEW_NATIVE" pre-edit-tdd-reminder.sh)"
RA_STALE_STOP="$(payload Stop "$SID_RA_STALE" "$RA_TREES/spot" | ra_hook "$RA_STALE_NEW_NATIVE" stop-chain-enforcer.sh)"
RA_STALE_OUT="$(ra_prompt "$SID_RA_STALE" "$RA_TREES/spot" 'zensu reanchor' "$RA_STALE_NEW_NATIVE")"
if printf '%s' "$RA_STALE_EDIT" | grep -qF '"permissionDecision":"deny"' \
  && printf '%s' "$RA_STALE_EDIT" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && ! printf '%s' "$RA_STALE_EDIT" | grep -qF 'open /hooks' \
  && printf '%s' "$RA_STALE_STOP" | grep -qF 'by sending the message `zensu reanchor` on its own' \
  && ! printf '%s' "$RA_STALE_STOP" | grep -qF 'open /hooks' \
  && printf '%s' "$RA_STALE_OUT" | grep -qF 'also re-bound the chat from Zensu 0.7.0 to the installed Zensu 0.7.1' \
  && same_canonical_path "$(record_field "$(ra_record "$SID_RA_STALE")" project_root)" "$RA_TREES/spot"; then
  check "with the bound installation removed, the edit gate and the Stop enforcer of a moved chat name the re-anchor message, which then re-anchors and re-binds it" PASS
else
  check "with the bound installation removed, the edit gate and the Stop enforcer of a moved chat name the re-anchor message, which then re-anchors and re-binds it" FAIL
fi

cp "$(ra_record "$SID_RA_FAIL")" "$TMP/reanchor-fail-before.json"
mv "$RA_CONTROL/locks" "$RA_CONTROL/locks.held"
printf 'held' > "$RA_CONTROL/locks"
RA_FAIL_OUT="$(ra_prompt "$SID_RA_FAIL" "$RA_TREES/spot" 'zensu reanchor')"
rm -f "$RA_CONTROL/locks"
mv "$RA_CONTROL/locks.held" "$RA_CONTROL/locks"
if printf '%s' "$RA_FAIL_OUT" | grep -qF 'Zensu Session Control could not re-anchor this chat: ' \
  && printf '%s' "$RA_FAIL_OUT" | grep -qF 'Its Session Control record still names' \
  && cmp -s "$(ra_record "$SID_RA_FAIL")" "$TMP/reanchor-fail-before.json" \
  && [ -z "$(ra_superseded "$SID_RA_FAIL")" ] \
  && [ ! -e "$(ra_state "$RA_TREES/spot" "$SID_RA_FAIL")" ]; then
  check "a re-anchor that fails inside Session Control tells the user, names the unchanged anchor and changes nothing" PASS
else
  check "a re-anchor that fails inside Session Control tells the user, names the unchanged anchor and changes nothing" FAIL
fi

if grep -qF '### Session Control trust boundary' "$ROOT/README.md" \
  && grep -qF 'not a cryptographically signed or broker-owned authority' "$ROOT/README.md" \
  && grep -qF 'same-user time-of-check/time-of-use races' "$ROOT/README.md"; then
  check "documentation states the same-user project-process trust boundary honestly" PASS
else
  check "Session Control trust-boundary documentation is present" FAIL
fi

if HINT_MODULE="$(canonical_path "$PLUGIN/hooks/lib/codex-reanchor-directive-v1.js")" node -e '
  const fs = require("node:fs");
  const { REANCHOR_HINT } = require(process.env.HINT_MODULE);
  const sentence = REANCHOR_HINT.slice(0, REANCHOR_HINT.indexOf(".") + 1);
  const flat = (file) => fs.readFileSync(file, "utf8").replace(/\s+/g, " ");
  process.exit(process.argv.slice(1).every((file) => flat(file).includes(`\`${sentence}\``)) ? 0 : 1);
' "$ROOT/README.md" "$PLUGIN/README.md" && cmp -s "$ROOT/README.md" "$PLUGIN/README.md"; then
  check "both READMEs key their re-anchor troubleshooting on the hint sentence the gates print" PASS
else
  check "both READMEs key their re-anchor troubleshooting on the hint sentence the gates print" FAIL
fi

RA_GRAPH="$(DIRECTIVE="$(canonical_path "$PLUGIN/hooks/lib/codex-reanchor-directive-v1.js")" \
  ADOPT="$(canonical_path "$PLUGIN/hooks/lib/codex-session-adopt-v1.js")" \
  REANCHOR="$(canonical_path "$PLUGIN/hooks/lib/codex-session-reanchor-v1.js")" node -e '
    const path = require("node:path");
    const loaded = () => Object.keys(require.cache).map((file) => path.basename(file)).sort().join(",");
    require(process.env.DIRECTIVE);
    const directive = loaded();
    const adopt = require(process.env.ADOPT);
    const rebind = loaded();
    const reanchor = require(process.env.REANCHOR);
    process.stdout.write([directive, rebind, typeof adopt.reanchorVerdict, typeof reanchor.reanchorVerdict].join("|"));
  ')"
if [ "$RA_GRAPH" = "codex-reanchor-directive-v1.js|codex-reanchor-directive-v1.js,codex-session-adopt-v1.js,session-control-core-v1.js|undefined|function" ]; then
  check "the re-anchor directive loads on its own, and the re-bind never loads the re-anchor" PASS
else
  check "the re-anchor directive loads on its own, and the re-bind never loads the re-anchor" FAIL
fi

RA_SHARED_TEXT="$(ADOPT="$(canonical_path "$PLUGIN/hooks/lib/codex-session-adopt-v1.js")" \
  REANCHOR="$(canonical_path "$PLUGIN/hooks/lib/codex-session-reanchor-v1.js")" node -e '
    const adopt = require(process.env.ADOPT);
    const reanchor = require(process.env.REANCHOR);
    const { RECORD_UNREADABLE, PLUGIN_DATA } = adopt.REFUSALS;
    process.stdout.write([RECORD_UNREADABLE, PLUGIN_DATA].map((reason) => {
      const text = adopt.refusalText({ reason });
      return Boolean(text) && reanchor.reanchorNotice({ reanchored: false, reason })
        .startsWith(`Zensu Session Control did not re-anchor this chat: ${text}. Nothing was changed.`);
    }).join(","));
  ')"
if [ "$RA_SHARED_TEXT" = "true,true" ]; then
  check "a re-anchor refused for an unreadable record or another store states the re-bind reason text" PASS
else
  check "a re-anchor refused for an unreadable record or another store states the re-bind reason text" FAIL
fi

printf '%s\n' "----" "test-session-control-codex: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
