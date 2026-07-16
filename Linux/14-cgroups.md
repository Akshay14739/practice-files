# cgroups — Resource Control

*The kernel's accountant and bouncer: how much CPU, memory, and PIDs a process is allowed to USE — the other half of what makes a container a container.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** Control groups (cgroups) — the Linux kernel feature that *limits, accounts for, and isolates* the resource usage (CPU, memory, PIDs, I/O) of a group of processes. If namespaces (see [namespaces](13-namespaces.md)) decide **what a process can SEE**, cgroups decide **how MUCH a process can USE**. Those two features, bolted together, ARE what your container runtime sells you as "a container."

**Why did this land on my desk?** You're on call. A pod in `prod` keeps dying and `kubectl get pod` shows:

```bash
kubectl get pod api-7f9c -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# OOMKilled
```

The app team swears "there's no memory leak, the node has 60 GB free!" And they're *right* about the node — but wrong about what matters. The container hit **its own** `resources.limits.memory`, not the node's limit. Something enforced that per-container ceiling and shot the process. That "something" is a cgroup, and the kernel's **OOM killer** pulled the trigger. To debug this credibly you need to read the actual limit and the actual usage off the filesystem — not trust the YAML, but verify the kernel.

**What do I already know that transfers?**
- **"Everything is a file"** (see [linux-philosophy](01-linux-philosophy.md)) — cgroups are configured entirely by reading and writing plain text files under `/sys/fs/cgroup`. No syscall gymnastics, no special tool required. `cat` and `echo` are your entire API.
- **Processes and PIDs** (see [processes-job-control](07-processes-job-control.md)) — a cgroup is fundamentally "a set of PIDs plus a set of limits applied to them."
- **`/proc` and `/sys`** — the kernel exposes its live state as virtual files. cgroups live in `/sys/fs/cgroup`; per-process cgroup membership lives in `/proc/<PID>/cgroup`.
- **Kubernetes `requests` and `limits`** — you've written them a thousand times in YAML. You've never seen where they *land*. Today you will.

---

## 🔥 Rung 1 — The Pain

**The problem that FORCED cgroups to exist: one greedy process could starve the whole machine.**

Rewind to a Linux box before 2008. You run ten services on one server. The scheduler is *fair* at the process level — it time-slices CPU across runnable tasks — but it has no concept of "this group of 40 worker processes together should never exceed 2 cores." A single misbehaving service could:

- **Fork-bomb the box.** A runaway loop spawns processes until the PID table is exhausted. Now you can't even `ssh` in to fix it — `fork()` fails for *everyone*, including your login shell.
- **Eat all the RAM.** A memory leak grows until the kernel's global OOM killer wakes up and kills... whatever it heuristically decides is "the worst" process. Maybe your leaking service. Maybe `sshd`. Maybe the database. The blast radius was the *entire machine*.
- **Hog the CPU.** One CPU-bound batch job pins every core; your latency-sensitive web server starves. `nice` (see [processes-job-control](07-processes-job-control.md)) could *lower a single process's priority*, but it couldn't say "cap this whole tree at half a core."

**What did people do before cgroups, and why did it hurt?**
- `ulimit` / `setrlimit(2)` — per-*process* limits (max open files, max memory). But a process could just `fork()` children, and each child got its own fresh limit. No aggregate accounting across a tree.
- `nice`/`renice` — priority nudging, not hard caps. Relative, not absolute.
- **One service per physical machine** — the brute-force isolation of the 2000s. Wildly expensive, terrible utilization (5% average CPU), and the reason your data-center power bill was insane.
- **Xen/KVM full virtual machines** — real isolation, but a whole guest kernel per workload. Heavy: gigabytes of RAM, seconds to boot, a full OS to patch.

**Who felt the pain most?** Google. They were packing thousands of jobs onto shared machines for maximum utilization and needed **hard, hierarchical, aggregate resource accounting** without the weight of a VM per job. Engineers Paul Menage and Rohit Seth built "process containers," merged into the kernel as **cgroups** in 2.6.24 (2008). That primitive is the direct ancestor of Borg, and Borg is the direct ancestor of Kubernetes. When you write `limits.memory: 128Mi`, you are speaking the language Google invented to stop one job from taking down a machine full of other people's jobs.

**Without cgroups, Kubernetes cannot exist as we know it.** `resources.requests`/`limits`, QoS classes, `OOMKilled`, node pressure eviction, `kubectl top` — every one of those is a thin YAML veneer over a cgroup file.

> **Check yourself before Rung 2:** Namespaces make a process *think* it's alone on the machine — it sees only its own PIDs, its own network. So why is that not enough to stop the fork-bomb or the memory leak from taking down the node? What second, orthogonal thing must the kernel enforce?

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it:

> **A cgroup is a named box of PIDs with resource dials on it; the kernel enforces those dials on the box as a whole, and the boxes form a tree where a child can never exceed its parent.**

Everything else is a derivation of that one sentence:

- **"box of PIDs"** → you add a process by writing its PID into the box's `cgroup.procs` file. Its children are born into the same box automatically.
- **"resource dials"** → each controller (memory, cpu, pids, io) adds files to the box: `memory.max`, `cpu.max`, `pids.max`. Writing a number turns the dial. Reading a `.current`/`.usage` file shows live consumption.
- **"enforces on the box as a whole"** → the limit is the *sum* across all PIDs in the box. This is the thing `ulimit` never did. Ten processes sharing one `memory.max` of 128Mi collectively cannot exceed 128Mi — hit it, and the OOM killer fires *scoped to that box*.
- **"a tree where a child can never exceed its parent"** → cgroups are hierarchical. Kubernetes leans on this hard: `kubepods.slice` caps all pods; inside it each pod slice caps its containers. A pod can't escape the node's `kubepods` allocation.

If you remember nothing else, remember: **box of PIDs + dials + tree.** Read on and watch the whole feature fall out of those three words.

> **Check yourself before Rung 3:** From the one sentence alone, predict: if I put a process in a box with `memory.max = 50M`, and that process forks a child that allocates 60M, who dies and why? (Hint: whose accounting does the child's memory count against?)

---

## ⚙️ Rung 3 — The Machinery (the important rung — go slow)

This is where you build the real mental model. Let's open the hood.

### The filesystem IS the API

There is no `cgroup` command. The kernel exposes cgroups as a **pseudo-filesystem** — a directory tree where every directory is a cgroup and every file is either a dial (writable) or a gauge (readable). Mount point:

```bash
stat -f -c %T /sys/fs/cgroup
# cgroup2fs      <- unified v2 hierarchy (modern: Ubuntu 22.04+, RHEL 9+)
# tmpfs          <- legacy v1, or hybrid; controllers live in subdirs
```

`stat -f` reports on the *filesystem* (the `-f`), and `%T` prints its type. `cgroup2fs` means you're on the modern unified hierarchy. That one command is your first diagnostic on any node: **which cgroup version am I even on?**

### v1 vs v2 — the single biggest source of confusion

**cgroup v1 (legacy):** every *controller* got its **own separate hierarchy**, mounted as its own directory. A process could sit in *different* boxes in each hierarchy simultaneously — in cgroup `/foo` for memory but `/bar` for cpu. This flexibility became a nightmare of inconsistency.

```
cgroup v1 — one tree PER controller
/sys/fs/cgroup/
├── memory/          <- memory controller's own tree
│   └── mygroup/  memory.limit_in_bytes, memory.usage_in_bytes
├── cpu,cpuacct/     <- cpu controller's own tree (note the joined name)
│   └── mygroup/  cpu.cfs_quota_us, cpu.cfs_period_us, cpu.stat
├── pids/
│   └── mygroup/  pids.max, pids.current
└── ...one dir per controller
```

**cgroup v2 (unified, the future and the present):** **ONE** tree. Every controller attaches to the *same* hierarchy. A process lives in exactly one cgroup, full stop. Which controllers are *active* in a given subtree is governed by two special files:

- `cgroup.controllers` — read-only: which controllers are *available* here (delegated down from the parent).
- `cgroup.subtree_control` — writable: which controllers you *enable for your children*. You write `+memory +cpu` to turn them on, `-memory` to turn off.

```
cgroup v2 — ONE unified tree, controllers toggled per subtree
/sys/fs/cgroup/               cgroup.controllers = "cpu memory pids io ..."
│                             cgroup.subtree_control = "cpu memory pids"
├── cgroup.procs              <- PIDs at the root
├── kubepods.slice/           <- Kubernetes lives here (systemd naming)
│   ├── memory.max            <- ceiling for ALL pods combined
│   ├── cpu.max
│   ├── kubepods-burstable.slice/       <- Burstable QoS pods
│   ├── kubepods-besteffort.slice/      <- BestEffort QoS pods
│   └── kubepods-pod<UID>.slice/        <- one Guaranteed pod
│       ├── memory.max        <- this POD's ceiling
│       └── cri-containerd-<id>.scope/  <- one CONTAINER
│           ├── memory.max            = 134217728   (128Mi)
│           ├── memory.current        = 41...       (live usage)
│           ├── cpu.max               = "50000 100000"  (0.5 CPU)
│           └── cgroup.procs          = 4021, 4055 ...
└── system.slice/             <- systemd's own services (sshd, kubelet)
```

**The key insight:** Kubernetes doesn't invent this layout. It hands the shape to **systemd** (via the `systemd` cgroup driver, the kubelet default) which creates `.slice` (a group of services) and `.scope` (an externally-created group of processes) units. Your container runtime — **containerd** via the CRI — creates the leaf `.scope` and writes the pod's limits into its files. When you `kubectl apply` a pod, the causal chain is: **kube-apiserver → kubelet → CRI (containerd) → runc → write files under `/sys/fs/cgroup`**. The number in your YAML ends its journey as bytes in a text file.

### How a dial actually enforces

The dials aren't polled by a userspace daemon. They're wired into the kernel's core subsystems:

- **memory.max** → the memory controller hooks the page-fault / charge path. Every page a process in the box touches is *charged* to the box's counter (`memory.current`). When a charge would push `current` past `max`, the kernel first tries to reclaim (evict page cache, swap). If it can't reclaim enough, it invokes the **OOM killer scoped to that cgroup** — it picks the fattest process *in the box* and sends `SIGKILL`. This is exactly `OOMKilled`. The node's other pods never notice.

- **cpu.max** → written as `"$QUOTA $PERIOD"` in microseconds. It plugs into the CFS (Completely Fair Scheduler) bandwidth controller. `"50000 100000"` means: *in every 100 ms window, the processes in this box may run for at most 50 ms of CPU time* — i.e. **0.5 of a CPU**. Exceed it and the scheduler **throttles** the box: it's made non-runnable until the next period starts. CPU is throttled (slowed), never killed. This is why over-limit CPU shows up as latency, not crashes.

- **pids.max** → checked in the `fork()`/`clone()` path. When `pids.current` equals `pids.max`, the next `fork()` returns `-EAGAIN`. The fork-bomb from Rung 1 hits a wall, contained to its own box.

### PSI — the pressure gauge the OOM killer wishes you'd read first

**PSI (Pressure Stall Information)** answers "how much time did tasks *stall* waiting for a resource?" — a far better signal than raw utilization. 100% CPU usage isn't a problem if nothing is waiting; PSI tells you if things are actually *stuck*.

```bash
cat /proc/pressure/memory
# some avg10=0.00 avg60=0.00 avg300=0.00 total=0
# full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

- **`some`** = % of wall-clock time *at least one* task was stalled waiting for the resource.
- **`full`** = % of time *every* task was stalled (the whole box made zero progress) — a red-alert number.
- `avg10/60/300` = rolling averages over 10 s / 60 s / 5 min. `total` = cumulative microseconds stalled.

There's a system-wide `/proc/pressure/{cpu,memory,io}`, AND per-cgroup `memory.pressure`, `cpu.pressure`, `io.pressure` files inside each v2 cgroup. **The kubelet reads these** to drive node-pressure eviction — it can start evicting pods when memory PSI climbs, *before* the hard OOM killer fires. PSI is the early-warning system; the OOM killer is the guillotine.

### The whiteboard picture

```
                    KUBERNETES SIDE                    │        KERNEL SIDE
                                                       │
  pod.yaml                                             │
  resources:                                           │
    limits:                                            │
      cpu: 500m   ───────┐                             │
      memory: 128Mi ──┐  │                             │
                      │  │                             │
   kube-apiserver     │  │                             │
        │  (etcd)      │  │                             │
        ▼             │  │                             │
     kubelet ─────────┼──┼──► CRI ──► containerd ──► runc
        │  reads back │  │                             │  writes files
        │  metrics    │  │                             ▼
        │             │  └──►  echo "50000 100000" > cpu.max ──► CFS bandwidth
        │             │           (0.5 CPU / 100ms window)     scheduler THROTTLES
        │             └──►  echo 134217728 > memory.max ──► memory controller
        │                       (128 MiB)                    charges every page
        ▼                                                    │ over max?
   kubectl top  ◄── reads memory.current, cpu.stat           ▼
                                                       cgroup OOM killer ─► SIGKILL
                                                              │
                                              reason: OOMKilled ◄─ kubelet observes
```

The user (app team) sees only the YAML on the left. Everything on the right — the charging, the throttling, the killing — is invisible machinery they never touch. Your job as platform engineer is to be able to walk from left to right and read the real numbers.

> **Check yourself before Rung 4:** In cgroup v2, why can't a process be "in the memory cgroup /A but the cpu cgroup /B" the way it could in v1? What single structural change makes that impossible — and why is that a *good* thing for Kubernetes' pod model?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually IS | Which machinery it touches |
|---|---|---|
| **cgroup** | A directory under `/sys/fs/cgroup` = a named box of PIDs + dials | The whole thing; each dir is one box |
| **controller** (aka subsystem) | A kernel module that adds dials for one resource (memory, cpu, pids, io) | Hooks into page-fault path, CFS, fork path |
| **hierarchy** | The tree of cgroup directories; child ⊆ parent | v1: one tree per controller; v2: one shared tree |
| **v1 (legacy)** | Separate mounted hierarchy per controller | `/sys/fs/cgroup/memory/`, `/cpu,cpuacct/` |
| **v2 (unified)** | Single hierarchy, all controllers, one cgroup per process | `cgroup.controllers`, `cgroup.subtree_control` |
| **`cgroup.procs`** | File listing/accepting PIDs in this box | Write a PID → move it into the box |
| **`cgroup.controllers`** | Read-only: controllers available in this cgroup | Delegated down from parent |
| **`cgroup.subtree_control`** | Write `+cpu +memory` to enable controllers for children | Turns dials on for the subtree |
| **`memory.max` (v2)** | Hard memory ceiling in bytes | Memory controller; triggers cgroup OOM |
| **`memory.current` (v2)** | Live memory usage in bytes | Read-only gauge; kubelet metrics source |
| **`memory.limit_in_bytes` (v1)** | v1 name for the memory ceiling | Same role, old file |
| **`memory.usage_in_bytes` (v1)** | v1 name for live usage | Same role, old file |
| **`cpu.max` (v2)** | `"QUOTA PERIOD"` in µs; `"50000 100000"` = 0.5 CPU | CFS bandwidth controller; throttles |
| **`cpu.cfs_quota_us` (v1)** | v1: quota in µs (`50000`) | Same, split across two files |
| **`cpu.cfs_period_us` (v1)** | v1: period in µs (`100000`) | Same, the window length |
| **`pids.max` / `pids.current`** | Cap / count of PIDs in the box | fork()/clone() path; anti-fork-bomb |
| **PSI** | Pressure Stall Information: % time stalled on a resource | `/proc/pressure/*` + per-cgroup `*.pressure` |
| **OOM killer** | Kernel routine that SIGKILLs a process to reclaim memory | Fires per-cgroup when `memory.max` unreclaimable |
| **`.slice`** | systemd unit = a group/tree of services or scopes | `kubepods.slice`, `system.slice` |
| **`.scope`** | systemd unit = externally-created group of processes | One per container: `cri-containerd-<id>.scope` |
| **kubepods** | The cgroup slice holding all Kubernetes pods | `kubepods.slice` + QoS sub-slices |
| **QoS class** | Guaranteed / Burstable / BestEffort — from requests vs limits | Maps to which `kubepods-*.slice` a pod lands in |

**"Same kind of thing wearing different names" — the groupings that matter:**

- **The memory ceiling:** `memory.max` (v2) *is* `memory.limit_in_bytes` (v1). Same dial, renamed.
- **The memory gauge:** `memory.current` (v2) *is* `memory.usage_in_bytes` (v1).
- **The CPU cap:** `cpu.max` = "QUOTA PERIOD" in one file (v2) *is* `cpu.cfs_quota_us` + `cpu.cfs_period_us` in two files (v1). Identical math, different file layout.
- **"controller" = "subsystem"** — kernel docs and old blog posts use both words for the exact same thing.
- **`.slice`/`.scope`** are just systemd's *naming and lifecycle wrapper* around plain cgroup directories. Under the hood, `kubepods.slice` is literally the directory `/sys/fs/cgroup/kubepods.slice/`.

> **Check yourself before Rung 5:** You SSH into a node, `cat /sys/fs/cgroup/.../memory.limit_in_bytes` for a container, and get a file-not-found error — but `memory.max` exists. From the vocabulary table alone, what does that one fact tell you about which cgroup version the node is running, and what would you have to change about *every* command in this doc to work on it?

---

## 🔬 Rung 5 — The Trace

Let's follow ONE concrete action end to end: **a pod with `limits.memory: 128Mi` allocates 200Mi and gets OOMKilled.** Who does what, in order.

1. **You `kubectl apply`.** The pod spec, including `resources.limits.memory: 128Mi`, is written to **etcd** by the **kube-apiserver**.
2. **kubelet** on the target node watches the apiserver, sees the pod assigned to it, and computes the cgroup layout: this pod has `requests == limits`, so it's **Guaranteed** QoS → it goes directly under `kubepods.slice` (not the burstable/besteffort sub-slices).
3. **kubelet calls the CRI**, telling **containerd** to create the container with a memory limit of `128Mi = 134217728` bytes.
4. **containerd invokes runc**, which creates the cgroup directory (a `.scope` under the pod's `.slice`) and **writes the dial**: `echo 134217728 > .../memory.max`. It also writes the container's PID into `cgroup.procs`. The box now exists with its ceiling set.
5. **The app runs and allocates.** Every page it faults in is **charged** by the kernel's memory controller to this box's `memory.current`. You can watch it climb.
6. **`memory.current` approaches `134217728`.** The kernel tries to **reclaim** — drop clean page cache, swap if swap is on (K8s nodes usually run swap off). Meanwhile `memory.pressure` climbs; kubelet may already be eyeing this for eviction.
7. **Reclaim fails to free enough.** The next charge would exceed `memory.max`. The **cgroup-scoped OOM killer** activates, scans processes *in this box only*, picks the biggest, and sends **SIGKILL**.
8. **The process dies.** The kernel logs it to the ring buffer (`dmesg`): `Memory cgroup out of memory: Killed process ...`.
9. **containerd notices** the container's main process exited with signal 9 and reports the termination to the kubelet.
10. **kubelet sets** `lastState.terminated.reason = OOMKilled` and — per `restartPolicy` — restarts the container (CrashLoopBackOff if it keeps happening). **The rest of the node is completely unaffected** — that's the whole point of scoping.

```
 kubectl apply
      │
      ▼
 apiserver ──write──► etcd
      │ watch
      ▼
   kubelet ──"128Mi"──► containerd ──► runc
                                         │ echo 134217728 > memory.max
                                         │ echo <PID> > cgroup.procs
                                         ▼
                              ┌─────────── the box ───────────┐
   app allocates ──charge──►  │ memory.current: 40M→90M→130M  │
                              │ memory.max:     134217728     │
                              │ page fault would exceed max?  │
                              │        reclaim → fails        │
                              │        ▼                      │
                              │   cgroup OOM killer ─► SIGKILL│
                              └───────────────┬───────────────┘
                                              ▼
                          dmesg: "Killed process ..."
                          containerd: exit signal 9
                                              │
                                              ▼
                          kubelet: reason=OOMKilled, restart
```

Notice the crucial detail in step 7: the OOM killer scanned **only this box**. The node's 60 GB of free RAM was irrelevant. The limit that mattered was the one in the file.

> **Check yourself before Rung 6:** In step 2 the pod was Guaranteed because `requests == limits`. If instead it had `requests: 64Mi, limits: 128Mi`, which sub-slice would it land in, and would the OOM behavior at step 7 change? (Think: does the *limit* file change, or just the *tree location*?)

---

## ⚖️ Rung 6 — The Contrast

**The older/alternative approach: `ulimit` / `setrlimit(2)` and `nice`.**

Before cgroups, the tools were per-process and mostly advisory:

```bash
ulimit -v 524288    # cap virtual memory at 512 MB — for THIS shell's future children
ulimit -u 100       # cap number of processes for this USER
nice -n 19 ./batch  # run at lowest priority — a hint, not a cap
```

The fatal gap: `ulimit` limits are **per-process and per-user**, not **per-arbitrary-group**. Each `fork()`ed child gets its *own* fresh 512 MB allowance, so a tree of 100 children can use 50 GB while each individually "obeys" its limit. There is no aggregate. And `ulimit -u` is per-*user*, which is useless when every container runs as the same UID.

| Capability | cgroups | ulimit / nice |
|---|---|---|
| Limit a **group** of processes as a whole | ✅ the entire point | ❌ per-process only |
| Aggregate accounting across forked children | ✅ children inherit the box | ❌ each child gets fresh limit |
| **Hierarchical** limits (child ⊆ parent) | ✅ the tree | ❌ flat |
| Hard CPU **quota** (0.5 CPU cap) | ✅ `cpu.max` | ❌ only relative `nice` priority |
| Hard **memory** ceiling with scoped OOM | ✅ `memory.max` | ⚠️ RLIMIT_AS per-process, no group OOM |
| Live **usage** accounting (`.current`) | ✅ built-in gauges | ❌ must poll `/proc` yourself |
| **Pressure** metrics (PSI) | ✅ per-cgroup | ❌ none |
| Anti-fork-bomb (aggregate PID cap) | ✅ `pids.max` | ⚠️ `ulimit -u` only per-user, leaky |
| Zero-overhead, no daemon | ✅ kernel-native files | ✅ also kernel-native |
| Simplicity for a one-off script | ⚠️ needs a cgroup setup | ✅ one command |

**When would I NOT reach for cgroups directly?** For a quick, single-process guardrail in a script — "don't let this one command open more than 1024 files" — `ulimit -n 1024` is instant and needs no cgroup. And you rarely create cgroups *by hand* in production; **you let systemd and Kubernetes do it.** You read them by hand to debug; you write them by hand only to learn (this doc) or in one-off `systemd-run` experiments.

**Why cgroups over ulimit, in one sentence:** *ulimit fences one process at a time and forgets about its children; cgroups fence a whole tree as a single accountable unit — which is exactly the shape of "a container."*

> **Check yourself before Rung 7:** You want to guarantee a batch job never uses more than half a CPU *across all the worker threads it spawns*. Explain in one sentence why `nice` and `ulimit` both fail at this and `cpu.max` succeeds.

---

## 🧪 Rung 7 — The Prediction Test

Now you commit to a prediction *before* running each command. The learning is in the gap between what you predicted and what happened. These assume **cgroup v2 on Ubuntu 22.04** unless noted, and require root (`sudo -i` or prefix with `sudo`).

First, confirm your world:

```bash
stat -f -c %T /sys/fs/cgroup
# cgroup2fs   -> you're on v2, everything below applies directly
# tmpfs       -> you're on v1/hybrid; use the v1 file names noted in each example
```

---

### Example 1 — The normal case: build a memory-capped box by hand and watch the OOM killer fire

**Prediction:** *If I create a cgroup with `memory.max = 50M` and run a process inside it that allocates 100M, the process will be SIGKILLed by the cgroup OOM killer — BECAUSE the memory controller charges every page to the box's counter, and when a charge would exceed `memory.max` and reclaim can't free enough, the kernel kills the fattest process in the box. The node's total free RAM is irrelevant.*

```bash
# Create the box (a directory under the v2 root)
sudo mkdir /sys/fs/cgroup/demo

# Turn the memory dial: 50 MiB = 52428800 bytes
echo 52428800 | sudo tee /sys/fs/cgroup/demo/memory.max
# 52428800

# Put THIS shell into the box (must run as root; $$ = current shell PID)
echo $$ | sudo tee /sys/fs/cgroup/demo/cgroup.procs

# Confirm the shell is now in /demo
cat /proc/$$/cgroup
# 0::/demo

# Now allocate ~100 MB inside the box — this child is also charged to /demo
python3 -c 'a = bytearray(100 * 1024 * 1024); input()'
# Killed          <- the shell/child is SIGKILLed almost immediately
```

**Verify:** You should see `Killed`. Confirm the *reason* in the kernel log:

```bash
sudo dmesg | tail -5
# Memory cgroup out of memory: Killed process 4231 (python3) ...
#   memory-cgroup: ... oom-kill:constraint=CONSTRAINT_MEMCG ...
```

`CONSTRAINT_MEMCG` is the tell — it was the *cgroup's* limit, not the machine's. **A wrong result** — the process surviving — would mean either you're on cgroup v1 (write to `memory.limit_in_bytes` instead), or the process wasn't actually in `/demo` (re-check `cat /proc/$$/cgroup`), or swap absorbed it (K8s nodes disable swap for exactly this predictability).

**cgroup v1 variant:**
```bash
sudo mkdir /sys/fs/cgroup/memory/demo
echo 52428800 | sudo tee /sys/fs/cgroup/memory/demo/memory.limit_in_bytes
echo $$      | sudo tee /sys/fs/cgroup/memory/demo/cgroup.procs
```

Clean up (move your shell out first, then remove the empty dir):
```bash
echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs   # move shell back to root
sudo rmdir /sys/fs/cgroup/demo                     # rmdir only; dirs aren't real files
```

---

### Example 2 — The edge case: CPU is THROTTLED, never killed

**Prediction:** *If I cap a busy-loop at `cpu.max = "50000 100000"` (0.5 CPU) and watch it, the process will NOT die — it will be throttled to ~50% of one core, and `cpu.stat` will show a climbing `nr_throttled` count — BECAUSE the CFS bandwidth controller makes the box non-runnable once it burns its 50 ms quota within each 100 ms period, then lets it run again next period. CPU pressure causes latency, not death.*

```bash
sudo mkdir /sys/fs/cgroup/cpudemo

# Enable the cpu controller for this cgroup's context first? No — we set the leaf's own cpu.max.
# On v2 the cpu.max file exists once the cpu controller is enabled in the parent's
# subtree_control (the root usually has it). Set 0.5 CPU: 50000us run per 100000us window.
echo "50000 100000" | sudo tee /sys/fs/cgroup/cpudemo/cpu.max
# 50000 100000

# Launch a CPU burner in the box: put a subshell in, then spin
sudo bash -c 'echo $$ > /sys/fs/cgroup/cpudemo/cgroup.procs; exec yes > /dev/null' &

# In another terminal, watch top — the `yes` process sits near 50% CPU, not 100%
top -b -n 1 | grep yes
#  4501 root  20  0  ...  50.0  0.0  ... yes    <- pinned at ~50%, throttled

# The proof it's throttling, not just scheduling: read cpu.stat
cat /sys/fs/cgroup/cpudemo/cpu.stat
# usage_usec 5123000
# nr_periods 512
# nr_throttled 480          <- throttled in 480 of 512 periods
# throttled_usec 24000000   <- total time spent frozen waiting for next period
```

**Verify:** `nr_throttled` and `throttled_usec` climb over time while the process **stays alive** at ~50% CPU. **A wrong result** — the process at 100% CPU with `nr_throttled` stuck at 0 — means the cpu controller isn't active for this cgroup; check `cat /sys/fs/cgroup/cgroup.subtree_control` at the root includes `cpu`, and if not, `echo "+cpu" | sudo tee /sys/fs/cgroup/cgroup.subtree_control`. **The Kubernetes lesson:** this is *exactly* why a CPU-throttled pod shows p99 latency spikes but never `OOMKilled`. CPU limits degrade; memory limits kill.

Kill the burner and clean up:
```bash
sudo pkill yes
sudo rmdir /sys/fs/cgroup/cpudemo
```

**cgroup v1 variant** (two files instead of one):
```bash
sudo mkdir /sys/fs/cgroup/cpu,cpuacct/cpudemo
echo 50000  | sudo tee /sys/fs/cgroup/cpu,cpuacct/cpudemo/cpu.cfs_quota_us
echo 100000 | sudo tee /sys/fs/cgroup/cpu,cpuacct/cpudemo/cpu.cfs_period_us
```

---

### Example 3 — The "do it the grown-up way" case: systemd-run + full subtree_control

**Prediction:** *If I launch a shell via `systemd-run --scope -p MemoryMax=50M -p CPUQuota=50%`, systemd will create a transient `.scope` cgroup with `memory.max=52428800` and `cpu.max="50000 100000"` already written — BECAUSE `systemd-run` is the sanctioned front-end that translates human units into cgroup dials and manages the box's lifecycle, exactly as the kubelet's systemd driver does for pods.*

```bash
# Launch an interactive shell inside a fresh transient scope with limits
sudo systemd-run --scope -p MemoryMax=50M -p CPUQuota=50% bash
# Running scope as unit: run-r<hex>.scope
# (you're now in a new bash inside that scope)

# From inside, find your cgroup path and read back what systemd actually wrote:
cat /proc/self/cgroup
# 0::/system.slice/run-r<hex>.scope

cat /sys/fs/cgroup/system.slice/run-r*.scope/memory.max
# 52428800          <- your 50M, in bytes
cat /sys/fs/cgroup/system.slice/run-r*.scope/cpu.max
# 50000 100000      <- your 50%, as quota/period

exit   # leaving the shell tears the transient scope down automatically
```

**Verify:** The `memory.max` reads `52428800` and `cpu.max` reads `50000 100000` — proving `50M`→bytes and `50%`→quota/period are the *same translation Kubernetes does*. **A wrong result** — files missing — usually means you're on v1 (paths differ) or an old systemd; check `systemctl --version` (need ≥ 244 for full v2). This is the closest hands-on analog to what happens on a real node.

**Now tie it to a real node** — enabling controllers for a subtree by hand (the `subtree_control` dance you'll see in `kubepods`):

```bash
# A cgroup can only USE a controller its parent DELEGATED via subtree_control.
sudo mkdir /sys/fs/cgroup/parent
cat /sys/fs/cgroup/parent/cgroup.controllers
# (empty or partial) — children can't use memory/cpu until the parent enables them
echo "+memory +cpu" | sudo tee /sys/fs/cgroup/parent/cgroup.subtree_control
sudo mkdir /sys/fs/cgroup/parent/child
cat /sys/fs/cgroup/parent/child/cgroup.controllers
# cpu memory        <- NOW the child has the dials, because the parent delegated them
sudo rmdir /sys/fs/cgroup/parent/child /sys/fs/cgroup/parent
```

---

### Example 4 — The Kubernetes case: read the real pod limits off a live node

**Prediction:** *If I find a running pod's container cgroup under `kubepods.slice` and read its `memory.max` and `cpu.max`, the numbers will exactly match the pod's YAML `limits` — `128Mi`→`134217728` and `500m`→`"50000 100000"` — BECAUSE the kubelet→containerd→runc chain wrote your YAML values into these very files, and `memory.current` shows the live usage the kubelet reports as `kubectl top`.*

```bash
# On a Kubernetes node (or a kind/minikube node shell):
# 1) Find the QoS sub-slices — this is where pods actually live
ls /sys/fs/cgroup/kubepods.slice/
# kubepods-besteffort.slice   <- BestEffort pods (no requests/limits)
# kubepods-burstable.slice    <- Burstable pods (requests < limits)
# kubepods-pod<UID>.slice     <- Guaranteed pods (requests == limits) sit at top level
# cpu.max  memory.max  ...    <- the node-wide kubepods ceiling

# 2) Drill into a burstable pod's container scope and read the real dials
find /sys/fs/cgroup/kubepods.slice -name memory.max | head
cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<UID>.slice/cri-containerd-<ID>.scope/memory.max
# 134217728         <- your limits.memory: 128Mi
cat .../cri-containerd-<ID>.scope/cpu.max
# 50000 100000      <- your limits.cpu: 500m  (0.5 CPU)
cat .../cri-containerd-<ID>.scope/memory.current
# 41947136          <- live usage; this is what feeds `kubectl top pod`

# 3) Map a mystery PID back to its pod
cat /proc/<PID>/cgroup
# 0::/kubepods.slice/kubepods-burstable.slice/.../cri-containerd-<ID>.scope
```

**Verify:** `memory.max` equals `limits.memory` in bytes (`128*1024*1024 = 134217728`) and `cpu.max`'s first number equals `millicores * 100` (`500m → 50000`). **A wrong result** — `memory.max` reads `max` (the literal string, meaning *no limit*) — tells you that container has **no memory limit set** (BestEffort or Burstable-without-limit), which is itself a finding: that pod can grow until it triggers *node-level* OOM and eviction. **The payoff:** you can now walk from `OOMKilled` in `kubectl` straight to the byte in the file that killed it, and prove to the app team that yes, their container really did hit *its own* 128Mi ceiling regardless of the node's free RAM.

Cross-check against control-plane truth if kubelet exposes it:
```bash
# The kubelet's cgroup driver (usually systemd on modern clusters):
sudo grep -i cgroupDriver /var/lib/kubelet/config.yaml
# cgroupDriver: systemd     <- explains the .slice/.scope naming above
```

---

## 🏔 Rung 8 — Capstone: Compress It

**One-sentence summary:** A cgroup is a named box of PIDs with resource dials (`memory.max`, `cpu.max`, `pids.max`) that the kernel enforces on the box as a whole within a parent-bounded tree — and that box, married to namespaces, is literally what Kubernetes ships as a container.

**Explain it to a beginner in three sentences:** Linux lets you put a group of processes into a box and set hard limits on how much CPU, memory, and how many processes that whole box may use. If the box tries to use more memory than its limit, the kernel kills the biggest process inside it (that's `OOMKilled`); if it tries to use more CPU, the kernel just slows it down. Kubernetes creates one of these boxes per container and writes your `resources.limits` into it, which is why a pod can die from hitting *its own* limit even when the node has plenty of RAM to spare.

**Sub-capabilities, each mapped back to the one core idea (box of PIDs + dials + tree):**

| Sub-capability | Which part of the one idea it is |
|---|---|
| `memory.max` / OOMKilled | a **dial** on the **box**, enforced on the box as a whole |
| `cpu.max` throttling | a **dial** that slows the whole box instead of killing it |
| `pids.max` anti-fork-bomb | a **dial** counting PIDs *in the box* |
| v2 unified hierarchy | one **tree**, one box per process |
| `cgroup.subtree_control` | which **dials** a child box is allowed to have (delegation down the **tree**) |
| kubepods.slice + QoS sub-slices | Kubernetes' **tree** shape: node box ⊇ QoS box ⊇ pod box ⊇ container box |
| PSI (`/proc/pressure/*`) | a **gauge** on the box measuring stall, read by kubelet before the guillotine |
| `cgroup.procs` | the list of **PIDs** that ARE the box |

**Which rung to revisit hands-on:** **Rung 7, Example 1 and Example 4.** Example 1 makes the OOM killer real in 30 seconds on any laptop — do it until `CONSTRAINT_MEMCG` in `dmesg` is muscle memory. Then Example 4 on a real (or `kind`) node is the one that pays your salary: being able to `cat memory.max` and `cat memory.current` under `kubepods.slice` and reconcile them against the pod YAML is the exact skill that turns a vague "OOMKilled, dunno why" ticket into a proven root cause. If Rung 3's v1-vs-v2 split still feels fuzzy, run `stat -f -c %T /sys/fs/cgroup` on three different machines and note which layout each one has.

---

## Related concepts

- [namespaces](13-namespaces.md) — the *other* half of a container: what a process can SEE (cgroups are how MUCH it can USE)
- [processes-job-control](07-processes-job-control.md) — PIDs, signals, `nice`; a cgroup is fundamentally a set of these
- [systemd-services](16-systemd-services.md) — `.slice`/`.scope` units and the systemd cgroup driver the kubelet uses
- [performance-monitoring](21-performance-monitoring.md) — PSI, `dmesg`, and reading pressure to catch OOM before it happens
- [linux-philosophy](01-linux-philosophy.md) — "everything is a file": why `cat` and `echo` on `/sys/fs/cgroup` are the entire cgroup API
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full Linux↔Kubernetes mapping and node-triage quick reference
