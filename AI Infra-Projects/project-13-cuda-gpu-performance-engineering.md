# Project 13 — CUDA & GPU Performance Engineering (Infra Engineer's Path)
### 🟩 NVIDIA TRACK 1 of 3 — "understand GPUs and CUDA"

> The LinkedIn post said it: *engineers who understand GPUs and CUDA will run the AI era.* You don't need to become a kernel author — you need to **read GPU performance like an SRE reads a flame graph**: know what CUDA/cuDNN/NCCL are, profile a real workload with **Nsight**, diagnose whether a job is compute/memory/comms-bound, prove the impact of **mixed precision / Tensor Cores / TensorRT**, and speak the hardware fluently (SMs, warps, HBM, roofline). This is the foundation the other two NVIDIA projects stand on.

| | |
|---|---|
| **Difficulty** | Hard |
| **Time** | 3 weekends |
| **Prereq** | Project 1 (a GPU node). Basic Python. |
| **Cloud cost** | 1× `g4dn.xlarge` (T4) spot ≈ $0.16–0.25/hr; a couple hours per session. Tensor-Core comparisons are nicer on `g5` (A10G) ≈ $0.40/hr. Budget < $15. |
| **Skills proven** | CUDA/cuDNN/NCCL stack literacy, Nsight Systems + Nsight Compute profiling, roofline reasoning, occupancy/warp concepts, mixed-precision & Tensor Cores, TensorRT/torch.compile speedups, `nvidia-smi`/DCGM deep read, minimal CUDA kernel authoring |
| **Post/JD mapping** | "understand GPUs, CUDA" (the post) · NVIDIA-cert syllabus: "CUDA, NGC, Nsight, DLProf, TensorRT" · GPU-neocloud JD "CUDA tooling, systems-level configuration for GPU nodes" |

---

## 1. The literacy an infra engineer actually needs

You will be able to explain, cold:

- **The software stack:** your app → framework (PyTorch) → **cuDNN/cuBLAS** (tuned math libs) → **CUDA runtime** → **driver** → GPU. Version compatibility across this stack is the #1 GPU-ops failure (you saw it in P1); now you'll understand *why*.
- **The hardware:** **SM** (streaming multiprocessor) = the core unit; **warp** = 32 threads executing in lockstep; **Tensor Cores** = matrix-multiply-accumulate units (the reason A100≫V100 for AI); **HBM** = high-bandwidth memory; **occupancy** = how well you keep SMs busy.
- **The three bottleneck classes:** compute-bound (SMs saturated — good), **memory-bound** (waiting on HBM — most real kernels), **comms-bound** (waiting on NCCL/PCIe/NVLink — P9's world). **Diagnosing which one** is the entire job.
- **Roofline model:** the mental picture tying arithmetic intensity (FLOPs/byte) to whether you're compute- or memory-limited.

## 2. Phase 1 — Read the stack on a real node

On the GPU node, map the whole thing:

```bash
nvidia-smi                       # driver + CUDA version, GPU, memory, running procs
nvidia-smi -q                    # everything: ECC counts, throttle reasons, power, clocks
nvidia-smi topo -m               # topology: PCIe/NVLink links between GPUs (matters at scale)
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.backends.cudnn.version())"
python -c "import torch; print(torch.cuda.get_device_properties(0))"   # SMs, mem, compute capability
```

Write `docs/gpu-node-anatomy.md`: for *your* T4 — compute capability 7.5, 40 SMs, 16GB GDDR6 @ 320 GB/s, 320 Tensor Cores — and what each number implies for workloads. This is the "systems-level configuration for GPU nodes" the neocloud JD wants, made concrete.

## 3. Phase 2 — Profile a real workload with Nsight Systems

Take the P5 QLoRA fine-tune (or a plain HF training loop) and profile it end-to-end. Run as a Job with Nsight:

```bash
# inside a CUDA devel image with nsight-systems installed
nsys profile -o /out/train_profile -t cuda,cudnn,nvtx,osrt \
  --gpu-metrics-device=all \
  python train_step.py --steps 50
```

Pull the `.nsys-rep` and open in the Nsight Systems GUI (local) or `nsys stats`. Learn to answer from the timeline:

- **GPU busy %** over the step — is the GPU actually working or waiting on the dataloader (CPU)? (The classic finding: input pipeline starves the GPU → fix with more workers / prefetch — a pure *infra* win, no ML.)
- **Kernel vs memcpy vs idle** breakdown — where the time truly goes.
- **NVTX ranges** you add (`torch.cuda.nvtx.range_push("forward")`) to label phases.
- **H2D/D2H transfers** — are you shuffling data over PCIe every step? (pinned memory / `non_blocking=True` fixes.)

Deliverable: a before/after — find one real inefficiency (dataloader starvation is almost guaranteed) and show the GPU-utilization improvement in the profile. **That is GPU performance engineering from the infra seat.**

## 4. Phase 3 — Kernel-level look with Nsight Compute (one kernel deep)

Pick the hottest kernel from Phase 2 and profile *it*:

```bash
ncu --set full -k regex:"gemm|attention" -c 3 -o /out/kernel python train_step.py
```

You're not rewriting it — you're **reading its report**: achieved occupancy, memory throughput vs peak (roofline placement), whether it used **Tensor Cores** (look for `sm__pipe_tensor` activity), warp stall reasons. The skill is saying "this kernel is memory-bound at 70% of peak HBM bandwidth, occupancy-limited by registers" — which tells a team whether a bigger batch, different dtype, or a fused kernel would help.

## 5. Phase 4 — Prove mixed precision & Tensor Cores (measured)

The single biggest "free" GPU speedup. Same model, three configs, `bench/precision_bench.py`:

```python
import torch, time
def bench(dtype, use_amp):
    model = build_model().cuda().to(dtype if not use_amp else torch.float32)
    x = torch.randn(BATCH, SEQ, HID, device="cuda")
    scaler = torch.cuda.amp.GradScaler(enabled=use_amp)
    torch.cuda.synchronize(); t0 = time.perf_counter()
    for _ in range(50):
        with torch.autocast("cuda", dtype=torch.float16, enabled=use_amp):
            loss = model(x).mean()
        scaler.scale(loss).backward(); scaler.step(opt); scaler.update(); opt.zero_grad()
    torch.cuda.synchronize()
    return 50 / (time.perf_counter() - t0)   # steps/sec

# FP32 baseline vs AMP-FP16 vs (on A10G) BF16 — publish steps/s and peak memory
```

| Config | steps/s | peak mem | speedup | notes |
|---|---:|---:|---:|---|
| FP32 | *base* | *base* | 1.0× | no Tensor Cores |
| AMP FP16 | … | … | ~1.5–3× | Tensor Cores engage |
| BF16 (A10G/A100) | … | … | … | no loss-scaling needed |

Explain *why* it's faster (Tensor Cores + half the memory traffic) — the explanation is the interview, the number is the proof.

## 6. Phase 5 — Inference acceleration: TensorRT & torch.compile

Take one model and accelerate inference, measuring each step:

```python
# 1) eager baseline latency
# 2) torch.compile
model_c = torch.compile(model, mode="max-autotune")
# 3) TensorRT (via torch-tensorrt) — kernel fusion + precision calibration
import torch_tensorrt
trt = torch_tensorrt.compile(model, inputs=[...], enabled_precisions={torch.float16})
```

Publish p50/p95 latency and throughput for eager vs compiled vs TensorRT. Tie back to P2/P10: this is *why* TensorRT-LLM exists and when a serving team reaches for it over vanilla vLLM. Add the one-paragraph explanation of **kernel fusion** (fewer kernel launches + less HBM round-tripping = the win).

## 7. Phase 6 — Author one minimal CUDA kernel (demystification)

Not to become a kernel dev — to remove the mystery. Write vector-add and a naive vs tiled matmul, measure the tiling speedup:

```cpp
// vecadd.cu — the "hello world" that makes SMs/threads/blocks concrete
__global__ void vecadd(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;   // thread → element mapping
    if (i < n) c[i] = a[i] + b[i];
}
// launch: vecadd<<<(n+255)/256, 256>>>(...)  ← grid of blocks of threads
```

Then a **tiled matmul** using shared memory, and benchmark naive vs tiled to *feel* why memory locality dominates GPU performance. `nvcc vecadd.cu -o vecadd`; profile with `ncu`. One page: "what I learned about how GPUs execute" — grid/block/thread hierarchy, shared memory as a managed cache, coalesced access, warp divergence. Now every profiler report makes sense.

## 8. Validation checklist

- [ ] `gpu-node-anatomy.md` written from real `nvidia-smi -q` / device properties
- [ ] Nsight Systems profile identifies + fixes a real inefficiency (e.g., dataloader starvation), improvement shown
- [ ] Nsight Compute report read for one hot kernel (occupancy, roofline, Tensor-Core usage)
- [ ] Mixed-precision benchmark table published with the *why*
- [ ] TensorRT/torch.compile inference speedup measured
- [ ] Custom kernel compiled; naive-vs-tiled matmul speedup measured

## 9. Teardown

Pure compute sessions: provision → run scripted benchmarks → destroy. All artifacts are docs/reports/numbers committed to the repo; no standing infra.

## 10. Interview ammunition

- *"Profiled real training and inference on NVIDIA GPUs with Nsight Systems/Compute: diagnosed dataloader starvation and recovered GPU utilization, read kernel-level occupancy and roofline placement, and quantified mixed-precision (Tensor Cores) and TensorRT speedups. Wrote a minimal CUDA matmul to ground the SM/warp/shared-memory model."*
- Whiteboard-ready: the CUDA software stack and its version-compatibility failure mode; compute vs memory vs comms bound and how you *tell*; what Tensor Cores do and why bf16/fp16 wins; roofline in one sketch; kernel fusion; grid/block/thread + why coalescing matters. **Most infra candidates can't do any of this — it's your NVIDIA-era moat.**

## 11. Stretch goals

1. **DCGM + Nsight together**: correlate a fleet-level DCGM utilization dip (P11) with a Nsight-identified kernel stall — bridge cluster metrics to kernel reality.
2. **CUDA Streams** demo: overlap compute and H2D copy; measure the hidden-latency win.
3. **cuDNN autotuning** (`torch.backends.cudnn.benchmark=True`) impact on conv workloads.
4. Profile **NCCL** collectives from P9 with Nsight Systems' NCCL trace — see AllReduce on the timeline.
