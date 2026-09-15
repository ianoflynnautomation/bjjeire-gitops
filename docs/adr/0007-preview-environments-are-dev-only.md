# ADR-0007: Preview environments exist on dev only, enforced by Kyverno

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/bjj-eire-preview/`, `kubernetes/apps/base/kyverno/policies/`

## Context

Pull requests in the application repository get an ephemeral environment: a
namespace per PR (`pr-<id>`) or per commit SHA, created by a Flux `ResourceSet`
factory driven by a `ResourceSetInputProvider`, and reconciled immediately via
a `Receiver` fed by a GitHub webhook.

That factory can create namespaces and workloads from input it derives from a
pull request — including pull requests from people who are not maintainers. A
production cluster is not a place for that.

## Decision

The preview factory is referenced **only** from the dev overlay
(`apps/overlays/aks-bjjeire-dev-sdc-01/kustomization.yaml`). Staging and prod
never include `bjj-eire-preview/ks.yaml`.

Omission alone is not the control. A Kyverno `ClusterPolicy`,
`deny-ephemeral-envs`, rejects ephemeral namespaces and SHA input providers
outright. It ships in the base Kyverno policy set, so it is active by default
in every environment — and the **dev overlay deletes it** with a
`$patch: delete`, which is the only place preview environments become possible.

Supporting policies:

- `restrict-hostnames-by-env` — keeps preview hostnames inside the dev domain.
- `ephemeral-env-cleanup` and the cleanup-controller RBAC — reap namespaces on
  TTL so abandoned PRs do not accumulate.

## Consequences

- The control is **default-deny with an explicit dev exception**, not
  default-allow with dev opt-in. Adding the factory to a staging or prod
  overlay is not enough to make it work — Kyverno still rejects the namespaces,
  which is the intended outcome.
- Reversing this needs two separate mistakes in two files. That is deliberate.
- **The policy is invisible from `base/`.** Reading
  `kyverno/policies/deny-ephemeral-envs.yaml` suggests it is enforced
  everywhere; only the dev overlay's patch reveals otherwise. See
  [ADR-0002](0002-kustomize-base-and-overlays-per-cluster.md).
- Preview environments are consequently a dev-cluster capability that the app
  and tests repositories can rely on only there. The Azure side matches: the
  `gha_pr_env` identity that drives them exists only on dev, and it is the only
  identity in the platform federated to a `pull_request` subject.
- Self-hosted ARC runners are also dev-only, so in-cluster Playwright runs
  against preview environments happen on dev by construction.

## Alternatives considered

- **Preview environments on staging.** More production-like test targets, at
  the cost of putting PR-derived workloads next to release-candidate state.
  Rejected.
- **A separate ephemeral cluster.** Cleanest isolation, and the honest answer
  if previews ever need to be production-like. Rejected on cost for a
  single-maintainer platform.
- **Omission from overlays without the Kyverno policy.** One forgotten
  comment-out away from running previews in prod.
