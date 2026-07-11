# Project 13 — Forge: A TensorRT-LLM + Triton Model Optimization Factory (NVIDIA 1/3)

**Difficulty:** ★★★★☆ | **Time:** 3 weekends | **Cost:** ~$15–30 (g5/g6 spot; engines build on the same GPU that serves them)

## 1. The production problem

Serving raw HuggingFace weights with a generic runtime leaves 2–4× throughput on the table. Inference performance teams run a **model optimization factory**: weights go in; quantized, compiled, benchmarked, *versioned* engines come out; and a canary system promotes them only if latency/quality SLOs hold. NVIDIA's production stack for this is **TensorRT-LLM** (compiler/runtime: fused kernels, paged KV cache, in-flight batching, FP8/INT4 quantization) served through **Triton Inference Server** (the `tensorrtllm` backend). This is also where the Udemy course's CUDA/GPU-architecture layer becomes practical: you'll finally *use* the difference between Ampere, Ada and Hopper.

Hard-won facts to internalize up front:
- **Engines are GPU-architecture-specific.** An engine built on A10G (SM86, Ampere) won't run on L4 (SM89, Ada) or H100 (SM90, Hopper). Production = a build **matrix** per architecture.
- **Quantization is architecture-gated.** FP8 needs Ada/Hopper tensor cores (L4/L40S/H100). On A10G you use INT8 SmoothQuant or **INT4-AWQ**. Knowing this instantly separates you from tutorial-followers.
- **Version pinning matters.** TensorRT-LLM release ↔ Triton `tensorrtllm` backend version must match (NVIDIA publishes the support matrix). Treat it like an ABI.

## 2. Architecture

```
 HF weights ─▶ [1] quantize (Model Optimizer / examples: INT4-AWQ | FP8)
            ─▶ [2] trtllm-build → engine artifacts (per GPU arch)
            ─▶ [3] push to S3 "engine registry" (s3://engines/llama31-8b/awq/sm86/v3/)
            ─▶ [4] Triton model repo (ensemble: preprocess → tensorrt_llm → postprocess)
            ─▶ [5] K8s Deployment (Triton) ── genai-perf gate ── Argo Rollouts canary
 GitHub Actions runs 1–4 on a self-hosted GPU runner; 5 is GitOps (ArgoCD)
```

## 3. Phase 1 — quantize + build (Llama-3.1-8B on a g5.2xlarge)

Use the matching NGC container so CUDA/TRT versions are coherent:

```bash
docker run --gpus all -it -v $PWD:/ws nvcr.io/nvidia/tritonserver:<yy.mm>-trtllm-python-py3
# inside: TensorRT-LLM examples are under /app or pip-installed — check the release notes

# (a) Quantize — INT4-AWQ (Ampere-safe). On g6/L4 or H100, use --qformat fp8.
python examples/quantization/quantize.py \
  --model_dir /ws/Llama-3.1-8B-Instruct \
  --qformat int4_awq --awq_block_size 128 \
  --kv_cache_dtype int8 \
  --output_dir /ws/ckpt-awq --calib_size 512

# (b) Compile the engine
trtllm-build --checkpoint_dir /ws/ckpt-awq --output_dir /ws/engine-sm86 \
  --gemm_plugin auto \
  --max_batch_size 64 --max_input_len 4096 --max_seq_len 8192 \
  --kv_cache_type paged --use_paged_context_fmha enable \
  --multiple_profiles enable
```

Record engine size, build time, and (crucially) a **quality check**: run a small eval (e.g., 200 MMLU-lite prompts or perplexity on a held-out set) FP16 vs AWQ. Quantization without a quality gate is malpractice — say that sentence in interviews.

## 4. Phase 2 — Triton model repository (in-flight batching)

```
model_repo/
├── ensemble/config.pbtxt            # ties the three below into one endpoint
├── preprocessing/                   # python backend: tokenizer
├── tensorrt_llm/config.pbtxt        # the engine
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

Two flags to be able to *explain*: `inflight_fused_batching` = continuous batching at the Triton layer (requests join/leave a running batch per step — the single biggest LLM-throughput idea of the last few years); `enable_chunked_context` = long prefills are sliced so they don't stall decoding (the intra-engine cousin of P09's disaggregation).

K8s Deployment: `tritonserver --model-repository=s3://engines/llama31-8b/... --model-control-mode=explicit`, readiness on `/v2/health/ready`, `nvidia.com/gpu: 1`, and Triton's Prometheus metrics scraped (`nv_inference_queue_duration_us`, `nv_trt_llm_kv_cache_block_metrics` feed your P12 dashboards). Prefer the OpenAI-compatible frontend (recent Triton releases ship one) so P09's gateway can route to it unchanged.

## 5. Phase 3 — benchmark honestly (genai-perf)

```bash
genai-perf profile -m ensemble --service-kind triton --backend tensorrtllm \
  --streaming --num-prompts 200 --concurrency 1,4,16,64 \
  --synthetic-input-tokens-mean 800 --output-tokens-mean 200
```

Produce THE table: **FP16-vLLM vs FP16-TRTLLM vs AWQ-TRTLLM** × concurrency → TTFT p50/p99, TPOT p50/p99, tokens/s/GPU, plus your quality-eval delta and $/1M-tokens (from P12's pricing). Then the honest paragraph: where vLLM wins (flexibility, day-0 model support, no per-arch builds), where TRT-LLM wins (peak throughput/latency on NVIDIA, quantization maturity). Balanced judgment > fanboyism.

## 6. Phase 4 — the "factory": CI + canary

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
    - run: ./factory/bench-gate.sh   # genai-perf; fail if p99 TTFT regresses >10 %
```

Rollout: Argo Rollouts canary (10 %→50 %→100 %) with an **AnalysisTemplate** querying Prometheus for canary-vs-stable p99 TTFT and error rate; auto-rollback on breach. This closes the loop the Udemy MLOps section describes — but with GPU-native gates, which is the differentiator.

## 7. Done criteria & interview ammo

- [ ] AWQ engine served via Triton in-flight batching, streaming end-to-end.
- [ ] Quality-gated quantization (eval delta documented).
- [ ] Three-way benchmark table + $/1M-token economics.
- [ ] Push-to-main → engine built → benched → canaried automatically.

**Resume bullet:** *"Built a model-optimization pipeline on NVIDIA's stack: INT4-AWQ/FP8 quantization with eval quality gates, TensorRT-LLM engine builds per GPU architecture, Triton in-flight-batching serving with chunked context, genai-perf regression gates in CI (self-hosted GPU runners), and Argo Rollouts canaries keyed to p99 TTFT — +X % tokens/s/GPU vs. FP16 baseline at ≤Y quality delta."*

## 8. Teardown & extensions

Stop the GPU runner ASG at 0; engines in S3 cost pennies. Extensions: multi-GPU engine (`--tp_size 2`) on g5.12xlarge to learn tensor-parallel serving; speculative decoding (draft engine) in TRT-LLM; Medusa/EAGLE heads comparison memo; ONNX→TensorRT path for a non-LLM model (embedder) to show breadth.
