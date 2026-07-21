# IP Addressing (IPv4 & IPv6)

> Every device needs a mailing address before a single packet can find it — this is that address.

---

## 🛠️ Rung 0 — The Setup

**What am I learning?** How machines are *identified* on a network. An IP address is a unique identity for a device — think of it as the street address written on an envelope. Before any data can be delivered, the network has to know *where* to deliver it. That "where" is an IP address.

**Why did this land on my desk?** You are an EKS platform engineer. One Tuesday, your cluster stops scheduling new pods. Events read:

```text
Warning  FailedCreatePodSandBox  ... failed to assign an IP address to container
```

You check the node and it has plenty of CPU and memory. So why can't a pod start? Because on AWS EKS with the **VPC-CNI**, every pod gets a *real, routable VPC IP address* pulled from your subnet — and you ran out of them. To understand that incident, you have to understand what an IP address actually *is*, where the bits come from, how many exist, and why "just add more" is not free. That is this whole document.

**What do I already know?** You already live in this world without naming it:
- You've typed `10.0.x.x` into Security Group rules.
- You've seen a pod get `192.168.43.17` and a node get `10.0.1.20`.
- You know `127.0.0.1` means "this machine."
- You've hit `kubectl get svc` and seen a `ClusterIP` like `172.20.0.10`.

You know the *symptoms*. Now we build the *model* underneath them, from the bits up.

---

## 🔥 Rung 1 — The Pain

**The problem that forced IP addresses to exist:** if you connect three computers with wires, how does machine A say "send *this* to machine C, not machine B"? Wires alone can't do it. You need a **naming scheme** — a globally agreed way to write "the machine I mean" that every router on Earth interprets identically. Without it there is no delivery, only broadcast shouting into the void.

**What people did before, and why it hurt:** early networks used link-local, hardware-only addressing (MAC addresses — see [MAC addresses & switching](05-mac-addresses-switching-arp.md)). That works inside one physical segment, like shouting a name across a single room. But MACs are *flat*: there's no structure that says "this address lives over *there*, on that faraway network." Routing a flat address across the planet would mean every router memorizing every device on Earth. Impossible. IP addresses fixed this by being **hierarchical** — they encode *which network* the device is on, so routers only need to know how to reach *networks*, not individual machines.

**What breaks without it (in your world):**
- A pod on Node A could never reach a pod on Node B — the network fabric would have no way to express "that pod, over on that other node's subnet."
- Your `Service` ClusterIP would be meaningless; kube-proxy rewrites destinations *by IP*.
- The VPC router couldn't send a packet from your private subnet out through the NAT Gateway, because "out" is defined by *destination IP ranges* in a route table.

**Who feels the pain most?** The platform engineer. App developers deal in DNS names (`payments.prod.svc.cluster.local`). *You* deal in the addresses those names resolve to — and when addresses run out or collide, it's your pager that fires.

> **Check yourself before Rung 2:** MAC addresses already uniquely identify every device. So *why* couldn't the internet just route on MAC addresses? What property does an IP address have that a MAC address lacks?

---

## 💡 Rung 2 — The One Idea

> **An IP address is a structured number that encodes two things at once: WHICH network a device is on, and WHICH device it is on that network.**

Memorize that sentence. Say it out loud. Everything else in IP addressing is *derived* from it:

- **It's a number** → it has a fixed size in bits (32 for IPv4, 128 for IPv6), which mathematically caps how many can exist. That cap is why IPv6 had to be invented.
- **It's structured (network + host)** → there must be a way to say where the "network" part ends and the "host" part begins. That's the **prefix / subnet mask** ([Subnetting & CIDR](03-subnetting-and-cidr.md)).
- **It encodes a network** → routers can forward toward *networks* instead of individual devices. That's what makes global routing scale ([Routing](08-routing-and-forwarding.md)).
- **It encodes a device** → within a network, the host bits pick the exact machine.

In Kubernetes terms, that one idea shows up three times, at three scales:

```text
Pod IP        drawn from the  POD / CLUSTER CIDR   (e.g. 192.168.0.0/16)
Node IP       drawn from the  VPC SUBNET CIDR      (e.g. 10.0.1.0/24)
Service IP    drawn from the  SERVICE CIDR         (e.g. 172.20.0.0/16)
```

