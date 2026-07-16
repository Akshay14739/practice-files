# Performance & Monitoring — Diagnosing a Sick Node

*The doctor's toolkit: how to walk up to a slow, unhealthy, or hanging Linux box and, in ten minutes, name exactly which resource is starved and which process is starving it — before Kubernetes ever tells you.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** A *method* and a *toolkit* for diagnosing why a Linux machine is slow, saturated, or misbehaving. Not "run `top` and squint" — a repeatable discipline: for every resource (CPU, memory, disk, network) ask three questions — **is it busy (utilization), is work backing up behind it (saturation), and is it throwing errors?** That's the **USE method** (Utilization, Saturation, Errors), coined by Brendan Gregg. Around it sit the classic tools — `uptime`, `free`, `vmstat`, `iostat`, `mpstat`, `top`, `ps`, `strace`, `lsof`, `dmesg` — and the modern one, **PSI** (Pressure Stall Information).

**Why did this land on my desk?** It's 02:00. PagerDuty fired: `node-7` is `NotReady`, pods on it are stuck `Terminating`, and the ones that survive are being `Evicted`. `kubectl describe node node-7` mumbles `MemoryPressure=True` and `DiskPressure=True`. Meanwhile etcd on the control plane is logging `apply request took too long` and leader elections are flapping. Kubernetes is *telling you the symptom* (pressure, eviction, slow apply) but not the *cause*. To find the cause you have to `ssh` onto the node and interrogate the kernel directly — because kubelet is just reading the same kernel counters you're about to read, only it reads them a minute late and summarizes them into a single scary word.

**What do I already know that transfers?**
- **"Everything is a file"** (see [linux-philosophy](01-linux-philosophy.md)) — nearly every number in this doc is `cat`'d out of `/proc` or `/sys`. `uptime`, `free`, `vmstat` are just pretty-printers over `/proc/loadavg`, `/proc/meminfo`, `/proc/stat`. PSI is literally `cat /proc/pressure/memory`.
- **Processes, PIDs, and states** (see [processes-job-control](07-processes-job-control.md)) — you know `ps` and `top`. The load average and `vmstat`'s `r`/`b` columns are just *counts of processes in particular states*.
- **cgroups and the OOM killer** (see [cgroups](14-cgroups.md)) — `OOMKilled` is a cgroup memory limit firing. `dmesg` is where the kernel *narrates* that kill. This doc is the diagnostic sibling of the cgroups doc.
- **File descriptors** (see [io-redirection-pipes](10-io-redirection-pipes.md)) — `lsof` = "list open files," and every socket, log, and etcd WAL is a file an fd points at.

---

## 🔥 Rung 1 — The Pain

**The problem that FORCED these tools to exist: a slow machine gives you a symptom, never a cause. "The server is slow" is a feeling, not a diagnosis.**

Picture a Unix admin in 1995. A server is crawling. What do they actually *know*? Nothing. "Slow" could mean:

- The CPUs are pinned at 100% doing real work (need more CPU, or a runaway loop).
- The CPUs are *idle* but every process is blocked waiting on a disk that can't keep up (need faster disk, not more CPU — buying CPU here changes **nothing**).
- RAM is exhausted, so the kernel is frantically swapping pages to disk, and now a "CPU" problem is really a "disk" problem wearing a costume.
- One process is stuck in a syscall that never returns — the box has spare everything, but the *one thing you care about* is frozen.

**Each of those has a completely different fix, and they all feel identical from the outside.** Guessing wrong is expensive: you order more RAM for a disk problem, you reboot (destroying the evidence), you restart the wrong service. The pain is **misattribution** — spending money, downtime, and 3 a.m. sanity chasing the wrong resource.

**What did people do before a real method?**
- **`top` and vibes.** Open `top`, stare at the CPU number, declare victory or defeat. But `top`'s load average and CPU% famously *conflate* "busy with CPU work" and "blocked on I/O." A load of 40 on an idle-CPU box baffles people to this day.
- **Reboot and pray.** The universal fix that destroys every clue about what happened.
- **Add hardware.** When you can't diagnose, you overprovision. Utilization stays at 5% because everything is sized for the worst misdiagnosed guess.

**Who feels this pain most?** The on-call platform engineer — you. And it is *worse* in Kubernetes, not better, because the machine is now a shared tenement: 60 pods from 12 teams packed onto one node by the scheduler. When the node gets sick, "which resource, whose fault" is a question about *someone else's* workload, and the kernel is the only impartial witness. Kubernetes' own health signals — `MemoryPressure`, `DiskPressure`, `PIDPressure`, `OOMKilled`, eviction — are **derived from these exact kernel counters**. If you can't read the counters, you can only react to kubelet's summary a minute too late. etcd makes it sharper still: etcd is fantastically sensitive to disk write latency (it `fsync`s its write-ahead log on every commit), so a disk that's merely "a bit busy" translates directly into cluster-wide control-plane instability — and *nothing in kubectl* will point at the disk. Only `iostat -x` will.

