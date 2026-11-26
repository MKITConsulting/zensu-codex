---
name: zensu-pr-fix-findings
description: Fix every open review comment on a GitHub pull request end-to-end — locate the PR, pull the unresolved review threads, triage independent vs dependent work, implement each fix through the Zensu workflow, parallelize independent fixes, push, resolve the threads on the PR, and report back. Use when the user wants to address, fix, or resolve PR review feedback / reviewer findings, or to work through a review.
---

# $zensu-pr-fix-findings

Resolve **every open review comment** on a pull request: implement each fix through
the Zensu workflow, parallelize independent fixes, push, resolve the threads on the
PR, and report back.

## When to Use

- A PR has review comments / change requests you want addressed in one pass.
- You want iterative, repeatable cleanup of review feedback.
- Reviewer left inline findings across several files and the fixes are mostly independent.

Not for: authoring a brand-new review from scratch, or planning unbuilt work (use
`$zensu-bootstrap`).

## Prerequisites

- `gh` CLI authenticated (`gh auth status`).
- Zensu CLI installed and authenticated (`zensu auth status`; `zensu auth login` if needed).
- The current branch has an open PR, or a PR number is supplied as an argument.

## Arguments

- Optional PR number to target. Omitted → the PR for the current branch.

## Procedure

1. **Locate the PR.**
   - With a PR number: `gh pr view <n> --json number,url,state,headRefName,baseRefName`.
   - Otherwise: `gh pr view --json number,url,state,headRefName,baseRefName` (current branch).
   - If no PR exists or `state != OPEN`: stop and report. Never push to a closed/merged PR.

2. **Collect unresolved feedback.**
   - Inline review comments: `gh api repos/{owner}/{repo}/pulls/<n>/comments --paginate`.
   - Unresolved review threads (authoritative for resolution state) via GraphQL —
     `reviewThreads { isResolved, isOutdated, comments { body, path, line, author } }`;
     keep only `isResolved == false`.
   - Top-level review bodies: `gh api repos/{owner}/{repo}/pulls/<n>/reviews`.
   - Build a worklist of actionable items. Skip pure praise, already-addressed, and outdated-and-moot threads.

3. **Triage for parallelism.**
   - Group items by independence. Items touching disjoint files/concerns are
     independent → safe to fix in parallel. Items on the same file/region or with
     ordering dependencies → sequential.
   - When several items are independent, fan them out across parallel subagents (one
     per item or cluster), each returning a patch for files no other item
     touches. A single small item does not need fan-out — fix it inline.
   - Spawn each fix agent with one `spawn_agent` call: `task_name: "fix_<item>"`,
     where `<item>` is the item's worklist number or, for a cluster, its short
     topic lowercased, with every run of characters other than `a-z` and `0-9`
     replaced by `_` (for example `task_name: "fix_3"` for worklist item 3, or
     `task_name: "fix_auth_config"` for a cluster on `auth-config`), and
     `fork_turns: "none"`, because the agent starts without this thread's turns
     and gets everything in its prompt. A fix agent runs as a `default` agent
     under the neutral `host-profile-v1`: while the Zensu hooks are trusted, the
     capability gate denies it the shell, spawning and every path outside the
     project root, and none of its hooked tools reads a file, so do not count on
     it to read the checkout or to run git, the type-check, the tests or
     `$zensu-tdd`. Its prompt therefore carries its item (the review thread with
     the comment body, its path and line), the PR number and head branch
     (`headRefName` from step 1), the path and current text of every file it may
     change, and the result shape from step 4, and it returns its fix as a patch
     against that text instead of applying it. That holds by instruction only:
     the gate still lets it patch files inside the project root through
     `apply_patch`, and in code mode its outer `exec` tool fires no hook. Where
     these limits leave a fan-out nothing to do, fix inline.
     Codex accepts a `task_name` of
     lowercase letters, digits and underscores only, and refuses one already used
     in this thread, even by a finished agent, so call `list_agents` before every
     batch (it lists finished agents too) and append the lowest free `_2`, `_3`,
     … to every name already in use, also when a later loop iteration fixes the
     same item again. The `fix_` prefix keeps these names apart from other skills'
     subagents in the same thread. Where `spawn_agent` takes no `task_name` or
     `fork_turns` (the classic surface), leave them out and skip `list_agents`,
     which only code mode offers.

4. **Implement each fix via the Zensu workflow.**
   - Code changes go through the Zensu workflow (`$zensu-tdd`) so the evidence audit
     + review chain run. For parallel fan-out, record `git status --porcelain`
     before the batch; each agent returns its patch and a structured result
     (files changed, what was fixed, residual risk). When the agents return,
     check that every file you gave an agent still holds the text you put in its
     prompt and that `git status --porcelain` lists no path it did not list
     before. Put back the text of a file an agent changed itself, stop and report
     any other new path instead of deleting it, then apply every patch in this
     thread inside `$zensu-tdd`.
   - After edits: run the relevant type-check / tests. Fix what you broke.

5. **Land the changes.**
   - Re-verify the PR is still OPEN (`gh pr view --json state`) before pushing.
   - Commit with a Conventional Commit message referencing the addressed comments,
     push to the PR branch. Clean commit messages — no watermark / co-author lines.

6. **Resolve the threads.**
   - For each addressed thread: reply to the comment with a one-line note on the fix
     (commit SHA), then resolve it via GraphQL `resolveReviewThread`.
   - Leave threads you could NOT resolve open, with a reply explaining why or what
     decision you need.

7. **Report back.**
   - Summary table: comment → action taken → commit → resolved?
   - Call out anything that needs a human decision, anything skipped, and the
     test / type-check results.

## Loop behaviour

When invoked repeatedly (e.g. under a loop runner): each iteration re-fetches
unresolved threads.

- If **none remain**, report "all review comments resolved" and stop.
- Otherwise address the next batch and continue.

Stop early and ask the user when you hit a fix that needs a product/architecture
decision, an auth error (`zensu auth login`), or a failing gate you cannot satisfy.
