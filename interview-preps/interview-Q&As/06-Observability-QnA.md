# Observability & Monitoring — Interview Q&A

Real questions from Akshay's past interviews on Prometheus, Grafana, ELK, Loki, alerting and SLO/SLI/error budgets. Each entry keeps the faithful transcript answer, then an authoritative correct answer with a copy-ready snippet — ordered by sub-theme with weak/partial answers first so the gaps get fixed first.

---

# Observability fundamentals & experience

## Q1. Have you worked on the observability pipeline?
**Asked in:** Compunnel  |  **My performance:** Partial

**My answer (from transcript):**
Set up dashboards, alerts and alerting mechanisms with runbooks. Clarified he did not develop a pipeline "per se", but built dashboards/alerts and alerting by integrating with xMatters and Slack.

**✅ Correct answer:**
An observability *pipeline* is the end-to-end flow: **instrument → collect → process/enrich → store → visualize/alert.** For metrics that's `app /metrics` endpoint → exporter/scrape → Prometheus TSDB → Grafana + Alertmanager. For logs it's `app stdout` → node agent (Filebeat/Fluent Bit/Promtail) → aggregator/buffer (Logstash/Kafka) → store (Elasticsearch/Loki) → Kibana/Grafana. For traces it's SDK → OpenTelemetry Collector → Tempo/Jaeger. Even if you "only" built dashboards and alerting, you *did* own the collect→store→visualize→alert stages — frame it that way: "I owned the collection, storage, dashboarding and alert-routing stages of the pipeline; instrumentation was on the app teams." That is a pipeline.

```yaml
# The pipeline as a mental model (OpenTelemetry Collector config)
receivers:      # 1. COLLECT
  otlp: { protocols: { grpc: {}, http: {} } }
processors:     # 2. PROCESS / ENRICH
  batch: {}
  resourcedetection: { detectors: [env, k8s] }
exporters:      # 3. STORE
  prometheusremotewrite: { endpoint: http://mimir:9009/api/v1/push }
  loki: { endpoint: http://loki:3100/loki/api/v1/push }
service:
  pipelines:
    metrics: { receivers: [otlp], processors: [batch], exporters: [prometheusremotewrite] }
    logs:    { receivers: [otlp], processors: [batch], exporters: [loki] }
```

---

## Q2. What observability tools have you worked with — Prometheus/Grafana?
**Asked in:** Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
Honestly said he wished he'd worked on Prometheus/Grafana but was given the ELK/Elasticsearch stack; developed dashboards, alerts, and alert-trigger mechanisms integrated with the ELK stack.

**✅ Correct answer:**
Honesty is good, but you should immediately bridge the transferable concepts so the "no Prometheus" doesn't read as a hard gap. The ELK skills map cleanly: **KQL ↔ PromQL**, **Kibana ↔ Grafana**, **Elasticsearch Watcher/Kibana rules ↔ Alertmanager**, **Filebeat/Elastic Agent ↔ node_exporter + scrape**. Prometheus is a **pull-based, metrics-first TSDB** (it scrapes `/metrics` endpoints on an interval and stores numeric time series with labels), whereas ELK is **push-based and log-first** (agents ship documents to Elasticsearch). Grafana is the visualization layer that queries *both* (Prometheus, Loki, Elasticsearch, CloudWatch) so it's the natural place to converge. Say: "I built the equivalent muscle in ELK; the Prometheus/Grafana model is pull-scrape + PromQL + Alertmanager and I can pick it up quickly because the concepts overlap."

```promql
# The Prometheus equivalent of "is this pod healthy?" — one line, no agent-shipped docs
sum by (namespace, pod) (
  kube_pod_status_phase{phase!="Running"}
) > 0
```

---

## Q3. Have you worked on native cloud tools like AWS CloudWatch?
**Asked in:** Compunnel  |  **My performance:** Partial

**My answer (from transcript):**
Their tooling was integrated with CloudWatch, but primarily used Elasticsearch/Kibana; has not exclusively worked on CloudWatch.

**✅ Correct answer:**
CloudWatch is AWS's native metrics + logs + alarms service. Know the four building blocks: **Metrics** (namespaces like `AWS/EC2`, `ContainerInsights`), **Logs** (log groups/streams, queried with **CloudWatch Logs Insights**), **Alarms** (threshold or anomaly-detection alarms that fire to SNS), and **Dashboards**. For EKS, **Container Insights** + the CloudWatch agent (as a DaemonSet) gives pod/node CPU, memory and container metrics without Prometheus. A strong follow-up: many teams scrape CloudWatch into Prometheus/Grafana via **YACE (yet-another-cloudwatch-exporter)** so cloud-native and self-hosted metrics live in one pane. Position yourself as "exposed via integration, comfortable with the model, alarm→SNS→Slack flow is analogous to my alert→xMatters/Slack flow."

```bash
# CloudWatch Logs Insights query (the KQL-equivalent) — top 5xx-generating paths
aws logs start-query \
  --log-group-name /eks/app/prod \
  --start-time $(date -d '1 hour ago' +%s) --end-time $(date +%s) \
  --query-string 'fields @timestamp, path, status
                  | filter status >= 500
                  | stats count(*) as errors by path
                  | sort errors desc | limit 5'
```

---

## Q4. What is the difference between observability and monitoring?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Observability is fetching details of the current infrastructure (dashboards showing current cluster/app status); monitoring is acting on that information (preventive solutions via alerts, runbooks, or AI-integrated automated solutions) to reduce MTTR when the platform goes down.

**✅ Correct answer:**
Good instinct; tighten the textbook framing. **Monitoring** = watching a *known, predefined* set of signals and alerting when they cross thresholds — it answers "**is the system working?**" (known-unknowns). **Observability** = the property of a system that lets you ask *arbitrary, new* questions about its internal state from its external outputs *without shipping new code* — it answers "**why is it broken?**" (unknown-unknowns). Observability is built on the **three pillars: metrics, logs, traces** (increasingly a fourth: continuous profiling). Monitoring is a *use case on top of* observability data. Your MTTR point is spot-on: high-cardinality, well-correlated telemetry is what lets you go from "an alert fired" to "here's the exact failing dependency" quickly.

```promql
# Monitoring = a fixed question with a threshold (known-unknown)
100 * (rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])) > 1

# Observability = slice the SAME data any new way at query time (unknown-unknown),
# e.g. "which customer + endpoint + version is driving the 5xx spike right now?"
topk(10, sum by (customer, path, version) (rate(http_requests_total{status=~"5.."}[5m])))
```

