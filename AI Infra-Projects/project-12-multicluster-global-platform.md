# Project 12 — Multi-Cluster Global AI Platform: Fleet, DR & Capacity Arbitrage

> The capstone-of-capstones: operate a **fleet** the way SentinelOne (70+ clusters) or a GPU-neocloud does. Federate multiple K8s clusters with **Cluster API** lifecycle, **fleet GitOps** (ArgoCD ApplicationSets), **cross-cluster service mesh**, **MultiKueue** GPU-job dispatch to wherever capacity/price is best, a **regional DR** runbook with real failover, and **cross-cluster cost governance**. Everything from P1–P11 becomes one globally-scheduled platform.

| | |
|---|---|
| **Difficulty** | Expert (the hardest) |
| **Time** | 5–6 weekends |
| **Prereq** | P4 (ArgoCD), P6 (control plane), P7 (Kueue/MultiKueue), P11 (observability) |
| **Cloud cost** | Control/management plane is CPU-only (kind or small EKS). GPU only during dispatch demos, sessions-only. ~$0.20–0.60/hr during GPU tests. |
| **Skills proven** | Cluster API (CAPI/CAPA) declarative cluster lifecycle, fleet GitOps (ApplicationSets + cluster generator), multi-cluster mesh (Istio/Cilium Cluster Mesh), MultiKueue federated scheduling, regional DR (RPO/RTO with failover drill), multi-cluster cost attribution, provider/region capacity arbitrage |
| **JD keywords hit** | "70+ K8s clusters, multi-region AWS (EKS) and GCP (GKE)" · "Cluster API (CAPI) with bare-metal providers" · "Cluster Mesh for multi-datacenter connectivity" · "MultiKueue" · "6–12 month capacity forecasting" · "DRP documentation" |

---

## 1. The fleet operating model

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

## 2. Phase 1 — Declarative cluster lifecycle with Cluster API

The remote JD asks for CAPI by name. Management cluster runs CAPI + a provider:

```bash
clusterctl init --infrastructure aws          # or docker (CAPD) for free kind-in-kind
```

A cluster becomes a Git-managed object:

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

Demo: `git commit` a new `Cluster` → CAPI provisions it → it auto-registers with the hub (Phase 2). `clusterctl move` the mgmt state between clusters to show pivot/DR of the *management plane itself*. (CAPD/docker provider does all of this on kind for $0 — use it for the write-up, keep one real CAPA cluster for the screenshot.)

## 3. Phase 2 — Fleet GitOps (ArgoCD ApplicationSets)

One Application definition, **auto-applied to every matching cluster** via the cluster generator:

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

Now GPU Operator + DCGM + Kueue-worker land on **every** GPU cluster automatically, and a new cluster is production-ready the moment CAPI registers it. Add an **overlay generator** (git-directories) so `region: eu-west` clusters get data-residency policies (Kyverno from P6). This is fleet management — the SentinelOne JD's core.

## 4. Phase 3 — Cross-cluster connectivity (Cluster Mesh)

Services in cluster A reach cluster B by name — required for disaggregated serving (P10) or cross-region failover. Two documented paths:

- **Cilium Cluster Mesh:** `cilium clustermesh enable` on each, `cilium clustermesh connect --context A --context B`; global services via `service.cilium.io/global: "true"` — pods load-balance across clusters transparently.
- **Istio multi-primary:** shared trust root, east-west gateways, endpoint discovery across clusters.

Demo: a global `InferencePool`-fronted vLLM Service where cluster A's gateway fails over to cluster B's pods when A's are drained — cross-cluster resilience, shown. (On kind, Cilium Cluster Mesh between two kind clusters works and is the free path.)

## 5. Phase 4 — MultiKueue: schedule GPU jobs across the fleet

The payoff. Submit a training job to the **manager**; MultiKueue dispatches it to whichever worker cluster has free GPU quota — or the cheapest:

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

A ClusterQueue referencing that AdmissionCheck now spans clusters. Submit the **P9 PyTorchJob** or **P5 RayJob** to the manager → watch it land where capacity exists → results/status stream back. Scenarios: us-east full → job runs in eu-west; add `spot-cheap` with higher quota → jobs prefer it (**capacity arbitrage**). This is global GPU scheduling — the frontier of what P7/P8 did on one cluster.

