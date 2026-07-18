# Tier-1 AI Projects, Climbed the Ladder 🪜
### The four portfolio projects — GPU platform, CUDA fluency, the Go scheduler, LLM serving — each climbed **Pain → One Idea → Machinery → Vocabulary → Trace → Contrast → Prediction → Capstone** *before* you run a single command from the project files.

> **How to use this file:** each climb below pairs with one project file in [AI Infra-Projects/](AI Infra-Projects/). **Climb the ladder first (60–90 min), then execute the project's phases.** The ladder gives you the mental model; the project gives you the evidence. Rung 7's predictions are deliberately mapped to each project's own cheap validation steps — so your first hours of project work double as your prediction test, and every result either confirms your model or repairs it.
>
> **Build order (your Tier-1 plan):**
> ```
> Climb 1 ─ project-1  (GPU K8s platform)   ─┐ do these two in PARALLEL
> Climb 2 ─ project-16 (CUDA performance)   ─┘ (16 needs only a GPU session, not the cluster)
> Climb 3 ─ project-07 (Go gang scheduler)  — kind/kwok, ~$0, doesn't need #1 finished
> Climb 4 ─ project-2  (vLLM inference)     — needs #1's cluster
> ```
> **Why interviewers will feel the difference:** your 19-transcript diagnosis was *"strong conceptually, light on hands-on."* These projects fix the hands-on half. The ladders fix the other failure mode — prompted recall — by making you **predict before you run**. A candidate who says *"I expected the vecadd kernel to hit 0.04% of peak FLOPS because its arithmetic intensity is 0.083 against a ridge point of 217 — and it did"* is un-stumpable.
>
> **The through-line across all four:** everything in AI infrastructure is downstream of one economic fact — **the GPU is scarce and 20–40× the price of everything else.** Project 1 makes K8s *see and share* it, project 16 teaches you to *read* it, project 07 decides *who gets it and where*, and project 2 *serves tokens off it* without wasting a cycle. Four projects, one resource.

---
---

# CLIMB 1 — GPU-Ready Kubernetes Platform ⚙️
### Pairs with: [project-1-gpu-kubernetes-platform.md](AI Infra-Projects/project-1-gpu-kubernetes-platform.md)

## RUNG 0 — The Setup
**What am I learning?** How a Kubernetes pod *actually* gets a GPU — the full chain from EC2 metal to `nvidia.com/gpu: 1` in a pod spec — and how to share, monitor, and autoscale that GPU economically.

**Why did it land on my desk?** It's the substrate every other Tier-1 project stands on, and every JD I'm targeting assumes I can whiteboard this chain. It's also my fastest win: it is literally my Harman EKS + Karpenter stack with one new layer (the GPU Operator) on top.

**What do I already know?** EKS, Terraform modules, Karpenter NodePools/EC2NodeClasses, taints, kube-prometheus-stack — cold. What I *don't* yet have is the GPU layer: how the driver/toolkit/device-plugin stack gets onto a node, how the scheduler learns a GPU exists, and how one physical card becomes four schedulable ones.

---

## RUNG 1 — The Pain 🔥
### *Why does the GPU Operator exist at all?*

A vanilla Kubernetes node **has no idea what a GPU is.** Attach a $10k card to a node and: the kernel has no NVIDIA driver, containers can't reach the device (`/dev/nvidia*` isn't mounted, CUDA libs aren't injected), the kubelet advertises `cpu` and `memory` but no GPU, and the scheduler — which only places pods against *advertised resources* — will happily schedule your training pod onto a GPU-less node and your nginx pod onto the GPU node.

**What people did before — and why it hurt:**

- **Hand-built AMIs:** bake the driver + container toolkit into a custom image, hand-install the device plugin, redo everything on every driver/CUDA/K8s upgrade. The **driver ↔ CUDA ↔ framework version matrix** is the #1 GPU-ops failure, and with hand-built AMIs *you* are the matrix solver, forever.
- **Per-node manual installs:** SSH + install scripts. Dies the moment nodes are ephemeral — and Karpenter nodes live for *minutes*.
- **No sharing:** one pod = one whole GPU. A notebook using 5% of a T4 blocks the other 95%. At GPU prices this isn't waste, it's a budget scandal.
- **No telemetry:** without an exporter, "is the GPU even being used?" is answered by SSH-ing in and running `nvidia-smi`. Fleet-blind.

**What breaks without it:** GPU nodes that can't run GPU work, non-GPU pods squatting on $2/hr metal, invisible utilization, and an ops team hand-managing driver versions across an autoscaling fleet.

**Who feels the pain most?** The platform engineer (me) — because "make the cluster GPU-ready" lands on exactly my desk, and the naive path is weeks of AMI hell.

> **✅ Check yourself before Rung 2:** Name the three separate things a bare node is missing before a pod can use its GPU (kernel level, container level, Kubernetes level).

---

## RUNG 2 — The One Idea 💡
Memorize this sentence — the whole project derives from it:

> **The GPU Operator installs the entire NVIDIA stack (driver, container toolkit, device plugin, DCGM exporter) as DaemonSets on GPU nodes, and the device plugin then advertises the GPU to the kubelet as a countable resource — `nvidia.com/gpu` — so the ordinary Kubernetes scheduler can place GPU pods exactly the way it places CPU pods, while taints keep everyone else off and Karpenter buys and destroys the expensive metal just-in-time.**

Watch what falls out of it:

- *"as DaemonSets"* → the stack is **reconciled, versioned, upgradeable cluster software**, not baked AMIs. New node joins → DaemonSets land → node becomes GPU-ready automatically. That's why it works with Karpenter's minutes-lived nodes.
- *"advertises a countable resource"* → the scheduler needs **zero GPU knowledge**. It just matches `requests: nvidia.com/gpu: 1` against node allocatable, like CPU. (This simplicity is also the *limitation* that DRA later fixes — Climb 3.)
- *"taints keep everyone else off"* → `nvidia.com/gpu: NoSchedule` means only pods that *tolerate* it (GPU workloads) can land on GPU nodes — the cheap insurance against nginx squatting on an A10G.
- *"Karpenter buys and destroys just-in-time"* → GPU capacity exists **only while a pod needs it**: pending GPU pod → node in ~90s; workload deleted → consolidation kills the node in ~2 min. That's the FinOps story.
- And because the device plugin controls what's advertised, it can **lie productively**: time-slicing tells the kubelet "this 1 GPU is 4 GPUs" → four small pods share one card (Rung 3).

> **✅ Check yourself before Rung 3:** Why does the *scheduler* need no modification to schedule GPUs? And what single mechanism prevents non-GPU pods from landing on GPU nodes?

---

## RUNG 3 — The Machinery ⚙️
### *The most important rung. Three mechanisms: (A) the chain, (B) the sharing lie, (C) the money loop.*

### (A) The pod→GPU chain — the whiteboard answer every JD assumes

```
THE CHAIN (bottom to top — this is THE interview whiteboard)

  EC2 g4dn node (has a T4 on PCIe)
       │
  [1] NVIDIA DRIVER (DaemonSet)          kernel module — the card exists to Linux now
       │
  [2] CONTAINER TOOLKIT (DaemonSet)      containerd runtime hook — injects /dev/nvidia*,
       │                                 CUDA user-space libs into containers that ask
  [3] DEVICE PLUGIN (DaemonSet)          registers with kubelet over a local gRPC socket:
       │                                 "I manage resource nvidia.com/gpu, this node has 1"
  [4] KUBELET                            adds nvidia.com/gpu: 1 to node status
       │                                 (capacity & allocatable — visible in kubectl describe node)
  [5] SCHEDULER                          sees a pod requesting nvidia.com/gpu: 1,
       │                                 filters to nodes with a free unit, binds
  [6] KUBELET → DEVICE PLUGIN Allocate() plugin replies with the device + mounts;
       │                                 toolkit wires the container to the physical GPU
  [7] POD                                torch.cuda.is_available() == True
  
  + DCGM EXPORTER (DaemonSet)  →  /metrics  →  Prometheus ServiceMonitor  →  Grafana 12239
  + NODE FEATURE DISCOVERY      →  labels the node with GPU model/driver facts
  All of [1]–[3] + DCGM + NFD are installed and lifecycle-managed BY THE GPU OPERATOR.
```

The operator is a classic K8s operator (your Kalyan/CKA mental model applies verbatim): it watches nodes, sees "GPU hardware, no stack," and reconciles the DaemonSets into place. **The device plugin is the keystone** — it's the only piece Kubernetes itself talks to, over the device-plugin gRPC API on the kubelet's socket.

### (B) Time-slicing — the productive lie

```
WITHOUT sharing:  device plugin advertises  nvidia.com/gpu: 1   → 1 pod max, 95% idle for small jobs

WITH time-slicing (a ConfigMap the operator feeds the device plugin):
    sharing.timeSlicing.resources: [{name: nvidia.com/gpu, replicas: 4}]
                  device plugin advertises  nvidia.com/gpu: 4   → 4 pods schedule on ONE card
    Reality underneath: the 4 pods' CUDA contexts TAKE TURNS on the whole GPU.
    NO memory isolation, NO fault isolation — one greedy pod can OOM the card for everyone.

THE TRADE-OFF LADDER (know all three cold):
    time-slicing  any GPU     zero isolation      dev/notebooks/bursty small jobs
    MPS           any GPU     memory partitions,  concurrent kernels, better perf,
                              weaker fault isolation
    MIG           A100/H100+  HARD hardware slices (own SMs+memory) — true multi-tenant prod
```

