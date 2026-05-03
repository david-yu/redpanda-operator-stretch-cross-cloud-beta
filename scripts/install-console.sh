#!/usr/bin/env bash
# scripts/install-console.sh — deploy a single Redpanda Console instance on
# rp-aws (the controller-pinned home region), wired to the cross-cloud
# StretchCluster.
#
# Why rp-aws: `default_leaders_preference: "racks:aws"` keeps the controller
# leader in this cloud, so any Admin API call lands on the local cluster
# without an extra cross-cloud hop. The operator's flat-mode EndpointSlices
# mean the headless `redpanda` Service in this cluster resolves to all 5
# broker pod IPs (2 AWS + 2 GCP + 1 Azure), so this single Console covers
# the whole stretch cluster.
#
# Usage:
#   ./scripts/install-console.sh
#
# Env (optional):
#   CTX            — kube-context to install into (default: rp-aws)
#   NAMESPACE      — Console namespace (default: console)
#   CONSOLE_VERSION — chart version (default: latest from redpanda repo)
#
# Output:
#   Prints the Console URL (NLB hostname) and a note about auth at the end.
#   Nothing is written to disk.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CTX=${CTX:-rp-aws}
NAMESPACE=${NAMESPACE:-console}
CONSOLE_VERSION=${CONSOLE_VERSION:-}

log() { echo "[install-console] $*" >&2; }

require_cli() {
  for c in kubectl helm; do
    command -v $c >/dev/null 2>&1 || { echo "missing CLI: $c" >&2; exit 1; }
  done
}

require_cli

log "ensuring redpanda helm repo is registered"
helm repo add redpanda https://charts.redpanda.com --force-update >/dev/null
helm repo update >/dev/null

log "creating namespace $NAMESPACE on $CTX (idempotent)"
kubectl --context "$CTX" create namespace "$NAMESPACE" --dry-run=client -o yaml | \
  kubectl --context "$CTX" apply -f - >/dev/null

VERSION_ARG=""
if [[ -n "$CONSOLE_VERSION" ]]; then
  VERSION_ARG="--version $CONSOLE_VERSION"
fi

log "helm upgrade --install console (chart: redpanda/console)"
# shellcheck disable=SC2086
helm --kube-context "$CTX" upgrade --install console redpanda/console \
  -n "$NAMESPACE" $VERSION_ARG \
  -f "$REPO_ROOT/console/values.yaml" \
  --wait --timeout 5m

log "waiting for the Console LoadBalancer to receive a public hostname (max 5m)"
url=""
for _ in $(seq 1 60); do
  hostname=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc console \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  ip=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc console \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$hostname" ]]; then
    url="http://$hostname:8080"; break
  elif [[ -n "$ip" ]]; then
    url="http://$ip:8080"; break
  fi
  sleep 5
done

cat >&2 <<EOF

============================================================
  Redpanda Console deployed on $CTX (namespace: $NAMESPACE)
============================================================

  URL:    ${url:-<LB pending — re-check: kubectl --context $CTX -n $NAMESPACE get svc console>}
  Auth:   none (Console OSS — demo posture)

  Console points at the cross-cloud StretchCluster via the headless
  redpanda.redpanda.svc.cluster.local Service. Topic / partition /
  broker / consumer-group views span all 3 clouds.

  Hint:   open Topics → load-test (after install-omb.sh) to watch
          the OMB workload land in real time.
EOF
