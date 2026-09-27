# Progressive delivery (Flagger) — implementation plan

- **Status:** Proposed — **not implemented**. No Flagger objects exist in this
  repository today.
- **Date:** 2026-09-17
- **Related:** [architecture.md](architecture.md) ·
  [releases.md](releases.md) ·
  [ADR-0003](adr/0003-istio-ambient-not-sidecar.md) ·
  [ADR-0005](adr/0005-no-waypoint-l4-authorization-policies.md) ·
  [ADR-0006](adr/0006-split-release-trains-images-and-charts.md) ·
  [ADR-0010](adr/0010-observability-is-cost-gated-per-environment.md)

This is a design to sit on, not current cluster state. When you choose to
implement it, the first Git commit is a new ADR (suggested **ADR-0011**) and
the first cluster change is Flagger on **staging only**. Until then, delivery
stays Helm rolling updates plus the preview factory.

---

## Verdict (read this first)

Do **not** bolt classic Flagger + Istio `VirtualService` / `DestinationRule`
onto this cluster. Progressive delivery belongs here, but it has to sit on
**Gateway API + Istio ambient**, not sidecar-era routing.

| Do | Don't |
|---|---|
| Flagger `meshProvider: gatewayapi:v1` | Flagger `provider: istio` (VirtualService) |
| Analyse on **stg**, then **prod** | Flagger on **dev** (no Prometheus — [ADR-0010](adr/0010-observability-is-cost-gated-per-environment.md)) |
| Keep Istio installed by Flux Helm | Enable the AKS Istio add-on (fights this repo) |
| Canary `bjj-frontend` first, then `bjj-api` | Canary MongoDB or the seeder Job |
| Treat Flagger as an SLO *tripwire* | Replace Playwright / SHA preview with Flagger |
| Raise the apps node pool before prod canary | Blue/Green on a 1–3 node `Standard_D2ps_v6` pool |

Flagger is the missing **production-traffic** control loop. It is not a
replacement for: Git as the write path, image automation on dev, chart
promotion PRs, or the PR/SHA test factory.

---

## When to implement

Suggested order. Skip a phase only if its exit criteria are already true.

| Phase | What | Do it when… | Effort (order of) |
|---|---|---|---|
| **0** | ADR-0011 + this doc stays the spec | You are ready to *decide*, not yet to ship YAML | Hours |
| **1** | Capacity + metrics prerequisites | Stg Prometheus is healthy; you can spare 2–5 apps nodes | Terraform PR + small GitOps policy PR |
| **2** | Flagger controller on **stg** only | Phase 1 merged; `istio_requests_total{reporter="source"}` has data | One GitOps PR, no app Canary yet |
| **3** | Frontend Canary on stg | Flagger Ready; Git HTTPRoutes for frontend deleted in the same PR | One GitOps PR, watched soak |
| **4** | API Canary on stg | Java schema is expand/contract; frontend canary has promoted cleanly | One GitOps PR + migration review |
| **5** | Prod Canary + Teams alerts + manual gate | Stg has run several real promotions; apps pool min≥2 | Overlay PR, 90-day watched period |
| **6** | Optional: staff-cookie A/B, read-only mirror, frontend B/G | Prod canaries are boring | Later, separate ADRs if waypoint is involved |

**Do not start at Phase 3.** Helm `driftDetection` and mesh default-deny will
fight Flagger if the controller and ignore-rules are not in place first.

A reasonable calendar if this is not urgent: Phase 0 whenever you next touch
delivery docs; Phases 1–2 with the next node-pool or observability change;
Phases 3–5 after a quiet week on stg.

---

## Current estate (what this plan is grafting onto)

