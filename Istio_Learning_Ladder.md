# Istio, Climbed the Ladder 🪜
### Learning Istio deeply on AWS EKS — deriving the behavior, not memorizing the commands

> This is your Istio guide rebuilt on the Learning Ladder framework. Instead of leading with `kubectl` commands, we climb from **why Istio exists** → **the one core idea** → **the machinery** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every command in Part 2 of your original guide now sits at the TOP of the ladder. You'll understand *what each one is doing to the machinery* before you run it.

---

# RUNG 0 — The Setup

**What am I learning?**
Istio — a service mesh — running on my EKS cluster with the Bookinfo demo app.

**Why did it land on my desk?**
My lead handed me a capability table (external routing, internal routing, network isolation, mTLS, traffic splitting, retries/circuit breaking, observability, fine-grained policies) and asked me to implement each one, demo it, and explain *how Istio helps*. My Bookinfo pods are already running `2/2`.

**What do I already know about it?**
I know it involves sidecars (my pods show `2/2`, so something extra is injected), I've deployed the Bookinfo app, and I've verified internal routing works (`ratings → productpage` returned the bookstore title). I don't yet have a mental model of *why* the sidecar is there or *how* it does its job.

---

# RUNG 1 — The Pain 🔥
### *Why does Istio exist at all?*

Before you touch a single Istio object, sit with the problem it was born to solve. If you understand the pain, you can predict what Istio *must* do to relieve it — and most of the API stops needing memorization.

### The problem that forced Istio into existence

You have many microservices talking to each other over the network. The network is **unreliable** (packets drop, services die, calls hang) and **insecure** (traffic between pods is plaintext by default). Every service therefore needs the same "networking survival kit":

- Retry a call that failed
- Time out a call that hangs
- Stop hammering a service that's clearly down (circuit breaking)
- Encrypt traffic to the next service
- Prove *who* it is and check *who* the other side is
- Emit metrics so someone can see what's happening
- Load-balance across replicas of the callee

### What people did *before* — and why it hurt

**Before service mesh, this kit was written INTO every application**, usually as a library (Netflix Hystrix for circuit breaking, Ribbon for load balancing, etc.).

```
THE PRE-MESH PAIN

Service A (Java)      Service B (Python)     Service C (Go)
┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│ business code│      │ business code│      │ business code│
│ + retry lib  │      │ + retry lib  │      │ + retry lib  │
│ + TLS code   │      │ + TLS code   │      │ + TLS code   │
│ + metrics lib│      │ + metrics lib│      │ + metrics lib│
│ + LB logic   │      │ + LB logic   │      │ + LB logic   │
└──────────────┘      └──────────────┘      └──────────────┘
     Java version         Python version        Go version
     of the kit           of the kit            of the kit

Pain points:
• Rewritten in EVERY language (3 services = 3 implementations)
• Upgrading retry logic = redeploy EVERY service
• Inconsistent: team A retries 3x, team B retries 5x, nobody agrees
• Security: is EVERY service actually encrypting? Who audits that?
• The business logic is now tangled with plumbing
```

**Who feels this pain most?** The **platform/ops/SRE team** (you). Developers just want to write features; they resent the plumbing. But when something fails at 3 AM, or a security audit asks "is all internal traffic encrypted?", it's the platform team holding the bag. Istio is fundamentally a **platform team's tool** — it lets you impose consistent networking behavior across every service *without asking developers to change code*.

### What breaks without it

