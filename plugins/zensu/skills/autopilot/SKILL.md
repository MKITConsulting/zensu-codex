---
name: zensu-autopilot
description: >
  Take a feature from a plain-language idea to a ready, validated GitHub pull
  request — autonomously. One interactive planning gate (spec + acceptance
  criteria), then a fully unattended build: implement via the Zensu workflow
  (vanilla `$zensu-tdd` + review chain), open the PR, run `$zensu-pr-team-review`
  once, fix every finding with `$zensu-pr-fix-findings`, then validate the running
  feature against every acceptance criterion in a fix loop until green. Works for
  any stack and app type (web, API, CLI, async, infra, mobile, desktop) via a
  pluggable validation driver, and is credential-blind — the AI never sees a
  password or token. Stops at a ready PR; the human reviews and merges. Use
  whenever the user wants a feature built end-to-end, "idea to PR", "build it and
  validate it", "plan, build, test, hand me a PR", an autonomous/unattended
  feature build, or the `$zensu-autopilot` command. The skill self-configures
  on first run and never auto-merges or auto-deploys.
---

# $zensu-autopilot

One command takes a feature from idea to a **ready, validated PR**. Exactly **one**
interactive gate — planning. Everything after is autonomous. The final merge is always
the human's. Generic across stacks and app types via a pluggable validation **driver**,
and **credential-blind**: the AI never holds a secret.

> It flies the whole route — idea → reviewed → validated → ready PR. **You land it.**

## Arguments

Invocation: `$zensu-autopilot <feature in plain words> [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<feature>` | yes | — | The feature to build, in plain language. The only thing most users type. |
| `--driver=<name>` | no | auto (probe) | Force the validation driver: `browser`/`api`/`cli`/`async`/`iac`/`custom`. |
| `--base=<branch>` | no | `main` | PR base branch. |
| `--no-validate` | no | off | Skip Phase 1 step 6 (live validation). Ship a reviewed+tested PR only. Degrades — note it. |
| `--config=<path>` | no | `.zensu/autopilot.yaml` | Project recipe file (see `rules/config.md`). |

If `<feature>` is missing, ask the user in Phase 0 (the one place asking is allowed).

## Prerequisites

- A git repository. The skill works **in a worktree only** — if the session is on the
  origin checkout it creates one first (see Critical Conventions).
- `gh` CLI authenticated (`gh auth status`) for opening the PR + the review steps.
- The sibling Zensu skills are present (same plugin): `$zensu-tdd`,
  `$zensu-pr-team-review`, `$zensu-pr-fix-findings`.
- Everything else — how to boot, gate, authenticate, and validate the project — the
  skill **discovers and verifies itself** in Phase 0. No config to hand-write.

## The one rule

**Phase 0 (planning) is the only time the skill may ask the user anything.** After the
plan is approved it drives to a ready PR without a single question. If it hits a genuine
blocker mid-run it makes the **safest reversible** assumption and records it in the
report; only a true stop-the-world blocker (no scriptable login AND auth is required, an
AC that is impossible as written, a missing toolchain with no degradation) may halt — and
then it halts and reports rather than guessing on anything irreversible.

## Workflow

Three phases. Track each with Codex's `update_plan` tool so the user has a live
progress view.

### Phase 0 — Probe & Plan  (the ONLY interactive gate)

**0.A — Worktree.** If `git rev-parse --show-toplevel` is the origin checkout (not a
worktree under `.worktrees/`), create one and continue inside it
(`git worktree add .worktrees/<slug> -b <branch> <base>`). Never build on the
origin checkout. See Critical Conventions.

**0.B — Probe (self-setup).** Resolve the four seams the run needs — **boot**, **gates**,
**auth**, **validate** — by the resolution order in `rules/probe.md`:

```
1. explicit --flags                       (override)
2. project config        .zensu/autopilot.yaml
3. auto-detect from repo  package.json / Makefile / compose / go.mod / pyproject /
                          *.tf / xcodebuild scheme / CLAUDE.md
4. confirm any gaps in THIS planning gate (plain-language, best guess pre-filled)
5. write the resolved recipe back  → next run skips 3+4
```

**Verify before trust:** actually boot the stack and obtain a session **once**, now, in
Phase 0. A wrong guess surfaces here, not mid-loop. Silent to the user if it works; if it
fails, that becomes one of the plain questions in 0.D. Pick the validation **driver** from
the detected app type — see `rules/drivers.md`.

**0.C — Plan.** Turn the feature into:
1. A short **spec** — what it does, who it's for, who it's NOT for, success, out-of-scope.
   Read the relevant domain docs first if the feature touches an existing area.
2. **Acceptance criteria** — a NUMBERED list, each one machine-checkable: verifiable by a
   test, a gate assertion, or a concrete observation through the validation driver. No
   vague ACs. For any UI, pin the visual/UX criteria explicitly (copy, states, empty/error,
   responsive); if "how it should look" can't be pinned in text, ask for a mockup or
   reference screenshot **now**. The ACs are the contract Phase 1 validates against —
   anything not in an AC will not be checked.
3. **Every open question batched** — defaults, edge cases, scope cuts, data shape — asked
   in this phase. This is the only chance.

**0.D — Confirm.** Present spec + numbered ACs + the resolved recipe (the boot / auth /
gates / validate commands the probe chose, so the user sees exactly what will run) and
wait for the user's explicit approval. If the probe wrote or
would write `.zensu/autopilot.yaml`, propose committing it (secret-free, shared) — but
**never commit without the user's explicit OK**.

