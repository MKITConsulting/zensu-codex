#!/bin/bash
set -u

# Structure test for the $zensu-pr-team-review skill (Codex port).
# Pins: the skill tree exists (SKILL.md + three rules files), the Codex-namespaced
# H1 + frontmatter, the orchestration essentials (worktree isolation, detached
# worktree, race-safe mktemp -d workspace, ONE parallel subagent batch, one
# consolidated gh api review, the 14-persona pool), Codex-idiom purity (none of the
# Claude multi-agent tokens subagent_type / general-purpose / run_in_background /
# TeamCreate / SendMessage / TaskList, and no /zensu: slash refs), bundled-path
# safety, and English-only. Skills auto-register via the .codex-plugin dir-glob
# ("skills": "./skills/"), so there is no plugin.json skills[] entry to assert.

PLUGIN_DIR="$(cd "$(dirname "$0")/../../plugins/zensu" && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/pr-team-review"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
pin() {  # $1=fixed-string pattern  $2=label
  grep -qF -- "$1" "$SKILL_MD" && check "$2" PASS || check "$2" FAIL
}

if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/pr-team-review/SKILL.md exists" FAIL
  echo "----"; echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "P1 skills/pr-team-review/SKILL.md exists" PASS

# P2 — the three rules files ship alongside the skill
for r in reviewer-personas workflow github-publish; do
  [ -f "$SKILL_DIR/rules/$r.md" ] && check "P2 rules/$r.md exists" PASS || check "P2 rules/$r.md exists" FAIL
done

# P3 — Codex-namespaced H1 + frontmatter name (drives $zensu-x invocation + auto-trigger)
grep -qxF '# $zensu-pr-team-review' "$SKILL_MD" \
  && check "P3a namespaced H1 '# \$zensu-pr-team-review'" PASS || check "P3a namespaced H1" FAIL
grep -qE '^name: *zensu-pr-team-review *$' "$SKILL_MD" \
  && check "P3b frontmatter 'name: zensu-pr-team-review'" PASS || check "P3b frontmatter name" FAIL

# P4 — orchestration essentials (engine-neutral + the Codex spawn idiom)
pin "worktree add"        "P4a worktree isolation (git worktree add)"
pin "--detach"           "P4b detached worktree (--detach)"
pin "mktemp -d"          "P4c race-safe workspace (mktemp -d)"
pin "parallel batch"     "P4d ONE parallel subagent batch (Codex idiom)"
pin "Submit ONE review"  "P4e one consolidated review"
pin "pulls/<n>/reviews"  "P4f gh api reviews endpoint"
pin "14-persona"         "P4g 14-persona pool"
pin "no team/background/messaging layer" "P4h Codex spawn contract (subagents return, no team/background/messaging)"

# P5 — Codex-idiom purity: none of the Claude multi-agent tokens, no /zensu: slash refs.
# The Codex model spawns subagents by request (no team/background/messaging layer)
# and cross-references skills as $zensu-x, so these tokens must be ABSENT.
FORBIDDEN='subagent_type|general-purpose|run_in_background|TeamCreate|SendMessage|TaskList|TaskCreate|TaskUpdate|AskUserQuestion|/zensu:'
if grep -rqE "$FORBIDDEN" "$SKILL_DIR"; then
  check "P5 Codex-idiom purity (found a Claude token: $FORBIDDEN)" FAIL
  grep -rnE "$FORBIDDEN" "$SKILL_DIR" | sed 's/^/        /'
else
  check "P5 Codex-idiom purity (no Claude multi-agent/slash tokens)" PASS
fi

# P6 — bundled-path: no hardcoded ~/.claude/skills home path (use ${CLAUDE_PLUGIN_ROOT})
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P6 no hardcoded ~/.claude/skills path" FAIL
else
  check "P6 no hardcoded ~/.claude/skills path (bundled-path safe)" PASS
fi

# P7 — English-only guard: German tokens MUST be ABSENT across the skill tree.
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P7 English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P7 English-only (no German tokens)" PASS
fi

echo "----"
echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
