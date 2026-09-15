# ADR-0006: Two release trains — Flux image automation for images, Renovate for charts

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/bjj-eire/image-automation/`, `renovate.json`, overlay `helmrelease-images.yaml`

## Context

Two kinds of dependency change at very different rates and carry very different
risk:

- **Application images** (`bjjeire-api`, `bjjeire-frontend`, `bjjeire-seeder`)
  are built from our own code, many times a day, and are the thing a developer
  wants to see running immediately.
- **Platform chart versions** (Istio, cert-manager, Kyverno, the umbrella
  `bjj-eire` chart) change occasionally, are written by other people, and can
  restructure a cluster.

Treating both with one mechanism means either humans approving every image
build, or a bot silently upgrading Istio.

## Decision

**Application images — Flux image automation, dev only.**
`ImageRepository` → `ImagePolicy` → `ImageUpdateAutomation` scans GHCR and
commits new tags back to this repository. The `$imagepolicy` markers exist
**only** in `apps/overlays/aks-bjjeire-dev-sdc-01/bjj-eire/helmrelease-images.yaml`.
Staging and prod carry the same file without markers — their tags move only
through a promotion pull request.

**Chart versions — Renovate.** `renovate.json` raises pull requests for
`OCIRepository` tags, `HelmRelease` chart versions, and GitHub Actions. Nothing
auto-merges.

## Consequences

- Dev tracks `main` automatically: merge to the app repo, and the dev cluster
  has it minutes later without touching this repository by hand.
- **Promotion is deliberate.** Staging and prod are always behind dev by an
  explicit, reviewable commit. There is no "it went to prod on its own".
- Flux commits to `main` here. Expect `chore(flux): update bjj-eire image tags
  (aks-bjjeire-dev-sdc-01)` commits authored by the automation, and rebase
  before pushing.
- **Adding an `$imagepolicy` marker to a staging or prod overlay silently
  converts that environment to continuous deployment.** The marker is a
  comment; nothing rejects it, and the first sign is prod moving on its own.
- Two mechanisms mean two places to look when something is on an unexpected
  version: `flux get image policy -A` for images, the Renovate dashboard issue
  for charts.

## Alternatives considered

- **Image automation in every environment.** Simple and consistent, and removes
  the human gate in front of production. Rejected.
- **Renovate for images too.** Would unify the tooling, but adds a pull-request
  round trip to every dev deploy, which is the loop this is optimising.
- **Manual tag edits everywhere.** What the automation replaced; reliably
  produced stale dev environments.
