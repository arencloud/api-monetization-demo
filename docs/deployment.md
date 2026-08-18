# Deployment guide

## Prerequisites

### Cluster sizing

Size this repository as an OpenShift AI cluster, not as only two small API
Deployments. The CPU model, four in-cluster source builds, RHCL, Service Mesh,
Keycloak, Red Hat Developer Hub, three PostgreSQL clusters, Grafana, Tempo, and their Operators all run
at the same time.

Red Hat OpenShift AI 3.4 requires a minimum of two worker nodes with 8 CPUs and
32 GiB of RAM each. That requirement is higher than the generic OpenShift
compute-node minimum and is therefore the governing product baseline for this
demo. The following profiles are planning targets for a fresh cluster:

| Profile | Control plane | Schedulable workers | Aggregate worker capacity | Demo headroom before bootstrap | Provisionable persistent capacity | Intended use |
| --- | --- | --- | --- | --- | --- | --- |
| Minimum | 3 × 4 vCPU, 16 GiB RAM, 100 GiB disk | 2 × 8 vCPU, 32 GiB RAM, 100 GiB disk | 16 vCPU, 64 GiB RAM | 10 vCPU and 36 GiB RAM after existing pod requests | 65 GiB | Functional installation and single-user validation; builds and first model start can be slow |
| Recommended | 3 × 4 vCPU, 16 GiB RAM, 100 GiB disk | 3 × 8 vCPU, 32 GiB RAM, 150 GiB disk | 24 vCPU, 96 GiB RAM | 16 vCPU and 48 GiB RAM after existing pod requests | 100 GiB | Reliable installation, rehearsal, and live presentation |
| Large showcase | 3 × 8 vCPU, 32 GiB RAM, 150 GiB disk | 3 × 16 vCPU, 64 GiB RAM, 200 GiB disk | 48 vCPU, 192 GiB RAM | 28 vCPU and 96 GiB RAM after existing pod requests | 200 GiB | Parallel builds, repeated tests, and additional observability or development workloads |

The Large showcase row is not an OpenShift maximum. OpenShift can scale beyond
it; it is the upper planning profile for this single-cluster demo. The
headroom column means scheduler-visible allocatable capacity minus existing pod
requests, not currently unused CPU and memory reported by metrics. The values
include practical margin above the resources declared in this repository for
operator-generated operands, Service Mesh sidecars, image builds, and rollout
overlap. Existing workloads on a shared cluster must fit outside that margin.

A single-node OpenShift lab is also possible, but Red Hat OpenShift AI requires
at least 32 CPUs and 128 GiB of RAM for that topology. Use at least 200 GiB of
node disk for this demo and treat the result as a non-HA lab. The multi-node
Recommended profile is preferred for presentations.

These baselines come from the Red Hat product documentation:

- [OpenShift AI 3.4 installation requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/installing_and_uninstalling_openshift_ai_self-managed/installing_and_uninstalling_openshift_ai_self-managed)
  specify the two-worker and single-node minimums, a default dynamic storage
  class, and the restriction against installing Open Data Hub on the cluster.
- [OpenShift 4.22 bare-metal machine requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_bare_metal/user-provisioned-infrastructure)
  specify the 4-vCPU, 16-GiB, 100-GB control-plane minimum used in the table.
- [OpenShift node resource guidance](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/nodes/working-with-nodes)
  explains that scheduling is based on allocatable resources after system
  reservations rather than the node's full physical capacity.

Check capacity before bootstrap:

```bash
oc get nodes \
  -o 'custom-columns=NAME:.metadata.name,WORKER:.metadata.labels.node-role\.kubernetes\.io/worker,ARCH:.status.nodeInfo.architecture,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,EPHEMERAL:.status.allocatable.ephemeral-storage'
oc describe nodes | sed -n '/Allocated resources:/,/Events:/p'
oc adm top nodes
```

Use the first two commands to assess scheduler capacity and committed requests.
Use `oc adm top nodes` only as a secondary utilization check; low instantaneous
usage does not mean that enough capacity remains schedulable. At least one
schedulable worker must be `amd64` because the selected Red Hat vLLM runtime is
the CPU x86 variant.

### Storage sizing

RWX storage is not required. A default dynamic RWO-capable `StorageClass` is
sufficient for the repository-managed stateful workloads. Plan storage as
follows:

