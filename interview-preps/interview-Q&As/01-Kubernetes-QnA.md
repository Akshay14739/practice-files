# Kubernetes — Interview Q&A (from Akshay's real interviews)

Consolidated, de-duplicated questions from past Senior DevOps/SRE interviews (HDFC, Trianz, Pure-SW, PwC, Barclays, Shell, Persistent, GlobalLogic, HCL, Virtusa, Accion, HTC, PwC-K8s).
Each entry keeps the honest "as-said" answer, then a senior-level correct answer and a runnable snippet. Within each theme, the questions answered weakest come first — study those hardest.

---

# 1. Core concepts & architecture

## Q1. Walk through exactly what happens when you run `kubectl get pods`.
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
kubectl reads the local kubeconfig for credentials/cluster, contacts the kube API server, which cross-verifies with etcd to fetch the info; if info is missing the API server talks to the node's kubelet to fetch it. When challenged, admitted uncertainty about the API-server-to-kubelet part and said "90% of cases it fetches from etcd."

**✅ Correct answer:**
`kubectl` never talks to etcd or the kubelet for a `get`. Flow:
1. kubectl loads `~/.kube/config`, resolves the current **context** (cluster URL + auth: client cert, token, or an exec plugin like `aws eks get-token`).
2. It builds an HTTPS REST request: `GET /api/v1/namespaces/<ns>/pods`, sending the bearer token/cert.
3. The **kube-apiserver** runs the request through **authentication → authorization (RBAC) → admission**.
4. The apiserver reads pod objects **from etcd** (via its watch cache) and returns them. It does **not** call kubelets for a read — Pod status is already reported *into* the apiserver by each node's kubelet and persisted in etcd. kubectl then formats the table client-side.
The apiserver is the *only* component that talks to etcd; everything else (kubelet, scheduler, controllers) goes through the apiserver.

```bash
kubectl get pods -v=8            # -v=8 prints the exact REST calls, headers, and JSON
# GET https://<apiserver>:443/api/v1/namespaces/default/pods?limit=500
kubectl config current-context   # shows which cluster/user kubectl is pointed at
```

---

## Q2. Explain the Kubernetes architecture — API server, etcd, controller, scheduler, kubelet.
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
Master has 4 components: API server (front end for API calls), etcd (key-value store of cluster state), kube-scheduler (picks nodes by resources), kube-controller (maintains pod availability by reconciliation). Managed EKS also has a cloud controller manager. Worker plane: kubelet (manages pods, networking via iptables), kube-proxy, container runtime. (Minor slip: attributed pod-count maintenance to the scheduler instead of the controller.)

**✅ Correct answer:**
**Control plane:**
- **kube-apiserver** — the front door; stateless REST/gRPC server, does authn/authz/admission, and is the *only* writer to etcd.
- **etcd** — consistent, distributed key-value store (Raft) holding all cluster state and the desired spec.
- **kube-scheduler** — watches for unscheduled Pods, filters + scores nodes, and *binds* a Pod to a node. It does **not** keep replica counts.
- **kube-controller-manager** — runs the reconciliation loops (Deployment, ReplicaSet, Node, Job controllers, etc.). The **ReplicaSet controller** is what keeps replica counts correct.
- **cloud-controller-manager** — integrates with the cloud (provisions LBs, EBS volumes, node lifecycle).

**Worker/node plane:**
- **kubelet** — node agent; watches the apiserver for Pods bound to its node, tells the container runtime to run them, runs probes, reports status back.
- **kube-proxy** — programs iptables/IPVS (or is replaced by CNI dataplanes like Cilium eBPF) to implement Service ClusterIP routing.
- **container runtime** — containerd/CRI-O (Docker is deprecated as a runtime) via the CRI.

The whole system is **level-triggered reconciliation**: controllers continuously drive *actual state* toward *desired state* declared in etcd.

```bash
kubectl get componentstatuses            # legacy health of control-plane pieces
kubectl -n kube-system get pods          # see apiserver/scheduler/controller/etcd (self-hosted)
kubectl get --raw='/readyz?verbose'      # apiserver readiness with per-check detail
```

---

## Q3. How does the scheduler decide where to place a Pod?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
The scheduler has a ranking mechanism that checks node CPU/memory availability and, based on the pod's requests/limits, matches by a ranking algorithm and deploys to the relevant node.

**✅ Correct answer:**
Scheduling is a two-phase pipeline per Pod:
1. **Filtering (Predicates)** — eliminate nodes that *can't* run the Pod: insufficient allocatable CPU/mem (based on **requests**, not limits), taints without matching tolerations, nodeSelector/affinity mismatch, unavailable volumes/topology, node not Ready.
2. **Scoring (Priorities)** — rank the surviving nodes: `LeastAllocated`/`MostAllocated` spread, `InterPodAffinity`, `NodeAffinity`, `TopologySpreadConstraint`, `ImageLocality`, etc. Highest score wins (ties broken randomly).
Then the scheduler **binds** the Pod to the node (writes `spec.nodeName`); the kubelet on that node takes over. Note: scoring uses **requests**, so wrong requests are the #1 cause of imbalance.

```yaml
apiVersion: v1
kind: Pod
metadata: { name: web }
spec:
  containers:
  - name: web
    image: nginx:1.27
    resources:
      requests: { cpu: "250m", memory: "256Mi" }   # scheduler places based on THIS
      limits:   { cpu: "500m", memory: "512Mi" }
  nodeSelector: { disktype: ssd }                    # a hard filter
```

---

## Q4. What happens if etcd goes down? Can you back it up?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
Already-deployed apps keep running, but new deployments won't happen and cluster state is lost so the scheduler can't place pods. Use tools like Velero for regular backups so you can restore. (And: yes, an etcd backup can be created.)

**✅ Correct answer:**
If etcd is fully down (loses quorum), the **apiserver goes read-fail/write-fail** — no `kubectl apply`, no scheduling, no controller reconciliation, no Service/endpoint updates. **Existing Pods keep running** because the kubelet and kube-proxy operate on their last known state, but nothing can *change*. Losing etcd = losing the entire cluster's source of truth.
Back it up with **`etcdctl snapshot`** (the authoritative method for self-managed control planes). **On EKS the control plane and etcd are AWS-managed and auto-backed-up** — you cannot snapshot etcd yourself; instead you back up *your* resources with **Velero** (which backs up K8s object manifests + PV data, not raw etcd). So: `etcdctl` for self-managed, Velero for workloads/DR on managed EKS.

```bash
# Self-managed control plane: take & verify a snapshot
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-*.db -w table
# Managed EKS: back up workloads instead
velero backup create full-$(date +%F) --include-namespaces '*'
```

---

## Q5. How does Pod-to-Service communication happen?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Pod-to-pod communication happens through Service objects (five service types, chosen per requirement). Pod-to-service communication happens through labels and selectors.

**✅ Correct answer:**
A **Service** provides a stable virtual IP (ClusterIP) and DNS name in front of a set of Pods. The mapping is by **label selector**: the Service's `selector` matches Pod labels; the **EndpointSlice/endpoints controller** watches ready Pods and keeps the backing IP list current. A client Pod resolves `svc.namespace.svc.cluster.local` via CoreDNS → gets the ClusterIP → **kube-proxy** (iptables/IPVS) or a CNI dataplane DNAT-load-balances the connection to a healthy Pod IP. Only Pods that pass their **readiness probe** are included as endpoints — that's how readiness gates traffic.

```yaml
apiVersion: v1
kind: Service
metadata: { name: web }
spec:
  selector: { app: web }          # matches Pod labels below
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 3
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }   # label the Service selects on
    spec:
      containers: [{ name: web, image: web:1.0, ports: [{ containerPort: 8080 }] }]
```

---

# 2. Workloads & controllers

## Q6. Difference between a StatefulSet and a Deployment — and what mechanism gives a StatefulSet persistence?
**Asked in:** Trianz  |  **My performance:** Partial

**My answer (from transcript):**
StatefulSets provide persistent storage; with Deployments, once it restarts/is killed the data is gone. When pressed: "it gets mounted to a persistent volume," and the StatefulSet retrieves data from the etcd server and continues where it left off; its main property is stable network identity. (The etcd claim is wrong, and "Deployment loses data" is imprecise.)

**✅ Correct answer:**
Both manage Pods, but a **StatefulSet gives each replica a stable identity**:
- **Stable ordinal names** — `web-0`, `web-1`, … (a Deployment gives random hash suffixes).
- **Stable network identity** via a *headless* Service — `web-0.web.ns.svc.cluster.local`.
- **Per-replica persistent storage** via **`volumeClaimTemplates`** — each Pod gets its *own* PVC (`data-web-0`, `data-web-1`) that survives rescheduling and is re-attached to the same ordinal.
- **Ordered, graceful** rollout/scale (0→1→2, reverse on scale-down).

Persistence has **nothing to do with etcd** — data lives on the bound **PersistentVolume** (EBS, etc.). A **Deployment can absolutely use a PVC too**, but all replicas would share one claim (usually wrong for stateful apps) and get no stable identity. So the real difference is *stable identity + per-replica storage + ordering*, not "Deployments lose data."

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: web }
spec:
  serviceName: web            # the governing HEADLESS service -> stable DNS
  replicas: 3
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
      - name: web
        image: nginx:1.27
        volumeMounts: [{ name: data, mountPath: /usr/share/nginx/html }]
  volumeClaimTemplates:       # each pod gets its OWN PVC, re-attached by ordinal
  - metadata: { name: data }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: gp3
      resources: { requests: { storage: 10Gi } }
