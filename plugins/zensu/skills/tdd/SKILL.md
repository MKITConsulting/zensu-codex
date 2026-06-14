---
name: zensu-tdd
description: Execute a feature specification with strict Red/Green Test-Driven Development in the main thread — write the tests, run them, implement, and verify yourself under a PreToolUse phase-gate, then run a guaranteed code-review chain. Use after a plan adds executable code, when $zensu-implement hands off a feature spec, or when invoked directly with a feature specification.
---

# $zensu-tdd

Execute a feature specification with strict Red/Green Test-Driven Development **in the main thread**. You write the tests, run them, implement, and verify yourself — the work is NOT delegated to a subagent (that lost too much implementation context). After implementation the auto-review chain fans out five read-only `zensu-review-aspect` subagents (one per perspective), merges their findings in this thread, and consolidates through a single `zensu-code-reviewer` spawn that routes the findings back to you to fix in-thread.

## Mandatory command protocol (read this FIRST, follow on every step)

The phase-gate and the witness only see these shell commands — prose compliance
does not count. `{PLUGIN_ROOT}` is resolved in Phase 0 (`cat ~/.zensu/plugin-root`).

1. **Arm once, before any edit**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --tdd-begin`
   Until this runs the gate and witness are silent and the session records ZERO
   discipline evidence — TDD without arming is a protocol violation.
2. **Declare every phase BEFORE acting — `--step <id>` is REQUIRED on every marker**:
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_WRITE --step <id>` → then write the test
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_RUN --step <id>` → then run it
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_FAIL --step <id> --reason "..."` → on the confirmed failure
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase IMPL --step <id>` → then edit production code
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_RUN --step <id>` → then run the test
   - `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_PASS --step <id>` → on PASS
   A marker without `--step` records step `(none)`, and the gate matches IMPL
   against a prior RED_FAIL **per step id** — a mismatch means your write is DENIED.
3. **Finish**: `--tdd-complete` arms the review-chain Stop backstop; `--chain-done`
   is owned by `$zensu-self-review` — NEVER run both in the same turn.

Full details (work types, planning, logging, review chain) follow below — the
command sequence above is non-negotiable on every step.

## When to Use

- After the user approves a plan that adds executable code, the plan-approval hook (`plan-approved-delegate.sh`) asks the user whether to run the TDD flow and directs you here when they confirm (or on its fast-paths: an explicit TDD affirmation in the approval message, or non-interactive auto mode).
- `$zensu-implement` Step 3 hands you a feature specification built from the Zensu feature + security context.
- A user invokes `$zensu-tdd` directly with a feature spec.

Provide a FEATURE SPECIFICATION as the input. Describe WHAT needs to be built, not HOW.

## Main-thread model (read first)

- **You are the implementer.** Run Phases 0–6 below in this conversation. Do NOT spawn a `tdd-manager` subagent — that agent no longer exists.
- **The discipline hooks enforce YOU.** The PreToolUse phase-gate (`pre-edit-tdd-reminder.sh`) and the Bash witness (`post-bash-witness.sh`) activate on a per-session chain-state flag, set by `--tdd-begin` in Phase 0. Until you call `--tdd-begin` they are silent; after it, edits are gated to the declared TDD phase exactly as a subagent would have been.
- **The review chain is mandatory (you drive it on Codex).** When you finish Phase 6 you mark `--tdd-complete`, spawn the `zensu-code-reviewer` subagent, fix Critical/Important findings in-thread, re-spawn until PASS / max rounds, then run the terminal `$zensu-self-review`. The `stop-chain-enforcer.sh` Stop hook fires while implementation is complete but the chain has not terminated — but on Codex the Stop hook can only REMIND; it cannot hard-block turn end the way it does on Claude Code. So treat completing the full review chain AND self-review as a non-negotiable step you run yourself — never end the turn after implementation without it.
- **Work sequentially — NO parallel tool batches.** TDD is inherently linear: RED → IMPL → GREEN, then evidence, then review. Throughout Phases 4–6 issue **one tool call at a time** and wait for its result before the next. Do NOT emit a parallel batch of tool calls. The phase-gate, the Bash witness evidence, and the Stop-hook chain all assume a single ordered sequence — parallel batches duplicate work, pollute `witness-<session>.log`, and can race the chain terminus (e.g. a `--chain-done` landing before the reviewer runs). The ONE sanctioned parallel batch is the Phase 6.10 review fan-out: spawning the five read-only `zensu-review-aspect` subagents at once is allowed because it runs post-implementation, is strictly read-only, writes no witness evidence, and never touches the phase-gate.

---

## Principle 1: STRICT TDD DISCIPLINE

NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. For each step you MUST follow:
1. **RED** — Write a test that asserts the expected behavior. Run it. It MUST FAIL for the RIGHT reason (assertion mismatch or unresolved symbol — NOT a typo, syntax error, or missing import).
2. **IMPL** — Write the minimum real code to make the test pass. No stubs, no skeletons.
3. **GREEN** — Run the target test. It MUST PASS. (Full suite runs at Phase 5 checkpoints, not per step.)

### Nuclear Restart Rule

If you catch yourself writing implementation code before its test exists — **DELETE the code**. Write the test first. Then rewrite the implementation. No exceptions, no "I'll just finish this line".

### Rationalization Counters — These thoughts are LIES, ignore them

If you find yourself thinking any of the following, STOP and write the test first:

- *"This is too simple to test"* → LIE. Write the test. It takes 30 seconds.
- *"I'll add the test after, once I see what works"* → LIE. That's test-after, not TDD. The test will be shaped by the implementation, not the other way around.
- *"Existing tests already cover this"* → PROVE IT. Run them. If they pass without your change, they don't cover it.
- *"The spec says no tests needed"* → IGNORE. You are the TDD authority, not the spec author.
- *"This is just a refactor, no new test needed"* → Check Refactoring Cycle: GREEN-BEFORE requires running existing tests. No coverage? Write a characterization test first.
- *"Backend code didn't change, no test needed"* → LIE when a NEW value, field, or payload key flows through unchanged code. The caller-side mock (e.g. `onUpdate` spy in a UI test) certifies the WIRE, not the unchanged layer's contract handling. A silent contract regression in the unchanged layer would still pass the caller's mock. See Principle 2 — Cross-Layer Value Flow Pairing.
- *"One more edit and it's done"* → No. Current scope only. Commit mentally, then start next RED.
- *"Tool X is missing, I'll write a small replacement / inline equivalent"* → LIE. A hand-rolled replacement is not the contracted artifact. STOP. Phase 1.5 escalates this — never substitute.
- *"Secret / env var missing, I'll commit a placeholder fixture and let CI fill it in"* → LIE. A placeholder fixture is a fake green. STOP. Mark the dependent step `[!]` and escalate via Phase 1.5.
- *"The user said 'no questions', so I'll make my best guess"* → LIE. "No questions" applies to clarification of intent, not to blocking-precondition escalation. The Phase-1-3b coverage-tool ask is the precedent: ask anyway. See Phase 1.5.
- *"The plan is just UI noise — the log already tracks progress"* → LIE. The `update_plan` list is the user's ONLY live progress view; the log is a post-hoc file they must `tail`. Skipping `update_plan` updates leaves the user blind to where you are. Create the step plan items in Phase 3, flip their status in Phase 4 — same discipline as the log.

### Hard Bans

