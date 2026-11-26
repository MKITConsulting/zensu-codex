#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

node - "$ROOT" <<'NODE'
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(process.argv[2]);
const plugin = path.join(root, 'plugins', 'zensu');
let pass = 0;
let fail = 0;
const check = (label, ok, details = []) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok) for (const line of details.filter(Boolean)) console.log(`        ${line}`);
  if (ok) pass += 1; else fail += 1;
};
const read = (file) => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const flat = (text) => text.replace(/\s+/g, ' ');
const rel = (file) => path.relative(root, file);
const TEXT = /\.(md|sh|js|json|toml|yaml|yml)$/;
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = path.join(dir, entry.name);
  if (entry.isDirectory()) return entry.name === 'assets' ? [] : walk(full);
  return TEXT.test(entry.name) ? [full] : [];
});
const files = [...walk(plugin), ...walk(path.join(root, 'reference'))];

const LITERAL = /\btask_name\\?["'`]?\s*[:=]\s*\\?(["'`])([^"'`\\\n]*)\\?\1/g;
const validTaskName = (value) => /^[a-z0-9_]+$/.test(value.replace(/<[a-z][a-z_]*>/g, 'x'));
const SAMPLES = ['"task_name":"a-b"', '\\"task_name\\":\\"a-b\\"', '`task_name`: `a-b`', 'task_name: "a-b"', "task_name='a-b'"];
const unread = SAMPLES.filter((sample) => {
  const values = [...sample.matchAll(LITERAL)].map((m) => m[2]);
  return values.length !== 1 || values[0] !== 'a-b';
});
check('the literal scanner reads the JSON, escaped, Markdown and plain key forms', unread.length === 0, unread);

const literals = files.flatMap((file) => [...read(file).matchAll(LITERAL)].map((m) => ({ file: rel(file), value: m[2] })));
const invalid = literals.filter(({ value }) => !validTaskName(value));
check(`plugin text names task_name literals (${literals.length})`, literals.length >= 8);
check('every task_name literal is a valid Codex task name', invalid.length === 0,
  invalid.map(({ file, value }) => `${file}: task_name "${value}"`));

const STALE = [
  'Name each agent `<persona-id>`',
  'Name each subagent by its role',
  'same role, same prompt',
  'is what fires `post-review-tdd-delegate.sh`',
  '`post-review-tdd-delegate.sh` routes any findings back',
  'For ANY interaction with the `zensu` CLI',
  'for review round `<n>`',
  'in review round `<n>`',
];
const stale = files.flatMap((file) => STALE.filter((phrase) => flat(read(file)).includes(phrase)).map((phrase) => `${rel(file)}: ${phrase}`));
check('no plugin text keeps a stale spawn or routing instruction', stale.length === 0, stale);

const RULE = 'lowercase letters, digits and underscores';
const REUSE = 'already used in this thread';
const CLASSIC = '(the classic surface), leave them out and skip `list_agents`';
const skillFile = (name) => path.join(plugin, 'skills', name, 'SKILL.md');
const skill = (name) => flat(read(skillFile(name)));
for (const name of ['tdd', 'plan-review', 'pr-team-review', 'ghost-scan', 'pr-fix-findings']) {
  const text = skill(name);
  check(`${name} states the task_name character rule`, text.includes(RULE));
  check(`${name} states that a reused task_name is refused`, text.includes(REUSE));
  check(`${name} checks list_agents before spawning`, text.includes('list_agents'));
  check(`${name} spawns with fork_turns "none"`, text.includes('fork_turns: "none"'));
  check(`${name} keeps the classic-surface exception`, text.includes(CLASSIC));
  check(`${name} names a task_name literal`, literals.some(({ file }) => file === rel(skillFile(name))));
}
for (const [name, prefixed] of [
  ['plan-review', 'task_name: "plan_<persona>"'],
  ['pr-team-review', 'task_name: "team_<role_id>"'],
  ['ghost-scan', 'task_name: "scan_<lens>"'],
  ['pr-fix-findings', 'task_name: "fix_<item>"'],
]) {
  const text = skill(name);
  check(`${name} prefixes its task_name per skill`, text.includes(prefixed));
  check(`${name} derives the task_name from any id`, text.includes('other than `a-z` and `0-9` replaced by `_`'));
}

const section = (name, from, to) => {
  const text = read(skillFile(name));
  const start = text.indexOf(from);
  const end = start === -1 ? -1 : text.indexOf(to, start + from.length);
  return start === -1 || end === -1 ? '' : flat(text.slice(start, end));
};
for (const [label, text, needles] of [
  ['pr-team-review Phase A deep-diff helpers', section('pr-team-review', 'For PRs > 50 files', '**A.2 Persona-Cast:**'), ['task_name: "team_diff_<area>"', 'apart from the Phase B reviewers', 'read-only by instruction only', 'which code mode does not yet enforce', 'git -C "$WORKTREE" diff origin/<base>...<SHA> -- <area paths>', 'denies it the shell, spawning and every path outside the project root', 'never to edit anything', 'the `baseRefName` from step 1', "it starts without the lead's turns"]],
  ['pr-fix-findings fan-out', section('pr-fix-findings', '3. **Triage for parallelism.**', '5. **Land the changes.**'), ['task_name: "fix_<item>"', 'also when a later loop iteration fixes the same item again', 'the review thread with the comment body, its path and line', '(`headRefName` from step 1)', 'denies it the shell, spawning and every path outside the project root', 'the path and current text of every file it may change', 'returns its fix as a patch against that text instead of applying it', 'Where these limits leave a fan-out nothing to do, fix inline', 'apply every patch in this thread inside `$zensu-tdd`', 'That holds by instruction only', 'in code mode its outer `exec` tool fires no hook', 'record `git status --porcelain` before the batch', 'still holds the text you put in its prompt', 'stop and report any other new path instead of deleting it']],
]) {
  check(`${label} section exists`, text.length > 0);
  const missing = [...needles, 'fork_turns: "none"', 'list_agents', RULE, REUSE, CLASSIC, 'other than `a-z` and `0-9` replaced by `_`']
    .filter((needle) => !text.includes(needle));
  check(`${label} spells the spawn call`, missing.length === 0, missing.map((needle) => `missing: ${needle}`));
}

const tdd = read(skillFile('tdd')).split('\n');
const stepLine = (prefix) => tdd.find((line) => line.startsWith(prefix)) || '';
const fanOut = stepLine('    4. **Review fan-out');
const consume = stepLine('    6. **Thin consume-mode spawn');
for (const [label, line, needles] of [
  ['aspect fan-out', fanOut, ['task_name: "<perspective>_<n>"', 'agent_type: "zensu-review-aspect"', 'fork_turns: "none"', REUSE, 'list_agents', 'never restarts', 'conventions', 'bugs', 'architecture', 'tests', 'security']],
  ['consume-mode reviewer', consume, ['task_name: "zensu_code_reviewer_<n>"', 'agent_type: "zensu-code-reviewer"', 'fork_turns: "none"', REUSE]],
]) {
  check(`tdd Phase 6 ${label} step exists`, line.length > 0);
  const missing = needles.filter((needle) => !line.includes(needle));
  check(`tdd Phase 6 ${label} spells the spawn call`, missing.length === 0, missing.map((needle) => `missing: ${needle}`));
}
check('tdd says the role never goes into task_name', fanOut.includes('never goes into `task_name`') && fanOut.includes('agent_type'));
check('tdd binds a role only when no project file shadows it', fanOut.includes('.codex/agents/') && fanOut.includes('.codex/config.toml'));
check('tdd gives an unbound reviewer its role contract',
  fanOut.includes('`developer_instructions`') && fanOut.includes('agents/zensu-review-aspect.toml') && consume.includes('agents/zensu-code-reviewer.toml'));
check('tdd reports an unbound reviewer as default and writable', fanOut.includes('`default`') && fanOut.includes('`host-profile-v1`') && fanOut.includes('final report'));
check('tdd keeps reviewers packet-only by contract and names the code-mode gap',
  fanOut.includes('Bound or not, they are packet-only by contract') && fanOut.includes('which code mode does not yet enforce'));
check('tdd routes the reviewer findings in the main thread', consume.includes('no hook fires on its completion'));
check('tdd ties the fan-out confinement claim to role binding',
  !skill('tdd').includes('is strictly read-only') && !skill('tdd').includes('five read-only')
  && skill('tdd').includes('by contract, plus the reviewer profile and capability gate where the role is bound'));

const doc = (file) => flat(read(path.join(plugin, file)));
for (const file of ['skills/implement/SKILL.md', 'skills/zensu-help/SKILL.md', 'AGENTS.zensu.md']) {
  check(`${file} names the reviewer task_name`, doc(file).includes('zensu_code_reviewer_<n>'));
}
check('implement makes agent_type conditional', doc('skills/implement/SKILL.md').includes('in `agent_type` when `spawn_agent` lists it'));
check('zensu-help names the project role source', doc('skills/zensu-help/SKILL.md').includes("the project's `.codex/agents/`"));
const conventions = doc('AGENTS.zensu.md');
check('AGENTS.zensu.md spawns the review chain with fork_turns "none"', conventions.includes('fork_turns: "none"'));
check('AGENTS.zensu.md keeps CLI work in the main thread', conventions.includes('in the main thread, through the `$zensu-*` skills') && conventions.includes('it never runs the CLI'));
check('AGENTS.zensu.md names a task_name for zensu-plm', conventions.includes('task_name: "zensu_plm_1"'));
check('AGENTS.zensu.md keeps the classic-surface exception',
  conventions.includes('On the classic surface, where `spawn_agent` takes no `task_name`, leave `task_name` and `fork_turns` out and skip `list_agents`'));
check('implement and zensu-help number the reviewer thread-wide',
  ['skills/implement/SKILL.md', 'skills/zensu-help/SKILL.md'].every((file) => doc(file).includes('so it never restarts in a later chain')));
check('zensu-help claims no unconditional read-only reviewer',
  !doc('skills/zensu-help/SKILL.md').includes('READ-ONLY') && doc('skills/zensu-help/SKILL.md').includes('which code mode does not yet enforce'));

const primers = read(path.join(plugin, 'hooks', 'session-start-primer.sh')).split('\n').filter((line) => line.includes('"additionalContext"'));
check('both session primers point at the spelled spawn call',
  primers.length === 2 && primers.every((line) => line.includes('$zensu-tdd Phase 6 step 10') && line.includes('never the hyphenated role name')));

const stop = read(path.join(plugin, 'hooks', 'stop-chain-enforcer.sh'));
const stopLines = (needle) => stop.split('\n').filter((line) => line.includes(needle));
check('the max-rounds message asks for an unused task_name',
  stopLines('did not converge after').some((line) => ['fresh task_name', 'list_agents', 'on the classic surface'].every((needle) => line.includes(needle))));
check('the chain block reason asks for a fresh, never restarting task_name',
  stopLines('A main-thread TDD session finished implementation').some((line) => ['fresh task_name', 'zensu_code_reviewer_<n>', 'never restarts', 'list_agents', 'On the classic surface'].every((needle) => line.includes(needle))));

const provider = read(path.join(root, 'evals', 'session-control', 'lib', 'codex-live-provider.js'));
const selfCheck = read(path.join(root, 'evals', 'session-control', 'run-self-check.sh'));
const constant = (name) => (provider.match(new RegExp(`const ${name} = '([^']+)';`)) || [])[1] || '';
for (const name of ['REVIEWER_TASK_NAME', 'PLM_TASK_NAME']) {
  check(`live harness ${name} is a valid Codex task name`, validTaskName(constant(name)), [`${name}=${constant(name) || '(missing)'}`]);
  check(`live harness directive spells ${name}`, provider.includes(`task_name is "\${${name}}"`));
}
check('live harness and its self-check expect the spelled reviewer path',
  !provider.includes("'/root/zensu_code_reviewer'") && selfCheck.includes(`agent_path="/root/${constant('REVIEWER_TASK_NAME')}"`));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
NODE
