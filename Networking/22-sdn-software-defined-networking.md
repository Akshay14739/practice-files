# SDN — Software-Defined Networking

*The one architectural split — brain vs muscle — that quietly powers your VPC, your CNI, kube-proxy, and your service mesh.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Software-Defined Networking: the idea of separating the **control plane** (the brain that decides where traffic goes) from the **data plane** (the muscle that actually forwards packets), and making the brain programmable through software and APIs.

**Why did it land on my desk?** You never `ssh` into a switch to configure your EKS network. You write a Kubernetes `Service`, a `NetworkPolicy`, or a VPC route-table entry, and *seconds later* traffic behaves differently across dozens of nodes — no cables touched, no per-box CLI. That is SDN. Understanding it turns "Kubernetes networking is magic" into "oh, it's a controller programming a data plane," and that single insight recurs everywhere.

**What do I already know?** You've met routers with routing tables ([08-routing-and-forwarding.md](08-routing-and-forwarding.md)) and kube-proxy writing iptables rules ([25-kubernetes-services-kube-proxy.md](25-kubernetes-services-kube-proxy.md)). SDN is the pattern *behind* both.

---

## 🔥 Rung 1 — The Pain

In the traditional world, every switch and router was a **self-contained box**: its brain (routing decisions, ACLs) and its muscle (the forwarding silicon) were welded together, configured one device at a time via its own CLI.

That hurt in specific ways:

- **Manual, per-box, error-prone.** Rolling out a new policy meant logging into hundreds of devices and typing the same commands, hoping you didn't fat-finger one. A single missed box was a silent hole.
- **No global view or coordination.** Each box only knew its neighbors. There was no central place to say "here is the network I want" and have it realized everywhere.
- **Vendor lock-in and rigidity.** The brain was baked into proprietary firmware. You couldn't program new behavior; you waited for a vendor feature.
- **Impossible at cloud scale.** Now imagine a cloud provider with millions of virtual machines, each needing its own virtual network, appearing and vanishing every second. You *cannot* hand-configure physical boxes fast enough. Multi-tenant cloud networking is simply infeasible with the old model.

**Who feels it most?** Anyone operating a large, fast-changing network — cloud providers first, then every platform team running Kubernetes, where pods (and their network needs) churn constantly.

> **✅ Check yourself before Rung 2:** Why can't a network of self-contained boxes — each configured by hand — support a cloud where thousands of virtual networks are created and destroyed per minute?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **SDN splits the network into a control plane that decides and a data plane that forwards, then lets software program the control plane centrally via APIs — so the whole network becomes a system you configure with code instead of a pile of boxes you configure by hand.**

Everything derives from the split:

- *Decide vs forward are separated* → the brain can live in software (a controller), the muscle can be cheap/fast/dumb.
- *Programmable via API* → you declare the network you want; the controller realizes it everywhere.
- *Central coordination* → one consistent policy pushed to every forwarding element, no per-box drift.

Once you see this split, you'll recognize it in **every** networking system you touch — that recognition is the real prize.

> **✅ Check yourself before Rung 3:** In one breath — what does the control plane produce, and what does the data plane consume?

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture a courier company. The whole idea of this chapter is one split: separate the *deciding* from the *doing*.
>
> - The **control plane** is the head-office planning department — "the brain." It works out how every delivery should travel and writes the route sheets. It never touches a single package itself.
> - The **data plane** is the drivers and conveyor belts — "the muscle." They move each package at full speed by following the route sheets exactly, without thinking.
> - The **controller** is the planning software sitting at head office, holding the master picture of how things *should* be. You and your applications tell it what you want through the front counter (the "northbound API" — the request desk facing management), and it pushes the finished route sheets down to the drivers through the back channel (the "southbound API" — with **OpenFlow** being one classic standard language for those instructions).
>
> One reassuring consequence: if head office loses power, deliveries don't stop. The drivers already have their route sheets, so existing traffic keeps flowing — you just can't issue *new* routes until the planners are back.
>
> **The real lesson: this pattern is everywhere.** Once you see "brain decides, muscle forwards," a pile of scary-sounding technologies collapse into one shape:
>
> - A **classic router**: its planning side computes the best routes; a simple lookup table actually moves the packets.
> - **kube-proxy** (a Kubernetes helper): it watches for changes and writes forwarding rules; the operating system's built-in machinery does the actual forwarding.
> - **Modern container networking (e.g. Cilium)**: an agent decides the policy; tiny fast programs planted inside the operating system's core do the moving.
> - A **service mesh**: one central brain configures a fleet of little courier proxies that sit beside each app.
> - **The AWS cloud itself**: Amazon's central systems hold your settings; the hardware under your virtual machines does the forwarding.
>
> Learn the split once, and five "new" technologies turn out to be the same courier company wearing different uniforms.

