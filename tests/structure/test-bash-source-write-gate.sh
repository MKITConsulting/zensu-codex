#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"
PARSER="$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/pre-bash-source-write-gate.sh exists" FAIL
  echo "----"; echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"; exit 1
fi

# ── Structure pins ───────────────────────────────────────────────────
[ -x "$HOOK" ] && check "W1 hook exists + executable" PASS || check "W1 hook exists + executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "W2 hook bash -n syntax" PASS || check "W2 hook bash -n syntax" FAIL
{ [ -f "$PARSER" ] && node --check "$PARSER" 2>/dev/null; } \
  && check "W3 parser exists + node --check" PASS || check "W3 parser exists + node --check" FAIL

node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const ok=pres.some(e=>e.matcher && new RegExp(e.matcher).test("Bash") && (e.hooks||[]).some(z=>/pre-bash-source-write-gate\.sh/.test(z.command||"")));
  process.exit(ok?0:1);
' "$HOOKS_JSON" 2>/dev/null \
  && check "W4 registered as PreToolUse Bash matcher" PASS || check "W4 registered as PreToolUse Bash matcher" FAIL

grep -qF 'zensu_hook_enabled bashWriteGate' "$HOOK" \
  && check "W5 config-gated via zensu_hook_enabled bashWriteGate (default-on)" PASS \
  || check "W5 config-gated via zensu_hook_enabled bashWriteGate (default-on)" FAIL

# ── Behavioral harness ───────────────────────────────────────────────
# A real (nested) git project + a sibling checkout. A controlled fake-temp dir
# (via the ZENSU_BSWGATE_TEMP_DIRS seam) keeps verdicts independent of where the
# repo itself is checked out.
WORKROOT="$TEST_DIR/.bswgate-tmp.$$"
trap 'rm -rf "$WORKROOT"' EXIT
PROJ="$WORKROOT/proj"; SIB="$WORKROOT/sibling"; FAKETMP="$WORKROOT/faketmp"
mkdir -p "$PROJ/src" "$PROJ/build" "$SIB/src" "$FAKETMP"
(
  cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'fn main(){}\n' > src/app.rs && printf 'build/\n' > .gitignore \
    && git add src/app.rs .gitignore && git commit -qm init && printf 'gen\n' > build/gen.rs
) >/dev/null 2>&1
(
  cd "$SIB" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'pub fn x(){}\n' > src/lib.rs && git add src/lib.rs && git commit -qm init
) >/dev/null 2>&1

CFG_DEF="$(mktemp -t bswgate-def-XXXXXX)";  printf '%s' '{"hooks":{}}'                    > "$CFG_DEF"
CFG_OFF="$(mktemp -t bswgate-off-XXXXXX)";   printf '%s' '{"hooks":{"bashWriteGate":false}}' > "$CFG_OFF"

payload() {
  CMD="$1" CWD="${2:-$PROJ}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.env.CMD},cwd:process.env.CWD,session_id:"bswgate-test"};
    process.stdout.write(JSON.stringify(o));
  '
}
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("ALLOW");return;}
      try{const j=JSON.parse(s);const d=j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision;process.stdout.write(d==="deny"?"DENY":(d||"OTHER"));}
      catch(_){process.stdout.write("BADJSON");}
    });
  '
}
# run <label> <cmd> <expected> [cwd] [cfg]
run() {
  local label="$1" cmd="$2" exp="$3" cwd="${4:-$PROJ}" cfg="${5:-$CFG_DEF}"
  local out
  out="$(payload "$cmd" "$cwd" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
        ZENSU_CONFIG="$cfg" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}

