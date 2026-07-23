# Tier-2 · Fractional GPUs & Multi-Tenancy, Explained From Zero 🪜
### Every technical idea in [project-8-gpu-sharing-partitioning-fleet.md](../project-8-gpu-sharing-partitioning-fleet.md) + [project-08-fractional-gpu-dra-multitenancy.md](../project-08-fractional-gpu-dra-multitenancy.md) (build from the first, merge in the second's depth), broken down for a smart adult with **no tech background**.

> **Running analogy for the whole file:** an **apartment building with insanely expensive kitchens**. Many tenants, few kitchens — the whole game is how you split a kitchen among tenants who don't trust each other, and how you bill each one fairly.
>
> **Where this sits in your plan:** Tier-2 #1. Start only once you're interviewing off Tier-1. Needs one short rental of a premium machine (an A100 — the walls-in-hardware feature doesn't exist on any of AWS's cheap GPU types; ~$4–8 for a 2–3 hour session elsewhere).

---

## RUNG 0 — What is this project, in one everyday sentence?

Project 07 decided *which tenant* gets a kitchen; this one decides **how much of a kitchen each tenant gets** — you'll run all five known ways of splitting a GPU among tenants, measure exactly how well each isolates neighbors from each other, and publish a cost-per-tenant report — the difference between a GPU fleet running at 15% versus 70% useful work.

---

## RUNG 1 — The Pain 🔥

A whole flagship GPU for one developer's notebook wastes more than 90% of a chip that costs as much as a car. So every company's internal "GPU cloud" must **share** cards between teams. But sharing raises the landlord's three eternal questions:

1. **Walls:** if tenant A's cooking explodes, does tenant B's dinner burn too?
2. **Portions:** can tenant A hog the fridge until tenant B's food is thrown out?
3. **Billing:** who used how much, and who pays?

The cheap sharing you met in Project 1 (time-slicing) answers *none* of these — it's roommates sharing one kitchen **on pure trust**: no locks, no shelves, one messy roommate ruins everyone. Fine among friends (dev notebooks), reckless for paying tenants.

---

## RUNG 2 — The One Idea 💡

> **There are exactly five ways to split a GPU, and they differ only in WHERE the walls are: no walls (time-slicing), painted lines on the floor (MPS), a strict butler intercepting every grab (HAMi — software-enforced portions on ANY GPU), real brick walls (MIG — hardware partitions, premium chips only) — plus a richer order form (DRA) and a building manager (KAI/Kueue) that decide who gets which portion; the skill is matching each tenant to the cheapest wall that's safe enough.**

The interview-ready compression: **isolation is a spectrum you buy — the harder the wall, the pricier the chip.**

---

## RUNG 3 — The Machinery ⚙️

### The five sharing modes, one table you'll rebuild from your own measurements

```
 MODE          THE ANALOGY                       WALLS?              WORKS ON
 whole GPU     one tenant per kitchen            perfect (alone)     any chip
 time-slicing  roommates on trust, taking turns  NONE — one OOM      any chip
                                                 kills everyone
 MPS           painted floor-lines + labeled     partial — memory    most chips
               fridge shelves; cooking is        caps opt-in; a
               genuinely simultaneous            grease fire still
                                                 spreads
 HAMi          a BUTLER intercepts every         software walls —    ANY chip (the
               ingredient-grab; a tenant over    the offender alone  cheap fleet MIG
               their portion is refused —        gets refused        can't cover!)
               only THEY go hungry
 MIG           actual brick walls: mini-         HARDWARE walls —    premium chips
               kitchens with own stove, fridge,  fault-isolated,     only (A100/H100
               and door                          guaranteed          class)
```

