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

## Route Zensu work through the skills
- Run Zensu work (feature CRUD, security, journeys, tiers, bootstrap,
  ghost-scan, pulse, wiki, docs) in the main thread, through the `$zensu-*`
  skills below and the `zensu` CLI. The **`zensu-plm`** subagent only advises
  from project files: it never runs the CLI.
- Spawn a subagent with `spawn_agent`: the role goes in `agent_type` when
  `spawn_agent` lists it, and `task_name` takes lowercase letters, digits and
  underscores only and must be new in the thread, for example
  `task_name: "zensu_plm_1"`. Codex refuses a hyphenated or reused `task_name`.
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
4. By default the workflow runs in **vanilla mode** (strict RED→GREEN is
   opt-in via `hooks.tddImplementation=true`) — ask "Run the Zensu workflow (vanilla implementation + review chain)?"
   instead. `--tdd-begin` echoes the frozen mode (`mode: strict|vanilla`); in
   vanilla mode RED→GREEN and the phase-gate are off (tests at your discretion)
   while the evidence audits and the review chain below stay fully enforced.

## After implementing: run the review chain to completion
When a TDD session finishes implementation, the review chain MUST run before you
end your turn (the Stop hook backstops this):
1. Either spawn the **`zensu-code-reviewer`** subagent (5 perspectives in one
   pass), or fan out five **`zensu-review-aspect`** subagents (one per
   perspective: conventions, bugs, architecture, tests, security) and merge.
   Spawn each one with `spawn_agent` as `$zensu-tdd` Phase 6 step 10 spells
   it: `task_name: "<perspective>_<n>"` for an aspect such as
   `task_name: "conventions_<n>"`, `task_name: "zensu_code_reviewer_<n>"` for
   the reviewer, `fork_turns: "none"`, and the role in `agent_type` only when
   `spawn_agent` lists it and no project role of that name shadows it. `<n>` is
   the lowest number for which none of the round's names exists yet in the
   thread (`list_agents` lists finished agents too), so it never restarts in a
   later chain. Codex refuses a hyphenated or reused `task_name`. On the classic
   surface, where `spawn_agent` takes no `task_name`, leave `task_name` and
   `fork_turns` out and skip `list_agents`.
2. Fix any Critical/Important findings under the session's frozen mode (strict:
   under the still-active gate; vanilla: directly, keeping the evidence
   discipline), then re-run the reviewer until it PASSes or you hit the round
   cap (`hooks.autoFixMaxRounds`, default 5; `$zensu-reset-review-limit` grants more).
3. Finish with `$zensu-self-review` (a final critical self-reflection), which
   owns the chain terminus.

## Configuration
Behavior is tunable via `~/.zensu/config.json` (`hooks.*`, `context.*`,
`logging.timestampStyle`). See the zensu-codex README for the full reference.