```

---

## Q7. In blue-green, on what basis does traffic switch between blue and green, and where do you define it?
**Asked in:** Pure-SW  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I'm not sure, I've not worked with blue-green." (Couldn't describe the traffic-switching mechanism / service selector.)

**✅ Correct answer:**
The switch is done by **changing the Service's label selector** (or an ingress/gateway weight) to point at the new ReplicaSet. Blue and green run **simultaneously** as two Deployments distinguished by a `version` label; the single front-door **Service selects one version at a time**. To cut over, you flip `service.spec.selector.version: blue → green` — one atomic API update reroutes 100% of traffic. Rollback is flipping it back. In practice this is automated by **Argo Rollouts / Flagger** or a mesh, which manage the selector/weights and can gate on metrics. The key interview point: **traffic is controlled at the Service/ingress selector, not inside the Deployment.**

```yaml
apiVersion: v1
kind: Service
metadata: { name: web }
spec:
  selector:
    app: web
    version: blue        # <-- flip to "green" to cut traffic over atomically
  ports: [{ port: 80, targetPort: 8080 }]
# Two Deployments exist: web-blue (labels app=web,version=blue) and
# web-green (labels app=web,version=green). The Service picks exactly one.
```

---

## Q8. Difference between Deployment, StatefulSet, and DaemonSet (and what controller runs a node agent like the Elastic Agent)?
**Asked in:** Persistent, Virtusa  |  **My performance:** Correct

**My answer (from transcript):**
Deployment = stateless apps, StatefulSet = stateful apps. Deployments use PVCs, StatefulSets use volumeClaimTemplates. A DaemonSet is a single service running across all nodes. (Elastic Agent → DaemonSet — confirmed correct.)

**✅ Correct answer:**
- **Deployment** → stateless, interchangeable replicas; rolling updates via ReplicaSets; random Pod names; scale freely.
- **StatefulSet** → stable identity, ordered lifecycle, per-replica PVCs (databases, Kafka, ZooKeeper).
- **DaemonSet** → **exactly one Pod per (matching) node**, and auto-adds a Pod when a node joins. Perfect for **node-level agents**: log/metric shippers (Elastic Agent, Fluent Bit), CNI, `kube-proxy`, node exporters, CSI node plugins. Uses tolerations to run on tainted/control-plane nodes.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: elastic-agent, namespace: elastic-system }
spec:
  selector: { matchLabels: { app: elastic-agent } }
  template:
    metadata: { labels: { app: elastic-agent } }
    spec:
      tolerations: [{ operator: Exists }]   # run on every node, incl. tainted ones
      containers:
      - name: agent
        image: docker.elastic.co/beats/elastic-agent:8.14.0
        volumeMounts: [{ name: varlog, mountPath: /var/log, readOnly: true }]
      volumes: [{ name: varlog, hostPath: { path: /var/log } }]
```

---

## Q9. Explain "stable network identity" for a StatefulSet.
**Asked in:** Trianz  |  **My performance:** Correct

**My answer (from transcript):**
A naming convention for StatefulSet pods persists across restarts (same pod names), so if you resolve a pod's DNS to connect to a backend DB you can rely on it.

**✅ Correct answer:**
Each StatefulSet Pod gets a **predictable, persistent DNS name** derived from its ordinal and the governing headless Service: `<pod>.<service>.<namespace>.svc.cluster.local`, e.g. `mysql-0.mysql.db.svc.cluster.local`. This name is stable across reschedules — even if `mysql-0` is recreated on another node, clients can address it by the same hostname, and it re-binds to *its own* PVC. This is essential for clustered/quorum systems where members must find each other by identity (primary vs replicas, seed nodes).

```bash
# Headless service (clusterIP: None) is what publishes per-pod DNS records
kubectl run -it --rm dns --image=busybox:1.36 --restart=Never -- \
  nslookup mysql-0.mysql.db.svc.cluster.local
```

---

## Q10. What deployment strategies exist, and how do rolling / blue-green / canary work?
**Asked in:** Pure-SW, PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Rolling (default): as v2 provisions, v1 goes down simultaneously. Blue-green: blue=old, green=new side by side; once green is verified, traffic switches fully to green and blue is evicted. Canary: deploy new version, route ~15-20% traffic, verify, then scale to 100% while draining the old.

**✅ Correct answer:**
- **Rolling update** (K8s Deployment default) — incrementally replace old Pods with new, governed by `maxSurge`/`maxUnavailable`. Zero extra infra, but old+new run together briefly (needs backward-compatible changes). Rollback = `kubectl rollout undo`.
- **Blue-green** — two full environments; flip the Service/ingress to green after verification; instant cutover and instant rollback, but 2× resources during the window. Native K8s doesn't do the flip for you — use two Deployments + selector, or Argo Rollouts.
- **Canary** — send a small % of live traffic to the new version, watch SLOs/metrics, then progressively increase. Best with a mesh/ingress that supports weighting (Argo Rollouts, Flagger, Istio). Safest for risky changes.

```yaml
# Native rolling update controls
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }   # add 1 new before dropping old
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec: { containers: [{ name: web, image: web:2.0 }] }
```
```bash
kubectl rollout status deploy/web
kubectl rollout undo deploy/web        # roll back to previous ReplicaSet
```

---

# 3. Scheduling & scaling

## Q11. Where does HPA fit — does HPA do node scaling? Explain HPA vs VPA.
**Asked in:** HDFC, GlobalLogic  |  **My performance:** Incorrect

**My answer (from transcript):**
Described HPA with min replicas and requests/limits; said if limits are crossed it adds pods on the same node until a node threshold, then a new node spins up — and answered "yes, HPA can handle both pod and node scaling." For VPA: increasing the defined requests/limits (e.g., 100Mi → 200Mi). Did not actually explain HPA when asked about HPA vs VPA.

**✅ Correct answer:**
These operate at **different layers** — HPA never scales nodes.
- **HPA (Horizontal Pod Autoscaler)** — changes the **replica count** of a Deployment/StatefulSet based on observed metrics (CPU/memory from metrics-server, or custom/external metrics via KEDA). More Pods → more parallelism. It targets *utilization vs requests* (e.g., keep CPU at 60% of request).
- **VPA (Vertical Pod Autoscaler)** — right-sizes a Pod's **requests/limits** (bigger/smaller Pods), recreating Pods to apply. Good for single-instance workloads. **Don't run HPA and VPA on the same CPU/memory metric** — they fight.
- **Node scaling is a separate concern** — done by **Cluster Autoscaler** or **Karpenter**, which add/remove *nodes* when Pods are **Pending** for lack of capacity. Chain: traffic ↑ → HPA adds Pods → Pods go Pending → Karpenter/CA add a node → Pods schedule.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: web }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: web }
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 60 }  # % of the CPU *request*
```

---

## Q12. What is Pod affinity vs Node affinity?
**Asked in:** Pure-SW, HDFC  |  **My performance:** Partial

**My answer (from transcript):**
"Node affinity deploys pods to a specific node; pod affinity means pods deploy to specific node configurations so they don't get scheduled elsewhere." (Confused pod affinity with node affinity — pod affinity is about co-locating relative to *other pods*, not nodes.)

**✅ Correct answer:**
- **Node affinity** — attract a Pod to **nodes** with certain **labels** (e.g., `disktype=ssd`, `topology.kubernetes.io/zone=us-east-1a`, GPU nodes). It's the richer successor to `nodeSelector`, with `requiredDuringScheduling…` (hard) and `preferredDuringScheduling…` (soft).
- **Pod affinity / anti-affinity** — schedule a Pod **relative to other Pods**, evaluated over a **topology key**:
  - *Pod affinity* → co-locate (e.g., put the cache next to the app in the same zone) for latency.
  - *Pod anti-affinity* → spread apart (e.g., keep the 3 web replicas on **different nodes** so one node loss ≠ full outage). This is the fix for Q35.

```yaml
spec:
  affinity:
    nodeAffinity:                       # about NODE labels
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - { key: disktype, operator: In, values: [ssd] }
    podAntiAffinity:                    # about OTHER PODS' labels + topology
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector: { matchLabels: { app: web } }
        topologyKey: kubernetes.io/hostname   # one 'web' pod per node
```

---

## Q13. How do you scale a Kubernetes cluster / how does Karpenter work?
**Asked in:** HDFC, PwC-1, Shell, Barclays  |  **My performance:** Correct

**My answer (from transcript):**
Karpenter coupled with HPA. HPA scales pods on traffic; when node CPU hits a threshold (~80%) Karpenter spins up a new instance in the node group; when utilization drops (~15-20%) it kills idle pods and destroys the EC2 node. Used spot instances to save cost.

**✅ Correct answer:**
Two independent loops:
1. **Pod scaling** — HPA (or KEDA for event/queue-driven) adjusts replica count.
2. **Node scaling** — **Karpenter** watches for **Pending Pods** and provisions **right-sized nodes directly** (it picks instance types/AZ/spot from a `NodePool`, bypassing fixed ASGs). It's faster and more bin-packing-efficient than the classic **Cluster Autoscaler** (which scales predefined ASG node groups). Karpenter also **consolidates** — it drains and removes/replaces under-utilized nodes to cut cost, and can prefer **spot**. Trigger is *unschedulable Pods*, not a raw "80% CPU" number — accurate framing matters in interviews.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: default }
spec:
  template:
    spec:
      requirements:
      - { key: karpenter.sh/capacity-type, operator: In, values: [spot, on-demand] }
      - { key: kubernetes.io/arch, operator: In, values: [amd64] }
      nodeClassRef: { name: default, group: karpenter.k8s.aws, kind: EC2NodeClass }
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized   # bin-pack & remove idle nodes
    consolidateAfter: 30s
  limits: { cpu: "1000" }
```

---

## Q14. What are taints and tolerations, and how do they differ from affinity?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
A node is marked with a taint (key-value); only a pod with a matching toleration can schedule there. With node affinity, key-value pairs direct a pod *to* a particular node.

**✅ Correct answer:**
They're **opposite mechanisms**:
- **Taints (on nodes) + Tolerations (on Pods)** are **repelling** — a taint says "keep Pods off unless they explicitly tolerate me." Effects: `NoSchedule` (block new), `PreferNoSchedule` (soft), `NoExecute` (also evict existing). Use for **dedicated/special nodes** (GPU, licensed, control-plane). A toleration only *permits* scheduling — it doesn't *attract*.
- **Node affinity** is **attracting** — it actively pulls Pods **toward** labeled nodes.
Real dedicated-node pattern = **taint the node** (repel everyone) **+ affinity/nodeSelector** on the special Pods (pull them in), so only they land there and *only* there.

