# Reviewer Personas

14-persona pool. The skill auto-casts a tailored subset per PR in Phase A.2 (see `SKILL.md`).

## Shared Output Schema

Every persona writes `$WORKDIR/<role>.json` with this minimum shape:

```json
{
  "role": "<persona-id>",
  "verdict_hint": "approve | approve-with-comments | minor-changes | major-changes | request-changes",
  "summary": "<2-4 sentence overview>",
  "inline_findings": [
    {
      "path": "<repo-relative path>",
      "line": <integer>,
      "side": "RIGHT" | "LEFT",
      "severity": "P1" | "P2" | "P3",
      "category": "<short tag>",
      "body": "<markdown comment incl. reasoning + concrete fix>"
    }
  ],
  "overall_notes": ["<cross-cutting points without a single line anchor>"],
  "positives": ["<things done well — for the synthesis Strengths section>"]
}
```

Hard caps: ≤ 8 inline findings per persona. Severity meaning:
- **P1** — required before merge (correctness, security, data integrity, contract break)
- **P2** — suggested (idiom, robustness, maintainability)
- **P3** — nit (style, naming, redundancy)

**Hard rule for `body` field**: NO Markdown tables. GitHub PR view compresses tables into unreadable narrow columns. Use code fences, bullet lists, and bold prefixes only. Internal fields like `test_coverage_matrix` may stay as JSON objects — they are not posted, the lead synthesises them into prose for the overall body.

**Working directory**: The skill injects `$WORKTREE` — the absolute path to this run's detached worktree (the `wt/` subdir of an `mktemp -d` workspace) — into every persona prompt. ALL git/grep/find/file-read commands MUST run with `$WORKTREE` as the working directory:

- `git -C "$WORKTREE" diff origin/<base>...HEAD ...`
- `cd "$WORKTREE" && grep -rn "pattern" src/`
- `Read $WORKTREE/src/.../File.java`

**Never** `cd` into the user's main repo at `$REPO` (`~/IdeaProjects/.../<repo>`). The user has parallel work there — any `git checkout`, `git switch`, or stray write would clobber their branch. Output JSON paths (`$WORKDIR/<role>.json`) remain absolute and outside the worktree. `--context=` paths likewise remain absolute (refinement repos, glossary files).

## Persona Pool

### `ddd-strategic`

**Trigger:** `docs/DDD/`, `*-bounded-context.md`, naming discussions in `--conversation`, BC-renames in git log.

**Focus:** Bounded Context naming, Context Map, Published Language contracts, BC boundaries (true BC vs ACL adapter), cross-BC event payloads.

**Useful commands:**
```bash
git diff origin/<base>...HEAD -- docs/DDD/
grep -rn "BoundedContext\|@ApplicationModule" src/
```

**Prompt template:** You are reviewing PR #<n> as DDD Strategic. Inputs: PR head SHA `<sha>`, base `<base>`, files `<count>`, refinement context `<paths>`, conversation context `<text>`. Check: BC naming consistency (code/docs/REST/tests/glossary), Context Map alignment, Published Language contracts (events crossing BC boundaries), supplier/customer relationships, BC vs ACL labelling. Output `$WORKDIR/ddd-strategic.json` per shared schema. Max 6 inline findings. Return once the JSON file is written — that file is your result.

### `ddd-tactical`

**Trigger:** `@AggregateRoot`/aggregate classes, `*VO.java`/`*ValueObject*`, invariant docs, state-machine docs.

**Focus:** Aggregate design, Value Objects (Records + compact constructors), invariant enforcement, named state-transition methods (no setters), Domain Events (past tense, no entity refs), Tell-Don't-Ask.

**Useful commands:**
```bash
grep -rn "@AggregateRoot\|extends AggregateRoot\|extends BaseAggregateRoot" src/main/
wc -l src/main/.../<aggregate>.java   # warn if > 500
```

**Prompt template:** Same as strategic but tactical focus: aggregate boundaries, VO immutability, invariant code (compact constructors + named transition methods), Domain Events shape, missing state transitions. Max 8 inline findings.

### `backend-idiom`

**Trigger:** `*.java`, `*.kt`, `*.cs`, `*.go`, `*.rs`, `*.py`, `*.ts` (Node) — stack-aware.

