# Project 6 — Capstone: Multi-Tenant AI Platform Control Plane ("Mini-Anthropic")

> Stop *using* platforms and **build one**. You'll write a Kubernetes **CRD + operator** (`ModelDeployment`) that turns one YAML into a full vLLM serving stack per tenant; enforce **hard multi-tenancy** with quotas, Kyverno policies and NetworkPolicies; front it with an **API gateway** doing per-tenant auth + rate limiting; attribute **GPU cost per tenant** with OpenCost; and run it against **SLOs with burn-rate alerts**. This is, component-for-component, the Cisco "AI Control Plane Engineer" JD.

| | |
|---|---|
| **Difficulty** | Expert (the capstone — everything composes here) |
| **Time** | 4–6 weekends |
| **Prereq** | Projects 1–2 (GPU platform + vLLM knowledge). Projects 4–5 enrich the demo. |
| **Cloud cost** | Control plane is CPU-only (develop on kind for free); end-to-end GPU demos ~$0.30–0.60/hr. |
| **Skills proven** | CRD design, operator/reconcile-loop **implementation** (Python kopf; Go/Kubebuilder appendix), multi-tenancy (quotas, Kyverno, NetworkPolicy), gateway auth + rate limiting, FinOps chargeback (OpenCost), SLO/error-budget engineering, DR runbooks + chaos test |
| **JD keywords hit** | "CRDs, the operator pattern, Kubebuilder" · "control plane components… Golang AND Python" · "REST APIs" · "SLA/SLO metrics" · "multi-tenant resource allocation" · "Kyverno or OPA" · "OpenCost/Kubecost" · "runbooks, DRP, postmortems" |

---

## 1. What "control plane" means here

Tenants don't get `kubectl` and a pile of Helm charts. They get **one declarative API**:

```yaml
apiVersion: platform.akshay.dev/v1alpha1
kind: ModelDeployment
metadata:
  name: support-bot
  namespace: tenant-a
spec:
  model: Qwen/Qwen2.5-1.5B-Instruct
  maxModelLen: 4096
  replicas: { min: 1, max: 2 }
  gpu: { count: 1, sharing: timeslice }
  rateLimit: { requestsPerMinute: 120 }
```

Your operator reconciles that into: vLLM Deployment + Service + ServiceMonitor + KEDA ScaledObject + gateway route — and reports status back. **Desired state in, running inference stack out.** That's the product AI-infra teams build internally.

## 2. Architecture

```
tenant request ──► Gateway (Envoy Gateway / NGINX)
                   │  API-key → tenant, per-tenant rate limit, /tenant-a/support-bot/v1/...
                   ▼
        ┌── tenant-a ns ─────────────┐   ┌── tenant-b ns ──────────┐
        │ vLLM pods (operator-made)  │   │ vLLM pods               │
        │ ResourceQuota: 1 GPU       │   │ ResourceQuota: 1 GPU    │
        │ NetworkPolicy: gw-only in  │   │ ...                     │
        └────────────▲───────────────┘   └──────────▲──────────────┘
                     │ creates/updates/heals        │
              ┌──────┴─────────────────────────────┴──────┐
              │  model-operator (kopf, Python)             │
              │  watches ModelDeployment CRs cluster-wide  │
              └────────────────────────────────────────────┘
 Kyverno: admission policies      OpenCost: $/tenant       Prometheus: SLOs + burn alerts
```

## 3. Repo layout

```
ai-control-plane/
├── crd/ modeldeployment-crd.yaml
├── operator/ operator.py  Dockerfile  rbac.yaml  deployment.yaml
├── tenancy/ tenant-template/ (ns, quota, netpol)   kyverno-policies.yaml
├── gateway/ envoy-gateway.yaml  routes.yaml  ratelimit.yaml
├── finops/ opencost-values.yaml  cost-report.py
├── slo/ prometheusrules-slo.yaml
├── runbooks/ RUNBOOK-gpu-node-loss.md  DR-PLAN.md  POSTMORTEM-template.md
└── examples/ tenant-a-supportbot.yaml  tenant-b-summarizer.yaml
```

