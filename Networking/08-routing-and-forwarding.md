# Routing & Forwarding

*How a packet with no map finds its way across a dozen strangers' networks — and how your cluster does the exact same thing.*

---

## 🧗 Rung 0 — The Setup

**What am I learning?**

You're learning how a packet gets from *here* to *there* when "there" is not on your local wire. Two words do all the work, and they are not synonyms:

- **Routing** — the *thinking*: building and maintaining a map of which networks exist and how to reach them. Slow, occasional, control-plane work.
- **Forwarding** — the *doing*: for this one packet arriving right now, punch out the correct exit port as fast as physically possible. Fast, per-packet, data-plane work.

A **router** is a device with an interface in two or more networks that moves packets between them, choosing the path using the **network portion** of the destination IP address (not the host portion — it doesn't care *which* machine, only *which network* first).

**Why did it land on your desk?**

You're a platform engineer on EKS. A pod on Node A cannot reach a pod on Node B. `kubectl exec` into the source pod, `curl` the target pod IP, and it hangs. DNS is fine, the target pod is `Running`, `NetworkPolicy` is empty. The AWS console shows both nodes healthy. Someone says "it's a routing issue" and everyone nods gravely and no one moves.

Here's the thing: **a Kubernetes node is a router.** It has a route for the pod CIDR. The CNI installed it. The VPC route table either knows about your pod CIDR or it doesn't. When pod-to-pod across nodes breaks, you are debugging *exactly* the mechanism in this file — routing tables, next-hops, and TTL — just wearing Kubernetes clothes. This concept is not "networking trivia you delegated to the CNI." It *is* the CNI.

**What do I already know already (the ladder so far)?**

- **[IP addressing](02-ip-addressing.md)** — every host has an IP; there are public and private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
- **[Subnetting & CIDR](03-subnetting-and-cidr.md)** — a prefix like `/24` splits an address into a **network part** and a **host part**. Routing lives and dies on this split.
- **[MAC / switching / ARP](05-mac-addresses-switching-arp.md)** — a switch moves frames *inside* one network using MAC addresses. A router moves packets *between* networks using IP.
- **[OSI / TCP-IP models](06-osi-and-tcpip-models.md)** — routing is a **Layer 3** job. Switching is Layer 2. That one-layer difference is the whole story.

Hold those. We build straight up from them.

---

## 🔥 Rung 1 — The Pain

Picture the world with switching but no routing. A switch is brilliant *within* one broadcast domain: it learns MAC addresses and floods what it doesn't know. But a switch has **no concept of "another network."** Its map is a flat table of MACs on wires it can physically see.

Now you have two offices:

```
Office A: 10.0.1.0/24        Office B: 10.0.2.0/24
  host 10.0.1.50               host 10.0.2.80
```

Host `10.0.1.50` wants to reach `10.0.2.80`. It ARPs for `10.0.2.80`'s MAC and... silence. ARP is a **broadcast**, and broadcasts do not cross into another network. The two offices are on different wires with different network numbers. The switch in Office A has never seen `10.0.2.80` and never will. **The packet has nowhere to go and dies on the source's doorstep.**

**What people did before, and why it hurt:**

- **One giant flat network.** Just put everyone in `10.0.0.0/8` and let switches flood. This "works" until it catastrophically doesn't: every ARP, every broadcast, every unknown-unicast flood hits *every* machine. This is a **broadcast storm** waiting to happen. A flat network of 10,000 hosts spends its bandwidth screaming "WHO HAS 10.4.2.9?" into the void. It does not scale past a building.
- **Manual bridging everywhere.** Chain switches until the physics collapses. No hierarchy, no summarization, no fault isolation. One loop and the whole thing melts (this is literally why Spanning Tree Protocol had to be invented).

**What breaks without routing:**

- No internet. The internet is ~75,000 independent networks (autonomous systems). You cannot flat-switch the planet.
- No VPC. AWS gives you `10.0.0.0/16` and lets you carve subnets. The moment you have two subnets, something must *route* between them. That something is the VPC router (an implicit thing at `.1` of your VPC, technically the "VPC router").
- **No cross-node pods.** Each Kubernetes node owns a slice of the pod CIDR (say Node A = `10.244.1.0/24`, Node B = `10.244.2.0/24`). Pod-to-pod across nodes is *routing between two networks*, full stop. Without it, your Service abstraction is a lie — the endpoints behind a ClusterIP are scattered across nodes you can't reach.

**Who feels the pain most?** The platform engineer at 2 a.m. whose "flat and simple" cluster network just hit a broadcast wall, and who now discovers that "the CNI handles it" was never an explanation — it was a deferral.

> **Check yourself before Rung 2:** A switch floods a frame to every port when it doesn't know the destination MAC. Why can't a router just "flood a packet to every network when it doesn't know the destination IP"? What would that cost, and what fact about IP addresses makes a smarter choice possible?

---

## 💡 Rung 2 — The One Idea

Memorize this sentence. Write it on a sticky note. Everything else in this file is a corollary of it:

> **A router forwards a packet by matching its destination IP's *network portion* against a table of known networks, sending it one hop closer to the *longest-matching* network, and trusting the next router to repeat the process.**

Read it again. Now watch the entire concept fall out of it:

- **"network portion"** → routing is done on **prefixes** (`10.0.2.0/24`), never on whole host addresses. This is why CIDR ([Rung 3](03-subnetting-and-cidr.md)) is the beating heart of routing.
- **"table of known networks"** → that table is the **routing table**. It must be *built* — statically (you type it) or dynamically (a protocol learns it). Hence static vs dynamic routing, OSPF, BGP.
- **"longest-matching"** → when two routes both match, the **more specific** prefix (bigger prefix number) wins. `/32` beats `/24` beats `/0`. This one rule is how a **default gateway** (`0.0.0.0/0`, matches *everything* but only barely) coexists with specific routes.
- **"one hop closer"** → no router knows the whole path. Each knows only the *next* router. This is **hop-by-hop forwarding**.
- **"trusting the next router to repeat"** → forwarding is a distributed relay of local decisions. Which means loops are possible, which is *why* **TTL** exists to kill packets that circle forever.

If you ever forget how routing works, re-derive it from that sentence. It genuinely all comes from there.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> **Planning a trip vs. actually driving.** A router (a box that passes internet traffic toward its destination) keeps **two** lists, not one. The first is like a road atlas spread on the kitchen table — every possible route, with notes comparing them. The second is a single cheat-sheet taped to the steering wheel: "Going to Chicago? Take exit 12." Planning happens rarely and slowly; driving happens millions of times a second and must be instant. That split — plan once, then just drive — is why routers are fast.
>
> **What's on the cheat-sheet.** Each line says: "for addresses in this neighborhood, hand the package to *that* neighbor, out *that* door." Three kinds of lines: places on my own street (deliver directly), a catch-all line ("anything I don't recognize goes to the main post office" — the *default gateway*), and specific routes someone taught me.
>
> **When several lines match, the most specific wins.** If one line covers "all of Illinois" and another covers "this exact block in Chicago," the block-level line wins. That's the one selection rule everything obeys.
>
> **Who fills in the lists?** Either a human types the routes by hand (simple, but if a road closes, nobody updates the sign), or the routers *talk to each other* and re-plan automatically when roads fail. Inside one organization they chat to find the genuinely fastest path; *between* organizations (internet providers, Google, Amazon) they use one worldwide protocol called **BGP**, which picks paths based on business deals as much as speed — like shipping companies choosing partners by contract, not just distance. Surprisingly, the same BGP that connects the world's providers is also used *inside* some Kubernetes clusters (server groups running apps) to connect their pieces.
>
> **How the "fastest path" is found.** Under the hood it's a classic map-puzzle: either every router learns the whole map and computes shortest paths itself, or each one just asks its neighbors "how far is X for you?" and adds its own step.
>
> **The runaway-package safeguard.** Because each router decides only the *next* hop, a mistake could send a package in circles forever. So every package carries a countdown number; each router subtracts one, and at zero the package is destroyed and a "your package died here" note goes back to the sender. That note is exactly what the *traceroute* diagnostic tool uses to map a path.
>
> **In Kubernetes:** each server's built-in route list says "my own pods are local; that other machine's pods — hand packages to that machine." That one idea is the whole cross-machine story.

*Now the original technical deep-dive — the same ideas, in precise form:*

### 3.1 Two tables, not one: RIB vs FIB

The single most common confusion is treating "routing table" and "forwarding table" as the same thing. They are two different structures with two different jobs, and understanding the split explains *why* routers are fast.

- **Routing table (RIB — Routing Information Base):** *all known routes to a network*, possibly several per destination, each with metadata: which protocol taught it, its administrative distance, its metric/cost, whether it's still valid. This is the **control plane's** working notebook. It can be big and messy. It changes when the network topology changes.

- **Forwarding table (FIB — Forwarding Information Base):** the **chosen** best next-hop per destination prefix, pre-computed and optimized for one thing — *speed*. No deliberation, no comparing metrics. Just: "destination matches this prefix → shove it out that interface toward that next-hop MAC." This is the **data plane**. In real hardware routers it lives in specialized memory (TCAM) so a lookup happens in nanoseconds at line rate.

```
          CONTROL PLANE (thinks, occasionally)
   ┌───────────────────────────────────────────────┐
   │  Routing protocols: OSPF, BGP, static config   │
   │            │  learn many possible routes        │
   │            ▼                                     │
   │      ┌───────────────┐   "best route" selection │
   │      │  RIB (routing │   by admin-distance,     │
   │      │     table)    │   then metric            │
   │      └───────┬───────┘                          │
   └──────────────┼──────────────────────────────────┘
                  │ install winners
                  ▼
   ┌───────────────────────────────────────────────┐
   │      ┌───────────────┐                          │
   │      │  FIB (fwding  │  ← per-packet lookups    │
   │      │    table)     │    happen HERE, fast     │
   │      └───────┬───────┘                          │
   │            ▲ │                                   │
   │   packet ──┘ └──▶ out interface eth1, next-hop  │
   │            DATA PLANE (does, millions/sec)      │
   └───────────────────────────────────────────────┘
```

**The analogy:** The RIB is the whole atlas with every possible route to Chicago sprawled across the kitchen table, sticky notes comparing tolls and traffic. The FIB is the one turn-by-turn instruction taped to your steering wheel: "Chicago? Take exit 12." You do not re-plan at every intersection — that would be insane. You *planned once* (routing) and now you *just drive* (forwarding).

Why split them? Because **thinking is slow and doing must be fast.** A backbone router forwards tens of millions of packets per second. It cannot run Dijkstra per packet. So it thinks rarely (updates the FIB when topology changes) and forwards constantly (reads the FIB).

### 3.2 What's actually *in* a routing table

Every entry is essentially: **`destination-prefix → (next-hop, exit-interface, metric)`**.

```
Destination        Next-Hop        Interface   Metric   Source
0.0.0.0/0          192.168.1.1     eth0        default  ← DEFAULT GATEWAY
10.0.2.0/24        10.0.9.2        eth1        20       OSPF
10.0.1.0/24        0.0.0.0         eth0        0        directly connected
203.0.113.0/24     198.51.100.7    eth2        100      BGP
```

Three flavors of entry to recognize:

1. **Directly connected** — "this network is on a wire I'm literally plugged into." Next-hop is "self"; just ARP for the final host and deliver. No routing needed *between* networks here.
2. **The default gateway** — the `0.0.0.0/0` route. It matches *any* destination (prefix length 0 = zero bits must match). It's the "I have no specific idea, send it to my upstream and let them figure it out" route. Your laptop has exactly one useful route most of the time: the default gateway to your home router. **A pod is the same** — its whole routing table is basically "default via my veth gateway."
3. **Learned routes** — specific prefixes taught by static config or a routing protocol.

### 3.3 Longest-prefix match: the selection rule

When a packet's destination matches multiple entries, the router picks the **longest prefix** (most specific). Given destination `10.0.2.80`:

```
0.0.0.0/0      matches (0 bits must agree)      ← least specific
10.0.0.0/16    matches (16 bits agree)
10.0.2.0/24    matches (24 bits agree)          ← WINNER: longest
```

`10.0.2.0/24` wins because 24 > 16 > 0. This is why you can have a broad default route *and* pin specific destinations elsewhere — the specific one always overrides. Every VPC route table, every node route table, every `ip route` output obeys this one rule.

### 3.4 Static vs dynamic routing

**How does the table get populated?**

- **Static routing** — a human types the routes. `ip route add 10.0.2.0/24 via 10.0.9.2`. Simple, predictable, zero protocol overhead, no CPU. But: does not adapt. If the path dies, the static route happily points at a black hole until a human fixes it. Great for small, stable topologies and stub networks. **A VPC route table is static routing** — you (or the AWS control plane) declare `0.0.0.0/0 → nat-gateway`, and it doesn't reconverge on its own.

- **Dynamic routing** — routers *talk to each other* using a routing protocol, exchange what they know, and recompute paths automatically when links fail. Adapts, scales, self-heals. Costs CPU, memory, and complexity. This is how the internet and large datacenters survive.

Dynamic protocols split into two families by *scope*:

- **IGP (Interior Gateway Protocol)** — routing *within* one administrative domain (one company, one AS). Optimizes for the *best technical path*: lowest latency/cost. Example: **OSPF** (Open Shortest Path First), which builds a full map of the domain and runs **Dijkstra's shortest-path algorithm** to find least-cost routes.
- **EGP (Exterior Gateway Protocol)** — routing *between* independent domains. Optimizes for *policy* (business relationships, who pays whom), not raw speed. There is exactly one that matters: **BGP** (Border Gateway Protocol).

### 3.5 BGP — the protocol that stitches the internet together

The internet is a mesh of **Autonomous Systems (AS)** — a network under one administrative control, each with a number (ASN), e.g. AS15169 is Google, AS16509 is Amazon. BGP is how one AS tells its neighbors "here are the prefixes I can reach, and the AS-path to get there." Each AS then picks a **best path** per prefix, weighing policy first (prefer customer routes, avoid expensive transit) and AS-path length second.

```
   AS64500 (your ISP) ──BGP──▶ AS16509 (AWS)
        │  "I can reach 203.0.113.0/24 via path [64500]"
        │
        ▼
   AS15169 (Google)   "to reach 8.8.8.0/24, path is [15169]"
```

BGP is **path-vector**: it advertises the *entire AS-path* to a prefix (which prevents loops — if an AS sees itself already in the path, it rejects the route). It uses a distance-vector-flavored algorithm (Bellman-Ford lineage) rather than building a global map, because no ISP wants to expose its internal topology to competitors and no single router could hold a map of the whole internet.

**The cloud/Kubernetes tie-in that makes BGP suddenly personal:**

- **AWS runs BGP** to peer with the internet and with your **Direct Connect** / VPN links. When you advertise your on-prem prefixes over Direct Connect, that's BGP.
- **Calico** — a Kubernetes CNI — literally runs BGP *inside your cluster*. Each node becomes a BGP speaker and *announces the pod routes it owns* ("I, Node B, can reach `10.244.2.0/24`") to the other nodes (or to a route reflector). The same protocol that glues Comcast to Google glues your pods together. That's not an analogy — it is the identical protocol (often BIRD as the BGP daemon).

### 3.6 The shortest-path idea: Dijkstra & Bellman-Ford

Under every dynamic protocol is a graph algorithm. Model the network as a **graph**: routers are nodes, links are edges, edge weights are costs (bandwidth, latency, admin cost).

- **Dijkstra's algorithm** (used by **link-state** protocols like OSPF): each router learns the *entire* topology (every router floods its link-state), then independently computes the shortest-path *tree* from itself to every destination. Fast convergence, needs a full map, more memory/CPU.
- **Bellman-Ford** (used by **distance-vector** protocols like RIP, and conceptually BGP's path selection): a router only knows *its neighbors' distances* to destinations ("routing by rumor") and iteratively relaxes: "my cost to X = min over neighbors of (cost-to-neighbor + neighbor's-cost-to-X)." No full map needed; converges more slowly and historically suffered count-to-infinity loops.

You will almost never implement these. But knowing they're there demystifies "how did OSPF pick this path?" — it ran Dijkstra on a weighted graph, same as your CS class.

### 3.7 TTL / hop-limit — the loop killer

Hop-by-hop forwarding is a chain of *local* decisions by routers that don't see the whole path. That means a misconfiguration can create a **loop**: R1 → R2 → R3 → R1 → … forever. Without a safety valve, one looped packet circulates until the heat death of the router.

The safety valve is **TTL (Time To Live)** in IPv4 — an 8-bit field in the IP header, renamed **Hop Limit** in IPv6 but doing the identical job:

- The sender sets TTL to some initial value (Linux default **64**, Windows 128, many network devices 255).
- **Every router that forwards the packet decrements TTL by 1.**
- **When a router decrements TTL to 0, it drops the packet** and sends back an **ICMP Time Exceeded (Type 11)** message to the source.

```
   src TTL=64 ──▶ R1(63) ──▶ R2(62) ──▶ R3(61) ──▶ ... ──▶ dst
                                              │
        looped packet:  R1(3)─▶R2(2)─▶R3(1)─▶R1(0) ✂ DROP + ICMP Time Exceeded
```

TTL guarantees a packet visits *at most* its initial-TTL routers before dying. A loop can now only spin a bounded number of times. And — beautifully — this drop-and-notify behavior is exactly what **traceroute** exploits (Rung 5). TTL is both the safety mechanism *and* the diagnostic hook.

> Note: TTL counts **routing hops (L3)**, not switches. A frame crossing three switches inside one subnet does not decrement TTL — switches are L2 and never touch the IP header. Only routers do.

### 3.8 Putting it in a Kubernetes node

A node has a Linux kernel that *is* a router (IP forwarding enabled: `net.ipv4.ip_forward=1`). Its routing table is what makes pods reachable:

```
# On an EKS node, roughly (Flannel-style host-gw for clarity):
default        via 10.0.1.1    dev eth0        # node's default gateway → VPC router
10.0.1.0/24    dev eth0        scope link      # node's own subnet, directly connected
10.244.1.0/24  dev cni0        scope link      # pods ON THIS node → local bridge
10.244.2.0/24  via 10.0.1.12   dev eth0        # pods on Node B → route via Node B's IP
10.244.3.0/24  via 10.0.1.13   dev eth0        # pods on Node C → route via Node C's IP
```

That fourth and fifth lines are the entire "how do cross-node pods talk" story: **a route per remote pod CIDR, next-hop = the node that owns it.** Flannel host-gw *adds these routes*; Calico *announces them via BGP*; AWS VPC-CNI sidesteps the overlay by giving pods real VPC IPs so the VPC route table does the job. Three mechanisms, one idea from Rung 2.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Router** | A device with interfaces in ≥2 networks that forwards packets between them at L3 | The box doing the forwarding; a K8s node is one |
| **Routing** | Control-plane act of *building* the map of reachable networks | Populates the RIB |
| **Forwarding** | Data-plane act of moving *this* packet out the right port, fast | Reads the FIB, per-packet |
| **Routing table (RIB)** | *All* known routes to each network, with metadata | Control plane's notebook |
| **Forwarding table (FIB)** | The *chosen* best next-hop per prefix, speed-optimized (TCAM) | Data plane's cheat sheet |
| **Default gateway** | The `0.0.0.0/0` route — matches everything, lowest priority | A RIB/FIB entry; a pod's whole world |
| **Next-hop** | The IP of the *next* router to hand the packet to | Per-route field; hop-by-hop relay |
| **Directly connected** | A network on a wire the router is physically on | Route with next-hop = self |
| **Longest-prefix match** | Selection rule: most-specific prefix wins | How FIB lookup resolves ties |
| **Hop-by-hop** | Each router decides only the *next* hop, not the whole path | The distributed forwarding model |
| **Static routing** | Human-entered routes; no adaptation | VPC route tables; small stubs |
| **Dynamic routing** | Routers exchange reachability via a protocol; self-healing | OSPF, BGP populate RIB |
| **IGP** | Interior Gateway Protocol — routing *within* one AS | OSPF; optimizes technical cost |
| **OSPF** | Link-state IGP; floods topology, runs Dijkstra | Builds intra-AS shortest paths |
| **EGP** | Exterior Gateway Protocol — routing *between* AS | BGP; optimizes policy |
| **BGP** | Path-vector protocol stitching autonomous systems | Internet backbone; Calico pod routes |
| **Autonomous System (AS)** | A network under one admin control, with an ASN | The unit BGP routes between |
| **TTL / Hop Limit** | Header counter decremented per hop; drop at 0 | Loop prevention + traceroute hook |
| **ICMP Time Exceeded (Type 11)** | Message sent when TTL hits 0 | How the source learns of the drop |
| **Dijkstra** | Shortest-path-tree algorithm on a full graph | Under OSPF (link-state) |
| **Bellman-Ford** | Distance-relaxation algorithm using neighbor rumors | Under RIP; BGP path-vector lineage |
| **Administrative distance** | Trust ranking between route *sources* (which protocol to believe) | RIB → FIB selection tiebreak |
| **Metric / cost** | Preference *within* one protocol (lower = better) | RIB → FIB selection |
| **traceroute** | Tool that maps hops by abusing TTL expiry | Diagnostic use of TTL |

**"Same kind of thing wearing different names":**

- **RIB = routing table**; **FIB = forwarding table**. Same pair, two names each. Control-plane notebook vs data-plane cheat sheet.
- **TTL (IPv4) = Hop Limit (IPv6)** — identical mechanism, different header name.
- **IGP ≈ "inside" routing (OSPF)**; **EGP ≈ "between" routing (BGP)** — the *scope* is the difference, not the fundamentals.
- **Default gateway = `0.0.0.0/0` route = "the route of last resort"** — three names for the catch-all.
- **Dynamic routing protocol ⊇ {link-state (Dijkstra), distance-vector (Bellman-Ford), path-vector (BGP)}** — all "routers gossip and compute," differing in *what* they gossip.
- **Static route ≈ VPC route-table entry ≈ `ip route add` line** — a hand-declared prefix→next-hop, wherever it appears.

---

## 🔬 Rung 5 — The Trace

Let's follow one packet from your pod to `google.com`'s server, end to end. Assume DNS already resolved to `142.250.72.0`-ish (we cover that in [DNS](09-dns.md)); here we care only about *getting the packet there*.

**Actors:** Pod (`10.244.1.5`) → veth → Node A (`10.0.1.11`) → VPC router → NAT Gateway → IGW → ISP router(s) → Google's edge → Google server.

```
STEP 1                STEP 2               STEP 3            STEP 4
┌────────┐  default   ┌────────┐  no local ┌──────────┐ SNAT ┌──────────┐
│  POD   │───route───▶│ NODE A │──route,───│VPC ROUTER│─────▶│NAT GATEWAY│
│10.244. │  via veth  │ (a     │  send to  │0.0.0.0/0 │      │masquerade │
│  1.5   │  gateway   │ router)│  default  │→ nat-gw  │      │to node IP │
└────────┘  TTL=64    └────────┘  TTL=63   └──────────┘      └────┬─────┘
                                                                   │TTL=62
                                     STEP 7        STEP 6          ▼ STEP 5
                                ┌─────────┐   ┌─────────┐    ┌──────────┐
              google server ◀───│ GOOGLE  │◀──│  ISP    │◀───│   IGW    │
              142.250.72.x      │  EDGE   │   │ ROUTERS │    │(internet │
              TTL≈58            │ (BGP)   │   │(BGP,many│    │ gateway) │
                                └─────────┘   │ hops)   │    └──────────┘
                                              └─────────┘    TTL=61,60,...
```

1. **Pod builds the packet.** Destination `142.250.72.0`. The pod's routing table has essentially one route: `default via 10.244.1.1 dev eth0` — its **veth gateway** (the node end of the virtual cable). Destination isn't on the pod's own tiny subnet, so it goes to the default gateway. Kernel sets **TTL=64**. Packet leaves via the veth pair into the node.

2. **Node A routes it.** The node (an IP-forwarding Linux router) does a FIB lookup on `142.250.72.0`. No specific route matches → falls to `default via 10.0.1.1 dev eth0` (the node's own default gateway, the VPC router at the subnet's `.1`). **Router decremented TTL to 63.** But first: is this a public destination leaving a private-IP pod? Yes → it must be NAT'd (the VPC route sends it toward the NAT Gateway because the pod IP is private and can't appear on the internet).

3. **VPC router consults the route table.** Your private subnet's route table says `0.0.0.0/0 → nat-gateway-id`. Longest-prefix match: only the default route matches a public IP, so off to the NAT GW. **TTL now 62** (conceptually; AWS's fabric is a bit magic here, but the model holds).

