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
# Which cloud hosts the cross-cloud aggregate dashboards (rp-gcp by default —
# central position in the rack ordering, survives the AWS-cordon Demo B path).
# Set XC_AGGREGATOR_CTX="" to skip cross-cloud dashboards entirely.
XC_AGGREGATOR_CTX=${XC_AGGREGATOR_CTX:-rp-gcp}

# Redpanda Grafana dashboards loaded from monitoring/dashboards/*.json.
# These are vendored copies of the upstream redpanda-data/observability
# JSONs (same source `rpk generate grafana-dashboard --dashboard <name>`
# pulls from), with two project-specific patches that we want to survive
# every reinstall:
#
#   1. Default dashboard — storage panels render as MB (decmbytes),
#      not raw bytes. Easier to eyeball "9.5 GiB free" than "1.02e+10".
#   2. Ops dashboard — "Nodes Up" renamed to "Nodes Up (this cloud)" with
#      a description explaining that per-cloud Prometheus only sees the
#      local cluster's brokers (rp-aws=1, rp-gcp=2, rp-azure=2). The
#      Default dashboard's "Nodes Up" stays as-is — it queries the
#      cluster-wide gauge `redpanda_cluster_brokers` (all 5).
#
# Plus four project-original dashboards:
#   3. Demo A dashboard — per-cloud Prometheus, leader-count-per-broker +
#      throughput + transfer rate. Watch leaders fall through from rp-aws
#      to rp-gcp during cordon, then return after restore.
#   4. Demo B dashboard — per-cloud Prometheus, cluster broker count +
#      per-broker disk free/used + partitions moving + storage health alert.
#      Open on rp-gcp or rp-azure Grafana — rp-aws Grafana goes dark with
#      its cordoned cluster.
#   5. Cross-Cloud Demo A dashboard — single-pane view querying ALL THREE
#      clouds' Prometheus instances on the aggregator cloud's Grafana
#      (XC_AGGREGATOR_CTX, default rp-gcp). Each panel has 3 query targets
#      (one per peer Prometheus); legend by pod name so the cloud is in
#      the legend. Survives an AWS cordon by going to "no data" for the
#      AWS series while continuing to show GCP + Azure.
#   6. Cross-Cloud Demo B dashboard — same idea for Demo B's broker count
#      / disk / reassignment narrative.
#
# Cross-cloud dashboards depend on:
#   - Cilium ClusterMesh routing peer-cluster pod IPs (validated 2026-05-04
#     in install-cilium.sh + connect-mesh.sh). Each peer Prometheus pod
#     is reachable from the aggregator's Grafana pod via its pod IP.
#   - A datasource provisioning ConfigMap (cross-cloud-datasources.yaml)
#     applied to ONLY the aggregator's monitoring namespace. The peer
#     Prometheus pod IPs go in there at install time. Pod IPs change on
#     restart — re-run install-monitoring.sh after a Prometheus pod restart
#     to refresh the datasource URLs.
#
# At install time we jq-inject:
#   - the local kube-context into Ops, Demo-A, Demo-B titles (per-cloud
#     branding so each Grafana tab self-identifies);
#   - the runtime-resolved Grafana datasource UIDs into the Cross-Cloud
#     dashboards (Grafana's provisioning auto-generates UIDs and rejects
#     UID overrides on update; we capture and substitute).
#
# All seven drop into the General folder via the sidecar (chart default
# at /tmp/dashboards). Chart-bundled K8s dashboards (apiserver / nodes /
# pods / kubelet / prometheus / ...) are explicitly disabled in
# monitoring/values.yaml so the Grafana UI stays focused on Redpanda.
#
# Format: "filename|configmap-name|flags"
#   flags: brand     — append "(<ctx>)" to .title
#          xc-only   — apply ONLY to XC_AGGREGATOR_CTX (skip on others)
#          xc-uids   — substitute datasource UID placeholders before apply
DASHBOARD_FILES=(
  "Redpanda-Ops-Dashboard.json|redpanda-ops-dashboard|brand"
  "Redpanda-Default-Dashboard.json|redpanda-default-dashboard|"
  "Kafka-Topic-Metrics.json|redpanda-topic-metrics-dashboard|"
  "Redpanda-Demo-A.json|redpanda-demo-a-dashboard|brand"
  "Redpanda-Demo-B.json|redpanda-demo-b-dashboard|brand"
  "Redpanda-Cross-Cloud-Demo-A.json|redpanda-cross-cloud-demo-a-dashboard|xc-only,xc-uids"
  "Redpanda-Cross-Cloud-Demo-B.json|redpanda-cross-cloud-demo-b-dashboard|xc-only,xc-uids"
)
DASHBOARD_DIR="$REPO_ROOT/monitoring/dashboards"

log() { echo "[install-monitoring] $*" >&2; }