- **Why HAMi is the sleeper hit:** it's a translator library that sits between a program and the GPU and *intercepts* memory requests — enforcing per-tenant portions in software on the cheap chips that lack brick walls. (A CNCF-incubating open-source project; real fleets run it.)
- **Why MIG needs premium chips:** the walls are etched into the silicon — compute units, memory, and cache physically partitioned into up to 7 mini-GPUs. Cheap cards simply don't have the circuitry.
- **The order form upgrade (DRA):** today a task just says "1 GPU" — an opaque count. DRA (now standard in new Kubernetes) lets it say *"any GPU with at least 40GB memory"* like a proper requisition form, and the platform matches it to a real device. You'll demo it because almost no candidate can.
- **The building managers:** **KAI** (NVIDIA's open-sourced scheduler) understands *fractions* — a task can ask for `0.5` GPU — but its fractions are bookkeeping only, so it's paired with HAMi's butler for actual enforcement. **Kueue** (from Project 07) sits above as team budgets: quotas, borrowing idle share, taking it back.
- **The bill:** the Project 1 gauges (DCGM) feed a per-team GPU-hours report — the chargeback that makes internal customers believe the platform.

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| multi-tenancy | many teams safely sharing one platform |
| fractional GPU | giving a tenant part of a card instead of the whole |
| time-slicing | turn-taking with no walls (trust-based roommates) |
| MPS | simultaneous cooking with painted lines + optional fridge-shelf caps |
| HAMi / vGPU | the butler: software-enforced memory/compute portions on any chip |
| `libvgpu.so` | the butler himself — the interception layer |
| MIG | brick walls: hardware mini-GPUs inside one premium card |
| MIG profile | the floor plan chosen (e.g. split into 7 small or 2 big mini-kitchens) |
| isolation / blast radius | whose dinner burns when one tenant's cooking explodes |
| DRA / ResourceClaim / DeviceClass | the proper requisition form replacing the bare count |
| KAI Scheduler | NVIDIA's fraction-aware building manager (pairs with the butler) |
| Kueue quota / cohort / borrowing | team budgets / shared pool / lending idle budget with take-back |
| chargeback | the itemized per-team bill from the usage gauges |
| A100 rental | the one short premium-machine session you need — cheap AWS GPU types have no MIG |

---

## RUNG 5 — The Trace 🎬 (one noisy tenant, five different mornings)

Tenant B runs a memory-hungry job next to tenant A. Same event, five outcomes:

1. **Time-slicing morning:** B over-allocates → the whole card OOMs → **A's job dies too.** You'll cause this on purpose and screenshot the double-obituary — the "why trust isn't a policy" artifact.
2. **MPS morning:** the two genuinely cook simultaneously (throughput up 1.5–3× for small jobs — measure it), B is capped *if* the cap was set — but a hard crash in B can still take A down. Better, not safe.
3. **HAMi morning:** B hits its portion → the butler refuses → **B alone** gets the out-of-memory error; A never notices. On the SAME cheap chip that had no walls. That contrast is the project's core demo.
4. **MIG morning (the A100 session):** B's mini-kitchen faults; A's mini-kitchen — own stove, own fridge — doesn't even flicker. Hardware guarantee, premium price.
5. **The manager's view:** through it all, KAI placed the fractions, Kueue enforced each team's budget (B's team borrowed idle share yesterday; it got reclaimed today), and the month-end chargeback shows each team exactly what their habits cost.

---

## RUNG 6 — The Contrast ⚖️ (the decision your report ends with)

- **Friendly dev notebooks** → time-slicing (free, walls unnecessary among friends).
- **Many small trusted inference jobs** → MPS (real simultaneity, measured speedup).
- **Paying/untrusting tenants on the CHEAP fleet** → HAMi (the only enforced walls those chips can have).
- **Paying/untrusting tenants with guarantees** → MIG (and you pay for premium silicon).
- **When NOT to share at all:** big training/serving that genuinely fills a card — sharing just adds overhead.

Almost nobody walks into interviews with *measured* per-mode latency, throughput, and blast-radius data. You will.

---

## RUNG 7 — Predict, then check 🧪

**P1.** Under time-slicing, tenant B allocates past the card's memory. What happens to tenant A, and what nameplate does this failure wear?
<details><summary>Answer</summary>A dies with B — the card OOMs as a whole; there are no walls. The nameplate: "no memory or fault isolation between replicas" (NVIDIA's own wording). You'll reproduce it deliberately.</details>

**P2.** Same scenario under HAMi. Who gets the error, and why can this work on a cheap T4 chip?
<details><summary>Answer</summary>Only B — the butler intercepts the over-portion grab and refuses it in software. Because enforcement is interception (not silicon), ANY NVIDIA chip works — exactly the fleet MIG can't cover.</details>

**P3.** A teammate proposes "let's just use MIG on our cheap fleet." What's wrong?
<details><summary>Answer</summary>MIG's walls are etched into premium silicon (A100/H100 class); the cheap AWS GPU types physically lack it. That's why this project rents one A100 for 2–3 hours — and why HAMi exists for everything else.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** splitting a GPU among tenants is a walls-for-money spectrum — trust (time-slicing), painted lines (MPS), a software butler (HAMi, on any chip), or brick walls (MIG, premium chips only) — with a richer order form (DRA) and fraction-aware managers (KAI + Kueue budgets) deciding who gets what, and a chargeback report proving who used it; the skill is buying each tenant the cheapest wall that's safe enough.

**Now do it for real:** build from [project-8-gpu-sharing-partitioning-fleet.md](../project-8-gpu-sharing-partitioning-fleet.md), merging in the DRA/HAMi/KAI depth from [project-08-fractional-gpu-dra-multitenancy.md](../project-08-fractional-gpu-dra-multitenancy.md): run time-slicing & MPS on the cheap pools → deploy the butler and prove the lone-OOM → rent the A100 for the MIG session → wire KAI + Kueue budgets → publish the five-mode measurement table and the per-team bill.
