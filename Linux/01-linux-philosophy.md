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

> ### 🧸 Plain-English first (read this before the technical version)
>
> **The big idea in one line:** when a program "reads a file," it never touches the disk itself. It hands a request to the kernel (the operating system's always-on manager), and the kernel decides what "read" should mean for that particular thing.
>
> **1. A file is a menu item, not a thing.** Picture the kernel as a restaurant with one head waiter, called the VFS ("Virtual File System" — the request dispatcher). Every program orders from the same tiny menu: open, read, write, close. But the kitchen station behind the waiter changes depending on what was ordered:
>
> - A normal saved file → the waiter fetches bytes from the pantry (the disk).
> - A status file like the CPU-info page → the kitchen cooks the answer fresh, on the spot; nothing was ever stored anywhere.
> - The randomness tap → the kitchen invents random numbers for you right then.
> - The trash chute (`/dev/null`) → anything you send is silently discarded; asking for food gets you an empty plate.
> - A pipe or a socket → really a phone line to another program; "reading" means waiting and listening.
>
> The program says one word — "read" — and the waiter routes it to whichever station signed up to handle that kind of item. That's the whole magic trick behind "everything is a file."
>
> **2. The seven badges.** The first letter of each line in a detailed file listing is a badge on the door saying which station is behind it: ordinary file, folder, two kinds of hardware doors, shortcut, pipe, or socket (a plug other programs connect to).
>
> **3. Coat-check tickets.** When a program opens something, the kernel keeps the item and hands back a small numbered ticket (a "file descriptor"). Every program starts life with three tickets pre-issued: #0 for input, #1 for normal output, #2 for error messages. "Redirection" is the trick of quietly swapping what ticket #1 points at — the program keeps writing to ticket #1, never noticing its words now land in a log file instead of the screen. That is exactly how container logs get captured for `kubectl logs`.
>
> **4. Three invented filing cabinets.** The folders `/proc`, `/sys`, and `/dev` take up zero disk space — the kernel fabricates their contents in memory the moment you look: `/proc` is a live status report on every running program, `/sys` is the catalog of the machine's hardware and settings, `/dev` holds the doors to devices. Everything Kubernetes "observes" about your workloads, it observes by reading these invented files.

*Now the original technical deep-dive — the same ideas, in precise form:*

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

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** If a program can only read from disks via a special `read_disk()` call, why could you not build a generic `kubectl logs` that works for any container? What specifically breaks?

**A:** Composability breaks. If each resource type has its own bespoke syscall (`read_disk()`, `read_tty()`, `net_recv()`...), then the log reader must know *in advance* which kind of resource every container's output lives on, and must be rewritten with new code for each one — a disk-backed log needs `read_disk()`, a terminal stream needs `read_tty()`, a network stream needs `net_recv()`. There is no single operation the tool can call that works regardless of the source, so "collect logs from any container" becomes a bespoke integration per workload — the tool-explosion matrix from Rung 1. Because Linux instead exposes everything through one interface, `kubectl logs` can just `read()` a file at a known path and never care what's behind it.

### Before Rung 3
**Q:** From the core sentence alone, predict where in the filesystem you'd find the command-line a running process was started with.

**A:** The core sentence says *nearly every resource is exposed through the filesystem interface* — and a running process is a resource, so it must appear somewhere in the filesystem as a file (or directory of files). The neighborhood is therefore the per-process directory the kernel synthesizes for each PID: `/proc/<pid>/`. Its startup command line specifically lives at `/proc/<pid>/cmdline` (with NUL-separated arguments), but the derivable part is that it must be a readable file under that process's `/proc` directory.

### Before Rung 4
**Q:** `/proc/meminfo` takes up no disk space, yet `cat` returns kilobytes of text that change between reads. When are those bytes created, and by what?

**A:** The bytes are created *at read time*, by the kernel's procfs driver. When `cat` calls `read()`, the VFS looks at the fd, sees it is backed by procfs's `file_operations` table, and dispatches to procfs's `read` handler. That handler reaches into the live kernel data structures holding current memory accounting and *formats them as ASCII text right then*, directly into the read buffer. Nothing is ever stored on disk — which is why `ls -l` reports 0 bytes, and why the numbers differ on every read: each `read()` regenerates the text fresh from the kernel's live state.

### Before Rung 5
**Q:** Sort into "kernel-fabricated, zero disk bytes" vs. "real bytes on a filesystem": `/proc/meminfo`, an ext4 inode, `/sys/fs/cgroup/...`, `/dev/null`, `/etc/hosts`. Which term in the table is the odd one out, and why?

**A:** Kernel-fabricated, zero disk bytes: `/proc/meminfo` (procfs generates the text on read), `/sys/fs/cgroup/...` (sysfs, the RAM-backed device/cgroup view), and `/dev/null` (a character device whose driver defines read/write, with no storage behind it). Real bytes on a filesystem: `/etc/hosts` (a regular ext4 file) and an ext4 inode (the on-disk metadata record for a real file). The odd one out is the **inode**: every other entry is a file *you can open and read through the VFS*, while an inode is not an openable object at all — it's the on-disk metadata structure (owner, permissions, block pointers) that a real file resolves to, which is also why virtual filesystems only fake theirs.

### Before Rung 6
**Q:** If two processes both `cat /proc/self/status` at the very same instant, do they read identical bytes? Which trace step decides the answer?

**A:** No — they read different bytes. Step 3 of the trace decides it: during path resolution, `self` is a *magic symlink* that procfs resolves to *the calling process's own* PID directory. So each `cat` gets an fd pointing at its own `/proc/<its-pid>/status`, and in step 5 procfs walks *that* process's live `task_struct` and formats its private memory accounting (its own VmRSS, its own PID) into text. Same path string, two different underlying objects, two different fabricated outputs — the bytes are generated per-reader, per-read.

### Before Rung 7
**Q:** cAdvisor could read cgroup stats by parsing files under `/sys/fs/cgroup` or via a hypothetical typed kernel API. Give one concrete reason each approach might win.

**A:** The file approach wins on **generality and discoverability**: cgroup stats are just files, so cAdvisor needs zero special libraries, the same code path works for every controller and every workload, and any human can verify what cAdvisor sees with a plain `cat /sys/fs/cgroup/.../memory.current` while debugging a node. The typed-API approach wins on **per-read cost at scale**: the file interface forces the kernel to format numbers as text and the reader to parse that text back, which is wasteful and slightly racy when polling thousands of cgroups per second — a binary, structured, atomic interface (the reason high-frequency telemetry moves to eBPF/netlink) skips the text-formatting tax entirely.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Saint John: what is writing to this log file?" (Easy)
**Setup:**
```bash
mkdir -p /tmp/lab-sj
cat > /tmp/lab-sj/writer.sh <<'EOF'
#!/bin/bash
exec 3>>/tmp/lab-sj/app.log
while true; do echo "$(date '+%F %T') payment-batch tick" >&3; sleep 1; done
EOF
chmod +x /tmp/lab-sj/writer.sh
nohup /tmp/lab-sj/writer.sh >/dev/null 2>&1 &
```
**Situation:** A log file at `/tmp/lab-sj/app.log` on a build box keeps growing, one line per second, and nobody on the team admits to owning the job that writes it. `lsof` and `fuser` are not installed on this minimal image, and the writer's command line contains no mention of the log file, so `pgrep -f app.log` comes back empty.

**Your task:** Using only `/proc`, find the PID of the process that holds `/tmp/lab-sj/app.log` open for writing, and terminate it.

**Verify:**
```bash
a=$(wc -c < /tmp/lab-sj/app.log); sleep 3; b=$(wc -c < /tmp/lab-sj/app.log); [ "$a" -eq "$b" ] && echo SOLVED   # expected: SOLVED (the file has stopped growing)
```

### 🟢 Scenario 2 — "Halifax: the process that lied about its name" (Easy)
**Setup:**
```bash
nohup bash -c 'exec -a lab-innocentd sleep 86400' >/dev/null 2>&1 &
```
**Situation:** During a routine audit, `ps aux` shows a process called `lab-innocentd 86400` running on a shared VM. Nobody installed anything called `lab-innocentd`, there is no such binary anywhere on the `PATH`, and security wants to know what is *actually* executing before anyone touches it.

**Your task:** Find the real on-disk executable behind the process whose command line starts with `lab-innocentd`, and write its absolute path into `/tmp/lab-hfx-answer.txt`.

**Verify:**
```bash
grep -Eq '^/(usr/)?bin/sleep$' /tmp/lab-hfx-answer.txt && echo SOLVED   # expected: SOLVED (the "malware" is just /usr/bin/sleep wearing a fake argv[0])
```

### 🟡 Scenario 3 — "Winnipeg: the heartbeats vanish into the void" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-wpg
sudo tee /opt/lab-wpg/heartbeat.sh >/dev/null <<'EOF'
#!/bin/bash
while true; do echo "heartbeat $(date +%s)"; sleep 2; done
EOF
sudo chmod 755 /opt/lab-wpg/heartbeat.sh
nohup /opt/lab-wpg/heartbeat.sh >/dev/null 2>&1 &
echo $! > /tmp/lab-wpg.pid
```
**Situation:** A teammate deployed a "heartbeat agent" and swears it is running — and `ps` agrees. But the on-call dashboard shows zero heartbeats, and there is no log file anywhere. The agent prints one heartbeat line every 2 seconds to its stdout; the question is where that stdout actually *goes*.

**Your task:** Using `/proc/<pid>/fd`, prove where the agent's fd 1 currently points. Then fix the deployment so heartbeats accumulate in `/tmp/lab-wpg.log` (restart the agent with its stdout aimed at that file — exactly what a container runtime does for `kubectl logs`).

**Verify:**
```bash
c1=$(grep -c heartbeat /tmp/lab-wpg.log); sleep 5; c2=$(grep -c heartbeat /tmp/lab-wpg.log); [ "$c2" -gt "$c1" ] && echo SOLVED   # expected: SOLVED (heartbeat lines are landing in the log and increasing)
```

### 🟡 Scenario 4 — "Victoria: /dev/null is getting full" (Medium)
**Setup:**
```bash
sudo rm -f /dev/null
sudo touch /dev/null
sudo chmod 666 /dev/null
seq 5000 >> /dev/null
```
**Situation:** A nightly cleanup script that ends every command with `>/dev/null 2>&1` has started filling the root filesystem, and this morning `du` shows `/dev/null` itself is kilobytes in size — which should be impossible for the void. Someone clearly "recreated" it after an accidental delete, but got it subtly wrong.

**Your task:** Diagnose what `/dev/null` has become (check its file *type* — the first character of `ls -l`), then restore it as the proper character device so writes are discarded again.

**Verify:**
```bash
echo test > /dev/null; stat -c '%F %t:%T %a %s' /dev/null   # expected: "character special file 1:3 666 0" — a char device, major 1 minor 3, and still 0 bytes after a write
```

### 🟠 Scenario 5 — "Moncton: recover the token from a dying deploy" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-mct
sudo bash -c 'tr -dc a-f0-9 < /dev/urandom | head -c 32 > /opt/lab-mct/secret; echo >> /opt/lab-mct/secret; chmod 600 /opt/lab-mct/secret'
sudo bash -c 'DEPLOY_STAGE=canary nohup sleep 86400 >/dev/null 2>&1 &'
sudo bash -c 'DEPLOY_STAGE=stable nohup sleep 86400 >/dev/null 2>&1 &'
sudo bash -c 'LAB_TOKEN=$(cat /opt/lab-mct/secret) nohup sleep 86401 >/dev/null 2>&1 &'
```
**Situation:** A deploy tool crashed halfway through a release, deleting its own config as it went down. The only surviving trace of the one-time release token is the environment of a single still-running helper process — but three near-identical root-owned helpers are running, and only one of them was launched with `LAB_TOKEN` in its environment. The token is 32 hex characters; without it the release can be neither completed nor rolled back.

**Your task:** Find which running process carries `LAB_TOKEN` in its environment, extract the token's value from `/proc`, and save it (one line, just the value) to `/tmp/lab-mct-token.txt`.

**Verify:**
```bash
sudo diff /tmp/lab-mct-token.txt /opt/lab-mct/secret && echo SOLVED   # expected: SOLVED (no diff output — recovered token matches the original)
```

### 🔴 Scenario 6 — "Regina: the producer that froze before its first line" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-reg
sudo mkfifo -m 666 /opt/lab-reg/events.fifo
sudo tee /opt/lab-reg/producer.sh >/dev/null <<'EOF'
#!/bin/bash
exec > /opt/lab-reg/events.fifo
while true; do echo "event $(date +%s)"; sleep 1; done
EOF
sudo chmod 755 /opt/lab-reg/producer.sh
nohup /opt/lab-reg/producer.sh >/dev/null 2>&1 &
echo $! > /tmp/lab-reg.pid
```
**Situation:** A new "event producer" service was deployed to feed a log-shipping pipeline through `/opt/lab-reg/events.fifo`. The process is alive (`ps` shows it, PID in `/tmp/lab-reg.pid`), it never crashes, it uses no CPU — and yet not a single event has ever come out. The shipper team says their consumer "hasn't been deployed yet, but that shouldn't matter."

**Your task:** Diagnose *why* the producer has never produced a byte — check what kind of file `events.fifo` is (`ls -l` first character), the producer's state (`ps -o stat,wchan -p <pid>`), and what its `/proc/<pid>/fd/1` does or doesn't point at. Then unblock the pipeline: attach a persistent consumer that drains the FIFO into `/tmp/lab-reg-events.log`, and prove events flow.

**Verify:**
```bash
sleep 3; c1=$(grep -c '^event ' /tmp/lab-reg-events.log); sleep 3; c2=$(grep -c '^event ' /tmp/lab-reg-events.log); [ "$c2" -gt "$c1" ] && echo SOLVED   # expected: SOLVED (events are flowing through the FIFO into the log, count still rising)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Saint John: what is writing to this log file?"
**Solution:**
```bash
for p in /proc/[0-9]*; do
  ls -l "$p/fd" 2>/dev/null | grep -q 'lab-sj/app.log' && echo "$p"
done
# -> /proc/<pid>; confirm what it is:
cat /proc/<pid>/cmdline | tr '\0' ' '; echo
kill <pid>
```
**Why this works & what it teaches:** Every open file a process holds is a symlink under `/proc/<pid>/fd/` (Rung 3.3), so scanning those symlinks finds the writer even when the filename never appears in any command line — this is exactly how `lsof` works under the hood. The writer kept fd 3 aimed at the log via `exec 3>>`, so the link was there to find. **Where people go wrong:** grepping `ps` output for the log filename — the fd table, not argv, is where open files live.

### Scenario 2 — "Halifax: the process that lied about its name"
**Solution:**
```bash
pid=$(pgrep -f lab-innocentd | head -1)
readlink /proc/$pid/exe > /tmp/lab-hfx-answer.txt
cat /tmp/lab-hfx-answer.txt   # /usr/bin/sleep
```
**Why this works & what it teaches:** `ps` and `/proc/<pid>/cmdline` show **argv**, which a program can set to anything (`exec -a` forged it here) — but `/proc/<pid>/exe` is a kernel-maintained symlink to the binary that is *actually* mapped into the process, and no userspace trick can forge it. This is a real incident-response technique for spotting renamed cryptominers. **Where people go wrong:** `pgrep -x lab-innocentd` finds nothing, because `comm` still says `sleep` — argv and comm are two different self-reported names, while `exe` is the ground truth.

### Scenario 3 — "Winnipeg: the heartbeats vanish into the void"
**Solution:**
```bash
pid=$(cat /tmp/lab-wpg.pid)
ls -l /proc/$pid/fd/1        # -> /dev/null  (there's the bug: stdout aimed at the void)
kill $pid
nohup /opt/lab-wpg/heartbeat.sh >> /tmp/lab-wpg.log 2>&1 &
sleep 3; tail -2 /tmp/lab-wpg.log
```
**Why this works & what it teaches:** The process was healthy; its fd 1 simply pointed at `/dev/null` because of how it was launched — and a process's fds are set *before* it runs and are visible from outside via `/proc/<pid>/fd` (Rung 3.3). Relaunching with `>> /tmp/lab-wpg.log` re-aims fd 1 at a real file, which is precisely the container-log mechanism: the app never changes, only what its fd 1 points at. **Where people go wrong:** debugging the *script* for a logging bug, when the truth was one `ls -l /proc/<pid>/fd/1` away.

### Scenario 4 — "Victoria: /dev/null is getting full"
**Solution:**
```bash
ls -l /dev/null              # -rw-rw-rw- ... — first char '-': it's a REGULAR FILE, not 'c'
sudo rm /dev/null
sudo mknod -m 666 /dev/null c 1 3
```
**Why this works & what it teaches:** What makes `/dev/null` discard data is not its name or path — it is the **character-device driver** behind it (major 1, minor 3), which defines "write means discard" (Rung 3.1's `file_operations` dispatch). A `touch`-created `/dev/null` is a regular file backed by ext4, so every `>/dev/null` *stored* the bytes. `mknod c 1 3` recreates the device node so the VFS routes writes back to the null driver. **Where people go wrong:** running `> /dev/null` to "empty" it — that truncates the regular file but doesn't fix its type; the first `ls -l` character is the diagnosis.

### Scenario 5 — "Moncton: recover the token from a dying deploy"
**Solution:**
```bash
# 1) Find which process has LAB_TOKEN in its environment (environ is NUL-separated, root-readable):
sudo bash -c 'for e in /proc/[0-9]*/environ; do tr "\0" "\n" < "$e" 2>/dev/null | grep -q "^LAB_TOKEN=" && echo "$e"; done'
# 2) Extract the value (replace <pid> with the directory found above):
sudo tr '\0' '\n' < /proc/<pid>/environ | grep '^LAB_TOKEN=' | cut -d= -f2 > /tmp/lab-mct-token.txt
```
**Why this works & what it teaches:** A process's launch-time environment is a file too — `/proc/<pid>/environ` — with entries separated by NUL bytes, just like `cmdline` (Rung 7, Prediction 2), so `tr '\0' '\n'` makes it greppable. It is readable only by the process owner or root, which is why `sudo` is required for these root-owned helpers — the "everything is a file" model reuses ordinary file permissions as its security model. **Where people go wrong:** plain `grep LAB_TOKEN /proc/*/environ` silently misses matches as the unprivileged user (permission denied) and can be awkward on NUL-separated data — convert the NULs first, as root.

### Scenario 6 — "Regina: the producer that froze before its first line"
**Solution:**
```bash
pid=$(cat /tmp/lab-reg.pid)
ls -l /opt/lab-reg/events.fifo      # prw-rw-rw- — first char 'p': a named pipe (FIFO)
ps -o stat,wchan,cmd -p $pid        # state S, waiting inside the FIFO open
ls -l /proc/$pid/fd/1               # still /dev/null — the redirect to the FIFO NEVER completed
# Unblock: attach a persistent reader; the producer's open() then returns and events flow
nohup bash -c 'cat /opt/lab-reg/events.fifo >> /tmp/lab-reg-events.log' >/dev/null 2>&1 &
```
**Why this works & what it teaches:** A FIFO is a rendezvous, not storage: `open()` for writing **blocks until a reader opens the other end**, so the producer froze inside `exec > events.fifo` before printing anything — its fd 1 still shows the *old* target because the new one was never attached. Attaching a consumer completes the rendezvous and bytes flow, illustrating that for pipe-type files "read/write" means synchronized communication between processes (Rungs 3.1 and 3.2, type `p`). **Where people go wrong:** restarting the producer over and over — it will block identically every time; the fix is on the *reader* side. (Use a long-lived reader: a one-shot `cat` that exits would send the producer SIGPIPE when the last reader closes.)
