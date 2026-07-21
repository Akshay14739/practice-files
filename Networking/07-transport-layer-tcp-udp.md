# The Transport Layer — TCP & UDP
*How raw, unreliable IP packets get turned into a trustworthy conversation between two programs — or a fire-and-forget shout when speed matters more than truth.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?**
You already know IP delivers a packet from one machine to another, and you know a **port** picks *which process* on that machine gets it. This rung is the layer that sits *between* those two ideas and makes them useful: the **transport layer (Layer 4)**. It answers a question IP simply refuses to answer — *"did my data actually arrive, in order, unbroken?"* IP shrugs and says "not my job." The transport layer picks up that job. It comes in two flavors:

- **TCP** (Transmission Control Protocol): connection-oriented, reliable, ordered, full-duplex. It turns a stream of lossy, possibly-reordered packets into a clean, in-order byte stream that either arrives correctly or tells you it failed.
- **UDP** (User Datagram Protocol): connectionless, unreliable, unordered, tiny. It slaps a source port, destination port, length, and checksum on your data and throws it at the network. No guarantees, no memory, no overhead. Fast.

**Why did it land on my desk?**
Picture an ordinary incident week on your EKS cluster. A readiness probe is flapping and you see `dial tcp 10.244.2.9:8080: connect: connection refused` — that "connect" is a **TCP handshake** failing. CoreDNS looks slow, and `tcpdump` on the node shows a storm of `UDP 53` packets with no connection state at all — that's **DNS over UDP**. A teammate says "just switch the health check to a TCP probe instead of HTTP" and you nod, but do you actually know what a "TCP probe" *does*? Someone mentions the new ALB does **HTTP/3**, which rides **QUIC over UDP/443**, and asks why anyone would rebuild reliability on top of unreliable UDP. Every one of these is the transport layer. If TCP and UDP are fuzzy, then handshakes, retransmits, "connection refused" vs "connection timed out", readiness probes, and half of what `kube-proxy` load-balances stay fuzzy too.

**What do I already know?**
- **IP** delivers **host-to-host** — machine `10.0.2.30` to machine `10.0.1.5` — and can lose, duplicate, delay, or reorder packets along the way. It makes *no promises*.
- A **port** (16-bit, 0–65535) selects the process, and a **socket** is `(IP, port)` — one endpoint of a conversation.
- **kubectl**, Security Groups ("allow TCP 443"), readiness probes, and CoreDNS are already daily vocabulary.

Hold those. We're going to slot the transport layer directly on top of IP: IP gets bytes *to the host*, and TCP/UDP decide *whether those bytes are trustworthy and which process they belong to.*

---

## 🔥 Rung 1 — The Pain

**The problem that forced the transport layer to exist:** IP is a liar, and applications can't build on a liar.

Rewind to a world with IP but nothing above it. Your app hands IP a 40 KB response and IP chops it into packets and sends them across a dozen routers. What can go wrong? *Everything.*

- A router's queue is full → it **drops** a packet. Gone. IP never tells anyone.
- Two packets take different paths → they arrive **out of order**. Packet 7 shows up before packet 4.
- A retransmit-happy link layer sends one twice → a **duplicate** arrives.
- Cosmic-ray bit-flip or a bad NIC → the payload arrives **corrupted**.
- The receiver is a tiny device with a full buffer → it gets **overwhelmed** and drops everything.
- Ten thousand senders all blast the same congested link → the network **collapses** into a useless storm (this literally happened to the early internet — the "congestion collapse" of October 1986, when throughput on a link dropped by a factor of a thousand).

With only IP, *every single application* would have to solve all of these itself. Your web server, your database driver, your mail agent — each would independently reimplement sequence numbers, acknowledgements, retransmission timers, reordering buffers, duplicate detection, flow control, and congestion avoidance. That's thousands of buggy, incompatible re-inventions of the hardest problems in networking.

The pre-transport "solution" was exactly that pain: reliability logic smeared into every application, done differently and wrongly each time. It's the equivalent of a postal system where the post office guarantees nothing — not delivery, not order, not that the envelope arrives unopened — so **every** business has to hire its own courier, invent its own tracking numbers, and phone every recipient to confirm receipt.

**Who feels this pain most today?** You do, one level up, constantly:
- A **readiness probe** must know "is the process actually accepting connections?" Only a real TCP handshake answers that. Without transport-layer connection semantics, "ready" is a guess.
- **kube-proxy** load-balances Services and must track connection state (for TCP) so return traffic goes back to the same pod. That state *is* the transport layer.
- **CoreDNS** answers thousands of lookups a second. If every DNS query paid TCP's handshake tax, cluster DNS would crawl. It rides **UDP** precisely to skip that tax — and that choice is only sane because the transport layer *offers* a lightweight option.
- When a pod says `connection refused` vs `connection timed out` vs `no route to host`, those are three *different transport/network-layer failures* telling you three different things. Read them wrong and you debug the wrong layer for an hour.

Without the transport layer, the internet is a pile of unreliable packets and no application can trust anything. TCP and UDP are the two contracts that make it usable.

> **Check yourself before Rung 2:** IP can already get bytes to the right *machine*, and ports can already get them to the right *process*. So what, precisely, is left over that neither IP nor ports provide — and which of TCP's jobs (ordering, acknowledgement, retransmission, flow control) would you have to write yourself if you only had IP + ports?

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it word for word:

