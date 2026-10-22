'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const NATIVE_MAGIC = ['cffaedfe', 'cefaedfe', '7f454c46', 'feedfacf'];

function resolveCodex(explicit) {
  const bin = explicit ? path.resolve(explicit) : 'codex';
  const result = spawnSync(bin, ['--version'], { encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(`cannot run ${bin} --version`);
  const match = /(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\s*$/.exec(result.stdout.trim());
  if (!match) throw new Error(`unrecognized codex version output: ${result.stdout.trim()}`);
  return { bin, version: match[1] };
}

function nativeBinary(bin) {
  let entry = bin;
  if (!path.isAbsolute(entry)) {
    const which = spawnSync('which', [entry], { encoding: 'utf8' });
    entry = which.stdout.trim();
  }
  entry = fs.realpathSync(entry);
  const head = Buffer.alloc(4);
  const fd = fs.openSync(entry, 'r');
  fs.readSync(fd, head, 0, 4, 0);
  fs.closeSync(fd);
  if (NATIVE_MAGIC.includes(head.toString('hex'))) return { binary: entry, packageRoot: null };
  const packageRoot = path.dirname(path.dirname(entry));
  const stack = [path.join(packageRoot, 'node_modules'), ...fs.readdirSync(path.dirname(packageRoot)).filter((name) => name.startsWith(`${path.basename(packageRoot)}-`)).map((name) => path.join(path.dirname(packageRoot), name))];
  while (stack.length) {
    const dir = stack.pop();
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const item of entries) {
      const full = path.join(dir, item.name);
      if (item.isDirectory()) stack.push(full);
      else if (item.name === 'codex' && path.basename(path.dirname(full)) === 'bin' && full.includes(`${path.sep}vendor${path.sep}`)) return { binary: full, packageRoot };
    }
  }
  return { binary: null, packageRoot };
}

function binaryStrings(binary, strings) {
  if (!binary) return Object.fromEntries(Object.keys(strings).map((key) => [key, null]));
  const buffer = fs.readFileSync(binary);
  return Object.fromEntries(Object.entries(strings).map(([key, text]) => [key, buffer.indexOf(Buffer.from(text, 'utf8')) !== -1]));
}

module.exports = { resolveCodex, nativeBinary, binaryStrings };