**The arbitrage brain (stretch, but the flex):** a Python controller that reads each cluster's spot price (AWS/GCP pricing APIs) + free GPU quota + your P11 demand forecast, and re-weights MultiKueue placement toward the cheapest capacity that meets the job's region/data constraints. That's a **FinOps scheduler** — write the design even if you only demo a stub.

## 6. Phase 5 — Regional DR drill (with real failover)

`docs/DR-PLAN.md` + an executed drill, not just a doc:

- **Define RPO/RTO** per component: stateless serving (RTO minutes, RPO 0), Kafka (RPO = replication lag), vector DB (RPO = snapshot interval), MLflow/Postgres (RPO = backup interval), model artifacts in S3 (cross-region replication, RPO ~0).
- **Backup/restore:** Velero for cluster state; S3 CRR for artifacts; scheduled Qdrant/Postgres snapshots to another region.
- **The drill (record it):** with traffic running through the mesh, **destroy the primary GPU cluster** (`clusterctl delete cluster gpu-us-east`). Observe: mesh fails serving over to eu-west; MultiKueue re-dispatches in-flight training (resumes from S3 checkpoints — P5/P9); GitOps rebuilds a replacement cluster from CAPI manifests. Measure **actual RTO** vs target; write the **postmortem**.

The GPU-neocloud and remote JDs both explicitly want DRP + postmortems + chaos — this is that, at fleet scale.

## 7. Phase 6 — Global observability & cost governance

- **Metrics:** Thanos or Mimir remote-write from every cluster → one Grafana with a `cluster` label → global fleet health (extends P11 across the fleet).
- **Cost:** OpenCost per cluster → aggregated report: **$/team/cluster/region and $/GPU-hour by provider** — the input to arbitrage and the artifact every FinOps-flavored JD wants. Add "cost of DR standby capacity" as a line item (the honest trade-off conversation).
- **Capacity forecasting:** feed P11's demand model per region → 6–12 month GPU capacity plan (remote JD, verbatim ask).

## 8. Validation checklist

- [ ] New cluster created from a Git commit via CAPI; auto-registered to the hub
- [ ] ApplicationSet rolls the platform baseline to all GPU clusters; a fresh cluster self-configures
- [ ] Cross-cluster global service fails over A→B under drain
- [ ] MultiKueue dispatches a training job to a remote cluster by capacity, then by cost
- [ ] DR drill executed: primary destroyed, serving + training + cluster recovered; RTO measured; postmortem written
- [ ] Global Grafana + multi-cluster cost report live

## 9. Teardown

`clusterctl delete cluster --all` (or `kind delete clusters --all`); confirm zero `nodeclaims`/MachineDeployments at replicas>0; Velero backups and S3 artifacts retained or purged deliberately. The management cluster is CPU-cheap.

## 10. Interview ammunition

- *"Operated a multi-cluster global AI platform: Cluster API for declarative cluster lifecycle, ArgoCD ApplicationSets rolling the full GPU platform (operator, DCGM, Kueue) to every cluster, Cilium Cluster Mesh for cross-cluster failover, and MultiKueue dispatching GPU training jobs across regions by capacity and spot price. Ran a regional DR drill — destroyed the primary, recovered serving and resumed checkpointed training in the failover region within RTO — and governed cost with per-cluster OpenCost attribution feeding a capacity-arbitrage scheduler."*
- That paragraph maps line-by-line onto the SentinelOne Staff and remote-Platform JDs — the two most senior roles in your set.
- Whiteboard-ready: hub-and-spoke fleet model; why ApplicationSets over per-cluster Apps; Cluster Mesh trust/discovery; MultiKueue dispatch semantics; RPO/RTO per stateful component; the cost of DR standby vs the cost of an outage; capacity arbitrage constraints (data residency, egress, quota).

## 11. Stretch goals

1. **Immutable OS** workers (Talos Linux via CAPI's Talos bootstrap) — the remote JD's "Talos/Flatcar" nice-to-have; write the diff vs AL2023.
2. **vCluster** virtual clusters as cheap per-team "clusters" within one real cluster — merges the hard-multi-tenancy JD with fleet ops.
3. **Progressive fleet rollout**: canary a platform change to 10% of clusters (ApplicationSet + Argo Rollouts) before fleet-wide — the safe way to change 70 clusters.
4. **Policy fleet**: Kyverno policies distributed and reported centrally (Policy Reporter) across all clusters for SOC2/ISO evidence (remote JD compliance ask).
