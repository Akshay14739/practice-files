# Network Observability — Metrics, Logs & Traces

*You can't fix what you can't see. How to make the network's behavior visible — from a single packet to a slow microservice buried in a 20-hop request.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Network observability: the three pillars (**metrics**, **logs**, **traces**) applied to networking, and the toolbox — `tcpdump`/Wireshark, `ss`, `mtr`, `iperf3`, VPC flow logs, eBPF/Hubble, Prometheus/Grafana, and distributed tracing (Jaeger).

**Why did it land on my desk?** "The app is slow" — but *which* hop? A request touches DNS, an ALB, an Ingress, kube-proxy, ten microservices, and a database. Without visibility you're guessing. And after an incident, security asks "what connected to what, when?" — a question only logs can answer. Observability turns "it's slow/broken somewhere" into "it's *this* hop, *this* reason."

**What do I already know?** You understand the request path end-to-end (DNS → TLS → LB → kube-proxy → CNI → pod, chapters [09](09-dns.md)–[29](29-service-mesh-and-sidecars.md)), and bandwidth/latency metrics ([31-bandwidth-latency-ai-hpc-networking.md](31-bandwidth-latency-ai-hpc-networking.md)). This chapter is how you *see* all of it.

---

## 🔥 Rung 1 — The Pain

A distributed system is opaque by default. When something's wrong you face:

- **"Which hop is slow?"** A user request fans out through many services; total latency is 800 ms but you have no idea whether it's DNS, the network, or one slow downstream call. Guess wrong and you optimize the wrong thing.
- **"What actually happened?"** After a breach or outage, you need a record of every connection — who talked to whom, when, allowed or denied. Without logs, the incident is unreconstructable.
- **"Is it the network or the app?"** A timeout could be packet loss, a saturated link, a DNS failure, a dropped-by-policy connection, or a bug. You can't tell them apart by staring at application logs.
- **"It works on my machine."** Intermittent, load-dependent, or one-node-only failures are invisible until you can watch real traffic.

Before observability, debugging distributed networking was folklore and `printf`. You need to *measure* what's happening on the wire.

**Who feels it most?** On-call engineers at 3 AM, and security teams doing post-incident forensics.

> **✅ Check yourself before Rung 2:** If a request through ten microservices takes 800 ms, why can't the caller's logs alone tell you which service caused the delay?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **Network observability means capturing three complementary signals — metrics (aggregate numbers over time), logs (individual events for forensics), and traces (one request followed across every hop) — so you can answer "how healthy," "what happened," and "where's the delay."**

Everything derives from "three signals, three questions":

