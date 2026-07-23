# Tier-2 · The AI Platform Control Plane, Explained From Zero 🪜
### Every technical idea in [project-6-ai-platform-control-plane.md](../project-6-ai-platform-control-plane.md), broken down for a smart adult with **no tech background**.

> **Running analogy for the whole file:** a **serviced apartment building for AI teams**. Until now you've been cooking meals to order; this project makes you the **builder of the building itself** — order forms, robot butler, house rules, reception desk, itemized bills, and fire drills.
>
> **Where this sits in your plan:** Tier-2 #3 — the capstone that proves you can *build* a platform, not just use one. It maps almost line-for-line to the "AI Control Plane Engineer" job description. Best part: the brain of it develops **for free** on your laptop (no GPUs needed until the final demo).

---

## RUNG 0 — What is this project, in one everyday sentence?

You'll build the thing internal AI-platform teams actually ship: tenants fill in **one simple order form** ("I want this model, this size, this many copies, this rate limit") and your software **automatically builds and maintains their entire serving setup** — with walls between tenants, house rules enforced at the door, a reception desk checking membership and limits, an itemized bill per tenant, and alarms based on promises rather than vibes.

---

## RUNG 1 — The Pain 🔥

Without a control plane, "the AI platform" is a senior engineer with a pile of scripts:

- Every team that wants a model served files a ticket; a human hand-assembles ~6 pieces (the server, networking, monitoring, autoscaling, routing…) — slow, inconsistent, and it doesn't scale past a few teams.
- **No walls:** team A's runaway job can eat team B's GPUs; nothing stops a team deploying something insecure or oversized.
- **No door:** anyone with cluster access can hit anyone's model; there's no per-team identity, no rate limits.
- **No bill:** at month's end nobody can say which team spent which GPU-dollars — so nobody economizes.
- **No promises:** "is the platform healthy?" is answered by staring at dashboards, not by defined service promises with alarms that fire when you're burning through your error allowance.

Every serious AI company solved this the same way: **give tenants a single declarative order form, and put a robot behind it.**

---

## RUNG 2 — The One Idea 💡

> **A platform is an order form plus a tireless robot: you INVENT a new Kubernetes document type (a CRD — your own "ModelDeployment" form), write an operator (a control loop that watches those forms and endlessly makes reality match them — creating, updating, and healing all ~6 underlying pieces), then wrap it with tenant walls (quotas, network fences, admission rules), a reception desk (API keys + rate limits), an itemized bill (cost attribution), and promise-based alarms — desired state in, running platform out.**

The deep idea worth savoring: Kubernetes is *extensible* — you can teach it **new nouns**. "ModelDeployment" becomes as real to the cluster as "Pod," and your robot gives the noun its meaning. That loop — *watch, compare, fix, forever* — is the same reconcile pattern behind every operator you've ever used (GPU Operator, ExternalDNS, Argo CD). Now you're on the author side.

---

## RUNG 3 — The Machinery ⚙️

### (A) The order form (CRD) and the robot (operator)

```
 tenant writes ONE document:            your robot (the operator) reconciles it into:
   kind: ModelDeployment                  · the vLLM serving deployment (Project 2)
   model: Qwen-1.5B                       · its network address (Service)
   replicas: 1 to 2                       · its dashboard wiring (monitoring)
   gpu: 1, sharing: timeslice             · its autoscaler (KEDA rules)
   rateLimit: 120/min                     · its route at the reception desk
                                          · …and a status report written back
 loop forever: WATCH the form → COMPARE reality → CREATE/FIX the difference
 delete a piece by hand? the robot re-creates it. change the form? reality follows.
```

You'll write the robot in Python (with a framework called kopf), with a Go appendix — the JD asks for both languages by name.

### (B) The tenant walls

- **Namespaces** — each tenant's own floor of the building.
- **ResourceQuota** — a hard budget per floor ("this tenant: max 1 GPU").
- **NetworkPolicy** — corridors sealed so tenants can't wander into each other's rooms; only the reception desk may enter.
- **Kyverno (admission policies)** — the doorman who rejects rule-breaking documents *at the door*: no un-approved images, no missing labels, no oversized requests. Rules-as-code, enforced before anything runs.

### (C) The reception desk (gateway)

One front door for all tenants: each API key maps to a tenant; each tenant gets their own path and a **rate limit** (120 requests/minute on the form above). Over-limit requests get the polite "429 slow down" — per tenant, not global.

### (D) The bill and the promises

