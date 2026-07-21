# Firewalls, Security Groups & NACLs

*The bouncer at every door — how a set of rules decides which packets get in, which get out, and why AWS makes you configure the same idea twice.*

---

## 🎬 Rung 0 — The Setup

**What am I learning?** How a **firewall** — a rule engine that permits or drops traffic based on IP, port, protocol, and connection *state* — protects a host, a subnet, or a whole VPC. You'll learn the split between **stateful** firewalls (which remember connections) and **stateless** ones (which judge every packet cold), and how AWS packages both ideas as **Security Groups** (stateful, per-instance) and **Network ACLs** (stateless, per-subnet). Underneath it all sits the same Linux machinery you already have on every node: **iptables/nftables**.

**Why did it land on my desk?** Pick the one that stings:

- You deployed a pod behind an internal ALB, `kubectl get pods` says `Running`, the target group health check is **failing**, and after an hour you discover the node's **Security Group** never allowed the ALB's health-check port. The app was fine. The *guest list* was wrong.
- A security review flagged that your worker-node SG allows `0.0.0.0/0` on port **22**. "Why can the whole internet SSH to our nodes?" You now need to explain SGs vs NACLs and fix it without locking yourself out.
- Your app tried to send email and it silently hung. Someone eventually mentions AWS **blocks outbound port 25** by default. You need to understand *why that block exists* and where it lives.
- You added a **deny** rule and it didn't work — because you put it in a Security Group, which has **no deny rules**. You needed a NACL. Now you need to know which tool does what.

**What do I already know?** More than you think:

- A packet carries a **source IP + port** and a **destination IP + port**, plus a protocol (TCP/UDP/ICMP). See [04-ports-sockets-multiplexing.md](04-ports-sockets-multiplexing.md).
- TCP opens with a **3-way handshake** (SYN → SYN-ACK → ACK) and closes with FIN. That handshake is the "connection" a *stateful* firewall tracks. See [07-transport-layer-tcp-udp.md](07-transport-layer-tcp-udp.md).
- A **subnet** is a CIDR range (`10.0.1.0/24` = 254 usable hosts). NACLs guard the subnet boundary. See [03-subnetting-and-cidr.md](03-subnetting-and-cidr.md).
- **NAT** rewrites addresses at the VPC edge. See [14-nat-and-pat.md](14-nat-and-pat.md). A firewall *filters*; NAT *translates*. Different jobs, often the same box.

A firewall sits **inline** on the path — every packet must pass through it to reach the app. It is, quite literally, the **last line of defense before your application code runs**.

```
   INTERNET
      │
      ▼
  ┌────────────────────────────────────────────────┐
  │  Firewall layers a packet crosses in a VPC      │
  │                                                 │
  │   NACL (subnet edge)  → stateless, allow+deny   │
  │        │                                        │
  │   Security Group (ENI) → stateful, allow-only   │
  │        │                                        │
  │   iptables (in the OS) → kube-proxy, host rules │
  │        │                                        │
  │   your app  ←── the packet finally arrives      │
  └────────────────────────────────────────────────┘
```

---

## 🔥 Rung 1 — The Pain

Before firewalls, a networked machine was **open by default**. If a process bound to a port, anyone who could route a packet to that IP could talk to it. Your database on port 3306, your admin panel on 8080, your SSH on 22 — all reachable by the entire internet the moment the machine had a public IP.

### What people did before, and why it hurt

**Option A — "just don't run services you don't want exposed."** This fails instantly. Real hosts run dozens of listeners: SSH for admin, a metrics agent, a database, a message queue. You *need* them running, but you only want *some* clients reaching *some* of them. "Turn it off" isn't a policy; it's surrender.

**Option B — bake access control into every application.** Make Postgres check the client IP, make the admin panel check a source range, make SSH restrict by address. Now every app reimplements the same IP/port filtering, in different config formats, with different bugs, maintained by different teams. One app forgets, and that's your breach. (This is the *exact* same "logic scattered into every app" pain that pushed service meshes to exist — see the Istio ladder.)

**Option C — a perimeter box only.** Put one hardware firewall at the building's front door. Better, but now the inside is a **soft chewy center**: once an attacker is past the perimeter (a compromised web server, a malicious pod), *nothing* stops them from reaching the database, because internal traffic was never filtered. This is the failure mode every "flat network" breach exploits.

```
   THE FLAT-NETWORK PAIN

   [ perimeter firewall ]  ← the only guard
          │
   ┌──────┴──────────────────────────────┐
   │  web   app   db   admin   queue      │   ← inside: no doors, no walls
   │   ●─────●─────●─────●───────●         │   one foothold = reach everything
   └──────────────────────────────────────┘
```

### What breaks without it

- **No default-deny.** Every new host is exposed the instant it boots. You're one `apt install` away from an open service.
- **No blast-radius control.** A compromised web pod can scan and hit your database directly.
- **No auditability.** "What can talk to the payments service?" has no answer — it's whatever the app authors happened to code.

**Who feels the pain most?** The **platform/security engineer** (you). Developers assume the network is safe. When the auditor asks "prove the database is only reachable from the app tier," or when an incident asks "how did they pivot from web to db," it's you holding the bag. A firewall turns "trust everyone inside" into an **explicit, reviewable list of who may talk to whom.**

