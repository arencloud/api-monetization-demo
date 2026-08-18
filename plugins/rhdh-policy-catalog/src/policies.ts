import { APIProduct, EffectivePolicy, TrafficPolicy } from './types';

const targetMatches = (
  product: APIProduct,
  policy: TrafficPolicy,
): boolean => {
  const productTarget = product.spec?.targetRef;
  const policyTarget = policy.spec?.targetRef;
  if (!productTarget || !policyTarget) {
    return false;
  }

  const productNamespace =
    productTarget.namespace || product.metadata.namespace || 'default';
  const policyNamespace =
    policyTarget.namespace || policy.metadata.namespace || 'default';

  return (
    (!policyTarget.kind || policyTarget.kind === 'HTTPRoute') &&
    policyTarget.name === productTarget.name &&
    policyNamespace === productNamespace
  );
};

const isEnforced = (policy: TrafficPolicy): boolean =>
  policy.status?.conditions?.some(
    condition =>
      (condition.type === 'Enforced' || condition.type === 'Accepted') &&
      condition.status === 'True',
  ) ?? false;

const describe = (
  kind: EffectivePolicy['kind'],
  policy: TrafficPolicy,
): EffectivePolicy => ({
  kind,
  name: policy.metadata.name,
  namespace: policy.metadata.namespace || 'default',
  enforced: isEnforced(policy),
});

/**
 * PlanPolicy is the product-level abstraction and wins when one targets the
 * route. Direct RateLimitPolicies are used for JWT products because they can
 * carry explicit per-customer counters that PlanPolicy does not expose.
 */
export const resolveEffectivePolicies = (
  product: APIProduct,
  planPolicies: TrafficPolicy[],
  rateLimitPolicies: TrafficPolicy[],
): EffectivePolicy[] => {
  const planPolicy = planPolicies.find(policy => targetMatches(product, policy));
  if (planPolicy) {
    return [describe('PlanPolicy', planPolicy)];
  }

  return rateLimitPolicies
    .filter(policy => targetMatches(product, policy))
    .map(policy => describe('RateLimitPolicy', policy));
};

export const resolveTokenPolicies = (
  product: APIProduct,
  tokenRateLimitPolicies: TrafficPolicy[],
): EffectivePolicy[] =>
  tokenRateLimitPolicies
    .filter(policy => targetMatches(product, policy))
    .map(policy => describe('TokenRateLimitPolicy', policy));

export const getAuthentication = (product: APIProduct): string[] => {
  const authentication =
    product.status?.discoveredAuthScheme?.authentication || {};
  const schemes = Object.values(authentication);
  const result: string[] = [];

  if (
    schemes.some(
      value => typeof value === 'object' && value !== null && 'apiKey' in value,
    )
  ) {
    result.push('API Key');
  }
  if (
    schemes.some(
      value => typeof value === 'object' && value !== null && 'jwt' in value,
    )
  ) {
    result.push('OIDC');
  }

  return result.length > 0 ? result : ['Unknown'];
};
