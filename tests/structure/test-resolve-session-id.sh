#!/bin/bash
set -u

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP  test-resolve-session-id on Windows — POSIX-path harness mangled by MSYS; native-path coverage elsewhere"
    exit 0 ;;
esac

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/resolve-session-id.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "hooks/lib/resolve-session-id.js exists" FAIL
  echo "----"
  echo "test-resolve-session-id: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S0 hooks/lib/resolve-session-id.js exists" PASS

TMP_ROOT="$(mktemp -d -t "resolve-sid-XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

mk_projects_dir() {
  local proj="$1"
  local sanitized
  sanitized="$(printf '%s' "$proj" | tr '/\\:.' '-')"
  local pdir="$TMP_ROOT/projects/$sanitized"
  mkdir -p "$pdir"
  echo "$pdir"
}

S1_PROJECT="/users/s1/repo"
S1_PDIR="$(mk_projects_dir "$S1_PROJECT")"
S1_UUID="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
: > "$S1_PDIR/$S1_UUID.jsonl"

S1_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S1_PROJECT" node "$HELPER")"
if [ "$S1_OUT" = "$S1_UUID" ]; then
  check "S1 single .jsonl returns its UUID" PASS
else
  check "S1 single .jsonl returns its UUID (got '$S1_OUT')" FAIL
fi

S2_PROJECT="/users/s2/repo"
S2_PDIR="$(mk_projects_dir "$S2_PROJECT")"
S2_UUID_OLD="bbbbbbbb-1111-old0-0000-bbbbbbbbbbbb"
S2_UUID_MID="bbbbbbbb-1111-mid0-0000-bbbbbbbbbbbb"
S2_UUID_NEW="zzzzzzzz-1111-new0-0000-bbbbbbbbbbbb"
: > "$S2_PDIR/$S2_UUID_OLD.jsonl"
: > "$S2_PDIR/$S2_UUID_MID.jsonl"
: > "$S2_PDIR/$S2_UUID_NEW.jsonl"

S2_NOW=$(date +%s)
S2_OLD_T=$((S2_NOW - 100))
S2_MID_T=$((S2_NOW - 50))
S2_NEW_T=$((S2_NOW - 1))
touch -t "$(date -r "$S2_OLD_T" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$S2_OLD_T" +%Y%m%d%H%M.%S)" "$S2_PDIR/$S2_UUID_OLD.jsonl"
touch -t "$(date -r "$S2_MID_T" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$S2_MID_T" +%Y%m%d%H%M.%S)" "$S2_PDIR/$S2_UUID_MID.jsonl"
touch -t "$(date -r "$S2_NEW_T" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$S2_NEW_T" +%Y%m%d%H%M.%S)" "$S2_PDIR/$S2_UUID_NEW.jsonl"

S2_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S2_PROJECT" node "$HELPER")"
if [ "$S2_OUT" = "$S2_UUID_NEW" ]; then
  check "S2 multiple .jsonl returns newest by mtime" PASS
else
  check "S2 multiple .jsonl returns newest by mtime (got '$S2_OUT' expected '$S2_UUID_NEW')" FAIL
fi

S3_PROJECT="/users/s3/repo"
S3_PDIR="$(mk_projects_dir "$S3_PROJECT")"
S3_UUID_A="cccccccc-aaaa-aaaa-aaaa-cccccccccccc"
S3_UUID_B="cccccccc-bbbb-bbbb-bbbb-cccccccccccc"
S3_UUID_C="cccccccc-cccc-cccc-cccc-cccccccccccc"
: > "$S3_PDIR/$S3_UUID_A.jsonl"
: > "$S3_PDIR/$S3_UUID_B.jsonl"
: > "$S3_PDIR/$S3_UUID_C.jsonl"