# (A) clobber existing tracked source -> DENY
run "W6 append >> tracked .rs"              "printf 'x\n' >> src/app.rs"            DENY
run "W7 clobber > tracked .rs"              "printf 'x\n' > src/app.rs"             DENY
run "W8 glued >>tracked (no space)"         "printf x >>src/app.rs"                 DENY
run "W9 tee tracked .rs"                    "echo x | tee src/app.rs"               DENY
run "W10 tee -a tracked .rs"               "echo x | tee -a src/app.rs"            DENY
run "W11 sed -i '' tracked .rs"            "sed -i '' 's/x/y/' src/app.rs"         DENY
run "W12 sed -i.bak tracked .rs"          "sed -i.bak 's/x/y/' src/app.rs"        DENY
run "W13 dd of= tracked .rs"              "dd if=/dev/null of=src/app.rs"         DENY
HEREDOC="$(printf 'cat > src/app.rs <<EOF\nZZZ_BROKEN\nEOF\n')"
run "W14 heredoc clobber tracked .rs"     "$HEREDOC"                              DENY

# (B) worktree / project escape -> DENY (even for new files)
run "W15 relative escape to sibling"      "printf x >> ../sibling/src/lib.rs"     DENY
run "W16 cd-into-sibling then write"      "cd ../sibling && printf x >> src/lib.rs" DENY
run "W17 escape, brand-new file"          "printf x > ../sibling/src/brandnew.rs" DENY
run "W18 absolute escape path"            "printf x >> $SIB/src/lib.rs"           DENY

# Allow — Bash keeps normal file power
run "W19 new file inside project"         "printf x > src/newfile.rs"             ALLOW
run "W20 glued new file inside project"   "printf x >src/newfile2.rs"             ALLOW
run "W21 non-source extension (.md)"      "echo hi > notes.md"                    ALLOW
run "W22 gitignored existing .rs"         "printf x >> build/gen.rs"              ALLOW
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP  W23 temp-dir source write (MSYS: native node cannot map /x/ mount paths to the mangled env override)" ;;
  *)
    run "W23 temp-dir source write"       "printf x >> $FAKETMP/scratch.rs"       ALLOW ;;
esac
run "W24 read, no write"                  "cat src/app.rs"                        ALLOW
run "W25 plain command, no write"         "git status"                            ALLOW
run "W26 arithmetic compare (not redir)"  "test 5 -gt 3 && echo ok"               ALLOW

# Escape hatch + config
run "W27 inline ZENSU_BASH_WRITE_GATE=off" "ZENSU_BASH_WRITE_GATE=off printf x >> src/app.rs" ALLOW
run "W28 inline ZENSU_MCP_GATE=off"        "ZENSU_MCP_GATE=off printf x >> src/app.rs"        ALLOW
run "W29 config bashWriteGate:false"       "printf x >> src/app.rs" ALLOW "$PROJ" "$CFG_OFF"

# Process-env escape (set on the hook process itself)
OUT="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" ZENSU_BASH_WRITE_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "W30 process-env ZENSU_BASH_WRITE_GATE=off -> ALLOW" PASS \
  || check "W30 process-env escape (got '$OUT')" FAIL

# Fail-open: empty + non-JSON -> ALLOW
OUT="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
OUT2="$(printf '%s' 'not json' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_DEF" bash "$HOOK" 2>/dev/null | classify)"
{ [ "$OUT" = "ALLOW" ] && [ "$OUT2" = "ALLOW" ]; } \
  && check "W31 fail-open: empty + non-JSON -> ALLOW" PASS \
  || check "W31 fail-open (empty='$OUT' nonjson='$OUT2')" FAIL

# Deny-reason content
REASON_A="$(payload 'printf x >> src/app.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$REASON_A" | grep -qF 'tracked' && printf '%s' "$REASON_A" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W32 clobber deny-reason: 'tracked' + escape-hatch hint" PASS \
  || check "W32 clobber deny-reason content" FAIL

REASON_B="$(payload 'printf x >> ../sibling/src/lib.rs' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
          ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
{ printf '%s' "$REASON_B" | grep -qiF 'worktree' && printf '%s' "$REASON_B" | grep -qF 'ZENSU_BASH_WRITE_GATE=off'; } \
  && check "W33 escape deny-reason: 'worktree' + escape-hatch hint" PASS \
  || check "W33 escape deny-reason content" FAIL

