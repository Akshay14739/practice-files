# 📅 Section 2 — Scheduling (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 2 transcript.

---

## 1. How scheduling works + Manual scheduling

### ❓ What
The **kube-scheduler** finds every pod with an empty `spec.nodeName`, filters/scores nodes, and binds the pod to the best one. Manual scheduling = you set the node yourself.

### 🔥 Pain points it solves & why this?
- Humans picking hosts per container doesn't scale and gets capacity wrong.
- When there's **no scheduler** (broken control plane, special cases), pods hang **Pending** — you need the bypass: `nodeName` or a Binding object.
- A pod can't be *moved* live — knowing this saves exam minutes (delete + recreate).

### ⚙️ How exactly it works
Queue → **Filter** (feasible nodes) → **Score** (best node) → **Bind** (write `nodeName`).

| Vocabulary | Meaning |
|---|---|
| `spec.nodeName` | the field scheduling ultimately sets; settable only at creation |
| Binding object | a POST to the pod's binding API — exactly what the scheduler does |
| `Pending` | pod with no node — scheduler missing or no node passed filtering |

### 🧪 Hands-on examples

**Example 1 — Manually place a pod (no scheduler needed):**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: manual }
spec:
  nodeName: node01              # bypasses the scheduler entirely
  containers: [ { name: nginx, image: nginx } ]
EOF
kubectl get pod manual -o wide      # on node01, no scheduler involved
# Verify: pod Running on node01 even if the scheduler is down.
```

**Example 2 — Detect a missing scheduler:**
```bash
kubectl run t --image=nginx
kubectl get pod t                              # Pending, Node: <none>
kubectl describe pod t | grep -A3 Events       # NO events at all = nobody is scheduling
kubectl get pods -n kube-system | grep scheduler   # scheduler missing/crashed
# Verify: Pending + zero events ⇒ scheduler problem (Section 13 skill).
```

**Example 3 — "Move" a running pod:**
```bash
kubectl get pod manual -o yaml > m.yaml   # edit nodeName → node02
kubectl replace --force -f m.yaml         # delete + recreate (live move is impossible)
kubectl get pod manual -o wide            # now on node02
# Verify: you cannot edit nodeName live; replace --force is the way.
```

---

## 2. Labels, Selectors & Annotations

### ❓ What
**Labels** = key/value tags on objects; **selectors** = queries over labels; **annotations** = non-identifying metadata (build info, contacts).

### 🔥 Pain points it solves & why this?
- Hundreds of objects need grouping/filtering (by app, env, tier) without rigid hierarchies.
- Kubernetes *itself* wires objects together with them: Service→pods, ReplicaSet→pods.
- Annotations carry data tools need without polluting selection.

### ⚙️ How exactly it works
Selectors match labels with AND semantics (`-l a=1,b=2`). Inside an RS/Deployment, `spec.selector.matchLabels` must equal `template.metadata.labels`.

### 🧪 Hands-on examples

**Example 1 — Filter and count under pressure:**
```bash
kubectl get pods -l env=dev
kubectl get pods -l env=prod,bu=finance,tier=frontend      # AND of 3 labels
kubectl get pods -l env=prod --no-headers | wc -l          # count (strip header!)
kubectl get all -l env=prod                                # any object type
# Verify: counts match; --no-headers avoids the +1 header bug.
```

**Example 2 — Label live objects and select them:**
```bash
kubectl run p1 --image=nginx; kubectl label pod p1 env=dev tier=web
kubectl label pod p1 tier=api --overwrite      # change a label
kubectl label pod p1 env-                      # remove a label (trailing minus)
kubectl get pods -L env,tier                   # show labels as columns
# Verify: -L displays your labels; selection reflects each change.
```

**Example 3 — See labels wiring a Service to pods:**
```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80
kubectl get ep web                             # endpoints = pods matched BY LABEL
kubectl label pod <one-web-pod> app-           # strip the label
kubectl get ep web                             # that pod's IP vanished from endpoints
# Verify: endpoints track label matches in real time.
```

---

## 3. Taints & Tolerations

### ❓ What
A **taint** on a node repels pods; a **toleration** on a pod lets it ignore that taint. Taints go on **nodes**, tolerations on **pods**.

### 🔥 Pain points it solves & why this?
- Reserve nodes (GPU, licensed, control plane) so random pods don't land there.
- It's the *node's* way to say "keep out" — the inverse of affinity (pod's way to say "I want that node").
- ⚠️ Repel-only: a tolerating pod may still land elsewhere — combine with affinity to dedicate.

### ⚙️ How exactly it works

| Effect | Meaning |
|---|---|
| `NoSchedule` | new intolerant pods won't schedule here |
| `PreferNoSchedule` | scheduler *tries* to avoid (soft) |
| `NoExecute` | repels new AND **evicts** existing intolerant pods |

The control plane itself is tainted: `node-role.kubernetes.io/control-plane:NoSchedule` — that's why workloads never land there.

### 🧪 Hands-on examples

**Example 1 — Taint, watch repulsion, tolerate:**
```bash
kubectl taint nodes node01 app=blue:NoSchedule
kubectl run normal --image=nginx
kubectl get pod normal -o wide           # NOT on node01 (repelled)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: tolerant }
spec:
  tolerations:
  - { key: "app", operator: "Equal", value: "blue", effect: "NoSchedule" }
  containers: [ { name: nginx, image: nginx } ]
