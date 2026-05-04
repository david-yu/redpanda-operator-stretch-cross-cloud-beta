#!/usr/bin/env bash
# scripts/install-monitoring.sh — deploy kube-prometheus-stack on rp-aws
# with a Redpanda-aware scrape config that covers all 5 brokers across the
# 3 clouds, plus an auto-provisioned Redpanda Grafana dashboard.
#
# Why rp-aws only: the operator's flat-mode EndpointSlices put all peer
# broker pod IPs into the headless `redpanda` Service on this cluster, and
# Cilium ClusterMesh routes pod-to-pod across clouds — so a single
# Prometheus here reaches all 5 brokers' /public_metrics endpoints.
#
# Outputs at the end:
#   - Grafana URL (NLB hostname, port 80)
#   - Grafana admin user (admin) + auto-generated password (read out of
#     the chart's <release>-grafana Secret — never written to disk and
#     never committed)
#
# Usage:
#   ./scripts/install-monitoring.sh
#
# Env (optional):
#   CTX        — kube-context (default: rp-aws)
#   NAMESPACE  — namespace (default: monitoring)
#   RELEASE    — helm release name (default: monitoring)
#   KPS_VERSION — chart version pin (default: latest)

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CTX=${CTX:-rp-aws}
NAMESPACE=${NAMESPACE:-monitoring}
RELEASE=${RELEASE:-monitoring}
KPS_VERSION=${KPS_VERSION:-}

# Redpanda Grafana dashboards from redpanda-data/observability (the same
# source `rpk generate grafana-dashboard --dashboard <name>` pulls from
# at runtime). We pre-load three:
#
#   Ops dashboard          — broker KPI + health (throughput, latency,
#                            disk free bytes, leadership distribution by
#                            rack, URP, leader elections). 41 panels.
#                            Best for Demo A's "watch leaders move" view.
#   Topic-metrics dashboard — per-topic throughput / on-disk size /
#                            read+write rates. Best for OMB observation:
#                            filter to topic=load-test and watch the
#                            ~30 MB/s producer rate live.
#   Default dashboard       — older legacy view kept as a familiar fallback.
#
# All three drop into the General folder via the sidecar (chart default
# at /tmp/dashboards). Drift caught 2026-05-03 (the original
# Kubernetes-Redpanda.json 404'd) and 2026-05-04 (added Ops + Topic
# Metrics so the user gets cross-cloud throughput, disk pressure, and
# OMB rate views out of the box).
DASHBOARD_URLS=(
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Redpanda-Ops-Dashboard.json|redpanda-ops-dashboard"
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Kafka-Topic-Metrics.json|redpanda-topic-metrics-dashboard"
  "https://raw.githubusercontent.com/redpanda-data/observability/main/grafana-dashboards/Redpanda-Default-Dashboard.json|redpanda-default-dashboard"
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

log "creating namespace $NAMESPACE on $CTX (idempotent)"
kubectl --context "$CTX" create namespace "$NAMESPACE" --dry-run=client -o yaml | \
  kubectl --context "$CTX" apply -f - >/dev/null

# Inject the cross-cluster scrape config as a Secret so kube-prometheus-stack
# can pick it up via `additionalScrapeConfigsSecret`. The Secret content is
# the YAML list in monitoring/redpanda-scrape.yaml (the chart concatenates
# it into prometheus's full scrape_configs list).
log "creating redpanda-additional-scrape-configs Secret"
kubectl --context "$CTX" -n "$NAMESPACE" create secret generic redpanda-additional-scrape-configs \
  --from-file=scrape.yaml="$REPO_ROOT/monitoring/redpanda-scrape.yaml" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

VERSION_ARG=""
if [[ -n "$KPS_VERSION" ]]; then
  VERSION_ARG="--version $KPS_VERSION"
fi

log "helm upgrade --install $RELEASE prometheus-community/kube-prometheus-stack"
# shellcheck disable=SC2086
helm --kube-context "$CTX" upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  -n "$NAMESPACE" $VERSION_ARG \
  -f "$REPO_ROOT/monitoring/values.yaml" \
  --wait --timeout 10m

# Pull each Redpanda dashboard JSON and load as a labelled ConfigMap.
# The Grafana sidecar (label=grafana_dashboard, value=1) auto-imports.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for entry in "${DASHBOARD_URLS[@]}"; do
  url=${entry%|*}
  cm=${entry##*|}
  fname="$(basename "$url")"
  log "fetching $fname"
  if ! curl -fsSL "$url" -o "$tmp/$fname"; then
    log "  WARNING: could not fetch $fname — skipping (Grafana will still work, just without this dashboard)"
    continue
  fi
  kubectl --context "$CTX" -n "$NAMESPACE" create configmap "$cm" \
    --from-file="$fname=$tmp/$fname" \
    --dry-run=client -o yaml | \
    kubectl --context "$CTX" label --local --dry-run=client -f - grafana_dashboard=1 -o yaml | \
    kubectl --context "$CTX" apply -f - >/dev/null \
    && log "  loaded as ConfigMap $cm"
done

log "waiting for Grafana LoadBalancer to receive a public hostname (max 5m)"
url=""
for _ in $(seq 1 60); do
  hostname=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  ip=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -n "$hostname" ]]; then
    url="http://$hostname"; break
  elif [[ -n "$ip" ]]; then
    url="http://$ip"; break
  fi
  sleep 5
done

# Read the auto-generated admin password out of the secret. This stays in
# the cluster — we print it to the operator's terminal once and never
# write it to disk.
admin_pw=$(kubectl --context "$CTX" -n "$NAMESPACE" get secret "$RELEASE-grafana" \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)

cat >&2 <<EOF

============================================================
  Prometheus + Grafana deployed on $CTX (namespace: $NAMESPACE)
============================================================

  Grafana URL:      ${url:-<LB pending — re-check: kubectl --context $CTX -n $NAMESPACE get svc $RELEASE-grafana>}
  Grafana login:    admin / ${admin_pw:-<unable to read $RELEASE-grafana secret>}
  Dashboard:        Dashboards → Redpanda → "Kubernetes Redpanda"

  Prometheus is configured with a cross-cluster scrape job that picks up
  every broker pod's /public_metrics across all 3 clouds via the
  operator's flat-mode EndpointSlices.

  This password regenerates on every helm upgrade --install if you let
  the chart auto-generate it. To keep it stable across re-installs, set
  grafana.adminPassword in monitoring/values.yaml — but DO NOT commit
  that change (the .gitignore covers monitoring/values.local.yaml).
EOF
