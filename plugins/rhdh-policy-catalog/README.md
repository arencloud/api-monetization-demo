# RHDH effective-policy catalog

This frontend dynamic plugin owns the Kuadrant API-product list, billing, and
Developer Hub API explorer routes. It keeps the upstream Kuadrant backend,
detail, approval, and API-key pages, resolves effective traffic policies, and
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
