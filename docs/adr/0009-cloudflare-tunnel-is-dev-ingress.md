# ADR-0009: Cloudflare Tunnel is dev's only ingress

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/network-system/cloudflare-tunnel/`, overlay resource lists

## Context

Exposing a Gateway API `Gateway` on AKS the conventional way provisions an
Azure public load balancer with a public IP. That is a standing cost per
environment and a public attack surface that has to be locked down at the NSG
level.

Cloudflare Tunnel inverts it: a `cloudflared` Deployment in the cluster opens an
outbound connection to Cloudflare's edge, and Cloudflare routes inbound traffic
back down it. No public IP, no inbound listener, nothing to allowlist.

## Decision

`cloudflare-tunnel` runs in `network-system` in every environment, with its
tunnel token supplied by an `ExternalSecret` from Key Vault. Its origin is the
Istio ingress gateway on `:443`.

On **dev** it is the *only* ingress — the overlay says so explicitly:

```yaml
# Cloudflare Tunnel is dev's only ingress — no public Azure LB.
- ../../base/network-system/cloudflare-tunnel/ks.yaml
```

TLS still terminates in-cluster at the Gateway, using the wildcard certificate
cert-manager obtains from Let's Encrypt via DNS-01. Cloudflare's own edge
certificate covers the client-to-edge hop.

`external-dns` publishes the Cloudflare DNS records that point at the tunnel.

## Consequences

- Dev has no public IP and no inbound path other than the tunnel. Combined with
  the Cloudflare-only NSG on the Azure side, the origin is not reachable
  directly.
- **The tunnel is a single point of failure for dev ingress.** If `cloudflared`
  cannot start — most often because its `ExternalSecret` has not synced — the
  environment is unreachable with no fallback path, and the symptom is a
  Cloudflare error page rather than a Kubernetes one.
- `cloudflare-tunnel` depends on `external-secrets-stores`, so it inherits the
  post-teardown failure described in
  [ADR-0008](0008-secrets-via-external-secrets-and-workload-identity.md).
- Client IPs arrive as Cloudflare edge addresses unless forwarded headers are
  honoured. Anything doing IP-based logic must read `CF-Connecting-IP`.
- Debugging spans two systems: `kubectl logs` for the connector, and the
  Cloudflare dashboard for tunnel health and routes.

## Alternatives considered

- **Azure public load balancer everywhere.** Standard, well understood, and
  gives a direct path for debugging. Rejected for dev on cost and exposure; the
  tunnel also matches how the Azure stack locks the origin down.
- **Tunnel in every environment as the sole ingress.** Attractive for
  consistency, but makes Cloudflare a hard dependency for production
  availability with no in-Azure fallback.
- **Private Link / API Management in front.** More moving parts and cost than
  this platform justifies.