## 4. Phase 1 — The CRD

`crd/modeldeployment-crd.yaml` (core; full validation in repo):

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: modeldeployments.platform.akshay.dev
spec:
  group: platform.akshay.dev
  scope: Namespaced
  names:
    kind: ModelDeployment
    plural: modeldeployments
    shortNames: [mdep]
  versions:
    - name: v1alpha1
      served: true
      storage: true
      subresources: { status: {} }          # status is a separate write — good practice
      additionalPrinterColumns:
        - { name: Model, type: string, jsonPath: .spec.model }
        - { name: Ready, type: string, jsonPath: .status.phase }
        - { name: Replicas, type: integer, jsonPath: .status.readyReplicas }
      schema:
        openAPIV3Schema:
          type: object
          required: [spec]
          properties:
            spec:
              type: object
              required: [model]
              properties:
                model: { type: string }
                maxModelLen: { type: integer, default: 4096, maximum: 32768 }
                replicas:
                  type: object
                  properties:
                    min: { type: integer, default: 1, minimum: 0 }
                    max: { type: integer, default: 2, maximum: 4 }
                gpu:
                  type: object
                  properties:
                    count: { type: integer, default: 1, maximum: 1 }
                    sharing: { type: string, enum: [none, timeslice], default: timeslice }
                rateLimit:
                  type: object
                  properties:
                    requestsPerMinute: { type: integer, default: 60 }
            status:
              type: object
              properties:
                phase: { type: string }
                readyReplicas: { type: integer }
                message: { type: string }
```

Design notes to *say out loud* in interviews: versioned group (`v1alpha1` → conversion webhooks later), OpenAPI validation as the first security layer, `status` subresource so controllers and users never fight over the same field, printer columns for operability.

## 5. Phase 2 — The operator (kopf, Python)

Why kopf: you're building Python fluency, and it maps 1:1 onto operator concepts (watch → reconcile → own → status). The **Go/Kubebuilder appendix** (§11) gives you the Cisco-JD keyword; concepts transfer wholesale.

`operator/operator.py` (complete core):

```python
import kopf
import kubernetes
from kubernetes import client

GROUP, VERSION, PLURAL = "platform.akshay.dev", "v1alpha1", "modeldeployments"

def desired_deployment(name, ns, spec):
    model = spec["model"]
    max_len = spec.get("maxModelLen", 4096)
    gpu = spec.get("gpu", {}).get("count", 1)
    return {
        "apiVersion": "apps/v1", "kind": "Deployment",
        "metadata": {"name": f"mdep-{name}", "namespace": ns,
                     "labels": {"app": f"mdep-{name}", "platform.akshay.dev/tenant": ns}},
        "spec": {
            "replicas": spec.get("replicas", {}).get("min", 1),
            "selector": {"matchLabels": {"app": f"mdep-{name}"}},
            "template": {
                "metadata": {"labels": {"app": f"mdep-{name}",
                                        "platform.akshay.dev/tenant": ns}},
                "spec": {
                    "tolerations": [{"key": "nvidia.com/gpu",
                                     "operator": "Exists", "effect": "NoSchedule"}],
                    "containers": [{
                        "name": "vllm",
                        "image": "vllm/vllm-openai:v0.8.5",
                        "args": [f"--model={model}", f"--max-model-len={max_len}",
                                 "--gpu-memory-utilization=0.90", "--dtype=half",
                                 "--port=8000"],
                        "ports": [{"containerPort": 8000}],
                        "readinessProbe": {"httpGet": {"path": "/health", "port": 8000},
                                            "initialDelaySeconds": 60},
                        "resources": {"limits": {"nvidia.com/gpu": gpu, "memory": "14Gi"},
                                      "requests": {"cpu": "2", "memory": "8Gi"}},
                    }],
                },
            },
        },
    }

def desired_service(name, ns):
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": f"mdep-{name}", "namespace": ns,
                         "labels": {"app": f"mdep-{name}"}},
            "spec": {"selector": {"app": f"mdep-{name}"},
                     "ports": [{"name": "http", "port": 8000, "targetPort": 8000}]}}

