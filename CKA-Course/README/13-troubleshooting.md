# Troubleshooting, Climbed the Ladder 🪜
### Section 13 of the CKA — deriving a method so you never guess

> The exam's highest-value skill (**30% of the CKA**): given a broken cluster, find and fix the fault — across **application**, **control-plane**, **worker-node**, and **network** failures. We climb from **the pain of guessing under a clock** → **the "walk the path until a check fails" idea** → **the four checklists** → then real diagnoses as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** A repeatable diagnostic method — and the four fixed checklists (app / control-plane / node / network) that turn "something's broken" into a fast, ordered hunt.

**Why did it land on my desk?** Troubleshooting is the **single largest CKA domain at 30%**, and it's where a method beats knowledge: the same commands, applied in the right order, crack almost every broken-cluster task.

**What do I already know?** Probably `kubectl describe` and `logs`. What's fuzzy: *which* to reach for first, how to read a symptom to the right layer, and what to do when `kubectl` itself is dead.

---

# RUNG 1 — The Pain 🔥
### *Why does a troubleshooting method exist at all?*

You're handed a broken cluster and a 2-hour clock. Without a method:

```
GUESSING UNDER PRESSURE (the pain)
  change a random field → didn't help → change another → now TWO things are wrong
  read the wrong logs   → the real error was in the PREVIOUS container
  fix the app           → but the fault was the control plane the whole time
  20 minutes gone, cluster more broken than before
```

**Before / without a method:** you poke at whatever's nearest, make changes you can't reason about, and lose track of what you've touched — the worst way to debug against a clock.