```bash
kubectl taint nodes gpu-node-1 dedicated=gpu:NoSchedule
```
```yaml
spec:
  tolerations:
  - { key: dedicated, operator: Equal, value: gpu, effect: NoSchedule }
  nodeSelector: { hardware: gpu }   # affinity pulls it TO the gpu node
```

---

## Q15. To run multiple applications on one cluster, how do you isolate them?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
Use multiple namespaces, one per application, and define resource quotas per namespace so it doesn't exceed the node's threshold.

**✅ Correct answer:**
**Namespaces** are the primary logical boundary; harden them with:
- **ResourceQuota** — cap total CPU/mem/object counts per namespace.
- **LimitRange** — default/मmax per-Pod requests/limits so one Pod can't hog a node.
- **NetworkPolicy** — restrict cross-namespace traffic (default-deny + allow-lists).
- **RBAC** — scope each team's access to its namespace.
For **hard** multi-tenant isolation (untrusted tenants), namespaces alone aren't enough — add separate node pools (taints), PodSecurity/Kyverno policies, and often **separate clusters** or vClusters.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: { name: team-a-quota, namespace: team-a }
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    pods: "50"
```

---

# 4. Networking & services

## Q16. Service-to-service traffic inside the cluster is plain HTTP. Compliance wants it encrypted. How?
**Asked in:** PwC-K8s  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I'm sure there are ways to secure microservices inside the cluster, but I'm not sure of the exact methods. I haven't worked on it." (Did not mention mTLS / service mesh.) Also: hadn't worked on Istio/Linkerd (Linkerd was a POC when he left).

**✅ Correct answer:**
The standard answer is **mutual TLS (mTLS)** for east-west traffic, delivered most cleanly by a **service mesh** so apps don't change code:
- **Istio / Linkerd / Cilium** inject a **sidecar (or eBPF) proxy** that transparently upgrades pod-to-pod connections to mTLS, issuing/rotating short-lived certs from the mesh CA. Istio's `PeerAuthentication STRICT` enforces mesh-wide mTLS.
- Alternatives without a full mesh: **SPIFFE/SPIRE** for workload identity, app-level TLS with cert-manager-issued certs, or **Cilium** transparent encryption (WireGuard/IPsec) at the node/network layer.
The interview keyword they wanted: **mTLS via a service mesh**.

```yaml
# Istio: force mTLS for ALL services in the mesh
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: istio-system }
spec:
  mtls: { mode: STRICT }
```

---

## Q17. How does Kubernetes networking work?
**Asked in:** GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
Described kube-proxy plus 5 service types (ClusterIP, NodePort, LoadBalancer, ExternalName…). Listed ExternalName twice and conflated it with headless/DNS; slightly garbled.

**✅ Correct answer:**
The Kubernetes network model has three rules: **every Pod gets its own IP**, **all Pods can reach all Pods without NAT**, and node agents can reach all Pods. It's implemented at layers:
1. **CNI plugin** (Calico, Cilium, AWS VPC CNI) gives each Pod an IP and wires pod-to-pod routing. On EKS the **VPC CNI** assigns real VPC IPs to Pods.
2. **Service abstraction** — a stable virtual IP for a set of Pods; **kube-proxy** programs iptables/IPVS (or Cilium eBPF replaces it) to DNAT ClusterIP → a Pod IP.
3. **DNS** — CoreDNS resolves `service.namespace.svc.cluster.local`.
4. **Ingress/Gateway** for north-south HTTP routing; **NetworkPolicy** for L3/L4 segmentation.
Service types are just *how a Service is exposed* (ClusterIP internal, NodePort, LoadBalancer, ExternalName=DNS CNAME), sitting on top of that pod network.

```bash
kubectl get pods -o wide                 # see each Pod's own IP
kubectl -n kube-system get pods -l k8s-app=kube-dns   # CoreDNS
kubectl get svc -A                       # ClusterIP/NodePort/LB mappings
```

---

## Q18. What is an Ingress controller and how does it work?
**Asked in:** Trianz, Pure-SW  |  **My performance:** Partial

**My answer (from transcript):**
The Ingress controller detects new Ingress resources and implements the routing logic (path-based routing to multiple backend services). Correct in gist but vague — didn't say it's a reverse proxy/load balancer watching Ingress objects.

**✅ Correct answer:**
Two distinct things:
- **Ingress resource** — a declarative object describing L7 HTTP rules (host/path → Service).
- **Ingress controller** — a running **reverse proxy / load balancer** (NGINX, AWS Load Balancer Controller, Traefik, Istio Gateway) that **watches** Ingress objects via the apiserver and **reconciles** its own config (or provisions a cloud ALB) to match. Without a controller, an Ingress object does nothing. It terminates TLS, does host/path routing, sticky sessions, rewrites, etc. On EKS, the **AWS Load Balancer Controller** turns an Ingress into an **ALB** with target groups pointing at your pods.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  annotations: { kubernetes.io/ingress.class: nginx }
spec:
  tls: [{ hosts: [shop.example.com], secretName: shop-tls }]
  rules:
  - host: shop.example.com
    http:
      paths:
      - { path: /api,  pathType: Prefix, backend: { service: { name: api, port: { number: 80 } } } }
      - { path: /,     pathType: Prefix, backend: { service: { name: web, port: { number: 80 } } } }
```

---

## Q19. In a 3-tier app (frontend, backend, DB), block frontend→DB but allow backend→DB. How? And what are NetworkPolicies generally?
**Asked in:** PwC-K8s, GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
Use a NetworkPolicy so communication flows only backend→DB; once a NetworkPolicy is enabled it defaults to deny both ingress and egress, so frontend can't reach DB. Concept right, phrasing imprecise. (GlobalLogic: policies define ingress/egress; once enabled, everything not allowed is denied.)

**✅ Correct answer:**
NetworkPolicies are **namespaced L3/L4 allow-lists** enforced by the CNI (Calico, Cilium; note the AWS VPC CNI needs the Network Policy add-on). Important nuance: policies are **additive and default-allow *until* a Pod is selected by at least one policy** — once selected, only explicitly allowed traffic is permitted (implicit deny for that direction). So to block frontend→DB: put a policy on the **DB Pods** that allows **ingress only from Pods labeled `tier=backend`**. Frontend, not being in the allow-list, is denied.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-allow-backend, namespace: shop }
spec:
  podSelector: { matchLabels: { tier: db } }   # applies to DB pods
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: { matchLabels: { tier: backend } }   # ONLY backend allowed
    ports: [{ protocol: TCP, port: 5432 }]
# frontend has no matching 'from' rule => implicitly denied to the DB
```

---

## Q20. How do you expose/connect to a frontend app from outside, securely?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Route 53 DNS → ALB (via ALB controller + ingress), path/host-based routing in ingress, HTTPS/TLS cert, auth via Azure identity/Okta.

**✅ Correct answer:**
Layer it: **Route 53** record → **ALB** (provisioned by the AWS Load Balancer Controller from an Ingress) → **ClusterIP** Services → Pods. Secure it with:
- **TLS termination** at the ALB using an **ACM** certificate (annotation on the Ingress), enforce HTTPS + redirect HTTP→HTTPS.
- **WAF** on the ALB for L7 protection; security groups to restrict sources.
- **AuthN** via OIDC (Okta/Azure AD) — either at the ALB (`authenticate-oidc`) or an oauth2-proxy/mesh.
- Backends stay **private (ClusterIP)** in private subnets; only the ALB is public.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...:certificate/xxxx
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
  - host: app.example.com
    http:
      paths: [{ path: /, pathType: Prefix, backend: { service: { name: web, port: { number: 80 } } } }]
```

---

## Q21. What Service types exist and when do you use each?
**Asked in:** Barclays, GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
ClusterIP, NodePort, LoadBalancer, Headless, ExternalName. ClusterIP for internal; NodePort to reach a pod from outside a node; LoadBalancer via cloud LB; ExternalName/Headless to resolve a pod DNS to a backend/DB. Slightly muddled headless vs ExternalName.

**✅ Correct answer:**
- **ClusterIP** (default) — internal-only virtual IP; pod-to-pod / service-to-service.
- **NodePort** — opens the same high port (30000–32767) on every node; basic external access / behind an external LB. Rarely used directly in prod.
- **LoadBalancer** — provisions a cloud L4 LB (NLB/ELB) mapped 1:1 to the Service; external entry for a single service.
- **Headless** (`clusterIP: None`) — **no virtual IP**; DNS returns the **individual Pod IPs**. Used by StatefulSets/clients that need per-pod addressing or do their own LB.
- **ExternalName** — pure **DNS CNAME** to an external hostname (e.g., an RDS endpoint); no proxying, no selector.

```yaml
apiVersion: v1
kind: Service
metadata: { name: db-headless }
spec:
  clusterIP: None                 # headless: DNS returns each pod IP
  selector: { app: mysql }
  ports: [{ port: 3306 }]
---
apiVersion: v1
kind: Service
metadata: { name: prod-db }
spec:
  type: ExternalName              # CNAME to an external endpoint
  externalName: mydb.abc123.us-east-1.rds.amazonaws.com
```

---

## Q22. With many microservices, do you create one LoadBalancer per service? And from ingress, what Service type does the backend use?
**Asked in:** Barclays  |  **My performance:** Correct

**My answer (from transcript):**
No — a LoadBalancer service is 1:1 with a cloud LB, so many services = many LBs = costly and no routing. Use an Ingress with multiple paths to backend services. From ingress, the backend pods use **ClusterIP**.

