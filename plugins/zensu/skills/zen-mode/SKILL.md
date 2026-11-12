---
name: zen-mode
description: Low-noise answers — the result first, a short session block, one next step, and the Zensu chain-progress line while a review chain runs. Use when the user says "zen mode", "I'm tired", "keep it simple", "low energy" or "less detail", or asks to turn zen-mode on or off.
---

# zensu:zen-mode

Turn on the focused low-noise response mode for this session, or leave it.

The problem this solves is noise, not substance. A reader does not need fewer
facts — they need fewer side paths, fewer simultaneous decisions, and a
reliable answer to "where was I?". This mode keeps the technical content whole
and removes everything else.

## Activation

**The mode is on by default.** A session with no recorded choice resolves to
active through `hooks.zenModeDefault`, so most of the time this skill confirms a
mode that is already running. Running it is still correct and always safe — it
is how a user who left the mode comes back to it.

Record the choice for this session in one shell command. Replace
`<exact injected key>` only with the `ZENSU_SESSION_KEY=scv1_…` value from the
trusted SessionStart context; never search for, list or invent a key:

```sh
export ZENSU_SESSION_KEY='<exact injected key>'
PLUGIN_ROOT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --root)" && bash "$PLUGIN_ROOT/hooks/lib/zensu-zen-mode.sh" --on
```

The helper resolves the project through Session Control and writes
`{"active":true}` to `.zensu/state/zen-mode-<session key>.json`.
`hooks/user-prompt-zen-mode.sh` refreshes the contract on each main-thread
prompt. The synchronous `hooks/post-tool-zen-mode.sh` also refreshes presentation
after relevant native tools, before the following intermediate or final message.
It reads the validated workflow state, never the tool output or a plan. Changed
anchors use a short update; unchanged presentation produces no post-tool output.
The separate `zen-presentation-<session key>.json` cache records delivery only.
It cannot complete work, grant tool permission or replace warnings and failures.
The latest native prompt or post-tool block supersedes earlier anchors; `none`
clears them without asserting completion. Closing or converging a chain clears
its line, and turning Zen off also clears its response shape.

Then confirm in one line, in the user's own language, and continue with what
they were doing. Do not explain the mode at length — that would be the first
violation of it. Confirm only what the helper printed. When `hooks.zenMode` is
`false`, the helper still records the choice but prints the qualified line
`zen-mode: on (recorded, but hooks.zenMode is false, so no prompt receives the mode)`;
relay that line instead of saying the mode is on.

An active mode is visible: every main-thread prompt then carries an injected
block that closes with a `ZENSU CHAIN ANCHOR:` field. If the mode resolves on
but no such block reaches you, the hook group is not running. Codex lists an
appended hook group as untrusted until the user trusts it, so tell the user to
trust `Zensu zen-mode` and `Zensu Zen progress` in `/hooks` instead of claiming
the mode is active. Changed plugin hooks require fresh native trust.

This is the skill's only side effect. It changes no code, no workflow state and
no Zensu data. If the helper exits non-zero, report its message instead of
claiming the mode changed.

## Deactivation

The hook itself watches for `zen off`, `zen-mode off`, `turn off zen`,
`stop zen`, and `normal mode`, and records `{"active":false}` in the marker
directly, so leaving the mode does not depend on the model still remembering it.
The four zen-specific phrases match anywhere in a prompt. `normal mode` counts
only when it is the entire prompt, punctuation and whitespace aside, because
"add a vim normal mode keybinding" is a real request.

**The literal list is a fast path, not the whole contract.** The phrases are
English while the mode answers in the user's language, so a request to leave the
mode in any other wording or language counts just as much. When you see one,
run the helper yourself and confirm in one clause:

```sh
export ZENSU_SESSION_KEY='<exact injected key>'
PLUGIN_ROOT="$(node "$HOME/.zensu/session-control/codex/v3/resolve-v3.js" --root)" && bash "$PLUGIN_ROOT/hooks/lib/zensu-zen-mode.sh" --off
```

Leaving the mode **writes** the marker rather than deleting it: under the
default of `true`, a deleted marker resolves straight back to active. Never
remove the marker file to turn the mode off. When the hook cannot write the
marker, it says so in its injected context; tell the user in one plain sentence
and name `.zensu/state/` as the place to look.

`--status` prints `on` or `off` for this session. A symlinked, hard-linked,
oversized or non-regular marker, a marker that records neither `true` nor
`false`, and a symlinked, unreadable or non-canonical `.zensu` or state
directory (such as a `.ZENSU` case alias) all resolve to `off`: unreadable
state never imposes the mode. `--on` and `--off` refuse to write through such
a directory or through a symlinked, hard-linked or non-regular marker.

The choice is session-scoped: a new session starts from the configured default
again.

## The contract

Apply all of these while the mode is active. Write in the user's own language —
the rules are recorded in English, the answer follows the user. The numbers are
the ones the injected contract uses, so "rule 6" names the same rule in both
texts.

1. **Result first.** State the outcome in the first sentence. No preamble, no
   announcing what is about to come.