**What breaks without it:** *time* (the exam's scarcest resource) and *reversibility* (undisciplined changes compound the fault).

**Who feels it most?** You, in the exam — and every on-call engineer at 3 AM.

> **✅ Check yourself before Rung 2:** Why is "start changing things and see what helps" a losing strategy on a timed, multi-fault cluster? What does it cost you beyond time?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Troubleshooting is walking the path a request (or a control-signal) takes, hop by hop, until a check fails — the **symptom localizes the layer** (application / control-plane / worker-node / network), and each layer has a **fixed checklist**, so you diagnose by elimination instead of guessing.**

Derivations:
- *"walk the path hop by hop"* → for an app: `user → Service → Pod → backend Service → Pod`; check each link (endpoints, ports, logs) until one fails.
- *"the symptom localizes the layer"* → **Pending** pod ⇒ scheduler; **no scaling/self-heal** ⇒ controller-manager; **`kubectl` dead** ⇒ apiserver/etcd; **node NotReady** ⇒ kubelet; **DNS/connectivity** ⇒ CNI/kube-proxy/CoreDNS.
- *"each layer has a fixed checklist"* → you don't invent steps under pressure; you run the layer's list.
- *"diagnose by elimination"* → every check either clears a hop or names the fault — no wasted moves.

The golden rule: **draw the map, then walk every link.**

> **✅ Check yourself before Rung 3:** Match symptom → layer: (a) pods stuck Pending, (b) `kubectl` returns connection refused, (c) node shows NotReady, (d) `Endpoints: <none>` on a Service.

---

# RUNG 3 — The Machinery ⚙️
### *The four checklists — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of a detective investigating a building where "something is wrong," ruling out suspects floor by floor. There are four floors — the app, the management office, the worker rooms, and the phone system — and each floor has its own fixed checklist, so you never guess.
>
> - **(A) The app floor: follow the customer's path.** A customer's request travels a known route: front door → receptionist → the app itself → its assistant → the filing room (database). You check each handoff in order until one fails. The classic culprits are all mix-ups: the receptionist's contact list points at nobody (the **Service** — the internal switchboard — has labels that don't match any app, so its list of destinations is empty); someone wrote down the wrong department name; the call is forwarded to the wrong extension (port number); or the database password on file is wrong. When a program keeps crashing over and over, the crucial trick is reading the *previous* attempt's diary (logs), because the current one hasn't failed yet.
>
> - **(B) The management office: the symptom names the culprit.** Kubernetes has a few manager programs, and each failure style points at exactly one. New work sits waiting and never gets assigned to a room? The **scheduler** (the room-assigner) is down. Nothing scales up or heals itself? The **controller manager** (the supervisor who notices gaps and fills them) is down. Your own command tool won't connect at all? The **API server** (the front desk everything talks through) is down. Twist: if the front desk is dead, your usual tool is blind — so you use a backstage tool (`crictl`) that talks directly to the machinery running the programs. The managers are started from plain instruction files in one folder; fix a typo in the file and the manager restarts itself automatically.
>
> - **(C) The worker rooms: go there in person.** If a whole machine reports "NotReady," check its status report first, then walk to the machine itself (log in remotely) and interrogate its caretaker program, the **kubelet**: Is it even running? What do its diary entries (system logs) say? Its mistakes live in one of exactly two settings files — one governing *how it behaves*, one holding *the address it uses to phone headquarters* — and the error message tells you which file to open.
>
> - **(D) The phone system: three suspects only.** Network trouble comes down to a trio: the wiring installer that gives every app an internal number (the CNI), the call-router that forwards switchboard calls to the right app (kube-proxy), and the phone book that turns names into numbers (CoreDNS, the cluster's directory service). Everything unreachable right after setup? Wiring never installed. Name lookups failing everywhere? Phone book down. Apps fine but the switchboard number dead? Call-router.
>
> Method over memory: match the symptom to the floor, then run that floor's checklist top to bottom.

*Now the original technical deep-dive — the same ideas, in precise form:*

## (A) Application failure — walk the request map

```
user ──▶ web Service (NodePort) ──▶ web Pod ──▶ db Service ──▶ db Pod
         └── check each hop, both directions ──┘
```
```bash
curl http://<node-ip>:<nodePort>            # 1) reach the app
kubectl describe svc web-service            # 2) Endpoints: <none> = selector/label MISMATCH
kubectl get pods                            # 3) STATUS + RESTARTS
kubectl describe pod <pod>                  #    Events (scheduling/pull/probe)
kubectl logs <pod> --previous               # 4) the CRASHED container (CrashLoopBackOff)
kubectl describe deploy <deploy>            # 5) env: DB_HOST / DB_USER / DB_PASSWORD
```
**The classic app faults:**
| Symptom | Root cause | Fix |
|---|---|---|
| `Endpoints: <none>` | Service **selector** ≠ pod **labels** | fix the selector |
| "name does not resolve" | wrong **Service name** (e.g. `mysql` vs `mysql-service`) | rename / fix env |
| "connection refused" | Service **targetPort** ≠ container port (8080 vs 3306) | fix `targetPort` |
| "access denied" | wrong **DB user/password** env | fix env / secret |
| timeout on the node port | wrong **nodePort** | fix `nodePort` |
> 🎯 Set the namespace once: `kubectl config set-context --current --namespace=<ns>`. Immutable field edit → `kubectl replace --force -f`.

## (B) Control-plane failure — symptom names the component

Control-plane components are **static pods**. The symptom tells you which:
| Symptom | Broken component |
|---|---|
| pods stuck **Pending** (`Node: <none>`) | **kube-scheduler** |
| scaling / self-heal / new ReplicaSets don't happen | **kube-controller-manager** |
| `kubectl` itself fails ("connection refused") | **kube-apiserver** (or etcd) |
```bash
kubectl get nodes ; kubectl get pods -n kube-system
kubectl describe pod kube-scheduler-controlplane -n kube-system   # Events + Last State
kubectl logs kube-controller-manager-controlplane -n kube-system
# if kubectl is DOWN (apiserver broken), use the runtime directly:
crictl ps -a | grep apiserver ; crictl logs <container-id>
ls /etc/kubernetes/manifests/               # fix the YAML → kubelet auto-restarts
```
**Common breaks (in `/etc/kubernetes/manifests/*.yaml`):** wrong `command`/args (`executable file not found`), wrong file path (`no such file or directory`), wrong volume `hostPath` (`unable to load client CA file`).
> 🎯 Editing a static-pod manifest **restarts that component** (kubectl may blip ~30–60s). When kubectl is fully dead, **`crictl ps -a` + `crictl logs`** are your eyes.

## (C) Worker-node failure — nodes → conditions → kubelet

```bash
kubectl get nodes                           # NotReady?
kubectl describe node node01                # Conditions: Memory/Disk/PIDPressure, Ready=Unknown
```
`Ready=Unknown` + stale heartbeat = the kubelet stopped talking to the API server. Go **onto the node**:
```bash
ssh node01
systemctl status kubelet                    # active? inactive? activating(exit 255)?
sudo systemctl start kubelet                # or restart
journalctl -u kubelet -f                    # the real error
```
| Log message | Cause | Fix location |
|---|---|---|
| kubelet `inactive (dead)` | just stopped | `systemctl start kubelet` |
| `unable to load client CA file … no such file` | wrong `clientCAFile` | **`/var/lib/kubelet/config.yaml`** |
| `connection refused` to apiserver `:6553` | wrong apiserver port | **`/etc/kubernetes/kubelet.conf`** (should be `:6443`) |
> 🎯 Two kubelet configs: **`/var/lib/kubelet/config.yaml`** (behavior — `clientCAFile`, `staticPodPath`) and **`/etc/kubernetes/kubelet.conf`** (the kubeconfig — apiserver address:port). Start at `kubectl get nodes`, then SSH and check **service → logs → config**.

## (D) Network failure — the kube-system trio

```bash
kubectl get pods -n kube-system              # CNI DaemonSet, kube-proxy, coredns all Running?
kubectl logs -n kube-system <kube-proxy-pod> # proxy mode / errors
kubectl exec <pod> -- nslookup <svc>.<ns>    # DNS working? CoreDNS up?
```
- **NotReady right after install** → CNI not deployed (`kubectl apply -f <addon>`).
- **DNS failing cluster-wide** → CoreDNS down/misconfigured.
- **Service unreachable, pods fine** → kube-proxy issue.

> **✅ Check yourself before Rung 4:** A Service returns `Endpoints: <none>`. Which layer, which single check confirms it, and what's the root cause? And if `kubectl` itself won't respond — what tool replaces it?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which layer |
|---|---|---|
| **Endpoints** | The pod IPs behind a Service | App (selector match) |
| **selector / labels** | Service's pod query / pod tags | App |
| **targetPort** | The pod port a Service forwards to | App |
| **CrashLoopBackOff / ImagePullBackOff** | Container keeps crashing / can't pull | App |
| **`logs --previous`** | The crashed container's logs | App |
| **static-pod manifest** | Control-plane pod YAML in `/etc/kubernetes/manifests` | Control plane |
| **crictl** | Runtime CLI when kubectl is dead | Control plane |
| **node Conditions** | Ready / *Pressure flags | Node |
| **kubelet / journalctl** | Node agent / its logs | Node |
| **kubelet.conf / config.yaml** | kubeconfig / behavior config | Node |
| **CNI / kube-proxy / CoreDNS** | Pod net / service net / DNS | Network |

**The unlock — symptom → layer → checklist:**
```
app error (curl fails)        → APP:      map → endpoints → ports → logs --previous → env
Pending / no-scaling / no-API → CONTROL:  get pods -n kube-system → logs/crictl → fix manifest
node NotReady                 → NODE:      describe node → kubelet service → journalctl → config
DNS / connectivity            → NETWORK:   kube-system trio (CNI/kube-proxy/CoreDNS)
```

> **✅ Check yourself before Rung 5:** Which layer's checklist starts with `kubectl get pods -n kube-system`, and which starts with `kubectl describe node`?

---

# RUNG 5 — The Trace 🎬
### *Follow ONE real diagnosis end-to-end*

**Trace — "the app shows a database connection error":**
1. **Reach it:** `curl -s localhost:30081 | grep -i error` → "Can't connect to `mysql-service` … name does not resolve." That's an **app-layer** symptom pointing at the db hop.
2. **Walk the map to the db Service:** `kubectl get svc` → the actual service is named **`mysql`**, but the app is configured for `mysql-service`. Mismatch found at the name hop.
3. **Decide the fix:** either rename the Service to `mysql-service` or point the app's `DB_HOST` env at `mysql`. (If instead the name resolved but connection *refused*, you'd check `describe svc` for `Endpoints`/`targetPort`; if *access denied*, the DB creds env.)
4. **Apply + verify:** fix, then re-`curl` → the page turns green. One hop identified, one change, verified.

