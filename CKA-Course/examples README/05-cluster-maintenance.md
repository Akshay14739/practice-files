# 🛠️ Section 5 — Cluster Maintenance (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 5 transcript. The **upgrade** and **etcd restore** flows are near-guaranteed exam tasks.

---

## 1. Node maintenance — drain, cordon, uncordon

### ❓ What
Deliberately evacuating a node before touching it: `cordon` (block new pods), `drain` (evict existing + cordon), `uncordon` (reopen for scheduling).

### 🔥 Pain points it solves & why this?
- Rebooting a node cold kills its pods mid-request; users notice.
- If a node just dies, the control plane waits the **pod eviction timeout** (~5 min) before rescheduling — a planned drain moves pods *now*, gracefully.
- Bare pods (no controller) are **gone forever** if the node dies — drain at least warns you about them.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `cordon` | node marked `SchedulingDisabled`; existing pods stay |
| `drain` | graceful eviction of all pods + cordon |
| `uncordon` | schedulable again (⚠️ evicted pods do NOT come back) |
| `--ignore-daemonsets` | DS pods can't move — required if any exist |
| `--force` | also evict bare pods (they are lost) |
| `--delete-emptydir-data` | accept losing emptyDir scratch data |
| pod eviction timeout | controller-manager wait (~5 m) before declaring a dead node's pods gone |

### 🧪 Hands-on examples

**Example 1 — Patch a node with zero app downtime:**
```bash
kubectl get pods -o wide | grep node01          # what's there
kubectl drain node01 --ignore-daemonsets
kubectl get nodes                               # node01 Ready,SchedulingDisabled
kubectl get pods -o wide                        # RS pods recreated on other nodes
# ...reboot/patch node01...
kubectl uncordon node01
# Verify: app pods served throughout; node01 takes NEW pods only after uncordon.
```

**Example 2 — The drain blockers, one by one:**
```bash
kubectl drain node01
# error: DaemonSet-managed pods → add --ignore-daemonsets
# error: pods not managed by a controller → add --force  (bare pod is DELETED forever)
# error: pods with local storage → add --delete-emptydir-data
kubectl drain node01 --ignore-daemonsets --force --delete-emptydir-data
# Verify: each error names its flag; you know the cost of each.
```

**Example 3 — cordon vs drain difference:**
```bash
kubectl cordon node02
kubectl get pods -o wide | grep node02      # pods STILL there (cordon ≠ evict)
kubectl scale deployment web --replicas=8   # new pods land elsewhere only
kubectl uncordon node02
# Verify: cordon only blocks NEW placement — existing pods untouched.
```

---

## 2. Kubernetes versions & the skew rule

### ❓ What
Versioning (`major.minor.patch`) plus the **version-skew policy**: nothing may be newer than `kube-apiserver`; components may trail it by fixed amounts.

### 🔥 Pain points it solves & why this?
- Upgrading components in the wrong order = they refuse to talk to each other.
- Only the **3 latest minors** are supported — falling behind means unsupported clusters.
- The skew rule *derives the upgrade order* for you: control plane first, kubelets after.

### ⚙️ How exactly it works
```
                kube-apiserver        (X)    ← the reference
       ┌───────────────┼───────────────┐
controller-manager  scheduler        kubectl
     (X-1)            (X-1)       (X-1 … X+1)
       │
  kubelet / kube-proxy  (X-2)
```
Upgrade **one minor at a time** (1.27→1.28→1.29 — never skip). etcd & CoreDNS have separate version numbers.

### 🧪 Hands-on examples

**Example 1 — Audit a cluster's versions:**
```bash
kubectl get nodes                          # kubelet version per node
kubectl version                            # client + server
kubectl get pod kube-apiserver-controlplane -n kube-system \
  -o jsonpath='{.spec.containers[0].image}{"\n"}'
# Verify: you can state apiserver vs kubelet versions and whether skew is legal.
```

**Example 2 — Plan an upgrade path:**
```bash
sudo kubeadm upgrade plan
# shows current, latest-in-minor, and the target versions per component
# Cluster at 1.27, target 1.29?  → 1.27→1.28, then 1.28→1.29 (two passes)
# Verify: plan never offers a 2-minor jump.
```

**Example 3 — Spot an illegal skew:**
```bash
# apiserver 1.29, a node's kubelet 1.26 → X-3 = OUT of policy
kubectl get nodes    # the offending version column
# Fix: upgrade that node's kubelet before touching the control plane again.
# Verify: kubelet may trail by at most TWO minors.
```

---

## 3. Upgrading a cluster with kubeadm

### ❓ What
The supported upgrade procedure: kubeadm upgrades the **control-plane static pods**; you upgrade the **kubelet manually** on every node.

### 🔥 Pain points it solves & why this?
- Hand-upgrading each control-plane manifest and binary is error-prone; kubeadm sequences it.
- Users keep being served: workloads run on kubelets, which stay up while the control plane upgrades.
- Gotcha it explains: `kubectl get nodes` shows **kubelet** versions — unchanged until you restart kubelets.

