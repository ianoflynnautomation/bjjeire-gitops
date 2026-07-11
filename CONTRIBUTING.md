# Contributing

Thanks for helping improve the BJJ Éire GitOps repository. This repo is the **declarative source of truth** for AKS workloads managed by **Flux CD** — not an imperative runbook.

## Workflow

1. Create a feature branch from `main`.
2. Make changes under `kubernetes/` (and docs when behavior or onboarding changes).
3. Validate locally:
   - `kustomize build kubernetes/apps/overlays/<cluster>`
   - `./scripts/validate.sh` when possible
4. Open a Pull Request using the template; ensure CI is green.
5. Request review — **required for staging and production promotions**.
6. After merge, Flux reconciles. Force if needed:

   ```bash
   flux reconcile source git flux-system && flux reconcile ks apps --with-source
   ```

## Style

- YAML: leading `---`, 2-space indent, quote ambiguous strings (`"true"`, `"443"`).
- Prefer env-specific behavior in **overlays**; keep **base** reusable.
- Use Flux substitution variables (`${CLUSTER_DOMAIN}`, etc.) instead of hardcoding cluster values in `base/`.
- Flux Kustomization / HelmRelease names should match the app or chart name.
- Directories and namespaces: lowercase with hyphens.
- Namespace for namespaced resources usually belongs on the Flux Kustomization `targetNamespace` / Kustomize `namespace`, not scattered inconsistently.

## Commits

- Prefer clear, conventional messages (e.g. `feat(bjj-eire): …`, `fix(istio): …`, `chore(deps): …`).
- Group related GitOps changes in one commit/PR when they must land together.
- **Never commit secrets**, tokens, or kubeconfigs.

## Releases & automation

- **App images (dev):** Flux Image Automation owns tags — do not fight it with Renovate.
- **Charts / Actions:** Renovate opens PRs; humans promote stg/prod.
- Do not add `$imagepolicy` markers to stg/prod image overlays.
- See [docs/releases.md](docs/releases.md).

## Security

- Report vulnerabilities via [SECURITY.md](SECURITY.md).
- Secrets live in Azure Key Vault and flow through External Secrets Operator.

## Ownership & contact

| Area | Contact |
|------|---------|
| Default code owner | [@ianoflynn](https://github.com/ianoflynn) — see [CODEOWNERS](.github/CODEOWNERS) |
| Infrastructure / AKS / Flux bootstrap / mesh policy | **@ianoflynn** before large or prod-impacting changes |
| Application chart source (`bjjeire-deploy`) / app code | Coordinate with app owners; this repo only pins versions and values |

Questions about whether a change belongs in **base** vs **overlay**, or needs a promotion PR, can go to the same owner.
