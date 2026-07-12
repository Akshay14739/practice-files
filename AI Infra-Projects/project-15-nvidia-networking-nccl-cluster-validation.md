# Project 15 — Fabric: GPU Networking, NCCL Performance & Cluster Validation (+ AI-Factory Capstone) (NVIDIA 3/3)

**Difficulty:** ★★★★★ | **Time:** 3–4 weekends (mostly prep) + one 2–3 hr paid GPU window | **Cost:** ~$0 prep + ~$10 cheap-EFA rehearsal + **$56–90 for one 2-hr 2×p4d window** (p4d.24xlarge ≈ $21.96/hr on-demand, ≈ $13.93/hr spot in us-east-1 as of July 2026 — share the window with P10's multi-node drill)

*This is the one project that genuinely pays for a p4d. Everything else has an honest cheap substitute — MIG moved to a single-A100 box in P08 — but **8-GPU NVLink intra-node busbw and multi-node GPUDirect-over-EFA busbw do not**. You cannot fake NVSwitch, and you cannot fake a 4×100 Gbps fabric. So you rehearse the whole pipeline for pennies, buy exactly two hours of real hardware, and walk out with numbers nobody else in the loop has. Then you close the NVIDIA track by making it reproducible: the on-prem RDMA stack you'd meet at a lab (Network Operator), the hardware vocabulary of the machines you'd validate (DGX/SuperPOD BOM), and one command that stands the whole factory back up.*

## 1. The production problem

This is the **GPU-neocloud JD** almost line for line: *"bare metal GPU node infrastructure, CNI configuration, GPU Operator setup, distributed storage backends, and RDMA/InfiniBand… deploy and validate Kubernetes."* When a lab receives 1,000 GPUs, someone must prove the **fabric** delivers before a single training job runs — a cluster that trains at 60 % of expected NCCL bandwidth silently doubles the cost of every run. That acceptance discipline (NVIDIA formalizes it for SuperPODs; every cloud team reinvents it) is a hireable specialty.

Concepts you'll own: **RDMA** (NIC reads/writes app memory directly, bypassing the kernel), **GPUDirect RDMA** (NIC ↔ GPU HBM directly, bypassing host RAM — tens of GB/s vs a bounce-buffer crawl), **EFA** (AWS's RDMA-class fabric: a Nitro device doing OS-bypass over the **SRD** protocol through the **libfabric** API — *not* InfiniBand, *not* RoCE), **NVLink/NVSwitch** (intra-node, ~an order of magnitude faster than the inter-node fabric — why topology-aware placement matters), and **NCCL** (the collectives library whose `busbw` number *is* your cluster's health).

**The fact that separates people who have done this from people who have read about it:** on AWS, EFA is the *only* RDMA fabric — InfiniBand and RoCE are not offered (NVIDIA says so in its own Dynamo/EKS docs). The AWS stack is `EFA kernel driver → aws-efa-k8s-device-plugin → libfabric → aws-ofi-nccl`. NVIDIA's **Network Operator**, DOCA-OFED, `NicClusterPolicy` and SR-IOV belong to a different world — bare-metal ConnectX/InfiniBand, the world of a lab that owns its racks. You **build** the first and **study** the second. Anyone who tells you to install the Network Operator on EKS to get RDMA has never done it.

## 2. Architecture

```
 eksctl: EFA-enabled nodegroup in ONE AZ + cluster placement group
   ├─ GPU Operator (drivers, DCGM)          ├─ aws-efa-k8s-device-plugin (vpc.amazonaws.com/efa)
   ├─ AMI ships EFA driver + aws-ofi-nccl (the NCCL→libfabric shim)
   └─ Kubeflow MPI Operator ─▶ nccl-tests MPIJobs (the measurement)
 Validation suite: dcgmi diag → gpu-burn → NCCL intra-node → NCCL inter-node
                   → storage fio (FSx Lustre) → signed acceptance report
 Scheduling tie-in: topology.k8s.aws/network-node-layer-* labels → Kueue TAS / your P07 scheduler
 Capstone ($0):    Network Operator CRD walkthrough on kind (the on-prem/IB equivalent)
                   + DGX/SuperPOD BOM doc + one-command GitOps bring-up of the whole factory
```

## 3. Phase 1 — provision the fabric correctly ($0 until apply)

`cluster.yaml` (eksctl does the EFA heavy lifting — launch-template ENIs, security groups):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata: {name: fabric-lab, region: us-east-1, version: "1.31"}
managedNodeGroups:
- name: gpu-efa
  instanceType: p4d.24xlarge          # 8×A100 40GB SXM4, 4×100 Gbps EFA. Budget rehearsal: see below
  desiredCapacity: 2
  availabilityZones: ["us-east-1c"]   # ONE AZ — EFA traffic cannot cross AZs/VPCs and is not routable
  efaEnabled: true                    # attaches all EFA interfaces + self-referencing SG
                                      # ...and deploys aws-efa-k8s-device-plugin for you
  placement: {groupName: fabric-lab-pg}   # cluster placement group (create it first)
  capacityReservation: ...            # ODCR or EC2 Capacity Blocks; p4d spot is scarce
```

Rules that bite people (memorize): **one AZ**; **cluster** placement group; the EFA security group must allow **all traffic to/from itself**; EFA pods need `hugepages-2Mi` *and* the `vpc.amazonaws.com/efa` extended resource; sub-8xlarge G sizes have **no** EFA at all. Capacity Blocks for ML *do* support P4d, but only in **us-east-2** and **us-west-2** — plan the region if you want a guaranteed window. EFA itself is free.

**Budget rehearsal (do this first, twice):** run the whole pipeline on **2× g6.8xlarge** (~$2.01/hr each on-demand, ~$1.11/hr spot ⇒ ~$4/hr for the pair, July 2026) — Nitro v4, EFA *with* RDMA read+write, cheaper *and* better than the g4dn.8xlarge (~$2.18/hr) / g5.8xlarge (~$2.45/hr) pairs people usually reach for. Two caveats to state rather than hide: (a) AWS's official *"Get started with EFA and NCCL"* guide nominally supports **only P-series**, and `FI_EFA_USE_DEVICE_RDMA=1` is documented for p4d and above — NCCL-over-EFA on G-series works via `aws-ofi-nccl` but is **functional rehearsal, not performance-representative** (one EFA interface, one GPU, no GPUDirect RDMA on g4dn/g5); (b) both nodes must share one subnet/AZ and one placement group.

```bash
helm repo add eks https://aws.github.io/eks-charts
# eksctl's efaEnabled already deploys this; install explicitly on self-managed nodegroups.
# chart v0.5.29 / app v0.5.20 as of July 2026 — pin it; p6-b200 needs >= v0.5.6
helm upgrade -i aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin -n kube-system --version 0.5.29
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
# GPU Operator from P08 (driver.enabled=false if the EKS GPU AMI ships drivers)
```

**The RDMA stack, named correctly** — say this out loud in the interview:

| Layer | AWS/EKS (hands-on here) | On-prem InfiniBand/RoCE (Phase 4, study) |
|---|---|---|
| Kernel/driver | EFA kernel driver (in the EKS GPU / DL AMI) | DOCA-OFED driver container (Network Operator) |
| K8s resource | `aws-efa-k8s-device-plugin` → `vpc.amazonaws.com/efa` | RDMA shared + SR-IOV device plugins → `rdma/...` |
| Transport API | libfabric, EFA provider, SRD protocol | libibverbs / RDMA-CM over IB or RoCE |
| NCCL shim | `aws-ofi-nccl` (v1.20.0, June 2026) | NCCL's native IB plugin (no shim) |
| GPU mem registration | DMA-BUF (kernel ≥ 5.12; default on p5/p6 AMIs) or `nvidia-peermem`/`efa_nv_peermem` | `nvidia-peermem` / DMA-BUF; GPUDirect RDMA via GPU Operator v25.3+ |

GPUDirect RDMA **does** work over EFA — supplied by the AWS stack, not NVIDIA's IB stack. Know the generation split: **p4d/p4de are EFA v1 → RDMA *read* only, no RDMA write**; p5/p5e/p5en and p6-b200/p6-b300/p6e-gb200 do read **and** write. That one line explains your p4d inter-node numbers.

## 4. Phase 2 — the measurement: nccl-tests via MPIJob

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata: {name: allreduce-2node}
spec:
  slotsPerWorker: 8
  runPolicy: {cleanPodPolicy: Running}
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
          - name: launcher
            image: <ecr>/nccl-tests:cuda12-efa    # aws-samples/awsome-distributed-training has Dockerfiles
            command: ["mpirun","--allow-run-as-root","-np","16","--map-by","ppr:8:node",
              "-x","FI_PROVIDER=efa","-x","FI_EFA_USE_DEVICE_RDMA=1",
              "-x","NCCL_DEBUG=INFO","-x","NCCL_SOCKET_IFNAME=^lo,docker",
              "/opt/nccl-tests/build/all_reduce_perf","-b","8","-e","2G","-f","2","-g","1"]
    Worker:
      replicas: 2
      template:
        spec:
          containers:
          - name: worker
            image: <ecr>/nccl-tests:cuda12-efa
            resources:
              limits: {nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 4,
                       hugepages-2Mi: 5120Mi, memory: 800Gi}
              requests: {memory: 800Gi}
```

**Reading the output** (this is the skill): `algbw` = bytes/time; **`busbw`** = algbw adjusted for the collective's traffic pattern (allreduce ×2(n−1)/n) — the hardware-comparable number. Run three ladders, tabulate busbw at 1 GiB:

1. **Intra-node** (1 node, 8 ranks): the NVLink/NVSwitch path — expect it to dwarf everything else (order 200+ GB/s on 8×A100; **record yours**). This is the number you cannot get on a cheap box — the reason this project owns the p4d window.
2. **Inter-node with GPUDirect** (`FI_EFA_USE_DEVICE_RDMA=1`): p4d's 4×100 Gbps EFA ⇒ 50 GB/s theoretical line rate; record the busbw you actually achieve at large sizes as a **% of line rate**. Remember p4d is EFA v1 (RDMA read only).
3. **Inter-node crippled** (`FI_PROVIDER=tcp`): watch it collapse — your control group, and the exact signature of a misconfigured production cluster.

Confirm the data path in `NCCL_DEBUG=INFO`: `NET/OFI Selected Provider is efa` and `[send/recv via NET/AWS Libfabric]`. If you see `NET/Socket`, you are on TCP and every number is a lie. Also run `all_gather_perf` and `reduce_scatter_perf` (FSDP's real traffic — what P10 will hammer) and small message sizes (latency regime), not just bandwidth.

Tuning knobs (one variable at a time, record deltas): `NCCL_ALGO=Ring|Tree`, `NCCL_PROTO=Simple|LL128`, `NCCL_BUFFSIZE`, `NCCL_NSOCKS_PERTHREAD` (TCP only), channels via `NCCL_MIN/MAX_CTAS`. The meta-lesson: defaults are good; you tune to *diagnose*, rarely to run.

## 5. Phase 3 — the acceptance suite (the deliverable)

`validate.sh` — run on every node/pair, emit a signed markdown report. This is *cluster*-level acceptance; the training-job-level checks (goodput, MFU, straggler detection, flight recorder, checkpoint restart) live in **P10 (project-10-fault-tolerant-training-goodput.md)** — cross-link, don't duplicate. A node that passes this suite is what P10 assumes it stands on.

1. **Inventory**: `nvidia-smi -q` (ECC on, expected clocks), `nvidia-smi topo -m` (the NVLink matrix — screenshot it), `fi_info -p efa` (all EFA devices visible).
2. **Health**: `dcgmi diag -r 3` (add `-r 4` in the p4d window if time allows) — the NVIDIA burn-in standard; any fail ⇒ node rejected. This is the admission gate P10's remediator enforces and P12's fleet loop re-runs on a schedule.
3. **Stress**: `gpu-burn 600` per GPU — watch `DCGM_FI_DEV_GPU_TEMP` / `DCGM_FI_DEV_POWER_USAGE`; a thermally weak GPU is tomorrow's straggler.
4. **Fabric**: the three NCCL ladders; pass = ≥ 85 % of your recorded healthy baseline. Also assert `NET/OFI Selected Provider is efa` appears in the log — a bandwidth threshold alone can be met by a lucky TCP run on small messages.
5. **Storage**: FSx-for-Lustre PVC + `fio` (seq read 1M × 16 jobs, randread 4k) — checkpoints (P10) die on slow storage; record GB/s vs provisioned throughput. (Name Rook/Ceph and Weka as self-managed alternatives; cross-link **P11**.)
6. **GPU Operator validator**: `nvidia-operator-validator` runs CUDA + device-plugin + toolkit sanity automatically. Capture the green check and pin the **NVIDIA Cloud Native Stack** version set you reproduced (the K8s + driver + operator combo NVIDIA tests together) in `docs/validated-stack.md`. Boring-looking, extremely credible — reproducing a validated version matrix is what GPU-cloud onboarding engineers do all day.
7. **Topology proof**: `kubectl get nodes -L topology.k8s.aws/network-node-layer-3` — then run a 2-node NCCL job **with** Kueue TAS `podset-required-topology: …layer-3` vs **without**, on a > 2-node pool. Same-leaf vs cross-spine busbw delta = the empirical justification for **P07's** topology-aware scheduler.

Emit `acceptance-report-<node>-<date>.md` with a checksum and raw logs. Call it a **node birth certificate**; feed it to **P12** as a metric and auto-quarantine on regression.

**Troubleshooting matrix** — build it from faults you *inject*. This table is half the interview value of the project:

| Symptom | Root cause | Where to look / fix |
|---|---|---|
| Inter-node busbw stuck in single-digit GB/s | TCP fallback: `aws-ofi-nccl` missing or `FI_PROVIDER` unset | `NCCL_DEBUG=INFO` shows `NET/Socket`, not `NET/OFI`; check plugin on `LD_LIBRARY_PATH` |
| Pods `Pending` forever | `vpc.amazonaws.com/efa` or `hugepages-2Mi` not requested / not advertised | `kubectl describe node`; is the EFA device-plugin DaemonSet running? |
| `fi_info -p efa` returns nothing | EFA SG not self-referencing, or nodegroup launched without `efaEnabled` | Fix the SG (all traffic to/from itself), relaunch the nodegroup |
| Ranks cannot connect across nodes | Nodes in different AZs/subnets — EFA **cannot** cross AZs and is not routable | One AZ, one subnet, one **cluster** placement group |
| Good bandwidth, bad latency | Cross-leaf / cross-spine placement | `topology.k8s.aws/network-node-layer-*` + Kueue TAS (**P07**) |
| One slow rank drags the collective | Thermally throttling GPU | DCGM temps/power; `dcgmi diag -r 3`; drain the node |
| GPUDirect never engages | No DMA-BUF (kernel < 5.12) or `nvidia-peermem` not loaded | `lsmod \| grep peermem`; on p4d recall EFA v1 = RDMA read only |
| NCCL hang, no error | Rank desync / dead peer | NCCL flight recorder + the hang playbook in **P10** |

## 6. Phase 4 — the Network Operator: the RDMA stack that is *not* on EKS (study + CRD walkthrough, $0)

Every neocloud/lab JD says "RDMA/InfiniBand." Most portfolios answer it by installing the NVIDIA Network Operator on EKS — where it does nothing, because there is no ConnectX hardware for it to manage. Answering honestly *is* the differentiator.

**What it actually is** (v26.4.0 GA, June 2026 — year.month versioning, quarterly cadence; v26.7.0 in beta as of July 2026, so **pin your chart and check upstream**): the RDMA-side sibling of the GPU Operator, driven by one cluster-scoped `NicClusterPolicy`. It manages the **DOCA-OFED driver container** (successor to MOFED, with automatic driver upgrades), the **RDMA shared** and **SR-IOV** device plugins, **secondary networks** (Multus, containernetworking plugins, IPoIB CNI, MacVlan/HostDevice), **NVIDIA-IPAM** (`nv-ipam` — Whereabouts was **removed** in v25.10.0, so posts showing `ipamPlugin: whereabouts` are stale), **NIC Feature Discovery** (NFD labels nodes with PCI vendor `15b3`), and the **NIC Configuration Operator**. Other CRDs: `MacvlanNetwork`, `HostDeviceNetwork`, `IPoIBNetwork`, `NicDevice`/`NicConfigurationTemplate`, `NicNodePolicy` (new in v26.4.0, heterogeneous clusters). Purpose: RDMA (InfiniBand **and** RoCE), SR-IOV, and **GPUDirect RDMA** (with GPU Operator v25.3+) on **ConnectX-6/6Dx/7**, **ConnectX-8/9 SuperNICs**, and **BlueField-3 in NIC mode**.

**Where it applies:** bare-metal/on-prem DGX/HGX-class clusters, and cloud VMs exposing *real* ConnectX/IB devices (e.g. Azure's IB-enabled ND series). **Never EFA.** NVIDIA's platform-support matrix lists DGX/HGX, Grace and IGX on Ubuntu/RHEL/CoreOS/SLES — no AWS/EKS/EFA row, and neither AWS nor NVIDIA documents the Network Operator on EKS. (One sentence of nuance: the **GPU** Operator *is* supported on EKS — GPU side only.)

**The cheap hands-on you can honestly do:** install the operator + CRDs on **kind** and study the control plane. This matches upstream practice — the repo's own `docs/local-development.md` describes a minikube + skaffold dev environment (`make dev-skaffold`) that NVIDIA's developers use without RDMA hardware.

```bash
kind create cluster --name netop-lab
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install network-operator nvidia/network-operator \
  -n nvidia-network-operator --create-namespace --version 26.4.0 --set nfd.enabled=true
kubectl get crds | grep -E 'mellanox|nvidia'      # NicClusterPolicy, MacvlanNetwork, IPoIBNetwork, ...
kubectl explain nicclusterpolicy.spec --recursive | head -60
```

```yaml
# nic-cluster-policy.yaml — the object a real IB cluster runs. Apply it on kind, watch the controller.
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata: {name: nic-cluster-policy}      # cluster-scoped, exactly ONE per cluster
spec:
  ofedDriver:                              # DOCA-OFED driver container
    image: doca-driver
    repository: nvcr.io/nvidia/mellanox
    version: <pin-me>
  rdmaSharedDevicePlugin:
    config: |
      {"configList": [{"resourceName": "rdma_shared_device_a",
                       "rdmaHcaMax": 63,
                       "selectors": {"ifNames": ["ens1f0"]}}]}
  secondaryNetwork:
    multus: {}
    cniPlugins: {}
    ipoib: {}
    nvIpam: {}                             # nv-ipam (NOT whereabouts — removed in v25.10.0)
```

```bash
kubectl apply -f nic-cluster-policy.yaml
kubectl get nicclusterpolicy nic-cluster-policy -o yaml | yq '.status'
kubectl get ds -n nvidia-network-operator          # the DaemonSets exist... and schedule nowhere
kubectl get nodes -L feature.node.kubernetes.io/pci-15b3.present
```

**State the limits explicitly — that is what makes this credible rather than cargo-cult.** NFD gates the DOCA-OFED driver and device-plugin DaemonSets on nodes labelled `feature.node.kubernetes.io/pci-15b3.present=true`. On a NIC-less kind node those pods never schedule, `NicClusterPolicy` never reaches `ready`, and the chart's `helm test` (which pushes real RDMA traffic) cannot pass. **There is no data path here and you must not pretend there is.** What you *do* get is worth the weekend: the CRD surface, the operator's state machine, the Multus/NFD/IPAM wiring, and the ability to read someone's `NicClusterPolicy` and say what it will do. NVIDIA publishes no kind/minikube guidance for users — every official guide assumes real ConnectX adapters — so present this as a **CRD study lab**, not a deployment.

Optional out-of-scope side experiment for real RDMA verbs on commodity Ethernet: **Soft-RoCE** (`rdma link add rxe0 type rxe netdev eth0`, then `ib_write_bw`/`rping`). Genuine verbs, but outside the Network Operator's supported scope and deprecated in RHEL 10 — a curiosity, not a lab.

Write `docs/gpudirect.md` while you're here: GPUDirect **RDMA** (NIC ↔ GPU HBM) vs GPUDirect **Storage/GDS** (NVMe ↔ GPU, skipping the CPU bounce buffer) — the two data-movement optimisations that define factory-grade I/O.

## 7. Phase 5 — BOM & DGX/SuperPOD literacy ($0, one afternoon)

You will not buy a DGX; you will absolutely be asked to reason in DGX units. Write `docs/ai-factory-bom.md` and get the hardware *right* — most blog posts don't:

**DGX H100** — 8× H100 SXM (640 GB HBM3) · 4× 4th-gen **NVSwitch** (NVLink 4; 900 GB/s per-GPU GPU-to-GPU) · 2× Xeon Platinum 8480C (56c each) · 2 TB RAM · compute fabric = **4× OSFP ports serving 8× single-port ConnectX-7** (one NIC per GPU, up to 400 Gb/s IB or Ethernet) · storage/in-band = **2× dual-port QSFP112 ConnectX-7**. **No BlueField-3 in the DGX H100 BOM** — that is the mistake everyone repeats.

**DGX B200** — 8× B200 (1,440 GB HBM3e) · 2× 5th-gen **NVSwitch** chips (14.4 TB/s aggregate; 1.8 TB/s per-GPU NVLink) · 2× Xeon Platinum 8570 (56c each) · up to 4 TB RAM · compute fabric = 4× OSFP → **8× single-port ConnectX-7** (400 Gb/s, IB by default) · storage/in-band = **2× dual-port QSFP112 BlueField-3 DPUs**. Memorize the one-liner: *"ConnectX-7 per GPU on both H100 and B200; BlueField-3 appears for storage/in-band on B200 — H100 uses dual-port ConnectX-7 there instead."*

**DGX SuperPOD (H100 RA)** — the unit of scale is the **Scalable Unit (SU) = 32 DGX H100 = 256 GPUs**. Four fabrics, not one:

| Fabric | Hardware | Why it exists |
|---|---|---|
| Compute | **Quantum-2 (QM9700) NDR 400G InfiniBand, rail-optimized, 8 rails** | Each GPU's ConnectX-7 connects to its *own rail's* leaf switch, so traffic per rail is **always one hop away** from the other 31 nodes in the SU — this is what makes a 256-GPU all-reduce behave |
| Storage | Separate InfiniBand fabric (MQM9700-based) | > 40 GB/s per-node I/O target; checkpoints and data loading must not contend with collectives |
| In-band mgmt | SN4600C Ethernet | Provisioning, monitoring, cluster services |
| Out-of-band mgmt | SN2201 Ethernet | BMC/IPMI — the network you use when the node is dead |

The base RA scales to 4 SU / 128 nodes, and the architecture is documented "up to and beyond 64 SU with 2000+ DGX H100 nodes."

Now the exercise: for a stated target — *"train a 7B model on 64 GPUs and serve 50 models concurrently"* — size GPUs, nodes, rails, storage throughput and rack power/cooling, mapping every line to a real part number. **Then map your lab onto it:** p4d = 8× A100 + NVSwitch + 4×100 Gbps EFA ≈ a *rail-less* DGX-shaped node on a non-IB fabric. Explaining what your two-hour window did and did *not* reproduce beats anything a brochure gives you.

## 8. Phase 6 — one-command GitOps bring-up (the capstone)

A fresh cluster becomes an **AI factory** with one command. NVIDIA's layer model, with your projects mapped onto it:

```
 TENANTS      Triton/TRT-LLM · Dynamo · fine-tuning jobs · notebooks   ← P13 / P14
 PLATFORM     tenancy (MIG/DRA) · scheduling (Kueue/Volcano)           ← P07 / P08
              observability (DCGM+LGTM) · cost (OpenCost)              ← P12
 OPERATORS    GPU Operator  ·  [Network Operator = on-prem only]       ← P08 + Phase 4
 KUBERNETES   pinned to a validated Cloud Native Stack version set     ← Phase 3, step 6
 COMPUTE      GPUs (MIG) · CUDA kernels · NVLink/NVSwitch              ← P16 / P08
 FABRIC       EFA (AWS)  |  InfiniBand/RoCE (on-prem) · GPUDirect/GDS  ← THIS project
 BARE METAL   GPU nodes · NVMe · DPUs (BlueField-3 on B200)            ← Phase 5 BOM
```

Build it as an **ArgoCD ApplicationSet** (from P12) with sync waves — the acceptance-suite Job from Phase 3 is the last wave, and it must go green before any tenant workload is allowed to schedule:

```
factory/
├── Makefile                      # factory-up / factory-down / factory-validate
├── appset-factory.yaml           # ArgoCD ApplicationSet, sync-wave ordered
├── waves/00-validated-stack/     # pinned K8s + driver + operator version matrix
├── waves/10-gpu-operator/        # + nvidia-operator-validator
├── waves/20-fabric/              # aws-efa-k8s-device-plugin, MPI Operator
├── waves/30-scheduling/          # Kueue + TAS topology labels (P07)
├── waves/40-tenancy/             # MIG profiles / DRA (P08)
├── waves/50-observability/       # DCGM exporter + LGTM + OpenCost (P12)
├── waves/60-serving/             # Triton / TRT-LLM (P13), Dynamo (P14)
└── waves/99-acceptance/          # validate.sh Job — gates everything above it
```

Then write `AI-FACTORY-REFERENCE.md`: layered diagram, pinned versions, acceptance-report output, tenancy model, DR posture (P12), cost model, Phase-5 BOM — as if onboarding the next engineer. This is the portfolio's centrepiece: *"here is my cluster, here is the command, here are the numbers it produced."*

## 9. Done criteria & interview ammo

- [ ] Rehearsal on a cheap EFA pair (2× g6.8xlarge) + one real 2-hr **2× p4d** report, every suite section filled in.
- [ ] Intra-node NVLink busbw, inter-node GPUDirect-over-EFA busbw, and the TCP control group **measured**, tabulated, expressed as % of line rate.
- [ ] Same-leaf vs cross-spine busbw delta measured with Kueue TAS on/off (the empirical case for P07).
- [ ] Troubleshooting matrix validated by **injected** faults (kill the plugin, break the SG, force `FI_PROVIDER=tcp`, split the AZs).
- [ ] `docs/validated-stack.md` (version matrix + `nvidia-operator-validator` green) and `docs/gpudirect.md` (RDMA vs GDS) written.
- [ ] Network Operator on **kind**, `NicClusterPolicy` applied and its state machine explained — *including* why nothing schedules without `pci-15b3` NICs, and why it does not belong on EKS.
- [ ] `docs/ai-factory-bom.md` sizes a workload in DGX/SuperPOD units with the correct NIC BOM (ConnectX-7 per GPU; BlueField-3 on B200, not H100) and the 8-rail Quantum-2 fabric explained.
- [ ] `make factory-up` reproduces the whole stack on a fresh cluster; the acceptance Job gates tenant scheduling.

**Resume bullet:** *"Built a GPU-cluster validation & acceptance pipeline on EKS: EFA-enabled placement-grouped nodegroups (aws-efa-k8s-device-plugin + libfabric + aws-ofi-nccl), GPUDirect-RDMA NCCL benchmarking via MPIJobs (all_reduce/all_gather busbw ladders — intra-node NVLink vs inter-node EFA vs TCP control — plus a tuning matrix), DCGM level-3 diagnostics and thermal stress gating, FSx Lustre fio validation, and topology-aware placement verification (Kueue TAS) — packaged as a one-command GitOps AI-factory reference architecture with a fault-injected troubleshooting runbook, a DGX/SuperPOD capacity BOM, and an NVIDIA Network Operator (NicClusterPolicy/DOCA-OFED/SR-IOV) study of the on-prem InfiniBand equivalent."*

## 10. Teardown (do it immediately)

`eksctl delete nodegroup gpu-efa --cluster fabric-lab` **the moment the report is written** — p4d bills ~$22/hr per node, so a forgotten pair is ~$1,050/day. Then `eksctl delete cluster`. Set a billing alarm *before* the window opens, a phone timer for its end, and verify `kubectl get nodes` is empty and no `nodeclaims` remain before you log off. The kind capstone and the docs cost nothing and are the durable output — the p4d window only produces the numbers you paste into them.

## 11. Extensions

- **vCluster per tenant** on the validated pool (the neocloud JD's exact ask): validate once, hand out virtual clusters against the acceptance report.
- **p5/H100 delta study** (32× EFA, EFA v2 with RDMA read *and* write) as a paper exercise against published numbers — then argue what changes in your MPIJob.
- **BlueField-3 / DOCA** chapter: offloading networking/storage/security to the DPU — and why B200's storage fabric differs from H100's.
- **Multi-node NVLink** (NVLink Switch, GB200 NVL72): how the newest factories collapse the intra/inter-node boundary this project measures.
- Confidential computing on H100 (GPU TEE) for a multi-tenant factory handling sensitive data.

## 📣 Build in public

- **LinkedIn:** post the three-bar chart — intra-node NVLink busbw vs inter-node GPUDirect-over-EFA busbw vs the TCP-fallback control group, all measured on the same 2× p4d in the same two hours — captioned *"this is what a misconfigured GPU cluster costs you, in one picture."* Then the line most posts get wrong: *"and no, you don't install NVIDIA's Network Operator to get RDMA on EKS — EFA is the only RDMA fabric on AWS."* That correction will out-perform the chart.
- **X/Twitter thread:** the fault-injection matrix, one tweet per injected fault (`FI_PROVIDER=tcp`, EFA SG no longer self-referencing, nodes split across AZs, EFA device plugin deleted), each with the symptom it produced and the `NCCL_DEBUG=INFO` line that gave it away. Close with the `NicClusterPolicy` you applied on **kind** and a screenshot of the DaemonSets that scheduled *nowhere* because NFD found no `pci-15b3` device — the honest limit of studying the on-prem stack without ConnectX hardware.
- **YouTube:** a 10-minute *"two hours of p4d, start to finish"* with the spend timer on screen: `make factory-up`, the acceptance Job going green, the NCCL ladders running live, `nvidia-smi topo -m` showing the NVLink matrix, the TCP control group collapsing on camera, then `eksctl delete nodegroup` and the billing console. The demo is the discipline, not just the benchmark.
