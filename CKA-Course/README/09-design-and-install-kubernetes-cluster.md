# Design & HA, Climbed the Ladder 🪜
### Section 9 of the CKA — deriving why a cluster needs an *odd* number of brains

> Designing a cluster and making it **highly available**: multiple control-plane nodes, leader election, and **etcd quorum**. Mostly conceptual, but the quorum math is testable. We climb from **the pain of a single point of failure** → **the "no SPOF, but consensus needs a majority" idea** → **the machinery** → then checks as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How to choose a cluster build, and how to remove single points of failure from the control plane — including the counter-intuitive etcd quorum rule.

**Why did it land on my desk?** *Cluster Architecture* is 25% of the CKA. You won't be asked to memorize scale ceilings, but **HA reasoning and etcd quorum** show up, and you must know why "just add a second master" isn't enough.

**What do I already know?** Maybe that "prod needs more than one master." What's fuzzy: why apiservers all run at once but only one scheduler acts, and why a **2-node etcd is no safer than 1**.

---

# RUNG 1 — The Pain 🔥
### *Why does HA design exist at all?*

A single control-plane node is a single point of failure:

```
THE SINGLE-CONTROL-PLANE PAIN
  control-plane node dies ─▶ running pods keep serving, BUT:
                            • no new scheduling, no self-healing, no kubectl
                            • etcd is gone → the cluster's entire memory is unavailable
  "just add a 2nd etcd"   ─▶ surprise: a 2-node etcd tolerates ZERO failures (quorum trap)
  network partition       ─▶ an even cluster can split so NEITHER half has a majority → total stop
```

**Before / without it:** one master, one etcd — a single reboot or disk failure takes down cluster management, and a naive "add one more" for etcd doesn't actually buy fault tolerance.

**What breaks without it:** manageability (schedule/heal/kubectl all depend on the control plane) and — because etcd is a *consensus* store — availability the moment you can't reach a majority of etcd members.

**Who feels it most?** The platform team running production — a control-plane outage means nothing new deploys and nothing self-heals until it's back.