Three separate address pools, each a "network + host" scheme. Master the one idea and all three stop being magic.

> **Check yourself before Rung 3:** If an IP address is "network part + host part," what single extra piece of information do you need in order to *split* a given address into those two parts? (You already type this piece after a slash all the time.)

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### 3.1 What an IPv4 address really is: 32 bits

An **IPv4 address is 32 bits** long. Humans can't read 32 raw bits, so we chop them into **four groups of 8 bits**. Each 8-bit group is called an **octet** (octet = 8 bits). We write each octet as a decimal number and separate them with dots — **dotted-decimal notation**:

```text
   192   .   168   .    1    .   20
 ┌──────┬──────────┬─────────┬────────┐
 │  8   │    8     │    8    │   8    │   bits   → 32 bits total
 │ bits │   bits   │   bits  │  bits  │
 └──────┴──────────┴─────────┴────────┘
   octet1   octet2    octet3   octet4
```

**Why does each octet max out at 255?** Because an octet is 8 bits, and 8 bits can represent exactly `2^8 = 256` distinct values: `0` through `255`. The largest is `255`, not `256`, because we start counting at `0`. `11111111` in binary = `255`. You cannot write `192.168.1.256` — there is no bit pattern for 256 in 8 bits. That single fact ("8 bits → 0-255") is the root of *countless* "invalid IP" errors.

**Binary ↔ decimal conversion (do this by hand once and it sticks).** Each of the 8 bit positions has a place value, doubling from right to left:

```text
 bit position value:  128  64  32  16   8   4   2   1
                       ─────────────────────────────
 the number 192   =    1    1   0   0   0   0   0   0
                       128 +64                       = 192  ✅
```

So **192 → `11000000`**, because `128 + 64 = 192` and every other bit is 0. Walk it slowly:
- Is 192 ≥ 128? Yes → write `1`, subtract → 64 left.
- Is 64 ≥ 64? Yes → write `1`, subtract → 0 left.
- Everything after → `0`.

Result: `11000000`. This is exactly the math a router or your kernel does when it compares an address against a subnet mask.

**Total address space:** 32 bits → `2^32 ≈ 4,294,967,296` ≈ **4.3 billion** possible IPv4 addresses. In 1981 that felt infinite. There are now far more than 4.3 billion internet-connected devices, which is the entire reason for the pain in the next rungs.

### 3.2 Network portion vs host portion

Those 32 bits are split into a **network portion** (the left/high bits — identifies the network) and a **host portion** (the right/low bits — identifies the device on that network). The split point is set by the **prefix length**, written `/N`, meaning "the first N bits are network."

```text
 10.0.1.20  with mask /24  (255.255.255.0)

 00001010 . 00000000 . 00000001 . 00010100
 └──────────── network (24 bits) ─────┘ └host┘
                                        (8 bits)

 Network = 10.0.1.0    (host bits zeroed)
 Host    =        .20  (the device)
```

Every device sharing the same network bits is on the *same network* and can talk directly (Layer 2). Reach a *different* network and you must go through a **router / gateway**. The full arithmetic — usable hosts = `2^(32 − prefix) − 2`, the two subtracted addresses being the network address and the broadcast address — lives in [Subnetting & CIDR](03-subnetting-and-cidr.md). Just anchor the idea here: `/24` → `2^8 − 2 = 254` usable hosts; `/26` → `2^6 − 2 = 62`; `/30` → `2^2 − 2 = 2`.

### 3.3 Public vs private addressing — and why private ranges exist

Not every address is meant to be reachable from the global internet. **RFC 1918** carves out three ranges that are **private** — reserved for use inside private networks and *never routed on the public internet*:

```text
 ┌──────────────────┬────────────────┬─────────────────────────┐
 │ Range            │ Prefix         │ Size                    │
 ├──────────────────┼────────────────┼─────────────────────────┤
 │ 10.0.0.0         │ /8             │ ~16.7 million addresses │
 │ 172.16.0.0       │ /12            │ ~1 million addresses    │
 │ 192.168.0.0      │ /16            │ ~65k addresses          │
 └──────────────────┴────────────────┴─────────────────────────┘
```

