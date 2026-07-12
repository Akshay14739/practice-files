# Project 12 — Watch: An SRE Control Plane for GPU Fleets (Observability · SLOs · FinOps · AIOps · Multi-Cluster DR)

**Difficulty:** ★★★★★ | **Time:** 6–7 weekends | **Cost:** ~$5–20 (rides on top of the P07–P11 clusters; the fleet phase runs entirely on kind for $0 — optional real-EKS GPU dispatch/DR demos add ~$0.20–0.60/hr, sessions only)

*You built the platforms in P07–P11; this is the project where you **run** them — first as a single-cluster SRE control plane (LGTM observability, burn-rate SLOs, FinOps, AIOps with anomaly detection, predictive GPU-failure scoring and an LLM RCA agent), then as a **fleet**: Cluster API provisioning, ApplicationSet rollouts, Cluster Mesh failover, MultiKueue job dispatch across clusters, and a scripted regional DR drill with a measured RTO. It is the closest thing in this series to a staff-platform job description in project form.*

**Feeds on:** [`project-07-topology-aware-gang-scheduler.md`](project-07-topology-aware-gang-scheduler.md) (Kueue) · [`project-09-disaggregated-inference-llm-d.md`](project-09-disaggregated-inference-llm-d.md) (vLLM SLIs) · [`project-10-fault-tolerant-training-goodput.md`](project-10-fault-tolerant-training-goodput.md) (XID injector, checkpoints, MFU) · [`project-11-petabyte-data-feature-platform.md`](project-11-petabyte-data-feature-platform.md) (pipeline freshness). It should end up observing [`project-13`](project-13-nvidia-tensorrt-llm-triton-factory.md)–[`project-16`](project-16-cuda-gpu-performance-engineering.md) too.

## 1. The production problem

GPU fleets fail differently from web fleets: a GPU can be "Ready" in Kubernetes while thermally throttled, ECC-erroring, or NVLink-degraded; "GPU utilization 95 %" can hide an MFU of 25 %; and a single misrouted tenant can burn $10k/week invisibly. This project turns you into the person who *runs* the platforms from P07–P11 — and it is nearly a line-for-line answer to the **Cisco AIOps JD** ("ingest signals from metrics, logs, events… anomaly detection, predictive analysis… SLA/SLO… eBPF telemetry") and the staff-platform JD's SRE/FinOps asks.

**"AIOps" here means three concrete capabilities, not buzzwords** — you build all three, grounded in signals only this domain has:

1. **Detect** what static thresholds miss — a GPU at 40 % util that is *anomalous for this job at this hour* (seasonality), a p99 drifting up 3 %/day.
2. **Predict** failures before they page — XID error acceleration, ECC creep, thermal-throttle trend → drain the node *before* the training job dies.
3. **Explain & act** — when an alert fires, an agent correlates metrics + logs + events + recent deploys and drafts the RCA + runbook step, so on-call starts at "here's the likely cause," not "let me open 6 dashboards."

And nobody senior runs *one* cluster. The staff and remote JDs ask — verbatim — for "70+ K8s clusters, multi-region AWS (EKS) and GCP (GKE)", "Cluster API (CAPI)", "MultiKueue", "Cluster Mesh for multi-datacenter connectivity", and "DRP documentation". Phase 7 grows this control plane into a fleet control plane and ends with a real disaster-recovery drill, not a doc.

## 2. Architecture

```
 Signals:  DCGM-exporter (GPU health/perf) · kube-state-metrics · vLLM /metrics
           · Beyla (eBPF RED metrics, zero-code) · Hubble/Cilium flows · training exporters (P10)
      └──▶ Prometheus / Mimir (metrics) · Loki (logs) · Tempo (traces) ──▶ Grafana suites
 SLOs:     recorded SLIs → multi-window multi-burn-rate alerts → Alertmanager
 FinOps:   OpenCost + custom GPU pricing → per-team chargeback & idle report
 AIOps:    anomaly detector (z-score / IsolationForest / Prophet) → synthetic alerts
           predictive GPU-failure scorer (XID/ECC/thermal trends) → cordon+drain
           Alertmanager webhook → RCA agent (tools: PromQL, Loki, events, deploys)
           → Slack, human approves actions
 Fleet:    a management cluster wraps all of the above and drives N workload
           clusters — CAPI · ApplicationSets · MultiKueue · Cluster Mesh (Phase 7)
```