- *Metrics* → "how healthy, trending which way?" (latency, throughput, loss, errors, connections) — cheap, aggregated, drives alerts and autoscaling.
- *Logs* → "what exactly happened at this moment?" (VPC flow logs, connection logs) — detailed, per-event, for audit and forensics.
- *Traces* → "where in this specific request did time go?" (a request's path across services) — pinpoints the slow hop.

No single signal is enough; together they cover health, history, and causality.

> **✅ Check yourself before Rung 3:** Match each question to a pillar: "who connected to the DB at 2 AM?", "is P99 latency creeping up this week?", "which of 10 services made this request slow?"

---

## ⚙️ Rung 3 — The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> Imagine running a city where deliveries keep arriving late and you must figure out why. This section is about the three kinds of records you keep, plus the street-level tools for when you need to watch the traffic yourself.
>
> **The three kinds of records:**
>
> - **Metrics** are like the city's **dashboard of gauges**: average trip times, how many deliveries per hour, what fraction fail. Cheap to collect, great for spotting trends and sounding alarms ("trips are getting slower this week!"). Tools with names like Prometheus and Grafana draw these gauges and graphs.
> - **Logs** are the **doorman's ledger**: one line per event — who visited whom, when, and whether they were let in or turned away. Essential after a burglary or an outage, when you must reconstruct exactly what happened. In the cloud these include "flow logs" — a ledger of every network connection.
> - **Traces** follow **one single delivery** door-to-door with a stopwatch, recording how long it spent at each stop. When one trip took 800 milliseconds, the trace shows *which* stop ate the time. Tools: Jaeger, OpenTelemetry — and a service mesh (last chapter's bodyguards) produces these automatically.
>
> **The street-level toolbox** — for when records aren't enough and you need to stand on the corner watching actual vehicles (packets — the little parcels all internet data travels in):
>
> - **tcpdump / Wireshark** — film the traffic itself, parcel by parcel: watch two computers shake hands, or see a "go away" note that explains a refused connection.
> - **ss** — list every conversation your machine currently has open, and who's waiting for calls.
> - **mtr** — send test cars along the route and report the delay at *each* junction, so you see exactly where the road degrades.
> - **iperf3** — a stopwatch-and-scale test of how much a road can really carry.
> - **dig** — check the address-lookup service (DNS, the internet's phone book) — is it right, and is it slow?
> - **curl -w** — time one single trip with a breakdown: address lookup, connecting, secure handshake, first byte back.
>
> **The clever modern shortcut: eBPF.** Old-style traffic filming is expensive and only shows anonymous license plates (IP numbers). eBPF plants tiny safe observers *inside* the engine of the operating system, so tools like Cilium Hubble can report, cheaply and by name: "the frontend app asked the api app for the orders page — allowed — took 12 ms."
>
> **How the records work together:** the dashboard says something's slow → the stopwatch trace points to the database stop → the ledger shows repeated retries there → filming the parcels confirms some were being lost. Each layer narrows the search; the street-level view proves the cause.

*Now the original technical deep-dive — the same ideas, in precise form:*

### The three pillars and their tools

```
┌─ METRICS ─ aggregate numbers over time ────────────────────────────┐
│  latency (P50/P99), throughput, packet loss, error rate,            │
│  active connections, TCP retransmits, DNS query time                │
│  tools: Prometheus + Grafana, node_exporter, blackbox_exporter,     │
│         CloudWatch, service-mesh telemetry                          │
│  answers: "how healthy? trending? alert me."                        │
├─ LOGS ─ individual events, kept for forensics ─────────────────────┤
│  VPC Flow Logs (every connection: src, dst, port, action, bytes),  │
│  connection/audit logs, WAF logs, load-balancer access logs        │
│  tools: CloudWatch Logs, S3, ELK/Loki, Hubble flow logs            │
│  answers: "what exactly happened, and when? who talked to whom?"    │
├─ TRACES ─ one request followed across every hop ───────────────────┤
│  a trace = a tree of spans (one span per service hop) with timing  │
│  tools: Jaeger, Tempo, OpenTelemetry; auto-emitted by a mesh       │
│  answers: "which hop in THIS request was slow?"                    │
└────────────────────────────────────────────────────────────────────┘
```

### The packet-level toolbox (when you need the wire itself)

- **`tcpdump` / Wireshark** — capture and inspect actual packets: see the SYN/SYN-ACK/ACK handshake ([07](07)), a TLS ClientHello ([11](11)), a DNS query and its answer, or a `RST` that reveals a refused connection.
- **`ss` / `netstat`** — live socket/connection state (who's listening, established connections, retransmit queues).
- **`mtr`** — `traceroute` + `ping` combined: per-hop latency and loss along the path, so you see *which* hop degrades ([08](08)).
- **`iperf3`** — measure raw bandwidth between two points ([31](31)).
- **`dig`** — DNS timing and resolution correctness ([09](09)).
- **`curl -w`** — a per-request timing breakdown (DNS, connect, TLS, first byte) — brilliant for "where did the 800 ms go" on a single call.

### eBPF: observability without the overhead

Traditional packet capture is heavy and sees only IPs. **eBPF** ([22](22-sdn-software-defined-networking.md)) runs safe programs in the kernel datapath, so tools like **Cilium Hubble** give **identity-aware, L7-aware** flow visibility for Kubernetes — "pod `frontend` → service `api` GET /orders, allowed, 12 ms" — across the whole cluster, cheaply, with pod names instead of raw IPs.

```
   A slow request, seen three ways:
   METRIC:  api P99 latency spiked to 900ms at 14:03  → "something's wrong with api"
   TRACE:   span api→db = 850ms of the 900ms          → "it's the DB call"
   LOG:     db flow log shows connection retries       → "the DB link was dropping packets"
   PACKET:  tcpdump on db shows TCP retransmissions     → confirmed: packet loss
```

Each pillar narrows the search; packet capture confirms the root cause.

> **✅ Check yourself before Rung 4:** A metric tells you "api latency spiked." Why do you then need a *trace* rather than another metric to find the cause?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which pillar / role |
|---|---|---|
| **Metrics** | Aggregated numbers over time | Health & alerting |
| **Logs** | Individual timestamped events | Forensics & audit |
| **Traces** | One request across all hops | Latency attribution |
| **Span** | One hop's slice of a trace | Trace building block |
| **VPC Flow Logs** | Per-connection records (src/dst/port/action) | Network logs |
| **tcpdump / Wireshark** | Packet capture & inspection | Wire-level truth |
| **ss / netstat** | Live socket/connection state | Point-in-time state |
| **mtr** | Per-hop latency + loss | Path diagnosis |
| **iperf3** | Bandwidth measurement | Throughput test |
| **eBPF / Hubble** | Kernel-level, identity-aware flow visibility | K8s network observability |
| **RED / USE** | Metric methodologies (Rate/Errors/Duration; Utilization/Saturation/Errors) | What to measure |
| **OpenTelemetry** | Vendor-neutral telemetry standard | Emitting traces/metrics |

**Same-kind-of-thing groupings:** *metrics, logs, traces* are the three pillars. *tcpdump, ss, mtr, iperf3, dig, curl -w* are all "point tools you run on demand." *Prometheus, Hubble, Jaeger, flow logs* are all "continuous collectors." *RED and USE* are both "methods for choosing which metrics matter."

---

## 🔬 Rung 5 — The Trace (fittingly)

**"The checkout page is slow." Follow the three pillars to the root cause.**

```
1. METRIC (Grafana): checkout service P99 jumped 200ms → 900ms at 14:03.
   → narrows WHEN and WHICH service, but not WHY.
        │
        ▼
2. TRACE (Jaeger): open a slow checkout trace. Spans:
      checkout        900ms
      ├─ auth          15ms
      ├─ inventory     20ms
      └─ payments     840ms   ◀── the culprit hop
        │
        ▼
3. TRACE deeper: payments span shows payments→bank-gateway = 820ms.
   → the delay is the outbound call to an external gateway.
        │
        ▼
4. LOG (VPC flow logs / Hubble): payments→bank-gateway connections show
   retries and elevated latency starting 14:03.
        │
        ▼
5. PACKET (tcpdump on a payments pod): repeated TCP retransmissions to the
   gateway IP → packet loss / gateway degradation on that path.
        │
        ▼
   ROOT CAUSE: the external payment gateway's network path degraded at 14:03.
   Fix: failover to a secondary gateway; alert on payments-span latency.
```

Metrics found *when/where*, traces found *which hop*, logs/packets found *why*. That funnel — broad to specific — is the whole discipline.

> **✅ Check yourself before Rung 6:** In that funnel, which pillar would you set an *alert* on so you're paged before users complain, and which do you only reach for *after* you know where to look?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: application logs + guesswork (no network observability).**

| Question | App logs only | Full observability |
|---|---|---|
| "Which of 10 services is slow?" | ❌ guess | ✅ trace pinpoints the span |
| "Is P99 trending up?" | ❌ | ✅ metrics dashboard |
| "Who connected to the DB at 2 AM?" | ❌ | ✅ flow logs |
| "Is it packet loss or a bug?" | ❌ | ✅ mtr/tcpdump |
| Cost / overhead | low | metrics cheap; packet capture heavy |

**Metrics vs traces vs logs (the within-topic contrast):** metrics are cheap and continuous but can't explain a single request; traces explain one request but you sample them (too expensive to trace 100%); logs are detailed but voluminous and costly to keep. You use all three at their strengths — metrics to *alert*, traces to *localize*, logs/packets to *confirm*.

**When would I NOT reach for packet capture?** Routinely — `tcpdump`/Wireshark is heavy and privacy-sensitive; it's the *last* resort after metrics/traces/logs have narrowed the problem to a specific hop, not a first move.

**One-sentence why-this-over-that:** *Instrument metrics for continuous health/alerting, traces to attribute latency across hops, and logs/packet-capture for forensics and root-cause — because no single signal answers "how healthy," "what happened," and "where's the delay" at once.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: break down where a single request spends its time

> **Prediction:** "If I use `curl -w`, I'll see the request's time split into DNS, TCP connect, TLS, and time-to-first-byte, so I can tell whether slowness is name resolution, the network, or the server, BECAUSE each phase is timed independently."

```bash
curl -s -o /dev/null -w \
  'dns:%{time_namelookup}  connect:%{time_connect}  tls:%{time_appconnect}  ttfb:%{time_starttransfer}  total:%{time_total}\n' \
  https://api.example.com/health
# dns:0.031  connect:0.052  tls:0.121  ttfb:0.640  total:0.642
#            ^ tls-connect ~0.07s      ^ server took 0.64-0.12 = ~0.52s to first byte
```

**Verify:** you get a phase-by-phase breakdown. If `time_namelookup` is huge, it's DNS ([09](09)/[26](26-kubernetes-dns-service-discovery.md)); if `time_starttransfer` dominates, it's the server, not the network. One command triages the whole request.

### Example 2 — Edge/failure case: find WHICH hop loses packets with mtr

> **Prediction:** "If a path is losing packets at one hop, `mtr` will show loss concentrated at that hop (and beyond), so I can localize the bad link, BECAUSE mtr probes every hop's RTT and loss continuously."

```bash
mtr -rwzc 50 target-host           # 50 cycles, report mode
# HOST                    Loss%   Snt   Last   Avg  Best  Wrst
# 1. gateway               0.0%    50    0.4    0.5   0.3   1.1
# 2. isp-router            0.0%    50    5.2    5.5   4.9   9.0
# 3. congested-hop        18.0%    50   45.3   60.1  20.1 210.4   ◀── loss + latency spike here
# 4. target-host          18.0%    50   46.0   61.2  21.0 205.7   (inherited from hop 3)
```

**Verify:** loss appears at a specific hop and persists downstream — that hop is your suspect. (Note: some routers deprioritize ICMP, so isolated loss at a *middle* hop that doesn't propagate to the destination can be a false alarm — loss that continues to the *final* hop is the real signal.)

### Example 3 — Kubernetes-flavored: capture a pod's traffic and watch flows with Hubble

> **Prediction:** "If I capture packets on a specific pod (via an ephemeral debug container) I'll see its real traffic, and eBPF Hubble will show identity-aware flows (pod→service, allowed/denied) without raw IP guessing, BECAUSE eBPF observes the kernel datapath with pod identity."

```bash
# Packet capture scoped to one pod, via an ephemeral debug container sharing its netns:
kubectl debug -it web-pod --image=nicolaka/netshoot --target=web -- \
  tcpdump -ni any -c 20 'tcp and port 80'
# 14:22:01 IP 10.244.1.7.51234 > 10.96.0.50.80: Flags [S] ...   <- SYN to the Service VIP
# 14:22:01 IP 10.96.0.50.80 > 10.244.1.7.51234: Flags [S.] ...  <- SYN-ACK back

# Identity-aware flows across the cluster (if Cilium/Hubble is installed):
hubble observe --pod default/web-pod --last 10
# default/web-pod:51234 -> default/api-svc:80  to-endpoint FORWARDED (TCP Flags: SYN)
# default/web-pod -> kube-system/coredns:53    to-endpoint FORWARDED (UDP)
# default/web-pod -> default/db:5432           DROPPED (Policy denied)   ◀── a NetworkPolicy drop, by NAME
```

**Verify:** tcpdump shows the pod's real SYN/SYN-ACK to the Service VIP; Hubble shows flows labeled with pod/service *names* and whether policy FORWARDED or DROPPED them. The `DROPPED (Policy denied)` line is how you debug "why can't my pod reach X" from [28](28-kubernetes-network-policies.md) in seconds instead of guessing.

---

## 🏔 Capstone — Compress It

**One sentence:** Network observability captures three complementary signals — metrics (aggregate health, for alerting), logs (per-connection events, for forensics), and traces (one request across every hop, for latency attribution) — backed by point tools (tcpdump, ss, mtr, iperf3, curl -w) and eBPF flow visibility (Hubble), so you can answer how healthy, what happened, and where the delay is.

**Explain it to a beginner in 3 sentences:**
1. Distributed systems are opaque, so you collect three kinds of signal: metrics (numbers over time), logs (a record of individual events), and traces (the journey of one request through every service).
2. Metrics tell you *that* something is wrong and page you; a trace tells you *which* of many services caused it; logs and packet captures tell you *exactly* what happened and why.
3. In Kubernetes, eBPF tools like Hubble make this even better by showing flows with pod names and whether traffic was allowed or dropped, so you debug by identity instead of guessing at IP addresses.

**Sub-parts mapped to the one idea (three signals, three questions):**
```
Metrics  → "how healthy / trending?"  (Prometheus/Grafana, alerts, autoscaling)
Logs     → "what happened / who talked to whom?"  (VPC flow logs, Hubble, audit)
Traces   → "which hop was slow?"  (Jaeger/OTel spans, mesh-emitted)
Point tools → tcpdump/ss/mtr/iperf3/dig/curl -w (on-demand truth)
eBPF/Hubble → identity-aware, L7 flow visibility for K8s
funnel    → metrics (when/where) → traces (which hop) → logs/packets (why)
```

**Which rung to revisit hands-on:** Rung 7 Example 3 — watching Hubble label a `DROPPED (Policy denied)` flow by pod name turns "networking is a black box" into "I can see every flow."

---

## Related concepts

- [Performance & Monitoring](../Linux/21-performance-monitoring.md) — host-level tools (strace, lsof, dmesg) that complement network signals.
- [The Transport Layer — TCP & UDP](07-transport-layer-tcp-udp.md) — the handshake and retransmits tcpdump reveals.
- [Service Mesh & Sidecars](29-service-mesh-and-sidecars.md) — the free metrics and traces a mesh emits.
- [Kubernetes Network Policies](28-kubernetes-network-policies.md) — the drops Hubble helps you debug.
- [Bandwidth, Latency & AI/HPC Networking](31-bandwidth-latency-ai-hpc-networking.md) — the latency/throughput metrics you're measuring.
- [SDN — Software-Defined Networking](22-sdn-software-defined-networking.md) — eBPF as a programmable, observable datapath.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If a request through ten microservices takes 800 ms, why can't the caller's logs alone tell you which service caused the delay?

**A:** Because the caller's logs only see the request's total time from its own vantage point — they record "I called the next service and got a response 800 ms later," with no visibility into how that time was divided across the ten downstream hops (DNS, the network, or any one slow service). The delay could be packet loss, a saturated link, a DNS failure, a policy-dropped connection, or a bug in service number seven, and application logs can't tell those apart. You need a **trace** — one request followed across every hop as a tree of timed spans — to attribute the 800 ms to the specific hop where the time actually went.

### Before Rung 3
**Q:** Match each question to a pillar: "who connected to the DB at 2 AM?", "is P99 latency creeping up this week?", "which of 10 services made this request slow?"

**A:** "Who connected to the DB at 2 AM?" → **logs** (e.g. VPC flow logs — individual per-connection events kept for forensics and audit: src, dst, port, action). "Is P99 latency creeping up this week?" → **metrics** (aggregate numbers over time — cheap, continuous, trend-able, and what you alert on). "Which of 10 services made this request slow?" → **traces** (one specific request followed across every hop, with a timed span per service, pinpointing where the delay went). That's the file's "three signals, three questions": what happened, how healthy, where's the delay.

### Before Rung 4
**Q:** A metric tells you "api latency spiked." Why do you then need a *trace* rather than another metric to find the cause?

**A:** Because metrics are **aggregates**: they compress many requests into one number over time, which tells you *when* and *which service* degraded but destroys the per-request detail of where the time went inside any individual call. Another metric would just be another aggregate view of the same symptom. A trace follows **one specific slow request** across every hop as a tree of timed spans — e.g. "span api→db = 850 ms of the 900 ms" — which is the only signal that attributes the delay to a particular downstream hop. Then logs and packet capture (flow logs showing retries, tcpdump showing TCP retransmissions) confirm *why* that hop was slow.

### Before Rung 6
**Q:** In that funnel, which pillar would you set an *alert* on so you're paged before users complain, and which do you only reach for *after* you know where to look?

**A:** You alert on **metrics** — they're cheap, continuous, aggregated signals (like checkout P99 jumping 200 ms → 900 ms) that are always being collected, so Prometheus/Grafana can page you the moment a threshold trips. **Packet capture (tcpdump/Wireshark)** is what you reach for only *after* the other pillars have narrowed the problem to a specific hop — it's heavy and privacy-sensitive, the last resort that confirms root cause (e.g. TCP retransmissions proving packet loss), never a first move or a continuous alert source. The funnel runs broad-to-specific: metrics alert (when/where) → traces localize (which hop) → logs/packets confirm (why).
