# Project 09 — Serve: A Disaggregated, KV-Cache-Aware LLM Inference Platform

**Difficulty:** ★★★★★ | **Time:** 4 weekends | **Cost:** ~$30–60 (2–4× g5/g6 spot; short A100 window for the disagg benchmark)

## 1. The production problem

Your first-track vLLM project served one model from one deployment. Frontier-scale serving looks different, because LLM inference has **two phases with opposite hardware profiles**:

- **Prefill** (process the prompt): compute-bound, parallel, benefits from big batches.
- **Decode** (generate tokens): memory-bandwidth-bound, latency-sensitive, dominated by **KV-cache** reads.

Co-locating them means long prefills stall everyone's decode (TTFT spikes, inter-token jitter). The 2025-era answer — visible across vLLM's production stack, the CNCF **llm-d** project, NVIDIA Dynamo (P14), and public talks from major labs — is:

1. **Disaggregation**: separate prefill and decode worker pools; ship KV blocks between them over RDMA/NIXL.
2. **KV-cache-aware routing**: route a request to the replica that already holds the longest matching prefix cache (multi-turn chat = huge hit rates), via the **Gateway API Inference Extension** (`InferencePool` + Endpoint Picker).
3. **KV offload/tiering** (LMCache): spill cache to CPU RAM / NVMe / Redis so long contexts and reuse survive GPU memory pressure.
4. **SLO-driven autoscaling** on TTFT / TPOT / queue depth — not CPU %.
5. **Cell-based multi-region** layout for blast-radius control (maps to the "HA microservices across regions" line in your Cisco control-plane JD).

## 2. Architecture

```
            Route53 latency routing / Global Accelerator
                 │                          │
        ┌────────▼────────┐        ┌────────▼────────┐
        │  Cell us-east-1 │        │  Cell ap-south-1│   (identical cells)
        │  Envoy/kgateway │        └─────────────────┘
        │   + EPP (KV/queue/prefix-aware endpoint picker)
        │        │ InferencePool
        │  ┌─────▼──────┐   NIXL/RDMA KV xfer   ┌──────────────┐
        │  │ prefill×N  │ ─────────────────────▶ │  decode×M    │
        │  │ vLLM       │                        │  vLLM+LMCache│
        │  └────────────┘                        └──────┬───────┘
        │        CPU/NVMe/Redis KV tier  ◀──────────────┘
        └─ HPA on vllm queue/TTFT metrics; PDBs; priorities
```

## 3. Phase 1 — the routing plane (works on small GPUs)

Install Gateway API Inference Extension (kgateway or Istio as the Gateway implementation, plus the reference **EPP**):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/latest/download/manifests.yaml
```

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2   # API still maturing — pin to your release
kind: InferencePool
metadata: {name: llama8b-pool}
spec:
  targetPortNumber: 8000
  selector: {app: vllm-decode}
  extensionRef: {name: llama8b-epp}      # the Endpoint Picker deployment
---
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata: {name: llama8b}
spec:
  modelName: meta-llama/Llama-3.1-8B-Instruct
  criticality: Critical            # vs Sheddable — enables priority load-shedding
  poolRef: {name: llama8b-pool}
```

The EPP scores endpoints on **queue depth + KV-cache utilization + prefix-cache hit** (it scrapes vLLM's `/metrics`). Prove it: send 200 conversations with sticky prefixes through the gateway vs. a plain round-robin Service; record TTFT p50/p99 and `vllm:gpu_prefix_cache_hit_rate`. Expect a dramatic p99 gap under load — *that* graph is your interview centerpiece.

**Shortcut:** the **llm-d** project packages gateway+EPP+prefill/decode as Helm charts (`llm-d-infra` quickstarts). Deploy it once to see the assembled reference, then keep your hand-rolled version for understanding.

## 4. Phase 2 — prefill/decode disaggregation

vLLM (≥0.9; flags evolve — check `vllm serve --help`) with the NIXL connector:

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

A proxy/EPP in disagg mode sends the prompt to prefill, then hands the request+KV handle to decode. On g5 instances the transfer rides TCP (slow but functional — perfect for learning); your P15 EFA cluster is where you benchmark it properly.

**Benchmark protocol** (use `guidellm` or `genai-perf`): fixed request rate sweep (1→32 rps), ISL/OSL 3000/150 (prefill-heavy) and 300/800 (decode-heavy). Compare aggregated vs. disaggregated on: TTFT p50/p99, TPOT p50/p99, goodput (requests meeting *both* SLOs: TTFT<800 ms, TPOT<40 ms). Disagg should win decisively on the mixed workload's tail latency; note where it *loses* (low QPS — transfer overhead) — knowing the break-even point is senior-engineer signal.

## 5. Phase 3 — KV tiering with LMCache

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

Test: 500 multi-turn sessions with 8k-token shared system prompts; measure TTFT with LMCache on/off, and cross-replica hits via the Redis tier (a session migrating replicas still hits cache). Explain the hierarchy like a CPU-cache hierarchy: HBM → host RAM → NVMe/Redis.

## 6. Phase 4 — SLO autoscaling, priorities, resilience

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

Plus: KEDA alternative (scale on Prometheus TTFT-p99 query); `priorityClassName` so Critical InferenceModels preempt Sheddable batch summarization; PDBs `maxUnavailable: 1`; node-loss drill (kill a decode node → measure error rate + recovery time; retries at the gateway should mask it).

**Multi-cell:** stamp the whole stack per region with ArgoCD ApplicationSets (your existing GitOps muscle), Route53 latency records + health checks on `/v1/models`, and a documented cell-evacuation runbook. Cells = blast-radius units; never one global control plane on the request path.

## 7. Done criteria & interview ammo

- [ ] KV-aware routing beats round-robin on p99 TTFT under load (graph it).
- [ ] Disagg vs. aggregated benchmark table with break-even analysis.
- [ ] LMCache tiering demonstrably cutting multi-turn TTFT; cross-replica cache hit shown.
- [ ] SLO autoscaling + priority shedding + node-loss drill all recorded in a runbook.
- [ ] Two-cell deployment with failover demo.

**Resume bullet:** *"Built a disaggregated LLM serving platform on EKS: prefill/decode vLLM pools with NIXL KV transfer, Gateway-API Inference-Extension KV-cache-aware routing, LMCache CPU/Redis KV tiering, and SLO-driven autoscaling (TTFT/TPOT/goodput); cut p99 TTFT ~X % vs. round-robin at equal GPU count and documented the low-QPS break-even where aggregation wins."*

**Deep-dive answers you now own:** why decode is bandwidth-bound (KV reads per token ∝ context length × layers); why continuous batching changed serving economics; PagedAttention as virtual memory for KV; why routing must be model-aware (queue depth ≠ load when batch composition differs).

## 8. Teardown & budget mode

All phases 1/3/4 run on 2× g5.xlarge spot (~$0.30/hr each). Phase 2's meaningful numbers need one 2-hr window on 2× g5.12xlarge or a p4d. `kubectl delete -k cells/ && eksctl delete nodegroup gpu-decode gpu-prefill`.

## 9. Extensions

- Speculative decoding (draft model) in the decode pool; measure TPOT gain vs. acceptance rate.
- Wide-EP / MoE serving notes (DeepSeek-style expert parallelism) as a design doc.
- Compare against NVIDIA Dynamo (P14) — same architecture, different implementation; write the trade-off memo.
