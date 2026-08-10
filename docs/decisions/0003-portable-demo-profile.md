# ADR 0003: Portable demo edge and observability profile

## Status

Accepted.

## Decision

The baseline uses an HTTP Gateway listener with synthetic hostnames and explicit
Host headers. This makes the repository deployable to a fresh supported cluster
without cloud DNS credentials. A real-domain overlay will add DNS and ACME-backed
TLS policies without changing applications or authentication rules.

The baseline uses OpenShift user-workload monitoring, structured container logs,
and a Red Hat Operator-managed, in-memory `TempoMonolithic` instance. In-memory
trace storage is deliberately limited to demonstrations and proof of concept.
Production overlays must use supported persistent/object storage.

A vendor-neutral Grafana dashboard is stored as code but Grafana is not installed
by the baseline. When an organization selects Grafana, it must be installed by an
Operator and the dashboard ConfigMap can be reconciled into that instance. Loki
is also excluded from the portable baseline because Red Hat LokiStack requires an
environment-specific object store; structured logs remain available through
OpenShift during the demo.

## Consequences

- A fresh cluster needs no DNS, ACME, S3, or Grafana credentials.
- The complete authentication, rate limiting, upgrade, metrics, logging, and
  tracing story works before environment-specific integrations are selected.
- TLS, long-lived traces, Loki, and Grafana are explicit production overlays,
  not silently insecure defaults.
