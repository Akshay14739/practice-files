# Bandwidth, Latency & AI/HPC Networking

*Two numbers people constantly confuse — how much versus how soon — and why, for GPU clusters, the network is the real bottleneck.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** The difference between **bandwidth** (throughput) and **latency** (delay), the metrics around them (RTT, jitter, packet loss, bandwidth-delay product), and why AI/HPC workloads need exotic interconnects (**InfiniBand, RoCE, RDMA**).

**Why did it land on my desk?** You run GPU workloads on EKS — distributed training and LLM inference. Training is stalling and the GPUs sit idle waiting on data; users complain the chatbot is "slow to start" but streams fine once going. These are *networking* problems in disguise, and diagnosing them requires knowing exactly which of two very different quantities you're up against.

**What do I already know?** You know CDNs cut distance-latency ([21-cdn-edge-waf.md](21-cdn-edge-waf.md)) and how packets move ([07-transport-layer-tcp-udp.md](07-transport-layer-tcp-udp.md), [08-routing-and-forwarding.md](08-routing-and-forwarding.md)). This chapter sharpens *what* you're optimizing and introduces the hardware AI teams reach for.

---

## 🔥 Rung 1 — The Pain

"Make the network faster" is a meaningless request until you know *which* faster. People conflate two independent things and optimize the wrong one:

- A team **buys a fatter link** (more bandwidth) to fix a *latency* problem (users far away) — and it doesn't help at all, because distance-delay isn't a bandwidth issue.
- A team **moves compute closer** (lower latency) to fix a *throughput* problem (a huge nightly data sync) — and it barely helps, because the bottleneck was bytes-per-second, not startup delay.

And in AI/HPC the stakes explode: a training job spreads a model across dozens of GPUs that must exchange gradients every step. If the *network* between GPUs is slow, **$40/hr GPUs sit idle waiting on each other**. The most expensive compute in your budget is throttled by a network you didn't think to size. "The GPUs are only 30% utilized" is, more often than not, a networking failure.

**Who feels it most?** Anyone running latency-sensitive or throughput-heavy systems — and especially AI-infra teams, where the interconnect determines whether GPUs earn their cost.

> **✅ Check yourself before Rung 2:** Why won't buying more bandwidth speed up a request from Sydney to a Virginia server that's already lightly loaded?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **Bandwidth is how much data can flow per second; latency is how long before the first bit arrives — they are independent, so you fix latency by shortening distance/hops and fix bandwidth by widening the pipe or parallelizing, and you must know which one is hurting you.**

Everything derives from "how much vs how soon are different problems":

- *Latency = delay* → dominated by **distance** and **number of hops**; fixed by moving closer (CDN, region, edge), fewer hops, faster media.
- *Bandwidth = capacity* → dominated by **link width and parallelism**; fixed by fatter links, more connections, better protocols.
- *They interact but don't substitute* → the **bandwidth-delay product** (bandwidth × RTT) is how much data must be "in flight" to keep a high-bandwidth, high-latency link full.

The plumbing analogy: **bandwidth is the pipe's diameter; latency is the pipe's length.** A wide, long pipe moves a lot of water — but the first drop still takes a while to arrive.

> **✅ Check yourself before Rung 3:** Give one fix that helps latency but not bandwidth, and one that helps bandwidth but not latency.

---

## ⚙️ Rung 3 — The Machinery

### The metrics

```
  BANDWIDTH  ──  max data per second (Gbps). Pipe DIAMETER.
  LATENCY    ──  one-way delay before data arrives (ms). Pipe LENGTH.
  RTT        ──  round-trip time = there-and-back latency (ping shows this).
  JITTER     ──  variation in latency (bad for real-time: voice, video, RDMA).
  PACKET LOSS──  % of packets dropped (forces retransmits → tanks effective throughput).
  BANDWIDTH-DELAY PRODUCT = bandwidth × RTT
             ──  bytes that must be "in flight" to keep a fat, long link full.
```

A subtle killer: on a lossy link, **latency and loss destroy effective bandwidth**. TCP's congestion control ([07](07)) backs off on loss and waits an RTT for ACKs — so a 10 Gbps link with high RTT and 1% loss might deliver a tiny fraction of its rated speed. Fast raw bandwidth ≠ fast real throughput.