> **Check yourself before Rung 2:** Two machines are "slow." On box A the CPUs are 100% busy; on box B the CPUs are 3% busy but the load average is 50. Why is "load average" not the same thing as "CPU usage," and what resource is box B almost certainly starved on?

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it exactly:

> **Every performance problem is one resource that is either too BUSY (utilization), has a QUEUE backing up behind it (saturation), or is FAILING (errors) — so diagnosis is not "look at the box," it's "walk the resource list and measure U, S, E for each one."**

That is the USE method, and it is the entire discipline. Everything else — every tool below — is just *"which command measures U, S, or E for which resource."*

Watch the whole toolkit fall out of that one sentence:

| Resource | Utilization (busy?) | Saturation (queue?) | Errors? |
|---|---|---|---|
| **CPU** | `mpstat` `%idle`, `top` | load avg, `vmstat` `r` column, PSI cpu | `dmesg` (MCE) |
| **Memory** | `free -h`, `/proc/meminfo` | `vmstat` `si`/`so` (swap), PSI memory | `dmesg` OOM kills |
| **Disk I/O** | `iostat -xz` `%util` | `iostat` `await`, `vmstat` `b`/`wa`, PSI io | `dmesg` I/O errors |
| **Network** | `sar -n DEV`, `ss` | dropped/retrans counters | `ip -s link`, `dmesg` |

- *"too BUSY"* → **utilization**: what percent of the time is the resource doing work? A disk at `%util=100%` is maxed.
- *"a QUEUE backing up"* → **saturation**: this is the one people forget, and it's the most important. A resource can be 100% utilized and *fine* (fully used, no waiting) — the pain only starts when work **queues**. The disk's `await` (average I/O latency) and the CPU's run-queue length (`r`) are saturation. **PSI is a direct, first-class saturation meter** — that's why it was invented.
- *"is FAILING"* → **errors**: the dmesg-and-counters bucket. OOM kills, I/O errors, NIC drops.

If you remember nothing else: **for each resource, measure U, S, and E — and never confuse utilization (busy) with saturation (queued).** Read on and watch every tool slot into that grid.

> **Check yourself before Rung 3:** A disk shows `%util = 100%` but `await` is a flat 1ms and nothing is complaining. Is that a problem? Now `%util = 60%` but `await` jumped to 400ms. Which one is actually hurting, and which USE letter did each of those numbers measure?

---

## ⚙️ Rung 3 — The Machinery (the important rung — go slow)

This is where you build the model. The big realization: **you are never really running a tool — you are reading a counter the kernel already maintains.** The kernel is *constantly* keeping score in memory. The tools are pretty-printers over `/proc` and `/sys`.

### The kernel is always keeping score

Every context switch, every interrupt, every page fault, every block I/O completion, the kernel bumps a counter. These live in virtual files:

```
/proc/loadavg      → the three load numbers + running/total procs
/proc/stat         → cumulative CPU jiffies (user/system/idle/iowait/steal…)
/proc/meminfo      → every memory pool (MemFree, Buffers, Cached, SwapFree…)
/proc/vmstat       → paging, swapping, page-fault counters
/proc/diskstats    → per-device: reads, writes, sectors, ms-spent-doing-IO
/proc/pressure/*   → PSI: stall time for cpu, memory, io
/proc/<PID>/stat   → per-process CPU, state, etc.
/proc/<PID>/status → per-process memory (VmRSS), state, cgroup-ish info
/proc/<PID>/fd/    → the file descriptors (what lsof reads)
```

Nothing here is magic. `free -h` reads `/proc/meminfo` and divides by 1024. `uptime` reads `/proc/loadavg`. `iostat` reads `/proc/diskstats` twice, a second apart, and **divides the deltas by the interval** — which is the single most important idea in this whole rung.

### Counters are cumulative — the tools show you DELTAS

`/proc/diskstats` doesn't say "the disk is 80% busy." It says "since boot, this device has spent 91,234,110 milliseconds doing I/O." That number alone is useless. What `iostat -xz 1` does:

```
        read /proc/diskstats  ──►  snapshot A  (t = 0s)
        ... wait 1 second ...
        read /proc/diskstats  ──►  snapshot B  (t = 1s)

        %util = (B.io_ms − A.io_ms) / 1000ms × 100
              = "of the last 1000ms, how many was the disk busy?"
```