## 3. Phase 1 — see the GPUs properly (and everything else: the LGTM stack)

DCGM-exporter comes with GPU Operator; extend its metric set (ConfigMap `dcgm-custom-metrics`) to include the ones that matter beyond `GPU_UTIL`:

```
DCGM_FI_DEV_GPU_UTIL, DCGM_FI_DEV_MEM_COPY_UTIL,
DCGM_FI_PROF_SM_ACTIVE, DCGM_FI_PROF_SM_OCCUPANCY,        # real compute activity
DCGM_FI_PROF_DRAM_ACTIVE, DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, # bandwidth vs tensor-core use
DCGM_FI_DEV_FB_USED, DCGM_FI_DEV_GPU_TEMP, DCGM_FI_DEV_POWER_USAGE,
DCGM_FI_DEV_XID_ERRORS, DCGM_FI_DEV_ECC_DBE_AGG_TOTAL,
DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL, DCGM_FI_DEV_SM_CLOCK
```

The interview insight: `GPU_UTIL` only means "a kernel was resident" — a memcpy-bound job shows 100 %. Real efficiency = `SM_ACTIVE`/`PIPE_TENSOR_ACTIVE` (+ MFU from P10). Build the Grafana panel that shows a job with 98 % GPU_UTIL and 22 % tensor-active, and explain it.

**The LGTM backbone** (the remote JD names "Grafana LGTM stack (Mimir, Loki, Tempo)" exactly):

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
- **GPU metrics** → DCGM exporter → Prometheus remote-write → **Mimir** (the metric set above).
- **LLM metrics** → vLLM `/metrics` (P09): TTFT, e2e latency, queue depth, KV-cache usage, tokens/s.
- **Pipeline metrics** → Kafka consumer lag, Spark job duration, Airflow task state (P11).
- **Logs** → Fluent Bit → **Loki** with labels `{namespace, gpu_uuid, model, job}`.
- **Traces** → OTel from your serving API → **Tempo**; exemplars link a slow trace to its metric spike.

**eBPF layer:** deploy **Grafana Beyla** as a DaemonSet → automatic RED metrics (rate/errors/duration) for your vLLM and FastAPI services with zero code changes; add **Cilium+Hubble** for service-to-service flow visibility. One paragraph in your writeup on *how* eBPF does this (kprobes/uprobes on socket/SSL functions) covers the JD's eBPF checkbox honestly.

Deliverable: a **single "AI Platform Health" Grafana dashboard** — GPU fleet utilization/thermals, per-model serving SLOs, pipeline freshness, cost (OpenCost from Phase 3) — the one pane an on-call actually opens.

## 4. Phase 2 — SLOs done properly (multi-window burn rates)

Pick user-facing SLIs from P09: availability (non-5xx), TTFT ≤ 800 ms, TPOT ≤ 40 ms. Recording rules:

```yaml
- record: sli:ttft_good:ratio_rate5m
  expr: sum(rate(vllm_time_to_first_token_seconds_bucket{le="0.8"}[5m]))
        / sum(rate(vllm_time_to_first_token_seconds_count[5m]))
```

Multi-window multi-burn-rate alert (Google SRE workbook pattern) for a 99.5 % / 30-day SLO:

```yaml
- alert: TTFT_SLO_FastBurn      # pages: burning 30d budget in ~6h
  expr: (1 - sli:ttft_good:ratio_rate5m) > 14.4 * 0.005
        and (1 - sli:ttft_good:ratio_rate1h) > 14.4 * 0.005
  labels: {severity: page}
- alert: TTFT_SLO_SlowBurn      # tickets
  expr: (1 - sli:ttft_good:ratio_rate30m) > 3 * 0.005
        and (1 - sli:ttft_good:ratio_rate6h) > 3 * 0.005
  labels: {severity: ticket}
```

Once the hand-written rules make sense, formalize the whole catalog with **Sloth** (generates multi-window burn-rate PrometheusRules from a spec):

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

