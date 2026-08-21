# Subscription data model

[Project home](../../README.md) · [Documentation](../README.md) · [Architecture](../architecture.md) · **Subscription model**

> PostgreSQL is the commercial system of record. Keycloak proves identity and
> Connectivity Link enforces decisions, but neither stores the authoritative
> customer plan or invoice state.

The initial schema is bootstrapped into the `monetization` PostgreSQL database
and owned by `monetization_app`. It provides the minimum durable model needed by
the first vertical slice.

| Table | Purpose |
| --- | --- |
| `plans` | Commercial price, included units, hard quota, overage rate, and enforcement window |
| `api_products` | APIs available for subscription and usage attribution |
| `api_product_plans` | Product availability plus optional owner-defined prices, allowances, quotas, and request-rate overrides |
| `customers` | Stable customer identity independent of login identity |
| `subscriptions` | Customer/product/plan relationship with optimistic version field |
| `subscription_identities` | External provider identity mapped to one commercial customer |
| `api_credentials` | Operator resource names, prefix, one-way key digest, and reveal state; never the raw API key |
| `plan_changes` | Auditable subscription upgrade and downgrade history |
| `usage_events` | Idempotent request usage records keyed by request ID |
| `invoices` | Rated billing periods and invoice state |
| `invoice_items` | Per-subscription draft lines with allowance, overage, and integer monetary totals |
| `subscription_events` | Suspension, resumption, and cancellation audit events with actor metadata |
| `schema_migrations` | Idempotent control-service schema migration history |

The demo seed creates Free, Pay as you go, Developer, Business, and Enterprise
plans; Inventory, Payment, and AI Chat products; and one Free Inventory
subscription for Demo Company. All three products are enabled end to end. AI
Chat uses `token` as its native commercial unit, while Inventory and Payment
use `request`.

Built-in products inherit the defaults in `plans`. A published Golden Path
product stores reviewed overrides in `api_product_plans`, so the same plan name
can cost €0.01 per request for one product and €0.02 per request for another.
Subscriptions and invoices always resolve the terms for their product and plan.

## Important boundaries

- Authentication identities belong in Keycloak; customer commercial identity
  belongs in this schema. JWTs carry identity and audience, never an
  authoritative commercial plan.
- Raw API keys are generated into an immutable Kubernetes Secret by External
  Secrets and displayed by the portal once. PostgreSQL stores a SHA-256 digest
  of the high-entropy key plus a short lookup prefix, never the raw value.
  Rotation retains that digest as revoked history while clearing reusable
  Kubernetes resource references for the replacement credential.
- Gateway telemetry is an input to `usage_events`, not an invoice by itself.
- AI usage attributes retain the vLLM model, prompt-token, and
  completion-token breakdown; `billable_units` stores their total.
- Connectivity Link limits AI request frequency before inference and uses
  `TokenRateLimitPolicy` to add the post-response `usage.total_tokens` value to
  a subscription-and-plan Limitador counter. The immutable subscription UUID
  keeps a live plan change on the same counter while a later resubscription
  starts a clean commercial lifecycle. The monthly hard quota and commercial
  allowance are therefore token-based; the request safety cap remains a
  deliberately separate control.
- Included allowance and hard quota are separate. Accepted usage above the
  allowance is billable overage until the hard quota is reached; rejected HTTP
  429 attempts do not reach the API and are not usage events.
- The active subscription query is the request-time entitlement read model;
  rating, usage aggregation, and invoicing remain asynchronous.
- Usage ingestion must be idempotent by `request_id`.
- Plan upgrades increment `subscriptions.version` and append `plan_changes` in
  the same transaction.
- One current subscription per customer/product may be active or suspended;
  cancellation closes it and permits a later subscription with a new credential.
- Current-month draft generation is idempotent by customer and billing period;
  refreshing a draft replaces its line items but never changes an issued invoice.
- Money is stored in integer cents and overage price in integer micro-units to
  avoid floating-point billing errors.

The ConfigMap bootstrap creates an empty demo database at cluster initialization.
The control service also applies idempotent, version-recorded migrations during
startup so an existing installation receives later schema additions safely.

---

[Documentation home](../README.md) · [Architecture](../architecture.md) · [Live demo](../demo-runbook.md)
