# Project 11 — AIOps & Full-Stack Observability for a GPU/ML Platform

> Build the exact system the Cisco Platform JD describes: *"intelligent agentic frameworks ingesting metrics, logs, events… Anomaly Detection, Predictive analysis."* A complete **LGTM observability stack** (Loki/Grafana/Tempo/Mimir) wired for **GPU + LLM + pipeline** signals, plus an **anomaly-detection service**, **predictive GPU-failure** from DCGM XID trends, an **LLM-powered incident RCA agent**, and **SLO burn-rate automation** — the AIOps layer over everything you've built.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 4 weekends |
| **Prereq** | Any of P1–P10 running to observe (P2+P3 ideal — GPU serving + pipelines) |
| **Cloud cost** | Observability is CPU-only; reuse existing GPU workloads during their sessions. ~$0/hr for the stack itself. |
| **Skills proven** | Grafana LGTM stack ops, OpenTelemetry pipelines, GPU/LLM metric design, time-series anomaly detection, predictive maintenance, LLM-RCA agent (tool-calling over Prometheus/Loki), multi-window burn-rate SLOs, alert routing |
| **JD keywords hit** | "AIOps platforms or intelligent monitoring systems" · "Anomaly Detection, Predictive analysis" · "ML based subsystems for data intensive tasks" · "SLA/SLO metrics" · "Grafana LGTM stack (Mimir, Loki, Tempo)" (remote JD, verbatim) |

---

## 1. What "AIOps" actually means here (not buzzwords)

Three concrete capabilities on top of monitoring:

1. **Detect** what static thresholds miss — a GPU at 40% util that's *anomalous for this job at this hour* (seasonality), a p99 drifting up 3%/day.
2. **Predict** failures before they page — DCGM XID error acceleration, ECC error creep, thermal throttling trend → drain the node *before* the training job dies.
3. **Explain & act** — when an alert fires, an agent correlates metrics+logs+events+recent deploys and drafts the RCA + runbook step, so on-call starts at "here's the likely cause" not "let me open 6 dashboards."

You'll build all three, grounded in the GPU/ML signals only this domain has.

## 2. Phase 1 — The LGTM stack (the remote JD names it exactly)

```bash
# Mimir (metrics, long-term) · Loki (logs) · Tempo (traces) · Grafana
helm repo add grafana https://grafana.github.io/helm-charts
helm install mimir  grafana/mimir-distributed -n obs --create-namespace -f mimir-values.yaml
helm install loki   grafana/loki -n obs -f loki-values.yaml
helm install tempo  grafana/tempo -n obs
helm install grafana grafana/grafana -n obs -f grafana-values.yaml
# OTel Collector as the ingestion funnel
helm install otel open-telemetry/opentelemetry-collector -n obs -f otel-values.yaml
```

**Signal wiring (the domain-specific part):**
- **GPU metrics** → DCGM exporter (from P1) → Prometheus remote-write → **Mimir**. Key series: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_XID_ERRORS`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_PROF_SM_ACTIVE` (real SM occupancy vs coarse util).
- **LLM metrics** → vLLM `/metrics` (from P2/P10): TTFT, e2e latency, queue, KV-cache, tokens/s.
- **Pipeline metrics** → Kafka consumer lag, Spark job duration, Airflow task state (from P3).
- **Logs** → Fluent Bit → **Loki** with labels `{namespace, gpu_uuid, model, job}`.
- **Traces** → OTel from the RAG API (P4) → **Tempo**; exemplars link a slow trace to its metric spike.

Deliverable: a **single "AI Platform Health" Grafana dashboard** — GPU fleet utilization/thermals, per-model serving SLOs, pipeline freshness, cost (OpenCost from P6) — the one pane an on-call actually opens.

## 3. Phase 2 — Anomaly detection service

`services/anomaly/detector.py` — pulls series from Mimir, scores them, emits anomalies as Prometheus metrics + Loki logs (so alerts and dashboards treat ML findings as first-class):

