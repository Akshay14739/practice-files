# Scheduling, Climbed the Ladder 🪜
### Section 2 of the CKA — deriving how pods land on nodes, and how you steer that

> The CKA "Scheduling" section on the Learning Ladder. Every feature here — taints, affinity, resources, DaemonSets, static pods, priority, profiles, admission — is *one lever on one machine*: the scheduler. We climb from **the pain of uncontrolled placement** → **the one matchmaker idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How the scheduler decides which node runs each pod, and every mechanism you use to influence or override that decision.

**Why did it land on my desk?** *Workloads & Scheduling* is 15% of the CKA, and "why is this pod **Pending**?" is one of the most common troubleshooting tasks (part of the 30% Troubleshooting domain). Placement bugs are everywhere.

**What do I already know?** Probably that "pods run on nodes" and maybe `nodeSelector`. What's fuzzy: *why* there are five different placement mechanisms, when to use which, and what actually makes a pod stick to (or bounce off) a node.

---

# RUNG 1 — The Pain 🔥
### *Why does controllable scheduling exist at all?*

Imagine the scheduler just dropped every pod on a random node with room. Real clusters break immediately:

```
UNCONTROLLED PLACEMENT (the pain)

  GPU training pod ───▶ lands on a cheap CPU-only node ───▶ crashes / runs 100x slow
  noisy batch job  ───▶ lands next to your prod API   ───▶ eats all RAM, API OOMs
  licensed workload ──▶ lands on any node             ───▶ license violation
  critical pod     ───▶ node is full of low-value pods ──▶ can't schedule, stays Pending
  log/monitoring agent ─▶ you must remember to run one on EVERY node, by hand
```

**What people did before / without these levers:** hard-wire pods to hosts by hand, or just hope. That doesn't survive node failures, autoscaling, or mixed hardware.

**What breaks without control:** hardware guarantees (GPU/SSD workloads), isolation (noisy neighbors), dedicated capacity (a node reserved for one team), critical-workload priority (important pods lose the race for space), and cluster-wide agents (one-per-node daemons).

**Who feels it most?** The **platform team** carving a shared cluster into safe, predictable slices for many teams and workload types.

