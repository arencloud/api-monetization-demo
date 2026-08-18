export interface NamespacedName {
  name: string;
  namespace?: string;
}

export interface TargetReference extends NamespacedName {
  kind?: string;
}

export interface Condition {
  type: string;
  status: string;
  reason?: string;
  message?: string;
}

export interface APIProduct {
  metadata: NamespacedName;
  spec?: {
    displayName?: string;
    version?: string;
    publishStatus?: string;
    tags?: string[];
    targetRef?: TargetReference;
  };
  status?: {
    conditions?: Condition[];
    discoveredAuthScheme?: {
      authentication?: Record<string, unknown>;
    };
  };
}

export interface TrafficPolicy {
  metadata: NamespacedName;
  spec?: {
    targetRef?: TargetReference;
  };
  status?: {
    conditions?: Condition[];
  };
}

export interface ResourceList<T> {
  items: T[];
}

export interface EffectivePolicy {
  kind: "PlanPolicy" | "RateLimitPolicy" | "TokenRateLimitPolicy";
  name: string;
  namespace: string;
  enforced: boolean;
}

export interface PortalIdentity {
  username: string;
  admin: boolean;
  developer: boolean;
}

export interface Subscription {
  id: string;
  customerId: string;
  customer: string;
  product: string;
  plan: string;
  planName: string;
  status: string;
  monthlyPriceCents?: number;
  includedRequests?: number;
  monthlyQuotaRequests?: number;
  rateLimitRequests?: number;
  rateLimitWindowSeconds?: number;
}

export interface UsageSummary {
  customer: string;
  product: string;
  requests: number;
  overageRequests: number;
  projectedRevenueEuro: number;
  promptTokens?: number;
  completionTokens?: number;
}

export interface InvoiceItem {
  product: string;
  plan: string;
  description: string;
  billableUnits: number;
  totalCents: number;
}

export interface Invoice {
  id?: string;
  customerId: string;
  customer: string;
  periodStart: string;
  periodEnd: string;
  status: string;
  currency: string;
  subtotalCents: number;
  overageCents: number;
  totalCents: number;
  items: InvoiceItem[];
}

export interface BillingSummary {
  preview: Invoice;
  invoices: Invoice[];
}
