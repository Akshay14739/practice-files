# Subnetting & CIDR 🪜
### Slicing one big address space into neighborhoods — deriving the math, not memorizing the tables

> This is the subnetting rung of your networking ladder. Most subnetting tutorials open with a table of magic numbers to memorize. We do the opposite: we climb from **why subnets had to exist** → **the one idea** → **the bit-level machinery** → and only at the very top, the commands (`ipcalc`, `ip route`, `aws ec2`). Each rung ends with a "check yourself" question. If you can *derive* the answer, climb on. If you had to guess, that rung is your next hands-on session.
>
> **The one rule:** by the end you should never need a subnet cheat-sheet again. You'll *compute* `/26 = 62 usable hosts` in your head, because you'll understand the two bits that get stolen.

---

# RUNG 0 — The Setup

**What am I learning?**
Subnetting and CIDR — how a single block of IP addresses like `10.0.0.0/16` gets carved into smaller, non-overlapping pieces, and the notation (`/n`) that describes each piece.

**Why did it land on my desk?**
You're standing up a new EKS cluster. The AWS VPC creation wizard asked you for a CIDR block and offered `10.0.0.0/16` as a default. Then it asked you to create a subnet **per Availability Zone**, each needing its *own* CIDR that fits inside the VPC's block and doesn't collide with its siblings. A week later a teammate asks you to peer this VPC with the shared-services VPC — and the peering request fails with `overlapping CIDR`. Meanwhile a colleague's smaller cluster is throwing `failed to assign an IP address to container`, and the root cause turns out to be a subnet that was too small. Every one of these is the same skill: **splitting an address space correctly.**