**Why do private ranges exist?** Two reasons, both born of the 4.3-billion cap:
1. **Conservation.** If every home laptop, every pod, every printer needed a globally unique public address, we'd have exhausted IPv4 decades ago. Private addresses let *millions of separate networks* reuse the same `10.x.x.x` internally. Your home `192.168.1.5` and your neighbor's `192.168.1.5` don't collide because neither leaves its own network.
2. **They get translated at the edge.** When a private device reaches the internet, a router performs **NAT** (Network Address Translation) — it swaps the private source address for a shared public one, like a concierge who takes your internal room number and presents the building's single street address to the outside world. Return traffic gets translated back. Full mechanism in [NAT & PAT](14-nat-and-pat.md).

A **public IP** is globally unique and routable. Example: **`8.8.8.8` is a public IP** — it's one of Google's public DNS servers, reachable from anywhere on Earth. Contrast that with `10.0.1.20`, which is meaningful only inside its own VPC.

**Cloud tie-in — this is your VPC:** when you create an AWS VPC you choose a CIDR, almost always from RFC 1918 (e.g. `10.0.0.0/16`). Subnets carve it up (`10.0.1.0/24`, `10.0.2.0/24`, …). Nodes and pods draw from these private ranges. Only resources in *public* subnets with a route to an **Internet Gateway** and a public/Elastic IP are internet-reachable; everything else reaches out through a **NAT Gateway**. See [AWS VPC](20-aws-vpc.md).

### 3.4 Loopback and other special ranges

Some ranges never touch a wire at all:

```text
 127.0.0.0/8   Loopback. 127.0.0.1 = "localhost" = THIS machine, talking to itself.
               A packet to 127.0.0.1 never leaves the host; the kernel loops it back.
 0.0.0.0       "This host / any address." As a bind address = "all interfaces."
 169.254.0.0/16  Link-local (APIPA). Self-assigned when DHCP fails. In AWS,
                 169.254.169.254 is the Instance Metadata Service (IMDS).
 255.255.255.255 Limited broadcast (everyone on this segment).
 224.0.0.0/4   Multicast (one-to-many groups).
 100.64.0.0/10 Carrier-grade NAT (CGNAT) — also used by some CNIs/EKS.
```

**Loopback matters daily:** when a sidecar (like an Envoy proxy in [Istio](../Istio_Learning_Ladder.md)) intercepts your app's traffic, the app often talks to `127.0.0.1:15001` — the proxy is *in the same pod's network namespace*, so loopback reaches it without a wire. When your DB connection string says `localhost:5432`, you're loopback-ing to a Postgres on the same host.

### 3.5 IPv6 — why, and how

4.3 billion addresses ran out. The Internet Assigned Numbers Authority allocated its last big IPv4 blocks in 2011. The fix is **IPv6: a 128-bit address** — four times the bits, but because address count is `2^bits`, that's `2^128 ≈ 3.4 × 10^38` addresses. That's roughly 340 undecillion — enough to give every grain of sand on Earth its own internet, many times over. Exhaustion, solved for any imaginable future.

128 bits is written as **eight groups of 16 bits each, in hexadecimal**, separated by colons:

```text
 2001:0db8:0000:0000:0000:ff00:0042:8329
 └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘ └──┘
 16b  16b  16b  16b  16b  16b  16b  16b   → 128 bits
```

