# Processes & Job Control
> A running program is a kernel bookkeeping entry with a PID — and every pod on your node is one of those entries. Learn to read, signal, background, and prioritize them.

---

## Rung 0 — 🛠 The Setup

**What am I learning?** How Linux turns a program (a file on disk) into a *process* (a living thing with a PID, a state, a parent, and a fate) — and how you observe, signal, background, and prioritize those processes.

**Why did it land on my desk?** You are on call. A pod is stuck `Terminating` for 90 seconds and finally gets force-killed. Another node is at load average 40 and `kubectl top` blames a pod called `noisy-batch`. A teammate ran `kubectl port-forward` in a terminal, closed their laptop, and the tunnel died. Someone asks "why is our container image running `tini` as PID 1?" Every one of these is a *process and job control* question wearing a Kubernetes costume. You cannot answer any of them from the `kubectl` layer alone — the answers live in the Linux process model.

**What do I already know?** You are fluent in `kubectl get pods`, deployments, and probes. You know a container "runs a process." What you may not yet have is the mechanical picture: that a container *is* a Linux process (in namespaces), that "Terminating" is literally the kernel delivering `SIGTERM`, that a "zombie" is a real kernel state you can create by accident, and that `nice` values are the same knob whether you type them by hand or let the kubelet set them via cgroups.

By the end you will read `ps aux` like a sentence, know exactly what `kill -9` does that `kill -15` doesn't, and understand why closing a terminal kills your `port-forward` unless you `disown` it.

---

## Rung 1 — 🔥 The Pain

**The problem that forced processes to exist.** Early computers ran one program at a time. You loaded a card deck, it ran to completion, it stopped. If you wanted two things "at once" — a compile and an editor — you were out of luck, or you bought a second machine. The pain was **isolation and multiplexing**: how does one CPU pretend to run many independent programs, each with its own memory and its own idea of "I am running," without them corrupting each other?

The answer the OS invented is the **process**: a container of state (memory map, open files, a program counter, a priority, a parent) that the kernel schedules onto the CPU in slices. The process is the unit the kernel *accounts* for. Without it there is no multitasking, no "kill this one, leave that one," no priorities, no `Ctrl-Z`.

**What people did before job control, and why it hurt.** Even after processes existed, early Unix shells could run only one thing interactively. If you started a long job, your terminal was hostage until it finished. You could not pause it, could not push it to the background, could not check on it. **Job control** (the `&`, `Ctrl-Z`, `fg`, `bg` machinery, added in the Berkeley `csh` and later standardized) fixed this: one terminal, many jobs, some in the foreground with your keyboard, others chugging in the background.

**What breaks without this knowledge, for you specifically.**
- A pod won't die gracefully because the app ignores `SIGTERM` — and you don't know that's what "graceful shutdown" *means*.
- A container leaks **zombie** processes because the app runs as PID 1 and never reaps its children, and eventually the pod exhausts the PID limit.
- `kubectl port-forward` dies the moment your SSH session drops, because it was a foreground job tied to a terminal you didn't detach it from.
- A batch pod pins the node's CPU and you don't know you can `renice` it while you plan a real fix.

**Who feels the pain most?** The platform engineer at 3 a.m. staring at a `Terminating` pod, and the app team whose "clean shutdown" quietly wasn't.

> Check yourself before Rung 2: Kubernetes' `terminationGracePeriodSeconds` defaults to 30. From the pain above, *derive* what must happen at second 0 and at second 30 — and why there have to be two different events, not one.

---

## Rung 2 — 💡 The One Idea

Here is the sentence. Memorize it:

> **A process is a kernel-tracked instance of a running program, identified by a PID, born from its parent via fork+exec, living in one of a few states, and controllable only by sending it signals.**

Everything in this document is derived from that sentence:

- "kernel-tracked … identified by a PID" → therefore there is a table you can *view* (`ps`, `top`, `/proc/<pid>`). **Viewing** falls out.
- "born from its parent via fork+exec" → therefore every process has a **parent (PPID)**, there is a **tree** with a root (**PID 1**), and orphans get re-parented. **The tree, init, orphans, zombies** fall out.
- "living in one of a few states" → therefore **R/S/D/Z/T** exist, and "stuck" has a precise meaning. **States** fall out.
- "controllable only by sending it signals" → therefore you never "reach in and stop" a process; you *ask* it via a signal it may catch, ignore, or (for 9) cannot. **kill, pkill, SIGTERM/SIGKILL, job control, terminationGracePeriod** all fall out. Job control is just the shell sending you `SIGTSTP`/`SIGCONT` behind `Ctrl-Z`/`bg`.
- Scheduling a PID onto the CPU is weighted by a **niceness** → **nice/renice, noisy neighbors** fall out.

