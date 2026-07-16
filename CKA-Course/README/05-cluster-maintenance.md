# Cluster Maintenance, Climbed the Ladder 🪜
### Section 5 of the CKA — deriving how to change a live cluster without breaking it

> Keeping a running cluster healthy: draining nodes, the version-skew rule, upgrading with kubeadm, and **etcd backup & restore**. The **upgrade** and **etcd restore** tasks are near-guaranteed on the exam. We climb from **the pain of touching a live cluster** → **the "control the blast radius, keep an undo" idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How to safely take a node out for maintenance, upgrade the cluster one version at a time, and back up / restore the one thing that *is* the cluster: etcd.

**Why did it land on my desk?** *Cluster Architecture, Installation & Configuration* is 25% of the CKA, and a **cluster upgrade** and an **etcd restore** are among the most reliably-appearing tasks. These are timed, procedural, and unforgiving — reflex matters.

**What do I already know?** Maybe `kubectl drain`. What's fuzzy: why `kubectl get nodes` shows the *old* version right after an upgrade, and the exact etcd-restore dance (which file to edit, which flags are mandatory).

---

# RUNG 1 — The Pain 🔥
### *Why does cluster maintenance exist at all?*

A cluster is a living system you must change *while it's serving traffic*. Every change is a chance to cause an outage:

```
THE MAINTENANCE PAIN
  patch a node's kernel  ─▶ just reboot it? → every pod on it dies without warning
  upgrade Kubernetes     ─▶ jump 1.27→1.30? → version skew → components refuse to talk
  etcd disk dies         ─▶ no backup?       → the ENTIRE cluster state is gone, no undo
  bad change             ─▶ "roll back?"      → to what? there's no snapshot
```

**Before / without these tools:** you rebooted nodes and hoped controllers noticed; you upgraded blindly and hit skew failures; and if etcd was lost, the cluster was *gone* — every object, every secret, unrecoverable.

**What breaks without it:** availability during maintenance (pods yanked out from under users), upgrade safety (skew breakage), and — the big one — **disaster recovery** (etcd is the single source of truth; lose it, lose everything).

**Who feels it most?** The platform/ops team — you own uptime *through* change, and you're the one restoring etcd at 3 AM.

> **✅ Check yourself before Rung 2:** If a worker node's etcd... wait — where does etcd actually live, and why is losing *it* categorically worse than losing a worker node? (Hint: what is stored where?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Maintenance is about controlling *where disruption lands* and keeping an *undo button*: `drain` moves pods off a node before you touch it, the version-skew rule forces a safe upgrade order (control plane first, one minor at a time), and an etcd snapshot is the only true restore point for all cluster state.**

Derivations:
- *"controlling where disruption lands"* → **cordon/drain** evacuate a node so maintenance hits no live pods; controllers reschedule them elsewhere.
- *"safe upgrade order… control plane first"* → because **nothing may be newer than the API server**, you *must* upgrade it before the kubelets — the skew rule dictates the sequence.
- *"one minor at a time"* → Kubernetes only supports N-2 minors and tested one-step upgrades; skipping breaks things.
- *"an etcd snapshot is the only true restore point"* → your YAML in Git rebuilds *objects*, but only an **etcd snapshot** captures the exact live state (including things created imperatively).

> **✅ Check yourself before Rung 3:** Why do you upgrade the **control plane before** the worker kubelets, never the reverse? State the rule it follows.

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

## (A) Node maintenance — cordon, drain, uncordon

When a node goes `NotReady`, the control plane waits the **pod eviction timeout** (~5 min, on the controller-manager; modern K8s applies a `NoExecute` taint and evicts after a grace period). Then: **ReplicaSet-backed pods are recreated elsewhere; bare pods are gone forever.** To do maintenance *deliberately* rather than by surprise:

| Command | Effect |
|---|---|
| `kubectl cordon <node>` | mark **unschedulable**; existing pods stay |
| `kubectl drain <node>` | evict all pods gracefully **+ cordon** |
| `kubectl uncordon <node>` | make schedulable again |

```bash
kubectl drain node01 --ignore-daemonsets                       # DS pods can't move
kubectl drain node01 --ignore-daemonsets --delete-emptydir-data   # if pods use emptyDir
kubectl drain node01 --ignore-daemonsets --force               # also evict bare pods
# ...maintenance / reboot...
kubectl uncordon node01
```
> 🎯 `drain` **fails** on DaemonSet pods (need `--ignore-daemonsets`), bare pods (`--force`), or `emptyDir` (`--delete-emptydir-data`). Drained pods **do not** come back on `uncordon` — the node just becomes eligible for *new* pods.