Two compression rules make that readable:
1. **Drop leading zeros** in each group: `0db8` → `db8`, `0042` → `42`.
2. **`::` collapses one run of all-zero groups** to nothing (allowed **once** per address, else it'd be ambiguous):

```text
 2001:db8:0:0:0:ff00:42:8329   →   2001:db8::ff00:42:8329
                └── the "::" stands in for these three 0000 groups
```

`::1` is the IPv6 loopback (the `127.0.0.1` of IPv6). `fe80::/10` is link-local; `fc00::/7` (unique-local) is IPv6's rough analog to RFC 1918 private space.

**One more IPv6 change you'll meet in packet captures:** IPv4 has a **TTL** (Time To Live) field; IPv6 renamed the same concept to **Hop Limit**. Both are a counter that each router decrements by 1; at 0 the packet is dropped and an ICMP "time exceeded" is returned. Same mechanism, honest name — it was never about *time*, always about *hops*. This is exactly what `traceroute` exploits (see [Routing](08-routing-and-forwarding.md)).

**Cloud tie-in:** EKS supports **dual-stack** (pods get both an IPv4 and an IPv6 address) and IPv6-only clusters. The entire motivation is IPv4 exhaustion *inside your own VPC* — which is the machinery behind the very next paragraph.

### 3.6 The machinery of your opening incident

Now the FailedCreatePodSandBox makes sense. The AWS **VPC-CNI** doesn't give pods addresses from a fake overlay range — it hands each pod a **real, routable secondary IP from the node's VPC subnet**. Beautiful for performance (no encapsulation, pods are first-class VPC citizens), but it means **pod IPs are drawn straight from your finite `/24` (or whatever) subnet**. A `10.0.1.0/24` subnet has only 251 usable host addresses after AWS reserves a few. Pack enough pods per node across enough nodes and the subnet *runs dry* — IP exhaustion. That's your incident. Fixes: bigger subnet CIDRs, secondary CIDRs, prefix delegation, or IPv6. Now you know *why*.

> **Check yourself before Rung 4:** A pod on EKS with the VPC-CNI gets `10.0.1.37`. A pod on a Flannel/Calico overlay cluster gets `192.168.4.12` while its node is on `10.0.1.37`. Both are "pod IPs." Using the network-vs-host idea, explain why one of them is routable across the VPC and the other is not.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **IP address** | A structured number identifying a device on a network | The whole scheme (3.1) |
| **IPv4** | 32-bit address, ~4.3 billion total | 3.1 |
| **IPv6** | 128-bit address, ~3.4×10³⁸ total | 3.5 |
| **Octet** | One 8-bit group of an IPv4 address (0-255) | 3.1 |
| **Dotted decimal** | The `a.b.c.d` human notation for IPv4 | 3.1 |
| **Hextet / group** | One 16-bit group of an IPv6 address (hex) | 3.5 |
| **Bit / binary** | Base-2 digit; 8 bits = 1 octet = 256 values | 3.1 |
| **Network portion** | High bits identifying *which network* | 3.2 |
| **Host portion** | Low bits identifying *which device* | 3.2 |
| **Prefix / `/N`** | How many leading bits are the network part | 3.2 |
| **Subnet mask** | Same info as prefix, written `255.255.255.0` | 3.2 |
| **RFC 1918 / private IP** | Non-routable ranges for internal reuse | 3.3 |
| **Public IP** | Globally unique, internet-routable address | 3.3 |
| **NAT** | Translating private↔public at the edge | 3.3 |
| **Loopback** | `127.0.0.0/8` / `::1` — the host itself | 3.4 |
| **Link-local (APIPA)** | `169.254.0.0/16` self-assigned address | 3.4 |
| **TTL** | IPv4 hop counter, decremented per router | 3.5 |
| **Hop Limit** | IPv6's renamed TTL — same thing | 3.5 |
| **`::` (zero compression)** | Collapses one run of zero groups in IPv6 | 3.5 |
| **CIDR** | `address/prefix` block notation (e.g. `10.0.0.0/16`) | 3.2 |
| **Pod/Cluster CIDR** | The pool pod IPs come from | 3.2 / 3.6 |
| **Service CIDR** | The pool ClusterIPs come from | 2 |
| **VPC-CNI** | AWS CNI giving pods real VPC subnet IPs | 3.6 |

**"Same kind of thing wearing different names":**
- **Prefix `/24`** *is* **subnet mask `255.255.255.0`** — two notations for the identical bit boundary.
- **TTL (IPv4)** *is* **Hop Limit (IPv6)** — one mechanism, two names.
- **Localhost = `127.0.0.1` = `::1` = loopback** — all "this machine talking to itself."
- **Octet (IPv4) and hextet/group (IPv6)** are both "one chunk of the address," just 8 vs 16 bits.
- **RFC 1918 private space (IPv4)** and **`fc00::/7` unique-local (IPv6)** play the same "internal-only" role.

---

## 🔬 Rung 5 — The Trace

**One concrete action:** your laptop (`192.168.1.50`, private) asks Google's DNS server (`8.8.8.8`, public) a question. Watch the address transformations.

```text
 STEP 1  App creates a packet.
         SRC = 192.168.1.50   (your private IP, from your home /24)
         DST = 8.8.8.8        (public — a different network)

 STEP 2  Kernel checks: is 8.8.8.8 in MY network (192.168.1.0/24)?
         Compare network bits → NO. Not local.
         → Send to the DEFAULT GATEWAY (your router, 192.168.1.1).

 STEP 3  Home router performs NAT (source translation).
         Rewrites SRC 192.168.1.50  →  203.0.113.7  (its ONE public IP)
         Remembers the mapping so replies can find you.
         TTL decremented: 64 → 63.

 STEP 4  Packet hops across internet routers. Each one:
           - reads DST 8.8.8.8, looks it up in its routing table
           - forwards toward Google's network
           - decrements TTL (63 → 62 → 61 → ...)

 STEP 5  8.8.8.8 receives it, replies.
         SRC = 8.8.8.8   DST = 203.0.113.7  (your public IP)

 STEP 6  Your router reverses the NAT mapping.
         DST 203.0.113.7 → 192.168.1.50. Packet lands on your laptop. ✅
```

Visual of the address swap at the edge — the "concierge" moment:

```text
   YOUR LAN (private)            INTERNET (public)
 ┌───────────────────┐        ┌──────────────────────┐
 │ 192.168.1.50 ─────┼──NAT──▶│ 203.0.113.7 ───▶ 8.8.8.8│
 │  (real device)    │  swap  │ (shared public face)  │
 └───────────────────┘        └──────────────────────┘
     private, reused          globally unique, routable
```

**Kubernetes version of the same trace** (a pod calling a Service on EKS):

```text
 Pod 192.168.12.5  ──▶  Service ClusterIP 172.20.100.8:80
     │                        (a VIRTUAL IP — no device owns it)
     ▼
 kube-proxy iptables/IPVS rule DNATs the destination:
     DST 172.20.100.8 ──rewritten──▶ 192.168.30.9  (a real backend pod IP)
     │
     ▼
 Packet delivered to pod 192.168.30.9. The ClusterIP was never
 a machine — it's a stable address kube-proxy rewrites on the fly.
```

Notice the through-line: in *both* traces a destination address gets rewritten to reach the real endpoint. Home NAT and kube-proxy DNAT are the same idea — "an address that stands in for another" — applied at different scales. Details in [Services & kube-proxy](25-kubernetes-services-kube-proxy.md).

> **Check yourself before Rung 6:** In the Kubernetes trace, `172.20.100.8` is a ClusterIP that no pod actually owns. Using the "network + host" and "NAT/rewrite" ideas, explain how a packet can be *sent to* an address that belongs to no physical interface.

---

## ⚖️ Rung 6 — The Contrast

**IPv4 vs IPv6** — the newer scheme versus the one it's slowly replacing:

| Dimension | IPv4 | IPv6 |
|---|---|---|
| Address size | 32 bits | 128 bits |
| Total addresses | ~4.3 billion (`2^32`) | ~3.4×10³⁸ (`2^128`) |
| Notation | Dotted decimal `192.168.1.1` | Hex groups `2001:db8::1` |
| Chunk | Octet (8 bits, 0-255) | Hextet (16 bits, hex) |
| Zero shortcut | none | `::` compression |
| Hop counter field | **TTL** | **Hop Limit** |
| NAT | Ubiquitous (had to be, due to scarcity) | Designed to make NAT unnecessary |
| Address config | DHCP ([DHCP](15-dhcp.md)) | SLAAC + DHCPv6 |
| Loopback | `127.0.0.1` | `::1` |
| EKS support | Default | Dual-stack / IPv6-only |

**What IPv6 can do that IPv4 cannot:** end globally, hand every device a *unique routable* address (no NAT needed), and never worry about exhaustion. **What IPv4 still does better:** it's human-memorable, universally supported, and every tool/config/regex on Earth already handles it. IPv6 addresses are painful to type and many legacy systems still choke on them.

**When would I NOT need IPv6?** Inside a single VPC that fits comfortably in RFC 1918 space with room to grow, and where you're not hitting pod-IP exhaustion, plain IPv4 is simpler and everything supports it. Reach for IPv6/dual-stack *specifically* when the 4.3-billion-shaped wall hits you locally — massive EKS clusters exhausting subnet IPs via the VPC-CNI, or workloads that must be directly addressable at scale.

**Why this over that, in one sentence:** *Use IPv4 for its universal simplicity until address scarcity bites, then move to IPv6 because more bits is the only real cure for exhaustion.*

> **Check yourself before Rung 7:** IPv6 has so many addresses that NAT is "unnecessary." Yet many organizations still deploy NAT/firewalling with IPv6. If exhaustion was the *only* reason for private addressing, that'd make no sense — so what *other* reason (hinted at in Rung 3.3) makes people keep a translation/hiding layer even when they don't need one?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *before* running the command. Being wrong is the point — a wrong result teaches you where your model is off.

### Example 1 — Normal case: inspect your own IPs and see the network/host split

**Prediction:** *If I list my interfaces, I'll see a private RFC 1918 address with a `/prefix`, plus a `127.0.0.1/8` loopback that never leaves the machine — BECAUSE every host has at least a loopback and at least one real interface, and the prefix encodes the network/host boundary.*

```bash
ip addr show            # full listing
ip -4 addr              # IPv4 only, terser
ip -6 addr              # IPv6 addresses (look for ::1 and fe80::/link-local)
```

```text
# Representative output (ip -4 addr):
# 1: lo    inet 127.0.0.1/8    scope host lo
# 2: eth0  inet 10.0.1.20/24   scope global eth0
#          └ private (RFC 1918)  └ /24 → first 24 bits are the network (10.0.1.0)
```

**Verify:** confirm the loopback is `127.0.0.1/8` and your real interface is a private range with a prefix. A *wrong* result — e.g. a `169.254.x.x` link-local address — would teach you DHCP failed and the host self-assigned, meaning no real network config arrived. On Windows the equivalent is `ipconfig /all`; on mac `ifconfig`.

### Example 2 — Edge/verification case: prove `127.0.0.1` is loopback, and public ≠ private

**Prediction:** *My public-facing IP (what the internet sees) will be DIFFERENT from every private address on my interfaces — BECAUSE NAT translates my private source to a shared public one at the edge, so the outside world never sees `10.x` / `192.168.x`.*

```bash
ip -4 addr | grep inet          # what I have LOCALLY (private)
curl -s ifconfig.me; echo       # what the INTERNET sees (public) — via a NAT/edge
# Prove loopback stays home:
ping -c1 127.0.0.1              # replies instantly, never touches a NIC
```

```text
# ip -4 addr  → 10.0.1.20         (private, on my interface)
# curl ifconfig.me → 203.0.113.7  (public, my NAT gateway's address) ← DIFFERENT
```

**Verify:** the two addresses differ, and the `curl` result is *not* in any RFC 1918 range. If they were *identical* and the address were public, you'd learn this host has a real public IP directly (e.g. an EC2 instance with a public IP in a public subnet) — no NAT in the path. That difference *is* NAT, made visible.

### Example 3 — Binary/math case: verify by hand why `192 = 11000000` and why 255 is the ceiling

**Prediction:** *`192` in binary is `11000000` (128+64), and `.256` is an invalid octet — BECAUSE an octet is 8 bits capping at `2^8−1 = 255`.*

```bash
# Confirm 128 + 64 = 192 and the bit pattern, using printf:
python3 -c "print(bin(192))"      # → 0b11000000
python3 -c "print(128+64)"        # → 192
# Ask the kernel to accept an out-of-range octet — it will refuse:
ip route get 192.168.1.256 2>&1 || echo "rejected: 256 is not a valid octet"
```

```text
# 0b11000000   → 1×128 + 1×64 + 0 + 0 + 0 + 0 + 0 + 0 = 192  ✅
# ip route get 192.168.1.256 → error / rejected (no 8-bit pattern for 256)
```

**Verify:** the binary is `11000000` and `.256` is rejected. If you *believed* an octet could hold 256, this failure corrects the model: 8 bits → 256 *values*, but the *highest* is 255 because counting starts at 0.

### Example 4 — Kubernetes/cloud case: watch pod IPs come from the cluster CIDR and node IPs from the VPC subnet

**Prediction:** *Pod IPs will all fall inside the pod/cluster CIDR, node IPs inside the VPC subnet CIDR, and Service ClusterIPs inside a THIRD, separate service CIDR — BECAUSE each is an independent "network+host" pool, and on EKS VPC-CNI the pod pool overlaps the VPC subnet (real routable IPs), which is exactly what causes IP-exhaustion incidents.*

```bash
kubectl get pods  -o wide          # POD IPs (from pod/cluster CIDR)
kubectl get nodes -o wide          # NODE INTERNAL-IPs (from VPC subnet)
kubectl get svc                    # ClusterIPs (from service CIDR)

# On AWS, inspect the actual subnet and how many IPs remain:
aws ec2 describe-subnets \
  --query 'Subnets[].{Id:SubnetId,CIDR:CidrBlock,Free:AvailableIpAddressCount}' \
  --output table
```

```text
# kubectl get pods  -o wide → pod   192.168.30.9    (pod/cluster CIDR)
# kubectl get nodes -o wide → node  10.0.1.20       (VPC subnet /24)
# kubectl get svc           → svc   172.20.100.8    (service CIDR, virtual)
# describe-subnets          → Free  3               ← nearly exhausted! ⚠
```

**Verify:** the three IP families are visibly distinct ranges. On a **VPC-CNI** cluster, note that pod IPs and node IPs share the *same* VPC subnet family (`10.0.x` / `192.168.x` per your VPC) — that overlap is the feature and the footgun. A low `AvailableIpAddressCount` is the smoking gun for your opening `FailedCreatePodSandBox`; the lesson is that pods consume real subnet addresses, so subnet sizing is capacity planning. On a Calico/Flannel *overlay* cluster instead, pod IPs come from a separate virtual range and *don't* drain the VPC subnet — a different trade-off ([Pod networking & CNI](24-kubernetes-pod-networking-cni.md)).

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):** An IP address is a fixed-size structured number that says which network a device is on and which device it is, and IPv4's 32-bit / 4.3-billion ceiling is why IPv6's 128 bits exist.

