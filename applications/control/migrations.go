package main

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

const subscriptionIdentityMigration = `
CREATE TABLE IF NOT EXISTS monetization.schema_migrations (
  version integer PRIMARY KEY,
  description text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS monetization.subscription_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id uuid NOT NULL REFERENCES monetization.customers(id),
  provider text NOT NULL,
  subject text NOT NULL,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscription_identities_unique UNIQUE (provider, subject),
  CONSTRAINT subscription_identities_status CHECK (status IN ('active', 'revoked'))
);

CREATE INDEX IF NOT EXISTS subscription_identities_lookup
  ON monetization.subscription_identities (provider, subject)
  WHERE status = 'active';

INSERT INTO monetization.subscription_identities (customer_id, provider, subject)
SELECT c.id, 'keycloak-client', 'demo-free-client'
FROM monetization.customers c
WHERE c.external_id = 'demo-company'
ON CONFLICT (provider, subject) DO NOTHING;
`

const selfServiceCredentialMigration = `
ALTER TABLE monetization.api_credentials
  ADD COLUMN IF NOT EXISTS kubernetes_name text UNIQUE,
  ADD COLUMN IF NOT EXISTS secret_name text UNIQUE,
  ADD COLUMN IF NOT EXISTS revealed_at timestamptz;
`

const billingLifecycleMigration = `
DROP INDEX IF EXISTS monetization.subscriptions_one_active_product;
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_one_current_product
  ON monetization.subscriptions (customer_id, api_product_id)
  WHERE status IN ('active', 'suspended');

ALTER TABLE monetization.invoices
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS invoices_customer_period
  ON monetization.invoices (customer_id, period_start, period_end);

CREATE TABLE IF NOT EXISTS monetization.invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES monetization.invoices(id) ON DELETE CASCADE,
  subscription_id uuid NOT NULL REFERENCES monetization.subscriptions(id),
  api_product_id text NOT NULL REFERENCES monetization.api_products(id),
  plan_id text NOT NULL REFERENCES monetization.plans(id),
  description text NOT NULL,
  billable_units bigint NOT NULL DEFAULT 0,
  included_units bigint,
  overage_units bigint NOT NULL DEFAULT 0,
  base_cents bigint NOT NULL DEFAULT 0,
  overage_cents bigint NOT NULL DEFAULT 0,
  total_cents bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoice_items_amounts_nonnegative CHECK (
    billable_units >= 0 AND overage_units >= 0 AND base_cents >= 0
    AND overage_cents >= 0 AND total_cents >= 0
  ),
  CONSTRAINT invoice_items_subscription_unique UNIQUE (invoice_id, subscription_id)
);

CREATE TABLE IF NOT EXISTS monetization.subscription_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id uuid NOT NULL REFERENCES monetization.subscriptions(id),
  event_type text NOT NULL,
  actor text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS subscription_events_subscription_time
  ON monetization.subscription_events (subscription_id, occurred_at DESC);
`

const meteredPlanMigration = `
ALTER TABLE monetization.plans
  ADD COLUMN IF NOT EXISTS monthly_quota_requests bigint;

UPDATE monetization.plans SET monthly_quota_requests=1000 WHERE id='free';
UPDATE monetization.plans SET monthly_quota_requests=1000000 WHERE id='developer';
UPDATE monetization.plans SET monthly_quota_requests=50000000 WHERE id='business';
UPDATE monetization.plans SET monthly_quota_requests=NULL WHERE id='enterprise';

INSERT INTO monetization.plans
  (id, display_name, monthly_price_cents, included_requests,
   monthly_quota_requests, rate_limit_requests, rate_limit_window_seconds,
   overage_micros_per_request, active)
VALUES ('payg', 'Pay as you go', 0, 0, 10000, 100, 60, 10000, true)
ON CONFLICT (id) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  monthly_price_cents=EXCLUDED.monthly_price_cents,
  included_requests=EXCLUDED.included_requests,
  monthly_quota_requests=EXCLUDED.monthly_quota_requests,
  rate_limit_requests=EXCLUDED.rate_limit_requests,
  rate_limit_window_seconds=EXCLUDED.rate_limit_window_seconds,
  overage_micros_per_request=EXCLUDED.overage_micros_per_request,
  active=true,
  updated_at=now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='plans_quota_nonnegative'
      AND conrelid='monetization.plans'::regclass
  ) THEN
    ALTER TABLE monetization.plans ADD CONSTRAINT plans_quota_nonnegative
      CHECK (monthly_quota_requests IS NULL OR monthly_quota_requests > 0);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='plans_allowance_within_quota'
      AND conrelid='monetization.plans'::regclass
  ) THEN
    ALTER TABLE monetization.plans ADD CONSTRAINT plans_allowance_within_quota
      CHECK (monthly_quota_requests IS NULL OR included_requests IS NULL
        OR included_requests <= monthly_quota_requests);
  END IF;
END $$;
`

