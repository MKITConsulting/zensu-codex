'use strict';

// Only local CLI help/version is probed. Never authenticate, bind or submit here.
const cp = require('node:child_process');
const fs = require('node:fs');
const REQUIRED = Object.freeze({
  bind: ['product', 'confirm'],
  context: ['feature', 'feature-revision', 'cross-product'],
  start: ['id', 'title', 'product', 'feature', 'feature-revision', 'maintenance-reason', 'cross-product-reason', 'source', 'source-version', 'run-kind'],
  get: ['json'],
  submit: ['event-id', 'expected-version', 'artifact', 'criteria-version', 'review-file'],
});
const guidance = 'Run zensu update, then verify zensu --version and the executable selected by PATH. If update is unknown, use the original installer: Homebrew users run brew update then brew upgrade --cask mkitconsulting/tap/zensu; other users follow docs/cli-install-update.md. Do not replace a package-manager installation with another installer.';
function check(workspace, budgetMs = 8000) {
  const deadline = Date.now() + budgetMs;
  const env = { ...process.env, ZENSU_NO_UPDATE_CHECK: '1' };
  for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
  const call = args => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return null;
    try {
      const r = cp.spawnSync('zensu', args, { cwd: workspace, env, encoding: 'utf8',
        timeout: Math.min(2000, remaining), maxBuffer: 65536, windowsHide: true });
      return r && !r.error && r.status === 0 && typeof r.stdout === 'string' ? r.stdout : null;
    } catch { return null; }
  };
  const versionText = call(['--version']);
  const cliVersion = versionText?.match(/^zensu (v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)(?:\s|$)/)?.[1] ?? 'unknown';
  if (versionText === null) return { status: 'cli_unavailable', cliVersion, guidance };
  const missingCapabilities = [];
  for (const [command, flags] of Object.entries(REQUIRED)) {
    const output = call(['ai-work', command, '--help']);
    if (output === null) {
      missingCapabilities.push('ai-work ' + command);
      continue;
    }
    // Match declared flag rows, never examples or arbitrary prose containing flags.
    const declared = new Set([...output.matchAll(/^\s+(?:-[A-Za-z0-9],\s+)?--([a-z][a-z0-9-]*)(?=\s|$)/gm)].map(m => m[1]));
    for (const flag of flags) if (!declared.has(flag)) missingCapabilities.push(command + ' --' + flag);
  }
  return missingCapabilities.length ? { status: 'cli_incompatible', cliVersion, missingCapabilities, guidance } : { status: 'compatible', cliVersion };
}
function paused(file) {
  const marker = file + '.paused';
  let st;
  try { st = fs.lstatSync(marker); } catch (e) { if (e.code === 'ENOENT') return false; throw e; }
  if (!st.isFile() || st.isSymbolicLink() || st.size !== 7 || fs.readFileSync(marker, 'utf8') !== 'paused\n') throw new Error('Unsafe capture pause marker');
  return true;
}
function pause(file) {
  if (!paused(file)) fs.writeFileSync(file + '.paused', 'paused\n', { flag: 'wx', mode: 0o600 });
  return { status: 'capture_disabled', reason: 'No work report will be sent. Do not ask for product or feature confirmation unless the user explicitly enables reporting again.' };
}
function resume(file) {
  if (paused(file)) fs.unlinkSync(file + '.paused');
}
function instructions() {
  return "Before implementation of an authorized task, use this same native helper with preflight (the same workspace/session identity, without task/title/criteria). This performs bounded local CLI capability checks and a read-only context check; it never starts work. If product_confirmation_required or feature_confirmation_required is returned, ask one concise question naming the exact product and this goal's feature or explicit maintenance reason, using verified CLI context. Reuse a valid product binding; never infer confirmation from discovery, a repository name or 'use Zensu'. Only pass feature/revision or exception flags after explicit confirmation for this goal. If reporting was explicitly declined, use pause instead of preflight, ask no scope questions, and do not begin or checkpoint; pause is local and preserves pending reports. Only an explicitly re-enabled, confirmed begin resumes reporting. If CLI compatibility fails, report the missing capabilities and installation/update guidance immediately; never silently install, drop flags or downgrade the protocol. Keep coding when scope or compatibility is unavailable. Call a green automated review 'plugin code review passed', never human acceptance.";
}
module.exports = { check, paused, pause, resume, instructions };
