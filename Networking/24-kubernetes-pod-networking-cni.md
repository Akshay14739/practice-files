# Kubernetes Pod Networking & CNI

*The four rules that make a pod feel like a tiny VM with its own IP — and the plug-in system that actually delivers them.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** The Kubernetes network model — its four non-negotiable rules — and the **CNI** (Container Network Interface) plugins (Flannel, Calico, Cilium, AWS VPC-CNI) that implement it.

**Why did it land on my desk?** This is *the* payoff chapter for a Kubernetes engineer. Every pod on your EKS cluster has its own IP; `kubectl get pod -o wide` shows a flat list of addresses; pods on different nodes reach each other directly. That "flat network" is not magic — it's a deliberate model plus a CNI plugin. When pods can't talk, when you hit IP exhaustion, when you choose Calico vs Cilium — you're living in this chapter.

**What do I already know?** You've seen Docker's per-host bridge and its limits ([23-container-docker-networking.md](23-container-docker-networking.md)), network namespaces ([../Linux/13-namespaces.md](../Linux/13-namespaces.md)), veth pairs, routing ([08-routing-and-forwarding.md](08-routing-and-forwarding.md)), and VXLAN overlays ([16-vlans-and-segmentation.md](16-vlans-and-segmentation.md)). Pod networking assembles all of them.

---

## 🔥 Rung 1 — The Pain

Docker's default networking ([23](23-container-docker-networking.md)) works on one host: containers share `docker0`, get NATed to reach out, and publish ports to be reached. But a cluster is **many hosts running thousands of churning pods**, and that model collapses:

- **Cross-host pods can't reach each other by IP.** `172.17.0.4` on node A means nothing on node B — both hosts reuse the same private bridge range.
- **NAT everywhere is a debugging nightmare.** If pod-to-pod traffic were NATed, a receiver would see a translated source, breaking identity, logging, and policy. "Who called me?" becomes unanswerable.
- **Port-publishing doesn't scale.** Tracking which `host:port` maps to which pod across a fleet is untenable.
- **Every runtime and cloud is different.** Kubernetes must run on AWS, GCP, bare metal, and your laptop — it can't hardcode one networking implementation.

Kubernetes' answer was to **specify the network behavior it requires** and let a pluggable component provide it. That contract is the pod network model; the plugin is CNI.

**Who feels it most?** The platform engineer who must guarantee "any pod can reach any pod" across a multi-node, multi-AZ cluster.

> **✅ Check yourself before Rung 2:** Why would NAT between pods (a receiver seeing a rewritten source IP) break things Kubernetes cares about, like network policy and audit logs?

---

## 💡 Rung 2 — The One Idea

Memorize this — the Kubernetes network model in one sentence:

> **Every pod gets its own unique, cluster-routable IP, and every pod can reach every other pod directly with no NAT — so a pod behaves like a little machine on one flat network, and a CNI plugin is the thing that makes that true on whatever infrastructure you run.**

The model is formally **four rules**:

1. Every **pod** has its own **unique IP**.
2. Every pod can reach **every other pod** across nodes **without NAT**.
3. Every **node** can reach every pod (and vice versa) without NAT.
4. The IP a pod **sees for itself** is the **same IP** others use to reach it (no translation surprises).

Everything else — Services, DNS, policies — is built *on top of* this flat foundation.