| Layer | What exists | Delivery today |
|---|---|---|
| Infra | AKS via Azure Verified Module, user-assigned identity, Workload Identity, OIDC, 1–3 × `Standard_D2ps_v6` apps pool (`bjjeire-terraform-azurerm-aks`) | Terraform only. **No AKS Istio add-on.** |
| Platform | Flux v2, Helm Istio **1.29 ambient**, Gateway API ingress, ESO → Key Vault, Kyverno | Git is the only write path ([ADR-0001](adr/0001-flux-reconciles-git-is-the-only-write-path.md)) |
| App | Umbrella HelmRelease `bjj-eire` (`bjj-api`, `bjj-frontend`, MongoDB, seeder) | Helm rolling update. Image automation on **dev only**. Stg/prod tags move by PR. |
| Quality | PR/SHA preview factory on **dev**; Playwright `@acceptance` on ephemeral AKS (`bjjeire-java` `ci-main.yml`) | Functional gate **before** `:main` promote. **No traffic-weighted canary.** |
| Mesh | `REGISTRY_ONLY` egress, STRICT mTLS, **no waypoint**, L4 `AuthorizationPolicy` only | Ingress is L7 (Istio Gateway). East-west is L4 (ztunnel). |
| Metrics | kube-prometheus-stack on **stg/prod**. **Dev has none** | Alertmanager off. Flux `notification-controller` present, **no Provider/Alert**. |

Traffic path that matters for canary:

```
Client → Cloudflare → (dev: tunnel / stg-prod: CF)
      → Gateway API istio-ingressgateway
      → HTTPRoute (Git today; Flagger after cutover)
      → ClusterIP Service → pods (ambient / HBONE :15008)

Frontend in-cluster → http://bjj-api.bjjeire-app.svc:8080
                      (kube L4, not HTTPRoute)
```

That last hop is why a sidecar-era “Istio canary” tutorial will lie: in-mesh
frontend→API **cannot** be weight-shifted without a waypoint
([ADR-0005](adr/0005-no-waypoint-l4-authorization-policies.md)).

---

## 1. Architecture

### Why Flagger next to Flux + Istio

1. **Git declares intent; a controller mutates traffic.** Same pattern as HPA
   writing `replicas` and cert-manager writing webhook CA bundles. Flagger is
   the mutator for *weight*, not for *desired image*.
2. **Same CD family.** CNCF graduated, OCI Helm chart on `ghcr.io/fluxcd`, no
   second control plane (Argo Rollouts / Argo CD).
3. **It analyses live traffic**, which Helm
   `upgrade.remediation.strategy: rollback` cannot. Helm rollback is “chart
   install failed,” not “p99 blew the error budget at 10% weight.”
4. **It preserves the two release trains**
   ([ADR-0006](adr/0006-split-release-trains-images-and-charts.md)): Flux still
   bumps the image (dev) or a human still bumps the overlay tag (stg/prod).
   Flagger only **gates whether that new PodSpec becomes primary**.

What Flagger is **not**: a replacement for the preview factory, Playwright, or
chart promotion PRs. Those stay.

Do **not** introduce Argo Rollouts unless you are prepared to run a second
progressive-delivery CRD family beside Flux.

### Traffic routing — use Gateway API, not VirtualService

Textbook Flagger+Istio (`provider: istio`) creates `VirtualService` +
`DestinationRule`. **Wrong provider for this repo:**

- Ingress is Gateway API `HTTPRoute`. There is not a single VS in `kubernetes/`.
- Ambient has **no sidecar Envoy**. VS/DR L7 is enforced by sidecars or
  **waypoints**. This platform deploys neither
  ([ADR-0003](adr/0003-istio-ambient-not-sidecar.md),
  [ADR-0005](adr/0005-no-waypoint-l4-authorization-policies.md)).
- Istio ambient’s own guidance: Gateway API is the L7 API.

Correct install setting: `meshProvider: gatewayapi:v1`.

```
                    Git                          Flagger (runtime)
  HelmRelease ──► Deployment/bjj-api  ──►  Deployment/bjj-api-primary  (stable)
                  HPA/bjj-api              Deployment/bjj-api          (canary)
                                           Service/bjj-api             (→ primary)
                                           Service/bjj-api-canary
                                           HTTPRoute/bjj-api
                                              backendRefs:
                                                bjj-api         weight 95
                                                bjj-api-canary  weight 5
                                         ▲
                                         │ parentRef
                                  Gateway/istio-ingressgateway   (Git, unchanged)
```

The Gateway object itself is **not** modified (TLS, listeners, TCP Azure
probes stay Git-owned).

**North-south** (browser → `api.${CLUSTER_DOMAIN}` / apex / www) **can** be
canaried today: the Istio Gateway is an L7 Envoy.

**East-west** (`bjj-frontend` → `bjj-api.bjjeire-app.svc`) **cannot**. Flagger’s
apex Service always points at **primary**. During an API canary, the SPA/BFF
keeps talking to the last good API. Accept that for v1. If product later
requires in-mesh API canary, that is a **new ADR** to deploy a waypoint for
`bjjeire-app` — do not sneak it in as a Flagger prerequisite.

