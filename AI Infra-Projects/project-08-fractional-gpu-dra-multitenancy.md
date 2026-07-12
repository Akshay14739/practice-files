# Project 08 — Slice: A Fractional-GPU Multi-Tenant Platform (MIG + HAMi + DRA + KAI + Kueue)

**Difficulty:** ★★★★☆ | **Time:** 3–4 weekends | **Cost:** ~$15–35 (g4dn/g5/g6 spot for time-slicing, MPS, HAMi and KAI; one 2–3 hr single-A100 rental ≈ $4–8 for MIG — no p4d anywhere in this project)
**GPU-scheduling project 2 of 2.**

*[P07](project-07-topology-aware-gang-scheduler.md) decided **which job** gets a GPU. This one decides **how much of a GPU** each workload gets — the fractional-GPU problem that determines whether a fleet runs at 15% utilization or 70%. You'll operate real MIG on a real A100, deploy MPS and HAMi (memory-isolated fractional GPUs on the cheap cards MIG can't touch), run NVIDIA's open-sourced KAI Scheduler for fraction-aware placement, impose org-level quotas with Kueue, and publish a cost-per-tenant economics report comparing every sharing mode.*

## 1. The production problem

A whole H100 for a notebook or a 7B-model dev endpoint wastes >90 % of a very expensive chip. Every internal GPU cloud (and every "neocloud" — see your uploaded JD: *"GPU Operator setup… validated vCluster environment"*) therefore runs **GPU sharing** with **hard multi-tenant quotas**:

- **MIG** (A100/A30, Hopper H100/H200/H20, Blackwell B200/GB200 and RTX PRO Blackwell server cards — *not* T4/A10G/L4/L40S): hardware partitions — isolated memory + SMs + L2, with fault isolation between instances. Safe for untrusted tenants.
- **Time-slicing** (any GPU, e.g. A10G/L4): kubelet advertises N replicas of one GPU; per NVIDIA's own docs, *"there is no memory or fault-isolation between replicas"* — fine for bursty dev, dangerous for tenants.
- **MPS**: concurrent kernels from multiple processes; per-client GPU address spaces on Volta+ and an opt-in memory cap (`CUDA_MPS_PINNED_DEVICE_MEM_LIMIT`, CUDA 11.5+), but *limited* error containment — one fatal client fault can take down every co-client on the device.
- **HAMi** (CNCF **Incubating** project — promoted July 2, 2026 — v2.9.0 as of July 2026): software-enforced fractional GPUs. Its `libvgpu.so` intercepts CUDA calls to enforce per-pod memory and SM caps on **any** NVIDIA GPU — exactly the T4/A10G/L4 fleet that MIG cannot cover.
- **DRA (Dynamic Resource Allocation)**: devices become first-class API objects (`DeviceClass`, `ResourceClaim`) selected with CEL, replacing the opaque `nvidia.com/gpu: 1` counter. **GA in Kubernetes v1.34** (`resource.k8s.io/v1`, August 2025); NVIDIA ships a DRA driver, and HAMi v2.9.0 added its own (HAMi-DRA).
- **KAI Scheduler**: NVIDIA's open-sourced (Apache-2.0, April 2025) scheduler from the Run:ai acquisition — hierarchical queues, fair-share, gang scheduling, and *fractional* GPU requests (`0.5` GPU). CNCF Sandbox since December 2025; now at `github.com/kai-scheduler/KAI-Scheduler`, v0.16.3 as of July 2026. Crucially, its fractions are **scheduling-level only** — KAI's own docs recommend pairing it with HAMi for memory isolation.

The decision matrix you're building evidence for:

| Mode | Isolation | Memory protection | Granularity | Hardware | Best for |
|---|---|---|---|---|---|
| Whole GPU | Full | Full | 1 | any | Big training/serving |
| **Time-slicing** | None (round-robin ctx switch) — *"no memory or fault-isolation between replicas"* (NVIDIA) | ❌ none — OOM kills neighbor | N replicas | any | Dev/notebooks, bursty tiny jobs |
| **MPS** | Compute partitioning; limited error containment (fatal fault hits co-clients) | Per-client address space (Volta+); opt-in cap via `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT` (CUDA 11.5+) | % of SMs | Volta+ | Many small inference procs, low latency |
| **HAMi vGPU** | Software (CUDA-call interception) — no hardware fault isolation | **Enforced cap** (`nvidia.com/gpumem` MiB) — offender gets CUDA OOM alone | Arbitrary MiB / % SM | any NVIDIA (T4/A10G/L4/L40S included) | Fractional prod on non-MIG GPUs |
| **MIG** | **Hardware** (SM+mem+L2+DMA sliced, fault-isolated) | **Full** | Fixed profiles (7 slices max) | A100/A30, Hopper (H100/H200/H20), Blackwell (B200/GB200, RTX PRO) | Multi-tenant prod, guaranteed QoS |

You'll run every mode in that table plus both schedulers, then impose org-level quota/borrowing with **Kueue**, and close the loop with per-team **chargeback** — the exact shape of an internal ML platform. Almost nobody interviews with per-mode latency/throughput/isolation data; you will.

## 2. Architecture

```
 Team queues (Kueue ClusterQueues in one cohort, borrowing enabled)
        │ admission (quota, priority, preemption)
        ▼
 KAI / kube-scheduler ──▶ Node pools (EKS, spot):
   ├── pool-shared  : g5 (A10G)  — time-slicing ×4 (+ optional MPS)
   ├── pool-hami    : g4dn (T4)  — HAMi fractions, memory-enforced
   └── pool-whole   : g6 (L4)    — exclusive GPUs, DRA-managed
 Side-lab (2–3 hr, off-EKS): 1× A100 rental (GCP a2 spot / Lambda / RunPod)
   └── single-node kubeadm + GPU Operator — MIG mixed profiles
 DCGM-exporter ──▶ Prometheus ──▶ per-namespace GPU-hour chargeback
```

Cost-honest lab strategy: **T4/A10G/L4 spot covers four of five sharing modes** (time-slicing, MPS, HAMi, KAI fractions). The single rented A100 covers the fifth — MIG, the only mode that *requires* Ampere-GA100-or-newer silicon. **p4d is reserved strictly for [P15](project-15-nvidia-networking-nccl-cluster-validation.md)**, where the 8-GPU NVLink intra-node numbers genuinely require it.

## 3. Phase 1 — GPU Operator: time-slicing + MPS (the software-sharing modes)

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm upgrade -i gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
  --set dcgmExporter.enabled=true
```

**Time-slicing** (A10G pool) — ConfigMap + ClusterPolicy patch:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: time-slicing-config, namespace: gpu-operator}
data:
  a10g-shared: |
    version: v1
    flags: {migStrategy: none}
    sharing:
      timeSlicing:
        renameByDefault: true      # exposes nvidia.com/gpu.shared
        resources:
        - name: nvidia.com/gpu
          replicas: 4
```
```bash
kubectl patch clusterpolicies.nvidia.com cluster-policy --type merge -p \
  '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"a10g-shared"}}}}'
# opt a node in:
kubectl label node <a10g-node> nvidia.com/device-plugin.config=a10g-shared
kubectl describe node <a10g-node> | grep nvidia.com/gpu.shared   # expect: 4
```

**MPS** (T4 or A10G pool, same device-plugin config mechanism):

```yaml
# mps-config ConfigMap (device plugin config)
version: v1
sharing:
  mps:
    resources:
      - name: nvidia.com/gpu
        replicas: 4              # 4 clients share SMs CONCURRENTLY
```
```bash
kubectl label node <t4-node> nvidia.com/device-plugin.config=mps --overwrite
```

Benchmark the difference that matters: 4 concurrent small-batch inference pods under **time-slicing** (serialized context switches) vs **MPS** (true concurrency, per-client memory caps via `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT`). Expect MPS to win aggregate throughput 1.5–3× at small batch — publish your measured number, and note MPS's operational caveats (shared fault domain: an MPS daemon crash takes all clients; weaker isolation than MIG). Then contrast fault-isolation behavior vs. time-slicing by crashing one client.

