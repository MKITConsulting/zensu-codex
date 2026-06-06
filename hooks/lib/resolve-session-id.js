#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

function sanitizeProjectDir(p) {
  return String(p).replace(/[^A-Za-z0-9_-]/g, '-');
}

function projectsBase() {
  if (process.env.ZENSU_PROJECTS_DIR) return process.env.ZENSU_PROJECTS_DIR;
  return path.join(os.homedir(), '.claude', 'projects');
}

function listCandidates(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (_) {
    return [];
  }
  const out = [];
  for (const name of entries) {
    if (!name.endsWith('.jsonl')) continue;
    const full = path.join(dir, name);
    let mtimeMs;
    try {
      mtimeMs = fs.statSync(full).mtimeMs;
    } catch (_) {
      continue;
    }
    out.push({ name, full, mtimeMs });
  }
  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out;
}

function parseCutoffMs(arg) {
  if (!arg) return null;
  const s = String(arg).trim();
  if (!/^[0-9]+$/.test(s)) return null;
  if (s.length < 18) return null;
  try {
    return Number(BigInt(s) / 1000000n);
  } catch (_) {
    return null;
  }
}

function readTail(filePath, byteLen) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - byteLen);
    const len = size - start;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, start);
    return buf.toString('utf8');
  } catch (_) {
    return '';
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
  }
}

function main() {
  const helperStartMs = Date.now();
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const subdir = sanitizeProjectDir(projectDir);
  const projectsDir = path.join(projectsBase(), subdir);

  let files = listCandidates(projectsDir);

  const parsedCutoffMs = parseCutoffMs(process.argv[2]);
  const cutoffMs = parsedCutoffMs !== null ? parsedCutoffMs : helperStartMs;
  files = files.filter((f) => f.mtimeMs <= cutoffMs);

  if (files.length === 0) {
    process.stdout.write('');
    return 0;
  }

  if (files.length > 1 && process.env.ZENSU_OWN_CMD) {
    const needle = process.env.ZENSU_OWN_CMD;
    for (const f of files) {
      const tail = readTail(f.full, 4096);
      if (tail.indexOf(needle) !== -1) {
        process.stdout.write(f.name.replace(/\.jsonl$/, ''));
        return 0;
      }
    }
  }

  const first = files[0];
  process.stdout.write(first.name.replace(/\.jsonl$/, ''));
  return 0;
}

process.exit(main());
