# API Monetization on Red Hat OpenShift

This repository contains the declarative foundation for a reproducible API
monetization demonstration built around Red Hat Connectivity Link (RHCL).
RHCL is the policy enforcement point; subscription management, usage
aggregation, and billing remain independent services.

## Target experience

A developer subscribes to an API plan, receives credentials, and calls an API
through a Gateway API gateway. The request is authenticated, authorized,
rate-limited, observed, and attributed to a subscription. During the demo an
administrator upgrades the subscription and the new limits take effect without
restarting the gateway or application.

```text
Internet -> OpenShift Route -> Gateway API -> Connectivity Link -> Service Mesh -> APIs
                                 |              |                 |
                              TLS/DNS      Auth and limits   mTLS and traces
                                 +--------------+-----------------+
                                   |
                    Metrics, logs, traces, usage, billing
```

OpenShift Routes always provide the portable entry path shown above. When
MetalLB, a cloud integration, or another Service LoadBalancer provider assigns
an external address, the Gateway also retains that direct LoadBalancer entry.

See [the architecture](docs/architecture.md) for component responsibilities and
trust boundaries.

## Deployment principles

- OpenShift GitOps is the only steady-state deployment mechanism.
- Red Hat products and other operator-capable platform services are installed
  with OLM Operators.
- Operator subscriptions and their operands are separate GitOps applications so
  CRDs can become available before custom resources are reconciled.
- No credentials are committed. Secrets must be supplied by an approved secret
  manager or created as a documented bootstrap prerequisite.
- Compatibility channels are deliberately selected as a tested set; upgrades
  are reviewed as a set rather than component by component.
- Every layer is idempotent and can be rendered locally before it reaches a
  cluster.

## Repository layout

| Path | Purpose |
| --- | --- |
| `bootstrap/` | One-time installation of OpenShift GitOps and the root application |
| `gitops/applications/` | App-of-apps definitions and reconciliation ordering |
| `operators/` | OLM subscriptions and operator groups |
| `platform/` | Operator-managed platform operands and shared namespaces |
| `applications/` | Inventory API and monetization control-plane source/builds |
| `policies/` | Gateway, authentication, authorization, and limit policies |
| `dashboards/` | Business and platform observability assets |
| `environments/` | Environment-specific composition and configuration |
| `scripts/` | Bootstrap, preflight, and validation automation |
| `docs/` | Architecture, operations, decisions, and demo runbooks |

## Supported initial profile

The first profile follows the RHCL 1.4 support matrix:

| Component | Selected compatibility lane |
| --- | --- |
| OpenShift Container Platform | 4.21–4.22 |
| Red Hat Connectivity Link | 1.4 stable channel, 1.4.1 or later |
| Red Hat OpenShift Service Mesh | 3.4 |
| cert-manager Operator for Red Hat OpenShift | 1.19 |
| Red Hat build of Keycloak | 26.6 |
| Red Hat OpenShift GitOps | 1.21 |
| External Secrets Operator for Red Hat OpenShift | 1.2 |
| CloudNativePG certified Operator | 1.30 |
| Red Hat build of OpenTelemetry Operator | stable, 0.152.0-2 starting CSV |
| Tempo Operator | stable, 0.21.0-3 starting CSV |
| Application build toolchain | Red Hat UBI 9 Go Toolset 1.26.5 |

The cluster must have subscriptions/entitlements for the Red Hat products. Run
`make preflight` before making any cluster changes.

## Quick start

Prerequisites: `oc`, cluster-admin access, access to the Red Hat operator
catalog, and a cluster matching the profile above.

```bash
make validate
make test
make preflight
make bootstrap
```

`make bootstrap` is the only imperative installation step. It installs the
OpenShift GitOps Operator, waits for the default Argo CD instance, grants its
dedicated application controller the cluster access required to reconcile this
cluster-configuration repository, and applies the root application. Argo CD
owns everything below that root.

The root application currently points to this repository's canonical GitHub
URL and the `main` branch. Before bootstrapping a fork or another branch, change
the source in `bootstrap/root/application.yaml` and the two source literals in
`gitops/applications/kustomization.yaml`.

Detailed prerequisites, verification, and recovery steps are in
[the deployment guide](docs/deployment.md).

## Implemented solution

The repository now contains the complete single-cluster demo path: operator and
GitOps bootstrap, integrated-registry readiness validation, OpenShift Routes,
Service Mesh, Connectivity Link, the RHCL developer catalog,
External Secrets-generated API keys, Keycloak JWT clients, Free/Developer/Business/
Enterprise plan policies, an Inventory API, a PostgreSQL-backed subscription
control plane, live plan changes, Prometheus metrics, a Grafana dashboard,
structured logs, and an OpenTelemetry-to-Tempo trace pipeline.

After deployment and verification, run the deterministic scenario:

```bash
make demo
make reset-demo
```

See [the live demo runbook](docs/demo-runbook.md) before presenting it.
