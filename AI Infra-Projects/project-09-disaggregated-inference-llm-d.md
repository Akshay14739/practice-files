# Project 09 — Serve: A Disaggregated, KV-Cache-Aware LLM Inference Platform with an Advanced Inference Gateway

**Difficulty:** ★★★★★ | **Time:** 5–6 weekends | **Cost:** ~$30–70 (2–4× g5/g6 spot; short 2-GPU window for the disagg benchmark)

**Prereqs:** P1–P2 (platform + vLLM), P5 (you'll serve your own adapters), P6 (Gateway + operator). **Skills proven:** Gateway API Inference Extension (InferencePool / Endpoint Picker), LoRA multiplexing ops, KV-cache-aware load balancing, prefix caching, chunked prefill, speculative decoding, P/D disaggregation, **goodput** benchmarking. **JD keywords hit:** "highly available microservices… reliability at scale" · "routing patterns — canary, A/B" · the exact stack behind every "AI inference platform" req.

*P2 served one model well. This is the frontier serving stack: the **Gateway API Inference Extension** (the Kubernetes-native inference gateway that routes on KV-cache pressure and loaded LoRA adapters, not round-robin), **multi-LoRA multiplexing** (dozens of fine-tunes on one GPU), a **measured optimization ladder** (prefix caching → chunked prefill → speculative decoding, every rung benchmarked with the same harness), and **prefill/decode disaggregation** (the llm-d / vLLM split-phase architecture) — the pattern Anthropic/OpenAI-scale fleets converged on.*

## 1. The production problem

Your first-track vLLM project served one model from one deployment. Frontier-scale serving looks different, because LLM inference has **two phases with opposite hardware profiles**:

- **Prefill** (process the prompt): compute-bound, parallel, benefits from big batches.
- **Decode** (generate tokens): memory-bandwidth-bound, latency-sensitive, dominated by **KV-cache** reads.

Co-locating them means long prefills stall everyone's decode (TTFT spikes, inter-token jitter). The 2025–26 answer — visible across vLLM's production stack, the CNCF **llm-d** project, NVIDIA Dynamo (P14), and public talks from major labs — is:

1. **Disaggregation**: separate prefill and decode worker pools; ship KV blocks between them over RDMA/NIXL.
2. **KV-cache-aware routing**: route a request to the replica that already holds the longest matching prefix cache (multi-turn chat = huge hit rates), via the **Gateway API Inference Extension** (`InferencePool` + Endpoint Picker).
3. **Multi-LoRA multiplexing**: one base model + N adapters = N "models" for ~1.05× the VRAM, with adapter-aware routing so requests land where their adapter is resident.
4. **Measured single-node optimizations**: prefix caching, chunked prefill, speculative decoding — each quantified, not cargo-culted.
5. **KV offload/tiering** (LMCache): spill cache to CPU RAM / NVMe / Redis so long contexts and reuse survive GPU memory pressure.
6. **SLO-driven autoscaling** on TTFT / TPOT / queue depth — not CPU %.
7. **Cell-based multi-region** layout for blast-radius control ("HA microservices across regions").

## 2. Architecture

```
            Route53 latency routing / Global Accelerator
                 │                          │
        ┌────────▼────────┐        ┌────────▼────────┐
        │  Cell us-east-1 │        │  Cell ap-south-1│   (identical cells)
        │  Envoy/kgateway │        └─────────────────┘
        │   + EPP (KV/queue/prefix/LoRA-aware endpoint picker)
        │        │ InferencePool
        │  ┌─────▼──────┐   NIXL/RDMA KV xfer   ┌──────────────┐
        │  │ prefill×N  │ ─────────────────────▶ │  decode×M    │
        │  │ vLLM       │                        │  vLLM+LMCache│
        │  └────────────┘                        │  [lora: x,y] │
        │                                        └──────┬───────┘
        │        CPU/NVMe/Redis KV tier  ◀──────────────┘
        └─ HPA on vllm queue/TTFT metrics; PDBs; priorities
```

Zoom in on the request path — the brain (EPP) is split from the muscle (the pool):

```
                    ┌───────────── Endpoint Picker (EPP) ─────────────┐
client ─► Gateway ─►│ scrapes per-pod: kv_cache_util, queue_len,      │─► picks THE pod
 (Envoy/kgateway)   │ prefix-cache hit, loaded_adapters;              │
                    │ applies InferenceObjective priority             │
                    └─────────────────────────────────────────────────┘
              ┌────────────┬─────────────┬─────────────┐
              ▼            ▼             ▼
         vllm pod A    vllm pod B    vllm pod C        (InferencePool)
         [lora: x,y]   [lora: z]     [cache-hot: RAG sys-prompt]
```

A vLLM replica's usable capacity is its **free KV-cache**, and its latency depends on **what's already cached** (shared prefixes) and **which LoRA adapters are resident**. Two replicas at "50% CPU" can differ 10× in what they can absorb — that's why round-robin is structurally wrong here, and why the picker has to be model-aware.

## 3. Phase 1 — the routing plane (works on small GPUs)

Install the Gateway API Inference Extension (kgateway, Istio or Envoy AI Gateway as the Gateway implementation — reuse the one you stood up in P6 — plus the reference **EPP**):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/manifests.yaml
```

> **API check (as of 2026-07-11; latest GIE release v1.5.0, 2026-04-19).** `InferencePool` is **GA**: `apiVersion: inference.networking.k8s.io/v1` (the group moved from `x-k8s.io` when it graduated at GIE v1.0.0, Sep 2025). The old alpha `InferenceModel` was **replaced, not just renamed**, at v1.0 by `InferenceObjective` — which is *still alpha*: the `criticality` enum became an integer `priority`, and `modelName` left the spec (the served model name now comes from the request body; name rewriting moved to a separate `InferenceModelRewrite` API in GIE v1.2.0). GIE releases v1.0.0–v1.5.0 serve `InferenceObjective` at `inference.networking.x-k8s.io/v1alpha2`; in June 2026 it moved out of the GIE repo into `llm-d/llm-d-router`, where llm-d v0.8.0+ serves it as `llm-d.ai/v1alpha2`. GIE now owns only `InferencePool`, the Endpoint-Picker (ext-proc) protocol, `InferencePoolImport` and conformance. **Pin to whatever your gateway's release actually serves** — `kubectl get crd | grep inference` before you write a line of YAML.

```yaml
apiVersion: inference.networking.k8s.io/v1     # GA since GIE v1.0.0 — the one stable string
kind: InferencePool
metadata: {name: llama8b-pool, namespace: llm}
spec:
  targetPorts: [{number: 8000}]
  selector:
    matchLabels: {app: vllm-decode}
  endpointPickerRef: {name: llama8b-epp}       # the Endpoint Picker deployment
---
apiVersion: inference.networking.x-k8s.io/v1alpha2   # llm-d.ai/v1alpha2 if deployed via llm-d v0.8+
kind: InferenceObjective                              # per-workload priority/SLO class (alpha)
metadata: {name: llama8b-critical, namespace: llm}
spec:
  priority: 10                     # integer priority replaced the old Criticality enum
  poolRef: {name: llama8b-pool}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: llm-route, namespace: llm}
