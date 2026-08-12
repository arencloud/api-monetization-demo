# ADR 0005: Keycloak SSO for Grafana

- Status: Accepted
- Date: 2026-08-12

## Context

The business dashboard initially required a separate generated Grafana
administrator credential. The portal already has operator-managed Keycloak
identities and role boundaries, so a second everyday login weakens the demo
experience and does not demonstrate centralized access control.

## Decision

Configure Grafana generic OAuth against a confidential Keycloak client using
Authorization Code flow with PKCE. Map `monetization-admin` strictly to Grafana
Admin and `monetization-developer` to Viewer. Deny users without either role and
keep local basic authentication only for break-glass recovery.

Generate the client secret with External Secrets in the identity namespace.
Mirror it into observability through a namespace-scoped Kubernetes
`SecretStore` whose service account can read only that Secret. GitOps hooks
derive exact callback and origin values from the cluster ingress domain and
admitted Keycloak Route. Grafana trusts the OpenShift router CA for OAuth
back-channel calls; TLS verification is never skipped.

## Consequences

- Portal and Grafana use the same generated demo identities and Keycloak
  session.
- Administrators can manage Grafana while developers can inspect dashboards
  without editing them.
- `make verify` checks secret replication, the Keycloak client and role mapper,
  the OAuth redirect, dashboard reconciliation, and datasource health.
- `make grafana` prints SSO logins and an explicit break-glass URL.
- The shared demo datasource exposes shared demo telemetry. Per-customer
  production isolation would require datasource tenancy and authorization in a
  production overlay.