**✅ Correct answer:**
Correct. A `type: LoadBalancer` Service maps 1:1 to a (billed) cloud LB and gives you no L7 routing — dozens of microservices would mean dozens of LBs. Instead, use **one Ingress (one ALB/NGINX)** that host/path-routes to many services. Those backend Services are **ClusterIP** (internal), since the ingress controller is the single public entry point. This is cheaper, centralizes TLS/WAF/auth, and gives real HTTP routing.

```yaml
# One ingress fronts many ClusterIP services
spec:
  rules:
  - http:
      paths:
      - { path: /orders,  pathType: Prefix, backend: { service: { name: orders,  port: { number: 80 } } } }
      - { path: /users,   pathType: Prefix, backend: { service: { name: users,   port: { number: 80 } } } }
      - { path: /catalog, pathType: Prefix, backend: { service: { name: catalog, port: { number: 80 } } } }
```

---

## Q23. Why use ingress controllers (NGINX/Istio) instead of just a load balancer?
**Asked in:** Virtusa  |  **My performance:** Correct

**My answer (from transcript):**
Ingress controllers provide sophisticated routing a plain LB can't; wiring each service to its own LB is costly and lacks routing. With multiple services, use ingress. (Admitted limited Istio knowledge.)

**✅ Correct answer:**
A cloud LB is L4 (IP:port) — it can't route by host/path, can't do per-route TLS, header/cookie routing, rewrites, rate-limiting, canary weights, or auth. An **ingress controller is an L7 reverse proxy** that adds all of that and consolidates many services behind **one** LB (cost + centralized TLS/observability). A **service mesh (Istio)** goes further for **east-west** traffic: mTLS, retries/timeouts, traffic-splitting, circuit breaking, and rich telemetry between services — things ingress (north-south only) doesn't cover.

```yaml
# NGINX ingress: canary + rate limiting via annotations
metadata:
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"     # 20% to this backend
    nginx.ingress.kubernetes.io/limit-rps: "50"
```

---

## Q24. Design a 3-tier setup where the frontend is public and the backend is private.
**Asked in:** HCL  |  **My performance:** Correct

**My answer (from transcript):**
Installed the AWS ALB controller and deployed ingress. DNS → ALB → ingress routes to backend microservices. Microservices run on EC2 in private subnets (no external/jump access). Added network policies so requests only come from the ingress to the pods. LB is public via DNS.

**✅ Correct answer:**
- **Public tier:** Route 53 → **internet-facing ALB** (public subnets) provisioned by the AWS LB Controller from an Ingress, TLS via ACM, WAF attached.
- **Private tiers:** worker nodes in **private subnets**; backend and DB Services are **ClusterIP** only (never LoadBalancer). Node egress via NAT gateway.
- **Segmentation:** **NetworkPolicies** — frontend accepts only from the ALB, backend accepts only from frontend, DB accepts only from backend.
- **DB:** external RDS via **ExternalName** or a StatefulSet with per-replica PVCs; secrets via IRSA + Secrets Manager.
This gives one public ingress and everything else private, defense-in-depth with policies + security groups.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: backend-from-frontend, namespace: shop }
spec:
  podSelector: { matchLabels: { tier: backend } }
  policyTypes: [Ingress]
  ingress:
  - from: [{ podSelector: { matchLabels: { tier: frontend } } }]
    ports: [{ protocol: TCP, port: 8080 }]
```

---

# 5. Storage

## Q25. Describe your storage management work. (What actually provides persistence?)
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Used a ConfigMap for backend DB connection details injected into pods, and an ExternalName Service to resolve the DB DNS — claimed this keeps backend data persistent across restarts. (Conflated ConfigMap/ExternalName *connectivity* with actual *storage persistence*.)

**✅ Correct answer:**
That's **connectivity/config**, not storage. ConfigMaps hold config; ExternalName is a DNS CNAME to reach an external DB — neither stores or persists application data. **Persistence in Kubernetes means a PersistentVolume**: a **PVC** requests storage, a **StorageClass** dynamically provisions the backing volume (EBS/EFS), and it's mounted into the Pod so data survives Pod restarts/reschedules. If the data lives in an external managed DB (RDS), then "persistence" is the DB's job and K8s just needs the connection string (ConfigMap) + credentials (Secret/IRSA) — but you shouldn't call that "storage management." Be precise: **config vs secrets vs persistent volumes are three different things.**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3            # dynamic provisioning of an EBS volume
  resources: { requests: { storage: 20Gi } }
---
# Pod mounts it -> data persists across restarts/reschedules
volumeMounts: [{ name: data, mountPath: /var/lib/app }]
volumes: [{ name: data, persistentVolumeClaim: { claimName: data } }]
```

---

## Q26. For multi-region storage with a PVC, which StorageClass would you prefer?
**Asked in:** Trianz  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I've worked with this long back, I've forgotten."

**✅ Correct answer:**
Key fact: **EBS is single-AZ (zonal)** — a `gp3` PVC can't move across AZs, let alone regions. Options by need:
- **Cross-AZ, shared, ReadWriteMany** → **EFS** (`efs.csi.aws.com`) — a network filesystem reachable from all AZs in a region.
- **Region-resilient block** → keep EBS/gp3 but rely on **volume snapshots replicated cross-region** (VolumeSnapshot + DR restore), since block volumes don't span regions live.
- **Multi-region active data** → don't push it through a single PVC; use a **replicated data service** (RDS/Aurora Global, DynamoDB Global Tables, or an object store like S3). Storage classes don't give you cross-region replication for block volumes — the app/data layer does.
So: **EFS for cross-AZ shared**, **snapshots for DR**, and a **replicated managed datastore for true multi-region**.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: efs-sc }
provisioner: efs.csi.aws.com     # RWX, reachable from every AZ in the region
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0123456789
```

---

## Q27. Explain PV, PVC, and StorageClasses.
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
PVCs bind the storage volume from the provisioner to the pod (e.g., pre-provisioned EBS bound to the pod), so data survives pod deletion/redeployment. StorageClasses provide dynamic provisioning.

**✅ Correct answer:**
- **PersistentVolume (PV)** — a cluster resource representing a real piece of storage (an EBS volume, EFS share). Cluster-scoped, has a lifecycle independent of Pods.
- **PersistentVolumeClaim (PVC)** — a namespaced *request* for storage (size + access mode). It **binds** to a PV.
- **StorageClass** — a template for **dynamic provisioning**: when a PVC references a StorageClass, the CSI driver **creates the PV automatically** (no manual pre-provisioning). It also sets `reclaimPolicy` (Delete/Retain) and `volumeBindingMode` (`WaitForFirstConsumer` delays binding until a Pod is scheduled, so the volume lands in the right AZ).
Access modes: **RWO** (one node, EBS), **RWX** (many nodes, EFS), **ROX**.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gp3 }
provisioner: ebs.csi.aws.com
parameters: { type: gp3, encrypted: "true" }
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer   # bind after scheduling -> correct AZ
```

---

## Q28. Explain requests vs limits.
**Asked in:** Shell, HTC  |  **My performance:** Correct

**My answer (from transcript):**
Requests = minimum resources for the pod to run; limits = the upper cutoff. Exceed the memory limit → OOMKilled; exceeding limits can cause CrashLoopBackOff/Pending.

