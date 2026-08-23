# CLAUDE.md

## Project Context

Flux CD v2 GitOps repository for AKS with Istio service mesh. All cluster state lives in Git and is reconciled by Flux. Never apply changes directly to the cluster - always commit to Git.

## Key Commands

```bash
# Check cluster state
flux get ks                          # All kustomizations
flux get hr -A                       # All HelmReleases
flux get ks | grep -v True           # Find failures

# Force reconciliation (always source first)
flux reconcile source git flux-system && flux reconcile ks <name>

# Unstick a kustomization
flux suspend ks <name> && flux resume ks <name>

# Validate before pushing
kustomize build kubernetes/apps/overlays/aks-bjjeire-prod-swn-01
```

## File Patterns

| File | Purpose |
|------|---------|
| `ks.yaml` | Flux Kustomization (reconciles a directory) |
| `helmrelease.yaml` | Flux HelmRelease (installs a Helm chart) |
| `kustomization.yaml` | Standard Kustomize resource list |
| `values.yaml` | Helm values (referenced via configMapGenerator) |
| `ocirepository.yaml` | OCI Helm chart source |

## Critical Rules

1. **Never hardcode cluster-specific values in `base/`** - use `${VARIABLE}` substitution from `cluster-config` ConfigMap
2. **Never set `webhook.url.host` in cert-manager values** - breaks AKS API server webhook calls
3. **Never use `driftDetection.mode: enabled` on istiod or istio-base** - use `mode: warn` (external controllers mutate these resources)
4. **The mesh is ambient-only - never add `istio-injection` labels or `sidecar.istio.io/inject` annotations** - enroll workload namespaces with `istio.io/dataplane-mode: ambient` instead (Jobs complete normally in ambient)
5. **All external endpoints need a ServiceEntry** - outbound policy is REGISTRY_ONLY (default deny)
6. **Azure LB health probes must use TCP** - HTTP/HTTPS probes fail due to hostname-based routing returning 404
7. **Keep letsencrypt-staging ClusterIssuer** - useful for testing certificate changes without hitting rate limits

## Dependency Chain

```
gateway-api -> istio-base -> istio-cni -> istiod -> istio-gateway-config -> observability-routes
external-secrets -> external-secrets-stores -> external-secrets-cluster-secrets
cert-manager -> cert-manager-issuers -> cert-manager-certificates -> istio-gateway-config
```

Do not break or create circular dependencies.

## Available Variables

Used in `base/` via Flux `postBuild.substituteFrom`:

- `${CLUSTER_DOMAIN}` - e.g., bjjopenmatfinder.com
- `${WORKLOAD_IDENTITY_CLIENT_ID}` - Azure Workload Identity
- `${TENANT_ID}` - Azure AD tenant ID
- `${PRIVATE_EMAIL}` - Let's Encrypt email
- `${OAUTH2_PROXY_CLIENT_ID}` - Azure Entra App Registration client ID
- `${OAUTH2_PROXY_ALLOWED_GROUP}` - Azure Entra security group Object ID

## Istio Quick Reference

- **Dataplane**: ambient-only, all envs (ztunnel + `profile: ambient` in base
  istiod/istio-cni values). Workload namespaces enroll via the
  `istio.io/dataplane-mode: ambient` label (`bjjeire-app`, `observability`).
  No namespace uses sidecar injection; the ingress gateway injects its proxy
  via its own pod annotation, independent of namespace labels. In-mesh
  traffic uses HBONE port 15008 — NetworkPolicies must allow it (see base
  bjj-eire netpols). L7 policy (JWT, path/method rules) needs a waypoint —
  none deployed; keep AuthorizationPolicies L4-only (principals, namespaces,
  ports) unless you add one.
- **Mesh mTLS**: STRICT (istio-system) with PERMISSIVE override in istio-ingress
- **Ingress**: Gateway API `Gateway` resource auto-provisions deployment + LoadBalancer service
- **Egress**: REGISTRY_ONLY - whitelist via ServiceEntry in `istio-egress/config/service-entries.yaml`
- **Gateway service account**: `istio-ingressgateway-istio` (used in AuthorizationPolicies)
- **Mesh enrollment**: namespace label `istio.io/dataplane-mode: ambient`
- **Gateway route access**: namespace label `gateway-access: "true"`

## Adding a New Exposed Service

