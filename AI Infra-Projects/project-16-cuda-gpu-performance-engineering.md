# Project 16 — CUDA & GPU Performance Engineering (the Infra Engineer's Path)

**Difficulty:** ★★★★☆ | **Time:** 3 weekends | **Cost:** < $15 total — 1× `g4dn.xlarge` (T4) spot ≈ $0.16–0.25/hr, a couple of hours per session; Tensor-Core comparisons are nicer on `g5.xlarge` (A10G) ≈ $0.40/hr spot. Pure compute sessions, nothing standing.

**Prereqs:** [P1](project-1-gpu-kubernetes-platform.md) (a GPU node), basic Python. **Skills proven:** CUDA/cuDNN/NCCL stack literacy, Nsight Systems + Nsight Compute profiling, roofline reasoning, occupancy/warp concepts, dense-vs-sparse peak FLOPs (the MFU denominator), mixed precision & Tensor Cores, TensorRT/`torch.compile` speedups, deep `nvidia-smi`/DCGM reads, minimal CUDA kernel authoring. **Post/JD mapping:** *"engineers who understand GPUs and CUDA will run the AI era"* · NVIDIA-cert syllabus: *"CUDA, NGC, Nsight, DLProf, TensorRT"* · GPU-neocloud JD: *"CUDA tooling, systems-level configuration for GPU nodes."*

*You don't need to become a kernel author — you need to **read GPU performance like an SRE reads a flame graph**: know what CUDA/cuDNN/NCCL are, profile a real workload with **Nsight**, diagnose whether a job is compute-, memory-, or comms-bound, prove the impact of **mixed precision / Tensor Cores / TensorRT**, and speak the hardware fluently (SMs, warps, HBM, roofline, dense vs sparse peaks). **This project is numbered last but should be built early — right after [P1](project-1-gpu-kubernetes-platform.md), before the NVIDIA track.** It is the cheapest project in the set (< $15, no cluster) and it makes every other one sharper: [P13](project-13-nvidia-tensorrt-llm-triton-factory.md)'s Phase 0 hands you an `nsys` command and assumes you can *read* the trace it produces; [P10](project-10-fault-tolerant-training-goodput.md)'s MFU math assumes you know which peak-FLOPs number goes in the denominator; [P09](project-09-disaggregated-inference-llm-d.md) and [P14](project-14-nvidia-dynamo-inference-os.md) assume you know why kernel fusion and paged KV cache are wins. It is numbered 16 only so the portfolio reads "CUDA" explicitly as a standalone line item.*

---

## 1. The literacy an infra engineer actually needs

You will be able to explain, cold:

- **The software stack:** your app → framework (PyTorch) → **cuDNN/cuBLAS** (tuned math libs) → **CUDA runtime** → **driver** → GPU. Version compatibility across this stack is the #1 GPU-ops failure (you saw it in [P1](project-1-gpu-kubernetes-platform.md)); now you'll understand *why*.
- **The hardware:** **SM** (streaming multiprocessor) = the core unit; **warp** = 32 threads executing in lockstep; **Tensor Cores** = matrix-multiply-accumulate units (the reason A100 ≫ V100 for AI); **HBM/GDDR** = the GPU's memory and its bandwidth ceiling; **occupancy** = how well you keep SMs busy.
- **The three bottleneck classes:** compute-bound (SMs saturated — good), **memory-bound** (waiting on memory — most real kernels), **comms-bound** (waiting on NCCL/PCIe/NVLink — [P10](project-10-fault-tolerant-training-goodput.md)'s and [P15](project-15-nvidia-networking-nccl-cluster-validation.md)'s world). **Diagnosing which one** is the entire job.
- **Roofline model:** the mental picture tying arithmetic intensity (FLOPs/byte) to whether you're compute- or memory-limited — and the *dense* peak-FLOPs number that anchors it.

## 2. Phase 1 — Read the stack on a real node

On the GPU node, map the whole thing:

```bash
nvidia-smi                       # driver + CUDA version, GPU, memory, running procs
nvidia-smi -q                    # everything: ECC counts, throttle reasons, power, clocks
nvidia-smi topo -m               # topology: PCIe/NVLink links between GPUs (matters at scale)
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.backends.cudnn.version())"
python -c "import torch; print(torch.cuda.get_device_properties(0))"   # SMs, mem, compute capability
```

