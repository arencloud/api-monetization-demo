import React, { useMemo } from 'react';
import {
  discoveryApiRef,
  fetchApiRef,
  useApi,
} from '@backstage/core-plugin-api';
import {
  Box,
  Chip,
  CircularProgress,
  Link as MaterialLink,
  Paper,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from '@material-ui/core';
import LockIcon from '@material-ui/icons/Lock';
import VpnKeyIcon from '@material-ui/icons/VpnKey';
import { Link as RouterLink } from 'react-router-dom';
import useAsync from 'react-use/lib/useAsync';
import { oidcAuthApiRef } from '../apis';
import {
  getAuthentication,
  resolveEffectivePolicies,
  resolveTokenPolicies,
} from '../policies';
import {
  APIProduct,
  EffectivePolicy,
  PortalIdentity,
  ResourceList,
  Subscription,
  TrafficPolicy,
} from '../types';

interface ProductRow extends APIProduct {
  effectivePolicies: EffectivePolicy[];
  authentication: string[];
  commercialProduct?: string;
  subscriptionStatus?: string;
}

export const ApiProductsPage = () => {
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);
  const oidcAuthApi = useApi(oidcAuthApiRef);

  const state = useAsync(async () => {
    const baseUrl = await discoveryApi.getBaseUrl('kuadrant');
    const monetizationBaseUrl = await discoveryApi.getBaseUrl('api-monetization');
    const fetchResource = async <T,>(path: string): Promise<ResourceList<T>> => {
      const response = await fetchApi.fetch(`${baseUrl}/${path}`);
      if (!response.ok) {
        throw new Error(
          `Kuadrant ${path} request failed: HTTP ${response.status}`,
        );
      }
      return response.json() as Promise<ResourceList<T>>;
    };

    const accessToken = await oidcAuthApi.getAccessToken(['openid', 'profile', 'email']);
    const controlRequest = async <T,>(path: string): Promise<T> => {
      const response = await fetchApi.fetch(`${monetizationBaseUrl}/control/user/${path}`, {
        headers: { 'X-API-Monetization-Authorization': `Bearer ${accessToken}` },
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(body.error || `Monetization request failed: HTTP ${response.status}`);
      }
      return body as T;
    };

    const [products, plans, rateLimits, tokenRateLimits, identity] = await Promise.all([
      fetchResource<APIProduct>('apiproducts'),
      fetchResource<TrafficPolicy>('planpolicies'),
      fetchResource<TrafficPolicy>('ratelimitpolicies'),
      fetchApi.fetch(`${monetizationBaseUrl}/tokenratelimitpolicies`).then(async response => {
        if (!response.ok) {
          throw new Error(`TokenRateLimitPolicy request failed: HTTP ${response.status}`);
        }
        return response.json() as Promise<ResourceList<TrafficPolicy>>;
      }),
      controlRequest<PortalIdentity>('me'),
    ]);
    const subscriptions = identity.developer && !identity.admin
      ? await controlRequest<Subscription[]>('me/subscriptions')
      : [];

    return {
      identity,
      rows: products.items.map<ProductRow>(product => {
        const commercialProduct = product.metadata.annotations?.['monetization.arencloud.com/product'];
        return {
          ...product,
          effectivePolicies: [
            ...resolveEffectivePolicies(product, plans.items, rateLimits.items),
            ...resolveTokenPolicies(product, tokenRateLimits.items),
          ],
          authentication: getAuthentication(product),
          commercialProduct,
          subscriptionStatus: subscriptions.find(
            subscription => subscription.product === commercialProduct,
          )?.status,
        };
      }),
    };
  }, [discoveryApi, fetchApi, oidcAuthApi]);

  const rows = useMemo(() => state.value?.rows || [], [state.value]);

  return (
    <Box p={3}>
      <Box mb={3}>
        <Typography variant="h4">API Products</Typography>
        <Typography variant="subtitle1" color="textSecondary">
          Discover APIs and their effective RHCL traffic policies
        </Typography>
      </Box>
      {state.loading && (
        <Box display="flex" justifyContent="center" p={4}>
          <CircularProgress aria-label="Loading API products" />
        </Box>
      )}
      {state.error && (
        <Paper variant="outlined">
          <Box p={2}>
            <Typography color="error">{state.error.message}</Typography>
          </Box>
        </Paper>
      )}
      {state.value && (
        <TableContainer component={Paper} variant="outlined">
          <Table aria-label="API products and effective traffic policies">
            <TableHead>
              <TableRow>
                <TableCell>Name</TableCell>
                <TableCell>Version</TableCell>
                <TableCell>Route</TableCell>
                <TableCell>Effective traffic policy</TableCell>
                <TableCell>Authentication</TableCell>
                <TableCell>Status</TableCell>
                <TableCell>Lifecycle</TableCell>
                <TableCell>Access</TableCell>
                <TableCell>Namespace</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map(row => {
                const subscriptionLocked = Boolean(
                  state.value?.identity.developer &&
                  !state.value.identity.admin &&
                  row.spec?.publishStatus === 'Published' &&
                  row.subscriptionStatus !== 'active',
                );
                const lockedStyle = subscriptionLocked
                  ? { opacity: 0.48, filter: 'grayscale(1)' }
                  : undefined;
                return (
                <TableRow
                  key={`${row.metadata.namespace}/${row.metadata.name}`}
                  style={{ backgroundColor: subscriptionLocked ? '#f3f3f3' : undefined }}
                  aria-disabled={subscriptionLocked}
                  data-subscription-locked={subscriptionLocked ? 'true' : 'false'}
                >
                  <TableCell style={lockedStyle}>
                    {subscriptionLocked ? (
                      <Box display="flex" style={{ gap: 6, alignItems: 'center' }}>
                        <LockIcon fontSize="small" />
                        <Box>
                          <Typography variant="body2"><strong>{row.spec?.displayName || row.metadata.name}</strong></Typography>
                          <Typography variant="caption" color="textSecondary">Subscribe to open</Typography>
                        </Box>
                      </Box>
                    ) : (
                      <MaterialLink
                        component={RouterLink}
                        to={`/kuadrant/api-products/${row.metadata.namespace}/${row.metadata.name}`}
                      >
                        <strong>{row.spec?.displayName || row.metadata.name}</strong>
                      </MaterialLink>
                    )}
                  </TableCell>
                  <TableCell style={lockedStyle}>{row.spec?.version || '-'}</TableCell>
                  <TableCell style={lockedStyle}>{row.spec?.targetRef?.name || '-'}</TableCell>
                  <TableCell style={lockedStyle}>
                    {row.effectivePolicies.length > 0 ? (
                      <Box display="flex" style={{ gap: 6, flexWrap: 'wrap' }}>
                        {row.effectivePolicies.map(policy => (
                          <Chip
                            key={`${policy.kind}/${policy.namespace}/${policy.name}`}
                            label={`${policy.kind}: ${policy.name}`}
                            color={policy.enforced ? 'primary' : 'default'}
                            size="small"
                            variant={policy.enforced ? 'default' : 'outlined'}
                          />
                        ))}
                      </Box>
                    ) : (
                      <Typography variant="body2" color="textSecondary">
                        None discovered
                      </Typography>
                    )}
                  </TableCell>
                  <TableCell style={lockedStyle}>
                    <Box display="flex" style={{ gap: 6, flexWrap: 'wrap' }}>
                      {row.authentication.map(authentication => (
                        <Chip
                          key={authentication}
                          icon={
                            authentication === 'OIDC' ? (
                              <LockIcon />
                            ) : (
                              <VpnKeyIcon />
                            )
                          }
                          label={authentication}
                          size="small"
                          color={
                            authentication === 'OIDC' ? 'secondary' : 'primary'
                          }
                        />
                      ))}
                    </Box>
                  </TableCell>
                  <TableCell style={lockedStyle}>{row.spec?.publishStatus || 'Draft'}</TableCell>
                  <TableCell style={lockedStyle}>
                    <Chip
                      size="small"
                      label={row.spec?.publishStatus === 'Published' ? 'Production' : 'Development'}
                      color={row.spec?.publishStatus === 'Published' ? 'primary' : 'default'}
                    />
                  </TableCell>
                  <TableCell>
                    {state.value?.identity.admin ? (
                      <MaterialLink component={RouterLink} to="/billing">Manage subscriptions</MaterialLink>
                    ) : row.spec?.publishStatus !== 'Published' ? (
                      <Typography variant="body2" color="textSecondary">No subscription required</Typography>
                    ) : row.subscriptionStatus === 'active' ? (
                      <MaterialLink component={RouterLink} to={`/billing?product=${encodeURIComponent(row.commercialProduct || '')}`}>
                        <Chip size="small" color="primary" label="Subscribed" clickable />
                      </MaterialLink>
                    ) : (
                      <MaterialLink component={RouterLink} to={`/billing?product=${encodeURIComponent(row.commercialProduct || '')}`}>
                        <Chip size="small" color="secondary" variant="outlined" label="Subscription required" clickable />
                      </MaterialLink>
                    )}
                  </TableCell>
                  <TableCell style={lockedStyle}>{row.metadata.namespace}</TableCell>
                </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
};
