# Logging & Monitoring, Climbed the Ladder 🪜
### Section 3 of the CKA — deriving how you *see* into a running cluster

> A compact section, but `kubectl top` and `kubectl logs` are guaranteed exam muscle memory. We climb from **the pain of a black-box cluster** → **the two-windows idea** → **the data paths** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** The two built-in ways to observe a cluster: live resource usage (`kubectl top`, via the Metrics Server) and application output (`kubectl logs`).

**Why did it land on my desk?** Every troubleshooting task (30% of the CKA) starts with "look at the metrics and the logs." These two commands are reflexes you need under a 2-hour clock.

**What do I already know?** Probably `kubectl logs`. What's fuzzy: *where* the numbers in `kubectl top` come from, why it needs a separate install, and why a crashed pod's logs seem empty (the `--previous` trick).

---

# RUNG 1 — The Pain 🔥
### *Why does cluster observability exist at all?*

A running cluster is a black box. Without a window in:

```
THE BLACK-BOX PAIN
  "which pod is eating all the memory?"  → no idea; you SSH to nodes and run top by hand
  "why did the app just crash-loop?"      → the container's gone; its output vanished with it
  "is this node about to fall over?"      → you find out when pods start getting OOMKilled
```

**Before / without it:** SSH to each node, `docker logs` per container, eyeball `top` — none of which correlates to *pods*, and all of which disappears when a container restarts. And **Kubernetes ships no full monitoring stack** — you must add one.

**What breaks without it:** you can't size requests/limits ([Section 2](02-scheduling.md)), can't drive autoscaling, and can't debug a `CrashLoopBackOff` because the failing container's output is already gone.

**Who feels it most?** Whoever is on call — you get paged for a symptom and need the metrics and the logs to find the cause fast.

