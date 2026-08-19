import React, { useMemo, useState } from 'react';
import {
  discoveryApiRef,
  fetchApiRef,
  useApi,
} from '@backstage/core-plugin-api';
import {
  Box,
  Chip,
  CircularProgress,
  FormControl,
  InputLabel,
  Link as MaterialLink,
  MenuItem,
  Paper,
  Select,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from '@material-ui/core';
import LockIcon from '@material-ui/icons/Lock';
import { Link as RouterLink } from 'react-router-dom';
import useAsync from 'react-use/lib/useAsync';
import { oidcAuthApiRef } from '../apis';
import { PortalIdentity, Subscription } from '../types';

interface CatalogApiEntity {
  apiVersion: string;
  kind: string;
  metadata: {
    name: string;
    namespace?: string;
    title?: string;
    description?: string;
    tags?: string[];
    annotations?: Record<string, string>;
  };
  spec?: {
    type?: string;
    lifecycle?: string;
    owner?: string;
    system?: string;
  };
}

interface CatalogApiRow extends CatalogApiEntity {
  commercialProduct?: string;
  subscriptionStatus?: string;
}

export const inferCommercialProduct = (entity: CatalogApiEntity): string | undefined => {
  const annotated = entity.metadata.annotations?.['monetization.arencloud.com/product'];
  if (annotated) {
    return annotated;
  }

  // API entities synchronized by the Kuadrant provider intentionally use the
  // admitted APIProduct name as their catalog name and relation key.
  const apiProduct = entity.metadata.annotations?.['kuadrant.io/apiproduct'];
  if (apiProduct?.endsWith('-api-jwt')) return apiProduct.slice(0, -8);
  if (apiProduct?.endsWith('-api')) return apiProduct.slice(0, -4);

  const name = entity.metadata.name.toLowerCase();
  if (name.startsWith('ai-chat')) return 'ai-chat';
  if (name.startsWith('inventory')) return 'inventory';
  if (name.startsWith('payments')) return 'payments';
  return undefined;
};

const displayName = (entity: CatalogApiEntity): string =>
  entity.metadata.title || entity.metadata.name;

export const MonetizedApisPage = () => {
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);
  const oidcAuthApi = useApi(oidcAuthApiRef);
  const [query, setQuery] = useState('');
  const [type, setType] = useState('all');
  const [lifecycle, setLifecycle] = useState('all');

  const state = useAsync(async () => {
    const [catalogBaseUrl, monetizationBaseUrl] = await Promise.all([
      discoveryApi.getBaseUrl('catalog'),
      discoveryApi.getBaseUrl('api-monetization'),
    ]);
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

    const [catalogResponse, identity] = await Promise.all([
      fetchApi.fetch(`${catalogBaseUrl}/entities?filter=kind=api`),
      controlRequest<PortalIdentity>('me'),
    ]);
    if (!catalogResponse.ok) {
      throw new Error(`Catalog API request failed: HTTP ${catalogResponse.status}`);
    }
    const entities = await catalogResponse.json() as CatalogApiEntity[];
    const subscriptions = identity.developer && !identity.admin
      ? await controlRequest<Subscription[]>('me/subscriptions')
      : [];

    const rows = entities.map<CatalogApiRow>(entity => {
      const commercialProduct = inferCommercialProduct(entity);
      return {
        ...entity,
        commercialProduct,
        subscriptionStatus: subscriptions.find(
          subscription => subscription.product === commercialProduct,
        )?.status,
      };
    });
    return { identity, rows };
  }, [discoveryApi, fetchApi, oidcAuthApi]);

  const rows = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return (state.value?.rows || []).filter(row => {
      const matchesQuery = !normalizedQuery || [
        displayName(row),
        row.metadata.description,
        row.spec?.owner,
        row.spec?.system,
      ].some(value => value?.toLowerCase().includes(normalizedQuery));
      const matchesType = type === 'all' || row.spec?.type === type;
      const matchesLifecycle = lifecycle === 'all' || row.spec?.lifecycle === lifecycle;
      return matchesQuery && matchesType && matchesLifecycle;
    });
  }, [lifecycle, query, state.value, type]);

  const types = useMemo(
    () => Array.from(new Set((state.value?.rows || []).map(row => row.spec?.type).filter(Boolean))).sort(),
    [state.value],
  );
  const lifecycles = useMemo(
    () => Array.from(new Set((state.value?.rows || []).map(row => row.spec?.lifecycle).filter(Boolean))).sort(),
    [state.value],
  );

  return (
    <Box p={3}>
      <Box mb={3}>
        <Typography variant="h4">APIs</Typography>
        <Typography variant="subtitle1" color="textSecondary">
          API Monetization API Explorer
        </Typography>
      </Box>
      {state.loading && (
        <Box display="flex" justifyContent="center" p={4}>
          <CircularProgress aria-label="Loading APIs" />
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
        <>
          <Paper variant="outlined">
            <Box p={2} display="flex" style={{ gap: 16, flexWrap: 'wrap' }}>
              <TextField
                label="Search APIs"
                value={query}
                onChange={event => setQuery(event.target.value)}
                variant="outlined"
                size="small"
                style={{ minWidth: 260 }}
              />
              <FormControl variant="outlined" size="small" style={{ minWidth: 180 }}>
                <InputLabel id="api-type-label">Type</InputLabel>
                <Select
                  labelId="api-type-label"
                  label="Type"
                  value={type}
                  onChange={event => setType(event.target.value as string)}
                >
                  <MenuItem value="all">All</MenuItem>
                  {types.map(value => <MenuItem key={value} value={value}>{value}</MenuItem>)}
                </Select>
              </FormControl>
              <FormControl variant="outlined" size="small" style={{ minWidth: 180 }}>
                <InputLabel id="api-lifecycle-label">Lifecycle</InputLabel>
                <Select
                  labelId="api-lifecycle-label"
                  label="Lifecycle"
                  value={lifecycle}
                  onChange={event => setLifecycle(event.target.value as string)}
                >
                  <MenuItem value="all">All</MenuItem>
                  {lifecycles.map(value => <MenuItem key={value} value={value}>{value}</MenuItem>)}
                </Select>
              </FormControl>
            </Box>
          </Paper>
          <Box mt={2}>
            <TableContainer component={Paper} variant="outlined">
              <Table aria-label="Monetized APIs">
                <TableHead>
                  <TableRow>
                    <TableCell>Name</TableCell>
                    <TableCell>System</TableCell>
                    <TableCell>Owner</TableCell>
                    <TableCell>Type</TableCell>
                    <TableCell>Lifecycle</TableCell>
                    <TableCell>Access</TableCell>
                  </TableRow>
                </TableHead>
                <TableBody>
                  {rows.map(row => {
                    const production = row.spec?.lifecycle?.toLowerCase() === 'production';
                    const subscriptionLocked = Boolean(
                      state.value?.identity.developer &&
                      !state.value?.identity.admin &&
                      production &&
                      row.commercialProduct &&
                      row.subscriptionStatus !== 'active',
                    );
                    const lockedStyle = subscriptionLocked
                      ? { opacity: 0.48, filter: 'grayscale(1)' }
                      : undefined;
                    const namespace = row.metadata.namespace || 'default';
                    return (
                      <TableRow
                        key={`${namespace}/${row.metadata.name}`}
                        style={{ backgroundColor: subscriptionLocked ? '#f3f3f3' : undefined }}
                        aria-disabled={subscriptionLocked}
                        data-subscription-locked={subscriptionLocked ? 'true' : 'false'}
                        data-commercial-product={row.commercialProduct || ''}
                      >
                        <TableCell style={lockedStyle}>
                          {subscriptionLocked ? (
                            <Box display="flex" style={{ gap: 6, alignItems: 'center' }}>
                              <LockIcon fontSize="small" />
                              <Box>
                                <Typography variant="body2"><strong>{displayName(row)}</strong></Typography>
                                <Typography variant="caption" color="textSecondary">Subscribe to open</Typography>
                              </Box>
                            </Box>
                          ) : (
                            <MaterialLink
                              component={RouterLink}
                              to={`/catalog/${namespace}/api/${row.metadata.name}`}
                            >
                              <strong>{displayName(row)}</strong>
                            </MaterialLink>
                          )}
                        </TableCell>
                        <TableCell style={lockedStyle}>{row.spec?.system || '-'}</TableCell>
                        <TableCell style={lockedStyle}>{row.spec?.owner || '-'}</TableCell>
                        <TableCell style={lockedStyle}>{row.spec?.type || '-'}</TableCell>
                        <TableCell style={lockedStyle}>{row.spec?.lifecycle || '-'}</TableCell>
                        <TableCell>
                          {state.value?.identity.admin ? (
                            <MaterialLink component={RouterLink} to="/billing">Manage subscriptions</MaterialLink>
                          ) : !production || !row.commercialProduct ? (
                            <Typography variant="body2" color="textSecondary">No subscription required</Typography>
                          ) : row.subscriptionStatus === 'active' ? (
                            <MaterialLink component={RouterLink} to={`/billing?product=${encodeURIComponent(row.commercialProduct)}`}>
                              <Chip size="small" color="primary" label="Subscribed" clickable />
                            </MaterialLink>
                          ) : (
                            <MaterialLink component={RouterLink} to={`/billing?product=${encodeURIComponent(row.commercialProduct)}`}>
                              <Chip size="small" color="secondary" variant="outlined" label="Subscription required" clickable />
                            </MaterialLink>
                          )}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                  {rows.length === 0 && (
                    <TableRow>
                      <TableCell colSpan={6}>
                        <Typography color="textSecondary">No APIs match the selected filters.</Typography>
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        </>
      )}
    </Box>
  );
};