4. **NAT Gateway masquerades.** It rewrites the source from the pod/node private IP to the NAT GW's Elastic IP (public). See [NAT & PAT](14-nat-and-pat.md). Now the packet has a legitimately routable public source.

5. **Internet Gateway (IGW).** The public subnet's route table has `0.0.0.0/0 → igw-id`. The IGW is the VPC's door to the internet. Packet exits AWS's AS (AS16509).

6. **ISP / transit routers (many hops).** Now the packet is in the wild internet, hopping router to router. **Each one decrements TTL** (61, 60, 59…). Every one of these routers picked its next-hop toward Google's prefix using **BGP** — Google announced `142.250.0.0/15`-ish blocks, and every AS along the way learned the best AS-path to it. Pure hop-by-hop: no single router knows the whole route, each just knows "toward Google, go that way."

7. **Google's edge (AS15169) delivers.** The packet arrives at Google's border router (which peers via BGP), gets routed internally (OSPF/IS-IS + Google's own fabric) to the actual server, TTL maybe ~58. The server sees a connection from your NAT GW's public IP and replies — and the whole dance runs in reverse.

**The payoff:** at no point did anyone compute the full path. ~15 independent routers each made one local longest-prefix decision, TTL kept any loop bounded, and BGP had pre-wired every hop's sense of "toward Google." That is routing.

---

## ⚖️ Rung 6 — The Contrast

**Routing (L3) vs Switching (L2)** — the alternative you already know.

A switch is the older, simpler, faster-per-decision device. It moves **frames** within one broadcast domain using **MAC addresses** and a flat MAC table. It cannot cross networks, cannot summarize, cannot pick between multiple paths (Spanning Tree even *disables* redundant links to prevent loops). A router moves **packets** *between* networks using **IP prefixes**, scales via hierarchy/summarization, and picks best paths.

| Dimension | Switching (L2) | Routing (L3) |
|---|---|---|
| Addresses used | MAC (flat, 48-bit) | IP prefix (hierarchical) |
| Scope | One broadcast domain / VLAN | Between any networks, globally |
| Data unit | Frame | Packet |
| Decision basis | Exact MAC match, else flood | Longest-prefix match, never floods |
| Loop prevention | Spanning Tree (blocks links) | **TTL decrement + drop at 0** |
| Path selection | None (one path, STP) | Metrics, admin distance, BGP policy |
| Scales to | A building | The planet (BGP) |
| K8s example | veth ↔ Linux bridge (`cni0`) | node route for remote pod CIDR |

**Static vs dynamic routing** — the other axis of contrast:

| | Static | Dynamic (OSPF/BGP) |
|---|---|---|
| Setup | Human types routes | Protocol learns them |
| Adapts to failure | No (black-holes) | Yes (reconverges) |
| Overhead | Zero CPU/protocol | CPU, memory, complexity |
| Best for | Stubs, VPC route tables, small stable nets | Large/changing topologies, the internet |
| Cloud example | AWS VPC route table | Calico pod-route announcement, Direct Connect BGP |

**When would I NOT need to think about this?** Inside a *single* subnet — pods on the *same* node, or two EC2 in one subnet — there is no routing; it's pure L2 switching (the node's bridge / ARP). You also lean on static routing (not dynamic) for VPCs: AWS doesn't want you running OSPF in your route table, it wants declarative static entries its control plane manages. And if VPC-CNI gives pods real VPC IPs, the *VPC's* routing does the cross-node work and your nodes need no per-pod-CIDR routes at all.

