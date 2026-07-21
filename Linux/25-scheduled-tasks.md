# Scheduled Tasks — cron & systemd timers

*How Linux runs work at 2 AM while you sleep — and why your Kubernetes CronJob is just this idea wearing a YAML costume.*

---

## Rung 0 — 🛠 The Setup

**What you're learning:** how to make a Linux machine run a command *on a schedule*, with **no human present** to type it. Two engines do this: the ancient, everywhere-installed **cron**, and the modern, systemd-native **timer unit**. Plus one honorable mention — **`at`**, for "run this exactly once, later."

**Why it landed on your desk:** You're the platform engineer for a self-managed Kubernetes cluster (kubeadm, not a cloud managed control plane). Last week etcd — the key-value store holding the *entire* cluster state — got corrupted during a botched upgrade, and there was **no recent snapshot** to restore from. The postmortem action item has your name on it: *"Automate a nightly etcd snapshot on every control-plane node."* Nobody is going to SSH in at 2 AM to run `etcdctl snapshot save`. The machine has to do it itself, forever, and *tell you if it fails*.

At the same time, you already know the Kubernetes-native answer to "run something on a schedule": the **CronJob** object. You've written `schedule: "0 2 * * *"` a hundred times. What you *haven't* internalized is that those five fields are a 40-year-old Unix invention, that Kubernetes literally reuses the exact syntax, and that the thing you need to schedule now — an etcd backup — runs on the **node**, *outside* the cluster, so a CronJob can't do it. It has to be node-level cron or a systemd timer.

**What you already know that transfers:**
- **Cron five-field syntax** — from `kubectl` CronJobs. You already read `0 2 * * *` fluently. Good; that's Rung 2 half-done.
- **[systemd services](16-systemd-services.md)** — units, `systemctl enable --now`, `journalctl -u`. A timer is *just another unit* that pokes a service. If you know services, you're 80% to timers.
- **[Shell scripting](08-shell-scripting.md)** and **[I/O redirection](10-io-redirection-pipes.md)** — because the *thing* cron runs is a script, and where its output goes is a redirection question.
- **[Processes](07-processes-job-control.md)** — a scheduled job is just a process the scheduler forks for you.

Everything below builds from the etcd-backup story. Keep it in your head.

---

## Rung 1 — 🔥 The Pain

Picture the world **before** schedulers. You want logs rotated every midnight so `/var` doesn't fill up and crash the kubelet. Your options in a scheduler-less world:

1. **Stay awake and type it yourself at midnight.** Obviously insane, and you'd miss weekends.
2. **Write a program that loops forever:** `while true; do do_work; sleep 86400; done`. This is the "busy daemon" anti-pattern, and it hurts in specific, painful ways:
   - It **holds a process (and its memory) resident 24/7** just to act for 2 seconds a day. Multiply across 50 such tasks and you've got 50 idle daemons.
   - **`sleep 86400` drifts.** If `do_work` takes 3 minutes, the next run is at 00:03, then 00:06 — it slowly walks off the clock. It's *interval-based*, not *calendar-based*.
   - If the machine is **powered off at midnight** (a laptop, a spot node), the run is simply *lost forever*. When it boots at 9 AM, nothing catches up.
   - If your loop **crashes**, there's nobody to restart it and no record it died. Silent failure.

Who feels this worst? Anyone running **unattended infrastructure** — which is exactly you. A Kubernetes node has a dozen recurring chores that must happen without a human:

- **etcd snapshots** (your postmortem).
- **certificate expiry reminders** — kubeadm-issued certs in `/etc/kubernetes/pki` expire after 1 year; a silent expiry takes the whole API server down.
- **log & image cleanup** — pruning `/var/log/pods` and dangling container images so the disk doesn't hit the `nodefs` eviction threshold and start killing your pods.
- **health probes and metrics scraping** for cron-driven monitoring.

The pain that *forced* schedulers into existence: **recurring work must happen reliably, on a wall-clock schedule, without a resident babysitter process and without silently vanishing when things go wrong.** In 1975, a Unix engineer at Bell Labs wrote `cron` (from *chronos*, Greek for time) precisely so a single lightweight daemon could own *all* the machine's scheduled work, waking only when something is actually due.

> **Check yourself before Rung 2:** Why is a `while true; do work; sleep 86400; done` loop *fundamentally* worse than a scheduler for a task that must run "every day at 2 AM" — name two distinct failure modes, not just "it wastes memory."

---

## Rung 2 — 💡 The One Idea

Here is the sentence everything hangs off. **Memorize it:**

> **A scheduler is one always-running daemon that watches the clock and, at the moments you declared, forks a process to run your command — so you declare *when*, and it owns the *forking*.**

That's it. Every feature below is *derived* from that sentence:

