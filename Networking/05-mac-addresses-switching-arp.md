# MAC Addresses, Switching & ARP
### The Layer-2 world beneath your pod IPs — hardware identity, the switch that learns, and the whisper that turns an IP into a MAC

---

## 🎯 Rung 0 — The Setup

You are a cloud/Kubernetes platform engineer. You live at Layer 3 and above: pod IPs, `ClusterIP` Services, VPC route tables, Security Groups. When two pods talk, you think "pod A's IP reaches pod B's IP, done." You have never once thought about the *hardware address* underneath — and honestly, why would you? EKS hides it. Flannel hides it. The kernel hides it.

Then this lands on your desk:

> Two pods on the **same node** talk to each other perfectly. The moment one gets rescheduled to a **different node**, latency triples and you see occasional drops. Someone in the incident channel says "sounds like it fell off the L2 path onto the overlay." You nod like you understand. You do not understand.

To understand that sentence — "same-node is L2 switching, cross-node is L3 overlay" — you have to go *down* one floor from where you're comfortable. Down to **Layer 2**, the **data link layer**, where devices are identified not by IP but by a **MAC address**, where the forwarding device is not a router but a **switch**, and where the glue that connects "the IP I know" to "the MAC I need" is a tiny, ancient, broadcast-based protocol called **ARP**.

**What you already know that will carry you:**
- An **IP address** is a logical, routable address (from `02-ip-addressing.md`). Good — MAC is the *other* address, the physical one, and you'll learn how they cooperate.
- A **subnet / broadcast domain** is a group of hosts that can reach each other without a router (from `03-subnetting-and-cidr.md`). Hold onto "broadcast domain" — ARP lives and dies inside it.
- Pods have IPs and a **veth** interface (from `24-kubernetes-pod-networking-cni.md`). Every one of those veths also has a MAC. You just never looked.

By the end of this file, the incident sentence will read like plain English.

---

## 🔥 Rung 1 — The Pain

Rewind to a network with **no switching and no ARP**. Picture the earliest shared-media LANs — a bunch of machines all wired onto **one shared cable** (a **hub**, or literally a single coax segment).

**Problem 1: The hub is a screaming room.** A **hub** is a dumb electrical repeater. When machine A sends a frame, the hub copies those electrical signals out **every other port**. Every machine on the segment receives *every* frame and must inspect it to decide "is this for me?" Ten machines chatting means everyone hears everyone. This is one giant **collision domain** — if two machines transmit at once, their signals collide and both must back off and retry. Add more machines and the LAN grinds: more collisions, more retries, less useful throughput. It doesn't scale.

**Problem 2: How do you even address a specific machine on the wire?** IP is a *logical* concept the OS invented. But the actual network card — the NIC — pushing electrical or radio signals needs a *physical* identity so a frame can say "this is FOR the card with hardware ID X." Without a hardware address baked into every NIC, the wire has no notion of "you specifically."

**Problem 3: You know the IP, but the wire speaks MAC.** Say your app wants to reach `10.0.1.7`. The NIC can't send "to 10.0.1.7" — the Ethernet frame header has no field for IP; it has a field for **destination MAC**. So there's a translation gap: *I have a Layer-3 address, I need a Layer-2 address for the same host.* Something must resolve one to the other. Without it, your beautifully routed IP packet has nowhere to physically go on the local wire.

**Who felt this pain most?** Anyone building a LAN bigger than a few machines. The fix for Problem 1 was the **switch** — a device smart enough to send each frame only where it needs to go. The fix for Problems 2 and 3 was **MAC addressing** plus **ARP** — a permanent hardware identity per NIC, and a protocol to map IP→MAC on the local segment.

**Why you, the cloud engineer, still feel it:** your Kubernetes node runs a **software switch** — the Linux bridge `cni0` (Flannel) or `docker0` (Docker) — and it does *exactly* the same MAC-learning and ARP dance, in software, millions of times a day, for your pods. When same-node pod traffic is fast and cross-node is slower, you are watching the boundary between "switched at Layer 2" and "routed at Layer 3." This isn't history. It's running inside your cluster right now.

> **Check yourself before Rung 2:** If a hub broadcasts every frame to every port, what specific piece of information would a *smarter* device need to remember so it could send a frame out *only one* port? (Name the mapping.)

---

## 💡 Rung 2 — The One Idea

Here is the whole file in one sentence. Write it on a sticky note:

> **A MAC address is a device's permanent Layer-2 hardware identity; a switch forwards frames by learning which MAC lives on which port; and ARP is the local-segment lookup that turns the IP you *know* into the MAC you *need* — because the IP stays constant end-to-end while the MAC changes at every single hop.**

Memorize that. Everything else is derivable:

- **Why does ARP exist?** Because the frame header carries MACs, not IPs, but your app only knows the IP → you need a translator. (Derived.)
- **Why is a switch better than a hub?** Because "learning which MAC lives on which port" lets it forward to one port instead of all → smaller collision domains. (Derived.)
- **Why does the MAC change every hop but the IP doesn't?** Because MAC is *local delivery* (this wire, this segment) and IP is *end-to-end delivery* (source to final destination). Each hop is a new local wire, so a new local MAC pair; the IP is the unchanging "who I ultimately want." (Derived.)
- **Why is same-node pod traffic L2 and cross-node L3?** Because on one node the pods share one virtual switch (the bridge) — pure Layer-2 forwarding — but reaching another node crosses a *router boundary*, which is Layer-3. (Derived.)

