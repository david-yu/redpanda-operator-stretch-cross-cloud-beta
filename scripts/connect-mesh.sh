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

patch_server_cert_clientauth() {
  # cilium#43099: server cert needs clientAuth EKU for kvstoremesh peer
  # auth to work. Regenerate with both serverAuth + clientAuth.
  local ctx=$1
  local td
  td=$(mktemp -d)
  trap "rm -rf $td" RETURN
  kubectl --context "$ctx" -n kube-system get secret clustermesh-apiserver-server-cert -o jsonpath='{.data.tls\.key}' | base64 -d > "$td/server.key"
  kubectl --context "$ctx" -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$td/ca.crt"
  kubectl --context "$ctx" -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.key}' | base64 -d > "$td/ca.key"
  cat > "$td/cert.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = clustermesh-apiserver.cilium.io
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @san
[san]
DNS.1 = clustermesh-apiserver.cilium.io
DNS.2 = *.mesh.cilium.io
DNS.3 = clustermesh-apiserver.kube-system.svc
IP.1 = 127.0.0.1
IP.2 = ::1
EOF
  openssl req -new -key "$td/server.key" -out "$td/server.csr" -config "$td/cert.cnf" 2>/dev/null
  openssl x509 -req -in "$td/server.csr" -CA "$td/ca.crt" -CAkey "$td/ca.key" -CAcreateserial \
    -out "$td/new.crt" -days 1095 -extfile "$td/cert.cnf" -extensions v3_req 2>/dev/null
  local b64
  b64=$(base64 < "$td/new.crt" | tr -d '\n')
  kubectl --context "$ctx" -n kube-system patch secret clustermesh-apiserver-server-cert \
    --type=json -p="[{\"op\":\"replace\",\"path\":\"/data/tls.crt\",\"value\":\"$b64\"}]" >/dev/null
  kubectl --context "$ctx" -n kube-system rollout restart deploy clustermesh-apiserver >/dev/null 2>&1 || true
}

enable_all() {
  for c in "${CONTEXTS[@]}"; do
    log "enabling clustermesh on $c"
    cilium clustermesh enable --context "$c" --service-type LoadBalancer
  done
  for c in "${CONTEXTS[@]}"; do
    log "patching server cert with clientAuth EKU (cilium#43099)"
    patch_server_cert_clientauth "$c"
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
