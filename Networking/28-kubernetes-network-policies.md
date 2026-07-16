# Kubernetes Network Policies

*By default every pod can talk to every other pod. NetworkPolicy is how you lock the doors — a pod-level firewall written in labels.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Kubernetes **NetworkPolicy** — the pod-level firewall that controls which pods may talk to which, using label selectors for ingress and egress, and the CNI enforcement behind it.

**Why did it land on my desk?** Security asked: "can the frontend pod reach the database directly? Can a compromised pod in `dev` reach `prod`?" On a fresh cluster the answer is **yes to everything** — the pod network is flat and wide open ([24-kubernetes-pod-networking-cni.md](24-kubernetes-pod-networking-cni.md)). NetworkPolicy is how you impose "only the API pods may reach the database, and only on 5432." Every micro-segmentation and PCI/zero-trust requirement runs through this object.

**What do I already know?** You understand firewalls, stateful vs stateless, and default-deny ([17-firewalls-security-groups-nacls.md](17-firewalls-security-groups-nacls.md)); the flat pod network ([24](24)); and that CNIs like Calico/Cilium enforce policy ([24](24)). NetworkPolicy is a firewall expressed in Kubernetes labels.

---

## 🔥 Rung 1 — The Pain

The Kubernetes network model guarantees **every pod can reach every other pod** — that flatness is a feature for connectivity but a liability for security:

- **No blast-radius control.** One compromised pod (a leaky web frontend, a poisoned dependency) can reach *everything* — the database, internal admin services, other teams' namespaces. This is **lateral movement**, and a flat network is a superhighway for it.
- **No least privilege.** Your payments service can be reached by any pod in the cluster, not just the few that should. Compliance (PCI, SOC2) demands you *prove* only authorized flows exist.
- **Security Groups don't help here.** AWS SGs guard nodes/ENIs, not the pod-to-pod traffic that never leaves a node or rides the CNI overlay. You need a control that understands *pods*.

Before NetworkPolicy, "which pods can talk to which" was unanswerable and unenforceable inside the cluster.

**Who feels it most?** Security teams (who must prove segmentation) and platform teams (who own the "assume breach" posture).

> **✅ Check yourself before Rung 2:** On a default cluster, why can a compromised frontend pod reach the database pod even though no one "connected" them — and why is that dangerous?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **A NetworkPolicy is a pod-level allow-list firewall: it selects pods by label and declares which sources may send to them (ingress) and which destinations they may reach (egress) — and the moment any policy selects a pod, everything not explicitly allowed is denied.**

Everything derives from "label-selected allow-list, deny-by-selection":

- *Selects pods by label* → policies target pods (`podSelector`) and namespaces (`namespaceSelector`), not IPs — perfect for churning pods.
- *Allow-list* → you can only *allow*; there is no "deny" rule. You allow the flows you want; the rest is implicitly denied.
- *Deny-by-selection* → a pod with **no** policy is wide open; a pod selected by **any** policy denies everything not allowed. This is how you build **default-deny**.

> **✅ Check yourself before Rung 3:** NetworkPolicy has no "deny" rule — only "allow." So how do you *block* traffic to a pod?

---

## ⚙️ Rung 3 — The Machinery

### The default-deny switch

The key mechanism is subtle: **selection flips the default.**

- A pod that **no** NetworkPolicy selects → **allow all** (the cluster default).
- A pod that **any** NetworkPolicy selects (for a direction) → **deny all in that direction except what a policy allows.**

So you create **default-deny** by applying a policy that selects all pods but allows nothing:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all, namespace: prod }
spec:
  podSelector: {}          # {} = select EVERY pod in the namespace
  policyTypes: [Ingress, Egress]   # deny both directions...
  # ...with NO ingress/egress rules = allow nothing
```

Then you layer **allow** policies on top. Policies are **additive**: the union of all matching allow-rules is permitted.

```
   pod selected by ≥1 policy →  DENY everything, then ALLOW the union of rules
   pod selected by NO policy →  ALLOW everything (cluster default)

   ┌──────────────────────── namespace: prod ─────────────────────────┐
   │  [default-deny-all] selects ALL pods → baseline: nothing allowed  │
   │                                                                   │
   │  [allow-api→db]  ┌── db pods (app=db) ──┐   ingress from:         │
   │   ────────────▶  │  allow app=api : 5432 │ ◀── only app=api pods   │
   │  frontend (app=web) ── ✗ blocked ──────▶ │      on TCP 5432        │
   │                  └───────────────────────┘                        │
   └───────────────────────────────────────────────────────────────────┘