NEVER implement before writing the RED test. NEVER skip the GREEN verification. NEVER modify a test after the implementation passed (that's rewriting history, not TDD). NEVER use `git stash`. NEVER edit files in `~/.codex/`. NEVER substitute a missing required dependency (CLI, secret, fixture, service endpoint) with a hand-rolled equivalent, mock, or placeholder unless the user has explicitly approved the substitution via Phase 1.5 escalation. NEVER search the filesystem to "discover" the zensu-log.sh helper — use the Phase 0 plugin-root resolution; if it fails, abort with the FATAL message.

If a step seems too simple for TDD (i18n, config), fold it into a related testable step's IMPL. If spec says "not testable", find a seam (extract function, inject dependency). If truly non-testable (wiring, migration), mark as `[W]` integration — but the wiring must still be VERIFIED by running the caller's tests.

## Principle 2: WORK TYPES (per step)

Classify EACH step. A single task may mix types.

**Feature** (default): RED → IMPL → GREEN. Status: `[G]`
**Refactoring** (same behavior): GREEN-BEFORE → CHANGE → GREEN-AFTER. Status: `[RF]`. Verify tests cover the affected code first — if not, write a behavior-preserving test.
**Bug Fix**: RED-REPRO → FIX → GREEN. Status: `[G]`
**Integration** (wiring, config, migrations): Direct implementation, no test cycle. Status: `[W]`

Merge steps ONLY if (a) their test files share setup code that should only be written once, or (b) they are technically inseparable (same class, same method). NEVER as a logging shortcut. Each merged step still requires its own RED log entry with that step's specific failure reason. When merging N steps you log N RED entries + 1 IMPL entry + N GREEN entries.

### Cross-Layer Value Flow Pairing (MANDATORY)

When a Feature/Bug-Fix step routes a NEW value, field, payload key, or query parameter through an UNCHANGED adjacent layer, you MUST add a paired **Characterization step** (`[G]`, Feature work type) in the unchanged layer that runs BEFORE the originating step. The Feature step's `depends_on` MUST list the Characterization step.

**Examples of the trigger:**
- Frontend dialog adds `project_id` to an update payload consumed by an existing Rust `update_appointment` command → pair with a Rust characterization that asserts `SELECT project_id FROM appointments WHERE id = ?` returns the new value after `update_appointment` runs.
- New column written by an existing repository call → pair with a repository test asserting the column round-trips.
- New query parameter read by an existing HTTP handler → pair with a handler test asserting the parameter changes the response.
- New gRPC field added to a request the existing server already deserializes generically → pair with a server-side test asserting the field is honored.

**Non-triggers (no pairing needed):**
- Pure UI change (label text, color, icon) — no value crosses a layer.
- Value never crosses a process / persistence / network boundary.
- Target layer already has an IMPL step in THIS plan (its own RED→GREEN covers the new value).
- An existing test in the target layer already asserts the new field round-trip. **Verify by reading the test, not by assumption** — `grep` for the field name in the target layer's test files; if no assertion exists, pairing is required.

**The characterization MUST assert at the unchanged layer's OWN seam** — DB row contents, returned struct, network response body, persisted file — NOT at the caller's mock. A `vi.fn()` / `mockReturnValue` at the caller boundary certifies the wire only; it cannot detect a silent contract drop in the unchanged consumer.

**Rationale:** Per-step RED→GREEN tests only code the agent writes. Phase-5 full-suite catches regression of EXISTING assertions — if no test ever asserted the new value's round-trip, there is nothing to regress. Skipping this pairing produces silent fullstack-contract regressions invisible to both per-step RED→GREEN and the Phase-5 safety net.

Detection happens in Phase 1 step 6 (planning) and is audited in Phase 6 step 6b.

## Principle 3: THREE-CHANNEL STATUS

After completing each cycle phase (RED, IMPL, GREEN):
1. **Log** — `printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "..." >> {log_file}` — the helper resolves `~/.zensu/config.json`'s `logging.timestampStyle` to the inline prefix (`wall` default, `relative`, or `none`). Never inline `$()` for the timestamp itself; always call the helper. Throughout this skill `{log_file}` denotes the **cwd-independent** path `"${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{SESSION_TS}_tdd-{slug}.log"` — always anchored to `${CLAUDE_PROJECT_DIR:-.}` (never bare-relative) so every `>> {log_file}` append succeeds regardless of the current working directory.
2. **Plan items (MANDATORY)** — the user's live progress dashboard, tracked with Codex's `update_plan` tool. Mark a plan item `in_progress` when starting a cycle phase, `completed` when done. Every step created in Phase 3 must reach `completed`. See the Per-Step Plan Contract below.
3. **Plan doc** — batch-update at checkpoints and final report only
4. **Phase-marker** (FSM, enforced by PreToolUse gate) — before any Edit/Write/MultiEdit, declare the current TDD phase via:
   `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase <PHASE> --step <step_id> [--reason "..."]`
   Valid `<PHASE>` values: `RED_WRITE`, `RED_RUN`, `RED_FAIL`, `IMPL`, `GREEN_RUN`, `GREEN_PASS`, `REFACTOR`. The marker is written to `.zensu/state/tdd-phase-<session>.json`; the log-line format above is unchanged. The PreToolUse gate (`hooks/pre-edit-tdd-reminder.sh`) blocks edits that don't match the FSM: in particular `IMPL` requires a prior `RED_FAIL` for the same step. The gate is active because Phase 0 set the chain-state `active` flag for this session. Set `ZENSU_TDD_GATE=off` only for legitimate non-TDD edits explicitly authorized by the user.

### Per-Step Logging Contract (MANDATORY)

For each Feature/Bug-Fix step, the log file MUST contain three entries with these EXACT prefixes:
  1. `{step_id} RED {test_name} — FAIL: {reason}` (after Phase 4 A)
  2. `{step_id} IMPL completed — files: {file_list}` (after Phase 4 B)
  3. `{step_id} GREEN — PASS ({attempts} attempts, {test_count} tests)` (after Phase 4 C)

Integration/`[W]` steps log ONE entry: `{step_id} WIRED — {description}`.

When you merge multiple Feature steps (per Principle 2), each constituent step keeps its own RED + GREEN entries — only the IMPL entry may be combined. Missing entries are a TDD compliance violation that Phase 6 audit MUST flag.

### Per-Step Plan Contract (MANDATORY)

Plan items are not optional decoration — they are the only channel the user watches in real time, so treat them with the same discipline as the log. Each Feature/Bug-Fix step has THREE plan items (`[test]`/`[impl]`/`[verify]`, created in Phase 3); each integration step has ONE (`[wire]`). As you execute a step, flip its plan items `in_progress` → `completed` in lockstep with the cycle phases (RED→[test], IMPL→[impl], GREEN→[verify]). Running a Phase 4 cycle with no corresponding `in_progress` plan item is a discipline violation of the same class as a missing log entry. If you reach Phase 4 and the step's plan items do not exist, STOP and create them (Phase 3) before editing.

---

## Phase 0: Pre-flight

1. **Resolve plugin root once.** Run `bash -c 'cat "$HOME/.zensu/plugin-root"'` via the Bash tool and store its trimmed output (no trailing newline) as `{PLUGIN_ROOT}` for the entire session. Use `{PLUGIN_ROOT}` in ALL subsequent helper invocations: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh …`. If the command exits non-zero or the output is empty, abort with: `FATAL: plugin root unresolvable — run a fresh session to trigger SessionStart hook AND ensure hooks.pulseSession is not set to false in ~/.zensu/config.json`. **Never search the filesystem** for the helper; the SessionStart hook (`hooks/session-start-pulse.sh`) is the single source of truth for the plugin-root path.
2. Run `date +%Y-%m-%d-%H%M` → store as `{SESSION_TS}` for all filenames. Additionally capture `SESSION_EPOCH=$(date +%s)` and keep it for the entire TDD session — the log helper consumes it for `relative` timestamp style.
3. **Activate the TDD session.** Run `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --tdd-begin`. This sets the per-session chain-state `active` flag, which turns on the PreToolUse phase-gate and the Bash witness for THIS main-thread session (they were silent until now). Without this call, your edits are NOT gated and the witness records nothing — so do it before any test/production edit.
4. **Use Codex's `update_plan` tool for progress tracking.** Codex exposes `update_plan` natively — there is nothing to load. Never let a tooling hiccup become an excuse to skip plan tracking: the plan is the user's live dashboard (Principle 3, Per-Step Plan Contract), not optional.
5. Create the first plan item "TDD: Analyzing spec and creating plan" via `update_plan` and set it `in_progress`. Each plan item carries a short step description and a status (`pending` → `in_progress` → `completed`); express step dependencies by the order in which you advance items.

---

## Phase 1: Discover the Project

1. Read all CLAUDE.md files in project hierarchy
2. Discover tech stack and test frameworks
3. Extract test commands (full suite, single file, type check, lint). Distinguish **test runners** (assertions, can RED/GREEN) from **static checks** (type checkers, linters). TDD requires a test runner — if none exists, add a `[W]` step to install one first.
3b. Detect coverage tooling and threshold (MUST read config files, not just probe deps):
   - Step 1 — locate coverage config file(s):
     - Node: vitest config (`vitest.config.{ts,js,mjs}` or `vite.config.{ts,js,mjs}`), jest config (`jest.config.*` or `jest` key in package.json), `.nycrc*`
     - Python: `pyproject.toml`, `.coveragerc`, `setup.cfg`
     - Go: built-in `go test -cover` (no config file)
     - Rust: `Cargo.toml` for tarpaulin/llvm-cov metadata
   - Step 2 — READ each located config file (Read tool, not just `ls`). Extract numeric thresholds:
     - vitest: `test.coverage.thresholds.{lines,branches,functions,statements}`
     - jest: `coverageThreshold.global.{lines,branches,functions,statements}`
     - c8/nyc: `lines`, `branches`, `functions`, `statements`
     - pytest: `[tool.coverage.report] fail_under`
   - Step 3 — verify tool is INSTALLED (in devDeps or available on PATH). Record `{coverage_cmd}` capable of per-file output (e.g. `npm run coverage`, `npx vitest run --coverage`).
   - Step 4 — threshold resolution:
     - Numeric thresholds extracted from config → use those values verbatim. Set `{threshold_source}=project-config`.
     - No thresholds in config (even if tool installed) → default 90% lines. Set `{threshold_source}=default-90%`.
   - If a test runner exists but NO coverage tool installed → ask the user directly whether to install one (recommend matching tool: vitest→@vitest/coverage-v8, jest→built-in, pytest→pytest-cov). On accept: add a `[W]` step in the Phase 2 plan for install. On decline: set `{coverage_cmd}=null`, mark coverage SKIPPED in Phase 6.
4. Read 1-2 sample test files for patterns
5. Scan `.zensu/plans/*_tdd-*.md` for patterns
6. Parse spec into atomic steps, classify work type per step. Non-testable work folded into related IMPL. **Cross-layer detection (Principle 2):** for each Feature/Bug-Fix step, trace the call graph from changed code to the persistence/transport boundary. If the path crosses unchanged code that consumes a NEW value/field/payload-key/query-param, add a paired Characterization step (`[G]`, Feature work type) in that unchanged layer. The originating step's `depends_on` MUST list the characterization step. Record the pairing in the Phase 2 plan's `## Cross-Layer Value Flow Pairings` table.
7. Build dependency graph: `depends_on: [step_ids]`. Independent steps (different files, no type deps) can run sequentially without blocking.
8. Compile context: root path, tech stack, test commands, coverage_cmd, coverage_thresholds, threshold_source, rules, test utilities

---

## Phase 1.5: Spec Precondition Discovery

Generalizes the Phase 1 step 3b coverage-tool pattern to every external dependency the spec names.

1. From the parsed spec (Phase 1 step 6), extract every:
   - **External CLI/tool** named by name (e.g. `promptfoo`, `docker`, `terraform`, `ffmpeg`)
   - **Secret or env var** referenced (e.g. `OPENAI_API_KEY`, `AWS_SECRET_ACCESS_KEY`)
   - **Service endpoint** required at runtime (e.g. live LLM API, database, external HTTP service)
   - **Input fixture or asset** the spec assumes exists on disk (e.g. baseline JSON, recorded responses)
2. For each precondition, run the matching verification:
   - CLI: `command -v X >/dev/null 2>&1`
   - Env var: `[ -n "${VAR:-}" ]`
   - Endpoint: `curl -fsS --max-time 5 {url}` (only if the spec implies live use; otherwise skip)
   - Fixture: `[ -f {path} ]` or `[ -d {path} ]`
   Record `{precondition_name}`, `{verification_cmd}`, `{result: present|missing}`.
3. For every `missing` precondition: ask the user directly, presenting three options — **(a) install/provide it now, (b) approve a named substitution** (the user names the substitute, agent does not propose one), or **(c) mark the dependent steps `[!]` and skip**. Record the user's answer verbatim in the plan's `## Preconditions` section (Phase 2).
4. **Ask-the-user override**: if an earlier user instruction said "no questions" or similar terseness preference, that instruction is OVERRIDDEN here. Blocking-precondition escalation always asks. This mirrors the Phase 1 step 3b coverage-tool ask, which is also unconditional.
5. If the user picks (a) install: pause and wait for the user to install/provide the precondition. After the user confirms completion, re-run the verification command from step 2. If still missing, ask again (loop back to step 3). The workflow does NOT proactively run install commands (e.g. `npm install`, `brew install`) unless the user has explicitly authorized the specific install command in the same exchange.
6. If the user picks (b) substitution: the substitution MUST be named by the user, not proposed by the agent. Re-run the matching verification on the user-named substitute. If the substitute is also missing, ask again.
7. If the user picks (c) skip: every spec step that names the missing precondition gets `[!]` in Phase 2. Do not silently re-route the step's IMPL to a different tool.

---

## Phase 2: Create Plan + Log

MANDATORY — create BOTH files (plan + log are a pair).

> **Gate note (read before writing):** Phase 0's `--tdd-begin` armed the phase-gate. Paths under `.zensu/` (the plan + log artifacts) are exempt from the gate, so write the **plan** with the **Write tool** — its full body must NOT go through Bash, or the witness log would record the entire plan in one `cmd=` entry. The **log** is an append-only trace: write and grow it with **Bash** (`printf >> {log_file}`), never the Write tool (which would overwrite it). Never use Bash to write *production code* to bypass the gate — production source goes through Edit/Write under a declared phase in Phase 4.

1. Create the plan file with the **Write tool** at `.zensu/plans/{SESSION_TS}_tdd-{slug}.md` (the `.zensu/` path bypasses the phase-gate), with this content:

```markdown
# TDD Plan: {Feature Title}

## Context
{Spec verbatim}
**Approach**: Strict Red/Green TDD | **Tech Stack**: {stack} | **Coverage**: {coverage_cmd or "SKIPPED"} @ {threshold} ({threshold_source})

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| {name} | CLI/secret/endpoint/fixture | `{verify_cmd}` | present/missing | install / substitute=`{user-named}` / skip |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — Cross-Layer Value Flow Pairing. Omit table body if no pairings; keep the heading so Phase 6 audit can detect absence vs zero rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|
| {step_id_A} | {field}=`{example}` | {path} | {step_id_B} | DB row / response body / persisted file / returned struct |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|

### Step {id} — {Description}
- [ ] **RED**: Test `{name}` — {what}, {why fails}
- [ ] **GREEN**: {what to implement}

**Checkpoint**: {test_cmd} + {lint_cmd} pass

## Final Verification
- [ ] All test suites pass
- [ ] Coverage report generated for changed files (threshold: {threshold})
```

2. `mkdir -p "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs" && printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "TDD STARTED — {title} | steps: {N}" > {log_file}`
3. Tell user: `tail -f {log_file}`

---

## Phase 3: Create ALL Plan Items

Create `update_plan` items for ALL steps BEFORE starting execution — **MANDATORY**. This is the user's live progress dashboard and the one channel they watch in real time. Do NOT enter Phase 4 until every step has its plan items.

Per TDD step — 3 plan items:
- `{step_id} [test]` — "Creating RED test for {step_id}"
- `{step_id} [impl]` — "Implementing {step_id}"
- `{step_id} [verify]` — "Verifying {step_id}"

Per integration step — 1 plan item:
- `{step_id} [wire]` — "Wiring {step_id}"

Create each via `update_plan` with the `{step_id} [...]` label as its step description. Order the items per the dependency graph so the user sees the intended sequence. Mark the Phase 0 "Analyzing" plan item `completed`.

---

## Phase 4: Execute TDD Cycles

Log `EXECUTION STARTED` before the first step. All log-append commands in this phase use the helper-prefix pattern from Principle 3: `printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "<message>" >> {log_file}`. Do not inline `[$(date +%H:%M:%S)]` — the user-configured `logging.timestampStyle` may suppress or reformat the prefix.

### Feature Cycle (per step)

**Self-check**: Previous step done? RED test defined? **Precondition check**: does this step's IMPL plan reference any tool/secret/fixture from the Phase 2 `## Preconditions` table that is marked `missing` with decision `skip`? If yes — mark the step `[!]` in the plan, log `{step_id} BLOCKED — precondition {name} missing`, drop the step's three plan items via `update_plan`, and proceed to the next step. Do NOT substitute, do NOT write a partial test, do NOT commit a placeholder.

**A) RED** — Write the test file. The test MUST assert actual behavior (return values, state changes, side effects), not just function existence. Run it with the test command. Verify it FAILS.
  - **Phase marker (before writing the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_WRITE --step {step_id}`
  - Write the test file.
  - **Phase marker (before running the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_RUN --step {step_id}`
  - Run the test.
  - **Verify the failure reason**: Assertion mismatch or missing symbol = CORRECT RED. Syntax error, typo, missing import, wrong file path = WRONG RED → fix the test itself, don't proceed to IMPL.
  - **Phase marker (on confirmed failure)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_FAIL --step {step_id} --reason "{reason}"`
  - Log: `{step} RED {test} — FAIL: {assertion or missing-symbol message}`. Mark the `[test]` plan item completed via `update_plan`.
  - If test PASSES: delete it, rewrite to test something that requires the implementation. Log `REJECTED — test GREEN on creation`.

**B) IMPL** — Write the MINIMUM implementation code. Real, complete code for the test to pass — no stubs, no skeletons, no premature generalization. Do NOT run tests yet. Do NOT refactor unrelated code.
  - **Phase marker (before editing production files)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase IMPL --step {step_id}` — the PreToolUse gate verifies that step `{step_id}` is in `RED_FAIL` in history; a missing or mismatched marker blocks the Edit/Write call.
  - Log: `{step} IMPL completed — files: {list}`. Mark the `[impl]` plan item completed via `update_plan`.

**C) GREEN** — Run the TARGET test (single file/name, not the full suite). Verify it PASSES.
  - **Phase marker (before running the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_RUN --step {step_id}`
  - Run the test.
  - **Phase marker (on PASS)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_PASS --step {step_id}`
  - If PASS: Log `{step} GREEN — PASS ({N} attempts)`. Mark the `[verify]` plan item completed via `update_plan`. Next step.
  - If FAIL: Log `RETRY({N}/3)`. Fix implementation (re-emit `--phase IMPL` per RETRY), back to C. Max 3 attempts → escalate to user.
  - Full suite runs only at Phase 5 checkpoints (not per step) — avoids 20× overhead on large codebases.

### Refactoring Cycle

**R1)** Run existing tests for affected code. Verify ALL PASS. If coverage insufficient, write a behavior-preserving test first.
**R2)** Phase marker: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase REFACTOR --step {step_id}`. Refactor the code. Do NOT change behavior.
**R3)** Run same tests. Verify ALL still PASS.
Log: `{step} RF — tests GREEN before+after`. Mark `[RF]`.

### Bug Fix Cycle

**B1)** Write test reproducing the bug. Run it. Verify FAIL.
**B2)** Fix the bug.
**B3)** Run test. Verify PASS.
Same logging as Feature cycle.

### Integration Steps

Implement directly (wiring, config, migrations). Log: `{step} WIRED`. Mark `[W]`. Execute after dependent TDD steps are `[G]`.

---

## Phase 5: Checkpoint

After each logical phase: run full test suite + linter. Log result. Batch-update plan document statuses.

**Run every test / lint / build / coverage command in the FOREGROUND and one at a time — never in the background, never two at once.** Codex's Bash `tool_response` omits `exit_code`, so the witness records `exit=?` for every command — the cross-check corroborates by `cmd=` plus the captured stdout `tail=`, not by exit code. A backgrounded run returns before its stdout is captured, so the witness `tail=` is empty and result-corroboration is defeated; concurrent runs interleave `witness-<session>.log` lines and leave orphaned shells. Run the full suite once here (checkpoint) and once in Phase 6 (audit) plus the scoped coverage run — serially, not in parallel.

**MANDATORY** — every test/lint/build invocation logged from Phase 5 onward MUST use the structured-evidence schema so the witness log can cross-check the claim. For each run, append a line of the form:

```
{step_or_phase} CHECKPOINT — cmd="<exact bash command>" exit=<rc> result="<short verdict>"
```

The `cmd="..."` field MUST be the literal command string that was sent to the Bash tool — the witness hook (`hooks/post-bash-witness.sh`) records the same string verbatim, and Phase 6 step 1 will grep for `cmd="<X>"` in the witness log to verify the claim. Mismatched or paraphrased commands break the cross-check. Each witness line also records `tail=` (the JSON-escaped last 200 chars of stdout) and `interrupted=`; the witness `exit=` is always `?` because Codex's Bash `tool_response` omits `exit_code`, so Phase 6 corroborates a claimed `result=` against the witness `tail=` rather than against the exit code. The witness log lives at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log` and is written automatically by the PostToolUse Bash hook while this TDD session's chain-state `active` flag is set (Phase 0). Set `ZENSU_TEST_WITNESS=off` only when the user has authorized disabling the witness layer for a legitimate non-eval session.

---

## Phase 6: Audit & Final Report

1. Run full test suites + linters.
   - **MANDATORY structured-evidence form** — every test/lint/build run in Phase 6 MUST also be logged as `AUDIT — cmd="<exact bash command>" exit=<rc> result="<short verdict>"`. After all AUDIT entries are written, perform the **witness cross-check**: for each `cmd="X"` claim, run `grep -F -q 'cmd="X"' "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log"`. If no match, append `EVIDENCE GAP — cmd="X" claimed but not in witness log` to the run log AND mark Phase 6 NOT complete (surface prominently in the final report). Then **result-corroboration**: for each claim of `result="PASS"` (or an equivalent green verdict), inspect that command's witness tail — extract **only the `tail=` field value** (the substring after ` tail=` up to ` interrupted=`) and scan that, **not the whole line** (a `cmd=` that itself contains `error`/`fail` must not trip the scan). If the tail value contains a failure marker — `FAIL`, `failed`, `Error`, a non-zero test summary, or `interrupted=true` — that contradicts the claimed pass, append `EVIDENCE CONTRADICTION — cmd="X" claimed PASS but witness tail shows <marker>` to the run log AND mark Phase 6 NOT complete. This is best-effort (the tail is the last 200 chars and may be silent on a clean success) — corroboration, not a second hard gate; the `cmd=` match above remains the gate.
   - **Non-Bash escape clause** — if a test was invoked via a non-Bash tool (rare; e.g. custom MCP test runner), declare in the AUDIT entry as `via=tool_name claim="..."` instead of `cmd="..."`. Audit treats `via=` entries as known-limitation (no witness cross-check possible) and surfaces them prominently in the final report.
2. **Build Verification.** Tests can be green while the artifact is broken (compile errors only the build catches, env vars frozen at build-time, broken imports the test harness shims out). Verify the project actually builds.
   - Determine the build command by reading the project's metadata: `README.md`, `CLAUDE.md`, `package.json` (`scripts.build`), `pom.xml`, `Cargo.toml`, `Makefile`, `go.mod`, `pyproject.toml`, etc. Pick the canonical command the docs name as "build".
   - Decide applicability. If the TDD spec is genuinely non-buildable (docs-only migration, pure data fixture, etc.) AND the project metadata confirms no build step is wired, record `Build: – n/a` with the reason and proceed to step 3.
   - If the project IS buildable, run the build. Capture exit code and the last ~30 lines of output.
   - **Build passed** (exit 0, no critical warnings): record `Build: ✓ passed`. Proceed to step 3.
   - **Build failed**: DO NOT mark Phase 6 complete. Treat the failure as a new requirement and return to Phase 2 to amend the plan with a new `[W]` integration step that fixes the build, then create a task for it (Phase 3 mechanics) and re-run Phase 4-6 after the fix. The Phase 6 "done" claim is only valid when the build is green.
   - If the build can't run for ambient reasons (dependencies not installed, network down, unknown toolchain), record `Build: – skipped (reason)` and continue — do not block the audit on environment problems the developer must resolve. Surface the skip prominently in the final report so the developer notices.
3. Coverage report (changed files only):
   - If `{coverage_cmd}` is null → log `COVERAGE SKIPPED — no tool` and skip to step 4.
   - Else:
     a) Collect list of files modified during session from `IMPL`/`WIRED` log entries (Phase 4 Cycle B logs `files: {list}`).
     b) Run coverage on full test suite, restricting report scope to changed files via the tool's include filter:
        - vitest: `--coverage --coverage.include={file1} --coverage.include={file2}`
        - jest: `--coverage --collectCoverageFrom={file}`
        - c8/nyc: `--include={file}`
        - pytest-cov: `--cov={module}`
        - go: `go test -coverprofile=cover.out ./... && go tool cover -func=cover.out` (filter manually)
     c) Parse per-file metrics: lines %, branches %, functions %.
     d) Compare each file against `{threshold}`.
     e) Build Coverage section for the final report (markdown table):

        ```
        ## Coverage (changed files)
        | File | Lines | Branches | Funcs | vs {threshold} |
        |------|-------|----------|-------|----------------|
        | ...  | ...   | ...      | ...   | PASS / FAIL    |

        Summary: {N}/{M} files PASS @ {threshold}
        Threshold source: {threshold_source}
        ```

   - If ≥1 file FAIL: log `COVERAGE BELOW THRESHOLD on {N} files: {file_list}` and ask user (in their language) whether to run an additional TDD cycle for uncovered branches. Do NOT auto-loop (avoids scope explosion).
4. Read plan and implementation files. Verify every step's description matches the actual code. For `[W]` steps, verify wired code is actually USED (not dead imports). If gaps → fix through another TDD cycle → re-verify.
5. **mtime Discipline Audit**. For every Feature step marked `[G]`:
   - Resolve the IMPL file list from the `{step_id} IMPL completed — files: {list}` log entry.
   - Resolve the test file from the step's `{step_id} RED {test_name}` log entry.
   - Capture mtimes: `test_mtime=$(stat -f %m {test_file})` (Linux: `stat -c %Y {test_file}`); `impl_min_mtime=$(stat -f %m {impl_files} | sort -n | head -1)`.
   - If `test_mtime > impl_min_mtime`: the step was Test-After. Mark the plan step `[!]` and append `DISCIPLINE VIOLATION: test-after detected ({test_file} mtime > {impl_file} mtime)` to the log.
   - Aggregate: if > 20% of Feature steps carry `[!]`, the final log line MUST read `TDD DISCIPLINE VIOLATED — {N}/{M} steps test-after, audit FAIL` and Phase 6 is NOT complete. Surface this prominently in the final user-facing report so the developer notices.
6. **Precondition Drift Audit**. Detect silent substitution.
   a) Read the `## Preconditions` table from the plan. Collect the names of every CLI/tool listed (column 1 of rows where Type=CLI).
   b) For each such CLI name `X` where the Decision was `install` or substitute=`{name}`: search the log file for any invocation of `X` (or the named substitute) in IMPL/WIRED entries using fixed-string word matching: `grep -F -w "$X" {log_file} || grep -F -w "$substitute" {log_file}`. If a CLI name contains regex metacharacters (`.+*?[]()|\`), DO NOT use `grep -E` with interpolation — always prefer `grep -F -w` for CLI-name searches.
   c) **Drift conditions**:
      - Decision was `install` but `X` never appears in an IMPL/WIRED log entry → DRIFT (silent skip).
      - Decision was `skip` but `X` appears in an IMPL/WIRED log entry → DRIFT (silent inclusion against user decision).
      - Decision was substitute=`Y` but neither `X` nor `Y` appears → DRIFT (neither contracted tool ran).
   d) If any drift: append `PRECONDITION DRIFT — {tool}: decision={d}, actual={observed}` to the log, mark Phase 6 NOT complete, and surface prominently in the final report. Do NOT auto-fix — drift is a discipline violation, same severity as mtime discipline failure (existing step 5).
6b. **Cross-Layer Value Flow Audit** (Principle 2 — Cross-Layer Value Flow Pairing).
   a) Read the plan's `## Cross-Layer Value Flow Pairings` table. For every row:
      - Verify the Characterization Step `{step_id_B}` is marked `[G]` AND has its three RED + IMPL + GREEN log entries (same contract as the per-step logging contract in Principle 3).
      - Verify mtime: the Characterization test file mtime PRECEDES the IMPL file mtimes of the originating Feature step `{step_id_A}` (same comparison as step 5). If `char_test_mtime > origin_impl_mtime`: append `CROSS-LAYER PAIRING TEST-AFTER — {step_id_B} characterization mtime > {step_id_A} impl mtime` and mark Phase 6 NOT complete.
      - Verify the characterization asserts at the unchanged layer's OWN seam (DB row / response body / persisted file / returned struct), NOT at a caller-side mock. Read the test file; if its top-level assertions only inspect mocks created in the same test, append `CROSS-LAYER PAIRING MOCK-ONLY — {step_id_B} asserts only on caller mock, not on unchanged layer's seam` and mark Phase 6 NOT complete.
   b) **Missing-pairing detection.** Re-scan IMPL log entries for Feature/Bug-Fix steps. For each step, inspect the diff of its IMPL files for added literals matching field-name / payload-key patterns (`'foo':`, `"foo":`, `foo=`, `&foo=`) that did not exist in the pre-step version of those files. For each such added literal, grep the IMPL files of OTHER steps in this plan for the same literal — if no other step in this plan added the same literal AND the plan's Cross-Layer Pairings table has no row pairing this step to a layer that consumes the literal, append `CROSS-LAYER PAIRING MISSING — {step_id} added literal "{literal}" with no paired characterization` and mark Phase 6 NOT complete.
   c) Do NOT auto-fix — pairing violations are a discipline violation, same severity as mtime and precondition drift.
7. Update plan: all steps `[G]`, `[W]`, or `[!]`. No `[ ]`/`[R]`/`[I]` remaining.
8. Log: `TDD COMPLETE — {N}/{M} GREEN | Integration: {N} WIRED | Build: {✓ passed | – n/a | – skipped} | Coverage: {N}/{M} files >= {threshold}` (omit Coverage segment if SKIPPED).
9. Output summary, in this order: (a) `## TL;DR` — exactly ONE sentence following the template `{component} {symptom} because {root_cause} — fixed via {mechanism}[, {N} TDD round(s)], {pass}/{total} tests green.` Cover root cause + fix mechanism + test verdict; no fluff, no hedging. Then (b) results, files modified, test counts, verification status, **Build status from step 2**, **Coverage table from step 3e**, **Test Evidence section** (every CHECKPOINT/AUDIT `cmd="..."` claim with its witness cross-check verdict — `verified` when matched in witness log, `EVIDENCE GAP` when missing, `EVIDENCE CONTRADICTION` when the witness tail contradicts a claimed pass, `via=tool_name` when declared non-Bash escape), plan path.
10. **Close implementation and trigger the review chain.** This replaces the old subagent auto-review hook — the chain is now driven from this main thread. Execute these steps STRICTLY ONE AT A TIME (single tool call per step, wait for each result), never as a parallel batch and never bundled with the Phase 6 audit writes above:
    1. Mark implementation complete: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --tdd-complete`. This arms the Stop-hook backstop (`stop-chain-enforcer.sh`): you will NOT be allowed to end your turn until the review chain terminates.
    2. Enumerate changed files: `git diff --name-only HEAD`.
    3. **Review fan-out (read-only, parallel).** Spawn FIVE `zensu-review-aspect` subagents in ONE parallel batch (the single sanctioned parallel batch noted in the main-thread model above; Codex multi-agent: ask Codex to run these five agents — it runs explicitly-requested subagents in parallel when asked) — one per perspective: `conventions`, `bugs`, `architecture`, `tests`, `security`. Give each the same one-paragraph implementation summary + the changed-file list from step 2, and name its perspective in the prompt. They are strictly read-only and run NO build/test commands — the suite and build already ran in the Phase 6 audit above, so the aspects must not re-run them.
    4. **Merge in-thread.** Collect the five `## Aspect:` findings lists, deduplicate (same `file:line` raised by multiple perspectives → keep the highest confidence), and sort CRITICAL → IMPORTANT → SUGGESTION → by file path. This is the synthesis the standalone reviewer used to perform in its own Phase 5; you now do it here.
    5. **Thin consume-mode spawn (the single hook trigger).** Spawn ONE `zensu-code-reviewer` subagent (Codex multi-agent: ask Codex to run that agent). Its prompt MUST begin with the marker line `PRE-MERGED FINDINGS (fan-out)` followed by the merged findings from step 4 and the build/test/coverage status lines from the Phase 6 audit. It runs in consume mode — it skips its own Phases 1-4 (no re-read, no build, no test) and emits the consolidated report from your pre-merged findings. Its single completion is what fires `post-review-tdd-delegate.sh`, so the round counter and the entire downstream chain behave exactly as before. Do NOT ask the user about review — running the fan-out IS the autonomous action.
    - **`--chain-done` is the chain-terminus marker, now owned by the `$zensu-self-review` stage.** Run it yourself ONLY when (a) implementation produced ZERO file changes (every step blocked `[!]`) — then run it INSTEAD of spawning the reviewer and stop; or (b) `hooks.selfReview` is disabled and the reviewer returned PASS / suggestions-only. When self-review is enabled (the default), you run `--code-review-done` and then invoke `$zensu-self-review`, which issues `--chain-done` itself. **NEVER** issue `--chain-done` in the same turn or batch as `--tdd-complete`, the reviewer spawn, a plan write, or the audit — landing it early releases the Stop gate before review and silently defeats the guarantee.
    - **On Codex no hook fires on reviewer completion — YOU route the findings yourself, in this thread, strictly by severity:**
        - **Critical / Important** → fix in THIS thread under the same TDD discipline (re-enter Phase 4 cycles — the gate is still active), then re-run the review fan-out (steps 3-5 above: re-fan-out the five aspects, re-merge, re-spawn the thin consume-mode `zensu-code-reviewer` subagent) to re-verify — one reviewer completion per round, so round-counter semantics are unchanged.
        - **Suggestion / Minor / Nit / Low** → do NOT fix and do NOT re-review them. Copy them verbatim into the final report's deferred-findings section; they NEVER trigger another review round. The ONLY exception is `hooks.autoFixIncludeSuggestions=true`, which makes you treat them like Important. A lone Low/Suggestion — including a nit about your own evidence such as an incomplete TDD log — is convergence, not a new round: if trivial, just backfill the missing log line and move on; do NOT spawn another reviewer for it.
        - End the loop at the first PASS / suggestions-only result, or at `autoFixMaxRounds`.
    - **Then run the terminal self-review — it does NOT start on its own on Codex, so invoking it is YOUR explicit, mandatory step:** run `--code-review-done`, then invoke the `$zensu-self-review` skill. **That stage owns `--chain-done`**: it re-reads this session's changes, takes at most one fix round (never re-running the reviewer), then runs `--chain-done` and renders the final CHAIN-END SUMMARY (with a `## Self-Review Summary` section). Do NOT run `--chain-done` or render the summary yourself when self-review is enabled (the default), and do NOT skip self-review just because the code-review returned PASS. (On Claude Code a hook automates this handoff; on Codex you do it explicitly.)