*Now the original technical deep-dive — the same ideas, in precise form:*

### The two planes

- **Control plane (the brain):** computes *how* traffic should flow — routes, load-balancing decisions, access rules — and pushes that as configuration to the forwarding elements. It does **not** touch individual packets.
- **Data plane (the muscle):** the actual forwarding path — switches, NICs, iptables/IPVS/eBPF in the kernel — that moves each packet at line rate according to the rules the control plane installed.
- **Controller:** the centralized software brain. It holds the desired state and programs the data plane, classically via a **southbound API** like **OpenFlow**. Apps and operators talk to it via a **northbound API**.

```
┌──────────────────────────────────────────────────────────┐
│  CONTROL PLANE (software brain — decides, never forwards) │
│  ┌────────────────────────────────────────────────────┐  │
│  │            Controller  (holds desired state)        │  │
│  │  northbound API ▲  (you/apps declare intent)        │  │
│  │  southbound API ▼  (OpenFlow / gRPC / writes rules) │  │
│  └───────────────────┬────────────────────────────────┘  │
│         push flow rules to every forwarding element        │
│      ┌───────────────┼───────────────┐                    │
│      ▼               ▼               ▼                     │
│  DATA PLANE (dumb, fast muscle — forwards per installed rules)
│  ┌────────┐     ┌────────┐     ┌────────┐                 │
│  │ switch │     │ switch │     │ kernel │                 │
│  │/ NIC   │     │/ NIC   │     │ iptables│                │
│  └────────┘     └────────┘     └────────┘                 │
│                                                            │
│  KEY: the controller decides ONCE, centrally.              │
│  Packets flow through the data plane ONLY.                 │
└──────────────────────────────────────────────────────────┘
```

If the controller dies, existing flows keep forwarding (the rules are already installed) — you just can't push *new* rules until it's back. That's the same resilience property as a service mesh's istiod ([29-service-mesh-and-sidecars.md](29-service-mesh-and-sidecars.md)).

### The pattern is everywhere (this is the real lesson)

Once you hold "control plane decides, data plane forwards," Kubernetes networking stops being a pile of unrelated tech:

| System | Control plane (decides) | Data plane (forwards) |
|---|---|---|
| Classic router | Routing protocol (OSPF/BGP) computes routes | The forwarding table (FIB) moves packets |
| **kube-proxy** | Watches Services/Endpoints, computes rules | **iptables / IPVS** DNAT in the kernel |
| **CNI (Cilium)** | Agent watches pods/policies | **eBPF** programs in the kernel datapath |
| **Service mesh** | istiod computes proxy config | **Envoy** sidecars move requests |
| **AWS VPC** | AWS's control plane (route tables, SGs) | The hypervisor/Nitro forwarding fabric |

Every one of these is SDN. Learn the split once and five "new" technologies collapse into one shape.

> **✅ Check yourself before Rung 4:** kube-proxy never sits in the packet path, yet it changes how Service traffic is delivered. Which plane is kube-proxy, and which plane actually forwards the packet?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **SDN** | Programmable networking via a control/data-plane split | The whole idea |
| **Control plane** | The brain that decides routes/policy | Decides, doesn't forward |
| **Data plane** | The muscle that forwards packets | Forwards per installed rules |
| **Controller** | The centralized software brain | The control plane's core |
| **OpenFlow** | A classic southbound protocol (controller → switch) | How the brain programs the muscle |
| **Southbound API** | Controller → forwarding elements | Downward interface |
| **Northbound API** | Apps/operators → controller | Upward interface (intent) |
| **Flow rule / flow table** | "Match these packets, take this action" | Installed in the data plane |
| **eBPF** | Programmable kernel datapath | A modern data plane |
| **Overlay / underlay** | Virtual network on top of physical | What SDN often builds |

**Same-kind-of-thing groupings:** *control plane, controller, istiod, kube-proxy-the-process* are all "the brain." *Data plane, forwarding table, iptables, IPVS, eBPF, Envoy* are all "the muscle." *OpenFlow, gRPC config push, the CNI ADD call* are all "the brain telling the muscle what to do."

---

## 🔬 Rung 5 — The Trace

**You create a Kubernetes Service. Follow how one declaration becomes forwarding behavior on every node — a textbook SDN loop.**

