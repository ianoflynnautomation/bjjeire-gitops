# Architecture Decision Records

Decisions with lasting consequences for this repository, and the reasoning
behind them. Several look like gaps or misconfigurations from the outside — the
ADR explains why they are deliberate and what breaks if reversed.

Format: [MADR](https://adr.github.io/madr/). One file per decision, numbered
sequentially, never renumbered. Superseding a decision means writing a new ADR
and flipping the old one's status — not editing it.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-flux-reconciles-git-is-the-only-write-path.md) | Flux CD v2 reconciles; Git is the only write path | Accepted |
| [0002](0002-kustomize-base-and-overlays-per-cluster.md) | Kustomize base + per-cluster overlays, one branch | Accepted |
| [0003](0003-istio-ambient-not-sidecar.md) | Istio **ambient** dataplane, never sidecar injection | Accepted |
| [0004](0004-registry-only-egress.md) | Egress is `REGISTRY_ONLY` with an explicit `ServiceEntry` allowlist | Accepted |
| [0005](0005-no-waypoint-l4-authorization-policies.md) | No waypoint proxy, so AuthorizationPolicies stay L4 | Accepted |
| [0006](0006-split-release-trains-images-and-charts.md) | Two release trains: Flux image automation (dev) and Renovate (charts) | Accepted |
| [0007](0007-preview-environments-are-dev-only.md) | Preview environments exist on dev only, enforced by Kyverno | Accepted |
| [0008](0008-secrets-via-external-secrets-and-workload-identity.md) | Secrets come from Key Vault via ESO and Workload Identity | Accepted |
| [0009](0009-cloudflare-tunnel-is-dev-ingress.md) | Cloudflare Tunnel is dev's only ingress | Accepted |
| [0010](0010-observability-is-cost-gated-per-environment.md) | The observability stack is cost-gated per environment | Accepted |

## Adding one

Copy [`0000-template.md`](0000-template.md), take the next number, and link it
from the table above — and from [AGENTS.md](../../AGENTS.md) if an agent could
plausibly try to reverse it.
