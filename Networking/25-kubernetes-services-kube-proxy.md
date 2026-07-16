# Kubernetes Services & kube-proxy

*Pods die and their IPs vanish — so how does anything reliably talk to "the backend"? A stable virtual IP, load-balanced by rules kube-proxy writes into the kernel.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Kubernetes **Services** (ClusterIP, NodePort, LoadBalancer, ExternalName, Headless), **Endpoints/EndpointSlices**, and **kube-proxy** — the component that turns a Service's virtual IP into real forwarding to healthy pods.

**Why did it land on my desk?** Pods are cattle: they restart, reschedule, scale, and get new IPs constantly ([24-kubernetes-pod-networking-cni.md](24-kubernetes-pod-networking-cni.md)). Nothing can rely on a pod IP. Yet your frontend must reliably reach "the API." Every `kubectl expose`, every `type: LoadBalancer`, every "why can't my pod reach this Service" ticket lives here.

**What do I already know?** You know load balancing ([18-load-balancing.md](18-load-balancing.md)), DNAT ([14-nat-and-pat.md](14-nat-and-pat.md)), iptables ([../Linux/12-iptables-netfilter.md](../Linux/12-iptables-netfilter.md)), and the SDN control/data-plane split ([22-sdn-software-defined-networking.md](22-sdn-software-defined-networking.md)). A Service is those ideas fused into one abstraction.

---

## 🔥 Rung 1 — The Pain

Pod IPs are **ephemeral**. Scale a Deployment and new pods get new IPs; roll it and every IP changes; a crash reschedules a pod onto another node with a different address. If your frontend hardcoded `10.244.1.7`, it breaks the instant that pod is replaced.

Before Services you'd need to:

- **Track every backend IP** and update all callers whenever a pod changed — a coordination nightmare at pod-churn speed.
- **Build your own load balancer** in front of the backends and keep its member list in sync with reality.
- **Health-check yourself** so you never send traffic to a pod that's starting up or dying.

You need a **stable name/IP that never changes**, automatically load-balances across the *current* healthy pods, and updates itself as pods come and go. That's a Service.

**Who feels it most?** Every developer wiring service-to-service calls, and the platform team owning "why is traffic hitting a dead pod?"

> **✅ Check yourself before Rung 2:** If a Deployment's pods get brand-new IPs every rollout, why is hardcoding a pod IP guaranteed to break — and what property must the replacement have?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **A Service is a stable virtual IP (and DNS name) that kube-proxy transparently load-balances to the current set of healthy pods behind it — so callers use one unchanging address while the actual pods churn freely underneath.**

Everything derives from "stable VIP → current healthy pods":

- *Stable VIP* → callers never change, even as pods do.
- *Current healthy pods* → the **Endpoints/EndpointSlice** controller keeps the member list in sync with readiness.
- *Load-balanced transparently* → **kube-proxy** programs kernel rules that DNAT the VIP to a chosen pod IP; no app change, no client-side logic.

Think of it as the **permanent company hotline**: the number never changes, but whichever employee (pod) is available answers.

> **✅ Check yourself before Rung 3:** A Service's ClusterIP stays fixed forever, yet the pods behind it are replaced constantly. What keeps the *list of pods* the VIP forwards to correct?

---

## ⚙️ Rung 3 — The Machinery

### The three collaborating pieces

1. **The Service object** — declares a stable **ClusterIP** (from the *service CIDR*, e.g. `10.96.0.0/12`), a port, and a **selector** (`app: web`).
2. **Endpoints / EndpointSlices** — a controller watches which pods match the selector *and are Ready*, and maintains the list of their `podIP:targetPort`. Fail a readiness probe → you're removed from the list → you stop getting traffic.
3. **kube-proxy** — runs on every node, watches Services and EndpointSlices, and writes **data-plane rules** (iptables or IPVS) that DNAT the ClusterIP to one of the current backend pod IPs. kube-proxy is the **control plane**; the kernel is the **data plane** ([22](22-sdn-software-defined-networking.md)) — kube-proxy is *never* in the packet path.

