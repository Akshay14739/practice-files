# iptables & netfilter

*How the Linux kernel decides the fate of every packet — and how kube-proxy turns your Services into thousands of these decisions.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?** How the Linux kernel inspects, mangles, redirects, and drops network packets — the *netfilter* framework — and the classic user-space tool that programs it, *iptables*. Netfilter is the packet-processing machinery baked into the kernel; iptables is one language for writing rules into it.

**Why did it land on my desk?** You're a Kubernetes platform engineer. A ticket says: *"Pods can reach `my-svc` by its ClusterIP `10.96.0.10:80` fine, but after we scaled the Deployment from 3 to 0 replicas and back, some clients get connection refused, others hang."* You `kubectl get endpoints`, they look right. You SSH to the node, and someone says "check the iptables rules kube-proxy wrote." You run `iptables -t nat -L -n -v` and a wall of `KUBE-SVC-XXXX` chains scrolls by. You realize: **a Kubernetes Service is not a process. It's a pile of iptables rules on every node.** There is no server listening on `10.96.0.10`. The kernel rewrites the destination address mid-flight. If you don't understand netfilter, ClusterIP is pure magic — and you can't debug magic.

**What do I already know (assumed)?**
- From [networking](11-networking.md): IP addresses, ports, TCP handshake, `ip addr`, `ss -tlnp`, that a packet has a source IP:port and destination IP:port.
- From [namespaces](13-namespaces.md): each pod lives in its own network namespace with its own interfaces; the node's *host* namespace is where kube-proxy's rules mostly live.
- `kubectl` fluency: Services, Endpoints/EndpointSlices, Pods, ClusterIP vs NodePort.
- That containerd runs your containers and each pod has a `pause` container holding the network namespace open.

You do **not** need to already know iptables. That's the whole point.

---

## 🔥 Rung 1 — The Pain

Before netfilter, if you wanted a Linux box to be a firewall, a router, or a NAT gateway, you had a bad time. The problem is fundamental: **a packet arriving at a network card is just bytes in kernel memory, and the kernel needs a place to let you say "do something to this packet before you route it."** Without a standard hook system, every feature — firewalling, port forwarding, address translation, logging — had to be bolted into the networking stack ad hoc.

The history of pain, briefly:
- **`ipfwadm` (kernel 2.0)** and **`ipchains` (2.2)** were earlier firewall tools. They were rigid: rules lived in a few fixed lists, connection state wasn't tracked, and NAT was a separate, awkward subsystem. A packet that was part of an already-approved connection had to be re-evaluated from scratch, so you wrote fragile rules trying to guess return traffic.
- **No connection tracking** meant *stateless* firewalls. To allow a reply to an outbound web request, you had to open a huge range of high ports inbound and hope. This was both insecure and maddening.
- **NAT was hacked on**, not designed in. Sharing one public IP across a LAN (masquerading) worked, but it lived apart from the filtering logic, so reasoning about "does this packet get translated *then* filtered, or filtered *then* translated?" was guesswork.

**What breaks without it, in Kubernetes terms?** Everything about Services. A ClusterIP has no NIC, no process, no ARP entry — it is a *virtual* IP. The only thing that makes `10.96.0.10:80` mean "load-balance across pods `10.244.1.5` and `10.244.2.7`" is netfilter rewriting the destination address (DNAT) as the packet leaves the client pod. Without netfilter (or an equivalent like IPVS or eBPF), kube-proxy's default mode simply cannot exist. Pod-to-external traffic also breaks: a pod IP like `10.244.1.5` is not routable on your corporate network, so when a pod calls an external API, the node must **masquerade** — rewrite the source to the node's IP — or the reply has nowhere to come back to.

**Who feels the pain most?** The platform engineer at 2 a.m. Application developers see "Service works" or "Service broken." *You* are the one who has to open the black box, and the black box is netfilter.

> **Check yourself before Rung 2:** Given that a ClusterIP has no process listening on it, what is the *minimum* thing the kernel must do to a packet destined for `10.96.0.10:80` so that a real pod at `10.244.1.5:8080` receives it — and at which moment in the packet's life must it happen?

---

## 💡 Rung 2 — The One Idea

> **Netfilter is a set of fixed hook points in the kernel's packet path; at each hook, ordered rules test a packet and, on a match, jump to a target that decides its fate (accept, drop, rewrite, or jump elsewhere).**

Memorize that sentence. Everything else is derivation.

