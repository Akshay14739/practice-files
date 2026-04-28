# CKA Section: Kubernetes Core Concepts
> **Complete Study Guide — Replaces Video Lectures**

---

## Table of Contents
1. [Section Objective](#section-objective)
2. [Cluster Architecture Overview](#1-cluster-architecture-overview)
3. [Container Runtimes & CLI Tools](#2-container-runtimes--cli-tools)
4. [etcd](#3-etcd)
5. [Pods](#4-pods)
6. [ReplicaSets](#5-replicasets)
7. [Deployments](#6-deployments)
8. [Services](#7-services)
9. [Namespaces](#8-namespaces)
10. [Imperative vs Declarative](#9-imperative-vs-declarative)
11. [How kubectl apply Works Internally](#10-how-kubectl-apply-works-internally)
12. [kubectl explain & kubectl api-resources](#11-kubectl-explain--kubectl-api-resources)
13. [Complete YAML Reference Snippets](#complete-yaml-reference-snippets)
14. [Exam Quick-Reference Cheat Sheet](#exam-quick-reference-cheat-sheet)

---

## Section Objective

> **Goal:** Understand the fundamental building blocks of a Kubernetes cluster — its architecture, components, and the API primitives (Pods, ReplicaSets, Deployments, Services, Namespaces) — so you can deploy, manage, and troubleshoot applications on a Kubernetes cluster.

---

## 1. Cluster Architecture Overview

### The Ship Analogy (Mental Model)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        KUBERNETES CLUSTER                            │
│                                                                      │
│  ┌─────────────────────────┐      ┌──────────────────────────────┐  │
│  │      MASTER NODE        │      │        WORKER NODES          │  │
│  │     (Control Ship)      │◄────►│       (Cargo Ships)          │  │
│  │                         │      │                              │  │
│  │  ┌───────────────────┐  │      │  ┌────────────────────────┐  │  │
│  │  │       etcd        │  │      │  │        kubelet         │  │  │
│  │  │  (data store)     │  │      │  │  (captain of the ship) │  │  │
│  │  └───────────────────┘  │      │  └────────────────────────┘  │  │
│  │  ┌───────────────────┐  │      │  ┌────────────────────────┐  │  │
│  │  │  kube-scheduler   │  │      │  │      kube-proxy        │  │  │
│  │  │  (crane/placer)   │  │      │  │  (network rules)       │  │  │
│  │  └───────────────────┘  │      │  └────────────────────────┘  │  │
│  │  ┌───────────────────┐  │      │  ┌────────────────────────┐  │  │
│  │  │  kube-apiserver   │  │      │  │   container runtime    │  │  │
│  │  │  (central hub)    │  │      │  │  (Docker/containerd)   │  │  │
│  │  └───────────────────┘  │      │  └────────────────────────┘  │  │
│  │  ┌───────────────────┐  │      │  ┌────────────────────────┐  │  │
│  │  │  controller-mgr   │  │      │  │    Pods (containers)   │  │  │
│  │  │  (office depts)   │  │      │  │    your applications   │  │  │
│  │  └───────────────────┘  │      │  └────────────────────────┘  │  │
│  └─────────────────────────┘      └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Control Plane Components (Master Node)

#### etcd
- Distributed, reliable key-value store
- Stores ALL cluster state: nodes, pods, configs, secrets, roles, role bindings
- Every `kubectl get` reads from etcd
- Every change (add node, deploy pod, create replica set) is written to etcd first
- **A change is only "complete" once stored in etcd**

#### kube-scheduler
- Decides *which node* a pod goes on — does **NOT** place it (that's kubelet's job)
- **Phase 1 — Filter:** removes nodes that don't meet requirements (CPU/memory, taints, tolerations, affinity rules, node capacity)
- **Phase 2 — Rank:** scores remaining nodes using a priority function (e.g., node with most free CPU after placing pod gets highest score)

#### kube-controller-manager
- Runs all controllers as a single process
- **Node Controller:** checks node health every 5s; marks unreachable after 40s grace period; evicts pods and reprovisions on healthy nodes after 5 min
- **Replication Controller:** ensures desired pod count is always running; if pod dies, creates a new one
- Many more controllers: deployment, endpoint, namespace, job, etc.
- All "intelligence" built into Kubernetes objects (Deployments, Services, etc.) is implemented through these controllers

#### kube-apiserver
- The **only** component that talks directly to etcd
- Central hub: authenticates → validates → processes all requests
- All other components (scheduler, kubelet, controllers) communicate *through* the API server
- Exposes the Kubernetes API for external users and internal components
- Can be reached via `kubectl` or direct HTTP POST requests

---

### Worker Node Components

#### kubelet
- Agent running on every worker node
- **Must be installed manually** — kube-adm does NOT deploy kubelet automatically (unlike other components)
- Registers node with the Kubernetes cluster
- Creates/destroys pods as instructed by API server via container runtime
- Sends periodic status reports back to API server

#### kube-proxy
- Runs on every node
- Deployed as a **DaemonSet** by kube-adm (one pod per node always)
- Maintains iptables rules to route traffic to the correct pod when a Service is accessed
- Example: creates iptables rule forwarding traffic from Service IP `10.96.0.1` → Pod IP `10.32.0.15`

#### Container Runtime
- Software that actually runs containers
- Must be installed on **ALL nodes** including master nodes
- Options: Docker, containerd, CRI-O, Rocket
- Kubernetes supports any CRI-compliant runtime

---

### Complete Architecture Flow — Pod Creation Example

```
                         ┌───────────────────────────────────────────────────┐
                         │               MASTER NODE                          │
                         │                                                     │
  User                   │  ┌──────────────┐          ┌─────────────────┐    │
  kubectl create pod ───►│  │ kube-apiserver│─────────►│      etcd       │    │
                         │  │              │◄─────────│  (stores pod    │    │
                         │  │ 1. Authn     │  stores  │   object, no   │    │
                         │  │ 2. Authz     │          │   node yet)    │    │
                         │  │ 3. Validates │          └─────────────────┘    │
                         │  └──────┬───────┘                                 │
                         │         │  monitors for unscheduled pods          │
                         │  ┌──────▼───────┐                                 │
                         │  │ kube-scheduler│                                 │
                         │  │              │                                  │
                         │  │ 4. Picks     │                                  │
                         │  │    best node │                                  │
                         │  └──────┬───────┘                                 │
                         │         │  tells apiserver which node              │
                         │  ┌──────▼───────┐          ┌─────────────────┐    │
                         │  │ kube-apiserver│─────────►│      etcd       │    │
                         │  │              │  updates  │  (node assigned)│    │
                         │  └──────┬───────┘          └─────────────────┘    │
                         └─────────┼─────────────────────────────────────────┘
                                   │
                                   │ sends pod spec to kubelet on chosen node
                                   ▼
                         ┌─────────────────────────────────────────────────┐
                         │               WORKER NODE                        │
                         │                                                   │
                         │  ┌──────────────┐    ┌──────────────────────┐   │
                         │  │   kubelet    │───►│  container runtime   │   │
                         │  │              │    │  (pulls image,       │   │
                         │  │ 5. Creates   │    │   starts container)  │   │
                         │  │    the Pod   │    └──────────────────────┘   │
                         │  └──────┬───────┘                               │
                         │         │  reports status back                   │
                         └─────────┼───────────────────────────────────────┘
                                   │
                                   ▼
                              kube-apiserver → etcd (status updated)
```

---

## 2. Container Runtimes & CLI Tools

### History: Why This Matters

```
Timeline of Docker & Kubernetes
────────────────────────────────────────────────────────────────────────►
│
2013        │  Docker created — dominant container tool
            │  Kubernetes built specifically FOR Docker
            │  Kubernetes ONLY supported Docker
            │
~2016       │  CRI (Container Runtime Interface) introduced
            │  Other runtimes (Rocket, etc.) now supported via CRI
            │  Docker did NOT support CRI (built before CRI existed)
            │  Kubernetes introduced "Dockershim" — hacky workaround
            │  to keep Docker working outside of CRI
            │
~2020       │  containerd extracted from Docker as standalone project
            │  containerd is CRI-compatible → works directly with K8s
            │
v1.24       │  Dockershim REMOVED from Kubernetes
(2022)      │  Docker no longer supported as runtime
            │  Docker images still work (OCI image spec compliant)
            │
Now         │  containerd / CRI-O are the standard runtimes
            │
────────────────────────────────────────────────────────────────────────►
```

#### Key Concepts:
- **CRI (Container Runtime Interface):** Standard interface so any OCI-compliant runtime can plug into Kubernetes
- **OCI (Open Container Initiative):**
  - **Image Spec** — defines how a container image should be built
  - **Runtime Spec** — defines standards for how a container runtime should be developed
- **Docker images still work** — Docker followed OCI image spec, so images are runtime-agnostic and work with containerd
- **containerd** — originally part of Docker, now a standalone CNCF graduated project; CRI-compatible; can be installed without Docker

#### What Docker Is (Multiple Tools Together):
```
Docker = Docker CLI
       + Docker API
       + Build tools (image building)
       + Volume support
       + Auth/Security
       + Runc (container runtime)
       + containerd (daemon managing runc)
```
- Kubernetes only needed `containerd` → deprecated the rest

---

### CLI Tool Comparison

| Tool | Made By | Works With | Purpose | Use in Production? |
|------|---------|-----------|---------|-------------------|
| `ctr` | containerd community | containerd only | Debugging only, very limited | ❌ No |
| `nerdctl` | containerd community | containerd only | Docker-like CLI, full-featured | ✅ Yes |
| `crictl` | Kubernetes community | ALL CRI runtimes | Debugging & inspecting runtimes | ⚠️ Debugging only |

#### `ctr` — Basic Examples (avoid in production)
```bash
# Pull an image
ctr images pull docker.io/library/redis:latest

# Run a container
ctr run docker.io/library/redis:latest redis
```

#### `nerdctl` — Docker-like CLI (recommended replacement)
```bash
# Replace 'docker' with 'nerdctl' for most commands
nerdctl run nginx
nerdctl run -p 8080:80 nginx
nerdctl ps
nerdctl images
```
- Supports: encrypted container images, lazy pulling, P2P image distribution, image signing/verifying, Kubernetes namespaces

#### `crictl` — Kubernetes Debugging Tool
```bash
crictl ps                          # List containers (like docker ps)
crictl images                      # List images
crictl logs <container-id>         # View logs
crictl exec -it <container-id> sh  # Shell into container
crictl pods                        # List pods (aware of pods unlike Docker)
```
- Works with the Kubelet — containers created via `crictl` manually will be **deleted by kubelet** (kubelet doesn't know about them)
- Set runtime endpoint if needed:
```bash
crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps
# OR
export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
```
- Default endpoint search order: Dockershim → containerd → CRI-O → cri-dockerd

#### Summary Diagram:
```
                ┌─────────────────────────────────────────┐
                │           CLI Tool Decision              │
                └─────────────────────────────────────────┘
                                    │
              ┌─────────────────────┼────────────────────┐
              │                     │                     │
              ▼                     ▼                     ▼
           ctr                  nerdctl               crictl
    ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
    │ containerd   │      │ containerd   │      │ ALL CRI      │
    │ community    │      │ community    │      │ runtimes     │
    │              │      │              │      │ K8s community│
    │ Debug only   │      │ General use  │      │ Debug only   │
    │ Very limited │      │ Docker-like  │      │ K8s-aware    │
    │              │      │ Full feature │      │ (knows pods) │
    └──────────────┘      └──────────────┘      └──────────────┘
    AVOID in prod         USE for containers     USE for K8s
                          on containerd          troubleshooting
```

---

## 3. etcd

### What is a Key-Value Store?

| Storage Type | Schema | Complex Queries | Flexibility | Best For |
|---|---|---|---|---|
| Relational (SQL) | Strict schema | Yes (JOIN, etc.) | Low — adding column affects all rows | Structured data |
| Document (JSON) | Optional | Limited | High — each doc independent | Semi-structured data |
| **Key-Value** | None | No | Very High — store anything | Simple fast lookup |

- etcd stores: `key → value`
  - Simple: `name → John`, `age → 45`, `location → New York`
  - Complex: `user:johndoe → { entire JSON document }`
- Adding/changing one key never affects others

### etcd Release History (Important for CLI commands)

| Version | Date | Key Change |
|---|---|---|
| v0.1 | Aug 2013 | Initial release |
| v2.0 | Feb 2015 | Raft consensus redesigned; 1000+ writes/sec |
| v3.0 | Jan 2017 | Major performance improvements; **API changed** |
| Nov 2018 | — | CNCF incubator project |
| Nov 2020 | — | CNCF graduated project |
| v3.5 | Jun 2021 | Latest major release |

#### API Version Command Differences:

| Action | etcdctl v2 | etcdctl v3 |
|---|---|---|
| Store value | `etcdctl set key1 value1` | `etcdctl put key1 value1` |
| Get value | `etcdctl get key1` | `etcdctl get key1` |
| Delete value | `etcdctl rm key1` | `etcdctl delete key1` |
| Transactions | Not supported | Supported |

```bash
# Check which version/API you're on
etcdctl version

# Set API version to v3
export ETCDCTL_API=3

# Basic operations
etcdctl put key1 value1        # Store
etcdctl get key1               # Retrieve
etcdctl delete key1            # Delete
```

### etcd in Kubernetes

- Listens on port **2379** by default
- `advertise-client-urls` config option tells kube-apiserver where to reach etcd
- Stores data under `/registry/` directory structure:
  ```
  /registry/
  ├── minions/       (nodes)
  ├── pods/
  ├── replicasets/
  ├── deployments/
  ├── secrets/
  ├── roles/
  └── rolebindings/
  ```

#### Setup Differences:

| Setup Method | How etcd is deployed |
|---|---|
| From scratch | Download binary, install manually, configure as systemd service on master |
| kube-adm | Deployed automatically as a pod in `kube-system` namespace |

#### Listing all Kubernetes keys in etcd:
```bash
kubectl exec etcd-master -n kube-system -- sh -c \
  "ETCDCTL_API=3 etcdctl get / \
  --prefix \
  --keys-only \
  --limit=10 \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key"
```
- `ETCDCTL_API=3` — use v3 API (required for `get` command syntax)
- `get /` — start from root key
- `--prefix` — get all keys that start with `/`
- `--keys-only` — show only key names, not values
- `--limit=10` — return at most 10 results
- `--cacert` — CA certificate to verify etcd server identity
- `--cert` — client certificate for authentication
- `--key` — client private key for authentication

> **Why TLS flags?** etcd secures communication with TLS. These certificates are auto-created by kube-adm and located at `/etc/kubernetes/pki/etcd/`

#### High Availability etcd:
- Multiple master nodes → multiple etcd instances
- Must configure `--initial-cluster` option so all etcd instances know each other:
```
--initial-cluster peer1=https://IP1:2380,peer2=https://IP2:2380
```

---

## 4. Pods

### What is a Pod?

```
┌─────────────────────── Node ─────────────────────────┐
│                                                        │
│  ┌──────────────────── Pod ──────────────────────┐   │
│  │                                                │   │
│  │  ┌──────────────────────────────────────────┐ │   │
│  │  │           Container (nginx)              │ │   │
│  │  │           your application               │ │   │
│  │  └──────────────────────────────────────────┘ │   │
│  │                                                │   │
│  │  ┌──────────────────────────────────────────┐ │   │
│  │  │     Helper Container (optional)          │ │   │
│  │  │     shares: network, storage, lifecycle  │ │   │
│  │  └──────────────────────────────────────────┘ │   │
│  │                                                │   │
│  │  Shared resources:                             │   │
│  │  • Same network namespace (localhost)          │   │
│  │  • Same storage volumes                        │   │
│  │  • Same lifecycle (created & destroyed together)│  │
│  └────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────── ┘
```

- **Smallest deployable unit** in Kubernetes — cannot deploy a container directly
- Usually **1 container per pod** (the standard pattern)
- **Multi-container pods** are rare — used for sidecar/helper pattern (e.g., log processor alongside main app)
- To **scale up:** create new pods, not new containers inside an existing pod
- To **scale down:** delete existing pods

#### Scaling Illustrated:
```
Initial State:                    Scale Up (more users):
┌──────────────┐                 ┌──────┐ ┌──────┐
│  Node        │                 │ Node │ │ Node │ (new node added)
│  ┌────────┐  │                 │ ┌──┐ │ │ ┌──┐ │
│  │  Pod   │  │      ────►      │ │Po│ │ │ │Po│ │
│  │ (app)  │  │                 │ └──┘ │ │ └──┘ │
│  └────────┘  │                 │ ┌──┐ │ └──────┘
└──────────────┘                 │ │Po│ │
                                 │ └──┘ │
                                 └──────┘
  1 pod, 1 node                  3 pods across 2 nodes
```

### Why Kubernetes Uses Pods (Not Bare Containers)

Without pods, you'd have to manually:
- Track which helper containers belong to which app containers
- Set up networking/links between related containers
- Share volumes between containers manually
- Monitor and kill helper containers when app containers die
- Recreate helpers when new app containers deploy

**With pods:** Kubernetes handles all of this automatically

### YAML API Version Reference

| Object | apiVersion |
|---|---|
| Pod | `v1` |
| Service | `v1` |
| ReplicationController | `v1` |
| Namespace | `v1` |
| ReplicaSet | `apps/v1` |
| Deployment | `apps/v1` |

### Pod YAML — Complete Syntax

```yaml
apiVersion: v1          # Version of Kubernetes API for this object type
kind: Pod               # Type of object (case-sensitive — capital P)
metadata:               # Data ABOUT the object — only K8s-defined fields allowed here
  name: myapp-pod       # Name of the pod — string value
  labels:               # Dictionary of key-value pairs — you choose the keys/values
    app: myapp          # Used for grouping, filtering, and selecting pods
    tier: frontend      # Can add as many labels as needed
spec:                   # Specification — defines what's INSIDE the object
  containers:           # List/array — pods can have multiple containers
  - name: nginx         # Name of THIS container inside the pod
    image: nginx        # Docker image name (pulled from Docker Hub by default)
    ports:
    - containerPort: 80 # Port the container listens on (informational)
```

#### YAML Indentation Rules:
- Use **2 spaces** (not tabs) — tabs cause errors
- Children must have MORE spaces than their parent
- Siblings must have EQUAL spaces
- `containers` is a list — each item starts with `-`

### Pod Commands

```bash
# Create pod imperatively (quickest)
kubectl run nginx --image=nginx

# Create from YAML file
kubectl create -f pod-definition.yaml

# List all pods (default namespace)
kubectl get pods

# Detailed view with node assignment
kubectl get pods -o wide

# Full detailed info — events, containers, images, node, labels
kubectl describe pod myapp-pod

# Delete a pod
kubectl delete pod myapp-pod

# Generate YAML without creating (exam tip)
kubectl run nginx --image=nginx --dry-run=client -o yaml

# Generate YAML and save to file
kubectl run nginx --image=nginx --dry-run=client -o yaml > pod.yaml
```

---

## 5. ReplicaSets

### Why ReplicaSets Are Needed

```
Without ReplicaSet:              With ReplicaSet:
┌─────────────┐                  ┌─────────────────────────────┐
│    Pod      │                  │   ReplicaSet (desired: 3)   │
│   crashes   │                  │  ┌───────┐┌───────┐┌──────┐ │
│      ↓      │                  │  │ Pod 1 ││ Pod 2 ││Pod 3 │ │
│  App DOWN   │                  │  └───────┘└───────┘└──────┘ │
│  Users lose │                  │      Pod 2 crashes ↓        │
│   access    │                  │  ┌───────┐        ┌──────┐  │
└─────────────┘                  │  │ Pod 1 │        │Pod 3 │  │
                                 │  └───────┘        └──────┘  │
                                 │  RS auto-creates new Pod 2 ↓ │
                                 │  ┌───────┐┌───────┐┌──────┐ │
                                 │  │ Pod 1 ││New Pod││Pod 3 │ │
                                 │  └───────┘└───────┘└──────┘ │
                                 └─────────────────────────────┘
```

**Benefits:**
- High availability — auto-restart pods if they crash
- Even a single pod can use RS (auto-restarts on failure)
- Load balancing across multiple pod instances
- Span across multiple nodes
- Scale up/down as demand changes

### ReplicationController vs ReplicaSet

| Feature | ReplicationController | ReplicaSet |
|---|---|---|
| API version | `v1` | `apps/v1` |
| Selector field | Optional (auto-matches template labels) | **Required** (uses `matchLabels`) |
| Managing pre-existing pods | Limited | Yes — can adopt pods created before RS existed |
| Status | Old — being deprecated | ✅ Current standard |

> **Rule:** Always use ReplicaSet — ReplicationController is legacy

### How Labels & Selectors Work

```
                    ReplicaSet
                  ┌───────────────────────────────┐
                  │  selector:                     │
                  │    matchLabels:                │
                  │      app: myapp     ◄──────────┼─── RS monitors pods
                  └───────────────────────────────┘    with this label
                           │
                           │ watches
                           ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │  Pod     │  │  Pod     │  │  Pod     │
        │ app:myapp│  │ app:myapp│  │ app:myapp│
        └──────────┘  └──────────┘  └──────────┘
        (these can be pre-existing pods OR created by the RS)
```

- RS uses selector to identify pods it should monitor
- Can adopt pre-existing pods with matching labels — won't create new ones if count is already met
- **Template is still required** even when adopting existing pods — needed to create replacements when a pod fails

### ReplicaSet YAML — Complete Syntax

```yaml
apiVersion: apps/v1          # MUST be apps/v1 — NOT v1 (will get error otherwise)
kind: ReplicaSet             # Type of object
metadata:
  name: myapp-rs             # Name of the ReplicaSet
  labels:                    # Labels on the RS itself
    app: myapp
    type: frontend
spec:
  replicas: 3                # Desired number of pod replicas at all times
  selector:                  # REQUIRED — how RS identifies pods to manage
    matchLabels:
      app: myapp             # Must match labels in template.metadata.labels below
  template:                  # Pod template — RS uses this to create/recreate pods
    metadata:
      labels:
        app: myapp           # MUST match selector.matchLabels above
    spec:
      containers:
      - name: nginx
        image: nginx
```

> ⚠️ If `selector.matchLabels` does NOT match `template.metadata.labels`, you get: `error: Invalid value: selector does not match template labels`

### Scaling a ReplicaSet

#### Method 1 — Edit file then replace:
```bash
# Edit replicas field in file from 3 to 6, then:
kubectl replace -f replicaset-definition.yaml
```
- **When to use:** When you want your local YAML file to reflect the new replica count

#### Method 2 — kubectl scale (does NOT update local file):
```bash
kubectl scale --replicas=6 -f replicaset-definition.yaml
# OR
kubectl scale --replicas=6 replicaset myapp-rs
```
- **When to use:** Quick scaling in exam; note local YAML file still shows old number

#### Method 3 — kubectl edit (edits live object):
```bash
kubectl edit rs myapp-rs
# Opens live config in editor — change replicas number and save
```
- **When to use:** Quick ad-hoc changes; changes apply immediately

### Important Caveat — Image Updates

> ⚠️ When you update a ReplicaSet's container image (via `kubectl edit` or `kubectl apply`), **existing pods are NOT automatically recreated** with the new image. You must manually delete existing pods — the RS will then recreate them using the new image template.

```bash
# After updating image in RS, delete all pods to force recreation:
kubectl delete pod <pod-name-1> <pod-name-2> <pod-name-3>
# RS automatically creates new pods with the updated image
```

### ReplicaSet Commands

```bash
kubectl create -f rs.yaml                    # Create RS
kubectl get replicaset                       # List RS (also: kubectl get rs)
kubectl describe replicaset myapp-rs         # Detailed info
kubectl delete replicaset myapp-rs           # Delete RS (also deletes all its pods)
kubectl replace -f rs.yaml                   # Update RS from file
kubectl scale --replicas=6 replicaset myapp-rs  # Scale
kubectl edit rs myapp-rs                     # Edit live RS object
```

---

## 6. Deployments

### Object Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│                       Deployment                             │
│  (manages rollouts, rollbacks, scaling, pause/resume)        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                    ReplicaSet                          │  │
│  │  (ensures desired pod count, manages pod lifecycle)    │  │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐         │  │
│  │  │   Pod    │    │   Pod    │    │   Pod    │         │  │
│  │  │(container)│   │(container)│   │(container)│        │  │
│  │  └──────────┘    └──────────┘    └──────────┘         │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Why Deployments Over ReplicaSets?

Deployments give you everything ReplicaSets do, PLUS:

| Feature | ReplicaSet | Deployment |
|---|---|---|
| Maintain desired pod count | ✅ | ✅ |
| Rolling updates | ❌ | ✅ |
| Rollback bad updates | ❌ | ✅ |
| Pause & resume changes | ❌ | ✅ |
| Batch multiple changes together | ❌ | ✅ |

#### Rolling Update:
```
Old version (v1):  [Pod-v1] [Pod-v1] [Pod-v1]
                                     ↓  update one at a time
During update:     [Pod-v1] [Pod-v1] [Pod-v2]    ← no downtime
                   [Pod-v1] [Pod-v2] [Pod-v2]
New version (v2):  [Pod-v2] [Pod-v2] [Pod-v2]
```

### Deployment YAML — Complete Syntax

```yaml
apiVersion: apps/v1          # Same as ReplicaSet
kind: Deployment             # ONLY difference from ReplicaSet YAML
metadata:
  name: myapp-deployment
  labels:
    app: myapp
    type: frontend
spec:
  replicas: 3                # Number of pod replicas
  selector:                  # Required — links Deployment to pods
    matchLabels:
      app: myapp
  template:                  # Pod template
    metadata:
      labels:
        app: myapp           # Must match selector.matchLabels
    spec:
      containers:
      - name: nginx
        image: nginx
        ports:
        - containerPort: 80
```

### What Gets Created When You Deploy

```bash
kubectl create -f deployment.yaml

# This automatically creates:
# 1. Deployment:  myapp-deployment
# 2. ReplicaSet:  myapp-deployment-<hash>
# 3. Pods:        myapp-deployment-<rs-hash>-<pod-hash>  (x3)
```

```bash
kubectl get all
# Output shows:
# pod/myapp-deployment-6b8d4b5c7-abc12
# pod/myapp-deployment-6b8d4b5c7-def34
# pod/myapp-deployment-6b8d4b5c7-ghi56
# replicaset.apps/myapp-deployment-6b8d4b5c7
# deployment.apps/myapp-deployment
```

### Deployment Commands

```bash
kubectl create -f deployment.yaml          # Create from file
kubectl get deployments                    # List deployments
kubectl get replicaset                     # See auto-created RS
kubectl get pods                           # See auto-created pods
kubectl get all                            # See everything at once
kubectl describe deployment myapp-deployment # Full details
kubectl delete deployment myapp-deployment # Delete deployment + RS + pods
```

### Imperative Deployment Commands (Exam Critical)

```bash
# Create deployment
kubectl create deployment nginx --image=nginx

# Create with specific replicas (K8s v1.19+)
kubectl create deployment nginx --image=nginx --replicas=4

# Generate YAML without creating
kubectl create deployment nginx --image=nginx --dry-run=client -o yaml

# Generate YAML, save to file, then create
kubectl create deployment nginx --image=nginx --dry-run=client -o yaml > nginx-deployment.yaml
kubectl create -f nginx-deployment.yaml

# Scale an existing deployment
kubectl scale deployment nginx --replicas=4
```

---

## 7. Services

### Purpose

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Application Architecture                           │
│                                                                       │
│  External Users                                                       │
│       │                                                               │
│       ▼                                                               │
│  [Frontend Service] ──► [Frontend Pods]                               │
│                                │                                      │
│                                ▼                                      │
│                    [Backend Service] ──► [Backend Pods]               │
│                                │                                      │
│                       ┌────────┴──────────┐                          │
│                       ▼                   ▼                          │
│              [Redis Service]        [MySQL Service]                   │
│              [Redis Pods]           [MySQL Pods]                      │
│                                                                       │
│  Services enable loose coupling between microservices                 │
└──────────────────────────────────────────────────────────────────────┘
```

- Pod IPs are unstable — pods come and go, IPs change
- Services provide a **stable IP and DNS name** that never changes
- Services use **labels & selectors** to find their target pods
- Services load balance across all matching pods

### Three Service Types

| Type | Purpose | Who Can Access | Use Case |
|---|---|---|---|
| **NodePort** | Expose pod via port on the Node | External (outside cluster) | Dev/testing, simple exposure |
| **ClusterIP** | Virtual IP for internal communication | Only inside cluster | Microservice-to-microservice |
| **LoadBalancer** | Cloud provider load balancer | External (via cloud LB) | Production on GCP/AWS/Azure |

---

### NodePort — Deep Dive

```
External User's Browser
        │
        │  http://192.168.1.2:30008
        ▼
┌──────────────────────────────────────────────────────┐
│                     NODE (192.168.1.2)                │
│                                                        │
│    NodePort: 30008  ◄── Port user connects to         │
│         │                (range: 30000-32767)          │
│         ▼                                             │
│    ┌──────────────────────────────────┐               │
│    │           SERVICE                │               │
│    │   Port: 80 (service's own port)  │               │
│    └──────────────────────────────────┘               │
│         │                                             │
│         ▼                                             │
│    TargetPort: 80  ──► Pod (web server on port 80)    │
│                                                        │
└──────────────────────────────────────────────────────┘
```

**Three ports to understand (all from Service's perspective):**
- **targetPort** — port on the Pod where application runs (where service forwards TO)
- **port** — port on the Service itself (only mandatory field)
- **nodePort** — port on the Node (what external users connect to; range 30000-32767)

**Defaults:**
- `targetPort` defaults to same value as `port` if not specified
- `nodePort` is auto-assigned from range if not specified

#### NodePort Service YAML:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp-service
spec:
  type: NodePort
  ports:
  - targetPort: 80       # Port on the Pod (defaults to 'port' if omitted)
    port: 80             # Port on the Service — MANDATORY
    nodePort: 30008      # Port on the Node (30000-32767; auto-assigned if omitted)
  selector:
    app: myapp           # Selects pods with this label — links service to pods
```

#### Single Pod, Multiple Pods, Multiple Nodes — All Work the Same:

```
Single pod:                      Multiple pods (load balanced):
[Service]──►[Pod]                [Service]──►[Pod-1]
                                       └───►[Pod-2]  (random algorithm)
                                       └───►[Pod-3]

Multiple nodes:
Node-1 (192.168.1.2)             Node-2 (192.168.1.3)
[NodePort:30008]                 [NodePort:30008]
    │                                │
    ▼                                ▼
[Pod-1][Pod-2]                   [Pod-3]

Access via ANY node IP: curl 192.168.1.2:30008 OR curl 192.168.1.3:30008
Kubernetes configures this automatically — no extra steps needed
```

---

### ClusterIP — Deep Dive

```
┌─────────────────────────────────────────────────────────────┐
│                        CLUSTER                               │
│                                                              │
│  ┌─────────────┐    ┌──────────────────┐    ┌───────────┐  │
│  │  Frontend   │    │ Backend Service  │    │  Backend  │  │
│  │    Pods     │───►│  ClusterIP:      │───►│   Pods    │  │
│  │             │    │  10.96.45.12     │    │           │  │
│  └─────────────┘    │  name: backend   │    └───────────┘  │
│                     └──────────────────┘                    │
│                              │                              │
│                     ┌────────┴──────────────────────┐       │
│                     ▼                               ▼       │
│            ┌────────────────┐             ┌──────────────┐  │
│            │  Redis Service │             │ MySQL Service│  │
│            │  name: redis   │             │ name: mysql  │  │
│            └────────────────┘             └──────────────┘  │
│                     │                               │        │
│            ┌────────┘                     ┌─────────┘        │
│            ▼                             ▼                   │
│        [Redis Pods]                 [MySQL Pods]             │
└─────────────────────────────────────────────────────────────┘

Frontend pods access backend as: http://backend (service name)
NOT by pod IP (which changes when pods restart)
```

#### ClusterIP Service YAML:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend              # This name is used by other pods to reach this service
spec:
  type: ClusterIP            # Default type — can omit this line entirely
  ports:
  - targetPort: 80           # Port on the backend pods
    port: 80                 # Port on the service
  selector:
    app: backend             # Selects backend pods
```

- Each service gets a stable cluster-internal IP AND a DNS name
- Pods access service by name: `http://backend`, `http://redis`, `http://mysql`
- DNS format: `<service-name>.<namespace>.svc.cluster.local`

---

### LoadBalancer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
spec:
  type: LoadBalancer         # Cloud provider provisions external LB
  ports:
  - targetPort: 80
    port: 80
    nodePort: 30008
  selector:
    app: frontend
```

```
Cloud LB URL: http://voting-app.example.com
              │
              ▼
    [Cloud Load Balancer]
    /          |          \
   ▼           ▼           ▼
[Node-1]   [Node-2]   [Node-3]
NodePort   NodePort   NodePort
   │           │           │
   ▼           ▼           ▼
[Pods]     [Pods]      [Pods]
```

> ⚠️ `LoadBalancer` on unsupported environments (VirtualBox, bare metal without MetalLB) behaves exactly like `NodePort` — no external LB is provisioned

---

### Endpoints — What They Are

```
Service
  selector: app=myapp
       │
       │ discovers
       ▼
┌──────────────────────────────────────────────┐
│              Endpoints                        │
│  10.244.0.3:80  ← Pod-1 IP:port              │
│  10.244.0.4:80  ← Pod-2 IP:port              │
│  10.244.0.5:80  ← Pod-3 IP:port              │
└──────────────────────────────────────────────┘
```

- Endpoints = the actual pod IP:port combinations the service routes to
- Auto-discovered based on selector matching pod labels
- `kubectl describe service myapp-service` shows Endpoints
- If Endpoints is empty → selector doesn't match any pod labels (common misconfiguration bug)

```bash
kubectl describe service myapp-service   # Shows Endpoints field
```

### Service Commands

```bash
kubectl create -f service.yaml
kubectl get services                      # or: kubectl get svc
kubectl describe service myapp-service
kubectl delete service myapp-service

# Imperative service creation
kubectl expose pod redis --port=6379 --name=redis-service            # ClusterIP, auto-uses pod labels as selector
kubectl expose pod nginx --type=NodePort --port=80 --name=nginx-svc  # NodePort, auto-uses pod labels

# Create pod AND expose as service in one command
kubectl run httpd --image=httpd:alpine --port=80 --expose=true
# Creates: pod/httpd AND service/httpd (ClusterIP)

# Generate service YAML without creating
kubectl expose pod redis --port=6379 --name=redis-service --dry-run=client -o yaml
```

#### Service Creation Method Comparison:

| Command | Auto-uses pod labels as selector? | Can specify nodePort? |
|---|---|---|
| `kubectl expose` | ✅ Yes | ❌ No (edit YAML) |
| `kubectl create service` | ❌ No (assumes app=<name>) | ✅ Yes |

> **Recommendation:** Use `kubectl expose` (auto-selector) then edit YAML if nodePort is needed

---

## 8. Namespaces

### Concept & Built-in Namespaces

```
┌─────────────────────────────────────────────────────────────────────┐
│                        CLUSTER                                       │
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐  ┌─────────────────────┐   │
│  │   kube-system  │  │   kube-public  │  │      default        │   │
│  │                │  │                │  │                     │   │
│  │ K8s internal:  │  │ Public         │  │ Where YOU work      │   │
│  │ • DNS          │  │ resources for  │  │ by default          │   │
│  │ • networking   │  │ all users      │  │                     │   │
│  │ • apiserver    │  │                │  │                     │   │
│  │ • etcd         │  │                │  │                     │   │
│  └────────────────┘  └────────────────┘  └─────────────────────┘   │
│                                                                      │
│  ┌────────────────┐  ┌────────────────┐                            │
│  │      dev       │  │      prod      │  ← Your custom namespaces  │
│  │                │  │                │                            │
│  │ Dev resources  │  │ Prod resources │                            │
│  │ Dev policies   │  │ Prod policies  │                            │
│  │ Dev quotas     │  │ Prod quotas    │                            │
│  └────────────────┘  └────────────────┘                            │
└─────────────────────────────────────────────────────────────────────┘
```

### DNS Across Namespaces

```
Pods within SAME namespace — use just the service name:
  webapp pod (in default) ──► db-service
                              (Kubernetes resolves it)

Pods in DIFFERENT namespaces — use full DNS name:
  webapp pod (in default) ──► db-service.dev.svc.cluster.local
                                    │      │   │      │
                                    │      │   │      └── cluster domain (always this)
                                    │      │   └───────── subdomain for services
                                    │      └───────────── namespace name
                                    └──────────────────── service name
```

### Namespace YAML

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
```

### ResourceQuota YAML

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: dev             # Apply quota to this namespace
spec:
  hard:
    pods: "10"               # Max 10 pods in this namespace
    requests.cpu: "10"       # Max 10 CPU units requested
    requests.memory: 10Gi   # Max 10GB memory requested
    limits.cpu: "20"
    limits.memory: 20Gi
```

### Namespace Commands

```bash
# List namespaces
kubectl get namespaces                    # or: kubectl get ns

# Create namespace
kubectl create namespace dev
kubectl create -f namespace.yaml

# List pods in a specific namespace
kubectl get pods --namespace=kube-system
kubectl get pods -n kube-system           # short flag

# List pods in ALL namespaces
kubectl get pods --all-namespaces
kubectl get pods -A                       # short flag

# Create resource in a specific namespace
kubectl run redis --image=redis -n dev
kubectl create -f pod.yaml --namespace=dev

# Embed namespace in pod definition (always creates in that namespace)
# Under metadata section:
#   namespace: dev

# Switch default namespace permanently for current context
kubectl config set-context --current --namespace=dev
# Now: kubectl get pods  ← shows pods in 'dev' namespace

# Switch back to default
kubectl config set-context --current --namespace=default
```

---

## 9. Imperative vs Declarative

### The Analogy

```
IMPERATIVE (old taxi):              DECLARATIVE (Uber):
"Turn right on Street A"            "Take me to Tom's house"
"Then left on Street B"             (system figures out route)
"Then right on Street C"
"Stop at the blue house"
─────────────────────────           ─────────────────────────
YOU specify HOW                     YOU specify WHAT
Step by step instructions           Just the end state
```

### In Kubernetes Terms

```
IMPERATIVE                          DECLARATIVE
─────────────────────────────       ─────────────────────────────
kubectl run ...                     kubectl apply -f config/
kubectl create ...
kubectl expose ...
kubectl edit ...
kubectl scale ...
kubectl set image ...
kubectl replace ...
kubectl delete ...

Creates/updates ONE object          Applies ENTIRE desired state
at a time                           at once

YOU must check if object            K8s figures out what to
exists before create/replace        create, update, or delete
```

### Imperative Sub-approaches

#### 1. Pure Commands (fastest, no files):

```bash
# Create objects
kubectl run nginx --image=nginx                          # Pod
kubectl create deployment web --image=nginx              # Deployment
kubectl expose pod redis --port=6379 --name redis-svc   # Service

# Update objects
kubectl edit pod nginx                   # Opens editor for live object
kubectl scale deployment web --replicas=5
kubectl set image deployment web nginx=nginx:1.19

# Delete objects
kubectl delete pod nginx
kubectl delete -f pod.yaml
```

**Pros:** Very fast, great for exam
**Cons:** No audit trail; can't track in Git; limited for complex configs

#### 2. With Config Files (imperative but tracked):

```bash
# Create (fails if already exists)
kubectl create -f pod.yaml

# Update (fails if doesn't exist)
kubectl replace -f pod.yaml

# Force delete and recreate
kubectl replace --force -f pod.yaml

# Delete
kubectl delete -f pod.yaml
```

**Pros:** Config tracked in files, can be stored in Git
**Cons:** Must always check if object exists first; still manual process

#### Problem with `kubectl edit`:

```
kubectl edit pod nginx
    │
    ▼
Opens LIVE object in editor (NOT your local file)
    │
    ▼
You change image from nginx to nginx:1.19
    │
    ▼
Change applied to live cluster ✅
    │
    ▼
Your local pod.yaml STILL shows nginx (old version) ❌
    │
    ▼
Next teammate runs 'kubectl replace -f pod.yaml'
    │
    ▼
Your image change is OVERWRITTEN and LOST ❌
```

**Better approach:** Edit your local file → `kubectl replace -f pod.yaml`

### Declarative Approach

```bash
# Create if not exists, update if exists — NEVER fails
kubectl apply -f pod.yaml

# Apply entire directory of files
kubectl apply -f ./manifests/

# Going forward — any change:
# 1. Edit local YAML file
# 2. Run kubectl apply -f file.yaml
# That's it — K8s figures out the diff
```

**Pros:** Idempotent; config in Git; change review process; team-friendly
**Cons:** Slightly more to learn upfront

### Exam Strategy

```
Exam Question Type                  Recommended Approach
─────────────────────────────────   ──────────────────────────────────
Create simple pod/deployment        Imperative commands (fastest)
with given name & image

Edit existing object's property     kubectl edit (quickest)

Create multi-container pod          YAML file + kubectl apply
Create pod with env vars,
commands, init containers, etc.

Create service exposing pod         kubectl expose (auto-selector)

Need to specify nodePort            kubectl expose --dry-run -o yaml
                                    → edit file → kubectl apply
```

---

## 10. How `kubectl apply` Works Internally

### Three Files That `apply` Compares

```
┌────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────────────────┐
│   LOCAL FILE       │   │  LIVE OBJECT IN CLUSTER  │   │  LAST APPLIED CONFIGURATION     │
│   (on your disk)   │   │  (in K8s memory)         │   │  (stored as annotation on       │
│                    │   │                           │   │   the live object)              │
│  pod.yaml          │   │  Status + Spec in K8s    │   │  JSON of last applied local     │
│  (what you wrote)  │   │  (includes status fields  │   │  file, stored as:               │
│                    │   │   like phase, conditions) │   │  kubectl.kubernetes.io/         │
│                    │   │                           │   │  last-applied-configuration     │
└─────────┬──────────┘   └──────────────┬────────────┘   └──────────────────┬──────────────┘
          │                             │                                    │
          └─────────────────────────────┴────────────────────────────────────┘
                                        │
                                        ▼
                                  kubectl apply
                              compares all three →
                              calculates diff →
                              applies only changes needed
```

### Step-by-Step: First Apply

```
Step 1: You run:  kubectl apply -f pod.yaml

Step 2: Object doesn't exist → K8s creates it
        (like kubectl create, but stores extra info)

Step 3: K8s creates the live object with:
        • All fields from your YAML
        • Additional status fields (phase, conditions, etc.)

Step 4: K8s converts your YAML to JSON
        Stores it as annotation on the live object:
        kubectl.kubernetes.io/last-applied-configuration: '{...json...}'
```

### Step-by-Step: Subsequent Apply (Update)

```
You change image in pod.yaml from nginx to nginx:1.19

kubectl apply -f pod.yaml

K8s compares:
  Local file:           image: nginx:1.19   (new)
  Live object:          image: nginx        (current)
  Last applied config:  image: nginx        (previous)

Decision: Update live object image to nginx:1.19 ✅
Update last-applied-configuration annotation to nginx:1.19 ✅
```

### Step-by-Step: Detecting Deleted Fields

```
You had a label 'type: frontend' in pod.yaml
You DELETE that label from pod.yaml and run kubectl apply

K8s compares:
  Local file:           (label 'type' not present)
  Last applied config:  type: frontend  ← was here before!
  Live object:          type: frontend  ← currently set

Decision: Since 'type' was in last-applied but NOT in local file,
          user deliberately removed it → REMOVE from live object ✅

vs.

If a field is in live object but NOT in local file OR last-applied:
  → It was added externally (e.g., by controller) → LEAVE IT ALONE
```

### Important Warning

```
DO NOT MIX these approaches on the same objects:

  kubectl create -f pod.yaml   ← does NOT set last-applied annotation
  kubectl apply -f pod.yaml    ← sets last-applied annotation

  If you use both, apply cannot correctly calculate diffs
  → Stick to ONE approach per set of objects
```

---

## 11. `kubectl explain` & `kubectl api-resources`

### `kubectl api-resources` — Find Resource Names & Versions

```bash
kubectl api-resources
```

Output example:
```
NAME                    SHORTNAMES   APIVERSION   NAMESPACED   KIND
pods                    po           v1           true         Pod
services                svc          v1           true         Service
replicasets             rs           apps/v1      true         ReplicaSet
deployments             deploy       apps/v1      true         Deployment
namespaces              ns           v1           false        Namespace
nodes                   no           v1           false        Node
```

**When to use:**
- Forgot resource name or short name
- Not sure of correct apiVersion
- Not sure if resource name is capitalized or not in YAML

### `kubectl explain` — Explore Resource Fields

```bash
# Top-level fields of a resource
kubectl explain pod

# Drill into subfields
kubectl explain pod.spec

kubectl explain pod.spec.containers

# See ALL fields recursively (best for YAML writing)
kubectl explain pod --recursive

kubectl explain replicaset.spec.selector --recursive
```

**When to use:**
- Writing YAML and unsure of field names
- Need to know field types (string, integer, []Object, etc.)
- Want descriptions of what each field does
- All within the terminal — no browser needed

---

## Complete YAML Reference Snippets

### Pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp-pod
  labels:
    app: myapp
    tier: frontend
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
```

### Multi-Container Pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp-pod
spec:
  containers:
  - name: app
    image: nginx
  - name: helper
    image: busybox
```

### ReplicaSet
```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: myapp-rs
  labels:
    app: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: nginx
        image: nginx
```

### Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-deployment
  labels:
    app: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: nginx
        image: nginx
        ports:
        - containerPort: 80
```

### NodePort Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp-service
spec:
  type: NodePort
  ports:
  - targetPort: 80
    port: 80
    nodePort: 30008
  selector:
    app: myapp
```

### ClusterIP Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  type: ClusterIP
  ports:
  - targetPort: 80
    port: 80
  selector:
    app: backend
```

### LoadBalancer Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
spec:
  type: LoadBalancer
  ports:
  - targetPort: 80
    port: 80
    nodePort: 30008
  selector:
    app: frontend
```

### Namespace
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
```

### ResourceQuota
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: dev
spec:
  hard:
    pods: "10"
    requests.cpu: "10"
    requests.memory: 10Gi
    limits.cpu: "20"
    limits.memory: 20Gi
```

### Pod in Specific Namespace
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: redis
  namespace: dev        # Always created in 'dev' namespace
  labels:
    app: redis
spec:
  containers:
  - name: redis
    image: redis
```

---

## Exam Quick-Reference Cheat Sheet

### Pods
```bash
kubectl run nginx --image=nginx
kubectl run nginx --image=nginx --dry-run=client -o yaml
kubectl run nginx --image=nginx --dry-run=client -o yaml > pod.yaml
kubectl run nginx --image=nginx --port=80
kubectl run nginx --image=nginx --labels="tier=db"
kubectl run httpd --image=httpd --port=80 --expose=true   # pod + service
kubectl get pods
kubectl get pods -o wide
kubectl describe pod nginx
kubectl delete pod nginx
```

### Deployments
```bash
kubectl create deployment nginx --image=nginx
kubectl create deployment nginx --image=nginx --replicas=4
kubectl create deployment nginx --image=nginx --dry-run=client -o yaml
kubectl create deployment nginx --image=nginx --dry-run=client -o yaml > deploy.yaml
kubectl get deployments
kubectl describe deployment nginx
kubectl scale deployment nginx --replicas=4
kubectl set image deployment nginx nginx=nginx:1.19
kubectl delete deployment nginx
```

### ReplicaSets
```bash
kubectl get replicaset                            # or: kubectl get rs
kubectl describe rs myapp-rs
kubectl scale --replicas=6 replicaset myapp-rs
kubectl edit rs myapp-rs
kubectl delete rs myapp-rs
```

### Services
```bash
kubectl expose pod redis --port=6379 --name=redis-service
kubectl expose pod nginx --type=NodePort --port=80 --name=nginx-svc
kubectl expose deployment web --port=80 --type=NodePort --name=web-svc
kubectl create service clusterip redis --tcp=6379:6379
kubectl create service nodeport nginx --tcp=80:80 --node-port=30080
kubectl get services                              # or: kubectl get svc
kubectl describe svc myapp-service
kubectl delete svc myapp-service
```

### Namespaces
```bash
kubectl create namespace dev
kubectl get pods -n kube-system
kubectl get pods -n dev
kubectl get pods -A                               # all namespaces
kubectl get pods --all-namespaces
kubectl run redis --image=redis -n dev
kubectl config set-context --current --namespace=dev
kubectl config set-context --current --namespace=default
```

### Apply & Manage
```bash
kubectl apply -f pod.yaml                         # create or update
kubectl apply -f ./manifests/                     # apply entire directory
kubectl create -f pod.yaml                        # create only (fails if exists)
kubectl replace -f pod.yaml                       # update only (fails if not exists)
kubectl replace --force -f pod.yaml               # delete + recreate
kubectl delete -f pod.yaml
kubectl edit pod nginx                            # edit live object
```

### Inspect & Debug
```bash
kubectl get all                                   # all objects in namespace
kubectl describe pod <name>
kubectl describe rs <name>
kubectl describe svc <name>
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>       # multi-container pod
kubectl exec -it <pod-name> -- /bin/sh
kubectl api-resources                             # all resource types + shortnames + versions
kubectl explain pod
kubectl explain pod.spec
kubectl explain pod --recursive
```

### Worker Node Debugging (containerd)
```bash
# crictl — use when docker is not available (K8s v1.24+)
crictl ps                                        # list containers
crictl ps -a                                     # all containers including stopped
crictl images                                    # list images
crictl logs <container-id>
crictl exec -it <container-id> sh
crictl pods                                      # list pods (pod-aware, unlike docker)

# nerdctl — docker-like CLI for containerd
nerdctl ps
nerdctl images
nerdctl logs <container-id>
```

### Common Errors & Fixes

| Error Message | Cause | Fix |
|---|---|---|
| `no matches for kind "ReplicaSet" in version "v1"` | Wrong apiVersion | Change to `apps/v1` |
| `no matches for kind "deployment"` | Wrong case | Use `Deployment` (capital D) |
| `selector does not match template labels` | Selector ≠ template labels | Make both match exactly |
| `ImagePullBackOff` / `ErrImagePull` | Wrong image name | Fix image name in spec |
| `already exists` | Used `create` on existing object | Use `apply` instead |
| `not found` | Used `replace` on non-existing object | Use `apply` instead |
| Endpoints is `<none>` on service | Selector doesn't match pod labels | Check labels vs selector |

---

*This document covers 100% of the CKA Core Concepts section. Good luck with your exam!*