**This is why the first line of `vmstat`, `iostat`, `mpstat` is a lie** — that first line is the *average since boot*, computed against no prior snapshot. **Always ignore the first sample.** The second sample onward is the real, live rate. Burn this in: the first line is history, the rest is now.

### The three process states that explain load average

Load average confuses everyone because it is **not** "CPU usage." On Linux, load average counts processes in **two** states:

```
  R  (Running / Runnable)  → on a CPU, or waiting in the run-queue FOR a CPU
  D  (Uninterruptible sleep) → blocked in the kernel, usually waiting on DISK I/O
                               (cannot be interrupted, not even by a signal)

  load average = time-decayed count of (R + D) processes
                 averaged over 1 min / 5 min / 15 min
```

That D-state inclusion is the whole reason a box with **idle CPUs** can show **load 50**: fifty processes are all stuck in `D`, blocked on a hammered disk. The CPU is bored; the *disk* is the bottleneck; load average — being (R + D) — screams anyway. This is precisely box B from Rung 1.

```
   ASCII: where each tool taps the kernel

     ┌──────────────────────── THE KERNEL (always counting) ─────────────────────┐
     │                                                                            │
     │  scheduler        memory mgr        block layer        oom killer          │
     │     │                 │                 │                  │               │
     │     ▼                 ▼                 ▼                  ▼               │
     │ /proc/stat      /proc/meminfo    /proc/diskstats     kernel ring buffer    │
     │ /proc/loadavg   /proc/vmstat     (io_ms, await)      (dmesg source)        │
     │     │                 │                 │                  │               │
     │     └───────┬─────────┴────────┬────────┴─────────┬────────┘               │
     │      /proc/pressure/cpu  /proc/pressure/memory  /proc/pressure/io  (PSI)   │
     └────────────┬──────────────────┬─────────────────┬────────────┬────────────┘
                  ▼                  ▼                 ▼            ▼
              uptime            free -h           iostat -xz    dmesg -T
              mpstat            vmstat 1          vmstat (wa)    (grep oom)
              top/htop          top (mem)         iostat        journalctl -k
                  \                 |                 /            /
                   \________________|________________/___________/
                                    ▼
                        USE grid:  U · S · E  per resource
```

### PSI — the modern saturation meter, and why it exists

The old counters have a blind spot. `%util=100%` tells you the disk is *busy* but not whether anyone is *hurting*. iowait is a per-CPU accident of scheduling. So kernel 4.20 (2018) added **PSI — Pressure Stall Information**: the kernel directly measures *how much time tasks were stalled waiting for a resource they couldn't get.* Read it:

```
/proc/pressure/memory:
  some avg10=4.11 avg60=2.03 avg300=0.55 total=1234567
  full avg10=1.02 avg60=0.51 avg300=0.10 total=456789
```

- **`some`** = % of wall-clock time **at least one** task was stalled waiting for this resource.
- **`full`** = % of time **every** runnable task was stalled (total starvation — the box got no useful work done). `full` doesn't exist for `cpu` (there's always *something* the CPU can run).
- `avg10/60/300` = decaying averages over 10s/60s/300s. `total` = microseconds of stall since boot.

This is pure **saturation**, first-class. `some memory avg10 = 40` means "40% of the last ten seconds, something was stuck waiting to reclaim memory" — a far sharper signal than "RAM looks 90% full" (which is often just healthy page cache).

### The Kubernetes tie: kubelet is reading these same files

Here is the connection that makes all of this matter to you:

- **kubelet's eviction manager** wakes on a timer, reads `memory.available` (from cgroup + `/proc/meminfo`), `nodefs.available` (disk), `pid.available`, and — on modern kubelet with the PSI feature — `/proc/pressure/*`. When a signal crosses a threshold it flips a **node condition** (`MemoryPressure`, `DiskPressure`, `PIDPressure`) and starts **evicting pods** by QoS class. Your `kubectl describe node` output *is a summary of these exact counters.*
- **The OOM killer** (see [cgroups](14-cgroups.md)) fires when a pod's cgroup hits `memory.max`. It writes a report to the **kernel ring buffer** — the thing `dmesg` reads. That report says `oom-kill:constraint=CONSTRAINT_MEMCG` (killed because a **cgroup** limit was hit, not the whole node) and `Out of memory: Killed process 12345 (java)`. That's your ground-truth proof of *why* a pod is `OOMKilled`.
- **etcd** `fsync`s its write-ahead log on every write. If `iostat` shows `w_await` climbing, etcd's commit latency climbs, `apply request took too long` appears, and the whole cluster gets shaky. The disk counter *precedes* the kubectl symptom.

