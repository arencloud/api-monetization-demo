# ADR 0008: Red Hat Developer Hub as the unified developer experience

## Status

Accepted incrementally.

## Decision

Install Red Hat Developer Hub 1.10 with its Red Hat Operator and automatic
z-stream updates from `fast-1.10`. Enable the Kuadrant 0.2.1 frontend and backend
dynamic plugins with npm integrity verification. Use the existing Red Hat build
of Keycloak realm for OIDC, organization synchronization, self-registration,
and group-to-role mapping. Use a dedicated single-instance CloudNativePG
database and service account for the demo profile.

Disable RHDH's default Lightspeed flavour. The project already exposes its own
OpenShift AI model through RHCL token policies, metering, and billing; a second
unconfigured AI sidecar would consume resources without contributing to the
monetization story.

The Kuadrant plugin is responsible for RHCL API-product synchronization,
product discovery, access requests, approvals, API-key management, and
PlanPolicy visibility. It does not become a billing system. Subscription state,
accepted usage, pricing, invoices, revenue, and AI token accounting remain in
the existing PostgreSQL-backed monetization service and will be exposed through
a custom RHDH frontend/backend plugin.

The existing portal remains deployed until the custom plugin reaches feature
parity. This gives the migration an explicit rollback and avoids duplicating
commercial authority across two backends.

## Consequences

- A new developer can register in Keycloak and is synchronized into RHDH as an
  API consumer.
- API owners and administrators receive explicit Keycloak group membership and
  Kuadrant RBAC permissions; there is no guest or resolver-bypass login.
- APIProduct resources must declare `backstage.io/owner` or the Kuadrant catalog
  provider intentionally skips them.
- RHDH and Kuadrant plugin compatibility must be tested as a pair. Kuadrant
  0.2.1 documents RHDH 1.8.4 as its tested baseline, so RHDH 1.10 is accepted
  only after the repository verification succeeds on the target cluster.
- The next milestone is a custom dynamic plugin that consumes the existing
  control-plane API; request-time enforcement remains entirely in RHCL.
