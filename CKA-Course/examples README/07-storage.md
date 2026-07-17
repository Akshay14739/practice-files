# 💾 Section 7 — Storage (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 7 transcript.

---

## 1. Volumes (emptyDir, hostPath, and the CSI world)

### ❓ What
Storage attached to a pod that lives **outside the container's writable layer**: `emptyDir` (pod-scratch), `hostPath` (a node directory), and cloud/network backends via **CSI** (Container Storage Interface).

### 🔥 Pain points it solves & why this?
- A container's filesystem dies with the container — restart a DB pod and the data's gone.
- Containers in one pod need a shared scratch space (`emptyDir`).
- ⚠️ `hostPath` is a trap on multi-node clusters: each node's `/data` is a *different* directory — the pod sees different data wherever it lands. CSI exists so real (EBS/NFS/…) storage follows the pod.

### ⚙️ How exactly it works
Declare `volumes:` at pod level, mount per container with `volumeMounts:`. Docker's volume/bind mounts generalized; CSI lets any vendor plug a driver in (same "interface" idea as CNI).

| Vocabulary | Meaning |
|---|---|
| `emptyDir` | created with the pod, deleted with it; shared by its containers |
| `hostPath` | a directory **on the node** (single-node use only) |
| `mountPath` | where the container sees the volume |
| **CSI** | the plug-in spec for real storage backends |

### 🧪 Hands-on examples

**Example 1 — hostPath: keep data past the pod:**
```yaml
spec:
  containers:
  - name: app
    image: alpine
    command: ["sh","-c","echo hello > /opt/data.txt; sleep 3600"]
    volumeMounts: [ { name: data, mountPath: /opt } ]
  volumes:
  - name: data
    hostPath: { path: /data, type: DirectoryOrCreate }
```
```bash
kubectl apply -f pod.yaml && kubectl delete pod app
cat /data/data.txt        # on the node: still there
# Verify: the file outlives the pod — but ONLY on that node.
```

**Example 2 — emptyDir shared between two containers:**
```yaml
spec:
  containers:
  - { name: writer, image: busybox, command: ["sh","-c","while true; do date >> /cache/log; sleep 5; done"], volumeMounts: [{name: c, mountPath: /cache}] }
  - { name: reader, image: busybox, command: ["sh","-c","tail -f /cache/log"], volumeMounts: [{name: c, mountPath: /cache}] }
  volumes: [ { name: c, emptyDir: {} } ]
```
```bash
kubectl logs shared -c reader -f
# Verify: reader sees writer's lines; delete the pod → the data is gone (scratch).
```

**Example 3 — Prove the hostPath multi-node trap:**
```bash
# run the Example-1 pod pinned to node01 (nodeName), write data, delete it,
# then pin to node02 and read:
kubectl exec app -- cat /opt/data.txt      # No such file — different node, different /data
# Verify: hostPath data does NOT follow the pod — the reason PVs exist.
```

---

## 2. PersistentVolumes & PersistentVolumeClaims

### ❓ What
**PV** = a piece of storage supplied (by an admin or dynamically); **PVC** = a pod team's *request* for storage. Kubernetes **binds** a claim to a matching volume **1:1**; the pod mounts the *claim*.

### 🔥 Pain points it solves & why this?
- Baking storage config into every pod couples app authors to the backend (AWS? NFS?) — the claim decouples them.
- Central pool vs per-pod ad-hoc definitions: admins manage supply, users just ask for size + access mode.
- The binding rules explain the #1 storage symptom: a **Pending** PVC.

### ⚙️ How exactly it works
```
admin ─creates─▶ PV (supply)        user ─creates─▶ PVC (request)
                   └────── bound 1:1 when ALL match ──────┘
                     capacity ≥ request · accessModes · storageClassName
pod ─mounts─▶ persistentVolumeClaim: { claimName: … }
```

| Vocabulary | Meaning |
|---|---|
| accessModes | RWO (1 node rw) / ROX (many ro) / RWX (many rw) / RWOP (1 pod rw) |
| reclaimPolicy | **Retain** (keep → `Released`, manual cleanup) / **Delete** / Recycle (deprecated) |
| `Pending` PVC | no PV matched all three criteria |
| 1:1 bind | a smaller claim can bind a bigger PV (remainder wasted; no sharing) |

### 🧪 Hands-on examples