> **Check yourself before Rung 4:** Why is the very first line of `vmstat 1` misleading, and what specifically would you have to do by hand to reproduce the number `iostat` prints for the *second* line?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|---|---|---|
| **USE method** | Discipline: measure Utilization, Saturation, Errors per resource | The whole grid; your top-level algorithm |
| **Utilization** | % of time a resource was busy | `%util`, `mpstat %idle`, `free` |
| **Saturation** | Work *queued/waiting* for a resource | load avg, `vmstat r`/`b`, `await`, **PSI** |
| **Load average** | Time-decayed count of R + D processes (1/5/15 min) | scheduler + disk block layer → `/proc/loadavg` |
| **Run queue (`r`)** | Processes ready to run, waiting for a CPU | scheduler → `/proc/stat`, `vmstat` |
| **`b` (blocked)** | Processes in uninterruptible sleep (usually disk) | block layer → `vmstat` |
| **`wa` / iowait** | % CPU time idle *because* tasks are blocked on I/O | scheduler accounting; high = disk bound |
| **`si`/`so`** | Swap-in / swap-out pages per second | memory mgr; nonzero = memory pressure/thrash |
| **`%util`** | % of interval the disk had ≥1 I/O in flight | `/proc/diskstats` io_ms delta |
| **`await`** | Avg ms an I/O spent (queue + service). `r_await`/`w_await` split | `/proc/diskstats`; the disk saturation number |
| **`%steal`** | CPU time the hypervisor gave to *another* VM | virtualization; noisy-neighbor on cloud nodes |
| **PSI** | Pressure Stall Information: % time tasks stalled on a resource | `/proc/pressure/{cpu,memory,io}` |
| **`some` / `full`** (PSI) | ≥1 task stalled / *all* tasks stalled | PSI decayed averages |
| **RSS** | Resident Set Size: physical RAM a process actually occupies | `/proc/<PID>/status` VmRSS; `ps`, `top` |
| **strace** | Ptrace-based tracer of **syscalls** (kernel boundary) | `ptrace(2)`; app↔kernel |
| **ltrace** | Tracer of **library calls** (e.g. `libc` `malloc`) | `LD_PRELOAD`/ptrace; app↔libraries |
| **lsof** | "List open files" — every fd a process holds | `/proc/<PID>/fd/`; files, sockets, pipes |
| **dmesg** | Prints the **kernel ring buffer** (kernel's own log) | ring buffer; OOM, I/O errors, hardware |
| **OOM killer** | Kernel routine that kills a process to reclaim RAM | memory mgr; per-cgroup or global |
| **`CONSTRAINT_MEMCG`** | OOM was triggered by a **cgroup** memory limit, not node RAM | cgroup v2 `memory.max` → `OOMKilled` |
| **sar** | Historical/collected system activity (sysstat) | reads archived `/proc` snapshots over time |

**Terms that are the same kind of thing wearing different names:**

- **All "how much is queued" = saturation:** load average, `vmstat`'s `r` and `b`, `iostat`'s `await`, and **PSI** are four windows onto the *same* concept. PSI is the newest and most direct.
- **All "how busy" = utilization:** `mpstat %idle` (inverted), `top`'s CPU%, `iostat %util`, `free`'s used memory.
- **All three tracers reveal "what is this process actually doing":** `strace` (kernel syscalls), `ltrace` (library calls), `lsof` (open files). Different altitude, same detective question.
- **`vmstat`, `iostat`, `mpstat`, `sar` are one family** — all from the `sysstat`/procps lineage, all "read `/proc` counter, wait, read again, print the delta." Learn the pattern once.
- **`dmesg` and `journalctl -k` are the same firehose** — both surface the kernel ring buffer; `journalctl -k` just persists and timestamps it via journald (see [systemd-services](16-systemd-services.md)).

---

## 🔬 Rung 5 — The Trace

**One concrete action, end to end: you `ssh` onto the `NotReady` node-7 and, in under ten minutes, prove it's a disk-saturation problem strangling etcd — not a CPU or RAM problem.** Follow the USE method top to bottom; each step names the tool, the counter, and what the kernel did.

```
   THE 60-SECOND TRIAGE (USE method, walking the resource list)

   ssh node-7
      │
   1. uptime ─────────► load avg 48.2, 45.1, 30.0   (16 CPUs)
      │                 "load ≫ cores → SATURATED somewhere. But where?"
      │
   2. top / mpstat ───► CPU %idle = 89%,  %iowait = 71%
      │                 "CPUs are BORED. Not a CPU problem. iowait huge → DISK."
      │
   3. vmstat 1 5 ─────► r=1  b=47   wa=70   si=0 so=0
      │                 "b=47 blocked in D-state, wa=70. Not swapping. DISK confirmed."
      │
   4. iostat -xz 1 ───► sda: %util=100  w_await=380ms  aqu-sz=45
      │                 "Disk pinned, writes taking 380ms. THIS is the bottleneck."
      │
   5. iotop / ps ─────► etcd + a log-shipper are the top writers
      │
   6. lsof -p <etcd> ─► etcd blocked writing /var/lib/etcd/member/wal/*.wal
      │                 "etcd's fsync is stuck behind the log-shipper's writes."
      │
   7. dmesg -T ───────► (no OOM)  but I/O latency warnings
      │
   VERDICT: Disk SATURATION (await), not utilization alone; etcd starved →
            control plane flaps. Fix = throttle/move the log-shipper, or faster disk.
```

Step by step, naming who does what at each hop:

1. **`uptime`** reads `/proc/loadavg`. Load 48 on a 16-CPU box → **saturation** exists. But load = R + D, so this alone can't tell you CPU vs disk. *Hypothesis, not diagnosis.*
2. **`mpstat -P ALL 1`** reads `/proc/stat` deltas per CPU. `%idle` high + `%iowait` high is the fingerprint: CPUs are idle *because* tasks are blocked on I/O. The scheduler literally has nothing to run — everyone's in `D`. **CPU is exonerated.**
3. **`vmstat 1 5`** reads `/proc/stat` + `/proc/vmstat`. `b=47` (blocked, uninterruptible) and `wa=70` corroborate disk. `si=0 so=0` proves it's **not** a memory/swap problem masquerading as disk. Two independent counters agree.
4. **`iostat -xz 1`** reads `/proc/diskstats` deltas. `%util=100` (utilization maxed) **and** `w_await=380ms` (writes queuing 380ms — brutal **saturation**). A healthy SSD does sub-millisecond. `aqu-sz=45` = 45 I/Os queued. This is the smoking gun.
5. **`iotop`** (or `pidstat -d 1`) attributes the bytes: which PIDs are writing. etcd and a rogue log-shipper.
6. **`lsof -p <etcd-pid>`** reads `/proc/<pid>/fd/` — shows etcd's fd pointing at `/var/lib/etcd/member/wal/0.wal`. Now you *know* the victim: etcd's write-ahead-log `fsync` is stuck behind the shipper.
7. **`dmesg -T`** reads the ring buffer. No OOM lines → rules out the memory-error branch. Confirms this is pure disk saturation.

The whole trace is nothing but "walk CPU → memory → disk, measure U/S/E at each, follow the winner down to a PID and a file." You never guessed; each tool eliminated a branch.

> **Check yourself before Rung 6:** At step 2 you saw `%iowait=71%`. If instead you'd seen `%idle=2%, %iowait=1%, %user=95%`, how would the rest of the trace have changed — which tool would you jump to, and which resource would you interrogate?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: kubectl-only observability.** Before touching Linux tools, most K8s engineers try to diagnose a sick node entirely from `kubectl top node`, `kubectl describe node`, and a Grafana dashboard. That's the "modern" high-level approach. How does it stack up against dropping to the node?

| | **kubectl / metrics-server / Grafana** | **On-node Linux tools (this doc)** |
|---|---|---|
| **Granularity** | Per-pod/container, node totals | Per-process, per-device, per-syscall, per-fd |
| **Latency of signal** | 15–60s scrape + summarization delay | Live, 1-second resolution |
| **Saturation visibility** | Weak — mostly utilization gauges | First-class: `await`, `r`/`b`, PSI |
| **"Which process/file?"** | Cannot answer below container | `ps`, `lsof`, `strace`, `iotop` pinpoint it |
| **A *hanging* process** | Invisible (CPU 0%, mem flat — "looks fine") | `strace -p` shows the exact stuck syscall |
| **OOM ground truth** | `reason: OOMKilled` (no *why*) | `dmesg` shows the cgroup, the RSS, the trigger |
| **Requires node access** | No — works from your laptop | Yes — `ssh` / debug pod / `nsenter` |
| **Works when node is `NotReady`** | Often stale/blind | Still works — you're on the box |

**What each can do that the other cannot:**
- kubectl **cannot** show you `await`, a stuck `fsync` syscall, or which fd holds the etcd WAL. It summarizes and it lags.
- Node tools **cannot** show you cluster-wide context — "is this node worse than its 40 siblings?", pod scheduling, or historical trends across a fleet. That's Grafana's job.

**When would you NOT reach for these tools?** When the question is "which of my 200 nodes is unhealthy" or "is this a trend over the last week" — that's a dashboard/Prometheus question. Node tools are for *drilling into the one box you've already identified*. And on a locked-down node you may not have `ssh`; then it's `kubectl debug node/node-7 -it --image=busybox` (which drops you into a pod in the node's namespaces) or a `nsenter` from a privileged pod.

