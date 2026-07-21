# Kubernetes DNS & Service Discovery

*How `curl http://payments` just works across a cluster of churning pods — and why one line in `/etc/resolv.conf` sometimes makes it slow.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** In-cluster service discovery via **CoreDNS**: the FQDN scheme (`<service>.<namespace>.svc.cluster.local`), the pod `/etc/resolv.conf` (`search` domains + `ndots:5`), record types for normal vs Headless Services, and the classic DNS-latency gotcha.

**Why did it land on my desk?** Services give you a stable *IP* ([25-kubernetes-services-kube-proxy.md](25-kubernetes-services-kube-proxy.md)), but nobody wants to hardcode `10.96.0.50`. Developers write `http://payments` and expect it to resolve. When cross-namespace calls fail, when DNS is mysteriously slow, or when CoreDNS falls over and "everything" breaks — you're in this chapter.

**What do I already know?** You understand DNS resolution and record types generally ([09-dns.md](09-dns.md)), and how Services expose a ClusterIP ([25](25-kubernetes-services-kube-proxy.md)). Cluster DNS is ordinary DNS, scoped to the cluster and served by a pod.

---

## 🔥 Rung 1 — The Pain

A Service's ClusterIP is stable, but it's still an **IP** — assigned when the Service is created, different in every cluster/namespace, and meaningless to a human. Hardcoding it means:

- **No portability:** the same manifest gets a different ClusterIP in staging vs prod.
- **Tight coupling:** create the backing Service *before* anything that references it, and never let its IP change assumptions leak.
- **No human-friendly wiring:** "connect to the payments service" should be spelled `payments`, not `10.96.0.50`.

You want the same thing the whole internet solved with DNS ([09](09-dns.md)): **refer to services by name, resolve to the current address automatically.** Inside a cluster, that name→ClusterIP resolver is CoreDNS.

**Who feels it most?** Developers wiring microservices, and the platform team when CoreDNS hiccups and *every* service-to-service call starts failing at once.

> **✅ Check yourself before Rung 2:** A Service's ClusterIP is already stable — so why is resolving it by *name* still worth a whole DNS system inside the cluster?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **CoreDNS is a DNS server running as pods inside the cluster that turns Service (and pod) names into their ClusterIPs, so workloads discover each other by predictable names like `payments.prod.svc.cluster.local` no matter how the underlying IPs change.**

Everything derives from "a cluster-internal DNS that knows every Service":

- *DNS server in the cluster* → reachable at a well-known ClusterIP (commonly `10.96.0.10`), injected into every pod's `resolv.conf`.
- *Knows every Service* → each Service automatically gets an **A/AAAA record** at a deterministic name.
- *Predictable naming* → `<service>.<namespace>.svc.cluster.local`, with `search` domains letting you use short names within a namespace.

> **✅ Check yourself before Rung 3:** If a pod resolves `payments` and gets a ClusterIP back, what made that name exist as a DNS record in the first place?

---

## ⚙️ Rung 3 — The Machinery

### The naming scheme

Every Service gets a fully-qualified name:

```
<service>.<namespace>.svc.cluster.local
   │           │        │      │
   │           │        │      └─ the cluster's DNS zone
   │           │        └──────── "svc" = it's a Service
   │           └───────────────── the namespace it lives in
   └───────────────────────────── the Service name
```

So `payments` in namespace `prod` is `payments.prod.svc.cluster.local`, resolving to that Service's ClusterIP. Pods can also get DNS names (`<ip-dashed>.<ns>.pod.cluster.local`), and Headless Services expose per-pod records (below).

### The pod resolver: resolv.conf + search + ndots

When a pod starts, the kubelet writes its `/etc/resolv.conf`:

```text
nameserver 10.96.0.10                                    # the CoreDNS Service ClusterIP
search prod.svc.cluster.local svc.cluster.local cluster.local   # search domains
options ndots:5
```

- **nameserver** points at the CoreDNS Service (itself a ClusterIP, DNATed by kube-proxy to a CoreDNS pod).
- **search** lets you use short names: querying `payments` from a pod in `prod` auto-tries `payments.prod.svc.cluster.local` first. That's why `curl http://payments` works within a namespace, and cross-namespace you need `payments.prod`.
- **ndots:5** is the famous gotcha: any name with **fewer than 5 dots** is treated as *unqualified* and tried against **each search domain first** before being tried as-is. So `api.github.com` (2 dots) generates several failed cluster lookups (`api.github.com.prod.svc.cluster.local`, …) before the real one. Multiply by every external call and DNS becomes a latency source.

