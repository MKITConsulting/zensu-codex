# Credential-blind auth

The single most important security property of `$zensu-autopilot`:

> **The AI never sees a password or a token.** A script holds the secret, performs the
> login, and writes a session **artifact**; the skill receives only a path (or `ok`).

This is non-negotiable. Everything below exists to keep a real credential out of the
model's context while still letting the run validate an authenticated feature.

## The login-script contract

A project provides a **login script** (a command, not an app endpoint). The skill runs it
and reads exactly one line from stdout:

```
Skill:  run loginScript ──►  script (deterministic):
                               1. ensure an ephemeral user exists  (local/throwaway DB only)
                               2. log in                           (API call OR headless form submit)
                               3. write a session artifact         (file the driver can load)
                               4. print ONE line:  <KEY>=<path|ok>  (NEVER the secret)
Skill:  ◄──  e.g.  STORAGE_STATE=/tmp/autopilot.xxxx/state.json
Skill:  load the artifact into the driver → already authenticated → validate
```

The skill passes the **path** to the driver. It never opens the artifact, never echoes it,
never `cat`s it. The credential lives only inside the script and the artifact file.

### Artifact forms by driver

| Driver | Artifact (`auth.artifact`) | How the driver consumes it |
|---|---|---|
| `browser` | `storageState` — Playwright storage-state JSON (cookies + localStorage) | launch context with `storageState: <path>` |
| `api` | `bearer-token-file` — a file containing the token | read into the `Authorization: Bearer` header at request time |
| `cli` | `bearer-token-file` / `none` | env or a config file the binary reads |
| `desktop` | `keychain` — an OS keychain/credential-store entry | the app reads its own keychain entry |
| `async`/`iac` | broker creds / kubeconfig (script-delivered) | passed to the client/provider by path, never inlined |
| any | `none` | feature needs no auth — skip the login step entirely |

### Login-script forms

- **API login (preferred when available):** the script `POST`s to the project's real login
  route with throwaway credentials and captures the returned token/cookies into the
  artifact. No browser needed; fast and deterministic.
- **Headless form submit:** when only a browser login exists, the script drives a headless
  browser to fill + submit the real login form and dumps `storageState`. The form-filling
  happens **inside the script**, so the secret is typed by the script, never by the AI.
- **Seed + login:** if the app has no user yet, the script seeds an ephemeral user in the
  local DB first (e.g. a `seed` target), then logs in. Idempotent: safe to re-run.

## Why a script, not a test-login endpoint

A test-login / auth-bypass **endpoint** ships auth-bypass code inside the application
binary. Even env-gated, that is a standing prod backdoor risk: a misconfiguration,
build-flag slip, or env leak turns it into an authentication bypass in production. A
**script** ships **no app code** — it is build-time tooling with zero production attack
surface. **Prefer the script form. Do not introduce an endpoint to satisfy autopilot.**

If a project already has an endpoint variant and insists on using it, the skill uses it
**only** when it is: env-gated (default **off**), fail-closed, and excluded from production
builds (e.g. a build tag). The skill **refuses** an endpoint that is not all three. The
script form remains strongly preferred.

## Secrets, config, and the three-way split

Keep three things strictly separate:

```
recipe (commands)     →  .zensu/autopilot.yaml   committed, shared, SECRET-FREE
real secret values    →  .env (gitignored)        referenced from the recipe BY NAME only
throwaway login creds  →  derived at runtime inside the login script, never stored
```

- The committed config names env vars (`PASSWORD_ENV: AUTOPILOT_TEST_PASSWORD`); it never
  contains a value. So every developer shares one recipe and nobody re-configures.
- The login script reads its secret from the environment / `.env` / a local secret store —
  never from an argument the skill constructs and never printed back.
- For a throwaway local user the script can derive a random password at runtime, use it to
  seed + log in, and discard it — the value never leaves the script.

## Artifacts are credentials — handle them as such

A `storageState` file or token file authenticates as the user; treat it like a password:

- Write it under a per-run `mktemp -d` temp dir, `chmod 600`.
- Never log it, never print its contents, never include it in evidence or the PR body.
- Delete it (and tear down the temp dir) at the end of the run, including on failure.
- The skill references the artifact **by path** only; it does not read the value.

## Degradation (when there is no safe path)

If login is only possible by the **AI typing a real secret into a form from its context**
— no scriptable path, no API route, no seed — that is the case to **avoid**, not to work
around. Do not place a real secret in context. Instead degrade per the ladder in
`SKILL.md`: ask once in the planning gate whether a login script can be provided, and if
not, **skip the authenticated validation** and ship a reviewed, gated PR with the gap
stated explicitly in the report. A missing live proof is acceptable; a leaked credential
is not.

## Security checklist the skill enforces

- [ ] The skill never receives, constructs, prints, or stores a password or token.
- [ ] The login script prints only `<KEY>=<path|ok>` — no secret on stdout/stderr.
- [ ] Ephemeral users exist only in a local/throwaway DB, never against real data.
- [ ] Artifacts: temp dir, `chmod 600`, never logged, deleted after the run.
- [ ] Config is secret-free; values live in gitignored `.env`, referenced by name.
- [ ] No test-login endpoint is introduced; an existing one is used only if env-gated +
      fail-closed + excluded from prod builds, else refused.
- [ ] Cloud/kube/broker creds (async/iac drivers) are script-delivered by path, same rule.
