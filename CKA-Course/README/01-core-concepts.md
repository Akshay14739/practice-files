# Core Concepts, Climbed the Ladder 🪜
### Section 1 of the CKA — deriving how Kubernetes works, not memorizing kubectl

> This is the CKA "Core Concepts" section rebuilt on the **Learning Ladder**. Instead of leading with `kubectl`, we climb from **why Kubernetes exists** → **the one core idea** → **the machinery** → and only at the top, the commands. Each rung ends with a **✅ Check yourself** question — answer it in your own words and climb on; if you can't, that rung is your next hands-on session.
>
> **The one rule:** every command in Rung 7 sits at the TOP of the ladder on purpose. You'll understand *what it does to the machinery* before you run it — which is exactly what the exam tests when it hands you a broken cluster.

---

# RUNG 0 — The Setup 🎯

**What am I learning?**
The core Kubernetes object model and cluster architecture — the foundation every other CKA section builds on: control plane vs worker nodes, and the primitives Pod → ReplicaSet → Deployment → Service → Namespace.

**Why did it land on my desk?**
I'm sitting the **Certified Kubernetes Administrator** exam — 2 hours, 100% hands-on, and *Cluster Architecture* alone is 25% of the score. I can't debug a cluster I can't picture.

**What do I already know about it?**
Probably that "pods run containers" and `kubectl get pods` lists them. What's usually fuzzy: *why* there's a control plane, what actually happens between `kubectl apply` and a running container, and why a Service exists at all. That fuzziness is what this ladder removes.

---

# RUNG 1 — The Pain 🔥
### *Why does Kubernetes exist at all?*

Sit with the problem before touching a single object. If you understand the pain, the whole API stops needing memorization — you can *derive* what Kubernetes must do to relieve it.

You have containers to run in production. A raw container runtime (Docker alone) gives you *nothing* for the hard parts:

```
LIFE WITHOUT AN ORCHESTRATOR (the pre-Kubernetes pain)

  You: docker run myapp        ┌─ container dies at 3AM ──▶ nobody notices, app is down
       docker run myapp        ├─ traffic spikes ────────▶ you SSH in and manually run more
       docker run myapp        ├─ need a new version ────▶ stop all / start all = downtime
                               ├─ which host has room? ──▶ you track it in your head / a spreadsheet
                               └─ container IP changed ──▶ whatever pointed at it is now broken
```

**What people did before — and why it hurt:**
- **Self-healing:** none. A crashed container stays dead until a human notices.
- **Scaling:** manual. You SSH to a box and `docker run` more copies, then wire up a load balancer by hand.
- **Placement:** manual. *You* decide which server has spare CPU/RAM — and get it wrong.
- **Rolling updates:** all-or-nothing. Stop v1 everywhere, start v2 everywhere = an outage window.
- **Networking:** container IPs are ephemeral. Anything hard-coded to an IP breaks on the next restart.

**Who feels this pain most?** The **platform / ops / SRE team** — you. Developers write features; when something falls over at 3 AM or a deploy needs zero downtime, it's the platform team holding the bag. Kubernetes is fundamentally a **platform team's tool**: it automates the operational survival kit so humans don't run it by hand.

**What breaks without it:** every operational guarantee — availability (nothing restarts dead apps), elasticity (no autoscaling), safe releases (no rolling update/rollback), and stable service discovery (no fixed address for a moving target).

> **✅ Check yourself before Rung 2:** In one breath — name three things a bare container runtime can't do for you in production that forced an orchestrator to be invented. (Hint: what happens when a container dies, when traffic spikes, and when its IP changes?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this exact sentence — the entire object model can be *derived* from it:

> **Kubernetes is a set of controllers that continuously reconcile the cluster's *actual* state toward the *desired* state you declare, with the API server + etcd as the single hub and source of truth.**

That's the whole trick. Everything else is detail. Watch how much falls out of it:

- *"you declare desired state"* → you write **YAML objects** (Pod, Deployment, Service). You never issue step-by-step orders; you describe the end goal.
- *"controllers continuously reconcile"* → there's a **control loop** watching: "desired = 3 replicas, actual = 2, so create 1." This is why Kubernetes **self-heals** — killing a pod just widens the gap the controller closes.
- *"actual toward desired"* → **ReplicaSets, Deployments, the node controller** are all the same pattern: watch a number, drive reality to match it.
- *"API server + etcd as the single hub"* → **every** action (yours, the scheduler's, the kubelet's) goes *through* the API server and is recorded in **etcd**. Nothing talks to etcd directly except the API server.

