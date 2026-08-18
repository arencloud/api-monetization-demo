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
  kind: "PlanPolicy" | "RateLimitPolicy";
  name: string;
  namespace: string;
  enforced: boolean;
}