### Automated rollback and analysis

Flagger’s loop (every `analysis.interval`):

1. Measure metrics against the **canary** workload.
2. If a check fails, increment `failedChecks`.
3. If `failedChecks >= threshold`, weight → 0, scale canary to 0, mark
   `Failed`. Primary is untouched.
4. If all steps pass through `maxWeight`, copy canary PodSpec → primary, wait
   for rollout, scale canary to 0.

Do **not** copy blog thresholds blindly.

| Constraint | Why it bites |
|---|---|
| Dev has no Prometheus | Analysis **cannot run** on `aks-bjjeire-dev-sdc-01`. |
| Stg API is **1 replica**, HPA 1–3 | A single 5xx in a 1m window is a large error-rate spike. |
| `RATE_LIMIT_*` is on (5–30 / 10s) | Loadtester 429s. Query **must** treat 429 as success (not 5xx). |
| Ambient / Gateway API | Built-in `request-success-rate` / `request-duration` assume sidecar `reporter="destination"`. Use `MetricTemplate` with `reporter="source"`. |
| Low QPS | 99% of ~20 req/min is one request. Always pair metrics with a **rollout webhook** load test. |
| Alertmanager is **disabled** | Page via Flagger `AlertProvider`, not kube-prometheus Alertmanager. |

Recommended SLO mapping:

| Check | Staging | Production | Notes |
|---|---|---|---|
| HTTP success (not 5xx) | ≥ 99% | ≥ 99.5% | Exclude 4xx; 429 is capacity, not a bad binary. |
| Gateway p99 | < 800ms first, then 500ms | < 500ms | 500ms at 1 replica on D2ps is tight; prove on stg. |
| p95 (optional) | < 400ms | < 300ms | Secondary; don’t rollback on p95 alone. |
| Pod healthy | required | required | Flagger built-in. |
| `threshold` (failed intervals) | 5 | 3 | Prod fails faster; stg needs room for cold JVM. |
| Min traffic | loadtester | loadtester **or** real traffic | Never analyse an idle canary. |
| Manual gate | off | **on** for first 90 days | `confirm-promotion` webhook. |

A 99.5% success floor on a **1-minute** window is a rollout tripwire, not a
monthly error budget. Keep monthly burn in Grafana; do not make Flagger the
budget accountant.

Azure Monitor: Flagger speaks Prometheus, Datadog, CloudWatch, New Relic,
Graphite — **not** Azure Monitor. Stay on kube-prometheus-stack (already
scrapes the Gateway on `http-envoy-prom` and `bjj-api` `/metrics`). If you
later move to Azure Monitor managed Prometheus, retarget
`MetricTemplate.provider.address` only.

### Canary vs Blue/Green vs shadowing

| Strategy | Flagger knobs | When enterprises use it | This platform |
|---|---|---|---|
| **Canary** (weighted) | `stepWeights` + `maxWeight` | High-QPS user-facing APIs | **Default** for API and frontend on stg/prod |
| **A/B / header** | `analysis.match` + `iterations` | Cookie / staff-user soak | Prod **staff cookie** (`canary=always`) before public weight |
| **Blue/Green** | `iterations`, no `stepWeight` | Binary cutover, sticky sessions | **Not first.** 2× pods on this node pool will Pending. Frontend later, after `max_count` is raised. |
| **Shadow / mirror** | `mirror: true` + `iterations` | New code vs production **reads** | API **GET** paths only. Mirrored POSTs duplicate Mongo writes. |

Preview namespaces already give you “full stack B/G” of an environment. Do not
Flagger those: they are ephemeral with a TTL.

---

## 2. Repository layout

You already have the split. **Do not create a fourth “platform repo.”** Add
Flagger as a base package in this GitOps repo.