Add an **error-budget dashboard** (budget remaining, burn rate, projected exhaustion) and write the policy doc: what happens when budget hits zero (freeze risky rollouts). Wire Alertmanager routing (page vs ticket vs the RCA agent) with **inhibition rules** so one root cause doesn't fan out into 20 pages, and write `docs/slo-catalog.md` defining SLIs/SLOs/budgets for GPU availability, serving latency, and pipeline freshness — the artifact every SRE-leaning JD asks for. Being able to *say the 14.4 derivation* (consuming 2 % of a 30-day budget in 1 h) is instant SRE credibility.

## 5. Phase 3 — FinOps for GPUs

```bash
helm upgrade -i opencost opencost/opencost -n opencost --create-namespace \
  --set opencost.customPricing.enabled=true \
  --set opencost.customPricing.costModel.GPU=3.05      # blended $/GPU-hr; refine per flavor
```

Recording rules → monthly per-namespace: requested GPU-hours, utilized GPU-hours (weight by `SM_ACTIVE`), $ cost, **idle-$** (requested−utilized). Add: spot-vs-on-demand mix per team (Karpenter labels), and an "orphaned GPU" alert (`FB_USED < 1 GiB` for 2 h on an allocated GPU). Deliverable: a monthly cost-review one-pager template with 3 optimization actions — exactly the FinOps fluency the staff JD requests.

## 6. Phase 4 — AIOps: anomaly detection + LLM triage

**Anomaly detector.** Start with the pragmatic CronJob (~80 lines): pull 7 d of key series (TTFT p99, queue depth, `SM_ACTIVE`, XIDs) via the Prometheus HTTP API; rolling z-score per series; on |z|>4 sustained 10 min, POST a synthetic alert to Alertmanager (`/api/v2/alerts`) labeled `source=anomaly`. Then upgrade to a resident service that scores with IsolationForest and emits anomalies as first-class Prometheus metrics (and Loki logs, so ML findings are queryable like any other signal) — `services/anomaly/detector.py`:

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

Then alert on the ML output (`aiops_anomaly_score > 0.7`). The progression to demo: static threshold (misses seasonality, fires on benign spikes) → rolling z-score → IsolationForest on residuals → mention **Prophet/ARIMA** for trend+seasonality and Grafana's built-in ML/outlier panels as the managed alternative. Validate by **injecting** a memory leak (a pod slowly claiming KV-cache) and showing the score cross before any hard threshold would. This is the defensible, demoable version of the JD's "anomaly detection / predictive analysis".

**LLM incident-RCA agent.** An Alertmanager webhook receiver that gathers evidence with real tools — logs, K8s events and recent deploys are what a human on-call correlates first — then drafts the first RCA pass. `services/rca-agent/agent.py`:

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
    resp = requests.post(f"{VLLM}/v1/chat/completions", json={     # your own P09 endpoint
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "messages": [{"role":"system","content":SYSTEM},
                     {"role":"user","content":json.dumps(evidence)[:8000]}],
        "max_tokens": 500, "temperature": 0.1}).json()
    rca = resp["choices"][0]["message"]["content"]
    post_to_slack(rca); attach_to_incident(alert, rca)             # trace it (LangFuse)
    return rca
