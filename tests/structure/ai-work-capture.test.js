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

function fixture(t) {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-work-capture-'));
  fs.mkdirSync(path.join(workspace, '.git'));
  const options = { source: 'codex', sourceVersion: '1.2.3', workspace, session, task: 'goal-1', title: 'Implement agreed goal', criteria: 'spec-v1' };
  const state = { apiUrl: 'https://api.example.test', actor, head: 'a'.repeat(40), dirty: '', unit: null, submits: [], calls: [], failResponse: false };
  const previous = cp.spawnSync;
  cp.spawnSync = (command, args, opts) => {
    assert.equal(opts.shell, undefined, 'metadata must never become a shell command');
    let value;
    if (command === 'git') {
      value = args.includes('--absolute-git-dir') ? path.join(workspace, '.git') : args[0] === 'status' ? state.dirty : state.head;
    } else {
      assert.equal(command, 'zensu'); assert.equal(args[0], 'ai-work');
      state.calls.push(args);
      const flag = (key) => args[args.indexOf(key) + 1];
      switch (args[1]) {
        case 'context': value = { apiUrl: state.apiUrl, ready: !state.unbound, workScope: args.includes('--cross-product') ? 'cross_product' : state.unbound ? 'unassigned' : 'product', productId: args.includes('--cross-product') ? undefined : (state.product || other), reportingUserId: state.actor, organizationId: org }; break;
        case 'start':
          if (state.unit && state.unit.actor !== state.actor) return { status: 1, stderr: 'secret server body' };
          state.unit ??= { id: flag('--id'), workScope: args.includes('--product') ? 'product' : 'cross_product', productId: args.includes('--product') ? flag('--product') : null, crossProductReason: args.includes('--cross-product-reason') ? flag('--cross-product-reason') : '', actor: state.actor, source: flag('--source'), sourceVersion: flag('--source-version'), runKind: flag('--run-kind'), version: 1, result: null, decision: null };
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
  const details = { summary: 'Implemented review dialog', acceptanceCriteria: [{ text: 'Shows evidence', status: 'met' }], evidence: [{ label: 'Tests', description: '24 passed' }], limitations: 'Human review pending' };
  fs.writeFileSync(file, JSON.stringify(details));
  return { file, details, options: { ...options, 'review-file': file } };
}
test('captures explicit review details and freezes exact retries after a lost response', (t) => {
  const { options, state, file } = fixture(t);
  capture.begin(options); state.head = 'c'.repeat(40);
  const review = reviewFixture(options); state.failResponse = true;
  assert.throws(() => capture.checkpoint(review.options), /incomplete/);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).pending.reviewDetails, review.details);
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, summary: 'Changed' }));
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
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, summary: 'Updated description' }));
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
  fs.writeFileSync(review.file, JSON.stringify({ ...review.details, limitations: '', evidence: [{ label: 'Tests', url: '', description: 'Passed' }, { label: 'PR', url: 'https://example.test/pr/1', description: '' }] }));
  capture.checkpoint(review.options);
  assert.equal(Object.hasOwn(state.unit.result.reviewDetails, 'limitations'), false);
  assert.deepEqual(state.unit.result.reviewDetails.evidence, [{ label: 'Tests', description: 'Passed' }, { label: 'PR', url: 'https://example.test/pr/1' }]);
});

 test('unbound work is skipped without declaration or receipt; cross-product requires explicit intent', (t) => {
  const { options, state, file } = fixture(t); state.unbound = true;
  assert.equal(capture.begin(options).status, 'skipped_unassigned');
  assert.equal(state.unit, null); assert.equal(fs.existsSync(file), false);
  assert.throws(() => capture.begin({ ...options, 'cross-product-reason': ' ' }), /explicit/);
  state.unbound = false;
  const cross = { ...options, 'cross-product-reason': 'Shared infrastructure for two products' };
  assert.equal(capture.begin(cross).status, 'recording');
  assert.equal(state.unit.productId, null); assert.equal(state.unit.crossProductReason, cross['cross-product-reason']);
  assert.throws(() => capture.begin(options), /product scope/);
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
