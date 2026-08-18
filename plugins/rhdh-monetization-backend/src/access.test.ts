import {
  isAllowedControlResource,
  normalizeControlResource,
  parseForwardedBearer,
} from './access';

describe('control-plane proxy boundary', () => {
  it('allows only customer-scoped developer resources', () => {
    expect(isAllowedControlResource('user', 'me/billing')).toBe(true);
    expect(isAllowedControlResource('user', 'subscriptions')).toBe(false);
    expect(isAllowedControlResource('user', '../subscriptions')).toBe(false);
  });

  it('keeps administrator resources on the administrator path', () => {
    expect(isAllowedControlResource('admin', 'subscriptions')).toBe(true);
    expect(isAllowedControlResource('admin', 'me/billing')).toBe(false);
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
