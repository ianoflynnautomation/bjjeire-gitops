#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# post-create.sh  (postCreateCommand)
#
# Runs once after the container is created: claims the mounted volumes, warms
# the kubeconform schema cache, wires shell completions, and prints a version
# table so drift from CI is obvious in the creation log.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "==> Claiming mounted volumes"
for dir in "${HOME}/.kube" "${HOME}/.azure"; do
  [ -d "${dir}" ] || continue
  [ -O "${dir}" ] || sudo chown -R "$(id -u):$(id -g)" "${dir}"
done
mkdir -p "${HOME}/.kube"
chmod 700 "${HOME}/.kube"

SCHEMA_DIR="${FLUX_SCHEMA_LOCATION:-${HOME}/.cache/flux-crd-schemas/master-standalone-strict}"
if [ ! -d "${SCHEMA_DIR}" ] || [ -z "$(ls -A "${SCHEMA_DIR}" 2>/dev/null)" ]; then
  echo "==> Caching Flux CRD schemas"
  mkdir -p "${SCHEMA_DIR}"
  curl -fsSL https://github.com/fluxcd/flux2/releases/latest/download/crd-schemas.tar.gz \
    | tar zxf - -C "${SCHEMA_DIR}" \
    || echo "    (skipped — validate.sh will fetch them on first run)"
fi

COMPLETIONS_MARKER="# gitops dev container completions"
if ! grep -qF "${COMPLETIONS_MARKER}" "${HOME}/.zshrc" 2>/dev/null; then
  {
    echo ""
    echo "${COMPLETIONS_MARKER}"
    echo 'source <(kubectl completion zsh) 2>/dev/null || true'
    echo 'source <(flux completion zsh) 2>/dev/null || true'
    echo 'source <(helm completion zsh) 2>/dev/null || true'
    echo 'source <(kustomize completion zsh) 2>/dev/null || true'
    echo 'alias k=kubectl'
    echo 'compdef k=kubectl 2>/dev/null || true'
  } >> "${HOME}/.zshrc"
fi

echo ""
echo "==> Tool versions (compare against .github/workflows/*.yml)"
{
  printf '  %-12s %s\n' "flux" "$(flux version --client 2>/dev/null | awk '/flux:/{print $2}')"
  printf '  %-12s %s\n' "kubectl" "$(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{if (!s++) print $2}')"
  printf '  %-12s %s\n' "kubelogin" "$(kubelogin --version 2>/dev/null | awk -F'[ /]' '/git hash/{print $3}')"
  printf '  %-12s %s\n' "helm" "$(helm version --short 2>/dev/null)"
  printf '  %-12s %s\n' "kustomize" "$(kustomize version 2>/dev/null)"
  printf '  %-12s %s\n' "kubeconform" "$(kubeconform -v 2>/dev/null)"
  printf '  %-12s %s\n' "yq" "$(yq --version 2>/dev/null | awk '{print $NF}')"
  printf '  %-12s %s\n' "yamllint" "$(yamllint --version 2>/dev/null | awk '{print $NF}')"
  printf '  %-12s %s\n' "istioctl" "$(istioctl version --remote=false 2>/dev/null)"
  printf '  %-12s %s\n' "trivy" "$(trivy --version 2>/dev/null | awk '/Version/{if (!s++) print $2}')"
  printf '  %-12s %s\n' "flux-local" "$(UV_TOOL_DIR=/usr/local/share/uv/tools uv tool list 2>/dev/null | awk '/^flux-local /{print $2}')"
  printf '  %-12s %s\n' "az" "$(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
  printf '  %-12s %s\n' "k9s" "$(k9s version -s 2>/dev/null | awk '/Version/{print $2}')"
} || true

cat <<'EOF'

============================================================================
 BjjEire GitOps dev container is ready.

 Connect to a cluster (clusters live in kubernetes/clusters/):
   az login
   az aks get-credentials -g rg-bjjeire-dev-sdc-01 -n aks-bjjeire-dev-sdc-01
   kubectl get nodes            # kubelogin reuses the az token

 Validate before pushing — same tool versions as CI:
   ./scripts/validate.sh
   kustomize build kubernetes/apps/overlays/aks-bjjeire-dev-sdc-01
   flux-local build all         # or: flux-local diff ks --path kubernetes

 Inspect a live cluster:
   flux get ks                  # all kustomizations
   flux get hr -A               # all HelmReleases
   flux get ks | grep -v True   # find failures
   istioctl ztunnel-config workload      # ambient dataplane
   k9s

 Reconcile (always source first):
   flux reconcile source git flux-system && flux reconcile ks <name>
============================================================================
EOF
