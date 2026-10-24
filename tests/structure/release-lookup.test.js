'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const script = path.resolve(__dirname, '../../scripts/read-release-by-tag.sh');
for (const scenario of [
  { name: 'a complete empty list proves absence', status: 0, body: [[]], output: '' },
  { name: 'absence fails for a required release', status: 0, body: [[]], required: true, fails: true },
  { name: 'existing draft retains metadata', status: 0, body: [[{ id: 42, tag_name: 'v0.4.1', draft: true, body: 'Exact notes' }]], release: { id: 42, tag_name: 'v0.4.1', draft: true, body: 'Exact notes' } },
  { name: 'later pages retain published immutability metadata', status: 0, body: [[{ id: 40, tag_name: 'v0.4.0', draft: false }], [{ id: 43, tag_name: 'v0.4.1', draft: false, immutable: true }]], release: { id: 43, tag_name: 'v0.4.1', draft: false, immutable: true } },
  { name: 'authorization error is fatal', status: 1, body: { status: '403' }, fails: true },
  { name: '404 from the listing is fatal', status: 1, body: { status: '404' }, fails: true },
  { name: 'server error is fatal', status: 1, body: { status: '500' }, fails: true },
  { name: 'transport failure is fatal', status: 1, body: '', fails: true },
  { name: 'invalid success payload is fatal', status: 0, body: { status: '404' }, fails: true },
  { name: 'duplicate tags are fatal', status: 0, body: [[{ id: 1, tag_name: 'v0.4.1', draft: true }, { id: 2, tag_name: 'v0.4.1', draft: true }]], fails: true },
]) {
  test(scenario.name, t => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-release-lookup-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const args = path.join(dir, 'args');
    fs.writeFileSync(path.join(dir, 'gh'), '#!/bin/sh\nprintf "%s\\n" "$@" > "$LOOKUP_ARGS"\nprintf "%s" "$LOOKUP_BODY"\nexit "$LOOKUP_STATUS"\n', { mode: 0o755 });
    const body = typeof scenario.body === 'string' ? scenario.body : JSON.stringify(scenario.body);
    const result = spawnSync('bash', [script, 'MKITConsulting/zensu-codex', 'v0.4.1', ...(scenario.required ? ['--required'] : [])], { encoding: 'utf8', timeout: 5000,
      env: { ...process.env, PATH: dir + path.delimiter + process.env.PATH, LOOKUP_ARGS: args, LOOKUP_BODY: body, LOOKUP_STATUS: String(scenario.status) } });
    assert.equal(result.error, undefined);
    assert.equal(result.status, scenario.fails ? 1 : 0, result.stderr);
    assert.equal(result.stdout.trim(), scenario.fails ? '' : scenario.output ?? JSON.stringify(scenario.release));
    assert.deepEqual(fs.readFileSync(args, 'utf8').trim().split('\n'), ['api', '-H', 'X-GitHub-Api-Version: 2026-03-10', '--paginate', '--slurp', 'repos/MKITConsulting/zensu-codex/releases?per_page=100']);
  });
}

for (const [kind, latest, current, expected] of [
  ['patch', '0.3.2', '0.4.0', '0.4.1'],
  ['minor', '0.3.2', '0.4.0', '0.5.0'],
  ['major', '0.3.2', '0.4.0', '1.0.0'],
  ['patch', '0.4.0', '0.3.2', '0.4.1'],
  ['minor', '0.3.2', '0.3.2', '0.4.0'],
]) test(`next ${kind} from tag ${latest} and manifest ${current}`, () => {
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../../scripts/next-release-version.js'), kind, latest, current], { encoding: 'utf8', timeout: 5000 });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), expected);
});
