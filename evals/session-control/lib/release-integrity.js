#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function canonicalDirectory(input, label) {
  if (typeof input !== 'string' || input.trim() === '') throw new Error(`${label} is required`);
  const directory = fs.realpathSync.native(input);
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory`);
  return directory;
}

function verifyRuntimeProvenance(repoRootInput, installedPluginRootInput) {
  const repoRoot = canonicalDirectory(repoRootInput, 'release repository root');
  const sourcePluginRoot = canonicalDirectory(path.join(repoRoot, 'plugins', 'zensu'), 'release source plugin root');
  const installedPluginRoot = canonicalDirectory(installedPluginRootInput, 'installed plugin root');
  if (installedPluginRoot === sourcePluginRoot
      || installedPluginRoot.startsWith(`${repoRoot}${path.sep}`)) {
    throw new Error('installed plugin root must be an independent installer-produced runtime');
  }
  const corePath = path.join(sourcePluginRoot, 'hooks', 'lib', 'session-control-core-v1.js');
  const stat = fs.lstatSync(corePath);
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size === 0) throw new Error('release source runtime core is invalid');
  const core = require(corePath);
  const sourceRuntimeDigest = core.computeRuntimeDigest(sourcePluginRoot, 'codex');
  const installedRuntimeDigest = core.computeRuntimeDigest(installedPluginRoot, 'codex');
  if (installedRuntimeDigest !== sourceRuntimeDigest) {
    throw new Error(`installed runtime provenance mismatch: source ${sourceRuntimeDigest}, installed ${installedRuntimeDigest}`);
  }
  return {
    source_plugin_root: sourcePluginRoot,
    installed_plugin_root: installedPluginRoot,
    source_runtime_digest: sourceRuntimeDigest,
    installed_runtime_digest: installedRuntimeDigest,
  };
}

function verifyReleaseIntegrity(repoRootInput, expectedRevision, installedPluginRootInput) {
  if (!/^[a-f0-9]{40,64}$/.test(expectedRevision || '')) {
    throw new Error('release source revision must be an exact Git SHA');
  }
  const repoRoot = canonicalDirectory(repoRootInput, 'release repository root');
  const git = (...args) => execFileSync('git', ['-C', repoRoot, ...args], { encoding: 'utf8' }).trim();
  const actualRevision = git('rev-parse', 'HEAD');
  if (actualRevision !== expectedRevision) {
    throw new Error(`release source revision mismatch: expected ${expectedRevision}, got ${actualRevision}`);
  }
  // Deliberately include untracked files. Runtime assets under hooks/agents/skills
  // participate in the digest and therefore must be committed at the attested SHA.
  const status = git('status', '--porcelain');
  if (status !== '') throw new Error(`release worktree is not exact-SHA clean:\n${status}`);
  const provenance = installedPluginRootInput
    ? verifyRuntimeProvenance(repoRoot, installedPluginRootInput)
    : undefined;
  return {
    repo_root: path.resolve(repoRoot),
    source_revision: actualRevision,
    ...(provenance || {}),
  };
}

module.exports = { verifyReleaseIntegrity, verifyRuntimeProvenance };

if (require.main === module) {
  try {
    if (!process.argv[4]) throw new Error('installed plugin root is required for the release provenance gate');
    const result = verifyReleaseIntegrity(process.argv[2], process.argv[3], process.argv[4]);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
