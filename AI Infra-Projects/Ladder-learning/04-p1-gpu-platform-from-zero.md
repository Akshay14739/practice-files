# Project 1 — The GPU-Ready Kubernetes Platform, Explained From Zero 🪜
### Every technical idea in [project-1-gpu-kubernetes-platform.md](../project-1-gpu-kubernetes-platform.md), broken down so a smart adult with **no tech background** could follow — read this first, then do the project hands-on.

> **The ladder rule:** we climb **Pain → One Idea → Machinery → Jargon → Trace → Contrast → Predict → Capstone**. No command appears before you understand what it's doing. Where a concept gets technical, it's introduced through one running analogy: **a restaurant that just bought a $10,000 pizza oven.**
>
> **Where this sits in your plan:** Tier-1 project #1 — the foundation everything else stands on. Do it in parallel with Project 16 (the CUDA ladder, file 05). It's your fastest win: it's your familiar EKS + Karpenter world plus ONE new layer.

---

## RUNG 0 — What is this project, in one everyday sentence?

You're going to teach a computer-management system (Kubernetes) to **notice, share, meter, and rent out** the most expensive kind of computer chip there is — the GPU — so that expensive hardware never sits idle and never gets wasted on work that doesn't need it.

**Why it matters to your career:** every AI company's platform team owns exactly this. Being able to explain "how a workload actually reaches a GPU" step-by-step is the whiteboard question their interviews assume.

---

## RUNG 1 — The Pain 🔥 (why does this project need to exist?)

