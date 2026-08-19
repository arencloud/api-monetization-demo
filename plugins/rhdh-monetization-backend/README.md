# API monetization RHDH backend

This dynamic backend plugin adds the API Monetization-specific surface that is
not provided by the upstream Kuadrant plugin:

- permission-controlled `TokenRateLimitPolicy` discovery;
- developer-scoped usage and billing from the monetization control plane; and
- administrator-scoped commercial overview data; and
- consumer-scoped API-owner requests plus administrator-only review actions.

The plugin never accepts a customer identifier for developer reads. The
existing Keycloak token is forwarded to the control plane, which resolves the
subject to its PostgreSQL customer identity and applies its own role checks.
The plugin does not mutate Keycloak. Approved membership changes are performed
by the control plane with a dedicated least-privilege service identity.
