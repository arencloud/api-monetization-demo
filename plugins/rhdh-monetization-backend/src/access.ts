const userReadPaths = new Set([
  'me',
  'catalog',
  'me/subscriptions',
  'me/usage',
  'me/billing',
  'me/audit',
  'me/owner-access',
]);

const adminReadPaths = new Set([
  'catalog',
  'subscriptions',
  'usage',
  'invoices',
  'owner-access-requests',
]);

const productResource = '[a-z0-9](?:[a-z0-9-]*[a-z0-9])?';
const userRequestRules: Array<{
  method: string;
  pattern: RegExp;
  access: ControlAccess;
}> = [
  { method: 'POST', pattern: /^me\/subscriptions$/, access: 'create-own' },
  { method: 'POST', pattern: /^me\/owner-access$/, access: 'request-owner' },
  {
    method: 'POST',
    pattern: new RegExp(`^me/subscriptions/${productResource}/plan$`),
    access: 'update-own',
  },
  {
    method: 'POST',
    pattern: new RegExp(`^me/subscriptions/${productResource}/cancel$`),
    access: 'delete-own',
  },
  {
    method: 'GET',
    pattern: new RegExp(`^me/credentials/${productResource}/status$`),
    access: 'read-own',
  },
  {
    method: 'POST',
    pattern: new RegExp(`^me/credentials/${productResource}/(?:reveal|rotate)$`),
    access: 'update-own',
  },
];

export type ControlAccess =
  | 'read-own'
  | 'create-own'
  | 'update-own'
  | 'delete-own'
  | 'read-all'
  | 'read-owner'
  | 'request-owner'
  | 'review-owner';

export const normalizeControlResource = (value: unknown): string =>
  String(value || '').replace(/^\/+|\/+$/g, '');

export const resolveControlAccess = (
  scope: 'user' | 'admin',
  method: string,
  resource: string,
): ControlAccess | undefined => {
  const normalizedMethod = method.toUpperCase();
  if (scope === 'admin') {
    if (normalizedMethod === 'GET' && adminReadPaths.has(resource)) {
      return resource === 'owner-access-requests' ? 'review-owner' : 'read-all';
    }
    if (
      normalizedMethod === 'POST' &&
      /^owner-access-requests\/[0-9a-f-]+\/decision$/.test(resource)
    ) {
      return 'review-owner';
    }
    return undefined;
  }
  if (normalizedMethod === 'GET' && userReadPaths.has(resource)) {
    return resource === 'me/owner-access' ? 'read-owner' : 'read-own';
  }
  return userRequestRules.find(
    rule => rule.method === normalizedMethod && rule.pattern.test(resource),
  )?.access;
};

export const parseForwardedBearer = (value: string | undefined): string | undefined =>
  value && /^Bearer [^\s]+$/.test(value) ? value : undefined;