S3_BASH_START_NS="$(S3_PDIR_ARG="$S3_PDIR" S3_A="$S3_UUID_A" S3_B="$S3_UUID_B" S3_C="$S3_UUID_C" node -e '
  const fs = require("fs");
  const path = require("path");
  const d = process.env.S3_PDIR_ARG;
  const nowMs = Date.now();
  const aMs = nowMs - 1000;
  const bMs = nowMs - 500;
  const cMs = nowMs;
  const cutoffMs = nowMs - 600;
  fs.utimesSync(path.join(d, process.env.S3_A + ".jsonl"), aMs / 1000, aMs / 1000);
  fs.utimesSync(path.join(d, process.env.S3_B + ".jsonl"), bMs / 1000, bMs / 1000);
  fs.utimesSync(path.join(d, process.env.S3_C + ".jsonl"), cMs / 1000, cMs / 1000);
  process.stdout.write(String(BigInt(cutoffMs) * 1000000n));
')"

S3_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S3_PROJECT" node "$HELPER" "$S3_BASH_START_NS")"
if [ "$S3_OUT" = "$S3_UUID_A" ]; then
  check "S3 BASH_START filters out files written after cutoff, newest <=cutoff wins" PASS
else
  check "S3 BASH_START cutoff (got '$S3_OUT' expected '$S3_UUID_A')" FAIL
fi

S4_PROJECT="/users/s4/repo"
S4_PDIR="$(mk_projects_dir "$S4_PROJECT")"
S4_UUID_A="dddddddd-aaaa-aaaa-aaaa-dddddddddddd"
S4_UUID_B="dddddddd-bbbb-bbbb-bbbb-dddddddddddd"
S4_OWN_CMD="bash zensu-log.sh --phase RED_WRITE --step S4-unique-marker"
printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"echo unrelated"}}' > "$S4_PDIR/$S4_UUID_A.jsonl"
printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"'"$S4_OWN_CMD"'"}}' > "$S4_PDIR/$S4_UUID_B.jsonl"

S4_BASH_START_NS="$(S4_PDIR_ARG="$S4_PDIR" S4_A="$S4_UUID_A" S4_B="$S4_UUID_B" node -e '
  const fs = require("fs");
  const path = require("path");
  const d = process.env.S4_PDIR_ARG;
  const nowMs = Date.now();
  const aMs = nowMs - 500;
  const bMs = nowMs - 1000;
  const cutoffMs = nowMs;
  fs.utimesSync(path.join(d, process.env.S4_A + ".jsonl"), aMs / 1000, aMs / 1000);
  fs.utimesSync(path.join(d, process.env.S4_B + ".jsonl"), bMs / 1000, bMs / 1000);
  process.stdout.write(String(BigInt(cutoffMs) * 1000000n));
')"

S4_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S4_PROJECT" ZENSU_OWN_CMD="$S4_OWN_CMD" node "$HELPER" "$S4_BASH_START_NS")"
if [ "$S4_OUT" = "$S4_UUID_B" ]; then
  check "S4 ZENSU_OWN_CMD tail-match disambiguates and wins over newest mtime" PASS
else
  check "S4 cmdline tail-match (got '$S4_OUT' expected '$S4_UUID_B')" FAIL
fi

S5_PROJECT="/users/s5/repo"
S5_PDIR="$(mk_projects_dir "$S5_PROJECT")"
S5_OUT_FILE="$TMP_ROOT/s5.stdout"
S5_EXIT_FILE="$TMP_ROOT/s5.exit"
ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S5_PROJECT" node "$HELPER" > "$S5_OUT_FILE" 2>/dev/null
echo "$?" > "$S5_EXIT_FILE"
S5_OUT="$(cat "$S5_OUT_FILE")"
S5_EXIT="$(cat "$S5_EXIT_FILE")"
if [ -z "$S5_OUT" ] && [ "$S5_EXIT" = "0" ]; then
  check "S5 empty projects dir -> empty stdout + exit 0" PASS
else
  check "S5 empty projects dir (out='$S5_OUT' exit='$S5_EXIT')" FAIL
fi