**Why this over that, in one sentence:** Use routing (L3) the instant traffic must cross a network boundary — different subnet, different node's pod CIDR, or the internet — because switching physically cannot leave its own broadcast domain.

> **Check yourself before Rung 7:** Two pods on the *same* node talk to each other. Does TTL get decremented? Does any *routing* table lookup happen, or is it pure switching? Explain using the difference between L2 and L3.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *out loud* before running the command. Being wrong here is the most valuable thing that can happen — it means you found a gap in your model.

### Test 1 — Normal case: read your routing table and find the default gateway

**Prediction:** *"My machine has a `default` (`0.0.0.0/0`) route pointing at my gateway, plus one directly-connected route for my own subnet with no `via`, BECAUSE the default gateway is the catch-all for anything not on my local wire, and my own subnet needs no next-hop."*

```bash
ip route show
# Representative output:
# default via 192.168.1.1 dev wlan0 proto dhcp metric 600
# 192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.42

# Ask "how would the kernel route ONE specific destination?":
ip route get 8.8.8.8
# 8.8.8.8 via 192.168.1.1 dev wlan0 src 192.168.1.42 uid 1000
ip route get 192.168.1.50
# 192.168.1.50 dev wlan0 src 192.168.1.42   ← no "via": directly connected, ARP for it
```

