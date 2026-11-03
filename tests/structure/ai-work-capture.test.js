'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const plugin = fs.existsSync(path.join(root, 'plugins/zensu')) ? path.join(root, 'plugins/zensu') : root;
const capture = require(path.join(plugin, 'hooks/lib/ai-work-capture-v1.js'));
const session = `scv1_${'b'.repeat(64)}`;
const actor = 'ba2e3519-3a56-4efa-815d-b411c882c769';
const other = '97e89c7f-3ce7-4593-9da3-7dfcab18387a';
const org = 'f72c484b-204d-4157-9326-93e02e1e02e1';

test('restored working copies require explicit resumption before any reporting', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file));
  receipt.pending = { id: org, expectedVersion: 1, artifactRef: 'commit:' + 'c'.repeat(40), criteriaVersion: options.criteria };
  receipt.futureField = { preserved: true };
  const raw = Buffer.from(JSON.stringify(receipt, null, 2) + '\n');
  fs.writeFileSync(file, raw);
  const digest = require(path.join(path.dirname(path.join(plugin, 'hooks/lib/ai-work-capture-v1.js')), 'ai-work-recovery-v1.js')).archive(file);
  const archived = path.join(path.dirname(file), 'recovery', options.session, digest + '.json');
  fs.writeFileSync(file, JSON.stringify({ ...receipt, capturePaused: true }) + '\n');
  const restored = fs.readFileSync(file);
  state.calls.length = 0;
  assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
  assert.equal(state.calls.length, 0);
  assert.deepEqual(fs.readFileSync(file), restored);
  assert.equal(capture.begin({ ...options, feature: undefined }).status, 'skipped_missing_feature');
  assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
  assert.equal(state.submits.length, 0);
  capture.begin(options);
  assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
  assert.deepEqual(state.submits[0], receipt.pending);
  assert.deepEqual(fs.readFileSync(archived), raw);
});

test('recovery rejects archive symlinks without following them', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file)); delete receipt.scope;
  const raw = Buffer.from(JSON.stringify(receipt));
  fs.writeFileSync(file, raw);
  const digest = require('node:crypto').createHash('sha256').update(raw).digest('hex');
  const parent = path.join(path.dirname(file), 'recovery');
  const directory = path.join(parent, options.session);
  const target = path.join(directory, digest + '.json');
  const outside = path.join(options.workspace, 'outside');
  fs.mkdirSync(outside);
  for (const link of [parent, directory, target]) {
    fs.symlinkSync(outside, link, process.platform === 'win32' ? 'junction' : 'dir');
    assert.throws(() => capture.begin({ ...options, task: 'next' }), /[Uu]nsafe/);
    assert.deepEqual(fs.readFileSync(file), raw);
    assert.deepEqual(fs.readdirSync(outside), []);
    fs.unlinkSync(link);
    if (link !== target) fs.mkdirSync(link);
  }
  assert.equal(state.submits.length, 0);
});

test('an interruption after archiving preserves both the old slot and its retryable archive', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file)); delete receipt.scope.taskScope;
  const raw = Buffer.from(JSON.stringify(receipt));
  fs.writeFileSync(file, raw);
  const rename = fs.renameSync;
  fs.renameSync = () => { throw new Error('simulated interrupted replacement'); };
  try { assert.throws(() => capture.begin({ ...options, task: 'next' }), /interrupted replacement/); }
  finally { fs.renameSync = rename; }
  assert.deepEqual(fs.readFileSync(file), raw);
  const dir = path.join(path.dirname(file), 'recovery', options.session);
  assert.equal(fs.readdirSync(dir).length, 1);
  assert.deepEqual(fs.readFileSync(path.join(dir, fs.readdirSync(dir)[0])), raw);
  state.unit = null;
  assert.equal(capture.begin({ ...options, task: 'next' }).status, 'recording');
  assert.equal(state.submits.length, 0);
});


