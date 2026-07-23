# Linux Networking — Interfaces, Sockets & DNS, Climbed the Ladder 🪜
### Learning how packets, ports, and names actually work — deriving *why `nslookup kubernetes.default` resolves and `curl 6443/healthz` answers*, not memorizing `ip` flags

> This is Linux networking rebuilt on the Learning Ladder framework. Instead of leading with `ip addr` and `ss -tlnp`, we climb from **why the network stack exists** → **the one core idea** → **the machinery (interfaces → routes → sockets → names)** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every `ip`, `ss`, `curl`, `nc`, `dig` command lives at the TOP of the ladder (Rung 7). You'll understand *what each one is inspecting or exercising in the kernel* before you run it — and why a pod's `eth0` is really a `veth` peer, and why `nameserver 10.96.0.10` is how a pod finds `kubernetes`.

---

# RUNG 0 — The Setup

**What am I learning?**
Linux networking from the wire up: **interfaces** (the NICs, real and virtual), **IP addresses and the routing table** (how the kernel decides where a packet goes), **sockets and listening ports** (how a process claims `:6443` and how you see who's listening), **connectivity testing** (`curl`, `nc`), and **name resolution** (how `kubernetes.default.svc.cluster.local` becomes `10.96.0.1`). The tools: `ip`, `ss`, `curl`, `nc`, `nslookup`, `dig`, and the config files `/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`.

**Why did it land on my desk?**
A pod is stuck in `CrashLoopBackOff` and its logs say `dial tcp: lookup my-svc.prod.svc.cluster.local: no such host`. Another node shows `NotReady`; `kubectl` says the kubelet can't reach the API server. You `ssh` onto the node and now you're staring at a shell, not a `kubectl` prompt. Your lead says: "Confirm the apiserver is even listening, confirm the node can route to the service network, and figure out why DNS is broken — from the node, with Linux tools." Every one of those is a networking question, and `kubectl` can't answer them because `kubectl` *is* the thing that's broken.

**What do I already know about it?**
You know pods have IPs, Services have ClusterIPs, and there's "a CNI" and "CoreDNS." You've typed `curl` at a Service and seen it work. You've seen `10.96.0.1` and `10.244.x.x` addresses. What you don't yet have is the mental model of *how a packet actually leaves a pod, crosses the node, and comes back* — and *how a name turns into one of those addresses* — using the same primitives on any Linux box.

---

# RUNG 1 — The Pain 🔥
### *Why does the whole interfaces/routes/sockets/DNS stack exist at all?*

Before any command, sit with the problems this machinery solves. There are really four distinct pains stacked on top of each other, and each layer of the network stack exists to kill one of them.

### Pain 1 — "Which wire?" (interfaces)
A machine can have many ways out: a physical NIC, a WiFi card, a VPN tunnel, a loopback to itself, and — on a Kubernetes node — *hundreds* of virtual cables to pods. Without a concept of a named **interface**, the kernel would have no way to say "send this out *that* one." Interfaces exist so the kernel can hold many network attachments at once and address each independently.

### Pain 2 — "Which direction?" (the routing table)
You have a packet for `10.96.0.1`. Which interface does it leave by? Does it go to a gateway or is it local? Without a **routing table**, every program would have to know the physical topology of the network. Before routing tables were a first-class kernel structure, this was hardcoded chaos. The routing table exists so that *destination IP alone* decides the exit — one lookup, no application knowledge required.

### Pain 3 — "Which program?" (sockets and ports)
A single IP arrives at the machine, but twenty programs are running. Which one gets the packet? The answer is the **port** — a 16-bit number that multiplexes one IP among many processes — and the **socket**, the kernel object a process opens to claim a port. Without ports, only one network program could run per machine. Ports are why `etcd` (2379), the `kubelet` (10250), and the `apiserver` (6443) can all live on the same node's IP and never collide.

### Pain 4 — "What's its address?" (DNS)
Humans and config files want to say `kubernetes.default.svc.cluster.local`, not `10.96.0.1`. And that address *changes* — pods die, Services get recreated, the backend moves. Hardcoding IPs is a maintenance nightmare and, in Kubernetes, simply impossible because addresses are assigned dynamically. **DNS** (and its local cousins `/etc/hosts` and `nsswitch`) exists to turn a stable *name* into a current *address*, so nothing has to know the number in advance.

### What people did before, and why it hurt
- Before the `ip` command there was `ifconfig` + `route` + `arp` + `netstat` — a bag of separate, inconsistent tools from the old `net-tools` package. They couldn't express modern kernel features (multiple IPs per interface, policy routing, namespaces) and are now deprecated. On a minimal container or a modern distro they may not even be installed.
- Before DNS, every machine shipped a giant `/etc/hosts` file listing *every* host on the network, copied around by hand (this is literally why `/etc/hosts` still exists — it's the fossil of pre-DNS naming).

### Who feels this pain most?
**You, the platform engineer on a broken node.** When the cluster is healthy, CNI and CoreDNS hide all of this. The moment something breaks below `kubectl`, you're dropped onto a raw Linux host and every troubleshooting step is: *check the interface, check the route, check the listening socket, check DNS.* That is the entire node-triage loop, and it's built from exactly these four primitives.

> **✅ Check yourself before Rung 2:** A pod can't reach a Service. Name the four independent things that must ALL be working for that call to succeed — and notice each maps to one pain above. (Interface up? Route exists? A socket is listening on the other end? The name resolved?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — the rest of Linux networking can be *derived* from it:

> **A packet is delivered by answering four questions in order — which interface, which route, which socket, and (first of all) what address does this name map to — and every networking tool just inspects or exercises one of those four answers.**

That's the whole stack. `ip addr`/`ip link` = interfaces. `ip route` = routes. `ss` = sockets. `resolv.conf`/`dig` = names. `curl` and `nc` = "run all four for real and see if a byte gets through."

### Why this sentence lets you derive the rest

- *"what address does this name map to"* → **DNS resolution chain**: `/etc/nsswitch.conf` decides the order, `/etc/hosts` is checked, then `/etc/resolv.conf` points at a DNS server. In a pod that server is CoreDNS at `10.96.0.10`.
- *"which interface"* → **`ip addr` / `ip link`**. A pod's `eth0` is not hardware — it's one end of a **veth pair**, a virtual patch cable whose other end lives on the node.
- *"which route"* → **`ip route`**. `default via <gateway>` is the catch-all; `10.244.0.0/16 dev flannel.1` is the CNI's rule for reaching every pod in the cluster.
- *"which socket"* → **`ss`**. A process must `bind()` and `listen()` on a port for anything to answer. `ss -tlnp` shows you `6443` (apiserver), `10250` (kubelet), `2379/2380` (etcd) — proof the control plane is actually up.

Every capability in your lead's list is just "inspect one of the four answers, or run all four end-to-end." The tools stop being a random pile and become one pipeline seen four ways.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then: in what ORDER do the four questions get answered when your pod runs `curl http://my-svc`? Which one happens *before* a single packet is even built?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Imagine your computer is an office building sending and receiving mail. This section explains five things about how that mail actually moves.
>
> - **(A) The doors (interfaces).** Every way in or out of the building is a named "door." Surprisingly, most doors aren't real — the computer can invent pretend ones. One special door, "loopback," is for mail the building sends to itself: it never goes outside. Another kind, a **veth pair** (a virtual patch cable), is like a private pneumatic tube with two ends: drop a letter in one end and it instantly pops out the other. One end sits inside a small sealed room (a pod — a little app's private workspace), the other end sits in the main building, plugged into a **bridge** (a shared mail-sorting rack that connects all the little rooms on that floor).
>
> - **(B) The routing table (the delivery rulebook).** For every outgoing letter, the mailroom checks a rulebook: "addresses in THIS neighborhood go out door 1; THAT neighborhood, door 2; anything else, hand it to the main post office" (the **default gateway** — the router of last resort). The most *specific* matching rule always wins.
>
> - **(C) Sockets and ports (numbered reception desks).** Inside the building, many workers share one street address. Each worker who wants to receive mail opens a numbered desk (a **port**) and announces "I'm listening at desk 6443." The desk itself is a **socket** (the kernel's record of who's receiving what). Desks have statuses: waiting for visitors, in an active conversation, or recently closed. When a worker mails *out*, they're temporarily assigned a random return-desk number.
>
> - **(D) The name lookup (the phone book step).** You can't mail a letter to "Bob" — you need a street address. Before anything is sent, the computer looks names up: first a note taped to the wall listing the lookup *order*, then a personal address book of fixed entries, then a phone-book service (DNS) whose number and "try adding these surnames to short names" hints live in a third note.
>
> - **(E) Putting it together in Kubernetes.** Each pod is a sealed room with its own doors, its own rulebook, and its own phone-book notes — pre-installed by the cluster. One quiet helper (the "pause" container) just holds the room open so roommates share everything.

*Now the original technical deep-dive — the same ideas, in precise form:*

We open the hood on all four answers. There are five things to understand: **(A) interfaces and what a veth pair really is, (B) the routing table decision, (C) sockets, ports, and connection state, (D) the DNS resolution chain, and (E) how these fuse inside a Kubernetes pod.**

## (A) Interfaces: named attachments, most of them virtual

An **interface** is a kernel object representing one network attachment. It has a name (`eth0`, `lo`, `flannel.1`), a MAC address, a state (UP/DOWN), and zero or more IP addresses. Crucially, **most interfaces on a node are not hardware.** The kernel can create virtual interfaces on demand. The two that matter for Kubernetes:

- **`lo`** — loopback. `127.0.0.1`. Traffic to yourself never leaves the machine. This is why `curl https://localhost:6443` reaches the local apiserver.
- **`veth` pair** — a *virtual Ethernet cable*: two interfaces created together where a packet pushed into one instantly appears out the other. One end lives inside the pod (named `eth0` *there*), the other end (named `vethXXXX`) lives on the node and is plugged into a bridge or handled by the CNI.

```
A veth PAIR is one virtual cable with two ends
─────────────────────────────────────────────

   POD network namespace              NODE (root) network namespace
  ┌──────────────────────┐          ┌───────────────────────────────┐
  │                      │          │                               │
  │   app process        │          │   vethB6f2  ◄── the other end │
  │        │             │          │        │                      │
  │      eth0 ◄──────────┼── cable ──┼────────┘                      │
  │   10.244.1.7         │          │        │ plugged into...       │
  │                      │          │   cni0 / flannel.1 bridge      │
  └──────────────────────┘          └───────────────────────────────┘

  A packet the app sends out eth0 pops out vethB6f2 on the node,
  where the node's routing table takes over. The pod thinks eth0
  is a normal NIC. It is actually one end of a patch cable.
```

A **bridge** (e.g. `cni0`) is a virtual switch: it connects many veth node-ends together so all the pods on one node can talk to each other as if plugged into the same physical switch.

## (B) The routing table: destination IP → exit decision

When the kernel has a packet, it does a **longest-prefix-match** lookup in the routing table: it finds the most *specific* route whose subnet contains the destination, and uses that route's interface and (optionally) gateway.

```
ROUTING DECISION for a packet to 10.96.0.1
──────────────────────────────────────────

Routing table (most specific wins):
  10.244.0.0/16  dev flannel.1        ← pod CIDR (CNI added this)
  10.244.1.0/24  dev cni0             ← this node's pods
  192.168.0.0/24 dev eth0             ← the real LAN
  default        via 192.168.0.1 dev eth0   ← everything else

Destination 10.96.0.1 (a ClusterIP):
  • matches none of the specific routes...
  • falls through to `default` → send to gateway 192.168.0.1 via eth0
  • BUT FIRST: iptables/IPVS (kube-proxy) rewrites 10.96.0.1 → a real pod IP
    (that's covered in 12-iptables-netfilter.md — routing and NAT cooperate)
```

`default via X` is the **default gateway** — the router of last resort for any destination you have no specific route for. `10.244.0.0/16 dev flannel.1` is the CNI teaching the kernel "to reach ANY pod anywhere in the cluster, send it out the flannel VXLAN device." Without that route, cross-node pod traffic has nowhere to go.

## (C) Sockets, ports, and connection state

A **socket** is the kernel object a process opens to do networking; a **port** is the 16-bit number that identifies which socket incoming traffic belongs to. A server calls `bind()` to claim a port, then `listen()` — now it's a **listening socket** (state `LISTEN`). A client's `connect()` and the resulting data flow create an **established socket** (state `ESTAB`).

```
THE SOCKET / PORT MULTIPLEXER on one node's IP
──────────────────────────────────────────────

              node IP 192.168.0.10
                     │
        ┌────────────┼───────────────┬──────────────┐
     :6443        :10250          :2379          :2380
   ┌────────┐   ┌────────┐      ┌────────┐    ┌────────┐
   │apiserver│  │kubelet │      │ etcd   │    │ etcd   │
   │ LISTEN  │  │ LISTEN │      │ client │    │ peer   │
   └────────┘   └────────┘      └────────┘    └────────┘

  One IP, four programs, four ports. The port is how the kernel
  knows which socket — and therefore which process — gets the packet.
```

**Ephemeral ports:** when a *client* connects out, the kernel hands it a temporary source port from the ephemeral range (Linux default `32768–60999`, see `sysctl net.ipv4.ip_local_port_range`). That's why an outbound connection shows a high random port on your side and the well-known port (443, 6443…) on the server side.

**Connection states** you'll see in `ss`: `LISTEN` (waiting for clients), `ESTAB` (active connection), `TIME-WAIT` (recently closed, kernel holding the port briefly to catch stray packets), `SYN-SENT`/`SYN-RECV` (handshake in progress). A pile of `TIME-WAIT` is usually normal; a pile of `SYN-SENT` means "I'm trying to connect and getting no answer" — a firewall or dead listener.

## (D) The DNS resolution chain: name → address

This happens *before* any of A/B/C — you can't route to a name, only to an address. When a program (or `curl`) needs to resolve `kubernetes.default.svc.cluster.local`, the C library's resolver runs this chain:

```
NAME RESOLUTION ORDER (driven by /etc/nsswitch.conf)
────────────────────────────────────────────────────

/etc/nsswitch.conf says:   hosts: files dns
                                    │     │
                    ┌───────────────┘     └──────────────┐
                    ▼                                     ▼
            1. FILES = /etc/hosts               2. DNS = ask a nameserver
               static name→IP table                from /etc/resolv.conf:
               (checked FIRST — an entry            nameserver 10.96.0.10
                here SHORT-CIRCUITS DNS)            search default.svc.cluster.local
                                                           svc.cluster.local
                                                           cluster.local

   For a SHORT name like "kubernetes", the `search` domains are
   appended in turn:  kubernetes.default.svc.cluster.local → try
   → svc.cluster.local → cluster.local, until one resolves.
```

Three files, three jobs:
- **`/etc/nsswitch.conf`** — the *order* of sources for the `hosts` database (`files dns` = check `/etc/hosts` first, then DNS). This is the master switch; people forget it exists and can't understand why `/etc/hosts` wins.
- **`/etc/hosts`** — a static name→IP table, checked first. Always has `127.0.0.1 localhost`.
- **`/etc/resolv.conf`** — *which DNS server to ask* (`nameserver`) and *what domains to append to short names* (`search`), plus options like `ndots`.

## (E) All four, fused inside a Kubernetes pod

Now stack it. A pod gets its **own network namespace** (see `13-namespaces.md`) — its own interfaces, routing table, and socket table, isolated from the node. The CNI (flannel/calico) wires it up:

```
WHAT KUBERNETES BUILDS FOR ONE POD
───────────────────────────────────

Pod's OWN net namespace:
  • eth0        = 10.244.1.7   (the pod-end of a veth pair)
  • lo          = 127.0.0.1
  • ip route:   default via 10.244.1.1 dev eth0   ← to the node's bridge
  • /etc/resolv.conf (injected by the kubelet):
        nameserver 10.96.0.10                      ← CoreDNS ClusterIP
        search my-ns.svc.cluster.local svc.cluster.local cluster.local
        options ndots:5

Node (root) namespace:
  • vethXXXX    = pod-end's partner, plugged into cni0
  • flannel.1   = holds route 10.244.0.0/16 for cross-node pods
  • kube-proxy's iptables turns 10.96.0.10 (a ClusterIP) into a real
    CoreDNS pod IP before the packet leaves (see 12-iptables-netfilter.md)
```

So when the pod does `curl http://my-svc`: (D) resolver appends `search` domains and asks CoreDNS at `10.96.0.10` → gets a ClusterIP; (A) picks `eth0`; (B) `ip route` sends it to `default via 10.244.1.1`; the packet exits the veth cable onto the node, kube-proxy NATs the ClusterIP to a backend pod IP, and (C) that pod's listening socket answers. **Four questions, one call.** The `pause` container is what actually *holds* this namespace open so all containers in the pod share the same `eth0` and resolv.conf.

> **✅ Check yourself before Rung 4:** Draw the pod-and-node picture from memory. Specifically: (1) what is the pod's `eth0` *really*, and where is its other end? (2) which file tells the pod to ask `10.96.0.10` for names? (3) which route lets the packet leave the pod at all?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Interface (NIC)** | A named network attachment (`eth0`, `lo`, `flannel.1`) | (A) — the "which wire" |
| **`lo` / loopback** | Virtual interface for talking to yourself (127.0.0.1) | (A) — why `localhost:6443` works |
| **veth pair** | A two-ended virtual cable; packet in one end, out the other | (A) — a pod's `eth0` is one end |
| **Bridge (`cni0`)** | A virtual switch joining many veth ends on a node | (A) — pod-to-pod on one node |
| **MAC address** | Layer-2 hardware address of an interface | (A) — link-layer delivery |
| **Routing table** | Kernel's destination-IP → exit-interface map | (B) — the "which direction" |
| **Default gateway** | `default via X` — router for unknown destinations | (B) — catch-all route |
| **Pod CIDR** | `10.244.0.0/16` route added by the CNI | (B) — reach any cluster pod |
| **Socket** | Kernel object a process opens for networking | (C) — the "which program" |
| **Port** | 16-bit number multiplexing one IP across processes | (C) — 6443, 10250, 2379 |
| **Listening socket** | A `bind()`+`listen()` socket in state `LISTEN` | (C) — a server that's up |
| **Ephemeral port** | Temporary high source port for outbound connections | (C) — client side of a connection |
| **Connection state** | `LISTEN`/`ESTAB`/`TIME-WAIT`/`SYN-SENT`… | (C) — the socket's lifecycle |
| **ClusterIP** | A virtual Service IP (e.g. `10.96.0.1`) NAT'd to pods | (B)+(C) — resolved then routed |
| **DNS resolver** | The C-library code that turns names into addresses | (D) — runs before A/B/C |
| **`/etc/nsswitch.conf`** | Sets the ORDER of name sources (`files dns`) | (D) — the master switch |
| **`/etc/hosts`** | Static name→IP table, checked before DNS | (D) — `files` source |
| **`/etc/resolv.conf`** | `nameserver` + `search` domains for DNS | (D) — the `dns` source config |
| **`search` domain** | Suffixes appended to short names | (D) — `kubernetes` → `.svc.cluster.local` |
| **`ndots`** | How many dots before a name is tried "as-is" first | (D) — why pod DNS makes extra queries |
| **CoreDNS** | The cluster's DNS server, ClusterIP `10.96.0.10` | (D)+(E) — the pod's `nameserver` |

### The big unlock: which terms are the *same kind of thing*

```
GROUP 1 — "Answer 1: the name → address step" (all DNS):
   resolver = /etc/nsswitch.conf + /etc/hosts + /etc/resolv.conf + CoreDNS
   → dig / nslookup are just "run this group manually and show me the answer"

GROUP 2 — "Answer 2: which interface" (all the same physical question):
   interface = NIC = eth0 = lo = veth end = flannel.1
   → ip addr / ip link / ifconfig all just LIST these

GROUP 3 — "Answer 3: which direction" (all routing):
   route = routing table entry = default gateway = pod-CIDR route
   → ip route / route (legacy) just PRINT this table

GROUP 4 — "Answer 4: which program" (all sockets/ports):
   socket = port = listener = connection
   → ss / netstat just DUMP the kernel's socket table

GROUP 5 — "Run all four for real":
   curl (does DNS + route + socket + full HTTP) and
   nc (does DNS + route + socket, no HTTP) are END-TO-END testers.
```

Notice **`ip a` and `ifconfig` are the same job, different generation**; so are **`ss` and `netstat`**, and **`dig`/`nslookup`** for DNS. Learn the modern one (`ip`, `ss`, `dig`), recognize the legacy one for old boxes.

> **✅ Check yourself before Rung 5:** Without looking — which tool inspects Group 3 and which inspects Group 4, and which *single* connection failure symptom (`SYN-SENT` piling up) tells you Group 4 is the problem, not Group 1?

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Let's trace the exact thing your broken node needs: **from inside a pod, `curl -k https://kubernetes.default/healthz`** — reaching the API server through its Service name. (The `kubernetes` Service listens on `443`, TLS-only, so it must be `https://` — plain `http://` against `:443` gets a TLS error, not `ok`; `-k` skips cert verification.) This touches all four answers.

```
THE TRACE: pod runs `curl -k https://kubernetes.default/healthz`
```

**Step 1 — The resolver reads `/etc/nsswitch.conf`.** It sees `hosts: files dns`: check `/etc/hosts` first, then DNS. `kubernetes.default` isn't in `/etc/hosts`, so fall through to DNS.

**Step 2 — Apply `search` domains (the `ndots:5` rule).** The name `kubernetes.default` has one dot, which is fewer than `ndots:5`, so the resolver tries the `search` suffixes *first*: `kubernetes.default.default.svc.cluster.local` (fails), `kubernetes.default.svc.cluster.local` (this one exists). This is why pod DNS often fires several queries before it hits.

**Step 3 — Ask the nameserver in `/etc/resolv.conf`.** That file says `nameserver 10.96.0.10`. The resolver builds a UDP DNS query to `10.96.0.10:53` asking for the A record of `kubernetes.default.svc.cluster.local`.

**Step 4 — But 10.96.0.10 needs routing too (answers A+B for the DNS packet).** The pod's `ip route` says `default via 10.244.1.1 dev eth0`. The query leaves the pod's `eth0` (one end of the veth), pops out the node-side `vethXXXX`, and kube-proxy's iptables rewrites ClusterIP `10.96.0.10` to a real **CoreDNS pod** IP.

**Step 5 — CoreDNS answers.** CoreDNS (a listening socket on `:53` in its own pod) looks up the Service, replies `10.96.0.1` (the apiserver's ClusterIP). The answer travels back to the pod's resolver. **DNS is now done — we have an address.**

**Step 6 — Now curl opens a socket to 10.96.0.1:443 (answers B+C).** The kernel picks a source **ephemeral port** (say `54012`), builds a TCP `SYN` to `10.96.0.1:443`, routes it out `eth0` again. kube-proxy NATs `10.96.0.1:443` → a real apiserver endpoint (the node's IP `:6443`).

**Step 7 — The apiserver's listening socket accepts.** On the destination, the apiserver has been sitting in `LISTEN` on `:6443`. The `SYN` arrives, the three-way handshake completes (`SYN → SYN-ACK → ACK`), the connection goes `ESTAB` on both sides.

**Step 8 — TLS handshake, then HTTP `/healthz` flows and returns `ok`.** Over the `ESTAB` TCP connection, curl and the apiserver complete a TLS handshake (`-k` means curl doesn't verify the server cert), then curl sends `GET /healthz`, the apiserver replies `200 ok`, the connection closes (briefly entering `TIME-WAIT` on the client), curl prints `ok`.

```
VISUAL OF THE TRACE
───────────────────

  curl -k "https://kubernetes.default/healthz"
      │
      │ (1)(2) nsswitch: files→dns; ndots:5 appends search domains
      ▼
  resolv.conf → ask 10.96.0.10:53  ─┐  (3) DNS query
      │                             │
      │ (4) routes out eth0 (veth)  │  kube-proxy NAT → CoreDNS pod
      ▼                             ▼
  CoreDNS answers: "10.96.0.1"  ◄───┘  (5) address in hand
      │
      │ (6) socket() → SYN to 10.96.0.1:443, src port 54012 (ephemeral)
      ▼        kube-proxy NAT → apiserver node:6443
  apiserver LISTEN :6443 ──(7)──► handshake → ESTAB
      │
      │ (8) TLS handshake, then GET /healthz  →  200 "ok"
      ▼
  curl prints: ok
```

If *any* rung fails you get a distinct error: Step 3/5 failing → `no such host` (DNS). Step 6/7 failing → `connection refused` (nothing listening / handshake rejected) or a hang then timeout (`SYN-SENT`, firewall dropping). That mapping *is* the triage skill.

> **✅ Check yourself before Rung 6:** At which step does the error message change from `no such host` to `connection refused`? Explain why those two errors point at completely different Groups from Rung 4.

---

# RUNG 6 — The Contrast ⚖️
### *The older tools, and where each belongs*

You understand the modern stack best by seeing what it replaced. The legacy `net-tools` package (`ifconfig`, `route`, `netstat`, `arp`) predates the current `iproute2` suite (`ip`, `ss`).

### The command-generation map

| Job (Rung 4 group) | Legacy (`net-tools`) | Modern (`iproute2`) | Why modern won |
|---|---|---|---|
| Show interfaces & IPs | `ifconfig` | `ip addr` / `ip link` | `ip` shows *multiple* IPs per interface, namespaces, and up/down state cleanly |
| Show/edit routes | `route -n` | `ip route` | `ip` supports policy routing, multiple tables, the features CNIs need |
| Show sockets/ports | `netstat -tlnp` | `ss -tlnp` | `ss` reads kernel netlink directly — *much* faster on a busy node with 100k sockets |
| Show ARP/neighbors | `arp -n` | `ip neigh` | Unified under one tool |

```
WHY ss BEATS netstat ON A KUBERNETES NODE
──────────────────────────────────────────

netstat: parses /proc/net/tcp line by line in userspace.
         On a node with 80,000 sockets this is SLOW and can
         even miss sockets as the table changes under it.

ss:      queries the kernel's socket table via a netlink
         socket — the kernel does the filtering. Fast, complete,
         and it can filter by state kernel-side (ss state ESTAB).
```

### What each can (and can't) do
- `ifconfig` **cannot** show a second IP on an interface, nor list network namespaces — it structurally predates both. On many pods/nodes it isn't even installed.
- `ss` **can** filter by connection state kernel-side (`ss -t state established`) and by port; `netstat` can only grep the text afterward.
- The legacy tools **can** still be useful: they're sometimes the only thing on an ancient host, and their output is muscle-memory for many engineers.

### When would I NOT reach for these?
- Inside a healthy cluster, you'd use `kubectl get endpoints`, Service DNS, and CNI dashboards — the node-level tools are for when *those* are broken or absent.
- Don't use `ping` to test a *Service* — ClusterIPs often don't answer ICMP (they're NAT rules, not hosts); use `nc -zv` or `curl` against the actual port instead. This trips up nearly everyone.

**One-sentence "why this over that":**
> Reach for `ip`/`ss`/`dig` by default (faster, namespace-aware, feature-complete for the CNI world); fall back to `ifconfig`/`netstat`/`nslookup` only on a stripped-down or legacy box where the modern tools aren't installed.

> **✅ Check yourself before Rung 7:** Explain to a colleague why `ping 10.96.0.1` can *fail* on a perfectly healthy cluster while `curl 10.96.0.1:443` *succeeds* — what is a ClusterIP really, and does it have anything to "ping"?

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each is a **hypothesis you commit to first**, then verify. Read the prediction, cover the outcome, decide if you agree, *then* run it. Commands are correct on a modern Linux (Ubuntu 22.04, systemd, `iproute2`); distro/legacy notes are called out.

---

## Prediction 1 — Interfaces and routes reveal the node's shape (normal case)

> **My prediction:** "If I list interfaces and the routing table on a Kubernetes node, then I'll see `lo`, a real NIC (`eth0`/`ens5`), CNI virtual devices (`cni0`, `flannel.1`, and `veth*` pairs), a `default via` gateway route, and a `10.244.0.0/16` route pointing at the CNI device — *because* the CNI added the pod-CIDR route and one veth per local pod."

```bash
# Interfaces + their IPs (modern; `ip a` is the short alias):
ip addr show
ip a                     # same thing, shorthand

# Just the link layer + find the pod veth ends:
ip link
ip link | grep veth      # one veth* per local pod (its node-side end)

# The routing table:
ip route
# default via 192.168.0.1 dev eth0        ← the default gateway
# 10.244.0.0/16 dev flannel.1             ← reach ANY pod in the cluster
# 10.244.1.0/24 dev cni0                  ← this node's pods
```

**Verify:** You should see the `default via` line (no gateway = node can't reach the outside) and the `10.244.0.0/16` line (missing = cross-node pod traffic is dead). If `ip` is "command not found", you're on a minimal box: `apt-get install -y iproute2`, or fall back to legacy `ifconfig -a` and `route -n`. If `grep veth` returns nothing on a node that has pods, the CNI didn't wire them — a real red flag.

---

## Prediction 2 — `ss` proves the control plane is listening (Kubernetes case)

> **My prediction:** "If I dump listening TCP sockets on a control-plane node, then I'll see `:6443` (kube-apiserver), `:10250` (kubelet), and `:2379`/`:2380` (etcd client/peer) in state `LISTEN` — *because* each of those processes called `bind()`+`listen()` on its port at startup, and that's the direct proof they're up regardless of what `kubectl` says."

```bash
# -t TCP, -l listening, -n numeric (no DNS lookups), -p show process:
ss -tlnp
# LISTEN 0 4096 *:6443  *:*  users:(("kube-apiserver",pid=...))
# LISTEN 0 4096 *:10250 *:*  users:(("kubelet",pid=...))
# LISTEN 0 4096 127.0.0.1:2379 ...  users:(("etcd",pid=...))

# Zoom in on the apiserver port:
ss -tlnp | grep 6443

# Established connections (who is talking to whom right now):
ss -tnp
# ESTAB 0 0 10.0.0.5:6443 10.0.0.9:41888 ...   ← a kubelet talking to apiserver

# UDP listeners (e.g. DNS on :53) — -u UDP, -n numeric, -l listen, -p process:
ss -unlp | grep :53
```

**Verify:** `LISTEN` on 6443/10250/2379 = control plane processes are alive and bound. If `ss -tlnp | grep 6443` is **empty**, the apiserver isn't listening at all (crashed / not started) — that's your root cause, and no amount of `kubectl` debugging would show it. Legacy fallback: `netstat -tlnp` (same flags, slower). Note: `-p` requires root to see process names for other users' sockets.

---

## Prediction 3 — `curl` and `nc` distinguish "listening" from "reachable" (connectivity)

> **My prediction:** "If I `curl -k https://localhost:6443/healthz`, then I get `ok` because the local apiserver's socket answers over loopback; and if I `nc -zv` the Service network, then a listening port reports `succeeded` while a dead one hangs then fails — *because* `nc -z` does the TCP handshake only (no data) and `curl` runs the full DNS+route+socket+HTTP stack."

```bash
# Full stack against the LOCAL apiserver. -k skips cert verification
# (the healthz endpoint is served over TLS with the cluster CA):
curl -k https://localhost:6443/healthz
# ok

# Just a TCP port probe — -z scan (no data sent), -v verbose:
nc -zv 10.96.0.1 443
# Connection to 10.96.0.1 443 port [tcp/https] succeeded!

# UDP probe (e.g. is something on DNS/53?) — -u UDP, -z scan, -v verbose:
nc -zuv 10.96.0.10 53

# A port with nothing listening: hangs, then times out or "refused"
nc -zv 10.96.0.1 9999       # Connection refused / times out
```

**Verify:** `curl ... /healthz` returning `ok` = the apiserver is healthy end-to-end. `nc -zv` `succeeded!` = the port is open and reachable (a *routing + socket* success even if the app-layer would reject you). `nc` on a dead port that **hangs** (rather than instantly "refused") means a firewall is *dropping* your `SYN` silently — a different failure than "refused" (which means the host is up but nothing's on that port). Note `nc -zuv` on UDP is unreliable by nature (UDP has no handshake) — treat "succeeded" cautiously. On Ubuntu the OpenBSD `netcat` (`nc.openbsd`) is default and supports `-z`; some `nmap-ncat` builds differ slightly.

---

## Prediction 4 — The DNS chain: `/etc/hosts` beats DNS, `search` domains complete short names (edge/config case)

> **My prediction:** "If I resolve `kubernetes.default` from inside a pod, then it resolves to a ClusterIP *because* `/etc/resolv.conf` points at CoreDNS `10.96.0.10` and the `search` domains complete the short name; and if I add a line to `/etc/hosts`, then that name resolves to *my* IP without ever touching DNS — *because* `nsswitch.conf` lists `files` before `dns`."

```bash
# What is the pod actually configured to do for names?
cat /etc/nsswitch.conf | grep hosts     # hosts: files dns   ← order matters
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
cat /etc/hosts                          # 127.0.0.1 localhost, plus pod's own entry

# Resolve a Service name (nslookup is in the `dnsutils`/`bind-utils` image):
nslookup kubernetes.default.svc.cluster.local
# Server: 10.96.0.10 ... Address: 10.96.0.1

# The scriptable form — dig +short prints ONLY the answer:
dig +short kubernetes.default.svc.cluster.local     # 10.96.0.1
dig +short @10.96.0.10 kubernetes.default.svc.cluster.local   # ask CoreDNS explicitly

# Prove files-beats-dns: add a static entry, then resolve it
echo "1.2.3.4 demo.internal" | sudo tee -a /etc/hosts
getent hosts demo.internal              # 1.2.3.4  (came from /etc/hosts, no DNS)
```

**Verify:** `dig +short` returning `10.96.0.1` = the full DNS chain works. If it returns nothing, either CoreDNS is down (check `ss`/`curl` against `10.96.0.10:53`) or `resolv.conf` is wrong. `getent hosts demo.internal` returning `1.2.3.4` proves `files` short-circuits `dns` — if it instead hit DNS, your `nsswitch.conf` order is unusual. To test *only* DNS, `nslookup`/`dig` bypass `nsswitch`/`/etc/hosts` and talk to the nameserver directly — which is exactly why `dig` works when the app fails: the app obeys `/etc/hosts`, `dig` doesn't. (Clean up: remove the line you added to `/etc/hosts`.)

---

## Prediction 5 — Connection states and ephemeral ports explain a "stuck" client (failure case)

> **My prediction:** "If a client can't reach a dead endpoint, then `ss` will show its socket stuck in `SYN-SENT` with a high ephemeral source port — *because* the kernel sent a `SYN`, got no `SYN-ACK`, and is retrying; whereas a healthy connection shows `ESTAB` and a finished one briefly shows `TIME-WAIT`."

```bash
# Watch states live. Filter to non-listening TCP with process info:
ss -tnp

# Filter kernel-side by state (ss can do this; netstat cannot):
ss -tn state syn-sent           # clients stuck handshaking = unreachable peer
ss -tn state established        # healthy live connections
ss -tn state time-wait | wc -l  # recently-closed count (usually harmless)

# See the ephemeral port range the kernel draws client ports from:
sysctl net.ipv4.ip_local_port_range     # 32768   60999

# Reproduce a SYN-SENT: connect to a routable IP with a dead port
timeout 3 nc -v 10.96.0.1 9999 &        # will hang in SYN-SENT
ss -tn state syn-sent                    # observe it here
```

**Verify:** Anything in `syn-sent` toward a port that *should* answer means the far end isn't listening or a firewall is dropping `SYN`s (correlate with Prediction 2/3). A healthy busy service shows lots of `ESTAB`; a mountain of `TIME-WAIT` is usually normal churn, not a leak. If you predicted the source port would be a low/well-known number, repair that: *clients* always draw from the high ephemeral range — the well-known port is the *server's* side.

---

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> Linux delivers a packet by resolving a name to an address, then answering three kernel questions in order — which interface, which route, which socket — and every networking tool (`dig`, `ip`, `ss`, `curl`, `nc`) just inspects or exercises one of those four steps.

**Explain it to a beginner in 3 sentences:**
> 1. Before anything happens, a *name* like `kubernetes.default` is turned into an *address* by the resolver, which checks `/etc/hosts` first and then asks the DNS server listed in `/etc/resolv.conf` (in a pod, that's CoreDNS at `10.96.0.10`).
> 2. With an address in hand, the kernel picks an *interface* (a pod's `eth0` is really one end of a virtual `veth` cable), consults the *routing table* to choose the exit (`default via` the gateway, or the CNI's pod-CIDR route), and delivers to a *port* where a listening *socket* — like the apiserver on `6443` — is waiting.
> 3. The whole cluster network is these same primitives multiplied: each pod gets its own namespace with its own interfaces, routes, and resolv.conf, wired together by the CNI and kube-proxy.

**Map of sub-capability → the one core idea (four questions):**

```
Every networking task = "inspect or run one of the four answers":

Show/config interfaces   → ip addr / ip link / ifconfig   (Answer 1: which wire)
Show/config routes       → ip route / route               (Answer 2: which direction)
Show listening/ports     → ss -tlnp / netstat -tlnp       (Answer 3: which program)
Resolve a name           → dig / nslookup / resolv.conf   (Answer 0: name→address)
Test the whole path      → curl / nc -zv                  (run all four for real)
```

Five rows, one pipeline: *name → interface → route → socket.*

**Which rung will I most likely need to revisit hands-on?**
- **Rung 3A (veth pairs & namespaces).** "The pod's eth0 is one end of a cable" stays abstract until you actually `ip netns` into it — go pair this with `13-namespaces.md` and `nsenter` into a real pod to see its private `ip addr`.
- **Rung 3D / Prediction 4 (the DNS chain).** The `nsswitch → hosts → resolv.conf → search/ndots` order is the single most common thing people get fuzzy on — and it's the root of most "it resolves with `dig` but the app says `no such host`" tickets. Rehearse why `dig` and the app can disagree.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts
- [iptables & netfilter](12-iptables-netfilter.md) — how kube-proxy turns a ClusterIP into a real pod IP (the NAT that Rungs 3B/5 kept referencing)
- [namespaces](13-namespaces.md) — the network namespace that gives each pod its own `eth0`, routes, and resolv.conf
- [Linux philosophy: everything is a file](01-linux-philosophy.md) — sockets and `/proc/net` as files/descriptors behind `ss`
- [TLS, PKI & OpenSSL](26-tls-pki-openssl.md) — why `curl -k` skips verification and what the apiserver's `6443` certificate is
- [SSH & remote access](23-ssh-remote-access.md) — port forwarding and the sockets you tunnel when `kubectl` isn't enough
- [The Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — the full node-triage loop this networking rung plugs into

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A pod can't reach a Service — name the four independent things that must ALL be working, each mapping to one pain.

**A:** (1) An **interface** must be up — the pod's `eth0` (really one end of a veth pair) has to exist and be UP, or the packet has no wire to leave by (Pain 1). (2) A **route** must exist — the pod's `default via` route (and on the node, the CNI's pod-CIDR route) tells the kernel which direction to send the packet (Pain 2). (3) A **listening socket** must be bound on the other end — some process must have done `bind()`+`listen()` on the target port, or nothing will answer (Pain 3). (4) The **name must resolve** — DNS (CoreDNS via `/etc/resolv.conf`, after `/etc/hosts` per `nsswitch.conf`) has to turn the Service name into a ClusterIP before any packet can even be addressed (Pain 4). If any one of the four fails, the call fails, each with its own distinct symptom.

### Before Rung 3
**Q:** Say the core sentence from memory. In what ORDER are the four questions answered when a pod runs `curl http://my-svc`, and which happens before a single packet is built?

**A:** The sentence: *"A packet is delivered by answering four questions in order — which interface, which route, which socket, and (first of all) what address does this name map to — and every networking tool just inspects or exercises one of those four answers."* The order for `curl http://my-svc` is: **name→address first** (the resolver appends `search` domains and asks CoreDNS at `10.96.0.10`), then **which interface** (`eth0`), then **which route** (`default via 10.244.1.1`), and finally **which socket** (the backend pod's listening socket answers). The name→address (DNS) step happens *before any packet is built* — you can't route to a name, only to an address; the kernel needs a destination IP before it can construct the packet at all.

### Before Rung 4
**Q:** Draw the pod-and-node picture: (1) what is the pod's `eth0` really, and where is its other end? (2) which file tells the pod to ask `10.96.0.10` for names? (3) which route lets the packet leave the pod at all?

**A:** (1) The pod's `eth0` is **not hardware** — it is one end of a **veth pair**, a two-ended virtual patch cable; the other end (`vethXXXX`) lives in the node's root network namespace, plugged into the CNI bridge (`cni0`), so a packet pushed into the pod's `eth0` instantly pops out on the node. (2) **`/etc/resolv.conf`**, injected into the pod by the kubelet, contains `nameserver 10.96.0.10` (the CoreDNS ClusterIP) plus the `search` domains and `options ndots:5`. (3) The pod's **default route** — `default via 10.244.1.1 dev eth0` — which points at the node's bridge; without it, packets to anything outside the pod have no exit and never leave.

### Before Rung 5
**Q:** Which tool inspects Group 3 and which inspects Group 4, and which single failure symptom (`SYN-SENT` piling up) tells you Group 4 is the problem, not Group 1?

**A:** Group 3 ("which direction" — the routing table) is inspected with **`ip route`** (legacy: `route -n`). Group 4 ("which program" — sockets/ports) is inspected with **`ss`** (legacy: `netstat`). A pile-up of sockets stuck in **`SYN-SENT`** means the kernel already resolved the name and built and sent a `SYN` toward a real IP, but is getting no `SYN-ACK` back — so DNS (Group 1) clearly worked; the problem is a socket-side failure: nothing is listening on the far end, or a firewall is silently dropping the handshake.

### Before Rung 6
**Q:** At which step does the error change from `no such host` to `connection refused`, and why do those errors point at completely different Rung 4 groups?

**A:** The boundary is between **Step 5 and Step 6**: failures in Steps 3/5 (the DNS query to CoreDNS, or CoreDNS's answer) produce `no such host`, while failures at Steps 6/7 (the TCP `SYN`/handshake to `10.96.0.1:443`) produce `connection refused` (or a hang and timeout with the socket in `SYN-SENT` if a firewall drops the `SYN`). They point at different groups because `no such host` means the resolver never got an address — a **Group 1 (DNS)** problem in `nsswitch`/`hosts`/`resolv.conf`/CoreDNS — whereas `connection refused` proves DNS already succeeded and an IP was reached, but no listening socket accepted the connection — a **Group 4 (sockets/ports)** problem. The error text tells you which of the four answers failed, and that mapping is the triage skill.

### Before Rung 7
**Q:** Why can `ping 10.96.0.1` fail on a perfectly healthy cluster while `curl 10.96.0.1:443` succeeds — what is a ClusterIP really?

**A:** A ClusterIP is not a host — it's a **virtual IP that exists only as NAT rules** (kube-proxy's iptables/IPVS); no machine actually owns `10.96.0.1`, so there is no network stack sitting there to answer ICMP echo requests. `ping` uses ICMP, and the NAT rules typically only rewrite TCP/UDP traffic aimed at Service ports, so the ping gets no reply even though everything is healthy. `curl 10.96.0.1:443` succeeds because it sends TCP to a real Service port, which kube-proxy NATs to an actual backend pod (the apiserver), whose listening socket answers. That's why you test Services with `nc -zv` or `curl` against the real port, never with `ping`.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Lisbon: the runbook says 8100, the kernel disagrees" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-lisbon
sudo tee /opt/lab-lisbon/app.py >/dev/null <<'EOF'
import http.server, socketserver
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'lisbon-ok\n')
    def log_message(self, *a):
        pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', 8123), H) as s:
    s.serve_forever()
EOF
pkill -f lab-lisbon/app.py 2>/dev/null || true
nohup python3 /opt/lab-lisbon/app.py >/dev/null 2>&1 &
sleep 1
```
**Situation:** The internal "docs" micro-app on this box is supposed to serve its health page on port **8100** — that's what the runbook says and that's what the alert probes, and the alert is red: `curl http://127.0.0.1:8100/` returns `Connection refused`. The developer swears the process is running, and `ps aux | grep app.py` backs them up. Somebody is wrong, and it isn't the kernel.

**Your task:** Using the kernel's socket table (not the runbook, not `ps`), find the port the app is *actually* listening on. Write just the port number to `/tmp/lab-lisbon-port.txt` and fetch the page from it.

**Verify:**
```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$(cat /tmp/lab-lisbon-port.txt)/"   # expected: 200
```

### 🟢 Scenario 2 — "Porto: dig is innocent, the fossil file did it" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-porto/www
echo 'porto-ok' | sudo tee /opt/lab-porto/www/index.html >/dev/null
pkill -f 'http.server 8200' 2>/dev/null || true
nohup python3 -m http.server 8200 --bind 127.0.0.1 --directory /opt/lab-porto/www >/dev/null 2>&1 &
sudo sed -i '/files\.lab-porto\.internal/d' /etc/hosts
echo '203.0.113.99 files.lab-porto.internal' | sudo tee -a /etc/hosts >/dev/null
sleep 1
```
**Situation:** After last month's migration, the file-sync service `files.lab-porto.internal` moved *onto this very box* — it now listens locally on port 8200. Yet every client on the machine hangs for seconds and then times out calling `http://files.lab-porto.internal:8200/`. The DNS team closed your ticket with "we have no records for `.internal` names, not our problem" — and annoyingly, they're right.

**Your task:** Work out where the resolver is *actually* getting an answer for `files.lab-porto.internal` (hint: `getent hosts` walks the real chain; `dig` does not), and fix that source so the URL works. For this lab, the correct address is `127.0.0.1`.

**Verify:**
```bash
curl -s --max-time 5 http://files.lab-porto.internal:8200/   # expected: porto-ok
```

### 🟡 Scenario 3 — "Madrid: the exporter that vanished from the network" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-madrid/www
echo 'madrid-ok' | sudo tee /opt/lab-madrid/www/index.html >/dev/null
pkill -f 'http.server 8300' 2>/dev/null || true
sudo ip link add lab0 type dummy 2>/dev/null || true
sudo ip addr replace 10.77.0.1/24 dev lab0
sudo ip link set lab0 up
nohup python3 -m http.server 8300 --bind 10.77.0.1 --directory /opt/lab-madrid/www >/dev/null 2>&1 &
sleep 1
sudo ip link set lab0 down
```
**Situation:** A metrics exporter is bound to this box's secondary service address `10.77.0.1:8300` (on the interface `lab0`). Since last night's maintenance window Prometheus shows the target down, and on the box itself `curl http://10.77.0.1:8300/` doesn't even get refused — it hangs, then times out. Meanwhile `ss -tlnp` insists the exporter is still in `LISTEN` on `10.77.0.1:8300`. The socket exists — but the packets to it are going somewhere very wrong.

**Your task:** Run the four-questions loop. The socket answer checks out, so interrogate the interface and the route: ask the kernel which exit it would really use (`ip route get 10.77.0.1`) and explain why the SYN is *leaving the machine*. Fix what maintenance broke — without restarting the exporter.

**Verify:**
```bash
curl -s --max-time 3 http://10.77.0.1:8300/   # expected: madrid-ok
```

### 🟡 Scenario 4 — "Prague: the packet that took the wrong exit" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-prague/www
echo 'prague-ok' | sudo tee /opt/lab-prague/www/index.html >/dev/null
sudo pkill -f 'http.server 8400' 2>/dev/null || true
sudo ip netns del labns-prague 2>/dev/null || true
sudo ip link del labveth0 2>/dev/null || true
sudo ip link del lab-decoy 2>/dev/null || true
sudo ip netns add labns-prague
sudo ip link add labveth0 type veth peer name labveth1
sudo ip link set labveth1 netns labns-prague
sudo ip addr add 10.89.0.1/24 dev labveth0
sudo ip link set labveth0 up
sudo ip netns exec labns-prague ip addr add 10.89.0.2/24 dev labveth1
sudo ip netns exec labns-prague ip link set labveth1 up
sudo ip netns exec labns-prague ip link set lo up
sudo ip netns exec labns-prague bash -c 'nohup python3 -m http.server 8400 --bind 10.89.0.2 --directory /opt/lab-prague/www >/dev/null 2>&1 &'
sudo ip link add lab-decoy type dummy
sudo ip link set lab-decoy up
sudo ip route add 10.89.0.2/32 dev lab-decoy
sleep 1
```
**Situation:** This host talks to a small appliance at `10.89.0.2:8400` over a point-to-point link, `labveth0` — the setup wires the appliance end into its own namespace, exactly the veth-pair pattern a pod uses. It worked yesterday. Today `curl http://10.89.0.2:8400/` hangs and times out, and while it hangs, `ss -tn state syn-sent` shows your SYN going nowhere. A teammate admits they were "experimenting with routing" on this box yesterday evening.

**Your task:** Ask the kernel which exit it actually chooses for `10.89.0.2` (`ip route get`), work out why the wrong route is beating the right one (think longest-prefix match), and remove the offending route so the appliance answers again.

**Verify:**
```bash
ip route get 10.89.0.2 | head -1              # expected: ... dev labveth0 src 10.89.0.1 ...
curl -s --max-time 3 http://10.89.0.2:8400/   # expected: prague-ok
```

### 🟠 Scenario 5 — "Vienna: listening, but only on the other internet" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-vienna
sudo tee /opt/lab-vienna/app.conf >/dev/null <<'EOF'
# lab-vienna listener config
BIND=::1
PORT=8500
EOF
sudo tee /opt/lab-vienna/app.py >/dev/null <<'EOF'
import http.server, socket, socketserver
conf = {}
for line in open('/opt/lab-vienna/app.conf'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, v = line.split('=', 1)
        conf[k] = v
class Srv(socketserver.TCPServer):
    allow_reuse_address = True
    address_family = socket.AF_INET6 if ':' in conf['BIND'] else socket.AF_INET
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'vienna-ok\n')
    def log_message(self, *a):
        pass
with Srv((conf['BIND'], int(conf['PORT'])), H) as s:
    s.serve_forever()
EOF
pkill -f lab-vienna/app.py 2>/dev/null || true
nohup python3 /opt/lab-vienna/app.py >/dev/null 2>&1 &
sleep 1
```
**Situation:** After a "small config cleanup" someone shipped last Friday, the load balancer has marked this API instance down: its IPv4 health check `curl -4 http://127.0.0.1:8500/` gets `Connection refused`. The previous on-call ran `ss -tlnp | grep 8500`, saw a `LISTEN` line, and escalated with "port is open, must be the LB's fault." The port number is the least interesting column of that `ss` line.

**Your task:** Explain how a socket can be in `LISTEN` on port 8500 while every IPv4 client is refused — look at exactly *which address, which family* that socket is bound to. Then fix the app's bind config in `/opt/lab-vienna/app.conf` and restart it (`pkill -f lab-vienna/app.py`, then relaunch with `nohup python3 /opt/lab-vienna/app.py >/dev/null 2>&1 &`) so the IPv4 health check passes.

**Verify:**
```bash
curl -4 -s --max-time 3 http://127.0.0.1:8500/   # expected: vienna-ok
```

### 🔴 Scenario 6 — "Krakow: three lies between you and the appliance" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-krakow/www
echo 'krakow-ok' | sudo tee /opt/lab-krakow/www/index.html >/dev/null
sudo pkill -f 'http.server 8601' 2>/dev/null || true
sudo ip netns del labns-krakow 2>/dev/null || true
sudo ip link del labveth2h 2>/dev/null || true
sudo ip netns add labns-krakow
sudo ip link add labveth2h type veth peer name labveth2n
sudo ip link set labveth2n netns labns-krakow
sudo ip link set labveth2h up
sudo ip netns exec labns-krakow ip addr add 10.90.0.2/24 dev labveth2n
sudo ip netns exec labns-krakow ip link set labveth2n up
sudo ip netns exec labns-krakow ip link set lo up
sudo ip netns exec labns-krakow bash -c 'nohup python3 -m http.server 8601 --bind 10.90.0.2 --directory /opt/lab-krakow/www >/dev/null 2>&1 &'
sudo sed -i '/api\.lab-krakow\.internal/d' /etc/hosts
echo '203.0.113.77 api.lab-krakow.internal' | sudo tee -a /etc/hosts >/dev/null
sleep 1
```
**Situation:** A vendor appliance — a black box you cannot log into — hangs off this host on the dedicated link `labveth2h`. The runbook states: name `api.lab-krakow.internal`, appliance IP `10.90.0.2`, host side of the link `10.90.0.1/24`, service port `8600`. A sticky note adds: "port may have changed in the latest firmware." Right now `curl http://api.lab-krakow.internal:8600/` hangs forever — and after each fix you make it will fail *differently*, because this box is telling three separate lies: one in name resolution, one at the interface/route layer, and one at the socket layer.

**Your task:** Peel the onion with the four-questions loop — name → interface → route → socket. Fix name resolution, restore the host side of the link, then hunt down the appliance's real port from the outside (you can't ssh in — probe it, e.g. `nc -zv 10.90.0.2 8600-8610`). Write the real port to `/tmp/lab-krakow-port.txt` and fetch the page by name.

**Verify:**
```bash
curl -s --max-time 5 "http://api.lab-krakow.internal:$(cat /tmp/lab-krakow-port.txt)/"   # expected: krakow-ok
```

---

## 🔑 Lab Answers — Solutions & Explanations

### 🟢 Scenario 1 — "Lisbon: the runbook says 8100, the kernel disagrees"
**Solution:**
```bash
ss -tlnp | grep python          # LISTEN 0 5 127.0.0.1:8123 ... users:(("python3",pid=...))
echo 8123 > /tmp/lab-lisbon-port.txt
curl -s "http://127.0.0.1:$(cat /tmp/lab-lisbon-port.txt)/"   # lisbon-ok
```
**Why this works & what it teaches:** `Connection refused` means the SYN reached a live IP but **no socket was listening on that port** — a Group 4 (sockets) failure from Rung 4, not DNS or routing. `ss -tlnp` dumps the kernel's socket table — the ground truth of who actually called `bind()`+`listen()` — and it shows the app claimed `8123`, not the documented `8100`. Where people go wrong: trusting `ps` (which only proves the process *runs*) instead of `ss` (which proves what it *listens on*). **Cleanup:** `pkill -f lab-lisbon/app.py; sudo rm -rf /opt/lab-lisbon; rm -f /tmp/lab-lisbon-port.txt`

### 🟢 Scenario 2 — "Porto: dig is innocent, the fossil file did it"
**Solution:**
```bash
getent hosts files.lab-porto.internal      # 203.0.113.99 — an answer, but from WHERE?
grep lab-porto /etc/hosts                  # there it is: a stale migration entry
sudo sed -i 's/^203\.0\.113\.99[[:space:]]*files\.lab-porto\.internal/127.0.0.1 files.lab-porto.internal/' /etc/hosts
curl -s http://files.lab-porto.internal:8200/    # porto-ok
```
**Why this works & what it teaches:** `nsswitch.conf` says `hosts: files dns`, so an `/etc/hosts` entry short-circuits DNS entirely (Rung 3D, Prediction 4) — the stale `203.0.113.99` (an unroutable TEST-NET address) blackholed every SYN, which is why clients *hung* (`SYN-SENT`) instead of getting refused. `getent hosts` walks the real resolver chain and exposed the lie; `dig` talks straight to a DNS server and never sees `/etc/hosts` — exactly why "dig works (or knows nothing) but the app disagrees" tickets exist. **Cleanup:** `sudo sed -i '/files\.lab-porto\.internal/d' /etc/hosts; pkill -f 'http.server 8200'; sudo rm -rf /opt/lab-porto`

### 🟡 Scenario 3 — "Madrid: the exporter that vanished from the network"
**Solution:**
```bash
ss -tlnp | grep 8300            # LISTEN on 10.77.0.1:8300 — the socket is fine
ip route get 10.77.0.1          # "10.77.0.1 via <default-gw> dev eth0" — it would LEAVE the box!
ip addr show lab0               # lab0 is DOWN — maintenance never brought it back up
sudo ip link set lab0 up
ip route get 10.77.0.1          # now: "local 10.77.0.1 dev lo ..." — local again
curl -s --max-time 3 http://10.77.0.1:8300/   # madrid-ok
```
**Why this works & what it teaches:** When an interface goes DOWN, the kernel withdraws its local and connected routes while keeping the address configured *and* keeping existing listening sockets alive — so `ss` looks healthy while `10.77.0.1` silently stops being "local". Longest-prefix match then falls through to `default via`, and your SYN to your own address is shipped toward the gateway and dies (Rung 3B), hanging in `SYN-SENT` (Prediction 5). `ip route get` is the killer move: it asks the kernel for the *actual* routing decision instead of guessing from the table. Where people go wrong: restarting the service (Group 4) when the failure lives in Groups 2/3. **Cleanup:** `pkill -f 'http.server 8300'; sudo ip link del lab0; sudo rm -rf /opt/lab-madrid`

### 🟡 Scenario 4 — "Prague: the packet that took the wrong exit"
**Solution:**
```bash
ip route get 10.89.0.2                # "10.89.0.2 dev lab-decoy ..." — wrong exit!
ip route show | grep 10.89.0          # both routes: 10.89.0.0/24 dev labveth0 AND 10.89.0.2 dev lab-decoy
sudo ip route del 10.89.0.2/32 dev lab-decoy
ip route get 10.89.0.2                # now: "10.89.0.2 dev labveth0 src 10.89.0.1"
curl -s --max-time 3 http://10.89.0.2:8400/   # prague-ok
```
**Why this works & what it teaches:** Routing is a longest-prefix-match lookup (Rung 3B): the teammate's `/32` host route is more specific than the correct connected `/24`, so every packet for `10.89.0.2` exited the `lab-decoy` dummy — a device that silently swallows frames — leaving the client stuck in `SYN-SENT` (Prediction 5). `ip route get <ip>` shows the winning route directly, which beats eyeballing `ip route show` on a busy CNI node with dozens of entries. This is precisely how a stray host route breaks a single pod IP while the rest of the subnet works. **Cleanup:** `sudo pkill -f 'http.server 8400'; sudo ip netns del labns-prague; sudo ip link del lab-decoy; sudo rm -rf /opt/lab-prague` (deleting the netns destroys `labveth1`, which takes `labveth0` with it — veth ends die in pairs)

### 🟠 Scenario 5 — "Vienna: listening, but only on the other internet"
**Solution:**
```bash
ss -tlnp | grep 8500                  # LISTEN ... [::1]:8500 — IPv6 loopback ONLY
curl -6 -s 'http://[::1]:8500/'       # vienna-ok — the app itself is healthy, over IPv6
sudo sed -i 's/^BIND=.*/BIND=0.0.0.0/' /opt/lab-vienna/app.conf
pkill -f lab-vienna/app.py
nohup python3 /opt/lab-vienna/app.py >/dev/null 2>&1 &
sleep 1
curl -4 -s http://127.0.0.1:8500/     # vienna-ok
```
**Why this works & what it teaches:** A socket's identity is *family + address + port*, not just the port (Rung 3C): this listener was bound to `[::1]` (IPv6 loopback, `AF_INET6`), so an IPv4 SYN to `127.0.0.1:8500` finds no matching socket and the kernel answers with a reset — `Connection refused` while `ss` "shows the port open". The tell is entirely in `ss`'s Local Address column: `[::1]:8500` vs `127.0.0.1:8500` vs `0.0.0.0:8500` (any-IPv4) vs `[::]:8500` (any-IPv6, usually dual-stack). Where people go wrong: grepping `ss` output for the port number and never reading the address next to it. **Cleanup:** `pkill -f lab-vienna/app.py; sudo rm -rf /opt/lab-vienna`

### 🔴 Scenario 6 — "Krakow: three lies between you and the appliance"
**Solution:**
```bash
# Lie 1 — name resolution. A hang (not "refused") + a name = check the resolver chain first:
getent hosts api.lab-krakow.internal        # 203.0.113.77 — /etc/hosts is lying (files beats dns)
sudo sed -i 's/^203\.0\.113\.77[[:space:]]*api\.lab-krakow\.internal/10.90.0.2 api.lab-krakow.internal/' /etc/hosts
curl --max-time 3 http://api.lab-krakow.internal:8600/   # still fails — but differently now
# Lie 2 — interface/route. Ask the kernel where 10.90.0.2 would exit:
ip route get 10.90.0.2                      # via the default gateway — WRONG for a directly-attached link
ip addr show labveth2h                      # UP but carries no inet address → no connected route
sudo ip addr add 10.90.0.1/24 dev labveth2h # restore it; the 10.90.0.0/24 connected route reappears
curl --max-time 3 http://api.lab-krakow.internal:8600/   # now: Connection refused — progress!
# Lie 3 — socket. "Refused" = we reach the appliance, nothing listens on 8600. Probe the range:
nc -zv 10.90.0.2 8600-8610 2>&1 | grep -i succeeded      # ... 8601 port [tcp/*] succeeded!
echo 8601 > /tmp/lab-krakow-port.txt
curl -s "http://api.lab-krakow.internal:$(cat /tmp/lab-krakow-port.txt)/"   # krakow-ok
```
**Why this works & what it teaches:** Each layer failed with its *own signature*, exactly the Rung 5 error map: blackholed TEST-NET IP → silent hang in `SYN-SENT` (resolver lied); no connected route → the SYN exits via the default gateway instead of the link (`ip route get` exposes it); no listener on 8600 → instant `Connection refused`, which paradoxically is *good news* — it proves name, interface, and route are all correct and only the socket answer remains. `nc -zv` over a port range is the standard "black-box appliance" move from Prediction 3. Where people go wrong: re-fixing the layer they already fixed because the symptom changed and they didn't re-triage from the top. **Cleanup:** `sudo pkill -f 'http.server 8601'; sudo ip netns del labns-krakow; sudo sed -i '/api\.lab-krakow\.internal/d' /etc/hosts; sudo rm -rf /opt/lab-krakow; rm -f /tmp/lab-krakow-port.txt`
