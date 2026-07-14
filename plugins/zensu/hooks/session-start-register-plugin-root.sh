#!/bin/bash
# Register the exact installed Codex plugin root for this SessionStart payload.
# The shell publishes the raw payload as a pending marker before it evaluates
# Node or the mutable bootstrap. The stable reader treats matching (and
# malformed/partial) markers as fail-closed guards, so no early failure can
# resurrect an older ready record.
set -u
set -o pipefail
umask 077

fail_closed() {
  printf '%s\n' "zensu: session plugin-root registration failed before bootstrap: $1" >&2
  exit 0
}

[ -n "${HOME:-}" ] || fail_closed "HOME is unavailable"
case "$HOME" in *[$'\r\n']*) fail_closed "HOME is unsafe" ;; esac

ZENSU_DIR="$HOME/.zensu"
ROOTS_DIR="$ZENSU_DIR/plugin-roots"
REGISTRY_DIR="$ROOTS_DIR/codex"
PENDING_DIR="$REGISTRY_DIR/.pending"
STAGING_DIR="$REGISTRY_DIR/.staging"
for directory in "$ZENSU_DIR" "$ROOTS_DIR" "$REGISTRY_DIR" "$PENDING_DIR" "$STAGING_DIR"; do
  [ ! -L "$directory" ] || fail_closed "registry path is a symlink"
  if [ ! -d "$directory" ]; then
    mkdir "$directory" 2>/dev/null || {
      [ -d "$directory" ] && [ ! -L "$directory" ] || fail_closed "cannot create private registry path"
    }
  fi
  chmod 700 "$directory" 2>/dev/null || fail_closed "cannot protect registry path"
done

ATTEMPT_NONCE_A="$RANDOM"
ATTEMPT_NONCE_B="$RANDOM"
MARKER_NAME="attempt.$$.$ATTEMPT_NONCE_A.$ATTEMPT_NONCE_B.json"
MARKER="$PENDING_DIR/$MARKER_NAME"
STAGING_NAME="payload.$$.$ATTEMPT_NONCE_A.$ATTEMPT_NONCE_B.json"
PROVISIONAL="$STAGING_DIR/provisional.$$.$ATTEMPT_NONCE_A.$ATTEMPT_NONCE_B.$RANDOM.tmp"
RAW_STAGE="$STAGING_DIR/$STAGING_NAME"
cleanup_staging() {
  rm -f "$PROVISIONAL" "$RAW_STAGE" 2>/dev/null || true
}
trap cleanup_staging EXIT

# Publish a complete provisional record atomically before reading stdin. A
# crash during payload capture therefore leaves a bounded, owner-identifiable
# fail-closed marker rather than a zero-byte global poison pill.
printf '{"schemaVersion":1,"state":"capturing","ownerPid":%s,"stagingName":"%s","createdAt":"%s"}\n' \
  "$$" "$STAGING_NAME" "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)" > "$PROVISIONAL" 2>/dev/null || \
  fail_closed "cannot stage pending marker"
chmod 600 "$PROVISIONAL" 2>/dev/null || fail_closed "cannot protect pending marker"
mv "$PROVISIONAL" "$MARKER" 2>/dev/null || fail_closed "cannot publish pending marker"

if [ "${NODE_ENV:-}" = "test" ] && [ -n "${ZENSU_CODEX_SHELL_TEST_BARRIER_DIR:-}" ]; then
  printf 'reached\n' > "$ZENSU_CODEX_SHELL_TEST_BARRIER_DIR/pending-provisional.reached" 2>/dev/null || \
    fail_closed "cannot publish pending-marker test barrier"
  while [ ! -e "$ZENSU_CODEX_SHELL_TEST_BARRIER_DIR/pending-provisional.release" ]; do sleep 0.02; done
fi

cat > "$RAW_STAGE" 2>/dev/null || fail_closed "cannot capture SessionStart payload"
chmod 600 "$RAW_STAGE" 2>/dev/null || fail_closed "cannot protect SessionStart payload"

if [ "${NODE_ENV:-}" = "test" ] && [ -n "${ZENSU_CODEX_SHELL_PAYLOAD_TEST_BARRIER_DIR:-}" ]; then
  printf 'reached\n' > "$ZENSU_CODEX_SHELL_PAYLOAD_TEST_BARRIER_DIR/pending-payload-staged.reached" 2>/dev/null || \
    fail_closed "cannot publish staged-payload test barrier"
  while [ ! -e "$ZENSU_CODEX_SHELL_PAYLOAD_TEST_BARRIER_DIR/pending-payload-staged.release" ]; do sleep 0.02; done
fi

mv "$RAW_STAGE" "$MARKER" 2>/dev/null || fail_closed "cannot publish SessionStart payload"

# The executable location is authoritative. Ambient host variables are passed
# through only so the Node registrar can require canonical agreement; they can
# never redirect this bootstrap to code from another directory.
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || {
  fail_closed "plugin installation is unavailable"
}
BOOTSTRAP="$SCRIPT_ROOT/hooks/lib/codex-plugin-root-bootstrap.js"

if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'zensu: node is required for fail-closed session plugin-root registration' >&2
  exit 0
fi

if ! ZENSU_CODEX_PENDING_MARKER="$MARKER" ZENSU_CODEX_PENDING_OWNER_PID="$$" \
  node "$BOOTSTRAP" < "$MARKER"; then
  printf '%s\n' 'zensu: session plugin-root registration failed; model-side helper resolution will fail closed' >&2
fi
exit 0
