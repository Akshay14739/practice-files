# Load Balancing
*One front door, many kitchens — how one address fans traffic across a fleet that is always changing.*

---

## 🎯 Rung 0 — The Setup

**What you're learning:** How a single entry point takes a flood of incoming connections and *spreads* them across many identical backends, so that no one backend melts, and so that when one backend dies the traffic simply flows around it.

Picture a busy restaurant. Diners pour in through *one* front door. A **host** stands there. The host doesn't cook, doesn't take orders — the host's only job is to look at the room, see which tables (and which waiters) are free and healthy, and *seat each new party at a good table*. That host is a **load balancer**. The diners are TCP connections and HTTP requests. The tables are your backends — servers, VMs, or Kubernetes pods.

**Why it landed on your desk (a real EKS moment):** You deployed a Deployment with `replicas: 6` and put a `Service` of `type: LoadBalancer` in front of it. AWS spun up a Network Load Balancer. Traffic flows. Then one pod goes bad — it's up, but its `/healthz` returns 500. Users start seeing intermittent errors: *one request in six fails.* Your manager asks, "Why is the load balancer still sending traffic to the broken pod?" To answer that, you need to know what the LB is actually doing under the hood: how it picks a backend, how it decides a backend is "healthy," and — critically — *who wired the pod into the LB's target list in the first place* (spoiler: a readiness probe did).

**What you already know that carries over:**
- **IP + port** ([04](04-ports-sockets-multiplexing.md)) — a load balancer is fundamentally something listening on an IP:port and forwarding to other IP:ports.
- **TCP handshake** ([07](07-transport-layer-tcp-udp.md)) — SYN, SYN-ACK, ACK. An L4 LB either forwards or terminates these.
- **NAT/DNAT** ([14](14-nat-and-pat.md)) — rewriting destination IP:port is exactly how kube-proxy and many L4 LBs work.
- **DNS** ([09](09-dns.md)) — the oldest, crudest load balancer of all is a DNS name with multiple A records.
- **HTTP** ([10](10-http-and-https.md)) and **TLS** ([11](11-tls-ssl-encryption-in-transit.md)) — an L7 LB reads the HTTP request and often terminates TLS.

If you can picture a packet arriving at an IP:port and being handed onward, you already have the whole skeleton.

---

## 🔥 Rung 1 — The Pain

**The world before load balancers: one server, one IP, one point of failure.**

In 1995 your website was `www.example.com` → one A record → one server. Two problems, both fatal:

1. **Scale ceiling.** That one box has a finite CPU, a finite NIC, a finite number of file descriptors. When 10,000 users show up, the 10,001st connection is refused. You cannot buy a big enough single machine forever — *vertical scaling* hits physics and price walls. You want *horizontal scaling*: add more cheap boxes. But how do users find "more boxes" when they only know one name?

2. **Availability cliff.** That one box reboots, its disk dies, or you deploy a bad build. The site is 100% down. There is no "route around it," because there is no *around*. One server = one failure = total outage.

**The crude first fix — DNS round-robin:**

```
www.example.com.  A  203.0.113.10
www.example.com.  A  203.0.113.11
www.example.com.  A  203.0.113.12
```

The DNS resolver hands out a different order to each client, so load *sort of* spreads. It was the first load balancing anyone did, and it still hurts:

- **DNS caching ignores health.** If `.11` dies, DNS keeps handing it out for the whole TTL (could be minutes to hours). Clients cache it and hammer a dead box. There's no health check in plain DNS.
- **No connection awareness.** DNS gives you an IP once, at resolution time. It has no idea one box has 5,000 live connections and another has 3. It can't rebalance.
- **Uneven spread.** Caching resolvers, `ndots`, and corporate DNS mean thousands of users behind one resolver all get the *same* answer and stampede one server.

**Who feels this most?** The on-call platform engineer. Without a real load balancer:
- You cannot do a rolling deploy without dropping traffic.
- You cannot lose a node gracefully — an EC2 instance failing takes real users down.
- You cannot autoscale, because there's no component that notices "new backend exists, start using it."