def desired_scaledobject(name, ns, spec):
    rep = spec.get("replicas", {})
    return {"apiVersion": "keda.sh/v1alpha1", "kind": "ScaledObject",
            "metadata": {"name": f"mdep-{name}", "namespace": ns},
            "spec": {"scaleTargetRef": {"name": f"mdep-{name}"},
                     "minReplicaCount": rep.get("min", 1),
                     "maxReplicaCount": rep.get("max", 2),
                     "triggers": [{"type": "prometheus", "metadata": {
                         "serverAddress": "http://kps-kube-prometheus-stack-prometheus.monitoring:9090",
                         "query": f'sum(vllm:num_requests_waiting{{namespace="{ns}",pod=~"mdep-{name}.*"}})',
                         "threshold": "5"}}]}}

@kopf.on.create(GROUP, VERSION, PLURAL)
@kopf.on.update(GROUP, VERSION, PLURAL)
def reconcile(spec, name, namespace, patch, **_):
    """Level-triggered reconcile: compute desired, server-side apply, report status."""
    api = client.ApiClient()
    for obj in (desired_deployment(name, namespace, dict(spec)),
                desired_service(name, namespace),
                desired_scaledobject(name, namespace, dict(spec))):
        kopf.adopt(obj)                      # ownerReferences → GC on CR delete
        _apply(api, obj)
    patch.status["phase"] = "Reconciling"
    patch.status["message"] = f"applied deployment/service/scaledobject for {spec['model']}"

def _apply(api, obj):
    """Server-side apply via dynamic client — idempotent create-or-update."""
    from kubernetes.dynamic import DynamicClient
    dyn = DynamicClient(api)
    res = dyn.resources.get(api_version=obj["apiVersion"], kind=obj["kind"])
    res.server_side_apply(body=obj, field_manager="model-operator",
                          namespace=obj["metadata"].get("namespace"))

@kopf.timer(GROUP, VERSION, PLURAL, interval=30)
def sync_status(name, namespace, patch, **_):
    """Copy readiness from the child Deployment into CR status."""
    apps = client.AppsV1Api()
    try:
        d = apps.read_namespaced_deployment(f"mdep-{name}", namespace)
        ready = d.status.ready_replicas or 0
        patch.status["readyReplicas"] = ready
        patch.status["phase"] = "Ready" if ready >= 1 else "Pending"
    except client.exceptions.ApiException:
        patch.status["phase"] = "Degraded"

@kopf.on.delete(GROUP, VERSION, PLURAL)
def on_delete(name, **_):
    # children carry ownerReferences (kopf.adopt) → K8s garbage-collects them.
    kopf.info(None, reason="Deleted", message=f"{name} children GC'd via ownerRefs")
```

RBAC (`operator/rbac.yaml`): ClusterRole over `modeldeployments` (+status), `deployments`, `services`, `scaledobjects`, events. Run it first as `kopf run operator.py` from your laptop against kind; containerize after it works.

**The self-healing demo:** `kubectl delete deploy mdep-support-bot -n tenant-a` → operator recreates it on the next event/timer. `kubectl delete mdep support-bot` → *everything* garbage-collects. Reconcile loop, proven — the same pattern as Karpenter and ArgoCD, but now **you wrote one**.

## 6. Phase 3 — Hard multi-tenancy

Per-tenant template (`tenancy/tenant-template/`):

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: gpu-quota, namespace: tenant-a }
spec:
  hard:
    requests.nvidia.com/gpu: "1"     # fairness: no tenant can hog the fleet
    limits.memory: 32Gi
    pods: "10"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: gateway-only, namespace: tenant-a }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { role: gateway }   # only the gateway ns reaches model pods
```

