# Project 8 — GPU Sharing & Partitioning at Fleet Scale: MIG, MPS, HAMi & KAI
### 🎯 GPU SCHEDULING PROJECT 2 of 2

> Project 7 decided **which job** gets a GPU. This one decides **how much of a GPU** each workload gets — the fractional-GPU problem that determines whether a fleet runs at 15% utilization or 70%. You'll operate **real MIG on a real A100**, deploy **MPS** and **HAMi** (memory-isolated fractional GPUs), run NVIDIA's open-sourced **KAI Scheduler** for fraction-aware placement, and publish a **cost-per-inference economics report** comparing every sharing mode.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 4–5 weekends |
| **Prereq** | Projects 1–2 (GPU Operator, vLLM, DCGM dashboards) |
| **Cloud cost** | The one project needing an **A100**: GCP `a2-highgpu-1g` (1× A100-40GB) spot ≈ **$1.1–1.5/hr**, or a Lambda/RunPod-style A100 VM ≈ $1.2–1.8/hr with single-node kubeadm. Budget $20–35 total across sessions. Everything else on T4/kind. |
| **Skills proven** | MIG geometry planning & mig-parted, GPU Operator MIG strategies, MPS operations, HAMi fractional GPUs with memory isolation, KAI Scheduler queues/fractions, DCGM per-partition telemetry, utilization economics |
| **JD keywords hit** | "MIG configuration, GPU sharing and isolation, vGPU" (NVIDIA-cert syllabus) · "multi-tenant resource allocation" · "GPU Fluency: NVIDIA GPU Operators, CUDA tooling, systems-level configuration" · FinOps in every platform JD |

---

## 1. The decision matrix you're building evidence for

| Mode | Isolation | Memory protection | Granularity | Hardware | Best for |
|---|---|---|---|---|---|
| Whole GPU | Full | Full | 1 | any | Big training/serving |
| **Time-slicing** | None (round-robin ctx switch) | ❌ none — OOM kills neighbor | N replicas | any | Dev/notebooks, bursty tiny jobs |
| **MPS** | Compute concurrent | Limited (per-client % caps) | % of SM/mem | Volta+ | Many small inference procs, low latency |
| **MIG** | **Hardware** (SM+mem+L2+DMA sliced) | **Full** | Fixed profiles (7 slices max) | A100/H100/A30/H200/B* | Multi-tenant prod, guaranteed QoS |
| **HAMi vGPU** | Software (CUDA intercept) | **Enforced limit** (e.g. 4000MiB) | Arbitrary % / MiB | any NVIDIA | Fractional prod on non-MIG GPUs (T4/A10G!) |

You already explain this table from the field guide. After this project you'll have **run all five**, with per-mode latency/throughput/isolation data. Almost nobody interviews with that.

## 2. Lab strategy (cost-honest)

- **T4/`g4dn` (cheap):** time-slicing (done in P1), MPS, HAMi, KAI — 4 of 5 modes.
- **A100 (one rented, few hours):** MIG — the mode that *requires* Ampere+. Two paths:
  - **Path A (recommended): single-node kubeadm on a rented A100 VM.** Lambda/RunPod/GCP VM → `kubeadm init` → GPU Operator with MIG manager. You control everything; total cost of a full MIG session ≈ $4–8.
  - **Path B: GKE** `a2-highgpu-1g` node pool with `gpu-partition-size=1g.5gb` — managed MIG, good to know, less visible internals.

## 3. Phase 1 — MIG for real (the centerpiece)

On the A100 node with GPU Operator installed (`mig.strategy=mixed`):

**Step 1 — enable MIG mode & pick a geometry.** A100-40GB profiles: `1g.5gb`×7, `2g.10gb`×3, `3g.20gb`×2, `7g.40gb`×1, and mixed layouts like `1×3g.20gb + 2×2g.10gb` (know that slices come from a fixed set of valid combinations — memory slices × compute slices).

The GPU Operator's **mig-manager** drives it declaratively via node label:

```bash
# built-in profiles from the default mig-parted config
kubectl label node a100-node nvidia.com/mig.config=all-1g.5gb --overwrite
kubectl -n gpu-operator logs -l app=nvidia-mig-manager -f   # watch it reconfigure
nvidia-smi -L
#   GPU 0: NVIDIA A100 ... (7 MIG devices: MIG 1g.5gb ...)
kubectl describe node a100-node | grep nvidia.com/mig
#   nvidia.com/mig-1g.5gb: 7        ← seven schedulable resources
```

Custom mixed geometry (`custom-mig-config` ConfigMap, mig-parted format):

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

**Step 3 — per-slice telemetry.** DCGM exporter emits `GPU_I_ID`/`GPU_I_PROFILE` labels; build the Grafana panel *utilization per MIG instance* — this is exactly how multi-tenant fleets bill.

## 4. Phase 2 — MPS on the T4 (the middle option)

GPU Operator makes MPS a device-plugin config, same mechanism as time-slicing:

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

Benchmark the difference that matters: 4 concurrent small-batch inference pods under **time-slicing** (serialized context switches) vs **MPS** (true concurrency, per-client memory caps via `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT`). Expect MPS to win aggregate throughput 1.5–3× at small batch — publish your measured number, and note MPS's operational caveats (shared fault domain: an MPS daemon crash takes all clients; weaker isolation than MIG).

## 5. Phase 3 — HAMi: fractional GPUs with *enforced* memory limits on any GPU