```python
"""Multi-signal anomaly detector for GPU/LLM telemetry."""
import time, requests, numpy as np
from prometheus_client import start_http_server, Gauge
from sklearn.ensemble import IsolationForest

MIMIR = "http://mimir-nginx.obs.svc/prometheus"
anom = Gauge("aiops_anomaly_score", "anomaly score", ["signal", "gpu"])

def query_range(expr, minutes=180, step=60):
    end = int(time.time()); start = end - minutes*60
    r = requests.get(f"{MIMIR}/api/v1/query_range",
                     params={"query": expr, "start": start, "end": end, "step": step})
    return r.json()["data"]["result"]

def detect(expr, signal):
    for s in query_range(expr):
        gpu = s["metric"].get("gpu", s["metric"].get("UUID", "agg"))
        vals = np.array([float(v[1]) for v in s["values"]]).reshape(-1, 1)
        if len(vals) < 30:
            continue
        # seasonal-naive baseline + IsolationForest on residuals
        model = IsolationForest(contamination=0.05, random_state=0).fit(vals[:-5])
        score = -model.score_samples(vals[-1:])[0]     # higher = more anomalous
        anom.labels(signal=signal, gpu=gpu).set(score)

SIGNALS = {
    "gpu_util":  "DCGM_FI_DEV_GPU_UTIL",
    "ttft_p95":  'histogram_quantile(0.95, sum by (le)(rate(vllm:time_to_first_token_seconds_bucket[5m])))',
    "kafka_lag": "sum(kafka_consumergroup_lag) by (consumergroup)",
    "gpu_temp":  "DCGM_FI_DEV_GPU_TEMP",
}

if __name__ == "__main__":
    start_http_server(9108)
    while True:
        for sig, expr in SIGNALS.items():
            try: detect(expr, sig)
            except Exception as e: print("err", sig, e)
        time.sleep(60)
```

Then alert on the ML output (`aiops_anomaly_score > 0.7`). Progression to demo: static threshold (misses seasonal + fires on benign spikes) → IsolationForest residuals → mention **Prophet/ARIMA** for trend+seasonality and Grafana's built-in ML/outlier panels as the managed alternative. Validate by **injecting** a memory leak (a pod slowly claiming KV-cache) and showing the score cross before any hard threshold would.

## 4. Phase 3 — Predictive GPU failure (the highest-value capability)

GPUs fail with warning signs. **XID errors, ECC (double-bit) counts, thermal throttling, and power anomalies trend before a hard failure.** `services/predictor/gpu_health.py`:

```python
"""Predict GPU node health from DCGM trends → drain BEFORE the job dies."""
import requests, numpy as np
from prometheus_client import start_http_server, Gauge
risk = Gauge("gpu_failure_risk", "0-1 predicted failure risk", ["node", "gpu"])

def slope(vals):                       # simple trend detector
    x = np.arange(len(vals)); return np.polyfit(x, vals, 1)[0] if len(vals) > 5 else 0.0

def score_node(node, gpu, xid, ecc, temp):
    r = 0.0
    r += min(0.5, 0.1 * sum(xid[-10:]))           # any recent XID is bad
    r += 0.3 if slope(ecc) > 0 else 0.0           # rising double-bit ECC → dying VRAM
    r += 0.2 if max(temp[-10:], default=0) > 85 else 0.0
    risk.labels(node=node, gpu=gpu).set(min(1.0, r))
    return r
```

Close the loop (guarded, with a dry-run flag): risk > 0.8 → **cordon + drain the node**, label it `gpu-health=suspect`, page. The demo: replay a captured XID-error burst → predictor scores → automation cordons the node → the training job's checkpoint/resume (P5) migrates it to a healthy node → **zero lost work**. That end-to-end is a staff-level story: *your monitoring prevented an outage instead of describing it.*

## 5. Phase 4 — LLM incident-RCA agent

When an alert fires, an agent (calling **your own vLLM** from P2, closing the loop) gathers evidence via tools and drafts the first RCA pass. `services/rca-agent/agent.py`:

```python
"""On alert → gather metrics/logs/events/deploys → LLM drafts RCA + next step."""
import requests, json

TOOLS = {
  "prom":   lambda q: requests.get(f"{MIMIR}/api/v1/query", params={"query": q}).json(),
  "loki":   lambda q: requests.get(f"{LOKI}/loki/api/v1/query_range",
                                   params={"query": q, "limit": 50}).json(),
  "events": lambda ns: run(f"kubectl get events -n {ns} --sort-by=.lastTimestamp"),
  "deploys":lambda ns: run(f"kubectl rollout history deploy -n {ns}"),
}

SYSTEM = ("You are an SRE assistant for a GPU/ML platform. Given an alert and "
          "evidence, output: probable_cause, evidence_cited, blast_radius, "
          "recommended_action. Be specific. Never invent metric values.")

def handle_alert(alert):               # Alertmanager webhook payload
    ns = alert["labels"].get("namespace", "default")
    evidence = {
      "alert": alert,
      "gpu": TOOLS["prom"]("DCGM_FI_DEV_XID_ERRORS > 0"),
      "logs": TOOLS["loki"](f'{{namespace="{ns}"}} |= "error"'),
      "events": TOOLS["events"](ns),
      "recent_deploys": TOOLS["deploys"](ns),
    }
    resp = requests.post(f"{VLLM}/v1/chat/completions", json={
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "messages": [{"role":"system","content":SYSTEM},
                     {"role":"user","content":json.dumps(evidence)[:8000]}],
        "max_tokens": 500, "temperature": 0.1}).json()
    rca = resp["choices"][0]["message"]["content"]
    post_to_slack(rca); attach_to_incident(alert, rca)     # LangFuse-traced (P4)
    return rca
```

Wire Alertmanager → this webhook. Demo: trigger the XID alert → within seconds an RCA lands in Slack citing the specific node, the XID code, the correlated log line, and "drain node X; job Y will resume from checkpoint." Keep it **advisory** (human approves actions) — and say that boundary out loud; it's the responsible-automation answer interviewers want. This is the JD's "LLM-based agents / intelligent automation workflows," built.

## 6. Phase 5 — SLO engineering & burn-rate automation

Formalize P6's SLOs across the platform with **Sloth** (generates multi-window burn-rate rules from a spec):

```yaml
# sloth spec → generated PrometheusRules
service: "llm-serving"
slos:
  - name: "availability"
    objective: 99.5
    sli:
      events:
        error_query: sum(rate(vllm:request_failure_total[{{.window}}]))
        total_query: sum(rate(vllm:request_total[{{.window}}]))
    alerting:
      page_alert:   { labels: { severity: critical } }   # fast burn
      ticket_alert: { labels: { severity: warning } }    # slow burn
```

Deliverables: an **error-budget dashboard** per service (availability + latency SLOs, budget remaining, burn rate), and Alertmanager routing (page vs ticket vs the RCA agent) with inhibition rules so one root cause doesn't fan out into 20 pages. The write-up (`docs/slo-catalog.md`) defines SLIs/SLOs/budgets for GPU availability, serving latency, and pipeline freshness — the artifact every SRE-leaning JD asks for.

## 7. Validation checklist

- [ ] Unified health dashboard: GPU + LLM + pipeline + cost on one board
- [ ] Anomaly detector catches an injected KV-cache leak before a static threshold
- [ ] Predictor cordons a node on replayed XID burst; training resumes elsewhere (zero lost work)
- [ ] RCA agent posts a correctly-cited draft on a real alert
- [ ] Burn-rate alerts fire fast/slow correctly; error-budget dashboard live

## 8. Teardown

Stack is CPU-cheap — you may keep it running across other projects as your permanent lab observability (it *should* observe P7–P15). GPU workloads follow their own session economics.

## 9. Interview ammunition

- *"Built the AIOps layer for a GPU/ML platform on the Grafana LGTM stack: DCGM/vLLM/pipeline telemetry unified in one health view, IsolationForest anomaly detection on serving and GPU signals, predictive GPU-failure from XID/ECC/thermal trends that auto-drains suspect nodes (training resumes from checkpoint — zero lost work), and an LLM RCA agent that correlates metrics/logs/events/deploys into a cited first-pass root cause, with Sloth multi-window burn-rate SLOs."*
- Whiteboard-ready: why static thresholds fail on seasonal GPU workloads; which DCGM signals predict failure and why; multi-window multi-burn-rate math; keeping LLM automation advisory (blast-radius control); SLI/SLO/error-budget design for GPU availability.

## 10. Stretch goals

1. **Trace-to-metric exemplars**: click a p99 spike → jump to the exact Tempo trace of that request (RAG path from P4).
2. Train a tiny **LSTM/Prophet** forecaster for GPU-hours demand → feed proactive capacity (the remote JD's "6–12 month forecasting").
3. Give the RCA agent a **runbook retrieval tool** (RAG over your P4–P15 runbooks) so it cites *your* procedures.
4. **Chaos + AIOps loop**: Chaos Mesh injects failures on a schedule; measure MTTD/MTTR improvement from the anomaly+RCA pipeline.