```

Pointing it at **your own vLLM endpoint from P09** is the self-hosted / air-gapped RCA story — your platform observing itself. Swap the `requests.post` for a hosted model (`anthropic.messages.create(model="claude-sonnet-4-6", …)`) when you want a stronger reasoner on the same evidence bundle and the same output contract; keep the contract (`probable_cause`, `evidence_cited`, `blast_radius`, `recommended_action`) and the "Never invent metric values" instruction identical so the two are comparable.

Guardrails to state explicitly (interviewers probe this): the agent **reads** metrics and **proposes**; mutations (restart deployment, cordon node) go through a Slack approve-button that triggers an Argo Workflow — auditable, reversible, rate-limited. Extend later with tool-use for read-only `kubectl get`. Demo: trigger an XID alert → within seconds an RCA lands in Slack citing the specific node, the XID code, the correlated log line, and "drain node X; job Y will resume from checkpoint."

## 7. Phase 5 — predictive GPU failure (the highest-value capability)

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

Close the loop (guarded, with a dry-run flag): risk > 0.8 → **cordon + drain the node**, label it `gpu-health=suspect`, page. The demo: replay a captured XID-error burst (the P10 injector) → predictor scores → automation cordons the node → the training job's checkpoint/resume (P10) migrates it to a healthy node → **zero lost work**. That end-to-end is a staff-level story: *your monitoring prevented an outage instead of describing it.*

**Know the ecosystem you're reimplementing** (as of July 2026 — great interview material): **Node Problem Detector detects, it does not remediate** — it parses kernel logs for NVRM XID messages and publishes Node conditions/events (`GpuXid`, `GpuEcc`, `GpuNvlink`); remediation needs a second actor. Real-world pairings: NPD + **draino** to cordon/drain; AKS ships GPU health monitoring built on NPD; NVIDIA now ships **NVSentinel**, a dedicated fault-remediation service (detect → classify → cordon+drain → break-fix); AWS's EKS node monitoring agent (DCGM/NVML-based) feeds EKS auto-repair — e.g. XID 64 defaults to reboot after 10 min, configurable to replace after 5. On the Karpenter side: the NodePool/NodeClaim API is stable (`karpenter.sh/v1` since v1.0), but **Node Auto Repair is still alpha** (feature gate `NodeRepair=true`, since v1.1.0; still alpha in the v1.14 docs) and requires an agent that stamps Node status conditions — once a condition persists past its toleration, Karpenter force-terminates the node and its NodeClaim, bypassing normal drain. Your homemade predictor + the managed patterns side-by-side is exactly the "build vs buy" judgment staff interviews test.

## 8. Phase 6 — prove it: a game day

Run four injected incidents end-to-end and write real postmortems: (1) throttle a decode pod's CPU → TPOT slow-burn alert → RCA agent fingers the noisy neighbor; (2) fake XID (P10 injector) → predictor cordons the node before the hard failure → training resumes from checkpoint → postmortem documents zero lost work; (3) deploy a bad model config doubling TTFT → fast-burn page within minutes → rollback via Argo; (4) KV-cache leak injection → anomaly score crosses before any static threshold → synthetic alert → RCA draft in Slack. Postmortems in your portfolio ≙ "incident response experience" on every JD.

## 9. Phase 7 — the fleet capstone: multi-cluster, MultiKueue & a real DR drill

Everything so far ran on one cluster. This phase is the SentinelOne-staff / remote-JD territory: operate a **fleet** the way a 70-cluster shop or a GPU-neocloud does.

### The fleet operating model

One team can't `kubectl` 70 clusters. The model that scales:

```
                 ┌──────────── MANAGEMENT CLUSTER ────────────┐
                 │ Cluster API (CAPI/CAPA)  → provisions clusters│
                 │ ArgoCD (hub) + ApplicationSets  → deploys to all│
                 │ Kueue MANAGER + MultiKueue → dispatches GPU jobs│
                 │ Thanos/Mimir global query  → one metrics view │
                 └───────┬───────────────┬───────────────┬──────┘
             ┌───────────▼──┐  ┌─────────▼────┐  ┌────────▼──────┐
             │ workload:     │  │ workload:    │  │ workload:     │
             │ us-east GPU   │  │ eu-west GPU  │  │ spot-cheap    │
             │ (EKS)         │  │ (EKS/GKE)    │  │ (kind/other)  │
             └───────────────┘  └──────────────┘  └───────────────┘
                     └──── Cluster Mesh (cross-cluster services) ────┘
