# Project 2 — Production LLM Inference Platform (vLLM)

> Serve a real open-weights LLM the way Anthropic/OpenAI-class inference teams do: **vLLM** with continuous batching, an OpenAI-compatible API, **KEDA autoscaling on queue depth**, canary rollouts gated on **p95 latency**, and load-test evidence.

| | |
|---|---|
| **Difficulty** | Medium-Hard |
| **Time** | 2–3 weekends |
| **Prereq** | Project 1 cluster (GPU Operator + Prometheus + Karpenter) |
| **Cloud cost** | ~$0.20–0.60/hr while running (1–2 GPU spot nodes). Tear down after sessions. |
| **Skills proven** | LLM serving internals (KV cache, continuous batching, PagedAttention), vLLM ops, KEDA custom-metric autoscaling, Argo Rollouts canary analysis, k6 load testing, p50/p95/p99 + TTFT SLOs |
| **JD keywords hit** | "Exposure to LLM-based agents…" · "KEDA" · "SLA/SLO metrics" · "canary, blue/green" · "GPU/CUDA compatibility" |
| **Book/course mapping** | GenAI book ch. 5–7, 10, 12 · Udemy: Triton/vLLM, batching, HPA/KEDA, p95/p99, TensorRT |

---

## 1. The mental model you must own

LLM inference is **not** a normal web service:

1. **A request isn't a unit of work — a token is.** One request = 1 prefill (parallel, compute-bound) + N decode steps (sequential, memory-bandwidth-bound).
2. **The KV cache is the resource.** Every in-flight request pins VRAM proportional to its context length. vLLM's **PagedAttention** manages this like an OS manages virtual memory pages.
3. **Continuous batching** = new requests join the running batch *between decode steps*, instead of waiting for the batch to drain. This is why vLLM gets 5–10× the throughput of naive serving.
4. Therefore the right autoscaling signal is **queue depth / KV-cache pressure**, not CPU. That's why this project uses KEDA on `vllm:num_requests_waiting`.

Say those four things in an interview and you're ahead of 90% of platform candidates.

## 2. Architecture

```
client ──> Service (ClusterIP) ──> Argo Rollout (vLLM pods, canary 10%→50%→100%)
                                        │  /v1/chat/completions (OpenAI-compatible)
                                        │  /metrics (vllm:* Prometheus metrics)
                                        ▼
                              GPU node (Karpenter, tainted, spot)
Prometheus <── ServiceMonitor ── vLLM metrics
   │                                   ▲
   ├── KEDA ScaledObject (queue depth) ┘  → scales replicas 1→N
   └── AnalysisTemplate (p95) ── gates canary promotion
```

## 3. Repo layout

```
llm-serving/
├── model/
│   ├── deployment.yaml         # plain Deployment first, Rollout later
│   ├── service.yaml
│   ├── servicemonitor.yaml
│   └── hf-cache-pvc.yaml
├── autoscaling/
│   └── keda-scaledobject.yaml
├── rollout/
│   ├── rollout.yaml            # Argo Rollouts canary
│   └── analysis-p95.yaml
├── loadtest/
│   └── k6-chat.js
└── Makefile
```

## 4. Phase 1 — Serve the model with vLLM

Model choice for a lab T4 (16 GB): **`Qwen/Qwen2.5-1.5B-Instruct`** (fast, good quality) or `TinyLlama/TinyLlama-1.1B-Chat-v1.0`. On a g5 (A10G, 24 GB): `mistralai/Mistral-7B-Instruct-v0.3` with `--max-model-len 8192`.

`model/hf-cache-pvc.yaml` — never re-download weights on every restart:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: hf-cache, namespace: llm }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources: { requests: { storage: 50Gi } }
```

`model/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-qwen
  namespace: llm
