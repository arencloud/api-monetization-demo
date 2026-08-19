import { InputError } from '@backstage/errors';
import { KubernetesApiError, kubernetesRequest } from './kubernetes';

const repositorySegment = /^[a-z][a-z0-9-]{2,39}$/;
const apiPath = /^\/[a-z0-9][a-z0-9/_-]*$/;
const applicationNamespace = 'openshift-gitops';
const workloadNamespace = 'api-monetization-apps';
const gatewayNamespace = 'api-monetization-gateway';
const identityNamespace = 'api-monetization-identity';

interface GeneratedProjectFiles {
  catalog: string;
  kustomization: string;
  apiProducts: string;
  plans: string;
  authPolicies: string;
  routes: string;
  peerAuthentication: string;
}

interface RouteResource {
  status?: {
    ingress?: Array<{
      host?: string;
      conditions?: Array<{ type?: string; status?: string }>;
    }>;
  };
}

interface ApplicationResource {
  metadata?: { name?: string };
  spec?: { source?: { repoURL?: string } };
  status?: {
    sync?: { status?: string; revision?: string };
    health?: { status?: string; message?: string };
    operationState?: { phase?: string; message?: string };
  };
}

interface APIProductResource {
  status?: {
    conditions?: Array<{ type?: string; status?: string; message?: string }>;
  };
}

export interface PublicationStatus {
  repository: string;
  phase: 'not-published' | 'deploying' | 'ready' | 'failed';
  syncStatus?: string;
  healthStatus?: string;
  revision?: string;
  message?: string;
  apiKeyEndpoint?: string;
  jwtEndpoint?: string;
}

interface ValidatedProject {
  product: string;
  path: string;
  freeRequestsPerMinute: number;
  freeMonthlyQuota: number;
  developerRequestsPerMinute: number;
  developerMonthlyQuota: number;
}

const escapeRegExp = (value: string): string =>
  value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const documents = (source: string): string[] => source.split(/^---\s*$/m);

const namedDocument = (source: string, kind: string, name: string): string => {
  const result = documents(source).find(document =>
    new RegExp(`^kind:\\s*${escapeRegExp(kind)}\\s*$`, 'm').test(document) &&
    new RegExp(`^\\s*name:\\s*['"]?${escapeRegExp(name)}['"]?\\s*$`, 'm').test(document),
  );
  if (!result) throw new InputError(`generated repository is missing ${kind} ${name}`);
  return result;
};

const positiveInteger = (value: unknown, field: string): number => {
  if (!Number.isInteger(value) || Number(value) < 1) {
    throw new InputError(`${field} must be a positive integer`);
  }
  return Number(value);
};

const planLimits = (planPolicy: string, tier: string): { minute: number; month: number } => {
  const marker = new RegExp(`^\\s*- tier:\\s*${escapeRegExp(tier)}\\s*$`, 'm').exec(planPolicy);
  const remainder = marker ? planPolicy.slice(marker.index + marker[0].length) : '';
  const nextTier = remainder.search(/^\s*- tier:/m);
  const section = nextTier < 0 ? remainder : remainder.slice(0, nextTier);
  const minute = section.match(/- limit:\s*(\d+)\s*\n\s*window:\s*1m\s*$/m)?.[1];
  const month = section.match(/^\s*monthly:\s*(\d+)\s*$/m)?.[1];
  return {
    minute: positiveInteger(minute ? Number(minute) : undefined, `${tier} requests per minute`),
    month: positiveInteger(month ? Number(month) : undefined, `${tier} monthly quota`),
  };
};

