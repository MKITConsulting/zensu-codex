# Self-setup probe

The probe is how `$zensu-autopilot` configures itself. It runs in Phase 0 and resolves
four **seams** the run needs, then verifies them, then writes the result back so the next
run is zero-touch. The goal: a non-expert types a feature and approves a plan — the skill
figured out the rest.

## The four seams

| Seam | Question it answers | Lands in config as |
|---|---|---|
| **boot** | How is the app brought up locally? | `services[]` (ordered, each with `up` + `ready`) |
| **gates** | What must pass before/after a change? | `gates[]` (+ `coverageMinPerFile`) |
| **auth** | How does a session get created without the AI seeing a secret? | `auth` (see `auth.md`) |
| **validate** | How is the running feature exercised + ACs observed? | `validate` (driver — see `drivers.md`) |

## Resolution order (per value, not per seam)

Apply this independently to every value — a project may pin `gates` explicitly while the
probe still has to detect `boot`:

```
1. explicit --flag                       highest precedence (one-off override)
2. .zensu/autopilot.yaml                 the persisted recipe (skip detection entirely)
3. auto-detect from the repo             the heuristics below
4. confirm gaps in the PLANNING gate     plain-language, best guess pre-filled, yes/no
5. write the resolved recipe back        → next run starts at step 2 for that value
```

Never hand-author the config and never silently guess: step 3 produces a **proposal**,
step 4 **confirms** anything it is not sure about, step 5 **persists** the confirmed
result. Confirm, don't author.

## Auto-detect heuristics (step 3)

Read the repo and synthesize a recipe. Signals, by what they reveal:

**Boot / services**
- `package.json` scripts → `dev`/`start`/`serve` (+ the package manager: `pnpm-lock.yaml`
  → pnpm, `yarn.lock` → yarn, else npm; honor a `packageManager` field).
- `Makefile` targets → `dev`, `run`, `db-up`, `migrate`, `seed`, `up`.
- `docker-compose.yml` / `compose.yaml` → `docker compose up -d <svc>`; the DB service
  name + port reveal the `ready` probe (`pg_isready`, `redis-cli ping`, a TCP check).
- `go.mod` → `go run ./cmd/<x>` or a Makefile target; `pyproject.toml`/`manage.py` →
  `uvicorn`/`flask run`/`python manage.py runserver`.
- A frontend dev server's port + a backend's port + any proxy config (`vite.config.*`
  `proxy`, `next.config.*` rewrites) tell you whether the UI calls the API directly or
  through a proxy — this decides the validation `baseUrl`.

**Ports + isolation**
- Default ports come from config/env (`SERVER_PORT`, `DB_PORT`, the dev-server default).
- If a dev stack may already occupy those ports, **offset** the autopilot stack's ports so
  it never collides with the user's running instance, and thread the offsets through every
  `up`/`ready`/`baseUrl`. Record the chosen ports so the run is reproducible.

**Gates**
- A single aggregate target if one exists (`make check`, `npm run ci`, `task verify`) is
  preferred over re-deriving the pieces.
- Otherwise compose from what's present: type-check (`tsc --noEmit`, `go vet`, `mypy`),
  lint (`eslint`, `golangci-lint`, `ruff`), unit tests (`vitest run`, `go test ./...`,
  `pytest`), and a coverage floor if the repo enforces one (`coverageMinPerFile`).
- Honor repo conventions found in `CLAUDE.md` / contributing docs (e.g. a per-file
  coverage minimum, a package manager mandate) over generic defaults.

**Auth** — see `auth.md`. Detection looks for an existing seed/login script or target
(`make seed`, a `scripts/login.*`, a documented test user) before proposing the
login-script convention. The probe never invents credentials and never reads a secret.

**Validate / driver** — see `drivers.md`. The app type picks the driver: a web UI →
`browser`; an HTTP service with no UI → `api`; a binary/TUI → `cli`; a queue/event
consumer → `async`; terraform/helm/k8s → `iac`; anything else → `custom`.

## Verify before trust (the part that matters)

A guessed recipe is worthless until it runs. **In Phase 0, before showing the plan, the
probe actually executes the boot + auth path once:**

1. If the checkout has no installed dependencies, restore them from the committed lockfile
   first (e.g. `npm ci`, `pnpm install --frozen-lockfile`); that routine setup never becomes a
   question by itself. Then bring up `services[]` in order, waiting on each `ready` check
   (bounded timeout).
2. Run the configured **login script** and confirm it returns an artifact path (never the
   secret — see `auth.md`). For `auth.mode: none`, skip.
3. Do a minimal liveness assertion through the chosen driver (e.g. `browser`: load
   `baseUrl` and confirm the app rendered; `api`: an authenticated request returns non-5xx).
4. Tear the stack back down.

If every step works, stay **silent** — the user sees only the plan. If a step fails, the
failure becomes one of the plain-language questions in the planning gate (with the best
guess pre-filled), never a mid-run surprise. A probe that cannot verify a seam **degrades
that seam** per the ladder in `SKILL.md`; it does not fake success.

## Write-back (step 5)

After a successful probe, propose writing the resolved recipe to `.zensu/autopilot.yaml`
(schema in `config.md`). It is **secret-free** by construction — commands and names only,
never a credential value. Because committing is a shared decision, the skill **proposes**
the file and the diff and lets the user commit it (honoring "never commit without
permission"). Once committed, every future run starts at resolution step 2 and skips
detection + confirmation entirely — the zero-touch path.

## Dummy-proofing invariants

1. Always show a guess and ask yes/no — never make the user author config.
2. One interactive phase — every probe question is batched into the planning gate.
3. Plain language — "I'll start it with `pnpm dev` and Postgres via docker — right?", not
   jargon.
4. Verify before trust — a wrong guess dies in Phase 0, not in the fix loop.
5. Degrade, never dead-end — an unresolved seam narrows scope (e.g. skip authenticated
   validation) but still ships a reviewed, tested PR, with the gap stated.
