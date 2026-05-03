#!/usr/bin/env bash
# scripts/install-console.sh — apply the Console CR and print the URL.
#
# The Console is managed by the Redpanda Operator via a
# cluster.redpanda.com/v1alpha2 Console CR (see console/console.yaml).
# The operator reconciles the Deployment + Service + ConfigMap from the
# CR; this script just applies the CR, waits for the operator-managed
# LoadBalancer Service to come up, and prints the URL.
#
# We deploy on rp-aws (the controller-pinned home region — Admin API
# round-trips stay local). The operator's flat-mode EndpointSlices put
# every peer broker pod IP into the headless `redpanda` Service on this
# cluster, so this single Console covers all 5 brokers across the 3
# clouds.
#
# Usage:
#   ./scripts/install-console.sh
#
# Env (optional):
#   CTX        — kube-context (default: rp-aws)
#   NAMESPACE  — Console namespace (default: redpanda — must match the
#                StretchCluster's namespace; the operator's clusterRef
#                lookup is namespace-scoped)
#   CONSOLE_NAME — Console CR name (default: redpanda-console)
#
# Output:
#   Console URL (LB hostname or IP) on stderr. No login by default
#   (Console OSS — demo posture).

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CTX=${CTX:-rp-aws}
NAMESPACE=${NAMESPACE:-redpanda}
CONSOLE_NAME=${CONSOLE_NAME:-redpanda-console}

log() { echo "[install-console] $*" >&2; }

require_cli() {
  command -v kubectl >/dev/null 2>&1 || { echo "missing CLI: kubectl" >&2; exit 1; }
}

require_cli

log "applying Console CR (kind: Console.cluster.redpanda.com) on $CTX"
kubectl --context "$CTX" apply -f "$REPO_ROOT/console/console.yaml" | sed 's/^/  /'

# The operator-managed Service inherits the CR name. Older operator
# releases sometimes drop spec.service.annotations on the way through —
# patch them onto the Service directly so we get an NLB on AWS rather
# than a classic ELB.
log "waiting up to 60s for the operator to create the $CONSOLE_NAME Service"
for _ in $(seq 1 30); do
  if kubectl --context "$CTX" -n "$NAMESPACE" get svc "$CONSOLE_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if kubectl --context "$CTX" -n "$NAMESPACE" get svc "$CONSOLE_NAME" >/dev/null 2>&1; then
  log "ensuring NLB annotations are set on $CONSOLE_NAME Service (idempotent)"
  kubectl --context "$CTX" -n "$NAMESPACE" annotate svc "$CONSOLE_NAME" \
    service.beta.kubernetes.io/aws-load-balancer-type=nlb \
    service.beta.kubernetes.io/aws-load-balancer-scheme=internet-facing \
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type=ip \
    --overwrite >/dev/null
fi

log "waiting for the Console LoadBalancer to receive a public hostname (max 5m)"
url=""
for _ in $(seq 1 60); do
  hostname=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc "$CONSOLE_NAME" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  ip=$(kubectl --context "$CTX" -n "$NAMESPACE" get svc "$CONSOLE_NAME" \
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

  Mode:   Operator-managed (Console CR — cluster.redpanda.com/v1alpha2)
  URL:    ${url:-<LB pending — re-check: kubectl --context $CTX -n $NAMESPACE get svc $CONSOLE_NAME>}
  Auth:   none (Console OSS — demo posture)

  Console points at the cross-cloud StretchCluster via clusterRef →
  the operator derives Kafka / Admin API / Schema Registry endpoints +
  TLS + auth from the StretchCluster automatically. Topic / partition /
  broker / consumer-group views span all 3 clouds.

  Hint:   open Topics → load-test (after install-omb.sh) to watch
          the OMB workload land in real time.
EOF