EOF
kubectl get pod tolerant -o wide         # CAN land on node01 (not guaranteed!)
# Verify: normal avoids node01; tolerant may use it.
```

**Example 2 — NoExecute evicts existing pods:**
```bash
kubectl run victim --image=nginx        # wait until it's on node01
kubectl taint nodes node01 maint=true:NoExecute
kubectl get pod victim                   # being evicted/gone
# Verify: NoExecute doesn't just block new pods — it evicts intolerant ones.
```

**Example 3 — Remove a taint (the trailing-minus syntax):**
```bash
kubectl describe node node01 | grep -i taint
kubectl taint nodes node01 app=blue:NoSchedule-      # note the "-"
kubectl describe node node01 | grep -i taint         # gone
# Verify: same triple + "-" removes it; pods can schedule again.
```

---

## 4. Node Selectors & Node Affinity

### ❓ What
Pod-side placement requirements: **nodeSelector** = simple "node must have this label"; **nodeAffinity** = expressive version (operators `In/NotIn/Exists/Gt/Lt`, hard vs soft rules).

### 🔥 Pain points it solves & why this?
- Some pods *need* certain nodes (big memory, SSD, GPU) — taints can't express "I require," only "keep out."
- nodeSelector can't do OR / NOT / exists — affinity adds those.
- Hard vs soft: "must be a large node" vs "prefer large, else anywhere."

### ⚙️ How exactly it works
Label the node first, then require/prefer it. Read the affinity type names literally:

| Type | No matching node at scheduling | Label removed later |
|---|---|---|
| `requiredDuringSchedulingIgnoredDuringExecution` | **Pending** (hard) | keeps running |
| `preferredDuringSchedulingIgnoredDuringExecution` | placed anywhere (soft) | keeps running |

### 🧪 Hands-on examples

**Example 1 — nodeSelector (the simple case):**
```bash
kubectl label nodes node01 size=large
kubectl run big --image=nginx --dry-run=client -o yaml > big.yaml
# add under spec:   nodeSelector: { size: large }
kubectl apply -f big.yaml
kubectl get pod big -o wide          # on node01
# Verify: without the node label, the pod would stay Pending.
```

**Example 2 — Affinity with In (multiple values):**
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: size, operator: In, values: [large, medium] }
```
```bash
kubectl apply -f affinity-pod.yaml && kubectl get pod -o wide
# Verify: schedules on any node labeled large OR medium — nodeSelector can't do OR.
```

**Example 3 — Exists + the Pending trap:**
```bash
# operator: Exists (no values) = "node just needs the key"
# Apply a required affinity for a label NO node has:
kubectl get pod picky                       # Pending
kubectl describe pod picky | grep -A3 Events  # "didn't match node selector/affinity"
kubectl label nodes node01 special=true     # satisfy it
kubectl get pod picky -o wide               # schedules immediately
# Verify: required affinity = Pending until a node matches; labeling fixes it live.
```

---

## 5. Resource Requests & Limits (+ LimitRange, ResourceQuota)