test('legacy pending receipts are preserved before a new confirmed goal replaces them', (t) => {
  const { options, state, file } = fixture(t);
  for (const kind of ['product', 'feature']) {
    if (fs.existsSync(file)) fs.unlinkSync(file);
    state.unit = null;
    capture.begin(options);
    const receipt = JSON.parse(fs.readFileSync(file));
    if (kind === 'product') delete receipt.scope; else delete receipt.scope.taskScope;
    receipt.pending = { id: org, expectedVersion: 1, artifactRef: 'commit:' + 'c'.repeat(40), criteriaVersion: options.criteria };
    receipt.futureMetadata = { untouched: true };
    const raw = Buffer.from(JSON.stringify(receipt, null, 2) + '\n');
    fs.writeFileSync(file, raw);
    const digest = require('node:crypto').createHash('sha256').update(raw).digest('hex');
    const archived = path.join(path.dirname(file), 'recovery', options.session, digest + '.json');
    assert.throws(() => capture.checkpoint(options), /Legacy capture/);
    assert.equal(capture.begin({ ...options, task: 'new-' + kind, feature: undefined }).status, 'skipped_missing_feature');
    assert.deepEqual(fs.readFileSync(file), raw, 'incomplete goal must not mutate legacy receipt');
    assert.equal(fs.existsSync(archived), false);
    state.unbound = true;
    assert.equal(capture.begin({ ...options, task: 'new-' + kind }).status, 'skipped_unassigned');
    assert.deepEqual(fs.readFileSync(file), raw);
    state.unbound = false;
    state.unit = null;
    const result = capture.begin({ ...options, task: 'new-' + kind });
    assert.equal(result.status, 'recording');
    assert.equal(result.recoveredReceipt, digest);
    assert.deepEqual(fs.readFileSync(archived), raw);
    assert.notEqual(JSON.parse(fs.readFileSync(file)).id, receipt.id);
    assert.equal(JSON.parse(fs.readFileSync(file)).pending, undefined);
    assert.equal(state.submits.length, 0);
    // POSIX permission bits are not represented by Windows ACLs.
    if (process.platform !== 'win32') assert.equal(fs.statSync(archived).mode & 0o077, 0);
  }
});

test('recovery never replaces an archive or drops a pending scoped submission', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file));
  receipt.pending = { id: org, expectedVersion: 1, artifactRef: 'commit:' + 'c'.repeat(40), criteriaVersion: options.criteria };
  fs.writeFileSync(file, JSON.stringify(receipt));
  assert.throws(() => capture.begin({ ...options, task: 'next' }), /pending/);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).pending, receipt.pending);
  delete receipt.scope;
  const raw = Buffer.from(JSON.stringify(receipt));
  fs.writeFileSync(file, raw);
  const digest = require('node:crypto').createHash('sha256').update(raw).digest('hex');
  const dir = path.join(path.dirname(file), 'recovery', options.session);
  fs.mkdirSync(dir, { recursive: true });
  const target = path.join(dir, digest + '.json');
  fs.writeFileSync(target, 'different bytes');
  assert.throws(() => capture.begin({ ...options, task: 'next' }), /archive/i);
  assert.deepEqual(fs.readFileSync(file), raw);
  assert.equal(fs.readFileSync(target, 'utf8'), 'different bytes');
  fs.writeFileSync(target, raw);
  state.unit = null;
  assert.equal(capture.begin({ ...options, task: 'next' }).status, 'recording', 'interrupted archive creation is retryable');
  assert.deepEqual(fs.readFileSync(target), raw);
  assert.equal(state.submits.length, 0);
});

test('recovery refuses unsafe archive paths and preserves active bytes on write failure', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file)); delete receipt.scope;
  const raw = Buffer.from(JSON.stringify(receipt));
  fs.writeFileSync(file, raw);
  const recovery = path.join(path.dirname(file), 'recovery');
  fs.writeFileSync(recovery, 'not a directory');
  assert.throws(() => capture.begin({ ...options, task: 'next' }));
  assert.deepEqual(fs.readFileSync(file), raw);
  fs.unlinkSync(recovery);
  fs.mkdirSync(recovery);
  const directory = path.join(recovery, options.session);
  fs.writeFileSync(directory, 'not a directory');
  assert.throws(() => capture.begin({ ...options, task: 'next' }));
  assert.deepEqual(fs.readFileSync(file), raw);
  fs.unlinkSync(directory);
  const write = fs.writeFileSync;
  fs.writeFileSync = (target, ...args) => {
    if (String(target).includes('.receipt-')) throw new Error('simulated interrupted write');
    return write(target, ...args);
  };
  try { assert.throws(() => capture.begin({ ...options, task: 'next' }), /interrupted write/); }
  finally { fs.writeFileSync = write; }
  assert.deepEqual(fs.readFileSync(file), raw);
  assert.equal(state.submits.length, 0);
});


