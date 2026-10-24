#!/usr/bin/env bash
# Context retrieval is a shipped prompt contract; mapping tests exercise the CLI read boundary.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$ROOT/plugins/zensu"
node - "$PLUGIN" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
// Git Bash may pass C:/...; normalize before comparing with native separators.
const root = path.resolve(process.argv[2]);
const skill = fs.readFileSync(path.join(root, 'skills/implement/SKILL.md'), 'utf8');
const link = skill.match(/\[Load and hydrate feature context\]\(([^)]+)\)/);
assert(link, 'implementation must route to its packaged retrieval procedure');
const guidePath = path.resolve(root, 'skills/implement', link[1]);
assert(guidePath.startsWith(root + path.sep), 'procedure must ship inside the plugin');
const guide = fs.readFileSync(guidePath, 'utf8');
assert(skill.indexOf(link[0]) < skill.indexOf('### Step 2:'), 'load before planning');
for (const required of ['context-pack --help', 'context-pack <feature-ref> --json',
  'knowledge get <item-id> --json', 'knowledge search --query "<feature title + key terms>" --json',
  'truncated', 'realpath containment', 'contents read', 'excerpt/metadata only',
  'unresolved or unavailable', '401/403', '404', 'does not start TDD']) {
  assert(guide.includes(required), 'missing evidence behavior: ' + required);
}
assert(skill.includes('context evidence summary'), 'handoff must retain read/unresolved status');
console.log('context retrieval and hydration contract: PASS');
NODE
