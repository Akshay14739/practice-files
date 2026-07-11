# Project 14 — The NVIDIA Inference Stack: Triton, TensorRT-LLM, NIM & Dynamo
### 🟩 NVIDIA TRACK 2 of 3 — "AI factories"

> NVIDIA doesn't just sell GPUs — it ships the **software factory** that runs them: **Triton Inference Server**, **TensorRT-LLM**, **NIM** (prepackaged inference microservices), the **NGC** catalog, and **Dynamo** (datacenter-scale disaggregated serving). This project makes you fluent in the vendor stack that AI factories are literally built on, deployed on your Kubernetes platform, and benchmarked honestly against the open-source path from P2/P10.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 4 weekends |
| **Prereq** | Projects 1–2, 10, 13 (you'll compare against vLLM and use your profiling skills) |
| **Cloud cost** | 1–2 GPU spot nodes, sessions only. TensorRT-LLM engine builds are compute-heavy but one-time. ~$0.30–0.90/hr. NGC catalog access is free (registration). |
| **Skills proven** | Triton (backends, dynamic batching, model repository, ensembles), TensorRT-LLM engine build & deploy, NIM microservice ops, NGC registry, Dynamo disaggregated serving, model-analyzer benchmarking, vendor-vs-OSS trade-off judgment |
| **Post/JD mapping** | "AI factories" (the post) · NVIDIA-cert syllabus: "Triton Inference Server, NGC, model deployment at scale, multi-framework serving, HA" · serving JDs |

---

## 1. The NVIDIA serving stack, mapped

```
NGC catalog ──► pull optimized containers & models (Triton, NIM, TensorRT-LLM)
     │
     ├── TensorRT-LLM ──► compiles a model → optimized ENGINE (fused kernels, paged KV, quant)
     │                         │
     ├── Triton ──────────────►│ serves the engine: dynamic batching, multi-model, metrics
     │                         │
     ├── NIM ─────────────────►│ = Triton+TensorRT-LLM+API prepackaged as ONE microservice
     │
     └── Dynamo ──────────────► datacenter layer: disaggregated P/D, KV router, multi-node
```

You'll deploy each rung on K8s and know exactly when a team chooses vendor (NIM: fast, supported, licensed) vs open (vLLM: flexible, free, more assembly).

## 2. Phase 1 — NGC & Triton fundamentals

Register for NGC (free), get an API key, pull the Triton container. Triton serves *any* framework via **backends** (TensorRT, PyTorch, ONNX, Python, vLLM-backend, TensorRT-LLM-backend). Start with a simple model to learn the **model repository** layout:

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

Deploy on K8s:

```yaml
containers:
  - name: triton
    image: nvcr.io/nvidia/tritonserver:24.12-py3
    args: ["tritonserver", "--model-repository=/models", "--metrics-port=8002"]
    ports: [{ containerPort: 8000 }, { containerPort: 8001 }, { containerPort: 8002 }]  # HTTP/gRPC/metrics
    resources: { limits: { nvidia.com/gpu: 1 } }
```

Learn Triton's **dynamic batching** (server-side request coalescing — the general version of what vLLM does for LLMs), **concurrent model execution** (instance groups), and its Prometheus metrics (`nv_inference_queue_duration`, `nv_gpu_utilization`). Wire metrics into P11's Grafana.

## 3. Phase 2 — TensorRT-LLM: build an optimized engine

This is the "compile your model for maximum GPU performance" step. TensorRT-LLM converts an LLM into a hardware-specific engine with fused kernels, paged KV-cache, and quantization:

```bash
# in the tensorrt-llm container (from NGC)
# 1) convert HF checkpoint → TensorRT-LLM checkpoint (choose quant here)
python convert_checkpoint.py --model_dir Qwen2.5-1.5B --dtype float16 \
  --output_dir /ckpt/qwen-trt
# 2) build the engine (this is the compute-heavy, one-time step)
trtllm-build --checkpoint_dir /ckpt/qwen-trt \
  --gemm_plugin float16 --max_batch_size 32 --max_input_len 2048 \
  --output_dir /engines/qwen
```

Serve the engine via **Triton's TensorRT-LLM backend** (in-flight batching = TRT-LLM's continuous batching). Then the honest benchmark (using P13's profiling discipline + genai-perf):

| Serving path | tokens/s | TTFT p95 | e2e p95 | build effort | flexibility |
|---|---:|---:|---:|---|---|
| vLLM (P2) | *base* | … | … | none | high |
| Triton + TensorRT-LLM | … | … | … | engine build per model/GPU | lower |

Expect TRT-LLM to win raw throughput/latency, at the cost of a per-model, per-GPU-arch engine build and less flexibility. **That trade-off table is the deliverable** — it's the decision a serving team makes and the reason both stacks exist.

## 4. Phase 3 — NIM: the prepackaged microservice

**NIM** = Triton + TensorRT-LLM + an OpenAI-compatible API, prebuilt and NVIDIA-supported — deploy a production inference service in minutes:

```bash
# NIM containers from NGC (requires NVIDIA AI Enterprise entitlement — note the licensing)
helm repo add nim https://helm.ngc.nvidia.com/nim   # or the NIM Operator
```

```yaml
# NIM Operator CRD — one object, full optimized service
apiVersion: apps.nvidia.com/v1alpha1
kind: NIMService
metadata: { name: llama-nim }
spec:
  image: { repository: nvcr.io/nim/meta/llama-3.1-8b-instruct, tag: latest }
  resources: { limits: { nvidia.com/gpu: 1 } }
  expose: { service: { type: ClusterIP, port: 8000 } }
```

The point isn't just deploying it — it's the **judgment write-up** (`docs/nim-vs-vllm.md`): NIM buys you optimized-out-of-the-box + enterprise support + guaranteed perf, and costs you licensing + less control + NVIDIA lock-in; vLLM is the opposite. Every AI-factory-adjacent team weighs this. Deploy the same model on NIM and on your P2 vLLM, compare latency *and* operational effort, and state when each wins. (If entitlement isn't available, do this phase as an architecture + pricing analysis using NIM docs — still a strong artifact.)

## 5. Phase 4 — Dynamo: datacenter-scale serving

**NVIDIA Dynamo** is the open-source (Apache-2.0) datacenter inference framework — the vendor's answer to the same problem llm-d solves (P10): disaggregated prefill/decode, a **KV-cache-aware router**, multi-node model sharding, and dynamic GPU scheduling across the fleet:

```bash
# Dynamo on K8s (operator/helm from NGC/GitHub)
```

Deploy the **disaggregated topology**: separate prefill and decode workers with Dynamo's KV router in front. This is the direct NVIDIA counterpart to P10's llm-d run — so the deliverable is the **three-way comparison** (`docs/disagg-comparison.md`): vLLM-native disagg vs llm-d vs Dynamo — architecture, KV-transfer mechanism (NIXL), scheduler, maturity, lock-in. Running the vendor and OSS versions of the frontier serving pattern and comparing them is a genuinely senior portfolio piece almost no one has.

## 6. Phase 5 — Triton model-analyzer: rigorous benchmarking

NVIDIA's **model-analyzer** sweeps batch size / instance count / concurrency to find the optimal config under a latency budget — the disciplined way to size serving:

```bash
model-analyzer profile --model-repository /models \
  --profile-models qwen --run-config-search-max-concurrency 64 \
  --latency-budget 200 --output-model-repository-path /optimal
```

Output: the Pareto frontier of throughput vs latency and the recommended config. Deliverable: the analyzer's report + your interpretation, and the general lesson (this is how you *actually* size any inference deployment, Triton or not — connect to P10's goodput framing).

## 7. Validation checklist

- [ ] Triton serving with dynamic batching; metrics in Grafana; batching effect measured
- [ ] TensorRT-LLM engine built and served; vLLM-vs-TRT-LLM benchmark table published
- [ ] NIM deployed (or fully analyzed); nim-vs-vllm judgment doc written
- [ ] Dynamo disaggregated topology running; three-way disagg comparison written
- [ ] model-analyzer sweep produces an optimal config with interpretation

## 8. Teardown

Engine builds cached to a PVC/S3 so you never rebuild; serving pods on session economics; `make down` drains GPU nodes. Keep the engines and reports.

## 9. Interview ammunition

- *"Deployed the full NVIDIA inference stack on Kubernetes — Triton with dynamic batching, TensorRT-LLM optimized engines, NIM microservices, and Dynamo datacenter-scale disaggregated serving — benchmarked each against open-source vLLM/llm-d with Triton model-analyzer, and can articulate the vendor-vs-OSS trade-off (performance and support vs flexibility and lock-in) that AI-factory serving teams decide on."*
- Whiteboard-ready: Triton backends & dynamic batching; what TensorRT-LLM compilation does and its per-arch cost; NIM = what, bundled; Dynamo vs llm-d vs vLLM-disagg; how to size a deployment with model-analyzer; when a factory standardizes on NVIDIA's stack vs rolls its own.

## 10. Stretch goals

1. **Triton ensemble**: chain a tokenizer (Python backend) + model + post-processor as one served pipeline.
2. Put **NIM/Triton behind P10's Inference Gateway** — vendor serving + open routing, best of both.
3. **Multi-node TensorRT-LLM** (tensor-parallel across 2 GPUs) — connect to P9's fabric lessons.
4. NGC **private registry** for your own engines/adapters → a golden-model supply chain (feeds P15 governance).