## (B) The version-skew rule — why order matters

Version = `major.minor.patch`. Kubernetes supports the **3 latest minors**; **upgrade one minor at a time** (1.27→1.28→1.29). Nothing may be **newer than the API server**:

```
                 kube-apiserver        (X)     ← reference, highest
        ┌───────────────┼───────────────┐
 controller-manager  scheduler        kubectl
      (X-1)            (X-1)       (X-1 … X+1  ← kubectl may be +1)
        │
   kubelet / kube-proxy   (X-2)      ← up to two minors behind
```
This is *why* the control plane upgrades first, then kubelets. During a control-plane upgrade, `kubectl`/API is briefly down but **running workloads keep serving** (kubelets and pods don't stop).

## (C) The kubeadm upgrade flow

kubeadm upgrades the control-plane **static pods**, but **never the kubelet — you do that manually** on every node.

```
per node: bump the pkgs.k8s.io repo to the target minor  →  apt-cache madison kubeadm (find patch)
CONTROL PLANE: apt install kubeadm=<v> → kubeadm upgrade plan → kubeadm upgrade apply <v>
               → drain CP → apt install kubelet kubectl=<v> → systemctl restart kubelet → uncordon
EACH WORKER:   apt install kubeadm=<v> → kubeadm upgrade node   (NOT "apply")
               → drain → apt install kubelet kubectl=<v> → restart kubelet → uncordon
```
> 🎯 After `kubeadm upgrade apply`, `kubectl get nodes` **still shows the old version** — that column is the **kubelet** version, which changes only after you `restart kubelet` (step 4). Extra control-plane nodes use `kubeadm upgrade **node**`, not `apply`.

## (D) etcd backup & restore — the only real undo

etcd holds **all** cluster state. Back it up (snapshot of a *live* etcd), and restore into a *new* data dir.

```bash
# BACKUP — talks to the live etcd (all 4 flags mandatory):
ETCDCTL_API=3 etcdctl snapshot save /opt/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
etcdctl snapshot status /opt/snapshot.db --write-out=table   # inspect

# RESTORE — offline, into a NEW dir, then repoint the manifest:
ETCDCTL_API=3 etcdctl snapshot restore /opt/snapshot.db --data-dir=/var/lib/etcd-from-backup
#   (modern: etcdutl snapshot restore /opt/snapshot.db --data-dir=/var/lib/etcd-from-backup)
sudo vi /etc/kubernetes/manifests/etcd.yaml   # set the etcd-data volume's hostPath → /var/lib/etcd-from-backup
kubectl get pods -A                           # after etcd + apiserver static pods restart
```
> 🎯 In restore you **only edit the etcd manifest's `volumes[].hostPath.path`** (the `etcd-data` volume). The kubelet sees the change and recreates the etcd (and dependent apiserver) static pods. Restore **initializes a brand-new cluster** (new member IDs) on purpose. Get the cert paths/endpoint from `cat /etc/kubernetes/manifests/etcd.yaml`. **`etcdctl`** = live/network (save/status); **`etcdutl`** = offline files (the modern restore) — either works for the exam.

> **✅ Check yourself before Rung 4:** In an etcd restore, which single field in `etcd.yaml` do you change, and why does editing that file cause etcd to restart on its own?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Machinery |
|---|---|---|
| **cordon** | Mark node unschedulable | Node maintenance |
| **drain** | Evict pods + cordon | Node maintenance |
| **uncordon** | Re-enable scheduling | Node maintenance |
| **pod eviction timeout** | Wait before declaring a NotReady node's pods dead | Controller-manager |
| **version skew** | Allowed version gaps between components | Upgrade order |
| **minor / patch** | `1.29` (feature) / `.3` (bugfix) | Versioning |
| **kubeadm upgrade plan/apply/node** | Preview / do (control plane) / do (worker) | Upgrade |
| **static pod** | Control-plane pod kubeadm upgrades | Upgrade target |
| **snapshot save/status/restore** | Backup / inspect / recover etcd | etcd |
| **data-dir** | Where etcd stores its DB | etcd restore |
| **hostPath** | The volume path you repoint on restore | etcd manifest |
| **etcdctl / etcdutl** | Live-cluster CLI / offline-file CLI | etcd |

**The unlock:** three verbs of maintenance — **evacuate** (drain), **advance** (upgrade, skew-ordered), **preserve/recover** (etcd snapshot/restore). All three are about *change with a safety net*.

> **✅ Check yourself before Rung 5:** Which command previews an upgrade without doing it, and which one do you run on a *worker* (hint: not `apply`)?

---

# RUNG 5 — The Trace 🎬

**Trace — upgrade the control plane 1.28 → 1.29:**
1. Bump the `pkgs.k8s.io` repo to `v1.29`, `apt-get update`, `apt-cache madison kubeadm` → pick `1.29.3-1.1`.
2. `apt install kubeadm=1.29.3-1.1`; `kubeadm version` confirms.
3. `kubeadm upgrade plan` shows the path; `kubeadm upgrade apply v1.29.3` upgrades the apiserver/scheduler/controller-manager/etcd **static pods** (kubeadm rewrites their manifests; the kubelet restarts them). API blips; **workloads keep serving**.
4. `kubectl get nodes` still shows **1.28** — because that's the *kubelet* version, unchanged.
5. `kubectl drain controlplane --ignore-daemonsets` (it runs CoreDNS etc.).
6. `apt install kubelet kubectl=1.29.3-1.1`; `systemctl daemon-reload && systemctl restart kubelet`. **Now** `get nodes` flips to 1.29.
7. `kubectl uncordon controlplane`. Repeat the worker flow with `kubeadm upgrade node` per node.

**Trace — etcd disaster recovery:** snapshot save (live) → something wipes state → `snapshot restore --data-dir=<new>` (offline) → edit `etcd.yaml` hostPath → kubelet recreates etcd + apiserver → the objects that existed *at snapshot time* reappear (anything created after the snapshot is gone).

> **✅ Check yourself before Rung 6:** At which exact step does `kubectl get nodes` finally show the new version — and why not earlier?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **cordon** | **drain** | block *new* pods only vs *also evict* existing ones |
| **drain** | **delete node** | temporary, reversible with uncordon vs removes it from the cluster |
| **etcd snapshot** | **config backup (Velero / `get -o yaml`)** | exact full state incl. imperative objects vs declarative objects (+ PVs with Velero) |
| **`kubeadm upgrade apply`** | **`kubeadm upgrade node`** | control-plane primary vs workers / extra control-plane nodes |
| **etcdctl** | **etcdutl** | live etcd over network (save/status) vs offline files (restore/backup) |

**When NOT to:** don't `drain` without `--ignore-daemonsets` (it just errors); don't skip minors on upgrade; don't restore etcd onto the *same* data dir the live etcd is using (repoint to a new dir); don't forget the four etcd TLS flags (the #1 mistake).

**One-sentence "why this over that":**
> Drain to evacuate a node before maintenance, upgrade the control plane first and one minor at a time to respect skew, and rely on an etcd snapshot — not just your YAML — when you need to truly rewind cluster state.

> **✅ Check yourself before Rung 7:** Your teammate says "we keep all manifests in Git, so we don't need etcd backups." Give one thing a Git of manifests would *not* recover that an etcd snapshot would.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — Drain keeps controller-backed apps up

> **My prediction:** "If I drain node01, then its ReplicaSet-backed pods reappear on other nodes and the app stays up, while node01 shows `SchedulingDisabled` — *because* drain evicts + cordons, and controllers reconcile the evicted pods elsewhere."

```bash
kubectl get pods -o wide | grep node01
kubectl drain node01 --ignore-daemonsets --delete-emptydir-data
kubectl get nodes                    # node01 = SchedulingDisabled
# ...patch/reboot...
kubectl uncordon node01
```
**Verify:** RS apps stay served; node01 accepts new pods only after uncordon. A **bare** pod blocks the drain until `--force` (and won't come back — it had no controller).

## Prediction 2 — `get nodes` shows the old version until the kubelet restarts

> **My prediction:** "If I run `kubeadm upgrade apply v1.29.0` but haven't touched the kubelet, then `kubectl get nodes` still says 1.28 — *because* that column reports the kubelet version, and I upgrade+restart the kubelet in a later step."

```bash
sudo apt-get install -y kubeadm=1.29.0-1.1
sudo kubeadm upgrade apply v1.29.0
kubectl get nodes                    # STILL 1.28
sudo apt-get install -y kubelet=1.29.0-1.1 && sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl get nodes                    # NOW 1.29.0
```
**Verify:** the version flips only after the kubelet restart. Surprised? That's the point — the node column ≠ control-plane component versions.

## Prediction 3 — etcd restore rewinds state to the snapshot

> **My prediction:** "If I snapshot etcd, delete some objects, then restore that snapshot and repoint `etcd.yaml`, then the deleted objects reappear — *because* restore rebuilds etcd from the snapshot's point in time."

```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/snap.db \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key
# ...delete a deployment to simulate loss...
ETCDCTL_API=3 etcdctl snapshot restore /opt/snap.db --data-dir=/var/lib/etcd-from-backup
sudo vi /etc/kubernetes/manifests/etcd.yaml    # etcd-data hostPath → /var/lib/etcd-from-backup
watch kubectl get pods -A
```
**Verify:** snapshot-time objects return after etcd+apiserver restart. If `kubectl` hangs, the apiserver is still coming up behind etcd — wait a minute. Post-snapshot changes are (correctly) gone.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Maintain a live cluster by draining nodes before you touch them, upgrading the control plane first and one minor at a time (skew rule), and keeping etcd snapshots as your only true restore point for cluster state.

**Explain it to a beginner in 3 sentences:**
> 1. Before patching a node you `drain` it, which safely moves its pods elsewhere so users aren't affected.
> 2. Upgrades go control-plane-first, one version step at a time, because Kubernetes forbids any component being newer than the API server.
> 3. etcd is the cluster's memory, so you take snapshots of it — restoring one is the only way to truly rewind the whole cluster after a disaster.

**Which rung to revisit hands-on?** Rung 3D + Prediction 3 — the **etcd restore**. It's the single highest-value skill here and the easiest to fumble (wrong flags, wrong field). Do it end-to-end until it's boring.

---

## 🎯 CKA exam tips & quick notes

- **`kubectl drain <node> --ignore-daemonsets`** (+ `--delete-emptydir-data`/`--force` if it complains), then **`uncordon`**. Pods don't auto-return.
- **Upgrade order:** control plane first, one minor at a time — repo bump → `kubeadm=<v>` → `upgrade plan` → `upgrade apply <v>` (CP) / `upgrade node` (workers) → drain → `kubelet kubectl=<v>` → `daemon-reload && restart kubelet` → uncordon.
- `kubectl get nodes` version = **kubelet** → doesn't change until you restart kubelet.
- **etcd:** every command needs `--endpoints --cacert --cert --key` (find them in `etcd.yaml`). save → status → restore `--data-dir=<new>` → repoint the manifest `hostPath`.
- **Skew:** nothing newer than apiserver; kubelet/kube-proxy X-2; kubectl X+1.
- **Drill the etcd restore** end-to-end — highest-value single skill in this section.

## 📌 Command cheat sheet
```bash
# NODE MAINTENANCE
k drain node01 --ignore-daemonsets --delete-emptydir-data
k cordon node01 ; k uncordon node01
# UPGRADE (kubeadm)
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.29.3       # control plane
sudo kubeadm upgrade node                # workers / extra control-plane
sudo apt-get install -y kubelet=1.29.3-1.1 kubectl=1.29.3-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
# ETCD BACKUP / RESTORE
ETCDCTL_API=3 etcdctl snapshot save /opt/snap.db \
  --endpoints=https://127.0.0.1:2379 --cacert=... --cert=... --key=...
etcdctl snapshot status /opt/snap.db --write-out=table
etcdctl snapshot restore /opt/snap.db --data-dir=/var/lib/etcd-from-backup
# then edit /etc/kubernetes/manifests/etcd.yaml hostPath → new dir
```

---

## Related sections

- [Section 9 — Design & Install a Kubernetes Cluster](09-design-and-install-kubernetes-cluster.md) — where etcd/control-plane layout comes from.
- [Section 10 — Install Kubernetes the Kubeadm Way](10-install-kubernetes-kubeadm-way.md) — the tool you upgrade with.
- [Section 6 — Security](06-security.md) — the PKI certs etcd/kubeadm use.
- [Section 1 — Core Concepts](01-core-concepts.md) — etcd's role and static pods.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — recovering when the control plane won't start.
- [../../Linux/16-systemd-services.md](../../Linux/16-systemd-services.md) — the systemd/kubelet service you restart during upgrades.
