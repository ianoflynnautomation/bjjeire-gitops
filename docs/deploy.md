# Deploy

How to validate changes locally and roll them out to AKS through Flux.

## Prerequisites

| Tool | Why |
|------|-----|
| `git` | PR workflow |
| `kubectl` | Optional cluster inspection after deploy |
| `flux` CLI | Reconcile / status / trace on cluster |
| `kustomize` | Build overlays locally |
| Optional: `kubeconform`, `yamllint`, `yq` | Used by `scripts/validate.sh` |

Cluster access requires a kubeconfig for the target AKS cluster and Flux already bootstrapped to this repository.

## Mental model

```
edit manifests → PR → CI validation → merge to main → Flux reconciles → verify on cluster
```

Never treat `kubectl apply -f` as the deployment path for resources owned by this repo. Flux will overwrite or fight you.

---

## Local validation

### 1. Build the overlay you care about

```bash
# Dev
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01 >/dev/null

# Staging
kustomize build kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01 >/dev/null

# Production
kustomize build kubernetes/apps/overlays/aks-bjjeire-prod-sdc-01 >/dev/null
```

Inspect rendered YAML when debugging patches:

```bash
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01/bjj-eire | less
```

### 2. Repo validation script

```bash
./scripts/validate.sh
```

Install missing deps if prompted (`kustomize`, `kubeconform`, `yq`, `yamllint`).

### 3. Dry-run a single file (syntax only)

```bash
kubectl apply --dry-run=client -f path/to/file.yaml
```

Client dry-run does **not** prove Flux/Helm semantics — still run kustomize/CI.

### 4. CI (what merge must pass)

Workflows under `.github/workflows/`:

- **Manifest Validation** — kustomize + kubeconform across clusters (`FLUX_VERSION` pinned in workflow)
- **flux-local** — deeper Flux/Helm local checks where configured
- **yaml-lint** / security policy workflows as applicable

Fix CI before requesting review for stg/prod promotions.

---

## Making a normal change

1. Branch from `main`.
2. Edit under `kubernetes/` (prefer overlay patches for env-specific behavior; keep `base/` shared).
3. Validate locally (above).
4. Open a PR; fill the PR template.
5. Merge after review (required for stg/prod promotion paths).
6. On the cluster:
   ```bash
   flux reconcile source git flux-system
   flux reconcile ks apps --with-source
   # or a specific Kustomization name:
   flux reconcile ks bjj-eire --with-source
   ```
7. Confirm:
   ```bash
   flux get ks
   flux get hr -A
   kubectl get pods -n bjjeire-app   # or relevant namespace
   ```

Default reconciliation intervals are on the order of **10m** for many Kustomizations and **1h** for some HelmReleases — force reconcile when you need faster feedback.

---

## Bootstrap a new cluster (reference)

Only when standing up a **new** AKS cluster already prepared with identity, Key Vault access, and cluster ConfigMaps:

```bash
flux bootstrap github \
  --owner=<github-org-or-user> \
  --repository=<this-repo> \
  --branch=main \
  --path=./kubernetes/clusters/<cluster-name>
```

Then ensure:

1. Overlay exists: `kubernetes/apps/overlays/<cluster-name>/`
2. Cluster entry exists: `kubernetes/clusters/<cluster-name>/ks.yaml` with correct `spec.path`
3. `cluster-config` / `workload-identity-config` ConfigMaps present for substitution
4. Secrets / pull credentials (e.g. GHCR) available via External Secrets or bootstrap process

Coordinate with the infrastructure owner (**@ianoflynn**) before bootstrapping production.

---

## Adding a new application (checklist)

1. Create `kubernetes/apps/base/<app-name>/` with namespace, `ks.yaml`, and `app/` (`helmrelease`, `ocirepository` or manifests, `kustomization.yaml`).
2. Wire `dependsOn` correctly relative to secrets, mesh, and certs.
3. Reference the new `ks.yaml` from the **target env overlay(s)** only when that env should run it.
4. If exposed externally:
   - `HTTPRoute` → parent `istio-ingressgateway` in `istio-ingress`
   - Gateway HTTPS listener if a new hostname is required
   - `AuthorizationPolicy` allowing the ingress gateway SA
   - Labels: `istio.io/dataplane-mode: ambient`, `gateway-access: "true"`
5. If it calls the internet: add a `ServiceEntry` under `istio-egress`.
6. Validate with `kustomize build` for each affected overlay.

---

## Environment-specific deploy notes

| Env | Deploy tips |
|-----|-------------|
| **dev** | Image tags may move via Flux automation after merge; chart bumps still need PRs. Observability largely disabled — don’t expect Grafana/Prometheus unless you re-enable them. |
| **stg** | Promote chart/image pins by PR; full platform closer to prod. |
| **prod** | Same as stg with stricter review; double-check cost/disabled components (e.g. Tempo). Prefer small, reversible PRs. |

Promotion details: [releases.md](releases.md).

---

## Related docs

- [Architecture](architecture.md)
- [bjj-eire.md](bjj-eire.md) — application overlay pins and values
- [bjj-eire-preview.md](bjj-eire-preview.md) — preview factory (dev only)
- [Operations](operations.md) — stuck reconciliations, suspend/resume, rollback
