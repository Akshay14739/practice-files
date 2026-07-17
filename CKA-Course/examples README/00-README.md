# 🧪 CKA — Examples Edition (What · Pain · How · 3+ Hands-on Examples)

> The full CKA course, section by section, in a **practice-first format**: every topic & subtopic answers **What is it** → **What pain does it solve & why this** → **How exactly it works** (machinery, under-the-hood, vocabulary maps) → **at least 3 hands-on coding examples** covering different real scenarios. Source: the course transcripts in [../Transcripts/](../Transcripts/).
>
> **Companion set:** the [../README/](../README/00-README.md) folder holds the same course as **Learning Ladder** climbs (Pain → One Idea → Machinery → Trace → Prediction Test). Use *that* to build the mental model, use *this* as your hands-on drill book.

## 📚 The sections

| # | Section | Topics covered |
|---|---|---|
| 01 | [Core Concepts](01-core-concepts.md) | architecture, runtimes/crictl, etcd, pods, RS, deployments, services, namespaces, imperative-vs-declarative |
| 02 | [Scheduling](02-scheduling.md) | manual scheduling, labels, taints/tolerations, affinity, resources, DaemonSets, static pods, priority, schedulers, admission |
| 03 | [Logging & Monitoring](03-logging-monitoring.md) | Metrics Server / `kubectl top`, `kubectl logs` |
| 04 | [Application Lifecycle Mgmt](04-application-lifecycle-management.md) | rollouts/rollbacks, command/args, env/CM/Secrets, encryption at rest, scaling, init/sidecar |
| 05 | [Cluster Maintenance](05-cluster-maintenance.md) | drain/cordon, version skew, kubeadm upgrade, etcd backup/restore |
| 06 | [Security](06-security.md) | TLS/PKI, cert locations, CSR API, kubeconfig, RBAC, service accounts, image security, security contexts, network policies |
| 07 | [Storage](07-storage.md) | volumes, PV/PVC binding, reclaim policies, StorageClasses |
| 08 | [Networking](08-networking.md) | ports, CNI, kube-proxy, CoreDNS, Ingress |
| 09 | [Design & Install](09-design-and-install-kubernetes-cluster.md) | design choices, HA control plane, etcd quorum |
| 10 | [Kubeadm Install](10-install-kubernetes-kubeadm-way.md) | prereqs, `kubeadm init`, CNI, `kubeadm join` |
| 11 | [Helm Basics](11-helm-basics.md) | charts/releases/revisions, Helm 2 vs 3, commands, values |
| 12 | [Kustomize Basics](12-kustomize-basics.md) | base/overlays, kustomization.yaml, transformers, patches |
| 13 | [Troubleshooting](13-troubleshooting.md) | application / control-plane / worker-node / network failures |

## 🎯 How to use this set

1. **Do the examples, don't read them.** Spin up a lab (killercoda / minikube / kind) and type every block; each ends with a **Verify** line — check it.
2. Per topic, the order mirrors how you should think: *what → why it exists → how it works → hands on*. If an example surprises you, reread that topic's **How** and find what your model missed.
3. Each file's **➕ Added** section covers gaps the transcripts skip (probes, PDBs, Gateway API, symptom→layer maps…).
4. Exam-strategy material (domain weights, speed kit, 3-week plan) lives in the ladder set's [index](../README/00-README.md) — this set is purely for building hands-on reflexes.
