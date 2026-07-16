# 🌐 Networking Mastery for Cloud & Kubernetes Engineers — The Learning Ladder Edition

You already run Kubernetes on EKS for a living. You can wire up an Ingress, read a `Service`, click through the VPC console, and open a security group when something can't reach something else. But underneath every one of those actions is a packet — a small, dumb envelope being addressed, named, routed, and either allowed or dropped, over and over, from the copper in the wall to the veth pair inside a pod. This guide re-teaches networking **from the physical wire up to the service mesh**, not as a pile of ports and commands to memorize but as a small set of primitives you can *derive behavior from*. It uses the **Learning Ladder**: one concept per file, and each file climbs the same eight rungs — **Pain → One Idea → Machinery → Vocabulary → Trace → Contrast → Prediction Test → Capstone**. You lead with *why the thing exists* and *how it actually works*, and the commands arrive last, as predictions you commit to before you press enter. This guide was synthesized from several deep networking courses and rebuilt into first-principles ladders, and it ties every concept back to what actually happens in a cluster, a VPC, or the cloud — because that connection *is* the whole point. By the end, when a pod can't reach a database at 3 AM, you won't guess — you'll *see* the addresses, names, routes, and rules underneath it and know exactly which one is broken.

---

## How to use this guide

The single most important instruction: **read up the ladder, not down.** Do not skip to the commands. The commands are Rung 7 for a reason — they're only meaningful once you hold the machinery from Rung 3. If you jump straight to `tcpdump` or `iptables -t nat -L`, you'll be back to memorizing, which is the exact trap this guide exists to break.

**Always start three rungs lower than feels necessary.** Your instinct as an experienced engineer will be "I know DNS, skip to the records." Resist it. Start at the Pain. The gaps in a senior person's networking knowledge are almost never at the top of the ladder — they're a fuzzy Rung 3 (the mechanism) hiding under a confident Rung 7 (the command). You can *use* a NAT gateway daily and still not be able to say, in one sentence, which field in the packet it rewrites. Starting low costs you ten minutes and closes those gaps for good.

**The test of mastery is exactly two things, and neither one is "I ran the command":**

1. **Explain the concept in one sentence, out loud, with no notes.** If you can't compress it, you don't own it yet — you're renting it from the docs.
2. **Predict a packet's path before you run the command.** Say where the packet goes, which device rewrites which header, and *why* — then run `traceroute`, `dig`, or `tcpdump` and watch. A wrong prediction isn't failure; it's your mental model repairing itself in real time. That's the most valuable event in the whole process — chase it.

Every file ends each rung with a **"✅ Check yourself"** question. **Answer these out loud**, in your own words, before climbing on. Talking forces the fuzzy parts to reveal themselves in a way that silent nodding never will. If a check-yourself question makes you hesitate, that rung is your next hands-on session — go do it before moving up.

### The eight rungs, briefly

- **🔥 Rung 1 — The Pain.** *Why does this primitive exist at all?* Sit with the problem it was born to solve. Understand the pain and you can predict what the tool must do.
- **💡 Rung 2 — The One Idea.** The single sentence everything else hangs off. Memorize it exactly; derive the rest from it.
- **⚙️ Rung 3 — The Machinery.** How it actually works under the hood, header by header. The most important rung. Go slow, draw the diagram.
- **🏷️ Rung 4 — The Vocabulary Map.** Pin every scary term to the part of the machinery it labels. Jargon stops being scary once it has somewhere to land.
- **🔬 Rung 5 — The Trace.** Follow one concrete packet end-to-end — a DNS query, a TCP handshake, a request into a pod — until the abstraction sears into memory.
- **⚖️ Rung 6 — The Contrast.** The boundary of a concept defines it. See exactly where this primitive stops and the neighboring one begins (TCP vs UDP, SG vs NACL, L4 vs L7).
- **🧪 Rung 7 — The Prediction Test.** The commands finally arrive — each one reframed as a hypothesis you commit to first, then verify.
- **🏔 Rung 8 — The Capstone.** Compress it. One sentence, no notes. If you can't, you've found your gap — which is useful.

