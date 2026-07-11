# Project 12 — Watch: An SRE Control Plane for GPU Fleets (Observability · SLOs · FinOps · AIOps)

**Difficulty:** ★★★★☆ | **Time:** 3 weekends | **Cost:** ~$5–15 (rides on top of P08–P10 clusters)

## 1. The production problem

GPU fleets fail differently from web fleets: a GPU can be "Ready" in Kubernetes while thermally throttled, ECC-erroring, or NVLink-degraded; "GPU utilization 95 %" can hide an MFU of 25 %; and a single misrouted tenant can burn $10k/week invisibly. This project turns you into the person who *runs* the platforms from P07–P11 — and it is nearly a line-for-line answer to your uploaded **Cisco AIOps JD** ("ingest signals from metrics, logs, events… anomaly detection, predictive analysis… SLA/SLO… eBPF telemetry" appears in the control-plane JD) and the staff-platform JD's SRE/FinOps asks.

## 2. Architecture

```
 Signals:  DCGM-exporter (GPU health/perf) · kube-state-metrics · vLLM /metrics
           · Beyla (eBPF RED metrics, zero-code) · Hubble/Cilium flows · training exporters (P10)
      └──▶ Prometheus (+ Thanos/Mimir optional) ──▶ Grafana suites
 SLOs:     recorded SLIs → multi-window multi-burn-rate alerts → Alertmanager
 FinOps:   OpenCost + custom GPU pricing → per-team chargeback & idle report
 AIOps:    anomaly detector (rolling z-score / Prophet) → synthetic alerts
           Alertmanager webhook → triage service → Claude API drafts diagnosis
           (fetches PromQL context + runbook) → Slack, human approves actions
```

## 3. Phase 1 — see the GPUs properly

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

**eBPF layer:** deploy **Grafana Beyla** as a DaemonSet → automatic RED metrics (rate/errors/duration) for your vLLM and FastAPI services with zero code changes; add **Cilium+Hubble** (or retain your CNI and use Hubble-less flow logs) for service-to-service flow visibility. One paragraph in your writeup on *how* eBPF does this (kprobes/uprobes on socket/SSL functions) covers the JD's eBPF checkbox honestly.

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

Add an **error-budget dashboard** (budget remaining, burn rate, projected exhaustion) and write the policy doc: what happens when budget hits zero (freeze risky rollouts). Being able to *say the 14.4 derivation* (14.4 = (30 d/6 h)·... i.e., consuming 2 % of a 30-day budget in 1 h) is instant SRE credibility.

## 5. Phase 3 — FinOps for GPUs

```bash
helm upgrade -i opencost opencost/opencost -n opencost --create-namespace \
  --set opencost.customPricing.enabled=true \
  --set opencost.customPricing.costModel.GPU=3.05      # blended $/GPU-hr; refine per flavor
```

Recording rules → monthly per-namespace: requested GPU-hours, utilized GPU-hours (weight by `SM_ACTIVE`), $ cost, **idle-$** (requested−utilized). Add: spot-vs-on-demand mix per team (Karpenter labels), and an "orphaned GPU" alert (`FB_USED < 1 GiB` for 2 h on an allocated GPU). Deliverable: a monthly cost-review one-pager template with 3 optimization actions — exactly the FinOps fluency the staff JD requests.

## 6. Phase 4 — AIOps: anomaly detection + LLM triage

**Anomaly detector** (CronJob, ~80 lines): pull 7 d of key series (TTFT p99, queue depth, `SM_ACTIVE`, XIDs) via the Prometheus HTTP API; rolling z-score (and/or Prophet forecast bands) per series; on |z|>4 sustained 10 min, POST a synthetic alert to Alertmanager (`/api/v2/alerts`) labeled `source=anomaly`. This is the pragmatic version of the JD's "anomaly detection / predictive analysis" — defensible and demoable.

**LLM triage service** (FastAPI webhook receiver — human-in-the-loop, read-only):

```python
@app.post("/alert")
async def triage(payload: dict):
    a = payload["alerts"][0]
    ctx = {q: prom(q) for q in RUNBOOK_QUERIES[a["labels"]["alertname"]]}  # e.g. top pods by queue, recent XIDs, deploy events
    msg = anthropic.messages.create(model="claude-sonnet-4-6", max_tokens=800, messages=[{
      "role":"user","content": f"You are an SRE. Alert: {a}. Metrics context: {ctx}. "
      f"Runbook: {RUNBOOKS[a['labels']['alertname']]}. Give: probable cause (ranked), "
      f"1 verification query, 1 safe mitigation. Be terse."}])
    slack_post(channel="#ai-infra-oncall", text=msg.content[0].text)
```

Guardrails to state explicitly (interviewers probe this): the agent **reads** metrics and **proposes**; mutations (restart deployment, cordon node) go through a Slack approve-button that triggers an Argo Workflow — auditable, reversible, rate-limited. Extend later with tool-use for `kubectl get` read-only commands.

## 7. Phase 5 — prove it: a game day

Run three injected incidents end-to-end and write real postmortems: (1) throttle a decode pod's CPU → TPOT slow-burn alert → triage bot fingers the noisy neighbor; (2) fake XID (P10 injector) → page → auto-remediation observed → postmortem; (3) deploy a bad model config doubling TTFT → fast-burn page within minutes → rollback via Argo. Three postmortems in your portfolio ≙ "incident response experience" on every JD.

## 8. Done criteria & interview ammo

- [ ] GPU dashboard distinguishing utilization from *efficiency* (SM/tensor-active, MFU).
- [ ] eBPF RED metrics live with zero app changes.
- [ ] Burn-rate SLO alerts firing correctly in game day (fast vs slow verified).
- [ ] Chargeback + idle-$ report; one real optimization executed.
- [ ] Anomaly→LLM-triage→Slack loop demoed; 3 postmortems written.

**Resume bullet:** *"Built the SRE control plane for a GPU platform: DCGM-based efficiency observability (SM/tensor activity vs. utilization, MFU), eBPF (Beyla/Hubble) service telemetry, multi-window burn-rate SLO alerting for TTFT/TPOT, OpenCost GPU chargeback with idle-spend reporting, and an AIOps loop (statistical anomaly detection + LLM-drafted incident triage with human-approved remediation via Argo Workflows)."*

## 9. Teardown & extensions

Stack is add-on Helm releases — uninstall cleanly. Extensions: Thanos for multi-cluster (staff-JD fleet story); drift detection on the Feast features (Udemy topic); Parca continuous profiling on the inference pods; Karpenter consolidation-savings report.