Derive the rest from it:
- *"Fixed hook points in the packet path"* → there are exactly **five hooks** (PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING), placed at the moments where the kernel makes routing/delivery decisions. You don't invent hooks; you register rules at existing ones.
- *"Ordered rules"* → rules live in **chains**, walked top to bottom, first match's target wins (or falls through). Order is everything.
- *"Test a packet"* → each rule is a set of **matches** (protocol, port, source, connection state...). All must be true.
- *"Jump to a target"* → the **target** is the verb: `ACCEPT`, `DROP`, `DNAT`, `SNAT`/`MASQUERADE`, or a *jump* to another chain (how kube-proxy nests `KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx`).
- *"Rewrite"* → address translation (NAT) is just a target that edits the packet's IP/port. ClusterIP is a `DNAT`. Pod-egress masquerade is an `SNAT`.
- Chains are grouped into **tables** by *purpose* (filter = allow/deny, nat = rewrite, mangle = tweak, raw = pre-tracking). Same five hooks, different tables layered on top.

If you internalize "hooks → chains → rules(matches) → targets, grouped into tables," you can read any kube-proxy ruleset.

> **Check yourself before Rung 3:** Using only the one-idea sentence, explain why a Kubernetes Service's load-balancing decision lives in a *target* (a jump to `KUBE-SEP-xxx`) rather than in a *match* — and what the `nat` *table* has to do with it.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### 3.1 Netfilter is *in* the kernel; iptables just writes to it

Netfilter is C code compiled into the kernel's networking stack. As a packet moves through the stack, the code calls out to five **hooks**. At each hook, the kernel walks whatever rules have been registered there and acts on the packet. `iptables` is a *user-space* command that serializes your rules and pushes them into the kernel via the `setsockopt`/netlink interface. The kernel does the per-packet work; iptables just installs the rulebook. This is why adding a rule is instant and why the rules survive even after the `iptables` process exits — they live in the kernel, not in your shell.

### 3.2 The five hooks and where routing happens

The single most important diagram in this document. This is the path a packet takes and where the five hooks sit relative to the kernel's **routing decision** ("is this packet for *me* or for someone *else*?").

```
                      ┌───────────────────────────────────────────────┐
   packet arrives     │                   THE HOST                     │
   on a NIC           │                                               │
        │             │                                               │
        ▼             │                                               │
  ┌───────────┐   ┌────────────┐   yes, for me   ┌────────────┐        │
  │ PREROUTING │──▶│  ROUTING   │───────────────▶│   INPUT    │──▶ local process
  └───────────┘   │  DECISION  │                 └────────────┘   (e.g. kubelet,
   (DNAT here:    └────────────┘                  (filter INPUT)   an app in a pod)
    ClusterIP →        │                                              │
    pod IP)            │ no, for someone else                        ▼
                       ▼                                        ┌──────────┐
                 ┌────────────┐        ┌────────────┐           │  OUTPUT  │ locally
                 │  FORWARD   │───────▶│   ROUTING  │◀──────────│          │ generated
                 └────────────┘        │  DECISION  │           └──────────┘ packet
                 (filter FORWARD:      └────────────┘            (nat/filter
                  pod-to-pod across          │                    OUTPUT)
                  the node routes here)      ▼
                                       ┌────────────┐
                                       │ POSTROUTING │──▶ out a NIC
                                       └────────────┘
                                       (SNAT/MASQUERADE here:
                                        pod IP → node IP on egress)
```

