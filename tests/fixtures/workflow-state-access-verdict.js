'use strict';

const fs = require('node:fs');
const path = require('node:path');

const READERS = new Set(['inspectWorkflowState', 'readWorkflowState', 'inspectSessionFile']);
const WRITERS = new Set(['writeSessionFile']);

function parseArguments(argv) {
  const options = { report: argv[0], only: '', opened: '', within: '', writer: '' };
  if (!options.report) {
    throw new Error('usage: workflow-state-access-verdict.js <report> [--only <text>] [--opened <file>] [--within <reader>] [--writer <writer>]');
  }
  for (let index = 1; index < argv.length; index += 2) {
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${argv[index]} needs a value`);
    if (argv[index] === '--only') options.only = value;
    else if (argv[index] === '--opened') options.opened = value;
    else if (argv[index] === '--within' && READERS.has(value)) options.within = value;
    else if (argv[index] === '--writer' && WRITERS.has(value)) options.writer = value;
    else throw new Error(`unknown argument ${argv[index]} ${value}`);
  }
  return options;
}

function realpathOrNull(file) {
  try {
    return fs.realpathSync.native(file);
  } catch {
    return null;
  }
}

function spellings(file) {
  const parent = realpathOrNull(path.dirname(file));
  return new Set([path.resolve(file), realpathOrNull(file), parent && path.join(parent, path.basename(file))]
    .filter(Boolean)
    .map((name) => name.toLowerCase()));
}

function describe(access) {
  return `${access.call}(${access.paths.join(', ')}) in [${access.scope.join(' > ') || 'no core export'}]`;
}

function judge(options) {
  const reports = fs.readFileSync(options.report, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const problems = [];
  if (reports.length === 0) problems.push('no probed process reported');
  for (const report of reports) {
    for (const fault of report.faults) problems.push(`probe fault: ${fault}`);
  }
  const accesses = reports
    .flatMap((report) => report.accesses)
    .filter((access) => access.paths.some((entry) => entry.includes(options.only)));
  if (accesses.length === 0) problems.push('no workflow-state access was observed');
  for (const access of accesses) {
    if (options.writer && access.scope.includes(options.writer)) continue;
    if (!READERS.has(access.scope[access.scope.length - 1])) problems.push(`outside the core reader: ${describe(access)}`);
    if (access.mutating) problems.push(`creates or changes: ${describe(access)}`);
  }
  if (options.writer && !accesses.some((access) => access.mutating && access.scope.includes(options.writer))) {
    problems.push(`no creating access ran inside ${options.writer}`);
  }
  if (options.opened) {
    const wanted = spellings(options.opened);
    const opened = accesses.some((access) => access.call === 'openSync'
      && access.paths.some((entry) => wanted.has(entry.toLowerCase())));
    if (!opened) problems.push(`the core reader never opened ${options.opened}`);
  }
  if (options.within && !accesses.some((access) => access.scope[access.scope.length - 1] === options.within)) {
    problems.push(`no workflow-state access ran inside ${options.within}`);
  }
  return { problems, count: accesses.length, writer: options.writer };
}

try {
  const { problems, count, writer } = judge(parseArguments(process.argv.slice(2)));
  if (problems.length > 0) {
    process.stdout.write(`${problems.join('; ')}\n`);
    process.exitCode = 1;
  } else if (writer) {
    process.stdout.write(`clean: ${count} workflow-state accesses, every creating one inside ${writer}, every other inside ${writer} or the core reader\n`);
  } else {
    process.stdout.write(`clean: ${count} workflow-state accesses, all inside the core reader, none creating\n`);
  }
} catch (error) {
  process.stdout.write(`verdict failed: ${error.message}\n`);
  process.exitCode = 2;
}
