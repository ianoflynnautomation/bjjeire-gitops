# syntax=docker/dockerfile:1
#
# ARC job image: upstream runner + Azure CLI.
# azure/login and `az aks get-credentials` need `az` on PATH; neither
# ghcr.io/actions/actions-runner nor home-operations/actions-runner ships it.
#
# Bump the FROM tag/digest together with the HelmRelease image tag
# (same runner version string, e.g. 2.336.0).

# renovate: datasource=docker depName=ghcr.io/home-operations/actions-runner
FROM ghcr.io/home-operations/actions-runner:2.336.0@sha256:281a9a090522fafbf4967f158b8c97d03552b1978b688893c5f7cb1944bc5fe5

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates \
      curl \
      apt-transport-https \
      lsb-release \
      gnupg \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor --yes --output /etc/apt/keyrings/microsoft.gpg \
 && chmod a+r /etc/apt/keyrings/microsoft.gpg \
 && printf '%s\n' \
      "Types: deb" \
      "URIs: https://packages.microsoft.com/repos/azure-cli/" \
      "Suites: $(lsb_release -cs)" \
      "Components: main" \
      "Architectures: $(dpkg --print-architecture)" \
      "Signed-by: /etc/apt/keyrings/microsoft.gpg" \
      > /etc/apt/sources.list.d/azure-cli.sources \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends azure-cli \
 && az version \
 && rm -rf /var/lib/apt/lists/*

USER runner
