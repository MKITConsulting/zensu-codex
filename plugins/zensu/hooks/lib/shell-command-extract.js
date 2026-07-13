"use strict";

// Shared shell-command extractor for the PostToolUse witness
// (post-bash-witness.sh) and the PreToolUse source-write gate parser
// (bash-source-write-parse.js). One cascade, two consumers — drift between
// them would make a tool shape gated-but-unwitnessed (evidence gap) or
// witnessed-but-ungated (write-gate bypass).
//
// Observed host shapes (verified against real Codex session rollouts):
//   Claude Code Bash      tool_input.command  (string)
//   Codex shell           tool_input.command  (argv array, e.g. ["bash","-lc","…"])
//   Codex exec_command    tool_input.cmd      (string)
//   Codex exec (custom)   tool_input          (raw command string) or {input}
function extractShellCommand(rawToolInput) {
  const rawTi = (typeof rawToolInput !== "undefined" && rawToolInput !== null) ? rawToolInput : {};
  const ti = (rawTi && typeof rawTi === "object") ? rawTi : {};
  if (typeof rawTi === "string") return rawTi;
  if (typeof ti.command === "string") return ti.command;
  if (Array.isArray(ti.command)) return ti.command.join(" ");
  if (typeof ti.cmd === "string") return ti.cmd;
  if (typeof ti.input === "string") return ti.input;
  return "";
}

module.exports = { extractShellCommand };
