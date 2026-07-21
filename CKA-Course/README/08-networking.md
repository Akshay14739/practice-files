# Networking, Climbed the Ladder 🪜
### Section 8 of the CKA — deriving how traffic finds a pod

> How traffic moves: **CNI** (pod IPs), **kube-proxy** (service VIPs), **CoreDNS** (names), and **Ingress** (L7 edge). It looks like four unrelated tools; it's really **one four-layer stack answering "how do I reach that?"** We climb from **the pain of ephemeral pod IPs** → **the layered idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.
>
> **Prereqs** live in the sibling guides: [../../Linux/13-namespaces.md](../../Linux/13-namespaces.md) (veth/netns), [../../Networking/09-dns.md](../../Networking/09-dns.md) (resolv.conf, search domains), [../../Networking/24-kubernetes-pod-networking-cni.md](../../Networking/24-kubernetes-pod-networking-cni.md). This file is the **Kubernetes** layer.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** The four layers that let anything reach anything in a cluster: pod-to-pod (CNI), name-and-VIP-to-pod (Services + kube-proxy + CoreDNS), and outside-to-app (Ingress).

**Why did it land on my desk?** *Services & Networking* is 20% of the CKA. The CNI/kube-proxy/CoreDNS **inspection commands** and **Ingress creation** are reliable points, and "pod can't reach service" is a staple troubleshooting task.

**What do I already know?** Probably that Services exist ([Section 1](01-core-concepts.md)). What's fuzzy: what actually forwards a packet to a pod, why a Service IP won't ping, and why short DNS names fail across namespaces.

---

# RUNG 1 — The Pain 🔥
### *Why does cluster networking exist at all?*

Pods are ephemeral and spread across nodes. Getting a packet to the right one is genuinely hard:

```
THE REACHABILITY PAIN
  pod IPs change on restart      ─▶ hard-code one and it breaks constantly
  pods live on different nodes   ─▶ how does a pod on node A reach a pod on node B?
  which of 3 replicas do I hit?  ─▶ you need ONE stable address that load-balances
  address by name, not IP        ─▶ apps want "mysql", not 10.244.3.7
  expose 20 apps externally      ─▶ 20 cloud LoadBalancers = 20 bills, no host/path routing
```

**Before / without it:** you'd wire up routes and NAT by hand, chase changing IPs, and pay for a load balancer per service — with no name-based discovery.

**What breaks without each layer:** no **CNI** → pods have no IPs / can't cross nodes; no **kube-proxy** → a Service VIP forwards nowhere; no **CoreDNS** → you must use raw IPs; no **Ingress** → external HTTP routing and shared TLS are impossible.

**Who feels it most?** The platform team — you own a network that must be flat, stable, name-addressable, and externally reachable, across many nodes and constant pod churn.

> **✅ Check yourself before Rung 2:** Give the single reason you can't just point your frontend at a backend pod's IP. What property of pods makes that fragile?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Kubernetes networking is a four-layer stack, each answering "how do I reach that?": the **CNI** gives every pod a unique, flat, NAT-free IP; **kube-proxy** turns a Service's virtual IP into iptables/IPVS rules that DNAT to a live pod; **CoreDNS** maps names to those virtual IPs; and **Ingress** adds one L7 door that routes external traffic by host/path.**

Derivations:
- *"CNI gives every pod a flat NAT-free IP"* → the **network model's rules** (every pod reachable without NAT); Kubernetes doesn't implement it — you deploy a CNI addon, and a `NotReady` node usually means *no CNI*.
- *"kube-proxy… DNAT to a live pod"* → a Service is a **virtual IP nothing listens on**; kube-proxy programs the kernel to rewrite it to a real pod IP. That's why a ClusterIP **won't ping** — only its DNAT'd ports work.
- *"CoreDNS maps names to VIPs"* → `mysql` → `10.96.x.y`; the kubelet points every pod's `/etc/resolv.conf` at CoreDNS; **search domains** are why short names work *within* a namespace.
- *"Ingress = one L7 door"* → replaces N LoadBalancers with host/path routing + shared TLS, but needs a **controller** to do anything.

Read a failure by asking *which layer*: no IP → CNI; VIP forwards nowhere → kube-proxy; name won't resolve → CoreDNS; external 404 → Ingress.

