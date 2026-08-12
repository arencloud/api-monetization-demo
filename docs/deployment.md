# Deployment guide

## Prerequisites

- OpenShift Container Platform 4.21 or 4.22.
- A user with `cluster-admin` privileges.
- The `oc` CLI and network access to the cluster.
- `redhat-operators` available in `openshift-marketplace`.
- `certified-operators` available in `openshift-marketplace`.
- `community-operators` available in `openshift-marketplace` for Grafana.
- Red Hat entitlements that expose the `rhcl-operator` package.
- The repository is reachable by the in-cluster Argo CD repository server.
- A default dynamic `StorageClass` is configured for PostgreSQL PVCs.
- The integrated OpenShift image registry is `Managed`, Available, and uses
  persistent infrastructure-backed storage rather than `emptyDir`.
- Cluster nodes can pull from `registry.redhat.io`, `registry.access.redhat.com`,
  `ghcr.io`, `docker.io`, and GitHub's `pkg-containers.githubusercontent.com`
  blob endpoint.

The preflight check is read-only:

```bash
make preflight
```

It fails if the cluster version, permissions, catalog sources, or required
operator packages are incompatible. A missing RHCL package generally means the
cluster pull secret/account does not include the required product entitlement.
It also reports a non-blocking warning when no MetalLB, cloud, or other external
Service LoadBalancer assignment is detected. That result is advisory because the
Gateway performs a live assignment probe during its GitOps sync. Registry
readiness is mandatory because OpenShift builds publish their output there.

## Bootstrap

Review the repository URL and revision in `bootstrap/root/application.yaml` and
`gitops/applications/kustomization.yaml`, then run:

```bash
make bootstrap
```

The script performs only these mutations:

1. Applies the OpenShift GitOps namespace, OperatorGroup, and Subscription.
2. Waits for the subscription to report an installed CSV.
3. Waits for the default Argo CD application controller.
4. Grants `cluster-admin` to the dedicated OpenShift GitOps application
   controller service account.
5. Applies the root `Application`.

The controller binding is required because this repository owns cluster-scoped
Operators and Gateway resources and reconciles resources across multiple
namespaces. It does not grant `cluster-admin` to users who log in to Argo CD.

It does not directly apply any platform resource. Argo CD reconciles the child
applications from Git.

The Inventory API and monetization control application include generated
source-trigger ConfigMaps. Their content hash changes whenever local application
source changes, making the Argo CD application OutOfSync and executing its
OpenShift source-build hook. The resulting ImageStream update rolls the
Deployment. This ensures source-only commits are built even when the static
Deployment and BuildConfig YAML did not change.

The identity application uses the same content-hash pattern for its Keycloak
configuration Job. Argo CD excludes hook manifests from normal drift
comparison, so the generated trigger ConfigMap ensures changes to users, roles,
or OIDC clients initiate a sync and rerun the idempotent identity hook.

## Verify

```bash
make status
oc get kuadrant -n kuadrant-system
oc get istio -n api-monetization-mesh-system
oc get istiocni -n api-monetization-istio-cni
make verify
make demo
make observe
make grafana
make showcase
```

`make showcase` is the self-contained acceptance and presentation workflow. It
runs platform verification, waits for authentic rate-limit windows, exercises
the live plan upgrade and metered invoice, publishes observability evidence,
prints the cluster-specific endpoints, and restores Demo Company to Free.

`make verify` finishes with the lifecycle enforcement test. The test mutates
only the dedicated `monetization-developer-automation` subscription: it creates
and reveals a temporary API key, suspends and resumes the subscription, cancels
it, verifies cleanup, resubscribes once, and returns it to a cancelled state.
It does not alter the `demo-developer` browser account or `demo-company` used by
`make demo`. Run the lifecycle part independently with:

```bash
make lifecycle-test
```

Print the admitted portal URL and generated developer and administrator logins:

```bash
make portal
```

The portal redirects the browser to the externally admitted Keycloak Route and
uses Authorization Code with PKCE. The generated `demo-developer` identity has
the `monetization-developer` role and `demo-admin` has the
`monetization-admin` role. Separate confidential clients are generated for CLI
verification; no credential is stored in Git. A GitOps hook reads the
OpenShift ingress domain and configures the browser client with the exact HTTPS
portal origin and callback rather than a permissive wildcard.

Print the Grafana URL and SSO roles:

```bash
make grafana
```

Grafana uses the same generated Keycloak users: `demo-admin` maps to Grafana
Admin and `demo-developer` maps to Viewer. OAuth auto-login is enabled and all
back-channel requests verify the OpenShift router CA. The command also prints a
generated local administrator and `/login?disableAutoLogin=true` URL for
break-glass access; that credential is not stored in Git.

The expected end state is that every Argo CD application is `Synced` and
`Healthy`, every operator CSV is `Succeeded`, the `Kuadrant` resource is ready,
the `Istio`/`IstioCNI` resources report healthy status, both PostgreSQL clusters
are ready, and the Keycloak realm import reports `Done`.

The integrated registry is infrastructure owned. GitOps does not change its
management state, replicas, storage, or PVC, and complete demo removal leaves it
untouched. `make preflight` blocks bootstrap unless the registry is Managed,
Available, non-Degraded, and backed by persistent storage.

