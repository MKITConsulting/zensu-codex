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

- Zensu MCP Server connected (plugin auto-configures via `.mcp.json`)
- `ZENSU_API_KEY` environment variable set
- A feature ID (ZEN-xxx format or UUID) to implement

## Workflow

### Step 1: Load Feature Context

1. Ask the user for the feature ID
2. Use `get_feature` to load the full feature details (title, description, status, priority, component, security classification)
3. Use `analyze_feature_security` to load the security context (classification, data sensitivity, OWASP tags, compliance requirements, score)
4. Use `search_knowledge` (query the feature title + key terms) to surface related org context — existing features, visions, journeys, and connected sources — so the implementation builds on what the org already knows. It is retrieval-only: synthesize from the returned passages and cite their provenance.
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

Invoke the **`$zensu-tdd` skill** with a feature specification built from Steps 1-2 as the input. Include the feature title, description, component, security classification, security constraints from Step 1, and the implementation plan from Step 2. End the spec with: "Reference this feature as [ZEN-xxx] in all commit messages." You run the TDD workflow yourself in THIS main thread — do not spawn a subagent.

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

For each test file written (by the $zensu-tdd workflow or manually), use `link_test` with:
- `feature_id` (required)
- `test_type` (required): unit | integration | e2e | security | performance | accessibility
- `file_path` (required): Path to the test file
- `function_name` (optional): Specific test function
- `last_run_status` (optional): passed | failed | skipped

### Step 5: Link Source Files

Use `link_source_files` to map implementation files to the feature:
- `feature_id` (required)
- `files` (required): Array of objects with:
  - `file_path` (required): Path to the source file
  - `file_type` (optional): source | test | config | migration | docs | generated | other
  - `language` (optional): Programming language
  - `line_count` (optional): Number of lines

For cross-feature file mapping, use `bulk_link_source_files` with a `mappings` array containing `feature_id`, `file_path`, `file_type`, and `language` per entry.

### Step 6: Documentation

Documentation must be **code-grounded** — written from the real source you just
implemented, not a restatement of the feature record.
**Read `docs/documentation-guide.md`** first, then follow it:

1. Call `get_doc_generation_context` for the feature + target `doc_type` — the
   context *map* (source-file paths, symbols, security posture), not the source.
2. **Read the real source files it names** (the files linked in Step 5). The map
   is not the territory.
3. Author Markdown grounded in real signatures, endpoints, and behavior, matched
   to the doc type's focus and audience. Do NOT condense the context metadata
   into `## Purpose / ## Source files / ## Security / ## Notes` sections — that
   metadata dump is the exact failure this step prevents.
4. Publish with `create_wiki_page` (full markdown `content`, plus `entity_type`,
   `entity_id`, `doc_type`, `audience`).

Then register the doc with `link_docs` (updates the feature's docs score):
- `feature_id` (required)
- `doc_type` (required): user_facing | api_reference | tutorial | adr | internal | release_notes | migration_guide | overview
- `title` (optional): Document title
- `file_path` (optional): Path to the doc file
- `external_url` (optional): External URL
- `audience` (optional): end_user | developer | admin | internal
- `publication_status` (optional): draft | published | archived

Use `link_docs` alone (no wiki page) only for docs that already live in the repo
or at an external URL.

### Step 7: Create Revision

Use `create_revision` to version the implementation:
- `feature_id` (required)
- `scope_summary` (required): Brief summary of what was implemented
- `scope_details` (optional): Detailed scope description
- `estimated_effort` (optional): S | M | L | XL
- `coverage_target` (optional): Target coverage percentage (0-100)
- `docs_required` (optional): Whether docs are required for this revision
- `created_by` (optional): "mcp" for MCP-initiated revisions

### Step 8: Validate

Use `validate_feature_security` to check if the implementation meets all security requirements for release.

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

- The `update_feature` MCP tool does NOT have a `status` field. Status transitions (planned -> in-progress -> testing -> released) require a separate API call, not an MCP tool.
- Always reference the feature ID in commit messages: `feat(component): description [ZEN-xxx]`
- Security classification should be set BEFORE implementation (use `$zensu-security-review` if not yet set)
- The $zensu-tdd workflow creates a plan at `.zensu/plans/{timestamp}_tdd-{feature-slug}.md` and a progress log at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{timestamp}_tdd-{feature-slug}.log`

## MCP Tools Used

| Tool | Step | Purpose |
|------|------|---------|
| `get_feature` | 1 | Load feature details |
| `analyze_feature_security` | 1 | Load security context |
| `search_knowledge` | 1 | Surface related org knowledge (retrieval-only) |
| `link_test` | 4 | Link test files |
| `link_source_files` | 5 | Map source files to feature |
| `bulk_link_source_files` | 5 | Bulk map across features |
| `get_doc_generation_context` | 6 | Get the context map to read source before writing docs |
| `create_wiki_page` | 6 | Publish authored markdown to the wiki |
| `link_docs` | 6 | Register the doc; updates docs score |
| `create_revision` | 7 | Create feature revision |
| `validate_feature_security` | 8 | Check release readiness |

## MCP Prompts Used

| Prompt | When | Purpose |
|--------|------|---------|
| `implement_with_security` | Step 2 | Get security constraints for implementation guidance |

## Agents & Skills Used

| Component | Type | Step | Purpose |
|-----------|------|------|---------|
| `$zensu-tdd` | skill (main thread) | Step 3 | Strict RED-GREEN TDD, phase-gated, guaranteed review chain |
| `zensu-code-reviewer` | subagent | Step 3 (Phase 6) | 5-perspective code review + auto-fix routing |
