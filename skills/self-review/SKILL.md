---
name: zensu-self-review
description: Terminal self-reflection stage of the post-implementation review chain — re-read this session's work as a senior engineer reviewing your own code, take at most one fix round if a must-fix surfaces, then render the final report and close the chain. Runs automatically as the chain's final gate after the zensu-code-reviewer chain converges; not normally invoked by hand.
---

# $zensu-self-review

Terminal self-reflection stage of the post-implementation review chain. After the
`zensu-code-reviewer` chain converges (PASS, suggestions-only, or max-rounds), you
re-read this session's work as an experienced senior engineer reviewing your own
code, take at most ONE fix round if a must-fix surfaces, then render the final
report and close the chain. This is the LAST instance — it never re-runs the
code-reviewer.

You have full access to the conversation history and know exactly which files you
edited, created, or deleted in this session. Use that knowledge directly.

## When to Use

- Invoked automatically as the terminal review-chain stage: the
  `post-review-tdd-delegate.sh` hook hands off here once the code-reviewer chain
  converges, and the `stop-chain-enforcer.sh` Stop hook forces this skill while
  `codeReviewDone` is set but `chainDone` is not.
- You should normally NOT run this by hand — it is the chain's final gate.

## Do NOT Use For

- A substitute for the `zensu-code-reviewer` subagent — that runs first; this is the
  terminal pass over your own work.
- Bypassing findings: a must-fix you surface here still goes through strict TDD.
- More than one fix round: the budget is exactly one (a hard latch), then finalize.

## What This Skill Does

1. Lists the files you changed this session (conversation context + `git diff --name-only HEAD`).
2. Re-reviews each change across seven dimensions against the project conventions.
3. Emits a Positive / Improvements / Risks reflection.
4. Takes at most ONE fix round under the still-active TDD phase-gate if a must-fix
   risk surfaces — without re-running the code-reviewer.
5. Owns the chain terminus: runs `--chain-done` and renders the final report.

## Phase 1: List Changed Files

List every file you changed or created in this session. You know these from your
own context — no parsing needed. Cross-check with `git diff --name-only HEAD` to
catch anything you missed.

If there are NO changes this session, run
`bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --chain-done`, state
"No changes — self-review skipped", and stop. `{PLUGIN_ROOT}` is the value you
resolved in `$zensu-tdd` Phase 0 (the contents of `~/.zensu/plugin-root`).

## Phase 2: Analyze

Read the current content of each changed file with the Read tool. Read the project
root `CLAUDE.md` so you apply the governing conventions. Score each change on:

- **Architecture**: does the approach fit the existing structure? Are better patterns available?
- **Consistency**: does the code follow the patterns used elsewhere in the codebase?
- **Edge-cases**: missing boundary conditions, error handling, or validation?
- **Test coverage**: are the tests sufficient? Are scenarios missing?
- **Security**: potential vulnerabilities (injection, missing auth checks, secret leakage)?
- **Simplification**: unnecessary complexity that could be reduced?
- **Conventions**: are the CLAUDE.md rules honored (language, comments, watermarks)?

## Phase 3: Report

Structure the reflection as:

- **Positive**: what was solved well.
- **Improvements**: concrete suggestions with `file:line` references.
- **Risks**: potential problems that were overlooked.

Be honest and direct. If everything looks good, say so briefly. Do not invent
problems where none exist.

Classify each finding: a **must-fix** is a Risk that would ship a defect — a real
bug, a security hole, or a broken convention the gate would reject. Everything else
is advisory and is buffered into the final report, not fixed here.

## Phase 4: Fix Round or Finalize

Read the one-fix-round latch: `selfReviewFixed` in the session chain-state.

- **If `selfReviewFixed` is false AND there is at least one must-fix finding** — take
  EXACTLY ONE fix round, in this main thread, under the still-active PreToolUse
  phase-gate. For each must-fix: RED test, then IMPL, then GREEN (re-enter the
  `$zensu-tdd` Phase 4 discipline). Then set the latch with
  `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --self-review-fixed` and re-run
  `$zensu-self-review` (pass 2 to confirm). In this branch you MUST NOT:
  - run `--tdd-complete` (implementation is already complete);
  - spawn the `zensu-code-reviewer` subagent — self-review is terminal, so do not spawn it;
  - re-invoke the whole `$zensu-tdd` skill (its Phase 6 tail would re-spawn the reviewer).

- **Otherwise** (no must-fix, OR `selfReviewFixed` is already true) — finalize:
  1. Run `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --chain-done` — this is the chain terminus.
  2. Render the final report (below), then stop.

### Final report

Render a CHAIN-END SUMMARY with these sections (pull from your own context; do NOT
re-spawn any agent):

```
## Implementation Summary
Feature title, files modified, tests created, build status, coverage status. Cite the plan + log paths.

## Review Summary
Final zensu-code-reviewer verdict: PASS / suggestions-only / max-rounds reached. Findings by severity.

## Auto-fix History
For each code-review round 1..N: what was fixed in-thread. Skip this section if zero rounds.

## Self-Review Summary
The self-reflection verdict, the seven-dimension findings, what the single self-review fix round
changed (if any), and any advisory findings buffered (not fixed). State whether a fix round ran.
```

## Strict Scope

- Operate ONLY on the current session and the current worktree. NEVER run
  `git worktree list` or traverse sibling worktrees.
- The latch (`selfReviewFixed`) and the terminus (`--chain-done`) are per-session —
  never touch another session's chain-state.
- Do not fix advisory findings — only a genuine must-fix earns the single fix round.

## Response Style

Terse and concrete. Lead with the reflection buckets, then either the fix-round
status or the final report. No preamble. Reference findings as `file:line`.