If you remember only one thing: **you control processes by sending signals, not by touching them directly.** Kubernetes is built on exactly this — "delete this pod" becomes "send the process a signal and wait."

> Check yourself before Rung 3: Using only the One Idea, explain why `kill -9` is fundamentally different in *kind* (not just strength) from `kill -15`. What clause of the sentence does 9 violate?

---

## Rung 3 — ⚙️ The Machinery (the important one — go slow)

### 3.1 Birth: fork + exec

There is no "run this program" syscall that does it in one step. Unix splits it in two, and this split explains almost everything downstream.

- **`fork()`** — the kernel *clones* the calling process. The child is a near-identical copy: same memory (copy-on-write), same open file descriptors, a **new PID**, and its **PPID set to the parent**. Both processes return from `fork()`; the child gets `0`, the parent gets the child's PID. That's how each knows who it is.
- **`exec()`** (the `execve` family) — the child then *replaces its own program image* with a new binary. Same PID, brand-new code and memory. The process "becomes" `nginx` or `kubelet`.

So starting `ls` from your shell is: bash `fork()`s a copy of itself, the copy `execve("/usr/bin/ls", …)`, and bash `wait()`s for it. This is the atom of everything.

```
   bash (PID 4000)
        │  fork()
        ├───────────────► child (PID 4137)  copy of bash
        │  wait(4137)         │  execve("/usr/bin/ls")
        │  (blocks)           ▼
        │                   ls   (PID 4137, new program image)
        │                     │  runs, then _exit(0)
        │  ◄──────────────────┘  child becomes a ZOMBIE until reaped
        ▼
   bash reaps exit status, prints prompt
```

### 3.2 What a process actually *is* to the kernel

Inside the kernel, each process is a struct (`task_struct`) in a big linked table. It holds: the PID, the PPID, the process **state**, the memory map, the table of **open file descriptors**, the **owning uid/gid**, the scheduling **priority/niceness**, pending **signals**, and the cgroup it belongs to. You can *read this struct's public face* through `/proc/<pid>/` — because on Linux, "everything is a file," a process is a directory:

```bash
cat /proc/self/status       # human-readable: State, PPid, Uid, Threads, VmRSS…
cat /proc/self/stat         # the raw one-line version ps/top parse
ls  /proc/self/fd           # every open file descriptor as a symlink
cat /proc/1/cgroup          # which cgroup PID 1 lives in
```

### 3.3 States: R / S / D / Z / T

A process is always in exactly one state. `ps` shows it in the `STAT` column.

| Code | Name | What it means mechanically |
|---|---|---|
| **R** | Running / Runnable | On a CPU *or* on the run-queue waiting for a CPU slice. |
| **S** | Interruptible Sleep | Waiting for an event (I/O, a timer, a socket). **Can** be woken by a signal. Most processes sit here. |
| **D** | Uninterruptible Sleep | Waiting deep in the kernel (usually disk/NFS I/O). Cannot be interrupted, **even by SIGKILL**, until the I/O returns. A pile of D is how a bad disk/NFS mount hangs a node. |
| **Z** | Zombie | Already dead; exists only as an exit-status entry the parent hasn't collected yet. Uses no CPU/memory, only a PID slot. |
| **T** | Stopped | Suspended by `SIGSTOP`/`SIGTSTP` (this is what `Ctrl-Z` does). Frozen until `SIGCONT`. |

Key insight for on-call: **`kill -9` cannot move a process out of `D`.** If a pod is stuck and even force-delete won't clear the underlying process, suspect `D` state on bad storage — a Linux problem, not a Kubernetes one.

### 3.4 The tree and PID 1

`fork` gives every process a parent, so all processes form a **tree**. The root is **PID 1**, the first userspace process the kernel starts at boot. On a normal host that's **`systemd`**. PID 1 has two jobs that matter enormously:

1. **It is the ancestor of everything.** Kill it and the system goes down.
2. **It reaps orphans.** When a process's parent dies before it does, the child is **re-parented to PID 1**. When that child later exits, PID 1 must call `wait()` to collect its exit status — **reaping** it so the zombie entry disappears.

```
              PID 1  (systemd / or pause / or tini)
             /   |   \
     sshd   containerd  kubelet
       |        |          \
     bash    containerd-shim  (talks to kernel, cgroups)
       |        |
      vim    pause (PID 1 *inside* the pod's PID namespace)
                |
              nginx  ── worker ── worker
```

### 3.5 Why this is THE container question