**Three-sentence beginner explanation:** An IP address is like a mailing address for a computer — it has to be structured so mail carriers (routers) know which neighborhood (network) to head to before finding the exact house (host). IPv4 writes this as four numbers 0-255 (each an 8-bit octet), but there are only about 4.3 billion of them, so we reuse private ranges internally and translate them at the edge with NAT. IPv6 uses 128 bits and hex groups to make address exhaustion a non-issue forever.

**Sub-parts mapped to the one core idea** ("network + host, in a fixed number of bits"):
- *Octets / binary / 0-255* → the *bits* that make up the number.
- *Prefix, subnet mask, CIDR* → where the network/host split falls.
- *Private vs public, NAT, loopback, reserved ranges* → *which* networks a number can belong to and reach.
- *IPv6, `::`, hop limit* → the *bigger* version of the same number, invented because the small one ran out.
- *Pod / Node / Service CIDRs, VPC-CNI* → the same idea applied at three scales inside your cluster.

**Which rung to revisit hands-on:** **Rung 3.1–3.2 and Rung 7 Example 3.** Convert three random octets to binary by hand until the "8 bits → 0-255" and network/host split are reflexive — every subnetting, CIDR, and IP-exhaustion problem you'll ever debug is built on that muscle memory.

---

## Related concepts