Kyverno guardrails (`tenancy/kyverno-policies.yaml`):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: mdep-guardrails }
spec:
  validationFailureAction: Enforce
  rules:
    - name: gpu-pods-only-from-operator          # tenants can't bypass the CRD
      match:
        any: [{ resources: { kinds: [Pod], namespaceSelector:
                 { matchLabels: { platform.akshay.dev/tenant: "true" } } } }]
      validate:
        message: "GPU pods must be created via ModelDeployment (operator-owned)."
        pattern:
          metadata:
            ownerReferences:
              - apiVersion: "apps/v1"
        deny:
          conditions:
            any:
              - key: "{{ request.object.spec.containers[?resources.limits.\"nvidia.com/gpu\"] | length(@) }}"
                operator: GreaterThan
                value: 0
              - key: "{{ request.object.metadata.labels.\"app\" || '' }}"
                operator: NotEquals
                value: "mdep-*"
    - name: no-privileged
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Privileged pods are not allowed."
        pattern:
          spec:
            containers:
              - =(securityContext): { =(privileged): "false" }
```

Demo: as tenant-a, try `kubectl run cheat --image=... --limits=nvidia.com/gpu=1` → **denied by admission**. Then apply a second `ModelDeployment` exceeding quota → operator's child Deployment sits pending, CR status says `Degraded: quota` (add that branch). Both screenshots go in the README.

## 7. Phase 4 — Gateway: auth + per-tenant rate limiting

Use **Envoy Gateway** (Gateway API — the modern answer; NGINX-ingress annotations are the legacy fallback):

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.4 -n envoy-gateway-system --create-namespace
```

`gateway/routes.yaml` (per tenant/model):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: tenant-a-support-bot, namespace: tenant-a }
spec:
  parentRefs: [{ name: platform-gw, namespace: gateway }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /tenant-a/support-bot } }]
      filters:
        - type: URLRewrite
          urlRewrite: { path: { type: ReplacePrefixMatch, replacePrefixMatch: / } }
      backendRefs: [{ name: mdep-support-bot, port: 8000 }]
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata: { name: tenant-a-rl, namespace: tenant-a }
spec:
  targetRefs: [{ group: gateway.networking.k8s.io, kind: HTTPRoute, name: tenant-a-support-bot }]
  rateLimit:
    type: Local
    local:
      rules:
        - limit: { requests: 120, unit: Minute }   # mirrors spec.rateLimit
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata: { name: tenant-a-auth, namespace: tenant-a }
spec:
  targetRefs: [{ group: gateway.networking.k8s.io, kind: HTTPRoute, name: tenant-a-support-bot }]
  apiKeyAuth:
    credentialRefs: [{ name: tenant-a-keys, group: "", kind: Secret }]
    extractFrom: [{ headers: ["x-api-key"] }]
```

**Stretch inside the phase:** teach the operator to emit these three objects too, so `spec.rateLimit` is honored end-to-end from the CR. Then k6 at 3× the limit → graph the 429s.

## 8. Phase 5 — FinOps: GPU cost per tenant

```bash
helm install opencost opencost/opencost -n opencost --create-namespace \
  --set opencost.prometheus.internal.serviceName=kps-kube-prometheus-stack-prometheus \
  --set opencost.prometheus.internal.namespaceName=monitoring
```

`finops/cost-report.py` — the chargeback artifact (queries OpenCost's allocation API, prints per-tenant GPU-hours and $):

```python
import requests, tabulate
r = requests.get("http://localhost:9003/allocation",
                 params={"window": "7d", "aggregate": "namespace"}).json()
rows = [(ns, f'{a["gpuHours"]:.1f}', f'${a["gpuCost"]:.2f}', f'${a["totalCost"]:.2f}')
        for ns, a in r["data"][0].items() if ns.startswith("tenant-")]
