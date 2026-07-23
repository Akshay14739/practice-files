# Filesystem Hierarchy & Navigation, Climbed the Ladder 🪜
### Learning the Linux tree deeply for Kubernetes — deriving where things live, not memorizing paths

> This is your Linux filesystem guide rebuilt on the Learning Ladder framework. Instead of leading with `ls` and `cd`, we climb from **why the tree exists** → **the one core idea** → **the machinery** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every command lives at the TOP of the ladder (Rung 7). You'll understand *what a path actually is* and *how the kernel resolves it* before you type a single `cd`.

---

# RUNG 0 — The Setup

**What am I learning?**
The Linux filesystem — the single tree that starts at `/`, the standard that says what lives where (the FHS), and the handful of commands to move through it and read what you find (`cd`, `ls`, `cat`, `less`, `tail`, `stat`, and friends).

**Why did it land on my desk?**
A node in your cluster went `NotReady`. `kubectl` can't help you — the kubelet itself is unhealthy, so you SSH into the box. Now you're staring at a bare shell prompt with no cluster API to hide behind. Your lead says: "The kubelet writes its state to disk, containerd stores its images and sockets on disk, the CNI plugins are on disk, the certs are on disk, the container logs are on disk. Go find out why it's unhappy." Every one of those is a **path**. If you don't know the tree, you can't triage a node.

**What do I already know about it?**
You've typed `cd` and `ls` a thousand times. You know `~` is home and `/` is "the top." You've probably run `cat some.yaml`. But you don't yet have a *model* of why `/etc` vs `/var` vs `/run` are separate, what a "mount point" really is, why `/proc` shows files that don't exist on any disk, or why `tail -f` on a log behaves like `kubectl logs -f`. That model is the whole point of this rung-climb — because on a broken node, knowing *where the kubelet would put a thing* lets you find it without Googling.

---

# RUNG 1 — The Pain 🔥
### *Why does a standardized filesystem hierarchy exist at all?*

Before you memorize a single directory, sit with the problem it solves. If you understand the pain, you can *predict* where a program will store its data — and the FHS stops needing memorization.

### The problem that forced the hierarchy into existence

Imagine a machine where every program invents its own place to put things. The web server drops its config in `/webserver-stuff/`. The database puts its config next to its binary in `/programs/db/config`. Logs go... wherever each author felt like. One program's data is read-only after install; another's changes every second; a third's is wiped on reboot — but nothing tells you which is which. Now:

```
THE PRE-STANDARD PAIN

/programs/webserver/config.txt      ← config? or data?
/db-data/                           ← safe to back up? or regenerated?
/randomlogs/                        ← logs? somewhere else too?
/mystuff/binary + /mystuff/cfg      ← binary mixed with config
/cache-or-important-who-knows/      ← wipe on reboot? nobody knows

Pain points:
• You can't back up "just the config" — it's scattered everywhere.
• You can't mount /home on a separate disk — home isn't a place.
• You can't make the OS read-only — writable and read-only data are mixed.
• A new admin has to LEARN each program's private geography.
• Automation is impossible: no script can assume where anything is.
```

### What people did *before* — and why it hurt

Early Unix systems genuinely were this chaotic, and every vendor's Unix drifted differently. A script that worked on one Unix broke on another because `/bin` here was `/usr/bin` there and logs were in three different places. The **Filesystem Hierarchy Standard (FHS)** — a written spec, currently 3.0 — was created to stop the drift: it declares, for every top-level directory, *what kind of thing lives there and what the rules are* (read-only vs writable, wiped-on-reboot vs persistent, machine-specific vs shareable).

### What breaks without it — and who feels it most

Without a predictable tree:

- **You can't separate concerns onto different storage.** `/var` (things that grow — logs, container layers) wanting its own disk only works if "things that grow" all live in one predictable place.
- **You can't make a read-only / immutable OS.** Container-optimized distros and immutable node images (Bottlerocket, Flatcar, Talos) depend on the rule that `/usr` is read-only and only `/var`, `/etc`, `/run` are writable. No FHS discipline, no immutable node.
- **You can't automate.** Kubernetes' kubelet *hardcodes* `/var/lib/kubelet`. containerd *hardcodes* `/var/lib/containerd` and `/run/containerd`. These defaults are only sane because the FHS already assigned meaning to `/var/lib` (persistent state) and `/run` (volatile runtime state).

**Who feels the pain most?** You — the platform engineer on the broken node. When you already know "logs live under `/var/log`, runtime sockets under `/run`, persistent state under `/var/lib`, config under `/etc`," you find the kubelet's problem in seconds instead of spelunking. The FHS is, fundamentally, a **map handed to the person doing triage**.

> **✅ Check yourself before Rung 2:** Without listing directories — why does putting *all* the "grows over time" data (logs, caches, container layers) under one predictable subtree make it possible to give a node its own log disk? What would break if logs were scattered?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — the rest of the filesystem can be *derived* from it:

> **Linux presents everything — every disk, device, kernel fact, and remote share — as one single tree of names rooted at `/`, and each top-level directory has an assigned *purpose* (config, state, runtime, logs…) so you can predict where any file lives from what *kind* of thing it is.**

That's the whole trick. Two halves: **(1) one unified tree** (there is no `C:` or `D:` — everything hangs off `/`), and **(2) purpose-assigned directories** (the FHS).

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"one single tree rooted at `/`"* → other disks and filesystems don't get their own letter; they get **grafted onto a directory** (a *mount point*). That's why a separate `/var` disk just... appears at `/var`.
- *"every device… as names"* → `/dev/sda`, `/dev/null` are files. *Kernel facts* → `/proc`, `/sys` are files that don't exist on any disk (see `01-linux-philosophy.md`, "everything is a file").
- *"each directory has a purpose"* → you can *guess* correctly: kubelet **state** → `/var/lib/kubelet`; cluster **config/certs** → `/etc/kubernetes`; containerd's **runtime socket** → `/run/containerd`; container **logs** → `/var/log`. You didn't memorize those; you *derived* them from the purpose rule.
- *"predict where any file lives from its kind"* → triage becomes deduction, not search.

