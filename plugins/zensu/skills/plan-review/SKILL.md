---
name: zensu-plan-review
description: Multi-agent plan revalidator — take an implementation/design plan, dynamically cast a tailored reviewer team, run the reviewers in parallel as read-only validators, and return a single revalidation report with a clear verdict plus concrete plan amendments, all before any code is written. Use as a pre-implementation gate when the user wants a plan double-checked by an agent team.
---

# $zensu-plan-review

Multi-agent **plan** revalidator. Takes an implementation/design plan, dynamically casts a tailored reviewer team as a batch of Codex subagents (Codex multi-agent: ask Codex to run the reviewer agents), runs the reviewers in parallel as **read-only** validators, consolidates their findings, and returns a single revalidation report with a clear verdict + concrete plan amendments — all **before** any code is written. Default team size is **6**; the cast is chosen dynamically from a 12-persona pool to match what the plan actually touches.

This is a **pre-implementation gate**, not an executor. It never edits code, never rewrites the plan (unless `--apply`), and never triggers the TDD workflow. The only thing it produces is a report.

## When to Use

- The user wants a plan double-checked / re-validated by an agent team before implementation begins.
- After Codex planning produces a plan and you want an independent multi-perspective sanity pass before approving it.
- Triggers include: "review this plan with a team", "validate the plan", "spawn an N-agent team to check the plan", "multi-agent plan review", the `$zensu-plan-review` skill, or any request to spin up a reviewer team for an implementation plan. The user may phrase this in any language — match the intent, then render the report in their language.

## Do NOT Use For

- Reviewing a pull request or already-written code — that is a code review, not a plan review.
- Implementing the plan. This skill stops at the report; it writes no production code.
- A plan that does not exist yet — if there is nothing concrete to review, ask for the plan instead of inventing one.

## Arguments

Parse from the user prompt. Invocation form: `$zensu-plan-review [<plan>] [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<plan>` | no | auto-locate | A plan file path, OR inline plan text. If omitted, resolve in the order in Phase A. |
| `--agents=<n>` | no | `6` | Team size. **Also parse from natural language** ("6-agent team", "eight reviewers", "team of five", etc.) and set N from it. Clamp to 3–10. |
| `--aspects=<csv>` | no | auto-cast | Override the dynamic cast with explicit persona ids from the pool below. |
| `--lang=<code>` | no | match input | Report language. Default: the language of the plan / the user's prompt. |
| `--confirm` | no | off | Ask the user to approve the cast before spawning. Default: announce the cast and proceed. |
| `--write[=<path>]` | no | off | Also write the report to a file. Default `<plan-dir>/<plan-basename>-revalidation.md` (or `<DIR>/revalidation.md` when the plan came from the conversation). |
| `--apply` | no | off | After reporting, offer to apply the concrete plan amendments back into the plan file (file plans only; show a diff and ask first). |

Default team size is **6**; `--agents` (or a natural-language count) overrides it, clamped 3–10.

## Persona Pool

A 12-persona, **stack-agnostic** aspect pool. Each persona is a read-only validator that reads the plan and verifies it against the **real codebase** of the project under review — never against assumptions. The phrasing below describes the *concern*; the reviewer discovers the project's actual tooling, conventions, and structure (e.g. by reading the in-scope `CLAUDE.md` / contributing guide / config) rather than assuming any particular framework, language, or product.

You (the lead) **cast** a subset of size N and **inject each chosen persona's focus + the output schema directly into that persona's spawn prompt** — the sub-agents never read this file.

**Core 4 — always cast** (they fill 4 of the N seats regardless of plan type):

- **`requirements-completeness`** — Does the plan fully deliver the stated goal? Map each requirement / acceptance criterion to a plan step; find gaps, unstated assumptions, missing success criteria, happy-path-only coverage.
- **`feasibility-soundness`** — Will the approach actually work against THIS codebase? Verify that referenced files, classes, functions, endpoints, config keys, and dependencies **actually exist** and behave as the plan assumes. Flag invented APIs, wrong signatures, version mismatches, and steps that depend on something absent. Highest-value seat: it catches plans built on things that aren't real.
- **`testing-tdd`** — Is the plan testable RED→GREEN? Does each requirement / invariant get a test? Unit vs integration balance, edge / error / boundary cases, concurrency where relevant. Flag "implement then test" ordering that breaks a test-first gate.
- **`devils-advocate`** — Red-team the plan. Assume it will fail and find why: the fatal flaw, the unchallenged core assumption, the simpler alternative the plan ignored. State the single assumption that, if false, sinks the plan — and whether it is actually verified. Do not merely restate the other seats.

