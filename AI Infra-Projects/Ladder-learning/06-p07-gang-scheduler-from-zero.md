# Project 07 — The Gang Scheduler, Explained From Zero 🪜
### Every technical idea in [project-07-topology-aware-gang-scheduler.md](../project-07-topology-aware-gang-scheduler.md), broken down for a smart adult with **no tech background** — read this first, then do the project hands-on.

> **Running analogy for the whole file:** a **restaurant host seating parties**. AI training jobs are parties of 8, 16, or 64 who must ALL sit down together — ideally in the same room — or the dinner cannot start at all.
>
> **Where this sits in your plan:** Tier-1 project #3, and your **single most differentiating artifact** — the only one that answers the "Golang + scheduler internals" job requirement. It runs on *simulated* machines (a tool that fakes 1,000 computers on a laptop), so it costs ~$0 and doesn't even need Project 1 finished.

---

## RUNG 0 — What is this project, in one everyday sentence?

Kubernetes has a built-in "host" that seats one task at a time; you'll first **operate** the two industry-standard replacement hosts (Kueue and Volcano) through real failure scenarios, and then **write your own host** — in the Go programming language — that seats whole parties together, in the same room, or not at all.

**A key personal note:** Go is new to you. That's exactly why this ladder exists — once the *concepts* are solid, the Go code becomes translation, not discovery. The project budgets a 2–3 week Go on-ramp; take it.

---

## RUNG 1 — The Pain 🔥

The standard Kubernetes host seats **one guest at a time**, greedily, with no concept of "these 16 guests are one party" and no idea that two tables in the same room let guests talk easily while tables in different buildings force them to shout.

AI training is a party: 16 workers who **all** compute together and sync up **constantly** — every single step. One-at-a-time seating produces five real disasters:

