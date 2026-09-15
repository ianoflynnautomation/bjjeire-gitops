# AGENTS.md

This is the single source of agent instructions for this repository.
`CLAUDE.md` points here — keep changes in this file.

## Repository Overview

This is a Flux CD v2 GitOps repository managing applications on Azure Kubernetes Service (AKS) with Istio service mesh. All cluster state is declared in Git and continuously reconciled by Flux.

## Read this before you change anything

Several settings here look like gaps or misconfigurations and are deliberate.
The reasoning is in [docs/adr/](docs/adr/); read the relevant record before
reversing one.

| If you are touching… | Read first |
|---|---|
| Mesh mode, injection labels, Job annotations | [ADR-0003](docs/adr/0003-istio-ambient-not-sidecar.md) |
| An `AuthorizationPolicy` | [ADR-0005](docs/adr/0005-no-waypoint-l4-authorization-policies.md) — L7 rules silently do nothing |
| Anything calling an external host | [ADR-0004](docs/adr/0004-registry-only-egress.md) |
| Image tags or chart pins | [ADR-0006](docs/adr/0006-split-release-trains-images-and-charts.md) |
| Preview / ephemeral environments | [ADR-0007](docs/adr/0007-preview-environments-are-dev-only.md) |
| Secrets | [ADR-0008](docs/adr/0008-secrets-via-external-secrets-and-workload-identity.md) |
| Enabling or disabling observability | [ADR-0010](docs/adr/0010-observability-is-cost-gated-per-environment.md) |
| Overlay structure, `$patch: delete` | [ADR-0002](docs/adr/0002-kustomize-base-and-overlays-per-cluster.md) |

Architecture reference: [docs/architecture.md](docs/architecture.md).
Full index: [docs/README.md](docs/README.md).

## Hard rules

1. **Never `kubectl apply` a Flux-managed resource.** Commit to Git and let
   Flux reconcile. A manual apply works, then silently reverts within the
   reconcile interval. If you must intervene, `flux suspend ks <name>` first —
   and remember to resume. See [ADR-0001](docs/adr/0001-flux-reconciles-git-is-the-only-write-path.md).
2. **Never hardcode cluster-specific values in `base/`** — use `${VARIABLE}`
   substitution.
3. **Never set `webhook.url.host` in cert-manager values** — it breaks AKS API
   server webhook calls.
4. **Never use `driftDetection.mode: enabled` on `istiod` or `istio-base`** —
   use `mode: warn`; external controllers mutate those resources.
5. **The mesh is ambient-only** — never add `istio-injection` labels or
   `sidecar.istio.io/inject` annotations. Enrol namespaces with
   `istio.io/dataplane-mode: ambient`.
6. **Every external endpoint needs a `ServiceEntry`** — outbound policy is
   `REGISTRY_ONLY` (default deny).
7. **Azure LB health probes must be TCP** — HTTP/HTTPS probes 404 because
   routing is hostname-based.
8. **Keep the `letsencrypt-staging` ClusterIssuer** — it is how certificate
   changes get tested without burning rate limits.
9. **Never commit secrets.** Values live in Azure Key Vault and arrive via
   External Secrets; manifests reference names only.
10. **Never add `$imagepolicy` markers to a staging or prod overlay** — that
    silently converts the environment to continuous deployment.
11. **`prune: true` is set**, so removing a resource from an overlay deletes it
    from the cluster. Comment-outs are deletions.

## Repository Structure

```
kubernetes/
  apps/
    base/           # Environment-agnostic configurations (shared across clusters)
    overlays/       # Per-cluster customizations (Kustomize overlays)
  clusters/         # Cluster bootstrap (Flux entrypoint)
```

### Key Conventions

- **`ks.yaml`**: Flux Kustomization resource that reconciles a directory of manifests
- **`helmrelease.yaml`**: Flux HelmRelease for Helm chart installations
- **`kustomization.yaml`**: Standard Kustomize file for resource composition
- **`values.yaml`**: Helm values, referenced via `configMapGenerator` in `kustomization.yaml`
- **`ocirepository.yaml`**: OCI-based Helm chart source references