```
     pod queries "payments"  (0 dots < ndots:5 → treat as unqualified)
        │
        ├─ try payments.prod.svc.cluster.local  → HIT (ClusterIP) ✔ stop
        │
     pod queries "api.github.com" (2 dots < 5 → unqualified too!)
        ├─ try api.github.com.prod.svc.cluster.local → NXDOMAIN
        ├─ try api.github.com.svc.cluster.local      → NXDOMAIN
        ├─ try api.github.com.cluster.local          → NXDOMAIN
        └─ try api.github.com.                       → HIT (finally)
           (4 lookups for one external name — the ndots tax)
```

### Record types in the cluster

| Service kind | DNS returns | Used for |
|---|---|---|
| **Normal (ClusterIP)** | one **A/AAAA** = the ClusterIP | load-balanced access |
| **Named ports** | **SRV** records (`_port._proto.<svc>…`) | port discovery |
| **Headless (`clusterIP: None`)** | one **A record per ready pod** | addressing individual pods (StatefulSets) |
| **ExternalName** | a **CNAME** to an external host | aliasing an outside service |

**CoreDNS itself** runs as a Deployment in `kube-system`, fronted by a Service named `kube-dns` (historical name) at the well-known ClusterIP. It watches the Kubernetes API for Services/Endpoints and answers from that live data — with a `Corefile` config that also forwards non-cluster names (`api.github.com`) upstream to the node's real DNS.

> **✅ Check yourself before Rung 4:** Why does querying an external name like `api.github.com` from a pod cause *several* failed lookups before it succeeds — and which resolv.conf setting is responsible?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **CoreDNS** | The cluster's DNS server (runs as pods) | The resolver |
| **kube-dns Service** | The ClusterIP fronting CoreDNS (e.g. 10.96.0.10) | The nameserver pods point at |
| **FQDN** | `<svc>.<ns>.svc.cluster.local` | The full record name |
| **search domains** | Suffixes auto-appended to short names | Why short names work |
| **ndots:5** | Names with <5 dots tried as unqualified first | The extra-query gotcha |
| **A / AAAA record** | Name → ClusterIP (v4/v6) | Normal Service resolution |
| **SRV record** | Name → host+port | Named-port discovery |
| **Headless Service** | No ClusterIP; DNS returns pod IPs | Per-pod addressing |
| **ExternalName** | CNAME to an outside host | Aliasing external services |
| **NodeLocal DNSCache** | A per-node DNS cache DaemonSet | Reduces CoreDNS load/latency |
| **dnsPolicy** | Per-pod DNS behavior setting | Controls resolv.conf |

**Same-kind-of-thing groupings:** *CoreDNS, kube-dns Service, the nameserver line* are all "how a pod finds the resolver." *A, SRV, CNAME records* are all "what CoreDNS answers with." *search + ndots* together are "how short names get expanded (and slowed)."

---

## 🔬 Rung 5 — The Trace

**A pod in `default` calls `http://payments.prod:8080` (a Service in the `prod` namespace).**

```
[app pod, namespace=default]
  │ 1. resolve "payments.prod" (1 dot < ndots:5 → unqualified, use search list)
  ▼
[stub resolver reads /etc/resolv.conf] nameserver 10.96.0.10
  │ 2. query CoreDNS: payments.prod.default.svc.cluster.local → NXDOMAIN
  │    query CoreDNS: payments.prod.svc.cluster.local        → A 10.96.0.55  ✔
  ▼
[CoreDNS pod] (reached via the kube-dns ClusterIP, DNATed by kube-proxy ── 25)
  │ 3. CoreDNS looks up the Service in its API-synced data → returns ClusterIP
  ▼
[app pod] now has 10.96.0.55, connects to :8080
  │ 4. kube-proxy DNAT: 10.96.0.55 → a ready payments pod IP ── 25
  ▼
[payments pod] handles the request
```

Two systems chain: **DNS** (name → ClusterIP) then **kube-proxy** (ClusterIP → pod IP). DNS handles discovery; kube-proxy handles delivery. Note step 2's first NXDOMAIN — that's the search-list/ndots behavior in action.

> **✅ Check yourself before Rung 6:** In that trace, DNS returned a ClusterIP, not a pod IP. Which component turns that ClusterIP into an actual pod, and why is that separation useful?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: no cluster DNS — hardcode ClusterIPs, or use environment-variable service discovery.**