---

## The curriculum

Thirty-two concepts, each a self-contained climb, grouped into six phases. Read them roughly in order — later files lean on primitives established earlier (subnetting assumes IP addressing; NAT assumes routing; Kubernetes Services assume DNS, iptables, and load balancing). Every row ends with the cloud/K8s tie-in, because that connection *is* the point of the guide.

### Phase 1 — Foundations (addresses & wires)

The bedrock: how machines are identified and physically reach each other. Everything above is a special case of these.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 01 | [What Is a Network & the Internet](01-what-is-a-network-and-the-internet.md) | LAN/MAN/WAN, topologies, ISPs, physical media, the internet as a network of networks | Your VPC is a LAN; the internet gateway is your on-ramp to the network of networks |
| 02 | [IP Addressing](02-ip-addressing.md) | IPv4/IPv6, octets & binary, public vs private, loopback, special ranges | Pod IPs, node IPs, the RFC1918 space your VPC CIDR carves from |
| 03 | [Subnetting & CIDR](03-subnetting-and-cidr.md) | Subnet math, CIDR notation, network/broadcast, address planning | Sizing a VPC CIDR and subnets so you don't run out of pod IPs mid-scale |
| 04 | [Ports, Sockets & Multiplexing](04-ports-sockets-multiplexing.md) | Ports, well-known/ephemeral, sockets, mux/demux, port mapping | `containerPort`, `targetPort`, NodePort, and how one node IP serves many pods |
| 05 | [MAC Addresses, Switching & ARP](05-mac-addresses-switching-arp.md) | L2 addressing, switches, ARP, frames vs packets | How pods on a node reach each other over a virtual bridge; the veth/ARP dance |

### Phase 2 — The Journey of Data (models & core protocols)

The map of the whole stack, then the protocols that carry every request you'll ever debug.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 06 | [OSI & TCP/IP Models](06-osi-and-tcpip-models.md) | 7-layer OSI, 4-layer TCP/IP, encapsulation, the journey of data | The mental grid you hang every other concept on: "which layer is broken?" |
| 07 | [Transport Layer: TCP & UDP](07-transport-layer-tcp-udp.md) | TCP handshake/reliability, UDP, flow & congestion control | Why a hung pod connection shows in `ss`; why DNS is UDP; readiness vs `SYN` |
| 08 | [Routing & Forwarding](08-routing-and-forwarding.md) | Routers, routing vs forwarding tables, static/dynamic, BGP, TTL | VPC route tables, pod-CIDR routes, and how `traceroute` reveals every hop |
| 09 | [DNS](09-dns.md) | Name resolution chain, record types, caching, resolvers | CoreDNS, `svc.cluster.local`, and the #1 cause of "it works intermittently" |
| 10 | [HTTP & HTTPS](10-http-and-https.md) | Request/response, methods, status codes, cookies, HTTP/2 & /3 | What an ALB and Ingress actually route on; 502 vs 504 vs 503 decoded |
| 11 | [TLS/SSL — Encryption in Transit](11-tls-ssl-encryption-in-transit.md) | TLS handshake, certs, chain of trust, mTLS | ACM certs on the ALB, Ingress TLS termination, mesh mTLS between pods |
| 12 | [Application-Layer Protocols](12-application-layer-protocols.md) | SMTP/POP3/IMAP, SSH, ICMP, NTP, Telnet | Why ICMP matters for path MTU; SSH tunnels vs `kubectl port-forward` |

### Phase 3 — Infrastructure & Middleboxes

