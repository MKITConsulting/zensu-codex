---
name: zensu-security-review
description: Run a comprehensive security review for a Zensu feature, guiding through classification, security-state analysis, security testing, STRIDE threat modeling, and review completion. Use before releasing a feature, when it handles sensitive data, after scope changes, or when preparing for a security audit.
---

# $zensu-security-review

Run a comprehensive security review for a Zensu feature. Guides through classification, analysis, security testing, threat modeling, and review completion.

## When to Use

- Before releasing a feature to production
- When a feature handles sensitive data (PII, financial, credentials)
- After significant changes to a feature's scope or architecture
- When preparing for a security audit

## Prerequisites

- Zensu MCP Server connected (plugin auto-configures via `.mcp.json`)
- `ZENSU_API_KEY` environment variable set
- A feature ID (ZEN-xxx format or UUID) to review

## Workflow

Execute these steps in order. The classification MUST be set first as all subsequent analysis depends on it.

### Step 1: Set Security Classification

Ask the user for the feature ID, then use `set_security_classification` with:

- `feature_id` (required)
- `security_classification`: public | internal | confidential | restricted
- `data_sensitivity`: none | pii | financial | health | credentials
- `auth_required`: true/false
- `auth_type`: jwt | api-key | oauth2 | none
- `input_validation`: true/false
- `rate_limited`: true/false
- `encryption_at_rest`: true/false
- `encryption_in_transit`: true/false
- `audit_logged`: true/false
- `threat_model_status`: not-required | pending | completed
- `pentest_status`: not-required | pending | passed | failed

If the feature already has a classification, use `analyze_feature_security` first to see the current state and ask if changes are needed.

### Step 2: Analyze Security State

Use `analyze_feature_security` with the feature_id. This returns:
- Calculated security score (0-10)
- Requirements matrix based on classification
- Release gate status

Present the results to the user, highlighting:
- Current score vs. required threshold
- Met vs. unmet security requirements
- Any blocking issues for release

### Step 3: Suggest Security Tests

Use `suggest_security_tests` with the feature_id. This returns the security profile, existing tests, OWASP tags, compliance tags, and requirements.

Based on the returned context, recommend specific security tests. Map recommendations to the available test types:
- `auth-bypass` — Authentication bypass attempts
- `injection` — SQL/NoSQL/command injection
- `access-control` — Authorization and access control
- `rate-limit` — Rate limiting verification
- `input-validation` — Input sanitization and validation
- `data-exposure` — Sensitive data exposure checks
- `header-security` — Security headers verification
- `dependency-scan` — Dependency vulnerability scan
- `csrf` — Cross-site request forgery
- `xss` — Cross-site scripting
- `ssrf` — Server-side request forgery

### Step 4: Generate Threat Model

Use `generate_threat_model` with the feature_id. This returns the feature security profile, existing threat model, product type, and requirements.

Generate a STRIDE threat model covering:
- **S**poofing — Identity and authentication threats
- **T**ampering — Data integrity threats
- **R**epudiation — Audit and logging threats
- **I**nformation Disclosure — Data exposure threats
- **D**enial of Service — Availability threats
- **E**levation of Privilege — Authorization threats

Present the threat model to the user with specific mitigations for each identified threat.

### Step 5: Link Security Tests

For each recommended and implemented security test, use `add_security_test` with:
- `feature_id` (required)
- `security_test_type` (required): auth-bypass | injection | access-control | rate-limit | input-validation | data-exposure | header-security | dependency-scan | csrf | xss | ssrf
- `file_path` (required): Path to the test file
- `last_run_status` (optional): passed | failed | skipped
- `owasp_id` (optional): OWASP Top 10 ID (e.g. A01:2021)

### Step 6: Complete Security Review

Use `complete_security_review` with:
- `feature_id` (required)
- `reviewer` (required): Reviewer identifier (e.g. "codex" or username)
- `review_status` (required): approved | rejected | conditional
- `review_type` (optional): manual | automated | external (default: manual)
- `findings` (optional): Review findings summary
- `conditions` (optional): Conditions for conditional approval

### Step 7: Validate Release Readiness

Use `validate_feature_security` with the feature_id to check if the feature passes all security requirements for release.

If the validation fails, present the blocking violations and guide the user through resolving them.

Optionally, use `get_security_posture` with the product_id to show the product-wide security overview.

### Summary

Present a final summary:
- Security classification and data sensitivity
- Security score (before and after review)
- Threat model highlights
- Security tests linked
- Review status (approved/rejected/conditional)
- Release gate status (pass/fail)

## MCP Tools Used

| Tool | Step | Purpose |
|------|------|---------|
| `set_security_classification` | 1 | Set security attributes |
| `analyze_feature_security` | 1, 2 | Analyze current security state |
| `suggest_security_tests` | 3 | Get context for test suggestions |
| `generate_threat_model` | 4 | Get context for STRIDE model |
| `add_security_test` | 5 | Link security tests |
| `complete_security_review` | 6 | Complete the review |
| `validate_feature_security` | 7 | Check release gate |
| `get_security_posture` | 7 | Product-wide security overview |

## MCP Prompts Used

| Prompt | When | Purpose |
|--------|------|---------|
| `implement_with_security` | Before implementation | Get security constraints for implementation guidance |