| Approach | Hardcoded ClusterIP | Env-var discovery | CoreDNS |
|---|---|---|---|
| Human-friendly names | ❌ | ⚠️ ALL_CAPS vars | ✅ |
| Works if Service created *after* the pod | ✅ (if IP known) | ❌ (vars set at pod start) | ✅ (resolved at call time) |
| Cross-namespace | manual | ❌ same-ns only | ✅ via FQDN |
| Per-pod addressing | ❌ | ❌ | ✅ Headless |
| Portable across clusters | ❌ | ⚠️ | ✅ |

Kubernetes *does* still inject env vars (`PAYMENTS_SERVICE_HOST`) for backward compatibility, but they only exist for Services created before the pod — a real footgun. **DNS is the recommended discovery mechanism** precisely because it resolves at call time and supports cross-namespace and Headless addressing.

**When would I reach past cluster DNS?** For very high-QPS internal calls where DNS latency matters, add **NodeLocal DNSCache** (a per-node cache) or tune `ndots`; for external-name aliasing, use ExternalName rather than baking in a public hostname.

**One-sentence why-this-over-that:** *Use CoreDNS names for all in-cluster wiring because they resolve at call time and survive IP churn; only hardcode IPs or use env vars when you have a specific, narrow reason.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: resolve a Service by short name and FQDN

> **Prediction:** "If I `nslookup` a Service from a pod in the same namespace, the short name resolves to the ClusterIP via the search list, and the FQDN resolves directly, BECAUSE `search` appends `<ns>.svc.cluster.local` to short names."

```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80         # ClusterIP Service "web"

kubectl run dnsprobe --rm -it --image=busybox:1.36 --restart=Never -- sh -c '
  cat /etc/resolv.conf;
  echo "--- short name ---"; nslookup web;
  echo "--- fqdn ---"; nslookup web.default.svc.cluster.local'
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
# Name: web.default.svc.cluster.local  Address: 10.96.0.50   <- short name expanded
# Name: web.default.svc.cluster.local  Address: 10.96.0.50   <- fqdn direct
```

**Verify:** both resolve to the same ClusterIP. If the short name fails but the FQDN works, the pod's `search` domains are wrong (or you're calling cross-namespace and need `web.<ns>`).

### Example 2 — Edge case: cross-namespace short name fails; FQDN fixes it

> **Prediction:** "If I call a Service in *another* namespace by its short name, it fails, BECAUSE the search list only prepends the *caller's* namespace — I must use `<service>.<namespace>`."

```bash
kubectl create namespace prod
kubectl create deployment payments -n prod --image=nginx
kubectl expose deployment payments -n prod --port=80

# From a pod in "default", the bare name does NOT find the prod Service:
kubectl run x --rm -it --image=busybox:1.36 --restart=Never -- sh -c '
  nslookup payments 2>&1 | tail -2;
  echo "--- with namespace ---";
  nslookup payments.prod 2>&1 | tail -2'
# ** server can'"'"'t find payments: NXDOMAIN         <- bare name fails cross-ns
# Name: payments.prod.svc.cluster.local  Address: 10.96.0.77   <- works with .prod
```

**Verify:** `payments` fails, `payments.prod` succeeds. This is *the* most common "my service can't reach the other team's service" bug — the fix is the FQDN, not a networking change.

### Example 3 — Kubernetes-flavored: a Headless Service returns per-pod IPs

> **Prediction:** "If I make a Service Headless (`clusterIP: None`), DNS returns one A record *per pod* instead of a single ClusterIP, BECAUSE there is no VIP to hand out — clients address pods directly (how StatefulSets get stable pod DNS)."

```bash
kubectl create deployment db --image=nginx --replicas=3
kubectl expose deployment db --port=80 --cluster-ip=None    # Headless
kubectl run y --rm -it --image=busybox:1.36 --restart=Never -- nslookup db
# Name: db.default.svc.cluster.local  Address: 10.244.1.5
# Name: db.default.svc.cluster.local  Address: 10.244.2.8
# Name: db.default.svc.cluster.local  Address: 10.244.1.9    <- ALL pod IPs, no single VIP
```

**Verify:** you get multiple A records (the pod IPs), not one ClusterIP. Contrast with a normal Service (Example 1) that returns exactly one VIP. This per-pod DNS is what gives StatefulSet pods their stable `pod-0.db...` identities.

---

## 🏔 Capstone — Compress It

