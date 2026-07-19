'use strict';

const PRINCIPALS = Object.freeze({
  MAIN: 'main-v1',
  REVIEWER: 'reviewer-readonly-v1',
  HOST: 'host-profile-v1',
});

const REVIEWER_TYPES = new Set([
  'zensu-code-reviewer',
  'zensu-review-aspect',
  'zensu-review-judge',
]);

function isReviewerType(agentType) {
  return typeof agentType === 'string' && REVIEWER_TYPES.has(agentType);
}

function classifySubagent(agentType) {
  return isReviewerType(agentType) ? PRINCIPALS.REVIEWER : PRINCIPALS.HOST;
}

function classifyPreToolPayload(payload) {
  const hasAgentId = Object.prototype.hasOwnProperty.call(payload, 'agent_id');
  const hasAgentType = Object.prototype.hasOwnProperty.call(payload, 'agent_type');
  if (!hasAgentId && !hasAgentType) return PRINCIPALS.MAIN;
  return classifySubagent(payload.agent_type);
}

module.exports = {
  PRINCIPALS,
  REVIEWER_TYPES,
  isReviewerType,
  classifySubagent,
  classifyPreToolPayload,
};
