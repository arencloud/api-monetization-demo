# Subscription data model

The initial schema is bootstrapped into the `monetization` PostgreSQL database
and owned by `monetization_app`. It provides the minimum durable model needed by
the first vertical slice.

| Table | Purpose |
| --- | --- |
| `plans` | Commercial price, included units, overage rate, and enforcement window |
| `api_products` | APIs available for subscription and usage attribution |
| `customers` | Stable customer identity independent of login identity |
| `subscriptions` | Customer/product/plan relationship with optimistic version field |
| `api_credentials` | Prefix and one-way key digest; never the raw API key |
| `plan_changes` | Auditable subscription upgrade and downgrade history |
| `usage_events` | Idempotent request usage records keyed by request ID |
| `invoices` | Rated billing periods and invoice state |

The demo seed creates Free, Developer, Business, and Enterprise plans; Inventory,
Payment, and AI Chat products; and one Free Inventory subscription for Demo
Company.

## Important boundaries

- Authentication identities belong in Keycloak; customer commercial identity
  belongs in this schema.
- Raw API keys are returned once to the caller and are never stored. The service
  stores an Argon2id digest plus a short lookup prefix.
- Gateway telemetry is an input to `usage_events`, not an invoice by itself.
- The active subscription query is the request-time entitlement read model;
  rating, usage aggregation, and invoicing remain asynchronous.
- Usage ingestion must be idempotent by `request_id`.
- Plan upgrades increment `subscriptions.version` and append `plan_changes` in
  the same transaction.
- Money is stored in integer cents and overage price in integer micro-units to
  avoid floating-point billing errors.

The ConfigMap bootstrap is suitable only for creating an empty demo database.
Once the subscription service exists, Flyway-style versioned migrations will be
the authority for subsequent schema changes.