**Example 1 — Create PV + PVC + pod (the full chain):**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata: { name: pv-log }
spec:
  capacity: { storage: 100Mi }
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /pv/log }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: claim-log }
spec:
  accessModes: ["ReadWriteMany"]
  resources: { requests: { storage: 50Mi } }
EOF
kubectl get pv,pvc      # pv Bound + pvc Bound (50Mi claim bound the 100Mi PV!)
# pod:  volumes: [{name: logs, persistentVolumeClaim: {claimName: claim-log}}]
# Verify: PVC shows capacity 100Mi — you get the whole PV, 1:1.
```

**Example 2 — Diagnose a Pending PVC (access-mode mismatch):**
```bash
# PV has ReadWriteMany; make the PVC ask ReadWriteOnce → apply
kubectl get pvc claim-log        # Pending
kubectl describe pvc claim-log   # no volume matches (access mode)
# fix accessModes to match → replace --force
kubectl get pvc                  # Bound
# Verify: binding needs capacity ≥ AND accessModes AND storageClass to match.
```

**Example 3 — Reclaim policy in action:**
```bash
kubectl delete pod app           # free the claim's consumer first
kubectl delete pvc claim-log     # (a bound PVC in use would hang Terminating!)
kubectl get pv pv-log            # STATUS: Released (Retain kept it + the data)
# A Released PV is NOT reusable until an admin clears claimRef / recreates it.
# Verify: Retain = data safe but manual cleanup; Delete would have wiped PV + backend.
```

---

## 3. StorageClasses — dynamic provisioning

### ❓ What
A template that **creates PVs on demand**: the PVC names a class; the class's **provisioner** makes the disk + PV automatically.

### 🔥 Pain points it solves & why this?
- Static flow = admin manually creates a disk, then a PV, for every app — doesn't scale.
- Topology: a disk must be created in the *zone where the pod lands* → `WaitForFirstConsumer` delays provisioning until the pod is scheduled.
- Classes tier storage (fast SSD "gold" vs cheap "bronze") behind one simple claim interface.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `provisioner` | who makes the disk (`ebs.csi.aws.com`…); **`no-provisioner`** = static/local |
| `volumeBindingMode` | `Immediate` (bind now) vs **`WaitForFirstConsumer`** (bind when a pod mounts) |
| default class | injected into class-less PVCs by the `DefaultStorageClass` admission controller |
| `parameters` | backend knobs (disk type gp3, replication…) |

### 🧪 Hands-on examples

**Example 1 — Define a class, claim from it:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gold }
provisioner: ebs.csi.aws.com
parameters: { type: gp3 }
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
# PVC just names the class — NO manual PV:
#   spec: { storageClassName: gold, accessModes: [ReadWriteOnce], resources: { requests: { storage: 10Gi } } }
kubectl get sc
# Verify: on a cloud cluster, the disk + PV appear when a pod mounts the PVC.
```

**Example 2 — The "Pending is normal" case (WaitForFirstConsumer):**
```bash
kubectl get pvc local-pvc            # Pending
kubectl describe pvc local-pvc      # "waiting for first consumer to be created"
kubectl run nginx --image=nginx:alpine --dry-run=client -o yaml > n.yaml
# add: volumes: [{name: v, persistentVolumeClaim: {claimName: local-pvc}}] + a volumeMount
kubectl apply -f n.yaml
kubectl get pvc local-pvc            # Bound — the pod was the trigger
# Verify: that Pending was expected behavior, not a fault.
```

**Example 3 — Watch the default class get injected:**
```bash
kubectl get sc                        # one marked (default)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: classless }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Gi } } }
EOF
kubectl get pvc classless -o jsonpath='{.spec.storageClassName}{"\n"}'
# Verify: the class you never wrote appears — the DefaultStorageClass admission controller did it.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Deleting a bound PVC while a pod uses it** hangs in `Terminating` (a finalizer) until the pod is deleted — expected, not a bug.
- **RWX needs a shared backend** (NFS/EFS/CephFS); block devices like EBS are RWO — a common design mistake.
- **StatefulSets + volumeClaimTemplates** give each replica its own PVC — the pattern for real databases (beyond CKA's storage section, worth knowing exists).

---

## Related
[02-scheduling](02-scheduling.md) (DefaultStorageClass admission) · [04-application-lifecycle-management](04-application-lifecycle-management.md) (ConfigMap/Secret volumes) · [13-troubleshooting](13-troubleshooting.md) (pods stuck ContainerCreating on volumes) · Ladder version: [../README/07-storage.md](../README/07-storage.md)
