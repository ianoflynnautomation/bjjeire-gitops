# ARC actions-runner image

`ghcr.io/ianoflynnautomation/actions-runner` — `home-operations/actions-runner` plus Azure CLI (`az`), which `azure/login` requires.

## Bump the base runner

1. Update the `FROM` line in `Dockerfile` (tag + digest).
2. Merge to `main` — `.github/workflows/publish-actions-runner.yml` builds and pushes `:<runner-version>`, `:sha-<short>`, and `:latest`.
3. Set the same `:<runner-version>` tag on the three HelmReleases under `kubernetes/apps/base/actions-runner-system/gha-runner-scale-set/app/`.

The first publish must finish before Flux can pull the image (expect `ImagePullBackOff` if the HelmReleases land first).
