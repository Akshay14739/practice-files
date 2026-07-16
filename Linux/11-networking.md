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
