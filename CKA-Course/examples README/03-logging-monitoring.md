# 📊 Section 3 — Logging & Monitoring (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 3 transcript.

---

## 1. Cluster monitoring — the Metrics Server & `kubectl top`

### ❓ What
The **Metrics Server** is a lightweight, **in-memory** aggregator of live CPU/memory per node and per pod, powering `kubectl top` (and the autoscalers). Kubernetes ships **no** monitoring stack by default.

### 🔥 Pain points it solves & why this?
- "Which pod is eating all the memory?" is unanswerable without metrics — SSH + `top` per node doesn't map to pods.
- You can't size requests/limits ([Section 2](02-scheduling.md)) or drive an HPA without a metrics API.
- Why *this* tool: one tiny server, no storage to run — trade-off: **no history** (for graphs/alerts you add Prometheus/EFK; Heapster is the deprecated ancestor).

### ⚙️ How exactly it works
```
container ─▶ cAdvisor (built INTO each kubelet) ─▶ kubelet API :10250
                                                     │ Metrics Server scrapes every node
                                                     ▼
                                 Metrics Server (aggregates, IN MEMORY)
                                                     ▼
                                 kubectl top node / kubectl top pod
```

| Vocabulary | Meaning |
|---|---|
| **cAdvisor** | the collector inside every kubelet (you deploy nothing per node) |
| **Metrics API** | what `kubectl top` calls; served by the Metrics Server |
| **in-memory** | no history, no graphs — live snapshot only |
| `--kubelet-insecure-tls` | lab-only flag when kubelet certs are self-signed (never in prod) |

### 🧪 Hands-on examples

**Example 1 — Deploy the Metrics Server and prove `top` needs it:**
```bash
kubectl top pod            # error: Metrics API not available (nothing serves it)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top node           # numbers after ~1 min of scraping
# Verify: the error disappears once the server is up AND has scraped.
```

**Example 2 — Find the resource hogs (exam task shape):**
```bash
kubectl top node                              # busiest node
kubectl top pod -A --sort-by=memory | head    # biggest memory user at the top
kubectl top pod --sort-by=cpu | tail -1       # LEAST cpu (bottom of the sort)
kubectl top pod --containers                  # per-container breakdown
# Verify: you can answer "which node/pod uses most CPU/memory" in one line.
```

**Example 3 — Fix a Metrics Server that won't start (lab clusters):**
```bash
kubectl -n kube-system logs deploy/metrics-server | tail    # x509: cannot validate certificate
kubectl -n kube-system edit deploy metrics-server
#   containers.args: add  --kubelet-insecure-tls
kubectl top node          # works after the rollout
# Verify: the cert error is the classic lab failure; the flag is for labs ONLY.
```

---

## 2. Application logs — `kubectl logs`

### ❓ What
Reading a container's **stdout/stderr**, captured by the container runtime and exposed by the kubelet — the K8s equivalent of `docker logs -f`.

### 🔥 Pain points it solves & why this?
- The app's error output lives inside a container that may be gone — you need the platform to capture and serve it.
- A **crashed** container's output vanishes from the current view — `--previous` recovers the *previous* container's logs (the one that actually failed).
- Multi-container pods have several streams — Kubernetes won't guess which you want.

### ⚙️ How exactly it works
App writes to stdout/stderr → the runtime persists the stream per container → `kubectl logs` fetches via the kubelet. Logs are **per container**, and each restart starts a fresh stream (the old one is kept once, as "previous").

| Vocabulary | Meaning |
|---|---|
| `-f` | follow (live tail) |
| `-c <name>` | pick the container (mandatory when >1) |
| `--previous` / `-p` | the crashed prior container's logs |
| `--since=1h` / `--tail=50` | time / line filters |
| `--all-containers` | merge all streams |

### 🧪 Hands-on examples

**Example 1 — Find why a user can't log in (single container):**
```bash
kubectl get pods
kubectl logs webapp-1 | grep -iE "warn|error|fail"
# → "USER5 failed to log in — account locked due to too many failed attempts"
# Verify: the log line names the user and the cause.
```

**Example 2 — Multi-container pod: target the right stream:**
```bash
kubectl logs webapp-2                    # ERROR: a container name must be specified
kubectl get pod webapp-2 -o jsonpath='{.spec.containers[*].name}{"\n"}'
kubectl logs webapp-2 -c webapp | grep -i warn
# → "USER30 order failed as the item is out of stock"
# Verify: -c returns that container's logs; the error even lists valid names.
```

**Example 3 — CrashLoopBackOff: read the PREVIOUS container:**
```bash
kubectl get pod crasher                 # CrashLoopBackOff, RESTARTS: 5
kubectl logs crasher                    # thin/empty — this attempt just started
kubectl logs crasher --previous        # the real panic/stacktrace
kubectl describe pod crasher | grep -A3 "Last State"   # Reason: Error/OOMKilled
# Verify: --previous + describe's Last State localize almost any crash.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **`kubectl logs deploy/<name>`** works too (picks a pod for you) — handy for quick checks.
- **Logs vs describe:** `logs` = the *app's* words; `describe` (Events, Last State) = the *platform's* words (scheduling, pulls, probes, OOM). Always read both.
- **Log persistence** is your job: node log rotation or a shipping DaemonSet (fluentd/fluent-bit → EFK) — `kubectl logs` alone is not an audit trail.

---

## Related
[02-scheduling](02-scheduling.md) (sizing requests from `top`) · [04-application-lifecycle-management](04-application-lifecycle-management.md) (CrashLoopBackOff causes) · [13-troubleshooting](13-troubleshooting.md) · Ladder version: [../README/03-logging-monitoring.md](../README/03-logging-monitoring.md)
