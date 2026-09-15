# bjj-eire-preview — ephemeral test infrastructure

AI-first inventory of PR preview and SHA/main acceptance environments. **Dev cluster only.** Source of truth for the *factory* is Git. Generated namespaces are not stored in Git.

Related: [bjj-eire.md](bjj-eire.md) · [architecture.md](architecture.md) · [operations.md](operations.md)

---

## Identity

| Key | Value |
|-----|--------|
| Stack name | `bjj-eire-preview` |
| Kind | Flux Operator **ResourceSet factory** + optional CI kubectl template |
| Factory namespace | `flux-system` |
| Generated namespaces | `pr-<id>` or `inputs.ns` (SHA/debug) |
| Flux Kustomization | `bjj-eire-preview` in `flux-system` |
| ResourceSet | `bjj-eire-previews` |
| PR input provider | `ResourceSetInputProvider` `bjj-eire-prs` (`GitHubPullRequest`) |
| SHA input providers | Static `ResourceSetInputProvider` objects **applied by CI**, not in Git |
| Enabled clusters | **`aks-bjjeire-dev-sdc-01` only** |
| Guard on other clusters | Kyverno `ClusterPolicy/deny-ephemeral-envs` (dev overlay **deletes** it) |

This stack is **not** the long-lived `bjjeire-app` release. It installs the **same umbrella chart** (`OCIRepository/bjj-eire` in `bjjeire-app`) into a short-lived namespace with cheaper values.

---

## Purpose

| Env kind | Trigger | Image tag | Hostname pattern | TTL default |
|----------|---------|-----------|------------------|-------------|
| **PR preview** | GitHub PR on `ianoflynnautomation/bjjeire` with label `deploy-preview` | `pr-<id>-<sha>` unless `inputs.imageTag` set | `pr-<id>.${ROOT_DOMAIN}` and `api-pr-<id>.${ROOT_DOMAIN}` | `2h` (`janitor/ttl`) |
| **SHA / main acceptance** | CI applies a Static InputProvider labeled `bjjeire.io/sha-env=true` | `inputs.imageTag` (required in practice) | `sha-….${ROOT_DOMAIN}` / `api-sha-….${ROOT_DOMAIN}` when `ns`/`ENV_ID` uses `sha-*` | InputProvider `4h` (Kyverno); namespace TTL annotation still set |

Hard cap: PR provider `filter.limit: 3`. PRs beyond the limit get no environment (the provider truncates the input list); raising it raises concurrent dev-cluster load by one full app stack per env.

---

## Source paths

| Path | Flux-owned? | Role |
|------|-------------|------|
| `kubernetes/apps/base/bjj-eire-preview/ks.yaml` | yes | Flux Kustomization for the factory |
| `kubernetes/apps/base/bjj-eire-preview/kustomization.yaml` | yes | Includes `controller/` |
| `kubernetes/apps/base/bjj-eire-preview/controller/` | yes | SA, RBAC, secrets, provider, ResourceSet, Receivers, ephemeral values ConfigMap |
| `kubernetes/apps/base/bjj-eire-preview/sha-env/manifests.yaml` | **no** | envsubst-style kubectl template; **not** listed in any Kustomization |
| `kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01/kustomization.yaml` | yes | Unique reference to `../../base/bjj-eire-preview/ks.yaml` + deletes `deny-ephemeral-envs` |
| `kubernetes/apps/base/kyverno/policies/deny-ephemeral-envs.yaml` | yes (stg/prod) | Admission deny of ephemeral namespaces / PR providers |
| `kubernetes/apps/base/kyverno/policies/ephemeral-env-cleanup.yaml` | yes | TTL reap |
| `kubernetes/apps/base/kyverno/policies/restrict-hostnames-by-env.yaml` | yes | Hostname allowlists |

stg/prod overlays do **not** include `bjj-eire-preview/ks.yaml`. Copying the **dev** overlay to seed a new cluster would enable previews unless `deny-ephemeral-envs` remains (dev is the cluster that waives it).

---