One sentence. Four derivations. That's the ladder.

> **Memorize the core sentence before you continue.** If you can't recite it, re-read Rung 2.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> This section has four moving parts, plus a look at where they run inside a cluster. In everyday terms:
>
> **Part 1 — The serial number.** Besides its internet address, every network plug (each Wi-Fi chip or cable jack) has a permanent factory serial number, called a MAC address. It's written as twelve letters-and-digits; the first half says who manufactured it, the second half which exact unit it is. Note: it belongs to the *plug*, not the whole computer — a laptop with Wi-Fi and a cable jack has two. One special "serial number" made of all F's means "everyone in the room."
>
> **Part 2 — Envelopes inside envelopes.** Your data travels double-wrapped. The inner envelope (the "packet") carries the internet addresses of the true sender and final receiver — it stays sealed for the whole journey. The outer envelope (the "frame") carries the serial numbers for just *this one leg* of the trip — and it gets torn off and rewritten at every relay point, like a courier re-bagging a parcel at each depot while the parcel itself is untouched.
>
> **Part 3 — The smart mailroom.** A "switch" is a box with many sockets that delivers outer envelopes within one room. It's smart because it *learns*: every time an envelope arrives, it notes "this sender's serial number lives on socket 3." Then future mail for that serial number goes to socket 3 only — unlike its dumb ancestor, the "hub," which photocopied every letter to everyone (so people constantly talked over each other). One catch: a switch still passes "shout to everyone" messages to every socket, so it quiets the crosstalk but doesn't shrink the shouting-room; only a router (or a room divider called a VLAN) does that.
>
> **Part 4 — The lookup shout (ARP).** You know a machine's internet address but not its serial number — and local delivery needs the serial number. So your computer shouts to the whole room: "Who has this address?" Only the owner answers, quietly and directly, with its serial number. Your computer then writes it in a little contact book so it never has to shout again for a while. Two extra rules: if the destination is *outside* your room, you don't shout for it — you ask for the doorman's (the router's) serial number and hand him the letter; and a machine can also shout unprompted, "attention, this address now belongs to me!" — used when one machine takes over another's address.
>
> **The Kubernetes bit.** Inside each cluster server, all of this runs in software: the mini-programs ("pods") each have their own plug with a serial number, and a virtual mailroom connects them. That's why two pods on the same server talk fast (same room, direct delivery) while pods on different servers are slower (mail must go out through the doorman and across town).

*Now the original technical deep-dive — the same ideas, in precise form:*

Let's take the machine apart. There are four moving parts: the **MAC address** itself, the **frame** that carries it, the **switch** that learns and forwards, and **ARP** that fills in the missing MAC.

### Part 1 — The MAC address: 48 bits of hardware identity

A **MAC address** (Media Access Control address) is a **48-bit** number, written as **12 hexadecimal digits**, usually grouped in pairs:

```text
   02:42:ac:11:00:02
   └─┬─┘ └────┬─────┘
   OUI (24 bits)   NIC-specific (24 bits)
   "who made it"   "which card"
```

- **48 bits = 6 bytes = 12 hex digits.** Each hex digit is 4 bits; 12 × 4 = 48. Lock that in.
- The first 24 bits are the **OUI** (Organizationally Unique Identifier) — a vendor code (Cisco, Intel, VMware…). The last 24 bits are assigned by the vendor per card.
- It is **per-interface, NOT per-device.** Your laptop's Wi-Fi NIC and Ethernet NIC have *different* MACs. A server with four NICs has four MACs. A pod's veth has its own MAC. "One device, one MAC" is a beginner's misconception — kill it now.
- Traditionally it's "burned in" to the NIC at manufacture (also called the **BIA**, Burned-In Address), but virtual interfaces (veth, bridges, `docker0`) get MACs *generated* by software — often starting with `02:` because that bit marks a locally-administered address.

Special MAC values you must recognize:
- **`ff:ff:ff:ff:ff:ff`** — the **broadcast MAC**. A frame sent here goes to *every* device in the broadcast domain. ARP requests use this.
- **Unicast** — a normal single-target MAC (the low bit of the first byte is 0).
- **Multicast** — group delivery (low bit of first byte is 1).

### Part 2 — Frames vs packets: the nested envelopes

This is the single most clarifying idea in Layer 2. Your data is wrapped in **nested envelopes**, each layer adding its own header:

```text
   ┌─────────────────────────────────────────────────────────┐
   │ ETHERNET FRAME  (Layer 2 — the "wire" envelope)          │
   │  ┌─────────────┬─────────────┬──────────────────────┐    │
   │  │ Dst MAC     │ Src MAC     │  ...payload...        │    │
   │  │ (6 bytes)   │ (6 bytes)   │                       │    │
   │  │             │             │  ┌─────────────────┐  │    │
   │  │             │             │  │ IP PACKET (L3)  │  │    │
   │  │             │             │  │ ┌────┬────┬───┐ │  │    │
   │  │             │             │  │ │SrcIP DstIP data│ │  │    │
   │  │             │             │  │ └────┴────┴───┘ │  │    │
   │  │             │             │  └─────────────────┘  │    │
   │  └─────────────┴─────────────┴──────────────────────┘    │
   │                                            + FCS (CRC)    │
   └─────────────────────────────────────────────────────────┘
```

- **Frame** = the Layer-2 **PDU** (Protocol Data Unit). Header carries **MAC** addresses. This is what actually travels on the wire / through the switch.
- **Packet** = the Layer-3 **PDU**. Header carries **IP** addresses. It rides *inside* the frame as payload.
- Vocabulary rule of thumb: **switches think in frames, routers think in packets.** When you hear "frame," think MAC/Layer 2. When you hear "packet," think IP/Layer 3.
- The frame also carries a trailing **FCS** (Frame Check Sequence, a CRC) so the receiver can detect corruption.

The killer insight: **the IP packet inside is untouched hop to hop, but the frame around it is stripped and rebuilt at every hop.** Each router receives a frame, throws away the L2 header, looks at the IP, decides the next hop, and wraps the *same* IP packet in a *brand-new* frame with new MAC addresses. (TTL/hop-limit in the IP header is the one field that does decrement — see `08-routing-and-forwarding.md`.)

### Part 3 — The switch: a device that learns

A **switch** is a Layer-2 device with many ports. Its whole job: forward frames to the *right port only*. It does this with a **MAC address table** (also called a **CAM table** — Content-Addressable Memory), a simple map of `MAC → port`.