spec:
  replicas: 1
  selector: { matchLabels: { app: vllm-qwen } }
  template:
    metadata:
      labels: { app: vllm-qwen }
    spec:
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.8.5    # check latest
          args:
            - --model=Qwen/Qwen2.5-1.5B-Instruct
            - --max-model-len=4096          # caps KV cache per request
            - --gpu-memory-utilization=0.90 # how much VRAM vLLM may claim
            - --dtype=half                  # T4 has no bf16
            - --port=8000
          ports:
            - { containerPort: 8000, name: http }
          env:
            - name: HF_HOME
              value: /root/.cache/huggingface
          volumeMounts:
            - { name: hf-cache, mountPath: /root/.cache/huggingface }
            - { name: shm, mountPath: /dev/shm }
          resources:
            limits:  { nvidia.com/gpu: 1, memory: 14Gi }
            requests:{ cpu: "2", memory: 8Gi }
          readinessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 60         # model load takes a while
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health, port: 8000 }
            initialDelaySeconds: 120
      volumes:
        - name: hf-cache
          persistentVolumeClaim: { claimName: hf-cache }
        - name: shm                          # vLLM needs big /dev/shm
          emptyDir: { medium: Memory, sizeLimit: 2Gi }
```

`model/service.yaml` + `model/servicemonitor.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata: { name: vllm-qwen, namespace: llm, labels: { app: vllm-qwen } }
spec:
  selector: { app: vllm-qwen }
  ports: [{ name: http, port: 8000, targetPort: 8000 }]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: vllm-qwen, namespace: llm }
spec:
  selector: { matchLabels: { app: vllm-qwen } }
  endpoints: [{ port: http, path: /metrics, interval: 15s }]
```

**Smoke test (OpenAI-compatible — the industry contract):**

```bash
kubectl -n llm port-forward svc/vllm-qwen 8000:8000 &
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role":"user","content":"Explain KV cache in one paragraph."}],
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

Key vLLM metrics now in Prometheus:

```promql
vllm:num_requests_running          # in the batch now
vllm:num_requests_waiting          # queued — OUR SCALING SIGNAL
vllm:gpu_cache_usage_perc          # KV-cache pressure
vllm:time_to_first_token_seconds_bucket   # TTFT histogram
vllm:e2e_request_latency_seconds_bucket
histogram_quantile(0.95, sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket[5m])))
```

Build a Grafana row with: TTFT p95, e2e p95/p99, running vs waiting, KV-cache %, tokens/sec (`rate(vllm:generation_tokens_total[1m])`).

## 5. Phase 2 — KEDA autoscaling on queue depth

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace
```

`autoscaling/keda-scaledobject.yaml`:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: vllm-qwen, namespace: llm }
spec:
  scaleTargetRef: { name: vllm-qwen }        # the Deployment (or Rollout later)
  minReplicaCount: 1
  maxReplicaCount: 3                          # ceiling = your GPU budget
  cooldownPeriod: 300                         # GPUs are pricey; scale down slow-ish
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kps-kube-prometheus-stack-prometheus.monitoring:9090
        query: sum(vllm:num_requests_waiting{namespace="llm"})
        threshold: "5"                        # >5 queued requests per replica → scale
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0       # scale up fast
          policies: [{ type: Pods, value: 1, periodSeconds: 60 }]
```

Why not CPU? A saturated vLLM pod can sit at 30% CPU while 50 requests queue. **Queue depth is the truth.** (Alternative signals worth mentioning in interviews: `gpu_cache_usage_perc > 0.9`, or tokens/sec per replica.)

Each new replica → new `nvidia.com/gpu` request → **Karpenter buys another spot GPU node**. KEDA scales pods; Karpenter scales metal. That sentence is interview gold.

## 6. Phase 3 — Canary rollouts gated on p95

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

Convert the Deployment to `rollout/rollout.yaml` (same pod spec, different top):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: vllm-qwen, namespace: llm }
spec:
  replicas: 2
  selector: { matchLabels: { app: vllm-qwen } }
  template: { <same pod template as the Deployment> }
  strategy:
    canary:
      steps:
        - setWeight: 34
        - pause: { duration: 3m }
        - analysis:                       # promotion gate
            templates: [{ templateName: p95-latency }]
        - setWeight: 100
