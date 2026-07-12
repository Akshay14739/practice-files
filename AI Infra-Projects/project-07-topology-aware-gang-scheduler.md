# Project 07 — GPU Batch & Gang Scheduling: Operate Kueue/Volcano, Then Build Your Own Topology-Aware Scheduler Plugin

**Difficulty:** ★★★★★ | **Time:** 5–6 weekends | **Cost:** ~$0–10 (kind/kwok simulation is free; optional real-GPU validation: 2× `g4dn.xlarge` spot ≈ $0.30–0.50/hr, sessions only)
**GPU-scheduling project 1 of 2** (see [P08](project-08-fractional-gpu-dra-multitenancy.md) for fractional GPUs & multi-tenancy). **Prereqs:** P1 (GPU platform), P5 (Kueue basics, RayJobs).
**Skills proven:** kube-scheduler internals + the Scheduling Framework in Go · gang/co-scheduling · priority & preemption · hierarchical quota (cohorts/borrowing/reclaim) · Kueue vs Volcano vs YuniKorn vs coscheduling trade-offs · DRA ResourceClaims/DeviceClasses · scheduling observability · kwok scale testing.
**JD keywords hit:** "orchestration and management of AI workloads" · "multi-tenant resource allocation" · "Golang… K8s concepts, CRDs… control plane services" (Cisco *AI Control Plane Engineer*).

*Own the question every AI company fights daily: **"which job gets the GPUs, when, and why?"** This project hits both verbs the JDs want. First you **operate** the incumbents: run the same contended-cluster scenarios through **Kueue** and **Volcano** (priority, preemption, quota borrowing, gang scheduling, **DRA**) and ship a Python **fragmentation analyzer**. Then you **build** one yourself: a topology-aware gang scheduler plugin in Go on the Kubernetes Scheduling Framework, validated at 1,000-node scale. Operating a scheduler and building one are different resume verbs — you want both.*

## 1. The production problem

Vanilla kube-scheduler places pods **one at a time** and knows nothing about GPU interconnect topology. Inference scales with KEDA; **training is a batch-HPC problem wearing a Kubernetes costume**, and the default scheduler is actively wrong for it in five ways:

1. **Deadlock by partial placement.** Two 4-GPU jobs on a 6-GPU cluster each grab 3 GPUs → both wait forever. A 16-GPU PyTorch job needs all 16 pods running before `torchrun` rendezvous completes; the default scheduler can place 12, run out of GPUs, and leave 12 GPUs burning money while blocking a 4-GPU job that *could* have run. Hence **gang (all-or-nothing) scheduling** — Volcano, Kueue, YuniKorn and NVIDIA's KAI all implement it.
2. **Starvation:** a stream of small jobs perpetually delays the big pretraining run → need **priority + preemption**.
3. **Hoarding:** team A's idle quota can't help team B's queue → need **cohorts/borrowing with reclaim**.
4. **Fragmentation:** 8 nodes each with 1 free GPU = 8 free GPUs that can't run one 8-GPU job → need **bin-packing awareness + a way to measure it**.
5. **Topology-blind placement.** Two nodes in the same EC2 placement group / same InfiniBand leaf switch give NCCL all-reduce 2–5× the bus bandwidth of two nodes across spine switches. The scheduler must *prefer packing a gang into the same network domain*.

You'll create each failure on purpose, fix it with the right off-the-shelf mechanism, then build the placement-time fix yourself. That before/after is the whole portfolio piece.

## 2. What you'll build

**Part A (operate):** a kind lab where Kueue and Volcano each run a deadlock/starvation/reclaim **scenario matrix (S1–S5)**, a DRA lab, and `gpu_frag.py` — a fleet fragmentation analyzer.

**Part B (build):** your own second scheduler, scaffolded from a fork of **kubernetes-sigs/scheduler-plugins**:

```
                    ┌──────────────────────────────────────────┐
 Pods (gang labels) │        topogang-scheduler (2nd sched)     │
 ──────────────────▶│  QueueSort → PreFilter → Filter → Score   │
                    │       → Reserve → Permit(gang gate)       │
                    └───────┬──────────────────────────────────┘
                            │ Score: same network-node-layer-3 as
                            │ already-placed gang members (+ GPU
                            │ bin-packing MostAllocated)
                            ▼
   kwok cluster: 1,000 fake GPU nodes labeled with a synthetic
   3-level topology (zone / layer-2 / layer-3), 8×"GPU" each
```