test('goal scope must be explicit, immutable and confirmed by the server', (t) => {
  const { options, state, file } = fixture(t);
  assert.equal(capture.begin({ ...options, feature: undefined }).status, 'skipped_missing_feature');
  assert.equal(state.unit, null); assert.equal(fs.existsSync(file), false);
  options['feature-revision'] = org;
  capture.begin(options);
  assert.equal(state.unit.featureId, actor); assert.equal(state.unit.featureRevisionId, org);
  assert.equal(state.unit.taskScope, 'feature');
  assert.throws(() => capture.begin({ ...options, feature: other }), /scope/);
  assert.throws(() => capture.begin({ ...options, 'feature-revision': other }), /scope/);
  capture.begin(options); // Explicitly resume after rejected changes.
  state.unit.featureId = other; state.head = 'e'.repeat(40);
  assert.throws(() => capture.checkpoint(options), /scope/);
  assert.equal(state.submits.length, 0);
  state.unit.featureId = actor;
  const receipt = JSON.parse(fs.readFileSync(file)); delete receipt.scope.taskScope;
  fs.writeFileSync(file, JSON.stringify(receipt));
  assert.throws(() => capture.checkpoint(options), /Legacy capture/);
  assert.equal(state.submits.length, 0);
});
test('invalid goal metadata pauses the old goal before any validation can fail', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options);
  for (const invalid of [
    { task: '' }, { title: '' }, { criteria: '' },
    { 'run-kind': 'invalid' }, { 'cross-product-reason': ' ' },
  ]) {
    assert.throws(() => capture.begin({ ...options, task: 'rejected-goal', ...invalid }));
    state.head = 'e'.repeat(40);
    const calls = state.calls.length;
    assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
    assert.equal(state.calls.length, calls);
    assert.equal(state.submits.length, 0);
    capture.begin(options);
  }
  assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
});
test('product maintenance is a per-goal exception and is never inherited', (t) => {
  const { options, state } = fixture(t);
  const maintenance = { ...options, feature: undefined, 'maintenance-reason': 'Upgrade product build tooling' };
  capture.begin(maintenance);
  assert.equal(state.unit.maintenanceReason, maintenance['maintenance-reason']);
  assert.equal(state.unit.taskScope, 'maintenance'); assert.equal(state.unit.featureId, null);
  assert.throws(() => capture.begin({ ...maintenance, 'maintenance-reason': 'Different objective' }), /scope/);
  assert.equal(capture.begin({ ...options, feature: undefined }).status, 'skipped_missing_feature');
  assert.equal(capture.begin({ ...options, feature: undefined, task: 'next-goal' }).status, 'skipped_missing_feature');
  state.head = 'f'.repeat(40);
  const calls = state.calls.length;
  assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
  assert.equal(state.calls.length, calls);
  assert.equal(state.submits.length, 0);
  capture.begin(maintenance);
  assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
});
test('goal scope validates combinations, context identity and transport fields', () => {
  const goal = require(path.join(plugin, 'hooks/lib/ai-work-goal-scope-v1.js'));
  for (const options of [
    { feature: '' }, { feature: '00000000-0000-0000-0000-000000000000' },
    { 'feature-revision': org }, { feature: actor, 'feature-revision': 'bad' },
    { 'maintenance-reason': ' ' }, { 'maintenance-reason': 'x'.repeat(501) },
    { 'maintenance-reason': 'line\nline' }, { 'cross-product-reason': ' ' },
    { feature: actor, 'maintenance-reason': 'Build' },
    { feature: actor, 'cross-product-reason': 'Shared' },
    { 'maintenance-reason': 'Build', 'cross-product-reason': 'Shared' },
  ]) assert.throws(() => goal.fromOptions(options));
  assert.equal(goal.fromOptions({}), null);
  assert.deepEqual(goal.contextArgs(null), ['context']);
  assert.throws(() => goal.confirm({}, null), /Legacy/);
  const feature = goal.fromOptions({ feature: actor });
  assert.throws(() => goal.confirm({ featureId: other }, feature), /not confirmed/);
  assert.equal(goal.confirm({ featureId: actor }, feature), feature);
  assert.throws(() => goal.startArgs({}), /Missing/);
  assert.deepEqual(goal.startArgs(feature), ['--feature', actor]);
  const cross = goal.fromOptions({ 'cross-product-reason': 'Shared tooling' });
  assert.deepEqual(goal.contextArgs(cross), ['context', '--cross-product']);
  assert.deepEqual(goal.startArgs(cross), []);
});


