# Tier-2 · Fault-Tolerant Training & Goodput, Explained From Zero 🪜
### Every technical idea in [project-10-fault-tolerant-training-goodput.md](../project-10-fault-tolerant-training-goodput.md), broken down for a smart adult with **no tech background**.

> **Running analogy for the whole file:** a **giant rowing crew** — hundreds of rowers who must stroke in perfect sync, for weeks, without stopping. Training a large AI model IS this boat: every rower (GPU) computes a piece, then everyone synchronizes on **every single stroke**.
>
> **Where this sits in your plan:** Tier-2 #2 — the frontier-lab specialty nothing else in your portfolio covers: making training *survive* failure. It's SRE thinking (your home turf) applied to the most expensive workload on earth.

---

## RUNG 0 — What is this project, in one everyday sentence?

You'll connect two GPU machines with a **genuinely fast rowing-drum channel** (AWS's special network, EFA), measure how much faster it is than the ordinary network, run real synchronized training across machines — and then deliberately break things (kill machines, inject faults) and build the machinery that lets the boat **keep rowing anyway**, measuring the fraction of time it actually moved forward.

---

## RUNG 1 — The Pain 🔥

Meta's engineers published a number: training their big Llama model, they suffered **466 interruptions in 54 days** — mostly hardware dying. At scale, failure isn't an *if*; it's a *daily guarantee*. So the metric that separates labs isn't "did it fail?" but **goodput** — the fraction of expensive boat-time that produced forward motion, versus time lost to restarting, re-rowing lost strokes, and waiting.

Why training is uniquely fragile:

- **Everyone syncs on every stroke.** After each step, all rowers exchange results (the "AllReduce") and only then take the next stroke. So **one slow rower slows the entire boat** (a "straggler"), and one dead rower **stops it completely**.
- **The talking is enormous.** Each sync moves roughly twice the model's whole size across the network, every step. On an ordinary network, the boat spends its life waiting on the drum; the special channel (EFA — AWS's answer to the science world's InfiniBand) bypasses the operating system entirely to move data at RDMA speeds.
- **Failure taxonomy you'll meet:** GPU hardware faults (with numeric codes called XID — the boat's warning lights), network hangs, stragglers, the cloud reclaiming cheap "spot" machines mid-row, and a nasty silent one: the special channel quietly falling back to the slow network *while everything still "works"* — just 5× slower.
- **Without checkpoints, a crash means starting over.** Weeks of a million-dollar row, gone.

---

## RUNG 2 — The One Idea 💡

> **At scale, hardware failure is a daily certainty, so the job is not avoiding it but engineering around it: a fast sync-channel you PROVE is actually in use, frequent game-saves (checkpoints) written asynchronously so saving doesn't stop the rowing, a crew that keeps rowing when a seat empties and re-syncs when a substitute arrives (elastic training), a watchman who spots a machine's warning lights and swaps it out automatically — and one honest scoreboard: goodput, the fraction of wall-clock time that produced real progress.**

---

## RUNG 3 — The Machinery ⚙️

### (A) The fabric — the rowing drum's sound channel

```
 inside one machine:   GPUs talk over ultra-fast direct wiring (NVLink)
 between machines:     ① ordinary network (TCP)      — the sad path, chatty & slow
                       ② EFA (AWS's RDMA-class net)  — programs write straight to the
                                                       wire, bypassing the OS
 the translator stack: training code → NCCL (the sync choreographer)
                       → a shim (aws-ofi-nccl) → libfabric → EFA hardware
 the proof tool:       nccl-tests — measures real sync bandwidth ("busbw");
                       you run it BOTH ways and publish the TCP-vs-EFA table,
                       because EFA silently falls back to TCP if a firewall
                       rule is missing — you PROVE the path, never trust it
```

### (B) The training styles (why memory forces sharing)

- **Simple data-parallel:** every rower holds the WHOLE recipe book (model) and they sync corrections each stroke. Works until the book no longer fits one rower's desk.
- **Sharded (FSDP / ZeRO-3):** the book itself is torn into pieces — each rower holds a fragment, borrowing pages just-in-time from teammates each stroke. More talking, radically less desk space — it's how big models fit at all. You'll run both and feel the trade.

### (C) The reliability layer (the half frontier labs hire for on its own)