> **✅ Check yourself before Rung 2:** A perimeter-only firewall still let internal breaches spread. From that fact alone, derive *why* AWS gives you a firewall at the **subnet** level (NACL) *and* another at the **instance** level (SG), instead of just one at the VPC edge.

---

## 💡 Rung 2 — The One Idea

Here it is. Memorize this exact sentence — everything else is derived from it:

> **A firewall is a guest list checked at a door: each packet is matched against ordered rules of {direction, protocol, port, source/destination IP}, and either allowed or dropped — and a *stateful* firewall also remembers connections it already approved so the reply is auto-allowed.**

That's the whole trick. A **security guard with a clipboard** standing at a door. Every packet walks up; the guard checks the list; you're in or you're turned away.

### Why this sentence lets you derive the rest

Watch how much falls out:

- *"a guest list"* → the **ruleset**. Rules = the names on the list.
- *"checked at a door"* → firewalls are **inline**; there's an **inbound** door and an **outbound** door, each with its own list.
- *"either allowed or dropped"* → and if a packet matches nothing? That's your **default policy**. Good security = **default-deny** (not on the list ⇒ turned away).
- *"remembers connections it already approved"* → **stateful**. The guard wrote down "I let Alice in at 9:02," so when Alice walks back out with a reply, he doesn't re-check. A **stateless** guard has amnesia — he checks Alice *both* directions, so you must put her on *both* lists.
- Everything AWS gives you is just **this guard configured two ways**: the **Security Group** is a *stateful* guard chained to your instance; the **NACL** is a *stateless* guard standing at the subnet gate who can also keep a *ban list* (deny rules).

Once you see that **SG, NACL, and iptables are the same guard with different memory and different posts**, the cloud console stops being three unrelated screens and becomes one idea applied three times.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then answer: if a firewall is *stateless*, why does allowing an inbound web request on port 443 still leave the browser unable to receive the reply — and what second rule fixes it?

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture a nightclub with bouncers. Every piece of internet traffic is a guest trying to get in or out, and the bouncers work from lists. This section explains four things:
>
> **A. What the bouncer actually looks at (the "5-tuple").** Every message on a network carries five facts: what kind of message it is, who sent it (their address and door number), and who it's for (address and door number). Those door numbers are called "ports" — think of them as numbered service windows on a building. Famous windows have fixed numbers everyone knows (like window 443 for secure websites); the sender, meanwhile, uses a random high-numbered window (an "ephemeral port") just for that one conversation. Rules are written against these five facts: "secure-web traffic, to window 443, from anywhere — let it in."
>
> **B. Bouncers with memory vs bouncers with amnesia ("stateful" vs "stateless").** A stateful bouncer keeps a notebook. When he lets a guest in, he writes it down — so when the reply walks back out, he recognizes the conversation and waves it through without re-checking. A stateless bouncer has no notebook: every guest, coming or going, gets checked against the list from scratch. That means with a stateless bouncer you must write TWO rules — one letting the request in, and one letting the reply back out through those random high-numbered windows — or replies get silently thrown away. This one difference IS the difference between AWS's two products: a "Security Group" is the bouncer with the notebook; a "NACL" is the one with amnesia.
>
> **C. Two doors, and what happens to strangers.** There's an entry door (who may reach me?) and an exit door (where may I reach?), each with its own list. And there's a house policy for anyone matching no rule: the safe policy is "not on the list, not getting in" ("default-deny"). AWS's out-of-the-box stance for a new machine: nobody gets in, but the machine may call out to anywhere (except sending old-style email, which AWS blocks for everyone to fight spam).
>
> **D. Layers of bouncers ("defense in depth").** A message reaching your app actually passes THREE checkpoints in a row: first the neighborhood gate guard (the NACL, watching the whole subnet — a block of addresses), then the front-door bouncer on the machine itself (the Security Group), then a final check inside the house by the operating system's own built-in filter (called "iptables"). Any one of them can reject the message, so one team's mistake is caught by another layer. Two quirks worth knowing: the Security Group's list is allow-only and unordered — if ANY rule says yes, you're in, and there's no "ban" rule at all (you ban by simply not inviting). The NACL's list IS ordered — rules are numbered, the first match wins, and it can hold explicit bans, with a catch-all "deny everyone else" at the bottom.

*Now the original technical deep-dive — the same ideas, in precise form:*

We now open the hood. This is the rung that makes everything else obvious, so go slow. Four things to understand: **(A) the 5-tuple a rule matches, (B) stateful vs stateless — the connection-tracking table, (C) inbound vs outbound and default-deny, and (D) how AWS SGs and NACLs actually layer.**

### (A) What a rule actually matches: the 5-tuple

Every rule inspects the same handful of fields in the packet header:

```
   ┌─────────────────────────────────────────────────────┐
   │  ONE PACKET, THE FIELDS A FIREWALL READS             │
   │                                                      │
   │   protocol : TCP                                     │
   │   src IP   : 203.0.113.9      src port : 51514 (eph) │
   │   dst IP   : 10.0.1.20        dst port : 443  (https)│
   │                                                      │
   │   A rule says: "protocol=TCP, dst port=443,          │
   │                 src=0.0.0.0/0  → ALLOW"              │
   │   Match all fields? → verdict applies.               │
   └─────────────────────────────────────────────────────┘
```