print(tabulate.tabulate(rows, headers=["tenant", "GPU-hrs", "GPU $", "total $"]))
```

Also add a Grafana panel: `sum by (namespace) (DCGM_FI_DEV_GPU_UTIL * on(...) ...)` — *utilization* per tenant next to *cost* per tenant is the exact FinOps conversation from your Harman chargeback work, now on AI workloads.

## 9. Phase 6 — SLOs, burn-rate alerts, DR

`slo/prometheusrules-slo.yaml` — availability SLO 99% + latency SLO, multi-window multi-burn (Google SRE style):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata: { name: mdep-slo, namespace: monitoring }
spec:
  groups:
    - name: mdep-slo
      rules:
        - record: mdep:error_ratio:5m
          expr: |
            sum(rate(vllm:request_failure_total{namespace=~"tenant-.*"}[5m]))
            / sum(rate(vllm:request_success_total{namespace=~"tenant-.*"}[5m])
                + rate(vllm:request_failure_total{namespace=~"tenant-.*"}[5m]))
        - alert: MdepFastBurn      # 2% of 30-day budget in 1h
          expr: mdep:error_ratio:5m > (14.4 * 0.01)
          for: 5m
          labels: { severity: critical }
        - alert: MdepSlowBurn
          expr: mdep:error_ratio:5m > (3 * 0.01)
          for: 1h
          labels: { severity: warning }
        - alert: MdepLatencySLO
          expr: |
            histogram_quantile(0.95, sum by (le)
              (rate(vllm:e2e_request_latency_seconds_bucket{namespace=~"tenant-.*"}[5m]))) > 8
          for: 10m
          labels: { severity: warning }
```

**Chaos test + runbook:** with k6 running, kill the GPU node. Record the timeline (429s/timeouts → KEDA holds → Karpenter re-provisions ~2 min → pods ready → SLO recovers), write it up as `runbooks/RUNBOOK-gpu-node-loss.md` with detection query, impact, mitigation steps, and a filled **postmortem** using your template. The remote-platform JD explicitly asks for exactly these documents.

## 10. Validation checklist (the demo script for interviews)

1. `kubectl apply -f examples/tenant-a-supportbot.yaml` → 90s later, curl through the gateway with tenant-a's API key → completion returns.
2. Delete the child Deployment → operator heals it.
3. Tenant tries a raw GPU pod → Kyverno denies.
4. k6 over rate limit → 429s; over queue threshold → KEDA scales within quota, never past it.
5. `cost-report.py` → per-tenant GPU $ table.
6. Node-kill chaos → SLO dashboard dips and recovers; runbook matches reality.

## 11. Appendix — the Go/Kubebuilder bridge (for the Cisco JD keyword)

Concept map you already own after kopf → `kubebuilder init --domain akshay.dev; kubebuilder create api --group platform --version v1alpha1 --kind ModelDeployment`:

| kopf (done) | Kubebuilder (next) |
|---|---|
| `@kopf.on.create/update` | `Reconcile(ctx, req)` |
| `kopf.adopt()` | `controllerutil.SetControllerReference` |
| `_apply` server-side apply | `controllerutil.CreateOrUpdate` |
| `patch.status[...]` | `r.Status().Update(ctx, &md)` |
| `@kopf.timer` | `RequeueAfter: 30 * time.Second` |

Port just the Deployment-reconcile path to Go as a learning exercise; keep kopf as the full implementation. Now "operator pattern, Kubebuilder" on your resume is honest.

## 12. Interview ammunition

- *"Designed and implemented a Kubernetes control plane for multi-tenant LLM serving: a `ModelDeployment` CRD + operator (level-triggered reconcile, server-side apply, ownerRef GC, status subresource) that provisions vLLM + KEDA + gateway routes per tenant, with GPU ResourceQuotas, Kyverno admission guardrails, per-tenant API-key auth and rate limits, OpenCost chargeback, and 99% SLOs with multi-window burn-rate alerting."*
- That sentence **is** the Cisco Control Plane JD. Every noun in it is something you built and can demo.

## 13. Stretch goals

1. **Conversion webhook**: add `v1beta1` with a renamed field; migrate live CRs.
2. Operator-managed **canary** per ModelDeployment (two child Deployments + weighted HTTPRoute) — merges Project 2's rollout into the control plane.
3. **vCluster** per tenant instead of namespaces — the hard-multi-tenancy model from the GPU-neocloud JD; write the comparison doc.
4. gRPC admin API in front of the CRs (Cisco JD: "GRPC, REST APIs, and CLI") + a `platformctl` Python CLI.