Time-slicing is *scheduling-level* sharing: it changes what's advertised, not what the silicon does. That one sentence is the interview differentiator the project file promises.

### (C) The money loop — Karpenter economics for GPUs

```
pending pod (requests nvidia.com/gpu, tolerates the taint)
    → Karpenter: no node fits → consults NodePool (g4dn|g5, xlarge|2xlarge, spot-first,
      limits: nvidia.com/gpu: 2 ← the hard cost ceiling)
    → provisions ONE right-sized spot node (~90s) → operator DaemonSets land → pod runs
workload deleted
    → node empty → consolidateAfter: 60s → node GONE in ~2 min
GPU $/hr is why consolidateAfter is 60s here vs the lazy defaults you'd use for CPU nodes.
```

DCGM closes the loop: `DCGM_FI_DEV_GPU_UTIL` (is it busy?), `FB_USED/FB_TOTAL` (VRAM), `GPU_TEMP`, and `rate(DCGM_FI_DEV_XID_ERRORS[5m])` — the "this GPU is dying" signal that predicts hardware failure before it takes a training job down.

> **✅ Check yourself before Rung 4:** (1) Recite the 7-step chain from metal to `torch.cuda.is_available()`. (2) What does time-slicing change, and what does it *not* change? (3) Why is `consolidateAfter` aggressive for GPU NodePools?

---

## RUNG 4 — The Vocabulary Map 🏷️

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **GPU Operator** | K8s operator installing/lifecycle-managing the NVIDIA stack | Reconciles [1]–[3]+DCGM+NFD as DaemonSets |
| **NVIDIA driver (DS)** | Kernel module, containerized | Chain step [1] |
| **Container toolkit** | containerd hook injecting devices+CUDA libs | Chain step [2] |
| **Device plugin** | gRPC service advertising `nvidia.com/gpu` to kubelet | Chain steps [3] & [6] — the keystone |
| **`nvidia.com/gpu`** | An *extended resource* — an opaque counter | What the scheduler matches on |
| **NFD** | Node Feature Discovery — labels nodes with hardware facts | GPU model/driver labels |
| **DCGM exporter** | NVIDIA's metrics DaemonSet → Prometheus | The telemetry loop |
| **XID errors** | GPU hardware error codes in DCGM | The failure-prediction signal |
| **Time-slicing** | Device plugin advertises N virtual GPUs per card, contexts take turns | Sharing, zero isolation |
| **MPS** | Concurrent CUDA kernels from multiple processes on one GPU | Sharing, partial isolation |
| **MIG** | Hardware partitioning into isolated slices (A100/H100+) | Sharing, full isolation |
| **Taint `nvidia.com/gpu`** | NoSchedule keep-out sign on GPU nodes | Cost protection |
| **EC2NodeClass / NodePool** | Karpenter's how-to-build / what-to-build for nodes | The money loop |
| **`limits: nvidia.com/gpu: 2`** (NodePool) | Fleet-wide GPU ceiling Karpenter won't exceed | The lab's cost fuse |
| **ServiceMonitor** | CRD telling Prometheus to scrape a service | DCGM → Prometheus wiring |

**Same-thing groups:** time-slicing/MPS/MIG = *three answers to "share one card," differing only in isolation*. Driver/toolkit/device-plugin/DCGM = *one stack, four DaemonSets, one operator*. `nvidia.com/gpu` + taints + NodePool limits = *the three knobs that make GPUs schedulable, exclusive, and capped*.

> **✅ Check yourself before Rung 5:** Which single component is the only one Kubernetes core actually talks to about GPUs — and over what interface?

---

## RUNG 5 — The Trace 🎬
### *Follow one `cuda-vectoradd` Job from `kubectl apply` to "Test PASSED" to the node's death.*

1. **Apply.** The Job's pod requests `nvidia.com/gpu: 1` and tolerates the GPU taint. API server stores it; scheduler finds **no node** with a free `nvidia.com/gpu` → pod `Pending`.
2. **Karpenter reacts.** Sees the unschedulable pod, matches it to the `gpu` NodePool (family g4dn/g5, spot-first, under the 2-GPU limit), and provisions a **g4dn.xlarge spot node** (~90s). `kubectl get nodeclaims -w` shows the purchase live.
3. **Node joins tainted and bare.** It carries the `nvidia.com/gpu: NoSchedule` taint from birth — nothing non-GPU can land, ever.
4. **The operator dresses the node.** GPU Operator's DaemonSets roll on: driver loads into the kernel, toolkit hooks containerd, device plugin registers with kubelet → node status now shows `nvidia.com/gpu: 1` allocatable. DCGM starts exporting; Prometheus's ServiceMonitor picks it up within a scrape interval.
5. **Scheduler binds.** The pending pod now fits; kubelet calls the device plugin's `Allocate()`; toolkit mounts `/dev/nvidia0` + CUDA libs into the container.
6. **The pod computes.** `vectoradd` runs on the T4; logs print **"Test PASSED."** Grafana's utilization panel blips.
7. **Time-slicing act two.** Apply the 4-replica ConfigMap, restart the device plugin DaemonSet → the *same node* now advertises `nvidia.com/gpu: 4`; the 4-replica sharing Deployment schedules **all four pods onto one card**. `kubectl describe node` proves it.
8. **The money shot.** Delete the workloads. Node empties → 60s consolidation timer → Karpenter terminates the spot node. Two minutes after your last pod, GPU spend is **zero**. Screenshot the nodeclaim lifecycle — that's the portfolio's FinOps evidence.

> **✅ Check yourself before Rung 6:** At step 4, what exactly changed in the node object that unblocked the scheduler? At step 7, what changed and what *didn't* change about the physical GPU?

---

## RUNG 6 — The Contrast ⚖️

| | Hand-built AMIs + manual plugin | **GPU Operator (this project)** |
|---|---|---|
| Driver lifecycle | You rebuild AMIs per driver/K8s bump | Operator upgrades DaemonSets |
| Ephemeral nodes (Karpenter) | Painful — every node needs the right AMI | Native — DaemonSets land on any node |
| Version matrix (driver↔CUDA↔framework) | You solve it by hand, per image | Operator ships tested combinations |
| Telemetry | DIY | DCGM exporter included |
| When AMI-baking *is* right | Ultra-fast node boot (driver pre-baked; set `driver.enabled: false`) — neoclouds do both | |

**Sharing contrast (the drill-down you must survive):** time-slicing = any GPU, no isolation, dev density; MPS = concurrency with memory partitions, weak fault isolation; MIG = hardware slices, true multi-tenancy, but A100/H100+ only — *which is why this lab (T4) demonstrates time-slicing and documents MIG*. **When NOT this stack:** tiny inference that fits CPU; or fully-managed endpoints (SageMaker/Bedrock) when you're buying outcomes, not building platform — but every target JD is the *build* side.

**One-sentence why-this-over-that:** the Operator turns GPU-node readiness from a per-image artifact you maintain into cluster software that reconciles itself — which is the only model that survives autoscaling.

> **✅ Check yourself before Rung 7:** Your team runs dev notebooks, and someone proposes MIG on the g4dn fleet. Two things wrong with that sentence?

---

## RUNG 7 — The Prediction Test 🧪
*Write each prediction down, then run the project phase that tests it. Wrong = your model repairing itself.*

**P1 — The taint fence.** *"If I deploy a plain nginx pod with no toleration while the GPU node is up, it will schedule onto a **system** node, never the GPU node — because the NoSchedule taint filters it at scheduling time."* → Run during Phase 5. Also predict the inverse: delete the toleration from the vectoradd Job → it goes Pending even with a free GPU.

**P2 — The advertised lie.** *"Before the time-slicing ConfigMap, `kubectl describe node <gpu>` shows `nvidia.com/gpu: 1`; after applying it and restarting the device-plugin DaemonSet, the same node shows `4` — because time-slicing changes only what the plugin advertises."* → Phase 3/5, Test 2. Then predict: all 4 test pods land on **one** node.

**P3 — Scale-from-zero and back.** *"Applying the vectoradd Job with zero GPU nodes produces a running pod in ≤ ~3 min (Karpenter ~90s + DaemonSets + image pull), and deleting all GPU workloads produces zero GPU nodes within ~2–3 min — because provisioning is pod-triggered and consolidation is 60s."* → Phase 5, Tests 1 & 3. Time both with a stopwatch; **your measured numbers become resume bullets.**

**P4 — Telemetry appears unbidden.** *"Grafana dashboard 12239 will show my GPU within one scrape interval of the node joining, with no manual target config — because DCGM's ServiceMonitor is auto-discovered (`serviceMonitorSelectorNilUsesHelmValues: false`)."* → Phase 4.

---

## 🎁 CAPSTONE — Compress It

**One sentence, cold:** *The GPU Operator installs the NVIDIA driver/toolkit/device-plugin/DCGM stack as self-reconciling DaemonSets so the device plugin can advertise GPUs as a countable resource the stock scheduler places like CPU — with taints fencing the expensive nodes, time-slicing multiplying what's advertised for density, and Karpenter creating and consolidating the metal so GPUs exist only while pods need them.*

