import { createPermission } from '@backstage/plugin-permission-common';

export const tokenRateLimitPolicyListPermission = createPermission({
  name: 'api-monetization.tokenratelimitpolicy.list',
  attributes: { action: 'read' },
});

export const billingReadOwnPermission = createPermission({
  name: 'api-monetization.billing.read.own',
  attributes: { action: 'read' },
});

export const billingReadAllPermission = createPermission({
  name: 'api-monetization.billing.read.all',
  attributes: { action: 'read' },
});

export const subscriptionCreateOwnPermission = createPermission({
  name: 'api-monetization.subscription.create.own',
  attributes: { action: 'create' },
});

export const subscriptionUpdateOwnPermission = createPermission({
  name: 'api-monetization.subscription.update.own',
  attributes: { action: 'update' },
});

export const subscriptionDeleteOwnPermission = createPermission({
  name: 'api-monetization.subscription.delete.own',
  attributes: { action: 'delete' },
});

export const apiMonetizationPermissions = [
  tokenRateLimitPolicyListPermission,
  billingReadOwnPermission,
  billingReadAllPermission,
  subscriptionCreateOwnPermission,
  subscriptionUpdateOwnPermission,
  subscriptionDeleteOwnPermission,
];
