# NAT & PAT

*How one public address can front for a thousand private ones — the concierge trick that quietly runs your VPC, your NAT Gateway, and every pod that ever reached the internet.*

---

## 🧗 Rung 0 — The Setup

**What am I learning?**

You're learning **Network Address Translation (NAT)** — the act of a device *rewriting the IP addresses (and often ports) inside a packet as it passes through*, then remembering the rewrite so it can undo it on the reply. Three flavours do all the work, and they are not synonyms:

- **SNAT — Source NAT** — rewrite the *source* address of an outbound packet. "Make this look like it came from me." This is how private hosts reach the internet.
- **DNAT — Destination NAT** — rewrite the *destination* address of an inbound packet. "You asked for this front-door address; I'll send you to the real machine behind it." This is port-forwarding, load-balancer VIPs, and Kubernetes Services.
- **PAT / masquerade — Port Address Translation** — SNAT for *many* hosts sharing *one* public IP, disambiguated by **source port**. Also called **NAPT** (Network Address Port Translation) or, on Linux, **MASQUERADE**. This is what your home router and an AWS NAT Gateway actually do.

**Why did it land on your desk?**

You're a platform engineer on EKS. Two tickets hit in the same afternoon:

1. *"The app in the private subnet can't `curl https://api.stripe.com` — but it worked from my laptop."* The pod has a `10.x` address that literally cannot exist on the internet. Something must translate it. That something is a **NAT Gateway**, and if the route table doesn't point at one, the pod is mute.
2. *"An external partner says they can't reach our pod at `10.244.3.7`."* Of course they can't — that address is private, non-routable, and shared by ten thousand other clusters on the planet. NAT is the exact reason this is impossible, and understanding NAT tells you what you *should* have handed them instead (a LoadBalancer, an Ingress, a public VIP).

Here's the thing: **NAT is not a home-router curiosity you left behind in 2010. It is the load-bearing wall of cloud networking.** Every pod that ever reached the internet was SNAT'd to its node. Every `ClusterIP` you ever curl'd was DNAT'd to a real pod. Every private subnet's outbound traffic was masqueraded by a NAT Gateway. When you understand NAT, three "magic" Kubernetes behaviours collapse into one mechanism you can reason about.

**What do I already know already (the ladder so far)?**