1. Add `ServiceEntry` if it calls external APIs
2. Create `HTTPRoute` referencing `istio-ingressgateway` in `istio-ingress`
3. Add HTTPS listener to Gateway if using a dedicated hostname
4. Create `AuthorizationPolicy` allowing `cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio`
5. Ensure namespace has labels: `istio.io/dataplane-mode: ambient`, `gateway-access: "true"`
6. Add to overlay `kustomization.yaml`

## Release Pipeline — Source of Truth

Three repos, two independent release trains converging on Flux:

```
BjjEire (app code)              bjjeire-deploy (charts)
   │                                │
   │ release-please tags             │ release-please tags
   │   api-v*, frontend-v*           │   umbrella-v*, api-v*, web-v*, mongodb-v*
   ▼                                ▼
GHCR: ghcr.io/.../bjjeire-{api,frontend,seeder}:v{semver}
                                 GHCR: oci://ghcr.io/.../bjj-eire:{semver}
   │                                │
   │ ImageRepository + ImagePolicy   │ Per-env OCIRepository (tag pinned)
   │ ImageUpdateAutomation (dev)     │ Renovate PRs + branch policy
   ▼                                ▼
HelmRelease values image.tag        overlay kustomization OCIRepository tag
(helmrelease-images.yaml)           (bjj-eire/kustomization.yaml)
```

### Hybrid automation model

| What | Owner | Mechanism | Environments |
|------|--------|-----------|--------------|
| App image tags (`bjjeire-api`, `frontend`, `seeder`) | **Flux Image Automation** | `$imagepolicy` markers → direct commit | **dev only** (stg/prod have no markers; promote by PR) |
| Umbrella + infra OCI chart tags | **Renovate** | PRs via `.github/workflows/renovate.yaml` | All envs; stg/prod labeled `needs-promotion-review` |
| GitHub Actions workflow deps | **Renovate** | PRs | repo-wide |

Do **not** let Renovate manage Flux-owned app image files (`helmrelease-images.yaml`,
`image-automation/**`). Config lives in root `renovate.json`.

**Cascade rule: image-tag-only.** App releases bump container image tags via Flux
image automation. Chart releases (template changes) are independent. App releases
do NOT auto-bump chart versions — if a release needs both, ship the chart change
in `bjjeire-deploy` separately.

**Chart version pinning is per-env.** Each cluster overlay owns its chart version:

- `apps/overlays/aks-bjjeire-{env}-sdc-01/bjj-eire/kustomization.yaml` patches
  `OCIRepository.spec.ref.tag` to the env's pinned version.
- The cluster's main `apps/overlays/aks-bjjeire-{env}-sdc-01/kustomization.yaml`
  rewrites the `bjj-eire` Flux Kustomization's `spec.path` to its overlay dir so
  the patch takes effect.
- Promotion: merge a Renovate (or manual) PR that bumps the tag in the target env
  overlay. Required reviewer enforces the gate. Bumping dev does not touch stg/prod.

Base `apps/base/bjj-eire/app/ocirepository.yaml` carries a default tag only as a
fallback for standalone use of base — overlays always override. Renovate ignores
that base file.

### Renovate setup (one-time)

1. Create a GitHub PAT (bot preferred) with Contents R/W, PRs R/W, Issues R/W
   (dependency dashboard), Packages R.
2. Add repository secret `RENOVATE_TOKEN`.
3. Run workflow **Renovate** manually (`workflow_dispatch`, optional dry-run) once.
4. Keep branch protection on `main` so chart PRs still need review/CI.

**Rollback.** First choice: `git revert` the offending overlay commit in this
repo and let Flux reconcile. Break-glass: `flux suspend helmrelease bjj-eire -n bjjeire-app`
in the affected cluster, edit the overlay tag back to the known-good version,
`flux resume`.

**Notifications.** Flux `notification-controller` is installed (see PodMonitor in
`flux-instance/extras/`) but no `Provider`/`Alert` is configured yet. Pick a
destination (Slack/Discord/GitHub commit status) before relying on async deploy
visibility — until then, watch with `flux get hr -A -w`.

## Code Style

- `---` at top of every YAML file
- 2-space indentation
- Quote ambiguous strings (`"true"`, `"false"`, `"443"`)
- Namespace goes in Kustomization `targetNamespace`, not in resource metadata
- Directory and namespace names: lowercase with hyphens
- HelmRelease and Kustomization names match the app/chart name
- Commit messages: describe what and why, never commit secrets
