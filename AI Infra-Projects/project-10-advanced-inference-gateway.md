# Project 10 — Advanced Inference: KV-Aware Routing, Multi-LoRA Multiplexing & P/D Disaggregation

> Project 2 served one model well. This is the **frontier serving stack**: the **Gateway API Inference Extension** (the Kubernetes-native "inference gateway" that routes on *KV-cache pressure and loaded LoRA adapters*, not round-robin), **multi-LoRA multiplexing** (dozens of fine-tunes on one GPU), **prefix caching & speculative decoding** with measured wins, and **prefill/decode disaggregation** (llm-d / vLLM's split-phase architecture) — the pattern Anthropic/OpenAI-scale fleets converged on.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 4–5 weekends |
| **Prereq** | Projects 1–2 (platform + vLLM), Project 5 (you'll serve your own adapters) |
| **Cloud cost** | 1–2 GPU spot nodes, sessions only ≈ $0.30–0.90/hr. Disagg phase wants 2 GPUs. |
| **Skills proven** | Gateway API Inference Extension (InferencePool / endpoint-picker), LoRA multiplexing ops, KV-cache-aware load balancing, prefix caching, speculative decoding, chunked prefill, P/D disaggregation theory + hands-on, **goodput** benchmarking (TTFT/TPOT/ITL under SLO) |
| **JD keywords hit** | "LLM-based agents… intelligent automation" · "highly available microservices… reliability at scale" · "routing patterns — canary, A/B" (Udemy) · the exact stack behind every "AI inference platform" req |

---

## 1. Why round-robin is wrong for LLMs (the thesis)

A vLLM replica's usable capacity is its **free KV-cache**, and its latency depends on **what's already cached** (shared prefixes) and **which LoRA adapters are resident**. Two replicas at "50% CPU" can differ 10× in what they can absorb. So modern serving splits the brain from the muscle:

```
                    ┌───────────── Endpoint Picker (EPP) ─────────────┐
client ─► Gateway ─►│ scrapes per-pod: kv_cache_util, queue_len,      │─► picks THE pod
 (Envoy)            │ loaded_adapters; applies InferenceObjective     │
                    └─────────────────────────────────────────────────┘
              ┌────────────┬─────────────┬─────────────┐
              ▼            ▼             ▼
         vllm pod A    vllm pod B    vllm pod C        (InferencePool)
         [lora: x,y]   [lora: z]     [cache-hot: RAG sys-prompt]
```

That's the **Gateway API Inference Extension (GIE)** model — CNCF-track, implemented by Envoy Gateway/GKE/Istio. You'll run it, then beat round-robin with numbers.

## 2. Phase 1 — Multi-LoRA serving (the tenant-density unlock)

One base model + N adapters = N "models" for ~1.05× the VRAM. Wire your **P5 adapter** in:

```yaml
# vLLM args (Deployment from P2, extended)
args:
  - --model=Qwen/Qwen2.5-1.5B-Instruct
  - --enable-lora
  - --max-loras=8                 # resident simultaneously
  - --max-lora-rank=16
  - --lora-modules
  - devops-bot=/adapters/devops   # name=path (PVC-mounted, synced from MLflow/S3)
  - finance-bot=/adapters/finance
```

Init-container syncs adapters from S3 (`aws s3 sync s3://ml-artifacts/adapters /adapters`). Clients just set `"model": "devops-bot"` — the OpenAI API contract holds. **Dynamic loading** (no restart) via vLLM's runtime endpoint:

```bash
curl -X POST $VLLM/v1/load_lora_adapter \
  -d '{"lora_name":"support-bot","lora_path":"/adapters/support"}'
```

Benchmark to publish: base-only vs 4 concurrent adapters — throughput cost of multiplexing (small), VRAM delta, and the punchline table: *N fine-tuned models per GPU vs N GPUs*.

## 3. Phase 2 — The Inference Gateway (GIE)

Install Envoy Gateway (from P6) + the Inference Extension CRDs, then declare the pool:

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata: { name: qwen-pool, namespace: llm }
spec:
  targetPorts: [{ number: 8000 }]
  selector:
    matchLabels: { app: vllm-qwen }
  endpointPickerRef:               # the EPP deployment (reference impl)
    name: qwen-epp
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceObjective            # per-workload priority/SLO class
metadata: { name: devops-bot, namespace: llm }
spec:
  priority: 10                       # premium tenant
  poolRef: { name: qwen-pool }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: llm-route, namespace: llm }
spec:
  parentRefs: [{ name: platform-gw, namespace: gateway }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /v1 } }]
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: qwen-pool
```

Deploy the reference **endpoint-picker** (EPP) — it consumes each pod's `/metrics` (`vllm:gpu_cache_usage_perc`, `vllm:num_requests_waiting`, loaded-adapter list) and picks per request. Then the experiment that *is* the project:

**A/B: plain Service round-robin vs GIE**, 3 replicas, workload = 70% short chats + 30% long-context RAG prompts, injected imbalance (pre-warm pod A with the RAG prefix). Publish TTFT p95, e2e p99, and **goodput** (requests meeting SLO per second) for both. Expect GIE to win visibly on p99 and goodput — the reference benchmarks show exactly this shape; yours makes it credible.

## 4. Phase 3 — Optimization ladder, each rung measured

One table, four features, same k6/genai-perf harness (`bench/harness.md` defines the fixed workload):

| Feature | Flag | What it exploits | Your measured Δ |
|---|---|---|---|
| **Prefix caching** | `--enable-prefix-caching` | Shared system prompts (RAG!) skip prefill | TTFT p95 −__% on 800-token shared prefix |
| **Chunked prefill** | `--enable-chunked-prefill` | Long prefills stop blocking decode steps | ITL p99 −__% under mixed load |
| **Speculative decoding** | `--speculative-model Qwen/Qwen2.5-0.5B-Instruct --num-speculative-tokens 5` | Draft model proposes, big model verifies | tokens/s +__% (report acceptance rate) |
| **FP8/AWQ quant** | `--quantization awq` | Smaller weights → bigger KV budget | max concurrent @SLO +__ |

Metrics vocabulary to use exactly: **TTFT** (time-to-first-token), **TPOT/ITL** (per-token latency), **goodput** — and why *goodput under SLO*, not raw throughput, is the fleet KPI.

## 5. Phase 4 — Prefill/Decode disaggregation (the frontier)

**Why:** prefill is compute-bound and spiky; decode is memory-bandwidth-bound and steady. Colocated, long prefills wreck decode ITL (you just measured that in Phase 3). Disaggregation runs them on **separate pods** and ships the KV cache between them — the architecture in DistServe/Mooncake and productized by **llm-d** and **NVIDIA Dynamo**.

Hands-on path (2 GPUs, vLLM's disagg support):

```bash
# pod P (prefill role) and pod D (decode role) share a KV-transfer channel
# vLLM: --kv-transfer-config '{"kv_connector":"...","kv_role":"kv_producer"}'  (P)
#       --kv-transfer-config '{"kv_connector":"...","kv_role":"kv_consumer"}'  (D)
# proxy in front dispatches: prompt→P, stream←D
```

Or deploy **llm-d**'s quickstart (Helm), which packages exactly this on top of GIE — P/D pods, KV-aware scheduler, NIXL transfer — and is the strongest "I run what the vendors announced" flex. Honest lab framing: on 2× T4 over TCP the *absolute* win is small (KV transfer isn't free without RDMA — connect to P9's fabric lesson); the deliverable is the **working topology + the ITL isolation demo**: long-prefill storm no longer moves decode ITL p99. Write the "when does disagg pay" analysis (long-context, high-QPS, RDMA-class fabric) — that judgment is the senior signal.

## 6. Phase 5 — Production routing polish

- **Model canary through the gateway:** two InferencePools (v1: fp16, v2: AWQ), HTTPRoute weighted 90/10, promote on your P2 AnalysisTemplate. Model rollouts now happen at the *gateway*, not the Deployment — cleaner than P2's approach; say why (traffic-level control, instant rollback, per-pool SLO classes).
- **Priority under overload:** two InferenceObjectives (premium prio 10, batch prio 0), saturate the pool, show premium p95 holds while batch sheds/queues. That's SLO-classed serving — the thing API businesses actually sell.
- **Semantic cache** (stretch from P4, now measured here): Redis + embedding-similarity gate in front of the gateway; report hit-rate and $/1k-requests delta on a realistic repeat-heavy workload.

## 7. Validation checklist

- [ ] 4+ LoRA adapters multiplexed; dynamic load/unload demonstrated
- [ ] GIE vs round-robin A/B published (TTFT/p99/goodput)
- [ ] Optimization-ladder table filled with your numbers (incl. speculative acceptance rate)
- [ ] Disagg topology running; prefill-storm isolation demo recorded; "when it pays" doc written
- [ ] Priority-classed overload demo (premium SLO holds)

## 8. Teardown

Everything rides P1's Karpenter economics: `make down` per phase; disagg phase is the only 2-GPU window — keep it under 2 hours per session.

## 9. Interview ammunition

- *"Built a Kubernetes-native inference gateway on the Gateway API Inference Extension: endpoint-picking on live KV-cache utilization and LoRA residency beat round-robin by __% goodput at p99 SLO; multiplexed N fine-tuned adapters per GPU; quantified prefix caching, chunked prefill, and speculative decoding; and ran prefill/decode-disaggregated vLLM (llm-d pattern), demonstrating decode-ITL isolation under prefill storms."*
- Whiteboard-ready: why KV-cache is the real capacity unit; LoRA multiplexing math; TTFT vs ITL and which phase owns each; the disagg trade (KV-transfer cost vs interference removal) and its fabric dependency; goodput as the fleet KPI; gateway-level vs deployment-level canary.

## 10. Stretch goals

1. Teach your **P6 operator** to emit InferencePool + InferenceObjective per ModelDeployment (control plane meets frontier data plane).
2. **NVIDIA Dynamo** deploy of the same disagg topology; compare with llm-d (feeds P14).
3. KV-cache **offload tier** (CPU/host memory via LMCache-style connector) — measure hit-rate on long-conversation replay.
4. Heterogeneous pool: T4 + A10G in one InferencePool; verify the picker respects capacity asymmetry.
