# Dev container

Everything needed to validate and operate this GitOps repo, pinned to the
versions CI uses. Open the repo in VS Code and pick **Reopen in Container**, or:

```sh
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . ./scripts/validate.sh
```

## What's inside

| Tool                              | Version | Pinned to match                          |
| --------------------------------- | ------- | ---------------------------------------- |
| flux                              | 2.8.8   | `manifest-validation.yaml`               |
| kubectl                           | 1.31.0  | `KUBERNETES_VERSION` (validation target) |
| helm                              | 3.17.0  | `manifest-validation.yaml`               |
| kustomize                         | 5.5.0   | `manifest-validation.yaml`               |
| kubeconform                       | 0.6.7   | `manifest-validation.yaml`               |
| flux-local                        | 8.2.0   | `flux-local.yaml` image tag              |
| trivy                             | 0.70.0  | `security-policy.yaml`                   |
| istioctl                          | 1.30.3  | istiod/ztunnel `OCIRepository` tag       |
| yq, yamllint, jq, k9s, az, kubelogin, gh | latest | —                                 |

Versions live in `install-gitops-tools.sh`. When a workflow bumps one, bump it
there too — the point of this container is that `./scripts/validate.sh` locally
and CI cannot disagree.

`docker-in-docker` is enabled so you can also run the tools CI invokes as
container images (flux-local, trivy, polaris, hadolint) byte-for-byte.

## Connecting to a cluster

The AKS clusters run with local accounts disabled, so kubectl authenticates
through **kubelogin** against Entra:

```sh
az login
az aks get-credentials -g rg-bjjeire-dev-sdc-01 -n aks-bjjeire-dev-sdc-01
kubectl get nodes
```

`AAD_LOGIN_METHOD=azurecli` is set for you, so kubelogin reuses the `az login`
token instead of prompting for a device code — no `kubelogin convert-kubeconfig`
step. Both `~/.kube` and `~/.azure` are named volumes, so credentials survive a
rebuild.

## Validating a change

```sh
./scripts/validate.sh                                        # yamllint + kustomize + kubeconform
kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01
flux-local test --all-namespaces \
  --path kubernetes/clusters/aks-bjjeire-dev-sdc-01 \
  --sources "flux-system=." --skip-invalid-kustomization-paths
```

`validate.sh` normally downloads the Flux CRD schemas to `/tmp` on every fresh
run; `post-create.sh` seeds them into the directory `FLUX_SCHEMA_LOCATION` points
at, so validation starts instantly and works offline.

## Ports

`kubectl port-forward` inside the container, browse on your host — 3000
(Grafana), 9090 (Prometheus) and 20001 (Kiali) are forwarded with labels.

## Editor

`.vscode/` is gitignored in this repo, so editor config ships here instead:
YAML at 2 spaces, Flux CRD schemas wired to `ks.yaml` / `helmrelease*.yaml` /
`ocirepository.yaml`, and the Kubernetes + GitOps extensions.
