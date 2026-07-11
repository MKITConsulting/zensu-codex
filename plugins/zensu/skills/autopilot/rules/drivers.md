# Driver catalog

A **driver** is how `$zensu-autopilot` exercises the running feature and observes whether
each acceptance criterion (AC) holds. The orchestration in `SKILL.md` is identical for
every driver; only the driver and its session artifact (`auth.md`) change per project. The
probe (`probe.md`) picks the driver from the detected app type; `--driver=` overrides.

A driver does two things for each AC: **exercise** (perform the action the AC describes)
and **assert** (observe the result and record evidence — a status code, a DOM state, a
stdout line, a DB row, a screenshot). Evidence per AC feeds the PR's per-AC table.

## Tier 1 — ship first (covers the common case)

| Driver | Target | Exercise → assert | Session artifact |
|---|---|---|---|
| `api` | HTTP / Bearer service | client call → status + JSON body / side-effect | `bearer-token-file` |
| `browser` | web app (+ electron, responsive) | Playwright: actions → DOM assertions + screenshots | `storageState` |
| `cli` | binary / TUI | run with args/stdin → stdout + exit code (TUI via pty) | `none` / `bearer-token-file` |
| `async` | queue / event bus (Kafka, SQS, NATS, Rabbit) | publish a message → assert the side-effect (DB row, out-topic, log) | broker creds (script) |
| `iac` | terraform / helm / k8s | plan/apply to **kind**/localstack → assert resources exist + are correct | kubeconfig (script) |
| `custom` | anything else | project `exercise` + `assert` scripts → exit 0 + evidence | as needed |

### `api`
- The default for any HTTP service without a UI, and the fast path for backend-only ACs
  even when a UI exists.
- Load the bearer token from the artifact at request time (never inline it). Assert on
  status code **and** response body / a persisted side-effect — not status alone.
- Project-supplied `assert` command (e.g. an e2e test target) is preferred when present;
  it returns exit 0 = pass and prints evidence.

### `browser`
- Drive with Playwright. Launch the context with `storageState: <artifact-path>` so the
  session is already authenticated — no login typed by the AI.
- Assert on visible DOM state (text, roles, attributes) and capture a screenshot per AC as
  evidence. Cover the states the ACs name: default, empty, error, loading.
- Electron apps use the same engine; a responsive/mobile-web AC sets `browser.viewport`.

### `cli`
- Run the binary with the AC's inputs; assert on stdout/stderr content **and** exit code.
- A TUI sets `cli.pty: true` so the driver captures the rendered terminal via a pseudo-tty.

### `async`
- Publish to the input queue/topic, then assert the downstream effect (a row written, a
  message on an output topic, a log line). Broker credentials are script-delivered by path
  (same blindness rule as login — see `auth.md`).

### `iac`
- **Never against prod.** Default to `plan`/dry-run; `apply` only to a disposable target —
  `kind` for k8s/helm, `localstack` for AWS, an ephemeral project/namespace otherwise.
- Assert the planned/created resources match the AC (resource exists, field set, count).
  Cloud/kube creds are real, prod-adjacent secrets — script-delivered, never in AI context.

### `custom` — why the catalog is non-exhaustive by design
- The escape hatch: the project supplies two scripts, `exercise` and `assert` (or a single
  `assert` that does both), each exiting 0 on pass and printing evidence. The skill runs
  them and reads exit code + output.
- This makes any target pluggable without extending the skill: browser-extension,
  game/canvas, notebook, embedded/firmware, hardware-in-the-loop. An unknown app type is
  never a dead end — it is a `custom` driver.

## Sub-modes — flags on a driver, NOT separate drivers

- `api.protocol: rest | grpc | graphql` (grpc via `grpcurl`/`buf`; graphql posts a query)
- `api.stream: sse | ws` (assert the streamed messages, not just the open)
- `api` webhook style: POST a signed payload + assert the signature path
- `browser.viewport: <w>x<h>` (responsive / mobile-web)
- `cli.pty: true` (TUI capture)

## Augments — cross-cutting, any driver may also assert

A driver can additionally assert on a side-effect sink, declared under `validate.sinks`:

- `email` — a dev mail sink (mailpit / mailhog): assert a message arrived + its content.
- `db` — assert a row/column/schema change.
- `log` — assert a log line was emitted.
- `metrics` — assert a counter/gauge moved.
- `file` / `artifact` — assert a generated file (PDF/CSV/image) exists + is correct.

Use augments to make an AC's *side-effect* checkable even when the primary driver only sees
the foreground (e.g. a `browser` AC "sends a confirmation email" → `browser` action +
`email` sink assertion).

## Tier 1.5 — cheap, common, add as needed

- `library` — run a usage example/snippet, assert its output (for a published package/API).
- `artifact` — assert a generated document/render without a running service.
- the `email` sink augment above.

## On-demand — real but heavier, only when the project needs them

- `mobile` — iOS Simulator + Android Emulator; **Maestro** as the common cross-platform
  flow runner (one flow file drives both). Needs Xcode / Android SDK present — if absent,
  the probe degrades and says so.
- `desktop-native` — OS UI automation: macOS XCUITest / computer-use, Windows FlaUI, Linux
  AT-SPI. Session artifact is typically a `keychain` entry the app reads itself.

These need their toolchains installed. The probe checks for the tool and **degrades the
driver** (with a note) rather than faking success when it is missing — toolchain honesty.

## Choosing + degrading

1. Probe detects the app type → picks the driver (table above). `--driver=` overrides.
2. If the driver's toolchain is missing, degrade: fall back to a lighter driver that can
   still assert the AC (`browser` → `api` for backend-observable ACs), or skip that AC's
   live proof and state it in the report.
3. Multiple app surfaces (e.g. web UI + backend API) can mix: validate UI-observable ACs
   via `browser` and backend-only ACs via `api` in the same run. Pick the cheapest driver
   that can actually observe each AC.
