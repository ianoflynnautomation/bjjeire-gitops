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

- **Istio Service Mesh**: mTLS, traffic management, ingress/egress gateways
- **Actions Runner System**: GitHub Actions self-hosted runners with auto-scaling
- **External Secrets**: Secrets management from Azure Key Vault
- **Network System**: Certificate management (cert-manager), external DNS
- **Observability**: Monitoring and metrics collection (Prometheus, Grafana, Kiali)
- **OAuth2 Proxy**: Azure Entra ID authentication for observability tools (Istio ext-authz)
- **Flux System**: GitOps controller and source repositories

## Architecture

### Technology Stack

- **Kubernetes**: Azure Kubernetes Service (AKS)
- **Service Mesh**: Istio 1.28 with Gateway API
- **GitOps**: Flux CD v2
- **Package Management**: Helm (via HelmRepository and OCIRepository)
- **Secret Management**: External Secrets Operator with Azure Key Vault
- **Certificate Management**: cert-manager with Let's Encrypt (DNS-01 via Cloudflare)
- **DNS**: ExternalDNS with Cloudflare
- **Authentication**: Azure Workload Identity

### Repository Structure

```
kubernetes/
├── apps/
│   ├── base/                          # Reusable application configurations
│   │   ├── actions-runner-system/     # Self-hosted GitHub runners
│   │   ├── external-secrets/          # Secret synchronization
│   │   ├── flux-system/               # Source repositories
│   │   ├── istio-system/              # Istio control plane (istiod, istio-base, istio-cni)
│   │   ├── istio-ingress/             # Ingress gateway, Gateway API config
│   │   ├── istio-egress/              # Egress gateway, ServiceEntry definitions
│   │   ├── network-system/            # cert-manager, external-dns
│   │   └── observability/             # Prometheus, Grafana, HTTPRoutes
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

## Istio Service Mesh

### Overview

The cluster runs Istio 1.28 as a service mesh, providing mutual TLS encryption, traffic management, and observability across all workloads. Istio is deployed using the Kubernetes Gateway API rather than the legacy Istio Gateway resources.

### Components

| Component | Namespace | Description |
|-----------|-----------|-------------|
| istio-base | istio-system | CRDs and cluster-wide Istio resources |
| istiod | istio-system | Control plane (Pilot) - manages proxy configuration and certificate issuance |
| istio-cni | istio-system | CNI plugin for transparent traffic interception (replaces init containers) |
| Ingress Gateway | istio-ingress | Gateway API-managed deployment handling all inbound traffic |
| Egress Gateway | istio-egress | Dedicated gateway for controlled outbound traffic |

### Ingress Gateway

Inbound traffic flows through a Kubernetes Gateway API `Gateway` resource that auto-provisions its own deployment and `LoadBalancer` service in the `istio-ingress` namespace.

**Traffic flow:**

```
Internet -> Cloudflare (proxy/CDN) -> Azure LB -> Gateway Pod -> HTTPRoute -> Backend Service
```

**Gateway listeners:**

| Listener | Port | Protocol | Description |
|----------|------|----------|-------------|
| http | 80 | HTTP | Redirects all traffic to HTTPS (301) |
| https-wildcard | 443 | HTTPS | Wildcard `*.${CLUSTER_DOMAIN}` with TLS termination |
| https-root | 443 | HTTPS | Root domain `${CLUSTER_DOMAIN}` |
| https-grafana | 443 | HTTPS | `grafana.${CLUSTER_DOMAIN}` |
| https-prometheus | 443 | HTTPS | `prometheus.${CLUSTER_DOMAIN}` |
| https-kiali | 443 | HTTPS | `kiali.${CLUSTER_DOMAIN}` |
| https-oauth2 | 443 | HTTPS | `oauth2.${CLUSTER_DOMAIN}` (OIDC callback) |

TLS is terminated at the gateway using a wildcard certificate issued by cert-manager (Let's Encrypt production, DNS-01 challenge via Cloudflare).

**Azure Load Balancer integration:**

The gateway service uses `spec.infrastructure.annotations` to pass Azure-specific annotations to the auto-provisioned service:
- TCP health probes on ports 80 and 443 (avoids HTTP probe failures from hostname-based routing)
- ExternalDNS annotations for automatic Cloudflare DNS record creation

### Egress Gateway

Outbound traffic is controlled via Istio's `REGISTRY_ONLY` outbound traffic policy. All external destinations must be explicitly whitelisted using `ServiceEntry` resources.

**Whitelisted external services:**

| ServiceEntry | Hosts | Purpose |
|-------------|-------|---------|
| cloudflare-api | api.cloudflare.com | cert-manager DNS-01 challenges |
| letsencrypt-acme | acme-v02.api.letsencrypt.org | Certificate issuance |
| azure-keyvault | *.vault.azure.net | External Secrets Operator |
| azure-identity | login.microsoftonline.com, sts.windows.net | Azure Workload Identity, OAuth2 Proxy |
| microsoft-graph | graph.microsoft.com | OAuth2 Proxy group claims |
| container-registries | ghcr.io, docker.io, quay.io, registry.k8s.io | Image pulls |
| github | github.com, raw.githubusercontent.com | Flux source, Helm charts |
| grafana-cdn | grafana.com | Grafana plugin/dashboard downloads |
| external-dns-resolvers | 1.1.1.1, 8.8.8.8 | DNS resolution for cert-manager |

The egress gateway runs as a `ClusterIP` service (no external LoadBalancer) with 2-5 replicas.

### Security Policies

**mTLS:**

| Scope | Policy | Mode |
|-------|--------|------|
| Mesh-wide | `default` (istio-system) | STRICT |
| Ingress namespace | `ingress-gateway` (istio-ingress) | PERMISSIVE |

STRICT mTLS is enforced mesh-wide. The ingress namespace uses PERMISSIVE mode to allow Azure Load Balancer health probes and external traffic to reach the gateway pods.

**Authorization policies:**

Access to Grafana and Prometheus is restricted via `AuthorizationPolicy` resources that only allow traffic from:
- The ingress gateway service account (`istio-ingressgateway-istio`)
- Pods within the `observability` namespace

### Observability Routes

Application routing is defined using `HTTPRoute` resources:

| Application | Hostname | Backend | Port |
|-------------|----------|---------|------|
| Grafana | `grafana.${CLUSTER_DOMAIN}` | grafana-service (observability) | 3000 |
| Prometheus | `prometheus.${CLUSTER_DOMAIN}` | kube-prometheus-stack-prometheus (observability) | 9090 |
| Kiali | `kiali.${CLUSTER_DOMAIN}` | kiali (observability) | 20001 |

Routes include dedicated health check paths and ExternalDNS annotations for automatic DNS record management.

### Namespace Injection

Istio sidecar injection is controlled per-namespace. The CNI plugin excludes `kube-system`, `istio-system`, and `flux-system` from traffic interception. Namespaces requiring mesh membership must have the `istio-injection: enabled` label.

### Adding a New Service to the Mesh

1. Label the namespace: `kubectl label namespace <ns> istio-injection=enabled`
2. Add a `ServiceEntry` if the service needs to reach external endpoints (REGISTRY_ONLY policy)
3. Create an `HTTPRoute` in the service's namespace referencing `istio-ingressgateway` if it needs external access
4. Add an `AuthorizationPolicy` to restrict which sources can reach the service
5. Ensure the namespace has the `gateway-access: "true"` label for HTTPS route access

## Security

- **mTLS**: All mesh traffic encrypted with STRICT mutual TLS
- Secrets never committed to Git
- External Secrets Operator syncs from Azure Key Vault
- Azure Workload Identity for passwordless authentication
- Namespace isolation between application stacks
- Authorization policies restrict service-to-service communication
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
- [Istio Documentation](https://istio.io/latest/docs/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [ExternalDNS Documentation](https://kubernetes-sigs.github.io/external-dns/)
- [Kustomize Documentation](https://kustomize.io/)
- [External Secrets Operator](https://external-secrets.io/)
- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/)
