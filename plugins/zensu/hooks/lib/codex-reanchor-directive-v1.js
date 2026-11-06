'use strict';

const MAX_DIRECTIVE_LENGTH = 256;
const REANCHOR_DIRECTIVE = 'zensu reanchor';
const DISCARD_OPEN_WORK = '--discard-open-work';
const PROJECT_MISMATCH = 'ZENSU_PROJECT_MISMATCH';
const REANCHOR_HINT = `This chat works in another directory than the project root Zensu Session Control is anchored to. If it moved to another worktree of the same repository, only the user can move the anchor there, by sending the message \`${REANCHOR_DIRECTIVE}\` on its own; otherwise start a new chat in this directory.`;

function projectMismatch(message) {
  return Object.assign(new Error(message), { code: PROJECT_MISMATCH });
}

function reanchorRequest(prompt) {
  if (typeof prompt !== 'string' || prompt.length > MAX_DIRECTIVE_LENGTH) return null;
  const words = prompt.trim().toLowerCase().split(/\s+/);
  if (words.length < 2 || words.length > 3 || words[0] !== 'zensu' || !['reanchor', 're-anchor'].includes(words[1])) return null;
  if (words.length === 2) return { discardOpenWork: false };
  return words[2] === DISCARD_OPEN_WORK ? { discardOpenWork: true } : null;
}

module.exports = {
  REANCHOR_DIRECTIVE,
  DISCARD_OPEN_WORK,
  PROJECT_MISMATCH,
  REANCHOR_HINT,
  projectMismatch,
  reanchorRequest,
};
