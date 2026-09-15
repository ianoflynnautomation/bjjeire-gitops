# Flux CD Hard Engineering Rules (bjjeire-gitops)

Load this file before generating or editing Flux YAML in this repository. Stack maps live in `docs/bjj-eire.md` and `docs/bjj-eire-preview.md`. Generic Flux field indexes live in `skills/gitops-knowledge/assets/schemas/` — grep those; do not invent fields or apiVersions.

---

## 1. Never invent specs

Allowed apiVersions in this repo (verify against a sibling file if unsure):

| Kind | apiVersion |
|------|------------|
| `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart` | `source.toolkit.fluxcd.io/v1` |
| `Kustomization` (Flux) | `kustomize.toolkit.fluxcd.io/v1` |
| `HelmRelease` | `helm.toolkit.fluxcd.io/v2` |
| `ImageRepository`, `ImagePolicy`, `ImageUpdateAutomation` | `image.toolkit.fluxcd.io/v1` |
| `Receiver` | `notification.toolkit.fluxcd.io/v1` |
| `Provider`, `Alert` | `notification.toolkit.fluxcd.io/v1beta3` |
| `ResourceSet`, `ResourceSetInputProvider`, `FluxInstance` | `fluxcd.controlplane.io/v1` |
| Kustomize file | `kustomize.config.k8s.io/v1beta1` |

`OCIRepository` is **v1**, not v1beta2. `HelmRelease` is **v2**, not v2beta1/v2beta2.

If a field is not in the matching `skills/gitops-knowledge/assets/schemas/*.fields.txt` index, do not emit it.

---

## 2. Fail fast via validation

After any YAML change, before presenting it as done:

1. `kustomize build` the **cluster overlay(s)** you touched (`kubernetes/apps/overlays/aks-bjjeire-{dev,stg,prod}-sdc-01`).
2. Run `.agent/validate.sh` (wraps `scripts/validate.sh`).
3. If `flux` is installed and supports `schema validate`, run it on the changed files.

Do not `kubectl apply` Flux-owned objects. Client dry-run is syntax only.

---

## 3. Explicit namespaces, intervals, prune

Every Flux `Kustomization` (`ks.yaml` / `k8.yaml`) must set:

| Field | Rule |
|-------|------|
| `metadata.namespace` | `flux-system` |
| `spec.sourceRef` | `GitRepository/flux-system` |
| `spec.path` | explicit repo-relative path |
| `spec.interval` | explicit (see §4) |
| `spec.timeout` | explicit |
| `spec.retryInterval` | explicit (`1m` unless a sibling differs) |
| `spec.prune` | **`true`** unless the user forbids garbage collection |
| `spec.targetNamespace` | explicit when the path is namespaced |
| `spec.wait` | explicit; do not rely on default |

Every `HelmRelease` must set `metadata.namespace` to the **workload** namespace (not `flux-system`). Prefer `createNamespace: false` and create the Namespace in Git.

Every `OCIRepository` / `HelmRepository` must set `metadata.namespace` and `spec.interval`.

Substitution: when a file uses `${CLUSTER_DOMAIN}` or other cluster vars, the **Flux** Kustomization that applies it must have `postBuild.substituteFrom` for `cluster-config` (and `workload-identity-config` when WI vars are used). Both `optional: false` unless a sibling is optional.

---

## 4. Intervals (match the sibling; these are the defaults for **new** objects)

| Kind | Default in this repo |
|------|----------------------|
| Cluster `apps` Kustomization | `10m` |
| App / platform Kustomization | `30m` |
| Preview factory Kustomization | `10m` |
| External-secrets KS chain | `5m` (keep) |
| `OCIRepository` (app charts) | `5m` |
| `OCIRepository` / platform HelmRelease | `1h` common |
| App `HelmRelease` `bjj-eire` | `15m` |
| Preview generated `HelmRelease` | `5m` |
| `ImageRepository` | `5m` |
| `ImageUpdateAutomation` | `30m` |

Never `ref.tag: latest` or unpinned `branch: main` on a production OCI/Helm source. CI denies `oci://…:latest`. Overlays pin chart tags.

---

## 5. Resource organization

- Keep **Sources** (`OCIRepository`, `HelmRepository`, `GitRepository`) in `ocirepository.yaml` / `repositories/`, separate from reconcilers (`ks.yaml`, `helmrelease.yaml`).
- Flux system CRs (`Kustomization`, `ResourceSet`, `Receiver`) live in `flux-system` unless a sibling is namespaced with the workload (`OCIRepository`/`HelmRelease` for `bjj-eire` are in `bjjeire-app`).
- Overlay `kustomization.yaml` **selects** which base `ks.yaml` files a cluster runs. Enabling an app = adding that `ks.yaml` reference. Do not apply base paths by hand.

Do not overlap Flux Kustomization `spec.path` trees. One owner per object.

---

## 6. HelmRelease — copy the nearest sibling

Do not “modernize” an existing install/upgrade block to a different Flux recipe. Copy the closest `helmrelease.yaml` in the same stack.

Patterns already in this repo (all valid):

