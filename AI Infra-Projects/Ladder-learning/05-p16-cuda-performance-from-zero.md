# Project 16 — CUDA & GPU Performance, Explained From Zero 🪜
### Every technical idea in [project-16-cuda-gpu-performance-engineering.md](../project-16-cuda-gpu-performance-engineering.md), broken down for a smart adult with **no tech background** — read this first, then do the project hands-on.

> **Running analogy for the whole file:** a GPU is a **giant room full of thousands of tiny calculators**, fed by **one conveyor belt** bringing them numbers from a warehouse. Almost everything about GPU performance is the tension between how fast the calculators ARE and how fast the belt can FEED them.
>
> **Where this sits in your plan:** Tier-1 project #2 — do it **in parallel** with Project 1. It's the cheapest project in the whole repo (~$0 on a laptop gaming GPU, a few dollars of rented time otherwise) and the highest "fluency per hour": it makes every later project sharper. *(Note: your plan says to delete the older `project-13-cuda-gpu-performance-engineering.md` — that file doesn't exist in the folder anymore, so nothing to do.)*

---

## RUNG 0 — What is this project, in one everyday sentence?

You're learning to **read a GPU's performance like a doctor reads vital signs** — so when someone says "the GPU is slow" you can say exactly WHY (calculators idle? belt saturated? waiting for deliveries from another building?) and exactly WHICH fix will help — before spending a single dollar on bigger hardware.

---

## RUNG 1 — The Pain 🔥

A team's AI training job is slow. The GPU costs $2/hour. The basic gauge says "55% busy." Now what?

Without this skill, the answers are folklore:
- **"Buy a bigger GPU"** — useless if the problem is the conveyor belt, not the calculators. Most real workloads ARE belt-limited, and teams discover this only after the invoice.
- **"The gauge says 90% busy, so we're efficient"** — the standard gauge only means *someone was in the room*; the calculators can be 90% "busy" while doing 4% of their possible work. Utilization theater.
- **"Trust the spec sheet"** — vendor brochures mix real numbers with marketing numbers that are exactly 2× higher (they assume a special data trick almost nobody uses). Build your math on the wrong number and every conclusion is silently double-counted.

Every wrong guess is billed by the hour. The person who can DIAGNOSE — that's the skill companies say will "run the AI era."

---

## RUNG 2 — The One Idea 💡

> **Every GPU workload is limited by exactly one of three things — the calculators (compute), the conveyor belt (memory bandwidth), or deliveries from other buildings (communication) — and you can tell which one by a single division: how much math the workload does per byte of data it moves. Below a known threshold, only moving less data helps; above it, only faster calculators help.**

That division is called **arithmetic intensity** ("math per delivery"), and the threshold is the **ridge point** (the GPU's calculator speed ÷ its belt speed). This one piece of arithmetic — doable on paper, before touching the machine — replaces all the folklore.

Two consequences worth loving:
- The threshold is brutally high on real GPUs. So **most workloads are belt-limited**, and the two levers that actually help are: **smaller packages** (use 16-bit numbers instead of 32-bit — half the bytes per delivery, AND it switches on special matrix-math units) and **fewer round trips** (fuse several steps into one, so intermediate results never ride the belt at all).
- "It got faster" stops being magic. You can now say *which lever moved it and why*.

---

## RUNG 3 — The Machinery ⚙️

### (A) The hardware, in five plain ideas

```
CALCULATOR CLUSTERS ("SMs")   the room is divided into clusters (a T4 GPU has 40);
                              work is handed out cluster by cluster
TEAMS OF 32 ("warps")         inside a cluster, calculators work in locked teams of 32
                              doing the SAME step together — if half a team must do
                              something different, the halves take turns (slow!)
MATRIX UNITS ("Tensor Cores") special-purpose super-calculators ONLY for matrix math,
                              and ONLY when numbers arrive in the small 16-bit format —
                              the whole reason "mixed precision" is a speed feature
THE BELT ("memory bandwidth") the warehouse-to-room conveyor; its speed is a hard number
                              (T4: ~300 GB/s) — the ceiling most workloads hit
KEEP-BUSY TRICK ("occupancy") clusters juggle several teams, switching to another team
                              whenever one is waiting on a delivery — hiding the wait
```

### (B) The software stack — why "version matrix" pain exists

Your AI code doesn't talk to the chip directly. It's a chain: **your code → PyTorch (the AI toolkit) → NVIDIA's pre-tuned math libraries → CUDA (the GPU's language runtime) → the driver → the chip.** Each layer only works with certain versions of the layer below — that's the infamous compatibility matrix from Project 1, and now you know it's not bureaucracy: each layer is literally compiled against the next.

### (C) The two "camera" tools (profilers)

