# bjj-eire — long-lived application

AI-first inventory of the production BJJ Éire application as declared in this GitOps repository. Source of truth is Git. Flux reconciles. Do not `kubectl apply` these objects.

Related: [architecture.md](architecture.md) · [bjj-eire-preview.md](bjj-eire-preview.md) · [releases.md](releases.md) · [deploy.md](deploy.md)

---

## Identity

| Key | Value |
|-----|--------|
| Stack name | `bjj-eire` |
| Kind | Long-lived umbrella Helm release + supporting Kubernetes objects |
| Workload namespace | `bjjeire-app` |
| Flux Kustomization | `bjj-eire` in `flux-system` |
| HelmRelease | `bjj-eire` in `bjjeire-app` |
| Chart source | `OCIRepository` `bjj-eire` → `oci://ghcr.io/ianoflynnautomation/bjj-eire` |
| Chart owner repo | `bjjeire-deploy` (not this repo) |
| Image owner repo | `BjjEire` / `bjjeire` (not this repo) |
| Enabled clusters | **dev**, **stg**, **prod** (all three overlays) |
| Image automation | **dev only** (`bjj-eire-image-automation`) |

---

## Purpose

Deploy the BJJ Éire product surface onto AKS:

| Component | Kubernetes object (typical) | Role |
|-----------|-----------------------------|------|
| `bjj-api` | Deployment / Service `bjj-api` | ASP.NET Core API, port **8080** |
| `bjj-frontend` | Deployment / Service `bjj-frontend` | Caddy/Node frontend, port **80** |
| `bjj-mongodb` | StatefulSet / Service `bjj-mongodb` | MongoDB, port **27017** |
| `bjjeire-seeder` | Helm hook Job | Seeds MongoDB on install (and overlay-dependent upgrades) |
| `bjj-mongodb-exporter` | Deployment / Service (base; deleted in **dev**) | Percona exporter, port **9216** |

Ingress, secrets, network policy, and (stg/prod) scrape/dashboards live **beside** the chart in this repo, not inside the umbrella chart.

---

## Source paths

| Path | What it is |
|------|------------|
| `kubernetes/apps/base/bjj-eire/namespace.yaml` | Namespace `bjjeire-app` |
| `kubernetes/apps/base/bjj-eire/kustomization.yaml` | Kustomize: namespace only (applied via overlay `resources`) |
| `kubernetes/apps/base/bjj-eire/ks.yaml` | Flux Kustomization `bjj-eire` (path rewritten per overlay) |
| `kubernetes/apps/base/bjj-eire/app/` | HelmRelease, OCIRepository, routes, secrets, netpols, monitors |
| `kubernetes/apps/base/bjj-eire/image-automation/` | ImageRepository / ImagePolicy / ImageUpdateAutomation |
| `kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01/bjj-eire/` | Dev chart pin, image tags, values, extra API route, observability deletes |
| `kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01/bjj-eire/` | Staging chart pin, image tags, values |
| `kubernetes/apps/overlays/aks-bjjeire-prod-sdc-01/bjj-eire/` | Production chart pin, image tags, values |

Overlay composition rule: each cluster overlay **rewrites** Flux Kustomization `bjj-eire.spec.path` from `./kubernetes/apps/base/bjj-eire/app` to `./kubernetes/apps/overlays/<cluster>/bjj-eire`. That overlay kustomization **includes** `../../../base/bjj-eire/app` and applies patches. The namespace is created because the overlay also lists `../../base/bjj-eire` (the parent kustomization with `namespace.yaml`).

---

## Flux objects

### Kustomization `bjj-eire`

| Field | Base (`ks.yaml`) | Dev overlay patch |
|-------|------------------|-------------------|
| `apiVersion` | `kustomize.toolkit.fluxcd.io/v1` | unchanged |
| `metadata.namespace` | `flux-system` | unchanged |
| `spec.interval` | `30m` | unchanged |
| `spec.retryInterval` | `1m` | unchanged |
| `spec.timeout` | `10m` | unchanged |
| `spec.prune` | `true` | unchanged |
| `spec.wait` | `true` | unchanged |
| `spec.sourceRef` | `GitRepository/flux-system` | unchanged |
| `spec.targetNamespace` | `bjjeire-app` | unchanged |
| `spec.path` | `./kubernetes/apps/base/bjj-eire/app` | `./kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01/bjj-eire` (stg/prod analogous) |
| `spec.dependsOn` | `external-secrets-stores`, `grafana` | **dev:** `external-secrets-stores` only (Grafana is disabled) |
| `spec.postBuild.substituteFrom` | `cluster-config`, `workload-identity-config` (both required) | unchanged |

