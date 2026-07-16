# The OSI & TCP/IP Models
*The journey of data, one layer at a time — and the debugging superpower that falls out of it.*

---

## 🎬 Rung 0 — The Setup

**What am I learning?** Two "maps" of how data travels across a network: the **OSI model** (7 layers) and the **TCP/IP model** (4 layers). Both describe the same journey — an app on one machine producing bytes, and those bytes arriving intact inside an app on another machine — but they slice that journey into layers so you can reason about one slice at a time.

A *layer* is one job in the pipeline: "figure out the route," "put it on the wire," "make sure it arrived." A *model* is just an agreed-upon list of those jobs, in order, with clean handoffs between them.

**Why did it land on my desk?** You're a platform engineer on EKS. This morning three tickets hit the queue:

- "The app can't reach `payments.internal` — DNS is broken."
- "Users get `curl: (35) SSL handshake failed` against the ALB."
- "Pod-to-pod traffic just silently disappears after we applied a NetworkPolicy."

Three different symptoms. Three *completely different* places to look. The thing that lets a senior engineer glance at each ticket and instantly say "that's a Layer 7 problem," "that's Layer 6/4," "that's Layer 3/4" — and skip straight to the right tool — is not memorized trivia. It's the layered model living in their head. That mental model is what turns a two-hour flailing session into a five-minute fix. Today you install it.

**What do I already know?** You've already met the pieces the layers are *made of*: [IP addresses](02-ip-addressing.md) (who), [ports and sockets](04-ports-sockets-multiplexing.md) (which app), and [MAC addresses, switches, and ARP](05-mac-addresses-switching-arp.md) (the local delivery). You know `kubectl`, the AWS console, Security Groups, ALBs, and NLBs by feel. What you *don't* yet have is the skeleton that arranges all of it into a single ordered story. The models are that skeleton.

---

## 🔥 Rung 1 — The Pain

**The problem that forced this to exist:** In the 1970s every vendor built its own networking stack. IBM had SNA. DEC had DECnet. Xerox had XNS. Each was a monolith — one giant blob of code that did *everything* from the electrical signal on the cable up to the application format. If you wanted an IBM mainframe to talk to a DEC machine, you were mostly out of luck. Worse: inside one vendor's blob, you couldn't swap out one piece. Want to run the same application over a different physical medium (copper vs. fiber vs. radio)? You often had to rewrite the whole stack, because "which cable" and "which app format" were tangled together in the same code with no clean seam between them.

**Why that hurt:**

- **No interoperability.** Vendor A's network and Vendor B's network were islands.
- **No independent evolution.** You couldn't upgrade Wi-Fi without touching your web browser, because there was no boundary saying "the browser doesn't know or care what the physical medium is."
- **No shared language for debugging.** When something broke, two engineers from two companies had no common vocabulary to even *describe* where it broke.

**What people did before, and why it still hurt:** The industry's answer was *layering* — the idea that you split the stack into independent slices, each with a defined job and a defined interface to its neighbors. The ISO published the **OSI model** (Open Systems Interconnection) in 1984 as the grand, formal, 7-layer reference. In parallel, the actual internet was already running on the pragmatic, shipped-and-working **TCP/IP** stack (formalized in the early 1980s, RFC 1122 later). OSI became the *teaching language* everyone shares; TCP/IP became the thing your packets actually run on. We keep both because they're good at different things: OSI gives you precise words to point at a problem, TCP/IP describes reality.

**What breaks without this mental model:** Nothing breaks on the *wire* — packets flow fine. What breaks is *you*. Without the layers, every network problem is one undifferentiated fog. You `curl` a thing, it fails, and you have no principled way to decide: is it DNS? routing? the firewall? TLS? the app returning a 500? You end up randomly restarting pods and re-applying manifests. The pain is **wasted hours and shotgun debugging.**

**Who feels it most?** The on-call platform engineer at 2 a.m., and anyone operating a system with many moving network parts — which is *exactly* Kubernetes: an [Ingress](27-kubernetes-ingress-gateway-api.md) at L7, a [Service + kube-proxy](25-kubernetes-services-kube-proxy.md) at L4, a [CNI](24-kubernetes-pod-networking-cni.md) at L3, [CoreDNS](26-kubernetes-dns-service-discovery.md) at L7, a [NetworkPolicy](28-kubernetes-network-policies.md) at L3/L4, and a [service mesh](29-service-mesh-and-sidecars.md) at L7 — all stacked on top of each other in one cluster. Without a layer model, EKS networking is impossible to reason about.

