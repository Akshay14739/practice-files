# Service Mesh & Sidecars

*Put a smart proxy next to every service, route all traffic through it, and get encryption, resilience, and observability without touching a line of app code.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** The service-mesh pattern — an **Envoy** sidecar proxy beside every pod, a control plane configuring them all — delivering traffic management, automatic mTLS, and observability. This is the conceptual bridge to the full [Istio deep-dive](../Istio_Learning_Ladder.md).

**Why did it land on my desk?** You have dozens of microservices. Your lead wants: encrypt all service-to-service traffic (compliance), canary 10% of traffic to a new version, retry failed calls, and see a live map of who calls whom — *without* asking every team to rewrite their app. A service mesh does all of that at the network layer.

**What do I already know?** You know Services and kube-proxy (L4) ([25-kubernetes-services-kube-proxy.md](25-kubernetes-services-kube-proxy.md)), Ingress (L7 at the edge) ([27-kubernetes-ingress-gateway-api.md](27-kubernetes-ingress-gateway-api.md)), TLS/mTLS ([11-tls-ssl-encryption-in-transit.md](11-tls-ssl-encryption-in-transit.md)), NetworkPolicy (L3/L4 filtering) ([28-kubernetes-network-policies.md](28-kubernetes-network-policies.md)), and the control/data-plane split ([22-sdn-software-defined-networking.md](22-sdn-software-defined-networking.md)). A mesh is those ideas applied to *east-west* (service-to-service) L7 traffic.

---

## 🔥 Rung 1 — The Pain

Every microservice needs the same "networking survival kit": retry failed calls, time out hung ones, stop hammering a dead service (circuit breaking), encrypt traffic, prove identity, emit metrics, load-balance. Before meshes, this lived **inside every app** as libraries (Hystrix, Ribbon…):

- **Rewritten per language.** A Java, a Python, and a Go service each need their own implementation of the same logic. Three stacks, three versions, endless drift.
- **Upgrades = redeploy everything.** Change the retry policy and every team must ship a new build.
- **Inconsistent and unauditable.** Team A retries 3×, team B 5×; is *every* service actually encrypting? Who can prove it in an audit?
- **Business logic tangled with plumbing.** Developers resent it; the platform team holds the bag at 3 AM.

Kubernetes gives you Services (L4 load balancing) and NetworkPolicy (L3/L4 filtering), but neither does **L7 traffic management, automatic encryption, or per-request observability** across every hop. That gap is the mesh's reason to exist.

**Who feels it most?** The platform/SRE team — the ones who must impose consistent security and resilience across services they don't own the code for.

> **✅ Check yourself before Rung 2:** Why is putting retry/TLS/metrics logic inside each app (as a library) painful once you have services written in several languages?

---

## 💡 Rung 2 — The One Idea

Memorize this (the same sentence that opens the Istio ladder):

> **A service mesh puts a network proxy next to every service and routes all traffic through it, so networking behavior — routing, security, resilience, observability — is controlled by the platform from outside the app, not coded inside it.**

Everything derives from "a proxy next to every service, controlled centrally":

- *A proxy next to every service* → the **sidecar** (your `2/2` pods: app + Envoy).
- *All traffic through it* → traffic is **transparently intercepted** (iptables in the pod), so the app needs zero changes.
- *Controlled by the platform* → a **control plane** pushes config and certs to every proxy.
- *Routing, security, resilience, observability* → all just "things the proxy does to traffic passing through it."

Every mesh feature is one pattern applied many ways: **the proxy is a chokepoint you program.**

> **✅ Check yourself before Rung 3:** If a proxy sees *all* traffic in and out of every service, why does that single fact make encryption, canary routing, AND observability all possible at once?

---

## ⚙️ Rung 3 — The Machinery

### Two planes

- **Data plane** — the **Envoy** sidecar proxies, one per pod, that carry every request. They do the actual work: encrypt, route, retry, measure.
- **Control plane** — **istiod** (in Istio): takes your high-level config, translates it to Envoy config, issues TLS certificates (identity), and pushes both to every proxy. It **never touches request traffic** — if it dies, existing traffic keeps flowing; you just can't push new config.