```
 GAME-SAVES     checkpoints written ASYNC (rowing continues while the save ships
                to local disk, then cloud storage) — save cost measured, not guessed
 ELASTICITY     torchrun's flexible crew size ("2 to 4 boats"): lose a machine and
                the crew re-synchronizes and continues smaller; a replacement joins
                and it grows back — no human in the loop
 THE WATCHMAN   node-problem-detector reads each machine's warning lights (XID codes
                in the system log) → marks the machine sick → a small robot you write
                cordons it, drains it, deletes it → Karpenter (Project 1) buys a
                replacement → the elastic crew absorbs it
 THE SCOREBOARD goodput = productive rowing time ÷ total time; plus MFU (Project 16's
                honest efficiency) and straggler charts — the dashboard IS the deliverable
```

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| distributed training | many GPUs across machines training one model together |
| AllReduce | the every-stroke sync where all rowers merge their results |
| NCCL | NVIDIA's choreographer library that runs those syncs |
| straggler | one slow rower who slows the whole synchronized boat |
| NVLink / InfiniBand / EFA | direct GPU wiring / science-world fast network / AWS's version |
| RDMA | writing straight into another machine's memory, skipping the OS — the speed trick |
| busbw / nccl-tests | measured sync bandwidth / the tool that measures it |
| TCP fallback | the silent failure where the fast channel quietly isn't used |
| FSDP / ZeRO-3 | tearing the model itself into fragments so it fits (sharding) |
| torchrun / rendezvous | the crew-assembly tool / the roll-call where rowers find each other |
| elastic training | the crew survives losing/gaining members mid-row |
| checkpoint (async, sharded) | the game-save, written without stopping, in per-rower pieces |
| XID error | a GPU's numeric warning-light code in the system log |
| node-problem-detector | the watchman daemon reading those lights |
| cordon / drain | "no new work here" / "move existing work off" |
| remediation controller | your small robot: sick machine → cordon → drain → replace |
| Kubeflow PyTorchJob / JobSet | the Kubernetes wrappers that launch multi-machine training crews |
| goodput | productive time ÷ total time — the honest scoreboard |
| MFU | achieved math rate ÷ the chip's honest peak (Project 16's metric) |

---

## RUNG 5 — The Trace 🎬 (one training day with a death in it)

1. A 2-machine crew launches. Roll-call (rendezvous) completes; rowing begins; the dashboard shows step-time and tokens/sec.
2. You run the proof: sync bandwidth measured on the ordinary network, then via EFA — the published table shows the fast channel is *actually* engaged (not silently fallen back).
3. Every N minutes, a game-save streams out **while rowing continues** — you measure its cost as a small dip, not a stop.
4. **A machine's warning light flashes** (an XID error — its GPU is failing). The watchman sees it in the log within seconds and marks the machine sick.
5. Your robot cordons and drains it; the elastic crew shrinks and **keeps rowing** at reduced size; Karpenter buys a replacement machine (~90s).
6. The replacement joins the roll-call; the crew re-expands; a recent game-save covers the tiny gap. No human was paged.
7. Week's end: the scoreboard says goodput 91% — and itemizes the missing 9% (saves, one re-crew, one straggler patch). That dashboard + the TCP-vs-EFA table are the portfolio artifacts.

---

## RUNG 6 — The Contrast ⚖️

- **Checkpoint-and-restart vs elastic:** old way = any death stops everything until a full restart from the last save (all progress since = lost, plus full re-assembly). Elastic = shrink-continue-regrow; deaths cost seconds-to-minutes, not the gap-plus-restart.
- **Watching dashboards vs the watchman:** humans notice a dead machine in minutes-to-hours; the log-watcher reacts in seconds and the robot needs no human at all. At 466 interruptions per 54 days, automation isn't a luxury.
- **Honesty note:** your cheap 2-machine lab rehearses the *operational* skillset (the plumbing, proofs, and reliability machinery) — the raw speeds aren't a giant cluster's, and saying exactly that is itself an interview-grade answer.

---

## RUNG 7 — Predict, then check 🧪

**P1.** One rower in a synchronized 16-GPU crew runs 20% slow. What's the whole boat's speed, and why?
<details><summary>Answer</summary>Everyone rows at the slowest rower's pace — the every-stroke sync means nobody starts stroke N+1 until all finish N. That's why straggler DETECTION is a first-class metric, not a nice-to-have.</details>

**P2.** The special channel's firewall rule is missing. What breaks visibly?
<details><summary>Answer</summary>Nothing visibly — that's the trap. Training runs, just ~5× slower: EFA silently falls back to ordinary TCP. The only defense is measuring the sync bandwidth and proving which path you're on — exactly what the project's benchmark table does.</details>

**P3.** A spot machine is reclaimed mid-training. Walk the automatic chain that follows.
<details><summary>Answer</summary>Watchman/K8s notices → elastic crew re-syncs smaller and keeps rowing → Karpenter buys a replacement → it joins the roll-call → crew regrows → the last async game-save covers any gap. Goodput dips, nothing dies, nobody is paged.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** large-scale training is a synchronized rowing crew where failure is daily arithmetic — so you prove the fast sync-channel is really in use, save the game asynchronously, let the crew shrink and regrow through deaths, automate sick-machine replacement off the GPU's own warning lights, and grade yourself on goodput: the fraction of expensive time that actually moved the boat.

**Now do it for real:** open [project-10-fault-tolerant-training-goodput.md](../project-10-fault-tolerant-training-goodput.md). Its phases: bring up the 2-machine EFA fabric → publish the TCP-vs-EFA table → run sharded training → add elastic + async saves → build the watchman-and-robot loop → ship the goodput dashboard.