In Kubernetes this pain is *constant*: pods are cattle. They get rescheduled, their IPs change every restart, they scale from 3 to 30 and back. Nothing durable could ever hand a client a pod IP. You need a stable front that tracks a shifting set of backends and only ever sends traffic to healthy ones. **That component is a load balancer, and Kubernetes has several stacked on top of each other.**

> **Check yourself before Rung 2:** DNS round-robin *does* spread load across multiple IPs. Name the two things it fundamentally *cannot* do that force you to a real load balancer — and tie each to a specific failure a user would see.

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Write it on a sticky note:

> ## A load balancer is a stable front-end address that accepts each incoming connection and forwards it to one healthy backend chosen from a live pool — deciding *how* to choose (the algorithm) and *whom to trust* (the health check).

Memorize it. Everything else is a corollary:

- **"stable front-end address"** → clients only ever know *one* IP:port (or one DNS name). The backends can churn wildly behind it. This is why a K8s `Service` has a fixed ClusterIP while its pods come and go.
- **"forwards each connection"** → the LB sits *in the path* of traffic (unlike DNS, which steps out of the path after handing over an IP). Being in-path is what lets it react in real time.
- **"one healthy backend"** → there is a **health check** loop constantly probing backends; unhealthy ones are removed from the pool. A packet is *never* sent to a backend the LB believes is dead.
- **"chosen from a live pool"** → the pool is *dynamic*. Something keeps it updated (in AWS: a target group; in K8s: the Endpoints/EndpointSlice controller driven by readiness probes).
- **"how to choose (the algorithm)"** → round-robin, least-connections, weighted, IP-hash. Just a policy for picking.
- **"whom to trust (the health check)"** → the gate. This is the part your manager's broken-pod question was really about.

Two big design choices fall right out of this one sentence:
- *At what layer do I read the traffic to make the choice?* If I only look at IP:port, I'm an **L4** load balancer (fast, dumb, connection-oriented). If I parse the HTTP request, I'm an **L7** load balancer (smart, can route by host/path/header, can terminate TLS).
- *Where does the pool live and who can reach me?* **External** (internet-facing) vs **internal** (private-only) load balancer.

Hold the one sentence. We now go under the hood.

> **Check yourself before Rung 3:** From the one-idea sentence alone, *derive* why a load balancer must sit in the traffic path but a DNS-based one does not — and what capability the in-path LB gets *for free* because of that position.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

A load balancer has four moving parts. Learn these and you can reason about any LB, from an F5 appliance to AWS ALB to kube-proxy.

```
                         ┌─────────────────────────────────────────┐
                         │            LOAD BALANCER                  │
   client ──connect──►   │                                           │
                         │  (1) LISTENER   ip:port it accepts on     │
                         │  (2) POOL       the live list of backends │
                         │  (3) ALGORITHM  which backend to pick     │
                         │  (4) HEALTHCHECK who is allowed in pool    │
                         │                                           │
                         └───────────────┬───────────────────────────┘
                                         │ forward
              ┌──────────────────────────┼──────────────────────────┐
              ▼                          ▼                          ▼
        backend A                  backend B (SICK)            backend C
        10.0.1.5:8080              10.0.1.6:8080  ✗            10.0.1.7:8080
        health: OK                 health: FAIL               health: OK
        (in pool)                  (evicted!)                 (in pool)
```

### Part 1 — The listener (where it accepts traffic)

The LB binds an IP:port and waits. What it does with the arriving bytes is the whole L4-vs-L7 split.

**L4 (transport layer) load balancing** — the LB decides *per connection*, looking only at the IP header and TCP/UDP header (source IP, dest IP, dest port). It does **not** read the payload. It never sees "GET /login HTTP/1.1". Two ways it can forward:

```
  L4, forwarding mode (DNAT):                L4, "flow" — one pick per connection
  ┌────────────┐                             the whole TCP connection (handshake,
  │ dst 198.51.100.9:443  ← LB VIP           data, teardown) pins to ONE backend.
  └─────┬──────┘                             The LB rewrites dst IP:port and (often)
        │ rewrite dst → 10.0.1.5:443         does source NAT so the reply comes
        ▼                                    back through it. This is exactly the
  ┌────────────┐                             DNAT you learned in NAT/PAT (14).
  │ dst 10.0.1.5:443                         Fast because it's just header math —
  └────────────┘                             no payload parsing, kernel-speed.
```

