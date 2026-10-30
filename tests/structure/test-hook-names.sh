#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_JSON="$ROOT/plugins/zensu/hooks/hooks.json"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

RESULT="$(node - "$HOOKS_JSON" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const lines = [];
let config;
try {
  config = JSON.parse(fs.readFileSync(file, 'utf8'));
} catch (error) {
  process.stdout.write(`bad hooks.json parses as JSON: ${error.message}\n`);
  process.exit(0);
}
const events = Object.entries((config && config.hooks) || {});
lines.push(`${events.length > 0 ? 'ok' : 'bad'} hooks.json declares hook events`);
const unnamed = [];
const malformed = [];
const duplicates = [];
let total = 0;
for (const [event, groups] of events) {
  const seen = new Set();
  for (const [groupIndex, group] of (Array.isArray(groups) ? groups : []).entries()) {
    for (const [hookIndex, hook] of (Array.isArray(group.hooks) ? group.hooks : []).entries()) {
      total += 1;
      const where = `${event}:${groupIndex}:${hookIndex}`;
      const name = hook.statusMessage;
      if (typeof name !== 'string' || name.trim() === '') {
        unnamed.push(where);
        continue;
      }
      if (!/^Zensu [^\u0000-\u001f\u007f]{1,60}$/.test(name) || name !== name.trim()) malformed.push(`${where}=${JSON.stringify(name)}`);
      if (seen.has(name)) duplicates.push(`${where}=${JSON.stringify(name)}`);
      seen.add(name);
    }
  }
}
lines.push(`${total > 0 ? 'ok' : 'bad'} hooks.json declares hook entries (${total})`);
lines.push(`${unnamed.length === 0 ? 'ok' : 'bad'} every hook entry carries a statusMessage name${unnamed.length ? ` (missing: ${unnamed.join(', ')})` : ''}`);
lines.push(`${malformed.length === 0 ? 'ok' : 'bad'} every hook name is a single-line "Zensu …" label of at most 66 characters${malformed.length ? ` (${malformed.join(', ')})` : ''}`);
lines.push(`${duplicates.length === 0 ? 'ok' : 'bad'} hook names are unique within each event${duplicates.length ? ` (${duplicates.join(', ')})` : ''}`);
process.stdout.write(`${lines.join('\n')}\n`);
NODE
)"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    ok\ *) check "${line#ok }" PASS ;;
    *) check "${line#bad }" FAIL ;;
  esac
done <<< "$RESULT"

printf '%s\n' "----" "test-hook-names: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
