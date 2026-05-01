#!/usr/bin/env bash
# scripts/teardown.sh — tear down the cross-cloud stretch stack cleanly.
#
# Walks the same ordering as the same-cloud beta's per-cloud teardown
# scripts but covers all three clouds:
#
#   1. Patch finalizers off NodePool / StretchCluster CRs on each cluster
#   2. Helm uninstall redpanda, operator, cert-manager
#   3. Force-finalize the redpanda namespace if it's stuck Terminating
#   4. cilium clustermesh disable (cleans up the public clustermesh-apiserver
#      LoadBalancer Services so no orphan cloud LBs leak)
#   5. Prune kubernetes_* / helm_release.* from each cloud's TF state
#      (avoids `context deadline exceeded` once the cluster is gone)
#   6. terraform destroy on each cloud's terraform/ directory
#   7. Cloud-specific orphan sweep (AWS NLBs/SGs/ENIs, Azure MC_* LBs)
#   8. Final terraform destroy pass to pick up anything the sweep unblocked
#   9. Clean rp-* kubectl contexts/clusters/users from kubeconfig
#
# Usage:
#   ./teardown.sh --gcp-project <id>
#
# Env:
#   AWS_PROFILE      — your AWS profile (already in env? skip)
#   AZURE_REGION     — for orphan sweep (default: eastus)
#   GCP_PROJECT      — alternative to --gcp-project
#
# Idempotent — safe to re-run after a partial failure.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

CONTEXTS=(rp-aws rp-gcp rp-azure)
TF_DIRS=(
  "$REPO_ROOT/aws/terraform"
  "$REPO_ROOT/gcp/terraform"
  "$REPO_ROOT/azure/terraform"
)

AWS_REGIONS=(${AWS_REGIONS:-us-east-1})
AZURE_REGION=${AZURE_REGION:-eastus}

GCP_PROJECT=${GCP_PROJECT:-}
while [[ $# -gt 0 ]]; do
  case $1 in
    --gcp-project) GCP_PROJECT=$2; shift 2 ;;
    -h|--help) sed -n '2,/^# Idempotent/p' "$0" | sed 's/^# *//;s/^#$//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$GCP_PROJECT" ]]; then
  echo "error: --gcp-project <id> is required (must match the GCP terraform's var.project_id)" >&2
  exit 2
fi

log() { echo "[teardown] $*" >&2; }

patch_finalizers() {
  local ctx=$1
  for r in $(kubectl --context "$ctx" -n redpanda get nodepool,stretchcluster -o name 2>/dev/null); do
    kubectl --context "$ctx" -n redpanda patch "$r" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' 2>/dev/null \
      | sed "s/^/  $ctx: /" || true
  done
}

helm_uninstall_all() {
  local ctx=$1
  helm --kube-context "$ctx" uninstall redpanda -n redpanda 2>/dev/null || true
  helm --kube-context "$ctx" uninstall "$ctx" -n redpanda 2>/dev/null || true
  helm --kube-context "$ctx" uninstall redpanda-operator -n redpanda 2>/dev/null || true
  helm --kube-context "$ctx" uninstall cert-manager -n cert-manager 2>/dev/null || true
}

force_finalize_ns() {
  local ctx=$1
  local ns=${2:-redpanda}
  kubectl --context "$ctx" get ns "$ns" 2>/dev/null | grep -q Terminating || return 0
  log "$ctx: ns/$ns stuck Terminating — force-finalizing"
  local port=$((RANDOM % 1000 + 18000))
  kubectl --context "$ctx" proxy --port=$port >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  curl -sX PUT -H 'Content-Type: application/json' \
    --data-binary "{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"$ns\"},\"spec\":{\"finalizers\":[]}}" \
    "http://localhost:$port/api/v1/namespaces/$ns/finalize" >/dev/null 2>&1 || true
  kill $pid 2>/dev/null
  wait 2>/dev/null
}

clustermesh_disable() {
  local ctx=$1
  cilium clustermesh disable --kube-context "$ctx" 2>/dev/null || true
}

tf_state_rm_k8s() {
  local dir=$1
  log "$dir: pruning kubernetes/helm resources from state"
  pushd "$dir" >/dev/null
  for r in $(terraform state list 2>/dev/null | grep -E '^(kubernetes_|helm_release\.)'); do
    terraform state rm "$r" 2>/dev/null | sed 's/^/  /' || true
  done
  popd >/dev/null
}

