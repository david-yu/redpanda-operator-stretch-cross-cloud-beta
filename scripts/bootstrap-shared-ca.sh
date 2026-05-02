#!/usr/bin/env bash
# scripts/bootstrap-shared-ca.sh — pre-create a single root CA and
# distribute it as a `cert-manager` Issuer in every cluster's `redpanda`
# namespace.
#
# Why this exists: the StretchCluster operator's default TLS path
# (`tls.certs.default.caEnabled: true`) asks each cluster's cert-manager
# to mint a *new* self-signed CA. With one CA per cluster, brokers in
# rp-aws can't verify peers' certs in rp-gcp / rp-azure and inter-broker
# RPC handshakes fail with `SSL routines::packet length too long` /
# `record layer failure`. To get cross-cluster broker TLS working we
# need ONE root CA shared across all three clusters.
#
# Flow:
#   1. Generate a P-256 root CA cert + key locally (single source of truth).
#   2. Apply it as a Secret named `redpanda-shared-ca` in each cluster's
#      redpanda namespace.
#   3. Apply a cert-manager Issuer of kind `ca` named `redpanda-shared-ca-issuer`
#      that references that secret. cert-manager in each cluster will then
#      mint per-broker leaves signed by the SAME root, so peer verification
#      across clusters works.
#
# After running this, configure the StretchCluster manifests to point at
# the shared issuer instead of generating a per-cluster CA:
#
#   spec:
#     tls:
#       enabled: true
#       certs:
#         default:
#           issuerRef:
#             kind: Issuer
#             name: redpanda-shared-ca-issuer
#           applyInternalDNSNames: true
#         external:
#           issuerRef:
#             kind: Issuer
#             name: redpanda-shared-ca-issuer
#
# (Remove `caEnabled: true` — it conflicts with `issuerRef`.)
#
# Usage:
#   ./bootstrap-shared-ca.sh                         # default: 10y CA
#   CA_DAYS=3650 ./bootstrap-shared-ca.sh
#
# Idempotent — re-running re-applies the same secret + issuer (only the
# CA generation step is skipped if /tmp/redpanda-shared-ca/ca.crt exists).

set -uo pipefail

CONTEXTS=(rp-aws rp-gcp rp-azure)
NAMESPACE=redpanda
SECRET_NAME=redpanda-shared-ca
ISSUER_NAME=redpanda-shared-ca-issuer
CA_DAYS=${CA_DAYS:-3650}
WORKDIR=${WORKDIR:-/tmp/redpanda-shared-ca}

log() { echo "[shared-ca] $*" >&2; }

mkdir -p "$WORKDIR"

if [[ -f "$WORKDIR/ca.crt" && -f "$WORKDIR/ca.key" ]]; then
  log "reusing existing CA at $WORKDIR/{ca.crt,ca.key}"
else
  log "generating P-256 self-signed root CA (valid $CA_DAYS days)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORKDIR/ca.key" 2>/dev/null
  cat > "$WORKDIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = redpanda-stretch-cross-cloud-ca
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -new -key "$WORKDIR/ca.key" -days "$CA_DAYS" \
    -out "$WORKDIR/ca.crt" -config "$WORKDIR/ca.cnf" 2>/dev/null
  log "  CA created"
fi

CA_CRT_B64=$(base64 < "$WORKDIR/ca.crt" | tr -d '\n')
CA_KEY_B64=$(base64 < "$WORKDIR/ca.key" | tr -d '\n')

for ctx in "${CONTEXTS[@]}"; do
  log "=== $ctx ==="
  log "  ensure namespace $NAMESPACE"
  kubectl --context "$ctx" create ns "$NAMESPACE" --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null

  log "  apply secret/$SECRET_NAME"
  cat <<EOF | kubectl --context "$ctx" apply -f - >/dev/null
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
data:
  tls.crt: $CA_CRT_B64
  tls.key: $CA_KEY_B64
  ca.crt:  $CA_CRT_B64
EOF

  log "  apply cert-manager Issuer/$ISSUER_NAME (kind: ca)"
  cat <<EOF | kubectl --context "$ctx" apply -f - >/dev/null
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: $ISSUER_NAME
  namespace: $NAMESPACE
spec:
  ca:
    secretName: $SECRET_NAME
EOF
done

log "done — set spec.tls.certs.default.issuerRef on each StretchCluster:"
log "    issuerRef:"
log "      kind: Issuer"
log "      name: $ISSUER_NAME"
log "(and remove caEnabled: true)"