**Why this over that, in one sentence:** *Dashboards tell you a node is sick; the Linux tools tell you which resource, which process, and which syscall — and only the second kind of answer lets you actually fix it.*

> **Check yourself before Rung 7:** kubectl says a pod is `OOMKilled` on a node with 40 GB free RAM. Which single Linux command, and which specific string in its output, proves whether it was the *pod's cgroup limit* or the *whole node* that ran out — and why can't kubectl tell you that?

---

## 🧪 Rung 7 — The Prediction Test

Now the hands-on. For each, **write down the prediction before you run the command.** A surprise means your model is wrong — and *that's* the learning. (Tools note: `mpstat`, `iostat`, `sar` come from the **`sysstat`** package — `apt install sysstat` on Debian/Ubuntu, `dnf install sysstat` on RHEL/Fedora. `vmstat`/`free`/`uptime` are in `procps`. `strace`, `ltrace`, `lsof` are separate installs. PSI needs kernel ≥ 4.20 and, on some distros, `psi=1` on the kernel cmdline — Ubuntu 22.04 has it on by default.)

### Prediction 1 — Baseline: read the resource counters and correlate them (normal case)

> **I predict:** on a healthy, idle laptop/VM, `uptime` shows load near 0, `free -h` shows lots of `available` even if `used` looks high (because `buff/cache` counts as reclaimable), `vmstat 1 5`'s first line differs from the rest, and PSI is near zero.

