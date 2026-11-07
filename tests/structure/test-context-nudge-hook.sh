#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PLUGIN="$ROOT/plugins/zensu"
HOOK="$PLUGIN/hooks/user-prompt-context-nudge.sh"
CORE="$PLUGIN/hooks/lib/session-control-core-v1.js"
PROBE="$ROOT/tests/fixtures/workflow-state-access-probe.js"
VERDICT="$ROOT/tests/fixtures/workflow-state-access-verdict.js"

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
expect() {
  if [ "$2" = "$3" ]; then check "$1" PASS; else check "$1 (expected '$3', got '$2')" FAIL; fi
}

for artifact in "$HOOK" "$CORE" "$PROBE" "$VERDICT"; do
  if [ -f "$artifact" ]; then check "artifact exists: ${artifact#$ROOT/}" PASS
  else check "artifact exists: ${artifact#$ROOT/}" FAIL; fi
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-context-nudge-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi
if grep -q 'mkdir' "$HOOK"; then
  check "the nudge creates no directory itself" FAIL
else
  check "the nudge creates no directory itself" PASS
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export ZENSU_CONFIG="$TMP/config.json"
unset CLAUDE_PROJECT_DIR
mkdir -p "$HOME"
printf '{"context":{"windowSize":100000}}\n' > "$ZENSU_CONFIG"

project() {
  mkdir -p "$TMP/$1"
  (cd "$TMP/$1" && pwd -P)
}

band_file() {
  printf '%s/.zensu/state/context-nudge-%s.txt' "$1" "$(node "$CORE" session-key "$2")"
}

nudge() {
  local dir="$1" sid="$2" tokens="$3"
  printf '{"message":{"usage":{"input_tokens":%s}}}\n' "$tokens" > "$TMP/transcript-$sid.jsonl"
  SID="$sid" PROJECT_DIR="$dir" TRANSCRIPT="$TMP/transcript-$sid.jsonl" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "UserPromptSubmit",
      session_id: process.env.SID,
      cwd: process.env.PROJECT_DIR,
      transcript_path: process.env.TRANSCRIPT,
      prompt: "next",
    }));
  ' | "${@:4}" bash "$HOOK" 2>"$TMP/hook.err"
}

percent_of() {
  node -e '
    const text = require("fs").readFileSync(0, "utf8").trim();
    if (!text) { process.stdout.write("silent"); process.exit(0); }
    const match = /this conversation is at ~(\d+)% of the context window/.exec(JSON.parse(text).hookSpecificOutput.additionalContext);
    process.stdout.write(match ? match[1] : "unrecognized");
  '
}

band_of() {
  if [ -f "$1" ]; then tr -d '[:space:]' < "$1"; else printf 'absent'; fi
}

A="$(project a)"
expect "below the threshold the nudge stays silent" "$(nudge "$A" nudge-a 30000 | percent_of)" "silent"
expect "below the threshold the nudge creates no .zensu" "$([ -e "$A/.zensu" ] && echo present || echo absent)" "absent"
expect "crossing the threshold injects the reminder" "$(nudge "$A" nudge-a 55000 | percent_of)" "55"
expect "the crossed band is recorded" "$(band_of "$(band_file "$A" nudge-a)")" "50"
expect "a second prompt in the same band stays silent" "$(nudge "$A" nudge-a 58000 | percent_of)" "silent"
expect "the next band climb injects the reminder again" "$(nudge "$A" nudge-a 61000 | percent_of)" "61"
expect "the climbed band is recorded" "$(band_of "$(band_file "$A" nudge-a)")" "60"
expect "a compaction below the recorded band stays silent" "$(nudge "$A" nudge-a 32000 | percent_of)" "silent"
expect "a compaction re-arms the band" "$(band_of "$(band_file "$A" nudge-a)")" "30"
expect "a climb after the compaction injects the reminder" "$(nudge "$A" nudge-a 52000 | percent_of)" "52"
expect "each session keeps its own band" "$(nudge "$A" nudge-other 55000 | percent_of)" "55"

B="$(project b)"
rm -f "$TMP/probe-b.jsonl"
OUT_FIRST="$(nudge "$B" nudge-b 55000 env ZENSU_PROBE_ROOTS="$B" ZENSU_PROBE_REPORT="$TMP/probe-b.jsonl" NODE_OPTIONS="--require \"$PROBE\"" | percent_of)"
OUT_SECOND="$(nudge "$B" nudge-b 65000 env ZENSU_PROBE_ROOTS="$B" ZENSU_PROBE_REPORT="$TMP/probe-b.jsonl" NODE_OPTIONS="--require \"$PROBE\"" | percent_of)"
if [ "$OUT_FIRST" = 55 ] && [ "$OUT_SECOND" = 65 ] && [ "$(band_of "$(band_file "$B" nudge-b)")" = 60 ] \
  && node "$VERDICT" "$TMP/probe-b.jsonl" --writer writeSessionFile --opened "$(band_file "$B" nudge-b)" \
    --within inspectSessionFile >"$TMP/probe-b.verdict" 2>&1; then
  check "the nudge creates and changes its band only inside the core writer and reads it only inside the core reader" PASS
else
  check "the nudge creates and changes its band only inside the core writer and reads it only inside the core reader (got '$OUT_FIRST' '$OUT_SECOND': $(cat "$TMP/probe-b.verdict" 2>/dev/null))" FAIL
fi

C="$(project c)"
printf 'not a directory\n' > "$C/.zensu"
nudge "$C" nudge-c 55000 > "$TMP/out-c.json"
expect "a workflow root the core refuses still lets the prompt through" "$?" "0"
expect "a workflow root the core refuses keeps the nudge silent" "$(percent_of < "$TMP/out-c.json")" "silent"
expect "a workflow root the core refuses is left unchanged" "$(cat "$C/.zensu")" "not a directory"

D="$(project d)"
mkdir -p "$D/.zensu/state/context-nudge-$(node "$CORE" session-key nudge-d).txt"
expect "a band entry the core refuses keeps the nudge silent" "$(nudge "$D" nudge-d 55000 | percent_of)" "silent"
expect "a band entry the core refuses is left unchanged" "$(find "$D/.zensu/state" -mindepth 1 | wc -l | tr -d ' ')" "1"

E="$(project e)"
mkdir "$E/.ZENSU"
if [ -d "$E/.zensu" ]; then
  expect "a case-alias workflow root keeps the nudge silent" "$(nudge "$E" nudge-e 55000 | percent_of)" "silent"
  expect "nothing is created under a case-alias workflow root" "$(ls -A "$E/.ZENSU" | wc -l | tr -d ' ')" "0"
else
  printf '  SKIP  case-alias workflow root (this volume is case-sensitive)\n'
fi

printf '%s\n' "----" "test-context-nudge-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
