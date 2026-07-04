#!/bin/bash
set -u

# Structure test for the $zensu-autopilot skill (Codex port).
# Pins: the skill tree exists (SKILL.md + four rules files), the Codex-namespaced
# H1 + frontmatter, the orchestration essentials (one interactive planning gate,
# the strict build order delegating to the sibling Zensu skills via $zensu-x,
# team-review-once, the validate<->fix loop, never auto-merge, worktree-only), the
# credential-blind security invariants (AI never sees a secret, login-script not an
# endpoint, artifacts handled as credentials, secret-free config), Codex-idiom
# purity (no Claude-only ExitPlanMode / .claude paths / multi-agent tokens, no
# /zensu: slash refs), bundled-path safety, and English-only. Skills auto-register
# via the .codex-plugin dir-glob, so there is no plugin.json skills[] entry to assert.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/autopilot"
SKILL_MD="$SKILL_DIR/SKILL.md"
AUTH_MD="$SKILL_DIR/rules/auth.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
pin() {  # $1=fixed-string pattern  $2=label  $3=file (default SKILL_MD)
  local f="${3:-$SKILL_MD}"
  grep -qF -- "$1" "$f" && check "$2" PASS || check "$2" FAIL
}

if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/autopilot/SKILL.md exists" FAIL
  echo "----"; echo "test-autopilot-skill: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "P1 skills/autopilot/SKILL.md exists" PASS

# P2 — the four rules files ship alongside the skill
for r in probe auth drivers config; do
  [ -f "$SKILL_DIR/rules/$r.md" ] && check "P2 rules/$r.md exists" PASS || check "P2 rules/$r.md exists" FAIL
done

# P3 — Codex-namespaced H1 + frontmatter name
grep -qxF '# $zensu-autopilot' "$SKILL_MD" \
  && check "P3a namespaced H1 '# \$zensu-autopilot'" PASS || check "P3a namespaced H1" FAIL
grep -qE '^name: *zensu-autopilot *$' "$SKILL_MD" \
  && check "P3b frontmatter 'name: zensu-autopilot'" PASS || check "P3b frontmatter name" FAIL

# P4 — orchestration essentials
pin "the ONLY interactive gate"  "P4a one interactive planning gate"
pin "\$zensu-tdd"                "P4b implements via \$zensu-tdd"
pin "\$zensu-pr-team-review"     "P4c team review via \$zensu-pr-team-review"
pin "\$zensu-pr-fix-findings"    "P4d fixes via \$zensu-pr-fix-findings"
pin "exactly once"               "P4e team review runs exactly once"
pin "Validate ↔ fix LOOP"        "P4f validate <-> fix loop"
pin "Never auto-merge"           "P4g never auto-merge / auto-deploy"
pin "Worktree only"              "P4h worktree-only build"

# P5 — credential-blind security invariants (the skill's most important property)
pin "credential-blind"                 "P5a SKILL states the credential-blind property"
pin "never sees a password"            "P5b auth.md: AI never sees a password or token" "$AUTH_MD"
pin "Do not introduce an endpoint"     "P5c auth.md: no test-login endpoint (script convention)" "$AUTH_MD"
pin "chmod 600"                        "P5d auth.md: artifacts handled as credentials" "$AUTH_MD"
if grep -rqiF 'secret-free' "$SKILL_DIR"; then
  check "P5e config is committed but secret-free" PASS
else
  check "P5e config is committed but secret-free" FAIL
fi

# P6 — Codex-idiom purity: no ExitPlanMode (Codex has no plan-approval event), no
# .claude/ paths, no Claude multi-agent tokens, no /zensu: slash refs.
FORBIDDEN='ExitPlanMode|/zensu:|\.claude/|subagent_type|general-purpose|run_in_background|TeamCreate|SendMessage|TaskList|TaskCreate|TaskUpdate|AskUserQuestion'
if grep -rqE "$FORBIDDEN" "$SKILL_DIR"; then
  check "P6 Codex-idiom purity (found a Claude token: $FORBIDDEN)" FAIL
  grep -rnE "$FORBIDDEN" "$SKILL_DIR" | sed 's/^/        /'
else
  check "P6 Codex-idiom purity (no ExitPlanMode/.claude/slash/multi-agent tokens)" PASS
fi

# P7 — bundled-path: no hardcoded ~/.claude/skills home path
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P7 no hardcoded ~/.claude/skills path" FAIL
else
  check "P7 no hardcoded ~/.claude/skills path (bundled-path safe)" PASS
fi

# P8 — English-only guard
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P8 English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P8 English-only (no German tokens)" PASS
fi

echo "----"
echo "test-autopilot-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
