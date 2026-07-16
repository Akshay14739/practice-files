# Storage, Climbed the Ladder 🪜
### Section 7 of the CKA — deriving how data outlives a pod

> Persisting data: volumes, **PV/PVC** binding, access modes, reclaim policies, and **StorageClasses**. We climb from **the pain of ephemeral data** → **the one "claim, don't name the disk" idea** → **the binding machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How a pod gets storage that survives its death, and how admins/StorageClasses supply that storage without every pod hard-coding a disk.

**Why did it land on my desk?** *Storage* is 10% of the CKA, and "**why is my PVC Pending?**" plus PV/PVC binding are classic tasks.

**What do I already know?** Maybe that pods lose data when they die. What's fuzzy: the PV↔PVC binding rules, why a claim can bind a *bigger* volume, and why some PVCs sit Pending *on purpose*.

---

# RUNG 1 — The Pain 🔥
### *Why does persistent storage exist at all?*

A pod's container filesystem is scratch — it dies with the pod:

```
THE EPHEMERAL-DATA PAIN
  db pod restarts    ─▶ its writable layer is gone → the database is empty
  hostPath /data     ─▶ works on 1 node; on a 3-node cluster each node's /data differs
  bake disk config into every pod ─▶ users must know the storage backend (AWS? NFS?) → tight coupling
  need a disk per app ─▶ admin manually makes a disk, then a PV, every single time → doesn't scale
```

**Before / without it:** data lived in the container and vanished on restart; the only "persistence" was a node-local `hostPath` that broke the moment a pod moved to another node.