```bash
uptime
#  14:03:11 up 3 days,  2:15,  2 users,  load average: 0.15, 0.20, 0.18
#  three numbers = 1-min, 5-min, 15-min avg of (running + uninterruptible) procs

free -h
#                total        used        free      shared  buff/cache   available
#  Mem:           15Gi       3.2Gi       6.1Gi       210Mi       6.4Gi        11Gi
#  the number that MATTERS is `available` (11Gi) — what apps can get WITHOUT swapping.
#  buff/cache (6.4Gi) is page cache; the kernel hands it back on demand. Don't panic at low `free`.

vmstat 1 5
#  procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
#   r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
#   0  0      0 6400000 120000 5200000    0    0    12    30  100  200  2  1 96  1  0   ← IGNORE (since-boot avg)
#   0  0      0 6399800 120000 5200000    0    0     0     0   90  180  1  0 99  0  0   ← real, now
#  r=runnable(CPU demand)  b=blocked(disk)  wa=io-wait%  si/so=swap. All ~0 = healthy.

cat /proc/pressure/cpu
#  some avg10=0.00 avg60=0.00 avg300=0.00 total=1234
cat /proc/pressure/memory
#  some avg10=0.00 ... full avg10=0.00 ...
cat /proc/pressure/io
#  some avg10=0.00 ... full avg10=0.00 ...
```

**Verify:** Load ≈ 0, PSI `avg10` ≈ 0, and `vmstat`'s line 1 ≠ line 2. Confirm you can explain why `free` shows little "free" but lots of "available." **A wrong result** (high load or PSI on an idle box) means something *is* running — jump to `top` and find it; your "idle" assumption was false, which is itself the lesson.

### Prediction 2 — Create real CPU saturation and watch load, run-queue, and PSI move together (edge/stress case)

> **I predict:** if I spawn more CPU-burning processes than I have cores, load average will climb toward (and past) the core count, `vmstat`'s `r` column will exceed the core count, `mpstat` `%idle` will hit ~0 with `%iowait` **staying near 0** (this is CPU, not disk), and `/proc/pressure/cpu` `some` will jump — because tasks are now *queued waiting for a CPU*.

```bash
nproc                       # how many CPUs, e.g. 4
# start MORE burners than cores so the run-queue backs up:
for i in $(seq 1 6); do yes > /dev/null & done     # 6 busy loops on 4 CPUs

uptime                      # load climbs toward 6 over ~1-5 min
vmstat 1 3
#   r  b ... wa
#   6  0 ...  0     ← r=6 runnable but only 4 CPUs → 2 always waiting = CPU SATURATION
mpstat -P ALL 1 2           # per-CPU: %idle≈0, %iowait≈0, %usr≈100  → CPU-bound, NOT disk
cat /proc/pressure/cpu      # some avg10 jumps to a high number — direct saturation proof

kill %1 %2 %3 %4 %5 %6      # stop the burners (or: pkill yes)
```

**Verify:** `r` > `nproc`, `%iowait` stays ~0 (proving CPU not disk), and PSI cpu `some` rises. **A wrong result** — if `%iowait` spiked instead — would mean `yes`/`/dev/null` unexpectedly hit disk, teaching you that even "pure CPU" tests can have I/O side effects. Contrast this deliberately with a *disk* stressor (`stress-ng --hdd 2` or `dd if=/dev/zero of=/tmp/f bs=1M count=4096 oflag=direct`) and watch `b`, `wa`, `await`, and `/proc/pressure/io` light up **instead** — same load number, completely different resource.

