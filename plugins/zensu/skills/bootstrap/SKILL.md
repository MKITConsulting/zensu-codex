---
name: zensu-bootstrap
description: Bootstrap a new Zensu product from a vision/plan document through to a fully configured product with features, journeys, security profiles, tiers, and a CLAUDE.md. Use as the greenfield entry point when starting a new project from a plan doc (MVP spec, PRD, idea paper) with no code yet.
---

# $zensu-bootstrap

Bootstrap a new Zensu product from a vision document through to a fully configured product with features, journeys, security profiles, tiers, and a CLAUDE.md.

## When to Use

This is the **greenfield** entry point — a new product captured from a plan/vision doc, before (or independent of) any code.

- Starting a new project from scratch with a plan document (MVP spec, PRD, idea paper)
- Converting an existing product vision into tracked features
- Setting up a complete product in Zensu for the first time

**Brownfield instead?** Code already exists and its features are untracked → use `$zensu-ghost-scan`.

**Hybrid (existing code *and* this plan doc)?** Run `$zensu-ghost-scan` first to import what is built, then create the plan's not-yet-built items as `planned` features — see that skill's Phase 6.

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`
- Authenticated: `zensu auth login` (check with `zensu auth status`)
- A product plan or vision document (MVP spec, PRD, or idea paper)

Every command accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

Execute these phases in order. Present results to the user after each phase and wait for confirmation before proceeding.

**Free text never goes into the command line itself.** Inside double quotes the shell runs every
backtick span and expands every `$NAME` and `$(…)`, and a single quote ends at the first
apostrophe. So write the plan document, every description and expected result, and every JSON
argument below to its own `mktemp` file with a quoted heredoc, one recipe per shell call, and pass
it as `"$(cat "$f")"`. Never put the heredoc inside `$(…)`. Put a short value such as a title in
single quotes and write each apostrophe in it as `'\''`.

```bash
f="$(mktemp)" || exit 1
trap 'rm -f "$f"' EXIT
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<the text, unchanged>
ZENSU_TEXT_<hex>
[ -s "$f" ] || exit 1
zensu journeys create --product <product-id> --title '<title>' --description "$(cat "$f")"
```

`<hex>` stands for 12 random hex digits you pick once the text is final; check that no line of the
text equals the delimiter. For a second value, create its file the same way after the first, widen
the trap to both files and check both with `[ -s … ]`.

### Phase 1: Product & Vision Setup

1. Ask the user for their product name, slug, type (public_product|internal_product|hybrid), and the vision/plan document content
2. Run `zensu products create` with name, slug, and product type. Its optional `--description` is Markdown: Zensu renders headings, lists and code, so write structured Markdown, not one unformatted paragraph; pass it as `"$(cat "$f")"`
3. Run `zensu products vision-create --product <product-id> --content "$(cat "$f")" --source codex`, with the plan document written to `$f`; a plan you read from a PDF or Word file goes this way too, as text. When the plan document is a UTF-8 text or Markdown file, pass it by path instead of retyping it, and never name that file in a `trap`, which would delete it: set `p='<absolute-plan-file>'` to an absolute path, never `~/…`, which the quotes leave unexpanded, check it with `[ -f "$p" ] && [ -n "$(cat -- "$p")" ] || exit 1`, and pass `--content "$(cat -- "$p")"`
4. Save the returned product_id and vision_id for subsequent steps

### Phase 2: Feature Extraction & Bootstrap

1. Run `zensu products vision-get <vision-id>` to get the vision content
2. Analyze the vision document and decompose it into components and features following these rules:
   - **Components**: Domain-based boundaries, NOT layer-based. One component per bounded context or domain module. Most products have 3-8 components. Never create "infrastructure", "devops", or "shared" components.
   - **Features**: Vertical slices of user value (INVEST criteria). Do NOT create features for CI/CD, deployment, infrastructure, database setup, monitoring, or scaffolding.
   - **Priority distribution**: ~20% critical, ~30% high, ~30% medium, ~20% low
   - **Security classification**: public (no sensitive data), internal (standard auth), confidential (PII/financial), restricted (health/credentials/regulatory)
   - **Estimated effort**: S (hours-1 day), M (2-3 days), L (1-2 weeks), XL (2+ weeks, consider splitting)
3. Present the decomposition to the user for review
4. Run `zensu products bootstrap-apply <vision-id> --result "$(cat "$f")"` with the structured JSON containing components and features written to `$f`. The component, feature and sub-feature `description` values in that JSON are Markdown: Zensu renders headings, lists and code, so write structured Markdown, not one unformatted paragraph. In JSON each description is a string, so write each line break as `\n` and escape every `"` and `\` with a backslash. Keep each one brief: the whole JSON travels as one command-line argument, and the operating system limits its size
5. Report the created entities (component count, feature count, features by priority). Bootstrapped features start at `planned` with **no revision baseline** — there is nothing built yet to capture; a feature gets its v1 revision at implement-time (`$zensu-implement`), or at discovery if `$zensu-ghost-scan` later finds it already built

### Phase 3: Post-Bootstrap Setup (5 Steps)

Execute each step below, presenting results to the user after each.

