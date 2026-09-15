# ADR-0005: No waypoint proxy, so AuthorizationPolicies stay L4

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/istio-system/policy/`

## Context

Ambient mode splits the dataplane in two. `ztunnel` handles L4 — mTLS,
identity, and connection-level authorization — on every node. Anything that
needs to read HTTP (paths, methods, JWT claims, headers) requires a **waypoint
proxy**: an opt-in Envoy deployment per namespace or service account.

No waypoint is deployed in any environment.

## Decision

`AuthorizationPolicy` resources in this repository stay L4-oriented: they match
on source principal, namespace, and port, not on HTTP path, method, or JWT
claim.

The ingress service account used as a source principal is:

```
cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio
```

Application-level authorization happens **outside the mesh**:

- **Cloudflare Zero Trust Access** gates who reaches an environment at all,
  with Entra as the identity provider.
- **oauth2-proxy** fronts the observability endpoints (Grafana, Prometheus,
  Kiali) where it is enabled.
- **The API validates its own JWTs**, against the `bjjeire-api-<env>` Entra
  audience.

## Consequences

- Writing an `AuthorizationPolicy` with `to.operation.paths`,
  `to.operation.methods`, or a `when` clause on `request.auth.claims` produces
  a policy that is **accepted by the API server and silently never enforced**.
  Nothing errors. The rule simply has no effect, because no proxy in the path
  can evaluate it. This is the single most likely way to introduce a false
  sense of security in this repository.
- Per-path authorization is not available in-mesh. If a route needs it, the
  options are the API's own middleware, Cloudflare Access, or deploying a
  waypoint — in that order of preference.
- The mesh still provides strong workload identity and mTLS, which is what the
  L4 policies rely on.
- Dev deletes most of the observability `AuthorizationPolicy` resources via an
  overlay patch, because the observability stack is not deployed there
  ([ADR-0010](0010-observability-is-cost-gated-per-environment.md)).

## Alternatives considered

- **Deploy a waypoint for `bjjeire-app`.** Unlocks real L7 policy. Costs
  another Envoy deployment to size, upgrade, and debug, and duplicates
  authorization the API already performs on its own JWTs. Revisit if
  service-to-service authorization inside the namespace ever needs to differ by
  path.
- **Return to sidecars for L7 everywhere.** Rejected in
  [ADR-0003](0003-istio-ambient-not-sidecar.md) on cost.
- **Rely on NetworkPolicy alone.** Already used alongside these policies, but
  it has no notion of workload identity — only IPs and labels.
