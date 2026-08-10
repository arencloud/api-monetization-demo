# ADR 0003: Portable demo edge and observability profile

## Status

Accepted.

## Decision

The baseline uses an HTTP Gateway listener with OpenShift-generated hostnames
beneath the cluster ingress domain. A GitOps hook aligns each Gateway API
`HTTPRoute` with its admitted OpenShift Route host. This makes the repository
deployable to a fresh supported cluster without cloud DNS credentials or
hard-coded cluster domains. A real-domain overlay will add DNS and ACME-backed
TLS policies without changing applications or authentication rules.

The Gateway-generated Service adapts to the cluster. It remains `LoadBalancer`
when MetalLB, a cloud integration, or another provider assigns an external
address. If a live assignment probe times out, a narrowly privileged GitOps hook
adds `networking.istio.io/service-type: ClusterIP` to the Gateway. Two OpenShift
Routes publish the API-key and JWT hostnames in either mode. This avoids assuming
that a bare-metal cluster has a Service LoadBalancer provider while using one
when it is available.

OpenShift application builds require the integrated image registry. The registry
and its persistent storage are cluster infrastructure prerequisites, not part of
the demo lifecycle. Preflight rejects a Removed, unavailable, unconfigured, or
`emptyDir`-backed registry. GitOps does not modify registry configuration.

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

- A fresh cluster needs no LoadBalancer provider, DNS, ACME, S3, or Grafana
  credentials.
- Registry capacity, availability, backup, and lifecycle remain infrastructure
  responsibilities and are unaffected by demo installation or removal.
- The complete authentication, rate limiting, upgrade, metrics, logging, and
  tracing story works before environment-specific integrations are selected.
- TLS, long-lived traces, Loki, and Grafana are explicit production overlays,
  not silently insecure defaults.