### Phase 1 — Build  (autonomous, ZERO questions) — strictly ordered

Run these in order. Implement **via the Zensu workflow** throughout.

1. **Implement** — invoke `$zensu-tdd` (vanilla mode) with the spec + ACs as the feature
   specification. Let the built-in 5-perspective review chain (conventions, bugs,
   architecture, tests, security) run and address what it raises. Stay in the worktree.
2. **Gates green** — run every command in the resolved `gates:` recipe; all must pass
   before the PR opens (e.g. type-check, lint, unit tests, per-file coverage floor).
3. **Open the PR** — commit (Conventional Commits, no watermark), push, open the PR
   against `--base` (English title + body). The body carries a per-AC table (status filled
   in after step 6).
4. **Team review — ONCE** — run `$zensu-pr-team-review` on the PR. This is the single deep
   multi-persona pass. It runs **exactly once** and does **not** re-run in the loop.
5. **Fix the findings** — run `$zensu-pr-fix-findings` and loop it until every review
   thread from step 4 is resolved. Re-run the step-2 gates, then push so the PR reflects
   the fixes.
6. **Validate ↔ fix LOOP** — only now exercise the running feature:
   a. Run the resolved validation **driver** (see `rules/drivers.md`), authenticating via
      the credential-blind login script if one is configured (see `rules/auth.md`). Assert
      **every numbered AC** and capture evidence per AC.
   b. Every AC passes + gates green → **exit the loop**.
   c. Anything off → fix it through `$zensu-tdd` (vanilla, scoped to the failing AC(s)),
      re-run the step-2 gates, push to update the PR, then go back to (a).
   d. Repeat (a)–(c) until all ACs pass. `$zensu-pr-team-review` does **not** re-run here.

### Phase 2 — Deliver

Stop at a **ready, pushed PR** whose body contains a per-AC pass/fail table with the
evidence. Then:
- **Do NOT merge, push a release, or deploy.** The final merge is the human's.
- Report: the PR link, the per-AC table, what looped and why, and anything decided
  autonomously that the user may want to revisit.

## The two seams

The orchestration above is constant. Only two things vary per project, both resolved by
the probe:

```
Driver           = how the app is exercised + ACs observed
                   browser | api | cli | async | iac | mobile | desktop | custom   (rules/drivers.md)
Session artifact = what "logged in" means for that driver
                   storageState | bearer-token-file | keychain | none              (rules/auth.md)
```

Everything else is identical across stacks. Unknown target → `custom` driver (two project
scripts), never a dead end.

## Credential-blind auth (iron rule)

**The AI never sees a password or token.** When a feature needs an authenticated session,
a project **login script** holds the secret, performs the login, writes a session
**artifact**, and prints exactly one line — `<KEY>=<path|ok>` — never the secret itself.
The skill receives only the path, loads the artifact into the driver, and validates. A
script ships **no app code** (zero prod attack surface), which is why it is preferred over
a test-login endpoint. Full contract, artifact handling, and the security rules:
`rules/auth.md`.

## Config

`.zensu/autopilot.yaml` — committed, shared, **secret-free**, written by the skill after a
successful probe and hand-editable but never required. Real secret values live in a
gitignored `.env`, referenced by name only; throwaway login credentials are derived at
runtime inside the login script. Schema + a concrete worked instance: `rules/config.md`.

## Degradation ladder (never dead-end)

```
no start command found   → one plain question in Phase 0 (best guess pre-filled)
no scriptable login      → one question OR skip authenticated validation + note it
no UI                    → validate via api / cli / custom, no browser
toolchain missing        → degrade that driver, note what was skipped
worst case               → still a reviewed, tested PR — minus the live proof, stated
```

The worst case is still a reviewed, gated PR. The skill never produces nothing.

## Reference Files

- `rules/probe.md` — detection sources per stack, the resolution order, verify-before-trust,
  and how the resolved recipe is written back.
- `rules/auth.md` — the credential-blind login-script contract, artifact forms + handling,
  the no-endpoint rule, and the security checks the skill enforces.
- `rules/drivers.md` — the driver catalog: how to exercise + assert per driver, sub-modes,
  cross-cutting augments, on-demand drivers, and the `custom` escape hatch.
- `rules/config.md` — `.zensu/autopilot.yaml` schema, a concrete worked instance, and the
  login-script prerequisite a project supplies.

## Critical Conventions

- **Worktree only.** The origin checkout is never built on. If the session starts there,
  `git worktree add .worktrees/<slug> -b <branch> <base>` and continue inside it.
- **One planning gate.** Zero questions after approval — safest reversible assumption +
  note for non-blockers; halt + report only on a true blocker.
- **Credential-blind.** The AI never receives a password or token; a script delivers auth
  and returns only an artifact path. Artifacts are treated as credentials (temp dir,
  `chmod 600`, deleted after the run, never logged or printed).
- **Never auto-merge / auto-deploy.** Stop at a ready PR. The merge is the human's.
- **Never push to a merged/closed branch.** Re-check `gh pr view <n> --json state,mergedAt`
  immediately before every push; if `MERGED`/`CLOSED`, branch off `origin/<base>` and open
  a fresh PR.
- **English PR + commits.** Conventional Commits. No AI watermark / co-author trailer.
- **iac never against prod.** Default plan/dry-run + kind/localstack/throwaway target;
  `apply` only to a disposable environment (see `rules/drivers.md`).
- **Review runs once.** `$zensu-pr-team-review` is the single mid-point pass; the tail loop
  is `$zensu-pr-fix-findings` + validate, never another team review.
