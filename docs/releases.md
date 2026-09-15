# Releases: Helm, OCI, and images

This repo uses a **hybrid** model: Flux owns **dev app image tags**; Renovate (and humans) own **chart versions** and promotion to stg/prod.

## Two release trains

```
BjjEire (app code)                    bjjeire-deploy (charts)
   │                                       │
   │ release tags → GHCR images            │ release tags → GHCR OCI charts
   ▼                                       ▼
ImageRepository / ImagePolicy              OCIRepository tag pins
ImageUpdateAutomation (dev only)           Renovate PRs + human promotion
   │                                       │
   └──────────────► HelmRelease values / overlay kustomization ◄─────┘
```

| What | Owner | Mechanism | Environments |
|------|--------|-----------|--------------|
| App image tags (`bjjeire-api`, `frontend`, `seeder`) | **Flux Image Automation** | `$imagepolicy` markers → commit to `main` | **dev only** |
| Umbrella + infra **OCI chart** tags | **Renovate** (+ humans) | PRs via `.github/workflows/renovate.yaml` | All envs; stg/prod need promotion review |
| GitHub Actions | **Renovate** | PRs | Repo-wide |

**Cascade rule:** bumping an **image tag** does not require bumping a **chart version**, and vice versa. Ship template/chart changes from the chart repo separately when needed.

---

## Helm charts & OCI artifacts

### How charts are consumed

1. `OCIRepository` (or `HelmRepository`) points at the chart source.
2. `HelmRelease` references that source and sets values (base + overlay patches).
3. Flux helm-controller installs/upgrades on the cluster.

Example app chart (base default; overlays override tag):

- URL: `oci://ghcr.io/ianoflynnautomation/bjj-eire`
- Pin: `spec.ref.tag` on the `OCIRepository` named `bjj-eire`
- Overlay path: `kubernetes/apps/overlays/<env>/bjj-eire/kustomization.yaml`

### Per-environment chart pins

Each cluster overlay owns its chart version. Changing **dev** does **not** change stg/prod.

To promote a chart:

1. Confirm the chart tag exists in GHCR.
2. Open a PR updating the overlay’s `OCIRepository` tag for the target env.
3. Pass CI + required review.
4. After merge, reconcile:

   ```bash
   flux reconcile source git flux-system
   flux reconcile source oci bjj-eire -n bjjeire-app
   flux reconcile hr bjj-eire -n bjjeire-app --with-source
   ```

### Renovate

- Config: root `renovate.json`
- Runner: `.github/workflows/renovate.yaml` (secret `RENOVATE_TOKEN`)
- One-time: bot PAT with Contents R/W, PRs R/W, Packages R; store as `RENOVATE_TOKEN`; run workflow once (optional dry-run)

**Do not** enable Renovate on Flux-managed app image packages or on `helmrelease-images.yaml` / `image-automation/**` — those are Flux-owned.

---

## App image updates

### Dev (automated)

- Resources live under `kubernetes/apps/base/bjj-eire/image-automation/` (enabled from the **dev** overlay).
- Dev image patch file uses setters, e.g. `helmrelease-images.yaml`:

  ```yaml
  tag: v0.1.15 # {"$imagepolicy": "bjjeire-app:bjjeire-api:tag"}
  ```

- `ImageUpdateAutomation` commits updated tags to `main` under the dev overlay path (strategy: Setters).

### Staging & production (manual promotion)

- **No** `$imagepolicy` markers in stg/prod `helmrelease-images.yaml`.
- Promote by PR: copy verified image tags from dev (or from known-good GHCR tags) into the target env file.
- Keep promotion PRs small and reversible.

### Image tag-only vs chart change

| Change type | What to edit |
|-------------|--------------|
| New app build only | Image tags (Flux in dev; PR for stg/prod) |
| New chart templates / values structure | Chart OCI tag in env overlay + any values patches |
| Both | Two coordinated changes (chart PR + image tags as needed) |

---

## Environment matrix

| Env | Images | Charts | Review |
|-----|--------|--------|--------|
| dev | Flux automation | Renovate / PR | Standard |
| stg | Human PR | Renovate / PR (`needs-promotion-review` style process) | Required |
| prod | Human PR | Renovate / PR + stricter gate | Required |

---

## Rollback

**Preferred:** `git revert` the bad commit on `main` and let Flux reconcile.

**Break-glass (example for app HelmRelease):**

```bash
flux suspend helmrelease bjj-eire -n bjjeire-app
# Fix pin/tag in Git, merge, then:
flux resume helmrelease bjj-eire -n bjjeire-app
flux reconcile hr bjj-eire -n bjjeire-app --with-source
```

Document break-glass actions in the incident notes; restore Git as source of truth ASAP.

---

## Related docs

- [Deploy](deploy.md)
- [Operations](operations.md)
- [bjj-eire.md](bjj-eire.md) — image-automation object map and overlay matrix
