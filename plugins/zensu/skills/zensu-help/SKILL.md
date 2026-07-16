---
name: zensu-help
description: Answer questions about how Zensu (the SaaS Product Lifecycle Manager) and the Zensu Codex plugin itself work — an in-conversation glossary, architecture explainer, and config reference. Use for "what is X / how does Y work / where is Z configured" questions about Zensu concepts or plugin internals; does NOT execute workflows.
---

# $zensu-help

Answer questions about how Zensu (the SaaS Product Lifecycle Manager) and the Zensu Codex plugin itself work. Acts as an in-conversation glossary, architecture explainer, and config reference — does NOT execute workflows.

## When to Use

- User asks "what is X?", "how does Y work?", "where is Z configured?"
- User asks about plugin internals: agents, hooks, FSM, auto-fix loop, the `zensu` CLI
- User asks about Zensu concepts: features, KEY-N identifiers, tiers, journeys, classifications
- User asks "what changed in version X" or "how do I disable hook Y"
- User is unsure which other skill (`bootstrap` vs `ghost-scan` vs `implement`) applies to their situation

## Do NOT Use For

- Executing workflows → use `$zensu-bootstrap`, `$zensu-ghost-scan`, `$zensu-implement`, `$zensu-security-review`, `$zensu-pulse`, `$zensu-reset-review-limit`
- Modifying Zensu data — this skill is read-only Q&A

## Prerequisites

None. This skill answers from embedded knowledge and the plugin's canonical docs already present in the repository. No Zensu account or network required.

## Core Glossary (embedded — stable concepts)

- **Product** — top-level container; owns Components, Tiers, Features, Journeys.
- **Component** — architectural module within a Product (e.g. `auth-service`).
- **Feature** — unit of capability, identified by a product key plus number (for example `ZEN-42` or `AUTH-7`). Lifecycle: `planned → in-progress → testing → released`.
- **Tier** — pricing/availability level (e.g. Free, Pro, Team). Features map to tiers via the tier matrix.
- **Journey** — user path through one or more Features; contributes to release readiness.
- **Security Classification** — `public | internal | confidential | restricted`. Drives the 0–10 security score.
- **Security Score** — computed from classification + OWASP tags + compliance tags + security tests + reviews.
- **Revision** — a Feature's build-out *stage* over time. Auto-versioned (v1, v2, …); each tracks scope changes, acceptance criteria, breaking changes, effort, and target release. v1 is the baseline stage; later revisions are deeper build-out. `$zensu-ghost-scan` seats each discovered feature at a v1 baseline; `$zensu-implement` adds one per implementation.
- **Subfeature** — *structural* fan-out of a Feature into child parts (same component + release): workflow steps, happy-vs-error paths, interface or data variations. A feature's two growth axes are revisions (stages over time) and subfeatures (parts); both differ from the product-level roadmap (features across a quarter timeline).

## Three Layers (embedded — architecture overview)

1. **Planning** (interactive main thread) — `$zensu-bootstrap` (greenfield: a plan/vision doc, no code yet) or `$zensu-ghost-scan` (brownfield: an existing codebase) produce tracked features, user journeys, and linked docs. The optional `zensu-plm` subagent is a read-only analyst that recommends a route; it never performs mutations.
2. **Implementation** (`$zensu-tdd` skill in the MAIN thread + reviewers) — vanilla implementation is the default; opting into `hooks.tddImplementation=true` adds FSM-gated RED→IMPL→GREEN discipline. Both modes run evidence audits, five parallel read-only review aspects, consolidation, fixes, and terminal self-review. Codex's `Stop` hook is an advisory reminder, not a hard block.
3. **Tracking** — web dashboard surfaces security scores, journey health, tier matrix, coverage trends.

## Agents (embedded — one-liners)

- `zensu-plm` — optional read-only planning analyst; recommends a main-thread skill and never performs mutations.
- `zensu-code-reviewer` — READ-ONLY consolidation subagent for the review packet and aspect findings.
- `zensu-review-aspect` — single-perspective READ-ONLY subagent; five run in parallel for the TDD review chain fan-out.

