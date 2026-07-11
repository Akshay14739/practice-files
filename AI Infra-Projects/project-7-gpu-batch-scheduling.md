# Project 7 — GPU Batch Scheduling Deep Dive: Kueue vs Volcano, Gang, Preemption & DRA
### 🎯 GPU SCHEDULING PROJECT 1 of 2

> Become the engineer who owns the question every AI company fights daily: **"which job gets the GPUs, when, and why?"** You'll run the same contended-cluster scenarios through **Kueue** and **Volcano**, implement priority + preemption + quota borrowing across teams, prove **gang scheduling** prevents deadlock, adopt **DRA (Dynamic Resource Allocation)** — the new Kubernetes-native GPU allocation API — and ship a Python **fragmentation/utilization analyzer** for the fleet.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 4–5 weekends |
| **Prereq** | Project 1 (GPU platform), Project 5 (Kueue basics, RayJobs) |
| **Cloud cost** | Most scenarios run on **kind with fake GPUs** (free). Real-GPU validation: 2× `g4dn.xlarge` spot ≈ $0.30–0.50/hr, sessions only. |
| **Skills proven** | kube-scheduler internals, gang/co-scheduling, priority & preemption semantics, hierarchical quota (cohorts/borrowing), fair sharing, Volcano vs Kueue vs YuniKorn trade-offs, **DRA ResourceClaims/DeviceClasses**, scheduling observability |
| **JD keywords hit** | "orchestration and management of AI workloads" · "multi-tenant resource allocation" · "design intelligent… scalable architecture for ML subsystems" · every training-platform JD's hidden core |

---

## 1. Why this is the differentiator

Inference scales with KEDA. **Training is a batch-HPC problem wearing a Kubernetes costume**, and default kube-scheduler is actively wrong for it:

1. **Deadlock:** two 4-GPU jobs on an 6-GPU cluster each grab 3 GPUs → both wait forever. Pods schedule *individually*; jobs need **all-or-nothing (gang)**.
2. **Starvation:** a stream of small jobs perpetually delays the big pretraining run → need **priority + preemption**.
3. **Hoarding:** team A's idle quota can't help team B's queue → need **cohorts/borrowing with reclaim**.
4. **Fragmentation:** 8 nodes each with 1 free GPU = 8 free GPUs that can't run one 8-GPU job → need **bin-packing awareness + a way to measure it**.

You'll create each failure on purpose, then fix it with the right mechanism. That before/after is the whole portfolio piece.

## 2. Lab topology (free tier)

Real GPUs are unnecessary for *scheduler* behavior — the scheduler only reads `nvidia.com/gpu` in node status. Build a kind cluster and **stub the capacity**:

```bash
kind create cluster --name sched-lab --config kind-3workers.yaml   # 1 cp + 3 workers

# Fake 4 GPUs per worker (status subresource patch)
for n in sched-lab-worker sched-lab-worker2 sched-lab-worker3; do
  kubectl patch node $n --subresource=status --type=json -p='[
    {"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"4"},
    {"op":"add","path":"/status/allocatable/nvidia.com~1gpu","value":"4"}]'
done
kubectl describe node sched-lab-worker | grep nvidia   # 4 each, 12 total
```

Workload stand-in (`sleep`-based "training job") so scenarios are deterministic:

```yaml
# job-template.yaml — parameterize NAME/GPUS/PARALLELISM/DURATION with envsubst
apiVersion: batch/v1
kind: Job
metadata: { name: ${NAME}, labels: { team: ${TEAM} } }
spec:
  parallelism: ${PARALLELISM}      # pods in the gang
  completions: ${PARALLELISM}
  completionMode: Indexed
  template:
    metadata: { labels: { job: ${NAME} } }
    spec:
      restartPolicy: Never
      containers:
        - name: worker
          image: busybox
          command: ["sh","-c","echo training ${NAME}; sleep ${DURATION}"]
          resources: { limits: { nvidia.com/gpu: ${GPUS} } }
```

## 3. Phase 1 — Reproduce the pathologies (default scheduler)

**Deadlock demo:** submit `jobA` (4×1-GPU pods) and `jobB` (4×1-GPU pods) *simultaneously* onto a temporarily-shrunk 6-GPU cluster (cordon one worker). Watch each land 3 pods, then both stall `Pending` forever. Capture:

```bash
kubectl get pods -o wide | sort
kubectl get events --field-selector reason=FailedScheduling
```

**Starvation demo:** loop-submit 1-GPU/60s jobs every 20s; submit an 8-GPU job; measure its queue wait (it never runs). Save the timeline — you'll replay it under each scheduler.

## 4. Phase 2 — Kueue done properly (quotas, cohorts, borrowing, preemption)