**Verify:** `8.8.8.8` should resolve to `via <gateway>` (leaves the subnet → default route). A same-subnet IP should have **no `via`** (directly connected → L2 delivery). If `ip route get 8.8.8.8` says "unreachable," you have no default gateway — that's the exact failure mode of a pod or node whose default route is missing, and it teaches you the default gateway is not optional.

### Test 2 — Edge/failure case: watch TTL bound a path with traceroute

**Prediction:** *"`traceroute` will reveal ~8-20 distinct hops between me and Google, each a router decrementing TTL, BECAUSE traceroute sends packets with TTL=1,2,3,… and each dying router replies with ICMP Time Exceeded, exposing itself. A packet with an artificially tiny TTL will die before reaching the destination."*

```bash
traceroute google.com
# 1  192.168.1.1 (192.168.1.1)      1.2 ms   ← my default gateway, TTL expired here first
# 2  10.20.0.1 (10.20.0.1)          8.4 ms   ← ISP edge
# 3  * * *                          ← a hop that won't send ICMP (filtered) — normal
# 4  72.14.x.x                     14.1 ms
# ...
# 11 142.250.72.14                 15.9 ms   ← arrived at Google

# Force the TTL-drop directly and SEE the ICMP Time Exceeded:
ping -t 1 8.8.8.8            # Linux: set initial TTL to 1
# From 192.168.1.1: icmp_seq=1 Time to live exceeded   ← died at hop 1, exactly as predicted
```

