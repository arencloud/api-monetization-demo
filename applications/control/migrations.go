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
	return tx.Commit(ctx)
}
