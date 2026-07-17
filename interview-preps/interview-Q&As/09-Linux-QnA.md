# Linux — Interview Q&A (from Akshay's real interviews)

> ⚠️ **Priority weak area.** You self-rated Linux 2.5–3/5 and stumbled on process scheduling, process vs thread, and CPU-debug fundamentals. This file makes the fundamentals crisp and adds a large "Core Linux to Master" section — rehearse it out loud until the *derivation* (not the memorized line) is second nature.

---

## Q1. How strong is your OS/Linux knowledge? Rate yourself.
**Asked in:** Trianz, Shell-2, HTC-1  |  **My performance:** Vague

**My answer (from transcript):**
Rated myself 3/5 for Linux and 2.5–3/5 for Windows, based on normal PC usage and troubleshooting. Told Trianz I don't have deep Linux experience but have "working knowledge — troubleshooting and all that."

**✅ Correct answer:**
Self-rating questions are really "can you back up the number with specifics?" A weak answer gives a number and stops; a strong answer *anchors the number to concrete work*. For a Senior DevOps/SRE role, frame it around operational Linux, not desktop usage:

> "I'd say a solid 3.5. Day-to-day I live in Linux on our nodes — I troubleshoot with `top`/`htop`, `ss`, `journalctl`, `df -h`, and `dmesg`; I read `/proc` and container cgroup limits when a pod gets OOM-killed; I manage services with `systemd`, permissions with `chmod`/`chown`, and I debug DNS and connectivity with `dig`, `curl -v`, and `tcpdump`. Where I'm still deepening is kernel-internals like the scheduler (CFS/EEVDF) and low-level memory management."

That last sentence (naming your growth edge honestly) reads as senior and self-aware. Avoid "based on PC usage" — it signals hobbyist, not operator.

```bash
# The "operator's dashboard" — commands a senior touches daily
uname -a                # kernel + arch
top; htop               # live CPU/mem per process
ss -tulpn               # listening sockets + owning PID
journalctl -u nginx -f  # follow a service's logs
df -h && df -i          # disk space AND inode usage
dmesg -T | tail         # kernel ring buffer (OOM, disk, driver events)
```

---

## Q2. You have 100 Linux servers and need the latest kernel version from all of them. What Ansible module/command would you use?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Suggested writing a Python script that uses the `os` module to get the OS/kernel version, then deploying it across all servers via Ansible to fetch the info. (Interviewer noted the direct answer is `gather_facts` / a shell module.)

**✅ Correct answer:**
Don't write custom code when Ansible already collects this. Two clean, idiomatic answers:

1. **`gather_facts` / the `setup` module** — Ansible auto-collects facts on every play, including `ansible_kernel`. Just print the fact; no script needed. This is the "Ansible-native" answer the interviewer wanted.
2. **The `command`/`shell` module running `uname -r`** — for an ad-hoc one-liner across the fleet.

Key distinction: `command` is safer (no shell, no pipes/redirects); `shell` is needed only when you use `|`, `>`, or env vars. Fetching a read-only value like a version = ad-hoc command, not a playbook script. Mentioning idempotency and that facts are cached/free shows maturity.

```bash
# Fastest: ad-hoc across the whole inventory
ansible all -i inventory -m command -a "uname -r"

# Ansible-native via gathered facts (no shell call at all)
ansible all -i inventory -m setup -a "filter=ansible_kernel"

# In a playbook:
# - hosts: all
#   tasks:
#     - debug: var=ansible_kernel        # from auto-gathered facts
```

---

## Q3. Difference between `chmod`, `chown`, and `chgrp` — what do they do?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
`chmod` modifies file-level access (read/write/execute). `chown` assigns user/groups and permissions. `chgrp` modifies group-level permissions. (My `chown` answer conflated user and group ownership, and I said `chgrp` changes "permissions" when it changes ownership.)

**✅ Correct answer:**
Keep two ideas separate: **who owns** a file vs **what the permission bits are**. Every file has an owning **user**, an owning **group**, and 9 permission bits (`rwx` for user / group / others).

- **`chmod` — changes the permission bits** (the `rwx`). It does *not* touch ownership. `chmod 644 f` or `chmod u+x f`.
- **`chown` — changes the owning user** (and optionally the group too, via `chown user:group f`). It changes *ownership*, not permission bits.
- **`chgrp` — changes only the owning group.** (`chown :group f` does the same thing.)

