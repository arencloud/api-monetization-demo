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
import {
  getAuthentication,
  resolveEffectivePolicies,
  resolveTokenPolicies,
} from '../policies';
import {
  APIProduct,
  EffectivePolicy,
  ResourceList,
  TrafficPolicy,
} from '../types';

interface ProductRow extends APIProduct {
  effectivePolicies: EffectivePolicy[];
  authentication: string[];
}

export const ApiProductsPage = () => {
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);

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

    const [products, plans, rateLimits, tokenRateLimits] = await Promise.all([
      fetchResource<APIProduct>('apiproducts'),
      fetchResource<TrafficPolicy>('planpolicies'),
      fetchResource<TrafficPolicy>('ratelimitpolicies'),
      fetchApi.fetch(`${monetizationBaseUrl}/tokenratelimitpolicies`).then(async response => {
        if (!response.ok) {
          throw new Error(`TokenRateLimitPolicy request failed: HTTP ${response.status}`);
        }
        return response.json() as Promise<ResourceList<TrafficPolicy>>;
      }),
    ]);

    return products.items.map<ProductRow>(product => ({
      ...product,
      effectivePolicies: [
        ...resolveEffectivePolicies(product, plans.items, rateLimits.items),
        ...resolveTokenPolicies(product, tokenRateLimits.items),
      ],
      authentication: getAuthentication(product),
    }));
  }, [discoveryApi, fetchApi]);

  const rows = useMemo(() => state.value || [], [state.value]);

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
                <TableCell>Namespace</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map(row => (
                <TableRow key={`${row.metadata.namespace}/${row.metadata.name}`}>
                  <TableCell>
                    <MaterialLink
                      component={RouterLink}
                      to={`/kuadrant/api-products/${row.metadata.namespace}/${row.metadata.name}`}
                    >
                      <strong>{row.spec?.displayName || row.metadata.name}</strong>
                    </MaterialLink>
                  </TableCell>
                  <TableCell>{row.spec?.version || '-'}</TableCell>
                  <TableCell>{row.spec?.targetRef?.name || '-'}</TableCell>
                  <TableCell>
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
                  <TableCell>
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
                  <TableCell>{row.spec?.publishStatus || 'Draft'}</TableCell>
                  <TableCell>{row.metadata.namespace}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
};
