# ADR 0004: Operator-managed Grafana baseline

- Status: Accepted
- Date: 2026-08-12

## Context

The Git-managed dashboard ConfigMap was not consumed by the OpenShift metrics
console or any running Grafana instance. A reproducible demo must render the
business dashboard without requiring a manual JSON import or an externally
prepared service.

## Decision

Install Grafana Operator 5 through OLM from the `community-operators` catalog.
The Operator owns one Grafana instance, one OpenShift Thanos datasource, and the
dashboard import. OpenShift GitOps owns their desired custom resources.

Grafana uses an admitted edge-terminated OpenShift Route and a generated
administrator password stored in a Kubernetes Secret. A dedicated Grafana
service-account token authenticates the datasource to the TLS-protected Thanos
Querier and a `cluster-monitoring-view` binding authorizes cluster metrics. The
service-signing CA is injected into a ConfigMap and supplied to the datasource,
so TLS verification remains enabled.

The instance uses one replica and ephemeral storage. No user-authored dashboard
or datasource state is authoritative in Grafana: all required content is
reconciled from `GrafanaDashboard` and `GrafanaDatasource` resources. Production
profiles may add persistent storage, SSO, network policies, and high availability.

## Consequences

- `make bootstrap` produces a working Grafana UI and dashboard without manual
  import.
- `make grafana` reveals the generated demo administrator login on demand.
- The portable profile gains a dependency on `community-operators` and
  `docker.io` image access.
- The demo needs no additional PVC or RWX storage for Grafana.
- The Grafana Operator is community-supported rather than a Red Hat product
  Operator; Red Hat product components remain installed through their Red Hat
  Operators.
