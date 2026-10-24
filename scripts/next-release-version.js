'use strict';
// A failed publication can leave main ahead of the latest published tag.
// Never reuse or downgrade that already prepared manifest version.
const [kind, latest, current] = process.argv.slice(2);
function parse(value) {
  if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(value || '')) throw new Error('Invalid release version');
  const parts = value.split('.').map(Number);
  if (!parts.every(Number.isSafeInteger)) throw new Error('Invalid release version');
  return parts;
}
const a = parse(latest), b = parse(current);
const greater = a.findIndex((n, i) => n !== b[i]);
const parts = greater < 0 || a[greater] > b[greater] ? a : b;
const index = ['major', 'minor', 'patch'].indexOf(kind);
if (index < 0) throw new Error('Invalid release bump');
parts[index] += 1;
if (!Number.isSafeInteger(parts[index])) throw new Error('Invalid release version');
for (let i = index + 1; i < parts.length; i++) parts[i] = 0;
process.stdout.write(parts.join('.') + '\n');