```
┌───────────────────────────────────────────────────────────┐
│  CONTROL PLANE — istiod (the brain)                        │
│   • your config (VirtualService, PeerAuthentication…)      │
│   • issues mTLS certs (identity)  • pushes to all proxies  │
└───────────────┬───────────────────────────────────────────┘
                │ push config + certs (never touches traffic)
      ┌─────────┼──────────┐
      ▼         ▼          ▼
  DATA PLANE — one Envoy per pod (the muscle)
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ app+Envoy│  │ app+Envoy│  │ app+Envoy│   ← every pod is "2/2"
  └────┬─────┘  └────┬─────┘  └────┬─────┘
    productpage    reviews      ratings
       └── mTLS ──────┴── mTLS ─────┘   traffic flows pod→pod via Envoys ONLY
```

### The interception trick (why apps need no changes)

When a mesh pod starts, an **init container** rewrites the pod's **iptables** so *all* inbound and outbound traffic is redirected to the Envoy first (Envoy listens on ports like 15001 outbound / 15006 inbound). The app calls `reviews:9080` thinking it's a direct connection — iptables silently hands it to Envoy, which decides routing, encrypts with mTLS, applies retries, and forwards. The app never knows. **This is why mesh pods are `2/2`** (app + sidecar) and why a `kubectl describe pod` shows an `istio-init` container ([../Linux/13-namespaces.md](../Linux/13-namespaces.md) explains the namespace/iptables it manipulates).

### The three capability families

| Family | What Envoy does | Configured by |
|---|---|---|
| **Traffic management** | Route by version, weight (canary), retry, timeout, circuit-break | VirtualService + DestinationRule |
| **Security** | Automatic **mTLS** (encrypt + verify identity), authz | PeerAuthentication + AuthorizationPolicy |
| **Observability** | Emit metrics, traces, access logs for every hop | Automatic (Kiali/Grafana/Jaeger read them) |

Because every hop passes through a proxy pair, **mTLS is automatic** (istiod mints a cert per workload identity), **canary is just a weight**, and **the service graph is free** (every Envoy reports latency/status).

### The cost (be honest)

