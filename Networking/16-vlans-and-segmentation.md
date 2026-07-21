# VLANs & Network Segmentation

*One wire, many networks: how a switch pretends to be dozens of switches — and how that idea became the overlay under your pod network.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?**
A **VLAN** (Virtual LAN) is a way to slice one physical switch into several *logically separate* networks — each its own isolated broadcast domain — using nothing but a tag inside the Ethernet frame. Then we climb one rung higher into **VXLAN**, the modern overlay that takes the same "logical network on shared wire" idea and stretches it across an entire cloud region so that thousands of tenants (and your Kubernetes pods) can share physical infrastructure without ever seeing each other.

**Why did this land on my desk?**
You are a platform engineer on **AWS EKS**. A teammate says, "Flannel is running in **VXLAN** mode and pod-to-pod traffic across nodes is dropping." You open the node and see a device called `flannel.1` with type `vxlan`, a **VNI** of 1, and UDP port **8472**. None of that makes sense unless you understand the 30-year-old switching idea it descends from. Separately, your security team asks, "Can we put the `payments` namespace on its own isolated network segment like the old finance VLAN?" To answer either question, you need VLANs in your bones.

**What do I already know already (prerequisites)?**
You should be comfortable with these before climbing:

- **MAC addresses & switching** — a switch forwards Ethernet *frames* by MAC, and floods *broadcasts* to every port ([05-mac-addresses-switching-arp.md](05-mac-addresses-switching-arp.md)).
- **A broadcast domain** — the set of devices that receive each other's broadcast frames (ARP "who has 10.0.0.5?"). One flat switch = one broadcast domain.
- **IP subnets & CIDR** — a /24 holds 254 usable hosts; routing between subnets needs a Layer-3 device ([03-subnetting-and-cidr.md](03-subnetting-and-cidr.md)).
- **The OSI layers** — VLANs live at **Layer 2**, routing at **Layer 3** ([06-osi-and-tcpip-models.md](06-osi-and-tcpip-models.md)).

Hold this mental image: **a switch is a room where everyone hears everyone shout. A VLAN is drawing invisible walls in that room so only the right people hear each shout — without building a second room.**

---

## 🔥 Rung 1 — The Pain

Rewind to a company in 2005 with one 48-port switch and four groups: **Admin, Faculty, Students, Guests**. They all plug into the same switch. What goes wrong?

**Pain #1 — Everyone is in one giant broadcast domain.**
A switch **floods** every broadcast frame out every port. ARP requests, DHCP discovers, Windows NetBIOS chatter — every device's noise hits every other device. With 500 hosts on one flat switch, broadcast traffic alone can eat measurable CPU on every NIC. This is called a **broadcast storm** when it snowballs. One flat network does not scale.

**Pain #2 — Zero isolation = zero security.**
A student plugging into any port is on the *same* Layer-2 network as the finance PC. They can ARP-spoof, sniff, or simply reach the admin server directly because there's no boundary between them. Segmentation is a security control, and a flat network has none.

**Pain #3 — The old fix was absurd: buy more switches.**
Before VLANs, the only way to separate Admin from Students was **physically separate switches and cabling** — one switch per group, then a router to connect them. Four groups meant four switches, four sets of uplinks, and a rats' nest of cable. Want to move a user from Faculty to Admin? Walk to the wiring closet and re-patch the cable. Segmentation was a *physical* property of *where you plugged in*. That is slow, expensive, and rigid.

```
   THE PAIN: physical segmentation before VLANs
   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │ Switch A │   │ Switch B │   │ Switch C │   │ Switch D │
   │  Admin   │   │ Faculty  │   │ Students │   │  Guests  │
   └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘
        └──────────────┴──────┬───────┴──────────────┘
                          ┌───┴───┐
                          │ Router│   4 switches, 4 uplinks,
                          └───────┘   re-cable to move anyone.
```

**Who feels it most?** The network admin re-patching cables, the security team with no boundaries, and — fast-forward — the **cloud provider**. AWS cannot give every customer their own physical switch. Millions of tenants share the same physical fabric, yet each VPC must feel completely isolated. Physical segmentation is dead on arrival at cloud scale. Something logical had to exist.

