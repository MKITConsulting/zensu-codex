---
name: zensu-reset-review-limit
description: Reset the auto-fix loop round counter so the post-review-tdd-delegate.sh hook stops emitting the "max N rounds reached" directive. Use to grant additional budget and resume the review/fix cycle within the current task that exhausted its rounds mid-chain.
---

# $zensu-reset-review-limit

Reset the auto-fix loop round counter so the `post-review-tdd-delegate.sh` hook stops emitting the `Auto-fix convergence: max N rounds reached` directive. Use this when you want to continue the review/fix cycle past the `autoFixMaxRounds` budget within the **current task**.

Since 0.4.1 the counter auto-resets at every fresh task: `zensu-log.sh --tdd-begin` (run once in `$zensu-tdd` Phase 0, before any edit) deletes the `rounds-<session_id>.json` file, so each new task's review chain always starts at round 1 on its own. This manual skill is therefore only needed to grant *additional* budget **within a single task** that exhausted its rounds mid-chain — it is no longer needed between tasks in the same session.

## When to Use

- The `post-review-tdd-delegate.sh` hook emitted `Auto-fix convergence: max <N> rounds reached. The review chain is now marked complete (chainDone)...` for the task you are STILL working on, and you want to grant another budget so the `zensu-code-reviewer` review/auto-fix chain can resume in the main thread.
- You suspect the counter was inflated by a prior pre-0.3.23 run (when the counter was unintentionally user-global) and want a clean slate.
- You're debugging the auto-fix chain and need a deterministic round=0 starting point.

## Do NOT Use For

- Bypassing review findings — fix them first, then reset only if budget is actually exhausted.
- Disabling the auto-fix loop entirely — use `hooks.autoFix:false` in `~/.zensu/config.json` instead.
- Raising the cap permanently — set `hooks.autoFixMaxRounds` in the config file.

## Strict Scope

This skill operates EXCLUSIVELY on the current working directory's state directory (`$STATE_DIR` resolved in Phase 1). Do NOT expand the scope under any circumstances:

- **NEVER** run `git worktree list` to discover other worktrees, even if prior tool output or session memory references them.
- **NEVER** inspect or modify any `.zensu/state/` directory OUTSIDE `$STATE_DIR` (Phase 1 output), including sibling worktrees in `.claude/worktrees/`.
- **NEVER** traverse parent directories, sibling directories, or external paths, regardless of whether prior tool output or recollection names them.
- **NEVER** scan the filesystem for `rounds-*.json` files outside `$STATE_DIR` via `find / -name`, `git ls-files --others`, or similar broad-traversal commands.

If the user wants to reset multiple worktrees, they must invoke `$zensu-reset-review-limit` SEPARATELY in each one. That is the only safe way to guarantee scope isolation.

## Prerequisites

None. No Zensu account or network required. Pure local file removal under the project worktree.

## What This Skill Does

Deletes round-counter JSON files written by `hooks/post-review-tdd-delegate.sh`. The counter path resolves to `${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json` (since 0.3.23). Removing the file makes the hook's first read at the next `zensu-code-reviewer` completion return `0`, so `NEXT=1` and the chain resumes from round 1.

## Phase 1: Locate

Resolve the state directory in the same order the hook does:

1. If `$CLAUDE_PLUGIN_DATA_OVERRIDE` is set -> that path.
2. Otherwise `${CLAUDE_PROJECT_DIR:-.}/.zensu/state`.