The `$zensu-tdd` workflow is not a subagent: vanilla implementation runs in the
main thread by default, while strict opt-in adds RED→IMPL→GREEN, FSM-gated
edits, retry escalation, and completeness audits.

## Topic Routing (live read for volatile facts)

Before answering questions in the right column, `Read` the source file in the left column and quote `file:line` in the answer.

| Question type | Source to Read |
|---|---|
| Plugin version, declared skills/agents | `.codex-plugin/plugin.json` |
| CLI command surface / install; plugin tool wiring | `README.md` § Install + `zensu --help` + `.codex-plugin/plugin.json` (the MCP server stays live for the Zensu web app but is no longer wired into the plugin) |
| Hook flags (`autoTdd`, `tddImplementation`, `chainEnforcer`, `autoFix`, `autoFixIncludeSuggestions`, `autoFixMaxRounds`, `combinedSummary`, `selfReview`, `pulseSession`, `sessionBanner`) | `README.md` § Configuration |
| Context-nudge settings (`context.compactionNudge`, `context.nudgeThreshold`, `context.windowSize`) — top-level `context` node, gate the `/compact` proposal | `README.md` § Configuration + `hooks/user-prompt-context-nudge.sh` |
| Config resolution order, `ZENSU_CONFIG` precedence | `README.md` § Configuration |
| Environment variables (`ZENSU_API_URL`, `ZENSU_TDD_GATE`, `ZENSU_TEST_WITNESS`, `ZENSU_CHAIN`, hook-only `ZENSU_PLUGIN_ROOT`/`CODEX_PLUGIN_ROOT`, injected main-thread `ZENSU_SESSION_KEY`, host-only `CODEX_THREAD_ID`) | `README.md` § Configuration (Environment overrides) + § The TDD engine |
| Exact Session Control v1 record binding, stable-reader ABI v3, and failure recovery | `README.md` § Lifecycle hooks + § The TDD engine + § Troubleshooting; `hooks/lib/session-control-core-v1.js`, `hooks/lib/codex-session-control-v1.js`, `hooks/lib/codex-session-control-resolve-v3.js` |
| TDD FSM details, phase transitions, gate logic, logging | `docs/tdd-manager-workflow.md` + `README.md` § The TDD engine |
| Documentation: doc types, how to write code-grounded feature/wiki docs | `docs/documentation-guide.md` |
| Hook scripts (what each does, when it fires) | `README.md` § Lifecycle hooks + `hooks/<script>.sh` source |
| Data flow, what's transmitted, retention, self-hosting | `README.md` § Authentication + `skills/pulse/SKILL.md` |
| Pulse session lifecycle, idempotency, privacy guarantees | `skills/pulse/SKILL.md` |
| Resetting the auto-fix rounds counter / "max rounds reached" recovery | `skills/reset-review-limit/SKILL.md` + `hooks/post-review-tdd-delegate.sh` (convergence branch; reference-only on Codex) |
| Workflow step order (new product / existing codebase / quick feature) | `README.md` § What is Zensu + the relevant `skills/<name>/SKILL.md` |
| Greenfield vs brownfield vs hybrid; feature build-out stages (revisions) & fan-out | Core Glossary (above) + `agents/zensu-plm.toml` § Decision Rules |
| "What changed in version X" | `CHANGELOG.md` (search for `[X.Y.Z]`) |
| License / Permitted Purpose / Competing Use | `README.md` § License + `LICENSE` file |
| What's enforced vs advisory on Codex | `README.md` § Capabilities & enforcement on Codex |
| Platform support, requirements, Windows caveats | `README.md` § Requirements |
| Install / auth / troubleshooting (`zensu` CLI not found, OAuth login, auth errors) | `README.md` § Install + § Authentication + § Troubleshooting |

## Response Style

- Cite sources as `README.md:200` or `docs/tdd-manager-workflow.md`.
- If the embedded glossary fully answers it → answer directly, no Read needed.
- If a routed source applies → Read first, quote facts verbatim, cite.
- Never invent tool names, hook names, config flags, or version numbers — verify via Read.
- If a question falls outside this skill's scope (e.g. "implement feature ZEN-042"), point the user at the right action skill instead of half-answering.
- Match the conversational register — terse if the user is terse, fuller if they ask "explain in detail".