## Flux Kustomization `bjj-eire-preview`

| Field | Value | Rationale |
|-------|--------|-----------|
| `apiVersion` | `kustomize.toolkit.fluxcd.io/v1` | |
| `spec.interval` | `10m` | Factory, not the app chart |
| `spec.retryInterval` | `1m` | |
| `spec.timeout` | `5m` | |
| `spec.prune` | `true` | |
| `spec.wait` | **`false`** | `wait: true` would wait on ResourceSet Ready; ResourceSet stays InProgress while any PR HelmRelease installs. CI (`flux-wait-helmrelease` in the app/tests repo) owns per-preview Ready |
| `spec.healthChecks` | InputProvider `bjj-eire-prs`, Receiver `bjj-eire-prs` | Factory health only |
| `spec.path` | `./kubernetes/apps/base/bjj-eire-preview/controller` | |
| `spec.targetNamespace` | `flux-system` | |
| `spec.dependsOn` | `external-secrets-stores` | PAT + webhook token |
| `spec.postBuild.substituteFrom` | `cluster-config` (required) | `${CLUSTER_DOMAIN}`, `${ROOT_DOMAIN}` |

---

## Event flow

### PR preview

```
1. Label GitHub PR deploy-preview (repo ianoflynnautomation/bjjeire)
2. Notification Receiver bjj-eire-prs (GitHub webhook) and/or
   Receiver bjj-eire-preview-oidc (GHA OIDC) reconcile the InputProvider + ResourceSet
   Fallback: InputProvider annotation fluxcd.controlplane.io/reconcileEvery: 1m
3. ResourceSetInputProvider GitHubPullRequest lists matching PRs (max 8)
4. ResourceSet bjj-eire-previews renders steps namespace then release
5. HelmRelease in pr-<id> installs chart from OCIRepository bjj-eire in bjjeire-app
6. Label removed / PR closed → provider drops input → ResourceSet prunes the namespace
```

### SHA / main acceptance (Flux-owned path)

```
1. CI applies ResourceSetInputProvider (kind Static) in flux-system
     labels: bjjeire.io/sha-env=true
     inputs: ns, imageTag, ttl, clusterDomain, rootDomain, …
2. ResourceSet inputsFrom selector matchLabels bjjeire.io/sha-env=true picks it up
3. Same ResourceSet steps as PR (namespace name = inputs.ns)
4. Kyverno ClusterCleanupPolicy ephemeral-sha-input-providers deletes the
   InputProvider after janitor/ttl (default 4h)
5. ResourceSet loses the input and prunes generated objects
```

Do **not** delete the SHA namespace by hand while the Static provider still exists — ResourceSet will recreate it. Delete the provider (or let Kyverno) and let prune run.

### SHA kubectl template (parallel artifact)

`sha-env/manifests.yaml` is a `${ENV_ID}` / `${IMAGE_TAG}` / `${ROOT_DOMAIN}` / `${TTL}` substitution template mirroring ResourceSet output. It is **not** reconciled by Flux.

| Constraint | Detail |
|------------|--------|
| ConfigMap gap | HelmRelease `valuesFrom` requires ConfigMap `bjj-eire-ephemeral-values` in the env namespace. ResourceSet copies it via annotation `fluxcd.controlplane.io/copyFrom: flux-system/bjj-eire-ephemeral-values`. The kubectl template **does not create that ConfigMap**. Do not apply the template unless CI also copies the ConfigMap. |
| Lockstep | Keep NetworkPolicy / AuthorizationPolicy / PeerAuthentication in `sha-env/manifests.yaml` aligned with `controller/resourceset.yaml`. |
| Prefer | Static InputProvider + ResourceSet so prune and Kyverno TTL stay consistent. |

---

## ResourceSet `bjj-eire-previews`

