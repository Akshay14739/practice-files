# DNS — The Internet's Phone Book

*How a name like `google.com` becomes an IP address — and why your pod can't reach a Service until this works.*

---

## 🪜 Rung 0 — The Setup

You are a cloud/Kubernetes platform engineer. You live in `kubectl`, the AWS console, and Terraform. You have deployed a hundred workloads. But today something small and infuriating landed on your desk:

> A developer files a ticket: *"My pod can't reach `payments`. `curl payments` just hangs. But `curl 10.100.42.7` works instantly. Networking is broken."*

You already know networking is NOT broken — the IP works. What is broken is the step *before* the packet ever leaves: turning the **name** `payments` into the **address** `10.100.42.7`. That translation is **DNS** — the Domain Name System — the service that maps human-friendly names to machine-friendly IP addresses.

**What you already know (and we'll build on):**

- An IP address (from [IP addressing](02-ip-addressing.md)) is how machines actually find each other — `142.250.72.14`, not `google.com`.
- A port (from [ports & sockets](04-ports-sockets-multiplexing.md)) picks the application; DNS itself lives on **UDP port 53**.
- TCP and UDP (from [transport](07-transport-layer-tcp-udp.md)) are the two ways to send that query — DNS uses **both**, and *when* it uses each matters.
- In Kubernetes, a **Service** gives a stable name to a shifting set of pods. That name only means anything because **CoreDNS** answers for it.

Here is the mental frame for the whole document: **DNS is a lookup that happens BEFORE the OSI data journey even begins.** Before your browser opens a TCP socket, before the 3-way handshake, before a single byte of HTTP — your machine must first *ask a completely separate question over a completely separate connection*: "what is the IP for this name?" DNS is the phone book you open before you dial.

---

## 🔥 Rung 1 — The Pain

Imagine the early internet with **no DNS**. Every computer that wanted to reach another had to know its numeric IP address. To make this bearable, in the 1970s–80s every machine kept a single flat file — **`HOSTS.TXT`** — listing every known host name and its IP. Stanford Research Institute (SRI) maintained the master copy. If you wanted to add or change a host, you *emailed SRI*, they edited the file, and everyone on the internet had to **download the whole file again**.

Sit with how badly that scales:

```
   HOSTS.TXT — one flat file, copied to EVERY machine on Earth
   ┌───────────────────────────────────────────────┐
   │ 10.0.0.1    mit-prep                           │
   │ 10.0.0.2    stanford-ai                        │
   │ 10.0.0.3    ucla-net                           │
   │ ...         ...        (grows with the whole   │
   │ ...         ...         internet, forever)     │
   └───────────────────────────────────────────────┘
        ▲                          ▲
        │ email SRI to change      │ re-download the WHOLE file
        │ ONE line                 │ to see anyone's change
   every admin on Earth ─────────────────────► pain
```

**Why it hurt:**

- **No scale.** One file for the entire internet. Every new host meant a bigger file for *everyone*.
- **Name collisions.** Two sites both want `mail`? Tough — it's one global namespace with one owner.
- **Central bottleneck.** One team (SRI) was the single point of change and failure for the whole planet.
- **Stale everywhere.** Your copy was as fresh as the last time you downloaded a file that was *always* out of date.

DNS was designed by Paul Mockapetris in 1983 to kill all four problems at once. Its trick — the thing everything else derives from — is **delegation**: instead of one giant file owned by one team, split the namespace into a **tree**, and let each branch's owner run their own server answering only for their own branch.

**Who feels the pain most today, without DNS?** You do, as a cluster operator. Kubernetes pods are *ephemeral* — a pod's IP changes every time it restarts, every deploy, every scale event. If your app hard-coded pod IPs, it would break constantly. The entire Service-discovery model — "talk to the name `payments`, we'll route it to whichever pods are alive" — is DNS solving the exact same problem SRI had, but for pods that come and go every few seconds.

> **Check yourself before Rung 2:** If DNS is a distributed tree where each owner runs their own server, what problem does that create that a single `HOSTS.TXT` file never had — and what must the system add to make the tree usable? (Hint: how do you *find* the right server, and how do you avoid asking it every single time?)

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it:

> **DNS is a distributed, hierarchical, cached lookup: you follow a delegation chain down a tree of name-owners — root → TLD → authoritative — and everyone remembers the answer for a while (the TTL).**

Everything else is a consequence of that one sentence. Let's derive the whole system from it:

- **"Distributed"** → no single file, no single owner. Derives the need for **many servers** and a way to know which one to ask.
- **"Hierarchical / a tree"** → names are read **right to left**: `www.google.com.` is `[root] → [com] → [google] → [www]`. Derives the **root servers, TLD servers, and authoritative servers**.
- **"Delegation chain"** → each level doesn't know the final answer; it knows **who to ask next**. The root doesn't know Google's IP — it knows who runs `.com`. Derives **NS records** (pointers to the next server down).
- **"Lookup"** → someone has to do the legwork of walking the chain. Derives the **recursive resolver** (does the walking for you) vs **iterative queries** (each server just says "go ask them").
- **"Cached, for a while (TTL)"** → nobody wants to walk the whole tree every time. Derives **caching at every layer** and the **TTL** (time-to-live) that says how long a cached answer is valid. This is the single feature that makes DNS fast enough to exist.

If you remember only one thing: **DNS walks DOWN a tree of owners, and CACHES the answer on the way back.** Root and TLD servers would melt under the world's traffic if caching didn't absorb ~99% of it.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> DNS is the internet's phone directory: you give it a name (google.com) and it returns the number (the machine's address). Four characters make that happen:
>
> - **The asker on your own computer** — lazy on purpose. It asks exactly one helper "what's the number for google.com?" and just waits.
> - **The helper (the "resolver")** — the librarian who does all the legwork on your behalf and remembers answers for next time.
> - **The directory desks** — they don't know the final answer, but they always know *who to ask next* ("for anything ending in .com, go see that desk").
> - **The owner's own record-keeper** — the one office that truly holds google.com's current numbers.
>
> **Who does the walking:** you ask one question and wait for a final answer; the librarian is the one who visits desk after desk. That split of labor is the heart of DNS.
>
> **Reading a name backwards.** A name like www.google.com is a set of nested directories read right-to-left: the master index, then the ".com" section, then Google's own pages, then the specific entry. Each level simply points you to the keeper of the next level down — no single giant phone book anywhere.
>
> **The master index** is run as 13 named clusters — really hundreds of copies worldwide that share the same addresses, so you're automatically served by the nearest one — coordinated by a nonprofit (ICANN). And you never *buy* a domain name; you *rent* your line in the directory, yearly. Stop paying and your entry is erased.
>
> **Remembering answers.** Every answer comes with an expiry time ("trust this for 300 seconds"). Browsers, your computer, and the librarian all keep copies until they expire — which is why changing a number "isn't instant": old copies live on until their timers run out. Pros shorten the timer *before* making a change.
>
> **How the question travels:** normally as a single quick postcard each way (no call setup). If the answer is too big for a postcard, both sides switch to a proper phone call (a reliable connection). Newer, private variants send the same question in a sealed envelope so nobody in between can read it.
>
> **Inside Kubernetes** (software that runs fleets of apps): the cluster runs its *own* little librarian (CoreDNS) with a well-known address, and every app is told "send all name questions there." Apps can use short nicknames because the system automatically tries adding the cluster's own "surname" endings — with one gotcha: for outside names like google.com, it tries all the wrong endings *first*, wasting several lookups. Same directory tree as the internet, with a private branch grafted on.