```
bjjeire-terraform-azurerm-aks/            # 1. Infrastructure
  main.aks.tf                             # AKS, node pools, WI, OIDC
  environments/{dev,staging,prod}/

bjjeire-terraform-gitops-flux-bootstrap/  # cluster-config / workload-identity-config
                                          # (not this repo)

bjjeire-gitops/                           # 2. Platform + 3. App delivery
  kubernetes/clusters/<cluster>/ks.yaml
  kubernetes/apps/base/
    istio-system/                         # unchanged
    istio-ingress/                        # Gateway unchanged
    observability/                        # Prometheus (stg/prod)
    flagger/                              # NEW
      namespace.yaml
      ks.yaml
      controller/                         # HelmRelease + OCIRepository
      loadtester/
      metrics/                            # MetricTemplates
      alerts/                             # AlertProvider
    bjj-eire/
      app/                                # HelmRelease, netpol, monitors
  kubernetes/apps/overlays/
    aks-bjjeire-dev-sdc-01/               # no Flagger
    aks-bjjeire-stg-sdc-01/               # Flagger + canaries
    aks-bjjeire-prod-sdc-01/              # Flagger + stricter canaries + manual gate

bjjeire-java/                             # app CI
bjjeire-deploy/                           # umbrella chart (Deployment / HPA)
```

Ownership after Flagger:

| Object | Owner | Notes |
|---|---|---|
| AKS, identities, Key Vault, node size | Terraform | GitOps never creates Azure resources |
| Istio, Gateway, certs, ESO | Flux Git | Unchanged |
| Flagger controller, MetricTemplates | Flux Git | New `base/flagger` |
| `Deployment` PodSpec / image tag | HelmRelease | Trigger only |
| Replicas, `-primary` clone, Services, HTTPRoute weights | **Flagger** | Flux must **ignore** these |
| `Canary` CR | Flux Git | Progressive-delivery contract |
| MongoDB StatefulSet | HelmRelease | **Never** a Canary target |
| Preview / SHA envs | ResourceSet | Unchanged |

Enablement stays the overlay `resources:` list
([ADR-0002](adr/0002-kustomize-base-and-overlays-per-cluster.md)). Dev does
**not** reference the Flagger Kustomization until Prometheus exists there.

---

## 3. Manifest sketches

These follow this repo’s rules (`source.toolkit.fluxcd.io/v1`,
`helm.toolkit.fluxcd.io/v2`, `kustomize.toolkit.fluxcd.io/v1`, leading `---`,
OCI `layerSelector`, `prune: true`). Pin the Flagger chart tag in the overlay
the same way Istio/Kyverno are pinned. They are **not** in Git yet.

### 3a. Terraform — capacity, not the AKS Istio add-on

The AKS Istio add-on (`service_mesh_profile`) would install a second control
plane and fight `istio-base` / `istiod` / `ztunnel` (REGISTRY_ONLY, ambient
profile, custom `meshConfig`). Leave the mesh in GitOps.

What Terraform **should** change is headroom. A canary is a second Deployment.

```hcl
# bjjeire-terraform-azurerm-aks / main.aks.tf
# Standard_D2ps_v6 = 2 vCPU / 8Gi. Canary of API (500m/512Mi) + frontend
# on a 1-node pool will Pending. Raise floor before prod canaries.

workload_node_pools = {
  apps = {
    name                 = "apps"
    mode                 = "User"
    vm_size              = "Standard_D2ps_v6"
    auto_scaling_enabled = true
    min_count            = 2   # was 1
    max_count            = 5   # was 3
    os_disk_size_gb      = 64
    max_pods             = 110
    node_labels = {
      workload = "apps"
    }
    vnet_subnet_id = module.virtual_network.subnets["workload"].resource_id
  }
}

# Do NOT add service_mesh_profile { mode = "Istio" ... }
```

Workload Identity stays as today. Flagger needs no Azure identity.

### 3b. Flux — Flagger as a platform package

Reuse `GitRepository/flux-system`. Do **not** add a second source.

```yaml
---
# kubernetes/apps/base/flagger/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: flagger-system
  labels:
    istio.io/dataplane-mode: ambient
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

```yaml
---
# kubernetes/apps/base/flagger/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flagger
  namespace: flux-system
spec:
  interval: 30m
  retryInterval: 1m
  timeout: 10m
  prune: true
  wait: true
  path: ./kubernetes/apps/base/flagger/controller
  targetNamespace: flagger-system
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: istiod
    - name: kube-prometheus-stack
```

`dependsOn: kube-prometheus-stack` is why this must **not** be referenced from
the dev overlay until ADR-0010 changes.

```yaml
---
# kubernetes/apps/base/flagger/controller/ocirepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flagger
  namespace: flagger-system
