# Network Devices

### Repeater, hub, bridge, switch, router, gateway, NIC — the boxes that move your bits, the exact OSI layer each lives on, and how every one of them became software inside your node

---

## 🎯 Rung 0 — The Setup

You are a cloud/Kubernetes platform engineer, ~6 years deep in DevOps and support. You provision EKS clusters, you read VPC route tables in your sleep, and when a pod can't reach a Service you reach for `kubectl`, `curl -v`, and the AWS console. You have never plugged in a physical switch and you have certainly never seen a "hub." That gear feels like museum equipment — the stuff in the CCNA course you skipped.

Then this lands on your desk:

> A teammate is drawing the pod-to-pod data path on the whiteboard during an incident review. They say: *"Traffic leaves the pod's veth, hits `cni0` — which is basically a **switch** — and if it's leaving the node, the node acts as a **router** for the pod CIDR before it hands off to the VPC."* Someone asks, "Wait, is `cni0` a switch or a bridge? And where's the router — I don't see a router?" The room looks at you. You realize every word — switch, bridge, router — is a **classic network device**, and you've been using virtual copies of them for years without ever learning what the originals were or which OSI layer each one lives on.

Here's the truth this file will make obvious: **the cloud did not invent new network plumbing. It virtualized the old plumbing.** `cni0` is a switch. The node is a router. The veth pair is a cable. The hypervisor under your EC2 instance runs a virtual switch. Every "modern" object maps cleanly onto a device engineers have wired into racks for forty years — and each of those devices is defined by exactly one thing: **the OSI layer it operates at.** Learn the six classic devices and their layers, and the whole virtual data path snaps into focus.

**What you already know that will carry you:**
- The **OSI model** — L1 physical, L2 data-link, L3 network (from `06-osi-and-tcpip-models.md`). This file is essentially "one device per layer." That model IS the organizing principle here.
- **MAC addresses, switches, and ARP** (from `05-mac-addresses-switching-arp.md`). You already met the switch. Here we place it in a family of six devices and see why it beat the hub.
- **Routing** — routers move packets between networks by IP (from `08-routing-and-forwarding.md`). We'll pin the router to L3 and contrast it with everything below.
- Pods have a **veth** interface and hang off a **bridge** called `cni0` or `docker0` (from `24-kubernetes-pod-networking-cni.md`). By the end, "bridge" won't be jargon — it'll be "the switch, in software."

By the end of this file, the whiteboard sentence will read like a parts list you could recite.

---

## 🔥 Rung 1 — The Pain

Rewind to the very beginning of local networking. You have two machines and a wire. That works. Now scale up, and watch each new device get *forced into existence* by a specific, physical pain.

**Pain 1 — The signal dies (→ forces the repeater).** An electrical signal on a copper cable weakens as it travels (attenuation). Past ~100 metres of Ethernet, the far end can no longer reliably tell a 1 from a 0. You physically cannot make the LAN bigger than the cable's reach. The crude fix: a **repeater** — a dumb L1 amplifier that receives the fading signal and regenerates a clean, full-strength copy so the wire can run further. It understands *nothing* about the data. It just refreshes bits.

**Pain 2 — More than two machines on one wire (→ forces the hub, then exposes ITS pain).** You want ten machines on one LAN. You connect them through a **hub** — essentially a multiport repeater. Machine A sends; the hub copies the signal out **every other port**. It works, but it's a screaming room: everyone hears everyone, and if two machines transmit at once their signals **collide** and both must back off and retry. The whole hub is **one collision domain**. Add machines and the LAN drowns in collisions. The hub *solved* "more than two machines" and *created* "everyone shouts over everyone."

**Pain 3 — Send to ONE machine, not all of them (→ forces the bridge/switch).** The hub is dumb because it forwards by *nothing* — it just floods. What if a device could *learn* which machine is on which port and send a frame only where it needs to go? That device reads the **MAC address** in each frame: first the **bridge** (two-ish segments, L2), then its high-port descendant the **switch** (a multiport bridge with a MAC table). Now traffic between A and B doesn't bother C through Z. Collisions collapse to near zero. This is L2, and it's the single biggest upgrade in LAN history.

**Pain 4 — Two DIFFERENT networks must talk (→ forces the router).** A switch is "flat." Everything plugged into it is one **broadcast domain** — one subnet. But you can't put the entire internet on one switch: ARP broadcasts alone would melt it. You need to connect *separate* networks (your `10.0.1.0/24` to my `10.0.2.0/24`, or your LAN to the internet). That's a different job — forward by **IP**, decide the best next network, cross the boundary. That device is the **router** (L3). A switch moves frames *within* a network; a router moves packets *between* networks.

**Pain 5 — The two networks don't even speak the same language (→ forces the gateway).** Sometimes the networks you're joining are fundamentally *dissimilar* — different protocols, formats, or addressing entirely (think an old IBM mainframe network bolted to a TCP/IP LAN, or email crossing from an internal system to SMTP). A router assumes both sides speak IP. When they don't, you need a **gateway** — a **protocol translator** that reformats between dissimilar networks. (Confusingly, "default gateway" in everyday IP config just means "the router I send off-subnet traffic to" — same word, narrower meaning. We'll untangle that.)

**Who felt this pain most?** Every LAN builder from the 1980s onward — but *you* feel it today, virtualized. Your Kubernetes node runs a **software switch** (the Linux bridge `cni0`/`docker0`) and acts as a **software router** for the pod CIDR. Your EC2 instance sits on a **hypervisor virtual switch**. The pain that forged repeaters, hubs, switches, and routers didn't go away — it moved into the kernel and the hypervisor, and you debug its virtual descendants every week.