You used Kueue minimally in P5. Now the real model — two teams, one cohort, borrowing with reclaim:

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata: { name: default-gpu }
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata: { name: team-a }
spec:
  cohort: research                       # shared borrowing pool
  namespaceSelector: {}
  preemption:
    withinClusterQueue: LowerPriority    # my high-prio evicts my low-prio
    reclaimWithinCohort: Any             # take back what others borrowed
    borrowWithinCohort:
      policy: LowerPriority
      maxPriorityThreshold: 100
  resourceGroups:
    - coveredResources: ["cpu","memory","nvidia.com/gpu"]
      flavors:
        - name: default-gpu
          resources:
            - name: "nvidia.com/gpu"
              nominalQuota: 6            # team A's guaranteed share
              borrowingLimit: 6          # may borrow up to 6 more from cohort
            - { name: cpu, nominalQuota: "24" }
            - { name: memory, nominalQuota: 96Gi }
---
# team-b: identical, nominalQuota 6
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata: { name: lq, namespace: team-a }
spec: { clusterQueue: team-a }
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: training-high }
value: 1000
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: training-low }
value: 100
```

Jobs opt in via labels:

```yaml
metadata:
  labels: { kueue.x-k8s.io/queue-name: lq }
spec:
  suspend: true                # Kueue's admission handle
  template:
    spec:
      priorityClassName: training-low
```

**Scenario matrix to run and screenshot** (each is one `Workload` watch: `kubectl get workloads -A -w`):

| # | Scenario | Expected Kueue behavior |
|---|----------|------------------------|
| S1 | A submits 12 GPUs of jobs; B idle | A borrows 6 from cohort → all run |
| S2 | Then B submits 6 GPUs | **Reclaim**: A's borrowed (lowest-prio) workloads evicted & re-queued; B gets nominal share |
| S3 | A low-prio running; A high-prio arrives, quota full | `withinClusterQueue` preemption |
| S4 | The 8-GPU job vs stream of small jobs | With priorities set, big job admitted as a unit — starvation gone |
| S5 | Deadlock replay (S from Phase 1) | **All-or-nothing admission**: second job stays `Suspended`, zero partial allocation |

Kueue admits **whole Workloads** (gang semantics at *admission*), which kills the deadlock class by construction. Say exactly that sentence in interviews.

**Topology-Aware Scheduling (TAS):** enable Kueue's `TopologyAwareScheduling` feature gate, label nodes with a fake topology (`cloud.provider.com/topology-block`, `.../topology-rack`), and show a 4-pod gang landing within one "rack" — the placement property that decides AllReduce bandwidth in real clusters (ties to P9).

## 5. Phase 3 — The same scenarios on Volcano

```bash
helm repo add volcano-sh https://volcano-sh.github.io/helm-charts
helm install volcano volcano-sh/volcano -n volcano-system --create-namespace
```

Volcano is a **true second scheduler** (`schedulerName: volcano`) with runtime gang semantics via PodGroups:

```yaml
apiVersion: batch.volcano.sh/v1alpha1
kind: Job                          # Volcano's own Job kind
metadata: { name: dist-train }
spec:
  schedulerName: volcano
  minAvailable: 4                  # THE gang knob: schedule only if 4 fit
  queue: team-a
  plugins: { ssh: [], svc: [] }    # injects worker discovery for real training
  tasks:
    - replicas: 4
      name: worker
      template:
        spec:
          containers:
            - name: worker
              image: busybox
              command: ["sh","-c","sleep 120"]
              resources: { limits: { nvidia.com/gpu: 1 } }
          restartPolicy: Never
---
apiVersion: scheduling.volcano.sh/v1beta1
kind: Queue
metadata: { name: team-a }
spec: { weight: 1, capability: { nvidia.com/gpu: 6 } }
```

Volcano's `actions: enqueue, allocate, preempt, reclaim, backfill` + plugins (`gang, priority, drf, binpack, proportion`) are configured in the `volcano-scheduler` ConfigMap. Turn **DRF** (dominant-resource fairness) and **binpack** on, rerun S1–S5, and record the differences.

**Write the comparison doc** (`docs/kueue-vs-volcano.md`) — this becomes a blog post with reach:

| Dimension | Kueue | Volcano |
|---|---|---|
| Model | Quota/admission controller *in front of* kube-scheduler (suspend/resume) | Full replacement scheduler with PodGroups |
| Gang | At admission (all-or-nothing quota) | At placement (minAvailable, runtime) |
| Fairness | Cohorts, borrowing, fair sharing | DRF, hierarchical queues |
| Bin-packing | Delegates to kube-scheduler scoring / TAS | Native binpack plugin |
| Ecosystem | K8s-SIG; JobSet/Kubeflow/Ray integrations | CNCF; strong AI/HPC history (also YuniKorn as the third option — mention it) |
| Ops risk | Low (stock scheduler untouched) | Higher (second scheduler to run) |

## 6. Phase 4 — DRA: the future of GPU allocation (GA in K8s 1.34)

Device plugins expose an opaque counter (`nvidia.com/gpu: 4`). **DRA** replaces that with first-class API objects — this is where scheduling is going, and almost no candidates can demo it:

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata: { name: gpu.nvidia.com }
spec:
  selectors:
    - cel: { expression: device.driver == "gpu.nvidia.com" }
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata: { name: one-a100-40gb }
spec:
  spec:
    devices:
      requests:
        - name: gpu
          deviceClassName: gpu.nvidia.com
          selectors:
            - cel:
                expression: >-
                  device.attributes["gpu.nvidia.com"].productName.matches("A100") &&
                  device.capacity["gpu.nvidia.com"].memory >= quantity("40Gi")
---
# pod consumes the claim instead of resources.limits
spec:
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: one-a100-40gb
  containers:
    - name: train
      resources:
        claims: [{ name: gpu }]
```

