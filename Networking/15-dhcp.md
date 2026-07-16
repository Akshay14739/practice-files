# DHCP — Dynamic Address Assignment 🪜
### How a device that knows *nothing* gets a full IP identity in under a second — and why your pods pointedly refuse to play along

> This is the DHCP rung of your networking ladder. We do not start with `dhclient`. We start with a machine that just booted onto a wire and has **no idea who it is or where it lives**, and we derive — from that single helplessness — every part of DHCP: the broadcast handshake, leases, pools, reservations, and relay. Only at the very top do we run commands. Each rung ends with a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.

---

# RUNG 0 — The Setup

**What am I learning?**
DHCP — the Dynamic Host Configuration Protocol — the mechanism that hands a freshly-booted device its **entire IP configuration** (IP address, subnet mask, default gateway, and DNS servers) automatically, so no human ever types those four things by hand.

**Why did it land on my desk?**
You're a platform engineer on EKS. A new worker node joined the cluster this morning and showed up in `kubectl get nodes` with a private IP like `10.0.3.157` — and *nobody assigned it*. Meanwhile your pods on that node have IPs like `10.0.3.42`, `10.0.3.88`… also unassigned by any human. Your lead asks the innocent question: "Where do those IPs actually come from — is that DHCP?" The answer is *half yes, half no*, and the half-no is one of the most important facts about how Kubernetes networking really works. To answer honestly you need to know exactly what DHCP does, and exactly where the cluster stops using it.

**What do I already know already?**
You know an IP address identifies a host on a network ([IP addressing](02-ip-addressing.md)), that a subnet mask / CIDR prefix splits it into network + host portions ([subnetting](03-subnetting-and-cidr.md)), that a default gateway is the router you send off-subnet traffic to ([routing](08-routing-and-forwarding.md)), that DNS turns names into IPs ([DNS](09-dns.md)), and that Layer 2 uses MAC addresses and ARP to move frames on the local wire ([MAC/ARP](05-mac-addresses-switching-arp.md)). DHCP is the glue that *bootstraps* all of that — it's how a host gets everything it needs to start participating.

---

# RUNG 1 — The Pain 🔥
### *Why does DHCP exist at all?*

Picture the world **before** DHCP. Every device that joins a network needs, at minimum, four facts to be a functioning citizen:

1. **Its own IP address** — otherwise nobody can reach it and it can't source packets.
2. **Its subnet mask** — otherwise it can't tell "who is local (ARP directly)" from "who is remote (send to the gateway)."
3. **Its default gateway** — otherwise every off-subnet packet has nowhere to go.
4. **Its DNS servers** — otherwise it can resolve zero names and the internet is a list of numbers.

### What people did before — and why it hurt

They typed all four in, by hand, on every machine. This is **static configuration**, and at any real scale it is a slow-motion disaster:

```
THE PRE-DHCP PAIN — a 300-desk office, all static

Desk 1:  IP 192.168.1.10   mask /24   gw 192.168.1.1   dns 192.168.1.53
Desk 2:  IP 192.168.1.11   mask /24   gw 192.168.1.1   dns 192.168.1.53
Desk 3:  IP 192.168.1.11   mask /24   gw 192.168.1.1   dns 192.168.1.53   ← OOPS. typo. duplicate.
   ...
Desk 300: IP ???           who's free? nobody knows. check the spreadsheet.

Failure modes:
• Duplicate IP  → BOTH machines break intermittently (ARP fights over the address)
• Typo in mask  → host thinks a remote peer is local, ARPs into the void, times out
• Typo in gw    → LAN works, internet dead, "it's DNS" (it's not, it's the gateway)
• DNS server moves → walk to all 300 desks and retype it
• Laptop roams office→home→cafe → 3 different networks, 3 manual reconfigs per move
• The source of truth is a SPREADSHEET a human maintains. It is always wrong.
```

The killer is that **static config doesn't scale with churn**. A laptop that moves between a /24 office subnet, a home network, and a coffee-shop network needs three completely different configs, and it changes networks several times a day. Multiply by every phone, laptop, printer, and VM that appears and disappears, and manual assignment becomes a full-time job that is *still* wrong.

**Who feels the pain most?** The people managing *large, churning* fleets — exactly the cloud/platform mindset. In a VPC, EC2 instances (your EKS nodes) are created and destroyed constantly by an autoscaler. If a human had to pick a free IP for every node the ASG launches at 3 AM, autoscaling would be impossible. **DHCP (and its cloud descendants) is what makes elastic, churning fleets even conceivable.**

### What breaks without it

Without automatic address assignment: no plug-and-play networking, no roaming, no autoscaling, guaranteed duplicate-IP outages, and a permanent human bottleneck between "a machine exists" and "a machine can talk."