AWS **NLB** (Network Load Balancer) is L4. It handles millions of connections/sec, preserves the client source IP, works for *any* TCP/UDP protocol (not just HTTP), and can't do anything HTTP-aware because it never looks that high.

**L7 (application layer) load balancing** — the LB **terminates** the client's TCP connection *itself*, reads the full HTTP request, then opens a *second, separate* connection to the chosen backend. It is a full proxy.

```
  L7 proxy = TWO connections, glued in the middle:

   client ═══TCP+TLS═══►  [ L7 LB ]  ═══new TCP═══►  backend
                          reads: Host: api.example.com
                                 path: /orders
                                 header: X-User: 42
                          decrypts TLS here (termination)
                          picks backend by RULE, not just round-robin
```

Because it reads HTTP, an L7 LB can route by **host** (`api.` vs `web.`), by **path** (`/orders` → order-service, `/images` → cdn-pool), by **header/cookie**, can **terminate TLS** (decrypt once at the edge, talk plaintext or re-encrypt inside), can inject headers (`X-Forwarded-For`), retry failed requests, and buffer slow clients. AWS **ALB** (Application Load Balancer) is L7. Envoy (the sidecar in [Istio](../Istio_Learning_Ladder.md)) and the NGINX Ingress controller are L7. This costs CPU — parsing and re-encrypting is far heavier than header math — which is the price of intelligence.

> The mental split: **L4 = "which line do I put you in?" decided by IP:port. L7 = "what are you actually asking for?" decided by reading your HTTP request.**

### Part 2 — The pool (the live list of backends)

The pool is a *dynamic set* of `IP:port` entries. In AWS this object is literally called a **target group**; its targets can be EC2 instances, IP addresses, or a Lambda. In Kubernetes the equivalent is the set of **Endpoints / EndpointSlices** behind a Service. The crucial word is *live*: something is constantly adding and removing members.

### Part 3 — The algorithm (how it picks)

Given a healthy pool, which member gets this connection?

| Algorithm | Rule | Best when |
|---|---|---|
| **Round-robin** | next backend in rotation, cycle forever | backends roughly equal, requests short & uniform |
| **Least-connections** | backend with fewest *active* connections | requests vary in duration (long-lived connections) |
| **Weighted** (weighted RR / weighted least-conn) | bigger boxes get proportionally more | mixed instance sizes; canary (send 5% to new version) |
| **IP-hash** | `hash(client_ip)` → always the same backend | crude stickiness without cookies |