1. **Deadlock.** Two parties of 4 arrive; the room has 6 seats. The host seats 3 of each. Both parties sit half-seated **forever** — neither can start, neither will leave, and 6 expensive seats are occupied doing nothing. (With GPUs at $2+/hour each, this is money burning nightly.)
2. **Starvation.** A stream of couples keeps getting seated ahead of the big party of 8, which waits unboundedly.
3. **Hoarding.** Team A's reserved-but-empty tables can't be lent to team B without rules for taking them back.
4. **Fragmentation.** Eight rooms each have 1 free seat = 8 free seats that cannot seat one party of 8. Silently, 20–30% of the fleet is wasted this way.
5. **Wrong room.** The host scatters a party across three buildings; every "conversation" (the workers' constant sync-ups) now happens by shouting across courtyards — 2–5× slower, on every step, forever.

Before Kubernetes, the science-computing world had a party-native host (a system called Slurm) — but it's a separate world with none of Kubernetes' ecosystem. The industry's whole current motion is *teaching Kubernetes to do Slurm's tricks*.

---

## RUNG 2 — The One Idea 💡

> **The Kubernetes host is actually an assembly line with well-defined stations that anyone can add steps to — so to seat parties, you add a step at the "final confirmation" station that HOLDS each guest's reserved seat until the whole party has reservations, then confirms them all at once (or, on a timeout, releases every hold so no seat is ever hostage) — and since you're already ranking tables anyway, you add points for tables in the same room as the party's other reservations.**

The three load-bearing phrases:
- **"assembly line with stations"** — you don't rewrite the host; you plug your steps into official extension points, and ship the result as a *second host* that parties explicitly request.
- **"hold until whole party, or release all"** — this makes half-seated parties *structurally impossible*. All N sit, or zero sit and nothing is held.
- **"points for the same room"** — the room preference is a *soft* score, not a hard rule, so it degrades gracefully when the ideal room is full.

---

## RUNG 3 — The Machinery ⚙️

### (A) The assembly line (the stations a guest passes through)

```
 waiting line → SORT        who's next? (yours: keep party members adjacent in line)
              → SANITY      "could this party POSSIBLY fit anywhere?" — if the whole
                            fleet lacks enough free seats, reject NOW, before any
                            half-seating can even begin
              → FEASIBLE    which tables could take this guest at all?
              → RANK        score the tables 0–100 (yours: +60 same-room-as-party,
                            +40 prefer-fuller-tables to fight fragmentation)
              → RESERVE     pencil the guest onto a table (tentative, in the host's
                            notebook — reversible)
              → CONFIRM ✋   THE PARTY GATE: wait here until all N are penciled in;
                            last one arrives → confirm everyone simultaneously;
                            120-second timeout → erase ALL pencil marks
              → SEAT        write it in ink — the guest actually sits
```

### (B) The gate in motion (party of 4, only 3 fit)

Guests 1–3 pencil in and wait at the gate (1/4… 2/4… 3/4). Guest 4 finds no feasible table → the timeout fires → all three pencil marks are erased → **zero seats held** → the next party in line proceeds instantly. The invariant: **all-or-nothing, by construction.**

### (C) The two schools (both are on your resume)

- **Kueue — check at the door:** a bouncer *in front of* the untouched standard host. Parties wait outside (fully suspended, zero guests inside) until the bouncer confirms the whole party fits within the team's quota. Adds team budgets, borrowing idle quota, and taking it back. You'll **operate** this through five failure scenarios.
- **Volcano / yours — check at the table:** a true second host that gates the actual seating. Volcano is the incumbent; **TopoGang (yours)** adds the same-room scoring. You'll **build** this.
- Operating the first and building the second are *different resume verbs* — the project makes you do both.

### (D) Why this costs ~$0

The host never touches real hardware — it reads the fleet's **inventory sheets**. So you can fake the sheets: a tool called **kwok** simulates 1,000 8-GPU machines (with fake room labels) on your laptop. Scale-testing a scheduler is free *by design*.

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| kube-scheduler | the built-in one-at-a-time host |
| Scheduling Framework / extension points | the assembly line + the official places to plug in your own steps |
| plugin | one of your steps, plugged into a station |
| second scheduler / `schedulerName` | your alternative host; a task opts in by naming it |
| gang / co-scheduling | all-or-nothing seating of a whole party |
| PodGroup / `minMember` / `gang-size` | the party's name tag and headcount (three tools, same knob) |
| PreFilter | the "could this even fit anywhere?" sanity check |
| Score | the 0–100 table-ranking step |
| Reserve / Unreserve | pencil in / erase the pencil mark |
| Permit / "Waiting" | the confirmation gate / a guest holding at it |
| bind | writing the seating in ink |
| Kueue / ClusterQueue / cohort / borrowing | the door bouncer / a team's budget / a shared pool / lending idle budget |
| preemption | evicting a lower-priority party to seat a higher one (the starvation fix) |
| Volcano / DRF | the incumbent replacement host / its fairness math |
| topology / network domain | which machines share a "room" (same network switch = fast talk) |
| fragmentation | free seats scattered so no whole party fits |
| bin-packing | preferring fuller tables so big contiguous space survives |
| kwok / kind | fake-fleet simulator / a mini-Kubernetes on your laptop |
| Go / Golang | the programming language Kubernetes itself is written in |
| DRA | the newer, richer way tasks describe what device they need (vs a bare count) — you'll demo it because almost no candidate can |

---

## RUNG 5 — The Trace 🎬 (one party of 4 through YOUR host)

1. Four tasks arrive wearing the badge "party: job-a, size 4, host: topogang." The standard host never sees them.
2. **Sort** keeps the four adjacent in line — no strangers interleaved.
3. **Sanity:** fleet-wide free seats ≥ 4? Yes → continue. (No → rejected instantly; nothing held.)
4. Guest 1 is ranked toward the fullest table in some room, pencils in, and waits at the gate (1/4, clock ticking).
5. Guests 2–4: now the +60 same-room points bite — they're all steered into guest 1's room. Pencil, pencil, pencil… 4/4!
6. **The release:** the gate confirms all four simultaneously; the party sits together in one room; their constant sync-chatter now happens at same-room speed.
7. **Counterfactual:** had guest 4 found no table, the timeout would have erased all three holds, and the party of 2 behind them would have been seated immediately. No deadlock, no hostages.
8. **The chaos drill:** kill your own host mid-party (2/4 penciled) — the holds lapse and release on restart. Correctness survives even the host's own crash.
9. **Measure:** on the 1,000 fake machines, compare your host vs the standard one on two numbers — how often parties land entirely in one room ("topology purity"), and how much seating is wasted to fragmentation. Those two measured numbers are the resume bullet.

---

## RUNG 6 — The Contrast ⚖️

| Host | Whole parties? | Same room? | Team budgets? | Checks at… |
|---|---|---|---|---|
| Standard | ✗ | ✗ | ✗ | the table |
| **Yours (TopoGang)** | ✓ | ✓ | ✗ | the table |
| Volcano | ✓ | partly | ✓ | the table |
| Kueue | ✓ | ✓ | ✓✓ | the door |

**When NOT to build your own:** production. Real platforms run Kueue and/or Volcano; you build yours to *own the internals* — and your benchmark comparing all of them is exactly the evidence that you know when each is right.

---

## RUNG 7 — Predict, then check 🧪

**P1.** Two parties of 4 arrive at a 6-seat room under the STANDARD host. What happens, and for how long?
<details><summary>Answer</summary>Each gets 3 seats; both wait half-seated forever; 6 expensive seats burn doing nothing. One-at-a-time seating has no concept of "party." You'll reproduce this deliberately as the project's first artifact.</details>

**P2.** Same two parties, but Kueue is the bouncer. What does the second party look like while waiting?
<details><summary>Answer</summary>Entirely outside — zero guests inside, zero seats held (its tasks are fully suspended). The bouncer only admits a whole party that fits the budget. The deadlock dies at the door.</details>

**P3.** A party of 16 hits your host when only 15 seats exist anywhere. Net seats held after 2 minutes, and what happens to the party of 8 behind them?
<details><summary>Answer</summary>Zero — the gate timeout erased all 15 pencil marks. The party of 8 seats immediately. Hold-then-release makes hostage-taking impossible.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** Kubernetes seats tasks one at a time, so I plugged a "confirmation gate" into its assembly line that holds each party member's penciled-in seat until the whole party fits — confirming all at once or erasing every hold — while a scoring step steers the party into one room; I operated the industry's door-checker (Kueue) and table-checker (Volcano) through five failure scenarios, then built the third myself in Go and proved it on a thousand simulated machines for free.

**Now do it for real:** open [project-07-topology-aware-gang-scheduler.md](../project-07-topology-aware-gang-scheduler.md). Its phases: reproduce the deadlock → operate Kueue & Volcano through the scenario matrix → Go on-ramp → build TopoGang plugin by plugin → chaos-drill it → measure purity & fragmentation at 1,000 fake nodes. (Deeper technical version: `Tier1-AI-Projects_Learning_Ladder.md`, Climb 3.)
