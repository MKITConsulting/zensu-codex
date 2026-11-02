'use strict';

// Goal scope is independent of the repository product binding and host identity.
const UUID = /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const reason = v => typeof v === 'string' && v.trim() && [...v].length <= 500 && !/[\x00-\x1f\x7f-\x9f]/.test(v);
function fromOptions(options) {
  const featureId = options.feature ?? null;
  const featureRevisionId = options['feature-revision'] ?? null;
  const maintenanceReason = options['maintenance-reason'] ?? '';
  const cross = options['cross-product-reason'] ?? '';
  if ((featureId !== null && !UUID.test(featureId)) || (featureRevisionId !== null && (!featureId || !UUID.test(featureRevisionId)))) throw new Error('A valid feature and optional matching revision are required');
  if (Object.hasOwn(options, 'maintenance-reason') && !reason(maintenanceReason)) throw new Error('An explicit maintenance reason is required');
  if (Object.hasOwn(options, 'cross-product-reason') && !reason(cross)) throw new Error('An explicit cross-product reason is required');
  if ([!!featureId, !!maintenanceReason, !!cross].filter(Boolean).length > 1) throw new Error('Choose a feature, maintenance or cross-product work, never more than one');
  if (!featureId && !maintenanceReason && !cross) return null;
  return { taskScope: featureId ? 'feature' : maintenanceReason ? 'maintenance' : 'cross_product', featureId, featureRevisionId, maintenanceReason };
}
function contextArgs(scope) {
  if (scope?.taskScope === 'cross_product') return ['context', '--cross-product'];
  return ['context', ...(scope?.featureId ? ['--feature', scope.featureId] : []), ...(scope?.featureRevisionId ? ['--feature-revision', scope.featureRevisionId] : [])];
}
function confirm(context, scope) {
  if (!scope) throw new Error('Legacy capture has no feature goal scope; begin a new explicitly scoped goal');
  if (scope.featureId && (context.featureId !== scope.featureId || (context.featureRevisionId ?? null) !== scope.featureRevisionId)) throw new Error('Feature scope was not confirmed; update the CLI and server');
  return scope;
}
function assertSame(actual, expected) {
  for (const key of ['taskScope', 'featureId', 'featureRevisionId', 'maintenanceReason']) {
    if (actual[key] !== expected[key]) throw new Error('Feature goal scope changed or was not confirmed; use a new task key');
  }
}
function startArgs(scope) {
  if (!scope?.taskScope) throw new Error('Missing goal scope');
  return [...(scope.featureId ? ['--feature', scope.featureId] : []), ...(scope.featureRevisionId ? ['--feature-revision', scope.featureRevisionId] : []), ...(scope.maintenanceReason ? ['--maintenance-reason', scope.maintenanceReason] : [])];
}
module.exports = { fromOptions, contextArgs, confirm, assertSame, startArgs };
