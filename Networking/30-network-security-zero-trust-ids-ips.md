# Network Security — Zero Trust, IDS/IPS & DDoS

*Stop trusting the network. Verify every request, encrypt every hop, watch for intruders, and design so one breach doesn't become ten.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** The pillars of network security: **Zero Trust** ("never trust, always verify"), **encryption in transit**, **IDS vs IPS** (detect vs block), **DDoS** attacks and mitigation, and **defense in depth** — layering all the controls from earlier chapters.

**Why did it land on my desk?** A pentest report says "a compromised pod could reach the database and move laterally to three other namespaces." Compliance (SOC2, PCI, HIPAA) demands encryption in transit and proof of segmentation. A traffic flood knocked over an endpoint last quarter. All of these are network-security questions, and they tie together every control you've learned.

**What do I already know?** You've met firewalls/SG/NACL ([17-firewalls-security-groups-nacls.md](17-firewalls-security-groups-nacls.md)), NetworkPolicy ([28-kubernetes-network-policies.md](28-kubernetes-network-policies.md)), TLS/mTLS ([11-tls-ssl-encryption-in-transit.md](11-tls-ssl-encryption-in-transit.md)), the service mesh ([29-service-mesh-and-sidecars.md](29-service-mesh-and-sidecars.md)), VPNs ([19-vpn-and-zero-trust-connectivity.md](19-vpn-and-zero-trust-connectivity.md)), and CDN/WAF ([21-cdn-edge-waf.md](21-cdn-edge-waf.md)). This chapter is the *strategy* that arranges them.

---

## 🔥 Rung 1 — The Pain

The old security model was the **castle and moat**: a hard perimeter (firewall/VPN) with a soft, trusting interior. Once you were "inside" the corporate network, you were trusted. That model shatters in the cloud:

- **The perimeter dissolved.** Workloads span clouds, VPNs, laptops, and SaaS. There is no single "inside."
- **Lateral movement is devastating.** An attacker who phishes one credential or pops one pod is now "inside" — and the flat, trusting interior lets them reach everything ([28](28)). One breach becomes a full compromise.
- **Plaintext internal traffic is a liability.** "It's on our private network" is not a defense; anyone who gets a foothold can sniff it, and auditors reject it.
- **Attacks that don't need a login at all.** A **DDoS** flood doesn't break in — it drowns you in traffic until you're offline.

The pain is that trusting the network *location* is a false assumption, and everything built on it is fragile.

**Who feels it most?** Security and platform teams, jointly — the ones who must "assume breach" and still keep the system safe and available.

> **✅ Check yourself before Rung 2:** Why does "trusted once you're on the corporate network" become dangerous the moment an attacker gets a single foothold inside?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **Zero Trust replaces "trust the network location" with "authenticate and authorize every request, encrypt every hop, and assume breach" — so trust comes from verified identity, not from where a packet came from, and no single compromise gives access to everything.**

Everything derives from "never trust the network, verify every request":

- *Verify every request* → strong identity + authorization on **every** call, internal or external (mTLS + authz + RBAC).
- *Encrypt every hop* → no plaintext, even "inside" (TLS end to end).
- *Assume breach* → **least privilege** and **micro-segmentation** so a popped pod can reach almost nothing (NetworkPolicy, SG).
- *Watch continuously* → **IDS/IPS** and observability to detect and stop intruders in progress.

> **✅ Check yourself before Rung 3:** In Zero Trust, where does "trust" come from if not from being on the internal network?

---

## ⚙️ Rung 3 — The Machinery

### Defense in depth — the layer cake

No single control is enough; you stack independent layers so bypassing one still leaves others:

```
   Internet
      │
   [1] Edge: CDN + WAF + DDoS scrubbing ── 21   (block floods & L7 attacks)
      │
   [2] VPC boundary: Security Groups + NACLs ── 17   (L3/L4 allow-lists)
      │
   [3] Cluster edge: Ingress/Gateway + TLS ── 27/11   (authenticated entry)
      │
   [4] Pod-to-pod: NetworkPolicy ── 28   (micro-segmentation, L3/L4)
      │
   [5] Service identity: mesh mTLS + AuthorizationPolicy ── 29   (L7 identity, encryption)
      │
   [6] App/API: RBAC, authN/authZ, secrets   (least privilege)
      │
   [ across all ] IDS/IPS + flow logs + tracing ── 32   (detect & respond)
```

Each layer verifies independently — that's Zero Trust in practice: an attacker past the WAF still faces SGs, then NetworkPolicy, then mTLS identity, then app authz.

### IDS vs IPS — the one-word difference

Both watch traffic for threat patterns (signatures, anomalies). The difference is what they do:

- **IDS (Intrusion Detection System):** monitors and **alerts**. It's a smoke detector — it tells you something's wrong but doesn't act.
- **IPS (Intrusion Prevention System):** sits **in-line** and **blocks** the malicious traffic in real time. It's the sprinkler — it acts.

```
  traffic ──▶ [ IDS ] ──▶ destination        (copy inspected; alert only)
                 └─ alert

  traffic ──▶ [ IPS ] ──▶ destination        (in path; drops bad packets)
                 └─ block + alert
```

In Kubernetes, **eBPF**-based tools (Cilium/Tetragon, Falco) provide runtime network + syscall detection — an IDS/IPS that understands pods and identities, not just IPs.

### DDoS — types and mitigation

A **Distributed Denial of Service** floods you from many sources so real users can't get through. Three flavors:

| Type | What it floods | Example | Mitigation |
|---|---|---|---|
| **Volumetric** | Bandwidth | UDP/ICMP flood, amplification | Scrubbing, anycast/CDN absorption ([21](21)) |
| **Protocol** | Connection state | SYN flood (half-open TCP) | SYN cookies, rate limiting, stateful firewalls |
| **Application (L7)** | App resources | HTTP flood, expensive queries | WAF, rate limiting, CAPTCHAs |

The core defense is **absorb and filter far from the origin** — hundreds of fat edge PoPs soak the flood; rate limiting and WAF drop the rest before it reaches your pods.

### Encryption in transit everywhere

Zero Trust demands **no plaintext hops**: user→LB (TLS), LB→app (TLS/re-encrypt), app→app (mesh mTLS), app→DB (TLS). This satisfies GDPR/HIPAA/SOC2 and means a sniffing attacker gets ciphertext even "inside."

> **✅ Check yourself before Rung 4:** An IDS and an IPS both spot the same malicious packet. What does each one *do* about it, and why might you deploy an IDS where you can't risk an IPS's false-positive blocking?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Zero Trust** | Verify every request, trust identity not location | The strategy |
| **Perimeter / castle-and-moat** | The old "trust the inside" model | What Zero Trust replaces |
| **Lateral movement** | Attacker hopping host-to-host after a foothold | What segmentation stops |
| **Least privilege** | Grant only the minimum access | A Zero Trust principle |
| **Defense in depth** | Stacking independent controls | The layer cake |
| **IDS** | Detect + alert on threats | Monitoring |
| **IPS** | In-line detect + block | Active prevention |
| **DDoS** | Flood to deny service | The attack |
| **Scrubbing** | Filtering flood traffic upstream | DDoS mitigation |
| **Encryption in transit** | TLS/mTLS on every hop | Confidentiality |
| **eBPF security** | Kernel-level runtime detection (Cilium/Falco) | K8s-native IDS/IPS |

**Same-kind-of-thing groupings:** *SG, NACL, NetworkPolicy, WAF, mesh authz* are all "allow-lists at different layers." *IDS, IPS, flow logs, tracing* are all "seeing and responding to threats." *TLS, mTLS* are "encryption in transit" at different scopes.

---

## 🔬 Rung 5 — The Trace

**An attacker compromises one frontend pod and tries to reach the database — follow how defense-in-depth contains them.**