> **✅ Check yourself before Rung 2:** A brand-new machine boots onto an Ethernet cable. It has a MAC address burned into its NIC but **no IP address at all**. It needs an IP — but to *ask* for one, it has to send a packet, and every IP packet needs a destination address. It doesn't know the DHCP server's address, and it has no source address of its own. How on earth can it send that first request? (Derive the trick before you read on.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — every other part of DHCP can be *derived* from it:

> **DHCP lets a device with no IP identity shout a request onto the local wire by broadcast, and a server that owns a pool of addresses answers by lending it a complete, time-limited IP configuration.**

Read it again. Three load-bearing words: **broadcast**, **pool**, **lease**.

### Why this sentence lets you derive the rest

Watch the whole protocol fall out of those three words:

- *"no IP identity… shout by broadcast"* → The chicken-and-egg from your Rung 1 question is solved by **broadcasting to `255.255.255.255`** (the all-hosts address) from source `0.0.0.0` (the "I have no address yet" address). You don't need to know the server's address; you yell to *everyone* on the L2 segment and let the server hear you. This forces DHCP to be **broadcast-based**, which in turn forces the **relay** mechanism later (broadcasts don't cross routers).
- *"a server that owns a pool"* → Somebody has to be the authority that hands out addresses and remembers what's taken. That's the **DHCP server** and its **address pool** (a range like `10.0.1.100–10.0.1.200`). If two servers owned overlapping pools you'd get duplicates again — so pools are carefully carved.
- *"lends… a complete configuration"* → Not just an IP: the server bundles **IP + mask + gateway + DNS** (and more) in its answer. That's why one protocol fixes all four of Rung 1's facts at once.
- *"time-limited… lease"* → The address isn't given, it's **loaned** for a duration (the lease). This is what makes addresses *reclaimable* — a laptop that leaves and never comes back eventually frees its address for someone else. Leases force **renewal**, which is a whole sub-dance.

Everything else — DORA, T1/T2 timers, reservations, relay — is just the mechanical detail of "broadcast, pool, lease." Hold the sentence; derive the machinery.

> **✅ Check yourself before Rung 3:** From the one sentence alone, predict: *why must a DHCP-assigned address expire instead of being given away forever?* (Think about a fleet where machines vanish without saying goodbye.)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. DHCP has four moving parts to understand: **(A) the DORA handshake**, **(B) the pool and the lease database**, **(C) lease timers and renewal**, and **(D) relay across subnets**. Everything runs over **UDP** — port **67** (server) and port **68** (client). Why UDP and not TCP? Because you can't do a TCP handshake when you don't have an IP address yet; TCP needs both endpoints addressed. Broadcast + connectionless UDP is the only thing that works from a standing start.

## (A) DORA — the four-packet handshake

**DORA = Discover → Offer → Request → Acknowledge.** Memorize the word DORA; it's the spine of the whole protocol.

```
        CLIENT (no IP yet, MAC=aa:bb:cc:dd:ee:ff)        DHCP SERVER (10.0.1.1)
        src=0.0.0.0  dst=255.255.255.255                 owns pool 10.0.1.100-.200
        ─────────────────────────────────────────────────────────────────────────

  1. DISCOVER  ──────────  "Is there a DHCP server out there? It's me, MAC ...ee:ff.
     (BROADCAST)            I have no address. Anyone?"
                            src 0.0.0.0:68  →  dst 255.255.255.255:67
                            ─────────────────────────────────────────────►

  2. OFFER     ◄──────────  "Yes! I'm 10.0.1.1. I can lend you 10.0.1.157,
     (BROADCAST*)           mask /24, gateway 10.0.1.1, DNS 10.0.1.53,
                            lease 3600s. Interested?"
                            src 10.0.1.1:67  →  dst 255.255.255.255:68
                            ◄─────────────────────────────────────────────

  3. REQUEST   ──────────  "Yes, I'll take 10.0.1.157 from server 10.0.1.1.
     (BROADCAST)            (Broadcasting so any OTHER servers that offered
                            know I declined them.)"
                            src 0.0.0.0:68  →  dst 255.255.255.255:67
                            ─────────────────────────────────────────────►

  4. ACK       ◄──────────  "Confirmed. 10.0.1.157 is yours for 3600s.
     (BROADCAST*)           Here's the full config again. Go live."
                            src 10.0.1.1:67  →  dst 255.255.255.255:68
                            ◄─────────────────────────────────────────────

        Client now configures its NIC: IP 10.0.1.157/24, gw 10.0.1.1, dns 10.0.1.53
        (Well-behaved clients ARP-probe 10.0.1.157 first to double-check nobody
         else is squatting on it before committing.)

  *Offer/Ack are broadcast because the client still has no confirmed IP to
   unicast to; the client's MAC in the packet lets it recognize its own reply.
```

Why **four** packets and not two? Because a network can have **more than one DHCP server**. Discover goes to all of them; each may Offer. The client picks one and **Requests** it *by broadcast*, which simultaneously tells the winner "I accept" and tells the losers "I declined you, release the address you tentatively held." The Ack is the server's final, binding commitment. Discover/Request come from the client; Offer/Ack come from the server. D-O-R-A, client-server-client-server.

## (B) The pool and the lease database

The server's whole job is bookkeeping over a **scope** (a subnet it's responsible for) and a **pool** (the assignable range inside it):

```
DHCP SERVER'S VIEW OF SUBNET 10.0.1.0/24  (254 usable hosts: 2^(32-24) - 2)

  10.0.1.1              ← default gateway   (EXCLUDED from pool — static infra)
  10.0.1.53             ← DNS server        (EXCLUDED — reserved by policy)
  10.0.1.2  – 10.0.1.99 ← reserved for servers/static kit (EXCLUDED)
  ┌───────────────────────────────────────────────────────────┐
  │ 10.0.1.100 – 10.0.1.200  = THE POOL (dynamic, lend these)  │
  │   .100  LEASED  → MAC aa:bb:...:ff   expires 14:32:07       │
  │   .101  LEASED  → MAC 11:22:...:99   expires 14:40:55       │
  │   .102  FREE                                                │
  │   .157  LEASED  → MAC aa:bb:...:ff  (our client from above) │
  │   ...                                                       │
  └───────────────────────────────────────────────────────────┘
  10.0.1.201 – 10.0.1.254 ← spare / future

  Note: .0 = network address, .255 = broadcast address — never assignable.
  That's the "- 2" in usable-hosts math for any subnet.
```

The server keeps a **lease database** (on disk) mapping *which address is lent to which MAC until when*. This is the single source of truth that the pre-DHCP spreadsheet could never be, because the machine that hands out addresses is the same machine that records them — they can't drift apart.

**Reservations** live here too: a reservation pins *"MAC `xx` always gets IP `10.0.1.150`."* The device still does full DORA — it doesn't configure statically — but the server always Offers it the same address. You get the *stability* of a fixed IP with the *central management* of DHCP. This is how a printer or a small database VM gets a predictable address without anyone touching the device.

## (C) Lease timers — the renewal dance

A lease is a loan with a clock. Three timers matter (values are fractions of the lease time L):

```
Lease granted at T=0, lease length L = 3600s (1 hour)

  T=0 ────────────── T1 (50% = 1800s) ────── T2 (87.5% = 3150s) ──── L (3600s)
  │                    │                         │                      │
  ACK received         RENEW: unicast REQUEST    REBIND: broadcast      EXPIRE:
  address is live      straight to the SAME      REQUEST to ANY         if still no
                       server that gave it.      server (maybe the      answer, DROP
                       "May I keep .157?"        original died).        the address,
                       Server ACKs → clock       "Anyone renew .157?"   go back to
                       resets to T=0.            ← last-ditch effort.    DISCOVER.
```

The crucial subtlety: **renewal is a 2-packet REQUEST/ACK, not a full DORA.** At T1 the client already knows its address and its server, so it just *unicasts* "renew please" and gets an ACK. It only falls back to broadcast (T2) or full Discover (after L) if the server has vanished. This is why a stable machine keeps the *same* address across months — it renews the same lease long before it ever expires. A machine that leaves and never renews silently loses its address at L, and the pool reclaims it. **That reclaim is the whole reason leases exist.**

## (D) Relay — crossing subnets

Here's the problem that "broadcast" creates: **routers do not forward broadcasts** (a broadcast storm across the whole internet would be catastrophic). So a client on subnet `10.0.2.0/24` broadcasts DISCOVER… and the central DHCP server on `10.0.1.0/24` never hears it. One server per subnet would be wasteful. The fix is a **DHCP relay agent** (aka *IP helper*), usually running on the router/gateway of each subnet:

```
   SUBNET 10.0.2.0/24                              SUBNET 10.0.1.0/24
  ┌──────────────────────┐                        ┌──────────────────────┐
  │ Client (no IP)        │                        │  Central DHCP server │
  │  broadcast DISCOVER   │                        │      10.0.1.10       │
  └─────────┬────────────┘                         └──────────▲───────────┘
            │ 255.255.255.255                                  │
            ▼                                                  │ UNICAST
  ┌──────────────────────┐   relay rewrites & unicasts         │
  │  ROUTER / RELAY AGENT │────────────────────────────────────┘
  │  10.0.2.1 (giaddr)    │   "A client on 10.0.2.0/24 wants an
  │  "ip helper-address   │    address — here's my giaddr so you
  │   10.0.1.10"          │    know which pool to draw from."
  └──────────────────────┘
```

The relay catches the broadcast, stamps the packet with its own subnet address in the **`giaddr`** (gateway IP address) field, and **unicasts** it across the router to the real server. The server reads `giaddr` to know *which pool* the client belongs to (draw from the `10.0.2.0/24` scope, not `10.0.1.0/24`), sends the reply back to the relay, and the relay broadcasts it onto the client's local wire. One central server can thus serve dozens of subnets. Keep the word **`giaddr`** — it's the single field that makes cross-subnet DHCP work.

## Where the cloud quietly rewrites all of this ☁️

Now the part that matters for your job. In a **VPC**, DHCP still exists — but it's *managed and invisible*:

- When an EC2 instance (your **EKS worker node**) launches into a subnet, the VPC's **DHCP option set** and the AWS-managed DHCP service hand it a private IP from the subnet's CIDR, plus the mask, the **VPC router** as gateway (always the `.1` of the subnet, e.g. `10.0.3.1`), and the **Amazon DNS server** at the base of the VPC CIDR + 2 (e.g. `10.0.0.2` for a `10.0.0.0/16` VPC — the "**AmazonProvidedDNS**"). So the node genuinely does DORA-style DHCP. But *you never run a DHCP server* — AWS is the server, the subnet is the scope, and the address is really pre-decided by the EC2 control plane (the ENI's private IP is allocated at instance-create time and DHCP just delivers it). The instance can also skip the wire entirely and read its config from the **Instance Metadata Service (IMDS)** at `169.254.169.254` — a link-local address that hands out identity without any broadcast at all.

- **Pods do NOT use DHCP. At all.** This is the fact your lead was fishing for. When a pod is scheduled, the **CNI plugin's IPAM** (IP Address Management) module allocates the pod's IP *directly and synchronously* and writes it into the pod's network namespace — no Discover, no Offer, no broadcast, no lease. On EKS the **VPC-CNI (`aws-node`)** pre-attaches a warm pool of secondary IPs to the node's ENIs and hands one to each new pod instantly. On Calico/Cilium/Flannel, the CNI's IPAM carves the pod out of a per-node slice of the cluster **pod CIDR**. The reason is **determinism and speed**: a scheduler creating 50 pods a second cannot wait ~1 second per pod for a broadcast handshake, cannot tolerate the non-determinism of "whatever the pool offers," and needs the IP to exist the instant the veth pair is wired. DHCP's whole model — *ask the wire, wait for an offer, hold a lease, renew it* — is the wrong tool for a system that mutates its address space thousands of times an hour.

```
  NODE gets its IP:                        POD gets its IP:
  ┌───────────────────────────┐            ┌───────────────────────────┐
  │ EC2 boots → DHCP/IMDS from │            │ Scheduler places pod →     │
  │ AWS-managed VPC service    │            │ kubelet calls CNI ADD →    │
  │ (DORA-ish, broadcast/L2 or │            │ CNI IPAM allocates IP      │
  │  metadata at .254)         │            │ DIRECTLY (no broadcast,    │
  │  → 10.0.3.157 from subnet  │            │  no lease) → 10.0.3.42     │
  └───────────────────────────┘            └───────────────────────────┘
        classic-ish DHCP                     programmatic IPAM, DHCP-free
```

> **✅ Check yourself before Rung 4:** A client's DISCOVER is a broadcast, and routers drop broadcasts. Explain *in your own words* how a single DHCP server in one subnet still manages to give addresses to clients in five other subnets — and name the one packet field that makes the server pick the right pool.

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Every scary word, pinned to what it actually is and which gear it touches*

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **DHCP** | Dynamic Host Configuration Protocol — auto-assigns IP config | The whole thing; runs over UDP 67 (server) / 68 (client) |
| **DORA** | Discover → Offer → Request → Acknowledge, the 4-packet handshake | (A) The lease acquisition sequence |
| **Discover** | Client's initial broadcast: "any server out there?" | (A) Packet 1, from `0.0.0.0` to `255.255.255.255` |
| **Offer** | Server's tentative loan proposal (IP + full config) | (A) Packet 2, server → client |
| **Request** | Client's broadcast acceptance of one offer | (A) Packet 3; also the *renewal* packet later |
| **Acknowledge (ACK)** | Server's binding confirmation of the lease | (A) Packet 4; also confirms renewals |
| **Lease** | Time-limited loan of an address to a MAC | (C) The reclaim mechanism; the "loan clock" |
| **T1 / renewal time** | ~50% of lease; client unicasts REQUEST to keep address | (C) The quiet renewal dance |
| **T2 / rebinding time** | ~87.5% of lease; client broadcasts REQUEST to any server | (C) Fallback when original server is gone |
| **DHCP server** | The authority that owns pools and the lease database | (B) Bookkeeping brain |
| **Scope** | The subnet a server is responsible for | (B) Defines which pool/config applies |
| **Address pool** | The assignable IP range inside a scope | (B) `10.0.1.100–.200` in our example |
| **Reservation** | "This MAC always gets this IP" (fixed IP via DHCP) | (B) Deterministic entry in the lease DB |
| **Exclusion** | Addresses inside the scope the server must never lend | (B) Protects gateway/DNS/static infra |
| **Relay agent / IP helper** | Router-side forwarder that unicasts DHCP across subnets | (D) Bridges broadcast → routed network |
| **`giaddr`** | Gateway IP field the relay stamps so the server picks the pool | (D) The one field cross-subnet DHCP hinges on |
| **`dhclient` / systemd-networkd** | The Linux client-side programs that *do* DORA | (A) The software running the handshake on a host |
| **Lease file** | On-disk record of the client's current lease | (C) Where a host remembers its address & timers |
| **IMDS** | Instance Metadata Service at `169.254.169.254` | Cloud alternative — identity without broadcast |
| **IPAM** | IP Address Management — allocates addresses programmatically | The CNI's DHCP-*replacement* for pods |
| **CNI / VPC-CNI** | Container Network Interface plugin (e.g. `aws-node`) | Wires the pod and calls IPAM — *not* DHCP |

**Same-kind-of-thing, different names** (this is where the fog usually is):

- **DORA's four names are two roles, alternating.** *Discover* and *Request* are the client speaking; *Offer* and *Acknowledge* are the server speaking. It's a call-and-response twice over: "anyone? / me. / you then. / done."
- **"Reservation," "fixed lease," "static DHCP mapping," and "DHCP static binding"** are all the same thing: a MAC-to-IP pin in the server's database. Don't confuse it with **static configuration**, which means the *device itself* is hand-configured and does no DORA at all.
- **"Relay agent," "IP helper," and "`ip helper-address`"** are the same feature — a name from the RFC, a Cisco-ism, and the config line that turns it on, respectively.
- **"Scope" (Windows/DHCP-server term) ≈ "subnet declaration" (ISC dhcpd term) ≈ "VPC subnet + DHCP option set" (AWS)** — three vendors' words for "the network this config applies to."
- **"Lease renewal" and the "Request" packet** are literally the same packet type; renewal just reuses DORA's third message without repeating D and O.

> **✅ Check yourself before Rung 5:** Without looking up — what's the difference between a **reservation** and a **static IP configuration**, given that both result in a device always having the same address? (Hint: *who* holds the mapping, and does the device run DORA?)

---

# RUNG 5 — The Trace 🔬
### *One concrete action, end to end: a laptop plugs in and gets online*

Let's follow a single laptop (MAC `aa:bb:cc:dd:ee:ff`) joining office subnet `10.0.1.0/24`, from dead-silent NIC to fully-online, naming the component at every hop. The DHCP server is `10.0.1.10`; gateway `10.0.1.1`; DNS `10.0.1.53`.

```
  ┌──────────┐        ┌──────────┐        ┌──────────────┐      ┌──────────┐
  │ LAPTOP   │        │  SWITCH  │        │ DHCP SERVER  │      │ THE WIRE │
  │ NIC only │        │  (L2)    │        │  10.0.1.10   │      │ /24 LAN  │
  └────┬─────┘        └────┬─────┘        └──────┬───────┘      └──────────┘
       │                   │                     │
  (1)  │  DISCOVER (bcast) │                     │
       ├──────────────────►│  floods to all ────►│
       │                   │                     │ (2) picks .157 from pool,
       │                   │                     │     writes tentative lease
  (3)  │  OFFER (bcast, my MAC inside) ◄──────────┤
       │◄──────────────────┤◄────────────────────┤
  (4)  │  REQUEST .157 (bcast) ───────────────────►
       ├──────────────────►│────────────────────►│ (5) commits lease in DB,
       │                   │                     │     expiry = now + 3600s
  (6)  │  ACK: .157/24, gw .1, dns .53 ◄──────────┤
       │◄──────────────────┤◄────────────────────┤
  (7)  │  ARP probe: "anyone using .157?" (silence = safe)
       │  → NIC now: 10.0.1.157/24, gw 10.0.1.1, dns 10.0.1.53
```

Step by step:

1. **Discover.** The laptop's DHCP **client** (`dhclient` or `systemd-networkd`) has no IP. It builds a UDP datagram from `0.0.0.0:68` to `255.255.255.255:67`, carrying its MAC and a transaction ID. The **NIC** frames it as an L2 broadcast (`ff:ff:ff:ff:ff:ff`).
2. **Switch floods it.** The **switch**, seeing a broadcast destination, forwards it out every port on the segment. The **DHCP server** receives it, checks its **pool** for subnet `10.0.1.0/24`, and picks a free address: `.157`. It records a *tentative* lease keyed to the laptop's MAC.
3. **Offer.** The server replies (broadcast, since the client isn't addressable yet) with `.157`, mask `/24`, gateway `10.0.1.1`, DNS `10.0.1.53`, and lease `3600s`. The client recognizes the packet by its own MAC and transaction ID.
4. **Request.** The client broadcasts "I accept `.157` from server `10.0.1.10`." Broadcasting means any *other* DHCP server that also Offered now sees it was declined and frees its tentative address.
5. **Server commits.** `10.0.1.10` writes the lease firmly into its **lease database**: `.157 → aa:bb:...:ff, expires now+3600s`.
6. **Acknowledge.** The server sends the binding ACK with the full config again. This is the client's green light.
7. **Client goes live.** A polite client sends a gratuitous **ARP probe** for `.157` to make sure nobody's squatting on it, then configures the NIC: `10.0.1.157/24`, default route via `10.0.1.1`, `nameserver 10.0.1.53` written into `/etc/resolv.conf`. The laptop is now a full network citizen — and at **T=1800s** it will quietly unicast a REQUEST to `10.0.1.10` to renew, keeping `.157` indefinitely.

**Cloud echo of the same trace:** an EKS node launches; the AWS-managed DHCP service (or IMDS at `169.254.169.254`) delivers `10.0.3.157/24`, gateway `10.0.3.1` (the VPC router), DNS `10.0.0.2` (AmazonProvidedDNS). Same shape, invisible server. Then a pod lands on that node and gets `10.0.3.42` — **skipping this entire trace** because the VPC-CNI's IPAM just *writes* the address into the pod namespace. No DORA. That contrast is the whole lesson.

> **✅ Check yourself before Rung 6:** In the trace, packet (4) REQUEST is a **broadcast** even though the client already knows exactly which server it wants to talk to. Why broadcast instead of unicast? (Think about who *else* needs to overhear it.)

---

# RUNG 6 — The Contrast ⚖️
### *DHCP vs static configuration vs cloud IPAM — and when to reach for each*

The alternative to DHCP is what came before it: **static configuration** — a human (or config file) sets IP, mask, gateway, and DNS directly on the device, which then does **no DORA at all**. And the *newer* alternative, for containers, is **programmatic IPAM**. Here's how the three stack up:

| Dimension | **Static config** | **DHCP (incl. reservations)** | **CNI IPAM (pods)** |
|---|---|---|---|
| Who assigns the IP | A human / hand-edited file | A server, on demand | The CNI plugin, programmatically |
| Does the device broadcast? | No | Yes (DORA) | No |
| Time to get an address | Instant (already set) | ~1 second (handshake) | Milliseconds (direct write) |
| Survives reboot with same IP? | Yes, always | Usually (renews the lease) | New pod = new IP (ephemeral) |
| Scales to churn? | Terribly | Well | Built for extreme churn |
| Central source of truth | A spreadsheet (drifts) | The lease database | The IPAM datastore / node CIDR slice |
| Determinism | Total | Pool = non-deterministic; reservation = deterministic | Deterministic & synchronous |
| Typical user | Servers, gateways, DNS, DBs | Laptops, phones, generic hosts, VMs, nodes | Kubernetes pods |

**What DHCP can do that static cannot:** hand thousands of churning devices a correct, conflict-free config with zero human touch, reclaim addresses automatically, and let a device roam networks. **What static can do that DHCP cannot (as reliably):** guarantee an address that *never* moves and *never* depends on a server being up — which is exactly why you want it for infrastructure.

**Why servers and infra use static or reserved addresses:** think about the bootstrap ordering. Your DNS server, your default gateway, your DHCP server itself, your database — everything else in the network *depends on these being at a known, fixed address*. If your DNS server got its address from DHCP and the DHCP server was down, nothing could resolve names, and the DHCP server can't very well DHCP itself its own identity. Critical infra sits at hand-picked, static addresses (or DHCP **reservations** if you want central management but stable IPs) so the rest of the network has stable anchors. In Kubernetes this same instinct is why **CoreDNS lives at a fixed ClusterIP** (typically `10.96.0.10`) and the **API server at a fixed ClusterIP** — pods are cattle with ephemeral IPs, but the services they depend on need permanent addresses. Determinism at the infrastructure layer is what makes ephemerality safe at the workload layer.

**When would I NOT use DHCP?** For anything other things must find at a fixed address: the gateway, DNS servers, the DHCP server, load balancers, databases, and — in a cluster — the addresses baked into config and certificates. And you don't use DHCP for **pods** at all, because CNI IPAM is faster, deterministic, and doesn't require a lease/renewal state machine per pod.

**Why this over that, in one sentence:** *Use DHCP when you have many transient devices that just need to be correct and online; use static/reserved when other things depend on this device always living at the same address; use CNI IPAM when you're allocating pod IPs, because DHCP's ask-and-wait model is the wrong tool for something that changes its address space thousands of times an hour.*

> **✅ Check yourself before Rung 7:** Your cluster's CoreDNS sits at a fixed ClusterIP `10.96.0.10`, but the pods behind it get ephemeral IPs from CNI IPAM. Explain why the *front door* must be static even though everything *behind* it is dynamic — and connect that to why a network's DNS/gateway are never DHCP clients.

---

# RUNG 7 — The Prediction Test 🧪
### *Commit to the prediction BEFORE you run the command. The gap between your guess and the result is the learning.*

For each example: read the prediction, decide whether you agree, *then* run it and check. (Client-side DHCP commands generally need `sudo` and a real NIC. The AWS/K8s examples reflect what you'll actually see on EKS.)

### Example 1 — Normal case: read your machine's current lease and prove it came from DHCP

**Prediction:** *If I inspect my lease, then I'll see the exact IP, gateway, DNS, and the server that issued it, plus lease-start and renewal times — BECAUSE the ACK's contents are written to a lease file the client keeps so it knows when to renew.*

```bash
# The DHCP client's on-disk lease file (location varies by distro/client):
#   ISC dhclient:     /var/lib/dhcp/dhclient.leases   (Debian/Ubuntu)
#                     /var/lib/dhclient/dhclient.leases (RHEL/older)
#   systemd-networkd: /run/systemd/netif/leases/<ifindex>
cat /var/lib/dhcp/dhclient.leases 2>/dev/null || \
  sudo cat /run/systemd/netif/leases/2 2>/dev/null

# A dhclient lease block looks like:
# lease {
#   interface "eth0";
#   fixed-address 10.0.1.157;
#   option subnet-mask 255.255.255.0;
#   option routers 10.0.1.1;                 ← default gateway
#   option domain-name-servers 10.0.1.53;    ← DNS
#   option dhcp-server-identifier 10.0.1.10; ← who gave it to me
#   option dhcp-lease-time 3600;
#   renew  5 2026/07/16 14:30:00;            ← T1
#   rebind 5 2026/07/16 14:48:00;            ← T2
#   expire 5 2026/07/16 14:55:00;            ← L
# }

# Cross-check the live config the lease produced:
ip -4 addr show            # your IP + mask (/24)
ip route show default      # default via <gateway>
cat /etc/resolv.conf       # nameserver <dns>  (or resolvectl status on systemd)
```

**Verify:** the `fixed-address`, `routers`, and `domain-name-servers` in the lease should exactly match `ip addr`, `ip route`, and `resolv.conf`. If `renew`/`rebind`/`expire` are in the future, your machine is happily leasing. **A wrong result teaches you:** if there's *no* lease file but you still have an IP, this interface is **statically** configured (or cloud-metadata configured) — it never did DORA, which is exactly the infra pattern from Rung 6.

### Example 2 — Edge/failure case: watch the DORA handshake live, then force a re-lease

**Prediction:** *If I sniff UDP 67/68 while I release and renew, then I'll capture Discover→Offer→Request→ACK in that order, with Discover sourced from `0.0.0.0` and destined for `255.255.255.255` — BECAUSE a client with no address can only reach the server by broadcast.*

```bash
# Terminal 1 — capture the handshake (DHCP = UDP ports 67 and 68):
sudo tcpdump -ni eth0 -v 'udp port 67 or udp port 68'

# Terminal 2 — drop the lease, then ask for a fresh one:
sudo dhclient -r eth0        # -r = release current lease (sends DHCPRELEASE)
sudo dhclient    eth0        # acquire a new lease → triggers full DORA
# systemd-networkd equivalent:
#   sudo networkctl renew eth0

# Expected tcpdump lines (abbreviated):
#   0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request from aa:bb:.. , DHCP-Message: Discover
#   10.0.1.10.67 > 255.255.255.255.68: BOOTP/DHCP, Reply,             DHCP-Message: Offer
#   0.0.0.0.68 > 255.255.255.255.67: BOOTP/DHCP, Request,             DHCP-Message: Request
#   10.0.1.10.67 > 255.255.255.255.68: BOOTP/DHCP, Reply,             DHCP-Message: ACK
```

**Verify:** you should see all four message types, and the Discover/Request must come from `0.0.0.0`. **A wrong result teaches you:** if you see *only* a two-packet Request/ACK (no Discover/Offer), the client was *renewing* an existing lease by unicast, not acquiring a new one — that's the T1 renewal path from Rung 3, proof that renewal skips D and O. If you see Discover repeated with no Offer ever arriving, there's **no reachable DHCP server** on this segment (or a relay is missing) — the classic "device stuck at a `169.254.x.x` APIPA self-assigned address" failure.

### Example 3 — Cloud/Kubernetes case: prove the node used DHCP-style assignment but the pod did NOT

**Prediction:** *If I compare how an EKS node got its IP versus how a pod got its IP, then the node's config will trace to the VPC subnet's DHCP/metadata service while the pod's IP was allocated directly by the VPC-CNI with no lease at all — BECAUSE nodes are long-lived L2 citizens but pods need deterministic, sub-second IPAM.*

```bash
# --- On the NODE (SSH to a worker), see the DHCP-ish / metadata identity ---
# The address the node received from the VPC (delivered via DHCP/IMDS):
ip -4 addr show
ip route show default                 # default via 10.0.3.1  (the VPC router = subnet .1)
# The instance read its identity from the Instance Metadata Service (link-local):
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4      # → 10.0.3.157
# The VPC's DHCP option set (which DNS/domain the DHCP service hands out):
aws ec2 describe-dhcp-options \
  --query 'DhcpOptions[].DhcpConfigurations' --output table

# --- For the POD, see IPAM (NOT DHCP) do the allocation ---
kubectl get pod mypod -o wide                     # POD IP e.g. 10.0.3.42 on that node
# On EKS, VPC-CNI hands out secondary ENI IPs — there is NO dhclient in the pod:
kubectl exec mypod -- sh -c 'which dhclient || echo "no DHCP client in this pod"'
# Inspect what the CNI IPAM actually assigned (the plumbing DHCP never touched):
kubectl exec mypod -- ip -4 addr show eth0        # the CNI-written pod IP
# On the node, VPC-CNI's warm pool of pre-attached IPs (the IPAM inventory):
kubectl get eniconfigs 2>/dev/null                # (if custom networking)
kubectl -n kube-system logs ds/aws-node | grep -i 'assigned\|ipamd' | head
```

**Verify:** the node's default route points at the subnet's `.1` (VPC router) and its IP matches IMDS `local-ipv4` — that's the DHCP/metadata path. The pod has a real IP on `eth0` but **no DHCP client and no lease file** — proof the VPC-CNI IPAM *wrote* the address directly. **A wrong result teaches you:** if you expected the pod to renew a lease and found none, you've just confirmed the central thesis — **pods don't do DHCP**, and if the `aws-node` IPAM pool is exhausted, new pods get stuck in `ContainerCreating` with `failed to assign an IP address to container`, which is an *IPAM* failure, not a DHCP timeout. Recognizing which of the two subsystems failed is the difference between debugging the VPC and debugging the CNI.

---

# CAPSTONE — Compress It 🏔️

**One sentence (no notes):**
DHCP lets an address-less device broadcast a request onto its local wire and receive, from a server that owns a pool, a complete and time-limited IP configuration — while cloud nodes use a managed version of this and Kubernetes pods bypass it entirely for deterministic CNI IPAM.

**Explain it to a beginner in three sentences:**
When a computer joins a network it has no IP address, so it shouts "does anyone here hand out addresses?" to everyone on the local wire, and a DHCP server answers by lending it an IP plus the mask, gateway, and DNS it needs to work. The loan is called a lease and it expires, so the computer keeps renewing it to hold its address, and when a device leaves for good its address is reclaimed for someone else. Servers and critical infrastructure skip all this and use fixed addresses so that everything else has stable anchors to depend on.

**Sub-parts mapped back to the one core idea** — *"broadcast a request, get a leased config from a pool"*:

- **DORA** → the four packets that *are* the broadcast-and-answer.
- **Lease + renewal (T1/T2)** → the "time-limited" clause; the reclaim engine.
- **Pool + scope** → the "server that owns a pool" the config is drawn from.
- **Reservation** → a pool entry pinned to a MAC for stability without static config.
- **Relay (`giaddr`)** → how the broadcast reaches a server across a router.
- **Static / reserved infra** → the deliberate opt-*out* for things others depend on.
- **Cloud IPAM / VPC-CNI** → the "pods bypass it" clause; direct allocation, no broadcast, no lease.

**Which rung to revisit hands-on:**
Go back to **Rung 3 (Machinery)** and **Rung 7, Example 2** together. Sniffing a live DORA exchange with `tcpdump` while you `dhclient -r && dhclient` is the single fastest way to make the four packets stop being letters (D-O-R-A) and start being real datagrams you watched cross the wire. Once you've *seen* Discover leave from `0.0.0.0`, the renewal shortcut, the relay's `giaddr`, and "pods have no dhclient" all click into place at once.

---

## Related concepts

- [IP addressing](02-ip-addressing.md) — what the address DHCP hands out actually means, plus link-local `169.254.x.x` (APIPA/metadata).
- [Subnetting and CIDR](03-subnetting-and-cidr.md) — the mask DHCP delivers, and the pool/usable-host math (`/24` = 254).
- [MAC addresses, switching, ARP](05-mac-addresses-switching-arp.md) — the MAC that keys every lease, and the ARP probe a client does before going live.
- [DNS](09-dns.md) — the resolver addresses DHCP configures, and CoreDNS at a fixed ClusterIP.
- [NAT and PAT](14-nat-and-pat.md) — what happens to your DHCP-assigned private address once it leaves the subnet.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — the IPAM that *replaces* DHCP for pods, in full detail.
- [AWS VPC](20-aws-vpc.md) — DHCP option sets, the managed DHCP service, subnets, and the VPC router at `.1`.