> **IP moves packets host-to-host with zero promises; the transport layer adds process-to-process delivery (via ports) plus a choice of contract — TCP pays overhead to guarantee a reliable, ordered byte stream, while UDP pays nothing and guarantees nothing.**

That's the whole concept. Everything else is derivable:

- **Why does TCP need a handshake (SYN → SYN-ACK → ACK)?** Because "reliable" means both sides must first *agree they're talking* and exchange starting sequence numbers before any data flows. No shared starting point → no way to detect loss or order. The handshake is where that agreement is minted.
- **Why sequence and acknowledgement numbers?** Because "ordered" and "reliable" require numbering every byte so the receiver can reassemble in order, spot gaps (loss), discard repeats (duplicates), and tell the sender exactly how far it got (the ACK). Derive both from the word "reliable, ordered."
- **Why retransmission timers?** Because the *only* way to know a packet was lost on a network that never reports drops is: "I sent it, I started a timer, no ACK came back before the timer fired → resend." Loss detection falls straight out of "guarantee delivery over a medium that doesn't confirm delivery."
- **Why flow control AND congestion control (two different things)?** "Don't overwhelm" has two victims: the **receiver** (a slow endpoint — solved by the *receive window*, flow control) and the **network** (congested links between you — solved by the *congestion window*, congestion control). Two distinct dangers → two distinct throttles.
- **Why does UDP even exist?** Because for some workloads the *contract itself is the cost*. If a late packet is worthless anyway (live video, VoIP, a DNS retry you'd rather just re-ask), then paying for handshakes, ordering, and retransmits is pure waste. Strip all of it away and you get UDP: four header fields and go.
- **Why a checksum on both?** Because even "unreliable" UDP should not hand your app *corrupted* bytes silently. Integrity (is this data intact?) is cheaper and more universal than reliability (did it arrive at all?), so *both* protocols carry a checksum; only TCP adds the machinery to *recover* from failure.

If you ever get lost below, come back to this sentence and re-derive. TCP is "the reliable contract"; UDP is "no contract"; both add ports on top of IP. The rest of this document is that sentence, unfolded.

---

## ⚙️ Rung 3 — The Machinery

This is the rung to go slow on. Let's open the hood on both protocols.

### Where the transport layer sits

IP is Layer 3 (host-to-host). The transport layer is Layer 4 (process-to-process), and it *wraps* your application data before handing it down to IP:

```
   ┌─────────────────────────────────────────────────────────────────┐
   │ IP header (L3)   src 10.0.2.30 → dst 10.0.1.5   (WHICH MACHINE)  │
   │  ┌──────────────────────────────────────────────────────────────┐│
   │  │ TCP or UDP header (L4)   src port → dst port  (WHICH PROCESS) ││
   │  │  + TCP only: seq, ack, flags, window, checksum                ││
   │  │  ┌───────────────────────────────────────────────────────────┐││
   │  │  │ Application data (HTTP request, DNS query, gRPC frame...)  │││
   │  │  └───────────────────────────────────────────────────────────┘││
   │  └──────────────────────────────────────────────────────────────┘│
   └─────────────────────────────────────────────────────────────────┘

   IP answers "which machine."  Ports answer "which process."
   TCP's extra fields answer "did it arrive, in order, intact — and how fast may I send?"
```

The unit at this layer has a name: TCP calls its unit a **segment**; UDP calls its unit a **datagram**. Both become the payload of an IP packet.

### The TCP header — what all that machinery costs

A TCP header is **20 bytes minimum** (up to 60 with options). Every field earns its place:

```
   TCP HEADER (the price of reliability)
   ┌───────────────────────┬───────────────────────┐
   │  Source Port (16)     │  Dest Port (16)       │  ← which processes
   ├───────────────────────┴───────────────────────┤
   │  Sequence Number (32)                          │  ← byte offset of THIS data
   ├────────────────────────────────────────────────┤
   │  Acknowledgement Number (32)                   │  ← "I've received up to here"
   ├──────┬───────┬─────────────────────────────────┤
   │ Data │ flags │  Window Size (16)               │  ← flow control (receiver's free buffer)
   │offset│SYN ACK│                                 │
   │      │FIN RST│                                 │
   ├──────┴───────┼─────────────────────────────────┤
   │ Checksum (16)│  Urgent Pointer (16)            │  ← integrity
   └──────────────┴─────────────────────────────────┘
```

### The UDP header — what "no contract" looks like

A UDP header is **8 bytes. Total.** Four fields, and it's done:

```
   UDP HEADER (the whole thing)
   ┌───────────────────────┬───────────────────────┐
   │  Source Port (16)     │  Dest Port (16)       │  ← which processes
   ├───────────────────────┼───────────────────────┤
   │  Length (16)          │  Checksum (16)        │  ← size + integrity, nothing more
   └───────────────────────┴───────────────────────┘
```

No sequence numbers (no ordering). No ack numbers (no delivery confirmation). No window (no flow control). No flags (no connection to open or close). That's *why* it's fast: there's nothing to negotiate and nothing to remember. Send and forget.

### TCP's 3-way handshake — minting the connection

Before a single byte of your HTTP request flows, TCP performs a three-message ritual to agree the connection exists and to exchange starting sequence numbers. Assume client `10.0.2.30` connecting to server `10.0.1.5:6443`:

```
   CLIENT (10.0.2.30:51000)                       SERVER (10.0.1.5:6443)
        │                                                 │
        │  ①  SYN   seq=x                                 │   "Let's talk. My byte
        ├────────────────────────────────────────────────►    stream starts at x."
        │                                                 │
        │                                     SERVER picks its own random y,
        │                                     notes client's x, allocates a socket.
        │  ②  SYN, ACK   seq=y, ack=x+1                   │   "OK. Mine starts at y,
        ◄────────────────────────────────────────────────┤    and I got your x."
        │                                                 │
        │  ③  ACK   ack=y+1                               │   "Got your y. We're up."
        ├────────────────────────────────────────────────►
        │                                                 │
        │  ═══ connection ESTABLISHED (full-duplex) ═══   │
        │  now HTTP/TLS/gRPC data flows BOTH directions   │
```

**Why THREE messages, not two?** Because TCP is **full-duplex** — data flows *both* ways — so *each* direction is a separate stream that must be opened and acknowledged. The client opens its direction (SYN) and the server acknowledges it; the server opens its direction (SYN) and the client acknowledges it. Cleverly, the server's SYN and its ACK of the client's SYN ride in *one* packet (the SYN-ACK), collapsing four logical steps into three physical packets.

**Why are the initial sequence numbers `x` and `y` RANDOM?** This is a security property, not an accident. If ISNs were predictable (say, always starting at 0, or a simple counter), an off-path attacker who couldn't see your traffic could still **guess** the sequence numbers and inject forged segments — spoofing packets that TCP would accept as part of your connection (TCP sequence-prediction / connection-hijacking / blind data-injection attacks). Randomizing the ISN with a strong per-connection value means an attacker has to guess a 32-bit number, making blind injection statistically hopeless. Real, standardized defense (RFC 6528). Predictable ISNs were a genuine, exploited vulnerability in the 1990s.

### How TCP delivers reliably — sequence numbers, ACKs, and timers

Once established, every byte TCP sends is *numbered* by the sequence number. The receiver acknowledges the highest contiguous byte it has received. This single mechanism gives you three properties at once:

```
   Sender sends 4 segments, each 100 bytes, starting seq=1000:
        seq=1000 (bytes 1000-1099)  ──►  ACK 1100  ("got through 1099, send 1100 next")
        seq=1100 (bytes 1100-1199)  ──X   LOST in the network
        seq=1200 (bytes 1200-1299)  ──►  ACK 1100  ("still waiting for 1100!")  ← duplicate ACK
        seq=1300 (bytes 1300-1399)  ──►  ACK 1100  ("still 1100!")               ← duplicate ACK

   ORDERING:   receiver holds 1200 & 1300 in a buffer, won't deliver to the
               app until the gap at 1100 is filled.
   LOSS:       the missing ACK + duplicate ACKs for 1100 tell the sender
               "1100 never arrived." A RETRANSMISSION TIMER also guards it:
               if no new ACK arrives before the timer fires, resend 1100.
   DEDUP:      if 1200 arrives twice, its sequence number is identical, so the
               receiver simply discards the duplicate. No app ever sees it.
```

- **Retransmission timer (RTO):** when TCP sends a segment it starts a timer. If the ACK doesn't come back before the timer expires, TCP assumes loss and resends. The timeout is computed from the measured **round-trip time (RTT)** and adapts continuously — a fast LAN gets a short timer, a satellite link a long one.
- **Fast retransmit:** waiting for the timer is slow, so TCP also treats **three duplicate ACKs** (all saying "I still need 1100") as immediate proof of loss and resends *without* waiting for the timer.
- **The checksum** guards integrity: the receiver recomputes it over the header + payload (+ a pseudo-header of the IPs); if it doesn't match, the segment is corrupt and silently dropped — which then looks like loss, so the same retransmission machinery recovers it.

### Flow control vs congestion control — two different throttles

These are constantly confused. They solve *different* problems:

```
   ┌──────────────────────────────────────────────────────────────────┐
   │ FLOW CONTROL  —  protect the RECEIVER                             │
   │                                                                   │
   │   The receiver advertises a WINDOW ("I have room for N more       │
   │   bytes") in every ACK. The sender may not have more than N       │
   │   unacknowledged bytes in flight. If the receiver's buffer        │
   │   fills, it advertises window=0 and the sender STOPS.             │
   │                                                                   │
   │   Danger:  a fast sender drowning a slow receiver.                │
   │   Signal:  the receive window field in the TCP header.            │
   └──────────────────────────────────────────────────────────────────┘
   ┌──────────────────────────────────────────────────────────────────┐
   │ CONGESTION CONTROL  —  protect the NETWORK in between             │
   │                                                                   │
   │   The sender keeps its OWN hidden congestion window (cwnd). It    │
   │   starts small (slow start), grows while ACKs flow smoothly, and  │
   │   BACKS OFF sharply when it detects loss (loss = the network is   │
   │   overloaded). Algorithms: Reno, CUBIC (Linux default), BBR.      │
   │                                                                   │
   │   Danger:  every sender flooding a shared, congested link →       │
   │            congestion collapse.                                   │
   │   Signal:  packet loss / delay, inferred by the sender.           │
   └──────────────────────────────────────────────────────────────────┘

   The actual send rate is limited by  min(receive window, congestion window).
   Flow control = the receiver's request.  Congestion control = the sender's caution.
```

The receiver can protect *itself* but knows nothing about the congested router three hops away — so the sender must infer congestion (usually from loss) and self-limit. Two problems, two mechanisms, working together.

### TCP teardown — the 4-way close (FIN)

Because each direction is independent, closing is symmetric to opening: each side closes *its own* direction with a **FIN**, and the other side ACKs it. That's four messages:

```
   CLIENT                                        SERVER
     │  ①  FIN          "I'm done sending."         │
     ├─────────────────────────────────────────────►
     │  ②  ACK          "OK, noted."                 │
     ◄─────────────────────────────────────────────┤
     │           (server may still send data —       │
     │            its half is still open!)           │
     │  ③  FIN          "Now I'm done too."          │
     ◄─────────────────────────────────────────────┤
     │  ④  ACK          "OK, noted."                 │
     ├─────────────────────────────────────────────►
     │                                               │
     │  client enters TIME_WAIT (~2×MSL, e.g. 60s)   │
     │  so late/duplicate segments drain safely.     │
```

That **TIME_WAIT** state — the closing side lingers for roughly twice the maximum segment lifetime — is why a busy node or NAT can pile up thousands of `TIME_WAIT` sockets. It's not a leak; it's TCP making sure a stray delayed segment from the old connection can't be mistaken for a new one. UDP, having no connection, has *none* of this: no handshake to open, no FIN to close, no TIME_WAIT to linger. Send and forget.

### The whole thing at a glance

```
        APPLICATION  (nginx, CoreDNS, kubectl, gRPC service)
              │  writes bytes / datagrams
   ┌──────────┴───────────┐
   │   TCP                 │   UDP
   │  handshake, seq/ack,  │  just src/dst port,
   │  retransmit, windows, │  length, checksum —
   │  ordering, teardown   │  then straight to IP
   └──────────┬───────────┘
              │  segment / datagram
              ▼
            IP (L3)  — host-to-host, no promises, decrements TTL each hop
              ▼
            link / NIC / VPC / the wire
```

Everything the app never sees — the resends, the reordering buffer, the window arithmetic, the congestion backoff — happens *inside TCP*, invisibly. The app just reads a clean byte stream. That invisibility is the entire value proposition.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Transport layer (L4)** | The layer providing process-to-process delivery on top of IP's host-to-host | Wraps app data with a TCP or UDP header |
| **TCP** | Connection-oriented, reliable, ordered, full-duplex protocol | The full reliability machine (handshake→teardown) |
| **UDP** | Connectionless, unreliable, unordered, minimal protocol | 8-byte header, no state, send-and-forget |
| **Segment** | TCP's unit of data | The thing carrying seq/ack/flags |
| **Datagram** | UDP's unit of data (also the generic word for a self-contained packet) | The 8-byte-header UDP unit |
| **Port** | 16-bit process selector in the L4 header | src/dst port fields (both protocols) |
| **3-way handshake** | SYN → SYN-ACK → ACK connection setup | Opens both directions, exchanges ISNs |
| **SYN / ACK / FIN / RST** | TCP control flags: synchronize / acknowledge / finish / reset | Handshake, acknowledgement, teardown, abrupt abort |
| **ISN (initial sequence number)** | The random starting byte-count for a direction | Chosen at handshake; random for security (RFC 6528) |
| **Sequence number** | Byte offset of the data in this segment | Ordering + duplicate detection |
| **Acknowledgement number** | Next byte the receiver expects ("got everything below this") | Loss detection, cumulative ACK |
| **Retransmission timer (RTO)** | Timer started per unacked segment; fires → resend | Loss recovery over a medium that never reports drops |
| **Fast retransmit** | Resend after 3 duplicate ACKs, without waiting for RTO | Faster loss recovery |
| **Receive window (rwnd)** | Receiver-advertised free buffer space | **Flow control** — protect the receiver |
| **Congestion window (cwnd)** | Sender's private, loss-driven send limit | **Congestion control** — protect the network |
| **Checksum** | Integrity value over header + payload | Detects corruption (both TCP and UDP) |
| **Teardown (4-way close)** | FIN/ACK in each direction to end a connection | Graceful close; leaves TIME_WAIT |
| **TIME_WAIT** | Post-close lingering state (~2×MSL) | Drains stray old segments before reuse |
| **Full-duplex** | Both directions carry data independently | Why handshake is 3-way and close is 4-way |
| **QUIC** | A reliable, encrypted transport built *on top of* UDP | HTTP/3's transport; reimplements TCP-like reliability in userspace over UDP/443 |

**Same kind of thing, different names — don't let these confuse you:**

- **"The reliability trio":** *sequence numbers*, *acknowledgement numbers*, and *retransmission timers* are three names for parts of one mechanism — number the bytes, confirm what arrived, resend what didn't.
- **"Two different windows":** the **receive window** (flow control, in the header, set by the *receiver*) and the **congestion window** (congestion control, hidden, set by the *sender*) both cap how much is in flight, but they defend against *different* victims. Never merge them.
- **"Segment vs datagram vs packet vs frame":** a TCP **segment** and a UDP **datagram** are L4 units; an IP **packet** is the L3 wrapper around them; an Ethernet **frame** is the L2 wrapper around *that*. Same bytes, different layer's name.
- **"Connection setup/teardown":** *3-way handshake* (SYN/SYN-ACK/ACK) and *4-way close* (FIN/ACK ×2) are the open and close ceremonies of the same connection object — TCP only.
- **"TCP probe" (Kubernetes) = a bare handshake:** a `tcpSocket` readiness/liveness probe literally just completes a 3-way handshake to a port and immediately closes it. "Did SYN-ACK come back?" = ready.

---

## 🔬 Rung 5 — The Trace

Let's follow **one** concrete action end to end, contrasting both protocols on the same picture: **a pod resolves a name via CoreDNS (UDP/53), then makes an HTTPS/gRPC call to another service (TCP).**

Assume: client pod `10.244.1.7`, CoreDNS ClusterIP `10.96.0.10:53`, target Service backing pod `10.244.2.9:8443`.

### Part A — the DNS lookup rides UDP (no handshake)

```
 STEP 1  App calls getaddrinfo("payments.default.svc.cluster.local").
         The resolver builds a DNS QUERY and hands it to UDP.

 STEP 2  UDP does NOTHING ceremonial. It stamps an 8-byte header:
            src port 43000 (ephemeral) → dst port 53, length, checksum.
         One datagram, straight down to IP. No SYN, no state.

 STEP 3  IP wraps it: src 10.244.1.7 → dst 10.96.0.10. It leaves the pod's veth,
         kube-proxy DNATs the ClusterIP 10.96.0.10 to a real CoreDNS pod IP,
         the datagram arrives, CoreDNS demuxes on dst port 53.

 STEP 4  CoreDNS answers in ONE UDP datagram: src port 53 → dst port 43000,
         payload = "payments = 10.96.0.55". Done. No teardown, no ACK.

 STEP 5  If that single datagram had been LOST, there is no retransmit built in —
         the resolver itself just TIMES OUT and re-asks. That's the whole
         "reliability" story for DNS: ask again. Cheap, because a stale answer
         is worthless anyway. (Big answers fall back to DNS-over-TCP/53.)
```

### Part B — the service call rides TCP (full ceremony)

```
 STEP 6  App connects to 10.96.0.55:8443 (the ClusterIP:port from DNS).
         Kernel assigns ephemeral src port 51000. kube-proxy will DNAT the
         ClusterIP to the real pod 10.244.2.9:8443.

 STEP 7  3-WAY HANDSHAKE (this is what a failing readiness probe fails at):
            → SYN      seq=x                 (open my direction)
            ← SYN,ACK  seq=y, ack=x+1        (open yours, ack mine)
            → ACK      ack=y+1               (ack yours) → ESTABLISHED

 STEP 8  TLS handshake, then the HTTP/2 (gRPC) request flow — every byte
         numbered by sequence, every arrival ACKed. A dropped segment is
         caught by the retransmission timer (or 3 dup-ACKs) and resent. The
         receive window keeps the fast side from drowning the slow side.

 STEP 9  Response streams back, ports SWAPPED: src 8443 → dst 51000, reassembled
         in order, corruption caught by checksum, gaps refilled by retransmit.

 STEP 10 4-WAY CLOSE:  → FIN / ← ACK / ← FIN / → ACK. Client parks in TIME_WAIT
         (~60s) so a late stray segment can't poison a future connection.
```

Visual of the two styles side by side:

```
   UDP (DNS): fire and forget                TCP (gRPC): a managed conversation
   ─────────────────────────                 ────────────────────────────────
   client            CoreDNS                 client                    server
     │ query :53        │                      │ SYN ───────────────►    │
     ├─────────────────►│                      │ ◄──────────── SYN,ACK   │
     │ ◄──────── answer │                      │ ACK ───────────────►    │  established
     │   (1 datagram)   │                      │ data⇄data (seq/ack/win) │
     │  no ACK,no close │                      │ FIN/ACK  FIN/ACK  close  │
     ▼                  ▼                      ▼                         ▼
   ~1 round trip, zero state                 1 RTT just to set up, full state both ends
```

Notice the trade in one glance: DNS gets its answer in a single round trip with no bookkeeping, accepting that a lost query just means "ask again." The gRPC call pays a full round trip *before any data*, plus per-byte accounting and a four-packet goodbye — and in exchange the application reads a guaranteed, in-order, uncorrupted stream and never has to think about loss.

---

## ⚖️ Rung 6 — The Contrast

The "older/alternative approach" here is UDP itself — the *minimal* transport that predates all of TCP's guarantees and still thrives precisely because it *omits* them. TCP and UDP aren't better/worse; they're two answers to "how much contract do I want?"

| | **TCP** | **UDP** |
|---|---|---|
| Connection | Connection-oriented (handshake first) | Connectionless (just send) |
| Reliability | Guaranteed delivery (retransmits) | None — lost = gone |
| Ordering | In-order byte stream | No ordering; app must handle it |
| Duplicate handling | Detected & discarded (by seq number) | App must handle it |
| Flow control | Yes (receive window) | No |
| Congestion control | Yes (congestion window, CUBIC/BBR…) | No (app must be a good citizen) |
| Header size | 20–60 bytes | 8 bytes |
| Setup cost | 1 RTT handshake before data | Zero — first packet carries data |
| Speed / latency | Slower to start, steady after | Minimal latency, minimal overhead |
| State kept | Per-connection state both ends (+ TIME_WAIT) | None |
| Unit | Segment (byte stream) | Datagram (message boundaries preserved) |
| Kubernetes uses | HTTP/gRPC apps, API server 6443, kubelet 10250, etcd 2379, TCP probes | DNS→CoreDNS 53, VXLAN overlays, HTTP/3 (QUIC), metrics push |

**When to use each (memorize the split):**

- **TCP** when *correctness beats latency* and you need every byte: **HTTP/HTTPS (80/443), SSH (22), email (SMTP 25, IMAP 143, POP3 110), databases (MySQL 3306, Postgres 5432), gRPC, the K8s API (6443)**. If a missing byte corrupts the result, use TCP.
- **UDP** when *fresh-and-fast beats complete-and-late*, or you'll build your own reliability: **DNS (53), live video/streaming, VoIP, online gaming, NTP (123), VXLAN overlay tunnels, and QUIC / HTTP/3 (443)**. If a late packet is worthless (you'd rather have the *next* frame than a resent old one), use UDP.