That grouping — *(protocol, src IP, src port, dst IP, dst port)* — is called the **5-tuple**, and it uniquely identifies a flow. Firewalls, NAT tables, and load balancers all key off it. Ports below 1024 are **well-known** (22 SSH, 25 SMTP, 53 DNS, 80 HTTP, 443 HTTPS, 3306 MySQL, 5432 Postgres, 6443 kube-apiserver, 10250 kubelet, 2379 etcd). The *client's* source port is a high **ephemeral** port (Linux default range 32768–60999). Remember that ephemeral fact — it's the whole reason stateless firewalls are painful.

### (B) Stateful vs stateless — the connection-tracking table

This is the single most important distinction in the whole file.

A **stateful** firewall keeps a **connection-tracking table** (on Linux this is literally `nf_conntrack`). When it *allows* an outbound or inbound flow, it writes down the 5-tuple. When a packet arrives, it first asks: **"is this part of a connection I already approved?"** If yes → allow, no rule check needed. Only *new* connections get matched against rules.

```
   STATEFUL FIREWALL (has memory)

   1) Browser → server  SYN  dst:443
      Guard checks inbound list: "443 allowed" ✓
      Guard WRITES to conntrack:  203.0.113.9:51514 ↔ 10.0.1.20:443  ESTABLISHED
                                     ┌────────────────────────────┐
                                     │  conntrack table           │
                                     │  ...:51514 ↔ ...:443  EST   │
                                     └────────────────────────────┘
   2) server → browser  SYN-ACK  (reply, src:443 dst:51514)
      Guard: "do I know this flow?"  YES → AUTO-ALLOW
      NO outbound rule for port 51514 was ever needed.  ← the magic
```

