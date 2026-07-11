# Project 07 — TopoGang: A Topology-Aware Gang Scheduler for GPU Workloads (Go)

**Difficulty:** ★★★★☆ | **Time:** 3–4 weekends | **Cost:** ~$0–5 (kwok simulation; optional $10–20 real-GPU validation)
**GPU-scheduling project 1 of 2.**

## 1. The production problem

Vanilla kube-scheduler places pods **one at a time** and knows nothing about GPU interconnect topology. For distributed training this is fatal in two ways:

1. **Deadlock by partial placement.** A 16-GPU PyTorch job needs all 16 pods running before `torchrun` rendezvous completes. Default scheduling can place 12 pods, run out of GPUs, and leave 12 GPUs burning money while blocking a 4-GPU job that *could* have run. This is why every serious ML platform has **gang (all-or-nothing) scheduling** — Volcano, Kueue, YuniKorn, and NVIDIA's KAI all implement it.
2. **Topology-blind placement.** Two nodes in the same EC2 placement group / same InfiniBand leaf switch give NCCL all-reduce 2–5× the bus bandwidth of two nodes across spine switches. The scheduler must *prefer packing a gang into the same network domain*.

Frontier labs solve this with custom schedulers or heavy scheduler extensions. In this project you build one yourself using the **Kubernetes Scheduling Framework** — the exact skill the Cisco "AI Control Plane Engineer" JD asks for ("Golang… K8s concepts, CRDs… control plane services").

## 2. What you'll build

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

Deliverables: a Go module building a scheduler binary, its `KubeSchedulerConfiguration`, a kwok test harness, a benchmark report vs. default scheduler and vs. Volcano/Kueue, and a design doc.

## 3. Repo layout

```
topogang/
├── cmd/scheduler/main.go
├── pkg/topogang/plugin.go
├── pkg/topogang/gangstate.go
├── deploy/scheduler-config.yaml
├── deploy/deployment.yaml            # runs as a Deployment in-cluster
├── sim/kwok-up.sh  sim/make-nodes.sh  sim/gangs.py
├── bench/results.md
└── Dockerfile  go.mod
```

## 4. Phase 1 — the plugin (core Go code)

> Signatures below match `k8s.io/kubernetes` **v1.31.x** (the framework API shifts slightly between minors — pin your go.mod to the same minor as your cluster and adjust).

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
	GangSizeLabel = "topogang.io/gang-size" // total pods that must co-schedule
	TopoLabel     = "topology.k8s.aws/network-node-layer-3" // finest AWS layer = closest switch
	permitTimeout = 120 * time.Second
	gpuResource   = "nvidia.com/gpu"
)

