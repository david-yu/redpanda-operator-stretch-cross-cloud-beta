#!/usr/bin/env bash
# scripts/install-monitoring.sh — deploy a kube-prometheus-stack +
# Grafana on EVERY cluster (rp-aws, rp-gcp, rp-azure). Each Prometheus
# scrapes ONLY its local cluster's broker pods (via the PodMonitor in
# monitoring/redpanda-podmonitor.yaml).
#
# Why per-cloud (not centralized on rp-aws):
#   1. Survivability — when AWS is cordoned (Demo B's failure mode),
#      the centralized design loses all observability at the moment
#      you most need it. Per-cloud Grafana on rp-gcp / rp-azure
#      keeps showing local broker metrics through the outage.
#   2. No cross-cloud egress on the metrics path.
#   3. Trade-off: ~$0.30/hr in extra compute (3× Prometheus + Grafana).
#      Worth it for survivability; egress saving alone wouldn't be.
#
# Outputs at the end:
#   - 3 Grafana URLs (one per cloud, each printing its own auto-generated
#     admin password from the local <release>-grafana Secret).
#
# Usage:
#   ./scripts/install-monitoring.sh                      # all 3 clusters
#   CONTEXTS="rp-aws" ./scripts/install-monitoring.sh    # one cluster
#
# Env (optional):
#   CONTEXTS    — space-separated kube-contexts (default: "rp-aws rp-gcp rp-azure")
#   NAMESPACE   — namespace (default: monitoring)
#   RELEASE     — helm release name (default: monitoring)
#   KPS_VERSION — chart version pin (default: latest)

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CONTEXTS=${CONTEXTS:-rp-aws rp-gcp rp-azure}
NAMESPACE=${NAMESPACE:-monitoring}
RELEASE=${RELEASE:-monitoring}
KPS_VERSION=${KPS_VERSION:-}

# Redpanda Grafana dashboards from redpanda-data/observability (the same
# source `rpk generate grafana-dashboard --dashboard <name>` pulls from
# at runtime). We pre-load three on EACH cluster's Grafana:
#
#   Ops dashboard           — 41-panel KPI + health view (throughput,
#                             latency, disk free bytes, leadership by
#                             rack, URP, leader elections).
#   Default dashboard       — broker-side throughput + consumer + topic
#                             breakdown in a single legacy view.
#   Topic Metrics dashboard — per-topic produce/consume rates + on-disk
#                             size; filter to topic=load-test for live
#                             OMB throughput.
#
# All three drop into the General folder via the sidecar (chart default
# at /tmp/dashboards). Chart-bundled K8s dashboards (apiserver / nodes /
# pods / kubelet / prometheus / ...) are explicitly disabled in
# monitoring/values.yaml so the Grafana UI stays focused on Redpanda.
DASHBOARD_URLS=(
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Redpanda-Ops-Dashboard.json|redpanda-ops-dashboard"
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Redpanda-Default-Dashboard.json|redpanda-default-dashboard"
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Kafka-Topic-Metrics.json|redpanda-topic-metrics-dashboard"
)

log() { echo "[install-monitoring] $*" >&2; }

require_cli() {
  for c in kubectl helm curl; do
    command -v $c >/dev/null 2>&1 || { echo "missing CLI: $c" >&2; exit 1; }
  done
}

require_cli

log "ensuring prometheus-community helm repo is registered"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

# Pre-fetch dashboards once (same JSONs apply to all 3 clusters).
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for entry in "${DASHBOARD_URLS[@]}"; do
  url=${entry%|*}
  fname="$(basename "$url")"
  log "fetching $fname"
  if ! curl -fsSL "$url" -o "$tmp/$fname"; then
    log "  WARNING: could not fetch $fname — skipping (Grafana will still work, just without this dashboard)"
  fi
done

VERSION_ARG=""
if [[ -n "$KPS_VERSION" ]]; then
  VERSION_ARG="--version $KPS_VERSION"
fi

# macOS ships bash 3.2 (no `declare -A`) — use parallel arrays for portability.
CTX_LIST=()
URL_LIST=()
PW_LIST=()

for ctx in $CONTEXTS; do
  log "=== $ctx ==="

  log "  creating namespace $NAMESPACE (idempotent)"
  kubectl --context "$ctx" create namespace "$NAMESPACE" --dry-run=client -o yaml | \
    kubectl --context "$ctx" apply -f - >/dev/null

  log "  helm upgrade --install $RELEASE prometheus-community/kube-prometheus-stack"
  # shellcheck disable=SC2086
  helm --kube-context "$ctx" upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
    -n "$NAMESPACE" $VERSION_ARG \
    -f "$REPO_ROOT/monitoring/values.yaml" \
    --wait --timeout 10m | tail -3

  log "  applying PodMonitor for local cluster's broker pods"
  kubectl --context "$ctx" apply -f "$REPO_ROOT/monitoring/redpanda-podmonitor.yaml" 2>&1 | tail -1

  log "  loading dashboard ConfigMaps (Ops, Default, Topic Metrics)"
  for entry in "${DASHBOARD_URLS[@]}"; do
    url=${entry%|*}
    cm=${entry##*|}
    fname="$(basename "$url")"
    [[ -f "$tmp/$fname" ]] || continue
    kubectl --context "$ctx" -n "$NAMESPACE" create configmap "$cm" \
      --from-file="$fname=$tmp/$fname" \
      --dry-run=client -o yaml | \
      kubectl --context "$ctx" label --local --dry-run=client -f - grafana_dashboard=1 -o yaml | \
      kubectl --context "$ctx" apply -f - >/dev/null
  done

  log "  waiting for Grafana LoadBalancer to receive a public hostname (max 5m)"
  url=""
  for _ in $(seq 1 60); do
    hostname=$(kubectl --context "$ctx" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    ip=$(kubectl --context "$ctx" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$hostname" ]]; then url="http://$hostname"; break; fi
    if [[ -n "$ip" ]]; then url="http://$ip"; break; fi
    sleep 5
  done

  admin_pw=$(kubectl --context "$ctx" -n "$NAMESPACE" get secret "$RELEASE-grafana" \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

  CTX_LIST+=("$ctx")
  URL_LIST+=("${url:-<LB pending — re-check: kubectl --context $ctx -n $NAMESPACE get svc $RELEASE-grafana>}")
  PW_LIST+=("${admin_pw:-<unable to read $RELEASE-grafana secret>}")
done

cat >&2 <<EOF

============================================================
  Prometheus + Grafana deployed on each cloud (per-cloud design)
============================================================

EOF
i=0
for ctx in "${CTX_LIST[@]}"; do
  cat >&2 <<EOF
  $ctx:
    URL:    ${URL_LIST[$i]}
    Login:  admin / ${PW_LIST[$i]}
    Scrape: only this cluster's local Redpanda brokers (via PodMonitor)

EOF
  i=$((i + 1))
done
cat >&2 <<EOF
  Each cloud's Grafana shows ONLY that cloud's brokers. To see all 5
  brokers in one view, hop between the 3 Grafana URLs (or stand up a
  Thanos / Mimir / Cortex aggregation tier — out of scope here).

  Survives a cross-cloud outage: if rp-aws is cordoned (Demo B), rp-gcp
  and rp-azure Grafanas keep working off their local Prometheus.

  Passwords regenerate on every helm upgrade --install. Pin them by
  setting grafana.adminPassword in monitoring/values.local.yaml
  (.gitignored) — DO NOT commit that change.
EOF
