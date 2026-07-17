# 🌐 Section 8 — Networking (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 8 transcript. Deep-dive prereqs: [../../Networking/24-kubernetes-pod-networking-cni.md](../../Networking/24-kubernetes-pod-networking-cni.md), [../../Networking/09-dns.md](../../Networking/09-dns.md).

---

## 1. Cluster networking basics (nodes & ports)

### ❓ What
The node-level plumbing Kubernetes assumes: unique hostname/MAC/IP per node, and a set of **ports** that must be open between nodes.

### 🔥 Pain points it solves & why this?
- Components can't find each other if firewalls/SGs block their ports — "cluster won't form" is often just a closed port.
- The port list is exam-memorization gold *and* real-world firewall config.

### ⚙️ How exactly it works

| Component | Port | On |
|---|---|---|
| kube-apiserver | **6443** | control plane |
| kubelet | **10250** | all nodes |
| kube-scheduler | **10259** | control plane |
| kube-controller-manager | **10257** | control plane |
| etcd | **2379** client / **2380** peer | control plane |
| NodePort services | **30000–32767** | all nodes |

### 🧪 Hands-on examples

**Example 1 — Node network recon:**
```bash
kubectl get nodes -o wide          # internal IPs
ip addr show eth0                  # interface, IP, MAC
ip route                           # default gateway
# Verify: you can state each node's IP, MAC, and gateway.
```

**Example 2 — What's listening where:**
```bash
netstat -npl | grep -i scheduler   # 10259
netstat -npl | grep -i etcd        # 2379 + 2380
# Verify: matches the table; 2380 only matters with multiple etcd members.
```

**Example 3 — Find the CNI bridge interface:**
```bash
ip -br link show type bridge       # cni0 / weave / flannel.1 …
ip addr show cni0                  # the node's pod-subnet gateway address
# Verify: the bridge exists once a CNI is installed and pods run.
```

---

## 2. Pod networking & CNI

### ❓ What
The Kubernetes **network model**: every pod gets a unique IP; all pods reach all pods **without NAT**, across nodes. Kubernetes doesn't implement it — a **CNI plugin** (Flannel/Calico/Weave/Cilium) does.

### 🔥 Pain points it solves & why this?
- Cross-node container networking by hand = veths, bridges, and routes on every node, redone per pod — automation or death.
- A standard interface (CNI) lets any vendor implement the model; swap plugins without touching Kubernetes.
- Explains the classic symptom: **node `NotReady` right after install = no CNI deployed.**

### ⚙️ How exactly it works
kubelet → runtime → CNI plugin `ADD` on pod create: create a veth pair, assign an IP (**IPAM**, usually `host-local`), wire routes.

| Vocabulary | Where |
|---|---|
| plugin binaries | `/opt/cni/bin/` |
| active config | `/etc/cni/net.d/*.conflist` (lowest filename wins) |
| pod CIDR | the addon's range (e.g. `10.244.0.0/16`) — must NOT overlap the service CIDR |
| the addon | runs as a **DaemonSet** (one agent per node) |

### 🧪 Hands-on examples

**Example 1 — Identify the CNI setup (exam recon):**
```bash
ls /opt/cni/bin                       # available plugins
ls /etc/cni/net.d                     # the ACTIVE config file
cat /etc/cni/net.d/*.conflist         # plugin type, IPAM, subnet
ps -aux | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*'
# Verify: you can name the CNI, its config, and the runtime socket.
```

**Example 2 — Find the pod CIDR (two ways):**
```bash
kubectl logs -n kube-system -l app=flannel | grep -i ip-alloc     # from the addon
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}{"\n"}'    # per-node slices
grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml
# Verify: pod CIDR (e.g. 10.244.0.0/16) ≠ service CIDR (e.g. 10.96.0.0/12) — no overlap.
```

**Example 3 — The NotReady-without-CNI symptom:**
```bash
kubectl get nodes                          # NotReady on a fresh kubeadm cluster
kubectl describe node controlplane | grep -i networkready   # "cni plugin not initialized"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get nodes                          # Ready
# Verify: the addon's DaemonSet pod per node flips readiness.
```

---

## 3. Service networking — kube-proxy

### ❓ What
A Service is a **virtual IP no process listens on**; **kube-proxy** (a DaemonSet) writes **iptables** (default) or **IPVS** rules that **DNAT** the VIP to a live backend pod IP.

### 🔥 Pain points it solves & why this?
- Pod IPs churn; clients need one stable address with load-balancing.
- Doing it in the kernel (iptables) means no proxy process in the data path per connection.
- Explains why a ClusterIP **doesn't ping** (nothing owns the IP) but its ports work.

### ⚙️ How exactly it works
```
client pod → ClusterIP 10.96.0.50:80
   │ (iptables rule kube-proxy wrote)
   ▼ DNAT → pod 10.244.1.7:80   (routable via the CNI)
```
Service CIDR: apiserver `--service-cluster-ip-range`. Mode: `--proxy-mode=iptables|ipvs` (see its logs).

### 🧪 Hands-on examples

**Example 1 — Confirm kube-proxy's shape and mode:**
```bash
kubectl get pods -n kube-system -o wide | grep kube-proxy    # one per node = DaemonSet
kubectl logs -n kube-system <kube-proxy-pod> | grep -i proxier   # "Using iptables Proxier"
# Verify: DaemonSet + mode from logs — two standard exam questions.
```

**Example 2 — See the actual DNAT rules:**
```bash
kubectl create deployment web --image=nginx && kubectl expose deployment web --port=80
SVC_IP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
iptables -t nat -L KUBE-SERVICES -n | grep $SVC_IP
# Verify: a chain matching the VIP that jumps to a pod-IP DNAT — the Service made real.
```