The boxes in the middle that move, translate, hide, assign, segment, filter, and balance traffic.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 13 | [Network Devices](13-network-devices.md) | Hub/switch/bridge/router/gateway/repeater and their OSI layers | Every cloud primitive is a virtualized one of these; naming them by layer |
| 14 | [NAT & PAT](14-nat-and-pat.md) | SNAT/DNAT/masquerade, NAT tables, cloud & pod NAT | The NAT gateway that gives private pods egress; kube-proxy DNAT to pod IPs |
| 15 | [DHCP](15-dhcp.md) | DORA, leases, IP autoconfig, IPAM vs DHCP | How nodes get IPs; how the VPC CNI hands pod IPs from an IPAM pool |
| 16 | [VLANs & Segmentation](16-vlans-and-segmentation.md) | 802.1Q VLANs, trunks, VXLAN overlays | VXLAN is how Flannel/Calico overlays carry pod traffic across nodes |
| 17 | [Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md) | Stateful vs stateless, SGs, NACLs, iptables | The two AWS firewalls (SG stateful, NACL stateless) and when each bites |
| 18 | [Load Balancing](18-load-balancing.md) | L4 vs L7, algorithms, health checks, ALB/NLB | ALB (L7) vs NLB (L4); a K8s Service IS a load balancer you can't see |

### Phase 4 — Cloud Networking

Where the physical concepts become software you provision with a click or a manifest.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 19 | [VPN & Zero-Trust Connectivity](19-vpn-and-zero-trust-connectivity.md) | Tunnels, IPsec/WireGuard, site-to-site, mesh VPN | Connecting on-prem to VPC; private cluster access without public endpoints |
| 20 | [AWS VPC](20-aws-vpc.md) | VPC, public/private subnets, IGW, NAT GW, route tables, SG/NACL, bastion | The single most important cloud-networking file: your cluster lives here |
| 21 | [CDN, Edge & WAF](21-cdn-edge-waf.md) | Edge caching, latency, DDoS mitigation, WAF | CloudFront in front of the ALB; WAF rules protecting your Ingress |
| 22 | [SDN — Software-Defined Networking](22-sdn-software-defined-networking.md) | Control/data plane split, programmable networks | Why the whole VPC and every CNI is "networking as an API call" |

### Phase 5 — Container & Kubernetes Networking

The payoff phase, where every earlier primitive reappears wearing a Kubernetes costume.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 23 | [Container & Docker Networking](23-container-docker-networking.md) | Bridge/host/overlay, port mapping, container DNS | The namespace/veth/bridge model a pod is built on top of |
| 24 | [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) | The 4 rules, pod IP, CNI, veth, Calico/Flannel/Cilium, eBPF | What gives every pod a routable IP; why the VPC CNI hands real VPC IPs |
| 25 | [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) | ClusterIP/NodePort/LoadBalancer, kube-proxy iptables/IPVS | The permanent hotline in front of churning pods; DNAT you can read |
| 26 | [Kubernetes DNS & Service Discovery](26-kubernetes-dns-service-discovery.md) | CoreDNS, `svc.cluster.local`, `resolv.conf`, `ndots` | How `curl my-svc` resolves; the `ndots:5` latency trap |
| 27 | [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) | L7 ingress, controllers, Gateway API, TLS termination | The front door: ALB Ingress controller, path routing, cert termination |
| 28 | [Kubernetes Network Policies](28-kubernetes-network-policies.md) | Pod firewalls, default-deny, selectors, CNI enforcement | Segmenting east-west pod traffic; why the CNI must support it |

### Phase 6 — Security, Performance & Observability

Making the network safe, fast, and — most importantly — *visible*.

| # | Concept | What it unlocks | Key cloud/K8s tie-in |
|---|---------|-----------------|----------------------|
| 29 | [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) | Envoy sidecar, mTLS, control/data plane, when NOT to use | The graduation from raw K8s networking; the companion Istio ladder |
| 30 | [Network Security & Zero Trust (IDS/IPS)](30-network-security-zero-trust-ids-ips.md) | Zero trust, IDS/IPS, DDoS, encryption in transit, defense in depth | Layering SG + NACL + NetworkPolicy + mTLS into one coherent posture |
| 31 | [Bandwidth, Latency & AI/HPC Networking](31-bandwidth-latency-ai-hpc-networking.md) | Bandwidth vs latency, RDMA/InfiniBand/RoCE, AI workloads | Why GPU/training clusters need EFA and placement groups, not just more bandwidth |
| 32 | [Network Observability](32-network-observability.md) | Metrics/logs/traces, flow logs, tcpdump, eBPF/Hubble, tracing | VPC Flow Logs + Hubble + `tcpdump`: seeing the four things directly |