> **Check yourself before Rung 2:** If a switch floods broadcasts to every port and you have Admin + Students on one switch, what single property of the frame could a switch inspect to decide "this broadcast only goes to Admin ports"? (You're about to invent 802.1Q.)

---

## 💡 Rung 2 — The One Idea

> **THE ONE IDEA — memorize this sentence:**
> **A VLAN is a broadcast domain defined by a *tag in the frame*, not by *which switch or cable you plug into*. Membership is logical, so one physical switch can host many isolated networks at once.**

Everything else is derived from that sentence:

- *Tag in the frame* → there must be a **frame format** that carries a VLAN number. That's **802.1Q**, a 4-byte field inserted into the Ethernet header holding a **12-bit VLAN ID** (values 1–4094 usable).
- *Broadcast domain per VLAN* → a switch floods a broadcast **only to ports in the same VLAN**. VLAN 10's ARP never reaches VLAN 20. Isolation falls out for free.
- *Membership is logical* → moving a user between VLANs is a config change on the switch port, not a re-cabling job.
- *Many networks on one switch* → but the link **between switches** must carry all VLANs at once → you need a **trunk** that keeps frames tagged, versus an **access port** that hands one VLAN to an end device untagged.
- *VLANs isolate at L2* → so to let VLAN 10 talk to VLAN 20 you must go **up to Layer 3** → **inter-VLAN routing** via a router or L3 switch.
- *12 bits = only 4094* → at cloud scale that's nowhere near enough tenants → the same "tag defines the network" idea gets a bigger tag and a way to travel over L3 → **VXLAN**, a **24-bit VNI** (~16 million networks) tunneled over UDP.

If you can re-derive trunk ports, inter-VLAN routing, and even VXLAN from "the network is defined by a tag, not by the wire," you own this concept.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### 3.1 The 802.1Q tag: four bytes that change everything

A normal Ethernet frame is: destination MAC, source MAC, EtherType, payload, CRC. **802.1Q** inserts a **4-byte tag** right after the source MAC:

```
   UNTAGGED Ethernet frame:
   ┌────────────┬────────────┬──────────┬───────────────┬─────┐
   │ Dst MAC(6) │ Src MAC(6) │ Type(2)  │   Payload     │ CRC │
   └────────────┴────────────┴──────────┴───────────────┴─────┘

   802.1Q TAGGED frame — 4 bytes inserted:
   ┌────────────┬────────────┬══════════════════════════┬──────────┬─────────┬─────┐
   │ Dst MAC(6) │ Src MAC(6) │  802.1Q TAG (4 bytes)    │ Type(2)  │ Payload │ CRC │
   └────────────┴────────────┴══════════════════════════┴──────────┴─────────┴─────┘
                              │                          │
                              ▼                          ▼
              ┌─────────────────────────────────────────────────┐
              │ TPID = 0x8100 (2B) │ PCP(3b) │ DEI(1b) │ VID(12b)│
              │ "I am a VLAN tag"  │priority │  drop   │ VLAN ID │
              └─────────────────────────────────────────────────┘
                                                          ▲
                              12 bits → 0..4095, usable 1..4094
                              (0 = priority-only, 4095 = reserved)
```

- **TPID = 0x8100** tells the switch "the next bytes are a VLAN tag, not an EtherType."
- **PCP** (Priority Code Point, 3 bits) is 802.1p QoS priority — not our focus but that's why voice traffic can jump the queue.
- **VID** — the **12-bit VLAN ID**. 2¹² = 4096 values; 0 and 4095 are reserved, leaving **4094 usable VLANs**. Remember this number — it is the ceiling that forced VXLAN into existence.

### 3.2 Access ports vs trunk ports — where tags get added and stripped

An end device (your laptop, a server NIC) usually has **no idea VLANs exist**. It sends plain untagged frames. So the switch must add and remove tags at the right places. Two port modes do this:

- **Access port** — faces an *end device*. It belongs to exactly **one** VLAN. Frames arrive **untagged** from the device; the switch **tags** them with that port's VLAN on the way in, and **strips** the tag on the way out. The device never sees a tag.
- **Trunk port** — faces *another switch or a router*. It carries **many** VLANs, and frames stay **tagged** so the far end knows which VLAN each frame belongs to. (One VLAN per trunk can be the untagged "native VLAN," but conceptually a trunk = tagged multi-VLAN link.)

```
   ONE PHYSICAL SWITCH, FOUR LOGICAL NETWORKS

   VLAN 10 = Admin        VLAN 20 = Students
   ┌──────┐               ┌──────┐
   │Admin │──access──┐    │Stud  │──access──┐
   │ PC   │  (untag) │    │ PC   │  (untag) │
   └──────┘          ▼    └──────┘          ▼
                ┌─────────────────────────────────┐
                │           SWITCH                 │
                │  port1=access VLAN10             │
                │  port2=access VLAN20             │──TRUNK──▶ to Switch B
                │  broadcast in VLAN10 floods ONLY │  (frames stay
                │  to VLAN10 ports. VLAN20 never   │   TAGGED: 10,20,..)
                │  hears it.                       │
                └─────────────────────────────────┘

   Access = "one VLAN, untagged, for a device"
   Trunk  = "many VLANs, tagged, between switches/routers"
```

**The key mechanism:** the switch keeps a **MAC-address table that is now VLAN-aware** — an entry is (MAC, port, **VLAN**). A broadcast or unknown-unicast frame in VLAN 10 is flooded **only out ports that are members of VLAN 10** (access ports in VLAN 10, plus trunks carrying VLAN 10). That single rule is the entire security and isolation story: **VLAN 20 literally never receives VLAN 10's frames.**

### 3.3 Inter-VLAN routing — you must go up a layer

VLANs are Layer-2 islands. VLAN 10 is subnet `10.0.10.0/24`; VLAN 20 is `10.0.20.0/24`. A host in VLAN 10 wanting to reach VLAN 20 sees a *different subnet*, so it sends the frame to its **default gateway**. Something operating at **Layer 3** must receive it, look at the *IP* destination, and forward it into the other VLAN. That device is a **router** or a **Layer-3 switch**.

```
   INTER-VLAN ROUTING ("router-on-a-stick")

   VLAN10 host 10.0.10.5 ──▶ wants 10.0.20.9 (VLAN20)
        │ different subnet → send to gateway 10.0.10.1
        ▼
   ┌─────────┐   trunk (tagged 10,20)   ┌──────────────┐
   │ SWITCH  │◀════════════════════════▶│    ROUTER    │
   └─────────┘                          │  sub-if .10 → 10.0.10.1 │
                                        │  sub-if .20 → 10.0.20.1 │
                                        └──────────────┘
   Router receives tagged VLAN10 frame, strips tag, routes by IP,
   re-tags as VLAN20, sends back. L2 isolation preserved; L3 bridges it.
```

This is why a firewall between VLANs is trivial: **all** inter-VLAN traffic *must* pass through the L3 device, so you enforce policy there. Isolation by default, connectivity by exception.

### 3.4 The scaling wall → VXLAN

Now put on your cloud hat. **12 bits = 4094 VLANs.** AWS has *millions* of customers. Google runs millions of tenant networks. 4094 is a rounding error. Worse, VLANs are **L2 constructs** — they can't cross a router, so a VLAN can't span two datacenters or two availability zones over an IP backbone. Cloud needs (a) far more than 4094 segments and (b) segments that ride **over L3** across the whole region.

Enter **VXLAN** (Virtual eXtensible LAN). Same core idea — *a tag defines the network* — with two upgrades:

1. **A 24-bit VNI** (VXLAN Network Identifier) instead of a 12-bit VID. 2²⁴ ≈ **16.7 million** segments. Tenant scale solved.
2. **Tunneling L2 over L3.** Instead of putting the tag inside the Ethernet header on a shared wire, VXLAN **wraps the entire original Ethernet frame inside a UDP packet** and ships it across a routed IP network. The endpoints doing the wrapping/unwrapping are **VTEPs** (VXLAN Tunnel Endpoints) — in the cloud/K8s world, that's software on each node.

```
   VXLAN ENCAPSULATION — original L2 frame becomes UDP payload

   ┌────────────────────────────────────────────────────────────────┐
   │ Outer Eth │ Outer IP  │ Outer UDP │ VXLAN hdr │  ORIGINAL frame  │
   │ (node MAC)│ src=NodeA │ dport=4789│  VNI(24b) │ ┌──────────────┐ │
   │           │ dst=NodeB │  (or 8472 │           │ │pod's real Eth│ │
   │           │           │  Flannel) │           │ │+IP+payload   │ │
   └───────────┴───────────┴───────────┴───────────┴─┴──────────────┴─┘
        └──────── routed across the L3 network (VPC) ────────┘
              A pod frame rides inside a normal UDP datagram.
```

- **Standard VXLAN UDP port = 4789.** (Note: **Flannel's** VXLAN backend historically uses **8472**, a pre-standard Linux default. Both are correct in their context — worth knowing when reading `tcpdump`.)
- The outer IP header lets the packet be **routed** node-to-node over the existing VPC — no L2 adjacency required. The pod thinks it's on a flat L2 network; underneath, its frames are being couriered as UDP.

**This is exactly how several CNIs build the pod overlay:**

- **Flannel (VXLAN backend)** creates a `flannel.1` VXLAN interface on each node; pod frames destined for a pod on another node get encapsulated with the cluster VNI and sent to the target node's IP.
- **Calico (VXLAN mode)** does the same via a `vxlan.calico` interface — used when you can't or don't want BGP peering (e.g., across AWS AZs or subnets where the underlay won't carry native pod routes).

So when your teammate says "Flannel is in VXLAN mode and cross-node pods are dropping," you now know: **the pod's Ethernet frame is being wrapped in UDP and routed between node IPs, and something — MTU, a Security Group blocking UDP 8472/4789, or a VTEP misconfig — is breaking that tunnel.** That is a VLAN concept, scaled up, sitting under your cluster.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **VLAN** | A logical broadcast domain defined by a tag, not by wiring | The whole L2 segmentation idea (Rung 2) |
| **802.1Q** | The IEEE standard/frame format that inserts a 4-byte VLAN tag | The tag in the frame (Rung 3.1) |
| **VLAN ID / VID** | The **12-bit** number (1–4094 usable) identifying a VLAN | Inside the 802.1Q tag |
| **TPID (0x8100)** | Marker saying "a VLAN tag follows" | First 2 bytes of the 802.1Q tag |
| **PCP / 802.1p** | 3-bit QoS priority in the tag | Priority field of the tag (not isolation) |
| **Broadcast domain** | Set of devices that receive each other's broadcasts | One per VLAN — the thing being isolated |
| **Access port** | Switch port for an end device: one VLAN, **untagged** | Adds/strips tag at the edge (Rung 3.2) |
| **Trunk port** | Switch port between switches/routers: many VLANs, **tagged** | Carries all VLANs between devices (Rung 3.2) |
| **Native VLAN** | The one VLAN sent untagged over a trunk | Trunk config detail |
| **Inter-VLAN routing** | Forwarding between VLANs at Layer 3 | Router / L3 switch (Rung 3.3) |
| **L3 switch** | A switch that also routes between VLANs in hardware | Does inter-VLAN routing |
| **VXLAN** | L2-over-L3 overlay with a 24-bit ID, tunneled in UDP | Cloud/K8s scaling (Rung 3.4) |
| **VNI** | The **24-bit** VXLAN Network Identifier (~16.7M segments) | VXLAN's equivalent of the VLAN ID |
| **VTEP** | VXLAN Tunnel Endpoint: encapsulates/decapsulates frames | Node-side software (`flannel.1`, `vxlan.calico`) |
| **Overlay / Underlay** | Overlay = the virtual pod net; underlay = the real VPC/IP net | VXLAN rides overlay-on-underlay |

**"Same kind of thing, different names" — group these deliberately:**

- **VLAN ID (12-bit)** and **VNI (24-bit)** are *the same role*: the number that names the isolated network. VXLAN just has a bigger field and travels over L3.
- **802.1Q tag** and **VXLAN header** are *the same role*: the on-the-wire structure that carries the network identifier.
- **Trunk port** and a **VXLAN tunnel between VTEPs** are *the same role*: the shared link that carries *many* logical networks at once, keeping them distinguished by their tag/VNI.
- **Access port** and a **pod's veth / access into a single VNI** are *the same role*: the edge where a single endpoint joins one segment, tag-unaware.

---

## 🔬 Rung 5 — The Trace

**Scenario:** Pod A on **Node1** (`10.0.1.10`) pings Pod B on **Node2** (`10.0.2.20`). Cluster CNI is **Flannel in VXLAN mode**, VNI 1, pod overlay `10.244.0.0/16`. Pod A = `10.244.1.5`, Pod B = `10.244.2.9`. Follow one ICMP packet.

```
 NODE 1 (underlay IP 10.0.1.10)                 NODE 2 (underlay IP 10.0.2.20)
 ┌───────────────────────────┐                 ┌───────────────────────────┐
 │ PodA 10.244.1.5           │                 │           PodB 10.244.2.9 │
 │   │ veth                  │                 │                  veth │   │
 │   ▼                       │                 │                       ▼   │
 │ cni0 bridge               │                 │               cni0 bridge │
 │   │                       │                 │                       ▲   │
 │   ▼ route: 10.244.2.0/24  │                 │                       │   │
 │ flannel.1 (VTEP, VNI 1) ──┼── encapsulate ──┼──▶ flannel.1 (VTEP) ──┘   │
 │   │  wrap frame in UDP    │                 │      decapsulate          │
 │   ▼ outer: src 10.0.1.10  │                 │  outer dst = me →         │
 │ eth0 ─────────────────────┼── UDP/8472 ─────┼──▶ eth0                   │
 └───────────────────────────┘   over the VPC  └───────────────────────────┘
```

1. **Pod A** builds an ICMP echo: inner IP `src 10.244.1.5 → dst 10.244.2.9`. It ARPs for its gateway / the destination and sends an Ethernet frame out its `veth` into the node's `cni0` bridge.
2. **Node1 routing table** has a route: `10.244.2.0/24 dev flannel.1`. The kernel hands the frame to **`flannel.1`**, the VXLAN VTEP.
3. **VTEP lookup (FDB).** `flannel.1` needs to know which *node* owns `10.244.2.0/24`. Its forwarding database maps the remote pod-subnet's VTEP MAC → **Node2's underlay IP `10.0.2.20`**. (Flannel's daemon programs this from the cluster's node data.)
4. **Encapsulation.** The VTEP wraps Pod A's entire Ethernet frame as the payload of a new packet:
   - Outer IP: `src 10.0.1.10 → dst 10.0.2.20`
   - Outer UDP: `dport 8472` (Flannel), VXLAN header with **VNI = 1**
5. **Underlay routing.** This is now an ordinary UDP packet between two node IPs. It leaves `eth0`, crosses the **VPC** — routed by the VPC route tables, subject to **Security Groups** (which *must* allow UDP 8472 between nodes). The outer IP **TTL is decremented** at each L3 hop like any packet.
6. **Node2 receives** a UDP/8472 packet destined for its own IP. The kernel sees VXLAN and hands it to **Node2's `flannel.1`** VTEP.
7. **Decapsulation.** The VTEP strips the outer Eth/IP/UDP/VXLAN headers, recovering Pod B's original inner frame (`10.244.1.5 → 10.244.2.9`) **untouched** — inner TTL unchanged by the tunnel.
8. **Local delivery.** Node2 routes the inner packet via `cni0` to Pod B's `veth`. **Pod B receives the ping** believing it came directly over a flat L2 network. It has no idea it was couriered inside UDP across two subnets.

The reply retraces the path with src/dst swapped. **The overlay illusion:** two pods on different VPC subnets behave as if on one switch — because VXLAN did to the pod frame exactly what a trunk does to a VLAN frame, only wrapped in UDP so it could be *routed* instead of *switched*.

---

## ⚖️ Rung 6 — The Contrast

**VLAN (802.1Q) vs VXLAN** — the same idea at two different scales.

| Dimension | **VLAN (802.1Q)** | **VXLAN** |
|---|---|---|
| Identifier size | **12-bit** VLAN ID → **4094** usable | **24-bit** VNI → **~16.7 million** |
| Where the tag lives | Inside the Ethernet header | In a VXLAN header inside **UDP** |
| Transport | **Layer 2** — same switched domain only | **Layer 2 over Layer 3** — routes anywhere IP reaches |
| Spans routers / subnets / AZs? | **No** — stops at the L3 boundary | **Yes** — that's the whole point |
| Who adds/removes the tag | Switch access/trunk ports | Software **VTEPs** on hosts/nodes |
| Typical home | Enterprise campus, on-prem datacenter | Cloud overlays, K8s CNIs, multi-tenant fabrics |
| Encapsulation overhead | 4 bytes | ~50 bytes (outer Eth+IP+UDP+VXLAN) → **watch MTU** |
| Standard port | n/a (L2) | UDP **4789** (Flannel uses **8472**) |

**What each can do that the other can't:**
- VLAN **cannot** cross a router — a VLAN can't stretch across two AWS AZs. VXLAN can, because it's routed.
- VXLAN needs **VTEP software and MTU headroom**; a plain VLAN needs neither — on a single managed switch, VLANs are simpler and hardware-fast.
- VLAN's 4094 ceiling makes it useless for hyperscale multi-tenancy; VXLAN's 16M is built for it.

**When would I NOT need VXLAN?** If your pods all sit in **one flat routed subnet** and the underlay can carry pod routes directly, you don't need an overlay at all — e.g., **AWS VPC-CNI** gives each pod a real VPC IP (routed natively, no encapsulation), and **Calico in BGP mode** advertises pod routes so no tunneling is required. Overlays cost you MTU and a little CPU; skip them when the underlay can route pod IPs itself.

**Why this over that (one sentence):** Use **VLANs** to segment a physical L2 network you fully control; use **VXLAN** when you must carve millions of isolated L2 segments **over a routed L3 network** — which is precisely the cloud/Kubernetes situation.

> **Check yourself before Rung 7:** Your EKS cluster uses the AWS VPC-CNI (each pod gets a real VPC IP, no overlay). A colleague insists cross-node pod traffic is "VXLAN-encapsulated." Why is that wrong, and what would you expect to see in `tcpdump` instead of UDP/4789?

---

## 🧪 Rung 7 — The Prediction Test

You need root/`sudo` and (for the K8s parts) a cluster. Commit to each prediction **before** running the command.

### Example 1 — Normal case: create a VLAN sub-interface and see the tag

**Prediction:** *If I create an 802.1Q VLAN interface with ID 10 on `eth0`, then it will appear as a distinct L3 interface I can address separately, BECAUSE the kernel now tags every frame leaving it with VID 10 — logically a different network on the same physical NIC.*

```bash
# Create a VLAN interface with VLAN ID 10 on top of eth0
sudo ip link add link eth0 name eth0.10 type vlan id 10
sudo ip addr add 10.0.10.2/24 dev eth0.10
sudo ip link set eth0.10 up

# Inspect it
ip -d link show eth0.10
# ... eth0.10@eth0: <...> mtu 1500 ...
#     vlan protocol 802.1Q id 10 <REORDER_HDR>   <-- proof: tag id 10
```

**Verify:** `ip -d link show eth0.10` must print `vlan protocol 802.1Q id 10`. If you `tcpdump -e -i eth0` and send traffic from `eth0.10`, you'll see frames marked `vlan 10, ...`. **A wrong result** — e.g., no `vlan` line, or the peer never replies — teaches that the *upstream switch port must be a trunk allowing VLAN 10*; an access port for a different VLAN would silently drop your tagged frames. The tag is only meaningful if the other end agrees on it.

### Example 2 — Edge/failure case: two VLANs on one wire cannot talk without L3

**Prediction:** *If I put `eth0.10` (10.0.10.2/24) and `eth0.20` (10.0.20.2/24) on the same NIC and ping from one subnet to the other, it will FAIL, BECAUSE VLANs are isolated broadcast domains — the frames carry different tags and nothing routes between them until an L3 device joins the two.*

```bash
# Second VLAN on the same physical NIC
sudo ip link add link eth0 name eth0.20 type vlan id 20
sudo ip addr add 10.0.20.2/24 dev eth0.20
sudo ip link set eth0.20 up

# Try to reach a host that lives in VLAN 20 from VLAN 10's perspective
ping -c2 -I eth0.10 10.0.20.9
# From 10.0.10.2 ... Destination Host Unreachable  (no L2 path, no route)
```

Now grant inter-VLAN reachability the *only* correct way — go up to Layer 3 by enabling routing (a stand-in for the router/L3 switch):

```bash
# Turn this host into the L3 device that bridges the two VLANs
sudo sysctl -w net.ipv4.ip_forward=1
ip route            # both 10.0.10.0/24 and 10.0.20.0/24 now appear as routes
```

**Verify:** Before enabling forwarding, cross-VLAN pings fail — that failure *is the isolation working as designed*, not a bug. After `ip_forward=1`, this host routes between the two subnets exactly as a router-on-a-stick would. **The lesson:** you can never make VLAN 10 reach VLAN 20 by "fixing L2" — isolation at L2 is the feature; connectivity is an L3 decision you make deliberately.

### Example 3 — Kubernetes/cloud-flavored: watch the VXLAN overlay carry a pod ping

**Prediction:** *If my CNI is Flannel/Calico in VXLAN mode and I ping across nodes while sniffing the node's `eth0`, then I'll see UDP-encapsulated frames (dport 8472 or 4789) whose outer IPs are the two node IPs and whose inner payload is the pod ICMP, BECAUSE VXLAN tunnels the pod's L2 frame over the routed VPC.*

```bash
# On a node: confirm the VXLAN VTEP device exists and its VNI
ip -d link show flannel.1
#  flannel.1: <...> vxlan id 1 local <nodeIP> dev eth0 srcport 0 0 dstport 8472 ...
#                        ^VNI=1                                        ^Flannel port

# See which remote-pod subnets route into the tunnel
ip route | grep flannel.1
#  10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink

# Sniff the UNDERLAY while pinging pod-to-pod across nodes
sudo tcpdump -ni eth0 'udp port 8472' -c 5
#  IP 10.0.1.10.xxxxx > 10.0.2.20.8472: VXLAN, flags [I], vni 1
#    IP 10.244.1.5 > 10.244.2.9: ICMP echo request   <-- inner pod packet
```

Kubernetes-native confirmation:

```bash
# Which CNI/backend is in play?
kubectl -n kube-flannel get cm kube-flannel-cfg -o yaml | grep -i -A3 Backend
#  "Backend": { "Type": "vxlan" }

kubectl get nodes -o wide          # note each node's INTERNAL-IP = the outer/underlay IP
```

**Verify:** The `tcpdump` line proving it is the **nested IP**: outer `10.0.x` node IPs on **UDP 8472**, wrapping inner `10.244.x` pod IPs. **A wrong result teaches loudly:** if you see the pod ping but with **no UDP wrapper** and pod IPs that look like VPC IPs (`10.0.x`), you're on **AWS VPC-CNI**, not an overlay — pods get real VPC addresses and are routed natively (the Rung 6 "when you don't need VXLAN" case). And if cross-node pings **fail** while same-node pings work, suspect the **Security Group blocking UDP 8472/4789** between nodes, or an **MTU** mismatch — the ~50-byte VXLAN header pushed frames over the path MTU. Both are the overlay tax made visible.

---

## 🏔️ Capstone — Compress It

**One-sentence summary:**
A VLAN is an isolated broadcast domain defined by a tag in the frame (802.1Q, 12-bit ID, ~4094) rather than by physical wiring, and VXLAN scales that same idea to ~16.7 million networks by tunneling L2 frames over L3 in UDP — which is exactly how CNIs like Flannel and Calico build the Kubernetes pod overlay.

**Explain it to a beginner (3 sentences):**
Imagine one big room where everyone hears every shout — that's a plain switch, and it's noisy and insecure. A VLAN draws invisible walls so only the right people hear each shout, using a small "which-room" label stamped on every message, no new rooms needed. VXLAN is the cloud-scale version: it stuffs each message inside an envelope addressed between buildings so your "room" can span the whole city — that envelope is how your Kubernetes pods on different servers feel like they're on one network.

**Sub-parts mapped to the One Idea** ("the network is defined by a *tag*, not by the *wire*"):

| Sub-part | How it derives from the One Idea |
|---|---|
| 802.1Q tag / VLAN ID | The literal tag that names the network |
| Access vs trunk ports | Where the tag is stripped (edge) vs kept (shared link) |
| One broadcast domain per VLAN | Flood only to ports sharing the tag → isolation |
| Inter-VLAN routing needs L3 | Tags isolate at L2; crossing them is a Layer-3 act |
| 4094 ceiling → VXLAN | A bigger tag (24-bit VNI) for cloud scale |
| VXLAN tunnels L2 over L3 | Same tag idea, wrapped in UDP so it can be routed |
| Flannel/Calico VXLAN backend | The tag-over-UDP idea, running as your pod network |

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 3** on a real cluster with `tcpdump -ni eth0 udp port 8472`. Seeing a pod's ICMP packet nested inside a node-to-node UDP datagram — inner pod IPs, outer node IPs, VNI 1 — is the moment VLANs stop being ancient switching trivia and become the living machinery under your EKS pod network. If the overlay still feels abstract, that packet capture is the fix.

---

## Related concepts

- [MAC addresses, switching & ARP](05-mac-addresses-switching-arp.md) — the L2 frame, switches, and broadcast domains VLANs subdivide.
- [Subnetting & CIDR](03-subnetting-and-cidr.md) — each VLAN is a subnet; inter-VLAN routing is subnet-to-subnet.
- [Routing & forwarding](08-routing-and-forwarding.md) — the Layer-3 step that inter-VLAN routing and the VXLAN underlay both depend on.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — where Flannel/Calico VXLAN overlays actually build the pod network.
- [Container & Docker networking](23-container-docker-networking.md) — bridge and overlay networking, the container-scale cousin of this idea.
- [AWS VPC](20-aws-vpc.md) — the routed underlay your VXLAN pod traffic and native VPC-CNI pods ride on.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If a switch floods broadcasts to every port and you have Admin + Students on one switch, what single property of the frame could a switch inspect to decide "this broadcast only goes to Admin ports"?

**A:** A tag carried *inside the Ethernet frame itself* — a VLAN ID. If every frame carries a small numeric label saying which logical network it belongs to, the switch can flood a broadcast only out ports assigned that same label, instead of all ports. That is exactly what 802.1Q does: it inserts a 4-byte tag after the source MAC containing a 12-bit VLAN ID (1–4094 usable), so membership becomes a logical property of the frame rather than a physical property of which cable you plugged into. Admin frames tagged VLAN 10 are flooded only to VLAN 10 ports; Students on VLAN 20 literally never receive them.

### Before Rung 7
**Q:** Your EKS cluster uses the AWS VPC-CNI (each pod gets a real VPC IP, no overlay). A colleague insists cross-node pod traffic is "VXLAN-encapsulated." Why is that wrong, and what would you expect to see in `tcpdump` instead of UDP/4789?

**A:** It's wrong because the AWS VPC-CNI gives each pod a *real VPC IP* that the underlay routes natively — there is no overlay, no VTEP, and no encapsulation, so nothing wraps pod frames in UDP. VXLAN only exists to carry L2 segments over a routed network when the underlay can't route pod IPs itself; here the VPC route tables carry pod addresses directly, so the overlay (and its ~50-byte header tax and MTU concerns) is unnecessary. In `tcpdump` on the node's `eth0` you would see the pod-to-pod packets as plain, unencapsulated IP traffic — e.g. an ICMP echo with the pods' own VPC addresses (`10.0.x.x → 10.0.x.x`) as the actual src/dst — with no outer node-IP header, no UDP/4789 (or 8472) wrapper, and no VXLAN/VNI field. You'd also find no `flannel.1` or `vxlan.calico` VTEP device on the node.