| Field | Value |
|-------|--------|
| `apiVersion` | `fluxcd.controlplane.io/v1` |
| `spec.serviceAccountName` | `flux-preview` |
| `spec.wait` | **`false`** — RS-level `wait: true` stays InProgress while any of the (up to `filter.limit`) preview HelmReleases install, and InputProvider updates cancel in-flight health checks. CI waits on the per-env HelmRelease instead |
| `spec.inputsFrom` | (1) named provider `bjj-eire-prs`; (2) selector `bjjeire.io/sha-env=true` |
| Combine | Flatten (default): PR inputs + SHA inputs in one list |
| `commonMetadata.labels` | `app.kubernetes.io/managed-by: flux-preview`, `bjjeire.io/preview: "true"`, `bjjeire.io/ephemeral: "true"`, `gateway-access: "true"`, `istio.io/dataplane-mode: ambient`, `pod-security.kubernetes.io/enforce: baseline`, `pod-security.kubernetes.io/warn: restricted` |
| Reconcile annotation | `fluxcd.controlplane.io/reconcileEvery: 1m` |

Template syntax is Flux Operator: `<< inputs.field >>`, **not** Helm `{{ }}`. The `<< >>` delimiters are required here — the same YAML carries External Secrets `{{ .mongodb_password }}` templates that must pass through untouched.

`commonMetadata.labels` deliberately **duplicates** the labels set inline on the generated Namespace. Flux `commonMetadata` overrides matching keys, and live applies were dropping those keys from the Namespace template; losing `gateway-access` makes the Gateway's `allowedRoutes` selector reject the namespace's HTTPRoutes and the preview 404s while everything else reports healthy. Keep both copies in sync.

### Built-in + default inputs

| Input | Source | Used for |
|-------|--------|----------|
| `inputs.id` | PR number (GitHubPullRequest) | Namespace `pr-<id>` |
| `inputs.sha` | PR head SHA | Default image tag suffix |
| `inputs.ns` | Static provider / optional | Overrides namespace name; presence also sets label `bjjeire.io/sha-env=true` |
| `inputs.ttl` | optional | Namespace annotation `janitor/ttl` (default `2h`) |
| `inputs.imageTag` | optional | Overrides default `pr-<id>-<sha>` on api/frontend/seeder |
| `inputs.clusterDomain` | provider `defaultValues` ← `${CLUSTER_DOMAIN}` | passed through |
| `inputs.rootDomain` | provider `defaultValues` ← `${ROOT_DOMAIN}` | HTTPRoute hosts + CORS |

Namespace expression used everywhere in the template:

```
<< get inputs "ns" | default (printf "pr-%s" inputs.id) >>
```

Use `get inputs "<key>"`, **not** bare `inputs.ns`. A bare field reference fails template rendering when a provider omits the key; `get` returns empty and lets `default` take over. Same idiom for the SHA/PR discriminator:

```
bjjeire.io/sha-env: '<< if get inputs "ns" >>true<< else >>false<< end >>'
```

Reads as: `ns` supplied → CI SHA env; absent → PR preview. Kyverno cleanup branches on this label (SHA namespaces are excluded from TTL reaping because the Static provider owns them).

---

## Steps

### Step `namespace` (timeout 2m)

Creates, per input:

| Kind | Name | Notes |
|------|------|-------|
| Namespace | `pr-<id>` or `inputs.ns` | Labels: ambient, `gateway-access`, PSA, `bjjeire.io/ephemeral=true`, `bjjeire.io/env-id`, `bjjeire.io/sha-env` true iff `inputs.ns` set. Annotation `janitor/ttl` |
| ResourceQuota `ephemeral` | same NS | cpu req `2` / lim `4`; mem req `2Gi` / lim `4Gi`; pods `20`; **`persistentvolumeclaims: "0"`** |
| LimitRange `ephemeral` | same NS | container default req `50m/128Mi`, default lim `500m/512Mi` |
| ConfigMap `bjj-eire-ephemeral-values` | copyFrom `flux-system` | Shared cheap Helm values |
| ExternalSecrets | mongodb, Entra, GHCR, donation | Same Key Vault keys as `bjjeire-app`. GHCR docker auth user is **`ianoflynnautomation`** (long-lived app secret template uses `ianoflynn`) |
| HTTPRoute `bjj-frontend` | listener `https-apex-wildcard` | `<<ns>>.<< inputs.rootDomain >>` → `bjj-frontend:80` |
| HTTPRoute `bjj-api` | listener `https-apex-wildcard` | `api-<<ns>>.<< inputs.rootDomain >>` → `bjj-api:8080` |
| NetworkPolicies | default-deny + allowlist | See matrix below |
| AuthorizationPolicies | internal, ingress, observability, runners | L4 only |
| PeerAuthentication | API :8080 and frontend :80 | **PERMISSIVE** for ARC plaintext |