---

## Q5. Describe your observability stack — what you set up and the reasoning / what you achieved.
**Asked in:** HDFC, Persistent, HTC-1, HCL, PwC-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Built enterprise-scale observability for a "golden path" Kubernetes platform. Critical platform apps (ArgoCD, Crossplane, K8s control plane, Istio, Infisical) needed ~99% uptime — if any went down all deployments were affected. Set up availability dashboards monitoring pod status: if a pod stays in CrashLoopBackOff/ImagePull/OOM/Pending for over a minute, trigger a Slack alert containing the error message, the duration, and a runbook Confluence link (which he authored) for the on-call engineer, to reduce MTTR. xMatters phones on-call for P0/P1; everything else goes to Slack. Used ELK/Elasticsearch + Kibana, integrated with xMatters and Slack.

**✅ Correct answer:**
This is a strong, well-structured answer — keep the "critical platform apps → availability SLO → pod-state alerts → runbook → MTTR" narrative. Two upgrades to make it senior-grade: (1) name the **collection layer precisely** — the log-shipper is **Filebeat/Elastic Agent (DaemonSet)**, and pod *state* actually comes from **kube-state-metrics / the Kubernetes API**, not from a log agent (see Q9–Q11). (2) State the **golden signals** you monitored explicitly: latency, traffic, errors, saturation. Then the story lands as "I owned collection → storage → dashboards → severity-based routing (xMatters P0/P1, Slack rest) → runbook-driven remediation."

```yaml
# The reasoning encoded: a Prometheus alert that mirrors your pod-state rule
- alert: PlatformPodNotReady
  expr: |
    sum by (namespace, pod) (
      kube_pod_status_phase{namespace=~"argocd|crossplane|istio-system", phase!="Running"}
    ) > 0
  for: 1m                                  # "stuck for more than a minute"
  labels: { severity: critical }
  annotations:
    summary: "{{ $labels.pod }} not Running in {{ $labels.namespace }}"
    runbook_url: "https://confluence/runbooks/{{ $labels.namespace }}"
```

---

# Prometheus / PromQL

## Q6. We considered Datadog / Splunk / Prometheus for this — thoughts?
**Asked in:** Accion-2  |  **My performance:** Partial

**My answer (from transcript):**
They tried integrating Splunk but it didn't work as expected; Python and shell scripts gave much better results than Splunk, so they went with scripts and just had to fine-tune them. (Opinion-based; brief.)

**✅ Correct answer:**
"Scripts beat Splunk" is a weak stance in a senior interview — it signals reinventing a solved problem. Give a **decision framework** instead: **Prometheus** = free, self-hosted, pull-based *metrics*, best for infra/K8s (huge exporter ecosystem, native ServiceMonitor CRDs); scales to long-term via **Thanos/Mimir**. **Datadog** = SaaS, all-pillars (metrics+logs+traces+APM) with low ops burden but per-host/per-GB cost that explodes at scale. **Splunk** = powerful log *analytics/SIEM*, premium priced, overkill for pure metrics. Custom scripts pushing to a DB are fine for a *bespoke aggregation* (like the deploy-version dashboard) but shouldn't replace a metrics platform — they lack alerting, retention, cardinality handling and a query language. Frame: "For ad-hoc cross-tool aggregation, scripts were pragmatic; for standing infra monitoring I'd standardize on Prometheus+Grafana (cost) or Datadog (speed-to-value), not scripts."

```yaml
# Why Prometheus wins for K8s infra: declarative scrape targets, zero glue scripts
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: app, labels: { release: kube-prometheus-stack } }
spec:
  selector: { matchLabels: { app: my-app } }
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

---

# Grafana / Kibana dashboards

## Q7. Design brainstorm: one dashboard showing each environment's deployed versions and deploy time, aggregating GitHub pipelines, Octopus Deploy, and AWS CodeBuild/CodePipeline. How would you start?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
Install the Elasticsearch agent across all clusters. Write per-tool Python scripts (different API calls per platform) to fetch each tool's latest deployment details — when deployed and the image version tag — and push that data to a centralized Elasticsearch. Once the data is in Elasticsearch, run KQL queries to build common dashboards and alerts across platforms/clusters.

**✅ Correct answer:**
The approach is sound (normalize heterogeneous sources into one store, then dashboard). Two refinements: (1) You don't need a log agent for this — it's an **API-scrape + normalize + index** job, better modeled as small collectors (Lambda/CronJob) writing a *uniform schema* like `{app, env, version, deployed_at, source_tool, git_sha}`. (2) In a metrics world this is a classic **Grafana "Info/Table" panel fed by a small exporter** exposing deployment info as labeled gauges (`deployment_info{app,env,version} 1`), or a Grafana **table panel on an SQL/Elasticsearch datasource**. Emphasize a **canonical schema** as the key design decision — that's what makes multi-tool aggregation work.

```promql
# Expose each deploy as a labeled gauge; timestamp = deploy time
deployment_info{app="checkout", env="prod", version="v2.3.1", source="argocd"} 1717430400
# Grafana table panel query: newest version per app/env
max by (app, env, version) (deployment_info)
```

---

## Q8. What other metrics/dashboards did you create for applications?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Created dashboards with three dropdowns — cluster, application name, and namespace. Selecting them shows each application's availability, latency, and error budget across all components (e.g., ArgoCD's five components: API, controller, redis, cache, repo server).

**✅ Correct answer:**
Great use of **template variables** (the dropdowns) — that's exactly the reusable-dashboard pattern. To make it senior-grade, name the mechanism: in Grafana these are **`$cluster`, `$app`, `$namespace` template variables** driven by `label_values()` queries, referenced in every panel so one dashboard serves all apps. Pair it with **repeated rows/panels** (one row per component, auto-generated) and manage the JSON as **dashboards-as-code** (Grafana provisioning / Grafonnet / Terraform) so it's version-controlled, not click-built. Also clarify the metric definitions: availability = `up`/ready ratio, latency = a **histogram_quantile p95/p99**, and "error budget" belongs on an SLO panel, not mixed into per-component availability.

```promql
# Template-variable query that populates the $app dropdown:
label_values(kube_pod_info{cluster="$cluster", namespace="$namespace"}, app)