**What UDP can do that TCP cannot:** send with *zero* setup latency, preserve message boundaries (each datagram is one discrete message), multicast/broadcast to many receivers, and hand control of reliability to the application (which is exactly what **QUIC** does — it runs over UDP/443 and reimplements TCP-style reliability, ordering, and congestion control *in userspace*, gaining faster connection setup, no head-of-line blocking across streams, and the ability to evolve without waiting for OS kernels to update).

**What TCP can do that UDP cannot:** hand your application a reliable, ordered, de-duplicated byte stream *for free*, and automatically be a polite network citizen under congestion — without a single line of application logic.

**Why TCP over UDP (one sentence):** choose TCP when you want the network to guarantee correctness so your application doesn't have to — and choose UDP when the guarantees themselves are the cost you can't afford (or the reliability you'd rather build yourself, QUIC-style).

> **Check yourself before Rung 7:** A Kubernetes `readinessProbe` of type `tcpSocket` on port 8080 succeeds, but an `httpGet` probe on the same port fails with a 500. What does the *TCP* probe actually prove versus the *HTTP* probe — and which layer's success are you observing in each case?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **out loud before running the command.** The learning is in the gap between what you predicted and what you saw.

### Example 1 — Normal case: watch a real 3-way handshake and teardown

**Prediction:** *If I capture packets to an HTTPS server while making one request, then I'll see exactly `SYN`, then `SYN-ACK`, then `ACK` at the start, and `FIN`/`ACK` pairs at the end, BECAUSE TCP must open both directions before data and close both directions after — the flags in the header are that ceremony made visible.*

```bash
# Terminal 1: capture SYN/ACK/FIN flags to one host, numeric, no reverse DNS.
# 'tcp[tcpflags]' filters let us see the handshake clearly.
sudo tcpdump -ni any 'host example.com and tcp port 443' -c 20

# Terminal 2: make exactly one request
curl -s https://example.com >/dev/null
```

```text
# Representative tcpdump output (flags shown in [brackets]):
IP 10.0.2.30.51000 > 93.184.216.34.443: Flags [S],  seq 1000000        # SYN
IP 93.184.216.34.443 > 10.0.2.30.51000: Flags [S.], seq 7000000, ack 1000001  # SYN-ACK
IP 10.0.2.30.51000 > 93.184.216.34.443: Flags [.],  ack 7000001         # ACK  → ESTABLISHED
IP 10.0.2.30.51000 > 93.184.216.34.443: Flags [P.], ... (TLS ClientHello)
...
IP 10.0.2.30.51000 > 93.184.216.34.443: Flags [F.], ...                 # FIN
IP 93.184.216.34.443 > 10.0.2.30.51000: Flags [F.], ...                 # FIN
IP 10.0.2.30.51000 > 93.184.216.34.443: Flags [.],  ...                 # final ACK
```

You can also watch the connection's *state* change with `ss`:

```bash
# -t TCP, -a all states, -n numeric.  Run repeatedly during/after the curl:
ss -tan 'dst 93.184.216.34'
# ESTAB ... during the request
# TIME-WAIT ... for ~60s after it closes   ← the TIME_WAIT lingering you learned about
```

**Verify:** In tcpdump, `[S]` = SYN, `[S.]` = SYN+ACK, `[.]` = ACK, `[F.]` = FIN+ACK, `[P.]` = PSH+ACK (data). Seeing S / S. / . in that order *is* the handshake. A **wrong result** — you see `[S]` sent repeatedly with no `[S.]` reply — teaches you the server never answered: a firewall/Security Group dropped the SYN, or nothing is listening. That "SYN with no SYN-ACK" pattern is the packet-level signature of a `connection timed out`.

### Example 2 — Edge/failure case: connection refused vs. connection timed out (two different failures)

**Prediction:** *If I try TCP to a port where nothing listens on a reachable host, I'll get an instant `connection refused` (the host actively RSTs me); but if I try a port that a firewall silently drops, I'll get a slow `connection timed out` instead — BECAUSE "refused" means my SYN reached a live host that answered `RST`, while "timed out" means my SYN vanished and the retransmission timer kept resending until it gave up.*

```bash
# (a) Reachable host, dead port → fast, active refusal (RST):
nc -vz 127.0.0.1 9   # port 9 (discard) almost certainly closed locally
# nc: connect to 127.0.0.1 port 9 (tcp) failed: Connection refused   ← INSTANT

# (b) A silently-dropped port → slow timeout (SYN retransmitted, no reply):
nc -vz -w 5 10.255.255.1 80   # unroutable/blackholed address, 5s timeout
# nc: connect to 10.255.255.1 port 80 (tcp) timed out: Operation now in progress  ← SLOW

# Watch the difference in packets for the timeout case:
sudo tcpdump -ni any 'host 10.255.255.1 and tcp' &
nc -vz -w 5 10.255.255.1 80
# You'll see repeated  Flags [S]  (SYN) retransmissions with NO reply — the
# retransmission timer firing again and again before nc gives up.
```

**Verify:** "Refused" returns in milliseconds because a live kernel sent back a `RST` — the port is closed but the host is *there*. "Timed out" takes seconds because your SYN got no answer at all and TCP's retransmission timer kept trying. A **wrong result** — getting "refused" where you expected a hang — teaches you a firewall is *rejecting* (sending RST/ICMP) rather than *dropping* silently, which is a real, useful distinction when debugging a Security Group (drop → timeout) vs. a `REJECT` iptables rule (→ refused). This is exactly the difference behind a Kubernetes pod's `dial tcp ...: connection refused` (pod up, process not listening yet) versus `i/o timeout` (NetworkPolicy or SG blackholing the SYN).

### Example 3 — TCP vs UDP behavior with `nc`, and why UDP "succeeds" even when nothing listens

**Prediction:** *If I probe a closed port over TCP vs UDP with `nc`, TCP will clearly fail (RST → refused), but UDP will often appear to "succeed" even with nothing listening — BECAUSE UDP is connectionless: there's no handshake to reject, so `nc` sends a datagram into the void and, absent an ICMP "port unreachable", has no way to know it was never received.*

```bash
# --- TCP: a real handshake, honest result ---
# Terminal 1 (listener):   nc -l 4000
# Terminal 2 (client):
nc -vz 127.0.0.1 4000     # → succeeded  (SYN/SYN-ACK/ACK completed)
# Stop the listener, try again:
nc -vz 127.0.0.1 4000     # → Connection refused  (RST, instant)

# --- UDP: no connection, so 'success' is an illusion ---
# Terminal 1 (listener):   nc -u -l 4000
# Terminal 2 (client):
echo "hello" | nc -u -w1 127.0.0.1 4000   # listener prints "hello"  ✔ truly delivered
# Now KILL the listener and send again:
echo "hello" | nc -u -w1 127.0.0.1 4000   # nc STILL exits 0 — no error!
#   The datagram left; with no listener the kernel may send ICMP port-unreachable,
#   but many paths swallow it, so the sender often can't tell delivery failed.
```

A cleaner way to *see* the two protocols on the wire:

```bash
# TCP shows flags; UDP shows none — just a datagram with a length.
sudo tcpdump -ni any 'udp port 4000 or tcp port 4000' -c 6
# UDP 127.0.0.1.55123 > 127.0.0.1.4000: UDP, length 6      ← no SYN/ACK/FIN, ever
# IP  127.0.0.1.51234 > 127.0.0.1.4000: Flags [S] ...      ← TCP opens with SYN
```

**Verify:** TCP gives you a truthful "connected / refused" because the handshake either completes or is rejected. UDP gives you no such signal — the tcpdump line for UDP has **no flags**, just `UDP, length N`, proving there is no connection state at all. A **wrong result** — expecting UDP to report failure like TCP does — teaches you *why applications over UDP must build their own confirmation*: DNS resolvers time out and re-query, QUIC adds acknowledgements in userspace, and a "UDP readiness probe" is nearly meaningless (which is precisely why Kubernetes readiness/liveness probes are `tcpSocket`/`httpGet`/`grpc`, never plain UDP).

### Example 4 — Kubernetes-flavored: a `tcpSocket` readiness probe is just a handshake

**Prediction:** *If I define a `tcpSocket` readiness probe on a container's port, then the kubelet will mark the pod Ready only once a TCP handshake to that port succeeds — and if I point the probe at a port nothing listens on, the pod stays `Running` but `0/1 READY` forever, BECAUSE a TCP probe is literally "can I complete SYN → SYN-ACK → ACK?", nothing more.*

```yaml
# probe-demo.yaml — container listens on 8080; probe checks TCP reachability to it
apiVersion: v1
kind: Pod
metadata:
  name: probe-demo
spec:
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:latest   # listens on 8080
      ports:
        - containerPort: 8080
      readinessProbe:
        tcpSocket:
          port: 8080          # ← works: nginx is listening here
        initialDelaySeconds: 2
        periodSeconds: 5
      livenessProbe:
        tcpSocket:
          port: 8080
        periodSeconds: 10
```

```bash
kubectl apply -f probe-demo.yaml
kubectl get pod probe-demo -w
# NAME         READY   STATUS    ...
# probe-demo   0/1     Running   ...   ← before first successful handshake
# probe-demo   1/1     Running   ...   ← kubelet completed SYN/SYN-ACK/ACK to :8080

# Now break it: change the probe port to 9999 (nothing listens there) and re-apply.
# The kernel on the pod's node has no listener on 9999, so the SYN gets a RST →
# handshake fails → probe fails:
kubectl describe pod probe-demo | grep -A2 Readiness
# Readiness probe failed: dial tcp 10.244.x.y:9999: connect: connection refused
kubectl get pod probe-demo
# probe-demo   0/1   Running   ← stuck NotReady; Service will NOT send it traffic
```

**Verify:** A working `tcpSocket` probe flips the pod to `1/1 READY` the instant a handshake succeeds; a wrong port yields `connection refused` and the pod is pulled from the Service's endpoints (kube-proxy won't DNAT traffic to a NotReady pod). A **wrong result** — the pod reporting Ready while the app is actually broken behind the port — teaches you the *limit* of a TCP probe: it proves only that *something accepted the handshake*, not that the app is healthy. That's exactly when you upgrade to an `httpGet` or `grpc` probe, which drives an actual application-layer request on top of the TCP connection. (Contrast: there is deliberately no `udpSocket` probe — UDP has no handshake to succeed, so "did it connect?" is unanswerable.)