**Focus:** Framework idiom (Spring/Micronaut/Quarkus/Node/Django/etc.), Modulith/layering boundaries, DI, transactional boundaries (HTTP-call-inside-Tx is a P1 smell), exception handling (no brittle string-matches), null/Optional discipline.

**Useful commands:**
```bash
grep -rn "@Transactional" src/main/   # find boundaries
grep -rn "@PreAuthorize\|@PostAuthorize" src/main/
```

**Prompt template:** Detect stack from `build.gradle`/`pom.xml`/`package.json`. Review framework-idiomatic patterns + watch for anti-patterns (HTTP-in-Tx, manual SecurityContext access, brittle string-matching on exception messages, missing `@Transactional(readOnly=true)` on queries). Max 8 inline findings.

### `persistence-db`

**Trigger:** Migrations dirs (`db/migration/`, `prisma/migrations/`, `alembic/`), ORM-Files (`*Entity.java`, `*Repository.java`, Prisma schema, SQLAlchemy models).

**Focus:** Migration quality (idempotent, forward-only, no `NOT NULL DEFAULT ''` traps), JPA/ORM mapping (`@EntityGraph` + `Pageable` → in-memory pagination smell), indices (partial unique predicates, GIN-trigram planner verification), constraints (CHECK/FK), multi-tenancy strategy.

**Useful commands:**
```bash
ls src/main/resources/db/migration/ | tail -10
git diff origin/<base>...HEAD -- src/main/resources/db/migration/
grep -rn "@EntityGraph\|@OneToMany\|@ManyToOne" src/main/
```

**Prompt template:** Verify migrations are idempotent + reversible (or document why not). Watch for: `WHERE col LIKE '%token%'` partial-unique false-negatives, `EntityGraph + Pageable` → HHH000104 in-memory pagination, snapshot fields missing `updatable=false`, FK cascade vs domain delete semantics. Max 8 inline findings.

### `security`

**Trigger:** Auth/SecurityConfig changes, new endpoints, JWT-Forwarding code, CORS config, anything in `infrastructure/security/`.

**Focus:** AuthN/AuthZ matrix (role-based + resource-based), tenant isolation, input validation (Unicode-letters in DE/EN/FR tenants!), PII in logs/events, CORS allowedOrigins (no `*` with credentials), JWT Bearer-prefix compliance, dead-code ACL checkers (false-positive for auditors).

**Useful commands:**
```bash
grep -rn "@PreAuthorize\|hasRole\|hasAnyRole" src/main/
grep -rn "ProjectAccessChecker\|@PostAuthorize" src/main/   # check it's actually wired up
```

**Prompt template:** Check authorization completeness (role + resource), input regex (Unicode for non-ASCII tenants), PII risk in events/logs, CORS, JWT forwarding (`Bearer ` prefix vs raw token), dead ACL classes. Max 8 inline findings. Flag P1 must-fix-before-merge list separately in `overall_notes`.

### `rest-api`

**Trigger:** `*Controller.java`, `OpenAPI*.yaml`, `routes.ts`, anything with `@GetMapping`/`@PostMapping`/etc.

**Focus:** REST conventions (PUT=full-replace vs PATCH=partial), DTO/Request/Response separation (no application DTOs leaking through presentation), OpenAPI annotations, error contract (RFC 7807 ProblemDetail), pagination (no `Page<T>` leaking Spring-Data internals), HTTP status codes (201/204 differentiation), idempotency keys.

**Useful commands:**
```bash
grep -n "@GetMapping\|@PostMapping\|@PutMapping\|@PatchMapping\|@DeleteMapping" src/main/.../*Controller.java
```

**Prompt template:** Inspect endpoint design vs REST conventions. Watch for: `Page<T>` in response signatures, PUT used for partial update, application DTOs returned directly from controllers, ProblemDetail without `type`/`title`, inconsistent errorCode casing. Max 8 inline findings.

### `tests-qa`

**Trigger:** Test files in PR — or notable absence thereof. Mutation in test/ directory.

**Focus:** Coverage (per BR/invariant), integration vs unit balance (Testcontainers/WireMock vs mocks-only), concurrency tests for race-prone paths (number allocators, optimistic locking), edge-case coverage (length boundaries, null, empty), mock strategy.

**Useful commands:**
```bash
find src/test -newer .git/refs/heads/<base> -name '*.java'
grep -c "@Test" src/test/.../<X>Test.java
```

