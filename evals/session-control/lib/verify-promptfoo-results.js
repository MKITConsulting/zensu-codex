#!/usr/bin/env node
'use strict';

const fs = require('node:fs');

function fail(message) {
  process.stderr.write(`session-control result verification: ${message}\n`);
  process.exit(1);
}

const [resultFile, catalogFile, suite, defaultRepeatRaw] = process.argv.slice(2);
if (!resultFile || !catalogFile || !suite || !defaultRepeatRaw) {
  fail('usage: verify-promptfoo-results.js <result.json> <catalog.yaml> <suite> <default-repeat>');
}
const defaultRepeat = Number(defaultRepeatRaw);
if (!Number.isSafeInteger(defaultRepeat) || defaultRepeat < 1 || defaultRepeat > 100) fail('invalid repeat');

let document;
try {
  document = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
} catch (error) {
  fail(`cannot parse result JSON: ${error.message}`);
}
const rows = document?.results?.results;
if (!Array.isArray(rows)) fail('results.results is missing');

const expected = new Map();
const catalog = fs.readFileSync(catalogFile, 'utf8');
for (const line of catalog.split(/\r?\n/)) {
  const id = /\bid:\s*([^,}\s]+)/.exec(line)?.[1];
  const rowSuite = /\bsuite:\s*([^,}\s]+)/.exec(line)?.[1];
  if (!id || rowSuite !== suite) continue;
  const repeatRaw = /\brepeat:\s*([0-9]+)/.exec(line)?.[1];
  const repeat = repeatRaw === undefined ? defaultRepeat : Number(repeatRaw);
  if (!Number.isSafeInteger(repeat) || repeat < 1 || repeat > 100) fail(`invalid catalog repeat for ${id}`);
  if (expected.has(id)) fail(`duplicate expected scenario id ${id}`);
  expected.set(id, repeat);
}
if (expected.size === 0) fail(`catalog contains no ${suite} scenarios`);

const actual = new Map();
for (const [index, row] of rows.entries()) {
  const id = row?.vars?.scenario_id ?? row?.testCase?.vars?.scenario_id;
  const rowSuite = row?.vars?.suite ?? row?.testCase?.vars?.suite;
  if (typeof id !== 'string' || id.length === 0) fail(`result ${index} has no scenario_id`);
  if (rowSuite !== suite) fail(`result ${index} belongs to suite ${String(rowSuite)}, expected ${suite}`);
  if (row.success !== true || row?.gradingResult?.pass !== true) fail(`scenario ${id} did not pass`);
  if (suite !== 'contract') {
    const output = row?.response?.output;
    if (typeof output !== 'string' || !/^\[control-attestation\] \{[^\r\n]*\}\n?$/.test(output)) {
      fail(`scenario ${id} emitted content outside its single wrapper-owned attestation line`);
    }
  }
  actual.set(id, (actual.get(id) || 0) + 1);
}

const expectedCount = [...expected.values()].reduce((sum, count) => sum + count, 0);
if (rows.length !== expectedCount) fail(`expected ${expectedCount} results, got ${rows.length}`);
for (const [id, count] of expected) {
  if (actual.get(id) !== count) fail(`scenario ${id}: expected ${count} result(s), got ${actual.get(id) || 0}`);
}
for (const id of actual.keys()) {
  if (!expected.has(id)) fail(`unexpected scenario id ${id}`);
}

process.stdout.write(`Promptfoo result audit: exact ${suite} scenario-id multiset (${expectedCount} results).\n`);
