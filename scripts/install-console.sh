#!/usr/bin/env bash
# scripts/install-console.sh — deploy a Redpanda Console instance on
# EVERY cluster (rp-aws, rp-gcp, rp-azure). Each Console points at its
# own cluster's headless `redpanda` Service.
#
# Why per-cloud (not centralized on rp-aws):
#   1. Survivability — when AWS is cordoned (Demo B's failure mode),
#      the centralized Console + Grafana stack on rp-aws goes dark.
#      Per-cloud keeps each cloud's UI alive when its peers are down.
#   2. Each cluster's local headless `redpanda` Service has flat-mode
#      EndpointSlices for ALL peer broker pod IPs, so each Console gets
#      a full cross-cluster broker view via local DNS. (Cross-cluster
#      reachability requires Cilium ClusterMesh — if peers are
#      unreachable, Console gracefully shows only the alive ones.)
#
# Why helm chart and NOT the operator-managed Console CR:
#   The multicluster-mode operator we deploy (`redpanda-data/operator
#   --version 26.2.1-beta.1`, started with `multicluster` as its top-level
#   subcommand) only ships the StretchCluster reconciler. Its `Console`
#   CRD is registered but no reconciler in this binary watches Console
#   CRs — applying one leaves it with empty `status` indefinitely. The
#   standalone (non-multicluster) operator binary does include the Console
#   controller, but running two operators in the redpanda namespace fights
#   over StretchCluster events. Helm chart is the pragmatic path.
#   Tracked as K8S-846; drift caught during 2026-05-03 e2e validation.
#
# Usage:
#   ./scripts/install-console.sh                       # all 3 clusters
#   CONTEXTS="rp-aws" ./scripts/install-console.sh     # one cluster
#
# Env (optional):
#   CONTEXTS       — space-separated kube-contexts (default: "rp-aws rp-gcp rp-azure")
#   NAMESPACE      — Console namespace (default: console)
#   CONSOLE_VERSION — chart version pin (default: latest)

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CONTEXTS=${CONTEXTS:-rp-aws rp-gcp rp-azure}
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

VERSION_ARG=""
if [[ -n "$CONSOLE_VERSION" ]]; then
  VERSION_ARG="--version $CONSOLE_VERSION"
fi

# macOS ships bash 3.2 by default which doesn't support `declare -A`
# (associative arrays). Use a parallel-arrays pattern instead so the
# script runs on macOS and Linux without bash >= 4.
CTX_LIST=()
URL_LIST=()

for ctx in $CONTEXTS; do
  log "=== $ctx ==="

  log "  creating namespace $NAMESPACE (idempotent)"
  kubectl --context "$ctx" create namespace "$NAMESPACE" --dry-run=client -o yaml | \
    kubectl --context "$ctx" apply -f - >/dev/null

  log "  helm upgrade --install console (chart: redpanda/console)"
  # shellcheck disable=SC2086
  helm --kube-context "$ctx" upgrade --install console redpanda/console \
    -n "$NAMESPACE" $VERSION_ARG \
    -f "$REPO_ROOT/console/values.yaml" \
    --wait --timeout 5m | tail -3

  log "  waiting for Console LoadBalancer (max 5m)"
  url=""
  for _ in $(seq 1 60); do
    hostname=$(kubectl --context "$ctx" -n "$NAMESPACE" get svc console \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    ip=$(kubectl --context "$ctx" -n "$NAMESPACE" get svc console \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$hostname" ]]; then url="http://$hostname:8080"; break; fi
    if [[ -n "$ip" ]]; then url="http://$ip:8080"; break; fi
    sleep 5
  done
  CTX_LIST+=("$ctx")
  URL_LIST+=("${url:-<LB pending — re-check: kubectl --context $ctx -n $NAMESPACE get svc console>}")
done

cat >&2 <<EOF

============================================================
  Redpanda Console deployed on each cloud (per-cloud design)
============================================================

EOF
i=0
for ctx in "${CTX_LIST[@]}"; do
  cat >&2 <<EOF
  $ctx:
    URL:   ${URL_LIST[$i]}
    Auth:  none (Console OSS — demo posture)

EOF
  i=$((i + 1))
done
cat >&2 <<EOF
  Each cloud's Console points at its own headless redpanda Service via
  redpanda.redpanda.svc.cluster.local:9093. With operator flat-mode
  EndpointSlices, each Console sees all 5 brokers across the 3 clouds
  (when peers are reachable via Cilium ClusterMesh).

  Survives a cross-cloud outage: if rp-aws is cordoned (Demo B), rp-gcp
  and rp-azure Consoles keep working (they may show the AWS brokers as
  unreachable in the Brokers pane, but topic / consumer-group views
  on the surviving brokers stay live).

  Hint: open Topics → load-test (after install-omb.sh) on rp-aws Console
        — that's where the OMB workload runs.
EOF
