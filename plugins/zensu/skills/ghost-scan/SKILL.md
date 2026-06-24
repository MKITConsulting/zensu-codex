---
name: zensu-ghost-scan
description: Scan an existing repository to discover undocumented features, then review and import them into Zensu as tracked features with linked tests, docs, and source files. Use as the brownfield entry point when importing an existing codebase whose features are not yet tracked.
---

# $zensu-ghost-scan

Scan an existing repository to discover undocumented features, then review and import them into Zensu as tracked features with linked tests, docs, and source files.

## When to Use

This is the **brownfield** entry point — an existing codebase whose features are not yet tracked.

- Importing an existing codebase into Zensu for the first time
- Discovering undocumented features in a repository
- Linking tests, docs, and source files to newly created features

**Greenfield instead?** No code yet, just a plan/vision doc → use `$zensu-bootstrap`.

**Hybrid (existing code *and* a forward-looking plan doc)?** Run this scan first to import what is built, then create the plan's not-yet-built items as `planned` features. No separate skill; see Phase 6.

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`
- Authenticated: `zensu auth login` (check with `zensu auth status`)
- Product ID known (create one first with `$zensu-bootstrap` if needed)
- Working in the repository root (or a subdirectory)

Every command accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

Execute these phases in order. Present results to the user after each phase and wait for confirmation before proceeding.

### Phase 1: Setup & Context

1. Confirm the product ID via `zensu products list`
2. Run `zensu features list --product <product-id>` to load existing feature slugs
3. Show existing features to the user: "These features already exist and will not be suggested again"
4. Run `zensu journeys list --product <product-id>` to load existing journeys for dedup: "These journeys already exist and will not be re-suggested." This feeds the Phase 2b journey-analyst lens and Phase 5.
5. **Resume check:** If you have a prior scan id, run `zensu ghost candidates <scan-id> --product <product-id>` to check its status. If a scan in "review" status exists, ask the user whether to resume or start a new scan
6. Confirm the repo path and branch

### Phase 2: Repo Analysis & Candidate Extraction

1. Walk the file tree with periodic feedback: "Analyzing auth/ (15 files)... Analyzing users/ (8 files)..."
2. Skip these directories: `vendor/`, `node_modules/`, `dist/`, `.git/`, `__pycache__/`, `.next/`, `build/`, `target/`
3. Identify file types:
   - **Test files:** `*_test.go`, `*.test.ts`, `*.test.tsx`, `test_*.py`, `*_spec.rb`, `*.spec.ts`
   - **Source files:** `*.go`, `*.ts`, `*.tsx`, `*.py`, `*.java`, `*.rs` (excluding test files)
   - **Doc files:** `README*`, `docs/**/*.md`, `*.rst`, `CHANGELOG*`
4. Group files by module/package and extract feature candidates
5. **Populate each candidate's three detection arrays — `detectedSourceFiles`, `detectedTestFiles`, `detectedDocFiles`.** These arrays are the *only* data the scan apply (`zensu ghost apply`) uses to link artifacts — it links exactly what you pass, so an empty array links zero. Never leave `detectedTestFiles` empty by omission: an empty array must mean "globbed and found none," not "skipped." Note: `detectedDocFiles` links **existing** doc files in the repo (READMEs, `docs/*.md`) — it does not generate new documentation. Authoring new wiki docs for discovered features is a separate, code-grounded task: see `docs/documentation-guide.md` (read the source, never dump feature metadata).
6. **Tests are co-located — glob them per candidate.** Tests live in the same directories as a feature's source files. For each candidate, after collecting `detectedSourceFiles`, glob the test-file patterns from step 3 within those same directories *and* their sibling test dirs (`test/`, `tests/`, `__tests__/`, `spec/`, `specs/`), and assign every match to that candidate's `detectedTestFiles`. A capability feature spanning multiple modules collects tests from all of its source dirs.
7. **Docs are co-located too — glob them per candidate.** Apply the same rigor to docs as to tests: for each candidate, glob the doc-file patterns from step 3 (`README*`, `docs/**/*.md`, `*.rst`, `CHANGELOG*`) in the candidate's source dirs and the repo root, and assign every match to `detectedDocFiles`. Linking existing docs is first-class scan data, not a bonus — an empty `detectedDocFiles` must mean "globbed and found none," not "skipped."
8. **For large repos (>500 files):** Scan only top-level modules, max 3 directory levels deep. Ask the user if a deeper subdirectory scan is desired. Still glob the test and doc dirs at each scanned level — capping breadth must not silently drop tests or docs.
9. Filter candidates against existing features from Phase 1 to avoid duplicates
10. If a candidate matches an existing feature slug, **reuse the exact existing slug** — this enables enrichment during apply
11. Present candidates to the user as a table — do NOT submit yet, let the user review first
12. The user can edit, remove, or add candidates before submission

#### Candidate Quality Rules

**Feature-level, not function-level:**
- Prefer domain-level grouping: `authentication` instead of `auth-login`, `auth-register`, `auth-logout`
- If multiple packages share a domain concept, propose one feature, not several
- Minimum 3 source files for a feature (otherwise likely a utility)
- When in doubt, fewer and broader features — the user can split later with `zensu features split`

**Test-file completeness (treat like the source-file rule, not a bonus):**
- Every candidate that has source files MUST have its co-located tests detected (Phase 2, step 6). Populate `detectedTestFiles` with the same rigor as `detectedSourceFiles`.
- An empty `detectedTestFiles` is acceptable ONLY after globbing the candidate's source dirs confirms genuinely zero tests — never as a default for "didn't look."
- Shared/helper tests that map to no single feature (e.g. `app.controller.spec.ts`, `helpers/*.spec.ts`) may stay unlinked or attach to a shell/account feature — do not force them onto an unrelated candidate.

**Doc-file completeness (treat like the test-file rule, not a bonus):**
- Every candidate MUST have its co-located docs detected (Phase 2, step 7). Populate `detectedDocFiles` with the same rigor as `detectedTestFiles` — the scan apply links exactly what you pass, so an omitted array links zero docs.
- An empty `detectedDocFiles` is acceptable ONLY after globbing the candidate's source dirs + repo root confirms genuinely zero docs — never as a default for "didn't look."
- `detectedDocFiles` links **existing** docs only (READMEs, `docs/*.md`). It never generates new documentation — authoring docs for a feature with zero docs is a separate task flagged in Phase 6 (see `docs/documentation-guide.md`).

**Never create candidates for:**
- CI/CD configuration (`.github/`, `.gitlab-ci.yml`, `Jenkinsfile`)
- Build tooling (`Makefile`, `Dockerfile`, `docker-compose.yml`)
- Linting/formatting (`.eslintrc`, `.prettierrc`, `golangci.yml`)
- IDE settings (`.vscode/`, `.idea/`)
- Package manager locks (`go.sum`, `package-lock.json`, `yarn.lock`)
- Vendor/dependencies (`vendor/`, `node_modules/`)

#### Confidence Score Heuristic

Confidence scores are heuristic estimates, not ML predictions. Use them to prioritize review, not as ground truth.

| Tier | Range | Criteria |
|------|-------|----------|
| High | >= 0.7 | Dedicated tests + clear module boundary (own package) |
| Medium | 0.4-0.7 | Either tests OR docs present, or clear boundary without tests |
| Low | < 0.4 | No tests, no docs, unclear boundary |

Building blocks:
- Dedicated test files: +0.3
- Documentation present: +0.2
- Clear directory boundary (own package/module, >= 3 source files): +0.3
- README mention or config reference: +0.2
- Single file / unclear boundary: -0.2
- Utils/helpers/infrastructure code: -0.3

#### Security Classification Heuristic

Classify each candidate by **what data the feature itself reads or writes** — not by its
directory name or the product domain. Path is a weak hint; data sensitivity is the rule.
**Never default to `internal` for un-triaged code.** Present each suggestion to the user for
verification.

- `restricted`: handles credentials, keys, secrets, auth config, health data, or
  regulatory-controlled data (key management, auth/session, security tooling, compliance exports).
- `confidential`: directly reads or writes PII, customer business data, financial records, or
  personal data (user profiles, payments, roadmaps, journeys, product/feature data, org
  membership). **This is the bulk of a typical product** — when a feature touches customer data
  and you are unsure between `internal` and `confidential`, choose `confidential`.
- `internal`: requires standard auth but handles **no** PII or secrets — pure infra/ops surfaces
  (health checks, app shell, log viewers, aggregate-only dashboards). A feature that only displays
  aggregated data is `internal` even if a sibling that writes the underlying records is `confidential`.
- `public`: exposes no sensitive data and needs no auth (landing pages, public docs, blog,
  status pages).

### Phase 2b: Multi-Perspective Deep Analysis (fan-out)

The single-pass walk in Phase 2 is only a **seed**. A lone heuristic pass misses
features that span modules, live behind entry points, or are only legible from
tests, data models, or docs. Augment it — never replace it — with a parallel
fan-out of read-only analysis lenses, then consolidate in this main thread. This
is the house pattern already used by `$zensu-plan-review` and `$zensu-tdd` Phase 6.

1. **Spawn the lenses in ONE parallel batch.** Spawn read-only exploration
   subagents (Codex multi-agent: ask Codex to run these analysis agents — Codex
   runs explicitly-requested subagents, and runs them in parallel when asked) — the
   lenses cannot mutate the repo or the scan. Each agent gets: the repo path, the
   Phase 2 seed candidates, the existing features (dedup), the existing journeys
   (dedup, from Phase 1), its single lens focus, and the per-lens output schema
   below. This is the one sanctioned parallel batch of the workflow; everything else
   stays sequential.
2. **Adaptive lens count (cap 12).** Scale the roster to repo size so small repos
   stay cheap and large repos get full coverage:
   - `< 150 files` → ~4 lenses
   - `150–500 files` → ~8 lenses
   - `> 500 files` → up to the full 12
   Core lenses are ALWAYS cast regardless of size: **domain-boundary**,
   **test-mapper**, **journey-analyst**, **docs-coverage**.
3. **Lens roster (up to 12):**

   | Lens | Looks for |
   |------|-----------|
   | domain-boundary | user-facing domains from READMEs + package structure |
   | test-mapper | behaviors from test names/structure → feature clusters; fills `detectedTestFiles` gaps |
   | cross-module capability | features spanning multiple directories |
   | API/entry-point surface | routes, controllers, CLI commands, events, public exports |
   | data-model | schemas, migrations, domain entities |
   | journey-analyst | entry points + personas → ordered user paths → draft journeys |
   | security-surface | auth/crypto/PII → `securityClassification` |
   | config/integration | external integrations, webhooks, env contracts |
   | docs-coverage | README / `docs/**` near each candidate → `detectedDocFiles` + gap flags |
   | perf/runtime | background jobs, caches, queues → infra features |
   | error-handling/observability | logging, metrics, error paths |
   | persona-split | refine journeys per persona (admin vs end-user vs API consumer) |

4. **Per-lens output schema.** Each agent returns: missed features, merge/split
   suggestions, refined boundaries, per-candidate `detectedSourceFiles` /
   `detectedTestFiles` / `detectedDocFiles` additions, doc gaps, and **draft
   journeys** (persona + ordered steps referencing candidate slugs — abstract until
   apply, since `zensu journeys step` needs real feature IDs that exist only after
   Phase 4).
5. **Consolidate in this main thread (not a subagent).** Dedup by slug, reuse the
   exact existing slug on a match (enables enrichment during apply), union the three
   detection arrays per slug, and keep grouping feature-level not function-level.
   Carry the merged draft-journey list forward to Phase 5.
6. **No silent caps.** When repo size trims the roster, `log` (tell the user) how
   many lenses ran and which were skipped — a capped scan must read as "capped on
   purpose," never as "covered everything." Same rule when a `> 500 file` repo is
   scanned at reduced breadth.
7. Present the refined candidate table (mark **seed** vs **fan-out** origin) plus a
   draft-journey preview. The user reviews/edits before you submit the scan.

### Phase 3: Create Ghost Scan

1. Run `zensu ghost scan --product <product-id> --repo-url <url> --branch <branch> --candidates '<json>'`. Each candidate carries its three detection arrays — populate all of them, and never omit `detectedTestFiles` or `detectedDocFiles`:

   ```json
   {
     "slug": "authentication",
     "title": "Authentication",
     "componentSlug": "auth",
     "confidenceScore": 0.8,
     "detectedSourceFiles": ["src/auth/login.ts", "src/auth/session.ts"],
     "detectedTestFiles": ["src/auth/login.test.ts", "src/auth/session.spec.ts"],
     "detectedDocFiles": ["docs/auth.md"],
     "securityClassification": "restricted"
   }
   ```

2. **Pre-submit self-check.** Sum `detectedTestFiles` **and** `detectedDocFiles` across all candidates. If the Phase 2 walk surfaced test or doc files but either sum is 0 — or far below what you saw — the per-candidate mapping is broken: STOP and re-glob each candidate's source dirs (steps 6–7) before submitting. Importing source without its tests or docs understates real maturity and skews release gates.
3. Output: "Scan created with {n} candidates ({x} high, {y} medium, {z} low confidence), {t} tests and {d} docs mapped across candidates. Ready for review."

### Phase 4: Batch Review & Apply

1. Run `zensu ghost candidates <scan-id> --product <product-id>` to load all candidates
2. Present candidates as a confidence-grouped table:

```
### High Confidence (>= 0.7) — 12 candidates
 # | Slug              | Component  | Tests | Docs | Source
 1 | auth-login        | auth       | 3     | 1    | 5
 2 | user-profile      | users      | 2     | 1    | 3

### Medium Confidence (0.4-0.7) — 5 candidates
13 | api-middleware     | middleware | 0     | 0    | 4

### Low Confidence (< 0.4) — 3 candidates
18 | config-loader     | infra      | 0     | 0    | 1
```

   **Scan the Tests column before approving.** If it reads 0 for candidates that clearly own source files, the scan missed test detection — do not approve blindly. Return to Phase 2 step 6, re-glob, and re-create the scan. An all-zero Tests column on a repo that has tests is a detection bug, not a property of the code.

   **Scan the Docs column too.** Same rule: if it reads 0 for candidates whose modules ship READMEs or `docs/*.md`, doc detection was skipped — return to Phase 2 step 7, re-glob, and re-create the scan. An all-zero Docs column on a repo that has docs is a detection bug, not a property of the code.

3. Offer batch operations:
   - "Approve all high confidence" — approve all >= 0.7
   - "Reject all low confidence" — reject all < 0.4
   - "Reject specific: #13, #18" — reject individually
   - "Approve all" / "Reject all"
   - "Tell me more about #13" — detail view for individual decision
4. Run `zensu ghost batch <scan-id> --product <product-id>` with `--approve-ids` and `--reject-ids` (JSON arrays of candidate UUIDs) to process all decisions in a single call. Optionally provide `--reject-reason` for rejected candidates.
5. If at least 1 approved: run `zensu ghost apply <scan-id> --product <product-id> --enrich-existing` if the product already has features (check Phase 1 feature list). Omit `--enrich-existing` only for the very first scan on an empty product.
6. Summary: "{n} features created, {e} features enriched, {m} components created, {t} tests linked, {d} docs linked, {s} source files linked"
7. **Backfilling a scan that missed tests.** If features were already created with zero linked tests, do NOT re-create them. Re-run Phase 2 with co-located test globbing, create a fresh scan that **reuses the exact existing slugs**, approve, and run `zensu ghost apply <scan-id> --product <product-id> --enrich-existing` — apply matches by slug and attaches the newly detected tests to the existing features, no duplicates. This costs ~2 calls per module (scan + apply) instead of one `zensu link test` per test file.

### Phase 5: Journey Discovery & Creation

User journeys are a release gate (journey health), yet a brownfield import never gets
them — close that gap here, **after `zensu ghost apply`**, when features have real ZEN IDs.
This mirrors `$zensu-bootstrap` Step 2.

1. Run `zensu features list --product <product-id>` and build a
   slug → ZEN-ID map from the just-applied features.
2. Take the draft journeys consolidated in Phase 2b. Resolve each draft step's
   candidate slug to a real `feature_id` via the map. Drop any step whose slug was
   rejected or not applied, and `log` what was dropped (no silent omission).
3. Dedup against the existing journeys loaded in Phase 1 — do not re-propose a
   journey that already exists.
4. Present the proposed journeys as a table (title, persona, ordered steps →
   features). The user edits/approves before creation.
5. On approval, mirror the bootstrap mechanic:
   - `zensu journeys suggest --product <product-id>` for product context.
   - `zensu journeys create --product <product-id>` per approved journey (title, slug, journey type,
     priority, persona).
   - `zensu journeys step <journey-id> --product <product-id>` per step (`--step-order` 1-based, `--feature`,
     `--interaction-type` ∈ action|navigation|input|validation|output|wait,
     `--critical`).
   - `zensu journeys health <journey-id> --product <product-id>` on each created journey; report weak links to the user.

> **Build-out baseline (automatic, server-side).** Each newly created feature is
> seated at a `v1` "Discovered baseline" automatically by the scan apply
> (`zensu ghost apply`) — minted backend-side (zensu-monorepo #266), no client step
> here. Backends predating #266 simply have no baseline; harmless. Features fan out
> later into deeper revisions and subfeatures.

### Phase 6: Summary & Next Steps

1. List created features via `zensu features list --product <product-id>`.
2. Report counts: features created/enriched, tests linked, docs linked, journeys
   created, and journey-health weak links from Phase 5.
3. **Doc-gap report.** List the created/enriched features with zero docs (empty
   `detectedDocFiles`). Recommend `$zensu-implement` to author code-grounded docs
   for them — ghost-scan links existing docs but never generates new ones
   (`docs/documentation-guide.md`).
4. Recommend next steps:
   - `$zensu-implement` for feature implementation
   - `$zensu-security-review` for security classification
   - `zensu doc claude-md` for an updated CLAUDE.md
5. **Hybrid — capture planned-but-unbuilt features.** If the repo also has a
   forward-looking plan/vision doc, diff it against the features just created. For
   each plan item with no matching feature, run `zensu features create` with `--status planned`
   — these are genuinely unbuilt (no v1 baseline yet; they get one at
   implement-time). This completes the "built + planned" picture that neither a
   pure scan nor a pure bootstrap captures alone.

## CLI Commands Used

| Command | Phase | Purpose |
|---------|-------|---------|
| `zensu products list` | 1 | Validate product |
| `zensu features list` | 1, 5, 6 | Load existing features (dedup); resolve slug → ZEN-ID after apply |
| `zensu journeys list` | 1, 5 | Load existing journeys (dedup) |
| read-only exploration subagents (Codex multi-agent) | 2b | Parallel read-only analysis lenses (fan-out) |
| `zensu ghost scan` | 3 | Create scan with candidates |
| `zensu ghost candidates` | 1 (resume), 4 | Load candidates |
| `zensu ghost batch` | 4 | Batch approve/reject candidates in one call |
| `zensu ghost apply` | 4 | Apply approved candidates (use `--enrich-existing` if product has features) |
| `zensu journeys suggest` | 5 | Product context for journey suggestions |
| `zensu journeys create` | 5 | Create a discovered journey |
| `zensu journeys step` | 5 | Add ordered steps linking real feature IDs |
| `zensu journeys health` | 5 | Report weak links on created journeys |
| `zensu features create` | 6 | Hybrid: create planned-but-unbuilt features from a forward plan doc |
| `zensu doc claude-md` | 6 | Update CLAUDE.md (optional) |
