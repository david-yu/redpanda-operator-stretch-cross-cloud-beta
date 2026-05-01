# Redpanda Stretch Cluster Across AWS / GCP / Azure with Cilium ClusterMesh

Validation scaffold for a Redpanda Operator v26.2.1+ StretchCluster that **spans three different cloud providers** — one Kubernetes cluster on each of AWS EKS, GCP GKE, and Azure AKS, connected into a single Cilium ClusterMesh that gives Redpanda flat pod-to-pod connectivity across the WAN.

Companion to [`redpanda-operator-stretch-beta`](https://github.com/david-yu/redpanda-operator-stretch-beta) (single-cloud, three-region). Where the same-cloud beta uses the cloud's native L3 mesh (AWS TGW, GCP global VPC, Azure VNet peering), this repo uses **Cilium ClusterMesh + WireGuard transparent encryption over the public internet**, so it works across cloud-provider boundaries with no SD-WAN or VPN tier in the middle.

> [!WARNING]
> **This is a scaffold, not a tested artifact.** The single-cloud beta has been validated end-to-end across all three clouds; this one has been written carefully but not yet end-to-end deployed. Treat the Terraform / scripts as a starting point and expect to fix small things on first apply. PRs welcome.

## How it differs from the same-cloud beta

| | Same-cloud beta | This repo |
|---|---|---|
| Topology | 3 regions × 1 cloud | 3 clouds × 1 region each |
| K8s clusters | 3 EKS / 3 GKE / 3 AKS | 1 EKS + 1 GKE + 1 AKS |
| CNI | Cloud default (AWS VPC CNI, GKE Dataplane V2, Azure CNI) | **Cilium** (replacing each cloud's default) |
| L3 mesh | AWS TGW / GCP global VPC / Azure VNet peering | **Cilium ClusterMesh** over public internet, WireGuard-encrypted node-to-node |
| Cross-cluster service discovery | Operator's `crossClusterMode: flat` (manages headless Services + EndpointSlices) | Same — Cilium provides the pod-IP routing layer underneath |
| Operator-to-operator raft | Public NLB / internal LB per cluster, port 9443 | Same |
| Broker count | 2/2/1 = 5 (RF=5) | 2/2/1 = 5 (RF=5) |

## Architecture

```
                   ┌───────────────── public internet ─────────────────┐
                   │  WireGuard-encrypted node-to-node Cilium tunnels  │
                   │  + mTLS clustermesh-apiserver (port 2379)         │
                   └───────────────────────────────────────────────────┘
                                    ▲           ▲           ▲
                                    │           │           │
   ┌────────── AWS us-east-1 ──────┴┐  ┌── GCP us-east1 ──┴┐  ┌── Azure eastus ──┴┐
   │ EKS: rp-aws         cluster.id=1│  │ GKE: rp-gcp       │  │ AKS: rp-azure     │
   │   • CNI: Cilium (no aws-vpc-cni)│  │   • CNI: Cilium   │  │   • CNI: Cilium   │
   │   • pod CIDR 10.110.0.0/16     │  │   (no DPv2)        │  │   (BYOCNI)        │
   │   • 2× m5.xlarge nodes (public)│  │   • pod 10.120/16  │  │   • pod 10.130/16 │
   │   • 2 broker pods (rack=aws)   │  │   • 2× n2-std-4    │  │   • 1× D4s_v5     │
   └─────────────────────────────────┘  │   • 2 brokers      │  │   • 1 broker      │
                                        │     (rack=gcp)     │  │     (rack=azure)  │
                                        └────────────────────┘  └───────────────────┘
                       brokers, 2 / 2 / 1 — RF=5 quorum survives any single cloud loss
```

Each cluster runs Cilium with:
- `kubeProxyReplacement=true` — eBPF replaces kube-proxy entirely
- `routingMode=tunnel`, `tunnelProtocol=geneve` — pod-to-pod over Geneve
- `encryption.enabled=true`, `encryption.type=wireguard`, `encryption.nodeEncryption=true` — every node-to-node packet WireGuard-encrypted
- `clustermesh-apiserver` exposed via `Service: type=LoadBalancer` per cluster, mTLS-secured

The Redpanda multicluster operator runs in flat networking mode and creates per-peer headless Services + EndpointSlices on each cluster. Brokers reach peer brokers via cross-cluster pod IPs, which Cilium routes through the WireGuard mesh.

## Repo layout

```
.
├── aws/
│   ├── terraform/              # EKS without aws-vpc-cni addon
│   ├── manifests/              # StretchCluster CR
│   └── helm-values/            # values-rp-aws.example.yaml
├── gcp/
│   ├── terraform/              # GKE without DPv2 / network policy
│   ├── manifests/
│   └── helm-values/
├── azure/
│   ├── terraform/              # AKS BYOCNI (network_plugin=none)
│   ├── manifests/
│   └── helm-values/
└── scripts/
    ├── install-cilium.sh       # per-cloud Cilium install
    ├── connect-mesh.sh         # enable + connect 3-way Cilium ClusterMesh
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

### 1. Bring up the three clusters

Each cloud's Terraform brings up a Kubernetes cluster with **no CNI installed**. Nodes report `NotReady` until you install Cilium in step 2 — that's expected.

```bash
# AWS
cd aws/terraform
terraform init
terraform apply
# (record the kubectl_setup_command output and run it)

# GCP — needs your project ID
cd ../../gcp/terraform
terraform init
terraform apply -var project_id=<your-gcp-project>
# (record + run kubectl_setup_command)

# Azure
cd ../../azure/terraform
terraform init
terraform apply
# (record + run kubectl_setup_command)
```

After all three apply, your kubeconfig has contexts `rp-aws`, `rp-gcp`, `rp-azure`. `kubectl --context rp-aws get nodes` should show nodes `NotReady` — that means kubelet is up and the only thing missing is the CNI.

### 2. Install Cilium on each cluster

```bash
./scripts/install-cilium.sh all
```

This runs three `cilium install` invocations with cloud-specific flags:

- **AWS** — `eni.enabled=false`, `ipam.mode=cluster-pool`, pod CIDR `10.110.0.0/16`. Cilium owns IP allocation entirely; AWS VPC CNI is never installed.
- **GCP** — `gke.enabled=true`, `ipam.mode=kubernetes`. Cilium uses GKE's per-node `spec.podCIDR` (each node gets a /24 from the pods secondary range).
- **Azure** — `aksbyocni.enabled=true`, `ipam.mode=cluster-pool`, pod CIDR `10.130.0.0/16`. AKS came up with `--network-plugin none`, so Cilium installs into a fully empty CNI slot.

All three set `kubeProxyReplacement=true` (eBPF replaces kube-proxy), `routingMode=tunnel` (Geneve), `encryption.type=wireguard` + `encryption.nodeEncryption=true` (every node-to-node packet WireGuard-encrypted on the public internet).

After the script returns, `cilium status --kube-context rp-aws` should report `OK` and `kubectl --context rp-aws get nodes` should show all nodes `Ready`. Repeat for `rp-gcp` and `rp-azure`.

### 3. Wire the three clusters into a Cilium ClusterMesh

```bash
./scripts/connect-mesh.sh all
```

This runs:
1. `cilium clustermesh enable --service-type LoadBalancer` on each cluster (provisions a public LB for `clustermesh-apiserver` on port 2379, mTLS-secured)
2. `cilium clustermesh connect` for each pair (aws↔gcp, aws↔azure, gcp↔azure)
3. `cilium clustermesh status` on each cluster

Connectivity is established when `cilium clustermesh status` shows `2 / 2 remote clusters connected` on every cluster. Pod-to-pod traffic across clouds now flows through Cilium's WireGuard tunnels.

To verify pod-IP routing across clouds:

```bash
kubectl --context rp-aws run -i --tty --rm test --image=nicolaka/netshoot --restart=Never -- \
  ping -c 3 <pod-IP-from-rp-gcp>
```

### 4. Bootstrap Redpanda prerequisites

```bash
./scripts/bootstrap-redpanda.sh --license /path/to/redpanda.license
```

This installs cert-manager on each cluster, annotates every node with `redpanda.com/cloud=<aws|gcp|azure>` (so the operator's rack awareness picks the right rack), and creates the `redpanda` namespace + `redpanda-license` secret.

### 5. Install the operator + apply StretchCluster on each cluster

The operator's `multicluster.peers` block lists the public LB hostname/IP of every cluster's `<name>-multicluster-peer` Service plus each cluster's K8s API server endpoint — so this is a **two-pass install**:

**Pass 1**: helm-install the operator with empty/placeholder peers so the multicluster Service comes up and provisions a cloud LB.

```bash
helm repo add redpanda https://charts.redpanda.com
helm repo update redpanda

# Pass 1 — placeholder peers, just to provision the LB Service.
for ctx in rp-aws rp-gcp rp-azure; do
  helm --kube-context $ctx upgrade --install $ctx redpanda/redpanda-operator \
    -n redpanda \
    --version v26.2.1-beta.1 \
    --set fullnameOverride=$ctx \
    --set crds.enabled=true \
    --set multicluster.enabled=true \
    --set multicluster.name=$ctx
done
```

Wait for the multicluster Service to get an external IP/hostname:

```bash
for ctx in rp-aws rp-gcp rp-azure; do
  echo "=== $ctx ==="
  kubectl --context $ctx -n redpanda get svc $ctx-multicluster-peer
done
```

**Pass 2**: collect the LB endpoints + K8s API endpoints, fill them into your per-cloud `helm-values/values-rp-<cloud>.example.yaml`, and `helm upgrade`.

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

helm --kube-context rp-aws upgrade rp-aws redpanda/redpanda-operator -n redpanda \
  --version v26.2.1-beta.1 -f /tmp/values-rp-aws.yaml
```

Repeat the `sed` + `helm upgrade` for `rp-gcp` and `rp-azure`.

Once all three operators are connected (check with `rpk k8s multicluster status` against any cluster), apply the StretchCluster + NodePool on each cluster:

```bash
for cloud in aws gcp azure; do
  ctx=rp-$cloud
  kubectl --context $ctx apply -f $cloud/manifests/stretchcluster.yaml
  # NodePool sized 2 / 2 / 1 — see helm-values/values-rp-$cloud.example.yaml
done
```

### 6. Validate

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

This is **expensive** — cross-cloud egress dominates everything. Rough monthly estimate (`us-east-1` / `us-east1` / `eastus`):

| Component | $/hr |
|---|---|
| EKS control plane | $0.10 |
| 2× m5.xlarge | $0.38 |
| GKE regional control plane | $0.10 |
| 3× n2-standard-4 (regional cluster, `node_count=1` × 3 zones) | $0.58 |
| AKS control plane (free tier) | $0.00 |
| 2× Standard_D4s_v5 | $0.38 |
| Cross-cloud LBs (3× NLB / Standard LB) | ~$0.07 |
| Cilium clustermesh-apiserver LB (3 of) | ~$0.05 |
| **Compute + LB subtotal** | **~$1.66/hr** |

On top: **inter-cloud egress**, which is the ~$0.05–$0.15 / GB tier on every provider. Even idle, broker-to-broker raft heartbeats + Cilium clustermesh-apiserver sync add up. Plan for **$5–$30/day in egress** alone for a quiet test cluster, much more under load.

Tear down promptly when you're done validating.

## Tear down

```bash
./scripts/teardown.sh --gcp-project <your-gcp-project>
```

The script handles the same failure modes the per-cloud teardown scripts in the same-cloud beta cover (CR finalizer hangs, orphan LBs / SGs / ENIs, kubernetes-provider timeouts after the cluster is gone) — see `scripts/teardown.sh` for the ordered flow.

It also runs `cilium clustermesh disable` on each cluster before destroying so the public clustermesh-apiserver Services don't leak orphan cloud LBs.

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

- **Untested end-to-end.** The same-cloud beta has been validated three times across all three clouds; this scaffold has not. Expect minor adjustments on first run.
- **`node_status_rpc` 100ms timeout.** Inherits the same constraint we hit on AWS in the same-cloud beta. Cross-cloud RTT is more variable than same-region — pick clouds in the same physical area (US East Coast triple is the safest).
- **Public node IPs.** Every node is in a public subnet with a public IP for direct cross-cloud reachability. Production should use SD-WAN / IPsec VPN between clouds and put nodes in private subnets — left as an exercise.
- **Cilium WireGuard MTU.** Geneve + WireGuard adds ~80 bytes of overhead. If you see PMTU issues, override Cilium's MTU (`--set MTU=1380`).
- **Cross-cloud egress cost.** Already mentioned, worth repeating.
- **GKE Dataplane V2 + Cilium ClusterMesh are mutually exclusive.** GKE DPv2 *is* Cilium internally but Google's fork doesn't support clustermesh. The Terraform here picks `LEGACY_DATAPATH` so we can install standard upstream Cilium.
