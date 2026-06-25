#!/bin/bash
set -u

# Pins the Codex session-id resolution tier order: an explicit id wins, then
# the project-scoped
# session-id-current.txt pointer OUTRANKS the Claude-transcript helper, then the
# helper, then the PPID-keyed cache, then fallback_<key>. The pointer-above-helper
# rule guards a dual-CLI machine where the helper would otherwise return a live
# Claude transcript id and detach the armed session mid-run.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-session.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "hooks/lib/zensu-session.sh exists" FAIL
  echo "----"
  echo "test-session-id-fallback: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S2-C0 hooks/lib/zensu-session.sh exists" PASS

if bash -n "$HELPER" 2>/dev/null; then
  check "S2-C0a bash -n syntax check on zensu-session.sh" PASS
else
  check "S2-C0a bash -n syntax check on zensu-session.sh" FAIL
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
EMPTY_PROJECTS="$TMP_DIR/empty-projects"
PROJECTS_BASE="$TMP_DIR/projects"
mkdir -p "$EMPTY_PROJECTS" "$PROJECTS_BASE"

sanitize_proj() { node -e 'process.stdout.write(String(process.argv[1]).replace(/[^A-Za-z0-9_-]/g,"-"))' "$1"; }
seed_helper_jsonl() {  # $1=PROJECT_DIR $2=UUID
  local sub; sub="$(sanitize_proj "$1")"
  mkdir -p "$PROJECTS_BASE/$sub"
  : > "$PROJECTS_BASE/$sub/$2.jsonl"
}

# Case 1 — stdin id present → returned verbatim sanitized.
OUT1=$(CLAUDE_PROJECT_DIR="$TMP_DIR/p1" bash -c "source '$HELPER'; zensu_resolve_session_id 'abc-123_real'")
if [ "$OUT1" = "abc-123_real" ]; then
  check "S2-C1 stdin session_id present and sanitization-safe -> returned verbatim" PASS
else
  check "S2-C1 stdin session_id (got '$OUT1')" FAIL
fi

# Case 4 — sanitization strips dangerous chars.
OUT4=$(CLAUDE_PROJECT_DIR="$TMP_DIR/p4" bash -c "source '$HELPER'; zensu_resolve_session_id '../foo/bar baz'")
case "$OUT4" in
  *../*|*/*|*' '*)
    check "S2-C4 dangerous chars stripped (got '$OUT4')" FAIL ;;
  *)
    if [ -n "$OUT4" ]; then
      check "S2-C4 dangerous chars (../, /, space) stripped from sanitized result" PASS
    else
      check "S2-C4 sanitized id non-empty after stripping" FAIL
    fi
    ;;
esac

# Case PTR — current-session pointer present, helper neutralized -> pointer wins.
PROJECT_PTR="$TMP_DIR/p-ptr"
mkdir -p "$PROJECT_PTR/.zensu/state"
printf '%s\n' "ptr-only-sid" > "$PROJECT_PTR/.zensu/state/session-id-current.txt"
OUTP=$(CLAUDE_PROJECT_DIR="$PROJECT_PTR" ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" bash -c "source '$HELPER'; zensu_resolve_session_id ''")
if [ "$OUTP" = "ptr-only-sid" ]; then
  check "S2-CPTR session-id-current.txt pointer returned when helper finds nothing" PASS
else
  check "S2-CPTR pointer read (got '$OUTP' expected 'ptr-only-sid')" FAIL
fi

# Case PTR>HELPER — pointer AND a resolvable helper transcript both present -> pointer outranks helper.
PROJECT_PH="$TMP_DIR/p-ptr-helper"
mkdir -p "$PROJECT_PH/.zensu/state"
seed_helper_jsonl "$PROJECT_PH" "11111111-2222-3333-4444-555555555555"
printf '%s\n' "pointer-beats-helper" > "$PROJECT_PH/.zensu/state/session-id-current.txt"
OUTPH=$(CLAUDE_PROJECT_DIR="$PROJECT_PH" ZENSU_PROJECTS_DIR="$PROJECTS_BASE" bash -c "source '$HELPER'; zensu_resolve_session_id ''")
if [ "$OUTPH" = "pointer-beats-helper" ]; then
  check "S2-CPTR>HELPER pointer outranks the Claude-transcript helper (dual-CLI safety)" PASS
else
  check "S2-CPTR>HELPER ordering (got '$OUTPH' expected 'pointer-beats-helper' — helper leaked above pointer)" FAIL
fi

# Case HELPER>KEYED — no pointer; helper transcript AND keyed cache both present -> helper wins.
PROJECT_HK="$TMP_DIR/p-helper-keyed"
mkdir -p "$PROJECT_HK/.zensu/state"
HK_UUID="66666666-7777-8888-9999-aaaaaaaaaaaa"
seed_helper_jsonl "$PROJECT_HK" "$HK_UUID"
SEED_HK="$TMP_DIR/seed-hk.sh"
cat > "$SEED_HK" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
printf '%s\n' "keyed-should-lose" > "$PROJECT_HK/.zensu/state/session-id-\${KEY}.txt"
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
EOF
chmod +x "$SEED_HK"
OUTHK_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_HK" ZENSU_PROJECTS_DIR="$PROJECTS_BASE" "$SEED_HK" 2>&1)
OUTHK=$(echo "$OUTHK_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
if [ "$OUTHK" = "$HK_UUID" ]; then
  check "S2-CHELPER>KEYED helper transcript outranks the PPID-keyed cache" PASS
else
  check "S2-CHELPER>KEYED ordering (got '$OUTHK' expected '$HK_UUID')" FAIL
fi

# Case KEYED — no pointer, helper neutralized, keyed cache present -> keyed returned.
PROJECT_K="$TMP_DIR/p-keyed"
mkdir -p "$PROJECT_K/.zensu/state"
SEED_K="$TMP_DIR/seed-k.sh"
cat > "$SEED_K" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
printf '%s\n' "keyed-only-sid" > "$PROJECT_K/.zensu/state/session-id-\${KEY}.txt"
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
EOF
chmod +x "$SEED_K"
OUTK_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_K" ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" "$SEED_K" 2>&1)
OUTK=$(echo "$OUTK_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
if [ "$OUTK" = "keyed-only-sid" ]; then
  check "S2-CKEYED PPID-keyed cache honored when pointer absent and helper finds nothing" PASS
else
  check "S2-CKEYED keyed cache read (got '$OUTK' expected 'keyed-only-sid')" FAIL
fi

# Case 3 — nothing seeded, helper neutralized -> fallback_<key>.
PROJECT_FB="$TMP_DIR/p-fb"
mkdir -p "$PROJECT_FB/.zensu/state"
SEED_FB="$TMP_DIR/seed-fb.sh"
cat > "$SEED_FB" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
echo "KEY=\${KEY}"
EOF
chmod +x "$SEED_FB"
OUTFB_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_FB" ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" "$SEED_FB" 2>&1)
OUTFB=$(echo "$OUTFB_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
KEYFB=$(echo "$OUTFB_RAW" | grep '^KEY=' | cut -d= -f2-)
EXPECTED_FB="fallback_${KEYFB}"
if [ "$OUTFB" = "$EXPECTED_FB" ]; then
  check "S2-C3 stdin empty + nothing resolvable -> fallback_<key> deterministic fallback" PASS
else
  check "S2-C3 fallback (got '$OUTFB' expected '$EXPECTED_FB' raw='$OUTFB_RAW')" FAIL
fi

case "$OUTFB" in
  *unknown*)
    check "S2-C3b fallback never contains literal 'unknown' string" FAIL ;;
  *)
    check "S2-C3b fallback never contains literal 'unknown' string" PASS ;;