```
curl → error names the failing hop (db name) → get svc (name mismatch)
     → fix name/env → curl again → SUCCESS
```

The discipline: each command either **cleared a hop** (front-end reachable) or **named the fault** (wrong service name) — no random edits.

> **✅ Check yourself before Rung 6:** In this trace, what told you the fault was at the *db* hop and not the web hop? What would `Endpoints: <none>` have pointed to instead of a name mismatch?

---

# RUNG 6 — The Contrast ⚖️

| Symptom… | vs… | Tells you |
|---|---|---|
| **Pending** pod (`Node: <none>`) | **NotReady** node | scheduler down vs kubelet down |
| **no scaling / self-heal** | **Pending** | controller-manager vs scheduler |
| **`kubectl` connection refused** | **app curl fails** | apiserver/etcd vs application |
| **`kubectl logs`** | **`kubectl describe`** | app errors (stdout) vs Events/Last State (scheduling/runtime) |
| **`kubectl`** | **`crictl`** | works when API is up vs the fallback when it's down |
| **`config.yaml`** | **`kubelet.conf`** | kubelet behavior vs its apiserver connection |

**When to use each tool:** `describe` first (Events explain most failures); `logs --previous` for crash loops; `crictl` only when the API is unreachable; SSH + `journalctl` for node/kubelet faults.