```
[compromised frontend pod]  attempts → payments-db:5432
   │ 1. NetworkPolicy on payments-db: source label app=frontend allowed? NO → DROP ── 28
   ▼  ✗ blocked at L3/L4 (micro-segmentation)

[attacker pivots] tries the payments SERVICE instead → payments:8080
   │ 2. mesh mTLS: does the caller present a valid "payments-client" identity cert? NO
   ▼  ✗ blocked — no cert, STRICT mTLS rejects plaintext ── 29

[attacker tries to exfiltrate] → outbound to evil.example.com:443
   │ 3. default-deny EGRESS policy: destination allowed? NO → DROP ── 28
   ▼  ✗ blocked

[meanwhile] eBPF IDS (Falco/Tetragon) observed:
   • unexpected connection attempts from frontend
   • a process spawning a shell in a web pod
   │ 4. → ALERT fires; (IPS mode) the anomalous connections are killed
   ▼
   SOC gets paged; blast radius = one pod, reached nothing of value.
```

Any single layer might be misconfigured — but *because they're independent*, the attacker is stopped and seen. That containment is the entire payoff of Zero Trust + defense in depth.

> **✅ Check yourself before Rung 6:** In that trace, name two *different* layers that each independently blocked the attacker. Why is having both better than a single perfect firewall?

---

## ⚖️ Rung 6 — The Contrast

**Zero Trust vs the perimeter model.**

| Property | Perimeter (castle-and-moat) | Zero Trust |
|---|---|---|
| Trust basis | Network location ("inside") | Verified identity, every request |
| Internal traffic | Plaintext, trusted | Encrypted (mTLS), authorized |
| After one breach | Attacker roams freely | Contained; must re-auth at each step |
| Segmentation | Coarse (perimeter only) | Fine (per-pod/identity) |
| Fits cloud/remote | ❌ no single perimeter | ✅ identity travels with the workload |

**IDS vs IPS:** an IDS is safe (alert-only, no risk of blocking good traffic) but reactive; an IPS is proactive (blocks in real time) but a false positive can drop legitimate traffic. Many deploy IDS broadly and IPS on well-understood, high-risk paths.

**When would I dial it back?** A tiny internal tool with no sensitive data and no compliance scope doesn't need full mesh mTLS + per-pod policy on day one — but the *principles* (least privilege, no plaintext for anything sensitive) apply everywhere, and retrofitting security is far harder than building it in.

**One-sentence why-this-over-that:** *Adopt Zero Trust (verify every request, encrypt every hop, assume breach) because in the cloud there is no trustworthy "inside," and defense in depth ensures one mistake isn't game over.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: verify encryption in transit is actually on

> **Prediction:** "If a service is behind TLS, connecting with `openssl s_client` shows a valid certificate and a modern protocol; a plaintext connection to the same port fails or is refused, BECAUSE the endpoint requires TLS."

```bash
# Confirm TLS is present and which version/cipher negotiated:
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
# subject=CN = api.example.com
# notBefore=... notAfter=...          <- valid cert, check it isn't expired

# A plaintext HTTP request to a TLS-only port should NOT return app data:
curl -s -m 4 http://api.example.com:443/ | head -1 ; echo "exit=$?"
# (garbage / empty / error)  exit != 0   <- speaking plaintext to a TLS port fails
```

**Verify:** TLS negotiates a valid, unexpired cert; plaintext to the TLS port fails. If plaintext *succeeds*, the service isn't TLS-only — a Zero-Trust gap. (For mesh mTLS, use `istioctl authn tls-check`.)

### Example 2 — Edge/failure case: least privilege stops lateral movement

> **Prediction:** "If I lock a namespace to default-deny and allow only intended flows, a pod cannot reach a service it has no rule for, BECAUSE Zero Trust denies by default and only verified/authorized flows pass."