const aiChatProductMigration = `
INSERT INTO monetization.api_products
  (id, display_name, description, unit_name, active)
VALUES
  ('ai-chat', 'AI Chat API',
   'CPU-hosted chat inference billed by prompt and completion tokens',
   'token', true)
ON CONFLICT (id) DO UPDATE SET
  display_name=EXCLUDED.display_name,
  description=EXCLUDED.description,
  unit_name=EXCLUDED.unit_name,
  active=true;
`

const dynamicProductCatalogMigration = `
CREATE TABLE IF NOT EXISTS monetization.api_product_plans (
  api_product_id text NOT NULL REFERENCES monetization.api_products(id) ON DELETE CASCADE,
  plan_id text NOT NULL REFERENCES monetization.plans(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (api_product_id, plan_id)
);

INSERT INTO monetization.api_product_plans (api_product_id, plan_id)
SELECT product.id, plan.id
FROM monetization.api_products product
CROSS JOIN monetization.plans plan
WHERE product.id IN ('inventory', 'payments', 'ai-chat')
ON CONFLICT DO NOTHING;
`

const ownerAccessRequestMigration = `
CREATE TABLE IF NOT EXISTS monetization.owner_access_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject text NOT NULL,
  username text NOT NULL,
  email text NOT NULL DEFAULT '',
  justification text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  reviewed_by text,
  decision_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  CONSTRAINT owner_access_request_status
    CHECK (status IN ('pending', 'approved', 'rejected')),
  CONSTRAINT owner_access_request_justification_length
    CHECK (char_length(justification) BETWEEN 10 AND 1000)
);

CREATE UNIQUE INDEX IF NOT EXISTS owner_access_requests_one_pending_subject
  ON monetization.owner_access_requests (subject)
  WHERE status='pending';

CREATE INDEX IF NOT EXISTS owner_access_requests_status_time
  ON monetization.owner_access_requests (status, created_at DESC);
`

func applyDatabaseMigrations(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err = tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", int64(607441829)); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, subscriptionIdentityMigration); err != nil {
		return fmt.Errorf("apply subscription identity migration: %w", err)
	}
	if _, err = tx.Exec(ctx, selfServiceCredentialMigration); err != nil {
		return fmt.Errorf("apply self-service credential migration: %w", err)
	}
	if _, err = tx.Exec(ctx, billingLifecycleMigration); err != nil {
		return fmt.Errorf("apply billing lifecycle migration: %w", err)
	}
	if _, err = tx.Exec(ctx, meteredPlanMigration); err != nil {
		return fmt.Errorf("apply metered plan migration: %w", err)
	}
	if _, err = tx.Exec(ctx, aiChatProductMigration); err != nil {
		return fmt.Errorf("apply AI Chat product migration: %w", err)
	}
	if _, err = tx.Exec(ctx, dynamicProductCatalogMigration); err != nil {
		return fmt.Errorf("apply dynamic product catalog migration: %w", err)
	}
	if _, err = tx.Exec(ctx, ownerAccessRequestMigration); err != nil {
		return fmt.Errorf("apply owner access request migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (1, 'keycloak client to subscription identity mapping')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record subscription identity migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (2, 'self-service API credential resource tracking')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record self-service migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (3, 'invoice items and subscription lifecycle')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record billing lifecycle migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (4, 'separate included allowance from hard quota and add payg plan')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record metered plan migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (5, 'publish token-metered AI Chat product')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record AI Chat product migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (6, 'discover published APIProducts and their available plans')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record dynamic product catalog migration: %w", err)
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO monetization.schema_migrations (version, description)
		VALUES (7, 'audited API owner access requests and approval decisions')
		ON CONFLICT (version) DO NOTHING`); err != nil {
		return fmt.Errorf("record owner access request migration: %w", err)
	}
	return tx.Commit(ctx)
}