## 4. Phase 2 — HAMi: fractional GPUs with *enforced* memory limits on any GPU

The gap time-slicing leaves (no memory protection) on non-MIG GPUs is HAMi's whole reason to exist. HAMi-core's `libvgpu.so` sits between the CUDA runtime (`libcudart`) and driver (`libcuda`), intercepting allocation calls: the moment a process would exceed its `nvidia.com/gpumem` cap it gets a **CUDA OOM error** — unlike native CUDA, which only OOMs when the physical GPU is exhausted. SM caps (`nvidia.com/gpucores`) are honored by time-sharing kernel launches. Because enforcement is software, it works on **any NVIDIA GPU** — T4, A10G, L4, L40S (Crusoe runs HAMi on L40S fleets).

```bash
# HAMi is CNCF Incubating (promoted 2026-07-02), v2.9.0 as of July 2026 — pin your release
helm repo add hami-charts https://project-hami.github.io/HAMi/
helm repo update
helm install hami hami-charts/hami -n kube-system
```

```yaml
# pod requests a FRACTION with a hard memory wall
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 6000      # MiB — ENFORCED (CUDA OOM in-pod, not on neighbor)
    nvidia.com/gpucores: 40      # % of SM time
```

(`nvidia.com/gpumem-percentage` works too; memory overcommit is available via the experimental `deviceMemoryScaling` config, default 1.0. Prereqs as of v2.9.0: NVIDIA driver ≥ 440, container-toolkit > 2.0, Kubernetes ≥ 1.23, glibc ≥ 2.17 and < 2.30.)

**The killer demo vs time-slicing:** two pods on one T4, pod A capped at 6000 MiB running vLLM, pod B running a memory-bomb (`torch.ones` loop). Under plain time-slicing B OOM-kills the *GPU* for both; under HAMi, B hits its own wall and dies alone with a CUDA OOM while A's p95 holds. Record both runs — third-party isolation tests (RiseUnion) confirm exactly this behavior.

**Hedge honestly in your write-up:** HAMi's enforcement is userspace, LD_PRELOAD-style interception — **no hardware fault isolation** (one Xid/ECC error or driver reset hits every pod on the GPU), compute caps are time-sharing-based and statistical, and GitHub issues document accounting edge cases (e.g. #1181 corrupted `nvidia-smi` readings; #1328 CUDA 13.0 breaking interception until HAMi-core caught up). Pin versions; retest after every CUDA/driver upgrade. MIG remains the answer for genuinely untrusted tenants — which is why you run both.

## 5. Phase 3 — MIG for real, on a rented single A100 (the centerpiece)

MIG needs A100/A30-, Hopper- or Blackwell-class silicon — none of your cheap EKS cards (T4/A10G/L4) qualify. The trick: you do **not** need a p4d. A single-A100 box gives the identical mig-manager workflow — same `mig.config` label, same single/mixed strategies, same DCGM per-slice metrics — because MIG behavior is per-GPU, and these boxes carry the same A100-SXM4-40GB silicon as p4d.

**Where to rent (prices as of July 2026):**

- **GCP `a2-highgpu-1g`** (1× A100-40GB, GPU included): ~$3.67/hr on-demand, **~$1.93/hr spot** (us-central1/us-east1/us-west1). ⚠️ Third-party trackers often show $0.39–0.83/hr for this machine type — those figures *exclude the bundled GPU*; always confirm the A100 is included.
- **Lambda** 1× A100 40GB (SXM or PCIe): **$1.99/hr** on-demand (the widely-cited $1.29 figure is obsolete).
- **RunPod** A100 80GB: $1.39–1.49/hr Secure Cloud, Community Cloud from ~$0.89/hr (interruptible). RunPod lists no 40GB card — note the 80GB profile names differ (`1g.10gb`…`7g.40gb` becomes `1g.10gb`…`7g.80gb`).
- **What you're not paying for:** p4d.24xlarge (8× A100) is ~$21.96/hr on-demand / ~$13.93/hr spot in us-east-1 after AWS's June 2025 price cut. The single-A100 spot box is roughly **1/11th of p4d on-demand per hour — an order of magnitude cheaper — for an identical MIG lab**. A full scripted MIG session costs $4–8. p4d stays reserved for [P15](project-15-nvidia-networking-nccl-cluster-validation.md).

