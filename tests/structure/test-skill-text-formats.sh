#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

node - "$ROOT/plugins/zensu" <<'NODE'
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const pluginDir = path.resolve(process.argv[2]);
const skillsDir = path.join(pluginDir, 'skills');
let pass = 0;
let fail = 0;
const check = (label, ok, details = []) => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok) for (const line of details.filter(Boolean)) console.log(`        ${line}`);
  if (ok) pass += 1; else fail += 1;
};
const read = (file) => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const skill = (rel) => read(path.join(skillsDir, rel));
const markdownFiles = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = path.join(dir, entry.name);
  if (entry.isDirectory()) return markdownFiles(full);
  return entry.name.endsWith('.md') ? [full] : [];
});

const MD = 'Zensu renders headings, lists and code, so write structured Markdown, not one unformatted paragraph';
const PLAIN = 'plain text: Zensu does not render Markdown there, so do not use Markdown syntax';
const FILE_FORM = '"$(cat "$';
const JSON_ESCAPE = 'write each line break as `\\n` and escape every `"` and `\\` with a backslash';
const TRAP_E = `trap 'rm -f "$f" "$e"' EXIT`;
const TRAP_D = `trap 'rm -f "$f" "$d"' EXIT`;
const GUARD = `grep -qI -e '[^[:space:]]' -- "$f"`;
const FENCE_GUARD = `${GUARD} || exit 1`;
const pair = (file) => `${GUARD} && grep -qI -e '[^[:space:]]' -- "${file}" || exit 1`;
const OWN_CHECK = 'check each file with its own `grep`, since one `grep` over both passes when either holds text';
const OTHER_STATUS = 'For any other status, drop the `c` lines (its `mktemp`, its widened trap and its heredoc), the second `grep` and `--conditions`, so the guard reads';
const PLAN_PATH = ["p='<absolute-plan-file>'", `[ -f "$p" ] && grep -qI -e '[^[:space:]]' -- "$p" || exit 1`,'--content "$(cat -- "$p")"', 'never `~/…`', 'never name that file in a `trap`', 'PDF or Word file goes this way too'];
const SITES = [
  ['bootstrap/SKILL.md', 'Run `zensu products create`', MD, true, []],
  ['bootstrap/SKILL.md', 'Run `zensu products vision-create', null, true, PLAN_PATH],
  ['bootstrap/SKILL.md', 'Run `zensu products bootstrap-apply', MD, true, [JSON_ESCAPE]],
  ['bootstrap/SKILL.md', 'with `zensu features update <feature-id>`', MD, true, []],
  ['bootstrap/SKILL.md', 'Create approved journeys with', MD, true, []],
  ['bootstrap/SKILL.md', '`--description` and `--expected-result` are plain text', PLAIN, true, [TRAP_E]],
  ['bootstrap/SKILL.md', 'Run `zensu tiers create', PLAIN, true, []],
  ['ghost-scan/SKILL.md', 'Run `zensu ghost scan', null, true, []],
  ['ghost-scan/SKILL.md', "A candidate's optional `description`", MD, false, [JSON_ESCAPE, "the scan's review page shows it unrendered"]],
  ['ghost-scan/SKILL.md', 'Optionally provide `--reject-reason`', PLAIN, true, []],
  ['ghost-scan/SKILL.md', 'per approved journey', MD, true, []],
  ['ghost-scan/SKILL.md', 'per step (`--step-order`', PLAIN, true, [TRAP_E]],
  ['security-review/SKILL.md', '`--findings` and `--conditions` are Markdown', MD, true, []],
  ['implement/SKILL.md', 'Publish with `zensu wiki create', null, true, []],
  ['implement/SKILL.md', '`--scope-summary` and `--scope-details` are plain text', PLAIN, true, [TRAP_D]],
];
const RECIPE_RULES = ['one recipe per shell call', '12 random hex digits you pick once the text is final', 'check that no line of the text equals the delimiter', GUARD, 'before an empty, blank or binary value reaches Zensu'];
const SHORT_RULE = "write each apostrophe in it as `'\\''`";
const RECIPE_SKILLS = [
  ['bootstrap/SKILL.md', [...RECIPE_RULES, SHORT_RULE, FENCE_GUARD, OWN_CHECK, pair('$e')]],
  ['ghost-scan/SKILL.md', [...RECIPE_RULES, SHORT_RULE, FENCE_GUARD, OWN_CHECK, pair('$e')]],
  ['security-review/SKILL.md', [...RECIPE_RULES, pair('$c'), OTHER_STATUS, FENCE_GUARD]],
  ['implement/SKILL.md', [...RECIPE_RULES, SHORT_RULE, FENCE_GUARD, OWN_CHECK, pair('$d')]],
];

