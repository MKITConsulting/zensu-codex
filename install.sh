#!/usr/bin/env bash
# Zensu for Codex — installer.
#
# Wires the plugin into the STABLE Codex surfaces so everything works on the
# current Codex build (0.130.0) even though plugin-bundled hooks (the
# `plugin_hooks` feature) are still under development. Concretely it:
#   1. Registers the zensu MCP server      -> `codex mcp add` (~/.codex/config.toml)
#   2. Installs the 10 skills              -> $CODEX_HOME/skills/zensu-*/SKILL.md
#   3. Installs the 3 subagents            -> $CODEX_HOME/agents/zensu-*.toml
#   4. Merges the lifecycle hooks          -> $CODEX_HOME/hooks.json (absolute paths)
#   5. Appends persistent conventions      -> $CODEX_HOME/AGENTS.md (guarded block)
#   6. Seeds config + plugin-root          -> ~/.zensu/config.json, ~/.zensu/plugin-root
#
# Idempotent: re-running re-points everything at this checkout and never
# duplicates entries. Auth: by default the MCP server uses interactive OAuth
# (`codex mcp login zensu`); set ZENSU_API_KEY before running to wire a bearer
# token for CI/headless use instead.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
ZENSU_HOME="$HOME/.zensu"
MCP_URL="${ZENSU_MCP_URL:-https://mcp.zensu.dev/mcp}"

say() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "error: node is required (Codex bundles a Node launcher; install Node 18+)"; exit 1; }

step "Zensu for Codex — installing from $PLUGIN_DIR"
say "CODEX_HOME = $CODEX_HOME"

# ---------------------------------------------------------------------------
# 1. MCP server
# ---------------------------------------------------------------------------
step "Registering the zensu MCP server"
if command -v codex >/dev/null 2>&1; then
  codex mcp remove zensu >/dev/null 2>&1 || true
  if [ -n "${ZENSU_API_KEY:-}" ]; then
    codex mcp add zensu --url "$MCP_URL" --bearer-token-env-var ZENSU_API_KEY
    say "added (bearer token via \$ZENSU_API_KEY) -> $MCP_URL"
  else
    codex mcp add zensu --url "$MCP_URL"
    say "added (interactive OAuth) -> $MCP_URL"
    say "run 'codex mcp login zensu' to sign in, or set ZENSU_API_KEY and re-run for CI."
  fi
else
  say "WARNING: 'codex' CLI not found on PATH — skipping MCP registration."
  say "After installing Codex, run: codex mcp add zensu --url $MCP_URL"
fi

# ---------------------------------------------------------------------------
# 2. Skills  -> $CODEX_HOME/skills/<name>/SKILL.md  (name = frontmatter name)
# ---------------------------------------------------------------------------
step "Installing skills -> $CODEX_HOME/skills/"
mkdir -p "$CODEX_HOME/skills"
for d in "$PLUGIN_DIR"/skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  base="$(basename "$d")"
  case "$base" in zensu-*) name="$base" ;; *) name="zensu-$base" ;; esac
  rm -rf "${CODEX_HOME:?}/skills/$name"
  mkdir -p "$CODEX_HOME/skills/$name"
  cp -R "$d"/. "$CODEX_HOME/skills/$name/"
  say "$name"
done