**One sentence:** CoreDNS runs inside the cluster and turns Service names into ClusterIPs at `<service>.<namespace>.svc.cluster.local`, and each pod's `resolv.conf` (with `search` domains and `ndots:5`) is what makes `curl http://payments` resolve — while the same `ndots:5` is why external lookups can be slow.

**Explain it to a beginner in 3 sentences:**
1. Services have stable IPs, but you still want to call them by name, so Kubernetes runs its own DNS server (CoreDNS) that maps every Service name to its current ClusterIP.
2. Every pod is configured to ask CoreDNS first and to auto-complete short names with its own namespace, which is why `http://payments` works inside a namespace but `payments.prod` is needed across namespaces.
3. After DNS gives you the ClusterIP, kube-proxy takes over and forwards you to a real pod — DNS handles *finding*, kube-proxy handles *delivering*.

**Sub-parts mapped to the one idea (cluster DNS that knows every Service):**
```
FQDN scheme      → deterministic name per Service
resolv.conf      → nameserver = CoreDNS ClusterIP
search domains   → short names work within a namespace
ndots:5          → the extra-query latency gotcha
A / SRV records  → normal Service / named ports
Headless         → per-pod A records (StatefulSets)
CoreDNS          → the server, synced from the API
```

**Which rung to revisit hands-on:** Rung 7 Example 2 — the cross-namespace short-name failure is the bug you'll actually hit; internalize the FQDN fix.

---

## Related concepts

- [DNS](09-dns.md) — the general resolution chain, record types, and TTLs CoreDNS builds on.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — what a Service name resolves *to*, and delivery after DNS.
- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — the pod IPs Headless Services return.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — external names vs internal service discovery.
- [Network Observability](32-network-observability.md) — diagnosing DNS latency and failures.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A Service's ClusterIP is already stable — so why is resolving it by *name* still worth a whole DNS system inside the cluster?

**A:** Because a stable IP is still just an IP: it's assigned when the Service is created, so the same manifest gets a *different* ClusterIP in staging vs prod, making hardcoded IPs non-portable across clusters and namespaces. Hardcoding also tightly couples deployment order (the Service must exist first so you can learn its IP) and gives humans nothing readable — "connect to payments" should be spelled `payments`, not `10.96.0.50`. Names solve all three: they're predictable (`payments.prod.svc.cluster.local`), portable across environments, and resolved to the current address automatically at call time — the same reason the whole internet uses DNS.

### Before Rung 3
**Q:** If a pod resolves `payments` and gets a ClusterIP back, what made that name exist as a DNS record in the first place?

**A:** Creating the Service did. Every Service automatically gets an A/AAAA record at the deterministic name `<service>.<namespace>.svc.cluster.local`, pointing at its ClusterIP. CoreDNS watches the Kubernetes API for Services/Endpoints and answers from that live, API-synced data — nobody registers records by hand. The short name `payments` works because the pod's `search` domains expand it to the FQDN for its namespace.

### Before Rung 4
**Q:** Why does querying an external name like `api.github.com` from a pod cause *several* failed lookups before it succeeds — and which resolv.conf setting is responsible?

**A:** The responsible setting is `options ndots:5`. Any name with fewer than 5 dots is treated as *unqualified*, so the resolver tries it against each `search` domain first: `api.github.com` (only 2 dots) generates `api.github.com.prod.svc.cluster.local`, then `api.github.com.svc.cluster.local`, then `api.github.com.cluster.local` — all NXDOMAIN — before finally trying `api.github.com.` as-is and succeeding. That's 4 lookups for one external name, and multiplied across every external call this "ndots tax" turns DNS into a real latency source (mitigated by tuning `ndots` or adding NodeLocal DNSCache).

### Before Rung 6
**Q:** In the trace, DNS returned a ClusterIP, not a pod IP. Which component turns that ClusterIP into an actual pod, and why is that separation useful?

**A:** kube-proxy — or more precisely, the kernel DNAT rules kube-proxy wrote — rewrites the ClusterIP (10.96.0.55) into the IP of a ready payments pod at connection time. The separation is DNS handling *discovery* (name → stable ClusterIP) while kube-proxy handles *delivery* (ClusterIP → current pod IP). This is useful because the DNS answer stays valid no matter how pods churn: clients can cache the ClusterIP indefinitely, and readiness-driven endpoint changes and load balancing happen underneath at the forwarding layer, per connection, without any new DNS lookup.
