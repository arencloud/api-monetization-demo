# ADR 0006: CPU-only model serving with OpenShift AI

## Status

Accepted for the AI Chat development milestone.

## Decision

Install Red Hat OpenShift AI 3.4 from the `stable-3.x` Operator channel and
enable only its dashboard and KServe components. Model workloads use KServe
Standard deployment mode (formerly RawDeployment) and a single CPU replica.
The demo does not install a GPU Operator or require accelerator resources.

The first model is the public Qwen2.5 0.5B Instruct model at a pinned repository
revision, served by the Operator-provided vLLM CPU (x86) runtime. Its public API
is not exposed directly. A mesh-injected AI Chat facade places the existing
Connectivity Link gateway in front of the model and uses the same API-key/JWT
entitlement, request-rate, usage, billing, and tracing path as the Inventory and
Payment products. The facade disables streaming for this milestone and bills
the prompt plus completion token total reported by vLLM.

## Rationale

OpenShift AI 3.4 supports OpenShift 4.22 and includes KServe 0.17 and a Red Hat
vLLM 0.18 CPU runtime template for x86. vLLM provides an OpenAI-compatible chat
API. This gives the demo real model inference while remaining deployable on a
five-node cluster without GPUs.

Standard deployment mode keeps OpenShift AI model serving independent from the
project's existing OpenShift Service Mesh instance. Enabling OpenShift AI MaaS
would also introduce its own RHCL governance layer, which would duplicate the
monetization control plane demonstrated by this repository, so MaaS remains
disabled.

## Consequences

- CPU inference has intentionally modest throughput and is suitable for a live
  demo, not performance benchmarking.
- Connectivity Link enforces request-frequency limits before inference;
  post-response token totals drive commercial allowance and overage. These are
  deliberately distinct controls.
- The vLLM CPU (x86) runtime is marked Technology Preview by OpenShift AI 3.4;
  it is acceptable for this demo profile but is not a production support claim.
- One replica and an ephemeral model cache are sufficient; RWX storage is not
  required. The pinned public model is downloaded again if the Pod is replaced.
- Only dashboard and KServe are managed, keeping the cluster footprint bounded.
- The model version, serving image digest, requests, limits, and readiness
  probes must be pinned in Git before the feature is promoted to `main`.
- GPU-backed runtimes can be added later as an environment overlay without
  changing the product or monetization contracts.