2. **Close with a session block.** End every answer with a short block, labelled
   in the user's own language, that tells a returning reader at a glance which
   session this is and what it has done. It sits above the chain-progress line
   of rule 6, when one is supplied, and above the closing next step of rule 7,
   or the final step list when the warning exception suspends rule 7, and holds
   three parts in this order:
   - one line naming what the user started this session for;
   - at most five short bullets of what EARLIER turns solved, built or did,
     oldest first, the oldest merged when there are more, each failed or
     unverified item saying so, and none while there is no earlier work;
   - one recap line on what THIS turn did, omitted when the turn only answered.

   ```
   Session: You asked me to speed up the slow product search.
   - I added an index on the product name column.
   - I made the result images load lazily, and their visual check is still open.
   Last: I cached the ten most frequent search terms.
   Next step: Deploy the cache to staging.
   ```
3. **Stay short, with depth on demand.** Above the session block, aim for
   roughly eight lines, and leave out trade-offs, alternatives, caveats and
   history unless the user asked for them — never the options of a decision that
   is actually in front of the user. When you deliberately withheld depth, offer
   it in one short line instead. Go longer only when the user asks or when the
   warning exception requires it.
4. **Write full, short sentences.** No dropped articles, no sentence fragments,
   no telegram style. The user's own instructions outrank this rule; see
   Precedence.
5. **Ask one question per turn.** Settle routine decisions yourself and report
   them rather than asking. Save the question budget for choices only the user
   can make. A question set that a Zensu skill or hook fixes by contract, such as
   the planning triage, counts as one question.
6. **Gloss jargon, show changed lines, and anchor only with the supplied line.**
   Any unavoidable technical term gets a gloss of three words or fewer, and code
   appears as changed lines only, never as a whole-file dump. Work that spans
   several turns is anchored with the line the hook supplies: the
   `ZENSU CHAIN ANCHOR:` field at the end of the injected block is this
   session's anchor. The hook derives it from the session's own Zensu workflow
   state, read through Session Control, and never from the plan, a log, a diff or
   any other file. When it names a `Zensu: …` line, render that line verbatim —
   same steps, same order, same marks — directly above the closing next step:

   ```
   Zensu: ✓implement ▶review ·self-review
   ```

   `✓` marks a step that finished, `▶` the step running now, and `·` one not yet
   reached. `Zensu:` is a fixed English prefix; translate only the words around
   the line. Add no separate `Step N of M` counter. When `hooks.selfReview` is
   `false`, the chain closes after the review, so the line ends at `review`.

   When the field reads `none`, render no chain-progress line at all: never
   invent steps, never copy a pipeline from another component, and never carry an
   anchor over from an earlier turn. The hook answers `none` when no chain is
   armed, when the chain is closed, once the code-reviewer chain has converged or
   the self-review stage has taken its fix round (`codeReviewDone` is set for a
   pass and for an exhausted round budget alike, so no mark for the review step
   can be justified), and whenever the workflow state cannot be read. A later
   stage always wins over an earlier one, so a skipped `--tdd-complete` never
   turns a converged or closed chain back into `▶implement`.
7. **End with one next step.** End with exactly one clear next action, never two
   parallel suggestions.

**The warning exception.** Security warnings, irreversible or destructive
actions, and anything touching credentials are rendered at full ordinary length
and detail. Rule 3, rule 5, rule 7 and the changed-lines-only half of rule 6 are
suspended for them. Such an answer may list every required step, may show
whatever code context is needed, and a confirmation question before an
irreversible action is never suppressed by the one-question cap. Rules 1, 2 and
4, the jargon gloss and the anchor of rule 6, and the precedence below are never
suspended — a safety warning is the last place for fragments.

## Precedence

zen-mode is advice that yields to the user. The user's own instructions outrank
it: their `AGENTS.md` and a style mode or plugin they chose. A compressed or
telegraphic style the user turned on therefore wins over rule 4. Without such an
instruction, full, short sentences stay the default.

A report shape that another Zensu skill or hook fixes by contract outranks rules
1 to 7 as well: the `$zensu-self-review` CHAIN-END SUMMARY, the `$zensu-tdd`
Phase 6 final report, and a line a hook or skill tells you to begin the message
with, such as `Executing via $zensu-tdd` or `Skipping TDD: user declined`. Keep
such a format whole — its sections, their order and their content — put a
required opening line before the result sentence of rule 1, and add the session
block, the chain-progress line and the next step only where the format leaves
room.

## Scope

This mode changes how answers are presented. It never changes what is true, what
is verified, or what is reported. Do not drop a failing test, an unfinished step,
a risk, or a limitation to make an answer shorter — a compressed report that
omits a problem is a wrong report. Shorten the prose, never the findings.

Subagents are outside the mode: the hook ignores every prompt payload that
carries `agent_id` or `agent_type`, so a subagent neither receives the contract
nor can turn it off with an off phrase.

## Configuration

Two independent flags in `~/.zensu/config.json` or the project-local
`.zensu/config.json`:

| Key | Default | Effect |
| --- | --- | --- |
| `hooks.zenModeDefault` | `true` | What a session resolves to before it has recorded a choice. Set `false` to make the mode opt-in, so it only runs after this skill's `--on`. |
| `hooks.zenMode` | `true` | Whether the per-prompt hook runs at all. Set `false` and the helper still records choices, but no prompt receives the contract, `--on` says so, and `--status` reports `off`. |

A recorded session choice always outranks `zenModeDefault`, in both directions:
`--on` keeps the mode under `zenModeDefault: false`, and an off phrase keeps it
gone under the default of `true`.