**Example 3 — VIP doesn't ping, but curl works:**
```bash
kubectl run t --image=busybox -it --rm -- sh -c "ping -c2 $SVC_IP; wget -qO- $SVC_IP | head -1"
# ping: 100% loss.   wget: the nginx page.
# Verify: only the DNAT'd ports exist; ICMP to a VIP goes nowhere.
```

---

## 4. Cluster DNS — CoreDNS

### ❓ What
**CoreDNS** (pods in `kube-system`, fronted by the `kube-dns` Service at ~`10.96.0.10`) maps Service/pod names to IPs; the kubelet points every pod's `/etc/resolv.conf` at it.

### 🔥 Pain points it solves & why this?
- Apps want `mysql`, not `10.96.4.7` — and the VIP itself can change across recreates.
- Namespaced short names (`db-service`) only work in-namespace; DNS search domains implement that scoping.

### ⚙️ How exactly it works

| Name form | Resolves |
|---|---|
| `web-service` | Service in **your own** namespace (via search domains) |
| `web-service.payroll` | Service in the `payroll` namespace |
| `web-service.payroll.svc.cluster.local` | the full FQDN |
| `10-244-1-7.default.pod.cluster.local` | a **pod** (dashed IP; needs full form) |

Config = the **Corefile** (a ConfigMap named `coredns`) with the `kubernetes cluster.local` plugin.

### 🧪 Hands-on examples

**Example 1 — Inspect the DNS plumbing:**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns       # coredns pods
kubectl get svc -n kube-system kube-dns                    # ClusterIP 10.96.0.10
kubectl run t --image=busybox -it --rm -- cat /etc/resolv.conf
# nameserver 10.96.0.10 ; search default.svc.cluster.local svc.cluster.local cluster.local
# Verify: the search list is WHY short names work in-namespace.
```

**Example 2 — Cross-namespace resolution fix (exam classic):**
```bash
kubectl exec web-app -- nslookup mysql              # NXDOMAIN (it lives in payroll)
kubectl exec web-app -- nslookup mysql.payroll      # resolves
kubectl set env deployment/web-app DB_HOST=mysql.payroll
# Verify: app connects; short names never cross namespaces.
```

**Example 3 — Read the Corefile:**
```bash
kubectl get configmap coredns -n kube-system -o yaml | grep -A10 Corefile
# kubernetes cluster.local … ; forward . /etc/resolv.conf (upstream for external names)
# Verify: cluster.local is the cluster zone; everything else forwards upstream.
```

---

## 5. Ingress

### ❓ What
One **L7 (HTTP) entrypoint** routing by host/path to Services, with shared TLS — two halves: an **Ingress Controller** (nginx/Traefik — you must deploy one) and **Ingress resources** (the rules).

### 🔥 Pain points it solves & why this?
- One cloud LoadBalancer per Service = one bill per app and zero URL-based routing.
- TLS termination and path/host routing belong at one edge, not in every app.
- No controller ⇒ Ingress objects do **nothing** — the #1 Ingress surprise.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| Ingress Controller | the proxy pods actually routing (not built-in!) |
| `rules[].host` / `paths[].path` | the match; `pathType: Prefix` usual |
| `rewrite-target: /` | strip the matched path before forwarding (fixes 404s) |
| default backend | where unmatched traffic goes |
| namespace rule | an Ingress can only reference Services in **its own** namespace |

### 🧪 Hands-on examples

**Example 1 — Path-based routing for two apps:**
```bash
kubectl create ingress shop \
  --rule="my-online-store.com/wear*=wear-service:80" \
  --rule="my-online-store.com/watch*=video-service:80" \
  --annotation nginx.ingress.kubernetes.io/rewrite-target=/
kubectl describe ingress shop
# Verify: /wear → wear-service, /watch → video-service, one entrypoint.
```

**Example 2 — The 404 → rewrite-target fix (exam classic):**
```bash
kubectl create ingress ingress-pay -n critical-space --rule="/pay=pay-service:8282"
curl http://<ingress-ip>/pay              # 404
kubectl logs -n critical-space <pay-pod>  # request arrived as /pay — app only serves /
kubectl annotate ingress ingress-pay -n critical-space \
  nginx.ingress.kubernetes.io/rewrite-target=/
curl http://<ingress-ip>/pay              # 200
# Verify: the backend log shows the path problem; the annotation rewrites it away.
```

**Example 3 — Prove the namespace rule:**
```bash
kubectl create ingress cross -n default --rule="/app=svc-in-other-ns:80"
kubectl describe ingress cross            # backend "<error: service not found>"
kubectl create ingress same -n other-ns --rule="/app=svc-in-other-ns:80"   # works
# Verify: Ingress + its Services must share a namespace — put each team's Ingress in their ns.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Gateway API** is the successor to Ingress (Gateways + HTTPRoutes, role-separated) — appearing in newer exams/courses; know it exists.
- **Debug order for "pod can't reach service":** name resolves? (`nslookup`) → endpoints exist? (`describe svc`) → port right? → NetworkPolicy in the way? ([Section 6](06-security.md)).
- Full traces of a packet through CNI→kube-proxy→CoreDNS live in the ladder version and the [Networking guide](../../Networking/25-kubernetes-services-kube-proxy.md).

---

## Related
[01-core-concepts](01-core-concepts.md) (Services) · [06-security](06-security.md) (NetworkPolicies) · [09-design-and-install](09-design-and-install-kubernetes-cluster.md) (CIDR choices) · [13-troubleshooting](13-troubleshooting.md) · Ladder version: [../README/08-networking.md](../README/08-networking.md)
