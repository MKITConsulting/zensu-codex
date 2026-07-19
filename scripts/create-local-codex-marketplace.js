#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function fail(message) {
  process.stderr.write(`create-local-codex-marketplace: ${message}\n`);
  process.exit(1);
}

const [sourceInput, destinationInput] = process.argv.slice(2);
if (!sourceInput || !destinationInput) fail('usage: <source-checkout> <empty-destination>');
const source = fs.realpathSync.native(sourceInput);
const destination = path.resolve(destinationInput);
const pluginSource = path.join(source, 'plugins', 'zensu');
if (!fs.lstatSync(pluginSource).isDirectory()) fail('source plugin is missing');
if (fs.existsSync(destination) && fs.readdirSync(destination).length !== 0) {
  fail('destination must be absent or empty');
}

function copyTree(from, to) {
  const stat = fs.lstatSync(from);
  if (stat.isSymbolicLink()) fail(`symlink rejected: ${from}`);
  if (stat.isDirectory()) {
    fs.mkdirSync(to, { recursive: true, mode: stat.mode & 0o777 });
    for (const child of fs.readdirSync(from).sort()) copyTree(path.join(from, child), path.join(to, child));
    return;
  }
  if (!stat.isFile()) fail(`non-regular source rejected: ${from}`);
  fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
  if (process.platform !== 'win32') fs.chmodSync(to, stat.mode & 0o777);
}

fs.mkdirSync(path.join(destination, '.agents', 'plugins'), { recursive: true, mode: 0o700 });
copyTree(pluginSource, path.join(destination, 'plugins', 'zensu'));
const marketplace = {
  // Keep the production marketplace identity so CI exercises the exact
  // end-user install command (`zensu@zensu`). Only the source is local.
  name: 'zensu',
  interface: { displayName: 'Zensu' },
  plugins: [{
    name: 'zensu',
    displayName: 'Zensu',
    description: 'Ephemeral local fixture for validating the exact checked-out plugin bytes.',
    source: { source: 'local', path: './plugins/zensu' },
    category: 'productivity',
    policy: { installation: 'AVAILABLE', authentication: 'ON_INSTALL' },
  }],
};
fs.writeFileSync(
  path.join(destination, '.agents', 'plugins', 'marketplace.json'),
  `${JSON.stringify(marketplace, null, 2)}\n`,
  { flag: 'wx', mode: 0o600 },
);
process.stdout.write(`${destination}\n`);