> **Check yourself before Rung 2:** A hub and a switch both have many ports and both connect machines on one LAN. Name the ONE piece of information the switch uses that the hub completely ignores — and say what that lets the switch stop doing.

---

## 💡 Rung 2 — The One Idea

Here is the whole file in one sentence. Write it on a sticky note:

> **Every network device is defined by the OSI layer it reads: a repeater/hub just moves bits (L1), a bridge/switch forwards frames by MAC within one network (L2), a router forwards packets by IP between different networks (L3), and a gateway translates between networks that don't even speak the same protocol — and in the cloud every one of these is now software.**

Memorize that. The "higher the layer it reads, the smarter it is" ladder is the key. Everything else is derivable:

- **Why is a switch smarter than a hub?** Because it reads one layer *higher* — L2 MAC addresses instead of raw L1 signals — so it can forward to one port instead of flooding all. "A switch is a smart hub." (Derived.)
- **Why does a router connect networks but a switch doesn't?** Because the router reads L3 IP addresses, which encode *which network* a host is on, so it can decide "this packet belongs on a different network, send it that way." A switch only reads L2 MACs, which are flat and local — no notion of "another network." "A router connects networks." (Derived.)
- **Why is a gateway different from a router?** Because a router assumes both sides speak the same protocol (IP) and only forwards; a gateway *translates* when the two sides are dissimilar. Higher-layer work. (Derived.)
- **Why is `cni0` called a bridge but behaves like a switch?** Because a switch *is* a multiport bridge — same L2 device, historically different port counts. In software the words merge. (Derived.)
- **Why does the node act as a router for pods?** Because pods on different nodes are on *different* L3 pod subnets, and crossing between networks by IP is exactly the router's L3 job. (Derived.)

One sentence. Five derivations. That's the ladder.