A container is just a process (or a small tree of processes) placed in its own **namespaces** (see [namespaces](13-namespaces.md)) and **cgroups** (see [cgroups](14-cgroups.md)). One of those is the **PID namespace**: inside it, the container's main process sees itself as **PID 1**.

That is a trap. Normal apps are *not written* to be PID 1. They don't reap orphaned children, and PID 1 has special signal semantics: **the kernel does not apply default signal actions to PID 1** — so if your app-as-PID-1 has no `SIGTERM` handler, `SIGTERM` is *silently ignored*, and Kubernetes' graceful shutdown does nothing until the SIGKILL at 30s.

Kubernetes and the container runtime address this in two different places:
- **By default, each container gets its own PID namespace**, so your app process really is PID 1 of *its own* namespace and is responsible for reaping *its own* children. If it might spawn children, you wrap it in a tiny init like **`tini`** (or use the runtime's built-in init). `tini` becomes PID 1, forwards signals to your app, and reaps its zombies. Docker's `--init` flag injects exactly this.
- The **`pause` container** (the pod "sandbox") holds the pod's shared namespaces — network, IPC, UTS — open so they survive individual container restarts. It is PID 1 of the *sandbox's* PID namespace and loops on `pause()`, reaping any zombies it parents. It only becomes the reaper *for your app's* children when you opt into a shared PID namespace with **`shareProcessNamespace: true`**, which makes every container in the pod share one PID namespace with `pause` as PID 1.

### 3.6 Signals: the only remote control you have

A **signal** is a small integer the kernel delivers to a process to interrupt it. The process can, for most signals, register a **handler**, **ignore** it, or let the **default action** happen (often "terminate"). Two signals are special: **9 (SIGKILL)** and **19 (SIGSTOP)** **cannot be caught, blocked, or ignored** — the kernel handles them itself. That's your guaranteed hammer.

```
   you ──kill(pid, SIGTERM)──► kernel ──► marks signal pending on target task
                                            │
                             target wakes ──┤ has a handler? ──► run handler (clean up, then maybe exit)
                                            │ ignoring it?     ──► nothing happens
                                            │ default action?  ──► kernel terminates it
   SIGKILL(9)/SIGSTOP(19): kernel does it directly, target gets no say
```

The common ones:

| Signal | Number | Default action | Catchable? |
|---|---|---|---|
| `SIGHUP` | 1 | Terminate (historically "hangup") — often repurposed as "reload config" | Yes |
| `SIGINT` | 2 | Terminate — this is `Ctrl-C` | Yes |
| `SIGKILL` | 9 | **Terminate, immediately, unstoppably** | **No** |
| `SIGTERM` | 15 | Terminate — the **polite** "please shut down" (the default `kill`) | Yes |
| `SIGSTOP` | 19 | **Stop/suspend** | **No** |
| `SIGCONT` | 18 | Resume a stopped process | (Yes) |
| `SIGTSTP` | 20 | Stop from terminal — this is `Ctrl-Z` (catchable, unlike SIGSTOP) | Yes |

**This is the Kubernetes pod-termination contract, exactly:** on delete, the kubelet (via containerd) sends the container's PID 1 a **`SIGTERM`**, runs any `preStop` hook, and waits up to **`terminationGracePeriodSeconds`** (default **30**). If the process is still alive at the deadline, it sends **`SIGKILL`**. `SIGTERM` = "please clean up"; `SIGKILL` = "times up." Now you know why an app that ignores SIGTERM always takes the full 30 seconds to die.

### 3.7 Scheduling and niceness

The kernel scheduler (CFS on most systems, or EEVDF on newer kernels) decides who gets the CPU. Each process has a **niceness** from **-20 (greediest)** to **+19 (most generous)**; higher nice = *nicer to others* = **less** CPU. Only root can make a process *greedier* (lower the nice number). This is the manual version of what cgroup `cpu.weight`/`cpu.shares` does for whole pods — Kubernetes sets CPU *requests* which become cgroup weights, but on a single node you can still `renice` an individual offending process as a stopgap.

> Check yourself before Rung 4: A process is re-parented to PID 1 when its parent dies. Using 3.4 + 3.5, explain why an app running as PID 1 *inside a container* creates zombies that a normal host never accumulates — and name the two components Kubernetes uses to prevent it.

---

## Rung 4 — 🏷️ The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|---|---|---|
| **PID** | Integer key identifying a process in the kernel's task table | 3.2 birth; the primary key everywhere |
| **PPID** | The PID of the parent that `fork()`ed it | 3.1 fork, 3.4 tree |
| **fork** | Syscall that clones a process (new PID, same image) | 3.1 birth |
| **exec / execve** | Syscall that replaces a process's program image (same PID) | 3.1 birth |
| **wait / reap** | Parent collecting a dead child's exit status, freeing its entry | 3.1, 3.4 zombie removal |
| **PID 1 / init** | First userspace process; ancestor of all; the reaper of orphans | 3.4, 3.5 |
| **pause container** | K8s sandbox process that holds namespaces open and reaps zombies | 3.5 |
| **tini** | Tiny init you wrap your app in so it reaps zombies & forwards signals | 3.5 |
| **State R/S/D/Z/T** | The single lifecycle state the kernel records for the task | 3.3 |
| **Zombie (Z)** | Dead process whose exit status is uncollected | 3.3, 3.4 |
| **Orphan** | Live process whose parent died; re-parented to PID 1 | 3.4 |
| **Signal** | Small integer the kernel delivers to interrupt/notify a process | 3.6 |
| **SIGTERM (15)** | Catchable "please shut down"; the default `kill`; K8s step 1 | 3.6 |
| **SIGKILL (9)** | Uncatchable "die now"; K8s step 2 after grace period | 3.6 |
| **SIGHUP (1)** | "Hangup"; conventionally reused as "reload config" | 3.6 |
| **SIGSTOP/SIGTSTP** | Suspend a process (19 uncatchable / 20 = `Ctrl-Z`) | 3.3, 3.6, job control |
| **SIGCONT (18)** | Resume a stopped process | job control |
| **Job** | A shell's handle for a pipeline you started, numbered `%1`, `%2`… | Rung 3 job control |
| **Foreground/Background** | Whether a job owns the terminal + keyboard (`&`, `fg`, `bg`) | job control |
| **nohup** | Wrapper that makes a job ignore SIGHUP so it survives terminal close | Rung 7 ex.3 |
| **disown** | Shell builtin that removes a job from the shell's job table | Rung 7 ex.3 |
| **Niceness / nice value** | -20..+19 scheduling weight; higher = less CPU | 3.7 |
| **renice** | Change the niceness of an already-running process | 3.7 |
| **terminationGracePeriodSeconds** | K8s wait between SIGTERM and SIGKILL (default 30) | 3.6 |

**"Same kind of thing wearing different names":**
- **`SIGTSTP` (Ctrl-Z) and `SIGSTOP`** — both "freeze the process." Difference: 20 is catchable (an app can refuse or clean up), 19 is not.
- **`kill`, `pkill`, `kubectl delete pod`** — all three are *"send a signal to a process(es)."* `kill` by PID, `pkill` by name/pattern, `kubectl delete` by pod → kubelet → SIGTERM-then-SIGKILL.
- **`nice` and `renice`** — same knob (the niceness value); `nice` sets it at launch, `renice` changes it live. And both are the single-process cousins of cgroup `cpu.weight`.
- **`&`, `bg`, `nohup`, `disown`** — all about *"where does this job live relative to my terminal?"* Background it, resume it in background, immunize it from hangup, detach it from the shell.
- **`ps`, `top`, `pgrep`, `pstree`, `/proc`** — all just *readers of the same task table*, differing in shape (snapshot / live / filter / tree / raw).

> Check yourself before Rung 5: `Ctrl-Z` then `bg` then `disown` — for each step, name the signal or table operation happening underneath. (Hint: only one of the three sends a signal.)

---

## Rung 5 — 🔬 The Trace: deleting a pod, all the way to the signal

Let's follow `kubectl delete pod web-0` from your keyboard down to the actual `kill()` on the node. This is the single most useful trace in this whole document.

```
[1] kubectl delete pod web-0
        │  writes to the API
        ▼
[2] kube-apiserver  ── sets metadata.deletionTimestamp, deletionGracePeriodSeconds=30
        │  persists to etcd; pod now shows "Terminating"
        ▼
[3] kubelet (on the node hosting web-0) sees the update via its watch
        │  runs preStop hook if defined, then asks the runtime to stop the container
        ▼
[4] containerd → containerd-shim → runc
        │  looks up the container's init process PID on the host
        ▼
[5] kernel: kill(PID, SIGTERM)      ◄── THE signal. Second 0.
        │  delivered to the container's PID-1 process (your app, or tini)
        ▼
[6a] App has a SIGTERM handler → drains connections, flushes, exit(0)
        │  container stops, kubelet reports it, apiserver removes pod from etcd. DONE early.
[6b] App ignores/lacks handler → nothing happens; process keeps running
        │  kubelet counts down the 30s grace period…
        ▼
[7] at grace deadline: kernel kill(PID, SIGKILL)  ◄── uncatchable. Second 30.
        │  process dies unconditionally (unless wedged in D-state I/O)
        ▼
[8] container gone, pod object deleted from etcd, PID slot freed
```

Now the same trace on the node, as commands you could actually run to *watch* it:

```bash
# On the node, find the container's main process PID (the one the signal hits):
pgrep -a -f 'nginx: master'          # -a shows the full command line next to the PID
#  5123 nginx: master process /usr/sbin/nginx

ps -o pid,ppid,stat,comm -p 5123
#    PID   PPID STAT COMMAND
#   5123   5098 Ss   nginx        # STAT "Ss": S=sleeping, s=session leader; PPID 5098 = the containerd-shim supervising this container

# What Kubernetes does at second 0 is exactly this:
kill -15 5123          # SIGTERM: nginx catches it, finishes in-flight requests, exits cleanly

# What Kubernetes does at second 30 (if it were still alive) is exactly this:
kill -9 5123           # SIGKILL: gone, no cleanup, no say
```

The punchline: **there is nothing magic in "Terminating." It is `kill -15`, a 30-second wait, then `kill -9`.** Every graceful-shutdown feature you write in an app is just a SIGTERM handler racing that clock.

> Check yourself before Rung 6: In step [6b] the app ignores SIGTERM. If that app is running as **PID 1** inside the container (no tini), would `kill -15` from step [5] behave *differently* than if it were PID 37? Explain using the special PID-1 signal rule from 3.5.

---

## Rung 6 — ⚖️ The Contrast

**The alternative worldview: "just kill it / just restart the box."** Before signals and job control were internalized, the operational reflex was blunt: reboot the server, or `kill -9` everything. It works, but it's a sledgehammer — no clean shutdown, no draining, corrupted files, lost in-flight requests.

The modern approach — **graceful, signal-based lifecycle** — is what Kubernetes bakes in. Here's the honest comparison:

| Capability | Blunt `kill -9` / reboot | Signal-based lifecycle (SIGTERM → grace → SIGKILL) |
|---|---|---|
| Clean resource release (flush, close conns) | ✗ none | ✓ app cleans up in its handler |
| Guaranteed to stop the process | ✓ (except D-state) | ✓ eventually (SIGKILL backstop) |
| Data-safe for stateful apps | ✗ risky | ✓ if handler is written |
| Complexity | trivial | needs a handler + a sane PID 1 |
| Works when app is wedged in `D` | ✗ (nothing works) | ✗ (nothing works) |
| Fits K8s pod deletion / rollouts | ✗ | ✓ this *is* the model |

**What each can do that the other can't:**
- `kill -9` can stop a process that is *ignoring everything else* — your guaranteed backstop. Graceful shutdown *cannot* guarantee a misbehaving app stops (that's *why* SIGKILL exists as step 2).
- Graceful shutdown can preserve data and finish work; `kill -9` never can.

**When would I NOT want the graceful path?** When you *know* the process is hung and holding a lock you need back now, or when it's stuck in `D` and only clearing the underlying I/O (or rebooting) will help — reaching for `--grace-period=0 --force` on the pod is the "skip the 30s, go straight to SIGKILL" escape hatch. Use it knowingly, not reflexively.

**Why this over that, in one sentence:** Prefer signal-based graceful shutdown because it's the only path that both stops the process *and* lets it protect its data — with SIGKILL always available as the last resort.

> Check yourself before Rung 7: `kubectl delete pod x --grace-period=0 --force` — translate that flag into the exact sequence of signals (or absence of one) the node performs, versus a normal delete.

---

## Rung 7 — 🧪 The Prediction Test

Commit to each prediction *out loud* before you run the command. A wrong prediction is the most valuable thing here — it means your model was off, and now you'll fix it.

### Example 1 — Normal case: SIGTERM is catchable, SIGKILL is not

**Prediction:** *If I trap SIGTERM in a shell process and then `kill -15` it, my trap runs and the process keeps living (I chose not to exit). If I then `kill -9` it, it dies instantly with no message, BECAUSE 9 is handled by the kernel and never reaches my handler.*

```bash
# Start a process that catches SIGTERM and refuses to die:
sleep 600 &                      # simple victim in the background
VICTIM=$!                        # $! = PID of the most recent background job
echo "victim is $VICTIM"

kill -15 $VICTIM                 # SIGTERM; sleep has no handler, default action = terminate
jobs                             # [1]+  Terminated  sleep 600     → it died

# Now the "catches and ignores" version, to see the difference:
bash -c 'trap "echo caught SIGTERM, staying alive" TERM; echo pid $$; while true; do sleep 1; done' &
TRAPPER=$!
kill -15 $TRAPPER                # prints "caught SIGTERM, staying alive" — still running
kill -9  $TRAPPER                # no message, gone
```

**Verify:** After `kill -15` on the trapper you should see its `caught SIGTERM` line and it *stays* in `jobs`. After `kill -9` it vanishes with no output. If `kill -15` had killed the trapper anyway, your trap wasn't installed — re-check the `trap` syntax. This *is* the app-that-ignores-SIGTERM scenario that makes pods take the full 30s.

### Example 2 — Edge/failure case: create a real zombie and watch PID 1 reap it

**Prediction:** *If a parent forks a child and never calls `wait()`, the child that exits becomes a `Z` (zombie) — visible in `ps` with `<defunct>`. If I then kill the parent, the zombie is re-parented to PID 1, which reaps it and it disappears, BECAUSE only a `wait()` clears the exit-status entry and PID 1 always does that for orphans.*

```bash
# Parent sleeps without ever reaping its child; child exits immediately -> zombie.
# Put it in a small script so the parent/child relationship is unambiguous:
cat > /tmp/mkzombie.sh <<'EOF'
#!/bin/bash
( sleep 0.1 ) &        # child that exits almost immediately
child=$!
sleep 300              # parent stays alive but NEVER wait()s -> child becomes a zombie
EOF
chmod +x /tmp/mkzombie.sh
/tmp/mkzombie.sh &
PARENT=$!

sleep 1
ps -o pid,ppid,stat,comm --ppid $PARENT
#   PID  PPID STAT COMMAND
#  8899  8890 Z    sleep <defunct>     # STAT Z = zombie, "<defunct>" is the giveaway

kill $PARENT                            # parent dies; zombie re-parented to PID 1
sleep 1
ps -o pid,ppid,stat,comm --ppid 1 | grep -i defunct   # (empty) — PID 1 reaped it
```

**Verify:** You should see one `Z … <defunct>` line while the parent lives, and it should be *gone* after you kill the parent (PID 1 reaped it). Note: `kill -9` on a **zombie does nothing** — it's already dead; only reaping clears it. This is precisely why a container whose app is PID 1 and never reaps will accumulate `<defunct>` entries — and why the **pause container / tini** exist to be that reaper.

### Example 3 — Kubernetes-flavored case: `port-forward` as a background job that must survive terminal close

**Prediction:** *If I background `kubectl port-forward` with `&` and then close the shell, the tunnel dies, BECAUSE closing the terminal sends `SIGHUP` to its jobs. If I instead `nohup … &` (or `disown` it), the SIGHUP is ignored/detached and the tunnel survives.*

```bash
# The fragile way — tied to this terminal:
kubectl port-forward svc/web 8080:80 &      # job [1], PID in $!
jobs                                         # [1]+ Running  kubectl port-forward ...
#   -> if you now exit this shell, the shell SIGHUPs job [1] and the forward dies.

# The durable way #1 — immunize against SIGHUP and detach output:
nohup kubectl port-forward svc/web 8080:80 > /tmp/pf.log 2>&1 &
disown                                       # also drop it from the shell's job table
#   -> now `exit` leaves the forward running; check /tmp/pf.log for "Forwarding from ..."

# Prove the SIGHUP mechanism directly on any command:
sleep 600 &
kill -HUP %1                                  # %1 = job 1; default SIGHUP action = terminate
jobs                                          # [1]+ Hangup   sleep 600   -> HUP killed it
```

**Verify:** With the plain `&` version, open a second terminal, `curl localhost:8080` — works; then close the first terminal and `curl` again — connection refused (SIGHUP killed it). With `nohup … & disown`, it keeps working after the terminal closes; `pgrep -a -f port-forward` still finds it. If `nohup` didn't help, check that you also redirected output (a forward writing to a closed terminal can still die on `SIGPIPE`). This is the exact reason your teammate's tunnel "randomly" dies — it was a foreground/HUP-bound job all along.

### Example 4 — Priority: renice a noisy neighbor

**Prediction:** *If I launch a CPU hog and `renice` it to +19, it will keep running but yield the CPU to everything else, BECAUSE niceness raises the "be generous" weight in the scheduler — it throttles share, it does not stop the process.*

```bash
# Launch a CPU burner at high niceness from the start:
nice -n 10 sh -c 'while :; do :; done' &     # starts nice=10 (lower priority)
HOG=$!
ps -o pid,ni,comm -p $HOG                     # NI column shows 10

# It's still too greedy? Push it to the max generosity (root or owner):
renice -n 19 -p $HOG                          # renice: <pid>: old priority 10, new priority 19
ps -eo pid,ni,comm | grep -w $HOG             # confirm NI = 19

# Watch it live and confirm it steps aside under contention:
top -p $HOG                                    # press 'q' to quit; %CPU drops when others need CPU
kill $HOG                                       # clean up
```

**Verify:** `ps -o pid,ni,comm` should show `NI` going 10 → 19. In `top`, the hog's `%CPU` should fall the moment another busy process appears. Note the asymmetry: you can *raise* niceness (be nicer) as a normal user, but **lowering** it below your current value needs root — try `renice -n -5 -p $HOG` as a non-root user and watch it fail with `Operation not permitted`; that teaches you the privilege boundary. This is your stopgap for a node's noisy pod before you fix it properly with CPU requests/limits (cgroups).

### Bonus drill — read the whole board with the canonical viewers

```bash
ps aux                 # every process, BSD style: USER PID %CPU %MEM VSZ RSS TTY STAT ... COMMAND
ps -ef                 # every process, System V style: UID PID PPID C STIME TTY TIME CMD
pgrep -a kubelet       # PIDs whose name matches 'kubelet', -a prints the full command line
pstree -p              # the whole tree with PIDs in parentheses — see pause -> app -> workers
kill -l                # list every signal name↔number mapping (1=HUP ... 9=KILL ... 15=TERM)
pkill nginx            # send SIGTERM to every process named nginx (by name, not PID)
ps -eo pid,ni,comm     # custom columns: PID, niceness, command — the priority audit view
```

`top` interactive keys worth muscle-memory: **`M`** sort by memory, **`P`** sort by CPU, **`k`** kill a PID (it prompts for PID then signal), **`1`** expand per-CPU-core view, **`q`** quit. `htop` (install with `apt install htop` on Ubuntu, `dnf install htop` on RHEL/Fedora) is the friendlier, scrollable, color version with the same ideas.

---

## Rung ⛰ Capstone — Compress It

**One sentence (no notes):** A process is a kernel-tracked, PID-identified running program born by fork+exec, living in a state, and steered only by signals — which is exactly how Kubernetes starts, stops, and prioritizes every container.

**Three-sentence beginner explanation:** Every running program on Linux is a *process* with an ID number (PID) and a parent, and they form a tree whose root is PID 1. You can't reach into a process to control it — you *send it a signal*, like SIGTERM ("please stop") or the unstoppable SIGKILL ("stop now"), and you can pause, background, or re-prioritize it. Kubernetes deleting a pod is literally this: send the container's process SIGTERM, wait 30 seconds, then SIGKILL.

**Sub-capabilities mapped back to the One Idea ("controlled only by sending signals, in a tree, by state"):**
- Viewing (`ps`, `top`, `pgrep`, `pstree`) → reading the kernel task table the One Idea describes.
- Signals (`kill`, `pkill`, SIGTERM/KILL/HUP) → the "controlled only by signals" clause.
- Job control (`&`, `Ctrl-Z`, `fg`, `bg`, `nohup`, `disown`) → your shell sending you SIGTSTP/SIGCONT and managing where a job lives vs. the terminal.
- Zombies/orphans/PID 1 → the "born from a parent in a tree" clause; reaping is the parent's `wait()`.
- `nice`/`renice` → weighting how the scheduler runs a PID; the single-process form of cgroup CPU shares.
- K8s termination + pause/tini → all of the above, wearing a container costume.

**Which rung to revisit hands-on:** **Rung 7, Example 2 (zombies).** Reading about `<defunct>` is not the same as *making one* and watching PID 1 eat it — do that until it's boring, because it's the mechanical heart of "why does my container need tini." Second priority: Example 3, because a dead `port-forward` will bite you again next week.

---

## Related concepts
- [linux-philosophy](01-linux-philosophy.md) — `/proc/<pid>` is how a process becomes a readable file.
- [shell-and-environment](02-shell-and-environment.md) — the shell is the parent that forks your commands and runs job control.
- [namespaces](13-namespaces.md) — the PID namespace is why a container's app thinks it's PID 1.
- [cgroups](14-cgroups.md) — `cpu.weight`/`memory.max`: the pod-scale version of `nice` and OOM-kill.
- [systemd-services](16-systemd-services.md) — the real PID 1 on your nodes, and how it supervises kubelet/containerd.
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full node-triage cheat sheet this all feeds into.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** `terminationGracePeriodSeconds` defaults to 30. Derive what must happen at second 0 and at second 30 — and why there have to be two different events, not one.

**A:** At second 0 the kubelet sends the container's process a *polite, catchable* request to shut down — `SIGTERM` — so the app can drain connections, flush data, and exit cleanly. At second 30, if the process is still alive, it sends an *unstoppable* `SIGKILL` that terminates it unconditionally. There must be two events because a single event can't be both: a catchable signal gives the app a chance to protect its data but also the ability to ignore the request, while an uncatchable one guarantees termination but allows no cleanup. So the design is "ask nicely first, then guarantee death at the deadline" — graceful shutdown with a hard backstop.

### Before Rung 3
**Q:** Using only the One Idea, explain why `kill -9` is fundamentally different in *kind* (not just strength) from `kill -15`. What clause of the sentence does 9 violate?

**A:** The One Idea says a process is "controllable only by sending it signals" — you *ask* it via a signal it may catch, ignore, or take the default action on. `kill -15` (SIGTERM) obeys that model: it's a request delivered to the process, which gets a say (run a handler, ignore it, or die by default). `kill -9` (SIGKILL) violates the "the process may respond" part of that clause: it cannot be caught, blocked, or ignored — the kernel terminates the process directly and the target gets no say at all. So 9 isn't a stronger request; it's not a request at all — it bypasses the process entirely and is handled by the kernel itself.

### Before Rung 4
**Q:** Explain why an app running as PID 1 *inside a container* creates zombies that a normal host never accumulates — and name the two components Kubernetes uses to prevent it.

**A:** On a normal host, when a process's parent dies the child is re-parented to PID 1 (systemd), which dutifully calls `wait()` to reap it, so zombies never pile up. Inside a container's PID namespace, the app itself *is* PID 1 — and normal apps are not written to be init: they never `wait()` on orphaned children re-parented to them, so every dead descendant stays a `Z` entry, eventually exhausting the pod's PID limit. (PID 1 also has special signal semantics — the kernel applies no default signal actions to it, so an unhandled SIGTERM is silently ignored.) The two components Kubernetes/the runtime use to prevent this are: **`tini`** (or the runtime's built-in init, e.g. Docker's `--init`), a tiny init that runs as PID 1, forwards signals, and reaps zombies; and the **`pause` container**, the pod sandbox process that holds shared namespaces open and acts as the reaping PID 1 when you enable `shareProcessNamespace: true`.

### Before Rung 5
**Q:** `Ctrl-Z` then `bg` then `disown` — for each step, name the signal or table operation happening underneath.

**A:** `Ctrl-Z` makes the terminal deliver **`SIGTSTP` (20)** to the foreground job, putting it in state `T` (stopped) — it's the catchable cousin of SIGSTOP. `bg` sends the stopped job **`SIGCONT` (18)**, resuming it, but as a *background* job that no longer owns the terminal. `disown` sends **no signal at all** — it is a shell builtin that performs a table operation: it removes the job from the shell's job table, so the shell won't SIGHUP it when the terminal closes. So only `Ctrl-Z` and `bg` involve signals (SIGTSTP and SIGCONT respectively); `disown` is pure bookkeeping.

### Before Rung 6
**Q:** In step [6b] the app ignores SIGTERM. If that app is running as **PID 1** inside the container (no tini), would `kill -15` from step [5] behave *differently* than if it were PID 37? Explain using the special PID-1 signal rule from 3.5.

**A:** Yes. If the app were PID 37 with no SIGTERM handler, the kernel would apply the *default action* for SIGTERM — terminate — so the container would die at second 0 even without any handler code. But the kernel does **not apply default signal actions to PID 1**: for PID 1, a signal only has effect if the process has explicitly registered a handler for it. So an app-as-PID-1 with no SIGTERM handler has the signal *silently ignored* — it keeps running as if nothing happened, and the pod always burns the full 30-second grace period before dying to SIGKILL. That's exactly why you wrap such apps in `tini`, which handles and forwards signals properly.

### Before Rung 7
**Q:** `kubectl delete pod x --grace-period=0 --force` — translate that flag into the exact sequence of signals (or absence of one) the node performs, versus a normal delete.

**A:** A normal delete performs: `kill(PID, SIGTERM)` at second 0 (after any preStop hook), a wait of up to `terminationGracePeriodSeconds` (default 30) for the app to clean up and exit, then `kill(PID, SIGKILL)` at the deadline if it's still alive. With `--grace-period=0 --force` the grace window is collapsed to zero: the node skips the meaningful SIGTERM-and-wait phase and goes effectively straight to **SIGKILL** — no cleanup opportunity, no draining, and the pod object is removed from the API immediately without waiting for confirmation the process is gone. It's the "skip the 30s, go straight to the uncatchable hammer" escape hatch — and note that even SIGKILL cannot free a process wedged in `D` (uninterruptible I/O) state.