**Domain seats — cast by trigger match** to fill the remaining N − 4:

- **`architecture-fit`** (usual 5th seat; any plan touching code) — Conformance to the project's existing architecture: module / layer boundaries, the conventions in the in-scope `CLAUDE.md` / contributing docs, no reinvented utilities, no new duplicate abstractions or tech debt.
- **`security-privacy`** (new surfaces, auth / permission changes, user or tenant data, external calls, secrets, PII, uploads) — Authorization on every new surface, isolation between users / tenants where applicable, input validation, secrets handling, sensitive data in logs. For each new entry point the plan adds, ask "which authorization gate and which data scope?".
- **`data-persistence`** (schema / migrations, data model, storage) — Migration safety (idempotent, ordered, reversible or forward-only as the project requires), indices for new query patterns, constraints, data integrity, cache invalidation — whatever migration and storage tooling the project actually uses.
- **`risk-rollout`** (prod-impacting paths, breaking changes, deploys, data backfills) — Blast radius, backward compatibility, rollback story, deploy / release ordering, feature-flag or staged-rollout need, what happens if a step half-completes.
- **`scope-sequencing`** (large, vague, or multi-part plans; more than ~6 steps) — Right-sizing (over-engineering vs under-scoping), smallest shippable slice, step dependency order, hidden long-poles, "and also" scope creep. Is the sequence actually buildable in that order?
- **`integration-impact`** (plans spanning multiple modules / services, API / contract / event-payload changes) — Cross-component ripple: which downstream consumers must also change, contract / payload compatibility, generated-client regeneration, version coordination. Does the plan account for every consumer?
- **`performance-scale`** (hot-path code, new queries / loops, caching, large-data operations) — Inefficient access patterns, missing indices, full scans, allocation hot spots, caching and invalidation, pagination, payload size; rough cost per request vs expected load.
- **`frontend-ux`** (plans touching UI — components, templates, state, styling) — Component design and single responsibility, design-system adherence, internationalization for **all configured locales** (no hard-coded user-facing strings), accessibility (semantic markup, focus, contrast), responsive behavior.

## Output Schema

Every persona writes exactly one file, `<DIR>/<persona-id>.json`, with this shape. Inject this schema into each spawn prompt:

```json
{
  "role": "<persona-id>",
  "verdict": "go | go-with-changes | revise | no-go",
  "confidence": "high | medium | low",
  "summary": "<2-4 sentences: does the plan hold from this aspect>",
  "blockers": [
    {
      "issue": "<what is wrong / missing / risky in the plan>",
      "why": "<consequence if implemented as written>",
      "plan_ref": "<the plan step/section this concerns>",
      "plan_amendment": "<concrete change to make to the plan>",
      "evidence": "<optional: file:line in the repo that proves the point>"
    }
  ],
  "improvements": [
    { "issue": "<non-blocking suggestion>", "suggestion": "<fix>", "plan_ref": "<step>" }
  ],
  "questions": ["<assumptions the plan leaves unresolved / to confirm before coding>"],
  "strengths": ["<what the plan gets right>"]
}
```

Severity: a **blocker (P1)** means the plan will fail, break something, miss the goal, or violate a hard constraint if implemented as written — the plan must change first. An **improvement (P2)** means it works but would be better; nits go in `improvements` with a `(nit)` prefix. Hard cap **≤ 6 blockers** per persona, and every blocker MUST carry a concrete `plan_amendment` — "this is risky" without "change the plan to X" is not actionable.

## Workflow

Six phases. Track each with Codex's `update_plan` tool.

### Phase A — Locate Plan + Scope

**A.1 Resolve the plan source** (first match wins): (1) explicit `<plan>` arg that is a readable file → use it; (2) explicit `<plan>` arg that is inline text → use it; (3) newest `.zensu/plans/*.md` → use it; (4) the most recent plan in the conversation (the latest Codex planning output) → use it; (5) none found → ask the user to paste the plan or give a path. **Never invent a plan.** If the resolved plan is trivial (under ~5 lines, no concrete steps), tell the user it is too thin to revalidate and ask for the real plan.

