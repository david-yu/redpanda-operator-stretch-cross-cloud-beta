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
  # Demo addons live on rp-aws only; safe to attempt on every context (no-op
  # if the release doesn't exist). Doing this BEFORE the redpanda operator
  # uninstall frees the LBs (Console NLB, Grafana NLB) so the AWS sweep at
  # the end has fewer ENIs to chase, AND lets the operator reconcile the
  # Console CR's deletion (Deployment + Service teardown) before its own
  # uninstall.
  kubectl --context "$ctx" -n redpanda delete -f "$REPO_ROOT/console/console.yaml" \
    --ignore-not-found 2>/dev/null || true
  helm --kube-context "$ctx" uninstall monitoring -n monitoring 2>/dev/null || true
  kubectl --context "$ctx" -n redpanda delete -f "$REPO_ROOT/omb/producer-job.yaml" \
    -f "$REPO_ROOT/omb/consumer-job.yaml" --ignore-not-found 2>/dev/null || true
  kubectl --context "$ctx" delete namespace monitoring --ignore-not-found 2>/dev/null || true

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
    # Cilium clustermesh-apiserver Service type=LoadBalancer creates
    # *classic* ELBs (ELBv1) — `aws elbv2 describe-load-balancers` does
    # not return these. Sweep ELBv1 first by their k8s ownership tag so
    # leftover ENIs don't block VPC delete.
    log "$r: sweep orphan classic ELBs (cilium clustermesh / k8s service)"
    for name in $(aws elb describe-load-balancers --region "$r" \
      --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null); do
      [[ -z "$name" ]] && continue
      tagged=$(aws elb describe-tags --region "$r" --load-balancer-names "$name" \
        --query 'TagDescriptions[0].Tags[?starts_with(Key, `kubernetes.io/cluster/`)] | length(@)' \
        --output text 2>/dev/null || echo 0)
      if [[ "$tagged" != "0" && "$tagged" != "" && "$tagged" != "None" ]]; then
        aws elb delete-load-balancer --region "$r" --load-balancer-name "$name" 2>/dev/null \
          && log "  deleted classic elb: $name" || true
      fi
    done
    # Sweep NLBs by ownership tag, NOT by name. Earlier versions of this
    # sweep filtered on `k8s-redpanda*` / `k8s-clusterm*` / `k8s-rpaws*`
    # name prefixes, but AWS LBC assigns LBs randomized UUID-style names
    # like `abd25f37edff94e4581e8c4a933c0353` for Service objects whose
    # name + namespace combo doesn't naturally fit the prefix scheme.
    # Console / Grafana / any user-named LoadBalancer Service in this
    # repo's demo addons fell into that bucket and leaked through the
    # name-pattern filter, leaving `ela-attach` ENIs that blocked the
    # subnet/VPC destroy for 13+ min. Tag-based selection catches all
    # k8s-managed LBs unconditionally. Drift caught 2026-05-03.
    log "$r: sweep orphan NLBs (by kubernetes.io/cluster/rp-aws tag)"
    for arn in $(aws elbv2 describe-load-balancers --region "$r" \
      --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null); do
      [[ -z "$arn" ]] && continue
      tagged=$(aws elbv2 describe-tags --region "$r" --resource-arns "$arn" \
        --query 'TagDescriptions[0].Tags[?starts_with(Key, `kubernetes.io/cluster/`)] | length(@)' \
        --output text 2>/dev/null || echo 0)
      if [[ "$tagged" != "0" && "$tagged" != "" && "$tagged" != "None" ]]; then
        aws elbv2 delete-load-balancer --region "$r" --load-balancer-arn "$arn" 2>/dev/null \
          && log "  deleted nlb: $arn" || true
      fi
    done
    # ela-attach ENIs (NLB-managed) refuse manual detach with
    # `OperationNotPermitted: You are not allowed to manage 'ela-attach'
    # attachments` — they only release when the owning NLB is fully
    # deleted, which takes AWS 2-5 min after the delete-load-balancer
    # call returns. Poll for ENI release before we continue, capped
    # at 5 min so a stuck delete doesn't hang the whole teardown.
    log "$r: wait up to 5min for NLB-managed (ela-attach) ENIs to release"
    for _ in 1 2 3 4 5; do
      remaining=$(aws ec2 describe-network-interfaces --region "$r" \
        --query 'NetworkInterfaces[?Attachment.InstanceOwnerId==`amazon-elb` && contains(Description, `ELB`)].NetworkInterfaceId' \
        --output text 2>/dev/null | wc -w)
      [[ "$remaining" == "0" ]] && break
      log "  $remaining ela-attach ENI(s) still in-use, waiting 60s..."
      sleep 60
    done

    # After NLB delete + propagation, sweep any remaining ENIs (EKS
    # control-plane, leftover instance-attached, etc.).
    log "$r: force-detach + delete ELB/EKS ENIs (don't wait 5-10min for AWS)"
    for eni in $(aws ec2 describe-network-interfaces --region "$r" \
      --query 'NetworkInterfaces[?contains(Description, `ELB`) || contains(Description, `EKS`)].NetworkInterfaceId' \
      --output text 2>/dev/null); do
      attach_id=$(aws ec2 describe-network-interfaces --region "$r" --network-interface-ids "$eni" \
        --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null)
      if [[ -n "$attach_id" && "$attach_id" != "None" ]]; then
        aws ec2 detach-network-interface --region "$r" --attachment-id "$attach_id" --force 2>/dev/null \
          && log "  detached eni: $eni" || true
      fi
      aws ec2 delete-network-interface --region "$r" --network-interface-id "$eni" 2>/dev/null \
        && log "  deleted eni: $eni" || true
    done
    log "$r: sweep orphan k8s-* security groups"
    for sg in $(aws ec2 describe-security-groups --region "$r" \
      --filters 'Name=group-name,Values=k8s-redpanda*,k8s-traffic*,k8s-clusterm*,k8s-rpaws*,k8s-elb*' \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
      aws ec2 delete-security-group --region "$r" --group-id "$sg" 2>/dev/null \
        && log "  deleted sg: $sg" || true
    done
    # AWS customer gateways live in aws/, but they're created by
    # vpn/terraform's `aws_customer_gateway.{gcp,azure}` against the
    # AWS provider. If vpn/ destroy fails (which the new phase-1 CLI
    # cleanup handles for the *connections*, but not for customer
    # gateways themselves), they stay around as $0 orphans. Sweep by
    # the rp-{gcp,azure}-cgw Name tag the VPN module sets.
    log "$r: sweep orphan customer gateways (rp-*-cgw tagged)"
    for cgw in $(aws ec2 describe-customer-gateways --region "$r" \
      --query 'CustomerGateways[?Tags[?Key==`Name` && (Value==`rp-gcp-cgw` || Value==`rp-azure-cgw`)] && State==`available`].CustomerGatewayId' \
      --output text 2>/dev/null); do
      [[ -z "$cgw" ]] && continue
      aws ec2 delete-customer-gateway --region "$r" --customer-gateway-id "$cgw" 2>/dev/null \
        && log "  deleted cgw: $cgw" || true
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

# IMPORTANT ordering: the cross-cloud VPN connections must be destroyed
# BEFORE the per-cloud TFs. The VPN module holds the
# azurerm_virtual_network_gateway_connection / aws_vpn_connection /
# google_compute_vpn_tunnel resources that reference the per-cloud
# gateways. If we go straight to per-cloud destroys, AWS subnet delete
# fails (the VGW is still attached to live VPN connections), GCP router
# delete fails (still in use by tunnels), and Azure VPN GW delete fails
# (still attached to a connection) — the classic 3-way circular dep
# that needs operator intervention to break.
#
# Two-phase strategy: first delete the cross-cloud connections via cloud
# CLI (idempotent, can't hit TF state / refresh / var-passthrough
# failure modes), then run the TF-based vpn/terraform destroy as a
# state-cleanup pass. Belt-and-braces — even if vpn/terraform destroy
# fails, the per-cloud destroys are already unblocked because the live
# connections are gone.
log "=== phase 1: delete cross-cloud VPN connections via cloud CLI ==="
log "  AWS — delete VPN connections by Name tag"
for vpn_id in $(aws ec2 describe-vpn-connections --region us-east-1 \
  --query 'VpnConnections[?Tags[?Key==`Name` && (Value==`to-rp-azure` || Value==`to-rp-gcp`)] && State==`available`].VpnConnectionId' \
  --output text 2>/dev/null); do
  [[ -z "$vpn_id" ]] && continue
  aws ec2 delete-vpn-connection --region us-east-1 --vpn-connection-id "$vpn_id" 2>/dev/null \
    && log "    deleted aws vpn-connection: $vpn_id" || true
done
log "  GCP — delete VPN tunnels"
for t in to-rp-aws to-rp-azure-a to-rp-azure-b; do
  gcloud compute vpn-tunnels delete "$t" --region us-east1 \
    --project "$GCP_PROJECT" --quiet 2>/dev/null \
    && log "    deleted gcp vpn-tunnel: $t" || true
done
log "  GCP — delete orphan static routes (rp-gcp VPC blocked by these even after tunnel delete)"
for r in to-rp-aws-via-vpn to-rp-azure-via-vpn; do
  gcloud compute routes delete "$r" --project "$GCP_PROJECT" --quiet 2>/dev/null \
    && log "    deleted gcp route: $r" || true
done
log "  Azure — delete VPN connections (frees the virtual_network_gateway for delete)"
for c in to-rp-aws to-rp-gcp; do
  az network vpn-connection delete --resource-group rp-aws-cross-cloud --name "$c" 2>/dev/null \
    && log "    deleted azure vpn-connection: $c" || true
done

log "=== phase 2: terraform destroy vpn/terraform (state cleanup; live connections already gone) ==="
AWS_VPC_ID=$(cd "$REPO_ROOT/aws/terraform" && terraform output -raw vpc_id 2>/dev/null || echo "")
AWS_VGW_ID=$(cd "$REPO_ROOT/aws/terraform" && terraform output -raw vpn_gateway_id 2>/dev/null || echo "")
AWS_RT_IDS_JSON=$(cd "$REPO_ROOT/aws/terraform" && terraform output -json public_route_table_ids 2>/dev/null || echo '[]')
GCP_NETWORK=$(cd "$REPO_ROOT/gcp/terraform" && terraform output -raw network_name 2>/dev/null || echo "")
GCP_ROUTER=$(cd "$REPO_ROOT/gcp/terraform" && terraform output -raw router_name 2>/dev/null || echo "")
GCP_HA_VPN_GW=$(cd "$REPO_ROOT/gcp/terraform" && terraform output -raw ha_vpn_gateway_self_link 2>/dev/null || echo "")
GCP_HA_IP_A=$(cd "$REPO_ROOT/gcp/terraform" && terraform output -raw ha_vpn_gateway_ip_a 2>/dev/null || echo "")
GCP_HA_IP_B=$(cd "$REPO_ROOT/gcp/terraform" && terraform output -raw ha_vpn_gateway_ip_b 2>/dev/null || echo "")
AZ_RG=$(cd "$REPO_ROOT/azure/terraform" && terraform output -raw resource_group 2>/dev/null || echo "")
AZ_VPN_GW_ID=$(cd "$REPO_ROOT/azure/terraform" && terraform output -raw vpn_gateway_id 2>/dev/null || echo "")
AZ_VPN_PIP=$(cd "$REPO_ROOT/azure/terraform" && terraform output -raw vpn_gateway_public_ip 2>/dev/null || echo "")
AZ_VPN_BGP_IP=$(cd "$REPO_ROOT/azure/terraform" && terraform output -raw vpn_gateway_bgp_peering_address 2>/dev/null || echo "")

pushd "$REPO_ROOT/vpn/terraform" >/dev/null
terraform init -upgrade >/dev/null 2>&1 || true
if ! terraform destroy -auto-approve \
  -var "aws_region=us-east-1" \
  -var "aws_vpc_id=$AWS_VPC_ID" \
  -var "aws_vpc_cidr=10.10.0.0/16" \
  -var "aws_route_table_ids=$AWS_RT_IDS_JSON" \
  -var "aws_vpn_gateway_id=$AWS_VGW_ID" \
  -var "gcp_project_id=$GCP_PROJECT" \
  -var "gcp_region=us-east1" \
  -var "gcp_network_name=$GCP_NETWORK" \
  -var "gcp_subnet_cidr=10.20.0.0/16" \
  -var "gcp_router_name=$GCP_ROUTER" \
  -var "gcp_ha_vpn_gateway_self_link=$GCP_HA_VPN_GW" \
  -var "gcp_ha_vpn_gateway_ip_a=$GCP_HA_IP_A" \
  -var "gcp_ha_vpn_gateway_ip_b=$GCP_HA_IP_B" \
  -var "azure_resource_group_name=$AZ_RG" \
  -var "azure_location=eastus" \
  -var "azure_vnet_cidr=10.30.0.0/16" \
  -var "azure_vpn_gateway_id=$AZ_VPN_GW_ID" \
  -var "azure_vpn_gateway_public_ip=$AZ_VPN_PIP" \
  -var "azure_vpn_gateway_bgp_peering_address=$AZ_VPN_BGP_IP" \
  2>&1 | tail -10 | sed 's/^/  /'; then
  # vpn/terraform destroy can fail at TF refresh time when per-cloud
  # state outputs are empty (e.g., a partial-teardown re-run) or when
  # the per-cloud resources the VPN module references have been deleted
  # out from under it (which is exactly the case after phase 1's CLI
  # cleanup). Phase 1 already deleted the live cloud resources, so
  # falling back to `terraform state rm` for everything in vpn/terraform
  # is the right thing — there are no live resources left for TF to
  # destroy, just stale state entries that would otherwise block a
  # future re-apply. Per-cloud destroys (next step) don't depend on
  # vpn/terraform state at all, so they aren't affected.
  log "  vpn/terraform destroy failed — clearing state entries (CLI cleanup in phase 1 already deleted the cloud resources)"
  for r in $(terraform state list 2>/dev/null); do
    terraform state rm "$r" 2>/dev/null | sed 's/^/    /' || true
  done
fi
popd >/dev/null

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