spec:
  parentRefs: [{name: platform-gw, namespace: gateway}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /v1}}]
      backendRefs:
        - group: inference.networking.k8s.io   # the pool IS the backend — not a Service
          kind: InferencePool
          name: llama8b-pool
```

One-line hedge: if your gateway is stuck on the pre-GA API (GIE ≤ v0.5.1) you'll still see `inference.networking.x-k8s.io/v1alpha2` `InferenceModel` with `modelName`/`criticality` — build against the GA `v1` `InferencePool` if your gateway supports it, and per the **conformance reports** most now do: Istio 1.28.3 / 1.30.1, kgateway v2.1.0, NGINX Gateway Fabric v2.5.0, agentgateway v1.0.0, Alibaba ACK; GKE Inference Gateway ships v1 via its managed controller (CRD auto-installed on GKE 1.34.0-gke.1626000+, with an official v1alpha2→v1 migration guide); and on the Envoy side the path is **Envoy AI Gateway v0.4+** (built on Envoy Gateway v1.5+), not Envoy Gateway natively.

The EPP scores endpoints on **queue depth + KV-cache utilization + prefix-cache hit + LoRA-adapter affinity** (it scrapes vLLM's `/metrics`: `vllm:gpu_cache_usage_perc`, `vllm:num_requests_waiting`, loaded-adapter list). Prove it: send 200 conversations with sticky prefixes through the gateway vs. a plain round-robin Service; record TTFT p50/p99 and `vllm:gpu_prefix_cache_hit_rate`. Then make it adversarial — **the A/B that *is* the project**: 3 replicas, workload = 70% short chats + 30% long-context RAG prompts, injected imbalance (pre-warm pod A with the RAG prefix), and publish TTFT p95, e2e p99, and **goodput** (requests meeting SLO per second) for both. Expect a dramatic p99 gap under load — *that* graph is your interview centerpiece.

**Shortcut:** the **llm-d** project (v0.8.1, June 2026; CNCF Sandbox since March 2026) packages gateway+EPP+prefill/decode as Helm charts (`llm-d-infra` quickstarts) and bundles the GIE v1.5.0 chart. Deploy it once to see the assembled reference, then keep your hand-rolled version for understanding. Mapping old docs/blog posts to current images: `llm-d-inference-scheduler` → `llm-d-router-endpoint-picker` (v0.9.0), `llm-d-routing-sidecar` → `llm-d-router-disagg-sidecar` (v0.9.0).

## 4. Phase 2 — multi-LoRA multiplexing (the tenant-density unlock)

One base model + N adapters = N "models" for ~1.05× the VRAM. This is the *serving-layer* answer to tenant density — P08 gives you the *scheduler-layer* answer (fractional GPUs); know when each applies. Wire your **P5 adapters** in (as of vLLM v0.24.0, mid-2026; multi-LoRA is off by default):

```yaml
# vLLM Deployment args, extended
args: ["serve", "meta-llama/Llama-3.1-8B-Instruct", "--port", "8000",
       "--enable-lora",
       "--max-loras", "8",            # resident on GPU simultaneously (default: 1)
       "--max-lora-rank", "16",       # default: 16 — set to the max rank among your adapters; oversizing wastes VRAM
       "--max-cpu-loras", "16",       # LRU adapter cache in host RAM
       "--lora-modules",
       "devops-bot=/adapters/devops",     # name=path (PVC-mounted, synced from MLflow/S3)
       "finance-bot=/adapters/finance"]