---

## 🏔️ Capstone — Compress It

**One-sentence summary:**
IP hauls packets host-to-host with no promises, and the transport layer adds process-to-process delivery via ports plus a choice of contract — TCP spends a handshake, sequence/ack numbers, retransmission timers, and two kinds of windowing to guarantee a reliable, ordered byte stream, while UDP spends nothing (an 8-byte header) and guarantees nothing but speed.

**Explain it to a beginner (3 sentences):**
The internet's basic delivery service (IP) can lose your packets, jumble their order, or corrupt them, and it never tells you — so on top of it we put a transport layer that makes two offers. TCP is like registered mail with tracking: it shakes hands to open a connection, numbers every piece so nothing is lost or out of order, resends anything that goes missing, and slows down so it doesn't overwhelm the receiver or the network — great for web pages, SSH, and databases where every byte must be right. UDP is like shouting across a room: it just sends and hopes, with almost no overhead — perfect for DNS lookups, live video, and gaming, where a late packet is useless and you'd rather have the next one now.

**Sub-parts mapped to the one core idea** ("IP has no promises; TCP is the reliable contract, UDP is no contract, both add ports"):
- *3-way handshake (SYN/SYN-ACK/ACK)* → how TCP mints the shared state its guarantees require; random ISNs make it secure.
- *Sequence & acknowledgement numbers + retransmission timer* → the machinery that delivers "reliable, ordered, de-duplicated."
- *Flow control (receive window) vs congestion control (congestion window)* → two throttles for two victims: the receiver and the network.
- *Checksum* → integrity, carried by *both* protocols; only TCP recovers from failure.
- *4-way FIN teardown + TIME_WAIT* → gracefully closing the two independent directions of a full-duplex connection.
- *UDP's 8-byte header (src port, dst port, length, checksum)* → what's left when you strip every guarantee away: pure process-to-process speed.
- *TCP-vs-UDP use cases + QUIC/HTTP/3* → picking the contract by whether correctness or freshness wins; QUIC proves you can even rebuild TCP's guarantees over UDP when you want control.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 1** and capture a real handshake with `tcpdump` while watching `ss` flip through `ESTAB` → `TIME-WAIT` — once you *see* SYN / SYN-ACK / ACK and the FIN dance with your own eyes, the whole "reliable connection" idea stops being abstract. If the *flow-control-vs-congestion-control* split still feels slippery, sit with **Rung 3's** two-box diagram until "receiver's window vs sender's window" is reflexive; and if you want the UDP contrast to land, redo **Example 3** and notice the UDP datagram has *no flags at all* — that absence is the entire difference.