Lab paths: (a) kind 1.34 + the **CEL-selectable example DRA driver** (dra-example-driver) to exercise the API for free; (b) real path on one `g4dn` with the **NVIDIA DRA driver** (`k8s-dra-driver-gpu`) — list `ResourceSlices`, watch claim allocation, and demo *attribute-based* selection ("give me any GPU with ≥15Gi") that device plugins simply cannot express. Close with the one-pager: device plugin vs DRA (counter vs structured claims; no attributes vs CEL selectors; no sharing model vs claims shareable between pods; MIG as pre-carved resources vs dynamically claimable partitions).

## 7. Phase 5 — Fleet fragmentation & scheduling observability (your Python tool)

`tools/gpu_frag.py` — the artifact interviewers remember:

```python
"""GPU fleet analyzer: utilization, fragmentation, largest schedulable gang."""
from collections import Counter
from kubernetes import client, config

config.load_kube_config()
v1 = client.CoreV1Api()

def gpu_int(d, key="nvidia.com/gpu"): return int(d.get(key, "0"))

nodes = {n.metadata.name: gpu_int(n.status.allocatable)
         for n in v1.list_node().items}
used = Counter()
for p in v1.list_pod_for_all_namespaces(field_selector="status.phase=Running").items:
    req = sum(gpu_int((c.resources.limits or {})) for c in p.spec.containers)
    if req: used[p.spec.node_name] += req

free = {n: cap - used[n] for n, cap in nodes.items() if cap}
total_cap, total_free = sum(nodes.values()), sum(free.values())
largest_gang_1gpu_pods = total_free                      # spreadable work
largest_single_pod = max(free.values(), default=0)       # monolithic work
frag = 1 - (largest_single_pod / total_free) if total_free else 0.0

print(f"capacity={total_cap} free={total_free} "
      f"largest_single_pod_fits={largest_single_pod} fragmentation={frag:.2%}")
for n, f in sorted(free.items()): print(f"  {n:24s} free={f}")
```

Extend it: `--suggest` mode that identifies which pod migrations would defragment enough to fit a target job (a mini descheduler-planner). Pair with dashboards: Kueue's built-in metrics (`kueue_pending_workloads`, `kueue_admitted_active_workloads`, quota usage) + **queue-wait-time p95 per team** — the KPI scheduling teams are paid on.

## 8. Validation checklist

- [ ] Deadlock reproduced on default scheduler, then impossible under Kueue (S5) and Volcano (`minAvailable`)
- [ ] S2 reclaim: borrowed workloads visibly evicted & re-queued when the owner returns
- [ ] Priority preemption within a queue (S3) with event trail captured
- [ ] DRA: pod scheduled via ResourceClaim with a CEL attribute selector
- [ ] `gpu_frag.py` output before/after a binpack-enabled run shows fragmentation drop
- [ ] Comparison doc published

## 9. Teardown

`kind delete cluster --name sched-lab`; cloud validation nodes via Karpenter consolidation as always.

## 10. Interview ammunition

- *"Built and benchmarked a multi-tenant GPU batch-scheduling layer: reproduced gang deadlock and starvation on default kube-scheduler, then eliminated them with Kueue cohorts (borrowing + reclaim, priority preemption) and Volcano PodGroups (DRF + binpack); adopted DRA ResourceClaims with CEL device selection on K8s 1.34; shipped a fleet fragmentation analyzer that quantified packing efficiency."*
- Whiteboard-ready: why gang scheduling exists (deadlock construction); admission-time vs placement-time gangs; DRF in one minute; borrowing/reclaim semantics; device plugin → DRA migration; how fragmentation silently wastes 20–30% of a GPU fleet.

## 11. Stretch goals

1. **scheduler-plugins** deploy with the `coscheduling` profile — a third gang implementation; extend the comparison.
2. Kueue **MultiKueue**: dispatch jobs to whichever of two kind clusters has free quota (multi-cluster scheduling — P12 tie-in).
3. Simulate **spot reclaim storms** (delete 30% of fake nodes) and measure re-queue fairness per team.
4. Write the fragmentation metric as a Prometheus exporter + alert when `largest_single_pod_fits < 8`.