Write `docs/gpu-node-anatomy.md`: for *your* T4 — compute capability 7.5 (Turing), 40 SMs, 320 Tensor Cores, 16 GB GDDR6 @ **300 GB/s** — and what each number implies for workloads. This is the "systems-level configuration for GPU nodes" the neocloud JD wants, made concrete.

### 2a. The one number everything else divides by: the **dense** peak

Every roofline, every speedup claim, and every MFU number in [P10](project-10-fault-tolerant-training-goodput.md) has a peak-FLOPs denominator. Get it wrong and your whole analysis is off by 2×. Datasheet values (verified against NVIDIA/AWS primary sources, July 2026 — re-check when you move to a new SKU):

| GPU (instance) | Dense FP16/BF16 tensor peak | Memory BW | Ridge point (peak ÷ BW) | The trap |
|---|---:|---:|---:|---|
| **T4** (`g4dn`) | **65 TFLOPS** FP16 | 300 GB/s | ≈ 217 FLOPs/byte | Turing has **no BF16 tensor support and no sparsity mode at all** — there is no 2× figure to be fooled by, and no BF16 row in your Phase 4 table |
| **A10G** (`g5`) | **70 TFLOPS** | 600 GB/s | ≈ 117 FLOPs/byte | The widely quoted **~125 TFLOPS is the *A10*'s dense number — a different SKU.** The A10G's own figures are 70 dense / 140 sparse. Third-party spec pages (and even AWS's own G5 page, which advertises "up to 250 TOPS" — that's the A10's dense INT8) copy A10 numbers onto the A10G |
| **L4** (`g6`) | **121 TFLOPS** | 300 GB/s | ≈ 403 FLOPs/byte | NVIDIA's L4 sheet prints **sparse-first**: the headline "242 TFLOPS" is the *sparse* number, footnoted "one-half lower without sparsity." Opposite presentation from the A100/A10/A10G sheets, which print `dense \| sparse*` |
| **A100** SXM/PCIe, 40 & 80 GB (`p4d`) | **312 TFLOPS** | 1.55–2.04 TB/s | ≈ 153–201 FLOPs/byte | 624 is the sparse figure. Same compute column for 40 GB and 80 GB, SXM and PCIe — only memory, bandwidth and TDP differ |

The 2× "with sparsity" numbers require **2:4 structured-sparsity weights**, which essentially no standard training or inference workload uses. They must never appear in a roofline or an MFU denominator — that's the PaLM-paper convention ([arXiv:2204.02311](https://arxiv.org/abs/2204.02311)), which uses A100's **312** dense matmul TFLOP/s in its worked Megatron-Turing example, not 624. Write the correct dense peak for your GPU into `gpu-node-anatomy.md` on day one; you will divide by it in Phases 3, 4, 5 and 6, and again in [P10](project-10-fault-tolerant-training-goodput.md) and [P13](project-13-nvidia-tensorrt-llm-triton-factory.md).

**Ridge point** = dense peak ÷ memory bandwidth = the arithmetic intensity at which a kernel *stops* being memory-bound. On a T4 that's ~217 FLOPs/byte, which is brutally high: almost everything that isn't a big GEMM lives on the memory roof. That single number explains most of what the profiler is about to tell you.

## 3. Phase 2 — Profile a real workload with Nsight Systems

Take the [P5](project-5-distributed-training-platform.md) QLoRA fine-tune (or a plain HF training loop) and profile it end-to-end. Run as a Job with Nsight:

```bash
# inside a CUDA devel image with nsight-systems installed
nsys profile -o /out/train_profile -t cuda,cudnn,nvtx,osrt \
  --gpu-metrics-device=all \
  python train_step.py --steps 50
```

Pull the `.nsys-rep` and open it in the Nsight Systems GUI (local) or run `nsys stats`. Learn to answer from the timeline:

- **GPU busy %** over the step — is the GPU actually working, or waiting on the dataloader (CPU)? (The classic finding: input pipeline starves the GPU → fix with more workers / prefetch — a pure *infra* win, no ML.)
- **Kernel vs memcpy vs idle** breakdown — where the time truly goes.
- **NVTX ranges** you add (`torch.cuda.nvtx.range_push("forward")`) to label phases.
- **H2D/D2H transfers** — are you shuffling data over PCIe every step? (pinned memory / `non_blocking=True` fixes.)

Deliverable: a before/after — find one real inefficiency (dataloader starvation is almost guaranteed) and show the GPU-utilization improvement in the profile. **That is GPU performance engineering from the infra seat.** This is exactly the trace-reading skill [P13](project-13-nvidia-tensorrt-llm-triton-factory.md)'s Phase 0 assumes you already have when it asks you to baseline a serving process before optimizing it.

## 4. Phase 3 — Kernel-level look with Nsight Compute (one kernel deep)

Pick the hottest kernel from Phase 2 and profile *it*:

```bash
ncu --set full -k regex:"gemm|attention" -c 3 -o /out/kernel python train_step.py
# roofline chart + memory-workload analysis, without the full (slow) set:
ncu --set roofline -k regex:"gemm" -c 3 -o /out/kernel_roofline python train_step.py
```

You're not rewriting it — you're **reading its report**: achieved occupancy, memory throughput vs peak (roofline placement), whether it used **Tensor Cores** (look for `sm__pipe_tensor` activity), warp stall reasons. The skill is saying "this kernel is memory-bound at 70 % of peak bandwidth, occupancy-limited by registers" — which tells a team whether a bigger batch, a different dtype, or a fused kernel would help.

### 4a. Place the kernel on the roofline yourself

Don't just accept `ncu`'s chart — reproduce it by hand once, and it will never be mysterious again:

1. **Arithmetic intensity** = FLOPs ÷ bytes moved. `ncu` gives you both (`sm__sass_thread_inst_executed_op_*` / `dram__bytes.sum`), or you can derive them analytically for a kernel you understand.
2. Compare AI to the **ridge point** from §2a. Below it → memory-bound: your ceiling is `AI × bandwidth`, and no amount of extra FLOPs capability helps. Above it → compute-bound: your ceiling is the **dense** peak.
3. State the verdict in one sentence, with the two numbers that justify it. That sentence is the interview.

A worked expectation to check yourself against: an attention or element-wise kernel typically lands at single-digit FLOPs/byte on a ridge point of ~117–217 → *memory-bound by an order of magnitude or more*. A large FP16 GEMM with Tensor Cores engaged is the one thing that gets near the compute roof. This is why fusion (Phase 5) and dtype (Phase 4) are the two levers that actually move the needle.

## 5. Phase 4 — Prove mixed precision & Tensor Cores (measured)

The single biggest "free" GPU speedup. Same model, three configs, `bench/precision_bench.py`:

```python
import torch, time

def bench(dtype, use_amp):
    model = build_model().cuda().to(dtype if not use_amp else torch.float32)
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    x = torch.randn(BATCH, SEQ, HID, device="cuda")
    scaler = torch.amp.GradScaler("cuda", enabled=use_amp)   # torch.cuda.amp.* is the deprecated spelling
    torch.cuda.synchronize(); t0 = time.perf_counter()
    for _ in range(50):
        with torch.autocast("cuda", dtype=torch.float16, enabled=use_amp):
            loss = model(x).mean()
        scaler.scale(loss).backward(); scaler.step(opt); scaler.update(); opt.zero_grad()
    torch.cuda.synchronize()
    return 50 / (time.perf_counter() - t0)   # steps/sec
```

Warm up before you time (the first iterations pay autotuning and allocator costs), and record `torch.cuda.max_memory_allocated()` per config.

| Config | steps/s | peak mem | speedup | notes |
|---|---:|---:|---:|---|
| FP32 | *base* | *base* | 1.0× | no Tensor Cores |
| AMP FP16 | *measured* | *measured* | ~1.5–3× typical | Tensor Cores engage; loss-scaling required |
| BF16 (A10G/L4/A100 only) | *measured* | *measured* | *measured* | no loss-scaling needed — **not available on T4**: Turing Tensor Cores have no BF16 path |
| TF32 on/off (Ampere+) | *measured* | *measured* | *measured* | `torch.backends.cuda.matmul.allow_tf32` — a one-line "free" matmul win people forget |

Explain *why* it's faster (Tensor Cores + half the memory traffic) — the explanation is the interview, the number is the proof. Then close the loop with §2a: convert your best steps/s into achieved TFLOPS and divide by the **dense** peak (70 on A10G, 65 on T4, 121 on L4, 312 on A100). That fraction is the same quantity [P10](project-10-fault-tolerant-training-goodput.md) calls **MFU** — and quoting a sparse peak (or an A10 number on an A10G) is the single most common way people report an MFU that is silently ~2× too flattering. If you also report **HFU**: model FLOPs exclude activation recomputation, which counts only toward HFU (PaLM 540B: 46.2 % MFU vs 57.8 % HFU); per-token model FLOPs = `6N + 12·L·H·Q·T`.

## 6. Phase 5 — Inference acceleration: TensorRT & `torch.compile`

Take one model and accelerate inference, measuring each step:

```python
# 1) eager baseline latency
# 2) torch.compile
model_c = torch.compile(model, mode="max-autotune")
# 3) TensorRT (via torch-tensorrt) — kernel fusion + precision calibration
import torch_tensorrt
trt = torch_tensorrt.compile(model, inputs=[...], enabled_precisions={torch.float16})
```

Pin your `torch` / `torch-tensorrt` / TensorRT versions together (they move as a set — check the support matrix for your release, this is the same ABI-matching discipline as [P13](project-13-nvidia-tensorrt-llm-triton-factory.md)'s TRT-LLM ↔ Triton container pairing).

Publish p50/p95 latency and throughput for eager vs compiled vs TensorRT, and re-run `nsys` on each so the win is **attributed** rather than asserted — you should literally see the kernel count drop. Add the one-paragraph explanation of **kernel fusion** (fewer kernel launches + less memory round-tripping = the win: fusion raises arithmetic intensity, which on a memory-bound kernel is the *only* thing that moves it right on the roofline).

Tie it back: this is *why* TensorRT-LLM ([P13](project-13-nvidia-tensorrt-llm-triton-factory.md)) exists and when a serving team reaches for it over vanilla vLLM ([P2](project-2-llm-inference-platform.md)), and why the disaggregation/gateway work in [P09](project-09-disaggregated-inference-llm-d.md) and [P14](project-14-nvidia-dynamo-inference-os.md) is stacked *on top of* an already-optimized kernel path rather than instead of one.

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

`nvcc vecadd.cu -o vecadd`; profile with `ncu`. **Do the roofline math on it before you run it**: per element you move 12 bytes (two 4-byte loads + one 4-byte store) and do 1 FLOP → arithmetic intensity ≈ **0.083 FLOPs/byte**, against a T4 ridge point of ~217. So it is memory-bound by ~2,600×, and the right success metric is not FLOPS at all — it's **achieved bandwidth** (`12 × n ÷ time`) as a fraction of 300 GB/s. When your first kernel hits ~1/2,600th of "peak FLOPS", you'll know that's not a bug — it's the roofline, and you predicted it.

Then a **tiled matmul** using shared memory, and benchmark naive vs tiled. Naive matmul reads two 4-byte operands per multiply-add (2 FLOPs) → AI ≈ 0.25 FLOPs/byte. Tiling with a `T×T` shared-memory tile reuses each loaded element `T` times → AI ≈ `0.25 × T` (≈ 8 FLOPs/byte at `T = 32`): still under the ridge point, but ~32× further up the memory roof. Measure it and you *feel* why memory locality dominates GPU performance — and why cuBLAS, which does this plus Tensor Cores plus register-level blocking, will still beat you by a wide margin. Compare against `torch.matmul` on the same shapes; being beaten by the tuned library **is** the lesson.

One page: "what I learned about how GPUs execute" — grid/block/thread hierarchy, shared memory as a managed cache, coalesced access, warp divergence, occupancy. Now every profiler report makes sense.

## 8. Done criteria & interview ammo

- [ ] `docs/gpu-node-anatomy.md` written from real `nvidia-smi -q` / device properties, including the **dense** tensor peak, memory bandwidth, and computed ridge point for your GPU
- [ ] The dense-vs-sparse table reproduced and the A10 ↔ A10G confusion documented in your own words
- [ ] Nsight Systems profile identifies **and fixes** a real inefficiency (e.g., dataloader starvation), improvement shown in a before/after timeline
- [ ] Nsight Compute report read for one hot kernel (occupancy, roofline placement, Tensor-Core usage) — and its roofline position reproduced by hand
- [ ] Mixed-precision benchmark table published with the *why*, plus the achieved-TFLOPS-over-dense-peak fraction
- [ ] TensorRT / `torch.compile` inference speedup measured and re-profiled with `nsys` (kernel count drop visible)
- [ ] Custom kernel compiled; vecadd scored as **bandwidth**, not FLOPS; naive-vs-tiled matmul speedup measured and explained by arithmetic intensity

Whiteboard-ready: the CUDA software stack and its version-compatibility failure mode; compute vs memory vs comms bound and how you *tell*; what Tensor Cores do and why bf16/fp16 wins; roofline and the ridge point in one sketch; why the MFU/roofline denominator is the **dense** peak and what breaks when someone quotes the sparse one; kernel fusion as an arithmetic-intensity move; grid/block/thread and why coalescing matters. **Most infra candidates can't do any of this — it's your NVIDIA-era moat.**

**Resume bullet:** *"Profiled real training and inference on NVIDIA GPUs with Nsight Systems/Compute: diagnosed dataloader starvation and recovered GPU utilization, read kernel-level occupancy and roofline placement against the correct dense tensor peak (70 TFLOPS on A10G, not the widely miscopied A10 figure), and quantified mixed-precision (Tensor Cores), `torch.compile` and TensorRT speedups with before/after kernel traces. Wrote a minimal CUDA vector-add and tiled matmul to ground the SM/warp/shared-memory model and validate the roofline analytically."*

## 9. Teardown

Pure compute sessions: provision → run scripted benchmarks → destroy the instance the moment the numbers are captured. All artifacts are docs, profiles, reports and numbers committed to the repo; **no standing infra**, no cluster, no idle GPU. Set a billing alarm anyway — a forgotten `g5` is $290/month.

## 10. Extensions

1. **DCGM + Nsight together:** correlate a fleet-level DCGM utilization dip ([P12](project-12-ai-fleet-sre-finops-aiops.md)) with an Nsight-identified kernel stall — bridge cluster metrics to kernel reality. This is the single most senior-sounding demo in the whole portfolio.
2. **CUDA Streams demo:** overlap compute and H2D copy; measure the hidden-latency win — and connect it to why MPS/time-slicing ([P08](project-08-fractional-gpu-dra-multitenancy.md)) raises utilization for small kernels that can't fill the SMs alone.
3. **cuDNN autotuning** (`torch.backends.cudnn.benchmark = True`) impact on conv workloads; measure the first-iteration cost vs steady-state win.
4. **Profile NCCL collectives** from [P10](project-10-fault-tolerant-training-goodput.md) / [P15](project-15-nvidia-networking-nccl-cluster-validation.md) with Nsight Systems' NCCL trace — see AllReduce on the timeline and watch compute/comms overlap (or fail to).
5. **Triton (OpenAI) kernel** as the modern alternative to hand-written CUDA: rewrite the tiled matmul in `triton.jit` and compare LOC and performance. Note the name collision with NVIDIA's Triton *Inference Server* ([P13](project-13-nvidia-tensorrt-llm-triton-factory.md)) — knowing the two are unrelated is itself a small signal.

## 📣 Build in public

- **LinkedIn:** post the dense-vs-sparse peak table with the A10G call-out — *"your MFU is probably 2× too good, and here's why: the ~125 TFLOPS everyone quotes for the A10G belongs to the A10, a different SKU. The A10G's datasheet says 70 dense / 140 sparse, and the PaLM convention says the denominator is dense."* Close with your own measured achieved-TFLOPS-over-70 figure from Phase 4 and the two-line correction to make in their dashboard. It's a correction, not an opinion — those travel.
- **X/Twitter thread:** the vecadd roofline story with receipts — *"I wrote my first CUDA kernel and it hit ~0.04 % of the GPU's peak FLOPS. That's not a bug, it's arithmetic intensity: 1 FLOP per 12 bytes against a ridge point of 217 FLOPs/byte — the memory roof caps it at ~25 GFLOP/s no matter what."* Post the hand calculation, then the `ncu` roofline chart that agrees with it, then the tiled-matmul number showing the ~32× arithmetic-intensity jump from shared memory. One tweet per rung of the ladder.
- **YouTube:** a 10-minute screen recording titled *"I found the bottleneck in a fine-tune without reading a line of ML code."* Open on the Nsight Systems timeline with the GPU idle-gapped by the dataloader, narrate the fix (workers + prefetch + pinned memory), show the after-timeline with the gaps closed and the measured GPU-utilization delta — then jump to Nsight Compute on the hottest kernel and read its occupancy and roofline placement out loud. Same GPU, same model, no ML changed: pure infra.