> **✅ Check yourself before Rung 2:** If the single control-plane node dies, what *keeps* working and what *stops*? (Hint: think running pods vs. new decisions.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **High availability means no single point of failure: replicate the control plane behind a load balancer — but because **etcd is a consensus database that only commits a write when a *majority* (quorum) of members agree**, you need an *odd* number of etcd members, at least **3**, or you gain no real fault tolerance.**

Derivations:
- *"replicate the control plane"* → multiple control-plane nodes; but each component behaves differently: **apiserver** is stateless (**active-active** behind an LB) while **scheduler/controller-manager** would collide if doubled (**active-standby** via **leader election**).
- *"etcd… majority… quorum"* → **quorum = ⌊N/2⌋+1**, **fault tolerance = N − quorum**. This is *why* 2 nodes tolerate 0 failures (quorum is still 2) and why **odd is better** (an even split leaves neither half with a majority).
- *"at least 3"* → 3 tolerates 1 failure — the minimum real HA; 5 tolerates 2; beyond that rarely pays.

The whole section is: *replicate everything, but respect that a consensus store needs a majority alive.*

> **✅ Check yourself before Rung 3:** Why is a 2-member etcd cluster no more fault-tolerant than a 1-member one? State the quorum for each.

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

## (A) Design choices

| Goal | Recommended |
|---|---|
| Learning | **minikube** (single node, provisions the VM) or kubeadm single-node |
| Dev/test | **kubeadm** multi-node (you provision VMs) |
| Production | **HA multi-master** (kubeadm), or **managed** (EKS/GKE/AKS), or turnkey (kOps) |

- **minikube** *creates* the VM (single node); **kubeadm** expects VMs but supports **multi-node**.
- Scale ceilings (in the docs, don't memorize): ~5000 nodes, ~150k pods, ~110 pods/node.
- **Dedicate control-plane nodes** — kubeadm taints them `node-role.kubernetes.io/control-plane:NoSchedule` so workloads stay off.

## (B) HA control plane — two behaviors

```
                 ┌──────── Load Balancer (:6443) ────────┐   ← kubectl / kubelets point HERE
                 ▼                                        ▼
      ┌──── control-plane-1 ────┐            ┌──── control-plane-2 ────┐
      │ kube-apiserver  ACTIVE  │            │ kube-apiserver  ACTIVE  │  ← active-ACTIVE (stateless)
      │ scheduler       ACTIVE  │            │ scheduler       standby │  ← active-STANDBY (leader elect)
      │ controller-mgr  ACTIVE  │            │ controller-mgr  standby │  ← active-STANDBY
      │ etcd (member)           │            │ etcd (member)           │  ← distributed (Raft)
      └─────────────────────────┘            └─────────────────────────┘
```

- **kube-apiserver:** stateless → **active-active**. Put an LB (nginx/HAProxy) on `:6443`; point kubectl/kubelets at it.
- **scheduler & controller-manager:** two acting at once would double-schedule → **active-standby** via **leader election**. Whoever holds the **Lease** lock is active; if it dies, the standby takes over within ~the lease duration.
```yaml
--leader-elect=true                       # default
--leader-elect-lease-duration=15s         # hold the lock this long
--leader-elect-renew-deadline=10s         # active renews every 10s
--leader-elect-retry-period=2s            # standby retries every 2s
```

## (C) etcd quorum — the consensus math

**Two topologies:** **stacked** (etcd on the control-plane nodes — fewer servers; losing a node loses a member *and* a control-plane) vs **external etcd** (separate servers — more resilient, ~2× the boxes). Either way, only the **apiserver** talks to etcd (`--etcd-servers=<list>`).

etcd replicates via **Raft**: writes go through an elected leader and **commit only when a majority confirm**.

**Quorum = ⌊N/2⌋ + 1. Fault tolerance = N − quorum.**
| Nodes (N) | Quorum | Can lose |
|---|---|---|
| 1 | 1 | 0 |
| **2** | **2** | **0** ← no better than 1! |
| **3** | **2** | **1** |
| 4 | 3 | 1 |
| **5** | **3** | **2** |
| **7** | **4** | **3** |

**Odd numbers are preferred:** a partition of an even cluster can leave *both* halves short of quorum (6-node split 3/3 → neither has 4 → whole cluster stops). An odd cluster always keeps one side ≥ quorum. **Minimum HA = 3.** etcd uses **2379** (client) / **2380** (peer).

> 🎯 Remember **quorum = N/2 + 1** and that **2 nodes ≠ HA**. Prefer odd counts.

> **✅ Check yourself before Rung 4:** For a 5-node etcd cluster: what's the quorum, and how many members can fail before writes stop? Why would 6 nodes be a *worse* choice than 5 in some partition scenarios?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which part |
|---|---|---|
| **SPOF** | Single point of failure | The problem |
| **active-active** | All instances serve at once | apiserver |
| **active-standby** | One acts, others wait | scheduler / controller-mgr |
| **leader election / Lease** | The lock deciding who's active | scheduler / controller-mgr |
| **load balancer (:6443)** | Front door spreading apiserver traffic | Control-plane HA |
| **stacked etcd** | etcd co-located on control-plane nodes | etcd topology |
| **external etcd** | etcd on dedicated servers | etcd topology |
| **Raft** | The consensus algorithm etcd uses | etcd |
| **quorum / majority** | ⌊N/2⌋+1 members needed to commit | etcd availability |
| **fault tolerance** | N − quorum members you can lose | etcd availability |
| **split-brain** | Partition where neither side has quorum | Why odd wins |

**The unlock — three behaviors under replication:**
```
STATELESS (just add copies + LB):   kube-apiserver → active-active
SINGLETON (must not double-run):     scheduler, controller-manager → active-standby (lease)
CONSENSUS (needs a majority alive):  etcd → odd count, quorum = N/2+1
```

> **✅ Check yourself before Rung 5:** Sort into stateless / singleton / consensus: kube-apiserver, etcd, kube-controller-manager. Which one dictates you use an *odd* number of nodes?

---

# RUNG 5 — The Trace 🎬
### *Follow ONE node failure through a 3-node HA cluster*

**Trace — control-plane-2 dies (of 3 HA nodes):**
1. **apiserver:** the LB health-check fails for CP-2, so it stops routing there; CP-1 and CP-3 apiservers keep serving `:6443`. `kubectl` never notices. ✅ (active-active)
2. **scheduler / controller-manager:** if CP-2 held the **Lease**, it stops renewing; after ~lease-duration the standby on CP-1 or CP-3 grabs the lease and becomes active. Scheduling/reconciliation resume within seconds. ✅ (active-standby)
3. **etcd:** the cluster had 3 members; now 2 remain. Quorum = ⌊3/2⌋+1 = **2**, and 2 ≥ 2 → **writes still commit**. The cluster stays fully operational. ✅
4. You repair/replace CP-2; it rejoins etcd and re-registers. Back to 3, tolerance 1 again.

**Contrast — the same failure in a 2-node etcd:** quorum = 2; losing one leaves 1 < 2 → **writes stop cluster-wide**. That's why 2 nodes "isn't HA."

```
3-node HA, lose 1:  apiserver→LB reroutes ✓ · scheduler→standby takes lease ✓ · etcd 2/3 ≥ quorum(2) ✓  → cluster OK
2-node etcd, lose 1: etcd 1/2 < quorum(2) ✗  → writes halt
```

> **✅ Check yourself before Rung 6:** In the 3-node trace, which component recovered by *rerouting*, which by *taking over a lease*, and which by *still having a majority*?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **Single control plane** | **HA multi-master** | one SPOF vs redundant, LB-fronted |
| **active-active (apiserver)** | **active-standby (scheduler/ctrl-mgr)** | all serve vs one acts (avoid double-action) |
| **Stacked etcd** | **External etcd** | fewer servers, coupled failure vs more servers, isolated |
| **Odd node count** | **Even node count** | always a majority side vs risk of no-majority split |
| **3 members** | **5 members** | tolerate 1 vs tolerate 2 (more write latency) |

**When NOT to:** don't build HA for a learning/dev cluster (needless cost/complexity — minikube is fine); don't run **2** control-plane/etcd nodes thinking it's safer than 1; don't scale etcd past 5 without reason (every write waits on a bigger majority → slower).

**One-sentence "why this over that":**
> Front stateless apiservers with a load balancer, let scheduler/controller-manager fail over via leader election, and size etcd to an odd count ≥ 3 so a majority survives a failure — 2 buys you nothing.

> **✅ Check yourself before Rung 7:** A colleague proposes a 4-node etcd cluster "for extra safety." Explain why it tolerates the same number of failures as 3 while costing more.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — Leader election means exactly one active holder

> **My prediction:** "If I check the scheduler/controller-manager manifests and the Leases, I'll see `--leader-elect=true` and a single current holder — *because* only one of each may act at a time."

```bash
grep -- '--leader-elect' /etc/kubernetes/manifests/kube-scheduler.yaml
grep -- '--leader-elect' /etc/kubernetes/manifests/kube-controller-manager.yaml
kubectl get lease -n kube-system         # holderIdentity = the active instance
```
**Verify:** `=true`, and each Lease names one holder. On multi-master, that holder is on one specific node.

## Prediction 2 — etcd reports its members and one leader

> **My prediction:** "If I query etcd membership, a single-node lab shows one member that IS LEADER; an HA cluster shows N members with exactly one leader — *because* Raft elects a single leader for writes."

```bash
ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key
ETCDCTL_API=3 etcdctl endpoint status --write-out=table --endpoints=... --cacert=... --cert=... --key=...
```
**Verify:** the status table has exactly one `IS LEADER=true`.

## Prediction 3 — Compute fault tolerance from N

> **My prediction:** "For N members, tolerance = N − (⌊N/2⌋+1). So 3→1, 4→1, 5→2, 7→3 — *because* you must keep a majority."

```
N=3: quorum 2, lose 1     N=4: quorum 3, lose 1 (same as 3!)
N=5: quorum 3, lose 2     N=7: quorum 4, lose 3
```
**Verify:** 4 tolerates the same as 3 — the concrete reason to pick odd. Say it back for 5 and 7 without the table.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> HA removes single points of failure by running apiservers active-active behind a load balancer and scheduler/controller-manager active-standby via leader election, while etcd — a consensus store — needs an odd number of members (≥3) because it only commits when a majority agree.

**Explain it to a beginner in 3 sentences:**
> 1. One control-plane node is a single point of failure, so production runs several, with a load balancer in front of the API servers.
> 2. The API servers all work at once, but only one scheduler and one controller-manager act at a time (the others wait to take over).
> 3. etcd stores everything and only accepts writes when more than half its members agree, so you run an odd number — at least three — because two would stop the moment one fails.

**Which rung to revisit hands-on?** Rung 3C + Prediction 3 — the **quorum math** and the **2-node/even-node trap** are the memorable, testable core of this section.

---

## 🎯 CKA exam tips & quick notes

- **apiserver = active-active** behind an LB (`:6443`); **scheduler & controller-manager = active-standby** via `--leader-elect`.
- **etcd quorum = N/2 + 1**, **fault tolerance = N − quorum**, **odd preferred**, **min 3** (2 gives nothing).
- **Stacked** (etcd on control plane) vs **external etcd**; apiserver reaches etcd via `--etcd-servers`.
- kubeadm taints control-plane nodes to keep workloads off (removable).
- Don't memorize scale ceilings; **do** internalize the quorum math.

## 📌 Command cheat sheet
```bash
grep -- '--leader-elect' /etc/kubernetes/manifests/kube-scheduler.yaml
kubectl get lease -n kube-system                        # who holds the lease
ETCDCTL_API=3 etcdctl member list --endpoints=... --cacert=... --cert=... --key=...
ETCDCTL_API=3 etcdctl endpoint status --write-out=table --endpoints=... ...
# quorum = floor(N/2)+1 ;  tolerance = N - quorum ;  prefer ODD, min 3
```

---

## Related sections

- [Section 10 — Install Kubernetes the Kubeadm Way](10-install-kubernetes-kubeadm-way.md) — bootstrapping the cluster you designed.
- [Section 5 — Cluster Maintenance](05-cluster-maintenance.md) — etcd backup/restore + upgrades on this design.
- [Section 1 — Core Concepts](01-core-concepts.md) — the control-plane components you're making HA.
- [Section 6 — Security](06-security.md) — the PKI each etcd + apiserver instance needs.
- [../../Networking/18-load-balancing.md](../../Networking/18-load-balancing.md) — the load balancer fronting the apiservers.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If the single control-plane node dies, what *keeps* working and what *stops*?

**A:** Running pods **keep serving** — the workloads on worker nodes don't depend on the control plane moment to moment. What **stops** is everything requiring new decisions: no new scheduling, no self-healing (a crashed pod won't be replaced), and no `kubectl` — the API server is down. And because etcd lived on that node, the cluster's entire memory (its state store) is unavailable until the control plane is back.

### Before Rung 3
**Q:** Why is a 2-member etcd cluster no more fault-tolerant than a 1-member one? State the quorum for each.

**A:** Quorum = ⌊N/2⌋+1. For 1 member, quorum = 1; for 2 members, quorum = ⌊2/2⌋+1 = **2** — both members must be alive to commit a write. So losing one member of a 2-node cluster leaves 1 < 2 and writes stop cluster-wide, exactly like losing the only member of a 1-node cluster: fault tolerance is **0** in both cases. Adding the second member bought no real fault tolerance — the minimum for real HA is 3 (quorum 2, tolerates 1).

### Before Rung 4
**Q:** For a 5-node etcd cluster: what's the quorum, and how many members can fail before writes stop? Why would 6 nodes be a *worse* choice than 5 in some partition scenarios?

**A:** For N=5, quorum = ⌊5/2⌋+1 = **3**, so fault tolerance = 5 − 3 = **2** — writes continue until a third member fails. 6 nodes (quorum 4) still tolerates only 2 failures, and it adds a partition risk odd counts avoid: a 6-node cluster can split **3/3**, leaving *neither* half with the 4 needed for quorum, so the whole cluster stops. An odd cluster always leaves one side with a majority, which is why odd is preferred.

### Before Rung 5
**Q:** Sort into stateless / singleton / consensus: kube-apiserver, etcd, kube-controller-manager. Which one dictates you use an *odd* number of nodes?

**A:** **kube-apiserver → stateless**: just add copies behind a load balancer, active-active. **kube-controller-manager → singleton**: it must not double-run, so it's active-standby via leader election on a Lease (the scheduler behaves the same way). **etcd → consensus**: it needs a majority of members alive to commit writes. It's **etcd** that dictates the odd node count — quorum = ⌊N/2⌋+1 means even counts add no tolerance and risk a no-majority split.

### Before Rung 6
**Q:** In the 3-node trace, which component recovered by *rerouting*, which by *taking over a lease*, and which by *still having a majority*?

**A:** The **kube-apiserver** recovered by rerouting — the load balancer's health check dropped CP-2 and sent traffic to the remaining active-active apiservers, so kubectl never noticed. The **scheduler and controller-manager** recovered by lease takeover — the dead node stopped renewing the Lease, and after ~the lease duration a standby grabbed it and became active. **etcd** recovered by still having a majority — 2 of 3 members remained, and 2 ≥ quorum (⌊3/2⌋+1 = 2), so writes kept committing.

### Before Rung 7
**Q:** A colleague proposes a 4-node etcd cluster "for extra safety." Explain why it tolerates the same number of failures as 3 while costing more.

**A:** For N=4, quorum = ⌊4/2⌋+1 = **3**, so fault tolerance = 4 − 3 = **1** — exactly the same one-failure tolerance as a 3-node cluster (quorum 2, lose 1). The fourth node therefore adds cost, an extra server every write must involve, and a new risk: a 2/2 partition leaves neither half with 3 members, so the whole cluster stops — a split an odd cluster can't suffer. For "extra safety," the right move is to go to **5** (quorum 3, tolerates 2), not 4.