# ── Regression pins from review round 1 ──────────────────────────────
# fd / quoting / redirect-variant correctness
run "W34 stderr-redirect is not a write"        "cat src/app.rs 2>&1"                       ALLOW
run "W35 redirect + trailing 2>&1 gated"        "printf x > src/app.rs 2>&1"                DENY
run "W36 quoted '>' in a message arg"           'git commit -m "refactor > faster"'         ALLOW
run "W37 quoted path, no redirect operator"     'echo "see src/app.rs"'                     ALLOW
run "W41 glued single-quoted redirect path"     "printf x >'src/app.rs'"                    DENY
run "W42 glued double-quoted append path"       "printf x >>\"src/app.rs\""                 DENY
run "W43 dd of= quoted path"                    "dd if=/dev/null of='src/app.rs'"           DENY
run "W44 redirect-all &> gated"                 "printf x &> src/app.rs"                     DENY
run "W45 redirect-all append &>> gated"         "printf x &>> src/app.rs"                    DENY
run "W51 noclobber override >| gated"           "echo x >| src/app.rs"                       DENY
run "W52 noclobber override glued >|"           "printf x >|src/app.rs"                      DENY
run "W53 of= only gated for dd (not echo)"      "echo of=src/app.rs"                         ALLOW

# transparent wrappers (env/sudo/command) must not hide the real verb
run "W55 env-wrapped sed -i"                    "env sed -i '' 's/x/y/' src/app.rs"         DENY
run "W56 sudo-wrapped dd of="                   "sudo dd if=/dev/null of=src/app.rs"        DENY
run "W57 env-wrapped redirect still gated"      "env printf x > src/app.rs"                 DENY

# >&FILE redirect-all-to-file (the &> mirror); fd dups (>&2 / >&-) stay ALLOW
run "W58 >& redirect-all to tracked (spaced)"   "printf x >& src/app.rs"                     DENY
run "W59 >& redirect-all to tracked (glued)"    "printf x >&src/app.rs"                      DENY
run "W60 >&2 fd-dup is not a file write"        "echo x >&2"                                 ALLOW
run "W61 >&- fd-close is not a file write"      "echo x >&-"                                 ALLOW
# accepted lexical limitation (documented): tee >(proc) severs a trailing real file
run "W62 tee >(proc) realfile (accepted gap)"   "echo x | tee >(cat) src/app.rs"             ALLOW

# tee multi-target + process substitution + interspersed redirect
run "W38 tee two targets, one tracked"          "echo x | tee notes.md src/app.rs"          DENY
run "W39 tee process-substitution"              "echo x | tee >(cat)"                        ALLOW
run "W50 tee with interspersed redirect"        "echo x | tee > /dev/null src/app.rs"        DENY

# cd scoping: escaped-cd still tracks cwd; subshell cd does not leak
run "W47 escaped cd still tracks cwd"           "ZENSU_BASH_WRITE_GATE=off cd ../sibling && printf x >> src/lib.rs" DENY
run "W48 subshell cd does not leak (no FP)"     "(cd ../sibling) && printf x > src/new.rs"   ALLOW
run "W49 in-subshell escape still caught"       "(cd ../sibling && printf x > src/lib.rs)"   DENY

# here-string (<<<) must not be treated as a heredoc and swallow a later write
HS="$(printf 'grep p <<<WORD\nprintf y > src/app.rs\n')"
run "W46 here-string does not swallow next write" "$HS"                                      DENY

# escape suppressed by config also covers rule B (escape), not just rule A
run "W40 escape suppressed by bashWriteGate:false" "printf x >> ../sibling/src/lib.rs" ALLOW "$PROJ" "$CFG_OFF"

# rule precedence: an escaped AND tracked target reports the worktree (B) reason
REASON_ESC="$(payload "printf x >> $SIB/src/lib.rs" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
            ZENSU_CONFIG="$CFG_DEF" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null)"
printf '%s' "$REASON_ESC" | grep -qiF 'worktree' \
  && check "W54 escaped+tracked target reports rule-B (worktree) reason" PASS \
  || check "W54 escaped+tracked rule precedence" FAIL

rm -f "$CFG_DEF" "$CFG_OFF"

echo "----"
echo "test-bash-source-write-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