---

## Suggested learning path

One focused session per weekday, weekends to consolidate and run the prediction tests. The plan front-loads the foundations (they compound into everything else) and gives the Kubernetes phase room to breathe, because that's where the payoff lands. Adjust to your pace — depth beats speed, and a skipped check-yourself question is a debt you'll pay later.

```
WEEK 1 — FOUNDATIONS + THE MODEL (make the invisible visible)
┌─────┬─────────────────────────────────────────────────────────────┐
│ Day │ File(s)                        Goal for the day               │
├─────┼─────────────────────────────────────────────────────────────┤
│  1  │ 01 What is a network           "Network of networks" clicks   │
│  2  │ 02 IP Addressing               Read an IP in binary from memory│
│  3  │ 03 Subnetting & CIDR           Plan a VPC CIDR + 3 subnets     │
│  4  │ 04 Ports/Sockets  05 MAC/ARP   How one host serves many things │
│  5  │ 06 OSI & TCP/IP models          The grid every debug hangs on   │
│ S/S │ Re-explain 01–06 out loud, one sentence each                  │
└─────┴─────────────────────────────────────────────────────────────┘

WEEK 2 — CORE PROTOCOLS (the packets you actually debug)
┌─────┬─────────────────────────────────────────────────────────────┐
│  8  │ 07 TCP & UDP                   Draw the 3-way handshake cold   │
│  9  │ 08 Routing & Forwarding        traceroute a real path         │
│ 10  │ 09 DNS                         dig every step of resolution   │
│ 11  │ 10 HTTP/HTTPS  11 TLS          Watch a TLS handshake in tcpdump│
│ 12  │ 12 App protocols + review      Re-run Rung 7 of files 07–11    │
│ S/S │ Consolidate: explain files 07–12 out loud                     │
└─────┴─────────────────────────────────────────────────────────────┘

WEEK 3 — MIDDLEBOXES + CLOUD (translate, filter, balance)
┌─────┬─────────────────────────────────────────────────────────────┐
│ 15  │ 13 Devices  14 NAT/PAT         Which header does NAT rewrite?  │
│ 16  │ 15 DHCP  16 VLANs/VXLAN        How addresses get assigned      │
│ 17  │ 17 Firewalls/SG/NACL           Stateful vs stateless, out loud │
│ 18  │ 18 Load Balancing              L4 vs L7 decided by the header  │
│ 19  │ 20 AWS VPC (the big one)       Trace egress from a private pod │
│ S/S │ 19 VPN  21 CDN/WAF  22 SDN     Round out the cloud picture     │
└─────┴─────────────────────────────────────────────────────────────┘

WEEK 4 — KUBERNETES + OBSERVABILITY (the payoff — go slow)
┌─────┬─────────────────────────────────────────────────────────────┐
│ 22  │ 23 Docker net  24 Pod net/CNI  Build the pod-network mental map│
│ 23  │ 25 Services/kube-proxy         Read a real ClusterIP DNAT rule │
│ 24  │ 26 K8s DNS  27 Ingress/Gateway The front door + service disco  │
│ 25  │ 28 NetworkPolicies             Default-deny, then allow        │
│ 26  │ 29 Service mesh  30 Zero trust Layer the whole defense stack   │
│ S/S │ 31 AI/HPC net  32 Observability See the four things directly   │
└─────┴─────────────────────────────────────────────────────────────┘

CAPSTONE — the end-to-end trace below, from memory, cold.
```

> If a week feels rushed, split it — the plan is a ladder, not a treadmill. The only failure mode is climbing to Rung 7 on a fuzzy Rung 3.

---

## The four things that never change

Here is the secret that makes this whole guide shorter than it looks: **every network problem you will ever face reduces to exactly four questions.** Physical server, VPC, or EKS pod — it's always the same four. Learn to ask them in order and you can debug or design anything, because a broken network is always *one of these four* failing.