```bash
# Assume a default-deny + specific allows are applied (see 28). Test lateral movement:
# frontend → api (allowed):
kubectl exec deploy/frontend -- nc -zv -w3 api 8080     ; echo "allowed exit=$?"   # exit=0
# frontend → payments-db (NOT allowed — no rule):
kubectl exec deploy/frontend -- nc -zv -w3 payments-db 5432 ; echo "lateral exit=$?" # exit=1 (blocked)
```

**Verify:** the intended flow works, the un-allowed lateral hop is blocked. If the "lateral" hop succeeds, your default-deny isn't in place or the CNI isn't enforcing ([28](28)) — the exact hole a pentest flags.

### Example 3 — Kubernetes-flavored: runtime IDS catches a suspicious action

> **Prediction:** "If I run a runtime security tool (Falco) and then do something suspicious in a pod (spawn an interactive shell in a container that shouldn't have one), it fires an alert, BECAUSE the IDS watches syscalls/network for known-bad patterns."

```bash
# With Falco (eBPF-based) running as a DaemonSet, trigger a classic detection:
kubectl exec -it deploy/web -c web -- /bin/sh -c 'echo hi'    # "shell in a container"

# Falco logs an alert (a detection, not a block — IDS mode):
kubectl logs -n falco -l app.kubernetes.io/name=falco --since=1m | grep -i 'shell\|Notice\|Warning'
# Warning A shell was spawned in a container (user=root container=web ...)
```

**Verify:** Falco emits an alert for the shell spawn. That's IDS behavior — detect + alert. Configure a response action (kill the pod, page the SOC) to make it IPS-like. The point: you *saw* the intrusion attempt, which is half of Zero Trust.

---

## 🏔 Capstone — Compress It

**One sentence:** Network security in the cloud means Zero Trust — authenticate and authorize every request, encrypt every hop, and assume breach — realized through defense in depth (WAF/DDoS at the edge, SG/NACL at the VPC, NetworkPolicy pod-to-pod, mesh mTLS for identity, RBAC in the app) plus IDS/IPS to detect and stop intruders.

**Explain it to a beginner in 3 sentences:**
1. The old model trusted anything already inside the network, which is fatal once an attacker gets one foothold and can roam freely — so Zero Trust trusts *identity*, not location, and checks every single request.
2. You encrypt all traffic (even internal), grant the least access possible, and segment tightly, so that a single compromised pod can barely reach anything and can't move sideways.
3. On top of that you watch continuously with intrusion detection (alerts) or prevention (blocks), and you absorb floods (DDoS) at the edge before they reach your servers — layering independent defenses so no single failure is game over.

**Sub-parts mapped to the one idea (never trust the network, verify everything):**
```
Zero Trust        → auth/authz every request, trust identity not location
Encryption        → TLS/mTLS every hop (no plaintext inside)
Least privilege    → minimal access; assume breach
Micro-segmentation → NetworkPolicy/SG limit lateral movement
IDS / IPS          → detect (alert) / prevent (block) intrusions
DDoS mitigation    → absorb & filter at the edge
Defense in depth   → independent, stacked layers
```

**Which rung to revisit hands-on:** Rung 5's containment trace and Rung 7 Example 2 — proving a lateral hop is blocked is the tangible heart of Zero Trust.

---

## Related concepts

- [Kubernetes Network Policies](28-kubernetes-network-policies.md) — pod-level micro-segmentation.
- [Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md) — the VPC/node allow-lists.
- [TLS/SSL — Encryption in Transit](11-tls-ssl-encryption-in-transit.md) — encryption on every hop.
- [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) — identity-based mTLS and L7 authorization.
- [CDN, Edge & WAF](21-cdn-edge-waf.md) — where DDoS is absorbed and L7 attacks are filtered.
- [VPN & Zero-Trust Connectivity](19-vpn-and-zero-trust-connectivity.md) — zero-trust access to networks and nodes.
- [Network Observability](32-network-observability.md) — the flow logs and traces that power detection.