The gap time-slicing leaves (no memory protection) on non-MIG GPUs is HAMi's (CNCF sandbox) whole reason to exist — it intercepts CUDA calls to enforce per-pod memory/compute caps:

```bash
helm repo add hami https://project-hami.github.io/HAMi/
helm install hami hami/hami -n kube-system
```

```yaml
# pod requests a FRACTION with a hard memory wall
resources:
  limits:
    nvidia.com/gpu: 1
    nvidia.com/gpumem: 6000      # MiB — ENFORCED (OOM in-pod, not on neighbor)
    nvidia.com/gpucores: 40      # % of SM time
```

**The killer demo vs time-slicing:** two pods on one T4, pod A capped at 6000MiB running vLLM, pod B runs a memory-bomb (`torch.ones` loop). Under plain time-slicing B OOM-kills the *GPU* for both; under HAMi, B hits its own wall and dies alone while A's p95 holds. Record both runs.

## 6. Phase 4 — KAI Scheduler: fraction-aware placement (NVIDIA's open-sourced Run:ai core)

Sharing modes carve GPUs; **KAI** (Apache-2.0, from Run:ai) *schedules* onto the carvings with queues, fairness, and native fractional requests:

```bash
helm install kai-scheduler oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler \
  -n kai-scheduler --create-namespace
```

```yaml
# hierarchical queues (org → team), quota + over-quota weights
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: { name: research }
spec:
  resources:
    gpu: { quota: -1, limit: -1, overQuotaWeight: 1 }
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: { name: team-inference }
spec:
  parentQueue: research
  resources:
    gpu: { quota: 2, limit: 4, overQuotaWeight: 2 }
```

```yaml
# pod: HALF a GPU, scheduled by KAI
metadata:
  labels: { kai.scheduler/queue: team-inference }
  annotations: { gpu-fraction: "0.5" }
spec:
  schedulerName: kai-scheduler
```

Scenarios to run: two 0.5-GPU pods **bin-packed onto one GPU** (check with `nvidia-smi`); queue over-quota borrowing then reclaim (compare semantics with Kueue from P7 — that comparison paragraph is blog gold); gang-schedule a fractional multi-pod job. Close the loop with a note on **NVIDIA GPU Operator + KAI as the emerging open Run:ai stack**.

## 7. Phase 5 — The economics report (the FinOps artifact)

`docs/gpu-sharing-economics.md` — one table that makes every platform lead lean in. Method: same vLLM workload profile (e.g., steady 5 rps of 100-token completions per tenant), measure max tenants per GPU per mode at p95 < SLO, then:

| Mode | Tenants/GPU @ SLO | $/GPU-hr (spot) | **$/tenant-hr** | Isolation grade |
|---|---:|---:|---:|---|
| Whole T4 | 1 | 0.16 | 0.160 | A |
| T4 time-slice ×4 | *measured* | 0.16 | … | D |
| T4 MPS ×4 | *measured* | 0.16 | … | C |
| T4 HAMi 0.25 | *measured* | 0.16 | … | B− |
| A100 MIG 1g.5gb ×7 | *measured* | 1.30 | … | **A** |
| A100 MIG 2g.10gb ×3 | *measured* | 1.30 | … | **A** |

Add the fleet-level punchline: at your measured numbers, what does serving 20 small internal models cost on dedicated GPUs vs the best sharing mix? (Typically a 3–5× difference — *your* measured version of that claim is the LinkedIn post.)

## 8. Validation checklist

- [ ] MIG: geometry reconfigured declaratively via node label; 3 workloads on 3 slices; isolation demo (gpu-burn + OOM) recorded
- [ ] MPS vs time-slicing throughput numbers published
- [ ] HAMi memory-wall demo recorded (neighbor survives the memory bomb)
- [ ] KAI: two 0.5-GPU pods packed on one GPU; queue reclaim demonstrated
- [ ] Economics table filled with **your** measurements
- [ ] Per-MIG-slice Grafana dashboard screenshot

## 9. Teardown

A100 sessions are surgical: provision → run scripted benchmarks (`make bench-mig`) → destroy within the hour. `nvidia.com/mig.config=all-disabled` label restores whole-GPU mode before comparisons. kind/T4 as usual.

## 10. Interview ammunition

- *"Operated every GPU-sharing mode in production form — time-slicing, MPS, HAMi fractional vGPU with enforced memory isolation, and hardware MIG on A100 (declarative geometry via GPU Operator mig-manager) — scheduled by NVIDIA's KAI with hierarchical queues and fractional bin-packing; published a cost-per-tenant analysis showing a Nx serving-cost reduction at equal p95 SLO."*
- Whiteboard-ready: MIG slice anatomy (SM/memory/L2 partitioning, valid geometry combinations); why time-slicing can't protect memory and what HAMi's CUDA interception does about it; MPS failure domain; when a fleet should be MIG-static vs fraction-dynamic; how DRA (P7) will eventually make MIG slices *claimable on demand*.

## 11. Stretch goals

1. **Dynamic MIG reconfiguration pipeline**: a CronJob that flips geometry between "inference day-mix" and "training night-mix" based on queue depth — with the drain/cordon choreography documented.
2. Extend your **P6 operator** with `gpu.sharing: {mig-2g.10gb | hami-fraction | whole}` so tenants choose isolation class per ModelDeployment.
3. Add **vGPU (NVIDIA AI Enterprise)** as a paper-comparison column — licensing vs HAMi's open approach.
4. Test **MIG + MPS combined** (MPS inside a 3g.20gb slice) and report whether the extra layer pays.
