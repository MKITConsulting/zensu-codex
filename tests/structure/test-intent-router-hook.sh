#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-intent-router.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
NO_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/user-prompt-intent-router.sh exists" FAIL
  echo "----"
  echo "test-intent-router-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command);
  process.exit(ups.some(c=>/user-prompt-intent-router\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json UserPromptSubmit" PASS
else
  check "C3 registered in hooks.json UserPromptSubmit" FAIL
fi

if grep -qF 'zensu_hook_enabled' "$HOOK" && grep -qF 'intentRouter' "$HOOK"; then
  check "C4 gated by hooks.intentRouter (zensu_hook_enabled intentRouter)" PASS
else
  check "C4 gated by hooks.intentRouter (zensu_hook_enabled intentRouter)" FAIL
fi

if grep -qF 'UserPromptSubmit' "$HOOK" && grep -qF 'hookEventName' "$HOOK" && grep -qF 'additionalContext' "$HOOK"; then
  check "C5 builds UserPromptSubmit additionalContext" PASS
else
  check "C5 builds UserPromptSubmit additionalContext" FAIL
fi

payload() {
  node -e 'process.stdout.write(JSON.stringify({prompt:process.argv[1]}))' "$1"
}

classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        const ac=o.additionalContext||"";
        const route=(/Invoke the matching skill yourself/.test(ac)
          && /never delegate mutations to zensu-plm/.test(ac))?"main":"notmain";
        const triage=(/greenfield/i.test(ac)&&/brownfield/i.test(ac))?"triage":"notriage";
        process.stdout.write((o.hookEventName||"?")+"|"+route+"|"+triage);
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

P6="$(mktemp -d -t introuter-XXXXXX)"
OUT6="$(payload "I want to track Zensu as a product in Zensu itself" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT6" = "UserPromptSubmit|main|triage" ]; then
  check "C6 planning prompt -> main-thread skill routing + greenfield/brownfield triage" PASS
else
  check "C6 planning directive (got '$OUT6')" FAIL
fi
rm -rf "$P6"

P7="$(mktemp -d -t introuter-XXXXXX)"
OUT7="$(payload "fix the auth token expiry bug" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P7" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT7" = "EMPTY" ] && check "C7 non-planning prompt -> silent" PASS || check "C7 non-planning silent (got '$OUT7')" FAIL
rm -rf "$P7"

P8="$(mktemp -d -t introuter-XXXXXX)"
CFG8="$P8/config.json"; printf '%s' '{"hooks":{"intentRouter":false}}' > "$CFG8"
OUT8="$(payload "bootstrap a new product roadmap in zensu" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P8" ZENSU_CONFIG="$CFG8" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT8" = "EMPTY" ] && check "C8 hooks.intentRouter:false -> silent (opt-out honored)" PASS || check "C8 disabled silent (got '$OUT8')" FAIL
rm -rf "$P8"

P9="$(mktemp -d -t introuter-XXXXXX)"
OUT9="$(printf '%s' '{"session_id":"s9"}' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P9" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC9=$?
if [ "$RC9" = "0" ] && [ -z "$OUT9" ]; then
  check "C9 missing prompt field -> exit 0, silent (fail-open)" PASS
else
  check "C9 missing prompt (rc=$RC9 out='$OUT9')" FAIL
fi
rm -rf "$P9"

if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(j.hooks && j.hooks.intentRouter===true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C10 config.example.json has hooks.intentRouter" PASS
else
  check "C10 config.example.json has hooks.intentRouter" FAIL
fi

P11="$(mktemp -d -t introuter-XXXXXX)"
KW_FAIL=0
for kw in zensu product feature roadmap milestone bootstrap "ghost scan" journey tier; do
  OUTKW="$(payload "let us $kw the plan now" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUTKW" = "UserPromptSubmit|main|triage" ] || { KW_FAIL=$((KW_FAIL+1)); echo "      keyword '$kw' did not fire (got '$OUTKW')"; }
done
[ "$KW_FAIL" -eq 0 ] && check "C11 every planning keyword fires as a whole word" PASS || check "C11 per-keyword coverage ($KW_FAIL missed)" FAIL
rm -rf "$P11"

P12="$(mktemp -d -t introuter-XXXXXX)"
OUT12A="$(payload "speed up production builds" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT12B="$(payload "explore the new frontier" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT12A" = "EMPTY" ] && [ "$OUT12B" = "EMPTY" ]; then
  check "C12 mid-word substrings (production/frontier) -> silent (whole-word match)" PASS
else
  check "C12 mid-word silence (a='$OUT12A' b='$OUT12B')" FAIL
fi
rm -rf "$P12"

P13="$(mktemp -d -t introuter-XXXXXX)"
OUT13="$(payload "list all products on the roadmaps" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P13" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT13" = "UserPromptSubmit|main|triage" ] && check "C13 inflected keywords (products/roadmaps) still fire" PASS || check "C13 inflection (got '$OUT13')" FAIL
rm -rf "$P13"

P14="$(mktemp -d -t introuter-XXXXXX)"
AC14="$(payload "please improve my product by adding a new modern hero section to my landing page" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P14" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC14" ] \
   && printf '%s' "$AC14" | grep -qi 'ignore this notice' \
   && printf '%s' "$AC14" | grep -qi 'answer the request normally' \
   && printf '%s' "$AC14" | grep -qi 'do NOT run the triage'; then
  check "C14 keyword-bearing non-planning prompt fires but directive empowers the model to dismiss" PASS
else
  fired="$([ -n "$AC14" ] && echo yes || echo no)"
  check "C14 dismiss-flexibility in directive (fired=$fired)" FAIL
fi
rm -rf "$P14"

P15="$(mktemp -d -t introuter-XXXXXX)"
AC15="$(payload "I want to track my SaaS product and its features in Zensu" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P15" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC15" ] \
   && printf '%s' "$AC15" | grep -qi 'very next action' \
   && printf '%s' "$AC15" | grep -qi 'do NOT read files' \
   && printf '%s' "$AC15" | grep -qi 'ground'; then
  check "C15 planning directive front-loads ask-first + forbids explore/ground-first deferral" PASS
else
  fired15="$([ -n "$AC15" ] && echo yes || echo no)"
  check "C15 ask-first/anti-explore clause (fired=$fired15)" FAIL
fi
rm -rf "$P15"

P16="$(mktemp -d -t introuter-XXXXXX)"
OUT16=""
for prompt in "zensu reanchor" "  Zensu   RE-ANCHOR  " "zensu reanchor --discard-open-work"; do
  OUT16="$OUT16$(payload "$prompt" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P16" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)|"
done
OUT16B="$(payload "zensu reanchor now" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P16" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT16" = "EMPTY|EMPTY|EMPTY|" ] && [ "$OUT16B" = "UserPromptSubmit|main|triage" ]; then
  check "C16 the Session Control re-anchor message -> silent, other zensu prompts still fire" PASS
else
  check "C16 re-anchor message silence (got '$OUT16' / '$OUT16B')" FAIL
fi
rm -rf "$P16"

echo "----"
echo "test-intent-router-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