```

### Selectors and rules

A rule's peers can be:

- **`podSelector`** — pods matching labels (in the same namespace by default).
- **`namespaceSelector`** — whole namespaces (e.g. allow from any pod in `namespace: monitoring`).
- **`ipBlock`** — CIDR ranges (for external IPs, e.g. allow egress to `0.0.0.0/0` except a block).
- **`ports`** — restrict to specific ports/protocols (TCP 5432).

NetworkPolicy is **L3/L4 only** — it matches IPs, ports, and protocols. It cannot match HTTP paths, methods, or verify cryptographic identity — that's a **service mesh's** job ([29-service-mesh-and-sidecars.md](29-service-mesh-and-sidecars.md)).

### Who actually enforces it

Here's the catch that bites people: **the API accepts NetworkPolicy objects, but only a CNI that supports enforcement makes them real.** Calico and Cilium enforce (via iptables/ipset or eBPF); **plain Flannel does not** — apply a policy on a Flannel-only cluster and it's silently ignored. NetworkPolicy is the *spec*; the CNI is the *firewall*. On EKS, the AWS VPC-CNI added policy enforcement, or you run Calico/Cilium alongside it.

> **✅ Check yourself before Rung 4:** Why can applying a perfectly valid NetworkPolicy have *zero* effect on some clusters — and what determines whether it's actually enforced?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **NetworkPolicy** | A pod-level allow-list firewall object | The rule |
| **podSelector** | Labels choosing which pods a rule targets/allows | Selection |
| **namespaceSelector** | Choose peer namespaces | Cross-namespace rules |
| **ipBlock** | A CIDR peer (external IPs) | External allow/deny |
| **policyTypes** | Ingress / Egress this policy governs | Direction |
| **default-deny** | A policy selecting all pods, allowing nothing | The baseline |
| **additive** | Multiple policies union their allows | Combination rule |
| **enforcing CNI** | Calico/Cilium (not plain Flannel) | What makes policy real |
| **micro-segmentation** | Fine-grained pod-to-pod control | The goal |
| **lateral movement** | An attacker hopping pod-to-pod | What policy prevents |

**Same-kind-of-thing groupings:** *podSelector, namespaceSelector, ipBlock* are all "ways to name a peer." *NetworkPolicy ≈ a Security Group for pods* (both allow-lists), but NetworkPolicy selects by label not IP and lives inside the cluster. *default-deny + allow policies* together are "how you build a whitelist."

---

## 🔬 Rung 5 — The Trace

**A `prod` namespace with default-deny; a policy allows only `app=api` → `app=db` on TCP 5432. A web pod and an api pod each try to reach the db.**

```
── db pod (app=db) is now selected by policies → DENY-by-default for ingress ──

[web pod, app=web]  → db:5432
   │ 1. packet reaches db's node; CNI (Calico/Cilium) checks ingress policy for db
   │ 2. is source label app=api?  NO (it's app=web)
   │ 3. any allow rule match?     NO
   ▼
   ✗ DROPPED  (connection times out — no RST, just silence)

[api pod, app=api]  → db:5432
   │ 4. CNI checks ingress policy for db
   │ 5. source label app=api?  YES   port 5432/TCP?  YES
   ▼
   ✓ ALLOWED → delivered to db pod
```

The enforcement happens **at the CNI datapath** (iptables/ipset for Calico, eBPF for Cilium) on the destination node, keyed off the *real* pod source IP — which is why the model's "no NAT, source preserved" guarantee ([24](24)) is essential: policy can't work if it can't trust the source identity.

> **✅ Check yourself before Rung 6:** The blocked web pod's connection *times out* rather than getting an immediate "refused." Why does a dropped-by-policy packet behave that way, and how does that differ from "no pod is listening"?

---

## ⚖️ Rung 6 — The Contrast

**The alternatives: AWS Security Groups (node-level), or a service mesh (L7 identity).**

| Control | Operates on | Layer | Selects by | Scope |
|---|---|---|---|---|
| **AWS Security Group** | Nodes/ENIs | L3/L4 | IP/SG/port | Around the cluster |
| **NetworkPolicy** | Pods | L3/L4 | **labels/namespace** | Inside the cluster |
| **Service mesh (mTLS + authz)** | Service identities | **L7** | crypto identity, HTTP verb/path | Inside the cluster |

- **vs Security Groups:** SGs guard the VPC boundary and node ENIs but are blind to pod-to-pod traffic on the CNI. NetworkPolicy is pod-aware and label-based. Use **both** (defense in depth).
- **vs service mesh:** NetworkPolicy is L3/L4 — "app=api may reach db:5432." A mesh adds L7 — "only GET /orders from a cryptographically-verified `api` identity." Meshes also *encrypt* (mTLS); NetworkPolicy only *filters*. They're layers, not rivals.

**When would I NOT (yet) use NetworkPolicy?** On a single-tenant dev cluster where everything trusts everything and there's no compliance need — the flat default is fine. But for any multi-tenant or production cluster, default-deny + explicit allows is the baseline.

**One-sentence why-this-over-that:** *Use NetworkPolicy for label-based L3/L4 pod segmentation inside the cluster; add a service mesh when you need L7 rules and encryption, and keep Security Groups for the node/VPC boundary.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: allow only api→db, block everyone else

> **Prediction:** "If I default-deny the namespace and allow only `app=api → app=db:5432`, then an api pod reaches the db but a web pod cannot, BECAUSE selection flipped db to deny-by-default and only the api rule permits ingress."

```yaml
# 1) default-deny all ingress in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress }
spec: { podSelector: {}, policyTypes: [Ingress] }
---
# 2) allow api → db on 5432
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-api-to-db }
spec:
  podSelector: { matchLabels: { app: db } }
  policyTypes: [Ingress]
  ingress:
  - from: [{ podSelector: { matchLabels: { app: api } } }]
    ports: [{ protocol: TCP, port: 5432 }]
