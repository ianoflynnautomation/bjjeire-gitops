# BJJ Éire GitOps

[![Flux CD](https://img.shields.io/badge/Flux_CD-v2.8-blue?logo=flux&logoColor=white)](https://fluxcd.io/)
[![AKS](https://img.shields.io/badge/Azure-AKS-0078D4?logo=microsoftazure&logoColor=white)](https://learn.microsoft.com/azure/aks/)
[![Istio](https://img.shields.io/badge/Istio-1.29_ambient-466BB0?logo=istio&logoColor=white)](https://istio.io/)
[![Helm / OCI](https://img.shields.io/badge/Helm-OCI_(GHCR)-0F1689?logo=helm&logoColor=white)](https://helm.sh/)
[![Renovate](https://img.shields.io/badge/deps-Renovate-1A1F6C?logo=renovatebot&logoColor=white)](https://docs.renovatebot.com/)
[![CI](https://img.shields.io/badge/CI-manifest_validation-success)](.github/workflows/manifest-validation.yaml)

Declarative GitOps for the **BJJ Éire** platform on **Azure Kubernetes Service**, continuously reconciled by **Flux CD v2**.

If you are new here: read this page, then [Architecture](docs/architecture.md) → [Deploy](docs/deploy.md) → [Releases](docs/releases.md). Day-two ops live in [Operations](docs/operations.md).

---

## Purpose

This repository is the **source of truth** for cluster application state:

| Goal | How |
|------|-----|
| Safe, auditable deploys | Every change is a Git commit; Flux reconciles |
| Multi-environment delivery | Kustomize base + overlays (`dev` / `stg` / `prod`) |
| Hybrid dependency updates | Flux image automation (app tags in **dev**) + Renovate (charts & Actions) |
| Secure platform defaults | Istio ambient mesh, External Secrets, cert-manager, Kyverno |

**Do not** `kubectl apply` Flux-managed resources. Change Git, open a PR, merge, and let Flux reconcile.

---

## Quick start (onboarding)

1. **Clone** this repo and install tools: `kubectl`, `flux`, `kustomize` (optional: `kubeconform`, `yamllint`).
2. **Skim** [repository layout](#repository-layout) and [architecture](docs/architecture.md).
3. **Validate** a change locally: see [Deploy — local checks](docs/deploy.md#local-validation).
4. **Open a PR** against `main`. CI runs manifest validation / flux-local checks.
5. **After merge**, Flux applies state. Watch with:
   ```bash
   flux get ks --watch
   flux get hr -A | grep -v True
   ```
6. **Promote** app images or charts to stg/prod via PR — never rely on auto-promotion. Details: [Releases](docs/releases.md).

---

## Environments

| Environment | Cluster overlay | Image tags | Chart pin | Notes |
|-------------|-----------------|------------|-----------|--------|
| **dev** | `aks-bjjeire-dev-sdc-01` | Flux Image Automation (`$imagepolicy`) | Per-overlay OCI tag | Cost-trimmed (observability mostly off); Cloudflare Tunnel ingress |
| **stg** | `aks-bjjeire-stg-sdc-01` | Manual / promotion PR | Per-overlay OCI tag | Full-ish platform stack; promotion review |
| **prod** | `aks-bjjeire-prod-sdc-01` | Manual / promotion PR | Per-overlay OCI tag | Production; required review; some cost gates (e.g. Tempo) |

Bootstrap path per cluster: `kubernetes/clusters/<cluster-name>/`.

---

## Repository layout

```
kubernetes/
├── apps/
│   ├── base/                 # Shared, env-agnostic manifests
│   │   ├── bjj-eire/         # Application (umbrella Helm chart + image automation)
│   │   ├── istio-system/     # Control plane, ztunnel, policies, Gateway API
│   │   ├── istio-ingress/    # Gateway API Gateway + HTTP redirect
│   │   ├── istio-egress/     # ServiceEntry whitelist (REGISTRY_ONLY)
│   │   ├── network-system/   # cert-manager, external-dns, cloudflare-tunnel
│   │   ├── external-secrets/ # ESO + stores + cluster secrets
│   │   ├── observability/    # Prometheus, Grafana, Loki, Tempo, OTel, Kiali, oauth2-proxy
│   │   ├── actions-runner-system/
│   │   ├── kyverno/
│   │   └── flux-system/      # Helm/OCI sources, Flux extras
│   └── overlays/
│       ├── aks-bjjeire-dev-sdc-01/
│       ├── aks-bjjeire-stg-sdc-01/
│       └── aks-bjjeire-prod-sdc-01/
├── clusters/                 # Flux entrypoint per cluster (apps Kustomization)
└── infrastructure/           # Infra-level overlays (where used)

docs/                         # Human onboarding & ops guides (this set)
scripts/validate.sh           # Local YAML / kustomize / schema checks
renovate.json                 # Chart + Actions dependency PRs
```

### File conventions

| File | Role |
|------|------|
| `ks.yaml` / `k8.yaml` | Flux **Kustomization** — reconciles a path |
| `helmrelease.yaml` | Flux **HelmRelease** — installs/upgrades a chart |
| `ocirepository.yaml` | **OCIRepository** — OCI Helm chart source (e.g. GHCR) |
| `kustomization.yaml` | Kustomize resource list / patches |
| `values.yaml` | Helm values (often via `configMapGenerator`) |
| `helmrelease-images.yaml` | Per-env image tag patches (Flux markers **only in dev**) |

---

## Architecture (summary)

```
Git (this repo) ──► Flux source ──► Flux Kustomizations ──► AKS
                         │
         ┌───────────────┼────────────────┐
         ▼               ▼                ▼
   HelmReleases    Image policies    ConfigMaps (substitute)
   (OCI charts)    (dev images)      cluster-config, WI
```

**Platform highlights**

- **Mesh**: Istio **ambient** (ztunnel). Workloads enroll with `istio.io/dataplane-mode: ambient` — not sidecar injection.
- **Ingress**: Kubernetes **Gateway API** in `istio-ingress`; TLS via cert-manager + Let’s Encrypt (DNS-01 / Cloudflare).
- **Egress**: `REGISTRY_ONLY` — external hosts need a `ServiceEntry`.
- **Secrets**: External Secrets Operator → Azure Key Vault (Workload Identity).
- **App**: `bjj-eire` umbrella chart from `oci://ghcr.io/ianoflynnautomation/bjj-eire`.

Full diagram, dependency chain, and variable substitution: **[docs/architecture.md](docs/architecture.md)**.

---

## Documentation map

| Doc | Contents |
|-----|----------|
| [Architecture](docs/architecture.md) | Stack, base/overlay, deps, mesh, variables |
| [Deploy](docs/deploy.md) | Local validation, bootstrap, applying changes |
| [Releases](docs/releases.md) | Helm/OCI charts, image automation, promotion, Renovate |
| [Operations](docs/operations.md) | Flux commands, debug, common failures, rollback |
| [Contributing](CONTRIBUTING.md) | PR workflow, style, ownership |
| [Security](SECURITY.md) | Vulnerability reporting |

Agent-oriented conventions for automation tools: `AGENTS.md` / `CLAUDE.md` (not a substitute for this guide).

---

## Useful commands

```bash
# Status
flux check
flux get ks
flux get hr -A
flux get ks | grep -v True

# Always reconcile source first
flux reconcile source git flux-system
flux reconcile ks <name> --with-source

# Debug
flux logs --level=error
flux trace helmrelease/<name> -n <namespace>
flux suspend ks <name>   # then: flux resume ks <name>
```

More: **[docs/operations.md](docs/operations.md)**.

---

## Contributing & contacts

- Workflow, style, and review expectations: **[CONTRIBUTING.md](CONTRIBUTING.md)**
- Default code owner for `kubernetes/` and infra docs: **@ianoflynn** (see [CODEOWNERS](.github/CODEOWNERS))
- Security issues: **[SECURITY.md](SECURITY.md)** — do not open a public issue for secrets or exploits
- Infrastructure / cluster / Flux ownership: contact **@ianoflynn** before changing bootstrap paths, mesh policy, or promotion rules

---

## References

- [Flux CD](https://fluxcd.io/docs/)
- [Istio ambient](https://istio.io/latest/docs/ambient/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [External Secrets Operator](https://external-secrets.io/)
- [cert-manager](https://cert-manager.io/docs/)
- [Kustomize](https://kustomize.io/)
