'use strict';

const CHILDREN = new Set();
const state = { stopping: false };

function settledWithin(promise, ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), ms);
    promise.then(() => {
      clearTimeout(timer);
      resolve(true);
    });
  });
}

function signalGroup(child, signal) {
  if (!child.pid) return false;
  try {
    process.kill(-child.pid, signal);
    return true;
  } catch {
    try {
      return child.kill(signal);
    } catch {
      return false;
    }
  }
}

function groupAlive(child) {
  if (!child.pid) return false;
  try {
    process.kill(-child.pid, 0);
    return true;
  } catch {
    return false;
  }
}

function track(child) {
  const entry = {
    child,
    closed: new Promise((resolve) => {
      child.once('close', resolve);
      child.once('error', resolve);
    }),
  };
  CHILDREN.add(entry);
  return entry;
}

function untrack(entry) {
  CHILDREN.delete(entry);
}

async function reapGroup(child, graceMs = 500) {
  if (!groupAlive(child)) return false;
  signalGroup(child, 'SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, graceMs));
  if (groupAlive(child)) signalGroup(child, 'SIGKILL');
  return true;
}

async function stopChildren({ graceMs = 3000 } = {}) {
  const entries = [...CHILDREN];
  for (const entry of entries) signalGroup(entry.child, 'SIGTERM');
  const closed = Promise.all(entries.map((entry) => entry.closed));
  if (!(await settledWithin(closed, graceMs))) {
    for (const entry of entries) signalGroup(entry.child, 'SIGKILL');
    await settledWithin(closed, graceMs);
  }
  for (const entry of entries) if (groupAlive(entry.child)) signalGroup(entry.child, 'SIGKILL');
  return entries.length;
}

function killChildren() {
  for (const entry of CHILDREN) signalGroup(entry.child, 'SIGKILL');
}

module.exports = { CHILDREN, state, settledWithin, signalGroup, groupAlive, track, untrack, reapGroup, stopChildren, killChildren };