Once you see that **a path is just a route through one purpose-organized tree**, navigation (`cd`, `pwd`, `ls`) is simply "walk the tree," and reading files (`cat`, `less`, `tail`) is "open a node in the tree." One idea, applied everywhere.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then derive, *without looking it up*: if containerd stores persistent image layers and also opens a runtime control socket, which top-level directory should each go under, and why are they different directories?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> **A. The floor plan.** Linux keeps everything under one top-level folder, written `/`, like one big office building where every room has an assigned purpose (the FHS is simply the written floor plan). The rooms you'll meet: `/etc` is the filing cabinet of settings; `/var` holds records that grow while the system runs (logs, databases) and survive restarts; `/usr` is the installed software itself; `/run` is a whiteboard kept in memory and wiped clean at every reboot — live connections and notes about what's running right now; `/proc` and `/sys` are live dashboards the system invents on the fly, taking no disk space at all (one about running programs, one about hardware); `/dev` holds the doors to devices like disks and screens; `/opt` is where third-party vendors drop self-contained apps; `/tmp` is a scratch table anyone may use; `/home` holds each person's private room; `/boot` is the gear needed just to start the machine. Four buckets cover most troubleshooting: settings (`/etc`), long-lived data (`/var/lib`), logs (`/var/log`), and this-moment-only stuff (`/run`).
>
> **B. One building stitched from several plots.** Your machine may have several separate storage areas — different disks, partitions, even a chunk of memory — yet you walk around as if it were one seamless building. A "mount point" is a doorway where a whole separate structure has been grafted onto the main one. Stepping through, you never feel the seam. The dashboard folders (`/proc`, `/sys`) are grafted in the same way, except there's no disk behind them at all — the system writes the answers the instant you look.
>
> **C. How an address finds a file.** A path like `/var/lib/kubelet/config.yaml` is a set of walking directions. Under the hood, each folder is nothing but a table matching *names* to *record numbers*; the numbered record (an "inode" — the file's index card, holding its size, owner, permissions, and where its contents sit, but NOT its name) is the real file. The system starts at the building entrance and follows the directions one name at a time until it reaches the final index card. An address beginning with `/` always starts from the entrance (an "absolute" path); anything else starts from wherever you're currently standing (a "relative" path). Every folder contains two built-in signposts: `.` means "right here" and `..` means "one level up." And "where you're standing" isn't written anywhere on disk — it's a note the system pins to your running program, which is why the `cd` command must be part of the shell itself rather than a separate program.

*Now the original technical deep-dive — the same ideas, in precise form:*

We now open the hood. Three things to understand: **(A) the FHS map itself, (B) how one tree is stitched from many filesystems via mount points, and (C) how the kernel actually turns a path string into a file.**

## (A) The FHS map — what lives where, and the *rule* behind each

Don't memorize this as trivia. Read the **"rule"** column — that's the derivable part. The Kubernetes column shows the payoff.

```
THE ROOT TREE  (top-level directories off / )

/            the root of everything. NOT the same as /root.
│
├── /etc     CONFIG. Text files, machine-specific, persistent, editable.
│            Rule: "if it configures the system, it's here."
│            K8s: /etc/kubernetes/  (admin.conf, manifests/, pki/)
│
├── /var     VARIABLE STATE. Data that grows/changes at runtime.
│            Rule: "written by running programs; persists reboots."
│            K8s: /var/lib/kubelet/, /var/lib/containerd/, /var/log/pods/
│
├── /usr     THE OS ITSELF. Programs, libraries. Read-only in spirit.
│            Rule: "installed software, shareable, not machine-specific."
│            K8s: /usr/bin/kubectl, /usr/bin/kubelet, /usr/bin/containerd
│
├── /run     RUNTIME (tmpfs — RAM). Volatile, WIPED on every reboot.
│            Rule: "sockets, PIDs, runtime handles. Gone at boot."
│            K8s: /run/containerd/containerd.sock, /run/flannel/
│
├── /proc    KERNEL PROCESS INFO. Not a disk! A live view of the kernel.
│            Rule: "one dir per PID + kernel tunables. Zero bytes on disk."
│            K8s: /proc/<pid>/cgroup, /proc/<pid>/ns/  (how containers work)
│
├── /sys     KERNEL DEVICE/SUBSYSTEM INFO. Also not a disk.
│            Rule: "devices, drivers, and cgroup v2 controllers live here."
│            K8s: /sys/fs/cgroup/kubepods.slice/  (pod CPU/memory limits)
│
├── /dev     DEVICE FILES. Disks, terminals, null, random — as files.
│            Rule: "hardware and pseudo-devices addressed as files."
│            K8s: /dev/null, /dev/sda; mounted into containers as needed
│
├── /opt     OPTIONAL add-on software (third-party, self-contained).
│            Rule: "vendor drops a whole app tree here."
│            K8s: /opt/cni/bin/  (the CNI plugin binaries: bridge, host-local…)
│
├── /tmp     TEMPORARY scratch. Anyone can write. May be cleared on reboot.
│            Rule: "throwaway. Never store anything you need."
│
├── /home    USER home directories. /home/alice, /home/bob.
│            Rule: "per-user personal files and dotfiles."
│            K8s: ~/.kube/config  (your kubectl credentials live here)
│
├── /root    The root USER's home. (Yes, confusingly named vs /.)
│
├── /boot    Kernel + bootloader. vmlinuz, initramfs, GRUB config.
│            Rule: "what's needed to boot, before / is fully up."
│
├── /bin /sbin /lib   On modern distros these are SYMLINKS into /usr.
│                     (the "usrmerge" — /bin → /usr/bin.)
│
└── /mnt /media       Mount points for temporary / removable filesystems.
```

**The four purpose-buckets that matter most for K8s triage** — hold these and you can find almost anything on a node:

- **`/etc` = configuration** (what should happen). Certs, kubeconfigs, static pod manifests.
- **`/var/lib` = persistent state** (what happened, kept). Kubelet pod dirs, containerd image layers, etcd data.
- **`/var/log` = logs** (what happened, human-readable). Container and system logs.
- **`/run` = volatile runtime** (what's happening *right now*, RAM-backed). Sockets, PIDs — gone after reboot.

## (B) One tree, many filesystems: the mount point

Here's the fact that surprises people: `/`, `/var`, and `/boot` might live on **three different disks or partitions**, yet you walk between them as if they were one tree. How? A **mount point** — a directory where a separate filesystem is *grafted onto* the tree.

```
MOUNTING: stitching many filesystems into ONE tree

Physical reality (separate block devices):
  ┌─────────────┐   ┌─────────────┐   ┌──────────────┐
  │  /dev/sda2  │   │  /dev/sda3  │   │  tmpfs (RAM) │
  │  root fs    │   │  data fs    │   │  volatile    │
  └─────────────┘   └─────────────┘   └──────────────┘

Logical view you actually navigate (one tree):
                       /
        ┌──────────────┼───────────────┐
      /etc           /var              /run
     (on sda2)    (on sda3 —         (tmpfs, RAM —
                   MOUNTED here)      MOUNTED here)
                     │
                  /var/lib/kubelet   ← lives on the sda3 filesystem

A "mount point" = a directory whose contents come from
a DIFFERENT filesystem than its parent. `cd` walks across
the seam without you ever noticing.
```

You never see the seam. `cd /var/lib/kubelet` crosses from the root filesystem onto the `/var` filesystem transparently — this is what "one rooted tree" from the One Idea buys you. (Mounting mechanics get their own file: `15-storage-mounts.md`.)

The special filesystems `/proc`, `/sys`, and `/run` (tmpfs) are mounted too — but they're **not on any disk**. `/proc` is a *virtual* filesystem the kernel generates on the fly: when you `cat /proc/1/cgroup`, the kernel manufactures that answer at read time. This is precisely how containers are visible from the host — a container is just a process, and `/proc/<pid>/ns/` exposes its namespaces (see `13-namespaces.md`).

## (C) The real mechanism: how a path becomes a file

When you type `cat /var/lib/kubelet/config.yaml`, what does the kernel actually *do* with that string? It walks the tree component by component, using **inodes**.

> An **inode** is the on-disk record for a file: its metadata (size, owner, permissions, timestamps) and pointers to the data blocks. The *name* is NOT in the inode — names live in directories, which are just tables mapping name → inode number.

```
PATH RESOLUTION: /var/lib/kubelet/config.yaml

Kernel starts at the ROOT inode (/), then walks each "/"-separated part:

  /                → root directory inode. Look up "var" in it.
   └─ var          → get var's inode. It's a dir. Look up "lib".
       └─ lib      → get lib's inode. Dir. Look up "kubelet".
           └─ kubelet → dir inode. Look up "config.yaml".
               └─ config.yaml → a FILE inode. Stop. Open it.

Each step = "read this directory (a name→inode table),
find the next name, jump to that inode, repeat."

A "path" is literally the driving directions.
An ABSOLUTE path starts at / (the root inode).
A RELATIVE path starts at your CWD inode (the . you're standing in).
```

**Absolute vs relative, now derivable:** an **absolute path** begins with `/` — resolution starts at the root inode, so it means the same thing no matter where you're standing. A **relative path** doesn't start with `/` — resolution starts at your **current working directory (CWD)**, the inode your shell is "standing in." Two special names in every directory make relative navigation work: `.` (this directory) and `..` (the parent). `cd ..` just follows the `..` entry to the parent's inode.

**Where does your CWD live?** Not on disk — it's kernel state attached to your *process*. Your shell has a CWD; when you `cd`, the shell asks the kernel to change *its own* process CWD. You can literally see it: `/proc/self/cwd` is a symlink to wherever the reading process currently stands. (This is why `cd` has to be a shell builtin, not an external program — an external program couldn't change its *parent* shell's directory. See `02-shell-and-environment.md`.)

> **✅ Check yourself before Rung 4:** Draw the path-resolution walk from memory for `/etc/kubernetes/pki`. Then answer: (1) why does `..` from `/` just stay at `/`? (2) `/proc/1/status` returns data but occupies zero disk bytes — what generates its contents, and when? (3) why can't `cd` be an external `/usr/bin/cd` program?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now that you have the machinery, the jargon has somewhere to land. Every term below is *just a label for a part of the picture you already understand*.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Root (`/`)** | The single top of the tree; the starting inode for absolute paths | Rung 3C — resolution origin |
| **FHS** | The written spec assigning a *purpose* to each top-level dir | Rung 3A — the map |
| **Path** | A string of names describing a walk through the tree | Rung 3C — the driving directions |
| **Absolute path** | Path starting with `/`; resolves from root, location-independent | Starts at root inode |
| **Relative path** | Path not starting with `/`; resolves from your CWD | Starts at CWD inode |
| **CWD** | Current working directory — per-process kernel state | The `.` you're standing in |
| **`.` / `..`** | Directory entries for "here" / "parent" | Relative-navigation links |
| **`~` (tilde)** | Shell shorthand for your home dir (`$HOME`) | Expanded by the shell, not the kernel |
| **Inode** | On-disk record of a file's metadata + data-block pointers | The thing a name points to |
| **Directory** | A file that is a table of name → inode number | Each step of path resolution |
| **Mount point** | A dir where another filesystem is grafted into the tree | Rung 3B — the seam |
| **tmpfs** | A filesystem living in RAM; contents vanish on reboot | `/run`, `/tmp` sometimes |
| **Virtual FS** | Kernel-generated filesystem, no disk backing | `/proc`, `/sys` |
| **Symlink** | A file whose content is *another path* to follow | `/bin`→`/usr/bin`, `~/.kube/config` targets |
| **`ls`** | Lists a directory's name→inode entries + their metadata | Reads a directory + `stat`s entries |
| **`stat`** | Prints an inode's full metadata | Directly reads the inode |
| **`cat` / `less`** | Read a file's data blocks to your terminal | Opens the file inode, streams bytes |
| **`tail -f`** | Keeps reading a file as it grows | Follows appended blocks live |
| **`file`** | Guesses a file's type by inspecting its first bytes ("magic") | Reads data, not the name |
| **`xxd`** | Dumps raw bytes as hex + ASCII | Reads data blocks byte-for-byte |

### The big unlock: which terms are the *same kind of thing*

New learners think these are 20 unrelated ideas. They're not. Group them:

```
GROUP 1 — "Ways of writing WHERE" (all just path forms):
   absolute path, relative path, ~, ., .. , cd -
   → All resolve to ONE inode. They differ only in starting point.

GROUP 2 — "The tree's building blocks":
   inode (the file's identity) + directory (name→inode table)
   → A name is NOT the file. The inode is the file. Names are labels.

GROUP 3 — "Filesystems that aren't disks" (mounted, but no blocks):
   /proc, /sys  = virtual (kernel-generated)
   /run         = tmpfs (RAM-backed, wiped on reboot). /tmp is tmpfs
                  too ONLY if configured that way — NOT the default on
                  Ubuntu 22.04, where /tmp sits on the root filesystem.
   → Same "it's a mounted filesystem" mechanism, no persistent storage.

GROUP 4 — "Commands that READ a directory":
   ls (and its flags -l -a -h -t -R -i)
   → All do: read the name→inode table, optionally stat each inode.

GROUP 5 — "Commands that READ a file's bytes":
   cat, head, tail, less, xxd
   → All open the file inode and stream its data blocks; they differ
     only in HOW MUCH and in what FORMAT they show it.

GROUP 6 — "Commands that READ metadata, not content":
   stat (the inode), file (the magic bytes), ls -l (a compact stat)
```

If you hold those six groups, you hold this whole file's vocabulary. Notice the deepest one: **a filename is not a file; the inode is the file.** Half of the next document (`04-file-operations.md` — hard links, `mv`, `rm`) becomes obvious once that clicks.

> **✅ Check yourself before Rung 5:** Without looking — `ls`, `cat`, and `stat` all "look at a file," but they read *different things*. Which reads the directory table, which reads the data blocks, and which reads the inode metadata?

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; a single traced action sears the model in. Let's trace the exact thing you'll do on that broken node: **you SSH in and run `tail -f /var/log/syslog` to watch the kubelet's complaints live** — the on-disk equivalent of `kubectl logs -f`.

**Step 1 — Your shell has a CWD**
You land in `~` (e.g. `/home/ubuntu`). The shell holds that as its process CWD (kernel state). You type `tail -f /var/log/syslog`.

**Step 2 — The shell parses the command**
`tail` is not a builtin, so the shell will `fork` a child and `exec` the `tail` program. But first it needs to find `tail`: it searches `$PATH` and resolves to `/usr/bin/tail` (a path walk of its own). The argument `/var/log/syslog` is an **absolute path**, so it's handed to `tail` unchanged.

**Step 3 — `tail` asks the kernel to open the path**
`tail` calls `open("/var/log/syslog")`. The kernel does the Rung 3C walk: root inode → `var` → `log` → `syslog` → a regular file inode. It crosses any mount seam (if `/var` is its own filesystem) invisibly. It returns a **file descriptor** — a small integer handle to the open file (see `01-linux-philosophy.md`).

**Step 4 — `tail` seeks to near the end**
`tail` reads the file's size from the inode, seeks toward the end, and reads back roughly the last 10 lines' worth of data blocks, printing them. That's the "tail" part.

**Step 5 — `-f` means "follow": don't stop at EOF**
Normally a reader hits end-of-file and exits. `-f` tells `tail` to *stay open* and keep polling (or, more efficiently, use `inotify` — a kernel facility that notifies a process when a file changes). When the kubelet appends a new log line to the file's data blocks, the kernel wakes `tail`, which reads the new bytes and prints them.

**Step 6 — The kubelet writes; you see it**
Somewhere, the kubelet (or systemd-journald forwarding to syslog) `write()`s "node not ready: container runtime down" to the same inode. The bytes land in new data blocks; `inotify` fires; `tail` prints the line to your terminal. You've now watched a live log stream — the same experience as `kubectl logs -f`, but one layer down, straight from the file.

```
THE TRACE: tail -f /var/log/syslog

You type ──▶ shell (CWD=/home/ubuntu)
                │ not a builtin → find in $PATH → /usr/bin/tail
                ▼
           fork + exec /usr/bin/tail  with arg "/var/log/syslog"
                │
                ▼   open("/var/log/syslog")  [absolute → start at / ]
        kernel walks:  / → var → log → syslog  (crossing mount seam)
                │  returns file descriptor (fd 3)
                ▼
           read last ~10 lines from data blocks  → print
                │
                ▼   -f : register inotify watch, then WAIT
                │
   kubelet ──write()──▶ [syslog inode: +new block] ──inotify──▶ wakes tail
                │
                ▼
        tail prints the new line to your terminal — LIVE
```

**The K8s payoff, made concrete:** on a modern node most logs are in the systemd journal, so the direct analog is `journalctl -u kubelet -f` (same "follow" idea). And per-container logs live as real files at `/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log`, with friendly symlinks in `/var/log/containers/`. When you run `kubectl logs -f`, the kubelet is doing *exactly this trace* — `tail -f` on that file — and streaming the bytes back to you over the API. You just did by hand what kubectl does for you.

> **✅ Check yourself before Rung 6:** At Step 5, what does `-f` change about `tail`'s behavior at end-of-file, and what kernel facility lets it wake up only when the file actually changes (instead of busy-looping)? And: where on disk does `kubectl logs` ultimately read from?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand the single-rooted, purpose-organized tree best by seeing what it *replaced* and where its limits are.

### The alternative: drive-letter filesystems (Windows/DOS)

The other major model, familiar from Windows, gives each storage volume its **own separate root**: `C:\`, `D:\`, `E:\`. There is no single top. A path names *which volume* first, then walks that volume's tree.

```
TWO MODELS OF "WHERE IS A FILE"

Windows (multi-root):              Linux (single-root):
   C:\  D:\  E:\  (3 trees)            /  (one tree)
    │    │    │                        ├── /var   (could be disk 2)
   each disk = its own root            ├── /home  (could be disk 3)
                                       └── /mnt/usb (removable, grafted in)
   To use disk D you name "D:".    To use another disk you MOUNT it
   The letter IS the volume.       AT a directory. The path hides the disk.
```

The difference is not cosmetic. In the Linux model, **a program never needs to know which physical disk a file is on** — `/var/lib/kubelet` is `/var/lib/kubelet` whether `/var` is on the boot disk or a dedicated NVMe. The kubelet's hardcoded path *just works* after you mount a bigger disk at `/var`. In the drive-letter world, moving data to a new disk changes its path (`C:\data` → `D:\data`), breaking anything that hardcoded it.

### What each model can and can't do

| The task | Drive-letter (Windows-style) | Single-tree + mounts (Linux) | Why the difference |
|---|---|---|---|
| Address a file | `D:\app\cfg` (volume in the path) | `/app/cfg` (volume hidden) | One root vs many |
| Move data to a new disk without breaking paths | ❌ path changes | ✅ mount new disk at same dir | Path is decoupled from device |
| Expose kernel state as files | ⚠️ limited | ✅ `/proc`, `/sys` in the same tree | Everything is a node in one tree |
| Give one directory its own disk/quota | ❌ awkward | ✅ mount a filesystem at that dir | Mount points |
| Predict where a program stores config/logs | ❌ vendor's choice | ✅ FHS assigns purpose | Standardized hierarchy |
| Removable media | New letter appears | Grafted at `/media/<name>` | Mount, not new root |

The pattern in the "why" column is always the same: **decoupling the *name* of a file from the *device* it lives on** is what a single mounted tree buys you — and it's exactly what makes hardcoded paths like `/var/lib/kubelet` safe.

### When would I NOT lean on this?

- **Pure Windows shops / Windows nodes.** Windows Server Kubernetes nodes use the drive-letter model; the FHS doesn't apply there.
- **When you need the *physical* device, not the logical path.** For disk-level work (partitioning, checking which NVMe is filling up) you drop below the tree to `/dev` and tools like `lsblk`/`df` (see `15-storage-mounts.md`). The unified tree *hides* the device — sometimes you want it back.

**One-sentence "why this over that":**
> Linux's single mounted tree lets every tool and every hardcoded path (kubelet, containerd, etcd) address files by *purpose and location* while staying blind to which physical disk backs them — which is precisely why you can grow a node's storage by mounting a disk at `/var` and nothing breaks.

> **✅ Check yourself before Rung 7:** Explain to an imaginary colleague why, on a Linux node, you can move `/var/lib/containerd` onto a brand-new disk *without reconfiguring containerd at all* — but doing the equivalent on a drive-letter system would break it. (Hint: what is decoupled from what?)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each one is a **hypothesis you commit to first**, then verify. Read the prediction, cover the outcome, decide if you agree, *then* run it. All commands are safe (read-only navigation and viewing) and target Ubuntu 22.04 / systemd; distro differences are noted.

---

## Prediction 1 — The tree is navigable and `cd -` teleports you back (normal case)

> **My prediction:** "If I `cd` into a deep K8s config path, then `cd` somewhere else, then `cd -`, I'll land *back* at the K8s path — *because* the shell remembers my previous CWD in `$OLDPWD`, and `cd -` means 'go to `$OLDPWD`.' `pushd`/`popd` will do the same but with a *stack* so I can nest jumps."

```bash
cd /etc/kubernetes/pki      # certs & keys for the control plane
pwd                          # /etc/kubernetes/pki
cd /var/lib/kubelet
pwd                          # /var/lib/kubelet
cd -                         # jump BACK to previous dir
pwd                          # /etc/kubernetes/pki   ← teleported back

# The stack version, for nesting:
pushd /var/log               # pushes CWD, cd's to /var/log; prints the stack
pushd /opt/cni/bin           # push again; stack now 3 deep
popd                         # pop → back to /var/log
popd                         # pop → back to where you started
```

**Verify:** After `cd -`, `pwd` shows `/etc/kubernetes/pki` and the shell echoes the directory it jumped to. `pushd` prints the whole directory stack each time; `dirs -v` shows it numbered. If `cd -` errors with "OLDPWD not set," you're in a fresh shell that hasn't moved yet — that itself teaches you `cd -` depends on history, not magic.

---

## Prediction 2 — `ls` flags read the same directory but surface different inode facts

> **My prediction:** "If I list `/var/log/` three ways — `-lh`, `-lt`, `-i` — I'll see the *same files* but ordered/annotated differently: `-h` makes sizes human-readable, `-t` sorts newest-first (so the actively-written log floats to top), and `-i` prints each file's inode number — *because* `ls` reads one name→inode table and then `stat`s each entry, and the flags just choose which inode facts to show and how to sort."

```bash
ls -lh /var/log/            # long listing, human sizes (4.0K, 2.3M)
ls -lt /var/log/            # newest first → the live log is at the TOP
ls -i  /var/log/            # show inode numbers next to each name
ls -lah ~                   # long + hidden (dotfiles) + human, on your home
```

**Verify:** In `ls -lt /var/log/`, `syslog` (or `kern.log`) sits at or near the top because it was written most recently — that's your "what's active right now" signal. `ls -lah ~` reveals `.kube` (your kubeconfig dir), `.bashrc`, etc. — the dot-prefixed names `ls` hides by default. If `-h` didn't change the sizes, you likely typed `ls -l` alone; the raw byte counts prove `-h` is doing the humanizing.

---

## Prediction 3 — `/proc` files have "size 0" yet return real data (edge / surprising case)

> **My prediction:** "If I `ls -l` a file under `/proc` and then `cat` it, the listing will claim size **0 bytes**, but `cat` will still print real content — *because* `/proc` is a *virtual* filesystem: the file has no data blocks on disk; the kernel *generates* the bytes at the moment I read it, so its stored 'size' is meaningless."

```bash
ls -l /proc/1/status        # -rw-r--r-- 1 root root 0 ...  ← SIZE 0
cat /proc/1/status | head   # ...yet this prints PID 1's live state
stat /proc/1/cgroup         # Size: 0, and note the filesystem type

# Same idea for a container: find a real PID and see ITS view
cat /proc/self/status | grep -i '^Name\|^Pid'
```

**Verify:** `ls -l` shows `0` for the size, but `cat` prints a full status block (state, threads, memory). That contradiction *is* the lesson: on `/proc` and `/sys`, size is a lie because there are no blocks — the kernel is the author. This is the exact mechanism that lets the host inspect any container's cgroup and namespaces via `/proc/<pid>/`. If you expected `cat` to print nothing because "size is 0," your model just corrected itself.

---

## Prediction 4 — `file` and `xxd` judge a file by its *bytes*, not its name (edge case)

> **My prediction:** "If I run `file` on the `kubectl` binary and on a text config, `file` will correctly say one is an ELF executable and the other is text — *because* `file` ignores the name and inspects the leading 'magic' bytes. `xxd` on the binary will show `7f 45 4c 46` (`.ELF`) at offset 0, which is *why* `file` knows."

```bash
file /usr/bin/kubectl                 # ELF 64-bit LSB executable, x86-64...
file /etc/kubernetes/admin.conf 2>/dev/null || file /etc/hostname
                                      # ASCII text / YAML
xxd /usr/bin/kubectl | head -1        # 00000000: 7f45 4c46 ...  .ELF....
```

**Verify:** `file /usr/bin/kubectl` reports `ELF 64-bit ... executable`; the text file reports `ASCII text`. `xxd ... | head -1` shows the magic number `7f 45 4c 46` = `.ELF` in the ASCII column. That four-byte signature is *how* `file` decided — proving type detection is content-based, not extension-based. (If `kubectl` isn't at `/usr/bin`, run `command -v kubectl` to find it — where a binary lives is itself a `$PATH` lesson from `02-shell-and-environment.md`.)

---

## Prediction 5 — `less` navigates a big file without loading it all; `tail -f` follows a growing one (K8s case)

> **My prediction (part A):** "If I open a large log in `less` and press `G`, I'll jump to the end instantly even on a huge file — *because* `less` seeks and pages on demand rather than reading the whole file into memory like `cat` would. `/pattern` searches, `n` finds the next hit, `g` goes to top, `q` quits."
>
> **My prediction (part B):** "If I `tail -f` a live log, new lines will appear as they're written — the same streaming behavior as `kubectl logs -f`, because both are 'follow the file as it grows.'"

```bash
# Part A — paging & searching a log with less:
less /var/log/syslog
#   Inside less:  G = end,  g = top,  /Failed = search fwd,
#                 n = next match,  N = prev match,  q = quit
#   (On a K8s node, try:  less /var/log/pods/*/*/0.log )

# Part B — follow a live log (the kubectl logs -f analog):
tail -f /var/log/syslog
#   watch new lines stream in; Ctrl-C to stop.

# The real node equivalents (systemd journal + per-pod files):
journalctl -u kubelet -f            # follow kubelet logs live
tail -f /var/log/containers/<pod>_<ns>_<container>-*.log   # one container
```

**Verify (A):** In `less`, `G` lands you at the last line instantly regardless of file size; typing `/Failed` then `n` walks you through each occurrence; `q` exits cleanly back to the shell. If a huge file paged slowly, remember `less` is still the *right* tool — `cat` on a multi-GB log would flood your terminal and can hang a session.
**Verify (B):** `tail -f` sits and waits, then prints each new line the instant it's appended. Trigger activity (e.g. `logger "test from $(whoami)"` writes a line to syslog) and watch it appear. This is the Rung 5 trace, live. If nothing streams, the file may be quiet — that's not a failure, it's an idle log; `journalctl -u kubelet -f` on a real node will show steady output.

---

## The prediction habit, generalized

Fill this in for anything new you explore on a node:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

> **Note on `/var/log/syslog` vs the journal:** On Ubuntu/Debian, `/var/log/syslog` exists as a plain text file. On RHEL/Fedora/CentOS and many minimal container-OS nodes, there is **no** `/var/log/syslog`; logs live only in the binary systemd journal — use `journalctl` there. Per-container log *files* under `/var/log/pods/` and `/var/log/containers/` exist on essentially all Kubernetes nodes regardless of distro, because the kubelet writes them.

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> Linux stitches every disk, device, and kernel fact into one tree rooted at `/` where each top-level directory has an assigned purpose, so you navigate it with a handful of path-walking and file-reading commands and can *predict* where anything — including everything Kubernetes writes — lives.

**Explain it to a beginner in 3 sentences:**
> 1. Unlike Windows with its `C:` and `D:` drives, Linux has exactly one tree starting at `/`, and other disks are "mounted" — grafted onto a directory — so you never think about which physical disk a file is on.
> 2. A published standard (the FHS) gives each top folder a job: `/etc` is config, `/var` is data that grows (logs, container layers, kubelet state), `/usr` is the installed software, `/run` is throwaway runtime state in RAM, and `/proc`/`/sys` are live views of the kernel that don't exist on any disk.
> 3. Because the layout is predictable, triaging a broken node is deduction, not guesswork — you *know* certs are in `/etc/kubernetes/pki`, kubelet state is in `/var/lib/kubelet`, and container logs are in `/var/log/pods`, and you read them with `ls`, `less`, `tail -f`, `stat`, and `file`.

**Map of sub-capability → the one core idea (all one pattern):**

```
The one idea: "ONE purpose-organized tree; predict location from kind of thing."

FHS layout          → each dir's PURPOSE lets you derive where a file is
Absolute paths      → a walk from the root inode (location-independent)
Relative paths / cd → a walk from your process's CWD (. and ..)
Mount points        → how many filesystems become ONE tree
/proc, /sys, /dev   → kernel facts & devices AS nodes in that same tree
ls -l/-a/-h/-t/-i   → read the directory's name→inode table, show inode facts
cat/head/tail/less  → open a file inode, stream its data blocks
tail -f             → keep streaming as the file grows  (= kubectl logs -f)
stat / file / xxd   → read metadata / magic bytes / raw bytes, not the name
```

Nine capabilities, one idea: *a path is a route through a single purpose-organized tree, and every command either walks it, lists a node, or reads a node's bytes.*

**Which rung will I most likely need to revisit hands-on?**

- **Rung 3B–3C (mount points and inode-based path resolution).** The seam between filesystems and the "a name is not the file, the inode is" insight are the abstract parts. Fix: on a node run `df -h /var/lib/kubelet` to see which filesystem actually backs it, and `stat` a file to watch the inode number and block count appear — the abstraction becomes concrete instantly.
- **Rung 3A (the FHS map), under pressure.** You can *recognize* `/etc` vs `/var` vs `/run`, but reciting *why* containerd's socket is in `/run` while its layers are in `/var/lib` (volatile vs persistent) takes a rep or two. Rehearse the four buckets — config / persistent-state / logs / volatile-runtime — out loud.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first, on a real node if you can.

---

## Related concepts

- [Everything is a File; /proc, /sys, /dev](01-linux-philosophy.md) — why kernel facts and devices appear as nodes in this tree, and what a file descriptor is.
- [The Shell & Environment](02-shell-and-environment.md) — how `~`, `$PATH`, and `$OLDPWD` are expanded, and why `cd` must be a builtin.
- [File Operations, Links & Inodes](04-file-operations.md) — the payoff of "a name is not the file": hard links, `mv`, `rm`, and `find`.
- [Storage & Mounts](15-storage-mounts.md) — the mount mechanism in depth: partitions, `fstab`, tmpfs, and OverlayFS (how container layers stack).
- [Namespaces](13-namespaces.md) — how `/proc/<pid>/ns/` exposes a container's isolated view of the tree.
- [Linux ↔ Kubernetes Map](27-linux-kubernetes-map.md) — the full node-triage reference tying every path here to what kubelet, containerd, and etcd do with it.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why does putting all the "grows over time" data under one predictable subtree make it possible to give a node its own log disk? What would break if logs were scattered?

**A:** Because everything that grows at runtime lives under one predictable subtree (`/var`), you can mount a dedicated disk at that single directory and *all* growing data — logs, caches, container layers — automatically lands on it; "give the growing stuff its own storage" becomes one mount operation. If logs were scattered across each program's private geography, there would be no single place to attach the disk: you'd have to hunt down every program's log location, move each one, and reconfigure each program — and any program you missed would still fill up the root disk. Separation of concerns onto different storage only works when "things that grow" all live in one assigned place.

### Before Rung 3
**Q:** Say the core sentence from memory. Then derive: containerd stores persistent image layers and also opens a runtime control socket — which top-level directory should each go under, and why are they different?

**A:** The sentence: "Linux presents everything — every disk, device, kernel fact, and remote share — as one single tree of names rooted at `/`, and each top-level directory has an assigned *purpose*, so you can predict where any file lives from what *kind* of thing it is." Image layers are *persistent state written by a running program* that must survive reboots, so they belong under `/var/lib` — hence `/var/lib/containerd`. The control socket is *volatile runtime state* — a handle that only means something while the process is alive and should vanish at boot — so it belongs under `/run` (a RAM-backed tmpfs, wiped on every reboot) — hence `/run/containerd/containerd.sock`. They differ because the FHS separates by lifetime and purpose: persistent state vs. what's-happening-right-now.

### Before Rung 4
**Q:** Draw the path-resolution walk for `/etc/kubernetes/pki`. Then: (1) why does `..` from `/` stay at `/`? (2) what generates `/proc/1/status`'s contents, and when? (3) why can't `cd` be an external `/usr/bin/cd`?

**A:** The walk: the kernel starts at the root inode `/` → reads that directory's name→inode table and looks up `etc` → gets `etc`'s inode (a directory) and looks up `kubernetes` → gets its inode and looks up `pki` → arrives at the `pki` directory inode and stops. (1) In the root directory, the `..` entry points back to the root's own inode — `/` is its own parent — so `cd ..` from `/` stays at `/`. (2) `/proc` is a virtual filesystem with zero bytes on disk; the kernel *generates* the contents at the moment you read the file, manufacturing PID 1's live state at read time. (3) The CWD is per-process kernel state; an external `/usr/bin/cd` would run as a *child* process, change its own CWD, and exit — its parent shell would be left standing exactly where it was. Only a builtin, running inside the shell process itself, can change the shell's CWD.

### Before Rung 5
**Q:** `ls`, `cat`, and `stat` all "look at a file" but read different things. Which reads the directory table, which reads the data blocks, and which reads the inode metadata?

**A:** `ls` reads the *directory* — the name→inode table — listing the entries it contains (and with `-l`, additionally `stat`-ing each entry for a compact metadata view). `cat` opens the file's inode and streams its *data blocks* — the actual content bytes — to your terminal. `stat` reads the *inode metadata* directly: size, owner, permissions, timestamps, inode number, block count — without touching the content at all. Same file, three different layers of the Rung 3 machinery: names, bytes, and metadata.

### Before Rung 6
**Q:** At Step 5, what does `-f` change about `tail`'s behavior at end-of-file, what kernel facility lets it wake only when the file changes, and where on disk does `kubectl logs` ultimately read from?

**A:** Without `-f`, `tail` hits end-of-file and exits; with `-f` it *stays open* and keeps reading past EOF, printing new bytes as they are appended. Rather than busy-looping, it registers an **inotify** watch — the kernel facility that notifies a process when a file changes — so it sleeps until the kernel wakes it on each new write. `kubectl logs` ultimately reads the per-container log files the kubelet maintains at `/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log` (with friendly symlinks in `/var/log/containers/`); the kubelet does this same `tail -f` trace on that file and streams the bytes back over the API.

### Before Rung 7
**Q:** Why can you move `/var/lib/containerd` onto a brand-new disk without reconfiguring containerd, while the equivalent on a drive-letter system would break it?

**A:** Because Linux decouples the *name* of a file from the *device* it lives on. containerd hardcodes the path `/var/lib/containerd`, and a path is just a route through the single tree rooted at `/` — it says nothing about which disk backs it. You mount the new disk at `/var` (or `/var/lib/containerd`) and the same path now transparently resolves onto the new filesystem; containerd never notices the seam. On a drive-letter system, the volume is *part of the path* (`C:\data` vs `D:\data`), so moving the data to a new disk changes its name, and anything that hardcoded the old path — as containerd hardcodes its state dir — breaks.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things (including mounting filesystems over live directories). For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Saskatoon: the script that only works from one desk" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-sas/app/data
echo "port=8123" | sudo tee /opt/lab-sas/app/data/config.txt >/dev/null
sudo tee /opt/lab-sas/app/run.sh >/dev/null <<'EOF'
#!/bin/bash
echo "config loaded: $(cat data/config.txt)"
EOF
sudo chmod 755 /opt/lab-sas/app/run.sh
```
**Situation:** A deploy helper "works on the author's machine": if you `cd /opt/lab-sas/app` first, `./run.sh` prints the config fine. But the scheduler runs it as `/opt/lab-sas/app/run.sh` from some other directory, and it dies with `cat: data/config.txt: No such file or directory`. The author insists "the file is right there next to the script!"

**Your task:** Explain where the kernel actually *started* resolving `data/config.txt` in the failing case (whose CWD?), then fix `run.sh` so it loads its config correctly no matter which directory it is launched from.

**Verify:**
```bash
cd /tmp && /opt/lab-sas/app/run.sh   # expected: "config loaded: port=8123" — even though CWD is /tmp
```

### 🟢 Scenario 2 — "Thunder Bay: the invisible disk hog" (Easy)
**Setup:**
```bash
mkdir -p /tmp/lab-tb/reports /tmp/lab-tb/.cache-lab
echo "Q3 summary" > /tmp/lab-tb/reports/q3.txt
touch /tmp/lab-tb/.labrc
dd if=/dev/zero of=/tmp/lab-tb/.cache-lab/blob.bin bs=1M count=120 status=none
```
**Situation:** A shared scratch area `/tmp/lab-tb` is flagged as consuming over 100 MB, but when the owner looks — `ls -l /tmp/lab-tb` — all they see is a tiny `reports` directory with one text file. They've filed a ticket claiming the disk-usage monitoring is broken.

**Your task:** Find what is really consuming the space (something `ls -l` doesn't show by default), remove the hog, and leave the legitimate `reports` data untouched.

**Verify:**
```bash
du -sk /tmp/lab-tb | awk '{print ($1<1024) ? "SOLVED" : "NOT YET"}'; cat /tmp/lab-tb/reports/q3.txt   # expected: SOLVED, then "Q3 summary" still intact
```

### 🟡 Scenario 3 — "Charlottetown: the report that fell behind the wall" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-cha/data
echo "quarterly numbers: 42" | sudo tee /opt/lab-cha/data/report.txt >/dev/null
sudo mount -t tmpfs -o size=64m tmpfs /opt/lab-cha/data
```
**Situation:** Yesterday `/opt/lab-cha/data/report.txt` existed — the analytics team read it. Today the directory is *empty*, yet `df` insists nothing was deleted and the disk has exactly as much data as before. Meanwhile a teammate mutters something about having "prepared a fast RAM disk for the new pipeline" in that area.

**Your task:** Figure out what is *really* at `/opt/lab-cha/data` right now (is it even the same filesystem as its parent?), explain where `report.txt` went, and bring it back — nothing about the file was ever deleted.

**Verify:**
```bash
findmnt /opt/lab-cha/data; cat /opt/lab-cha/data/report.txt   # expected: findmnt prints NOTHING (no separate fs mounted there) and the report prints "quarterly numbers: 42"
```

### 🟡 Scenario 4 — "Kamloops: the counter with amnesia" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-kam
sudo tee /opt/lab-kam/counter.sh >/dev/null <<'EOF'
#!/bin/bash
d=/run/lab-kam
mkdir -p "$d"
n=$(cat "$d/counter" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$d/counter"
echo "run count: $n"
EOF
sudo chmod 755 /opt/lab-kam/counter.sh
sudo tee /opt/lab-kam/reboot-sim.sh >/dev/null <<'EOF'
#!/bin/bash
rm -rf /run/lab-kam
echo "reboot simulated: /run contents gone"
EOF
sudo chmod 755 /opt/lab-kam/reboot-sim.sh
sudo /opt/lab-kam/counter.sh
```
**Situation:** A billing agent keeps a lifetime run-counter — and every single reboot it starts back at 1. The `reboot-sim.sh` script faithfully reproduces what a real reboot does to this box. The developer chose `/run/lab-kam/` for the counter file because "it was world-writable-ish and always there."

**Your task:** Using the FHS purpose rules from Rung 3A, explain *exactly* why `/run` guarantees this data loss (what kind of filesystem is it, and what's its lifetime rule?). Then fix `counter.sh` to keep its state in the FHS-correct directory for persistent program state, so the count survives "reboots."

**Verify:**
```bash
sudo /opt/lab-kam/counter.sh; sudo /opt/lab-kam/reboot-sim.sh; sudo /opt/lab-kam/counter.sh   # expected: the count AFTER the simulated reboot is higher than the count before it (e.g. "run count: 2" then "run count: 3")
```

### 🟠 Scenario 5 — "Brandon: the release chain with a missing link" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-bra/releases /opt/lab-bra/builds/build-4812
echo "release v4 OK" | sudo tee /opt/lab-bra/builds/build-4812/index.html >/dev/null
sudo ln -s ../builds/build-4711 /opt/lab-bra/releases/current-blue
sudo ln -s releases/current-blue /opt/lab-bra/current
```
**Situation:** The web tier serves whatever `/opt/lab-bra/current/index.html` resolves to — a blue/green pointer scheme built from symlinks. After last night's "cleanup of old builds," the site 404s: `cat /opt/lab-bra/current/index.html` says `No such file or directory`. Yet `ls -l /opt/lab-bra/current` looks perfectly healthy, and the new build `build-4812` is definitely on disk.

**Your task:** Walk the symlink chain hop by hop (`ls -l`, `readlink`, `namei -l`) and identify *which* hop dangles and why (careful: one target is a *relative* path — relative to what?). Then repair the chain — by re-pointing the broken link, not by copying files — so `current` serves the v4 build.

**Verify:**
```bash
cat /opt/lab-bra/current/index.html && readlink -f /opt/lab-bra/current   # expected: "release v4 OK" and a fully-resolved path ending in /opt/lab-bra/builds/build-4812
```

### 🔴 Scenario 6 — "Yellowknife: 200 MB that du swears doesn't exist" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-yk/data
sudo dd if=/dev/zero of=/opt/lab-yk/data/core-4211.dump bs=1M count=200 status=none
sudo mount -t tmpfs -o size=16m tmpfs /opt/lab-yk/data
echo "active-service-data" | sudo tee /opt/lab-yk/data/live.txt >/dev/null
```
**Situation:** The root filesystem fired a capacity alert: `df -h /` shows ~200 MB more used than yesterday, but `sudo du -xsh /opt /var /home /tmp` can't find it anywhere — every directory adds up small. There *is* a busy little tmpfs mounted at `/opt/lab-yk/data` serving a live service, and ops has made one thing crystal clear: **that tmpfs must not be unmounted, even for a second.**

**Your task:** Explain why `du` is blind here (what does a mount do to the files that were in the directory *before* it was mounted?). Then, without touching the live tmpfs mount, get a view of the root filesystem *underneath* all mounts, find the hidden 200 MB, and delete it.

**Verify:**
```bash
sudo mkdir -p /mnt/lab-yk-check && sudo mount --bind / /mnt/lab-yk-check && ls /mnt/lab-yk-check/opt/lab-yk/data/ && cat /opt/lab-yk/data/live.txt; sudo umount /mnt/lab-yk-check   # expected: the underneath view lists NO core-4211.dump (directory empty), while live.txt still prints "active-service-data" (tmpfs untouched)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Saskatoon: the script that only works from one desk"
**Solution:**
```bash
sudo tee /opt/lab-sas/app/run.sh >/dev/null <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "config loaded: $(cat data/config.txt)"
EOF
# (equally valid: use the absolute path /opt/lab-sas/app/data/config.txt in the cat)
```
**Why this works & what it teaches:** `data/config.txt` has no leading `/`, so the kernel's path walk (Rung 3C) starts at the **calling process's CWD** — which was the scheduler's directory, not the script's home. Relative paths resolve from where the *process stands*, not from where the script file lives. `cd "$(dirname "$0")"` moves the script's own process to its install directory first, making every relative reference stable (an absolute path achieves the same by starting the walk at the root inode instead). **Where people go wrong:** believing "next to the script" is a location the kernel knows about — it isn't; only CWD and `/` are starting points.

### Scenario 2 — "Thunder Bay: the invisible disk hog"
**Solution:**
```bash
ls -la /tmp/lab-tb            # reveals .cache-lab and .labrc — names starting with '.' are hidden by default
du -sh /tmp/lab-tb/.[!.]*     # .cache-lab is ~120M
rm -rf /tmp/lab-tb/.cache-lab
```
**Why this works & what it teaches:** `ls` hides any directory entry whose *name* starts with a dot — a pure convention, not a filesystem feature; the bytes are all still there in the name→inode table and `du` (which walks the table itself) counts them fine. `-a` shows the full table, resolving the "monitoring vs ls" contradiction (Rung 7, Prediction 2's `-a` lesson). **Where people go wrong:** trusting bare `ls` during a disk investigation — always `ls -la` or `du -a` when bytes are "missing," because dotfiles are exactly where caches hide.

### Scenario 3 — "Charlottetown: the report that fell behind the wall"
**Solution:**
```bash
findmnt /opt/lab-cha/data     # tmpfs is mounted HERE — the directory shows a different filesystem
sudo umount /opt/lab-cha/data
cat /opt/lab-cha/data/report.txt    # quarterly numbers: 42 — it was there all along
```
**Why this works & what it teaches:** A mount *grafts another filesystem onto a directory* (Rung 3B) — from that instant, path resolution crosses the seam into the new filesystem, and everything in the *underlying* directory becomes unreachable (shadowed), though not deleted. The teammate's tmpfs turned `/opt/lab-cha/data` into an empty RAM disk; unmounting removes the graft and the original ext4 contents reappear. This is why `df` never showed a deletion: no inode was freed. **Where people go wrong:** restoring "lost" files from backup on top of the *mount* — the copy lands in the tmpfs and evaporates on reboot while the originals still sit beneath.

### Scenario 4 — "Kamloops: the counter with amnesia"
**Solution:**
```bash
sudo tee /opt/lab-kam/counter.sh >/dev/null <<'EOF'
#!/bin/bash
d=/var/lib/lab-kam
mkdir -p "$d"
n=$(cat "$d/counter" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$d/counter"
echo "run count: $n"
EOF
```
**Why this works & what it teaches:** `/run` is a **tmpfs** — RAM-backed and wiped at every boot; its FHS-assigned purpose is *volatile runtime state* (sockets, PIDs), so storing a lifetime counter there guarantees amnesia by design (Rung 3A's four buckets). Persistent state written by a running program belongs in `/var/lib/<program>` — exactly why kubelet uses `/var/lib/kubelet` and containerd `/var/lib/containerd` for state but `/run/containerd` for its socket. **Where people go wrong:** choosing directories by convenience ("it was writable") instead of by *lifetime rule* — the FHS's whole value is that the directory name encodes the data's fate.

### Scenario 5 — "Brandon: the release chain with a missing link"
**Solution:**
```bash
namei -l /opt/lab-bra/current/index.html   # shows the chain and where it breaks
readlink /opt/lab-bra/current              # releases/current-blue
readlink /opt/lab-bra/releases/current-blue   # ../builds/build-4711  ← relative, resolved FROM /opt/lab-bra/releases → build-4711 is GONE
sudo ln -sfn ../builds/build-4812 /opt/lab-bra/releases/current-blue
cat /opt/lab-bra/current/index.html        # release v4 OK
```
**Why this works & what it teaches:** A symlink is a file whose *content is another path* (Rung 4), and a **relative** symlink target is resolved from the directory containing the *link*, not from your CWD — so `../builds/build-4711` means `/opt/lab-bra/builds/build-4711`, which the cleanup deleted while the link itself stayed perfectly "healthy"-looking (`ls -l` never validates targets). `namei -l` walks the chain hop by hop and marks the dangling component instantly. `ln -sfn` atomically re-points the pointer — the same pattern as Kubernetes' own `..data` symlink swap for ConfigMap updates. **Where people go wrong:** "fixing" it by copying build files over the link, which silently breaks the whole blue/green switch mechanism for the next release.

### Scenario 6 — "Yellowknife: 200 MB that du swears doesn't exist"
**Solution:**
```bash
df -h /; sudo du -xsh /opt        # confirm the disagreement: df sees the usage, du can't
findmnt | grep lab-yk             # a tmpfs is mounted at /opt/lab-yk/data
# Peek UNDER every mount by bind-mounting the root filesystem itself elsewhere:
sudo mkdir -p /mnt/lab-yk-under
sudo mount --bind / /mnt/lab-yk-under
sudo du -sh /mnt/lab-yk-under/opt/lab-yk/data     # there's the 200M — the shadowed dir
sudo rm /mnt/lab-yk-under/opt/lab-yk/data/core-4211.dump
sudo umount /mnt/lab-yk-under
```
**Why this works & what it teaches:** Files that lived in a directory *before* something was mounted on it still occupy blocks on the underlying filesystem, but path resolution can no longer reach them — `df` (which asks the filesystem for totals) and `du` (which walks reachable paths) disagree by exactly the shadowed amount. A **bind mount of `/`** creates a second pathway into the root filesystem where *no child mounts follow*, so `/mnt/lab-yk-under/opt/lab-yk/data` shows the real ext4 directory underneath while the production tmpfs stays mounted and untouched — the standard SRE trick for "df and du disagree" incidents. **Where people go wrong:** unmounting the live mount to look underneath (an outage), or trusting `du -xsh /` alone and concluding the kernel is lying.