> **✅ Check yourself before Rung 2:** Give two concrete failures that happen if the scheduler ignores *what kind* of node a pod needs. (Hint: think special hardware, and think noisy neighbors.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this — every feature in the section derives from it:

> **The scheduler is a matchmaker: for every pod with an empty `nodeName` it FILTERS out nodes that can't run it, SCORES the survivors, and BINDS the pod to the best one — and every scheduling feature is just a lever that biases that filter or score (or bypasses the matchmaker entirely).**

Watch the whole section fall out of it:

- *"filters out nodes that can't run it"* → **taints** (node says "keep out"), **nodeAffinity/nodeSelector** (pod says "only nodes like this"), **resource requests** (pod says "I need this much free") all remove candidate nodes.
- *"scores the survivors"* → **preferred** affinity, image locality — soft preferences that rank, not exclude.
- *"binds to the best one"* → the pod's `nodeName` gets set; that's literally all "scheduling" is.
- *"bypasses the matchmaker"* → **static pods** (kubelet runs them directly), **manual `nodeName`**, **DaemonSets** (one per node by design) skip normal scheduling.
- *"for every pod in the queue"* → **PriorityClass** decides *queue order* and can **preempt** (evict) lower-priority pods to make room.
- And **admission controllers** act *before* scheduling even starts — they can reject/mutate the pod on the way in.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it. Then: a taint and a nodeAffinity rule both keep a pod off the "wrong" node — but which one is a *node repelling pods* and which is a *pod requiring a node*? Why do you often need **both**?

---

# RUNG 3 — The Machinery ⚙️
### *How placement ACTUALLY works — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of a hotel front desk assigning guests (your apps, called "pods") to rooms (the computers, called "nodes"). The desk clerk is the **scheduler**.
>
> **(A) How assigning works.** Every guest card has a blank "room number" line. The clerk watches for blank cards and does four things in order: take guests from the **waiting line**, **cross off** rooms that won't work at all, **rank** the rooms that remain, and finally **write the room number** on the card. That last pen-stroke is literally all "scheduling" is — someone else (the room's own staff) actually moves the guest in. If *every* room gets crossed off, the guest waits in the lobby indefinitely ("Pending"). If the clerk is off sick, everyone waits with no explanation. You can also skip the clerk by writing a room number on the card yourself before handing it in — but once a guest is settled, you can't move them; you check them out and check them in fresh.
>
> **(B) Three ways rooms get crossed off:**
> - **"Staff only" signs (taints):** a *room* can post a keep-out sign; only guests carrying a matching pass (a "toleration") may enter. Signs come in strengths: block newcomers, merely discourage them, or even evict guests already inside. Note: a sign only keeps others *out* — it doesn't pull your guest *in*.
> - **Guest requirements (nodeSelector / nodeAffinity):** a *guest* can demand "only rooms with a sea view." You must first put the "sea view" sticker on the room (a label). Demands can be hard ("no such room? I'll wait forever") or soft ("nice to have, but I'll take anything"). Either way, once the guest is inside, a later sticker change doesn't kick them out.
> - **Fitting (resource requests):** each guest declares the minimum space they need; the clerk only considers rooms with that much free. Guests also declare a maximum (a "limit"): overuse of shared time (CPU) just slows the guest down, but overuse of space (memory) gets them thrown out abruptly. The hotel can also set per-floor default and total space rules (LimitRange and ResourceQuota).
> - The classic combo: a sign keeps strangers out of your room, AND a requirement keeps your guest in it — you need **both** to truly reserve a room for one guest.
>
> **(C) Guests who skip the front desk:** some staff must be in *every* room — cleaners, smoke detectors — placed automatically one-per-room (a **DaemonSet**). And a few live-in maintenance staff are hired directly by each room's caretaker from a folder of instructions on-site, with no front desk involved at all (**static pods** — this is actually how the hotel's own management offices get started).
>
> **(D) The line and the door:** VIP status (**PriorityClass**) moves a guest up the waiting line and can even bump a lesser guest out of a full room (**preemption**). The hotel can employ several clerks with different rulebooks (multiple schedulers/profiles). And before any of this, a **doorman (admission controllers)** inspects each request at the entrance — he can adjust it or turn it away before it's even recorded.

*Now the original technical deep-dive — the same ideas, in precise form:*

## (A) The core loop — what "scheduling" physically is

Every pod has `spec.nodeName`, normally empty. The scheduler watches for empty-`nodeName` pods and runs four phases, then writes the name:

```
   NEW POD (nodeName: <empty>)
        │
        ▼
 ┌─────────────┐   ┌───────────┐   ┌──────────┐   ┌──────────┐
 │  Scheduling │──▶│ Filtering │──▶│ Scoring  │──▶│ Binding  │
 │    Queue    │   │ (feasible?)│   │ (best?)  │   │ set node │
 │ PrioritySort│   │ NodeResourcesFit│ NodeResourcesFit│ DefaultBinder│
 └─────────────┘   │ TaintToleration │ ImageLocality│ └──────────┘
   ordered by      │ NodeAffinity    │              │
   PriorityClass   │ NodeName        │              ▼
                   └───────────┘   └──────────┘  kubelet runs it
```

If **no node survives filtering**, the pod stays **Pending** forever. If **no scheduler is running**, every pod stays Pending with `Node: <none>` and no events. That single fact drives most "Pending pod" triage.

**Manual scheduling (no scheduler):** set `spec.nodeName: node01` at creation (bypasses the matchmaker), or POST a **Binding object** to an existing pod's binding API (exactly what the scheduler does internally). You **cannot move a running pod** — delete + recreate to "reschedule."

## (B) The filter levers — three ways to shrink the candidate set

