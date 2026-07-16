# CDN, Edge & WAF — Serving Fast and Safe From the Edge

*Why the fastest packet is the one that never has to cross an ocean — and how the edge became your first line of defense.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Content Delivery Networks (CDNs), edge Points-of-Presence (PoPs), and the Web Application Firewall (WAF) that rides in front of them.

**Why did it land on my desk?** Your EKS app serves users in Mumbai, Frankfurt, and São Paulo, but the cluster lives in `us-east-1`. Users far away complain it's slow, a marketing launch tripled traffic and nearly toppled your Ingress, and security flagged that raw SQL-injection attempts are reaching your pods. All three problems have the same answer: push work to the **edge**, close to users, before it ever reaches your origin.

**What do I already know?** You know DNS resolves a name to an IP ([09-dns.md](09-dns.md)) and that a load balancer spreads traffic across backends ([18-load-balancing.md](18-load-balancing.md)). A CDN sits one layer further out — in front of even your load balancer.

---

## 🔥 Rung 1 — The Pain

Imagine every request for your product image traveling from a phone in Sydney to a server in Virginia. That's ~16,000 km each way. Light in fiber covers roughly 200,000 km/s, so the round trip is **~160 ms of pure physics** — before TLS, before your app does anything. Load a page with 60 assets and that latency stacks up into seconds.

Before CDNs, you had exactly two bad options:

- **Serve everything from one origin.** Every user, everywhere, pays the full distance tax. Your origin also carries 100% of the load — a traffic spike or a DDoS flood hits your actual servers directly.
- **Manually replicate servers worldwide.** Buy racks in a dozen countries, keep them in sync, and operate them. Only giants could afford it.

And on the security side: your app server saw every malicious payload directly. A single crafted request probing for SQL injection or cross-site scripting (XSS) reached your code, and your app was the only thing standing between an attacker and your database.

**Who feels it most?** The platform/SRE team — you own both the latency SLO *and* the "why did the origin fall over" incident.

> **✅ Check yourself before Rung 2:** Why can't you fix global latency just by buying a faster origin server or more bandwidth? (Hint: what part of the delay is a property of *distance*, not of your server?)

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **A CDN keeps copies of your content in many locations physically near users, so a request is answered by the nearest edge instead of your distant origin — and because that edge sees every request first, it's also the perfect place to cache, absorb floods, and filter attacks.**

Everything derives from "answer from nearby, and use that chokepoint":

- *Near users* → **lower latency** (short distance) and **less origin load** (edge answers cache hits).
- *Sees every request first* → the natural spot for a **WAF** (block bad requests) and **DDoS absorption** (soak the flood at hundreds of fat edge sites, not your one origin).
- *Copies, not the source of truth* → you need **TTLs and invalidation** to keep copies fresh.

> **✅ Check yourself before Rung 3:** If the edge already has a fresh copy of what you asked for, how far does your request actually travel? What if it *doesn't* have a copy?

---

## ⚙️ Rung 3 — The Machinery

### The pieces

- **PoP (Point of Presence):** an edge data center — a cluster of cache servers in a city. A big CDN has hundreds worldwide.
- **Edge cache:** stores responses keyed by URL (and sometimes headers). A **cache hit** serves locally; a **cache miss** fetches from the origin, stores it, then serves it.
- **Origin:** the source of truth — for you, the ALB/Ingress in front of your EKS cluster.
- **Anycast:** the same IP is announced from every PoP via BGP ([08-routing-and-forwarding.md](08-routing-and-forwarding.md)); the internet's routing naturally delivers a user to the *nearest* PoP. One IP, many locations.
- **TTL (time-to-live):** how long the edge may serve a cached copy before re-checking the origin.
- **Invalidation / purge:** an explicit "drop this cached object now" when content changes before its TTL expires.
- **WAF (Web Application Firewall):** an L7 filter that inspects HTTP requests and blocks known-malicious patterns (the OWASP Top 10 — SQL injection, XSS, etc.) *before* they reach the origin.

### Cache hit vs miss — the whole game

```
                        USER IN SYDNEY
                              │  GET /logo.png
                              ▼
                   ┌─────────────────────┐   anycast routes user
                   │  PoP: Sydney edge   │   to the NEAREST PoP
                   └─────────┬───────────┘
                             │
              cache HIT?─────┴─────cache MISS?
                 │                     │
       serve from edge          fetch from origin (Virginia),
       (~5 ms, never            store in Sydney cache with TTL,
        touches origin)         then serve. NEXT Sydney user = HIT.
                 │                     │
                 ▼                     ▼
            fast + free          slow ONCE, fast forever after
```

The magic number is the **cache hit ratio**. At 95% hit ratio, only 1 in 20 requests ever reaches your origin — your EKS pods do a fraction of the work and global users get edge-speed responses.

### Where the WAF sits

The WAF is evaluated at the edge *before* the cache/origin decision:

```
Request ──▶ [ WAF: does this look like SQLi / XSS / a bad bot? ]
                 │ blocked (403)            │ allowed
                 ▼                          ▼
            never reaches you        [ cache hit? → serve ]
                                     [ cache miss? → origin (ALB → EKS) ]
```