### Prediction 3 — Trace a running process's syscalls and find its open files (deep inspection)

> **I predict:** `strace -c` on a command will show a *histogram* of which syscalls dominate (great for "why is this slow"); `strace -f -e openat` will show it **following child processes** and printing only file-open syscalls; and `lsof -p` on a long-running server will list its open files and sockets — letting me answer "what is this process actually touching."

```bash
# (a) Summary mode: count syscalls, don't dump every one — best for "where's the time going?"
strace -c ls /usr
#  % time     seconds  usecs/call     calls    errors syscall
#  ------ ----------- ----------- --------- --------- ----------------
#   28.57    0.000200          10        19           openat
#   19.04    0.000133           8        16           mmap
#   ...
#  ------ ----------- ----------- --------- --------- ----------------
#  100.00    0.000700                    98         5 total

# (b) Follow forks, filter to file opens only — see exactly which files get touched:
strace -f -e openat ls /etc >/dev/null
#  openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
#  openat(AT_FDCWD, "/lib/x86_64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
#  openat(AT_FDCWD, "/etc", O_RDONLY|O_NONBLOCK|O_DIRECTORY|O_CLOEXEC) = 3

# (c) Attach to a LIVE, already-running process (needs sudo / CAP_SYS_PTRACE):
sleep 300 &                 # a stand-in "hung" process; note its PID
sudo strace -p $!           # watch it sit in nanosleep(...) forever, then Ctrl-C to detach
#  strace: Process 4242 attached
#  restart_syscall(<... resuming interrupted nanosleep ...>)   ← THIS is what "hung" looks like

# (d) What files/sockets does a process hold?
sudo lsof -p $!             # its cwd, its binary, its libs, its fds
```

**Verify:** In (a), the `% time` column tells you the hot syscall. In (c), you should see the process parked in **one** syscall — that is exactly how you'd catch a **hanging kubelet**: `sudo strace -p $(pgrep -x kubelet)` and if it's frozen in, say, a `read` on a container socket or a `futex`, you've found the stuck resource. **A wrong result** — `strace -p` erroring with `Operation not permitted` — teaches you about ptrace hardening (`/proc/sys/kernel/yama/ptrace_scope`); you need `sudo` or `CAP_SYS_PTRACE`, which matters inside restricted containers. (`ltrace <cmd>` is the sibling for **library** calls, e.g. seeing every `malloc`/`getenv` — but many distros ship it broken on PIE binaries, so lean on `strace` first.)

### Prediction 4 — Kubernetes flavor: prove an OOMKill was a cgroup limit, and find who holds the etcd WAL (K8s case)

> **I predict:** when a container is `OOMKilled`, `dmesg -T | grep -i oom` will show the kernel's kill report including `oom-kill:constraint=CONSTRAINT_MEMCG` (a **cgroup** limit, not node RAM) and `Out of memory: Killed process …` with the RSS and the process name — proving the *why* kubectl hides. Separately, `lsof` will name the process holding etcd's write-ahead log, and `lsof -i :6443` will identify the API server.

```bash
# --- OOM diagnosis (run on the node after a pod shows OOMKilled) ---
dmesg -T | grep -i oom
#  [Wed Jul 16 02:14:33 2026] java invoked oom-killer: gfp_mask=0x..., order=0, oom_score_adj=968
#  [Wed Jul 16 02:14:33 2026] memory: usage 131072kB, limit 131072kB, failcnt 27
#  [Wed Jul 16 02:14:33 2026] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),...
#  [Wed Jul 16 02:14:33 2026] Out of memory: Killed process 12345 (java) total-vm:..., anon-rss:130800kB
#  CONSTRAINT_MEMCG  = a cgroup (the pod's memory.max) hit its ceiling — NOT the node.
#  Cross-check the cgroup's own counter (cgroup v2):
cat /sys/fs/cgroup/kubepods.slice/.../memory.events   # oom_kill 1  ← the kernel's tally

dmesg -Tw | grep -i oom &    # -w = follow/wait: live-tail future OOM kills (foreground on newer utils)

# --- Who holds the etcd write-ahead log? (disk-saturation drilldown) ---
sudo lsof /var/lib/etcd/member/wal/0.wal
#  COMMAND  PID USER   FD   TYPE DEVICE SIZE/OFF     NODE NAME
#  etcd    1987 etcd   11uW  REG  259,1 64000000  1310772 /var/lib/etcd/member/wal/0.wal
#  → PID 1987 (etcd) holds it, fd 11, opened for write (W). If something ELSE also appears here,
#    that's your contention. Then: sudo lsof -p 1987  to see everything etcd is blocked on.

# --- Who is listening on the API server / etcd ports? ---
sudo lsof -i :6443           # kube-apiserver's listening + established connections
sudo lsof -i :2379           # etcd client port — see every client hammering etcd
```