Once you see that **every object is just "desired state I handed to a controller,"** the API stops being a pile of unrelated YAML and becomes one pattern applied over and over.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then answer: if you `kubectl delete` a pod that belongs to a ReplicaSet, why does a new one appear almost instantly — and *which part of the one-sentence idea* explains it?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. Three things to hold: **(A) the two-plane architecture, (B) how a pod actually gets created, and (C) what runs the containers (the runtime).**

## (A) The two planes: brain vs muscle

```
        ┌──────────────────────── CONTROL PLANE (the brain) ──────────────────────┐
        │                                                                          │
        │   ┌─────────┐   the ONLY component that talks to etcd                    │
        │   │  etcd   │◀──────────────┐                                            │
        │   │ :2379   │  key-value DB │  (cluster state = single source of truth)  │
        │   └─────────┘               │                                            │
        │                     ▲       │                                            │
        │   ┌─────────────────┴───────┴──────────┐   ┌───────────────┐  ┌─────────┐│
        │   │      kube-apiserver  :6443          │◀──│ kube-scheduler│  │  kube-  ││
        │   │  (authn → authz → validate → etcd)  │   │ (decides node)│  │controller│
        │   │           THE HUB                   │   └───────────────┘  │ manager ││
        │   └───────────────▲─────────────────────┘                     └─────────┘│
        │                   │  every worker talks ONLY to the API server            │
        └───────────────────┼──────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼──────────────── WORKER NODE (the muscle) ─────────────┐
        │   ┌───────────────┴──────┐   ┌──────────────────┐   ┌──────────────────┐  │
        │   │  kubelet  :10250     │   │  kube-proxy      │   │ container runtime│  │
        │   │ (captain: runs pods) │   │ (svc → iptables) │   │ (containerd/CRI-O)│ │
        │   └──────────────────────┘   └──────────────────┘   └──────────────────┘  │
        │            └───────────── pods (your containers) ─────────────┘            │
        └───────────────────────────────────────────────────────────────────────────┘
```

The **control plane** decides and records; the **worker nodes** run the containers. The single most important structural fact: **everything flows through the API server, and only the API server touches etcd.** Analogy: worker nodes are cargo ships carrying containers; the control plane is the fleet of control ships directing them.

**Control-plane components (memorize the ports — the exam asks):**

| Component | Role | Port | Where it lives (kubeadm) |
|---|---|---|---|
| **etcd** | Distributed key-value store; single source of truth for *all* state | `2379` client / `2380` peer | static pod `kube-system` |
| **kube-apiserver** | The hub — authenticates, validates, reads/writes etcd. **Only thing that talks to etcd.** | `6443` | static pod `kube-system` |
| **kube-scheduler** | *Decides* which node a pod goes on (it does **not** place it) | `10259` | static pod `kube-system` |
| **kube-controller-manager** | Runs all controllers (node, replication…) — the reconciliation engine | `10257` | static pod `kube-system` |
| **cloud-controller-manager** | Integrates with the cloud (LBs, nodes) | — | static pod (cloud) |

**Worker-node components:**

| Component | Role | Port | Deployed how |
|---|---|---|---|
| **kubelet** | The captain — registers the node, runs/monitors pods via the runtime, reports to the API server | `10250` | ⚠️ **NOT a pod** — a **systemd service** you install per node |
| **kube-proxy** | Programs iptables/IPVS so Services route to pods | — | **DaemonSet** (one per node) |
| **container runtime** | Actually runs containers (containerd, CRI-O) | — | installed on every node |

> 🎯 **CKA tip:** The most-tested architecture fact — **kubeadm runs the control plane as *static pods*** whose manifests live at `/etc/kubernetes/manifests/`. Edit a manifest and the kubelet auto-restarts that component. **The kubelet itself is a systemd service** (`systemctl status kubelet`), never a pod — which is why a broken kubelet can't self-heal.

## (B) The golden flow: what actually happens on `kubectl create`

This is the machinery in motion — the reconcile loop from Rung 2, concretely:

```
kubectl create/apply
   └─▶ kube-apiserver:  authn → authz → validate → write "Pod (node: none)" to etcd → reply OK
          └─▶ kube-scheduler (watching): sees an unscheduled pod → filters+scores nodes → tells apiserver
                 └─▶ apiserver writes the node assignment to etcd
                        └─▶ kubelet on that node (watching apiserver): sees a pod bound to it
                               └─▶ tells the container runtime to pull the image + start the container
                                      └─▶ kubelet reports status back → apiserver → etcd
```

Every change in Kubernetes follows this shape: **write desired state → a controller notices the gap → it acts → the new actual state is recorded.** The API server is the center; etcd is the memory; nobody skips the hub.

## (C) The runtime & CRI — what "runs the container"

Kubernetes was born coupled to Docker, then introduced the **CRI (Container Runtime Interface)** so *any* OCI-compliant runtime works. Docker predated CRI, so K8s used a shim (**dockershim**) — **removed in v1.24**. Docker is no longer a *runtime*, but Docker-*built images* still run (they follow the OCI image spec).

The three CLIs people confuse:

| Tool | From | Talks to | Purpose |
|---|---|---|---|
| `ctr` | containerd | containerd only | low-level **debug only**, unfriendly — ignore |
| `nerdctl` | containerd | containerd | **Docker-like general CLI** (drop-in for `docker`) |
| **`crictl`** | Kubernetes | *any* CRI runtime | **debug pods/containers on a node** — the one CKA cares about |

```bash
# On a node, when kubectl isn't enough (e.g. API server down):
crictl ps                 # running containers (like docker ps)
crictl pods               # pod sandboxes
crictl logs <container>   # container logs
crictl images             # images
# crictl reads /etc/crictl.yaml for its runtime-endpoint
```

And **etcd**, the memory: a schema-free key-value store holding *everything* (nodes, pods, secrets, roles) under keys like `/registry/<resource>/<namespace>/<name>`. `kubectl get` is just reading etcd through the API server; a change is "real" only once etcd has it. (v3 API uses `put`/`get`/`del`; backup/restore is [Section 5](05-cluster-maintenance.md).)

> **✅ Check yourself before Rung 4:** Draw the two-plane picture from memory, then trace `kubectl run nginx`: (1) which component writes to etcd? (2) which one picks the node, and does it *place* the pod or just *decide*? (3) which one actually starts the container? (4) if the scheduler is down, what state does the pod get stuck in?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery above*

Now the jargon has somewhere to land. Every term is just a label for a part of the picture you already hold.

| Term | What it actually is | Which part of the machinery |
|---|---|---|
| **Pod** | Smallest deployable unit; wraps 1+ tightly-coupled containers sharing network + storage | What the kubelet runs on a node |
| **Label** | A key=value tag on an object | How selectors find things |
| **Selector** | A label query (`app=web`) | How Services/ReplicaSets pick their pods |
| **ReplicaSet** | Controller keeping *N* pod copies alive | The reconcile loop for pod count |
| **Deployment** | Controller managing ReplicaSets (adds rollout/rollback) | Sits above the RS |
| **Service** | Stable virtual IP + name load-balancing across pods | Programmed into nodes by kube-proxy |
| **Endpoints** | The actual pod IPs currently behind a Service | Proof the selector matched something |
| **ClusterIP / NodePort / LoadBalancer** | Service *scopes*: internal / node-port / cloud-LB | Where traffic can enter |
| **Namespace** | A virtual cluster for scoping names + policies | A partition of etcd's object tree |
| **kubelet** | Node agent that runs/reports pods | Worker node, systemd service |
| **kube-proxy** | Turns Services into iptables/IPVS rules | Worker node, DaemonSet |
| **etcd** | The key-value store of all state | Control plane, single source of truth |
| **kube-apiserver** | The hub every request flows through | Control plane, only etcd-talker |
| **kube-scheduler** | Decides pod → node | Control plane |
| **kube-controller-manager** | Houses all reconcile controllers | Control plane |
| **CRI / containerd / crictl** | Runtime interface / runtime / its debug CLI | Worker node, runs containers |

### The big unlock: which terms are the *same kind of thing*

