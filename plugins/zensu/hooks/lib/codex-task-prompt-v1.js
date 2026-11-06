#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const { reanchorRequest } = require('./codex-reanchor-directive-v1.js');

function taskPrompt(raw) {
  let prompt = '';
  try {
    const payload = JSON.parse(raw);
    if (typeof payload.prompt === 'string') prompt = payload.prompt;
  } catch {
    return '';
  }
  return reanchorRequest(prompt) ? '' : prompt;
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch {
    return '';
  }
}

module.exports = { taskPrompt };

if (require.main === module) process.stdout.write(taskPrompt(readStdin()));
