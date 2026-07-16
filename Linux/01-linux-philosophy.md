# The Linux Philosophy — Everything is a File
*One abstraction to rule them all: how CPUs, processes, randomness, and container logs all become things you can `read()` and `write()`.*

---

## Rung 0 — 🎯 The Setup

**What you're learning:** Why Linux insists that almost *everything* — your disk, your terminal, a running process, the CPU's temperature, a network socket, a source of randomness — is presented to you as a **file**: an object you open, read from, write to, and close. And crucially, why this single design decision is the reason Kubernetes can exist at all.

**Why it landed on your desk (a realistic situation):** A pod is being OOM-killed and you want to know how much memory its main process actually uses. Someone on Slack says "just `cat /proc/<pid>/status`." You do it, and it works — but you have no idea *why* a process has a file, where that file lives on disk (spoiler: it doesn't), or how `metrics-server` and `cAdvisor` are reading the exact same "files" to draw the graphs in your dashboard. You realize the entire observability stack of Kubernetes is built on reading files that were never written to a disk. That gap is what this rung closes.

**What you already know (your leverage):** You're a Kubernetes platform engineer with ~6 years of DevOps. You already `kubectl exec` into pods, `kubectl logs` a container, and you've probably run `cat /proc/cpuinfo` once. You know files have paths and permissions. You know a process has a PID. You have *never* had to care that the kernel is the thing pretending all of this is a filesystem. That's the one mental muscle we build here.

---

## Rung 1 — 🔥 The Pain

**The problem that forced this to exist.** Imagine you're writing an operating system in 1969 (this is literally the Unix origin story). You have:

- Disks that store blocks of data.
- Terminals (teletypes) that stream characters.
- Printers that consume characters.
- Tape drives that spool.
- Later: network cards, mice, sound cards, GPUs, a clock, a random-number source.

The naive design gives each of these its **own** set of system calls. To read from a disk you call `read_disk()`. To read from a terminal, `read_tty()`. To talk to the network, `net_recv()`. Every new device means new syscalls, and every program that wants to work with a new device must be rewritten to know those syscalls.

**Why that hurt, concretely:**

- **No composability.** A program that counts lines (`wc -l`) would need a disk version, a terminal version, a tape version. You could not pipe the output of one program into another unless they happened to speak the same device dialect.
- **The tool explosion.** Every tool times every device = an unmaintainable matrix. Want `grep` to work on serial-port output? Rewrite `grep`.
- **Hardware knowledge leaks into every app.** Your text editor had to know the electrical details of a teletype. Add a new terminal model, patch every program.

**Who feels this pain most today?** *You*, the platform engineer, in a world where this pain had *not* been solved. Kubernetes' entire model — "collect logs from any container, measure any process's memory, stream any pod's stdout" — would require a bespoke integration per workload. Because Unix solved it, `kubelet` can treat a Postgres container's memory stat and an nginx container's memory stat *identically*: both are just a file at `/proc/<pid>/status`. Without "everything is a file," there is no generic `cAdvisor`, no generic `kubectl logs`, no generic `metrics-server`. Each would need per-application plumbing.

> **Check yourself before Rung 2:** If a program can only read from disks via a special `read_disk()` call, explain *why* you could not build a generic `kubectl logs` that works for any container. What specifically breaks?

---

## Rung 2 — 💡 The One Idea

Here is the sentence. Memorize it word for word:

> **In Linux, nearly every resource is exposed through the filesystem interface, so the same four operations — `open`, `read`, `write`, `close` — work on all of them.**

That's it. Everything else in this document is *derived* from that sentence. Watch:

- *"Nearly every resource"* → so a **CPU's info** is a file (`/proc/cpuinfo`), a **process** is a directory (`/proc/<pid>/`), a **disk** is a file (`/dev/sda`), **randomness** is a file (`/dev/urandom`), a **terminal** is a file (`/dev/pts/0`), a **network connection** is a file (a socket), a **trash can** is a file (`/dev/null`).
- *"Through the filesystem interface"* → so they all have **paths** you can `ls`, and permissions you can `chmod`, and you navigate them with `cd` and `cat`.
- *"The same four operations work on all of them"* → so **one toolset** (`cat`, `grep`, `dd`, `head`, `>`) works on *all* of them. `cat` doesn't know if it's reading a disk file or the CPU's model name. It just calls `read()`.

Derivation drill — ask yourself "if everything is a file, then…":

- *…then a process must have a way to appear as a file.* → That's `/proc/<pid>/`.
- *…then hardware must appear as files.* → That's `/dev` and `/sys`.
- *…then a program's three standard streams must be files too.* → That's file descriptors **0, 1, 2** (stdin, stdout, stderr).
- *…then redirecting a container's log must just be pointing fd 1 at a different file.* → That's exactly what container runtimes do.

You just re-derived the rest of the guide from one sentence. That's the point of Rung 2.

> **Check yourself before Rung 3:** From the one core sentence alone, predict where in the filesystem you'd look to find the command-line that a running process was started with. You haven't been told the exact path — derive the *neighborhood*.

---

## Rung 3 — ⚙️ The Machinery (the important one — go slow)

The one idea is a promise. Now we open the hood and see *who keeps that promise*. The short answer: **the kernel**, through a layer called the **VFS — the Virtual File System**.

### 3.1 The core trick: a file is not a thing, it's an *interface*

When an app calls `read(fd, buf, count)`, it is **not** talking to a disk. It's talking to the kernel. The kernel looks at the file descriptor `fd`, finds the object behind it, and asks *that object*: "what does `read` mean for you?" Each kind of object supplies its own answer:

- A **regular file** on ext4: "read means fetch bytes from these disk blocks."
- A **`/proc/cpuinfo`** file: "read means *generate* a text description of the CPU *right now*." (Nothing is stored on disk — the kernel manufactures the bytes on demand.)
- **`/dev/urandom`**: "read means run the kernel's CSPRNG and hand back random bytes."
- **`/dev/null`**: "read means immediately return end-of-file; write means discard everything."
- A **pipe**: "read means block until the other end writes something."
- A **socket**: "read means pull bytes off the network receive buffer."

This is the whole magic: **`read` and `write` are polymorphic.** The VFS is the dispatcher. Every file type registers a table of function pointers (`read`, `write`, `open`, …) called `file_operations`, and the VFS calls whichever table belongs to the object you opened.

```
        The user/app NEVER sees below this line
   ─────────────────────────────────────────────────────
   App:   fd = open("/proc/1/status");  read(fd, buf, 4096)
                         │
                         ▼
   ┌─────────────────────────────────────────────────────┐
   │                   VFS  (the dispatcher)              │
   │   "which file_operations table backs this fd?"       │
   └───────┬─────────────┬──────────────┬────────────────-┘
           │             │              │
     ext4 driver    procfs driver   char-device driver
     (real disk)    (fabricates     (urandom, null,
      blocks)        text on read)   /dev/pts, /dev/sda…)
           │             │              │
     ┌─────▼───┐   ┌──────▼──────┐  ┌────▼─────────┐
     │ SSD/HDD │   │ live kernel │  │ CPU RNG, tty │
     │ blocks  │   │ data structs│  │ hardware     │
     └─────────┘   └─────────────┘  └──────────────┘
```

The app on top wrote **one** line of code (`read`). Underneath, three *completely different* mechanisms ran. That is "everything is a file" made physical.

### 3.2 The seven file *types* (what `ls -l` is telling you)

The very first character of an `ls -l` line names the file's type. This is the kernel telling you which `file_operations` table is behind the object:

| Char | Type | Example |
|------|------|---------|
| `-` | Regular file | `/etc/hosts` |
| `d` | Directory | `/home` |
| `c` | Character device (byte stream) | `/dev/urandom`, `/dev/null`, `/dev/pts/0` |
| `b` | Block device (addressable blocks) | `/dev/sda`, `/dev/nvme0n1` |
| `l` | Symbolic link | `/proc/1/exe` |
| `p` | Named pipe (FIFO) | created by `mkfifo` |
| `s` | Socket | `/run/containerd/containerd.sock` |

You already talk to that last one constantly: `kubelet` reaches `containerd` through the **socket file** `/run/containerd/containerd.sock`. It's a file. You can `ls -l` it.

### 3.3 File descriptors: the app's private handle

When your process opens something, the kernel doesn't hand back the file — it hands back a small integer, the **file descriptor (fd)**, an index into *your process's* private table of open files. Three are opened for you before your program even starts:

```
  fd 0  ──►  stdin   (where the program reads input)
  fd 1  ──►  stdout  (where normal output goes)
  fd 2  ──►  stderr  (where error output goes)
```

Each entry in your fd table points at an "open file description" in the kernel, which points at the actual object (the inode, the device, the pipe). This indirection is the entire basis of **redirection**: `command > file.log` means "before running, replace whatever fd 1 points at with this file." The program is oblivious — it still just `write()`s to fd 1.

**This is the mechanism behind container logs.** When containerd starts your container's process, it sets that process's **fd 1 and fd 2** to point at a log file (something under `/var/log/pods/...` or `/var/lib/docker/containers/...`). The application inside thinks it's printing to the console. The kernel is quietly steering those bytes into a file that `kubectl logs` later reads. You can *see* this redirection from outside:

```
  /proc/<pid>/fd/0 ──► symlink to the process's stdin
  /proc/<pid>/fd/1 ──► symlink to its stdout  (the log file!)
  /proc/<pid>/fd/2 ──► symlink to its stderr
```

### 3.4 The three virtual filesystems you must know

None of these live on a disk. The kernel synthesizes them in RAM, on demand.

- **`/proc` (procfs)** — a live window into the **kernel and every process**. `/proc/cpuinfo`, `/proc/meminfo` describe the machine. `/proc/<pid>/` is a directory *per running process*: its `cmdline`, `status`, `fd/`, and critically `cgroup`. When you read `/proc/1/status`, procfs walks the live kernel task structure and *formats it as text right then*.
- **`/sys` (sysfs)** — a structured view of the **device and driver model**: buses, devices, kernel tunables. This is where cgroup v2 lives (`/sys/fs/cgroup/...`), where you'd read a NIC's state, a disk's queue settings, or a battery's charge.
- **`/dev` (devtmpfs)** — the **device nodes**: `/dev/sda` (your disk), `/dev/null` (the void), `/dev/zero` (infinite zeros), `/dev/urandom` (randomness), `/dev/pts/N` (pseudo-terminals for interactive sessions).

**Kubernetes leans on all three, hard:**

- `kubelet` and `cAdvisor` read **`/proc/<pid>/cgroup`** to map a process to its pod, and read cgroup files under **`/sys/fs/cgroup/kubepods...`** to get CPU/memory usage. That's how your Grafana memory graph exists.
- `kubectl exec -it` allocates a **pseudo-terminal** under **`/dev/pts`** so your keystrokes and the shell's output flow like a real TTY.
- A Secret's random token, or TLS key material, is seeded from **`/dev/urandom`**.
- Container **logs** are the container process's **fd 1/2** (`/proc/1/fd/1`) redirected to a file.

Everything Kubernetes "observes" about your workloads, it observes by opening files the kernel invented.

> **Check yourself before Rung 4:** `/proc/meminfo` takes up no disk space, yet `cat` returns kilobytes of text every time and the numbers change between reads. Using the machinery above, explain *when* those bytes are created and by *what*.

---

## Rung 4 — 🏷️ The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|------|--------------------|-----------------------------|
| **File** | An object you can `open/read/write/close` — not necessarily bytes on disk | The universal abstraction; the whole idea |
| **VFS (Virtual File System)** | Kernel layer that dispatches `read`/`write` to the right driver | The polymorphic dispatcher in 3.1 |
| **inode** | On-disk metadata record for a real file (owner, perms, block pointers) | What ext4 objects resolve to; virtual FS often fake these |
| **File descriptor (fd)** | Small integer = index into your process's open-file table | Redirection, container logs, `/proc/<pid>/fd` |
| **stdin / stdout / stderr** | The three pre-opened fds: 0, 1, 2 | Redirection; container log capture |
| **Regular file (`-`)** | Bytes actually stored in a filesystem | ext4/xfs driver |
| **Directory (`d`)** | A file whose contents are name→inode mappings | Any filesystem |
| **Character device (`c`)** | Byte-stream hardware node (no seek by block) | `/dev/urandom`, `/dev/null`, `/dev/pts` |
| **Block device (`b`)** | Block-addressable storage node | `/dev/sda`, `/dev/nvme0n1` |
| **Symlink (`l`)** | A file whose content is another path | `/proc/<pid>/fd/1` → the log file |
| **Named pipe / FIFO (`p`)** | A file that connects one writer to one reader | Pipe machinery, `mkfifo` |
| **Socket (`s`)** | An endpoint for communication (network or local) | `containerd.sock`, kube API traffic |
| **procfs (`/proc`)** | Virtual FS exposing kernel + per-process state as text | 3.4; kubelet resource reads |
| **sysfs (`/sys`)** | Virtual FS exposing the device/driver model + tunables | cgroup v2 lives here |
| **devtmpfs (`/dev`)** | Virtual FS of device nodes | urandom, null, zero, pts, disks |
| **pseudo-terminal (pty)** | A software TTY pair; the interactive-session device | `/dev/pts`, `kubectl exec -it` |
| **`file_operations`** | Kernel struct of function pointers (`read`, `write`…) per file type | The table the VFS dispatches through |

**Same thing wearing different names — group them so they stop scaring you:**

- **"Virtual filesystems"** = `/proc` (procfs) + `/sys` (sysfs) + `/dev` (devtmpfs). All three are *kernel-fabricated, RAM-backed, zero disk bytes*. Same species.
- **"Device nodes"** = character devices (`c`) + block devices (`b`). Both live in `/dev`; both are just files whose driver is a piece of hardware (or a fake one like `/dev/null`).
- **"The standard streams"** = stdin/stdout/stderr = fd 0/1/2. Three names for three integers indexing one table.
- **"IPC files"** = pipes (`p`) + sockets (`s`). Both are files whose "content" is *a flow of bytes between processes*, not stored data.

> **Check yourself before Rung 5:** Without scrolling up, sort these into "kernel-fabricated, zero disk bytes" vs. "real bytes on a filesystem": `/proc/meminfo`, an ext4 **inode**, `/sys/fs/cgroup/...`, `/dev/null`, `/etc/hosts`. Which term in the table is the odd one out, and why?

---

## Rung 5 — 🔬 The Trace

Let's follow **one** concrete action all the way down: you run `cat /proc/self/status` and it prints `VmRSS: 4321 kB`. Where did that number come from? Nothing was on disk.

1. **Shell forks & execs `cat`.** The new `cat` process inherits fd 0/1/2 (its stdout, fd 1, is your terminal — a `/dev/pts/N` pty).
2. **`cat` calls `open("/proc/self/status", O_RDONLY)`.** The syscall traps into the kernel and hits the **VFS**.
3. **VFS resolves the path.** It walks `/proc` and finds this mount is backed by **procfs**. `self` is a magic symlink procfs resolves to the caller's own PID directory. VFS returns an fd whose `file_operations` table is *procfs's*, not ext4's.
4. **`cat` calls `read(fd, buf, 131072)`.** VFS dispatches to **procfs's `read` handler**.
5. **procfs manufactures the bytes now.** It reaches into the live kernel `task_struct` for that process, reads the current memory accounting (RSS from the `mm_struct`), and *formats it as ASCII text* into the buffer — `VmRSS:\t4321 kB\n`. These bytes did not exist one microsecond ago.
6. **`cat` calls `write(1, buf, n)`.** VFS sees fd 1 is a **pty** (`/dev/pts`), dispatches to the tty driver, which pushes characters to your terminal emulator.
7. **`cat` calls `close(fd)`** and exits. The fabricated text is gone; next read would regenerate it fresh.

```
  cat ──open("/proc/self/status")──► [VFS] ──► procfs
                                                  │ read()
                                                  ▼
                                       reads live task_struct,
                                       formats "VmRSS: 4321 kB"
                                                  │
  cat ◄────────── bytes ─────────────────────────┘
   │ write(fd 1)
   ▼
  [VFS] ──► pty driver (/dev/pts/0) ──► your terminal
```

Now swap `cat` for **`kubelet`** and the path for `/proc/<container-pid>/cgroup`, and you have literally described how Kubernetes learns which pod a process belongs to. Same trace, same VFS, same procfs — different reader.

> **Check yourself before Rung 6:** Step 5 said the bytes "did not exist one microsecond ago." If two processes both `cat /proc/self/status` at the very same instant, do they read identical bytes? Using the trace, explain which step decides the answer.

---

## Rung 6 — ⚖️ The Contrast

**The alternative approach: per-device APIs (and, on other OSes, a partial retreat from the idea).**

Before Unix, and in some other designs, each resource had bespoke access calls. Even Windows — which *has* a unified handle model — historically exposed a lot through specialized APIs (the Registry for config, WMI/Performance Counters for process metrics) rather than a single filesystem you can `cat`. To read a Windows process's working set you call a metrics API; to read a Linux process's, you `cat /proc/<pid>/status`.

| | "Everything is a file" (Linux) | Per-resource APIs (the alternative) |
|---|---|---|
| Tooling | One set (`cat`, `grep`, `dd`, `>`) works everywhere | New tool/library per resource type |
| Composability | Pipe anything into anything | Only where APIs happen to align |
| Discoverability | `ls` and `cd` explore hardware & processes | Must know each API up front |
| Permissions | Unified rwx + ownership on the node | Per-API security models |
| Precision / typing | Bytes are untyped; text parsing is fiddly | Strongly typed, structured returns |
| Performance ceiling | Text formatting has overhead | Binary APIs can be leaner/faster |
| Atomicity | Reading `/proc` gives a slightly racy snapshot | APIs can offer transactional reads |

**What "everything is a file" can do that the alternative cannot:** let a shell one-liner (`cat /proc/<pid>/cgroup`) inspect a container's resource group with zero libraries — which is exactly why debugging a K8s node from a plain shell is so powerful.

**What the alternative can do better:** return richly typed, structured, atomic data. That's why high-frequency, structured metrics increasingly use **eBPF** and dedicated interfaces instead of parsing `/proc` text in a hot loop — parsing `/proc/<pid>/stat` for thousands of processes per second is wasteful.

**When would you NOT rely on this?** When you need microsecond-latency, structured, race-free telemetry at scale — reach for eBPF or netlink, not `cat` in a loop. When you need cross-node config, that's etcd, not a file.

**Why this over that (one sentence):** For a human or a shell script triaging a Linux node, "everything is a file" turns the entire machine into something you can explore and read with tools you already know — and that generality is worth the text-parsing tax.

> **Check yourself before Rung 7:** cAdvisor could read cgroup stats either by parsing files under `/sys/fs/cgroup` or via a hypothetical typed kernel API. Give one concrete reason each approach might win. (Hint: think generality vs. per-read cost at scale.)

---

## Rung 7 — 🧪 The Prediction Test

Commit to the prediction **before** you run the command. The value is in being wrong and learning why. Everything here is safe and runnable on Ubuntu 22.04 (systemd, cgroup v2).

### Prediction 1 (normal case): a hardware file materializes on read

**I predict:** `cat /proc/cpuinfo` and `cat /proc/meminfo` will print detailed, up-to-date text about my CPU and memory, even though `ls -l` shows the files as **0 bytes** — BECAUSE procfs *fabricates* the content at read time; nothing is stored on disk.

```bash
ls -l /proc/cpuinfo /proc/meminfo
# -r--r--r-- 1 root root 0 Jul 16 10:00 /proc/cpuinfo   <- 0 bytes!
# -r--r--r-- 1 root root 0 Jul 16 10:00 /proc/meminfo

cat /proc/cpuinfo | grep 'model name' | head -1
# model name : Intel(R) Xeon(R) CPU @ 2.20GHz

cat /proc/meminfo | head -3
# MemTotal:       16340512 kB
# MemFree:         8231044 kB
# MemAvailable:   12004884 kB
```

**Verify:** The reported size is `0` but `cat` returns real text — proof the bytes are generated on demand. Run `cat /proc/meminfo | grep MemFree` twice a few seconds apart; the number changes. A wrong result (e.g. a nonzero size, or identical bytes forever) would tell you you're looking at a real disk file, not a virtual one.

### Prediction 2 (process introspection): a process is a directory of files

**I predict:** My own shell has a PID I can get from `$$`, and under `/proc/$$/` I'll find `cmdline` (how it was launched), `status` (its live memory), and `fd/` (its open files, including stdin/stdout/stderr as symlinks) — BECAUSE each process is exposed as a procfs directory.

```bash
echo $$
# 4127                      <- your shell's PID ($$ = current shell PID)

cat /proc/$$/cmdline | tr '\0' ' '; echo
# -bash                     <- args are NUL-separated; tr makes them readable

cat /proc/$$/status | grep VmRSS
# VmRSS:    5124 kB         <- resident memory of THIS shell, live

ls -l /proc/$$/fd
# lrwx------ 1 you you 64 Jul 16 10:00 0 -> /dev/pts/0   <- stdin  = your terminal
# lrwx------ 1 you you 64 Jul 16 10:00 1 -> /dev/pts/0   <- stdout = your terminal
# lrwx------ 1 you you 64 Jul 16 10:00 2 -> /dev/pts/0   <- stderr = your terminal
```

**Verify:** All three of fd 0/1/2 point at the same `/dev/pts/N` — that's your interactive terminal, and it's the exact mechanism `kubectl exec -it` uses. Now redirect and watch fd 1 change: run `sleep 300 > /tmp/out.log &`, then `ls -l /proc/<that-pid>/fd/1` and you'll see it point at `/tmp/out.log` instead of a pty. That is *container logging in miniature* — fd 1 aimed at a file. A wrong result (fd 1 still a pty) would mean the redirection didn't take.

### Prediction 3 (device files: the void and the firehose)

**I predict:** `/dev/null` swallows anything I write and gives nothing back; `/dev/zero` is an endless source of zero bytes; `/dev/urandom` is an endless source of random bytes — BECAUSE these are character devices whose driver *defines* what read/write mean, with no storage behind them.

```bash
echo "this disappears forever" > /dev/null   # write to the void; no error, no trace

dd if=/dev/zero of=/tmp/blob bs=1M count=10 status=progress
# 10+0 records in / 10+0 records out
# 10485760 bytes (10 MB) copied      <- 10 MB of zeros conjured from /dev/zero
ls -l /tmp/blob    # -rw-r--r-- ... 10485760   (exactly 10 MiB)

head -c 16 /dev/urandom | base64
# 3kF9pQ2xVpL8sYbNzQ7mKw==         <- 16 random bytes -> 24 base64 chars
```

**Verify:** `/dev/null` produces no output and no error — the write was accepted and discarded (this is why `command 2>/dev/null` hides errors). The `dd` blob is *exactly* 10 MiB of zeros. Each `head -c 16 /dev/urandom | base64` gives different output every time — this is the same entropy source that seeds Kubernetes Secret tokens and TLS keys. A wrong result (e.g. `/dev/urandom` repeating) would mean something is deeply broken with your kernel RNG.

### Prediction 4 (Kubernetes-flavored: read a container's cgroup and log fd)

**I predict:** For a running container's main process (PID 1 *inside* the container, or its host PID), `/proc/<pid>/cgroup` will name a `kubepods` cgroup path, and `/proc/<pid>/fd/1` will be a symlink to the **log file** — BECAUSE kubelet places the process in a pod cgroup and the runtime redirects its stdout to a file. This is precisely what cAdvisor/metrics-server read.

```bash
# On a K8s node. Find a container process (nginx here); pick its host PID.
pgrep -f nginx | head -1
# 20344

cat /proc/20344/cgroup
# 0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod<uid>.slice/cri-containerd-<id>.scope
#   ^ cgroup v2 shows a single "0::" line; the path ties this PID to its pod

sudo ls -l /proc/20344/fd/1 /proc/20344/fd/2
# l-wx------ 1 root root 64 ... 1 -> /var/log/pods/default_nginx.../nginx/0.log
# l-wx------ 1 root root 64 ... 2 -> /var/log/pods/default_nginx.../nginx/0.log
#   ^ stdout & stderr of the container ARE a log file -> this is `kubectl logs`
```

**Verify:** The `cgroup` line contains `kubepods` and a pod UID — that string is how kubelet maps this PID to a Kubernetes pod. fd 1/2 point at a file under `/var/log/pods/...`; `tail -f` that file and you'll see the same lines `kubectl logs` shows. On **cgroup v1** you'd instead see many numbered lines (`12:memory:/kubepods/...`, one per controller) rather than a single `0::` line — note the version difference. A wrong result (fd 1 pointing at a pty, or no `kubepods` in cgroup) would tell you the process isn't a Kubernetes-managed container.

---

## Capstone — 🏔 Compress It

**One sentence (no notes):** In Linux almost every resource — files, disks, devices, processes, randomness, network endpoints — is exposed through the filesystem so one set of operations (`open/read/write/close`) and one toolset (`cat`, `grep`, `>`) works on all of them.

**Three-sentence beginner explanation:** Linux pretends that hardware and running programs are just files with paths you can read. That means to inspect your CPU you `cat /proc/cpuinfo`, and to inspect a process's memory you `cat /proc/<pid>/status` — no special program needed. Kubernetes is built directly on this: kubelet, cAdvisor, and `kubectl logs` all work by reading kernel-invented files under `/proc`, `/sys`, and `/dev`.

**Sub-capability → the one idea:**

| Sub-capability | Derives from the one idea because… |
|---|---|
| `/proc/cpuinfo`, `/proc/meminfo` | hardware/kernel state is exposed *as a file* |
| `/proc/<pid>/{cmdline,status,fd}` | a process is exposed *as a directory of files* |
| stdin/stdout/stderr = fd 0/1/2 | a program's streams are *files* it read/writes |
| container logs (`/proc/1/fd/1`) | fd 1 is a file, so redirect it to a log *file* |
| `/dev/null`, `/dev/zero`, `/dev/urandom` | devices are *files* whose driver defines read/write |
| `kubectl exec -it` via `/dev/pts` | a terminal is a *file* (a pty device) |
| cgroup stats under `/sys/fs/cgroup` | kernel tunables/accounting are exposed *as files* |

**Which rung to revisit hands-on:** **Rung 7, Predictions 2 and 4.** Getting `$$`, walking `/proc/$$/fd`, then doing the same on a real container's PID to see cgroup + log-file redirection is the single exercise that fuses "everything is a file" with what Kubernetes actually does. If only one thing sticks, make it that.

---

## Related concepts

- [Shell and environment](02-shell-and-environment.md) — how `$$`, redirection, and `>` (which target file descriptors) actually behave.
- [I/O redirection and pipes](10-io-redirection-pipes.md) — fd 0/1/2, `>`, `2>`, pipes and FIFOs in depth.
- [Processes and job control](07-processes-job-control.md) — the process side of `/proc/<pid>/`, PIDs, and signals.
- [cgroups](14-cgroups.md) — the `/sys/fs/cgroup` files kubelet and cAdvisor read for CPU/memory.
- [Storage and mounts](15-storage-mounts.md) — block devices under `/dev`, tmpfs, and how virtual filesystems get mounted.
- [The Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — the full mapping of these primitives to what kubelet/containerd/etcd do.