**Two paths:**

- **Path A (recommended): single-node kubeadm on the rented A100 VM.** GCP/Lambda/RunPod VM → `kubeadm init` → GPU Operator with MIG manager. You control everything and see all the internals.
- **Path B: GKE** `a2-highgpu-1g` node pool with `gpu-partition-size=1g.5gb` — managed MIG, good to know, less visible internals.

On the A100 node:

```bash
helm upgrade -i gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
  --set mig.strategy=mixed \
  --set migManager.enabled=true \
  --set dcgmExporter.enabled=true
```

**Step 1 — enable MIG mode & pick a geometry.** A100-40GB profiles: `1g.5gb`×7, `2g.10gb`×3, `3g.20gb`×2, `7g.40gb`×1, plus mixed layouts like `1×3g.20gb + 2×2g.10gb` (slices come from a fixed set of valid memory-slice × compute-slice combinations). The GPU Operator's **mig-manager** drives it declaratively via node label — it drains GPU pods, reconfigures, and uncordons:

```bash
# built-in profiles from the default mig-parted config
kubectl label node a100-node nvidia.com/mig.config=all-1g.5gb --overwrite
kubectl -n gpu-operator logs -l app=nvidia-mig-manager -f   # watch it reconfigure
nvidia-smi -L
#   GPU 0: NVIDIA A100 ... (7 MIG devices: MIG 1g.5gb ...)
kubectl describe node a100-node | grep nvidia.com/mig
#   nvidia.com/mig-1g.5gb: 7        ← seven schedulable resources

# then the balanced preset — on A100-40GB: 2×1g.5gb + 1×2g.10gb + 1×3g.20gb per GPU
kubectl label node a100-node nvidia.com/mig.config=all-balanced --overwrite
kubectl get node a100-node -o json | jq '.status.allocatable' | grep 'nvidia.com/mig'
#   e.g. nvidia.com/mig-1g.5gb: "2"
```

Custom mixed geometry (`custom-mig-config` ConfigMap, mig-parted format) — proof you can go beyond the presets:

```yaml
config.yaml: |
  version: v1
  mig-configs:
    inference-mixed:
      - devices: [0]
        mig-enabled: true
        mig-devices:
          "3g.20gb": 1        # one "large" tenant slice
          "2g.10gb": 2        # two medium slices
```

**Step 2 — schedule onto slices.** Three vLLM instances, three isolation domains, one physical GPU:

```yaml
resources:
  limits:
    nvidia.com/mig-2g.10gb: 1     # instead of nvidia.com/gpu
```

Run `Qwen2.5-1.5B` on a `2g.10gb` and `Qwen2.5-3B` on the `3g.20gb`. **The proof-of-isolation demo:** run `gpu-burn` inside one slice while latency-testing vLLM in another → p95 barely moves (contrast with the same test under time-slicing on the T4, where it collapses). Then OOM one slice deliberately → neighbors unaffected. Screenshots of both = the whole MIG value proposition, demonstrated.

**Step 3 — per-slice telemetry.** DCGM-exporter emits `GPU_I_ID`/`GPU_I_PROFILE` labels; build the Grafana panel *utilization per MIG instance* — this is exactly how multi-tenant fleets bill. Gotcha: `DCGM_FI_DEV_GPU_UTIL` is **not supported on MIG devices** — use `DCGM_FI_PROF_GR_ENGINE_ACTIVE` (and the other `DCGM_FI_PROF_*` fields, some disabled by default) for per-slice utilization.

**What one GPU can't rehearse** (say so — it shows judgment): per-GPU heterogeneous mig-parted configs (device filters giving different GPUs different profiles) and mixed MIG-on/MIG-off nodes need multiple GPUs; and A100-80GB targets (p4de) use different profile names/sizes. Everything else — the label-driven reconfigure loop, mixed geometries, per-slice billing — is identical.