Read it as three journeys:
1. **Packet passing *through* the box (routing/forwarding):** PREROUTING → routing decision → FORWARD → POSTROUTING. This is pod-to-pod traffic that hops via the node, and it's why `net.ipv4.ip_forward=1` must be set on Kubernetes nodes (see [kernel-tuning](24-kernel-tuning-boot.md)).
2. **Packet *into* a local process:** PREROUTING → routing decision → INPUT → app. This is traffic to something *on the node* (the kubelet's healthz port, a hostNetwork pod).
3. **Packet *out of* a local process:** OUTPUT → routing decision → POSTROUTING → NIC. This is a process on the node originating traffic.

The mental anchor: **DNAT (destination rewrite) happens *early*, at PREROUTING/OUTPUT, so the routing decision uses the *real* destination. SNAT (source rewrite) happens *late*, at POSTROUTING, after routing is done, so it doesn't disturb routing.** That timing is not arbitrary — it's forced by what each rewrite must not break.

### 3.3 Tables: the same hooks, layered by purpose

A **table** is a collection of chains dedicated to one kind of work. Multiple tables register rules at the *same* hook; they run in a fixed priority order (raw → mangle → nat → filter, roughly). You rarely touch this ordering, but it explains why `raw` can exempt a packet from connection tracking *before* `nat` ever sees it.

| Table | Purpose | Chains it hooks | Kube use |
|-------|---------|-----------------|----------|
| `filter` | Allow / deny (the actual firewall) | INPUT, FORWARD, OUTPUT | NetworkPolicy allow/deny; default node firewall |
| `nat` | Rewrite addresses/ports, once per connection | PREROUTING, INPUT, OUTPUT, POSTROUTING | **ClusterIP DNAT, pod egress MASQUERADE** — the heart of kube-proxy |
| `mangle` | Alter packet fields (TOS, TTL, mark) | all five | packet marking for policy routing; some CNIs |
| `raw` | Act *before* connection tracking | PREROUTING, OUTPUT | `NOTRACK` to skip conntrack for perf |

Key subtlety: the **`nat` table only sees the *first* packet of each connection.** Once conntrack decides "this flow gets DNAT'd to `10.244.1.5:8080`," every subsequent packet of that flow is translated automatically by the conntrack machinery, *without* re-walking the nat rules. That's both a performance win and the reason your load-balancing decision is *sticky per connection*, not per packet.

### 3.4 Chains, rules, matches, targets

A **chain** is an ordered list of rules attached to a hook (built-in chains: `INPUT`, `FORWARD`, etc.) or a user-defined chain you `jump` to (like `KUBE-SVC-XXXX`). Each **rule** = **matches** + a **target**:

```
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
          │   │     │        │          │
          │   │     │        │          └─ TARGET: what to do on match
          │   │     └────────┴─ MATCHES: tcp AND destination port 80
          │   └─ CHAIN: append to the INPUT chain
          └─ (default table is `filter` when -t is omitted)
```

The kernel walks the chain top to bottom. On the first rule whose matches *all* pass, it runs the target. `ACCEPT`/`DROP` are terminating. A jump to a user chain runs that sub-chain and, if nothing there terminates, *returns* to the next rule after the jump. Each built-in chain also has a **policy** (default `ACCEPT` or `DROP`) applied if no rule matches.

### 3.5 Connection tracking (conntrack) — the state engine

This is what makes netfilter a *stateful* firewall and what makes Kubernetes Services work at all. **conntrack** is a kernel table of every connection the box has seen: `(src ip:port, dst ip:port, proto)` → state and any NAT translation to apply. Each flow has a `ctstate`:

- `NEW` — first packet of a flow the kernel hasn't seen.
- `ESTABLISHED` — a flow where traffic has gone both directions.
- `RELATED` — a new flow spawned by an existing one (e.g. an FTP data channel, or an ICMP error).
- `INVALID` — doesn't match any known flow and isn't a valid new one.

The golden firewall rule you'll see everywhere:

```bash
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

This says "if this packet belongs to a connection I already approved, let it in without re-checking" — so you only need explicit rules for `NEW` connections. Conntrack lives in `/proc/sys/net/netfilter/` (tunables like `nf_conntrack_max`) and you inspect it with the `conntrack` tool. **In Kubernetes this table is load-bearing:** it's where the DNAT decision "this ClusterIP flow → pod `10.244.1.5:8080`" is remembered for the life of the connection, and a full conntrack table (`nf_conntrack: table full, dropping packet` in `dmesg`) is a classic cause of mysterious pod networking failures under high connection churn.

### 3.6 How kube-proxy (iptables mode) programs all this

`kube-proxy` is a pod (usually a DaemonSet) on every node. It **watches the API server** for Services and EndpointSlices, and translates them into `nat`-table rules. It does *not* sit in the data path — it's a control-plane translator. The packet never touches kube-proxy; it touches the rules kube-proxy wrote. The structure it builds:

```
nat PREROUTING / OUTPUT
        │
        ▼
   KUBE-SERVICES          (one rule per Service ClusterIP:port)
        │
        │  match dst=10.96.0.10 tcp dport 80
        ▼
   KUBE-SVC-ABCDEF        (load-balancer for that Service)
        │
        ├─ statistic mode random probability 0.50 ─▶ KUBE-SEP-1  (pod A)
        └─ (fallthrough)                          ─▶ KUBE-SEP-2  (pod B)
                                                       │
                                                       ▼
                                                  DNAT to 10.244.2.7:8080
```

- **KUBE-SERVICES**: the entry chain, jumped to from PREROUTING and OUTPUT. One match per Service VIP.
- **KUBE-SVC-xxx**: the per-Service chain that does load balancing using the `statistic` match with `mode random probability`. With N endpoints, the first rule fires with probability 1/N, the next with 1/(N-1) of the remainder, etc., giving an even split. It jumps to a per-endpoint chain.
- **KUBE-SEP-xxx** (SEP = Service EndPoint): does the actual `DNAT` to one pod IP:port, and (for the pod's own traffic to itself) a `KUBE-MARK-MASQ` mark.
- **KUBE-MARK-MASQ / KUBE-POSTROUTING**: packets that need source-NAT on the way out (pod traffic leaving the node, or hairpin traffic) get a firewall *mark*, and `KUBE-POSTROUTING` in POSTROUTING masquerades marked packets.

**NetworkPolicy** is *not* implemented by kube-proxy. Your **CNI plugin** (Calico, Cilium's iptables mode, etc.) watches `NetworkPolicy` objects and compiles them into `filter`-table rules (often in the FORWARD path / custom chains like `cali-...`). So on a node you can see *two* authors writing to netfilter: kube-proxy (Services, in `nat`) and the CNI (policy, in `filter`).

> **Check yourself before Rung 4:** A packet from a client pod to a ClusterIP gets its destination rewritten by DNAT. At which hook does that rewrite happen, and why must it happen *before* the routing decision rather than after? What would break if kube-proxy tried to DNAT at POSTROUTING instead?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|------|--------------------|-----------------------------|
| **netfilter** | Kernel framework of packet hooks | The whole packet path; the engine |
| **iptables** | User-space CLI that installs rules into netfilter | Control plane; writes chains/rules |
| **hook** | One of 5 fixed callout points in the packet path | PREROUTING, INPUT, FORWARD, OUTPUT, POSTROUTING |
| **table** | A ruleset grouped by purpose | filter / nat / mangle / raw layered on the hooks |
| **chain** | Ordered list of rules on a hook (or user-defined) | INPUT, KUBE-SERVICES, KUBE-SVC-xxx |
| **rule** | matches + a target | One line inside a chain |
| **match** | A condition a packet must satisfy | `-p tcp`, `--dport 80`, `-s 10.244.0.0/16`, `-m conntrack` |
| **target** | The action on match | ACCEPT/DROP/DNAT/SNAT/MASQUERADE/jump |
| **policy** | Default verdict if no rule matches (built-in chains) | ACCEPT or DROP at end of chain |
| **DNAT** | Rewrite *destination* address/port | nat table, PREROUTING/OUTPUT — ClusterIP |
| **SNAT** | Rewrite *source* to a fixed address | nat table, POSTROUTING |
| **MASQUERADE** | SNAT to the outgoing interface's *current* IP | nat POSTROUTING — pod egress |
| **conntrack** | Kernel table of known connections + their NAT | State engine; makes NAT/stateful FW possible |
| **ctstate** | A flow's tracked state | NEW / ESTABLISHED / RELATED / INVALID |
| **KUBE-SERVICES** | kube-proxy's entry chain (nat) | Dispatch to per-Service chains |
| **KUBE-SVC-xxx** | Per-Service load-balancer chain | `statistic random probability` split |
| **KUBE-SEP-xxx** | Per-endpoint chain | DNAT to one pod IP:port |
| **KUBE-MARK-MASQ** | Sets a fwmark for later masquerade | Marks packets; POSTROUTING acts on mark |
| **iptables-nft** | iptables front-end that writes to the newer `nftables` kernel backend | Same commands, different kernel subsystem |
| **IPVS** | In-kernel L4 load balancer (alternative kube-proxy mode) | Replaces KUBE-SVC hashing with a real LB |

**"Same kind of thing, different names":**
- **DNAT, SNAT, MASQUERADE, ACCEPT, DROP, and a jump to `KUBE-SVC-xxx`** are all *targets* — verbs a rule invokes on match. MASQUERADE is just SNAT that auto-detects the IP.
- **KUBE-SERVICES, KUBE-SVC-xxx, KUBE-SEP-xxx, INPUT, FORWARD** are all *chains* — ordered rule lists. The KUBE-* ones are user-defined; INPUT/FORWARD are built-in and pinned to hooks.
- **`-p tcp`, `--dport 80`, `-s <cidr>`, `-m conntrack --ctstate`, `-m statistic`** are all *matches* — conditions. `-m` loads an extension match module.
- **filter, nat, mangle, raw** are all *tables* — same five hooks, different purpose and priority.

> **Check yourself before Rung 5:** `MASQUERADE`, `DNAT`, and a jump to `KUBE-SVC-ABCDEF` all appear in the target column of a rule. Which vocabulary category do all three belong to, and what single behavior distinguishes `MASQUERADE` from a plain `SNAT`?

---

## 🔬 Rung 5 — The Trace

**One concrete action:** a client pod `10.244.1.9` runs `curl http://10.96.0.10:80` where `10.96.0.10` is the ClusterIP of `my-svc`, backed by two pods `10.244.1.5:8080` and `10.244.2.7:8080`.

Step by step:

1. **App writes to a socket.** curl in the pod opens a TCP connection to `10.96.0.10:80`. The packet is born inside the pod's network namespace with `src=10.244.1.9:33456`, `dst=10.96.0.10:80`, state `NEW`.
2. **Leaves the pod via veth.** The packet exits the pod's veth into the node's host namespace and enters the node's netfilter path at **PREROUTING** (it arrived on an interface, from the host's point of view).
3. **nat PREROUTING → KUBE-SERVICES.** A rule matches `dst 10.96.0.10 tcp dport 80` and jumps to `KUBE-SVC-ABCDEF`.
4. **KUBE-SVC-ABCDEF load-balances.** First rule: `-m statistic --mode random --probability 0.50 -j KUBE-SEP-1`. Say the dice miss (>0.5); fall through to the second rule → `KUBE-SEP-2`.
5. **KUBE-SEP-2 does DNAT.** Its rule `-j DNAT --to-destination 10.244.2.7:8080` rewrites the packet's destination. Now `dst=10.244.2.7:8080`. **conntrack records this translation** so every later packet of this flow is auto-DNAT'd — no re-walk, and the same pod is used for the whole connection.
6. **Routing decision.** With the *real* destination now in place, the kernel routes: `10.244.2.7` is on another node, so this becomes a **FORWARD** packet, sent toward that node via the CNI's routes/tunnel.
7. **nat POSTROUTING → KUBE-POSTROUTING.** If the packet was marked for masquerade (cross-node, or specific egress cases), it's SNAT'd to the node IP. For plain pod-to-pod within the cluster CIDR, typically *no* masquerade (the `! -d 10.244.0.0/16` guard skips intra-cluster traffic).
8. **Reply comes back.** Pod `10.244.2.7` replies with `src=10.244.2.7:8080, dst=10.244.1.9:33456`. conntrack recognizes the flow, **un-DNATs** the reply so its source appears as `10.96.0.10:80` again — the client believes it talked to the ClusterIP the whole time. The client never learns a pod IP existed.

