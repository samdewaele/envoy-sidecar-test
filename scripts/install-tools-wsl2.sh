#!/usr/bin/env bash
# =============================================================================
# install-tools-wsl2.sh
#
# Installs kind, kubectl, helm, helmfile, and openssl on Ubuntu/Debian WSL2.
#
# Docker is NOT installed by this script — on Windows, install Docker Desktop
# and enable WSL2 integration for your distro (Settings → Resources → WSL
# Integration).  The docker command then works inside WSL2 automatically.
#
# Usage:
#   chmod +x scripts/install-tools-wsl2.sh
#   ./scripts/install-tools-wsl2.sh
# =============================================================================
set -euo pipefail

KUBECTL_VERSION="v1.29"
KIND_VERSION="v0.23.0"
HELMFILE_VERSION="0.162.0"

ARCH=$(dpkg --print-architecture)   # amd64 or arm64
BIN=/usr/local/bin

echo "▶  Updating apt"
sudo apt-get update -q

# ── openssl ───────────────────────────────────────────────────────────────────
echo "▶  Installing openssl"
sudo apt-get install -y -q openssl curl ca-certificates gnupg

# ── kubectl ───────────────────────────────────────────────────────────────────
# Not in the default Ubuntu repo — needs Kubernetes' own apt source.
echo "▶  Installing kubectl ${KUBECTL_VERSION}"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${KUBECTL_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
sudo apt-get update -q
sudo apt-get install -y -q kubectl

# ── helm ──────────────────────────────────────────────────────────────────────
# Official Helm install script — handles arch + latest release automatically.
echo "▶  Installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── kind ──────────────────────────────────────────────────────────────────────
echo "▶  Installing kind ${KIND_VERSION}"
curl -fsSLo /tmp/kind \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x /tmp/kind
sudo mv /tmp/kind "$BIN/kind"

# ── helmfile ──────────────────────────────────────────────────────────────────
echo "▶  Installing helmfile v${HELMFILE_VERSION}"
curl -fsSLo /tmp/helmfile.tar.gz \
  "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
tar -xzf /tmp/helmfile.tar.gz -C /tmp helmfile
sudo mv /tmp/helmfile "$BIN/helmfile"
rm /tmp/helmfile.tar.gz

# ── verify ────────────────────────────────────────────────────────────────────
echo ""
echo "✅  Installed versions:"
kubectl version --client --short 2>/dev/null || kubectl version --client
helm version --short
kind version
helmfile --version
openssl version

echo ""
echo "⚠️   Docker: install Docker Desktop on Windows, then:"
echo "     Settings → Resources → WSL Integration → enable for this distro"
echo "     Restart WSL, then run: docker ps"
