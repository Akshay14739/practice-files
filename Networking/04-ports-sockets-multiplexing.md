# Ports, Sockets & Multiplexing
*How one machine with one IP address quietly runs a hundred conversations at once — and never mixes them up.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?**
You already know an IP address answers the question *"which machine?"* This rung teaches the question that comes *immediately after*: **"which program on that machine?"** That answer is a **port** — a 16-bit number that labels a specific conversation endpoint inside a host. A **socket** is the full pairing of `(IP address, port)` — the exact doorknob a process grabs to talk to the network. And **multiplexing** is the magic that lets one network card, one IP, one cable carry your SSH session, your `kubectl` stream, a Prometheus scrape, and a database query all at the same time without a single crossed wire.

**Why did it land on my desk?**
Picture a Tuesday on your EKS cluster. You run `kubectl get pods` and it hangs. You SSH to a node and someone says "check if the API server is even listening." You type `ss -tlnp` and see a wall of numbers: `:6443`, `:10250`, `:2379`, `:2380`, `:53`, `:10256`. Someone else asks why the Service exposes port 80 but the pod says `containerPort: 8080`, and why the NodePort is some weird number like `31734`. Every one of those numbers is a port, and every one of them is doing the same job: **routing bytes to the right process.** If ports are fuzzy for you, half of Kubernetes networking stays fuzzy — because Services, NodePorts, targetPorts, hostPorts, and `docker -p` are *all* just port bookkeeping.

**What do I already know?**
- An **IP address** identifies a machine (a NIC, really) on a network — `10.0.1.5`, `172.20.0.10`.
- A machine can run many programs at once (nginx, sshd, kubelet, etcd).
- `kubectl`, the AWS console, Security Groups, and "expose port 443" are already daily vocabulary for you.

Hold those. We're about to slot the port concept in right on top of the IP concept — the two together are the address of a *conversation*, not just a *machine*.

---

## 🔥 Rung 1 — The Pain

**The problem that forced ports to exist:** an IP address is not specific enough.

Rewind to a world with IP but no ports. A packet arrives at `10.0.1.5`. The kernel unwraps it and holds a fistful of bytes. Now what? nginx is running. sshd is running. kubelet is running. **Which one gets the bytes?** With only an IP, the machine knows the delivery *building* but not the *room*. There is no way to run two servers on one host without them fighting over every arriving packet. The internet as we know it — a single laptop simultaneously loading a webpage, syncing mail, and holding an SSH session — is simply impossible.

The pre-ports "solution" was brutally limited: **one service per machine, period.** Want a web server and a mail server? Buy two computers. This is the networking equivalent of a skyscraper where the postal address gets you to the front door but there are no room numbers — every letter for every one of the 4,000 employees dumps into a single pile in the lobby, and nobody can tell whose is whose.

**Who feels this pain most today?** You do, constantly, even though ports already solved it — because in Kubernetes the pain reappears one level up:
- A pod has an IP, but that pod might run one container listening on 8080 and a sidecar on 15001. Same IP, different ports.
- A node runs the kubelet, the API server (on control-plane nodes), etcd, CoreDNS, kube-proxy — **all sharing the node's IP.** Only ports keep them separate.
- You want to reach a pod from outside the cluster. The pod IP isn't routable from your laptop. So Kubernetes borrows a **port on the node** (a NodePort) and forwards it inward. Pure port bookkeeping.

Without ports, none of this multiplexing is possible. Every shared-IP scenario — and cloud/K8s is *nothing but* shared-IP scenarios — collapses.

> **Check yourself before Rung 2:** A packet arrives at a node whose IP is `10.0.1.5`, and that node is running both the kubelet and etcd. Using only the fields in an IP header, can the kernel decide which process gets the packet? If not, what *one* additional number would settle it?

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it word for word:

> **An IP address gets you to the machine; a port gets you to the process — and the pair of them, `IP:port`, is a socket: the single named endpoint of one network conversation.**

That's the whole concept. Everything else is derivable:

- **Why 16 bits?** A port is a 16-bit unsigned integer. 16 bits → 2¹⁶ = **65,536** values → ports **0 through 65535**. That's the entire range, no exceptions.
- **Why port *ranges* (well-known / registered / ephemeral)?** Because two roles share the space: **servers** need *predictable, agreed* numbers so clients know where to knock (that's the low, reserved end), and **clients** need *throwaway* numbers just to have a return address (that's the high, dynamic end). Split one 16-bit space by role and the three ranges fall out automatically.
- **Why does one server handle thousands of clients on the *same* port?** Because the kernel identifies a connection not by the server port alone but by the **4-tuple**: `(source IP, source port, dest IP, dest port)`. Change any one field and it's a different conversation. That's **demultiplexing**.
- **Why NodePort, targetPort, containerPort, `-p 8080:80`?** They're all just *mapping one port to another* so that a conversation aimed at one endpoint gets delivered to a process listening on a different one. Once you see "port = which process," every one of those is obvious plumbing.

If you ever get lost below, come back to this sentence and re-derive. The rest of this document is that sentence, unfolded.

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> This section explains how one computer keeps a hundred conversations separate. In everyday terms:
>
> - **The office building.** A computer's internet address is like a building's street address; a "port" is like a room number inside it. The combination — address plus room — is called a "socket," and it points to the exact person (program) you're talking to. The mail truck only needs the street address; the lobby clerk (the computer's operating system) uses the room number to deliver each envelope to the right desk.
>
> - **A port isn't a physical thing.** There's no actual jack or wire labeled "port 80." It's just a number written on each envelope, plus a note in the lobby clerk's ledger saying "mail for room 80 goes to that program over there."
>
> - **Two labels on every envelope.** Each packet carries the street addresses (sender's and receiver's machines) in one layer of the envelope, and the room numbers (sender's and receiver's programs) in an inner layer. Machine first, then program — two questions, one envelope.
>
> - **Mixing and un-mixing.** Everything leaving the computer travels down one shared wire, all conversations mixed together ("multiplexing" — combining streams). Incoming mail gets sorted back out ("demultiplexing") using a four-part label: sender's address, sender's room, receiver's address, receiver's room. If any one of the four differs, it's a different conversation. That's how a single website room (say, room 443) can host thousands of visitors at once — each visitor's own address-and-room combination makes their conversation unique.
>
> - **Three kinds of room numbers.** Low numbers (0–1023) are famous, reserved rooms everyone knows — like "the front desk is always room 22." Middle numbers are registered to well-known applications. High numbers are a scratch pad: when *you* call someone, your computer grabs any free high number as your temporary return address, and throws it away afterward.
>
> - **Rooms can forward to other rooms.** Sometimes the room number on the envelope isn't where the program really sits — a doorman quietly rewrites "room 8080" to "room 80 in the annex" mid-delivery. Docker and Kubernetes do this constantly; the sender never notices.

*Now the original technical deep-dive — the same ideas, in precise form:*

This is the rung to go slow on. Let's open the hood.

### The building analogy, made precise

Think of a machine as an office building:

```
   IP address 10.0.1.5  =  the building's street address
   Port 22 / 80 / 6443  =  a specific room number inside
   Socket 10.0.1.5:6443 =  "the person sitting in that exact room"
```

The mail truck (a router) uses the **street address (IP)** to reach the building. The lobby clerk (the OS kernel) uses the **room number (port)** to deliver the envelope to the right desk. Neither number alone is enough. Together they pinpoint one conversation.

### What a port actually *is* under the hood

A port is **not** a physical thing. There is no wire, no jack, no chip labeled "port 80." A port is a **number written in the transport-layer header** — the TCP header or the UDP header — and a corresponding **entry in a kernel table** that says "process X wants bytes addressed to this number."

When a process calls `listen()` on port 80, the kernel makes a note: *"Any incoming TCP segment whose destination port = 80 belongs to this process."* That note lives in the kernel's socket table. The port "exists" only as that agreement between the kernel and the process.

### Where the port number rides in the packet

Ports live in the **transport layer (Layer 4)**. IP addresses live one layer below, in the **network layer (Layer 3)**. When you nest the headers, the machinery becomes visible:

```
   ┌───────────────────────────────────────────────────────────────┐
   │ Ethernet frame                                                 │
   │  ┌──────────────────────────────────────────────────────────┐ │
   │  │ IP header (Layer 3)                                       │ │
   │  │   Source IP:  10.0.2.30    ← WHICH MACHINE (sender)       │ │
   │  │   Dest IP:    10.0.1.5     ← WHICH MACHINE (receiver)     │ │
   │  │  ┌─────────────────────────────────────────────────────┐ │ │
   │  │  │ TCP header (Layer 4)                                 │ │ │
   │  │  │   Source port: 51000   ← WHICH PROCESS (sender)      │ │ │
   │  │  │   Dest port:   6443    ← WHICH PROCESS (receiver)    │ │ │
   │  │  │   Flags: SYN/ACK/FIN...  Seq/Ack numbers...          │ │ │
   │  │  │  ┌────────────────────────────────────────────────┐ │ │ │
   │  │  │  │ Payload (your kubectl API request bytes)       │ │ │ │
   │  │  │  └────────────────────────────────────────────────┘ │ │ │
   │  │  └─────────────────────────────────────────────────────┘ │ │
   │  └──────────────────────────────────────────────────────────┘ │
   └───────────────────────────────────────────────────────────────┘

   IP layer answers "which machine."   Port (in TCP/UDP) answers "which process."
```

The IP header carries the two **IP addresses**; the TCP (or UDP) header carries the two **port numbers**. The kernel reads Layer 3 to know the packet reached the right host, then reads Layer 4 to know which socket gets it. Two layers, two questions, one packet.

### Multiplexing and demultiplexing — the core mechanism

**Multiplexing (mux):** many independent application streams are combined onto one network link. Your node has *one* NIC and *one* primary IP, yet dozens of conversations flow over it simultaneously. On the way *out*, the kernel stamps each conversation's outgoing packets with the right port numbers and shoves them all down the single wire.

**Demultiplexing (demux):** on the way *in*, a mixed stream of packets arrives on that one wire, and the kernel must sort each packet back to the right socket. It does this with the **4-tuple**:

```
              ONE NODE, ONE NIC (IP 10.0.1.5), MANY CONVERSATIONS
                                      │
   ┌──────────── incoming packet stream (all mixed together) ───────────┐
   │  pkt→ :6443   pkt→ :10250   pkt→ :2379   pkt→ :6443   pkt→ :53      │
   └────────────────────────────────┬───────────────────────────────────┘
                                     │  kernel reads dest port + 4-tuple
             ┌───────────────────────┼───────────────────────┐
             ▼                       ▼                       ▼
      ┌────────────┐          ┌────────────┐          ┌────────────┐
      │ API server │          │  kubelet   │          │   etcd     │
      │  :6443     │          │  :10250    │          │  :2379     │
      └────────────┘          └────────────┘          └────────────┘

   DEMULTIPLEXING = sorting one arriving stream back into the right sockets.
```

The kernel keeps a socket table. Each fully-established TCP connection is keyed by the **4-tuple** `(src IP, src port, dst IP, dst port)`. That's why a single web server listening on port 443 can hold 10,000 simultaneous connections: every client presents a different `(source IP, source port)`, so every connection is a distinct 4-tuple pointing at a distinct socket — even though the *server* side is always `10.0.1.5:443`.

```
   Server socket that is LISTENING:      10.0.1.5 : 443   (one, passive)

   Established connections it holds (all to port 443, all distinct 4-tuples):
     client A  203.0.113.7 : 51000  ──►  10.0.1.5 : 443
     client B  203.0.113.7 : 51001  ──►  10.0.1.5 : 443   (same client, new src port)
     client C  198.51.100.2: 44210  ──►  10.0.1.5 : 443
   The server port never changes; the SOURCE side makes each conversation unique.
```

### The three port ranges — and *why* they're split that way

Because servers need predictable numbers and clients need disposable ones, IANA carves the 16-bit space into three bands:

```
   0 ─────────── 1023 ── 1024 ──────────── 49151 ── 49152 ──────── 65535
   │ WELL-KNOWN       │ REGISTERED               │ EPHEMERAL / DYNAMIC │
   │ (system)         │ (user)                   │ (private)           │
   │ needs privilege  │ assigned to apps         │ handed out by kernel│
   │ 22,80,443,53...  │ 3306,5432,6443,9090...   │ client source ports │
```

- **Well-known: 0–1023.** The famous services. On Linux, binding to these historically requires root (or the `CAP_NET_BIND_SERVICE` capability) — that's why containers often run the app on 8080 and *map* 80 → 8080 rather than binding 80 directly.
- **Registered: 1024–49151.** Assigned to specific applications by IANA but not privileged. This is where MySQL (3306), Postgres (5432), the Kubernetes API server (6443), and Prometheus (9090) live.
- **Ephemeral / dynamic: 49152–65535.** The kernel's scratch pad. When a *client* opens a connection it doesn't care what its own port is — it just needs *a* return address — so the kernel grabs a free one from this range. (Note: Linux's *actual* default ephemeral range is `32768–60999`, tunable via `net.ipv4.ip_local_port_range`; the IANA-blessed range is `49152–65535`. Both are "ephemeral" — the concept is what matters.)

### Ephemeral source ports — the client's return address

When you run `kubectl` (a client), your machine opens a socket *to* `API:6443`. But *your* side needs a port too, so the kernel picks an ephemeral one — say `51000`. That number is how return traffic finds its way back to *your* process. Every outbound connection burns one ephemeral port; that's why a busy proxy can run out of source ports and why connection pooling matters.

### Port mapping — one port stands in for another

Ports don't have to match end to end. A **port mapping** rewrites the destination port mid-flight:

```
   docker run -p 8080:80  nginx        (format is  HOST : CONTAINER)

   client → nodeIP:8080  ──[Docker/iptables DNAT]──►  containerIP:80 (nginx)
                    ▲  host port                              ▲ container port
```

The world talks to `hostIP:8080`; Docker's NAT rules **DNAT** (destination-NAT) it to `containerIP:80` inside. The client never knows a translation happened. Kubernetes does the exact same trick at larger scale with `kube-proxy` rewriting Service ports to pod ports. **Everything the user/app never sees happens right here in the kernel's NAT and socket tables.**

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Port** | A 16-bit number (0–65535) in the TCP/UDP header labeling a process endpoint | Transport layer (L4) header field; kernel socket table key |
| **Socket** | The pair `(IP address, port)` — one endpoint of a conversation | The kernel object a process reads/writes; where app meets network |
| **4-tuple** | `(src IP, src port, dst IP, dst port)` — the key that uniquely names a connection | Demultiplexing: how the kernel sorts arriving packets to sockets |
| **Well-known ports** | 0–1023, privileged, standard services | The reserved low band of the port space |
| **Registered ports** | 1024–49151, assigned to apps, unprivileged | The middle band (3306, 5432, 6443, 9090) |
| **Ephemeral ports** | 49152–65535 (IANA) / 32768–60999 (Linux default), disposable | Client-side source ports; the kernel's scratch pad |
| **Multiplexing** | Combining many app streams onto one link | Outbound: stamping ports so streams share one NIC/IP |
| **Demultiplexing** | Sorting one arriving stream back to the right sockets | Inbound: kernel reads dest port + 4-tuple |
| **Listening socket** | A passive socket waiting for new connections (`LISTEN` state) | Server side; `ss -l` shows these |
| **containerPort** | Informational field: the port the app in a pod listens on | Documents where the process binds inside the pod |
| **targetPort** | The pod port a Service forwards traffic *to* | kube-proxy rewrite destination |
| **Service port** | The port the Service itself is reachable on (the ClusterIP port) | The virtual front door clients hit |
| **nodePort** | A node-level port (30000–32767) forwarding into the cluster | Borrowed host port → Service → pod |
| **hostPort** | Binds a container port directly onto the node's IP | Direct node-level port mapping (skips Service) |
| **Port mapping** | Rewriting dest port in flight (`-p host:container`) | Kernel DNAT / iptables |

**Same kind of thing, different names — don't let these confuse you:**

- **"Port mapping" everywhere:** `docker -p 8080:80`, a Kubernetes `nodePort → targetPort`, and an AWS NLB `listener port → target port` are the *same idea* — DNAT rewriting a destination port. Learn it once.
- **"The process's port":** `containerPort` (K8s), the number after `LISTEN` in `ss`, and "the port the app binds to" all name the same thing — where a server process actually listens.
- **"A disposable client port":** ephemeral port, dynamic port, and "source port" (in the outbound context) are the same throwaway return-address number.
- **Socket vs. endpoint vs. `IP:port`:** all three phrases point at the identical object — the pair that names one side of a conversation.

---

## 🔬 Rung 5 — The Trace

Let's follow **one** concrete action end to end: **you run `kubectl get pods`, which is an HTTPS request to the Kubernetes API server on port 6443.**

Assume: your workstation is `10.0.2.30`, the API server (a load-balanced endpoint or control-plane node) is `10.0.1.5`, listening on `6443`.

```
 STEP 1  kubectl (client process) asks the kernel for an outbound socket.
         Kernel assigns an EPHEMERAL source port, e.g. 51000.
         Your side of the socket is now:   10.0.2.30 : 51000

 STEP 2  kubectl targets the server socket:  10.0.1.5 : 6443
         The kernel now knows the full 4-tuple it will use:
            ( 10.0.2.30 , 51000 , 10.0.1.5 , 6443 )

 STEP 3  Kernel builds the packet. It stamps:
            IP header  → src 10.0.2.30, dst 10.0.1.5      (WHICH MACHINE)
            TCP header → src port 51000, dst port 6443     (WHICH PROCESS)
            TCP flag   → SYN   (opening the 3-way handshake)

 STEP 4  Packet leaves your NIC, crosses the VPC / routers, arrives at 10.0.1.5.
         (Along the way IP TTL decrements at each router hop; ports untouched.)

 STEP 5  API server node's kernel receives the frame. It reads the IP header:
         "dst IP is me, 10.0.1.5. Good." Then reads the TCP header:
         "dst port 6443 — who's LISTENING on 6443?"  →  kube-apiserver.
         This lookup IS demultiplexing.

 STEP 6  Kernel completes the handshake (SYN-ACK back, then your ACK),
         creates an ESTABLISHED socket keyed by the 4-tuple, and hands the
         connection to kube-apiserver. TLS handshake + HTTP request follow.

 STEP 7  Reply travels back. On the return packet the ports SWAP roles:
            src port 6443  →  dst port 51000
         Your kernel demuxes on dst port 51000 and 4-tuple → delivers to kubectl.
```

Visual of the round trip:

```
   kubectl @ 10.0.2.30                              kube-apiserver @ 10.0.1.5
   ephemeral :51000                                       listens :6443
        │                                                       │
        │  IP[10.0.2.30→10.0.1.5]  TCP[51000→6443] SYN          │
        ├──────────────────────────────────────────────────────►
        │                                                       │  demux:
        │                                                       │  "port 6443
        │  IP[10.0.1.5→10.0.2.30]  TCP[6443→51000] SYN,ACK      │   = apiserver"
        ◄──────────────────────────────────────────────────────┤
        │  IP[10.0.2.30→10.0.1.5]  TCP[51000→6443] ACK          │
        ├──────────────────────────────────────────────────────►
        │            ...TLS + HTTPS request/response...         │
        │  IP[10.0.1.5→10.0.2.30]  TCP[6443→51000] ...          │
        ◄──────────────────────────────────────────────────────┤
        │                                                       │
   demux on :51000                                     one listener, many clients
```

Notice the symmetry: the **destination** port on the way out becomes the **source** port on the way back. The pair of ports, plus the pair of IPs, is what keeps *your* `kubectl` reply from landing in someone else's process.

---

## ⚖️ Rung 6 — The Contrast

**What did people do before ports?** As covered in Rung 1: one service per machine. But there's a more instructive contrast — **ports vs. having a separate IP per service.**

You *could* give every service its own IP address and skip ports entirely. Some setups do assign an IP per service (a "VIP per service"). But IPs are scarce, routing them is expensive, and you'd still need L4 addressing to distinguish, say, two conversations to the same service. Ports solve the "many processes, few addresses" problem cheaply — 65,535 conversations per IP, for free, with no extra routing.

| | **Ports (multiplexing on one IP)** | **One IP per service (no ports)** |
|---|---|---|
| Addresses consumed | 1 IP serves 65,535 endpoints | 1 IP per service — burns address space fast |
| Routing cost | None extra — kernel demuxes locally | Every service IP must be routable |
| Two conns to same service | Distinguished by source port (4-tuple) | Still need *something* like ports anyway |
| Human predictability | Standard numbers (22, 80, 443, 6443) | Must publish/lookup each IP |
| How Kubernetes uses it | Node shares 1 IP across apiserver/kubelet/etcd via ports | ClusterIP gives each *Service* an IP, *then still uses ports* |

Note the punchline in the last row: Kubernetes uses **both**. Each Service gets its own virtual ClusterIP (IP-per-service) *and* a port. Ports don't disappear at scale — they compose with per-service IPs.

**When would I NOT need to think about ports?** When you're purely at Layer 3 or below — routing, subnetting, ARP, MAC switching. A router forwarding by IP prefix doesn't read ports at all (a plain L3 router ignores L4). Ports only matter once you're delivering to a *process*. A pure packet-forwarding hop is port-blind.

**Why ports over IP-per-conversation:** because one 16-bit number multiplexes 65,535 conversations onto a single address for free, and the kernel demuxes them with zero routing cost — scarce IP space stays scarce, and the machine stays busy.

> **Check yourself before Rung 7:** A single nginx pod, IP `10.244.3.7`, listens only on port 443 yet serves 5,000 simultaneous browsers. Only one listening socket exists. What makes each of the 5,000 connections a *distinct* entry in the kernel's socket table, given they all target `10.244.3.7:443`?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **out loud before running the command.** The learning is in the gap between what you predicted and what you saw.

### Example 1 — Normal case: list what's actually listening on a host

**Prediction:** *If I run `ss -tlnp`, then I'll see a set of listening sockets each pinned to a port, BECAUSE every server process registered a port with the kernel via `listen()`, and `ss` reads that socket table. On a control-plane-ish node I expect to recognize numbers like 22 (SSH) and, on an API server, 6443.*

```bash
# -t TCP  -l listening only  -n numeric (no DNS/port-name lookup)  -p show process
ss -tlnp
```

```text
# Representative output on a Kubernetes node:
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN  0       4096          127.0.0.1:10248      0.0.0.0:*      users:(("kubelet",...))
LISTEN  0       4096          127.0.0.1:10249      0.0.0.0:*      users:(("kube-proxy",...))
LISTEN  0       128           0.0.0.0:22           0.0.0.0:*      users:(("sshd",...))
LISTEN  0       4096                  *:10250            *:*      users:(("kubelet",...))
LISTEN  0       4096                  *:10256            *:*      users:(("kube-proxy",...))
# On a control-plane node you'd additionally see:
LISTEN  0       4096          127.0.0.1:2379       0.0.0.0:*      users:(("etcd",...))   # client
LISTEN  0       4096          127.0.0.1:2380       0.0.0.0:*      users:(("etcd",...))   # peer
LISTEN  0       4096                  *:6443             *:*      users:(("kube-apiserver",...))
```

**Verify:** Each row is a *listening socket* = an `IP:port` a process claimed. Confirm the port numbers map to the services you expect: `10250` = kubelet, `6443` = API server, `2379`/`2380` = etcd client/peer. A **wrong result** — e.g., nothing on `10250` — would teach you the kubelet isn't running or isn't listening, which is exactly why "check `ss` on the node" is the classic first move when `kubectl exec`/`logs` fail (they route through the kubelet's `10250`).

### Example 2 — Edge/failure case: two processes fighting for one port

**Prediction:** *If I start one listener on port 8080, then try to start a second on the same port, the second WILL FAIL with "Address already in use", BECAUSE a port can be bound by only one listening socket at a time — that exclusivity is the entire mechanism that makes demultiplexing unambiguous.*

```bash
# Terminal 1: claim port 8080
nc -l 8080          # (on some systems: nc -l -p 8080)  — sits and listens

# Terminal 2: try to claim the SAME port
nc -l 8080
# Expected: nc: Address already in use
```

You can watch the state change with `ss`:

```bash
ss -tlnp '( sport = :8080 )'
# LISTEN 0 1 *:8080 *:*  users:(("nc",...))   ← exactly ONE owner
```

**Verify:** The second bind is rejected. This is the kernel enforcing "one listening socket per `(IP, port)`." A **wrong result** — the second listener somehow succeeding — would mean one of them bound a *different* IP (e.g. `127.0.0.1:8080` vs `0.0.0.0:8080` are different sockets), teaching you that a socket is `IP:port`, *not* port alone. This is the same collision you hit when two pods both request the *same* `hostPort` on one node: only one schedules, the other stays `Pending`.

### Example 3 — Kubernetes-flavored: prove Service port ≠ targetPort ≠ nodePort

**Prediction:** *If I expose a pod that listens on `containerPort: 8080` via a NodePort Service with `port: 80` and `targetPort: 8080`, then (a) inside the cluster I reach it at `ClusterIP:80`, (b) from outside I reach it at `NodeIP:<nodePort>` where the nodePort is in 30000–32767, and (c) kube-proxy DNATs both down to the pod's `:8080` — BECAUSE each of those is just a port mapping rewriting the destination port toward the process that's actually listening.*

```yaml
# nginx-on-8080.yaml  — a deployment whose container listens on 8080, plus a NodePort Service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:latest   # listens on 8080, no root needed
          ports:
            - containerPort: 8080     # INFORMATIONAL: where the process listens
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: NodePort
  selector: { app: web }
  ports:
    - port: 80          # Service (ClusterIP) port — the in-cluster front door
      targetPort: 8080  # pod port kube-proxy forwards TO  (must match the listener)
      nodePort: 31734   # node-level port, MUST be in 30000-32767
```

```bash
kubectl apply -f nginx-on-8080.yaml
kubectl get svc web        # note the CLUSTER-IP and the 80:31734/TCP mapping

# (a) In-cluster: hit the Service port 80
kubectl run t --rm -it --image=busybox --restart=Never -- \
  wget -qO- http://web.default.svc.cluster.local:80 | head -1
# → HTTP served by nginx on 8080, reached via Service port 80

# (b) From a node / outside: hit the NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s http://$NODE_IP:31734/ | head -1

# (c) See kube-proxy's DNAT rules that rewrite the port toward the pod
sudo iptables -t nat -L KUBE-SERVICES -n | grep web     # (iptables mode)
```

**Verify:** All three paths return the same nginx page even though the client-facing ports differ (80 vs 31734) and the pod listens on yet another (8080). That is *three distinct ports for one conversation*, each a mapping toward the one process actually listening. A **wrong result** — e.g. `targetPort: 80` giving connection-refused — would teach you targetPort must equal the *listener's* port, not the Service port. And if you tried `nodePort: 8080` the API would reject it (`provided port is not in the valid range 30000-32767`), teaching you the NodePort band is a hard, enforced constraint.

### Example 4 (bonus) — Watch ephemeral source ports appear

**Prediction:** *If I open several connections to the same server and inspect them, then each will share the server's dest port but carry a DIFFERENT ephemeral source port, BECAUSE the source side is what makes each 4-tuple unique.*

```bash
# Open a couple of connections to a public HTTPS server, then look:
( curl -s https://example.com >/dev/null & curl -s https://example.com >/dev/null & )
ss -tnp | grep ':443'
# ESTAB 0 0  10.0.2.30:51002  93.184.216.34:443  users:(("curl",...))
# ESTAB 0 0  10.0.2.30:51005  93.184.216.34:443  users:(("curl",...))
#                       ^^^^^ different source ports; dest port 443 identical
```

**Verify:** Same `dst :443`, different `src` ports → different 4-tuples → the exact mechanism that lets one server hold thousands of clients. A **wrong result** (identical source ports) is impossible for concurrent live connections precisely because the kernel guarantees ephemeral-port uniqueness per 4-tuple.

---

## 🏔️ Capstone — Compress It

**One-sentence summary:**
An IP address names the machine and a 16-bit port names the process, so the pair `IP:port` (a socket) uniquely identifies one endpoint of one conversation — which is what lets a single host multiplex thousands of streams and demux each arriving packet back to the right process by its 4-tuple.

**Explain it to a beginner (3 sentences):**
Your computer has one address, but it runs many programs at once, so it needs a way to say "this data is for the web server, that data is for SSH." Ports are those little numbers — 80 for web, 22 for SSH, 6443 for the Kubernetes API — that ride alongside the IP address to point at the right program. Because every conversation is tagged with both machine addresses and both port numbers, the computer never mixes up who gets what, even with a thousand chats happening on one wire.

**Sub-parts mapped to the one core idea** ("IP = machine, port = process, socket = the pair"):
- *16-bit range 0–65535* → how many process-endpoints one machine can name.
- *Well-known / registered / ephemeral bands* → servers get predictable ports, clients get disposable ones.
- *Multiplexing / demultiplexing* → the pair + 4-tuple is what makes sorting unambiguous.
- *Ephemeral source ports* → the client's temporary half of the socket pair.
- *containerPort / targetPort / Service port / nodePort / hostPort / `-p host:container`* → all just port *mappings*, rewriting the destination toward the process that's actually listening.

**Which rung to revisit hands-on:**
Go back to **Rung 7, Example 3** on a real (or `kind`/`minikube`) cluster. Wiring up containerPort ≠ targetPort ≠ Service port ≠ nodePort with your own hands, and breaking it on purpose (mismatch targetPort, request an out-of-range nodePort), cements the whole concept faster than re-reading anything. If the *why* of demux still feels abstract, sit with **Rung 3's** 4-tuple diagram and **Rung 5's** trace until "the source port makes it unique" is reflexive.

---

## Related concepts

- [IP addressing](02-ip-addressing.md) — the "which machine" half that ports sit on top of.
- [Subnetting and CIDR](03-subnetting-and-cidr.md) — how those machine addresses are carved up in a VPC.
- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the layer that actually carries port numbers, plus the SYN/ACK/FIN handshake.
- [NAT and PAT](14-nat-and-pat.md) — port *mapping* generalized; how `-p 8080:80` and kube-proxy rewrite ports.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — ClusterIP/NodePort/LoadBalancer and the DNAT that maps Service ports to pod ports.
- [Container & Docker networking](23-container-docker-networking.md) — bridge networks and `-p host:container` port forwarding in depth.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A packet arrives at a node whose IP is `10.0.1.5`, running both the kubelet and etcd. Using only the fields in an IP header, can the kernel decide which process gets the packet? If not, what *one* additional number would settle it?

**A:** No. The IP header only carries the two IP addresses — it answers "which machine?" (the destination IP `10.0.1.5` confirms the packet reached the right host) but says nothing about "which process?". With IP alone the kernel knows the delivery *building* but not the *room*: the kubelet and etcd share the node's one IP, so there is no way to pick between them. The one additional number that settles it is the **destination port**, which rides one layer up in the TCP/UDP (Layer 4) header — e.g. `10250` means the kubelet gets the bytes, `2379` means etcd does. The kernel matches that port against its socket table of listening processes; that lookup is demultiplexing.

### Before Rung 7
**Q:** A single nginx pod at `10.244.3.7` listens only on port 443 yet serves 5,000 simultaneous browsers, with only one listening socket. What makes each of the 5,000 connections a *distinct* entry in the kernel's socket table, given they all target `10.244.3.7:443`?

**A:** The **4-tuple**: `(source IP, source port, destination IP, destination port)`. The kernel keys each established connection by all four fields, not by the server port alone. Every browser presents a different source side — a different client IP, and/or a different ephemeral source port handed out by the client's kernel — so all 5,000 connections have distinct 4-tuples even though the destination half is identically `10.244.3.7:443`. Change any one field and it's a different conversation, so each 4-tuple points at its own established socket in the table. The single LISTEN socket is just the passive front door that accepts new connections; the source side is what makes each conversation unique.