- **[IP addressing](02-ip-addressing.md)** — public vs private ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` are private and **must not appear on the public internet**. NAT exists precisely because of this rule.
- **[Subnetting & CIDR](03-subnetting-and-cidr.md)** — a VPC is `10.0.0.0/16`; subnets are carved from it. "Public" vs "private" subnet is a *routing* distinction, and NAT is what makes a private subnet usable.
- **[Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md)** — a connection is identified by the 4-tuple `(src IP, src port, dst IP, dst port)`. **PAT lives or dies on the source port.** If this is fuzzy, revisit it first — it's the whole trick.
- **[Routing & forwarding](08-routing-and-forwarding.md)** — routers move packets between networks by longest-prefix match. NAT is a thing routers *also* do, on the same packets, at the same choke point.
- **[Transport layer TCP/UDP](07-transport-layer-tcp-udp.md)** — the connection state (SYN, established, FIN) is exactly what a NAT device must track to know when to forget a translation.

Hold those. We build straight up from them.

---

## 🔥 Rung 1 — The Pain

Rewind to the early 1990s. IPv4 has **~4.3 billion addresses** (2³²), which sounded infinite when a "computer" was a fridge-sized thing in a university basement. Then everyone got a PC. Then a phone. Then a fridge that tweets. The math stopped working.

**The pain, stated plainly:** there are not enough public IPv4 addresses for every device to have its own. If your company has 5,000 laptops, you cannot get 5,000 public IPs — your ISP won't give them, and even if they did, the global routing table would collapse under the weight of everyone doing that.

**What people did before, and why it hurt:**

- **Give every host a public IP.** This is how the *original* internet worked. MIT had a whole `/8` (16 million addresses) for a few thousand machines. It was gloriously wasteful and it ran out fast. By the mid-90s the registries were rationing addresses like wartime sugar.
- **Classful addressing (Class A/B/C).** You either got a Class C (254 hosts — too few) or a Class B (65,534 hosts — far too many, mostly wasted). There was no middle. Millions of addresses sat stranded inside over-sized Class B allocations. (CIDR later fixed the *sizing* waste; NAT fixed the *scarcity*.)

**What breaks without NAT:**

- **No home internet as you know it.** Your ISP hands you *one* public IP. Without NAT, exactly one device in your house could be online. NAT is why your laptop, phone, TV, and fridge all share that single address.
- **No private subnets in the cloud.** An EKS worker node in a private subnet has a `10.x` address. That address is **non-routable on the internet** — every backbone router is configured to *drop* packets sourced from private ranges. Without NAT, nothing in a private subnet could ever pull a container image, hit an external API, or run `apt-get update`.
- **No pod egress.** A pod IP (`10.244.x.x` on Flannel, or a VPC IP on the AWS VPC-CNI) is private. When it talks to the internet, *something* must swap that source for a public address or the reply has nowhere to come back to.

**The second, sneakier reason NAT exists — hiding.** A side effect of "everyone hides behind one public address" is that **the outside world cannot see or address your internal hosts.** An attacker scanning your public IP sees one door (the NAT device), not 5,000 machines. This is not real security (it's not a firewall, and NAT ≠ safety), but the *asymmetry* it creates — you can start connections out, nobody can start connections in — is genuinely useful and is the default posture of every private subnet and every pod.

**Who feels the pain most?** The platform engineer who put the database in a private subnet "for security," then can't figure out why it can't reach S3 or pull an image — because they removed its internet path and forgot that the *only* legitimate way back is NAT.

> **Check yourself before Rung 2:** Your ISP gives you one public IP. Ten devices in your house are streaming video at the same time, all to different servers. When the video packets come *back*, they all arrive at that one public IP. What single piece of information must the router have stored to know which of the ten devices each returning packet belongs to?

---

## 💡 Rung 2 — The One Idea

Memorize this sentence. Write it on a sticky note. Everything else in this file is a corollary of it:

> **NAT rewrites the address (and usually the port) in a packet as it crosses a boundary, and records that rewrite in a table so it can reverse it on the reply — letting many private hosts share a public identity while replies still find their way home.**

Say it again slowly: **rewrite + remember + reverse.** Those three verbs are the entire mechanism.

Now watch everything derive from it:

- **Why does SNAT exist?** Because the outbound packet's *source* is a private address that can't come home; rewrite it to a public one, remember the mapping, reverse it on the reply. Rewrite the source = **SNAT**.
- **Why does DNAT exist?** Because an inbound packet is addressed to a public front-door that isn't the real server; rewrite the *destination* to the real one, remember it, reverse it on the reply. Rewrite the destination = **DNAT**.
- **Why does PAT exist?** Because *many* private hosts share *one* public IP, so rewriting the address alone isn't enough to tell replies apart — you also rewrite the **source port** to a unique value per connection. The port is the disambiguator. Many-to-one = **PAT / masquerade**.
- **Why does NAT need a table?** Because "remember" and "reverse" are impossible without stored state. That table is the **conntrack / NAT table**. No table, no return path — the reply would be undeliverable.
- **Why does NAT break unsolicited inbound?** Because "reverse" only works if there was a "remember" first — and a *remembered* entry is only created by an *outbound* packet. An inbound connection nobody asked for has no table entry, so the NAT device doesn't know which private host to send it to. It drops it. (This is why you need explicit **port-forwards / DNAT rules** to expose a service.)

One sentence. Six corollaries. That's the file.

> **Check yourself before Rung 3:** From the One Idea alone, explain why a Kubernetes `ClusterIP` (a fake, virtual IP that no network card owns) can still receive your traffic and deliver it to a real pod. Which of the three verbs is doing the work, and is it SNAT or DNAT?

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

### The concierge analogy (then we ground it hard in packets)

Picture a fancy hotel. You (a guest in **room 512**) want a newspaper from the street vendor. You don't walk out yourself — you phone the **front-desk concierge**. The concierge steps onto the street, buys the paper *under the hotel's name*, and the vendor has no idea room 512 exists. The vendor only ever knew "the concierge at 350 Fifth Avenue."

When the vendor has change to return, he hands it to **the concierge**, not to you — he can't, he's never heard of you. So how does the change get back to room 512? Because the concierge **wrote it in a ledger**: *"Newspaper errand → came from room 512."* He reads the ledger and walks the change up to your door.

That ledger is the entire game. Map it:

| Hotel | Network |
|---|---|
| Room 512 | Private host `10.0.5.12` |
| Hotel street address (350 Fifth Ave) | Public IP of the NAT device |
| Concierge | The NAT device (router / NAT Gateway / node kernel) |
| Street vendor | Public internet server |
| The ledger | The **conntrack / NAT table** |
| "Which room?" written in the ledger | The remembered translation |

The concierge **fetches from the street but hides your room number.** That's SNAT/PAT in one sentence. And note the built-in limitation: **the vendor can never *start* a conversation with room 512** — he doesn't know it exists, and there's no ledger entry until *you* send the concierge out first. That's exactly why NAT breaks unsolicited inbound.

### What actually moves: the 5-tuple and the rewrite

Every TCP/UDP flow is identified by a **5-tuple**: `(protocol, src IP, src port, dst IP, dst port)`. NAT is nothing more than a device rewriting some of those fields on the way out and reversing the rewrite on the way back. Here's PAT (the many-to-one case) on the wire:

```
                    PRIVATE SIDE                  NAT DEVICE                 PUBLIC SIDE
                  (10.0.5.0/24)              public IP 203.0.113.9        (the internet)

  Host A 10.0.5.12 ─┐
    src 10.0.5.12:51000                                                   dst 93.184.216.34:443
    dst 93.184.216.34:443 ──────▶  ┌───────────────────────────┐ ──────▶ src 203.0.113.9:61001
                                   │   CONNTRACK / NAT TABLE    │
  Host B 10.0.5.20 ─┐             │  (the concierge's ledger)  │
    src 10.0.5.20:51000            │                           │         dst 93.184.216.34:443
    dst 93.184.216.34:443 ──────▶  │  10.0.5.12:51000  <=>      │ ──────▶ src 203.0.113.9:61002
                                   │      203.0.113.9:61001     │
                                   │  10.0.5.20:51000  <=>      │
                                   │      203.0.113.9:61002     │
                                   └───────────────────────────┘
```

Look closely at the collision that PAT solves. **Both** hosts happened to pick source port `51000` (nothing stops them — they don't coordinate). If the NAT device only rewrote the *IP*, both flows would leave as `203.0.113.9:51000 → 93.184.216.34:443` — **identical 5-tuples**, and the reply would be impossible to demultiplex. So PAT **also rewrites the source port** to a unique value (`61001`, `61002`). Now the two flows differ, and the table can reverse each one to the correct room. **The source port is the disambiguator. That is the entire reason it's called *Port* Address Translation.**

### The three rewrites, side by side

```
  SNAT (outbound)        rewrite SOURCE          for traffic LEAVING a private net
   before:  src 10.0.5.12:51000  dst 93.184.216.34:443
   after:   src 203.0.113.9:61001 dst 93.184.216.34:443     ← source changed

  DNAT (inbound)         rewrite DESTINATION     for traffic ENTERING to a hidden host
   before:  src 198.51.100.7:40000 dst 203.0.113.9:80
   after:   src 198.51.100.7:40000 dst 10.0.5.30:8080        ← destination changed

  PAT / MASQUERADE       SNAT for MANY hosts     source PORT rewritten to disambiguate
   many private (IP:port) ==> one public IP : {unique port per flow}
```

### Where the mechanism lives (and what the app never sees)

The application on `10.0.5.12` believes with all its heart that it is talking `10.0.5.12:51000 → 93.184.216.34:443`. It never learns otherwise. The rewrite happens **in the router/kernel forwarding path**, after the app handed the packet down and before it hit the wire. The reply comes back to `203.0.113.9:61001`, the NAT device reverses the rewrite *before* delivering it, and the app receives a packet addressed to `10.0.5.12:51000` — exactly what it expects. **NAT is invisible to both ends.** The server thinks it talked to `203.0.113.9`. The client thinks it used its own IP. Only the concierge knows the truth, and only for as long as the ledger entry lives.

### On Linux, this is netfilter/conntrack — the same code in your cluster

Linux does NAT in the **netfilter** framework, configured via **iptables** (or nftables/IPVS). Two hook points matter:

- **`POSTROUTING`** chain of the `nat` table — last stop before the packet leaves. This is where **SNAT** and **MASQUERADE** happen (you rewrite the source *after* routing has decided the exit interface).
- **`PREROUTING`** chain of the `nat` table — first stop after arrival. This is where **DNAT** happens (you rewrite the destination *before* routing decides where it goes).

```
   packet in ──▶ [PREROUTING: DNAT] ──▶ routing ──▶ [POSTROUTING: SNAT/MASQ] ──▶ packet out
                  "fix destination"                    "fix source"
```

The state lives in the kernel's **conntrack** table (`/proc/net/nf_conntrack`). Conntrack is *also* what makes a **stateful firewall** work — the same connection-tracking that reverses NAT is what a Security Group uses to auto-allow return traffic. (Deep dive: **[iptables & netfilter](../Linux/12-iptables-netfilter.md)** and **[firewalls / SGs / NACLs](17-firewalls-security-groups-nacls.md)**.)

**Now the cloud/Kubernetes payoff — same machinery, three costumes:**

- **Pod egress = SNAT/MASQUERADE to the node IP.** A pod at `10.244.1.5` curls the internet. On the way out of the node, an iptables `MASQUERADE` rule (installed by the CNI, e.g. Flannel/Calico) rewrites the source to the **node's IP**. To the outside world the traffic came from the node, not the pod. This is why external captures show node IPs, never pod IPs.
- **Service ClusterIP = DNAT by kube-proxy.** A `ClusterIP` like `10.96.0.10` is a **virtual IP no interface owns**. When a pod sends to it, **kube-proxy**'s iptables (or IPVS) rules **DNAT** the destination to one real backend pod IP, chosen per-connection. The client thinks it's talking to a stable VIP forever; the actual pod behind it changes on every deploy. (Full story: **[Services & kube-proxy](25-kubernetes-services-kube-proxy.md)**.)
- **NodePort = DNAT too.** Traffic hits `NodeIP:31234` (NodePort range is **30000–32767**), and kube-proxy DNATs it to a backend pod, often adding SNAT so the reply routes back through the same node.
- **AWS NAT Gateway = managed PAT.** A NAT Gateway sits in a *public* subnet with an Elastic IP. Private-subnet route tables send `0.0.0.0/0 → nat-gateway-id`. It masquerades every private host behind its one public IP, hiding the entire private subnet while granting outbound internet. (Full story: **[AWS VPC](20-aws-vpc.md)**.)

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **NAT** | Rewriting IP addresses in packets crossing a boundary | The whole concept — rewrite + remember + reverse |
| **SNAT** (Source NAT) | Rewrite the *source* address of outbound packets | `POSTROUTING`; the "make it look like me" step |
| **DNAT** (Destination NAT) | Rewrite the *destination* address of inbound packets | `PREROUTING`; port-forwarding, Service VIPs |
| **PAT / NAPT** | Many hosts → one IP, disambiguated by source **port** | The port-rewrite that makes many-to-one possible |
| **MASQUERADE** | Linux's PAT that uses the exit interface's *current* IP | iptables target; pod egress, home routers |
| **Conntrack table** | Kernel record of every tracked connection + its NAT rewrite | The "remember/reverse" ledger; `/proc/net/nf_conntrack` |
| **NAT table** | The subset of conntrack holding the address/port mappings | The concierge's ledger |
| **5-tuple** | `(proto, src IP, src port, dst IP, dst port)` — a flow's identity | What NAT rewrites and what conntrack keys on |
| **Port forwarding** | A static DNAT rule exposing an inside host on a public port | Manual inbound path past NAT |
| **Elastic IP (EIP)** | A fixed AWS public IP you own | The public identity a NAT Gateway masquerades to |
| **NAT Gateway** | AWS-managed PAT device for a private subnet's egress | Cloud SNAT/PAT; hides private subnet |
| **IGW (Internet Gateway)** | VPC's door to the internet; does 1:1 NAT for public IPs | Where public-subnet traffic actually leaves |
| **kube-proxy** | The agent that programs iptables/IPVS DNAT for Services | Cluster-side DNAT engine |
| **ClusterIP** | A virtual Service IP no NIC owns | The DNAT *target front-door* inside a cluster |
| **Hairpin NAT** | NAT'ing a host so it can reach itself via its own public IP | The awkward inside→public→inside loop |
| **Full-cone / symmetric NAT** | How permissive the mapping is toward inbound reuse | Matters for VoIP/WebRTC/P2P and hole-punching |
| **CGNAT** | Carrier-Grade NAT — your ISP NATs *you* behind a shared IP | NAT stacked on NAT, at ISP scale |

**"Same kind of thing wearing different names":**

- **PAT = NAPT = "NAT overload" (Cisco) = MASQUERADE (Linux) = "IP masquerading."** Five names, one idea: many private hosts behind one public IP, sorted by source port.
- **SNAT ⊇ MASQUERADE.** MASQUERADE is just SNAT that auto-picks the exit interface's IP instead of a hard-coded one — perfect when your public IP is dynamic (DHCP, a pod's node IP).
- **"Port forwarding" = "a static DNAT rule" = "a NodePort" = "a published Docker port (`-p 80:8080`)."** All the same inbound DNAT, different UIs. (See **[container/Docker networking](23-container-docker-networking.md)**.)
- **"NAT table" ⊂ "conntrack table"** — the NAT mappings are entries *inside* the broader connection-tracking store.
- **"ClusterIP resolution" = "DNAT to a pod."** A Service isn't a proxy process for ClusterIP/iptables mode — it's literally a kernel DNAT rule.
- **"NAT Gateway" and "your home router's WiFi" do the *same job*** — managed PAT with hiding — at wildly different scales.

---

## 🔬 Rung 5 — The Trace

Let's follow **one pod's HTTPS request to an external API**, end to end, and watch NAT happen *twice* (once in the cluster, once at the VPC edge) and then reverse on the way home.

**Actors:** Pod `10.244.1.5:44001` → node `10.0.1.11` (SNAT/MASQ + conntrack) → VPC router → NAT Gateway `10.0.0.9` w/ EIP `203.0.113.9` (PAT + conntrack) → IGW → internet → API server `93.184.216.34:443`.

```
        OUTBOUND  ───────────────────────────────────────────────────────────▶

  ┌────────┐  MASQ   ┌──────────┐  route  ┌────────┐  PAT    ┌──────┐        ┌──────────┐
  │  POD   │ src→node│  NODE    │0.0.0.0/0│  NAT   │src→EIP  │ IGW  │        │   API    │
  │10.244. │────────▶│ 10.0.1.11│────────▶│ GATEWAY│────────▶│      │───────▶│ 93.184.  │
  │ 1.5    │ :44001  │ conntrack│         │203.0.  │ :61001  │ 1:1  │        │ 216.34   │
  │ :44001 │         │  ledger  │         │113.9   │conntrack│ NAT  │        │  :443    │
  └────────┘         └──────────┘         └────────┘ ledger  └──────┘        └──────────┘

   src 10.244.1.5:44001   src 10.0.1.11:52000   src 203.0.113.9:61001   arrives as
   dst 93.184.216.34:443  dst 93.184.216.34:443 dst 93.184.216.34:443   203.0.113.9:61001

        INBOUND (reply)  ◀───────────────────────────────────────────────────
     each device reads its ledger and REVERSES the rewrite, hop by hop back to the pod.
```

1. **Pod builds the packet.** `src 10.244.1.5:44001 → dst 93.184.216.34:443`. Its default route sends it out the veth to the node. TTL=64. The pod has no idea any of the next steps exist.
2. **Node SNATs (MASQUERADE).** The node is an IP-forwarding Linux router. A CNI-installed iptables rule in `POSTROUTING` fires: because the destination is *outside* the pod/cluster CIDR, `MASQUERADE` rewrites the source to the **node IP** and picks a fresh source port. Packet is now `src 10.0.1.11:52000 → dst 93.184.216.34:443`. **Conntrack records** `10.244.1.5:44001 <=> 10.0.1.11:52000`. (Pod-to-pod and pod-to-ClusterIP traffic is *excluded* from this masquerade — only off-cluster traffic gets SNAT'd, so internal traffic keeps real pod IPs.)
3. **VPC routing.** The node's subnet is *private*: its route table says `0.0.0.0/0 → nat-gateway-id`. The packet is forwarded toward the NAT Gateway. Still sourced from the private `10.0.1.11`.
4. **NAT Gateway does PAT.** It rewrites the source from `10.0.1.11:52000` to its **Elastic IP** `203.0.113.9:61001`, records the mapping in *its own* ledger, and forwards toward the IGW. Now — and only now — does the packet carry a globally routable source. **The private subnet is invisible to the internet.**
5. **IGW → internet.** The Internet Gateway performs the final 1:1 NAT for public traffic and puts the packet on the wire out of AWS's AS. It crosses many BGP hops to `93.184.216.34`.
6. **Server replies — to the only address it ever saw.** The API sends `src 93.184.216.34:443 → dst 203.0.113.9:61001`. It has never heard of `10.0.1.11`, let alone `10.244.1.5`. The reply can only be addressed to the public EIP.
7. **Reverse the rewrites, hop by hop.** The reply hits the NAT Gateway; it reads its ledger (`61001 → 10.0.1.11:52000`) and rewrites the destination back. The node receives it, reads *its* conntrack (`52000 → 10.244.1.5:44001`) and rewrites the destination back to the pod. The pod receives `src 93.184.216.34:443 → dst 10.244.1.5:44001` — exactly the reply it was waiting for.

**The payoff:** the private pod reached the public internet and got an answer, yet its address never once appeared on a public wire. Two independent NAT devices each did **rewrite → remember → reverse**, and the two ledgers together stitched a private room to a public street and back. That is NAT.

---

## ⚖️ Rung 6 — The Contrast

**The real alternative to NAT is: don't translate — give everything a globally unique, routable address.** That's the **IPv6** world, and it's also how the *original* IPv4 internet worked before scarcity.

| Dimension | NAT (IPv4 private + translate) | No-NAT (public/routable everywhere, IPv6) |
|---|---|---|
| Address supply | Sips one public IP for thousands of hosts | Needs a unique global address per host (IPv6 has 2¹²⁸) |
| Inbound connections | **Broken by default** — need explicit DNAT/port-forward | Any host directly addressable (firewall decides, not NAT) |
| End-to-end principle | Broken — the address the server sees isn't the client's | Preserved — server sees the true source |
| "Hiding" side effect | Yes — internal topology invisible (not real security) | No inherent hiding; rely on firewalls/policy |
| State required | **Stateful** — a conntrack entry per flow; table can exhaust | Stateless forwarding; no per-flow NAT state |
| Protocols that embed IPs | Break (FTP active mode, SIP, some P2P) → need ALGs | Work natively |
| Debuggability | Harder — addresses change mid-path | Easier — one address end to end |

**What NAT can do that the alternative can't:** stretch a tiny pool of public addresses across a huge private fleet, and give you "outbound-only by default" hiding for free. That's exactly the posture of a private subnet or a default pod.

**What the alternative does that NAT can't:** preserve the true source address end to end (great for logging, security, and protocols that carry IPs in their payload), and let *any* host be reached inbound without a bespoke port-forward.

**When would I NOT want NAT?**

- **Inside the cluster CIDR.** Pod-to-pod traffic must keep **real pod IPs** — that's one of Kubernetes' four network rules ("pods communicate without NAT"). CNIs deliberately *exclude* intra-cluster traffic from masquerade so NetworkPolicy, mTLS identity, and logging see true source pods. NAT there would break identity.
- **When you need the real client IP.** An L7 proxy that SNATs loses the client's address unless it re-injects it via `X-Forwarded-For` or `externalTrafficPolicy: Local` preserves it. Sometimes you turn NAT *off* on purpose.
- **IPv6 / VPC-CNI with real IPs.** When pods get routable VPC IPs, you may not need pod-egress masquerade at all — the VPC routes them natively.

**Why NAT over the alternative, in one sentence:** Use NAT whenever many hosts must share scarce public addresses *and* you want outbound-only exposure by default — which is precisely the situation of every private subnet and every pod in your cluster.

> **Check yourself before Rung 7:** Kubernetes requires that "pods talk to each other without NAT," yet a pod reaching the internet *is* NAT'd (masqueraded to the node). Reconcile these two facts — what property of the *destination* decides whether the masquerade rule fires?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *out loud* before running the command. Being wrong here is the most valuable thing that can happen — it means you found a gap in your model. (Commands that write NAT rules need `sudo`/root; a Linux box or VM is the right lab.)

### Test 1 — Normal case: watch a live connection and its NAT translation in the conntrack table

**Prediction:** *"When I open an outbound connection, the kernel's conntrack table will hold one entry showing both the original 5-tuple and the reply-direction tuple. If my box does SNAT/masquerade, the reply tuple's destination will be the translated (public) address, not my private one — BECAUSE conntrack is the ledger that stores rewrite + reverse."*

```bash
# Open a connection in one shell:
curl -s https://example.com >/dev/null &

# Inspect conntrack in another (install: conntrack-tools):
sudo conntrack -L -p tcp --dport 443
# Representative line (on a plain host, no NAT yet — original == reply reversed):
# tcp 6 115 ESTABLISHED src=192.168.1.42 dst=93.184.216.34 sport=51000 dport=443 \
#   src=93.184.216.34 dst=192.168.1.42 sport=443 dport=51000 [ASSURED]

# Or read the raw kernel table:
sudo cat /proc/net/nf_conntrack | grep 443
```

**Verify:** You should see two directions in one line: the original (`src=you dst=server`) and the reply (`src=server dst=you`). On a NAT router, the reply-direction `dst=` would show the **translated** address, proving the reverse mapping. If the table is empty, either conntrack isn't loaded (`modprobe nf_conntrack`) or nothing is tracking that flow — which teaches you that **no state = no NAT reversal possible**.

### Test 2 — Build SNAT/PAT yourself and prove hiding, then break inbound (edge/failure case)

**Prediction (part A):** *"If I add a MASQUERADE rule for outbound traffic, hosts behind this box will reach the internet and the destination server will see THIS box's IP, not theirs — BECAUSE POSTROUTING rewrites the source to the exit interface's IP."*

**Prediction (part B):** *"An unsolicited inbound connection to this box will NOT reach any internal host, BECAUSE there's no conntrack entry to reverse and no DNAT rule — until I add an explicit port-forward."*

```bash
# --- Part A: SNAT / masquerade (turn a Linux box into a NAT router) ---
sudo sysctl -w net.ipv4.ip_forward=1                      # enable routing
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE  # SNAT out eth0
sudo iptables -t nat -L POSTROUTING -n -v                  # verify the rule exists

# From a client behind this box, check the source the world sees:
curl -s https://ifconfig.me      # returns THIS router's public IP, never the client's

# --- Part B: prove unsolicited inbound is dead, then fix it with DNAT ---
# (from outside) curl http://<router-public-ip>:80   -> connection refused/timeout
sudo iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 \
     -j DNAT --to-destination 10.0.5.30:8080          # explicit port-forward
sudo iptables -t nat -L PREROUTING -n -v              # now inbound :80 -> 10.0.5.30:8080
```

**Verify:** After Part A, `ifconfig.me` (or `curl https://api.ipify.org`) from a client shows the **router's** IP — hiding confirmed. Before the DNAT rule, inbound `:80` fails (no ledger entry, nowhere to send it — this is the *whole reason* NAT breaks unsolicited inbound). After the DNAT rule, it reaches the internal host. If Part A's `curl` shows the *client's* own IP, forwarding/masquerade isn't actually on the path — teaching you that SNAT only fires at the routing choke point you configured.

### Test 3 — Kubernetes: see kube-proxy's DNAT for a ClusterIP, and pod-egress masquerade (cloud-flavoured)

**Prediction:** *"A ClusterIP is a virtual IP no interface owns, yet curling it works — because kube-proxy installed iptables DNAT rules that rewrite the destination to a real pod IP. And a pod reaching the internet will be masqueraded to its node IP, so external captures never show the pod IP."*

```bash
# The ClusterIP belongs to no NIC — confirm it's virtual:
kubectl get svc kubernetes -n default      # e.g. CLUSTER-IP 10.96.0.1, no pod/host owns it

# On a node, find kube-proxy's DNAT rules for Services (iptables mode):
sudo iptables -t nat -L KUBE-SERVICES -n | head
# You'll see per-service chains; drilling in shows the DNAT:
sudo iptables -t nat -L -n | grep -A3 'KUBE-SEP'
#   ... DNAT tcp -- 0.0.0.0/0  0.0.0.0/0  /* ns/svc */ tcp to:10.244.1.5:8080
# (IPVS mode instead: `sudo ipvsadm -Ln` shows VIP -> real pod endpoints)

# Prove pod egress is SNAT'd to the node IP. From inside a pod:
kubectl run t --rm -it --image=curlimages/curl -- sh -c 'curl -s https://api.ipify.org'
# Returns the NODE's / NAT-Gateway's public IP — never the pod's 10.244.x.x

# See the masquerade rule the CNI installed:
sudo iptables -t nat -L POSTROUTING -n | grep -i masq
#   ... MASQUERADE all -- 0.0.0.0/0  0.0.0.0/0  /* kubernetes ... */  (excludes cluster CIDR)
```

**Verify:** The ClusterIP has no owning interface yet traffic to it lands on a pod — that's DNAT, not routing to a real host. The `to:10.244.x.x:port` in the rule *is* the destination rewrite. `api.ipify.org` from a pod returns the node/NAT-GW public IP, proving egress SNAT. If it somehow returned the pod IP, either you're on VPC-CNI with routable pod IPs and no masquerade, or an egress path bypasses the rule — both teach you exactly where the SNAT boundary sits. (Deeper: **[Services & kube-proxy](25-kubernetes-services-kube-proxy.md)**, **[pod networking / CNI](24-kubernetes-pod-networking-cni.md)**.)

---

## 🏔️ Capstone — Compress It

**One-sentence summary:**
NAT rewrites the address/port of a packet crossing a boundary and remembers the swap in a table so replies reverse cleanly — letting many private hosts share one public identity while staying unreachable from outside unless you explicitly forward a port.

**Explain it to a beginner in three sentences:**
Your devices have private addresses that can't travel the internet, so a device in the middle swaps the source for a shared public address on the way out and writes down who it belongs to. When the reply comes back to that public address, it reads its notes and hands the packet to the right private device. Because there's no note until *you* reach out first, strangers can't start a conversation with your internal machines — which is both a convenience and the reason you need explicit port-forwarding to expose anything.

**Map the sub-parts back to the one core idea (rewrite + remember + reverse):**

| Sub-part | How it's just the One Idea | Verb it emphasizes |
|---|---|---|
| SNAT | Rewrite the source so a private host can go out and get a reply | rewrite (source) |
| DNAT | Rewrite the destination so a public front-door reaches the real host | rewrite (destination) |
| PAT / masquerade | Add source-port rewriting so many hosts share one IP | rewrite (port) to enable *remember* uniquely |
| Conntrack / NAT table | The stored mappings | remember + reverse |
| Broken unsolicited inbound | No prior outbound = no remembered entry = nothing to reverse | reverse (absent) |
| Pod egress → node IP | SNAT/MASQUERADE at the node | rewrite (source) |
| ClusterIP / NodePort | kube-proxy DNAT to a real pod | rewrite (destination) |
| AWS NAT Gateway | Managed PAT hiding a private subnet | rewrite (source+port) at cloud scale |

**Which rung to revisit hands-on:** **Rung 7, Test 3.** Reading about pod-egress masquerade and ClusterIP DNAT is one thing; *seeing* `MASQUERADE` and `DNAT ... to:10.244.x.x` in a live node's iptables, then watching a pod's egress surface as the node's public IP, is what makes NAT stop being magic. Do it on a real cluster. If the conntrack ledger still feels abstract, loop back to **Rung 3** and re-draw the PAT diagram from memory — if you can reproduce the two-hosts-same-port collision and how the port rewrite resolves it, you own this concept.

---

## Related concepts

- **[Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md)** — the source port that PAT rewrites; the 5-tuple that conntrack keys on.
- **[IP addressing](02-ip-addressing.md)** — the public vs private ranges that make NAT necessary in the first place.
- **[Routing & forwarding](08-routing-and-forwarding.md)** — NAT happens at the same choke point routers use; route tables send private subnets to the NAT Gateway.
- **[Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md)** — the same conntrack state powers stateful firewalls; NAT ≠ security.
- **[Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md)** — ClusterIP/NodePort DNAT in full detail.
- **[AWS VPC](20-aws-vpc.md)** — NAT Gateway, IGW, public vs private subnets, and route tables.
- **[iptables & netfilter](../Linux/12-iptables-netfilter.md)** — the PREROUTING/POSTROUTING machinery, MASQUERADE and DNAT targets, and conntrack, at the source.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Ten devices behind one public IP all stream video from different servers. When packets come back to that single public IP, what single piece of information must the router have stored to know which device each returning packet belongs to?

**A:** The router must have stored the **NAT/conntrack table entry mapping each translated (public) source port back to the original private `IP:port`** — the concierge's ledger. When each device's outbound flow left, the router rewrote its source to `publicIP:uniquePort` and recorded `private IP:port <=> public IP:port`. A returning packet arrives addressed to `publicIP:thatPort`, and the port is the disambiguator: the router looks up which of the ten devices' flows owns that translated source port and rewrites the destination back to that device's private address and port. This is exactly why the scheme is called *Port* Address Translation — with one shared IP, only the rewritten source port can tell the ten flows apart.

### Before Rung 3
**Q:** From the One Idea alone, explain why a Kubernetes ClusterIP — a virtual IP no network card owns — can still receive your traffic and deliver it to a real pod. Which verb is doing the work, and is it SNAT or DNAT?

**A:** The ClusterIP is just a front-door address: when a packet addressed to it passes through the node's kernel, kube-proxy's rules **rewrite the destination** from the virtual IP to a real backend pod's `IP:port`, **remember** the choice in conntrack, and **reverse** it on the reply so the client still believes it spoke to the stable VIP. The verb doing the work is **rewrite** (of the destination, with remember+reverse keeping the illusion consistent), and it is **DNAT** — "you asked for this front-door address; I'll send you to the real machine behind it." No interface needs to own the ClusterIP because the packet never has to be delivered *to* it; the address is swapped out in the kernel forwarding path (PREROUTING) before routing decides where the packet goes.

### Before Rung 7
**Q:** Kubernetes requires that "pods talk to each other without NAT," yet a pod reaching the internet *is* masqueraded to the node. Reconcile these facts — what property of the *destination* decides whether the masquerade rule fires?

**A:** Whether the destination is **inside or outside the cluster/pod CIDR**. The CNI-installed MASQUERADE rule in the node's POSTROUTING chain explicitly *excludes* destinations within the cluster CIDR, so pod-to-pod and pod-to-ClusterIP traffic keeps real pod IPs — satisfying the Kubernetes rule and preserving true source identity for NetworkPolicy, mTLS, and logging. Only when the destination falls *outside* that CIDR (off-cluster, e.g. the internet) does the masquerade fire, rewriting the source to the node IP — necessary because a private pod address like `10.244.1.5` is non-routable on the public internet and a reply could never find its way back. Same node, same iptables chain, one match condition on the destination range reconciles both facts.