| Stack | Install / upgrade |
|-------|-------------------|
| `bjj-eire` app HR | `install.remediation.retries: 3` + `upgrade.remediation` retries `3`, `remediateLastFailure: true`, `strategy: rollback` |
| Most platform HRs | `install.strategy.name: RetryOnFailure` **and** `upgrade.remediation` rollback |
| Preview ResourceSet HR | `install`/`upgrade` `strategy.name: RetryOnFailure` only |

Also required on new app/platform HRs unless the sibling omits them:

- `driftDetection.mode: enabled` — **except** `istiod` and `istio-base` (`warn`)
- `install.crds` / `upgrade.crds`: `CreateReplace` when the chart owns CRDs
- `maxHistory` set (`3` typical; preview `2`)
- OCI charts: `spec.chartRef` to an `OCIRepository` with Helm `layerSelector` (`application/vnd.cncf.helm.chart.content.v1.tar+gzip`, `operation: copy`). Do not set both `chart` and `chartRef`.

---

## 7. Base vs overlay

- `kubernetes/apps/base/` is shared. Use `${VARIABLE}` from `cluster-config` / `workload-identity-config`. No cluster hostnames, replica counts that differ per env, or WI client IDs hardcoded in base.
- Env deltas belong in `kubernetes/apps/overlays/<cluster>/`.
- Chart version pins: overlay JSON patch on `OCIRepository.spec.ref.tag`. The cluster overlay rewrites Flux Kustomization `bjj-eire.spec.path` to that overlay directory.
- `$imagepolicy` markers + `bjj-eire-image-automation` KS: **dev overlay only**. Do not reference `image-automation/ks.yaml` from stg/prod. Do not let Renovate own `helmrelease-images.yaml`.

---

## 8. Mesh, ingress, egress (this cluster)

- Ambient only: namespace label `istio.io/dataplane-mode: ambient`. No `istio-injection` labels, no `sidecar.istio.io/inject` on workloads.
- HTTPS routes: namespace label `gateway-access: "true"`. HTTPRoute `parentRefs` → `istio-ingressgateway` in `istio-ingress`.
- AuthorizationPolicy for a new exposed service: allow principal `cluster.local/ns/istio-ingress/sa/istio-ingressgateway-istio`. L4 only (no waypoint).
- NetworkPolicy in-mesh: allow app port **and TCP 15008** (HBONE).
- New outbound host: add `ServiceEntry` under `kubernetes/apps/base/istio-egress/config/service-entries.yaml` (`REGISTRY_ONLY`).
- Azure LB probes: TCP, not HTTP/HTTPS.
- Never set cert-manager `webhook.url.host`.

---

## 9. Preview / test factory

Canonical map: `docs/bjj-eire-preview.md`.

- Reference `bjj-eire-preview/ks.yaml` **only** from `aks-bjjeire-dev-sdc-01`.
- Non-dev clusters must keep Kyverno `ClusterPolicy/deny-ephemeral-envs`. Dev is the overlay that deletes it.
- ResourceSet templates use `<< inputs.field >>`, not Helm `{{ }}` (ESO templates inside the same YAML already use `{{ }}`).
- New generated kinds: update `controller/resourceset.yaml`, ClusterRole `flux-preview`, and `sha-env/manifests.yaml` in the **same change** if that template remains.
- SHA envs: Static `ResourceSetInputProvider` labeled `bjjeire.io/sha-env=true`. Do not delete the namespace while the provider exists.
- Parent KS `bjj-eire-preview`: keep `wait: false`. ResourceSet `wait: true`.

---

## 10. YAML / naming

- Leading `---` on every YAML file
- 2-space indent
- Quote ambiguous strings (`"true"`, `"false"`, `"443"`)
- Directories and namespaces: lowercase hyphens
- Flux Kustomization / HelmRelease names match the app or chart
- Never commit secrets, tokens, or kubeconfigs

---

## 11. Anti-patterns (reject / correct)

| Anti-pattern | Correction |
|--------------|------------|
| Missing `spec.prune` on a Flux Kustomization | Set `true` |
| HelmRelease in `flux-system` for a workload | Put HR in the workload namespace |
| Overlapping Kustomization paths | One owner |
| `dependsOn` cycle | Follow the documented chain; app KS may drop `grafana` on **dev** (Grafana disabled) |
| Preview factory on stg/prod | Remove the KS reference; keep deny policy |
| Nested preview host under `${CLUSTER_DOMAIN}` | Single label under `${ROOT_DOMAIN}` + listener `https-apex-wildcard` |
| Sidecar injection on app namespaces | Ambient label only |
| `driftDetection.mode: enabled` on istiod / istio-base | `warn` |
| Renovate on Flux-owned image tags | Leave `helmrelease-images.yaml` / `image-automation/**` to Flux |

---

## 12. Execution workflow

1. **Inspect** — read this file; read the stack doc if the path is `bjj-eire` or `bjj-eire-preview`; read the target overlay `kustomization.yaml` and a sibling `ks.yaml` / `helmrelease.yaml`.
2. **Draft** — match local conventions; substituteFrom where `${VARS}` appear.
3. **Validate** — `.agent/validate.sh` and `kustomize build` of affected overlays.
4. **Respond** — YAML (or the patch), rationale tied to a rule or sibling file, and verification commands.
