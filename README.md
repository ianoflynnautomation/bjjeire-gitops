# GitOps FluxCD GitHub Actions Runner on AKS

A GitOps-managed GitHub Actions runner infrastructure deployed on Azure Kubernetes Service (AKS) using FluxCD. This project implements the GitHub Actions Runner Scale Set architecture with automated scaling, secret management via External Secrets Operator, and Azure Workload Identity integration.

## Overview

This repository provides a complete GitOps solution for running self-hosted GitHub Actions runners on Azure Kubernetes Service. The infrastructure is managed entirely through FluxCD, following GitOps best practices with a clear separation between base configurations and environment-specific overlays.

### Key Features

- **GitOps-driven**: All infrastructure and application configurations are version-controlled and managed through FluxCD
- **Scalable**: GitHub Actions Runner Scale Set with configurable min/max runners (currently 1-5 runners)
- **Secure**: Secrets managed via External Secrets Operator with Azure Key Vault integration
- **Azure-native**: Uses Azure Workload Identity for secure, passwordless authentication
- **Properties**: Includes drift detection, automatic remediation, and rollback capabilities
- **Multi-environment support**: Base/overlay pattern allows easy deployment across multiple AKS clusters

## Architecture

### Components

1. **GitHub Actions Runner Scale Set Controller** (`gha-runner-scale-set-controller`)
   - Manages the lifecycle of runner scale sets
   - Handles communication with GitHub's Actions service
   - Deployed via Helm chart from OCI registry

2. **GitHub Actions Runner Scale Set** (`gha-runner-scale-set`)
   - The actual runner pods that execute GitHub Actions workflows
   - Supports Docker-in-Docker (DinD) mode for containerized builds
   - Auto-scales based on job queue demand

3. **External Secrets Operator**
   - Manages secrets from Azure Key Vault
   - Uses Azure Workload Identity for authentication
   - Automatically syncs secrets to Kubernetes secrets

4. **FluxCD**
   - GitOps controller managing all Kubernetes resources
   - Handles Helm releases, Kustomizations, and source repositories
   - Provides drift detection and automatic reconciliation

### Technology Stack

- **Kubernetes**: Azure Kubernetes Service (AKS)
- **GitOps**: FluxCD v2
- **Package Management**: Helm (via HelmRepository and OCIRepository)
- **Secret Management**: External Secrets Operator
- **Authentication**: Azure Workload Identity
- **Container Registry**: GitHub Container Registry (ghcr.io)

## Project Structure

This project follows FluxCD best practices with a clear separation of concerns:

```
gitops-flux-github-runners/
├── kubernetes/
│   ├── apps/                          # Application definitions
│   │   ├── base/                      # Base configurations (reusable)
│   │   │   ├── actions-runner-system/ # GitHub Actions runner components
│   │   │   │   ├── gha-runner-scale-set-controller/
│   │   │   │   │   ├── app/           # Controller application manifests
│   │   │   │   │   │   ├── helmrelease.yaml
│   │   │   │   │   │   ├── ocirepository.yaml
│   │   │   │   │   │   └── kustomization.yaml
│   │   │   │   │   └── ks.yaml        # Flux Kustomization resource
│   │   │   │   ├── gha-runner-scale-set/
│   │   │   │   │   ├── app/           # Runner scale set application manifests
│   │   │   │   │   │   ├── helmrelease.yaml
│   │   │   │   │   │   ├── externalsecret.yaml
│   │   │   │   │   │   ├── ocirepository.yaml
│   │   │   │   │   │   └── kustomization.yaml
│   │   │   │   │   └── ks.yaml
│   │   │   │   ├── namespace.yaml
│   │   │   │   └── kustomization.yaml
│   │   │   ├── external-secrets/      # External Secrets Operator
│   │   │   │   ├── external-secrets/
│   │   │   │   │   ├── app/
│   │   │   │   │   │   ├── helmrelease.yaml
│   │   │   │   │   │   └── kustomization.yaml
│   │   │   │   │   ├── stores/        # Secret store configurations
│   │   │   │   │   │   ├── secretstore.yaml
│   │   │   │   │   │   └── kustomization.yaml
│   │   │   │   │   └── ks.yaml
│   │   │   │   ├── namespace.yaml
│   │   │   │   └── kustomization.yaml
│   │   │   └── flux-system/           # Flux source repositories
│   │   │       └── repositories/
│   │   │           ├── helm/          # Helm chart repositories
│   │   │           └── oci/            # OCI registry repositories
│   │   └── overlays/                   # Environment-specific configurations
│   │       └── aks-myaks-tst-swn-00/   # AKS cluster overlay
│   │           └── kustomization.yaml # Composes base resources
│   ├── clusters/                       # Cluster-specific configurations
│   │   └── aks-myaks-tst-swn-00/
│   │       └── ks.yaml                 # Root Kustomization for cluster
│   └── infrastructure/                 # Infrastructure components
│       ├── base/
│       └── overlays/
│           └── aks-myaks-tst-swn-00/
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE
```

### Structure Explanation

#### Base vs Overlays Pattern

- **`base/`**: Contains reusable, environment-agnostic configurations
  - Application definitions (HelmReleases, ExternalSecrets, etc.)
  - Namespace definitions
  - Source repository definitions (HelmRepository, OCIRepository)

- **`overlays/`**: Contains environment-specific customizations
  - Composes base resources using Kustomize
  - Can override values, add environment-specific resources
  - One overlay per cluster/environment

#### FluxCD Resource Types