spec:
  interval: 1h
  url: oci://ghcr.io/fluxcd/charts/flagger
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: "1.45.0"   # overlay-pin; Renovate owns this
```

```yaml
---
# kubernetes/apps/base/flagger/controller/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flagger
  namespace: flagger-system
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: flagger
  install:
    timeout: 10m
    crds: CreateReplace
    createNamespace: false
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    cleanupOnFail: true
    remediation:
      retries: 3
      remediateLastFailure: true
      strategy: rollback
  driftDetection:
    mode: enabled
  maxHistory: 3
  values:
    meshProvider: "gatewayapi:v1"
    prometheus:
      install: false
    metricsServer: http://prometheus-operated.observability.svc.cluster.local:9090
    serviceMonitor:
      enabled: true
    crd:
      create: true
    replicaCount: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
```

Enable from **stg** and **prod** overlay `resources:` only:

```yaml
# kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01/kustomization.yaml
#   - ../../base/flagger
#   - ../../base/flagger/ks.yaml
```

### 3c. MetricTemplates (ambient + Gateway API)

Built-in Istio success/latency metrics assume sidecars. Use source-reporter
templates (Flagger FAQ for Istio Gateway API):

```yaml
---
# kubernetes/apps/base/flagger/metrics/metric-templates.yaml
apiVersion: flagger.app/v1beta1
kind: MetricTemplate
metadata:
  name: gateway-error-rate
  namespace: flagger-system
spec:
  provider:
    type: prometheus
    address: http://prometheus-operated.observability.svc.cluster.local:9090
  query: |
    100 - 100 * sum(
      rate(
        istio_requests_total{
          reporter="source",
          destination_workload_namespace=~"{{ namespace }}",
          destination_workload=~"{{ target }}",
          response_code!~"5.*"
        }[{{ interval }}]
      )
    )
    /
    sum(
      rate(
        istio_requests_total{
          reporter="source",
          destination_workload_namespace=~"{{ namespace }}",
          destination_workload=~"{{ target }}"
        }[{{ interval }}]
      )
    )
---
apiVersion: flagger.app/v1beta1
kind: MetricTemplate
metadata:
  name: gateway-p99-latency
  namespace: flagger-system
spec:
  provider:
    type: prometheus
    address: http://prometheus-operated.observability.svc.cluster.local:9090
  query: |
    histogram_quantile(0.99,
      sum(
        rate(
          istio_request_duration_milliseconds_bucket{
            reporter="source",
            destination_workload_namespace=~"{{ namespace }}",
            destination_workload=~"{{ target }}"
          }[{{ interval }}]
        )
      ) by (le)
    ) / 1000
```

### 3d. Staging Canary for `bjj-api`

```yaml
---
# kubernetes/apps/overlays/aks-bjjeire-stg-sdc-01/bjj-eire/canary-api.yaml
apiVersion: flagger.app/v1beta1
kind: Canary
metadata:
  name: bjj-api
  namespace: bjjeire-app
spec:
  provider: gatewayapi:v1
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: bjj-api
  progressDeadlineSeconds: 120
  autoscalerRef:
    apiVersion: autoscaling/v2
    kind: HorizontalPodAutoscaler
    name: bjj-api
    primaryScalerReplicas:
      minReplicas: 1
      maxReplicas: 3
  service:
    name: bjj-api
    port: 8080
    targetPort: 8080
    portName: http
    hosts:
      - "api.${CLUSTER_DOMAIN}"
    gatewayRefs:
      - name: istio-ingressgateway
        namespace: istio-ingress
        group: gateway.networking.k8s.io
        kind: Gateway
  analysis:
    interval: 1m
    threshold: 5
    maxWeight: 50
    stepWeights: [5, 10, 25, 50]
    metrics:
      - name: gateway-error-rate
        templateRef:
          name: gateway-error-rate
          namespace: flagger-system
        thresholdRange:
          max: 1          # error % → success ≥ 99%
        interval: 1m
      - name: gateway-p99-latency
        templateRef:
          name: gateway-p99-latency
          namespace: flagger-system
        thresholdRange:
          max: 0.5        # seconds
        interval: 1m
    webhooks:
      - name: acceptance-smoke
        type: pre-rollout
        url: http://flagger-loadtester.flagger-system/
        timeout: 30s
        metadata:
          type: bash
          cmd: >
            curl -fsS -o /dev/null -w "%{http_code}"
            http://bjj-api-canary.bjjeire-app:8080/actuator/health/readiness
            | grep -E '200'
      - name: load-test
        type: rollout
        url: http://flagger-loadtester.flagger-system/
        timeout: 5s
        metadata:
          cmd: >
            hey -z 1m -q 5 -c 2
            -host api.${CLUSTER_DOMAIN}
            http://istio-ingressgateway-istio.istio-ingress.svc.cluster.local/
