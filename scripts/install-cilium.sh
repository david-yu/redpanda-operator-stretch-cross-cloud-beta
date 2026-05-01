#!/usr/bin/env bash
# scripts/install-cilium.sh — install Cilium on each cluster after the
# Terraform clusters are up.
#
# Each cloud needs different Cilium install flags because we asked
# Terraform to bring up a cluster with NO CNI:
#
#   - AWS EKS (no `vpc-cni` addon)  → ipam.mode=cluster-pool, eni.enabled=false
#   - GCP GKE (no Dataplane V2)     → gke.enabled=true, ipam.mode=kubernetes
#   - Azure AKS (network_plugin=none) → aksbyocni.enabled=true, ipam.mode=cluster-pool
#
# All three install with kubeProxyReplacement (eBPF replaces kube-proxy)
# and node-to-node WireGuard encryption so the cross-cloud pod traffic is
# encrypted on the public internet.
#
# Cluster IDs (1-255) and names must be unique across the mesh:
#   aws=1/rp-aws, gcp=2/rp-gcp, azure=3/rp-azure
#
# Usage:
#   ./install-cilium.sh aws
#   ./install-cilium.sh gcp
#   ./install-cilium.sh azure
#   ./install-cilium.sh all   # install on all three sequentially
#
# Requires: cilium CLI (https://github.com/cilium/cilium-cli) and the
# kubectl contexts rp-aws / rp-gcp / rp-azure in your kubeconfig.

set -uo pipefail

CILIUM_VERSION=${CILIUM_VERSION:-1.16.5}
POD_CIDR_AWS=${POD_CIDR_AWS:-10.110.0.0/16}
POD_CIDR_AZURE=${POD_CIDR_AZURE:-10.130.0.0/16}

log() { echo "[install-cilium] $*" >&2; }

require_cli() {
  for c in cilium kubectl; do
    command -v $c >/dev/null 2>&1 || { echo "missing CLI: $c" >&2; exit 1; }
  done
}

install_aws() {
  log "installing Cilium on rp-aws (EKS, cluster.id=1)"
  cilium install --kube-context rp-aws \
    --version "$CILIUM_VERSION" \
    --set cluster.id=1 \
    --set cluster.name=rp-aws \
    --set eni.enabled=false \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR_AWS" \
    --set ipam.operator.clusterPoolIPv4MaskSize=24 \
    --set kubeProxyReplacement=true \
    --set routingMode=tunnel \
    --set tunnelProtocol=geneve \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --set bpf.masquerade=true \
    --set l7Proxy=false
  cilium status --kube-context rp-aws --wait
}

install_gcp() {
  log "installing Cilium on rp-gcp (GKE, cluster.id=2)"
  cilium install --kube-context rp-gcp \
    --version "$CILIUM_VERSION" \
    --set cluster.id=2 \
    --set cluster.name=rp-gcp \
    --set gke.enabled=true \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set routingMode=tunnel \
    --set tunnelProtocol=geneve \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --set bpf.masquerade=true \
    --set l7Proxy=false
  cilium status --kube-context rp-gcp --wait
}

install_azure() {
  log "installing Cilium on rp-azure (AKS BYOCNI, cluster.id=3)"
  cilium install --kube-context rp-azure \
    --version "$CILIUM_VERSION" \
    --set cluster.id=3 \
    --set cluster.name=rp-azure \
    --set aksbyocni.enabled=true \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR_AZURE" \
    --set ipam.operator.clusterPoolIPv4MaskSize=24 \
    --set kubeProxyReplacement=true \
    --set routingMode=tunnel \
    --set tunnelProtocol=geneve \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set encryption.nodeEncryption=true \
    --set bpf.masquerade=true \
    --set l7Proxy=false
  cilium status --kube-context rp-azure --wait
}

require_cli

case "${1:-}" in
  aws)   install_aws ;;
  gcp)   install_gcp ;;
  azure) install_azure ;;
  all)   install_aws; install_gcp; install_azure ;;
  *) echo "usage: $0 {aws|gcp|azure|all}" >&2; exit 2 ;;
esac

log "done"
