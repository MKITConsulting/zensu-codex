---
name: zensu-reset-review-limit
description: Reset the current Session Control review budget transactionally so the review/fix chain can resume after autoFixMaxRounds.
---

# $zensu-reset-review-limit

Grant the current task another review/fix budget after the chain reached
`autoFixMaxRounds`. The counters are `reviewRound` and `stopBlocks` fields in
the same validated, revisioned `tdd-phase-scv1_….json` document as the workflow
FSM. There are no counter sidecars to find, delete, or repair.

## Safety contract

- Operate only on the exact `ZENSU_SESSION_KEY` injected by Session Control v1.
- Resolve plugin and project roots through immutable reader ABI v3. Never scan
  `.zensu/state`, sibling worktrees, session records, or home directories.
- Never edit workflow JSON directly. One shared CAS mutation resets both
  counters and all three completion flags, advancing `revision` exactly once
  under the per-session lock. A failed precondition changes no bytes.
- Abort on a missing/invalid context, wrong principal, inactive workflow,
  symlink, malformed state, runtime-digest drift, or transactional failure.
- This grants budget; it never suppresses findings or disables review.

## Transaction

Run this recipe once in the main thread. Replace `<exact injected key>` only
with the key already present in trusted SessionStart context:

```sh
export ZENSU_SESSION_KEY='<exact injected key>'
CONTEXT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --context)" || exit 1
case "$CONTEXT" in *'principal=main-v1'*) ;; *) echo 'Refusing: main-v1 context required'; exit 1 ;; esac
PLUGIN_ROOT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --root)" || exit 1
PROJECT_ROOT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --field project_root)" || exit 1
case "$PLUGIN_ROOT$PROJECT_ROOT" in *$'\n'*|'') echo 'Refusing: unsafe Session Control binding'; exit 1 ;; esac
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
. "$PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$ZENSU_SESSION_KEY")" || exit 1
[ "$(tdd_state_status "$STATE_FILE")" = valid ] || { echo 'Refusing: invalid workflow state'; exit 1; }
[ "$(tdd_session_active "$STATE_FILE")" = true ] || { echo 'Refusing: workflow is not active'; exit 1; }
[ "$(tdd_impl_complete "$STATE_FILE")" = true ] || { echo 'Refusing: implementation is not complete'; exit 1; }
REV_BEFORE="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).revision))' "$STATE_FILE")" || exit 1
tdd_reset_review_budget "$ZENSU_SESSION_KEY" "$REV_BEFORE" >/dev/null || exit 1
REV_AFTER="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).revision))' "$STATE_FILE")" || exit 1
[ "$(tdd_get_counter "$STATE_FILE" reviewRound)" = 0 ] || exit 1
[ "$(tdd_get_counter "$STATE_FILE" stopBlocks)" = 0 ] || exit 1
[ "$(tdd_chain_done "$STATE_FILE")" = false ] || exit 1
[ "$(tdd_code_review_done "$STATE_FILE")" = false ] || exit 1
[ "$(tdd_self_review_fixed "$STATE_FILE")" = false ] || exit 1
[ "$REV_AFTER" -eq $((REV_BEFORE + 1)) ] || { echo 'Refusing: unexpected revision advance'; exit 1; }
printf 'Review budget reset transactionally for %s (revision %s -> %s).\n' "$ZENSU_SESSION_KEY" "$REV_BEFORE" "$REV_AFTER"
```

The next Stop event sees `implComplete=true`, `chainDone=false`, and a zeroed
budget, so it requires a fresh reviewer round. Report the exact session key hash
and revision transition, but never print a raw host session identifier or scan
for other sessions.