```
GROUP 1 — "The workload hierarchy" (each manages the one below it):
   Deployment ──▶ ReplicaSet ──▶ Pod ──▶ container(s)
   (rollouts)     (N copies)     (unit)   (your app)

GROUP 2 — "Controllers" (all the SAME pattern: watch desired, drive actual):
   ReplicaSet · Deployment · node-controller · every *-controller in the manager

GROUP 3 — "Service discovery" (stable identity for moving pods):
   Service (virtual IP) + Selector (which pods) + Endpoints (the matched IPs)

GROUP 4 — "The control plane" (brain): apiserver + etcd + scheduler + controller-manager
GROUP 5 — "The node" (muscle): kubelet + kube-proxy + container runtime
```

Hold those five groups and you hold the Core Concepts vocabulary. Note **ReplicationController = old ReplicaSet** (same idea, `apiVersion: v1` vs `apps/v1`; the RS *requires* a `selector` and can adopt matching pods).

> **✅ Check yourself before Rung 5:** Without looking — what's the chain of objects between a `Deployment` and a running container, and what does each link add? And: what does an empty **Endpoints** list tell you about a Service?

---

# RUNG 5 — The Trace 🎬
### *Follow ONE concrete action end-to-end*

Let's trace the exact thing the exam makes you do: **`kubectl apply -f deployment.yaml` (3 replicas), then a user hits the Service.** This single trace touches every component.

**Step 1 — kubectl → API server.** Your YAML (a Deployment, `replicas: 3`) is POSTed to `kube-apiserver:6443`. It **authenticates** you (client cert), **authorizes** you (RBAC), **validates** the object, and writes a Deployment to **etcd**. You get "created" back — but nothing is running yet.

**Step 2 — Deployment controller (in controller-manager) notices.** It's watching for Deployments. It sees one with no ReplicaSet and creates a **ReplicaSet** object (via the API server → etcd).

**Step 3 — ReplicaSet controller notices.** Desired = 3, actual = 0. It creates **3 Pod** objects, each with `node: <none>` — written through the API server to etcd.

**Step 4 — Scheduler notices 3 unscheduled pods.** For each: **filter** nodes (enough CPU/RAM? taints tolerated?) then **score** the survivors, pick the best, and tell the API server "bind pod → node." etcd now records each pod's node.

**Step 5 — kubelet on each chosen node notices its pod.** It calls the **container runtime** (via CRI) to pull the image and start the container, sets up the pod's network (CNI), and reports `Running` back → API server → etcd.

**Step 6 — You expose it: `kubectl expose deployment`.** A **Service** (ClusterIP) is created with `selector: app=web`. The **endpoints controller** finds the 3 pods whose labels match and records their IPs as the Service's **Endpoints**.

**Step 7 — A request hits the Service.** kube-proxy on every node has already turned the Service's virtual IP into **iptables/IPVS rules**. A packet to the ClusterIP is DNAT'd to one of the 3 pod IPs (random/round-robin). CoreDNS resolved the Service *name* to that virtual IP first ([Section 8](08-networking.md)).

```
YOU: kubectl apply (Deployment=3)
  │
  ▼
apiserver → etcd  ──▶ Deployment-ctrl ──▶ ReplicaSet ──▶ RS-ctrl ──▶ 3 Pods (node:none)
                                                                        │
                                                              scheduler filters+scores
                                                                        ▼
                                                          3 Pods bound to nodes
                                                                        │
                                                    kubelet → runtime → containers RUNNING
                                                                        │
USER ─▶ Service VIP ─(kube-proxy iptables)─▶ one of the 3 pod IPs ◀─────┘
```

Every hop went through the API server; every fact lives in etcd; every "make it so" was a controller closing a gap.

> **✅ Check yourself before Rung 6:** At Step 4 the scheduler did two distinct things before choosing a node — name them. And at Step 7, which component actually forwards the packet to a pod (not DNS, not the API server)?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

**Kubernetes vs. running containers by hand (Docker / docker-compose):**

```
                        docker / compose            Kubernetes
                        ─────────────────           ──────────────────────
Self-healing:           ❌ you restart it           ✅ controller reconciles
Scaling:                ❌ manual docker run         ✅ change `replicas`
Placement:              ❌ you pick the host         ✅ scheduler picks
Rolling update:         ⚠️ stop-all/start-all        ✅ Deployment does it live
Stable networking:      ❌ IPs change                ✅ Service = fixed VIP + name
Multi-host:             ❌ single host               ✅ whole cluster
```

