'use strict';

const TUI_STRINGS = {
  approvalQuestion: 'Implement this plan?',
  approvalPrompt: 'Implement the plan.',
  freshContextPrompt: 'A previous agent produced the plan below to accomplish the user',
};

const CONTEXT = {
  sessionStart: 'PROBE_SESSION_CONTEXT_MARKER',
  userPromptSubmit: 'PROBE_PROMPT_CONTEXT_MARKER',
};

const MARKERS = {
  deny: 'PROBE_DENY_MARKER',
  stop: 'PROBE_BLOCK_MARKER',
  subagentStop: 'PROBE_SUBAGENT_BLOCK_MARKER',
  subagentShell: 'PROBE_SUB_SHELL',
  planTool: 'PROBE_PLAN_TOOL',
  trustedTool: 'PROBE_TRUSTED_TOOL',
  planStep: 'PROBE_PLAN_STEP',
  planIntro: 'Probe plan intro',
  stdin: 'PROBE_STDIN_LINE',
  patchLine: 'PROBE_PATCH_LINE',
  multiLines: ['PROBE_FIRST', 'PROBE_SECOND'],
  subagentFinal: 'PROBE_SUB_FINAL_MESSAGE',
  subagentPreHold: 'PROBE_SUB_PRE_HOLD_MESSAGE',
};

const FILES = {
  denied: 'denied.txt',
  patched: 'patched.txt',
  stdin: 'stdin-received.txt',
  multi: ['first.txt', 'second.txt'],
  subShell: 'sub-shell.txt',
  subPatch: 'sub-patch.txt',
  parentWrite: 'parent-write.txt',
  subDenied: 'sub-denied.txt',
  subDeniedPatch: 'sub-denied-patch.txt',
  profilePatch: 'profile-patch.txt',
  profileShell: 'profile-shell.txt',
  grandWrite: 'grand-write.txt',
  semanticEdit: 'semantic-edit-ran.txt',
};

const PROMPTS = {
  trustedTurn: 'probe trusted turn',
  makePlan: 'probe make a plan',
  makePlanOnRequest: 'probe make a plan on request',
  semanticEditTurn: 'probe turn after a semantic hook script edit',
  messageRoot: 'probe message the root thread.',
  ruiDefault: 'probe default mode question',
  ruiPlan: 'probe plan mode question',
  ruiCodeDefault: 'probe code default mode question',
  ruiCodePlan: 'probe code plan mode question',
};

const CALLS = {
  env: 'call_probe_env',
  stdinStart: 'call_probe_stdin_start',
  stdinWrite: 'call_probe_stdin_write',
  rui: 'call_probe_rui',
  ruiDefault: 'call_probe_rui_default',
  ruiPlan: 'call_probe_rui_plan',
  ruiCodeDefault: 'call_probe_rui_code_default',
  ruiCodePlan: 'call_probe_rui_code_plan',
  deny: 'call_probe_deny',
  escalate: 'call_probe_escalate',
  spawn: 'call_probe_spawn',
  subTool: 'call_probe_sub_tool',
  planTool: 'call_probe_plan_tool',
  parentWrite: 'call_probe_parent_write',
  subDeny: 'call_probe_sub_deny',
  profileTools: 'call_probe_profile_tools',
  profileSpawn: 'call_probe_profile_spawn',
  wait: 'call_probe_wait',
  waitFirst: 'call_probe_wait_first',
  waitSecond: 'call_probe_wait_second',
  rootMessage: 'call_probe_root_message',
  rootMessageRelative: 'call_probe_root_message_relative',
  rootFollowup: 'call_probe_root_followup',
  planToolOnRequest: 'call_probe_plan_tool_on_request',
};

const ROLES = {
  'probe-role': 'PROBE_ROLE_MARKER',
  'home-role': 'PROBE_HOME_ROLE_MARKER',
  'project-role': 'PROBE_PROJECT_ROLE_MARKER',
  'config-role': 'PROBE_CONFIG_ROLE_MARKER',
};

const TWIN_ROLE = { name: 'twin-role', home: 'PROBE_TWIN_HOME_MARKER', project: 'PROBE_TWIN_PROJECT_MARKER' };

const TOOLS_ROLE = { name: 'tools-role', marker: 'PROBE_TOOLS_ROLE_MARKER' };

const MATCHERS = [
  { label: 'bash-plain', matcher: 'Bash' },
  { label: 'bash-anchored', matcher: '^Bash$' },
  { label: 'exec-command', matcher: '^exec_command$' },
  { label: 'apply-patch', matcher: '^apply_patch$' },
  { label: 'claude-edit', matcher: '^(Edit|Write|MultiEdit)$' },
  { label: 'spawn-plain', matcher: 'spawn_agent' },
];

const SCENARIO_NAMES = Object.freeze([
  'classic-baseline',
  'code-baseline',
  'gpt55-baseline',
  'classic-stdin',
  'code-stdin',
  'code-patch',
  'code-patch-multi',
  'gpt55-patch',
  'classic-rui',
  'code-rui',
  'deny-classic-bash-json',
  'deny-classic-bash-exit2',
  'deny-code-bash-json',
  'deny-code-bash-exit2',
  'deny-code-patch-json',
  'deny-code-patch-exit2',
  'deny-code-patch-edit-json',
  'deny-gpt55-bash-json',
  'deny-gpt55-patch-json',
  'deny-sub-classic-bash-json',
  'deny-sub-classic-bash-exit2',
  'deny-sub-code-bash-json',
  'deny-sub-code-bash-exit2',
  'deny-sub-code-patch-json',
  'deny-sub-code-patch-exit2',
  'deny-sub-code-spawn-json',
  'deny-classic-spawn-json',
  'deny-code-spawn-json',
  'spawn-classic',
  'spawn-code',
  'spawn-classic-subagent-stop-block',
  'spawn-code-subagent-stop-block',
  'spawn-classic-subagent-stop-hold',
  'spawn-code-subagent-stop-hold',
  'role-sandbox-classic',
  'role-sandbox-code',
  'sandbox-readonly-parent',
  'spawn-code-workspace',
  'role-sandbox-code-workspace',
  'subagent-message-root',
  'role-tools-code',
  'role-delegate-code',
  'roles-code',
  'roles-classic',
  'roles-untrusted-project',
  'permission-request',
  'compact-auto',
  'exec-untrusted',
  'exec-default-features',
  'exec-cwd-outside',
  'stop-decision-block',
  'stop-exit2',
  'stop-continue-false',
  'stop-system-message',
  'stop-code-decision-block',
  'stop-code-exit2',
  'stop-code-continue-false',
  'stop-code-system-message',
  'stop-gpt55-decision-block',
  'app-lists',
  'app-untrusted-turn',
  'app-rui',
  'app-trust',
  'app-interrupt-compact',
  'app-permission',
  'app-gates',
  'exec-trusted',
  'deny-classic-bash-json-trusted',
  'stop-decision-block-trusted',
]);

function isSubagentBody(body) {
  const meta = (body && body.client_metadata) || {};
  return Boolean(meta['x-codex-parent-thread-id'] || meta['x-openai-subagent']);
}

module.exports = {
  TUI_STRINGS,
  CONTEXT,
  MARKERS,
  FILES,
  PROMPTS,
  CALLS,
  ROLES,
  TWIN_ROLE,
  TOOLS_ROLE,
  MATCHERS,
  SCENARIO_NAMES,
  isSubagentBody,
};