Deliverables: the scenario-matrix screenshots and Kueue-vs-Volcano comparison doc, a DRA demo, the fragmentation analyzer, a Go scheduler plugin + its `KubeSchedulerConfiguration`, a kwok test harness, a benchmark report replaying S1–S5 against every scheduler (including yours), and a design doc.

## 3. Part A lab topology (free tier)

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

## 4. Phase 1 — Reproduce the pathologies (default scheduler)

**Deadlock demo:** submit `jobA` (4×1-GPU pods) and `jobB` (4×1-GPU pods) *simultaneously* onto a temporarily-shrunk 6-GPU cluster (cordon one worker). Watch each land 3 pods, then both stall `Pending` forever. Capture:

```bash
kubectl get pods -o wide | sort
kubectl get events --field-selector reason=FailedScheduling
```

**Starvation demo:** loop-submit 1-GPU/60s jobs every 20s; submit an 8-GPU job; measure its queue wait (it never runs). Save the timeline — you'll replay it under each scheduler, *including the one you build in Part B*.

## 5. Phase 2 — Kueue done properly (quotas, cohorts, borrowing, preemption)

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

**Scenario matrix to run and screenshot** (each is one `Workload` watch: `kubectl get workloads -A -w`). This matrix is also the **benchmark harness** you replay against every scheduler — including your own — in Phase 9, so script each scenario as a one-command reproduction (`bench/s1.sh` … `bench/s5.sh`) rather than clicking through it once:

| # | Scenario | Expected Kueue behavior |
|---|----------|------------------------|
| S1 | A submits 12 GPUs of jobs; B idle | A borrows 6 from cohort → all run |
| S2 | Then B submits 6 GPUs | **Reclaim**: A's borrowed (lowest-prio) workloads evicted & re-queued; B gets nominal share |
| S3 | A low-prio running; A high-prio arrives, quota full | `withinClusterQueue` preemption |
| S4 | The 8-GPU job vs stream of small jobs | With priorities set, big job admitted as a unit — starvation gone |
| S5 | Deadlock replay (from Phase 1) | **All-or-nothing admission**: second job stays `Suspended`, zero partial allocation |

Kueue admits **whole Workloads** (gang semantics at *admission*), which kills the deadlock class by construction. Say exactly that sentence in interviews.

**Topology-Aware Scheduling (TAS):** enable Kueue's `TopologyAwareScheduling` feature gate, label nodes with a fake topology (`cloud.provider.com/topology-block`, `.../topology-rack`), and show a 4-pod gang landing within one "rack" — the placement property that decides AllReduce bandwidth in real clusters (ties to [P10](project-10-fault-tolerant-training-goodput.md)'s training fabric and [P15](project-15-nvidia-networking-nccl-cluster-validation.md)'s NCCL validation).

## 6. Phase 3 — The same scenarios on Volcano

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

## 7. Phase 4 — DRA: the future of GPU allocation (GA in K8s 1.34)

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

Lab paths: (a) kind 1.34 + the **CEL-selectable example DRA driver** (dra-example-driver) to exercise the API for free; (b) real path on one `g4dn` with the **NVIDIA DRA driver** (`k8s-dra-driver-gpu`) — list `ResourceSlices`, watch claim allocation, and demo *attribute-based* selection ("give me any GPU with ≥15Gi") that device plugins simply cannot express. Close with the one-pager: device plugin vs DRA (counter vs structured claims; no attributes vs CEL selectors; no sharing model vs claims shareable between pods; MIG as pre-carved resources vs dynamically claimable partitions). DRA goes much deeper in [P08](project-08-fractional-gpu-dra-multitenancy.md).

## 8. Phase 5 — Fleet fragmentation & scheduling observability (your Python tool)

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

## 9. Phase 6 — Capstone scaffold: fork kubernetes-sigs/scheduler-plugins

Now the build verb. You've operated admission-time gangs (Kueue) and a replacement scheduler (Volcano); next you implement placement-time gang + topology scheduling yourself.

