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
  deployment: `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: time
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: USAGE_SINK_URL
              value: http://monetization-control.api-monetization-data.svc.cluster.local:8081/internal/usage
            - name: MONETIZATION_PRODUCT
              value: time
            - name: MONETIZATION_UNIT
              value: request
`,
  apiProducts: `
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIProduct
metadata:
  name: time-api
  annotations:
    monetization.arencloud.com/product: time
    monetization.arencloud.com/path: /timer
    monetization.arencloud.com/unit: request
    monetization.arencloud.com/plans: '{"free":{"monthlyPriceCents":0,"includedUnits":1000,"monthlyQuotaUnits":1000,"overageMicrosPerUnit":0,"rateLimitRequests":10,"rateLimitWindowSeconds":60},"payg":{"monthlyPriceCents":0,"includedUnits":0,"monthlyQuotaUnits":10000,"overageMicrosPerUnit":10000,"rateLimitRequests":100,"rateLimitWindowSeconds":60},"developer":{"monthlyPriceCents":4900,"includedUnits":100000,"monthlyQuotaUnits":1000000,"overageMicrosPerUnit":1000,"rateLimitRequests":1000,"rateLimitWindowSeconds":60},"business":{"monthlyPriceCents":49900,"includedUnits":5000000,"monthlyQuotaUnits":50000000,"overageMicrosPerUnit":500,"rateLimitRequests":10000,"rateLimitWindowSeconds":60},"enterprise":{"monthlyPriceCents":0,"includedUnits":null,"monthlyQuotaUnits":null,"overageMicrosPerUnit":0,"rateLimitRequests":null,"rateLimitWindowSeconds":null}}'
spec:
  publishStatus: Published
  documentation:
    openAPISpecURL: http://time.api-monetization-apps.svc.cluster.local:8082/openapi.yaml
---
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIProduct
metadata:
  name: time-api-jwt
  annotations:
    monetization.arencloud.com/product: time
    monetization.arencloud.com/path: /timer
    monetization.arencloud.com/unit: request
    monetization.arencloud.com/plans: '{"free":{"monthlyPriceCents":0,"includedUnits":1000,"monthlyQuotaUnits":1000,"overageMicrosPerUnit":0,"rateLimitRequests":10,"rateLimitWindowSeconds":60},"payg":{"monthlyPriceCents":0,"includedUnits":0,"monthlyQuotaUnits":10000,"overageMicrosPerUnit":10000,"rateLimitRequests":100,"rateLimitWindowSeconds":60},"developer":{"monthlyPriceCents":4900,"includedUnits":100000,"monthlyQuotaUnits":1000000,"overageMicrosPerUnit":1000,"rateLimitRequests":1000,"rateLimitWindowSeconds":60},"business":{"monthlyPriceCents":49900,"includedUnits":5000000,"monthlyQuotaUnits":50000000,"overageMicrosPerUnit":500,"rateLimitRequests":10000,"rateLimitWindowSeconds":60},"enterprise":{"monthlyPriceCents":0,"includedUnits":null,"monthlyQuotaUnits":null,"overageMicrosPerUnit":0,"rateLimitRequests":null,"rateLimitWindowSeconds":null}}'
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
    - tier: payg
      limits:
        monthly: 10000
        custom:
          - limit: 100
            window: 1m
    - tier: business
      limits:
        monthly: 50000000
        custom:
          - limit: 10000
            window: 1m
    - tier: enterprise
      limits: {}
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
      unit: 'request',
      limits: {
        free: { minute: 10, month: 1000 },
        payg: { minute: 100, month: 10000 },
        developer: { minute: 1000, month: 1000000 },
        business: { minute: 10000, month: 50000000 },
      },
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
