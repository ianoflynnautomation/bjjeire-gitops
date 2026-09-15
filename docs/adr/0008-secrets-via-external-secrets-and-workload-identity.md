# ADR-0008: Secrets come from Key Vault via External Secrets and Workload Identity

- **Status:** Accepted
- **Date:** 2026-09-09 (recorded; decision predates this record)
- **Applies to:** `kubernetes/apps/base/external-secrets/`, every `ExternalSecret` in the repo

## Context

This repository is the declared state of the cluster, so anything a workload
needs must be expressed here. Secrets are the exception that has to be solved
rather than declared: putting them in Git means either plaintext in a public
history, or an encryption scheme whose keys still have to live somewhere.

The Azure side of the platform already provisions an Azure Key Vault and a set
of user-assigned managed identities with federated credentials pointing at the
cluster's OIDC issuer.

## Decision

**No secret values in Git.** This repository declares *references*, not
material.

External Secrets Operator reconciles in three ordered stages, each its own Flux
Kustomization:

```
external-secrets → external-secrets-stores → external-secrets-cluster-secrets
```

`ExternalSecret` resources name a key in Key Vault; ESO authenticates with
**Azure Workload Identity** (no client secret) and projects the value into a
Kubernetes `Secret`. The client ID arrives through
`${WORKLOAD_IDENTITY_CLIENT_ID}`, substituted from the
`workload-identity-config` ConfigMap that the flux-bootstrap repository
creates.

Most platform components depend on one of these stages, which is why
`external-secrets-stores` appears in so many `dependsOn` lists.

## Consequences

- A public repository is safe to keep public. The worst a reader learns is
  which secret *names* exist.
- **Identity recreation breaks the chain.** If the Azure stack recreates a
  managed identity, its client ID changes; until the bootstrap repo is
  re-applied and `workload-identity-config` is refreshed, ESO fails token
  exchange and every dependent Kustomization stalls. This is the standard
  post-teardown failure and it presents as a cascade, not a single error —
  cert-manager, external-dns, cloudflare-tunnel and the app all wait on
  external-secrets.
- Debugging starts at `kubectl get externalsecret -A` and the ESO logs, not at
  the workload that is missing its Secret.
- Adding a secret is a two-repository change: create it in Key Vault (Terraform
  side), then reference it here.
- Rotation happens in Key Vault. ESO re-syncs on its refresh interval with no
  commit here.
- `*.secret.yaml` and `*.env` are gitignored as a backstop, but the real
  control is that no manifest ever contains a value.

## Alternatives considered

- **SOPS-encrypted secrets in Git.** Flux supports it natively and the platform
  even provisions a SOPS key. Rejected as the primary mechanism: it puts
  ciphertext in a public history forever, and rotation becomes a commit.
- **Sealed Secrets.** Same objection, plus a controller-held key that is
  cluster-specific and awkward across three clusters.
- **CSI Secrets Store driver.** Mounts Key Vault secrets directly into pods
  with no Kubernetes `Secret` at all — arguably stronger. Rejected because many
  platform charts expect a real `Secret` to reference.