```
   Service (ClusterIP 10.96.0.50:80, selector app=web)
        │ controller watches ready pods
        ▼
   EndpointSlice: [10.244.1.7:8080, 10.244.2.9:8080]   (only READY pods)
        │ kube-proxy on every node watches this
        ▼
   kube-proxy WRITES iptables (or IPVS) rules on each node:

   client pod → 10.96.0.50:80
        │
        ▼  (kernel, iptables nat table)
   KUBE-SERVICES ─▶ KUBE-SVC-XXXX ─┬─ 50% ─▶ KUBE-SEP-A ─▶ DNAT to 10.244.1.7:8080
                                    └─ 50% ─▶ KUBE-SEP-B ─▶ DNAT to 10.244.2.9:8080
```

A connection to the ClusterIP is **DNATed** in the kernel to one backend pod, chosen probabilistically (iptables `statistic` module) or by IPVS's scheduler. There's no server actually *listening* on the ClusterIP — it's a virtual address that only exists as forwarding rules.

### iptables mode vs IPVS mode

- **iptables mode (default):** kube-proxy writes a chain per Service that random-selects a backend. Simple and ubiquitous, but rule-matching is O(n) and can slow down with tens of thousands of Services.
- **IPVS mode:** uses the kernel's in-built L4 load balancer (hash tables, O(1) lookup) and real scheduling algorithms (round-robin, least-conn). Better at large scale.

### Service types (all built on the ClusterIP idea)

| Type | What it adds | Reachable from |
|---|---|---|
| **ClusterIP** (default) | A stable in-cluster VIP | Inside the cluster only |
| **NodePort** | Opens the same port (**30000–32767**) on *every node* | Outside, via `nodeIP:nodePort` |
| **LoadBalancer** | Asks the cloud for an external LB → NodePort → pods | The internet (cloud LB) |
| **ExternalName** | Just a DNS CNAME to an external host | Redirects by name, no proxying |
| **Headless** (`clusterIP: None`) | *No* VIP; DNS returns pod IPs directly | Clients that want per-pod addressing (StatefulSets) |

**externalTrafficPolicy** (`Cluster` vs `Local`) controls whether a NodePort/LoadBalancer preserves the client source IP (`Local`, no extra hop) or spreads to all pods (`Cluster`, may SNAT). **sessionAffinity: ClientIP** pins a client to one backend.

> **✅ Check yourself before Rung 4:** No process listens on a ClusterIP, yet connecting to it reaches a pod. What actually makes that connection land on a real pod, and where does that logic live?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Service** | A stable VIP + selector for a set of pods | The abstraction |
| **ClusterIP** | The virtual IP (from the service CIDR) | The stable address |
| **Selector** | Labels that pick the backend pods | How members are chosen |
| **Endpoints / EndpointSlice** | The live list of ready `podIP:port` | The current membership |
| **kube-proxy** | Control-plane agent writing forwarding rules | Programs the data plane |
| **iptables / IPVS mode** | Two kernel data-plane implementations | Where DNAT happens |
| **KUBE-SVC / KUBE-SEP chains** | The generated iptables chains | The actual DNAT rules |
| **NodePort (30000–32767)** | A port opened on every node | External reach without a cloud LB |
| **Headless Service** | No VIP; DNS returns pod IPs | Per-pod addressing |
| **externalTrafficPolicy** | Preserve client IP or spread evenly | Ingress path behavior |

**Same-kind-of-thing groupings:** *ClusterIP, NodePort, LoadBalancer* are one thing layered — LoadBalancer builds on NodePort builds on ClusterIP. *Endpoints and EndpointSlices* are "the member list" (Slices are the scalable successor). *iptables mode and IPVS mode* are two data planes for the same job.

---

## 🔬 Rung 5 — The Trace

**A frontend pod calls `http://web:80`; `web` is a ClusterIP Service (`10.96.0.50`) with two ready pods.**

