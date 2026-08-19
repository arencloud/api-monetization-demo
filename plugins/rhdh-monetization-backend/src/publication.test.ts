import { InputError } from '@backstage/errors';
import { validateGeneratedProject } from './publication';

const files = {
  catalog: `
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: time
  annotations:
    github.com/project-slug: arencloud/time
spec:
  owner: group:default/api-owners
`,
  kustomization: `
resources:
  - build.yaml
  - deployment.yaml
  - service.yaml
  - peer-authentication.yaml
  - routes.yaml
  - auth-policies.yaml
  - plans.yaml
  - api-products.yaml
`,
  apiProducts: `
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIProduct
metadata:
  name: time-api
  annotations:
    monetization.arencloud.com/product: time
    monetization.arencloud.com/path: /timer
spec:
  publishStatus: Published
  documentation:
    openAPISpecURL: http://time.api-monetization-apps.svc.cluster.local:8082/openapi.yaml
---
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIProduct
metadata:
  name: time-api-jwt
spec:
  publishStatus: Published
  documentation:
    openAPISpecURL: http://time.api-monetization-apps.svc.cluster.local:8082/openapi.yaml
`,
  routes: `
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: time-api-key
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: time-jwt
`,
  authPolicies: `
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: time-api-key
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: time-jwt
`,
  peerAuthentication: `
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: time
spec:
  selector:
    matchLabels: {app.kubernetes.io/name: time}
  mtls: {mode: STRICT}
  portLevelMtls:
    "8082": {mode: DISABLE}
`,
  plans: `
apiVersion: extensions.kuadrant.io/v1alpha1
kind: PlanPolicy
metadata:
  name: time-plans
spec:
  plans:
    - tier: free
      limits:
        monthly: 1000
        custom:
          - limit: 10
            window: 1m
    - tier: developer
      limits:
        monthly: 1000000
        custom:
          - limit: 1000
            window: 1m
---
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: time-jwt
`,
};

describe('generated API publication validation', () => {
  it('accepts the governed Time repository contract and extracts its limits', () => {
    expect(validateGeneratedProject('arencloud', 'arencloud', 'time', files)).toEqual({
      product: 'time',
      path: '/timer',
      freeRequestsPerMinute: 10,
      freeMonthlyQuota: 1000,
      developerRequestsPerMinute: 1000,
      developerMonthlyQuota: 1000000,
    });
  });

  it('rejects another organization or an unpublished API', () => {
    expect(() => validateGeneratedProject('arencloud', 'other', 'time', files)).toThrow(InputError);
    expect(() => validateGeneratedProject('arencloud', 'arencloud', 'time', {
      ...files,
      apiProducts: files.apiProducts.replaceAll('Published', 'Draft'),
    })).toThrow('both APIProducts must be Published');
  });

  it('rejects a duplicate static API catalog entity', () => {
    expect(() => validateGeneratedProject('arencloud', 'arencloud', 'time', {
      ...files,
      catalog: `${files.catalog}\n---\napiVersion: backstage.io/v1alpha1\nkind: API\nmetadata:\n  name: time\n`,
    })).toThrow('must not define static API entities');
  });

  it('rejects a Component relation that consumers cannot resolve', () => {
    expect(() => validateGeneratedProject('arencloud', 'arencloud', 'time', {
      ...files,
      catalog: files.catalog.replace(
        '  owner: group:default/api-owners',
        "  owner: group:default/api-owners\n  providesApis: ['time-api', 'time-api-jwt']",
      ),
    })).toThrow('consumers cannot read owner Components');
  });
});