Round-robin is the default almost everywhere (kube-proxy's iptables mode uses statistically-uniform random selection, which is round-robin in effect). Least-connections shines when some connections are long (websockets, gRPC streams) and round-robin would pile new ones onto a box that's already saturated.

### Part 4 — The health check (the gate — this is what your manager asked about)

A separate loop, running on its own timer, that probes each backend and marks it **healthy** or **unhealthy**. Only healthy members stay in the pool. This is the difference between a load balancer and DNS round-robin.

```
   HEALTH-CHECK LOOP (independent of client traffic)

   every 10s ──► GET http://10.0.1.6:8080/healthz
                 ├─ 200 OK  within timeout ──► counter++  (2 in a row → HEALTHY, add to pool)
                 └─ 500 / timeout / refused ─► counter++  (2 in a row → UNHEALTHY, evict!)
```

- **L4 health check** = "can I open a TCP connection to `IP:port`?" (SYN → SYN-ACK). Shallow but cheap. NLB does this by default.
- **L7 health check** = "does `GET /healthz` return 200 within N seconds?" Deep — it catches an app that's *listening* but *broken* (exactly your intermittent-500 pod!). ALB does this.

Thresholds matter: typically "2 consecutive successes → healthy," "2–3 consecutive failures → unhealthy," check interval ~5–30s. That interval is *why traffic to a newly-broken pod doesn't stop instantly* — there's a detection window.

### Where Kubernetes stacks THREE load balancers on top of each other

This is the payoff. A single request to your EKS app can pass through *three* load balancers, each at a different layer:

```
  Internet
     │
     ▼
  ┌────────────────────────────────────────────┐  ← LB #1: CLOUD LB
  │ AWS ALB (L7)  or  NLB (L4)                  │     provisioned by Service type=LoadBalancer
  │ listener :443, TLS terminated (ALB)        │     or by the Ingress/ALB controller.
  │ target group = the cluster's NODES or PODS │     Health-checks its targets.
  └───────────────┬────────────────────────────┘
                  │ arrives at a node's NodePort (30000-32767) OR pod IP directly
                  ▼
  ┌────────────────────────────────────────────┐  ← LB #2: kube-proxy (L4!)
  │ kube-proxy on the node: iptables/IPVS DNAT  │     ClusterIP 10.96.0.1:80  →  one pod IP.
  │ spreads ClusterIP across READY pod IPs      │     THIS is an L4 load balancer, built
  │ (random/round-robin selection)              │     from NAT rules. No daemon in the path.
  └───────────────┬────────────────────────────┘
                  │ DNAT to a pod IP
                  ▼
  ┌────────────────────────────────────────────┐  ← LB #3 (optional): Envoy sidecar (L7)
  │ Istio/Envoy: mTLS, retries, per-request LB  │     service-mesh layer, if present.
  └───────────────┬────────────────────────────┘
                  ▼
            application container
```

**kube-proxy is itself an L4 load balancer** — a huge realization. It doesn't sit as a daemon in the packet path; it *programs the Linux kernel* (iptables `KUBE-SVC-*` chains, or IPVS) so that any packet destined for a Service's ClusterIP gets **DNAT**'d to one of the ready pod IPs, chosen with roughly uniform probability. Same four parts: listener = ClusterIP:port, pool = ready endpoints, algorithm = random/RR, "health check" = **the readiness probe** (see below). It's load balancing done entirely with the NAT machinery from [Rung 14](14-nat-and-pat.md).

**Who fills the pool in Kubernetes? The readiness probe.** A pod only becomes a *ready endpoint* when its **readiness probe** passes. The `EndpointSlice` controller watches pod readiness and adds/removes the pod IP from the Service's endpoint set. kube-proxy reprograms iptables from that set. For a cloud LB in **IP target mode**, the AWS Load Balancer Controller registers/deregisters pod IPs in the target group *from the same readiness signal*. So:

> **Readiness probe fails → pod removed from Endpoints → kube-proxy drops its DNAT rule AND the cloud LB deregisters its target → no traffic reaches it.** That is the entire answer to "why is the LB still hitting the broken pod": either the readiness probe isn't wired to the failure, or you're inside the detection window.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery |
|---|---|---|
| **Backend / target / upstream / real server** | one server or pod that can serve a request | the pool members |
| **Pool / target group / backend set / Endpoints** | the live list of backends | Part 2 (pool) |
| **VIP (virtual IP)** | the LB's single front-end IP clients hit | Part 1 (listener) |
| **Listener** | IP:port + protocol the LB accepts on | Part 1 |
| **L4 load balancing** | forwards by IP:port only, per connection | listener at transport layer; DNAT |
| **L7 load balancing** | full proxy; reads HTTP, routes by host/path/header | listener at application layer |
| **TLS termination** | LB decrypts client TLS, ends the encrypted leg | L7 listener |
| **Round-robin** | pick next in rotation | Part 3 (algorithm) |
| **Least-connections** | pick backend with fewest active conns | Part 3 |
| **Weighted** | pick proportionally to a weight | Part 3 |
| **IP-hash** | `hash(src IP)` → fixed backend | Part 3 + stickiness |
| **Health check / probe** | loop that marks backends up/down | Part 4 (gate) |
| **Sticky session / session affinity** | keep one client pinned to one backend | Part 3 policy (cookie or IP-hash) |
| **DSR (direct server return)** | backend replies straight to client, bypassing LB on the return path | forwarding optimization |
| **NLB** | AWS L4 load balancer | Part 1 at L4 |
| **ALB** | AWS L7 load balancer | Part 1 at L7 |
| **Service type=LoadBalancer** | K8s object that provisions a cloud LB | LB #1 |
| **kube-proxy** | programs kernel DNAT; L4 LB across pods | LB #2 |
| **Ingress** | K8s L7 routing rules → controller programs an ALB/NGINX | LB #1 at L7 |
| **Readiness probe** | pod's "am I ready for traffic?" check | Part 4, for the K8s pool |
| **Internal vs external LB** | private-subnet-only vs internet-facing | listener placement |

**"Same thing wearing different names" — say these out loud:**
- **backend = target = upstream = real server = pool member = endpoint.** All one concept: a thing that serves the request.
- **pool = target group = backend set = server farm = Endpoints/EndpointSlice.** The live list.
- **VIP = front-end IP = listener address = a Service's ClusterIP.** The stable address clients know.
- **health check = readiness probe = target-group health check.** The gate that filters the pool. (In Kubernetes the readiness probe *is* the LB's health check.)
- **session affinity = sticky session = persistence.** Pin client → backend.
- **L4 = transport LB = TCP/UDP LB = NLB-style. L7 = application LB = HTTP LB = ALB/proxy-style.**

---

## 🔬 Rung 5 — The Trace

Let's follow **one HTTPS request** from a laptop to an EKS pod, through an **ALB (L7) → target group of pods → kube-proxy is bypassed in IP mode**, and watch what happens when one pod is sick. This is your manager's exact scenario.

Setup: `shop.example.com` → ALB. Target group is in **IP mode** (registers pod IPs directly). Three pods: `10.0.11.5`, `10.0.11.6` (SICK — app up but `/healthz` returns 500), `10.0.11.7`. Pods live in **private subnets**; the ALB lives in **public subnets**.

```
 STEP  WHO                         WHAT HAPPENS
 ────  ──────────────────────────  ─────────────────────────────────────────────
  0    ALB health-check loop       Every 15s: GET /healthz to each pod IP.
                                    .5→200 healthy | .6→500 UNHEALTHY (evicted)
                                    | .7→200 healthy.  Pool now = {.5, .7}.
  1    Laptop → DNS                 Resolve shop.example.com → ALB has ITS OWN
                                    DNS name mapping to 2+ public IPs (the ALB
                                    nodes, one per AZ). Picks 198.51.100.9.
  2    Laptop → ALB                 TCP 3-way handshake to 198.51.100.9:443
                                    SYN → SYN-ACK → ACK. Connection #1 established
                                    WITH THE ALB (L7 = full proxy).
  3    Laptop ↔ ALB                 TLS handshake. **ALB terminates TLS** using the
                                    ACM cert for shop.example.com. Now ALB can read
                                    plaintext HTTP.
  4    ALB reads request           GET /orders  Host: shop.example.com
                                    Rule match: path /orders → target group TG-orders.
  5    ALB picks backend           Algorithm = round-robin over HEALTHY pool {.5,.7}.
                                    Picks 10.0.11.7.  **.6 is NOT a candidate** —
                                    it was evicted at step 0.  ← the whole point.
  6    ALB → pod (connection #2)    ALB opens a SEPARATE TCP connection from its
                                    private-subnet interface to 10.0.11.7:8080.
                                    Adds X-Forwarded-For: <laptop IP>. Traffic stays
                                    inside the VPC; Security Group on pods allows ALB.
  7    Pod serves                   App returns 200 + body on connection #2.
  8    ALB → laptop                 ALB relays the body back on connection #1
                                    (re-using the terminated-TLS session).
  9    Result                       User gets 200. The sick pod .6 was never touched.
                                    Failures stop the moment the health check evicts it.
```

```
   Laptop ──443/TLS──► [ ALB :443 ]  reads /orders, pool={.5,.7}
                          │  terminate TLS, pick .7 (RR)
     public subnet       │  new TCP :8080
     ───────────────────┼───────────── VPC boundary ───────────
     private subnet      ▼
                    10.0.11.5  ✅        10.0.11.6  ❌(evicted)      10.0.11.7  ✅◄── served
```

The one-line lesson: **the health-check loop at step 0 is what made step 5 safe.** If your users still hit the sick pod, the failure is in step 0 — the probe path (`/healthz`) doesn't actually exercise the broken code, or the pod's *readiness* probe (which controls target registration) is missing while only the *liveness* probe fails.

Compare the L4/NLB path: there is *no* step 3 or 4. The NLB never terminates TLS and never reads `/orders`; it DNATs the whole TCP connection to a backend and TLS is terminated *on the pod*. Faster, blinder.

---

## ⚖️ Rung 6 — The Contrast

**The older/alternative approach: DNS-based load balancing (round-robin A records), and "just make the one server bigger."**

DNS load balancing still exists and is genuinely useful — it's how you balance across *regions* (GeoDNS, Route 53 latency/weighted routing), because no single in-path box can straddle continents cheaply. But within one site it's weak.

| | DNS round-robin | L4 LB (NLB) | L7 LB (ALB) |
|---|---|---|---|
| Layer | — (name→IP) | 3/4 (IP:port) | 7 (HTTP) |
| In traffic path? | No (steps aside) | Yes | Yes (full proxy) |
| Health-aware? | **No** | Yes (TCP probe) | Yes (HTTP probe) |
| React to a dead backend | Only after TTL expires + client re-resolves | Seconds (probe interval) | Seconds (probe interval) |
| Route by host/path/header | No | No | **Yes** |
| Terminate TLS | No | No (passthrough) | **Yes** |
| Speed / throughput | N/A | Highest (kernel/header math) | Lower (parses+re-encrypts) |
| Preserves client source IP | Yes | Yes | No (adds X-Forwarded-For) |
| Any protocol? | Any | Any TCP/UDP | HTTP(S)/gRPC/WebSocket only |
| K8s equivalent | headless Service (multiple A records) | kube-proxy, `Service type=LoadBalancer`+NLB | Ingress/ALB, service mesh |

**What each can do that the others cannot:**
- **DNS** can span the globe and cost nothing in the data path — but it's blind to health and slow to react.
- **L4** is brutally fast, protocol-agnostic (databases, TLS passthrough, UDP/QUIC), and preserves the client IP — but it can't route by URL or terminate TLS.
- **L7** can do host/path/header routing, TLS termination, retries, and header rewriting — but it costs CPU, only speaks application protocols it understands, and hides the client IP (you must read `X-Forwarded-For`).

**When would I NOT use / need a load balancer?**
- A single-replica internal tool with no availability requirement — one pod, `ClusterIP` is enough (though even ClusterIP quietly uses kube-proxy).
- Raw ultra-low-latency east-west traffic where you want *zero* extra hop — you might use headless Services + client-side load balancing (the client picks from the A records itself, as gRPC clients do).
- Global region steering — that's DNS's job, not an in-path LB's.

**Why this over that (one sentence):** *Use DNS to pick a region, an L4 LB when you need raw speed or non-HTTP or the real client IP, and an L7 LB whenever a routing decision depends on what's inside the HTTP request or you want TLS terminated at the edge.*

> **Check yourself before Rung 7:** Your app needs to send `/api/*` to one pod set and `/static/*` to another, over HTTPS, using one hostname. Which layer of load balancer is *mandatory*, and name the one specific capability that rules the other layer out.

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction *out loud* before you run the command. A wrong prediction is the most valuable thing that can happen here.

### Prediction 1 (normal case): round-robin spreads requests across pod IPs

**I predict:** if I hit a ClusterIP-backed Service repeatedly from inside the cluster, consecutive requests will land on *different* pods, BECAUSE kube-proxy programs kernel DNAT rules that pick a ready endpoint with roughly uniform probability — an L4 load balancer built from NAT.

```bash
# In a cluster with a Deployment "web" (3 replicas) fronted by a ClusterIP Service "web".
# Make each pod return its own hostname, then hammer the Service from a throwaway pod.
kubectl run curler --image=curlimages/curl -it --rm --restart=Never -- \
  sh -c 'for i in $(seq 1 9); do curl -s http://web.default.svc.cluster.local/hostname; echo; done'
# Expected: pod names cycle, e.g.
#   web-6f4b... 
#   web-9c2a...
#   web-1d7e...
#   web-6f4b...   ← spread across all 3 ready pods
```

**Verify:** you should see all three pod names appear. If you see only *one*, either you have session affinity on (`service.spec.sessionAffinity: ClientIP`), or only one endpoint is Ready — check `kubectl get endpointslices -l kubernetes.io/service-name=web`. A single name teaches you: *the pool the LB is choosing from only had one member.*

### Prediction 2 (failure/edge case): a failing readiness probe evicts a pod from the LB pool

**I predict:** if I break one pod's readiness, it will *disappear from the Service Endpoints within seconds* and stop receiving traffic — even though the pod is still Running — BECAUSE the EndpointSlice controller removes not-ready pod IPs, and kube-proxy then deletes that pod's DNAT rule. This is the exact mechanism behind "the LB skips the unhealthy backend."

```bash
# Watch endpoints live in one terminal:
kubectl get endpointslices -l kubernetes.io/service-name=web -o wide -w

# In another terminal, make ONE pod fail its readiness probe.
# (Assume the readiness probe is httpGet /healthz; we flip the app to return 500,
#  or simplest: exec-break the readiness file the probe checks.)
POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- sh -c 'rm -f /tmp/ready'   # probe: exec test -f /tmp/ready

# Observe:
kubectl get pod "$POD" -o wide          # STATUS still Running, but READY 0/1
kubectl describe endpointslices -l kubernetes.io/service-name=web | grep -A3 "$POD"
# Expected: the pod's IP moves to "notReadyAddresses" / drops out of the ready set.
```

**Verify:** in the `-w` watch you'll see the endpoint count drop from 3 to 2 within a probe interval or two. Re-run Prediction 1's curl loop — the broken pod's name no longer appears. A wrong result (traffic still hitting it) teaches the deepest lesson of this whole file: *you probably only have a liveness probe, not a readiness probe — liveness restarts a pod but does NOT gate the LB target set.* Readiness is the gate.

### Prediction 3 (cloud/AWS case): inspect a real ALB target group and see the unhealthy target

**I predict:** in an EKS cluster fronted by an ALB (via the AWS Load Balancer Controller / Ingress), the ALB's target group will list each pod IP with a health state, and a pod failing `/healthz` will show `State: unhealthy` and receive no traffic — BECAUSE the ALB runs its own L7 health-check loop and only forwards to `healthy` targets.

```bash
# Find the target group ARN for your Ingress/Service, then read target health.
aws elbv2 describe-target-groups \
  --query 'TargetGroups[?contains(TargetGroupName, `web`)].TargetGroupArn' --output text
# → arn:aws:elasticloadbalancing:...:targetgroup/k8s-default-web-abc123/...

aws elbv2 describe-target-health \
  --target-group-arn arn:aws:elasticloadbalancing:...:targetgroup/k8s-default-web-abc123/...
# Expected JSON (trimmed):
#   { "Target": {"Id": "10.0.11.5", "Port": 8080}, "TargetHealth": {"State": "healthy"} }
#   { "Target": {"Id": "10.0.11.6", "Port": 8080},
#     "TargetHealth": {"State": "unhealthy", "Reason": "Target.ResponseCodeMismatch",
#                      "Description": "Health checks failed with code 500"} }
#   { "Target": {"Id": "10.0.11.7", "Port": 8080}, "TargetHealth": {"State": "healthy"} }
```

**Verify:** the sick pod shows `unhealthy` with a reason like `Target.ResponseCodeMismatch` or `Target.Timeout`. Confirm from the outside that no user request lands on it. Also confirm the target *type*: `aws elbv2 describe-target-groups ... --query 'TargetGroups[].TargetType'` returning `ip` means the ALB talks straight to pod IPs (LB #1 → pods, kube-proxy bypassed); `instance` means it targets NodePorts and kube-proxy still spreads across pods. Different answers teach you *which of the three stacked load balancers is doing the pod-level spreading.*

### Prediction 4 (local analog, no cloud needed): see L4 vs L7 with your own eyes

**I predict:** a plain L4 forward preserves bytes blindly, while an L7 proxy can read and route on the HTTP request line — I'll prove the L4 side is protocol-blind by forwarding a raw TCP port.

```bash
# L4 analog: socat forwards TCP :8080 → one backend, header-blind (like an NLB).
# Terminal A (backend):
python3 -m http.server 9001
# Terminal B (the "L4 LB"):
socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:9001
# Terminal C (client) — watch that it never inspects the path, just moves bytes:
curl -sv http://127.0.0.1:8080/anything 2>&1 | grep -E '> GET|< HTTP'
#   > GET /anything HTTP/1.1
#   < HTTP/1.1 200 OK        ← forwarded verbatim; the L4 forwarder read no HTTP

# Contrast the health-check idea at L4: is a backend even accepting connections?
nc -vz 127.0.0.1 9001        # Connection to 127.0.0.1 9001 port [tcp] succeeded!  (TCP health check = SYN/SYN-ACK)
nc -vz 127.0.0.1 9999        # Connection refused  → an L4 health check would mark this DOWN
```

**Verify:** `socat` moved the request without ever parsing `/anything` — that's L4. The `nc -vz` pair is exactly what an L4 health check does: a successful TCP handshake = healthy, connection refused = unhealthy. To *feel* L7 by contrast, put NGINX in front with `location /api { proxy_pass ...; } location /static { proxy_pass ...; }` — routing by path is only possible because NGINX reads the HTTP request line, which `socat` structurally cannot.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
A load balancer is a stable front-end address that forwards each incoming connection to one *healthy* backend from a live pool, choosing by an algorithm at either L4 (IP:port, fast/blind) or L7 (HTTP host/path, smart/TLS-terminating).

**Three-sentence beginner explanation:**
Imagine one restaurant door and a host who seats each arriving party at a free, working table — that host is a load balancer, the tables are your servers or pods, and the seating rule (round-robin, least-busy) is the algorithm. The host constantly checks which tables are actually usable (health checks) and never seats anyone at a broken one, which is how a load balancer routes around failure automatically. If the host only checks *which door you walked in* it's an L4 balancer (fast, dumb); if it reads *your reservation and what you ordered* to pick a table it's an L7 balancer (smart, can decrypt and route by URL).

**Sub-parts mapped to the one idea ("forward each connection to one healthy backend from a live pool"):**
- *"stable front-end"* → VIP / ClusterIP / ALB DNS name — the one address clients know.
- *"forward each connection"* → in-path proxying; L4 DNAT vs L7 full-proxy.
- *"one … backend"* → the algorithm: round-robin, least-connections, weighted, IP-hash; stickiness pins the choice.
- *"healthy"* → the health-check loop / readiness probe — the gate.
- *"live pool"* → target group / EndpointSlice, kept current as backends churn.
- *cloud/K8s glue* → `Service type=LoadBalancer` provisions the cloud LB; kube-proxy is the L4 LB across pods; Ingress/ALB is the L7 LB; readiness probes fill all their pools.

**Which rung to revisit hands-on:**
**Rung 7, Prediction 2.** The readiness-probe-evicts-a-pod demo is the beating heart of this concept — it's where "health checks gate the pool," "kube-proxy is an L4 LB," and "why the LB skipped the broken backend" all become one thing you can watch happen in `kubectl get endpointslices -w`. If only one idea survives, make it *readiness gates targets.*

---

## Related concepts

- [Ports, sockets & multiplexing](04-ports-sockets-multiplexing.md) — a load balancer is fundamentally a listener on an IP:port forwarding to other IP:ports.
- [Transport layer: TCP & UDP](07-transport-layer-tcp-udp.md) — L4 balancing lives here; the handshake is also the simplest health check.
- [NAT & PAT](14-nat-and-pat.md) — DNAT is literally how L4 LBs and kube-proxy forward to backends.
- [DNS](09-dns.md) — the original, health-blind load balancer and today's global region-steering layer.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — ClusterIP/NodePort/LoadBalancer and the in-kernel L4 LB in detail.
- [Kubernetes Ingress & Gateway API](27-kubernetes-ingress-gateway-api.md) — the L7 layer, ALB controllers, and TLS termination.
- [Service mesh & sidecars](29-service-mesh-and-sidecars.md) — per-request L7 load balancing pushed all the way down to an Envoy next to every pod.