Imagine a restaurant kitchen run by a very good manager (that's **Kubernetes** — software that decides which task runs on which machine). The restaurant just bought a **$10,000 specialty pizza oven** (the **GPU** — a chip that does massive amounts of math in parallel, which is what AI needs).

Here's the problem: **the manager has no idea the oven exists.**

- The oven isn't plugged in and has no instruction manual installed (the computer lacks the **driver** — the software that lets the machine talk to the chip).
- The cooking stations can't reach it (programs run in sealed boxes called **containers**, and nothing connects those boxes to the oven).
- The manager's inventory sheet lists stoves and counter space but no oven (Kubernetes tracks CPU and memory, not GPUs).
- So the manager seats pizza orders at the salad station, and lets a salad-maker camp at the $10,000 oven doing nothing special.

**What people did before, and why it hurt:** they hand-built custom machines with everything pre-installed (like buying a new fully-equipped kitchen every time the oven's manual got a new edition — slow, error-prone, endless). And with no sharing, one person doodling on 5% of the oven blocked everyone else from the other 95%. At these prices, that's not waste — it's a budget scandal.

---

## RUNG 2 — The One Idea 💡

Say this sentence until it feels obvious:

> **A piece of software called the "GPU Operator" automatically installs everything a machine needs to use its GPU, and then tells the manager "this machine has 1 GPU" as a simple countable item — so ordinary scheduling just works; a keep-out sign protects the expensive machines from ordinary work; the count can be deliberately multiplied ("this 1 oven is 4 ovens") to share it; and an auto-renter buys the GPU machine only when work is waiting and returns it minutes after the work ends.**

Everything in the project is one of those five clauses: **install automatically · count it · fence it · multiply it · rent it just-in-time.**

---

## RUNG 3 — The Machinery ⚙️ (the parts, in plain language)

### (A) The chain — how a task actually reaches the GPU (the interview whiteboard)

```
  A machine with a GPU joins the fleet
      │
 [1] DRIVER installs itself          → the machine can now talk to the chip
      │                                (the oven gets plugged in + its manual installed)
 [2] TOOLKIT installs itself         → sealed program-boxes (containers) can now
      │                                reach the chip (a hatch from station to oven)
 [3] DEVICE PLUGIN announces         → tells the manager: "this machine has 1 GPU"
      │                                (the oven appears on the inventory sheet)
 [4] MANAGER (Kubernetes) matches    → a task saying "I need 1 GPU" gets seated
      │                                on this machine — same way it seats CPU tasks
 [5] The task runs on the GPU        → the pizza actually bakes
      │
  + a GAUGE (DCGM) publishes the oven's temperature & busy-ness to dashboards
```

Steps 1–3 + the gauge are all installed and kept up-to-date by ONE piece of software — the **GPU Operator**. Because it re-installs itself onto every new machine automatically, machines can come and go every few minutes and still work. That's the whole trick.

### (B) The productive lie — sharing one GPU

The device plugin controls what number gets announced. Tell it to announce **"this 1 GPU is 4 GPUs"** (**time-slicing**) and four small tasks get seated on one card, taking turns. Important honesty: the chip itself didn't change — there are **no walls** between the four. One greedy task can crash the party for all four. (Safer sharing modes with real walls exist — that's Tier-2's fractional-GPU project.)

### (C) The money loop — renting metal by the minute

**Karpenter** is the auto-renter: when a GPU task is waiting with nowhere to run, it rents a GPU machine from the cloud (~90 seconds); when the last task finishes, it returns the machine (~2 minutes later). A **taint** — a "RESERVED FOR GPU WORK" sign — keeps ordinary tasks off the expensive machine the whole time. Result: you pay for GPUs almost only while they're computing.

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| Kubernetes / K8s | the restaurant manager: software placing tasks onto machines |
| node | one machine (one kitchen) in the fleet |
| pod / container | a task in a sealed lunchbox — carries everything it needs |
| GPU | the $10k parallel-math chip AI runs on |
| driver | the software letting a machine talk to its GPU |
| container toolkit | the hatch connecting sealed lunchboxes to the GPU |
| device plugin | the announcer: "this machine has N GPUs" |
| `nvidia.com/gpu: 1` | a task's order slip: "I need 1 GPU" |
| GPU Operator | the auto-installer that sets up ALL of the above on every machine |
| DaemonSet | "run one copy of this on every machine" — how the operator ships its pieces |
| taint / toleration | the RESERVED sign / the permission slip to ignore it |
| time-slicing | announcing 1 GPU as N so N tasks share it, turn by turn, no walls |
| MIG | real hardware walls inside one GPU (only on premium chips) — the safe sharing |
| DCGM exporter | the gauge publishing GPU busy-ness/temperature to dashboards |
| Karpenter / NodePool | the auto-renter / its shopping rules (which machines, spot-cheap first, spending cap) |
| spot instance | renting a machine at ~1/3 price, accepting it can be reclaimed on short notice |

---

## RUNG 5 — The Trace 🎬 (one task's whole life, as a story)

1. You submit a tiny GPU test task. Its order slip says "1 GPU" and it carries the RESERVED-sign permission slip. **No machine in the fleet has a GPU** → the task waits.
2. The auto-renter sees it waiting, checks its shopping rules, and rents one cheap spot GPU machine. ~90 seconds.
3. The new machine arrives **bare and fenced** (RESERVED sign up from birth — ordinary tasks can't touch it).
4. The auto-installer dresses it: driver → hatch → announcer. The inventory sheet now reads "1 GPU." The gauge starts publishing to the dashboard.
5. The manager seats the waiting task. It runs on the GPU and prints its success message.
6. You apply the "1 = 4" sharing config; the SAME machine now advertises 4; four small tasks all land on the one card — visible right on the inventory sheet.
7. You delete everything. The machine empties → 60-second timer → the auto-renter returns it. **Two minutes after your last task, GPU spending is zero.** You screenshot that lifecycle — it's your cost-engineering evidence.

---

## RUNG 6 — The Contrast ⚖️ (old way vs this way, and when NOT)

- **Hand-built machine images vs the Operator:** old way = you personally rebuild the machine recipe every time any version changes (forever); Operator way = the stack is self-installing software that lands on any machine automatically. Only the second survives machines that live for minutes.
- **When the old way IS right:** if machines must boot ultra-fast, big shops pre-bake the driver AND run the operator for the rest — both, not either.
- **When NOT this project's stack at all:** if the work is small enough to run on ordinary chips (a GPU is waste), or if you're buying a fully-managed AI service (someone else's platform). But the companies you're targeting BUILD the platform — that's the point.

---

## RUNG 7 — Predict, then check 🧪 (say your answer aloud, then peek)

**P1.** You launch an ordinary (non-GPU) task while the expensive GPU machine is running. Where does it land, and why?
<details><summary>Answer</summary>On an ordinary machine — never the GPU one. The RESERVED sign (taint) filters it out at seating time; only tasks carrying the permission slip (toleration) may land there. Inverse: remove the permission slip from a GPU task and it waits forever even with a free GPU.</details>

**P2.** After applying the "1 GPU = 4" sharing config, what changed physically inside the chip?
<details><summary>Answer</summary>Nothing. Only the ANNOUNCED number changed (1 → 4). Four tasks now take turns on the same silicon with no walls between them — which is exactly why this mode is for friendly dev work, not untrusted tenants.</details>

**P3.** You delete all GPU work at 2:00pm. What does the GPU bill look like at 2:05pm, and what two mechanisms made that true?
<details><summary>Answer</summary>~Zero. The machine emptied, the 60-second consolidation timer fired, and the auto-renter (Karpenter) returned the machine — renting was triggered by a waiting task, and returning by the absence of one. Pay-per-need in both directions.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** an auto-installer makes every GPU machine self-configuring, an announcer turns the GPU into a countable item the ordinary scheduler can place, a reserved sign fences the expensive machines, the count can be multiplied to share a card, and an auto-renter makes GPU machines exist only while work needs them.

**Now do it for real:** open [project-1-gpu-kubernetes-platform.md](../project-1-gpu-kubernetes-platform.md). Its phases will have you: build the cluster → install the GPU Operator → run the test task → apply time-slicing → watch the dashboards → time the rent/return loop with a stopwatch. Every phase is one rung of this ladder made physical. (Deeper technical version, when ready: `Tier1-AI-Projects_Learning_Ladder.md`, Climb 1.)