> **✅ Check yourself before Rung 3:** From the four rules alone, why can a pod on node A `curl` a pod on node B using nothing but that pod's IP — no port mapping, no gateway trick?

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> There are two levels here: roommates sharing one apartment, and apartments spread across a whole city.
>
> - **Inside a pod:** a pod is an apartment shared by a few roommates (containers). They share one street address and one phone line, so they talk to each other by just shouting across the room — that's "localhost." A tiny caretaker called the **pause container** does nothing except hold the lease: it keeps the apartment's address alive so roommates can move in and out (restart, upgrade) without the address ever changing.
> - **Across the cluster:** a helper program called the **CNI plugin** (think: the network installer the landlord calls) wires up every new apartment. It runs a cable from the apartment to its building's wiring closet (a "veth pair" — a two-ended virtual cable), and assigns the apartment an address from that building's block of the city plan (the "pod CIDR" — the range of addresses reserved for pods, carved up building by building). To let apartments in *different* buildings reach each other, installers use one of two strategies:
>   - **Overlay (encapsulation):** put the letter inside a second envelope addressed building-to-building (VXLAN or IP-in-IP — tunneling). The far building's mailroom opens the outer envelope and delivers the inner one. Works anywhere, costs a little extra handling.
>   - **Native routing:** teach the city's actual postal service the real routes (via BGP — the internet's route-sharing protocol) so letters travel directly with no extra envelope. Faster, but the postal service has to cooperate.
>
> - **CNI is just a contract:** when Kubernetes' building manager (the kubelet) creates a pod, it calls the installer with "ADD" (and "DEL" when the pod is torn down). The installer must do three things: run the cable, hand out an address from its address book (the "IPAM" module — IP address management, the ledger of who has which number), and set up the routes so every pod can reach every pod.
>
> - **The installer companies (plugins):** *Flannel* — simple envelope-in-envelope, just works. *Calico* — direct routing plus rule enforcement (network policies). *Cilium* — plants very fast little programs inside the operating system's core (eBPF) for speed and visibility. *AWS VPC-CNI* — Amazon's own installer.
>
> - **AWS's version is special:** instead of envelopes, it gives pods *real* addresses from the cloud's own street plan by attaching extra network cards (ENIs) to each machine and handing their spare addresses to pods. Pods become first-class citizens of the cloud network — but each machine has only so many address slots, so a busy cluster can literally run out ("IP exhaustion"). Handing out small address *blocks* instead of one-at-a-time (prefix delegation) eases the squeeze. That's why "we ran out of pod IPs" is a real incident you'll meet on EKS.

*Now the original technical deep-dive — the same ideas, in precise form:*

### Two levels: inside a pod, and across the cluster

**Inside a pod (container-to-container):** a pod is one or more containers **sharing a single network namespace**. That namespace is created and held by the tiny **pause (sandbox) container** — it exists solely to own the network (and IPC) namespace so app containers can come and go without losing the pod's IP. Containers in the same pod therefore share `localhost` and the same IP; they talk over `127.0.0.1`.

```
              ONE POD (on a node)
 ┌──────────────────────────────────────────┐
 │  network namespace (held by pause)        │
 │  IP 10.244.1.7   lo 127.0.0.1             │
 │  ┌──────────┐  ┌──────────┐  ┌─────────┐  │
 │  │  app     │  │ sidecar  │  │ pause   │  │
 │  │ :8080    │  │ :9090    │  │ (holds  │  │
 │  └────┬─────┘  └────┬─────┘  │  netns) │  │
 │       └── localhost ┘        └─────────┘  │
 │  eth0 (veth) ───────────────┐             │
 └─────────────────────────────┼─────────────┘
                               veth peer
                                │
                    ┌───────────┴──────────┐
                    │  node's CNI bridge / │
                    │  routing (cni0, etc.) │
                    └──────────────────────┘
```

**Across the cluster (pod-to-pod):** the CNI plugin gives each pod a `veth` pair — one end (`eth0`) in the pod, the other on the node — and assigns the pod an IP from the node's slice of the **pod CIDR**. Then the plugin makes pods on *other* nodes reachable, using one of two strategies:

- **Overlay (encapsulation):** wrap the pod's packet in an outer packet (VXLAN/IP-in-IP) addressed node-to-node; the destination node unwraps and delivers. Works anywhere, costs a little overhead. *Flannel (VXLAN), Calico (VXLAN/IPIP).*
- **Native / BGP routing (no encapsulation):** advertise each node's pod-CIDR as routes so the underlying network forwards pod packets directly. Faster, needs a cooperative network. *Calico (BGP).*

### CNI: the contract

**CNI** is a dead-simple spec. When the kubelet creates a pod, it calls the configured CNI binary with **ADD** (and **DEL** on teardown). The plugin must:

1. Create the pod's network namespace plumbing (`veth` pair).
2. Assign an IP via its **IPAM** (IP Address Management) module.
3. Program the routes so the pod is reachable per the four rules.

```
kubelet creates pod ──▶ calls CNI plugin: ADD
                          │  1. make veth pair (pod eth0 ↔ node)
                          │  2. IPAM: assign 10.244.1.7 from node's pod CIDR
                          │  3. add routes so cross-node pods are reachable
                          ▼
                     pod is now on the flat network
```

### The plugin landscape

| CNI | Datapath | Superpower |
|---|---|---|
| **Flannel** | VXLAN overlay | Simple, "just works" |
| **Calico** | BGP native routing (or VXLAN/IPIP) + policy | Performance + NetworkPolicy |
| **Cilium** | **eBPF** in the kernel | Fast, L7-aware, rich observability |
| **AWS VPC-CNI** | Real VPC IPs via ENIs | Pods are first-class VPC citizens |