```
[frontend pod]
  │ 1. DNS: "web" → 10.96.0.50 (CoreDNS resolves the Service) ── 26
  │ 2. connect to 10.96.0.50:80
  ▼
[node kernel: iptables nat] ── kube-proxy wrote these rules
  │ 3. PREROUTING/OUTPUT → KUBE-SERVICES
  │ 4. match ClusterIP 10.96.0.50:80 → KUBE-SVC-WEB
  │ 5. KUBE-SVC-WEB random-picks a backend chain → KUBE-SEP-B
  │ 6. KUBE-SEP-B: DNAT dst 10.96.0.50 → 10.244.2.9:8080
  │    (conntrack remembers this so replies un-DNAT correctly)
  ▼
[CNI routes the packet to pod 10.244.2.9 on its node] ── 24
  ▼
[web pod :8080] handles the request; reply is un-DNATed back to the ClusterIP
  ▼
[frontend pod] gets the response — it only ever "saw" 10.96.0.50
```

The frontend never knew which pod answered, never saw a pod IP, and needs no update when pods change. kube-proxy (control plane) wrote steps 3–6 once; the kernel (data plane) runs them per connection.

> **✅ Check yourself before Rung 6:** At step 6 the destination is rewritten from the ClusterIP to a pod IP. What is that rewrite called, and what remembers it so the reply comes back correctly?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: talk to pods directly (raw pod IPs) or roll your own service discovery + LB.**

| Task | Raw pod IPs / DIY | Kubernetes Service |
|---|---|---|
| Stable target as pods churn | ❌ IPs change | ✅ fixed ClusterIP/name |
| Load-balance across replicas | Build it yourself | ✅ kube-proxy (free) |
| Skip dying/starting pods | Health-check yourself | ✅ readiness-gated endpoints |
| External exposure | Manual | NodePort/LoadBalancer |
| Per-pod addressing (databases) | Manual | Headless Service |

**Service (kube-proxy L4) vs Ingress (L7):** a Service load-balances at L4 (IP:port) and can't route by HTTP path/host; an **Ingress** ([27](27-kubernetes-ingress-gateway-api.md)) adds L7 routing *on top of* Services. They're complementary, not competing.

**When would I NOT use a ClusterIP Service?** For a StatefulSet where each pod is distinct (a database with per-replica identity), you want a **Headless** Service so clients address individual pods, not a load-balanced VIP.

**One-sentence why-this-over-that:** *Use a Service for a stable, load-balanced entrypoint to a pool of interchangeable pods; use Headless when clients need to reach specific pods directly.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: the ClusterIP is stable while pods churn

> **Prediction:** "If I create a Service, then delete and recreate its pods, the Service's ClusterIP stays the same while the Endpoint pod IPs change, BECAUSE the VIP is fixed and only the backing member list is updated."

```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80 --target-port=80
kubectl get svc web -o jsonpath='ClusterIP={.spec.clusterIP}{"\n"}'
# ClusterIP=10.96.0.50           <- note it

kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{.items[*].endpoints[*].addresses[0]}{"\n"}'
# 10.244.1.7 10.244.2.9          <- current pod IPs

kubectl rollout restart deployment web ; kubectl rollout status deployment web
kubectl get svc web -o jsonpath='ClusterIP={.spec.clusterIP}{"\n"}'
# ClusterIP=10.96.0.50           <- UNCHANGED
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{.items[*].endpoints[*].addresses[0]}{"\n"}'
# 10.244.1.11 10.244.2.14        <- NEW pod IPs, auto-updated
```

**Verify:** ClusterIP is identical before/after; endpoint IPs changed. The stable-VIP-over-churning-pods promise, demonstrated.

### Example 2 — Edge/failure case: an unready pod is removed from endpoints

> **Prediction:** "If a pod fails its readiness probe, it disappears from the Service's endpoints and stops receiving traffic, BECAUSE endpoints only include Ready pods — even though the pod is still Running."