S6_OUT_FILE="$TMP_ROOT/s6.stdout"
S6_EXIT_FILE="$TMP_ROOT/s6.exit"
ZENSU_PROJECTS_DIR="$TMP_ROOT/does-not-exist-anywhere" CLAUDE_PROJECT_DIR="/users/s6/repo" node "$HELPER" > "$S6_OUT_FILE" 2>/dev/null
echo "$?" > "$S6_EXIT_FILE"
S6_OUT="$(cat "$S6_OUT_FILE")"
S6_EXIT="$(cat "$S6_EXIT_FILE")"
if [ -z "$S6_OUT" ] && [ "$S6_EXIT" = "0" ]; then
  check "S6 missing projects dir -> empty stdout + exit 0 (no crash)" PASS
else
  check "S6 missing projects dir (out='$S6_OUT' exit='$S6_EXIT')" FAIL
fi

S7_NESTED_PROJECT="/Users/foo/repo"
S7_SANITIZED="-Users-foo-repo"
S7_PDIR_S="$TMP_ROOT/projects/$S7_SANITIZED"
mkdir -p "$S7_PDIR_S"
S7_UUID="eeeeeeee-1111-2222-3333-eeeeeeeeeeee"
: > "$S7_PDIR_S/$S7_UUID.jsonl"

S7_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S7_NESTED_PROJECT" node "$HELPER")"
if [ "$S7_OUT" = "$S7_UUID" ]; then
  check "S7 CLAUDE_PROJECT_DIR=/Users/foo/repo sanitized to -Users-foo-repo for projects subdir lookup" PASS
else
  check "S7 nested-path sanitization (got '$S7_OUT' expected '$S7_UUID')" FAIL
fi

S7B_PROJECT="/Users/foo/dev.zensu/.claude/worktrees/x"
S7B_SANITIZED="-Users-foo-dev-zensu--claude-worktrees-x"
S7B_PDIR_S="$TMP_ROOT/projects/$S7B_SANITIZED"
mkdir -p "$S7B_PDIR_S"
S7B_UUID="eeeeeeee-dddd-dddd-dddd-eeeeeeeeeeee"
: > "$S7B_PDIR_S/$S7B_UUID.jsonl"

S7B_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S7B_PROJECT" node "$HELPER")"
if [ "$S7B_OUT" = "$S7B_UUID" ]; then
  check "S7B dotted path /Users/foo/dev.zensu/.claude/worktrees/x sanitizes dots to dashes" PASS
else
  check "S7B dotted-path sanitization (got '$S7B_OUT' expected '$S7B_UUID')" FAIL
fi

S8_PROJECT="/users/s8/repo"
S8_PDIR="$(mk_projects_dir "$S8_PROJECT")"
S8_UUID_OLDER="88888888-aaaa-aaaa-aaaa-888888888888"
S8_UUID_FUTURE="88888888-ffff-ffff-ffff-888888888888"
: > "$S8_PDIR/$S8_UUID_OLDER.jsonl"
: > "$S8_PDIR/$S8_UUID_FUTURE.jsonl"
S8_OLDER_FULL_E="$S8_PDIR/$S8_UUID_OLDER.jsonl" S8_FUTURE_FULL_E="$S8_PDIR/$S8_UUID_FUTURE.jsonl" node -e '
  const fs = require("fs");
  const nowMs = Date.now();
  const olderMs = nowMs - 60000;
  const futureMs = nowMs + 60000;
  fs.utimesSync(process.env.S8_OLDER_FULL_E, olderMs/1000, olderMs/1000);
  fs.utimesSync(process.env.S8_FUTURE_FULL_E, futureMs/1000, futureMs/1000);
'

S8_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S8_PROJECT" node "$HELPER")"
if [ "$S8_OUT" = "$S8_UUID_OLDER" ]; then
  check "S8 helper self-initializes Date.now() cutoff when argv[2] missing (excludes future-mtime sibling)" PASS
else
  check "S8 helper self-init (got '$S8_OUT' expected '$S8_UUID_OLDER' — future-mtime sibling not filtered, Layer-1 skipped)" FAIL
fi

