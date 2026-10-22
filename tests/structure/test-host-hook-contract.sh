#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/evals/host-hook-contract"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

for f in probe.js analyze.js contract.js codex-binary.js mock-model.js app-server-client.js schemas.js fixture/plugins/hookprobe/hooks/record.js; do
  if node --check "$PROBE/$f" 2>/dev/null; then ok "node --check $f"; else bad "node --check $f"; fi
done
for f in run-probe.sh extract-hook-schemas.sh; do
  if bash -n "$PROBE/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

OUT="$(env CODEX_HOME=/nonexistent bash "$PROBE/run-probe.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'inherited CODEX_HOME'; then
  ok "run-probe.sh refuses an inherited CODEX_HOME"
else
  bad "run-probe.sh did not refuse an inherited CODEX_HOME (exit $RC)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RESULT="$(ROOT="$ROOT" PROBE="$PROBE" WORK="$WORK" node <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawnSync } = require('node:child_process');

const ROOT = process.env.ROOT;
const PROBE = process.env.PROBE;
const WORK = process.env.WORK;
const lines = [];
const ok = (name) => lines.push(`ok ${name}`);
const bad = (name) => lines.push(`bad ${name}`);
const check = (cond, name) => (cond ? ok(name) : bad(name));

const analyze = require(path.join(PROBE, 'analyze.js'));
const contract = require(path.join(PROBE, 'contract.js'));
const schemas = require(path.join(PROBE, 'schemas.js'));
const probe = require(path.join(PROBE, 'probe.js'));
const { startMockModel } = require(path.join(PROBE, 'mock-model.js'));