stg/prod keep the base `dependsOn` including `grafana`.

### HelmRelease `bjj-eire`

| Field | Value |
|-------|--------|
| `apiVersion` | `helm.toolkit.fluxcd.io/v2` |
| Namespace | `bjjeire-app` |
| `spec.interval` | `15m` |
| `spec.chartRef` | `OCIRepository/bjj-eire` (same namespace) |
| `spec.install.timeout` | `10m` |
| `spec.install.replace` | `true` |
| `spec.install.crds` | `CreateReplace` |
| `spec.install.createNamespace` | `false` |
| `spec.install.remediation.retries` | `3` |
| `spec.upgrade.remediation.retries` | `3` |
| `spec.upgrade.remediation.remediateLastFailure` | `true` |
| `spec.upgrade.remediation.strategy` | `rollback` |
| `spec.upgrade.cleanupOnFail` | `true` |
| `spec.upgrade.crds` | `CreateReplace` |
| `spec.rollback.recreate` | `true` |
| `spec.driftDetection.mode` | `enabled` |
| `spec.maxHistory` | `3` |
| Chart ingress | **disabled** (`bjj-api.ingress.enabled: false`, `bjj-frontend.ingress.enabled: false`) — Gateway API HTTPRoutes in this repo own ingress |

### OCIRepository `bjj-eire`

| Field | Value |
|-------|--------|
| `apiVersion` | `source.toolkit.fluxcd.io/v1` |
| URL | `oci://ghcr.io/ianoflynnautomation/bjj-eire` |
| `spec.interval` | `5m` |
| `spec.ref.tag` | overlay-pinned (base fallback `"0.2.3"`) |
| `spec.secretRef` | `ghcr-pull-secret` |
| Layer selector | Helm chart media type, `operation: copy` |

**Promotion rule:** bumping this tag is a **Renovate / human PR** in the target overlay. Dev chart bump does not change stg/prod.

---

## Namespace

`bjjeire-app` labels (must stay):

| Label | Value | Why |
|-------|--------|-----|
| `istio.io/dataplane-mode` | `ambient` | Mesh enrollment (not sidecar injection) |
| `gateway-access` | `"true"` | Gateway HTTPS listeners allow routes from this NS |
| `pod-security.kubernetes.io/enforce` | `baseline` | PSA |
| `pod-security.kubernetes.io/warn` | `restricted` | PSA warn |

Do **not** add `istio-injection: enabled` or `sidecar.istio.io/inject`.

---

## Substitution variables used by this stack

Injected by Flux `postBuild.substituteFrom` (`cluster-config`, `workload-identity-config`):

| Variable | Used in | Meaning |
|----------|---------|---------|
| `${CLUSTER_DOMAIN}` | HTTPRoutes, CORS | Public app host (apex / www / api) |
| `${ROOT_DOMAIN}` | Dev extra listener + `httproute-api-dev.yaml` | Zone apex (Cloudflare Universal SSL). Dev also exposes `api-dev.${ROOT_DOMAIN}` |
| `${API_CLIENT_ID}` | API ServiceAccount annotation | Azure Workload Identity for API |
| `${SEEDER_CLIENT_ID}` | Seeder ServiceAccount annotation | Azure Workload Identity for seeder |
| `${CLUSTER_ID}` | ImageUpdateAutomation path/commit | Overlay directory name, e.g. `aks-bjjeire-dev-sdc-01` |

Never hardcode cluster hostnames or WI client IDs in `base/`.

---

## Secrets (External Secrets → Azure Key Vault)

All use `ClusterSecretStore` `azure-keyvault-store`, `refreshInterval: 1h`, `creationPolicy: Owner`.

