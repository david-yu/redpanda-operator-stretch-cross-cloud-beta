#!/usr/bin/env bash
# scripts/bootstrap-redpanda.sh — install cert-manager and tag nodes for
# rack awareness on each cluster, then create the redpanda namespace and
# license secret.
#
# This script handles the deterministic parts of the install. The
# operator helm install + StretchCluster apply still need rendered values
# (peer LB hostnames, K8s API endpoints) — see the README step-by-step
# for that flow.
#
# Usage:
#   ./bootstrap-redpanda.sh --license <path/to/redpanda.license>
#
# Optional env:
#   CERT_MANAGER_VERSION (default v1.16.2)

set -uo pipefail

CONTEXTS=(rp-aws rp-gcp rp-azure)
declare -A CLOUD_OF=( [rp-aws]=aws [rp-gcp]=gcp [rp-azure]=azure )

CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.16.2}

LICENSE_PATH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --license) LICENSE_PATH=$2; shift 2 ;;
    -h|--help) sed -n '2,/^# Usage:/p' "$0" | sed 's/^# *//;s/^#$//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$LICENSE_PATH" || ! -f "$LICENSE_PATH" ]]; then
  echo "error: --license <path> is required and must point to a readable file" >&2
  exit 2
fi

log() { echo "[bootstrap] $*" >&2; }

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null 2>&1 || true

for ctx in "${CONTEXTS[@]}"; do
  cloud=${CLOUD_OF[$ctx]}
  log "=== $ctx ($cloud) ==="

  log "  install cert-manager"
  helm --kube-context "$ctx" upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --wait --timeout 5m \
    >/dev/null

  log "  annotate nodes with redpanda.com/cloud=$cloud (rack awareness)"
  kubectl --context "$ctx" annotate nodes --all "redpanda.com/cloud=$cloud" --overwrite >/dev/null

  log "  ensure redpanda namespace + license secret"
  kubectl --context "$ctx" create ns redpanda --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n redpanda create secret generic redpanda-license \
    --from-file="license.key=$LICENSE_PATH" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
done

log "done — next: render <cloud>/helm-values/values-rp-<cloud>.example.yaml and helm install the operator + apply manifests/stretchcluster.yaml on each cluster (see README)"
