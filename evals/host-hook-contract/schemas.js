'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { resolveCodex, nativeBinary } = require('./codex-binary');

const SCHEMAS_DIR = path.join(__dirname, 'schemas');
const MARKER = /([a-z-]+)\.command\.(input|output)\{/g;
const TITLE = /^[a-z]+(?:-[a-z]+)*\.command\.(?:input|output)$/;

function objectEnd(text, start) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

function extractSchemas(buffer) {
  const text = buffer.toString('utf8');
  const schemas = new Map();
  for (const hit of text.matchAll(MARKER)) {
    const start = hit.index + hit[0].length - 1;
    const end = objectEnd(text, start);
    if (end === -1) throw new Error(`unterminated schema near ${hit[0]}`);
    let parsed;
    try {
      parsed = JSON.parse(text.slice(start, end));
    } catch (error) {
      throw new Error(`invalid schema JSON near ${hit[0]}: ${error.message}`);
    }
    const title = parsed.title;
    if (typeof title !== 'string' || !TITLE.test(title)) throw new Error(`schema without a usable title near ${hit[0]}`);
    const [name, , direction] = title.split('.');
    if (direction !== hit[2] || !hit[1].endsWith(name)) throw new Error(`schema title ${title} disagrees with marker ${hit[0]}`);
    schemas.set(title, parsed);
  }
  if (schemas.size === 0) throw new Error('no hook schema markers found');
  return schemas;
}

function render(schema) {
  return `${JSON.stringify(schema, null, 2)}\n`;
}

function readRecorded(dir) {
  if (!fs.existsSync(dir)) return null;
  const recorded = new Map();
  for (const name of fs.readdirSync(dir).filter((file) => file.endsWith('.json')).sort()) {
    recorded.set(name.replace(/\.json$/, ''), fs.readFileSync(path.join(dir, name), 'utf8'));
  }
  return recorded;
}

function compareSchemas(recorded, extracted) {
  const problems = [];
  if (!recorded) return ['no recorded schemas for this version'];
  for (const title of [...new Set([...recorded.keys(), ...extracted.keys()])].sort()) {
    if (!recorded.has(title)) problems.push(`new in binary: ${title}`);
    else if (!extracted.has(title)) problems.push(`missing from binary: ${title}`);
    else if (recorded.get(title) !== render(extracted.get(title))) problems.push(`changed: ${title}`);
  }
  return problems;
}

function writeSchemas(dir, extracted) {
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  for (const [title, schema] of [...extracted.entries()].sort()) fs.writeFileSync(path.join(dir, `${title}.json`), render(schema));
}

function main() {
  const args = process.argv.slice(2);
  let codexArg = null;
  let check = false;
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--codex' && args[i + 1] && !args[i + 1].startsWith('--')) {
      codexArg = args[i + 1];
      i += 1;
    } else if (args[i] === '--check') check = true;
    else throw new Error(`unknown argument: ${args[i]}`);
  }
  const codex = resolveCodex(codexArg);
  const native = nativeBinary(codex.bin);
  if (!native.binary) throw new Error(`no native codex binary found for ${codex.bin}`);
  const extracted = extractSchemas(fs.readFileSync(native.binary));
  const dir = path.join(SCHEMAS_DIR, codex.version);
  if (check) {
    const problems = compareSchemas(readRecorded(dir), extracted);
    for (const problem of problems) process.stdout.write(`  DRIFT  ${problem}\n`);
    process.stdout.write(problems.length
      ? `schemas: codex ${codex.version} disagrees with schemas/${codex.version}/\n`
      : `schemas: ${extracted.size} schemas match codex ${codex.version}\n`);
    process.exitCode = problems.length ? 1 : 0;
    return;
  }
  writeSchemas(dir, extracted);
  process.stdout.write(`schemas: wrote ${extracted.size} schemas from codex ${codex.version} to schemas/${codex.version}/\n`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`schemas: ${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = { extractSchemas, compareSchemas, readRecorded, render };
