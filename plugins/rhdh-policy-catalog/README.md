# RHDH effective-policy catalog

This frontend dynamic plugin owns the Kuadrant API-product list, billing, and
Developer Hub API explorer routes. It keeps the upstream Kuadrant backend and
read-only product detail integration, resolves effective traffic policies, and
locks production catalog entries until the signed-in developer subscribes to
their commercial product. One subscription unlocks both API-key and Keycloak
JWT variants of that product.

JWT products intentionally use direct `RateLimitPolicy` resources because the
demo requires explicit subscription/customer counters. Creating a decorative
`PlanPolicy` would change enforcement semantics and is therefore not used.

Build and test the checked-in deployment artifact with the repository's
digest-pinned Node toolchain:

```sh
make rhdh-plugin-test
```

The command uses Podman or Docker and builds at the same `/workspace` path in
development and CI, keeping webpack content hashes reproducible across hosts.

The packaging step drops standard webpack output and source maps; RHDH's
frontend dynamic loader only consumes `package.json` and `dist-scalprum`. This
keeps the TGZ below the Kubernetes ConfigMap object limit.

The GitOps configuration mounts the resulting TGZ locally into RHDH. For a
production installation, publish the same exported dynamic plugin as a
digest-pinned OCI artifact in a private registry.

The **Subscriptions & Access** route also contains the reviewed API-owner
onboarding workflow. Consumers submit their own request; administrators can
approve or reject it. The browser never receives a Keycloak management token,
and the extension does not become a second identity authority.

Before subscribing, consumers can inspect the selected plan and expand a full
comparison of monthly price, included native units, request/token rate limit,
monthly safety cap, and overage or PAYG price. Usage remains dimensionally
correct: request-based API calls and AI tokens are displayed separately and
only their currency estimates are aggregated. The control API publishes
`billableUnits` with `unitName`; the legacy `requests` usage field remains a
compatibility alias for existing demo automation.