So the correction to what you said: `chown` sets *ownership* (not permissions), and `chgrp` changes the owning *group* (not "group permissions" — that's `chmod g±...`).

**Numeric permissions:** r=4, w=2, x=1, summed per class. `755` = `rwxr-xr-x`. Owner=7 (4+2+1), group=5 (4+1), others=5.

```bash
chmod 640 report.txt        # owner rw-, group r--, others ---
chmod u+x deploy.sh         # add execute for the owner (symbolic)
chown akshay report.txt     # change owning USER
chown akshay:devops report.txt   # change user AND group at once
chgrp devops report.txt     # change owning GROUP only
ls -l report.txt            # verify:  -rw-r----- akshay devops ...
```

---

## Q4. Difference between `su` and `sudo`?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
`sudo` provides root access (`sudo` + command). Said `su` works on similar lines but with less privileges — admitted I wasn't sure.

**✅ Correct answer:**
Both let you act as another user, but the model is different:

- **`su` (substitute user)** — *switches your whole shell* into another user's identity for the rest of the session. `su -` becomes root (asks for **root's** password); `su - alice` becomes alice. You stay that user until you `exit`. It's all-or-nothing and needs the *target* account's password.
- **`sudo` (superuser do)** — runs **one command** as another user (root by default), then drops back. It asks for **your own** password, and it's governed by `/etc/sudoers` (fine-grained: you can permit user X to run only `systemctl restart nginx`). Every use is logged.

Why `sudo` wins in production: no shared root password, least-privilege per-command rules, and an audit trail. So the correction: it's not that `su` has "less privileges" — `su -` gives *full* root; the real difference is **scope (session vs single command), whose password is used, and auditability.**

```bash
sudo systemctl restart nginx     # one command as root; your password; logged
sudo -i                          # start an interactive root shell via sudo
su -                             # switch to root for the whole session (root's pw)
su - alice                       # become alice (alice's pw)
sudo -u postgres psql            # run a command as a specific non-root user
sudo -l                          # list what sudo rights YOU have
```

---

## Q5. Explain how Linux process scheduling works.
**Asked in:** HTC-1  |  **My performance:** Didn't know

**My answer (from transcript):**
Said I'm not really sure / don't know.

**✅ Correct answer:**
The **scheduler** decides which runnable process (task) gets the CPU next, because there are always more processes than CPU cores. Build it up the ladder:

1. **Time-sharing:** the CPU is sliced into tiny time slices; the scheduler rapidly rotates tasks so they *appear* to run simultaneously. A **context switch** saves one task's registers/state and loads the next.
2. **Process states:** a task is Running, Runnable (ready, waiting for CPU), Sleeping/Blocked (waiting on I/O), Stopped, or Zombie. The scheduler only picks among **runnable** tasks.
3. **The scheduler itself — CFS (Completely Fair Scheduler)**, the long-time default (replaced by **EEVDF** in kernel 6.6+). CFS aims for *fairness*: it tracks each task's **virtual runtime (vruntime)** and always runs the task that has gotten the least CPU so far, keeping them balanced. No fixed time-slice — it's proportional to how many tasks are competing.
4. **Priority / `nice`:** niceness ranges **-20 (highest priority) to +19 (lowest)**. A lower nice value makes vruntime accrue slower, so that task gets more CPU. `nice`/`renice` set it.
5. **Scheduling classes:** normal tasks use CFS/EEVDF (`SCHED_OTHER`); **real-time** classes (`SCHED_FIFO`, `SCHED_RR`) always preempt normal tasks — used for latency-critical work.

One-liner for the interview: *"The Linux scheduler time-slices the CPU across runnable processes; the default fair scheduler (CFS, now EEVDF) uses virtual runtime to give every task a fair share, tunable with `nice`, while real-time classes can preempt everything else."*

```bash
nice -n 10 ./batch_job.sh        # start a low-priority job (nicer to others)
renice -n -5 -p 1234             # raise priority of running PID 1234 (needs root)
chrt -p 1234                     # (chrt) show/set real-time scheduling policy
ps -eo pid,ni,pri,stat,comm | head   # NI=nice, STAT=state (R,S,D,Z,T)
cat /proc/loadavg                # 1/5/15-min run-queue pressure
```

---

## Q6. What is the difference between a process and a thread?
**Asked in:** HTC-1  |  **My performance:** Didn't know (knew it once, blanked)

**My answer (from transcript):**
Said I knew this but forgot and would have to recall it — effectively couldn't answer.

**✅ Correct answer:**
- A **process** is a running program with its **own isolated memory** (address space), file descriptors, and resources. Processes are isolated from each other — one crashing doesn't corrupt another.
- A **thread** is a **unit of execution *inside* a process**. Threads of the same process **share** that process's memory and resources (heap, globals, file descriptors) but each has its **own stack, registers, and program counter**.

Analogy: the **process is a house**; **threads are people in the house** — they share the kitchen and rooms (memory) but each does their own task.