*(On Windows: `tracert google.com`; on macOS `traceroute` is built in. `mtr google.com` gives a live, per-hop loss/latency view — better for spotting a flaky hop.)*

**Verify:** Hop 1 must be your default gateway from Test 1 — proof the two tools agree on your first router. Rising latency across hops = physical distance. `* * *` lines are routers that decline to send ICMP (rate-limited or filtered), *not* failures. The `ping -t 1` reply saying "Time to live exceeded" from your gateway is TTL-decrement-and-drop happening in front of your eyes. If traceroute stalls at a hop and never recovers, that's where the path is actually broken — the diagnostic value of TTL made visible.

### Test 3 — Kubernetes/cloud case: prove a node is a router for pod CIDRs

**Prediction:** *"On a Kubernetes node, I'll find a directly-connected route for the local pod CIDR (via the CNI bridge/interface) and, with a route-based CNI, a route for each *remote* node's pod CIDR with next-hop = that node's IP, BECAUSE cross-node pod traffic is routing between two networks and the CNI installs exactly those next-hops."*

```bash
# On an EKS/kubeadm node (run on the node, or via a privileged debug pod):
ip route show
# default via 10.0.1.1 dev eth0                       ← node's default gateway (VPC router)
# 10.0.1.0/24 dev eth0 proto kernel scope link src 10.0.1.11
# 10.244.1.0/24 dev cni0 proto kernel scope link      ← LOCAL pods, directly connected
# 10.244.2.0/24 via 10.0.1.12 dev eth0                ← Node B's pods: route via Node B
# 10.244.3.0/24 via 10.0.1.13 dev eth0                ← Node C's pods: route via Node C

# Confirm the node is actually forwarding (a router MUST have this = 1):
sysctl net.ipv4.ip_forward        # net.ipv4.ip_forward = 1

# From inside a pod, see its ENTIRE world is a default route to the veth gateway:
kubectl run r --rm -it --image=nicolaka/netshoot -- ip route
# default via 10.244.1.1 dev eth0     ← the veth gateway on the node
# 10.244.1.0/24 dev eth0 scope link

# If the cluster runs Calico, watch BGP announce those pod routes:
kubectl get pods -n calico-system -l k8s-app=calico-node
calicoctl node status
# IPv4 BGP status: peers established with each other node   ← Calico IS running BGP
```

