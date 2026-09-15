# ADR-0001: Flux CD v2 reconciles; Git is the only write path

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** the whole repository

## Context

Cluster state can be changed three ways: `kubectl apply`, Helm from a laptop,
or a controller reconciling a declared source. The first two leave no audit
trail, cannot be reviewed before they land, and drift silently from whatever is
written down.

Three clusters (`dev`, `stg`, `prod`) run the same platform, operated by one
person. Reproducing a cluster after a teardown has to be a mechanical
operation, not an act of recall.

## Decision

Flux CD v2 continuously reconciles this repository. Every cluster has a single
Flux `Kustomization` named `apps` in
`kubernetes/clusters/<cluster>/ks.yaml`, pointing at that cluster's overlay
with `prune: true` and a 10-minute interval.

**Git is the only supported write path.** Changing the cluster means a commit,
a pull request, a merge, and a reconcile. `kubectl apply` against a
Flux-managed resource is not a shortcut — it is drift that Flux will revert on
the next interval.

`prune: true` means deleting a resource from Git deletes it from the cluster.

## Consequences

- Every change is reviewable and revertible with `git revert`. The cluster's
  history is the repository's history.
- Debugging starts with `flux get ks`, `flux get hr -A`, and
  `flux logs --level=error` — not with `kubectl get` on a live object, which
  shows what Flux last applied rather than what was intended.
- **Manual `kubectl apply` produces confusing symptoms**: the change works,
  then silently disappears up to 10 minutes later. If you must intervene by
  hand, `flux suspend ks <name>` first and remember to `flux resume`.
- Emergency changes are slower than typing a command. That is the trade the
  audit trail buys.
- Because `prune: true` is set, removing a resource from an overlay's resource
  list is a *deletion*, not a no-op. Comment-outs in overlay `kustomization.yaml`
  files are how components are disabled, and they take effect immediately.

## Alternatives considered

- **Argo CD.** Comparable capability. Flux was chosen for its Kustomize-native
  model, `dependsOn` ordering, and first-class OCI Helm chart support, which
  match how this platform is packaged.
- **CI-driven `kubectl apply` / `helm upgrade` from GitHub Actions.** Needs
  standing cluster credentials in CI and gives pull-based reconciliation
  nothing to converge on. Rejected.
- **`prune: false`.** Would make deletions manual and leave orphans behind
  after a component is removed from an overlay.
