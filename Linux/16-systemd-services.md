# systemd, Services & journald
> PID 1 is not just "the first process" — it is a full service manager that starts, supervises, restarts, and logs everything on your node. Your kubelet is one of its children. Learn to read it, override it, and follow its logs.

---

## Rung 0 — 🛠 The Setup

**What am I learning?** How a modern Linux box goes from "kernel finished booting" to "a running, self-healing set of services" — and how *you* interrogate, configure, and repair those services. That machine is **systemd**: it is PID 1, the init system, the service supervisor, and (through **journald**) the log collector. You will learn units, `systemctl`, the *right* way to override a service, and how to read logs with `journalctl`.

**Why did it land on my desk?** A node just went `NotReady`. `kubectl describe node` says `Kubelet stopped posting node status`. The pods on it are draining. You SSH in, and now every button you press is a systemd button: *Is kubelet even running? Did it crash-loop? What did it log right before it died? Someone added `--max-pods` last week — where did that setting go and did it survive a reboot?* None of these are `kubectl` questions. They are all `systemctl` and `journalctl` questions.

**What do I already know?** You know `kubectl get pods` cold. You know kubelet is "the agent on every node" and containerd is "the thing that runs containers." What you may not yet have is the mechanical picture: that **kubelet and containerd are ordinary systemd services** defined by unit files on disk, that "enable" and "start" are two *different* things, that editing the shipped unit file by hand is a trap that a package upgrade will silently undo, and that every line kubelet writes to stderr is sitting in the journal indexed by unit name, ready for `journalctl -u kubelet`.

By the end you will read a `.service` file like a sentence, add `--max-pods=200` to kubelet the way that survives upgrades *and* reboots, and pull the exact 100 log lines around a crash without grepping through a pile of files.

---

## Rung 1 — 🔥 The Pain

**The problem that forced systemd to exist.** A booted kernel is almost useless. It needs userspace: a network stack configured, filesystems mounted, a logging daemon, an SSH server, a container runtime, a kubelet. Something has to **start all of that in the right order, supervise it, restart it when it dies, and shut it down cleanly.** That "something" is the **init system** — PID 1.

**What people did before, and why it hurt.** The old answer was **SysV init**: a pile of shell scripts in `/etc/init.d/`, run in an order fixed by two-digit number prefixes (`S20network`, `S80kubelet`). It hurt in specific, repeated ways:

- **Ordering was a guess.** You encoded dependencies by *renaming files with numbers*. "Start kubelet after containerd" meant "give kubelet a bigger number and hope."
- **No supervision.** A start script ran, forked a daemon, and exited. If the daemon crashed at 3 a.m., **nothing** restarted it. You wrote your own `while true` wrappers, or bolted on `monit`/`supervisord`/`upstart` — three more tools.
- **No idea if it worked.** "Is it running?" meant `ps aux | grep`, or trusting a stale PID file that lied after a crash.
- **Logs scattered everywhere.** Each daemon wrote to its own file in `/var/log/`, with its own format and its own rotation config. Correlating "what did the network do the instant kubelet died?" meant `tail -f` across five files and eyeballing timestamps.
- **Parallelism was hard.** Scripts ran one at a time, so boots were slow.

**What breaks for you specifically without this knowledge.**
- A node reboots after maintenance and kubelet **doesn't come back** — because it was `start`ed but never `enable`d, and you don't know those are different.
- Someone "fixed" kubelet's `--max-pods` by editing `/lib/systemd/system/kubelet.service` directly; an `apt upgrade` overwrote the file and the setting vanished — a silent config regression you can't explain.
- kubelet is crash-looping and you're SSH-ing around `/var/log/` looking for a file that doesn't exist, because its output went to the **journal**, not a file.
- The node OOM-killed something and you can't find the evidence, because kernel messages live in a place you didn't think to look (`journalctl -k`).

**Who feels the pain most?** The on-call platform engineer, because "Node NotReady" is nearly always "a systemd-managed service on that node is unhappy," and the entire diagnosis happens in `systemctl` and `journalctl`.

> Check yourself before Rung 2: From the pain above, *derive* why an init system needs two separate concepts — "is this service running **right now**" versus "should this service come up **on the next boot**." Why can't one flag cover both?

---

## Rung 2 — 💡 The One Idea

Here is the sentence. Memorize it:

> **systemd is PID 1 running a state machine: it reads declarative *unit* files that describe desired state and dependencies, drives the system toward that state, supervises the results, and journals everything they emit.**

Everything in this document derives from that sentence:

- **"reads declarative *unit* files"** → therefore configuration is *files with a defined schema* (`[Unit]`, `[Service]`, `[Install]`), not imperative scripts. You **read** them (`systemctl cat`) and **override** them (`systemctl edit`). All the unit *types* (`.service`, `.target`, `.timer`, `.socket`, `.mount`) fall out — they're just different shapes of "a thing systemd manages."
- **"desired state and dependencies"** → therefore there is an ordering/wants graph (`After=`, `Wants=`, `WantedBy=`) and grouping milestones called **targets** (`multi-user.target`). "Start kubelet after containerd" becomes a *declaration*, not a filename number.
- **"drives the system toward that state"** → therefore `enable` (wire into the boot graph) and `start` (make it true *now*) are **genuinely different verbs**. `enable --now` does both because they're two operations, not one.
- **"supervises the results"** → therefore `Restart=always`, `status`, and auto-restart fall out. systemd *watches* the main process and acts on its exit.
- **"journals everything they emit"** → therefore every unit's stdout/stderr is captured, tagged with the unit name, timestamped, and queryable: `journalctl -u kubelet`. Logging isn't bolted on; it's part of PID 1.

If you remember only one thing: **a service is a declared desired-state document, and systemd's whole job is to make reality match it and tell you when it can't.**

> Check yourself before Rung 3: Using only the One Idea, explain why editing `/lib/systemd/system/kubelet.service` by hand is *architecturally* wrong — which word in the sentence tells you where your changes actually belong?

---

## Rung 3 — ⚙️ The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> Imagine a big apartment building. When the power comes on in the morning, one person — the **building manager** — unlocks the doors, turns on the elevators, and wakes up all the staff. On a Linux computer, that manager is a program called **systemd**. It is literally the first worker the computer hires (its employee badge is number 1), and every other program on the machine works under it.
>
> - **The manager's binder (3.1).** The manager doesn't memorize anything — every staff member (each background program, called a "service") has a one-page job sheet in a binder. There are different kinds of pages: some describe a worker, some describe a schedule ("do this every night"), some describe a milestone ("building fully open"). Crucially, there are **two binders**: the one the builders shipped with the building, and the manager's own binder. If both have a page for the same job, **the manager's own binder always wins**. So you never scribble on the builders' pages (a renovation would replace them and erase your notes) — you put your changes in the manager's binder.
> - **What's on a job sheet (3.2).** Each sheet has three parts: who this worker is and who must clock in before them ("don't start the cook until the kitchen lights are on"), exactly how to start their work, and what to do if they collapse — such as "always send them back to work after 10 seconds."
> - **Two different requests (3.3).** Telling the manager "put this person to work *right now*" and "add this person to *every future* morning routine" are two separate requests. The first changes today only; the second just pins a note into tomorrow's checklist without touching today. You can ask for both at once.
> - **Milestones (3.4).** The morning routine drives toward named milestones like "building open for residents." Workers' sheets say which milestone they belong to.
> - **Constant supervision (3.5).** The manager puts each worker's whole team in its own labeled room (so no helper can wander off untracked), watches them, and restarts anyone who collapses.
> - **One shared diary (3.6).** Everything every worker says is written into one big indexed diary by a dedicated note-taker, stamped with who said it and when — so later you can ask "show me only what the doorman said in the last hour." One catch: unless a permanent diary shelf exists, the diary is kept on a whiteboard that gets wiped when the building loses power.
> - **The wall chart (3.7)** simply draws all of this as one picture: manager reads binders, wakes workers in order, tracks their rooms, and the note-taker records everything.