```
 pod 10.244.1.9                     NODE netfilter (nat)                     pod 10.244.2.7
      │                                                                          
 curl 10.96.0.10:80                                                             
      │  dst=10.96.0.10:80                                                       
      ├──────────────▶ PREROUTING ─▶ KUBE-SERVICES ─▶ KUBE-SVC-ABCDEF           
      │                                     │  statistic random p=0.5           
      │                                     ▼                                    
      │                               KUBE-SEP-2 ─ DNAT ▶ dst=10.244.2.7:8080    
      │                                     │  (conntrack remembers)            
      │                                  routing ─▶ FORWARD ─▶ POSTROUTING ──────┼─▶ arrives :8080
      │                                                                          │
      │  ◀──── un-DNAT (src shown as 10.96.0.10:80) ◀── conntrack ◀── reply ─────┘
```

The lesson: **the ClusterIP only ever exists as a match condition in step 3.** It is never an address anything binds to. The kernel swaps it for a real pod address in step 5 and swaps it back in step 8. That is the entire trick.

> **Check yourself before Rung 6:** In the trace, the reply from pod `10.244.2.7` arrives with source `10.244.2.7:8080`, yet the client sees the reply as coming from `10.96.0.10:80`. Which subsystem rewrites it back, at what moment in the packet's life, and why did the client never need to learn that a pod IP existed?