### Step `release` (timeout 10m)

| Field | Value |
|-------|--------|
| HelmRelease name | `bjj-eire` in the env namespace |
| `spec.interval` | `5m` |
| `spec.timeout` | `10m` |
| `chartRef` | `OCIRepository/bjj-eire` **namespace `bjjeire-app`** (cross-namespace) |
| install/upgrade strategy | `RetryOnFailure`, retry `30s` |
| `driftDetection.mode` | `enabled` |
| `maxHistory` | `2` |
| `valuesFrom` | ConfigMap `bjj-eire-ephemeral-values` + Entra/donation secrets (same targetPaths as long-lived app) |
| Image tags | `inputs.imageTag` or `pr-<id>-<sha>` for api, frontend, seeder |

The long-lived `bjjeire-app` HelmRelease and OCIRepository must exist; previews do **not** create a second OCIRepository.

---

## Ephemeral Helm values (`controller/values-ephemeral.yaml`)

ConfigMap `bjj-eire-ephemeral-values` in `flux-system` (`disableNameSuffixHash: true`, `reconcile.fluxcd.io/watch: Enabled`). Copied into each env namespace.

| Key | Ephemeral | Long-lived prod (base) |
|-----|-----------|------------------------|
| Mongo persistence | **disabled** (required: PVC quota is 0) | 32Gi `managed-premium` |
| Mongo resources | req `50m/256Mi`, lim `500m/512Mi` | larger |
| API replicas / HPA | `2` / **off** | `2` / on |
| API resources | req `50m/256Mi`, lim `500m/512Mi` | larger |
| `READ_ONLY_MODE_ENABLED` | **`"false"`** | `"true"` |
| Rate limit permit | **`500`** / 10s | `5` (prod overlay `30`) |
| Frontend replicas / HPA | `2` / off | `2` / on |
| Seeder `force` | **`true`** | `false` |
| Seeder `environment` | `Development` | `Production` |
| Seeder `dataset` | `"test"` | unset in base |
| Seeder `hookPolicy` | `post-install,post-upgrade` | `post-install` |
| Chart ingress | false | false |

Per-env overlays in the ResourceSet still set CORS, in-cluster API URL, `waitForApi`, and `OTEL_RESOURCE_ATTRIBUTES`.

Acceptance tests (Playwright etc.) need writable APIs and the test dataset — that is why read-only is off and seeder force/upgrade hooks are on.

---

## DNS / TLS

| Fact | Value |
|------|--------|
| Why `${ROOT_DOMAIN}` not `${CLUSTER_DOMAIN}` | Cloudflare Universal SSL covers `*.${ROOT_DOMAIN}` (one label). Nested `*.${CLUSTER_DOMAIN}` (e.g. `pr-1.dev.example.com`) is **not** covered |
| Gateway listener | `https-apex-wildcard` on `Gateway/istio-ingressgateway`, hostname `*.${ROOT_DOMAIN}` |
| Kyverno allowlist (ephemeral NS) | `^(pr\|sha\|api-pr\|api-sha)-[a-zA-Z0-9]+.${ROOT_DOMAIN}$` |
| Examples | `pr-80.bjjeire.com`, `api-pr-80.bjjeire.com`, `sha-abc123.bjjeire.com` |

`debug-*` namespaces are denied by Kyverno name rule on non-dev clusters; hostname rule does **not** allow `debug-` hosts even on dev.

---

## Why ARC jobs talk plaintext to in-cluster Services

