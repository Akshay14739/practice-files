# 🚢 CKA Study Notes — Complete Course, Section by Section

> The entire **Certified Kubernetes Administrator** course, rebuilt on the **[Learning Ladder](../../Learning-Ladder-Template.md)** so you can skip the videos and actually *understand* — not memorize — Kubernetes. Every section climbs the same 8 rungs, leading with *why* and the *machinery* and putting the commands last. Source: [Mumshad's CKA course](https://www.udemy.com/course/certified-kubernetes-administrator-with-practice-tests/).

## 🪜 How each section is built (the Learning Ladder)

Each file climbs the same rungs — read them in order and answer each **✅ Check yourself** out loud before climbing on:

| Rung | What it does |
|---|---|
| **0 Setup** | what you're learning & why it's on the CKA |
| **1 The Pain** | the problem that forced this to exist |
| **2 The One Idea** | the single sentence to memorize — everything derives from it |
| **3 The Machinery** ⚙️ | how it *actually* works, with ASCII diagrams (the most important rung) |
| **4 Vocabulary Map** | every scary term pinned to a part of the machinery |
| **5 The Trace** | one concrete action followed end-to-end |
| **6 The Contrast** | how it differs from the alternative, and when *not* to use it |
| **7 Prediction Test** 🧪 | the commands — as "if I do X, then Y, because [mechanism]" predictions you run & verify |
| **🎁 Capstone** | compress it to one sentence; find your shaky rung |

Then each file closes with **🎯 CKA exam tips** and a **📌 command cheat sheet** for the exam.

**How to use these:** climb a section rung by rung, do its Rung-7 predictions on a live cluster (killercoda/minikube/kind) *before* reading the outcome, then answer the check-yourself questions. The test of readiness is that you can *predict* what a command does and do it fast — [Istio_Learning_Ladder.md](../../Istio_Learning_Ladder.md) is the gold-standard example of the same method.

---

## 📚 The curriculum

| # | Section | Covers | Exam weight |
|---|---|---|---|
| 01 | [Core Concepts](01-core-concepts.md) | architecture, pods, ReplicaSets/Deployments, Services, namespaces, imperative vs declarative | ⭐⭐⭐ |
| 02 | [Scheduling](02-scheduling.md) | manual sched, taints/tolerations, node affinity, resources, DaemonSets, static pods, priority, admission | ⭐⭐⭐ |
| 03 | [Logging & Monitoring](03-logging-monitoring.md) | metrics-server, `kubectl top`, `kubectl logs` | ⭐ |
| 04 | [Application Lifecycle Mgmt](04-application-lifecycle-management.md) | rollouts/rollback, commands/args, env, ConfigMaps, Secrets, multi-container/init/sidecar | ⭐⭐⭐ |
| 05 | [Cluster Maintenance](05-cluster-maintenance.md) | drain/cordon, version skew, **kubeadm upgrade**, **etcd backup/restore** | ⭐⭐⭐ |
| 06 | [Security](06-security.md) | TLS/PKI, CSR API, kubeconfig, **RBAC**, service accounts, image secrets, security contexts, NetworkPolicy | ⭐⭐⭐ |
| 07 | [Storage](07-storage.md) | volumes, **PV/PVC**, access modes, reclaim policies, StorageClasses | ⭐⭐ |
| 08 | [Networking](08-networking.md) | ports, **CNI**, kube-proxy, **CoreDNS**, **Ingress** | ⭐⭐⭐ |
| 09 | [Design & Install a Cluster](09-design-and-install-kubernetes-cluster.md) | HA topologies, leader election, **etcd quorum** | ⭐⭐ |
| 10 | [Install the Kubeadm Way](10-install-kubernetes-kubeadm-way.md) | runtime/cgroups, `kubeadm init`, CNI, `kubeadm join` | ⭐⭐ |
| 11 | [Helm Basics](11-helm-basics.md) | charts, releases, install/upgrade/rollback *(supplementary)* | ⭐ |
| 12 | [Kustomize Basics](12-kustomize-basics.md) | base/overlays, transformers, patches *(on the exam)* | ⭐⭐ |
| 13 | [Troubleshooting](13-troubleshooting.md) | app / control-plane / worker-node / network failures | ⭐⭐⭐⭐ |

**Added beyond the course flow where useful:** cross-links to the sibling **Linux** and **Networking** deep-dive guides (`../../Linux/`, `../../Networking/`) for the primitives under the hood (namespaces, iptables, TLS, DNS).

---

## 🎯 The CKA exam — what to expect

- **Format:** 100% **performance-based** — ~15–20 hands-on tasks on real clusters, **2 hours**, remotely proctored.
- **Passing score:** **66%**. Partial credit exists — bank easy points, flag hard ones, move on.
- **Domains & weights** (current curriculum):
  | Domain | Weight | Mapped sections |
  |---|---|---|
  | Cluster Architecture, Installation & Configuration | **25%** | 1, 5, 6, 9, 10 |
  | Workloads & Scheduling | **15%** | 1, 2, 4 |
  | Services & Networking | **20%** | 1, 6, 8 |
  | Storage | **10%** | 7 |
  | **Troubleshooting** | **30%** | 3, 13 |
- **Allowed docs:** the official **kubernetes.io/docs** (+ `/blog`), **helm.sh/docs**, and Kustomize docs — one browser tab. Learn to *search the docs fast* and copy YAML samples.
- You work across **multiple clusters** — always run the given `kubectl config use-context <ctx>` first.

---

## ⚡ Exam-day speed kit (set this up in the first 60 seconds)

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"     # k run x --image=nginx $do > x.yaml
export now="--force --grace-period=0"    # k delete pod x $now
source <(kubectl completion bash)        # tab completion
complete -F __start_kubectl k            # completion for the alias too
# set vim: 2-space indent, expandtab   → ~/.vimrc:  set et ts=2 sw=2
```
**The universal workflow:** **generate YAML, never hand-type it.**
```bash
k run nginx --image=nginx $do > pod.yaml         # then edit + k apply -f
k create deploy web --image=nginx --replicas=3 $do > d.yaml
k expose deploy web --port=80 $do > svc.yaml
k create role/rolebinding/clusterrole ... $do    # RBAC fast
k explain pod.spec.containers --recursive        # forgot a field? no browser needed
```

---

## 🧭 Cross-cutting tips (worth more than any single section)

1. **Read the task's context switch.** Every question tells you which cluster — `kubectl config use-context` first, every time.
2. **Imperative first, YAML only when forced.** Simple pod/deploy/service/RBAC → imperative + `$do`. Complex (multi-container, volumes, probes) → generate + edit + `apply`.
3. **Know the file locations cold:** static pods `/etc/kubernetes/manifests/`, PKI `/etc/kubernetes/pki`, kubelet `/var/lib/kubelet/config.yaml` + `/etc/kubernetes/kubelet.conf`, etcd certs `/etc/kubernetes/pki/etcd`.
4. **Know the ports cold:** apiserver **6443**, kubelet **10250**, etcd **2379/2380**, scheduler **10259**, controller-mgr **10257**, NodePort **30000–32767**, CoreDNS **53**.
5. **Troubleshooting is 30%** — internalize Section 13's checklists (map→endpoints→logs; static-pod manifests; kubelet service→logs→config).
6. **`kubectl describe` + `kubectl logs --previous`** solve most "why is it broken" tasks.
7. **etcd backup/restore and a cluster upgrade** are near-guaranteed — practice each end-to-end until reflexive (Section 5).
8. Don't over-verify; if a task validates, move on. Flag the two hardest for the end.

---

## 🗓️ A 3-week study plan

```
WEEK 1 — Foundations & workloads
  Day 1  01 Core Concepts        Day 2  02 Scheduling
  Day 3  04 App Lifecycle        Day 4  03 Logging + 07 Storage
  Day 5  redo all Rung-7 labs imperatively (speed)

WEEK 2 — Cluster ops & networking (the heavy weights)
  Day 1  06 Security (RBAC + certs)   Day 2  08 Networking (CNI/CoreDNS/Ingress)
  Day 3  05 Cluster Maintenance (upgrade + etcd)   Day 4  09 Design + 10 Kubeadm
  Day 5  12 Kustomize + 11 Helm

WEEK 3 — Troubleshooting & exam simulation
  Day 1-2  13 Troubleshooting (break & fix clusters repeatedly)
  Day 3    full mock exam under 2h timer (killer.sh)
  Day 4    review misses; re-drill weak cheat sheets
  Day 5    second mock; polish speed kit + doc-search muscle
```

---

## 🐧 Under the hood

Every Kubernetes construct is a Linux/networking primitive with a fancy name — pods are namespaces + cgroups, Services are iptables, DNS is CoreDNS, certs are PKI. If a section's *machinery* feels fuzzy, drop to the sibling deep-dive guides: [../../Linux/](../../Linux/00-README.md) and [../../Networking/](../../Networking/00-README.md). Master the primitives once and CKA stops being memorization — you can *derive* the answer and *debug* anything.

**Now go break some clusters and fix them. That's the exam. Good luck. 🍀**