## 6. Phase 4 — DRA: the new way to ask for devices

Requirements: Kubernetes ≥1.32 (beta, feature gates + `resource.k8s.io/v1beta1`) or ≥1.34 (**GA**, `resource.k8s.io/v1`, stable since August 2025). Start on **kind** with the NVIDIA `k8s-dra-driver-gpu`, then on EKS once your platform version supports it.

```yaml
# A class of devices, selected by CEL over vendor-published attributes
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata: {name: single-a10g}
spec:
  selectors:
  - cel:
      expression: >-
        device.driver == "gpu.nvidia.com" &&
        device.attributes["gpu.nvidia.com"].productName.matches(".*A10G.*")
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata: {name: one-gpu}
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly: {deviceClassName: single-a10g, count: 1}
---
apiVersion: v1
kind: Pod
metadata: {name: dra-smoke}
spec:
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: one-gpu
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources: {claims: [{name: gpu}]}
```

Why DRA matters (say this in interviews): claims are **structured and shareable** — one claim can be mounted by multiple pods; CEL selects on memory size, MIG profile, NVLink domain; and it's the foundation for scheduling *fabric-attached* accelerators. Demonstrate a **shared claim**: two pods referencing the same `ResourceClaim` co-located on one GPU. The ecosystem is converging here too: HAMi ships a DRA driver (HAMi-DRA, since v2.9.0) and KAI lists DRA support — MIG slices claimable on demand is where this is heading.

## 7. Phase 5 — KAI Scheduler: queues, fair-share, fractions

```bash
# Repo moved: github.com/NVIDIA/KAI-Scheduler → github.com/kai-scheduler/KAI-Scheduler
# (old URL redirects). Apache-2.0, CNCF Sandbox since 2025-12-21, v0.16.3 as of July 2026.
# Releases are frequent — pin one and check the README for the current chart location.
helm upgrade -i kai-scheduler oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler \
  -n kai-scheduler --create-namespace
```

Queues (hierarchical: department → team) — check your chart version's CRD group:

```yaml
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: dept-ml}
spec:
  resources:
    gpu: {quota: 8, limit: 12, overQuotaWeight: 1}
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: team-nlp}
spec:
  parentQueue: dept-ml
  resources:
    gpu: {quota: 4, limit: 8, overQuotaWeight: 2}
```

A **half-GPU** workload:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dev-notebook
  labels: {kai.scheduler/queue: team-nlp}
  annotations: {gpu-fraction: "0.5"}
spec:
  schedulerName: kai-scheduler
  containers:
  - name: nb
    image: jupyter/pytorch-notebook
```

**The caveat that wins interviews:** KAI's fractions are scheduling-level arithmetic only. Its own gpu-sharing docs state it *"does not enforce memory allocation limits or perform memory isolation between processes"* — and point users at HAMi for enforcement. Position them as complementary: **KAI for queues/gang/placement, HAMi (Phase 2) for in-GPU enforcement** — the emerging open Run:ai stack (commercial Run:ai layers enforcement/UI on this same scheduling core).

Experiments to run and record: (1) two 0.5-fraction pods pack onto one A10G — verify with `nvidia-smi`; (2) team-nlp bursts to 8 GPUs when idle, gets **reclaimed** back to quota=4 when dept siblings submit (fair-share + preemption); (3) a 4-pod gang via KAI's built-in podgrouper is all-or-nothing (compare with your [P07](project-07-topology-aware-gang-scheduler.md) implementation); (4) rerun the HAMi memory-bomb *under KAI placement* to show scheduler and enforcer composing.

## 8. Phase 6 — Kueue quotas, cohorts, borrowing, preemption

Where KAI is placement-time, Kueue is **admission-time** (works with any scheduler — pair it with your [P07](project-07-topology-aware-gang-scheduler.md) scheduler):

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata: {name: a10g-shared}
spec:
  nodeLabels: {nvidia.com/device-plugin.config: a10g-shared}
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata: {name: cq-research}
spec:
  cohort: gpu-fleet
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  resourceGroups:
  - coveredResources: ["nvidia.com/gpu.shared"]
    flavors:
    - name: a10g-shared
      resources:
      - name: nvidia.com/gpu.shared
        nominalQuota: 8
        borrowingLimit: 8        # may borrow idle quota from cohort peers
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata: {name: research, namespace: team-research}
spec: {clusterQueue: cq-research}
```