**✅ Correct answer:**
- **Request** — the **guaranteed reserved** amount used by the **scheduler** to place the Pod (and to compute node fit). CPU request also sets the CFS scheduling weight.
- **Limit** — the **hard ceiling** enforced at runtime. **CPU over-limit is throttled** (not killed); **memory over-limit is OOMKilled** (memory isn't compressible).
- **QoS classes** derive from these: `Guaranteed` (requests==limits for all resources), `Burstable` (requests<limits), `BestEffort` (none) — driving **eviction order** under node pressure (BestEffort evicted first).
Correct the transcript nuance: hitting the *CPU* limit does **not** cause CrashLoopBackOff — it throttles; only *memory* over-limit kills the container.

```yaml
resources:
  requests: { cpu: "250m", memory: "256Mi" }   # scheduled & guaranteed
  limits:   { cpu: "500m", memory: "512Mi" }   # CPU throttled, memory OOMKilled
# requests==limits on both => Guaranteed QoS (last to be evicted)
```

---

## Q29. Difference between a ConfigMap and a Secret.
**Asked in:** Trianz  |  **My performance:** Correct

**My answer (from transcript):**
ConfigMap stores non-sensitive config (ports, usernames, DB DNS); Secret stores sensitive info like passwords, base64-encoded so general audiences can't read it. Both can be injected into pods; there are better ways to handle secrets.

**✅ Correct answer:**
Both inject config into Pods (as env vars or mounted files), but a **Secret is not encrypted by default** — it's only **base64-encoded** (trivially decodable). To actually protect Secrets: enable **etcd encryption-at-rest**, lock down with **RBAC**, and prefer an **external secrets store** (AWS Secrets Manager/Vault via the **Secrets Store CSI driver** or External Secrets Operator, using **IRSA/Pod Identity**). Never commit Secrets to Git in plaintext — use Sealed Secrets / SOPS for GitOps.

```bash
kubectl create secret generic db-cred \
  --from-literal=username=app --from-literal=password='S3cr3t!'
# base64 only -> decode proves it's not encrypted:
kubectl get secret db-cred -o jsonpath='{.data.password}' | base64 -d
```

---

# 6. Probes & pod lifecycle

## Q30. Ensure the DB is ready before the app starts / app returns 503 for 30-40s until it initializes — how do you gate traffic and startup?
**Asked in:** PwC-K8s (×4 related follow-ups)  |  **My performance:** Incorrect

**My answer (from transcript):**
Fetch DB secrets via pod identity + secret manager; inject config via ConfigMap; connect through an ExternalName Service. For the 503s, blamed security groups/ports/label mismatch, and network latency (netstat). Circled around the idea (run a shell script to test connectivity) without naming the actual features. (Missed: readiness probe, init container, startup probe.)

**✅ Correct answer:**
This is the flagship gap — three purpose-built features:
- **Readiness probe** — the direct fix for "new Pod serves 503 for 30-40s." A Pod is only added to the Service's endpoints when its readiness probe passes, so **traffic isn't routed until the app has fetched secrets / connected to the DB / warmed up**. That eliminates the 503 window entirely.
- **initContainer** — runs to completion **before** the main container; use it to **wait for the DB** (block until the DB port answers) so ordering is guaranteed.
- **startup probe** — for slow-starting apps; disables liveness/readiness until startup completes so a slow boot isn't mistaken for a crash.
The failure in the interview was reaching for network/infra causes instead of naming **readiness probe** — memorize: *"new pod, running, but not ready → readiness probe."*

```yaml
spec:
  initContainers:
  - name: wait-for-db                     # gate startup on DB availability
    image: busybox:1.36
    command: ['sh','-c','until nc -z db 5432; do echo waiting; sleep 2; done']
  containers:
  - name: app
    image: app:1.0
    readinessProbe:                       # gate TRAFFIC until app is ready
      httpGet: { path: /healthz/ready, port: 8080 }
      initialDelaySeconds: 5
      periodSeconds: 5
    startupProbe:                         # allow up to 60s cold start
      httpGet: { path: /healthz/started, port: 8080 }
      failureThreshold: 12
      periodSeconds: 5
```

---

## Q31. Explain liveness and readiness (and startup) probes.
**Asked in:** Barclays  |  **My performance:** Partial

**My answer (from transcript):**
Liveness checks if the pod is running (its status); readiness checks if it can receive/handle traffic. Core idea right, but liveness described loosely.

**✅ Correct answer:**
- **Liveness** — "is the app **still healthy**?" If it **fails, the kubelet restarts the container** (fixes deadlocks/hangs). It is *not* about whether the process exists — it detects a *stuck* process and heals it.
- **Readiness** — "can it **serve traffic right now**?" If it fails, the Pod is **removed from Service endpoints** (no traffic) but **not restarted**. Used for warmup and for shedding load when a dependency is down.
- **Startup** — protects **slow starters**: liveness/readiness are suspended until startup passes, so a long boot isn't killed as a crash.
Common mistake: pointing liveness at a dependency (DB) — a DB blip then restart-storms all Pods. Liveness should check only the process's *own* health; use readiness for dependencies.

```yaml
livenessProbe:                 # restart if unhealthy/stuck
  httpGet: { path: /healthz/live, port: 8080 }
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:                # pull from LB if not ready (no restart)
  httpGet: { path: /healthz/ready, port: 8080 }
  periodSeconds: 5
```

---

## Q32. Walk through the Pod lifecycle phases and what causes transitions.
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Guessed "initialization" is the first phase; a container runs through image layers; if all execute it's Running; config issues / pending volume/secret cause Pending, CrashLoopBackOff, or ImagePullBackOff. Didn't name the formal phases cleanly.

**✅ Correct answer:**
The formal **Pod phases** are: **Pending → Running → Succeeded / Failed** (plus **Unknown**).
- **Pending** — accepted by the apiserver but not all containers running yet: waiting to be scheduled, pulling images, or waiting on volumes/secrets.
- **Running** — Pod is bound to a node and at least one container is running/starting/restarting.
- **Succeeded** — all containers exited 0 and won't restart (Jobs).
- **Failed** — all containers terminated, at least one non-zero.
Note: **`CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled`, `ContainerCreating`** are **container/waiting reasons**, *not* phases — they show under Pod conditions/container statuses while the Pod is Pending/Running. Also relevant: init containers run first, then app containers, with the restart behavior governed by `restartPolicy`.

```bash
kubectl get pod web -o jsonpath='{.status.phase}'; echo
kubectl get pod web -o jsonpath='{.status.containerStatuses[*].state}'; echo
kubectl describe pod web | sed -n '/Conditions/,/Events/p'
```

---

## Q33. What are init containers?
**Asked in:** Persistent  |  **My performance:** Didn't-know

**My answer (from transcript):**
Heard of them but hasn't used/studied them; guessed it's a sidecar container (incorrect).

**✅ Correct answer:**
**init containers** run **sequentially, to completion, before** any app container starts. Each must exit 0 before the next runs; if one fails, the kubelet restarts it (per `restartPolicy`) and the Pod stays in **Init:**. They're **not** sidecars (sidecars run *alongside* the main container for the Pod's lifetime). Uses: **wait for a dependency** (DB/service), run **schema migrations**, fetch config/secrets or clone content into a shared `emptyDir`, set kernel params, or do one-time setup that needs different tools/permissions than the app image.
(K8s 1.29+ also adds *native sidecar containers* — an init container with `restartPolicy: Always` that stays running — but classic init containers still run-and-exit.)

```yaml
spec:
  initContainers:
  - name: migrate
    image: migrate/migrate:v4
    command: ['migrate','-path','/mig','-database','$(DB_URL)','up']   # runs once, must succeed
  containers:
  - { name: app, image: app:1.0 }   # starts only after migrate exits 0
```

---

## Q34. What is a sidecar container, and where would you use one?
**Asked in:** Persistent, PwC-K8s  |  **My performance:** Partial / Vague

**My answer (from transcript):**
A sidecar spins up alongside the main container to support it (e.g., collecting logs). For a use case, guessed Crossplane could use one to temporarily save credentials (tentative/vague). PwC: "No sidecars while I was on the team."

**✅ Correct answer:**
A **sidecar** is a helper container in the **same Pod** as the main app — it **shares the Pod's network and can share volumes**, running for the Pod's lifetime to augment the app *without changing its code*. Classic uses:
- **Log/metric shipping** (Fluent Bit reading a shared `emptyDir`).
- **Service mesh proxy** (Envoy/istio-proxy for mTLS, retries, telemetry).
- **Secrets/config agent** (Vault agent, Secrets Store CSI) injecting/rotating creds.
- **Proxies** (cloud-sql-proxy, oauth2-proxy).
As of K8s 1.29+ sidecars are **first-class**: an initContainer with `restartPolicy: Always` starts before the app, stays running, and is guaranteed to shut down *after* the app — solving old ordering problems.

```yaml
spec:
  initContainers:
  - name: log-shipper                 # native sidecar (K8s 1.29+)
    image: fluent/fluent-bit:3.0
    restartPolicy: Always             # <-- makes it a long-running sidecar
    volumeMounts: [{ name: logs, mountPath: /var/log/app }]
  containers:
  - name: app
    image: app:1.0
    volumeMounts: [{ name: logs, mountPath: /var/log/app }]
  volumes: [{ name: logs, emptyDir: {} }]
```

---

# 7. Troubleshooting scenarios

## Q35. 2-3 frontend replicas land on the same node; a node drain deletes them all → ~30s downtime. How do you avoid this?
**Asked in:** PwC-K8s  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I understand the question but haven't done this, so I don't know the exact way — I can figure it out." (Intended: pod anti-affinity / topology spread + PodDisruptionBudget.)

**✅ Correct answer:**
Two complementary controls:
1. **Spread the replicas** so they never all sit on one node — **pod anti-affinity** (`topologyKey: kubernetes.io/hostname`) or, better, **topologySpreadConstraints** across nodes/zones. Then draining one node can't take out all replicas.
2. **PodDisruptionBudget (PDB)** — caps **voluntary** disruptions (drains/upgrades). `minAvailable: 1` (or `maxUnavailable: 1`) makes `kubectl drain` **wait/refuse** to evict a Pod if it would drop below the budget, so the node cordon/drain proceeds only as replacements come up elsewhere.
Together: anti-affinity prevents co-location, PDB prevents simultaneous eviction → zero-downtime node maintenance. (Readiness probes on the new Pods ensure traffic only shifts once they're ready.)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: web-pdb }
spec:
  minAvailable: 2                         # drain can't drop below 2 ready pods
  selector: { matchLabels: { app: web } }
---
# in the Deployment pod template:
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
  labelSelector: { matchLabels: { app: web } }
```

---

## Q36. An app just spins/won't load; hitting the API hangs. How do you troubleshoot?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Checked VPC security groups, NACLs, WAF first; then backend services and ingress; then network policies and label/selector matching. Jumped to infra before the interviewer redirected to monitoring/logging.

**✅ Correct answer:**
Work **top-down through the request path with observability first**, not straight to infra:
1. **Pods** — `kubectl get pods` (Ready? Restarts? CrashLoop/OOM?), then `kubectl logs` / `kubectl describe` for the app's own errors.
2. **Service/endpoints** — `kubectl get endpoints <svc>`: **empty endpoints = selector/readiness problem** (a very common cause of "spins forever").
3. **Ingress/DNS** — controller healthy? cert valid? DNS resolves? check ingress controller logs.
4. **Dependencies** — DB/cache reachable? (the app may be blocking on a downstream). Metrics/traces (Prometheus/Grafana, distributed tracing) pinpoint the slow hop.
5. **Only then network/infra** — NetworkPolicy, SGs/NACLs.
The senior signal is **starting from logs/metrics/endpoints**, isolating *which hop* fails, before touching VPC config.

```bash
kubectl get pods -o wide
kubectl get endpoints web            # <-- empty? Service selects nothing / not ready
kubectl logs deploy/web --tail=100
kubectl describe pod <pod> | tail -30
kubectl top pods                     # resource pressure / throttling
```

---

## Q37. How do you troubleshoot a Pod in CrashLoopBackOff?
**Asked in:** GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
Usually app config errors, missing env vars, or wrong image. Get cluster access, `kubectl get pods`, then `kubectl describe pod`, and bucket the issue (storage/network/process/security) to troubleshoot further.

**✅ Correct answer:**
CrashLoopBackOff = the container **starts, exits, and the kubelet keeps restarting it with backoff**. Diagnose in order:
1. **`kubectl logs <pod> --previous`** — logs of the *crashed* instance (the single most useful command). Reveals app stack traces, missing env/config, failed DB connect.
2. **`kubectl describe pod`** — check **Last State / Exit Code / Reason**: `OOMKilled` (137 → raise memory limit), config/secret missing, failing **liveness probe** restarting a healthy-but-slow app, or bad command/entrypoint.
3. **Exit code clues** — 1 (app error), 137 (OOM/SIGKILL), 139 (segfault), 143 (SIGTERM).
4. Fix root cause: bad image/tag, missing ConfigMap/Secret, wrong command, too-tight memory limit, or a mis-tuned probe.

```bash
kubectl logs <pod> --previous            # logs from the crashed container
kubectl describe pod <pod> | grep -A5 -iE 'last state|exit code|reason'
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

---

## Q38. A Pod is restarting continuously — what do you check?
**Asked in:** Barclays  |  **My performance:** Correct

**My answer (from transcript):**
`kubectl describe pod` and `kubectl logs`, then triage network/storage/process. Common causes: memory leaks, wrong policies/limits, pending on a PV. Use logs to bifurcate. Solid systematic approach.

**✅ Correct answer:**
Good instincts. Structured checklist:
- **`--previous` logs + exit code** (as Q37). `137` → **OOMKilled**: memory limit too low or a leak → raise limit / fix leak.
- **Probe misconfiguration** — an aggressive **liveness probe** (short `timeoutSeconds`/`failureThreshold`, wrong path/port) restarts a healthy app; add a **startupProbe** for slow boots.
- **Missing dependency** at boot — DB/secret/config not present → app exits; fix with initContainer/readiness.
- **Bad image/command**, or **node pressure/eviction**.
Confirm with `kubectl describe pod` events and `kubectl get events --sort-by=.lastTimestamp`.

```bash
kubectl get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" restarts="}{.restartCount}{" reason="}{.lastState.terminated.reason}{"\n"}{end}'
kubectl get events --sort-by=.lastTimestamp | tail -20
```

---

## Q39. After upgrading EKS in Dev, the application isn't working. Now what?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
With CLI access, check pod logs, `describe`/`logs`, bucket into storage/security/network/processing, do RCA and fix.

**✅ Correct answer:**
Post-upgrade breakage is usually **deprecated/removed APIs or add-on incompatibility**, so check upgrade-specific causes, not just generic triage:
1. **Removed API versions** — the app's manifests may use APIs the new K8s version dropped (e.g., old `Ingress`, `PodSecurityPolicy`, `batch/v1beta1 CronJob`). Run **`kubectl api-resources` / `kubectl-convert`** and check the **EKS upgrade insights**.
2. **Add-on/CNI/CSI version skew** — VPC CNI, CoreDNS, kube-proxy must match the new control-plane version; upgrade them.
3. **Node version skew** — control plane can't be >1 (now up to 3) minor versions ahead of nodes; upgrade node groups.
4. Then **normal triage** — `describe`/`logs`/events for the actual failure, and if it's an EKS control-plane regression, the **fast rollback is redeploying workloads to a parallel cluster** (you can't downgrade an EKS control plane).

