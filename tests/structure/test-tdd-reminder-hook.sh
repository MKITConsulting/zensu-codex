#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
SESSION_HOOK="$PLUGIN_DIR/hooks/session-start-session-control.sh"
NO_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/user-prompt-tdd-reminder.sh exists" FAIL
  echo "----"
  echo "test-tdd-reminder-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command);
  process.exit(ups.some(c=>/user-prompt-tdd-reminder\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json UserPromptSubmit" PASS
else
  check "C3 registered in hooks.json UserPromptSubmit" FAIL
fi

if grep -qF 'zensu_hook_enabled' "$HOOK" && grep -qF 'tddReminder' "$HOOK"; then
  check "C4 gated by hooks.tddReminder (zensu_hook_enabled tddReminder)" PASS
else
  check "C4 gated by hooks.tddReminder (zensu_hook_enabled tddReminder)" FAIL
fi

if grep -qF 'UserPromptSubmit' "$HOOK" && grep -qF 'hookEventName' "$HOOK" && grep -qF 'additionalContext' "$HOOK"; then
  check "C5 builds UserPromptSubmit additionalContext" PASS
else
  check "C5 builds UserPromptSubmit additionalContext" FAIL
fi

payload() {
  node -e 'process.stdout.write(JSON.stringify({prompt:process.argv[1],session_id:process.argv[2]||"t"}))' "$1" "$2"
}

# Reduce the hook output to FIRED (TDD directive present, Codex vocabulary) /
# EMPTY (silent) / NOMATCH (fired but missing directive) / BADJSON (malformed).
fired() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        const ac=o.additionalContext||"";
        const ok=(o.hookEventName==="UserPromptSubmit")&&/\$zensu-tdd/.test(ac)&&/ASK the user/.test(ac);
        process.stdout.write(ok?"FIRED":"NOMATCH");
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

# C6 — a non-planning code prompt (the intent-router stays SILENT on this one)
# must FIRE here: every-turn, no keyword filter.
P6="$(mktemp -d -t tddrem-XXXXXX)"
OUT6="$(payload "fix the auth token expiry bug" "s6" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT6" = "FIRED" ] && check "C6 non-planning code prompt fires the TDD directive" PASS || check "C6 non-planning fires (got '$OUT6')" FAIL
rm -rf "$P6"

# C7 — a German prompt fires IDENTICALLY (proves language-independence: no regex).
P7="$(mktemp -d -t tddrem-XXXXXX)"
OUT7="$(payload "behebe den Login-Fehler im Auth-Service" "s7" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P7" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT7" = "FIRED" ] && check "C7 German prompt fires identically (language-independent, no regex)" PASS || check "C7 German fires (got '$OUT7')" FAIL
rm -rf "$P7"

# C8 — empty prompt -> silent, exit 0 (fail-open).
P8="$(mktemp -d -t tddrem-XXXXXX)"
OUT8="$(printf '%s' '{"prompt":"","session_id":"s8"}' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P8" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC8=$?
if [ "$RC8" = "0" ] && [ -z "$OUT8" ]; then
  check "C8 empty prompt -> exit 0, silent (fail-open)" PASS
else
  check "C8 empty prompt (rc=$RC8 out='$OUT8')" FAIL
fi
rm -rf "$P8"

# C9 — hooks.tddReminder:false -> silent (opt-out honored).
P9="$(mktemp -d -t tddrem-XXXXXX)"
CFG9="$P9/config.json"; printf '%s' '{"hooks":{"tddReminder":false}}' > "$CFG9"
OUT9="$(payload "implement a debounce helper" "s9" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P9" ZENSU_CONFIG="$CFG9" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT9" = "EMPTY" ] && check "C9 hooks.tddReminder:false -> silent (opt-out honored)" PASS || check "C9 disabled silent (got '$OUT9')" FAIL
rm -rf "$P9"

# C10 — an active TDD session -> silent (the TDD flow owns the reminder there).
P10="$(mktemp -d -t tddrem-XXXXXX)"
HOME10="$P10/.test-home"
mkdir -p "$HOME10"
printf '{"hook_event_name":"SessionStart","session_id":"s10","cwd":"%s"}' "$P10" \
  | env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    HOME="$HOME10" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$SESSION_HOOK" >/dev/null 2>&1
CORE="$SESSION_CORE" PROJECT="$P10" node -e '
  const core = require(process.env.CORE);
  core.mutateWorkflowState({
    projectRoot: process.env.PROJECT,
    sessionId: "s10",
    workflowState: "active",
    event: "test-seed",
  }, (state) => ({ ...state, phase: "IMPL", history: [], active: true, vanilla: true }));
'
OUT10="$(payload "add validation to the parser" "s10" | env HOME="$HOME10" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT10" = "EMPTY" ] && check "C10 active TDD session -> silent" PASS || check "C10 active-session silence (got '$OUT10')" FAIL
rm -rf "$P10"

# C11 — config.example.json registers the flag.
if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(j.hooks && j.hooks.tddReminder===true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C11 config.example.json has hooks.tddReminder" PASS
else
  check "C11 config.example.json has hooks.tddReminder" FAIL
fi

# C12 — the directive front-loads ask-first ($zensu-tdd inline), the fast-paths, and the dismiss clauses.
P12="$(mktemp -d -t tddrem-XXXXXX)"
AC12="$(payload "build a rate limiter" "s12" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC12" ] \
   && printf '%s' "$AC12" | grep -qi 'ASK the user' \
   && printf '%s' "$AC12" | grep -qF '$zensu-tdd' \
   && printf '%s' "$AC12" | grep -qi 'use tdd' \
   && printf '%s' "$AC12" | grep -qi 'no tdd' \
   && printf '%s' "$AC12" | grep -qi 'Auto Mode' \
   && printf '%s' "$AC12" | grep -qi 'IGNORE'; then
  check "C12 directive carries ask-first (inline + \$zensu-tdd) + fast-paths (use/no tdd, Auto Mode) + dismiss (IGNORE)" PASS
else
  fired12="$([ -n "$AC12" ] && echo yes || echo no)"
  check "C12 directive content (fired=$fired12)" FAIL
fi
rm -rf "$P12"

echo "----"
echo "test-tdd-reminder-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