```

`rollout/analysis-p95.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: { name: p95-latency, namespace: llm }
spec:
  metrics:
    - name: p95-e2e-latency
      interval: 1m
      count: 3
      successCondition: result[0] < 6            # seconds; tune to your model
      failureLimit: 1
      provider:
        prometheus:
          address: http://kps-kube-prometheus-stack-prometheus.monitoring:9090
          query: |
            histogram_quantile(0.95,
              sum by (le) (rate(vllm:e2e_request_latency_seconds_bucket{namespace="llm"}[2m])))
```

Demo for your portfolio: change `--max-model-len` (a "new model version"), watch the canary run analysis, then deliberately push a bad config (e.g. absurdly low `gpu-memory-utilization`) and record the **automatic abort + rollback**.

## 7. Phase 4 — Load test and publish numbers

`loadtest/k6-chat.js`:

```javascript
import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const e2e = new Trend('e2e_latency', true);

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '2m', target: 10 },
        { duration: '3m', target: 30 },   // should trip KEDA
        { duration: '2m', target: 0 },
      ],
    },
  },
};

const prompts = [
  'Summarize the CAP theorem in two sentences.',
  'Write a haiku about Kubernetes.',
  'Explain continuous batching to a DevOps engineer.',
];

export default function () {
  const body = JSON.stringify({
    model: 'Qwen/Qwen2.5-1.5B-Instruct',
    messages: [{ role: 'user', content: prompts[Math.floor(Math.random()*prompts.length)] }],
    max_tokens: 100,
  });
  const res = http.post(`${__ENV.BASE_URL}/v1/chat/completions`, body,
    { headers: { 'Content-Type': 'application/json' }, timeout: '120s' });
  e2e.add(res.timings.duration);
  check(res, { 'status 200': r => r.status === 200 });
}
```

```bash
kubectl -n llm port-forward svc/vllm-qwen 8000:8000 &
BASE_URL=http://localhost:8000 k6 run loadtest/k6-chat.js
```

Publish a table like this in your README (your real numbers):

| VUs | replicas | tokens/s | TTFT p95 | e2e p95 | KV cache % |
|----:|---------:|---------:|---------:|--------:|-----------:|
| 10  | 1        | …        | …        | …       | …          |
| 30  | 3 (KEDA) | …        | …        | …       | …          |

## 8. Quantization & model-size levers (know the trade-offs)

- `--quantization awq` / GPTQ / `fp8` (Hopper+): ~½ VRAM → 2× KV-cache head-room → higher batch → higher throughput; small quality cost.
- `--max-model-len`: the KV-cache budget per request. Halving it ≈ doubles concurrent capacity.
- `--tensor-parallel-size N`: split one model across N GPUs (needs multi-GPU node; NVLink matters here — connect this to the interconnect layer in your infra-stack notes).
- Alternatives to name-drop with one sentence each: **TensorRT-LLM** (NVIDIA-compiled, fastest, less flexible), **Triton** (multi-framework server, dynamic batching), **TGI** (HF's server), **SGLang** (fast structured output).

## 9. Teardown

```bash
kubectl delete ns llm keda argo-rollouts
# GPU nodes drain → Karpenter consolidates them away; verify: kubectl get nodeclaims
```

## 10. Interview ammunition

- *"Deployed vLLM with continuous batching on EKS GPU nodes; autoscaled on Prometheus queue-depth via KEDA (pods) + Karpenter (nodes), sustaining X tok/s at p95 < Ys under a 30-VU k6 ramp."*
- *"Implemented canary releases for model deployments with Argo Rollouts, auto-aborting on p95 latency regression."*
- Whiteboard-ready: why queue depth beats CPU for LLM autoscaling; PagedAttention in one paragraph; TTFT vs inter-token latency; what `gpu_cache_usage_perc` at 95% means operationally.

## 11. Stretch goals

1. Add a **second model** and put both behind one gateway with model-name routing (feeds Project 6).
2. Serve the same model via **Triton + TensorRT-LLM** and publish a vLLM-vs-Triton benchmark.
3. Prefix caching (`--enable-prefix-caching`) + measure TTFT improvement on shared system prompts.
4. **Structured output**: guided JSON decoding, and why it matters for agent platforms.