*Now the original technical deep-dive — the same ideas, in precise form:*

### 3.1 The big picture: PID 1 and the unit database

At boot, the kernel mounts the root filesystem and executes one program as **PID 1**: `/sbin/init`, which on Ubuntu/RHEL/most modern distros is a symlink to `/lib/systemd/systemd`. From that instant, systemd owns userspace.

systemd's model of the world is a **set of units**. A **unit** is any resource systemd knows how to manage, described by a text file. The file's *suffix* declares its type:

| Suffix | Unit type | Manages… |
|---|---|---|
| `.service` | Service | A daemon/process (kubelet, containerd, sshd, nginx) |
| `.target` | Target | A named *group* / sync point (like SysV runlevels) |
| `.timer` | Timer | A schedule that activates another unit (cron replacement) |
| `.socket` | Socket | A listening socket; activates a service on first connection |
| `.mount` | Mount | A filesystem mount point (auto-generated from `/etc/fstab`) |
| `.device`, `.swap`, `.slice`, `.scope` | others | Devices, swap, cgroup slices, externally-created process groups |

systemd loads these units from a **search path with strict precedence** (highest wins):

```
/etc/systemd/system/     ← YOU put admin overrides here.        HIGHEST priority
/run/systemd/system/     ← runtime, volatile (gone on reboot)
/lib/systemd/system/     ← the DISTRO/package ships units here.  LOWEST priority
   (also /usr/lib/systemd/system on some distros — same role)
```

This ordering is the single most important operational fact in this whole document. Packages drop their canonical unit in `/lib` (or `/usr/lib`). You never edit that. Your changes go in `/etc/systemd/system/`, where they *win* over the shipped file — so a package upgrade rewriting `/lib` cannot clobber you.

### 3.2 Anatomy of a `.service` unit

A service file has three sections. Here is a realistic (lightly trimmed) kubelet unit, the kind you'd see from `cat /lib/systemd/system/kubelet.service`:

```ini
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
```

- **`[Unit]`** — identity and *ordering/dependencies*. `Description=` names it in `status`/journal. `After=network-online.target` means "don't start me until the network is up" (ordering only). `Wants=` is a *soft* dependency: pull that unit in, but don't fail if it fails. (`Requires=` is the *hard* version — if it fails, we fail.)
- **`[Service]`** — *how to run the process*. `ExecStart=` is the exact command PID 1 forks+execs. `Restart=always` tells systemd's supervisor: whenever the main process exits (any reason), restart it. `RestartSec=10` waits 10s between tries. This is the supervision the old SysV world lacked entirely.
- **`[Install]`** — *what happens at `enable` time*. `WantedBy=multi-user.target` means: "when someone `enable`s me, create a symlink so that reaching `multi-user.target` at boot pulls me in." **`[Install]` is only consulted by `enable`/`disable` — it does nothing at `start` time.** This is the mechanical root of "start ≠ enable."

### 3.3 enable vs start — two verbs, two mechanisms

This trips up everyone, so slow down. They touch different machinery:

- **`systemctl start kubelet`** — imperative, *right now*. systemd forks+execs `ExecStart` and begins supervising. **Nothing is written to disk.** Reboot and it's gone unless something else pulls it in.
- **`systemctl enable kubelet`** — declarative, *for future boots*. systemd reads the unit's `[Install]` section and creates a **symlink**:

  ```
  /etc/systemd/system/multi-user.target.wants/kubelet.service
        → /lib/systemd/system/kubelet.service
  ```

  Now when boot reaches `multi-user.target`, that `.wants/` directory is scanned and kubelet is pulled in. **`enable` changes nothing about the currently-running system.**
- **`systemctl enable --now kubelet`** — does both: create the boot symlink *and* start it now. This is what you almost always want for kubelet.

```
   start  ─────────────► affects the LIVE system (fork+exec now)
   enable ─────────────► affects FUTURE boots (writes a .wants/ symlink)
   enable --now ───────► both
```

### 3.4 Targets: the runlevel replacement

A **target** is a unit with no process — it's a *named sync point* used to group other units. Booting is "reach a target." The common ones:

| Target | Meaning |
|---|---|
| `multi-user.target` | Normal multi-user, networked, no GUI. **This is what a server boots to.** kubelet's `WantedBy` points here. |
| `graphical.target` | multi-user + a display manager (desktop). Pulls in `multi-user.target`. |
| `network-online.target` | Sync point meaning "network is configured." kubelet's `After=`/`Wants=` reference it. |
| `default.target` | Symlink to whatever the box boots to (usually `multi-user.target` on servers). |

`systemctl get-default` shows it; `systemctl set-default multi-user.target` changes it. Think of targets as SysV runlevels reborn as dependency-graph nodes.

### 3.5 The supervisor loop and cgroups

When systemd starts a service it doesn't just fork+exec and forget. It:

1. Places the service in its **own cgroup** (e.g. `system.slice/kubelet.service`) so *every* child process is tracked — no more "the daemon double-forked and I lost the PID."
2. Watches the main process. On exit, it consults `Restart=` and acts (`always`, `on-failure`, `no`, …).
3. Captures the process's **stdout and stderr** and pipes them to **journald**, tagged with the unit name and metadata.

That cgroup detail is a direct bridge to Kubernetes: kubelet then creates its *own* cgroup hierarchy for pods (`kubepods.slice`) *inside* the tree systemd set up. systemd manages kubelet; kubelet manages pods; both use the same cgroup primitive.

### 3.6 journald: logging as part of PID 1

**journald** (`systemd-journald`, itself a service) receives:
- stdout/stderr of every systemd-managed service,
- messages sent to the classic syslog socket,
- **kernel ring-buffer messages** (the same stuff `dmesg` shows),
and stores them in a **binary, indexed** journal (under `/run/log/journal` if volatile, or `/var/log/journal/` if persistent). Because it's indexed by fields — `_SYSTEMD_UNIT`, `PRIORITY`, `_TRANSPORT` — you can slice it instantly: "only kubelet, only errors, only since an hour ago" without grepping text files.

Persistence note: if `/var/log/journal/` exists, the journal survives reboots (`Storage=persistent` or `auto` in `/etc/systemd/journald.conf`). If it doesn't, logs are RAM-only and vanish on reboot — a real gotcha when investigating a crash *after* a node reboot. `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald` makes it persistent.

### 3.7 Whiteboard: the whole machine