A **stateless** firewall has **no table**. Every packet is judged alone. The SYN-ACK reply above (source port 443, destination the browser's ephemeral 51514) is a *brand new packet* as far as it's concerned. So you must write a **second rule** allowing outbound traffic to the ephemeral range:

```
   STATELESS FIREWALL (amnesia)

   inbound  rule: allow TCP dst 443 from 0.0.0.0/0      ← lets the request in
   OUTBOUND rule: allow TCP dst 1024–65535 to 0.0.0.0/0 ← you MUST add this,
                                                          or the reply is dropped
   (you configure BOTH directions by hand — the "return traffic" is not free)
```

**This is the entire SG-vs-NACL difference in one picture.** A Security Group is stateful (allow inbound 443, replies flow automatically). A NACL is stateless (allow inbound 443 *and* allow outbound to ephemeral ports 1024–65535, or return traffic dies).

### (C) Inbound vs outbound, and default-deny

Two independent doors, two independent lists:

- **Inbound (ingress):** packets arriving *at* the resource. "Who may reach me?"
- **Outbound (egress):** packets leaving *from* the resource. "Where may I reach?"

And the crucial policy question: **what happens to a packet that matches no rule?**

- **Default-deny** (the secure posture): unmatched ⇒ **drop**. You explicitly list what's allowed; everything else is refused. This is how SGs behave inbound, and how a good NACL/iptables chain ends (`... DROP`).
- **Default-allow:** unmatched ⇒ permit. Convenient, dangerous, and how too many home routers ship.

AWS bakes a specific default posture into every new Security Group: **deny all inbound, allow all outbound.** A fresh instance can reach out to anything but nothing can reach in until you add an inbound rule. (The one famous asterisk: AWS *also* blocks **outbound TCP port 25** at the platform level regardless of your SG — the anti-spam story in Rung 6.)

### (D) How AWS layers the two guards — defense in depth

Here is the packet's real journey into an EKS worker node, and where each guard stands:

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │                         ONE VPC, TWO GUARDS + THE OS                   │
  │                                                                        │
  │   Internet ──► IGW ──► [ subnet 10.0.1.0/24 ]                          │
  │                                                                        │
  │        ╔═══════════════════════════════════════════════╗              │
  │        ║  NACL  (STATELESS, subnet edge)                ║   guard #1   │
  │        ║  ordered numbered rules, ALLOW *and* DENY      ║   at the     │
  │        ║  rule 100 allow 443 ... rule 200 deny 22 ...   ║   gate       │
  │        ╚═══════════════════════════════════════════════╝              │
  │                        │  (passed the subnet gate)                     │
  │                        ▼                                               │
  │        ┌───────────────────────────────────────────────┐              │
  │        │  EC2 / EKS node  (an ENI = a network card)     │              │
  │        │  ╔═════════════════════════════════════════╗   │   guard #2   │
  │        │  ║ Security Group (STATEFUL, on the ENI)   ║   │   at the     │
  │        │  ║ allow-only, evaluated as a whole set    ║   │   door       │
  │        │  ╚═════════════════════════════════════════╝   │              │
  │        │        │                                       │              │
  │        │        ▼                                       │              │
  │        │  ╔═════════════════════════════════════════╗   │   guard #3   │
  │        │  ║ iptables / nftables (the Linux kernel)  ║   │   inside     │
  │        │  ║ kube-proxy DNAT, host firewall rules    ║   │   the house  │
  │        │  ╚═════════════════════════════════════════╝   │              │
  │        │        │                                       │              │
  │        │        ▼   pod / app finally receives packet   │              │
  │        └───────────────────────────────────────────────┘              │
  └──────────────────────────────────────────────────────────────────────┘
```

Three independent checks, each of which can drop the packet. That redundancy **is** defense-in-depth: an over-broad SG is still backstopped by a NACL, and a subnet-wide NACL allow is still narrowed by a per-instance SG. In-cluster, a fourth guard exists — the Kubernetes **NetworkPolicy**, enforced by your CNI (Calico/Cilium) via iptables/eBPF — but that's its own file: [28-kubernetes-network-policies.md](28-kubernetes-network-policies.md).

**Two AWS-specific mechanics you must internalize:**

1. **SG rules are evaluated as an unordered *set* — pure OR.** There is no "rule 1 beats rule 2." If *any* rule allows the packet, it's allowed. There are **no deny rules** in an SG; you deny something by simply *not allowing* it. SGs also allow referencing *another SG* as the source ("allow from anything wearing the `alb-sg` badge") instead of a CIDR — that's how ALB→node and node→node rules stay stable as IPs churn.

2. **NACL rules are evaluated in *ascending number order*, first match wins, and include an explicit `*` DENY at the bottom.** Rule 100 is checked before rule 200. The moment a rule matches, evaluation stops. So a `deny` at rule 90 beats an `allow` at rule 100. This ordering is why people leave gaps (100, 200, 300) — room to insert rules later.

> **✅ Check yourself before Rung 4:** A Security Group has **no deny rules**, yet security teams rely on it constantly. Using default-deny, explain how you "block" an IP with an SG — and then explain the one thing a NACL can do that an SG fundamentally cannot.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Firewall** | A rule engine that permits/drops packets by header fields | The inline guard at the door |
| **Stateful** | Firewall that tracks connections; return traffic auto-allowed | The conntrack table (B) |
| **Stateless** | Firewall that judges each packet alone; both directions needed | No table — per-packet match (B) |
| **Connection tracking (`nf_conntrack`)** | Kernel table of active flows and their state | The "memory" that makes stateful work |
| **5-tuple** | (proto, src IP, src port, dst IP, dst port) identifying a flow | The fields every rule matches (A) |
| **Inbound / ingress rule** | Rule for packets arriving at the resource | The "who may reach me" door (C) |
| **Outbound / egress rule** | Rule for packets leaving the resource | The "where may I go" door (C) |
| **Default-deny** | Unmatched packet is dropped | The secure fall-through policy (C) |
| **Security Group (SG)** | AWS **stateful** firewall on an ENI; allow-only; set-evaluated | Guard #2 in (D) |
| **ENI (Elastic Network Interface)** | The virtual NIC an SG attaches to | Where the SG physically sits |
| **Network ACL (NACL)** | AWS **stateless** firewall at the subnet edge; ordered; allow+deny | Guard #1 in (D) |
| **NACL rule number** | Integer priority; lowest matching number wins | Ordered evaluation (D-2) |
| **Ephemeral ports (1024–65535 / 32768–60999)** | High source ports clients use | Why stateless NACLs need an outbound rule (B) |
| **iptables / nftables** | The Linux kernel packet filter (netfilter) | Guard #3, the host firewall (D) |
| **Security Groups for Pods** | AWS feature giving individual pods their own SG via branch ENIs | SG at pod granularity on EKS |
| **NetworkPolicy** | Kubernetes L3/L4 pod firewall, enforced by the CNI | Guard #4, in-cluster ([28](28-kubernetes-network-policies.md)) |
| **Defense in depth** | Multiple independent filters on one path | The whole SG+NACL+iptables stack (D) |

### Same idea, different names

- **"Stateful" ≈ "connection-aware" ≈ Security Group ≈ Linux `conntrack`/`ESTABLISHED,RELATED`.** All mean: *the reply to something I allowed comes back for free.*
- **"Stateless" ≈ "per-packet" ≈ NACL ≈ a bare `iptables` ACCEPT with no state match.** All mean: *you configure both directions by hand.*
- **"Firewall rule" ≈ SG rule ≈ NACL entry ≈ iptables rule ≈ NetworkPolicy ingress/egress rule.** Five product names, **one guest-list entry**: match some header fields, render a verdict.
- **"Default-deny" ≈ "implicit deny" ≈ the NACL `*` rule ≈ an iptables chain `-P DROP` policy ≈ NetworkPolicy's "a pod becomes isolated once selected."** One posture: *not on the list ⇒ out.*

> **✅ Check yourself before Rung 5:** Without looking up, name the two AWS objects that are "the same guard with different memory," say which one keeps a ban list, and state which layer (subnet or instance) each guards.

---

## 🔬 Rung 5 — The Trace

Let's follow **one HTTPS request from a laptop on the internet to an app pod on an EKS node**, and watch every guard render a verdict. Assume: node ENI in subnet `10.0.1.0/24`, node IP `10.0.1.20`, laptop `203.0.113.9`, app listening on `443`.

**Setup rules:**
- **NACL** (subnet): rule 100 `allow TCP 443 from 0.0.0.0/0` inbound; rule 100 `allow TCP 1024-65535 to 0.0.0.0/0` outbound. Bottom `*` = DENY.
- **SG** (node ENI): inbound `allow TCP 443 from 0.0.0.0/0`. Outbound: default `allow all`.

```
  STEP-BY-STEP: laptop 203.0.113.9  →  pod on node 10.0.1.20:443

  ┌ 1. Laptop sends SYN ─────────────────────────────────────────────┐
  │    src 203.0.113.9:51514  dst 10.0.1.20:443  proto TCP  flag SYN  │
  └──────────────────────────────────────────────────────────────────┘
            │ crosses IGW, TTL decrements each hop
            ▼
  ┌ 2. NACL inbound (STATELESS) ─────────────────────────────────────┐
  │    Walk rules ascending: rule 100 allow 443 from 0.0.0.0/0 ✓ MATCH│
  │    → PASS. (No memory written — it will re-check the reply later.)│
  └──────────────────────────────────────────────────────────────────┘
            ▼
  ┌ 3. Security Group inbound (STATEFUL) ────────────────────────────┐
  │    Any rule allow it? "allow 443 from 0.0.0.0/0" ✓ → ALLOW        │
  │    conntrack WRITES: 203.0.113.9:51514 ↔ 10.0.1.20:443  NEW→EST   │
  └──────────────────────────────────────────────────────────────────┘
            ▼
  ┌ 4. iptables / kube-proxy (STATEFUL host) ────────────────────────┐
  │    conntrack sees NEW; DNAT to pod IP 10.244.3.7:443; ACCEPT      │
  └──────────────────────────────────────────────────────────────────┘
            ▼
        POD RECEIVES SYN → app replies with SYN-ACK
            │  src 10.0.1.20:443  dst 203.0.113.9:51514
            ▼
  ┌ 5. SG outbound (STATEFUL) ───────────────────────────────────────┐
  │    "Do I know this flow?" conntrack: YES (ESTABLISHED)            │
  │    → AUTO-ALLOW. No outbound rule for 51514 needed. ← the magic   │
  └──────────────────────────────────────────────────────────────────┘
            ▼
  ┌ 6. NACL outbound (STATELESS) ────────────────────────────────────┐
  │    No memory! Judge fresh: dst port 51514 → rule 100 allow        │
  │    1024-65535 to 0.0.0.0/0 ✓ MATCH → PASS.                        │
  │    (Forget this outbound rule and the reply DIES here.)           │
  └──────────────────────────────────────────────────────────────────┘
            ▼
      Laptop gets SYN-ACK → sends ACK → handshake done → TLS begins
```

**The lesson in one glance:** at steps **3 & 5** (the SG) the return path was *free* because it's stateful. At steps **2 & 6** (the NACL) the return path was a *separate, hand-written rule* because it's stateless. Delete the NACL's outbound ephemeral-range rule and the request arrives but the reply is silently dropped — the classic "connection hangs, no error" symptom that sends engineers hunting for hours.

> **✅ Check yourself before Rung 6:** In the trace, the SG needed **zero** outbound rules for the reply but the NACL needed a whole rule for ports 1024–65535. Explain, from the conntrack mechanism, exactly why those two "guards" behaved differently on the *same* return packet.

---

## ⚖️ Rung 6 — The Contrast

### Security Group vs Network ACL — the head-to-head

| Dimension | **Security Group** | **Network ACL** |
|---|---|---|
| State | **Stateful** (tracks connections) | **Stateless** (per-packet) |
| Return traffic | **Automatic** | Must add an explicit rule (ephemeral ports) |
| Scope | Instance / **ENI** (and pods, via SG-for-pods) | **Subnet** (all resources in it) |
| Rule verdicts | **Allow only** | **Allow AND Deny** |
| Evaluation | All rules as a **set** (OR; any allow wins) | **Ordered** by rule number; **first match wins** |
| Source can be | CIDR **or another SG** (badge reference) | CIDR only |
| Default (new) | Deny inbound, allow outbound | Default NACL: allow all; **custom** NACL: deny all |
| Best at | Fine-grained app-tier access ("app→db only") | Coarse subnet guardrails & **blocking a bad IP** |

### What each can do that the other cannot

- **Only a NACL can DENY.** To block a single malicious IP across an entire subnet, you add a NACL deny rule with a low number so it's evaluated first. An SG *cannot* express "block this one IP" — it only says yes, never no. (You'd have to allow *everything except* that IP, which CIDRs can't cleanly do.)
- **Only an SG can reference another SG.** "Allow from anything in `alb-sg`" survives IP churn as the ALB scales — impossible with a CIDR-only NACL. This is the backbone of stable EKS node↔node and ALB↔node rules.
- **Only an SG is per-instance.** Two instances in the same subnet can have wildly different SGs; they share one NACL.

### The default outbound port-25 story — why the guard has a permanent rule you didn't write

Port **25** is SMTP, the protocol mail servers use to relay email. Compromised cloud instances are a spammer's dream: cheap, disposable, and trusted-looking. So AWS (and GCP, Azure) **block outbound TCP port 25 by default at the platform level** — *above* your SG, so you can't just "allow 25 outbound" to fix it. It's a network-wide anti-abuse guardrail. If you have a legitimate mail-sending need you request removal of the restriction (or, far more commonly, you send through **SES / SendGrid over port 587/465** with authentication). This is the cleanest real-world example of **default-deny applied to a specific dangerous port** — the guard has a standing order that overrides your guest list.

### When would I NOT reach for these?

- **In-cluster pod-to-pod control:** SGs/NACLs operate on VPC IPs and subnets; they can't see pod identity or namespaces. Use a **NetworkPolicy** ([28](28-kubernetes-network-policies.md)) — the in-cluster analog enforced by your CNI.
- **L7 filtering (block a URL path, an SQL-injection string):** firewalls here are L3/L4. You need a **WAF** ([21-cdn-edge-waf.md](21-cdn-edge-waf.md)) or an Envoy/Istio policy.

**Why SG over NACL (or both):** reach for the **stateful, per-instance SG** for everyday app access rules because return traffic is free and rules follow the workload; add a **stateless subnet NACL** only for coarse guardrails and explicit IP bans. In practice you run **both** — that's the defense-in-depth the whole file is about.

> **✅ Check yourself before Rung 7:** Your teammate says "let's just block that attacker's IP in the app-tier Security Group." Why does that request not even make sense, and what's the correct object and rule to use instead?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **out loud before running the command.** The gap between what you predicted and what happened is where the learning is.

### Example 1 — The normal case: prove Linux is stateful (`iptables` conntrack)

**Prediction:** If I set the host firewall to *drop everything inbound except established connections and port 22*, then an **outbound** `curl` will still succeed **because** the reply comes back on an `ESTABLISHED` connection that conntrack recognizes — even though I wrote **no** rule for the reply's ephemeral port.

```bash
# Inspect the default INPUT chain and current conntrack entries.
sudo iptables -L INPUT -n -v
# View live tracked connections (the stateful "memory"):
sudo conntrack -L 2>/dev/null | head
# ...  tcp  6  431999 ESTABLISHED src=10.0.1.20 dst=93.184.216.34 sport=51514 dport=443 ...

# A stateful ruleset: allow loopback, allow replies to our own connections, allow SSH, drop the rest.
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -P INPUT DROP     # default-deny fall-through

curl -sS -m 5 https://example.com -o /dev/null -w "%{http_code}\n"   # → 200
```

**Verify:** The `curl` returns `200` even though inbound is default-DROP, because the reply matched the `ESTABLISHED,RELATED` rule — that rule *is* statefulness made visible. A wrong result (curl hangs) would mean the conntrack module isn't loaded or the rule order is off. Note `dport 22` had to be listed explicitly, proving *new* inbound connections still need a rule. See [../Linux/12-iptables-netfilter.md](../Linux/12-iptables-netfilter.md).

### Example 2 — The failure case: a stateless NACL that drops return traffic

**Prediction:** If a subnet's NACL **allows inbound 443 but has NO outbound rule for ephemeral ports 1024–65535**, then a browser's request will **arrive at the server but the reply will be dropped at the NACL**, and the connection will **hang** (no reset, no error) **because** NACLs are stateless and treat the reply as an unrelated new packet that matches only the bottom `*` DENY.

```bash
# Inspect a NACL's entries (AWS CLI). Note the ordered RuleNumber and Egress flag.
aws ec2 describe-network-acls \
  --filters Name=association.subnet-id,Values=subnet-0abc123 \
  --query 'NetworkAcls[0].Entries[].{Num:RuleNumber,Egress:Egress,Proto:Protocol,Ports:PortRange,CIDR:CidrBlock,Action:RuleAction}' \
  --output table
# +------+--------+-------+--------------+-------------+--------+
# | Num  | Egress | Proto | Ports        | CIDR        | Action |
# | 100  | False  | 6     | 443-443      | 0.0.0.0/0   | allow  |   ← inbound 443 OK
# | 32767| False  | -1    |              | 0.0.0.0/0   | deny   |   ← the implicit '*'
# | 32767| True   | -1    |              | 0.0.0.0/0   | deny   |   ← NO egress allow!
# +------+--------+-------+--------------+-------------+--------+

# The FIX: add an egress rule for the ephemeral range so replies can leave.
aws ec2 create-network-acl-entry --network-acl-id acl-0def456 \
  --rule-number 100 --egress --protocol tcp \
  --port-range From=1024,To=65535 --cidr-block 0.0.0.0/0 --rule-action allow
```

**Verify:** Before the fix, `curl -v https://<server>` from outside **stalls after `Connected`** (TCP handshake completes only if the SYN-ACK escapes — here it's dropped, so it hangs). After adding egress rule 100 the page loads. What this teaches: protocol number `6` = TCP, `-1` = all; `Egress:False` is inbound; the `32767` catch-all is the stateless default-deny. **The reply is never free in a NACL — that's the definition of stateless.**

### Example 3 — The cloud/Kubernetes case: why the EKS node SG must allow the ALB and kubelet ports

**Prediction:** If my EKS worker-node **Security Group** does not allow inbound from the **ALB's security group** on the pod's target port, then the target group health checks will **fail and the ALB will show the target `unhealthy`**, even though the pod is `Running` — **because** the SG is the last gate before the ENI and it drops the health-check probe before the app ever sees it.

```bash
# What SG is on the node's ENI, and what does it allow inbound?
aws ec2 describe-instances --instance-ids i-0node123 \
  --query 'Reservations[].Instances[].NetworkInterfaces[].Groups' --output table

aws ec2 describe-security-groups --group-ids sg-0node \
  --query 'SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,SrcSG:UserIdGroupPairs[].GroupId,SrcCIDR:IpRanges[].CidrIp}' \
  --output json
# Look for a rule allowing the ALB SG (sg-0alb) on the health-check / node port.

# Add the missing rule: allow the ALB SG to reach the NodePort range used by the target group.
aws ec2 authorize-security-group-ingress --group-id sg-0node \
  --protocol tcp --port 30000-32767 \
  --source-group sg-0alb    # reference the ALB's SG by badge, not a CIDR

# Cross-check the cluster side and the target health:
kubectl get pods -o wide          # pod is Running with an IP — app is fine
aws elbv2 describe-target-health --target-group-arn <tg-arn> \
  --query 'TargetHealthDescriptions[].TargetHealth.State'
# ["unhealthy"]  → becomes ["healthy"] after the SG rule lands
```

**Verify:** The pod being `Running` while the target is `unhealthy` is the tell — the problem is the **guard, not the app.** Kubernetes NodePort services live in **30000–32767**, so the ALB must reach the node on that range; kube-proxy then DNATs to the pod ([25-kubernetes-services-kube-proxy.md](25-kubernetes-services-kube-proxy.md)). Using `--source-group sg-0alb` instead of a CIDR means the rule keeps working as the ALB scales and its IPs change. A wrong result (still unhealthy) points you one layer out — check the **subnet NACL** or the target group's health-check port/path. This is defense-in-depth debugging: walk the guards **outside-in** (NACL → SG → iptables → app).

---

## 🏔️ Capstone — Compress It

**One sentence:** A firewall is a guest-list checked at a door — Security Groups are the stateful, allow-only guard on each instance's ENI (return traffic free), NACLs are the stateless, ordered, allow-and-deny guard on the subnet (both directions by hand), and iptables is the same guard inside the Linux kernel; layered together they are the last line of defense before your app.

**Three-sentence beginner explanation:** A firewall looks at each network packet's source, destination, port, and protocol and decides to let it through or drop it, based on a list of rules you write. A "stateful" firewall like an AWS Security Group remembers connections it already approved, so when a reply comes back it's automatically let through; a "stateless" one like an AWS Network ACL has no memory, so you have to write rules for traffic going *both* directions. AWS makes you configure a stateful guard on each server and a stateless guard on each subnet so that if one is misconfigured, the other still protects you.

**Sub-parts mapped to the One Idea ("a guest list checked at a door, with optional memory"):**

- Inbound/outbound rules → *the two doors, each with its own list.*
- 5-tuple matching → *the fields the guard reads off each guest.*
- Stateful / conntrack → *the guard's memory of who he already let in.*
- Stateless / per-packet → *the amnesiac guard who re-checks everyone both ways.*
- Default-deny → *"not on the list ⇒ turned away."*
- Security Group (stateful, ENI, allow-only, set) → *the guard chained to your door with a good memory.*
- NACL (stateless, subnet, ordered, allow+deny) → *the gate guard with a ban list but no memory.*
- iptables/nftables → *the same guard standing inside the house.*
- Port-25 block → *a standing order that overrides the guest list.*
- Defense in depth → *three guards on one hallway.*

**Which rung to revisit hands-on:** **Rung 7, Example 2.** Reading "stateless needs both directions" is easy; the concept only truly lands when you watch a `curl` **hang** because the NACL silently dropped the reply, then watch it spring to life the instant you add the ephemeral-range egress rule. Pair it with Rung 3's stateful-vs-stateless diagrams open beside you, and Rung 5's trace to see where in the path the drop happened.

---

## Related concepts

- [Ports, Sockets & Multiplexing](04-ports-sockets-multiplexing.md) — the port numbers and ephemeral ranges every firewall rule matches.
- [Transport Layer: TCP & UDP](07-transport-layer-tcp-udp.md) — the 3-way handshake and connection state a stateful firewall tracks.
- [Subnetting & CIDR](03-subnetting-and-cidr.md) — the ranges NACLs and SG rules are written in.
- [NAT & PAT](14-nat-and-pat.md) — filtering vs translating; both live at the VPC edge and key off the 5-tuple.
- [AWS VPC](20-aws-vpc.md) — where SGs, NACLs, IGW, and route tables come together.
- [Kubernetes Network Policies](28-kubernetes-network-policies.md) — the in-cluster firewall analog, enforced by the CNI.
- [Network Security & Zero Trust, IDS/IPS](30-network-security-zero-trust-ids-ips.md) — defense-in-depth and where firewalls sit in it.
- [Linux: iptables & netfilter](../Linux/12-iptables-netfilter.md) — the host firewall machinery under every SG and kube-proxy rule.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A perimeter-only firewall still let internal breaches spread. From that fact alone, derive why AWS gives you a firewall at the subnet level (NACL) *and* another at the instance level (SG), instead of just one at the VPC edge.

**A:** A perimeter-only design leaves a "soft chewy center": once an attacker gets one foothold inside (a compromised web server or pod), internal traffic is never filtered, so they can pivot freely to the database or anything else. The fix is to put guards at every boundary, not just the front door — that is defense in depth. AWS therefore stations a stateless guard at each subnet gate (the NACL) and a stateful guard on each instance's ENI (the SG), so east-west traffic inside the VPC is filtered too, and a misconfiguration in one layer is still backstopped by the other. Blast radius shrinks from "the whole VPC" to "whatever the compromised resource's own rules explicitly allow."

### Before Rung 3
**Q:** If a firewall is *stateless*, why does allowing an inbound web request on port 443 still leave the browser unable to receive the reply — and what second rule fixes it?

**A:** (The One Idea: a firewall is a guest list checked at a door — each packet matched against ordered rules of {direction, protocol, port, source/destination IP}, allowed or dropped — and a stateful firewall also remembers approved connections so replies are auto-allowed.) A stateless firewall has no connection-tracking memory, so the server's reply (SYN-ACK from source port 443 back to the browser's ephemeral source port, e.g. 51514) is judged as a brand-new, unrelated packet going in the *outbound* direction. The inbound "allow 443" rule says nothing about that outbound packet, so it falls through to the default deny and is dropped. The fix is a second, explicit outbound rule allowing TCP to the ephemeral port range 1024–65535 (to 0.0.0.0/0), so return traffic can leave. With a stateless guard, you configure both directions by hand — return traffic is never free.

