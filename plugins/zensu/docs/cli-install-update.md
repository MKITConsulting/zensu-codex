# Install or update the Zensu CLI

The plugin and CLI are separate installations. Updating a plugin does not update
`zensu`. Use the same installation channel that owns your current executable.

## Install once

Choose one method:

```sh
# macOS / Homebrew
brew install --cask mkitconsulting/tap/zensu

# Linux / macOS install script
curl -fsSL https://zensu.dev/install.sh | sh
```

On Windows, in PowerShell:

```powershell
irm https://zensu.dev/install.ps1 | iex
```

Check the executable before signing in or capturing work:

```sh
zensu --version
zensu ai-work context --help
zensu ai-work submit --help
```

Authentication is separate: use `zensu auth login` only when you want to connect
your account. Installing or updating never confirms a product or feature and does
not authorize sending a work report.

## Update

On versions that provide the updater:

```sh
zensu update --check  # inspect availability without replacing the binary
zensu update
zensu --version
```

The updater delegates Homebrew installations to Homebrew. Supported standalone
installations verify signed checksums and the archive before replacing the binary.
Development builds, containers, and other package-managed installations receive
instructions for their original installation channel instead of being overwritten.

**Older CLI: `unknown command "update"`.** The updater is not included in v0.18.0
or earlier. Until an updater-capable release is available, and for the first
upgrade from an older version, use your original installer:

```sh
# Existing Homebrew installation
brew update
brew upgrade --cask mkitconsulting/tap/zensu

# Existing install-script installation on Linux / macOS
curl -fsSL https://zensu.dev/install.sh | sh
```

For an existing PowerShell-script installation, rerun the Windows command above.
Keep any custom installation directory from your original setup. Do not install a
second copy over a package manager's binary. Container users update their image;
source/development installations follow their build or package instructions.

If the old version still runs, inspect PATH with `type -a zensu` (macOS/Linux) or
`Get-Command zensu -All` (PowerShell). Ensure your shell **and the coding host** use
the intended executable. Do not reset credentials, delete capture receipts, or
restart an active conversation merely to fix a PATH mismatch.

## Early capture checks and explicit scope

At the start of an authorized implementation goal, the plugin's native capture
helper runs `preflight`: bounded local CLI help/version checks, followed by a
read-only `ai-work context` query if compatible. Startup by itself creates no work.
The helper checks capabilities rather than assuming that a version number is enough.

| Result | Next step |
| --- | --- |
| `cli_unavailable` / `cli_incompatible` | Install/update the CLI using this guide; repeat preflight. No fallback to an older capture protocol. |
| `product_confirmation_required` | Confirm the exact product once, then use `zensu ai-work bind --product <uuid> --confirm`. Never guess from a repository name. |
| `feature_confirmation_required` | Confirm this goal's exact feature, or explicitly choose product maintenance with a reason. A valid product binding is reused. |
| `scope_unavailable` | Check the selected account, organization, API host and product/feature access; no automatic login or reassignment. |
| `ready` | The confirmed scope can be used by `begin`; preflight itself has not created a report. |
| `capture_disabled` | Reporting was declined. Continue coding without scope questions or upload attempts. |

Product maintenance uses `--maintenance-reason <reason>` instead of a feature.
Work spanning products requires explicit intent and `--cross-product-reason
<reason>` for this goal; it is never a fallback for missing scope. A feature may
also specify its exact `--feature-revision <uuid>`.

When a user declines reporting, the native helper's `pause` operation records a
local pause without contacting Zensu or modifying old receipts. Stop/checkpoint
cannot submit them while paused. Only an explicitly re-enabled, confirmed `begin`
resumes capture. Updating the CLI does not resume reporting, rewrite old records,
or backfill historical work. Safe receipt recovery is documented in the AI-work
capture guide and `zensu ai-work recover --help` on recovery-capable releases.

A plugin code review, a successful release and a submitted work report are separate
outcomes. None is human acceptance in Zensu.