```

Prod variant: `threshold: 3`, keep `maxWeight: 50`, add a
`confirm-promotion` webhook for the first 90 days.

Frontend Canary is the same shape with `port: 80` and hosts
`[${CLUSTER_DOMAIN}, www.${CLUSTER_DOMAIN}]`. Run **one workload at a time**
on this node pool.

### 3e. HelmRelease must stop fighting Flagger

```yaml
# patch on HelmRelease/bjj-eire (stg/prod overlay)
spec:
  driftDetection:
    mode: enabled
    ignore:
      - paths: ["/spec/replicas"]
        target:
          kind: Deployment
      - paths: ["/spec/selector", "/spec/replicas"]
        target:
          kind: HorizontalPodAutoscaler
      - paths: ["/spec/selector"]
        target:
          kind: Service
          name: bjj-api
      - paths: ["/spec/selector"]
        target:
          kind: Service
          name: bjj-frontend
      - paths: ["/spec/rules"]
        target:
          kind: HTTPRoute
```

**Remove or `$patch: delete` the Git `HTTPRoute`s for canaried hosts** in the
same PR that adds the Canary. Two HTTPRoutes for `api.${CLUSTER_DOMAIN}` (Git
+ Flagger) will double-bind on the Gateway. After cutover, Flagger owns those
routes.

Keep the existing `Gateway` in Git. Flagger does not edit it.

### 3f. What Flagger writes at runtime (do not commit)

During a 10% step the live HTTPRoute looks like:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bjj-api
  namespace: bjjeire-app
spec:
  parentRefs:
    - name: istio-ingressgateway
      namespace: istio-ingress
  hostnames:
    - api.stg.bjjeire.com
  rules:
    - backendRefs:
        - name: bjj-api
          port: 8080
          weight: 90
        - name: bjj-api-canary
          port: 8080
          weight: 10
```

A `VirtualService` + `DestinationRule` pair is what `provider: istio` would
write. Those objects would be accepted by the API server and **would not split
ingress traffic** on ambient without a waypoint — the same silent-no-op class
as L7 `AuthorizationPolicy` (ADR-0005). Do not apply them.

---

## 4. Enterprise practices

### Drift: Terraform vs Flux vs Flagger

| Plane | Source of truth | Drift policy |
|---|---|---|
| Azure (AKS, KV, identities, DNS, tunnel) | Terraform state | `terraform plan` in CI |
| Cluster desired spec | Git (`bjjeire-gitops`) | HelmRelease `driftDetection.mode: enabled`, except istiod/istio-base `warn` |
| Traffic weight / primary clone | Flagger status | **Not in Git.** Ignore those fields on the HelmRelease |

One owner per object. If someone `kubectl apply`s an HTTPRoute weight, Flagger
overwrites it on the next tick; Flux may overwrite Flagger if the static
HTTPRoute stays in Git.

Break-glass: `flux suspend ks bjj-eire` then
`flux suspend helmrelease bjj-eire -n bjjeire-app`. Mid-canary freeze: suspend
the Flagger HelmRelease; weights stay where they are.

### Database schema during canary

MongoDB is a **StatefulSet in the same namespace**, shared by primary and
canary.

1. **Expand:** schema-additive changes in release N. Old API ignores unknown
   fields.
2. **Dual-write / dual-read** on renames. Never rename in place while two
   binaries run.
3. **Canary N+1** against the expanded schema. Rollback is then safe.
4. **Contract:** remove old fields only in N+2, after primary is N+1 on stg
   **and** prod.
5. **Seeder:** keep `hookPolicy: post-install` (already). A `post-upgrade`
   seeder with `force: true` during canary mutates data from a Job racing two
   APIs. Dev may keep `force: true`; stg/prod must not.