Acceptance jobs in `actions-runner-system` call:

```
http://bjj-api.<ns>.svc.cluster.local:8080
http://bjj-frontend.<ns>.svc.cluster.local:80
```

Reason: skip Cloudflare Bot Fight (JS challenge breaks HeadlessChrome XHR). Runners are **not** in ambient (privileged ARC / DinD). Mesh-wide STRICT mTLS would RST plaintext.

Mitigations (keep in lockstep between ResourceSet and `sha-env/manifests.yaml`):

| Layer | Object | Effect |
|-------|--------|--------|
| mTLS | PeerAuthentication port 8080 / 80 **PERMISSIVE** on api/frontend | Allows unauthenticated plaintext on those ports only |
| L7/L4 authz | `allow-actions-runners-to-preview` / `-frontend` | ALLOW from namespace `actions-runner-system` **or** `notPrincipals: ["*"]` (no SPIFFE) to those ports |
| NetworkPolicy | `allow-*-ingress-from-actions-runners` | L4 from `actions-runner-system` only |

Do not widen PERMISSIVE to the whole namespace. Do not remove `notPrincipals` without putting runners in the mesh.

---

## NetworkPolicy matrix (generated NS)

Same default-deny model as `bjjeire-app`, plus runner ingress. No mongodb-exporter policies (exporter is not installed in ephemeral values).

| Policy | Extra vs long-lived app |
|--------|-------------------------|
| `allow-api-ingress-from-actions-runners` | **preview-only** |
| `allow-frontend-ingress-from-actions-runners` | **preview-only** |
| Frontend ingress from gateway | 80 + 15008 (no 443, unlike long-lived frontend policy) |
| Mongo ingress | api + seeder only (no exporter) |

---

## RBAC (`flux-preview`)

ServiceAccount `flux-preview` in `flux-system`. ClusterRole/Binding `flux-preview` — verbs create/get/list/watch/update/patch/delete on:

| API group | Resources |
|-----------|-----------|
| `""` | namespaces, configmaps, resourcequotas, limitranges |
| `networking.k8s.io` | networkpolicies |
| `gateway.networking.k8s.io` | httproutes |
| `external-secrets.io` | externalsecrets |
| `helm.toolkit.fluxcd.io` | helmreleases |
| `security.istio.io` | authorizationpolicies, peerauthentications |

No cluster-wide `*` . If the ResourceSet template gains a new kind, this ClusterRole must gain that kind in the **same PR**.

---

## Secrets for the factory

| ExternalSecret (flux-system) | Key Vault | Kubernetes Secret | Consumer |
|------------------------------|-----------|-------------------|----------|
| `github-preview-token` | `github-preview-pat` | keys `username=git`, `password=<token>` | InputProvider `secretRef` |
| `flux-preview-webhook` | `flux-preview-webhook-token` | key `token` | Receiver `bjj-eire-prs` |

Terraform (dev AKS module) must populate those Key Vault secrets. Without the PAT, the ResourceSet has **no PR inputs** (SHA Static providers still work). Webhook is optional; poll interval `1m` is the fallback.

PAT scope: Contents + Pull requests **read** on `ianoflynnautomation/bjjeire`.

---

## Receivers

| Receiver | Type | When it fires | Resources reconciled |
|----------|------|---------------|----------------------|
| `bjj-eire-prs` | `github` | `ping`, `pull_request` | InputProvider `bjj-eire-prs`, ResourceSet `bjj-eire-previews` |
| `bjj-eire-preview-oidc` | `generic-oidc` | GHA OIDC to `notification-controller` | same |

OIDC validations:

| Claim check | Value |
|-------------|--------|
| issuer | `https://token.actions.githubusercontent.com` |
| audience | `notification-controller` |
| `claims.repository` | `ianoflynnautomation/bjjeire` |

Health check on Flux Kustomization `bjj-eire-preview` includes **only** the GitHub Receiver, not the OIDC one.

---

## Kyverno

### `deny-ephemeral-envs` (stg/prod; deleted on **dev**)