S8B_PROJECT="/users/s8b/repo"
S8B_PDIR="$(mk_projects_dir "$S8B_PROJECT")"
S8B_UUID_OLDER="88888888-bbbb-bbbb-bbbb-888888888888"
S8B_UUID_FUTURE="88888888-cccc-cccc-cccc-888888888888"
: > "$S8B_PDIR/$S8B_UUID_OLDER.jsonl"
: > "$S8B_PDIR/$S8B_UUID_FUTURE.jsonl"
S8B_OLDER_FULL_E="$S8B_PDIR/$S8B_UUID_OLDER.jsonl" S8B_FUTURE_FULL_E="$S8B_PDIR/$S8B_UUID_FUTURE.jsonl" node -e '
  const fs = require("fs");
  const nowMs = Date.now();
  const olderMs = nowMs - 60000;
  const futureMs = nowMs + 60000;
  fs.utimesSync(process.env.S8B_OLDER_FULL_E, olderMs/1000, olderMs/1000);
  fs.utimesSync(process.env.S8B_FUTURE_FULL_E, futureMs/1000, futureMs/1000);
'

S8B_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$S8B_PROJECT" node "$HELPER" "1779715299N")"
if [ "$S8B_OUT" = "$S8B_UUID_OLDER" ]; then
  check "S8B helper self-initializes when argv[2] is non-numeric garbage (e.g. unexpanded %N output)" PASS
else
  check "S8B helper invalid-arg self-init (got '$S8B_OUT' expected '$S8B_UUID_OLDER')" FAIL
fi

W1_PROJECT="/users/w1/repo"
W1_PDIR="$(mk_projects_dir "$W1_PROJECT")"
W1_UUID="ffffffff-1111-2222-3333-ffffffffffff"
: > "$W1_PDIR/$W1_UUID.jsonl"

SESSION_HELPER="$PLUGIN_DIR/hooks/lib/zensu-session.sh"
W1_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$W1_PROJECT" bash -c "source '$SESSION_HELPER'; zensu_resolve_session_id ''")"
if [ "$W1_OUT" = "$W1_UUID" ]; then
  check "W1 zensu_resolve_session_id wires helper below the current-session pointer (returns UUID, not fallback)" PASS
else
  check "W1 wired resolver (got '$W1_OUT' expected '$W1_UUID')" FAIL
fi

W2_PROJECT="$TMP_ROOT/w2-proj"
mkdir -p "$W2_PROJECT/.zensu/state"
W2_PDIR_S="$(printf '%s' "$W2_PROJECT" | tr '/\\:.' '-')"
W2_PDIR="$TMP_ROOT/projects/$W2_PDIR_S"
mkdir -p "$W2_PDIR"
W2_UUID="99999999-1111-2222-3333-999999999999"
: > "$W2_PDIR/$W2_UUID.jsonl"

unset CLAUDE_SESSION_ID
ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PROJECT_DIR="$W2_PROJECT" \
  bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --phase IMPL --step W2-demo >/dev/null 2>&1

if [ -f "$W2_PROJECT/.zensu/state/tdd-phase-${W2_UUID}.json" ]; then
  check "W2 zensu-log.sh --phase exports ZENSU_BASH_START + ZENSU_OWN_CMD so helper resolves to UUID" PASS
else
  ACTUAL_FILES="$(ls "$W2_PROJECT/.zensu/state/" 2>/dev/null | tr '\n' ' ')"
  check "W2 helper-routed phase write (expected tdd-phase-${W2_UUID}.json, got: $ACTUAL_FILES)" FAIL
fi