> **Check yourself before Rung 2:** Two vendors' networks in 1978 can't talk. Explain *why splitting the stack into independent layers* — rather than just writing one careful translator between them — is the more powerful fix. (Hint: think about the *N×N* problem of translators.)

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it:

> **Data travels down a stack of layers, each one wrapping the layer above in its own header (encapsulation); at the other end it travels up the same stack, each layer unwrapping its own header (decapsulation) — so every layer only ever talks to its counterpart on the other machine.**

That's it. Everything else is derived from it.

- **Why 7 (or 4) layers?** Because you can split "the journey of data" into that many independent jobs with clean handoffs. The *number* is a design choice; the *layering* is the idea.
- **Why headers?** Because each layer needs to leave a note for its counterpart on the far side — "here's the port," "here's the destination IP," "here's the MAC." Wrapping = attaching that note. Unwrapping = reading and removing it.
- **Why "each layer only talks to its counterpart"?** This is the magic. Your browser (L7) behaves *as if* it's speaking directly to the web server's software (L7), even though its bytes physically dropped all the way down to electrical signals, crossed fifteen routers, and climbed back up. Each layer maintains the *illusion* of a direct peer conversation. That illusion is what lets you reason about one layer in isolation.
- **Why is this a debugging superpower?** Because "which layer is broken?" partitions the entire problem space. Packet not arriving at all → Layer 3. TLS handshake dies → Layer 6/4 boundary. DNS name won't resolve → Layer 7. You stop guessing and start *bisecting*.

Keep this next to the sentence — the layers, and a mnemonic to hold their order:

```
Layer 7  Application    "Please Do Not Throw Sausage Pizza Away"
Layer 6  Presentation      P    D    N    T    S    P    A
Layer 5  Session           |    |    |    |    |    |    |
Layer 4  Transport       (top-down: Application → Physical)
Layer 3  Network
Layer 2  Data Link       Bottom-up ("All People Seem To Need
Layer 1  Physical         Data Processing" = 1→7)
```

Everything below is just *this one idea*, slowed down.

> **Check yourself before Rung 3:** If every layer only talks to its counterpart on the far machine, how can data ever get from a browser to a server, given that a browser can't put electrical signals on a wire? Derive the answer from the One Idea *before* reading on.

---

## ⚙️ Rung 3 — The Machinery

This is the important rung. Go slow.

### The core move: encapsulation going down, decapsulation going up

When your browser sends a request, the data does **not** teleport to the server's browser. It descends the sender's stack, crosses the physical medium, and *ascends* the receiver's stack. On the way down, each layer prepends (wraps) its own **header** — a small block of metadata addressed to that same layer on the other side. On the way up, each layer reads and strips its own header, then hands the remaining payload upward.

Think of it as **nested envelopes**. Your letter (the HTTP request) goes into an envelope marked with a port (Transport). That envelope goes into a bigger envelope marked with IP addresses (Network). That goes into an envelope marked with MAC addresses (Data Link). The receiving mailroom opens them in reverse order — outermost first — and each clerk only reads the marking meant for them.

```
   SENDER (your laptop / a pod)                RECEIVER (the web server / a pod)
   ============================                ================================

 7 Application   [ HTTP: GET /pay ]                 [ HTTP: GET /pay ]   Application 7
                        |  encapsulate                     ^  decapsulate
 6 Presentation  [ TLS-encrypt, encode ]           [ TLS-decrypt ]      Presentation 6
                        |                                  |
 5 Session       [ keep the dialog/state ]         [ restore session ]  Session 5
                        |                                  |
 4 Transport     [ TCP hdr | ......... ]  SEGMENT  [ TCP hdr | .... ]   Transport 4
                 |src/dst PORT, SYN/ACK|                   ^
                        |                                  |
 3 Network       [ IP hdr | TCP | ... ]   PACKET   [ IP hdr | .... ]    Network 3
                 | src/dst IP, TTL     |                   ^
                        |                                  |
 2 Data Link     [ Eth | IP | TCP |..]    FRAME    [ Eth | IP | ... ]   Data Link 2
                 | src/dst MAC, CRC    |                   ^
                        |                                  |
 1 Physical      101000110101110...      BITS      101000110101110...   Physical 1
                        |                                  ^
                        +======= the wire / fiber / Wi-Fi ==+
                            (routers & switches in between)
```