function syntheticFacts() {
  const { CALLS, MARKERS, FILES } = contract;
  const output = (callId, text) => ({ input: [{ type: 'custom_tool_call_output', call_id: callId, output: text }] });
  const stubFs = (present) => ({
    existsSync: (file) => present.includes(path.basename(file)),
    readFileSync: () => {
      throw new Error('no file');
    },
  });
  const ctx = (present) => ({ fs: stubFs(present), codexHome: '/h', plugin: { name: 'p', marketplace: 'm', id: 'p@m', version: '0.0.1' }, tuiStrings: {} });
  const run = (name, requests, hooks = []) => ({ name, requests, hooks, project: '/p' });
  const denied = [{ input: [] }, output(CALLS.deny, `${MARKERS.deny} Bash`)];
  const denyRuns = ['deny-classic-bash-json', 'deny-code-bash-json', 'deny-code-patch-json'].map((name) => run(name, denied));
  const blockRun = (name) => run(name, [{ input: [] }, { input: [{ type: 'message', role: 'user', content: MARKERS.stop }] }]);
  const passing = analyze.deriveFacts([...denyRuns, blockRun('stop-decision-block'), blockRun('stop-code-decision-block')], ctx([]));
  check(passing.deny.codeMode.bashJson.blocked === true && passing.deny.classic.bashJson.reasonReachesModel === true, 'deny facts read the reason from the denied call output');
  check(analyze.deriveGate(passing).verdict === 'continue', 'gate continues when JSON deny and decision block work on both surfaces');
  const sideEffect = analyze.deriveFacts(denyRuns, ctx([FILES.denied]));
  check(sideEffect.deny.codeMode.bashJson.blocked === false, 'a deny whose side effect happened is not a block');
  const posted = analyze.deriveFacts([run('deny-code-bash-json', denied, [{ event: 'PostToolUse', argv: ['PostToolUse'], payload: { tool_name: 'Bash' } }])], ctx([]));
  check(posted.deny.codeMode.bashJson.blocked === false, 'a deny followed by PostToolUse is not a block');
  const silent = analyze.deriveFacts([run('deny-code-bash-json', [{ input: [] }])], ctx([]));
  check(Boolean(silent.deny.codeMode.bashJson.unverified), 'a denied call without output stays unverified');
  const stops = analyze.deriveFacts([
    run('stop-decision-block', [{ input: [] }]),
    run('stop-exit2', [{ input: [] }, { input: [] }]),
    blockRun('stop-continue-false'),
  ], ctx([]));
  check(stops.stop.classic.decisionBlock.blocks === false, 'one model request is not a Stop block');
  check(stops.stop.classic.exit2.blocks === false, 'an extra request without the block reason is not a Stop block');
  check(stops.stop.classic.continueFalse.blocks === true, 'an extra request carrying the block reason is a Stop block');
  check(analyze.deriveGate(stops).verdict === 'stop', 'gate stops when a Stop block is missing');
  const parent = { input: [{ type: 'message', role: 'user', content: MARKERS.subagentStop }] };
  const child = { client_metadata: { thread_id: 't2', 'x-codex-parent-thread-id': 't1' }, input: [{ type: 'message', role: 'user', content: MARKERS.subagentStop }] };
  const both = analyze.deriveFacts([run('spawn-code-subagent-stop-block', [parent, child])], ctx([]));
  check(both.subagentStop.codeMode.blockTarget === 'both', 'a block reason in parent and subagent requests reads both');
  const labelled = analyze.deriveFacts([run('deny-code-bash-json', denied, [
    { event: 'PreToolUse', argv: ['PreToolUse'], payload: { tool_name: 'Bash' } },
    { event: 'PreToolUse', label: 'bash-anchored', argv: ['PreToolUse', 'bash-anchored'], payload: { tool_name: 'Bash' } },
    { event: 'PreToolUse', label: 'claude-edit', argv: ['PreToolUse', 'claude-edit'], payload: { tool_name: 'apply_patch' } },
    { event: 'PostToolUse', label: 'bash-plain', argv: ['PostToolUse', 'bash-plain'], payload: { tool_name: 'Bash' } },
  ])], ctx([]));
  check(JSON.stringify(labelled.deny.matcherHits) === JSON.stringify({ Bash: ['bash-anchored'], apply_patch: ['claude-edit'] }), 'matcher hits group labelled records by tool name');
  check(labelled.deny.codeMode.bashJson.blocked === true, 'labelled matcher records never count as the catch-all hook');
  const empty = analyze.deriveFacts([], ctx([]));
  check(['hookEnvironment', 'threadId', 'toolHooks', 'requestUserInput', 'hookTrust', 'interrupt', 'features'].every((key) => Boolean(empty[key].unverified)), 'missing scenarios yield unverified facts');
  check(Boolean(empty.subagents.classic.unverified) && Boolean(empty.agentRoles.unverified), 'missing spawn and role scenarios yield unverified facts');
  check(analyze.deriveGate(empty).verdict === 'stop', 'gate stops when nothing was measured');
  const rui = analyze.deriveFacts([
    run('classic-rui', [{ input: [] }, { input: [{ type: 'function_call_output', call_id: CALLS.rui, output: 'request_user_input is unavailable in Default mode' }] }]),
    run('code-rui', [{ input: [] }]),
    { ...run('app-rui', []), serverRequests: [], result: { threads: { classic: 'a', code: 'b' } } },
  ], ctx([]));
  check(rui.requestUserInput.exec.classic === 'unavailable' && Boolean(rui.requestUserInput.exec.codeMode.unverified), 'request_user_input answers come from the call output, missing output stays unverified');
}