**1. Taints & Tolerations — the *node* repels pods.** A taint on a node says "keep out unless you tolerate me"; a toleration on a pod says "I can withstand that."

```
 node01 [taint: app=blue:NoSchedule]
    ▲ podA (no toleration)      → repelled → scheduled elsewhere
    └ podD (tolerates app=blue) → allowed through the filter
```

| Effect | Meaning |
|---|---|
| `NoSchedule` | new intolerant pods won't schedule here |
| `PreferNoSchedule` | scheduler *tries* to avoid (soft) |
| `NoExecute` | intolerant new pods repelled **AND existing** ones **evicted** |

```bash
kubectl taint nodes node01 app=blue:NoSchedule       # add
kubectl taint nodes node01 app=blue:NoSchedule-      # remove (trailing minus)
```
```yaml
spec:
  tolerations:
  - key: "app"
    operator: "Equal"      # or "Exists" (then omit value)
    value: "blue"
    effect: "NoSchedule"
```
> 🎯 The **control-plane node is tainted** `node-role.kubernetes.io/control-plane:NoSchedule` — that's why your pods never land there (`kubectl describe node controlplane | grep -i taint`). **Taints only repel; they don't attract** — a tolerating pod can still go to any *other* untainted node.

**2. nodeSelector / nodeAffinity — the *pod* requires a node.** You must **label the node first** (`kubectl label nodes node01 size=large`).

```yaml
# simple:
spec:
  nodeSelector: { size: large }
# advanced (operators nodeSelector can't do: In/NotIn/Exists/DoesNotExist/Gt/Lt):
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: size, operator: In, values: [large, medium] }
```
Read the long type name **literally**:

| Type | No matching node at scheduling | Label changes after it's running |
|---|---|---|
| `requiredDuringScheduling…IgnoredDuringExecution` | pod stays **Pending** (hard) | keeps running (ignored) |
| `preferredDuringScheduling…IgnoredDuringExecution` | placed **anywhere** (soft) | keeps running (ignored) |

**3. Resource requests — the pod must *fit*.** The scheduler uses `requests` (not `limits`) to find a node with that much free.