```bash
# A Deployment whose readiness probe we can break:
kubectl create deployment flaky --image=nginx --replicas=2
kubectl patch deployment flaky --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/readinessProbe","value":{"httpGet":{"path":"/nope","port":80},"periodSeconds":2}}]'
kubectl expose deployment flaky --port=80
sleep 10
kubectl get pods -l app=flaky            # Running but READY 0/1
# flaky-xxx  0/1  Running
kubectl get endpointslices -l kubernetes.io/service-name=flaky -o yaml | grep -A2 conditions
#   conditions:
#     ready: false          <- excluded from load-balancing targets
```

**Verify:** pods are `Running` but `0/1` ready, and endpoints show `ready: false`, so kube-proxy won't DNAT to them. This is why readiness probes are the load balancer's on/off switch. (`kubectl delete deploy flaky svc/flaky` to clean up.)

### Example 3 — Kubernetes-flavored: read the DNAT rules kube-proxy wrote

> **Prediction:** "If I inspect the iptables nat table on a node, I'll find a KUBE-SVC chain for my Service that DNATs to my pod IPs, BECAUSE kube-proxy programmed the kernel to implement the virtual IP."

```bash
SVCIP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
# On a node (or a privileged debug pod), find the Service's chain:
sudo iptables -t nat -L KUBE-SERVICES -n | grep "$SVCIP"
# KUBE-SVC-ABC123 tcp -- 0.0.0.0/0  10.96.0.50  /* default/web */ tcp dpt:80

sudo iptables -t nat -L KUBE-SVC-ABC123 -n
# KUBE-SEP-AAA  statistic mode random probability 0.50000000000
# KUBE-SEP-BBB  (the remainder)
sudo iptables -t nat -L KUBE-SEP-AAA -n | grep DNAT
# DNAT tcp -- to:10.244.1.7:8080         <- the actual pod IP
```

**Verify:** the KUBE-SVC chain splits by probability into KUBE-SEP chains that DNAT to real pod IPs. You are looking directly at how a ClusterIP becomes a pod connection — pure kernel rules, no listening process. (In IPVS mode, use `sudo ipvsadm -Ln` instead.)

---

## 🏔 Capstone — Compress It

**One sentence:** A Kubernetes Service is a stable virtual IP that kube-proxy programs the kernel (via iptables or IPVS) to DNAT-load-balance onto the current set of readiness-passing pods, so callers use one unchanging address while the pods behind it churn freely.

**Explain it to a beginner in 3 sentences:**
1. Pods come and go with ever-changing IPs, so you can't point anything at a pod directly.
2. A Service gives you one permanent virtual IP (and DNS name) that automatically spreads traffic across whichever pods are currently healthy.
3. It works because kube-proxy on every node watches the pod list and writes kernel forwarding rules that rewrite the Service IP into a real pod IP — no server actually listens on the Service address, it's all forwarding rules.

**Sub-parts mapped to the one idea (stable VIP → current healthy pods):**
```
ClusterIP           → the stable virtual IP
Selector            → picks candidate pods
EndpointSlice       → the live READY-only member list
kube-proxy          → control plane: writes the rules
iptables / IPVS     → data plane: DNATs VIP → pod
NodePort/LoadBalancer → external reach (30000–32767 / cloud LB)
Headless            → skip the VIP, expose pod IPs
```

**Which rung to revisit hands-on:** Rung 7 Example 3 — tracing KUBE-SERVICES → KUBE-SVC → KUBE-SEP → DNAT makes the "virtual IP is just rules" idea click permanently.

---

## Related concepts

- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — the pod IPs a Service load-balances across.
- [Kubernetes DNS & Service Discovery](26-kubernetes-dns-service-discovery.md) — how a Service *name* becomes its ClusterIP.
- [NAT & PAT](14-nat-and-pat.md) — the DNAT that turns a ClusterIP into a pod IP.
- [iptables & netfilter](../Linux/12-iptables-netfilter.md) — the KUBE-* chains kube-proxy writes.
- [Load Balancing](18-load-balancing.md) — kube-proxy as an L4 load balancer; L4 vs L7.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — L7 routing layered on top of Services.