> **✅ Check yourself before Rung 2→3:** Why does a Service's ClusterIP not respond to `ping`, yet `curl <clusterIP>:80` works? Which layer explains it?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture the cluster as a city, and each running app (a "pod") as a shop that opens and closes at unpredictable addresses. This section explains the four layers that let anyone find and reach any shop — plus, first, a short list of official phone lines (fixed port numbers — think of them as well-known extensions the city's departments always answer on, which the security guards must not block).
>
> **Layer 1 — Streets and addresses (the "CNI," the city's road contractor).** Kubernetes itself doesn't pave roads; you hire a contractor (a network plug-in) that gives every shop its own unique street address and builds roads so any shop can reach any other directly — even in another district (another computer) — with no detours or address-translation tricks. The contractor's tools and blueprints live in two known filing drawers on each computer. If a new district shows up as "NotReady," it usually means no road contractor was hired yet. One rule: the shops' address range and the phone-number range (next layer) must never overlap.
>
> **Layer 2 — One stable phone number per business ("Services" and "kube-proxy").** Shops move constantly, so each business gets a permanent phone number that isn't attached to any physical shop — it's a virtual number. A switchboard operator on every corner ("kube-proxy") keeps rewiring that number to whichever shop branch is currently open, using the building's wiring rules (kernel rules called iptables). That's why you can *call* the number but can't *knock on its door* — there's no building there (why the address won't answer a "ping").
>
> **Layer 3 — The phone book ("CoreDNS").** Nobody memorizes numbers; you ask directory assistance for "mysql" and get the virtual number back. Every shop is automatically given the directory's contact card. Handy shortcut: within your own neighborhood (a "namespace" — a walled-off area) first names work; to call another neighborhood you must use the full name, like "mysql.payroll."
>
> **Layer 4 — The city's front gate ("Ingress").** For visitors from outside the city, instead of building a separate private tollbooth per business (one paid load balancer each), you build one smart front gate that reads the visitor's destination — which website name and which page path — and directs them to the right business. Crucially, the gate needs a gatekeeper actually hired ("an Ingress controller" — software you must install); the rulebook alone does nothing. And sometimes the gate must trim the path off the address before forwarding, or the shop won't recognize it (the "rewrite" fix for 404 not-found errors).

*Now the original technical deep-dive — the same ideas, in precise form:*

**Ports to know first (firewall/SG):** apiserver **6443**, kubelet **10250**, scheduler **10259**, controller-mgr **10257**, etcd **2379/2380**, NodePort **30000–32767**.

## (A) Layer 1 — pod IPs via the CNI

The **network model (4 rules):** every pod gets a unique IP; every pod reaches every other pod **without NAT** (same *and* cross node); nodes reach pods. A **CNI plugin** implements this:
- **Binaries:** `/opt/cni/bin/` (bridge, flannel, host-local…).
- **Active config:** `/etc/cni/net.d/*.conflist` (lowest filename wins) — the runtime reads it.
- On pod create, the **kubelet → runtime → CNI plugin** (`ADD`): make a **veth**, assign an IP (**IPAM**, usually `host-local`), add routes. The addon (Weave/Flannel/Calico, a **DaemonSet**) owns the **pod CIDR** (e.g. `10.244.0.0/16`).
```bash
ls /opt/cni/bin ; ls /etc/cni/net.d ; cat /etc/cni/net.d/*.conflist
ps -aux | grep kubelet | grep -o 'container-runtime-endpoint=[^ ]*'
```
> 🎯 **Pod CIDR and Service CIDR must NOT overlap.** `NotReady` right after install = **no CNI** → apply an addon.

## (B) Layer 2 — service VIPs via kube-proxy

A **Service is a virtual IP** — no process listens on it. **kube-proxy** (a **DaemonSet**) watches Services/Endpoints and writes **iptables** (default) or **IPVS** rules that **DNAT** the service IP → a backend pod IP.
```
client pod → ClusterIP 10.96.0.50:80
   │  (kube-proxy wrote this iptables NAT rule)
   ▼ DNAT → pod 10.244.1.7:80   (routable via the CNI from Layer 1)
```
- **Service CIDR:** apiserver `--service-cluster-ip-range` (commonly `10.96.0.0/12`).
```bash
kubectl get pods -n kube-system -o wide | grep kube-proxy
kubectl logs -n kube-system <kube-proxy-pod> | grep -i proxier   # "Using iptables Proxier"
iptables -t nat -L KUBE-SERVICES -n | grep <clusterIP>           # the DNAT rules
```

## (C) Layer 3 — names via CoreDNS

**CoreDNS** (pods in `kube-system`, fronted by the **`kube-dns` Service**, ClusterIP commonly **`10.96.0.10`**) resolves names. The kubelet injects that IP into every pod's `/etc/resolv.conf`.
- **Service name:** `<service>.<namespace>.svc.cluster.local` (short name works *within* a namespace via `search` domains).
- **Pod name:** `<ip-with-dashes>.<namespace>.pod.cluster.local`.
```bash
kubectl get svc -n kube-system kube-dns                  # 10.96.0.10
kubectl get configmap coredns -n kube-system -o yaml     # the Corefile (cluster.local zone)
kubectl exec test -- cat /etc/resolv.conf                # nameserver 10.96.0.10 + search domains
kubectl exec test -- nslookup web-service.payroll        # cross-namespace
```
> 🎯 Cross-namespace = FQDN `<svc>.<ns>` (short names only same-ns; **pods** need full FQDN). If DNS fails cluster-wide, check the CoreDNS pods are `Running`.

## (D) Layer 4 — external L7 via Ingress

One `Service type: LoadBalancer` per app = one cloud LB each, no host/path routing. **Ingress** = one L7 entrypoint. **Two halves:** the **Ingress Controller** (nginx/Traefik/ALB — you must **deploy one**; not built in) and the **Ingress resource** (rules). No controller ⇒ nothing happens.
```yaml
kind: Ingress                          # networking.k8s.io/v1
metadata:
  name: shop
  annotations: { nginx.ingress.kubernetes.io/rewrite-target: / }
spec:
  rules:
  - host: my-online-store.com
    http:
      paths:
      - { path: /wear,  pathType: Prefix, backend: { service: { name: wear-service,  port: { number: 80 } } } }
      - { path: /watch, pathType: Prefix, backend: { service: { name: video-service, port: { number: 80 } } } }
```
```bash
kubectl create ingress ingress-test --rule="wear.my-online-store.com/wear*=wear-service:80"
```
> 🎯 `rewrite-target: /` strips the matched path (backends often lack `/wear` → 404 without it). An Ingress can only reference Services in its **own namespace**.

> **✅ Check yourself before Rung 4:** For each layer name the component and where it lives: (1) gives a pod its IP, (2) DNATs a service VIP, (3) resolves `mysql`, (4) routes `example.com/pay`. Which two run as DaemonSets?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Layer |
|---|---|---|
| **CNI plugin / addon** | Implements pod networking | 1 pod IPs |
| **/opt/cni/bin, /etc/cni/net.d** | Plugin binaries / active config | 1 |
| **IPAM / veth / pod CIDR** | IP allocation / pod's cable / pod IP range | 1 |
| **Service (VIP) / ClusterIP** | Stable virtual IP for a pod set | 2 service |
| **kube-proxy** | Programs iptables/IPVS DNAT (DaemonSet) | 2 |
| **iptables / IPVS / DNAT** | The kernel rules that rewrite VIP→pod | 2 |
| **service CIDR** | Range VIPs come from | 2 |
| **CoreDNS / kube-dns** | Name resolver / its Service | 3 DNS |
| **resolv.conf / search domain** | Pod's DNS config / why short names work | 3 |
| **FQDN** | `<svc>.<ns>.svc.cluster.local` | 3 |
| **Ingress controller** | The proxy pods doing L7 routing | 4 edge |
| **Ingress resource** | The host/path rules | 4 |
| **rewrite-target / pathType** | URL rewrite / match style | 4 |

**The unlock — the layers stack:**
```
OUTSIDE ─▶ [4] Ingress (host/path, L7) ─▶ [2] Service VIP (kube-proxy DNAT)
                                              ▲ resolved by [3] CoreDNS (name → VIP)
                                              ▼
                                          [1] Pod IP (CNI, flat/NAT-free)
```

> **✅ Check yourself before Rung 5:** Which layer would you suspect for each: `NotReady` node; ClusterIP reachable but `nslookup mysql` fails; external `/pay` returns 404; two pods on different nodes can't ping each other?

---

# RUNG 5 — The Trace 🎬
### *Follow ONE request down all four layers*

**Trace — browser hits `my-store.com/wear`, which internally calls `mysql`:**
1. **DNS (public):** `my-store.com` resolves to the **Ingress controller's** external IP/LB.
2. **[4] Ingress:** the controller matches `host=my-store.com, path=/wear` → backend `wear-service:80`; `rewrite-target: /` changes the path to `/`.
3. **[3] CoreDNS:** to reach `wear-service`, the name resolves (via `/etc/resolv.conf` → `10.96.0.10`) to the Service **ClusterIP**.
4. **[2] kube-proxy:** the packet to that ClusterIP hits the node's **iptables** `KUBE-SERVICES` chain → **DNAT** to one live `wear` **pod IP**.
5. **[1] CNI:** that pod IP is routable across nodes via the CNI's routes/veth; the packet arrives at the `wear` pod.
6. The `wear` app calls **`mysql`** → **[3]** CoreDNS resolves `mysql.<ns>.svc.cluster.local` → **[2]** kube-proxy DNATs the mysql Service VIP → **[1]** CNI routes to the mysql pod. Same three inner layers, one level deeper.
7. Responses walk back; kube-proxy's conntrack un-DNATs so the client sees replies from the VIP it sent to.

```
browser →(pubDNS) Ingress-LB →[4 host/path]→ Service VIP
                                   ▲[3 CoreDNS name→VIP]
                                   ▼[2 kube-proxy DNAT VIP→podIP]
                                 wear pod [1 CNI routes] → calls mysql (repeat 3→2→1)
```

> **✅ Check yourself before Rung 6:** In this trace, which layer made `wear-service` a *name* you could use, and which one actually forwarded the packet to a specific pod? Why are those two different components?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **CNI** | **kube-proxy** | gives pods *real* IPs / routes vs turns *virtual* Service IPs into DNAT |
| **Service (L4)** | **Ingress (L7)** | stable IP + port load-balance vs host/path/TLS HTTP routing |
| **NodePort / LoadBalancer** | **Ingress** | one entry per service vs one shared entry routing many |
| **iptables mode** | **IPVS mode** | rule-chain (fine at small scale) vs hash table (better at large scale) |
| **short name** | **FQDN** | same-namespace only vs cross-namespace / pods |

**When NOT to:** don't expect a ClusterIP to `ping` (no host owns it); don't use short DNS names across namespaces; don't deploy an Ingress *resource* without a *controller* (it does nothing); don't overlap pod and service CIDRs.

**One-sentence "why this over that":**
> Let the CNI give pods flat IPs, kube-proxy give pod *sets* a stable VIP, CoreDNS give those VIPs *names*, and Ingress give the outside world one host/path door — four layers, each solving reachability at a different level.

> **✅ Check yourself before Rung 7:** Explain why you'd choose one Ingress over ten `type: LoadBalancer` Services — name two concrete things Ingress gives you that per-service LBs don't.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — Inspect the stack and name every layer

> **My prediction:** "If I read `/etc/cni/net.d`, kube-proxy's logs, and the apiserver manifest, I can name the CNI, proxy mode, pod CIDR, and service CIDR — and the two CIDRs won't overlap — *because* each layer records its config in a known place."

```bash
ls /etc/cni/net.d                                                    # CNI
kubectl logs -n kube-system -l app=flannel | grep -i ip-alloc        # pod CIDR
grep service-cluster-ip-range /etc/kubernetes/manifests/kube-apiserver.yaml   # service CIDR
kubectl logs -n kube-system <kube-proxy-pod> | grep -i proxier       # mode
```
**Verify:** you can state all four, non-overlapping. This *is* the standard "explore networking" lab.

## Prediction 2 — Short DNS names fail across namespaces; FQDN fixes it

> **My prediction:** "If `web-app` in `default` looks up `mysql` (which lives in `payroll`), it's NXDOMAIN, but `mysql.payroll` resolves — *because* the pod's `search` domains only cover its own namespace, so crossing namespaces needs the qualified name."

```bash
kubectl exec web-app -- nslookup mysql            # NXDOMAIN
kubectl exec web-app -- nslookup mysql.payroll    # resolves
kubectl set env deployment/web-app DB_HOST=mysql.payroll
```
**Verify:** the qualified name resolves and the app connects. If *both* fail, CoreDNS itself is down (check its pods).

## Prediction 3 — Ingress 404 until `rewrite-target`

> **My prediction:** "If I add a `/pay` path to a backend that only serves `/`, then `curl /pay` returns 404 until I add `rewrite-target: /` — *because* the controller forwards `/pay` verbatim, which the backend doesn't have."

```bash
kubectl create ingress ingress-pay -n critical-space --rule="/pay=pay-service:8282"
curl http://<ingress-ip>/pay                        # 404
kubectl logs -n critical-space <pay-pod>            # request arrived as /pay
kubectl annotate ingress ingress-pay -n critical-space \
  nginx.ingress.kubernetes.io/rewrite-target=/
curl http://<ingress-ip>/pay                        # 200
```
**Verify:** 404 → 200 after the annotation. The Ingress must be in the **same namespace** as `pay-service`.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> The CNI gives every pod a flat NAT-free IP, kube-proxy turns each Service's virtual IP into iptables/IPVS DNAT to a live pod, CoreDNS maps names to those VIPs, and Ingress puts one L7 host/path door in front — four layers, each answering "how do I reach that?"

**Explain it to a beginner in 3 sentences:**
> 1. A network plugin (CNI) gives every pod its own IP and makes pods reachable across all nodes without NAT.
> 2. Because pod IPs change, a Service gives a set of pods one stable virtual IP that kube-proxy quietly rewrites to a real pod, and CoreDNS lets you use a *name* instead of that IP.
> 3. To let the outside world in, you deploy an Ingress controller and write rules that route by hostname and URL path to the right Service.

**Which rung to revisit hands-on?**
- **Rung 3B (kube-proxy DNAT)** — the "VIP that nothing listens on" is unintuitive. Fix: `iptables -t nat -L KUBE-SERVICES` and find your service.
- **Rung 3C (DNS search domains)** — the same-ns-vs-FQDN rule. Fix: Prediction 2, then `cat /etc/resolv.conf` and read the search list.

---

## 🎯 CKA exam tips & quick notes

- **Ports:** apiserver **6443**, kubelet **10250**, scheduler **10259**, controller-mgr **10257**, etcd **2379/2380**, NodePort **30000–32767**.
- **CNI:** binaries `/opt/cni/bin`, config `/etc/cni/net.d`; deploy with `kubectl apply -f`; `NotReady` → CNI missing; **pod CIDR ≠ service CIDR**.
- **kube-proxy** = DaemonSet; mode from its logs; DNATs VIP→pod via iptables/IPVS.
- **CoreDNS:** `kube-dns` ClusterIP `10.96.0.10`; Corefile = `coredns` ConfigMap; cross-ns = FQDN `<svc>.<ns>`.
- **Ingress:** deploy a **controller** first; `kubectl create ingress name --rule="host/path=svc:port"`; `pathType: Prefix`; **`rewrite-target: /`** fixes 404s; same-namespace as its Services.
- Debug from inside a pod with `nslookup` / `kubectl exec ... -- curl`.

## 📌 Command cheat sheet
```bash
# INSPECT
kubectl get nodes -o wide ; ip addr ; ip route
ls /opt/cni/bin ; ls /etc/cni/net.d
kubectl get pods -n kube-system -o wide          # coredns, kube-proxy, CNI DaemonSets
kubectl logs -n kube-system <kube-proxy-pod>     # proxy mode
# DNS
kubectl exec <pod> -- cat /etc/resolv.conf
kubectl exec <pod> -- nslookup <svc>.<ns>.svc.cluster.local
# INGRESS
kubectl create ingress web --rule="host.com/path*=svc:80"
kubectl describe ingress web
```

---

## Related sections

- [Section 1 — Core Concepts](01-core-concepts.md) — Services (ClusterIP/NodePort/LoadBalancer) and kube-proxy's role.
- [Section 6 — Security](06-security.md) — NetworkPolicies enforced by the CNI; DNS for egress rules.
- [Section 9 — Design & Install a Kubernetes Cluster](09-design-and-install-kubernetes-cluster.md) — choosing pod/service CIDRs at install.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — DNS/CNI/service connectivity debugging.
- [../../Networking/24-kubernetes-pod-networking-cni.md](../../Networking/24-kubernetes-pod-networking-cni.md) · [../../Networking/25-kubernetes-services-kube-proxy.md](../../Networking/25-kubernetes-services-kube-proxy.md) · [../../Networking/26-kubernetes-dns-service-discovery.md](../../Networking/26-kubernetes-dns-service-discovery.md) · [../../Networking/27-kubernetes-ingress-gateway-api.md](../../Networking/27-kubernetes-ingress-gateway-api.md) — each layer in depth.
- [../../Linux/12-iptables-netfilter.md](../../Linux/12-iptables-netfilter.md) — the iptables/netfilter kube-proxy programs.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Give the single reason you can't just point your frontend at a backend pod's IP. What property of pods makes that fragile?

**A:** Pods are **ephemeral** — a pod's IP changes every time it restarts or reschedules, so any hard-coded pod IP breaks constantly. That churn is exactly why the stack exists: a Service gives the pod *set* one stable virtual IP, and CoreDNS gives that VIP a name, so the frontend addresses "backend" instead of a specific, short-lived 10.244.x.y address.

### Before Rung 2→3
**Q:** Why does a Service's ClusterIP not respond to `ping`, yet `curl <clusterIP>:80` works? Which layer explains it?

**A:** Layer 2 — **kube-proxy** — explains it. A Service is a **virtual IP that no process listens on**; no host owns it, so ICMP `ping` gets no reply. kube-proxy programs iptables/IPVS **DNAT** rules for the Service's ports, so a TCP packet to `<clusterIP>:80` is rewritten in the kernel to a live pod IP and `curl` works — only the DNAT'd ports function, never the bare IP.

### Before Rung 4
**Q:** For each layer name the component and where it lives: (1) gives a pod its IP, (2) DNATs a service VIP, (3) resolves `mysql`, (4) routes `example.com/pay`. Which two run as DaemonSets?

**A:** (1) The **CNI plugin** — binaries in `/opt/cni/bin/`, active config in `/etc/cni/net.d/`, with the addon (Flannel/Calico/Weave) running as a DaemonSet; the kubelet → runtime → CNI `ADD` call assigns the IP. (2) **kube-proxy**, a DaemonSet in `kube-system`, which writes iptables/IPVS DNAT rules on every node. (3) **CoreDNS**, pods in `kube-system` fronted by the `kube-dns` Service (ClusterIP `10.96.0.10`, injected into every pod's `/etc/resolv.conf`). (4) The **Ingress controller** (nginx/Traefik/ALB), proxy pods you deploy yourself, driven by Ingress resources. The two DaemonSets are the **CNI addon** and **kube-proxy**.

### Before Rung 5
**Q:** Which layer would you suspect for each: `NotReady` node; ClusterIP reachable but `nslookup mysql` fails; external `/pay` returns 404; two pods on different nodes can't ping each other?

**A:** `NotReady` node → **Layer 1, CNI** — a node NotReady right after install usually means no CNI addon is applied. ClusterIP works but `nslookup mysql` fails → **Layer 3, CoreDNS** — the VIP and DNAT are fine, name resolution isn't (check CoreDNS pods, or use the FQDN across namespaces). External `/pay` 404 → **Layer 4, Ingress** — a missing/wrong rule or a missing `rewrite-target: /` annotation. Cross-node pod-to-pod failure → **Layer 1, CNI** — the flat NAT-free pod network isn't routing between nodes.

### Before Rung 6
**Q:** In the trace, which layer made `wear-service` a *name* you could use, and which one actually forwarded the packet to a specific pod? Why are those two different components?

**A:** **CoreDNS (Layer 3)** made `wear-service` a usable name — it resolves the name to the Service's ClusterIP via the pod's `/etc/resolv.conf`. **kube-proxy (Layer 2)** actually forwarded the packet — its iptables `KUBE-SERVICES` DNAT rule rewrote the VIP to one live pod IP, which the CNI then routed. They're different components because they solve different problems: DNS is a one-time name-to-VIP lookup done in userspace, while forwarding must happen in the kernel on **every packet** and track which backends are currently alive — CoreDNS knows names, kube-proxy knows endpoints.

### Before Rung 7
**Q:** Why choose one Ingress over ten `type: LoadBalancer` Services — name two concrete things Ingress gives you that per-service LBs don't.

**A:** Ten LoadBalancer Services mean ten cloud load balancers and ten bills, each a dumb L4 entry for one service. One Ingress gives you (1) **host/path L7 routing** — a single entrypoint that routes `example.com/wear` and `example.com/watch` to different backend Services — and (2) **one shared front door**, meaning a single external IP/LB (one bill) and shared TLS termination at that edge. The trade-off from the ladder: you must deploy an Ingress **controller** first, or the resource does nothing.
