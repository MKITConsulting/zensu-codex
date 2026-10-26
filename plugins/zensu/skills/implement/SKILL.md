---
name: zensu-implement
description: Implement a tracked Zensu feature end-to-end — load its feature context and security profile, run disciplined RED-GREEN TDD via the $zensu-tdd skill in the main thread, then link all artifacts (tests, source, docs) and create a revision. Use to start, resume, or complete implementation of a tracked feature.
---

# $zensu-implement

Implement a tracked Zensu feature end-to-end. Loads feature context and security profile, then runs disciplined implementation via the **`$zensu-tdd` skill** in the main thread (strict RED-GREEN TDD, PreToolUse phase-gate, guaranteed code-review chain). After TDD completes, links all artifacts and creates a revision.

## When to Use

- Starting implementation of a planned feature
- Resuming work on an in-progress feature
- Completing a feature with proper artifact linking

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`
- Authenticated: `zensu auth login` (check with `zensu auth status`)
- A feature ID (ZEN-xxx format or UUID) to implement

Every command accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

### Step 1: Load Feature Context

1. Ask the user for the feature ID
2. Run `zensu features get <feature-id>` to load the full feature details (title, description, status, priority, component, security classification)
3. Run `zensu security analyze <feature-id>` to load the security context (classification, data sensitivity, OWASP tags, compliance requirements, score)
4. Read and follow [Load and hydrate feature context](references/knowledge-context.md) before planning. Check `zensu knowledge context-pack --help`, load `zensu knowledge context-pack <feature-ref> --json --agent codex`, retain the returned `load_id`, inspect truncation, and hydrate relevant real items with `zensu knowledge get <item-id> --json --context-load <load-id>`. Supplement with `zensu knowledge search --query "<feature title + key terms>" --json`; file references require actual reads from the authorized checkout.
5. Present a summary to the user:
   - Feature title and description
   - Current status and priority
   - Security classification and constraints
   - Any security requirements that must be addressed during implementation

### Step 2: Implementation Planning

Based on the feature context and security profile, help the user plan the implementation:
- Identify files to create or modify
- Note security constraints from the classification (e.g., input validation required, audit logging needed)
- Consider the OWASP tags and compliance requirements
- Outline the implementation approach

If the feature's security classification is confidential or restricted, emphasize:
- Input validation on all user inputs
- Proper authentication and authorization checks
- Data encryption requirements
- Audit logging for sensitive operations

### Step 3: Implement via the $zensu-tdd skill

Invoke the **`$zensu-tdd` skill** with a feature specification built from Steps 1-2 as the input. Include the feature title, description, component, security classification, security constraints from Step 1, the context evidence summary (contents read, excerpt/metadata only, unresolved sources), and the implementation plan from Step 2. End the spec with: "Reference this feature as [ZEN-xxx] in all commit messages." You run the TDD workflow yourself in THIS main thread — do not spawn a subagent.

If the TDD workflow cannot proceed or all steps are blocked, continue manually from Step 4.

The $zensu-tdd workflow will:
- Split the work into atomic steps and classify each (Feature / Refactor / Bug-fix / Integration)
- Create a plan document in `.zensu/plans/`
- Execute strict RED-GREEN TDD cycles in-thread, enforced by the PreToolUse phase-gate (or direct vanilla implementation when `hooks.tddImplementation` is `false` — the skill branches itself at `--tdd-begin`)
- Run a completeness audit at the end (build, coverage, mtime, precondition drift)
- Provide a progress log at `.zensu/logs/`

At the end of the workflow (Phase 6) it marks implementation complete and spawns the `zensu-code-reviewer` subagent for the 5-perspective review. The `Stop` hook (`stop-chain-enforcer.sh`) guarantees the review chain runs, and `post-review-tdd-delegate.sh` routes any findings back for in-thread fixing until PASS or max rounds.

**For trivial changes** (single-line fix, config change, migration-only): Skip the $zensu-tdd skill and implement directly, then continue with Step 4.

### Step 4: Link Tests

For each test file written (by the $zensu-tdd workflow or manually), run `zensu link test <feature-id>` with:
- `--test-type` (required): unit | integration | e2e | security | performance | accessibility
- `--file` (required): Path to the test file
- `--function` (optional): Specific test function
- `--last-run-status` (optional): passed | failed | skipped

### Step 5: Link Source Files

Run `zensu link source <feature-id>` to map implementation files to the feature. Pass each file with a repeatable `--file` flag in the form `path[:type[:language[:linecount]]]` (type: source | test | config | migration | docs | generated | other). For cross-feature mapping, run `zensu link source` once per target feature id.

### Step 6: Documentation

Documentation must be **code-grounded** — written from the real source you just
implemented, not a restatement of the feature record.
**Read `docs/documentation-guide.md`** first, then follow it:

1. Run `zensu doc gen-context <feature-id> --doc-type <type>` for the context *map*
   (source-file paths, symbols, security posture), not the source.
2. **Read the real source files it names** (the files linked in Step 5). The map
   is not the territory.
3. Author Markdown grounded in real signatures, endpoints, and behavior, matched
   to the doc type's focus and audience. Do NOT condense the context metadata
   into `## Purpose / ## Source files / ## Security / ## Notes` sections — that
   metadata dump is the exact failure this step prevents.