### Base/Overlay Pattern

- `base/` contains reusable, environment-agnostic configurations
- `overlays/<cluster-name>/kustomization.yaml` composes base resources and applies cluster-specific values
- Adding a new app to a cluster means adding a reference to its `ks.yaml` in the overlay

### Application stacks (read these before editing)

| Stack | Git path | Doc | Cluster |
|-------|----------|-----|---------|
| Long-lived app | `kubernetes/apps/base/bjj-eire/` | [docs/bjj-eire.md](docs/bjj-eire.md) | dev, stg, prod |
| PR/SHA test factory | `kubernetes/apps/base/bjj-eire-preview/` | [docs/bjj-eire-preview.md](docs/bjj-eire-preview.md) | **dev only** |

Do not add `bjj-eire-preview/ks.yaml` to stg/prod. Do not `kubectl apply` `sha-env/manifests.yaml` without copying ConfigMap `bjj-eire-ephemeral-values`. Prefer Static `ResourceSetInputProvider` (`bjjeire.io/sha-env=true`) for SHA envs.

### Agent pack (load before generating Flux YAML)

| File | Role |
|------|------|
| `.agent/rules/core-gitops.md` | Hard constraints (apiVersions, prune, overlay, mesh, preview) |
| `.agent/validate.sh` | Local dry-run: wraps `scripts/validate.sh` + extra `kustomize build` paths |
| `.grok/skills/flux-cd-gitops-engineering/SKILL.md` | Workflow skill (`/flux-cd-gitops-engineering`) |

## Flux CD Conventions

### Resource Dependencies

Flux Kustomizations use `dependsOn` to define reconciliation order. Always respect the dependency chain:

```
gateway-api -> istio-base -> istio-cni -> istiod -> istio-gateway-config
external-secrets -> external-secrets-stores -> external-secrets-cluster-secrets
cert-manager -> cert-manager-issuers -> cert-manager-certificates -> istio-gateway-config
```

When adding new resources, place them in the correct dependency position. Do not create circular dependencies.

### HelmRelease Best Practices

- Always set `install.remediation.retries` and `upgrade.remediation` with rollback strategy
- Use `crds: CreateReplace` for charts that manage CRDs
- Set appropriate `timeout` values (10m for most, 30m+ for large charts like kube-prometheus-stack)
- Use `driftDetection.mode: enabled` for most resources
- Use `driftDetection.mode: warn` for resources where external controllers mutate state (istiod, istio-base)
- Add `driftDetection.ignore` rules for fields managed by webhooks or external controllers

### Variable Substitution

Flux `postBuild.substituteFrom` injects variables from ConfigMaps at reconciliation time:

| Variable | Use |
|---|---|
| `${CLUSTER_DOMAIN}` | Public hostnames for this cluster (e.g. `dev.bjjeire.com`) |
| `${ROOT_DOMAIN}` | Root / API host variants (e.g. `api-dev.${ROOT_DOMAIN}`) |
| `${WORKLOAD_IDENTITY_CLIENT_ID}` | Azure Workload Identity client ID |
| `${TENANT_ID}` | Entra tenant ID |
| `${PRIVATE_EMAIL}` | Email for Let's Encrypt registration |
| `${OAUTH2_PROXY_CLIENT_ID}` | Entra app registration for oauth2-proxy |
| `${OAUTH2_PROXY_ALLOWED_GROUP}` | Allowed Entra group object ID |
| `${CLUSTER_ID}` | Overlay / image-automation path |

These variables come from the `cluster-config` and `workload-identity-config`
ConfigMaps, which are created by the **`bjjeire-terraform-gitops-flux-bootstrap`
repository**, not by this one. A `${VARIABLE}` that resolves to an empty string
is usually a bootstrap gap — check there before adding a default here.

Never hardcode cluster-specific values in `base/` when a substitution variable exists.

### Reconciliation

- Default reconciliation interval is 30m for most Kustomizations, 1h for HelmReleases
- Force reconciliation: `flux reconcile source git flux-system && flux reconcile ks <name>`
- Always reconcile the source first, then the kustomization
- Never use `kubectl apply` directly - all changes must flow through Git