The pattern in every row: Kubernetes replaces a *manual human action* with a *controller reconciling declared state*. That's not a bag of features — it's the one idea (Rung 2) applied everywhere.

**Imperative vs declarative (the exam mindset):**
- **Imperative** = *tell it how* (`run`, `create`, `expose`, `scale`, `set image`, `edit`, `delete`). Fast, one-off, not tracked.
- **Declarative** = *tell it the desired state* (`kubectl apply -f`). Idempotent (create *or* update), Git-trackable.

**When NOT to use Kubernetes:** a single small app on one box with no availability/scaling needs — the control-plane overhead (etcd, schedulers, a whole cluster to operate) outweighs the benefit. Kubernetes earns its keep when you have *many* services that must stay up, scale, and update safely.

**One-sentence "why this over that":**
> Use Kubernetes when you need containers to self-heal, scale, update safely, and find each other automatically across many hosts; run plain containers when you have one small workload and none of those guarantees matter.

> **✅ Check yourself before Rung 7:** Explain to a colleague *why* docker-compose structurally can't self-heal a crashed container across a spike the way Kubernetes does — not "it lacks the feature," but what architectural piece it's missing. (Hint: is anything *watching desired vs actual* and allowed to act?)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

Here the commands finally arrive — reframed. Each is a **hypothesis you commit to first**, then verify. That single habit converts "I typed the command" into "I understand the system." First, the exam speed kit:

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"     # generate YAML: k run x --image=nginx $do > x.yaml
export now="--force --grace-period=0"     # fast delete
source <(kubectl completion bash); complete -F __start_kubectl k
```

## Prediction 1 — A ReplicaSet self-heals a deleted pod

> **My prediction:** "If I delete one pod owned by a 3-replica Deployment, then a replacement appears within seconds and the count returns to 3 — *because* the ReplicaSet controller is watching desired(3) vs actual, and a delete just widens the gap it exists to close."

```bash
k create deployment web --image=nginx --replicas=3
k get pods -l app=web                    # 3 Running
k delete pod <one-pod-name>              # kill one
k get pods -l app=web -w                 # watch
```

**Verify:** a new pod is created almost immediately; you end back at 3. If it *stays* at 2, your model of "controllers reconcile" needs repair — check the Deployment/RS actually owns those pods (`k get rs`).

## Prediction 2 — `kubectl run` makes a Pod, not a Service

> **My prediction:** "If I `kubectl run nginx --image=nginx --port=80`, then a Pod exists but nothing is reachable from other pods by name — *because* `run` creates only a Pod; a Service is a separate object, and the `--port` flag just declares the container port."

```bash
k run nginx --image=nginx --port=80
k get pod nginx
k get svc                                # nginx is NOT here
```

**Verify:** the Pod exists; `get svc` does not list it. To make it reachable you must `k expose pod nginx --port=80`. If you expected a Service, repair: `run` = Pod only.

## Prediction 3 — A selector/label mismatch = empty Endpoints = dead Service

> **My prediction:** "If a Service's `selector` doesn't match any pod's `labels`, then `describe svc` shows `Endpoints: <none>` and curling it fails — *because* the endpoints controller found no matching pods, so kube-proxy has nothing to forward to."

```bash
k create deployment web --image=nginx      # pods get label app=web
k expose deployment web --port=80          # selector app=web → MATCHES → endpoints populate
k describe svc web | grep Endpoints        # 1+ pod IPs
# now break it on purpose:
k patch svc web -p '{"spec":{"selector":{"app":"nope"}}}'
k describe svc web | grep Endpoints        # <none>
```

**Verify:** endpoints go from populated → `<none>` the instant the selector stops matching. This is the #1 real "my Service doesn't work" cause — and a classic [Section 13](13-troubleshooting.md) task.

## Prediction 4 — Cross-namespace needs the FQDN

> **My prediction:** "If a pod in namespace `marketing` looks up a Service `db-service` that lives in `dev`, then the short name fails but `db-service.dev.svc.cluster.local` resolves — *because* the short name only searches the pod's *own* namespace; crossing namespaces requires the fully-qualified DNS name."

```bash
k create ns dev; k run redis --image=redis -n dev
k expose pod redis --name=db-service --port=6379 -n dev
k run test --image=busybox -n default -it --rm -- \
  sh -c 'nslookup db-service.dev.svc.cluster.local'