**One-sentence "why this over that":**
> Read the symptom to the layer, then run that layer's checklist top-to-bottom — the map for apps, `kube-system` static pods for the control plane, the kubelet service for nodes, and the CNI/kube-proxy/CoreDNS trio for networking.

> **✅ Check yourself before Rung 7:** Two clusters: one has pods stuck Pending; the other can't scale a Deployment. Different control-plane component each — name them.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — App failure: the map leads straight to the broken Service

> **My prediction:** "If the app shows a DB error, then walking the map (curl → service name/endpoints/targetPort → env) finds one broken link, and fixing it turns the page green — *because* the fault is one hop in a known chain."

```bash
kubectl config set-context --current --namespace=alpha
curl -s localhost:30081 | grep -i error       # names the failing hop
kubectl get svc ; kubectl describe svc mysql-service   # name/selector/endpoints/targetPort
# fix the name/selector/port/env, then:
curl -s localhost:30081                        # SUCCESS
```
**Verify:** the page turns green after one targeted fix. Walk the map in order — don't skip to guessing.

## Prediction 2 — Pending pods ⇒ scheduler; the fix is in its manifest

> **My prediction:** "If a pod is Pending with `Node: <none>` and the scheduler pod is CrashLoopBackOff, then `describe` shows a bad command in `kube-scheduler.yaml`, and fixing the manifest reschedules the pod — *because* Pending = nothing is assigning nodes."

```bash
kubectl get pods                               # app pod Pending, Node: <none>
kubectl get pods -n kube-system                # kube-scheduler-controlplane CrashLoopBackOff
kubectl describe pod kube-scheduler-controlplane -n kube-system   # "executable file not found"
sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml   # fix the mangled command
kubectl get pods                               # pod schedules → Running
```
**Verify:** scheduler returns to Running, the Pending pod gets a node. `Pending + Node: <none>` ⇒ scheduler.

## Prediction 3 — Worker NotReady ⇒ kubelet; the log names the file

> **My prediction:** "If a node is NotReady and its kubelet is failing on a CA file, then `journalctl` names the exact bad path in `/var/lib/kubelet/config.yaml`, and fixing it + restarting kubelet returns the node to Ready — *because* the kubelet is the node's agent."