env:
- {name: VLLM_ALLOW_RUNTIME_LORA_UPDATING, value: "True"}   # enables the runtime load/unload API
```

Init-container syncs adapters from S3 (`aws s3 sync s3://ml-artifacts/adapters /adapters`). Clients just set `"model": "devops-bot"` — the OpenAI API contract holds. **Dynamic loading** (no restart) via vLLM's runtime endpoints:

```bash
curl -X POST $VLLM/v1/load_lora_adapter \
  -d '{"lora_name":"support-bot","lora_path":"/adapters/support"}'
curl -X POST $VLLM/v1/unload_lora_adapter -d '{"lora_name":"support-bot"}'
```

Adapters are LRU-cached up to `--max-cpu-loras`; pre-warm a freshly loaded adapter with a 1-token dummy request to avoid cold-start latency on the first real hit.

**Adapter-aware routing** closes the loop with Phase 1: the EPP ships a **LoRA-affinity scorer** (`LoraAffinityScorer`) that scores a pod 1.0 if the requested adapter is loaded (or loadable on demand) and 0.0 otherwise, alongside the queue/KV/prefix scorers. This works because the GIE model-server protocol *requires* LoRA metrics, which vLLM exposes — servers without them (e.g., Triton, see P13) don't get adapter-aware picking. Add one `InferenceObjective` per adapter tenant (`devops-bot` at priority 10, batch adapters at 0) so priority follows the **tenant**, not the pod.

Benchmark to publish: base-only vs 4 concurrent adapters — throughput cost of multiplexing (small), VRAM delta, and the punchline table: *N fine-tuned models per GPU vs N GPUs*. Credible published anchors: S-LoRA (arXiv 2311.03285) reports up to **4× higher throughput** than packed per-adapter serving while hosting thousands of adapters; Google's GA announcement for the (GIE-based) GKE Inference Gateway measured **>30% lower serving cost, −60% tail latency, +40% throughput** vs baseline load balancing.

## 5. Phase 3 — the optimization ladder, every rung measured

