# Redpanda Stretch Cluster Across AWS / GCP / Azure with Cilium ClusterMesh + Site-to-Site VPN

Validation scaffold for a Redpanda Operator v26.2.1+ StretchCluster that **spans three different cloud providers** — one Kubernetes cluster on each of AWS EKS, GCP GKE, and Azure AKS, connected into a single Cilium ClusterMesh.

Companion to [`redpanda-operator-stretch-beta`](https://github.com/david-yu/redpanda-operator-stretch-beta) (single-cloud, three-region). Where the same-cloud beta uses the cloud's native L3 mesh (AWS TGW, GCP global VPC, Azure VNet peering), this repo uses **a 3-way mesh of site-to-site IPsec VPNs (BGP-routed) + Cilium ClusterMesh on top**, so node InternalIPs are routable across cloud boundaries and Cilium's clustermesh data plane works without modification.

> [!TIP]
> **If you don't specifically need cross-cloud, prefer [`redpanda-operator-stretch-beta`](https://github.com/david-yu/redpanda-operator-stretch-beta) (cross-region in a single cloud).** Cross-cloud egress is billed at each provider's *internet-egress* rate ($0.087–$0.12/GB), while same-cloud cross-region transfer is $0.02–$0.04/GB depending on cloud (per the same-cloud beta's [cross-region data transfer table](https://github.com/david-yu/redpanda-operator-stretch-beta#cross-region-data-transfer-variable-per-gb--the-cost-that-scales-with-throughput) — AWS adds TGW data-processing on top of egress, Azure pays both directions on peering, GCP is one-side egress only). For the 30 MB/s OMB demo workload, that's roughly **\~$29/hr of egress in this cross-cloud scaffold** versus **\~$4.30/hr (GCP) / \~$8.60/hr (AWS or Azure) in the same-cloud beta** — a 3.4–6.7× saving depending on cloud. Use this repo only when the demo *itself* is cross-cloud (e.g., a 3-cloud failover story); use the same-cloud beta for everything else, including most leader-pinning / autobalancer / multicluster-operator validation. See the [Cost](#cost) section for the breakdown.

## Contents

- [How it differs from the same-cloud beta](#how-it-differs-from-the-same-cloud-beta)
- [Architecture](#architecture)
  - [How cross-cloud traffic is encrypted](#how-cross-cloud-traffic-is-encrypted)
- [Repo layout](#repo-layout)
- [Prerequisites](#prerequisites)
- [Step-by-step](#step-by-step)
  - [1. Bring up the three clusters + VPN gateways](#1-bring-up-the-three-clusters--vpn-gateways)
  - [2. Wire the cross-cloud IPsec VPN mesh](#2-wire-the-cross-cloud-ipsec-vpn-mesh)
  - [3. Verify VPN connectivity](#3-verify-vpn-connectivity)
  - [4. Install Cilium on each cluster](#4-install-cilium-on-each-cluster)
  - [5. Wire the three clusters into a Cilium ClusterMesh](#5-wire-the-three-clusters-into-a-cilium-clustermesh)
  - [6. Bootstrap Redpanda prerequisites](#6-bootstrap-redpanda-prerequisites)
  - [7. Install the operator + apply StretchCluster on each cluster](#7-install-the-operator--apply-stretchcluster-on-each-cluster)
  - [8. Validate](#8-validate)
  - [9. Demo add-ons: Console, OMB load, Prometheus + Grafana](#9-demo-add-ons-console-omb-load-prometheus--grafana)
- [Demo A: leader pinning + cross-cloud failover fallthrough](#demo-a-leader-pinning--cross-cloud-failover-fallthrough)
- [Demo B: regional failure + capacity injection (cross-cloud variant)](#demo-b-regional-failure--capacity-injection-cross-cloud-variant)
- [Cost](#cost)
- [Tear down](#tear-down)
- [Troubleshooting](#troubleshooting)
  - [Nodes stay `NotReady` after Cilium install](#nodes-stay-notready-after-cilium-install)
  - [`cilium clustermesh status` shows `0 / 2 remote clusters connected`](#cilium-clustermesh-status-shows-0--2-remote-clusters-connected)
  - [Brokers can't form quorum across clouds](#brokers-cant-form-quorum-across-clouds)
  - [Auto-decom doesn't fire on a region failure](#auto-decom-doesnt-fire-on-a-region-failure)
- [Caveats / known issues](#caveats--known-issues)

> [!IMPORTANT]
> **Known unresolved upstream issues** that this scaffold works around — read these before you tweak any of the design choices below, and check the linked tickets before assuming "the fix is upstream now":
>
> - **[cilium#24403](https://github.com/cilium/cilium/issues/24403)** — Cilium picks node `InternalIP` for clustermesh tunnel endpoints; cross-cloud nodes aren't reachable on those IPs without a routable underlay. The IPsec VPN tier in `vpn/terraform/` makes peer InternalIPs mutually routable, sidestepping the bug.
> - **[cilium#31209](https://github.com/cilium/cilium/issues/31209)** — Tunnel + KubeProxyReplacement + WireGuard nodeEncryption combo breaks asymmetric initial-connect routing. We deliberately do **not** enable Cilium's WireGuard nodeEncryption; the IPsec underlay already encrypts cross-cloud traffic.
> - **[cilium#43099](https://github.com/cilium/cilium/issues/43099)** — clustermesh-apiserver server cert is shipped with `serverAuth` only, but KVStoreMesh authenticates as a TLS client and fails with `unknown certificate authority`. **Fixed upstream in [cilium#43230](https://github.com/cilium/cilium/pull/43230)** (merged Dec 2025, in 1.20.0-pre.1); once 1.20.0 GA ships we can pin to it and delete `patch_server_cert_clientauth()` from `connect-mesh.sh`.
> - **`cilium clustermesh connect --allow-mismatching-ca` was producing a broken mesh.** Symptom (caught 2026-05-04 e2e v2): per-peer secret entries in `cilium-clustermesh` pointed at the LOCAL clustermesh-apiserver Service DNS (`https://clustermesh-apiserver.kube-system.svc:2379`) instead of the remote LB; agent logs showed `Connection to remote cluster established` looping back to itself; mesh status stuck at `2/2 configured, 0/2 connected` indefinitely; pod-to-pod cross-cloud failed. **Fix in `connect-mesh.sh` (commit `f3a9748`)**: drop the `--allow-mismatching-ca` flag entirely — connect now reports `⚠️ Cilium CA certificates do not match between clusters. Multicluster features will be limited!` (warning, informational) but the mesh actually connects fully. Validated 2026-05-04 e2e v3 with cilium-cli v0.18.9: pod-to-pod across clusters works, all 3 pairs report `2/2 configured, 2/2 connected`. Whether v0.19.x without the flag also works is **untested** — both repaired runs used v0.18.9, so this isn't conclusively a v0.19.x regression. The flag was added in v0.19.x along with PR [cilium/cilium#42833](https://github.com/cilium/cilium/pull/42833)'s CA-bundle refactor, so it doesn't exist in v0.18.x at all (`unknown flag` in v0.18.9). Track [cilium#42833](https://github.com/cilium/cilium/pull/42833) if you want to revisit the flag once a fix lands; for now, just don't use it.
> - **[redpanda-data/redpanda-operator#1499](https://github.com/redpanda-data/redpanda-operator/issues/1499)** — operator's auto-generated cert SANs (`*.redpanda`, `*.redpanda.svc`) violate RFC-6125 for single-label parents and strict TLS hostname verification rejects them on the advertised broker RPC hostname (`redpanda-rp-gcp-0.redpanda` etc.). Brokers complete the TLS handshake then drop the RPC with `rpc::errc:4` / "Broken pipe". This scaffold ships `spec.tls.enabled: false` on every listener as the workaround; cross-cloud confidentiality is already provided by the IPsec VPN underlay (see [Architecture → How cross-cloud traffic is encrypted](#how-cross-cloud-traffic-is-encrypted)).
> - **[K8S-846](https://redpandadata.atlassian.net/browse/K8S-846)** (internal) — operator binary started in `multicluster` mode ships the Console CRD but not its reconciler; Console CRs sit with empty `status` indefinitely. We use the `redpanda/console` Helm chart instead — see Step 9 + [`console/values.yaml`](console/values.yaml).
> - **Redpanda `node_status_rpc` 100ms timeout** — hardcoded in the broker; if the controller leader ever lands in a region whose pairwise RTT to any peer exceeds 100ms, that peer is silently marked `IS-ALIVE=false` and the autobalancer makes decisions on the wrong data. Mitigation here: the `us-east-1` / `us-east1` / `eastus` triple stays under 100ms pairwise. See the cross-Atlantic caveat under Demo A and Step 7.
>
> **`spec.tls.enabled: false` on its own is not enough** — the operator chart still emits `kafka_api_tls` / `admin_api_tls` / `pandaproxy_api_tls` / `schema_registry_api_tls` listeners referencing `/etc/tls/certs/external/*` cert files that don't exist, and brokers crash-loop reading them. The manifests in this repo ship with TLS turned off explicitly on every listener (`spec.listeners.{kafka,admin,http,schemaRegistry,rpc}.tls.enabled: false`). If you re-enable broker TLS once #1499 is fixed, remove that listener block in addition to flipping `spec.tls.enabled: true`.
>
> **VPN tier note** — the original BGP-routed VPN scaffold didn't converge cleanly across the AWS/GCP/Azure triple; we switched to **static routes** (per [this devgenius.io guide](https://blog.devgenius.io/lessons-from-connecting-gcp-and-aws-with-a-site-to-site-vpn-d5e0d27ec03c)) and that works. See `vpn/terraform/`.

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

### How cross-cloud traffic is encrypted

Every byte that crosses a cloud boundary is already encrypted by the cloud-native IPsec VPN tunnels in `vpn/terraform/` before it leaves the source cloud's network — so we deliberately do **not** stack additional encryption layers (no Cilium WireGuard nodeEncryption, and broker-level TLS is off — see the comment in `aws/manifests/stretchcluster.yaml`).

Layered view of a single broker-to-broker packet from `redpanda-rp-aws-0` (10.110.x.x pod IP in AWS) to `redpanda-rp-gcp-0` (10.120.x.x pod IP in GCP):

```
┌── on the wire between AWS and GCP cloud edges ──────────────────────┐
│ IPsec ESP (IKEv2 + AES-256-GCM)        ← VPN gateway encryption     │
│  └─ underlay UDP (Cilium Geneve port)  ← Cilium tunnel              │
│      └─ inner IPv4 (pod IP → pod IP)                                │
│          └─ TCP/33145 (Redpanda RPC)   ← plaintext at this layer    │
└─────────────────────────────────────────────────────────────────────┘
```

Per-cloud crypto:

| Cloud | Tunnel resource | IKE / cipher |
|---|---|---|
| AWS | `aws_vpn_connection` (Site-to-Site VPN) | IKEv2, AES-256-GCM (default) |
| GCP | `google_compute_vpn_tunnel` on `google_compute_ha_vpn_gateway` | IKEv2, AES-256-GCM |
| Azure | `azurerm_virtual_network_gateway_connection` (`VpnGw2AZ`) | IKEv2, AES-256-GCM |

The TCP/33145 RPC payload between brokers is plaintext at the inner-most layer, but it never appears on a public path — it's wrapped in Geneve, then in IPsec ESP, before any byte hits the WAN. If the IPsec tunnel drops, pod-IP routing across clouds breaks at the same instant (Cilium's tunnel encapsulation has nowhere to deliver to), so brokers can't talk anyway. There's no "VPN down but data still flowing in plaintext" failure mode.

Within a single cluster the broker traffic stays inside that cloud's VPC/VNet — same trust boundary as any other intra-cluster pod traffic. If you need defense-in-depth against an attacker on the *cloud-internal* network too, layer broker TLS on once the operator's hostname-mismatch issue (see Step 7) is resolved upstream.

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
├── console/
│   └── console.yaml            # Console CR (cluster.redpanda.com/v1alpha2) — operator-managed via clusterRef
├── omb/
│   ├── producer-job.yaml       # \~30 MB/s kafka-perf-test producer (Job in the redpanda namespace)
│   ├── consumer-job.yaml       # matching consumer
│   └── README.md
├── monitoring/
│   ├── values.yaml             # kube-prometheus-stack values: Grafana LB + dashboard sidecar
│   └── redpanda-scrape.yaml    # cross-cluster scrape config (Endpoints SD on the redpanda Service)
└── scripts/
    ├── install-cilium.sh       # per-cloud Cilium install
    ├── connect-mesh.sh         # enable + connect 3-way Cilium ClusterMesh
    ├── apply-vpn.sh            # collects per-cloud TF outputs and applies vpn/terraform
    ├── bootstrap-redpanda.sh   # cert-manager + license secret + node annotations (initial)
    ├── annotate-rack.sh        # idempotent re-annotation of nodes — re-run after any GKE/EKS/AKS resize, autoscaler add, or Demo B capacity-injection step
    ├── install-console.sh      # Console on rp-aws (LB + URL printed at end)
    ├── install-omb.sh          # creates load-test topic + applies OMB Jobs (\~30 MB/s)
    ├── install-monitoring.sh   # kube-prometheus-stack + Redpanda dashboard, prints Grafana URL+creds
    └── teardown.sh             # full multi-cloud teardown (uninstalls demo addons first)
```

## Prerequisites

- Cloud CLIs authenticated: `aws sts get-caller-identity`, `gcloud auth list`, `az account show`
- `terraform` ≥ 1.6, `kubectl` ≥ 1.28, `helm` ≥ 3.14
- [`cilium` CLI](https://github.com/cilium/cilium-cli) ≥ v0.16. **v0.18.9 is the most recently validated version (2026-05-04 e2e v3).** v0.19.x adds an `--allow-mismatching-ca` flag that, when used with the connect-mesh.sh shape we ship, produced a broken mesh — `connect-mesh.sh` no longer passes the flag, and v0.18.x doesn't recognize it at all. Whether v0.19.x without the flag works end-to-end is untested. See the unresolved-issues callout above.
- A Redpanda Enterprise license file (the operator + multicluster features require it)
- A GCP project ID with the `container.googleapis.com` and `compute.googleapis.com` APIs enabled

## Step-by-step

The flow is:

1. **Apply per-cloud Terraform** (clusters + VPN gateways). VPN gateway creation alone is slow on Azure (\~30-45 min for `azurerm_virtual_network_gateway`), so kick off all three in parallel.
2. **Apply `vpn/terraform/`** — wires the 3-way mesh of IPsec tunnels with BGP. Reads each cloud's outputs.
3. **Verify VPN connectivity** — node-internal-IP pings cross-cloud should succeed.
4. **Install Cilium** on each cluster.
5. **Connect Cilium ClusterMesh** between the three clusters.
6. **Bootstrap Redpanda** (cert-manager, license secret, node annotations).
7. **Install operator + StretchCluster** with peer LB lookups.

### 1. Bring up the three clusters + VPN gateways

Each cloud's Terraform brings up a Kubernetes cluster plus the cloud's VPN gateway (no peer connections yet — those come from `vpn/terraform/` in step 2). What gets installed on the CNI side is cloud-specific:

- **AWS** — `bootstrap_self_managed_addons = false` keeps the *self-managed* aws-node DaemonSet out, but the EKS *managed* `vpc-cni` and `coredns` addons still install (the chart's `cluster_addons` block adds them by default). Nodes come up `Ready` with VPC CNI doing pod networking. Cilium install (step 4) deletes the `aws-node` DaemonSet first and takes over.
- **GCP** — GKE always installs a CNI (kubenet on `LEGACY_DATAPATH`). Nodes come up `Ready`. Cilium install evicts kubenet-assigned pods so they re-attach under Cilium.
- **Azure** — `network_plugin = "none"` (BYOCNI) means there is *no* CNI on AKS until step 4. Azure nodes are the only ones that report `NotReady` until Cilium installs.

So `kubectl get nodes` after step 1 shows: rp-aws / rp-gcp = Ready, rp-azure = NotReady. All become Ready after step 4.

```bash
# AWS — \~12-15 min for EKS + VGW
cd aws/terraform
terraform init
terraform apply
# (record the kubectl_setup_command output and run it)

# GCP — \~10-15 min for GKE + HA VPN
cd ../../gcp/terraform
terraform init
terraform apply -var project_id=<your-gcp-project>
# (record + run kubectl_setup_command)

# Azure — \~5 min for AKS, then \~30-45 min for VPN GW (azurerm_virtual_network_gateway is just slow)
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

If this succeeds, the VPN tier is healthy. If it times out, BGP routes haven't propagated yet (normal for the first \~30s after `apply-vpn.sh`) or there's an IPsec tunnel issue (`aws ec2 describe-vpn-connections` and `gcloud compute vpn-tunnels list`).

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

> **Allow \~60s after `connect-mesh.sh` finishes before checking status.** The script's final `cilium clustermesh status` call (without `--wait`) prints the snapshot at script-end, but config propagation to cilium-agents and the KVStoreMesh sync are async — it's normal to see `1/3 configured, 0/3 connected` immediately after the script returns and `3/3 configured, 3/3 connected` 30-60s later. If it doesn't converge after 2-3 min, restart the cilium-agent DaemonSets (`kubectl -n kube-system rollout restart daemonset/cilium`) on the lagging cluster.

To verify pod-IP routing across clouds:

```bash
kubectl --context rp-aws run -i --tty --rm test --image=nicolaka/netshoot --restart=Never -- \
  ping -c 3 <pod-IP-from-rp-gcp>
```

### 6. Bootstrap Redpanda prerequisites

```bash
./scripts/bootstrap-redpanda.sh --license /path/to/redpanda.license
```

`bootstrap-redpanda.sh` installs cert-manager on each cluster, annotates every node with `redpanda.com/cloud=<aws|gcp|azure>` (so the operator's rack awareness picks the right rack), and creates the `redpanda` namespace + `redpanda-license` secret.

> **Note on broker TLS**: this scaffold ships with `tls.enabled: false` on the StretchCluster manifests. Cross-cloud broker traffic is encrypted at the IPsec layer by the VPN tunnels in `vpn/terraform/` (see [How cross-cloud traffic is encrypted](#how-cross-cloud-traffic-is-encrypted) for the layered view). Re-enabling broker TLS with the operator's auto-generated certs hits an RFC-6125 hostname-mismatch on the advertised RPC hostnames (`*.redpanda` doesn't match `redpanda-rp-gcp-0.redpanda` per strict TLS hostname verification), and the operator doesn't expose a way to add explicit per-broker SANs — left as a follow-up once that's resolved upstream.

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

This is a single-shot helm install — but the operator chart in `redpanda-data/operator @ 26.2.1-beta.1` requires `multicluster.peers` to already be set with each peer's LB hostname/IP. Same as same-cloud beta [step 3](https://github.com/david-yu/redpanda-operator-stretch-beta#step-by-step), we run `rpk k8s multicluster bootstrap` *before* `helm install` so it provisions the peer LB Services + signs the operator-mTLS / kubeconfig Secrets, and the helm install then consumes the peers it printed.

**Step 7a — bootstrap multicluster TLS + kubeconfig secrets and provision peer LBs**:

```bash
rpk k8s multicluster bootstrap \
  --context rp-aws --context rp-gcp --context rp-azure \
  --namespace redpanda \
  --loadbalancer \
  --loadbalancer-timeout 10m
```

This:
- Creates a `<ctx>-multicluster-peer` Service of `type: LoadBalancer` in each cluster (port 9443) and waits for the cloud provider to assign an external IP/hostname.
- Generates a shared CA across the three clusters and writes per-cluster TLS material to `<ctx>-multicluster-certificates` (the chart's expected Secret name).
- Writes per-peer kubeconfig secrets so each operator pod can talk to peer clusters' API servers.
- Prints a ready-to-paste `multicluster.peers` block with each cluster's LB address baked in.

**Step 7b — render values files + helm install**:

```bash
helm repo add redpanda-data https://charts.redpanda.com --force-update
helm repo update

# Per-cluster K8s API server endpoints (from terraform / cloud CLI):
RP_AWS_API=$(aws eks describe-cluster --region us-east-1 --name rp-aws --query cluster.endpoint --output text)
RP_GCP_API="https://$(gcloud container clusters describe rp-gcp --region us-east1 --format='value(endpoint)'):443"
RP_AZURE_API="https://$(az aks show -g rp-aws-cross-cloud -n rp-azure --query fqdn -o tsv):443"

# Peer LB addresses (use whatever rpk k8s multicluster bootstrap printed,
# or read them off the multicluster-peer Services it created):
RP_AWS_LB=$(kubectl   --context rp-aws   -n redpanda get svc rp-aws-multicluster-peer   -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
RP_GCP_LB=$(kubectl   --context rp-gcp   -n redpanda get svc rp-gcp-multicluster-peer   -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
RP_AZURE_LB=$(kubectl --context rp-azure -n redpanda get svc rp-azure-multicluster-peer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

for cloud in aws gcp azure; do
  ctx=rp-$cloud
  sed -e "s|<RP_AWS_API_SERVER>|$RP_AWS_API|g"     \
      -e "s|<RP_GCP_API_SERVER>|$RP_GCP_API|g"     \
      -e "s|<RP_AZURE_API_SERVER>|$RP_AZURE_API|g" \
      -e "s|<RP_AWS_NLB_HOSTNAME>|$RP_AWS_LB|g"    \
      -e "s|<RP_GCP_LB_IP>|$RP_GCP_LB|g"           \
      -e "s|<RP_AZURE_LB_IP>|$RP_AZURE_LB|g"       \
      $cloud/helm-values/values-$ctx.example.yaml > /tmp/values-$ctx.yaml

  helm --kube-context $ctx upgrade --install $ctx redpanda-data/operator \
    -n redpanda --version 26.2.1-beta.1 \
    -f /tmp/values-$ctx.yaml
done
```

The helm release name **must** equal the kubectl context name (`rp-aws` / `rp-gcp` / `rp-azure`) so that the chart's generated TLS Secret name (`<ctx>-multicluster-certificates`) matches what `rpk k8s multicluster bootstrap` already wrote in step 7a.

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

### 9. Demo add-ons: Console, OMB load, Prometheus + Grafana

These three add-ons turn the bare cross-cloud StretchCluster into a presentable demo: a single Redpanda Console UI for the topic / partition / consumer-group view, a \~30 MB/s OMB-equivalent workload so failover behavior is visible under real load, and a Prometheus + Grafana stack scraping all 5 brokers across 3 clouds with the published Redpanda dashboard pre-imported.

All three install on **rp-aws only** — the controller is pinned there (`default_leaders_preference: "racks:aws"`), and the operator's flat-mode EndpointSlices put every peer broker pod IP into rp-aws's headless `redpanda` Service, so a single Console / Prometheus reaches the whole stretch cluster without per-cluster federation.

**Order matters once** — install monitoring before OMB if you want the steady-state baseline panels populated before load arrives; install Console before OMB if you want to watch `load-test` populate from zero. Otherwise any order works.

```bash
./scripts/install-console.sh        # Redpanda Console on rp-aws
./scripts/install-monitoring.sh     # kube-prometheus-stack on rp-aws
./scripts/install-omb.sh            # \~30 MB/s producer + consumer Jobs
```

Each script provisions its own LoadBalancer (NLB on AWS), waits for it to come up, and prints the URL + login at the end. **Nothing about credentials is committed to the repo** — Grafana's admin password is auto-generated by the chart and read out of the in-cluster `monitoring-grafana` Secret only at print time.

#### Accessing Console

Console (Helm chart `redpanda/console` — see [K8S-846](https://redpandadata.atlassian.net/browse/K8S-846) for why we use the chart instead of the operator-managed CR) is exposed via an NLB in the `console` namespace on rp-aws. **No login** (Console OSS, demo posture).

```bash
# print the URL anytime:
echo "http://$(kubectl --context rp-aws -n console get svc console \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'):8080"
```

After login (the URL you got from `install-console.sh` or the command above):

| Pane | Where to click | What you see |
|---|---|---|
| **Topics** | left nav → "Topics" | `load-test` (24 partitions × RF=5 — the OMB target), `cross-cloud-test` (validation topic from step 8), `leader-pinning-demo` (Demo A topic) |
| **Topic detail → Partitions** | click a topic, then "Partitions" tab | per-partition leader broker ID + replicas; cross-reference broker IDs to racks (aws/gcp/azure) via the Brokers pane |
| **Brokers** | left nav → "Brokers" | all 5 brokers, their RACK column, IS-ALIVE state — most useful pane during Demo A's cordon-restore cycle |
| **Consumer Groups** | left nav → "Consumer groups" → `omb-consumer` | per-partition lag for the OMB consumer, real-time during failover |

#### Accessing Grafana

Grafana (Helm chart `prometheus-community/kube-prometheus-stack`) is exposed via an NLB in the `monitoring` namespace. **Login: `admin` + auto-generated password.**

```bash
# print URL + creds anytime:
echo "URL:  http://$(kubectl --context rp-aws -n monitoring get svc monitoring-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "User: admin"
echo "Pass: $(kubectl --context rp-aws -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d)"
```

After login (left nav → Dashboards (four-square icon) → Browse → **General** folder):

`install-monitoring.sh` pre-loads **two Redpanda dashboards** sourced from [redpanda-data/observability](https://github.com/redpanda-data/observability) (same source `rpk generate grafana-dashboard --dashboard <name>` uses). The kube-prometheus-stack chart's ~20 bundled Kubernetes dashboards are explicitly disabled (`grafana.defaultDashboardsEnabled: false` in `monitoring/values.yaml`) to keep the Grafana UI focused on Redpanda.

| What you want to see | Open this dashboard | Notes |
|---|---|---|
| **Broker health, throughput, latency, leader counts by rack** | **Redpanda Ops Dashboard** | 41-panel KPI view. Best dashboard for Demo A's "watch leaders migrate aws → gcp → aws" — leader-count panel is grouped by `rack` label. Also shows under-replicated partitions, leader elections, p50/p95/p99 latency. |
| **Disk pressure on each broker (free bytes, used%)** | **Redpanda Ops Dashboard** → "Disk usage" panel | `redpanda_storage_disk_free_bytes` / `_total_bytes`. Watch this during Demo B — `Over Disk Limit Nodes` showed up here first. Compare against the autobalancer's `partition_autobalancing_max_disk_usage_percent: 80` threshold (committed in `<cloud>/manifests/stretchcluster.yaml`). |
| **OMB throughput on `load-test` (produce + consume rates)** | **Redpanda Default Dashboard** → throughput panels | Filter `instance` / `pod` to scope to one rack if needed. The ~30 MB/s OMB rate shows in the produce-bytes-per-sec series. |
| **Per-region broker view** | Either dashboard's `instance` / `pod` variable selector at the top | Filter to `redpanda-rp-aws-*` / `redpanda-rp-gcp-*` / `redpanda-rp-azure-*` to scope to one cluster's brokers. |
| **Cross-cluster aggregate (all 5 brokers, no filter)** | Default view (no variable filter) | All brokers' metrics aggregated across clouds — Prometheus's cross-cluster Endpoints SD picks them all up via the operator's flat-mode EndpointSlices on rp-aws (no per-cluster federation needed). |
| **More dashboards (per-topic, consumer offsets, consumer-metrics, ...)** | `kubectl exec` into a broker, run `rpk generate grafana-dashboard --dashboard <name>` and import the printed JSON into Grafana via "+" → Import | Available dashboard names: `operations`, `topic-metrics`, `consumer-metrics`, `consumer-offsets`, `serverless`. We don't pre-load these by default to keep the General folder uncluttered. |

> **If "Dashboards → Browse" is empty after login**, the sidecar's dashboard provisioning probably failed. Check `kubectl --context rp-aws -n monitoring logs deployment/monitoring-grafana -c grafana-sc-dashboard` — should show `Writing /tmp/dashboards/<name>.json (ascii)` for each chart-bundled and our redpanda-dashboard ConfigMap. Failure modes seen during 2026-05-04 e2e v3:
>
> 1. **`Error: insufficient privileges to create <FolderName>. Skipping ...` on every dashboard** — the chart's `sidecar.dashboards.folder` setting was overridden to a non-default value (`Redpanda` in our case). The chart uses that field as the *shared-volume mount path* between sidecar and main Grafana container, AND as the relative directory the sidecar writes to. A non-default value lands files at a relative path Grafana provisioning can't reach (`stat Redpanda: no such file or directory`). Repo's current `monitoring/values.yaml` doesn't set the folder so chart default `/tmp/dashboards` applies — but if you've inherited a stale install, run:
>     ```bash
>     helm --kube-context rp-aws upgrade monitoring prometheus-community/kube-prometheus-stack \
>       -n monitoring --no-hooks --reset-values \
>       -f monitoring/values.yaml
>     ```
>     `--no-hooks` is needed because the chart's pre-upgrade `monitoring-kube-prometheus-admission-create` Job can hit `context deadline exceeded` on a re-upgrade and block the values rollout.
>
> 2. **Sidecar log shows `Should have added FOLDER as environment variable! Exit`** — `FOLDER` env was unset (e.g., from `kubectl set env ... FOLDER-`). Add it back: `kubectl set env deploy/monitoring-grafana -c grafana-sc-dashboard FOLDER=/tmp/dashboards`.
>
> Verify dashboards loaded by hitting the Grafana API:
> ```bash
> GPASS=$(kubectl --context rp-aws -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
> GURL=$(kubectl --context rp-aws -n monitoring get svc monitoring-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
> curl -s -u "admin:$GPASS" "http://$GURL/api/search?query=&type=dash-db" | jq '. | length'   # should print ~24
> ```

What each piece is doing under the hood:

| Add-on | Chart / image | Where load lands | Demo signal |
|---|---|---|---|
| **Console** | Operator-managed `Console` CR (`cluster.redpanda.com/v1alpha2`) in namespace `redpanda`, exposed via `Service: type=LoadBalancer` (NLB). The operator pulls broker / Admin API / Schema Registry endpoints + TLS + auth from the StretchCluster via `spec.cluster.clusterRef` — no per-listener wiring in the CR | n/a — read-only UI | Topics → `load-test` shows partition leadership across racks (`aws` / `gcp` / `azure`); consumer group `omb-consumer` shows lag spike + recover during failover |
| **OMB workload** | `apache/kafka:3.8.0` Job, `kafka-producer-perf-test --throughput 7680 --record-size 4096` | `redpanda` namespace on rp-aws — leaders for the 24 partitions distribute across racks per the operator's leader-balancer | `kubectl logs -f job/omb-producer` shows per-5s `records sent / records/sec / avg latency / max latency`. A regional cordon → \~5–30 s producer stall → return to \~7680 records/sec |
| **Prometheus + Grafana** | `prometheus-community/kube-prometheus-stack`, namespace `monitoring`, Grafana exposed via NLB | scrapes `redpanda.redpanda.svc.cluster.local:9644/public_metrics` (Endpoints SD), reaches all 5 brokers thanks to flat-mode EndpointSlices + Cilium ClusterMesh | Dashboards → Redpanda → "Kubernetes Redpanda" — produce/consume MB/s, p50/p95/p99 latency, leader count by rack, URP / leader-elections panels light up during region failover |

The OMB target rate is 30 MB/s with 4 KiB records — see [`omb/README.md`](omb/README.md) for the rate-tuning matrix if you want a different number, and the same notes on stopping / re-applying the Jobs.

> **No credentials in the repo.** `.gitignore` covers `*.local.yaml`, `console-creds.txt`, and `grafana-creds.txt` so any pinned override files stay out of git. The install scripts never write credentials to disk — they print to stderr once and leave the auto-generated values in their respective in-cluster Secrets (`monitoring-grafana`).

> **Console deploys via the helm chart, NOT the operator-managed Console CR** documented at [docs.redpanda.com/current/deploy/console/kubernetes/deploy/](https://docs.redpanda.com/current/deploy/console/kubernetes/deploy/). The multicluster-mode operator we deploy (`redpanda-data/operator --version 26.2.1-beta.1`, started with `multicluster` as its first arg) only ships the StretchCluster reconciler — its Console CRD is registered but no controller in this binary watches Console CRs. Applying one leaves it with empty `status` indefinitely. Tracked as **K8S-846**. `console/values.yaml` and `scripts/install-console.sh` document why we deviate from the docs page.

> **Storage sizing is real.** Chart default PVC size is 20Gi. Under the OMB workload (\~30 MB/s × RF=5 = \~30 MB/s ingest per broker) that fills in \~11 minutes, the partition autobalancer stalls with `Over Disk Limit Nodes`, and brokers crashloop on `no space left on device`. The committed manifests pin `spec.storage.persistentVolume.size: 200Gi` plus `log_retention_ms: 3600000` (1 hour). These two together give a multi-hour Demo A window without disk pressure feedback.

## Demo A: leader pinning + cross-cloud failover fallthrough

> Adapted from the same-cloud beta's [Demo A: leader pinning + region-failure fallthrough](https://github.com/david-yu/redpanda-operator-stretch-beta#demo-a-leader-pinning--region-failure-fallthrough). Same shape — cordon the primary, watch leadership relocate, restore — but the rack labels are *cloud names* (`aws` / `gcp` / `azure`) and the failure boundary is an entire cloud's K8s cluster.

The committed `<cloud>/manifests/stretchcluster.yaml` configures rack-aware leader pinning with an **ordered** failover list — primary cloud first, then the next-lowest-RTT cloud, then the last:

```yaml
rackAwareness:
  enabled: true
  nodeAnnotation: redpanda.com/cloud   # rack = cloud name (aws / gcp / azure)

config:
  cluster:
    # Ordered preference. Leaders sit in the first reachable rack and fall
    # over to the next listed rack on outage (Redpanda 26.1+ ordered_racks).
    default_leaders_preference: "ordered_racks:aws,gcp,azure"
```

`bootstrap-redpanda.sh` annotates every node with `redpanda.com/cloud=<aws|gcp|azure>` (from step 6), so each broker's rack is the cloud it lives in (one rack per cloud). With the 2 / 2 / 1 broker layout (RF=5), a single-cloud outage leaves quorum with 3 brokers and leadership relocates to the next reachable rack in the priority list.

> **Run continuous load (recommended).** Apply the [`omb/`](omb/) Jobs *before* starting Demo A so the producer + consumer are at steady state when you cordon the primary cloud. The producer's per-5s throughput line stalls for \~5–30 s during leader re-election then returns to \~7680 records/sec — that's the visible proof the cluster kept serving traffic across a full-cloud failure. The same window shows in Grafana as a leader-count flip from `rack=aws` to `rack=gcp` and a brief consumer-lag spike.
>
> ```bash
> ./scripts/install-omb.sh    # creates load-test, starts producer + consumer
> # then proceed with the demo steps below — load is running in the background
> ```

**Step 1 — verify rack labels are populated**

```bash
kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- \
  rpk redpanda admin brokers list
```

Expected — every broker has a `RACK` value matching its cloud:

```
ID    HOST                          PORT   RACK   CORES  MEMBERSHIP  IS-ALIVE  VERSION  UUID
0     redpanda-rp-aws-0.redpanda    33145  aws    4      active      true      26.2.1   52351fe6-…
1     redpanda-rp-aws-1.redpanda    33145  aws    4      active      true      26.2.1   78f90065-…
2     redpanda-rp-gcp-0.redpanda    33145  gcp    4      active      true      26.2.1   72ecf5ff-…
3     redpanda-rp-gcp-1.redpanda    33145  gcp    4      active      true      26.2.1   3bda1c04-…
4     redpanda-rp-azure-0.redpanda  33145  azure  4      active      true      26.2.1   bad54b3e-…
```

Broker IDs are assigned by Redpanda in join order, so the exact `ID → cloud` mapping may differ on your run if brokers come up in a different order. From here on, prefer rack-name lookups over hardcoded IDs:

```bash
# Capture rack → broker-ID mapping into shell vars for the rest of the demo:
rack_ids() {
  kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- \
    rpk redpanda admin brokers list 2>/dev/null \
    | awk -v r="$1" 'NR>1 && $4==r {print $1}' | xargs
}
AWS_IDS=$(rack_ids aws)     # e.g. "0 1"
GCP_IDS=$(rack_ids gcp)     # e.g. "2 3"
AZURE_IDS=$(rack_ids azure) # e.g. "4"
echo "aws=$AWS_IDS gcp=$GCP_IDS azure=$AZURE_IDS"
```

**Step 2 — create the demo topic and watch leaders concentrate in the AWS rack**

A 12-partition topic with RF=5 (every partition has a replica on every broker):

```bash
kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- \
  rpk topic create leader-pinning-demo --partitions 12 --replicas 5
```

Wait \~60 s for the leader balancer to converge, then tally leaders by broker:

```bash
sleep 60
kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- \
  rpk topic describe leader-pinning-demo -p | awk 'NR>1 {print $2}' | sort | uniq -c
```

Expected — all 12 leaders on the two AWS-rack brokers (`$AWS_IDS`), evenly split:

```
   6 0
   6 1
```

If you have Console up (`./scripts/install-console.sh`), Topics → `leader-pinning-demo` shows the same picture visually with the rack column populated, and the same view auto-updates as leadership moves in step 4.

**Step 3 — simulate the AWS cloud failing**

Patching the `NodePool` to `replicas: 0` triggers a *graceful* decommission, which stalls under RF=5 (autobalancer has nowhere to land replicas). Likewise `kubectl scale sts redpanda-rp-aws --replicas=0` is fought back by the operator's reconcile loop within \~60 s.

For a true cloud-outage simulation (brokers unreachable, no graceful drain), cordon every node in rp-aws and delete the broker pods so they sit `Pending`:

```bash
for N in $(kubectl --context rp-aws get nodes -o name); do
  kubectl --context rp-aws cordon "$N"
done
kubectl --context rp-aws -n redpanda delete pod \
  redpanda-rp-aws-0 redpanda-rp-aws-1 --grace-period=10
```

**Step 4 — confirm leaders fall through to the GCP rack**

Wait **\~5–7 min** for the controller to mark AWS brokers unreachable (well under the `partition_autobalancing_node_availability_timeout_sec: 600` we set, so they don't get auto-decommissioned mid-demo) and for the leader balancer to relocate leaders. Under the 30 MB/s OMB load, convergence is meaningfully slower than the same-cloud beta's \~2 min — every replica catch-up has to traverse the cross-cloud VPN. Run the tally from a *surviving* cluster (rp-aws's API is gone):

```bash
sleep 120
kubectl --context rp-gcp -n redpanda exec redpanda-rp-gcp-0 -c redpanda -- \
  rpk topic describe leader-pinning-demo -p | awk 'NR>1 {print $2}' | sort | uniq -c
```

Expected — leadership has fallen through to `ordered_racks`'s rank-2 rack (gcp), brokers `$GCP_IDS`:

```
   6 2
   6 3
```

If you see something like `4 2 / 4 3 / 4 4` mid-window, that's the leader balancer mid-convergence — broker 4 (`azure`, rank 3) is briefly used as a holder while replicas catch up. Wait another 30–60 s; leadership consolidates on the highest-priority *reachable* rack (gcp) once partitions are re-replicated.

> **Cross-cloud heartbeat caveat (Azure landing). ** With AWS brokers down, the controller raft re-elects, and there's a non-trivial chance it lands on broker 4 (`azure`). For our `us-east-1` / `us-east1` / `eastus` triple this is fine — every pairwise RTT stays under the 100 ms `node_status_rpc` timeout — but if you swap any region for one that pushes a pair over 100 ms (e.g., Azure `westeurope`), the controller will silently mark the > 100 ms-distant brokers `IS-ALIVE=false` even when they're healthy, and the autobalancer makes decisions on the wrong data. Keep all three regions on the same continent and the chained-controller path stays under budget.

**Watch it in Console / Grafana while the demo runs.**

| Surface | What to point at | What to expect |
|---|---|---|
| **Console** → Topics → `leader-pinning-demo` → Partitions | The leader column for every partition | Flips from broker IDs in rack=aws (step 2) to rack=gcp (step 4), then back to rack=aws (step 5) |
| **Console** → Topics → `load-test` → Consumer Groups → `omb-consumer` | Lag column | \~0 in steady state; spikes during the cordon window; drains back to \~0 once leaders relocate |
| **Grafana** → Redpanda → "Kubernetes Redpanda" → throughput panels | Per-rack produce / consume MB/s | Sustained \~30 MB/s with a brief dip during leader re-election |
| **Grafana** → same dashboard → leader-count panels | Leader count by rack | Steps from `aws=12, gcp=0, azure=0` to `aws=0, gcp=12, azure=0` and back |
| **`kubectl logs -f job/omb-producer`** | Per-5s `records sent / records/sec / avg latency / max latency` | Throughput pauses for \~5–30 s during leader migration, then returns to \~7680 records/sec |

**Step 5 — restore AWS and watch leaders return**

Uncordon the rp-aws nodes; the pending broker pods schedule immediately:

```bash
for N in $(kubectl --context rp-aws get nodes -o name); do
  kubectl --context rp-aws uncordon "$N"
done
```

Brokers rejoin (\~60 s), partitions catch up, the leader balancer moves leaders back to AWS (rank 1 in `ordered_racks`). After \~2 min:

```bash
kubectl --context rp-aws -n redpanda exec redpanda-rp-aws-0 -c redpanda -- \
  rpk topic describe leader-pinning-demo -p | awk 'NR>1 {print $2}' | sort | uniq -c
```

```
   6 0
   6 1
```

Console / Grafana show the leader-count panel flip back to `aws=12, gcp=0, azure=0`. The `omb-consumer` group's lag (which spiked during the cordon window) drains within seconds — that's the visible end-to-end signal that the cluster rode through a full-cloud outage with continuous client traffic.

**Caveats observed in this scaffold:**

- **Leader balancer stalls during under-replicated periods.** When a whole cloud's brokers go away, the balancer pauses while the cluster is recovering, then resumes once partitions are re-replicated. Expect 30–90 s of "leaders not yet redistributed" while replicas are being rebuilt elsewhere.
- **EKS NLBs may be reaped during long cordons.** If you keep AWS cordoned for more than \~10–15 min, the AWS Load Balancer Controller (whose pods are also Pending on cordoned nodes) stops reconciling, and any LB it owns can be reaped by the cloud LB controller. The `rp-aws-multicluster-peer` LB is the one that matters — if it's gone, the rp-gcp / rp-azure operator pods drop their AWS-peer connection until you uncordon and the LB is recreated. For Demo A's short cycle this doesn't bite; it does for Demo B (which deliberately leaves AWS down).
- **`rpk redpanda admin brokers list` may briefly show un-affected brokers as `IS-ALIVE=false`.** During transitions, cross-cloud heartbeats can flap. Confirm against `rpk cluster health` (`Nodes down:` field), which uses the controller's authoritative view — except when the controller itself sits across a > 100 ms RTT line (see the Azure caveat above).
- **Within-rack leader split lands at 4/8 not 6/6 after AWS recovery.** The `ordered_racks` rack-priority semantics work (12 leaders return to AWS), but the leader balancer doesn't always even out across the two AWS-rack brokers. `rpk cluster partitions transfer-leadership <topic> --partition <pid>:<broker>` works to nudge specific partitions, but the balancer may move them back. Not a blocker — the rack-pin objective is met. Filing a follow-up issue makes sense if intra-rack evenness becomes a hard requirement.
- **GKE kubectl-exec sessions get reset by the API server LB on commands lasting >60 s.** During Demo A I hit `connection reset by peer` on long `rpk` queries against rp-gcp brokers. Workaround: anchor long-running queries on rp-aws or rp-azure (the EKS / AKS API servers don't have the same idle-LB behavior).
- **Don't run OMB at 30 MB/s for hours without 200Gi PVCs + 1h retention.** All five brokers will hit `no space left on device` and crashloop simultaneously. Recovery requires online PVC expansion (`kubectl patch pvc datadir-... -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'`) on every broker + force-delete the crashlooping pods to trigger the FS resize on remount. `<cloud>/manifests/stretchcluster.yaml` is now sized for this; only an issue if you bring up the cluster from a pre-2026-05-03 snapshot.

## Demo B: regional failure + capacity injection (cross-cloud variant)

> Adapted from the same-cloud beta's [Demo B: regional failure + temporary failover-region capacity injection](https://github.com/david-yu/redpanda-operator-stretch-beta#demo-b-regional-failure--temporary-failover-region-capacity-injection). The narrative is the same — `RF=5` with only 3 of 5 brokers reachable can't self-heal, the partition autobalancer stalls with `Over Disk Limit`/`unavailable_nodes` violations, and you fix it by **adding a 5th-broker-equivalent of capacity** so re-replication can complete.
>
> **The same-cloud beta does capacity injection by spinning up a 4th K8s cluster** (`<cloud>/terraform-failover/`) in a separate region. That path doesn't trivially port to cross-cloud — see [Why a 4th K8s cluster is hard cross-cloud](#why-a-4th-k8s-cluster-is-hard-cross-cloud) below — so the cross-cloud variant uses **NodePool scale-up on an existing cluster** instead. The lesson the demo teaches (RF=5 stall → capacity injection → rebalance → drain) is identical; only the capacity-injection mechanism differs.

### Why a 4th K8s cluster is hard cross-cloud

Same-cloud Demo B's 4th K8s cluster sits inside the same cloud's L3 mesh (TGW / global VPC / VNet peering). Cross-cloud, every layer needs an extension:

1. **IPsec VPN mesh becomes 4-endpoint.** A 4th cluster needs 6 new IPsec tunnels (failover↔aws, failover↔gcp, failover↔azure, both directions per peering rules) on top of the existing 6. Each cloud's VPN gateway has a per-connection cost (AWS $0.05/hr, Azure $0.04/hr per VPN connection) — Demo B alone adds ~$0.30/hr in VPN connection fees.
2. **Cilium ClusterMesh becomes 4-cluster (6 pairs).** Each pair needs `cilium clustermesh connect --allow-mismatching-ca`. The clustermesh-apiserver's TLS server-cert workaround ([cilium#43099](https://github.com/cilium/cilium/issues/43099)) has to apply to the 4th cluster too. The KVStoreMesh sync has more peers, so the post-connect settle window grows from \~60s to \~2-3 min.
3. **Operator multicluster bootstrap becomes 4-peer.** `rpk k8s multicluster bootstrap` has to be re-run with all 4 contexts. The existing 3-cluster operator deployments may need their helm values' `multicluster.peers` block re-rendered + `helm upgrade` for them to pick up the new peer's LB hostname.
4. **Adding the 4th cluster mid-failure is fragile.** The same-cloud beta's [AWS-only callout](https://github.com/david-yu/redpanda-operator-stretch-beta#demo-b-regional-failure--temporary-failover-region-capacity-injection) calls out two issues that all hit cross-cloud too:
   - The new operator pod's startup needs every peer reachable; if rp-aws is cordoned and AWS LBC has reaped its multicluster-peer NLB, the failover operator hangs on `name resolver error: produced zero addresses` until you temporarily uncordon AWS to let the failover operator fetch peer kubeconfigs.
   - Cross-cloud RTT — if any failover↔surviving-peer pair exceeds 100 ms, Redpanda's hardcoded `node_status_rpc` timeout silently corrupts the cluster's `unavailable_nodes` view. The us-east-1 / us-east1 / eastus triple chosen for this scaffold stays under 100 ms pairwise; a 4th region in the same continent (e.g. AWS us-west-2) keeps that property if the controller stays in the eastern triple, but the controller can re-elect into the failover region and skew the timing budget.

If you want the faithful 4th-K8s-cluster path, the work is roughly:
- New `aws-failover/terraform/` (or gcp / azure) with EKS in a 2nd region, public subnets, no VPC CNI, EBS CSI driver + default `ebs-sc` SC, mirroring `aws/terraform/`
- New `vpn/terraform/aws-failover.tf` (or similar) for 4 new IPsec tunnels (2 to gcp, 2 to azure) plus VPC peering to rp-aws (intra-AWS, $0.02/GB regional egress, much cheaper than IPsec)
- Extend `scripts/{install-cilium,connect-mesh,bootstrap-redpanda,teardown}.sh` to handle a 4th context
- New `aws-failover/manifests/{stretchcluster,nodepool}.yaml` with `rack: aws-failover` and NodePool replicas=2

### Cross-cloud Demo B walkthrough (NodePool scale-up variant)

Pre-reqs: full bring-up + Demo A done (so we know the 5-broker baseline works), OMB Jobs running for visible load.

The committed manifests have:

```yaml
config:
  cluster:
    partition_autobalancing_node_availability_timeout_sec: 600   # 10 min
    partition_autobalancing_node_autodecommission_timeout_sec: 900  # 15 min
```

These keep the demo runnable in a single sitting (autodecom kicks in 15 min after the cordon, well before the demo timer wins).

**Step 1 — simulate AWS regional failure (same as Demo A step 3)**

```bash
for N in $(kubectl --context rp-aws get nodes -o name); do
  kubectl --context rp-aws cordon "$N"
done
kubectl --context rp-aws -n redpanda delete pod \
  redpanda-rp-aws-0 redpanda-rp-aws-1 --grace-period=10
```

**Step 2 — observe the partition autobalancer stall**

After ~10 min (`node_availability_timeout`), check from a surviving cluster:

```bash
kubectl --context rp-azure -n redpanda exec redpanda-rp-azure-0 -c redpanda -- \
  rpk cluster partitions balancer-status
```

```
BALANCER STATUS
===============
Status:                      stalled
Unavailable Nodes:           [0, 1]      ← AWS brokers
Over Disk Limit Nodes:       []
Current Reassignment Count:  0
```

`Status: stalled` + `unavailable_nodes: [0, 1]` is the failure mode the demo is *demonstrating*. Under-replicated partitions show up too:

```bash
kubectl --context rp-azure -n redpanda exec redpanda-rp-azure-0 -c redpanda -- rpk cluster health
# Healthy: false
# Under-replicated partitions: <every RF=5 topic>
```

> **Cross-cloud caveat applies here too.** If the controller raft re-elected into a broker whose pairwise RTT to another surviving broker exceeds 100 ms, `unavailable_nodes` will report the *wrong* set (e.g., a healthy peer whose heartbeat fell into the timeout black hole). The us-east-1 / us-east1 / eastus triple stays under 100 ms; if you swap any region for a far one (e.g. eu-west-1), this matters. Same gotcha as Demo A's "Cross-cloud heartbeat caveat".

**Step 3 — inject capacity by scaling up the rp-gcp NodePool**

Same-cloud Demo B step 3 brings up a whole new K8s cluster here. The cross-cloud variant scales an existing NodePool — same outcome (5 reachable brokers), much less plumbing.

> **Pre-req: GKE cluster needs ≥4 nodes.** With `gcp/terraform`'s default `node_count = 2` per zone (6 nodes total), there's headroom. If you're upgrading from the pre-2026-05-04 default of `node_count = 1` (3 nodes total) you need to bump GKE first, otherwise the 4th broker pod sits `Pending` with cluster-autoscaler reporting `Pod didn't trigger scale-up`:
>
> ```bash
> # If running on the old 3-node default, resize first:
> gcloud container clusters resize rp-gcp --node-pool default \
>   --num-nodes 2 --region us-east1 --project <your-gcp-project> --quiet
> # Then re-annotate the new nodes (bootstrap-redpanda.sh only annotates
> # at bootstrap time; new nodes from a resize come up unannotated):
> ./scripts/annotate-rack.sh
> ```

```bash
kubectl --context rp-gcp -n redpanda patch nodepool rp-gcp \
  --type=merge -p '{"spec":{"replicas": 4}}'
```

The operator reconciles → 2 new broker pods schedule on rp-gcp → broker IDs 5 + 6 join the cluster. Watch them come up:

```bash
kubectl --context rp-gcp -n redpanda get pods -l app.kubernetes.io/name=redpanda -w
```

**Step 4 — autobalancer un-stalls and rehomes the AWS brokers' replicas**

Once the new brokers are `IS-ALIVE=true` (~3-5 min), the autobalancer transitions from `stalled` to `in_progress`:

```bash
kubectl --context rp-azure -n redpanda exec redpanda-rp-azure-0 -c redpanda -- \
  rpk cluster partitions balancer-status
```

```
Status:                      in_progress
Unavailable Nodes:           [0, 1]
Current Reassignment Count:  18
```

After `node_autodecommission_timeout` (15 min from the cordon, ~5-10 min from the GCP scale-up), the AWS brokers (0, 1) are auto-decommissioned. `rpk cluster health` settles to `Healthy: true` with the new layout: 4 GCP + 1 Azure brokers, RF=5 (max RF the 5 surviving brokers can carry, which matches the original RF=5 — convenient).

**Step 5 — restore AWS (uncordon)**

```bash
for N in $(kubectl --context rp-aws get nodes -o name); do
  kubectl --context rp-aws uncordon "$N"
done
```

The AWS broker pods schedule back; **but they were auto-decommissioned in step 4, so they re-join as new broker IDs (7, 8) rather than re-claiming 0 + 1**. The cluster now has 7 brokers in state and 7 in the broker list. That's the expected end-state of a same-cloud Demo B run too.

**Step 6 — drain the temporary GCP capacity**

Same-cloud Demo B decommissions the 4th cluster's brokers here. The cross-cloud variant scales the rp-gcp NodePool back down:

```bash
kubectl --context rp-gcp -n redpanda patch nodepool rp-gcp \
  --type=merge -p '{"spec":{"replicas": 2}}'
```

The operator decommissions the two scale-up brokers (5, 6) gracefully, replicas migrate to the AWS brokers (7, 8), and the cluster returns to the original 2/2/1 layout (just with different broker IDs).

### Known issues for cross-cloud Demo B (validated 2026-05-03)

Inherited from same-cloud Demo B and confirmed cross-cloud:

- **`partition_balancer/status` reports the wrong `unavailable_nodes` set when the controller leader sits >100 ms from any surviving broker.** Mitigation: keep the regions in the same continent (the default `us-east-1` / `us-east1` / `eastus` triple is fine).
- **Under-replicated topics show in *every* topic's describe**, including internal ones (`__consumer_offsets`, transaction state). That's expected — RF=5 internal topics are also affected.
- **Auto-decommission only fires on brokers that have been continuously unreachable for `autodecom_timeout`.** Patching the NodePool replicas back up before the timeout fires means the original brokers (0, 1) come back instead of being decommissioned, which leaves you with 7 active brokers and no auto-cleanup. Time the demo accordingly.

Cross-cloud-specific:

- **NodePool scale-up takes longer cross-cloud than same-cloud** because the new pods have to fetch operator-managed mTLS material from a peer cluster's API server over the IPsec VPN before joining the multicluster. Budget ~5-7 min from the patch to "broker `IS-ALIVE=true`" instead of the same-cloud beta's 3-5 min.
- **AWS LBC reap risk on long cordons.** Same gotcha as Demo A — but Demo B's cordon is 15+ min, well past the LBC's reap timer. If `rp-aws-multicluster-peer` NLB gets reaped, the rp-gcp / rp-azure operator pods log `failed to fetch peer kubeconfig from rp-aws ...` and stay in that state until you uncordon AWS (LBC pods come back, recreate the LB, peer connectivity restores). Workaround: temporarily uncordon AWS for ~2 min between Demo B's steps 3 and 4 to let LBC re-establish the LB if it was reaped, then re-cordon to continue the demo. Less invasive than the same-cloud beta's analogous workaround because we're not provisioning a new operator.
- **OMB workload disk pressure compounds the demo.** Demo B's 15-min cordon + GCP scale-up adds significant cross-cloud egress (replica catch-up to the new brokers traverses the VPN). At 30 MB/s baseline the catch-up phase pushes 60–90 MB/s of cross-cloud traffic for a few minutes — budget another \~$2-5 in egress on top of the steady-state \~$29/hr.

## Cost

Rough estimate (`us-east-1` / `us-east1` / `eastus`):

| Component | $/hr |
|---|---|
| EKS control plane | $0.10 |
| 2× m5.xlarge | $0.38 |
| AWS Site-to-Site VPN (2 connections × $0.05/hr) | $0.10 |
| GKE regional control plane | $0.10 |
| 3× n2-standard-4 (regional cluster, `node_count=1` × 3 zones) | $0.58 |
| GCP HA VPN gateway (2 tunnels active × $0.05/hr) | \~$0.10 |
| AKS control plane (free tier) | $0.00 |
| 2× Standard_D4s_v5 | $0.38 |
| Azure VPN Gateway (VpnGw1 sku) | $0.19 |
| Cross-cloud LBs (3× NLB / Standard LB) | \~$0.07 |
| Cilium clustermesh-apiserver LB (3 of) | \~$0.05 |
| Console + Grafana NLBs on rp-aws (step 9, only when running the demo addons) | \~$0.04 |
| Broker data PVCs (5× 500Gi: 2 EBS gp3 on AWS, 2 pd-balanced on GCP, 1 Azure Managed Disk Standard) | \~$0.30 |
| **Compute + VPN + LB + storage subtotal** | **\~$2.39/hr** |

The broker PVC line item is sized for both Demo A and Demo B. Sizing iterations:

- Chart default: 20Gi → cluster crashes every \~11 min under OMB 30 MB/s × RF=5 (caught 2026-05-03 e2e v1)
- Bumped to 200Gi → Demo A runs cleanly, but Demo B's capacity-injection step re-stalls the autobalancer with `Over Disk Limit Nodes` because the new broker has to receive \~108GB of historical replica data within the 1-hour retention window while existing brokers keep serving steady-state writes (caught 2026-05-04 e2e v3)
- Bumped to **500Gi** → 400GB usable headroom (at the 80% autobalancer threshold) absorbs catch-up + ongoing load; Demo B completes through to fully `ready` state

If you don't plan to run Demo B (the capacity-injection demo), 200Gi is enough and saves \~$0.18/hr.

### Cross-cloud egress (the dominant cost under load)

The compute subtotal above is the floor. Cross-cloud network egress is the variable that scales with throughput and **dominates total cost during the OMB demo workload**.

**Per-provider egress rates** (public list price, US-region origins, traffic leaving the cloud's AS — including over the IPsec VPN, which is billed at standard internet-egress rates by all three providers):

| Origin | Rate | Notes |
|---|---|---|
| AWS (us-east-1) | $0.09/GB | Standard internet egress. AWS Site-to-Site VPN traffic is billed at this rate; the per-VPN-connection $0.05/hr is already in the fixed-cost subtotal. First 100 GB/month free across the account. |
| GCP (us-east1) | $0.12/GB | Internet egress to "Worldwide destinations excluding China and Australia". Cloud Interconnect / Cloud VPN traffic uses the same rate. |
| Azure (eastus) | $0.087/GB | Internet egress (first 100 GB/month free). VPN Gateway data transfer uses standard egress pricing. |

**What the OMB demo workload actually costs in egress.** With OMB producing 30 MB/s on the AWS-pinned leader brokers (`ordered_racks:aws,gcp,azure`), every record gets replicated to all 4 followers:

- 2 AWS-local followers → no egress (intra-VPC)
- 2 GCP followers → 30 MB/s × 2 = 60 MB/s out of AWS, 0 inbound charge on GCP
- 1 Azure follower → 30 MB/s × 1 = 30 MB/s out of AWS

So the producer side (AWS) emits **\~90 MB/s = \~324 GB/hr cross-cloud** under sustained 30 MB/s OMB load. At AWS's $0.09/GB:

- **\~$29.16/hr in AWS egress under 30 MB/s OMB sustained load**

The OMB consumer adds back-pressure on whichever cloud the consumer pod runs in (we run it on rp-aws, so most consume traffic stays AWS-local). If you move the consumer to rp-gcp or rp-azure, expect another \~$15–$30/hr of egress out of GCP / Azure for the consume path.

**Idle cost** (no client traffic, brokers + operators + clustermesh sync + BGP keepalives):

- Broker raft heartbeats: \~5–10 KB/s per peer pair × 10 cross-cloud broker pairs ≈ 100 KB/s ≈ 350 MB/hr ≈ **$0.03/hr**
- Cilium clustermesh-apiserver KVStoreMesh sync: \~10 KB/s per peer pair × 6 pairs ≈ 60 KB/s ≈ **$0.02/hr**
- Operator multicluster raft: similar order, **$0.01/hr**
- BGP keepalives over VPN tunnels: trivial, **<$0.01/hr**
- **Idle egress total: \~$0.06–$0.10/hr** (matches the README's prior "$5–$30/day idle" claim — closer to the lower end with the static-routes VPN config we now ship)

**Summary**:

| Mode | Compute + LB + storage | Cross-cloud egress | Total |
|---|---|---|---|
| Idle (cluster up, no client traffic) | $2.21/hr | \~$0.08/hr | **\~$2.29/hr** |
| Demo A run (30 MB/s OMB, RF=5, AWS-pinned leaders) | $2.21/hr | **\~$29/hr** | **\~$31/hr** |

A Demo A run that takes \~3-4 hours of bring-up + walkthrough + teardown lands at **\~$30 in compute + \~$60–$120 in egress** depending on how long OMB runs. Drop OMB throughput proportionally for cheaper iterations — `--throughput 1280 --record-size 1024` (the same-cloud beta's \~10 Mbps default) cuts egress 24× to \~$1.20/hr.

### Same-cloud cross-region is dramatically cheaper

If your demo / validation doesn't *specifically* require cross-cloud, use [`redpanda-operator-stretch-beta`](https://github.com/david-yu/redpanda-operator-stretch-beta) instead. It runs a StretchCluster across three regions of a single cloud, which keeps egress on each provider's much-cheaper inter-region rate. Numbers below are pulled directly from that repo's [cross-region data transfer table](https://github.com/david-yu/redpanda-operator-stretch-beta#cross-region-data-transfer-variable-per-gb--the-cost-that-scales-with-throughput), which has the per-cloud breakdown including both-direction billing (AWS TGW data-processing, Azure peering ingress+egress) — so these are not just the egress headline rate:

| Egress path | Effective rate | 30 MB/s OMB cost (\~324 GB/hr cross-region) |
|---|---|---|
| AWS inter-region (us-east-1 ↔ us-west-2 via TGW) | $0.04/GB ($0.02 egress + $0.02 TGW) | **\~$8.60/hr** |
| GCP inter-region (us-east1 ↔ us-west1) | $0.02/GB (one-side egress) | **\~$4.30/hr** |
| Azure inter-region (eastus ↔ westus2 via peering) | $0.04/GB ($0.02 each direction) | **\~$8.60/hr** |
| **Cross-cloud (this repo)** | $0.087–$0.12/GB | **\~$29/hr** |

That's a **3.4–6.7× egress saving** at the same workload (GCP best-case, AWS / Azure worst-case), plus you skip the IPsec VPN tier entirely (no `vpn/terraform/`, no static-route plumbing, simpler tear-down). The same-cloud beta also has a more thorough fixed-infra breakdown by cloud — Azure is cheapest fixed (\~$1.20/hr) thanks to the AKS Free tier, AWS is most expensive fixed (\~$2.50/hr) thanks to TGW attachment fees.

Use the same-cloud beta for: leader-pinning / `ordered_racks` validation, autobalancer behavior, multicluster operator raft, broker TLS work (which the same-cloud beta can actually run with TLS on, since #1499's hostname-mismatch only bites cross-cluster), Console / OMB / Prometheus integration testing.

Use **this** (cross-cloud) repo only for cross-cloud-specific stories: a 3-cloud failover demo, IPsec VPN tier validation, Cilium ClusterMesh on a cross-cloud underlay, or anything that explicitly needs the cluster to span provider boundaries.

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

Same finding as the same-cloud AWS run: the partition balancer's `node_status_rpc` heartbeat has a hardcoded \~100ms timeout. If the controller (`redpanda/controller/0` leader) lands in a cloud whose RTT to one of the other clouds exceeds 100ms, it perpetually marks that cloud's brokers unresponsive and won't auto-decom anything. Check current controller location with `rpk cluster health` (`controller_id` field), then force the controller to a low-RTT cloud:

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
- **`node_status_rpc` 100ms timeout.** Inherits the same constraint we hit on AWS in the same-cloud beta. Cross-cloud RTT is more variable than same-region — pick clouds in the same physical area (US East Coast triple: `us-east-1` / `us-east1` / `eastus` \~5-15 ms pairwise) and lean on `default_leaders_preference: "racks:aws,gcp,azure"` to keep the controller in the lowest-RTT cloud.
- **Public node IPs.** Every node is in a public subnet with a public IP for direct cross-cloud reachability. Production should use SD-WAN / IPsec VPN between clouds and put nodes in private subnets — left as an exercise.
- **Cilium WireGuard MTU.** Geneve + WireGuard adds \~80 bytes of overhead. If you see PMTU issues, override Cilium's MTU (`--set MTU=1380`).
- **Cross-cloud egress cost.** Already mentioned, worth repeating.
- **GKE Dataplane V2 + Cilium ClusterMesh are mutually exclusive.** GKE DPv2 *is* Cilium internally but Google's fork doesn't support clustermesh. The Terraform here picks `LEGACY_DATAPATH` so we can install standard upstream Cilium.