---

## ⚖️ Rung 6 — The Contrast

**The alternative you'll actually meet: IPVS mode (and, newer, eBPF).**

Before iptables there was `ipchains`/`ipfwadm` — historically interesting but gone. The live contrast for a K8s engineer is **iptables mode vs IPVS mode** of kube-proxy, plus the emerging **eBPF** approach (Cilium).

The pain of iptables mode at scale: kube-proxy builds a *linear* set of rules. With thousands of Services, `KUBE-SERVICES` becomes a long chain the kernel walks per new connection (O(n)), and every Service update means recomputing and re-applying a large ruleset. **IPVS** (IP Virtual Server) is a purpose-built in-kernel L4 load balancer using hash tables — O(1) lookup, real scheduling algorithms (round-robin, least-conn), and faster sync at scale.

| Dimension | iptables mode | IPVS mode |
|-----------|---------------|-----------|
| Data structure | Sequential rule chains | Hash tables |
| Lookup cost per conn | O(n) in # Services | O(1) |
| Load-balancing algo | Random (statistic match) | rr, lc, sh, dh, etc. |
| Behavior at 5k+ Services | Sync latency grows, rules bloat | Scales smoothly |
| Still uses netfilter? | It *is* netfilter | Yes — for MASQUERADE/mark; needs `ip_vs` modules |
| Debug tooling | `iptables -t nat -L` | `ipvsadm -Ln` |
| Ubiquity / simplicity | Default, everywhere, well-understood | Needs kernel modules loaded |

