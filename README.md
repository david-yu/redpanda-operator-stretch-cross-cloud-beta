# Redpanda Stretch Cluster Across AWS / GCP / Azure with Cilium ClusterMesh + Site-to-Site VPN

Validation scaffold for a Redpanda Operator v26.2.1+ StretchCluster that **spans three different cloud providers** — one Kubernetes cluster on each of AWS EKS, GCP GKE, and Azure AKS, connected into a single Cilium ClusterMesh.

Companion to [`redpanda-operator-stretch-beta`](https://github.com/david-yu/redpanda-operator-stretch-beta) (single-cloud, three-region). Where the same-cloud beta uses the cloud's native L3 mesh (AWS TGW, GCP global VPC, Azure VNet peering), this repo uses **a 3-way mesh of site-to-site IPsec VPNs (BGP-routed) + Cilium ClusterMesh on top**, so node InternalIPs are routable across cloud boundaries and Cilium's clustermesh data plane works without modification.

> [!IMPORTANT]
> **Current validation state (2026-05-01)** — the infrastructure layers are working end-to-end; the broker-cluster bootstrap is the remaining open issue.
>
> | Layer | State |
> |---|---|
> | Per-cloud Terraform (EKS / GKE / AKS) | ✅ Apply clean |
> | Cross-cloud IPsec VPN mesh | ✅ Established (switched to **static routes** — BGP convergence is fragile across these clouds, see `vpn/terraform/`) |
> | Cilium ClusterMesh (control plane + KVStoreMesh) | ✅ All 3 clusters fully connected |
> | Intra-cluster pod-to-pod networking | ✅ (after AWS node-SG self-rule fix in `aws/terraform/eks.tf`) |
> | EBS CSI driver + PVC binding on AWS | ✅ |
> | cert-manager webhook on EKS | ✅ (after `hostNetwork: true` + `securePort=10260` patch — see Step 6) |
> | Multi-cluster operator + raft mesh (`rpk k8s multicluster status`) | ✅ |
> | Shared CA across all 3 clusters (`scripts/bootstrap-shared-ca.sh`) | ✅ |
> | StretchCluster + NodePool CRs applied, broker pods Running | ✅ (5 brokers, 0 crashes after PVC wipe) |
> | Brokers form quorum & become `Ready` | ❌ `cluster_bootstrap_info` RPC fails with `rpc::errc:4` / `Broken pipe` immediately after a successful TLS handshake. Investigation in progress; likely either (a) a SAN-vs-`advertised_rpc_api`-hostname mismatch, or (b) a Redpanda 26.1.6 stretch-cluster-bootstrap RPC interaction we haven't isolated. |
>
> **Why the VPN tier exists** — without it, the stack hits two open upstream Cilium issues that prevent cross-cloud clustermesh data plane from establishing:
>
> - **[cilium#24403](https://github.com/cilium/cilium/issues/24403)** — Cilium picks node `InternalIP` for clustermesh tunnel endpoints, but cross-cloud nodes are only reachable via `ExternalIP` without a VPN. AWS pods try to send traffic to GCP nodes' private `10.20.x.x`, which doesn't route across the WAN.
> - **[cilium#31209](https://github.com/cilium/cilium/issues/31209)** — Tunnel + KubeProxyReplacement + WireGuard nodeEncryption combination causes asymmetric initial-connect routing.
>
> The VPN tier sidesteps both: InternalIPs become mutually routable across clouds (fixes #24403), and we drop WireGuard nodeEncryption since IPsec already encrypts the underlay (fixes #31209). The original BGP-routed VPN scaffold didn't converge cleanly; we switched to **static routes** (per [this devgenius.io guide](https://blog.devgenius.io/lessons-from-connecting-gcp-and-aws-with-a-site-to-site-vpn-d5e0d27ec03c)) and that works.

## How it differs from the same-cloud beta

| | Same-cloud beta | This repo |
|---|---|---|
| Topology | 3 regions × 1 cloud | 3 clouds × 1 region each |
| K8s clusters | 3 EKS / 3 GKE / 3 AKS | 1 EKS + 1 GKE + 1 AKS |
| CNI | Cloud default (AWS VPC CNI, GKE Dataplane V2, Azure CNI) | **Cilium** (replacing each cloud's default) |
| L3 mesh | AWS TGW / GCP global VPC / Azure VNet peering | **Site-to-site IPsec VPN** (3-way mesh, BGP-routed) + **Cilium ClusterMesh** on top |
| Cross-cluster service discovery | Operator's `crossClusterMode: flat` (manages headless Services + EndpointSlices) | Same — Cilium provides the pod-IP routing layer underneath |
| Operator-to-operator raft | Public NLB / internal LB per cluster, port 9443 | Same |
| Broker count | 2/2/1 = 5 (RF=5) | 2/2/1 = 5 (RF=5) |

## Architecture

```
   ┌───────── 3-way mesh of site-to-site IPsec VPN tunnels (BGP-routed) ─────────┐
   │     - aws_vpn_gateway   ↔ google_compute_ha_vpn_gateway   ↔ azurerm_vpn_gw  │
   │     - VPC / VNet CIDRs propagated as BGP routes between every pair          │
   │     - InternalIP-to-InternalIP across clouds → routable                     │
   └─────────────────────────────────────────────────────────────────────────────┘
                                    ▲           ▲           ▲
                                    │           │           │
   ┌────────── AWS us-east-1 ──────┴┐  ┌── GCP us-east1 ──┴┐  ┌── Azure eastus ──┴┐
   │ EKS: rp-aws         cluster.id=1│  │ GKE: rp-gcp       │  │ AKS: rp-azure     │
   │   • CNI: Cilium (no aws-vpc-cni)│  │   • CNI: Cilium   │  │   • CNI: Cilium   │
   │   • pod CIDR 10.110.0.0/16     │  │   (no DPv2)        │  │   (BYOCNI)        │
   │   • VPC 10.10.0.0/16            │  │   • VPC 10.20.0/16 │  │   • VNet 10.30/16 │
   │   • 2× m5.xlarge nodes          │  │   • 2× n2-std-4    │  │   • 2× D4s_v5     │
   │   • 2 broker pods (rack=aws)    │  │   • 2 brokers      │  │   • 1 broker      │
   └─────────────────────────────────┘  │     (rack=gcp)     │  │     (rack=azure)  │
                                        └────────────────────┘  └───────────────────┘
                       brokers, 2 / 2 / 1 — RF=5 quorum survives any single cloud loss
```

Each cluster runs Cilium with:
- `kubeProxyReplacement=true` — eBPF replaces kube-proxy entirely
- `routingMode=tunnel`, `tunnelProtocol=geneve` — pod-to-pod over Geneve, encapsulated to peer node InternalIPs
- **No** `encryption.nodeEncryption=true` — the underlying VPN already IPsec-encrypts the traffic, and the WireGuard combo triggers cilium#31209 in this exact config
- `clustermesh-apiserver` exposed via `Service: type=LoadBalancer` per cluster, mTLS-secured

The Redpanda multicluster operator runs in flat networking mode and creates per-peer headless Services + EndpointSlices on each cluster. Brokers reach peer brokers via cross-cluster pod IPs, which Cilium encapsulates over peer node InternalIPs — and those InternalIPs are routable thanks to the VPN BGP mesh.

## Repo layout

```
.
├── aws/
│   ├── terraform/              # EKS without aws-vpc-cni addon + aws_vpn_gateway
│   ├── manifests/              # StretchCluster CR
│   └── helm-values/            # values-rp-aws.example.yaml
├── gcp/
│   ├── terraform/              # GKE without DPv2 + ha_vpn_gateway + cloud router
│   ├── manifests/
│   └── helm-values/
├── azure/
│   ├── terraform/              # AKS BYOCNI + virtual_network_gateway (VPN GW)
│   ├── manifests/
│   └── helm-values/
├── vpn/
│   └── terraform/              # 3-way mesh of IPsec tunnels + BGP peers (multi-cloud TF root)
└── scripts/
    ├── install-cilium.sh       # per-cloud Cilium install
    ├── connect-mesh.sh         # enable + connect 3-way Cilium ClusterMesh
    ├── apply-vpn.sh            # collects per-cloud TF outputs and applies vpn/terraform
    ├── bootstrap-redpanda.sh   # cert-manager + license secret + node annotations
    └── teardown.sh             # full multi-cloud teardown
```

## Prerequisites

- Cloud CLIs authenticated: `aws sts get-caller-identity`, `gcloud auth list`, `az account show`
- `terraform` ≥ 1.6, `kubectl` ≥ 1.28, `helm` ≥ 3.14
- [`cilium` CLI](https://github.com/cilium/cilium-cli) ≥ 0.16 (`cilium version`)
- A Redpanda Enterprise license file (the operator + multicluster features require it)
- A GCP project ID with the `container.googleapis.com` and `compute.googleapis.com` APIs enabled

## Step-by-step

The flow is:

1. **Apply per-cloud Terraform** (clusters + VPN gateways). VPN gateway creation alone is slow on Azure (~30-45 min for `azurerm_virtual_network_gateway`), so kick off all three in parallel.
2. **Apply `vpn/terraform/`** — wires the 3-way mesh of IPsec tunnels with BGP. Reads each cloud's outputs.
3. **Verify VPN connectivity** — node-internal-IP pings cross-cloud should succeed.
4. **Install Cilium** on each cluster.
5. **Connect Cilium ClusterMesh** between the three clusters.
6. **Bootstrap Redpanda** (cert-manager, license secret, node annotations).
7. **Install operator + StretchCluster** with peer LB lookups.

### 1. Bring up the three clusters + VPN gateways

Each cloud's Terraform brings up a Kubernetes cluster with **no CNI installed** plus the cloud's VPN gateway (no peer connections yet — those come from `vpn/terraform/` in step 2). Nodes report `NotReady` until you install Cilium in step 4 — that's expected.

```bash
# AWS — ~12-15 min for EKS + VGW
cd aws/terraform
terraform init
terraform apply
# (record the kubectl_setup_command output and run it)

# GCP — ~10-15 min for GKE + HA VPN
cd ../../gcp/terraform
terraform init
terraform apply -var project_id=<your-gcp-project>
# (record + run kubectl_setup_command)

# Azure — ~5 min for AKS, then ~30-45 min for VPN GW (azurerm_virtual_network_gateway is just slow)
cd ../../azure/terraform
terraform init
terraform apply
# (record + run kubectl_setup_command)
```

Run all three in parallel terminals if you want to save time — they have no dependency on each other yet.

### 2. Wire the cross-cloud IPsec VPN mesh

```bash
./scripts/apply-vpn.sh
```

This collects per-cloud TF outputs (VGW IDs, HA VPN IPs, Azure VPN GW public IP, ASNs, route table IDs, etc.) and applies `vpn/terraform/` which:

- Generates 3 IPsec PSKs (one per pair, persisted in the VPN module's TF state)
- AWS side: `aws_customer_gateway` and `aws_vpn_connection` for each peer (GCP, Azure); enables BGP route propagation back into the AWS VPC route tables.
- GCP side: `google_compute_external_vpn_gateway` and `google_compute_vpn_tunnel` to each peer (AWS, Azure); BGP peer config on the existing Cloud Router.
- Azure side: `azurerm_local_network_gateway` and `azurerm_virtual_network_gateway_connection` to each peer (AWS, GCP).

After this completes, BGP advertises:
- AWS VPC CIDR (`10.10.0.0/16`) is reachable from GCP and Azure
- GCP subnet CIDR (`10.20.0.0/16`) is reachable from AWS and Azure
- Azure VNet CIDR (`10.30.0.0/16`) is reachable from AWS and GCP

### 3. Verify VPN connectivity

From a hostNetwork pod on rp-aws, ping a node InternalIP on rp-gcp:

```bash
gcp_node_internal_ip=$(kubectl --context rp-gcp get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
kubectl --context rp-aws run -i --rm test --image=alpine:3.20 --restart=Never --overrides='{"spec":{"hostNetwork":true}}' -- \
  sh -c "apk add -q iputils 2>/dev/null; ping -c 3 -W 5 $gcp_node_internal_ip"
```

If this succeeds, the VPN tier is healthy. If it times out, BGP routes haven't propagated yet (normal for the first ~30s after `apply-vpn.sh`) or there's an IPsec tunnel issue (`aws ec2 describe-vpn-connections` and `gcloud compute vpn-tunnels list`).

### 4. Install Cilium on each cluster

```bash
./scripts/install-cilium.sh all
```

This runs three `cilium install` invocations with cloud-specific flags:

- **AWS** — `eni.enabled=false`, `ipam.mode=cluster-pool`, pod CIDR `10.110.0.0/16`. Cilium owns IP allocation entirely; AWS VPC CNI is never installed.
- **GCP** — `ipam.mode=kubernetes`. Cilium uses GKE's per-node `spec.podCIDR` (each node gets a /24 from the pods secondary range). NB the script temporarily renames the kube-context back to its original `gke_<project>_<region>_rp-gcp` form because cilium-cli derives region/zone from the context name on GKE — see [Known issues](#known-issues).
- **Azure** — `aksbyocni.enabled=true`, `ipam.mode=cluster-pool`, pod CIDR `10.130.0.0/16`. AKS came up with `--network-plugin none`, so Cilium installs into a fully empty CNI slot.

All three set `kubeProxyReplacement=true` (eBPF replaces kube-proxy) and `routingMode=tunnel` (Geneve). We do **not** enable `encryption.nodeEncryption=wireguard` here — the underlying VPN already IPsec-encrypts traffic, and adding WireGuard on top triggers cilium#31209.

After the script returns, `cilium status --context rp-aws` should report `OK` and `kubectl --context rp-aws get nodes` should show all nodes `Ready`. Repeat for `rp-gcp` and `rp-azure`.

### 5. Wire the three clusters into a Cilium ClusterMesh

```bash
./scripts/connect-mesh.sh all
```

This runs:
1. `cilium clustermesh enable --service-type LoadBalancer` on each cluster (provisions a public LB for `clustermesh-apiserver` on port 2379, mTLS-secured)
2. Re-issues each cluster's `clustermesh-apiserver-server-cert` with both `serverAuth` and `clientAuth` Extended Key Usages, then rolls the apiserver deployment. Workaround for [cilium#43099](https://github.com/cilium/cilium/issues/43099) — the helm-shipped server cert only carries `serverAuth`, and KVStoreMesh fails peer auth as a TLS *client* with `unknown certificate authority`. **Fixed upstream in [cilium#43230](https://github.com/cilium/cilium/pull/43230) (merged Dec 2025), included in 1.20.0-pre.1; once 1.20.0 GA ships we can pin to it and delete `patch_server_cert_clientauth()` from `connect-mesh.sh`.**
3. `cilium clustermesh connect --allow-mismatching-ca` for each pair (aws↔gcp, aws↔azure, gcp↔azure)
4. `cilium clustermesh status` on each cluster

Connectivity is established when `cilium clustermesh status` shows `2 / 2 remote clusters connected` on every cluster. Pod-to-pod traffic across clouds flows through Cilium's Geneve tunnel encapsulated to peer node InternalIPs (which are routable thanks to step 2's VPN mesh).

To verify pod-IP routing across clouds:

```bash
kubectl --context rp-aws run -i --tty --rm test --image=nicolaka/netshoot --restart=Never -- \
  ping -c 3 <pod-IP-from-rp-gcp>
```

### 6. Bootstrap Redpanda prerequisites

```bash
./scripts/bootstrap-redpanda.sh --license /path/to/redpanda.license
./scripts/bootstrap-shared-ca.sh
```

`bootstrap-redpanda.sh` installs cert-manager on each cluster, annotates every node with `redpanda.com/cloud=<aws|gcp|azure>` (so the operator's rack awareness picks the right rack), and creates the `redpanda` namespace + `redpanda-license` secret.

`bootstrap-shared-ca.sh` generates **one** P-256 root CA and applies the same Secret + cert-manager Issuer (`redpanda-shared-ca-issuer`) in every cluster's `redpanda` namespace. The StretchCluster manifests below point `tls.certs.default.issuerRef` at that issuer, so cert-manager mints per-broker leaves signed by the **same** root in every cloud — required for inter-broker TLS to verify peers across clusters. Without it, each cluster's cert-manager mints a different self-signed CA and inter-broker handshakes fail with `SSL routines::packet length too long` / `record layer failure`.

**cert-manager webhook on EKS + Cilium**: cert-manager's webhook listens on port 10250 by default, which collides with kubelet on every node. EKS' API server then short-circuits the webhook with `Address is not allowed`. Per [cert-manager#403](https://github.com/cert-manager/website/issues/403) and the [EKS-Cilium thread on Stack Overflow](https://stackoverflow.com/questions/72548056/cert-manager-clusterissuer-undefined-on-eks-cluster-with-cilium-installed-as-cni), patch the webhook deployment to `hostNetwork: true` + `--secure-port=10260`, point the Service `targetPort` at `10260`, and authorize TCP/10260 from the EKS cluster SG → node SG. We patch the running deployment after `bootstrap-redpanda.sh` rather than re-deploying through the Jetstack chart because the helm values schema in v1.16.2 is older than the current docs:

```bash
for ctx in rp-aws rp-gcp rp-azure; do
  kubectl --context $ctx -n cert-manager patch deploy cert-manager-webhook --type=json -p '[
    {"op":"replace","path":"/spec/template/spec/hostNetwork","value":true},
    {"op":"add","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirstWithHostNet"},
    {"op":"replace","path":"/spec/template/spec/containers/0/args/1","value":"--secure-port=10260"},
    {"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":10260}
  ]'
  kubectl --context $ctx -n cert-manager patch svc cert-manager-webhook --type=merge \
    -p '{"spec":{"ports":[{"name":"https","port":443,"protocol":"TCP","targetPort":10260}]}}'
done
```

### 7. Install the operator + apply StretchCluster on each cluster

The operator's `multicluster.peers` block lists the public LB hostname/IP of every cluster's `<name>-multicluster-peer` Service plus each cluster's K8s API server endpoint — so this is a **two-pass install**:

**Pass 1**: helm-install the operator with placeholder peers so it stands up and `rpk k8s multicluster bootstrap --loadbalancer` can then provision the peer LB Services. The chart in `redpanda-data/operator @ 26.2.1-beta.1` requires `multicluster.peers` to be set even on the first install, so we feed in three placeholder entries:

```bash
helm repo add redpanda-data https://charts.redpanda.com
helm repo update

cat > /tmp/values-pass1.yaml <<EOF
crds:
  enabled: true
multicluster:
  enabled: true
  name: PLACEHOLDER
  apiServerExternalAddress: PLACEHOLDER
  peers:
    - name: rp-aws
      address: placeholder.local
    - name: rp-gcp
      address: placeholder.local
    - name: rp-azure
      address: placeholder.local
EOF

RP_AWS_API=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="arn:aws:eks:us-east-1:605419575229:cluster/rp-aws")].cluster.server}')
RP_GCP_API="https://$(gcloud container clusters describe rp-gcp --region us-east1 --format 'value(endpoint)'):443"
RP_AZURE_API="https://$(az aks show -g rp-aws-cross-cloud -n rp-azure --query fqdn -o tsv):443"

for ctx in rp-aws rp-gcp rp-azure; do
  case $ctx in rp-aws) api=$RP_AWS_API ;; rp-gcp) api=$RP_GCP_API ;; rp-azure) api=$RP_AZURE_API ;; esac
  helm --kube-context $ctx upgrade --install $ctx redpanda-data/operator \
    -n redpanda --version 26.2.1-beta.1 \
    --set fullnameOverride=$ctx \
    --set multicluster.name=$ctx \
    --set multicluster.apiServerExternalAddress=$api \
    -f /tmp/values-pass1.yaml
done
```

Then provision the peer LB Services and bootstrap operator-mTLS in one shot:

```bash
rpk k8s multicluster bootstrap \
  --context rp-aws --context rp-gcp --context rp-azure \
  --namespace redpanda \
  --loadbalancer
```

This prints back the exact `multicluster.peers` block (with each cluster's LB hostname/IP) ready to paste into your values files.

**Pass 2**: fill the printed peer addresses + K8s API endpoints into your per-cloud `helm-values/values-rp-<cloud>.example.yaml`, and `helm upgrade`.

```bash
# AWS endpoints
RP_AWS_API=$(aws eks describe-cluster --region us-east-1 --name rp-aws --query cluster.endpoint --output text)
RP_AWS_LB=$(kubectl --context rp-aws -n redpanda get svc rp-aws-multicluster-peer -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# GCP endpoints
RP_GCP_API="https://$(gcloud container clusters describe rp-gcp --region us-east1 --format 'value(endpoint)'):443"
RP_GCP_LB=$(kubectl --context rp-gcp -n redpanda get svc rp-gcp-multicluster-peer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Azure endpoints
RP_AZURE_API="https://$(az aks show -g rp-aws-cross-cloud -n rp-azure --query fqdn -o tsv):443"
RP_AZURE_LB=$(kubectl --context rp-azure -n redpanda get svc rp-azure-multicluster-peer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Render values files and helm upgrade — one example, repeat for gcp and azure:
sed -e "s|<RP_AWS_API_SERVER>|$RP_AWS_API|g" \
    -e "s|<RP_AWS_NLB_HOSTNAME>|$RP_AWS_LB|g" \
    -e "s|<RP_GCP_LB_IP>|$RP_GCP_LB|g" \
    -e "s|<RP_AZURE_LB_IP>|$RP_AZURE_LB|g" \
    aws/helm-values/values-rp-aws.example.yaml > /tmp/values-rp-aws.yaml

helm --kube-context rp-aws upgrade rp-aws redpanda-data/operator -n redpanda \
  --version 26.2.1-beta.1 -f /tmp/values-rp-aws.yaml
```

Repeat the `sed` + `helm upgrade` for `rp-gcp` and `rp-azure`.

Once all three operators are connected (check with `rpk k8s multicluster status` against any cluster), apply the StretchCluster **and** NodePool on each cluster:

```bash
for cloud in aws gcp azure; do
  ctx=rp-$cloud
  kubectl --context $ctx apply -f $cloud/manifests/stretchcluster.yaml
  kubectl --context $ctx apply -f $cloud/manifests/nodepool.yaml
done
```

`stretchcluster.yaml` is identical in shape across the three clouds (only the `rack:` rack name and the manifest filename's path differ). `nodepool.yaml` defines the per-cluster broker count: `replicas: 2` on aws + gcp, `replicas: 1` on azure (2/2/1 layout — RF=5 with quorum tolerance for losing one cloud).

### 8. Validate

```bash
# Cluster health from any context:
kubectl --context rp-aws -n redpanda exec -it redpanda-rp-aws-0 -c redpanda -- \
  rpk cluster health

# Multi-cluster status:
rpk k8s multicluster status

# Broker list — should show 5 brokers across racks aws / gcp / azure:
kubectl --context rp-aws -n redpanda exec -it redpanda-rp-aws-0 -c redpanda -- \
  rpk redpanda admin brokers list

# Round-trip test — produce on one cloud, consume on another:
kubectl --context rp-aws -n redpanda exec -it redpanda-rp-aws-0 -c redpanda -- \
  rpk topic create cross-cloud-test --partitions 6 --replicas 5
kubectl --context rp-aws -n redpanda exec -it redpanda-rp-aws-0 -c redpanda -- \
  bash -c 'echo "hello from aws" | rpk topic produce cross-cloud-test'
kubectl --context rp-gcp -n redpanda exec -it redpanda-rp-gcp-0 -c redpanda -- \
  rpk topic consume cross-cloud-test --num 1
```

## Cost

This is **expensive** — cross-cloud egress + the VPN tier add up fast. Rough estimate (`us-east-1` / `us-east1` / `eastus`):

| Component | $/hr |
|---|---|
| EKS control plane | $0.10 |
| 2× m5.xlarge | $0.38 |
| AWS Site-to-Site VPN (2 connections × $0.05/hr) | $0.10 |
| GKE regional control plane | $0.10 |
| 3× n2-standard-4 (regional cluster, `node_count=1` × 3 zones) | $0.58 |
| GCP HA VPN gateway (2 tunnels active × $0.05/hr) | ~$0.10 |
| AKS control plane (free tier) | $0.00 |
| 2× Standard_D4s_v5 | $0.38 |
| Azure VPN Gateway (VpnGw1 sku) | $0.19 |
| Cross-cloud LBs (3× NLB / Standard LB) | ~$0.07 |
| Cilium clustermesh-apiserver LB (3 of) | ~$0.05 |
| **Compute + VPN + LB subtotal** | **~$2.05/hr** |

On top: **inter-cloud egress** at the ~$0.05–$0.15/GB tier on every provider. Even idle, broker-to-broker raft heartbeats + Cilium clustermesh-apiserver sync + BGP keepalives add up. Plan for **$5–$30/day in egress** alone for a quiet test cluster, much more under load.

Tear down promptly when you're done validating.

## Tear down

```bash
./scripts/teardown.sh --gcp-project <your-gcp-project>
```

The script handles the same failure modes the per-cloud teardown scripts in the same-cloud beta cover (CR finalizer hangs, orphan LBs / SGs / ENIs, kubernetes-provider timeouts after the cluster is gone) — see `scripts/teardown.sh` for the ordered flow.

It also runs `cilium clustermesh disable` on each cluster before destroying so the public clustermesh-apiserver Services don't leak orphan cloud LBs.

**AWS gotcha**: the cilium clustermesh-apiserver Service `type=LoadBalancer` provisions *classic* ELBs (ELBv1) on EKS, not NLBs. `aws elbv2 describe-load-balancers` does not return them, so the AWS sweep explicitly enumerates ELBv1 and deletes any tagged `kubernetes.io/cluster/*`. The associated `k8s-elb-*` security groups also stick around and block VPC delete; the sweep catches those too. If you see `terraform destroy` looping on `DependencyViolation` for a VPC, look for leftover ELBv1s with `aws elb describe-load-balancers --region us-east-1` and delete them by name.

## Troubleshooting

### Nodes stay `NotReady` after Cilium install

Cilium status: `cilium status --kube-context <ctx>`. Common causes:

- **AWS** — VPC CNI addon was somehow installed (e.g., a stale `terraform apply` from an earlier attempt). Run `aws eks delete-addon --region us-east-1 --cluster-name rp-aws --addon-name vpc-cni` and re-run the Cilium install.
- **GCP** — Dataplane V2 was enabled. The Terraform sets `datapath_provider = "LEGACY_DATAPATH"`; if you used a different setting, recreate the cluster.
- **Azure** — `network_plugin` wasn't `none`. Re-apply Terraform.

### `cilium clustermesh status` shows `0 / 2 remote clusters connected`

The clustermesh-apiserver Service didn't get a public IP, or the other clusters can't reach it. Check:

- `kubectl --context <ctx> -n kube-system get svc clustermesh-apiserver` — should show `EXTERNAL-IP` populated.
- The cloud's security group / firewall / NSG allows TCP 2379 inbound from `0.0.0.0/0` (the Terraform configs open this; if you tightened the source range, the other clouds' egress IPs need to be in your allowed list).

### Brokers can't form quorum across clouds

Most likely Cilium clustermesh isn't routing pod IPs cross-cluster, or the operator's flat-mode EndpointSlices don't have the peer pod IPs. Check:

- `kubectl --context rp-aws -n redpanda get endpointslices` — every peer cluster's broker pod IPs should appear.
- From a broker pod on rp-aws, ping a broker pod IP on rp-gcp: `kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- ping -c 3 <gcp-broker-pod-ip>`. If this fails, Cilium WireGuard isn't routing — `cilium status` and check the WireGuard peers list.

### Auto-decom doesn't fire on a region failure

Same finding as the same-cloud AWS run: the partition balancer's `node_status_rpc` heartbeat has a hardcoded ~100ms timeout. If the controller (`redpanda/controller/0` leader) lands in a cloud whose RTT to one of the other clouds exceeds 100ms, it perpetually marks that cloud's brokers unresponsive and won't auto-decom anything. Check current controller location with `rpk cluster health` (`controller_id` field), then force the controller to a low-RTT cloud:

```bash
rpk cluster partitions transfer-leadership --partition redpanda/controller/0:<broker-id-in-low-RTT-cloud>
```

The cloud-rack ordering in `default_leaders_preference` (`racks:aws,gcp,azure` in the manifests) is supposed to bias this on its own — keep the lowest-RTT cloud first.

## Caveats / known issues

Found during the partial validation pass on 2026-05-01:

- **Cilium CLI `--context` flag, not `--kube-context`.** The cilium-cli ≥ v0.16 dropped the `--kube-context` long-form. Scripts use `--context` to match.
- **GKE Cilium install requires the original kube-context name.** When you install Cilium with `cilium install --context rp-gcp ...`, the CLI auto-detects GKE and tries to derive region/zone from the context name format `gke_PROJECT_ZONE_NAME`. After the rename to `rp-gcp` this fails (`unable to derive region and zone from context name`). Workaround documented in the install flow: rename the context back to its original `gke_<project>_<region>_rp-gcp` form for the Cilium install, then rename to `rp-gcp` after.
- **Don't use `--set gke.enabled=true` for cross-cloud.** That flag selects GKE *native* routing which only works for same-cloud GCP-to-GCP. For the cross-cloud setup we use `routingMode=tunnel` (Geneve) on every cluster including GKE so pod traffic is encapsulated over the WAN.
- **EKS bootstraps `aws-node` (VPC CNI) by default unless told not to.** The Terraform sets `bootstrap_self_managed_addons = false` to keep the cluster bare; without that you have to manually `kubectl delete daemonset aws-node` before Cilium install.
- **GKE pre-existing pods need to be restarted to come under Cilium management.** kubenet-assigned pods keep their old IPs until restarted. After Cilium install, run `kubectl delete pods -A --field-selector=status.phase=Running -l '!cilium,!kube-dns'` to evict them so Cilium picks them up. The bootstrap script does this automatically.
- **Cilium per-cluster CAs differ.** Each cluster's Cilium installation generates its own CA. The mesh `connect` step needs `--allow-mismatching-ca` so each cluster trusts the others' CAs. Connect-mesh.sh sets this.
- **Cross-cloud reachability to specific IP/port combinations is fragile, and pod-to-pod across clusters fails even when clustermesh control-plane reports connected.** During validation we observed:
  - From rp-aws hostNetwork pods, TCP to GCP/Azure clustermesh-apiserver public IPs (35.x.x.x and 20.x.x.x respectively) timed out, while ICMP to the same IPs worked (12ms RTT) and TCP to 8.8.8.8 / google.com worked fine.
  - `cilium clustermesh status` reported `aws ↔ gcp connected` (control-plane mTLS to clustermesh-apiserver), but `kubectl exec` ping from a pod in rp-gcp to a pod IP in rp-aws gave 100% packet loss.
  - This split between control-plane (works) and data-plane (broken) almost certainly tracks [Cilium issue #24403](https://github.com/cilium/cilium/issues/24403): the node-to-node WireGuard / Geneve tunnel needs UDP 51871 (or 8472 if not WG) reachable between the *actual node IPs* of every cluster, not just the clustermesh-apiserver LB IPs. Cloud egress firewalling, asymmetric routing on AWS, and MTU-fragmentation issues across the WAN can all break this silently. The Terraform configs in this repo open the right SG/firewall/NSG ports but you may still need to:
    - Verify each cluster's node external IPs can reach the others' on UDP 51871: `nc -uvz <peer-node-public-ip> 51871`
    - If using AWS, ensure nodes are in *public subnets with auto-assigned public IPs* (this repo's TF does this) — pods behind a NAT gateway add an extra hop that breaks WireGuard's symmetry assumptions.
    - Drop the MTU explicitly: `cilium install ... --set MTU=1380` (default tunnel MTU may not account for Geneve + WG overhead on every cloud's underlying network).
- **`node_status_rpc` 100ms timeout.** Inherits the same constraint we hit on AWS in the same-cloud beta. Cross-cloud RTT is more variable than same-region — pick clouds in the same physical area (US East Coast triple: `us-east-1` / `us-east1` / `eastus` ~5-15 ms pairwise) and lean on `default_leaders_preference: "racks:aws,gcp,azure"` to keep the controller in the lowest-RTT cloud.
- **Public node IPs.** Every node is in a public subnet with a public IP for direct cross-cloud reachability. Production should use SD-WAN / IPsec VPN between clouds and put nodes in private subnets — left as an exercise.
- **Cilium WireGuard MTU.** Geneve + WireGuard adds ~80 bytes of overhead. If you see PMTU issues, override Cilium's MTU (`--set MTU=1380`).
- **Cross-cloud egress cost.** Already mentioned, worth repeating.
- **GKE Dataplane V2 + Cilium ClusterMesh are mutually exclusive.** GKE DPv2 *is* Cilium internally but Google's fork doesn't support clustermesh. The Terraform here picks `LEGACY_DATAPATH` so we can install standard upstream Cilium.