```
1. You: kubectl apply -f service.yaml
        (northbound intent: "give app=web a stable VIP")
        │
        ▼
2. Kubernetes API server stores the Service object
        │
        ▼
3. kube-proxy on EVERY node is WATCHING the API (control plane)
        │  it computes: "ClusterIP 10.96.0.50:80 → pods 10.244.1.7, 10.244.2.9"
        ▼
4. kube-proxy WRITES data-plane rules on each node:
        iptables:  KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx (DNAT)
        (or programs IPVS / eBPF, depending on mode)
        │
        ▼
5. A pod sends a packet to 10.96.0.50:80
        │  kube-proxy is NOT in this path
        ▼
6. The KERNEL data plane (iptables/IPVS) DNATs it to a real pod IP
        │
        ▼
7. Packet delivered to a backend pod. Done.

Control plane ran ONCE (steps 3–4). The data plane (step 6) runs
for EVERY packet, at line rate, with no controller involvement.
```

Change the Service's selector and the loop re-runs: kube-proxy recomputes and rewrites the rules — no pod restart, no cable moved. That instant, code-driven reconfiguration is the whole point of SDN.

> **✅ Check yourself before Rung 6:** In that trace, which steps happen once per *change*, and which step happens once per *packet*? Why does that division make the system both flexible and fast?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: traditional networking — brain and muscle fused in each box, configured per device.**

| Property | Traditional (fused, per-box) | SDN (split, programmable) |
|---|---|---|
| Configuration | Log into each box, type CLI | Declare intent; controller programs all |
| Global consistency | ❌ per-box drift | ✅ one source of truth |
| Speed of change | Slow, manual | Seconds, automated |
| Cloud multi-tenancy | ❌ infeasible | ✅ the whole basis of cloud |
| Programmable behavior | ❌ vendor firmware | ✅ software controller |
| Failure of the brain | N/A (per box) | Existing flows keep working; no new changes |

**When would I NOT think in SDN terms?** For a tiny home/lab network of a couple of switches, the overhead of a controller is pointless — traditional config is simpler. SDN earns its keep at scale and where change is constant (i.e. every cloud and every cluster).

**One-sentence why-this-over-that:** *Use SDN (a programmable control plane over a dumb-fast data plane) whenever the network is large or changes constantly; a handful of static boxes don't need it.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: see your host's own control/data split

> **Prediction:** "If I look at the Linux routing table and then the forwarding decision for a destination, I'm seeing the control-plane output (the table) and the data-plane query (the lookup) on my own machine, BECAUSE even a single host separates 'the routes I know' from 'forward this specific packet.'"

```bash
# The control-plane artifact: the routing table (what the box "decided")
ip route show
# default via 192.168.1.1 dev eth0
# 10.244.0.0/16 dev cni0  proto kernel  scope link

# The data-plane query: "for THIS destination, what does the muscle do?"
ip route get 10.244.2.9
# 10.244.2.9 dev cni0 src 10.244.0.1   <- the forwarding decision, computed from the table
```

**Verify:** `ip route get` returns a concrete next-hop/interface derived from the table. The table is the decision; the `get` is the forward. Same split, one host.

### Example 2 — Edge case: watch the data plane keep working after the "controller" is paused

> **Prediction:** "If I already have an established Service connection and I disrupt kube-proxy's ability to push *new* rules, existing traffic keeps flowing, BECAUSE the rules are already installed in the kernel data plane and don't need the controller per-packet."

```bash
# Existing rules are in the kernel (data plane), independent of the kube-proxy process:
sudo iptables -t nat -L KUBE-SERVICES -n | head
# ... KUBE-SVC-XXXX ... 10.96.0.50 ... tcp dpt:80     <- installed, stays installed

# Even if kube-proxy is momentarily unavailable, an already-programmed ClusterIP
# still DNATs, because the KERNEL does the forwarding, not kube-proxy.
kubectl exec somepod -- curl -s -o /dev/null -w '%{http_code}\n' http://10.96.0.50:80
# 200
```

