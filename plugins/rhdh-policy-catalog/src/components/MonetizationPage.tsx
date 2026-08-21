import React, { useCallback, useMemo, useState } from 'react';
import {
  discoveryApiRef,
  fetchApiRef,
  useApi,
} from '@backstage/core-plugin-api';
import {
  Box,
  Button,
  Chip,
  CircularProgress,
  FormControl,
  Grid,
  InputLabel,
  MenuItem,
  Paper,
  Select,
  TextField,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography,
} from '@material-ui/core';
import useAsync from 'react-use/lib/useAsync';
import {
  BillingSummary,
  CredentialState,
  Invoice,
  OwnerAccessRequest,
  OwnerAccessState,
  PortalIdentity,
  ProductCatalog,
  Plan,
  Subscription,
  UsageSummary,
} from '../types';
import { oidcAuthApiRef } from '../apis';

interface MonetizationView {
  identity: PortalIdentity;
  subscriptions: Subscription[];
  usage: UsageSummary[];
  invoices: Invoice[];
  preview?: Invoice;
  catalog?: ProductCatalog;
  credentials: Record<string, CredentialState>;
  ownerAccess?: OwnerAccessState;
  ownerRequests?: OwnerAccessRequest[];
}

interface JwtCredential {
  token: string;
  expiresAt: number;
}

const decodeJwtClaims = (token: string): { aud?: string | string[]; exp?: number } => {
  const payload = token.split('.')[1]?.replace(/-/g, '+').replace(/_/g, '/');
  if (!payload) throw new Error('Keycloak returned an invalid access token');
  return JSON.parse(atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, '=')));
};

const jwtEndpoint = (apiKeyEndpoint: string | undefined): string | undefined => {
  if (!apiKeyEndpoint) return undefined;
  try {
    const endpoint = new URL(apiKeyEndpoint);
    endpoint.hostname = endpoint.hostname.replace(/^api-monetization\./, 'api-monetization-jwt.');
    return endpoint.toString();
  } catch {
    return undefined;
  }
};

const currency = (cents: number | undefined, code = 'EUR') =>
  new Intl.NumberFormat(undefined, { style: 'currency', currency: code }).format(
    Number(cents || 0) / 100,
  );

const unitPrice = (micros: number | undefined, unit: string): string =>
  `${new Intl.NumberFormat(undefined, {
    style: 'currency', currency: 'EUR', minimumFractionDigits: 2, maximumFractionDigits: 6,
  }).format(Number(micros || 0) / 1_000_000)}/${unit}`;

export const planPriceLabel = (plan: Plan, unit: string): string => {
  const monthly = `${currency(plan.monthlyPriceCents)}/month`;
  if (Number(plan.overageMicrosPerRequest || 0) <= 0) return `${plan.displayName} · ${monthly}`;
  const variable = unitPrice(plan.overageMicrosPerRequest, unit);
  if (Number(plan.includedRequests || 0) === 0) return `${plan.displayName} · ${variable}`;
  return `${plan.displayName} · ${monthly} + ${variable} after ${Number(plan.includedRequests).toLocaleString()} included`;
};