### Fixing each

| Problem | Fix | Why |
|---|---|---|
| **Latency** (far users) | Multi-region, CDN/edge, anycast, smart DNS | Shorten distance/hops |
| **Latency** (many hops) | Fewer hops, faster routing, colocation | Each hop adds delay |
| **Bandwidth** (big transfers) | Fatter links, parallel streams, compression | More capacity in flight |
| **Loss/jitter** | Better links, QoS, FEC, lossless fabrics | Protect effective throughput |

### Why AI/HPC needs special hardware

Distributed training runs **collective operations** (all-reduce: every GPU sums its gradients with every other GPU's) every single step. That's massive, latency-sensitive, **east-west** (GPU-to-GPU) traffic. Ordinary TCP/IP over Ethernet has two problems here: too much **latency** (kernel networking, copies, interrupts) and CPU overhead. So HPC uses:

- **RDMA (Remote Direct Memory Access):** one machine's NIC writes directly into another machine's memory, **bypassing the CPU and kernel** — near-zero-copy, microsecond latency. This is the key idea.
- **InfiniBand:** a purpose-built lossless fabric with native RDMA — the gold standard for GPU clusters (very high bandwidth, very low latency).
- **RoCE (RDMA over Converged Ethernet):** RDMA on Ethernet, so you get RDMA benefits on (lossless-configured) Ethernet gear.
- **GPUDirect:** lets the NIC move data straight to/from GPU memory, skipping the host entirely.
- **NCCL:** NVIDIA's library that runs those collectives efficiently over InfiniBand/RoCE.
- On AWS, **EFA (Elastic Fabric Adapter)** brings RDMA-style low-latency networking to EC2/EKS GPU instances.

```
   ORDINARY PATH (slow for GPU-to-GPU):
   GPU-A → host RAM → CPU/kernel/TCP → NIC → ... → NIC → kernel → host RAM → GPU-B

   RDMA / GPUDirect PATH (fast):
   GPU-A memory ─── NIC ═══(InfiniBand/RoCE)═══ NIC ─── GPU-B memory
                (CPU and kernel bypassed; microsecond latency)
```

### The two AI latency/bandwidth metrics you'll be asked about

- **Time-to-first-token (TTFT):** how long before an LLM starts responding — a **latency** metric.
- **Token streaming speed (tokens/sec):** how fast tokens flow once started — a **bandwidth/throughput** metric.

Same request, two different networking concerns. Optimizing TTFT (place inference near the user, cut hops) is a *different* job from optimizing streaming throughput (fat pipes, batching).

> **✅ Check yourself before Rung 4:** Why does distributed GPU training care so intensely about *latency* between nodes, not just raw bandwidth — what happens on every training step?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which quantity |
|---|---|---|
| **Bandwidth / throughput** | Data per second (Gbps) | Capacity |
| **Latency** | Delay before data arrives (ms) | Delay |
| **RTT** | Round-trip latency | Delay |
| **Jitter** | Variation in latency | Delay stability |
| **Packet loss** | Dropped packets → retransmits | Kills effective throughput |
| **Bandwidth-delay product** | bandwidth × RTT (bytes in flight) | The interaction |
| **RDMA** | NIC writes remote memory, CPU-bypass | Ultra-low latency |
| **InfiniBand** | Lossless RDMA fabric | HPC interconnect |
| **RoCE** | RDMA over Ethernet | RDMA on Ethernet |
| **GPUDirect** | NIC ↔ GPU memory directly | Skip the host |
| **NCCL** | GPU collective-comms library | Uses the fabric |
| **EFA** | AWS RDMA-style adapter | RDMA on EKS/EC2 |
| **TTFT** | Time-to-first-token | Latency (AI) |

**Same-kind-of-thing groupings:** *latency, RTT, jitter, TTFT* are all "how soon / delay." *bandwidth, throughput, tokens/sec* are all "how much / capacity." *RDMA, InfiniBand, RoCE, GPUDirect, EFA, NCCL* are all "make GPU-to-GPU traffic fast and CPU-free."

---

## 🔬 Rung 5 — The Trace

**A distributed training step across 8 GPUs on 2 nodes — where latency and bandwidth each bite.**

```
── one training step ──
[8 GPUs] compute gradients in parallel  (compute-bound, fast)
   │
   ▼ ALL-REDUCE: every GPU must combine its gradients with every other's
[NCCL] orchestrates the collective
   │
   ├─ within a node: GPU↔GPU over NVLink (very fast)
   │
   └─ across nodes: GPU-A(node1) memory ══ EFA/RoCE/InfiniBand ══ GPU-B(node2) memory
         │  • LATENCY: every step waits for the slowest exchange
         │    → high inter-node latency = GPUs idle each step = low utilization
         │  • BANDWIDTH: gradients are large (GBs)
         │    → thin links = the exchange itself is slow
         ▼
[gradients synced] → GPUs apply the update → next step
                     (network delay is PURE overhead on every one of thousands of steps)
```

If inter-node **latency** is high, GPUs stall at the barrier every step (utilization craters). If inter-node **bandwidth** is thin, the gradient exchange itself is slow. RDMA/InfiniBand attacks *both* — low latency and high bandwidth with CPU bypass — which is why GPU clusters are built on it, not plain Ethernet.

> **✅ Check yourself before Rung 6:** In that step, if you doubled bandwidth but latency stayed high, would GPU utilization necessarily improve? Why or why not?

---

## ⚖️ Rung 6 — The Contrast

**Standard cloud networking (TCP/IP over Ethernet) vs HPC interconnects (RDMA/InfiniBand).**

| Property | TCP/IP over Ethernet | RDMA (InfiniBand/RoCE/EFA) |
|---|---|---|
| Latency | Milliseconds (kernel, copies) | Microseconds (kernel bypass) |
| CPU overhead | High (per packet) | Near zero |
| Data path | App→kernel→NIC→…→kernel→app | NIC ↔ remote memory directly |
| Cost/complexity | Cheap, ubiquitous | Expensive, specialized |
| Best for | Web, microservices, most apps | GPU training, HPC, low-latency trading |

**Bandwidth-fix vs latency-fix (the within-topic contrast):** CDNs/regions/anycast fix *latency*; fatter links/parallelism/compression fix *bandwidth*. Applying the wrong one wastes money and doesn't move the metric.

**When would I NOT reach for RDMA?** For ordinary microservices, web apps, and batch jobs, standard networking is fine — RDMA's cost and complexity only pay off for tightly-coupled, latency-sensitive parallel workloads (large-scale training, HPC simulation).

**One-sentence why-this-over-that:** *Diagnose whether you're latency- or bandwidth-bound first; use RDMA/InfiniBand only for tightly-coupled GPU/HPC workloads where microsecond GPU-to-GPU latency decides whether your expensive accelerators are utilized.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: measure latency and bandwidth separately

> **Prediction:** "If I `ping` a host and separately run `iperf3`, `ping` reports latency (RTT, unaffected by pipe width) and `iperf3` reports bandwidth (throughput, unaffected by distance) — two independent numbers, BECAUSE they measure delay vs capacity."

```bash
# Latency (RTT): tiny packets, round-trip time
ping -c 5 target-host
# 5 packets, time=1.2 ms ... rtt min/avg/max = 1.0/1.2/1.5 ms   <- DELAY

# Bandwidth: sustained throughput (needs iperf3 server on the target)
iperf3 -c target-host -t 10
# [SUM] ... 9.41 Gbits/sec receiver                              <- CAPACITY
```

**Verify:** you get an RTT in ms *and* a throughput in Gbps — two separate quantities. A nearby host can have low RTT but a thin link (low iperf3), or a distant host a fat link but high RTT. Seeing both proves they're independent.

### Example 2 — Edge/failure case: loss+latency crush effective throughput

> **Prediction:** "If I add latency and packet loss to a link, its *effective* TCP throughput collapses even though the raw link speed is unchanged, BECAUSE TCP waits an RTT for ACKs and backs off on loss."

```bash
# Baseline throughput:
iperf3 -c target-host -t 10 | tail -3
# ~9.4 Gbits/sec

# Inject 100ms latency + 1% loss on the egress interface (Linux tc/netem):
sudo tc qdisc add dev eth0 root netem delay 100ms loss 1%
iperf3 -c target-host -t 10 | tail -3
# ~50-200 Mbits/sec   <- effective throughput CRATERS despite the same link
sudo tc qdisc del dev eth0 root         # remove the impairment
```

**Verify:** effective throughput drops enormously with added RTT+loss, though the physical link never changed. This is why "we have a 10 Gbps link" doesn't guarantee 10 Gbps of useful transfer — and why lossless fabrics matter for HPC.

### Example 3 — Kubernetes/AI-flavored: confirm GPU nodes have RDMA/EFA fabric

> **Prediction:** "If my EKS GPU nodes are RDMA-capable (EFA), I'll see an EFA/RDMA device present and NCCL will use it; without it, cross-node training falls back to slow TCP, BECAUSE the fast path requires the fabric hardware + driver."

```bash
# On a GPU node (or via a pod with the EFA device), check for the RDMA/EFA device:
kubectl get nodes -o json | jq '.items[].status.allocatable | keys[] | select(test("efa|rdma"))'
# "vpc.amazonaws.com/efa"        <- EFA advertised as an allocatable resource

# Inside a training pod, confirm NCCL sees the fabric (env + probe):
kubectl exec deploy/trainer -- sh -c 'ls /dev/infiniband 2>/dev/null; echo NCCL_DEBUG=$NCCL_DEBUG'
# /dev/infiniband/uverbs0        <- RDMA verbs device present
# NCCL logs (NCCL_DEBUG=INFO) will show: "NET/OFI Selected Provider is efa"
```

**Verify:** the node advertises an `efa`/`rdma` resource and the pod sees an InfiniBand/EFA device. If absent, cross-node NCCL collectives run over TCP — dramatically slower, and your GPU utilization tanks on multi-node jobs. This is the concrete "why is my distributed training slow" checklist item.

---

## 🏔 Capstone — Compress It

**One sentence:** Bandwidth is how much data flows per second and latency is how long before the first bit arrives — independent quantities you fix differently (shorten distance/hops for latency, widen/parallelize for bandwidth) — and AI/HPC pushes both to the limit with RDMA fabrics (InfiniBand/RoCE/EFA) so GPU-to-GPU traffic doesn't leave expensive accelerators idle.

**Explain it to a beginner in 3 sentences:**
1. Bandwidth is the width of the pipe (how much water flows) and latency is the length of the pipe (how long the first drop takes) — they're different, so "make it faster" needs you to say which one.
2. You lower latency by moving things closer (CDNs, regions, fewer hops) and raise bandwidth by using fatter links or more parallel connections; using the wrong fix wastes money.
3. GPU clusters care about both to the extreme, because every training step the GPUs must swap data, so they use special hardware (RDMA/InfiniBand) that lets network cards write directly into each other's memory in microseconds, bypassing the CPU.

**Sub-parts mapped to the one idea (how much vs how soon are different):**
```
Latency (how soon)      → distance/hops; fix with region/CDN/anycast/colocation
Bandwidth (how much)    → link width/parallelism; fix with fatter pipes
RTT/jitter/loss         → delay quality; loss+latency crush effective throughput
RDMA/InfiniBand/RoCE/EFA→ microsecond, CPU-free GPU-to-GPU (attacks both)
TTFT vs tokens/sec      → latency vs bandwidth, same AI request
```

**Which rung to revisit hands-on:** Rung 7 Example 2 — watching netem crush throughput teaches, viscerally, that raw link speed and useful throughput are not the same thing.

---

## Related concepts

- [CDN, Edge & WAF](21-cdn-edge-waf.md) — the classic latency fix (serve from nearby).
- [The Transport Layer — TCP & UDP](07-transport-layer-tcp-udp.md) — why loss and RTT throttle TCP throughput.
- [Routing & Forwarding](08-routing-and-forwarding.md) — hops and paths that add latency.
- [Network Observability](32-network-observability.md) — measuring latency, throughput, jitter, and loss.
- [What is a Network & How the Internet Works](01-what-is-a-network-and-the-internet.md) — bandwidth units and physical media.