```bash
# find objects using soon-to-be-removed APIs before/after upgrade
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
kubectl api-resources --verbs=list -o name | xargs -n1 kubectl get -A -o name 2>/dev/null | head
# ensure add-ons match the new control-plane version
aws eks describe-addon --cluster-name prod --addon-name vpc-cni
```

---

# 8. Cluster operations: upgrades, node patching & DR

## Q40. Upgrade an EKS cluster while keeping running services available — full procedure.
**Asked in:** HDFC, Virtusa, Trianz-K8s  |  **My performance:** Incomplete / Partial

**My answer (from transcript):**
Terraform repo; bump the version; upgrade control-plane components first, then node groups via rotation; test in lower environments then prod, on weekends. Interviewer flagged it as insufficient — missing cordon/drain, pod evacuation specifics; and elsewhere admitted he hadn't actually done cluster upgrades.

**✅ Correct answer:**
EKS upgrades are **one minor version at a time**, in this order:
1. **Pre-checks** — read the version's breaking changes; scan for **removed APIs** (upgrade insights); confirm add-on/node compatibility; ensure PDBs and ≥2 replicas exist; back up (Velero).
2. **Control plane** — AWS upgrades the managed control plane in place (`aws eks update-cluster-version`). No node impact.
3. **Add-ons** — upgrade **VPC CNI, CoreDNS, kube-proxy** to match.
4. **Nodes** — with **managed node groups**, the managed flow **cordons and drains** each node **respecting PDBs**, launches replacement nodes on the new AMI, and shifts Pods — no manual "backup EC2." For zero downtime you rely on **≥2 replicas + PDB + readiness probes** so drains never remove the last ready Pod.
5. **Validate** per environment (dev → staging → prod). **No rollback** for the control plane — hence the pre-checks.

```bash
aws eks update-cluster-version --name prod --kubernetes-version 1.31
# managed node group rolling upgrade (cordon/drain honoring PDBs, new AMI):
aws eks update-nodegroup-version --cluster-name prod --nodegroup-name ng-1
# guardrails that make the drain safe:
kubectl get pdb -A
kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,REPL:.spec.replicas
```

---

## Q41. Managed vs self-managed node groups — with managed node groups you can't "add a backup EC2," so how does the node upgrade actually work?
**Asked in:** HDFC  |  **My performance:** Didn't-know

**My answer (from transcript):**
Believed it was fully automated and that they were managed node groups; when pressed, admitted "that's what my leads told me; what happened in the backend I'm not sure — another team handled it."

**✅ Correct answer:**
- **Managed node groups** — AWS runs the node lifecycle. On upgrade it does a **rolling replacement**: creates a new **ASG launch template** with the new EKS-optimized AMI, **scales up new nodes**, **cordons + drains old nodes honoring PodDisruptionBudgets**, then terminates them. You never manually attach a "backup EC2" — replacement is inherent. Config: `updateConfig.maxUnavailable`.
- **Self-managed nodes** — you own the ASG/AMI (e.g., custom **Packer** AMIs) and drive the drain/replace yourself (or via tools like `eksctl`, node-termination-handler).
So the honest, correct mechanism is **new nodes up → drain old (PDB-aware) → old terminated**, not patch-in-place. In-place OS patching also exists but the **immutable "replace the node" pattern is the standard** for EKS, especially with custom AMIs.

```bash
# managed node group replacement controls
aws eks update-nodegroup-config --cluster-name prod --nodegroup-name ng-1 \
  --update-config maxUnavailablePercentage=25
# self-managed equivalent, done manually:
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # then terminate & replace
```

---

## Q42. How do you patch/set up EKS nodes (given custom AMIs)?
**Asked in:** Shell, Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
Node rotation, mostly weekends: drain node, redeploy pods elsewhere, run patching/security tests on the drained node, redeploy pods back, patched in place. (Interviewer noted this is odd given they used custom Packer AMIs — replace-the-node is more standard.)

**✅ Correct answer:**
With **custom Packer AMIs the standard is immutable replacement, not in-place patching**:
1. **Bake a new AMI** (Packer) with the latest OS/security patches + kubelet.
2. Update the node group **launch template** to the new AMI.
3. **Rolling replace**: new nodes join → **cordon + drain** old nodes (respecting PDBs, DaemonSets ignored) → terminate old nodes. Pods reschedule onto the patched nodes.
This gives reproducible, drift-free nodes and easy rollback (revert the AMI). In-place `yum update` on live nodes causes config drift and is discouraged. Automate the AMI pipeline + node group update in CI/CD.

```bash
# Packer builds ami-NEW; point the node group at it and roll:
aws eks update-nodegroup-version --cluster-name prod --nodegroup-name ng-1 \
  --launch-template id=lt-0abc,version='$Latest'
kubectl get nodes -L node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
```

---

## Q43. How do you do risk assessment before an EKS upgrade (which can't be rolled back)?
**Asked in:** Trianz-K8s  |  **My performance:** Partial / Didn't-know

