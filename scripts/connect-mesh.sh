#!/usr/bin/env bash
# scripts/connect-mesh.sh — wire the three clusters into a Cilium Cluster
# Mesh after they each have Cilium installed (via install-cilium.sh).
#
# The flow:
#   1. Enable clustermesh on each cluster. The clustermesh-apiserver
#      Service is exposed via type=LoadBalancer, so each cluster gets a
#      public IP/hostname that the other clusters can reach.
#   2. Connect each pair of clusters. `cilium clustermesh connect` is
#      bidirectional (sets up mesh in both directions when given both
#      contexts), so 3 calls are enough to fully mesh 3 clusters.
#   3. Verify with `cilium clustermesh status`.
#
# Cilium auto-generates mTLS certs and exchanges them between clusters
# during `connect`, so the public LB exposure is safe — only authenticated
# peers can use the clustermesh-apiserver.
#
# Usage:
#   ./connect-mesh.sh enable
#   ./connect-mesh.sh connect
#   ./connect-mesh.sh status
#   ./connect-mesh.sh all     # enable + connect + status

set -uo pipefail

CONTEXTS=(rp-aws rp-gcp rp-azure)

log() { echo "[connect-mesh] $*" >&2; }

enable_all() {
  for c in "${CONTEXTS[@]}"; do
    log "enabling clustermesh on $c"
    cilium clustermesh enable --context "$c" --service-type LoadBalancer
  done
  for c in "${CONTEXTS[@]}"; do
    log "waiting for clustermesh-apiserver Ready on $c"
    cilium clustermesh status --context "$c" --wait
  done
}

# 3-clique: aws↔gcp, aws↔azure, gcp↔azure.
connect_all() {
  log "connecting rp-aws ↔ rp-gcp"
  cilium clustermesh connect --allow-mismatching-ca --context rp-aws --destination-context rp-gcp
  log "connecting rp-aws ↔ rp-azure"
  cilium clustermesh connect --allow-mismatching-ca --context rp-aws --destination-context rp-azure
  log "connecting rp-gcp ↔ rp-azure"
  cilium clustermesh connect --allow-mismatching-ca --context rp-gcp --destination-context rp-azure
}

status_all() {
  for c in "${CONTEXTS[@]}"; do
    log "=== $c ==="
    cilium clustermesh status --context "$c"
  done
}

case "${1:-}" in
  enable)  enable_all ;;
  connect) connect_all ;;
  status)  status_all ;;
  all)     enable_all; connect_all; status_all ;;
  *) echo "usage: $0 {enable|connect|status|all}" >&2; exit 2 ;;
esac

log "done"