**Materialize** the resolved plan to a stable file so every agent reads byte-identical input:

```bash
SLUG=$(date +%Y%m%d-%H%M%S)                              # label for the team name only
DIR=$(mktemp -d "${TMPDIR:-/tmp}/plan-review-XXXXXX")   # mktemp -d → mode 700, unpredictable name (no shared-tmp disclosure)
# write the plan content verbatim to "$DIR/PLAN.md"
REPO=$(pwd)   # repo root — agents read it READ-ONLY for feasibility checks
printf 'DIR=%s\nREPO=%s\nSLUG=%s\n' "$DIR" "$REPO" "$SLUG" > "$DIR/.env"
```

**A.2 Scope scan.** Read the plan and classify what it touches — this drives the cast: layers (backend / frontend / infra / CI / data); cross-cutting concerns (auth and isolation, external / third-party calls, API and event contracts, data model, performance hot-paths); plan shape (green-field vs refactor vs migration; size; how concrete vs hand-wavy). Determine **N** (from `--agents=` or natural language, default 6, clamp 3–10).

### Phase B — Cast (dynamic)

1. **Always include the core 4**: `requirements-completeness`, `feasibility-soundness`, `testing-tdd`, `devils-advocate`.
2. Fill the remaining **N − 4** seats by trigger match against the Phase-A scope, highest-signal first. `architecture-fit` is the usual 5th. Force-casts: schema / migration plan → `data-persistence`; new endpoint / auth → `security-privacy`; multi-module / contract change → `integration-impact`; UI plan → `frontend-ux`; prod / migration / deploy → `risk-rollout`; big or vague plan → `scope-sequencing`; hot-path → `performance-scale`.
3. If `--aspects=` was given, use it verbatim (still cap at N). If N < 4, keep the most relevant N of the core 4 (drop `devils-advocate` last). Do not pad with near-duplicate seats just to hit N — if the plan is small, say so and recommend a smaller team.

**Announce the cast** (always), one line per seat with why it was chosen. If `--confirm`, ask the user to approve the cast before spawning; otherwise proceed immediately (the user already opted in).

### Phase C — Spawn the Reviewer Team

Track the work with Codex's `update_plan` tool: one item per persona + one "Consolidate" + one "Report".

Spawn **all reviewers in ONE parallel batch** of Codex subagents (Codex multi-agent: ask Codex to run the reviewer agents — Codex runs explicitly-requested subagents, and runs them in parallel when asked, so request the whole cast at once rather than serially). Name each agent `<persona-id>`. Each prompt = the chosen persona's focus (copied from the pool above) + the output schema + the injection block below.

**Injection block — put this in every reviewer prompt** (each agent starts fresh, with no conversation history):

> You are revalidating an **implementation plan** (not a PR, not code that exists yet) as persona **`<persona-id>`**.
> **The plan to review:** read `<DIR>/PLAN.md` in full first.
> **Codebase for feasibility checks:** `<REPO>`. You are **READ-ONLY** on the codebase and on the plan — use `grep`, `find`, file reads, and read-only `git` to VERIFY the plan against reality (do the referenced files / APIs / config actually exist? does the approach fit the existing patterns and the relevant `CLAUDE.md`?). **Never edit, write, or run mutating commands** anywhere except your one output file.
> **Your focus:** <inject the persona's focus paragraph here>.
> **Verify before judging:** check the plan's concrete assumptions against the real code first — do not review the plan in a vacuum.
> **Write your verdict as JSON to `<DIR>/<persona-id>.json`** per this schema: <inject the output schema here>. Every blocker MUST include a concrete `plan_amendment` and a `plan_ref`. Max 6 blockers.

Mark each reviewer's `update_plan` item `in_progress` as you dispatch it.

### Phase D — Wait + Consolidate

Wait for all reviewer subagents to finish and return. Once they have all completed:

1. Read every `<DIR>/<persona-id>.json` and parse **defensively** — agents may vary the schema (`blockers` vs `findings`, `verdict` vs `verdict_hint`) or emit malformed JSON; handle missing keys, and if a file will not parse, read it raw and parse by hand. Keep the files as a debug record.
2. **Deduplicate** blockers and improvements across personas, and build a **convergence map**: the same issue raised by ≥ 2 personas is high signal — merge it into one item and cite all sources.
3. Resolve conflicts and compute the overall verdict per the rubric below.

Lead-driven consolidation — no cross-agent message round unless reviewers hard-conflict on the verdict.

### Phase E — Report

Present ONE consolidated report to the user, in the report language (default: the input language). Structure:

```
## Plan Revalidation — <Plan Title>  ·  <N>-agent team

**Verdict: <GO | GO-WITH-CHANGES | REVISE | NO-GO>**  (consensus <x>/<N>)

### Summary
<2-3 sentences: is the plan sound, and what is the biggest gap>

### Blockers (P1 — fix before implementing)
#### 1. <area> — <short title>
<problem in 2-4 sentences>. **Plan change:** <concrete amendment>. Ref: <plan step>. Source: <persona-ids>.
#### 2. ...

### Improvements (P2)
- **<area>**: <problem + suggestion in one line>. Source: <persona-id(s)>.

### Open Questions / Assumptions
- <what the plan leaves unresolved>

### Strengths
- <what the plan gets right>  (max 5-7)

### Concrete Plan Amendments
1. <actionable edit to the plan>
2. ...

### Recommendation
<verdict rationale + the single next step>
```

**No Markdown tables** in the report — terminals and GitHub squeeze them into unreadable columns. Use numbered subsections for P1, and bold-prefixed bullets for P2 / Strengths / Questions.

**Verdict → next step:** `GO` → the plan is sound, implementation can start. `GO-WITH-CHANGES` → fold in the amendments above, then implement (no re-review needed). `REVISE` → restructure the plan and revalidate. `NO-GO` → rethink the approach; the core assumption does not hold.

If `--write`, also save the report to the file. If `--apply` (file plans only), show the proposed plan edits as a diff and ask before writing — never silently rewrite the plan.

### Phase F — Cleanup

- The reviewer subagents finish on their own once they return their JSON; there is nothing to shut down.
- Mark all `update_plan` items `completed`.
- Keep `<DIR>/` (the per-persona JSON + `PLAN.md`) as a debug record.

## Consolidation & Verdict Rubric

Overall verdict (worst-of, weighted by convergence + confidence):

- **GO** — 0 blockers; only improvements / nits.
- **GO-WITH-CHANGES** — blockers exist but all are small, local, and fixable by editing the plan text (no rethink).
- **REVISE** — blockers are structural: missing whole steps, wrong sequencing, an unverified core dependency, or a security gap on a new surface.
- **NO-GO** — a core assumption is false, the approach cannot meet the goal, or `devils-advocate` lands a confirmed fatal flaw with at least one corroborating persona.

**Veto seats:** a high-confidence `no-go` from `feasibility-soundness` or `security-privacy` outweighs several low-confidence `go`s — a plan that references things that don't exist, or opens an isolation hole on a new surface, should not get a GO on majority vote. A lone, low-confidence `no-go` with no corroboration → downgrade to `REVISE` and list it as an open question. State the consensus count (how many personas' verdicts align with the final one).

## Critical Conventions

- **READ-ONLY.** Reviewers verify the plan against the real codebase but never modify code or the plan. The only file each agent writes is its own `<DIR>/<persona-id>.json`. No worktree is needed — nothing is mutated.
- **Materialize the plan** to `<DIR>/PLAN.md` so all agents review byte-identical input — never rely on conversation context reaching the sub-agents.
- **Inject full context per agent** — persona focus, output schema, plan path, repo path, output path, and the READ-ONLY mandate. Agents start fresh with no history and do not read this skill file.
- **Single parallel batch.** Request the whole reviewer cast at once so Codex runs them in parallel — serial spawning wastes wall-clock.
- **Always cast `devils-advocate`** — the red-team seat is the highest-signal seat for plan review.
- **Default N = 6**, also parsed from natural language; clamp 3–10.
- **Advisory, not executory.** The skill outputs a verdict + amendments and stops. It writes no code, does not approve the plan, and does not trigger the TDD workflow.
