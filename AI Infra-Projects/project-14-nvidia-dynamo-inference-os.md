# Project 14 — Conduct: NVIDIA Dynamo, the Datacenter-Scale Inference Framework (NVIDIA 2/3)

**Difficulty:** ★★★★★ | **Time:** 3 weekends | **Cost:** ~$20–40 (2–4× g5/g6 spot; optional A100 window)

> ⚠️ Dynamo is one of the fastest-moving projects in the ecosystem (first released GTC, March 2025). Pin a release tag from `github.com/ai-dynamo/dynamo`, and expect CRD/flag names to have evolved — the *architecture* below is the durable part.

## 1. What Dynamo is and why it exists

NVIDIA's open-source (Apache-2.0) successor-in-spirit to Triton for the LLM era: a **datacenter-scale distributed inference framework** — NVIDIA pitches it as the "operating system of the AI factory." It productizes exactly the patterns you hand-built in P09, which is why doing P09 first makes you dangerous here:

| Dynamo component | What it does | Your P09 equivalent |
|---|---|---|
| **Frontend** | OpenAI-compatible API, Rust, high-QPS | your gateway |
| **Smart Router** | KV-cache-aware + load-aware request routing across workers | Inference-Extension EPP |
| **Workers** | engine-agnostic: vLLM, SGLang, or TRT-LLM backends | your vLLM pools |
| **Disaggregated serving** | prefill/decode split as a first-class deployment mode | your NIXL producer/consumer split |
| **NIXL** | low-latency transfer library (GPU↔GPU/CPU/NVMe, RDMA/EFA-capable) | same library, raw |
| **KVBM** (KV Block Manager) | tiered KV memory: HBM→host RAM→NVMe→object | LMCache |
| **Planner** | SLA-driven scaling: adjusts prefill:decode worker ratio from TTFT/TPOT targets | your HPA + judgment |
| **etcd + NATS** | service discovery + control/event plane | K8s Services |

The senior-engineer question this project lets you answer: *"Build the serving plane from open parts (llm-d style) or adopt Dynamo?"* You'll have run both.

## 2. Phase 1 — platform install on EKS

```bash
# CRDs + platform (operator, etcd, NATS) — pin the chart version to a release
helm install dynamo-crds oci://nvcr.io/nvidia/ai-dynamo/dynamo-crds -n dynamo-system --create-namespace
helm install dynamo-platform oci://nvcr.io/nvidia/ai-dynamo/dynamo-platform -n dynamo-system
kubectl get pods -n dynamo-system   # operator, etcd, nats healthy
```

Prereqs you already own: GPU Operator (P08), Prometheus (P12).

## 3. Phase 2 — aggregated baseline, then disaggregated

A `DynamoGraphDeployment` (the operator's CRD) for a vLLM-backend graph — aggregated first:

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata: {name: llama8b-agg, namespace: dynamo}
spec:
  services:
    Frontend:
      replicas: 1
      extraPodSpec:
        mainContainer: {image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:<ver>}
    VllmDecodeWorker:            # aggregated mode: this worker does prefill+decode
      replicas: 2
      resources: {limits: {gpu: "1"}}
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:<ver>
          args: ["python3 -m dynamo.vllm --model meta-llama/Llama-3.1-8B-Instruct"]
```

Then the **disaggregated** graph: add a `VllmPrefillWorker` service (worker flag `--is-prefill-worker`), keep decode workers, and enable the KV-aware router on the frontend (`--router-mode kv`). Port-forward the frontend and hit `/v1/chat/completions` — same OpenAI schema as everything else you've built.

Verify the interesting behavior:
- **KV-aware routing:** replay 100 multi-turn conversations; watch worker logs / router metrics show sticky routing by prefix overlap; compare TTFT vs `--router-mode round-robin`.
- **Disagg data path:** NIXL transfer metrics/logs during a long-prompt burst; on TCP (g5) it works but is visibly slower — note the number, then (optional) repeat on an EFA pair from P15 with UCX/RDMA transports and watch the transfer cost collapse. That single before/after is a superb systems story.

## 4. Phase 3 — the Planner (SLA-driven, not utilization-driven)

Classic HPA scales replicas on a proxy metric. Dynamo's **Planner** reasons about the *ratio* of prefill:decode capacity against TTFT/TPOT targets — e.g., an ISL-heavy burst needs more prefill workers, not more of everything. Enable it with your SLOs (TTFT ≤ 800 ms, TPOT ≤ 40 ms), then drive two synthetic phases with genai-perf: prompt-heavy (ISL 3000/OSL 100) → decode-heavy (ISL 200/OSL 1000). Capture the worker-count timeline showing the ratio shifting. Write the comparison memo: Planner vs HPA-on-queue-depth (P09) — when is SLA-planning worth its complexity? (Answer sketch: at multi-model/multi-node scale with expensive GPUs; below that, HPA is simpler and good enough.)

## 5. Phase 4 — KVBM tiering + benchmark matrix

Enable KVBM offload (host RAM tier first, NVMe if the instance has it) and rerun P09's multi-turn benchmark. Final deliverable table across **four** stacks you have now personally operated:

| Stack | TTFT p99 | TPOT p99 | tok/s/GPU | Multi-turn TTFT (cache reuse) | Ops complexity (your rating) |
|---|---|---|---|---|---|
| vLLM plain (track 1) | | | | | |
| Your P09 (llm-d pattern) | | | | | |
| Triton+TRT-LLM (P13) | | | | | |
| Dynamo (agg / disagg) | | | | | |

Nobody interviewing you will have this table. It converts "I read about disaggregation" into "I measured it four ways."

## 6. Phase 5 (optional but cheap) — NIM, the packaged alternative

Deploy one **NIM** (NVIDIA Inference Microservice — prebuilt, optimized model container) via the **NIM Operator** (`NIMService` CRD) with an NGC API key, and note the trade: NIM = enterprise-packaged, supported, opinionated; Dynamo/llm-d = composable, transparent, yours to operate. One page: "When I'd recommend NIM vs Dynamo vs open assembly" — architecture-judgment content that reads extremely well to hiring managers.

## 7. Done criteria & interview ammo

- [ ] Dynamo platform + graphs (agg and disagg) live on EKS; OpenAI endpoint served.
- [ ] KV-aware routing benefit measured vs round-robin.
- [ ] Planner ratio-shift captured under workload phase change.
- [ ] Four-stack benchmark table + NIM/Dynamo/llm-d recommendation memo.

**Resume bullet:** *"Deployed NVIDIA Dynamo on EKS (operator, etcd/NATS control plane): disaggregated prefill/decode graphs with NIXL KV transfer, KV-cache-aware routing, KVBM tiered KV memory, and SLA-driven Planner autoscaling; benchmarked against vLLM, an llm-d-pattern stack, and Triton/TensorRT-LLM, and authored the platform-selection recommendation."*

## 8. Teardown & extensions

`helm uninstall dynamo-platform dynamo-crds -n dynamo-system`; scale GPU nodegroups to 0. Extensions: SGLang backend swap (engine-agnosticism demo); multi-node TP worker on 2× g5.12xlarge; wide-EP/MoE serving design note; edge angle (Udemy topic): single-GPU Dynamo frontend+worker as a "micro-cell."