**Beginner, 3 sentences:** Kubernetes doesn't natively know GPUs exist, so an "operator" auto-installs everything a node needs and then tells Kubernetes "this node has 1 GPU" as a simple count. Pods just ask for a GPU the way they ask for CPU, a keep-out taint stops normal apps wasting the expensive nodes, and one card can be advertised as four for small jobs. An autoscaler buys the GPU machine only when a pod is waiting and deletes it minutes after the work ends — so you pay almost nothing while idle.

**Shakiest rung, honestly:** Rung 3A step [6] — the kubelet↔device-plugin `Allocate()` handshake, because it's invisible. Fix during the project: `kubectl -n gpu-operator logs ds/nvidia-device-plugin-daemonset` while the vectoradd pod schedules, and watch the allocation happen.

---
---

# CLIMB 2 — CUDA & GPU Performance Engineering 🔬
### Pairs with: [project-16-cuda-gpu-performance-engineering.md](AI Infra-Projects/project-16-cuda-gpu-performance-engineering.md)

## RUNG 0 — The Setup
**What am I learning?** To read GPU performance like an SRE reads a flame graph: the hardware model (SMs, warps, Tensor Cores, memory bandwidth), the software stack (PyTorch → cuDNN/cuBLAS → CUDA → driver), profiling with Nsight, and the **roofline** — the one mental model that tells you whether a workload is compute-, memory-, or comms-bound and therefore which lever helps.

**Why did it land on my desk?** Cheapest project in the repo (< $15), highest fluency-per-hour, and it sharpens every later project: P2's serving choices, P07's topology scoring, and any future MFU math all assume this literacy. Done in parallel with Climb 1 — it needs only a GPU *session*, not the cluster.

**What do I already know?** From Climb 1 / the GenAI ladder: GPUs have thousands of cores for parallel matrix math, the version matrix hurts, and DCGM exports utilization. What I can't yet do is answer *"the GPU shows 40% utilization — why, and what would fix it?"* That question is this entire climb.

---

## RUNG 1 — The Pain 🔥
### *Why does an infra engineer need CUDA literacy at all?*

A team's fine-tune is slow. The GPU costs $2/hr. `nvidia-smi` shows 55% utilization. Now what? Without this skill, the answers are folklore: "buy a bigger GPU" (useless if memory-bound), "increase batch size" (maybe), "it's probably the network" (guess). **Every wrong guess is billed by the hour.**

**What people do without the literacy — and why it hurts:**