### ❓ What
**request** = guaranteed minimum the scheduler uses for placement; **limit** = runtime ceiling. **LimitRange** = per-namespace defaults; **ResourceQuota** = per-namespace total cap.

### 🔥 Pain points it solves & why this?
- No requests → the scheduler packs blindly; one greedy pod starves neighbors.
- CPU over limit → **throttled**; memory over limit → **OOMKilled** (memory can't be throttled) — the distinction explains mystery pod deaths.
- Defaults matter: pods with no requests/limits get none unless a LimitRange injects them.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| CPU `1` / `100m` | 1 core / 0.1 core (min `1m`) |
| `Mi/Gi` vs `M/G` | 1024-based vs 1000-based — `256Mi ≠ 256M` |
| OOMKilled | container exceeded memory limit → killed |
| LimitRange | default/min/max per container in a namespace (affects NEW pods) |
| ResourceQuota | total namespace budget |

Editable live pod fields: only `image`, `activeDeadlineSeconds`, `tolerations`, init image — resources are **immutable** → `replace --force`.

### 🧪 Hands-on examples

**Example 1 — Requests/limits on a pod:**
```yaml
resources:
  requests: { memory: "256Mi", cpu: "250m" }   # scheduler places by this
  limits:   { memory: "512Mi", cpu: "500m" }   # runtime ceiling
```
```bash
kubectl apply -f pod.yaml && kubectl describe pod app | grep -A6 -i limits
# Verify: describe shows both; the node had ≥256Mi/250m free.
```

**Example 2 — Diagnose & fix OOMKilled (exam classic):**
```bash
kubectl describe pod elephant | grep -A3 "Last State"    # Reason: OOMKilled
kubectl edit pod elephant           # raise memory limit → DENIED (immutable)
kubectl replace --force -f /tmp/kubectl-edit-XXXX.yaml   # kubectl saved your edit there
kubectl get pod elephant            # Running
# Verify: memory = hard kill; immutable fields need replace --force.
```

**Example 3 — LimitRange injects defaults:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata: { name: cpu-defaults, namespace: default }
spec:
  limits:
  - type: Container
    default: { cpu: 500m }           # limit if none set
    defaultRequest: { cpu: 250m }    # request if none set
EOF
kubectl run plain --image=nginx
kubectl get pod plain -o jsonpath='{.spec.containers[0].resources}{"\n"}'
# Verify: the new pod got 250m/500m automatically; pods created BEFORE the LimitRange are untouched.
```

---

## 6. DaemonSets

### ❓ What
A controller that runs **exactly one copy of a pod on every node** (auto-added/removed as nodes join/leave).

### 🔥 Pain points it solves & why this?
- Node-level agents (kube-proxy, CNI, log collectors, monitoring) must exist on *every* node — a Deployment can't guarantee that.
- Manual per-node deployment breaks the moment autoscaling adds a node.

### ⚙️ How exactly it works
Same YAML shape as a Deployment/RS (selector + template) but **no `replicas`** — node count *is* the count. Since v1.12 it uses the default scheduler + node affinity per node. **There is no `kubectl create daemonset`** — generate a Deployment and convert.

### 🧪 Hands-on examples

**Example 1 — The create-by-conversion trick:**
```bash
kubectl create deployment mon --image=prom/node-exporter --dry-run=client -o yaml > ds.yaml
# edit: kind: DaemonSet ; DELETE replicas: and strategy: blocks
kubectl apply -f ds.yaml
kubectl get ds mon ; kubectl get pods -o wide -l app=mon    # one per node
# Verify: pod count == node count.
```

**Example 2 — Find existing DaemonSets (recon):**
```bash
kubectl get daemonsets -A
# kube-proxy and your CNI (weave/flannel/calico) are DaemonSets
kubectl describe ds kube-proxy -n kube-system | grep -i image
# Verify: you can explain WHY these two must be DaemonSets (every node needs them).
```

**Example 3 — DaemonSets follow nodes:**
```bash
kubectl get pods -l app=mon -o wide          # note nodes
# join/remove a node (or uncordon a cordoned one) …
kubectl get pods -l app=mon -o wide          # a copy appeared/disappeared with the node
# Verify: no scaling action needed — membership tracks the node pool.
```

---

## 7. Static Pods

### ❓ What
Pods the **kubelet runs directly from manifest files on disk** (`/etc/kubernetes/manifests/`) — no API server, scheduler, or controllers involved. This is how kubeadm bootstraps the control plane itself.

### 🔥 Pain points it solves & why this?
- Chicken-and-egg: the control plane is made of pods, but who runs pods before the control plane exists? → the kubelet alone can.
- Node-critical workloads that must run even if the API server is unreachable.

### ⚙️ How exactly it works
The kubelet watches the dir from `staticPodPath` in `/var/lib/kubelet/config.yaml`: file added → pod created; edited → recreated; deleted → pod gone. The API server shows a **read-only mirror** named `<pod>-<nodename>` — `kubectl delete` on it just respawns it. Only Pods (no RS/Deploy/Service).

### 🧪 Hands-on examples

**Example 1 — Create a static pod:**
```bash
grep staticPodPath /var/lib/kubelet/config.yaml        # /etc/kubernetes/manifests
kubectl run static-web --image=nginx --dry-run=client -o yaml | \
  sudo tee /etc/kubernetes/manifests/static-web.yaml >/dev/null
kubectl get pods                    # static-web-<node> appears (mirror)
# Verify: name carries the node suffix — the static-pod fingerprint.
```

**Example 2 — Prove kubectl can't kill it:**
```bash
kubectl delete pod static-web-node01     # deleted…
kubectl get pods                          # …and it's BACK (kubelet owns it)
sudo rm /etc/kubernetes/manifests/static-web.yaml    # the real delete
kubectl get pods                          # gone for good
# Verify: lifecycle is the FILE, not the API object.
```

**Example 3 — Identify a static pod among normal ones (exam question):**
```bash
kubectl get pods -A -o wide | grep -E -- "-controlplane|-node01"   # node-suffix names
kubectl get pod kube-apiserver-controlplane -n kube-system -o yaml | grep -A3 ownerReferences
# → kind: Node  (not ReplicaSet) — owned by the node = static pod
# Verify: ownerReferences.kind: Node is the definitive tell.
```

---

## 8. Priority Classes

### ❓ What
A cluster-wide (non-namespaced) object assigning pods an integer **priority**; higher schedules first and can **preempt** (evict) lower-priority pods when space runs out.

### 🔥 Pain points it solves & why this?
- In a full cluster, critical workloads must not lose the race for space to batch jobs.
- Without preemption, an important pod waits behind junk indefinitely.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `value` | bigger = more important (user range ≤ ~1e9; system classes ~2e9) |
| default | no priorityClass → value **0**; `globalDefault: true` changes that (one per cluster) |
| `preemptionPolicy` | `PreemptLowerPriority` (default, evicts) or `Never` (waits, but still queue-jumps) |

### 🧪 Hands-on examples

**Example 1 — Create and use a class:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: { name: high-priority }
value: 1000000
description: "critical apps"
EOF
kubectl run vip --image=nginx --dry-run=client -o yaml > vip.yaml
# add under spec:  priorityClassName: high-priority
kubectl apply -f vip.yaml
kubectl get pod vip -o jsonpath='{.spec.priority}{"\n"}'    # 1000000
# Verify: priority resolved from the class.
```

**Example 2 — See system classes and defaults:**
```bash
kubectl get priorityclass
# system-cluster-critical / system-node-critical ≈ 2e9 — why control-plane pods never lose
kubectl run plain --image=nginx
kubectl get pod plain -o jsonpath='{.spec.priority}{"\n"}'   # 0 (no default set)
# Verify: unclassed pods run at 0.
```

**Example 3 — Watch preemption on a full node:**
```bash
# Fill a node with low-priority pods (big requests), then:
kubectl apply -f vip.yaml            # high-priority, PreemptLowerPriority
kubectl get pods -w                  # a low-priority pod is Terminating → vip schedules
# With preemptionPolicy: Never instead → vip waits Pending but ahead of the queue.
# Verify: preemption evicts to make room; Never queues politely.
```

---

## 9. Multiple Schedulers & Scheduler Profiles

### ❓ What
You can run **custom schedulers** beside the default and pick per-pod (`schedulerName`), or — since v1.18 — run several **profiles** inside ONE scheduler binary, each with plugins enabled/disabled.

### 🔥 Pain points it solves & why this?
- Special placement logic (bin-packing, batch) that the default scheduler doesn't do.
- Separate scheduler *processes* can race for the same nodes → **profiles** share one process, no races.

### ⚙️ How exactly it works
The scheduling pipeline is pluggable at **extension points**:
```
Queue(PrioritySort) → Filter(NodeResourcesFit,TaintToleration,NodeName,NodeUnschedulable)
                    → Score(NodeResourcesFit,ImageLocality) → Bind(DefaultBinder)
```
```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
- schedulerName: no-scoring-scheduler
  plugins: { score: { disabled: [ { name: '*' } ] } }
```

### 🧪 Hands-on examples

**Example 1 — Point a pod at a specific scheduler:**
```yaml
spec:
  schedulerName: my-scheduler
  containers: [ { name: nginx, image: nginx } ]
```
```bash
kubectl apply -f pod.yaml
kubectl get pod nginx    # Pending forever if my-scheduler doesn't exist!
# Verify: a pod naming a nonexistent scheduler simply never schedules.
```

**Example 2 — Which scheduler placed a pod?**
```bash
kubectl get events -o wide | grep Scheduled
# SOURCE column: default-scheduler vs my-scheduler
# Verify: events attribute every binding to its scheduler.
```

**Example 3 — Inspect / debug a custom scheduler:**
```bash
kubectl get pods -n kube-system | grep scheduler
kubectl logs my-scheduler-xyz -n kube-system     # leader election + binding logs
# Verify: the logs show it winning leadership and binding your pod.
```

---

## 10. Admission Controllers

### ❓ What
Plugins in the API server that run **after authn/authz** and can **validate**, **mutate**, or **reject** a request before it's persisted.

### 🔥 Pain points it solves & why this?
- RBAC only answers *who may do what to which resource* — not "no `latest` tags," "no root containers," "auto-add a storage class." Those are request-content policies.
- Mutation enables sane defaults without users writing them (e.g. `DefaultStorageClass`).

### ⚙️ How exactly it works
```
Request → Authentication → Authorization(RBAC) → ADMISSION: mutating → validating → etcd
```
- Mutating first (so changes get validated): `DefaultStorageClass`, `NamespaceAutoProvision` (deprecated).
- Validating: `NamespaceLifecycle` (rejects pods in missing namespaces, protects default/kube-system).
- **Webhooks** (`MutatingAdmissionWebhook` / `ValidatingAdmissionWebhook`) call *your* server for custom logic.
- Configured via apiserver flags; editing the manifest restarts the apiserver (~30–60 s kubectl blip).

### 🧪 Hands-on examples

**Example 1 — See what's enabled:**
```bash
kubectl exec kube-apiserver-controlplane -n kube-system -- \
  kube-apiserver -h | grep enable-admission-plugins   # defaults list
sudo grep -- "admission-plugins" /etc/kubernetes/manifests/kube-apiserver.yaml
# Verify: you can state which plugins are on beyond the defaults.
```

**Example 2 — Enable a plugin (and survive the restart):**
```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
#   - --enable-admission-plugins=NodeRestriction,NamespaceAutoProvision
watch crictl ps        # apiserver container restarts
kubectl run t --image=nginx -n brand-new-ns    # namespace auto-created!
# Verify: without the plugin this fails "namespace not found"; with it, the ns appears.
```

**Example 3 — Watch a mutating controller act:**
```bash
kubectl get sc                       # note the (default) StorageClass
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: no-class-pvc }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } } }
EOF
kubectl get pvc no-class-pvc -o jsonpath='{.spec.storageClassName}{"\n"}'
# Verify: the DefaultStorageClass admission controller INJECTED the class you never wrote.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Pending-pod triage order** (ties this whole section together): (1) scheduler running? (2) taints vs tolerations, (3) affinity/selector match, (4) resource fit — all readable from `kubectl describe pod` Events.
- **Pod Topology Spread Constraints** exist for spreading pods across zones/nodes (`topologySpreadConstraints`) — newer alternative to affinity tricks for balancing.

---

## Related
[01-core-concepts](01-core-concepts.md) · [07-storage](07-storage.md) (DefaultStorageClass) · [13-troubleshooting](13-troubleshooting.md) (Pending pods) · Ladder version: [../README/02-scheduling.md](../README/02-scheduling.md)
