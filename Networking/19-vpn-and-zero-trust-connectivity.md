# VPN & Zero-Trust Connectivity

*How to build an encrypted tunnel across the hostile public internet — the trick that stitches your on-prem data center to an EKS VPC, lets an engineer reach a private node without a public IP, and quietly encrypts pod-to-pod traffic inside Cilium.*

---

## 🧗 Rung 0 — The Setup

**What am I learning?**

You're learning the **VPN (Virtual Private Network)** — a way to carry private traffic *inside an encrypted tunnel across an untrusted network* (usually the public internet), so that two things far apart behave as if they share one private LAN, and nobody in between can read or forge the traffic.

There are two shapes of VPN, and they are not the same job:

- **Remote-access VPN** — *one user* securely reaches *a private network*. Your laptop, from a coffee shop, joins the corporate `10.x` network. The tunnel endpoint on your side is a piece of software; the other side is a concentrator/gateway.
- **Site-to-site VPN** — *two whole networks* are glued together. An on-prem data center (`10.10.0.0/16`) and an AWS VPC (`10.0.0.0/16`) talk as if a single router sat between them. No per-user client — two *gateways* hold the tunnel up permanently.

And there's a mindset that rides on top of all of this: **zero-trust connectivity** — *stop trusting a packet just because it arrived from "inside" the network*. Authenticate every device and every request on its own merits, every time, regardless of where it came from. The VPN of 2005 said "get inside the perimeter and you're trusted." Zero trust says "there is no inside."

**Why did it land on your desk?**

You're a platform engineer on EKS, ~6 years in. Three things hit this sprint:

1. *"Finance's on-prem Oracle box needs to talk to the new service in our EKS VPC — and it must never touch the public internet."* That's a **site-to-site VPN** (or later a Direct Connect), terminating on an **AWS VPN Gateway**, with route tables and Security Groups that have to agree on both sides. This is the hybrid-cloud bread-and-butter of every migration.
2. *"How does on-call actually SSH into a private worker node when it has no public IP?"* The old answer is a **bastion host**. The modern answer is a **mesh VPN** (WireGuard/Tailscale) where your laptop forms a direct encrypted link to something inside the VPC — no public SSH port exposed to the planet at all.
3. *"Compliance wants all pod-to-pod traffic encrypted, even inside the VPC."* You reach for **WireGuard transparent encryption in the CNI** — Cilium or Calico flips a flag and every packet between nodes rides an encrypted tunnel, with zero application changes.

Every one of those is this file.

**What do I already know already (the ladder so far)?**

- **[IP addressing](02-ip-addressing.md)** — private ranges `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` are non-routable on the public internet. A VPN is precisely how two islands of private address space reach each other *across* the public internet.
- **[Subnetting & CIDR](03-subnetting-and-cidr.md)** — a site-to-site VPN lives or dies on **non-overlapping CIDRs**. If on-prem is `10.0.0.0/16` and your VPC is *also* `10.0.0.0/16`, routing is ambiguous and the tunnel is useless. This is the #1 real-world VPN failure.
- **[NAT & PAT](14-nat-and-pat.md)** — NAT hides private hosts behind one public IP, which is exactly why a mesh VPN needs **NAT traversal** to punch a direct path between two devices that are both hidden.
- **[TLS / encryption in transit](11-tls-ssl-encryption-in-transit.md)** — a VPN and TLS both encrypt, but at different layers. TLS wraps *one application connection*; a VPN wraps *whole packets* (all ports, all protocols) below the app. Keep that distinction warm.
- **[Routing & forwarding](08-routing-and-forwarding.md)** — a tunnel is ultimately a *route*: "to reach `10.10.0.0/16`, send the packet into interface `wg0` / the IPsec tunnel." A VPN is a routing decision plus encryption.
- **[Firewalls, SGs & NACLs](17-firewalls-security-groups-nacls.md)** — the tunnel still has to be *permitted* by Security Groups and NACLs on both ends. Encryption doesn't bypass the firewall; it rides through a hole you punch in it.

Hold those. We build straight up from them.

---

## 🔥 Rung 1 — The Pain

The internet is a **shared, hostile, public medium**. Every packet you send between two cities crosses a dozen routers owned by companies you've never heard of. Anyone on that path can — in principle — **read** your packets (it's plaintext by default), **forge** packets that claim to be from you (nothing checks the source), or **replay** old ones. That's the environment. Now try to run a business across it.

