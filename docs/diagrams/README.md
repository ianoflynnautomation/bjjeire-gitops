# Diagrams

## `architecture.drawio.svg`

The full platform topology. It is a **dual-format file**: a plain SVG that
GitHub renders inline anywhere it is referenced, carrying the draw.io model in
the root element's `content` attribute so the same file reopens as a fully
editable diagram.

It reads left to right as the **reconciliation flow** — sources → Flux →
platform services → mesh → workloads. The **request path** is a separate strip
along the bottom, because live traffic runs orthogonally to reconciliation and
drawing both in one graph makes neither readable.

**To edit:**

- **VS Code** — install the *Draw.io Integration* extension and open the file;
  it opens as a canvas, not as markup. Saving writes both the picture and the
  model back.
- **Browser** — open [diagrams.net](https://app.diagrams.net/), then
  *File → Open from → Device*. Export with *File → Export as → SVG* and
  **"Include a copy of my diagram"** ticked, or the file stops being editable.

Keep the `.drawio.svg` extension — it is what signals the editable-SVG format
to both tools.

## Conventions

| Element | Meaning |
|---|---|
| Solid blue edge | Flux reconciles this |
| Dotted grey edge | `dependsOn` ordering |
| Dashed amber edge | Key Vault → Kubernetes Secret via ESO |
| Dashed purple edge | Automated commit or ephemeral-env factory |
| Solid green edge | Live request path |
| Dashed amber box | Dev-only — not deployed to staging or prod |

## Scope

The diagram shows the union of all three environments, with dev-only components
marked. Per-environment enablement lives in each overlay's `resources` list;
the differences are summarised in
[ADR-0010](../adr/0010-observability-is-cost-gated-per-environment.md) and
[ADR-0007](../adr/0007-preview-environments-are-dev-only.md).

The lighter Mermaid diagrams in [../architecture.md](../architecture.md) are
the ones to update for small changes — they render everywhere and cost nothing
to edit. Reach for this file when the change is structural.