esac

# Case 6 — zensu_session_key returns stable ${PPID}_${cksum_of_lstart} shape.
KEY1=$(bash -c "source '$HELPER'; zensu_session_key")
case "$KEY1" in
  [0-9]*_[0-9]*)
    check "S2-C6 zensu_session_key shape matches '<pid>_<cksum>' (got '$KEY1')" PASS ;;
  [0-9]*)
    check "S2-C6 zensu_session_key shape matches bare pid fallback (got '$KEY1')" PASS ;;
  *)
    check "S2-C6 zensu_session_key shape (got '$KEY1')" FAIL ;;
esac

PAIR_OUT=$(bash -c "source '$HELPER'; zensu_session_key; zensu_session_key")
KEY1A=$(echo "$PAIR_OUT" | head -1)
KEY1B=$(echo "$PAIR_OUT" | tail -1)
if [ "$KEY1A" = "$KEY1B" ] && [ -n "$KEY1A" ]; then
  check "S2-C6b zensu_session_key stable across two calls in same shell" PASS
else
  check "S2-C6b zensu_session_key stable (a='$KEY1A' b='$KEY1B')" FAIL
fi

# Case 7 — graceful degradation when ps/cksum missing → bare ${PPID}.
DEGRADE_DIR="$TMP_DIR/degraded-path"
mkdir -p "$DEGRADE_DIR"
cat > "$DEGRADE_DIR/ps" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$DEGRADE_DIR/cksum" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$DEGRADE_DIR/ps" "$DEGRADE_DIR/cksum"
DEGRADED_KEY=$(env PATH="$DEGRADE_DIR:/usr/bin:/bin" bash -c "source '$HELPER'; zensu_session_key")
case "$DEGRADED_KEY" in
  [0-9]*_*)
    check "S2-C7 ps + cksum failing but key still contains underscore (unexpected, ps stub did not block)" FAIL ;;
  [0-9]*)
    check "S2-C7 ps/cksum stubbed-failing -> bare numeric PPID fallback" PASS ;;
  *)
    check "S2-C7 ps/cksum stubbed-failing (got '$DEGRADED_KEY')" FAIL ;;
esac

DEGRADED_RESOLVE=$(env PATH="$DEGRADE_DIR:/usr/bin:/bin" CLAUDE_PROJECT_DIR="$PROJECT_FB" ZENSU_PROJECTS_DIR="$EMPTY_PROJECTS" bash -c "source '$HELPER'; zensu_resolve_session_id ''")
case "$DEGRADED_RESOLVE" in
  fallback_[0-9]*)
    check "S2-C7b ps/cksum failing -> resolve returns fallback_<bare-pid>" PASS ;;
  *)
    check "S2-C7b ps/cksum failing resolve (got '$DEGRADED_RESOLVE')" FAIL ;;
esac

echo "----"
echo "test-session-id-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