- "It watches the **clock**" → therefore there's a **syntax to declare times** (the five cron fields; systemd's `OnCalendar`).
- "It **forks a process**" → therefore the job runs in some **environment** (a `PATH`, a user, a working dir) that you didn't set up interactively, which is the #1 source of "works in my shell, fails in cron."
- "It runs your **command**" → therefore whatever the command prints (stdout/stderr) has to **go somewhere** — mail, a log, `/dev/null`.
- "**One always-running daemon**" → therefore if the *daemon* isn't running, *nothing* is scheduled; and there can be different daemons (`cron`, `systemd`) competing for the job.
- "At the **moments you declared**" → if the machine was **off** at that moment, did the moment "happen"? That single question splits the whole field into cron (no, it's lost — unless anacron) vs. systemd timers with `Persistent=true` (yes, it catches up).

Kubernetes tie-in, stated once and precisely: a **Kubernetes CronJob** is this exact idea, moved up a layer. The **CronJob controller** (running in `kube-controller-manager`) *is* the daemon watching the clock; your `schedule:` field *is* the five cron fields; and instead of forking a shell process it creates a **Job**, which creates a **Pod**. Same idea, different "process." Node-level cron forks a shell command; Kubernetes CronJob "forks" a pod.

> **Check yourself before Rung 3:** From the one-idea sentence alone, *derive* why a cron job that runs `docker ps` might fail with "command not found" even though `docker ps` works fine when you type it. (Hint: which clause of the sentence is doing the work here?)

---

## Rung 3 — ⚙️ The Machinery

> ### 🧸 Plain-English first (read this before the technical version)
>
> **The big picture: a clock-watching secretary runs your errands on schedule.**
>
> - **The secretary (3.1).** A small always-on program wakes once a minute, checks its appointment books, runs anything due, and dozes off again. Its finest tick is one minute — it simply cannot do anything faster than that.
> - **The appointment books (3.2).** Jobs live in four different places: each person's private book (edited only through a safe front-desk command, and always run as that person); one shared building-wide book (with an extra column saying *who* performs each errand); a drawer of drop-in pages (how installed software adds its own errands without scribbling in the shared book); and four folders labeled hourly/daily/weekly/monthly — drop a to-do script into one, and a helper simply runs everything in that folder at the right interval, no schedule syntax needed at all.
> - **The stranger problem (3.3).** The secretary doesn't know your personal shortcuts. When she runs your errand, it happens in a bare-bones setting — your custom search paths and nicknames don't exist there. That's why a command that works when *you* type it can fail for her with "can't find that." The fix: write full street addresses (complete file paths) in every job.
> - **Mail to a dead mailbox (3.4).** Whatever a job prints, the secretary tries to *mail* to its owner — but modern servers have no mail system, so complaints vanish silently into the void. The disciplined fix: tell every job to write its output into a log file you can actually read.
> - **The catch-up assistant (3.5).** If the machine is off when a job was due, the job is simply lost. A helper (anacron) instead tracks "days since last done" and runs missed daily/weekly chores shortly after the machine wakes up — that's how a laptop asleep at 2 AM still gets its maintenance. It can't do anything finer than one day.
> - **The modern system (3.6).** Alongside all this runs a newer scheduler built into the machine's main manager. Each chore is a *pair* of cards: one says *what* to do, the other says *when*. It can go finer than a minute, has built-in catch-up after downtime, can wait for things like "network is up," respects resource limits, and — the big one — every run's output lands in a searchable logbook, with its result recorded. No silent failures, which is why server operators prefer it.
> - **One-off reminders (3.7).** For "do this once, five minutes from now," a separate little tool queues a single job, runs it at the appointed time, and forgets it.

*Now the original technical deep-dive — the same ideas, in precise form:*

Go slow here. This is where the mental model gets built.

### 3.1 The cron daemon — what's actually running

When a Linux box boots, systemd starts a long-lived process — `cron` on Debian/Ubuntu, `crond` on RHEL/Fedora (same thing, different package name: `cron` vs `cronie`). Confirm it's alive:

```bash
systemctl status cron      # Debian/Ubuntu  (service is 'cron')
systemctl status crond     # RHEL/Fedora/CentOS (service is 'crond')
```

This daemon does something almost embarrassingly simple. **Once a minute, it wakes up, reads its list of jobs, and asks each one: "is your time-spec true for *this* minute?" If yes, it forks a child, sets up an environment, and runs the command.** Then it goes back to sleep for the rest of the minute. It is *not* a fancy real-time scheduler; its resolution is exactly **one minute**. You cannot cron something for "every 30 seconds" — that's a hard architectural floor (a systemd timer *can* do sub-minute; more later).

### 3.2 Where the job definitions live — the crontab files

The daemon doesn't invent jobs; it *reads* them from files called **crontabs** (cron tables). There are several distinct sources, and confusing them is a classic trap:

```
                          ┌─────────────────────────────────────────┐
                          │            cron daemon (crond)           │
                          │      "once a minute, read all these"     │
                          └───────────────────┬─────────────────────┘
                                              │ reads
        ┌──────────────────────┬──────────────┼──────────────────┬────────────────────┐
        ▼                      ▼              ▼                  ▼                    ▼
 ┌──────────────┐   ┌────────────────────┐ ┌───────────┐ ┌──────────────┐  ┌────────────────────┐
 │ Per-user     │   │ /etc/crontab       │ │/etc/cron.d│ │/etc/cron.daily│ │ (each has 5 fields │
 │ crontabs     │   │ (system-wide)      │ │  drop-in  │ │ /hourly/weekly│ │  + who + command)  │
 │ /var/spool/  │   │                    │ │  dir      │ │ /monthly dirs │ └────────────────────┘
 │  cron/       │   │ 5 fields + USER    │ │ 5 fields  │ │  ← just SCRIPTS│
 │  crontabs/   │   │ + command          │ │ + USER    │ │  no time spec! │
 │  <username>  │   │                    │ │ + command │ │  run by run-   │
 │              │   │                    │ │           │ │  parts via a   │
 │ 5 fields +   │   │                    │ │           │ │  cron.d entry  │
 │ command      │   │                    │ │           │ │                │
 │ (no USER —   │   │                    │ │           │ │                │
 │  runs as you)│   │                    │ │           │ │                │
 └──────────────┘   └────────────────────┘ └───────────┘ └──────────────┘
```

The four sources, precisely:

1. **Per-user crontabs** live in a spool directory (`/var/spool/cron/crontabs/<user>` on Debian, `/var/spool/cron/<user>` on RHEL). **You never edit these files by hand** — they're managed by the `crontab` command, which validates syntax and reloads the daemon. Format: five time fields, then the command. No username column, because the file *is* owned by a user, so it runs as that user.

2. **`/etc/crontab`** — the system-wide table, editable directly by root. Its lines have an **extra sixth column: the username** to run as. This is the historical home for system jobs.

3. **`/etc/cron.d/`** — a **drop-in directory**. Any file here is a mini-crontab in the *same format as `/etc/crontab`* (with the username column). This is how **packages** install their cron jobs — `apt install certbot` drops a file in `/etc/cron.d/` so it doesn't have to fight over the one shared `/etc/crontab`. This is the modern, sane place to add a system job.

4. **`/etc/cron.{hourly,daily,weekly,monthly}/`** — these are **directories of executable scripts**, *not* crontab files. The scripts inside have **no time spec at all**. Instead, a single entry (in `/etc/crontab` or `/etc/cron.d/`) runs a helper called **`run-parts`** against the directory at the right interval. `run-parts /etc/cron.daily` means "execute every script in that directory, in order." So dropping a script into `/etc/cron.daily/` is the *zero-syntax* way to say "run this once a day" — you don't write any cron fields at all.

### 3.3 The environment trap — the mechanism the user never sees

Here's the moving part that bites everyone. When cron forks your job, it does **not** give it your interactive shell environment. It runs with a **minimal, hardcoded environment**: often just `PATH=/usr/bin:/bin`, `SHELL=/bin/sh`, `HOME=<user's home>`, and *not* the `PATH` your `.bashrc` builds up, *not* your `kubectl` alias, *not* the `/usr/local/bin` where you installed `etcdctl`. That's *derived straight from Rung 2*: the daemon forks a fresh process; it never sourced your login files.

So a command that works when *you* type it can fail under cron with "command not found." **Fix:** always use absolute paths in cron jobs (`/usr/local/bin/etcd-backup.sh`, not `etcd-backup.sh`), or set `PATH=` explicitly at the top of the crontab.

### 3.4 Output & mail — where stdout goes

Cron captures whatever your job prints to **stdout and stderr**. By default it tries to **email** that output to the job's owner (via the local Mail Transfer Agent and the `MAILTO` variable). On a modern server with no mail system installed, that mail goes nowhere — meaning **error output silently vanishes.** This is the "silent failure" problem in its rawest form. The disciplined pattern is to redirect explicitly:

```bash
0 2 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

`>>` appends stdout to a log; `2>&1` folds stderr into the same place ([I/O redirection](10-io-redirection-pipes.md)). Now failures land in a file you can inspect — not in the void.

### 3.5 anacron — for machines that aren't always on

cron has that fatal gap: **if the machine is off when a job is due, the job is lost.** Fine for a 24/7 server, catastrophic for a laptop that's asleep at 2 AM. **anacron** patches this. It doesn't work in clock-time; it works in **days elapsed**. It records the last time each job ran in timestamp files under `/var/spool/anacron/`. When the machine boots (or anacron runs), it checks: "has it been ≥1 day since the daily jobs last ran? Yes? Run them now, catch-up style." On desktop distros, the `cron.daily/weekly/monthly` directories are actually driven by **anacron**, not cron, precisely so a powered-off laptop still gets its daily maintenance shortly after it wakes. Note: anacron's minimum granularity is **one day** — it can't do hourly.

### 3.6 The systemd timer — the modern parallel machine

Everything above is the cron world. Running *alongside* it on any systemd machine is a completely separate scheduling engine built into **[systemd](16-systemd-services.md)** itself. It works differently — and better, for nodes.

A systemd timer is **two units working as a pair**:

- A **`.service` unit** — the *what*. Exactly a normal (usually `Type=oneshot`) service that runs your command and exits. It knows nothing about scheduling.
- A **`.timer` unit** — the *when*. It shares the service's basename (`backup.timer` drives `backup.service` by naming convention) and carries the schedule in `[Timer]` directives.

```
   ┌──────────────────┐     when its schedule fires      ┌──────────────────────┐
   │   backup.timer   │  ───────────────────────────────▶│   backup.service     │
   │  [Timer]         │      systemd starts the service   │  [Service]           │
   │  OnCalendar=...  │      with the SAME basename       │  Type=oneshot        │
   │  Persistent=true │                                    │  ExecStart=/usr/...  │
   └──────────────────┘                                    └──────────┬───────────┘
        ▲                                                             │ runs, logs to
        │ enabled & tracked by                                        ▼
   ┌────┴───────────────────────────────────┐              ┌────────────────────┐
   │ systemd (PID 1) — the same manager that │              │ journald           │
   │ runs kubelet.service, containerd.service│              │ journalctl -u      │
   └─────────────────────────────────────────┘              │ backup.service     │
                                                            └────────────────────┘
```

Why this pairing is powerful, mechanically:
- The schedule lives in `OnCalendar=` (wall-clock, e.g. `*-*-* 02:00:00`) *or* `OnBootSec=` / `OnUnitActiveSec=` (relative, monotonic time — "15 min after boot," "1h after last run"). You can even do sub-minute intervals — no one-minute floor.
- **`Persistent=true`** is systemd's built-in anacron: it records the last trigger time on disk, and if the machine was **off** when the timer should have fired, it runs the service **immediately on next boot** to catch up. One directive replaces the entire anacron mechanism.
- Because the job *is* a service, it inherits the whole systemd feature set: **ordering and dependency** directives (`After=network-online.target`, `Requires=`), **resource limits** ([cgroups](14-cgroups.md) via `MemoryMax=`), automatic **restart policies**, and — the big one — **all output goes to [journald](16-systemd-services.md)**. There is no "mail into the void." `journalctl -u backup.service` shows you every run, its exit code, and its output. **No silent failures.** This is the core reason node operators prefer timers to cron for anything that matters.

### 3.7 `at` — the one-shot

Neither cron nor timers are for "run this *once*, 5 minutes from now." That's the **`at`** command (daemon: `atd`). You pipe it a command and a time-spec; it queues the job, runs it exactly once at that time, then forgets it. Think of it as a scheduler with a schedule of length one.

> **Check yourself before Rung 4:** A script dropped into `/etc/cron.daily/` has **no** cron fields in it at all — so what actually decides it runs once a day, and which helper executes it? And in the systemd world, if you write both units but run `systemctl enable --now backup.service` instead of `backup.timer`, what happens to the schedule?

---

## Rung 4 — 🏷 The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|---|---|---|
| **cron / crond** | The always-running daemon that wakes every minute and runs due jobs | 3.1 — the engine |
| **crontab** | A file listing jobs (time-spec + command); also the *command* to edit it safely | 3.2 — job definitions |
| **`crontab -e` / `-l`** | Edit / list *your* per-user crontab through the validating wrapper | 3.2 — per-user spool |
| **`/etc/crontab`** | System-wide table; lines carry an extra **username** column | 3.2 — system jobs |
| **`/etc/cron.d/`** | Drop-in directory of mini-crontabs (with username col); where packages install jobs | 3.2 — modern system jobs |
| **`/etc/cron.daily` etc.** | Directories of **scripts** (no time-spec), run by `run-parts` on a schedule | 3.2 — zero-syntax jobs |
| **`run-parts`** | Helper that executes every script in a directory in order | 3.2 — drives cron.daily/etc. |
| **five fields** | `min hour day-of-month month day-of-week` — the time spec | 3.1 — the clock match |
| **`@reboot`, `@daily`** | Special string shorthands for common schedules (`@daily` = `0 0 * * *`) | 3.1 — the clock match |
| **`MAILTO`** | Crontab variable naming who gets emailed the job's output | 3.4 — output routing |
| **anacron** | Day-granularity catch-up scheduler for machines that aren't always on | 3.5 — the off-machine gap |
| **`at` / `atd`** | Command + daemon to run something exactly **once**, later | 3.7 — one-shot |
| **`.timer` unit** | systemd unit holding a schedule; triggers its paired `.service` | 3.6 — modern when |
| **`.service` unit** | The systemd unit that actually runs the command | 3.6 — modern what |
| **`OnCalendar=`** | Wall-clock schedule directive in a timer (`*-*-* 02:00:00`) | 3.6 — calendar time |
| **`OnBootSec=` / `OnUnitActiveSec=`** | Monotonic (relative) schedule directives | 3.6 — relative time |
| **`Persistent=true`** | Timer directive: catch up a missed run after downtime | 3.6 — built-in anacron |
| **`systemctl list-timers`** | Command showing all timers, last & next fire time | 3.6 — inspection |
| **Kubernetes CronJob** | A cluster object whose `schedule:` reuses the five cron fields, running a **pod** | 2, 3, 5 — the tie-in |

**"Same kind of thing wearing different names":**
- **Scheduling engines (daemons):** `cron`/`crond`, `anacron`, `atd`, and `systemd` (for timers) — all four are "a process that fires jobs at times." Different clothes, same job.
- **Places to declare a *recurring* job:** `crontab -e` (per-user), `/etc/crontab`, `/etc/cron.d/*`, `cron.daily/` scripts, and a `.timer`+`.service` pair — all five are "where you write down *when and what.*"
- **Catch-up-after-downtime mechanisms:** anacron **and** systemd's `Persistent=true` — literally the same feature, one bolted onto cron, one built into systemd.
- **The two "relative vs absolute" pairs:** cron's `@reboot` ≈ systemd's `OnBootSec=`; cron's `0 2 * * *` ≈ systemd's `OnCalendar=*-*-* 02:00:00`. Same intent, two dialects.

> **Check yourself before Rung 5:** Without peeking at the table, name the two mechanisms that catch up a missed run after the machine was powered off — one bolted onto cron, one built into systemd — and state the minimum granularity limit of each.

---

## Rung 5 — 🔬 The Trace

Let's follow **one concrete action end-to-end**: your etcd backup, scheduled via cron, firing at 02:00. Then we'll contrast the same trace under a Kubernetes CronJob so the mirror is obvious.

**Setup:** you ran `crontab -e` as root and added:
```
0 2 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

Now the clock crosses 02:00:00. Here's every hop:

1. **02:00:00 — the daemon wakes.** `cron` (asleep since 01:59) wakes for its once-a-minute tick. It reads its in-memory copy of all crontabs (loaded when you saved, and refreshed on changes).

2. **The clock match.** For each job it compares the five fields against *now* = (min=0, hour=2, dom=16, mon=7, dow=Thu). Your spec `0 2 * * *` → minute 0 ✓, hour 2 ✓, rest wildcard ✓. **Match.** (`docker ps` would find no match at 02:01 and skip.)

3. **fork().** cron calls `fork()` to create a child process — it does **not** run the job in its own process, so a long or crashing job can't take the daemon down ([processes](07-processes-job-control.md)).

4. **Environment setup.** In the child, cron sets the minimal environment: `HOME=/root`, `SHELL=/bin/sh`, `PATH=/usr/bin:/bin`, `LOGNAME=root`. **Note what's missing:** your interactive `PATH` additions. This is why `etcd-backup.sh` uses the *absolute* path `/usr/local/bin/etcdctl` inside it.

5. **exec the shell.** cron runs the command via `/bin/sh -c '/usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1'`. The shell sets up the redirection (opens the logfile, points fd 1 and fd 2 at it) *before* exec'ing your script.

6. **Your script runs.** `etcd-backup.sh` calls `ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=... --key=... snapshot save /var/backups/etcd-$(date +%F).db`. It reads etcd's TLS certs from `/etc/kubernetes/pki/etcd/`, talks to the local etcd on port 2379, and writes a snapshot file.

7. **Output capture.** Everything the script prints — etcdctl's "Snapshot saved at ..." on stdout, any TLS error on stderr — flows through fd 1/fd 2 into `/var/log/etcd-backup.log`. Because we redirected explicitly, **nothing** goes to the mail void.

8. **Exit & reap.** The script exits (0 on success). cron's child exits; the daemon reaps it. cron goes back to sleep until 02:01. If output had been produced *and* no redirection existed, cron would now try to `sendmail` it to `MAILTO`/root.

```
02:00:00
   │
 [cron wakes] ──match `0 2 * * *`?── YES
   │
   ├─ fork() ─────────────► child process
   │                          │
   │                     set env (minimal PATH!)
   │                          │
   │                     exec /bin/sh -c "script >> log 2>&1"
   │                          │
   │                     etcd-backup.sh → etcdctl snapshot save
   │                          │           (reads /etc/kubernetes/pki/etcd/*)
   │                          │           (writes /var/backups/etcd-2026-07-16.db)
   │                          ▼
   │                     stdout+stderr ──► /var/log/etcd-backup.log
   │                          │
   │                        exit 0
   ▼                          │
[cron reaps child] ◄──────────┘
[sleep until 02:01]
```

**The same trace as a Kubernetes CronJob** (for `hour==2`), so you see the mirror bone-for-bone:
1. `kube-controller-manager`'s **CronJob controller** wakes (its own tick), compares `schedule: "0 2 * * *"` against now → match.
2. Instead of `fork()`, it **creates a Job** object in the API server (etcd).
3. The **Job controller** creates a **Pod**; the **scheduler** binds it to a node; that node's **kubelet** tells **containerd** to pull the image and start the container (with a **pause** container holding the [network namespace](13-namespaces.md), all inside the `kubepods` [cgroup](14-cgroups.md)).
4. The container runs to completion; kubelet reports exit status; Job marks Complete. Pod logs (not mail, not a file) are the output channel — `kubectl logs`.

Same five fields. Same "match the clock, then spawn a unit of work." The difference is only *what gets spawned*: a shell child vs. a pod. **But** — and this is the whole reason your etcd backup can't be a CronJob — the CronJob's pod runs *inside* the cluster, and etcd is the thing the cluster is *made of*. You can't reliably back up the foundation using a tool built on top of it. Node-level cron/timer it is.

> **Check yourself before Rung 6:** In step 5 of the trace, cron runs your job through `/bin/sh -c '...'` rather than exec'ing the script directly. Why does the shell need to be in the middle — and which part of step 7 (the `>> log 2>&1` redirection) would stop working if it weren't?

---

## Rung 6 — ⚖ The Contrast

The "older/alternative approach" here is a two-way contrast: **cron (older) vs. systemd timers (newer)**, both of which are alternatives to the Kubernetes-native CronJob for *cluster-scoped* work.

| Dimension | **cron** | **systemd timer** |
|---|---|---|
| Age / ubiquity | 1975; on literally every Unix | systemd era (~2010+); every modern Linux |
| Where output goes | Email (often into the void); you must redirect to a log | **journald** automatically — `journalctl -u` |
| Missed run after downtime | Lost (unless anacron bolted on) | `Persistent=true` catches up natively |
| Granularity | 1 minute floor | Sub-second possible |
| Dependencies / ordering | None — can't say "after network is up" | `After=`, `Requires=`, `Wants=` — full dependency graph |
| Resource limits on the job | None natively | Inherits [cgroup](14-cgroups.md) limits (`MemoryMax=`, `CPUQuota=`) |
| Randomized start (thundering herd) | No (some crons have `RANDOM_DELAY`) | `RandomizedDelaySec=` built in |
| Failure visibility | Silent unless you engineer logging | Exit code + logs tracked; `systemctl status` shows failed |
| Setup effort | One line in `crontab -e` | Two files (`.service` + `.timer`) + enable |
| Calendar expressiveness | Five fields + `@` strings | `OnCalendar` mini-language + `systemd-analyze calendar` to test |

**What cron can do that timers can't (cleanly):** be written in *one line* with *zero unit files*, and be understood by anyone who's touched Unix since the '70s. For a quick, low-stakes, human-visible job, `crontab -e` wins on sheer speed.

**What timers can do that cron can't:** guarantee **no silent failure** (journald), **catch up after downtime** (`Persistent=`), **wait for dependencies** (`After=network-online.target` — critical for a backup that needs etcd up), and **cap resources**. On a Kubernetes node, every one of those matters — a backup that silently fails, or fires before etcd is ready, is worse than no backup.

**When would you NOT need any of this?** When the work is *inside* the cluster and doesn't touch the node itself — then use a **Kubernetes CronJob**, so it's declarative, GitOps-managed, and scheduled onto whatever node has room. Reserve node-level cron/timers for things a pod *can't* do: backing up etcd, renewing the node's kubelet/API certs in `/etc/kubernetes/pki`, cleaning node disk.

**Why this over that, one sentence each:**
- *Timer over cron on a node:* because a node backup that fails silently is how you end up with the empty-snapshot postmortem you're trying to prevent.
- *CronJob over both, for in-cluster work:* because it's declarative, portable across nodes, and lives in Git with the rest of your manifests.

> **Check yourself before Rung 7:** Your etcd backup script needs etcd to be up *and* the disk mounted before it runs. Which single systemd-timer/service feature makes this safe, and what's the closest cron can offer? (Derive from the table — don't just recall a directive name.)

---

## Rung 7 — 🧪 The Prediction Test

Now the hands-on. For each: **write the prediction down first**, run the command, then verify. The point is to catch the gap between what you *think* the mechanism does and what it *actually* does.

### Example 1 — Normal case: a per-user cron job that actually fires

**Prediction:** *If I add a cron entry that writes a timestamp to a file every minute, then within ~60 seconds a new line will appear in that file, BECAUSE the cron daemon wakes each minute, matches `* * * * *` (always true), forks, and runs my command.*

```bash
# Open YOUR crontab through the safe validating editor:
crontab -e
# add this line, save, quit:
#   * * * * * date >> /tmp/cron-test.log 2>&1

crontab -l                        # verify it's registered:
# * * * * * date >> /tmp/cron-test.log 2>&1

sleep 65 && cat /tmp/cron-test.log
# Wed Jul 16 14:23:00 UTC 2026     <- one line per minute
```

**Verify:** A line appears within a minute, and a new one each minute after. If **nothing** appears, the lesson is either (a) the cron daemon isn't running — check `systemctl status cron` (Debian) / `crond` (RHEL); or (b) a `PATH`/permissions issue — check for mail with `cat /var/mail/$USER` or look at cron's own log: `journalctl -u cron` (or `grep CRON /var/log/syslog`). Clean up: `crontab -r` removes your crontab (careful — that wipes *all* your per-user jobs).

### Example 2 — The environment/failure edge case: why "works in my shell" breaks in cron

**Prediction:** *If I cron a command that relies on a binary in `/usr/local/bin` using its bare name, it will FAIL with "command not found," even though the same bare command works when I type it — BECAUSE cron's forked child gets a minimal `PATH` (`/usr/bin:/bin`) that never sourced my `.bashrc`.*

```bash
# Prove cron's environment differs from yours. Add to crontab -e:
#   * * * * * env > /tmp/cron-env.txt 2>&1
sleep 65
grep -E '^(PATH|SHELL|HOME)=' /tmp/cron-env.txt
# PATH=/usr/bin:/bin           <- NOT your rich interactive PATH
# SHELL=/bin/sh
# HOME=/home/youruser

# Now compare to your interactive shell:
echo "$PATH"
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/you/.local/bin ...
```

**Verify:** The `PATH` in `/tmp/cron-env.txt` is *shorter* than your interactive `echo $PATH` — typically missing `/usr/local/bin`. That single difference is why cron jobs must use **absolute paths** (`/usr/local/bin/etcdctl`) or set `PATH=` at the top of the crontab. A wrong result — identical PATHs — would mean your distro seeds a fuller cron PATH (some do via `/etc/environment` or a `PATH=` line in `/etc/crontab`); the lesson then is "never *assume* the PATH, always check it."

### Example 3 — Kubernetes-flavored: the etcd backup as a systemd timer (the production pattern)

**Prediction:** *If I create a `.service`+`.timer` pair with `OnCalendar=*-*-* 02:00:00` and `Persistent=true`, then `systemctl list-timers` will show it with a NEXT fire time of the coming 02:00, its output will land in journald (not mail), and if the box was off at 2 AM it'll run on next boot — BECAUSE the timer is a first-class systemd unit tracked by PID 1, and `Persistent=true` records last-run on disk to catch up.*

```bash
# 1) The service — the WHAT. /etc/systemd/system/etcd-backup.service
sudo tee /etc/systemd/system/etcd-backup.service >/dev/null <<'EOF'
[Unit]
Description=Snapshot etcd datastore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/etcd-backup.sh
EOF

# 2) The timer — the WHEN. /etc/systemd/system/etcd-backup.timer
sudo tee /etc/systemd/system/etcd-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Run etcd snapshot nightly at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 3) Load, enable, and start the timer (NOT the service):
sudo systemctl daemon-reload
sudo systemctl enable --now etcd-backup.timer

# 4) Verify it's scheduled:
systemctl list-timers etcd-backup.timer
# NEXT                        LEFT     LAST  PASSED  UNIT               ACTIVATES
# Fri 2026-07-17 02:00:00 UTC 11h left  -     -      etcd-backup.timer  etcd-backup.service

# 5) Fire the SERVICE once by hand to test the work without waiting for 2 AM:
sudo systemctl start etcd-backup.service

# 6) Read its output from journald — no mail, no lost errors:
journalctl -u etcd-backup.service --no-pager -n 20
# Jul 16 14:30:01 node1 systemd[1]: Starting Snapshot etcd datastore...
# Jul 16 14:30:02 node1 etcd-backup.sh[4211]: Snapshot saved at /var/backups/etcd-2026-07-16.db
# Jul 16 14:30:02 node1 systemd[1]: etcd-backup.service: Deactivated successfully.
```

**Verify:** `list-timers` shows a concrete NEXT time; `systemctl start etcd-backup.service` runs immediately and `journalctl -u` shows the snapshot line *and* the exit status. Contrast the two commands deliberately: you **enable the `.timer`** (that's what schedules), but you **start the `.service`** for a manual test run. A wrong result — `list-timers` doesn't show it — usually means you forgot `daemon-reload` after writing the files, or enabled the `.service` instead of the `.timer`. To prove `Persistent=true`, note the LAST column; after a reboot that spanned 02:00, a missed run shows up as a catch-up execution shortly after boot.

*(Bonus one-shot, for completeness — `at`:)*
```bash
echo 'kubectl drain node1 --ignore-daemonsets' | at now + 5 minutes
# job 3 at Thu Jul 16 14:35:00 2026
atq            # list pending at jobs:  3  Thu Jul 16 14:35:00 2026 a root
atrm 3         # cancel it before it fires
```
**Verify:** `atq` lists the queued job with its fire time; it runs **exactly once** then disappears from the queue. (Requires the `at` package + running `atd`: `sudo systemctl status atd`.)

---

## Rung 🏔 Capstone — Compress It

**One sentence (no notes):** A scheduler is one always-running daemon that watches the clock and forks your command at the times you declared — cron does it with five fields, systemd does it with a `.timer`+`.service` pair, and a Kubernetes CronJob does the exact same thing but spawns a pod.

**Three-sentence beginner explanation:** Instead of a human running a command at 2 AM, you tell a background service *when* and *what*, and it runs it for you forever. The classic tool is **cron** — one line like `0 2 * * *` means "at 02:00 daily" — and the modern tool is a **systemd timer**, which logs every run and can catch up after downtime so nothing fails silently. Kubernetes' **CronJob** reuses the identical time syntax but launches a pod, so the schedule skill you already have from `kubectl` is literally the same skill you use on the node.

**Sub-capabilities mapped back to the one idea** ("*declare when, the daemon owns the forking*"):

| Sub-capability | How it derives from the one idea |
|---|---|
| Five-field syntax / `OnCalendar` | The "declare *when*" half — the language for the clock match |
| `@reboot` / `OnBootSec=` | "When" can be relative to an event (boot), not just wall-clock |
| `/etc/cron.d`, `cron.daily`, per-user crontabs | Different *places* to declare the same when+what |
| Minimal-`PATH` env trap | Consequence of "the daemon **forks a fresh process**" — no login shell |
| MAILTO / journald / log redirect | The forked process prints somewhere — you route the *output* |
| anacron / `Persistent=true` | Handling "the declared moment happened while we were off" |
| `at` | The degenerate case: a schedule with exactly one moment |
| Kubernetes CronJob | Same idea one layer up — fork a **pod** instead of a shell child |

**Which rung to revisit hands-on:** **Rung 7, Example 3.** Reading about timers is easy; the muscle memory that sticks is the *enable-the-timer-but-start-the-service* distinction and pulling output from `journalctl -u`. Build the etcd-backup pair on a throwaway VM, reboot it across a scheduled time, and watch `Persistent=true` catch up — that single exercise cements the whole rung. Secondarily, revisit Rung 3.3/Example 2 (the PATH trap) the first time a "working" script mysteriously fails under cron, because you *will* hit it.

---

## Related concepts

- [systemd & services](16-systemd-services.md) — timers are units; journald is where their output lives.
- [processes & job control](07-processes-job-control.md) — a scheduled job is a forked process the daemon reaps.
- [shell scripting](08-shell-scripting.md) — the thing cron and timers actually run is a script.
- [I/O redirection & pipes](10-io-redirection-pipes.md) — `>> log 2>&1` is how you defeat silent cron failures.
- [cgroups](14-cgroups.md) — systemd services (and thus timer jobs) inherit resource limits from here.
- [Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — where node-level cron/timers sit next to CronJobs in the full picture.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why is `while true; do work; sleep 86400; done` fundamentally worse than a scheduler for "every day at 2 AM"? Name two distinct failure modes beyond wasted memory.

**A:** First, **it drifts off the clock**: `sleep 86400` is interval-based, not calendar-based — if the work takes 3 minutes, the next run is at 00:03, then 00:06, slowly walking away from 2 AM, whereas a scheduler matches wall-clock time each day. Second, **it fails silently and unrecoverably**: if the loop crashes, nobody restarts it and there is no record it died; and if the machine is powered off when the moment arrives, the run is simply lost with nothing to catch up. A scheduler daemon avoids all of these — it re-evaluates the calendar each minute, survives individual job crashes because each run is a fresh forked child, and (with anacron or `Persistent=true`) can catch up missed runs.

### Before Rung 3
**Q:** From the one-idea sentence alone, derive why a cron job running `docker ps` might fail with "command not found" even though it works when you type it.

**A:** The load-bearing clause is "**it forks a process**": when the daemon's clock match fires, cron forks a fresh child with a minimal, hardcoded environment — typically `PATH=/usr/bin:/bin`, `SHELL=/bin/sh` — because it never sourced your `.bashrc` or login files. Your interactive shell finds `docker` because your login environment built up a rich `PATH` (including places like `/usr/local/bin`); cron's child has none of that, so the bare name `docker` resolves to nothing and the job dies with "command not found." The fix that follows from the same derivation: use absolute paths in cron jobs, or set `PATH=` explicitly at the top of the crontab.

### Before Rung 4
**Q:** A script in `/etc/cron.daily/` has no cron fields — what decides it runs daily, and which helper executes it? And in systemd, what happens if you `systemctl enable --now backup.service` instead of `backup.timer`?

**A:** The `cron.daily/` directory holds plain executable scripts with no time spec; the schedule lives elsewhere — a single entry in `/etc/crontab` (or `/etc/cron.d/`, or anacron on desktop distros) fires at the daily interval and invokes the helper **`run-parts`**, which executes every script in the directory in order. So dropping a script there is the zero-syntax way to declare "daily." In the systemd case, enabling and starting `backup.service` instead of `backup.timer` runs the job **once, right now, and never again on a schedule**: the service knows nothing about scheduling — the `[Timer]` section with `OnCalendar=` lives in the `.timer` unit, and only enabling the timer registers the schedule with PID 1. The rule: enable the `.timer` (that's what schedules), start the `.service` only for a manual test run.

### Before Rung 5
**Q:** Name the two mechanisms that catch up a missed run after the machine was powered off — one bolted onto cron, one built into systemd — and state each one's minimum granularity limit.

**A:** The cron-world bolt-on is **anacron**: it works in days-elapsed rather than clock time, records the last run of each job in timestamp files under `/var/spool/anacron/`, and on boot runs anything overdue, catch-up style — but its minimum granularity is **one day** (it cannot do hourly or finer). The systemd-native equivalent is the timer directive **`Persistent=true`**: systemd records the last trigger time on disk and, if the machine was off when the timer should have fired, runs the service immediately on next boot. Timers have no coarse floor — systemd timers can schedule down to **sub-second/sub-minute** intervals (versus cron's own one-minute floor), so `Persistent=true` catch-up applies at whatever granularity the timer declares.

### Before Rung 6
**Q:** In step 5 of the trace, cron runs the job via `/bin/sh -c '...'` rather than exec'ing the script directly. Why must the shell be in the middle, and which part of the `>> log 2>&1` redirection would break without it?

**A:** The crontab line isn't just a program name — it's a *shell command line* containing shell syntax: the `>>` append operator and `2>&1` fd-duplication are interpreted by a shell, not by the kernel's exec. So cron hands the whole string to `/bin/sh -c`, and the shell opens the logfile and points file descriptors 1 and 2 at it *before* exec'ing your script. Without the shell in the middle, the entire redirection would break: `>>` and `2>&1` would be passed to the script as literal arguments instead of being performed, so nothing would open `/var/log/etcd-backup.log`, and the job's stdout/stderr would fall back to cron's default output path — the mail-to-`MAILTO` route that on a mailless server vanishes into the void.

### Before Rung 7
**Q:** Your etcd backup needs etcd up *and* the disk mounted before it runs. Which systemd-timer/service feature makes this safe, and what's the closest cron can offer?

**A:** The feature is systemd's **dependency and ordering directives** — because the scheduled job is a real service unit, its `[Unit]` section can declare `After=` / `Requires=` / `Wants=` (e.g. `After=network-online.target`, or after the etcd service and the relevant mount unit), so PID 1 will not start the backup until its prerequisites are actually up; this is exactly the "Dependencies / ordering" row of the contrast table where cron scores "None." Cron has no dependency graph at all — the closest it can offer is workarounds: schedule the job "late enough" and hope, use `@reboot` with a sleep, or write guard logic into the script itself (check etcd health and the mountpoint, and bail/retry if not ready). That gap — a backup that fires before etcd is ready — is one of the core reasons node operators prefer timers to cron for anything that matters.