**My answer (from transcript):**
Better to check before upgrading — analyze/document policies and structure first. (Interviewer led heavily; candidate didn't drive it, and later admitted no hands-on upgrade experience.)

**✅ Correct answer:**
Because an **EKS control-plane version can't be downgraded**, all risk work is **pre-upgrade**:
1. **API deprecation scan** — check the target version's removed/deprecated APIs against your manifests (`kubectl-convert`, Pluto, `apiserver_requested_deprecated_apis` metric, **EKS upgrade insights**).
2. **Compatibility matrix** — validate add-ons (VPC CNI, CoreDNS, kube-proxy), CSI/ingress controllers, Karpenter, ArgoCD, service mesh against the new version.
3. **Skew rules** — nodes must be within the supported minor-version skew of the control plane.
4. **Rehearse** — upgrade a **non-prod / ephemeral clone** first; run smoke/integration tests.
5. **Safeguards** — Velero backup, PDBs, ≥2 replicas, and a **fallback plan** (blue-green: stand up a new cluster at the target version and shift traffic, rather than trying to roll back).

```bash
# detect deprecated API usage that will break after the upgrade
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
# or: pluto detect-all-in-cluster --target-versions k8s=v1.31
aws eks list-insights --cluster-name prod   # EKS upgrade insights
```

---

## Q44. How do you manage disaster recovery for an EKS cluster?
**Asked in:** GlobalLogic  |  **My performance:** Partial

**My answer (from transcript):**
Multi-AZ node groups; back up etcd, EBS volumes, and critical components with Velero; multi-region for bigger separation; restoration tested with Velero. (Interviewer pushed that multi-AZ node groups add cost.)

**✅ Correct answer:**
Separate **HA** (survive an AZ) from **DR** (survive a region/cluster loss):
- **HA** — multi-AZ node groups + topology spread + PDBs; the EKS control plane is already multi-AZ and AWS-managed (you don't back up its etcd).
- **DR** — **Velero** backs up namespaced objects **and** PV data (via CSI snapshots), stored in **S3 (cross-region replicated)**; restore into a **standby cluster in another region**. Define **RTO/RPO** and schedule backups accordingly.
- **Data tier** — rely on the datastore's own replication (RDS/Aurora cross-region, DynamoDB Global Tables, EBS snapshot copy) rather than Velero alone for hot data.
- **IaC** — the cluster itself is reproducible from **Terraform + GitOps (ArgoCD)**, so you rebuild + Velero-restore state. **Regularly test restores** — an untested backup is not a backup.

```bash
velero schedule create daily --schedule="0 2 * * *" \
  --include-namespaces '*' --snapshot-volumes --ttl 720h
velero backup-location create dr --provider aws \
  --bucket eks-dr-backups --config region=us-west-2   # cross-region target
# DR drill: restore into the standby cluster
velero restore create --from-backup daily-20260717
```

---

# 9. Security, identity & RBAC

## Q45. Independent of CI/CD, once a Pod is created it must still pull the image — how does Kubernetes authenticate to the registry (ECR)?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
First repeated the ArgoCD/Azure identity → AWS IAM story (missed the point). After redirect: service accounts with IRSA and cluster role bindings with ECR policies let clusters pull from ECR — hedged with "I think that was their approach."

**✅ Correct answer:**
Image pull auth is done by the **kubelet on the node**, two common patterns:
- **EKS + ECR (the clean way)** — the **node's IAM role (or Pod Identity/IRSA)** carries ECR read permissions (`ecr:GetAuthorizationToken`, `BatchGetImage`, `GetDownloadUrlForLayer`). The kubelet's ECR credential provider fetches a token automatically — **no Kubernetes Secret needed**. This is the standard EKS approach.
- **Private/third-party registries** — create a **`docker-registry` Secret** and reference it via **`imagePullSecrets`** on the Pod/ServiceAccount.
Note: **IRSA/Pod Identity give the *application* AWS permissions**; ECR *pull* is primarily the **node role / kubelet credential provider**. Mixing these up was the gap.

```bash
# private registry: create pull secret and attach to the default SA
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com --docker-username=u --docker-password=p
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```
```yaml
# ECR on EKS: node role policy is enough; app identity uses IRSA/Pod Identity
spec:
  serviceAccountName: app-sa   # annotated with eks.amazonaws.com/role-arn for app AWS access
  containers: [{ name: app, image: 1234.dkr.ecr.us-east-1.amazonaws.com/app:1.0 }]
```

---

## Q46. Explain how Pod Identity / IRSA works for securely fetching secrets.
**Asked in:** HDFC (DB integration follow-ups)  |  **My performance:** Partial

**My answer (from transcript):**
DB is read+write, hence extra security. Pod Identity agent runs as a DaemonSet; pod identity is config in the deployment; on each request it fetches credentials and connects. Used an "ingress=Pod Identity, controller=agent" analogy; some confusion about the "forgets the secret" behavior.

**✅ Correct answer:**
Both give **AWS IAM permissions to a Pod without static keys**, mapping a **Kubernetes ServiceAccount → an IAM role**, so the app gets **short-lived, auto-rotated STS credentials**:
- **IRSA** — the cluster has an **OIDC provider**; the SA is annotated with a role ARN; the pod receives a **projected web-identity token**, which the AWS SDK exchanges via `sts:AssumeRoleWithWebIdentity`.
- **EKS Pod Identity** (newer) — an **agent runs as a DaemonSet** on each node; you create a **PodIdentityAssociation** (SA ↔ role) via the EKS API — no per-cluster OIDC/annotation wiring, easier at scale.
The app then calls **Secrets Manager** for the DB creds using these temporary credentials (or mounts them via the **Secrets Store CSI driver**). Nothing is a long-lived secret on disk; tokens expire and rotate. The correct framing: **SA→IAM role→temporary STS creds**, not a persistent fetched secret.

```bash
# IRSA
eksctl create iamserviceaccount --cluster prod --namespace app --name app-sa \
  --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite --approve
# Pod Identity (newer, no OIDC annotation needed)
aws eks create-pod-identity-association --cluster-name prod \
  --namespace app --service-account app-sa \
  --role-arn arn:aws:iam::1234:role/app-secrets-role
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## Q47. Explain the full etcd Raft consistency model — why must you run an odd number of etcd members, and what happens on quorum loss?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
etcd uses the **Raft** consensus algorithm: one **leader** replicates a log to **followers**; a write is committed only when a **majority (quorum = ⌊n/2⌋+1)** acknowledges it. You run an **odd number** (3 or 5) because it maximizes fault tolerance per node: 3 members tolerate **1** failure, 5 tolerate **2**; a 4th member adds cost but not more tolerance and worsens the split-vote surface. On **quorum loss** the cluster becomes **read-only/unavailable for writes** — the apiserver can't persist changes, so no scheduling or reconciliation. Recovery is restoring from a **snapshot** and bootstrapping a new cluster (`--force-new-cluster`). Keep etcd on low-latency disks; it's latency-sensitive.

```bash
ETCDCTL_API=3 etcdctl endpoint status --cluster -w table   # who's leader, DB size
ETCDCTL_API=3 etcdctl endpoint health --cluster            # quorum health
```

---

## Q48. How does the scheduler framework's extension points (QueueSort, Filter, Score, Reserve, Permit, Bind) let you customize scheduling?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
The **Scheduler Framework** exposes plugin **extension points** across the scheduling cycle: **QueueSort** (order the pending queue), **PreFilter/Filter** (feasibility — node fit, taints, affinity), **PreScore/Score/NormalizeScore** (rank feasible nodes), **Reserve** (tentatively hold resources), **Permit** (delay/approve binding — e.g., **gang scheduling**), and **Bind/PostBind**. You customize by writing plugins compiled into a scheduler and selecting them via a **KubeSchedulerConfiguration profile**, or by running a **second scheduler** and setting `schedulerName` on Pods. This powers things like batch/gang scheduling (Volcano, Coscheduling) and topology-aware placement without forking core.

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: gang-scheduler
  plugins:
    permit: { enabled: [{ name: Coscheduling }] }
    score:  { enabled: [{ name: NodeResourcesFit }] }
```

---

## Q49. What is a CNI, and how do overlay (VXLAN) vs native-routing dataplanes differ (Calico vs Cilium vs AWS VPC CNI)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**CNI** is the plugin interface the kubelet calls to give each Pod a network interface + IP and program routes. Approaches:
- **Overlay (VXLAN/Geneve/IPIP)** — encapsulate pod traffic in node-to-node tunnels; works on any underlay but adds MTU/encap overhead (Calico VXLAN, Flannel).
- **Native/BGP routing** — advertise pod CIDRs as real routes, no encap, lower latency (Calico BGP).
- **AWS VPC CNI** — assigns **real VPC IPs** to Pods from ENIs — no overlay, native SG support, but consumes VPC IP space (mitigated by prefix delegation).
- **Cilium** — **eBPF** dataplane; can replace kube-proxy, do L3–L7 policy, transparent encryption, and better performance/observability (Hubble).
Choose per need: VPC CNI for AWS-native integration, Cilium for eBPF policy/observability, Calico for portable policy/BGP.

```bash
kubectl -n kube-system get ds aws-node        # AWS VPC CNI daemonset
cilium status && cilium connectivity test      # if running Cilium
```

---

## Q50. How does the Operator pattern work, and how would you build a controller with a CRD?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
An **Operator** encodes human operational knowledge as software: a **Custom Resource Definition (CRD)** extends the API with a new object (e.g., `PostgresCluster`), and a **controller** runs a **reconcile loop** — watch the CR, diff **desired vs actual**, and drive changes (create StatefulSets, run backups, handle failover) idempotently. Built with **controller-runtime/Kubebuilder** or **Operator SDK**. Core principles: **level-triggered** (converge to desired state, don't react to one-off events), **idempotent** reconciles, **status subresource** to report state, and **owner references** for garbage collection.

```go
func (r *DBReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var db v1.PostgresCluster
    if err := r.Get(ctx, req.NamespacedName, &db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }
    // ensure the StatefulSet matches db.Spec (create/update, idempotent)
    if err := r.ensureStatefulSet(ctx, &db); err != nil {
        return ctrl.Result{RequeueAfter: 30 * time.Second}, err
    }
    return ctrl.Result{}, nil   // level-triggered: reconcile until converged
}
```

---

## Q51. Explain admission control — the difference between validating and mutating webhooks, and how Kyverno/OPA Gatekeeper use them.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
After authn/authz, every write passes through **admission controllers**. Two dynamic kinds:
- **Mutating admission webhooks** run first and can **modify** the object (inject sidecars, add labels/defaults, set securityContext).
- **Validating admission webhooks** run after and can only **accept/reject** (enforce policy — no `:latest`, must have limits, no privileged).
**OPA Gatekeeper** (Rego) and **Kyverno** (YAML policies) are validating/mutating webhook engines used for **policy-as-code** and governance/compliance. K8s also ships built-in **Pod Security Admission** (baseline/restricted). Webhooks must be fast and fail-safe (`failurePolicy`) or they can block the whole cluster.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: require-limits }
spec:
  validationFailureAction: Enforce
  rules:
  - name: require-resource-limits
    match: { any: [{ resources: { kinds: [Pod] } }] }
    validate:
      message: "CPU and memory limits are required"
      pattern:
        spec:
          containers:
          - resources: { limits: { memory: "?*", cpu: "?*" } }
```

---

## Q52. How does HPA scale on custom/external metrics (e.g., queue depth) via KEDA, and how does that differ from CPU-based HPA?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Native HPA on CPU/memory reacts to *symptoms*, not the actual workload driver. **KEDA (Kubernetes Event-Driven Autoscaling)** lets you scale on **event sources** — SQS/Kafka lag, Prometheus queries, cron, etc. — via **scalers**, and uniquely supports **scale-to-zero**. Under the hood KEDA creates a managed **HPA** using the **external metrics API**, so you scale on "messages in queue" rather than CPU. This is the right tool for bursty/async workloads where CPU lags the real demand signal.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: worker }
spec:
  scaleTargetRef: { name: worker }
  minReplicaCount: 0            # scale to zero when idle
  maxReplicaCount: 50
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/1234/jobs
      queueLength: "5"          # target ~5 messages per replica
      awsRegion: us-east-1
```

---

## Q53. Describe a zero-downtime graceful shutdown: preStop hooks, SIGTERM, terminationGracePeriod, and endpoint deregistration ordering.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
On Pod deletion two things happen **concurrently**: the Pod is removed from **Service endpoints**, and the kubelet sends **SIGTERM** then waits `terminationGracePeriodSeconds` before **SIGKILL**. The race is that in-flight requests may still arrive after SIGTERM but before endpoint removal propagates (kube-proxy/ingress lag). The fix: a **`preStop` sleep** so the container keeps serving briefly while it's being deregistered, then the app handles SIGTERM by **draining connections** and exiting. Also set the grace period longer than the longest request. This gives true zero-downtime rollouts.

```yaml
spec:
  terminationGracePeriodSeconds: 60
  containers:
  - name: app
    image: app:1.0
    lifecycle:
      preStop:
        exec: { command: ["sh","-c","sleep 10"] }   # keep serving while endpoints drain
    # app must trap SIGTERM and drain in-flight requests before exiting
```

---

## Q54. Compare Cluster Autoscaler vs Karpenter internals — how each decides to add/remove nodes and consolidates.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
- **Cluster Autoscaler (CA)** — bound to **fixed ASGs/node groups**. It scales a group up when Pods are Pending and the group's template would fit them; scales down when a node is under-utilized and its Pods can move elsewhere. You must pre-define instance types per group, so bin-packing is coarse.
- **Karpenter** — **groupless**; it reads Pending Pods' requirements and **provisions the optimal instance directly** (any type/AZ/spot from a `NodePool`), booting nodes in seconds. It continuously **consolidates** — removing empty nodes and **replacing** under-utilized nodes with cheaper/smaller ones — and handles spot interruption. Result: better bin-packing and cost, less config. Trade-off: Karpenter is AWS/Azure-centric; CA is portable across clouds.

```yaml
# Karpenter drift + consolidation lets it replace nodes when a better fit exists
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    budgets: [{ nodes: "10%" }]   # cap how many nodes churn at once
```

---

## Q55. How does a service mesh implement mTLS, traffic splitting, and retries without changing application code?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A mesh has a **data plane** (per-pod **Envoy sidecars**, or ambient/eBPF) and a **control plane** (istiod). The sidecar transparently intercepts all pod traffic (via iptables/eBPF redirection), so it can add **mTLS** (the control plane issues/rotates SPIFFE identities and certs), **traffic management** (weighted routing for canary, header/subset routing), **resilience** (timeouts, retries, circuit breaking, outlier detection), and **telemetry** (uniform metrics/traces) — all **without app changes**. You configure it declaratively with CRDs (`VirtualService`, `DestinationRule`, `PeerAuthentication`).

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews }
spec:
  hosts: [reviews]
  http:
  - route:
    - { destination: { host: reviews, subset: v1 }, weight: 90 }
    - { destination: { host: reviews, subset: v2 }, weight: 10 }   # 10% canary
    retries: { attempts: 3, perTryTimeout: 2s }
```

---

## Q56. Explain RBAC deeply — Role vs ClusterRole, RoleBinding vs ClusterRoleBinding, and how to grant least-privilege to a CI service account.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
RBAC has 4 objects: **Role** (namespaced permissions), **ClusterRole** (cluster-wide or reusable permission set), **RoleBinding** (grants a Role *or* ClusterRole **within one namespace**), **ClusterRoleBinding** (grants a ClusterRole **cluster-wide**). Rules are **allow-only, additive** (no deny). Subjects: users, groups, **ServiceAccounts**. Least-privilege pattern for CI: a dedicated ServiceAccount + a **Role** limited to the exact verbs/resources in a single namespace, bound with a **RoleBinding** — never `cluster-admin`. Audit with `kubectl auth can-i`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { namespace: ci, name: deployer }
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get","list","update","patch"]     # no delete, no secrets, one namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { namespace: ci, name: ci-deployer }
subjects: [{ kind: ServiceAccount, name: ci-bot, namespace: ci }]
roleRef: { kind: Role, name: deployer, apiGroup: rbac.authorization.k8s.io }
```
```bash
kubectl auth can-i delete secrets --as=system:serviceaccount:ci:ci-bot -n ci   # -> no
```

---

## Q57. What are PodSecurity Standards / securityContext hardening (runAsNonRoot, drop capabilities, seccomp, read-only rootfs)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Pod Security Admission** enforces three built-in levels per namespace via labels — **privileged / baseline / restricted** — replacing the removed PodSecurityPolicy. On top, harden each Pod with **securityContext**: `runAsNonRoot`, a non-zero `runAsUser`, **drop ALL Linux capabilities** (add back only what's needed), `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, and a **seccomp** profile (`RuntimeDefault`). This shrinks the blast radius if a container is compromised. Enforce org-wide with Kyverno/Gatekeeper.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: secure
  labels: { pod-security.kubernetes.io/enforce: restricted }
---
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: app
    image: app:1.0
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
```

---

## Q58. Design multi-tenancy on a shared cluster — namespaces vs virtual clusters vs separate clusters, with hard isolation.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Pick isolation strength by trust level:
- **Soft (trusted teams)** — **namespace-per-tenant** + RBAC + ResourceQuota/LimitRange + NetworkPolicy + PodSecurity. Cheap, but a shared control plane and shared kernel.
- **Medium** — add **dedicated node pools** (taints/affinity), **vClusters** (each tenant gets a virtual API server/control plane on the shared cluster) for API-level isolation without full clusters.
- **Hard (untrusted/regulated)** — **separate clusters** (or separate accounts), optionally **sandboxed runtimes** (gVisor/Kata) for kernel isolation.
Key point: **namespaces are a logical, not a security, boundary** for hostile tenants — kernel and control-plane are shared. Combine quotas + policies + node isolation, and escalate to vCluster/separate clusters as trust drops.

```yaml
# per-tenant guardrails on a shared cluster
apiVersion: v1
kind: LimitRange
metadata: { name: defaults, namespace: tenant-a }
spec:
  limits:
  - type: Container
    default: { cpu: 500m, memory: 512Mi }
    defaultRequest: { cpu: 100m, memory: 128Mi }
    max: { cpu: "2", memory: 2Gi }
```

---

## Q59. How do you debug intermittent DNS resolution failures / latency in a cluster (CoreDNS, ndots, NodeLocal DNSCache)?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Classic causes and fixes:
- **`ndots:5`** in the pod's `/etc/resolv.conf` — external lookups first try all search-domain permutations, multiplying queries and latency. Fix with `dnsConfig` `ndots:2` or use FQDNs (trailing dot).
- **CoreDNS overload / under-replication** — scale CoreDNS, add HPA, check its metrics/logs; tune the `cache` plugin.
- **conntrack race / UDP drops** at scale — deploy **NodeLocal DNSCache** (a per-node DNS cache DaemonSet) to cut cross-node UDP and conntrack pressure, switching upstream to TCP.
- Verify with `dnsutils` pod, `nslookup`, and CoreDNS query logs.

```yaml
# reduce needless search-domain lookups per pod
spec:
  dnsConfig: { options: [{ name: ndots, value: "2" }] }
```
```bash
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl -n kube-system get pods -l k8s-app=node-local-dns   # NodeLocal DNSCache
```

---

## Q60. Explain GitOps with ArgoCD ApplicationSets for multi-cluster/multi-env delivery, and how drift is detected and reconciled.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**GitOps** makes Git the single source of truth; **ArgoCD** continuously compares the **live cluster state** to the **desired state in Git** and reports **Synced/OutOfSync**, auto-healing **drift** (manual `kubectl` changes get reverted). **ApplicationSets** template many `Application`s from a **generator** (list/cluster/git-directory/matrix) so one definition fans out **per environment and per cluster** — ideal for the hub-and-spoke model (one ArgoCD on the hub deploying to many spokes). Combine with per-env Helm `values.yaml` or Kustomize overlays. Benefits: auditability, easy rollback (git revert), and declarative multi-cluster fleet management.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: web, namespace: argocd }
spec:
  generators:
  - clusters: {}                     # one App per registered spoke cluster
  template:
    metadata: { name: 'web-{{name}}' }
    spec:
      project: default
      source:
        repoURL: https://git/org/web
        path: 'envs/{{metadata.labels.env}}'   # per-env overlay
        targetRevision: main
      destination: { server: '{{server}}', namespace: web }
      syncPolicy: { automated: { prune: true, selfHeal: true } }   # auto-revert drift
```

---

## Q61. When authenticating a Python script to multiple clusters, how does kubeconfig context switching and the EKS auth flow (aws-auth / access entries) actually work?
**Asked in:** Accion-2 (weakly)  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(In interview:) "Log into a cluster and run the script; credentials are part of CI so kubectl runs on that cluster." — vague on the multi-cluster auth mechanism.*

**✅ Correct answer:**
Each cluster is a **context** in kubeconfig (cluster endpoint + user + namespace). To act on many clusters, either **switch contexts** (`use-context`) in a loop or point the client library at each context explicitly. For EKS, the "user" runs **`aws eks get-token`** (an exec credential plugin) which returns a **short-lived STS token**; the cluster then maps that IAM identity to Kubernetes RBAC via the **`aws-auth` ConfigMap** (legacy) or **EKS Access Entries** (newer). So the real auth chain is **IAM identity → STS token → EKS access entry/aws-auth → RBAC**. A clean script iterates registered contexts and loads each per call rather than relying on one ambient context.

```python
from kubernetes import client, config
for ctx in ["dev-eks", "uat-eks", "prod-eks"]:      # each is a kubeconfig context
    config.load_kube_config(context=ctx)            # re-auths via aws eks get-token
    v1 = client.CoreV1Api()
    for ns in v1.list_namespace().items:
        print(ctx, ns.metadata.name)
```
```bash
kubectl config get-contexts
aws eks update-kubeconfig --name prod --alias prod-eks   # writes the exec-based context
```

---