Because it's L7 and HTTP-aware, a WAF can read the request body and query string — it can spot `' OR 1=1--` in a form field, something a network firewall (L3/L4) at [17-firewalls-security-groups-nacls.md](17-firewalls-security-groups-nacls.md) structurally cannot see.

### How the edge absorbs DDoS

A volumetric flood aimed at your origin IP would saturate your one link. But if your origin is *hidden behind* the CDN (users only ever see the anycast edge IP), the flood lands on the CDN's hundreds of PoPs and terabits of aggregate capacity — spread thin, scrubbed, and rate-limited long before a single packet reaches your ALB.

> **✅ Check yourself before Rung 4:** Two users in the same city request the same image seconds apart. Which one pays the origin round-trip, and which gets a fast local answer — and why?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **CDN** | A network of edge caches near users | The whole system |
| **PoP / edge location** | An edge data center in a city | Where copies live |
| **Origin** | Your source of truth (ALB/Ingress → EKS) | What the edge falls back to |
| **Cache hit / miss** | Content is / isn't already at the edge | The core decision |
| **TTL** | How long a cached copy stays valid | Freshness control |
| **Invalidation / purge** | Force-expire a cached object now | Freshness control |
| **Anycast** | One IP announced from many PoPs via BGP | How users reach the nearest edge |
| **Edge compute** | Running small code at the PoP (e.g. Lambda@Edge) | Logic at the edge |
| **WAF** | L7 filter for malicious HTTP | The guard in front |
| **OWASP Top 10** | The canonical web-attack list (SQLi, XSS…) | What the WAF looks for |
| **Origin shield** | An extra caching tier that funnels misses | Reduces origin load further |

**Same-kind-of-thing groupings:** *CDN, PoP, edge location, origin shield* are all "places that hold copies." *TTL, invalidation, purge* are all "freshness controls." *WAF, rate limiting, bot management* are all "edge filters."

---

## 🔬 Rung 5 — The Trace

**A user in Frankfurt loads `https://shop.example.com/product/42` fronted by CloudFront → ALB → EKS.**

```
Browser (Frankfurt)
  │ 1. DNS: shop.example.com → CloudFront anycast IP (nearest = Frankfurt PoP)
  ▼
[Frankfurt PoP]
  │ 2. TLS handshake terminates HERE (cert served at the edge)
  │ 3. WAF rules run: query string clean? not a known-bad bot? → ALLOW
  │ 4. Cache lookup for /product/42:
  │      • static assets (images/CSS/JS) → HIT → served in ~10 ms, done
  │      • the dynamic HTML → MISS (uncacheable) → go to origin
  ▼ (only the miss travels onward, over the CDN's fast backbone)
[Origin: AWS ALB, us-east-1]  ── 20-aws-vpc.md / 18-load-balancing.md
  │ 5. ALB routes to the Ingress controller Service (NodePort/target group)
  ▼
[Ingress controller pod] ── 27-kubernetes-ingress-gateway-api.md
  │ 6. host/path routing → the shop Service (ClusterIP)
  ▼
[kube-proxy DNAT] ── 25-kubernetes-services-kube-proxy.md
  │ 7. ClusterIP → a healthy pod IP
  ▼
[shop pod] renders HTML → back up the chain
  ▲
[Frankfurt PoP] 8. may cache the HTML briefly (short TTL) → serves user
```

Notice: steps 5–7 (your whole cluster) only run for cache **misses**. Every static asset and every cache hit is answered in step 4 without your pods lifting a finger.

> **✅ Check yourself before Rung 6:** In that trace, which single step is the reason a SQL-injection attempt in the query string never reaches your pod?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: serve everything straight from your origin (ALB → EKS), no CDN.**

| Task | Origin only | CDN + WAF | Why the difference |
|---|---|---|---|
| Global low latency | ❌ everyone pays full distance | ✅ answered nearby | Copies live near users |
| Absorb a traffic spike | ❌ origin takes 100% | ✅ edge serves cache hits | Load offloaded to edge |
| Absorb DDoS | ❌ your one link saturates | ✅ hundreds of fat PoPs | Aggregate capacity |
| Block SQLi/XSS at L7 | ⚠️ only if app self-defends | ✅ WAF filters first | HTTP-aware chokepoint |
| Serve *dynamic, personalized* data | ✅ always fresh | ⚠️ hard to cache (short/no TTL) | It's the source of truth |
| Strong consistency (instant updates) | ✅ | ⚠️ needs invalidation | Copies can be stale |

**When NOT to bother:** an internal-only API, a single-region audience, or highly dynamic per-user responses that can't be cached — a CDN then mostly adds a hop and complexity (though the WAF/DDoS value may still justify it).

**One-sentence why-this-over-that:** *Put a CDN + WAF in front when your audience is global or your origin needs shielding from load and attacks; skip it for internal or single-region services with little cacheable content.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: prove a cache HIT never touches the origin

