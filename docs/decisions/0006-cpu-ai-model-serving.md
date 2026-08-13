# ADR 0006: CPU-only model serving with OpenShift AI

## Status

Accepted for the AI Chat development milestone.

## Decision

Install Red Hat OpenShift AI 3.4 from the `stable-3.x` Operator channel and
enable only its dashboard and KServe components. Model workloads use KServe
RawDeployment mode and a single CPU replica. The demo does not install a GPU
Operator or require accelerator resources.

The first model is a small, INT4 OpenVINO instruction model served by the
OpenVINO Model Server runtime. Its public API is not exposed directly. The AI
Chat product will place the existing Connectivity Link gateway in front of the
model and will use the same API-key/JWT entitlement, rate-limit, usage, billing,
and tracing path as the Inventory and Payment products.

## Rationale

OpenShift AI 3.4 supports OpenShift 4.22 and includes KServe 0.17 and OpenVINO
Model Server 2026.1. OpenVINO supports text generation on x86 CPU and provides
an OpenAI-compatible chat API. This gives the demo real model inference while
remaining deployable on a five-node cluster without GPUs.

RawDeployment mode keeps OpenShift AI model serving independent from the
project's existing OpenShift Service Mesh instance. Enabling OpenShift AI MaaS
would also introduce its own RHCL governance layer, which would duplicate the
monetization control plane demonstrated by this repository, so MaaS remains
disabled.

## Consequences

- CPU inference has intentionally modest throughput and is suitable for a live
  demo, not performance benchmarking.
- One replica and RWO storage are sufficient; RWX storage is not required.
- Only dashboard and KServe are managed, keeping the cluster footprint bounded.
- The model version, serving image digest, requests, limits, and readiness
  probes must be pinned in Git before the feature is promoted to `main`.
- GPU-backed runtimes can be added later as an environment overlay without
  changing the product or monetization contracts.
