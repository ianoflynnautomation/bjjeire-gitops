# AKS GitOps Repository

GitOps-managed Kubernetes applications for Azure Kubernetes Service (AKS) using Flux CD.

## Overview

This repository implements GitOps principles to manage all applications running on AKS clusters. Infrastructure and application configurations are version-controlled and continuously reconciled by Flux CD, ensuring declarative, auditable, and automated cluster management.

### GitOps Principles

- **Declarative**: Entire system state defined in Git
- **Versioned**: All changes tracked through Git history
- **Automated**: Flux CD continuously reconciles cluster state
- **Auditable**: Git commits provide complete audit trail
- **Self-healing**: Automatic drift detection and remediation

## Managed Applications

The repository currently manages the following application stacks:

- **Actions Runner System**: GitHub Actions self-hosted runners with auto-scaling
- **External Secrets**: Secrets management from Azure Key Vault
- **Network System**: Certificate management (cert-manager)
- **Observability**: Monitoring and metrics collection
- **Flux System**: GitOps controller and source repositories

## Architecture

### Technology Stack

- **Kubernetes**: Azure Kubernetes Service (AKS)
- **GitOps**: Flux CD v2
- **Package Management**: Helm (via HelmRepository and OCIRepository)
- **Secret Management**: External Secrets Operator with Azure Key Vault
- **Authentication**: Azure Workload Identity

### Repository Structure

```
kubernetes/
├── apps/
│   ├── base/                          # Reusable application configurations
│   │   ├── actions-runner-system/     # Self-hosted GitHub runners
│   │   ├── external-secrets/          # Secret synchronization
│   │   ├── flux-system/               # Source repositories
│   │   ├── network-system/            # Ingress and certificates
│   │   └── observability/             # Monitoring stack
│   └── overlays/                      # Environment-specific customizations
│       └── aks-myaks-tst-swn-00/      # Per-cluster configuration
├── clusters/                          # Cluster bootstrap configurations
│   └── aks-myaks-tst-swn-00/
└── infrastructure/                    # Infrastructure-level resources
    ├── base/
    └── overlays/
```

### Base and Overlay Pattern

- **base/**: Environment-agnostic configurations (HelmReleases, namespaces, sources)
- **overlays/**: Environment-specific customizations using Kustomize
- Each overlay composes base resources and applies cluster-specific values

### Flux CD Resources

- **Kustomization** (`ks.yaml`): Reconciles directories of Kubernetes manifests
- **HelmRelease**: Manages Helm chart installations and upgrades
- **HelmRepository**: References Helm chart repositories
- **OCIRepository**: References OCI-based Helm charts (ghcr.io, etc.)
- **ExternalSecret**: Syncs secrets from Azure Key Vault

## Prerequisites

- AKS cluster with Flux CD bootstrapped
- Azure Key Vault with required secrets
- Azure Workload Identity configured for secret access
- kubectl access to target cluster

## Deployment

### Bootstrap New Cluster

```bash
flux bootstrap github \
  --owner=<github-org> \
  --repository=<repo-name> \
  --branch=main \
  --path=./kubernetes/clusters/<cluster-name>
```

### Verify Installation

```bash
flux check
flux get all
```

### Monitor Reconciliation

```bash
# Check all Flux resources
flux get kustomizations
flux get helmreleases

# View logs
flux logs

# Force reconciliation
flux reconcile kustomization apps --with-source
```

## Operations

### Making Changes

1. Update YAML manifests in the repository
2. Commit and push to Git
3. Flux automatically reconciles changes (default interval: 10 minutes)
4. Optionally trigger immediate reconciliation:
   ```bash
   flux reconcile kustomization apps
   ```

### Adding New Applications

1. Create base configuration under `kubernetes/apps/base/<app-name>/`
2. Add namespace, HelmRelease, and Kustomization resources
3. Reference base resources in overlay `kustomization.yaml`
4. Commit changes to trigger deployment

### Adding New Environments

1. Create overlay directory: `kubernetes/apps/overlays/<cluster-name>/`
2. Create `kustomization.yaml` referencing required base resources
3. Add cluster directory under `kubernetes/clusters/<cluster-name>/`
4. Bootstrap Flux pointing to new cluster path

## Troubleshooting

### Check Application Status

```bash
# List resources in namespace
kubectl get all -n <namespace>

# Check Flux resource status
flux get helmrelease -n <namespace>

# View resource events
kubectl describe helmrelease <name> -n <namespace>
```

### Check Secret Synchronization

```bash
# Verify ExternalSecret status
kubectl get externalsecret -n <namespace>

# Check sync errors
kubectl describe externalsecret <name> -n <namespace>
```

### View Reconciliation Logs

```bash
# Flux system logs
flux logs -n flux-system

# Application-specific logs
kubectl logs -n flux-system deploy/kustomize-controller
kubectl logs -n flux-system deploy/helm-controller
```

## Security

- Secrets never committed to Git
- External Secrets Operator syncs from Azure Key Vault
- Azure Workload Identity for passwordless authentication
- Namespace isolation between application stacks
- All changes auditable through Git history

## Best Practices

### GitOps Workflow

- All changes flow through Git (no manual `kubectl apply`)
- Feature branches for significant changes
- Git commits provide deployment audit trail
- Flux handles reconciliation automatically

### Resource Management

- Define resource requests and limits for all workloads
- Use HelmRelease remediation strategies for safe upgrades
- Enable drift detection on critical resources
- Configure appropriate retry and timeout values

### Scalability

- Base/overlay pattern enables multi-cluster management
- Reusable base configurations reduce duplication
- Kustomize allows environment-specific overrides
- Helm values can be parameterized per environment

## References

- [Flux CD Documentation](https://fluxcd.io/docs/)
- [Kustomize Documentation](https://kustomize.io/)
- [External Secrets Operator](https://external-secrets.io/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/)
