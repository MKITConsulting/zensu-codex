'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const NATIVE_MAGIC = ['cffaedfe', 'cefaedfe', '7f454c46', 'feedfacf'];
const VERSION_TIMEOUT_MS = 20000;
const CODEX_PACKAGE = '@openai/codex';
const [CODEX_SCOPE, CODEX_NAME] = CODEX_PACKAGE.split('/');

function runVersion(bin) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-hookprobe-version-'));
  try {
    const result = spawnSync(bin, ['--version'], {
      encoding: 'utf8',
      timeout: VERSION_TIMEOUT_MS,
      cwd: home,
      env: { PATH: process.env.PATH || '/usr/bin:/bin', HOME: home },
    });
    if (result.error || result.status !== 0 || result.signal) {
      const reason = result.error ? result.error.message : `exit status ${result.status}, signal ${result.signal}`;
      const tail = String(result.stderr || '').trim().split('\n').slice(-3).join(' | ');
      return { version: null, failure: `${reason}${tail ? `: ${tail}` : ''}` };
    }
    const match = /(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\s*$/.exec(String(result.stdout).trim());
    return match ? { version: match[1], failure: null } : { version: null, failure: `unrecognized version output: ${String(result.stdout).trim()}` };
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function resolveCodex(explicit) {
  const bin = explicit ? path.resolve(explicit) : 'codex';
  const { version, failure } = runVersion(bin);
  if (!version) throw new Error(`cannot run ${bin} --version: ${failure}`);
  return { bin, version };
}

function onPath(bin) {
  const which = spawnSync('which', [bin], { encoding: 'utf8', timeout: 5000 });
  const found = String(which.stdout || '').trim();
  if (which.status !== 0 || !found) throw new Error(`cannot find ${bin} on PATH`);
  return found;
}

function trusted(target, kind) {
  let stat;
  try {
    stat = fs.lstatSync(target);
  } catch {
    return false;
  }
  const uid = typeof process.getuid === 'function' ? process.getuid() : null;
  const owner = uid === null || stat.uid === uid || stat.uid === 0;
  const shape = kind === 'directory' ? stat.isDirectory() : stat.isFile();
  return shape && owner && (stat.mode & 0o022) === 0;
}

function codexPackage(dir) {
  const manifest = path.join(dir, 'package.json');
  if (!trusted(dir, 'directory') || !trusted(manifest, 'file')) return false;
  try {
    return JSON.parse(fs.readFileSync(manifest, 'utf8')).name === CODEX_PACKAGE;
  } catch {
    return false;
  }
}

function platformPackages(scope) {
  if (!trusted(scope, 'directory')) return [];
  let names = [];
  try {
    names = fs.readdirSync(scope);
  } catch {
    return [];
  }
  return names.filter((name) => name.startsWith(`${CODEX_NAME}-`)).sort().map((name) => path.join(scope, name)).filter(codexPackage);
}

function vendorCandidates(pkg) {
  const found = [];
  const stack = [path.join(pkg, 'vendor')];
  while (stack.length) {
    const dir = stack.pop();
    if (!trusted(dir, 'directory')) continue;
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const item of entries) {
      const full = path.join(dir, item.name);
      if (item.isDirectory()) stack.push(full);
      else if (item.name === 'codex' && path.basename(dir) === 'bin' && trusted(full, 'file')) found.push(full);
    }
  }
  return found.sort();
}

function nativeBinary(bin, version) {
  if (typeof version !== 'string' || !version) throw new Error('nativeBinary needs the version the native binary must report');
  const entry = fs.realpathSync(path.isAbsolute(bin) ? bin : onPath(bin));
  const verified = (candidate) => runVersion(candidate).version === version;
  const head = Buffer.alloc(4);
  const fd = fs.openSync(entry, 'r');
  fs.readSync(fd, head, 0, 4, 0);
  fs.closeSync(fd);
  if (NATIVE_MAGIC.includes(head.toString('hex'))) return { binary: verified(entry) ? entry : null, packageRoot: null };
  const packageRoot = path.dirname(path.dirname(entry));
  if (!codexPackage(packageRoot)) return { binary: null, packageRoot: null };
  const scope = path.dirname(packageRoot);
  const packages = [...platformPackages(path.join(packageRoot, 'node_modules', CODEX_SCOPE)), ...(path.basename(scope) === CODEX_SCOPE ? platformPackages(scope) : [])];
  const binary = packages.flatMap(vendorCandidates).find(verified) || null;
  return { binary, packageRoot };
}

function binaryStrings(binary, strings) {
  if (!binary) return Object.fromEntries(Object.keys(strings).map((key) => [key, null]));
  const buffer = fs.readFileSync(binary);
  return Object.fromEntries(Object.entries(strings).map(([key, text]) => [key, buffer.indexOf(Buffer.from(text, 'utf8')) !== -1]));
}

module.exports = { resolveCodex, nativeBinary, binaryStrings, runVersion };