> **✅ Check yourself before Rung 2:** Why is "just run `docker logs` on the node" a poor answer in Kubernetes? (Hint: what happens to a crashed container, and does the node view map to *pods*?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Kubernetes gives you two windows into a live cluster — the **Metrics Server** aggregates real-time CPU/memory from every kubelet's built-in cAdvisor for `kubectl top`, and the **container runtime** captures each container's stdout/stderr for `kubectl logs` — and by default neither keeps any history.**

Derivations:
- *"Metrics Server aggregates… for `kubectl top`"* → `top` fails with "Metrics API not available" until you **install** the Metrics Server; it's not there by default.
- *"from every kubelet's cAdvisor"* → the metric source already lives *inside* the kubelet; the Metrics Server just scrapes and sums.
- *"runtime captures stdout/stderr"* → `kubectl logs` = your app's stdout. If the app logs to a *file* inside the container, `kubectl logs` won't see it.
- *"neither keeps history"* → Metrics Server is **in-memory** (no graphs/past data), and a restarted container's live logs start fresh — hence **`--previous`** to read the dead one.

> **✅ Check yourself before Rung 3:** If `kubectl top pod` returns numbers but `kubectl top node` was empty a minute ago, what changed — and what does that tell you about *where* the data comes from and *when* it's ready?

---

# RUNG 3 — The Machinery ⚙️
### *The two data paths — go slow*

## (A) The metrics path

```
  container ──▶ cAdvisor (built INTO each kubelet) ──exposes──▶ kubelet API :10250
                                                                    │  Metrics Server scrapes every node
                                                                    ▼
                                        Metrics Server  (aggregates, IN MEMORY only)
                                                                    │  serves the Metrics API
                                                                    ▼
                                        kubectl top node / kubectl top pod
```

Every node's **kubelet** embeds **cAdvisor (Container Advisor)**, which measures per-container CPU/memory and exposes it on the kubelet API. The **Metrics Server** (one per cluster, lightweight, **in-memory**) scrapes all nodes and serves the aggregated **Metrics API** that `kubectl top` reads. No history — for that you'd add **Prometheus** or **EFK** (the deprecated **Heapster** was folded into Metrics Server).

```bash
# deploy it (not present by default):
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# minikube: minikube addons enable metrics-server
# give it ~1–2 min to scrape before `top` works
```
> ⚠️ In kubeadm/lab clusters the kubelet serving cert is self-signed, so the Metrics Server Deployment often needs `--kubelet-insecure-tls` in its args. **Never** use that in production.

```bash
kubectl top node                 # CPU (millicores) + memory per node
kubectl top pod -A               # all namespaces
kubectl top pod --sort-by=cpu    # busiest first
kubectl top pod --containers     # break down by container
```

## (B) The logs path

Apps write to **stdout/stderr**; the **container runtime** captures that stream; the kubelet exposes it; `kubectl logs` reads it (same idea as `docker logs -f`).

```bash
kubectl logs -f my-pod                  # live tail
kubectl logs my-pod --previous          # the CRASHED previous container (CrashLoopBackOff!)
kubectl logs my-pod --since=1h --tail=50
# multi-container pod → you MUST name the container:
kubectl logs my-pod -c event-simulator  # (else: "a container name must be specified")
kubectl logs my-pod --all-containers
```

> 🎯 **CKA tip:** `--previous` (`-p`) is the single most useful log flag. A `CrashLoopBackOff` pod's *current* container may have no logs yet — the *previous, crashed* one holds the actual error. Always pair `kubectl logs` (app errors) with `kubectl describe pod` (Events + Last State = scheduling/runtime errors).

> **✅ Check yourself before Rung 4:** Name the component that (1) *measures* CPU/memory, (2) *aggregates* it cluster-wide, and (3) *captures* your app's log lines. Which one is in-memory-only, and what's the consequence?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which path |
|---|---|---|
| **cAdvisor** | Metric collector built into every kubelet | Metrics — the source |
| **Metrics Server** | Cluster-wide aggregator, in-memory, serves Metrics API | Metrics — the hub |
| **Metrics API** | The API `kubectl top` reads | Metrics — the interface |
| **`kubectl top`** | CLI for live node/pod CPU+memory | Metrics — the window |
| **Heapster** | Old aggregator, **deprecated** → Metrics Server | Metrics (history) |
| **Prometheus / EFK** | Full historical monitoring stacks (add-on) | Metrics (history) |
| **stdout/stderr** | The stream `kubectl logs` shows | Logs — the source |
| **`kubectl logs -c`** | Pick a container in a multi-container pod | Logs |
| **`--previous` / `-p`** | Logs from the crashed prior container | Logs (debugging) |

**The unlock:** two independent pipelines — **metrics** (cAdvisor → Metrics Server → `top`) and **logs** (stdout → runtime → `logs`). They don't share plumbing; `top` needs an install, `logs` works out of the box.

> **✅ Check yourself before Rung 5:** `kubectl top` errors but `kubectl logs` works fine. Which pipeline is broken, and what's the fix?

---

# RUNG 5 — The Trace 🎬

**Trace A — "Which pod uses the most memory?"**
1. You run `kubectl top pod --sort-by=memory`.
2. kubectl calls the **Metrics API** on the API server.
3. That's served by the **Metrics Server**, which returns its latest in-memory snapshot.
4. That snapshot was built by **scraping each node's kubelet/cAdvisor**.
5. kubectl sorts and prints — top row = biggest memory user. (If step 3 has no data yet, you get "Metrics API not available" — it hasn't scraped, or isn't installed.)

**Trace B — "Why did webapp crash-loop?"**
1. `kubectl get pod webapp` → `CrashLoopBackOff`, `RESTARTS: 5`.
2. `kubectl logs webapp` → empty/partial (the *current* attempt just started).
3. `kubectl logs webapp --previous` → the **runtime's captured stderr of the dead container** shows the real panic ("config key missing").
4. `kubectl describe pod webapp` confirms `Last State: Terminated, Reason: Error`. Cause found — fix the config ([Section 4](04-application-lifecycle-management.md)).

> **✅ Check yourself before Rung 6:** In Trace B, why did step 2 look empty while step 3 had the error? What does that say about where a restarted container's logs go?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **Metrics Server** | **Prometheus / EFK** | live + in-memory, no history vs full historical graphs/alerting |
| **`kubectl top`** | **`kubectl describe` (resources)** | *actual* current usage vs *requested/limit* configuration |
| **`kubectl logs`** | **`kubectl describe pod`** | *app* errors (stdout) vs *scheduling/runtime* errors (Events, Last State) |
| **`logs` (current)** | **`logs --previous`** | this container's run vs the crashed prior run |

**When NOT to rely on Metrics Server:** anything needing history, dashboards, or alerting — that's Prometheus/EFK territory. Metrics Server exists to feed `kubectl top` and the autoscalers, nothing more.

**One-sentence "why this over that":**
> Use `kubectl top` + Metrics Server for a fast live snapshot and to size/autoscale; use `kubectl logs --previous` + `describe` to find *why* a pod broke; reach for Prometheus/EFK only when you need history.

> **✅ Check yourself before Rung 7:** A pod's `kubectl top` shows low CPU but it's still slow. Name one thing `top` won't tell you that `logs` or `describe` might.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — `top` fails until the Metrics Server has scraped

> **My prediction:** "If I run `kubectl top pod` on a fresh cluster, it errors with *Metrics API not available*; after I deploy the Metrics Server and wait ~1 min, it returns numbers — *because* the Metrics API has no server behind it until then."

```bash
kubectl top pod                         # error
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top node ; kubectl top pod --sort-by=memory
```
**Verify:** numbers appear after the rollout + a short wait. Still failing? `kubectl -n kube-system logs deploy/metrics-server` — usually the `--kubelet-insecure-tls` cert issue.

## Prediction 2 — A multi-container pod demands `-c`

> **My prediction:** "If I `kubectl logs` a two-container pod without `-c`, it errors and lists the container names; adding `-c <name>` returns that container's logs — *because* logs are per-container and Kubernetes won't guess which one."

```bash
kubectl logs webapp-2                   # error: "a container name must be specified"
kubectl get pod webapp-2 -o jsonpath='{.spec.containers[*].name}{"\n"}'
kubectl logs webapp-2 -c webapp | grep -i warn
```
**Verify:** the error lists the names; `-c` returns logs. `--all-containers` merges them.

## Prediction 3 — `--previous` reveals the crash cause

> **My prediction:** "If a pod is `CrashLoopBackOff`, plain `logs` is thin but `logs --previous` shows the real error — *because* the current container just (re)started, while the previous one is the one that actually failed."

```bash
kubectl get pod webapp                  # CrashLoopBackOff, RESTARTS climbing
kubectl logs webapp                     # little/nothing
kubectl logs webapp --previous          # the actual panic/stacktrace
kubectl describe pod webapp | grep -A3 "Last State"
```
**Verify:** `--previous` shows the failure; `describe` confirms `Reason`. That pair localizes almost any crash.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> `kubectl top` reads live CPU/memory that the Metrics Server aggregates from every kubelet's cAdvisor (in-memory, no history), while `kubectl logs` streams a container's stdout/stderr — use `--previous` to read a crashed container and `describe` for scheduling/runtime errors.

**Explain it to a beginner in 3 sentences:**
> 1. Kubernetes doesn't ship monitoring, so you install a small Metrics Server that gathers CPU/memory from every node and powers `kubectl top`.
> 2. To see what an app printed, `kubectl logs` shows its output — and `--previous` recovers the output of a container that already crashed.
> 3. Metrics and logs are separate pipelines with no memory of the past, so for history you add Prometheus or EFK.

**Which rung to revisit hands-on?** Rung 7 Prediction 3 — the `--previous` reflex is the one that saves you on a `CrashLoopBackOff` exam task.

---

## 🎯 CKA exam tips & quick notes

- **`kubectl top`** needs the **Metrics Server running** + ~1 min. Sort `--sort-by=cpu|memory`; scope `-A`/`-n`.
- **`kubectl logs -c <container>`** is mandatory for multi-container pods.
- **`kubectl logs --previous`** = crashed container — your `CrashLoopBackOff` go-to.
- Metrics Server is **in-memory** → no history, no graphs.
- Pair **`logs`** (app errors) with **`describe pod`** (Events, Last State/Reason = scheduling/runtime).

## 📌 Command cheat sheet
```bash
# MONITORING
kubectl top node                        kubectl top pod -A
kubectl top pod --sort-by=cpu           kubectl top pod --containers
# LOGS
kubectl logs -f my-pod                   # live tail
kubectl logs my-pod --previous           # crashed container
kubectl logs my-pod -c app               # multi-container
kubectl logs my-pod --tail=50 --since=1h
```

---

## Related sections

- [Section 13 — Troubleshooting](13-troubleshooting.md) — logs + describe + events as the core debugging loop.
- [Section 2 — Scheduling](02-scheduling.md) — requests/limits that `kubectl top` helps you size.
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — CrashLoopBackOff from bad configs, read via `logs`.
- [Section 1 — Core Concepts](01-core-concepts.md) — where the kubelet/cAdvisor sit in the architecture.
- [../../Linux/21-performance-monitoring.md](../../Linux/21-performance-monitoring.md) — `top`/`vmstat` and the Linux resource metrics underneath cAdvisor.