One table, one harness (`guidellm`, `genai-perf` or k6; `bench/harness.md` pins the fixed workload: 70% short chat + 30% RAG with an 800-token shared prefix, fixed request-rate sweep). Anchor: **vLLM v0.24.0, V1 engine — prefix caching and chunked prefill are ON by default** (both flipped to default when V1 became the default engine in v0.8.0, March 2025), so the ladder starts by switching prefix caching *off* to get an honest baseline, and the chunked-prefill rung tunes the token budget rather than toggling a flag (in V1 chunked prefill is effectively always on and can't be meaningfully disabled). Anyone still writing `--enable-prefix-caching` / `--enable-chunked-prefill` in 2026 is copying a 2024 blog post.

| Rung | Knob (vLLM v0.24, V1 engine) | What it exploits | Expect roughly (published) | Your measured Δ |
|---|---|---|---|---|
| 0 — Baseline | `--no-enable-prefix-caching`, no spec-decode | Nothing — honest floor | — | TTFT p95 = __ ms, tok/s = __ |
| 1 — Prefix caching | remove the flag (default-on) | Shared system prompts (RAG!) skip prefill | TTFT ~−78% at ~50% hit rate (4.3s→<1s, shared-prefix bench); <1% throughput cost at 0% hits (vLLM V1 blog). Helps TTFT only, not decode | TTFT p95 −__% at __% hit rate |
| 2 — Chunked prefill tuning | `--max-num-batched-tokens` 2048 vs 8192 | Long prefills stop blocking decode steps; budget trades TTFT vs ITL | Sarathi-Serve (OSDI '24, the design vLLM follows): up to 2.6× capacity for Mistral-7B on 1×A100 under tail SLOs; docs: >8192 favors throughput, ~2048 favors ITL | ITL p99 −__% under mixed load (report both budgets) |
| 3 — Speculative decoding | `--speculative-config` JSON (below) | Draft proposes, target verifies | 1.5–2.8× tokens/s, strongly workload-dependent (vLLM blog: 1.5× draft-model on ShareGPT, 2.8× n-gram on summarization; Red Hat EAGLE3: up to 2.5× on Llama 3.1 8B, 1×A100, low QPS). **Gains shrink or vanish at high QPS**; translation can regress | tok/s +__% at acceptance rate __% |
| 4 — Quantization (stretch) | `--quantization awq` (or FP8) | Smaller weights → bigger KV budget | Model-dependent; measure, don't assume | max concurrent @SLO +__ |

Speculative decoding syntax — the old `--speculative-model` / `--num-speculative-tokens` flags are **gone**; it's one JSON config now, and supported methods include `ngram`, `suffix`, `draft_model`, `eagle`/`eagle3`, `medusa`, and `mtp`:

```bash
# low-overhead, no extra weights (great first rung):
--speculative-config '{"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4}'
# higher gain, needs draft weights (EAGLE3 head matched to your base model):
--speculative-config '{"method":"eagle3","model":"<eagle3-draft-for-your-base>","num_speculative_tokens":5}'
```

Metrics vocabulary to use exactly: **TTFT** (time-to-first-token), **TPOT/ITL** (per-token latency), **goodput** — and why *goodput under SLO*, not raw throughput, is the fleet KPI. Every number you publish carries its hardware, model and dataset, or it's noise. Rung 2's result is also your motivation for the next phase: even tuned, chunked prefill only *shares* the GPU between phases — disaggregation *separates* them.

## 6. Phase 4 — prefill/decode disaggregation

The architecture behind DistServe and Mooncake, productized by **llm-d** and **NVIDIA Dynamo** (P14). vLLM v0.24.0 (mid-2026) with the NIXL connector: the KV-connector API is stable-ish, but P/D disaggregation is still labeled **experimental** in bare vLLM's own docs — production hardening lives in the orchestration layers (llm-d's "well-lit path", Dynamo). Flags evolve — check `vllm serve --help`.

```yaml
# prefill workers (producer)
args: ["serve", "meta-llama/Llama-3.1-8B-Instruct", "--port", "8000",
       "--kv-transfer-config",
       '{"kv_connector":"NixlConnector","kv_role":"kv_producer"}']
env:
- {name: UCX_TLS, value: "cuda_copy,cuda_ipc,tcp"}   # add rc,ud+EFA/IB on RDMA nodes
---
# decode workers (consumer)
args: [ ... "--kv-transfer-config",
       '{"kv_connector":"NixlConnector","kv_role":"kv_consumer"}']
```

A proxy/EPP in disagg mode sends the prompt to prefill, then hands the request+KV handle to decode (in llm-d this is the `llm-d-router-disagg-sidecar`). On g5 instances the transfer rides TCP (slow but functional — perfect for learning); your P15 EFA cluster is where you benchmark it properly.

**Benchmark protocol** (use `guidellm` or `genai-perf`): fixed request-rate sweep (1→32 rps), ISL/OSL 3000/150 (prefill-heavy) and 300/800 (decode-heavy). Compare aggregated vs. disaggregated on: TTFT p50/p99, TPOT p50/p99, goodput (requests meeting *both* SLOs: TTFT<800 ms, TPOT<40 ms). Disagg should win decisively on the mixed workload's tail latency; note where it *loses* (low QPS — transfer overhead) — knowing the break-even point is senior-engineer signal. For calibration, llm-d's published P/D numbers (16× H200 + InfiniBand, Llama-70B-class, 5k ISL / 250 OSL at 45 QPS vs aggregated): mean E2E latency 6.7s→3.5s (~−47%), P95 −50%, mean ITL 25ms→8ms (−67%) — *at the cost of TTFT rising 532ms→1400ms*. llm-d recommends P/D only for long-ISL workloads (think 10k ISL / 1k OSL) on medium-large models; on 2 small GPUs over TCP your absolute win will be modest, so the deliverable is the **working topology + the isolation demo**: fire a long-prefill storm and show decode ITL p99 no longer moves. Write the "when does disagg pay" analysis (long-context, high QPS, RDMA-class fabric).

## 7. Phase 5 — KV tiering with LMCache

```yaml
# decode pods
env:
- {name: LMCACHE_CONFIG_FILE, value: /etc/lmcache/lmcache.yaml}
args: [ ... "--kv-transfer-config",
       '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}']
```
```yaml
# lmcache.yaml
chunk_size: 256
local_cpu: true
max_local_cpu_size: 40        # GiB of host RAM as L2 cache
remote_url: "redis://kv-redis.inference:6379"   # optional L3 shared tier
```

Test: 500 multi-turn sessions with 8k-token shared system prompts; measure TTFT with LMCache on/off, and cross-replica hits via the Redis tier (a session migrating replicas still hits cache). Explain the hierarchy like a CPU-cache hierarchy: HBM → host RAM → NVMe/Redis. (llm-d ships the same idea as its multi-tier `llm-d-kv-cache` library v0.9.0: GPU→CPU→disk.)

## 8. Phase 6 — SLO autoscaling, priorities, resilience

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: vllm-decode}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: vllm-decode}
  minReplicas: 2
  maxReplicas: 12
  metrics:
  - type: Pods
    pods:
      metric: {name: vllm_num_requests_waiting}   # via prometheus-adapter
      target: {type: AverageValue, averageValue: "4"}
  behavior:
    scaleUp:  {stabilizationWindowSeconds: 0,  policies: [{type: Percent, value: 100, periodSeconds: 30}]}
    scaleDown:{stabilizationWindowSeconds: 300}