| Consumer | Baseline | Notes |
| --- | --- | --- |
| Integrated OpenShift registry | 50 GiB persistent volume, one replica | Required before bootstrap; infrastructure-owned and intentionally not managed by this repository |
| Subscription PostgreSQL | 2 GiB RWO PVC | Demo data, subscriptions, usage, invoices, and audit history |
| Keycloak PostgreSQL | 2 GiB RWO PVC | Identity and realm state |
| Developer Hub PostgreSQL | 5 GiB RWO PVC | RHDH catalog, authentication, and plugin schemas; PostgreSQL 17 is digest-pinned because RHDH 1.10 supports PostgreSQL 14–17 while newer CloudNativePG releases default to 18 |
| AI model and container layers | Node-local ephemeral storage | Approximately 1 GiB pinned model plus the Red Hat serving image and build layers; retain at least 30 GiB free per candidate worker |
| Tempo | Memory-backed 1 GiB volume | Demo-only trace retention; no persistent volume |

The absolute persistent-volume request is 59 GiB. The 65-GiB Minimum profile
allows only a small provisioning margin; 100 GiB or more is recommended. The
StorageClass and its backing storage must also have enough unallocated capacity
to satisfy those claims.

Verify storage and the integrated registry before bootstrap:

```bash
oc get storageclass
oc get configs.imageregistry.operator.openshift.io/cluster \
  -o jsonpath='{.spec.managementState}{" storage="}{.spec.storage}{" replicas="}{.spec.replicas}{"\n"}'
oc get pvc -n openshift-image-registry
```

The expected registry result is `Managed`, one replica, and a Bound 50-GiB PVC.
The preflight check rejects `emptyDir`, an unavailable registry, and an unbound
configured registry PVC. It reports the detected capacity but does not enforce
or resize an existing claim, so confirm the 50-GiB value explicitly.

### Platform and workstation requirements

- OpenShift Container Platform 4.21 or 4.22.
- A user with `cluster-admin` privileges.
- The `oc`, `git`, `make`, `curl`, `jq`, and `python3` CLIs, the Python `PyYAML` package,
  and network access to the cluster.
- `redhat-operators` available in `openshift-marketplace`.
- `certified-operators` available in `openshift-marketplace`.
- `community-operators` available in `openshift-marketplace` for Grafana.
- Red Hat entitlements that expose the `rhcl-operator` package.
- Red Hat entitlements that expose the `rhdh` package and permit RHDH image pulls.
- The repository is reachable by the in-cluster Argo CD repository server.
- A default dynamic `StorageClass` is configured for PostgreSQL PVCs.
- Open Data Hub is not installed; it conflicts with the Red Hat OpenShift AI
  installation supported by this profile.
- The integrated OpenShift image registry is `Managed`, Available, and uses
  a one-replica 50-GiB persistent infrastructure-backed volume rather than
  `emptyDir`.
- Cluster nodes can pull from `registry.redhat.io`, `registry.access.redhat.com`,
  `ghcr.io`, `docker.io`, `registry.npmjs.org`, and GitHub's
  `pkg-containers.githubusercontent.com` blob endpoint. RHDH downloads the
  integrity-pinned Kuadrant dynamic plugins from npm during Pod initialization.
- For the CPU AI milestone, cluster workloads can reach `huggingface.co` and
  its model-content CDN endpoints.

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
Capacity and outbound model-download bandwidth remain manual planning gates:
taints, reservations, storage backends, and shared-cluster workloads make a
single automated total misleading. Use the sizing commands above and the
runbook checklist in addition to `make preflight`.

## Bootstrap

Review the repository URL and revision in `bootstrap/root/application.yaml` and
`gitops/applications/kustomization.yaml`, then run:

```bash
make bootstrap
```

The script performs only these mutations:

1. Applies the OpenShift GitOps namespace, OperatorGroup, and Subscription.
2. Removes any legacy `startingCSV` pin and waits for the current
   `latest` catalog head CSV to reach `Succeeded`.
3. Waits for superseded GitOps CSVs to be removed and for the default Argo CD
   custom resource and server to become available.
4. Grants `cluster-admin` to the dedicated OpenShift GitOps application
   controller service account.
5. Applies the root `Application`.

The controller binding is required because this repository owns cluster-scoped
Operators and Gateway resources and reconciles resources across multiple
namespaces. It does not grant `cluster-admin` to users who log in to Argo CD.

