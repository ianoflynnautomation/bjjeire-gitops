# ADR-0003: Istio ambient dataplane, never sidecar injection

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/istio-system/`, every namespace that joins the mesh

## Context

The platform runs on small AKS node pools (`Standard_D2ps_v6`, 1–3 nodes for
apps). A sidecar mesh adds an Envoy container to every pod: roughly 50–100 MiB
of memory and a CPU request per workload, plus pod startup ordering problems
where the application races the proxy.

Istio's ambient dataplane moves L4 mTLS into a per-node `ztunnel` DaemonSet, so
workload pods carry no proxy at all.

## Decision

Ambient only, in every environment. `istiod` and `istio-cni` run with
`profile: ambient`, and `ztunnel` provides the L4 dataplane.

**Namespaces join the mesh with a label:**

```yaml
metadata:
  labels:
    istio.io/dataplane-mode: ambient
```

**Never** add `istio-injection: enabled` or
`sidecar.istio.io/inject: "true"`. Those are sidecar-mode controls; in an
ambient cluster they either do nothing or produce a pod that is both
sidecar-injected and ambient-captured.

In-mesh traffic uses **HBONE on port 15008**. NetworkPolicies that restrict
pod-to-pod traffic must allow it, or mTLS connections fail while plain
connections appear fine.

The reconcile order is fixed and encoded in `dependsOn`:

```
gateway-api → istio-base → istio-cni → istiod → ztunnel → istio-gateway-config
```

## Consequences

- Per-pod overhead drops to zero, which is what makes the small node pools
  viable. Adding a workload does not add a proxy.
- mTLS is mesh-wide `STRICT`, with `istio-ingress` set `PERMISSIVE` so the
  Azure load balancer and external health probes can reach the gateway.
- **Ambient gives L4 only.** There is no per-pod Envoy to run L7 policy, which
  is the subject of [ADR-0005](0005-no-waypoint-l4-authorization-policies.md).
- A NetworkPolicy written without port 15008 will break in-mesh traffic in a
  way that looks like an application bug — connections hang rather than being
  refused.
- Advice found online for Istio usually assumes sidecars. Annotations,
  `EnvoyFilter` examples, and most `AuthorizationPolicy` samples do not
  transfer.
- Skipping a step in the `dependsOn` chain leaves `istiod` stuck waiting on
  CRDs that `istio-base` has not applied yet.

## Alternatives considered

- **Sidecar mode.** Mature, full L7 per workload, far more documentation.
  Rejected on cost and pod-startup complexity at this cluster size.
- **No mesh, NetworkPolicy only.** Cheapest, but gives up mTLS between
  workloads and the Gateway API integration the ingress path depends on.
- **Linkerd.** Lighter than sidecar Istio, but the ingress story here is built
  on Istio's Gateway API implementation and Kiali.
