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

- Zensu MCP Server connected (plugin auto-configures via `.mcp.json`)
- `ZENSU_API_KEY` environment variable set
- A product plan or vision document (MVP spec, PRD, or idea paper)

## Workflow

Execute these phases in order. Present results to the user after each phase and wait for confirmation before proceeding.

### Phase 1: Product & Vision Setup

1. Ask the user for their product name, slug, type (public_product|internal_product|hybrid), and the vision/plan document content
2. Use `create_product` to create the product with name, slug, and product_type
3. Use `create_product_vision` with the product_id and the user's plan document as content (set source to "codex")
4. Save the returned product_id and vision_id for subsequent steps

### Phase 2: Feature Extraction & Bootstrap

1. Use `bootstrap_from_vision` with the vision_id to get the vision content
2. Analyze the vision document and decompose it into components and features following these rules:
   - **Components**: Domain-based boundaries, NOT layer-based. One component per bounded context or domain module. Most products have 3-8 components. Never create "infrastructure", "devops", or "shared" components.
   - **Features**: Vertical slices of user value (INVEST criteria). Do NOT create features for CI/CD, deployment, infrastructure, database setup, monitoring, or scaffolding.
   - **Priority distribution**: ~20% critical, ~30% high, ~30% medium, ~20% low
   - **Security classification**: public (no sensitive data), internal (standard auth), confidential (PII/financial), restricted (health/credentials/regulatory)
   - **Estimated effort**: S (hours-1 day), M (2-3 days), L (1-2 weeks), XL (2+ weeks, consider splitting)
3. Present the decomposition to the user for review
4. Use `apply_bootstrap` with the vision_id and the structured JSON containing components and features
5. Report the created entities (component count, feature count, features by priority). Bootstrapped features start at `planned` with **no revision baseline** — there is nothing built yet to capture; a feature gets its v1 revision at implement-time (`$zensu-implement`), or at discovery if `$zensu-ghost-scan` later finds it already built

### Phase 3: Post-Bootstrap Setup (5 Steps)

Use the `post_bootstrap_setup` prompt with the product_id to get the guided workflow context. Then execute each step:

**Step 1: Review & Refine Features**
- Review the bootstrapped features with the user
- Remove horizontal/implementation features that shouldn't be tracked
- Split XL-effort features using `add_subfeature` or `split_feature`
- Add missing features with `create_feature`
- Fix incorrect priorities or security classifications with `update_feature`
- After completion: call `update_bootstrap_step` with vision_id and step=1

**Step 2: Define User Journeys**
- Use `suggest_journeys` to get product context for journey suggestions
- Propose 3-5 critical user journeys to the user
- Create approved journeys with `create_user_journey` (include title, slug, journey_type, priority, persona)
- For each journey, add steps with `create_journey_step`:
  - Set step_order (1-based sequential)
  - Link to features via feature_id
  - Set interaction_type (action|navigation|input|validation|output|wait)
  - Mark critical steps with is_critical=true
- Use `analyze_journey_health` on each journey to identify weak links
- After completion: call `update_bootstrap_step` with vision_id and step=2

**Step 3: Deepen Security Setup**
- Use `analyze_feature_security` on all confidential/restricted features
- Use `suggest_security_tests` on high-risk features to identify needed tests
- Use `generate_threat_model` on the most critical feature for STRIDE analysis
- Present the security posture summary to the user
- After completion: call `update_bootstrap_step` with vision_id and step=3

**Step 4: Set Up Tier Availability (Optional)**
- Ask the user: "Does this product use pricing tiers (e.g. Free/Pro/Enterprise)?"
- If yes:
  1. Ask which tiers they need
  2. Use `create_tier` for each tier (ascending tier_order: 1, 2, 3...)
  3. Use `set_feature_tiers` for each feature:
     - Critical features: available in all tiers (hard gating)
     - High priority: Pro and above
     - Medium/low: highest tier only
  4. Use `get_tier_matrix` to show the complete matrix
- If no: skip directly to Step 5
- After completion: call `update_bootstrap_step` with vision_id and step=4 (or step=5 if skipping)

**Step 5: Generate CLAUDE.md**
- Use `generate_claude_md` with product_id and template="full"
- Present the generated CLAUDE.md to the user
- After completion: call `update_bootstrap_step` with vision_id and step=5

### Phase 4: Summary

Present a final summary:
- Product name and type
- Number of components and features created
- Journeys defined and their health scores
- Security posture overview
- Tier configuration (if applicable)
- CLAUDE.md generated

The product is now ready for implementation. Features can be worked on using the `$zensu-implement` skill.

## MCP Tools Used

| Tool | Phase | Purpose |
|------|-------|---------|
| `create_product` | 1 | Create the product |
| `create_product_vision` | 1 | Store the vision document |
| `bootstrap_from_vision` | 2 | Get vision content for analysis |
| `apply_bootstrap` | 2 | Create components and features from decomposition |
| `list_features` | 3.1 | Review bootstrapped features |
| `update_feature` | 3.1 | Fix priorities, descriptions |
| `add_subfeature` | 3.1 | Split large features |
| `split_feature` | 3.1 | Split features into children |
| `create_feature` | 3.1 | Add missing features |
| `suggest_journeys` | 3.2 | Get context for journey suggestions |
| `create_user_journey` | 3.2 | Create journeys |
| `create_journey_step` | 3.2 | Add steps to journeys |
| `analyze_journey_health` | 3.2 | Check journey health |
| `analyze_feature_security` | 3.3 | Analyze feature security |
| `suggest_security_tests` | 3.3 | Get security test suggestions |
| `generate_threat_model` | 3.3 | Generate STRIDE threat model |
| `create_tier` | 3.4 | Create pricing tiers |
| `set_feature_tiers` | 3.4 | Assign features to tiers |
| `get_tier_matrix` | 3.4 | Show tier matrix |
| `generate_claude_md` | 3.5 | Generate CLAUDE.md template |
| `update_bootstrap_step` | 3.x | Track post-bootstrap progress |

## MCP Prompts Used

| Prompt | Phase | Purpose |
|--------|-------|---------|
| `post_bootstrap_setup` | 3 | Get guided workflow context with feature list and step instructions |