## Istio Service Mesh

### Architecture

- **STRICT mTLS** mesh-wide via PeerAuthentication in `istio-system`
- **PERMISSIVE mTLS** in `istio-ingress` namespace (required for Azure LB health probes)
- **REGISTRY_ONLY** outbound traffic policy - all external destinations must have a ServiceEntry
- **Gateway API** (not legacy Istio Gateway) for ingress configuration
- The Gateway auto-provisions its own deployment and service in `istio-ingress`

### Common Pitfalls

1. **New external dependency**: If a workload needs to reach an external service, add a `ServiceEntry` in `istio-egress/config/service-entries.yaml`. Without it, traffic will be blocked by REGISTRY_ONLY policy.

2. **The mesh is ambient — there are no sidecars.** Never add
   `istio-injection: enabled` or `sidecar.istio.io/inject`. There is not a
   single occurrence of either in `kubernetes/`, and adding one is a bug.
   Kubernetes Jobs complete normally under ambient; the sidecar-era workaround
   of annotating them `sidecar.istio.io/inject: "false"` is unnecessary here.
   See [ADR-0003](docs/adr/0003-istio-ambient-not-sidecar.md).

3. **Gateway health probes on AKS**: The Gateway service must use TCP health probes (not HTTP/HTTPS) because hostname-based routing returns 404 for probe requests. This is configured via `spec.infrastructure.annotations` on the Gateway resource.

4. **AuthorizationPolicies**: When adding a new service behind the ingress gateway, create an AuthorizationPolicy that allows traffic from `cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio`.

5. **Keep AuthorizationPolicies L4.** No waypoint proxy is deployed, so rules
   matching on HTTP path, method, or JWT claims are **accepted by the API
   server and silently never enforced**. Nothing errors — the rule simply has
   no effect. Match on principals, namespaces, and ports.
   See [ADR-0005](docs/adr/0005-no-waypoint-l4-authorization-policies.md).

6. **Namespace labels**: workload namespaces need
   `istio.io/dataplane-mode: ambient` to join the mesh, and
   `gateway-access: "true"` for HTTPS route access through the gateway.

7. **HBONE**: in-mesh traffic uses port **15008**. NetworkPolicies that
   restrict pod-to-pod traffic must allow it, or mTLS connections hang while
   plain connections look fine.

### Adding a New Ingress Route

1. Create an `HTTPRoute` resource in the service's namespace
2. Reference `istio-ingressgateway` in `istio-ingress` as the `parentRef`
3. Add a corresponding HTTPS listener to the Gateway if using a dedicated hostname
4. Add an `AuthorizationPolicy` for the backend service
5. Add ExternalDNS annotations for automatic DNS record creation

## cert-manager

- Uses Let's Encrypt production with DNS-01 challenges via Cloudflare
- Wildcard certificate (`*.${CLUSTER_DOMAIN}`) issued in `network-system` namespace
- The Gateway references this certificate for TLS termination
- Drift detection ignores webhook configuration fields (managed by cert-manager itself)
- The `webhook.url.host` value must NOT be set - it breaks AKS API server webhook calls

## Coding Standards

### YAML

- Use `---` document separator at the top of every YAML file
- Use 2-space indentation
- Quote string values that could be misinterpreted (booleans, numbers)
- Place namespace in the Kustomization's `targetNamespace`, not in individual resource metadata (unless the resource is cluster-scoped)

### Naming

- Directories: lowercase with hyphens (e.g., `kube-prometheus-stack`)
- Namespaces: lowercase with hyphens (e.g., `istio-system`, `network-system`)
- Flux Kustomization names should match the application name
- HelmRelease names should match the Helm chart name

### Git Commits

- Commit messages should describe what changed and why
- Group related changes in a single commit (e.g., adding a new app includes ks.yaml, helmrelease.yaml, values.yaml)
- Never commit secrets, tokens, or credentials

## Testing Changes

### Before Pushing

```bash
# Validate YAML syntax
kubectl apply --dry-run=client -f <file>

# Build and validate kustomize output
kustomize build kubernetes/apps/overlays/<cluster-name>

# Check Flux-specific resources
flux check
```