```bash
kubectl get nodes                              # node01 NotReady
ssh node01
sudo systemctl status kubelet                  # activating (exit 255)
sudo journalctl -u kubelet | tail              # "unable to load client CA file … /WRONG-ca"
sudo vi /var/lib/kubelet/config.yaml           # fix clientCAFile → /etc/kubernetes/pki/ca.crt
sudo systemctl restart kubelet
exit; kubectl get nodes                        # node01 Ready
```
**Verify:** kubelet goes `active (running)`, node returns Ready. The error message names the exact file to fix.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Read the symptom to a layer (app / control-plane / node / network), then walk that layer's fixed checklist hop by hop — map→endpoints→logs for apps, `kube-system` static pods (with crictl as backup) for the control plane, kubelet service→logs→config for nodes, and the CNI/kube-proxy/CoreDNS trio for networking — fixing the one link that fails.

**Explain it to a beginner in 3 sentences:**
> 1. Don't guess — figure out which layer is broken from the symptom (a Pending pod is the scheduler; a NotReady node is the kubelet; a failing app is the request path).
> 2. Then follow that layer's checklist step by step until a check fails: for an app, trace user → service → pod → database, checking endpoints, ports, logs, and env at each hop.
> 3. When `kubectl` itself is down, use `crictl` on the node to read the control-plane containers' logs, and fix the static-pod manifest they came from.

**Which rung to revisit hands-on?**
- **Rung 3A (the app map)** — `Endpoints: <none>` and the name/targetPort faults are the most common tasks. Fix: Prediction 1, twice.
- **Rung 3B/C (crictl + kubelet configs)** — the "kubectl is dead" and "which kubelet file" moments. Fix: Predictions 2 and 3 on a real node.

---

## 🎯 CKA exam tips & quick notes

- **Draw the map, walk every link.** `Endpoints: <none>` = Service↔Pod mismatch (selector/ports), then pod status/logs.
- **`kubectl logs --previous`** for `CrashLoopBackOff`; **`kubectl describe`** for Events.
- **Control plane** = static pods in `/etc/kubernetes/manifests/`; symptom→component (Pending=scheduler, no-scaling=controller-manager, kubectl-dead=apiserver/etcd). kubectl down → **`crictl ps -a` / `crictl logs`**; fix the manifest (command/path/`hostPath`).
- **Worker node** = `get nodes` → `describe node` (Conditions) → SSH → **kubelet service → journalctl → config** (`/var/lib/kubelet/config.yaml`, `/etc/kubernetes/kubelet.conf` apiserver `:6443`).
- **Network** = CNI/kube-proxy/CoreDNS in `kube-system`; NotReady after install = deploy a CNI.
- Set the namespace once; `alias k=kubectl` + completion to save time.

## 📌 Command cheat sheet
```bash
# APP
kubectl describe svc <svc>         # Endpoints? selector?
kubectl logs <pod> --previous      # crashed container
kubectl get pods -o wide           # pod IPs / nodes
# CONTROL PLANE
kubectl get pods -n kube-system
kubectl logs <cp-pod> -n kube-system   |   crictl ps -a ; crictl logs <id>
ls /etc/kubernetes/manifests/
# WORKER NODE
kubectl describe node <node>       # Conditions
systemctl status kubelet ; journalctl -u kubelet -f
# fix: /var/lib/kubelet/config.yaml  |  /etc/kubernetes/kubelet.conf
```

---

## Related sections

- [Section 1 — Core Concepts](01-core-concepts.md) — the object map (Service→Pod) you walk.
- [Section 5 — Cluster Maintenance](05-cluster-maintenance.md) — recovering etcd/control plane; node drain.
- [Section 6 — Security](06-security.md) — cert/`crictl` control-plane debugging.
- [Section 8 — Networking](08-networking.md) — CNI/kube-proxy/CoreDNS fault-finding.
- [Section 3 — Logging & Monitoring](03-logging-monitoring.md) — `logs`/`top` as first-line tools.
- [../../Linux/16-systemd-services.md](../../Linux/16-systemd-services.md) — `systemctl`/`journalctl` for kubelet debugging.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why is "start changing things and see what helps" a losing strategy on a timed, multi-fault cluster? What does it cost you beyond time?

