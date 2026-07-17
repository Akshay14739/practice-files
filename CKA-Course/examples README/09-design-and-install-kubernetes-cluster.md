# 🏗️ Section 9 — Design & Install a Kubernetes Cluster (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 9 transcript. The **etcd quorum math** is the testable core.

---

## 1. Cluster design choices

### ❓ What
Choosing *how* to build: minikube (learning), kubeadm multi-node (dev/prod you manage), managed (EKS/GKE/AKS) or turnkey (kOps) — driven by purpose, hosting, and scale.

### 🔥 Pain points it solves & why this?
- Overbuilding a learning cluster wastes days; underbuilding prod loses uptime.
- Knowing the ceilings (they're in the docs — don't memorize) prevents wrong-sized designs.
- Workloads on control-plane nodes destabilize the control plane → dedicate them.

### ⚙️ How exactly it works

| Goal | Recommended |
|---|---|
| Learning | **minikube** (creates its own single-node VM) |
| Dev/test | **kubeadm** multi-node (you provision the VMs) |
| Production | HA kubeadm, or managed (EKS/GKE/AKS), or kOps |

Scale (docs, not memory): ~5000 nodes, ~150k pods, ~110 pods/node (`--max-pods`). kubeadm taints control-plane nodes `node-role.kubernetes.io/control-plane:NoSchedule`.

### 🧪 Hands-on examples

**Example 1 — See (and understand) the control-plane taint:**
```bash
kubectl describe node controlplane | grep -i taint
# node-role.kubernetes.io/control-plane:NoSchedule
kubectl run t --image=nginx && kubectl get pod t -o wide     # lands on a WORKER
# Verify: workloads avoid the control plane because of this taint (Section 2 machinery).
```

**Example 2 — (Lab-only) allow workloads on the control plane:**
```bash
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule-
kubectl run t2 --image=nginx -o wide      # can now land on controlplane
# re-add for hygiene:
kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule
# Verify: single-node labs remove the taint; prod never does.
```

**Example 3 — Check a node's pod capacity:**
```bash
kubectl describe node node01 | grep -A6 Capacity     # pods: 110
# Verify: the ~110 pods/node default is a kubelet setting (--max-pods), not a law.
```

---

## 2. High-availability control plane

### ❓ What
Multiple control-plane nodes with: **apiserver active-active** behind a load balancer, **scheduler/controller-manager active-standby** via **leader election**.

### 🔥 Pain points it solves & why this?
- One control-plane node = one reboot away from "no scheduling, no healing, no kubectl."
- Why not run everything active-active? Two active schedulers would **double-schedule** pods — singleton components need a leader lock.
- The apiserver is stateless per request → safe to run N copies behind an LB on `:6443`.

### ⚙️ How exactly it works
```
            ┌───── Load Balancer :6443 ─────┐   ← kubectl & kubelets point HERE
            ▼                                ▼
   CP-1: apiserver ACTIVE          CP-2: apiserver ACTIVE     (active-active)
         scheduler ACTIVE                scheduler standby    (leader election)
         ctrl-mgr  ACTIVE                ctrl-mgr  standby    (leader election)
         etcd member                     etcd member          (Raft, next topic)
```

| Vocabulary | Meaning |
|---|---|
| `--leader-elect=true` | competitors race for a **Lease** lock |
| lease-duration / renew-deadline / retry-period | 15s hold / 10s renew / 2s retry |
| Lease object | `kubectl get lease -n kube-system` names the current holder |

### 🧪 Hands-on examples

**Example 1 — Confirm leader election is on:**
```bash
grep -- '--leader-elect' /etc/kubernetes/manifests/kube-scheduler.yaml
grep -- '--leader-elect' /etc/kubernetes/manifests/kube-controller-manager.yaml
# Verify: both true (the default) — only one instance of each ACTS at a time.
```

**Example 2 — Find the current leader:**
```bash
kubectl get lease -n kube-system
kubectl get lease kube-scheduler -n kube-system -o jsonpath='{.spec.holderIdentity}{"\n"}'
# Verify: holderIdentity names the node whose scheduler is active right now.
```

**Example 3 — (HA lab) watch failover:**
```bash
# on the leader node: stop the scheduler (move its manifest out of /etc/kubernetes/manifests)
kubectl get lease kube-scheduler -n kube-system -w
# within ~lease-duration the OTHER node's scheduler grabs the lease
# Verify: scheduling resumes within seconds — that's active-standby working.
```

---

## 3. etcd topologies & quorum

### ❓ What
etcd replicated across members via **Raft**: a write commits only when a **majority (quorum)** confirms. Topologies: **stacked** (etcd on the control-plane nodes) vs **external** (dedicated etcd servers).

### 🔥 Pain points it solves & why this?
- The cluster's memory can't live on one disk — but naive replication risks split-brain.
- Majority-commit means a partition can't produce two divergent truths.
- The counterintuitive consequence you must internalize: **2 members are no safer than 1**, and **odd counts beat even**.

### ⚙️ How exactly it works
**Quorum = ⌊N/2⌋+1 · Fault tolerance = N − quorum**

| N | Quorum | Can lose |
|---|---|---|
| 1 | 1 | 0 |
| **2** | **2** | **0** ← trap! |
| **3** | 2 | **1** |
| 4 | 3 | 1 (same as 3, costs more) |
| **5** | 3 | **2** |

Even clusters can partition into two halves *neither* of which has quorum (6 → 3/3 → total stop). Only the apiserver talks to etcd (`--etcd-servers`); peers find each other via `--initial-cluster` on **:2380**.

### 🧪 Hands-on examples

**Example 1 — Read the membership + leader:**
```bash
ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
ETCDCTL_API=3 etcdctl endpoint status --write-out=table --endpoints=... --cacert=... --cert=... --key=...
# Verify: N members, exactly one IS LEADER=true.
```

**Example 2 — Compute fault tolerance cold (exam math):**
```bash
# N=3 → quorum 2 → lose 1
# N=4 → quorum 3 → lose 1   (why even buys nothing)
# N=5 → quorum 3 → lose 2
# N=7 → quorum 4 → lose 3
# Verify: say quorum + tolerance for any N without the table.
```

**Example 3 — See stacked topology + peer wiring:**
```bash
kubectl get pods -n kube-system -o wide | grep etcd     # etcd co-located on CP nodes = stacked
sudo grep -E 'initial-cluster|listen-peer' /etc/kubernetes/manifests/etcd.yaml
# Verify: peers listed on :2380; external topology would show etcd on non-CP machines instead.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Three replication behaviors, one table:** stateless (apiserver → active-active + LB), singleton (scheduler/ctrl-mgr → leader election), consensus (etcd → odd quorum). Every HA design question resolves to which of the three a component is.
- If you *might* go HA later, run `kubeadm init --control-plane-endpoint=<LB>` from day one — retrofitting it is painful ([Section 10](10-install-kubernetes-kubeadm-way.md)).

---

## Related
[10-kubeadm](10-install-kubernetes-kubeadm-way.md) (building it) · [05-cluster-maintenance](05-cluster-maintenance.md) (etcd backup) · [01-core-concepts](01-core-concepts.md) (the components) · Ladder version: [../README/09-design-and-install-kubernetes-cluster.md](../README/09-design-and-install-kubernetes-cluster.md)
