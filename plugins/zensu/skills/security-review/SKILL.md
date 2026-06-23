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

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and on `PATH`
- Authenticated: `zensu auth login` (check with `zensu auth status`)
- A feature ID (ZEN-xxx format or UUID) to review

Every command accepts `--json` for machine-readable output; run `zensu security <verb> --help` for the full flag set.

## Workflow

Execute these steps in order. The classification MUST be set first as all subsequent analysis depends on it.

### Step 1: Set Security Classification

Ask the user for the feature ID, then run `zensu security classify <feature-id>` with the relevant flags:

- `--classification`: public | internal | confidential | restricted
- `--data-sensitivity`: none | pii | financial | health | credentials
- `--auth-required` / `--auth-type`: jwt | api-key | oauth2 | none
- `--input-validation`, `--rate-limited`, `--encryption-at-rest`, `--encryption-in-transit`, `--audit-logged` (booleans)
- `--threat-model-status`: not-required | pending | completed
- `--pentest-status`: not-required | pending | passed | failed

If the feature already has a classification, run `zensu security analyze <feature-id>` first to see the current state and ask if changes are needed.

### Step 2: Analyze Security State

Run `zensu security analyze <feature-id>`. This returns:
- Calculated security score (0-10)
- Requirements matrix based on classification
- Release gate status

Present the results to the user, highlighting current score vs. required threshold, met vs. unmet requirements, and any blocking issues for release.

### Step 3: Suggest Security Tests

Run `zensu security suggest-tests <feature-id>`. This returns the security profile, existing tests, OWASP tags, compliance tags, and requirements.

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

Run `zensu security threat-model <feature-id>`. This returns the feature security profile, existing threat model, product type, and requirements.

Generate a STRIDE threat model covering:
- **S**poofing — Identity and authentication threats
- **T**ampering — Data integrity threats
- **R**epudiation — Audit and logging threats
- **I**nformation Disclosure — Data exposure threats
- **D**enial of Service — Availability threats
- **E**levation of Privilege — Authorization threats

Present the threat model to the user with specific mitigations for each identified threat.

### Step 5: Link Security Tests

For each recommended and implemented security test, run `zensu security add-test <feature-id>` with:
- `--type` (required): auth-bypass | injection | access-control | rate-limit | input-validation | data-exposure | header-security | dependency-scan | csrf | xss | ssrf
- `--file` (required): Path to the test file
- `--last-run-status` (optional): passed | failed | skipped
- `--owasp-id` (optional): OWASP Top 10 ID (e.g. A01:2021)

### Step 6: Complete Security Review

Run `zensu security review <feature-id>` with:
- `--reviewer` (required): Reviewer identifier (e.g. "codex" or username)
- `--status` (required): approved | rejected | conditional
- `--type` (optional): manual | automated | external (default: manual)
- `--findings` (optional): Review findings summary
- `--conditions` (optional): Conditions for conditional approval

### Step 7: Validate Release Readiness

Run `zensu security validate <feature-id>` to check if the feature passes all security requirements for release.

If the validation fails, present the blocking violations and guide the user through resolving them.

Optionally, run `zensu security posture <product-id>` to show the product-wide security overview.

### Summary

Present a final summary:
- Security classification and data sensitivity
- Security score (before and after review)
- Threat model highlights
- Security tests linked
- Review status (approved/rejected/conditional)
- Release gate status (pass/fail)

## CLI Commands Used

| Command | Step | Purpose |
|---------|------|---------|
| `zensu security classify` | 1 | Set security attributes |
| `zensu security analyze` | 1, 2 | Analyze current security state |
| `zensu security suggest-tests` | 3 | Get context for test suggestions |
| `zensu security threat-model` | 4 | Get context for STRIDE model |
| `zensu security add-test` | 5 | Link security tests |
| `zensu security review` | 6 | Complete the review |
| `zensu security validate` | 7 | Check release gate |
| `zensu security posture` | 7 | Product-wide security overview |