**The pain, stated plainly:** you have two private networks (or one user and one private network) separated by the public internet, and you need them to communicate *as if they were on the same trusted LAN* — with confidentiality (nobody reads it), integrity (nobody tampers with it), and authenticity (you know who you're talking to). The raw internet gives you *none* of those.

**What people did before, and why it hurt:**

- **Lease a private physical line.** Pay a telco for a dedicated point-to-point circuit (a leased line, Frame Relay, later MPLS) between your two offices. It works and it's private — but it costs a fortune, takes weeks to provision, and doesn't stretch to a laptop in a hotel. You cannot lease a copper line to every remote worker.
- **Just expose the service publicly and hope.** Put the database on a public IP, slap a password on it, cross your fingers. This is how breaches happen. A public port is scanned by bots within *minutes* of coming online.
- **Trust the perimeter (the castle-and-moat era).** Build a big firewall around the office. Anyone *inside* is trusted; anyone *outside* is not. This is the model that VPNs were born to extend — "let the remote user tunnel *inside* the moat, then trust them completely." It felt safe. It was a time bomb (more on that in a second).

**What breaks without a VPN:**

- **No hybrid cloud.** Your on-prem data center and your EKS VPC can't share private services without shoving traffic onto the public internet in the clear. Migrations stall.
- **No safe remote access.** Engineers can't reach private nodes, dashboards, or databases without exposing them to the world.
- **No confidentiality on shared infrastructure.** Even inside a cloud provider, traffic between availability zones crosses cables you don't own. Compliance (PCI, HIPAA) may demand it be encrypted regardless.

**The sneakier, deeper pain — the trusted perimeter itself became the vulnerability.** The classic VPN said: *authenticate once at the edge, then you're "inside" and trusted.* But once an attacker phishes one VPN credential, they're *inside the moat* — and inside, nothing is checked. They move laterally from the compromised laptop to the database to the domain controller, because the network trusted them the moment they got in. Target, and dozens of others, were breached exactly this way. The lesson that became **zero trust**: *network location must confer no trust at all.* Being "on the VPN" or "in the VPC" should mean nothing. Every connection re-authenticates.

**Who feels the pain most?** The platform engineer who "secured" the cluster by putting nodes in a private subnet — and then either (a) can't reach them at all, or (b) pokes a bastion with a public SSH port that becomes the single most-attacked box in the account. VPN + zero trust is the way out of that false choice.

> **Check yourself before Rung 2:** TLS already encrypts your HTTPS traffic end-to-end. So why would a company still route that *already-encrypted* HTTPS through a site-to-site VPN tunnel? What does the VPN give you that per-connection TLS does not? (Hint: think about *which* packets get protected, and about the source-IP / private-routing story, not just secrecy.)

---

## 💡 Rung 2 — The One Idea

Memorize this sentence. Write it on a sticky note. Everything else in this file is a corollary of it:

> **A VPN wraps whole private packets inside encrypted, authenticated packets addressed gateway-to-gateway, so private traffic rides safely across a public network as if the two ends shared one trusted LAN — and zero trust adds: never grant trust for being on that LAN.**

Say it slowly: **encapsulate + encrypt + authenticate + route.** The private packet becomes *payload* inside a new outer packet. That's the whole trick — it's called **tunneling**.

Now watch everything derive from it:

- **Why "virtual" and "private"?** Private, because the inner packets use private addresses and only the two ends can read them. Virtual, because there's no physical private wire — the privacy is *synthesized* by encryption over shared public infrastructure.
- **Why does remote-access differ from site-to-site?** Same mechanism, different *endpoints*. Remote-access: one tunnel endpoint is a user's software client. Site-to-site: both endpoints are always-on *gateways* representing whole subnets. The encapsulation is identical; who holds the ends differs.
- **Why so many protocols (IPsec, OpenVPN, WireGuard)?** They're just different recipes for the *encrypt + authenticate + encapsulate* step. Same job, different key exchange, different code size, different speed.
- **Why does a mesh beat a hub-and-spoke?** If every tunnel must terminate at one central concentrator, all traffic detours through it (a bottleneck). If instead the One Idea is applied *pairwise* — every device tunnels *directly* to every other — you get a mesh with no chokepoint. That's WireGuard/Tailscale.
- **Why does the CNI use it?** Cilium/Calico apply the exact same "wrap each packet in an encrypted WireGuard packet" step to *pod-to-pod* traffic between nodes. The tunnel just happens to be inside your cluster instead of across the internet.
- **Why zero trust on top?** Because the tunnel proves *the pipe* is private — it does **not** prove the *device or user* at the end deserves access. Zero trust checks that separately, every time.

One sentence. Six corollaries. That's the file.

> **Check yourself before Rung 3:** From the One Idea alone, explain why a VPN can carry protocols it has never heard of — a database on port 5432, an old UDP game protocol, ICMP pings — all at once through one tunnel, whereas a TLS-terminating load balancer fundamentally cannot. Which word in the One Idea is doing that work?

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### The diplomatic pouch analogy (then we ground it hard in packets)

A diplomat needs to send a sensitive letter from Embassy A (in a foreign, hostile city) to Embassy B (in another). She can't trust the local post. So she puts the real letter — addressed *internally*, "to the Ambassador's desk, room 12" — inside a **sealed diplomatic pouch**. The pouch has a *new outer label*: "Embassy A → Embassy B," and by treaty **no one along the way may open it**. Couriers, customs, and airlines route the pouch by its outer label, oblivious to what's inside. At Embassy B, a trusted clerk opens the pouch and delivers the inner letter to room 12.

Map it:

| Diplomacy | Network |
|---|---|
| Inner letter ("to room 12") | The original **private packet** (`dst 10.0.4.5:5432`) |
| Sealed pouch | **Encryption + authentication** (nobody reads or forges it) |
| Outer label ("Embassy A → Embassy B") | The **outer IP header** (public IP of gateway A → public IP of gateway B) |
| Couriers who route by the outer label | Every public-internet **router** on the path |
| "No one may open the pouch" | Only the two gateways hold the keys |
| Clerk at Embassy B who unwraps | The receiving **VPN gateway** that decrypts and forwards inward |

The couriers move the pouch **without ever knowing the inner address.** That's **encapsulation**: your private packet is the *payload* of a brand-new public packet. The internet routes the outer packet; the inner one is invisible.

### What actually moves: encapsulation on the wire

Here is a single application packet — say a pod at `10.0.4.5` querying an on-prem Postgres at `10.10.9.9:5432` — as it crosses a site-to-site VPN. Watch the packet grow an outer wrapper, cross the internet opaque, then shed it:

```
        VPC SIDE                         PUBLIC INTERNET                     ON-PREM SIDE
   (private 10.0.0.0/16)          (owned by nobody you trust)          (private 10.10.0.0/16)

  Pod 10.0.4.5                    VPN GW A                 VPN GW B                 Postgres
   │  original packet             pub 203.0.113.7          pub 198.51.100.4          10.10.9.9:5432
   │  ┌───────────────────┐          │                        │                        │
   └─▶│ src 10.0.4.5      │          │                        │                        │
      │ dst 10.10.9.9:5432│──route──▶│                        │                        │
      │ [ Postgres query ]│          │  ENCRYPT + WRAP        │                        │
      └───────────────────┘          ▼                        │                        │
                             ┌─────────────────────────────┐  │                        │
                             │ OUTER: src 203.0.113.7      │  │                        │
                             │        dst 198.51.100.4     │  │                        │
                             │ ESP/UDP: [ encrypted blob ─ │──┼── the internet routes  │
                             │   {src 10.0.4.5             │  │   ONLY the outer header;│
                             │    dst 10.10.9.9:5432       │  │   the inner packet is  │
                             │    Postgres query} ]        │  │   an opaque ciphertext │
                             └─────────────────────────────┘  ▼                        │
                                                      DECRYPT + UNWRAP                  │
                                                      ┌───────────────────┐            │
                                                      │ src 10.0.4.5      │───route───▶│
                                                      │ dst 10.10.9.9:5432│  delivered │
                                                      │ [ Postgres query ]│  as if LAN │
                                                      └───────────────────┘            │
```

Three facts to burn in from that diagram:

1. **The inner private addresses never appear on the public internet.** Backbone routers only ever see `203.0.113.7 → 198.51.100.4`. They *cannot* route `10.x` and never have to. This is why a VPN lets non-routable private ranges reach each other.
2. **Everything above the outer header is ciphertext.** Ports, protocol, payload — all hidden. A VPN protects *arbitrary* traffic (any port, TCP/UDP/ICMP) because it operates *below* the application, on whole packets. That's the answer to the Rung 2 check.
3. **The tunnel is a route.** Gateway A only wrapped that packet because its routing table said "`10.10.0.0/16` → tunnel to `198.51.100.4`." No route, no tunnel.

### The protocols — three recipes for the same wrap

```
  ┌──────────────┬─────────────────────────────────────────────────────────────────┐
  │ IPsec        │ The old-guard standard. Works at L3 (IP layer). Two sub-parts:   │
  │              │  • IKE (Internet Key Exchange, UDP 500 / UDP 4500 for NAT-T)     │
  │              │    negotiates keys — this is "phase 1 / phase 2."                 │
  │              │  • ESP (Encapsulating Security Payload, IP proto 50) carries the  │
  │              │    encrypted packets. This is what AWS site-to-site VPN speaks.   │
  │              │  Powerful, interoperable, and famously fiddly to configure.       │
  ├──────────────┼─────────────────────────────────────────────────────────────────┤
  │ OpenVPN      │ Runs in userspace over TLS (uses the OpenSSL/TLS stack). Usually  │
  │              │ UDP 1194. Very flexible, firewall-friendly (can ride TCP 443 to   │
  │              │ look like HTTPS), but slower — every packet crosses user/kernel.  │
  ├──────────────┼─────────────────────────────────────────────────────────────────┤
  │ WireGuard    │ The modern one. ~4,000 lines of code, in the Linux kernel. UDP    │
  │              │ only (default 51820). Fixed modern crypto (Curve25519,            │
  │              │ ChaCha20-Poly1305) — no negotiation to misconfigure. Stateless-ish│
  │              │ peers identified by public key. Fast, simple, mesh-friendly.      │
  └──────────────┴─────────────────────────────────────────────────────────────────┘
```

WireGuard's model is worth internalizing because the whole modern mesh world is built on it: **every peer is just a public key plus a list of "AllowedIPs" it's responsible for.** There's no "client" and "server" — only peers. To send to `10.10.9.0/24`, you look up which peer's public key owns that CIDR, encrypt to that key, and send to that peer's current public `endpoint`. That's it. That symmetry is exactly what makes a *mesh* natural.

### Hub-and-spoke bottleneck vs mesh

The classic corporate VPN is **hub-and-spoke**: one big **concentrator** (VPN gateway) in the data center; every laptop and every branch office tunnels *to it*. That's simple to manage but has a brutal flaw — **all traffic detours through the hub**, even two laptops sitting next to each other, even a branch office reaching a cloud service.

```
        HUB-AND-SPOKE (bottleneck)                     MESH (direct peer tunnels)

     Laptop A                Laptop B                Laptop A ───────── Laptop B
         \                    /                         │ \           / │
          \                  /                          │   \       /   │
           ▼                ▼                           │     \   /     │
        ┌─────────────────────┐                         │      \ /      │
        │  VPN CONCENTRATOR   │  ◀── every packet       │       X       │
        │      (the hub)      │      passes here,       │      / \      │
        └─────────────────────┘      even A↔B           │     /   \     │
           ▲                ▲                           │   /       \   │
          /                  \                          │ /           \ │
     Branch office       Cloud VPC               Branch office ──── Cloud VPC

     A→B latency: A→hub→B (a detour,            A→B latency: A→B (a straight line,
     hub is a chokepoint & single point         no chokepoint; the hub is only a
     of failure and a bandwidth cap)            "coordination server," not a data path)
```

**Mesh VPNs (WireGuard, Tailscale, Netmaker)** flip this. A lightweight **coordination/control server** (Tailscale's "coordination server," or Headscale self-hosted) hands out keys and tells each peer where the others are — but it is **not in the data path**. Actual packets go **peer-to-peer, directly encrypted**. Add a node and it forms direct tunnels to the peers it needs; no re-plumbing a central box.

### NAT traversal — how two hidden peers find each other

Here's the hard part a mesh must solve: both peers are usually behind NAT (see **[NAT & PAT](14-nat-and-pat.md)**) — neither has a public IP, and unsolicited inbound is dropped. So how do two hidden devices open a *direct* tunnel? The trick is **UDP hole punching**, coordinated by the (public) control server:

```
   Laptop A behind NAT-A            Coordination server         Laptop B behind NAT-B
   (no public IP)                   (public, reachable)          (no public IP)
        │                                  │                          │
        │  1. "here's my public            │   1. "here's my public   │
        │      endpoint as NAT-A sees it"  │       endpoint (NAT-B)"  │
        ├─────────────────────────────────▶│◀─────────────────────────┤
        │                                  │                          │
        │  2. server tells A: "B is at NAT-B:port"                     │
        │     server tells B: "A is at NAT-A:port"                     │
        │◀─────────────────────────────────┼─────────────────────────▶│
        │                                  │                          │
        │  3. A and B BOTH send UDP to each other's public endpoint    │
        │     AT THE SAME TIME. Each outbound packet opens a return    │
        │     hole in its own NAT's conntrack table. The two holes     │
        │     line up ─ and now packets flow DIRECTLY, no hub:         │
        │                                                              │
        │◀════════════ DIRECT ENCRYPTED WIREGUARD TUNNEL ═════════════▶│
```

Because WireGuard is **UDP and connectionless**, both sides sending simultaneously means each NAT sees its own device "start" the conversation, creates a SNAT/conntrack entry, and therefore *accepts* the reply. The hole is punched. (When symmetric NAT on both ends defeats this — rare — the system falls back to relaying through a **DERP** relay, which *is* in the data path, hub-style, but only as a last resort.)

### Zero trust — the layer above the tunnel

The tunnel makes the *pipe* private. It does **not** answer "should this device/user be allowed to reach this service *right now*?" Zero trust does, on the principle **"never trust, always verify — network location grants nothing."** In practice:

```
   Old perimeter model                     Zero-trust model
   ───────────────────                     ────────────────
   "Are you inside the VPN/VPC?"           For EVERY request, check ALL of:
        │                                    • device identity (is this a known,
        ▼                                       healthy, enrolled device?)
   yes ─▶ trust everything                    • user identity (SSO, MFA)
        (lateral movement is free)            • policy (is THIS user allowed
                                                 THIS service, right now?)
                                              • re-verified continuously, not once
                                            Being "on the network" = worth nothing.
```

Modern mesh VPNs (Tailscale, Cloudflare/Zscaler ZTNA) fold identity *into* the tunnel: a peer only exists if its user is authenticated via SSO, and ACLs say which peers may reach which — so the VPN and the zero-trust policy are the same system. This is the direct sibling of **[network security & zero trust](30-network-security-zero-trust-ids-ips.md)**, and of service-mesh **[mTLS](29-service-mesh-and-sidecars.md)**, which does the identical "authenticate every peer, encrypt every hop" idea *inside* the cluster.

### Where this lives in your cluster / cloud

- **Site-to-site to an EKS VPC:** an **AWS Site-to-Site VPN** = a **Virtual Private Gateway (VGW)** or **Transit Gateway** on the AWS side + a **Customer Gateway (CGW)** describing your on-prem router, joined by two IPsec tunnels (redundant). You add a route (`10.10.0.0/16 → vgw-…`) to the VPC subnet route tables, and Security Groups must permit the on-prem CIDR. Now on-prem hosts reach pods/services by private IP.
- **Bastion vs VPN for node access:** a **bastion** (jump host) is a hardened public box you SSH *through* to reach private nodes — one exposed port, one audited hop. A **mesh VPN** removes even that: your laptop becomes a peer inside the VPC's address space and reaches nodes directly, with **no public SSH port anywhere** (the zero-trust win). AWS's own **SSM Session Manager** is another "no bastion, no open port" approach.
- **Mesh for multi-cluster / multi-cloud:** WireGuard/Tailscale meshes let pods or nodes across EKS + GKE + on-prem address each other privately without a public LB per service.
- **CNI transparent encryption:** **Cilium** (`enable-wireguard: true`) and **Calico** (`wireguardEnabled: true`) create a `wg0`-style device on every node and route all inter-node pod traffic through it — every pod-to-pod packet is WireGuard-encrypted, no app change, no sidecar. It's the site-to-site pattern, shrunk to node-to-node.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **VPN** | Encrypted tunnel carrying private packets over a public network | The whole file |
| **Tunnel / tunneling** | Putting one packet inside another as payload | The encapsulation step (outer header wraps inner packet) |
| **Encapsulation** | Wrapping the original packet in a new outer IP header | What makes private addresses cross the public internet |
| **Remote-access VPN** | One user's device joins a private network | Endpoint = a software client on a laptop |
| **Site-to-site VPN** | Two whole networks glued as one | Endpoints = always-on gateways per subnet |
| **VPN gateway / concentrator** | The device that terminates tunnels and en/decrypts | Both ends of the tunnel; the hub in hub-and-spoke |
| **IPsec** | L3 VPN standard: IKE for keys + ESP for data | AWS site-to-site; the "encrypt+auth" recipe |
| **IKE** | Internet Key Exchange (UDP 500 / 4500) — negotiates keys | IPsec's key-agreement phase |
| **ESP** | Encapsulating Security Payload (IP protocol 50) | IPsec's actual encrypted-packet carrier |
| **NAT-T** | NAT Traversal: wraps ESP in UDP 4500 to survive NAT | Makes IPsec work when a gateway is behind NAT |
| **OpenVPN** | Userspace TLS-based VPN (UDP 1194 / TCP 443) | The "encrypt+auth" recipe, TLS flavor |
| **WireGuard** | Modern in-kernel VPN, UDP 51820, key-per-peer | The recipe behind mesh VPNs and CNI encryption |
| **AllowedIPs** | The CIDRs a WireGuard peer is responsible for | Routing: which peer owns which inner addresses |
| **`wg` / `wg-quick`** | CLI to configure / bring up WireGuard interfaces | Creates the `wg0` device and its peer table |
| **Hub-and-spoke** | All tunnels terminate at one central concentrator | The bottleneck topology |
| **Mesh VPN** | Peers form direct encrypted tunnels to each other | The no-chokepoint topology |
| **Coordination server** | Control plane that shares keys/endpoints (not in data path) | Tailscale/Headscale; hands peers their maps |
| **NAT traversal / hole punching** | Trick to open a direct path between two NAT'd peers | UDP simultaneous-send that lines up conntrack holes |
| **DERP relay** | Fallback that relays traffic when hole-punch fails | Last-resort data path in a mesh |
| **Zero trust** | Grant no trust for network location; verify every request | The policy layer above the tunnel |
| **ZTNA** | Zero-Trust Network Access — product form of zero trust | Identity-gated access replacing perimeter VPNs |
| **Bastion / jump host** | Hardened public host you SSH through to reach private ones | The pre-VPN node-access pattern |
| **VGW / TGW / CGW** | AWS Virtual/Transit Gateway + Customer Gateway | The two ends of an AWS site-to-site VPN |
| **Split vs full tunnel** | Whether *all* traffic or only *some* CIDRs go via the VPN | A routing choice on the client (AllowedIPs / routes) |

**Terms that are the same kind of thing wearing different names:**

- **VPN gateway = concentrator = VPN server = tunnel endpoint = (AWS) VGW/TGW.** All mean "the box that terminates a tunnel and does the crypto."
- **IPsec, OpenVPN, WireGuard** are all "the encrypt + authenticate + encapsulate recipe" — interchangeable *roles*, different implementations.
- **Zero trust ≈ ZTNA ≈ BeyondCorp ≈ (inside the cluster) service-mesh mTLS.** All say "authenticate the peer every time; the network is not a trust boundary."
- **Tunnel = overlay = encapsulation.** A VPN tunnel and a **[VXLAN overlay](16-vlans-and-segmentation.md)** and the CNI's node-to-node tunnel are all "one packet riding inside another." The VPN's distinguishing extra is *encryption*.
- **Mesh coordination server ≈ SDN control plane ≈ mesh control plane (Istiod).** A brain that programs peers/proxies but stays out of the data path.

> **Check yourself before Rung 5:** Someone says "we use IPsec, not a VPN." Why is that sentence confused? Name the layer IPsec occupies and where it sits inside the VPN vocabulary above.

---

## 🔬 Rung 5 — The Trace

Let's follow **one packet** end to end: an on-prem monitoring server at `10.10.5.20` scrapes a Prometheus metrics endpoint on an EKS pod, reachable via a Kubernetes **[ClusterIP-fronted](25-kubernetes-services-kube-proxy.md)** service, across an **AWS Site-to-Site VPN**. The target is a private service IP `10.0.60.10:9090`. Non-overlapping CIDRs: on-prem `10.10.0.0/16`, VPC `10.0.0.0/16`.

```
 STEP 1                 STEP 2-3                STEP 4-5           STEP 6-7          STEP 8
 on-prem host           on-prem router          public internet    AWS VGW           inside VPC
 10.10.5.20             = Customer GW (CGW)      (opaque ESP)       terminates        DNAT + deliver
 ┌──────────┐   route   ┌──────────────┐  ESP   ┌────────────┐    ┌──────────┐      ┌──────────┐
 │ SYN to   │──10.0/16─▶│ encrypt+wrap │══════▶ │ routers see│══▶ │ decrypt  │────▶ │ pod:9090 │
 │10.0.60.10│  via VPN  │ outer: CGW→  │  UDP   │ CGW_pub →  │    │ inner:   │ kube │ replies  │
 │ :9090    │           │       VGW    │  4500  │ VGW_pub    │    │10.0.60.10│ proxy│  SYN-ACK │
 └──────────┘           └──────────────┘        └────────────┘    └──────────┘ DNAT └──────────┘
```

1. **App emits the packet.** The monitoring server opens a TCP connection: `src 10.10.5.20:44321 → dst 10.0.60.10:9090`, flags **SYN**. Plain private packet, no encryption yet.
2. **Routing decision on-prem.** The host's default route sends it to the on-prem router. The router's table has a static (or BGP-learned) route: **`10.0.0.0/16` → the IPsec tunnel** to the AWS VGW. That route is the *entire* reason this becomes a tunneled packet.
3. **Encapsulate + encrypt (Customer Gateway).** The on-prem gateway (the **CGW**) encrypts the whole inner packet with the IPsec session key (negotiated earlier by **IKE** over UDP 500/4500) and wraps it: **OUTER `src CGW_public → dst VGW_public`, ESP payload = {encrypted inner packet}**. Because the CGW is behind NAT, it uses **NAT-T** (ESP-in-UDP 4500).
4. **Across the public internet.** Backbone routers forward the *outer* packet by its public destination. They **decrement TTL** at each hop, see only `CGW_public → VGW_public`, and have no idea `10.10.5.20` or `10.0.60.10` exist. The inner packet is ciphertext.
5. **VGW receives + decrypts.** The AWS **Virtual Private Gateway** authenticates the ESP packet (integrity check — was it tampered? forged?), decrypts it, and recovers the original inner packet `10.10.5.20:44321 → 10.0.60.10:9090 [SYN]`.
6. **Routing inside the VPC.** The VGW injects the packet into the VPC. The subnet **route table** and **Security Group** on the target must permit `10.10.0.0/16` inbound on 9090 — the tunnel doesn't bypass the firewall, it delivers *into* it. If the SG lacks that rule, the packet dies here (a very common "the tunnel is up but nothing works" bug).
7. **ClusterIP → pod (kube-proxy DNAT).** `10.0.60.10` is a **ClusterIP** — a virtual IP no NIC owns. **kube-proxy**'s iptables (or IPVS) rules **DNAT** it to a real pod IP, say `10.0.61.7:9090`, load-balanced across endpoints.
8. **Pod replies.** Prometheus answers with **SYN-ACK**, and the whole path runs in reverse: pod → kube-proxy un-DNATs → VGW re-encrypts → internet (opaque) → CGW decrypts → on-prem host completes the **TCP 3-way handshake** with a final **ACK**. From the app's view, it just talked to `10.0.60.10:9090` on a "local" network. It never knew about the pouch.

The load-bearing insight: **the tunnel is transparent to the application and opaque to the internet.** The app sees a flat private LAN; the internet sees two public IPs exchanging encrypted blobs. Everything private happens at the two gateways.

> **Check yourself before Rung 6:** In step 4, a backbone router tries to log the destination port of your Prometheus scrape for traffic analytics. What port does it record, and why is it *not* 9090? What *would* it record, and what does that tell you about what a VPN hides versus what it doesn't (packet size, timing, the two public endpoints)?

---

## ⚖️ Rung 6 — The Contrast

**The alternative(s):**

- **No VPN — expose the service publicly** (public IP + TLS + auth). vs
- **A dedicated private circuit** (AWS **Direct Connect**, MPLS, leased line) — real private wire, no public internet. vs
- **Perimeter-trust VPN (hub-and-spoke)** vs **zero-trust mesh**.

**What a VPN can do that public exposure cannot:**
- Carry *arbitrary* protocols/ports (databases, ICMP, legacy UDP) in one encrypted pipe, below the application.
- Let non-routable private ranges reach each other with private-IP addressing.
- Hide the *existence* of services — nothing is on a public port to be scanned.

**What public exposure (with TLS) can do that a VPN cannot:**
- Serve *anonymous, internet-scale* clients (you can't hand a WireGuard key to every customer). Public HTTPS + a WAF is the right tool for a public API.

**What a mesh can do that hub-and-spoke cannot:**
- Direct peer-to-peer paths (lower latency, no central bandwidth cap, no single point of failure), with automatic NAT traversal and identity-gated access.

**What Direct Connect can do that a VPN cannot:**
- Consistent low latency and high bandwidth on a private circuit (no public-internet jitter), and no per-packet crypto overhead. But it costs more and takes weeks to provision — many run **VPN as backup to Direct Connect**.

| Dimension | Public exposure + TLS | Site-to-site VPN (IPsec) | Mesh VPN (WireGuard) | Direct Connect |
|---|---|---|---|---|
| Encryption | Per-connection (app-layer) | Whole packets (L3) | Whole packets (L3) | None inherent (private wire) |
| Protocols carried | One app per TLS conn | Any (all ports/protocols) | Any | Any |
| Topology | N/A | Usually hub-and-spoke | Direct peer mesh | Point-to-point circuit |
| Chokepoint | The public endpoint | The concentrator | None (control plane only) | The circuit |
| NAT traversal | N/A | NAT-T (fiddly) | Automatic hole punching | N/A |
| Best for | Public/anonymous clients | Hybrid on-prem ↔ VPC | Node access, multi-cloud, dev | High-bandwidth stable hybrid |
| Setup speed | Minutes | Hours | Minutes | Weeks |
| Trust model | Per-request (good) | Often perimeter (risky) | Identity-gated (zero trust) | Physical + your policy |

**When would I NOT use / need a VPN?**
- For a **public-facing** service with anonymous users → use a public **ALB + TLS + WAF**, not a VPN.
- For **service-to-service inside one cluster** → you likely want a **[service mesh (mTLS)](29-service-mesh-and-sidecars.md)** or **CNI encryption**, not a user VPN.
- When **CIDRs overlap** → a VPN can't cleanly route it; fix the addressing (or use NAT-based translation) first.
- For **stable, very high bandwidth hybrid** → prefer **Direct Connect**, keep VPN as failover.

**Why this over that (one sentence):** Use a VPN when you need *whole private networks or private protocols* to reach each other securely over infrastructure you don't trust — and make it a *zero-trust mesh* so that being on the tunnel earns no automatic trust.

> **Check yourself before Rung 7:** Your team wants engineers to reach private EKS nodes and also wants "encrypt all pod-to-pod traffic." Someone proposes "one big OpenVPN concentrator for everything." Name two distinct reasons that's the wrong tool for the *pod-to-pod* half, and say what you'd use instead for each half.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *out loud* before running the command. A wrong prediction is the most valuable thing that can happen here — it means the mechanism wasn't where you thought.

### Example 1 — Normal case: stand up a real WireGuard tunnel between two hosts

**Prediction:** *If I create a `wg0` interface with a private key, a peer's public key, and `AllowedIPs = 10.99.0.2/32`, then `wg-quick up` will create a routed, encrypted interface, and `wg show` will list the peer with a `latest handshake` only AFTER traffic flows — BECAUSE WireGuard is lazy/connectionless and only performs its handshake when there's a packet to send.*

```bash
# On host A (10.99.0.1). Generate keys:
umask 077
wg genkey | tee privatekey | wg pubkey > publickey   # Curve25519 keypair

# /etc/wireguard/wg0.conf
cat >/etc/wireguard/wg0.conf <<'EOF'
[Interface]
Address    = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <A_private_key>

[Peer]
PublicKey  = <B_public_key>
AllowedIPs = 10.99.0.2/32        # which inner IPs this peer owns
Endpoint   = <B_public_ip>:51820 # where to reach peer B on the internet
EOF

wg-quick up wg0          # creates the wg0 device + installs the route to 10.99.0.2
ip addr show wg0         # 10.99.0.1/24 on interface wg0
ip route | grep 10.99    # 10.99.0.0/24 dev wg0
wg show                  # peer listed, but "latest handshake" is empty until traffic
ping -c1 10.99.0.2       # trigger the handshake
wg show                  # now: "latest handshake: N seconds ago", tx/rx bytes climb
```

**Verify:** After the ping, `wg show` should print a recent `latest handshake` and non-zero `transfer:`. If handshake stays empty, the peer's `Endpoint`/UDP 51820 is unreachable (firewall/SG blocking UDP) — which *teaches* that WireGuard is UDP-only and needs that port open, not TCP.

### Example 2 — Edge/failure case: overlapping CIDRs and split vs full tunnel

**Prediction:** *If peer B advertises `AllowedIPs = 0.0.0.0/0` (a full tunnel) while I also need my normal internet, then `wg-quick` will reroute ALL my traffic through the tunnel and I may lose my default route / SSH session — BECAUSE `AllowedIPs` doubles as the routing table, and `0.0.0.0/0` is the most-general route that captures everything.* And: *if on-prem and VPC both use `10.0.0.0/16`, the tunnel route is ambiguous and traffic to `10.0.x.x` will never leave for the peer.*

```bash
# Inspect what AllowedIPs actually installed as routes:
wg show wg0 allowed-ips           # peer <pubkey>  0.0.0.0/0  ::/0   <- full tunnel!
ip route show table all | grep wg0

# Safer: a SPLIT tunnel — only the VPC CIDR goes through wg0:
#   AllowedIPs = 10.0.0.0/16        (not 0.0.0.0/0)
# Prove the routing decision the kernel will make for a given dst:
ip route get 10.0.60.10           # -> dev wg0  (goes through tunnel)  = split tunnel working
ip route get 8.8.8.8              # -> dev eth0 (normal internet)      = NOT hijacked

# Overlap check BEFORE building a site-to-site tunnel:
#   on-prem 10.0.0.0/16 and VPC 10.0.0.0/16  ==> CONFLICT, tunnel is unusable
```

**Verify:** With a split tunnel, `ip route get 10.0.60.10` shows `dev wg0` while `ip route get 8.8.8.8` shows your normal interface. If *both* show `wg0`, you built a full tunnel and captured all egress. If `ip route get` for a VPC IP resolves to a *local* interface, your CIDRs overlap — the fix is re-addressing, not more VPN config. This is the single most common real hybrid-VPN failure.

### Example 3 — Kubernetes-flavored: turn on transparent WireGuard encryption in the CNI

**Prediction:** *If I enable WireGuard in Cilium, then every node will grow a `cilium_wg0` interface and inter-node pod traffic will show as encrypted WireGuard packets on the wire (UDP), NOT as plaintext pod-to-pod packets — BECAUSE the CNI applies the same encapsulate+encrypt tunnel to pod traffic between nodes, transparently, with no pod/app change.*

```bash
# Enable at install (Helm) — Cilium:
# helm upgrade cilium cilium/cilium --namespace kube-system --set encryption.enabled=true \
#   --set encryption.type=wireguard

# Verify the datapath picked it up (run inside a cilium agent pod):
kubectl -n kube-system exec ds/cilium -- cilium status | grep -i encryption
#   Encryption:   Wireguard  [cilium_wg0 (Pubkey: ..., Port: 51871, Peers: N)]

kubectl -n kube-system exec ds/cilium -- ip -d link show cilium_wg0   # the wg device exists
kubectl -n kube-system exec ds/cilium -- wg show cilium_wg0           # peers = the other nodes

# Prove it on the wire: from a pod on node1, curl a pod on node2, and sniff node1's uplink.
# You should see UDP (WireGuard) between NODE IPs, not plaintext to the destination pod IP:
# tcpdump -ni eth0 udp port 51871        # encrypted WireGuard between node IPs
# (Calico equivalent: kubectl patch felixconfiguration default --type merge \
#    -p '{"spec":{"wireguardEnabled":true}}' ; then check "wireguard/…" in calico-node)
```

**Verify:** `cilium status` should report `Encryption: Wireguard` and list peers = your other nodes; `tcpdump` on the node uplink shows **UDP WireGuard** traffic between *node* IPs rather than plaintext TCP to the destination *pod* IP. If you still see plaintext pod-to-pod on the uplink, encryption didn't attach to that path — a signal to check the CNI encryption mode and whether the traffic is same-node (same-node pod traffic isn't tunneled, since it never leaves the box).

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
A VPN wraps whole private packets inside encrypted, authenticated packets addressed gateway-to-gateway so private networks reach each other safely over the public internet — and zero trust adds that being on that network must, by itself, earn no trust.

**Three-sentence beginner explanation:**
The internet is public and unsafe, so a VPN puts your real (private-addressed) packets inside a sealed, encrypted outer packet that only the two endpoints can open — like a diplomatic pouch routed by its outer label while its contents stay secret. This lets a laptop join a company network (remote-access) or glue two whole networks together (site-to-site, e.g. on-prem ↔ an EKS VPC), and lets any protocol ride through. Modern mesh VPNs (WireGuard/Tailscale) drop the central concentrator so devices form direct encrypted peer links with automatic NAT traversal, and zero trust layers on top so every device and request is verified regardless of where it sits.

**Sub-parts mapped to the one core idea (encapsulate + encrypt + authenticate + route, trust nothing):**
- *Remote-access vs site-to-site* → same encapsulation, different endpoints (a client vs two gateways).
- *IPsec / OpenVPN / WireGuard* → interchangeable recipes for the encrypt+authenticate step.
- *Hub-and-spoke vs mesh* → apply the One Idea through one central box (bottleneck) vs pairwise/direct (no chokepoint).
- *NAT traversal* → how the "route" step reaches a peer that has no public address.
- *CNI WireGuard (Cilium/Calico)* → the same tunnel shrunk to node-to-node, encrypting pod traffic.
- *Zero trust* → the pipe being private ≠ the peer being trusted; verify identity every request.

**Which rung to revisit hands-on:**
**Rung 7, Example 2 (routing / AllowedIPs / CIDR overlap).** The mechanics of encapsulation are easy to *read*; what actually bites you in production is that `AllowedIPs` is really a routing table and that overlapping CIDRs quietly break a site-to-site tunnel. Run `ip route get` against tunnel and non-tunnel destinations until predicting the interface is reflexive — that skill is what separates "the tunnel says UP but nothing works" from a fix.

---

## Related concepts

- **[NAT & PAT](14-nat-and-pat.md)** — why mesh VPNs need hole punching, and how gateways SNAT tunneled traffic.
- **[TLS / encryption in transit](11-tls-ssl-encryption-in-transit.md)** — the app-layer sibling of VPN encryption; a VPN wraps *packets*, TLS wraps *connections*.
- **[Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md)** — the tunnel still has to be permitted; SG/NACL rules gate the decrypted traffic.
- **[Network security, zero trust, IDS/IPS](30-network-security-zero-trust-ids-ips.md)** — the zero-trust mindset in full, defense in depth around the tunnel.
- **[AWS VPC](20-aws-vpc.md)** — VGW/TGW, route tables, and bastion hosts: where a site-to-site VPN actually lands.
- **[Service mesh & sidecars](29-service-mesh-and-sidecars.md)** — mTLS is "authenticate every peer, encrypt every hop" applied *inside* the cluster.
- **[iptables & netfilter](../Linux/12-iptables-netfilter.md)** — the kernel machinery that IPsec/WireGuard and NAT-T hook into.