**Verify:** existing Service traffic still returns `200`. What you *lose* while the control plane is down is the ability to reflect *new* Services/endpoints — exactly the SDN resilience property. (Don't actually kill kube-proxy in prod; observe the principle.)

### Example 3 — Kubernetes-flavored: prove kube-proxy is the control plane, iptables is the data plane

> **Prediction:** "If I create a Service and then inspect iptables, I'll find rules that kube-proxy wrote but that the kernel enforces, BECAUSE kube-proxy is the brain that programmed the kernel muscle."

```bash
kubectl create deployment web --image=nginx --replicas=2
kubectl expose deployment web --port=80          # creates a ClusterIP Service
SVCIP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')

# The control plane (kube-proxy) has written data-plane rules for this VIP:
sudo iptables -t nat -L -n | grep "$SVCIP"
# KUBE-SVC-... tcp -- 0.0.0.0/0  <SVCIP>  tcp dpt:80
# The chain fans out to KUBE-SEP-... entries = the real pod IPs (DNAT targets).
```

**Verify:** iptables now contains chains referencing your Service's ClusterIP that you never wrote by hand — kube-proxy (control plane) generated them; the kernel (data plane) executes them. That's SDN inside your cluster.

---

## 🏔 Capstone — Compress It

**One sentence:** SDN separates the deciding brain (control plane) from the forwarding muscle (data plane) and makes the brain programmable via software, turning the network into something you configure with code — and this exact split is what powers your VPC, CNI, kube-proxy, and service mesh.

**Explain it to a beginner in 3 sentences:**
1. Old network gear mixed "decide where traffic goes" and "actually move the packets" into each box, configured one at a time by hand.
2. SDN pulls those apart: a central software controller decides and programs the rules, while dumb-fast forwarding elements just execute them.
3. That's why in Kubernetes you write one YAML and the network changes everywhere in seconds — a controller (kube-proxy, the CNI, istiod) reprogrammed the data plane for you.

**Sub-parts mapped to the one idea (decide centrally, forward dumbly):**
```
Control plane   → decides, programs rules (kube-proxy, CNI agent, istiod)
Data plane      → forwards packets (iptables/IPVS/eBPF, Envoy)
Controller/API  → where you declare intent as code
Cloud VPC       → SDN you rent
The recurring pattern → routers, kube-proxy, mesh, VPC are all this split
```

**Which rung to revisit hands-on:** Rung 5's trace and Rung 7 Example 3 — watching kube-proxy's rules appear in iptables makes "SDN inside Kubernetes" undeniable.

---

## Related concepts

- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — the clearest in-cluster control/data-plane split.
- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — the CNI controller programming the pod data plane.
- [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) — istiod (control) vs Envoy (data), the same shape at L7.
- [Routing & Forwarding](08-routing-and-forwarding.md) — routing table (control) vs forwarding table (data).
- [The AWS VPC](20-aws-vpc.md) — cloud networking that is SDN you rent.
- [Network Observability](32-network-observability.md) — eBPF as a programmable data plane you can also observe.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why can't a network of self-contained boxes — each configured by hand — support a cloud where thousands of virtual networks are created and destroyed per minute?

**A:** Because in the traditional model the brain and muscle are welded into each box, every change means logging into devices one at a time and typing CLI commands — a manual, per-box, error-prone process with no central place to declare "here is the network I want." A cloud creates and destroys virtual networks (and the VMs/pods behind them) faster than any human can touch a box, so hand configuration simply cannot keep up. There's also no global view or coordination, so per-box drift and silent holes are inevitable at that scale. Multi-tenant cloud networking is infeasible without a programmable, centrally driven control plane realizing changes everywhere in seconds.

### Before Rung 3
**Q:** In one breath — what does the control plane produce, and what does the data plane consume?

**A:** The control plane produces the rules — routes, flow rules, DNAT entries, policy — i.e. the decisions about how traffic should flow; the data plane consumes those installed rules to forward every packet at line rate. The brain decides once and pushes configuration; the muscle executes it per packet without ever asking the brain.

### Before Rung 4
**Q:** kube-proxy never sits in the packet path, yet it changes how Service traffic is delivered. Which plane is kube-proxy, and which plane actually forwards the packet?

**A:** kube-proxy is the control plane: it watches Services and Endpoints via the API server, computes the mapping (ClusterIP → pod IPs), and writes the rules. The data plane that actually forwards is the kernel — iptables (or IPVS/eBPF, depending on mode) performs the DNAT on every packet. That's why kube-proxy can be absent from the packet path yet still change delivery: it programmed the muscle once, and the kernel executes those installed rules for every packet thereafter.

### Before Rung 6
**Q:** In the Service trace, which steps happen once per *change*, and which step happens once per *packet*? Why does that division make the system both flexible and fast?

**A:** Steps 3–4 — kube-proxy watching the API, computing the ClusterIP-to-pod mapping, and writing the iptables/IPVS rules — run once per change (per Service/Endpoints update). Step 6 — the kernel data plane DNATing the packet to a real pod IP — runs once per packet, at line rate, with no controller involvement. This division is exactly what makes SDN both flexible and fast: the software brain can recompute and rewrite rules in seconds whenever you change intent (flexibility), while the per-packet work is done entirely by dumb-fast installed rules in the kernel (speed). It also gives resilience: if the controller dies, already-installed rules keep forwarding.
