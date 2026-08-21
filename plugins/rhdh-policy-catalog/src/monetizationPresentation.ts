import { UsageSummary } from './types';

export interface NativeUsageTotals {
  requestUnits: number;
  tokenUnits: number;
  promptTokens: number;
  completionTokens: number;
  otherUnits: Record<string, number>;
}

export const normalizedUnitName = (unitName?: string): string =>
  unitName?.trim().toLowerCase() || 'request';

export const billableUnitsFor = (usage?: UsageSummary): number =>
  Number(usage?.billableUnits ?? usage?.requests ?? 0);

export const summarizeNativeUsage = (usage: UsageSummary[]): NativeUsageTotals =>
  usage.reduce<NativeUsageTotals>((totals, item) => {
    const unit = normalizedUnitName(item.unitName);
    const billableUnits = billableUnitsFor(item);
    if (unit === 'request') totals.requestUnits += billableUnits;
    else if (unit === 'token') totals.tokenUnits += billableUnits;
    else totals.otherUnits[unit] = (totals.otherUnits[unit] || 0) + billableUnits;
    if (unit === 'token') {
      totals.promptTokens += Number(item.promptTokens || 0);
      totals.completionTokens += Number(item.completionTokens || 0);
    }
    return totals;
  }, {
    requestUnits: 0,
    tokenUnits: 0,
    promptTokens: 0,
    completionTokens: 0,
    otherUnits: {},
  });

export const remainingUnits = (limit: number | undefined, consumed: number): number | undefined =>
  limit === undefined || limit === null ? undefined : Math.max(Number(limit) - consumed, 0);