W2B_PROJECT="$TMP_ROOT/w2b-proj"
mkdir -p "$W2B_PROJECT/.zensu/state"
W2B_PDIR_S="$(printf '%s' "$W2B_PROJECT" | tr '/\\:.' '-')"
W2B_PDIR="$TMP_ROOT/projects/$W2B_PDIR_S"
mkdir -p "$W2B_PDIR"
W2B_UUID_OLDER="88888888-aaaa-aaaa-aaaa-888888888888"
W2B_UUID_NEWER="88888888-bbbb-bbbb-bbbb-888888888888"
: > "$W2B_PDIR/$W2B_UUID_OLDER.jsonl"
: > "$W2B_PDIR/$W2B_UUID_NEWER.jsonl"
W2B_NOW_MS=$(node -e 'process.stdout.write(String(Date.now()))')
W2B_OLDER_MS=$((W2B_NOW_MS - 2000))
W2B_NEWER_MS=$((W2B_NOW_MS - 100))
W2B_CUTOFF_MS=$((W2B_NOW_MS - 500))
W2B_OLDER_FULL="$W2B_PDIR/$W2B_UUID_OLDER.jsonl"
W2B_NEWER_FULL="$W2B_PDIR/$W2B_UUID_NEWER.jsonl"
W2B_OLDER_FULL_ESC="$W2B_OLDER_FULL" W2B_NEWER_FULL_ESC="$W2B_NEWER_FULL" W2B_OLDER_MS_E="$W2B_OLDER_MS" W2B_NEWER_MS_E="$W2B_NEWER_MS" node -e '
  const fs = require("fs");
  fs.utimesSync(process.env.W2B_OLDER_FULL_ESC, Number(process.env.W2B_OLDER_MS_E)/1000, Number(process.env.W2B_OLDER_MS_E)/1000);
  fs.utimesSync(process.env.W2B_NEWER_FULL_ESC, Number(process.env.W2B_NEWER_MS_E)/1000, Number(process.env.W2B_NEWER_MS_E)/1000);
'

unset CLAUDE_SESSION_ID
ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PROJECT_DIR="$W2B_PROJECT" \
  ZENSU_BASH_START="${W2B_CUTOFF_MS}000000" \
  bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --phase IMPL --step W2B-demo >/dev/null 2>&1

if [ -f "$W2B_PROJECT/.zensu/state/tdd-phase-${W2B_UUID_OLDER}.json" ]; then
  check "W2B zensu-log.sh respects pre-set ZENSU_BASH_START -> writes phase to older-than-cutoff session id" PASS
elif [ -f "$W2B_PROJECT/.zensu/state/tdd-phase-${W2B_UUID_NEWER}.json" ]; then
  check "W2B ZENSU_BASH_START ignored — picked newer sibling ($W2B_UUID_NEWER) instead of older ($W2B_UUID_OLDER)" FAIL
else
  ACTUAL_FILES_2="$(ls "$W2B_PROJECT/.zensu/state/" 2>/dev/null | tr '\n' ' ')"
  check "W2B ZENSU_BASH_START routing (no expected file, got: $ACTUAL_FILES_2)" FAIL
fi

W2C_PROJECT="$TMP_ROOT/w2c-proj"
mkdir -p "$W2C_PROJECT/.zensu/state"
W2C_PDIR_S="$(printf '%s' "$W2C_PROJECT" | tr '/\\:.' '-')"
W2C_PDIR="$TMP_ROOT/projects/$W2C_PDIR_S"
mkdir -p "$W2C_PDIR"
W2C_UUID_OLDER="77777777-aaaa-aaaa-aaaa-777777777777"
W2C_UUID_FUTURE="77777777-bbbb-bbbb-bbbb-777777777777"
: > "$W2C_PDIR/$W2C_UUID_OLDER.jsonl"
: > "$W2C_PDIR/$W2C_UUID_FUTURE.jsonl"

W2C_NOW_MS=$(node -e 'process.stdout.write(String(Date.now()))')
W2C_OLDER_MS=$((W2C_NOW_MS - 60000))
W2C_FUTURE_MS=$((W2C_NOW_MS + 60000))
W2C_OLDER_FULL_E="$W2C_PDIR/$W2C_UUID_OLDER.jsonl" W2C_FUTURE_FULL_E="$W2C_PDIR/$W2C_UUID_FUTURE.jsonl" W2C_OLDER_MS_E="$W2C_OLDER_MS" W2C_FUTURE_MS_E="$W2C_FUTURE_MS" node -e '
  const fs = require("fs");
  fs.utimesSync(process.env.W2C_OLDER_FULL_E, Number(process.env.W2C_OLDER_MS_E)/1000, Number(process.env.W2C_OLDER_MS_E)/1000);
  fs.utimesSync(process.env.W2C_FUTURE_FULL_E, Number(process.env.W2C_FUTURE_MS_E)/1000, Number(process.env.W2C_FUTURE_MS_E)/1000);