**Verify:** The local pod CIDR must be `scope link` on the CNI interface (`cni0`/`cali*`) — that's L2 delivery to local pods. Each *remote* pod CIDR must have a `via <node-IP>` next-hop — that's the node acting as a **router**, precisely the Rung 2 idea. `ip_forward` must be `1`; if it's `0`, the node silently drops transit packets and cross-node pods break (a classic CNI misinstall). The pod's own table being just "default via veth gateway" proves a pod is as route-simple as your laptop. With Calico, `calicoctl node status` showing established BGP peers proves the *same protocol that runs the internet* is stitching your pods — bring it full circle to Rung 3.5.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
A router sends each packet one hop closer to the *longest-matching* destination network in its table, hop by hop, with TTL as the loop-killing safety valve.

**Three-sentence beginner explanation:**
Routing is the slow "figure out the map of all networks" job; forwarding is the fast "shove this one packet out the right door" job, and routers keep two tables — a rich routing table (RIB) and a lean speed-optimized forwarding table (FIB) — for exactly that reason. No router knows the whole path; each only knows the next hop, and it picks that hop by matching the destination IP's network portion against the most specific prefix it knows, defaulting to the gateway when nothing specific matches. Small stable networks (and AWS VPC route tables) use hand-typed static routes, while the internet and large clusters use dynamic protocols — OSPF (Dijkstra) inside an org, BGP between organizations and clouds — with TTL decremented at every hop so a misrouted packet dies instead of looping forever.