### After Pushing

```bash
# Watch reconciliation
flux get ks --watch

# Check for errors
flux get ks | grep -v True
flux get hr -A | grep -v True

# View controller logs
flux logs --level=error
```

## Dependency & Image Automation (Hybrid)

| What | Owner | Where |
|------|--------|--------|
| App container image tags (api / frontend / seeder) | **Flux** `ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` | Dev only via `$imagepolicy` markers in `helmrelease-images.yaml` |
| OCI Helm chart tags (umbrella + infra) | **Renovate** PRs | `ocirepository.yaml` + per-env overlay chart pins |
| GitHub Actions actions | **Renovate** PRs | `.github/workflows/*` |

- Config: root `renovate.json`, runner: `.github/workflows/renovate.yaml` (needs `RENOVATE_TOKEN` secret).
- Never add `$imagepolicy` markers to stg/prod image overlays (promotion stays a human PR).
- Never enable Renovate on Flux-managed app image packages or `helmrelease-images.yaml`.
- Image automation Kustomization is only referenced from the **dev** cluster overlay.

### Cascade rule: image-tag only

App releases bump **container image tags** through Flux image automation. Chart
releases (template changes, shipped from `bjjeire-deploy`) are independent. An
app release does **not** auto-bump a chart version — if a change needs both,
ship the chart change separately.

### Chart version pinning is per environment

- `apps/overlays/aks-bjjeire-<env>-sdc-01/bjj-eire/kustomization.yaml` patches
  `OCIRepository.spec.ref.tag` to that environment's pinned version.
- The overlay's top-level `kustomization.yaml` rewrites the `bjj-eire` Flux
  Kustomization's `spec.path` to the overlay directory, which is what makes the
  patch take effect. Changing one without the other is a common mistake.
- Promotion is a PR bumping the tag in the target overlay. Bumping dev does not
  touch stg or prod.
- `apps/base/bjj-eire/app/ocirepository.yaml` carries a default tag only as a
  fallback for standalone use of `base/`; overlays always override it and
  Renovate ignores it.

### Rollback

First choice: `git revert` the offending overlay commit and let Flux reconcile.

Break-glass:

```bash
flux suspend helmrelease bjj-eire -n bjjeire-app
# edit the overlay tag back to the known-good version, commit, push
flux resume helmrelease bjj-eire -n bjjeire-app
```

### Notifications

`notification-controller` is installed (see the PodMonitor in
`flux-instance/extras/`) but no `Provider` or `Alert` is configured. Until one
is, async deploy visibility is `flux get hr -A -w` — do not assume a failed
reconcile will page anyone.

## Common Operations

### Adding a New Application

1. Create directory structure: `kubernetes/apps/base/<app-name>/app/`
2. Create `helmrelease.yaml`, `kustomization.yaml`, `values.yaml`, `ocirepository.yaml`
3. Create `kubernetes/apps/base/<app-name>/ks.yaml` (Flux Kustomization)
4. Add reference to `ks.yaml` in the overlay `kustomization.yaml`
5. If the app needs external access: create namespace, HTTPRoute, AuthorizationPolicy
6. If the app calls external services: add ServiceEntry resources

### Debugging a Stuck Kustomization

1. Check `flux get ks` for the error message
2. Check dependencies: `flux get ks | grep False` - parent must be Ready first
3. Check HelmRelease: `flux get hr -A` - look for install/upgrade failures
4. Check pod status: `kubectl get pods -n <namespace>` - look for CrashLoop, Pending, or sidecar issues
5. Force re-reconciliation: `flux reconcile source git flux-system && flux reconcile ks <name>`
6. If truly stuck: `flux suspend ks <name> && flux resume ks <name>`

### Suspending a Resource

```bash
# Suspend to prevent reconciliation during debugging
flux suspend ks <name>

# Resume when done
flux resume ks <name>
```

Never delete Flux-managed resources directly with `kubectl delete` - Flux will recreate them. Use `flux suspend` instead, or remove the resource from Git.