| Rule | Denies |
|------|--------|
| `no-ephemeral-namespaces` | Namespace with `bjjeire.io/ephemeral=true` **or** `app.kubernetes.io/managed-by=flux-preview` |
| `no-preview-namespace-names` | Names matching `^(pr\|sha\|debug)-.+` |
| `no-pull-request-input-providers` | `ResourceSetInputProvider` type `GitHubPullRequest` or `GitLabMergeRequest` |

Closes: (1) preview factory accidentally added to a non-dev overlay; (2) CI `kubectl apply -f sha-env/manifests.yaml` against stg/prod.

### `ephemeral-env-namespaces` (ClusterCleanupPolicy, every 15m)

Deletes namespaces labeled `bjjeire.io/ephemeral=true` whose age ≥ `janitor/ttl` (default `2h`).

**Excludes** namespaces labeled `bjjeire.io/sha-env=true` — those are Flux-owned via Static providers. Reaping the namespace would fight ResourceSet.

### `ephemeral-sha-input-providers`

Deletes `ResourceSetInputProvider` in `flux-system` with `bjjeire.io/sha-env=true` whose age ≥ `janitor/ttl` (default `4h`). ResourceSet then prunes.

### `restrict-hostnames-by-env`

See hostname allowlist above. Long-lived routes still must match `${CLUSTER_DOMAIN}`.

---

## Decision rules (do / do not)

| Do | Do not |
|----|--------|
| Enable previews only on **dev** overlay + explicit delete of `deny-ephemeral-envs` | Reference `bjj-eire-preview/ks.yaml` from stg/prod |
| Add new generated kinds to ResourceSet **and** ClusterRole `flux-preview` **and** `sha-env/manifests.yaml` if that template stays | Edit only one of the two YAML copies |
| Use `<< inputs.field >>` in ResourceSet | Use Helm `{{ }}` in ResourceSet (conflicts with ESO templates inside the same YAML) |
| Point preview HelmRelease at `OCIRepository` in `bjjeire-app` | Duplicate the OCIRepository per PR namespace |
| Keep Mongo persistence **off** while PVC quota is 0 | Enable PVCs without raising `persistentvolumeclaims` |
| Tear down SHA envs by deleting the Static InputProvider | `kubectl delete ns sha-*` while the provider still exists |
| Keep PERMISSIVE mTLS port-scoped for runners | Namespace-wide PERMISSIVE or STRICT that breaks ARC |

---

## Anti-patterns already encoded

| Anti-pattern | How this stack avoids it |
|--------------|--------------------------|
| Parent KS `wait: true` stuck on installing PR releases | `spec.wait: false` + healthChecks on factory CRs only |
| Preview factory copied to a new cluster overlay | `deny-ephemeral-envs` inherited unless waived |
| Nested preview hostnames vs Cloudflare Universal SSL | `https-apex-wildcard` + `${ROOT_DOMAIN}` |
| ResourceSet Ready blocked / CI timeout | CI waits on the **HelmRelease**, not the factory KS |
| SHA namespace janitor fighting Flux | Cleanup deletes the **InputProvider**, not the SHA namespace |
| HelmRelease in `flux-system` | Generated HR `metadata.namespace` is the env namespace |

---

## Verification

```bash
# Factory is in the dev overlay, not stg/prod
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01 | grep -c 'name: bjj-eire-preview'
kustomize build kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01 | grep 'kind: ResourceSet' || true

# On dev cluster
flux get ks bjj-eire-preview
flux get resourceset -n flux-system
flux get resourcesetinputprovider -n flux-system
kubectl get ns -l bjjeire.io/ephemeral=true
kubectl get hr -A -l app.kubernetes.io/managed-by=flux-preview
kubectl get receiver -n flux-system

# A single PR env
kubectl get hr,httproute,netpol,externalsecret -n pr-<id>
flux get hr -n pr-<id>
```

Expected: stg/prod must **not** contain `ResourceSet/bjj-eire-previews`. Dev must contain it, and must **not** contain `ClusterPolicy/deny-ephemeral-envs`.