> **Prediction:** "If I request the same static URL twice through a CDN, the first response header shows `X-Cache: Miss` and the second shows `X-Cache: Hit`, BECAUSE the first populated the edge cache and the second was served locally."

```bash
# Any CDN-fronted static asset (CloudFront exposes X-Cache; others use Age/CF-Cache-Status)
curl -sI https://d1example.cloudfront.net/logo.png | grep -iE 'x-cache|age'
# x-cache: Miss from cloudfront        <- first hit, fetched from origin
curl -sI https://d1example.cloudfront.net/logo.png | grep -iE 'x-cache|age'
# x-cache: Hit from cloudfront         <- second hit, served at the edge
# age: 7                               <- seconds it has lived in the cache
```

**Verify:** second call shows `Hit` and a nonzero `Age`. If it's `Miss` every time, the object is uncacheable (check `Cache-Control: no-store` from your origin) — a very common "my CDN isn't caching" bug.

### Example 2 — Edge/failure case: measure the latency difference proximity buys

> **Prediction:** "If I time a request to the edge vs directly to a distant origin, the edge is dramatically faster on a cache hit, BECAUSE the answer travels a fraction of the distance."

```bash
# Edge (cache hit, nearby PoP):
curl -s -o /dev/null -w 'edge:   %{time_total}s (connect %{time_connect}s)\n' \
  https://d1example.cloudfront.net/logo.png
# edge:   0.045s (connect 0.012s)

# Origin directly (bypass the CDN — a distant region):
curl -s -o /dev/null -w 'origin: %{time_total}s (connect %{time_connect}s)\n' \
  https://origin-alb.us-east-1.elb.amazonaws.com/logo.png
# origin: 0.310s (connect 0.150s)   <- the ~ RTT tax of distance shows up in connect time
```

**Verify:** edge `time_total` is a small fraction of origin. The gap lives mostly in `time_connect` (the TCP+TLS round trips over the long link) — that's the physics a CDN sidesteps.

### Example 3 — Kubernetes-flavored: WAF blocks an attack before it reaches a pod

> **Prediction:** "If a WAF sits in front of my EKS Ingress and I send a SQL-injection pattern, I get a `403` from the edge and my pod logs show NOTHING, BECAUSE the WAF rejected the request at L7 before it was ever forwarded to the origin."

```bash
# A benign request succeeds:
curl -s -o /dev/null -w '%{http_code}\n' 'https://shop.example.com/search?q=shoes'
# 200

# A SQLi probe gets blocked at the edge:
curl -s -o /dev/null -w '%{http_code}\n' "https://shop.example.com/search?q=1'%20OR%20'1'='1"
# 403      <- AWS WAF (attached to CloudFront/ALB) rejected it

# Meanwhile, watch the app pod — the malicious request never arrives:
kubectl logs -l app=shop --since=2m | grep "OR '1'='1"
# (no output)   <- it never reached your code
```

**Verify:** the attack returns `403` and the pod log has no record of it. If the pod *does* log the payload, the WAF isn't in the path (or is in "count" mode, not "block") — check the Web ACL association on your CloudFront distribution / ALB.

---

## 🏔 Capstone — Compress It

**One sentence:** A CDN answers requests from caches near users (cutting latency and origin load) and, because it sees every request first, is also where a WAF filters attacks and floods get absorbed — before anything reaches your origin.

**Explain it to a beginner in 3 sentences:**
1. Your servers are in one place, but your users are everywhere, so a CDN keeps copies of your content in hundreds of cities and serves each user from the nearest one.
2. Most requests are answered by that nearby edge (a "cache hit"), so they're fast and never bother your real servers; only cache misses and truly dynamic requests travel back to your origin.
3. Since every request passes through the edge first, that's also where a Web Application Firewall blocks malicious HTTP (like SQL injection) and where a giant traffic flood gets soaked up before it can knock over your cluster.

**Sub-parts mapped to the one idea (answer from nearby, use the chokepoint):**
```
Low latency      → nearest PoP answers (short distance)
Origin offload   → cache hits never reach origin
DDoS absorption  → flood lands on hundreds of fat PoPs
WAF / OWASP      → filter at the edge chokepoint
TTL/invalidation → keep the cached copies fresh
Anycast          → how users find the nearest PoP
```

**Which rung to revisit hands-on:** Rung 3's cache-hit/miss flow and Rung 7 Example 1 — actually watch `X-Cache` flip from `Miss` to `Hit` and the whole model clicks.

---

## Related concepts

- [Load Balancing](18-load-balancing.md) — the origin the CDN falls back to; L4 vs L7.
- [DNS](09-dns.md) — anycast and how a user is steered to the nearest PoP.
- [Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md) — the L3/L4 filters the L7 WAF complements.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — the cluster entrypoint that acts as the CDN's origin.
- [Bandwidth, Latency & AI/HPC Networking](31-bandwidth-latency-ai-hpc-networking.md) — why distance-latency is physics you can only route around.
- [Network Security — Zero Trust, IDS/IPS & DDoS](30-network-security-zero-trust-ids-ips.md) — where edge defense fits in defense-in-depth.