- **Nsight Systems** = a **time-lapse camera of the whole day**: shows when the GPU worked, when it idled, and the classic crime — the GPU standing around between steps *waiting for the kitchen (CPU) to prep the next batch of data*. Fixing that is a pure infrastructure win, no AI knowledge needed.
- **Nsight Compute** = a **microscope on one operation**: is this specific step belt-limited or calculator-limited? Are the matrix units even switched on? It literally draws the math from Rung 2 as a chart (the "roofline").
- The dashboard gauge from Project 1 (DCGM) is the **fleet weather report**; these two are the *diagnosis*. Fleet says "something's off" → time-lapse says "where the time went" → microscope says "why."

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| CUDA | NVIDIA's language/runtime for programming their GPUs |
| kernel | one GPU operation — a batch of work sent to the room of calculators |
| SM | one calculator cluster |
| warp | a locked team of 32 calculators doing the same step |
| Tensor Core | the special matrix-math super-calculator (needs 16-bit numbers) |
| VRAM / HBM / GDDR | the GPU's own warehouse (its memory) |
| memory bandwidth | the conveyor belt's speed, in gigabytes per second |
| arithmetic intensity | math done per byte delivered — THE diagnostic number |
| ridge point | calculator speed ÷ belt speed — the threshold that splits "belt-limited" from "calculator-limited" |
| roofline | the chart drawing exactly that: two ceilings, your workload plotted under one of them |
| fp32 / fp16 / bf16 | number formats: 32-bit (default), 16-bit (half the bytes, enables matrix units) |
| mixed precision / AMP | letting the toolkit use 16-bit where safe — the "smaller packages" lever |
| kernel fusion | merging several operations into one so intermediate data never rides the belt — the "fewer trips" lever |
| `torch.compile` / TensorRT | tools that apply fusion automatically |
| dense vs sparse peak | the real spec number vs the 2×-inflated marketing number — always use dense |
| MFU | honest efficiency: achieved math rate ÷ the DENSE peak |
| `nvidia-smi` utilization | the misleading "someone's in the room" gauge |
| nsys / ncu | the time-lapse camera / the microscope |
| dataloader | the CPU-side kitchen prepping data batches — the classic hidden bottleneck |

---

## RUNG 5 — The Trace 🎬 (one investigation, start to finish)

1. **Symptom.** A training job feels slow; the fleet gauge sawtooths 30–90%.
2. **Time-lapse first.** The camera shows the crime: **gaps** — the GPU idle between steps, waiting for the CPU kitchen to prep data.
3. **The infra fix.** More prep cooks + prepping ahead + a faster hand-off (workers, prefetch, pinned memory). Re-film: gaps gone. *You never touched the AI itself.*
4. **Microscope on the biggest operation.** Verdict: running in 32-bit, matrix units asleep, belt nearly saturated → belt-limited AND leaving the best hardware idle.
5. **Pull the smaller-packages lever.** Switch to 16-bit: every delivery halves and the matrix units wake up → measured **1.5–3× faster**. (Fun trap: the cheap T4 chip doesn't support one of the two 16-bit formats — knowing that is itself interview material.)
6. **Compute honest efficiency.** Speed ÷ the DENSE spec number = your MFU. Using the marketing number would have flattered you 2×.
7. **Pull the fewer-trips lever.** Auto-fusion tools; re-film with the camera and literally **count fewer operations**. Faster, and you can prove why.
8. **Demystify.** Write the tiniest possible GPU program yourself, PREDICT its speed on paper first (it's belt-limited by ~2,600×, so it'll hit ~0.04% of the calculator peak — and that's CORRECT behavior), then measure. When your paper math matches the machine, the model is yours.

---

## RUNG 6 — The Contrast ⚖️

- **You vs kernel authors:** you are not learning to hand-write GPU code for a living — NVIDIA's tuned libraries beat almost everyone (losing to them in step 8 IS the lesson). The market pays platform people for the **diagnosis**.
- **Busy-gauge vs honest efficiency:** never quote the "someone's in the room" percentage as efficiency; quote MFU vs dense peak.
- **When NOT to profile:** if the workload is delivery-limited across buildings (a networking problem — Tier-2's training project), no calculator work helps; and for a tiny one-off job, diagnosing costs more than it saves.

---

## RUNG 7 — Predict, then check 🧪

**P1.** A workload does 1 unit of math per 12 bytes delivered, on a chip whose threshold is 217. Which limit is it under, and what's the ONLY category of fix?
<details><summary>Answer</summary>Massively belt-limited (0.083 vs 217 — off by ~2,600×). Only moving less data helps: smaller number formats, fusing steps, reusing data already in the room. Faster calculators would change nothing.</details>

**P2.** A colleague proposes upgrading to a card with 2× the calculator speed but the SAME belt speed, for a belt-limited workload. Verdict?
<details><summary>Answer</summary>Near-zero improvement — the belt is the ceiling and the belt didn't change. This is the single most expensive folklore mistake in the field.</details>

**P3.** Switching from 32-bit to 16-bit numbers speeds up even a belt-limited workload that never touches the matrix units. Why?
<details><summary>Answer</summary>Every number is half the bytes → the same belt delivers twice the numbers per second. The matrix units are a bonus on top, not the only mechanism.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** GPU performance is a two-number diagnosis — math-per-byte versus the chip's threshold — that tells you whether the calculators, the conveyor belt, or the network is the limit, and therefore whether smaller number formats, fused steps, or nothing at all will help; a time-lapse camera shows where the time went, and a microscope shows why.

**Now do it for real:** open [project-16-cuda-gpu-performance-engineering.md](../project-16-cuda-gpu-performance-engineering.md). Its phases: profile a real training loop (find the kitchen-prep crime) → fix it → benchmark 32-bit vs 16-bit → apply auto-fusion and count the operations drop → write and predict your own tiny GPU program. (Deeper technical version: `Tier1-AI-Projects_Learning_Ladder.md`, Climb 2.)