A sidecar per pod = **more CPU/RAM**, an **extra hop of latency** (usually sub-millisecond, but nonzero), and a **control plane to operate**. Newer **ambient/sidecarless** meshes (Istio ambient, Cilium's eBPF mesh) push the data plane into a per-node component or the kernel to cut that overhead.

> **✅ Check yourself before Rung 4:** The app calls another service and "never knows" a proxy intercepted it. What mechanism inside the pod makes that interception invisible?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Service mesh** | Proxies everywhere + a brain controlling them | The whole pattern |
| **Sidecar** | The extra proxy container in each pod | Data plane, per pod |
| **Envoy** | The proxy software (fast C++) | Every sidecar |
| **Data plane** | All the Envoy proxies collectively | Where traffic flows |
| **Control plane / istiod** | The brain configuring proxies + issuing certs | Pushes config + certs |
| **istio-init / iptables redirect** | Init container rewriting pod iptables | The interception setup |
| **mTLS** | Mutual TLS between proxies | Encryption + identity |
| **VirtualService** | Routing rules (where traffic goes) | Traffic management config |
| **DestinationRule** | Subsets + traffic policy (LB, circuit break) | Traffic management config |
| **Ambient / sidecarless** | Mesh without a per-pod proxy | Lower-overhead data plane |

**Same-kind-of-thing groupings:** *sidecar = Envoy = data-plane member = the 2nd container in `2/2`* (one thing, many names). *Control plane = istiod = the brain.* *VirtualService + DestinationRule* always pair up for routing. *mTLS + authz* are the security family.

---

## 🔬 Rung 5 — The Trace

**`productpage` calls `reviews` in a mesh with STRICT mTLS and a 90/10 canary split to reviews-v2.**

```
[productpage app] connect to reviews:9080  (thinks it's direct)
   │ 1. pod iptables (from istio-init) REDIRECTS the call to the local Envoy
   ▼
[productpage's Envoy]
   │ 2. VirtualService for reviews: 90% v1 / 10% v2 → rolls → picks v2
   │ 3. DestinationRule: how to reach subset v2, its LB/circuit-break policy
   │ 4. wrap in mTLS using the cert istiod issued (identity = productpage)
   ▼ ── encrypted, mutually-authenticated hop ──
[reviews-v2's Envoy :15006 inbound]
   │ 5. verify productpage's identity, decrypt, apply AuthorizationPolicy
   │ 6. hand the plain request to the app on localhost:9080
   ▼
[reviews-v2 app] handles it → response returns the same way
   │ 7. BOTH Envoys emitted metrics (latency, status) to Prometheus
   ▼
Kiali later draws this exact path with live numbers — for free.
```

The apps were "blissfully unaware": encryption, canary routing, and metrics all happened in the proxies. Retries/circuit-breaking, if reviews-v2 were failing, would trigger at **step 4** inside productpage's Envoy — not in the app.

> **✅ Check yourself before Rung 6:** At step 2 two config objects together decided where the call went. Name both, and say which step (the app or the Envoy) is where a retry would happen.

---

## ⚖️ Rung 6 — The Contrast

**Alternatives: in-app libraries (the old way), or plain Kubernetes primitives (Services + NetworkPolicy).**

| Capability | In-app libraries | K8s Services + NetworkPolicy | Service mesh |
|---|---|---|---|
| Retry / circuit break | ✅ per language | ❌ | ✅ (in Envoy) |
| Encrypt service-to-service | ✅ per language | ❌ | ✅ automatic mTLS |
| Canary / weighted routing | hard | ❌ (L4 only) | ✅ (VirtualService) |
| Identity-based authz (L7) | ✅ per language | ❌ (L3/L4) | ✅ (AuthorizationPolicy) |
| Live service map / tracing | build it | ❌ | ✅ free |
| App code changes | required | none | **none** |
| Extra latency / resources | in-process | none | **sidecar overhead** |

**vs kube-proxy/Services:** Services do L4 load balancing; a mesh does **L7** routing, encryption, and resilience per request. **vs NetworkPolicy:** NetworkPolicy *filters* at L3/L4; a mesh *encrypts and manages* at L7 with cryptographic identity. They stack.

**When NOT to use a mesh:** small clusters / few services with no compliance pressure (the sidecar overhead outweighs the benefit — your earlier IP-exhaustion pain is a real example of mesh overhead biting); latency-critical hot paths (each hop adds a little); or a team that doesn't yet understand it (a mesh you can't debug is a liability). For "just get external traffic in," a plain Ingress ([27](27)) is simpler.

**One-sentence why-this-over-that:** *Use a mesh when you need consistent security, resilience, and visibility BETWEEN services (east-west, L7) without changing app code; skip it for small/simple systems or when only north-south routing is needed.*

---

## 🧪 Rung 7 — The Prediction Test

> These assume Istio installed with automatic sidecar injection enabled on the namespace (`kubectl label ns default istio-injection=enabled`).

### Example 1 — Normal case: the sidecar makes pods `2/2`

> **Prediction:** "If I deploy a pod into an injection-enabled namespace, it comes up `2/2` (app + Envoy) and shows an `istio-init` container, BECAUSE the mesh injects a proxy and an iptables-rewriting init container."

```bash
kubectl label namespace default istio-injection=enabled --overwrite
kubectl create deployment web --image=nginx
kubectl get pods -l app=web
# NAME       READY   STATUS
# web-xxx    2/2     Running        <- app + istio-proxy sidecar
kubectl get pod -l app=web -o jsonpath='{.items[0].spec.initContainers[*].name}{"\n"}'
# istio-init                        <- the iptables-rewriting init container
```

**Verify:** `READY 2/2` and an `istio-init` init container. If it's `1/1`, injection isn't active — the namespace label or the injection webhook is missing (the classic "my mesh isn't doing anything" cause).

### Example 2 — Edge/failure case: STRICT mTLS blocks a non-meshed pod

> **Prediction:** "If I set mTLS to STRICT, a pod *without* a sidecar can't reach a meshed service, while meshed pods still can, BECAUSE STRICT makes every inbound Envoy reject plaintext, and a non-meshed pod has no Envoy/cert to do mTLS."

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: { name: default, namespace: default }
spec: { mtls: { mode: STRICT } }
```

```bash
kubectl apply -f strict-mtls.yaml
# Non-meshed pod (1/1, no sidecar) → meshed service: FAILS
kubectl run legacy --image=busybox:1.36 --restart=Never -it --rm \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' -- \
  wget -qO- --timeout=4 http://web.default.svc.cluster.local ; echo "exit=$?"