4. Publish with `zensu wiki create --product <product-id> --title <title> --content <markdown>`
   (plus `--entity-type`, `--entity-id`, `--doc-type`, `--audience`).

Then register the doc with `zensu link docs <feature-id>` (updates the feature's docs score):
- `--doc-type` (required): user_facing | api_reference | tutorial | adr | internal | release_notes | migration_guide | overview
- `--title` (optional): Document title
- `--file` (optional): Path to the doc file
- `--external-url` (optional): External URL
- `--audience` (optional): end_user | developer | admin | internal
- `--publication-status` (optional): draft | published | archived

Run `zensu link docs` alone (no wiki page) only for docs that already live in the repo
or at an external URL.

### Step 7: Create Revision

Run `zensu features revision <feature-id>` to version the implementation:
- `--scope-summary` (required): Brief summary of what was implemented
- `--scope-details` (optional): Detailed scope description
- `--estimated-effort` (optional): S | M | L | XL
- `--coverage-target` (optional): Target coverage percentage (0-100)
- `--docs-required` (optional): Whether docs are required for this revision
- `--created-by` (optional): identifier for who created the revision

### Step 8: Validate

Run `zensu security validate <feature-id>` to check if the implementation meets all security requirements for release.

Present the validation results:
- Security score
- Release gate status (pass/fail)
- Any remaining violations to address

### Summary

Present a completion summary:
- Feature title and what was implemented
- Files created/modified (source files linked)
- Tests written and linked (with pass/fail status)
- Documentation linked
- Revision created (version number)
- Security validation status
- TDD report: steps completed, attempts, blocked steps (if any)

## Important Notes

- `zensu features update` does NOT change status. Status transitions (planned -> in-progress -> testing -> released) go through `zensu features status <feature-id> <new-status>`.
- Always reference the feature ID in commit messages: `feat(component): description [ZEN-xxx]`
- Security classification should be set BEFORE implementation (use `$zensu-security-review` if not yet set)
- The $zensu-tdd workflow creates a plan at `.zensu/plans/{timestamp}_tdd-{feature-slug}.md` and a progress log at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{timestamp}_tdd-{feature-slug}.log`

## CLI Commands Used

| Command | Step | Purpose |
|---------|------|---------|
| `zensu features get` | 1 | Load feature details |
| `zensu security analyze` | 1 | Load security context |
| `zensu knowledge context-pack` / `zensu knowledge get` / `zensu knowledge search --json` | 1 | Load linked context, hydrate relevant content, supplement with passages |
| `zensu link test` | 4 | Link test files |
| `zensu link source` | 5 | Map source files to feature (bulk via repeated `--file`) |
| `zensu doc gen-context` | 6 | Get the context map to read source before writing docs |
| `zensu wiki create` | 6 | Publish authored markdown to the wiki |
| `zensu link docs` | 6 | Register the doc; updates docs score |
| `zensu features revision` | 7 | Create feature revision |
| `zensu security validate` | 8 | Check release readiness |

## Agents & Skills Used

| Component | Type | Step | Purpose |
|-----------|------|------|---------|
| `$zensu-tdd` | skill (main thread) | Step 3 | Strict RED-GREEN TDD, phase-gated, guaranteed review chain |
| `zensu-code-reviewer` | subagent | Step 3 (Phase 6) | 5-perspective code review + auto-fix routing |