```

**Verify:** the FQDN resolves to the `dev` service's ClusterIP; the bare `db-service` would only resolve one in `default`. If both fail, CoreDNS may be down ([Section 8](08-networking.md)).

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Kubernetes is a control plane of reconciling controllers, fronted by one API server backed by etcd, that drives worker-node kubelets to run your declared Pods and stitches them together with label-selected Services.

**Explain it to a beginner in 3 sentences:**
> 1. You describe what you want (3 copies of my app, reachable at a stable address) as YAML, and hand it to the API server, which records it in etcd.
> 2. Background controllers constantly compare what you asked for against what's actually running and take action to close any gap — that's what makes Kubernetes self-heal and scale.
> 3. Because pods come and go, a Service gives them one stable virtual IP and name (matched by labels), so other apps never chase a moving target.

**Which rung will I most likely need to revisit hands-on?**
- **Rung 3B (the golden create-flow)** — under exam pressure people forget *which* component does what. Fix: run `k get events -A -w` while creating a Deployment and literally watch the hops.
- **Rung 4 (selectors/endpoints)** — the label↔selector↔endpoints chain trips people. Fix: do Prediction 3 twice.

---

## 🎯 CKA exam tips & quick notes (this section)

- **Set the speed aliases first thing** (`k`, `$do`, `$now`, completion) — worth minutes over the exam.
- **Always generate YAML, never type it:** `k run/create ... $do > f.yaml`, edit, `k apply -f`.
- **`kubectl run`** = a **Pod**; **`kubectl create deployment`** = a **Deployment**. Don't mix them up.
- **`--dry-run=client`** = print only; **`--dry-run=server`** = run admission but don't persist.
- Ports cold: apiserver **6443**, etcd **2379/2380**, kubelet **10250**, NodePort **30000–32767**, scheduler **10259**, controller-mgr **10257**.
- **Static pods** live in `/etc/kubernetes/manifests/`; the **kubelet is a systemd service**, not a pod.
- `Endpoints: <none>` ⇒ selector/label mismatch. `k describe` + `k get events` are your universal recon.
- `kubectl explain <res> --recursive` beats opening the docs when you forget a field.

## 📌 Imperative command cheat sheet
```bash
# PODS
k run nginx --image=nginx                              # create a pod
k run nginx --image=nginx $do > pod.yaml               # generate pod YAML
k run tmp --image=busybox -it --rm -- sh               # throwaway debug pod
# DEPLOYMENTS
k create deployment web --image=nginx --replicas=3
k scale deployment web --replicas=5
k set image deployment/web nginx=nginx:1.26            # rolling image update
# SERVICES  (expose = auto-selector | create service = manual)
k expose deployment web --port=80 --type=NodePort
k expose pod redis --port=6379 --name=redis-service
# NAMESPACES
k create namespace dev
k config set-context --current --namespace=dev
# EDIT / REPLACE / DELETE
k edit deployment web                                  # live edit (NOT saved to file)
k replace --force -f pod.yaml                          # recreate (immutable-field change)
k delete pod nginx --force --grace-period=0
# INTROSPECTION
k get all -A ; k describe <res> <name> ; k explain <res> --recursive ; k api-resources
```

---

## Related sections

- [Section 2 — Scheduling](02-scheduling.md) — how the scheduler (Rung 3/5) picks nodes: taints, affinity, resources.
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — rollouts/rollback the Deployment adds on the RS.
- [Section 8 — Networking](08-networking.md) — Services, kube-proxy, CNI and cluster DNS in depth.
- [Section 6 — Security](06-security.md) — how the API server authenticates/authorizes every request in the trace.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — `crictl`, `describe`, endpoints when the machinery breaks.
- [../../Linux/13-namespaces.md](../../Linux/13-namespaces.md) — the Linux namespaces/cgroups a Pod is really built from.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Name three things a bare container runtime can't do for you in production that forced an orchestrator to be invented.

**A:** (1) **Self-healing** — when a container dies at 3 AM, nothing restarts it; it stays dead until a human notices. (2) **Scaling** — when traffic spikes, nobody starts more copies; you'd have to SSH in and `docker run` more by hand and wire up a load balancer yourself. (3) **Stable networking** — container IPs are ephemeral, so when a container restarts with a new IP, everything hard-coded to the old one breaks. (Placement decisions and zero-downtime rolling updates are two more valid answers from the same list.)

### Before Rung 3
**Q:** Say the one-sentence idea from memory. Then: if you `kubectl delete` a pod that belongs to a ReplicaSet, why does a new one appear almost instantly — and which part of the sentence explains it?

**A:** The sentence: **Kubernetes is a set of controllers that continuously reconcile the cluster's actual state toward the desired state you declare, with the API server + etcd as the single hub and source of truth.** A new pod appears because the ReplicaSet controller is continuously watching desired (e.g. 3 replicas) vs actual; deleting a pod just widens the gap (actual = 2), and the controller exists to close that gap, so it immediately creates a replacement. The part of the sentence that explains it is *"controllers continuously reconcile the actual state toward the desired state"* — self-healing is not a separate feature, it's the reconcile loop doing its only job.

### Before Rung 4
**Q:** Draw the two-plane picture, then trace `kubectl run nginx`: (1) which component writes to etcd? (2) which one picks the node — does it place the pod or just decide? (3) which one actually starts the container? (4) if the scheduler is down, what state is the pod stuck in?

**A:** The picture: a **control plane** (brain) holding etcd :2379, kube-apiserver :6443 as THE HUB, kube-scheduler :10259 and kube-controller-manager :10257, and **worker nodes** (muscle) each running the kubelet :10250, kube-proxy, and a container runtime — everything flows through the API server, and only the API server touches etcd. The trace: (1) **kube-apiserver** is the only component that writes to etcd — it authenticates, authorizes, validates, then records "Pod (node: none)". (2) The **kube-scheduler** picks the node, and it only *decides* — it tells the API server the binding, which is written to etcd; it never places anything itself. (3) The **kubelet** on the chosen node, watching the API server, sees the pod bound to it and tells the **container runtime** (via CRI) to pull the image and start the container. (4) With the scheduler down, the pod sits unscheduled with no node assignment — stuck in **Pending**.

### Before Rung 5
**Q:** What's the chain of objects between a Deployment and a running container, and what does each link add? What does an empty Endpoints list tell you about a Service?

**A:** The chain is **Deployment → ReplicaSet → Pod → container(s)**. The Deployment adds rollouts and rollback (it manages ReplicaSets); the ReplicaSet adds the reconcile loop that keeps N pod copies alive; the Pod is the smallest deployable unit, wrapping one or more tightly-coupled containers that share network and storage; the containers are your actual app. An empty **Endpoints** list (`Endpoints: <none>`) tells you the Service's selector matched no pod labels — the endpoints controller found nothing, so kube-proxy has nothing to forward to and the Service is effectively dead. It's the #1 cause of "my Service doesn't work."

### Before Rung 6
**Q:** At Step 4 the scheduler did two distinct things before choosing a node — name them. And at Step 7, which component actually forwards the packet to a pod?

**A:** The scheduler first **filters** the nodes (does the node have enough CPU/RAM? are its taints tolerated?) and then **scores** the survivors, binding the pod to the best-scoring node. At Step 7 the component that actually forwards the packet is **kube-proxy** — or more precisely the **iptables/IPVS rules** kube-proxy has programmed on every node, which DNAT a packet sent to the Service's ClusterIP to one of the matching pod IPs. CoreDNS only resolves the Service name to the virtual IP, and the API server isn't in the data path at all.

### Before Rung 7
**Q:** Explain why docker-compose structurally can't self-heal a crashed container the way Kubernetes does — what architectural piece is it missing?

**A:** docker-compose is purely imperative: it starts what you told it to start and then nothing is left running that compares "what should exist" against "what does exist." Kubernetes has a **control loop** — a controller (backed by desired state recorded in the API server/etcd) that continuously watches desired vs actual and is *allowed to act* to close any gap. Compose has no reconciling controller, no stored desired state to reconcile against, and no watch mechanism, so a crashed container just stays crashed and a traffic spike changes nothing. It's not a missing feature toggle; it's the absence of the entire declare-watch-reconcile architecture that Rung 2's one sentence describes.