**Sub-parts mapped to the one idea** ("match the network portion, one hop closer, trust the next router"):

| Sub-part | How it derives from the one idea |
|---|---|
| Default gateway | The `/0` route you fall back to when no network portion matches specifically |
| RIB vs FIB | "Match" is precomputed once (RIB) so "one hop closer" is instant (FIB) |
| Longest-prefix match | The precise rule for "match the network portion" when several fit |
| Static vs dynamic | Two ways the *table of networks* gets built |
| OSPF vs BGP | Dijkstra-picks-best-path *inside* an AS vs policy-picks-path *between* AS |
| TTL / hop-limit | The guardrail that makes "trust the next router" safe against loops |
| Dijkstra / Bellman-Ford | The math that computes *which* hop is "closer" |
| traceroute | Turns TTL's drop-at-0 into an X-ray of every hop |
| Node routes / CNI / VPC route tables | The same one idea, wearing Kubernetes and AWS clothes |

**Which rung to revisit hands-on:** **Rung 7, Test 3.** Reading your laptop's routing table (Test 1) clicks fast, but *seeing a node route pod CIDRs to other nodes' IPs* — and catching Calico speaking BGP — is where "a node is a router" stops being a slogan and becomes muscle memory. If cross-node pod networking ever feels like magic, come back and run `ip route show` on the node until it doesn't.

