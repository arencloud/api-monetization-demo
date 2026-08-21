import { billableUnitsFor, remainingUnits, summarizeNativeUsage } from './monetizationPresentation';
import { UsageSummary } from './types';

const usage = (overrides: Partial<UsageSummary>): UsageSummary => ({
  customer: 'demo-developer',
  product: 'inventory',
  requests: 0,
  overageRequests: 0,
  projectedRevenueEuro: 0,
  ...overrides,
});

describe('unit-aware monetization presentation', () => {
  it('never adds tokens and requests into one accepted-unit total', () => {
    const totals = summarizeNativeUsage([
      usage({ product: 'ai-chat', unitName: 'token', billableUnits: 54, requests: 54, promptTokens: 38, completionTokens: 16 }),
      usage({ product: 'demo-app-04', unitName: 'request', billableUnits: 9, requests: 9 }),
      usage({ product: 'inventory', unitName: 'request', billableUnits: 2, requests: 2 }),
    ]);
    expect(totals.requestUnits).toBe(11);
    expect(totals.tokenUnits).toBe(54);
    expect(totals.promptTokens).toBe(38);
    expect(totals.completionTokens).toBe(16);
  });

  it('prefers the explicit native billable-unit contract and retains compatibility', () => {
    expect(billableUnitsFor(usage({ billableUnits: 7, requests: 99 }))).toBe(7);
    expect(billableUnitsFor(usage({ requests: 3 }))).toBe(3);
  });

  it('calculates remaining allowance without returning a negative value', () => {
    expect(remainingUnits(1_000, 54)).toBe(946);
    expect(remainingUnits(10, 12)).toBe(0);
    expect(remainingUnits(undefined, 12)).toBeUndefined();
  });
});