const blocksOf = (raw) => {
  const blocks = [];
  let current = [];
  for (const line of raw.split('\n')) {
    const starts = /^\s*$/.test(line) || /^\s*([-*]|\d+\.)\s/.test(line) || /^#/.test(line) || /^\s*```/.test(line);
    if (starts && current.length) {
      blocks.push(current.join(' '));
      current = [];
    }
    if (!/^\s*$/.test(line)) current.push(line.trim());
  }
  if (current.length) blocks.push(current.join(' '));
  return blocks;
};

for (const [rel, anchor, phrase, fileForm, extras] of SITES) {
  const hits = blocksOf(skill(rel)).filter((block) => block.includes(anchor));
  const block = hits[0] || '';
  const missing = extras.filter((extra) => !block.includes(extra));
  const ok = hits.length === 1 && (!phrase || block.includes(phrase)) && (!fileForm || block.includes(FILE_FORM)) && missing.length === 0;
  const states = [phrase === MD ? 'the Markdown sentence' : phrase === PLAIN ? 'the plain-text sentence' : '', fileForm ? 'the file form' : '', ...extras]
    .filter(Boolean).join(' and ');
  check(`F1 ${rel}: "${anchor}" carries ${states}`, ok, [`blocks holding the anchor: ${hits.length}`, `missing: ${missing.join(' | ') || 'none'}`, block.slice(0, 400)]);
}
for (const [rel, rules] of RECIPE_SKILLS) {
  const blocks = blocksOf(skill(rel));
  const missing = rules.filter((rule) => !blocks.some((block) => block.includes(rule)));
  check(`F1 ${rel} states the recipe rules (${rules.length})`, missing.length === 0, [`missing: ${missing.join(' | ')}`]);
}