export function validateGeneratedProject(
  allowedOwner: string,
  owner: string,
  repository: string,
  files: GeneratedProjectFiles,
): ValidatedProject {
  if (owner !== allowedOwner || !repositorySegment.test(repository)) {
    throw new InputError(`repository must be a DNS-safe project in the ${allowedOwner} organization`);
  }

  const component = namedDocument(files.catalog, 'Component', repository);
  if (
    !new RegExp(`github[.]com/project-slug:\\s*${escapeRegExp(owner)}/${escapeRegExp(repository)}\\s*$`, 'm').test(component) ||
    !/^\s*owner:\s*group:default\/api-owners\s*$/m.test(component)
  ) {
    throw new InputError('catalog component must be owned by api-owners and reference the requested repository');
  }

  const requiredResources = [
    'build.yaml', 'deployment.yaml', 'service.yaml', 'routes.yaml',
    'peer-authentication.yaml', 'auth-policies.yaml', 'plans.yaml', 'api-products.yaml',
  ];
  if (!requiredResources.every(resource =>
    new RegExp(`^\\s*-\\s*${escapeRegExp(resource)}\\s*$`, 'm').test(files.kustomization),
  )) {
    throw new InputError('generated GitOps kustomization is incomplete');
  }

  const apiKeyProduct = namedDocument(files.apiProducts, 'APIProduct', `${repository}-api`);
  const jwtProduct = namedDocument(files.apiProducts, 'APIProduct', `${repository}-api-jwt`);
  const product = apiKeyProduct.match(/^\s*monetization[.]arencloud[.]com\/product:\s*([^\s]+)\s*$/m)?.[1];
  const path = apiKeyProduct.match(/^\s*monetization[.]arencloud[.]com\/path:\s*([^\s]+)\s*$/m)?.[1];
  if (
    product !== repository || !apiPath.test(path || '') ||
    !/^\s*publishStatus:\s*Published\s*$/m.test(apiKeyProduct) ||
    !/^\s*publishStatus:\s*Published\s*$/m.test(jwtProduct)
  ) {
    throw new InputError('both APIProducts must be Published and contain the generated product and path annotations');
  }

  namedDocument(files.routes, 'HTTPRoute', `${repository}-api-key`);
  namedDocument(files.routes, 'HTTPRoute', `${repository}-jwt`);
  namedDocument(files.authPolicies, 'AuthPolicy', `${repository}-api-key`);
  namedDocument(files.authPolicies, 'AuthPolicy', `${repository}-jwt`);
  const peerAuthentication = namedDocument(
    files.peerAuthentication, 'PeerAuthentication', repository,
  );
  if (
    !/^\s*mode:\s*STRICT\s*$/m.test(peerAuthentication) ||
    !/^\s*["']?8082["']?:\s*(?:\{\s*)?mode:\s*DISABLE/m.test(peerAuthentication) ||
    !new RegExp(`app[.]kubernetes[.]io/name:\\s*['"]?${escapeRegExp(repository)}['"]?`, 'm').test(peerAuthentication)
  ) {
    throw new InputError('PeerAuthentication must retain STRICT mTLS and exempt only documentation port 8082');
  }
  if (!/svc[.]cluster[.]local:8082\/openapi[.]yaml/m.test(files.apiProducts)) {
    throw new InputError('APIProducts must publish OpenAPI from the dedicated documentation port 8082');
  }

  const planPolicy = namedDocument(files.plans, 'PlanPolicy', `${repository}-plans`);
  namedDocument(files.plans, 'RateLimitPolicy', `${repository}-jwt`);
  const free = planLimits(planPolicy, 'free');
  const developer = planLimits(planPolicy, 'developer');
  return {
    product,
    path: path!,
    freeRequestsPerMinute: free.minute,
    freeMonthlyQuota: free.month,
    developerRequestsPerMinute: developer.minute,
    developerMonthlyQuota: developer.month,
  };
}

async function fetchRepositoryFiles(owner: string, repository: string): Promise<GeneratedProjectFiles> {
  const base = `https://raw.githubusercontent.com/${owner}/${repository}/main`;
  const paths: Record<keyof GeneratedProjectFiles, string> = {
    catalog: 'catalog-info.yaml',
    kustomization: 'gitops/kustomization.yaml',
    apiProducts: 'gitops/api-products.yaml',
    plans: 'gitops/plans.yaml',
    authPolicies: 'gitops/auth-policies.yaml',
    routes: 'gitops/routes.yaml',
    peerAuthentication: 'gitops/peer-authentication.yaml',
  };
  const entries = await Promise.all(Object.entries(paths).map(async ([key, path]) => {
    const response = await fetch(`${base}/${path}`, {
      headers: { Accept: 'text/plain' },
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) {
      throw new InputError(`cannot read ${path} from the repository (HTTP ${response.status})`);
    }
    const content = await response.text();
    if (content.length > 512_000) throw new InputError(`${path} exceeds the publication size limit`);
    return [key, content];
  }));
  return Object.fromEntries(entries) as unknown as GeneratedProjectFiles;
}

async function routeHost(namespace: string, name: string): Promise<string> {
  const route = await kubernetesRequest<RouteResource>(
    'GET',
    `/apis/route.openshift.io/v1/namespaces/${namespace}/routes/${name}`,
  );
  const ingress = route.status?.ingress?.find(candidate =>
    candidate.host && candidate.conditions?.some(condition =>
      condition.type === 'Admitted' && condition.status === 'True',
    ),
  );
  if (!ingress?.host) throw new Error(`OpenShift Route ${namespace}/${name} is not admitted`);
  return ingress.host;
}

const jsonPatch = (operations: unknown[]): string => JSON.stringify(operations);

function applicationFor(
  owner: string,
  repository: string,
  project: ValidatedProject,
  hosts: { api: string; jwt: string; keycloak: string },
): Record<string, unknown> {
  const apiKeySubscriptionUrl =
    `'http://monetization-control.api-monetization-data.svc.cluster.local:8081/internal/entitlements/' + auth.identity.metadata.annotations['secret.kuadrant.io/user-id'] + '/${project.product}'`;
  const jwtSubscriptionUrl =
    `'http://monetization-control.api-monetization-data.svc.cluster.local:8081/internal/entitlements/token/' + auth.identity.sub + '/' + auth.identity.azp + '/${project.product}'`;
  const activeSubscription = {
    patternMatching: { patterns: [{
      selector: 'auth.metadata.subscription.status', operator: 'eq', value: 'active',
    }] },
  };
  const jwtLimits = {
    free: {
      rates: [
        { limit: project.freeRequestsPerMinute, window: '1m' },
        { limit: project.freeMonthlyQuota, window: '720h' },
      ],
      counters: [{ expression: 'auth.kuadrant.customer' }],
      when: [{ predicate: 'auth.kuadrant.plan == "free"' }],
    },
    developer: {
      rates: [
        { limit: project.developerRequestsPerMinute, window: '1m' },
        { limit: project.developerMonthlyQuota, window: '720h' },
      ],
      counters: [{ expression: 'auth.kuadrant.customer' }],
      when: [{ predicate: 'auth.kuadrant.plan == "developer"' }],
    },
  };
  const apiSuccess = {
    headers: {
      'x-monetization-customer': {
        plain: { selector: 'auth.identity.metadata.annotations.secret\\.kuadrant\\.io/user-id' },
      },
      'x-monetization-plan': { plain: { selector: 'auth.metadata.subscription.plan' } },
    },
  };
  const jwtSuccess = {
    filters: { kuadrant: { json: { properties: {
      customer: { selector: 'auth.metadata.subscription.customerId' },
      plan: { selector: 'auth.metadata.subscription.plan' },
    } } } },
    headers: {
      'x-monetization-customer': { plain: { selector: 'auth.metadata.subscription.customerId' } },
      'x-monetization-plan': { plain: { selector: 'auth.metadata.subscription.plan' } },
    },
  };
  return {
    apiVersion: 'argoproj.io/v1alpha1',
    kind: 'Application',
    metadata: {
      name: repository,
      namespace: applicationNamespace,
      labels: {
        'app.kubernetes.io/part-of': 'api-monetization',
        'monetization.arencloud.com/generated-by': 'rhdh-owner-publication',
      },
      finalizers: ['resources-finalizer.argocd.argoproj.io'],
    },
    spec: {
      project: 'api-monetization-api-owners',
      source: {
        repoURL: `https://github.com/${owner}/${repository}.git`,
        targetRevision: 'main',
        path: 'gitops',
        kustomize: {
          patches: [
            {
              target: { group: 'gateway.networking.k8s.io', version: 'v1', kind: 'HTTPRoute', name: `${repository}-api-key` },
              patch: jsonPatch([{ op: 'add', path: '/spec/hostnames', value: [hosts.api] }]),
            },
            {
              target: { group: 'gateway.networking.k8s.io', version: 'v1', kind: 'HTTPRoute', name: `${repository}-jwt` },
              patch: jsonPatch([{ op: 'add', path: '/spec/hostnames', value: [hosts.jwt] }]),
            },
            {
              target: { group: 'kuadrant.io', version: 'v1', kind: 'AuthPolicy', name: `${repository}-api-key` },
              patch: jsonPatch([
                { op: 'add', path: '/spec/rules/metadata', value: { subscription: { http: { method: 'GET', urlExpression: apiKeySubscriptionUrl } } } },
                { op: 'add', path: '/spec/rules/authorization', value: { 'active-subscription': activeSubscription } },
                { op: 'add', path: '/spec/rules/response/success', value: apiSuccess },
                { op: 'add', path: '/spec/rules/response/unauthorized', value: { code: 403, headers: { 'content-type': { value: 'application/json' } }, body: { value: '{"error":"active subscription required"}' } } },
              ]),
            },
            {
              target: { group: 'kuadrant.io', version: 'v1', kind: 'AuthPolicy', name: `${repository}-jwt` },
              patch: jsonPatch([
                { op: 'add', path: '/spec/rules/authentication/keycloak/jwt', value: { issuerUrl: `https://${hosts.keycloak}/realms/api-monetization` } },
                { op: 'add', path: '/spec/rules/metadata', value: { subscription: { http: { method: 'GET', urlExpression: jwtSubscriptionUrl } } } },
                { op: 'add', path: '/spec/rules/authorization/active-subscription', value: activeSubscription },
                { op: 'add', path: '/spec/rules/response/success', value: jwtSuccess },
                { op: 'add', path: '/spec/rules/response/unauthorized', value: { code: 403, headers: { 'content-type': { value: 'application/json' } }, body: { value: '{"error":"token audience and active subscription are required"}' } } },
              ]),
            },
            {
              target: { group: 'kuadrant.io', version: 'v1', kind: 'RateLimitPolicy', name: `${repository}-jwt` },
              patch: jsonPatch([{ op: 'replace', path: '/spec/limits', value: jwtLimits }]),
            },
          ],
        },
      },
      destination: {
        server: 'https://kubernetes.default.svc',
        namespace: workloadNamespace,
      },
      syncPolicy: {
        automated: { prune: true, selfHeal: true },
        retry: { limit: 10, backoff: { duration: '10s', factor: 2, maxDuration: '2m' } },
        syncOptions: ['ServerSideApply=true', 'SkipDryRunOnMissingResource=true'],
      },
    },
  };
}

const applicationPath = (repository: string): string =>
  `/apis/argoproj.io/v1alpha1/namespaces/${applicationNamespace}/applications/${repository}`;

export async function publishGeneratedProject(
  allowedOwner: string,
  owner: string,
  repository: string,
): Promise<PublicationStatus> {
  const files = await fetchRepositoryFiles(owner, repository);
  const project = validateGeneratedProject(allowedOwner, owner, repository, files);
  const [apiHost, jwtHost, keycloakHost] = await Promise.all([
    routeHost(gatewayNamespace, 'api-monetization'),
    routeHost(gatewayNamespace, 'api-monetization-jwt'),
    routeHost(identityNamespace, 'api-monetization-keycloak'),
  ]);
  const application = applicationFor(owner, repository, project, {
    api: apiHost, jwt: jwtHost, keycloak: keycloakHost,
  });

  try {
    await kubernetesRequest(
      'POST',
      `/apis/argoproj.io/v1alpha1/namespaces/${applicationNamespace}/applications`,
      application,
    );
  } catch (error) {
    if (!(error instanceof KubernetesApiError) || error.statusCode !== 409) throw error;
    const existing = await kubernetesRequest<ApplicationResource>('GET', applicationPath(repository));
    if (existing.spec?.source?.repoURL !== `https://github.com/${owner}/${repository}.git`) {
      throw new InputError(`Application ${repository} already belongs to another repository`);
    }
    await kubernetesRequest('PATCH', applicationPath(repository), { spec: (application as any).spec });
  }
  return publicationStatus(owner, repository, project.path, { api: apiHost, jwt: jwtHost });
}

export async function publicationStatus(
  owner: string,
  repository: string,
  knownPath?: string,
  knownHosts?: { api: string; jwt: string },
): Promise<PublicationStatus> {
  if (!repositorySegment.test(repository)) throw new InputError('invalid repository name');
  let application: ApplicationResource;
  try {
    application = await kubernetesRequest<ApplicationResource>('GET', applicationPath(repository));
  } catch (error) {
    if (error instanceof KubernetesApiError && error.statusCode === 404) {
      return { repository: `${owner}/${repository}`, phase: 'not-published' };
    }
    throw error;
  }
  if (application.spec?.source?.repoURL !== `https://github.com/${owner}/${repository}.git`) {
    throw new InputError(`Application ${repository} is not managed by this repository`);
  }
  const syncStatus = application.status?.sync?.status;
  const healthStatus = application.status?.health?.status;
  const operationPhase = application.status?.operationState?.phase;
  const failed = operationPhase === 'Failed' || operationPhase === 'Error' || healthStatus === 'Degraded';
  const applicationReady = syncStatus === 'Synced' && healthStatus === 'Healthy';
  let apiProductReady = false;
  let apiProductMessage: string | undefined;
  if (applicationReady) {
    try {
      const apiProduct = await kubernetesRequest<APIProductResource>(
        'GET',
        `/apis/devportal.kuadrant.io/v1alpha1/namespaces/${workloadNamespace}/apiproducts/${repository}-api`,
      );
      const readyCondition = (type: string) => apiProduct.status?.conditions?.find(
        condition => condition.type === type,
      );
      const ready = readyCondition('Ready');
      const openAPI = readyCondition('OpenAPISpecReady');
      apiProductReady = ready?.status === 'True' && openAPI?.status === 'True';
      apiProductMessage = openAPI?.status !== 'True'
        ? openAPI?.message || 'waiting for the APIProduct OpenAPI contract'
        : ready?.status !== 'True'
          ? ready?.message || 'waiting for the APIProduct to become ready'
          : undefined;
    } catch (error) {
      if (!(error instanceof KubernetesApiError) || error.statusCode !== 404) throw error;
      apiProductMessage = 'waiting for the APIProduct to be created';
    }
  }
  const ready = applicationReady && apiProductReady;
  let path = knownPath;
  if (!path) {
    try {
      const files = await fetchRepositoryFiles(owner, repository);
      path = validateGeneratedProject(owner, owner, repository, files).path;
    } catch {
      path = undefined;
    }
  }
  let hosts = knownHosts;
  if (!hosts && path) {
    const [api, jwt] = await Promise.all([
      routeHost(gatewayNamespace, 'api-monetization'),
      routeHost(gatewayNamespace, 'api-monetization-jwt'),
    ]);
    hosts = { api, jwt };
  }
  return {
    repository: `${owner}/${repository}`,
    phase: failed ? 'failed' : ready ? 'ready' : 'deploying',
    syncStatus,
    healthStatus,
    revision: application.status?.sync?.revision,
    message: apiProductMessage || application.status?.operationState?.message || application.status?.health?.message,
    ...(path && hosts ? {
      apiKeyEndpoint: `https://${hosts.api}${path}`,
      jwtEndpoint: `https://${hosts.jwt}${path}`,
    } : {}),
  };
}