```

```bash
kubectl apply -f policies.yaml
# api pod → db  : allowed
kubectl exec deploy/api -- nc -zv -w3 db 5432   ; echo "api exit=$?"   # exit=0 (open)
# web pod → db  : blocked (times out)
kubectl exec deploy/web -- nc -zv -w3 db 5432   ; echo "web exit=$?"   # exit=1 (timeout)
```

**Verify:** api connects (exit 0), web times out (nonzero). If web *also* connects, your CNI isn't enforcing policy (see Example 3) — the policy is valid but ignored.

### Example 2 — Edge/failure case: forgetting egress lets a "blocked" pod still exfiltrate

> **Prediction:** "If I only write *ingress* policies, a compromised pod can still make *outbound* connections anywhere, BECAUSE ingress and egress are governed separately — blocking one direction doesn't touch the other."

```bash
# With only default-deny-INGRESS applied, egress is still wide open:
kubectl exec deploy/web -- sh -c 'wget -qO- --timeout=4 https://example.com | head -1'
# <!doctype html>          <- the pod can still reach the internet / other services!

# Lock egress too (default-deny egress, then allow only DNS + intended destinations):
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-egress }
spec: { podSelector: {}, policyTypes: [Egress] }
EOF
kubectl exec deploy/web -- sh -c 'wget -qO- --timeout=4 https://example.com | head -1; echo exit=$?'
# exit=1                   <- now outbound is denied (you'd re-allow DNS + needed egress)
```

**Verify:** ingress-only policy leaves egress open (exfiltration path!); adding default-deny-egress closes it. Real zero-trust needs *both* directions — a classic gap in first-attempt policies. (Remember to allow egress to CoreDNS on UDP/TCP 53, or name resolution breaks.)

### Example 3 — Kubernetes-flavored: prove your CNI actually enforces policy

> **Prediction:** "If my CNI doesn't support NetworkPolicy, applying a default-deny changes nothing, BECAUSE the API stores the object but no datapath enforces it."

```bash
# Which CNI is running? (enforcement depends on it)
kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|flannel|aws-node'
# aws-node-...   (VPC-CNI)   |  calico-node-...  |  cilium-...

# Apply a deny-all and TEST — does traffic actually stop?
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-all }
spec: { podSelector: {}, policyTypes: [Ingress] }
EOF
kubectl run probe --rm -it --image=busybox:1.36 --restart=Never -- \
  nc -zv -w3 <some-service> 80 ; echo "exit=$?"
# exit=1 (blocked)  → CNI enforces.   exit=0 (still open) → CNI is NOT enforcing (e.g. plain Flannel)
```

**Verify:** with an enforcing CNI (Calico/Cilium, or VPC-CNI with policy enabled) the probe is blocked; with plain Flannel it still connects, proving the policy is inert. This is the "my NetworkPolicy does nothing" root cause.

---

## 🏔 Capstone — Compress It

**One sentence:** A NetworkPolicy is a label-based, allow-list, pod-level firewall for ingress and egress — where selecting a pod flips it to deny-by-default and you layer explicit allows on top — enforced at L3/L4 by a policy-capable CNI (Calico/Cilium, not plain Flannel).

**Explain it to a beginner in 3 sentences:**
1. By default every pod can reach every other pod, which is convenient but means one hacked pod can reach everything, so NetworkPolicy lets you say which pods may talk to which.
2. You write rules that *allow* traffic (by pod label, namespace, or IP range and port); there's no "deny" rule — instead, once any policy selects a pod, everything you didn't allow is automatically blocked.
3. It only works if your cluster's networking plugin (CNI) actually enforces policies, and it filters by IP/port (L3/L4) — for HTTP-level rules or encryption you add a service mesh.

**Sub-parts mapped to the one idea (label-selected allow-list, deny-by-selection):**
```
podSelector {}          → default-deny baseline (select all, allow nothing)
allow policies          → additive whitelist (union of allows)
podSelector/nsSelector  → name the allowed peers by label
ipBlock                 → allow/deny external CIDRs
Ingress vs Egress       → govern each direction separately
enforcing CNI           → what turns the object into a real firewall
L3/L4 only              → mesh for L7 + encryption
```

**Which rung to revisit hands-on:** Rung 7 Example 3 — always *test* that traffic actually stops; a policy that's silently ignored is worse than no policy because it gives false confidence.

---

## Related concepts

- [Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md) — the node/VPC-level allow-lists NetworkPolicy complements.
- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — the flat network and the CNI that enforces policy.
- [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) — L7 identity/authz and mTLS beyond L3/L4 filtering.
- [Network Security — Zero Trust, IDS/IPS & DDoS](30-network-security-zero-trust-ids-ips.md) — where micro-segmentation fits in defense-in-depth.
- [Kubernetes DNS & Service Discovery](26-kubernetes-dns-service-discovery.md) — why egress policies must allow DNS.