- [What is a network & the internet](01-what-is-a-network-and-the-internet.md) — the world these addresses live in.
- [Subnetting & CIDR](03-subnetting-and-cidr.md) — the exact math of splitting network vs host bits.
- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — the "room number" that pairs with the IP "street address."
- [NAT & PAT](14-nat-and-pat.md) — how private addresses reach the public internet.
- [AWS VPC](20-aws-vpc.md) — where your node/subnet CIDRs are actually configured.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — where pod IPs come from and why the VPC-CNI exhausts subnets.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** MAC addresses already uniquely identify every device. Why couldn't the internet just route on MAC addresses? What property does an IP address have that a MAC lacks?

**A:** MAC addresses are **flat** — they uniquely identify a device, but nothing in the address says *where* that device lives. Routing the planet on flat addresses would force every router on Earth to memorize every individual device, which cannot scale. An IP address is **hierarchical**: it encodes *which network* the device is on (the network portion) plus *which device* it is on that network (the host portion). That structure lets routers forward toward *networks* instead of individual machines, which is the property that makes global routing possible. MACs work fine inside one physical segment — like shouting a name across a single room — but they can't express "over there, on that faraway network."

### Before Rung 3
**Q:** If an IP address is "network part + host part," what single extra piece of information do you need to split a given address into those two parts?