test('preflight asks for missing product or feature before creating any capture', (t) => {
  const { options, state, file } = fixture(t);
  const unscoped = { ...options, feature: undefined };
  state.unbound = true;
  assert.equal(capture.preflight(unscoped).status, 'product_confirmation_required');
  state.unbound = false;
  const bound = capture.preflight(unscoped);
  assert.equal(bound.status, 'feature_confirmation_required');
  assert.equal(bound.productId, other);
  assert.equal(capture.preflight(options).status, 'ready');
  assert.equal(fs.existsSync(file), false);
  assert.ok(state.calls.every(args => args[1] === 'context'));
});
test('preflight verifies maintenance and explicit cross-product scope without inventing it', (t) => {
  const { options, state, file } = fixture(t);
  const maintenance = capture.preflight({ ...options, feature: undefined, 'maintenance-reason': 'Release maintenance' });
  assert.equal(maintenance.taskScope, 'maintenance');
  assert.equal(maintenance.productId, other);
  const cross = capture.preflight({ ...options, feature: undefined, 'cross-product-reason': 'Shared CLI integration' });
  assert.equal(cross.taskScope, 'cross_product');
  assert.equal(cross.productId, null);
  assert.equal(cross.crossProductReason, 'Shared CLI integration');
  assert.throws(() => capture.preflight({ ...options, 'maintenance-reason': 'invalid mixed scope' }), /never more than one/);
  assert.equal(fs.existsSync(file), false);
  assert.equal(state.submits.length, 0);
});
test('an outdated CLI is diagnosed before any remote declaration', (t) => {
  const { options, state, file } = fixture(t);
  state.missingFlag = 'review-file';
  const result = capture.preflight(options);
  assert.equal(result.status, 'cli_incompatible');
  assert.deepEqual(result.missingCapabilities, ['submit --review-file']);
  assert.match(result.guidance, /zensu update/);
  assert.match(result.guidance, /original installer/);
  assert.equal(capture.begin(options).status, 'cli_incompatible');
  assert.equal(fs.existsSync(file), false);
  assert.equal(state.calls.length, 0);
});
test('CLI downgrade never changes or transmits an existing frozen pending report', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const receipt = JSON.parse(fs.readFileSync(file));
  receipt.pending = { id: org, expectedVersion: 1, artifactRef: 'commit:' + 'c'.repeat(40), criteriaVersion: options.criteria };
  const raw = JSON.stringify(receipt, null, 2) + '\n';
  fs.writeFileSync(file, raw);
  state.missingFlag = 'feature';
  state.calls.length = 0;
  assert.equal(capture.checkpoint(options).status, 'cli_incompatible');
  assert.equal(fs.readFileSync(file, 'utf8'), raw);
  assert.equal(state.calls.length, 0);
  assert.equal(state.submits.length, 0);
});
test('explicit no-report pause preserves opaque receipts and suppresses all CLI calls', (t) => {
  const { options, state, file } = fixture(t);
  assert.equal(capture.pause(options).status, 'capture_disabled');
  assert.equal(capture.preflight(options).status, 'capture_disabled');
  assert.equal(capture.checkpoint(options).status, 'capture_disabled');
  assert.equal(state.probes.length, 0);
  capture.begin(options);
  const raw = fs.readFileSync(file);
  state.calls.length = 0; state.probes.length = 0;
  capture.pause(options); capture.pause(options);
  assert.deepEqual(fs.readFileSync(file), raw);
  assert.equal(capture.preflight(options).status, 'capture_disabled');
  assert.equal(capture.checkpoint(options).status, 'capture_disabled');
  assert.equal(state.calls.length, 0);
  assert.equal(state.probes.length, 0);
  state.missingFlag = 'review-file';
  assert.equal(capture.begin(options).status, 'cli_incompatible');
  assert.equal(capture.checkpoint(options).status, 'capture_disabled');
  state.missingFlag = undefined;
  capture.begin(options);
  assert.equal(fs.existsSync(file + '.paused'), false);
  assert.equal(capture.checkpoint(options).status, 'no_new_commit');
});
test('invalid local pause markers fail closed without touching the receipt', (t) => {
  const { options, file } = fixture(t);
  capture.begin(options);
  const raw = fs.readFileSync(file);
  fs.writeFileSync(file + '.paused', 'damaged');
  assert.throws(() => capture.pause(options), /Unsafe capture pause marker/);
  assert.throws(() => capture.checkpoint(options), /Unsafe capture pause marker/);
  fs.unlinkSync(file + '.paused');
  fs.symlinkSync(file, file + '.paused');
  assert.throws(() => capture.begin(options), /Unsafe capture pause marker/);
  assert.throws(() => capture.pause(options), /Unsafe capture pause marker/);
  assert.deepEqual(fs.readFileSync(file), raw);
});
test('preflight exposes neither CLI stderr nor scope failure details', (t) => {
  const { options, state, file } = fixture(t);
  state.cliUnavailable = true;
  const unavailable = capture.preflight(options);
  assert.equal(unavailable.status, 'cli_unavailable');
  assert.ok(!JSON.stringify(unavailable).includes('private-token'));
  state.cliUnavailable = false; state.helpUnavailable = true;
  const incompatible = capture.preflight(options);
  assert.equal(incompatible.status, 'cli_incompatible');
  assert.deepEqual(incompatible.missingCapabilities, ['ai-work bind', 'ai-work context', 'ai-work start', 'ai-work get', 'ai-work submit']);
  assert.equal(state.calls.length, 0);
  assert.ok(!JSON.stringify(incompatible).includes('private-token'));
  state.helpUnavailable = false; state.missingFlag = 'json';
  assert.deepEqual(capture.preflight(options).missingCapabilities, ['get --json']);
  assert.equal(capture.begin(options).status, 'cli_incompatible');
  assert.equal(state.calls.length, 0);
  state.missingFlag = undefined; state.contextError = true;
  const denied = capture.preflight(options);
  assert.equal(denied.status, 'scope_unavailable');
  assert.ok(!JSON.stringify(denied).includes('private-token'));
  assert.equal(fs.existsSync(file), false);
});
test('capability checks are bounded and cannot accept flags mentioned only in prose', (t) => {
  const { options, state } = fixture(t);
  const compatibility = require(path.join(plugin, 'hooks/lib/ai-work-preflight-v1.js'));
  assert.equal(compatibility.check(options.workspace, 0).status, 'cli_unavailable');
  assert.equal(state.probes.length, 0);
  state.helpProse = true;
  const result = capture.preflight(options);
  assert.equal(result.status, 'cli_incompatible');
  assert.ok(result.missingCapabilities.includes('submit --review-file'));
  assert.ok(state.probes.every(p => p.timeout > 0 && p.timeout <= 2000));
});
function fixture(t) {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-work-capture-'));
  fs.mkdirSync(path.join(workspace, '.git'));
  const options = { feature: actor, source: 'codex', sourceVersion: '1.2.3', workspace, session, task: 'goal-1', title: 'Implement agreed goal', criteria: 'spec-v1' };
  const state = { apiUrl: 'https://api.example.test', actor, head: 'a'.repeat(40), dirty: '', unit: null, submits: [], calls: [], failResponse: false };
  const previous = cp.spawnSync;
  state.probes = [];
  cp.spawnSync = (command, args, opts) => {
    if (command === 'zensu' && (args[0] === '--version' || args.includes('--help'))) {
      assert.equal(opts.shell, undefined);
      assert.equal(opts.env.ZENSU_NO_UPDATE_CHECK, '1');
      state.probes.push({ args, timeout: opts.timeout });
      if (state.cliUnavailable) return { error: new Error('private-token'), status: 1, stderr: 'private-token' };
      if (args[0] === '--version') return { status: 0, stdout: 'zensu 0.18.0 (commit fixture)' };
      if (state.helpUnavailable) return { status: 1, stderr: 'private-token' };
      const flags = {
        bind: ['product', 'confirm'], context: ['feature', 'feature-revision', 'cross-product'],
        start: ['id', 'title', 'product', 'feature', 'feature-revision', 'maintenance-reason', 'cross-product-reason', 'source', 'source-version', 'run-kind'],
        get: ['json'],
        submit: ['event-id', 'expected-version', 'artifact', 'criteria-version', 'review-file'],
      };
      assert.ok(flags[args[1]], 'only read-only help commands may be probed');
      return { status: 0, stdout: state.helpProse ? 'Examples mention --review-file and --feature' : flags[args[1]].filter(f => f !== state.missingFlag).map(f => '      --' + f + ' string    description').join('\n') };
    }
    if (command === 'zensu' && args[1] === 'context' && state.contextError) return { status: 1, stderr: 'private-token' };
    assert.equal(opts.shell, undefined, 'metadata must never become a shell command');
    let value;
    if (command === 'git') {
      value = args.includes('--absolute-git-dir') ? path.join(workspace, '.git') : args[0] === 'status' ? state.dirty : state.head;
    } else {
      assert.equal(command, 'zensu'); assert.equal(args[0], 'ai-work');
      state.calls.push(args);
      const flag = (key) => args[args.indexOf(key) + 1];
      switch (args[1]) {
        case 'context': value = { featureId: args.includes('--feature') ? flag('--feature') : null, featureRevisionId: args.includes('--feature-revision') ? flag('--feature-revision') : null, apiUrl: state.apiUrl, ready: !state.unbound, workScope: args.includes('--cross-product') ? 'cross_product' : state.unbound ? 'unassigned' : 'product', productId: args.includes('--cross-product') ? undefined : (state.product || other), reportingUserId: state.actor, organizationId: org }; break;
        case 'start':
          if (state.unit && state.unit.actor !== state.actor) return { status: 1, stderr: 'secret server body' };
          state.unit ??= { taskScope: args.includes('--feature') ? 'feature' : args.includes('--maintenance-reason') ? 'maintenance' : 'cross_product', featureId: args.includes('--feature') ? flag('--feature') : null, featureRevisionId: args.includes('--feature-revision') ? flag('--feature-revision') : null, maintenanceReason: args.includes('--maintenance-reason') ? flag('--maintenance-reason') : '', id: flag('--id'), workScope: args.includes('--product') ? 'product' : 'cross_product', productId: args.includes('--product') ? flag('--product') : null, crossProductReason: args.includes('--cross-product-reason') ? flag('--cross-product-reason') : '', actor: state.actor, source: flag('--source'), sourceVersion: flag('--source-version'), runKind: flag('--run-kind'), version: 1, result: null, decision: null };
          value = { id: state.unit.id }; break;
        case 'get':
          value = { ...state.unit, reportingUserId: state.actor, organizationId: org,
            reviewUrl: `https://app.example.test/ai-work?unit=${state.unit.id}${state.unit.result ? `&result=${state.unit.result.id}` : ''}` };
          if (state.forged) value.id = other;
          break;
        case 'submit': {
          const event = { id: flag('--event-id'), artifactRef: flag('--artifact'), criteriaVersion: flag('--criteria-version'), expectedVersion: Number(flag('--expected-version')) };
          if (args.includes('--review-file')) {
            event.reviewDetails = JSON.parse(fs.readFileSync(flag('--review-file'), 'utf8'));
            assert.equal(fs.statSync(flag('--review-file')).mode & 0o777, 0o600);
          }
          state.submits.push(event);
          if (!state.unit.result || state.unit.result.id !== event.id) {
            if (event.expectedVersion !== state.unit.version) return { status: 1 };
            state.unit.result = state.dropReview ? { ...event, reviewDetails: undefined } : event; state.unit.version++; state.unit.decision = null;
          }
          if (state.failResponse) { state.failResponse = false; return { status: 1 }; }
          value = { id: event.id }; break;
        }
        default: assert.fail(`unexpected command: ${args[1]}`);
      }
      value = JSON.stringify(value);
    }
    return { status: 0, stdout: value };
  };
  t.after(() => { cp.spawnSync = previous; fs.rmSync(workspace, { recursive: true, force: true }); });
  return { options, state, file: path.join(workspace, '.git/zensu-ai-work-v1', `${session}.json`) };
}

