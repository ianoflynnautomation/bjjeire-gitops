#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-gitops-tools.sh  (onCreateCommand)
#
# Installs the CLIs that are not available as Dev Container Features, pinned to
# the versions CI uses. Keep these in step with:
#   .github/workflows/manifest-validation.yaml   FLUX/KUSTOMIZE/KUBECONFORM/HELM
#   .github/workflows/flux-local.yaml            flux-local image tag
#   .github/workflows/security-policy.yaml       trivy
#   kubernetes/apps/base/istio-system/*/app/ocirepository.yaml   istio
#
# scripts/validate.sh hard-requires kustomize, kubeconform, yq and yamllint —
# it exits 1 listing whatever is missing.
# ---------------------------------------------------------------------------
set -euo pipefail

FLUX_VERSION="${FLUX_VERSION:-2.8.8}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.5.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-0.6.7}"
TRIVY_VERSION="${TRIVY_VERSION:-0.70.0}"
FLUX_LOCAL_VERSION="${FLUX_LOCAL_VERSION:-8.2.0}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.3}"
YQ_VERSION="${YQ_VERSION:-4.53.3}"
UV_VERSION="${UV_VERSION:-0.12.5}"

BIN_DIR="/usr/local/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Apple Silicon hosts build arm64 containers, so nothing here may assume amd64.
case "$(uname -m)" in
  x86_64 | amd64)
    ARCH="amd64"
    TRIVY_ARCH="Linux-64bit"
    ;;
  aarch64 | arm64)
    ARCH="arm64"
    TRIVY_ARCH="Linux-ARM64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "==> Installing apt packages (yamllint, jq)"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  yamllint jq >/dev/null

if ! command -v kustomize >/dev/null 2>&1; then
  echo "==> kustomize ${KUSTOMIZE_VERSION}"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" \
    | tar xz -C "${TMP_DIR}"
  sudo install -m 0755 "${TMP_DIR}/kustomize" "${BIN_DIR}/kustomize"
fi

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "==> kubeconform ${KUBECONFORM_VERSION}"
  curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
    | tar xz -C "${TMP_DIR}"
  sudo install -m 0755 "${TMP_DIR}/kubeconform" "${BIN_DIR}/kubeconform"
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "==> yq ${YQ_VERSION}"
  curl -fsSL -o "${TMP_DIR}/yq" \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}"
  sudo install -m 0755 "${TMP_DIR}/yq" "${BIN_DIR}/yq"
fi

if ! command -v flux >/dev/null 2>&1; then
  echo "==> flux ${FLUX_VERSION}"
  curl -fsSL https://fluxcd.io/install.sh | sudo FLUX_VERSION="${FLUX_VERSION}" bash >/dev/null
fi

if ! command -v istioctl >/dev/null 2>&1; then
  echo "==> istioctl ${ISTIO_VERSION}"
  curl -fsSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-linux-${ARCH}.tar.gz" \
    | tar xz -C "${TMP_DIR}"
  sudo install -m 0755 "${TMP_DIR}/istioctl" "${BIN_DIR}/istioctl"
fi

if ! command -v trivy >/dev/null 2>&1; then
  echo "==> trivy ${TRIVY_VERSION}"
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${TRIVY_ARCH}.tar.gz" \
    | tar xz -C "${TMP_DIR}"
  sudo install -m 0755 "${TMP_DIR}/trivy" "${BIN_DIR}/trivy"
fi

if ! command -v kubelogin >/dev/null 2>&1; then
  echo "==> kubelogin (via az aks install-cli)"
  if az aks install-cli --install-location "${TMP_DIR}/kubectl-unused" \
       --kubelogin-install-location "${TMP_DIR}/kubelogin" >/dev/null 2>&1; then
    sudo install -m 0755 "${TMP_DIR}/kubelogin" "${BIN_DIR}/kubelogin"
  else
    echo "    (skipped — needs network; rerun 'az aks install-cli')"
  fi
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "==> uv ${UV_VERSION}"
  case "${ARCH}" in
    amd64) UV_TARGET="x86_64-unknown-linux-gnu" ;;
    arm64) UV_TARGET="aarch64-unknown-linux-gnu" ;;
  esac
  curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz" \
    | tar xz -C "${TMP_DIR}"
  sudo install -m 0755 "${TMP_DIR}/uv-${UV_TARGET}/uv" "${BIN_DIR}/uv"
fi

if ! command -v flux-local >/dev/null 2>&1; then
  echo "==> flux-local ${FLUX_LOCAL_VERSION}"
  sudo env \
    UV_TOOL_BIN_DIR="${BIN_DIR}" \
    UV_TOOL_DIR=/usr/local/share/uv/tools \
    UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python \
    uv tool install --quiet --python 3.13 "flux-local==${FLUX_LOCAL_VERSION}" \
    || echo "    (skipped — run it as a container instead: ghcr.io/allenporter/flux-local:v${FLUX_LOCAL_VERSION})"
fi

echo "==> Tool install complete."