**What do I already know?**
From the [IP addressing](02-ip-addressing.md) rung you know an IPv4 address is 32 bits, written as four octets (`10.0.0.0`), and that some ranges are *private* (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`). You're comfortable in `kubectl` and the AWS console. What you *don't* yet have is a gut feel for what the `/16` actually means bit-for-bit, or why one wrong digit breaks VPC peering.

---

# RUNG 1 — The Pain 🔥
### *Why does subnetting exist at all?*

Before any math, sit with the problem. If you feel the pain, the math becomes obvious instead of arbitrary.

### Problem 1: One flat network doesn't scale

Imagine you *didn't* subnet. Every machine in your company — 60,000 of them — sits on one giant flat network, `10.0.0.0/16`. Now think about what a switch does when a host doesn't know a MAC address: it **broadcasts** ("who has `10.0.42.7`?"). On one flat segment, *every* broadcast reaches *every* one of those 60,000 hosts. This is a **broadcast domain**, and a single flat one this large is a catastrophe:

```
THE FLAT-NETWORK PAIN

        one giant broadcast domain: 10.0.0.0/16 (65k hosts)

   host ──"who has 10.0.42.7?"──▶ EVERY other host must process it
     │                                     │
     ▼                                     ▼
  ARP storm: one noisy host degrades ALL 65,000 machines.
  No isolation: HR laptops share a segment with prod databases.
  No blast-radius control: one compromised host can reach everything.
```

- **Performance:** broadcast traffic grows with host count; a big flat L2 domain drowns in ARP and floods.
- **Security:** there's no natural boundary. Finance, prod, and guest Wi-Fi all sit in one room with no walls.
- **Isolation:** a misconfigured or compromised host can talk to *anything*.

### Problem 2: Classful addressing wasted addresses grotesquely

Before 1993, IPv4 was **classful**. Your network size was decided by the *first bits* of the address, and you got exactly three sizes:

```
THE CLASSFUL PAIN (pre-CIDR, before 1993)

Class A:  /8   → 16,777,214 hosts   (way too big)
Class B:  /16  →     65,534 hosts   (still huge)
Class C:  /24  →        254 hosts   (often too small)

You need 400 hosts? A Class C (254) is too small...
  ...so you're forced to take a Class B (65,534).
  → You just wasted ~65,000 addresses. Multiply across the internet.
```

There was no in-between. This burned through the IPv4 space so fast the internet nearly ran out of addresses in the mid-90s.

### What people did before, and why it hurt

Engineers hard-coded network sizes to class boundaries and either **wasted** enormous ranges or **crammed** too many hosts into a `/24` and hit the ceiling. Route tables on the internet backbone also exploded because there was no way to *aggregate* many small networks into one advertisement.

### Who feels this pain most?

**You — the cloud/platform engineer.** In AWS, *you* choose the VPC CIDR and every subnet CIDR. Get it wrong and: your subnets don't fit, your AZs collide, your CNI runs out of pod IPs, or your VPC can never peer with the corporate network. The pain didn't go away with the cloud — it moved into the console and landed on your desk.

> **✅ Check yourself before Rung 2:** In your own words — why does a network *need* to be split even when you technically have enough addresses to put everyone on one segment? (Hint: think about what a switch broadcasts, and who has to listen.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — every calculation in this file can be *derived* from it:

> **An IP address is 32 bits; the CIDR prefix `/n` declares the first `n` bits are a FIXED network ID shared by everyone in the subnet, and the remaining `32 − n` bits are free to number the hosts — so the subnet holds `2^(32−n)` addresses, of which two are reserved.**

That's the whole trick. Read it twice. Everything below is just consequences of that one sentence.

### Why this sentence lets you derive everything

Watch how much falls straight out of it:

- *"the first `n` bits are fixed"* → **that's the prefix, the network portion.** Two hosts are on the same subnet **iff** their first `n` bits match.
- *"the remaining `32 − n` bits are free"* → **host portion.** The number of distinct hosts you can number is `2^(32 − n)`. This is the whole **"32 − prefix, then 2 to the power"** trick.
- *"two are reserved"* → the all-zeros host bits = the **network address** (the name of the subnet itself), and the all-ones host bits = the **broadcast address**. Neither can be assigned to a machine. So **usable hosts = 2^(32 − n) − 2.**
- *"a fixed network ID shared by everyone"* → this is exactly why **overlapping CIDRs can't be connected**: if two subnets share the same network ID, a router can't tell which one you mean.

You will never memorize a subnet table again. You'll compute `32 − n`, raise 2 to it, subtract 2. Done.

```
THE ONE TRICK, VISUALLY (for a /26):

  32  −  26   =   6        ← host bits
  2^6         =   64       ← TOTAL addresses
  64  −  2    =   62       ← USABLE hosts (drop network + broadcast)
```

> **✅ Check yourself before Rung 3:** Cover the sentence. From memory, tell me: for a `/28`, how many total addresses, and how many usable hosts? (Derive it — don't recall a table. `32 − 28 = 4`, `2^4 = 16`, `16 − 2 = 14`.)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We now open the hood and look at the **bits**, because that's where subnetting literally happens. There are four things to see: **(A) the network/host boundary in binary, (B) how the prefix slides that boundary, (C) network vs broadcast addresses, and (D) how a router uses the prefix to make a forwarding decision.**

## (A) The 32 bits and the boundary line

An IPv4 address is 32 bits, grouped into four 8-bit octets. The CIDR prefix draws a vertical line: everything left of the line is **network**, everything right is **host**.

```
ADDRESS: 172.16.3.10   with prefix /24

octet:      172        16          3          10
binary:  10101100 . 00010000 . 00000011 . 00001010
         └──────────────────────────────┘ └────────┘
              NETWORK (24 bits, fixed)      HOST (8 bits, free)
                                          ▲
                                    the /24 boundary
```

Every host in `172.16.3.0/24` shares the identical first 24 bits (`10101100.00010000.00000011`). The last 8 bits are theirs to vary: `00000000` through `11111111` — that's `2^8 = 256` combinations.

## (B) Sliding the boundary: the prefix IS the boundary

Change the prefix and you *move the line*. Move it right (bigger `/n`) → fewer host bits → smaller subnet. Move it left (smaller `/n`) → more host bits → bigger subnet. This is the entire concept of subnetting: **borrowing host bits to make more, smaller networks.**

```
SAME FIRST OCTETS, DIFFERENT BOUNDARY:

/24  10101100.00010000.00000011 | 00001010    host bits = 8  → 256 addrs
/25  10101100.00010000.00000011.0| 0001010    host bits = 7  → 128 addrs
/26  10101100.00010000.00000011.00| 001010    host bits = 6  →  64 addrs
/28  10101100.00010000.00000011.0000| 1010    host bits = 4  →  16 addrs
/30  10101100.00010000.00000011.000010| 10    host bits = 2  →   4 addrs
                                       ▲
                       the boundary slides right → subnet shrinks
```

Going from `/24` to `/26` "steals" 2 host bits and hands them to the network side. Those 2 stolen bits (`00`, `01`, `10`, `11`) let you split one `/24` into **four** `/26` subnets — the classic "carve a subnet per AZ" move you'll do in a VPC.

## (C) The two reserved addresses (why it's minus 2)

Within any subnet, two specific host-bit patterns are off-limits for machines:

```
INSIDE 172.16.3.0/26   (host bits = last 6 bits)

  host bits = 000000  → 172.16.3.0    = NETWORK ADDRESS   (the subnet's name)
  host bits = 000001  → 172.16.3.1    ┐
  host bits = 000010  → 172.16.3.2    │  ← 62 USABLE host addresses
       ...                            │     (.1 through .62)
  host bits = 111110  → 172.16.3.62   ┘
  host bits = 111111  → 172.16.3.63   = BROADCAST ADDRESS (reach everyone here)

  64 total − 2 reserved = 62 usable.
```

- **Network address** (all host bits `0`): the *identity* of the subnet. Routers use it to name the whole block. You cannot give it to a host.
- **Broadcast address** (all host bits `1`): "deliver to everyone on this subnet." Also un-assignable.

> Analogy: think of a subnet as a **street**. The *network address* is the street's name on the sign ("Maple Street"); the *broadcast address* is shouting down the whole street at once. Neither is a house you can live in — houses are the addresses in between.

Note the cloud twist: **AWS reserves not 2 but 5 addresses** in every subnet (network, broadcast, plus 3 for the VPC router, DNS, and future use). So an AWS `/24` gives you **251** usable, not 254. The *concept* is the classic minus-2; AWS just reserves three extra.

## (D) How a router actually USES the prefix (the payoff)

Here's where the bits earn their keep. When a router (or your Linux host, or the VPC's implicit router) decides where to send a packet, it does a **bitwise AND** of the destination IP against each route's subnet mask, and checks whether the result equals that route's network address. The prefix with the **longest match wins** (longest-prefix match).

```
FORWARDING DECISION for destination 172.16.3.10

Route table:
   10.0.0.0/16     → send out eth1
   172.16.3.0/24   → send out eth0        ← 24 network bits
   172.16.0.0/12   → send out eth0        ← 12 network bits
   0.0.0.0/0       → send to default gateway (catch-all)

Router masks the destination with each /n and compares:
   172.16.3.10 AND /24 mask (255.255.255.0) = 172.16.3.0  ✔ matches route
   172.16.3.10 AND /12 mask (255.240.0.0)   = 172.16.0.0  ✔ also matches!
   → BOTH match, but /24 is longer → LONGEST PREFIX WINS → eth0 via the /24 route.
```

This is the mechanism behind everything:
- A **VPC route table** is exactly this table. `10.0.0.0/16 → local` means "same VPC, deliver internally"; `0.0.0.0/0 → igw-xxxx` means "everything else → internet gateway."
- **This is also why overlapping CIDRs are fatal.** If two peered VPCs both contain `10.0.1.0/24`, the router sees the *same network ID from two directions* and has no rule to break the tie. Routing becomes ambiguous, so AWS simply **refuses the peering connection** rather than silently blackhole traffic.

```
WHY OVERLAP IS FORBIDDEN

  VPC-A: 10.0.0.0/16          VPC-B: 10.0.0.0/16   (identical!)
        │                            │
        └──────────┐      ┌──────────┘
                   ▼      ▼
             peering router: "packet for 10.0.1.5 —
             is that VPC-A's 10.0.1.5 or VPC-B's 10.0.1.5?"
                   │
                   ▼
             AMBIGUOUS → AWS rejects the peering at creation time.
```

The subnet mask, by the way, is just the prefix written as dotted decimal: `/24` = `255.255.255.0` = 24 ones followed by 8 zeros in binary. Same information, two notations.

> **✅ Check yourself before Rung 4:** Draw the 32 bits for `10.0.5.130/26`. Where's the boundary? What are the network and broadcast addresses of *that specific* subnet, and how many usable hosts does it hold? (Derive: 6 host bits, block size 64, so this address falls in the `10.0.5.128/26` block → network `.128`, broadcast `.191`, 62 usable.)

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now that you've seen the bits, the jargon has somewhere to land.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **CIDR** | Classless Inter-Domain Routing — the whole `/n` scheme that replaced fixed classes | The prefix notation itself (Rung 3B) |
| **Prefix / prefix length** | The `n` in `/n` — how many leading bits are network | The boundary line (Rung 3A/B) |
| **Subnet mask** | The prefix as dotted decimal (`/24` = `255.255.255.0`) | Same info as prefix; used in the AND (Rung 3D) |
| **Network portion** | The fixed leading bits shared by all hosts in the subnet | Left of the boundary (Rung 3A) |
| **Host portion** | The free trailing bits that number individual hosts | Right of the boundary (Rung 3A) |
| **Network address** | All host bits = 0; names the subnet | Reserved address #1 (Rung 3C) |
| **Broadcast address** | All host bits = 1; reaches everyone on the subnet | Reserved address #2 (Rung 3C) |
| **Block size** | `2^(32−n)` — total addresses in the subnet | The count itself (Rung 2) |
| **Usable hosts** | `2^(32−n) − 2` — assignable to real machines | Block size minus the two reserved |
| **Broadcast domain** | The set of hosts a broadcast reaches (one subnet on L2) | The pain subnetting solves (Rung 1) |
| **Subnetting** | Borrowing host bits to split one network into smaller ones | Sliding the boundary right (Rung 3B) |
| **Supernetting / aggregation** | The reverse — merging small blocks into one shorter prefix | Sliding the boundary left |
| **Longest-prefix match** | Router picks the most specific matching route | The forwarding decision (Rung 3D) |
| **Classful (A/B/C)** | The obsolete fixed-size scheme CIDR replaced | Rung 1's pain |
| **VPC CIDR** | The big block you assign a whole VPC (e.g. `10.0.0.0/16`) | The parent block you subdivide |
| **Subnet (AWS)** | A CIDR slice of the VPC, pinned to one AZ | A child block (Rung 3B) |
| **Pod CIDR** | The block a CNI hands out to pods (`--pod-network-cidr`) | A block sized for pods, not nodes |
| **Service CIDR** | The virtual block for ClusterIP Services | A separate block, never overlapping pod CIDR |

### The big unlock: terms that are the *same thing wearing different names*

```
GROUP 1 — "how many network bits" (all describe the boundary):
   prefix = prefix length = the /n = (as dotted decimal) subnet mask
   → /24 and 255.255.255.0 are THE SAME FACT in two costumes.

GROUP 2 — "the un-assignable pair" (always exactly 2 per subnet):
   network address (all-zeros host bits) + broadcast address (all-ones host bits)
   → these are WHY it's "minus 2".

GROUP 3 — "sliding the boundary" (same operation, opposite directions):
   subnetting = boundary RIGHT (more, smaller nets)
   supernetting/aggregation = boundary LEFT (fewer, bigger nets)

GROUP 4 — "a block of addresses assigned to a scope" (same concept, different scope):
   VPC CIDR (whole VPC) ⊃ subnet CIDR (one AZ) ; pod CIDR & service CIDR (a cluster)
   → all are just "a /n block"; only the scope and who hands out IPs differ.
```

Hold those four groups and the vocabulary collapses from twenty terms to four ideas.

> **✅ Check yourself before Rung 5:** Someone says "the mask is 255.255.255.192." Without a table, what prefix is that, how many usable hosts, and what did the `192` in the last octet tell you? (Derive: `192` = `11000000` = 2 more network bits than `/24`, so `/26`, block size 64, 62 usable.)

---

# RUNG 5 — The Trace 🎬
### *Follow ONE concrete assignment end-to-end*

Let's trace a real, concrete task: **you are given `172.16.3.0/30` and must fully work it out** — every address, its role, and where such a tiny subnet actually gets used. A `/30` is the classic point-to-point link size, so this trace is exactly what happens when a router-to-router link or a NAT-gateway link is provisioned.

**Step 1 — Read the prefix, find the host bits.**
`/30` → `32 − 30 = 2` host bits. So the block size is `2^2 = 4` addresses. Immediately you know this subnet spans exactly 4 IPs.

**Step 2 — Find the block boundary (the network address).**
Host bits are the last 2 bits of the final octet. The given address ends in `.0` (`00000000`) — its last two bits are `00`, so `.0` is already the start of a block. **Network address = `172.16.3.0`.**

**Step 3 — Enumerate all 4 addresses in binary.**
```
last octet, only the low 2 bits vary:

  000000 00 → 172.16.3.0   → NETWORK address     (reserved)
  000000 01 → 172.16.3.1   → usable host #1       ✔
  000000 10 → 172.16.3.2   → usable host #2       ✔
  000000 11 → 172.16.3.3   → BROADCAST address    (reserved)
```

**Step 4 — Apply the minus-2 rule.**
`4 total − 2 reserved = 2 usable`: `172.16.3.1` and `172.16.3.2`. Exactly enough for **two** endpoints — which is why `/30` is *the* point-to-point link subnet: one IP for each router end, nothing wasted (well, half-wasted: 2 of 4 are overhead).

**Step 5 — Where this actually lands in cloud.**
Router A gets `.1`, Router B gets `.2`. The two reserved addresses (`.0` network, `.3` broadcast) glue the subnet together. In AWS you'd see `/30`-ish tiny subnets for things like Transit Gateway attachments or VPN tunnel inside-CIDRs. And if you needed to squeeze even harder, **`/31` exists for point-to-point links** (RFC 3021): 2 total addresses, *both usable*, no network/broadcast waste — because on a pure 2-endpoint link, "broadcast" and "the other guy" are the same thing.

```
VISUAL OF THE TRACE: working out 172.16.3.0/30

  /30  →  32−30 = 2 host bits  →  2^2 = 4 addresses  →  4−2 = 2 usable
                       │
                       ▼
   ┌───────────────────────────────────────────────┐
   │  172.16.3.0   NETWORK   ── the subnet's name    │
   │  172.16.3.1   host      ── Router A eth0   ✔    │
   │  172.16.3.2   host      ── Router B eth0   ✔    │
   │  172.16.3.3   BROADCAST ── shout to the link    │
   └───────────────────────────────────────────────┘
        point-to-point link, 2 endpoints, 0 spare.

   (compare /31: 172.16.3.0 & .1 BOTH usable — no reserved pair)
```

> **✅ Check yourself before Rung 6:** You're handed `10.0.0.8/29`. Trace it: how many host bits, how many usable, what's the network and broadcast address, and what's the *range* of usable IPs? (Derive: 3 host bits → 8 total → 6 usable; block starts at `.8`; network `.8`, broadcast `.15`, usable `.9`–`.14`.)

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand CIDR best by seeing exactly what it *replaced* and where it *stops*.

### The alternative: classful addressing

Before CIDR (RFC 1518/1519, 1993), your network size was locked to the class of the first octet — no prefix, no choice.

```
CLASSFUL vs CIDR

Classful:  the FIRST BITS of the address dictate the size.
   1.x.x.x  – 126.x.x.x   → Class A → /8  (16.7M hosts, fixed)
   128.x.x.x – 191.x.x.x  → Class B → /16 (65k hosts, fixed)
   192.x.x.x – 223.x.x.x  → Class C → /24 (254 hosts, fixed)
   → THREE sizes. Take it or leave it.

CIDR:  YOU choose the boundary anywhere from /0 to /32.
   Need ~500 hosts? Use /23 (510 usable). Need 2? Use /30.
   → Any size, aligned to the actual requirement.
```

### What CIDR can do that classful can't (and vice versa)

| Capability | Classful (A/B/C) | CIDR (`/n`) | Why the difference |
|---|---|---|---|
| Pick a network size to fit the need | ❌ 3 fixed sizes | ✅ any prefix `/0`–`/32` | The boundary is arbitrary, not tied to the first octet |
| Right-size to avoid waste (500 hosts) | ❌ forced to a /16 | ✅ `/23` = 510 usable | You borrow exactly the bits you need |
| Aggregate many routes into one advert | ❌ | ✅ supernetting | Shorter prefix summarizes a range |
| Split one block into per-AZ subnets | ❌ (no notion of sub-splitting) | ✅ | Slide the boundary right |
| Human-obvious size at a glance | ✅ (A/B/C is quick) | ⚠️ must read the prefix | Class is coarse but instant; CIDR is precise but needs the `/n` |

The pattern in the "why" column is always the same: **CIDR lets the boundary fall on any bit, classful forced it onto octet lines.** That single freedom is the whole invention.

### When would I NOT think about subnetting?

- **Inside a single subnet.** If everything you're doing lives in one `/24`, you don't re-subnet; you just assign hosts.
- **When the platform picks for you.** Managed offerings (some CNIs, small VPC defaults) auto-carve blocks; you only intervene when you need custom sizing or peering.
- **Pure IPv6.** With a `/64` per subnet as the norm (`2^64` hosts), you rarely sweat host-count math — the pain is different there.

**One-sentence "why this over that":**
> Use CIDR (always, today) because it lets you size every network to its real requirement and aggregate routes; classful is only worth knowing as the historical pain that explains *why* CIDR looks the way it does.

> **✅ Check yourself before Rung 7:** Explain to a colleague why a company needing exactly 400 host addresses *wasted ~65,000 addresses* under classful but wastes only ~100 under CIDR. Name the two prefixes involved. (Classful forces `/16`; CIDR uses `/23` = 510 usable.)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

This is where the tools finally arrive. For each: read the prediction, cover the outcome, decide if you agree, *then* run it. The habit of predicting first is what converts "I ran `ipcalc`" into "I understand subnets."

Install the helper once if needed:
```bash
# Debian/Ubuntu:  sudo apt-get install -y ipcalc
# macOS:          brew install ipcalc
# (ipcalc is a pure calculator — it makes no network changes, safe to run anywhere)
```

---

## Prediction 1 — The normal case: `/24` gives 254 usable, and I can predict the boundaries

> **My prediction:** "If I run `ipcalc 172.16.3.0/24`, then it will report **256 total addresses**, **254 usable** hosts (`172.16.3.1`–`172.16.3.254`), network `172.16.3.0`, and broadcast `172.16.3.255` — *because* `/24` leaves 8 host bits, `2^8 = 256`, minus the network and broadcast pair = 254."

```bash
ipcalc 172.16.3.0/24
# Expected key lines:
#   Netmask:   255.255.255.0 = 24
#   Network:   172.16.3.0/24
#   HostMin:   172.16.3.1
#   HostMax:   172.16.3.254
#   Broadcast: 172.16.3.255
#   Hosts/Net: 254
```

**Verify:** `Hosts/Net: 254` and the `.1`–`.254` range confirm the minus-2 rule. If you predicted 256 usable, repair that — you forgot the two reserved addresses.

---

## Prediction 2 — Splitting a `/24` into four `/26` subnets (the per-AZ carve)

> **My prediction:** "If I ask `ipcalc` to split `192.168.1.0/24` into `/26` subnets, then I'll get **exactly 4** subnets, each with **64 total / 62 usable**, starting at `.0`, `.64`, `.128`, `.192` — *because* stealing 2 host bits (`/24`→`/26`) creates `2^2 = 4` blocks of size `2^6 = 64`."

```bash
# The '/26' after the slash tells ipcalc the target subnet size to split into:
ipcalc 192.168.1.0/24 /26
# Expected — four networks:
#   192.168.1.0/26    (hosts .1 – .62,   broadcast .63)
#   192.168.1.64/26   (hosts .65 – .126, broadcast .127)
#   192.168.1.128/26  (hosts .129 – .190, broadcast .191)
#   192.168.1.192/26  (hosts .193 – .254, broadcast .255)
```

**Verify:** Four blocks, boundaries at multiples of 64, each `62` usable. This is *literally* the "one subnet per Availability Zone" pattern — four AZs, four `/26`s, no overlap. If you got the boundaries wrong (e.g. expected `.50`), your block-size intuition needs a rep: blocks always start at multiples of their size.

---

## Prediction 3 — The edge case: `/30` and `/31` point-to-point links

> **My prediction:** "If I calculate `172.16.3.0/30`, then it reports **4 total / 2 usable** (`.1` and `.2`). And if I calculate a `/31`, then it reports **2 usable with NO separate broadcast** — *because* `/30` has 2 host bits (4 addrs, minus 2) while `/31` (RFC 3021) is the special point-to-point case where both addresses are usable."

```bash
ipcalc 172.16.3.0/30
#   HostMin: 172.16.3.1
#   HostMax: 172.16.3.2
#   Hosts/Net: 2          ← exactly two endpoints

ipcalc 172.16.3.0/31
#   HostMin: 172.16.3.0
#   HostMax: 172.16.3.1
#   Hosts/Net: 2          ← both usable, no network/broadcast reserved
```

**Verify:** `/30` gives `.1`–`.2`; `/31` gives `.0`–`.1` with *both* usable. If your `/31` output showed only 0 usable hosts, your `ipcalc` predates RFC 3021 support — the concept still holds: `/31` is the 2-usable point-to-point special case.

---

## Prediction 4 — The Kubernetes case: sizing a pod CIDR so you don't exhaust IPs

> **My prediction:** "If I initialize a cluster with `kubeadm --pod-network-cidr=10.244.0.0/16` and my CNI hands each node a `/24` slice, then I can support up to **256 nodes** (`2^(24−16) = 2^8`), each node numbering up to ~254 pods — *because* the pod CIDR is a `/16` (65,536 pod IPs) carved into per-node `/24`s. If I'd instead used a `/24` pod CIDR, I'd have room for well under 254 pods total and hit `failed to assign IP` fast."

```bash
# Cluster init declares the pod network block (Flannel's classic default):
kubeadm init --pod-network-cidr=10.244.0.0/16

# After the CNI is up, see the per-node slice it assigned:
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# Expected, e.g.:
#   node-1    10.244.0.0/24
#   node-2    10.244.1.0/24
#   node-3    10.244.2.0/24   ← each node owns a /24 = up to ~254 pod IPs

# Sanity-check the math with ipcalc:
ipcalc 10.244.0.0/16
#   Hosts/Net: 65534     ← total pod IP budget for the whole cluster
```

**Verify:** Each node's `podCIDR` is a distinct `/24` inside the `/16`. If pods start failing to schedule with IP-assignment errors, your pod CIDR was too small for `nodes × pods-per-node` — that's **CNI IP exhaustion**, and the fix is a larger (shorter-prefix) pod CIDR *before* the cluster grows. On EKS with the VPC-CNI, pod IPs come from the *VPC subnet* itself, so an undersized subnet exhausts real VPC addresses — size the subnet, not just the pod CIDR.

---

## Prediction 5 — The cloud failure case: overlapping VPC CIDRs refuse to peer

> **My prediction:** "If I try to peer two VPCs that both use `10.0.0.0/16`, then AWS will **reject the peering request** with an overlapping-CIDR error — *because* identical network IDs make routing ambiguous, so AWS refuses at creation time rather than blackhole traffic."

```bash
# Inspect the CIDRs of two VPCs before peering:
aws ec2 describe-vpcs \
  --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock}' --output table
# If two rows both show 10.0.0.0/16, peering WILL fail.

# Attempt the peering (this is the call that errors on overlap):
aws ec2 create-vpc-peering-connection \
  --vpc-id vpc-aaaa1111 \
  --peer-vpc-id vpc-bbbb2222
# Expected error on overlap:
#   An error occurred (InvalidVpcPeeringConnection.OverlappingCidr) ...
#   The CIDR '10.0.0.0/16' conflicts with another connection's CIDR.
```

**Verify:** The call fails with `OverlappingCidr`. The lesson: choose **non-overlapping** CIDRs up front for every VPC you might ever connect (peering, Transit Gateway, or hybrid VPN to on-prem). A common scheme: `10.0.0.0/16` for VPC-A, `10.1.0.0/16` for VPC-B, `10.2.0.0/16` for shared services — they nest under `10.0.0.0/8` but never overlap. If your peering *succeeded* with overlapping CIDRs, double-check you weren't reading two different accounts' identical-looking-but-distinct VPCs.

---

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

# 🏔️ CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> A CIDR prefix `/n` freezes the first `n` of an IPv4 address's 32 bits as a shared network ID and frees the remaining `32 − n` bits to number hosts, giving `2^(32−n)` total addresses and `2^(32−n) − 2` usable ones after reserving the network and broadcast addresses.

**Explain it to a beginner in 3 sentences:**
> 1. An IP address is 32 ones-and-zeros, and the `/n` in something like `10.0.0.0/16` just says "the first `n` bits name the neighborhood; the rest number the houses in it."
> 2. So the size of a subnet is `2` raised to the number of leftover host bits — do `32 − n`, then `2^that` — and you subtract 2 because every subnet reserves one address as its name (network) and one to shout at everyone (broadcast).
> 3. In the cloud this is the whole game: you give a VPC a big block like `10.0.0.0/16`, slice a smaller non-overlapping block to each Availability Zone and to your pods, and you keep every VPC's block distinct so they can peer without the router getting confused.

**Map of sub-parts → the one core idea (`/n` = first `n` bits fixed, `32 − n` free):**

```
Total addresses (2^(32−n))     → count the FREE host bits, raise 2 to it
Usable hosts (−2)              → drop the all-0 (network) & all-1 (broadcast) patterns
Network vs broadcast address   → the two reserved host-bit patterns
/8 /16 /24 /26 /28 /30 /31     → just different places to put the boundary
The 32 − prefix trick          → literally "how many free host bits remain"
VPC CIDR → per-AZ subnets       → slide the boundary right to carve the block
Pod vs Service CIDR sizing      → separate blocks, sized by free host bits
No-overlap for peering          → two subnets can't share the same fixed network ID
```

Eight rows, one idea: **the prefix is a boundary, and everything is a consequence of where you draw it.**

**Worked reference (derive these, don't memorize them):**

| Prefix | Host bits (`32−n`) | Total (`2^h`) | Usable (`−2`) | Typical use |
|---|---|---|---|---|
| `/8` | 24 | 16,777,216 | 16,777,214 | Whole private range `10.0.0.0/8` |
| `/16` | 16 | 65,536 | 65,534 | A VPC (`10.0.0.0/16`) or Flannel pod CIDR |
| `/24` | 8 | 256 | 254 (AWS: 251) | A subnet / small LAN |
| `/26` | 6 | 64 | 62 | One subnet per AZ |
| `/28` | 4 | 16 | 14 | Small subnet / tiny service block |
| `/30` | 2 | 4 | 2 | Point-to-point link |
| `/31` | 1 | 2 | 2 (RFC 3021) | Point-to-point, no waste |

**Which rung will I most likely need to revisit hands-on?**

- **Rung 3D (the router's longest-prefix match)** — it's the least visual and it's *the* reason overlaps are fatal. Fix: run `ip route get <some-ip>` on a Linux box and watch which route it picks; make the abstract concrete.
- **Rung 7, Prediction 4 (pod/service CIDR sizing)** — the cloud consequence bites hardest and is easy to get wrong under pressure. Rehearse `nodes × pods-per-node` against your pod CIDR budget until it's reflexive.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [IP addressing](02-ip-addressing.md) — the 32-bit addresses, octets, and private ranges that subnetting slices up.
- [Routing and forwarding](08-routing-and-forwarding.md) — how longest-prefix match uses your CIDR blocks to move packets.
- [MAC addresses, switching & ARP](05-mac-addresses-switching-arp.md) — the broadcast domain that a too-large flat subnet drowns.
- [AWS VPC](20-aws-vpc.md) — VPC CIDR, per-AZ subnets, route tables, and public vs private subnets in practice.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — pod CIDR, per-node slices, and CNI IP exhaustion.
- [NAT and PAT](14-nat-and-pat.md) — how private CIDR blocks reach the internet without needing public addresses.
