# 🧩 Section 1 — Core Concepts (What · Pain · How · Examples)

> Every topic below follows the same 4 steps: **What** it is → **Pain points it solves & why** → **How exactly it works** (machinery + vocabulary) → **3+ hands-on examples** you can run. Source: CKA course Section 1 transcript.

---

## 1. Cluster Architecture (control plane + worker nodes)

### ❓ What
Kubernetes is split into a **control plane** (etcd, kube-apiserver, kube-scheduler, kube-controller-manager) that decides and records, and **worker nodes** (kubelet, kube-proxy, container runtime) that actually run containers.

### 🔥 Pain points it solves & why this?
- Running containers on many machines by hand = no self-healing, manual placement, no single source of truth about "what should be running."
- Splitting brain (decisions) from muscle (execution) lets any node die without losing cluster state, and lets one API be the single, auditable entry point for every change.

### ⚙️ How exactly it works
Every action flows through the **API server** (authn → authz → validate → write to **etcd**). Controllers and the scheduler *watch* the API server and act on gaps; kubelets *watch* it and run assigned pods.

```
kubectl create pod
 └▶ kube-apiserver → writes "Pod (no node)" to etcd
     └▶ kube-scheduler (watching) picks a node → apiserver records it
         └▶ kubelet on that node (watching) → container runtime pulls image, runs it
             └▶ kubelet reports status → apiserver → etcd
```

| Vocabulary | What it actually is | Port |
|---|---|---|
| **etcd** | key-value DB holding ALL cluster state (only the apiserver talks to it) | 2379 client / 2380 peer |
| **kube-apiserver** | the hub — every request goes through it | 6443 |
| **kube-scheduler** | *decides* the node (does not place the pod) | 10259 |
| **kube-controller-manager** | runs all reconcile controllers | 10257 |
| **kubelet** | node agent — runs/monitors pods; a **systemd service, NOT a pod** | 10250 |
| **kube-proxy** | turns Services into iptables rules; runs as a **DaemonSet** | — |
| **container runtime** | containerd/CRI-O — actually runs containers | — |

### 🧪 Hands-on examples

**Example 1 — Identify every component in an unknown cluster (exam recon):**
```bash
kubectl get nodes -o wide                          # nodes, roles, versions, IPs
kubectl get pods -n kube-system                    # control-plane static pods + kube-proxy + CNI
kubectl describe pod kube-apiserver-controlplane -n kube-system | grep -i image
systemctl status kubelet                           # kubelet = systemd service, not a pod
# Verify: you can name each component and where it runs.
```

**Example 2 — Find how the apiserver connects to etcd:**
```bash
sudo grep -- --etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml
# → --etcd-servers=https://127.0.0.1:2379
# Verify: the flag points at etcd's client port 2379.
```

**Example 3 — Watch the golden flow live:**
```bash
kubectl get events -A -w &                          # watch cluster events
kubectl run flowtest --image=nginx
# You'll see: Scheduled (scheduler) → Pulling/Pulled → Created/Started (kubelet)
kubectl delete pod flowtest --force --grace-period=0
# Verify: the event Source column names which component did each step.
```

---

## 2. Container Runtimes, CRI & crictl

### ❓ What
The **container runtime** (containerd, CRI-O) is what actually runs containers. Kubernetes talks to any runtime through the **CRI (Container Runtime Interface)**. Docker's special shim (**dockershim**) was removed in v1.24.

### 🔥 Pain points it solves & why this?
- Kubernetes was hard-coupled to Docker; other runtimes couldn't plug in → CRI made the runtime swappable.
- Docker predates CRI, so it needed a maintenance-heavy shim → removed; Docker-*built images* still run (OCI image spec).
- When the API server is down you still need to inspect containers on a node → `crictl` works against *any* CRI runtime.

### ⚙️ How exactly it works
The kubelet calls the runtime over a Unix socket (`--container-runtime-endpoint`). Three CLIs exist — know which to use:

| Vocabulary | From | Talks to | Use for |
|---|---|---|---|
| `ctr` | containerd | containerd only | low-level debug — ignore |
| `nerdctl` | containerd | containerd | Docker-like general CLI |
| **`crictl`** | Kubernetes | **any CRI runtime** | **debugging pods/containers on a node (CKA)** |

`crictl` reads `/etc/crictl.yaml` for the runtime endpoint.

### 🧪 Hands-on examples

**Example 1 — Inspect containers on a node like `docker ps`:**
```bash
crictl ps                        # running containers
crictl pods                      # pod sandboxes
crictl images                    # cached images
# Verify: your app's containers appear with pod names attached.
```

**Example 2 — Debug a control-plane crash when kubectl is dead:**
```bash
kubectl get pods                 # connection refused (apiserver down)
crictl ps -a | grep apiserver    # find the exited container
crictl logs <container-id>       # read the actual startup error
# Verify: the log names the bad flag/path — fix it in /etc/kubernetes/manifests.
```

**Example 3 — Find which runtime the kubelet uses:**
```bash
ps -aux | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*'
# → unix:///run/containerd/containerd.sock
cat /etc/crictl.yaml             # crictl pointed at the same socket
# Verify: kubelet and crictl target the same runtime endpoint.
```

---

## 3. etcd — the cluster's memory

### ❓ What
A distributed **key-value store** holding *everything*: nodes, pods, configs, secrets, roles. `kubectl get` = reading etcd through the API server.

### 🔥 Pain points it solves & why this?
- Cluster state must live somewhere consistent and crash-safe — not in each component's memory.
- Key-value (schema-free) fits arbitrary API objects; Raft consensus keeps replicas consistent.
- A change is only "real" once written to etcd → one source of truth.

### ⚙️ How exactly it works
Keys are stored under `/registry/<resource>/<namespace>/<name>`. Only the **apiserver** talks to etcd (port **2379**; **2380** is peer-to-peer for HA). v3 API verbs: `put`/`get`/`del`. Every `etcdctl` call needs the TLS trio + endpoint.

| Vocabulary | Meaning |
|---|---|
| `ETCDCTL_API=3` | use the v3 API |
| `--endpoints` | where etcd listens (`https://127.0.0.1:2379`) |
| `--cacert/--cert/--key` | etcd's own CA + client cert pair |
| `/registry/...` | the key prefix Kubernetes writes under |

### 🧪 Hands-on examples

**Example 1 — List everything Kubernetes stores:**
```bash
kubectl exec -it etcd-controlplane -n kube-system -- sh -c \
 "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get / --prefix --keys-only" | head -20
# Verify: keys like /registry/pods/default/... appear.
```

**Example 2 — Prove a created object lands in etcd:**
```bash
kubectl create ns etcd-demo
# same etcdctl as above but:  get /registry/namespaces/etcd-demo
# Verify: the key exists the moment kubectl returns "created".
```

**Example 3 — Read etcd's config from its manifest (backup prep):**
```bash
sudo grep -E 'data-dir|cert-file|trusted-ca' /etc/kubernetes/manifests/etcd.yaml
# Verify: you can state the data dir (/var/lib/etcd) and cert paths — exactly what snapshot save needs (Section 5).
```

---

## 4. Pods

### ❓ What
The smallest deployable unit: a wrapper around one (or a few tightly-coupled) containers that share network (localhost), storage, and lifecycle.

### 🔥 Pain points it solves & why this?
- Kubernetes needs one schedulable unit with one IP and one lifecycle — a raw container has none of that.
- Helpers (log shippers, proxies) need to live *with* the app, sharing its network/volumes, without merging code → multi-container pods.
- **Scale by adding pods, not containers** — 1 pod ≈ 1 app instance.

### ⚙️ How exactly it works
Every K8s object has 4 top-level fields — `apiVersion`, `kind`, `metadata`, `spec`. Containers in a pod share the network namespace (reach each other on `localhost`) and can mount the same volumes.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels: { app: nginx, tier: frontend }   # labels = how selectors find it later
spec:
  containers:                # a LIST — note the "-"
  - name: nginx
    image: nginx
