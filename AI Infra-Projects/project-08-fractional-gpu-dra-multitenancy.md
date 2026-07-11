# Project 08 — Slice: A Fractional-GPU Multi-Tenant Platform (MIG + DRA + KAI + Kueue)

**Difficulty:** ★★★★☆ | **Time:** 3 weekends | **Cost:** ~$15–40 (g5/g6 spot for sharing; 2–3 hr p4d window for MIG)
**GPU-scheduling project 2 of 2.**

## 1. The production problem

A whole H100 for a notebook or a 7B-model dev endpoint wastes >90 % of a very expensive chip. Every internal GPU cloud (and every "neocloud" — see your uploaded JD: *"GPU Operator setup… validated vCluster environment"*) therefore runs **GPU sharing** with **hard multi-tenant quotas**:

- **MIG** (A100/H100/H200/B200): hardware partitions — isolated memory + SMs. Safe for untrusted tenants.
- **Time-slicing** (any GPU, e.g. A10G/L4): kubelet advertises N replicas of one GPU; no isolation, fine for bursty dev.
- **MPS**: concurrent kernels from multiple processes; memory limits but weaker fault isolation.
- **DRA (Dynamic Resource Allocation)**: the *future* of device scheduling in Kubernetes — devices become first-class API objects (`DeviceClass`, `ResourceClaim`) selected with CEL, replacing the opaque `nvidia.com/gpu: 1` counter. Core DRA is GA in Kubernetes 1.34; NVIDIA ships a DRA driver.
- **KAI Scheduler**: NVIDIA's open-sourced (Apache-2.0) scheduler from the Run:ai acquisition — queues, fair-share, gang, and *fractional* GPU requests (`0.5` GPU).

You'll run all five, then impose org-level quota/borrowing with **Kueue**, and close the loop with per-team **chargeback** — the exact shape of an internal ML platform.

## 2. Architecture

```
 Team queues (Kueue ClusterQueues in one cohort, borrowing enabled)
        │ admission (quota, priority, preemption)
        ▼
 KAI / kube-scheduler ──▶ Node pools:
   ├── pool-mig     : p4d (A100) — MIG mixed profiles (1g.5gb…7g.40gb)
   ├── pool-shared  : g5 (A10G)  — time-slicing ×4 (+ optional MPS)
   └── pool-whole   : g6 (L4)    — exclusive GPUs, DRA-managed
 DCGM-exporter ──▶ Prometheus ──▶ per-namespace GPU-hour chargeback
```

## 3. Phase 1 — GPU Operator with mixed MIG + time-slicing

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm upgrade -i gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
  --set mig.strategy=mixed \
  --set migManager.enabled=true \
  --set dcgmExporter.enabled=true
```

**Time-slicing** (A10G pool) — ConfigMap + ClusterPolicy patch:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: time-slicing-config, namespace: gpu-operator}
data:
  a10g-shared: |
    version: v1
    flags: {migStrategy: none}
    sharing:
      timeSlicing:
        renameByDefault: true      # exposes nvidia.com/gpu.shared
        resources:
        - name: nvidia.com/gpu
          replicas: 4
```
```bash
kubectl patch clusterpolicies.nvidia.com cluster-policy --type merge -p \
  '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"a10g-shared"}}}}'
# opt a node in:
kubectl label node <a10g-node> nvidia.com/device-plugin.config=a10g-shared
kubectl describe node <a10g-node> | grep nvidia.com/gpu.shared   # expect: 4
```

**MIG** (A100 pool) — declarative via node label; mig-manager drains, reconfigures, uncordons:

```bash
kubectl label node <p4d-node> nvidia.com/mig.config=all-balanced --overwrite
# 'all-balanced' on A100-40GB ⇒ per GPU: 2×1g.5gb + 1×2g.10gb + 1×3g.20gb
kubectl get node <p4d-node> -o json | jq '.status.allocatable' \
  | grep 'nvidia.com/mig'   # e.g. nvidia.com/mig-1g.5gb: "16"
```

Pods then request `resources: {limits: {nvidia.com/mig-1g.5gb: 1}}`. Add a custom mig-parted profile (in the `custom-mig-parted-config` ConfigMap) to show you can go beyond the presets.

**MPS** (optional, same ConfigMap mechanism): `sharing.mps.resources[{name: nvidia.com/gpu, replicas: 4}]` — then contrast fault-isolation behavior vs. time-slicing by crashing one client.

## 4. Phase 2 — DRA: the new way to ask for devices

Requirements: Kubernetes ≥1.32 (beta, feature gates + `resource.k8s.io/v1beta1`) or ≥1.34 (GA, `resource.k8s.io/v1`). Start on **kind** with the NVIDIA `k8s-dra-driver-gpu`, then on EKS once your platform version supports it.

```yaml
# A class of devices, selected by CEL over vendor-published attributes
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata: {name: single-a10g}
spec:
  selectors:
  - cel:
      expression: >-
        device.driver == "gpu.nvidia.com" &&
        device.attributes["gpu.nvidia.com"].productName.matches(".*A10G.*")
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata: {name: one-gpu}
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly: {deviceClassName: single-a10g, count: 1}
---
apiVersion: v1
kind: Pod
metadata: {name: dra-smoke}
spec:
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: one-gpu
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources: {claims: [{name: gpu}]}
```