```
┌──────────────────────────────────────────────────────────────────────┐
│              THE FOUR THINGS THAT NEVER CHANGE                        │
│                                                                       │
│  1. ADDRESSES  ─▶ Everything needs an identity.                       │
│                   MAC (L2) · IP (L3) · port (L4).                     │
│                   "Does the thing even HAVE an address, and is it     │
│                    the address I think it is?"                        │
│                   → files 02, 03, 04, 05, 14                          │
│                                                                       │
│  2. NAMES      ─▶ Names must resolve to addresses.                    │
│                   DNS · service discovery · /etc/hosts.               │
│                   "Does the name resolve, and to the RIGHT address?"  │
│                   → files 09, 26                                      │
│                                                                       │
│  3. ROUTES     ─▶ Traffic needs a path to the address.                │
│                   Routing & forwarding tables · gateways · BGP.       │
│                   "Is there a route there — AND a route BACK?"        │
│                   → files 08, 13, 20, 24                              │
│                                                                       │
│  4. RULES      ─▶ Something controls what is allowed.                 │
│                   Firewall · Security Group · NACL · NetworkPolicy.   │
│                   "Is something ALLOWING (or silently dropping) it?"  │
│                   → files 17, 28, 30                                  │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

Master these four and the API of every networking tool collapses into a combination of things you already understand. When a pod "can't connect," you don't panic — you walk the four in order:

1. **Addresses** — Does the pod have an IP? Does the target? `kubectl get pod -o wide`, `ss -tlnp`. (Bad address = the 90% case with typo'd `targetPort`.)
2. **Names** — Does the Service name resolve? `nslookup my-svc`. (CoreDNS down, or `ndots` sending you to the wrong FQDN.)
3. **Routes** — Is there a path there *and back*? Check the VPC route table, the pod CIDR route, `traceroute`. (Asymmetric routing and a missing return route are classic.)
4. **Rules** — Is something dropping it? Security group, NACL, NetworkPolicy, iptables. (A stateless NACL blocking the ephemeral return port is the sneakiest.)

That order is not arbitrary — it climbs the layers from the bottom, so the first "no" you hit is almost always the real cause. Every file in this guide is, underneath its topic, teaching you one of these four.

---

## End-to-end: a request from a browser to a pod on EKS

Here is the whole guide in one picture. A user types a URL and hits Enter; a response comes back. Between those two events, **all four of the never-change things happen at least once**, at nearly every layer of the stack. Trace this cold and you have mastered the material. Each hop names the file that explains it.

```
                  A REQUEST: browser ──────────▶ pod on EKS ──────────▶ back
                                (and the four things at every hop)

┌─ 0. BROWSER ───────────────────────────────────────────────────────────────┐
│  User enters https://shop.example.com/cart                                  │
│  Browser needs an ADDRESS for the NAME "shop.example.com".                   │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  NAME → ADDRESS
                ▼
