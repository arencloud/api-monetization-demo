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
  Grid,
  Paper,
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
  Invoice,
  PortalIdentity,
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
}

const currency = (cents: number | undefined, code = 'EUR') =>
  new Intl.NumberFormat(undefined, { style: 'currency', currency: code }).format(
    Number(cents || 0) / 100,
  );

export const MonetizationPage = () => {
  const discoveryApi = useApi(discoveryApiRef);
  const fetchApi = useApi(fetchApiRef);
  const oidcAuthApi = useApi(oidcAuthApiRef);

  const state = useAsync(async (): Promise<MonetizationView> => {
    const [baseUrl, accessToken] = await Promise.all([
      discoveryApi.getBaseUrl('api-monetization'),
      oidcAuthApi.getAccessToken(['openid', 'profile', 'email']),
    ]);
    const request = async <T,>(scope: 'user' | 'admin', path: string): Promise<T> => {
      const response = await fetchApi.fetch(`${baseUrl}/control/${scope}/${path}`, {
        headers: {
          'X-API-Monetization-Authorization': `Bearer ${accessToken}`,
        },
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(body.error || `Monetization request failed: HTTP ${response.status}`);
      }
      return body as T;
    };

    const identity = await request<PortalIdentity>('user', 'me');
    if (identity.admin) {
      const [subscriptions, usage, invoices] = await Promise.all([
        request<Subscription[]>('admin', 'subscriptions'),
        request<UsageSummary[]>('admin', 'usage'),
        request<Invoice[]>('admin', 'invoices'),
      ]);
      return { identity, subscriptions, usage, invoices };
    }

    const [subscriptions, usage, billing] = await Promise.all([
      request<Subscription[]>('user', 'me/subscriptions'),
      request<UsageSummary[]>('user', 'me/usage'),
      request<BillingSummary>('user', 'me/billing').catch(() => ({
        preview: undefined,
        invoices: [],
      } as unknown as BillingSummary)),
    ]);
    return {
      identity,
      subscriptions,
      usage,
      invoices: billing.invoices || [],
      preview: billing.preview,
    };
  }, [discoveryApi, fetchApi, oidcAuthApi]);

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
      <Box mb={3}>
        <Typography variant="h4">API Monetization</Typography>
        <Typography variant="subtitle1" color="textSecondary">
          Subscription, accepted usage, token consumption and billing from the monetization control plane
        </Typography>
      </Box>
      {state.loading && (
        <Box display="flex" justifyContent="center" p={4}>
          <CircularProgress aria-label="Loading monetization data" />
        </Box>
      )}
      {state.error && (
        <Paper variant="outlined"><Box p={2}><Typography color="error">{state.error.message}</Typography></Box></Paper>
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
          <Box mt={3}>
            <Typography variant="h5" gutterBottom>Subscriptions and usage</Typography>
            <TableContainer component={Paper} variant="outlined">
              <Table aria-label="API subscriptions and usage">
                <TableHead><TableRow><TableCell>Customer</TableCell><TableCell>Product</TableCell><TableCell>Plan</TableCell><TableCell>Status</TableCell><TableCell align="right">Accepted</TableCell><TableCell align="right">Tokens</TableCell><TableCell align="right">Projected</TableCell></TableRow></TableHead>
                <TableBody>
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
            <Typography variant="h5" gutterBottom>Invoices</Typography>
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
