# ADR-0010: The observability stack is cost-gated per environment

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/observability/`, all three overlay resource lists

## Context

The full observability stack is kube-prometheus-stack, Grafana, Loki, Tempo,
the OpenTelemetry collector, Kiali, and oauth2-proxy. On the node pools this
platform runs (`Standard_D2ps_v6`, 1–3 nodes), that is a substantial share of
cluster capacity and the largest single line in the bill.

This is a single-maintainer platform. Running full telemetry in a development
cluster that is used interactively, by one person who can `kubectl logs`, buys
very little.

## Decision

Observability is enabled per environment, in each overlay's resource list:

| Component | dev | stg | prod |
|---|:--:|:--:|:--:|
| kube-prometheus-stack | — | ✓ | ✓ |
| Grafana | — | ✓ | ✓ |
| Loki | — | ✓ | ✓ |
| Tempo | — | ✓ | **—** |
| OpenTelemetry collector | — | ✓ | ✓ |
| Kiali | — | ✓ | — |
| oauth2-proxy | — | ✓ | ✓ |
| istio-monitoring | — | ✓ | ✓ |
| flux-instance-extras | — | ✓ | ✓ |

**Dev disables the whole stack.** Because so many components ship dashboards,
`ServiceMonitor`s, `PrometheusRule`s, and `AuthorizationPolicy`s that assume
Prometheus and Grafana exist, the dev overlay also deletes those individually
with `$patch: delete` — cert-manager's `PrometheusRule` and dashboard,
external-dns's dashboard and `serviceMonitor`, external-secrets' dashboard,
Istio's `Telemetry` and eight observability `AuthorizationPolicy` resources.
That is what most of the dev overlay's length is.

**Prod disables Tempo**, and patches the collector accordingly — dropping
`tempo` from its `dependsOn` and nulling the `otlp/tempo` exporter and its
pipeline. Without that patch the collector would wait forever on a
Kustomization that is not deployed.

## Consequences

- Dev has no metrics, no dashboards, and no traces. Debugging there is
  `kubectl logs`, `flux logs`, and `flux get`. This surprises people who expect
  Grafana to exist everywhere.
- Prod has metrics and logs but **no distributed tracing**. An OTLP trace
  exporter pointed at prod goes nowhere.
- **Enabling a component is rarely one line.** Turning observability back on in
  dev means removing the resource-list comments *and* the matching
  `$patch: delete` blocks; re-enabling Tempo in prod means reverting the
  collector patch too. The overlay comment says so at the point of the change.
- Adding a new platform component that ships a dashboard or `ServiceMonitor`
  requires a corresponding dev deletion patch, or dev reconciliation fails on a
  missing CRD.
- This is a cost decision, not an architectural one. If the budget changes, the
  correct move is to enable the stack rather than to work around its absence.

## Alternatives considered

- **Full stack everywhere.** Consistent, and makes dev a faithful rehearsal of
  prod. Rejected on cost.
- **A managed backend** (Azure Monitor / Grafana Cloud) with only agents
  in-cluster. Much lighter in the cluster and would remove most of the overlay
  patching. A real option if the self-hosted stack becomes a maintenance
  burden; rejected today to avoid another external dependency and bill.
- **Metrics only in dev, no logs or traces.** Halfway option that still carries
  the Prometheus operator's CRDs and footprint, which is the bulk of the cost.