**What breaks without it:** stateful workloads (databases, queues), portability (a pod that moves nodes must keep its data), and separation of concerns (app authors shouldn't need to know the storage vendor).

**Who feels it most?** App teams (their data) *and* the platform team (who must offer storage safely and at scale).

> **✅ Check yourself before Rung 2:** Why is a `hostPath` volume a trap on a multi-node cluster? (Hint: what does `/data` point to when the pod reschedules onto a different node?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Kubernetes storage decouples the app from the disk through a *claim*: an admin (or a StorageClass) offers **PersistentVolumes**, a pod's **PersistentVolumeClaim** requests a size + access mode + class, Kubernetes **binds** a matching PV to the claim **1:1**, and the pod mounts the *claim* — so the pod never names a physical disk.**

Derivations:
- *"the pod mounts the claim, never a disk"* → app authors write `claimName: my-pvc`; the storage backend (EBS, NFS, local) is the admin's/StorageClass's concern.
- *"binds a matching PV… 1:1"* → binding needs three matches (capacity ≥, access mode, class); a claim can bind a *larger* PV (rest wasted); no match → **Pending**.
- *"an admin **or a StorageClass** offers PVs"* → two worlds: **static** (admin pre-creates PVs) and **dynamic** (a StorageClass provisions a PV on demand when the PVC appears).
- *"requests… access mode"* → RWO/RWX etc. decide how many nodes/pods can mount it.

Once you see **PVC = a request, PV = a supply, binding = matchmaking**, "why is it Pending" becomes "which of the three matches failed."

> **✅ Check yourself before Rung 3:** A 50Mi PVC bound to a 100Mi PV. Why is that allowed, and what happens to the other 50Mi? What does "1:1" mean for a second claim wanting that PV?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

## (A) Volumes — the raw form

A **volume** stores data outside the container's writable layer. Kubernetes generalizes Docker's mounts and adds cloud/network backends via the **CSI (Container Storage Interface)** so any vendor plugs in.
```yaml
spec:
  containers:
  - name: app
    volumeMounts: [{ name: data, mountPath: /opt }]   # where the container sees it
  volumes:
  - name: data
    hostPath: { path: /data, type: DirectoryOrCreate } # a directory ON THE NODE
```
- **`emptyDir`** — scratch, lives with the pod (shared between its containers).
- **`hostPath`** — a node directory. ⚠️ **single-node only** — each node's `/data` differs.
- **cloud/CSI** (`awsElasticBlockStore`, `nfs`, `ebs.csi.aws.com`…) — real cross-node persistence.

## (B) PV/PVC — supply, request, bind

```
 admin ──creates──▶ PV (supply)          user ──creates──▶ PVC (request)
                       │  ◀──── Kubernetes binds a matching PV ────┐
                       └──────────────── 1:1 bind ─────────────────┘
                                            │
                         pod ──references──▶ PVC (as a volume)
```

```yaml
kind: PersistentVolume                 # apiVersion: v1
metadata: { name: pv-log }
spec:
  capacity: { storage: 100Mi }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /pv/log }          # demo backend
---
kind: PersistentVolumeClaim
metadata: { name: claim-log }
spec:
  accessModes: ["ReadWriteMany"]       # MUST be satisfiable by the PV
  resources: { requests: { storage: 50Mi } }
```

**Access modes:** RWO (one node RW), ROX (many nodes RO), RWX (many nodes RW), RWOP (one *pod* RW).

**Reclaim policy** (on PVC delete): **Retain** (default for manual PVs — kept, → `Released`, manual cleanup), **Delete** (default for dynamic — removes PV + backend), **Recycle** (deprecated).

**The binding triple — a PVC binds a PV when ALL hold:** capacity **≥** request, **accessModes** match, **storageClassName** match. Otherwise the PVC is **Pending**.

```yaml
# use it in a pod:
  volumes:
  - name: logs
    persistentVolumeClaim: { claimName: claim-log }
```
> 🎯 A **Pending PVC** with a seemingly-fitting PV is almost always an **access-mode** or **storageClassName** mismatch → `kubectl describe pvc`. Deleting a **bound** PVC that a pod still uses hangs in **Terminating** (finalizer) until the pod is gone.

## (C) StorageClass — dynamic provisioning

Manually making a disk *then* a PV is **static**. A **StorageClass** automates it: the PVC names a class, and its **provisioner** creates the disk + PV on demand.
```yaml
kind: StorageClass                     # storage.k8s.io/v1
metadata: { name: gold }
provisioner: ebs.csi.aws.com           # backend; "no-provisioner" = static/local
parameters: { type: gp3 }
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer   # vs Immediate
```
- **`volumeBindingMode: Immediate`** binds/provisions at once; **`WaitForFirstConsumer`** waits until a **pod** uses the PVC (so the volume lands in the pod's zone — topology-correct).
- The **default StorageClass** is applied to PVCs with no `storageClassName` by the `DefaultStorageClass` **admission controller** ([Section 2](02-scheduling.md)).

> 🎯 A PVC on a **`WaitForFirstConsumer`** class stays **Pending** with *"waiting for first consumer"* — this is **normal**, not a bug; it binds when a pod mounts it. Local-storage (`no-provisioner`) classes work this way.

> **✅ Check yourself before Rung 4:** Name the three things that must match for a PVC to bind a PV. And: which mechanism creates a PV *automatically* versus an admin creating it by hand?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which part |
|---|---|---|
| **volume** | Storage attached to a pod | Raw form |
| **emptyDir / hostPath** | Pod-scratch / node-dir volume | Raw (node-local) |
| **CSI** | Vendor plug-in interface for storage | Backend |
| **PersistentVolume (PV)** | A piece of supplied storage | Supply |
| **PersistentVolumeClaim (PVC)** | A request for storage | Request |
| **capacity / accessModes / storageClassName** | The three binding matches | Binding |
| **RWO/ROX/RWX/RWOP** | How many nodes/pods can mount RW/RO | Access modes |
| **reclaimPolicy (Retain/Delete)** | Fate of the PV on PVC delete | Lifecycle |
| **Released** | PV state after PVC deleted (Retain) | Lifecycle |
| **StorageClass** | Template for dynamic PV creation | Dynamic |
| **provisioner** | The backend that makes disks | Dynamic |
| **volumeBindingMode / WaitForFirstConsumer** | Bind now vs when a pod mounts | Dynamic |
| **DefaultStorageClass** | Admission controller assigning the default class | Dynamic |

**The unlock — two worlds, one binding:**
```
STATIC:   admin creates PV  ─┐
                             ├─▶ PVC binds a matching PV (capacity ≥, accessModes, class)
DYNAMIC:  StorageClass makes PV on demand ─┘   ─▶ pod mounts the PVC
```

> **✅ Check yourself before Rung 5:** Put these in "static" or "dynamic": an admin hand-writes a PV; a PVC names class `gold` and a disk appears; `provisioner: no-provisioner`.

---

# RUNG 5 — The Trace 🎬

**Trace — a stateful pod gets durable storage (dynamic):**
1. You create a **PVC** naming class `gold`, `RWO`, `10Gi`.
2. The `DefaultStorageClass`/named class routes it to the **`ebs.csi.aws.com` provisioner**.
3. With `WaitForFirstConsumer`, binding **waits** — the PVC is `Pending` ("waiting for first consumer"). *(With `Immediate`, a disk + PV would appear now.)*
4. You create a **pod** referencing the PVC. The scheduler places it; now the provisioner creates an **EBS disk in that node's zone**, wraps it in a **PV**, and **binds** the PV to the PVC 1:1.
5. The **kubelet** mounts the volume into the container at `mountPath`. The app writes data.
6. The pod dies and reschedules → the same PVC re-binds the same PV → **the data is still there**.
7. Later the PVC is deleted → **reclaimPolicy** decides: `Delete` removes the PV + EBS disk; `Retain` keeps the PV as `Released` for manual cleanup.

```
PVC(gold,RWO,10Gi) ─▶ provisioner ─(WaitForFirstConsumer)─▶ Pending
      pod mounts PVC ─▶ disk+PV created in pod's zone ─▶ bind 1:1 ─▶ kubelet mounts ─▶ data persists
      PVC deleted ─▶ reclaimPolicy: Delete→gone | Retain→Released
```

**Trace — a Pending PVC (static, mismatch):** PVC(RWO) vs the only PV(RWX) → binder finds **no access-mode match** → PVC stays `Pending`; `describe pvc` says so; fix the mode → it binds (to the whole PV, even if bigger than requested).

> **✅ Check yourself before Rung 6:** In the dynamic trace, why did the disk only get created at step 4 (not step 1)? What real-world problem does that timing solve?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **hostPath / emptyDir** | **PV/PVC** | node-local / pod-scratch vs portable, claimed, durable |
| **static provisioning** | **dynamic (StorageClass)** | admin pre-creates PVs vs auto-created on demand |
| **Retain** | **Delete** | keep data (manual cleanup) vs wipe PV + backend |
| **Immediate** | **WaitForFirstConsumer** | bind now vs bind when a pod mounts (topology-aware) |
| **RWO** | **RWX** | one node RW vs many nodes RW (needs a shared backend like NFS) |

**When NOT to:** don't use `hostPath` for anything that must survive rescheduling; don't set `Delete` on a PV holding data you can't lose; don't expect `RWX` from a block device (EBS is RWO — you need NFS/EFS for RWX); don't "fix" a `WaitForFirstConsumer` Pending PVC — mount it with a pod.

**One-sentence "why this over that":**
> Claim storage with a PVC so the pod never hard-codes a disk; use a StorageClass for on-demand dynamic provisioning, `Retain` for data you must not lose, and match access modes to how many nodes need to write.

> **✅ Check yourself before Rung 7:** A teammate set a database PV's reclaim policy to `Delete` and deleted the PVC to "clean up." What just happened to the data, and what policy should they have used?

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — hostPath survives the pod but is node-local

> **My prediction:** "If I add a `hostPath` volume, then the file appears on the node's path and survives pod deletion — but only on *that* node — *because* hostPath is just a directory on the node the pod runs on."

```bash
kubectl edit pod webapp        # add volume + volumeMount → save fails → /tmp
kubectl replace --force -f /tmp/kubectl-edit-XXXX.yaml
kubectl exec webapp -- cat /log/app.log
cat /var/log/webapp/app.log    # same content, on the NODE
```
```yaml
  volumes: [{ name: log-vol, hostPath: { path: /var/log/webapp } }]
  # container: volumeMounts: [{ name: log-vol, mountPath: /log }]
```
**Verify:** the file persists on the node after pod recreate. Move the pod to another node and the file's *gone from view* — proving node-locality.

## Prediction 2 — An access-mode mismatch keeps the PVC Pending

> **My prediction:** "If my PV is RWX but my PVC asks RWO (or the classes differ), the PVC stays **Pending**; matching the access mode binds it — to the *PV's* capacity, even if I requested less — *because* binding requires capacity≥, accessModes, and class to all match, 1:1."

```bash
kubectl apply -f pv.yaml -f pvc.yaml
kubectl get pv,pvc                 # PV Available, PVC Pending
kubectl describe pvc claim-log     # no matching PV (access mode)
# fix PVC accessModes → ReadWriteMany:
kubectl replace --force -f pvc.yaml
kubectl get pvc                    # Bound, shows 100Mi (the PV's size)
```
**Verify:** Pending → Bound after matching the mode; bound capacity = the PV's. This is the #1 "PVC Pending" cause.

## Prediction 3 — WaitForFirstConsumer binds only when a pod mounts

> **My prediction:** "If a PVC uses a `WaitForFirstConsumer` class, it stays **Pending** ('waiting for first consumer') until I create a pod that mounts it, then it **Binds** — *because* the class delays binding until a consumer's placement is known."

```bash
kubectl get pvc local-pvc          # Pending
kubectl describe pvc local-pvc     # "waiting for first consumer"
kubectl run nginx --image=nginx:alpine --dry-run=client -o yaml > nginx.yaml
# add volumes.persistentVolumeClaim.claimName=local-pvc + a volumeMount
kubectl apply -f nginx.yaml
kubectl get pvc local-pvc          # Bound
```
**Verify:** Pending → Bound the instant a pod mounts it. That Pending was *expected*, not a fault.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> A pod mounts a PersistentVolumeClaim (never a disk); Kubernetes binds that claim 1:1 to a PersistentVolume matching its capacity, access mode, and class — supplied either statically by an admin or dynamically by a StorageClass — and the reclaim policy decides the volume's fate when the claim is deleted.

**Explain it to a beginner in 3 sentences:**
> 1. Container storage disappears when a pod dies, so you attach a volume — and for durable storage, the pod uses a *claim* rather than naming a real disk.
> 2. Kubernetes matches that claim to an available volume by size, access mode, and class; if nothing matches, the claim sits Pending.
> 3. A StorageClass can create the disk automatically on demand, and a reclaim policy decides whether the disk is kept or wiped when you delete the claim.

**Which rung to revisit hands-on?** Rung 3B + Prediction 2 — the **three-match binding rule** and reading `describe pvc` are what turn "PVC Pending" from mystery into a 20-second fix.

---

## 🎯 CKA exam tips & quick notes

- **Binding needs three matches:** capacity (≥), **accessModes**, **storageClassName**. Debug Pending with `kubectl describe pvc`.
- **Access modes:** RWO / ROX / RWX / RWOP — RWO PV won't satisfy an RWX claim.
- **Reclaim:** `Retain` (keep → Released) vs `Delete` (auto-wipe) vs `Recycle` (deprecated).
- **Deleting a bound PVC** hangs `Terminating` until the consuming pod is gone.
- **StorageClass** = dynamic; `no-provisioner` = static/local; **`WaitForFirstConsumer`** PVCs stay Pending until a pod mounts — *expected*.
- Mount via `volumes[].persistentVolumeClaim.claimName` + `volumeMounts`. Short names `pv/pvc/sc`.

## 📌 Command cheat sheet
```bash
kubectl get pv,pvc,sc                          # overview
kubectl describe pvc <name>                     # why Pending?
kubectl get pvc <name> -o jsonpath='{.status.phase}{"\n"}'
# in a Pod/Deployment:
#   volumes: [{ name: v, persistentVolumeClaim: { claimName: my-pvc } }]
#   volumeMounts: [{ name: v, mountPath: /data }]
```

---

## Related sections

- [Section 2 — Scheduling](02-scheduling.md) — the `DefaultStorageClass` mutating admission controller.
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — mounting ConfigMaps/Secrets as volumes.
- [Section 1 — Core Concepts](01-core-concepts.md) — pods and how volumes attach.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — a pod stuck `ContainerCreating` on a volume.
- [../../Linux/15-storage-mounts.md](../../Linux/15-storage-mounts.md) — the Linux mount/filesystem layer underneath volumes.