```

**Cost-honest lab:** the management cluster + 2–3 "workload clusters" all as **kind clusters on one box** proves every control pattern for free; swap one kind cluster for a real EKS GPU cluster only during dispatch/DR demos.

> **Version pins (verified July 2026).** This corner of the ecosystem graduates fast — MultiKueue, Argo CD Progressive Syncs, JobSet and Karpenter Node Auto Repair are all actively moving through alpha/beta. The statuses below were checked 2026-07-11; pin your releases and re-check upstream before you publish.

### 7a — Declarative cluster lifecycle with Cluster API

The remote JD asks for CAPI by name. As of July 2026, CAPI's current minor is **v1.12** (Jan 2026 — added in-place updates and chained upgrades; supports workload clusters v1.29–v1.35) and **CAPA is on its v2.x series**, actively maintained. The official CAPI quick start literally uses kind as the management cluster with the Docker provider (CAPD) — so the laptop fleet is the documented path — but the docs warn repeatedly that CAPD is **development-only**; say that out loud in the write-up and keep one real CAPA cluster for the screenshot.

```bash
# management cluster = kind
export CLUSTER_TOPOLOGY=true EXP_MACHINE_POOL=true   # CAPD needs the ClusterTopology/MachinePool experimental gates
clusterctl init --infrastructure docker              # $0 kind-in-docker fleet — or: --infrastructure aws (CAPA v2.x)
```

A cluster becomes a Git-managed object (pin the API version to whatever your `clusterctl version` installs — the Cluster API group has been rolling forward):

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata: { name: gpu-us-east, labels: { region: us-east-1, tier: gpu } }
spec:
  clusterNetwork: { pods: { cidrBlocks: ["192.168.0.0/16"] } }
  infrastructureRef: { kind: AWSCluster, name: gpu-us-east }
  controlPlaneRef: { kind: KubeadmControlPlane, name: gpu-us-east-cp }
---
# MachineDeployment = the GPU worker pool, declaratively
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata: { name: gpu-us-east-gpu-workers }
spec:
  clusterName: gpu-us-east
  replicas: 0                    # scale from Git; 0 = cost-safe default
  template:
    spec:
      infrastructureRef: { kind: AWSMachineTemplate, name: gpu-g4dn }   # g4dn instance type
```

Demo: `git commit` a new `Cluster` → CAPI provisions it → it auto-registers with the hub (7b). `clusterctl move` the mgmt state between clusters to show pivot/DR of the *management plane itself*.

### 7b — Fleet GitOps (ArgoCD ApplicationSets)

One Application definition, **auto-applied to every matching cluster** via the cluster generator (a core, stable ApplicationSet generator — the standard fleet-rollout mechanism):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: platform-baseline, namespace: argocd }
spec:
  generators:
    - clusters:
        selector: { matchLabels: { tier: gpu } }     # every GPU cluster CAPI registered
  template:
    metadata: { name: 'baseline-{{name}}' }
    spec:
      project: default
      sources:                                        # the whole platform stack, everywhere
        - { repoURL: '...', path: 'fleet/gpu-operator', targetRevision: main }
        - { repoURL: '...', path: 'fleet/dcgm-monitoring', targetRevision: main }
        - { repoURL: '...', path: 'fleet/kueue-worker', targetRevision: main }
      destination: { server: '{{server}}' }
      syncPolicy: { automated: { prune: true, selfHeal: true } }