Read the arrows: **down** on the left (each layer adds its header), across the medium, **up** on the right (each layer removes its header). The HTTP request that arrives at the top-right is *byte-for-byte identical* to the one that started at the top-left. Every layer in between did its job and got out of the way. That is the whole machine.

### What each layer actually does — with the "browser → server" example

Let's walk your browser asking `https://payments.internal/pay` and pin each layer to a concrete job.

- **Layer 7 — Application** *(the job: speak the app's language).* Produces the actual request in a protocol the two apps agree on: HTTP. Also where **DNS** and **TLS negotiation logic** live from the app's point of view. *Example:* your browser builds `GET /pay HTTP/1.1\r\nHost: payments.internal`. In a cluster this is where an **[Ingress](27-kubernetes-ingress-gateway-api.md)/ALB** routes by hostname/path, and where a **[service mesh](29-service-mesh-and-sidecars.md)** (Envoy) makes routing decisions.
- **Layer 6 — Presentation** *(the job: format/encrypt so both sides understand the bytes).* Character encoding (UTF-8), compression, and crucially **TLS encryption/decryption**. *Example:* the plaintext HTTP is encrypted into TLS records here. A failed **TLS handshake** shows up conceptually at this L6/transport boundary.
- **Layer 5 — Session** *(the job: open, manage, and close the conversation).* Establishes and maintains the dialog between the two endpoints, tracks state, handles reconnection. *Example:* keeping your authenticated session coherent across multiple requests.
- **Layer 4 — Transport** *(the job: deliver to the right app, reliably or not).* Adds a **[TCP or UDP](07-transport-layer-tcp-udp.md) header** with **source and destination ports**. TCP guarantees ordered, reliable delivery via the 3-way handshake (SYN → SYN-ACK → ACK) and retransmission; UDP is fire-and-forget. *Example:* dst port **443** for HTTPS. **This is the layer of K8s [Services](25-kubernetes-services-kube-proxy.md), kube-proxy DNAT, and NLBs.**
- **Layer 3 — Network** *(the job: get across networks, end to end).* Adds the **IP header** with **source and destination IP addresses** and a **TTL** (hop limit). Routers use this to forward the packet hop by hop, each **decrementing TTL by 1**. *Example:* src `10.42.1.7` (a pod IP) → dst `10.100.0.55`. **This is where [routing](08-routing-and-forwarding.md), the [CNI](24-kubernetes-pod-networking-cni.md), and L3/L4 [NetworkPolicy](28-kubernetes-network-policies.md) live.**
- **Layer 2 — Data Link** *(the job: hop to the next physical device on this link).* Adds the **Ethernet frame** header with **source and destination MAC addresses** and a trailing **CRC** checksum. Scope is one link only; **[ARP](05-mac-addresses-switching-arp.md)** maps the next-hop IP to a MAC. *Example:* frame addressed to your default gateway's MAC. Switches operate here.
- **Layer 1 — Physical** *(the job: be the actual signal).* Turns the frame's bits into electrical voltage, light pulses, or radio waves on the medium. *Example:* the cat6 cable, the fiber, the Wi-Fi radio, the ENI attached to your EC2 node.

### The critical detail most people miss: layers are *stateless about each other's meaning*

Layer 3 does not know or care that the payload it's carrying is TLS-encrypted HTTP. It sees an opaque blob, slaps an IP header on it, and forwards. That indifference is *the feature*. It's why you can run HTTP, SSH, or a database over the exact same IP layer, and why you can swap Wi-Fi for fiber without the browser noticing. Each layer is a black box to its neighbors — coupled only through a thin, defined interface. That is what "clean handoff between layers" buys you.

### TCP/IP: the same journey, fewer boxes

The internet doesn't actually implement 7 discrete layers — it runs the leaner **TCP/IP 4-layer model**. It maps onto OSI like this:

```
        OSI (7)                         TCP/IP (4)                Example
   ┌───────────────────┐
 7 │ Application       │ ┐
 6 │ Presentation      │ ├──────►  ┌─────────────────┐   HTTP, DNS, TLS,
 5 │ Session           │ ┘         │  Application     │   gRPC, SSH
   ├───────────────────┤           ├─────────────────┤
 4 │ Transport         │ ────────► │  Transport       │   TCP, UDP  (ports)
   ├───────────────────┤           ├─────────────────┤
 3 │ Network           │ ────────► │  Internet        │   IP, ICMP  (routing)
   ├───────────────────┤           ├─────────────────┤
 2 │ Data Link         │ ┐         │  Network Access  │   Ethernet, ARP,
 1 │ Physical          │ ┴───────► │  (a.k.a. Link)   │   Wi-Fi, the wire
   └───────────────────┘           └─────────────────┘
```

The key merges to burn in: **OSI L7 + L6 + L5 all collapse into TCP/IP's single "Application" layer**, and **OSI L2 + L1 collapse into "Network Access" (Link)**. Transport and Network/Internet map one-to-one. When someone says "it's an application-layer problem" in the TCP/IP sense, they mean *anything* in the top three OSI layers — the app, its encoding, its encryption, its session. This is why "Layer 7" in cloud land (L7 load balancer, L7 policy) loosely means "the application-content layer," even though strict OSI would split encryption into L6.

### PDUs — the name the data wears at each layer

A **PDU** (Protocol Data Unit) is just "what we call the bundle of data at a given layer." As it gets wrapped going down, its name changes:

```
 Layer 5-7 Application ......  DATA        (the raw message)
 Layer 4   Transport .......  SEGMENT     (TCP)  /  DATAGRAM  (UDP)
 Layer 3   Network .........  PACKET
 Layer 2   Data Link .......  FRAME
 Layer 1   Physical ........  BITS
```

Memorize the chain: **Data → Segment → Packet → Frame → Bits.** When you hear "packet loss," someone is talking L3. "Frame" → L2. "Segment" → L4/TCP. Using the right word tells other engineers exactly which layer you mean. (Mnemonic: **D**o **S**ome **P**eople **F**ear **B**irthdays.)

> **Check yourself before Rung 4:** A packet leaves your pod with TTL 64 and reaches a server 5 router-hops away. What TTL does it arrive with, and *which layer's header* did the decrementing? Then: name the PDU at the moment that same data is sitting in the TCP layer.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **OSI model** | A 7-layer *reference* model (ISO, 1984) | The shared teaching vocabulary; the layer stack |
| **TCP/IP model** | The 4-layer model your packets *actually* run on | The real implementation (App / Transport / Internet / Link) |
| **Layer** | One job in the pipeline with a defined interface | A single horizontal slice of the stack |
| **Encapsulation** | Wrapping a payload by prepending a header | The downward journey on the sender |
| **Decapsulation** | Reading + stripping a header | The upward journey on the receiver |
| **Header** | A per-layer metadata note for the far-side counterpart | Ports (L4), IPs+TTL (L3), MACs+CRC (L2) |
| **PDU** | The name data wears at a layer | Data / Segment / Packet / Frame / Bits |
| **Segment** | L4 PDU (TCP); UDP's is a **datagram** | Transport layer, carries ports + seq/ack |
| **Packet** | L3 PDU | Network layer, carries src/dst IP + TTL |
| **Frame** | L2 PDU | Data Link layer, carries src/dst MAC + CRC |
| **Bits** | L1 PDU | Physical signal on the medium |
| **Application layer** | L7 (OSI) / top of TCP/IP | HTTP, DNS, TLS logic, gRPC, SSH — Ingress, mesh |
| **Presentation** | L6 — encoding & encryption | TLS encrypt/decrypt, UTF-8, compression |
| **Session** | L5 — dialog lifecycle | Open/maintain/close the conversation |
| **Transport** | L4 — app-to-app delivery | TCP/UDP, ports, handshake — Services, NLB, kube-proxy |
| **Network / Internet** | L3 — cross-network delivery | IP, routing, TTL, ICMP — CNI, NetworkPolicy L3 |
| **Data Link** | L2 — next-hop on the local link | Ethernet, MAC, ARP, switches |
| **Physical** | L1 — the actual signal/medium | Copper, fiber, Wi-Fi, the ENI/NIC |
| **TTL / hop limit** | Counter in the IP header, −1 per router | L3; prevents infinite routing loops |
| **Peer conversation** | The illusion each layer talks to its twin | Why you can debug one layer in isolation |

### Terms that are "the same kind of thing wearing different names"

- **PDU aliases:** *data, segment, packet, frame, bits* are the **same bytes** at five different altitudes of the stack — not five different things.
- **"Application layer" collision:** OSI's L7/L6/L5 vs. TCP/IP's single "Application." Same top-of-stack territory, different granularity. When cloud docs say "L7 load balancer," they mean this whole merged top region.
- **"Link layer" aliases:** *Network Access, Link, Data Link + Physical* all point at the same bottom region.
- **Segment vs. datagram:** both are the **L4 PDU** — "segment" for TCP, "datagram" for UDP. Same slot, different transport.
- **Internet layer vs. Network layer:** TCP/IP says "Internet," OSI says "Network" — identical job (L3, IP, routing).
- **Encapsulation vs. decapsulation:** the *same* wrapping operation, run forward on the way down and in reverse on the way up.

> **Check yourself before Rung 5:** Someone says "we're dropping packets" and someone else says "we're dropping frames." Are they necessarily describing the same failure? Which layer is each pointing at, and why does the word choice matter?

---

## 🔬 Rung 5 — The Trace

Let's follow **one HTTPS request** end to end: a pod (`web`, IP `10.42.1.7`) in your EKS cluster calling `https://payments.internal/pay`, which resolves to a ClusterIP `10.100.0.55` backed by a `payments` pod. We'll name the component at every hop.

1. **L7 (App) — DNS first.** The `web` container needs an IP. Its `/etc/resolv.conf` points at **CoreDNS** (ClusterIP, port **53/UDP**). CoreDNS answers `payments.internal` → `10.100.0.55`. *(A failure here is a Layer 7 / application problem — the name resolution — even though the transport was fine.)*
2. **L7 (App) — build the request.** The browser/app constructs `GET /pay HTTP/1.1\r\nHost: payments.internal`.
3. **L6 (Presentation) — TLS.** A TLS handshake runs, then the plaintext HTTP is **encrypted** into TLS records. *(A cert/handshake failure surfaces here — Layer 6/4 boundary.)*
4. **L4 (Transport) — segment.** TCP wraps the TLS bytes with a header: **src port** `49158` (ephemeral), **dst port** `443`. If this is connection setup, the **3-way handshake** fires: `SYN → SYN-ACK → ACK`. PDU is now a **segment**.
5. **L3 (Network) — packet.** IP wraps the segment: **src** `10.42.1.7`, **dst** `10.100.0.55`, **TTL 64**. PDU is now a **packet**. Here **kube-proxy** (iptables/IPVS rules) performs **DNAT**, rewriting the ClusterIP `10.100.0.55` → a real pod IP, say `10.42.3.9`.
6. **L2 (Data Link) — frame.** The kernel needs the next-hop MAC. **ARP** resolves it; Ethernet wraps the packet with **src/dst MAC** + a **CRC** trailer. PDU is now a **frame**. The **[CNI](24-kubernetes-pod-networking-cni.md)** (Calico/Cilium/VPC-CNI) provides the veth pair and bridge/routes this frame traverses.
7. **L1 (Physical) — bits.** The frame becomes electrical/optical signals on the node's **ENI** and the VPC underlay.
8. **Across the fabric.** Routers/switches (and the VPC network) forward it. Each router **decrements TTL by 1** (64 → 63 → …). Along the way, **Security Groups** (stateful, L3/L4) and any **[NetworkPolicy](28-kubernetes-network-policies.md)** (L3/L4) decide *allow or drop* by inspecting IPs and ports — never the HTTP body.
9. **Up the receiver's stack.** At the `payments` pod: L1 reads bits → L2 checks CRC, strips MAC → L3 confirms dst IP, strips IP header → L4 confirms port 443, reassembles the stream → L6 **decrypts** TLS → L7 hands the app a byte-identical `GET /pay HTTP/1.1`.

```
 web pod (10.42.1.7)                                         payments pod (10.42.3.9)
 ─────────────────────                                       ────────────────────────
 L7 GET /pay ────────┐                                          ┌──────► GET /pay  L7
 L6 TLS encrypt      │                                          │  TLS decrypt      L6
 L4 +TCP :49158→:443 │  segment                        segment  │  +TCP             L4
 L3 +IP  .7 → .55    │  packet   ── kube-proxy DNAT ──► .55→.9   │  +IP              L3
 L2 +Eth (ARP→MAC)   │  frame                          frame    │  +Eth CRC ok      L2
 L1 bits ────────────┘  ~~~ ENI / VPC underlay, routers TTL−− ~~~└─ bits            L1

     SG + NetworkPolicy inspect L3/L4 here ▲ (IP + port), allow/deny — never see the HTTP body
```

The punchline: the `GET /pay` that L7 receives on the right is **identical** to the one L7 sent on the left. Everything between was faithful wrapping and unwrapping.

> **Check yourself before Rung 6:** In step 8, a **NetworkPolicy** blocked the traffic. Given that policies see only L3/L4, could that same policy have blocked the request *based on the URL path `/pay`*? If not, which component in the cluster *could*, and at which layer does it operate?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: no shared model — the pre-OSI monolithic stack (SNA, DECnet, XNS).** One vendor blob, physical-to-application fused together, no clean seams.

**What layering can do that the monolith cannot:**

- **Mix and match.** Run HTTP *or* SSH *or* Postgres over the same IP layer; run any of them over copper *or* fiber *or* Wi-Fi. The monolith couldn't decouple these.
- **Evolve independently.** IPv4 → IPv6 at L3 without rewriting your browser. TLS 1.2 → 1.3 at L6 without touching routers.
- **Interoperate across vendors.** A Cisco switch, a Linux host, and an AWS ENI cooperate because they agree on the layer interfaces.
- **Debug by bisection.** "Which layer?" partitions the whole problem.

**What the monolith arguably did "better":** raw performance and simplicity in a single closed system — no per-layer header overhead, no handoff cost, everything hand-tuned end to end. (This is the same reason RDMA/InfiniBand in [AI/HPC networking](31-bandwidth-latency-ai-hpc-networking.md) *bypasses* parts of the classic stack: strict layering has a cost, and at extreme performance you sometimes pay to skip it.)

**OSI vs. TCP/IP head to head:**

| Dimension | OSI (7 layers) | TCP/IP (4 layers) |
|---|---|---|
| Layers | 7: App, Present, Session, Transport, Network, Data Link, Physical | 4: Application, Transport, Internet, Network Access |
| Origin | ISO reference standard (1984) | The real, shipped internet stack (early 1980s) |
| Top-of-stack | L7/L6/L5 split into three | Merged into one "Application" |
| Bottom | L2 + L1 split | Merged into "Network Access" |
| Primary use today | **Teaching & talking** ("that's a Layer 4 issue") | **Reality** — what actually runs |
| Strength | Precise vocabulary, clean separation | Pragmatic, matches implementation |

**When would I NOT reach for this?** You never *stop* using the models — but you don't invoke all 7 layers for every conversation. In day-to-day cloud work you mostly live in a coarse **L3/L4 vs. L7** split: is this an IP/port problem ([Services](25-kubernetes-services-kube-proxy.md), [NLB](18-load-balancing.md), [NetworkPolicy](28-kubernetes-network-policies.md), SGs) or a content/hostname/path problem ([Ingress/ALB](27-kubernetes-ingress-gateway-api.md), [service mesh](29-service-mesh-and-sidecars.md))? The full 7 come out when you're pinpointing a subtle failure.

**Why this over that, in one sentence:** *Use TCP/IP to describe what your packets actually do, and OSI to describe precisely where they broke.*

> **Check yourself before Rung 7:** Your teammate says "it's a Layer 7 problem" about an EKS request. Translate that into the TCP/IP model — which single TCP/IP layer are they pointing at, and name two cluster components that live there.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **out loud before** running the command. Being *wrong* teaches you more than being right — a wrong result means your model of the layers is off, and that's exactly what to fix.

### Prediction 1 — Watch encapsulation with your own eyes (normal case)

**Prediction:** *If I capture a single packet on my interface, I will see the layers nested inside each other — an Ethernet frame (L2, MACs) wrapping an IP packet (L3, IPs + TTL) wrapping a TCP segment (L4, ports + flags) — BECAUSE encapsulation physically prepends each layer's header, so the capture is those envelopes, outermost first.*

```bash
# Capture one HTTPS packet leaving your box, decoded layer by layer.
# (Linux; run with sudo. Ctrl-C after a packet or two.)
sudo tcpdump -i any -n -v 'tcp port 443' -c 1
# Representative decode:
#  L3 ► IP (tos 0x0, ttl 64, ...) 10.0.1.23.49158 > 93.184.216.34.443:   <- src/dst IP + TTL
#  L4 ► Flags [S], seq 12345, win 64240, ...                             <- TCP SYN flag + ports
# Add link-layer detail (-e prints the L2 Ethernet header with MACs):
sudo tcpdump -i any -e -n 'tcp port 443' -c 1
#  L2 ► aa:bb:cc:11:22:33 > dd:ee:ff:44:55:66, ethertype IPv4 (0x0800)   <- src/dst MAC
```

**Verify:** You should see **MACs (L2), then IPs + `ttl 64` (L3), then ports + a `[S]` SYN flag (L4)** in one packet — the nesting made visible. If TTL isn't 64/128/64-ish or you see no port, you grabbed the wrong packet. Seeing `[S]` alone (not `[S.]`) confirms it's the first step of the **3-way handshake** (SYN); the reply will be `[S.]` = SYN-ACK, then `[.]` = ACK.

### Prediction 2 — Prove TTL is decremented at L3, hop by hop (mechanism/edge case)

**Prediction:** *If I traceroute a distant host, each successive router will report back one hop farther, BECAUSE traceroute sends packets with TTL 1, 2, 3, … and every router decrements TTL at L3 and, when it hits 0, replies with an ICMP "Time Exceeded" — so the TTL counter literally maps to hop distance.*

```bash
# Linux/macOS:
traceroute -n 8.8.8.8
# Windows: tracert 8.8.8.8
# Representative:
#  1  10.0.1.1     1.2 ms     <- your gateway (TTL reached 0 here first)
#  2  100.64.0.1   3.4 ms     <- next router decremented to 0
#  3  * * *                   <- a hop that doesn't send ICMP (silent, normal)
#  ...
#  8  8.8.8.8      12 ms      <- destination reached
```

**Verify:** The hop count climbs by one per line — that *is* the TTL field being decremented at Layer 3, one router at a time. A row of `* * *` is an **edge case**, not a failure: that router simply declines to send ICMP Time Exceeded (common on cloud/AWS internal hops and by design in many VPCs). If you get *zero* hops or hang immediately, that's L3 reachability (routing) — a genuinely different problem than "some hops are silent."

### Prediction 3 — Isolate the layer of a failure: L3 vs. L4 vs. L7 (the debugging superpower)

**Prediction:** *If a service is unreachable, I can pin the broken layer by climbing the stack: `ping` tests L3, `nc`/`ss` tests L4, `curl -v` tests L7 — and the first rung that fails is the layer to fix, BECAUSE each tool exercises exactly one layer's job.*

```bash
# L3 — does the packet reach the host at all? (ICMP, no ports involved)
ping -c 3 payments.internal
#   64 bytes from 10.100.0.55: icmp_seq=1 ttl=63 time=0.9 ms   <- L3 OK

# L4 — is the PORT open / can I complete a TCP handshake? (no app data)
nc -vz payments.internal 443
#   Connection to payments.internal 443 port [tcp/https] succeeded!  <- L4 OK
ss -tnp 'dport = :443'     # see the ESTAB socket / handshake state locally

# L7 — does the APPLICATION actually respond correctly? (full HTTP + TLS)
curl -v https://payments.internal/pay
#   * TLS handshake ...            <- L6/TLS visible here
#   > GET /pay HTTP/1.1            <- L7 request
#   < HTTP/1.1 200 OK             <- L7 response  ✅
```

**Verify — read the failure by *where* the ladder stops:**
- `ping` fails but you expected reachability → **L3**: routing, [NetworkPolicy](28-kubernetes-network-policies.md), Security Group, or CNI. (Note: many clusters/SGs *block ICMP by design*, so treat ping as a hint, not proof.)
- `ping` works, `nc` fails → **L4**: the port's closed, no listener, or an SG/NACL/policy blocks that *port*.
- `nc` works, `curl` fails at `SSL/TLS` → **L6/L4 boundary**: cert or [TLS](11-tls-ssl-encryption-in-transit.md) handshake (`curl: (35)`), e.g. `openssl s_client -connect payments.internal:443` to inspect the cert.
- `curl` connects but returns `5xx`/wrong body → **L7**: it's the app, or [Ingress/mesh](27-kubernetes-ingress-gateway-api.md) routing — *not* the network.

That laddering **is** the OSI model as a debugging tool.

### Prediction 4 — See the merged "Application" layer in a cluster (Kubernetes-flavored)

**Prediction:** *If I inspect an L3/L4 NetworkPolicy vs. an L7 Ingress in the same cluster, the NetworkPolicy will express rules only in IPs/ports (never URLs), while the Ingress routes by hostname/path, BECAUSE policies operate at OSI L3/L4 and Ingress operates at the merged TCP/IP Application layer.*

```bash
# L3/L4 — a NetworkPolicy: note it speaks ports & selectors, NEVER paths.
kubectl get networkpolicy -A
kubectl describe networkpolicy <name> -n <ns>
#   Allowing ingress ... ports: TCP/443     <- L4 port
#   from: podSelector matchLabels app=web   <- L3 identity (pod IPs)
#   (there is no "path:" field — L7 is invisible to it)

# L7 — an Ingress: it routes by HOST and PATH, which live at the app layer.
kubectl get ingress -A
kubectl describe ingress <name> -n <ns>
#   Host              Path   Backends
#   payments.internal /pay   payments-svc:443     <- L7 hostname + path routing

# And the L4 machinery underneath the Service — kube-proxy's DNAT rules:
sudo iptables -t nat -L KUBE-SERVICES -n | head
#   ... /* default/payments-svc:https */ ... to:10.42.3.9:443   <- L4 DNAT
```

**Verify:** The NetworkPolicy has **ports and selectors but no path field** — confirming it can never allow/deny by `/pay` (answering Rung 5's check-yourself). The Ingress *does* route by `/pay` — that's the L7/merged-Application layer. The `iptables` DNAT line is your L4 [Service/kube-proxy](25-kubernetes-services-kube-proxy.md) machinery made concrete. If you ever try to write a "block `/admin`" rule in a NetworkPolicy, this prediction tells you *why it's impossible* and which component ([Ingress](27-kubernetes-ingress-gateway-api.md) or [service mesh](29-service-mesh-and-sidecars.md)) you must use instead.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
Data descends a stack of layers that each wrap it in their own header (encapsulation) and ascends the far stack unwrapping in reverse (decapsulation), so every layer converses only with its counterpart — and "which layer is broken?" becomes your fastest debugging move.

**Explain it to a beginner (3 sentences):**
Sending data across a network is like putting a letter inside nested envelopes: the app writes the letter, then each layer below wraps it in another envelope marked with what *its* level needs (port, then IP, then MAC), until it's raw signal on a wire. On the far side, each layer opens *only its own* envelope and passes the rest up, so the app at the top receives the exact letter that was sent. OSI names 7 of these layers (great for talking precisely), TCP/IP names 4 (what actually runs), and knowing which layer a symptom belongs to tells you exactly where to look.

**Sub-parts mapped to the one core idea:**
- *7 OSI layers / 4 TCP/IP layers* → the ordered list of jobs the "wrap-and-unwrap" happens across.
- *Encapsulation / decapsulation* → the wrapping down / unwrapping up, directly.
- *Headers* → the per-layer notes that make "each layer talks to its counterpart" possible.
- *PDUs (data→segment→packet→frame→bits)* → the same bytes renamed at each wrap.
- *L4 (Service/NLB/kube-proxy) vs. L7 (Ingress/ALB/mesh); NetworkPolicy at L3/L4* → *which layer* a cloud tool operates on.
- *"Which layer is the problem?"* → the payoff: the model turned into a bisection tool.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Prediction 3** and run the `ping` → `nc` → `curl -v` ladder against a *real* service in your cluster until reading "where the ladder stopped" is instant and automatic. That reflex — instantly mapping a symptom to a layer — is the entire reason this document exists. Then revisit **Rung 3's `tcpdump`** whenever the nesting stops feeling physical.

---

## Related concepts

- [IP addressing](02-ip-addressing.md) — the L3 addresses in every packet header.
- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — the L4 identifiers that let one host run many apps.
- [MAC addresses, switching & ARP](05-mac-addresses-switching-arp.md) — the L2 frame layer and next-hop delivery.
- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the L4 machinery (handshake, reliability) in full.
- [Routing & forwarding](08-routing-and-forwarding.md) — how L3 packets cross networks, TTL, and hop-by-hop forwarding.
- [Load balancing](18-load-balancing.md) — the concrete L4-vs-L7 split (NLB vs. ALB, K8s Services vs. Ingress).
- [Kubernetes network policies](28-kubernetes-network-policies.md) — L3/L4 pod firewalls, and why they can't see L7.