test('captures one goal and one exact version, with no acceptance command', (t) => {
  const { options, state } = fixture(t);
  assert.equal(capture.begin(options).status, 'recording');
  capture.begin(options);
  state.head = 'c'.repeat(40);
  assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
  assert.equal(capture.checkpoint(options).status, 'already_submitted');
  assert.equal(state.submits.length, 1); assert.equal(state.unit.version, 2);
  assert.equal(state.unit.result.artifactRef, `commit:${state.head}`);
  assert.equal(state.unit.result.criteriaVersion, options.criteria);
  assert.equal(state.unit.decision, null);
  assert.ok(state.calls.every((args) => !args.includes('accept') && !args.includes('user-id')));
});
test('lost response retries the exact durable event even after human acceptance', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); state.failResponse = true;
  assert.throws(() => capture.checkpoint(options), /incomplete/);
  assert.ok(JSON.parse(fs.readFileSync(file)).pending);
  state.unit.decision = { kind: 'accepted' }; state.unit.version++;
  capture.checkpoint(options);
  assert.deepEqual(state.submits[0], state.submits[1]);
  assert.equal(state.unit.version, 3); assert.equal(state.unit.decision.kind, 'accepted');
  assert.equal(JSON.parse(fs.readFileSync(file)).pending, undefined);
});
test('changed login or host cannot attribute an existing task to someone else', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); state.actor = other;
  assert.throws(() => capture.checkpoint(options), /incomplete/);
  state.actor = actor; state.apiUrl = 'https://other.example.test';
  assert.throws(() => capture.checkpoint(options), /host changed/);
  assert.equal(state.submits.length, 0);
});
test('uncommitted work and unchanged starting head are not submitted', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); assert.equal(capture.checkpoint(options).status, 'no_new_commit');
  state.head = 'd'.repeat(40); state.dirty = ' M work.go';
  assert.equal(capture.checkpoint(options).status, 'uncommitted_work');
  assert.equal(state.submits.length, 0);
});
test('new commits do not inherit acceptance and unchanged reports do not revoke it', (t) => {
  const { options, state } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40); capture.checkpoint(options);
  state.unit.decision = { kind: 'accepted' }; state.unit.version++;
  capture.checkpoint(options); assert.equal(state.unit.decision.kind, 'accepted');
  state.head = 'd'.repeat(40); capture.checkpoint(options);
  assert.equal(state.unit.decision, null); assert.equal(state.submits.length, 2);
});
test('changed criteria, invalid identities and concurrent receipts fail closed', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  assert.throws(() => capture.begin({ ...options, criteria: 'v2' }), /new task key/);
  assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
  capture.begin(options);
  state.forged = true; assert.throws(() => capture.checkpoint(options), /identity mismatch/);
  state.forged = false; fs.writeFileSync(`${file}.lock`, '');
  assert.throws(() => capture.checkpoint(options), /already running/);
  assert.equal(state.submits.length, 0);
});
test('no begun goal produces no CLI calls or receipt directory', (t) => {
  const { options, state, file } = fixture(t);
  assert.equal(capture.checkpoint(options).status, 'not_started');
  assert.equal(state.calls.length, 0); assert.equal(fs.existsSync(path.dirname(file)), false);
});
test('the hook and primer are registered, with no session-start capture writes', () => {
  const hooks = JSON.parse(fs.readFileSync(path.join(plugin, 'hooks/hooks.json'))).hooks;
  assert.ok(JSON.stringify(hooks.Stop).includes('stop-ai-work-capture.sh'));
  assert.ok(JSON.stringify(hooks.SessionStart).includes('session-start-ai-work.sh'));
  const primer = fs.readFileSync(path.join(plugin, 'hooks/session-start-ai-work.sh'), 'utf8');
  assert.ok(primer.includes('capture-v1.js" primer')); assert.ok(!primer.includes('capture-v1.js begin'));
  const payload = { session_id: 'capture-test-session', cwd: '/tmp' };
  const call = (action, input) => cp.spawnSync(process.execPath, [path.join(plugin, 'hooks/lib/ai-work-capture-v1.js'), action], { input: typeof input === 'string' ? input : JSON.stringify(input), encoding: 'utf8' });
  const context = JSON.parse(call('primer', payload).stdout).hookSpecificOutput;
  assert.equal(context.hookEventName, 'SessionStart');
  assert.match(context.additionalContext, /captureSessionKey=scv1_[0-9a-f]{64}/);
  assert.match(context.additionalContext, /direct implementation/);
  assert.match(context.additionalContext, /preflight/);
  assert.match(context.additionalContext, /use pause instead/);
  assert.equal(call('primer', { ...payload, agent_type: 'reviewer' }).stdout, '');
  assert.equal(call('hook', { ...payload, agent_id: 'child' }).stdout, '');
  const malformed = call('hook', 'not-json-sensitive-input');
  assert.equal(malformed.status, 0); assert.match(malformed.stdout, /capture incomplete/);
  assert.ok(!malformed.stdout.includes('sensitive-input'));
  const oversized = call('hook', 'x'.repeat(1024 * 1024 + 1));
  assert.equal(oversized.status, 0); assert.match(oversized.stdout, /capture incomplete/);
});