```

Now GPU Operator + DCGM + Kueue-worker land on **every** GPU cluster automatically, and a new cluster is production-ready the moment CAPI registers it. Add an **overlay generator** (git-directories) so `region: eu-west` clusters get data-residency policies (Kyverno). For staged fleet rollouts, ApplicationSet **Progressive Syncs** (RollingSync — canary a change to 10 % of clusters, wait for Healthy, continue) exists but know its status: **beta since Argo CD v3.3.0 and still opt-in** (`--enable-progressive-syncs` on the ApplicationSet controller) as of July 2026 — not alpha, not GA. This is fleet management — the SentinelOne JD's core.

### 7c — Cross-cluster connectivity (Cluster Mesh)

Services in cluster A reach cluster B by name — required for cross-region failover (and for the disaggregated-serving patterns in P09/P14). Two documented paths:

- **Cilium Cluster Mesh:** `cilium clustermesh enable` on each, `cilium clustermesh connect --context A --context B`; global services via `service.cilium.io/global: "true"` — pods load-balance across clusters transparently.
- **Istio multi-primary:** shared trust root, east-west gateways, endpoint discovery across clusters.

Demo: a global `InferencePool`-fronted vLLM Service (P09 gateway) where cluster A's gateway fails over to cluster B's pods when A's are drained — cross-cluster resilience, shown. (On kind, Cilium Cluster Mesh between two kind clusters works and is the free path.)

### 7d — MultiKueue: schedule GPU jobs across the fleet

The payoff. Submit a training job to the **manager**; MultiKueue dispatches it to whichever worker cluster has free GPU quota — or the cheapest.

> **Status (July 2026): MultiKueue is beta, not GA.** Introduced as alpha in Kueue v0.6.0 (Feb 2024), promoted to beta in v0.9 and enabled by default; the docs still say "currently a beta feature" as of Kueue v0.18 (May 2026; latest releases v0.18.3 / v0.17.7). Only sub-feature gates have gone stable (`MultiKueueBatchJobWithManagedBy` in v0.17; `MultiKueueWaitForWorkloadAdmitted` + `MultiKueueRedoAdmissionOnEvictionInWorker` in v0.18). What *did* go GA is the **`batch/v1` Job `.spec.managedBy` field — stable in Kubernetes v1.35** (Dec 2025) — which MultiKueue relies on to dispatch plain Jobs. Don't conflate the two in an interview; knowing the difference is the flex.

Setup requirements (per the official docs): Kueue + CRDs on the manager **and** every worker; `ResourceFlavor`/`ClusterQueue`/`LocalQueue` on the workers; a restricted-RBAC kubeconfig per worker stored as a Secret in the manager's `kueue-system` namespace. Then on the manager:

```yaml
# management cluster: worker clusters + admission check
apiVersion: kueue.x-k8s.io/v1beta1
kind: MultiKueueCluster
metadata: { name: gpu-us-east }
spec: { kubeConfig: { locationType: Secret, location: us-east-kubeconfig } }
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: MultiKueueConfig
metadata: { name: gpu-fleet }
spec: { clusters: [gpu-us-east, gpu-eu-west, gpu-spot-cheap] }
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: AdmissionCheck
metadata: { name: multikueue }
spec:
  controllerName: kueue.x-k8s.io/multikueue
  parameters: { apiGroup: kueue.x-k8s.io, kind: MultiKueueConfig, name: gpu-fleet }