# A panel that reuses all three variables:
avg by (app) (up{cluster="$cluster", namespace="$namespace", app="$app"})
```

---

# ELK pipeline & log shipping

## Q9. What is the log-shipping agent you used to collect events and application logs?
**Asked in:** HDFC  |  **My performance:** Incorrect ⚠️

**My answer (from transcript):**
Repeatedly called it the "Elasticsearch agent" running as a DaemonSet to fetch pod data and push to the ELK DB. The interviewer pushed back several times ("there is no such agent"); he could not name it and finally said "we had the Helm chart for this agent, that's all I'm aware of, I need to look into it."

**✅ Correct answer:**
⚠️ **This is the #1 gap to nail.** There is no product called "Elasticsearch agent." The log shipper in the Elastic stack is one of:
- **Filebeat** — lightweight log *shipper*, runs as a **DaemonSet**, tails `/var/log/containers/*.log` on each node and ships to Logstash or Elasticsearch. This is the classic answer.
- **Elastic Agent** — the newer *unified* agent (managed by **Fleet**) that replaces Filebeat/Metricbeat/etc. and ships logs **and** metrics.
- (Non-Elastic equivalents: **Fluent Bit** / **Fluentd** / **Promtail** for Loki.)

The full Elastic pipeline: **Filebeat (DaemonSet) → Logstash (parse/enrich) → Elasticsearch (store/index) → Kibana (visualize).** Metricbeat/kube-state-metrics handle *metrics*. Memorize "**Filebeat is the DaemonSet log shipper; Elastic Agent is the unified successor.**" Never say "Elasticsearch agent."

```yaml
# Filebeat DaemonSet autodiscover — the answer he couldn't give
filebeat.autodiscover:
  providers:
    - type: kubernetes
      node: ${NODE_NAME}
      hints.enabled: true          # read logging hints from pod annotations
processors:
  - add_kubernetes_metadata: {}    # enrich each log line with pod/ns/labels
output.elasticsearch:
  hosts: ["https://elasticsearch:9200"]
  index: "filebeat-k8s-%{+yyyy.MM.dd}"
```

---

## Q10. How does ELK/Elasticsearch collect pod information — not just application logs via Filebeat?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
We had an "Elasticsearch agent" installed via Helm as DaemonSets whose main function is to get all pod information and send it to Elasticsearch. When pressed whether it's app logs or pod info, said pod information "in the form of its logs." (Hand-wavy; interviewer repeatedly probed and was unconvinced.)

**✅ Correct answer:**
The interviewer's skepticism was justified — you were conflating two different data paths. **Log agents (Filebeat/Fluent Bit) collect log *lines*, not pod *state*.** Pod status (Running/CrashLoopBackOff/Pending), restarts, phase and resource usage come from the **Kubernetes API**, surfaced as metrics by **kube-state-metrics** (object state) and **Metricbeat's Kubernetes module** or **cAdvisor/metrics-server** (resource usage). So the honest architecture is: **Filebeat → logs**; **Metricbeat + kube-state-metrics → pod/cluster metrics**; both into Elasticsearch, both visualized in Kibana. Saying "pod info in the form of logs" is wrong — pod *phase* is a metric/field pulled from the API server, not scraped from stdout. This distinction (logs vs. state metrics) is exactly what separates a partial from a strong answer.

```yaml
# Metricbeat's kubernetes module = where pod STATE actually comes from
metricbeat.modules:
  - module: kubernetes
    metricsets: [state_pod, state_container, pod, container]   # state_* = kube-state-metrics
    hosts: ["kube-state-metrics:8080"]
    period: 30s
    add_metadata: true
```

---

## Q11. Explain the ELK components — what each does.
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
"Elastic agent" installed via Helm fetches pod info and pushes to a centralized ELK database. In Elasticsearch selected the data-plane component per namespace, saw namespace arguments on the left, ran KQL queries (pod status, labels, image) to build Kibana dashboards and Elasticsearch alerts.

**✅ Correct answer:**
Name and separate each component crisply:
- **E — Elasticsearch:** the distributed **search/analytics engine + document store** (indexes JSON docs, inverted index, shards/replicas). This is the database.
- **L — Logstash:** server-side **ingest/transform pipeline** (input → filter → output; grok parsing, enrichment). Often replaced by lighter **Beats** or **Elasticsearch ingest pipelines**.
- **K — Kibana:** the **visualization/UI** — Discover, dashboards, and **alerting rules** live here (not "in Elasticsearch"). Small correction to your answer: dashboards *and* the built-in alerting UI are **Kibana**; the classic rules engine was **Watcher** (an Elasticsearch/X-Pack feature).
- **Beats (Filebeat/Metricbeat):** the lightweight **collectors/shippers** on each node. "B" is the unofficial fourth letter (ELK → "Elastic Stack" / BELK).

Data flow: **Beats → (Logstash) → Elasticsearch → Kibana.**

```yaml
# Logstash pipeline — the "L" people forget: input -> filter -> output
input  { beats { port => 5044 } }
filter {
  grok  { match => { "message" => "%{TIMESTAMP_ISO8601:ts} %{LOGLEVEL:level} %{GREEDYDATA:msg}" } }
  date  { match => ["ts", "ISO8601"] }
}
output { elasticsearch { hosts => ["es:9200"] index => "app-%{+YYYY.MM.dd}" } }
```

---

## Q12. What is a DaemonSet (logging agents like Fluent Bit run as DaemonSets), and how do you fetch/debug logs?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Candidate began to respond but the transcript shows the interviewer largely explaining; candidate acknowledged but did not give a substantive DaemonSet definition.

**✅ Correct answer:**
A **DaemonSet** ensures **exactly one pod runs on every (matching) node** — as nodes join the cluster the controller schedules a copy automatically; as nodes leave, the pod is garbage-collected. That's *why* log shippers (Fluent Bit, Filebeat, Promtail) use it: they must read `/var/log/containers/*.log` (via a `hostPath` mount) on **every** node. Other DaemonSet uses: CNI agents, node_exporter, CSI node plugins, kube-proxy. Debugging logs: `kubectl logs <pod> -c <container>`, `--previous` for a crashed container's last logs, `-l app=x --all-containers` across a Deployment; but for *aggregated/historical* logs you query the store (Kibana Discover / `logcli` for Loki) since node logs rotate and vanish when a pod is rescheduled — which is the entire reason for centralized shipping.

```bash
# Fetch logs at every level
kubectl logs -f deploy/my-app -c app --tail=100      # live, specific container
kubectl logs my-app-abc --previous                   # last logs of a CRASHED container
kubectl get ds -n logging fluent-bit                 # confirm one shipper per node
# In the store (Loki example) — historical logs a rescheduled pod would have lost:
logcli query '{namespace="prod",app="my-app"} |= "level=error"' --since=1h
```

---

## Q13. Which alerting mechanism/tool did you integrate with ELK, and what tools are involved end-to-end?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
AWS EKS managed clusters with the "Elasticsearch agent" as DaemonSets extracting all pod info across namespaces into a centralized ELK DB. In Elasticsearch (not Kibana) there's an alerting section; run custom KQL for the app pods (e.g., Istio), fetch current pod status, and set an alert: if pod status isn't Running for over a minute, trigger to a Slack channel via xMatters. (Interviewer skeptical about how Elasticsearch collects pod info vs. logs.)

**✅ Correct answer:**
Fix two naming issues that drew the skepticism: (1) the agent is **Filebeat/Metricbeat/Elastic Agent**, not "Elasticsearch agent" (Q9); (2) **alerting rules live in Kibana** (Stack Management → Rules and Connectors) or the legacy **Elasticsearch Watcher** — connectors (Slack, PagerDuty, webhook/xMatters) are configured there. End-to-end tool chain to state: **Filebeat/Metricbeat (collect) → Elasticsearch (store/index) → Kibana rule (threshold on a KQL/ES query) → Connector → xMatters (P0/P1 phone) / Slack (rest).** In a Prometheus world the equivalent is **Alertmanager** (routing, grouping, silences, inhibition) fed by rule evaluations. Name the routing tool explicitly — that's what the interviewer wanted.

```json
// Kibana alerting rule + Slack connector (the actual mechanism)
{
  "rule_type_id": ".es-query",
  "params": {
    "index": ["metricbeat-*"],
    "esQuery": "{\"query\":{\"bool\":{\"must\":[{\"match\":{\"kubernetes.pod.status.phase\":\"Pending\"}}]}}}",
    "threshold": [0], "thresholdComparator": ">", "timeWindowSize": 1, "timeWindowUnit": "m"
  },
  "actions": [{ "group": "query matched", "id": "slack-connector",
                "params": { "message": "{{context.hits}} pods not Running — runbook: ..." } }]
}
```

---

## Q14. How do you collect logs from your application deployed in EKS?
**Asked in:** Virtusa  |  **My performance:** Correct

**My answer (from transcript):**
An Elastic Agent installed across all clusters fetches all pods' data and pushes it to the centralized ELK database.

**✅ Correct answer:**
Correct in spirit — just say **Filebeat/Elastic Agent as a DaemonSet** and mention the *mechanism*: containers write to stdout/stderr → the kubelet/container runtime writes those to `/var/log/containers/*.log` on the node → the DaemonSet agent tails those files (via `hostPath`), enriches each line with Kubernetes metadata (namespace, pod, labels), and ships to Elasticsearch/Logstash. On EKS specifically, the AWS-native path is **Fluent Bit → CloudWatch Logs or OpenSearch** (the `aws-for-fluent-bit` image). Mentioning the `/var/log/containers` symlink chain and metadata enrichment is what turns a correct answer into an impressive one.

```yaml
# Fluent Bit on EKS: tail node logs -> enrich -> ship to OpenSearch/Elasticsearch
[INPUT]
    Name              tail
    Path              /var/log/containers/*.log
    multiline.parser  cri
[FILTER]
    Name              kubernetes           # adds namespace, pod, labels
    Merge_Log         On
[OUTPUT]
    Name              es
    Host              opensearch.eks.internal
    Index             eks-app
```

---

## Q15. How did you ascertain it was a memory problem?
**Asked in:** HDFC  |  **My performance:** Correct

**My answer (from transcript):**
Had dashboards and alerts per application via Elasticsearch/Kibana; if CPU or memory crossed 80%, an alert triggered to Slack. The app breached memory, alerts fired, then inspected logs with kubectl.

**✅ Correct answer:**
Solid. Sharpen it with the exact signals: a memory problem shows as **container memory usage approaching its limit** (`container_memory_working_set_bytes / limit`), then **OOMKilled** in the pod's `lastState.terminated.reason`, a **restart-count** jump, and `Warning OOMKilling` events. The 80% threshold is a good *early-warning* (saturation) signal; the OOMKill is the *symptom*. Distinguish **working-set** memory (what the kernel counts toward the OOM decision) from RSS/cache. Closing the loop: alert on saturation (80%) → confirm via `kubectl describe` reason=OOMKilled → fix by raising the limit or fixing the leak.

```promql
# The exact saturation signal behind the alert:
max by (pod) (
  container_memory_working_set_bytes{namespace="prod"}
  / on(pod,container) kube_pod_container_resource_limits{resource="memory"}
) > 0.80
```
```bash
kubectl get pod my-app -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# -> OOMKilled   (the definitive confirmation)
```

---

# Alerting & Alertmanager

## Q16. Have you set up any synthetic monitoring?
**Asked in:** HCL  |  **My performance:** Didn't know

**My answer (from transcript):**
Synthetic monitoring was already set up (not by me), testing the endpoints of the applications. It was already there.

**✅ Correct answer:**
**Synthetic monitoring** = actively *probing* a service from outside on a schedule with simulated traffic (a "synthetic" user), rather than waiting for real users — so you catch outages **before** customers do and measure availability/latency from the user's vantage point. Two flavors: **uptime/API checks** (HTTP status, cert expiry, DNS) and **browser/transaction checks** (scripted multi-step user journeys, e.g. login → add-to-cart → checkout). Tools: **Prometheus Blackbox Exporter**, **Grafana Synthetic Monitoring / k6**, Datadog Synthetics, Pingdom, CloudWatch Synthetics (Canaries). It complements the "real-traffic" golden signals with a **known-good heartbeat**. Even if it was pre-existing, you should be able to define it and configure a blackbox probe.

```yaml
# Blackbox exporter probe + alert: catch the outage before users do
- job_name: blackbox-http
  metrics_path: /probe
  params: { module: [http_2xx] }
  static_configs: [{ targets: ["https://app.example.com/health"] }]
  relabel_configs:
    - { source_labels: [__address__], target_label: __param_target }
    - { target_label: __address__, replacement: blackbox-exporter:9115 }
---
- alert: SyntheticEndpointDown
  expr: probe_success == 0
  for: 2m
  labels: { severity: critical }
```

---

## Q17. Once the trigger happens, does it just notify or resolve on its own? How do you know which runbook to use?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
No self-healing/auto-resolution. The alert notifies the Slack channel with the error message and an attached runbook of troubleshooting steps. The error message reveals the pod status (e.g., ImagePullBackOff) and you pick the matching runbook.

**✅ Correct answer:**
Notify-only is a legitimate design, but a senior answer names the alternative and the routing mechanism. **Runbook selection should be automated via alert labels**, not human pattern-matching: every alert carries a `runbook_url` annotation templated from its labels, so the *right* runbook is embedded in the notification. For **auto-remediation**, the ladder is: Alertmanager receiver → webhook → an automation engine (**Ansible**, **Rundeck**, **StackStorm**, a K8s **Operator**, or **Argo Events/Workflows**) that runs the runbook's steps. Distinguish **self-healing that K8s already does** (liveness probe restarts, HPA scaling, ReplicaSet rescheduling) from **event-driven remediation** you build. Mention the risk: auto-remediation without guardrails can mask root causes or cause flapping — that's why many teams stay notify-first.

```yaml
# Runbook chosen automatically by label; optional webhook to a remediation engine
route:
  routes:
    - matchers: [ alertname="ImagePullBackOff" ]
      receiver: remediation-webhook
receivers:
  - name: remediation-webhook
    webhook_configs:
      - url: http://stackstorm/api/webhooks/imagepull   # runs the runbook automatically
```

---

## Q18. A customer complains they can't log in to the application — how do you approach it?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
First check CI/CD (GitHub Actions) for failed jobs; then ArgoCD application logs for auth/connectivity/deployment issues; then log into the cluster to check the service is up and pods are running.

**✅ Correct answer:**
Starting at CI/CD is backwards — that assumes a *recent deploy* caused it, which biases the investigation. Work the **request path top-down from the symptom**, using the golden signals: (1) **Is it everyone or one user?** (check error-rate and login-success dashboards → scope). (2) **Walk the path:** DNS/LB/Ingress → the **auth service** and its dependency (identity provider, session store/**Redis**, DB) → check its error rate, latency, saturation and recent 5xx/401 spikes. (3) **Correlate with change:** *now* check recent deploys/config/secret rotations (**Infisical**), cert expiry, token/OIDC issues. (4) **Reproduce** with a synthetic login. Mention **secret/cert expiry** and **downstream identity-provider outages** explicitly — the most common "can't log in" root causes. The skill is starting from user impact and following telemetry, not guessing at the pipeline.

```promql
# Scope it in one query: is login failing for everyone, and where?
sum by (reason) (rate(auth_login_failures_total[5m]))
# and confirm the auth service's dependency isn't the culprit:
rate(auth_dependency_errors_total{dependency=~"redis|idp|db"}[5m]) > 0
```

---

## Q19. Before troubleshooting, do you have anything set up in monitoring? Do you check an error code or logs first?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Said he'd track error budgets and availability of application components. The interviewer pushed back that error budget isn't relevant during troubleshooting; he then agreed availability (and latency) is what he'd check.

**✅ Correct answer:**
The interviewer is right, and the *why* matters: **error budget is a strategic/planning signal** (over weeks — do we ship features or freeze and fix reliability?), **not a live debugging signal.** During an active incident you look at **real-time golden signals**: errors (5xx/exception rate), latency (p95/p99), traffic, saturation (CPU/mem/queue depth) — plus recent deploys and the specific error code/exception in logs/traces. The right order: **alert fires → dashboards to scope (which signal, which service) → logs/traces to root-cause.** Keep the SLO/error-budget concept for the *retro and prioritization* conversation. Mixing the two is the exact confusion the interviewer flagged.

```promql
# Live troubleshooting signals (NOT error budget):
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))  # latency
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))  # errors
```

---

## Q20. How do you trigger the alert / what's the notification flow?
**Asked in:** HCL  |  **My performance:** Correct

**My answer (from transcript):**
Configured Slack integration with xMatters, so a triggered alert goes to a specific Slack channel with a message template containing the error, how long it's been happening, and its runbook Confluence link, so the team can work on it.

**✅ Correct answer:**
Good — the message template with error + duration + runbook is best practice. Elevate it by naming the **routing/dedup layer**: in Prometheus that's **Alertmanager**, which does **grouping** (collapse many pod alerts into one notification), **routing** (severity/team-based receivers), **inhibition** (suppress node-level alerts when the whole cluster is down), **silences** (during maintenance), and **repeat/throttle** intervals. Your **severity split (xMatters phones P0/P1, Slack for the rest)** is exactly the routing tree Alertmanager expresses. Naming grouping + inhibition + severity routing is what makes this a senior answer.

```yaml
# Alertmanager: severity-based routing = your xMatters/Slack split, plus grouping
route:
  group_by: [alertname, namespace]     # collapse noise
  receiver: slack-default
  routes:
    - matchers: [ severity="critical" ]
      receiver: xmatters-oncall         # P0/P1 -> phone
receivers:
  - name: slack-default
    slack_configs: [{ channel: "#alerts", title: "{{ .CommonAnnotations.summary }}",
                      text: "Firing {{ .Alerts | len }} | runbook: {{ .CommonAnnotations.runbook_url }}" }]
  - name: xmatters-oncall
    webhook_configs: [{ url: "https://xmatters/integration/..." }]
```

---

## Q21. How will you handle the alert fatigue problem?
**Asked in:** HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
Alert fatigue starts with too many alerts (10–15) to a channel and high frequency (auto-triggering every 2–5 min). Prioritize which apps/metrics matter, tune the trigger frequency, and act based on severity.

**✅ Correct answer:**
Strong instincts — formalize with the standard levers: (1) **Alert on symptoms, not causes** — page on user-facing SLO burn, not every CPU blip. (2) **Grouping + inhibition** in Alertmanager (one incident = one page; suppress downstream alerts when the parent is firing). (3) **Right `for:` duration + hysteresis** to kill flapping. (4) **Severity tiers + routing**: page (P0/P1) vs. ticket vs. dashboard-only. (5) **Multi-window burn-rate alerts** so only *fast* budget burn pages (Q24/advanced). (6) **Silences** during deploys/maintenance. (7) **Track alert quality**: signal-to-noise, % actionable, alerts-per-on-call-shift; prune anything non-actionable. The north star: **every page must be actionable and urgent** — if it isn't, it's a ticket or a dashboard.

```yaml
# Kill flapping (for:) + suppress downstream noise (inhibition)
inhibit_rules:
  - source_matchers: [ severity="critical", alertname="ClusterDown" ]
    target_matchers: [ severity="warning" ]      # don't page pod alerts if the cluster is down
    equal: [ cluster ]
```

---

## Q22. The Slack-integrated metrics — did that help in this incident?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Yes — they immediately got alerts the app was stuck in OOM, started inspecting logs/infrastructure, the app team confirmed it was their issue, built and tested a new image in lower environments, then merged to production main.

**✅ Correct answer:**
Good outcome story. Make it quantified and process-shaped for a senior audience: tie it to **MTTA/MTTR reduction** ("alert-to-acknowledge dropped to X min because the page carried the error, duration and runbook"), note the **clean escalation** (platform triaged → correctly handed to the app team → fix flowed dev→staging→prod through the promotion pipeline), and mention the **follow-up** — a blameless postmortem plus a guardrail (memory-limit tuning, or a VPA/HPA recommendation) so the same OOM doesn't recur. Demonstrating the *loop closes* (detect → remediate → prevent) is what distinguishes a senior from a responder.

```promql
# Turn the incident into a prevention guardrail: predict OOM 30m out
predict_linear(container_memory_working_set_bytes{pod=~"my-app.*"}[1h], 30*60)
  > on(pod,container) kube_pod_container_resource_limits{resource="memory"}
```

---

# SLO / SLI / error budgets

## Q23. What is the SLI/SLO in your environment?
**Asked in:** HCL  |  **My performance:** Partial ⚠️

**My answer (from transcript):**
Our SLO was ~96% of the time, and the error budget was ~35%. Based on that we created availability, latency, and pod/node resource-utilization metrics; built ~34 dashboards with cluster/app/namespace dropdowns.

**✅ Correct answer:**
⚠️ **The math is wrong and it's the key thing to fix.** **Error budget = 100% − SLO**, always. If the SLO is 96%, the error budget is **4%**, *not* 35%. (A "35% budget" would imply a 65% SLO — a service that's allowed to be down a third of the time, which is absurd.) Also, **96% is a weak SLO** — that's ~**14.4 hours of downtime per month** (30d × 4%). Real platform SLOs are stated in "nines": **99.9%** = 43.8 min/month, **99.95%** = 21.9 min/month, **99.99%** = 4.4 min/month. And an **SLI must be a ratio of good events to total events** with an explicit definition, e.g. `good = requests with status<500 AND latency<300ms`. Say it as: "SLI = fraction of successful, fast requests; SLO = 99.9% over 30 days; error budget = 0.1% ≈ 43 min/month."

```promql
# SLI as a ratio, and the budget that flows from the SLO:
# error_budget = 1 - SLO  (SLO 0.999 -> budget 0.001, NOT 0.35)
1 - (
  sum(rate(http_requests_total{status!~"5..",le_ok="true"}[28d]))
  / sum(rate(http_requests_total[28d]))
)  # this is budget CONSUMED; alert when it exceeds 0.001
```

---

## Q24. How do you calculate the error rate / error budget?
**Asked in:** HCL  |  **My performance:** Partial ⚠️

**My answer (from transcript):**
Count failure points over a timeframe (used 24 h). Failure = HTTP errors or availability issues. Within 24 h, if it fails more than 5–6 times, look into it — created alerts that way. (Ad-hoc threshold rather than a proper burn calculation.)

**✅ Correct answer:**
⚠️ "More than 5–6 fails in 24h" is an arbitrary threshold, not error-budget management. Do it properly:
1. **Error rate = bad events / total events** over a window (a *ratio*, not a raw count — 6 failures out of 100 requests vs. 6 out of 10M are wildly different).
2. **Error budget** = `1 − SLO`. For 99.9% over 30 days, budget = 0.1% of requests (or ~43 min).
3. **Burn rate** = how fast you're consuming the budget: `burn_rate = observed_error_rate / (1 − SLO)`. Burn rate **1** = you'll exactly exhaust the budget over the window; **>1** = burning too fast.
4. **Multi-window, multi-burn-rate alerts** (Google SRE): page on a **fast burn** (e.g. 14.4× over 1h **and** 5m) → 2% of budget gone fast; ticket on a **slow burn** (e.g. 3× over 6h). This gives fast detection *and* low false positives — replacing the ad-hoc "5–6 fails" rule.

```promql
# Burn rate = error rate normalized by the budget (1 - 0.999 = 0.001)
( sum(rate(http_requests_total{status=~"5.."}[1h])) / sum(rate(http_requests_total[1h])) ) / 0.001

# Multi-window fast-burn page: >14.4x on BOTH 1h and 5m windows
- alert: ErrorBudgetFastBurn
  expr: |
    (sum(rate(http_requests_total{status=~"5.."}[1h])) / sum(rate(http_requests_total[1h]))) / 0.001 > 14.4
    and
    (sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) / 0.001 > 14.4
  labels: { severity: critical }
```

---

## Q25. You used the ELK stack for your SLOs/SLIs — how, and why ELK (not typical)?
**Asked in:** Shell-1  |  **My performance:** Partial ⚠️

**My answer (from transcript):**
Installed an "Elasticsearch agent" across clusters to fetch pod info into a centralized ES DB; query the namespace's data plane with KQL to build dashboards and alerts. Main metrics: availability, latency, errors.

**✅ Correct answer:**
⚠️ **Acknowledge the tool mismatch — the interviewer's skepticism is correct.** ELK is **log-centric**; SLOs are fundamentally a **metrics + time-series math** problem (ratios, `rate()`, `histogram_quantile`, burn rate over rolling windows), which is exactly what **Prometheus + a recording-rule/SLO framework does natively**. The industry-standard SLO stack is **Prometheus/Thanos/Mimir + Grafana + Sloth/Pyrra/OpenSLO** (which generate SLI recording rules and multi-burn-rate alerts for you). You *can* approximate SLIs in ELK by counting good/total log docs, but you lose native histograms, cheap long-window rollups and burn-rate alerting. The right framing: "ELK was our org standard so I computed availability/latency/error SLIs from indexed data, but I know the **conventional and better fit is Prometheus-based SLO tooling** — metrics, not logs, are the native substrate for SLOs." Your three chosen SLIs (availability, latency, errors) are correct — it's the *engine* that was unconventional.

```yaml
# The conventional way: declare the SLO, let Sloth generate rules + burn alerts
apiVersion: sloth.slok.dev/v1
kind: PrometheusServiceLevel
spec:
  service: checkout
  slos:
    - name: requests-availability
      objective: 99.9                         # SLO %
      sli:
        events:
          error_query: sum(rate(http_requests_total{status=~"5.."}[{{.window}}]))
          total_query: sum(rate(http_requests_total[{{.window}}]))
      alerting: { name: CheckoutAvailability, pageAlert: {labels: {severity: critical}} }
```

---

## Q26. Are you using other tools (e.g. Prometheus) for SLOs, or just ELK dashboards?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
The org was streamlined with ELK. We tried to bring in Prometheus but leadership didn't like it, so we went back to Elasticsearch/Kibana dashboards.

**✅ Correct answer:**
"Leadership didn't like it" is a weak explanation — offer the *technical* tradeoff so it reads as an informed org decision, not a limitation. Legit reasons a shop consolidates on ELK: one stack to operate, existing log expertise, licensing/procurement. But be ready to state what Prometheus buys you for SLOs specifically: **native time-series math**, **recording rules** (precompute expensive SLIs), **cheap long-window queries** via **Thanos/Mimir** downsampling, first-class **multi-burn-rate alerting**, and the **ServiceMonitor** CRD ecosystem. Ideal end state is **both**: Prometheus/Grafana for metrics+SLOs, ELK/Loki for logs, unified in Grafana. Show you understand *why* you'd add Prometheus, even if the org chose not to.

```promql
# What Prometheus recording rules give you that ELK dashboards don't:
# precompute the 30d SLI once, query it cheaply everywhere
- record: slo:availability:ratio_rate30d
  expr: |
    sum(rate(http_requests_total{status!~"5.."}[30d]))
    / sum(rate(http_requests_total[30d]))
```

---

## Q27. Define SLA, SLO, SLI and how we measure them.
**Asked in:** HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
SLA = agreement between customers and platform owners assuring uptime, with a penalty if breached. SLOs support the SLA (e.g., 96–97% availability or error budget). SLIs are custom metrics like availability, latency, error rates, monitored via ELK plus alerting to reduce MTTR.

**✅ Correct answer:**
The hierarchy is right; sharpen the definitions and the numbers:
- **SLI (Indicator)** — the *measured number*: a **ratio of good events to total events**, e.g. `successful requests / total requests`, or `requests faster than 300ms / total`. It's quantitative and derived from telemetry.
- **SLO (Objective)** — the *internal target* for an SLI over a window: "99.9% of requests succeed over 30 days." Should be **stricter** than the SLA (buffer).
- **SLA (Agreement)** — the *external contract* with **consequences** (credits/penalties) if the SLO-like target is missed: "99.5% or we refund X%."
- Relationship: **SLI ≤ SLO ≤ SLA strictness** — you set the SLA looser than your internal SLO so you have headroom before contractual breach. Fix the earlier "96%" habit — real targets are in **nines** (99.9%+). Measurement = instrument events → compute the good/total ratio in Prometheus → track against the objective → alert on **budget burn**.

```promql
# SLI (the measured ratio), then compare to the SLO target
sli_availability = sum(rate(http_requests_total{status!~"5.."}[30d]))
                 / sum(rate(http_requests_total[30d]))
# breach if SLI < SLO (0.999). SLA (e.g. 0.995) sits looser, with penalties.
```

---

## Q28. What is an error budget?
**Asked in:** Persistent, HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
The percentage of downtime the SLA/platform can accommodate; e.g., with an SLO of 96–97%, the error budget is 3–4% — the tolerable failure before breaching. Exceeding it makes it a P1 requiring action.

**✅ Correct answer:**
The definition is correct: **error budget = 100% − SLO** = the amount of unreliability you're *allowed* to spend before breaching the objective. Make it senior-grade with three additions: (1) **it's a currency, not just a number** — it lets you *balance velocity vs. reliability*: budget remaining → ship features freely; budget exhausted → **freeze features and fix reliability** (this is the core cultural purpose). (2) **Convert to real units** so it's tangible: 99.9% over 30d ≈ **43 min/month**; 99.95% ≈ 22 min. (3) **Burn rate** is how you police it in real time (Q24) — page on fast burn, ticket on slow burn. And drop the "96%" example for a "nines" one. Framing the error budget as a **decision tool that governs release policy** is what interviewers are really probing for.

```promql
# Budget consumed over the SLO window; policy: if >100%, freeze releases
error_budget_consumed =
  ( 1 - (sum(rate(http_requests_total{status!~"5.."}[30d]))
         / sum(rate(http_requests_total[30d]))) )
  / 0.001          # 0.001 = 1 - 0.999 SLO;  >1.0 means budget blown
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## A1. Explain `rate()` vs `irate()` vs `increase()`, and why you must not `rate()` a gauge.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`rate()` gives the **per-second average** rate of increase of a **counter** over the window (handles counter resets); `irate()` uses only the **last two samples** (instantaneous, spiky — for fast-moving graphs, not alerts); `increase()` is total growth over the window (= `rate() × window`). All three require **counters** (monotonic). Applying them to a **gauge** (up/down values like memory) is meaningless — use `deriv()` or `delta()` for gauges. Always put `rate()` **inside** aggregation (`sum(rate(...))`), never `rate(sum(...))`.

```promql
sum by (path) (rate(http_requests_total[5m]))     # req/s, correct for alerting
increase(http_requests_total[1h])                 # total requests in the last hour
```

---

## A2. Compute p99 latency with `histogram_quantile()` — and what's the classic pitfall?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
`histogram_quantile(φ, sum by (le)(rate(bucket[5m])))` estimates the φ-quantile from a **`_bucket`** histogram. Pitfalls: (1) you **must** `rate()` the buckets first and aggregate **by `le`** (keep the `le` label); (2) accuracy depends on bucket boundaries — a p99 inside a huge bucket is a rough interpolation; (3) you **cannot average quantiles** across instances — recompute from summed buckets. Native histograms (newer Prometheus) reduce this pain.

```promql
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

---

## A3. What are recording rules and when do you use them?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Recording rules **precompute** expensive/frequently-used expressions on an interval and store the result as a new series, so dashboards and alerts query a cheap precomputed metric instead of recomputing heavy aggregations every load. Use for: long-window SLIs, high-cardinality aggregations, and any expression reused across many panels/alerts. Naming convention: `level:metric:operation`.

```yaml
groups:
  - name: slo.rules
    interval: 30s
    rules:
      - record: job:http_errors:rate5m
        expr: sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
```

---

## A4. How do you find and control metric cardinality explosions?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Cardinality = number of unique label-value series; it explodes when high-variability values (user IDs, request IDs, raw paths, pod hashes) become labels, blowing up memory and query time. Find it with `topk` on `count by (__name__)` and TSDB status. Control it: **drop/relabel** offending labels at scrape time (`metric_relabel_configs`), bucket unbounded values, never put unbounded IDs in labels, and set `sample_limit`. Loki/Elasticsearch differ but the principle (keep index labels low-cardinality) holds.

```yaml
metric_relabel_configs:
  - source_labels: [path]
    regex: '/user/[0-9]+'
    target_label: path
    replacement: '/user/:id'          # collapse unbounded IDs
```

---

## A5. Design an Alertmanager routing tree with grouping, inhibition, and silences.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**Route** = a tree matching on labels to receivers; **group_by** collapses related alerts into one notification; **inhibition** suppresses lower-severity alerts when a higher-severity parent fires (cluster-down suppresses pod alerts); **silences** mute alerts during maintenance; **repeat_interval/group_wait** throttle. Route by `severity`/`team` to different receivers (page vs. ticket vs. Slack).

```yaml
route:
  group_by: [alertname, cluster, namespace]
  group_wait: 30s
  repeat_interval: 4h
  receiver: slack
  routes:
    - matchers: [severity="critical"]
      receiver: pagerduty
inhibit_rules:
  - source_matchers: [alertname="ClusterDown"]
    target_matchers: [severity="warning"]
    equal: [cluster]
```

---

## A6. Design multi-window, multi-burn-rate SLO alerts.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Google-SRE pattern: alert only when a **fast window and a slower confirmation window** both exceed a burn-rate threshold, giving fast detection with few false positives. Typical tiers: **page** at 14.4× (1h & 5m) = 2% budget in an hour; **page** at 6× (6h & 30m); **ticket** at 3× (24h & 2h) / 1× (3d). Burn rate = error-rate ÷ (1−SLO).

```promql
- alert: SLOFastBurn
  expr: |
    (sum(rate(http_requests_total{status=~"5.."}[1h]))/sum(rate(http_requests_total[1h])))/0.001 > 14.4
    and
    (sum(rate(http_requests_total{status=~"5.."}[5m]))/sum(rate(http_requests_total[5m])))/0.001 > 14.4
```

---

## A7. Prometheus long-term storage & HA: Thanos vs. Mimir vs. Cortex.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Vanilla Prometheus is local, single-node, ~weeks of retention. **Thanos** adds a **sidecar** that ships TSDB blocks to object storage (S3/GCS), a **Store Gateway** to query them, a **Querier** that dedups across HA Prometheus pairs, plus **Compactor** (downsampling). **Mimir** (Grafana) / **Cortex** are horizontally scalable, multi-tenant remote-write backends for the same goal. Choose Thanos for a sidecar-on-existing-Prometheus model; Mimir for large multi-tenant remote-write at scale.

```yaml
thanos:
  objectStorageConfig:
    type: S3
    config: { bucket: prom-lts, endpoint: s3.amazonaws.com }
```

---

## A8. Loki vs. ELK — when do you pick which?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**Loki** indexes only **labels** (not full log content), stores compressed chunks in object storage — cheap, low-ops, integrates natively with Grafana/Prometheus labels, queried with **LogQL**; best when you filter by known labels then grep. **ELK** does **full-text inverted indexing** — richer ad-hoc search/analytics/aggregations, but heavier and costlier to run. Pick Loki for cost-efficient K8s log aggregation alongside Prometheus; ELK when you need deep full-text search, complex analytics, or SIEM.

```logql
{namespace="prod", app="checkout"} |= "error" | json | status >= 500
```

---

## A9. Explain OpenTelemetry and distributed tracing (traces/spans, context propagation).
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**OpenTelemetry (OTel)** is the vendor-neutral standard (SDKs + **Collector** + OTLP protocol) for metrics, logs and **traces**. A **trace** = one request's journey across services, made of **spans** (each a timed operation) linked by a **trace/span ID** propagated via headers (**W3C traceContext**). This lets you see *where* latency/errors occur across microservices. Backends: **Tempo, Jaeger**. The Collector receives, processes and exports to multiple backends, decoupling instrumentation from vendors.

```yaml
exporters:
  otlp/tempo: { endpoint: tempo:4317 }
service:
  pipelines:
    traces: { receivers: [otlp], processors: [batch], exporters: [otlp/tempo] }
```

---

## A10. What are exporters? Write/scrape a custom exporter and node_exporter.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
An **exporter** is a process that translates a system's metrics into the Prometheus text format on `/metrics` for scraping. Standard ones: **node_exporter** (host CPU/mem/disk/net), **kube-state-metrics** (K8s object state), **blackbox_exporter** (probes), **cAdvisor** (containers), DB exporters (mysqld/postgres). For custom app metrics you expose them via a client library. Prometheus scrapes them on an interval via `scrape_configs`.

```python
from prometheus_client import Counter, start_http_server
REQS = Counter('app_requests_total', 'total', ['status'])
start_http_server(8000)          # exposes /metrics for Prometheus to scrape
REQS.labels(status='200').inc()
```

---

## A11. What is the ServiceMonitor / PodMonitor CRD and how does the Prometheus Operator use it?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
The **Prometheus Operator** (kube-prometheus-stack) lets you configure scraping declaratively via **CRDs** instead of editing `prometheus.yml`. A **ServiceMonitor** selects **Services** (by label) and their ports/paths to scrape; a **PodMonitor** targets pods directly; **PrometheusRule** holds alert/recording rules; **Probe** for blackbox. The Operator watches these CRDs and regenerates Prometheus config automatically — this is the GitOps-friendly, K8s-native way to add targets.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: app, labels: { release: kube-prometheus-stack } }
spec:
  selector: { matchLabels: { app: my-app } }
  endpoints: [{ port: web, interval: 15s, path: /metrics }]
```

---

## A12. How do you manage dashboards and alerts as code (GitOps)?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Never click-build production dashboards. Store them as **JSON/Jsonnet (Grafonnet)** or via the **Grafana Terraform provider / Operator (GrafanaDashboard CRD)**, provisioned from Git so they're versioned, reviewed and reproducible across environments. Alerts/recording rules live as **PrometheusRule** CRDs or rule YAML in Git, deployed via Argo CD/Flux. Benefits: peer review, rollback, drift detection, and environment parity. Pair with **Grafana provisioning** config maps for datasources.

```yaml
# Grafana Operator: dashboard as a versioned CRD in Git
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata: { name: slo-overview }
spec:
  instanceSelector: { matchLabels: { dashboards: grafana } }
  json: |
    { "title": "SLO Overview", "panels": [ /* ... */ ] }
```

---