6. **Never Canary the MongoDB chart.** Restore is the rollback, not Flagger.

If a release needs a breaking migration, **do not canary**. Feature-flag it
off or use a maintenance window.

Frontend canary is easier (no DB). Start there.

### Secrets

Keep [ADR-0008](adr/0008-secrets-via-external-secrets-and-workload-identity.md).
Do not introduce SOPS as the primary path.

- Flagger `AlertProvider` webhook URL: `ExternalSecret` → Key Vault.
- Flagger webhooks stay **cheap** (`/actuator/health/readiness`, a public GET).
  Full Playwright stays on the SHA env.
- Flagger tracks Secret/ConfigMap changes on the target Deployment. Annotate
  secrets that must **not** trigger a rollout (e.g. Mongo password rotation).

### Observability and alerting

Today a failed reconcile pages **nobody**. Use Flagger’s `AlertProvider` for
canary phase changes; add Flux `Provider`/`Alert` later for HelmRelease
failures.

```yaml
---
apiVersion: flagger.app/v1beta1
kind: AlertProvider
metadata:
  name: msteams
  namespace: flagger-system
spec:
  type: msteams
  secretRef:
    name: flagger-msteams-webhook
```

Scrape Flagger (`serviceMonitor.enabled: true`) and add a Grafana row: canary
weight, failed checks, phase.

### Mesh / NetworkPolicy holes (easy to miss)

Mesh-wide `default-deny` plus `allow-ingress-to-bjjeire-app` (ingress SA only)
plus `allow-bjjeire-app-internal` **will deny** `flagger-loadtester` in
`flagger-system`. Add, in the same PR as the controller:

- `AuthorizationPolicy` allow from namespace `flagger-system` to `bjjeire-app`
  (L4, ports 8080 / 80 / **15008**).
- Allow `flagger-system` to query Prometheus (today: ingress SA +
  `observability` only).
- `NetworkPolicy` in `bjjeire-app` allowing from `flagger-system` (default-deny
  is already on).

Without those, analysis webhooks fail closed and every canary rolls back.

---

## 5. Gap analysis

### Already in good shape

- Three-layer GitOps with `prune: true`.
- Ambient mesh with a documented L4 policy model.
- Split release trains: images auto on dev, charts and stg/prod tags via PR.
- Preview/SHA factory + Playwright **before** `:main` promote.
- ESO + Workload Identity; no secrets in Git.
- HelmRelease rollback + drift detection on the app.
- Gateway TCP probes, REGISTRY_ONLY egress, Kyverno hostname restrictions.

### Gaps, ordered

| Sev | Gap | Why it matters | Fix (phase) |
|---|---|---|---|
| **P0** | No progressive delivery; Helm rolling update = 100% as soon as pods Ready | A bad image on stg/prod is a full blast | Flagger canaries (3–5) |
| **P0** | Helm `driftDetection.mode: enabled` with **no** ignore for replicas / selectors / HTTPRoute | Flagger and helm-controller oscillate | Ignore list (3) |
| **P0** | Dev has no Prometheus | Cannot analyse on the auto-deploy cluster | **Do not Flagger dev** (0) |
| **P0** | Apps pool `min_count = 1`, `max_count = 3`, D2ps_v6 | Canary doubles footprint; B/G is worse | Terraform min 2 / max 5 (1) |
| **P1** | Built-in Istio metrics assume sidecars | Empty series → false pass or false fail | MetricTemplates (2) |
| **P1** | Mesh default-deny + netpol block loadtester and Flagger→Prometheus | Every canary fails analysis | Extra L4 policies (1–2) |
| **P1** | No paging on canary fail | Failures are silent | Flagger `AlertProvider` (5) |
| **P1** | Two Git HTTPRoutes for frontend (apex + www) | Flagger wants one Canary / one HTTPRoute | One Canary, two hosts; delete Git routes (3) |
| **P1** | In-mesh frontend→API always hits **primary** | API canary does not exercise the SPA path | Accept for v1; waypoint ADR only if required |
| **P2** | `upgrade.remediation.strategy: rollback` on the app HR | Helm may rollback the chart while Flagger analyses | Keep Helm rollback for *chart* failure; test on stg (4) |
| **P2** | Seeder / Mongo in the same HelmRelease as API | A values bump can change Mongo during an API canary | Never Canary Mongo; freeze seeder on stg/prod upgrades (4) |
| **P2** | Rate limits + loadtester | 429s and p99 inflation | Cap hey at `q 5 -c 2`; exclude 4xx (3–4) |
| **P2** | Prod HPA max 10 on a tiny pool | Canary + HPA scale-up can evict mesh | `primaryScalerReplicas` caps + pool max (1, 5) |
| **P3** | Alertmanager disabled | No Prom-side canary burn alerts | Optional; Flagger alerts are enough |
| **P3** | AKS Istio add-on not used | **Correct.** Do not “fix” this | Keep Helm Istio |