Without a mesh, you have no consistent, central way to:
- Encrypt service-to-service traffic (compliance risk)
- Roll out a new version to 10% of users (you're stuck with all-or-nothing deploys)
- See a live map of what's calling what (debugging is guesswork)
- Make the system self-heal under partial failure (one slow service cascades)

> **✅ Check yourself before Rung 2:** In one breath — why couldn't we just keep putting this logic in libraries inside each app? (Hint: think about languages, upgrades, and who has to redeploy.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — the rest of Istio can be *derived* from it:

> **Istio puts a network proxy next to every service and routes all traffic through it, so networking behavior (routing, security, resilience, observability) is controlled by the platform from outside the app, not coded inside it.**

That's the whole trick. Everything else is detail.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"a proxy next to every service"* → that's the **sidecar** (your `2/2` pods: app + proxy)
- *"routes all traffic through it"* → traffic must be **intercepted** somehow (→ iptables, Rung 3)
- *"controlled by the platform from outside"* → there must be a **control plane** pushing config to all those proxies (→ istiod)
- *"routing, security, resilience, observability"* → those are exactly your lead's capabilities. They're not separate features bolted on; they're all just *"things the proxy can do to traffic passing through it."*

Once you see that **every capability in your lead's table is just "configure what the proxy does to the traffic,"** the API stops being a pile of unrelated YAML and becomes one pattern applied seven ways.

> **✅ Check yourself before Rung 3:** Cover the sentence. Say it out loud from memory. Then answer: if the proxy sees *all* traffic in and out of every service, why does that single fact make encryption, traffic-splitting, AND observability all possible? (They're the same mechanism — the proxy is a chokepoint you control.)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We now open the hood. This is where most people stay fuzzy, so we go step by step. There are three things to understand: **(A) the two planes, (B) how the proxy hijacks traffic, and (C) how config flows from your YAML to the proxy.**

## (A) The two planes: brain vs muscle

```
┌─────────────────────────────────────────────────────────────┐
│                    THE TWO PLANES                            │
│                                                              │
│   CONTROL PLANE (the brain — one deployment)                 │
│   ┌────────────────────────────────────────────┐            │
│   │              istiod                         │            │
│   │  • takes YOUR yaml (rules)                  │            │
│   │  • converts it to proxy config              │            │
│   │  • issues TLS certificates (identity)       │            │
│   │  • pushes both to every proxy               │            │
│   └───────────────────┬────────────────────────┘            │
│                       │ push config + certs                 │
│        ┌──────────────┼──────────────┐                       │
│        ▼              ▼              ▼                        │
│   DATA PLANE (the muscle — one proxy per pod)                │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐                 │
│   │  Envoy  │    │  Envoy  │    │  Envoy  │                 │
│   │ (proxy) │    │ (proxy) │    │ (proxy) │                 │
│   └─────────┘    └─────────┘    └─────────┘                 │
│   productpage      reviews        ratings                    │
│                                                              │
│  KEY: istiod NEVER touches actual request traffic.           │
│  Requests flow pod→pod through Envoys ONLY.                  │
│  istiod just tells the Envoys HOW to behave.                 │
└─────────────────────────────────────────────────────────────┘
```

The **control plane (istiod)** is the brain: it makes decisions and distributes config. The **data plane (the Envoy proxies)** is the muscle: it does the actual work on live traffic. This separation is the single most important structural fact about Istio. If istiod crashes, existing traffic *keeps flowing* (the Envoys already have their config) — you just can't push *new* config until it's back.

**istiod's internal jobs** (these used to be separate binaries — the old names still show up in docs):
- **Pilot** — the config translator. Turns your high-level YAML ("send 10% to v2") into low-level Envoy config.
- **Citadel** — the certificate authority. Mints a unique TLS cert for every proxy so services can prove their identity (this is what makes mTLS possible).
- **Galley** — the validator. Checks your YAML is sane before it's accepted.

## (B) The real mechanism: how the proxy hijacks ALL traffic

This is the part that feels like magic until you see it. How does the app's traffic get *forced* through the sidecar without the app knowing?

**Answer: iptables rules inside the pod's network namespace.** When the pod starts, an init container rewrites the pod's routing table so that every packet in or out is redirected to Envoy first.

```
INSIDE A SINGLE POD (the interception trick)

Pod startup sequence:
┌──────────────────────────────────────────────────────┐
│ 1. istio-init runs FIRST (init container)             │
│    └─▶ writes iptables rules:                         │
│        "ALL inbound  → redirect to Envoy port 15006"  │
│        "ALL outbound → redirect to Envoy port 15001"  │
│    └─▶ then exits (its job is done)                   │
│                                                        │
│ 2. Envoy sidecar (istio-proxy) starts                 │
│    └─▶ connects to istiod, downloads config + cert    │
│                                                        │
│ 3. YOUR app container starts LAST                     │
│    └─▶ tries to call reviews:9080                     │
│        thinks it's a direct connection...             │
└──────────────────────────────────────────────────────┘

What ACTUALLY happens when the app calls reviews:
┌──────────────────────────────────────────────────────┐
│  app: "connect to reviews:9080"                       │
│         │                                             │
│         ▼   (iptables silently intercepts)            │
│  ┌──────────────┐                                     │
│  │ Envoy :15001 │  ← outbound. Envoy now decides:     │
│  │              │    • which reviews version?         │
│  │              │    • retry? timeout?                │
│  │              │    • encrypt with mTLS cert?        │
│  └──────┬───────┘                                     │
│         │ encrypted mTLS tunnel                       │
│         ▼                                             │
│    reviews pod's Envoy :15006 (inbound)               │
│         │ decrypts, applies inbound policy            │
│         ▼                                             │
│    reviews app                                        │
│                                                       │
│  The app NEVER KNEW any of this happened.             │
│  Zero code changes. That's the whole point.           │
└──────────────────────────────────────────────────────┘
```

**This is why your pods are `2/2`** — container 1 is your app, container 2 is the Envoy sidecar. And it's why your earlier `kubectl describe pod` showed an `istio-init` container: that's the init container doing the iptables rewrite. You saw the machinery directly and didn't know it yet.

## (C) How your YAML becomes proxy behavior

```
THE CONFIG FLOW (why "kubectl apply" changes traffic)

You run: kubectl apply -f virtualservice.yaml
                │
                ▼
   Kubernetes API stores the object
                │
                ▼
   istiod is WATCHING the API, sees the new object
                │
                ▼
   Pilot translates it → Envoy-specific config (routes, clusters)
                │
                ▼
   istiod PUSHES new config to the relevant Envoy proxies
                │
                ▼
   Envoys update their behavior LIVE (no restart, no redeploy)
                │
                ▼
   Next request follows the new rule
```

This flow is why Istio changes feel instant and why they need **no pod restart**. You're not changing the app — you're changing the proxy's instructions, and the proxy re-reads them on the fly.

> **✅ Check yourself before Rung 4:** Draw the pod-internal picture from memory. Specifically: (1) what does `istio-init` do and when? (2) when the app calls another service, what intercepts the call, and on which port? (3) if istiod dies, does existing traffic stop? Why or why not?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now that you have the machinery, the jargon has somewhere to land. Every term below is *just a label for a part of the picture you already understand*.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Service mesh** | The whole pattern: proxies everywhere + a brain controlling them | The entire two-plane system |
| **Sidecar** | The extra proxy container in each pod | The "2/2" — data plane, per pod |
| **Envoy** | The specific proxy software Istio uses (C++, fast) | Every sidecar; the muscle |
| **Data plane** | The collective set of all Envoy proxies | Where live traffic actually flows |
| **Control plane** | istiod — the brain that configures proxies | Pushes config + certs |
| **istiod** | The single control-plane binary | Brain (contains Pilot/Citadel/Galley) |
| **Pilot** | The config-translator inside istiod | YAML → Envoy config |
| **Citadel** | The cert-authority inside istiod | Issues mTLS identities |
| **istio-init** | Init container that writes iptables rules | The traffic-interception setup |
| **iptables redirect** | Kernel rules that force traffic to Envoy | The *how* of interception (Rung 3B) |
| **Gateway** | Config for the edge proxy (cluster front door) | Where external traffic enters |
| **VirtualService** | Rules for WHERE traffic goes (routing) | Instructions Pilot gives Envoy |
| **DestinationRule** | Defines version "subsets" + traffic policy (circuit breaking, LB) | Also instructions for Envoy |
| **Subset** | A named group of pods by label (e.g. version=v2) | A target a VirtualService can point at |
| **PeerAuthentication** | Sets mTLS mode (STRICT/PERMISSIVE) | Tells Envoys to require encryption |
| **AuthorizationPolicy** | Access rules (who may call whom, which HTTP verbs) | Envoy checks these on each request |
| **mTLS** | Mutual TLS — both sides present certs | Encryption + identity between Envoys |
| **Envoy sidecar injection** | The automatic adding of the proxy to pods | How pods become "2/2" |

### The big unlock: which terms are the *same kind of thing*

New learners drown because they think these are 15 unrelated concepts. They're not. Group them:

```
GROUP 1 — "The proxy" (all the same physical thing, different names):
   Sidecar = Envoy = data plane member = the second container in 2/2

GROUP 2 — "The brain" (all istiod):
   Control plane = istiod = Pilot + Citadel + Galley

GROUP 3 — "Instructions for the proxy about ROUTING":
   VirtualService (where to go) + DestinationRule (subsets + how to behave)
   → These two ALWAYS work as a pair. VS points to a subset; DR defines the subset.

GROUP 4 — "Instructions for the proxy about SECURITY":
   PeerAuthentication (encrypt?) + AuthorizationPolicy (who's allowed?)

GROUP 5 — "The interception plumbing" (invisible, runs once at startup):
   istio-init + iptables redirect
```

If you hold those five groups, you hold Istio's vocabulary. Notice **VirtualService and DestinationRule are the pair you'll use most** — nearly every capability in your lead's table is "write a VirtualService, sometimes with a DestinationRule."

> **✅ Check yourself before Rung 5:** Without looking — which two objects always come as a pair for routing, and what's the division of labor between them? (One says *where*, the other defines the *named targets and their behavior*.)

---

# RUNG 5 — The Trace 🎬
### *Follow ONE concrete request end-to-end*

Abstractions blur; a single traced request sears the model in. Let's trace the exact thing you'll demo: **a user's browser hits `/productpage`, and productpage internally calls `reviews`, which calls `ratings`.** We'll assume mTLS is on and reviews is split 90/10 between v1 and v2 — so this trace touches most of your lead's table at once.

```
THE TRACE: browser → productpage → reviews → ratings
```

**Step 1 — Browser → AWS Load Balancer**
Your browser resolves the ELB hostname and sends `GET /productpage`. The AWS load balancer forwards it to the Istio ingress gateway pod inside the cluster.

**Step 2 — Ingress Gateway (an Envoy) receives it**
This is a standalone Envoy at the cluster edge (your `bookinfo-gateway-istio` pod). It checks the **Gateway** config (which ports/hosts are open) and the routing rules (your HTTPRoute/VirtualService): "Is `/productpage` an allowed path? Yes → forward to the `productpage` service." Paths like `/admin` that aren't listed would be rejected right here.

**Step 3 — Gateway Envoy → productpage's Envoy (mTLS)**
The gateway opens a connection to a productpage pod. Because mTLS is STRICT, the two Envoys present certificates (minted by Citadel) and establish an **encrypted tunnel**. The gateway's Envoy is the client; productpage's inbound Envoy (port 15006) is the server. Both verify the other's identity.

**Step 4 — productpage's Envoy → productpage app**
productpage's inbound Envoy decrypts the request, checks any **AuthorizationPolicy** ("is the caller allowed? which HTTP method?"), then hands the plain request to the actual productpage container on `localhost:9080`. The app has no idea encryption or auth just happened.

**Step 5 — productpage app decides to call reviews**
The Python app runs its logic and makes an outbound call: `GET reviews:9080`. It thinks this is a direct network call.

**Step 6 — iptables intercepts → productpage's OUTBOUND Envoy (port 15001)**
The kernel's iptables rules (from `istio-init`) silently redirect that call to productpage's own Envoy. Now the Envoy consults the config Pilot pushed:
- **VirtualService for reviews:** "route 90% to subset v1, 10% to subset v2." Envoy rolls the dice — say it picks v2 this time.
- **DestinationRule for reviews:** "here's how to reach subset v2's pods, and here's the circuit-breaker/load-balancing policy."

**Step 7 — productpage Envoy → reviews-v2 Envoy (mTLS again)**
Another encrypted, mutually-authenticated hop to a specific reviews-v2 pod. Same cert dance. If reviews-v2 were failing, the **retry** and **circuit-breaking** rules would kick in *right here* inside the Envoy.

**Step 8 — reviews-v2 app → calls ratings (repeat the pattern)**
reviews-v2's app calls `ratings:9080`. iptables → reviews' outbound Envoy → VirtualService/DestinationRule for ratings → mTLS hop → ratings' inbound Envoy → ratings app. Exactly the same machinery, one level deeper.

**Step 9 — The response walks back up**
ratings → reviews-v2 → productpage → gateway → ELB → browser. Every hop back is also mTLS-encrypted. Along the entire journey, **every Envoy emitted metrics** (latency, status code) to Prometheus, which is why Kiali can later draw this exact path with live numbers.

```
VISUAL OF THE TRACE (each 🔒 = an mTLS hop between two Envoys)

Browser
  │ GET /productpage
  ▼
AWS ELB
  │
  ▼
[Gateway Envoy] ──🔒──▶ [productpage Envoy → app]
                              │ app calls reviews:9080
                              │ (iptables → own Envoy)
                              │ VS: 90/10 → picks v2
                              ▼
                        [reviews-v2 Envoy → app]
                              │ app calls ratings:9080
                              ▼
                        [ratings Envoy → app]
                              │
                              ▼
                          returns 200
  ◀────────────── response walks back up ──────────────

Every hop: identity checked, traffic encrypted, metrics emitted.
The apps: blissfully unaware.
```

> **✅ Check yourself before Rung 6:** At Step 6, *two* different objects together decided where the reviews call went. Name both and what each contributed. And: at which single step do retries/circuit-breaking live — the app, or the Envoy?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand Istio best by seeing exactly where the *old* way stops and Istio begins. This is also precisely what your lead's table is testing — so this rung doubles as your answer to them.

### The alternative: Ingress + NetworkPolicy

Before/without a mesh, the closest tools are a **Kubernetes Ingress** (an edge load balancer for getting external traffic in) plus **NetworkPolicies** (firewall rules between pods). Here's the crucial mental distinction:

```
WHERE EACH TOOL OPERATES

                 NORTH-SOUTH traffic          EAST-WEST traffic
                 (outside → cluster)          (service → service)
                 ─────────────────────        ─────────────────────
Ingress:         ✅ handles this              ❌ blind to it
NetworkPolicy:   ⚠️ allow/deny by IP          ⚠️ allow/deny by IP only
Istio:           ✅ handles this              ✅ FULL control here

The gap Istio fills: EAST-WEST, Layer 7 (HTTP-aware) control.
```

And the layer difference:

```
LAYER OF OPERATION

NetworkPolicy = Layer 3/4  (IP addresses & ports)
   "Pods with label X may reach port 9080 on pods with label Y"
   → It's a FIREWALL. It can allow or block. It cannot:
     route by HTTP path, split traffic %, retry, or encrypt.

Istio = Layer 7  (HTTP: paths, headers, methods, identity)
   "Route GET /productpage from service A's identity to reviews v2,
    retry 3x on 5xx, encrypt it, and log the latency"
   → It's a programmable ROUTER + security layer + observer.
```

### What Istio can do that the alternative can't

| The task | Ingress + NetworkPolicy | Istio | Why the difference |
|---|---|---|---|
| Get external traffic in | ✅ | ✅ | Both have an edge proxy |
| Isolate pods by IP | ✅ | ✅ | NetPolicy is a real firewall |
| Route internal traffic by version/% | ❌ | ✅ | Needs an L7 proxy on every hop |
| Encrypt service-to-service | ❌ | ✅ | Needs a proxy pair + a CA (Citadel) |
| Retry / circuit-break | ❌ | ✅ | Needs logic in the request path (Envoy) |
| Isolate by *cryptographic identity* | ❌ | ✅ | NetPolicy trusts IPs (spoofable); Istio trusts certs |
| See a live service map | ❌ | ✅ | Every Envoy emits metrics automatically |

The pattern in the "why" column is always the same: **the extra powers all require a smart proxy sitting in the path of *every* request.** That's exactly what the sidecar is. The alternative has no such thing for east-west traffic, so it *structurally cannot* offer these features — it's not a missing feature, it's a missing architecture.

### When would I NOT use Istio?

Be honest with your lead — a mesh isn't free:

- **Small clusters / few services.** If you have 3 services and no compliance pressure, the operational overhead (an extra proxy per pod = more CPU/RAM, a control plane to run, more moving parts to debug) may outweigh the benefit. Your earlier **IP exhaustion** incident is a real example of mesh overhead biting.
- **You only need north-south routing.** If all you want is "get external traffic to a service," a plain Ingress or Gateway API is simpler.
- **Latency-critical hot paths.** Each mTLS hop adds a little latency (usually sub-millisecond, but non-zero).
- **Team maturity.** A mesh you don't understand is a liability. (Which is why you're climbing this ladder instead of pasting commands.)

**One-sentence "why this over that":**
> Use Istio when you need consistent security, resilience, and visibility *between* services (east-west, Layer 7) without changing app code; stick with Ingress + NetworkPolicy when you only need to get traffic *into* the cluster and do coarse IP-level isolation.

> **✅ Check yourself before Rung 7:** Explain to an imaginary colleague why NetworkPolicy *structurally cannot* do a 90/10 canary split — not "it doesn't have the feature," but *why the architecture makes it impossible*. (Hint: what layer does it operate at, and does it sit in the request path?)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive — and notice the reframing.** In your original guide, these were "steps to run." Here, each one is a **hypothesis you commit to first**, then verify. That single change — predicting before running — is what converts "I typed the command" into "I understand the system." For each capability: read the prediction, cover the outcome, decide if you agree, *then* run it.

Assume your Bookinfo app is running and you've captured the gateway URL:

```bash
export GW=$(kubectl get svc bookinfo-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```
*(If that's empty, switch the gateway service to LoadBalancer first — see the note at the end of this rung.)*

---

## Prediction 1 — External routing works, and reviews is currently random

> **My prediction:** "If I curl `/productpage` repeatedly, then every request will return the bookstore page, and the star-rating section will vary between no-stars/black/red across refreshes — *because* with no VirtualService pinning reviews, the productpage→reviews call load-balances across all three versions."

```bash
# Run it:
for i in $(seq 1 6); do
  curl -s http://$GW/productpage | grep -o 'reviews-v[0-9]' | head -1
done
```

**Verify:** You should see the title every time, and mixed versions across the six calls. If the versions were *not* random, your model of "no VS = default round-robin across subsets" needs repair.

---

## Prediction 2 — A VirtualService pins internal routing deterministically

> **My prediction:** "If I apply a DestinationRule defining subsets v1/v2/v3 AND a VirtualService routing reviews to v1 only, then refreshing the page will *always* show no stars — *because* the productpage→reviews call is intercepted by productpage's Envoy, which Pilot has now told to send 100% to subset v1."

```bash
# The pair: DestinationRule defines the targets, VirtualService picks one
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata: {name: reviews, namespace: default}
spec:
  host: reviews
  subsets:
  - {name: v1, labels: {version: v1}}
  - {name: v2, labels: {version: v2}}
  - {name: v3, labels: {version: v3}}
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata: {name: reviews, namespace: default}
spec:
  hosts: [reviews]
  http:
  - route:
    - {destination: {host: reviews, subset: v1}}
EOF
```

**Verify:** Refresh `http://$GW/productpage` many times → stars never appear. If they still vary, either the DR subsets don't match the pod labels, or the VS didn't apply — check with `istioctl analyze -n default`.

*(This is Capabilities 1 and 2 from your lead's table, now as a verified prediction rather than a memorized step.)*

---

## Prediction 3 — Traffic splitting is just changing the weights

> **My prediction:** "If I change the VirtualService to weight v1:90/v2:10, then about 1 in 10 refreshes will show black stars — *because* Envoy now probabilistically routes per the weights I gave Pilot. Changing weights needs no pod restart, because I'm reconfiguring the proxy, not the app."

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata: {name: reviews, namespace: default}
spec:
  hosts: [reviews]
  http:
  - route:
    - {destination: {host: reviews, subset: v1}, weight: 90}
    - {destination: {host: reviews, subset: v2}, weight: 10}
EOF

# Sample 30 requests, count how many hit v2:
for i in $(seq 1 30); do
  curl -s http://$GW/productpage | grep -o 'reviews-v2' | head -1
done | wc -l
```

**Verify:** Roughly 2-4 out of 30. Not exactly 3 — it's probabilistic. If you predicted "exactly 3," repair that: weights are statistical, not a rota. **This same mechanism is canary and blue-green** — blue-green is just an instant 0→100 flip instead of a gradual climb (Capability 5).

---

## Prediction 4 — Header-based routing overrides the split for one user

> **My prediction:** "If I add a match rule for `end-user: jason` → v2, then logging into the app as jason shows black stars every time, while anonymous users still follow the 90/10 split — *because* Envoy evaluates match rules top-down, and jason's requests carry the `end-user` header that productpage sets after login."

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata: {name: reviews, namespace: default}
spec:
  hosts: [reviews]
  http:
  - match:
    - headers: {end-user: {exact: jason}}
    route:
    - {destination: {host: reviews, subset: v2}}
  - route:
    - {destination: {host: reviews, subset: v1}}
EOF
```

**Verify:** In the browser, sign in as user `jason` (any password) → always black stars. Log in as anyone else → v1. If jason *doesn't* get v2, your model missed that the app must inject the header — confirm productpage is actually setting `end-user`. (Capability 7: fine-grained policies.)

---

## Prediction 5 — STRICT mTLS blocks a non-meshed pod

> **My prediction:** "If I set PeerAuthentication to STRICT, then a pod *without* a sidecar (like `velero-tag-test-pod`, which is 1/1) will FAIL to reach productpage, while meshed services still succeed — *because* STRICT tells every inbound Envoy to reject plaintext, and the non-meshed pod has no Envoy/cert to establish mTLS."

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata: {name: default, namespace: default}
spec:
  mtls: {mode: STRICT}
EOF

# From a NON-meshed pod (1/1, no sidecar) — should FAIL:
kubectl exec velero-tag-test-pod -- \
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 \
  http://productpage:9080/productpage

# From a MESHED pod — should SUCCEED:
kubectl exec $(kubectl get pod -l app=ratings -o jsonpath='{.items[0].metadata.name}') \
  -c ratings -- curl -s http://productpage:9080/productpage | grep -o "<title>.*</title>"
```

**Verify:** First returns `000`/failure, second returns the title. If the non-meshed pod *succeeds*, mTLS isn't actually STRICT yet (maybe still PERMISSIVE) — recheck the PeerAuthentication applied. (Capability 4.)

---

## Prediction 6 — Circuit breaker returns 503 under concurrency

> **My prediction:** "If I set the ratings DestinationRule to `maxConnections: 1` and then hit it with 2 concurrent connections, then some requests return 503 — *because* Envoy's connection pool caps concurrency at 1 and sheds the excess immediately rather than queuing it."

```bash
# Add the circuit breaker to ratings' DestinationRule:
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata: {name: ratings, namespace: default}
spec:
  host: ratings
  subsets:
  - {name: v1, labels: {version: v1}}
  trafficPolicy:
    connectionPool:
      tcp: {maxConnections: 1}
      http: {http1MaxPendingRequests: 1, maxRequestsPerConnection: 1}
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 3m
EOF

# Load test with fortio at concurrency 2:
kubectl apply -f samples/httpbin/sample-client/fortio-deploy.yaml
export FORTIO=$(kubectl get pod -l app=fortio -o jsonpath='{.items[0].metadata.name}')
kubectl exec $FORTIO -c fortio -- \
  fortio load -c 2 -qps 0 -n 20 http://ratings:9080/ratings/1
```

**Verify:** The fortio summary shows a mix of `200` and `503`. If it's *all* 200, your concurrency didn't exceed the limit (or the breaker didn't apply) — bump `-c` higher. This is timing-sensitive, so don't be surprised if you need to tune the numbers. (Capability 6.)

---

## The prediction habit, generalized

Fill this in for anything new you try in Istio:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

> **Note on getting `$GW`:** if the gateway has no external hostname, run:
> ```bash
> kubectl patch svc bookinfo-gateway-istio -n default \
>   --type='json' -p='[{"op":"replace","path":"/spec/type","value":"LoadBalancer"}]'
> kubectl get svc bookinfo-gateway-istio -n default -w   # wait for EXTERNAL-IP
> ```
> Remember the IP-exhaustion lesson: installing the observability addons adds several pods — ensure node/IP capacity first.

---

# 🎁 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> Istio runs an Envoy proxy beside every service and routes all traffic through it, so the platform controls routing, encryption, resilience, and observability from outside the app instead of baking that logic into each service's code.

**Explain it to a beginner in 3 sentences:**
> 1. Istio slips a small network proxy next to every one of your services, and quietly forces all the service's traffic to pass through that proxy using kernel routing rules — so your app code never changes.
> 2. A central brain (istiod) pushes rules and TLS certificates to all those proxies, which is how you get version-based routing, canary deployments, automatic encryption between services, retries, and circuit breaking without touching the apps.
> 3. Because every proxy also reports metrics, you get a live map of your whole system (via Kiali) for free — something a plain Ingress, which only sees traffic entering the cluster, can never provide.

**Map of capability → what you're really doing (all one pattern):**

```
Every capability = "configure what the Envoy proxy does to traffic":

External routing      → Gateway + route rules  (edge Envoy: who gets in)
Internal routing      → VirtualService + DestinationRule (which subset)
Traffic splitting     → VirtualService weights (probabilistic routing)
Fine-grained routing  → VirtualService match on headers/URI
mTLS                  → PeerAuthentication (Envoys require certs)
Network isolation     → AuthorizationPolicy (Envoy checks identity)
Retries/circuit break → VirtualService retries + DestinationRule pool
Observability         → automatic (Envoys emit metrics) → Kiali/Grafana/Jaeger
```

Seven rows, one idea: *the proxy is a chokepoint you program.*

**Which rung will I most likely need to revisit hands-on?**

Be honest with yourself here, but the two usual suspects are:

- **Rung 3B (the iptables interception).** It's invisible and feels like magic. The fix: `kubectl exec` into a sidecar and actually look — `istioctl proxy-config listeners <pod>` shows the 15001/15006 setup, making the abstract concrete.
- **Rung 6 (the contrast), under questioning.** You can *state* "Istio is L7, NetworkPolicy is L3/4," but explaining *why that makes canary structurally impossible for NetworkPolicy* takes a couple of reps. Rehearse it out loud before facing your lead.

If either of those felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Appendix — The commands, collected (for reference AFTER you understand them)

Now that each command is tied to a mechanism, here's the flat list for quick copy-paste during your demo. Run them in this order for a clean narrative; keep Kiali open throughout so every change is visible.

```bash
# 0. Gateway URL + (optional) observability
kubectl patch svc bookinfo-gateway-istio -n default \
  --type='json' -p='[{"op":"replace","path":"/spec/type","value":"LoadBalancer"}]'
export GW=$(kubectl get svc bookinfo-gateway-istio \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

kubectl apply -f samples/addons/prometheus.yaml
kubectl apply -f samples/addons/grafana.yaml
kubectl apply -f samples/addons/jaeger.yaml
kubectl apply -f samples/addons/kiali.yaml
istioctl dashboard kiali   # or expose kiali via LoadBalancer

# 1-2. Subsets + pin to v1  (Predictions 2)
# 3.   Weighted 90/10       (Prediction 3)
# 4.   Header routing jason (Prediction 4)
# 5.   STRICT mTLS          (Prediction 5)
# 6.   Circuit breaker      (Prediction 6)
#      (YAML for each is in the corresponding prediction above)

# Diagnostics you'll lean on:
istioctl analyze -n default                       # find config errors
istioctl proxy-status                             # are proxies in sync?
istioctl x describe pod <pod>                     # what applies to this pod?
istioctl proxy-config listeners <pod>             # SEE the 15001/15006 interception
```

**Cleanup (reset to baseline):**
```bash
kubectl delete virtualservice --all -n default
kubectl delete destinationrule --all -n default
kubectl delete peerauthentication --all -n default
kubectl delete authorizationpolicy --all -n default
kubectl delete -f samples/httpbin/sample-client/fortio-deploy.yaml --ignore-not-found
```

---

*You climbed the whole ladder. You can now not just run Istio's commands but predict what each one does before you press enter — which is the actual definition of understanding it. Good luck with the demo, and with explaining it to your lead from the Pain upward rather than the commands downward.*