test('freezes the declared origin and test purpose across retries and checkpoints', (t) => {
  const { options, state, file } = fixture(t);
  options['run-kind'] = 'test';
  capture.begin(options);
  const metadata = JSON.parse(fs.readFileSync(file)).metadata;
  assert.equal(metadata.runKind, 'test');
  assert.equal(metadata.source, options.source);
  assert.ok(metadata.sourceVersion);
  assert.throws(() => capture.begin({ ...options, 'run-kind': 'work' }), /run purpose/);
  assert.throws(() => capture.begin({ ...options, 'run-kind': 'demo' }), /Run kind/);
  // A plugin upgrade must not rewrite the origin of an already declared task.
  capture.begin({ ...options, sourceVersion: '9.9.9' });
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).metadata, metadata);
  state.unit.runKind = 'work'; // a human correction is allowed without changing the original receipt
  state.head = 'd'.repeat(40); capture.checkpoint(options);
  const declarations = state.calls.filter(a => a[1] === 'start');
  assert.ok(declarations.every(a => a[a.indexOf('--run-kind')+1] === 'test'));
  state.unit.source = 'wrong';
  assert.throws(() => capture.checkpoint(options), /metadata was not confirmed/);
});
test('legacy receipts are replayed without invented source or purpose', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options);
  const s = JSON.parse(fs.readFileSync(file)); delete s.metadata;
  fs.writeFileSync(file, JSON.stringify(s));
  state.unit.source = 'unknown'; state.unit.runKind = 'unknown';
  capture.begin(options);
  assert.ok(state.calls.filter(a => a[1] === 'start').at(-1).includes('--legacy-metadata'));
  assert.equal(JSON.parse(fs.readFileSync(file)).metadata, undefined);
  assert.throws(() => capture.begin({ ...options, 'run-kind': 'test' }), /run purpose/);
});

