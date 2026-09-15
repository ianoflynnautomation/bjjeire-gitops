# Documentation

| Doc | Contents |
|---|---|
| [architecture.md](architecture.md) | Stack, base/overlay model, dependency graph, mesh, variable substitution, traffic path |
| [adr/](adr/) | Architecture decision records — *why* the platform is shaped this way |
| [diagrams/](diagrams/) | `architecture.drawio.svg` — renders on GitHub, editable in draw.io |
| [bjj-eire.md](bjj-eire.md) | Long-lived app: HelmRelease, routes, secrets, netpols, image automation |
| [bjj-eire-preview.md](bjj-eire-preview.md) | Dev-only PR/SHA test factory (ResourceSet, Kyverno, ARC) |
| [deploy.md](deploy.md) | Local validation, bootstrap, applying changes |
| [releases.md](releases.md) | Helm/OCI charts, image automation, promotion, Renovate |
| [operations.md](operations.md) | Flux commands, debugging, common failures, rollback |

## Reading order

**New here:** [architecture.md](architecture.md) → [deploy.md](deploy.md) →
[releases.md](releases.md).

**Something is broken:** [operations.md](operations.md) first. If a whole
group of Kustomizations is stalled at once, start at
[ADR-0008](adr/0008-secrets-via-external-secrets-and-workload-identity.md) —
`external-secrets-stores` is the shared dependency.

**Changing the platform:** the decision table in
[architecture.md](architecture.md#why-it-is-built-this-way) routes you to the
ADR that governs what you are about to touch.

## Keeping these accurate

These pages describe the manifests in this repository, not the live cluster.
When a change alters topology, ordering, mesh posture, or which components an
environment runs, update the matching page in the same pull request — and add
an ADR if you are making a decision rather than following one.

Agent-facing conventions live in [../AGENTS.md](../AGENTS.md); constraints for
generating Flux YAML live in `../.agent/rules/core-gitops.md`.