The demo Gateway listener uses HTTP inside the cluster. Edge-terminated
OpenShift Routes provide HTTPS externally and generate the API-key and JWT
hostnames beneath the cluster ingress domain from the Route subdomains
`api-monetization` and `api-monetization-jwt`. A GitOps sync hook copies the
admitted Route hosts into the corresponding Gateway API `HTTPRoute` resources,
and the Inventory API's published OpenAPI document, so edge routing, Gateway
routing, and the APIProduct interactive documentation agree without hard-coded
cluster DNS names.

The Developer Portal controller does not run inside the application Service
Mesh. It fetches the OpenAPI document from the Inventory workload's dedicated
port 8082; mTLS is disabled only for that documentation port while API traffic
on port 8080 remains `STRICT`. An earlier Gateway-application sync-wave hook
waits for a valid OpenAPI response before allowing the APIProduct generation to reconcile.
`make verify` reads `OpenAPISpecReady` directly and reports `FetchFailed`
messages immediately instead of waiting on an empty status field.

The Gateway initially uses the controller's normal `LoadBalancer` Service. A
GitOps sync hook waits for an external IP or hostname from MetalLB, a cloud
integration, or another provider. When an address is assigned, the Service
remains `LoadBalancer`. When none is assigned, the hook adds
`networking.istio.io/service-type: ClusterIP` to the Gateway. OpenShift Routes
expose both APIs in either mode. `make verify` prints the admitted URLs, and
`make demo` discovers them dynamically. Environment overlays can add
`TLSPolicy` and `DNSPolicy` once a real domain and provider credentials are
selected. A healthy ClusterIP selection is preserved on subsequent syncs to
avoid repeated Gateway rollouts; remove the service-type annotation explicitly
when a newly installed LoadBalancer provider must be probed.

This Route/ClusterIP behavior is the supported portable demo profile. A
production deployment can add provider-specific Kustomize overlays for external
DNS and certificates, object-backed telemetry, PostgreSQL HA/backups, and
disaster recovery. Those choices require environment-specific storage, DNS,
certificate, and recovery objectives, so the baseline does not install dummy
or insecure production resources.

After the relevant Operators create their `ConsolePlugin` resources, GitOps
enables the OpenShift GitOps and Connectivity Link plugins while preserving the
default networking and monitoring plugins. The OpenShift console then exposes
the GitOps and Connectivity Link navigation entries without a manual patch.

## Upgrade policy

Subscriptions use minor-version channels where the Red Hat catalog provides
them. Automatic approval accepts compatible patch releases in that lane. Major
or minor lane changes require a pull request that updates the support matrix,
subscriptions, operands, and validation evidence together.

The RHCL catalog currently exposes a single `stable` channel. Before every demo
release, record its resolved CSV and dependent operator versions in the release
notes. Do not approve an RHCL minor upgrade until the complete Red Hat supported
configuration matrix has been reviewed.

## Secrets

Plain Kubernetes `Secret` resources are rejected by repository validation. The
demo profile uses one-time immutable password generators managed by External
Secrets. A production overlay must replace those generators with provider-backed
External Secrets while retaining the same target Secret contracts. Bootstrap
credentials must never be committed, even for a demonstration.

The generated Secrets use orphan ownership and remain if their `ExternalSecret`
is pruned. This is intentional: database bootstrap credentials must not rotate
without changing the persisted database role password. During a complete demo
reset, delete the PostgreSQL cluster/PVC and its corresponding generated Secret
together, after confirming that no retained data is required.

## Recovery

Argo CD self-heals managed resources. For diagnosis, inspect the child
application first, then the owning operator and operand conditions:

```bash
oc get applications.argoproj.io -n openshift-gitops
oc get subscriptions,csv,installplans -A
oc describe application <name> -n openshift-gitops
```

Do not delete CRDs to recover an operator. CRD deletion can remove all operand
data. Any teardown workflow will be added separately with explicit ordering and
backup requirements.

## Complete removal

The complete demo, including its databases and generated credentials, can be
removed only with an explicit confirmation value:

```bash
CONFIRM_UNINSTALL=api-monetization make uninstall
```

The workflow stops Argo CD reconciliation, removes operands before their
Operators, removes cert-manager's separately managed operand, deletes the demo
namespaces, and uninstalls OpenShift GitOps last. The infrastructure registry and
its data are preserved. OLM-installed CRDs are retained
to avoid destructive cluster-wide data removal and to support clean
reinstallation.

## Product references

- [RHCL supported configurations](https://access.redhat.com/articles/7092611)
- [Installing Red Hat Connectivity Link 1.4](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/installing_connectivity_link/)
- [RHCL observability](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html/observability/)
- [Installing OpenShift Service Mesh 3.4](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/installing/)
- [Installing OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.21/html/installing_gitops/)
- [Configuring the OpenShift image registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/registry/setting-up-and-configuring-the-registry)
- [OpenShift Service Mesh gateways](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/gateways/)
- [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift)
- [CloudNativePG installation and upgrades](https://cloudnative-pg.io/docs/1.30/installation_upgrade/)
- [Red Hat build of Keycloak Operator guide](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html/operator_guide/)
- [Red Hat build of OpenTelemetry](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/3.10/html/installing_red_hat_build_of_opentelemetry/)
- [Red Hat OpenShift distributed tracing](https://docs.redhat.com/en/documentation/red_hat_openshift_distributed_tracing_platform/3.9/html/installing_distributed_tracing/)