```
   kernel boots ──► execs PID 1 = /lib/systemd/systemd
                                   │
                                   │ reads units (precedence: /etc > /run > /lib)
                                   ▼
                      ┌────────────────────────────────┐
                      │        systemd (PID 1)          │
                      │  desired state = default.target │
                      └───────────────┬────────────────┘
                                      │ pull in .wants/
                    ┌─────────────────┼──────────────────┐
                    ▼                 ▼                   ▼
            network-online     containerd.service     kubelet.service
              .target                │  (After=network-online)
                                     │  ExecStart=/usr/bin/containerd
                                     │  Restart=always
                                     ▼
                      ┌──────────────────────────────┐
                      │ cgroup: system.slice/         │  ← systemd tracks
                      │   kubelet.service             │     every child
                      └──────────────┬───────────────┘
                       stdout/stderr │
                                     ▼
                          systemd-journald  ──►  journalctl -u kubelet
                             ▲
                             │ also ingests kernel ring buffer
                          [ kernel: OOM killer, etc. ]  ──► journalctl -k
```

The kubelet process, once alive, connects to the API server and starts *its* own supervision of pods — but that's a layer above. As far as the node is concerned, **kubelet is just another `.service` in `system.slice`.**

> Check yourself before Rung 4: Without looking, name the three unit-file search directories in precedence order and say which one *you* write to and why. Then explain what physically happens on disk when you run `systemctl enable kubelet` — what object gets created, in which directory, pointing where?

---

## Rung 4 — 🏷️ The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|---|---|---|
| **systemd** | The init system + service manager running as PID 1 | Everything; the state machine in 3.1 |
| **PID 1 / init** | The first userspace process; ancestor of all others | 3.1 — the process systemd *is* |
| **Unit** | A managed resource described by a text file | 3.1 — the atom of systemd's model |
| **`.service`** | A unit that runs/supervises a process | 3.2 — kubelet, containerd, sshd |
| **`.target`** | A unit with no process; a named group / sync point | 3.4 — `multi-user.target` |
| **`.timer`** | A unit that activates another on a schedule | 3.1 — cron replacement (see 25-scheduled-tasks) |
| **`.socket`** | A unit holding a listening socket; lazy-starts a service | 3.1 — socket activation |
| **`.mount`** | A unit representing a mount point | 3.1 — generated from `/etc/fstab` |
| **`[Unit]`** | Section for identity, ordering, dependencies | 3.2 — `After=`, `Wants=`, `Requires=` |
| **`[Service]`** | Section for how to run the process | 3.2 — `ExecStart=`, `Restart=` |
| **`[Install]`** | Section consulted only by `enable`/`disable` | 3.2/3.3 — `WantedBy=` |
| **`ExecStart=`** | The exact command systemd forks+execs | 3.2 — the daemon binary + args |
| **`Restart=always`** | Supervision policy: relaunch on any exit | 3.5 — the supervisor loop |
| **`After=` / `Before=`** | *Ordering* only (not a dependency) | 3.2 — boot sequencing |
| **`Wants=` / `Requires=`** | Soft / hard *dependency* (pulls unit in) | 3.2 — the dependency graph |
| **`WantedBy=`** | "When enabled, wire me into this target" | 3.3 — the `.wants/` symlink |
| **enable** | Write the boot-time symlink (future boots) | 3.3 — declarative |
| **start** | Fork+exec the process now (live system) | 3.3 — imperative |
| **daemon-reload** | Re-read unit files from disk into memory | 3.8 (below) |
| **Drop-in / override** | A partial unit in `<unit>.d/override.conf` that *adds to* the shipped unit | 3.1 precedence, 3.9 (below) |
| **journald** | The service that collects & indexes all logs | 3.6 |
| **journalctl** | The client that queries the journal | 3.6 |
| **cgroup / slice** | Kernel process-grouping systemd puts each service in | 3.5 (see 14-cgroups) |

**Terms that are the same kind of thing wearing different names:**
- **Unit file, `.service`/`.target`/`.timer`/`.socket`/`.mount`** — all *units*; the suffix is just the shape.
- **`enable`, `WantedBy=`, the `.wants/` symlink** — three views of *one* mechanism: wiring a unit into the boot graph.
- **`Wants=`, `Requires=`, `After=`, `Before=`** — all edges in the dependency/ordering graph; `Wants`/`Requires` say *what*, `After`/`Before` say *when*.
- **journald, journalctl, "the journal," `-u`, `PRIORITY`** — all facets of the single indexed log store.
- **target, runlevel, sync point** — the same idea; "runlevel" is the SysV word.

> Check yourself before Rung 5: Pick three terms from the map — `WantedBy=`, `enable`, and the `.wants/` symlink — and describe the *single* mechanism that ties all three together. If you can't say it in one sentence, re-read 3.3.

---

## Rung 5 — 🔬 The Trace: `systemctl restart kubelet`, end to end

You run one command. Here is every hop.

1. **You type** `sudo systemctl restart kubelet`. `systemctl` is just a *client*; it doesn't do the work. It packages your request as a method call.
2. **The request travels over D-Bus** to PID 1 (systemd). D-Bus is the local IPC bus; `systemctl` calls `RestartUnit("kubelet.service", ...)` on the systemd manager object.
3. **systemd resolves the unit** `kubelet.service` from its in-memory database (loaded from `/lib` + any `/etc` overrides at the last `daemon-reload`).
4. **Stop phase.** systemd sends `SIGTERM` to kubelet's main process, waits up to `TimeoutStopSec` (default 90s), then `SIGKILL` if it's stubborn. It tears down the service's cgroup children too.
5. **Dependency check.** Ordering (`After=network-online.target`) is honored; those are already up, so no wait.
6. **Start phase.** systemd creates a fresh cgroup `system.slice/kubelet.service`, then **fork+execs** `ExecStart=/usr/bin/kubelet <args>` (args coming from the shipped unit *plus* any `KUBELET_EXTRA_ARGS` from a drop-in).
7. **Wiring stdout/stderr.** Before exec, systemd connects the child's fd 1 and fd 2 to a journald socket. From now on, everything kubelet prints is a journal entry tagged `_SYSTEMD_UNIT=kubelet.service`.
8. **Supervision begins.** systemd records the new main PID and watches it. `Restart=always` is now armed.
9. **kubelet itself wakes up:** reads `/var/lib/kubelet/config.yaml` + `/etc/kubernetes/kubelet.conf`, dials the API server, and re-registers the node. Within seconds the node flips `NotReady → Ready`.
10. **`systemctl` returns.** It was blocked waiting for the D-Bus reply that the job finished; you get your prompt back.

```
 you        systemctl        (D-Bus)        systemd/PID1          kubelet          journald        API server
  │  restart    │                              │                    │                 │                │
  ├────────────►│  RestartUnit ───────────────►│                    │                 │                │
  │             │                              │ SIGTERM ──────────►│ (graceful stop) │                │
  │             │                              │ (kill cgroup)      X                 │                │
  │             │                              │ new cgroup + fork+exec ─────────────►│ (new PID)      │
  │             │                              │ wire fd1/fd2 ──────────────────────────────►│         │
  │             │                              │ arm Restart=always │  logs stream ──►│                │
  │             │                              │                    │ register node ─────────────────►│
  │◄────────────┤◄─── job done (D-Bus reply) ──┤                    │                 │  Node=Ready    │
```

Notice: **you** never touched kubelet. You asked PID 1, and PID 1 did the fork+exec+supervise+log — exactly the One Idea in motion.

> Check yourself before Rung 6: Every action in the trace went *through* PID 1 — you never spawned kubelet yourself. Explain why that indirection is the whole point, and specifically what you'd lose in *supervision* and *logging* if you instead ran `/usr/bin/kubelet &` in a shell.