async function main() {
  const resultsDir = path.join(PROBE, 'results');
  const resultFiles = fs.existsSync(resultsDir) ? fs.readdirSync(resultsDir).filter((name) => name.endsWith('.json')).sort() : [];
  check(resultFiles.length >= 2, `at least two recorded Codex versions (${resultFiles.length})`);
  const verdicts = new Set();
  for (const file of resultFiles) {
    const results = JSON.parse(fs.readFileSync(path.join(resultsDir, file), 'utf8'));
    const problems = analyze.validateResults(results);
    check(problems.length === 0, `results/${file} validates${problems.length ? `: ${problems.join('; ')}` : ''}`);
    check(`${results.codexVersion}.json` === file, `results/${file} names its own version`);
    check(JSON.stringify(results.gate) === JSON.stringify(analyze.deriveGate(results.facts || {})), `results/${file} gate agrees with its facts`);
    verdicts.add(results.gate && results.gate.verdict);
    const schemaDir = path.join(PROBE, 'schemas', results.codexVersion);
    check(fs.existsSync(schemaDir) && fs.readdirSync(schemaDir).some((name) => name.endsWith('.json')), `schemas/${results.codexVersion}/ holds the extracted hook schemas`);
  }
  const schemaRoot = path.join(PROBE, 'schemas');
  for (const version of fs.existsSync(schemaRoot) ? fs.readdirSync(schemaRoot).sort() : []) {
    const schemaDir = path.join(schemaRoot, version);
    const schemaFiles = fs.readdirSync(schemaDir).filter((name) => name.endsWith('.json'));
    const titlesMatch = schemaFiles.length > 0 && schemaFiles.every((name) => JSON.parse(fs.readFileSync(path.join(schemaDir, name), 'utf8')).title === name.replace(/\.json$/, ''));
    check(titlesMatch, `schemas/${version}/ file names equal their schema titles`);
  }

  const doc = path.join(ROOT, 'docs', 'codex-port.md');
  const text = fs.existsSync(doc) ? fs.readFileSync(doc, 'utf8') : '';
  check(text.length > 0, 'docs/codex-port.md exists');
  for (const file of resultFiles) check(text.includes(`results/${file}`), `docs/codex-port.md cites results/${file}`);
  const gateLines = text.split('\n').filter((line) => line.startsWith('Gate verdict:'));
  check(gateLines.length === 1, `docs/codex-port.md has exactly one gate verdict line (${gateLines.length})`);
  const docVerdict = gateLines.length === 1 ? (/^Gate verdict: (continue|stop)\b/.exec(gateLines[0]) || [])[1] : null;
  check(verdicts.size === 1 && docVerdict === [...verdicts][0], 'docs/codex-port.md verdict matches every recorded gate');

  const synthetic = Buffer.concat([
    Buffer.from('\u0000junkbytes'),
    Buffer.from('stop.command.input{"title":"stop.command.input","type":"object"}'),
    Buffer.from('\u0001Errorpost-tool-use.command.output{"title":"post-tool-use.command.output","properties":{"a":{"description":"brace } and quote \\" inside"}}}'),
    Buffer.from('\u0002tail'),
  ]);
  const extracted = schemas.extractSchemas(synthetic);
  check(extracted.size === 2 && extracted.has('stop.command.input') && extracted.has('post-tool-use.command.output'), 'schema extractor splits concatenated schemas on their markers');
  check(extracted.get('post-tool-use.command.output').properties.a.description === 'brace } and quote " inside', 'schema extractor respects braces and quotes inside strings');
  let threw = false;
  try {
    schemas.extractSchemas(Buffer.from('stop.command.input{"title":"stop.command.output"}'));
  } catch {
    threw = true;
  }
  check(threw, 'schema extractor refuses a title that disagrees with its marker');
  const drift = schemas.compareSchemas(new Map([['stop.command.input', '{}\n']]), extracted);
  check(drift.some((line) => line.startsWith('changed: stop.command.input')) && drift.some((line) => line.startsWith('new in binary: post-tool-use')), 'schema comparison reports changed and new schemas');

  const seen = [];
  const mock = await startMockModel({
    respond: () => [
      { type: 'function_call', name: 'exec_command', arguments: { cmd: 'echo hi' }, namespace: 'functions', callId: 'call_fixed' },
      { type: 'custom_tool_call', name: 'exec', input: 'text("hi")' },
      { type: 'message', text: 'done' },
    ],
    onRequest: (request) => seen.push(request),
  });
  const post = await new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: mock.port, path: '/v1/responses', method: 'POST' }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end(JSON.stringify({ input: [] }));
  });
  const get = await new Promise((resolve) => http.get({ host: '127.0.0.1', port: mock.port, path: '/v1/models' }, (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); }));
  await mock.close();
  const events = post.body.split('\n').filter((line) => line.startsWith('data: ')).map((line) => JSON.parse(line.slice(6)));
  const completed = events.find((event) => event.type === 'response.completed');
  const items = completed ? completed.response.output : [];
  check(post.status === 200 && items.length === 3, 'mock model streams a completed response with every scripted item');
  check(items[0] && items[0].type === 'function_call' && items[0].arguments === '{"cmd":"echo hi"}' && items[0].namespace === 'functions' && items[0].call_id === 'call_fixed', 'mock function_call carries JSON arguments, namespace and the scripted call_id');
  check(items[1] && items[1].type === 'custom_tool_call' && items[1].input === 'text("hi")' && Boolean(items[1].call_id), 'mock custom_tool_call carries raw input and a call_id');
  check(get === 404 && seen.some((request) => request.served === false) && seen.some((request) => request.served === true), 'mock model serves only POST /responses and reports both');

  const recorder = path.join(PROBE, 'fixture', 'plugins', 'hookprobe', 'hooks', 'record.js');
  const runRecorder = (args, payload, mode, dir) => spawnSync(process.execPath, [recorder, ...args], {
    input: JSON.stringify(payload),
    env: { PATH: process.env.PATH, PROBE_DIR: dir, PROBE_MODE: JSON.stringify(mode) },
    encoding: 'utf8',
  });
  const denyDir = fs.mkdtempSync(path.join(WORK, 'deny-'));
  const deny = runRecorder(['PreToolUse'], { tool_name: 'Bash', tool_input: { command: 'touch x' } }, { deny: { tool: 'Bash', via: 'json', marker: 'M' } }, denyDir);
  let denyOut = null;
  try {
    denyOut = JSON.parse(deny.stdout);
  } catch {
    denyOut = null;
  }
  check(deny.status === 0 && denyOut && denyOut.hookSpecificOutput.permissionDecision === 'deny' && denyOut.hookSpecificOutput.permissionDecisionReason === 'M Bash', 'recorder emits a JSON deny with the marker it was given');
  check(fs.readdirSync(path.join(denyDir, 'hooks')).length === 1, 'recorder writes one record per invocation');
  const exit2 = runRecorder(['PreToolUse'], { tool_name: 'apply_patch', tool_input: { command: 'p' } }, { deny: { tool: ['apply_patch'], via: 'exit2', marker: 'M' } }, fs.mkdtempSync(path.join(WORK, 'exit2-')));
  check(exit2.status === 2 && /M apply_patch/.test(exit2.stderr), 'recorder denies through exit 2 with the reason on stderr');
  const pass = runRecorder(['PreToolUse'], { tool_name: 'Bash', tool_input: { command: 'x' } }, { deny: { tool: 'apply_patch', marker: 'M' } }, fs.mkdtempSync(path.join(WORK, 'pass-')));
  check(pass.status === 0 && pass.stdout === '', 'recorder lets other tools through');
  const labelDir = fs.mkdtempSync(path.join(WORK, 'label-'));
  const labelled = runRecorder(['PreToolUse', 'bash-anchored'], { tool_name: 'Bash', tool_input: { command: 'x' } }, { deny: { tool: 'Bash', via: 'exit2', marker: 'M' } }, labelDir);
  const labelRecord = JSON.parse(fs.readFileSync(path.join(labelDir, 'hooks', fs.readdirSync(path.join(labelDir, 'hooks'))[0]), 'utf8'));
  check(labelled.status === 0 && labelled.stdout === '' && labelRecord.label === 'bash-anchored', 'a matcher-labelled recorder records its label and never denies');
  const stopDir = fs.mkdtempSync(path.join(WORK, 'stop-'));
  const shapes = [1, 2, 3].map(() => runRecorder(['Stop'], { stop_hook_active: false }, { stop: { shape: 'decision-block', marker: 'M' } }, stopDir).stdout);
  check(/"decision":"block"/.test(shapes[0]) && /"decision":"block"/.test(shapes[1]) && shapes[2] === '', 'recorder blocks Stop twice and then allows it');
  const context = runRecorder(['SessionStart'], { source: 'startup' }, { context: { sessionStart: 'CTX' } }, fs.mkdtempSync(path.join(WORK, 'ctx-')));
  check(/"additionalContext":"CTX"/.test(context.stdout), 'recorder injects SessionStart context on request');

  const hooksFile = JSON.parse(fs.readFileSync(path.join(PROBE, 'fixture', 'plugins', 'hookprobe', 'hooks', 'hooks.json'), 'utf8'));
  const matcherGroups = hooksFile.hooks.PreToolUse.filter((group) => group.matcher !== undefined).map((group) => ({ label: group.hooks[0].command.split(' ').pop(), matcher: group.matcher }));
  check(JSON.stringify(matcherGroups) === JSON.stringify(contract.MATCHERS), 'fixture matcher groups equal the contract matcher list');
  check(hooksFile.hooks.PreToolUse[0].matcher === undefined && hooksFile.hooks.PreToolUse[0].hooks[0].command.endsWith(' PreToolUse'), 'the catch-all PreToolUse group comes first and carries no label');

  const env = analyze.envLines('A=1\nCODEX_THREAD_ID=abc\nnot a line\n');
  check(env.A === '1' && env.CODEX_THREAD_ID === 'abc' && Object.keys(env).length === 2, 'envLines parses KEY=VALUE lines only');
  const refs = { pluginRoot: '/r', pluginData: '/d', project: '/p', codexHome: '/h' };
  check(analyze.classifyValue('/r', refs) === 'plugin-root' && analyze.classifyValue('1', refs) === 'literal:1' && analyze.classifyValue('/elsewhere/x', refs) === 'other', 'classifyValue never records a raw path');
  const tools = analyze.toolsOfBody({
    tools: [{ type: 'function', name: 'a' }, { type: 'namespace', name: 'ns', tools: [{ type: 'function', name: 'b' }] }],
    input: [{ type: 'additional_tools', tools: [{ type: 'namespace', name: 'functions', tools: [{ type: 'custom', name: 'exec' }] }] }],
  });
  check(JSON.stringify(tools) === JSON.stringify(['a', 'functions.exec', 'ns.b']), 'toolsOfBody flattens namespaces and additional_tools');
  check(analyze.outputOfCall({ input: [{ type: 'function_call_output', call_id: 'x', output: 'out' }] }, 'x') === 'out' && analyze.outputOfCall({ input: [] }, 'x') === null, 'outputOfCall finds the output of one call id');
  check(analyze.diffPaths({ a: [1, 2] }, { a: [1, 3] }).length === 1 && analyze.diffPaths({ a: 1 }, { a: 1 }).length === 0, 'diffPaths reports only differing leaves');
  check(analyze.diffPaths(analyze.comparable({ conditions: { launcher: 'npm package' } }), analyze.comparable({ conditions: { launcher: 'native binary' } })).length === 0, 'the launcher condition never counts as drift');
  check(analyze.validateResults({ schemaVersion: analyze.SCHEMA_VERSION, codexVersion: '1.2.3', measuredOn: '2026-01-01', conditions: {}, facts: {}, gate: { verdict: 'continue', denyShell: true, denyApplyPatch: true, stopBlocks: true } }).some((problem) => problem.startsWith('facts.events missing')), 'validateResults requires every fact group');
  check(analyze.validateResults({ schemaVersion: analyze.SCHEMA_VERSION, codexVersion: '1.2.3', measuredOn: '2026-01-01', conditions: { p: '/Users/someone/x' }, facts: {}, gate: { verdict: 'continue' } }).includes('results contain an absolute path'), 'validateResults rejects absolute paths');
  syntheticFacts();

  let rejected = 0;
  for (const argv of [['--record', '--check'], ['--timeout', '0'], ['--bogus']]) {
    try {
      probe.parseArgs(argv);
    } catch {
      rejected += 1;
    }
  }
  check(rejected === 3, 'probe argument parser rejects conflicting, invalid and unknown flags');
  const respond = probe.makeResponder({ main: [[{ type: 'message', text: 'main-1' }], [{ type: 'message', text: 'main-2' }]], sub: [[{ type: 'message', text: 'sub-1' }]] });
  const subReply = respond({ client_metadata: { thread_id: 't2', 'x-codex-parent-thread-id': 't1' }, input: [] });
  const mainReply = respond({ client_metadata: { thread_id: 't1' }, input: [] });
  const markerOnly = respond({ client_metadata: { thread_id: 't3' }, input: [{ type: 'message', role: 'user', content: 'PROBE_SUBAGENT_TASK' }] });
  check(subReply[0].text === 'sub-1' && mainReply[0].text === 'main-1' && markerOnly[0].text === 'main-2', 'responder routes subagent requests by their parent-thread metadata only');
  let ordered = null;
  try {
    ordered = probe.orderedScenarios();
  } catch {
    ordered = null;
  }
  const names = probe.SCENARIOS.map((scenario) => scenario.name);
  check(Array.isArray(ordered) && ordered.length === names.length && new Set(names).size === names.length, 'every scenario is ordered exactly once and every name is unique');

  const inventory = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests', 'profiles', 'promptfoo-local-only.v1.json'), 'utf8'));
  check(inventory.ciStructureTests.includes('test-host-hook-contract.sh'), 'this suite is classified as a CI structure test');

  process.stdout.write(`${lines.join('\n')}\n`);
}

main().catch((error) => {
  process.stdout.write(`bad unexpected error: ${error.message}\n`);
});
NODE
)"
NODE_RC=$?
[ "$NODE_RC" -eq 0 ] || bad "node checks exited $NODE_RC"
printf '%s\n' "$RESULT" | grep -q '^ok ' || bad "node checks reported nothing"

while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "bad "*) bad "${line#bad }" ;;
  esac
done <<< "$RESULT"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