- **What iptables can do that IPVS can't (cleanly):** arbitrary stateful *filtering* — it's a full firewall language, not just a load balancer. NetworkPolicy, mangle/mark, raw NOTRACK all live here. IPVS is *only* the LB; it still leans on iptables/netfilter for masquerade and marking.
- **What IPVS does that iptables can't:** scale to thousands of Services without O(n) per-connection walks, and offer real scheduling algorithms.
- **iptables-nft vs legacy:** modern distros (Ubuntu 22.04, RHEL 8+) ship `iptables` as a *thin wrapper over `nftables`* (the newer kernel packet framework). `iptables-nft` speaks the classic command syntax but writes to the nft backend; `iptables-legacy` writes to the original `xt_tables`. They use *different* kernel tables and **don't see each other's rules** — a real footgun if kube-proxy uses one and your manual rules use the other. Check with `iptables --version` (it prints `nf_tables` or `legacy`) and switch with `update-alternatives --config iptables`.

**When would I NOT need this?** If your cluster runs a fully eBPF dataplane (Cilium in kube-proxy-replacement mode), Service handling moves into eBPF programs and the giant KUBE-* iptables tree largely disappears — you'd debug with `cilium` tooling, not `iptables -t nat -L`.

**Why this over that (one sentence):** Use iptables mode because it's the universal, zero-dependency default that doubles as a full firewall; reach for IPVS or eBPF only when Service count or connection churn makes the linear rule walk your bottleneck.

> **Check yourself before Rung 7:** kube-proxy in iptables mode uses `statistic --mode random --probability` for load balancing, which is stateless per-*rule*. Why does a single TCP connection still stick to *one* pod for its entire lifetime rather than getting re-randomized on every packet?

---

## 🧪 Rung 7 — The Prediction Test

Hands-on. For each: commit to the prediction *first*, then run, then verify. Run on a Linux node with `sudo`. On a Kubernetes node, the KUBE-* chains only exist if kube-proxy is in iptables mode.

> ⚠️ Adding `filter` rules on a live node can lock you out or break pod traffic. Do experiments 1–2 on a throwaway VM. Experiments 3–5 are read-only inspection — safe on a real node.

### Example 1 — Normal case: a stateful INPUT firewall

**Prediction:** If I set the INPUT policy to DROP but first allow ESTABLISHED,RELATED and new SSH+HTTP, then existing sessions survive and new web/ssh connections work, BECAUSE conntrack lets replies through without me writing return rules, and only `NEW` packets need explicit allows.

```bash
# order matters: allow existing flows and loopback BEFORE flipping policy to DROP
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -P INPUT DROP            # -P sets the chain POLICY (default verdict)

sudo iptables -L INPUT -n -v           # -n = numeric (no DNS), -v = counters + interfaces
# Chain INPUT (policy DROP 0 packets, 0 bytes)
#  pkts bytes target  prot opt in  out  source      destination
#     3   180 ACCEPT  all  --  lo  *    0.0.0.0/0   0.0.0.0/0
#    42  6300 ACCEPT  all  --  *   *    0.0.0.0/0   0.0.0.0/0   ctstate ESTABLISHED,RELATED
#     1    60 ACCEPT  tcp  --  *   *    0.0.0.0/0   0.0.0.0/0   tcp dpt:22 ctstate NEW
#     0     0 ACCEPT  tcp  --  *   *    0.0.0.0/0   0.0.0.0/0   tcp dpt:80
```