```

### 🧪 Hands-on examples

**Example 1 — Create a pod imperatively, then from generated YAML:**
```bash
kubectl run nginx --image=nginx
kubectl run web --image=nginx --dry-run=client -o yaml > pod.yaml   # generate, don't type
kubectl apply -f pod.yaml
kubectl get pods            # both Running
# Verify: ContainerCreating → Running; describe shows image + node.
```

**Example 2 — Debug a broken pod:**
```bash
kubectl run bad --image=nginx-typo
kubectl get pods                          # ImagePullBackOff
kubectl describe pod bad | grep -A5 Events    # "pull access denied / not found"
kubectl set image pod/bad bad=nginx       # fix the image in place
# Verify: pod transitions to Running after the fix.
```

**Example 3 — Two containers sharing localhost:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: buddy }
spec:
  containers:
  - { name: web, image: nginx }
  - name: probe
    image: busybox
    command: ["sh","-c","sleep 5; wget -qO- localhost:80 | head -1; sleep 3600"]
EOF
kubectl logs buddy -c probe
# Verify: the busybox container fetched nginx's page via localhost — shared network namespace.
```

---

## 5. ReplicaSets (and the old ReplicationController)

### ❓ What
A controller that keeps **N identical pods** running at all times. **ReplicationController** = legacy (`v1`); **ReplicaSet** = current (`apps/v1`) and requires a `selector`.

### 🔥 Pain points it solves & why this?
- A single pod is a single point of failure — nobody restarts it if it dies.
- Manual scaling means humans running `kubectl run` N times.
- ReplicaSet's explicit `selector` also lets it **adopt** existing pods whose labels match (RC couldn't).

### ⚙️ How exactly it works
A reconcile loop: desired (`replicas`) vs actual (pods matching the `selector`) — create or delete to close the gap. `selector.matchLabels` **must equal** `template.metadata.labels` or creation fails.

| Vocabulary | Meaning |
|---|---|
| `replicas` | desired count |
| `selector.matchLabels` | which pods this RS owns |
| `template` | full pod definition (minus apiVersion/kind) to stamp out |

### 🧪 Hands-on examples

**Example 1 — Create, kill a pod, watch self-healing:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: ReplicaSet
metadata: { name: myapp-rs }
spec:
  replicas: 3
  selector: { matchLabels: { app: myapp } }
  template:
    metadata: { labels: { app: myapp } }
    spec: { containers: [ { name: nginx, image: nginx } ] }
EOF
kubectl delete pod $(kubectl get pods -l app=myapp -o name | head -1)
kubectl get pods -l app=myapp     # replacement appears — back to 3
# Verify: count returns to 3 within seconds.
```

**Example 2 — Scale three different ways:**
```bash
kubectl scale rs myapp-rs --replicas=6          # imperative
kubectl edit rs myapp-rs                        # live edit spec.replicas
kubectl replace -f rs.yaml                      # from an edited file
# Verify: kubectl get rs shows DESIRED=CURRENT=READY at the new count.
```

**Example 3 — The selector/label mismatch error:**
```bash
# In the YAML above, change template label to app: other → apply
# → error: `selector` does not match template `labels`
# Fix them to match; apply succeeds.
# Verify: you've seen (and can instantly fix) the classic RS creation failure.
```

---

## 6. Deployments

### ❓ What
The object you actually use in production: sits **above** ReplicaSets and adds **rolling updates, rollback, pause/resume**.

### 🔥 Pain points it solves & why this?
- A ReplicaSet keeps N pods, but *upgrading* means replacing pods — RS alone can't do it gradually or undo it.
- Deployments version each change (revisions) so a bad release is one `undo` away.

### ⚙️ How exactly it works
```
Deployment ──manages──▶ ReplicaSet ──manages──▶ Pods
 (rollouts/rollback)      (N copies)            (containers)
