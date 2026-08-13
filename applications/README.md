# Application workloads

The demo owns three small Go services:

- `inventory`: an intentionally authentication-free backend. Connectivity Link
  owns all external authentication and rate limiting.
- `payments`: a second independent backend proving that catalog publication,
  credentials, limits, usage, and billing are scoped per API product.
- `control`: the commercial control plane. It records plan changes in
  PostgreSQL and updates the RHCL-managed API-key enforcement metadata.

Both images are built on the cluster by OpenShift `BuildConfig` resources and
published to the integrated image registry. Argo CD owns the build definitions,
image streams, deployments, services, and monitoring resources.