'

env -i PATH="$PATH" \
  ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" \
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PROJECT_DIR="$W2C_PROJECT" \
  bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --phase IMPL --step W2C-demo >/dev/null 2>&1

if [ -f "$W2C_PROJECT/.zensu/state/tdd-phase-${W2C_UUID_OLDER}.json" ]; then
  check "W2C zensu-log.sh self-initializes ZENSU_BASH_START when unset (excludes future-mtime sibling)" PASS
elif [ -f "$W2C_PROJECT/.zensu/state/tdd-phase-${W2C_UUID_FUTURE}.json" ]; then
  check "W2C self-init missing — picked future-mtime sibling ($W2C_UUID_FUTURE) — ZENSU_BASH_START not initialized at script entry" FAIL
else
  ACTUAL_FILES_3="$(ls "$W2C_PROJECT/.zensu/state/" 2>/dev/null | tr '\n' ' ')"
  check "W2C self-init (no expected file, got: $ACTUAL_FILES_3)" FAIL
fi

F1_SPACE_PROJECT="/users/spaces are/repo"
F1_SPACE_SUBDIR="-users-spaces-are-repo"
F1_SPACE_PDIR="$TMP_ROOT/projects/$F1_SPACE_SUBDIR"
mkdir -p "$F1_SPACE_PDIR"
F1_SPACE_UUID="11111111-aaaa-bbbb-cccc-111111111111"
: > "$F1_SPACE_PDIR/$F1_SPACE_UUID.jsonl"
F1_SPACE_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F1_SPACE_PROJECT" node "$HELPER")"
if [ "$F1_SPACE_OUT" = "$F1_SPACE_UUID" ]; then
  check "F1-R-space CLAUDE_PROJECT_DIR with space sanitizes via allowlist -> finds subdir" PASS
else
  check "F1-R-space CLAUDE_PROJECT_DIR with space (got '$F1_SPACE_OUT' expected '$F1_SPACE_UUID')" FAIL
fi

F1_TILDE_PROJECT="/users/~home/repo"
F1_TILDE_SUBDIR="-users--home-repo"
F1_TILDE_PDIR="$TMP_ROOT/projects/$F1_TILDE_SUBDIR"
mkdir -p "$F1_TILDE_PDIR"
F1_TILDE_UUID="22222222-aaaa-bbbb-cccc-222222222222"
: > "$F1_TILDE_PDIR/$F1_TILDE_UUID.jsonl"
F1_TILDE_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F1_TILDE_PROJECT" node "$HELPER")"
if [ "$F1_TILDE_OUT" = "$F1_TILDE_UUID" ]; then
  check "F1-R-tilde CLAUDE_PROJECT_DIR with ~ sanitizes via allowlist -> finds subdir" PASS
else
  check "F1-R-tilde CLAUDE_PROJECT_DIR with ~ (got '$F1_TILDE_OUT' expected '$F1_TILDE_UUID')" FAIL
fi

F1_HASH_PROJECT="/users/#dev/repo"
F1_HASH_SUBDIR="-users--dev-repo"
F1_HASH_PDIR="$TMP_ROOT/projects/$F1_HASH_SUBDIR"
mkdir -p "$F1_HASH_PDIR"
F1_HASH_UUID="33333333-aaaa-bbbb-cccc-333333333333"
: > "$F1_HASH_PDIR/$F1_HASH_UUID.jsonl"
F1_HASH_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F1_HASH_PROJECT" node "$HELPER")"
if [ "$F1_HASH_OUT" = "$F1_HASH_UUID" ]; then
  check "F1-R-hash CLAUDE_PROJECT_DIR with # sanitizes via allowlist -> finds subdir" PASS
else
  check "F1-R-hash CLAUDE_PROJECT_DIR with # (got '$F1_HASH_OUT' expected '$F1_HASH_UUID')" FAIL