# exit=1     <- rejected: plaintext not allowed under STRICT
# A meshed pod (2/2) reaches it fine, because its Envoy speaks mTLS.
```

**Verify:** the non-meshed pod fails; a meshed one succeeds. If the non-meshed pod *succeeds*, mTLS is still PERMISSIVE, not STRICT — recheck the PeerAuthentication applied.

### Example 3 — Kubernetes-flavored: canary with a weight, no redeploy

> **Prediction:** "If I set a VirtualService to 90/10 across two versions, ~1 in 10 requests hits v2 with no pod restart, BECAUSE I reconfigured the proxies (via istiod), not the app."

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: { name: reviews }
spec:
  hosts: [reviews]
  http:
  - route:
    - { destination: { host: reviews, subset: v1 }, weight: 90 }
    - { destination: { host: reviews, subset: v2 }, weight: 10 }
# (a DestinationRule defines subsets v1/v2 by version label)
```

```bash
kubectl apply -f reviews-vs.yaml     # no pod restart needed
# Sample 30 requests; count how many reached v2:
for i in $(seq 30); do
  kubectl exec deploy/productpage -c productpage -- \
    curl -s http://reviews:9080/ | grep -o 'reviews-v2' | head -1
done | grep -c reviews-v2
# ~3        <- roughly 10% (probabilistic, not exactly 3)
```

**Verify:** roughly 2–4 of 30 hit v2, and no pod was restarted. If you predicted *exactly* 3, repair that: weights are statistical, not a rota. Bump the weight and re-sample to confirm the proxy re-read the config live.

---

## 🏔 Capstone — Compress It

**One sentence:** A service mesh runs an Envoy proxy beside every service and transparently routes all traffic through it (via pod iptables), so the platform controls routing, automatic mTLS encryption, resilience, and observability from outside the app — at the cost of per-pod proxy overhead you can reduce with ambient/eBPF meshes.

**Explain it to a beginner in 3 sentences:**
1. A mesh slips a small proxy next to each service and quietly forces all the service's traffic through it using kernel routing rules, so your app code never changes.
2. A central brain pushes rules and TLS certificates to all those proxies, giving you version-based routing, canary deploys, automatic encryption between services, retries, and circuit breaking for free.
3. Because every proxy also reports metrics, you get a live map of your whole system — something a plain Ingress (which only sees traffic entering the cluster) can never provide — but the extra proxy per pod costs some CPU, memory, and latency.

**Sub-parts mapped to the one idea (the proxy is a programmable chokepoint):**
```
Traffic management → VirtualService + DestinationRule (route/weight/retry)
Security           → PeerAuthentication (mTLS) + AuthorizationPolicy
Observability      → automatic metrics/traces per Envoy
Interception       → istio-init rewrites pod iptables (invisible to the app)
Control vs data    → istiod configures; Envoys carry the traffic
When NOT to        → small/latency-critical clusters (use ambient/eBPF or none)
```

**Which rung to revisit hands-on:** Rung 3's iptables interception — `kubectl exec` into a sidecar and look (`istioctl proxy-config listeners <pod>` shows the 15001/15006 setup); it makes the "invisible proxy" real. For the full climb, do the [Istio Learning Ladder](../Istio_Learning_Ladder.md).

---

## Related concepts

- [Istio deep-dive (full Learning Ladder)](../Istio_Learning_Ladder.md) — the complete, hands-on climb of one mesh.
- [TLS/SSL — Encryption in Transit](11-tls-ssl-encryption-in-transit.md) — the mTLS the mesh automates.
- [Kubernetes Services & kube-proxy](25-kubernetes-services-kube-proxy.md) — the L4 layer the mesh sits above.
- [Kubernetes Network Policies](28-kubernetes-network-policies.md) — L3/L4 filtering that stacks under the mesh's L7 rules.
- [SDN — Software-Defined Networking](22-sdn-software-defined-networking.md) — istiod/Envoy as another control/data-plane split.
- [Network Observability](32-network-observability.md) — the metrics and traces the mesh emits.