---

## Rung 6 — ⚖️ The Contrast: systemd vs SysV init (and vs "just run it")

The alternative worlds are **SysV init** (shell scripts in `/etc/init.d/`) and its add-ons (`monit`, `supervisord`), or the naive "start the binary in a terminal / `nohup` it."

| Capability | systemd | SysV init (+ add-ons) | Bare `nohup ./kubelet &` |
|---|---|---|---|
| Dependency ordering | Declarative (`After=`, `Wants=`) | Filename number prefixes (`S80…`) | None |
| Auto-restart on crash | Built in (`Restart=`) | Needs `monit`/`supervisord` bolt-on | None |
| "Is it running?" truth | `systemctl status` (from cgroup, can't lie) | PID file (lies after a crash) | `ps | grep` |
| Start now vs on-boot | Separate verbs (`start`/`enable`) | Symlink farms (`update-rc.d`) | Manual, nothing persists |
| Log capture | Automatic, indexed (journald) | Each daemon rolls its own file | Wherever you redirected |
| Config override safety | Drop-ins win over shipped units | Edit the script, upgrade clobbers it | N/A |
| Boot parallelism | Yes (dependency graph) | Serial | N/A |
| Resource limits | Native (`MemoryMax=`, cgroups) | Manual `ulimit` in the script | Manual |

**What systemd can do that the alternatives can't:** track *all* child processes via cgroups (a double-forking daemon can't escape), restart with backoff, socket/timer activation, and give you one indexed log store across every service. **What the alternatives arguably did better:** the shell scripts were *transparent* — you could read exactly what ran. systemd trades that for a schema you have to learn (which is what this document is for).

**When would I NOT reach for systemd?** Inside a **container**. A container should run *one* process as PID 1 (your app or a tiny init like `tini`), not a whole systemd. That's why static pods and Kubernetes-managed containers are **not** systemd services — Kubernetes *is* their supervisor. On the **node**, though, kubelet and containerd absolutely are systemd services, because someone has to supervise the supervisor.

**Why this over that, in one sentence:** systemd replaces a pile of shell scripts, a separate restarter, a separate log daemon, and a separate dependency-ordering hack with one declarative, cgroup-backed, log-integrated PID 1 — which is exactly why every Kubernetes node uses it to run kubelet.

> Check yourself before Rung 7: A static pod (manifest in `/etc/kubernetes/manifests/`) and a systemd service both "run a process and restart it if it dies." *Derive* who the supervisor is in each case, and why you'd never wrap a static pod's container in its own systemd unit.

---

## Rung 7 — 🧪 The Prediction Test

Commit to the prediction *out loud* before you run each block. The learning is in the gap between what you predicted and what happened.

Assume Ubuntu 22.04 (systemd, cgroup v2). Where RHEL/older differs, it's noted. `sudo` is implied for state-changing commands.

### Example 1 — Normal case: read the shipped unit, then check live status

**Prediction:** `cat /lib/systemd/system/kubelet.service` shows the *shipped* file with `ExecStart` and `Restart=always`. `systemctl cat kubelet` shows the shipped file **plus** any drop-ins merged. `systemctl status kubelet` shows `active (running)`, the main PID, its cgroup, and the last few log lines — BECAUSE systemd tracks the service in a cgroup and tees its output to journald.

```bash
cat /lib/systemd/system/kubelet.service     # the package's canonical unit (RHEL: same path)
# [Service]
#   ExecStart=/usr/bin/kubelet
#   Restart=always

systemctl cat kubelet                        # shipped unit + every drop-in, in precedence order
# # /lib/systemd/system/kubelet.service
# ...
# # /etc/systemd/system/kubelet.service.d/10-kubeadm.conf   <-- kubeadm's own drop-in
# [Service]
#   Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=..."
#   ExecStart=
#   ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS

systemctl status kubelet
#  kubelet.service - kubelet: The Kubernetes Node Agent
#      Loaded: loaded (/lib/systemd/system/kubelet.service; enabled; ...)   <-- note: enabled
#     Drop-In: /etc/systemd/system/kubelet.service.d
#              └─10-kubeadm.conf
#      Active: active (running) since ...; 3 days ago
#    Main PID: 1234 (kubelet)
#       CGroup: /system.slice/kubelet.service
#               └─1234 /usr/bin/kubelet --bootstrap-kubeconfig=... --max-pods=110
```

**Verify:** In `status`, confirm `Active: active (running)` and that `Loaded:` says **`enabled`** (survives reboot). See how a kubeadm cluster's real `ExecStart` is a *chain of `$VARS`* — note the empty `ExecStart=` line that **resets** the shipped value before redefining it. If `status` said `inactive (dead)` or `activating (auto-restart)`, you'd have found your `NotReady` cause. If `cat` and `systemctl cat` looked identical, this node has no drop-ins.

### Example 2 — Kubernetes case: add `--max-pods=200` the RIGHT way (drop-in override)

**Prediction:** `systemctl edit kubelet` opens an empty override editor, drops my file at `/etc/systemd/system/kubelet.service.d/override.conf`, and because `/etc` beats `/lib`, my `KUBELET_EXTRA_ARGS` merges into the unit **without touching the shipped file** — so a package upgrade can't erase it and a reboot will keep it. It won't take effect until `daemon-reload` (re-read files) + `restart` (relaunch the process) — BECAUSE systemd runs from an *in-memory* copy of units, and the running kubelet already exec'd with the old args.

```bash
sudo systemctl edit kubelet
# Editor opens on: /etc/systemd/system/kubelet.service.d/override.conf
# Type ONLY the sections you want to add:
```
```ini
[Service]
Environment="KUBELET_EXTRA_ARGS=--max-pods=200 --node-labels=disktype=ssd"
```
```bash
# Save & quit. Then make systemd notice, and relaunch kubelet with new args:
sudo systemctl daemon-reload           # re-read unit files from disk into memory
sudo systemctl restart kubelet         # fork+exec kubelet again, now with --max-pods=200

systemctl cat kubelet                  # confirm the override is merged, LAST (highest precedence)
# # /etc/systemd/system/kubelet.service.d/override.conf
# [Service]
# Environment="KUBELET_EXTRA_ARGS=--max-pods=200 --node-labels=disktype=ssd"

# Prove kubelet actually got the arg:
systemctl show kubelet -p ExecStart | tr ' ' '\n' | grep -i extra   # var is referenced
journalctl -u kubelet -n 5 --no-pager                               # started cleanly?
kubectl get node "$(hostname)" -o jsonpath='{.status.capacity.pods}{"\n"}'  # -> 200
```

**Verify:** `systemctl cat` must show your `override.conf` listed *after* the shipped unit — that's precedence proving `/etc` wins. `kubectl get node ... capacity.pods` should now read `200`, and the node should carry the `disktype=ssd` label (`kubectl get node --show-labels`). Common wrong result: you *edited `/lib/.../kubelet.service` directly* instead — it works until the next `apt upgrade` silently reverts it. Another classic: you forgot `daemon-reload`, so `systemctl` warns *"Warning: The unit file ... changed on disk. Run 'systemctl daemon-reload'"* and your `restart` used the stale in-memory unit. (To undo the whole override: `sudo systemctl revert kubelet && sudo systemctl daemon-reload && sudo systemctl restart kubelet`.)