# ---------------------------------------------------------------------------
# 3. Subagents -> $CODEX_HOME/agents/zensu-*.toml
# ---------------------------------------------------------------------------
step "Installing subagents -> $CODEX_HOME/agents/"
mkdir -p "$CODEX_HOME/agents"
for f in "$PLUGIN_DIR"/agents/*.toml; do
  [ -f "$f" ] || continue
  cp "$f" "$CODEX_HOME/agents/$(basename "$f")"
  say "$(basename "$f")"
done

# ---------------------------------------------------------------------------
# 4. Lifecycle hooks -> merge into $CODEX_HOME/hooks.json with absolute paths
# ---------------------------------------------------------------------------
step "Wiring lifecycle hooks -> $CODEX_HOME/hooks.json"
chmod +x "$PLUGIN_DIR"/hooks/*.sh 2>/dev/null || true
HOOKS_JSON="$CODEX_HOME/hooks.json"
[ -f "$HOOKS_JSON" ] && cp "$HOOKS_JSON" "$HOOKS_JSON.zensu-backup.$$" 2>/dev/null || true
HOOKS_JSON="$HOOKS_JSON" PLUGIN_DIR="$PLUGIN_DIR" TEMPLATE="$PLUGIN_DIR/hooks/hooks.json" node -e '
  const fs = require("fs");
  const hooksPath = process.env.HOOKS_JSON;
  const pluginDir = process.env.PLUGIN_DIR;
  const tmpl = JSON.parse(fs.readFileSync(process.env.TEMPLATE, "utf8"));
  const sub = s => String(s).split("${CODEX_PLUGIN_ROOT}").join(pluginDir);
  let existing = { hooks: {} };
  try { const j = JSON.parse(fs.readFileSync(hooksPath, "utf8")); if (j && typeof j === "object") existing = j; } catch (_) {}
  if (!existing.hooks || typeof existing.hooks !== "object") existing.hooks = {};
  const ours = pluginDir + "/hooks/";
  for (const ev of Object.keys(tmpl.hooks)) {
    const incoming = tmpl.hooks[ev].map(g => ({ ...g, hooks: (g.hooks || []).map(h => ({ ...h, command: sub(h.command) })) }));
    const arr = Array.isArray(existing.hooks[ev]) ? existing.hooks[ev] : [];
    const kept = arr.filter(g => !((g.hooks || []).some(h => typeof h.command === "string" && h.command.indexOf(ours) !== -1)));
    existing.hooks[ev] = kept.concat(incoming);
  }
  fs.writeFileSync(hooksPath, JSON.stringify(existing, null, 2) + "\n");
'
say "merged 5 events (PreToolUse, PostToolUse, SessionStart, Stop, UserPromptSubmit)"
say "NOTE: standalone hooks (the 'hooks' feature) are stable on 0.130.0; plugin-bundled"
say "hooks ('plugin_hooks') are still under development, which is why we wire ~/.codex/hooks.json."

# ---------------------------------------------------------------------------
# 5. Persistent instructions -> $CODEX_HOME/AGENTS.md (guarded, idempotent)
# ---------------------------------------------------------------------------
step "Installing persistent conventions -> $CODEX_HOME/AGENTS.md"
AGENTS_MD="$CODEX_HOME/AGENTS.md"
BEGIN="<!-- BEGIN ZENSU (managed by zensu-codex install.sh; do not edit between markers) -->"
END="<!-- END ZENSU -->"
mkdir -p "$CODEX_HOME"
touch "$AGENTS_MD"
# strip any previous managed block, then append the current one
AGENTS_MD="$AGENTS_MD" BEGIN="$BEGIN" END="$END" BLOCK="$PLUGIN_DIR/AGENTS.zensu.md" node -e '
  const fs = require("fs");
  const p = process.env.AGENTS_MD, b = process.env.BEGIN, e = process.env.END;
  let cur = "";
  try { cur = fs.readFileSync(p, "utf8"); } catch (_) {}
  const re = new RegExp("\\n*" + b.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[\\s\\S]*?" + e.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\n*", "g");
  cur = cur.replace(re, "\n");
  let block = "";
  try { block = fs.readFileSync(process.env.BLOCK, "utf8"); } catch (_) {}
  const out = cur.replace(/\s*$/, "") + "\n\n" + b + "\n" + block.replace(/\s*$/, "") + "\n" + e + "\n";
  fs.writeFileSync(p, out);
'
say "appended a guarded ZENSU block"

# ---------------------------------------------------------------------------
# 6. Config + plugin-root
# ---------------------------------------------------------------------------
step "Seeding ~/.zensu/"
mkdir -p "$ZENSU_HOME"
if [ ! -f "$ZENSU_HOME/config.json" ]; then
  cp "$PLUGIN_DIR/config.example.json" "$ZENSU_HOME/config.json"
  say "created ~/.zensu/config.json (from config.example.json)"
else
  say "kept existing ~/.zensu/config.json"
fi
printf '%s\n' "$PLUGIN_DIR" > "$ZENSU_HOME/plugin-root"
say "wrote ~/.zensu/plugin-root -> $PLUGIN_DIR"

step "Done."
cat <<EOF

Zensu for Codex is installed. Next steps:
  • Restart Codex (or open a new session) so it picks up skills, agents, and hooks.
  • Authenticate the MCP server:
      - OAuth:  codex mcp login zensu
      - CI/key: export ZENSU_API_KEY=zsk_... then re-run ./install.sh
  • Try it:   start Codex and run a skill, e.g.  \$zensu-help   or   \$zensu-bootstrap
  • Verify:   codex mcp list        (zensu should be listed)

Skills:  \$zensu-bootstrap · \$zensu-ghost-scan · \$zensu-implement · \$zensu-tdd ·
         \$zensu-plan-review · \$zensu-security-review · \$zensu-self-review ·
         \$zensu-reset-review-limit · \$zensu-pulse · \$zensu-help
Uninstall:  ./uninstall.sh
EOF
