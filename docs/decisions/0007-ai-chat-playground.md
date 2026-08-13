# ADR 0007: Browser AI Chat playground and repeatable token-quota demo

## Status

Accepted for the AI Chat business-demonstration milestone.

## Context

The infrastructure already exposes an OpenAI-compatible AI Chat API through
Connectivity Link, serves a small CPU model through OpenShift AI/KServe, and
records the model-reported token count. A complete business demo also needs a
visible developer experience: choose a credential, chat, observe token usage,
reach a real plan quota, upgrade, and continue. The same proof must be safe to
rerun and portable to a freshly installed OpenShift cluster.

## Decision

- Embed the playground in the existing Keycloak-protected developer portal.
- Call only cluster-admitted Gateway API hostnames discovered from portal
  configuration. Keep KServe cluster-internal behind Service Mesh strict mTLS.
- Permit anonymous access only to method-specific `OPTIONS` routes. Continue to
  require API-key or JWT authentication and an active subscription for `POST`.
- Use wildcard, non-credentialed CORS because authorization is carried in an
  explicit header and API routes never consume browser cookies.
- Display the OpenAI response token fields and verify
  `X-Monetization-Billable-Units` matches `usage.total_tokens`.
- Key AI token counters by immutable subscription UUID. Cancellation followed
  by resubscription creates a clean counter without destructive Limitador
  administration, while a live plan change preserves the UUID and counter.
- Provide `make ai-demo` with a dedicated automation identity. It proves both
  API-key and already-issued JWT paths, live Free-to-Developer continuation,
  PostgreSQL attribution, and cleanup on success or interruption.

## Consequences

The browser demonstrates the same public enforcement path as an external API
consumer and does not expose the model service. A large accepted request can
move the asynchronous token counter beyond the allowance; RHCL rejects the
following request with HTTP 429. This matches TokenRateLimitPolicy's
post-response cost accounting and is described explicitly in the UI and
runbook. A new subscription is required for a deterministic fresh quota, which
also preserves historical usage and audit data rather than deleting it.