Drill: fill `cq-research` beyond nominal via borrowing, then submit to a sibling queue → watch Kueue **preempt the borrowed workloads** (`kubectl get workloads -A -o wide`). This admission-vs-placement distinction (Kueue vs KAI/Volcano) is a classic interview question — you'll have run both.

## 9. Phase 7 — chargeback + the economics report (FinOps)

Prometheus recording rules (DCGM + KSM):

```yaml
groups:
- name: gpu-chargeback
  rules:
  - record: namespace:gpu_requested:sum
    expr: sum by (namespace) (kube_pod_container_resource_requests{resource=~"nvidia_com_gpu.*"} 
          * on(pod, namespace) group_left kube_pod_status_phase{phase="Running"})
  - record: namespace:gpu_util:avg
    expr: avg by (exported_namespace) (DCGM_FI_DEV_GPU_UTIL)
  # MIG slices never emit DCGM_FI_DEV_GPU_UTIL — bill them on the profiling metric:
  - record: namespace:mig_slice_util:avg
    expr: avg by (exported_namespace, GPU_I_PROFILE) (DCGM_FI_PROF_GR_ENGINE_ACTIVE)
```

Monthly cost = `namespace:gpu_requested:sum` integrated over time × $/GPU-hr per flavor (A100 slice priced at profile fraction). Grafana table: *requested GPU-hours vs. actually-utilized GPU-hours* per team — the gap **is** the business case for fractional GPUs. This satisfies the "cost optimization & tagging governance" line in your AWS JD, and feeds directly into the fleet-level FinOps work in [P12](project-12-ai-fleet-sre-finops-aiops.md).

Then the artifact every platform lead leans in for — `docs/gpu-sharing-economics.md`. Method: same vLLM workload profile (e.g., steady 5 rps of 100-token completions per tenant), measure max tenants per GPU per mode at p95 < SLO, then:

| Mode | Tenants/GPU @ SLO | $/GPU-hr (spot, July 2026) | **$/tenant-hr** | Isolation grade |
|---|---:|---:|---:|---|
| Whole T4 | 1 | ~0.16 (g4dn.xlarge, varies) | 0.160 | A |
| T4 time-slice ×4 | *measured* | ~0.16 | … | D |
| T4 MPS ×4 | *measured* | ~0.16 | … | C |
| T4 HAMi 0.25 | *measured* | ~0.16 | … | B− |
| A100 MIG 1g.5gb ×7 | *measured* | ~1.93 (a2-highgpu-1g spot) | … | **A** |
| A100 MIG 2g.10gb ×3 | *measured* | ~1.93 | … | **A** |

Add the fleet-level punchline: at your measured numbers, what does serving 20 small internal models cost on dedicated GPUs vs the best sharing mix? (Typically a 3–5× difference — *your* measured version of that claim is the LinkedIn post.)

## 10. Done criteria & interview ammo