fi

F1_PAREN_PROJECT="/users/(branch)/repo"
F1_PAREN_SUBDIR="-users--branch--repo"
F1_PAREN_PDIR="$TMP_ROOT/projects/$F1_PAREN_SUBDIR"
mkdir -p "$F1_PAREN_PDIR"
F1_PAREN_UUID="44444444-aaaa-bbbb-cccc-444444444444"
: > "$F1_PAREN_PDIR/$F1_PAREN_UUID.jsonl"
F1_PAREN_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F1_PAREN_PROJECT" node "$HELPER")"
if [ "$F1_PAREN_OUT" = "$F1_PAREN_UUID" ]; then
  check "F1-R-paren CLAUDE_PROJECT_DIR with () sanitizes via allowlist -> finds subdir" PASS
else
  check "F1-R-paren CLAUDE_PROJECT_DIR with () (got '$F1_PAREN_OUT' expected '$F1_PAREN_UUID')" FAIL
fi

F1_SMOKE_PROJECT="/Users/foo/IdeaProjects/dev.zensu/zensu-codex/.claude/worktrees/thirsty-elbakyan-eaba92"
F1_SMOKE_SUBDIR="-Users-foo-IdeaProjects-dev-zensu-zensu-codex--claude-worktrees-thirsty-elbakyan-eaba92"
F1_SMOKE_PDIR="$TMP_ROOT/projects/$F1_SMOKE_SUBDIR"
mkdir -p "$F1_SMOKE_PDIR"
F1_SMOKE_UUID="a01473c3-c9cb-45ed-8d12-e00a548866ca"
: > "$F1_SMOKE_PDIR/$F1_SMOKE_UUID.jsonl"
F1_SMOKE_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F1_SMOKE_PROJECT" node "$HELPER")"
if [ "$F1_SMOKE_OUT" = "$F1_SMOKE_UUID" ]; then
  check "F1-R-smoke current worktree CWD sanitizes to known subdir under allowlist (regression lock)" PASS
else
  check "F1-R-smoke current worktree subdir (got '$F1_SMOKE_OUT' expected '$F1_SMOKE_UUID')" FAIL
fi

F2_PROJECT="/users/f2/repo"
F2_PDIR="$(mk_projects_dir "$F2_PROJECT")"
F2_UUID_NEEDLE="ffffffff-aaaa-aaaa-aaaa-ffff00000001"
F2_UUID_NOISE="ffffffff-bbbb-bbbb-bbbb-ffff00000002"
F2_OWN_CMD="bash zensu-log.sh --phase RED_WRITE --step F2-unique-needle-AB12"
printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"'"$F2_OWN_CMD"'"}}' > "$F2_PDIR/$F2_UUID_NEEDLE.jsonl"
printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"echo unrelated noise"}}' > "$F2_PDIR/$F2_UUID_NOISE.jsonl"

F2_BASH_START_NS="$(F2_PDIR_ARG="$F2_PDIR" F2_NEEDLE="$F2_UUID_NEEDLE" F2_NOISE="$F2_UUID_NOISE" node -e '
  const fs = require("fs");
  const path = require("path");
  const d = process.env.F2_PDIR_ARG;
  const nowMs = Date.now();
  const needleMs = nowMs - 30;
  const noiseMs = nowMs - 10;
  const cutoffMs = nowMs + 50;
  fs.utimesSync(path.join(d, process.env.F2_NEEDLE + ".jsonl"), needleMs / 1000, needleMs / 1000);
  fs.utimesSync(path.join(d, process.env.F2_NOISE + ".jsonl"), noiseMs / 1000, noiseMs / 1000);
  process.stdout.write(String(BigInt(cutoffMs) * 1000000n));
')"

F2_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F2_PROJECT" ZENSU_OWN_CMD="$F2_OWN_CMD" node "$HELPER" "$F2_BASH_START_NS")"
if [ "$F2_OUT" = "$F2_UUID_NEEDLE" ]; then
  check "F2-R Layer-2 cmdline tail-match disambiguates two candidates both inside Layer-1 cutoff window (regression for design rationale)" PASS