**Step 1: Review & Refine Features**
- Review the bootstrapped features with the user (`zensu features list --product <product-id>`)
- Remove horizontal/implementation features that shouldn't be tracked
- Split XL-effort features using `zensu subfeatures add <feature-id>` or `zensu features split <feature-id>`
- Add missing features with `zensu features create`
- Fix incorrect priorities or descriptions with `zensu features update <feature-id>`. Its `--description`, like the optional one of `zensu subfeatures add`, is Markdown: Zensu renders headings, lists and code, so write structured Markdown, not one unformatted paragraph; pass it as `"$(cat "$f")"`
- After completion: run `zensu products bootstrap-step <vision-id> 1`

**Step 2: Define User Journeys**
- Run `zensu journeys suggest --product <product-id>` to get product context for journey suggestions
- Propose 3-5 critical user journeys to the user
- Create approved journeys with `zensu journeys create --product <product-id>` (include title, slug, journey type, priority, persona). Its `--description` is Markdown: Zensu renders headings, lists and code, so write structured Markdown, not one unformatted paragraph; pass it as `"$(cat "$f")"`
- For each journey, add steps with `zensu journeys step <journey-id> --product <product-id>`:
  - Set step order (1-based sequential) via `--step-order`
  - Link to features via `--feature`
  - Set `--interaction-type` (action|navigation|input|validation|output|wait)
  - Mark critical steps with `--critical`
  - `--description` and `--expected-result` are plain text: Zensu does not render Markdown there, so do not use Markdown syntax. Pass them as `--description "$(cat "$f")" --expected-result "$(cat "$e")"`, both files written as above, with `trap 'rm -f "$f" "$e"' EXIT` once `e` exists
- Run `zensu journeys health <journey-id> --product <product-id>` on each journey to identify weak links
- After completion: run `zensu products bootstrap-step <vision-id> 2`

**Step 3: Deepen Security Setup**
- Run `zensu security analyze <feature-id>` on all confidential/restricted features
- Run `zensu security suggest-tests <feature-id>` on high-risk features to identify needed tests
- Run `zensu security threat-model <feature-id>` on the most critical feature for STRIDE analysis
- Present the security posture summary to the user
- After completion: run `zensu products bootstrap-step <vision-id> 3`

**Step 4: Set Up Tier Availability (Optional)**
- Ask the user: "Does this product use pricing tiers (e.g. Free/Pro/Enterprise)?"
- If yes:
  1. Ask which tiers they need
  2. Run `zensu tiers create --product <product-id>` for each tier (ascending tier order: 1, 2, 3...). Its optional `--description` is plain text: Zensu does not render Markdown there, so do not use Markdown syntax; pass it as `"$(cat "$f")"`
  3. Run `zensu tiers set-feature <feature-id>` for each feature:
     - Critical features: available in all tiers (hard gating)
     - High priority: Pro and above
     - Medium/low: highest tier only
  4. Run `zensu tiers matrix --product <product-id>` to show the complete matrix
- If no: skip directly to Step 5
- After completion: run `zensu products bootstrap-step <vision-id> 4` (or step `5` if skipping)

**Step 5: Generate CLAUDE.md**
- Run `zensu doc claude-md --product <product-id> --variant full`
- Present the generated CLAUDE.md to the user
- After completion: run `zensu products bootstrap-step <vision-id> 5`

### Phase 4: Summary

Present a final summary:
- Product name and type
- Number of components and features created
- Journeys defined and their health scores
- Security posture overview
- Tier configuration (if applicable)
- CLAUDE.md generated

The product is now ready for implementation. Features can be worked on using the `$zensu-implement` skill.

## CLI Commands Used

| Command | Phase | Purpose |
|---------|-------|---------|
| `zensu products create` | 1 | Create the product |
| `zensu products vision-create` | 1 | Store the vision document |
| `zensu products vision-get` | 2 | Get vision content for analysis |
| `zensu products bootstrap-apply` | 2 | Create components and features from decomposition |
| `zensu features list` | 3.1 | Review bootstrapped features |
| `zensu features update` | 3.1 | Fix priorities, descriptions |
| `zensu subfeatures add` | 3.1 | Split large features |
| `zensu features split` | 3.1 | Split features into children |
| `zensu features create` | 3.1 | Add missing features |
| `zensu journeys suggest` | 3.2 | Get context for journey suggestions |
| `zensu journeys create` | 3.2 | Create journeys |
| `zensu journeys step` | 3.2 | Add steps to journeys |
| `zensu journeys health` | 3.2 | Check journey health |
| `zensu security analyze` | 3.3 | Analyze feature security |
| `zensu security suggest-tests` | 3.3 | Get security test suggestions |
| `zensu security threat-model` | 3.3 | Generate STRIDE threat model |
| `zensu tiers create` | 3.4 | Create pricing tiers |
| `zensu tiers set-feature` | 3.4 | Assign features to tiers |
| `zensu tiers matrix` | 3.4 | Show tier matrix |
| `zensu doc claude-md` | 3.5 | Generate CLAUDE.md template |
| `zensu products bootstrap-step` | 3.x | Track post-bootstrap progress |