**A:** The **prefix length** — the `/N` you type after the slash (equivalently, the **subnet mask**, e.g. `255.255.255.0`). The address alone is just 32 bits; the prefix tells you "the first N bits are the network part, the rest are host bits." So `10.0.1.20/24` means the network is `10.0.1.0` (first 24 bits) and the host is `.20` (last 8 bits). `/24` and `255.255.255.0` are two notations for the identical bit boundary.

### Before Rung 4
**Q:** A VPC-CNI pod gets `10.0.1.37`; a Flannel/Calico overlay pod gets `192.168.4.12` while its node is on `10.0.1.37`. Both are "pod IPs." Why is one routable across the VPC and the other not?

**A:** Routability is decided by whether the address's *network portion* is one the VPC fabric knows how to reach. The VPC-CNI pod's `10.0.1.37` is a real secondary IP drawn from the node's VPC subnet CIDR (`10.0.1.0/24`) — its network bits match a subnet in the VPC's route tables, so the VPC router can deliver to it directly; the pod is a first-class VPC citizen. The overlay pod's `192.168.4.12` comes from a separate virtual pod CIDR that exists only inside the cluster — the VPC has no route for the `192.168.x` network, so the fabric can't deliver to it. Overlay traffic must instead be encapsulated and carried between nodes using the nodes' real `10.0.x` addresses. That's also the trade-off: VPC-CNI pods drain the finite subnet (your `FailedCreatePodSandBox` incident), while overlay pods don't.