---

## Related concepts

- [Subnetting & CIDR](03-subnetting-and-cidr.md) — the network/host split that longest-prefix match operates on.
- [MAC addresses, switching & ARP](05-mac-addresses-switching-arp.md) — the L2 delivery that happens *inside* a network, before and after routing.
- [OSI & TCP/IP models](06-osi-and-tcpip-models.md) — why routing is L3 and switching is L2, and where TTL lives in the header.
- [NAT & PAT](14-nat-and-pat.md) — what happens to the source address as your packet leaves the VPC (the NAT GW step in the Trace).
- [AWS VPC](20-aws-vpc.md) — route tables, IGW, NAT Gateway targets: static routing in the cloud.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — Flannel routes, Calico BGP, veth gateways: routing wearing Kubernetes clothes.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A switch floods a frame to every port when it doesn't know the destination MAC. Why can't a router just "flood a packet to every network" when it doesn't know the destination IP? What would that cost, and what fact about IP addresses makes a smarter choice possible?

**A:** Flooding works for a switch because its scope is one broadcast domain — a bounded set of wires it can physically see. A router's "every network" is potentially the whole internet (~75,000 autonomous systems), so flooding every unknown packet everywhere would be a planet-scale broadcast storm: bandwidth on every link consumed by copies of every packet, exactly the flat-network collapse that routing was invented to prevent. The smarter choice is possible because IP addresses, unlike flat 48-bit MACs, are **hierarchical**: the CIDR prefix splits an address into a network portion and a host portion, so a router can match just the network portion against a table of known prefixes (longest-prefix match) and send the packet one hop closer — no flooding, and whole swaths of the internet summarize into a single table entry or the `0.0.0.0/0` default route.

### Before Rung 7
**Q:** Two pods on the *same* node talk to each other. Does TTL get decremented? Does any routing table lookup happen, or is it pure switching?

**A:** Both pods sit in the node's local pod CIDR (e.g. `10.244.1.0/24`), which the node's table lists as **directly connected** (`scope link` on `cni0`) — so no packet crosses a network boundary and no router forwards it. Delivery is essentially L2: the veth pairs and the Linux bridge move the frame by MAC address (after ARP), which is switching, and since **only routers decrement TTL — switches never touch the IP header** — TTL stays at 64. Strictly, the kernel still does a route lookup on the destination, but it hits the directly-connected entry ("next-hop = self, just ARP and deliver"), so no *routing between networks* occurs. TTL decrement only starts the moment traffic must leave for another network — e.g. another node's pod CIDR via a `via <node-IP>` route.
