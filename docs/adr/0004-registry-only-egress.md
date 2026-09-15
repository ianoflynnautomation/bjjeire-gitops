# ADR-0004: Egress is `REGISTRY_ONLY` with an explicit ServiceEntry allowlist

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/istio-egress/config/service-entries.yaml`

## Context

Istio's default `outboundTrafficPolicy` is `ALLOW_ANY`: any pod may open a
connection to any host on the internet. For a cluster that pulls charts,
images, and secrets from a handful of known endpoints, that is far more egress
than the workloads need, and it makes exfiltration from a compromised pod
invisible.

## Decision

`outboundTrafficPolicy: REGISTRY_ONLY`. Traffic to a host outside the mesh is
refused unless a `ServiceEntry` names it.

The current allowlist, in `istio-egress/config/service-entries.yaml`:

| Purpose | Hosts |
|---|---|
| Certificates | `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org` |
| DNS / edge | `api.cloudflare.com` |
| Azure identity + secrets | `*.vault.azure.net`, `login.microsoftonline.com`, `sts.windows.net`, `graph.microsoft.com` |
| Charts and images | `ghcr.io`, `docker.io`, `registry-1.docker.io`, `production.cloudflare.docker.com`, `quay.io`, `registry.k8s.io`, `grafana.com` |
| Source | `github.com`, `raw.githubusercontent.com` |

**Adding an external dependency means adding a `ServiceEntry`.** There is no
other way for a workload to reach a new host.

## Consequences

- The blast radius of a compromised pod is bounded by this list, and the list
  is a reviewable artefact in Git.
- **The failure mode is confusing.** A blocked call does not return "forbidden"
  — it fails as a connection error, a DNS-looking failure, or a client-side
  timeout deep inside a library. When a new integration cannot reach its API
  and the credentials are known-good, check this file before anything else.
- The list needs maintenance. A registry that moves to a new CDN hostname, or a
  chart that starts pulling from a new mirror, breaks a previously working
  reconcile with no change on our side.
- Wildcards are used sparingly (`*.vault.azure.net`), because each one widens
  the allowlist by an unknown amount.
- Egress config depends on `istiod`, so it cannot be the first thing to
  reconcile in a fresh cluster.

## Alternatives considered

- **`ALLOW_ANY`.** The Istio default and no maintenance. Rejected: it gives up
  the main security benefit of routing egress through the mesh at all.
- **`ALLOW_ANY` plus NetworkPolicy egress rules.** NetworkPolicy works on IPs
  and CIDRs, not hostnames, which is unusable against CDN-fronted registries
  whose addresses change constantly.
- **An egress gateway with per-namespace policy.** Finer-grained and gives a
  single audited exit point, at the cost of another deployment to run and route
  through. Worth revisiting if the allowlist ever needs to differ per
  namespace; today it does not.
