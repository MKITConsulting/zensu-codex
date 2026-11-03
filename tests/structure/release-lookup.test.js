'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const script = path.resolve(__dirname, '../../scripts/read-release-by-tag.sh');
const lateDraft = { id: 42, tag_name: 'v0.4.1', draft: true, body: 'Exact notes' };
const duplicates = [{ id: 1, tag_name: 'v0.4.1', draft: true }, { id: 2, tag_name: 'v0.4.1', draft: true }];
const pending = { ...lateDraft, assets: [] };
const settled = { ...lateDraft, assets: [{ name: 'zensu-codex-v0.4.1.zip', state: 'uploaded', digest: `sha256:${'a'.repeat(64)}` }] };
const mutable = { ...settled, draft: false, immutable: false };
const immutable = { ...mutable, immutable: true };
const workflow = fs.readFileSync(path.resolve(__dirname, '../../.github/workflows/release.yml'), 'utf8');
const awaited = Array.from(workflow.matchAll(/--required --until '([^']+)'/g), match => match[1]);
const [uploadSettled, publishedImmutable] = awaited;
test('the workflow awaits exactly two release states through the tested lookup', () => {
  assert.equal(awaited.length, 2);
});
for (const scenario of [
  { name: 'a complete empty list proves absence', status: 0, body: [[]], output: '' },
  { name: 'absence fails for a required release', status: 0, body: [[]], required: true, fails: true, calls: 6, sleeps: ['5', '5', '5', '5', '5'] },
  { name: 'a required draft the listing shows late is found', responses: [{ status: 0, body: [[]] }, { status: 0, body: [[]] }, { status: 0, body: [[lateDraft]] }], required: true, release: lateDraft, calls: 3, sleeps: ['5', '5'] },
  { name: 'a failed request while waiting is fatal without another read', responses: [{ status: 0, body: [[]] }, { status: 1, body: { status: '502' } }, { status: 0, body: [[lateDraft]] }], required: true, fails: true, calls: 2, sleeps: ['5'] },
  { name: 'an invalid payload while waiting is fatal without another read', responses: [{ status: 0, body: [[]] }, { status: 0, body: { status: '404' } }, { status: 0, body: [[lateDraft]] }], required: true, fails: true, calls: 2, sleeps: ['5'] },
  { name: 'existing draft retains metadata', status: 0, body: [[{ id: 42, tag_name: 'v0.4.1', draft: true, body: 'Exact notes' }]], release: { id: 42, tag_name: 'v0.4.1', draft: true, body: 'Exact notes' } },
  { name: 'later pages retain published immutability metadata', status: 0, body: [[{ id: 40, tag_name: 'v0.4.0', draft: false }], [{ id: 43, tag_name: 'v0.4.1', draft: false, immutable: true }]], release: { id: 43, tag_name: 'v0.4.1', draft: false, immutable: true } },
  { name: 'authorization error is fatal', status: 1, body: { status: '403' }, fails: true },
  { name: '404 from the listing is fatal', status: 1, body: { status: '404' }, fails: true },
  { name: 'server error is fatal', status: 1, body: { status: '500' }, fails: true },
  { name: 'transport failure is fatal', status: 1, body: '', fails: true },
  { name: 'invalid success payload is fatal', status: 0, body: { status: '404' }, fails: true },
  { name: 'duplicate tags are fatal', status: 0, body: [duplicates], fails: true },
  { name: 'a failed required lookup is fatal without waiting', status: 1, body: { status: '500' }, required: true, fails: true },
  { name: 'duplicate required tags are fatal without waiting', status: 0, body: [duplicates], required: true, fails: true },
  { name: 'the upload wait re-reads until the workflow sees the asset settled', responses: [{ status: 0, body: [[pending]] }, { status: 0, body: [[settled]] }], required: true, until: uploadSettled, release: settled, calls: 2, sleeps: ['5'] },
  { name: 'the upload wait rejects an asset that is listed but not yet uploaded', responses: [{ status: 0, body: [[{ ...settled, assets: [{ ...settled.assets[0], state: 'open' }] }]] }, { status: 0, body: [[settled]] }], required: true, until: uploadSettled, release: settled, calls: 2, sleeps: ['5'] },
  { name: 'the final wait re-reads until the workflow sees the release immutable', responses: [{ status: 0, body: [[mutable]] }, { status: 0, body: [[immutable]] }], required: true, until: publishedImmutable, release: immutable, calls: 2, sleeps: ['5'] },
  { name: 'an awaited state that never arrives fails after the bounded wait', status: 0, body: [[pending]], required: true, until: uploadSettled, fails: true, calls: 6, sleeps: ['5', '5', '5', '5', '5'] },
  { name: 'a failed request while awaiting a state is fatal without another read', responses: [{ status: 0, body: [[pending]] }, { status: 1, body: { status: '502' } }, { status: 0, body: [[settled]] }], required: true, until: uploadSettled, fails: true, calls: 2, sleeps: ['5'] },
  { name: 'an invalid awaited-state filter is rejected without another read', status: 0, body: [[settled]], required: true, until: '.assets[', exit: 2, calls: 1 },
  { name: 'an awaited state without --required is rejected before any read', status: 0, body: [[settled]], until: '.draft', exit: 2, calls: 0 },
]) {
  test(scenario.name, t => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-release-lookup-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const args = path.join(dir, 'args');
    const sleeps = path.join(dir, 'sleeps');
    const responses = scenario.responses ?? [{ status: scenario.status, body: scenario.body }];
    responses.forEach(({ status, body }, index) => {
      fs.writeFileSync(path.join(dir, `body.${index + 1}`), typeof body === 'string' ? body : JSON.stringify(body));
      fs.writeFileSync(path.join(dir, `status.${index + 1}`), String(status));
    });
    fs.writeFileSync(path.join(dir, 'calls'), '0');
    fs.writeFileSync(path.join(dir, 'gh'), `#!/bin/sh\nprintf "%s\\n" "$@" > "$LOOKUP_DIR/args"\nn=$(($(cat "$LOOKUP_DIR/calls") + 1))\nprintf "%s" "$n" > "$LOOKUP_DIR/calls"\n[ -f "$LOOKUP_DIR/body.$n" ] || n=${responses.length}\ncat "$LOOKUP_DIR/body.$n"\nexit "$(cat "$LOOKUP_DIR/status.$n")"\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(dir, 'sleep'), '#!/bin/sh\nprintf "%s\\n" "$@" >> "$LOOKUP_DIR/sleeps"\n', { mode: 0o755 });
    const result = spawnSync('bash', [script, 'MKITConsulting/zensu-codex', 'v0.4.1', ...(scenario.required ? ['--required'] : []), ...(scenario.until ? ['--until', scenario.until] : [])], { encoding: 'utf8', timeout: 30000,
      env: { ...process.env, PATH: dir + path.delimiter + process.env.PATH, LOOKUP_DIR: dir } });
    assert.equal(result.error, undefined);
    assert.equal(result.status, scenario.exit ?? (scenario.fails ? 1 : 0), result.stderr);
    assert.equal(result.stdout.trim(), scenario.fails || scenario.exit ? '' : scenario.output ?? JSON.stringify(scenario.release));
    if ((scenario.calls ?? 1) > 0) assert.deepEqual(fs.readFileSync(args, 'utf8').trim().split('\n'), ['api', '-H', 'X-GitHub-Api-Version: 2026-03-10', '--paginate', '--slurp', 'repos/MKITConsulting/zensu-codex/releases?per_page=100']);
    assert.equal(fs.readFileSync(path.join(dir, 'calls'), 'utf8'), String(scenario.calls ?? 1));
    assert.deepEqual(fs.existsSync(sleeps) ? fs.readFileSync(sleeps, 'utf8').trim().split('\n') : [], scenario.sleeps ?? []);
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
