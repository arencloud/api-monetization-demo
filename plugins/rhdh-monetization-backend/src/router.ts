import {
  HttpAuthService,
  PermissionsService,
  RootConfigService,
} from '@backstage/backend-plugin-api';
import { InputError, NotAllowedError } from '@backstage/errors';
import { AuthorizeResult, BasicPermission } from '@backstage/plugin-permission-common';
import express from 'express';
import Router from 'express-promise-router';
import {
  ControlAccess,
  normalizeControlResource,
  parseForwardedBearer,
  resolveControlAccess,
} from './access';
import { listTokenRateLimitPolicies } from './kubernetes';
import {
  billingReadAllPermission,
  billingReadOwnPermission,
  subscriptionCreateOwnPermission,
  subscriptionDeleteOwnPermission,
  subscriptionUpdateOwnPermission,
  tokenRateLimitPolicyListPermission,
  publicationCreatePermission,
  publicationReadPermission,
  ownerAccessReadOwnPermission,
  ownerAccessRequestPermission,
  ownerAccessReviewPermission,
} from './permissions';
import { publicationStatus, publishGeneratedProject } from './publication';

const permissionByAccess: Record<ControlAccess, BasicPermission> = {
  'read-own': billingReadOwnPermission,
  'create-own': subscriptionCreateOwnPermission,
  'update-own': subscriptionUpdateOwnPermission,
  'delete-own': subscriptionDeleteOwnPermission,
  'read-all': billingReadAllPermission,
  'read-owner': ownerAccessReadOwnPermission,
  'request-owner': ownerAccessRequestPermission,
  'review-owner': ownerAccessReviewPermission,
};

const githubSegment = /^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,99})$/;

export function buildDevSpacesFactoryUrl(
  devSpacesBaseUrl: string,
  owner: unknown,
  repository: unknown,
): string {
  if (
    typeof owner !== 'string' ||
    typeof repository !== 'string' ||
    !githubSegment.test(owner) ||
    !githubSegment.test(repository)
  ) {
    throw new InputError('valid GitHub owner and repository are required');
  }

  let parsedBaseUrl: URL;
  try {
    parsedBaseUrl = new URL(devSpacesBaseUrl);
  } catch {
    throw new InputError('apiMonetization.devSpacesBaseUrl must be a valid URL');
  }
  if (
    parsedBaseUrl.protocol !== 'https:' ||
    parsedBaseUrl.username ||
    parsedBaseUrl.password ||
    parsedBaseUrl.search ||
    parsedBaseUrl.hash
  ) {
    throw new InputError('apiMonetization.devSpacesBaseUrl must be a plain HTTPS URL');
  }

  const normalizedBaseUrl = devSpacesBaseUrl.replace(/\/+$/, '');
  return `${normalizedBaseUrl}#https://github.com/${owner}/${repository}`;
}

async function requirePermission(
  req: express.Request,
  httpAuth: HttpAuthService,
  permissions: PermissionsService,
  permission: BasicPermission,
) {
  const credentials = await httpAuth.credentials(req);
  const [decision] = await permissions.authorize([{ permission }], { credentials });
  if (decision.result !== AuthorizeResult.ALLOW) {
    throw new NotAllowedError(`permission ${permission.name} is required`);
  }
}

function keycloakAuthorization(req: express.Request): string {
  const value = parseForwardedBearer(req.header('x-api-monetization-authorization'));
  if (!value) {
    throw new NotAllowedError('a Keycloak access token is required');
  }
  return value;
}

async function proxyControl(
  req: express.Request,
  res: express.Response,
  controlBaseUrl: string,
  path: string,
) {
  const response = await fetch(`${controlBaseUrl}/api/${path}`, {
    method: req.method,
    headers: {
      Accept: 'application/json',
      Authorization: keycloakAuthorization(req),
      ...(req.method === 'GET' ? {} : { 'Content-Type': 'application/json' }),
    },
    body: req.method === 'GET' ? undefined : JSON.stringify(req.body || {}),
    signal: AbortSignal.timeout(req.method === 'GET' ? 15_000 : 60_000),
  });
  const body = await response.text();
  res.status(response.status);
  res.type(response.headers.get('content-type') || 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.send(body);
}

export async function createRouter({
  config,
  httpAuth,
  permissions,
}: {
  config: RootConfigService;
  httpAuth: HttpAuthService;
  permissions: PermissionsService;
}): Promise<express.Router> {
  const router = Router();
  const controlBaseUrl = config.getOptionalString('apiMonetization.controlBaseUrl') ||
    'http://monetization-control.api-monetization-data.svc.cluster.local:8080';
  const devSpacesBaseUrl = config.getString('apiMonetization.devSpacesBaseUrl');
  const publicationOwner = config.getOptionalString('apiMonetization.publication.githubOwner') || 'arencloud';

  router.use(express.json());

  router.get('/devspaces/open', (req, res) => {
    res.redirect(302, buildDevSpacesFactoryUrl(
      devSpacesBaseUrl,
      req.query.owner,
      req.query.repo,
    ));
  });

  router.get('/tokenratelimitpolicies', async (req, res) => {
    await requirePermission(req, httpAuth, permissions, tokenRateLimitPolicyListPermission);
    res.json(await listTokenRateLimitPolicies());
  });

  router.get('/publications/:owner/:repository', async (req, res) => {
    await requirePermission(req, httpAuth, permissions, publicationReadPermission);
    if (req.params.owner !== publicationOwner) {
      throw new InputError(`publications are restricted to the ${publicationOwner} organization`);
    }
    res.json(await publicationStatus(req.params.owner, req.params.repository));
  });

  router.post('/publications/:owner/:repository', async (req, res) => {
    await requirePermission(req, httpAuth, permissions, publicationCreatePermission);
    const result = await publishGeneratedProject(
      publicationOwner,
      req.params.owner,
      req.params.repository,
    );
    res.status(result.phase === 'ready' ? 200 : 202).json(result);
  });

  router.all('/control/user/:resource(*)', async (req, res) => {
    const resource = normalizeControlResource(req.params.resource);
    const access = resolveControlAccess('user', req.method, resource);
    if (!access) {
      throw new NotAllowedError('control-plane operation is not available through the user API');
    }
    await requirePermission(req, httpAuth, permissions, permissionByAccess[access]);
    await proxyControl(req, res, controlBaseUrl, resource);
  });

  router.all('/control/admin/:resource(*)', async (req, res) => {
    const resource = normalizeControlResource(req.params.resource);
    const access = resolveControlAccess('admin', req.method, resource);
    if (!access) {
      throw new NotAllowedError('control-plane resource is not available through the administrator API');
    }
    await requirePermission(req, httpAuth, permissions, permissionByAccess[access]);
    await proxyControl(req, res, controlBaseUrl, resource);
  });

  return router;
}