It does not directly apply any platform resource. Argo CD reconciles the child
applications from Git.

The GitOps Subscription uses automatic InstallPlans and intentionally omits
`startingCSV`. A fresh cluster therefore installs the newest CSV currently
published in the catalog's `latest` channel instead of first installing an
older CSV and immediately entering an avoidable replacement. Future updates in
that channel are installed automatically. `Replacing` can appear briefly during
a normal upgrade; bootstrap completes only after the catalog head is
`Succeeded`, and reports OLM resolution or InstallPlan failures directly.

The Inventory API, Payment API, and monetization control application include generated
source-trigger ConfigMaps. Their content hash changes whenever local application
source changes, making the Argo CD application OutOfSync and executing its
OpenShift source-build hook. Argo CD injects the exact reconciled 40-character
commit into the hook. The hook builds that commit, fails the Argo sync if the
OpenShift Build fails or resolves a different revision, and snapshots the output
as an immutable `git-<12-character-commit>` ImageStreamTag. The `demo` delivery
tag then rolls the Deployment to that digest.

This supplies a verifiable provenance chain instead of merely proving that some
image exists:

```text
Argo CD sync revision -> OpenShift Build commit -> immutable ImageStreamTag
                      -> Deployment digest -> running Pod image ID
```

Run `make promotion-status` to inspect that chain. `make verify` treats any
missing build, revision mismatch, mutable-only image, digest mismatch, or
non-ready Pod as a failure. A failed source-build hook is retained by Argo CD,
and the corresponding Application remains visibly failed until the next
successful reconciliation.

The identity application uses the same content-hash pattern for its Keycloak
configuration Job. Argo CD excludes hook manifests from normal drift
comparison, so the generated trigger ConfigMap ensures changes to users, roles,
or OIDC clients initiate a sync and rerun the idempotent identity hook.

## Verify

```bash
make status
make promotion-status
oc get kuadrant -n kuadrant-system
oc get istio -n api-monetization-mesh-system
oc get istiocni -n api-monetization-istio-cni
make verify
make multi-product-test
make ai-model-test
make ai-monetization-test
make ai-demo
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

Validate simultaneous Inventory and Payment subscriptions, product-scoped
credentials, both JWT paths, and independent usage attribution with:

```bash
make multi-product-test
```

Prove the OpenShift AI model independently before placing Connectivity Link in
front of it:

```bash
make ai-model-test
```

The first start can take several minutes while a node pulls the Red Hat vLLM
CPU image and the Pod downloads the approximately 1 GB pinned model snapshot.
Later starts can reuse node image layers, but the demo intentionally uses an
ephemeral model cache and one replica. This profile requires neither a GPU nor
RWX storage. The runtime is Technology Preview in OpenShift AI 3.4 and is meant
for demonstration rather than performance or production support claims.

The model namespace is enrolled in the project Service Mesh revision. KServe
injects an Istio proxy and rewrites health probes, while a mesh-aware ClusterIP
Service, strict peer authentication, and an explicit `ISTIO_MUTUAL` destination
rule secure calls from the AI facade to vLLM. The OpenShift edge Routes use the
supported HAProxy timeout annotation with a 180-second budget so CPU inference
can complete without weakening TLS or bypassing the gateway.

After the model and monetization applications are healthy, validate the public
product contract and token billing:

```bash
make ai-monetization-test
```

Run the complete repeatable AI business scenario—including the Free token
quota, HTTP 429, live Developer upgrade, both credential paths, stored usage,
and cleanup—with:

```bash
make ai-demo
```

This command discovers the current cluster's admitted hosts, router targets,
and ingress certificate. It creates and later cancels a dedicated automation
subscription, so it does not depend on a fixed hostname or modify a human
developer's portal state.

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
its `mtlsAuthorino` and `mtlsLimitador` status fields are both `true`,
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
and both product APIs' published OpenAPI documents, so edge routing, Gateway
routing, and APIProduct interactive documentation agree without hard-coded
cluster DNS names.

The Developer Portal controller does not run inside the application Service
Mesh. It fetches each OpenAPI document from the corresponding workload's
dedicated port 8082; mTLS is disabled only for each documentation port while
API traffic on port 8080 remains `STRICT`. An earlier Gateway-application
sync-wave hook waits for both valid OpenAPI responses before allowing the
APIProduct generations to reconcile.
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