export const MonetizationPage = () => {
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);
  const oidcAuthApi = useApi(oidcAuthApiRef);
  const [refresh, setRefresh] = useState(0);
  const [planSelections, setPlanSelections] = useState<Record<string, string>>({});
  const [revealedKeys, setRevealedKeys] = useState<Record<string, string>>({});
  const [revealedJwts, setRevealedJwts] = useState<Record<string, JwtCredential>>({});
  const [pending, setPending] = useState<string>();
  const [notice, setNotice] = useState<{ message: string; error: boolean }>();
  const [ownerJustification, setOwnerJustification] = useState('');

  const request = useCallback(async <T,>(
    scope: 'user' | 'admin',
    path: string,
    options: { method?: string; body?: unknown } = {},
  ): Promise<T> => {
    const [baseUrl, accessToken] = await Promise.all([
      discoveryApi.getBaseUrl('api-monetization'),
      oidcAuthApi.getAccessToken(['openid', 'profile', 'email']),
    ]);
    const response = await fetchApi.fetch(`${baseUrl}/control/${scope}/${path}`, {
      method: options.method || 'GET',
      headers: {
        'X-API-Monetization-Authorization': `Bearer ${accessToken}`,
        ...(options.body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(body.error || `Monetization request failed: HTTP ${response.status}`);
    }
    return body as T;
  }, [discoveryApi, fetchApi, oidcAuthApi]);

  const state = useAsync(async (): Promise<MonetizationView> => {
    void refresh;
    const identity = await request<PortalIdentity>('user', 'me');
    if (identity.admin) {
      const [subscriptions, usage, invoices, ownerRequests] = await Promise.all([
        request<Subscription[]>('admin', 'subscriptions'),
        request<UsageSummary[]>('admin', 'usage'),
        request<Invoice[]>('admin', 'invoices'),
        request<OwnerAccessRequest[]>('admin', 'owner-access-requests'),
      ]);
      return { identity, subscriptions, usage, invoices, ownerRequests, credentials: {} };
    }

    const [catalog, subscriptions, usage, billing, ownerAccess] = await Promise.all([
      request<ProductCatalog>('user', 'catalog'),
      request<Subscription[]>('user', 'me/subscriptions'),
      request<UsageSummary[]>('user', 'me/usage'),
      request<BillingSummary>('user', 'me/billing').catch(() => ({
        preview: undefined,
        invoices: [],
      } as unknown as BillingSummary)),
      request<OwnerAccessState>('user', 'me/owner-access'),
    ]);
    const credentialEntries = await Promise.all(
      subscriptions
        .filter(item => item.status === 'active')
        .map(async item => {
          const credential = await request<CredentialState>(
            'user',
            `me/credentials/${encodeURIComponent(item.product)}/status`,
          ).catch(() => ({ status: 'provisioning', revealed: false } as CredentialState));
          return [item.product, credential] as const;
        }),
    );
    return {
      identity,
      catalog,
      subscriptions,
      usage,
      invoices: billing.invoices || [],
      preview: billing.preview,
      credentials: Object.fromEntries(credentialEntries),
      ownerAccess,
    };
  }, [request, refresh]);

  const runAction = async (key: string, action: () => Promise<void>) => {
    setPending(key);
    setNotice(undefined);
    try {
      await action();
      setRefresh(value => value + 1);
    } catch (error) {
      setNotice({ message: error instanceof Error ? error.message : String(error), error: true });
    } finally {
      setPending(undefined);
    }
  };

  const totals = useMemo(() => {
    const usage = state.value?.usage || [];
    const preview = state.value?.preview;
    return {
      accepted: usage.reduce((sum, item) => sum + Number(item.requests || 0), 0),
      promptTokens: usage.reduce((sum, item) => sum + Number(item.promptTokens || 0), 0),
      completionTokens: usage.reduce((sum, item) => sum + Number(item.completionTokens || 0), 0),
      revenue: preview
        ? Number(preview.totalCents || 0)
        : Math.round(
            usage.reduce((sum, item) => sum + Number(item.projectedRevenueEuro || 0), 0) * 100,
          ),
    };
  }, [state.value]);

  return (
    <Box p={3}>
      <Box mb={3} display="flex" justifyContent="space-between" alignItems="center">
        <Box>
          <Typography variant="h4">API Monetization</Typography>
          <Typography variant="subtitle1" color="textSecondary">
            Subscribe to production APIs and manage your usage, credentials and billing
          </Typography>
        </Box>
        <Button variant="outlined" onClick={() => setRefresh(value => value + 1)}>
          Refresh
        </Button>
      </Box>
      {state.loading && (
        <Box display="flex" justifyContent="center" p={4}>
          <CircularProgress aria-label="Loading monetization data" />
        </Box>
      )}
      {state.error && (
        <Paper variant="outlined"><Box p={2}><Typography color="error">{state.error.message}</Typography></Box></Paper>
      )}
      {notice && (
        <Box mb={2}><Paper variant="outlined"><Box p={2}><Typography color={notice.error ? 'error' : 'primary'}>{notice.message}</Typography></Box></Paper></Box>
      )}
      {state.value && (
        <>
          <Box mb={2} display="flex" style={{ gap: 8, alignItems: 'center' }}>
            <Chip label={state.value.identity.admin ? 'Administrator view' : 'My account'} color="primary" />
            <Typography variant="body2" color="textSecondary">{state.value.identity.username}</Typography>
          </Box>
          <Grid container spacing={2}>
            <Grid item xs={12} sm={6} md={3}><Metric title="Active subscriptions" value={String(state.value.subscriptions.filter(item => item.status === 'active').length)} /></Grid>
            <Grid item xs={12} sm={6} md={3}><Metric title="Accepted units" value={totals.accepted.toLocaleString()} /></Grid>
            <Grid item xs={12} sm={6} md={3}><Metric title="AI tokens" value={(totals.promptTokens + totals.completionTokens).toLocaleString()} detail={`${totals.promptTokens.toLocaleString()} prompt · ${totals.completionTokens.toLocaleString()} completion`} /></Grid>
            <Grid item xs={12} sm={6} md={3}><Metric title={state.value.identity.admin ? 'Projected revenue' : 'Current estimate'} value={currency(totals.revenue)} /></Grid>
          </Grid>

          {!state.value.identity.admin && state.value.ownerAccess && (
            <Box mt={3}>
              <Paper variant="outlined" data-testid="owner-access-panel">
                <Box p={3} style={{ borderTop: '4px solid #ee0000' }}>
                  <Typography variant="overline" style={{ color: '#c9190b', fontWeight: 700 }}>
                    API OWNER ONBOARDING
                  </Typography>
                  <Typography variant="h5" gutterBottom>
                    {state.value.ownerAccess.owner ? 'API owner access active' : 'Build and publish governed APIs'}
                  </Typography>
                  {state.value.ownerAccess.owner ? (
                    <Typography variant="body2" color="textSecondary">
                      Your approved owner identity can use Golden Paths, OpenShift Dev Spaces and the governed publication workflow.
                    </Typography>
                  ) : state.value.ownerAccess.request?.status === 'pending' ? (
                    <>
                      <Chip size="small" label="Approval pending" color="secondary" />
                      <Box mt={1}>
                        <Typography variant="body2" color="textSecondary">
                          Submitted {new Date(state.value.ownerAccess.request.createdAt).toLocaleString()}. An API administrator must approve publisher access.
                        </Typography>
                      </Box>
                    </>
                  ) : (
                    <>
                      <Typography variant="body2" color="textSecondary">
                        Owner access is privileged. Describe the API domain you will own and an administrator will review the request.
                      </Typography>
                      {state.value.ownerAccess.request?.status === 'rejected' && (
                        <Box mt={1}>
                          <Typography color="error">
                            Previous request rejected{state.value.ownerAccess.request.decisionReason ? `: ${state.value.ownerAccess.request.decisionReason}` : '.'}
                          </Typography>
                        </Box>
                      )}
                      <Box mt={2} display="flex" style={{ gap: 12, alignItems: 'flex-start', flexWrap: 'wrap' }}>
                        <TextField
                          variant="outlined"
                          size="small"
                          multiline
                          minRows={2}
                          label="Ownership justification"
                          placeholder="Example: I own the customer profile domain and need to publish its supported API contract."
                          value={ownerJustification}
                          onChange={event => setOwnerJustification(event.target.value)}
                          inputProps={{ maxLength: 1000 }}
                          style={{ minWidth: 320, flex: 1 }}
                        />
                        <Button
                          color="primary"
                          variant="contained"
                          disabled={Boolean(pending) || ownerJustification.trim().length < 10}
                          onClick={() => runAction('owner-request', async () => {
                            await request('user', 'me/owner-access', {
                              method: 'POST', body: { justification: ownerJustification.trim() },
                            });
                            setOwnerJustification('');
                            setNotice({ message: 'API owner access request submitted for administrator review.', error: false });
                          })}
                        >{pending === 'owner-request' ? 'Submitting…' : 'Request owner access'}</Button>
                      </Box>
                    </>
                  )}
                </Box>
              </Paper>
            </Box>
          )}

          {state.value.identity.admin && (
            <Box mt={3}>
              <Typography variant="h5" gutterBottom>API owner access approvals</Typography>
              <Typography variant="body2" color="textSecondary">
                Approval adds the user to the Keycloak API owner group, removes the consumer-only catalog restriction and preserves an auditable decision.
              </Typography>
              <Box mt={1}>
                <TableContainer component={Paper} variant="outlined">
                  <Table aria-label="API owner access requests">
                    <TableHead><TableRow><TableCell>Applicant</TableCell><TableCell>Justification</TableCell><TableCell>Status</TableCell><TableCell>Submitted</TableCell><TableCell align="right">Decision</TableCell></TableRow></TableHead>
                    <TableBody>
                      {(state.value.ownerRequests || []).length === 0 && <TableRow><TableCell colSpan={5}>No API owner access requests.</TableCell></TableRow>}
                      {(state.value.ownerRequests || []).map(item => (
                        <TableRow key={item.id}>
                          <TableCell><Typography variant="body2">{item.username}</Typography><Typography variant="caption" color="textSecondary">{item.email}</Typography></TableCell>
                          <TableCell>{item.justification}{item.decisionReason ? <Typography variant="caption" display="block" color="textSecondary">Decision: {item.decisionReason}</Typography> : null}</TableCell>
                          <TableCell><Chip size="small" label={item.status} color={item.status === 'approved' ? 'primary' : item.status === 'rejected' ? 'secondary' : 'default'} /></TableCell>
                          <TableCell>{new Date(item.createdAt).toLocaleString()}</TableCell>
                          <TableCell align="right">
                            {item.status === 'pending' ? (
                              <Box display="flex" justifyContent="flex-end" style={{ gap: 8 }}>
                                <Button
                                  size="small"
                                  color="primary"
                                  variant="contained"
                                  disabled={Boolean(pending)}
                                  onClick={() => runAction(`approve-${item.id}`, async () => {
                                    await request('admin', `owner-access-requests/${item.id}/decision`, {
                                      method: 'POST', body: { decision: 'approved', reason: 'Approved by API platform administrator' },
                                    });
                                    setNotice({ message: `${item.username} approved as an API owner. Ask the user to sign out and back in.`, error: false });
                                  })}
                                >Approve</Button>
                                <Button
                                  size="small"
                                  color="secondary"
                                  variant="outlined"
                                  disabled={Boolean(pending)}
                                  onClick={() => runAction(`reject-${item.id}`, async () => {
                                    const reason = window.prompt('Reason for rejecting API owner access:')?.trim();
                                    if (!reason) return;
                                    await request('admin', `owner-access-requests/${item.id}/decision`, {
                                      method: 'POST', body: { decision: 'rejected', reason },
                                    });
                                    setNotice({ message: `${item.username} owner request rejected.`, error: false });
                                  })}
                                >Reject</Button>
                              </Box>
                            ) : item.reviewedBy || '—'}
                          </TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                </TableContainer>
              </Box>
            </Box>
          )}

          {!state.value.identity.admin && state.value.catalog && (
            <Box mt={3}>
              <Typography variant="h5" gutterBottom>Production API subscriptions</Typography>
              <Typography variant="body2" color="textSecondary">
                A subscription is required before a production API accepts either an API key or a Keycloak JWT. One subscription covers both authentication options for the product.
              </Typography>
              <Box mt={1}>
                <Grid container spacing={2}>
                  {state.value.catalog.products.filter(product => product.available).map(product => {
                    const subscription = state.value?.subscriptions.find(item => item.product === product.id);
                    const credential = state.value?.credentials[product.id];
                    const productPlans = product.plans || state.value?.catalog?.plans.filter(
                      plan => product.planIds.includes(plan.id),
                    ) || [];
                    const selectedPlan = planSelections[product.id] || subscription?.plan ||
                      (product.planIds.includes('free') ? 'free' : productPlans[0]?.id || '');
                    const actionKey = `${product.id}-action`;
                    return (
                      <Grid item xs={12} md={6} lg={4} key={product.id}>
                        <Paper variant="outlined" data-testid={`subscription-${product.id}`}>
                          <Box p={2}>
                            <Box display="flex" justifyContent="space-between" alignItems="center">
                              <Typography variant="h6">{product.displayName}</Typography>
                              <Chip
                                size="small"
                                label={subscription ? subscription.status : 'Subscription required'}
                                color={subscription?.status === 'active' ? 'primary' : 'default'}
                                variant={subscription?.status === 'active' ? 'default' : 'outlined'}
                              />
                            </Box>
                            <Box mt={1} minHeight={42}>
                              <Typography variant="body2" color="textSecondary">{product.description}</Typography>
                            </Box>
                            <Box mt={2} display="flex" style={{ gap: 8, alignItems: 'center' }}>
                              <FormControl variant="outlined" size="small" style={{ minWidth: 180, flex: 1 }}>
                                <InputLabel id={`${product.id}-plan-label`}>Plan</InputLabel>
                                <Select
                                  labelId={`${product.id}-plan-label`}
                                  value={selectedPlan}
                                  onChange={event => setPlanSelections(current => ({ ...current, [product.id]: String(event.target.value) }))}
                                  label="Plan"
                                >
                                  {productPlans.map(plan => (
                                    <MenuItem key={plan.id} value={plan.id}>
                                      {planPriceLabel(plan, product.unitName)}
                                    </MenuItem>
                                  ))}
                                </Select>
                              </FormControl>
                              {!subscription ? (
                                <Button
                                  color="primary"
                                  variant="contained"
                                  disabled={Boolean(pending)}
                                  data-testid={`subscribe-${product.id}`}
                                  onClick={() => runAction(actionKey, async () => {
                                    await request('user', 'me/subscriptions', {
                                      method: 'POST', body: { product: product.id, plan: selectedPlan },
                                    });
                                    setNotice({ message: `${product.displayName} subscription created. Credential provisioning has started.`, error: false });
                                  })}
                                >
                                  {pending === actionKey ? 'Working…' : 'Subscribe'}
                                </Button>
                              ) : (
                                <Button
                                  color="primary"
                                  variant="contained"
                                  disabled={Boolean(pending) || subscription.status !== 'active' || selectedPlan === subscription.plan}
                                  onClick={() => runAction(actionKey, async () => {
                                    await request('user', `me/subscriptions/${encodeURIComponent(product.id)}/plan`, {
                                      method: 'POST', body: { plan: selectedPlan },
                                    });
                                    setNotice({ message: `${product.displayName} plan changed without restarting the gateway.`, error: false });
                                  })}
                                >Change plan</Button>
                              )}
                            </Box>
                            {subscription && (
                              <>
                                <Box mt={2} display="flex" style={{ gap: 8, flexWrap: 'wrap' }}>
                                  <Button
                                    variant="outlined"
                                    disabled={Boolean(pending) || subscription.status !== 'active' || credential?.status !== 'ready' || credential.revealed}
                                    data-testid={`reveal-${product.id}`}
                                    onClick={() => runAction(`${product.id}-reveal`, async () => {
                                      const revealed = await request<CredentialState>('user', `me/credentials/${encodeURIComponent(product.id)}/reveal`, { method: 'POST' });
                                      if (revealed.apiKey) setRevealedKeys(current => ({ ...current, [product.id]: revealed.apiKey! }));
                                      setNotice({ message: `Copy the ${product.displayName} API key now; it is shown only once.`, error: false });
                                    })}
                                  >Reveal API key</Button>
                                  <Button
                                    variant="outlined"
                                    disabled={Boolean(pending) || subscription.status !== 'active' || credential?.status === 'provisioning'}
                                    onClick={() => runAction(`${product.id}-rotate`, async () => {
                                      await request('user', `me/credentials/${encodeURIComponent(product.id)}/rotate`, { method: 'POST' });
                                      setRevealedKeys(current => {
                                        const next = { ...current };
                                        delete next[product.id];
                                        return next;
                                      });
                                      setNotice({ message: `${product.displayName} API key rotation started.`, error: false });
                                    })}
                                  >Rotate API key</Button>
                                  <Button
                                    variant="outlined"
                                    disabled={Boolean(pending) || subscription.status !== 'active'}
                                    data-testid={`jwt-${product.id}`}
                                    onClick={() => runAction(`${product.id}-jwt`, async () => {
                                      const token = await oidcAuthApi.getAccessToken(['openid', 'profile', 'email']);
                                      const claims = decodeJwtClaims(token);
                                      const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
                                      if (!audiences.includes('api-monetization')) {
                                        throw new Error('The RHDH Keycloak token is missing the API gateway audience. Sign out and sign in again.');
                                      }
                                      if (!claims.exp) throw new Error('The Keycloak access token has no expiry');
                                      setRevealedJwts(current => ({
                                        ...current,
                                        [product.id]: { token, expiresAt: claims.exp! * 1000 },
                                      }));
                                      setNotice({ message: `${product.displayName} Keycloak JWT is ready to copy.`, error: false });
                                    })}
                                  >Get Keycloak JWT</Button>
                                  <Button
                                    color="secondary"
                                    variant="outlined"
                                    disabled={Boolean(pending)}
                                    data-testid={`cancel-${product.id}`}
                                    onClick={() => runAction(`${product.id}-cancel`, async () => {
                                      if (!window.confirm(`Cancel ${product.displayName}? API-key and JWT access will be denied immediately.`)) return;
                                      await request('user', `me/subscriptions/${encodeURIComponent(product.id)}/cancel`, {
                                        method: 'POST', body: { version: subscription.version },
                                      });
                                      setRevealedKeys(current => {
                                        const next = { ...current };
                                        delete next[product.id];
                                        return next;
                                      });
                                      setRevealedJwts(current => {
                                        const next = { ...current };
                                        delete next[product.id];
                                        return next;
                                      });
                                      setNotice({ message: `${product.displayName} subscription cancelled; API-key and JWT access is revoked.`, error: false });
                                    })}
                                  >Cancel</Button>
                                </Box>
                                <Box mt={1}>
                                  <Typography variant="caption" color="textSecondary">
                                    API key: {credential?.status || (subscription.status === 'active' ? 'provisioning' : 'unavailable')}
                                    {credential?.endpoint ? ` · ${credential.endpoint}` : ''}
                                  </Typography>
                                </Box>
                                {revealedKeys[product.id] && (
                                  <Box mt={1} p={1} style={{ background: '#f5f5f5', overflowWrap: 'anywhere' }}>
                                    <Typography variant="caption">One-time API key</Typography>
                                    <Typography component="code" display="block" data-testid={`api-key-${product.id}`}>{revealedKeys[product.id]}</Typography>
                                  </Box>
                                )}
                                {revealedJwts[product.id] && (
                                  <Box mt={1} p={1} style={{ background: '#f5f5f5', overflowWrap: 'anywhere' }}>
                                    <Typography variant="caption">
                                      Keycloak JWT · expires {new Date(revealedJwts[product.id].expiresAt).toLocaleTimeString()}
                                      {jwtEndpoint(credential?.endpoint) ? ` · ${jwtEndpoint(credential?.endpoint)}` : ''}
                                    </Typography>
                                    <Typography component="code" display="block" data-testid={`jwt-token-${product.id}`}>
                                      {revealedJwts[product.id].token}
                                    </Typography>
                                    <Box mt={1}>
                                      <Button
                                        size="small"
                                        variant="outlined"
                                        onClick={() => navigator.clipboard.writeText(revealedJwts[product.id].token)}
                                      >Copy JWT</Button>
                                    </Box>
                                  </Box>
                                )}
                              </>
                            )}
                          </Box>
                        </Paper>
                      </Grid>
                    );
                  })}
                </Grid>
              </Box>
            </Box>
          )}

          <Box mt={3}>
            <Typography variant="h5" gutterBottom>{state.value.identity.admin ? 'All subscriptions and usage' : 'My subscriptions and usage'}</Typography>
            <TableContainer component={Paper} variant="outlined">
              <Table aria-label="API subscriptions and usage">
                <TableHead><TableRow><TableCell>{state.value.identity.admin ? 'Customer' : 'Account'}</TableCell><TableCell>Product</TableCell><TableCell>Plan</TableCell><TableCell>Status</TableCell><TableCell align="right">Accepted</TableCell><TableCell align="right">Tokens</TableCell><TableCell align="right">Projected</TableCell></TableRow></TableHead>
                <TableBody>
                  {state.value.subscriptions.length === 0 && <TableRow><TableCell colSpan={7}>No subscriptions yet. Subscribe to a production API above to begin.</TableCell></TableRow>}
                  {state.value.subscriptions.map(subscription => {
                    const usage = state.value?.usage.find(item => item.customer === subscription.customerId && item.product === subscription.product) || state.value?.usage.find(item => item.product === subscription.product);
                    return (
                      <TableRow key={subscription.id}>
                        <TableCell>{subscription.customer}</TableCell>
                        <TableCell>{subscription.product}</TableCell>
                        <TableCell>{subscription.planName}</TableCell>
                        <TableCell><Chip size="small" label={subscription.status} color={subscription.status === 'active' ? 'primary' : 'default'} /></TableCell>
                        <TableCell align="right">{Number(usage?.requests || 0).toLocaleString()}</TableCell>
                        <TableCell align="right">{(Number(usage?.promptTokens || 0) + Number(usage?.completionTokens || 0)).toLocaleString()}</TableCell>
                        <TableCell align="right">{currency(Math.round(Number(usage?.projectedRevenueEuro || 0) * 100))}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
          <Box mt={3}>
            <Typography variant="h5" gutterBottom>{state.value.identity.admin ? 'Invoices' : 'My invoices'}</Typography>
            <TableContainer component={Paper} variant="outlined">
              <Table aria-label="Invoices">
                <TableHead><TableRow><TableCell>Customer</TableCell><TableCell>Period</TableCell><TableCell>Status</TableCell><TableCell align="right">Billable units</TableCell><TableCell align="right">Total</TableCell></TableRow></TableHead>
                <TableBody>
                  {state.value.invoices.length === 0 && <TableRow><TableCell colSpan={5}>No persisted invoices yet.</TableCell></TableRow>}
                  {state.value.invoices.map((invoice, index) => (
                    <TableRow key={invoice.id || `${invoice.customerId}-${invoice.periodStart}-${index}`}>
                      <TableCell>{invoice.customer}</TableCell><TableCell>{invoice.periodStart} – {invoice.periodEnd}</TableCell><TableCell>{invoice.status}</TableCell><TableCell align="right">{(invoice.items || []).reduce((sum, item) => sum + Number(item.billableUnits || 0), 0).toLocaleString()}</TableCell><TableCell align="right">{currency(invoice.totalCents, invoice.currency)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </TableContainer>
          </Box>
        </>
      )}
    </Box>
  );
};

const Metric = ({ title, value, detail }: { title: string; value: string; detail?: string }) => (
  <Paper variant="outlined"><Box p={2}><Typography variant="overline" color="textSecondary">{title}</Typography><Typography variant="h4">{value}</Typography>{detail && <Typography variant="body2" color="textSecondary">{detail}</Typography>}</Box></Paper>
);