*Now the original technical deep-dive — the same ideas, in precise form:*

Let's open the hood. There are four kinds of players, and it's crucial you don't confuse them, because they do genuinely different jobs.

### The four players

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │  1. STUB RESOLVER   — lives on YOUR machine (the OS / libc / systemd) │
 │       "I don't do legwork. I ask ONE server and wait for the answer." │
 │       Config lives in  /etc/resolv.conf                               │
 ├──────────────────────────────────────────────────────────────────────┤
 │  2. RECURSIVE RESOLVER — your ISP's server, or 8.8.8.8, or CoreDNS.   │
 │       "I DO the legwork. I'll walk the whole tree for you and cache." │
 ├──────────────────────────────────────────────────────────────────────┤
 │  3. ROOT + TLD SERVERS — the directory. "I don't know the answer,    │
 │       but I know who to ask NEXT." (delegation via NS records)        │
 ├──────────────────────────────────────────────────────────────────────┤
 │  4. AUTHORITATIVE SERVER — the source of truth for ONE zone.         │
 │       "I OWN google.com's records. Here is the actual A record."      │
 └──────────────────────────────────────────────────────────────────────┘
```

The single most important distinction here: **the stub resolver asks ONE question and waits. The recursive resolver does ALL the walking.** This is the difference between a **recursive query** ("give me the final answer, I'll wait") and **iterative queries** ("just tell me the next server to ask").

### Recursive vs iterative — who does the work

```
  YOUR MACHINE                 RECURSIVE RESOLVER              THE TREE
  (stub resolver)              (e.g. ISP / 8.8.8.8)
  ┌──────────┐                 ┌───────────────┐
  │ "what is │  RECURSIVE      │ "on it. wait  │  ITERATIVE (resolver asks each,
  │ google   │ ─── query ────► │  right there."│   gets 'ask them' pointers)
  │ .com?"   │                 │               │
  │          │ ◄── answer ──── │               │──► ROOT: "ask the .com server"
  └──────────┘   (final IP)    │               │──► .com TLD: "ask ns1.google.com"
                               │               │──► ns1.google.com: "142.250.72.14"
                               └───────────────┘
     ONE query, waits            does 3+ queries, walks the tree
```

You (the stub) make **one recursive query**. The resolver makes **several iterative queries** on your behalf. That division of labor is the beating heart of DNS.

### The tree, read right to left

A fully-qualified domain name (FQDN) has an invisible trailing dot — the **root**:

```
        www . google . com .
         │      │       │   └── ROOT zone           (the "." — 13 root clusters)
         │      │       └────── TOP-LEVEL DOMAIN     (.com — run by Verisign)
         │      └────────────── SECOND-LEVEL DOMAIN  (google — Google's zone)
         └───────────────────── HOSTNAME / label     (the specific host)

   Resolution walks RIGHT → LEFT:  root, then .com, then google, then www.
```

Each dot is a **delegation boundary**. The owner of each level runs (or delegates) a server, and hands out an **NS record** pointing to the server for the next level down. That's how the tree stays navigable without any central file.

### Who runs the roots

There are **13 logical root server clusters**, named `a.root-servers.net` through `m.root-servers.net`. Why 13? A historical limit: an unfragmented 512-byte UDP DNS response could hold exactly 13 root addresses. They are **not** 13 physical machines — each letter is a globally distributed fleet of hundreds of physical servers sharing one IP via **anycast** (many machines announce the same IP; BGP routes you to the nearest). They are operated by 12 independent organizations (Verisign runs two: A and J). Above them sits **ICANN** (the Internet Corporation for Assigned Names and Numbers), the nonprofit that coordinates the root zone and the whole naming system.

Which is why you **rent, not buy, a domain**: you pay a *registrar* (accredited by ICANN) an annual fee for the *right to control a name's records in the TLD's zone*. Stop paying and the delegation is withdrawn — the name goes back in the pool. You never owned `mycompany.com`; you leased its entry in `.com`.

### Caching + TTL — the layer that makes it survivable

Every answer carries a **TTL** (time-to-live, in seconds). Every layer that sees the answer may cache it until the TTL expires:

```
  ANSWER: google.com  A  142.250.72.14   TTL=300   (cache me for 300s)

  Cached at EVERY level, each counting down its own TTL:
  ┌─────────────┐   ┌──────────────┐   ┌────────────┐   ┌──────────────┐
  │ browser     │   │ OS stub      │   │ recursive  │   │ authoritative│
  │ cache       │   │ cache        │   │ resolver   │   │ (the source) │
  │ TTL: 120s   │   │ TTL: 200s    │   │ TTL: 280s  │   │ TTL: 300s    │
  └─────────────┘   └──────────────┘   └────────────┘   └──────────────┘
     hottest ◄──────────────────────────────────────────────► coldest
```

**This is why DNS changes are "not instant."** Lower the TTL *before* a migration (say to 60s) so caches expire fast; a record still cached at TTL=3600 will keep sending traffic to the old IP for up to an hour after you change it. Every on-call engineer who has ever said "why is it *still* resolving to the old load balancer?" has been bitten by a TTL they forgot to lower first.

### The transport: UDP/53, with TCP as the fallback

DNS runs on **port 53**, and it prefers **UDP**:

- **UDP/53 for normal queries.** A query and its answer are tiny; UDP has no handshake, so it's one packet out, one packet back — fast and cheap. No connection setup ([UDP vs TCP](07-transport-layer-tcp-udp.md)).
- **TCP/53 when the answer is large.** If a response exceeds the UDP size limit, the server sets the **TC (truncated) flag** and the resolver **retries over TCP**. Also used for **zone transfers** (AXFR/IXFR) — a secondary DNS server copying an entire zone from the primary, which is far too big for UDP and needs TCP's reliability.
- Modern encrypted variants: **DoT** (DNS-over-TLS, TCP/853) and **DoH** (DNS-over-HTTPS, 443) wrap the query so your ISP can't read or tamper with it — but the *logic* above is identical.

### Now the Kubernetes machinery — same tree, private branch

Here is where it clicks for you. A Kubernetes cluster runs its **own** DNS server — **CoreDNS** — as pods in `kube-system`, fronted by a Service usually named `kube-dns` with a well-known **ClusterIP of `10.96.0.10`** (default in kubeadm clusters; EKS commonly uses `10.100.0.10` — it's the `.10` of the Service CIDR).

Every pod is born with an `/etc/resolv.conf` the kubelet injects:

```text
# /etc/resolv.conf inside a pod in namespace "shop"
nameserver 10.96.0.10
search shop.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

Read every line, because each one is machinery:

- **`nameserver 10.96.0.10`** → the pod's stub resolver sends *all* queries to CoreDNS (via that ClusterIP, which kube-proxy DNAT-loadbalances to a real CoreDNS pod — see [Services & kube-proxy](25-kubernetes-services-kube-proxy.md)).
- **`search ...`** → suffixes the OS appends to short names. So `curl payments` gets tried as `payments.shop.svc.cluster.local`, then `payments.svc.cluster.local`, then `payments.cluster.local`. This is why `curl payments` works *inside* the right namespace.
- **`options ndots:5`** → the gotcha. If a name has **fewer than 5 dots**, the OS tries it **with the search suffixes FIRST**, and only tries it as-is (absolute) last. `google.com` has 1 dot < 5, so a pod resolving `google.com` fires off `google.com.shop.svc.cluster.local` (NXDOMAIN), `google.com.svc.cluster.local` (NXDOMAIN), `google.com.cluster.local` (NXDOMAIN) — three wasted lookups — *before* finally trying `google.com` and succeeding. Multiply that by every pod and you get the classic "our external DNS is slow" incident. Fix: use a trailing dot (`google.com.`) to force absolute, or tune ndots.

CoreDNS answers cluster names authoritatively (via its `kubernetes` plugin, watching the API server) and **forwards** anything it doesn't own (like `google.com`) upstream — usually to the node's own resolver / the VPC resolver at **`169.254.169.253`** (the AmazonProvidedDNS, the `.2` of your VPC CIDR, reached at the link-local address). So CoreDNS is *itself* a recursive resolver for your pods, and a stub-forwarder to the real internet. Same tree. Private branch grafted on.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Stub resolver** | The tiny client in your OS/libc that asks one server and waits | On your machine; reads `/etc/resolv.conf` |
| **Recursive resolver** | The server that *walks the tree for you* and caches | ISP, `8.8.8.8`, `1.1.1.1`, or CoreDNS forwarding |
| **Iterative query** | "Just tell me the next server to ask" | What the resolver sends to root/TLD/auth |
| **Recursive query** | "Give me the final answer, I'll wait" | What the stub sends to the resolver |
| **Root server** | Top of the tree; points to TLD servers | 13 logical clusters, `a`–`m.root-servers.net`, anycast |
| **TLD server** | Owns a top-level domain (`.com`, `.org`, `.io`) | Points to the authoritative server for a domain |
| **Authoritative server** | The source of truth for one **zone** | Holds the real A/AAAA/MX/etc. records |
| **Zone** | A slice of the namespace one server is authoritative for | e.g. `google.com`'s records |
| **NS record** | Pointer: "the server for this zone is here" | The delegation glue between tree levels |
| **TTL** | Seconds a record may be cached before re-fetching | Stamped on every answer; enables all caching |
| **FQDN** | Fully-qualified name with the trailing root dot | `www.google.com.` — unambiguous, absolute |
| **A record** | Name → IPv4 address | `google.com → 142.250.72.14` |
| **AAAA record** | Name → IPv6 address | `google.com → 2607:f8b0:...` |
| **CNAME** | Alias: "this name is really that other name" | `www → example.com`; resolver re-resolves the target |
| **MX record** | Mail exchanger for a domain, with priority | Where email for `@domain` is delivered (SMTP, port 25) |
| **TXT record** | Arbitrary text (SPF, DKIM, domain-ownership proofs) | Verification, email auth |
| **SRV record** | Service location: name → host **+ port** + priority/weight | Used by CoreDNS for `_port._proto.svc...` |
| **PTR record** | **Reverse** lookup: IP → name | Lives in `in-addr.arpa` (v4) / `ip6.arpa` (v6) |
| **Registrar** | ICANN-accredited company you rent a domain through | Where you set your NS records |
| **ICANN** | Nonprofit coordinating the root zone & TLDs | Governs the whole namespace |
| **Anycast** | Many servers sharing one IP; BGP routes to nearest | How 13 root "clusters" are really hundreds of machines |
| **CoreDNS** | The DNS server running inside your cluster | Answers `*.svc.cluster.local`, forwards the rest |
| **kube-dns Service** | The ClusterIP fronting CoreDNS pods | `10.96.0.10`, the `nameserver` in every pod |
| **ndots** | Threshold of dots below which search suffixes are tried first | `resolv.conf` option; the multi-query gotcha |
| **ExternalName** | A Service that resolves to an external CNAME | CoreDNS returns a CNAME, no ClusterIP |
| **Headless Service** | A Service with `clusterIP: None` | DNS returns one **A record per pod**, not one VIP |

**Same kind of thing, different names:**

- **Resolver / nameserver / `8.8.8.8` / CoreDNS forwarder** — all *recursive resolvers*: things that do the tree-walking for a stub.
- **A / AAAA / CNAME** — all *forward name → address (or alias)* records; A is IPv4, AAAA is IPv6, CNAME is "go look at another name."
- **NS / SOA delegation** — all *"the authority for this zone lives over there"* pointers.
- **PTR / reverse zone / `in-addr.arpa`** — all the same *IP → name* mechanism, just the tree run backwards.
- **`resolv.conf` `search` domains / Kubernetes `cluster.local` suffix / ndots** — all the *"complete this short name into a full one"* mechanism.
- **Recursive resolver / stub resolver** — both are "resolvers," but one *does the work* and one *delegates the work*. Don't fuse them.

> **Check yourself before Rung 5:** A CNAME points one name at another name; an A record points a name at an IP. If you ask a resolver for the A record of a name that is actually a CNAME, what extra work must the resolver do before it can hand you back an IP — and how does that relate to Kubernetes `ExternalName`?

---

## 🔬 Rung 5 — The Trace

Let's follow **one** real resolution end to end: your laptop resolving `www.example.com` for the first time (nothing cached anywhere). Watch which player does what at each hop.

```
 STEP 0  You type www.example.com. Browser checks its own cache: MISS.
         OS stub resolver checks its cache: MISS. Reads /etc/resolv.conf.

 STEP 1  Stub → Recursive resolver (UDP/53):  RECURSIVE query
         "Give me the A record for www.example.com. I'll wait."
         ┌────────┐  "A? www.example.com"   ┌───────────────┐
         │  STUB  │ ───────────────────────►│  RECURSIVE     │
         └────────┘                         │  RESOLVER      │
                                            └───────────────┘

 STEP 2  Resolver cache: MISS. It starts walking (ITERATIVE queries):

         Resolver → ROOT server:  "A? www.example.com"
         ROOT     → Resolver:     "I don't know. Ask the .com TLD:
                                   NS = a.gtld-servers.net (+ glue IP)."

 STEP 3  Resolver → .com TLD server:  "A? www.example.com"
         TLD      → Resolver:  "I don't know the IP. Ask example.com's
                                authoritative server: NS = ns.example.com."

 STEP 4  Resolver → ns.example.com (AUTHORITATIVE):  "A? www.example.com"
         AUTH     → Resolver:  "YES. A = 93.184.216.34, TTL = 3600."
                                (the source of truth answers)

 STEP 5  Resolver CACHES it (TTL 3600) and replies to the stub.
         Stub CACHES it. Browser CACHES it. Browser finally opens a
         TCP connection to 93.184.216.34:443 — the OSI journey begins NOW.
```

Visual of the walk (down the tree, then the answer flows back up and caches):

```
                         ┌────────┐
              (2) ask ──►│  ROOT  │──► "ask .com"
             ┌───────────└────────┘
             │           ┌────────┐
   ┌─────────▼──┐ (3) ──►│ .com   │──► "ask ns.example.com"
   │ RECURSIVE  │────────└────────┘
   │ RESOLVER   │        ┌──────────────┐
   │            │ (4) ──►│ AUTHORITATIVE│──► "93.184.216.34, TTL 3600"
   └─────┬──────┘        └──────────────┘
     (1) │ recursive         ▲
   ask   │ (5) answer +      │  every hop's answer gets CACHED
    ▲    ▼ cache             │  on the way back — next time: 1 hop.
 ┌──────────┐
 │   STUB   │  ─── now dials 93.184.216.34:443 (TCP handshake) ───►
 └──────────┘
```

**The load-bearing insight:** all of Steps 1–5 happen **before** your machine sends a single TCP SYN to the web server. DNS is a *separate transaction on UDP/53 to a different server*, and only when it returns an IP does the "real" connection (handshake, TLS, HTTP) even begin. That's the "before the OSI data journey starts" idea made concrete.

**The same trace inside your cluster:** a pod does `curl payments`. Stub reads `resolv.conf`, appends the search domain → asks CoreDNS (`10.96.0.10`) for `payments.shop.svc.cluster.local`. CoreDNS *is authoritative* for `svc.cluster.local` (it watches the API server), so it answers directly with the Service's ClusterIP — no root, no TLD, one hop. If instead the pod asked for `google.com`, CoreDNS wouldn't own it, so it **forwards** upstream (Steps 2–4 above happen out in the VPC / on the internet), then caches and returns.

---

## ⚖️ Rung 6 — The Contrast

The alternative to DNS is the old world: **static, manually-maintained name→IP mappings**. On any Linux/EKS node this still exists as `/etc/hosts` — the direct descendant of `HOSTS.TXT`. Kubernetes even lets you inject entries via a pod's `hostAliases`.

| Dimension | `/etc/hosts` (static file) | DNS (distributed system) |
|---|---|---|
| **Where names live** | One flat file, per machine | A global delegated tree of servers |
| **Update model** | Edit the file on *every* machine | Change one record on the authoritative server |
| **Scale** | Breaks past a handful of hosts | Runs the entire internet |
| **Freshness** | Only as fresh as your last manual edit | Bounded by TTL; propagates automatically |
| **Dynamic targets** | Hopeless for ephemeral IPs | Built for churn (pods, autoscaling, failover) |
| **Ownership** | You own your file; no coordination | Delegation: each zone owner controls their own |
| **Lookup order** | Checked *first* (via `nsswitch.conf`) | Checked after `hosts` (usually) |
| **Failure mode** | Silent staleness | NXDOMAIN, SERVFAIL, timeout — *observable* |

**What DNS can do that `/etc/hosts` cannot:** scale to billions of names, update globally from one place, hand back different answers per client (geo/latency routing at the CDN), express aliases (CNAME), mail routing (MX), and service+port discovery (SRV) — none of which a flat file expresses.

**What `/etc/hosts` can do that DNS cannot:** work with **zero infrastructure** and resolve *before* any network exists. It's checked first, so it's the perfect surgical override — pin `api.internal` to a test IP on one box without touching global DNS. This is exactly why a broken `/etc/hosts` entry can override healthy DNS and cause a maddening "only on my machine" bug.

**When would you NOT need DNS?** When you have exactly one static target and no churn — a hard-coded IP in a script, a single database host that never moves, a `hostAliases` override for a test. The moment there's more than a handful of names, or the targets move, or someone other than you needs to change a mapping, DNS wins.

> **Why this over that:** *Use `/etc/hosts` for a surgical, single-machine override; use DNS for anything that must scale, change, or be discovered — which in a cluster is everything.*

> **Check yourself before Rung 7:** Your pod's `/etc/hosts` has `10.0.0.5 payments` but CoreDNS says `payments.shop.svc.cluster.local` is `10.100.42.7`. When the app runs `curl payments`, which IP does it hit, and *why* — and which mechanism (search domains vs `nsswitch` order) decides it?

---

## 🧪 Rung 7 — The Prediction Test

Now the hands-on. For each: **write down your prediction first**, then run the command, then read the Verify note. Being *wrong* here is where the learning is.

### Prediction 1 — The normal case: walking the chain with `dig`

> **I predict:** `dig +short google.com` returns one or more IPv4 addresses. A plain `dig google.com` shows an `ANSWER SECTION` with an **A** record and a **TTL** that *counts down* if I run it twice in a row (because my resolver cached it). **BECAUSE** the resolver returns its cached copy with the remaining TTL, not a fresh full walk.

```bash
dig +short google.com
# 142.250.72.14        (a bare IP — the answer, nothing else)

dig google.com A
# ;; ANSWER SECTION:
# google.com.   300   IN   A   142.250.72.14
#               ^TTL              ^the A record
# ;; Query time: 24 msec        <- first time: real walk / upstream
# ;; SERVER: 127.0.0.53#53(...)  <- your stub/resolver

dig google.com A        # run again within a few seconds
# google.com.   287   IN   A   142.250.72.14   <- TTL dropped 300 -> 287
# ;; Query time: 0 msec          <- served from cache, near-instant
```

**Verify:** The TTL is *smaller* the second time and query time drops to ~0 ms. That falling number **is** caching happening in front of you. If the TTL *didn't* drop, your stub isn't caching (common on raw Linux — `systemd-resolved` caches, plain glibc may not) and each query walked upstream fresh.

### Prediction 2 — Different record types and the CNAME chase

> **I predict:** `dig gmail.com MX` shows **mail servers with priority numbers** (not IPs), and `dig www.github.com` reveals a **CNAME** in the answer before any A record — **BECAUSE** MX records point to mail exchangers by name, and many `www` names are aliases that the resolver must follow to a real A record.

```bash
dig +short gmail.com MX
# 5 gmail-smtp-in.l.google.com.       <- priority 5 (lowest = preferred)
# 10 alt1.gmail-smtp-in.l.google.com. <- priority 10 (fallback)
#  ^priority  ^the mail exchanger name (not an IP — mail goes here via SMTP/25)

dig www.github.com
# ;; ANSWER SECTION:
# www.github.com.   3600  IN  CNAME  github.com.   <- alias!
# github.com.       60    IN  A      140.82.112.3  <- resolver chased it to an A

# Reverse lookup (PTR): IP -> name
dig +short -x 8.8.8.8
# dns.google.        <- the PTR record in the 8.8.8.8.in-addr.arpa zone
```

**Verify:** MX answers are `priority name` pairs, never bare IPs — lower priority wins. `www.github.com` shows a **CNAME line then an A line**: proof the resolver followed the alias for you. The `-x` flag builds the reversed `in-addr.arpa` query automatically. If `-x` returns nothing, that IP's owner simply hasn't published a PTR (common, and it's why reverse DNS for mail servers is a spam-filtering signal).

### Prediction 3 — The failure/edge case: TCP fallback and NXDOMAIN

> **I predict:** Querying a name that doesn't exist returns **NXDOMAIN** (not an empty success), and forcing a large query or `+tcp` proves DNS will ride TCP/53 — **BECAUSE** DNS uses UDP by default but the protocol mandates a TCP fallback for large or reliable transfers.

```bash
dig +short does-not-exist-zzz9999.com
# (empty output)

dig does-not-exist-zzz9999.com | grep status
# ;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 4211
#                                      ^ the name authoritatively does NOT exist

# Force the query over TCP/53 (what happens on a truncated UDP response):
dig +tcp google.com A
# ;; Query time: 30 msec
# ;; SERVER: ...#53   -- same answer, carried over TCP instead of UDP

# See truncation + retry in action on a big answer (many records):
dig google.com ANY +noedns
# ...may show  ";; Truncated, retrying in TCP mode."  (TC flag was set)
```

**Verify:** `status: NXDOMAIN` means the *authoritative* server confirmed the name has no records — a definite "no," different from `SERVFAIL` (resolver broke) or an empty `NOERROR` (name exists but no record of that type). The `+tcp` run succeeds, proving port 53 speaks TCP too. If you *ever* see "Truncated, retrying in TCP mode," you've just watched the **TC flag → TCP fallback** mechanism fire.

### Prediction 4 — The Kubernetes case: CoreDNS, FQDNs, and the ndots tax

> **I predict:** Inside a pod, resolving a **short** Service name works via search domains, the **FQDN** resolves directly, a **headless** Service returns *multiple* A records (one per pod), and resolving an *external* name fires **several NXDOMAIN queries first** because of `ndots:5` — **BECAUSE** the stub appends `search` suffixes to any name with fewer than 5 dots before trying it absolute.

```bash
# From your workstation: confirm CoreDNS is the cluster resolver
kubectl -n kube-system get svc kube-dns
# NAME       TYPE        CLUSTER-IP     PORT(S)
# kube-dns   ClusterIP   10.96.0.10     53/UDP,53/TCP,9153/TCP   <- the .10 VIP

# Launch a throwaway debug pod with dig/nslookup
kubectl run dns-test --image=nicolaka/netshoot -it --rm --restart=Never -- bash

# --- inside the pod ---
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5

# Short name -> resolved via search domains to the Service ClusterIP:
nslookup kubernetes
# Server:  10.96.0.10
# Name:    kubernetes.default.svc.cluster.local
# Address: 10.96.0.1        <- the API Service VIP

# Full FQDN resolves directly (one shot, no search-suffix guessing):
dig +short kubernetes.default.svc.cluster.local
# 10.96.0.1

# SRV record exposes the PORT of a Service:
dig +short SRV _https._tcp.kubernetes.default.svc.cluster.local
# 0 100 443 kubernetes.default.svc.cluster.local.   <- prio weight PORT target

# Headless Service (clusterIP: None) -> one A record PER pod, not one VIP:
dig +short my-headless-svc.default.svc.cluster.local
# 10.244.1.7
# 10.244.2.4        <- individual pod IPs (used by StatefulSets, DBs)

# Watch the ndots tax on an EXTERNAL name (1 dot < 5 => suffixes tried first):
dig +search google.com | grep -E "NXDOMAIN|NOERROR"
# ...google.com.default.svc.cluster.local -> NXDOMAIN
# ...google.com.svc.cluster.local        -> NXDOMAIN
# ...google.com.cluster.local            -> NXDOMAIN
# ...google.com                          -> NOERROR   <- finally! 4 queries total

# Fix: trailing dot forces absolute, skips the search list (1 query):
dig +short google.com.
```

**Verify:** `kube-dns` sits at `10.96.0.10` (or `10.100.0.10` on EKS — the `.10` of *your* Service CIDR). A short name only resolves because a search suffix completed it; the FQDN resolves in one shot. A **headless** Service returns *multiple* pod IPs where a normal ClusterIP Service would return one VIP — that's the discovery mechanism StatefulSets rely on. And the external lookup burning 3 NXDOMAINs before success is the **ndots:5** gotcha live; the trailing dot collapses it to one query. If your real external DNS ever feels "slow" in-cluster, this is almost always the cause.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
DNS is a distributed, cached, hierarchical lookup that walks a delegation tree (root → TLD → authoritative) to turn a name into an IP *before* any connection begins, and remembers each answer for its TTL.

**Explain it to a beginner in three sentences:**
DNS is the internet's phone book: you know a name like `google.com`, but computers need a number like `142.250.72.14`, and DNS does the lookup. Instead of one giant book, the work is split into a tree — a root directory points to the `.com` directory, which points to Google's own server, which gives the real answer — and every step remembers the answer for a while so it doesn't have to ask again. Inside Kubernetes the exact same idea runs privately: CoreDNS turns `payments` into a Service IP so your pods can find each other even as they restart and move.

**Sub-parts mapped back to the one idea** ("*distributed, hierarchical, cached lookup down a delegation chain*"):

| Sub-part | Which word of the core idea it is |
|---|---|
| Root / TLD / authoritative servers | **hierarchical** — the tree, read right to left |
| NS records, "ask them next" | **delegation chain** — no one holds the whole answer |
| Recursive resolver vs iterative queries | **lookup** — who does the tree-walking |
| Caching + TTL at every level | **cached** — what makes it fast enough to exist |
| 13 root clusters, anycast, ICANN, registrars | **distributed** — no single file, no single owner |
| A/AAAA/CNAME/MX/NS/TXT/SRV/PTR | the *kinds of answers* the leaves can return |
| CoreDNS, `svc.cluster.local`, ndots, headless | the **same tree grafted into your cluster** |

**Which rung to revisit hands-on:** **Rung 7, Prediction 4.** The chain theory (Rungs 3 and 5) sticks fast, but `ndots:5`, headless-Service multi-A answers, and the search-domain expansion are the parts that actually page you at 2 a.m. Spin up the `netshoot` pod, `cat /etc/resolv.conf`, and watch the NXDOMAIN cascade with your own eyes — that muscle memory is worth more than re-reading the tree diagram.

---

## Related concepts

- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — why DNS rides UDP/53 and when it falls back to TCP.
- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — port 53 and how a query reaches the DNS process.
- [IP addressing](02-ip-addressing.md) — the addresses DNS hands back, and the private ranges pods live in.
- [Kubernetes DNS & service discovery](26-kubernetes-dns-service-discovery.md) — CoreDNS, `svc.cluster.local`, resolv.conf and ndots in full depth.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — the ClusterIP (`10.96.0.10`) that fronts CoreDNS and how DNAT reaches a real pod.
- [HTTP & HTTPS](10-http-and-https.md) — what happens *after* the name resolves and the connection begins.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If DNS is a distributed tree where each owner runs their own server, what problem does that create that a single `HOSTS.TXT` never had — and what must the system add to make the tree usable?

**A:** A single file had one trivial property the tree loses: you always knew where to look — the answer was right there in your local copy. Once the namespace is split across thousands of independently-run servers, you face a discovery problem (which server owns the answer for this name?) and a cost problem (walking servers for every single lookup would be slow and would melt the top of the tree). So the system must add two things: **delegation pointers (NS records)** at every level — root points to the TLD, the TLD points to the authoritative server — so a resolver can find the right server by walking right-to-left down the chain; and **caching with a TTL** at every layer, so nobody re-walks the tree for an answer they saw recently. Caching absorbs ~99% of the traffic and is the single feature that makes the distributed tree fast enough to exist.

### Before Rung 5
**Q:** If you ask a resolver for the A record of a name that is actually a CNAME, what extra work must the resolver do before handing back an IP — and how does that relate to Kubernetes `ExternalName`?

**A:** The resolver gets back a CNAME ("this name is really that other name") instead of an address, so it must **re-resolve the alias target**: it starts a fresh lookup for the canonical name — potentially walking the delegation chain again for a completely different zone — until it reaches a real A record, then returns both the CNAME line and the final A record (as seen with `www.github.com` → CNAME `github.com.` → A `140.82.112.3`). A Kubernetes `ExternalName` Service is exactly this mechanism grafted into the cluster: CoreDNS answers the Service name with a **CNAME to the external name** (no ClusterIP at all), and the pod's resolver must then chase that CNAME out through the upstream/VPC resolver to get the actual IP.

### Before Rung 7
**Q:** A pod's `/etc/hosts` has `10.0.0.5 payments` but CoreDNS says `payments.shop.svc.cluster.local` is `10.100.42.7`. Which IP does `curl payments` hit, and why — search domains or `nsswitch` order?

**A:** It hits **`10.0.0.5`**, and the deciding mechanism is **`nsswitch.conf` lookup order**, not search domains. The resolver library checks `hosts: files dns` — the static `/etc/hosts` file is consulted *first*, and the literal name `payments` matches the entry there exactly, so resolution ends before any DNS query is ever sent. Search-domain expansion (appending `shop.svc.cluster.local`, etc.) is part of the DNS path, which is only reached if the hosts file has no match — so CoreDNS's `10.100.42.7` never gets a chance to answer. This is precisely why a stale `/etc/hosts` entry silently overrides healthy DNS and produces the maddening "only on this machine" bug.