### Before Rung 4
**Q:** A Security Group has no deny rules, yet security teams rely on it constantly. Using default-deny, explain how you "block" an IP with an SG — and the one thing a NACL can do that an SG fundamentally cannot.

**A:** An SG is allow-only with an implicit default-deny: anything not explicitly allowed is dropped. So you "block" with an SG by *omission* — you simply write allow rules narrow enough that the unwanted IP never matches any of them (e.g. allow 443 only from your office CIDR, not 0.0.0.0/0), and default-deny drops the rest. What an SG fundamentally cannot do is express an explicit DENY — "block this one attacker IP while still allowing everyone else" is impossible to state cleanly with allow rules and CIDRs. Only a NACL can do that: an explicit deny entry with a low rule number, evaluated first in ascending order, bans that IP for the whole subnet before any allow rule is reached.

### Before Rung 5
**Q:** Name the two AWS objects that are "the same guard with different memory," say which one keeps a ban list, and state which layer (subnet or instance) each guards.

**A:** The two objects are the **Security Group** and the **Network ACL** — the same guest-list guard configured two ways. The SG is the *stateful* guard (it remembers approved connections via conntrack, so return traffic is free) and it stands at the **instance** layer, attached to the ENI. The NACL is the *stateless* guard with amnesia, and it is the one that keeps a **ban list** — it supports explicit deny rules, evaluated in ascending rule-number order — standing at the **subnet** edge.