**Do NOT `go mod init topogang && go get k8s.io/kubernetes`.** The Scheduling Framework's types live inside `k8s.io/kubernetes` itself, and importing that module directly is famously painful. Kubernetes pins its staging modules (`k8s.io/api`, `k8s.io/apimachinery`, `k8s.io/client-go`, …) via `replace` directives pointing at `./staging/src/k8s.io/*` — and replace directives **only apply in the main module**. For any downstream consumer every staging module therefore resolves to an unbuildable `v0.0.0` unless you hand-copy ~30 replace lines pinning each `k8s.io/X` to the `v0.<minor>.<patch>` matching your Kubernetes version (31 staging replaces in k8s master's `go.mod` as of July 2026; the count drifts by a couple per minor as staging repos like `cri-client` and `externaljwt` come and go).

**kubernetes-sigs/scheduler-plugins exists precisely for this** — the SIG-Scheduling-owned home for out-of-tree plugins built on the framework. Its `go.mod` already requires `k8s.io/kubernetes` and ships the full replace block (~34 lines on master, pinned to k8s v1.35.4 as of July 2026; it does *not* vendor), so forking it inherits the dependency solution. Bonus: the production-ready **Coscheduling** plugin (gang scheduling via a PodGroup CRD) lives in the same repo, beside Capacity Scheduling, Node Resource Topology and Trimaran — your comparison baseline sits in-tree with your own code. Tags follow `v0.X.Y` ↔ Kubernetes `v1.X.Y`, with release branches `release-1.18` … `release-1.34` (master tracks k8s 1.35.x as of July 2026): **branch to the release matching your cluster's minor, and re-check upstream before you start — this ecosystem moves every minor.**

```bash
# fork github.com/kubernetes-sigs/scheduler-plugins to your account first
git clone https://github.com/<you>/scheduler-plugins && cd scheduler-plugins
git checkout release-1.34        # match your cluster's k8s minor
mkdir -p pkg/topogang            # your plugin lives beside pkg/coscheduling, pkg/trimaran, ...
# ... write plugin.go (Phase 7), register it in cmd/scheduler/main.go ...
make local-image                 # builds the custom kube-scheduler image (per doc/develop.md)
kind load docker-image localhost:5000/scheduler-plugins/kube-scheduler:latest --name sched-lab
```

Repo layout after your additions:

```
scheduler-plugins/                        # your fork
├── cmd/scheduler/main.go                 # + one app.WithPlugin(...) line
├── pkg/topogang/plugin.go                # the plugin (Phase 7)
├── pkg/topogang/gangstate.go
├── manifests/topogang/scheduler-config.yaml
├── manifests/topogang/deployment.yaml    # runs as a Deployment in-cluster
├── sim/kwok-up.sh  sim/make-nodes.sh  sim/gangs.py
├── bench/s1.sh … bench/s5.sh  bench/results.md
└── go.mod                                # inherited — the ~34 replace directives already solved
```

Conventions to follow from the repo: if you add configurable plugin args, name the struct `TopoGangArgs` (the `<PluginName>Args` convention) and run `hack/update-codegen.sh`; deploy via the repo's `manifests/` or Helm chart patterns.

## 10. Phase 7 — The TopoGang plugin (core Go code)

> Signatures below match the framework as consumed by scheduler-plugins' `release-1.34` branch (k8s v1.34.x). The framework API shifts slightly between minors — stay on the release branch matching your cluster and adjust.

**Design-doc caveat (write this sentence; say it in interviews):** the kube-scheduler docs are blunt — *"Exactly one queue sort plugin may be enabled at a time"* and *"All profiles must use the same plugin in the queueSort extension point … because the scheduler only has one pending pods queue"* — so replacing `PrioritySort` with the gang-name sort below re-orders **every** pending pod handled by this scheduler binary, including non-gang workloads; that's acceptable for a dedicated second scheduler that only gang jobs opt into, and it's exactly why gang schedulers ship as a second scheduler rather than a reconfigured default.

`pkg/topogang/plugin.go`:

```go
package topogang

import (
	"context"
	"fmt"
	"strconv"
	"sync"
	"time"

	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/kubernetes/pkg/scheduler/framework"
)

const (
	Name          = "TopoGang"
	GangNameLabel = "topogang.io/gang-name"
	GangSizeLabel = "topogang.io/gang-size"                 // total pods that must co-schedule
	TopoLabel     = "topology.k8s.aws/network-node-layer-3" // finest AWS layer = closest switch
	permitTimeout = 120 * time.Second
	gpuResource   = "nvidia.com/gpu"
)

type TopoGang struct {
	fh       framework.Handle
	mu       sync.Mutex
	reserved map[string]map[string]string // gang -> pod -> node
}

var (
	_ framework.QueueSortPlugin = &TopoGang{}
	_ framework.PreFilterPlugin = &TopoGang{}
	_ framework.ScorePlugin     = &TopoGang{}
	_ framework.ReservePlugin   = &TopoGang{}
	_ framework.PermitPlugin    = &TopoGang{}
)

func New(_ context.Context, _ runtime.Object, h framework.Handle) (framework.Plugin, error) {
	return &TopoGang{fh: h, reserved: map[string]map[string]string{}}, nil
}
func (t *TopoGang) Name() string { return Name }

func gangOf(p *v1.Pod) (string, int) {
	name := p.Labels[GangNameLabel]
	size, _ := strconv.Atoi(p.Labels[GangSizeLabel])
	return name, size
}

// ---- QueueSort: keep members of the same gang adjacent (by gang name, then
// creation time) so a gang drains through the queue together.
// NOTE: this replaces PrioritySort for the whole binary — see the caveat above.
func (t *TopoGang) Less(a, b *framework.QueuedPodInfo) bool {
	ga, _ := gangOf(a.Pod)
	gb, _ := gangOf(b.Pod)
	if ga != gb {
		return ga < gb
	}
	return a.Pod.CreationTimestamp.Before(&b.Pod.CreationTimestamp)
}

// ---- PreFilter: reject fast if the gang can't possibly fit (fewer free GPUs
// cluster-wide than the gang needs). Prevents partial placement.
func (t *TopoGang) PreFilter(ctx context.Context, _ *framework.CycleState, p *v1.Pod) (*framework.PreFilterResult, *framework.Status) {
	gang, size := gangOf(p)
	if gang == "" || size <= 1 {
		return nil, framework.NewStatus(framework.Success)
	}
	nodes, err := t.fh.SnapshotSharedLister().NodeInfos().List()
	if err != nil {
		return nil, framework.AsStatus(err)
	}
	free := int64(0)
	for _, n := range nodes {
		alloc := n.Allocatable.ScalarResources[v1.ResourceName(gpuResource)]
		used := n.Requested.ScalarResources[v1.ResourceName(gpuResource)]
		free += alloc - used
	}
	need := podGPUs(p) * int64(size)
	if free < need {
		return nil, framework.NewStatus(framework.Unschedulable,
			fmt.Sprintf("gang %s needs %d GPUs, only %d free", gang, need, free))
	}
	return nil, framework.NewStatus(framework.Success)
}
func (t *TopoGang) PreFilterExtensions() framework.PreFilterExtensions { return nil }

func podGPUs(p *v1.Pod) int64 {
	var g int64
	for _, c := range p.Spec.Containers {
		if q, ok := c.Resources.Requests[v1.ResourceName(gpuResource)]; ok {
			g += q.Value()
		}
	}
	if g == 0 {
		g = 1
	}
	return g
}

// ---- Score: (a) prefer nodes in the same topology domain as gang members
// already reserved; (b) bin-pack GPUs (MostAllocated) to keep whole nodes free
// for future gangs.
func (t *TopoGang) Score(ctx context.Context, _ *framework.CycleState, p *v1.Pod, nodeName string) (int64, *framework.Status) {
	ni, err := t.fh.SnapshotSharedLister().NodeInfos().Get(nodeName)
	if err != nil {
		return 0, framework.AsStatus(err)
	}
	node := ni.Node()
	score := int64(0)

	// (a) topology affinity with already-reserved gang members: up to 60 pts
	gang, _ := gangOf(p)
	if gang != "" {
		t.mu.Lock()
		domains := map[string]bool{}
		for _, nName := range t.reserved[gang] {
			if other, err := t.fh.SnapshotSharedLister().NodeInfos().Get(nName); err == nil {
				domains[other.Node().Labels[TopoLabel]] = true
			}
		}
		t.mu.Unlock()
		if len(domains) == 0 || domains[node.Labels[TopoLabel]] {
			score += 60
		}
	}
	// (b) GPU bin-packing: up to 40 pts for fuller nodes
	alloc := ni.Allocatable.ScalarResources[v1.ResourceName(gpuResource)]
	used := ni.Requested.ScalarResources[v1.ResourceName(gpuResource)]
	if alloc > 0 {
		score += (used + podGPUs(p)) * 40 / alloc
	}
	return score, framework.NewStatus(framework.Success)
}
func (t *TopoGang) ScoreExtensions() framework.ScoreExtensions { return nil }

// ---- Reserve/Unreserve: track where gang members landed (feeds Score).
func (t *TopoGang) Reserve(ctx context.Context, _ *framework.CycleState, p *v1.Pod, nodeName string) *framework.Status {
	gang, _ := gangOf(p)
	if gang != "" {
		t.mu.Lock()
		if t.reserved[gang] == nil {
			t.reserved[gang] = map[string]string{}
		}
		t.reserved[gang][p.Name] = nodeName
		t.mu.Unlock()
	}
	return framework.NewStatus(framework.Success)
}
func (t *TopoGang) Unreserve(ctx context.Context, _ *framework.CycleState, p *v1.Pod, _ string) {
	gang, _ := gangOf(p)
	t.mu.Lock()
	delete(t.reserved[gang], p.Name)
	t.mu.Unlock()
}

// ---- Permit: the gang gate. Hold every member in "Waiting" until the whole
// gang is reserved, then release all at once. Timeout ⇒ reject all (their
// Unreserve fires, freeing resources — no deadlock).
func (t *TopoGang) Permit(ctx context.Context, _ *framework.CycleState, p *v1.Pod, _ string) (*framework.Status, time.Duration) {
	gang, size := gangOf(p)
	if gang == "" || size <= 1 {
		return framework.NewStatus(framework.Success), 0
	}
	t.mu.Lock()
	ready := len(t.reserved[gang]) >= size
	t.mu.Unlock()
	if !ready {
		return framework.NewStatus(framework.Wait), permitTimeout
	}
	// last member arrived: release all waiting siblings
	t.fh.IterateOverWaitingPods(func(wp framework.WaitingPod) {
		if wp.GetPod().Labels[GangNameLabel] == gang {
			wp.Allow(Name)
		}
	})
	return framework.NewStatus(framework.Success), 0
}
```