┌─ 1. DNS RESOLUTION ────────────────────────────────  file 09 (DNS) ─────────┐
│  stub resolver → recursive resolver → root → .com TLD → authoritative.       │
│  Returns an A/AAAA record: shop.example.com = 52.x.x.x  (the ALB's IP).      │
│  (In cloud this is often a Route 53 ALIAS pointing at the ALB.)              │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  now we have an ADDRESS + a ROUTE toward it (files 02,03,08)
                ▼
┌─ 2. TCP + TLS HANDSHAKE ──────────────  files 07 (TCP), 11 (TLS) ───────────┐
│  TCP 3-way handshake to 52.x.x.x:443  (SYN, SYN-ACK, ACK).                   │
│  Then TLS: ClientHello → cert (from ACM) → key exchange → encrypted tunnel.  │
│  The ALB terminates TLS here — it holds the cert, the browser trusts the CA. │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  encrypted HTTP request (file 10) now flows
                ▼
┌─ 3. AWS ALB — Layer 7 ────────────────  files 18 (LB), 21 (edge/WAF) ───────┐
│  WAF rules inspect the request first (file 21). Then the ALB reads the       │
│  HTTP HOST header + path "/cart" (that's why it's L7) and matches a          │
│  listener RULE → a target group (your Ingress controller / node ports).      │
│  RULE check + ADDRESS selection (which target) happen here.                  │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  packet enters the VPC toward a node
                ▼
┌─ 4. VPC: ROUTE TABLE + SECURITY GROUP + NACL ─  files 20 (VPC), 17 (rules) ─┐
│  Public subnet → private subnet. The subnet ROUTE TABLE forwards toward the  │
│  node's ENI. Two RULE gates in series:                                       │
│    • NACL (stateless, subnet edge) — must allow IN and the ephemeral OUT.    │
│    • Security Group (stateful, on the ENI) — allow the target port.          │
│  Either one silently dropping = the classic "times out for no reason."       │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  arrives at the worker node's ENI (an ADDRESS in the VPC)
                ▼
┌─ 5. INGRESS CONTROLLER (L7, in-cluster) ──  file 27 (Ingress/Gateway) ──────┐
│  The ingress-controller pod (e.g. AWS LB Controller in IP mode, or NGINX)    │
│  applies Ingress/HTTPRoute RULES: host + path → a backend Kubernetes         │
│  Service. Re-encrypt or pass through per TLS config (file 11).               │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  destined for a Service NAME → ClusterIP (a virtual ADDRESS)
                ▼
┌─ 6. SERVICE DNS + kube-proxy DNAT ──  files 26 (K8s DNS), 25 (Services),    │
│                                              14 (NAT) ──────────────────────┐│
│  cart-svc.default.svc.cluster.local → ClusterIP 10.100.x.x (CoreDNS).       ││
│  ClusterIP is virtual — no NIC owns it. kube-proxy's iptables/IPVS rules    ││
│  DNAT the packet: dst 10.100.x.x:80  →  a real pod IP:8080, chosen from     ││
│  the Endpoints list. This is the "permanent hotline → whichever desk" trick.││
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  now addressed to a real POD IP (a routable VPC IP via CNI)
                ▼
┌─ 7. CNI: NODE ROUTE → veth → POD NETNS ──  files 24 (CNI), 05 (ARP),        │
│                                                  28 (NetworkPolicy) ────────┐│
│  The node routes the pod IP to the pod's veth pair (one end on the node,    ││
│  one inside the pod's network namespace). ARP resolves the veth's L2 addr.  ││
│  NetworkPolicy RULES (enforced by the CNI — Calico/Cilium) allow or drop    ││
│  this east-west flow. Packet crosses the veth into the pod.                 ││
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  finally: PORT demux to the container (file 04)
                ▼
┌─ 8. CONTAINER ─────────────────────────────────────────────────────────────┐
│  The listening process accepts on :8080, handles GET /cart, writes a 200.   │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │
                ▼   ── THE RESPONSE WALKS ALL THE WAY BACK UP ──
   pod → veth → node → (un-DNAT: src rewritten back to the ClusterIP/ALB) →
   VPC route + SG (stateful: return is auto-allowed; NACL is NOT — file 17) →
   ALB re-encrypts → TLS tunnel → TCP → browser renders the cart.

  At EVERY hop, ask the four:  ADDRESS? · NAME? · ROUTE (there AND back)? · RULE?
```

Notice what that diagram really shows: **there is no magic anywhere in it.** Every box is one of the four never-change things, implemented by a device or a piece of software you can name, inspect, and — with the right Rung 7 command — watch directly. The `502` you saw last week was Rung 3's ALB failing to reach a healthy target (a *rule* or *address* problem at box 3–6). The intermittent timeout was box 4 or box 7 — a *rule* silently dropping the return path. You now know which box, and which file, to open.

---

*Master these thirty-two concepts and cloud/Kubernetes networking stops being magic — it becomes addresses, names, routes, and rules you can see. Start at Rung 1 of file 01. Climb.*
