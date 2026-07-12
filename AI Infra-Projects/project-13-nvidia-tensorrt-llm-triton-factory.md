# Project 13 — Forge: A TensorRT-LLM + Triton Model Optimization Factory (NVIDIA 1/3)

**Difficulty:** ★★★★☆ | **Time:** 3–4 weekends | **Cost:** ~$15–35 (g5/g6 spot; engines build on the same GPU that serves them; NGC registration free; NIM developer tier free)

*NVIDIA doesn't just sell GPUs — it ships the software factory that runs them: **TensorRT-LLM** (the LLM compiler/runtime), **Triton Inference Server** (the general-purpose server, now branded **Dynamo-Triton**), **NIM microservices** (that factory prepackaged and licensed), and the **NGC** catalog they all pull from. Here you build the optimization factory yourself — quantize, serve, benchmark, canary — then deploy NVIDIA's prepackaged version of it (NIM), compare both honestly against your open-source vLLM baseline, and Nsight-profile every rung so the speedups are attributed, not asserted.*

## 1. The production problem

Serving raw HuggingFace weights with a generic runtime leaves 2–4× throughput on the table. Inference performance teams run a **model optimization factory**: weights go in; quantized, compiled, benchmarked, *versioned* serving artifacts come out; a canary system promotes them only if latency/quality SLOs hold. NVIDIA's stack for this is **TensorRT-LLM** (fused kernels, paged KV cache, in-flight batching, FP8/INT4 quantization), served via its OpenAI-compatible **`trtllm-serve`** frontend or through **Triton** (the `tensorrtllm` backend). This is where GPU-architecture knowledge turns practical: you finally *use* the difference between Ampere, Ada and Hopper.

Hard-won facts to internalize up front:
- **The ground moved in 2025 — know both lanes.** Since TensorRT-LLM 1.0 (GA, Sept 2025) the **PyTorch runtime is the default backend**, and the recommended path is `trtllm-serve <HF model>` (online, OpenAI-compatible: completions/chat/responses) or the Python **LLM API** (offline) — *no engine compilation required*. Manual engine building (`trtllm-build`) is the documented **legacy** path; the v1.3.0 release candidates state it's the *last* line supporting the TensorRT engine backend, removed in the next version. As of July 2026: TRT-LLM v1.2.1 stable, v1.3.0 in RC — pin your release and re-check upstream, this moves monthly. Run both lanes anyway: real fleets still serve engine-based stacks, and the migration story is interview gold.
- **Engines are GPU-architecture-specific** (legacy lane). An engine built on A10G (SM86, Ampere) won't run on L4 (SM89, Ada) or H100 (SM90, Hopper) — production means a build **matrix** per architecture. The PyTorch backend removes the ahead-of-time engine, but the concern doesn't vanish: NIM (Phase 4) still selects per-GPU optimized *profiles*.
- **Quantization is architecture-gated.** FP8 needs Ada/Hopper tensor cores (L4/L40S/H100). On A10G you use INT8 SmoothQuant or **INT4-AWQ**. Knowing this instantly separates you from tutorial-followers.
- **Version pinning matters.** The Triton `tensorrtllm` backend source was consolidated *into* the TensorRT-LLM repo (`triton_backend/`); the old `tensorrtllm_backend` repo remains the integration/docs entry point (container tags around 25.12 as of mid-2026). It is neither deprecated nor independently developed — it's consolidated. Match TRT-LLM release ↔ Triton container like an ABI, and note the engine-based Triton flow is end-of-life once 1.3 drops the TensorRT engine backend.

