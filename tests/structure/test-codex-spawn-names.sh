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
const rel = (file) => path.relative(root, file);
const TEXT = /\.(md|sh|js|json|toml|yaml|yml)$/;
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = path.join(dir, entry.name);
  if (entry.isDirectory()) return entry.name === 'assets' ? [] : walk(full);
  return TEXT.test(entry.name) ? [full] : [];
});
const files = [...walk(plugin), ...walk(path.join(root, 'reference'))];

const LITERAL = /task_name\s*[:=]\s*\\?(["'`])([^"'`\\\n]*)\\?\1/g;
const validTaskName = (value) => /^[a-z0-9_]+$/.test(value.replace(/<[a-z][a-z_]*>/g, 'x'));
const literals = files.flatMap((file) => [...read(file).matchAll(LITERAL)].map((m) => ({ file: rel(file), value: m[2] })));
const invalid = literals.filter(({ value }) => !validTaskName(value));
check(`plugin text names task_name literals (${literals.length})`, literals.length >= 8);
check('every task_name literal is a valid Codex task name', invalid.length === 0,
  invalid.map(({ file, value }) => `${file}: task_name "${value}"`));

const OLD_PERSONA_NAMING = 'Name each agent `<persona-id>`';
const stale = files.filter((file) => read(file).includes(OLD_PERSONA_NAMING)).map(rel);
check('no skill names an agent by its hyphenated persona id', stale.length === 0, stale);

const RULE = 'lowercase letters, digits and underscores';
const REUSE = 'already used in this thread';
const skill = (name) => read(path.join(plugin, 'skills', name, 'SKILL.md'));
for (const name of ['tdd', 'plan-review', 'pr-team-review', 'ghost-scan']) {
  const text = skill(name);
  check(`${name} states the task_name character rule`, text.includes(RULE));
  check(`${name} states that a reused task_name is refused`, text.includes(REUSE));
  check(`${name} names a task_name literal`, literals.some(({ file }) => file === rel(path.join(plugin, 'skills', name, 'SKILL.md'))));
}

const tdd = skill('tdd').split('\n');
const stepLine = (prefix) => tdd.find((line) => line.startsWith(prefix)) || '';
const fanOut = stepLine('    4. **Review fan-out');
const consume = stepLine('    6. **Thin consume-mode spawn');
for (const [label, line, needles] of [
  ['aspect fan-out', fanOut, ['task_name: "<perspective>_<n>"', 'agent_type: "zensu-review-aspect"', 'fork_turns: "none"', REUSE, 'list_agents', 'conventions', 'bugs', 'architecture', 'tests', 'security']],
  ['consume-mode reviewer', consume, ['task_name: "zensu_code_reviewer_<n>"', 'agent_type: "zensu-code-reviewer"', 'fork_turns: "none"', REUSE]],
]) {
  check(`tdd Phase 6 ${label} step exists`, line.length > 0);
  const missing = needles.filter((needle) => !line.includes(needle));
  check(`tdd Phase 6 ${label} spells the spawn call`, missing.length === 0, missing.map((needle) => `missing: ${needle}`));
}
check('tdd says the role never goes into task_name', fanOut.includes('never') && fanOut.includes('agent_type'));
check('tdd says an unbound reviewer is reported', fanOut.includes('`default`') && fanOut.includes('final report'));

for (const file of ['skills/implement/SKILL.md', 'skills/zensu-help/SKILL.md', 'AGENTS.zensu.md']) {
  check(`${file} names the reviewer task_name`, read(path.join(plugin, file)).includes('zensu_code_reviewer_<n>'));
}

const stop = read(path.join(plugin, 'hooks', 'stop-chain-enforcer.sh'));
const stopLines = (needle) => stop.split('\n').filter((line) => line.includes(needle));
check('the max-rounds message asks for a fresh task_name',
  stopLines('did not converge after').some((line) => line.includes('fresh task_name')));
check('the chain block reason asks for a fresh task_name',
  stopLines('A main-thread TDD session finished implementation').some((line) => line.includes('fresh task_name') && line.includes('zensu_code_reviewer_<n>')));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
NODE