- **Treat the GPU as a black box billed by time.** Then utilization theater rules: `nvidia-smi`'s "GPU util" only means *a kernel was resident* — a GPU can read 90% while doing a fraction of its possible work.
- **Upgrade hardware to fix software.** Most real kernels are **memory-bound**; a GPU with 2× the FLOPS but similar bandwidth buys ~nothing for them. Teams discover this after the invoice.
- **Trust vendor peak numbers.** Spec sheets mix *dense* and *sparse* peaks (2× apart) and even mix up SKUs (the A10G is routinely credited with the A10's numbers). Build a roofline or an MFU figure on the wrong peak and every conclusion is silently ~2× off.
- **Can't attribute a win.** "TensorRT made it faster" — why? If you can't say *kernel fusion cut launches and memory round-trips*, you can't predict where it'll help next.

**Who feels the pain most?** The platform team paying the GPU bill — which is exactly why the JDs say "engineers who understand GPUs and CUDA will run the AI era."

> **✅ Check yourself before Rung 2:** Why can `nvidia-smi` show 90% utilization while the GPU does a small fraction of its peak work? (What does that metric actually measure?)

---

## RUNG 2 — The One Idea 💡

> **Every GPU workload is limited by exactly one of three things — compute (SMs saturated), memory bandwidth (waiting on VRAM), or communication (waiting on NCCL/PCIe) — and you can tell which by comparing the kernel's arithmetic intensity (FLOPs per byte moved) against the GPU's ridge point (dense peak FLOPS ÷ memory bandwidth): below the ridge, only moving less data helps; above it, only more FLOPS helps.**

What falls out:

- *"exactly one of three"* → diagnosis **is** the job. Compute-bound = good (you're getting your money's worth). Memory-bound = most real kernels. Comms-bound = distributed training's world.
- *"arithmetic intensity vs ridge point"* → the **roofline** is arithmetic you can do on paper *before* profiling. T4: 65 TFLOPS dense ÷ 300 GB/s = **ridge ≈ 217 FLOPs/byte** — brutally high, so almost everything that isn't a big matmul lives on the memory roof.
- *"dense peak"* → the denominator discipline. Sparse peaks (the 2× figures) require 2:4 structured sparsity nobody's standard workload uses; MFU convention (the PaLM paper) divides by **dense**. Quote sparse and your utilization number flatters itself 2×.
- *"only moving less data helps"* → this is why the two levers that actually move memory-bound workloads are **lower precision** (fp16 = half the bytes, and it turns on Tensor Cores) and **kernel fusion** (fewer round-trips to VRAM = higher intensity). TensorRT and `torch.compile` are those levers, productized.

> **✅ Check yourself before Rung 3:** Compute the ridge point of an A10G (70 TFLOPS dense, 600 GB/s). A kernel at 5 FLOPs/byte on that card — which roof is it under, and name the only two lever types that help it.

---

## RUNG 3 — The Machinery ⚙️
### *(A) the hardware model, (B) the software stack, (C) the roofline with real numbers, (D) how profilers see it.*

### (A) The hardware model — five words that carry everything

```
GPU = many SMs  ·  SM runs WARPS  ·  TENSOR CORES do matrix math  ·  VRAM has a BANDWIDTH  ·  OCCUPANCY keeps SMs fed

  SM (streaming multiprocessor)  the unit of compute. T4 = 40 SMs. Kernels launch a GRID of
                                 BLOCKS; blocks land on SMs; blocks are executed as
  WARP                           groups of 32 threads in lockstep. Branch divergence within a
                                 warp serializes both paths — why GPU code avoids branchy logic.
  TENSOR CORES                   dedicated matrix-multiply-accumulate units (T4: 320).
                                 Engage ONLY for matmul-shaped work in fp16/bf16/tf32 —
                                 the entire reason "mixed precision" is a speed feature.
  MEMORY                         registers → shared memory (per-SM, ~TB/s, tiny) → L2 →
                                 VRAM (T4: 16GB GDDR6 @ 300 GB/s). Each level ~an order of
                                 magnitude slower. Locality (reuse in shared memory) is the game.
  OCCUPANCY                      enough resident warps per SM that memory stalls are hidden
                                 by switching to another warp. Low occupancy = stalls visible.
```

### (B) The software stack — and why the version matrix exists

```
your code → PyTorch → cuDNN / cuBLAS (NVIDIA's tuned kernels — you almost never write kernels;
            you call these) → CUDA runtime → DRIVER → GPU
Each layer pins acceptable versions of the one below ⇒ the compatibility matrix from Climb 1.
Now you know WHY: PyTorch binaries are compiled against a CUDA version, which requires a
minimum driver. The matrix isn't bureaucracy; it's ABI.
```

### (C) The roofline, numerically (T4 lab card)

```
                 ▲ achievable FLOPS
      65 TFLOPS ─┤· · · · · · · · · ─────────── compute roof (DENSE peak)
                 │                 /
                 │   memory roof  /    achievable = min(AI × 300 GB/s, 65 TFLOPS)
                 │  (slope =     /
                 │   300 GB/s)  /
                 └─────────────┼──────────────▶ arithmetic intensity (FLOPs/byte)
                          ridge ≈ 217

  vecadd:        1 FLOP / 12 bytes  = 0.083  → memory-bound by ~2,600× → ceiling ≈ 25 GFLOPS
                 (0.04% of peak — CORRECT behavior, predictable before running)
  naive matmul:  ≈ 0.25             → memory-bound
  tiled matmul:  ≈ 0.25 × T (tile)  → ~8 @ T=32 → 32× better, STILL memory-bound on a T4
  big fp16 GEMM (Tensor Cores):     → the one thing that approaches the compute roof
  DENSE-PEAK TRAPS: A10G = 70 TFLOPS (the famous ~125 belongs to the A10 — different SKU);
  L4's sheet headlines the SPARSE 242 (dense = 121); sparse figures NEVER go in a roofline/MFU.
```

### (D) How the two profilers divide the work

- **Nsight Systems (`nsys`)** = the *timeline*: GPU busy vs idle, kernel vs memcpy vs gaps, dataloader starvation (the classic find: GPU idles between steps waiting on the CPU input pipeline — fixed with workers/prefetch/pinned memory, a pure infra win). NVTX ranges label your phases.
- **Nsight Compute (`ncu`)** = *one kernel under a microscope*: achieved occupancy, memory throughput vs peak, roofline placement, Tensor-Core activity (`sm__pipe_tensor`), warp-stall reasons. You read its report; you don't rewrite the kernel.
- **DCGM** (from Climb 1) is the *fleet* view; Nsight is the *why*. Correlating a DCGM utilization dip to an Nsight-identified stall is the most senior-sounding demo in the portfolio.

> **✅ Check yourself before Rung 4:** (1) What's a warp, and why does branch divergence hurt? (2) Which profiler answers "is the GPU waiting on the dataloader?" and which answers "is this kernel memory-bound?" (3) Why does fp16 speed up a *memory-bound* kernel even if Tensor Cores didn't exist?

---

## RUNG 4 — The Vocabulary Map 🏷️

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **SM** | The GPU's compute unit (T4: 40) | Hardware model |
| **Warp** | 32 threads in lockstep | Execution unit on an SM |
| **Occupancy** | Resident warps vs max — stall-hiding ability | Why kernels underperform |
| **Tensor Core** | Matrix-multiply-accumulate unit | The fp16/bf16 speed source |
| **HBM / GDDR** | VRAM technologies; what "bandwidth" measures | The memory roof's slope |
| **Shared memory** | Tiny per-SM scratchpad (~TB/s) | The locality lever (tiling) |
| **cuDNN / cuBLAS** | NVIDIA's tuned kernel libraries | What PyTorch actually calls |
| **Arithmetic intensity** | FLOPs ÷ bytes moved | The roofline's x-axis |
| **Ridge point** | Dense peak ÷ bandwidth | Memory-vs-compute boundary |
| **Dense vs sparse peak** | Real peak vs 2:4-structured-sparsity marketing 2× | The denominator discipline |
| **MFU** | Achieved FLOPS ÷ dense peak | The training-efficiency KPI |
| **Roofline** | min(AI × BW, peak) picture | The diagnosis tool |
| **`nsys` / `ncu`** | Timeline profiler / kernel profiler | Where vs why |
| **NVTX** | Code annotations visible in profiles | Labeling phases |
| **AMP / autocast** | PyTorch mixed-precision machinery | Turns on Tensor Cores + halves bytes |
| **Kernel fusion** | Merging kernels → fewer launches & VRAM round-trips | TensorRT/`torch.compile`'s win = an AI raise |
| **Coalesced access** | Adjacent threads reading adjacent memory | Bandwidth efficiency |
| **Grid / block / thread** | Kernel launch hierarchy | How work maps to SMs |

**Same-thing groups:** `torch.compile` / TensorRT / tiling = *all arithmetic-intensity raisers (fusion/locality)*. MFU / roofline-fraction / "achieved-over-dense-peak" = *the same ratio in three costumes*. DCGM util / `nsys` busy% / `ncu` occupancy = *three zoom levels of "is it working?"*.

> **✅ Check yourself before Rung 5:** A kernel shows high occupancy, 70% of peak *bandwidth*, 8% of peak *FLOPS*. Diagnose it in one sentence, and name the two levers worth trying.

---

## RUNG 5 — The Trace 🎬
### *Follow one profiling investigation end-to-end (the project's Phases 2→5 as a story).*

1. **Symptom.** A HF fine-tune on the T4 node feels slow. DCGM shows utilization sawtoothing 30–90%.
2. **Timeline first.** `nsys profile -t cuda,cudnn,nvtx ... python train_step.py --steps 50`. The timeline shows the classic crime: **gaps between steps** — GPU idle while the CPU dataloader prepares the next batch, plus H2D copies not overlapped.
3. **The infra fix.** More workers + prefetch + pinned memory (`non_blocking=True`). Re-profile: gaps closed, GPU-busy% up. *No ML knowledge touched.* Save the before/after — that's the YouTube demo.
4. **Zoom into the hottest kernel.** `ncu --set roofline -k regex:"gemm"`. Report: fp32 GEMM, no Tensor-Core activity, memory throughput near peak → memory-bound *and* leaving the matrix units idle.
5. **The precision lever.** Run the Phase-4 bench: fp32 vs AMP fp16. fp16 engages Tensor Cores and halves bytes/element → measured **1.5–3× steps/s**. (On the T4, remember: no bf16 — Turing has no bf16 path; that "trap" is itself interview material.)
6. **Convert to MFU.** Best steps/s → achieved TFLOPS → divide by **65** (T4 dense). The honest fraction is the number that goes in the README — and you can now explain why dividing by a sparse peak would have flattered it 2×.
7. **The fusion lever.** `torch.compile(mode="max-autotune")`, then torch-tensorrt: re-run `nsys`, **watch the kernel count drop** — fusion attributed, not asserted. Latency table published.
8. **Demystification.** Write `vecadd.cu`, *predict* its ceiling by hand (0.083 AI → ~25 GFLOPS → success metric is **bandwidth**, not FLOPS), run `ncu`, confirm. Then tiled matmul: measure the ~32× intensity jump from shared-memory reuse — and lose gracefully to cuBLAS, which is the lesson.

> **✅ Check yourself before Rung 6:** At step 2, why was the *timeline* profiler the right first tool (not `ncu`)? At step 6, what exactly would have gone wrong with a sparse-peak denominator?

---

## RUNG 6 — The Contrast ⚖️

**Infra-engineer literacy vs kernel author:** you read reports, run benches, and diagnose; you don't hand-optimize kernels (cuBLAS beats you; being beaten *is* the lesson). The market pays platform people for the *diagnosis*, not the CUDA authorship.

**`nvidia-smi` utilization vs real efficiency:** util% = "a kernel was resident," not "SMs were productive." MFU (vs dense peak) and `ncu` occupancy are the honest metrics. Never quote util% as efficiency in an interview.

**Dense vs sparse peaks:** dense = what standard workloads can reach; sparse = 2:4-structured-sparsity marketing. Rooflines and MFU use dense, per the PaLM convention. Knowing the A10G-vs-A10 SKU mixup is a correction that travels (it's literally the project's LinkedIn post).

**When NOT to reach for this:** if the workload is comms-bound (NCCL/EFA — a later project's world), no amount of kernel work helps; and for a one-off small job, profiling costs more than it saves. Diagnose *first*, always.

**One-sentence why-this-over-that:** roofline-first diagnosis replaces hardware-upgrade guesswork with a two-number verdict — arithmetic intensity vs ridge point — that tells you *which* lever (precision, fusion, batch, or nothing) will actually move the workload.

> **✅ Check yourself before Rung 7:** A teammate proposes upgrading T4 → L4 ("2× the FLOPS!") for a workload you've measured at 3 FLOPs/byte. L4: 121 TFLOPS dense, **300 GB/s**. Verdict, in one sentence with the numbers?

---

## RUNG 7 — The Prediction Test 🧪
*All from the project's own phases; total spend a few dollars of spot T4 time.*

**P1 — Predict a kernel's ceiling before running it.** *"vecadd moves 12 bytes per 1 FLOP (AI = 0.083); against a 217 ridge it's memory-bound by ~2,600×, so it will achieve ~0.04% of peak FLOPS, and its bandwidth (12n/time) will approach 300 GB/s — because the memory roof, not compute, caps it."* → Phase 6. If the FLOPS number had shocked you, the roofline wasn't yet yours.

**P2 — The dataloader crime.** *"The first `nsys` timeline of the training loop will show GPU-idle gaps between steps caused by the input pipeline, and workers+prefetch+pinned memory will visibly close them — because the GPU is faster than the un-tuned CPU feed."* → Phase 2. (The project calls this finding "almost guaranteed" — but *predict the shape before you look*.)

**P3 — Tensor Cores are a step function.** *"AMP fp16 will give ~1.5–3× steps/s over fp32 on the same model AND cut peak memory — because Tensor Cores engage and every tensor halves its bytes; and bf16 will be absent on the T4 because Turing has no bf16 path."* → Phase 4 bench table.

**P4 — Fusion shows up as fewer kernels.** *"`torch.compile` / TensorRT will reduce measured latency AND the `nsys` kernel count will visibly drop — because the speedup mechanism is fusion (fewer launches, fewer VRAM round-trips), not magic."* → Phase 5 re-profile.

---

## 🎁 CAPSTONE — Compress It

**One sentence, cold:** *GPU performance reading is a two-number diagnosis — a kernel's arithmetic intensity against the card's ridge point (dense peak ÷ bandwidth) — that tells you whether it's compute-, memory-, or comms-bound and therefore whether precision (Tensor Cores, half the bytes), fusion (fewer VRAM round-trips), batching, or nothing will move it; Nsight Systems finds where time goes, Nsight Compute says why, and every efficiency claim divides by the dense peak.*

**Beginner, 3 sentences:** A GPU is thousands of small calculators attached to a memory pipe, and most programs are limited by the pipe, not the calculators. There's simple arithmetic — how much math you do per byte you move — that predicts which limit you're hitting and what would help. Profilers then show you the same answer visually: first "where did the time go?" on a timeline, then "why is this one operation slow?" under a microscope.

**Shakiest rung, honestly:** Rung 3C's by-hand roofline math. Fix: do the vecadd and tiled-matmul calculations on paper (project §4a and §7) *before* running `ncu`, then check the chart agrees. Once your hand math and the profiler agree twice, this is permanent.

---
---

# CLIMB 3 — The Topology-Aware Gang Scheduler 🧩
### Pairs with: [project-07-topology-aware-gang-scheduler.md](AI Infra-Projects/project-07-topology-aware-gang-scheduler.md)

## RUNG 0 — The Setup
**What am I learning?** Kube-scheduler internals — the Scheduling Framework and its extension points — deeply enough to first *operate* the incumbent batch schedulers (Kueue, Volcano) against real failure scenarios, and then *build* my own second scheduler in Go: gang (all-or-nothing) placement that also packs a job into the same network domain. Validated on 1,000 fake nodes with kwok, ~$0.

**Why did it land on my desk?** The single most differentiating artifact in my portfolio — the only one that answers the Cisco "Golang + scheduler internals" ask — and it's the question every AI company fights daily: *which job gets the GPUs, when, and why?* It needs neither the cluster (kind/kwok) nor much money.

**What do I already know?** Scheduling basics from CKA (taints, affinity, priorities), Kueue's name from the roadmap, and — critically — that **Go is new to me**: the ladder model must be solid enough that the Go on-ramp (Tour of Go + the plugin skeleton) is *translation*, not discovery. What I don't yet know: what happens between "pod Pending" and "pod Bound," and why that pipeline's design makes gang scheduling impossible without extending it.

---

## RUNG 1 — The Pain 🔥
### *Why is the default scheduler actively wrong for AI training?*

The kube-scheduler places pods **one at a time**, greedily, with no memory of "these 16 pods are one job" and no idea that two nodes on the same switch are 2–5× faster for NCCL than two across the spine. Training is batch-HPC wearing a Kubernetes costume, and one-at-a-time greedy placement produces five distinct production disasters:

1. **Deadlock by partial placement.** Two 4-GPU jobs hit a 6-GPU cluster; each grabs 3; both wait forever; 6 GPUs burn money doing nothing. A 16-pod `torchrun` job with 12 placed is *worthless* — rendezvous never completes — yet those 12 GPUs are held hostage.
2. **Starvation.** A stream of small jobs perpetually leapfrogs the big pretraining run; without priority+preemption the 8-GPU job's queue-wait is unbounded.
3. **Quota hoarding.** Team A's idle guaranteed share can't help team B's queue without borrowing-with-reclaim semantics.
4. **Fragmentation.** 8 nodes with 1 free GPU each = 8 free GPUs that cannot run one 8-GPU job. Silent 20–30% fleet waste.
5. **Topology blindness.** The scheduler happily scatters a gang across spine switches, and the NCCL all-reduce pays the bandwidth tax on *every* training step forever after.

**What people did before:** ran HPC on Slurm (gang-native, but a second world outside K8s), or lived with the pathologies, or bolted on ad-hoc "wait for all pods" scripts that raced the scheduler. **What breaks without the fix:** the most expensive hardware in the company sits deadlocked, starved, hoarded, fragmented, and mis-placed — *simultaneously*.

> **✅ Check yourself before Rung 2:** Explain deadlock-by-partial-placement to a colleague using the two-4-GPU-jobs-on-6-GPUs example, and name the property a scheduler needs to make it structurally impossible.

---

## RUNG 2 — The One Idea 💡

> **The kube-scheduler is a pluggable pipeline (QueueSort → PreFilter → Filter → Score → Reserve → Permit → Bind) that decides one pod at a time — so to schedule a *gang*, you insert yourself into that pipeline and hold every member at the Permit gate, in "Waiting," until the whole gang has reserved its resources, then release them all at once (or time out and release the reservations) — and while you're scoring candidate nodes anyway, you prefer nodes in the same network domain as the gang's already-reserved members.**

What falls out:

- *"pluggable pipeline"* → you don't fork the scheduler; you write **plugins** against the Scheduling Framework's extension points and ship them as a **second scheduler** pods opt into via `schedulerName`.
- *"hold at Permit"* → the gang gate. Waiting pods keep their **Reserve**d resources in the scheduler cache — atomic release, and on timeout **Unreserve** frees everything, so the gang mechanism itself can't deadlock.
- *"one pod at a time"* is *why* all-or-nothing must be grafted on — and why there are two philosophies: gate **admission** before the scheduler ever sees pods (Kueue suspends whole Workloads) or gate **placement** (Volcano / coscheduling / mine).
- *"prefer the same network domain"* → topology is just a **Score** plugin reading node labels (`topology.k8s.aws/network-node-layer-3`) — a soft preference that degrades gracefully instead of blocking.
- *"scoring anyway"* → bin-packing (MostAllocated) rides along in the same Score, attacking fragmentation too.

> **✅ Check yourself before Rung 3:** Why must the gang gate live at Permit (after Reserve) rather than being a webhook or an admission check? What do Waiting pods hold that makes release atomic?

---

## RUNG 3 — The Machinery ⚙️
### *(A) the framework pipeline, (B) the gang gate in motion, (C) admission-time vs placement-time, (D) the free lab (kwok/faked GPUs) and DRA.*

### (A) The pipeline — one pod's journey through a scheduling cycle

```
 pending queue ──▶ QueueSort        who's next? (ONE sort per binary — replacing it re-orders
                    │                EVERYTHING; this is WHY gang schedulers ship as a second
                    ▼                scheduler rather than reconfiguring the default)
                  PreFilter         cheap global sanity: "can this possibly fit anywhere?"
                    │                (TopoGang: total free GPUs < gang's need ⇒ reject FAST,
                    ▼                 before any partial placement can happen)
                  Filter            per-node feasibility (taints, resources, affinity)
                    ▼
                  Score             rank feasible nodes 0–100
                    │                (TopoGang: +60 same layer-3 domain as reserved gang
                    ▼                 members, +40 GPU bin-packing MostAllocated)
                  Reserve           tentatively claim the resources in the SCHEDULER CACHE
                    │                (not yet real on the node; Unreserve is the undo)
                    ▼
                  Permit            ✋ THE GANG GATE: Wait until all N members reserved;
                    │                last one in ⇒ Allow() every Waiting sibling; 120s
                    ▼                timeout ⇒ reject all ⇒ Unreserve frees the claims
                  Bind              write pod.spec.nodeName — now it's real
```

### (B) The gang gate in motion (4-pod gang, 3 fit)

```
pod1: …Reserve ✓ → Permit: 1/4 reserved → WAIT (holds its claim)
pod2: …Reserve ✓ → Permit: 2/4 → WAIT
pod3: …Reserve ✓ → Permit: 3/4 → WAIT
pod4: Filter: no node fits! ⇒ cycle fails ⇒ pods 1–3 hit the 120s Permit timeout
      ⇒ Unreserve ×3 ⇒ ALL claims freed ⇒ zero GPUs held hostage ⇒ next job proceeds
THE INVARIANT: a gang binds all N or binds zero. Partial placement is impossible by construction.
```

### (C) The two philosophies (and the comparison table you'll build)

- **Admission-time gang — Kueue:** a quota controller *in front of* the untouched default scheduler. Jobs arrive `suspend: true`; Kueue admits a whole Workload only when its full quota fits (all-or-nothing **at admission** — S5's deadlock dies by construction), and layers ClusterQueues/cohorts/borrowing/reclaim/preemption on top. Low ops risk; delegates actual placement.
- **Placement-time gang — Volcano / coscheduling / TopoGang (mine):** a true second scheduler gates *binding*. Volcano: PodGroups + `minAvailable`, plus DRF fairness and binpack plugins. Coscheduling (in the same repo you fork): PodGroup CRD + Permit. Mine adds the topology Score.
- **Both verbs matter:** you *operate* Kueue and Volcano through the S1–S5 scenario matrix first (deadlock, borrowing, reclaim, preemption, starvation), then *build* the placement-time one — operating and building are different resume verbs.

### (D) Why this is ~$0, and the DRA footnote

The scheduler never touches silicon — it reads **node status**. So: `kubectl patch node --subresource=status` fakes `nvidia.com/gpu: 4` on kind workers, and **kwok** fakes 1,000 8-GPU nodes with synthetic topology labels on a laptop. Scale-testing a scheduler is free by design. And the device plugin's opaque counter is being succeeded by **DRA** (GA in K8s 1.34): ResourceClaims with CEL selectors ("any GPU with ≥40Gi") — the project demos it because almost no candidate can, but the counter model above is still what runs nearly everywhere today.

> **✅ Check yourself before Rung 4:** (1) Walk the pipeline naming what TopoGang does at QueueSort, PreFilter, Score, Reserve, Permit. (2) In the 4-pod trace, what exactly frees the 3 held claims? (3) Kueue vs Volcano in one sentence each: *where* does each enforce the gang?

---

## RUNG 4 — The Vocabulary Map 🏷️

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Scheduling Framework** | The extension-point API inside kube-scheduler | The pipeline itself |
| **Extension points** | QueueSort/PreFilter/Filter/Score/Reserve/Permit/Bind… | Where plugins hook in |
| **Second scheduler** | Another scheduler binary; pods opt in via `schedulerName` | How custom schedulers ship |
| **Gang / co-scheduling** | All-or-nothing placement of N pods | The Permit gate |
| **PodGroup** | CRD naming a gang + `minMember` | Volcano's/coscheduling's gang handle |
| **Permit / Waiting pod** | Gate that can hold a reserved pod | Where the gang waits |
| **Reserve / Unreserve** | Tentative claim in scheduler cache / its undo | Why timeout can't leak GPUs |
| **Kueue** | Quota/admission controller (suspend→admit whole Workloads) | Admission-time gang |
| **ClusterQueue / cohort / borrowing / reclaim** | Team quota / shared pool / take-idle / take-back | Kueue's fairness model |
| **Volcano** | Replacement scheduler: PodGroups, DRF, binpack | Placement-time incumbent |
| **DRF** | Dominant-resource fairness | Volcano's fairness math |
| **Preemption** | Evicting lower-priority to admit higher | The starvation fix |
| **Fragmentation** | Free GPUs stranded on partially-used nodes | What binpack + `gpu_frag.py` attack |
| **Topology labels** | `topology.k8s.aws/network-node-layer-{1..3}` (EC2 instance-topology API) | What the Score reads |
| **kwok** | Fake kubelets — 1,000 nodes on a laptop | The $0 scale lab |
| **kube-scheduler-simulator / scheduler_perf** | Per-plugin score debugger / official bench harness | kwok's complements |
| **DRA / ResourceClaim / DeviceClass** | Structured device requests with CEL selectors | The device plugin's successor |
| **scheduler-plugins repo** | SIG-owned fork base with the ~34 `replace` directives solved | Why you fork, not `go get k8s.io/kubernetes` |

**Same-thing groups:** Volcano `minAvailable` / coscheduling `minMember` / TopoGang `gang-size` label = *the same all-or-nothing knob, three homes*. Kueue-admission vs everything-else-placement = *the one axis the whole comparison table hangs on*. Reserve/Permit/Unreserve = *one transaction: claim, hold, commit-or-rollback*.

> **✅ Check yourself before Rung 5:** Why can't you just `go mod init && go get k8s.io/kubernetes` to build a plugin — and what does forking scheduler-plugins inherit that solves it?

---

## RUNG 5 — The Trace 🎬
### *Follow one 4-pod gang (`gang-size: 4`, 1 GPU each) through TopoGang on the kwok fleet.*

1. **Submit.** Four pods carry `topogang.io/gang-name: job-a`, `gang-size: 4`, `schedulerName: topogang-scheduler`. They enter *this* scheduler's queue — the default scheduler never sees them.
2. **QueueSort.** `Less()` sorts by gang name, then creation time → the four drain **adjacently**, not interleaved with strangers. (And because only one QueueSort can exist per binary, this re-orders every pod this scheduler owns — the documented reason gang schedulers are second schedulers.)
3. **PreFilter (pod1).** Sum free GPUs across the fleet snapshot: cluster-wide free ≥ 4×1? Yes → proceed. (If not: `Unschedulable` *now*, zero partial placement — pathology #1 dead at the door.)
4. **Filter → Score (pod1).** Feasible nodes ranked: no gang member reserved yet, so topology's 60 points go to every candidate equally; bin-packing's 40 favor fuller nodes → pod1 heads toward the fullest node in some layer-3 brick, say `nn-l3-7`.
5. **Reserve → Permit (pod1).** Claim cached; Permit counts 1/4 reserved → **Wait** (120s clock starts).
6. **Pods 2–4 follow.** Now Score's topology half bites: nodes in `nn-l3-7` get +60 over other bricks → the gang **packs into one network domain**. Reserve, Permit: 2/4… 3/4… wait.
7. **The release.** Pod4 reserves → Permit sees 4/4 → `IterateOverWaitingPods` → `Allow()` all siblings → four **Bind**s in the same instant. `torchrun` rendezvous completes; NCCL all-reduce runs at same-leaf bandwidth.
8. **Counterfactual A (no room):** pod4 finds no feasible node → pods 1–3 time out at Permit → Unreserve frees 3 GPUs → a waiting 2-pod gang schedules immediately. No deadlock, no hostages.
9. **Counterfactual B (scheduler dies mid-gang):** the chaos drill — kill the scheduler pod after 2/4; waiting pods' permits lapse, reservations release on restart. Correctness survives the operator's own failure.
10. **Measure.** `sim/gangs.py` reports time-to-full-placement and **topology purity** (% of gangs entirely within one layer-3); `gpu_frag.py` shows fragmentation with/without bin-packing. Those measured numbers are the resume bullet.

> **✅ Check yourself before Rung 6:** At step 6, what changed in Score between pod1 and pod2? At step 8, name each mechanism in the chain that guaranteed zero stranded GPUs.

---

## RUNG 6 — The Contrast ⚖️

| | Gang | Topology | Quota/fairness | Acts at |
|---|---|---|---|---|
| default scheduler | ✗ | ✗ | ✗ | placement |
| **TopoGang (mine)** | ✓ Permit | ✓ Score | ✗ | placement |
| coscheduling (SIG) | ✓ Permit+PodGroup | ✗ | ✗ | placement |
| Volcano | ✓ | partial (binpack) | ✓ DRF/queues | own scheduler |
| Kueue | ✓ at admission | ✓ TAS | ✓ cohorts/borrow/reclaim | admission |

**The interview-grade distinctions:** Kueue never places pods — it *admits* whole Workloads then delegates to the stock scheduler (lowest ops risk; quota-rich); Volcano replaces the scheduler outright (runtime gangs, DRF, more to operate); TopoGang shows you can *build* the placement-time mechanics yourself. **vs Slurm:** gang-native HPC, but a second world with no K8s API/ecosystem — the entire industry motion is teaching K8s to do Slurm's tricks. **When NOT to build your own:** production. You build TopoGang to *own the internals*; a real platform runs Kueue and/or Volcano/KAI, and your S1–S5 benchmark of all five schedulers is precisely the evidence that you know when each is right.

**One-sentence why-this-over-that:** admission-time gangs (Kueue) buy safety and quota semantics without touching placement; placement-time gangs (Volcano/coscheduling/mine) buy runtime control and topology; serious platforms compose both — and I've operated the former and built the latter.

> **✅ Check yourself before Rung 7:** An interviewer asks "why is your gang gate at Permit and not an admission webhook?" — give the two-part answer (what Waiting pods hold; what a webhook can't see).

---

## RUNG 7 — The Prediction Test 🧪
*All ~$0 on kind + kwok. P1 needs nothing but kind and a `kubectl patch`.*

**P1 — Reproduce the deadlock on purpose.** *"On a kind cluster patched to 6 fake GPUs, submitting two 4×1-GPU Jobs simultaneously under the default scheduler will leave each holding 3 pods and both stalled Pending forever — because one-at-a-time placement has no all-or-nothing concept."* → Project Phase 1. The `FailedScheduling` events screenshot is portfolio artifact #1.

**P2 — Kueue kills it at admission.** *"Replaying the same two jobs through Kueue ClusterQueues, the second Workload stays entirely `Suspended` — zero pods created, zero partial allocation — because Kueue admits whole Workloads against quota before the scheduler ever sees them."* → Phase 2, scenario S5. Then predict S2: when team B submits, A's *borrowed* (lowest-priority) workloads get evicted and re-queued — reclaim in action.

**P3 — The Permit gate makes it atomic (mine).** *"A 16-pod gang submitted to TopoGang on a kwok fleet with room for only 15 will bind zero pods and release every reservation at the 120s timeout, and a subsequent 8-pod gang will schedule immediately — because Permit holds and Unreserve rolls back."* → Phases 8/13 chaos drill #1.

**P4 — Topology purity is measurable, not aspirational.** *"On 1,000 kwok nodes with 3-level synthetic topology, TopoGang's gangs will land overwhelmingly within single layer-3 bricks while the default scheduler's spread across many — because +60 Score points dominate placement once one member is reserved."* → Phase 8, `sim/gangs.py` purity metric vs the default-scheduler run. Your two measured numbers side by side = the money slide.

---

## 🎁 CAPSTONE — Compress It

**One sentence, cold:** *The kube-scheduler is a pluggable one-pod-at-a-time pipeline, so gang scheduling means holding each member's reserved claim at the Permit gate until all N are reserved — releasing atomically or timing out into Unreserve so nothing is ever held hostage — while a Score plugin packs the gang into one network domain and bin-packs GPUs; Kueue achieves the same all-or-nothing earlier by admitting whole quota-checked Workloads, Volcano by replacing the scheduler with PodGroups, and I've operated both and built the third.*

**Beginner, 3 sentences:** Kubernetes normally places pods one by one, which deadlocks jobs that need all their pods at once — two half-placed jobs can block each other forever on expensive GPUs. A gang scheduler makes placement all-or-nothing: every pod's spot is tentatively held until the whole group fits, then all start together, or the holds are released so nothing is wasted. Mine also prefers putting the group on machines wired to the same switch, because training pods talk constantly and same-switch bandwidth is several times higher.

**Shakiest rung, honestly:** the Go itself (Rung 5's code, not its concepts) — I'm new to the language. Fix: after Tour of Go, read the project's `plugin.go` top-to-bottom *mapping each function to the pipeline stage in my Rung 3 diagram* — the ladder means the Go is translation, not discovery. Budget the 2–3-week on-ramp the roadmap already reserves; don't let it silently eat project-2's slot.

---
---

# CLIMB 4 — The LLM Inference Platform 🚀
### Pairs with: [project-2-llm-inference-platform.md](AI Infra-Projects/project-2-llm-inference-platform.md)

## RUNG 0 — The Setup
**What am I learning?** How production LLM serving actually works — KV cache, PagedAttention, continuous batching — and the ops around it: vLLM with an OpenAI-compatible API, **KEDA autoscaling on queue depth**, canary rollouts **gated on p95 latency** with Argo Rollouts, and k6 load-test evidence, all on Climb 1's cluster.

**Why did it land on my desk?** Serving is the core thing the target companies *do* — inference is the workload that pays for everything. vLLM + KEDA + canary is the credible baseline, and it converts my Harman skills (probes, HPA/KEDA, Argo, SLOs) into the AI domain almost one-for-one.

**What do I already know?** From the GenAI ladder: generation is a next-token loop; the context window and weights live in GPU memory; prefill vs decode differ. From Harman: KEDA, Argo Rollouts's cousins (Argo CD), Prometheus SLOs, k6-style load testing. The genuinely new part: *why the KV cache is the real resource* and everything that follows from that.

---

## RUNG 1 — The Pain 🔥
### *Why can't you serve an LLM like a web service?*

Treat vLLM like nginx and everything misfires:

- **A request isn't a unit of work — a token is.** One request = 1 prefill pass + N sequential decode passes. A 50-token answer and a 2,000-token answer differ 40× in cost under the same "1 request." Requests-per-second is a meaningless capacity number.
- **Naive/static batching wastes the GPU.** Serve one request at a time → the GPU idles between decode steps of a single sequence. Static batching → the whole batch waits for its *longest* member to finish while short requests' slots sit empty. Either way, 5–10× throughput is left on the table.
- **VRAM fragments.** Every in-flight request pins a **KV cache** proportional to its context length. Reserve contiguous worst-case space per request (the pre-vLLM norm) and memory fragments so badly that ~60–80% of KV memory is waste → tiny effective batch.
- **CPU-based autoscaling is blind.** A saturated vLLM pod sits at ~30% CPU while 50 requests queue — HPA-on-CPU would *never scale it*. (Your CPU-era instinct, precisely wrong.)
- **Blind rollouts are outages.** A "small" change — new model rev, different `--max-model-len` — can silently double p95. Ship it to 100% and users find out before you do.

**Who feels the pain most?** The inference platform team burning $2/hr per GPU at 20% effective utilization, then paging through a latency regression they deployed themselves.

> **✅ Check yourself before Rung 2:** Why would a CPU-target HPA never scale a saturated vLLM pod? And why is static batching wasteful even though it *is* batching?

---

## RUNG 2 — The One Idea 💡
The project file's own four sentences, welded into one — this is the mental model that puts you "ahead of 90% of platform candidates":

> **In LLM serving the token is the unit of work and the KV cache is the scarce resource, so vLLM manages KV memory in small pages like an OS manages virtual memory (PagedAttention — no fragmentation, so far more requests fit) and lets new requests join the running batch between decode steps (continuous batching — the GPU never idles); therefore the true load signal is queue depth / KV-cache pressure, which is what KEDA scales pods on while Karpenter scales the metal, and every rollout is a canary that promotes only if measured p95 stays inside SLO.**

What falls out:

- *"token is the unit"* → capacity, latency, and cost all decompose into **TTFT** (time to first token — the prefill) + **inter-token latency** (the decode loop). You quote those, not RPS.
- *"KV pages like virtual memory"* → PagedAttention is *literally* the OS-paging idea applied to KV blocks: allocate on demand in small pages, no contiguous reservation, near-zero fragmentation → bigger effective batch on the same VRAM.
- *"join between decode steps"* → continuous batching: the batch is rebuilt every ~few-ms decode step, so a finished request's slot is refilled *immediately*.
- *"queue depth is the truth"* → `vllm:num_requests_waiting` is the scaling signal; `gpu_cache_usage_perc` is the pressure gauge. **KEDA scales pods; Karpenter scales metal** — the sentence the project calls interview gold.
- *"canary gated on p95"* → an Argo Rollouts `AnalysisTemplate` runs the p95 PromQL and auto-aborts a bad rev — SLOs as *gates*, not dashboards.

> **✅ Check yourself before Rung 3:** What problem of the "reserve worst-case contiguous KV per request" scheme does paging solve, and what capacity metric improves as a direct result?

---

## RUNG 3 — The Machinery ⚙️
### *(A) the request anatomy, (B) PagedAttention + continuous batching, (C) the two-layer autoscale, (D) the gated canary.*

### (A) One request, two phases (Climb 2's roofline, applied)

```
"Explain KV cache" ──▶ tokenize ──▶ PREFILL: one pass over ALL prompt tokens in parallel
                                     · compute-bound (big matmuls, Tensor Cores earn their keep)
                                     · produces token #1  ⇒ TTFT is mostly prefill time
                                    DECODE: one pass per new token, each reading ALL the weights
                                     · memory-bandwidth-bound (Climb 2: low arithmetic intensity)
                                     · N tokens = N passes ⇒ inter-token latency × length = the tail
WHY CACHE? Attention needs every prior token's K/V vectors each step. Recomputing them
every step would be quadratic — so you keep them in VRAM: THE KV CACHE. Its size grows
with context length × batch size. THAT is the resource everything fights over.
```

### (B) The two vLLM tricks

```
PagedAttention                                Continuous batching
──────────────                                ───────────────────
old way: reserve max-model-len of             old way: batch waits for its longest
contiguous VRAM per request                   member; finished slots sit idle
  → internal fragmentation → ~60-80%            → GPU under-fed between requests
    of KV memory wasted → tiny batch
                                              vLLM: the batch is re-formed at EVERY
vLLM: KV lives in small PAGES,                decode step — new requests slip in the
allocated on demand, non-contiguous,          moment a slot frees; nothing waits for
tracked by a block table (an OS page          strangers to finish
table, for attention)                           → GPU always fed → the 5–10× throughput
  → near-zero waste → far more                    over naive serving
    concurrent requests per GPU
KNOBS: --gpu-memory-utilization=0.90 (how much VRAM vLLM may claim: weights + KV budget)
       --max-model-len=4096 (KV budget PER REQUEST — halve it ≈ double concurrent capacity)
       quantization (AWQ/GPTQ/fp8): ~½ weight VRAM → the reclaimed space IS extra KV head-room
```

### (C) The two-layer autoscale (pods, then metal)

```
k6 ramps 10→30 VUs
  → vllm:num_requests_waiting climbs past threshold: "5"     (Prometheus, via ServiceMonitor)
  → KEDA ScaledObject scales the Deployment/Rollout 1→2→3    (pods; scaleUp window 0 — fast)
  → each new pod requests nvidia.com/gpu: 1 + tolerates the taint
  → Karpenter buys another spot GPU node (~90s — Climb 1's loop, triggered by Climb 4's signal)
load falls → cooldownPeriod: 300 (GPUs are pricey; scale down deliberately)
  → replicas shrink → nodes empty → 60s consolidation → metal gone
Alternative signals you can defend: gpu_cache_usage_perc > 0.9 (KV pressure), tokens/sec/replica.
```

### (D) The gated canary

```
new rev (e.g. --max-model-len change) → Argo Rollout: setWeight 34% → pause 3m
  → AnalysisTemplate polls: histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[2m]))
  → 3 checks, 1m apart · p95 < 6s ⇒ promote to 100% · any breach ⇒ AUTO-ABORT + rollback
Ops details that make it production-shaped: readinessProbe initialDelay 60s (model load is slow —
your Week-2 probe drills, applied), HF-cache PVC (never re-download weights), /dev/shm emptyDir
(vLLM needs it), --dtype=half (T4 has no bf16 — Climb 2's trap, resurfacing in a flag).
```

> **✅ Check yourself before Rung 4:** (1) Which phase dominates TTFT and which dominates a long answer's total latency — and which is memory-bandwidth-bound? (2) The OS analogy: what plays "page table"? (3) Recite the two-layer scaling chain from k6 ramp to new EC2 node.

---

## RUNG 4 — The Vocabulary Map 🏷️

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Prefill / decode** | Parallel prompt pass / per-token loop | Request anatomy; compute- vs memory-bound |
| **TTFT** | Time to first token (≈ prefill + queue) | The responsiveness SLO |
| **Inter-token latency** | Per-decode-step time | The streaming-speed SLO |
| **KV cache** | Stored K/V vectors of all prior tokens | THE scarce resource |
| **PagedAttention** | KV in on-demand pages + block table | The anti-fragmentation trick |
| **Continuous batching** | Batch re-formed every decode step | The GPU-never-idles trick |
| **`--gpu-memory-utilization`** | VRAM fraction vLLM claims | Weights + KV budget |
| **`--max-model-len`** | Max context = per-request KV budget | The capacity knob |
| **`vllm:num_requests_waiting`** | Queued requests metric | THE scaling signal |
| **`gpu_cache_usage_perc`** | KV-cache pressure | The saturation gauge |
| **KEDA ScaledObject** | Scale on any external metric (Prometheus here) | Pod layer of the autoscale |
| **cooldownPeriod / stabilization** | Scale-down patience / scale-up haste | GPU-priced asymmetry |
| **Argo Rollouts / AnalysisTemplate** | Progressive delivery / metric promotion gate | The canary machinery |
| **OpenAI-compatible API** | `/v1/chat/completions` contract | Why clients swap backends freely |
| **k6** | Load generator (VUs, trends) | The evidence factory |
| **Quantization (AWQ/GPTQ/fp8)** | Lower-precision weights | ½ VRAM → KV head-room → throughput |
| **Tensor parallel** | One model split across N GPUs | The bigger-than-one-card lever |
| **TensorRT-LLM / Triton / TGI / SGLang** | The serving alternatives | One-sentence-each name-drops |

**Same-thing groups:** TTFT/prefill and inter-token/decode = *SLO names for the two phases*. `num_requests_waiting` / `gpu_cache_usage_perc` / tokens-per-sec = *three defensible load signals; CPU is not one*. PagedAttention/virtual memory and block-table/page-table = *the same idea, OS ↔ GPU*.

> **✅ Check yourself before Rung 5:** Which flag trades per-request context for concurrency? Which metric would you alert on at 95% and what does it mean operationally?

---

## RUNG 5 — The Trace 🎬
### *One chat completion, then the platform reacting to thirty of them.*

1. **Request in.** `POST /v1/chat/completions` (the OpenAI contract) → Service → a vLLM pod on Climb 1's tainted spot GPU node — weights already warm off the HF-cache PVC.
2. **Admission.** The engine checks KV head-room (`gpu_cache_usage_perc`); there's room → the request skips the wait queue (`num_requests_waiting` stays 0) and is tokenized.
3. **Prefill.** One parallel pass over the prompt; PagedAttention allocates the first KV *pages*; token #1 emitted — **TTFT ≈ 300ms**, mostly this step (compute-bound; Tensor Cores busy).
4. **Decode, continuously batched.** Each ~tens-of-ms step, the engine advances *every* active sequence one token — this request's decode steps interleave with strangers'. Two other requests finish mid-generation; their KV pages free; **two queued requests join the batch at the very next step**. The GPU never idles.
5. **Stream + account.** Tokens stream back; on finish, KV pages release. Prometheus (via ServiceMonitor) has the whole story: TTFT histogram, e2e histogram, running/waiting, cache %, `rate(generation_tokens_total[1m])`.
6. **Load arrives.** k6 ramps to 30 VUs → the batch saturates → `num_requests_waiting` climbs to 12 → **KEDA** (threshold 5) scales the Rollout 1→3 → two pods Pending → **Karpenter** buys two spot GPU nodes (~90s) → queue drains. Grafana shows the whole causal chain — screenshot it.
7. **A rev ships.** New config → Argo Rollouts sends **34%** of traffic to the canary, pauses 3m, runs the p95 analysis ×3. *Good rev:* promote 100%. *Bad rev (the deliberately broken `gpu-memory-utilization` demo):* p95 breaches once → **auto-abort, rollback** — recorded for the portfolio.
8. **Quiet returns.** VUs → 0; after `cooldownPeriod: 300` replicas → 1; nodes empty → consolidated. The published table (VUs / replicas / tok/s / TTFT p95 / e2e p95 / KV%) *is* the resume bullet's numbers.

> **✅ Check yourself before Rung 6:** At step 4, what exactly lets queued requests start *mid-generation* of others? At step 6, name the two scalers and the exact metric each acted on.

---

## RUNG 6 — The Contrast ⚖️

**vs a normal web service:** stateless request/response, CPU-bound, RPS-meaningful, scale-on-CPU — every one of those flips: token-metered, GPU-memory-bound, KV-stateful per request, scale-on-queue-depth. Same K8s objects, different physics.

**vLLM vs the field (one sentence each, as the project prescribes):** **TensorRT-LLM** — NVIDIA-compiled engines, fastest, least flexible (Climb 2's fusion, productized); **Triton** — multi-framework server with dynamic batching, TRT-LLM's usual home; **TGI** — Hugging Face's server, ecosystem-tight; **SGLang** — fast structured/JSON output. vLLM is the credible open default: PagedAttention + continuous batching + OpenAI API + a first-class metrics surface.

**Queue-depth vs CPU scaling:** CPU measures the wrong resource entirely (Rung 1); queue depth measures *unserved demand*, and KV-cache % measures *why*. **Canary-gated vs time-based rollout:** a pause-only canary detects nothing — the AnalysisTemplate is what converts "wait and hope" into "measure and gate." **When NOT this stack:** tiny/CPU-viable models (a GPU is waste), or fully-managed endpoints (Bedrock) when you're buying outcomes — but these companies *build* the serving layer, which is the point.

**One-sentence why-this-over-that:** vLLM + KEDA-on-queue-depth + Karpenter + p95-gated canaries is the minimum credible production loop because each piece answers the specific way LLM serving breaks a normal web-service playbook — fragmentation, idle GPUs, blind autoscaling, and blind rollouts.

> **✅ Check yourself before Rung 7:** An interviewer says "we autoscale our LLM pods on CPU at 70%." Diagnose what they'll observe under load, and give the two-sentence fix.

---

## RUNG 7 — The Prediction Test 🧪
*Run these as you execute the project's phases — they're its own smoke/load/canary steps, predicted first.*

**P1 — CPU lies, the queue doesn't.** *"Under a 30-VU k6 ramp, the vLLM pod's CPU will sit low (~30%) while `vllm:num_requests_waiting` climbs steadily — because the bottleneck is GPU decode bandwidth and KV space, which CPU metrics can't see."* → Phase 4 with the Grafana row open. This one chart *is* the autoscaling interview answer.

**P2 — The KEDA→Karpenter cascade.** *"When waiting exceeds ~5, KEDA will scale 1→N within its polling interval, the new pods will sit Pending ~90s, then Karpenter delivers spot GPU nodes and the queue drains — because pods scale on the metric and metal scales on the pending pods."* → Phase 2+4; stopwatch both stages; the two numbers go in the README table.

**P3 — `--max-model-len` is a capacity dial.** *"Halving max-model-len (4096→2048) will roughly double sustainable concurrency before `gpu_cache_usage_perc` saturates — because it halves each request's KV budget inside a fixed VRAM pool."* → Re-run the same k6 ramp on both configs; compare waiting/cache curves.

**P4 — The canary catches what I break on purpose.** *"Shipping a rev with absurdly low `--gpu-memory-utilization` will pass health checks but breach the p95 analysis within 3 checks and auto-rollback — because the gate measures the SLO, not liveness."* → Phase 3's deliberate-bad-config demo; record it (portfolio artifact + the STAR story for 'how do you ship models safely').

---

## 🎁 CAPSTONE — Compress It

**One sentence, cold:** *LLM serving is token-metered and KV-cache-bound, so vLLM pages KV memory like an OS (no fragmentation → big batches) and re-forms the batch every decode step (GPU never idles), which makes queue depth — not CPU — the true load signal that KEDA scales pods on while Karpenter scales the metal beneath them, and every release is a canary that Argo Rollouts promotes only if measured p95 stays inside SLO.*

**Beginner, 3 sentences:** An AI model answers one word at a time, and every in-flight conversation reserves scarce GPU memory for its context — so the trick is packing as many conversations onto one GPU as possible without waste. vLLM does that by managing that memory in small pages (like an operating system) and letting new requests slip into the running batch the instant a slot frees. You then scale by watching *how many requests are waiting* (CPU tells you nothing), let the autoscalers add pods and then GPU machines, and roll out changes to a small slice first, promoting only if measured latency stays good.

**Shakiest rung, honestly:** Rung 3B's KV-cache arithmetic (why exactly halving `max-model-len` ≈ doubles concurrency; what quantization's reclaimed VRAM buys). Fix: during Phase 1, compute your T4's numbers on paper — 16GB × 0.90 minus weights = KV pool, ÷ per-request KV at 4096 — then run P3 and check the measured concurrency agrees. When your paper math predicts the k6 result, this rung is yours.

---
---

# 🗺️ The Four Climbs, One Platform

```
            CLIMB 2 (project-16) — READ the GPU
            roofline · dense peaks · Nsight · why fp16/fusion win
                     │ explains prefill/decode boundness, quantization, TensorRT
                     ▼
CLIMB 1 (project-1) — the SUBSTRATE            CLIMB 3 (project-07) — WHO GETS THE GPUs
GPU Operator chain · nvidia.com/gpu ·          scheduler pipeline · Permit gang gate ·
time-slicing/MIG · taints · DCGM ·             topology Score · Kueue/Volcano operated,
Karpenter money loop                           TopoGang built · kwok at 1,000 nodes
                     │                                   (standalone: kind/kwok, ~$0)
                     ▼
            CLIMB 4 (project-2) — SERVE TOKENS OFF IT
            KV cache is the resource · PagedAttention · continuous batching ·
            KEDA on queue depth → Karpenter on metal · p95-gated canaries
```

**One narrative sentence — say this in interviews:** *I built the platform that makes Kubernetes see and share GPUs, learned to read those GPUs down to the roofline, wrote the scheduler logic that decides which jobs get them and where, and served LLM tokens off them with autoscaling and canaries gated on measured latency — four projects, one resource, end to end.*

**Before starting each project, the gate:** you can recite its climb's One Idea cold, walk its Rung-3 diagram from memory, and have its Rung-7 predictions *written down*. Then open the project file — and let every phase confirm or repair the model. That habit — predict, run, reconcile — is the exact opposite of the "prompted recall" your interview transcripts diagnosed, and it's what will make these four projects feel *owned* in a loop rather than followed from a script.