**Verify:** The magic string is `constraint=CONSTRAINT_MEMCG`. If instead you see `CONSTRAINT_NONE`, the **node** itself ran out of RAM (a global OOM) — a different, worse problem meaning your pod limits or node capacity are misconfigured. That single word changes your entire remediation. For `lsof`, confirm the etcd WAL is held **only** by etcd; a second writer is a misconfiguration or a rogue backup job stealing your disk. **A wrong result** — `dmesg` empty of OOM lines despite `OOMKilled` — usually means the ring buffer already rotated out the event (it's a fixed-size buffer); reach for `journalctl -k --since "10 min ago"` which persists it, or the container's kubelet events. Map it home: `MemoryPressure=True` on the node is kubelet reading the *same* `/proc/pressure/memory` and cgroup `memory.available` you can `cat` yourself — the node condition is downstream of these files.

---

## 🏔 Rung 8 — Capstone: Compress It

**One sentence, no notes:**
> Diagnosing a sick machine is walking the resource list (CPU, memory, disk, net) and measuring Utilization, Saturation, and Errors for each — because every performance problem is one resource that's too busy, backed up, or failing, and every tool is just a pretty-printer over a kernel counter in `/proc`.

**Explain it to a beginner (3 sentences):**
The computer keeps a running scoreboard in memory of everything it does — how busy each CPU and disk is, how much memory is used, how long I/O takes. Tools like `top`, `free`, `vmstat`, and `iostat` just read that scoreboard a second apart and show you the change, while `strace` and `lsof` zoom into one program to show which system calls and files it's touching. If you always ask "which *resource* is the problem, and is it *busy* or *backed up*?" instead of "the server is slow," you'll find the real cause instead of guessing.

**Sub-capabilities mapped to the one core idea (U/S/E per resource):**

| Sub-capability | Which USE letter / resource | How it derives from the one idea |
|---|---|---|
| `uptime`, load average | Saturation (CPU+disk) | Count of R+D processes = work queued |
| `free -h`, `/proc/meminfo` | Utilization (memory) | How full is RAM (minus reclaimable cache) |
| `vmstat 1` (`r`/`b`/`wa`/`si`/`so`) | Sat (CPU `r`, disk `b`/`wa`), Util (swap) | Deltas of scheduler + memory counters |
| `mpstat`, `top`/`htop` | Utilization (per-CPU) | Who's busy, and busy with what (`%usr` vs `%iowait`) |
| `iostat -xz` (`%util`, `await`) | Util + **Saturation** (disk) | `%util`=busy, `await`=queue latency |
| PSI `/proc/pressure/*` | **Saturation** (all resources) | Direct stall-time meter — the purest S signal |
| `strace`/`ltrace` | Errors / hang drilldown | Which syscall/library call is stuck or failing |
| `lsof` | drilldown (which file/socket) | Maps a resource back to a process + fd |
| `dmesg`/`journalctl -k` | **Errors** | Kernel's own report: OOM, I/O errors, hardware |

**Which rung to revisit hands-on (be honest):**
- If you still think **load average = CPU usage**, redo **Rung 3** (the three process states) and **Prediction 2** — build the CPU stressor and *watch* `%iowait` stay at zero.
- If **`iostat`'s `await` vs `%util`** distinction is fuzzy, that's **Rung 2 + Prediction 2's disk variant** — the difference between "busy" and "backed up" is the crux of the whole method.
- If you couldn't read an **OOM report** and say "cgroup vs node" from `constraint=`, drill **Prediction 4** — that's the single most common real K8s page you'll answer.
- If PSI still feels abstract, `cat /proc/pressure/memory` on a healthy box, then run the stressor and `cat` it again — feeling the numbers move is worth more than any paragraph.

---

## Related concepts

- [cgroups](14-cgroups.md) — where `memory.max`, the OOM killer, and `OOMKilled` actually live; the enforcement side of what this doc diagnoses.
- [processes-job-control](07-processes-job-control.md) — process states (R/D/S/Z), `ps`, `top`, signals — the objects load average and `vmstat` are counting.
- [linux-philosophy](01-linux-philosophy.md) — "everything is a file": `/proc` and `/sys` are the counters every tool here reads.
- [storage-mounts](15-storage-mounts.md) — disks, filesystems, and OverlayFS — the layer whose `await` strangles etcd.
- [systemd-services](16-systemd-services.md) — `journald` and `journalctl -k`, the persistent sibling of `dmesg`.
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full node-triage quick reference that ties this method to every Kubernetes signal.
