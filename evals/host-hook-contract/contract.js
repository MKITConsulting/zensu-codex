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
};

const FILES = {
  denied: 'denied.txt',
  patched: 'patched.txt',
  stdin: 'stdin-received.txt',
  multi: ['first.txt', 'second.txt'],
  subShell: 'sub-shell.txt',
  subPatch: 'sub-patch.txt',
  parentWrite: 'parent-write.txt',
};

const PROMPTS = {
  trustedTurn: 'probe trusted turn',
  makePlan: 'probe make a plan',
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
  isSubagentBody,
};
