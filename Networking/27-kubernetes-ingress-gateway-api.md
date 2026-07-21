# Kubernetes Ingress & Gateway API

*One smart front door for the whole cluster — routing by hostname and URL path, terminating TLS, and doing it without a cloud load balancer per app.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** **Ingress** (the L7 HTTP entrypoint), the **Ingress Controller** that implements it, TLS termination, and the newer **Gateway API** that is succeeding Ingress.

**Why did it land on my desk?** You have ten microservices to expose on the internet. Giving each a `type: LoadBalancer` Service means ten cloud load balancers, ten IPs, ten bills — and no way to route `shop.example.com/api` vs `shop.example.com/web` to different services. Ingress is the single, HTTP-aware front door that fixes all of that. Every `shop.example.com`, every path-based route, every "add TLS to this app" request lives here.

**What do I already know?** You know L4 vs L7 load balancing ([18-load-balancing.md](18-load-balancing.md)), HTTP host/path routing ([10-http-and-https.md](10-http-and-https.md)), TLS termination ([11-tls-ssl-encryption-in-transit.md](11-tls-ssl-encryption-in-transit.md)), and that a Service load-balances at L4 ([25-kubernetes-services-kube-proxy.md](25-kubernetes-services-kube-proxy.md)). Ingress is L7 routing layered on top of Services.

---

## 🔥 Rung 1 — The Pain

A `Service type: LoadBalancer` works, but it operates at **L4** — it forwards by IP:port and knows nothing about HTTP. That creates real pain when you have more than a toy app:

- **One cloud LB per service.** Ten public services = ten ALBs/NLBs, ten external IPs, ten sets of billing and TLS certs to manage. Cloud LBs aren't free.
- **No HTTP-aware routing.** You can't say "`/api/*` → the api Service, `/` → the web Service, `admin.example.com` → the admin Service." L4 can't read the host header or the URL path.
- **TLS everywhere.** Each service would terminate its own TLS and manage its own certificate. You want that in one place.

Before Ingress, teams bolted a hand-rolled nginx/HAProxy in front and manually kept its config in sync with their Services — the exact toil Kubernetes exists to automate.

**Who feels it most?** The platform team owning cost, the single public entrypoint, and cluster-wide TLS.

> **✅ Check yourself before Rung 2:** Why can't a plain `Service type: LoadBalancer` route `example.com/api` and `example.com/web` to two different backends? (Hint: what layer does it operate at, and can it read a URL path?)

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **Ingress is a single L7 (HTTP-aware) entrypoint that routes external requests to different Services by hostname and URL path and terminates TLS — declared as a resource, and implemented by an Ingress Controller running as proxy pods inside the cluster.**

Everything derives from "one L7 front door, split into a rule and an implementation":

- *L7, HTTP-aware* → route by **host** and **path**, do **TLS termination**, add headers.
- *Single entrypoint* → one cloud LB / one IP fronts many services (huge cost/ops win).
- *Rule vs implementation* → the **Ingress resource** is declarative rules; the **Ingress Controller** (nginx, AWS ALB, Traefik) is the actual proxy that reads those rules and does the work.

> **✅ Check yourself before Rung 3:** An Ingress resource you `kubectl apply` does nothing on its own. What else must be running for it to actually route traffic?

---

## ⚙️ Rung 3 — The Machinery

### Resource vs Controller — the crucial split

Ingress has two halves, and confusing them causes most beginner grief:

- **The Ingress resource** — a small YAML object: "for host `shop.example.com`, path `/api` → Service `api:80`; path `/` → Service `web:80`; use this TLS secret." It's just *declared intent*. On its own it does nothing.
- **The Ingress Controller** — a running workload (nginx, AWS Load Balancer Controller, Traefik, HAProxy, Contour) that **watches** Ingress resources and **configures a real proxy** accordingly. It runs as **pods**, usually fronted by a single `Service type: LoadBalancer` (so there's exactly one cloud LB for the whole cluster).

```
        Internet
           │  https://shop.example.com/api
           ▼
  ┌──────────────────────────┐   ONE cloud LB (ALB/NLB) for the whole cluster
  │  Cloud Load Balancer     │
  └───────────┬──────────────┘
              ▼
  ┌──────────────────────────────────────────┐
  │  Ingress Controller PODS (e.g. nginx)     │   ← the actual L7 proxy
  │  reads Ingress resources, terminates TLS  │
  │                                            │
  │  host shop.example.com:                    │
  │    /api  → Service api  (ClusterIP)        │
  │    /web  → Service web  (ClusterIP)        │
  │    /     → Service frontend (ClusterIP)    │
  └───────┬───────────┬───────────┬───────────┘
          ▼           ▼           ▼
     Service api  Service web  Service frontend   ── 25 (kube-proxy DNAT → pods)
          │           │           │
        pods        pods        pods
```

The controller does L7 work — inspect host/path, match a rule, terminate TLS, forward to the chosen **Service** (which then L4-load-balances to pods via kube-proxy). So the full chain is: **cloud LB → controller pods (L7 route + TLS) → Service (L4) → pods.**

### TLS termination

An Ingress references a Kubernetes **Secret** holding a certificate + key. The controller presents that cert to clients and decrypts HTTPS at the edge of the cluster, forwarding plain (or re-encrypted) HTTP to the backend. **cert-manager** automates issuing/renewing those certs (e.g. from Let's Encrypt), so TLS becomes declarative and self-renewing — no more expired-cert outages ([11](11-tls-ssl-encryption-in-transit.md)).

### The successor: Gateway API

Ingress has limits: it's HTTP-centric, its advanced features hide in controller-specific **annotations** (so manifests aren't portable), and it muddles roles. The **Gateway API** is the newer, official successor:

- **GatewayClass** — the kind of gateway (like a StorageClass, chosen by the platform).
- **Gateway** — an actual listener (ports, protocols, TLS) — owned by the platform/cluster-ops.
- **HTTPRoute** (and TCPRoute, GRPCRoute…) — the routing rules — owned by app teams.

This role split (infra owns the Gateway, devs own their Routes), richer matching, and protocol support beyond HTTP make Gateway API the direction the ecosystem is moving — but Ingress remains extremely common today.

> **✅ Check yourself before Rung 4:** Trace the layers: after the Ingress Controller picks a Service by URL path, what does the *Service* then do to actually reach a pod?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Ingress resource** | Declarative host/path→Service rules + TLS | The intent |
| **Ingress Controller** | Proxy pods (nginx/ALB/Traefik) that implement it | The doer |
| **L7 routing** | Route by hostname + URL path | What Ingress adds over a Service |
| **TLS termination** | Decrypt HTTPS at the entrypoint | Handled by the controller |
| **cert-manager** | Auto-issues/renews TLS certs | Automates the TLS secret |
| **Annotations** | Controller-specific extra config | Advanced Ingress behavior |
| **GatewayClass** | The type of gateway | Gateway API |
| **Gateway** | A listener (ports/protocol/TLS) | Gateway API (infra-owned) |
| **HTTPRoute** | Routing rules attached to a Gateway | Gateway API (dev-owned) |
| **AWS LB Controller** | Provisions an ALB from Ingress/Gateway | EKS implementation |

**Same-kind-of-thing groupings:** *Ingress resource + Ingress Controller* mirror *desired state + controller that realizes it* (a control-plane/data-plane split, [22](22-sdn-software-defined-networking.md)). *Ingress ≈ Gateway + HTTPRoute* — the newer API splits the one Ingress object into role-separated pieces. *nginx, ALB, Traefik, Contour* are interchangeable controllers.

---

## 🔬 Rung 5 — The Trace

**A browser requests `https://shop.example.com/api/orders` on an EKS cluster with the AWS Load Balancer Controller.**

```
Browser
  │ 1. DNS: shop.example.com → the ALB's address (a CNAME/A record) ── 09
  ▼
[AWS ALB]  (ONE load balancer for the cluster) ── 18 / 20
  │ 2. TLS terminates here (cert from the referenced Secret / ACM)
  │ 3. L7 rule (compiled from the Ingress): path /api/* → target group for "api"
  ▼
[Ingress path → Service "api"]   (ALB target group = the api Service's pods/NodePort)
  ▼
[kube-proxy DNAT] ── 25
  │ 4. Service ClusterIP → a ready api pod IP
  ▼
[api pod] handles GET /orders → response walks back up, re-encrypted to the browser
```

For an **nginx** Ingress Controller instead of ALB, steps 2–3 happen inside the nginx **controller pods** (fronted by one `Service type: LoadBalancer`) rather than in a cloud ALB — same shape, different proxy. Either way: L7 host/path decision at the front, then a normal Service→pod delivery.

> **✅ Check yourself before Rung 6:** In that trace, which single component made the "`/api` goes to the api service" decision, and at which OSI layer did it operate?

---

## ⚖️ Rung 6 — The Contrast

**The alternatives: a LoadBalancer Service per app (L4), or the newer Gateway API.**

| Task | LoadBalancer per Service | Ingress | Gateway API |
|---|---|---|---|
| Number of cloud LBs | one **per service** 💸 | one for many | one for many |
| Route by host/path | ❌ (L4) | ✅ | ✅ (richer) |
| TLS termination | per service | centralized | centralized |
| Advanced config | n/a | controller **annotations** (non-portable) | typed, portable fields |
| Role separation (infra vs dev) | none | muddled | ✅ explicit |
| Non-HTTP protocols | any (it's L4) | HTTP-focused | HTTP/TCP/gRPC/TLS |

**Ingress vs Service LoadBalancer:** use a `LoadBalancer` Service when you need raw L4 (e.g. a database, a custom TCP protocol, or an NLB for extreme throughput); use **Ingress/Gateway** when you're exposing HTTP(S) apps and want host/path routing, shared TLS, and one entrypoint.

**When would I NOT use Ingress?** For purely internal service-to-service traffic (use ClusterIP + DNS), or for non-HTTP L4 workloads (use a LoadBalancer Service or Gateway API's TCPRoute).

**One-sentence why-this-over-that:** *Use Ingress/Gateway for HTTP(S) apps that need name/path routing and shared TLS behind one entrypoint; use a LoadBalancer Service for raw L4 or non-HTTP protocols.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: path-based routing to two Services

> **Prediction:** "If I define one Ingress with two path rules, requests to `/web` reach the web Service and `/api` reach the api Service through a *single* entrypoint, BECAUSE the controller reads the URL path (L7) and routes accordingly."

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
spec:
  ingressClassName: nginx
  rules:
  - host: shop.example.com
    http:
      paths:
      - { path: /api, pathType: Prefix, backend: { service: { name: api,  port: { number: 80 } } } }
      - { path: /,    pathType: Prefix, backend: { service: { name: web,  port: { number: 80 } } } }
```

```bash
kubectl apply -f ingress.yaml
INGRESS_IP=$(kubectl get ingress shop -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -H 'Host: shop.example.com' http://$INGRESS_IP/api/health   # → api service
curl -s -H 'Host: shop.example.com' http://$INGRESS_IP/             # → web service
```

**Verify:** the two paths reach two different backends through one IP. If both hit the same backend, your `pathType`/order is off, or the ingress class doesn't match a running controller.

### Example 2 — Edge/failure case: an Ingress with no controller does nothing

> **Prediction:** "If I apply an Ingress but no Ingress Controller is installed, the resource exists but gets no address and routes nothing, BECAUSE the resource is only intent — a controller must implement it."

```bash
kubectl apply -f ingress.yaml
kubectl get ingress shop
# NAME   CLASS   HOSTS              ADDRESS   PORTS   AGE
# shop   nginx   shop.example.com   <empty>   80      30s     <- ADDRESS never populates
kubectl describe ingress shop | grep -i events -A3
# (no controller events — nothing is reconciling it)
```

**Verify:** `ADDRESS` stays empty and there are no controller events. Install a controller (`helm install ingress-nginx ingress-nginx/ingress-nginx`) and the address appears. This is the #1 "my Ingress isn't working" cause — the resource is fine; nothing is implementing it.

### Example 3 — Kubernetes-flavored: the same routing expressed in Gateway API

> **Prediction:** "If I express the same routing with Gateway API, the Gateway owns the listener/TLS and an HTTPRoute owns the rules, BECAUSE Gateway API splits the single Ingress object into role-separated resources."

```yaml
# gateway.yaml (platform-owned)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: shop-gw }
spec:
  gatewayClassName: nginx
  listeners:
  - { name: http, protocol: HTTP, port: 80 }
---
# route.yaml (app-team-owned)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: shop-route }
spec:
  parentRefs: [{ name: shop-gw }]
  hostnames: ["shop.example.com"]
  rules:
  - matches: [{ path: { type: PathPrefix, value: /api } }]
    backendRefs: [{ name: api, port: 80 }]
  - matches: [{ path: { type: PathPrefix, value: / } }]
    backendRefs: [{ name: web, port: 80 }]
```

```bash
kubectl apply -f gateway.yaml -f route.yaml
kubectl get gateway shop-gw            # PROGRAMMED = True when a controller accepts it
kubectl get httproute shop-route -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
# True
```

**Verify:** the Gateway shows `PROGRAMMED=True` and the HTTPRoute is `Accepted=True`, giving the same routing as the Ingress but with the listener/TLS (Gateway) cleanly separated from the routing rules (HTTPRoute). Requires a Gateway-API-capable controller installed.

---

## 🏔 Capstone — Compress It

**One sentence:** Ingress is a single L7 entrypoint that routes external HTTP(S) to different Services by hostname and URL path and terminates TLS — declared as an Ingress resource and made real by an Ingress Controller running as proxy pods — with Gateway API as its more expressive, role-separated successor.

**Explain it to a beginner in 3 sentences:**
1. Exposing every app with its own cloud load balancer is expensive and can't route by URL, so Ingress gives you one HTTP-aware front door that sends `example.com/api` and `example.com/web` to different services and handles TLS in one place.
2. An Ingress is just a set of rules; it does nothing until an Ingress Controller (nginx, AWS ALB, Traefik) — which runs as pods — reads those rules and configures a real proxy.
3. The newer Gateway API does the same job but splits it into a Gateway (owned by platform teams) and HTTPRoutes (owned by app teams) for cleaner ownership and richer routing.

**Sub-parts mapped to the one idea (one L7 front door: rule + implementation):**
```
Ingress resource   → the host/path/TLS rules (intent)
Ingress Controller → proxy pods that implement them
L7 routing         → by host + URL path
TLS termination    → cert (Secret) presented at the edge; cert-manager renews
Gateway API        → Gateway (listener) + HTTPRoute (rules), role-separated
chain              → cloud LB → controller → Service → pods
```

**Which rung to revisit hands-on:** Rung 7 Example 2 — feeling an Ingress do *nothing* without a controller cements the resource-vs-controller split forever.

---

## Related concepts

- [Load Balancing](18-load-balancing.md) — L4 vs L7; the cloud LB in front of the controller.
- [HTTP & HTTPS](10-http-and-https.md) — the host/path/headers Ingress routes on.
- [TLS/SSL — Encryption in Transit](11-tls-ssl-encryption-in-transit.md) — TLS termination and cert-manager.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — the Services Ingress forwards to.
- [Kubernetes DNS & Service Discovery](26-kubernetes-dns-service-discovery.md) — internal names vs the external hostnames Ingress serves.
- [The AWS VPC](20-aws-vpc.md) — where the ALB and public subnets live.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why can't a plain `Service type: LoadBalancer` route `example.com/api` and `example.com/web` to two different backends?

**A:** Because a LoadBalancer Service operates at **L4** — it forwards by IP:port and never parses the HTTP request. The hostname lives in the Host header and `/api` vs `/web` lives in the URL path, both of which are HTTP (L7) concepts an L4 forwarder cannot read. To it, both requests are just TCP segments to the same IP:port, so it has no information on which to make a different routing decision. Only an L7-aware proxy — an Ingress Controller — can inspect host and path and split the traffic.

### Before Rung 3
**Q:** An Ingress resource you `kubectl apply` does nothing on its own. What else must be running for it to actually route traffic?

**A:** An **Ingress Controller** — a running workload such as nginx, the AWS Load Balancer Controller, or Traefik. The Ingress resource is only declared intent (host/path→Service rules plus a TLS secret reference); the controller runs as proxy pods (usually fronted by one `Service type: LoadBalancer`), watches Ingress resources, and configures a real L7 proxy from them. Without a controller matching the ingress class, the resource sits there with an empty ADDRESS and routes nothing — the file's #1 "my Ingress isn't working" cause.

### Before Rung 4
**Q:** After the Ingress Controller picks a Service by URL path, what does the *Service* then do to actually reach a pod?

**A:** The Service does normal **L4 load balancing via kube-proxy**: the controller forwards the request to the Service's ClusterIP, and kube-proxy's rules **DNAT** that virtual IP to the IP:port of one ready backend pod. So the full chain is cloud LB → controller pods (L7 route + TLS termination) → Service ClusterIP (L4, kube-proxy DNAT) → pod. The Ingress layer chooses *which Service*; the Service layer chooses *which pod*.

### Before Rung 6
**Q:** In the trace, which single component made the "`/api` goes to the api service" decision, and at which OSI layer did it operate?

**A:** The **Ingress Controller's proxy** made that decision — in the EKS trace, the AWS ALB executing the L7 rule compiled from the Ingress by the AWS Load Balancer Controller (with nginx, it would be the nginx controller pods instead). It operated at **Layer 7**, because matching the path `/api/*` (and the host `shop.example.com`) requires reading the HTTP request itself. Everything after that decision — kube-proxy's DNAT from ClusterIP to a pod — is plain L4 forwarding.