> **Memorize the core sentence before you continue.** If you can't recite the "L1 bits / L2 frames-by-MAC / L3 packets-by-IP / gateway translates" spine, re-read Rung 2.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> This section is a family tour of the boxes that move network traffic, climbing a ladder from dumbest to smartest. The rule for the whole ladder: the more of the "envelope" a device is able to read, the smarter its decisions — and the more work each decision costs.
>
> - **The NIC (network card) — the front door.** Every computer needs a doorway onto the network. The NIC is that door, and it carries the machine's hardware nametag (its MAC address — think of it as a serial number stamped on the door). In the cloud these doors are virtual, but they're still doors.
>
> - **Repeater — the megaphone relay.** A voice fades over a long hallway. A repeater just hears the fading signal and shouts a fresh, crisp copy onward. It reads no addresses, makes no decisions — it only refreshes the signal so the wire can run farther.
>
> - **Hub — the room where everyone shouts.** A hub is a repeater with many sockets: whatever comes in one socket gets blasted out all the others. Everyone hears everything, and if two people talk at once their words collide and both must repeat themselves. It works, badly, and is now extinct.
>
> - **Bridge — the first doorman who reads name tags.** A bridge sits between two rooms and learns who's in which room. A message for someone in the same room isn't forwarded — keeping the other room quiet.
>
> - **Switch — the doorman with a full guest list.** A switch is that bridge with many sockets. It keeps a list of "which nametag is plugged into which socket," so it delivers each message to exactly one recipient — a whisper instead of a shout. If it hasn't met a name yet, it briefly falls back to shouting like a hub, learns the answer, then whispers forever after.
>
> - **Router — the border post between neighborhoods.** A switch only works *inside* one neighborhood. To send mail *between* neighborhoods you need the router: it reads the full street address (the IP), looks up the best direction in its map, ticks down a "hops remaining" counter on the envelope (so lost mail can't circle forever), and re-labels the outer wrapper for the next leg. The letter inside never changes; only the outer wrapper does.
>
> - **Gateway — the interpreter.** Sometimes two networks don't even speak the same language. A gateway translates the actual content between them. Trap to note: the everyday phrase "default gateway" just means "the router I hand outbound mail to" — same word, humbler job.
>
> - **The payoff: your cloud runs software copies of all of these.** Inside a Kubernetes node, each pod's virtual cable (a "veth pair" — a two-ended cord) plugs into a software switch (`cni0`), and the node itself acts as the router whenever traffic must leave for another node's neighborhood. Underneath, the cloud host runs yet another software switch. Nothing new was invented — the old boxes just moved inside the computer.

*Now the original technical deep-dive — the same ideas, in precise form:*

Let's take the whole family apart, device by device, from the bottom of the stack up. The organizing rule never changes: **each device reads up to a certain OSI layer and no higher, and that ceiling is its entire personality.**

### The layer ladder — the map for everything below

```text
   OSI LAYER          DEVICE THAT LIVES HERE        WHAT IT READS / DECIDES ON
   ─────────────────────────────────────────────────────────────────────────
   L7 Application ┐
   L6 Presentation│    GATEWAY (protocol translator)   translates between
   L5 Session     │      spans up to L7                 dissimilar protocols
   L4 Transport   ┘
   ─────────────────────────────────────────────────────────────────────────
   L3 Network          ROUTER                           destination IP →
                       (+ L3 switch)                     next network / hop
   ─────────────────────────────────────────────────────────────────────────
   L2 Data Link        SWITCH  (multiport BRIDGE)       destination MAC →
                       BRIDGE                            which port
   ─────────────────────────────────────────────────────────────────────────
   L1 Physical         HUB  (multiport REPEATER)        nothing — copies
                       REPEATER                          bits to all ports
   ─────────────────────────────────────────────────────────────────────────
   (edge of every host) NIC — the L1/L2 doorway onto the wire; owns the MAC
```

Higher on this ladder = reads more of the packet = makes smarter decisions = does more work. That's the single trend. Now, part by part.

### Part 0 — The NIC: every host's doorway onto the wire

A **NIC** (Network Interface Card / network interface) is the component that connects a host to the network. It straddles **L1 and L2**: it turns the host's frames into physical signals (L1) and it owns the host's **MAC address** (L2). Every other device below exists to interconnect NICs. In the cloud you never see a physical NIC — but every EC2 instance has a virtual one (the ENI, Elastic Network Interface), and every pod has a virtual one (`eth0`, one end of a veth pair). When you run `ip link show` and see `link/ether 02:42:...`, you are looking at a NIC's L2 identity.

### Part 1 — Repeater (L1): the signal refresher

A **repeater** operates at **Layer 1, Physical**. Its entire job: receive a weakening electrical (or optical) signal and regenerate a clean, full-strength copy so the medium can run past its distance limit.

```text
   weak, attenuated signal          clean, regenerated signal
   ~~~..--..~~~._.~~   ──►  [REPEATER]  ──►  ‾|_|‾|_|‾|_|‾|_
   (barely readable)         (L1)             (crisp 1s and 0s)
```

- It reads **no addresses**. It doesn't know what a MAC or IP is. It sees voltage/light, not data.
- It has (classically) two ports: in and out. It cannot make forwarding *decisions* — there's nothing to decide.
- Modern echo: fiber-optic repeaters/amplifiers on long-haul links; and every hub is, internally, a repeater with many ports.

### Part 2 — Hub (L1): the multiport repeater that shouts

A **hub** is a **multiport repeater** — still pure **Layer 1**. A signal arriving on one port is regenerated and blasted out **every other port**. It has zero intelligence: no table, no address reading, no filtering.

```text
        HUB (L1)  —  "dumb broadcast to all ports"
                     ┌──────────────┐
        A ──frame──► │  copies bits │ ──► B  (must inspect: for me? no → drop)
                     │  to ALL other│ ──► C  (for me? no → drop)
                     │  ports, no   │ ──► D  (for me? no → drop)
                     │  filtering   │
                     └──────────────┘
        Consequences:
          • ONE collision domain (A and C transmit at once → collision)
          • ONE broadcast domain
          • half-duplex, shared bandwidth (10 Mb hub / 10 machines ≈ awful)
          • every NIC wastes effort inspecting frames not meant for it
```

The hub is the villain of Rung 1. It solved "connect many machines" and created "everyone collides." It is functionally obsolete — replaced everywhere by the switch — but you must know it, because **a hub is exactly what a switch behaves like for one frame when it doesn't yet know where a MAC lives** (flooding).

### Part 3 — Bridge (L2): the first device that reads addresses

A **bridge** operates at **Layer 2, Data Link**. It's the evolutionary jump: the first device to read the **MAC address** inside a frame. A classic bridge joins two LAN segments and **filters** — if a frame's destination is on the same side it came from, the bridge doesn't forward it; if it's on the other side, it does. It learns which MACs live on which side.

```text
   BRIDGE (L2) — filters/forwards by MAC between two segments
        Segment 1                         Segment 2
     A ── B ── C ───┤  BRIDGE  ├─── D ── E ── F
                    │  MAC tbl │
     A→B frame?  → same segment → DON'T forward (filtered, keeps segment 2 quiet)
     A→E frame?  → other segment → FORWARD
```

The bridge introduced the idea that would define L2 forever: **learn source MACs, forward by destination MAC.** A switch is just this idea scaled to many ports.

### Part 4 — Switch (L2): the multiport bridge with a MAC table

A **switch** is a **multiport bridge** — still **Layer 2** — and it's the workhorse of every LAN (and every Kubernetes node) on Earth. It maintains a **MAC address table** (a.k.a. **CAM table**, or in Linux the **forwarding database / fdb**) mapping `MAC → port`, and it forwards each frame to the **one** port where its destination lives.

```text
   SWITCH (L2)  —  "a smart hub": unicast to the target port only
   ┌──────────── MAC ADDRESS TABLE ────────────┐
   │  aa:aa:...:01  →  port 1   (learned from A)│
   │  bb:bb:...:02  →  port 2   (learned from B)│
   │  cc:cc:...:03  →  port 3                    │
   └────────────────────────────────────────────┘

   RULE 1 (LEARN):   frame arrives → record its SOURCE MAC → this port
   RULE 2 (FORWARD): look up DESTINATION MAC:
                       known    → send out THAT one port  (unicast)
                       unknown  → flood all ports but source (acts like a hub, once)
                       ff:ff:ff:ff:ff:ff (broadcast) → flood always

        A ──frame to B──► [SWITCH] ──► B only.  C and D hear NOTHING.
```

Why the switch crushed the hub, in the language of domains:
- **Collision domains:** a hub = one big shared one; a switch = **one per port** → with full-duplex links, effectively *no* collisions. **A switch breaks up collision domains.**
- **Broadcast domains:** a plain switch forwards broadcasts to all ports, so the whole switch is still **one broadcast domain**. A switch does **not** break up broadcast domains — a **router** (or a **VLAN**, see `16-vlans-and-segmentation.md`) does.

Memory hook: **"a switch is a smart hub."** Same many-port shape; the switch just reads the L2 MAC the hub ignores, so it can whisper to one port instead of shouting to all.

### Part 5 — Router (L3): the device that connects networks

A **router** operates at **Layer 3, Network**. It reads the **destination IP** in each packet, consults its **routing table** (`IP prefix → next hop / interface`), and forwards the packet toward a **different network**. Where a switch moves frames *within* one subnet, a router moves packets *between* subnets.

```text
   ROUTER (L3) — routes packets between DIFFERENT networks by IP
                          ┌─────────── ROUTING TABLE ───────────┐
                          │ 10.0.1.0/24  → interface eth0 (local)│
   Network A              │ 10.0.2.0/24  → interface eth1 (local)│      Network B
   10.0.1.0/24 ──eth0──►  │ 0.0.0.0/0    → next hop 203.0.113.1  │  ◄──eth1── 10.0.2.0/24
                          └──────────────────────────────────────┘
   For each packet:
     1. strip the incoming L2 frame (throw away old MACs)
     2. read destination IP, longest-prefix-match the routing table
     3. DECREMENT the IP TTL / hop-limit by 1 (if it hits 0 → drop, send ICMP Time Exceeded)
     4. build a BRAND-NEW L2 frame with new src/dst MACs for the next hop
     5. forward out the chosen interface
```

Two facts to burn in:
- **The IP packet is preserved end-to-end; the L2 frame is rebuilt at every hop.** Source/destination IP stay constant from origin to final destination; the MACs change at every single router. (This is the "MAC changes every hop" idea from `05-mac-addresses-switching-arp.md`.)
- **The router decrements TTL** (IPv4) / **hop-limit** (IPv6) by 1 per hop. When it reaches 0 the packet is dropped and an ICMP "Time Exceeded" is returned — which is *exactly* how `traceroute` maps the path (see `08-routing-and-forwarding.md`).

Memory hook: **"a router connects networks."** Different networks = different IP prefixes = L3 = router.

### Part 6 — Gateway (L4–L7): the protocol translator

A **gateway**, in its precise sense, is a **protocol translator between dissimilar networks** — it can operate all the way up to **Layer 7** because it may have to reformat data, not just re-address it. A router assumes both sides speak IP and only forwards; a gateway is called for when the two sides are *fundamentally different*.

```text
   GATEWAY — translates between networks that speak different languages
   ┌─────────────────┐        ┌──────────────────┐        ┌─────────────────┐
   │ Network X       │        │   GATEWAY         │        │ Network Y       │
   │ (protocol/format│ ─────► │ decode X, re-encode│ ─────► │ (protocol/format│
   │  A)             │        │ as Y  (up to L7)  │        │  B)             │
   └─────────────────┘        └──────────────────┘        └─────────────────┘
   Examples: email→SMTP gateway, VoIP↔PSTN media gateway,
             legacy SNA/mainframe ↔ TCP/IP, an API gateway (HTTP↔gRPC),
             IoT protocol gateway (MQTT↔HTTP)
```

⚠️ **The "default gateway" trap.** In everyday IP configuration, "default gateway" means "the **router** I send all off-subnet traffic to" — that's a *router*, not a protocol translator. Same word, two meanings. When someone says "the pod's default gateway is `10.244.1.1`," they mean the router-of-last-resort. When a textbook says "a gateway translates between dissimilar networks," they mean the L7 translator. Context tells you which; now you'll never conflate them.

### The Kubernetes / cloud picture — where the whole family runs in software

This is the payoff. Every classic device above exists inside your cluster as software:

```text
                         ONE KUBERNETES NODE (an EC2 instance)
   ┌────────────────────────────────────────────────────────────────────────┐
   │  Pod A 10.244.1.5      Pod B 10.244.1.6                                 │
   │  ┌────────┐            ┌────────┐                                       │
   │  │ eth0   │            │ eth0   │   ← pod NIC (one end of a veth pair)  │
   │  │(veth)  │            │(veth)  │                                       │
   │  └───┬────┘            └───┬────┘                                       │
   │   veth│ = a VIRTUAL CABLE  │veth   (the other end lives on the host)    │
   │      ┌┴────────────────────┴┐                                          │
   │      │  cni0 / docker0       │  ← LINUX BRIDGE = a SOFTWARE SWITCH      │
   │      │  (Linux bridge, L2,   │     (learns pod MAC → veth port)         │
   │      │   has a MAC fdb)      │                                          │
   │      └───────────┬───────────┘                                          │
   │                  │ the node's kernel routing table + iptables          │
   │            ┌─────┴──────┐                                              │
   │            │  NODE = a   │  ← the node acts as a VIRTUAL ROUTER (L3)    │
   │            │  virtual    │     for the pod CIDR: pod→pod cross-node,    │
   │            │  ROUTER     │     pod→internet all route through here      │
   │            └─────┬──────┘                                              │
   │                  │ node NIC (ENI)                                       │
   └──────────────────┼───────────────────────────────────────────────────┘
                      ▼
        HYPERVISOR VIRTUAL SWITCH (under the EC2 host) → VPC fabric → other nodes / IGW
```

Read the map:
- **veth pair = the virtual cable.** Two connected virtual interfaces; whatever enters one end exits the other. One end is the pod's `eth0`, the other end plugs into the bridge. It literally replaces the copper patch cord.
- **`cni0` / `docker0` (Linux bridge) = the software switch.** It has a MAC forwarding database (`bridge fdb show`), it learns which pod MAC is on which veth port, and it unicasts same-node pod frames to the right port — pure L2, exactly Part 4. Same-node pod-to-pod traffic never leaves this switch.
- **The node = the virtual router.** When a pod talks to a pod on *another* node (a different pod subnet) or to the internet, the frame goes up to the node's **kernel routing table**, which forwards by IP across the network boundary — decrementing TTL, rewriting MACs — exactly Part 5. The node *is* the L3 router for the pod CIDR.
- **Hypervisor virtual switch = the switch one level down.** Your EC2 instance's ENI plugs into a virtual switch inside the hypervisor (in AWS, the Nitro system / VPC data plane), which stitches thousands of VMs onto the VPC fabric. Same L2 concept, another layer of virtualization.
- **L3 switch = a hardware hybrid you'll meet in data centers:** a switch chassis that *also* does L3 routing at wire speed. It blurs Parts 4 and 5 into one box — proof that "one device = one layer" is a teaching simplification the real world happily violates.

That whiteboard sentence from Rung 0 — "cni0 is basically a switch, and the node acts as a router" — is now a precise, layered parts list.

> **Check yourself before Rung 4:** Two pods on the **same** node exchange traffic entirely through `cni0` and it never touches the node's routing table. Which classic device is `cni0` playing, and which OSI layer does that put the same-node data path at? Now: the pods move to **different** nodes — which device takes over, and which layer does the path jump to?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **NIC / network interface** | A host's doorway onto the network; owns the MAC | L1/L2; the endpoint every device interconnects |
| **Repeater** | L1 device that regenerates a weakening signal | Refreshes bits; reads no addresses |
| **Hub** | L1 multiport repeater; floods bits to all ports | One collision + one broadcast domain; obsolete |
| **Bridge** | L2 device that filters/forwards by MAC between segments | Introduced "learn source MAC, forward by dest MAC" |
| **Switch** | L2 multiport bridge with a MAC table | Unicasts to the target port; breaks collision domains |
| **MAC address table / CAM / fdb** | The switch's `MAC → port` map | Built by LEARN, used by FORWARD (Part 4) |
| **Router** | L3 device that forwards packets between networks by IP | Reads dest IP, rewrites MACs, decrements TTL |
| **Routing table** | The router's `IP prefix → next hop` map | Longest-prefix-match decides the next network |
| **Gateway (translator)** | Protocol translator between dissimilar networks (up to L7) | Reformats data, not just re-addresses it |
| **Default gateway** | The *router* a host sends off-subnet traffic to | Everyday IP config; NOT the L7 translator |
| **L3 switch** | A switch that also routes at wire speed | Hybrid of Part 4 + Part 5 in one box |
| **Collision domain** | Set of interfaces that can collide on shared media | Hub = 1 big; switch = 1 per port |
| **Broadcast domain** | Set of devices a broadcast frame reaches | Whole switch = 1; split by router or VLAN |
| **veth pair** | Two linked virtual interfaces; a virtual cable | Connects pod `eth0` to the `cni0` bridge |
| **Linux bridge (cni0/docker0)** | A software switch inside a node | Same-node pod L2 forwarding |
| **Hypervisor virtual switch** | The software switch under a VM/EC2 host | Stitches VM NICs onto the VPC fabric |
| **Frame** | The L2 PDU; carries MAC headers | What a switch/bridge forwards |
| **Packet** | The L3 PDU; carries IP headers | What a router forwards; rides inside a frame |

**"Same kind of thing, different names" — don't get fooled:**
- **Bridge = switch.** A switch is genuinely a multiport bridge. In the container world `cni0` is *called* a bridge but *behaves* as a switch — same L2 device.
- **Hub = multiport repeater.** A hub is just a repeater with many ports; both are L1, both flood, neither reads an address.
- **MAC address table = CAM table = forwarding database (fdb).** The switch's `MAC→port` map, three names. On Linux: `bridge fdb show`.
- **Router = L3 forwarder = (loosely) "default gateway".** The device that connects networks; "default gateway" is the everyday IP-config name for it.
- **Gateway (translator) ≠ default gateway.** These are the *odd couple*: one is an L7 protocol translator, the other is just a router. Same word, keep them apart.
- **NIC = network adapter = network interface = (in cloud) ENI / the pod's `eth0`.** All the host's doorway onto the wire.
- **veth = virtual Ethernet pair = "the virtual cable."** Two ends, whatever goes in one comes out the other.

> **Check yourself before Rung 5:** Someone hands you a device and says "it reads the destination address, keeps a table, and sends traffic out exactly one port." That's true of *both* a switch and a router. What ONE follow-up question tells you which it is — and what does each answer imply about the OSI layer?

---

## 🔬 Rung 5 — The Trace

Let's follow **one** concrete action end to end, and watch the device baton pass from L2 to L3. **Pod A on Node 1 sends a packet to Pod C on Node 2.** IPs: A = `10.244.1.5` (subnet `10.244.1.0/24`), C = `10.244.2.9` (subnet `10.244.2.0/24`). We deliberately pick a *cross-node* target so both a switch and a router get involved.

```text
STEP 1  App in Pod A sends to 10.244.2.9. Pod A's kernel checks its routes:
        "10.244.2.9 is NOT in my subnet 10.244.1.0/24 → it's OFF-subnet →
         send to my DEFAULT GATEWAY (the router), which is cni0 at 10.244.1.1."
        It needs the gateway's MAC → resolves via ARP (cached after first time).

STEP 2  Pod A builds the frame:
        [Dst MAC = cni0/gateway | Src MAC = Pod A | IP 10.244.1.5 → 10.244.2.9]
        Frame leaves Pod A's eth0, travels the VETH CABLE to the host.

STEP 3  cni0 (SOFTWARE SWITCH, L2) receives the frame. Dst MAC = the gateway
        (the node itself), so the switch delivers it UP to the node's routing
        stack. Its L2 job is done — it moved the frame to the router's "port."

STEP 4  NODE 1 acts as ROUTER (L3). Kernel routing table:
        "10.244.2.0/24 lives on Node 2 (via the pod-network route / VPC)."
        → DECREMENT TTL by 1 (say 64 → 63).
        → Build a BRAND-NEW frame with new MACs for the next hop toward Node 2.
        → (Depending on CNI: route directly over the VPC, or VXLAN-encapsulate.)

STEP 5  The packet crosses the VPC fabric (through the HYPERVISOR VIRTUAL
        SWITCH under each EC2 host) and arrives at NODE 2.

STEP 6  NODE 2 acts as ROUTER (L3). "10.244.2.9 is a local pod → deliver to
        cni0." TTL 63 → still fine. Hands the frame to Node 2's cni0.

STEP 7  cni0 on NODE 2 (SOFTWARE SWITCH, L2) looks up Pod C's MAC in its fdb →
        unicasts the frame out Pod C's veth port. Frame crosses the VETH CABLE
        into Pod C's eth0 (its NIC). Delivered. The IP src/dst never changed.
```

Visual of the whole trace, compressed — watch the layer bounce L2 → L3 → L2:

```text
  Pod A          cni0 (switch)     NODE1 router   VPC/hypervisor   NODE2 router    cni0 (switch)   Pod C
  10.244.1.5        L2                 L3            vSwitch            L3               L2       10.244.2.9
     │  veth cable    │                 │               │                │                │  veth   │
     │───frame──────► │──to gateway────►│  TTL 64→63     │                │                │         │
     │                │                 │───new frame───►│───────────────►│  TTL 63        │         │
     │                │                 │                │                │───new frame───►│──unicast►│
     │                │                 │                │                │                │   to C  │
     └───────── IP src 10.244.1.5 / dst 10.244.2.9 UNCHANGED the whole way ──────────────────────────┘
              (only the L2 MACs got rewritten, and TTL dropped by 1 per router)
```

Notice the shape: **switch → router → (fabric) → router → switch.** L2 forwards *within* a node's pod subnet; L3 forwards *between* the two pod subnets; L2 again for final local delivery. Same-node traffic would have stopped at Step 3 — the switch alone, never touching a router, never decrementing TTL. That single difference — did we cross a router or not — is the whole "same-node L2 vs cross-node L3" incident from Rung 0, now traced hop by hop with each device named.

> **Check yourself before Rung 6:** In the trace, the IP addresses never changed but the TTL dropped from 64 to 63 (once) and the MACs were rewritten twice. Which *device type* is responsible for the TTL drop, and why does that same device NOT appear on the same-node path?

---

## ⚖️ Rung 6 — The Contrast

The devices *are* each other's alternatives, arranged up the layer ladder. Each rung up can do something the rung below cannot — at the cost of more work per packet.

| Dimension | **Repeater / Hub (L1)** | **Bridge / Switch (L2)** | **Router (L3)** | **Gateway (L4–L7)** |
|---|---|---|---|---|
| Reads / decides on | Nothing (raw signal) | **Destination MAC** | **Destination IP** | **Protocol / payload format** |
| Unit it handles | Bits / signals | **Frames** | **Packets** | Messages / data |
| Keeps a table? | No | **MAC → port** | **IP prefix → next hop** | Translation logic |
| Connects… | one segment, extended | hosts **within** one network | **different** networks | **dissimilar** networks |
| Collision domains | Hub = one big | **One per port** | One per port | n/a |
| Broadcast domains | One | **One** (doesn't split) | **Splits** (one per interface) | n/a |
| Changes addresses? | No | Rewrites frame MACs | Rewrites MACs + **decrements TTL** | May rewrite everything |
| Cloud / K8s analog | (obsolete) | **`cni0`/`docker0`, hypervisor vSwitch** | **the node; VPC route table** | **API gateway, email/VoIP gateway** |

**What each device can do that the one below cannot:**
- A **switch** can send a frame to *one* port instead of flooding all → it isolates collisions and gives every host full bandwidth. A hub cannot; it has no address to read.
- A **router** can cross between subnets and shrink broadcast domains → you can build the internet from routers. A switch cannot; it's flat, everything on it is one broadcast domain, and ARP broadcasts would drown a switch-only internet.
- A **gateway** can join networks that don't share a protocol → it reformats data. A router cannot; it assumes both sides speak IP.

**And what a lower device can do that a higher one "cannot" (why we still use the simple ones):** a switch forwards at L2 far faster and cheaper than a router chews through L3 lookups + TTL + reframing — which is *why* your same-node pod traffic staying on `cni0` (pure L2) is faster than cross-node traffic that must be routed. Simplicity is a feature; you don't route what you can switch.

**When would you NOT reach for a router / L3?** When everything is on one subnet / one broadcast domain and you just need hosts to talk locally — that's a switch's job, and adding a router there is pure overhead. In Kubernetes: same-node pod-to-pod needs only the bridge; the node-as-router only earns its keep the moment traffic leaves the pod subnet.

**One sentence — how to pick the device:** *Choose the lowest-layer device that can still make the decision you need — repeater to reach farther, switch to talk within a network, router to cross between networks, gateway to translate between networks that don't share a language — because every layer you climb buys capability at the price of per-packet work.*

> **Check yourself before Rung 7:** You have a single flat subnet where hosts collide constantly but there are no broadcast storms. Do you add a switch, a router, or a gateway — and which "domain" does your choice fix while leaving the other untouched?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *before* running the command. The gap between what you predicted and what you saw is where the learning is.

### Example 1 — Normal case: identify the virtual switch and its ports on a Linux host

**Prediction:** *If I list bridges and links on a Docker/Kubernetes host, then I'll find a Linux bridge (`docker0` or `cni0`) acting as a software switch, with several `veth…` interfaces enslaved to it as ports — BECAUSE each container/pod is wired to the bridge by one end of a veth pair, and the bridge is literally a multiport L2 switch in software.*

```bash
# List bridges and the interfaces attached to each (the switch and its "ports")
bridge link
# 7: veth1a2b3c@if6: <...> master docker0 state forwarding ...   ← a container's cable, enslaved to docker0
# 9: veth9d8e7f@if8: <...> master docker0 state forwarding ...   ← another one

# Same idea via ip: show only interfaces whose master is the bridge
ip link show master docker0
# 7: veth1a2b3c@if6: ... master docker0 ...
# 9: veth9d8e7f@if8: ... master docker0 ...

# See the bridge device itself
ip -d link show docker0
#   link/ether 02:42:ab:cd:ef:01 ... bridge ...   ← 'bridge' = it IS a switch; has its own MAC
```

**Verify:** Every `veth…@ifN` with `master docker0` is a **port on the software switch** — that's the Part-4 machinery in front of you. The `@ifN` suffix is the *other end* of the veth cable (inside the container). If `bridge link` is empty, no containers/pods are attached yet — start one and re-run. If you're on EKS with the AWS VPC CNI (not Flannel/Calico bridge mode), you may see *no* `cni0` bridge at all, because VPC-CNI gives each pod a branch ENI and routes rather than bridging — a perfect real-world reminder that "which device am I using" depends on the CNI.

### Example 2 — Watch the switch's MAC table and the router's TTL drop (mechanism/edge case)

**Prediction:** *If I inspect the bridge's forwarding database I'll see learned `MAC → veth port` entries (the switch's CAM table); and if I `traceroute` across a router boundary, the TTL/hop-limit will decrement by exactly 1 per router — BECAUSE the switch LEARNS source MACs per port (Part 4) and every router DECREMENTS TTL and drops it at 0, replying with ICMP Time Exceeded (Part 5), which is how traceroute discovers each hop.*

```bash
# The switch's MAC table (CAM / forwarding database) for the software switch:
bridge fdb show br docker0 | grep -v permanent | head
# 02:42:ac:11:00:02 dev veth1a2b3c master docker0    ← container MAC LEARNED on its veth port
# 02:42:ac:11:00:03 dev veth9d8e7f master docker0    ← another, on its port
#   → this IS 'MAC → port', the exact table from Rung 3 Part 4

# Now the router side: traceroute exploits TTL decrement to reveal each L3 hop
traceroute -n 8.8.8.8
#  1  10.244.1.1    0.4 ms     ← first router: node gateway (TTL 1 expired here)
#  2  10.0.0.1      1.2 ms     ← VPC / next router (TTL 2 expired here)
#  3  100.64.0.1    2.1 ms
#  ...                          ← each line = one router that decremented TTL to 0
```

**Verify:** In `bridge fdb show`, each non-`permanent` line maps one MAC to one `veth…` port — the switch learned it exactly as Rule 1 says. In `traceroute`, **each numbered hop is a distinct router**: traceroute sends packets with TTL=1, 2, 3…, and each router that decrements TTL to 0 drops the packet and returns ICMP Time Exceeded, exposing itself. If two adjacent hops show the *same* IP or a hop shows `* * *`, that's a router not returning ICMP (common, filtered) — not a broken path. The fact that a *switch* never appears as a traceroute hop is the proof that **switches don't touch TTL and routers do** — the Rung-6 check answer, live.

### Example 3 — Kubernetes case: prove the node is the router and cni0 is the switch

**Prediction:** *If I read a pod's routes and its node's routes, then the pod's off-subnet traffic will point at a gateway that is the bridge/node, and the node will hold routes for OTHER nodes' pod CIDRs — BECAUSE `cni0` is the L2 switch for the local pod subnet and the NODE is the L3 router that forwards between pod subnets across the cluster.*

```bash
# Inside a pod: where does off-subnet traffic go?
kubectl exec -it app-a -- ip route
# default via 10.244.1.1 dev eth0        ← the pod's ROUTER (its default gateway = cni0/node)
# 10.244.1.0/24 dev eth0 ...             ← ON-subnet: handled locally by the SWITCH (cni0), no router

# On the node: the node's routing table shows it routing FOR the pod network
#   (Flannel/Calico host-gw style: each other node's pod CIDR is a route)
ip route
# 10.244.0.0/24 via 10.0.1.10 dev eth0   ← Node0's pods → reach via Node0's IP  (NODE = ROUTER)
# 10.244.1.0/24 dev cni0                 ← MY pods → local, via the SWITCH cni0
# 10.244.2.0/24 via 10.0.1.30 dev eth0   ← Node2's pods → reach via Node2's IP  (NODE = ROUTER)

# Confirm the node is even allowed to route between interfaces:
cat /proc/sys/net/ipv4/ip_forward
# 1     ← IP forwarding ON = this Linux box is acting as a ROUTER (0 would break pod networking)
```

**Verify:** The pod's `default via 10.244.1.1` is its **router** (Part 5); the `10.244.1.0/24 dev eth0` route is **switched** locally by `cni0` (Part 4) with no router involved. On the node, every `10.244.X.0/24 via <other-node-IP>` line is the node **routing** to another node's pod subnet — the node *is* the L3 router. And `ip_forward = 1` is the kernel flag that literally turns a Linux host into a router; if it were `0`, cross-node pod traffic would silently blackhole (a classic broken-CNI symptom). Together these three outputs are the entire Rung-3 Kubernetes diagram, reproduced from your own cluster: switch (`cni0`), cable (veth), router (the node).

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
Each network device is defined by the highest OSI layer it reads — repeater/hub move bits (L1), bridge/switch forward frames by MAC within a network (L2), router forwards packets by IP between networks (L3), gateway translates between dissimilar protocols — and in the cloud every one of them is now software: `cni0` is the switch, the veth pair is the cable, and the node is the router.

**Three-sentence beginner explanation:**
Network devices come in a ladder, and each one is smarter than the last because it reads one more layer of the packet: a hub just copies electrical signals to every port, a switch reads the hardware (MAC) address so it can send data to only the right port, and a router reads the IP address so it can pass traffic between entirely separate networks. A gateway is the special one that translates when two networks don't even speak the same language, and "default gateway" is just the everyday name for the router your computer sends outside traffic to. In Kubernetes you use software copies of all of these — the Linux bridge `cni0` is a switch for the pods on a node, the veth pair is the virtual cable connecting each pod to it, and the node itself acts as a router whenever traffic leaves the pod's subnet.

**Sub-parts mapped back to the one core idea:**
- *Repeater regenerates a signal / hub floods to all ports* → the L1 "just move bits, read no address" rung.
- *Bridge filters by MAC / switch = multiport bridge with a MAC table* → the L2 "forward frames by MAC within one network" rung.
- *Router routes between networks by IP, decrements TTL* → the L3 "forward packets by IP between different networks" rung.
- *Gateway = protocol translator* → the top of the ladder, "translate between dissimilar networks."
- *cni0/docker0 = software switch, veth = cable, node = router, hypervisor vSwitch* → the whole ladder, virtualized, running in your cluster.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 3** (pod routes vs node routes vs `ip_forward`) — nothing makes "switch within a subnet, router between subnets" click like seeing your pod's `default via` gateway next to your node's routes for every other node's pod CIDR. Then **Rung 7, Example 2** to watch a switch's learned MAC table and a router's TTL decrement in the same breath — the two devices, side by side, doing exactly what their OSI layer says they must.

---

## Related concepts

- [MAC Addresses, Switching & ARP](05-mac-addresses-switching-arp.md) — the L2 machinery behind the switch/bridge: MAC learning, the CAM table, and ARP.
- [OSI & TCP/IP Models](06-osi-and-tcpip-models.md) — the layer ladder that defines every device in this file.
- [Routing & Forwarding](08-routing-and-forwarding.md) — the router's L3 job in depth: routing tables, next hops, TTL, and traceroute.
- [Container & Docker Networking](23-container-docker-networking.md) — `docker0` as a bridge, veth pairs, and port mapping in the container world.
- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — how `cni0`, veth cables, and the node-as-router are assembled by the CNI.
- [AWS VPC](20-aws-vpc.md) — the cloud fabric of route tables, IGW/NAT Gateway, and the hypervisor virtual switch your nodes plug into.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A hub and a switch both have many ports and connect machines on one LAN. Name the ONE piece of information the switch uses that the hub ignores — and what that lets the switch stop doing.

**A:** The switch reads the **destination MAC address** in each frame (L2), which the hub — a pure L1 multiport repeater — completely ignores. Combined with its learned MAC address table (`MAC → port`), that lets the switch stop **flooding every frame out all ports**: it unicasts each frame to exactly the one port where the destination lives. The consequence is that collision domains collapse from one big shared one to one per port, so machines no longer shout over each other and every host gets full bandwidth.

### Before Rung 4
**Q:** Two pods on the *same* node talk entirely through `cni0`, never touching the node's routing table — which classic device is `cni0` playing, and at which OSI layer? When the pods move to *different* nodes, which device takes over and which layer does the path jump to?

**A:** For same-node traffic, `cni0` (the Linux bridge) is playing the **switch** — a multiport bridge with a MAC forwarding database that unicasts frames between the pods' veth ports — so the whole data path stays at **Layer 2**, forwarding by destination MAC within the one pod subnet. When the pods are on different nodes they sit on *different* pod subnets, so the **node acting as a router** takes over: the frame goes up to the node's kernel routing table, which forwards by destination IP, decrements TTL, and builds a brand-new frame for the next hop — the path jumps to **Layer 3**. Switch within a network, router between networks.

### Before Rung 5
**Q:** "It reads the destination address, keeps a table, and sends traffic out exactly one port" describes both a switch and a router. What ONE follow-up question tells you which it is, and what does each answer imply about the OSI layer?

**A:** Ask: **"Which address does it read — MAC or IP?"** (equivalently: "does its table map MACs to ports, or IP prefixes to next hops?"). If it forwards by **destination MAC** using a MAC/CAM table, it's a **switch** operating at **L2**, moving frames *within* one network/broadcast domain. If it forwards by **destination IP** using a routing table with longest-prefix match — rewriting MACs and decrementing TTL as it goes — it's a **router** operating at **L3**, moving packets *between* different networks. The layer the device reads is its entire personality.

### Before Rung 6
**Q:** In the trace, the IPs never changed but TTL dropped 64 → 63 and the MACs were rewritten. Which device type is responsible for the TTL drop, and why does that device NOT appear on the same-node path?

**A:** The **router** — here, Node 1 acting as the virtual L3 router for the pod CIDR — is what decrements TTL: at every L3 hop the router strips the old frame, decrements TTL/hop-limit by 1, and builds a brand-new frame with fresh MACs (dropping the packet and sending ICMP Time Exceeded if TTL hits 0). It doesn't appear on the same-node path because two pods on the same node share the same pod subnet, so the frame is handled purely at L2 by the `cni0` software switch, which forwards by MAC and never touches the IP header — switches don't decrement TTL, only routers do.

### Before Rung 7
**Q:** A single flat subnet where hosts collide constantly but there are no broadcast storms — do you add a switch, a router, or a gateway, and which domain does your choice fix while leaving the other untouched?

**A:** Add a **switch**. Collisions are an L1/L2 shared-medium problem, and a switch **breaks up the collision domain** — from one big shared one (hub-style) into one collision domain per port, which with full-duplex links eliminates collisions entirely. It leaves the **broadcast domain** untouched: a plain switch still forwards broadcasts to all ports, so the whole subnet remains one broadcast domain — which is fine here, since there are no broadcast storms. A router (or VLAN) is what splits broadcast domains, and there's no cross-network or protocol-translation job to justify a router or gateway; per Rung 6's rule, choose the lowest-layer device that can still make the decision you need.