### Before Rung 6
**Q:** In the trace, the SG needed zero outbound rules for the reply but the NACL needed a whole rule for ports 1024–65535. Explain, from the conntrack mechanism, exactly why those two guards behaved differently on the same return packet.

**A:** When the inbound SYN (203.0.113.9:51514 → 10.0.1.20:443) passed the SG at step 3, the SG *wrote the flow's 5-tuple into its connection-tracking table* and marked it ESTABLISHED. When the SYN-ACK reply came back through at step 5, the SG first asked "is this part of a connection I already approved?", found the matching conntrack entry, and auto-allowed it — no outbound rule for port 51514 was ever consulted or needed. The NACL has no such table: at step 6 it judged the reply cold as a brand-new packet with destination port 51514, so the only thing that could save it was an explicit outbound allow rule covering the ephemeral range 1024–65535; without that rule the reply matches only the bottom `*` DENY and dies silently. Same packet, different verdict mechanics: one guard consulted its memory, the other re-checked the guest list.

### Before Rung 7
**Q:** Your teammate says "let's just block that attacker's IP in the app-tier Security Group." Why does that request not even make sense, and what's the correct object and rule to use instead?

**A:** It doesn't make sense because Security Groups have **no deny rules at all** — they are allow-only, evaluated as an unordered set where any matching allow wins. There is literally no way to write "block 203.0.113.9" in an SG; you can only fail to allow it, and if an existing broad rule (like allow 443 from 0.0.0.0/0) already matches the attacker, the traffic gets in. The correct tool is the subnet's **Network ACL**: add an explicit inbound DENY rule for the attacker's IP with a *low rule number* (e.g. rule 90, below your allows), so that in the NACL's ascending, first-match-wins evaluation the deny is hit before any allow — banning that IP for the entire subnet.