### Before Rung 6
**Q:** `172.20.100.8` is a ClusterIP that no pod actually owns. How can a packet be *sent to* an address that belongs to no physical interface?

**A:** Because a destination address only needs to survive long enough to be **rewritten** — the same "address that stands in for another" idea as NAT. The ClusterIP is a virtual "network + host" number drawn from the service CIDR (`172.20.0.0/16`), a pool deliberately separate from any pod or node network, so no interface ever claims it. When the pod's packet leaves, it hits kube-proxy's iptables/IPVS rules on the node *before* it would ever need real delivery, and the rule DNATs the destination: `172.20.100.8` is rewritten to a real backend pod IP like `192.168.30.9`. The packet then routes normally to that real address. Exactly like your home NAT rewriting addresses at the edge, the ClusterIP is a stable stand-in that kube-proxy translates on the fly — it was never a machine.

### Before Rung 7
**Q:** IPv6 makes NAT "unnecessary," yet many organizations still deploy NAT/firewalling with IPv6. What *other* reason (beyond exhaustion) makes people keep a translation/hiding layer?

**A:** Because private addressing was never *only* about conservation — Rung 3.3's second point is that translation at the edge also **hides the internal network**. The concierge model gives you a control point: internal room numbers (your topology, device identities, address plan) are never exposed to the outside world, and nothing outside can reach inward unless the edge explicitly allows it. That's security and policy, not scarcity — one auditable boundary where all inbound/outbound traffic can be inspected, filtered, and logged. With IPv6, every device *could* be globally unique and directly routable, but most organizations don't *want* every device reachable from the internet, so they keep unique-local addressing (`fc00::/7`), firewalls, and sometimes NAT to preserve that hiding-and-gatekeeping layer even when exhaustion is solved.