const FLAGS = 'content|description|expected-result|findings|conditions|scope-summary|scope-details|result|candidates|reject-reason';
const INLINE = new RegExp(`--(?:${FLAGS})(?:=|\\s+)(?:"<[^"\\n]*>"|'<[^'\\n]*>'|<[^\\s>]+>)`);
const SHORT = /--(?:title|name|persona)(?:=|\s+)(?:"<[^"\n]*>"|<[^\s>]+>)/;
const NESTED = /\$\(\s*cat\s*<</;
const DELIMITER = /(?<!<)<<(?!<)(?!'ZENSU_TEXT_<hex>'(?!\S))-?\s*[\\'"]?[\w$]/;
const PLAIN_WRITE = /^(?=.*<<)(?=.*(?<![>|])>(?![>|&])\s*"\$\{?\w+\}?")/;
const SIZE_ONLY = /\[\s+-s\s/;
const TWO_FILES = /\bgrep\b[^|&;\n]*'\[\^\[:space:\]\]'[^|&;\n]*\s"\$\{?\w+\}?"\s+"\$\{?\w+\}?"/;
const lint = (lines) => lines.flatMap((line, index) => ([INLINE, SHORT, NESTED, DELIMITER, PLAIN_WRITE, SIZE_ONLY, TWO_FILES].some((rule) => rule.test(line)) ? [index + 1] : []));
const BAD = [
  'zensu wiki create --product <product-id> --content "<authored-markdown>"',
  "zensu ghost scan --product <product-id> --candidates '<json>'",
  'zensu products vision-create --content <plan-document> --source codex',
  'zensu security review <feature-id> --findings="<findings-summary>"',
  'zensu journeys step <journey-id> --expected-result "<expected result>"',
  'zensu ghost batch <scan-id> --reject-reason "<reason>"',
  'zensu wiki create --product <product-id> --title <title> --content "$(cat "$f")"',
  'zensu journeys create --product <product-id> --title "<title>"',
  "zensu features revision <feature-id> --scope-summary \"$(cat <<'EOF'",
  "cat > \"$f\" <<'ZENSU_TEXT_<hex>'",
  "cat >| \"$f\" <<'ZENSU_TEXT_END'",
  "cat >| \"$f\" <<'EOF'",
  "cat >| \"$f\" <<ZENSU_TEXT_<hex>",
  "cat >| \"$f\" <<\\ZENSU_TEXT_END",
  "cat >| \"$f\" <<-'ZENSU_TEXT_<hex>'",
  "cat <<'ZENSU_TEXT_<hex>' > \"$f\"",
  "cat 1> \"$f\" <<'ZENSU_TEXT_<hex>'",
  '[ -s "$f" ] || exit 1',
  'check both with `[ -s … ]`',
  "grep -qI -e '[^[:space:]]' -- \"$f\" \"$e\" || exit 1",
];
const GOOD = [
  "zensu journeys create --product <product-id> --title '<title>' --description \"$(cat \"$f\")\"",
  '- `--scope-details` (optional): Detailed scope description',
  'zensu security review <feature-id> --reviewer <reviewer> --status <status>',
  '<the text, unchanged>',
  "cat >| \"$f\" <<'ZENSU_TEXT_<hex>'",
  'zensu products vision-create --product <product-id> --content "$(cat -- "$p")" --source codex',
  FENCE_GUARD,
  pair('$e'),
  PLAN_PATH[1],
  'grep -q "$pattern" "$file"',
];
check('F2 the lint flags every inline placeholder form, an unquoted or double-quoted title, a heredoc nested in $(...), a heredoc delimiter other than the quoted ZENSU_TEXT_<hex> placeholder, a plain > heredoc write in either order, a size-only [ -s guard and one grep over two files, and passes the file form',
  lint(BAD).length === BAD.length && lint(GOOD).length === 0,
  [`bad lines flagged: ${lint(BAD).join(',')}`, `good lines flagged: ${lint(GOOD).join(',') || 'none'}`]);
const files = [...markdownFiles(skillsDir), ...markdownFiles(path.join(pluginDir, 'docs'))];
const inline = files.flatMap((file) => lint(read(file).split('\n')).map((line) => `${path.relative(pluginDir, file)}:${line}`));
check(`F2 no skill or doc passes free text or JSON inline, nests a heredoc in $(...), uses another heredoc delimiter, a plain > heredoc write, a size-only guard or one grep over two files (${files.length} Markdown files)`, inline.length === 0, inline);

const PROBE = [
  '## Probe `echo INJECTED` heading',
  "- user's $HOME, $(echo INJECTED), ${PATH} and \"quoted\" text",
  '- back\\slash, *glob* and a tab:\there',
  '- naïve café, a résumé, 5 € and “curly” quotes',
  '```js',
  'const x = `template ${y}`;',
  '```',
].join('\n');
const shells = [fs.existsSync('/bin/bash') ? '/bin/bash' : 'bash'];
if (spawnSync('zsh', ['-f', '-c', 'exit 0']).status === 0) shells.push('zsh');
else if (process.platform === 'darwin') check('F3 zsh is available on macOS', false, ['macOS ships zsh, so the zsh leg must run here']);
else console.log('  SKIP  F3 zsh is not installed, so the recipes run under bash only');
const version = (shell) => (spawnSync(shell, shell === 'zsh' ? ['-f', '-c', 'echo $ZSH_VERSION'] : ['-c', 'echo $BASH_VERSION'], { encoding: 'utf8' }).stdout || '').trim();
console.log(`  INFO  F3 shells: ${shells.map((shell) => `${shell} ${version(shell)}`).join(', ')}`);
const env = { ...process.env };
delete env.BASH_ENV;
delete env.ENV;
const prelude = 'zensu() { for a in "$@"; do printf \'%s\\0\' "$a"; done >| "$ZENSU_PROBE_OUT"; }\n'
  + 'mktemp() { n=$(( $(cat "$ZENSU_PROBE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" >| "$ZENSU_PROBE_COUNT"; '
  + '[ "$n" = "$ZENSU_MKTEMP_FAIL_AT" ] && return 1; command mktemp "$@" | tee -a "$ZENSU_PROBE_TEMPS"; }\n';
const fill = (recipe, bodyFor) => {
  let index = 0;
  return recipe
    .replace(/(<<'(ZENSU_TEXT_[^'\n]+)'\n)[\s\S]*?^(\2)$/gm, (match, open, delimiter, close) => {
      const body = bodyFor(index);
      index += 1;
      return body === '' ? `${open}${close}` : `${open}${body}\n${close}`;
    })
    .replace(/<([a-z][a-z0-9-]*)>/g, 'X-$1');
};
const runRecipe = (shell, noclobber, recipe, failAt) => {
  const guard = noclobber ? (shell === 'zsh' ? 'setopt noclobber\n' : 'set -C\n') : '';
  const script = guard + prelude + recipe;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-file-form-'));
  const out = path.join(work, 'args');
  const tempLog = path.join(work, 'temps');
  const argv = shell === 'zsh' ? ['-f', '-c', script] : ['-c', script];
  const run = spawnSync(shell, argv, { encoding: 'utf8', env: { ...env, ZENSU_PROBE_OUT: out, ZENSU_PROBE_TEMPS: tempLog, ZENSU_PROBE_COUNT: path.join(work, 'count'), ZENSU_MKTEMP_FAIL_AT: String(failAt) } });
  const args = fs.existsSync(out) ? fs.readFileSync(out, 'utf8').split('\0').slice(0, -1) : null;
  const temps = fs.existsSync(tempLog) ? fs.readFileSync(tempLog, 'utf8').split('\n').filter(Boolean) : [];
  const leftovers = temps.filter((file) => fs.existsSync(file));
  for (const file of leftovers) fs.rmSync(file, { force: true });
  fs.rmSync(work, { recursive: true, force: true });
  return { status: run.status, stderr: (run.stderr || '').trim(), args, temps, leftovers };
};
for (const [rel] of RECIPE_SKILLS) {
  const recipes = [...skill(rel).matchAll(/^```bash\n([\s\S]*?)^```$/gm)]
    .map((match) => match[1])
    .filter((body) => body.includes("<<'ZENSU_TEXT_"));
  if (recipes.length !== 1) {
    check(`F3 ${rel} holds exactly one top-level file-form recipe`, false, [`recipes found: ${recipes.length}`]);
    continue;
  }
  const bodies = (recipes[0].match(/<<'ZENSU_TEXT_[^'\n]+'$/gm) || []).length;
  const mktemps = (recipes[0].match(/\$\(mktemp\)/g) || []).length;
  const probes = Array.from({ length: bodies }, (unused, index) => `${PROBE}\n- body ${index + 1}`);
  const success = fill(recipes[0], (index) => probes[index]);
  const failures = [['every value empty', fill(recipes[0], () => ''), 0]];
  if (bodies > 1) failures.push(['every value blank', fill(recipes[0], () => ' \t\n\t '), 0]);
  for (let empty = 0; empty < bodies; empty += 1) {
    if (bodies > 1) failures.push([`value ${empty + 1} of ${bodies} empty`, fill(recipes[0], (index) => (index === empty ? '' : probes[index])), 0]);
    failures.push([`value ${empty + 1} of ${bodies} blank`, fill(recipes[0], (index) => (index === empty ? ' \t\n\t ' : probes[index])), 0]);
  }
  for (let call = 1; call <= mktemps; call += 1) failures.push([`mktemp failing on call ${call}`, success, call]);
  for (const shell of shells) {
    for (const noclobber of [false, true]) {
      const mode = `${shell}${noclobber ? ' with noclobber' : ''}`;
      const ok = runRecipe(shell, noclobber, success, 0);
      const args = ok.args || [];
      const handed = args.filter((arg, index) => index > 0 && args[index - 1].startsWith('--') && probes.includes(arg));
      const inOrder = handed.length === bodies && handed.every((arg, index) => arg === probes[index]);
      check(`F3 ${rel} recipe under ${mode} hands ${bodies} value(s) unchanged to their own flags in order, one temp file each, and removes them`,
        ok.status === 0 && bodies > 0 && inOrder && ok.temps.length === bodies && ok.leftovers.length === 0,
        [`exit ${ok.status}`, `values handed to their own flag: ${handed.length}/${bodies}, in order: ${inOrder}`, `temp files created: ${ok.temps.length}`, `temp files left: ${ok.leftovers.join(', ') || 'none'}`, ok.stderr]);
      const broken = failures
        .map(([name, recipe, failAt]) => [name, runRecipe(shell, noclobber, recipe, failAt)])
        .filter(([, result]) => result.status === 0 || result.args !== null || result.leftovers.length > 0)
        .map(([name, result]) => `${name}: exit ${result.status}, zensu called: ${result.args !== null}, temp files left: ${result.leftovers.length}`);
      check(`F3 ${rel} recipe under ${mode} stops before zensu and leaves no temp file in ${failures.length} failure case(s)`, broken.length === 0, broken);
    }
  }
}

const planDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-by-path-'));
const planFile = (name, content) => {
  const file = path.join(planDir, name);
  fs.writeFileSync(file, content);
  return file;
};
const byPath = (file) => [PLAN_PATH[0].replace('<absolute-plan-file>', file), PLAN_PATH[1], `zensu products vision-create --product X-product-id ${PLAN_PATH[2]} --source codex`].join('\n');
const plan = planFile('plan.md', `${PROBE}\n`);
const locked = planFile('locked.md', `${PROBE}\n`);
fs.chmodSync(locked, 0);
let lockedReadable = true;
try { fs.readFileSync(locked); } catch { lockedReadable = false; }
const blocked = [
  ['a missing path', path.join(planDir, 'missing.md')],
  ['an empty file', planFile('empty.md', '')],
  ['a newline-only file', planFile('newlines.md', '\n\n')],
  ['a blank file', planFile('blank.md', ' \t\n\n\t \n')],
  ['a binary file', planFile('binary.pdf', Buffer.from('%PDF-1.4\n\0\0binary\0 data\n', 'latin1'))],
  ['a directory', planDir],
  ...(lockedReadable ? [] : [['an unreadable file', locked]]),
];
for (const shell of shells) {
  const ok = runRecipe(shell, false, byPath(plan), 0);
  const handed = ok.args || [];
  const at = handed.indexOf('--content');
  check(`F3 bootstrap/SKILL.md by-path form under ${shell} hands the plan file to --content unchanged`,
    ok.status === 0 && at >= 0 && handed[at + 1] === PROBE,
    [`exit ${ok.status}`, `zensu called: ${ok.args !== null}`, ok.stderr]);
  const leaks = blocked
    .map(([name, file]) => [name, runRecipe(shell, false, byPath(file), 0)])
    .filter(([, result]) => result.status === 0 || result.args !== null)
    .map(([name, result]) => `${name}: exit ${result.status}, zensu called: ${result.args !== null}`);
  check(`F3 bootstrap/SKILL.md by-path form under ${shell} stops before zensu for ${blocked.map(([name]) => name).join(', ')}`, leaks.length === 0, leaks);
}
fs.chmodSync(locked, 0o600);
fs.rmSync(planDir, { recursive: true, force: true });

const SHOWS = /(?<!not |never |n't )\b(?:shows?|displays?|renders?)\b[^.\n]*\bstep descriptions?\b|\bstep descriptions?\b[^.\n]*\b(?:is|are) (?:shown|displayed|rendered)\b/i;
const CLAIMS = ['Zensu shows the step description on the journey page', 'The step description is displayed in the journey timeline'];
const DENIALS = ['Zensu does not show a step description', 'The step `--description` is plain text: Zensu does not render Markdown there, so do not use Markdown syntax'];
check('F4 the step-description check flags a display claim and passes a denial',
  CLAIMS.every((line) => SHOWS.test(line)) && !DENIALS.some((line) => SHOWS.test(line)));
const claims = files.flatMap((file) => read(file).split('\n')
  .flatMap((line, index) => (SHOWS.test(line) ? [`${path.relative(pluginDir, file)}:${index + 1}`] : [])));
check('F4 no skill or doc claims that Zensu shows a journey step description', claims.length === 0, claims);

console.log('----');
console.log(`test-skill-text-formats: ${pass} PASS / ${fail} FAIL`);
process.exit(fail === 0 ? 0 : 1);
NODE
