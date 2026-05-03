#!/usr/bin/env bash
# scripts/install-omb.sh — create the load-test topic and start the OMB
# producer + consumer Jobs.
#
# We run the Jobs from rp-aws because that's where the controller leader
# lives (default_leaders_preference: racks:aws) — Admin API calls and
# topic-create round-trips are local. Produce / consume traffic still
# spans all three clouds because the topic is created with replicas=5 and
# leaders are spread across racks for the partitions we don't pin.
#
# Usage:
#   ./scripts/install-omb.sh
#
# Env (optional):
#   CTX        — kube-context (default: rp-aws)
#   NAMESPACE  — namespace (default: redpanda — must match StretchCluster)
#   PARTITIONS — load-test topic partitions (default: 24)
#   REPLICAS   — load-test topic replicas (default: 5 — full RF=5)

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CTX=${CTX:-rp-aws}
NAMESPACE=${NAMESPACE:-redpanda}
PARTITIONS=${PARTITIONS:-24}
REPLICAS=${REPLICAS:-5}

log() { echo "[install-omb] $*" >&2; }

require_cli() {
  command -v kubectl >/dev/null 2>&1 || { echo "missing CLI: kubectl" >&2; exit 1; }
}

require_cli

# Pick whichever broker pod exists in this cluster (could be -0 or -1).
BROKER_POD=$(kubectl --context "$CTX" -n "$NAMESPACE" get pod \
  -l app.kubernetes.io/name=redpanda -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$BROKER_POD" ]]; then
  echo "no redpanda broker pod found on $CTX in namespace $NAMESPACE" >&2
  exit 1
fi

log "creating load-test topic (partitions=$PARTITIONS, replicas=$REPLICAS) via $BROKER_POD"
kubectl --context "$CTX" -n "$NAMESPACE" exec "$BROKER_POD" -c redpanda -- \
  rpk topic create load-test \
  --partitions "$PARTITIONS" \
  --replicas "$REPLICAS" 2>&1 | sed 's/^/  /' || true

log "applying producer + consumer Jobs"
kubectl --context "$CTX" -n "$NAMESPACE" delete job omb-producer omb-consumer \
  --ignore-not-found >/dev/null 2>&1
kubectl --context "$CTX" -n "$NAMESPACE" apply \
  -f "$REPO_ROOT/omb/producer-job.yaml" \
  -f "$REPO_ROOT/omb/consumer-job.yaml" | sed 's/^/  /'

cat >&2 <<EOF

============================================================
  OMB workload running on $CTX (namespace: $NAMESPACE)
============================================================

  Target rate: ~30 MB/s (7680 msg/s × 4 KiB)
  Topic:       load-test (partitions=$PARTITIONS, replicas=$REPLICAS)

  Tail produce throughput:
    kubectl --context $CTX -n $NAMESPACE logs -f job/omb-producer

  Tail consume throughput:
    kubectl --context $CTX -n $NAMESPACE logs -f job/omb-consumer

  Stop the workload:
    kubectl --context $CTX -n $NAMESPACE delete \\
      -f $REPO_ROOT/omb/producer-job.yaml \\
      -f $REPO_ROOT/omb/consumer-job.yaml

  Watch in Console (after install-console.sh) under Topics → load-test,
  or in Grafana under the Redpanda dashboard's "throughput" panels.
EOF