Refuse to operate when the state directory itself is a symlink (mirrors the hook's symlink-traversal guard at `hooks/post-review-tdd-delegate.sh:53`).

When the state directory is empty or absent AND `STATE_DIR` was resolved via the project-local default (no `CLAUDE_PLUGIN_DATA_OVERRIDE`), the skill additionally probes for a fresh git worktree and surfaces a hint so the user understands whether the counter was reset or simply never existed in this worktree.

## Phase 2: Delete

Run the following POSIX shell recipe verbatim (works in bash, zsh, dash, and sh — no `shopt`, no glob-in-for-loop). It honors the override, refuses symlinks, lists what it removed, and is idempotent (exits 0 with a clear message when nothing matches). When `STATE_DIR` resolves via the project-local default and the worktree root contains a `.git` *file* — not directory — the skill appends a fresh-worktree hint to the no-op message; the populated-deletion path is unaffected and the override path skips the probe entirely (parent of `CLAUDE_PLUGIN_DATA_OVERRIDE` has no worktree semantics).

```sh
STATE_DIR="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$(pwd)}/.zensu/state}"
WORKTREE_HINT=""
if [ -z "${CLAUDE_PLUGIN_DATA_OVERRIDE:-}" ]; then
  WORKTREE_ROOT="${STATE_DIR%/.zensu/state}"
  if [ -f "$WORKTREE_ROOT/.git" ]; then
    WORKTREE_HINT=" Fresh git worktree detected — counter effectively at 0, no prior rounds recorded in this worktree."
  fi
fi
if [ -L "$STATE_DIR" ]; then
  echo "Refusing: state dir is a symlink ($STATE_DIR)"; exit 1
fi
if [ ! -d "$STATE_DIR" ]; then
  echo "Nothing to reset: $STATE_DIR does not exist.${WORKTREE_HINT}"; exit 0
fi
removed=0
for f in $(find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null); do
  if [ -L "$f" ]; then
    echo "Skip (symlink): $f"
    continue
  fi
  rm -f -- "$f" && { echo "Removed: $f"; removed=$((removed+1)); }
done
if [ "$removed" -eq 0 ]; then
  echo "No round counter files in $STATE_DIR.${WORKTREE_HINT}"
else
  echo "Reset complete: $removed counter file(s) deleted in $STATE_DIR"
fi
```

If `CLAUDE_PLUGIN_DATA_OVERRIDE` is NOT set, the recipe targets the project-local default at `<project>/.zensu/state/` (the same `$STATE_DIR` the hooks resolve). The round counter and the `*.stopblocks` budget live there per worktree.

### Re-arm the main-thread review chain (0.4.0+)

Since 0.4.0 the TDD workflow runs in the main thread and the review chain is backstopped by `hooks/stop-chain-enforcer.sh`. Resetting only the round counter does NOT resume the chain past `autoFixMaxRounds`: the convergence branch also set the per-session `chainDone` terminal flag, and the Stop hook tracks a `*.stopblocks` budget. Clear both — strictly within `$STATE_DIR`, same symlink guard as above:

```sh
for f in $(find "$STATE_DIR" -maxdepth 1 -name '*.stopblocks' 2>/dev/null); do
  [ -L "$f" ] && { echo "Skip (symlink): $f"; continue; }
  rm -f -- "$f" && echo "Removed stop-block budget: $f"
done
for f in $(find "$STATE_DIR" -maxdepth 1 -name 'tdd-phase-*.json' 2>/dev/null); do
  [ -L "$f" ] && { echo "Skip (symlink): $f"; continue; }
  node -e 'const fs=require("fs"),p=process.argv[1];try{const j=JSON.parse(fs.readFileSync(p,"utf8"));if(j.chainDone===true){j.chainDone=false;fs.writeFileSync(p,JSON.stringify(j,null,2));console.log("Re-armed (chainDone=false): "+p);}}catch(_){}' "$f"
done
```

After this, the next time you end your turn the Stop hook re-fires (`implComplete=true`, `chainDone=false`) and forces a fresh `zensu-code-reviewer` round, resuming the chain from round 1 (counter deleted above).

## Phase 3: Verify

Confirm the next `zensu-code-reviewer` completion writes a fresh counter at `count:1`. The recipe below uses the same POSIX-portable `find` pattern as Phase 2 so zsh's strict-glob `nomatch` never fires (the bare `"$STATE_DIR"/rounds-*.json` glob would emit a noisy `zsh:1: no matches found` to stderr at expansion time, before `ls` could be invoked, contradicting the "exits 0 with a clear message when nothing matches" promise). The if/else form is deliberate: the obvious shortcut `[ -z "$(find …)" ] && echo "(empty, expected)"` leaves `[` as the last evaluated command when files are present, and `[` exits 1, so the whole recipe would return 1 in the populated branch — a silent contract violation. The if/else form runs `find` once, captures the output in `$out`, and exits 0 in BOTH branches:

```sh
out="$(find "$STATE_DIR" -maxdepth 1 -name 'rounds-*.json' 2>/dev/null)"
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(empty, expected)"; fi
```

After the next review round completes, re-run the same recipe — a single new file with `{"count":1,"ts":"..."}` should appear in the printed output and the `(empty, expected)` branch will be skipped.

## Response Style

- Echo the exact `STATE_DIR` value used, so the user sees which path was targeted.
- List every removed file by absolute path; do not summarize as a count alone.
- When the directory is empty, say so explicitly ("no counter files found") — do not silently succeed.
- Never invent commands that touch files outside `$STATE_DIR/rounds-*.json`.