### Example 3 — Failure/triage case: node went NotReady — read the logs

**Prediction:** When a node is `NotReady`, `systemctl status kubelet` will show `failed` or `activating (auto-restart)` and `journalctl -u kubelet` will hold the crash reason. Following it live with `-f` shows new lines as kubelet writes them; `-p err` filters to errors only; correlating kubelet **and** containerd in one stream (`-u kubelet -u containerd`) shows if the runtime died first — BECAUSE journald tags every line by unit, so it can interleave two units in true time order. Kernel OOM kills won't appear under `-u kubelet` at all; they're kernel messages, reachable only via `-k`.

```bash
# 1. Is kubelet even up, and why not?
systemctl status kubelet
#   Active: activating (auto-restart) (Result: exit-code) ...   <-- crash-looping

# 2. The last 100 lines, then follow live (Ctrl-C to stop):
journalctl -u kubelet -f -n 100

# 3. Just the errors from the last hour (great for a post-incident scan):
journalctl -u kubelet --since "1 hour ago" -p err
#   ... "failed to run Kubelet: misconfiguration: kubelet cgroup driver: \"cgroupfs\"
#        is different from docker cgroup driver: \"systemd\""   <-- a real, classic cause

# 4. Did the container runtime die FIRST? Interleave both units in time order:
journalctl -u kubelet -u containerd -f

# 5. Was something OOM-killed by the KERNEL? Not in the unit log — use -k:
journalctl -k | grep -i oom
#   kernel: Out of memory: Killed process 4242 (kubelet) total-vm:...   <-- node ran out of RAM
# (equivalently: journalctl --dmesg -p warning ; or the classic  dmesg -T | grep -i oom)
```

**Verify:** `-p err` should collapse a noisy log down to the one or two lines that actually explain the failure (`err` = priority 3; the scale is `emerg 0 … err 3 … info 6 … debug 7`). If `journalctl -u kubelet` prints **nothing** on a fresh-crashed node, suspect a **non-persistent journal** — check `ls /var/log/journal` (empty ⇒ logs were RAM-only and gone after the reboot). If the OOM line names `kubelet` (or `containerd`) as the killed process, your problem is *node memory pressure*, not a kubelet bug — a fix in `--kube-reserved`/`--system-reserved` (via the same drop-in from Example 2), not in the unit's restart policy. If `-u kubelet -u containerd` shows containerd erroring *seconds before* every kubelet error, fix containerd first — kubelet is just the loud downstream victim.

---

## Rung 🏔 Capstone — Compress It

**One sentence (no notes):** systemd is PID 1 as a declarative service manager — it reads unit files describing desired state and dependencies, makes reality match, supervises and restarts the results, and journals everything they emit.

**Three-sentence beginner explanation:** On a Linux node, systemd is the first program the kernel starts, and it's in charge of running every background service — including kubelet and containerd, which are just service files on disk. You control those services with `systemctl` (start/stop/status now, enable for future boots) and you *never* edit the shipped file — you add a drop-in with `systemctl edit`, then `daemon-reload` and `restart`. When a node goes `NotReady`, you check `systemctl status kubelet` and read the crash reason with `journalctl -u kubelet`.

**Sub-capabilities mapped to the one idea ("declared desired state that PID 1 makes true, supervises, and logs"):**
- Unit types (`.service/.target/.timer/.socket/.mount`) → *different shapes of "a declared thing systemd manages."*
- `start` vs `enable` → *make it true now* vs *declare it for future boots.*
- `[Unit]/[Service]/[Install]`, `After=`, `Restart=always` → *the declaration's fields: what depends on what, how to run it, how to supervise it.*
- Drop-in + `daemon-reload` + `systemctl cat` → *amend the declaration safely (via `/etc` precedence) and re-read it.*
- Targets / `multi-user.target` → *named desired-state milestones the boot drives toward.*
- journald / `journalctl -u/-f/-p/-k` → *"logs everything they emit," indexed and queryable.*

**Which rung to revisit hands-on:** **Rung 7, Example 2** (the drop-in override). Almost everyone *understands* `/etc` beats `/lib` yet still edits the shipped file under pressure. Do the `systemctl edit` → `daemon-reload` → `restart` → `systemctl cat` loop on a throwaway service (`sudo systemctl edit cron`) until the muscle memory is real. Then revisit **Rung 5**'s trace once more — being able to narrate D-Bus → SIGTERM → new cgroup → fork+exec → journald wiring is what separates "I run commands" from "I know what PID 1 did."

---

## Related concepts

- [Processes & Job Control](07-processes-job-control.md) — what systemd supervises: PIDs, signals (`SIGTERM`/`SIGKILL`), PID 1, reaping.
- [cgroups](14-cgroups.md) — how systemd tracks every service's children, and where `kubepods.slice` lives.
- [Storage & Mounts](15-storage-mounts.md) — `.mount` units, `/etc/fstab`, and how systemd auto-generates mount units.
- [Scheduled Tasks](25-scheduled-tasks.md) — `.timer` units as the systemd-native replacement for cron.
- [Performance Monitoring](21-performance-monitoring.md) — `journalctl -k`, `dmesg`, PSI, and reading the kernel ring buffer during incidents.
- [Linux ↔ Kubernetes Map](27-linux-kubernetes-map.md) — full node-triage reference tying kubelet/containerd systemd units to `NotReady` diagnosis.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** From the pain, derive why an init system needs two separate concepts — "running right now" versus "comes up on the next boot." Why can't one flag cover both?

**A:** Because the two states live in different places and change at different times: "running right now" is a property of the live system (a process that exists in memory), while "comes up at boot" is a property of persistent configuration on disk that the next boot will read. The SysV pain shows both failure modes: a node reboots after maintenance and kubelet doesn't come back because it was only started, never wired into the boot sequence; conversely, you often need to stop a service for maintenance *without* removing it from future boots. One flag can't cover both because you routinely want every combination — running-but-not-enabled (a one-off test), enabled-but-stopped (maintenance), both, or neither. That's why systemd gives you two verbs, `start` (live, imperative) and `enable` (boot-time, declarative), and `enable --now` when you want both.

### Before Rung 3
**Q:** Using only the One Idea, explain why editing `/lib/systemd/system/kubelet.service` by hand is architecturally wrong — which word in the sentence tells you where your changes belong?

**A:** The key word is **"declarative"** (systemd "reads declarative *unit* files that describe desired state"). In a declarative system, configuration is data with a defined schema and a defined precedence, not something you patch in place: the file in `/lib/systemd/system/` is the *package's* declaration, owned by the distro, and any upgrade will rewrite it and silently erase your edit. Your declarations belong in the admin layer, `/etc/systemd/system/` (a drop-in via `systemctl edit`), which sits higher in the search-path precedence (`/etc` > `/run` > `/lib`) and therefore wins over — and survives — whatever the package ships.

### Before Rung 4
**Q:** Name the three unit-file search directories in precedence order, say which one you write to and why, and explain what physically happens on disk when you run `systemctl enable kubelet`.