```

Plus: KEDA alternative (scale on a Prometheus TTFT-p99 query); `priorityClassName` on pods (P07's preemption story), and **InferenceObjective priorities** at the gateway so premium tenants (priority 10) hold their SLO while batch (priority 0) sheds/queues; PDBs `maxUnavailable: 1`; node-loss drill (kill a decode node → measure error rate + recovery time; retries at the gateway should mask it).

**Production routing polish:**

- **Model canary through the gateway:** two InferencePools (v1: fp16, v2: AWQ), HTTPRoute weighted 90/10, promote on your P2 AnalysisTemplate. Model rollouts now happen at the *gateway*, not the Deployment — cleaner than P2's approach; say why (traffic-level control, instant rollback, per-pool SLO classes).
- **Priority under overload:** saturate the pool with both objective classes live; show premium p95 holds while batch degrades. That's SLO-classed serving — the thing API businesses actually sell.

**Multi-cell:** stamp the whole stack per region with ArgoCD ApplicationSets (your existing GitOps muscle), Route53 latency records + health checks on `/v1/models`, and a documented cell-evacuation runbook. Cells = blast-radius units; never one global control plane on the request path. (Fleet-wide DR and the FinOps view of this layout are P12's capstone.)

## 9. Done criteria & interview ammo

- [ ] KV/LoRA-aware routing beats round-robin on p99 TTFT and goodput under injected imbalance (graph it).
- [ ] 4+ LoRA adapters multiplexed on one GPU; dynamic load/unload via `/v1/load_lora_adapter` demonstrated; adapter-affinity routing shown.
- [ ] Optimization-ladder table filled with your numbers, including speculative-decoding acceptance rate and the high-QPS regression point.
- [ ] Disagg vs. aggregated benchmark table with break-even analysis; prefill-storm ITL-isolation demo recorded; "when it pays" doc written.
- [ ] LMCache tiering demonstrably cutting multi-turn TTFT; cross-replica cache hit shown.
- [ ] SLO autoscaling + priority shedding (premium SLO holds under overload) + node-loss drill all recorded in a runbook.
- [ ] Two-cell deployment with failover demo.

**Resume bullet:** *"Built a disaggregated LLM serving platform on EKS: prefill/decode vLLM pools with NIXL KV transfer, Gateway-API Inference-Extension (v1 InferencePool) KV-cache- and LoRA-affinity routing, N fine-tuned adapters multiplexed per GPU with runtime load/unload, a measured optimization ladder (prefix caching, chunked prefill, speculative decoding), LMCache CPU/Redis KV tiering, and SLO-driven autoscaling (TTFT/TPOT/goodput); cut p99 TTFT ~X % vs. round-robin at equal GPU count and documented the low-QPS break-even where aggregation wins."*

**Deep-dive answers you now own:** why decode is bandwidth-bound (KV reads per token ∝ context length × layers); PagedAttention as virtual memory for KV; why routing must be model-aware (queue depth ≠ load when batch composition differs); KV-cache as the real capacity unit; the LoRA multiplexing math (N tenants ≈ 1.05× VRAM); TTFT vs ITL and which phase owns each; the disagg trade (KV-transfer cost vs interference removal) and its fabric dependency; goodput as the fleet KPI; gateway-level vs deployment-level canary.

## 10. Teardown & budget mode

Phases 1/2/3/5/6 run on 2× g5.xlarge spot (~$0.30/hr each) and ride P1's Karpenter economics. Phase 4's meaningful numbers need one 2-hr window on 2× g5.12xlarge — keep it under 2 hours per session; RDMA-grade numbers belong on P15's EFA cluster (the only project that pays for p4d). `kubectl delete -k cells/ && eksctl delete nodegroup gpu-decode gpu-prefill`.

## 11. Extensions

- Teach your **P6 operator** to emit InferencePool + InferenceObjective per ModelDeployment (control plane meets frontier data plane).
- Compare against **NVIDIA Dynamo** (P14) — same disagg architecture, different implementation (also NIXL-based); deploy the identical topology on both and write the trade-off memo.
- Wide-EP / MoE serving notes (DeepSeek-style expert parallelism, now shipped in llm-d) as a design doc.
- Heterogeneous pool: T4 + A10G in one InferencePool; verify the picker respects capacity asymmetry.
- **Semantic cache** (stretch from P4, measured here): Redis + embedding-similarity gate in front of the gateway; report hit-rate and $/1k-requests delta on a repeat-heavy workload.
- Multi-cluster pools via `inference.networking.x-k8s.io/v1alpha1` `InferencePoolImport` (alpha, still upstream in GIE) — connect to the P12 fleet story.

## 📣 Build in public

- **LinkedIn post:** one graph — p99 TTFT under load, KV/LoRA-aware EPP vs round-robin Service at equal GPU count — with your measured goodput delta in the caption, and a two-line explanation of why "queue depth ≠ load" for LLM replicas. Close by putting your own numbers next to the published anchors (S-LoRA's 4×, GKE Inference Gateway's −60% tail latency).
- **X/Twitter thread:** the optimization ladder, one rung per post — baseline TTFT/tok/s, prefix caching (−__% TTFT at your measured hit rate), the 2048-vs-8192 `--max-num-batched-tokens` ITL/TTFT trade, and speculative decoding's acceptance rate *including the QPS point where the gain collapses* — the regression screenshot is the hook.
- **YouTube demo:** 12 minutes, two live moments: (1) `curl /v1/load_lora_adapter` to hot-load an adapter mid-video, then watch the EPP's LoRA-affinity scorer route the very next request to that pod; (2) fire a long-prefill storm and split-screen decode ITL p99 on the aggregated vs disaggregated topologies — the flat line is the payoff.
