# Zensu PLM — operating conventions

Zensu is a Product Lifecycle Manager that makes **features first-class citizens**
across the whole software lifecycle. When working in a project that uses Zensu,
follow these conventions. (Installed by `zensu-codex`; the typed `zensu` CLI,
the `zensu-*` skills, and the `zensu-*` subagents are available. Run
`zensu auth login` once if a command returns an auth error.)

## Core model
- **Products** own **Components** (domain modules), **Tiers** (pricing levels),
  **Features**, and **User Journeys**.
- **Features** carry `ZEN-XXX` IDs (e.g. `ZEN-001`). Reference them in commit
  messages as `[ZEN-001]`. Status lifecycle: `planned → in-progress → testing →
  released`, gated by security score (0–10), docs completeness, and journey health.
- Per-feature build-out has two axes: **revisions** (`zensu features revision`, v1/v2…,
  stages over time) and **subfeatures** (`zensu subfeatures add`, structural parts).

## Route Zensu work through the agent and skills
- For ANY interaction with the `zensu` CLI (feature CRUD, security,
  journeys, tiers, bootstrap, ghost-scan, pulse, wiki, docs), use the
  **`zensu-plm`** subagent — it enforces workflow conventions and command ordering.
- Skills (invoke with `$name`):
  `$zensu-bootstrap` (greenfield) · `$zensu-ghost-scan` (brownfield) ·
  `$zensu-implement` · `$zensu-tdd` · `$zensu-plan-review` ·
  `$zensu-security-review` · `$zensu-self-review` · `$zensu-reset-review-limit` ·
  `$zensu-pulse` · `$zensu-help` (Q&A).
- Never guess feature IDs — `zensu features list` or ask. Status transitions use
  `zensu features status <id> <new-status>`, not `zensu features update`. Set
  security classification before coding.

## Code changes: plan, then ask about TDD
For any task that adds or modifies executable code:
1. Plan the change first.
2. **Before implementing, ask the user whether to run the strict TDD flow**
   (`$zensu-tdd`). Skip the question only for: doc-only changes, an explicit TDD
   preference the user already stated, or a non-interactive run.
3. On **yes**: run `$zensu-tdd` — strict RED→GREEN, one step at a time. The
   PreToolUse phase-gate blocks production edits until a failing test exists for
   the step; declare each phase with `zensu-log.sh --phase …`. On **no**:
   implement directly.

## After implementing: run the review chain to completion
When a TDD session finishes implementation, the review chain MUST run before you
end your turn (the Stop hook backstops this):
1. Either spawn the **`zensu-code-reviewer`** subagent (5 perspectives in one
   pass), or fan out five **`zensu-review-aspect`** subagents (one per
   perspective: conventions, bugs, architecture, tests, security) and merge.
2. Fix any Critical/Important findings under the still-active gate, then re-run
   the reviewer until it PASSes or you hit the round cap
   (`hooks.autoFixMaxRounds`, default 5; `$zensu-reset-review-limit` grants more).
3. Finish with `$zensu-self-review` (a final critical self-reflection), which
   owns the chain terminus.

## Configuration
Behavior is tunable via `~/.zensu/config.json` (`hooks.*`, `context.*`,
`logging.timestampStyle`). See the zensu-codex README for the full reference.