| ExternalSecret | Kubernetes Secret | Key Vault keys | Consumed by |
|----------------|-------------------|----------------|-------------|
| `bjj-mongodb-root-password` | same; key `mongodb-password` | `bjj-mongodb-root-password` | MongoDB, API, seeder, exporter |
| `bjj-azure-ad-secret` | keys `ENTRA_ISSUER_URI`, `ENTRA_AUDIENCE`, `ENTRA_AUDIENCE_URI` | `bjj-api-azuread-tenant-id`, `bjj-api-azuread-client-id`, `bjj-api-azuread-audience` | HelmRelease `valuesFrom` → `bjj-api.api.env.*` |
| `ghcr-pull-secret` | `kubernetes.io/dockerconfigjson` | `ghcr-pat` | OCIRepository + imagePullSecrets. Template user **`ianoflynn`** |
| `bjj-donation-secret` | `DONATION_BITCOIN_ADDRESS` | `bjj-donation-bitcoin-address` | HelmRelease `valuesFrom` → `bjj-api.api.env.DONATION_BITCOIN_ADDRESS` |

Helm controller must be able to read those Secrets in `bjjeire-app` at reconcile time. If Entra/donation secrets are missing, the HelmRelease cannot render values.

---

## Ingress (Gateway API)

Parent: `Gateway/istio-ingressgateway` in `istio-ingress`. TLS: `wildcard-tls-secret` in `network-system`.

| HTTPRoute | Listener (`sectionName`) | Hostname | Backend |
|-----------|--------------------------|----------|---------|
| `bjj-frontend-root` | `https-root` | `${CLUSTER_DOMAIN}` | `bjj-frontend:80` |
| `bjj-frontend-www` | `https-wildcard` | `www.${CLUSTER_DOMAIN}` | `bjj-frontend:80` |
| `bjj-api` | `https-wildcard` | `api.${CLUSTER_DOMAIN}` | `bjj-api:8080` |
| `bjj-api-root-wildcard` (**dev overlay only**) | `https-root-wildcard` | `api-dev.${ROOT_DOMAIN}` | `bjj-api:8080` |

Dev overlay also patches Flux Kustomization `istio-gateway-config` to **add** Gateway listener `https-root-wildcard` for `api-dev.${ROOT_DOMAIN}`.

Edge path:

```
Client → Cloudflare (Tunnel in dev; Tunnel and/or LB elsewhere)
      → Gateway istio-ingressgateway :443
      → HTTPRoute in bjjeire-app
      → Service (ambient HBONE 15008 in-mesh)
```

Kyverno `restrict-hostnames-by-env` enforces HTTPRoute hostnames in `bjjeire-app` / `istio-ingress` / `observability` match `${CLUSTER_DOMAIN}`. Ephemeral hosts are a separate rule (see [bjj-eire-preview.md](bjj-eire-preview.md)).

---

## Mesh & L4 policy

Mesh-wide `AuthorizationPolicy` `default-deny` in `istio-system` (empty spec = deny all). Workload allows (in `istio-system/policy/ambient-authorization-policies.yaml`, **not** in `bjj-eire/`):

| Policy | Namespace | Allows |
|--------|-----------|--------|
| `allow-ingress-to-bjjeire-app` | `bjjeire-app` | principal `cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio` |
| `allow-bjjeire-app-internal` | `bjjeire-app` | source namespace `bjjeire-app` |
| `allow-observability-to-bjjeire-app` | `bjjeire-app` | source namespace `observability` |

Keep these L4 (principals / namespaces / ports). No waypoint is deployed; JWT/path AuthorizationPolicies will not work as intended.

NetworkPolicies in `app/networkpolicy.yaml` (default-deny + allowlist). All in-mesh rules include **TCP 15008** (HBONE) in addition to the app port.

| NetworkPolicy | Direction | From / To | Ports |
|---------------|-----------|-----------|-------|
| `default-deny-all` | in+out | — | — |
| `allow-dns-egress` | egress | `kube-system` | 53 UDP/TCP |
| `allow-frontend-ingress-from-gateway` | ingress | `istio-ingress` | 80, 443, 15008 |
| `allow-api-ingress-from-gateway-and-frontend` | ingress | `istio-ingress` + pods `bjj-frontend` | 8080, 15008 |
| `allow-mongodb-ingress-from-api` | ingress | `bjj-api`, `bjjeire-seeder`, mongodb exporter | 27017, 15008 |
| `allow-frontend-egress-to-api` | egress | `bjj-api` | 8080, 15008 |
| `allow-api-egress-to-mongodb` | egress | `bjj-mongodb` | 27017, 15008 |
| `allow-seeder-egress-to-mongodb` | egress | `bjj-mongodb` | 27017, 15008 |
| `allow-api-egress-internet` | egress | `0.0.0.0/0` except RFC1918 + link-local | 443 |
| `allow-api-metrics-ingress-from-observability` | ingress | `observability` | 8080, 15008 |
| `allow-mongodb-exporter-egress` | egress | mongodb server pods | 27017, 15008 |
| `allow-mongodb-metrics-ingress-from-observability` | ingress | `observability` | 9216, 15008 |
| `allow-api-egress-to-otel-collector` | egress | `observability` | 4318, 15008 |

