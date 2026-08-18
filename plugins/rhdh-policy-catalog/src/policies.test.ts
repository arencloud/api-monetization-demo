import { getAuthentication, resolveEffectivePolicies } from './policies';
import { APIProduct, TrafficPolicy } from './types';

const product = (route: string): APIProduct => ({
  metadata: { name: `${route}-product`, namespace: 'api-monetization-apps' },
  spec: { targetRef: { kind: 'HTTPRoute', name: route } },
});

const policy = (name: string, route: string): TrafficPolicy => ({
  metadata: { name, namespace: 'api-monetization-apps' },
  spec: { targetRef: { kind: 'HTTPRoute', name: route } },
  status: { conditions: [{ type: 'Enforced', status: 'True' }] },
});

describe('resolveEffectivePolicies', () => {
  it('returns PlanPolicy for a plan-managed API-key route', () => {
    expect(
      resolveEffectivePolicies(
        product('inventory-api-key'),
        [policy('inventory-api-plans', 'inventory-api-key')],
        [policy('generated-rate-limit', 'inventory-api-key')],
      ),
    ).toEqual([
      {
        kind: 'PlanPolicy',
        name: 'inventory-api-plans',
        namespace: 'api-monetization-apps',
        enforced: true,
      },
    ]);
  });

  it('returns direct RateLimitPolicy for a JWT route', () => {
    expect(
      resolveEffectivePolicies(
        product('inventory-jwt'),
        [],
        [policy('inventory-jwt-plans', 'inventory-jwt')],
      ),
    ).toEqual([
      {
        kind: 'RateLimitPolicy',
        name: 'inventory-jwt-plans',
        namespace: 'api-monetization-apps',
        enforced: true,
      },
    ]);
  });

  it('does not associate a policy from another namespace', () => {
    const other = policy('inventory-jwt-plans', 'inventory-jwt');
    other.metadata.namespace = 'another-namespace';
    expect(resolveEffectivePolicies(product('inventory-jwt'), [], [other])).toEqual([]);
  });
});

describe('getAuthentication', () => {
  it('reports OIDC from a discovered JWT scheme', () => {
    const jwtProduct = product('inventory-jwt');
    jwtProduct.status = {
      discoveredAuthScheme: { authentication: { bearer: { jwt: {} } } },
    };
    expect(getAuthentication(jwtProduct)).toEqual(['OIDC']);
  });
});