**AWS VPC-CNI is special (and your daily reality on EKS):** instead of an overlay, it attaches secondary IPs from the VPC subnet to the node's **ENIs** (Elastic Network Interfaces) and hands those *real VPC IPs* to pods. Pods are routable inside the VPC with zero encapsulation — but each node can only hold so many IPs (bounded by ENI/IP limits per instance type), so a busy cluster can hit **IP exhaustion**. Prefix delegation (assigning /28 prefixes instead of single IPs) mitigates it. This is why "we ran out of pod IPs" is an EKS-specific incident you'll meet.

> **✅ Check yourself before Rung 4:** Two containers in the *same* pod share an IP and talk over localhost; two pods on *different* nodes each have their own IP and need the CNI to route between them. What single object makes the same-pod containers share that one network namespace?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Pod network model** | The four rules (unique IP, no-NAT pod-to-pod, node-to-pod, consistent IP) | The contract |
| **CNI** | The plugin spec kubelet calls (ADD/DEL) to wire a pod | How the model is implemented |
| **CNI plugin** | Flannel/Calico/Cilium/VPC-CNI | The implementation |
| **IPAM** | Assigns pod IPs from the pod CIDR | Step 2 of CNI ADD |
| **Pod CIDR** | The IP range pods are allocated from | Where pod IPs come from |
| **pause / sandbox container** | Tiny container holding the pod's netns | Why same-pod containers share an IP |
| **veth pair** | Virtual cable: pod eth0 ↔ node | Connects pod to node |
| **Overlay (VXLAN/IPIP)** | Encapsulate pod packets node-to-node | Cross-node reachability (one way) |
| **BGP native routing** | Advertise pod-CIDR routes, no encap | Cross-node reachability (faster way) |
| **eBPF** | Programmable kernel datapath | Cilium's engine |
| **ENI** | AWS Elastic Network Interface | Where VPC-CNI gets pod IPs |

**Same-kind-of-thing groupings:** *CNI plugin, Flannel, Calico, Cilium, VPC-CNI* are all "the thing that wires pods." *Overlay and BGP routing* are two answers to the same question: "how does a pod on node A reach node B?" *pause container, held network namespace* are why "a pod has one IP" even with many containers.

---

## 🔬 Rung 5 — The Trace

**A pod on node A (`10.244.1.7`) sends a request to a pod on node B (`10.244.2.9`), using a VXLAN-overlay CNI like Flannel.**

```
[app in pod-A, node A]  10.244.1.7 → 10.244.2.9:8080
  │ 1. pod's routing table: default route via eth0 (veth) to the node
  ▼
[node A kernel / cni bridge]
  │ 2. node A knows 10.244.2.0/24 lives on node B (route the CNI installed)
  │ 3. OVERLAY: wrap the pod packet in a VXLAN packet:
  │       outer src=nodeA_ip  outer dst=nodeB_ip  (real VPC/underlay IPs)
  ▼
[underlay network: VPC, real node IPs, real routing] ── 08 / 20
  │ 4. delivered node-to-node like any normal packet
  ▼
[node B kernel]
  │ 5. DECAPSULATE the VXLAN → recover inner packet (dst 10.244.2.9)
  │ 6. deliver over veth into pod-B's namespace
  ▼
[app in pod-B]  receives from source 10.244.1.7  ← the REAL pod IP, NO NAT (rule 2 & 4)
```

Notice step 6: pod-B sees the *actual* source `10.244.1.7`, not a translated address — that's rule 2 (no NAT) and rule 4 (consistent IP), and it's why NetworkPolicy ([28](28-kubernetes-network-policies.md)) and audit logs can trust the source. With **VPC-CNI** or **Calico BGP**, steps 3/5 vanish — the pod IPs are natively routable, so no wrap/unwrap.

> **✅ Check yourself before Rung 6:** In that trace, which two source-IP properties would break if the CNI used NAT between nodes — and which rules do they correspond to?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: Docker's per-host bridge with NAT and port publishing.**

| Property | Docker bridge | Kubernetes + CNI |
|---|---|---|
| Pod/container IP | Host-local, NATed | Cluster-routable, unique |
| Pod-to-pod cross host | ❌ (or overlay+publish) | ✅ direct, no NAT |
| Who wires it | Docker (fixed) | Pluggable CNI (choose one) |
| Source IP preserved | ❌ (NATed) | ✅ (rule 2 & 4) |
| Enforce policy on identity | Hard | NetworkPolicy on real IPs/labels |