### ⚙️ How exactly it works
```
per node : bump pkgs.k8s.io repo to the target minor → apt-cache madison kubeadm
CONTROL  : apt install kubeadm=<v> → kubeadm upgrade plan → kubeadm upgrade apply <v>
           → drain → apt install kubelet kubectl=<v> → systemctl restart kubelet → uncordon
WORKERS  : apt install kubeadm=<v> → kubeadm upgrade node   ("node", NOT "apply")
           → drain → apt install kubelet kubectl=<v> → restart kubelet → uncordon
```

### 🧪 Hands-on examples

**Example 1 — Full control-plane upgrade (1.28 → 1.29):**
```bash
sudo sed -i 's|v1.28|v1.29|' /etc/apt/sources.list.d/kubernetes.list && sudo apt-get update
apt-cache madison kubeadm | head -3            # pick the exact patch
sudo apt-get install -y kubeadm=1.29.0-1.1
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.29.0
kubectl get nodes                              # STILL 1.28 (kubelet not touched yet!)
kubectl drain controlplane --ignore-daemonsets
sudo apt-get install -y kubelet=1.29.0-1.1 kubectl=1.29.0-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon controlplane
kubectl get nodes                              # NOW 1.29.0
# Verify: the version flips only after the kubelet restart.
```

**Example 2 — Upgrade a worker:**
```bash
# on the worker:
sudo apt-get install -y kubeadm=1.29.0-1.1
sudo kubeadm upgrade node                       # NOT "apply"
# from the control plane:
kubectl drain node01 --ignore-daemonsets
# on the worker:
sudo apt-get install -y kubelet=1.29.0-1.1 kubectl=1.29.0-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon node01
# Verify: node01 shows 1.29.0 and Ready.
```

**Example 3 — Prove workloads survive the control-plane upgrade:**
```bash
kubectl create deployment probe --image=nginx --replicas=3
# during `kubeadm upgrade apply`: curl the app via its NodePort in a loop
while true; do curl -s -o /dev/null -w "%{http_code}\n" http://<node>:<port>; sleep 1; done
# Verify: 200s throughout — kubectl may blip, the WORKLOAD doesn't.
```

---

## 4. Backup & Restore (resource configs + etcd)

### ❓ What
Two backup layers: (1) your **declarative YAML** (Git, `kubectl get -o yaml`, Velero), and (2) an **etcd snapshot** — the authoritative, complete cluster state.

### 🔥 Pain points it solves & why this?
- Lose etcd with no snapshot = every object, secret, and configuration is gone, permanently.
- YAML in Git misses imperative objects and live state; an etcd snapshot captures *everything at a point in time*.
- Restore is a drill you must be fast at — it's the classic disaster-recovery exam task.

### ⚙️ How exactly it works
- **Backup** talks to the live etcd — the four flags are mandatory: `--endpoints --cacert --cert --key` (find values in `/etc/kubernetes/manifests/etcd.yaml`).
- **Restore** is offline: unpack the snapshot into a **new data dir**, then repoint the etcd static pod's **`hostPath` volume** at it; the kubelet recreates etcd (and the apiserver follows). Restore deliberately initializes a *new* cluster identity (new member IDs).
- **`etcdctl`** = live/network commands (save/status); **`etcdutl`** = offline file commands (the modern restore).

### 🧪 Hands-on examples

**Example 1 — Snapshot etcd (backup):**
```bash
ETCDCTL_API=3 etcdctl snapshot save /opt/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
etcdctl snapshot status /opt/snapshot.db --write-out=table
# Verify: the status table shows hash, revision, total keys, size.
```

**Example 2 — Full disaster-recovery drill (restore):**
```bash
kubectl delete deployment web            # simulate the disaster
ETCDCTL_API=3 etcdctl snapshot restore /opt/snapshot.db \
  --data-dir=/var/lib/etcd-from-backup
sudo vi /etc/kubernetes/manifests/etcd.yaml
#   volumes: → etcd-data hostPath.path: /var/lib/etcd-from-backup   (ONLY this)
watch kubectl get pods -A                # etcd + apiserver restart, then…
kubectl get deployment web               # IT'S BACK (snapshot-time state)
# Verify: deleted objects reappear; anything created after the snapshot is gone.
```

**Example 3 — Quick resource-config backup (the other layer):**
```bash
kubectl get all -A -o yaml > all-resources.yaml     # catch-all
# better practice: YAML in Git; Velero for full backups incl. PVs
# Verify: you can explain what this layer misses (imperative-only objects’ history,
# non-"all" kinds like configmaps/secrets unless queried) vs an etcd snapshot.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **PodDisruptionBudget (PDB):** production drains respect PDBs (`minAvailable`) — a drain can hang waiting on one; `kubectl get pdb` explains why.
- **`kubeadm certs check-expiration`** — kubeadm certs live 1 year; upgrades renew them, but know the check command.
- Take an **etcd snapshot before every upgrade** — the two skills of this section compose.

---

## Related
[09-design-and-install](09-design-and-install-kubernetes-cluster.md) (etcd topology) · [10-kubeadm](10-install-kubernetes-kubeadm-way.md) (the tool being upgraded) · [13-troubleshooting](13-troubleshooting.md) (when the control plane won't come back) · Ladder version: [../README/05-cluster-maintenance.md](../README/05-cluster-maintenance.md)