type TopoGang struct {
	fh framework.Handle
	mu sync.Mutex
	// gang -> set of nodeNames already reserved, and count reserved
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

// ---- QueueSort: keep members of the same gang adjacent (by gang name,
// then creation time) so a gang drains through the queue together.
func (t *TopoGang) Less(a, b *framework.QueuedPodInfo) bool {
	ga, _ := gangOf(a.Pod)
	gb, _ := gangOf(b.Pod)
	if ga != gb {
		return ga < gb
	}
	return a.Pod.CreationTimestamp.Before(&b.Pod.CreationTimestamp)
}

// ---- PreFilter: reject fast if the gang can't possibly fit (fewer free
// GPUs cluster-wide than the gang needs). Prevents partial placement.
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
// already reserved; (b) bin-pack GPUs (MostAllocated) to keep whole nodes
// free for future gangs.
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

// ---- Permit: the gang gate. Hold every member in "Waiting" until the
// whole gang is reserved, then release all at once. Timeout ⇒ reject all
// (their Unreserve fires, freeing resources — no deadlock).
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

`cmd/scheduler/main.go`:

```go
package main

import (
	"os"

	"k8s.io/component-base/cli"
	"k8s.io/kubernetes/cmd/kube-scheduler/app"
	"topogang/pkg/topogang"
)

func main() {
	cmd := app.NewSchedulerCommand(app.WithPlugin(topogang.Name, topogang.New))
	os.Exit(cli.Run(cmd))
}
```

`deploy/scheduler-config.yaml`:

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
```

Build & deploy as a **second scheduler** (Deployment in kube-system with RBAC cloned from the system scheduler's ClusterRole; workloads opt in via `spec.schedulerName: topogang-scheduler`). Dockerfile: `FROM golang:1.23 AS build … FROM gcr.io/distroless/static`.

## 5. Phase 2 — 1,000-node simulation with kwok ($0)

```bash
# kind + kwok controller (fake kubelets — nodes/pods are simulated)
kind create cluster --name sched-lab
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
- **deadlocks**: gangs stuck >permit timeout
- **fragmentation**: free GPUs stranded on partially-used nodes

## 6. Phase 3 — benchmark vs. the incumbents

Repeat the same workload against: (a) `default-scheduler`, (b) **Volcano** (`gang` plugin + `binpack`), (c) **Kueue** (queueing above the scheduler, not placement), (d) sig-scheduling's **coscheduling** plugin. Write up when you'd choose each — this comparison table is interview gold:

| | Gang | Topology-aware placement | Quota/fair-share | Where it acts |
|---|---|---|---|---|
| default | ✗ | ✗ (spread-ish) | ✗ | placement |
| TopoGang (yours) | ✓ Permit gate | ✓ Score | ✗ | placement |
| Volcano | ✓ | partial (binpack, task-topology) | ✓ queues | own scheduler |
| Kueue | ✓ (via admission) | ✓ TAS (1.9+) | ✓ ClusterQueues | admission, delegates placement |
| KAI (NVIDIA) | ✓ | ✓ | ✓ + fractions | own scheduler (see P08) |

## 7. Chaos & correctness drills

1. Submit a 16-node gang into a cluster with 15 free nodes → verify **zero** pods bind (PreFilter/Permit), and a later 8-node gang schedules immediately (no head-of-line deadlock).
2. Kill the scheduler pod mid-gang → confirm waiting pods time out, Unreserve fires, resources free.
3. Two gangs racing for the last layer-3 brick → verify one packs cleanly, the other lands in the next-best domain (Score degrades gracefully, never blocks).

## 8. What "done" looks like + interview ammo

- [ ] Scheduler binary + config deployed; gangs of 16 place atomically in <2 s at 1,000-node scale.
- [ ] ≥95 % topology purity vs. ~20 % for default scheduler on the same workload (record your numbers).
- [ ] Benchmark report with the comparison table above.

**Resume bullet:** *"Built a Kubernetes scheduler plugin in Go (Scheduling Framework: QueueSort/PreFilter/Score/Reserve/Permit) implementing gang scheduling and network-topology-aware GPU placement; validated at 1,000-node scale with kwok, achieving atomic placement of 128-GPU gangs with 95 %+ same-leaf topology purity and zero partial-placement deadlocks."*

**Deep-dive questions you can now answer:** Why Permit instead of a webhook? (Waiting pods hold reservations in the scheduler cache — atomic release, clean timeout semantics.) Why does gang scheduling prevent deadlock? (All-or-nothing admission = no circular hold-and-wait.) How does AWS expose topology? (`topology.k8s.aws/network-node-layer-{1..3}` node labels from the EC2 instance-topology API; layer-3 is the last/nearest network node.)

## 9. Extensions

- Preemption: implement `PostFilter` to evict a lower-priority gang *as a unit*.
- CRD-ify the gang (a `PodGroup` CRD + controller) instead of labels — reuse your Project-06 Kubebuilder skills.
- Real-GPU validation: 2×g5.12xlarge for 2 hours (~$10) proves the labels/flow end-to-end. `eksctl delete cluster` when done.