**Dev overlay deletes** the four observability-related NetworkPolicies plus exporter Deployment/Service, ServiceMonitors, PrometheusRule, and GrafanaDashboards (observability stack is off).

API egress to the public internet still requires a matching **ServiceEntry** under `istio-egress` (`REGISTRY_ONLY`). Identity/Key Vault hosts already exist (`login.microsoftonline.com`, `*.vault.azure.net`, Graph). Add a ServiceEntry before introducing a new external API.

---

## Helm values — base vs overlay

Base lives in `app/helmrelease.yaml`. Overlays strategic-merge `spec.values`.

### Shared / base defaults (production-shaped)

| Key | Base |
|-----|------|
| Mongo persistence | `managed-premium`, `32Gi` |
| Mongo resources | req `1000m/1Gi`, lim `2000m/2Gi` |
| API replicas | `2` + HPA `2–10` @ 70% CPU, PDB `minAvailable: 1` |
| API resources | req `500m/512Mi`, lim `1000m/1Gi` |
| Frontend replicas | `2` + HPA `2–6` @ 70% CPU / 80% mem, PDB `minAvailable: 1` |
| Frontend resources | req `200m/256Mi`, lim `500m/512Mi` |
| `READ_ONLY_MODE_ENABLED` | `"true"` |
| Rate limit | enabled, permit `5` / 10s, 429 |
| Feature flags | events, gyms, stores, competitions all `"true"` |
| CORS | `https://${CLUSTER_DOMAIN}`, `https://www.${CLUSTER_DOMAIN}` |
| OTLP | `http://opentelemetry-collector.observability.svc.cluster.local:4318` (`http/protobuf`) |
| Frontend `SERVICES_API_HTTP_0` | `http://bjj-api.bjjeire-app.svc.cluster.local:8080` |
| Frontend `waitForApi` | API readiness URL on that Service |
| Seeder | `enabled: true`, `force: false`, `environment: Production`, `hookPolicy: post-install` |
| WI | API + seeder SAs annotated; pods labeled `azure.workload.identity/use: "true"` |

Image tags in **base** HelmRelease are fallbacks only. Overlays always patch tags.

### Environment matrix (overlay deltas)

| Concern | **dev** | **stg** | **prod** |
|---------|---------|---------|----------|
| Overlay values file | `helmrelease-dev-values.yaml` | `helmrelease-stg-values.yaml` | `helmrelease-prod-values.yaml` |
| Chart tag (current pin) | `"0.2.3"` | `"0.2.3"` | `"0.2.3"` |
| Image automation | Yes (`$imagepolicy` + ImageUpdateAutomation) | Overlay file still contains `$imagepolicy` comments; **automation KS is not referenced** — tags move only by PR | Same as stg |
| API/frontend replicas | `1`, HPA off | `1`, HPA API `1–3`, frontend `1–2` | Base (`2` + HPA) |
| Mongo size / class | `10Gi` / `default` | `20Gi` / `default` | Base `32Gi` / `managed-premium` |
| Seeder | `dataset: test`, `force: true`, `environment: Development` | `dataset: test` (force/env inherit base unless patched) | Base Production / force false |
| Rate limit permit | `30` | `30` | `30` (prod overlay) |
| OTEL / Prometheus scrape | `OTEL_SDK_DISABLED: "true"`, scrape `"false"` | Base (on) | Base (on) |
| Dashboards / ServiceMonitors / exporter | Deleted by overlay patches | Present | Present |
| Extra hostname | `api-dev.${ROOT_DOMAIN}` | — | — |

**Intended promotion model:** Flux Image Automation writes **dev** image tags on `main`. Humans copy verified tags into stg/prod `helmrelease-images.yaml` via PR. Do not enable `bjj-eire-image-automation` on stg/prod. Prefer removing `$imagepolicy` markers from stg/prod when editing those files so they cannot be activated by accident.

---

## Image automation (dev only)

Flux Kustomization `bjj-eire-image-automation`:

| Field | Value |
|-------|--------|
| Path | `./kubernetes/apps/base/bjj-eire/image-automation` |
| Interval | `30m` |
| Prune / wait | `true` / `true` |
| `targetNamespace` | `bjjeire-app` |
| `dependsOn` | `external-secrets-cluster-secrets` (GHCR pull secret) |
| Referenced from | **dev overlay only** |

| Kind | Names | Spec highlights |
|------|-------|-----------------|
| `ImageRepository` | `bjjeire-api`, `bjjeire-frontend`, `bjjeire-seeder` | `ghcr.io/ianoflynnautomation/...`, interval `5m`, `secretRef: ghcr-pull-secret` |
| `ImagePolicy` | same names | tag `^v(?P<version>[0-9]+\.[0-9]+\.[0-9]+)$`; semver `>=0.1.0 <1.0.0` except **frontend** `>=0.1.30 <1.0.0` |
| `ImageUpdateAutomation` `bjj-eire` | — | checkout/push `main`; Setters; path `./kubernetes/apps/overlays/${CLUSTER_ID}/bjj-eire`; author Flux Bot |

Marker shape in `helmrelease-images.yaml`:

```yaml
tag: v0.1.19 # {"$imagepolicy": "bjjeire-app:bjjeire-api:tag"}
```

Renovate must **not** own these files or the GHCR app image packages.

---

## Observability (stg/prod; stripped in dev)

| Object | Name | Notes |
|--------|------|-------|
| `ServiceMonitor` | `bjj-api` | `/metrics` on port `http`, 30s |
| `ServiceMonitor` | `bjj-mongodb` | exporter port `metrics` (9216) |
| `PrometheusRule` | `bjj-mongodb` | exporter missing, down, restarts, connections, queue, WiredTiger cache |
| `GrafanaDashboard` | `bjj-eire-api` | Grafana operator, instance label `grafana.internal/instance: grafana` |
| `GrafanaDashboard` | `bjj-eire-mongodb` | same |
| Exporter image | `percona/mongodb_exporter:0.51.0` | non-root, read-only root, no SA token |

---

## Workload identity & security context

| Workload | SA | WI | Security |
|----------|----|----|----------|
| API | `bjjeire-api` (created) | `${API_CLIENT_ID}` + pod label `azure.workload.identity/use: "true"` | non-root UID 1000, RuntimeDefault seccomp |
| Seeder | `bjjeire-seeder` | `${SEEDER_CLIENT_ID}` | WI labels on pod |
| Frontend | chart default | none | non-root UID 101, `net.ipv4.ip_unprivileged_port_start=0` (listen on 80) |
| Mongo exporter | none (`automountServiceAccountToken: false`) | none | UID 1001, drop ALL caps, read-only root |

---

## Decision rules (do / do not)

| Do | Do not |
|----|--------|
| Change env-specific sizing/flags in the **overlay** values file | Put cluster hostnames or replica counts that differ per env into `base/` HelmRelease |
| Pin chart version in overlay `OCIRepository` patch | Let base `"0.2.3"` be the production pin without an overlay override |
| Add a `ServiceEntry` before new API egress | Assume `REGISTRY_ONLY` allows arbitrary HTTPS |
| Keep NetworkPolicy HBONE **15008** when adding a new in-mesh flow | Copy a netpol that only allows the app port |
| Enroll with `istio.io/dataplane-mode: ambient` | Enable sidecar injection on `bjjeire-app` |
| Promote stg/prod images with a PR | Point `bjj-eire-image-automation` at stg/prod |
| Keep chart ingress disabled | Create an Ingress that fights Gateway HTTPRoutes |

---

## Verification

```bash
# Render (no cluster)
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01/bjj-eire
kustomize build kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01/bjj-eire
kustomize build kubernetes/apps/overlays/aks-bjjeire-prod-sdc-01/bjj-eire

# Full overlay (includes Flux KS path rewrite)
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01 >/dev/null

# Repo schema / lint
./scripts/validate.sh

# On cluster
flux get ks bjj-eire
flux get hr -n bjjeire-app
flux get sources oci -n bjjeire-app
kubectl get pods,httproute,externalsecret,netpol -n bjjeire-app
flux trace helmrelease/bjj-eire -n bjjeire-app
```

Force reconcile:

```bash
flux reconcile source git flux-system
flux reconcile ks bjj-eire --with-source
flux reconcile source oci bjj-eire -n bjjeire-app
flux reconcile hr bjj-eire -n bjjeire-app --with-source
```