Why DRA matters (say this in interviews): claims are **structured and shareable** — one claim can be mounted by multiple pods; CEL selects on memory size, MIG profile, NVLink domain; and it's the foundation for scheduling *fabric-attached* accelerators. Demonstrate a **shared claim**: two pods referencing the same `ResourceClaim` co-located on one GPU.

## 5. Phase 3 — KAI Scheduler: queues, fair-share, fractions

```bash
helm upgrade -i kai-scheduler oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler \
  -n kai-scheduler --create-namespace    # pin a released version; API surface evolves
```

Queues (hierarchical: department → team) — check your chart version's CRD group:

```yaml
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: dept-ml}
spec:
  resources:
    gpu: {quota: 8, limit: 12, overQuotaWeight: 1}
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata: {name: team-nlp}
spec:
  parentQueue: dept-ml
  resources:
    gpu: {quota: 4, limit: 8, overQuotaWeight: 2}
```

A **half-GPU** workload:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dev-notebook
  labels: {kai.scheduler/queue: team-nlp}
  annotations: {gpu-fraction: "0.5"}
spec:
  schedulerName: kai-scheduler
  containers:
  - name: nb
    image: jupyter/pytorch-notebook
```

Experiments to run and record: (1) two 0.5-fraction pods pack onto one A10G; (2) team-nlp bursts to 8 GPUs when idle, gets **reclaimed** back to quota=4 when dept siblings submit (fair-share + preemption); (3) a 4-pod gang via KAI's pod-grouper is all-or-nothing (compare with your P07 implementation).

## 6. Phase 4 — Kueue quotas, cohorts, borrowing, preemption

Where KAI is placement-time, Kueue is **admission-time** (works with any scheduler — pair it with your P07 scheduler):

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata: {name: a10g-shared}
spec:
  nodeLabels: {nvidia.com/device-plugin.config: a10g-shared}
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata: {name: cq-research}
spec:
  cohort: gpu-fleet
  preemption:
    reclaimWithinCohort: Any
    withinClusterQueue: LowerPriority
  resourceGroups:
  - coveredResources: ["nvidia.com/gpu.shared"]
    flavors:
    - name: a10g-shared
      resources:
      - name: nvidia.com/gpu.shared
        nominalQuota: 8
        borrowingLimit: 8        # may borrow idle quota from cohort peers
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata: {name: research, namespace: team-research}
spec: {clusterQueue: cq-research}
```

Drill: fill `cq-research` beyond nominal via borrowing, then submit to a sibling queue → watch Kueue **preempt the borrowed workloads** (`kubectl get workloads -A -o wide`). This admission-vs-placement distinction (Kueue vs KAI/Volcano) is a classic interview question — you'll have run both.

## 7. Phase 5 — chargeback (FinOps)

Prometheus recording rules (DCGM + KSM):

```yaml
groups:
- name: gpu-chargeback
  rules:
  - record: namespace:gpu_requested:sum
    expr: sum by (namespace) (kube_pod_container_resource_requests{resource=~"nvidia_com_gpu.*"} 
          * on(pod, namespace) group_left kube_pod_status_phase{phase="Running"})
  - record: namespace:gpu_util:avg
    expr: avg by (exported_namespace) (DCGM_FI_DEV_GPU_UTIL)
```

Monthly cost = `namespace:gpu_requested:sum` integrated over time × $/GPU-hr per flavor (A100 slice priced at profile fraction). Grafana table: *requested GPU-hours vs. actually-utilized GPU-hours* per team — the gap **is** the business case for fractional GPUs. This satisfies the "cost optimization & tagging governance" line in your AWS JD.

## 8. Done criteria & interview ammo

- [ ] One cluster simultaneously serving: MIG slices, ×4 time-sliced A10Gs, DRA-claimed GPUs, KAI 0.5-fractions — with a written **isolation comparison** (memory protection? fault isolation? perf interference measured with concurrent `gpu-burn` + inference latency).
- [ ] Quota + borrowing + preemption demonstrated in both Kueue and KAI.
- [ ] Chargeback dashboard with a real utilization-gap finding.

**Resume bullet:** *"Designed a multi-tenant fractional-GPU platform on EKS: MIG (mixed profiles via GPU Operator/mig-manager), time-slicing and MPS pools, Kubernetes DRA (DeviceClass/ResourceClaim with CEL selection), NVIDIA KAI fractional scheduling, and Kueue cohort quotas with borrowing/preemption; delivered per-team GPU-hour chargeback that exposed a 60 % request-vs-utilization gap."*

**Teardown:** `helm uninstall` all, `kubectl label node nvidia.com/mig.config-`, `eksctl delete nodegroup` the p4d pool *first* (it's the $32/hr one).

## 9. Extensions

- **vCluster per tenant** (straight from the neocloud JD): give each team a virtual cluster whose nodes are backed by your shared GPU pools.
- DRA **ComputeDomains** for multi-node NVLink (GB200-class) — read the NVIDIA DRA driver docs and write a design note even without the hardware.
- Admission policy (Kyverno/ValidatingAdmissionPolicy): reject pods requesting whole GPUs in dev namespaces.
