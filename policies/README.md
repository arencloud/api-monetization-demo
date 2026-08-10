# Policies

This area will contain Gateway API and Connectivity Link policy packages.
Planned layers are:

1. a platform-owned Gateway with TLS and deny-by-default authentication;
2. route-owned authentication and authorization overrides;
3. customer/plan-aware rate and quota rules;
4. premium routing and timeout behavior; and
5. policy status checks used by the live demo.

Credential material and environment hostnames belong in environment overlays,
not policy bases.