function reviewFixture(options) {
  const file = path.join(options.workspace, 'review.json');
  const details = { artifactUrl: 'https://git.example.test/team/repo/commit/' + 'c'.repeat(40), summary: 'Implemented review dialog', acceptanceCriteria: [{ text: 'Shows evidence', status: 'met' }], evidence: [{ label: 'Tests', description: '24 passed' }], limitations: 'Human review pending' };
  fs.writeFileSync(file, JSON.stringify(details));
  return { file, details, options: { ...options, 'review-file': file } };
}
test('captures explicit review details and freezes exact retries after a lost response', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options); state.failResponse = true;
  assert.throws(() => capture.checkpoint(review.options), /incomplete/);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).pending.reviewDetails, review.details);
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, artifactUrl: 'https://git.example.test/team/other/commit/' + 'c'.repeat(40) }));
  assert.throws(() => capture.checkpoint(review.options), /different review details/);
  fs.unlinkSync(review.file);
  capture.checkpoint(options);
  assert.deepEqual(state.submits[0], state.submits[1]);
  assert.deepEqual(state.unit.result.reviewDetails, review.details);
  assert.equal(capture.checkpoint(options).status, 'already_submitted');
  assert.ok(!fs.readdirSync(path.dirname(file)).some(f => f.endsWith('.review.json')));
});
test('a changed report creates a new result even at the same commit; acceptance is not inherited', (t) => {
  const { options, state } = fixture(t); capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options); capture.checkpoint(review.options);
  assert.equal(capture.checkpoint(review.options).status, 'already_submitted');
  state.unit.decision = { kind: 'accepted' };
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, artifactUrl: 'https://git.example.test/team/moved/commit/' + 'c'.repeat(40) }));
  capture.checkpoint(review.options);
  assert.equal(state.submits.length, 2); assert.notEqual(state.submits[0].id, state.submits[1].id);
  assert.equal(state.unit.decision, null);
});
test('malformed and unrelated review content cannot become a pending report', (t) => {
  const { options, state, file } = fixture(t); capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options);
  for (const bad of [null, { ...review.details, transcript: 'private' }, { ...review.details, summary: '' }, { ...review.details, evidence: [{ label: 'Bad', url: 'javascript:alert(1)' }] }, { ...review.details, acceptanceCriteria: [{ text: 'x', status: 'accepted' }] }]) {
    fs.writeFileSync(review.file, JSON.stringify(bad)); assert.throws(() => capture.checkpoint(review.options));
    assert.equal(JSON.parse(fs.readFileSync(file)).pending, undefined);
  }
  assert.equal(state.submits.length, 0);
});

