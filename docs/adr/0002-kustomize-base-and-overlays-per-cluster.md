# ADR-0002: Kustomize base + per-cluster overlays on a single branch

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/`, `kubernetes/apps/overlays/`, `kubernetes/clusters/`

## Context

Three clusters run the same platform with real differences: dev has no
observability stack and no public load balancer, prod has no Tempo and no
self-hosted runners, only dev has preview environments and image automation.

Those differences have to live somewhere. The options are branches per
environment, directories per environment with duplicated manifests, or one set
of manifests with per-environment composition.

## Decision

Three layers, one branch (`main`):

| Layer | Path | Role |
|---|---|---|
| **base** | `kubernetes/apps/base/<package>/` | Environment-agnostic manifests. Prefer `${VARIABLE}` substitution over hardcoded cluster values. |
| **overlay** | `kubernetes/apps/overlays/<cluster>/` | Chooses which base packages are enabled, and patches paths, chart tags, image tags, and Helm values. |
| **cluster** | `kubernetes/clusters/<cluster>/ks.yaml` | Flux entrypoint: one `apps` Kustomization pointing at the overlay, with `postBuild.substituteFrom`. |

**Enablement is the overlay's `resources` list.** A component is turned off by
commenting out its `ks.yaml` entry — which is why those files carry inline
comments explaining *why* something is off (`# Observability stack disabled in
dev for cost.`).

Overlays also patch *into* Flux Kustomizations, so an environment can delete an
individual resource from a base package without forking it — dev deletes the
`deny-ephemeral-envs` ClusterPolicy and every observability
`AuthorizationPolicy` this way.

## Consequences

- Adding a platform component means one base package plus a line in each
  overlay that should run it. Forgetting the overlay line is the most common
  reason "I added it but it never appeared".
- **Environment differences are only visible by diffing overlays.** When dev
  works and prod does not, diff the two overlay `kustomization.yaml` files
  first — and remember that a third repository
  (`bjjeire-terraform-gitops-flux-bootstrap`) supplies the substitution
  ConfigMaps, so a missing `${VARIABLE}` is often a bootstrap gap, not a gap
  here.
- Deleting a resource via an overlay patch (`$patch: delete`) is invisible from
  the base package. Anyone reading `base/` alone will believe a policy is
  active on dev when it is not.
- A single branch means no cherry-picking between environments and no
  long-lived divergence. Promotion is a pull request that edits an overlay.
- Base manifests must not hardcode cluster-specific values when a substitution
  variable exists — see the variable table in
  [../architecture.md](../architecture.md#variable-substitution).

## Alternatives considered

- **Branch per environment** (`dev`, `stg`, `prod`). Familiar, but promotion
  becomes a merge with conflicts, and drift between branches is invisible until
  someone diffs them. Widely regarded as a GitOps anti-pattern.
- **Duplicated directories per environment.** No abstraction to learn, but a
  platform change must be applied three times and will eventually be applied
  twice.
- **Helm umbrella chart for the whole platform.** Values files replace
  overlays, but conditional enablement of ~25 components turns into deeply
  nested `if` blocks, and Flux loses the per-package `dependsOn` ordering that
  the current split provides.
