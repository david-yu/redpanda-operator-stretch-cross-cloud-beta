#!/usr/bin/env bash
# scripts/install-console.sh — deploy a single Redpanda Console instance on
# rp-aws (the controller-pinned home region), wired to the cross-cloud
# StretchCluster.
#
# Why helm chart and NOT the operator-managed Console CR:
# the multicluster-mode operator we deploy (`redpanda-data/operator
# --version 26.2.1-beta.1`, started with `multicluster` as its top-level
# subcommand) only ships the StretchCluster reconciler. Its `Console`
# CRD is registered but no reconciler in this binary watches Console
# CRs — applying one leaves it with empty `status` indefinitely. The
# standalone (non-multicluster) operator binary does include the Console
# controller, but running two operators in the redpanda namespace fights
# over StretchCluster events. Helm chart is the pragmatic path. Drift
# caught during 2026-05-03 e2e validation; see console/values.yaml.
#
# We deploy on rp-aws because that's where the controller leader lives
# (default_leaders_preference: ordered_racks:aws,gcp,azure) — Admin API
# round-trips stay local. Operator's flat-mode EndpointSlices put every
# peer broker pod IP into rp-aws's headless `redpanda` Service, so this
# single Console covers all 5 brokers across the 3 clouds.
#
# Usage:
#   ./scripts/install-console.sh
#
# Env (optional):
#   CTX            — kube-context (default: rp-aws)
#   NAMESPACE      — Console namespace (default: console)
#   CONSOLE_VERSION — chart version (default: latest from redpanda repo)

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

  Mode:   helm chart (redpanda/console)
  URL:    ${url:-<LB pending — re-check: kubectl --context $CTX -n $NAMESPACE get svc console>}
  Auth:   none (Console OSS — demo posture)

  Console points at the cross-cloud StretchCluster via the headless
  redpanda.redpanda.svc.cluster.local Service. Topic / partition /
  broker / consumer-group views span all 3 clouds.

  Hint:   open Topics → load-test (after install-omb.sh) to watch
          the OMB workload land in real time.
EOF
