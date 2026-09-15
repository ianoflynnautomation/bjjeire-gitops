---
name: flux-cd-gitops-engineering
description: >
  Generate, audit, and fix Flux CD v2 manifests in the bjjeire-gitops repository
  (HelmRelease, Kustomization, OCIRepository, ResourceSet, ImagePolicy, Receiver).
  Enforces this repo's CRD versions, base/overlay rules, ambient mesh, preview-dev-only
  constraints, and local dry-run validation. Use when creating or editing Flux YAML,
  adding an app to a cluster, changing bjj-eire or bjj-eire-preview, reviewing GitOps
  PRs, or when the user runs /flux-cd-gitops-engineering.
---

# Flux CD GitOps engineering (this repo)

You are generating or fixing Flux manifests **in bjjeire-gitops**, not a generic cluster.

## Mandatory reads (in order)

1. `.agent/rules/core-gitops.md` — hard constraints. Follow it.
2. If the change is under `kubernetes/apps/base/bjj-eire/` or an overlay `bjj-eire/` dir → `docs/bjj-eire.md`.
3. If the change is under `kubernetes/apps/base/bjj-eire-preview/` or Kyverno ephemeral policies → `docs/bjj-eire-preview.md`.
4. Field names / enums: grep `skills/gitops-knowledge/assets/schemas/<kind>-*.fields.txt`. Do not invent apiVersions or fields.

Do not paste those docs back to the user. Apply them.

## Workflow

1. **Inspect** the target overlay `kustomization.yaml` and a sibling `ks.yaml` / `helmrelease.yaml` / `ocirepository.yaml`.
2. **Draft** YAML that matches the sibling (install/upgrade/drift blocks, intervals, `---` + 2-space indent).
3. **Validate** before claiming the change is done:
   ```bash
   kustomize build kubernetes/apps/overlays/aks-bjjeire-<env>-sdc-01 >/dev/null
   .agent/validate.sh
   ```
   For a narrower check after a small edit:
   ```bash
   .agent/validate.sh kubernetes/apps/overlays/aks-bjjeire-<env>-sdc-01
   ```
   If validation is unavailable, say so and still run `kustomize build` on the affected overlay.
4. **Respond** with the YAML or patch, the rule/sibling it follows, and verification commands.

Never `kubectl apply` Flux-owned resources.

## Decision trees

### Source

- Versioned Helm chart in GHCR → `OCIRepository` (`source.toolkit.fluxcd.io/v1`) + `HelmRelease.spec.chartRef`. Helm `layerSelector` required.
- Third-party HTTPS chart repo → `HelmRepository` under `kubernetes/apps/base/flux-system/repositories/`.
- This Git repo's YAML → existing `GitRepository/flux-system`; add a Flux `Kustomization`, do not add another GitRepository.

### Where to put files

| What | Where |
|------|--------|
| Shared app/platform | `kubernetes/apps/base/<name>/` (`ks.yaml` + `app/` or `controller/`) |
| Env pin / values / extra route | `kubernetes/apps/overlays/<cluster>/` |
| Enable on a cluster | Reference `ks.yaml` from that overlay's `kustomization.yaml` |
| Preview factory | `bjj-eire-preview` — **dev overlay only** |

### HelmRelease install/upgrade

Copy the nearest sibling. Do not rewrite working `remediation` blocks into `RetryOnFailure` (or the reverse) as a drive-by.

### Dependencies

Keep this chain; do not add cycles:

```
gateway-api → istio-base → istio-cni → istiod → istio-gateway-config
external-secrets → external-secrets-stores → external-secrets-cluster-secrets
cert-manager → cert-manager-issuers → cert-manager-certificates → istio-gateway-config
```

`bjj-eire` KS `dependsOn` includes `grafana` in base; **dev** overlay replaces that with `external-secrets-stores` only (Grafana off).

## Out of scope

- Live cluster debugging (`flux get` on a real cluster) → `gitops-cluster-debug` / Flux MCP.
- Generic Flux API questions with no repo change → `gitops-knowledge`.
- Full repo security audit → `gitops-repo-audit`.
