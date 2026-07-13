# Zensu for Codex

![version](https://img.shields.io/badge/version-0.3.1-blue)
![license](https://img.shields.io/badge/license-FSL--1.1--Apache--2.0-green)

**Product Lifecycle Manager — features as first-class citizens, for the [OpenAI Codex CLI](https://developers.openai.com/codex/).**

`zensu-codex` is the [Zensu](https://zensu.dev) Product Lifecycle Manager packaged as a native plugin for the [OpenAI Codex CLI](https://developers.openai.com/codex/). It delivers feature tracking, strict RED→GREEN TDD with a phase-gated edit guard, a five-perspective code-review chain, security reviews, release-readiness gating, and greenfield/brownfield onboarding — as a Codex plugin: a `.codex-plugin/plugin.json` manifest, `skills/`, `agents/` (subagents), and `hooks/`, installed through Codex's native plugin system. The plugin drives Zensu through the typed [`zensu` CLI](https://zensu.dev) (≥ 0.2.0); the hosted MCP server stays live for the Zensu web app's own assistant but is no longer wired into the plugin. Per-release changes are tracked in [CHANGELOG.md](CHANGELOG.md).

> **Status:** local plugin, not yet published to a remote marketplace. Install from this checkout with `codex plugin marketplace add` (see below).

---

## Table of contents
- [What is Zensu?](#what-is-zensu)
- [Agent & workflow overview](#agent--workflow-overview)
- [Requirements](#requirements)
- [Install](#install)
- [Authentication](#authentication)
- [What you get](#what-you-get)
  - [The zensu CLI](#the-zensu-cli)
  - [Skills](#skills)
  - [Subagents](#subagents)
  - [Lifecycle hooks](#lifecycle-hooks)
- [The TDD engine](#the-tdd-engine)
- [Configuration](#configuration-zensuconfigjson)
- [Troubleshooting](#troubleshooting)
- [Capabilities & enforcement on Codex](#capabilities--enforcement-on-codex)
- [Repository layout](#repository-layout)
- [Uninstall](#uninstall)
- [How it's built](#how-its-built)
- [License](#license)

---

## What is Zensu?

Zensu is a SaaS Product Lifecycle Manager (PLM) that treats **features as
first-class citizens** across the entire software lifecycle — from roadmap to
release. The CLI plugin is the in-terminal front door to that SaaS, plus a
stack-agnostic TDD/review discipline engine that works even with no account.

Core model:
- **Organizations → Products.** A product owns **Components** (domain modules),
  **Tiers** (pricing levels with feature gating), **Features**, and **User Journeys**.
- **Features** carry `ZEN-XXX` IDs (e.g. `ZEN-001`), referenced in commits as
  `[ZEN-001]`. Status lifecycle: `planned → in-progress → testing → released`,
  gated by a **security score** (0–10), **docs completeness**, and **journey health**.
- Per-feature build-out runs along two axes: **revisions** (`zensu features revision`,
  v1/v2…, stages over time) and **subfeatures** (`zensu subfeatures add`, structural parts).

Three layers of behavior:
1. **Planning (what):** the `zensu-plm` agent + `$zensu-bootstrap` (greenfield) /
   `$zensu-ghost-scan` (brownfield) / hybrid.
2. **Implementation (how, securely):** `$zensu-tdd` — strict RED→GREEN TDD,
   enforced by a PreToolUse phase-gate, followed by a five-perspective review chain.
3. **Tracking (progress):** a web dashboard (outside this repo) fed by the same Zensu backend.

---

## Agent & workflow overview

Zensu's three-layer flow, with the Codex
specifics baked in: skills are invoked as `$zensu-x`, the plan-approval ask is
an `AGENTS.md` + primer convention (Codex has no `ExitPlanMode` hook event), the
review chain fans out five explicitly-spawned `zensu-review-aspect` subagents
before consolidating through `zensu-code-reviewer`, and the auto-fix loop is
skill-driven (backstopped by the advisory Stop hook). The Implementation layer
shows both modes: **vanilla** (the default — no RED→GREEN ceremony, the edit
gate passes through, review chain and evidence audits stay enforced) and
strict RED→GREEN, opt-in via `hooks.tddImplementation=true`.

```mermaid
flowchart TD
    subgraph Planning["Layer 1: Planning"]
        A1["$zensu-bootstrap<br/>(greenfield)"] --> B["zensu-plm subagent"]
        A2["$zensu-ghost-scan<br/>(brownfield)"] --> B
        B --> C["Features in Zensu"]
    end

    subgraph Implementation["Layer 2: Implementation"]
        C -->|"$zensu-implement"| D["Load Feature Context"]
        PLAIN["Plan approval<br/>(AGENTS.md + primer convention,<br/>no ExitPlanMode hook)"] -->|"ask, then invoke skill on yes"| E
        D --> E["$zensu-tdd skill<br/>(main thread)"]
        E --> MODE{"hooks.tddImplementation?"}
        MODE -->|"true · strict (opt-in)"| RED["RED — write failing test"]
        MODE -->|"false/absent · vanilla (default):<br/>no RED→GREEN, gate passes through"| VAN["IMPL — write code directly<br/>(tests at discretion)"]
        VAN --> FAN
        RED --> IMPL["IMPL — minimum code"]
        IMPL --> GREEN{"GREEN — test passes?"}
        GREEN -->|"No (≤ 3 retries)"| IMPL
        GREEN -->|"Yes"| NEXT{"More steps?"}
        NEXT -->|"Yes"| RED
        NEXT -->|"No"| FAN["5× zensu-review-aspect<br/>(parallel · read-only)"]
        FAN --> K["zensu-code-reviewer<br/>(consolidate, consume mode)"]
        K --> L["Review Report"]
        L -->|"auto-fix, skill-driven<br/>(≤ autoFixMaxRounds)"| E
        L -->|"converged (PASS / max rounds)"| SR["$zensu-self-review<br/>(terminal · ≤ 1 fix round)"]
        SR --> FR(["Final Report"])
        GATE["PreToolUse FSM gate<br/>(apply_patch parser)"] -.guards.-> RED
        GATE -.-> IMPL
        GATE -.-> GREEN
    end

    subgraph Tracking["Layer 3: Tracking"]
        FR -->|"link artifacts"| M["Zensu Dashboard"]
        M --> Q["Release Gate"]
        M --> P["Journey Health"]
        M --> O["Tier Matrix"]
        M --> N["Security Scores"]
    end

    style A1 fill:#4a9eff,color:#fff
    style A2 fill:#4a9eff,color:#fff
    style PLAIN fill:#4a9eff,color:#fff
    style E fill:#ff6b6b,color:#fff
    style MODE fill:#fff3bf,color:#1e293b
    style VAN fill:#b197fc,color:#fff
    style GATE fill:#888,color:#fff
    style FAN fill:#ffd43b,color:#1e293b
    style K fill:#ffa94d,color:#fff
    style SR fill:#dcfce7,stroke:#166534,color:#1e293b
    style M fill:#51cf66,color:#fff
```

---

## Requirements

- **Zensu CLI ≥ 0.2.0** (`zensu --version`) on `PATH` — the plugin drives Zensu
  through it. Install: `curl -fsSL https://zensu.dev/install.sh | sh`, then
  `zensu auth login`.
- **Codex CLI ≥ 0.130.0** (`codex --version`). Verified against 0.130.0, where
  the `hooks`, `plugins`, and `multi_agent` features are **stable**.
- **Node.js** (Codex bundles a Node launcher; the hook scripts use `node` for
  JSON parsing — Node 18+ on PATH is sufficient).
- **bash** + **git** (the hooks and installer are POSIX bash; macOS/Linux, or
  Windows via WSL/Git Bash).

---

## Install

```bash
# 1. Install the Zensu CLI (the plugin drives Zensu through it) and sign in
curl -fsSL https://zensu.dev/install.sh | sh
zensu auth login          # browser OAuth2 + PKCE (see Authentication)

# 2. Register the marketplace (a local dir now; owner/repo once pushed to GitHub)
codex plugin marketplace add /absolute/path/to/zensu-codex

# 3. Install the plugin (interactive picker)
codex /plugins            # select "Zensu" -> Install

# 4. Enable + trust the lifecycle hooks (TDD gate, witness, stop-enforcer, banner)
codex --enable plugin_hooks   # plugin_hooks is under development on 0.130.0
codex /hooks                  # review -> Trust the zensu hooks
```

Installing the plugin registers its components straight from
`.codex-plugin/plugin.json`: the 10 skills, the 3 subagents, and the lifecycle
hooks (`hooks/hooks.json`). Zensu data access goes through the `zensu` CLI you
installed in step 1 — the hosted MCP server is no longer wired into the plugin.
Restart Codex (or open a new session) afterward.

(Optional) To carry the Zensu conventions even with hooks disabled, append this
repo's `AGENTS.zensu.md` to `~/.codex/AGENTS.md`.

### Trust the hooks (required, one-time)

Codex does not run any **non-managed** hook until you review and trust it — a
security gate that applies to user, project, AND plugin hooks alike. After
installing, start Codex and run **`/hooks`**: inspect the zensu hook sources and
**Trust** them. Until you do, the TDD phase-gate, the test witness, the Stop
chain-enforcer, and the session banner stay inactive (Codex prints a startup
warning telling you to open `/hooks`). Trust is keyed to each hook's content hash,
so after a plugin update that changes a hook you re-trust it via `/hooks`. Only
enterprise **managed** hooks (`requirements.toml`) skip this review.

> **Heads-up on hooks (0.130.0):** plugin-bundled hooks execute only when the
> `plugin_hooks` feature is enabled (step 4), and it is still *under development*
> on 0.130.0 (verified via `codex features list` + openai/codex PR #19705) — so
> the TDD phase-gate and the other hooks may not fire reliably until it stabilizes.
> Skills, subagents, and the `zensu` CLI do **not** depend on it and work today.
> When plugin hooks do run, Codex injects `CLAUDE_PLUGIN_ROOT` into their
> environment, which the hook scripts use to resolve the plugin root. See the
> capability matrix below.

---

## Authentication

The plugin drives Zensu through the typed `zensu` CLI, which talks to the Zensu
backend (default `https://api.zensu.dev`). Authenticate the CLI once:

- **OAuth (default, interactive):** sign in through the browser (OAuth2 + PKCE):
  ```bash
  zensu auth login
  zensu auth status     # verify; `zensu auth logout` clears credentials
  ```
- **API key (CI / headless):** log in with a key instead of the browser:
  ```bash
  zensu auth login --with-token zsk_...      # or:  echo "$ZSK" | zensu auth login --with-token -
  ```
- **Self-hosting:** point the CLI at your own endpoint, by flag or environment.
  Resolution order: `--api-url` flag → `ZENSU_API_URL` → stored host → `https://api.zensu.dev`.
  ```bash
  zensu auth login --api-url https://api.example.internal
  # or, per-invocation:
  export ZENSU_API_URL=https://api.example.internal
  ```

> **MCP note.** The hosted MCP server at `https://mcp.zensu.dev/mcp` is **no
> longer wired into the plugin** — it stays live for the Zensu web app's own AI
> assistant. Earlier `zensu-codex` releases registered it via `.mcp.json`; that
> file has been removed (see [CHANGELOG](CHANGELOG.md)).

> **Graceful degradation:** the TDD engine, code review, and progress logging
> work with **no Zensu account / no CLI sign-in**. The `zensu` CLI only augments
> the flow (auto-link tests/sources, status updates, revisions, release gating).

---

## What you get

### The zensu CLI

A GitHub-CLI-style binary (`zensu <noun> <verb>`) covering the full surface —
feature CRUD, subfeatures, linking, security, revisions, lifecycle, tiers,
journeys, bootstrap, product studio, docs context, wiki, knowledge search, pulse,
and ghost-scan. The skills and the `zensu-plm` agent invoke it by command
(`zensu features create`, `zensu ghost scan`, …); every command takes `--json`
and documents its flags via `zensu <noun> <verb> --help`. Driving the typed CLI
instead of the 74-tool MCP surface reclaims ~22k context tokens per request.

### Skills

Invoke with `$name` (or via the `/skills` menu). Each is a `SKILL.md` with YAML
`name`/`description` frontmatter (Codex's trigger mechanism).

| Skill | Purpose |
|---|---|
| `$zensu-bootstrap` | Greenfield: create product + vision, decompose into components/features, post-bootstrap setup. |
| `$zensu-ghost-scan` | Brownfield: scan a repo for features (multi-lens), apply, discover journeys, seat a v1 baseline. |
| `$zensu-implement` | Implement a tracked feature end-to-end (context → TDD → link artifacts → revision → validate). |
| `$zensu-tdd` | The heart: strict RED→IMPL→GREEN, phase-gated, with a guaranteed review chain. |
| `$zensu-plan-review` | Pre-implementation gate: a tailored multi-perspective reviewer panel returns GO / REVISE / NO-GO. |
| `$zensu-security-review` | Classify → analyze → suggest+link tests → STRIDE threat model → complete → validate. |
| `$zensu-self-review` | Terminal self-reflection across 7 dimensions; owns the review-chain terminus. |
| `$zensu-reset-review-limit` | Reset the auto-fix round counter and re-arm the review chain. |
| `$zensu-pulse` | Developer journal: start/end a dev session, review activity. |
| `$zensu-help` | Read-only Q&A about Zensu concepts and workflows. |
| `$zensu-pr-team-review` | Multi-agent PR review: auto-cast a persona team, review in parallel, publish one consolidated GitHub review via `gh api`. |
| `$zensu-pr-fix-findings` | Resolve every open PR review comment end-to-end: fix via the Zensu workflow, push, resolve threads, report back. |
| `$zensu-autopilot` | Idea → ready, validated PR autonomously: one plan gate, then build + team-review + fix + validate-loop. Never auto-merges. |

### Subagents

Codex subagents (`agents/*.toml`), spawned explicitly when you ask Codex to use them.

| Agent | Role |
|---|---|
| `zensu-plm` | Product Lifecycle Manager — orchestrates all `zensu` CLI workflows (feature tracking, security, journeys, tiers, bootstrap, ghost-scan, …). |
| `zensu-code-reviewer` | Five-perspective reviewer (conventions, bugs, architecture, tests, security) with build/test verification. |
| `zensu-review-aspect` | Single-perspective reviewer; five run in parallel for the TDD review chain. Runs `read-only` sandboxed. |

### Lifecycle hooks

All hooks read the host's JSON payload on stdin and emit the host's hook output
schema. They are engine-neutral (they resolve the plugin root from
`ZENSU_PLUGIN_ROOT`/`CODEX_PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT` or self-resolution,
and the project dir from the payload `cwd`). Each is gated by `~/.zensu/config.json`.

| Event (matcher) | Script | What it does |
|---|---|---|
| `SessionStart` | `session-start-pulse.sh` | Writes `~/.zensu/plugin-root`; prints a HEAD/branch readiness line. |
| `SessionStart` | `session-start-capture-sid.sh` | Caches the session id for later hooks. |
| `SessionStart` | `session-start-banner.sh` | User-facing "Zensu PLM active" banner (fresh starts only). |
| `SessionStart` | `session-start-primer.sh` | Model-facing orientation (plan → ask about `$zensu-tdd`). |
| `PreToolUse` (`apply_patch`/`Edit`/`Write`/`MultiEdit`) | `pre-edit-tdd-reminder.sh` | **The TDD phase-gate** — denies production edits until a failing test exists. |
| `PreToolUse` (`shell`/`Bash`/`exec_command`/`exec`) | `pre-bash-source-write-gate.sh` | Blocks raw shell writes (`>>`, `tee`, `sed -i`, `dd of=`) that clobber tracked source or escape the worktree into a sibling checkout. |
| `PostToolUse` (`shell`/`Bash`/`exec_command`/`exec`) | `post-bash-witness.sh` | Records every shell command to a witness log (anti-hallucination evidence). |
| `Stop` | `stop-chain-enforcer.sh` | Backstops the review chain (don't end a TDD turn before review completes). |
| `UserPromptSubmit` | `user-prompt-context-nudge.sh` | Suggests `/compact` when context occupancy crosses a threshold. |
| `UserPromptSubmit` | `user-prompt-intent-router.sh` | On a product/planning keyword, nudges the model to run the project-context triage and route via `zensu-plm`. |
| `UserPromptSubmit` | `user-prompt-tdd-reminder.sh` | Per-turn reminder to ask about `$zensu-tdd` before implementing code (Codex has no plan-approval event). |

Two hooks have **no matching Codex event** and are kept as the canonical
reference implementation (their behavior is carried by `AGENTS.md` + skill
prose): `plan-approved-delegate.sh` (plan-approval) and
`post-review-tdd-delegate.sh` (subagent-completion auto-fix loop).

---

## The TDD engine

`$zensu-tdd` runs strict, one-step-at-a-time RED→GREEN TDD. Each step declares
its phase through the helper:

```bash
bash "$(cat ~/.zensu/plugin-root)/hooks/lib/zensu-log.sh" --tdd-begin            # arm the gate + witness
bash "$(cat ~/.zensu/plugin-root)/hooks/lib/zensu-log.sh" --phase RED_WRITE --step 1
# write a failing test, run it…
bash "$(cat ~/.zensu/plugin-root)/hooks/lib/zensu-log.sh" --phase RED_FAIL  --step 1 --reason "asserts X"
bash "$(cat ~/.zensu/plugin-root)/hooks/lib/zensu-log.sh" --phase IMPL      --step 1
# implement until green, then GREEN_RUN / GREEN_PASS, optionally REFACTOR
```

The **phase-gate** (`pre-edit-tdd-reminder.sh`) reads the per-session FSM state
and allows/denies each edit:

| Phase | Test file | Production file |
|---|---|---|
| `RED_WRITE` | allow | allow |
| `RED_FAIL` | allow | **deny** |
| `IMPL` | allow (after a `RED_FAIL` for the step) | allow (after `RED_FAIL`) |
| `GREEN_PASS` | allow | **deny** |
| `REFACTOR` | allow | allow |
| `UNINITIALIZED` | deny | deny |

On Codex the gate parses the freeform `apply_patch` envelope (`*** Update/Add/
Delete File:` lines) — a patch touching several files is denied if **any** file
violates the current phase. Vanilla mode is the default; setting `hooks.tddImplementation=true` opts in to
the strict gate. In vanilla mode — `--tdd-begin` reads the config ONCE, freezes the
mode into the session state (echoing `mode: vanilla`; query later with
`zensu-log.sh --mode`), the gate passes through (the `.zensu/state/` deny stays),
and the RED→GREEN ceremony is dropped while the evidence audits and review chain
stay enforced. Config flips mid-session change nothing; the ask-before-implementation
flows keep asking, worded "Zensu workflow (vanilla implementation + review chain)".
Beware: a project-local `.zensu/config.json` checked into a repository pre-selects
the mode for every clone (the project file's keys deep-merge over the global
config, so `hooks.tddImplementation` set there wins per key) — and the same file can also set
`hooks.sessionBanner=false`, silencing the banner signal, which leaves the `mode:`
echo at `--tdd-begin` as the only per-session signal of an unexpected downgrade.
Full docs: [`docs/tdd-manager-workflow.md`](docs/tdd-manager-workflow.md).
Documentation authoring rules: [`docs/documentation-guide.md`](docs/documentation-guide.md).

---

## Configuration (`~/.zensu/config.json`)

Resolution: `$ZENSU_CONFIG` is a full override (read verbatim, no merge). Otherwise
the project `$CLAUDE_PROJECT_DIR/.zensu/config.json` is **deep-merged per key over**
the global `$HOME/.zensu/config.json` — the project wins per key, and keys it omits
fall through to the global instead of shadowing it wholesale. A missing file or key
means "enabled". Copy `config.example.json` to start.

| Key | Default | Effect |
|---|---|---|
| `hooks.autoTdd` | `true` | Plan→ask-about-TDD directive (advisory on Codex; see the capability matrix). |
| `hooks.tddImplementation` | `false` | **Vanilla mode is the default** (parity with zensu-claude-code); explicit `true` opts in to strict RED→GREEN. Vanilla drops the ceremony and phase markers; the edit gate passes through (`.zensu/state/` edits stay denied), tests at the agent's discretion; evidence audits + review chain stay enforced. Frozen per session at `--tdd-begin` (echoes `mode: …`; details in [The TDD engine](#the-tdd-engine)). |
| `hooks.chainEnforcer` | `true` | Stop-hook review-chain backstop. |
| `hooks.autoFix` | `true` | Auto-fix loop behavior (skill-driven on Codex). |
| `hooks.autoFixIncludeSuggestions` | `false` | Route all severities vs Critical+Important only. |
| `hooks.autoFixMaxRounds` | `5` (1–99) | Review→fix round cap + stop-block budget (`cap+3`). |
| `hooks.combinedSummary` | `true` | Render the 3-section chain-end summary. |
| `hooks.selfReview` | `true` | Terminal `$zensu-self-review` stage owns the chain terminus. |
| `hooks.pulseSession` | `true` | SessionStart HEAD/branch banner (plugin-root write is unconditional). |
| `hooks.sessionBanner` | `true` | User banner + model primer on fresh starts. |
| `hooks.intentRouter` | `true` | UserPromptSubmit nudge toward the product-planning triage on a Zensu keyword. |
| `hooks.tddReminder` | `true` | Per-turn UserPromptSubmit reminder to ask about `$zensu-tdd` before code edits. |
| `context.compactionNudge` | `true` | `/compact` nudge on/off. |
| `context.nudgeThreshold` | `50` (1–99) | Occupancy % at which the nudge fires. |
| `context.windowSize` | unset | 100%-denominator token budget (unset → auto-tier 200k/1M). |
| `logging.timestampStyle` | `wall` | `wall` `[HH:MM:SS]` \| `relative` `[+HH:MM:SS]` \| `none`. |

**Environment overrides:** `ZENSU_CONFIG` (config path), `ZENSU_TDD_GATE=off`
(disable the phase-gate), `ZENSU_TEST_WITNESS=off`, `ZENSU_CHAIN=off` (disable
the Stop backstop), `ZENSU_API_URL` (self-host the `zensu` CLI's backend),
`ZENSU_PLUGIN_ROOT`/`CODEX_PLUGIN_ROOT` (override plugin-root resolution).

---

## Troubleshooting

- **`zensu: command not found`** — the CLI is not on `PATH`. Install it with
  `curl -fsSL https://zensu.dev/install.sh | sh` and reopen your shell. The
  session banner warns when `zensu` is missing.
- **Auth errors (401 / "not logged in")** — run `zensu auth login` (or
  `zensu auth login --with-token zsk_...` for CI), then verify with
  `zensu auth status`.
- **Self-hosted backend** — `zensu auth login --api-url <url>`, or export
  `ZENSU_API_URL`. Resolution order: `--api-url` → `ZENSU_API_URL` → stored host
  → `https://api.zensu.dev`.
- **Hooks not firing** — the TDD phase-gate, witness, Stop backstop, and banner
  are plugin hooks: enable plugin hooks and **Trust** them via `codex /hooks`
  (see Install). They are independent of Zensu CLI auth.
- **A `zensu` mutation ran outside a skill/agent** — Codex does **not** gate
  `zensu` CLI mutations (a write-gate is not wired on Codex; see the capability
  matrix). Route product changes through the `zensu-plm` agent or the `$zensu-*`
  skills to keep the workflow conventions (dedup, journeys, baseline revisions,
  security classification, release-readiness).

---

## Capabilities & enforcement on Codex

On Codex 0.130.0 most of Zensu's behavior is hook-enforced. A few capabilities
depend on host events Codex does not expose, or on payload/tool-name shapes the
hooks adapt to; those degrade to advisory or skill-driven. This matrix is the
honest map of what's enforced versus advisory.

| Capability | On Codex | Enforcement on 0.130.0 |
|---|---|---|
| Plugin manifest | `.codex-plugin/plugin.json` | **full** |
| Zensu backend access | typed `zensu` CLI (MCP server unwired) | **full** |
| Zensu write-gate (workflow enforcement) | **not wired** (deferred) — `PreToolUse(shell)` does not fire reliably on Codex | **advisory** |
| Skills | `skills/*/SKILL.md` (+ YAML frontmatter), invoked `$zensu-x` | **full** |
| Subagents | `agents/*.toml`, **explicit spawn** | **partial** — no proactive auto-delegation |
| Persistent instructions | `AGENTS.md` (global block) + SessionStart primer | **full** |
| `SessionStart` hooks | banner/primer/pulse/sid (Codex `SessionStart`, `source` field present) | **full** |
| `PreToolUse` TDD gate | `apply_patch` (parse patch) + Edit/Write, **deny** | **full** |
| `PostToolUse` witness | `shell`/`Bash`/`exec_command`/`exec` tools (argv array normalized, `Exit code:` envelope parsed) | **full** |
| `UserPromptSubmit` nudge | parser is Claude-transcript-shaped | **partial** — likely inert until adapted to Codex's rollout format |
| `Stop` review backstop | `{decision:block}` re-prompt + mode-aware fix wording (see CHANGELOG 0.2.0); Codex Stop can't hard-block | **advisory** |
| Plan-approval → ask TDD | **no host event** → `AGENTS.md` + primer convention | **advisory** |
| Auto-fix loop | **no host event** → `$zensu-tdd` skill prose + Stop backstop | **skill-driven** |
| Review chain (5 aspects) | `zensu-review-aspect` subagents (explicit spawn, parallel) | **partial** — parallel, but explicitly requested |
| State machine / logging / config | `hooks/lib/*` with local hardening (CHANGELOG 0.2.0) | **full** |
| Marketplace / install | `codex plugin marketplace add` + `codex /plugins` | **full** for skills/agents; hooks need `plugin_hooks` (under-dev) + `/hooks` trust |

**Bottom line.** The crown-jewel TDD phase-gate is **fully enforced** — its
`PreToolUse` deny stops production edits until a failing test exists. The
structural *guarantees* that depend on host events Codex does not expose — the
un-skippable Stop backstop, the auto-firing review loop, and a `zensu` CLI
write-gate — are strongly-instructed conventions instead (carried by `AGENTS.md`
and the skill prose). One place Codex is actually *stronger*: the
`zensu-review-aspect` subagent runs under an OS-enforced `read-only` sandbox.

---

## Repository layout

The repo is a Codex plugin **marketplace**; the plugin itself lives in a
subdirectory (the layout Codex expects — `marketplace.json` points at it).

```
zensu-codex/                             # repo = a Codex plugin marketplace
├── .agents/plugins/marketplace.json     # marketplace descriptor → source ./plugins/zensu
├── README.md  CHANGELOG.md  LICENSE     # repo docs
├── AGENTS.md                            # repo guide (for working in this repo)
├── reference/                           # canonical agent definitions (source of truth for subagents)
├── tests/smoke.sh                       # offline checks
└── plugins/zensu/                       # ← the plugin root (.codex-plugin/plugin.json)
    ├── .codex-plugin/plugin.json        # Codex plugin manifest (skills, agents, hooks)
    ├── AGENTS.zensu.md                  # optional conventions block to append to ~/.codex/AGENTS.md
    ├── config.example.json              # ~/.zensu/config.json template
    ├── agents/                          # 3 subagents: zensu-plm, zensu-code-reviewer, zensu-review-aspect
    ├── skills/                          # 10 skills (SKILL.md w/ frontmatter)
    │   ├── bootstrap/  ghost-scan/  implement/  tdd/  plan-review/
    │   └── security-review/  self-review/  reset-review-limit/  pulse/  zensu-help/
    ├── hooks/                           # hooks.json + *.sh + lib/ (config, session, tdd-phase, log, runtime)
    └── docs/                            # tdd-manager-workflow.md, documentation-guide.md
```

---

## Uninstall

```bash
codex plugin marketplace remove zensu   # or uninstall via  codex /plugins
codex /hooks                            # untrust the zensu hooks (optional)
```

This removes the plugin's skills, subagents, and hooks. It leaves the `zensu` CLI
(uninstall separately), `~/.zensu/config.json`, and any project `.zensu/`
artifacts in place. If you appended `AGENTS.zensu.md` to `~/.codex/AGENTS.md`,
remove that block by hand. Restart Codex.

---

## Testing

`tests/run-all.sh` runs three tiers (exit 0 iff every selected suite passes):

- **(no arg)** — deterministic only, no network / no Codex / no API: `tests/smoke.sh`,
  every `tests/structure/test-*.sh`, and the offline `evals/config-gate/`. This is what
  CI (`ci.yml`) runs on every push.
- **`--self-check`** — the above plus each live suite's skeleton (structure-only, no API).
- **`--live`** — the above plus the `codex exec`-driven suites (COSTS API credits; needs an
  authenticated `codex` CLI): `tests/e2e-{intent-router,context-nudge}/` and the reference
  eval `evals/tdd/` (proves Codex follows `$zensu-tdd` end to end, asserting on post-run
  state via `scripts/codex-promptfoo-wrapper.sh`).

The `--live` layer is opt-in only — a manual `.github/workflows/evals.yml`
(`workflow_dispatch`), never part of push/PR CI. Node + promptfoo are used solely by the
`--live` path; the default suite stays pure bash. See `evals/tdd/README.md` for the live
prerequisites (`codex login --device-auth`, `ZENSU_CODEX_HOME_OVERRIDE`).

---

## How it's built

The installed Codex CLI (0.130.0) was probed for its actual plugin / hook /
subagent / MCP support (the `features` flags and the native binary's embedded
schema) to design the manifest, hook state-machine, and subagent wiring above.
The skills, agents, and hook state-machine carry the full Zensu workflow logic;
only the engine-specific edges (tool names, payload fields, plugin-root/project-dir
resolution, the `apply_patch` gate) are Codex-specific.

---

## License

[FSL-1.1-Apache-2.0](LICENSE) — Functional Source License, Apache 2.0 Future
License.