tf_destroy() {
  local dir=$1
  shift
  log "$dir: terraform destroy"
  pushd "$dir" >/dev/null
  terraform destroy -auto-approve "$@" 2>&1 | tail -5 | sed 's/^/  /'
  popd >/dev/null
}

# AWS orphan sweep — same logic as the same-cloud aws/scripts/teardown.sh.
aws_sweep() {
  for r in "$@"; do
    log "$r: sweep orphan NLBs"
    for arn in $(aws elbv2 describe-load-balancers --region "$r" \
      --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-redpanda`) || contains(LoadBalancerName, `k8s-clusterm`) || contains(LoadBalancerName, `k8s-rpaws`)].LoadBalancerArn' \
      --output text 2>/dev/null); do
      aws elbv2 delete-load-balancer --region "$r" --load-balancer-arn "$arn" 2>/dev/null \
        && log "  deleted nlb: $arn" || true
    done
    log "$r: sweep orphan k8s-* security groups"
    for sg in $(aws ec2 describe-security-groups --region "$r" \
      --filters 'Name=group-name,Values=k8s-redpanda*,k8s-traffic*,k8s-clusterm*,k8s-rpaws*' \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
      aws ec2 delete-security-group --region "$r" --group-id "$sg" 2>/dev/null \
        && log "  deleted sg: $sg" || true
    done
    log "$r: sweep available ENIs"
    for eni in $(aws ec2 describe-network-interfaces --region "$r" \
      --filters 'Name=status,Values=available' \
      --query 'NetworkInterfaces[?contains(Description, `ELB`) || contains(Description, `EKS`)].NetworkInterfaceId' \
      --output text 2>/dev/null); do
      aws ec2 delete-network-interface --region "$r" --network-interface-id "$eni" 2>/dev/null \
        && log "  deleted eni: $eni" || true
    done
  done
}

azure_sweep() {
  log "sweeping orphan LBs in MC_* resource groups"
  for rg in $(az group list --query "[?starts_with(name, 'MC_')].name" -o tsv 2>/dev/null); do
    for lb in $(az network lb list -g "$rg" --query '[].name' -o tsv 2>/dev/null); do
      az network lb delete -g "$rg" -n "$lb" --no-wait 2>/dev/null \
        && log "  deleted lb: $rg/$lb" || true
    done
  done
}

clean_kubectl() {
  local pattern=$1
  for c in $(kubectl config view -o jsonpath='{.contexts[*].name}' 2>/dev/null | tr ' ' '\n' | grep -E "$pattern"); do
    kubectl config delete-context "$c" 2>/dev/null || true
  done
  for n in $(kubectl config view -o jsonpath='{.clusters[*].name}' 2>/dev/null | tr ' ' '\n' | grep -E "$pattern"); do
    kubectl config delete-cluster "$n" 2>/dev/null || true
  done
  for n in $(kubectl config view -o jsonpath='{.users[*].name}' 2>/dev/null | tr ' ' '\n' | grep -E "$pattern"); do
    kubectl config delete-user "$n" 2>/dev/null || true
  done
}

###################
# Main flow
###################

log "=== k8s pre-cleanup ==="
for ctx in "${CONTEXTS[@]}"; do patch_finalizers   "$ctx"; done
for ctx in "${CONTEXTS[@]}"; do helm_uninstall_all "$ctx"; done
for ctx in "${CONTEXTS[@]}"; do force_finalize_ns  "$ctx"; done

log "=== disable clustermesh on each cluster ==="
for ctx in "${CONTEXTS[@]}"; do clustermesh_disable "$ctx"; done

log "=== terraform destroy each cloud ==="
tf_state_rm_k8s "$REPO_ROOT/aws/terraform"
tf_destroy      "$REPO_ROOT/aws/terraform"
tf_state_rm_k8s "$REPO_ROOT/gcp/terraform"
tf_destroy      "$REPO_ROOT/gcp/terraform" -var "project_id=$GCP_PROJECT"
tf_state_rm_k8s "$REPO_ROOT/azure/terraform"
tf_destroy      "$REPO_ROOT/azure/terraform"

log "=== post-destroy cloud sweeps ==="
aws_sweep "${AWS_REGIONS[@]}"
azure_sweep

log "=== final terraform destroy pass ==="
tf_destroy "$REPO_ROOT/aws/terraform"
tf_destroy "$REPO_ROOT/gcp/terraform" -var "project_id=$GCP_PROJECT"
tf_destroy "$REPO_ROOT/azure/terraform"

log "=== kubectl cleanup ==="
clean_kubectl 'rp-(aws|gcp|azure)$'

log "done"
