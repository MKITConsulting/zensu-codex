#!/usr/bin/env bash
# Zensu for Codex — uninstaller. Reverses install.sh. Leaves ~/.zensu/config.json
# (your settings) and any .zensu/ run artifacts in your projects untouched.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

say() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }

step "Removing zensu MCP server"
if command -v codex >/dev/null 2>&1; then
  codex mcp remove zensu >/dev/null 2>&1 && say "removed" || say "not registered"
else
  say "'codex' CLI not found — skipping"
fi

step "Removing skills"
for d in "$PLUGIN_DIR"/skills/*/; do
  [ -d "$d" ] || continue
  base="$(basename "$d")"
  case "$base" in zensu-*) name="$base" ;; *) name="zensu-$base" ;; esac
  if [ -d "$CODEX_HOME/skills/$name" ]; then rm -rf "${CODEX_HOME:?}/skills/$name"; say "$name"; fi
done

step "Removing subagents"
for f in "$PLUGIN_DIR"/agents/*.toml; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"
  if [ -f "$CODEX_HOME/agents/$n" ]; then rm -f "$CODEX_HOME/agents/$n"; say "$n"; fi
done

step "Removing hooks from $CODEX_HOME/hooks.json"
HOOKS_JSON="$CODEX_HOME/hooks.json"
if [ -f "$HOOKS_JSON" ] && command -v node >/dev/null 2>&1; then
  HOOKS_JSON="$HOOKS_JSON" PLUGIN_DIR="$PLUGIN_DIR" node -e '
    const fs = require("fs");
    const p = process.env.HOOKS_JSON, ours = process.env.PLUGIN_DIR + "/hooks/";
    let j; try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch (_) { process.exit(0); }
    if (!j || !j.hooks) process.exit(0);
    for (const ev of Object.keys(j.hooks)) {
      if (!Array.isArray(j.hooks[ev])) continue;
      j.hooks[ev] = j.hooks[ev].filter(g => !((g.hooks || []).some(h => typeof h.command === "string" && h.command.indexOf(ours) !== -1)));
      if (j.hooks[ev].length === 0) delete j.hooks[ev];
    }
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  '
  say "removed zensu hook entries"
else
  say "no hooks.json or no node — skipping"
fi

step "Removing the ZENSU block from $CODEX_HOME/AGENTS.md"
AGENTS_MD="$CODEX_HOME/AGENTS.md"
if [ -f "$AGENTS_MD" ] && command -v node >/dev/null 2>&1; then
  AGENTS_MD="$AGENTS_MD" node -e '
    const fs = require("fs");
    const p = process.env.AGENTS_MD;
    const b = "<!-- BEGIN ZENSU (managed by zensu-codex install.sh; do not edit between markers) -->";
    const e = "<!-- END ZENSU -->";
    let cur = ""; try { cur = fs.readFileSync(p, "utf8"); } catch (_) { process.exit(0); }
    const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    cur = cur.replace(new RegExp("\\n*" + esc(b) + "[\\s\\S]*?" + esc(e) + "\\n*", "g"), "\n");
    fs.writeFileSync(p, cur.replace(/\s*$/, "") + "\n");
  '
  say "stripped managed block"
fi

step "Done."
cat <<EOF

Zensu for Codex removed. Left in place (yours to keep or delete):
  • ~/.zensu/config.json        (your settings)
  • ~/.zensu/plugin-root        (run: rm ~/.zensu/plugin-root  to clear)
  • .zensu/ folders in projects (local run artifacts)
Restart Codex to drop the now-removed skills, agents, and hooks.
EOF