Trade-offs (what interviewers probe):
- **Sharing:** threads share memory → communication is fast/cheap but needs **locks/mutexes** to avoid race conditions. Processes are isolated → safer but IPC (pipes, sockets, shared memory) is heavier.
- **Cost:** creating a thread is cheaper than a process; context-switching between threads is lighter.
- **Failure blast radius:** a crashing thread can take down the whole process; a crashing process doesn't kill its siblings.
- **Linux detail:** to the kernel scheduler, threads and processes are both "tasks" — both created via `clone()`; a thread just shares more (`CLONE_VM`, etc.) with its parent. Threads share a **PID** (thread group ID) but each has a unique **TID**.

```bash
ps -eLf | head            # -L shows threads: NLWP=thread count, LWP=TID
cat /proc/<pid>/status | grep Threads   # thread count of a process
top -H                    # top in per-thread mode
ls /proc/<pid>/task/      # one dir per thread (TID) of the process
```

---

## Q7. How do you debug high CPU usage in Linux?
**Asked in:** HTC-1  |  **My performance:** Partial

**My answer (from transcript):**
Use `top`, `df`, `ps`. `df` is for disk usage; `top` shows which processes consume high CPU/memory — monitor them, kill unneeded processes, check again. (Named `top` correctly but `df` is disk, not CPU.)

**✅ Correct answer:**
Correction first: **`df` is disk-space, not CPU** — drop it from a CPU-debug story. A structured method:

1. **Confirm it's CPU and read load** — `uptime` / `cat /proc/loadavg`. Compare the 1-min load average to core count (`nproc`). Load ≈ cores = fully busy; load ≫ cores = saturated/queuing.
2. **Find the culprit process** — `top` (press `P` to sort by CPU) or `htop`. Note the PID. Use `top -H` or `ps -eLf` to find the hot **thread**.
3. **Distinguish the *kind* of load** — in `top`, look at `%us` (user code) vs `%sy` (kernel/syscalls) vs `%wa` (I/O wait) vs `%si` (soft interrupts). High `%wa` means it's actually **disk/network I/O**, not CPU-bound. High `%sy` points at syscalls/context-switch storms.
4. **Dig into the process** — `pidstat 1`, `ps -p <pid> -o %cpu,etime,cmd`; check what it's doing with `strace -p <pid>` (syscalls) or `perf top` / `py-spy`/profilers for the hot code path.
5. **Act & verify** — `renice` to deprioritize, fix/restart the app, or `kill`/`kill -9` as a last resort. Then re-check load. Killing blindly is a junior move; identify *why* first.

Say the method, not just tool names — that's what separated the "Partial" from a strong answer.

```bash
uptime                       # load averages: 1 / 5 / 15 min
nproc                        # number of CPU cores (compare vs load)
top                          # press 'P' = sort by CPU, '1' = per-core view
pidstat -u 1 5               # per-process CPU each second
ps -eo pid,%cpu,comm --sort=-%cpu | head    # top CPU processes
top -H -p <pid>              # which THREAD in that process is hot
strace -p <pid> -c          # summarize syscalls of a running process
```

---

# 🔺 Core Linux to Master (mostly not asked yet — study these)

> The section that closes the gap. Each answer is written to be *derivable*, not memorized — understand the "why". My answer for all of these = *"(Not asked — study & rehearse)"*.

## Q8. What are Linux signals? Explain SIGTERM vs SIGKILL and the Kubernetes link.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Signals** are asynchronous notifications the kernel/other processes send to a process to tell it something happened or to ask it to do something.

- **SIGTERM (15)** — "please terminate." It's **catchable**: the app can install a handler to flush buffers, finish requests, and shut down cleanly (**graceful shutdown**). This is the polite default of `kill`.
- **SIGKILL (9)** — "die now." It **cannot be caught, blocked, or ignored** — the kernel kills the process immediately. No cleanup → risk of corruption/leaked resources. Last resort.
- **SIGHUP (1)** — traditionally "terminal closed"; many daemons repurpose it to **reload config** without restart. **SIGINT (2)** = Ctrl-C. **SIGSTOP/SIGCONT** = pause/resume.