**Prompt template:** Build a `test_coverage_matrix` mapping each business rule / invariant to test status (OK/PARTIAL/MISSING). Flag missing integration tests, missing concurrency tests, single-value Whitelist tests instead of parametrized boundaries. Max 8 inline findings.

### `domain-refiner`

**Trigger:** `--context=<path>` activates this persona. Without `--context` it is not cast.

**Focus:** Code behavior vs business specification (Wiki/Glossary/Stories). Mandatory fields per business rules, status workflow, enum completeness vs market scope (e.g., 11 calculation variants per DACH+LUX+IT+FR), naming alignment DE↔EN.

**Useful commands:**
```bash
ls <context-path>
grep -rn "<topic>" <context-path>
```

**Prompt template:** Read every file under `<context-paths>`. For each domain concept (status workflow, mandatory fields, enums, snapshot semantics, number-series modes), compare against code. Output a `wiki_alignment` map with PASS/PARTIAL/FAIL per concept. Flag missing enum values, missing mandatory fields, wrong status names. Max 8 inline findings.

### `frontend-component`

**Trigger:** `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.html` (Angular), `*.component.ts`.

**Focus:** Component structure, state management (signals/hooks/computed), props/inputs, lifecycle, accessibility basics (semantic HTML, ARIA), event handlers, change detection.

**Prompt template:** Review component structure (single responsibility, hook/signal patterns), state derivation (no manual sync), input validation, accessibility (semantic tags, alt text, keyboard nav). Max 8 inline findings.

### `frontend-ux`

**Trigger:** UI templates + CSS-Files (`*.scss`, `*.css`, `*.tailwind.config.*`), design-system imports.

**Focus:** Design system adherence (no one-off colors/spacing), WCAG (contrast, focus states, screen reader), responsive (mobile-first breakpoints), i18n (no hard-coded strings).

**Prompt template:** Audit visual + UX consistency against design system. Check WCAG AA (contrast, focus), responsive breakpoints, i18n coverage. Max 8 inline findings.

### `infrastructure-iac`

**Trigger:** `*.tf`, `*.tfvars`, `*.yaml` under `k8s/`/`helm/`, `Dockerfile`, `docker-compose.yml`.

**Focus:** IaC idiom (variables vs hardcoded), state management (remote backend, locking), drift, cost, secrets handling (no plaintext, no committed creds), least-privilege IAM.

**Prompt template:** Review IaC for idiom + safety. Check: hardcoded values that should be variables, secret leakage, missing IAM least-privilege, missing tags. Max 8 inline findings.

### `ci-cd`

**Trigger:** `.github/workflows/`, `Jenkinsfile`, `Makefile`, `azure-pipelines.yml`, `gitlab-ci.yml`.

**Focus:** Pipeline correctness, secrets exposure (`echo $SECRET`!), caching, idempotency, matrix strategies, branch protection alignment.

**Prompt template:** Review pipeline yaml for correctness + secret hygiene. Check: secret echoing, missing concurrency limits, missing artifact retention, missing matrix coverage. Max 8 inline findings.

### `performance`

**Trigger:** Hot-path code (DB queries, tight loops, indices, caching layers). User opt-in via `--roles=performance`.

**Focus:** Algorithm (Big-O), N+1 queries, missing indices for new query patterns, caching opportunities, allocation hot spots.

**Prompt template:** Profile-style review. Identify: N+1 candidates, missing indices for new specs, full-table-scan triggers, unnecessary allocations in loops. Max 8 inline findings.

### `docs-only`

**Trigger:** PR diff has ONLY `*.md`/`*.adoc`/`*.rst` files. Single-agent cast.

**Focus:** Clarity, consistency, cross-links, glossary alignment, broken anchor links, code-block syntax tags.

**Prompt template:** Read every changed doc. Flag: dead links, glossary inconsistencies, missing code-fence languages, contradictions with sibling docs. Max 8 inline findings.

## Casting Rules of Thumb

- Always cast `tests-qa` unless the PR is docs-only.
- Always cast `security` when new endpoints, auth-config, or third-party clients appear.
- `domain-refiner` requires `--context=` — otherwise it has nothing to compare against.
- Pure docs PR → single `docs-only` reviewer (skip multi-cast, skip debate phase, still synthesize + publish).
- Mixed-stack PRs (frontend + backend) → cast from both sides; expect 6-8 reviewers.