### What not to change

- Do not add `istio-injection` or sidecars to make a tutorial work.
- Do not deploy a waypoint just to unlock VirtualServices.
- Do not put `$imagepolicy` on stg/prod so Flagger “has something to do.”
  Promotion stays a PR; Flagger runs **after** merge when HelmRelease updates
  the Deployment.
- Do not Flagger preview namespaces.
- Do not canary MongoDB or the seeder Job.

---

## Implementation checklist

Copy into the implementing PR. Tick in order.

**Phase 0 — decide**

- [ ] Accept this plan (or amend it) and write **ADR-0011**: Flagger Gateway
      API, stg/prod only; ambient unchanged; no waypoint; reject VS provider
      and AKS Istio add-on.
- [ ] Link ADR-0011 from [adr/README.md](adr/README.md) and
      [AGENTS.md](../AGENTS.md).
- [ ] Flip this page’s status from Proposed to Accepted (or point at the ADR).

**Phase 1 — capacity and metrics**

- [ ] Terraform: apps pool `min_count = 2`, `max_count = 5` (stg first, then
      prod).
- [ ] Confirm on stg:
      `istio_requests_total{reporter="source"}` is non-empty for the Gateway.
- [ ] AuthorizationPolicy + NetworkPolicy holes for `flagger-system`
      (bjjeire-app + Prometheus, ports including 15008).

**Phase 2 — controller on staging**

- [ ] `kubernetes/apps/base/flagger/` (namespace, ks, OCIRepository,
      HelmRelease, MetricTemplates, loadtester).
- [ ] Reference from **stg** overlay only.
- [ ] `kustomize build` that overlay + `.agent/validate.sh`.
- [ ] `flux get hr flagger -n flagger-system` Ready.

**Phase 3 — frontend canary on staging**

- [ ] HelmRelease `driftDetection.ignore` for Deployment/HPA/Service/HTTPRoute.
- [ ] Delete Git HTTPRoutes `bjj-frontend-root` and `bjj-frontend-www` in the
      **same** PR as the Canary.
- [ ] Canary CR for `bjj-frontend`.
- [ ] Trigger via a stg image-tag PR; watch `kubectl get canary -n bjjeire-app -w`.
- [ ] Confirm rollback by forcing 5xx against the canary (once).

**Phase 4 — API canary on staging**

- [ ] Review Java migrations for expand/contract.
- [ ] Confirm seeder is not `post-upgrade` / `force: true` on stg.
- [ ] Canary CR for `bjj-api`; delete Git `HTTPRoute/bjj-api` in the same PR.
- [ ] Loadtester QPS under the rate limit.
- [ ] Confirm in-mesh frontend→API still hits primary (expected).

**Phase 5 — production**

- [ ] Same controller package referenced from the prod overlay.
- [ ] Stricter Canary (`threshold: 3`, confirm-promotion webhook).
- [ ] Teams `AlertProvider` via ExternalSecret.
- [ ] First five prod canaries are watched, not set-and-forget.

**Phase 6 — later, optional**

- [ ] Staff-cookie A/B (`canary=always`).
- [ ] Read-only mirroring for selected GETs.
- [ ] Frontend blue/green only after the node pool holds 3+ Ready nodes.
- [ ] Waypoint for `bjjeire-app` **only** with a new ADR, if in-mesh API
      canary becomes a product requirement.

---

## References

- Flagger Gateway API tutorial: <https://docs.flagger.app/tutorials/gatewayapi-progressive-delivery>
- Flagger Flux install (OCI): <https://docs.flagger.app/install/flagger-install-with-flux>
- Flagger FAQ — Istio Gateway API metrics need `reporter="source"`
- Istio ambient traffic management: Gateway API, not VirtualService
