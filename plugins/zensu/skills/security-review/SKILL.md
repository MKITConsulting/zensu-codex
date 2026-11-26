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
- A feature ID to review. The user may name it as `KEY-N` (e.g. `ZEN-42`), as a slug or as the feature UUID, but **every `<feature-id>` CLI argument takes the feature UUID**: a `KEY-N` id or a slug fails with `invalid feature id (status 400, code bad_request)`. Step 1 resolves it first.

Every command accepts `--json` for machine-readable output; run `zensu security <verb> --help` for the full flag set.

## Workflow

Execute these steps in order. The classification MUST be set first as all subsequent analysis depends on it.

### Step 1: Set Security Classification

Ask the user for the feature ID. Every `<feature-id>` below is the feature UUID, so if the ID is not a UUID, read and follow [Resolve a feature ID to its UUID](../implement/references/feature-id-resolution.md) before any other `zensu` call. Then run `zensu security classify <feature-id>` with the relevant flags:

- `--classification`: public | internal | confidential | restricted; pass only a level that keeps or raises the recorded one, and a feature without one counts as `internal`
- `--data-sensitivity`: none | pii | financial | health | credentials
- `--auth-required` / `--auth-type`: jwt | api-key | oauth2 | none
- `--input-validation`, `--rate-limited`, `--encryption-at-rest`, `--encryption-in-transit`, `--audit-logged` (booleans)
- `--threat-model-status`: not-required | pending
- `--pentest-status`: not-required | pending | failed

Lowering the classification, marking the threat model `completed` and marking a pentest
`passed` are decisions for an admin signed in to the Zensu web app, never for this skill:
Zensu refuses each of them from `zensu security classify` with a `400`. When the evidence
or the user calls for one, run no command for it; name it as an open decision for an
admin, with its evidence, and hand it on with the feature's browser link (Step 6).

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

### Step 6: Record the Security Review

Record a review only for `rejected` or `conditional`, which reject the feature or ask for
changes. A clean review that finds nothing blocking records nothing. Approving a security
review is a decision for an admin signed in to the Zensu web app: Zensu refuses
`zensu security review --status approved` with a `400`, so never pass it. Present the
findings instead, and hand the approval to an admin with the feature's browser link,
together with every decision Step 1 left open. When `zensu auth status` reports
`https://api.zensu.dev`, the link is
`https://app.zensu.dev/products/<product-id>/features/<feature-id>?tab=security`, the
feature's page in the hosted web app, opened on its Security tab; for another host, give
the same path on that instance's web app. Take `<product-id>` from the product that Step 1
used to resolve the feature ID, or from `product_id` in `zensu features get <feature-id> --json`.

Run `zensu security review <feature-id>` with:
- `--reviewer` (required): Reviewer identifier (e.g. "codex" or username)
- `--status` (required): rejected | conditional
- `--type` (optional): manual | automated | external (default: manual)
- `--findings` (optional): Review findings summary
- `--conditions` (optional): Conditions for conditional approval

`--findings` and `--conditions` are Markdown: Zensu renders headings, lists and code, so write
structured Markdown, not one unformatted paragraph. They never go into the command line itself:
inside double quotes the shell runs every backtick span and expands every `$NAME` and `$(…)`, and
a single quote ends at the first apostrophe. Write each to its own `mktemp` file with a quoted
heredoc, one recipe per shell call, never inside `$(…)`, and pass it as `"$(cat "$f")"`:

```bash
f="$(mktemp)" || exit 1
trap 'rm -f "$f"' EXIT
c="$(mktemp)" || exit 1
trap 'rm -f "$f" "$c"' EXIT
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<the findings, unchanged>
ZENSU_TEXT_<hex>
cat >| "$c" <<'ZENSU_TEXT_<hex>'
<the conditions, unchanged>
ZENSU_TEXT_<hex>
grep -qI -e '[^[:space:]]' -- "$f" && grep -qI -e '[^[:space:]]' -- "$c" || exit 1
zensu security review <feature-id> --reviewer <reviewer> --status <status> --findings "$(cat "$f")" --conditions "$(cat "$c")"
```

`<hex>` stands for 12 random hex digits you pick once the text is final; check that no line of the
text equals the delimiter. The `grep` checks stop the call before an empty, blank or binary value
reaches Zensu. Write the conditions file and pass `--conditions` only for the status
`conditional`. For any other status, drop the `c` lines (its `mktemp`, its widened trap and its
heredoc), the second `grep` and `--conditions`, so the guard reads
`grep -qI -e '[^[:space:]]' -- "$f" || exit 1`.

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
- Review status (rejected, conditional, or waiting for an admin's approval)
- Decisions left for an admin, with the feature's browser link
- Release gate status (pass/fail)

## CLI Commands Used

| Command | Step | Purpose |
|---------|------|---------|
| `zensu products list` | 1 | Find the product a `KEY-N` id or a slug belongs to |
| `zensu features list` | 1 | Resolve a `KEY-N` number or a slug to the feature UUID, filtered locally to the one match |
| `zensu security classify` | 1 | Set security attributes |
| `zensu security analyze` | 1, 2 | Analyze current security state |
| `zensu security suggest-tests` | 3 | Get context for test suggestions |
| `zensu security threat-model` | 4 | Get context for STRIDE model |
| `zensu security add-test` | 5 | Link security tests |
| `zensu security review` | 6 | Record a rejected or conditional review |
| `zensu features get` | 6 | Read the product id for the browser link |
| `zensu security validate` | 7 | Check release gate |
| `zensu security posture` | 7 | Product-wide security overview |