- [ ] One cluster simultaneously serving: ×4 time-sliced A10Gs, an MPS pool, HAMi-fractioned T4s with enforced memory caps, DRA-claimed GPUs, and KAI 0.5-fractions — plus MIG slices on the A100 side-box — with a written **isolation comparison** (memory protection? fault isolation? perf interference measured with concurrent `gpu-burn` + inference latency).
- [ ] MIG: geometry reconfigured declaratively via node label; 3 workloads on 3 slices; isolation demo (gpu-burn + OOM) recorded; per-MIG-slice Grafana dashboard screenshot.
- [ ] MPS vs time-slicing throughput numbers published.
- [ ] HAMi memory-wall demo recorded (offender gets CUDA OOM alone; neighbor's p95 holds) — with the honest caveats written down.
- [ ] Quota + borrowing + preemption demonstrated in both Kueue and KAI.
- [ ] Chargeback dashboard with a real utilization-gap finding; economics table filled with **your** measurements.

**Resume bullet:** *"Designed a multi-tenant fractional-GPU platform on EKS: MIG (mixed profiles via GPU Operator/mig-manager on A100), time-slicing and MPS pools, HAMi fractional vGPU with CUDA-intercept-enforced memory caps on non-MIG GPUs, Kubernetes DRA (DeviceClass/ResourceClaim with CEL selection), NVIDIA KAI fractional scheduling, and Kueue cohort quotas with borrowing/preemption; published a cost-per-tenant analysis across all sharing modes that exposed a 60 % request-vs-utilization gap."*

Whiteboard-ready: MIG slice anatomy (SM/memory/L2 partitioning, valid geometry combinations); why time-slicing can't protect memory and what HAMi's CUDA interception does about it (and where userspace interception ends — Xid faults, statistical compute caps); MPS's failure domain; KAI-schedules-HAMi-enforces vs commercial Run:ai; when a fleet should be MIG-static vs fraction-dynamic; how DRA will eventually make MIG slices claimable on demand.

## 11. Teardown

- A100 sessions are surgical: provision → run scripted benchmarks (`make bench-mig`) → destroy within 2–3 hours. `nvidia.com/mig.config=all-disabled` restores whole-GPU mode before comparisons.
- EKS: `helm uninstall` all (gpu-operator, hami, kai-scheduler, kueue), remove `nvidia.com/device-plugin.config` labels, scale the spot GPU nodegroups to zero.
- There is no p4d in this project to forget about — that bill belongs to [P15](project-15-nvidia-networking-nccl-cluster-validation.md).

## 12. Extensions

- **vCluster per tenant** (straight from the neocloud JD): give each team a virtual cluster whose nodes are backed by your shared GPU pools.
- **Dynamic MIG reconfiguration pipeline**: a CronJob that flips geometry between "inference day-mix" and "training night-mix" based on queue depth — with the drain/cordon choreography documented.
- Extend your **P6 operator** with `gpu.sharing: {mig-2g.10gb | hami-fraction | whole}` so tenants choose an isolation class per ModelDeployment.
- DRA **ComputeDomains** for multi-node NVLink (GB200-class) — read the NVIDIA DRA driver docs and write a design note even without the hardware.
- Admission policy (Kyverno/ValidatingAdmissionPolicy): reject pods requesting whole GPUs in dev namespaces.
- Add **vGPU (NVIDIA AI Enterprise)** as a paper-comparison column — licensing vs HAMi's open approach.
- Test **MIG + MPS combined** (MPS inside a `3g.20gb` slice) and report whether the extra layer pays.

## 📣 Build in public

- **LinkedIn post:** the economics table — measured $/tenant-hr for six sharing configurations at equal p95 SLO, with the fleet punchline (what 20 small internal models cost dedicated vs your best sharing mix) and the hook that the entire hardware-MIG lab cost under $8 on a ~$1.93/hr spot A100 instead of a ~$22/hr p4d.
- **X/Twitter thread:** the memory-bomb, twice — same two pods, run 1 under time-slicing (bomb OOM-kills the GPU for both tenants), run 2 under HAMi (bomb dies alone with CUDA OOM, neighbor's p95 doesn't move). Side-by-side `nvidia-smi` + latency screenshots, ending with the honest caveat about userspace interception vs hardware MIG.
- **YouTube demo:** live declarative MIG reconfiguration — label the node `mig.config=all-balanced`, watch mig-manager drain/reslice/uncordon, `nvidia-smi -L` flip from 1 GPU to a mixed-geometry slice set, then the per-slice Grafana panel — closing on the `DCGM_FI_DEV_GPU_UTIL`-vanishes-under-MIG gotcha and the `DCGM_FI_PROF_GR_ENGINE_ACTIVE` fix.