**Verify:** Your existing SSH session stays alive (it's ESTABLISHED). Open a *new* SSH and a `curl` to port 80 — both work; everything else is silently dropped. Watch the `pkts` counters climb on the matching rule with repeated `-L -n -v`. **A wrong result** (locked out) almost always means you flipped the policy to DROP *before* the ESTABLISHED rule was in place — proof that order and the conntrack allow are what make stateful firewalling humane. Flush with `sudo iptables -P INPUT ACCEPT && sudo iptables -F INPUT` to recover.

### Example 2 — Edge/failure case: DNAT without the conntrack return path

**Prediction:** If I DNAT port 8080→80 but the reply path can't be un-NAT'd, connections hang; and if I inspect conntrack I'll *see* the translation the kernel is remembering, BECAUSE DNAT is recorded per-flow in the conntrack table and the reply must traverse the same box to be reversed.

```bash
# redirect local traffic hitting :8080 to a service on :80 (OUTPUT for locally-generated)
sudo iptables -t nat -A OUTPUT -p tcp -o lo --dport 8080 -j DNAT --to-destination 127.0.0.1:80
# run a quick server on 80 in another shell:  sudo python3 -m http.server 80
curl -s http://127.0.0.1:8080/ -o /dev/null -w "%{http_code}\n"   # -> 200 if :80 is serving

sudo conntrack -L -p tcp --dport 8080 2>/dev/null
# tcp 6 ... src=127.0.0.1 dst=127.0.0.1 sport=... dport=8080
#           src=127.0.0.1 dst=127.0.0.1 sport=80 dport=...   [ASSURED]
#                          ^^ reply tuple shows the DNAT: replies come from :80
```

**Verify:** The two-line conntrack entry is the whole point — the *original* tuple has `dport=8080`, the *reply* tuple has `sport=80`. That mirrored pair is exactly how the kernel un-DNATs the response. If you had no listener on 80, `curl` returns `000`/connection refused and conntrack shows the flow but no successful reply — teaching you that DNAT only rewrites the address; something must actually be *listening* at the target. Clean up: `sudo iptables -t nat -F OUTPUT`. (Install the tool with `apt install conntrack` on Debian/Ubuntu; `dnf install conntrack-tools` on RHEL/Fedora.)

### Example 3 — Kubernetes case: read the ClusterIP DNAT chain kube-proxy wrote

**Prediction:** If I dump the `nat` table on a node, I'll find my Service's ClusterIP in `KUBE-SERVICES`, a `KUBE-SVC-xxx` chain that splits traffic by `statistic random probability`, and `KUBE-SEP-xxx` chains each doing a DNAT to a pod IP:port, BECAUSE that three-level nesting *is* how a ClusterIP is implemented.

```bash
# the full nat table — big on a real node; this is your map
sudo iptables -t nat -L -n -v | less

# find your Service's VIP entry (the comment carries namespace/name)
sudo iptables -t nat -L KUBE-SERVICES -n | grep -i 'cluster ip'
# ... KUBE-SVC-ABCDEF ... tcp dpt:80 /* default/my-svc cluster IP */ ... 10.96.0.10

# the per-Service load balancer: note the statistic match
sudo iptables -t nat -L KUBE-SVC-ABCDEF -n
# Chain KUBE-SVC-ABCDEF (1 references)
#  target       prot opt source     destination
#  KUBE-SEP-1   all  --  0.0.0.0/0  0.0.0.0/0   statistic mode random probability 0.50000000000
#  KUBE-SEP-2   all  --  0.0.0.0/0  0.0.0.0/0

# the per-endpoint chain: the actual DNAT to a pod
sudo iptables -t nat -L KUBE-SEP-1 -n
# Chain KUBE-SEP-1 (1 references)
#  target       prot opt source        destination
#  KUBE-MARK-MASQ all  --  10.244.1.5  0.0.0.0/0    /* mark hairpin traffic */
#  DNAT         tcp  --  0.0.0.0/0     0.0.0.0/0    tcp to:10.244.1.5:8080
```

**Verify:** The chain names must line up: `KUBE-SERVICES` → `KUBE-SVC-ABCDEF` → `KUBE-SEP-1`/`KUBE-SEP-2`, with `probability 0.5` for a 2-endpoint Service (it'd be `0.333...` for 3). The final `DNAT ... to:10.244.1.5:8080` is the pod IP `kubectl get endpointslice` should also show. **A wrong result** — no KUBE-* chains at all — means kube-proxy is in IPVS mode (check with `ipvsadm -Ln` and `kubectl -n kube-system get cm kube-proxy -o yaml | grep mode`) or you're on an eBPF dataplane. If the SEP DNAT points at a pod IP that's no longer in the EndpointSlice, you've found a kube-proxy sync lag bug — exactly the "scaled 3→0→3, some clients hang" ticket from Rung 0.

### Example 4 — Kubernetes case: the pod-egress MASQUERADE rule

**Prediction:** If I inspect POSTROUTING, I'll find a MASQUERADE rule for traffic *from* the pod CIDR going *outside* the pod CIDR, BECAUSE pod IPs aren't routable off-cluster, so the node must rewrite the source to its own IP for external traffic — but *not* for pod-to-pod.

```bash
sudo iptables -t nat -L POSTROUTING -n -v
# ... KUBE-POSTROUTING  all -- ... /* kubernetes postrouting rules */

sudo iptables -t nat -L KUBE-POSTROUTING -n -v
# masquerades packets carrying the 0x4000 mark set by KUBE-MARK-MASQ

# the classic hand-written equivalent (what a simple CNI / kubeadm-style setup adds):
# "source is in pod CIDR AND destination is NOT in pod CIDR  ->  masquerade"
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 ! -d 10.244.0.0/16 -j MASQUERADE
#                                    └─ src pod CIDR   └─ NOT to pod CIDR  └─ SNAT to egress IP
```

**Verify:** The `-s 10.244.0.0/16 ! -d 10.244.0.0/16` guard is the teaching moment: the `!` negates the destination match, so *intra-cluster* pod-to-pod traffic (dst also in the pod CIDR) is **excluded** from masquerade and keeps its real pod source — which is why NetworkPolicy and pod-identity still work east-west. Only traffic *leaving* the pod network gets its source hidden behind the node IP. If you (wrongly) masqueraded pod-to-pod too, every packet would appear to come from the node and per-pod policy/identity would collapse.

### Example 5 — Snapshot everything for diffing / backup

**Prediction:** If I run `iptables-save`, I get the entire ruleset as a replayable text blob across all tables, BECAUSE that's the serialization format `iptables-restore` reads — the canonical way to snapshot, diff, or migrate rules.

```bash
sudo iptables-save > /tmp/ipt-before.txt      # dumps ALL tables in restore format
# ... deploy a new Service, then:
sudo iptables-save > /tmp/ipt-after.txt
diff /tmp/ipt-before.txt /tmp/ipt-after.txt   # exactly which KUBE-* lines kube-proxy added
```

**Verify:** The `diff` shows a fresh `KUBE-SVC-*` chain and `-A KUBE-SERVICES ...` line appearing after you create a Service — you're literally watching kube-proxy program netfilter. `iptables-save` output tagged `# Generated by iptables-nft-save` vs `iptables-legacy-save` also tells you which backend (Rung 6) is authoritative on this node — the fastest way to catch the nft/legacy split footgun.

---

## 🏔 Capstone — Compress It

**One sentence:** Netfilter is five in-kernel packet hooks where ordered iptables rules match packets and jump to targets that accept, drop, or rewrite them — and a Kubernetes Service is nothing more than a tree of such rules (`KUBE-SERVICES → KUBE-SVC → KUBE-SEP`) that DNATs a virtual ClusterIP to a real pod.

**Three-sentence beginner explanation:** The Linux kernel checks every packet at fixed checkpoints; at each checkpoint you can install rules that say "if the packet looks like *this*, do *that*" — allow it, block it, or rewrite its address. Connection tracking remembers each flow so the kernel only fully checks the first packet and automatically handles the rest, including reversing any address rewrite on the reply. Kubernetes' kube-proxy writes these rules automatically so that a Service's fake IP gets rewritten to a real pod's IP, load-balanced across pods, and hidden behind the node's IP when leaving the cluster.

**Sub-capabilities → the one core idea** ("hooks → rules(matches) → targets, grouped into tables"):
| Sub-capability | Which piece of the one idea |
|----------------|------------------------------|
| ClusterIP routing | DNAT *target* at the PREROUTING/OUTPUT *hook*, in the `nat` *table* |
| Load balancing across pods | `statistic` *match* choosing among *jump* targets |
| Pod egress to internet | MASQUERADE *target* at POSTROUTING |
| Stateful firewalling | `conntrack` *match* on ctstate feeding ACCEPT/DROP *targets* |
| NetworkPolicy | CNI-written ACCEPT/DROP *rules* in the `filter` *table* |
| Sticky per-connection routing | conntrack remembering the DNAT so `nat` runs once per flow |

**Which rung to revisit hands-on:** Rung 7, Examples 3 & 4 — reading `KUBE-SVC`/`KUBE-SEP` chains and the MASQUERADE guard on a live cluster is the muscle memory that turns "Service is broken" tickets from magic into a five-minute `iptables -t nat -L` investigation. If the machinery of *why DNAT is early and SNAT is late* still feels fuzzy, re-walk the Rung 3 diagram and the Rung 5 trace together.

---

## Related concepts

- [networking](11-networking.md) — IPs, ports, `ip`/`ss`, the packet basics netfilter operates on
- [namespaces](13-namespaces.md) — pod network namespaces and veth pairs the packets traverse
- [cgroups](14-cgroups.md) — the other half of what makes a pod; resource limits vs network control
- [kernel-tuning-boot](24-kernel-tuning-boot.md) — `ip_forward`, `nf_conntrack_max`, and sysctls netfilter depends on
- [tls-pki-openssl](26-tls-pki-openssl.md) — what rides *inside* the connections netfilter routes
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full Linux↔Kubernetes primitive map and node triage