**Overlay vs native routing (a contrast *within* CNI):**

| | Overlay (Flannel VXLAN) | Native/BGP (Calico, VPC-CNI) |
|---|---|---|
| Encapsulation | Yes (wrap/unwrap) | No |
| Works on any network | ✅ | Needs routable underlay |
| Overhead / MTU cost | Higher | Lower |
| Debuggability | Packets are wrapped | Pod IPs visible on the wire |

**When would I NOT use a heavy CNI?** On a single-node kind/minikube dev cluster, a simple CNI (or the default) is plenty; you don't need Calico's BGP or Cilium's eBPF until you want NetworkPolicy, scale, or L7 observability.

**One-sentence why-this-over-that:** *Use a CNI (overlay for portability, native/BGP or VPC-CNI for performance) because Kubernetes requires a flat, NAT-free, cross-node pod network that Docker's bridge can't provide.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: every pod has a unique, cross-node-reachable IP

> **Prediction:** "If I list pods with `-o wide` and curl one pod's IP from another pod on a *different node*, it works with no port mapping, BECAUSE the CNI put every pod on one flat, routable network (rules 1 & 2)."

```bash
kubectl create deployment web --image=nginx --replicas=3
kubectl get pods -o wide
# NAME        READY  IP            NODE
# web-xxx-a   1/1    10.244.1.7    node-1
# web-xxx-b   1/1    10.244.2.9    node-2     <- different node, different pod-CIDR slice
# web-xxx-c   1/1    10.244.1.8    node-1

# From an unrelated pod, curl pod-b's IP directly (no Service, no port publish):
kubectl run probe --rm -it --image=busybox --restart=Never -- \
  wget -qO- --timeout=3 http://10.244.2.9:80 | head -1
# <!DOCTYPE html>   <- reached a pod on another node by raw IP
```

**Verify:** the raw pod IP on another node responds. If it hangs, the CNI's cross-node routing/overlay is broken — the classic "pods on node X can't reach node Y" CNI/security-group problem.

### Example 2 — Edge case: containers in one pod share an IP and localhost

> **Prediction:** "If I put two containers in one pod, they share the same IP and one can reach the other over `localhost`, BECAUSE the pause container holds a single network namespace they both join."

```yaml
# shared-netns.yaml
apiVersion: v1
kind: Pod
metadata: { name: two-c }
spec:
  containers:
  - { name: web, image: nginx }                 # listens on :80
  - { name: shell, image: busybox, command: ["sleep","3600"] }
```

```bash
kubectl apply -f shared-netns.yaml
# The sidecar reaches the web container via localhost — same netns:
kubectl exec two-c -c shell -- wget -qO- --timeout=3 http://localhost:80 | head -1
# <!DOCTYPE html>
# Both containers report the SAME pod IP:
kubectl get pod two-c -o jsonpath='{.status.podIP}{"\n"}'
# 10.244.1.12
```

**Verify:** the sidecar reaches nginx on `localhost` and both see one pod IP. That only works because of the shared (pause-held) network namespace — the defining trait of a pod.

### Example 3 — EKS-flavored: VPC-CNI gives pods real VPC IPs (and can exhaust them)

> **Prediction:** "On EKS with the AWS VPC-CNI, a pod's IP is a real address from the node's VPC subnet (not an overlay range), BECAUSE VPC-CNI attaches subnet IPs to the node's ENIs and hands them to pods — which also means a small subnet can run out of pod IPs."

```bash
# On EKS: pod IPs fall INSIDE the VPC subnet CIDR, e.g. 10.0.3.x — not a 10.244/overlay range
kubectl get pods -o wide | awk 'NR==1 || /Running/ {print $1, $6, $7}'
# web-xxx   10.0.3.altitude   ip-10-0-3-15.ec2.internal

# The node advertises how many pod IPs it can still hand out (ENI/IP budget):
kubectl get node ip-10-0-3-15.ec2.internal -o jsonpath='{.status.allocatable.pods}{"\n"}'
# 29     <- instance-type-bound; hit this and new pods get stuck "ContainerCreating" (no IPs)
```

**Verify:** pod IPs are inside your VPC subnet range and the node reports a finite `allocatable.pods`. If pods stick in `ContainerCreating` with `failed to assign an IP address` events, you've hit VPC-CNI IP exhaustion — the fix is bigger subnets or prefix delegation, an EKS-specific gotcha overlay CNIs don't have.

---

## 🏔 Capstone — Compress It

