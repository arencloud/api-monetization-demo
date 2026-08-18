export const userControlPaths = new Set([
  'me',
  'catalog',
  'me/subscriptions',
  'me/usage',
  'me/billing',
  'me/audit',
]);

export const adminControlPaths = new Set([
  'catalog',
  'subscriptions',
  'usage',
  'invoices',
]);

export const normalizeControlResource = (value: unknown): string =>
  String(value || '').replace(/^\/+|\/+$/g, '');

export const isAllowedControlResource = (
  scope: 'user' | 'admin',
  resource: string,
): boolean => (scope === 'user' ? userControlPaths : adminControlPaths).has(resource);

export const parseForwardedBearer = (value: string | undefined): string | undefined =>
  value && /^Bearer [^\s]+$/.test(value) ? value : undefined;
