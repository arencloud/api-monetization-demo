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

export const apiMonetizationPermissions = [
  tokenRateLimitPolicyListPermission,
  billingReadOwnPermission,
  billingReadAllPermission,
];