**One sentence:** Kubernetes requires that every pod have its own unique, cluster-routable IP and reach every other pod with no NAT, and a CNI plugin (Flannel overlay, Calico BGP, Cilium eBPF, or AWS VPC-CNI's real VPC IPs) is what wires each pod's veth, assigns its IP, and routes between nodes to make that flat network real.

**Explain it to a beginner in 3 sentences:**
1. Kubernetes insists every pod acts like its own little machine with a unique IP that any other pod can reach directly, with no address translation in between.
2. It doesn't implement that itself — it calls a plug-in (the CNI) that, whenever a pod starts, gives it a virtual network cable, assigns it an IP, and sets up routing so pods on different nodes can find each other.
3. Different plugins do the "reach other nodes" part differently — overlays wrap packets (Flannel), native routing advertises routes (Calico), and on EKS the AWS VPC-CNI just hands pods real VPC IP addresses.

**Sub-parts mapped to the one idea (flat network, delivered by a plugin):**
```
Rule 1: unique pod IP        → CNI IPAM assigns from pod CIDR
Rule 2: pod-to-pod no NAT    → CNI routes/overlays between nodes
Rule 3: node-to-pod          → node routes into pod CIDR
Rule 4: consistent IP        → no translation; source preserved
same-pod containers          → share one netns via the pause container
overlay vs BGP vs VPC-CNI    → three ways to satisfy Rule 2
```

**Which rung to revisit hands-on:** Rung 7 Example 1 — curling a pod on another node by raw IP is the moment "flat pod network" stops being a slogan.

---

## Related concepts

- [Container & Docker Networking](23-container-docker-networking.md) — the per-host model this flat network replaces.
- [Linux Namespaces](../Linux/13-namespaces.md) — the network namespace (and the pause container that holds it).
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — stable VIPs built on top of ephemeral pod IPs.
- [VLANs & Segmentation](16-vlans-and-segmentation.md) — VXLAN, the encapsulation overlays use.
- [Routing & Forwarding](08-routing-and-forwarding.md) — BGP native routing and node routes for pod CIDRs.
- [Kubernetes Network Policies](28-kubernetes-network-policies.md) — why preserving the real pod source IP matters.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why would NAT between pods (a receiver seeing a rewritten source IP) break things Kubernetes cares about, like network policy and audit logs?

**A:** Because NAT destroys the caller's identity. If pod-to-pod traffic were translated, the receiving pod would see some rewritten source address (e.g. the node's IP) instead of the real pod IP, so "who called me?" becomes unanswerable. NetworkPolicy decides allow/deny based on who the source actually is — with a translated source it could no longer match traffic to the real originating pod. Audit logs and observability suffer the same way: every entry would show the translator's address, not the workload that made the request. That's why the model demands no NAT between pods and a consistent, preserved source IP.

### Before Rung 3
**Q:** From the four rules alone, why can a pod on node A `curl` a pod on node B using nothing but that pod's IP — no port mapping, no gateway trick?

**A:** Rule 1 says the destination pod has its own unique, cluster-routable IP, so that address is unambiguous across the whole cluster — no two pods share it and no host-local reuse exists. Rule 2 says every pod can reach every other pod across nodes without NAT, so the network (as wired by the CNI) will deliver a packet addressed to that pod IP directly, with no translation in between. Rule 4 guarantees the IP the pod sees for itself is the same IP others use to reach it, so there are no translation surprises. Together the rules make each pod behave like a little machine on one flat network — so a raw `curl http://<pod-ip>:<port>` just works, no port publishing or gateway trick required.

### Before Rung 4
**Q:** What single object makes the same-pod containers share that one network namespace?

**A:** The pause (sandbox) container. It's a tiny container whose only job is to create and hold the pod's network (and IPC) namespace; every app container in the pod joins that namespace rather than getting its own. That's why all containers in a pod share one IP and one `localhost`, and why app containers can crash and restart without the pod losing its IP — the pause container keeps the namespace alive.

### Before Rung 6
**Q:** In the trace, which two source-IP properties would break if the CNI used NAT between nodes — and which rules do they correspond to?

**A:** First, pod-B would no longer receive the packet from the real source `10.244.1.7` — it would see a translated address (e.g. node A's IP), breaking rule 2 (every pod reaches every other pod without NAT). Second, pod-A's IP as seen by others would differ from the IP pod-A sees for itself, breaking rule 4 (the IP a pod sees for itself is the same IP others use to reach it). Losing those two properties is exactly what would break NetworkPolicy and audit logs, since both depend on trusting the real pod source IP on the wire.