else
  check "F2-R Layer-2 tail-match in widened cutoff window (got '$F2_OUT' expected '$F2_UUID_NEEDLE')" FAIL
fi

F3_PROJECT="/users/f3/repo"
F3_PDIR="$(mk_projects_dir "$F3_PROJECT")"
F3_UUID_OLDER="33333333-1111-2222-3333-333300000001"
F3_UUID_NEWER="33333333-1111-2222-3333-333300000002"
: > "$F3_PDIR/$F3_UUID_OLDER.jsonl"
: > "$F3_PDIR/$F3_UUID_NEWER.jsonl"
F3_OLDER_FULL_E="$F3_PDIR/$F3_UUID_OLDER.jsonl" F3_NEWER_FULL_E="$F3_PDIR/$F3_UUID_NEWER.jsonl" node -e '
  const fs = require("fs");
  const nowMs = Date.now();
  const olderMs = nowMs - 60000;
  const newerMs = nowMs - 30000;
  fs.utimesSync(process.env.F3_OLDER_FULL_E, olderMs/1000, olderMs/1000);
  fs.utimesSync(process.env.F3_NEWER_FULL_E, newerMs/1000, newerMs/1000);
'

F3_OUT="$(ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" CLAUDE_PROJECT_DIR="$F3_PROJECT" node "$HELPER" "1779715299000")"
if [ "$F3_OUT" = "$F3_UUID_NEWER" ]; then
  check "F3-R 13-digit ms-style argv[2] is rejected by length guard -> helper self-inits Date.now() -> newest valid sibling wins" PASS
else
  check "F3-R 13-digit ms-style argv[2] (got '$F3_OUT' expected '$F3_UUID_NEWER' — empty means silent filter-all, OLDER means newest-mtime-after-bad-cutoff misordered)" FAIL
fi

# G1 — CLAUDE_PROJECT_DIR unset -> git toplevel anchors the projects subdir,
# so resolution holds even when the helper runs from a nested subdirectory.
if command -v git >/dev/null 2>&1; then
  G1_WORK="$TMP_ROOT/gitwork"
  mkdir -p "$G1_WORK/sub/nested"
  ( cd "$G1_WORK" && git init -q >/dev/null 2>&1 )
  G1_TOP="$(cd "$G1_WORK/sub/nested" && git rev-parse --show-toplevel 2>/dev/null)"
  G1_SUBDIR="$(node -e 'process.stdout.write(String(process.argv[1]).replace(/[^A-Za-z0-9_-]/g,"-"))' "$G1_TOP")"
  G1_PDIR="$TMP_ROOT/projects/$G1_SUBDIR"
  mkdir -p "$G1_PDIR"
  G1_UUID="9a9a9a9a-1111-2222-3333-9a9a9a9a9a9a"
  : > "$G1_PDIR/$G1_UUID.jsonl"
  G1_OUT="$(cd "$G1_WORK/sub/nested" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$TMP_ROOT/projects" node "$HELPER")"
  if [ "$G1_OUT" = "$G1_UUID" ]; then
    check "G1 CLAUDE_PROJECT_DIR unset -> git toplevel anchors projects subdir (resolves from nested subdir)" PASS
  else
    check "G1 git-toplevel anchor (got '$G1_OUT' expected '$G1_UUID')" FAIL
  fi
else
  check "G1 git-toplevel anchor SKIPPED (git absent)" PASS
fi

# G2 — gitToplevel must bound the git call (timeout + maxBuffer) so a stalled/hostile
# cwd (e.g. git on a hung network FS) cannot hang the synchronous hook indefinitely.
if grep -Eq "timeout:[[:space:]]*[0-9]+" "$HELPER" && grep -Eq "maxBuffer" "$HELPER"; then
  check "G2 gitToplevel execFileSync bounds the git call (timeout + maxBuffer)" PASS
else
  check "G2 gitToplevel git call is unbounded (missing timeout/maxBuffer)" FAIL
fi

echo "----"
echo "test-resolve-session-id: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