Where each rung sits (and where this project's siblings pick up):

```
NGC catalog ──► optimized containers & models (Triton, TensorRT-LLM, NIM)
     │
     ├── TensorRT-LLM ──► compiler/runtime: fused kernels, paged KV, quant, in-flight batching
     │                        │ served by trtllm-serve (default) or ▼
     ├── Triton (Dynamo-Triton) ──► general-purpose server: any framework, dynamic batching, ensembles
     │
     ├── NIM ──► TRT-LLM + serving + OpenAI API prepackaged as ONE licensed microservice  (Phase 4)
     │
     └── Dynamo ──► datacenter-scale disaggregated serving, KV-aware routing   (→ P14)
```

Triton was renamed **Dynamo-Triton** when Dynamo launched; it lives on as the actively-released general-purpose per-node server (v2.70.0, June 2026) for TensorRT/PyTorch/ONNX/OpenVINO/Python/FIL workloads, while **Dynamo succeeds it for datacenter-scale LLM serving** — Dynamo workers run vLLM/SGLang/TRT-LLM engines directly, *not* Triton. That layer is [P14](project-14-nvidia-dynamo-inference-os.md); this project is the per-node factory underneath it.

## 2. Architecture

```
 HF weights ─▶ [1] quantize (Model Optimizer: INT4-AWQ | FP8) → quantized checkpoint
            ─▶ [2a] Lane A (default): trtllm-serve, PyTorch backend — no engine build
            ─▶ [2b] Lane B (legacy, ≤1.2.x): convert_checkpoint → trtllm-build → engine (per arch)
            ─▶ [3] push to S3 "artifact registry" (s3://engines/llama31-8b/awq/sm86/v3/)
            ─▶ [4] serve: trtllm-serve (A) | Triton in-flight batching (B) | NIM (vendor)
            ─▶ [5] K8s Deployment ── aiperf gate ── Argo Rollouts canary
 GitHub Actions runs 1–4 on a self-hosted GPU runner; 5 is GitOps (ArgoCD)
 Phase 0 Nsight baseline ──────────── re-profiled in Phase 3 to attribute the speedup
```

## 3. Phase 0 — profile before you optimize (Nsight baseline)

Before building anything faster, capture what "slow" looks like — otherwise your Phase 3 table is a number without a cause. Serve your FP16 vLLM baseline (P02) on the g5.2xlarge, put steady load on it, and trace the server:

```bash
# 60 s Nsight Systems window over the serving process while a client drives load
nsys profile -o /ws/nsys/vllm-baseline --duration 60 --force-overwrite true \
  -t cuda,nvtx,osrt \
  python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-3.1-8B-Instruct
# in another shell: aiperf against it (same command as Phase 3) so the trace is under real load
```

Record three things: the **kernel mix** of a decode step (GEMM vs attention vs elementwise/memcpy), the **gaps** between kernels (launch overhead, CPU-side stalls), and achieved tensor throughput vs the hardware peak. For that last one use the *dense* peak: **A10G = 70 TFLOPS dense FP16/BF16** (official AWS/NVIDIA datasheet; 140 TF with 2:4 sparsity — the ~125 TFLOPS figure floating around is the NVIDIA *A10*'s dense number, a different SKU that third-party spec pages and even AWS's own G5 page conflate with the A10G); **L4 = 121 dense** (NVIDIA's L4 sheet prints 242 sparse-first, footnoted "one-half lower without sparsity"); A100 = 312 dense. Never put a 2:4-sparsity figure in a utilization denominator — no standard inference workload uses structured-sparse weights, and the PaLM/MFU convention is the dense peak.

The full CUDA treatment — Nsight Compute per-kernel analysis, roofline placement, occupancy, writing your own kernels — is [P16](project-16-cuda-gpu-performance-engineering.md), recommended early in the track (right after P1) for exactly this reason. Here you need only the baseline trace and the decode-step kernel mix, because **Phase 3 re-profiles the optimized paths against it** to attribute where the speedup comes from.

Deliverable: `docs/phase0-baseline.md` — trace screenshots, kernel-mix table, achieved-vs-70-TFLOPS ratio.

## 4. Phase 1 — quantize + build (Llama-3.1-8B on a g5.2xlarge)

### Lane A — the current recommended path (PyTorch backend, no engine build)

```bash
pip install tensorrt-llm        # pin your release; v1.2.1 stable as of Jul 2026
# serve any HF model directly, OpenAI-compatible (completions/chat/responses):
trtllm-serve meta-llama/Llama-3.1-8B-Instruct --host 0.0.0.0 --port 8000
```

```python
# offline path — the stable LLM API (PyTorch backend by default since v1.0)
from tensorrt_llm import LLM, SamplingParams
llm = LLM(model="meta-llama/Llama-3.1-8B-Instruct")
print(llm.generate(["The capital of France is"], SamplingParams(max_tokens=32)))
```

Quantization on this lane: build a quantized checkpoint with **NVIDIA Model Optimizer** (`nvidia-modelopt` — its PTQ workflow exports a quantized HF-format checkpoint `trtllm-serve` loads directly), or pull a pre-quantized checkpoint from HF (the `nvidia/*-FP8` series — FP8 only on g6/L4 or Hopper; on A10G stick to INT4-AWQ/INT8). ModelOpt flags shift between releases — pin, and read the examples in your installed version.

### Lane B — the legacy engine flow (pin TRT-LLM ≤1.2.x; removed in 1.3)

Worth two builds: an FP16 engine (so the benchmark has an apples-to-apples "engine, no quant" row) and a quantized one. Engine-based stacks are widely deployed, and this is where the per-arch matrix lesson lives. Use the matching NGC container so CUDA/TRT versions are coherent:

```bash
docker run --gpus all -it -v $PWD:/ws nvcr.io/nvidia/tritonserver:<yy.mm>-trtllm-python-py3
# inside: TensorRT-LLM examples are under /app or pip-installed — check the release notes

# (a) HF checkpoint → TRT-LLM checkpoint (the FP16 control build)
python convert_checkpoint.py --model_dir /ws/Llama-3.1-8B-Instruct \
  --dtype float16 --output_dir /ws/ckpt-fp16

# (b) Quantize — INT4-AWQ (Ampere-safe). On g6/L4 or H100, use --qformat fp8.
python examples/quantization/quantize.py \
  --model_dir /ws/Llama-3.1-8B-Instruct \
  --qformat int4_awq --awq_block_size 128 \
  --kv_cache_dtype int8 \
  --output_dir /ws/ckpt-awq --calib_size 512

# (c) Compile each checkpoint into an SM86 engine
trtllm-build --checkpoint_dir /ws/ckpt-awq --output_dir /ws/engine-sm86-awq \
  --gemm_plugin auto \
  --max_batch_size 64 --max_input_len 4096 --max_seq_len 8192 \
  --kv_cache_type paged --use_paged_context_fmha enable \
  --multiple_profiles enable
```

Record engine size, build time, and (crucially) a **quality check**: a small eval (200 MMLU-lite prompts, or perplexity on a held-out set) FP16 vs AWQ. Quantization without a quality gate is malpractice — say that sentence in interviews.

## 5. Phase 2 — Triton: dynamic batching, then the LLM ensemble

### Warm-up — Triton fundamentals with a non-LLM model

Register for NGC (free), get an API key, pull the Triton container. Triton serves *any* framework via **backends** (TensorRT, PyTorch, ONNX, OpenVINO, Python, vLLM, TensorRT-LLM). Learn the **model repository** layout with a small ONNX model first:

```
model_repository/
└── my_model/
    ├── config.pbtxt          # backend, batching, instances, inputs/outputs
    └── 1/ model.onnx
```

```protobuf
# config.pbtxt — the dynamic-batching demo
platform: "onnxruntime_onnx"
max_batch_size: 32
dynamic_batching {
  preferred_batch_size: [ 8, 16 ]
  max_queue_delay_microseconds: 5000     # wait up to 5ms to fill a batch
}
instance_group [ { count: 2, kind: KIND_GPU } ]
```

```yaml
containers:
  - name: triton
    image: nvcr.io/nvidia/tritonserver:25.12-py3   # pin the current yy.mm release
    args: ["tritonserver", "--model-repository=/models", "--metrics-port=8002"]
    ports: [{ containerPort: 8000 }, { containerPort: 8001 }, { containerPort: 8002 }]  # HTTP/gRPC/metrics
    resources: { limits: { nvidia.com/gpu: 1 } }
```

Two primitives to be able to explain: **dynamic batching** (server-side request coalescing — the general-purpose ancestor of LLM continuous batching; measure throughput at fixed p95 vs `max_queue_delay`) and **concurrent model execution** (`instance_group` count — N copies sharing one GPU, the crude ancestor of [P08](project-08-fractional-gpu-dra-multitenancy.md)'s fractional-GPU work). Wire `nv_inference_queue_duration_us` / `nv_gpu_utilization` into [P12](project-12-ai-fleet-sre-finops-aiops.md)'s Grafana.

### The LLM ensemble (in-flight batching)

```
model_repo/
├── ensemble/config.pbtxt            # ties the three below into one endpoint
├── preprocessing/                   # python backend: tokenizer
├── tensorrt_llm/config.pbtxt        # the engine (Lane B) or PyTorch-backend model (Lane A)
└── postprocessing/                  # python backend: detokenizer
```

The parts of `tensorrt_llm/config.pbtxt` that matter:

```
backend: "tensorrtllm"
max_batch_size: 64
model_transaction_policy { decoupled: true }        # streaming tokens
parameters { key: "gpt_model_type"  value: { string_value: "inflight_fused_batching" } }
parameters { key: "gpt_model_path"  value: { string_value: "/engines/sm86/v3" } }
parameters { key: "batch_scheduler_policy" value: { string_value: "max_utilization" } }
parameters { key: "kv_cache_free_gpu_mem_fraction" value: { string_value: "0.90" } }
parameters { key: "enable_chunked_context" value: { string_value: "true" } }
```

Two flags to be able to *explain*: `inflight_fused_batching` = continuous batching at the Triton layer (requests join/leave a running batch per step — the single biggest LLM-throughput idea of the last few years); `enable_chunked_context` = long prefills sliced so they don't stall decoding (the intra-engine cousin of [P09](project-09-disaggregated-inference-llm-d.md)'s disaggregation). The backend's README now leads with the PyTorch path ("serve any HF model — no engine compilation required"); the config above is the classic flow, valid on ≤1.2.x containers.

K8s Deployment: `tritonserver --model-repository=s3://engines/llama31-8b/... --model-control-mode=explicit`, readiness on `/v2/health/ready`, `nvidia.com/gpu: 1`, `nv_trt_llm_kv_cache_block_metrics` scraped into P12. Prefer the OpenAI-compatible frontend (recent Triton releases ship one) so [P09](project-09-disaggregated-inference-llm-d.md)'s gateway routes to it unchanged.

## 6. Phase 3 — benchmark honestly (AIPerf + Model Analyzer), then attribute

Get the tooling story straight first — a fresh interview differentiator (July 2026): **genai-perf is deprecated** (the `perf_analyzer` repo carries the notice and migration path) in favor of **AIPerf** (`ai-dynamo/aiperf`), the NVIDIA-recommended generative-AI benchmarking client and the one Dynamo's guides use. **Model Analyzer is NOT deprecated** — v1.55.0 shipped June 2026 in lockstep with Triton v2.70.0 — and it does a *different* job: server-side Triton config search, not client-side LLM load generation. Anyone who says "model-analyzer was replaced by genai-perf" has both halves wrong; the truth is the reverse.

**Methodology** — fix these before recording a single row, and state them atop the results doc: **fixed ISL/OSL** (~800 in / ~200 out, identical across every path — change the shape and you change the winner); **warm up, then measure** (discard the first N requests: CUDA-graph warm-up, KV allocator settling); **sweep concurrency** 1/4/16/64 (one number is a marketing claim, a curve is a result); report **TTFT and TPOT separately** (a single "latency" figure hides which one you broke); **p50 and p99, not means**; **load generator off the GPU node**; **same client for every server** — they all speak OpenAI-compatible, so keep it constant.

### Client-side: AIPerf

```bash
pip install aiperf
aiperf profile -m ensemble --url http://triton:9000 --endpoint-type chat \
  --streaming --request-count 200 --concurrency 64 \
  --synthetic-input-tokens-mean 800 --output-tokens-mean 200
# flags track genai-perf's; sweep concurrency 1,4,16,64 — check `aiperf profile --help` on your version
```

Run it against every frontend (vLLM, `trtllm-serve`, Triton, NIM) and produce THE table — × concurrency → TTFT p50/p99, TPOT p50/p99, tokens/s/GPU, plus your quality-eval delta, $/1M tokens (from [P12](project-12-ai-fleet-sre-finops-aiops.md)'s pricing), and the two columns most benchmarks omit:

| Serving path | tokens/s/GPU | TTFT p99 | TPOT p99 | quality Δ | $/1M tok | build effort | flexibility |
|---|---:|---:|---:|---:|---:|---|---|
| vLLM FP16 (P02) | *base* | … | … | 0 | … | none | high |
| TRT-LLM FP16 (`trtllm-serve`) | … | … | … | 0 | … | pip install | high |
| TRT-LLM FP16 (engine, Lane B) | … | … | … | 0 | … | per model × GPU arch | lower |
| TRT-LLM AWQ (engine, Lane B) | … | … | … | … | … | per model × GPU arch | lower |
| NIM (Phase 4) | … | … | … | … | … | minutes | vendor cadence |

Then the honest paragraph: where vLLM wins (flexibility, day-0 models, no per-arch builds) and where TRT-LLM wins (peak throughput/latency on NVIDIA, quantization maturity). **That trade-off table is the deliverable** — it's the decision a serving team makes, and the reason both stacks exist.

### Server-side: Model Analyzer (Triton config search)

```bash
model-analyzer profile --model-repository /models \
  --profile-models qwen --run-config-search-max-concurrency 64 \
  --latency-budget 200 --output-model-repository-path /optimal
```

Model Analyzer sweeps batch size / instance count / concurrency for the optimal Triton config under a latency budget and emits the throughput-vs-latency Pareto frontier. Deliverable: the report + your interpretation — this is how you *actually* size any inference deployment, Triton or not (connect to [P10](project-10-fault-tolerant-training-goodput.md)'s goodput framing).

### Attribute, don't assert (Nsight re-profile)

Re-run the exact Phase 0 `nsys` capture against the AWQ engine under identical aiperf load, and diff it: which kernels disappeared (fused), how the GEMM-vs-attention split shifted, what happened to inter-kernel gaps, the new achieved-vs-70-TFLOPS ratio. Every speedup number now has a *cause* — "X% faster because the quantized fused-attention path cut kernel count per token from A to B" is a sentence very few candidates can back with their own traces. Full methodology in [P16](project-16-cuda-gpu-performance-engineering.md).

## 7. Phase 4 — NIM: the vendor's factory, prepackaged

**NIM microservices** (NVIDIA now brands them that way rather than expanding the acronym) are the factory you just built — TRT-LLM optimization + serving + an OpenAI-compatible API — prebuilt, per-GPU-profiled, NVIDIA-supported, pulled from NGC, deployed in minutes. Licensing, precisely (July 2026): NIM containers fall under the **NVIDIA AI Enterprise** license; **Developer Program members get free access for research/dev/test, self-hosting up to 16 GPUs** — so you *can* run this phase hands-on for free — while **production requires an AI Enterprise subscription** (~$4,500/GPU/yr list, or ~$1/GPU/hr on cloud marketplaces; 90-day eval available). No entitlement at all? Do the phase as an architecture + pricing analysis from the docs and say so — still a strong artifact.

Deploy via the **NIM Operator** (v3.1.1 as of July 2026; operator source Apache-2.0, the artifacts it pulls AI-Enterprise-licensed). Its CRDs mirror everything you hand-rolled: **NIMCache** (model download/caching from NGC to shared storage — their version of your S3 registry), **NIMService** (deployment with autoscaling, ingress/Gateway API, monitoring), **NIMPipeline** (grouped services), and — the punchline — **NIMBuild**, which builds optimized TensorRT-LLM engines from model profiles. NVIDIA productized your Phases 1–2.

```yaml
# 1) cache the model + its optimized profiles once (confirm schema on your operator release)
apiVersion: apps.nvidia.com/v1alpha1
kind: NIMCache
metadata: { name: llama-31-8b-cache }
spec:
  source:
    ngc:
      modelPuller: nvcr.io/nim/meta/llama-3.1-8b-instruct:latest
      pullSecret: ngc-secret
      authSecret: ngc-api-secret
  storage: { pvc: { create: true, size: "50Gi", storageClass: gp3 } }
---
# 2) one object → full optimized service
apiVersion: apps.nvidia.com/v1alpha1
kind: NIMService
metadata: { name: llama-nim }
spec:
  image: { repository: nvcr.io/nim/meta/llama-3.1-8b-instruct, tag: latest }
  storage: { nimCache: { name: llama-31-8b-cache } }
  resources: { limits: { nvidia.com/gpu: 1 } }
  expose: { service: { type: ClusterIP, port: 8000 } }
```

At startup NIM detects the GPU and picks a **per-GPU optimized profile** — Phase 1's build matrix, done for you and hidden. Pin it (`NIM_MODEL_PROFILE`; the container ships a profile-listing utility — check your NIM's docs for the command) so auto-selection can't drift between benchmark runs.

Deploy the same Llama-3.1-8B, point the **same aiperf run** at it, fill the NIM row above. Then the judgment write-up (`docs/nim-vs-vllm.md`):

| | NIM | your factory (TRT-LLM/Triton) | vLLM |
|---|---|---|---|
| Time to production | minutes | weekends of engineering | hours |
| Perf out of the box | optimized per-GPU profiles | you tune it (Phases 1–3) | good, improving fast |
| Licensing | free ≤16 GPUs dev/test; AI Enterprise for prod (~$4.5k/GPU/yr, ~$1/GPU/hr cloud) | OSS (Apache-2.0) | OSS (Apache-2.0) |
| Control / lock-in | low control, NVIDIA lock-in | full control | full control |
| Day-0 model support | NVIDIA's release cadence | you build it | fastest in ecosystem |
| Custom / fine-tuned models | LoRA + NIMBuild, inside the profile system | anything you can quantize | anything |
| Support | enterprise SLA | you are the support | community |
| $/1M tokens (measured) | … | … | … |

State when each wins. The honest framing of the vendor path: you buy back engineering weekends and an SLA, and pay in dollars and lock-in. Having *measured* both sides — latency **and** operational effort **and** license cost — is what makes it credible.

## 8. Phase 5 — the "factory": CI + canary

GitHub Actions (self-hosted GPU runner — a spot g5 you start on demand):

```yaml
on: {push: {paths: ["models/**/build.yaml"]}}
jobs:
  build-engine:
    runs-on: [self-hosted, gpu, sm86]
    steps:
    - uses: actions/checkout@v4
    - run: ./factory/build.sh models/llama31-8b/build.yaml   # quantize→build→eval-gate
    - run: aws s3 sync out/ s3://engines/llama31-8b/awq/sm86/${GITHUB_SHA::7}/
    - run: ./factory/bench-gate.sh   # aiperf; fail if p99 TTFT regresses >10 %
```

Rollout: Argo Rollouts canary (10 %→50 %→100 %) with an **AnalysisTemplate** querying Prometheus for canary-vs-stable p99 TTFT and error rate; auto-rollback on breach. Standard MLOps loop — with GPU-native gates, which is the differentiator.

## 9. Done criteria & interview ammo

- [ ] Phase 0 Nsight baseline captured; decode-step kernel mix documented against the 70-TFLOPS dense A10G peak.
- [ ] Both lanes run: `trtllm-serve` (PyTorch backend) and a legacy AWQ engine served via Triton in-flight batching, streaming end-to-end — and you can explain why Lane B is retired in 1.3.
- [ ] Triton fundamentals proven on a non-LLM model: dynamic-batching effect measured, instance groups understood, metrics in Grafana.
- [ ] Quality-gated quantization (eval delta documented).
- [ ] Five-way benchmark table (vLLM / TRT-LLM serve / TRT-LLM FP16 engine / TRT-LLM AWQ / NIM) + $/1M-token economics, measured with AIPerf under a stated methodology; Model Analyzer Pareto report interpreted.
- [ ] Nsight re-profile diff attributing the speedup kernel-by-kernel.
- [ ] `docs/nim-vs-vllm.md` vendor-vs-OSS judgment written from measurements, licensing tiers stated correctly.
- [ ] Push-to-main → artifact built → benched → canaried automatically.

**Whiteboard-ready:** Triton backends and dynamic vs in-flight batching; what TRT-LLM compilation does and why it costs a per-arch matrix; why `trtllm-build` is going away and what replaces it; what NIM bundles and what it costs; how you size a deployment (Model Analyzer sweep + AIPerf curve, never one number); when a factory standardizes on NVIDIA's stack vs rolls its own.

**Resume bullet:** *"Built a model-optimization pipeline on NVIDIA's stack: INT4-AWQ/FP8 quantization with eval quality gates, TensorRT-LLM serving on both the default PyTorch backend (trtllm-serve) and legacy per-arch engines, Triton in-flight-batching with chunked context, NIM deployment with a measured vendor-vs-OSS trade-off analysis, AIPerf regression gates in CI (self-hosted GPU runners), Nsight-attributed speedups, and Argo Rollouts canaries keyed to p99 TTFT — +X % tokens/s/GPU vs. FP16 baseline at ≤Y quality delta."*

## 10. Teardown

Stop the GPU runner ASG at 0; engines/checkpoints in S3 (and the NIMCache PVC) cost pennies — never rebuild. Serving pods on session economics; drain GPU nodes when done. Keep the engines, traces, and reports.

## 11. Extensions

- Multi-GPU engine (`--tp_size 2`) on g5.12xlarge for tensor-parallel serving — connects to [P10](project-10-fault-tolerant-training-goodput.md)'s fabric lessons and [P15](project-15-nvidia-networking-nccl-cluster-validation.md)'s NCCL validation.
- Speculative decoding (draft model) in TRT-LLM; Medusa/EAGLE heads comparison memo.
- ONNX→TensorRT path for a non-LLM model (embedder) through the same Triton repo.
- Put NIM/Triton behind [P09](project-09-disaggregated-inference-llm-d.md)'s inference gateway — vendor serving + open routing.
- NGC **private registry** for your own engines/adapters → a golden-model supply chain (feeds [P15](project-15-nvidia-networking-nccl-cluster-validation.md)'s AI-factory capstone).
- **Close the customize→evaluate→serve loop:** the NIM Operator also manages the NeMo microservice CRDs (Customizer — LoRA/SFT/DPO/GRPO, Volcano-gang-scheduled — plus Evaluator, Guardrails, Data/Entity Store): fine-tune, evaluate, serve the adapter through NIM. Be precise about which "NeMo" you mean — the *framework* is now modular (Megatron-Bridge, NeMo AutoModel, NeMo RL, via NeMo-Run); the managed K8s loop is NeMo *microservices*.
- The datacenter rung — disaggregated prefill/decode, KV-aware routing, KVBM/NIXL, DynamoGraphDeployments — is [P14](project-14-nvidia-dynamo-inference-os.md), where the three-way write-up (`docs/disagg-comparison.md`: vLLM-native disagg vs llm-d ([P09](project-09-disaggregated-inference-llm-d.md)) vs Dynamo) lands, built on the engines you produce here.

## 📣 Build in public

- **LinkedIn:** post THE table — five serving paths × concurrency with TTFT/TPOT p99, tokens/s/GPU, quality delta and $/1M tokens on the same ~$1/hr spot GPU, NIM row included with its license cost stated — under the hook "quantization without a quality gate is malpractice," letting the AWQ-vs-FP16 quality delta carry the argument.
- **X/Twitter thread:** the tooling-shift story with receipts — "`trtllm-build` is legacy and gone in TRT-LLM 1.3; genai-perf is deprecated for AIPerf; Model Analyzer is *not* dead, and never did genai-perf's job" — illustrated with your before/after Nsight kernel-mix screenshots and the measured throughput gap between the PyTorch-backend and engine lanes.
- **YouTube:** live-fire the factory — push a `build.yaml` change, watch CI quantize→build→aiperf-gate, then inject a p99 TTFT regression and let the Argo Rollouts AnalysisTemplate auto-rollback on camera with the Prometheus canary-vs-stable graph up; close by deploying the same model as a NIMService in 90 seconds and pricing what it would cost in production.
