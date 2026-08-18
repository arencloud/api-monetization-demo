import {
  HttpAuthService,
  PermissionsService,
  RootConfigService,
} from '@backstage/backend-plugin-api';
import { NotAllowedError } from '@backstage/errors';
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
} from './permissions';

const permissionByAccess: Record<ControlAccess, BasicPermission> = {
  'read-own': billingReadOwnPermission,
  'create-own': subscriptionCreateOwnPermission,
  'update-own': subscriptionUpdateOwnPermission,
  'delete-own': subscriptionDeleteOwnPermission,
  'read-all': billingReadAllPermission,
};

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

  router.use(express.json());

  router.get('/tokenratelimitpolicies', async (req, res) => {
    await requirePermission(req, httpAuth, permissions, tokenRateLimitPolicyListPermission);
    res.json(await listTokenRateLimitPolicies());
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

  router.get('/control/admin/:resource(*)', async (req, res) => {
    await requirePermission(req, httpAuth, permissions, billingReadAllPermission);
    const resource = normalizeControlResource(req.params.resource);
    if (!resolveControlAccess('admin', req.method, resource)) {
      throw new NotAllowedError('control-plane resource is not available through the administrator API');
    }
    await proxyControl(req, res, controlBaseUrl, resource);
  });

  return router;
}