test('server must confirm review content; a dropped report stays pending', (t) => {
  const { options, state, file } = fixture(t); capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options); state.dropReview = true;
  assert.throws(() => capture.checkpoint(review.options), /not confirmed/);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).pending.reviewDetails, review.details);
});
test('optional empty strings match the typed CLI and server representation', (t) => {
  const { options, state } = fixture(t); capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options);
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, artifactUrl: '', limitations: '', evidence: [{ label: 'Tests', url: '', description: 'Passed' }, { label: 'PR', url: 'https://example.test/pr/1', description: '' }] }));
  capture.checkpoint(review.options);
  assert.equal(Object.hasOwn(state.unit.result.reviewDetails, 'limitations'), false);
  assert.equal(Object.hasOwn(state.unit.result.reviewDetails, 'artifactUrl'), false);
  assert.deepEqual(state.unit.result.reviewDetails.evidence, [{ label: 'Tests', description: 'Passed' }, { label: 'PR', url: 'https://example.test/pr/1' }]);
});

 test('unbound work is skipped without declaration or receipt; cross-product requires explicit intent', (t) => {
  const { options, state, file } = fixture(t); state.unbound = true;
  assert.equal(capture.begin(options).status, 'skipped_unassigned');
  assert.equal(state.unit, null); assert.equal(fs.existsSync(file), false);
  assert.throws(() => capture.begin({ ...options, 'cross-product-reason': ' ' }), /explicit/);
  state.unbound = false;
  const cross = { ...options, feature: undefined, 'cross-product-reason': 'Shared infrastructure for two products' };
  assert.equal(capture.begin(cross).status, 'recording');
  assert.equal(state.unit.productId, null); assert.equal(state.unit.crossProductReason, cross['cross-product-reason']);
  assert.throws(() => capture.begin(options), /scope/);
  assert.equal(capture.checkpoint(options).status, 'skipped_missing_feature');
  capture.begin(cross);
  state.head = 'e'.repeat(40); assert.equal(capture.checkpoint(options).status, 'submitted_for_review');
 });
 test('changed product and legacy unscoped receipts never submit automatically', (t) => {
  const { options, state, file } = fixture(t); capture.begin(options); state.head = 'e'.repeat(40);
  state.product = org; assert.throws(() => capture.checkpoint(options), /scope/);
  state.product = other; state.unit.productId = org; assert.throws(() => capture.checkpoint(options), /scope/);
  state.unit.productId = other;
  const receipt = JSON.parse(fs.readFileSync(file)); delete receipt.scope; fs.writeFileSync(file, JSON.stringify(receipt));
  assert.throws(() => capture.checkpoint(options), /Legacy capture/); assert.equal(state.submits.length, 0);
 });

test('unsafe artifact URLs are rejected before a submission becomes pending', (t) => {
  const { options, state, file } = fixture(t); capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options);
  for (const artifactUrl of [null, 7, 'javascript:alert(1)', 'file:///tmp/a', '//example.test', 'https://user:secret@example.test/commit/abc', 'https://example.test/a b', 'https://example.test/\\bad', 'https://example.test/\u0000bad', 'https://%zz', 'https://example.test/' + 'a'.repeat(2000)]) {
    fs.writeFileSync(review.file, JSON.stringify({ ...review.details, artifactUrl }));
    assert.throws(() => capture.checkpoint(review.options));
    assert.equal(JSON.parse(fs.readFileSync(file)).pending, undefined);
  }
  assert.equal(state.submits.length, 0);
});
