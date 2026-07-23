# Project 2 — The LLM Inference Platform, Explained From Zero 🪜
### Every technical idea in [project-2-llm-inference-platform.md](../project-2-llm-inference-platform.md), broken down for a smart adult with **no tech background** — read this first, then do the project hands-on.

> **Running analogy for the whole file:** a **scribe's office answering letters one word at a time**. Each customer conversation needs a growing **notepad** kept on the shelf next to the scribe — and shelf space, not the scribe's speed, is what runs out first.
>
> **Where this sits in your plan:** Tier-1 project #4 — the payoff. Serving AI answers ("inference") is the thing your target companies actually sell. Needs Project 1's cluster.

---

## RUNG 0 — What is this project, in one everyday sentence?

You'll run a real AI language model as a **production service**: a server (vLLM) that packs as many simultaneous conversations onto one GPU as physically possible, an autoscaler that watches the *queue at the counter* (not how busy workers "look"), and a release process that shows every change to a slice of users first and **auto-cancels itself** if measured speed gets worse.

---

## RUNG 1 — The Pain 🔥 (why an AI model can't be served like a website)

A normal website request is a quick stamp: request in, response out, done. An AI model is a **scribe writing an answer one word at a time** — and that breaks every normal serving habit:

- **Requests aren't equal.** One customer's answer is 50 words; another's is 2,000. Same "1 request," 40× the work. Counting requests-per-second becomes meaningless.
- **The naive line wastes the scribe.** Serve one customer at a time and the scribe idles between words. Serve a fixed batch and everyone waits for the *slowest* member while finished customers' desk slots sit empty. Either way, 5–10× of the GPU's capability is thrown away.
- **Shelf space fragments.** Every active conversation keeps a **notepad** (the "KV cache" — the model's memory of everything said so far) on the shelf beside the scribe. The old method reserved a *worst-case-sized* shelf section per customer — most of it empty — so the shelf "filled up" at 20–40% actual use.
- **The usual busy-meter lies.** The office's CPU meter reads ~30% while fifty customers queue outside — because the bottleneck is the scribe's shelf and hand, not the front desk. An autoscaler watching CPU would **never** add capacity. (Your CPU-era instinct, precisely wrong.)
- **Blind releases are outages.** A "small" configuration change can silently double response times. Ship it to everyone at once and customers find out before you do.

---

## RUNG 2 — The One Idea 💡

> **In AI serving the word is the unit of work and shelf space (the KV cache) is the scarce resource — so vLLM stores each conversation's notepad in small loose pages instead of reserved shelf sections (no wasted space → far more customers fit), lets new customers join the writing rotation the instant any slot frees (the scribe never idles), scales up based on how many customers are QUEUING (the only honest signal), and ships every change to one-third of customers first, promoting only if measured response time stays within the promise.**

Four clauses = the four things you'll build: **paged notepads · continuous rotation · queue-based scaling · measured canary releases.**

---

## RUNG 3 — The Machinery ⚙️

### (A) One answer, two phases

```
Customer letter arrives
  PHASE 1 — READ IT ALL AT ONCE ("prefill")     fast, muscular work — the big
    the scribe digests the whole letter          matrix-math units earn their keep;
    and writes the FIRST word                    this sets "time to first word"
  PHASE 2 — WRITE WORD BY WORD ("decode")        for EVERY word, the scribe re-reads
    one word per pass, consulting the            the notepad + the entire reference
    conversation's notepad each time             book — limited by the conveyor
                                                 belt (Project 16!), not muscle
WHY THE NOTEPAD? Without it, writing word N would require re-digesting all N-1
prior words — cost exploding quadratically. So it's kept on the shelf: THE KV CACHE.
It grows with conversation length × number of simultaneous customers.
THAT — not the scribe — is the resource everything fights over.
```

### (B) vLLM's two tricks

- **Paged notepads (PagedAttention):** instead of reserving one big worst-case shelf section per customer, notepad pages are stored loose, wherever they fit, tracked by an index card — exactly how a computer's operating system manages its own memory. Waste drops from ~60–80% to near zero → **several times more simultaneous customers on the same shelf.**
- **Continuous rotation (continuous batching):** the scribe advances *every* active conversation by one word per pass, and the moment any conversation finishes, a queued customer takes its slot **mid-pass** — nobody waits for strangers to finish. The scribe literally never idles.
- **The capacity dials you'll turn:** how much shelf vLLM may claim; the maximum conversation length (halve it ≈ double the simultaneous customers — same shelf, smaller notepads); and compressing the reference book (quantization) to free shelf space for more notepads.

### (C) The two-layer autoscale

```
queue at the counter grows (metric: "requests waiting")
  → KEDA (the pod-scaler) opens more scribe desks (new vLLM pods)
  → new desks need GPUs → Karpenter (Project 1's auto-renter) rents more GPU machines
load fades → wait 5 patient minutes (GPUs are pricey; don't flap) → desks close → machines returned
```
Pods scale on the queue; metal scales on the pods. Two scalers, two layers — that sentence is interview gold.

### (D) The self-cancelling release (canary)

A new configuration serves **34%** of customers for a few minutes while a robot referee keeps re-checking one number: the **95th-percentile response time** (the experience of your unluckiest 1-in-20 customer). Within the promise → promote to everyone. Breached even once → **automatic rollback**, recorded. Service promises become *gates*, not wall decorations.

---

## RUNG 4 — Jargon translator 🏷️

| When you read… | It just means… |
|---|---|
| inference / serving | running the trained model to answer users (vs training it) |
| vLLM | the open-source serving engine with the two tricks above |
| token | roughly one word-piece — the true unit of work and billing |
| prefill / decode | read-the-whole-letter phase / word-by-word writing phase |
| TTFT | "time to first token" — how long till the first word appears |
| inter-token latency | the pause between words while streaming |
| KV cache | the conversation's notepad in GPU memory — THE scarce resource |
| PagedAttention | notepads stored as loose pages + an index card (no reserved sections) |
| continuous batching | new customers join the writing rotation the instant a slot frees |
| `--max-model-len` | max conversation length = each notepad's size budget — the capacity dial |
| quantization | compressing the model's reference book to free shelf space |
| `num_requests_waiting` | the queue-at-the-counter metric — THE honest scaling signal |
| KV-cache usage % | how full the shelf is — the saturation gauge |
| KEDA | the autoscaler that can watch ANY metric (here: the queue) |
| cooldown / stabilization | patience before scaling down (GPUs are pricey) |
| Argo Rollouts / AnalysisTemplate | the gradual-release machinery / the robot referee's checklist |
| p95 latency | your unluckiest 1-in-20 customer's wait — the number the referee watches |
| canary | the small first slice of customers who get a new version |
| k6 | the load-testing tool that simulates crowds of customers |
| OpenAI-compatible API | the standard request format — clients can swap backends freely |

---

## RUNG 5 — The Trace 🎬 (one conversation, then a crowd)

1. A chat request arrives at the standard address and reaches a vLLM desk on Project 1's rented GPU machine (the model already loaded — re-downloading it every restart is banned by a persistent cache).
2. Shelf has room → no queue → the letter is read in one pass (phase 1) → first word streams back in ~300ms.
3. Word-by-word writing proceeds — interleaved with every other active conversation. Two finish mid-pass; two queued customers slip into their slots on the very next pass. The scribe never pauses.
4. The conversation ends; its notepad pages are freed instantly. The dashboards saw everything: first-word time, total time, queue depth, shelf fullness.
5. **A crowd arrives** (the load test ramps to 30 simulated users). The shelf saturates; the queue climbs past the threshold → KEDA opens two more desks → they sit waiting ~90 seconds while Karpenter rents two GPU machines → queue drains. One dashboard shows the whole causal chain — screenshot it.
6. **A new version ships** to 34% of traffic. The referee checks the unluckiest-customer number three times. Good → everyone gets it. You then deliberately ship a bad config → the referee catches it and rolls back automatically — recorded, your "how do you ship AI safely" interview story.
7. The crowd leaves; after five patient minutes the desks close; minutes later the machines are returned. Idle cost: ~zero.

---

## RUNG 6 — The Contrast ⚖️

- **vs a normal web service:** every assumption flips — work is measured in words not requests, the limit is GPU shelf space not CPU, each request carries growing state (the notepad), and the honest load signal is the queue. Same Kubernetes objects, different physics.
- **vs the other serving engines (one line each):** TensorRT-LLM = NVIDIA's pre-compiled fastest-but-rigid option; Triton = the multi-framework host it usually lives in; TGI = Hugging Face's engine; SGLang = fastest at structured outputs. vLLM is the credible open default.
- **When NOT this stack:** models small enough for ordinary chips (a GPU is waste), or when buying a fully-managed AI endpoint. Your targets *build* serving — that's why this project exists.

---

## RUNG 7 — Predict, then check 🧪

**P1.** Under heavy load, what will the CPU meter and the queue metric each show, and which would a CPU-based autoscaler do?
<details><summary>Answer</summary>CPU ~30% (calm), queue climbing steadily. A CPU autoscaler would do NOTHING — the bottleneck is GPU shelf + writing bandwidth, invisible to CPU. This one chart is the entire autoscaling interview answer.</details>

**P2.** You halve the maximum conversation length. What roughly happens to how many simultaneous customers fit, and why?
<details><summary>Answer</summary>Roughly doubles — each notepad's budget halves inside the same fixed shelf. Capacity is shelf ÷ per-notepad size; you changed the denominator.</details>

**P3.** You ship a deliberately mis-configured version. Health checks pass. What catches it, and when?
<details><summary>Answer</summary>The canary referee — it measures the p95 response-time promise on the 34% slice and auto-rolls-back on breach. Health checks ask "is it alive?"; the referee asks "is it GOOD?" — different questions.</details>

---

## 🎁 CAPSTONE — Say it back

**One sentence:** an AI model answers one word at a time while every conversation's notepad competes for scarce GPU shelf space — so vLLM pages the notepads (no waste) and rotates customers continuously (no idling), the platform scales on the queue at the counter rather than the lying CPU meter, and every release proves itself on a slice of real traffic before anyone else sees it.

**Now do it for real:** open [project-2-llm-inference-platform.md](../project-2-llm-inference-platform.md). Its phases: deploy vLLM on Project 1's cluster → wire the queue metric to KEDA → load-test the crowd → configure the canary referee → break it on purpose and watch the auto-rollback. (Deeper technical version: `Tier1-AI-Projects_Learning_Ladder.md`, Climb 4.)