- **OpenCost** meters resource-hours per namespace → your script turns that into a **monthly GPU bill per tenant**. Chargeback turns "the platform is expensive" into "YOUR team spent $X."
- **SLOs with burn-rate alerts:** you publish promises ("99% of requests under N seconds") and alarms fire on how fast you're *burning the error allowance* — a fast burn pages you now; a slow leak files a ticket. Plus the operational adulthood package: runbooks, a disaster-recovery plan, a chaos drill (kill a GPU node during the demo, watch the platform heal), and a postmortem template.

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| control plane | the brain layer that accepts orders and makes reality match them |
| CRD | your custom document type — teaching Kubernetes a new noun |
| ModelDeployment | the noun you invent: one tenant order form for a served model |
| operator / reconcile loop | the robot: watch forms, compare reality, fix differences, forever |
| kopf / Kubebuilder | Python / Go frameworks for writing that robot |
| desired vs actual state | what the form says vs what's really running — the gap the robot closes |
| status subresource | the robot's progress report written back onto the form |
| namespace / ResourceQuota | a tenant's floor / its hard resource budget |
| NetworkPolicy | sealed corridors between floors |
| Kyverno | the doorman enforcing written house rules at admission time |
| gateway (Envoy/NGINX) | the reception desk: one front door, keys, routes, rate limits |
| API key → tenant mapping | the membership card that identifies which tenant is calling |
| rate limiting / 429 | "no more than N requests per minute" / the polite refusal |
| OpenCost | the meter that attributes cluster cost per tenant |
| chargeback | the itemized monthly bill per team |
| SLO / error budget / burn rate | the promise / the allowed failure amount / how fast you're spending it |
| runbook / DR plan / postmortem | the emergency cookbook / the disaster plan / the blameless write-up |
| chaos test | breaking something on purpose to prove the healing works |

---

## RUNG 5 — The Trace 🎬 (one tenant's model, birth to bill)

1. Tenant A applies a 10-line ModelDeployment form for "support-bot."
2. The doorman (Kyverno) checks it against house rules — image allowed, size sane → admitted. (A rule-breaking form would be rejected with a reason before anything ran.)
3. Your robot notices the new form within seconds and builds all six pieces on tenant A's floor; the floor's quota debits 1 GPU; the corridors stay sealed except to reception.
4. The robot writes back: `status: Ready, endpoint: /tenant-a/support-bot`.
5. Tenant A calls the front desk with their API key → routed to their model → answer streams back. Request 121 within a minute → "429, slow down." Tenant B's key on tenant A's path → refused.
6. **The chaos drill:** you kill the GPU node mid-demo. The robot + the platform (Karpenter, health checks) heal it; the burn-rate alarm briefly wakes and calms; the runbook narrates what would page whom.
7. Tenant A hand-deletes their deployment "to save money" → the robot **re-creates it** (the form still says it should exist). To truly remove it, delete the *form* — the robot then cleans up all six pieces.
8. Month's end: the bill lands — tenant A: $41.20 of GPU-hours; tenant B: $12.75. Nobody argues with the meter.

---

## RUNG 6 — The Contrast ⚖️

- **Tickets-and-scripts vs a control plane:** a human with Helm charts is a queue with a single point of burnout; an operator is consistency at machine speed with self-healing built in.
- **Your operator vs the ones you've used:** the GPU Operator, ExternalDNS, Argo CD — all the SAME loop you're now writing. Using operators is Tier-0; *authoring* one is the JD's actual ask.
- **When NOT to build one:** one team, two models — a Helm chart is fine. The control plane earns its keep at many-tenants scale, which is exactly the interviewer's world.

---

## RUNG 7 — Predict, then check 🧪

**P1.** A tenant hand-deletes the deployment your robot created (the form remains). What happens within seconds, and why?
<details><summary>Answer</summary>The robot re-creates it — reality diverged from the form, and closing that gap is its only job. This "fighting the robot" moment is the demo that makes operators click for everyone.</details>

**P2.** A tenant's form asks for 3 GPUs; their floor's quota is 1. Where exactly does this fail, and what does the tenant see?
<details><summary>Answer</summary>At admission/quota — either the doorman rejects the form outright or the created pods refuse to schedule past quota, with the reason written into status. Walls hold BEFORE money is spent, and the error is self-explanatory.</details>

**P3.** Tenant B fires 500 requests/minute at a 120/min limit. What do they get, and what does tenant A notice?
<details><summary>Answer</summary>B gets fast "429" refusals beyond 120; A notices nothing — limits are per-tenant at the reception desk, so one tenant's flood can't consume another's service. That isolation IS the multi-tenancy promise.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** I taught Kubernetes a new noun — a one-page ModelDeployment order form — and wrote the robot that endlessly makes reality match it, then wrapped tenants in real walls (quotas, sealed networks, a rule-enforcing doorman), put one reception desk with keys and rate limits in front, attached an itemized GPU bill per tenant, and defended it all with promise-based alarms, runbooks, and a live chaos drill.

**Now do it for real:** open [project-6-ai-platform-control-plane.md](../project-6-ai-platform-control-plane.md). Its phases: design the CRD → write the kopf robot on your free laptop cluster → add walls & doorman → the reception desk → OpenCost billing → SLO alarms → the chaos-drill demo day.