```
Each template change creates a **new RS** scaled up while the old scales down (details in Section 4 file). YAML is identical to an RS except `kind: Deployment`.

### 🧪 Hands-on examples

**Example 1 — Create and see the 3-level hierarchy:**
```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl get deploy,rs,pods          # deployment → replicaset (hash suffix) → pods
kubectl get all                     # everything at once
# Verify: the RS name = deployment name + template hash; pods = RS name + suffix.
```

**Example 2 — Generate production YAML fast:**
```bash
kubectl create deployment httpd-frontend --image=httpd:2.4-alpine --replicas=3 \
  --dry-run=client -o yaml > deploy.yaml
kubectl apply -f deploy.yaml
# Verify: 3/3 READY; the file is your declarative source of truth.
```

**Example 3 — Update an image and watch a new RS appear:**
```bash
kubectl set image deployment/web nginx=nginx:1.26
kubectl get rs                      # TWO replicasets: old scaling to 0, new to 3
# Verify: this is the rolling-update machinery Deployments add over RS.
```

---

## 7. Services (ClusterIP · NodePort · LoadBalancer)

### ❓ What
A **stable virtual IP + DNS name** that load-balances across a set of pods selected by **labels**.

### 🔥 Pain points it solves & why this?
- Pod IPs are ephemeral — anything pointed at a pod IP breaks on restart.
- Multiple replicas need one address with built-in load balancing.
- Different exposure scopes: internal only (**ClusterIP**), on every node's port (**NodePort**, 30000–32767), or behind a cloud LB (**LoadBalancer**).

### ⚙️ How exactly it works
The service's `selector` matches pod labels → the matched pod IPs become **Endpoints** → kube-proxy programs iptables to DNAT the VIP to one endpoint.

| Vocabulary (NodePort's 3 ports) | Meaning |
|---|---|
| `targetPort` | port on the **pod** (where the app listens) |
| `port` | port on the **service** VIP (the only mandatory one) |
| `nodePort` | port on every **node** (30000–32767, auto if omitted) |

```yaml
apiVersion: v1
kind: Service
metadata: { name: web-service }
spec:
  type: NodePort
  selector: { app: myapp }        # ← links service → pods
  ports: [ { targetPort: 80, port: 80, nodePort: 30008 } ]
```

### 🧪 Hands-on examples

**Example 1 — Expose a deployment end-to-end:**
```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl expose deployment web --type=NodePort --port=80
kubectl get svc web -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
curl http://<node-ip>:<that-port>
# Verify: nginx welcome page; describe svc web shows 3 Endpoints.
```

**Example 2 — Diagnose the #1 service failure (empty Endpoints):**
```bash
kubectl describe svc web | grep Endpoints        # populated
kubectl patch svc web -p '{"spec":{"selector":{"app":"wrong"}}}'
kubectl describe svc web | grep Endpoints        # <none> → traffic goes nowhere
kubectl patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
# Verify: Endpoints repopulate the instant the selector matches pod labels again.
```

**Example 3 — Service for a pod + a specific nodePort:**
```bash
kubectl run redis --image=redis --labels=app=redis
kubectl expose pod redis --port=6379 --name=redis-service      # auto-uses pod labels
# expose can't set nodePort → generate + edit:
kubectl create service nodeport web-np --tcp=80:80 --node-port=30080 \
  --dry-run=client -o yaml > svc.yaml
kubectl apply -f svc.yaml
# Verify: kubectl get svc shows redis-service (ClusterIP) and web-np on 30080.
```

---

## 8. Namespaces

### ❓ What
Virtual clusters inside a cluster — they scope names, policies, and quotas. Built-ins: `default`, `kube-system` (control plane — don't touch), `kube-public`, `kube-node-lease`.

### 🔥 Pain points it solves & why this?
- Dev and prod (or many teams) on one cluster need isolation without separate clusters.
- Name collisions: two teams can both have a `web` service — in different namespaces.
- Per-team resource caps via **ResourceQuota**.

### ⚙️ How exactly it works
Same-namespace services resolve by short name (`db-service`); cross-namespace needs the FQDN `<svc>.<namespace>.svc.cluster.local` (DNS search domains only cover your own namespace).

### 🧪 Hands-on examples

**Example 1 — Create, deploy into, and default to a namespace:**
```bash
kubectl create namespace dev
kubectl run redis --image=redis -n dev
kubectl config set-context --current --namespace=dev    # stop typing -n
kubectl get pods                                        # now shows dev's pods
# Verify: kubectl config view --minify | grep namespace → dev.
```

**Example 2 — Cross-namespace DNS:**
```bash
kubectl expose pod redis --name=db-service --port=6379 -n dev
kubectl run test --image=busybox -n default -it --rm -- \
  sh -c 'nslookup db-service.dev.svc.cluster.local'