**Kubernetes link (say this — it's the money answer):** when a pod is deleted, the kubelet sends **SIGTERM** to PID 1 in the container, waits `terminationGracePeriodSeconds` (default **30s**), then sends **SIGKILL** if it hasn't exited. So your app must trap SIGTERM to drain connections; combine with a `preStop` hook and readiness gates for zero-downtime rollouts. (PID-1/init-forwarding caveat: if your app isn't PID 1, signals may not reach it — use an init like `tini` or `exec` in the entrypoint.)

```bash
kill -TERM 1234      # graceful (default). same as: kill 1234
kill -9 1234         # SIGKILL — forceful, no cleanup
kill -HUP $(pgrep nginx)   # reload config on many daemons
kill -l              # list all signal names/numbers
trap 'echo caught SIGTERM; cleanup; exit 0' TERM   # handle it in a shell script
```

---

## Q9. Explain namespaces and cgroups — how do containers use them?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Containers are **not a kernel object** — they're a *combination* of two Linux kernel features plus a filesystem:

- **Namespaces = isolation (what a process can *see*).** Each namespace virtualizes one resource so the process thinks it has its own copy. Types: **PID** (own process tree — container sees its app as PID 1), **NET** (own interfaces/IPs/ports), **MNT** (own filesystem mounts), **UTS** (own hostname), **IPC**, **USER** (map container root to unprivileged host UID), **cgroup**.
- **cgroups (control groups) = limitation (what a process can *use*).** They meter and cap **CPU, memory, I/O, PIDs**. cgroup **v2** is the current unified hierarchy.

So: **namespaces isolate, cgroups limit.** A container = a process running in its own set of namespaces, constrained by cgroups, using an overlay filesystem image. In Kubernetes, a pod's `resources.requests/limits` become cgroup settings; exceed the memory **limit** → the kernel **OOM-kills** that container.

```bash
lsns                         # list namespaces on the host
unshare --pid --fork --mount-proc bash   # spawn a shell in a new PID namespace
cat /sys/fs/cgroup/memory.max            # (cgroup v2) memory cap of current cgroup
systemd-cgls                 # tree of cgroups
nsenter -t <pid> -n ss -tulpn   # run ss inside another process's NET namespace
```

---

## Q10. What is `/proc` and what do you use it for?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
`/proc` is a **virtual (pseudo) filesystem** — it doesn't exist on disk; the kernel generates its contents on read. It's the primary window into kernel and process state.

- **Per-process:** `/proc/<pid>/` — `status` (memory, threads, UID), `cmdline` (launch command), `environ` (env vars), `fd/` (open file descriptors), `limits` (ulimits), `cgroup`, `task/` (threads).
- **System-wide:** `/proc/cpuinfo`, `/proc/meminfo`, `/proc/loadavg`, `/proc/mounts`, `/proc/net/*`.
- **Tunables via `/proc/sys`** (same as `sysctl`): e.g. `/proc/sys/vm/swappiness`, `/proc/sys/net/ipv4/ip_forward`.

Most tools (`ps`, `top`, `free`, `ss`) are really just pretty-printers over `/proc`. Related: **`/sys` (sysfs)** exposes devices/kernel objects. Knowing `/proc` lets you debug when the nice tools aren't installed (common in minimal containers).

```bash
cat /proc/meminfo | head       # memory breakdown
cat /proc/<pid>/status         # per-process state, VmRSS, Threads
ls -l /proc/<pid>/fd           # every open file/socket of a process
cat /proc/<pid>/cmdline | tr '\0' ' '   # exact command that started it
sysctl vm.swappiness           # = reading /proc/sys/vm/swappiness
```

---

## Q11. How does systemd work, and how do you use journalctl?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**systemd** is the modern init system — **PID 1**, the first user-space process; it boots the system and supervises services. Its unit of management is the **unit**: `.service` (daemons), `.socket`, `.timer` (cron replacement), `.mount`, `.target` (groups of units, like the old runlevels — e.g. `multi-user.target`). Units live in `/etc/systemd/system` (admin) and `/lib/systemd/system` (packages). systemd tracks each service in its **own cgroup**, so it reliably knows every child process.

**`systemctl`** controls units; **`journalctl`** reads the **journal** — systemd's centralized, structured, indexed log (captures stdout/stderr of every service, filterable by unit/time/priority/boot). This replaces hunting through scattered files under `/var/log`.

```bash
systemctl status nginx           # state + recent logs + main PID
systemctl start|stop|restart nginx
systemctl enable --now nginx     # start now AND on every boot
systemctl daemon-reload          # after editing a unit file
journalctl -u nginx -f           # follow one service's logs live
journalctl -u nginx --since "10 min ago" -p err   # errors only, time-scoped
journalctl -b -1                 # logs from the previous boot
systemctl list-units --failed    # what's broken
```

---

## Q12. What is load average and how do you interpret it?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Load average = the number shown by `uptime`/`top` as three values: the **1-, 5-, and 15-minute** averages of the **run queue** — tasks that are **running or waiting** for CPU. (On Linux it *also* counts tasks in **uninterruptible sleep (`D` state)** — usually blocked on disk/NFS I/O — which is why high load can mean an **I/O** problem, not CPU.)

**Interpret relative to core count (`nproc`):**
- load = cores → CPUs ~100% used, no queue.
- load < cores → spare capacity.
- load > cores → tasks are **queuing** (saturation).

The three numbers show **trend**: 1-min ≫ 15-min = load spiking now; 15-min ≫ 1-min = a spike that's subsiding. Always divide by cores: load 8 is fine on a 16-core box, on fire on a 2-core box. If load is high but CPU `%us`/`%sy` are low, suspect **I/O wait (`%wa`)**.

```bash
uptime                    # ... load average: 2.15, 1.80, 1.50
nproc                     # cores to compare against
cat /proc/loadavg         # raw: 2.15 1.80 1.50 3/512 12345
# high load + low CPU? check I/O wait & D-state processes:
top                       # look at %wa
ps -eo state,pid,cmd | grep '^D'   # tasks stuck in uninterruptible I/O
```

---

## Q13. Explain Linux memory, swap, and the OOM killer.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Two facts that confuse people:
1. **"Free" memory being low is normal.** Linux uses spare RAM as **page cache** (buffers/cache) to speed up I/O; it's instantly reclaimable. So read the **`available`** column in `free -h`, **not** `free`. Available = what apps can still get.
2. **Swap** is disk used as overflow RAM. It prevents hard failures but is slow; heavy swapping = **thrashing** (system crawls). `vm.swappiness` tunes how eagerly the kernel swaps. In Kubernetes, swap was traditionally **disabled** on nodes (kubelet required it off; newer versions support swap modes).

**OOM killer:** when memory is truly exhausted and nothing's reclaimable, the kernel's **Out-Of-Memory killer** picks a process (by an `oom_score` heuristic — big memory hogs score high) and **SIGKILLs** it to save the system. You'll see it in `dmesg`/journal ("Out of memory: Killed process..."). In K8s, exceeding a container's **memory limit** triggers a cgroup OOM-kill → pod shows `OOMKilled`, exit code **137** (128+9).

```bash
free -h                     # look at the 'available' column
cat /proc/meminfo           # detailed: MemAvailable, Cached, SwapFree...
dmesg -T | grep -i "out of memory"   # OOM-kill events
sysctl vm.swappiness        # 0–100; lower = avoid swap
cat /proc/<pid>/oom_score   # how likely a process is to be OOM-killed
# K8s: kubectl get pod x -o jsonpath='{.status.containerStatuses[0].lastState}'  -> OOMKilled / exit 137
```

---

## Q14. How do you troubleshoot disk space and inode exhaustion?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
"No space left on device" has **two** causes, and juniors miss the second:
1. **Blocks full** — actual bytes. Check `df -h`.
2. **Inodes full** — an **inode** is the metadata record for each file/dir; a filesystem has a fixed number. **Millions of tiny files** (session files, logs, mail spools) can exhaust inodes while `df -h` still shows free space. Check `df -i`.

Method: `df -h` and `df -i` to see which is full and on which mount → then `du` to find the heavy directory → find big or numerous files → clean/rotate. Gotcha: **deleting a file that a process still holds open does NOT free space** until the process closes it (or is restarted) — find these with `lsof | grep deleted`. Also set up **log rotation** (`logrotate`) so it doesn't recur.

```bash
df -h                       # block/space usage per mount
df -i                       # INODE usage per mount (the overlooked one)
du -xhd1 /var | sort -rh | head    # biggest subdirs of /var (one filesystem)
find /var/log -type f -size +100M  # large files
find /tmp -xdev -type f | wc -l    # count files (inode hogs)
lsof +L1                    # open-but-deleted files still holding space
```

---

## Q15. What are file descriptors and ulimits?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A **file descriptor (fd)** is a small integer the kernel gives a process to reference an open file, **socket**, or pipe. Everything is a "file" in Unix, so a busy server holds an fd per open connection. Standard ones: **0 = stdin, 1 = stdout, 2 = stderr.**

There's a **per-process limit** on open fds (`ulimit -n`, aka `RLIMIT_NOFILE`) and a system-wide cap (`fs.file-max`). High-connection services (web servers, proxies, databases) hit the per-process soft limit and fail with **"Too many open files"** — a classic production incident. Fix by raising the limit in `/etc/security/limits.conf`, the systemd unit (`LimitNOFILE=`), or the container runtime. **Soft limit** = current, raisable up to the **hard limit**.

```bash
ulimit -n                   # current soft limit on open fds
ulimit -Hn                  # hard ceiling
ls /proc/<pid>/fd | wc -l   # how many fds a process currently holds
lsof -p <pid> | wc -l       # same, via lsof
cat /proc/sys/fs/file-max   # system-wide maximum
# systemd service: add  LimitNOFILE=65536  under [Service]
```

---

## Q16. How do you troubleshoot "connection refused" / a port timing out? (telnet & port checks)
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Work the path **outward from the client** — decide *where* it breaks:

1. **DNS resolves?** `dig host` / `nslookup`. Wrong IP → DNS problem, stop here.
2. **Host reachable?** `ping` (may be ICMP-blocked — not conclusive), or better, test the port directly.
3. **Port open / listening?** `nc -zv host 443`, `telnet host 443`, or `curl -v telnet://host:443`. Interpreting the result is the whole skill:
   - **"Connection refused"** = you *reached* the host but **nothing is listening** on that port (or it's a fast-fail). Service is down/not bound.
   - **Timeout / hangs** = a **firewall / security group / network ACL** is silently dropping packets, or routing is broken. Refused = fast + app-level; timeout = slow + network/firewall.
4. **On the server:** is it actually listening, and on which interface? `ss -tulpn`. Bound to `127.0.0.1` instead of `0.0.0.0` is a common "works locally, refused remotely" bug.
5. **Firewall:** `iptables -L -n` / `nftables` / cloud security groups.

`telnet host port` is the classic quick probe: connects = port open; "Connection refused"/timeout tells you which failure mode. In K8s add: check `Service`, `Endpoints` (empty = no ready pods), and `NetworkPolicy`.

```bash
nc -zv db.internal 5432       # quick port test (z=scan, v=verbose)
telnet db.internal 5432       # classic: connects vs refused vs hangs
curl -v telnet://db.internal:5432   # if telnet isn't installed
timeout 5 bash -c '</dev/tcp/db.internal/5432' && echo open || echo closed  # no tools needed
ss -tulpn | grep 5432         # ON THE SERVER: is it listening? on which IP?
dig +short db.internal        # DNS sanity
```

---

## Q17. Explain Linux networking troubleshooting tools (ip, ss, tcpdump, dig).
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Know the modern tools (the old `ifconfig`/`netstat` are deprecated in favor of the `iproute2` suite):

- **`ip`** — interfaces, addresses, routes. `ip a` (addresses), `ip r` (routing table), `ip link`. Replaces `ifconfig`/`route`.
- **`ss`** — socket statistics: who's listening, established connections. `ss -tulpn` (**t**cp/**u**dp, **l**istening, **p**rocess, **n**umeric). Replaces `netstat`.
- **`dig`** — DNS queries. `dig +short name`, `dig name @8.8.8.8` to test a specific resolver, `dig +trace` to follow delegation.
- **`tcpdump`** — packet capture to *see* what's actually on the wire when higher-level tools lie. `tcpdump -i any port 443`. Save with `-w file.pcap`, open in Wireshark.
- **`curl -v` / `traceroute` / `mtr`** — HTTP-level debugging and path/latency.

Mental model: `ip` (config) → `ss` (sockets) → `dig` (name resolution) → `tcpdump` (ground truth on the wire).

```bash
ip a                          # interfaces & IP addresses
ip r get 10.0.0.5             # which route/interface reaches an IP
ss -tulpn                     # listening sockets + owning process
ss -tn state established      # active connections
dig +short api.example.com    # resolve a name
tcpdump -ni any host 10.0.0.5 and port 443   # capture matching packets
mtr example.com               # continuous traceroute + loss/latency
```

---

## Q18. How does DNS resolution work on Linux (resolv.conf, nsswitch, ndots)?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Order of resolution is set by **`/etc/nsswitch.conf`** (`hosts:` line) — typically **files then dns**, so **`/etc/hosts`** is checked before querying DNS. DNS servers and search domains come from **`/etc/resolv.conf`**:
- **`nameserver`** — resolver IP(s), tried in order.
- **`search`** — domains to append to short (unqualified) names.
- **`options ndots:N`** — if a name has **fewer than N dots**, the resolver **appends the search domains first** before trying it as-is (absolute).

**Why this matters in Kubernetes (classic gotcha):** the injected `resolv.conf` uses **`ndots:5`**. So a lookup of an external name like `api.github.com` (2 dots, < 5) first tries it *with each search domain appended* (`api.github.com.svc.cluster.local`, etc.) — several failing queries — **before** the real one. This causes latency and CoreDNS load. Fixes: use a trailing dot (`api.github.com.` = fully qualified, skips search), or tune `dnsConfig` `ndots`. This is a favorite SRE interview topic.

```bash
cat /etc/resolv.conf          # nameserver / search / options ndots:N
cat /etc/nsswitch.conf | grep hosts   # resolution order (files dns ...)
getent hosts api.example.com  # resolve THROUGH nsswitch (honors /etc/hosts)
dig +search api               # emulate search-domain appending
dig api.github.com.           # trailing dot = FQDN, bypass search/ndots
resolvectl status             # (systemd-resolved) effective DNS config
```

---

## Q19. Explain special permissions: SUID, SGID, and the sticky bit.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Beyond the 9 `rwx` bits there are 3 **special bits** (a leading 4th octal digit):

- **SUID (4)** — on an executable, it runs with the **owner's** privileges, not the caller's. Classic example: **`passwd`** is owned by root and SUID, so a normal user can update `/etc/shadow` through it. Shows as `s` in the owner-execute slot (`-rwsr-xr-x`). Security-sensitive — audit SUID-root binaries.
- **SGID (2)** — on an executable, runs with the **group's** privileges. On a **directory**, new files inherit the directory's **group** (great for shared team folders).
- **Sticky bit (1)** — on a directory, only the **file's owner** (or root) can delete/rename files in it, even if others have write. That's why **`/tmp`** (`drwxrwxrwt`) is world-writable yet users can't delete each other's files. Shows as `t`.

```bash
chmod u+s /path/bin       # set SUID   -> -rwsr-xr-x
chmod g+s /shared/dir     # set SGID on dir -> new files inherit group
chmod +t /shared/upload   # sticky bit  -> drwxrwxrwt
chmod 4755 file           # numeric: leading 4 = SUID
ls -l /usr/bin/passwd     # -rwsr-xr-x root ... (SUID root)
find / -perm -4000 -type f 2>/dev/null   # audit all SUID binaries
```

---

## Q20. Difference between a symbolic link and a hard link.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Both create a second name for data, but at different layers:

- **Hard link** — a second **directory entry pointing to the same inode** (same actual data). The file's link count increments; all names are equal "first-class" references. Data is freed only when the **link count hits 0**. Limits: **can't cross filesystems** and **can't link directories**. Delete the original name → data survives via the other link.
- **Symbolic (soft) link** — a **separate small file whose contents are a path** to the target. It's like a shortcut. Can **cross filesystems** and **link directories**. If the target is deleted/moved, the symlink **dangles** (broken).

Key mental hooks: hard link = "same inode, another label"; symlink = "a signpost to a path." `ls -li` shows inode numbers — two hard links share one inode; a symlink has its own and shows `-> target`.

```bash
ln target.txt hardlink.txt        # hard link (same inode)
ln -s /path/to/target softlink    # symbolic link (points to a path)
ls -li target.txt hardlink.txt    # SAME inode number, link count 2
ls -l softlink                    # softlink -> /path/to/target
readlink -f softlink              # resolve where a symlink ultimately points
stat target.txt                   # 'Links:' shows the hard-link count
```

---

## Q21. Compare Linux package managers (apt/dpkg, yum/dnf/rpm).
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Two families, each with a **low-level** tool (single package, no dependency resolution) and a **high-level** tool (repos + dependency resolution):

- **Debian/Ubuntu:** low-level **`dpkg`** (installs a local `.deb`), high-level **`apt`** (fetches from repos, resolves deps). Repos in `/etc/apt/sources.list*`.
- **RHEL/CentOS/Fedora:** low-level **`rpm`** (local `.rpm`), high-level **`yum`** → now **`dnf`**. Repos in `/etc/yum.repos.d/`.

Rule of thumb: use the **high-level** tool (`apt`/`dnf`) day-to-day so dependencies are handled; drop to `dpkg`/`rpm` to inspect or force a single local file. For containers, prefer minimal base images and clean the package cache in the same layer to keep images small.

```bash
apt update && apt install nginx      # Debian/Ubuntu (resolves deps)
dpkg -i pkg.deb ; dpkg -l | grep nginx   # local .deb; list installed
apt-cache policy nginx               # versions & source repo
dnf install nginx                    # RHEL/Fedora (or: yum install)
rpm -qa | grep nginx ; rpm -qf $(which nginx)   # query installed / owner pkg
# slim container layer:
# RUN apt-get update && apt-get install -y --no-install-recommends nginx && rm -rf /var/lib/apt/lists/*
```

---

## Q22. How do cron jobs and systemd timers work?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**cron** runs commands on a schedule. Each user has a **crontab**; system jobs live in `/etc/crontab` and `/etc/cron.d/`. The five fields are **minute hour day-of-month month day-of-week**, then the command:

```
*  *  *  *  *   command
│  │  │  │  └─ day of week (0–7, 0/7=Sun)
│  │  │  └──── month (1–12)
│  │  └─────── day of month (1–31)
│  └────────── hour (0–23)
└───────────── minute (0–59)
```
`*/5 * * * *` = every 5 min. Gotchas: cron runs with a **minimal environment** (sparse `$PATH`, no profile) — use absolute paths; and **redirect output** or cron mails it. `@reboot` runs at boot.

**systemd timers** are the modern alternative (`.timer` + `.service` units): better logging (in the journal), dependencies, `OnCalendar=` syntax, randomized delays, and **catch-up for missed runs** (`Persistent=true`) if the machine was off. In Kubernetes, the equivalent is a **CronJob** (same 5-field syntax).

```bash
crontab -e                     # edit YOUR crontab
crontab -l                     # list it
# run every day at 02:30:
30 2 * * * /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
systemctl list-timers          # active systemd timers + next run
journalctl -u backup.service   # logs of a timer-driven job
```

---

## Q23. Explain the essential text-processing tools: grep, awk, sed, sort, uniq, cut.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
The pipeline toolkit — each does one thing, combined with `|`:

- **`grep`** — filter lines matching a pattern (regex). `-i` ignore case, `-v` invert, `-r` recursive, `-E` extended regex, `-c` count.
- **`awk`** — field-based processing; splits each line into `$1,$2,...`. Great for columns and math: `awk '{sum+=$3} END{print sum}'`.
- **`sed`** — stream editor; substitutions and line edits: `sed 's/old/new/g'`, `sed -n '10,20p'`.
- **`sort`** — order lines (`-n` numeric, `-r` reverse, `-k` by column, `-u` unique).
- **`uniq`** — collapse **adjacent** duplicates (so **sort first**); `-c` counts occurrences.
- **`cut`** — slice columns by delimiter: `cut -d: -f1 /etc/passwd`.

The canonical interview one-liner: **"top N most frequent values in a log column."**

```bash
# Top 10 client IPs hitting an access log:
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head -10

grep -i "error" app.log | wc -l          # count error lines
sed -i 's/DEBUG/INFO/g' config.ini       # in-place substitute
awk -F, '$3 > 100 {print $1, $3}' data.csv   # filter+select on a CSV
cut -d: -f1 /etc/passwd | sort           # all usernames, sorted
```

---

## Q24. Walk me through how you troubleshoot a slow/unresponsive server.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Give a **method**, top-down through the four resources — CPU, memory, disk I/O, network (this mirrors Brendan Gregg's **USE method**: for each resource check **U**tilization, **S**aturation, **E**rrors). A 60-second triage:

1. **Overview:** `uptime` (load vs `nproc`), `dmesg -T | tail` (OOM, disk/hardware errors), `w` (who/what).
2. **CPU:** `top`/`htop` — which process, and is it `%us` (app), `%sy` (kernel), or `%wa` (I/O wait)?
3. **Memory:** `free -h` (check **available**, not free), any swapping? OOM kills in `dmesg`?
4. **Disk I/O:** `iostat -xz 1` / `iotop` — high `%util` or await = disk bottleneck; and `df -h`/`df -i` for full disk/inodes.
5. **Network:** `ss -s` (socket summary), `ss -tn state established | wc -l` (connection count), retransmits, `dig` for DNS latency.
6. **Logs:** `journalctl -p err --since "30 min ago"`, app logs.

Then **correlate**: recent deploy? traffic spike? cron job? Narrow to the one saturated resource, prove it, fix, verify. Speaking a *repeatable framework* (not a random list of commands) is exactly what senior interviewers reward.

```bash
uptime; nproc                 # load vs cores
dmesg -T | tail -20           # kernel-level red flags (OOM, I/O errors)
top                           # CPU/mem hogs; watch %wa for I/O wait
free -h                       # memory 'available' + swap
iostat -xz 1 3                # per-disk utilization & latency
ss -s                         # socket/connection summary
journalctl -p err --since "30 min ago"   # recent errors across services
```

---

## Q25. What is the boot process and the difference between kill, pkill, pgrep, and killall?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**Boot process (high level):** firmware **BIOS/UEFI** → **bootloader (GRUB)** loads the **kernel** + initramfs → kernel mounts root FS and starts **PID 1 (systemd)** → systemd brings up the default **target** (services, network, login). Knowing this lets you reason about where boot hangs.

**Process-signalling tools** (all deliver signals — SIGTERM by default, `-9` for SIGKILL):
- **`kill <PID>`** — signal one process by **PID**.
- **`pgrep <name>`** — *find* PIDs by name/pattern (doesn't signal). `pgrep -f` matches the full command line.
- **`pkill <name>`** — signal processes by **name/pattern** (pgrep + kill).
- **`killall <name>`** — signal **all** processes with an **exact** name.

Use `pgrep` to look before you leap, then `pkill`/`kill`. `pkill -f` is handy when many processes share a binary but differ by arguments.

```bash
pgrep -a nginx               # list matching PIDs + command lines (no signal)
kill 1234                    # SIGTERM to one PID
pkill -f "python worker.py"  # signal by full command-line match
killall -9 chrome            # SIGKILL every process named exactly 'chrome'
pgrep -f app.jar | xargs -r kill   # combine: find then signal
systemctl list-units --type=target   # boot targets systemd reached
```

---