How it learns (this is beautiful and it's just two rules):

```text
   SWITCH MAC-ADDRESS-TABLE (learned over time)
   ┌───────────────────┬──────┐
   │ MAC               │ Port │
   ├───────────────────┼──────┤
   │ aa:aa:aa:00:00:01 │  1   │   ← learned from A's source MAC
   │ bb:bb:bb:00:00:02 │  2   │   ← learned from B's source MAC
   │ cc:cc:cc:00:00:03 │  3   │
   └───────────────────┴──────┘

   RULE 1 (LEARN):   Every frame arriving on a port → record
                     its SOURCE MAC against that port.
   RULE 2 (FORWARD): Look up the DESTINATION MAC.
                     • Known  → send out that ONE port (unicast forward)
                     • Unknown→ FLOOD out all ports except the one
                                it came in on (behaves like a hub, once)
                     • Broadcast (ff:ff:ff:ff:ff:ff) → flood always
```

Contrast with a **hub**: a hub has no table and no brain. It floods *every* frame out *every* port, *always*. The switch replaced the hub precisely because Rule 2 lets it stop flooding once it has learned.

**Collision domain vs broadcast domain** — the two "domains" people confuse:

```text
   HUB: one big collision domain          SWITCH: each port = own collision domain
   ┌──────────────────────────┐           ┌──────────────────────────┐
   │  A  B  C  D all collide   │           │ [A]  [B]  [C]  [D]        │
   │  when two talk at once    │           │  no collisions between    │
   └──────────────────────────┘           │  ports; full-duplex       │
                                          └──────────────────────────┘
```

- **Collision domain** = the set of interfaces that can collide with each other on shared media. A hub = one big collision domain. A switch = **one collision domain per port** (so, effectively none, with modern full-duplex links). This is *why* switches scale and hubs don't.
- **Broadcast domain** = the set of devices a broadcast frame (`ff:ff:ff:ff:ff:ff`) reaches. A switch **forwards broadcasts to all ports**, so a plain switch does **not** break up a broadcast domain — the whole switch (and everything plugged into it) is **one broadcast domain**. What *does* break a broadcast domain? A **router** (Layer 3) — or a **VLAN** (`16-vlans-and-segmentation.md`), which slices one physical switch into several logical broadcast domains.

Memory hook: **a switch breaks up collision domains; a router (or VLAN) breaks up broadcast domains.**

### Part 4 — ARP: turning an IP into a MAC

Now the glue. Your app wants to send to IP `10.0.1.7`, on the local subnet. The kernel builds an IP packet. To put it in a frame, it needs the **destination MAC** for `10.0.1.7`. It doesn't know it. Enter **ARP** (Address Resolution Protocol).

```text
   ARP REQUEST  (broadcast — "shouted to the whole room")
   ┌───────────────────────────────────────────────────────────┐
   │ Frame Dst MAC: ff:ff:ff:ff:ff:ff   (everybody hears this)  │
   │ Frame Src MAC: aa:aa:aa:00:00:01   (me, the asker)         │
   │ ARP payload:  "Who has 10.0.1.7? Tell 10.0.1.5"           │
   └───────────────────────────────────────────────────────────┘
                          │  switch floods the broadcast
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
     10.0.1.6          10.0.1.7          10.0.1.8
    "not me,          "THAT'S ME!"      "not me,
     ignore"           replies →         ignore"

   ARP REPLY  (unicast — whispered back to just the asker)
   ┌───────────────────────────────────────────────────────────┐
   │ Frame Dst MAC: aa:aa:aa:00:00:01  (straight back to asker) │
   │ Frame Src MAC: dd:dd:dd:00:00:07  (10.0.1.7's real MAC)    │
   │ ARP payload:  "10.0.1.7 is at dd:dd:dd:00:00:07"          │
   └───────────────────────────────────────────────────────────┘
```

The two-line rhythm to memorize: **ARP request is broadcast (ask everyone), ARP reply is unicast (only the owner answers, straight back).**

And crucially, the asker **caches** the answer in its **ARP table** (a.k.a. **neighbor table**) so it never has to ask again for a while:

```text
   ARP CACHE on 10.0.1.5
   ┌───────────┬───────────────────┬───────────┐
   │ IP        │ MAC               │ State     │
   ├───────────┼───────────────────┼───────────┤
   │ 10.0.1.7  │ dd:dd:dd:00:00:07 │ REACHABLE │  ← just learned
   │ 10.0.1.1  │ ee:ee:ee:00:00:01 │ STALE     │  ← the gateway
   └───────────┴───────────────────┴───────────┘
```

Two more essential rules:

1. **ARP only works inside the local broadcast domain (same subnet).** If the destination IP is on a *different* subnet, the host does NOT ARP for the destination — it ARPs for the **default gateway's** IP, and sends the frame to the *router's* MAC. The router then handles getting it closer. This is the mechanism behind "MAC changes every hop": on your wire, the destination MAC is the *gateway*, not the far-away server.

2. **Gratuitous ARP** — an *unsolicited* ARP announcement: "Hey everyone, IP X is now at MAC Y" that nobody asked for. Uses: (a) detect duplicate IPs on boot, (b) **fail over a virtual IP** — when a standby takes over an IP, it blasts a gratuitous ARP so every switch and host updates its table to the new MAC immediately. This is *exactly* how cloud load balancers, keepalived/VRRP, and floating IPs move an address between machines without waiting for caches to expire.

### The Kubernetes picture — where this ALL runs in software

Everything above happens inside your node, in the kernel, virtually:

```text
                       ONE KUBERNETES NODE
   ┌──────────────────────────────────────────────────────────────┐
   │                                                                │
   │   Pod A (10.244.1.5)              Pod B (10.244.1.6)          │
   │   ┌─────────────┐                 ┌─────────────┐             │
   │   │ eth0        │                 │ eth0        │             │
   │   │ MAC:aa..05  │                 │ MAC:bb..06  │             │
   │   └──────┬──────┘                 └──────┬──────┘             │
   │      veth│(host end,MAC)            veth │(host end,MAC)       │
   │          │                              │                     │
   │      ┌───┴──────────────────────────────┴───┐                 │
   │      │   cni0  — the Linux BRIDGE            │  ← a SOFTWARE   │
   │      │   (a virtual SWITCH with a MAC table) │     SWITCH      │
   │      └──────────────────┬───────────────────┘                 │
   │                         │ eth0 (node NIC, real MAC)           │
   └─────────────────────────┼──────────────────────────────────────┘
                             ▼
                    to VPC / other nodes (Layer 3 / overlay)
```

- Every **pod veth** interface has a MAC (`ip link show` inside the pod shows it).
- The **Linux bridge** `cni0` (or `docker0`) **is a virtual switch** — it maintains a MAC table (`bridge fdb show`) and forwards pod frames port-to-port exactly like a hardware switch.
- **Same-node Pod A → Pod B:** both are on `cni0`, same subnet, same broadcast domain. Pod A **ARPs** for Pod B's IP *within the bridge*, gets Pod B's veth MAC, and the bridge switches the frame directly. **Pure Layer 2.** Fast. No routing.
- **Cross-node Pod A → Pod C (other node):** Pod C's IP is on a *different node's* pod subnet — a different Layer-3 hop. Pod A ARPs for its **gateway** (the bridge/`cni0` IP acting as router), the frame goes up to the node's routing stack, then across the VPC or through an **overlay** (VXLAN encapsulation, `16-vlans-and-segmentation.md`) to the far node. **Layer 3.** More work.

*That* is the incident sentence from Rung 0, fully unpacked. Same-node = L2 switching on the bridge. Cross-node = L3/overlay.

> **Check yourself before Rung 4:** Your pod sends to an IP in a *different* pod subnet on another node. Whose MAC goes in the destination field of the *first* frame that leaves the pod — the far pod's, or something else's? Why?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **MAC address** | A 48-bit / 12-hex-digit hardware address, per NIC | Layer-2 identity; the Src/Dst fields of a frame |
| **OUI** | First 24 bits of a MAC = vendor code | Identifies who made the NIC |
| **Frame** | The Layer-2 PDU; carries MAC headers + FCS | What travels on the wire; what a switch forwards |
| **Packet** | The Layer-3 PDU; carries IP headers | Rides *inside* the frame as payload |
| **PDU** | Protocol Data Unit — the "unit" at a given layer | Frame (L2), Packet (L3), Segment (L4) |
| **Switch** | Layer-2 device that forwards frames per-port | Learns MAC→port, forwards to one port |
| **Hub** | Dumb repeater; floods every frame everywhere | The thing switches replaced |
| **MAC address table / CAM table** | The switch's `MAC → port` map | Built by the LEARN rule, used by FORWARD |
| **Flooding** | Sending a frame out all ports but the source | What a switch does for unknown/broadcast dst |
| **Collision domain** | Set of interfaces that can collide on shared media | Hub = 1 big; switch = 1 per port |
| **Broadcast domain** | Set of devices a broadcast frame reaches | Whole switch = 1; broken by router or VLAN |
| **ARP** | Address Resolution Protocol: IP → MAC on local segment | Fills the missing destination MAC for a frame |
| **ARP request** | "Who has this IP?" — sent as a **broadcast** | Frame dst = `ff:ff:ff:ff:ff:ff` |
| **ARP reply** | "That IP is at this MAC" — sent as **unicast** | Frame dst = the asker's MAC |
| **ARP cache / neighbor table** | Local `IP → MAC` store, time-limited | Avoids re-ARPing every packet |
| **Gratuitous ARP** | Unsolicited "IP X is now at MAC Y" announcement | Duplicate-IP detection & VIP failover |
| **Broadcast MAC** | `ff:ff:ff:ff:ff:ff` — reaches everyone in the domain | Destination of every ARP request |
| **veth** | Virtual Ethernet pair connecting pod to bridge | Each end has its own MAC |
| **Linux bridge (cni0/docker0)** | A software switch inside the node | Forwards pod frames; has a MAC table |
| **Default gateway** | The router IP for off-subnet destinations | What you ARP for when dst is remote |

**"Same kind of thing, different names" — don't get fooled:**
- **MAC address table = CAM table = forwarding database (`fdb`)** — the switch's `MAC→port` map, three names.
- **ARP cache = ARP table = neighbor table = neighbor cache** — the host's `IP→MAC` map. On Linux you view it with `ip neigh` (the modern name is literally "neighbor").
- **Frame = Layer-2 PDU = "what's on the wire."** **Packet = Layer-3 PDU = "the IP unit inside."** People say "packet" loosely for everything; be precise here.
- **Switch = bridge** — a Linux **bridge** is genuinely a **multi-port switch**; the terms are used interchangeably in the container world (`cni0` is called a bridge but behaves as a switch).
- **Hardware address = physical address = link-layer address = MAC** — all the same 48-bit thing.
- **Broadcast MAC = `ff:ff:ff:ff:ff:ff` = "all-ones" = L2 broadcast** — one address, many nicknames.

> **Check yourself before Rung 5:** Someone says "the switch flooded the packet to all ports." Two words in that sentence are technically imprecise for Layer 2. Which two, and what should they be?

---

## 🔬 Rung 5 — The Trace

Let's follow **one** concrete action end to end: **Pod A wants to `curl` Pod B, both on the same node, and A's ARP cache is empty.** IPs: A = `10.244.1.5`, B = `10.244.1.6`, both on the bridge `cni0` (same subnet `10.244.1.0/24`).

```text
STEP 1  App in Pod A calls curl 10.244.1.6:80
        Kernel: "10.244.1.6 is in MY subnet (10.244.1.0/24) →
        deliver locally, I need B's MAC. Check ARP cache… EMPTY."

STEP 2  Kernel emits an ARP REQUEST (broadcast):
        [Dst ff:ff:ff:ff:ff:ff | Src aa:..:05 | "Who has 10.244.1.6?"]
        Leaves Pod A's eth0 → through the veth → arrives at cni0.

STEP 3  cni0 (the virtual switch) sees a BROADCAST dst → FLOODS it
        out every port except the one it arrived on.
        (It also LEARNS: aa:..:05 lives on Pod A's veth port.)

STEP 4  Pod B receives the ARP request. "10.244.1.6 is ME."
        Pod B sends an ARP REPLY (unicast):
        [Dst aa:..:05 | Src bb:..:06 | "10.244.1.6 is at bb:..:06"]

STEP 5  cni0 sees dst aa:..:05, looks up its MAC table → known,
        Pod A's port → forwards out that ONE port. No flood.
        (It also LEARNS: bb:..:06 lives on Pod B's veth port.)

STEP 6  Pod A caches it:  ip neigh →  10.244.1.6  bb:..:06  REACHABLE
        NOW the real work: build the frame for the TCP SYN:
        [Dst bb:..:06 | Src aa:..:05 | IP 10.244.1.5→10.244.1.6 | SYN]

STEP 7  cni0 switches that frame straight to Pod B's port (unicast).
        TCP 3-way handshake completes (SYN → SYN-ACK → ACK),
        curl gets its HTTP 200. Done — all at LAYER 2.
```

Visual of the whole trace, compressed:

```text
   Pod A                cni0 (switch)                 Pod B
   10.244.1.5                                         10.244.1.6
   aa:..:05                                           bb:..:06
      │                                                  │
      │ 1-2  ARP req (bcast) ──► FLOOD ─────────────────►│  "who has .6?"
      │                                                  │
      │◄──────────────── 4-5  ARP reply (unicast) ───────│  ".6 is bb:..:06"
      │                                                  │
      │ 6-7  SYN  ─────────► switch (unicast) ──────────►│
      │◄──────────────────── SYN-ACK ────────────────────│
      │ ─────── ACK ────────────────────────────────────►│
      │                  HTTP 200 OK                      │
```

Notice the shape: **one broadcast (the ARP request), then everything else is unicast.** The expensive "shout to the room" happens exactly once, then the cache makes it silent. And note what did NOT happen: **no router, no IP TTL decrement, no overlay.** The IP packet's src/dst never changed and never left Layer 2 forwarding. That is what "same-node pod-to-pod is L2 switching" *means* in motion.

(If B were on another node, Step 1 would differ: the kernel would see B's IP as *off-subnet*, ARP for the **gateway** instead, and the frame's destination MAC would be the **router/bridge gateway**, not Pod B — the packet would then be routed/encapsulated across nodes, decrementing TTL at each L3 hop while the IP endpoints stayed constant.)

> **Check yourself before Rung 6:** In the trace, how many times did a *broadcast* frame cross the switch, and why would adding 500 more pods to this bridge eventually make that a scaling concern?

---

## ⚖️ Rung 6 — The Contrast

The alternative to a **switch** is a **hub** (and, one layer up, the alternative to "flat L2 switching" is "L3 routing"). Let's line them up.

| Dimension | **Hub (Layer 1)** | **Switch (Layer 2)** | **Router (Layer 3)** |
|---|---|---|---|
| Forwards based on | Nothing — floods all ports | **Destination MAC** | **Destination IP** |
| Unit it handles | Bits/signals | **Frames** | **Packets** |
| Keeps a table? | No | **MAC → port** | **IP prefix → next hop** |
| Collision domains | One big shared one | **One per port** (isolates) | One per port |
| Broadcast domains | One | **One** (does NOT split) | **Splits them** (one per interface) |
| Changes the address? | No | Rewrites frame MACs per hop | Also decrements IP TTL |
| Scales to large nets? | No | Yes, within one subnet | Yes, across subnets |
| Cloud/K8s analog | (obsolete) | **Linux bridge `cni0`/`docker0`** | **kube-proxy / node routing / VPC route table** |

**What a switch can do that a hub cannot:** send a frame to *one* port instead of all, isolating collisions and giving every device full bandwidth. **What a switch canNOT do that a router can:** cross between subnets or shrink a broadcast domain — a switch is "flat," everything on it is one broadcast domain. That's why you can't build the whole internet out of switches: broadcasts (ARP among them) would drown everything. You need routers (and VLANs) to segment.

**When would you NOT need to care about MAC/switch/ARP?** When traffic is purely *routed* across L3 boundaries and you're debugging above Layer 3 — e.g., a `ClusterIP` DNAT issue in kube-proxy, or a Security Group blocking port 443. ARP won't be your bug there. **But** the moment you see "works same-node, breaks cross-node," "duplicate IP," "stale entry after failover," or "packets to the gateway vanish," you are back in MAC/ARP territory.

**One sentence — why switching/ARP over hubs:** *You switch (not hub) because forwarding a frame to exactly one learned port instead of shouting it everywhere is the difference between a LAN that scales and one that collapses — and ARP is the price of admission for talking to any host whose MAC you don't yet know.*

> **Check yourself before Rung 7:** You add a plain (non-VLAN) switch to relieve a congested LAN and collisions vanish — but a broadcast storm still floods the whole LAN. Which "domain" did the switch fix and which did it leave untouched?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *before* running the command. The gap between what you predicted and what you saw is where the learning is.

### Example 1 — Normal case: read your own MAC and your neighbor cache

**Prediction:** *If I run `ip link show`, then each interface will list a 12-hex-digit MAC after `link/ether`, and my loopback (`lo`) will show `00:00:00:00:00:00` BECAUSE loopback never touches real L2 media so it has no meaningful hardware address.* And *if I then run `ip neigh`, I'll see cached IP→MAC entries for hosts I've recently talked to, including my default gateway.*

```bash
# Show interfaces and their MAC addresses
ip link show
# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
#     link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff   ← 48-bit MAC, note brd = broadcast MAC
# 1: lo: <LOOPBACK,UP,LOWER_UP> ...
#     link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00 ← loopback: all zeros

# Show the ARP / neighbor cache (modern tool)
ip neigh
# 172.17.0.1 dev eth0 lladdr 02:42:xx:xx:xx:xx REACHABLE   ← the gateway, resolved
# 172.17.0.5 dev eth0 lladdr 02:42:yy:yy:yy:yy STALE       ← a peer, entry aging out

# The old-school equivalent (still works on most systems):
arp -a
# gateway (172.17.0.1) at 02:42:xx:xx:xx:xx [ether] on eth0
```

**Verify:** Count the hex digits after `link/ether` — exactly 12 (6 pairs = 48 bits). If `lo` showed a *non-zero* MAC, your mental model of "loopback has no wire" would need revising (it wouldn't — this confirms the model). If `ip neigh` is empty, you simply haven't talked to any L2 neighbor recently; `ping` your gateway once and re-check to force an entry to appear.

### Example 2 — Watch ARP actually happen (edge/observability case): flush the cache and capture the request/reply

**Prediction:** *If I delete my gateway's ARP entry and then ping it while capturing ARP with tcpdump, then I'll see EXACTLY the Rung-3 pattern — a broadcast "who-has" request followed by a unicast reply — BECAUSE the empty cache forces a fresh resolution before any ICMP can be sent.*

```bash
# 1. Find and delete the gateway's neighbor entry (force a cache miss)
GW=$(ip route | awk '/default/ {print $3; exit}')
sudo ip neigh del "$GW" dev eth0        # flush just this entry

# 2. In one terminal, capture only ARP traffic
sudo tcpdump -n -i eth0 arp
# (leave running)

# 3. In another terminal, trigger resolution
ping -c1 "$GW"

# Expected tcpdump output:
# ARP, Request who-has 172.17.0.1 tell 172.17.0.2, length 28   ← BROADCAST request
# ARP, Reply 172.17.0.1 is-at 02:42:xx:xx:xx:xx, length 28     ← UNICAST reply
```

**Verify:** You should see **request first, reply second**, and only THEN the ICMP echo. The request is a broadcast (destination `ff:ff:ff:ff:ff:ff` — add `-e` to tcpdump to print frame MACs and confirm), the reply is unicast straight back to you. If you see the ICMP echo with *no* preceding ARP, the entry wasn't actually flushed (re-run step 1). This is the whole of Rung 3 and Rung 5 happening in front of you in real packets.

### Example 3 — Kubernetes case: prove same-node pods share an L2 bridge

**Prediction:** *If I exec into a pod and inspect its interface and neighbor table, then its `eth0` will have its own MAC and its ARP cache will resolve a same-node peer pod directly to that peer's MAC (no gateway in between) BECAUSE both pods hang off the same `cni0` bridge and are in the same pod subnet — pure Layer-2 switching.* Cross-node, the peer would resolve via the gateway instead.

```bash
# Two pods; get their IPs and which node each is on
kubectl get pods -o wide
# NAME    IP            NODE
# app-a   10.244.1.5    ip-10-0-1-20   ← same node
# app-b   10.244.1.6    ip-10-0-1-20   ← same node

# Exec into pod A and look at its L2 world
kubectl exec -it app-a -- sh
  # inside the pod:
  ip link show eth0
  #   link/ether 5a:1c:... brd ff:ff:ff:ff:ff:ff   ← the pod's veth MAC

  ping -c1 10.244.1.6         # talk to same-node peer to populate ARP
  ip neigh
  # 10.244.1.6 dev eth0 lladdr 5a:2d:... REACHABLE  ← peer's MAC directly, L2!
  ip route
  # default via 10.244.1.1 dev eth0     ← the gateway (cni0) for OFF-subnet dst
  # 10.244.1.0/24 dev eth0 ...          ← ON-subnet = resolved by ARP, no gateway
  exit

# On the NODE itself, see the software switch's MAC table:
# (the bridge forwarding database — the CAM table of cni0)
sudo bridge fdb show br cni0 | head
# 5a:1c:... dev vethXXXX master cni0     ← pod A's MAC learned on its veth port
# 5a:2d:... dev vethYYYY master cni0     ← pod B's MAC learned on its veth port
```

**Verify:** In pod A's `ip neigh`, the same-node peer `10.244.1.6` resolves to the **peer pod's own MAC** — no gateway hop — confirming L2 switching on `cni0`. In `bridge fdb show`, each pod MAC appears against a distinct `veth…` port: that IS the switch's learned `MAC→port` table from Rung 3, running in software. Now schedule `app-b` onto a *different* node and repeat: `10.244.1.6` will no longer be a direct neighbor — traffic leaves via the `default via 10.244.1.1` gateway and gets routed/encapsulated across nodes. That contrast — direct MAC same-node vs gateway cross-node — is the Rung-0 incident, reproduced on demand.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
A MAC is a per-NIC 48-bit hardware address, a switch forwards frames by learning MAC→port, and ARP resolves an IP to a MAC on the local segment — because the IP is constant end-to-end while the MAC is rewritten at every hop.

**Three-sentence beginner explanation:**
Every network interface has a permanent 48-bit hardware ID called a MAC address, and data actually moving on a local wire is addressed by MAC, not IP. A switch is a device that learns which MAC is plugged into which port, so it can send each frame to just the right port instead of shouting it to everyone like an old hub. When your computer knows an IP but needs the matching MAC, it broadcasts an ARP request ("who has this IP?"), gets a unicast reply, and caches the answer — and in Kubernetes this exact dance happens in software inside each node's Linux bridge.

**Sub-parts mapped back to the one core idea:**
- *MAC is per-interface, 48-bit* → the "Layer-2 identity" the core sentence names.
- *Switch learns MAC→port, hub floods* → the "forwards frames by learning" clause.
- *ARP request broadcast / reply unicast / cached* → the "resolves the IP you know into the MAC you need" clause.
- *Frame (L2) vs packet (L3), MAC changes per hop, IP constant* → the "because" clause that ties it all together.
- *cni0 bridge = virtual switch, same-node L2 vs cross-node L3* → the whole idea, running in your cluster.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 2** (flush the ARP cache and capture request+reply with tcpdump) — nothing cements "broadcast ask, unicast answer, then cache" like watching the two frames appear in that order. Then **Rung 7, Example 3** to *feel* the same-node-L2 vs cross-node-L3 boundary that started this whole file.

---

## Related concepts

- [IP Addressing](02-ip-addressing.md) — the Layer-3 address ARP resolves *to* a MAC.
- [Subnetting & CIDR](03-subnetting-and-cidr.md) — defines the broadcast domain that bounds where ARP works.
- [OSI & TCP/IP Models](06-osi-and-tcpip-models.md) — where frames (L2) and packets (L3) sit, and encapsulation.
- [Routing & Forwarding](08-routing-and-forwarding.md) — what happens when the destination is off-subnet and the MAC becomes the gateway's.
- [VLANs & Segmentation](16-vlans-and-segmentation.md) — how one switch is sliced into multiple broadcast domains, and VXLAN overlays for cross-node pods.
- [Network Devices](13-network-devices.md) — hub vs switch vs bridge vs router and their OSI layers.
- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — veth pairs, the `cni0` bridge, and how pods get their L2/L3 plumbing.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If a hub broadcasts every frame to every port, what specific piece of information would a *smarter* device need to remember so it could send a frame out *only one* port? (Name the mapping.)

**A:** It needs to remember **which MAC address lives on which port** — the `MAC → port` mapping. That map is the switch's **MAC address table** (also called the CAM table or forwarding database). The switch builds it for free by watching the *source* MAC of every arriving frame and recording it against the arrival port (the LEARN rule); then, for each frame, it looks up the *destination* MAC and forwards out that one port instead of flooding everywhere (the FORWARD rule). Once the table is populated, the screaming-room hub behavior disappears.

### Before Rung 4
**Q:** Your pod sends to an IP in a *different* pod subnet on another node. Whose MAC goes in the destination field of the *first* frame that leaves the pod — the far pod's, or something else's? Why?

**A:** Something else's: the **default gateway's MAC** — on a Flannel-style node, the MAC of the `cni0` bridge IP (e.g. `10.244.1.1`) acting as the router. ARP only works inside the local broadcast domain, so when the kernel sees the destination IP is off-subnet, it does *not* ARP for the far pod — it ARPs for the gateway's IP and stamps the gateway's MAC into the frame. This is the "MAC changes every hop" rule in action: the MAC handles *local* delivery to the next hop on this wire, while the IP addresses inside the packet stay constant end-to-end as the packet is then routed (or VXLAN-encapsulated) across to the far node, where a brand-new frame is built with the far pod's MAC.

### Before Rung 5
**Q:** Someone says "the switch flooded the packet to all ports." Two words in that sentence are technically imprecise for Layer 2. Which two, and what should they be?

**A:** First, "**packet**" should be "**frame**": a switch is a Layer-2 device and forwards frames (the L2 PDU, addressed by MAC); a packet is the Layer-3 PDU riding inside — switches think in frames, routers think in packets. Second, "**all** ports" should be "all ports **except the one it arrived on**": flooding by definition excludes the source port, otherwise the frame would be reflected straight back at its sender. Precisely stated: "the switch flooded the frame out every port except the ingress port."

### Before Rung 6
**Q:** In the trace, how many times did a *broadcast* frame cross the switch, and why would adding 500 more pods to this bridge eventually make that a scaling concern?

**A:** Exactly **once** — the ARP request in Steps 2–3 (destination `ff:ff:ff:ff:ff:ff`, flooded by `cni0`). Everything after was unicast: the ARP reply, the SYN/SYN-ACK/ACK, and the HTTP exchange, because the answer was cached in the ARP table. The scaling concern: the entire bridge is **one broadcast domain**, and a switch always floods broadcasts to every port. With 500 more pods, every ARP request from any pod is delivered to and processed by all ~500 pods, and the total broadcast rate grows with the number of pods (more pods asking, more caches expiring and re-asking). A big flat L2 domain therefore drowns in ARP/broadcast noise — the very Rung-1 pain that routers and VLANs exist to bound.

### Before Rung 7
**Q:** You add a plain (non-VLAN) switch to a congested LAN and collisions vanish — but a broadcast storm still floods the whole LAN. Which "domain" did the switch fix, and which did it leave untouched?

**A:** The switch fixed the **collision domain**: instead of one big shared segment where any two simultaneous transmitters collide, each switch port becomes its own collision domain (effectively eliminating collisions on modern full-duplex links) — that's why the congestion vanished. It left the **broadcast domain** untouched: a switch forwards every broadcast frame (`ff:ff:ff:ff:ff:ff`) out all ports, so the entire switch and everything plugged into it remain one broadcast domain, and a broadcast storm still reaches every device. The memory hook from Rung 3: **a switch breaks up collision domains; a router (or VLAN) breaks up broadcast domains.**