---

## Related concepts

- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — the port numbers TCP and UDP carry, and the 4-tuple that names each connection.
- [OSI & TCP/IP models](06-osi-and-tcpip-models.md) — where the transport layer sits in the stack and how segments/datagrams get encapsulated.
- [IP addressing](02-ip-addressing.md) — the host-to-host layer beneath, whose "no promises" forced TCP to exist.
- [DNS](09-dns.md) — the classic UDP/53 workload (with TCP/53 fallback) traced in Rung 5.
- [HTTP & HTTPS](10-http-and-https.md) — the TCP-riding application protocol on top, including HTTP/3 over QUIC/UDP.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — how both TCP and UDP Services get DNAT load-balanced, and where TCP readiness probes fit.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** IP gets bytes to the right machine and ports get them to the right process — so what is left over that neither provides, and which of TCP's jobs would you have to write yourself with only IP + ports?

**A:** What's left over is *trust*: IP + ports say nothing about whether the bytes arrived at all, arrived once, arrived intact, or arrived in the right order — IP can drop, duplicate, delay, reorder, or corrupt packets and never tells anyone. With only IP + ports you would have to write **all four** of TCP's jobs yourself: **ordering** (sequence numbers plus a reassembly buffer to fill gaps and discard duplicates), **acknowledgement** (telling the sender what actually arrived), **retransmission** (timers that resend anything unacknowledged, since the network never reports drops), and **flow control** (a window so a fast sender doesn't drown a slow receiver) — and, to be a good citizen, congestion control too. That is exactly the pre-transport pain: every application reimplementing the hardest problems in networking, differently and wrongly each time.

### Before Rung 7
**Q:** A `tcpSocket` readiness probe on port 8080 succeeds, but an `httpGet` probe on the same port fails with a 500. What does each probe actually prove, and which layer's success are you observing?

**A:** The `tcpSocket` probe proves only that a **3-way handshake completed** — a SYN to port 8080 got a SYN-ACK back and the kubelet ACKed it, meaning *something* is listening and accepting connections. That is purely a **Layer 4 (transport)** success. The `httpGet` probe goes further: on top of that same TCP connection it sends a real HTTP request and requires a healthy response, so a 500 is a **Layer 7 (application)** failure — the process accepts connections but the app behind the socket is broken. So the situation is entirely consistent: L4 is fine, L7 is not, which is precisely why you upgrade from a bare-handshake TCP probe to an `httpGet`/`grpc` probe when "accepting connections" isn't the same as "healthy."