`cmd/scheduler/main.go` — in the fork you **edit** the existing file, adding one registration to the list that already carries Coscheduling and friends:

```go
import (
	// ...existing imports...
	"sigs.k8s.io/scheduler-plugins/pkg/topogang"
)

command := app.NewSchedulerCommand(
	// ...existing app.WithPlugin(coscheduling.Name, coscheduling.New), etc...
	app.WithPlugin(topogang.Name, topogang.New),
)
```

`manifests/topogang/scheduler-config.yaml`:

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: false
profiles:
- schedulerName: topogang-scheduler
  plugins:
    multiPoint:
      enabled:
      - name: TopoGang
      disabled:
      - name: PrioritySort   # only one QueueSort may be active — yours replaces it
```

Build with `make local-image` and deploy as a **second scheduler** (Deployment in kube-system with RBAC cloned from the system scheduler's ClusterRole — the repo's `manifests/` and Helm chart show the pattern; workloads opt in via `spec.schedulerName: topogang-scheduler`).

## 11. Phase 8 — 1,000-node simulation with kwok ($0)

kwok (Kubernetes WithOut Kubelet — v0.8.0 as of June 2026, actively maintained, SIG-Scheduling-sponsored) is the de facto standard for fake-node scale testing: ~1,000 nodes / 100k pods on a laptop. Complements worth knowing by name: **kube-scheduler-simulator** (itself kwok-powered, for debugging per-plugin scoring decisions) and in-tree **scheduler_perf** (`test/integration/scheduler_perf`, the official kube-scheduler benchmark harness). For "many fake nodes, real custom scheduler binary," kwok is the tool.

```bash
# reuse the sched-lab kind cluster; add the kwok controller (fake kubelets)
KWOK_VER=$(curl -s https://api.github.com/repos/kubernetes-sigs/kwok/releases/latest | jq -r .tag_name)
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VER}/kwok.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VER}/stage-fast.yaml"
```

`sim/make-nodes.sh` — 1,000 fake 8-GPU nodes across a synthetic 3-level topology (25 layer-3 "bricks" × 5 layer-2 "spines"):

```bash
for i in $(seq 0 999); do
  L3=$((i % 25)); L2=$((L3 % 5))
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Node
metadata:
  name: gpu-node-$i
  labels:
    type: kwok
    nvidia.com/gpu.product: H100
    topology.kubernetes.io/zone: az-$L2
    topology.k8s.aws/network-node-layer-2: nn-l2-$L2
    topology.k8s.aws/network-node-layer-3: nn-l3-$L3
  annotations: {kwok.x-k8s.io/node: fake}