- **`Kustomization`** (`ks.yaml`): Flux resources that reconcile Kustomize directories
- **`HelmRelease`**: Manages Helm chart installations and upgrades
- **`OCIRepository`**: References OCI-based Helm charts (e.g., from ghcr.io)
- **`HelmRepository`**: References traditional Helm chart repositories
- **`ExternalSecret`**: Defines secrets to be synced from external stores
- **`ClusterSecretStore`**: Defines the connection to Azure Key Vault

## Prerequisites

- An AKS cluster with FluxCD installed and configured
- Azure Key Vault with the GitHub PAT token stored as `gh-flux-aks-token`
- Azure Workload Identity configured with:
  - Service Account annotations for External Secrets Operator
  - Client ID: `Insert your own client id`
  - Tenant ID: `Insert your own tenant id`
- A GitHub repository with appropriate permissions for self-hosted runners
- kubectl configured to access your AKS cluster

## Configuration

### GitHub Configuration

Update the following values in `kubernetes/apps/base/actions-runner-system/gha-runner-scale-set/app/helmrelease.yaml`:

- `githubConfigUrl`: Your GitHub repository URL
- `maxRunners`: Maximum number of concurrent runners
- `minRunners`: Minimum number of runners to keep available

### Azure Key Vault

Ensure your Azure Key Vault contains:
- Secret name: `gh-flux-aks-token`
- Value: Your GitHub Personal Access Token (PAT) with `repo` and `admin:org` scopes

### Runner Resources

Current configuration in `helmrelease.yaml`:
- Memory requests: 12Gi
- Memory limits: 16Gi
- Container mode: Docker-in-Docker (DinD)
- Runner image: `ghcr.io/home-operations/actions-runner:2.330.0`

Adjust these values based on your workload requirements.

## Deployment

### Initial Setup

1. **Bootstrap FluxCD** (if not already done):
   ```bash
   flux bootstrap github \
     --owner=ianoflynnautomation \
     --repository=gitops-flux-github-runners \
     --branch=main \
     --path=./kubernetes/clusters/aks-myaks-tst-swn-00
   ```

2. **Verify FluxCD Installation**:
   ```bash
   flux check
   ```

3. **Monitor Reconciliation**:
   ```bash
   flux get kustomizations
   flux get helmreleases
   ```

### Updating Configurations

1. Make changes to the appropriate YAML files
2. Commit and push to the repository
3. FluxCD will automatically reconcile changes within the configured interval (typically 10-30 minutes)
4. Monitor reconciliation status:
   ```bash
   flux reconcile kustomization apps
   flux reconcile helmrelease -n actions-runner-system gha-runner-scale-set
   ```

## Monitoring and Troubleshooting

### Check Runner Status

```bash
# List runner pods
kubectl get pods -n actions-runner-system

# Check runner scale set status
kubectl get runnerscaleset -n actions-runner-system

# View runner logs
kubectl logs -n actions-runner-system -l app=gha-runner-scale-set
```

### Check External Secrets

```bash
# Verify ExternalSecret status
kubectl get externalsecret -n actions-runner-system

# Check secret sync status
kubectl describe externalsecret github-app-secret -n actions-runner-system

# Verify synced secret
kubectl get secret github-app-secret -n actions-runner-system
```

### FluxCD Status

```bash
# Check all Flux resources
flux get all

# View reconciliation logs
flux logs -n flux-system

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization apps
```

## Best Practices

### GitOps Principles

1. **Everything as Code**: All configurations are version-controlled
2. **Declarative**: Desired state is defined, not how to achieve it
3. **Automated**: FluxCD continuously reconciles actual state with desired state
4. **Observable**: All changes are tracked through Git commits

### Security

1. **Secrets Management**: Never commit secrets to Git; use External Secrets Operator
2. **Workload Identity**: Use Azure Workload Identity instead of service principal keys
3. **Namespace Isolation**: Separate namespaces for different components
4. **Pod Security**: Namespace-level pod security policies applied

### Resource Management

1. **Resource Limits**: Always set resource requests and limits
2. **Scaling**: Configure appropriate min/max runners based on workload
3. **Upgrades**: Use HelmRelease remediation strategies for safe upgrades
4. **Drift Detection**: Enabled on all HelmReleases to detect manual changes

### Maintenance

1. **Regular Updates**: Keep Helm charts and container images updated
2. **Backup**: Ensure Azure Key Vault backups are configured
3. **Monitoring**: Set up alerts for reconciliation failures
4. **Documentation**: Keep README and inline comments updated

## Customization

### Adding a New Environment

1. Create a new overlay directory:
   ```bash
   mkdir -p kubernetes/apps/overlays/aks-<cluster-name>
   ```

2. Create `kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../base/actions-runner-system
     - ../../base/external-secrets
     # ... other base resources
   ```

3. Add cluster-specific Kustomization in `kubernetes/clusters/`

### Modifying Runner Configuration

Edit `kubernetes/apps/base/actions-runner-system/gha-runner-scale-set/app/helmrelease.yaml` and update the `values` section as needed.

### Adding New Secrets

1. Add secret to Azure Key Vault
2. Create new `ExternalSecret` resource in the appropriate namespace
3. Reference it in your application manifests

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

## Security

For security concerns, please see [SECURITY.md](SECURITY.md).

## License

This project is licensed under the terms specified in [LICENSE](LICENSE).

## References

- [FluxCD Documentation](https://fluxcd.io/docs/)
- [GitHub Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [External Secrets Operator](https://external-secrets.io/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/)
- [Kustomize Documentation](https://kustomize.io/)