```

A ClusterQueue referencing that AdmissionCheck (via `admissionChecksStrategy`) now spans clusters: the manager mirrors admitted Workloads onto workers and propagates status back (a configurable dispatcher — incremental vs all-at-once — landed in v0.13). Submit the **P10 training job** to the manager → watch it land where capacity exists → results/status stream back. Scenarios: us-east full → job runs in eu-west; add `spot-cheap` with higher quota → jobs prefer it (**capacity arbitrage**). This is global GPU scheduling — the fleet-scale sequel to what P07 did on one cluster.

Two integration details worth stating precisely: Kubeflow Trainer workloads on the workers need **Trainer v1.7.0+**, and if you dispatch multi-node jobs as a **JobSet**, note it is still `jobset.x-k8s.io/v1alpha2` (latest release v0.12.0, which added pod-level elastic scaling and finer-grained restart actions) — no beta/GA graduation has shipped, and it needs a cluster on one of the last 3 Kubernetes minors.

**The arbitrage brain (stretch, but the flex):** a Python controller that reads each cluster's spot price (AWS/GCP pricing APIs) + free GPU quota + your Phase-4 demand forecast, and re-weights MultiKueue placement toward the cheapest capacity that meets the job's region/data constraints. That's a **FinOps scheduler** — write the design even if you only demo a stub.

### 7e — Regional DR drill (with real failover)

`docs/DR-PLAN.md` + an executed drill, not just a doc:

- **Define RPO/RTO** per component: stateless serving (RTO minutes, RPO 0), Kafka (RPO = replication lag), feature/offline store (P11 — RPO = snapshot interval), MLflow/Postgres (RPO = backup interval), model artifacts + training checkpoints in S3 (cross-region replication, RPO ~0).
- **Backup/restore:** Velero for cluster state; S3 CRR for artifacts; scheduled DB snapshots to another region.
- **The drill (record it):** with traffic running through the mesh, **destroy the primary GPU cluster** (`clusterctl delete cluster gpu-us-east`). Observe: mesh fails serving over to eu-west; MultiKueue re-dispatches in-flight training (resumes from S3 checkpoints — P10); GitOps rebuilds a replacement cluster from CAPI manifests. Measure **actual RTO** vs target and actual RPO per component; write the **postmortem**.

**What "training resumes" actually costs you** (be precise — this is where interviews go): with `torchrun --nnodes=MIN:MAX --max-restarts=N --rdzv-backend=c10d`, a membership change is a **group restart** — *all* workers stop and restart with new `RANK`/`WORLD_SIZE`, not a single-worker hot-swap — so your RTO includes a full rendezvous + checkpoint reload. That reload is bounded by your checkpoint interval, which is why `torch.distributed.checkpoint.async_save()` matters (PyTorch ≥ 2.4; still flagged *"experimental and subject to change"* in the 2.13 docs; PyTorch 2.9 added `DefaultStager` for background GPU→CPU staging — keep one async checkpoint in flight at a time, and budget CPU memory ≈ checkpoint_size_per_rank × ranks). If you want per-step fault tolerance *without* a group restart, **TorchFT** (Lighthouse + per-replica-group Manager, fault-tolerant HSDP) is the thing to name — but call it what it is: **experimental, no versioned release, nightly wheels only**, though demonstrated at scale (the PyTorch blog trained Llama through ~2000 synthetic failures every ~15 s with no checkpoint recovery). Report your RTO with the mechanism attached: "RTO = mesh failover (measured) + rendezvous + checkpoint reload (measured)."

The GPU-neocloud and remote JDs both explicitly want DRP + postmortems + chaos — this is that, at fleet scale.

### 7f — Global observability & cost governance

- **Metrics:** Thanos or Mimir remote-write from every cluster → one Grafana with a `cluster` label → global fleet health. This is where Phases 1–6 stop being single-cluster: every dashboard, burn-rate alert, and anomaly signal gets a `cluster` dimension.
- **Cost:** OpenCost per cluster → aggregated report: **$/team/cluster/region and $/GPU-hour by provider** — the input to arbitrage and the artifact every FinOps-flavored JD wants. Add "cost of DR standby capacity" as a line item (the honest trade-off conversation).
- **Capacity forecasting:** feed the Phase-4 demand model per region → 6–12 month GPU capacity plan (remote JD, verbatim ask).

## 10. Done criteria & interview ammo

- [ ] GPU dashboard distinguishing utilization from *efficiency* (SM/tensor-active, MFU).
- [ ] Unified "AI Platform Health" board: GPU + LLM + pipeline + cost on one pane (Mimir/Loki/Tempo wired).
- [ ] eBPF RED metrics live with zero app changes.
- [ ] Burn-rate SLO alerts firing correctly in game day (fast vs slow verified); Sloth-generated rules + error-budget dashboard live.
- [ ] Chargeback + idle-$ report; one real optimization executed.
- [ ] Anomaly detector catches an injected KV-cache leak before a static threshold.
- [ ] RCA agent posts a correctly-cited draft on a real alert (self-hosted vLLM variant demoed).
- [ ] Predictor cordons a node on a replayed XID burst; training resumes elsewhere (zero lost work).
- [ ] 4 postmortems written.
- [ ] New cluster created from a Git commit via CAPI; auto-registered to the hub; ApplicationSet configures it hands-free.
- [ ] Cross-cluster global service fails over A→B under drain.
- [ ] MultiKueue dispatches a training job to a remote cluster by capacity, then by cost.
- [ ] DR drill executed: primary destroyed, serving + training + cluster recovered; RTO/RPO measured vs target; postmortem written.
- [ ] Global Grafana + multi-cluster cost report live.

**Resume bullet:** *"Built and operated the SRE control plane for a multi-cluster GPU platform: DCGM-based efficiency observability (SM/tensor activity vs. utilization, MFU) on the Grafana LGTM stack, eBPF (Beyla/Hubble) service telemetry, multi-window burn-rate SLO alerting for TTFT/TPOT, OpenCost GPU chargeback with idle-spend reporting, an AIOps loop (IsolationForest anomaly detection, predictive GPU-failure scoring from XID/ECC/thermal trends that auto-drains suspect nodes, and an LLM RCA agent that correlates metrics/logs/events/deploys into a cited root cause with human-approved remediation via Argo Workflows) — then scaled it to a fleet: Cluster API declarative cluster lifecycle, ArgoCD ApplicationSets rolling the platform baseline to every cluster, Cilium Cluster Mesh failover, MultiKueue dispatching training jobs across regions by capacity and spot price, and a regional DR drill that destroyed the primary and recovered serving + checkpointed training within measured RTO."*

Whiteboard-ready: why static thresholds fail on seasonal GPU workloads; which DCGM signals predict failure and why; multi-window multi-burn-rate math (the 14.4 derivation); keeping LLM automation advisory (blast-radius control); NPD detects vs Karpenter Node Auto Repair (alpha) remediates; hub-and-spoke fleet model and why ApplicationSets over per-cluster Apps; MultiKueue dispatch semantics and its beta status vs Job `.spec.managedBy` GA; torchrun's group-restart semantics vs TorchFT's per-step recovery; RPO/RTO per stateful component; the cost of DR standby vs the cost of an outage; capacity-arbitrage constraints (data residency, egress, quota).

## 11. Teardown

The observability stack is add-on Helm releases — uninstall cleanly, or keep it running across other projects as your permanent lab observability (it *should* observe P07–P16; it's CPU-cheap). For the fleet: `clusterctl delete cluster --all` (or `kind delete clusters --all`); confirm zero NodeClaims and no MachineDeployments at `replicas > 0`; Velero backups and S3 artifacts retained or purged deliberately. GPU workloads follow their own session economics.

## 12. Extensions

1. **Trace-to-metric exemplars**: click a p99 spike → jump to the exact Tempo trace of that request.
2. Train a tiny **LSTM/Prophet** forecaster for GPU-hours demand → feed the 6–12 month capacity plan and the arbitrage brain.
3. Give the RCA agent a **runbook retrieval tool** (RAG over your P07–P16 runbooks) so it cites *your* procedures.
4. **Chaos + AIOps loop**: Chaos Mesh injects failures on a schedule; measure MTTD/MTTR improvement from the anomaly+RCA pipeline.
5. **Drift detection** on the Feast features (P11); **Parca** continuous profiling on the inference pods; Karpenter **consolidation-savings report**.
6. **Immutable OS** workers (Talos Linux via CAPI's Talos bootstrap) — the remote JD's "Talos/Flatcar" nice-to-have; write the diff vs AL2023.
7. **vCluster** virtual clusters as cheap per-team "clusters" within one real cluster — merges the hard-multi-tenancy story with fleet ops.
8. **Progressive fleet rollout in anger**: enable ApplicationSet Progressive Syncs (beta since Argo CD v3.3.0, `--enable-progressive-syncs`) and canary a platform change to 10 % of clusters before fleet-wide.
9. **Policy fleet**: Kyverno policies distributed and reported centrally (Policy Reporter) across all clusters for SOC2/ISO evidence.

## 📣 Build in public

- **LinkedIn post angle:** "Your GPU dashboard is lying to you" — screenshot your Grafana panel showing the same job at 98 % `GPU_UTIL` and 22 % tensor-core-active, next to your monthly idle-$ number from the OpenCost chargeback report; walk through why `GPU_UTIL` only means "a kernel was resident" and what `SM_ACTIVE`/`PIPE_TENSOR_ACTIVE` revealed about where the money actually went.
- **X/Twitter thread angle:** live-thread the DR drill from the drill log — one tweet per timeline event: `clusterctl delete cluster gpu-us-east` at T+0, mesh failing serving over to eu-west, MultiKueue re-dispatching the training job, torchrun re-rendezvousing and reloading the last checkpoint, GitOps rebuilding the replacement cluster from CAPI manifests, and the closer: your measured RTO vs the target you wrote in `DR-PLAN.md`, plus the one component that blew its RPO.
- **YouTube demo-video angle:** the zero-lost-work run, end-to-end on screen — replay the captured XID burst, watch `gpu_failure_risk` cross 0.8, the automation cordon the node, training resume from checkpoint on a healthy node, and the RCA draft from your *own* vLLM land in Slack citing the exact node, XID code, and correlated log line — then diff your homemade predictor against the managed patterns (NPD+draino, NVSentinel, Karpenter Node Auto Repair alpha) as the build-vs-buy discussion.