**A:** Because random changes aren't reasoned about: you change a field, it doesn't help, you change another — and now two things are wrong instead of one, or you fix the app when the real fault was in the control plane all along. Beyond time (the exam's scarcest resource), it costs you **reversibility**: undisciplined edits compound the fault and you lose track of what you've touched, so the cluster ends up more broken than when you started. A method — walking a fixed checklist by elimination — means every check either clears a hop or names the fault, with no wasted or destructive moves.

### Before Rung 3
**Q:** Match symptom → layer: (a) pods stuck Pending, (b) `kubectl` returns connection refused, (c) node shows NotReady, (d) `Endpoints: <none>` on a Service.

**A:** (a) Pods stuck Pending → control-plane layer, specifically the **kube-scheduler** (nothing is assigning nodes). (b) `kubectl` connection refused → control-plane layer, the **kube-apiserver** (or etcd behind it). (c) Node NotReady → worker-node layer, the **kubelet** (it stopped talking to the API server). (d) `Endpoints: <none>` → application layer: the Service's **selector doesn't match the pod labels**, so no pods back the Service.

### Before Rung 4
**Q:** A Service returns `Endpoints: <none>`. Which layer, which single check confirms it, and what's the root cause? And if `kubectl` itself won't respond — what tool replaces it?

**A:** `Endpoints: <none>` is an **application-layer** fault; the single confirming check is `kubectl describe svc <svc>` — compare the Service's **selector** against the pods' **labels**. The root cause is a selector/label mismatch, so the Service matches zero pods; the fix is to correct the selector. When `kubectl` itself is dead (apiserver broken), you fall back to the container runtime CLI: **`crictl ps -a`** to find the control-plane containers and **`crictl logs <container-id>`** to read their errors, then fix the static-pod YAML in `/etc/kubernetes/manifests/` (the kubelet auto-restarts it).

### Before Rung 5
**Q:** Which layer's checklist starts with `kubectl get pods -n kube-system`, and which starts with `kubectl describe node`?

**A:** The **control-plane** checklist starts with `kubectl get pods -n kube-system` — the control-plane components are static pods there, and the failing one (scheduler, controller-manager, apiserver) shows up immediately. The **worker-node** checklist starts with `kubectl get nodes` then `kubectl describe node <node>` — reading the Conditions (Ready=Unknown, Memory/Disk/PIDPressure) before SSHing in to check the kubelet service, its journalctl logs, and its config files.

### Before Rung 6
**Q:** In this trace, what told you the fault was at the *db* hop and not the web hop? What would `Endpoints: <none>` have pointed to instead of a name mismatch?

**A:** The curl itself succeeded in reaching the front end and returned a page whose error text named the failing hop: "Can't connect to `mysql-service` … name does not resolve" — the web Service and web pod hops were already cleared (the request got through them), and the error explicitly pointed at the database service name. If instead `kubectl describe svc` had shown `Endpoints: <none>`, that would have pointed to a **selector/label mismatch** — the Service exists and resolves, but its selector matches no pod labels, so no pod IPs sit behind it — fixed by correcting the selector rather than the service name or `DB_HOST` env.

### Before Rung 7
**Q:** Two clusters: one has pods stuck Pending; the other can't scale a Deployment. Different control-plane component each — name them.

**A:** Pods stuck Pending (with `Node: <none>`) means the **kube-scheduler** is broken — nothing is assigning pods to nodes. A Deployment that won't scale (no new ReplicaSets, no self-healing) means the **kube-controller-manager** is broken — it runs the controllers that create/scale ReplicaSets and replace pods. Both are static pods in `/etc/kubernetes/manifests/`, so the fix path is the same: `kubectl get pods -n kube-system`, read logs/Events, and repair the component's manifest.