```yaml
spec:
  containers:
  - name: app
    image: nginx
    resources:
      requests: { memory: "256Mi", cpu: "250m" }   # for SCHEDULING (must fit)
      limits:   { memory: "512Mi", cpu: "500m" }   # runtime CEILING
```
- **CPU over limit → throttled** (never killed). **Memory over limit → OOMKilled** (memory can't be throttled).
- Units: CPU `1` = 1 core, `100m` = 0.1 core. Memory `Mi/Gi` = 1024-based, `M/G` = 1000-based (`256Mi ≠ 256M`).
- **LimitRange** = per-namespace default/min/max for pods that don't specify (affects **new** pods only). **ResourceQuota** = per-namespace *total* cap.

> 🎯 **Taints + affinity, the classic combo:** taints keep *other* pods **off** your node; affinity keeps *your* pod **on** it. Neither alone fully dedicates a node — **use both** for "only these pods here, and these pods only here."

## (C) The bypass levers — pods that skip the matchmaker

- **DaemonSet** — one pod on **every** node, auto-added/removed as nodes join/leave (kube-proxy, CNI, log/monitoring agents). Uses node affinity internally but the scheduler otherwise ignores it. **No `kubectl create daemonset`** — make a Deployment YAML, flip `kind: DaemonSet`, drop `replicas` + `strategy`.
- **Static pod** — the **kubelet runs it with no API server/scheduler at all**, reading YAML from `/etc/kubernetes/manifests/` (path from `staticPodPath` in `/var/lib/kubelet/config.yaml`). This is **how the control plane bootstraps** (apiserver/etcd/scheduler are static pods). The API server shows a **read-only mirror** with the **node name appended** (`nginx-node01`); you delete it by **removing the file**, not via kubectl. Only *Pods* — no RS/Deployment/Service.

```
kubelet ──watches──▶ /etc/kubernetes/manifests/ ──creates──▶ static pods
   add file → created · edit → recreated · delete file → deleted · crash → restarted
```

## (D) The queue & the gate — priority and admission

- **PriorityClass** (non-namespaced): higher `value` = scheduled sooner, and by default **preempts** (evicts) lower-priority pods to fit. `preemptionPolicy: Never` waits in queue but still jumps ahead. No priority = value `0`; `globalDefault: true` sets a cluster default (one only).
- **Multiple schedulers / profiles:** run a custom scheduler (pod sets `schedulerName`), or since v1.18 run **multiple profiles in one binary** (each with its own `schedulerName`, enabling/disabling plugins) — avoids the race conditions of separate processes.
- **Admission controllers** run *after* authn/authz but *before* the object is persisted — they **mutate** then **validate**, and can reject the request (no `latest` tag, no root, auto-add default StorageClass). Configured on the API server (`--enable-admission-plugins`).

```
Request → [Authentication] → [Authorization/RBAC] → [Admission: mutate → validate] → etcd → (scheduler)
```

> **✅ Check yourself before Rung 4:** A pod is **Pending**. Walk the filter phase: name the *three* different reasons a node could get filtered out (one about the node, one about the pod's node requirement, one about capacity). And: which field does the scheduler read to check capacity — `requests` or `limits`?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to the matchmaker machinery*

| Term | What it actually is | Which lever / phase |
|---|---|---|
| **nodeName** | The field the scheduler sets | The output of Binding |
| **Taint** | A "keep out" mark on a **node** | Filter (repel) |
| **Toleration** | A pod's permission to ignore a taint | Filter (pass the repel) |
| **NoSchedule / PreferNoSchedule / NoExecute** | Taint strengths (block / soft / block+evict) | Filter |
| **nodeSelector** | Simple "pod requires node label" | Filter (attract) |
| **nodeAffinity** | Expressive version (operators, soft/hard) | Filter + Score |
| **required… / preferred…** | Hard rule (Pending if unmet) / soft preference | Filter / Score |
| **requests** | Minimum guaranteed; used to place | Filter (fit) |
| **limits** | Runtime ceiling (CPU throttle / mem OOMKill) | not scheduling |
| **LimitRange / ResourceQuota** | Per-ns defaults / per-ns total cap | admission-time |
| **DaemonSet** | One pod per node, cluster-wide | Bypass (per-node) |
| **Static pod** | Pod the kubelet runs directly from a dir | Bypass (bootstraps control plane) |
| **PriorityClass** | Ranks pods; enables preemption | Queue order |
| **preemption** | Evicting lower-priority pods to fit a higher one | Queue/Filter |
| **schedulerName / profile** | Which scheduler (or profile) handles a pod | Whole loop |
| **Admission controller** | Validate/mutate/reject a request | Before scheduling |

### The big unlock: group the levers by what they do

```
REPEL (node pushes pods away):      Taints + Tolerations
ATTRACT/REQUIRE (pod pulls to node): nodeSelector + nodeAffinity
FIT (capacity):                      requests (+ LimitRange/ResourceQuota)
BYPASS (skip the scheduler):         static pods · manual nodeName · DaemonSets
QUEUE (who goes first, who gets evicted): PriorityClass + preemption
GATE (before scheduling at all):     Admission controllers
```

Six groups, one machine. Note **taint↔toleration** and **label↔nodeSelector/affinity** are each two-sided pairs (one on the node, one on the pod).

> **✅ Check yourself before Rung 5:** Sort these into "repel / attract / fit / bypass": a `NoSchedule` taint, a `requiredDuringScheduling` nodeAffinity, a `memory: 256Mi` request, a static pod. Which two must be used *together* to truly dedicate a node?

---

# RUNG 5 — The Trace 🎬
### *Follow ONE pod through the scheduler, lever by lever*

Trace a **GPU training pod** onto a **dedicated GPU node**, in a cluster that also has a high-priority preemption rule. This one path touches every lever.

**Step 1 — Pod is created, hits the API server.** It passes authn/authz, then **admission controllers** run: a policy rejects `image: …:latest`, so the pod uses a pinned tag. Object is written to etcd with `nodeName: <empty>`.

**Step 2 — Scheduling Queue (PrioritySort).** The pod has `priorityClassName: high-priority` (value 1,000,000), so it's ordered ahead of default (value 0) pods waiting in the queue.

**Step 3 — Filtering (feasible nodes only).** The scheduler eliminates nodes:
- CPU-only nodes → **filtered out** by the pod's `nodeAffinity: gpu=true` (attract lever).
- Nodes without enough free memory for the pod's `requests` → **filtered out** (fit lever).
- The GPU node is tainted `gpu=true:NoSchedule`; the pod has a matching **toleration**, so it **passes** that repel. Other pods without the toleration were filtered off this node.

**Step 4 — Preemption (if no node fits).** Suppose the GPU node is full of low-priority pods. Because our pod is high-priority with `PreemptLowerPriority`, the scheduler **evicts** a low-priority pod to free room, then proceeds.

**Step 5 — Scoring.** Among surviving nodes (here, just the GPU node), soft signals (image already cached? `preferred` affinity?) score them; the best wins.

**Step 6 — Binding.** The scheduler sets `spec.nodeName: gpu-node01` (a Binding write through the API server → etcd).

**Step 7 — kubelet runs it.** The kubelet on `gpu-node01` (watching the API server) sees its pod and starts the container via the runtime. The scheduler's job ended at Step 6 — it *decided*, it never *placed*.

```
create → [admission: reject :latest] → etcd(nodeName:empty)
      → QUEUE(priority high, goes first)
      → FILTER(affinity gpu=true ✓ · requests fit ✓ · toleration passes taint ✓)
      → [PREEMPT a low-prio pod if full]
      → SCORE → BIND(nodeName=gpu-node01) → kubelet starts container
```

> **✅ Check yourself before Rung 6:** In this trace, three separate levers all "chose" the GPU node — the taint/toleration, the nodeAffinity, and the resource request. State what each one contributed. And: at which single step does the scheduler's involvement *end*?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of each lever defines it*

| This… | vs that… | The real difference |
|---|---|---|
| **Taint/Toleration** | **nodeAffinity** | node *repels* pods vs pod *requires* a node (repel vs attract) |
| **nodeSelector** | **nodeAffinity** | simple equality vs operators + soft/hard rules |
| **requests** | **limits** | schedule-time fit vs runtime ceiling |
| **Static pod** | **DaemonSet** | kubelet runs it directly (control-plane bootstrap) vs API-managed one-per-node |
| **Manual `nodeName`** | **the scheduler** | you bypass matchmaking vs it filters+scores for you |
| **PriorityClass preemption** | **plain scheduling** | can *evict* others to fit vs only uses free space |

**Why taints alone can't dedicate a node:** a taint stops *other* pods landing, but your target pod could still schedule on any *other* untainted node — so you add **affinity** to pull it back. Two-sided problem, two levers.

**When NOT to use these:** don't reach for affinity/taints on a small uniform cluster (adds complexity for no benefit); don't set CPU **limits** reflexively (they can waste idle capacity via throttling — set **requests** always, limits carefully); don't hand-pin `nodeName` in production (defeats self-healing across node failures).

**One-sentence "why this over that":**
> Use taints to keep the wrong pods *off* a node and affinity to keep the right pods *on* it; use requests so the scheduler can place by real capacity, and reserve static pods for the control plane and DaemonSets for true one-per-node agents.

> **✅ Check yourself before Rung 7:** A teammate tainted the GPU node and is surprised their GPU pod landed on a *different* node anyway. Explain *why* — and what single addition fixes it.

---

# RUNG 7 — The Prediction Test 🧪
### *Predict BEFORE you run. A wrong prediction repairs your model.*

## Prediction 1 — Dedicate a node needs BOTH taint and affinity

> **My prediction:** "If I only taint `node01` for blue, then blue pods might still land elsewhere; only after I *also* add nodeAffinity requiring `app=blue` will blue pods run **exclusively** on node01 and nothing else run there — *because* taint = repel others, affinity = require this node."

```bash
kubectl taint nodes node01 app=blue:NoSchedule     # repel everyone else
kubectl label nodes node01 app=blue                # so affinity has something to match
```
```yaml
spec:
  tolerations: [{ key: app, operator: Equal, value: blue, effect: NoSchedule }]
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions: [{ key: app, operator: In, values: [blue] }]
```
**Verify:** `kubectl get pods -o wide` → blue pods only on node01, no other pods there. Remove *one* lever and watch leakage — that's the proof you need both.

## Prediction 2 — A missing toleration keeps a pod Pending

> **My prediction:** "If I taint every candidate node `NoSchedule` and my pod has no matching toleration, then it stays **Pending** with a `FailedScheduling` event mentioning taints — *because* filtering removed every node."

```bash
kubectl taint nodes node01 key=val:NoSchedule
kubectl run test --image=nginx
kubectl get pod test                 # Pending
kubectl describe pod test | grep -A3 Events   # "node(s) had untolerated taint"
```
**Verify:** the event names the taint. Add a toleration (or `kubectl taint nodes node01 key=val:NoSchedule-`) and it schedules. If it scheduled anyway, another untainted node existed.

## Prediction 3 — OOMKilled = memory limit too low, and it's immutable live

> **My prediction:** "If a pod's memory `limit` is below what it uses, then `describe` shows `Last State: Terminated, Reason: OOMKilled`, and `kubectl edit pod` will *refuse* to raise the limit live — *because* memory can't be throttled (hard kill) and resource limits are immutable on a running pod."

```bash
kubectl describe pod elephant | grep -A3 "Last State"   # OOMKilled
kubectl edit pod elephant           # raise memory limit → DENIED (immutable)
kubectl replace --force -f /tmp/kubectl-edit-XXXXX.yaml  # kubectl saved your edit here
kubectl get pod elephant -w         # Running
```
**Verify:** the pod runs after recreate; OOMKilled is gone. Lesson: **memory = hard kill**, and immutable pod fields need `replace --force` (or edit the Deployment, which auto-rolls).

## Prediction 4 — A static pod ignores `kubectl delete`

> **My prediction:** "If I drop a manifest in `/etc/kubernetes/manifests/` the kubelet creates the pod (name gets the node suffix), and `kubectl delete pod` won't remove it — it comes right back — until I delete the **file** — *because* the kubelet owns it directly; the API object is only a mirror."

```bash
grep staticPodPath /var/lib/kubelet/config.yaml     # find the dir
kubectl run static-web --image=nginx --dry-run=client -o yaml \
  > /etc/kubernetes/manifests/static-web.yaml
kubectl get pods                    # static-web-<node> appears
kubectl delete pod static-web-<node>   # ...it comes back
rm /etc/kubernetes/manifests/static-web.yaml   # THIS deletes it
```
**Verify:** gone only after the file is removed. If the name ends in a different node, ssh there — the file lives on that node.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | If wrong, what did I miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Scheduling is a matchmaker that filters nodes a pod can't run on, scores the rest, and binds the best — and taints, affinity, requests, priority, static pods and DaemonSets are just levers that bias, override, or bypass that filter/score.

**Explain it to a beginner in 3 sentences:**
> 1. When you create a pod, a component called the scheduler picks which node it runs on by first ruling out unsuitable nodes, then ranking what's left.
> 2. You steer that decision with levers — taints push pods away from a node, affinity pulls the right pods onto it, resource requests make sure the node has room, and priority lets critical pods jump the queue (even evicting others).
> 3. A few workloads skip the scheduler entirely: static pods are run straight by the node's kubelet (that's how the control plane starts), and DaemonSets deliberately run one copy on every node.

**Which rung to revisit hands-on?**
- **Rung 3B — taints vs affinity.** People conflate repel and attract. Fix: do Prediction 1 and delete one lever.
- **Rung 3C — static pods.** The mirror/file distinction is slippery. Fix: Prediction 4, on a worker node.

---

## 🎯 CKA exam tips & quick notes

- **Generate, then edit:** `k run/create ... $do > f.yaml`, add the taint/affinity/resources block, `k apply -f`.
- **Taint syntax:** `key=value:Effect` to add, **append `-`** to remove. Toleration values are **quoted strings**.
- **Pending-pod triage order:** (1) is the scheduler running? (2) taints vs tolerations, (3) affinity/selector match, (4) resource fit — all via `describe pod` → Events.
- **Immutable pod fields** → `kubectl replace --force -f`. Deployment-managed pods → `kubectl edit deployment` (auto-rolls).
- **No `create daemonset`** → Deployment YAML, flip `kind`, drop `replicas`+`strategy`.
- **Static pods** in `/etc/kubernetes/manifests`; delete via the **file**. Find dir: `grep staticPodPath /var/lib/kubelet/config.yaml`.
- Editing `kube-apiserver.yaml` (admission plugins) **restarts the apiserver** — brief `kubectl` outage, then verify.
- **CPU = throttle, Memory = OOMKill; request = schedule, limit = cap.**
- `kubectl get events -o wide` → which **scheduler** placed a pod.

## 📌 Command cheat sheet
```bash
# TAINTS / LABELS / AFFINITY
k taint nodes node01 key=val:NoSchedule          # add   (…:NoSchedule- to remove)
k label nodes node01 size=large                  # label (for nodeSelector/affinity)
k describe node node01 | grep -iE 'taint|label'
# RESOURCES
k describe pod x | grep -A5 -iE 'limits|requests|Last State'   # values / OOMKilled
k replace --force -f /tmp/kubectl-edit-xxxx.yaml               # recreate after immutable edit
# DAEMONSET (no create cmd)
k create deploy ds --image=nginx $do > ds.yaml   # kind->DaemonSet, drop replicas/strategy
# STATIC PODS
grep staticPodPath /var/lib/kubelet/config.yaml
k run web --image=nginx $do > /etc/kubernetes/manifests/web.yaml
# PRIORITY / SCHEDULERS / ADMISSION
k get priorityclass
k get events -o wide                             # which scheduler placed the pod
grep -- "admission-plugins" /etc/kubernetes/manifests/kube-apiserver.yaml
```

---

## Related sections

- [Section 1 — Core Concepts](01-core-concepts.md) — the scheduler's place in the pod-creation flow; labels/selectors.
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — configmaps/secrets/rollouts on the pods you schedule.
- [Section 6 — Security](06-security.md) — RBAC/authorization that admission controllers run *after*.
- [Section 7 — Storage](07-storage.md) — the `DefaultStorageClass` mutating admission controller in action.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — diagnosing Pending / OOMKilled pods.
- [../../Linux/14-cgroups.md](../../Linux/14-cgroups.md) — the cgroups that enforce CPU throttle / memory OOMKill.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Give two concrete failures that happen if the scheduler ignores *what kind* of node a pod needs.

**A:** (1) **Special hardware:** a GPU training pod lands on a cheap CPU-only node and either crashes or runs ~100x slower — the hardware guarantee is gone. (2) **Noisy neighbors:** a noisy batch job lands right next to your production API, eats all the RAM, and the API gets OOM-killed — there's no isolation. (Licensed workloads landing on non-licensed nodes, and critical pods stuck Pending behind low-value pods, are further failures from the same list.)

### Before Rung 3
**Q:** Say the one-sentence idea. Then: a taint and a nodeAffinity rule both keep a pod off the "wrong" node — which is a *node repelling pods* and which is a *pod requiring a node*? Why do you often need both?

**A:** The sentence: **the scheduler is a matchmaker — for every pod with an empty `nodeName` it FILTERS out nodes that can't run it, SCORES the survivors, and BINDS the pod to the best one, and every scheduling feature is a lever that biases that filter or score (or bypasses the matchmaker entirely).** A **taint** is the *node repelling pods*: the node says "keep out unless you tolerate me." **nodeAffinity** is the *pod requiring a node*: the pod says "only nodes labeled like this." You often need both because each only solves half of dedicating a node: the taint keeps *other* pods off your node but does nothing to stop your pod landing on some other untainted node, while affinity pulls your pod to the node but doesn't keep strangers away. Taint + affinity together give "only these pods here, and these pods only here."

### Before Rung 4
**Q:** A pod is Pending. Name the three different reasons a node could get filtered out (one about the node, one about the pod's node requirement, one about capacity). Which field does the scheduler read for capacity — `requests` or `limits`?

**A:** (1) **About the node — taints:** the node carries a taint (e.g. `NoSchedule`) that the pod has no toleration for, so the node repels it (TaintToleration filter). (2) **About the pod's requirement — affinity:** the pod's `nodeSelector` or `requiredDuringSchedulingIgnoredDuringExecution` nodeAffinity doesn't match the node's labels, so the node fails the pod's requirement (NodeAffinity filter). (3) **About capacity — fit:** the node doesn't have enough free CPU/memory to satisfy the pod's resource requests (NodeResourcesFit filter). The scheduler reads **`requests`**, never `limits` — requests are for schedule-time fit; limits are only a runtime ceiling. If no node survives all three filters, the pod stays Pending.

### Before Rung 5
**Q:** Sort into repel / attract / fit / bypass: a `NoSchedule` taint, a `requiredDuringScheduling` nodeAffinity, a `memory: 256Mi` request, a static pod. Which two must be used together to truly dedicate a node?

**A:** `NoSchedule` taint = **repel** (the node pushes pods away); `requiredDuringScheduling` nodeAffinity = **attract/require** (the pod pulls itself to matching nodes); `memory: 256Mi` request = **fit** (capacity check); static pod = **bypass** (the kubelet runs it directly, skipping the scheduler). The two that must be combined to truly dedicate a node are the **taint** and the **affinity**: the taint keeps everyone else off the node, and the affinity keeps your pods on it — neither alone closes both sides.

### Before Rung 6
**Q:** In the GPU-pod trace, three levers all "chose" the GPU node — taint/toleration, nodeAffinity, and the resource request. What did each contribute? At which step does the scheduler's involvement end?

**A:** The **nodeAffinity** (`gpu=true`) was the attract lever: it filtered out every CPU-only node so only GPU nodes remained candidates. The **resource request** was the fit lever: it filtered out any node without enough free memory to satisfy the pod's requests. The **taint/toleration** was the repel lever working in reverse: the GPU node's `gpu=true:NoSchedule` taint had already kept ordinary pods off it, and our pod's matching toleration let it pass that repel filter. The scheduler's involvement ends at **Step 6 — Binding**, when it writes `spec.nodeName: gpu-node01` through the API server; it only *decides*, it never *places* — the kubelet on that node actually starts the container.

### Before Rung 7
**Q:** A teammate tainted the GPU node and is surprised their GPU pod landed on a different node anyway. Why — and what single addition fixes it?

**A:** Because **taints only repel; they don't attract.** The taint keeps intolerant pods *off* the GPU node, and the teammate's pod (with its toleration) is merely *allowed* onto it — but the scheduler is still free to bind that pod to any other untainted node that passes filtering, and it did. The single fix is to add a **nodeAffinity** (or nodeSelector) on the pod requiring the GPU node's label (e.g. `gpu=true`, after labeling the node), so the pod is *required* to land there. That's the classic taint + affinity combo: repel others off, pull yours on.
