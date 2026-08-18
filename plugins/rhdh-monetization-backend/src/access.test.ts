import {
  normalizeControlResource,
  parseForwardedBearer,
  resolveControlAccess,
} from './access';

describe('control-plane proxy boundary', () => {
  it('allows only customer-scoped developer resources', () => {
    expect(resolveControlAccess('user', 'GET', 'me/billing')).toBe('read-own');
    expect(resolveControlAccess('user', 'GET', 'subscriptions')).toBeUndefined();
    expect(resolveControlAccess('user', 'GET', '../subscriptions')).toBeUndefined();
  });

  it('keeps administrator resources on the administrator path', () => {
    expect(resolveControlAccess('admin', 'GET', 'subscriptions')).toBe('read-all');
    expect(resolveControlAccess('admin', 'GET', 'me/billing')).toBeUndefined();
    expect(resolveControlAccess('admin', 'POST', 'subscriptions')).toBeUndefined();
  });

  it('allows only the explicit own-subscription lifecycle operations', () => {
    expect(resolveControlAccess('user', 'POST', 'me/subscriptions')).toBe('create-own');
    expect(resolveControlAccess('user', 'POST', 'me/subscriptions/inventory/plan')).toBe('update-own');
    expect(resolveControlAccess('user', 'POST', 'me/subscriptions/inventory/cancel')).toBe('delete-own');
    expect(resolveControlAccess('user', 'GET', 'me/credentials/inventory/status')).toBe('read-own');
    expect(resolveControlAccess('user', 'POST', 'me/credentials/inventory/reveal')).toBe('update-own');
    expect(resolveControlAccess('user', 'DELETE', 'me/subscriptions/inventory')).toBeUndefined();
    expect(resolveControlAccess('user', 'POST', 'me/subscriptions/../plan')).toBeUndefined();
  });

  it('normalizes edge slashes without interpreting traversal', () => {
    expect(normalizeControlResource('/me/usage/')).toBe('me/usage');
    expect(normalizeControlResource('/../usage')).toBe('../usage');
  });

  it('accepts one strict bearer token and rejects malformed headers', () => {
    expect(parseForwardedBearer('Bearer signed-token')).toBe('Bearer signed-token');
    expect(parseForwardedBearer('Basic signed-token')).toBeUndefined();
    expect(parseForwardedBearer('Bearer token extra')).toBeUndefined();
  });
});
