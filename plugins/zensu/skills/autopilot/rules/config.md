# Config — `.zensu/autopilot.yaml`

The persisted recipe. **Committed, shared, secret-free.** Written by the skill after a
successful probe (`probe.md`); hand-editable but never required. Once it exists, every run
skips detection — the zero-touch path.

Rules:
- **No secret values, ever.** Commands and names only. Real secrets live in a gitignored
  `.env`, referenced by name (`PASSWORD_ENV: AUTOPILOT_TEST_PASSWORD`). See `auth.md`.
- The skill **proposes** the file + diff and lets the user commit it (never commits
  without permission).
- Ports may be offset for isolation; if so, the offsets are baked into the commands here
  so the recipe is reproducible.

## Schema

```yaml
version: 1

vcs:
  provider: github          # github | gitlab
  prBase: main
  commitStyle: conventional
  worktreeOnly: true

services:                   # ordered bring-up; each waits on `ready` before the next
  - name: db
    up:    "<shell>"
    ready: "<shell, exits 0 when ready>"
    env:   { KEY: value }   # NON-SECRET only; real secrets referenced by NAME, value in .env
  - name: backend
    up:    "<shell>"
    ready: "<shell>"
  # ports auto-offset for isolation if a dev stack already occupies them

gates:                      # all must pass before the PR opens and after every fix round
  - "<shell, non-zero = fail>"
coverageMinPerFile: 90      # optional per-file coverage floor

auth:
  mode:        login-script # login-script | none
  loginScript: "<shell that prints '<KEY>=<path|ok>' — never the secret>"
  artifact:    storageState # storageState | bearer-token-file | keychain | none
  # skill reads only the artifact path/ok — never the credential value

validate:
  driver:  browser          # browser | api | cli | async | iac | custom  (see drivers.md)
  baseUrl: "<url>"          # browser / api
  assert:  "<shell>"        # cli / api / custom: exit 0 = pass, prints evidence
  # driver-specific keys: browser.viewport, api.protocol, cli.pty, iac plan target, ...
  sinks:                    # optional side-effect assertions (augments)
    - { type: email, at: "<url>" }
```

## Concrete instance — the zensu-monorepo (verified values)

This is the recipe the probe resolves for the Zensu monorepo, using real values from that
repo's `backend/Makefile`, `backend/internal/config/config.go`, and `frontend/vite.config.ts`:

```yaml
version: 1
vcs: { provider: github, prBase: main, commitStyle: conventional, worktreeOnly: true }

services:
  - name: db
    up:    "make -C backend db-up"            # docker compose postgres :5432
    ready: "pg_isready -h localhost -p 5432"
  - name: backend
    up:    "make -C backend migrate && make -C backend dev"   # air hot-reload, :8080
    ready: "curl -fs http://localhost:8080/<health>"          # exact path resolved by probe
    env:   { EMAIL_PROVIDER: noop, NOTIFICATION_PROVIDER: noop }
  - name: frontend
    up:    "pnpm -C frontend dev"             # vite :5173, proxies /api → :8080
    ready: "curl -fs http://localhost:5173"

gates:
  - "make -C backend check"                   # fmt + vet + lint + test + migrations-integration
  - "pnpm -C frontend exec vitest run --coverage"
coverageMinPerFile: 90                        # repo rule 16

auth:
  mode:        login-script
  loginScript: "make -C backend e2e-session"  # NEW small target — see prerequisite below
  artifact:    storageState

validate:
  driver:  browser
  baseUrl: "http://localhost:5173"
  # an `api` profile is also viable for backend-only ACs:
  #   driver: api, assert: "make -C backend test-e2e", artifact: bearer-token-file
```

## Login-script prerequisite a project supplies

For the monorepo this is the only thing autopilot needs that does not exist yet: a small
`make e2e-session` target (the consumer-side login script) that

1. runs the existing seed (the monorepo's `backend/cmd/seed/main.go` already creates an
   email-confirmed `admin@zensu.dev` owner user, idempotent + RLS-safe),
2. logs that user in against the local backend (`POST /api/auth/login`),
3. writes `storageState.json` (cookies/localStorage) to a temp path,
4. prints exactly `STORAGE_STATE=<path>` and nothing else.

The credentials stay **inside that target**. The skill runs it and reads only the
`STORAGE_STATE=` line — it never sees the password. This is the login-script convention
from `auth.md` applied to one concrete repo; any project provides the equivalent for its
own stack (an API-login script, a headless-form script, or a seed+login target), and the
orchestration is identical.

## Notes

- A project with **no auth** sets `auth.mode: none` and omits `loginScript`; the validate
  step runs unauthenticated.
- A project with **no UI** sets `validate.driver: api` (or `cli`/`custom`) and provides an
  `assert` command instead of a `baseUrl`.
- `services[]` is ordered and each entry blocks on its `ready` check — model real
  dependencies (db before backend before frontend).