# Verify: FQDN resolves; bare "db-service" from default would NOT.
```

**Example 3 — Cap a namespace with a ResourceQuota:**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata: { name: dev-quota, namespace: dev }
spec:
  hard: { pods: "2", requests.cpu: "1", requests.memory: 1Gi }
EOF
kubectl run p1 --image=nginx -n dev; kubectl run p2 --image=nginx -n dev
kubectl run p3 --image=nginx -n dev        # FORBIDDEN: exceeded quota
# Verify: the third pod is rejected with the quota error.
```

---

## 9. Imperative vs Declarative (+ kubectl explain / api-resources)

### ❓ What
Two ways to drive Kubernetes: **imperative** commands (`run`, `create`, `expose`, `scale`, `edit`, `set image`) that say *how*, and **declarative** `kubectl apply -f` that says *what the end state is*.

### 🔥 Pain points it solves & why this?
- Imperative = fastest for one-off/exam tasks; declarative = idempotent, Git-trackable, repeatable.
- `apply` creates *or* updates — no "already exists" errors, no drift between file and cluster (if you always apply).
- `--dry-run=client -o yaml` bridges both: imperative speed producing declarative files.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `kubectl apply -f` | create-or-update to match the file (idempotent) |
| `kubectl replace -f` | replace an existing object (errors if missing) |
| `kubectl replace --force -f` | delete + recreate (for immutable fields) |
| `kubectl edit` | edit the LIVE object (⚠️ not saved to your file) |
| `--dry-run=client -o yaml` | print the YAML without creating |
| `kubectl explain <res> --recursive` | field docs without leaving the terminal |
| `kubectl api-resources` | every kind, short name, apiVersion, namespaced? |

### 🧪 Hands-on examples

**Example 1 — The exam workflow (generate → edit → apply):**
```bash
export do="--dry-run=client -o yaml"
kubectl run web --image=nginx --port=80 $do > pod.yaml
vi pod.yaml                       # add labels/env/whatever
kubectl apply -f pod.yaml
# Verify: object created exactly as edited; re-running apply is a no-op.
```

**Example 2 — Apply a whole directory idempotently:**
```bash
mkdir app && kubectl create deploy a --image=nginx $do > app/a.yaml \
          && kubectl create deploy b --image=httpd $do > app/b.yaml
kubectl apply -f app/            # creates both
kubectl apply -f app/            # second run: "unchanged" — idempotent
# Verify: no errors on re-apply; declarative wins for repeatability.
```

**Example 3 — Find a field without the docs:**
```bash
kubectl explain pod.spec.containers.resources
kubectl explain deployment.spec.strategy --recursive
kubectl api-resources | grep -iE 'ingress|networkpol'   # kinds + short names
# Verify: you can recover any YAML field name offline — faster than the browser.
```

---

## ➕ Added (not in the transcript, but core-concepts you'll need)

- **Labels vs annotations:** labels are for *selection* (services, RS, deployments find pods by them); annotations are free-form metadata (build info, tool config) — never selected on.
- **`kubectl get all -A`** and **`kubectl describe`** are your two universal recon commands — reflexes for every section that follows.

---

## Related
[02-scheduling](02-scheduling.md) · [04-app-lifecycle](04-application-lifecycle-management.md) · [08-networking](08-networking.md) · [13-troubleshooting](13-troubleshooting.md) · Ladder version: [../README/01-core-concepts.md](../README/01-core-concepts.md)
