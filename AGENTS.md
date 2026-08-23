# AGENTS.md

## Repository Overview

This is a Flux CD v2 GitOps repository managing applications on Azure Kubernetes Service (AKS) with Istio service mesh. All cluster state is declared in Git and continuously reconciled by Flux.

## Repository Structure

```
kubernetes/
  apps/
    base/           # Environment-agnostic configurations (shared across clusters)
    overlays/       # Per-cluster customizations (Kustomize overlays)
  clusters/         # Cluster bootstrap (Flux entrypoint)
  infrastructure/   # Infrastructure-level resources
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
- `${CLUSTER_DOMAIN}` - Cluster domain (e.g., bjjopenmatfinder.com)
- `${WORKLOAD_IDENTITY_CLIENT_ID}` - Azure Workload Identity client ID
- `${TENANT_ID}` - Azure AD tenant ID
- `${PRIVATE_EMAIL}` - Email for Let's Encrypt registration

These variables are defined in `cluster-config` and `workload-identity-config` ConfigMaps. Never hardcode cluster-specific values in `base/` - always use substitution variables.

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

2. **Kubernetes Jobs with Istio sidecars**: Jobs (like Helm hook jobs) will never complete if they get an Istio sidecar. Add `sidecar.istio.io/inject: "false"` as a pod annotation:
   ```yaml
   podAnnotations:
     sidecar.istio.io/inject: "false"
   ```

3. **Gateway health probes on AKS**: The Gateway service must use TCP health probes (not HTTP/HTTPS) because hostname-based routing returns 404 for probe requests. This is configured via `spec.infrastructure.annotations` on the Gateway resource.

4. **AuthorizationPolicies**: When adding a new service behind the ingress gateway, create an AuthorizationPolicy that allows traffic from `cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio`.

5. **Namespace labels**: Namespaces need `istio-injection: enabled` for sidecar injection and `gateway-access: "true"` for HTTPS route access through the gateway.

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