spec:
  taints: [{key: kwok.x-k8s.io/node, value: fake, effect: NoSchedule}]
status:
  allocatable: {cpu: "96", memory: 1000Gi, nvidia.com/gpu: "8", pods: "110"}
  capacity:    {cpu: "96", memory: 1000Gi, nvidia.com/gpu: "8", pods: "110"}
EOF
done
```

`sim/gangs.py` submits mixed workloads (gangs of 2/4/8/16 nodes + single-GPU inference pods, all tolerating the kwok taint, `schedulerName: topogang-scheduler`) and measures:

- **gang time-to-full-placement** (last pod scheduled − first pod created)
- **topology purity**: % of gangs whose pods share one layer-3 value
- **deadlocks**: gangs stuck > permit timeout
- **fragmentation**: free GPUs stranded on partially-used nodes (run `gpu_frag.py` from Phase 5 against the kwok fleet)

## 12. Phase 9 — Benchmark harness: replay the scenario matrix against everyone

This is where Parts A and B fuse. Replay the **S1–S5 matrix** (deadlock, starvation, reclaim, preemption) *plus* the kwok gang-metric workload against: (a) `default-scheduler`, (b) **Volcano** (`gang` + `binpack`), (c) **Kueue** (queueing above the scheduler, not placement), (d) sig-scheduling's **coscheduling** plugin — already in your fork; its PodGroup CRD is still `scheduling.x-k8s.io/v1alpha1` (alpha: `minMember`/`minResources`/`scheduleTimeoutSeconds`, pods join via the `scheduling.x-k8s.io/pod-group` label, status reconciled by a **separate controller image**; no beta graduation as of July 2026), and (e) **TopoGang** (yours). Write up when you'd choose each — this comparison table is interview gold:

| | Gang | Topology-aware placement | Quota/fair-share | Where it acts |
|---|---|---|---|---|
| default | ✗ | ✗ (spread-ish) | ✗ | placement |
| TopoGang (yours) | ✓ Permit gate | ✓ Score | ✗ | placement |
| coscheduling (sig) | ✓ Permit + PodGroup CRD (v1alpha1) | ✗ | ✗ (ElasticQuota is separate) | placement |
| Volcano | ✓ | partial (binpack, task-topology) | ✓ queues | own scheduler |
| Kueue | ✓ (via admission) | ✓ TAS (1.9+) | ✓ ClusterQueues | admission, delegates placement |
| KAI (NVIDIA) | ✓ | ✓ | ✓ + fractions | own scheduler (see [P08](project-08-fractional-gpu-dra-multitenancy.md)) |

For each scheduler record: deadlock outcome (S5), 8-GPU-job queue wait under the small-job stream (S4), reclaim behavior (S2 — expect "n/a" for placement-only schedulers, and *say why*), time-to-full-placement, and topology purity. Publish `bench/results.md` with your measured numbers.

## 13. Chaos & correctness drills

1. Submit a 16-node gang into a cluster with 15 free nodes → verify **zero** pods bind (PreFilter/Permit), and a later 8-node gang schedules immediately (no head-of-line deadlock).
2. Kill the scheduler pod mid-gang → confirm waiting pods time out, Unreserve fires, resources free.
3. Two gangs racing for the last layer-3 brick → verify one packs cleanly, the other lands in the next-best domain (Score degrades gracefully, never blocks).

## 14. What "done" looks like + interview ammo

- [ ] Deadlock reproduced on default scheduler, then impossible under Kueue (S5), Volcano (`minAvailable`), and TopoGang (Permit gate)
- [ ] S2 reclaim: borrowed workloads visibly evicted & re-queued when the owner returns
- [ ] Priority preemption within a queue (S3) with event trail captured
- [ ] DRA: pod scheduled via ResourceClaim with a CEL attribute selector
- [ ] `gpu_frag.py` output before/after a binpack-enabled run shows fragmentation drop
- [ ] Kueue-vs-Volcano comparison doc published
- [ ] TopoGang built from your scheduler-plugins fork (`make local-image`), deployed as a second scheduler; gangs of 16 place atomically at 1,000-node kwok scale (record your measured time-to-full-placement)
- [ ] Topology purity for TopoGang vs default scheduler on the same workload (record both measured numbers)
- [ ] `bench/results.md`: S1–S5 + gang metrics across all five schedulers, with the comparison table above

**Resume bullet:** *"Owned GPU batch scheduling end-to-end: reproduced gang deadlock, starvation, and quota-hoarding on default kube-scheduler, eliminated them operating Kueue cohorts (borrowing + reclaim, priority preemption) and Volcano PodGroups (DRF + binpack), adopted DRA ResourceClaims with CEL device selection (K8s 1.34); then built a Kubernetes scheduler plugin in Go on the kubernetes-sigs/scheduler-plugins framework (QueueSort/PreFilter/Score/Reserve/Permit) implementing gang + network-topology-aware GPU placement — benchmarked against Volcano, Kueue and sig-scheduling's coscheduling on the same scenario matrix at 1,000-node kwok scale (atomic 128-GPU gang placement, measured same-leaf topology purity, zero partial-placement deadlocks) — and shipped a fleet fragmentation analyzer that quantified packing efficiency."*

**Deep-dive questions you can now answer:** Why Permit instead of a webhook? (Waiting pods hold reservations in the scheduler cache — atomic release, clean timeout semantics.) Why does gang scheduling prevent deadlock? (All-or-nothing = no circular hold-and-wait.) Admission-time vs placement-time gangs? (Kueue suspends whole Workloads before the scheduler sees them; Volcano/coscheduling/TopoGang gate binding.) Why must a gang scheduler be a *second* scheduler? (One QueueSort per binary, one shared pending queue — the Phase 7 caveat.) How does AWS expose topology? (`topology.k8s.aws/network-node-layer-{1..3}` labels from the EC2 instance-topology API; layer-3 is the nearest network node.) Plus: DRF in one minute; borrowing/reclaim semantics; device plugin → DRA migration; how fragmentation silently wastes 20–30 % of a GPU fleet.

## 15. Teardown

`kind delete cluster --name sched-lab`; cloud validation nodes via Karpenter consolidation as always. If you ran the optional real-GPU validation (2× `g5.12xlarge` for ~2 hours ≈ $10 proves the AWS topology labels and full flow end-to-end): `eksctl delete cluster` when done.

## 16. Extensions

1. Preemption: implement `PostFilter` to evict a lower-priority gang *as a unit*.
2. CRD-ify the gang (a `PodGroup` CRD + controller) instead of labels — reuse your P6 Kubebuilder skills. Study the coscheduling plugin's `scheduling.x-k8s.io/v1alpha1` PodGroup (minMember/minResources/scheduleTimeoutSeconds; status phases Pending/Scheduling/Running/Finished/Failed, reconciled by a separate controller binary) before designing yours — it's still alpha as of July 2026, so there's real design space here.
3. Kueue **MultiKueue**: dispatch jobs to whichever of two kind clusters has free quota (multi-cluster scheduling — [P12](project-12-ai-fleet-sre-finops-aiops.md) tie-in).
4. Simulate **spot reclaim storms** (delete 30 % of fake nodes) and measure re-queue fairness per team.
5. Write the fragmentation metric as a Prometheus exporter + alert when `largest_single_pod_fits < 8`.
6. Real-GPU validation: 2× `g5.12xlarge` for 2 hours (~$10) proves the AWS topology labels and the full flow end-to-end.

## 📣 Build in public

- **LinkedIn post:** the before/after screenshot pair — two 4-GPU jobs deadlocked forever on default kube-scheduler (`FailedScheduling` events, 6 GPUs held hostage) next to the same jobs under Kueue admission and under your Permit gate — with your measured S4 queue-wait for the starved 8-GPU job under each of the five schedulers from `bench/results.md`.
- **X/Twitter thread:** "I tried to `go get k8s.io/kubernetes` and hit the 31-replace-directive wall" — thread the staging-module mechanics, the kubernetes-sigs/scheduler-plugins fork that fixes it, and end with the money shot: your `make local-image` scheduler placing a 16-pod gang atomically at 1,000-node kwok scale, with the measured time-to-full-placement.
- **YouTube demo:** live split-screen at 1,000 kwok nodes — default scheduler vs TopoGang on the same 128-GPU gang workload, watching your measured topology-purity and fragmentation counters from `gpu_frag.py` tick in real time; finish by killing the scheduler pod mid-gang to show the Permit timeout + Unreserve freeing every reserved GPU.