require_cli() {
  for c in kubectl helm jq; do
    command -v $c >/dev/null 2>&1 || { echo "missing CLI: $c" >&2; exit 1; }
  done
}

require_cli

log "ensuring prometheus-community helm repo is registered"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

# Verify all vendored dashboards are present locally before we begin.
for entry in "${DASHBOARD_FILES[@]}"; do
  fname=${entry%%|*}
  [[ -f "$DASHBOARD_DIR/$fname" ]] || { echo "missing dashboard: $DASHBOARD_DIR/$fname" >&2; exit 1; }
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

  log "  loading dashboard ConfigMaps (per-cloud subset; cross-cloud applied after the loop)"
  # Per-cluster scratch dir so the cloud-branding rewrite for one ctx
  # doesn't leak into the next ctx's ConfigMap.
  ctx_tmp=$(mktemp -d)
  for entry in "${DASHBOARD_FILES[@]}"; do
    fname=${entry%%|*}
    rest=${entry#*|}
    cm=${rest%%|*}
    flags=${rest#*|}
    # Skip cross-cloud-only dashboards in the per-cloud loop — they need
    # peer Prometheus IPs + Grafana datasource UIDs, applied later.
    [[ "$flags" == *xc-only* ]] && continue
    src="$DASHBOARD_DIR/$fname"
    dst="$ctx_tmp/$fname"
    if [[ "$flags" == *brand* ]]; then
      # Brand the dashboard title with the kube-context so each cloud's
      # Grafana clearly self-identifies (helps when you have 3 tabs open).
      jq --arg ctx "$ctx" '.title = (.title + " (" + $ctx + ")")' "$src" > "$dst"
    else
      cp "$src" "$dst"
    fi
    kubectl --context "$ctx" -n "$NAMESPACE" create configmap "$cm" \
      --from-file="$fname=$dst" \
      --dry-run=client -o yaml | \
      kubectl --context "$ctx" label --local --dry-run=client -f - grafana_dashboard=1 -o yaml | \
      kubectl --context "$ctx" apply -f - >/dev/null
  done
  rm -rf "$ctx_tmp"

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

# ----------------------------------------------------------------------
# Cross-cloud aggregate dashboards (applied to XC_AGGREGATOR_CTX only)
# ----------------------------------------------------------------------
XC_URL=""
if [[ -n "$XC_AGGREGATOR_CTX" ]] && echo "$CONTEXTS" | grep -qw "$XC_AGGREGATOR_CTX"; then
  log "=== cross-cloud aggregate setup on $XC_AGGREGATOR_CTX ==="

  log "  resolving each Prometheus pod IP (Cilium ClusterMesh routes them cross-cluster)"
  declare_ds_yaml=""
  declare ds_lines
  ds_lines=""
  for ctx in $CONTEXTS; do
    podip=$(kubectl --context "$ctx" -n "$NAMESPACE" get pods -l app.kubernetes.io/name=prometheus \
      -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    if [[ -z "$podip" ]]; then
      log "  WARNING: could not resolve Prometheus pod IP on $ctx — skipping its datasource"
      continue
    fi
    # Datasource name "Prometheus-AWS" / "Prometheus-GCP" / "Prometheus-Azure"
    cloud_name=$(echo "$ctx" | sed 's/^rp-//' | tr '[:lower:]' '[:upper:]')
    ds_lines="${ds_lines}
  - name: Prometheus-${cloud_name}
    type: prometheus
    access: proxy
    url: http://${podip}:9090
    isDefault: false
    jsonData:
      timeInterval: 30s"
  done

  if [[ -n "$ds_lines" ]]; then
    log "  applying cross-cloud datasource ConfigMap to $XC_AGGREGATOR_CTX"
    ds_yaml="apiVersion: 1
datasources:${ds_lines}
"
    kubectl --context "$XC_AGGREGATOR_CTX" -n "$NAMESPACE" create configmap redpanda-cross-cloud-datasources \
      --from-literal=cross-cloud-datasources.yaml="$ds_yaml" \
      --dry-run=client -o yaml | \
      kubectl --context "$XC_AGGREGATOR_CTX" label --local --dry-run=client -f - grafana_datasource=1 -o yaml | \
      kubectl --context "$XC_AGGREGATOR_CTX" apply -f - >/dev/null

    log "  waiting up to 60s for Grafana sidecar to provision the new datasources"
    XC_URL=""
    for i in $(seq 1 12); do
      hostname=$(kubectl --context "$XC_AGGREGATOR_CTX" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
      ip=$(kubectl --context "$XC_AGGREGATOR_CTX" -n "$NAMESPACE" get svc "$RELEASE-grafana" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      [[ -n "$hostname" ]] && XC_URL="http://$hostname"
      [[ -z "$XC_URL" && -n "$ip" ]] && XC_URL="http://$ip"
      [[ -n "$XC_URL" ]] && break
      sleep 5
    done

    if [[ -n "$XC_URL" ]]; then
      gpass=$(kubectl --context "$XC_AGGREGATOR_CTX" -n "$NAMESPACE" get secret "$RELEASE-grafana" \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
      # Wait for all 3 Prometheus-* datasources to appear.
      for i in $(seq 1 24); do
        ds_count=$(curl -s -u "admin:$gpass" "$XC_URL/api/datasources" 2>/dev/null \
          | jq -r '[.[] | select(.name | startswith("Prometheus-"))] | length' 2>/dev/null || echo 0)
        [[ "$ds_count" -ge 1 ]] && break
        sleep 5
      done

      log "  fetching Grafana-assigned datasource UIDs"
      ds_json=$(curl -s -u "admin:$gpass" "$XC_URL/api/datasources" 2>/dev/null)
      AWS_UID=$(echo "$ds_json" | jq -r '.[] | select(.name=="Prometheus-AWS") | .uid // empty' 2>/dev/null)
      GCP_UID=$(echo "$ds_json" | jq -r '.[] | select(.name=="Prometheus-GCP") | .uid // empty' 2>/dev/null)
      AZURE_UID=$(echo "$ds_json" | jq -r '.[] | select(.name=="Prometheus-Azure") | .uid // empty' 2>/dev/null)

      log "  applying cross-cloud dashboards (UID-substituted) to $XC_AGGREGATOR_CTX"
      xc_tmp=$(mktemp -d)
      for entry in "${DASHBOARD_FILES[@]}"; do
        fname=${entry%%|*}
        rest=${entry#*|}
        cm=${rest%%|*}
        flags=${rest#*|}
        [[ "$flags" == *xc-only* ]] || continue
        src="$DASHBOARD_DIR/$fname"
        dst="$xc_tmp/$fname"
        # Substitute the dashboard's hardcoded development-time UIDs with
        # the live ones. The original UIDs in the JSON serve as portable
        # placeholder strings — any dashboard authored against this Grafana
        # install once would have these baked in.
        sed -e "s/PF0528EF25F2024B6/${AWS_UID:-PF0528EF25F2024B6}/g" \
            -e "s/PF2AF1CE8C60FA39E/${GCP_UID:-PF2AF1CE8C60FA39E}/g" \
            -e "s/P798A6BC1AFC6F104/${AZURE_UID:-P798A6BC1AFC6F104}/g" \
            "$src" > "$dst"
        kubectl --context "$XC_AGGREGATOR_CTX" -n "$NAMESPACE" create configmap "$cm" \
          --from-file="$fname=$dst" \
          --dry-run=client -o yaml | \
          kubectl --context "$XC_AGGREGATOR_CTX" label --local --dry-run=client -f - grafana_dashboard=1 -o yaml | \
          kubectl --context "$XC_AGGREGATOR_CTX" apply -f - >/dev/null
      done
      rm -rf "$xc_tmp"
      log "  cross-cloud dashboards applied: AWS_UID=${AWS_UID:-?} GCP_UID=${GCP_UID:-?} AZURE_UID=${AZURE_UID:-?}"
    else
      log "  WARNING: $XC_AGGREGATOR_CTX Grafana LB never came up — skipping cross-cloud dashboard apply"
    fi
  fi
else
  log "skipping cross-cloud aggregate (XC_AGGREGATOR_CTX='$XC_AGGREGATOR_CTX' not in CONTEXTS)"
fi

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
  Each cloud's Grafana shows ONLY that cloud's brokers (per-cloud Demo A
  / Demo B / Ops dashboards). To see all 5 brokers in ONE view, open the
  cross-cloud aggregate dashboards on $XC_AGGREGATOR_CTX:

    $XC_AGGREGATOR_CTX cross-cloud aggregate URL: ${XC_URL:-<see Grafana URL above>}
    Open: Dashboards → "Redpanda Cross-Cloud Demo A" / "Redpanda Cross-Cloud Demo B"

  How it works: 3 Grafana datasources (Prometheus-AWS / -GCP / -Azure)
  point at each peer's Prometheus pod IP; Cilium ClusterMesh routes the
  pod IPs cross-cluster. If a Prometheus pod restarts its IP changes —
  re-run install-monitoring.sh to refresh.

  Survives a cross-cloud outage: if rp-aws is cordoned (Demo B), rp-gcp
  and rp-azure Grafanas keep working off their local Prometheus, AND the
  cross-cloud aggregate on $XC_AGGREGATOR_CTX shows the AWS series as
  "no data" while GCP + Azure series keep streaming. If $XC_AGGREGATOR_CTX
  itself goes down (less likely), fall back to the per-cloud Grafanas.

  Passwords regenerate on every helm upgrade --install. Pin them by
  setting grafana.adminPassword in monitoring/values.local.yaml
  (.gitignored) — DO NOT commit that change.
EOF