**A:** Precedence, highest to lowest: `/etc/systemd/system/` (admin overrides — where **you** write), then `/run/systemd/system/` (runtime, volatile, gone on reboot), then `/lib/systemd/system/` (the distro/package's canonical units — never edit these; also `/usr/lib/systemd/system` on some distros). You write to `/etc` because it wins over `/lib`, so package upgrades that rewrite the shipped unit cannot clobber your changes. On `systemctl enable kubelet`, systemd reads the unit's `[Install]` section (`WantedBy=multi-user.target`) and creates a **symlink** on disk: `/etc/systemd/system/multi-user.target.wants/kubelet.service → /lib/systemd/system/kubelet.service`. At the next boot, when the system drives toward `multi-user.target`, that `.wants/` directory is scanned and kubelet is pulled in; nothing about the currently running system changes.

### Before Rung 5
**Q:** Describe the single mechanism that ties together `WantedBy=`, `enable`, and the `.wants/` symlink.

**A:** They are three views of one mechanism: wiring a unit into the boot dependency graph. `WantedBy=multi-user.target` is the *declaration* in the unit's `[Install]` section saying which target should pull it in; `systemctl enable` is the *verb* that reads that declaration; and the symlink in `/etc/systemd/system/multi-user.target.wants/` is the *on-disk artifact* the verb creates, which the target scans at boot to pull the service in. One sentence: `enable` reads `WantedBy=` and materializes it as a `.wants/` symlink so the named target pulls the unit in at boot.

### Before Rung 6
**Q:** Every action in the trace went through PID 1 — you never spawned kubelet yourself. Why is that indirection the whole point, and what would you lose in supervision and logging with `/usr/bin/kubelet &` in a shell?

**A:** The indirection is the point because only PID 1, as the process's parent and cgroup manager, can reliably supervise it: systemd places kubelet in its own cgroup (`system.slice/kubelet.service`) so every child is tracked and none can escape via double-forking, records the main PID, and arms `Restart=always`. Run `/usr/bin/kubelet &` from a shell and you lose supervision entirely — when kubelet crashes at 3 a.m., nothing restarts it; when your SSH session ends, the process may be killed or orphaned; and `status` truth degrades back to `ps | grep`. You also lose logging: systemd wires kubelet's fd 1 and fd 2 to a journald socket before exec, so every line is captured, tagged `_SYSTEMD_UNIT=kubelet.service`, timestamped, and queryable via `journalctl -u kubelet` — from a shell, output just goes to your terminal (or wherever you redirected it) and is never indexed.

### Before Rung 7
**Q:** A static pod and a systemd service both "run a process and restart it if it dies." Derive who the supervisor is in each case, and why you'd never wrap a static pod's container in its own systemd unit.

**A:** For a systemd service (kubelet, containerd), the supervisor is **systemd/PID 1**: it fork+execs the process, tracks it in a cgroup, and applies `Restart=`. For a static pod (a manifest in `/etc/kubernetes/manifests/`), the supervisor is **kubelet**: kubelet watches that directory, tells containerd to run the containers, and restarts them per the pod spec — Kubernetes *is* their supervisor. You'd never wrap the static pod's container in its own systemd unit because that would create two supervisors fighting over one process: kubelet restarts a dead container itself, so a systemd unit doing the same would race it, double-start, and confuse both restart loops. The layering is "supervise the supervisor": systemd manages kubelet; kubelet manages pods; a container runs one process, not a whole init system.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Buenos Aires: it works… until the reboot" (Easy)
**Setup:**
```bash
sudo tee /opt/lab-pulse.sh >/dev/null <<'SH'
#!/bin/bash
while true; do echo "pulse OK $(date +%T)"; sleep 10; done
SH
sudo chmod +x /opt/lab-pulse.sh
sudo tee /etc/systemd/system/lab-pulse.service >/dev/null <<'UNIT'
[Unit]
Description=Lab heartbeat publisher

[Service]
ExecStart=/opt/lab-pulse.sh

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-pulse.service
```
**Situation:** Monitoring pages you after every planned node maintenance: the heartbeat agent `lab-pulse` is down again after each reboot. Every time, the previous on-call "fixed" it by SSH-ing in and starting it by hand — and every reboot it dies again. Right now `systemctl status lab-pulse` says `active (running)`, which is exactly why the team keeps closing the ticket as "works for me."

**Your task:** Make `lab-pulse.service` both run now *and* come back on every future boot. Do not edit the unit file — it already contains everything you need.

**Verify:**
```bash
systemctl is-active lab-pulse && systemctl is-enabled lab-pulse   # expected: "active" then "enabled"
```

### 🟢 Scenario 2 — "Montevideo: the service that died in silence" (Easy)
**Setup:**
```bash
sudo tee /opt/lab-ticker.sh >/dev/null <<'SH'
#!/bin/bash
if [[ ! -f /etc/lab-ticker/feed.url ]]; then
  echo "FATAL: config file /etc/lab-ticker/feed.url is missing - refusing to start" >&2
  exit 1
fi
while true; do echo "tick $(date +%T) feed=$(cat /etc/lab-ticker/feed.url)"; sleep 15; done
SH
sudo chmod +x /opt/lab-ticker.sh
sudo tee /etc/systemd/system/lab-ticker.service >/dev/null <<'UNIT'
[Unit]
Description=Lab market ticker

[Service]
ExecStart=/opt/lab-ticker.sh
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-ticker.service 2>/dev/null || true
```
**Situation:** A teammate pings you: "lab-ticker is dead on the new box, and there's *nothing* in `/var/log` — no ticker log file at all. I have no idea why it exits." They have been running `ls /var/log | grep ticker` for twenty minutes.

**Your task:** Find out — from the journal, not from reading the script — exactly why `lab-ticker.service` exits, fix the root cause, and get the service running.

**Verify:**
```bash
systemctl is-active lab-ticker   # expected: active
```

### 🟡 Scenario 3 — "Santiago: the upgrade that ate the port flag" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-api
sudo tee /opt/lab-api/api.sh >/dev/null <<'SH'
#!/bin/bash
exec python3 -m http.server "${LAB_API_PORT:-8400}" --bind 127.0.0.1
SH
sudo chmod +x /opt/lab-api/api.sh
sudo tee /opt/lab-api/shipped.unit >/dev/null <<'UNIT'
[Unit]
Description=Lab API (vendor unit - do not edit)

[Service]
ExecStart=/opt/lab-api/api.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
sudo cp /opt/lab-api/shipped.unit /lib/systemd/system/lab-api.service
sudo tee /usr/local/sbin/lab-api-upgrade >/dev/null <<'SH'
#!/bin/bash
# Simulates the package manager reinstalling lab-api: rewrites the vendor unit in /lib
cp /opt/lab-api/shipped.unit /lib/systemd/system/lab-api.service
systemctl daemon-reload
systemctl restart lab-api.service
echo "lab-api upgraded (vendor unit rewritten)"
SH
sudo chmod +x /usr/local/sbin/lab-api-upgrade
sudo systemctl daemon-reload
sudo systemctl enable --now lab-api.service
```
**Situation:** The internal API must listen on **port 8420** — the only port the host firewall allows. Last month someone made that happen by editing the vendor unit in `/lib/systemd/system/` directly. Last night's package upgrade (simulated here by `sudo lab-api-upgrade`) rewrote that file, and the API silently fell back to port 8400; every client is now getting connection-refused. This will happen again on the next upgrade unless you fix it the right way.

**Your task:** Make `lab-api.service` serve on 127.0.0.1:8420 in a way that **survives** any future run of `sudo lab-api-upgrade` — without touching `/lib/systemd/system/lab-api.service`.

**Verify:**
```bash
sudo lab-api-upgrade && sleep 1 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8420/   # expected: 200 even right after an upgrade
```

### 🟡 Scenario 4 — "Lima: start request repeated too quickly" (Medium)
**Setup:**
```bash
sudo tee /etc/systemd/system/lab-worker.service >/dev/null <<'UNIT'
[Unit]
Description=Lab queue worker
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
EnvironmentFile=/etc/lab-worker.env
ExecStart=/bin/bash -c 'echo "lab-worker: consuming queue $${LAB_QUEUE:?LAB_QUEUE is not set}"; exec sleep infinity'
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-worker.service 2>/dev/null || true
sleep 8
```
**Situation:** The queue worker was deployed an hour ago and has never come up. `systemctl status lab-worker` shows `failed` and mentions nothing useful beyond a `start-limit-hit` / "Start request repeated too quickly" — and when a colleague tried `systemctl start` again, it refused immediately without even trying. The deploy pipeline says the unit file was installed correctly.

**Your task:** Dig the *original* failure reason out of the journal (it is not the rate limit — that is only the symptom), fix the root cause, clear the failure state, and get `lab-worker` running stably.

**Verify:**
```bash
systemctl is-active lab-worker && sleep 5 && systemctl is-active lab-worker   # expected: "active" twice (not restarting in a loop)
```

### 🟠 Scenario 5 — "Quito: a dependency in chains" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-db
sudo tee /opt/lab-db/start.sh >/dev/null <<'SH'
#!/bin/bash
echo "lab-db: accepting connections"
exec sleep infinity
SH
sudo tee /etc/systemd/system/lab-db.service >/dev/null <<'UNIT'
[Unit]
Description=Lab database engine

[Service]
ExecStart=/opt/lab-db/start.sh
Restart=on-failure
UNIT
sudo tee /etc/systemd/system/lab-frontend.service >/dev/null <<'UNIT'
[Unit]
Description=Lab frontend
Requires=lab-db.service
After=lab-db.service

[Service]
ExecStart=/bin/bash -c 'echo "lab-frontend: serving"; exec sleep infinity'
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl mask lab-db.service
sudo systemctl start lab-frontend.service 2>/dev/null || true
```
**Situation:** During an incident two weeks ago, the then-on-call "temporarily" took the database out of rotation and then left the company. Now the frontend won't start at all: `systemctl start lab-frontend` errors out instantly, and every attempt to bring the stack up dies with dependency errors. Management wants both services running *and* guaranteed to come up after the next reboot.

**Your task:** Untangle the chain: get `lab-db.service` startable again, fix whatever else prevents it from actually running, bring `lab-frontend` up through its dependency, and make **both** units start at boot. (One of the two units cannot be enabled as shipped — you must fix that too.)

**Verify:**
```bash
systemctl is-active lab-db lab-frontend && systemctl is-enabled lab-db lab-frontend   # expected: active, active, enabled, enabled
```

### 🔴 Scenario 6 — "Bogota: retire the nohup, ship a real service" (Expert)
**Setup:**
```bash
sudo useradd -r -s /usr/sbin/nologin labuser6 2>/dev/null || true
sudo mkdir -p /opt/lab-sensor
sudo tee /opt/lab-sensor/sensor.py >/dev/null <<'PY'
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"lab-sensor OK\n")
    def log_message(self, fmt, *args):
        print("lab-sensor: " + (fmt % args), flush=True)

print("lab-sensor: listening on 127.0.0.1:8460", flush=True)
HTTPServer(("127.0.0.1", 8460), H).serve_forever()
PY
sudo chown -R labuser6: /opt/lab-sensor
# The "previous admin" way: run it as root with nohup-style detachment, zero supervision
sudo setsid bash -c 'cd /opt/lab-sensor && exec python3 sensor.py >> nohup.out 2>&1' < /dev/null &
sleep 1
curl -s http://127.0.0.1:8460/ && echo "legacy sensor is up (root, unsupervised)"
```
**Situation:** The sensor-fleet endpoint on this box is a `python3 sensor.py` that the previous admin launched **as root with nohup** — there is a `nohup.out` in `/opt/lab-sensor` to prove it. When it crashed last Tuesday, nobody noticed for six hours, and the security review flagged "network daemon running as root, unmanaged." You have been told to do it properly this time.

**Your task:** Replace the legacy process with a real `lab-sensor.service`: it must run as **labuser6** (not root), restart itself within a few seconds if it dies, be wired into boot, and keep serving on 127.0.0.1:8460. Then prove the self-healing by SIGKILL-ing its main process. (Careful: the legacy process is still squatting on the port — your unit's logs will tell you about it.)

**Verify:**
```bash
PID=$(systemctl show -p MainPID --value lab-sensor); [ "$PID" -gt 1 ] && sudo kill -9 "$PID"; sleep 5
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8460/   # expected: 200 (it healed itself)
ps -o user= -p "$(systemctl show -p MainPID --value lab-sensor)"  # expected: labuser6
systemctl is-enabled lab-sensor                                   # expected: enabled
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Buenos Aires: it works… until the reboot"
**Solution:**
```bash
sudo systemctl enable lab-pulse.service    # writes the .wants/ symlink for future boots
systemctl is-active lab-pulse              # already active from the earlier start
systemctl is-enabled lab-pulse             # now: enabled
# (on a fresh box you'd do both in one shot: sudo systemctl enable --now lab-pulse)
```
**Why this works & what it teaches:** This is Rung 3.3 verbatim: `start` is imperative and touches only the live system, while `enable` reads the `[Install]` section (`WantedBy=multi-user.target`) and materializes it as a symlink in `/etc/systemd/system/multi-user.target.wants/` — the only thing the next boot ever looks at. The previous on-call kept running `start`, which writes nothing to disk, so every reboot forgot the service. Where people go wrong: assuming `active (running)` implies "will survive a reboot" — `systemctl status` even tells you (`; disabled;` on the `Loaded:` line) if you know to look.
**Cleanup:** `sudo systemctl disable --now lab-pulse; sudo rm /etc/systemd/system/lab-pulse.service /opt/lab-pulse.sh; sudo systemctl daemon-reload`

### Scenario 2 — "Montevideo: the service that died in silence"
**Solution:**
```bash
journalctl -u lab-ticker -n 20 --no-pager
#   lab-ticker.sh: FATAL: config file /etc/lab-ticker/feed.url is missing - refusing to start
sudo mkdir -p /etc/lab-ticker
echo "https://feeds.example.com/ticks" | sudo tee /etc/lab-ticker/feed.url
sudo systemctl start lab-ticker
systemctl is-active lab-ticker             # active
```
**Why this works & what it teaches:** Rung 3.6: a systemd-managed service's stdout/stderr never becomes a file in `/var/log` — systemd wires fd 1/2 to journald before exec, and every line is indexed by `_SYSTEMD_UNIT=lab-ticker.service`. So the *only* place the FATAL line exists is `journalctl -u lab-ticker`. Your teammate's `ls /var/log` reflex is the exact pain from Rung 1. Where people go wrong: reading the script instead of the logs — fine here, hopeless when the binary is a 40 MB Go daemon.
**Cleanup:** `sudo systemctl disable --now lab-ticker 2>/dev/null; sudo rm -rf /etc/systemd/system/lab-ticker.service /opt/lab-ticker.sh /etc/lab-ticker; sudo systemctl daemon-reload`

### Scenario 3 — "Santiago: the upgrade that ate the port flag"
**Solution:**
```bash
# Interactive way: sudo systemctl edit lab-api   (opens override.conf in an editor)
# Non-interactive equivalent:
sudo mkdir -p /etc/systemd/system/lab-api.service.d
sudo tee /etc/systemd/system/lab-api.service.d/override.conf >/dev/null <<'INI'
[Service]
Environment="LAB_API_PORT=8420"
INI
sudo systemctl daemon-reload
sudo systemctl restart lab-api
systemctl cat lab-api        # shipped unit first, your override.conf listed after it (= higher precedence)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8420/   # 200
sudo lab-api-upgrade         # vendor unit rewritten again...
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8420/   # ...still 200
```
**Why this works & what it teaches:** Rung 3.1's precedence rule is the whole game: `/etc/systemd/system/` beats `/lib/systemd/system/`, and a drop-in under `lab-api.service.d/` *merges into* the vendor unit instead of replacing it. The fake upgrade only ever rewrites `/lib`, so your `Environment=` line survives every run — exactly how `KUBELET_EXTRA_ARGS` survives kubelet package upgrades in Rung 7 Example 2. Where people go wrong: editing `/lib` directly (works until the next upgrade, then silently reverts), or writing the drop-in but forgetting `daemon-reload`, so the in-memory unit is stale and the restart changes nothing.
**Cleanup:** `sudo systemctl disable --now lab-api; sudo rm -rf /lib/systemd/system/lab-api.service /etc/systemd/system/lab-api.service.d /opt/lab-api /usr/local/sbin/lab-api-upgrade; sudo systemctl daemon-reload`

### Scenario 4 — "Lima: start request repeated too quickly"
**Solution:**
```bash
systemctl status lab-worker --no-pager
#   Active: failed (Result: start-limit-hit)          <- symptom, not cause
journalctl -u lab-worker -n 30 --no-pager
#   lab-worker.service: Failed to load environment files: No such file or directory
#   lab-worker.service: Failed to run 'start' task: No such file or directory
#   ... Scheduled restart job, restart counter is at 3 ... start request repeated too quickly
echo 'LAB_QUEUE=orders' | sudo tee /etc/lab-worker.env
sudo systemctl reset-failed lab-worker     # clear the failed state + rate-limit counter
sudo systemctl start lab-worker
systemctl is-active lab-worker             # active, and stays active
```
**Why this works & what it teaches:** The unit's `EnvironmentFile=` (no `-` prefix, so it is mandatory) points at a file that does not exist, so systemd can't even reach fork+exec; `Restart=always` (Rung 3.5's supervisor loop) retried every second until `StartLimitBurst=3` within `StartLimitIntervalSec=60` tripped, and from then on every start attempt is rejected with the rate-limit message — burying the real error several restarts back in the journal. `reset-failed` clears the counter so you don't have to wait out the interval. Where people go wrong: treating `start-limit-hit` as the root cause and "fixing" it by raising the limit — the limit is doing its job; read the *first* failure in the journal, not the last.
**Cleanup:** `sudo systemctl disable --now lab-worker 2>/dev/null; sudo rm -f /etc/systemd/system/lab-worker.service /etc/lab-worker.env; sudo systemctl daemon-reload`

### Scenario 5 — "Quito: a dependency in chains"
**Solution:**
```bash
sudo systemctl start lab-frontend
#   Failed to start ... Unit lab-db.service is masked.
sudo systemctl unmask lab-db               # remove the /dev/null symlink from the incident
sudo systemctl start lab-frontend 2>&1 || true
#   A dependency job for lab-frontend.service failed. See 'journalctl -xe'.
journalctl -u lab-db -n 10 --no-pager
#   ... Failed at step EXEC ... Permission denied  (status=203/EXEC)
sudo chmod +x /opt/lab-db/start.sh
sudo systemctl start lab-frontend          # Requires= + After= pull lab-db in first, then frontend
sudo systemctl enable lab-frontend
sudo systemctl enable lab-db 2>&1 || true
#   The unit files have no installation config (WantedBy=, RequiredBy= ...)
sudo tee -a /etc/systemd/system/lab-db.service >/dev/null <<'INI'

[Install]
WantedBy=multi-user.target
INI
sudo systemctl daemon-reload
sudo systemctl enable lab-db
```
**Why this works & what it teaches:** Three separate pieces of Rung 3 machinery stack up here. (1) `mask` is a symlink to `/dev/null` in `/etc` — the highest-precedence layer from 3.1 — so *nothing* can start the unit until you `unmask`. (2) `Requires=` + `After=` (Rung 3.2) mean frontend refuses to run until lab-db actually starts, and lab-db can't exec a non-executable script (`203/EXEC` in the journal). (3) `enable` is powered *only* by the `[Install]` section (Rung 3.3) — a unit without one is startable but not enableable, so you add `WantedBy=` and `daemon-reload`. Where people go wrong: deleting `Requires=` to "make the error go away" — the frontend then starts happily with no database behind it.
**Cleanup:** `sudo systemctl disable --now lab-frontend lab-db; sudo rm -rf /etc/systemd/system/lab-frontend.service /etc/systemd/system/lab-db.service /opt/lab-db; sudo systemctl daemon-reload`

### Scenario 6 — "Bogota: retire the nohup, ship a real service"
**Solution:**
```bash
# 1. Find and retire the legacy root process squatting on 8460:
sudo ss -ltnp 'sport = :8460'              # shows the python3 run by root, with its PID
sudo pkill -f 'python3 sensor.py'          # the nohup-era process (unit not running yet, so safe)
# 2. Write the real unit:
sudo tee /etc/systemd/system/lab-sensor.service >/dev/null <<'INI'
[Unit]
Description=Lab sensor fleet endpoint
Wants=network-online.target
After=network-online.target

[Service]
User=labuser6
ExecStart=/usr/bin/python3 /opt/lab-sensor/sensor.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
INI
sudo systemctl daemon-reload
sudo systemctl enable --now lab-sensor
# 3. Prove self-healing:
PID=$(systemctl show -p MainPID --value lab-sensor); sudo kill -9 "$PID"; sleep 5
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8460/   # 200 again
systemctl show lab-sensor -p NRestarts     # >= 1: the supervisor did the restart, not you
```
**Why this works & what it teaches:** This is the whole file in one exercise. If you skip step 1, your unit crash-loops with `OSError: [Errno 98] Address already in use` — visible only via `journalctl -u lab-sensor`, which is how the port squatter is *meant* to be found. The unit then encodes everything the nohup approach lacked (Rung 6's contrast table): `User=` drops root, `Restart=always` + `RestartSec=2` arms the supervisor loop from Rung 3.5 (your `kill -9` is exactly the 3 a.m. crash, and `NRestarts` incrementing proves PID 1 — not you — brought it back), `enable` wires it into `multi-user.target` for boot, and stdout lands in the journal instead of `nohup.out`. Where people go wrong: `kill -9`-ing the *unit's* process to "free the port" while leaving the legacy one alive — check `ps -o user=` on who actually owns the listener.
**Cleanup:** `sudo systemctl disable --now lab-sensor; sudo rm -rf /etc/systemd/system/lab-sensor.service /opt/lab-sensor; sudo userdel labuser6 2>/dev/null; sudo systemctl daemon-reload`
