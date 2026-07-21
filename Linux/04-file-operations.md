# File Operations, Links & Finding Files
### Learning what a filename *really* is on Linux — deriving inodes, links, and `find` instead of memorizing flags

> This is the file-manipulation rung of your Linux-for-Kubernetes ladder. You already `kubectl apply` YAML all day; you `cp` and `mv` on autopilot. But you've probably never asked: *what is a filename, actually?* Why does a ConfigMap update itself atomically with symlinks? Why does `rm` on a running log file not free disk space? We climb from the pain → one core idea → the machinery (inodes) → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.

---

# RUNG 0 — The Setup

**What am I learning?**
How to create, copy, move, and delete files on Linux; what a *filename* really is under the hood (the **inode**); the difference between a **hard link** and a **symbolic link**; and how to *find* files across a filesystem with `find`, `which`, and `locate`.

**Why did it land on my desk?**
Three real tickets hit your queue this week:
1. "Before we upgrade the control plane, **back up `/etc/kubernetes/pki`**." (A `cp -r` job — but get the flags wrong and you copy the certs without their permissions.)
2. "A **CKS security audit** wants a list of every **SUID binary** on the worker nodes." (That's a `find -perm` job.)
3. "The app team says their **ConfigMap change didn't take effect** in the pod, then suddenly did — with no restart. Why?" (That's symlinks — the whole reason ConfigMap volume mounts update atomically.)

And underneath all three: on the control-plane node your `~/.kube/config` is typically a **copy of — or a symlink to — `/etc/kubernetes/admin.conf`** (kubeadm's setup step tells you to `cp` it, but plenty of admins symlink it instead). Either way you've been leaning on file-and-link machinery every day without seeing it.

**What do I already know about it?**
You know `ls`, `cp`, `mv`, `rm`, `mkdir`. You've deleted files and made directories thousands of times. What you *don't* have yet is the mental model of what sits *underneath* the filename — and without it, hard links, `rm` not freeing space, and atomic ConfigMap updates all feel like unrelated trivia. By the top of this ladder they'll be one idea seen from four angles.

---

# RUNG 1 — The Pain 🔥
### *Why does the inode / link machinery exist at all?*

Before you touch a command, sit with the problem. Naively, you'd design a filesystem like a dictionary: **the name IS the file.** "`/etc/hosts`" would be a box, and inside that box lives the bytes. Simple. So simple that early designers were tempted by it — and it breaks the moment you ask three questions.

### The three questions that break "name = file"

**1. "I want the same file to appear in two places."**
If the name *is* the file, then having `/usr/bin/python3` and `/usr/local/bin/python3` point at the *same* bytes is impossible — you'd have to store two full copies. Change one, the other goes stale. Every shared library, every dedup, every "same content, two paths" need is dead on arrival.

**2. "I'm renaming a 40 GB file."**
If the name *is* the file, renaming `bigfile` to `bigfile.old` means physically rewriting 40 GB under a new key. But you know `mv` on the same disk is *instant*. That instant-ness is a **clue**: the name and the data must be *separate things*, and `mv` is only touching the name.

**3. "Who's still using this file I just deleted?"**
Your kubelet has a log file open. Ops runs `rm kubelet.log` to reclaim space — and `df` shows **no space freed** until kubelet restarts. If name = file, deleting the name should vaporize the bytes instantly. It doesn't. Something is *counting references*, and the name is only one of them.

### What people did before / what breaks without this

There's no "before" era to nostalgize here — Unix got this right in 1969. The pain is what you'd suffer *if inodes didn't exist*: no shared files, slow renames, and a delete that could yank data out from under a running process and crash it. The inode design is the fix, and it's so foundational that **every capability in this whole document is a consequence of it.**

**Who feels this pain most?** You, the platform engineer, in exactly these moments:
- A disk fills to 100% but `du` says the files are small → **deleted-but-still-open** files (a running process holds them). Pure inode behavior.
- A ConfigMap update needs to be **atomic** — the app must never read a half-written config. Kubernetes solves this with symlinks, and if you don't understand symlinks you'll debug it blind.
- A `cp -r` of your CA keys that silently drops permissions → a broken, insecure cluster.

> **✅ Check yourself before Rung 2:** Why is renaming a 40 GB file instant, but *copying* it takes minutes? What does that tell you must be true about the relationship between a filename and the file's data?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — every command, link type, and quirk in this document can be *derived* from it:

> **A filename is not the file. The file is an inode (a numbered record of the data + metadata), and a filename is just a directory entry that points to an inode number — so many names can point to one inode, and deleting a name only removes data when the last pointer to the inode is gone.**

That's the whole trick. Read it twice. Now watch how much falls out of it:

- *"a filename is just a pointer to an inode"* → so **two names can share one inode**. That's a **hard link** (`ln`).
- *"deleting a name only frees data when the last pointer is gone"* → that's why `rm` on an open file **doesn't free space**: the open file descriptor is *also* a pointer. `rm` removed the *name*, not the last reference.
- *"the file is an inode... the name is a directory entry"* → so `mv` on the same disk just **rewrites the directory entry**. No data moves. Instant.
- *"many names → one inode"* → but what if you want a name that points to *another name* instead of an inode? That's a **symbolic link** (`ln -s`) — a different, weaker kind of pointer, and its weakness is exactly why ConfigMaps use it for atomic swaps.

Once you hold "the name is not the file," hard links, symlinks, instant renames, and stubborn disk usage stop being four facts to memorize and become one idea seen four ways.

> **✅ Check yourself before Rung 3:** Cover the sentence. Say it from memory. Then answer: if two filenames point to the same inode, and you `rm` one of them, is the data gone? Why or why not?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood now. There are four things to understand: **(A) the three-layer structure — directory entry → inode → data blocks; (B) hard links; (C) symbolic links and how they differ; (D) how `find` walks this structure.**

## (A) The three layers: name → inode → data

When you save `/home/eng/pod.yaml`, the filesystem stores **three separate things**:

```
THE THREE LAYERS OF A FILE  (whiteboard view)

  LAYER 1: DIRECTORY ENTRY            LAYER 2: THE INODE            LAYER 3: DATA BLOCKS
  (lives inside the directory)        (a numbered metadata record)  (the actual bytes on disk)

  ┌──────────────────────────┐        ┌─────────────────────────┐   ┌────────────────────┐
  │ directory: /home/eng      │       │  inode #131074           │   │ block 8801: "apiV" │
  │ ┌──────────┬───────────┐ │        │  ─────────────────────   │   │ block 8802: "ersi" │
  │ │  name    │ inode #   │ │   ┌───▶│  type:  regular file     │──▶│ block 8803: "on: " │
  │ ├──────────┼───────────┤ │   │    │  perms: rw-r--r--        │   │ block 8804: "v1…"  │
  │ │ pod.yaml │  131074   │─┼───┘    │  owner: eng (uid 1000)   │   └────────────────────┘
  │ │ .        │  131000   │ │        │  size:  412 bytes        │
  │ │ ..       │  130000   │ │        │  mtime: 2026-07-16 09:11 │
  │ └──────────┴───────────┘ │        │  LINK COUNT: 1  ◀── key! │
  └──────────────────────────┘        │  → points to data blocks │
                                      └─────────────────────────┘

  A DIRECTORY IS JUST A TABLE of (name → inode number) pairs. Nothing more.
  The inode holds EVERYTHING ABOUT THE FILE — except its name.
  The name lives ONLY in the directory entry. The inode doesn't know its own name(s).
```

Sear this in: **the inode does not contain the filename.** The name lives in the directory table. This one fact explains everything downstream. The inode holds type, permissions, owner, timestamps, size, a **link count**, and pointers to the data blocks. See the inode number and link count yourself with `ls -i` and `ls -l` (column 2 is the link count):

```bash
ls -li pod.yaml
# 131074 -rw-r--r-- 1 eng eng 412 Jul 16 09:11 pod.yaml
#  ^inode          ^link count = 1
```

## (B) Hard links — a second name for the same inode

A **hard link** is simply *another directory entry pointing at the same inode number*. There is no "original" and "copy" — both names are equal, first-class pointers to one inode. Making one **increments the inode's link count.**

```
HARD LINK: `ln pod.yaml backup.yaml`   (no -s)

  directory /home/eng                      inode #131074
  ┌──────────────┬─────────┐               ┌──────────────────────┐
  │ pod.yaml     │ 131074  │──┐            │ LINK COUNT: 2  ◀───── both names counted
  │ backup.yaml  │ 131074  │──┼───────────▶│ perms, owner, size…   │
  └──────────────┴─────────┘  │            │ → data blocks         │
                              (same #)      └──────────────────────┘

  • Both names are EQUAL. Neither is "the real one."
  • Edit through either name → both see the change (it's ONE file).
  • `rm pod.yaml` → link count drops 2→1. Data SURVIVES via backup.yaml.
  • Data blocks freed ONLY when link count hits 0.
```

**Two hard rules fall out of the machinery, not from arbitrary policy:**
1. **A hard link cannot cross filesystems.** Inode #131074 is only meaningful *within one filesystem*. A directory entry on `/data` (a different mount) can't point at an inode number that lives on `/`. The number would be ambiguous.
2. **You (normally) cannot hard-link a directory.** Allowing it would let you create loops in the directory tree that break `find`, `rm -r`, and every tree-walker. The kernel forbids it.

**The "deleted but still using space" mystery, solved:** an open **file descriptor** (a process holding the file open) is *also* a reference the kernel counts — think of it as an invisible link. `rm` removes the *name*; if a process still has the file open, the on-disk link count may hit 0 but the *open count* is still 1, so **the data blocks are not freed until that process closes the file (or dies).** This is exactly the kubelet-log-fills-the-disk incident.

## (C) Symbolic links — a pointer to a *name*, not an inode

A **symbolic link (symlink)** is a completely different animal. It is its *own* tiny file, with its *own* inode, whose entire contents are a **text string: a path to another file.** It does not point at an inode number — it points at a *name*, and the name is resolved fresh every time you follow it.

```
SYMLINK: `ln -s pod.yaml link.yaml`   (note the -s)

  directory /home/eng
  ┌──────────────┬─────────┐
  │ pod.yaml     │ 131074  │──────────────▶ inode #131074 (the real file)
  │ link.yaml    │ 131099  │──▶ inode #131099 (type: SYMLINK)
  └──────────────┴─────────┘        contents = the STRING "pod.yaml"
                                     │
                            follow ─┘ (kernel re-reads the string,
                                       then looks up "pod.yaml" AGAIN)

  `ls -l` shows:  link.yaml -> pod.yaml
```

The crucial contrasts, all derivable from "a symlink stores a *path string*":

| Question | Hard link | Symlink |
|---|---|---|
| What does it point at? | An **inode number** | A **path string (a name)** |
| Own inode? | No — shares the target's | Yes — its own tiny inode |
| Cross filesystems / disks? | ❌ No (inode #s are per-fs) | ✅ Yes (a path is just text) |
| Link to a directory? | ❌ No | ✅ Yes |
| If the target is deleted/renamed? | Data **survives** (still a real link) | **Dangles** — points at a name that's gone |
| Bumps target's link count? | ✅ Yes | ❌ No (target doesn't know it exists) |

**A symlink can break; a hard link cannot.** Delete `pod.yaml` and `link.yaml` becomes a **dangling symlink** pointing at a name that no longer resolves — `cat link.yaml` gives "No such file or directory." But a hard link, being an equal pointer to the inode itself, keeps the data alive. That very fragility is a *feature* Kubernetes exploits — see the trace.

## (D) How `find` walks all this

`find` doesn't consult a database — it **walks the directory tree live**, reading each directory table, `stat()`-ing each inode to read its metadata (type, size, mtime, permission bits), and testing your filters against that metadata. That's why `find` is always accurate but can be slow on huge trees. Its cousins trade accuracy for speed:

```
find /etc -name "*.conf"

  start at /etc ──▶ read directory table
     for each entry:
        stat() the inode  ──▶ metadata (type, perms, size, mtime)
        entry is a dir? ──▶ recurse into it
        name matches "*.conf"?  ──▶ if yes, print path
     ...repeat for the entire subtree, live, every run.

  `-name`  tests the directory-entry NAME
  `-type`  tests the inode's TYPE      (f=file, d=dir, l=symlink)
  `-perm`  tests the inode's PERM bits (e.g. -4000 = SUID)
  `-size`  tests the inode's SIZE
  `-mtime` tests the inode's MTIME
  `-exec`  runs a command per match, {} = the path found
```

`locate` is the opposite trade-off: it reads a **prebuilt database**. On Ubuntu 22.04 that's `plocate` (DB at `/var/lib/plocate/plocate.db`, refreshed by the `plocate-updatedb.timer` systemd timer); older Debian/Ubuntu and RHEL/CentOS use `mlocate` (DB at `/var/lib/mlocate/mlocate.db`, refreshed via a daily cron job). Blazing fast, but **stale** — a file created 10 minutes ago won't be in it until `updatedb` runs. `which` is narrower still: it only searches the directories in your **`$PATH`** for an executable. Three tools, one spectrum: `find` = live and thorough, `locate` = cached and fast, `which` = PATH-only.

> **✅ Check yourself before Rung 4:** Draw the three layers from memory (name → inode → data). Then: when you `rm` a file that a running process still has open, which layer's *count* is the reason the disk space isn't freed yet — and what event finally frees it?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now the jargon has somewhere to land. Every term below is just a label for a part of the picture you already drew.

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **inode** | A numbered on-disk record: metadata + pointers to data blocks. Holds everything about a file **except its name** | Layer 2 — the file itself |
| **inode number** | The unique ID of an inode *within one filesystem* (`ls -i`) | Layer 2; why hard links can't cross filesystems |
| **directory entry** | One `(name → inode #)` row inside a directory | Layer 1 — the name |
| **directory** | A file whose data blocks *are* a table of directory entries | Layer 1 |
| **data block** | A chunk of disk holding the file's actual bytes | Layer 3 |
| **link count** | Count of hard links (directory entries) pointing at an inode | The number in `ls -l` col 2; hits 0 → data freed |
| **hard link** | An additional directory entry pointing at an existing inode (`ln`) | Layer 1 → same Layer 2 |
| **symbolic link / symlink / soft link** | A tiny file whose contents are a *path string* (`ln -s`) | Its own Layer 2, pointing at a *name* |
| **dangling symlink** | A symlink whose target name no longer resolves | Symlink that outlived its target |
| **file descriptor (fd)** | A process's open handle to a file — an extra, in-memory reference | Why `rm` on an open file frees no space |
| **`touch`** | Create an empty file, or bump an existing file's timestamps | Makes a new inode + directory entry |
| **`mkdir -p`** | Make a directory, creating parents as needed, no error if it exists | Creates directory inodes along a path |
| **heredoc (`<<EOF`)** | Shell syntax feeding an inline block as stdin to a command | Redirect input; the K8s `apply -f -` trick |
| **`cp`** | *Copies* — makes a **new inode** with duplicated data | Brand-new Layer 2 + Layer 3 |
| **`cp -p`** | Copy **preserving** mode, ownership, and timestamps | Copies inode *metadata* too |
| **`mv`** | Rename: rewrites the directory entry (same-fs) or copy+delete (cross-fs) | Layer 1 only, when same filesystem |
| **`rm`** | Unlink: removes a directory entry, decrements link count | Removes a Layer-1 pointer |
| **`find`** | Live recursive walker that `stat()`s inodes and filters | Walks Layers 1 & 2 |
| **`locate` / `updatedb`** | Fast lookup from a prebuilt (possibly stale) name database | Cache of Layer-1 names |
| **`which`** | Finds an executable by scanning `$PATH` directories | PATH-scoped name lookup |
| **SUID bit (`-perm -4000`)** | A permission bit making a binary run as its *owner* | A perm bit in the inode; CKS audit target |

### The big unlock: which terms are the *same kind of thing*

New learners drown treating these as 20 unrelated words. Group them:

```
GROUP 1 — "The name" (Layer 1, all directory-entry things):
   directory entry = filename = hard link = what `ln`, `mv`, `rm` manipulate
   → A hard link is not special; EVERY filename is already a hard link (count starts at 1).

GROUP 2 — "The file itself" (Layer 2/3):
   inode + data blocks = the real file = what `cp` duplicates and `stat`/`ls -i` reveal

GROUP 3 — "Pointers that can break":
   symlink (points at a NAME) — breaks if the name vanishes
   fd on a deleted file (points at an INODE) — the ONE case where data outlives every name

GROUP 4 — "Finding names" (one spectrum, live → cached → scoped):
   find (live, thorough)  →  locate/updatedb (cached, fast, stale)  →  which ($PATH only)

GROUP 5 — "Making things":
   touch / mkdir -p / echo > / cat <<EOF  = create-an-inode-and-name in different flavors
```

The single most mind-bending item: **your everyday filename is *already* a hard link.** A "regular file" is just an inode with link count 1. `ln` doesn't create a special object — it adds a second, equally-ordinary name. There is no "original."

> **✅ Check yourself before Rung 5:** Someone says "I'll make a hard link so I have a backup of the original file." Why is the word "original" misleading here — and what does that reveal about what a filename actually is?

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Let's trace the exact thing behind Ticket #3 — **why a ConfigMap update reaches a running pod atomically, with no restart.** This is the highest-value symlink story in all of Kubernetes, and it uses *both* link types plus the `mv`-is-atomic fact.

**The setup:** a pod mounts a ConfigMap named `app-config` (key `settings.conf`) at `/etc/app/`. Inside the container, `/etc/app/settings.conf` is **not** a plain file — the kubelet built a small pyramid of symlinks. Here's the layout the kubelet creates in the volume:

```
INSIDE THE MOUNTED CONFIGMAP VOLUME  (what `ls -la /etc/app` really shows)

  /etc/app/
  ├── settings.conf        --symlink-->  ..data/settings.conf
  ├── ..data               --symlink-->  ..2026_07_16_09_11_20.847/
  └── ..2026_07_16_09_11_20.847/         (a REAL timestamped directory)
        └── settings.conf                (the REAL file, actual bytes)

  So a read of settings.conf follows TWO symlinks:
     settings.conf → ..data → ..2026_..._20.847/settings.conf → bytes
                     ▲
                     └── this single symlink is the ATOMIC SWITCH
```

Now trace what happens when you `kubectl edit configmap app-config` and change the value:

**Step 1 — API server stores the new ConfigMap.**
`kubectl` sends the edit; the change lands in **etcd**. Nothing has moved on the node yet.

**Step 2 — kubelet notices and syncs.**
The **kubelet** watches ConfigMaps consumed by its pods. It sees the new revision and prepares to update the volume — the on-disk directory that lives under `/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~configmap/app-config/`.

**Step 3 — kubelet writes a WHOLE NEW timestamped directory.**
It does **not** edit the existing file in place (that would risk the app reading a half-written file). Instead it creates a brand-new dir, e.g. `..2026_07_16_10_30_05.991/`, and writes the full new `settings.conf` inside it. The old `..2026_07_16_09_11_20.847/` is still there, untouched.

**Step 4 — the atomic switch: a symlink rename.**
The kubelet creates a temporary symlink `..data_tmp -> ..2026_07_16_10_30_05.991` and then does an **atomic `rename()`** of `..data_tmp` onto `..data` (this is the `mv`-is-just-a-directory-entry-rewrite fact from Rung 3). Because a same-directory rename is a single, indivisible kernel operation, at *no instant* does `..data` point at a half-built directory. One moment it points at the old dir; the very next, the new one.

**Step 5 — the app's next read follows the fresh path.**
The app reads `/etc/app/settings.conf` → follows the (unchanged) `settings.conf → ..data` symlink → but `..data` now resolves to the *new* timestamped dir → reads the new bytes. **No file handle broke, no restart happened, and the app never saw a partial file.**

**Step 6 — cleanup.**
The kubelet garbage-collects the old `..2026_07_16_09_11_20.847/` directory once nothing references it.

```
THE ATOMIC FLIP (the entire trick in one picture)

  BEFORE:  settings.conf → ..data → [ ..09_11_20 dir ]  (old value)
                                                          [ ..10_30_05 dir ] ← kubelet builds this fully, off to the side

  FLIP  :  rename(..data_tmp → ..data)   ← ONE atomic kernel op

  AFTER :  settings.conf → ..data → [ ..10_30_05 dir ]  (new value)
                                     the old dir is now unreferenced → GC'd

  Why symlinks? Because you can atomically re-point ONE symlink,
  but you CANNOT atomically overwrite a file's bytes.
```

This is why, in Ticket #3, the change "suddenly took effect with no restart": the app happened to re-read the file *after* the atomic flip. (And why sometimes it *seems* delayed — the kubelet sync period plus the app's own caching.) Every piece here is machinery from Rung 3: symlinks pointing at names, and rename being a cheap directory-entry operation.

> **✅ Check yourself before Rung 6:** At Step 4, why does Kubernetes flip a *symlink* instead of just overwriting `settings.conf` in place? What bad thing could the app observe if the kubelet edited the real file's bytes directly?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand links best by seeing exactly where each one stops working — and where a plain `cp` would have been the right call instead.

### `cp` vs hard link vs symlink — three answers to "I want this file over there"

```
"I have fileA. I want it accessible as fileB too." — THREE strategies:

  cp fileA fileB          →  NEW inode, NEW data blocks. A true independent copy.
                             Edit one, the other is UNAFFECTED. Uses 2x disk.

  ln fileA fileB          →  SAME inode, SAME data. Two equal names.
                             Edit one → both change (it's one file). ~0 extra disk.
                             Cannot cross filesystems. Cannot link a directory.

  ln -s fileA fileB       →  NEW tiny inode holding the STRING "fileA".
                             Edit via fileB → edits fileA. Uses ~0 disk.
                             Crosses filesystems, links directories.
                             BREAKS if fileA is deleted/renamed (dangles).
```

| Property | `cp` (copy) | `ln` (hard link) | `ln -s` (symlink) |
|---|---|---|---|
| Independent data? | ✅ Yes | ❌ Shared inode | ❌ Points at target |
| Extra disk used | Full size again | ~0 | ~0 (path string) |
| Edit propagates to other? | ❌ No | ✅ Yes | ✅ Yes |
| Survives deletion of source? | ✅ (it's separate) | ✅ (equal pointer) | ❌ Dangles |
| Cross filesystem / disk? | ✅ | ❌ | ✅ |
| Point at a directory? | ✅ (`cp -r`) | ❌ | ✅ |
| Bumps source link count? | n/a | ✅ | ❌ |

### When would I NOT use a link?

- **Backing up your PKI (Ticket #1): use `cp -r`, never a link.** A hard/soft link to `/etc/kubernetes/pki` isn't a backup — it's *the same data*. If the originals get corrupted, your "backup" corrupts with them. You want an **independent copy** (`cp -rp`, preserving perms — critical for private keys).
- **Cross-disk "link": you can't hard-link, and a symlink adds fragility.** If `/data` is a separate mount, `cp` the file or accept a dangle-prone symlink.
- **Config you want frozen at a point in time:** `cp`, so later edits to the source don't leak in.

**One-sentence "why this over that":**
> Use `cp` when you want an *independent* copy that survives on its own; use a **hard link** when you want a second equal name for the *same* data on the *same* filesystem; use a **symlink** when you need a redirect that can cross filesystems or point at a directory — and can tolerate breaking if the target moves.

> **✅ Check yourself before Rung 7:** Your teammate "backs up" the CA key with `ln -s /etc/kubernetes/pki/ca.key /backup/ca.key` and deletes the original during a migration. Explain, using the machinery, why the backup is now worthless — and which single command would have actually protected them.

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each is a *hypothesis you commit to first*, then verify. Predicting before running is what converts "I typed the command" into "I understand the system." Work in a scratch dir so nothing matters:

```bash
mkdir -p ~/ladder-fileops && cd ~/ladder-fileops
```

---

## Prediction 1 — Creating files: `touch`, `echo >`, `>>`, and heredoc

> **My prediction:** "`touch a.txt` makes an *empty* file (size 0). `echo hi > a.txt` *replaces* its contents. `echo bye >> a.txt` *appends*, so the file ends with two lines. And a `cat <<EOF` heredoc writes a multi-line block in one shot — *because* `>` truncates, `>>` appends, and the heredoc feeds everything up to `EOF` as input."

```bash
touch a.txt
ls -l a.txt                 # size 0 — an empty inode with a name
echo "hi"  > a.txt          # >  truncates then writes
echo "bye" >> a.txt         # >> appends
cat a.txt                   # hi \n bye  (two lines)

# Heredoc — write a whole pod manifest in one shot:
cat <<EOF > pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.27
EOF
cat pod.yaml                # the full manifest, verbatim
```

**Verify:** `a.txt` has exactly two lines (`hi`, `bye`); if `>>` had *replaced* instead of appended, you'd see only `bye` — that would mean you confused the two operators. `pod.yaml` contains the whole manifest. **The K8s payoff:** the exact same heredoc applies a manifest with no file at all — the `-f -` means "read the manifest from stdin":

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.27
EOF
# pod/nginx created
```

---

## Prediction 2 — Hard links share an inode; `rm` decrements, it doesn't destroy

> **My prediction:** "If I `ln original hardlink`, then `ls -li` shows *both names with the same inode number and a link count of 2*. If I then `rm original`, the data in `hardlink` **survives** and its link count drops to 1 — *because* a hard link is an equal pointer to the inode, and data is freed only when the count hits 0."

```bash
echo "important data" > original
ln original hardlink                 # second name, SAME inode
ls -li original hardlink
# 262145 -rw-r--r-- 2 eng eng 15 ... original    <- link count 2
# 262145 -rw-r--r-- 2 eng eng 15 ... hardlink    <- SAME inode #

rm original                          # remove ONE name
ls -li hardlink
# 262145 -rw-r--r-- 1 eng eng 15 ... hardlink    <- count now 1, data intact
cat hardlink                         # "important data" — still here
```

**Verify:** Same inode number on both lines, link count `2` → `1`, and `cat hardlink` still works after deleting `original`. If the data had vanished, your model of "the name is the file" survived and needs repairing — the file is the *inode*, and one pointer still remains.

---

## Prediction 3 — Symlinks break; hard links don't (the edge/failure case)

> **My prediction:** "If I make a symlink `ln -s target.txt slink` and then delete `target.txt`, the symlink becomes **dangling** and `cat slink` fails with 'No such file or directory' — *because* a symlink stores only the *path string* `target.txt`, and that name no longer resolves. A hard link, by contrast, would still work."

```bash
echo "payload" > target.txt
ln -s target.txt slink               # symlink stores the STRING "target.txt"
ln target.txt hlink                  # hard link to the SAME inode
ls -li target.txt slink hlink
# note: slink has its OWN inode # and shows "slink -> target.txt"

rm target.txt                        # delete the target NAME
cat hlink                            # "payload"  — hard link keeps data alive
cat slink                            # cat: slink: No such file or directory
ls -l slink                          # slink -> target.txt  (shown in red = dangling)
```

**Verify:** `hlink` still prints `payload`; `slink` errors and `ls -l` shows it pointing at a name that's gone. If `slink` had *also* survived, you've mixed up the two link types — the symlink's fragility is the whole reason it errored. **K8s tie-in:** this exact fragility, weaponized, is how ConfigMap volumes swap atomically (Rung 5) — and it's why your `~/.kube/config` symlink breaks if someone moves `admin.conf`:

```bash
ln -s /etc/kubernetes/admin.conf ~/.kube/config   # the classic kubeconfig symlink
ls -l ~/.kube/config                               # config -> /etc/kubernetes/admin.conf
```

---

## Prediction 4 — `cp -r` needs `-p` to preserve permissions (the PKI backup case)

> **My prediction:** "If I `cp -r` a directory of key files as root, the copies land with **default permissions and the copier's ownership/timestamps**, not the originals'. Adding `-p` **preserves** mode, owner, and mtime — *because* plain `cp` creates fresh inodes with default metadata, while `-p` copies the source inode's metadata too. For private keys this matters: a `600` key must not become world-readable."

```bash
# Simulate the PKI dir with a tightly-permissioned "key":
mkdir -p pki && umask 077 && echo "PRIVATE" > pki/ca.key && chmod 600 pki/ca.key
ls -l pki/ca.key                     # -rw------- (600)

cp -r pki backup-plain               # plain recursive copy
cp -rp pki backup-preserved          # -p preserves mode + owner + timestamps
ls -l backup-plain/ca.key            # perms/mtime may differ from source
ls -l backup-preserved/ca.key        # -rw------- and original mtime — identical
```

**Verify:** `backup-preserved/ca.key` keeps `-rw-------` and the original timestamp; the plain copy may show a *newer* mtime (and on a stricter setup could widen perms). The real command from Ticket #1 — run as root on the control-plane node — is:

```bash
sudo cp -rp /etc/kubernetes/pki /backup/pki-$(date +%F)
# -r = recurse the whole cert tree, -p = keep 600 on the private keys.
# Without -p you risk a "backup" whose keys are world-readable = a security finding.
```

If you predicted the plain `cp` was "good enough," this is your repair: for anything security-sensitive, **`-p` is not optional.**

---

## Prediction 5 — `find` the SUID binaries (the CKS audit case)

> **My prediction:** "`find /usr/bin -perm -4000 -type f` lists every **SUID** binary — files that run with their *owner's* privileges regardless of who launches them. Expected hits: `sudo`, `passwd`, `su`, `mount` — *because* `-perm -4000` matches inodes whose SUID bit is set, and `-type f` restricts to regular files. On a hardened node this list should be short and every entry justified."

```bash
find /usr/bin -perm -4000 -type f
# /usr/bin/sudo
# /usr/bin/passwd
# /usr/bin/su
# /usr/bin/mount ...

# The real CKS audit sweeps the whole filesystem:
find / -perm -4000 -type f 2>/dev/null
# 2>/dev/null hides "Permission denied" noise on dirs you can't enter.

# Other filters you'll pair with an audit:
find /etc -name "*.conf" -type f          # config files by name + type
find /var/log -size +100M                 # log files over 100 MB (disk pressure)
find /tmp -mtime +7 -type f               # files not modified in 7+ days
```

**Verify:** You get a short list dominated by well-known privileged tools. **The point of the audit:** an *unexpected* SUID binary (say a random `/tmp/backdoor`) is a red flag — an attacker's classic privilege-escalation plant. If `find` returned nothing at all, you likely mistyped the mode (it's `-4000`, and the leading `-` means "these bits at minimum," not "exactly these bits").

---

## Prediction 6 — `-exec` acts on each match; `which`/`locate` are the fast finders

> **My prediction:** "`find /tmp -name '*.tmp' -exec rm {} \;` deletes each matched file, running `rm` once per file with `{}` replaced by the path — *because* `-exec ... {} \;` invokes the command for every result. Separately, `which kubectl` prints its path from `$PATH` only, while `locate` searches a *prebuilt database* and may miss a file created seconds ago."

```bash
# Set up some throwaways:
mkdir -p /tmp/junk && touch /tmp/junk/a.tmp /tmp/junk/b.tmp /tmp/junk/keep.log
find /tmp/junk -name "*.tmp" -exec rm {} \;   # rm runs once per .tmp file
ls /tmp/junk                                   # only keep.log remains

# The finders spectrum:
which kubectl          # /usr/local/bin/kubectl  — PATH lookup only
whereis kubectl        # binary + man page + source locations
locate admin.conf      # fast, but from a CACHE — may be stale or empty
sudo updatedb          # refresh the locate database NOW
locate admin.conf      # now it appears (if updatedb has indexed it)
```

**Verify:** After the `-exec`, only `keep.log` is left — the `.tmp` files are gone, proving `-exec` ran per-match. `which` prints a single PATH entry; a freshly created file is *absent* from `locate` until `updatedb` runs, then present. If `locate` found a brand-new file *without* `updatedb`, either the daily timer just ran or you're misremembering — `locate` is a cache, and a cache is only as fresh as its last refresh.

> **Safety note on `rm -rf` and `rm -i`:** `rm -rf dir` deletes a directory tree with **no confirmation and no undo** — there is no recycle bin. Because `rm` removes the *name* and the kernel frees blocks when the link count hits 0, recovery is generally impossible. Two habits that save careers: `rm -i` (interactive — prompts before each delete) when unsure, and *never* interpolate an unset variable into an `rm -rf "$DIR/"` (if `$DIR` is empty you just typed `rm -rf /`). Test destructive `find` with `-print` before swapping in `-exec rm`.

### The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> A filename is only a directory-entry pointer to an inode (the real file), so many names can share one inode (hard link), a name can instead point at another name (symlink), and data is freed only when the last pointer — on-disk name *or* open file descriptor — disappears.

**Explain it to a beginner in 3 sentences:**
> 1. On Linux the file itself is an "inode" — a numbered record holding the data and all its metadata — while the filename you see is just a label in a directory that points at that inode, which is why renaming is instant and two names can share one file.
> 2. A *hard link* is a second equal name for the same inode (deleting one name keeps the data), whereas a *symbolic link* is a tiny file that just stores a *path string*, so it silently breaks if you move or delete what it points to.
> 3. Kubernetes leans on all of this constantly — ConfigMap mounts flip a symlink to update a running pod atomically without a restart, your kubeconfig is a symlink to `admin.conf`, backing up `/etc/kubernetes/pki` needs `cp -rp` to keep the keys' `600` perms, and a CKS audit is just `find / -perm -4000` walking inodes for SUID bits.

**Map of sub-capability → the one core idea ("the name is not the file"):**

```
touch / echo> / mkdir -p / heredoc → create a new inode + a directory-entry name
cp                                  → duplicate the inode + data (independent file)
cp -p                               → duplicate the inode's METADATA too (perms/owner/mtime)
mv (same fs)                        → rewrite ONLY the directory entry — data never moves
rm                                  → remove ONE directory-entry pointer; free blocks at count 0
ln (hard link)                      → add a second equal name to one inode (count +1)
ln -s (symlink)                     → a name that points at a NAME (breakable redirect)
"deleted but disk still full"       → an open fd is the last pointer; blocks freed on close
find -perm/-type/-mtime/-size       → walk names, stat() inodes, filter on inode metadata
find -exec                          → act on each matched inode/name
which / locate / updatedb           → find names fast: PATH-scoped / cached / cache refresh
```

Eleven rows, one idea: *the name is a pointer, the inode is the file.*

**Which rung will I most likely need to revisit hands-on?**
- **Rung 3C + Prediction 3 (symlink fragility).** It's easy to *say* "symlinks break," harder to feel it until you've made a dangling link and watched `cat` fail. Reproduce it once and it sticks.
- **Rung 5 (the ConfigMap atomic flip).** The `..data` symlink dance is the single most useful thing here for your day job — `kubectl exec` into a pod and run `ls -la` on a mounted ConfigMap to *see* the `..data` symlink and timestamped directory with your own eyes.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts
- [linux-philosophy](01-linux-philosophy.md) — "Everything is a file," file descriptors, and `/proc` — the wider frame the inode sits in
- [filesystem-navigation](03-filesystem-navigation.md) — the FHS and how to move around the tree these files live in
- [permissions-ownership](05-permissions-ownership.md) — the perm/owner bits stored *in the inode*, and the SUID bit your `find` audit hunts
- [storage-mounts](15-storage-mounts.md) — filesystems, mounts, and OverlayFS — why hard links can't cross a mount boundary
- [io-redirection-pipes](10-io-redirection-pipes.md) — `>`, `>>`, and heredocs in depth, the streams behind file creation
- [text-processing](09-text-processing.md) — pairing `find` with `grep`/`xargs` to search *inside* the files you locate

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why is renaming a 40 GB file instant, but copying it takes minutes? What must be true about the relationship between a filename and the file's data?

**A:** Renaming is instant because `mv` on the same filesystem never touches the 40 GB of data — it only rewrites the *directory entry*, the small (name → inode number) row in the directory table. Copying takes minutes because `cp` must create a brand-new inode and physically duplicate every data block. The instant-ness is the clue: the name and the data must be *separate things*. The filename is just a pointer stored in a directory; the data lives elsewhere (in the inode's data blocks), so an operation that changes only the pointer costs nothing no matter how big the file is.

### Before Rung 3
**Q:** Say the core sentence from memory. If two filenames point to the same inode and you `rm` one of them, is the data gone? Why or why not?

**A:** The sentence: "A filename is not the file. The file is an inode (a numbered record of the data + metadata), and a filename is just a directory entry that points to an inode number — so many names can point to one inode, and deleting a name only removes data when the last pointer to the inode is gone." No, the data is not gone. `rm` removes one directory entry, which decrements the inode's link count from 2 to 1. The other name is an equal, first-class pointer to the same inode, so the data blocks stay alive; they are freed only when the link count reaches 0 (and no process holds the file open).

### Before Rung 4
**Q:** Draw the three layers (name → inode → data). When you `rm` a file a running process still has open, which layer's count keeps the disk space allocated, and what event finally frees it?

**A:** The three layers: Layer 1, the *directory entry* — a (name → inode number) row in the directory's table; Layer 2, the *inode* — the numbered record holding type, perms, owner, size, timestamps, link count, and pointers to blocks (everything except the name); Layer 3, the *data blocks* — the actual bytes on disk. When you `rm` an open file, the on-disk link count (Layer 2) drops to 0, but the process's open *file descriptor* is an extra, in-memory reference the kernel also counts — an invisible link. Because that open count is still 1, the data blocks are not freed. The space is finally reclaimed when the process closes the file (or dies) — that close drops the last reference, and only then do the blocks free. This is the kubelet-log-fills-the-disk incident.

### Before Rung 5
**Q:** Someone says "I'll make a hard link so I have a backup of the original file." Why is "original" misleading, and what does that reveal about what a filename is?

**A:** "Original" is misleading because after `ln fileA fileB` there is no original and no copy — both names are equal, first-class directory entries pointing at the *same* inode; the inode doesn't even know its own names. It reveals that every ordinary filename is *already* a hard link (a regular file is just an inode with link count 1), and `ln` merely adds a second, equally-ordinary pointer. It's also not a backup: since both names share one inode and one set of data blocks, corrupting the data through either name corrupts "both" — a real backup needs an independent copy (`cp`).

### Before Rung 6
**Q:** At Step 4 of the ConfigMap trace, why does Kubernetes flip a *symlink* instead of overwriting `settings.conf` in place? What could the app observe if the kubelet edited the real file's bytes directly?

**A:** Because you can atomically re-point one symlink, but you cannot atomically overwrite a file's bytes. A same-directory `rename()` of `..data_tmp` onto `..data` is a single, indivisible kernel operation — just a directory-entry rewrite — so at no instant does `..data` point at a half-built directory: one moment it resolves to the old timestamped dir, the next moment to the new one. If the kubelet instead edited `settings.conf`'s bytes in place, an app reading mid-write could observe a *half-written* config — part old value, part new — and crash or misbehave on the torn file. Building the complete new directory off to the side and flipping the `..data` symlink guarantees the app only ever sees a fully-old or fully-new file.

### Before Rung 7
**Q:** A teammate "backs up" the CA key with `ln -s /etc/kubernetes/pki/ca.key /backup/ca.key`, then deletes the original during a migration. Why is the backup worthless, and which command would have protected them?

**A:** A symlink is its own tiny inode whose entire contents are the *path string* `/etc/kubernetes/pki/ca.key` — it holds none of the key's data and doesn't even bump the target's link count. When the original name was deleted, its inode's link count hit 0 and the kernel freed the data blocks; the symlink is now *dangling*, pointing at a name that no longer resolves, so reading `/backup/ca.key` returns "No such file or directory." The command that would have protected them is `sudo cp -rp /etc/kubernetes/pki /backup/...` (for the single file, `cp -p`): `cp` creates an independent inode with its own duplicated data blocks that survives deletion of the source, and `-p` preserves the `600` mode, owner, and timestamps so the private key doesn't end up with widened permissions.
