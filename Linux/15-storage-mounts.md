# Storage, Filesystems & Mounts, Climbed the Ladder 🪜
### Learning how Linux turns raw disks into one navigable tree — and why every container image is just OverlayFS

> This is your storage guide rebuilt on the Learning Ladder framework. Instead of leading with `mount` and `df`, we climb from **why filesystems and mounts exist** → **the one core idea** → **the machinery** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every command lives at the TOP of the ladder (Rung 7). You'll understand *what each one does to the machinery* — the block layer, the VFS, the mount table, the OverlayFS copy-up — before you run it.

---

# RUNG 0 — The Setup

**What am I learning?**
How Linux takes raw storage (a disk, a partition, or even RAM) and makes it appear as directories you can `cd` into — and specifically the mechanism (**OverlayFS**) that makes container images and container writable layers work.

**Why did it land on my desk?**
A node in your Kubernetes cluster went `NodeHasDiskPressure`. The kubelet started **evicting pods** to reclaim space, and `df -h` showed `/var/lib/containerd` at 96%. Your lead asked three things: *(1) what is actually eating the disk, (2) why is a container's `df` output different from the host's, and (3) when a Secret is mounted into a pod, where does it physically live?* You can `kubectl` your way around all day, but these questions are all **Linux storage questions**, and you've been treating the node's filesystem as a black box.

**What do I already know about it?**
You know `df -h` shows disk usage and `du` measures directory sizes. You've seen `/var/lib/containerd` and `/var/lib/kubelet` in error messages. You know containers have "layers" and "images," and that PersistentVolumes exist. What you *don't* have yet is a mental model connecting the disk → the filesystem → the mount tree → the overlay that a running container actually reads from.

---

# RUNG 1 — The Pain 🔥
### *Why do filesystems and mounts exist at all?*

Before you run a single `mount`, sit with the problem. A disk, at the hardware level, is not files and folders. It is a dumb linear array of fixed-size blocks — sector 0, sector 1, sector 2, ... a few billion of them. That's it. No names, no directories, no "this file is 4KB starting at sector 918273."

### The problem that forced filesystems into existence

If all you have is a numbered array of blocks, then to store your `config.yaml` you'd have to personally remember: "it starts at block 918273 and is 3 blocks long." Now store a million files and let them grow and shrink. You'd need a bookkeeping system that tracks *which blocks belong to which named file, how files nest into directories, who owns them, and which blocks are free.* That bookkeeping system **is a filesystem** (ext4, xfs). It's the layer that turns "block 918273" into `/etc/config.yaml`.

```
THE RAW TRUTH UNDERNEATH EVERYTHING

Hardware:   [blk0][blk1][blk2][blk3] ... [blk 4 billion]   ← dumb array
                        │
                A filesystem imposes structure on it:
                        │
Software:   /etc/config.yaml (owner root, 3 blocks, at 918273...)
            /home/you/notes  (owner you, 1 block, at 44...)
```

### The *second* pain: many disks, one tree

Okay, one disk now has a filesystem. But a real machine has **several** storage devices: the root SSD, a data disk, a USB stick, a RAM disk, a network volume. Windows solved this by giving each one a letter (`C:`, `D:`, `E:`). Linux made a bolder choice: **there are no drive letters. There is ONE tree, rooted at `/`, and you graft each additional filesystem onto a folder inside it.** That grafting operation is called a **mount**. Without mounts, you'd be back to "which drive is my data on?" — with mounts, everything is just a path under `/`.

### What breaks without this, and who feels it

- Without **filesystems**: no named files, period. You cannot save anything meaningfully.
- Without **mounts**: you could only ever use one storage device, and you'd need drive letters or manual block math for the rest.
- Without **OverlayFS** (the special one this guide builds toward): every container would need a full private copy of its entire root filesystem (hundreds of MB to GB) on disk. Ten pods from the same image = ten full copies. Startup would be slow and disk would vanish. OverlayFS is what lets 10 containers *share* one read-only image and each keep only its own tiny changes.

**Who feels this pain most?** You — the platform engineer — at 3 AM when a node is at `DiskPressure`. Because the moment you ask "what's using the disk and why does the container see something different than the host," you are standing exactly where filesystems, mounts, and OverlayFS meet.

> **✅ Check yourself before Rung 2:** In one breath — why can't the kernel just hand your program raw disk blocks and let the program remember where its files are? (Hint: think about a million files, growing and shrinking, owned by different users.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this exact sentence — the rest of Linux storage can be *derived* from it:

> **A filesystem turns a block device into a tree of named files, and a *mount* grafts that tree onto a directory in the one global tree rooted at `/` — so "everything is a path under `/`," no matter which device, RAM, or overlay actually holds the bytes.**

That's the whole trick. Three nouns: **block device** (the bytes), **filesystem** (the structure), **mount** (the graft point). One tree.

### Why this sentence lets you derive the rest

Watch how much falls out of it:

- *"turns a block device into a tree"* → you need a **filesystem type** (ext4/xfs) to define *how* the structure is laid out. Different types, same job.
- *"grafts onto a directory"* → that directory is a **mount point**. Whatever was there before is hidden while the mount is active.
- *"no matter which device, RAM, or overlay"* → the source doesn't have to be a real disk. It can be **RAM** (that's **tmpfs**), or **another directory** (that's a **bind mount**), or a **stack of directories** (that's **OverlayFS**). Same graft operation, exotic sources.
- *"everything is a path under `/`"* → this is why a container can be handed a Secret at `/etc/secret` and never know it's really a tmpfs, or why a PersistentVolume just *appears* at a path in the pod. **The pod only ever sees a path; the kernel decides what's behind it.**

Once you see that **mount is one universal graft operation and the only thing that varies is *what you graft*** (a disk, RAM, a directory, an overlay), the entire topic collapses into one pattern applied five ways.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then answer: if a container reads `/etc/config/app.conf` and it works, what are the *three* different things that path could physically be backed by, and does the container's code care which?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> This section explains how a computer turns "raw storage hardware" into the tidy folders-and-files world you see. Four ideas, in order.
>
> - **(A) The delivery chain from disk to folder.** When a program asks for a file, the request passes down through layers, like a request in a big library. At the top sits a universal front desk (called VFS — the virtual file system) that doesn't know or care how any shelf is organized; it just checks "which department handles this address?" and forwards the request. The department (a filesystem driver — the software that knows one particular shelving scheme) looks up the file's index card (an **inode** — the record holding a file's owner, size, and where its contents physically live; notably, the file's *name* is not on the card — names live in folder listings that point at card numbers). At the bottom, warehouse staff fetch the actual boxes of data from the physical drive. Because of the universal front desk, programs never need to know what kind of shelf their files sit on.
>
> - **(B) The graft list (mount table).** A computer shows you ONE folder tree, but different branches of that tree can be served by entirely different storage. "Mounting" is grafting: attach a whole drive (or something else) onto an ordinary folder, and from then on everything under that folder comes from the graft. The computer keeps a live list of all current grafts. Each graft can carry house rules ("read-only," "no running programs from here") that even the administrator can't sidestep. The list is forgotten at shutdown, so a settings file tells the machine which grafts to redo at every startup.
>
> - **(C) Two unusual things you can graft.** You can graft a folder made of pure short-term memory (RAM) — blazing fast, but its contents vanish on restart; Kubernetes uses this for secrets so they never touch a disk. And you can graft an *existing* folder onto a second location (a "bind mount") — like two doorways into the same room: not a copy, the very same files seen from two paths.
>
> - **(D) The layered see-through stack (OverlayFS) — how container images work.** Imagine a stack of transparencies on a projector: several locked, read-only sheets at the bottom (the container image), one blank writable sheet on top, and you view them all merged from above. Reading finds the topmost version of anything. Writing to a locked sheet is impossible — so the system first *copies* that item onto the top sheet, then edits the copy ("copy-up"). "Deleting" a locked item just places an opaque sticker over it. That's why ten containers can share one image cheaply (each keeps only its own top sheet), why a container can't damage its image, and why a container's own changes vanish when it's thrown away — the top sheet goes in the bin, which is exactly why real data needs separately grafted storage (volumes).

*Now the original technical deep-dive — the same ideas, in precise form:*

We open the hood now. There are four things to understand: **(A) the stack from disk to path, (B) the mount table — the graft list, (C) the exotic sources — tmpfs and bind, and (D) OverlayFS in depth, because that IS your container images.**

## (A) The stack: from dumb blocks to a path you can `cd` into

Every file access travels through layers. From the bottom up:

```
        WHAT HAPPENS WHEN YOU open("/var/lib/etcd/x")

 ┌─────────────────────────────────────────────────────────┐
 │  Your app / kubelet / etcd:  open("/var/lib/etcd/x")     │
 └───────────────────────────┬─────────────────────────────┘
                             ▼
 ┌─────────────────────────────────────────────────────────┐
 │  VFS  (Virtual File System)                              │
 │  The kernel's universal switchboard. It doesn't know     │
 │  ext4 from xfs from overlay — it just asks "who is       │
 │  mounted at the longest matching prefix of this path?"   │
 └───────────────────────────┬─────────────────────────────┘
                             ▼   (routes to the right driver)
 ┌─────────────────────────────────────────────────────────┐
 │  Filesystem driver:  ext4 / xfs / overlay / tmpfs        │
 │  Knows the on-disk (or in-RAM) layout. Translates        │
 │  "file x" → "these specific blocks."  Uses INODES:       │
 │  an inode = the metadata record for one file (owner,     │
 │  perms, size, timestamps, and pointers to its blocks).   │
 │  The FILENAME is NOT in the inode — it lives in the      │
 │  directory, which maps name → inode number.              │
 └───────────────────────────┬─────────────────────────────┘
                             ▼
 ┌─────────────────────────────────────────────────────────┐
 │  Block layer + device driver                             │
 │  Schedules reads/writes of actual sectors on /dev/sda2   │
 └───────────────────────────┬─────────────────────────────┘
                             ▼
 ┌─────────────────────────────────────────────────────────┐
 │  The physical device: SSD / NVMe / virtual disk          │
 └─────────────────────────────────────────────────────────┘
```

The crucial insight: **VFS is a router.** It sits above every filesystem and presents one uniform interface (`open`, `read`, `write`) to apps. That's *why* an app can read a file without knowing or caring whether it's on ext4, xfs, RAM, or an overlay — VFS hides the difference. This is the kernel-level expression of "everything is a file."

A **block device** is the kernel's handle to that dumb sector array. You see them in `/dev`: `/dev/sda` (whole disk), `/dev/sda1` (first partition). `lsblk` (list block devices) prints this tree.

## (B) The mount table: the list of grafts

The kernel keeps a live, in-memory list: *"which filesystem is grafted at which directory."* That list is the **mount table**, and you can read it raw at `/proc/mounts` (or the friendlier `mount` command, or `findmnt`).

```
   THE ONE TREE, with grafts (mounts) shown as ┣━►

   /                       ← root fs (ext4 on /dev/sda2)
   ├── etc/
   ├── home/
   ├── var/
   │   └── lib/
   │       ├── containerd/  ┣━► big data lives here (maybe its own disk)
   │       ├── kubelet/     ┣━► pod volumes get grafted UNDER here
   │       └── etcd/
   ├── mnt/
   │   └── data/            ┣━► /dev/sdb (a second disk) mounted here
   ├── boot/                ┣━► often /dev/sda1 (separate)
   ├── proc/                ┣━► proc (virtual, kernel state)
   ├── sys/                 ┣━► sysfs (virtual)
   └── dev/                 ┣━► devtmpfs (virtual, the device nodes)

   Rule: mount /dev/sdb at /mnt/data, and from then on every path
   under /mnt/data is served by /dev/sdb's filesystem. Whatever
   files were in the /mnt/data folder BEFORE are hidden (not deleted)
   until you umount.
```

A **mount point** is just an ordinary directory chosen to be the graft site. **Mount options** ride along with each graft and constrain it: `ro` (read-only), `rw` (read-write), `noexec` (files here may not be executed), `nosuid`, `nodev`. These are enforced by the kernel at the VFS layer, so even root obeys a `ro` mount until it's remounted.

**How mounts survive a reboot:** the kernel forgets its mount table on shutdown. `/etc/fstab` (filesystem table) is the on-disk config file listing mounts that should be re-established at boot. `mount -a` reads `/etc/fstab` and mounts everything in it that isn't already mounted — which is exactly what systemd does during startup.

## (C) The exotic sources: tmpfs and bind mounts

The graft operation doesn't care what it grafts. Two important non-disk sources:

**tmpfs** — a filesystem that lives entirely in **RAM** (and swap). Nothing touches a disk. It's fast and *volatile* — reboot and it's gone. `mount -t tmpfs`. This is what Kubernetes uses for **Secret volumes** (secrets should never hit disk) and for `emptyDir` with `medium: Memory`.

**bind mount** — grafts an *existing directory* onto *another* path. No new filesystem; you're making the same files visible at a second location. `mount --bind /src /dst`. After this, `/src` and `/dst` are two windows onto the identical inodes. This is how Kubernetes exposes a **hostPath** volume and how **ConfigMap** files get projected into a container.

```
  BIND MOUNT: same inodes, two paths

  /data/real/  ──┐
                 ├── (both point at the SAME underlying inodes)
  /mnt/view/  ───┘
  A write via either path is seen via the other. It is NOT a copy.
```

## (D) OverlayFS — the mechanism behind every container image

This is the one to slow down on, because **this is literally how your container images and running containers work on the node.**

OverlayFS is a **union filesystem**: it stacks multiple directories and presents them as one merged directory. Four roles:

- **lowerdir** — one or more **read-only** layers, stacked. (You can have many, colon-separated.) *These are your container image layers.*
- **upperdir** — one **read-write** layer on top. All changes go here. *This is the container's writable layer.*
- **workdir** — an empty scratch directory OverlayFS needs internally to stage atomic operations. Must be on the same filesystem as upperdir. You never touch it.
- **merged** — the mount point where the unified view appears. *This is what the container sees as its `/`.*

```
        OVERLAYFS: many read-only layers + one writable layer

   merged/  (what the container sees as "/")   ← the mount point
   ┌───────────────────────────────────────────────────────┐
   │   app.conf   binary   libc.so   /etc/passwd   newfile  │
   └───────────────────────────────────────────────────────┘
        ▲ unified view, computed top-down on every lookup
        │
   ┌────┴──────────── upperdir (READ-WRITE) ────────────────┐
   │  newfile        (created in container)                 │  ← container's
   │  app.conf'      (MODIFIED copy — see "copy-up" below)  │    writable layer
   └───────────────────────────────────────────────────────┘
   ┌───────────────── lowerdir 2 (READ-ONLY) ───────────────┐
   │  app binary, app.conf (original)                       │  ← image layer
   └───────────────────────────────────────────────────────┘
   ┌───────────────── lowerdir 1 (READ-ONLY) ───────────────┐
   │  base OS: libc, /etc/passwd, /bin/sh ...               │  ← base image layer
   └───────────────────────────────────────────────────────┘
```

**How a lookup works:** when the container opens a file, OverlayFS searches **top-down**: upperdir first, then each lowerdir. The first hit wins. So a file in upperdir *shadows* the same-named file in a lower layer.

**Copy-up — the single most important OverlayFS behavior.** The lowerdirs are read-only. So what happens when the container *modifies* a file that only exists in a lowerdir?

```
   COPY-UP ON FIRST WRITE

   Container does:  echo "x" >> /etc/app.conf
                    (app.conf currently exists ONLY in a lowerdir)

   1. OverlayFS sees the file is in a read-only lower layer.
   2. It COPIES the entire file up into upperdir first.   ← "copy-up"
   3. THEN applies the write to the upper copy.
   4. Future reads find the upper copy first → they see the change.
   The lowerdir original is untouched (still shared with other containers).
```

This is why:
- **Ten containers from one image share the lowerdirs** (read-only, identical) and each only stores its *own changes* in its own upperdir. Massive disk savings.
- **A container "modifying a system file" never affects the image** — it copy-ups a private version.
- **Deleting a lower-layer file** doesn't remove it (can't — it's read-only); OverlayFS writes a special **whiteout** marker in upperdir that hides it. The file is gone *from the merged view* but still on disk in the lower layer.
- **The writable layer is ephemeral.** Kill the container and its upperdir is discarded — which is exactly why data in a container's own filesystem doesn't survive a restart, and why you need volumes.

On a real node, containerd stores all of this under **`/var/lib/containerd`** (specifically the `io.containerd.snapshotter.v1.overlayfs` directory), and a running container's rootfs shows up in `mount` as an `overlay` type mount. That is the whole reason a container's `df` looks nothing like the host's: **the container's `/` is an overlay mount, not the host disk.**

> **✅ Check yourself before Rung 4:** Draw the OverlayFS stack from memory. Then: a container edits `/etc/hosts` (which came from the image, a lowerdir). Walk through exactly what the kernel does to the bytes, and explain why the other nine containers from the same image don't see the change.

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now the jargon has somewhere to land. Every term is just a label for a part of the picture you already understand.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Block device** | Kernel handle to a raw sector array (e.g. `/dev/sda`) | Bottom of the stack (Rung 3A); listed by `lsblk` |
| **Partition** | A named slice of one disk (`/dev/sda1`) | A block device carved from a bigger one |
| **Filesystem** | The bookkeeping that maps blocks → named files | The driver layer (ext4/xfs) |
| **Filesystem type** | The *format* of that bookkeeping (ext4, xfs, tmpfs, overlay) | Which driver VFS routes to |
| **Inode** | The metadata record for one file (owner, perms, block pointers) | Inside the filesystem driver; filename NOT stored here |
| **VFS** | Kernel's universal switchboard above all filesystems | The router that hides fs differences |
| **Mount** | Grafting a filesystem onto a directory | The core operation of the whole topic |
| **Mount point** | The directory chosen as the graft site | Where a filesystem attaches to the tree |
| **Mount table** | Live kernel list of all current grafts | Read via `/proc/mounts`, `mount`, `findmnt` |
| **Mount options** | Constraints on a mount (`ro`, `noexec`, `nosuid`) | Enforced at VFS on every access |
| **/etc/fstab** | On-disk config of mounts to restore at boot | Consumed by `mount -a` / systemd |
| **tmpfs** | A filesystem backed by RAM (+swap), volatile | An exotic mount source (Rung 3C) |
| **Bind mount** | Grafting an existing dir onto a second path | Same inodes, two paths (Rung 3C) |
| **OverlayFS / overlay** | Union fs stacking read-only + read-write dirs | The container-image mechanism (Rung 3D) |
| **lowerdir** | Read-only layer(s) in an overlay | = container **image layers** |
| **upperdir** | The single read-write layer | = container **writable layer** |
| **workdir** | OverlayFS's internal scratch dir | Staging for atomic ops; never touched |
| **merged** | The unified mount point of an overlay | What the container sees as `/` |
| **Copy-up** | Copying a file up to upperdir before writing it | The write path of OverlayFS |
| **Whiteout** | A marker that hides a lower-layer file | How "delete" works in overlay |
| **snapshotter** | containerd's component managing overlay layers | Lives under `/var/lib/containerd` |

### The big unlock: which terms are the *same kind of thing*

New learners drown because they think these are 20 unrelated concepts. Group them:

```
GROUP 1 — "The raw bytes" (physical, bottom of stack):
   Block device = partition = /dev/sdX = what lsblk shows

GROUP 2 — "The structure imposed on bytes":
   Filesystem = filesystem type (ext4/xfs) = the driver = uses inodes

GROUP 3 — "The graft operation" (ONE verb, many sources):
   mount a DISK      → mount /dev/sdb /mnt/data
   mount RAM         → mount -t tmpfs ...        (Secrets, emptyDir Memory)
   mount a DIRECTORY → mount --bind ...          (hostPath, ConfigMap)
   mount a STACK     → mount -t overlay ...      (every container image)
   They are ALL "mount." Only the source differs.

GROUP 4 — "The overlay pieces" (all just directories on the host):
   lowerdir + upperdir + workdir + merged
   = image layers + writable layer + scratch + the view

GROUP 5 — "The persistence config":
   /etc/fstab + mount -a  (restore grafts at boot)
```

The single biggest realization: **tmpfs, bind, and overlay are not three different features — they are the *same mount operation* pointed at three different kinds of source.** Kubernetes volumes are almost entirely "which source do we graft, and where."

> **✅ Check yourself before Rung 5:** Without looking — a Secret volume, a hostPath volume, and a container image's root all reach the app as a path. For each, name the mount *source* (RAM? a directory? a stack of directories?) and the mount *type*.

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Let's trace the exact thing behind your node incident: **a pod starts from an image, then writes a file, then reads a mounted Secret.** This single trace touches OverlayFS, copy-up, and tmpfs — most of the topic at once. Assume containerd on an Ubuntu node with ext4 root.

**Step 1 — The image is already unpacked into layers.**
When the image was pulled, containerd's **overlayfs snapshotter** unpacked each image layer into its own directory under `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/<N>/fs`. These become the **lowerdirs**. They are read-only and shared by every container using this image.

**Step 2 — kubelet asks containerd to create the container.**
containerd allocates a fresh **upperdir** and **workdir** for this specific container (also under `/var/lib/containerd`), then performs an `overlay` mount: `lowerdir=<image layers>, upperdir=<this container's rw>, workdir=<scratch>`, with the **merged** directory as the mount point.

**Step 3 — The merged view becomes the container's `/`.**
Combined with mount namespaces (see [namespaces](13-namespaces.md)), that merged overlay is pivoted to be the container's root filesystem. The app inside sees a normal-looking `/` — `/bin`, `/etc`, `/lib`. It has no idea it's an overlay of shared read-only layers.

**Step 4 — The app writes a log file: `/app/run.log`.**
The write reaches VFS → routed to the **overlay** driver. `/app/run.log` is new, so it's created directly in **upperdir**. No copy-up needed (nothing to copy). Nine other containers from the same image never see this file — it's in *this* container's upperdir only.

**Step 5 — The app appends to `/etc/nginx/nginx.conf` (which came from the image).**
Now overlay must **copy-up**: the file exists only in a lowerdir (read-only). OverlayFS copies the whole file up into upperdir, then applies the append to the upper copy. From now on, reads of that path find the upper copy first. The image's original is untouched and still shared.

**Step 6 — kubelet mounts a Secret at `/etc/secret`.**
Separately, kubelet created a **tmpfs** (RAM-backed) mount for the Secret volume and populated it with the secret files, then the container runtime bind-mounted it into the container at `/etc/secret`. The bytes live in RAM, never on the node's disk — so a stolen disk yields no secrets.

**Step 7 — The app reads `/etc/secret/token`.**
VFS sees `/etc/secret` is a longer-matching mount than `/` → routes to the **tmpfs** driver → returns bytes from RAM. The app just called `open()`; it has no idea one path came from an overlay and the next from RAM.

**Step 8 — The pod is deleted.**
containerd unmounts the overlay. The **upperdir is discarded** — `run.log` and the modified `nginx.conf` vanish (ephemeral writable layer). The tmpfs Secret mount is torn down, freeing the RAM. The read-only image lowerdirs remain, ready for the next container.

```
   THE TRACE (one pod's storage life)

   image pulled ──► layers unpacked ──► /var/lib/containerd/.../snapshots/*/fs
                                          = LOWERDIRS (ro, shared)
                                              │
   kubelet+containerd: overlay mount ────────┤ + fresh UPPERDIR + WORKDIR
                                              ▼
                                        merged/  ── becomes container "/"
                                          │
    write /app/run.log  ─────────────►  lands in UPPERDIR (new file)
    append /etc/nginx.conf ──────────►  COPY-UP lower→upper, then write
    read /etc/secret/token ──────────►  VFS routes to tmpfs (RAM), not disk
                                          │
    pod deleted ─────────────────────►  UPPERDIR discarded (ephemeral)
                                        tmpfs freed; LOWERDIRS survive
```

> **✅ Check yourself before Rung 6:** At Step 5, why did the write trigger a copy but the write at Step 4 didn't? And at Step 8, name exactly which bytes are destroyed and which survive — and connect that to why a container losing its data on restart is *expected*, not a bug.

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

### The alternative to OverlayFS: full copies (and to mounts: drive letters)

**Before union filesystems**, giving each container its own root meant one of two bad options: **(a)** a full copy of the entire root filesystem per container (slow to create, enormous on disk), or **(b)** device-mapper thin snapshots (block-level copy-on-write — workable but heavier, needs a dedicated block device/thin pool, and copies at block granularity instead of file granularity). OverlayFS won because it's **file-level copy-on-write with zero special setup** — just directories on your existing ext4/xfs.

And the deeper contrast for mounts themselves: **Windows-style drive letters vs. the single Linux tree.** Drive letters make the storage device *visible in the path* (`D:\data`). The Linux mount model *hides* the device — `/mnt/data` doesn't reveal it's a second disk. That hiding is a feature: apps become storage-agnostic.

```
   THREE WAYS TO GIVE A CONTAINER A ROOT FS

   Full copy:         [====== full 500MB copy per container ======]  ×10 = 5GB
   devicemapper:      block-level COW snapshots (needs thin pool, heavier)
   OverlayFS:         [shared 500MB RO image] + [tiny per-container upper]  ×10 ≈ 500MB + scraps
```

### Comparison table

| Task / property | Full copy | devicemapper COW | OverlayFS |
|---|---|---|---|
| Disk for 10 containers, 1 image | 10× image size | ~1× + deltas | ~1× + tiny deltas |
| Setup required | none | dedicated block device / thin pool | none (works on ext4/xfs dirs) |
| Copy granularity | whole fs | block | file |
| Container start speed | slow (copy) | fast | fast (just a mount) |
| Share RO layers across containers | ❌ | partial | ✅ (lowerdirs shared) |
| Visible in `mount` as | a real fs | dm device | `overlay` type |

### When would I NOT reach for these?

- **You need data to persist past the container.** OverlayFS's upperdir is *ephemeral by design* — do NOT store your database there. Use a **PersistentVolume** (mounted under `/var/lib/kubelet/pods/<UUID>/volumes/...`) or a real disk mount.
- **You need a shared, writable, network filesystem across nodes.** OverlayFS is node-local. Use NFS/CSI-backed volumes.
- **Heavy random-write workloads inside the container fs.** Copy-up on first write of large files adds latency; put hot data on a real volume, not the writable layer.
- **You need a mount to survive reboot.** tmpfs and ad-hoc `mount` commands vanish; use `/etc/fstab` for persistence.

**One-sentence "why this over that":**
> Use OverlayFS for container root filesystems because it gives every container a private, writable view over shared read-only image layers at near-zero disk and startup cost — but reach for a PersistentVolume (a real mount) the instant the data must outlive the container.

> **✅ Check yourself before Rung 7:** Explain to a colleague why OverlayFS *structurally* saves disk across 10 identical pods — not "it's more efficient," but the specific mechanism (which directories are shared, which are per-container, and what copy-up does).

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each is a **hypothesis you commit to first**, then verify. Read the prediction, cover the outcome, decide if you agree, *then* run it. Most of these are safe on any Ubuntu 22.04 box; the ones needing a spare disk say so.

First, the read-only survey commands you'll lean on constantly (safe everywhere):

```bash
lsblk                          # tree of block devices, sizes, mount points
df -h                          # per-mount free space, HUMAN units
mount | column -t              # every current mount, aligned into columns
cat /proc/mounts               # the same table, raw from the kernel
findmnt /var/lib/containerd    # what's mounted at a path (great for pods)
```

---

## Prediction 1 — Normal case: a bind mount shows the same files at two paths

> **My prediction:** "If I bind-mount a directory onto another empty directory, then a file created via one path instantly appears via the other — *because* a bind mount is not a copy; both paths route through VFS to the *same inodes*. And `mount` will list it, proving a graft happened."

```bash
mkdir -p /tmp/src /tmp/view
echo "hello from src" > /tmp/src/file.txt

sudo mount --bind /tmp/src /tmp/view    # graft src's inodes onto view

cat /tmp/view/file.txt                   # → hello from src
echo "written via view" > /tmp/view/new.txt
cat /tmp/src/new.txt                      # → written via view  (same inodes!)

mount | grep /tmp/view                    # shows the bind mount
sudo umount /tmp/view                     # remove the graft
ls /tmp/view                              # empty again; new.txt still in /tmp/src
```

**Verify:** `new.txt` created via `/tmp/view` appears in `/tmp/src` immediately. If it *didn't* — if it looked like a copy — your model of "bind = same inodes, not a copy" needs repair. After `umount`, `/tmp/view` is empty but `/tmp/src/new.txt` survives (the data was always in src). This is exactly how a **hostPath** volume works.

---

## Prediction 2 — Edge/failure case: `ro` and `noexec` are enforced by the kernel, even for root

> **My prediction:** "If I mount a tmpfs with `ro`, then even `sudo` cannot write to it, and if I mount one `noexec`, then a perfectly valid `+x` script inside it refuses to run — *because* mount options are enforced at the VFS layer on every access, so they override file permissions and even root."

```bash
# A read-only tmpfs:
sudo mkdir -p /mnt/rodisk
sudo mount -t tmpfs -o ro tmpfs /mnt/rodisk
sudo touch /mnt/rodisk/x            # → touch: cannot touch ... Read-only file system
sudo umount /mnt/rodisk

# A noexec tmpfs:
sudo mount -t tmpfs -o size=16m,noexec tmpfs /mnt/rodisk
printf '#!/bin/sh\necho ran\n' | sudo tee /mnt/rodisk/s.sh >/dev/null
sudo chmod +x /mnt/rodisk/s.sh
/mnt/rodisk/s.sh                    # → Permission denied  (even though it's +x!)
sh /mnt/rodisk/s.sh                 # → ran   (reading+interpreting is allowed; direct exec is not)
sudo umount /mnt/rodisk
```

**Verify:** The write fails on the `ro` mount despite `sudo`, and the `+x` script fails to *execute directly* on the `noexec` mount even though its permission bits are correct. If root *could* write to the `ro` mount, you'd have found that mount options aren't what enforces this — but they are. Note the subtlety: `noexec` blocks `execve` of files on that mount, but you can still `sh script` because that runs `/bin/sh` (elsewhere) and merely *reads* the script. This is why hardened nodes mount `/tmp` and Secret volumes `noexec`.

---

## Prediction 3 — Kubernetes-flavored: build an OverlayFS by hand and watch copy-up happen

> **My prediction:** "If I stack a read-only lowerdir under a writable upperdir and mount them as `overlay`, then the merged view shows files from both; and when I modify a file that exists *only* in the lowerdir, the change lands in upperdir (copy-up) while the lowerdir original stays byte-for-byte unchanged — *because* that is exactly the copy-on-write mechanism containerd uses for every container."

```bash
cd /tmp && rm -rf ovtest && mkdir -p ovtest/{lower,upper,work,merged}

# lowerdir = pretend "image layer" (read-only role)
echo "from the image layer" > ovtest/lower/config.conf
echo "base binary"          > ovtest/lower/app

# Stack them:  lowerdir (ro) + upperdir (rw) + workdir, view at merged/
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/ovtest/lower,upperdir=/tmp/ovtest/upper,workdir=/tmp/ovtest/work \
  /tmp/ovtest/merged

mount | grep overlay                       # see the overlay mount (like a real container's)
ls /tmp/ovtest/merged                      # → app  config.conf  (unified view)

# Now MODIFY a file that only exists in lowerdir → triggers copy-up:
echo "changed by container" >> /tmp/ovtest/merged/config.conf

cat /tmp/ovtest/upper/config.conf          # → full file + the new line (COPIED UP)
cat /tmp/ovtest/lower/config.conf          # → still "from the image layer" ONLY (untouched!)

# Create a brand-new file → goes straight to upper, no copy-up:
echo "new" > /tmp/ovtest/merged/fresh.txt
ls /tmp/ovtest/upper                        # → config.conf  fresh.txt

# Delete a lower-only file → whiteout, not real deletion:
rm /tmp/ovtest/merged/app
ls /tmp/ovtest/merged                       # app is GONE from the view
ls /tmp/ovtest/lower                        # → app STILL THERE (lower is read-only)
ls -la /tmp/ovtest/upper                    # → a char-device "app" of 0,0 = the WHITEOUT

sudo umount /tmp/ovtest/merged
```

**Verify:** After the append, the modified `config.conf` appears in **upperdir** while **lowerdir's copy is unchanged** — that IS copy-up. New files skip copy-up (nothing to copy). The deleted `app` is hidden by a whiteout (a `0,0` character device in upperdir) yet physically survives in lowerdir. If lowerdir's `config.conf` had changed, your model is wrong — lowerdirs are read-only by construction. **You just reproduced, by hand, exactly what containerd does under `/var/lib/containerd` for every pod.**

---

## Prediction 4 — Kubernetes triage: find what is eating the node's disk

> **My prediction:** "If a node is under DiskPressure, then `du` on the big Kubernetes dirs will pin the culprit to one of containerd/kubelet/etcd, and `du --max-depth=1` on `/var` will rank the offenders — *because* these are the only places K8s stores meaningful bytes: image layers (containerd), pod volumes (kubelet), and cluster state (etcd)."

```bash
# df first: WHICH mount is full? Watch for an 'overlay' row = a container's rootfs.
df -h
df -h /var/lib/containerd            # the filesystem backing image layers + upperdirs

# Total size of each K8s storage area (-s = summary, -h = human):
sudo du -sh /var/lib/containerd /var/lib/kubelet /var/lib/etcd 2>/dev/null

# Rank the top consumers directly under /var (one level deep), biggest first:
sudo du --max-depth=1 -b /var 2>/dev/null | sort -rn | head
# (-b = bytes so sort -rn is exact; swap for -h if you just want to eyeball)

# See a container's overlay rootfs mounts explicitly:
mount | grep overlay
```

**Verify:** One of the three `du -sh` numbers dominates. If it's **containerd** → unused image layers (run `crictl rmi --prune` after confirming). If it's **kubelet** → a pod's `emptyDir` or logs ballooning under `/var/lib/kubelet/pods/`. If it's **etcd** → cluster state / snapshot growth. The `du --max-depth=1 /var | sort -rn` line is your fastest "who's the offender" ranking. If `df` shows an `overlay` mount at 100% but `du` on the host path is small, remember: the container writes into its **upperdir** under containerd — that's where a runaway container log grows.

---

## Prediction 5 — Persistence: an `/etc/fstab` entry survives reboot; a raw `mount` does not

> **My prediction:** "If I mount a tmpfs with a one-off `mount` command, it disappears on reboot; but if I add it to `/etc/fstab` and run `mount -a`, it's restored — *because* the kernel's mount table is in-memory only, and `/etc/fstab` (via `mount -a` at boot) is the mechanism that re-establishes grafts."

```bash
# One-off RAM disk (gone on reboot):
sudo mkdir -p /mnt/ramdisk
sudo mount -t tmpfs -o size=128m tmpfs /mnt/ramdisk
df -h /mnt/ramdisk                   # → tmpfs, 128M, mounted now

# Make it persistent: add a line to /etc/fstab (TEST carefully — a bad fstab can block boot)
echo 'tmpfs  /mnt/ramdisk  tmpfs  size=128m,noexec,nosuid  0  0' | sudo tee -a /etc/fstab

sudo umount /mnt/ramdisk             # unmount the manual one
sudo mount -a                        # re-read fstab and mount everything not yet mounted
findmnt /mnt/ramdisk                 # → present again, now sourced from fstab

# Cleanup so you don't leave a test line behind:
sudo umount /mnt/ramdisk
sudo sed -i '\#/mnt/ramdisk#d' /etc/fstab   # remove the line we added
```

**Verify:** After `umount` then `mount -a`, the tmpfs is back — proving `/etc/fstab` (not memory) is what persists mounts. **Always run `mount -a` after editing `/etc/fstab` before rebooting:** if it errors, a bad entry could hang boot in an emergency shell. This is precisely how a node's data disk for `/var/lib/containerd` is made to survive reboots.

---

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> A filesystem turns a block device (or RAM, or a stack of directories) into named files, and `mount` grafts that onto the one tree rooted at `/`, so every app just sees a path while the kernel decides what's really behind it — and OverlayFS is the special stacked mount (read-only image layers + one writable copy-on-write layer) that makes container images work.

**Explain it to a beginner in 3 sentences:**
> 1. A disk is just a huge numbered list of blocks; a *filesystem* (ext4/xfs) is the bookkeeping that turns those blocks into named files and folders, and *mounting* attaches a filesystem onto a directory in Linux's single tree so there are no drive letters — everything is a path under `/`.
> 2. That same "mount" verb can attach a real disk, a chunk of RAM (tmpfs, used for Kubernetes Secrets), an existing directory shown at a second place (bind mount, used for hostPath and ConfigMaps), or a *stack* of directories (OverlayFS).
> 3. OverlayFS gives each container a writable view over shared read-only image layers — reads search top-down and the first hit wins, and the first time a container changes an image file it gets copied up into the container's private writable layer, which is why containers start fast, share disk, and lose their own changes when they die.

**Map of sub-capability → the one core idea (all "mount a source onto the tree"):**

```
Every capability = "graft some source onto a directory in the one tree":

 Add a second disk       → mount /dev/sdb /mnt/data        (source: block device)
 Read-only / noexec area → mount -o ro,noexec ...          (constrain the graft)
 RAM disk / Secret / emptyDir(Memory) → mount -t tmpfs     (source: RAM)
 hostPath / ConfigMap     → mount --bind (+ symlinks)      (source: a directory)
 Container image + rootfs → mount -t overlay (lower+upper) (source: a stack of dirs)
 PersistentVolume         → mount under /var/lib/kubelet/pods/<UUID>/volumes/
 Survive reboot           → /etc/fstab + mount -a          (persist the grafts)
 Find disk hogs           → du -sh / du --max-depth=1 | sort -rn   (measure the tree)
```

Eight rows, one idea: *mount grafts a source onto the tree; the app only ever sees a path.*

**Which rung will I most likely need to revisit hands-on?**

- **Rung 3D / Prediction 3 (OverlayFS + copy-up).** It's the whole payoff and it feels abstract until you build one by hand and watch the file get copied up. The fix: run Prediction 3 on a real box, then `mount | grep overlay` on an actual node and match what you see to your hand-built stack.
- **Rung 5 (the trace), the Secret-as-tmpfs and ephemeral-upperdir parts.** If "why does my container lose its data on restart" or "where does a Secret physically live" still feels fuzzy, re-run Predictions 2 and 3 and narrate each step out loud.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [Everything is a File & /proc, /sys, /dev](01-linux-philosophy.md) — why VFS lets a path be backed by anything
- [Filesystem navigation & the FHS](03-filesystem-navigation.md) — the layout of the single tree you mount into
- [Namespaces](13-namespaces.md) — mount namespaces are what give each container its own overlay-rooted tree
- [cgroups](14-cgroups.md) — the sibling primitive limiting a pod's CPU/memory while mounts limit its storage
- [Performance monitoring](21-performance-monitoring.md) — iostat/lsof/PSI for diagnosing the disk pressure this file's `du` finds
- [Full Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — where storage fits in the node-triage big picture

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why can't the kernel just hand your program raw disk blocks and let the program remember where its files are?

**A:** Because a disk is a dumb linear array of numbered blocks with no names, no directories, no ownership, and no free-space tracking — the program would have to personally remember "config.yaml starts at block 918273 and is 3 blocks long." Scale that to a million files that grow and shrink and are owned by different users, and every program would need its own bookkeeping for which blocks belong to which file, how files nest into directories, who may access them, and which blocks are free — with all programs somehow agreeing so they don't clobber each other. That shared, kernel-enforced bookkeeping system *is* the filesystem (ext4/xfs): the layer that turns "block 918273" into `/etc/config.yaml`.

### Before Rung 3
**Q:** Say the core sentence from memory. If a container reads `/etc/config/app.conf` and it works, what three different things could physically back that path, and does the container's code care?

**A:** The sentence: *"A filesystem turns a block device into a tree of named files, and a mount grafts that tree onto a directory in the one global tree rooted at `/` — so everything is a path under `/`, no matter which device, RAM, or overlay actually holds the bytes."* The path could be backed by (1) **RAM** — a tmpfs mount, as Kubernetes uses for Secrets and `emptyDir` with `medium: Memory`; (2) **another directory** — a bind mount, as used for hostPath/ConfigMap projection; or (3) **a stack of directories** — an OverlayFS mount, if the file simply came from the container image's layers. The container's code does not care at all: it just calls `open()` on a path, and VFS routes the request to whichever driver is mounted there — the pod only ever sees a path; the kernel decides what's behind it.

### Before Rung 4
**Q:** Draw the OverlayFS stack. A container edits `/etc/hosts` (from a lowerdir) — walk through what the kernel does to the bytes, and why the other nine containers from the same image don't see the change.

**A:** The stack, bottom-up: one or more read-only **lowerdirs** (the image layers), one read-write **upperdir** (this container's writable layer), a **workdir** (OverlayFS's internal scratch space), all presented unified at the **merged** mount point, which the container sees as its `/`; lookups search top-down, upperdir first, and the first hit wins. When the container writes to `/etc/hosts`, OverlayFS sees the file exists only in a read-only lower layer, so it performs a **copy-up**: it copies the entire file into this container's upperdir first, *then* applies the write to that upper copy; future reads find the upper copy first and see the change. The other nine containers don't see it because they share only the untouched read-only lowerdirs — each has its *own private* upperdir, and the modified `/etc/hosts` exists solely in this one container's upperdir, shadowing (not altering) the shared original.

### Before Rung 5
**Q:** A Secret volume, a hostPath volume, and a container image's root all reach the app as a path. For each, name the mount source and the mount type.

**A:** **Secret volume:** source is **RAM** (plus swap) — mount type **tmpfs** — so the secret bytes never touch the node's disk; kubelet populates the tmpfs and it's bind-mounted into the container. **hostPath volume:** source is an **existing directory on the node** — mount type **bind mount** (`mount --bind`) — the same inodes made visible at a second path, not a copy. **Container image root:** source is a **stack of directories** (the read-only image-layer lowerdirs plus the container's writable upperdir and workdir) — mount type **overlay** (OverlayFS), whose merged view becomes the container's `/`. All three are the same graft operation, differing only in what gets grafted.

### Before Rung 6
**Q:** At Step 5, why did the write trigger a copy but Step 4's write didn't? At Step 8, which bytes are destroyed and which survive — and why is a container losing data on restart expected?

**A:** Step 5 appended to `/etc/nginx/nginx.conf`, a file that existed **only in a read-only lowerdir**, so OverlayFS had to copy-up the whole file into upperdir before applying the write; Step 4 created `/app/run.log`, a **brand-new file** that existed nowhere below, so it was created directly in upperdir — there was nothing to copy. At Step 8, the **upperdir is discarded** — `run.log` and the copied-up, modified `nginx.conf` are destroyed — and the **tmpfs Secret mount is torn down**, freeing its RAM; what survives are the **read-only image lowerdirs** under `/var/lib/containerd`, still shared and ready for the next container. That's why losing container-local data on restart is expected, not a bug: the writable layer is ephemeral *by design*, and anything that must outlive the container belongs in a volume (a PersistentVolume, i.e., a real mount).

### Before Rung 7
**Q:** Explain structurally why OverlayFS saves disk across 10 identical pods — which directories are shared, which are per-container, and what does copy-up do?

**A:** The image's layers are unpacked once into read-only **lowerdirs** under `/var/lib/containerd`, and all 10 containers' overlay mounts point at those *same* shared directories — the ~500MB of image content exists exactly once on disk, not ten times. Each container gets only its own tiny private **upperdir** (plus a workdir), which starts empty; a container consumes extra disk only for the specific files it creates or changes. **Copy-up** is what makes the sharing safe: the first time a container writes to an image file, OverlayFS copies just that one file into that container's upperdir and applies the write there, leaving the shared lowerdir byte-for-byte untouched. So the structural saving is: full copies would cost 10× the image size, while overlay costs ~1× the image plus each container's small delta — file-level copy-on-write with no special setup, which is exactly why it won over full copies and devicemapper.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6. Everything lives under dedicated `/opt/lab-*` and `/tmp/lab-*` paths, so nothing real is clobbered.

### 🟢 Scenario 1 — "Cork: the directory that emptied itself" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-cork/data
echo "cork-data-safe" | sudo tee /opt/lab-cork/data/important.txt >/dev/null
sudo mount -t tmpfs -o size=8m tmpfs /opt/lab-cork/data
```
**Situation:** Panic ticket: "our app's data directory `/opt/lab-cork/data` is suddenly EMPTY — everything is gone!" Backups are three days old. But nobody ran `rm`, the disk shows no errors, and the amount of *used space* on the root filesystem hasn't changed at all. Files that vanish while their bytes stay put usually haven't gone anywhere — something is standing in front of them.

**Your task:** Figure out why the directory appears empty, undo it, and bring `important.txt` back — no restore from backup.

**Verify:**
```bash
cat /opt/lab-cork/data/important.txt      # expected: cork-data-safe
findmnt /opt/lab-cork/data | wc -l        # expected: 0  (nothing mounted there anymore)
```

### 🟢 Scenario 2 — "Leipzig: root can't run its own script" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-leipzig
sudo mount -t tmpfs -o size=16m,noexec,nosuid tmpfs /opt/lab-leipzig
printf '#!/bin/sh\necho leipzig-deployed\n' | sudo tee /opt/lab-leipzig/deploy.sh >/dev/null
sudo chmod +x /opt/lab-leipzig/deploy.sh
```
**Situation:** A deploy job drops `deploy.sh` into `/opt/lab-leipzig` and runs it. It fails with `Permission denied`. The on-call engineer checked everything obvious: the file is `rwxr-xr-x`, owned by root, `sh -n` says the syntax is fine — and even `sudo /opt/lab-leipzig/deploy.sh` is *denied*. When root itself can't execute a `+x` file, the file isn't the problem; the ground it's standing on is.

**Your task:** Find what's really denying execution and fix it so the script runs from its current location (don't move or copy the script).

**Verify:**
```bash
/opt/lab-leipzig/deploy.sh    # expected: leipzig-deployed
```

### 🟡 Scenario 3 — "Toulouse: df says full, du says empty" (Medium)
**Setup:**
```bash
mkdir -p /tmp/lab-toulouse-img && sudo mkdir -p /opt/lab-toulouse
dd if=/dev/zero of=/tmp/lab-toulouse-img/disk.img bs=1M count=300 status=none
mkfs.ext4 -q -F /tmp/lab-toulouse-img/disk.img
sudo mount -o loop /tmp/lab-toulouse-img/disk.img /opt/lab-toulouse
sudo dd if=/dev/zero of=/opt/lab-toulouse/ghost.log bs=1M count=200 status=none
sudo setsid tail -f /opt/lab-toulouse/ghost.log >/dev/null 2>&1 < /dev/null &
sleep 1
sudo rm /opt/lab-toulouse/ghost.log
```
**Situation:** The 300 MB "log volume" mounted at `/opt/lab-toulouse` is nearly full — `df` shows ~200 MB used and alerts are firing. Someone already "fixed" it the obvious way: they found the giant log and deleted it. The alert never cleared. Now `ls` shows the volume is empty, `du -sh /opt/lab-toulouse` agrees (~0), yet `df` still reports the space as used. The bytes are alive; only the *name* died.

**Your task:** Explain the df-vs-du gap, find who is keeping the deleted file's bytes alive, and release the space **without unmounting** the volume.

**Verify:**
```bash
df --output=used -BM /opt/lab-toulouse | tail -1    # expected: under 30M (was ~215M)
sudo lsof +L1 /opt/lab-toulouse | wc -l              # expected: 0  (no deleted-but-open files remain)
```

### 🟡 Scenario 4 — "Valencia: we fixed the image, the container disagrees" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-valencia/lower /opt/lab-valencia/upper /opt/lab-valencia/work /opt/lab-valencia/merged
echo "version=2-fixed"  | sudo tee /opt/lab-valencia/lower/config.conf >/dev/null
echo "version=1-broken" | sudo tee /opt/lab-valencia/upper/config.conf >/dev/null
sudo mount -t overlay overlay \
  -o lowerdir=/opt/lab-valencia/lower,upperdir=/opt/lab-valencia/upper,workdir=/opt/lab-valencia/work \
  /opt/lab-valencia/merged
```
**Situation:** A "container" (the overlay mount at `/opt/lab-valencia/merged`) keeps reading `version=1-broken` from its config. The platform team already shipped the fix into the image layer — you can verify yourself that the lowerdir copy says `version=2-fixed`. Yet the merged view stubbornly serves the broken version. Long ago, *this* container once edited that config at runtime, and OverlayFS never forgets a write.

**Your task:** Make the merged view show `version=2-fixed` — and it must still be a live overlay mount afterwards, not a plain directory. Careful: the obvious `rm` through the merged view makes things *worse*, not better.

**Verify:**
```bash
cat /opt/lab-valencia/merged/config.conf                          # expected: version=2-fixed
mount | grep -c 'overlay on /opt/lab-valencia/merged'             # expected: 1
```

### 🟠 Scenario 5 — "Rotterdam: the 150 MB that df can see and du cannot find" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-rotterdam/data
sudo dd if=/dev/zero of=/opt/lab-rotterdam/data/old-hog.bin bs=1M count=150 status=none
echo "rotterdam-hidden" | sudo tee /opt/lab-rotterdam/data/marker.txt >/dev/null
sudo mount -t tmpfs -o size=8m tmpfs /opt/lab-rotterdam/data
echo "fresh-disk" | sudo tee /opt/lab-rotterdam/data/README >/dev/null
```
**Situation:** The root filesystem is ~150 MB heavier than anything you can find: `df` counts the bytes, but `du` on every visible directory comes up short — the classic under-the-mount mystery. History: the app once wrote directly into `/opt/lab-rotterdam/data` on the root disk; later a "data disk" was mounted **on top of** that very directory, entombing the old files underneath — invisible, undeletable, but still charged to the root filesystem. One of the entombed files (`marker.txt`) also holds a credential the team needs back. The mount must stay up: the "database" on the data disk is in production and **cannot be unmounted, even briefly**.

**Your task:** Reach *underneath* the live mount without disturbing it, save the marker file's content to `/tmp/lab-rotterdam-answer.txt`, and delete the 150 MB hog to reclaim the root filesystem's space.

**Verify:**
```bash
cat /tmp/lab-rotterdam-answer.txt                                  # expected: rotterdam-hidden
findmnt /opt/lab-rotterdam/data >/dev/null && echo still-mounted    # expected: still-mounted
df -BM /   # expected: ~150M more available on / than before your fix (the hog is truly gone)
```

### 🔴 Scenario 6 — "Bratislava: three containers, one of them is eating the node" (Expert)
**Setup:**
```bash
for c in c1 c2 c3; do
  sudo mkdir -p /opt/lab-bratislava/$c/lower /opt/lab-bratislava/$c/upper /opt/lab-bratislava/$c/work /opt/lab-bratislava/$c/merged
  echo "base-image-$c" | sudo tee /opt/lab-bratislava/$c/lower/base.txt >/dev/null
  sudo mount -t overlay overlay \
    -o lowerdir=/opt/lab-bratislava/$c/lower,upperdir=/opt/lab-bratislava/$c/upper,workdir=/opt/lab-bratislava/$c/work \
    /opt/lab-bratislava/$c/merged
done
sudo setsid sh -c 'while true; do dd if=/dev/zero bs=64K count=16 >> /opt/lab-bratislava/c2/merged/app.log 2>/dev/null; sleep 1; done' >/dev/null 2>&1 < /dev/null &
```
**Situation:** DiskPressure, miniaturized. This node runs three "containers" — three overlay mounts, exactly the shape containerd builds under `/var/lib/containerd` — and free space is draining at about 1 MB/s. `df` can tell you the disk is dying but not *who* is killing it: each container writes into its merged view, and the bytes physically land somewhere on the host. Your job is the Rung 7 / Prediction 4 triage, but at overlay granularity: rank the writable layers, catch the writer, stop the bleed, reclaim the space.

**Your task:** Identify which container is filling the disk *by measuring where overlay writes physically land*, find and stop the process doing the writing, then remove the runaway log so all three writable layers are back to near-zero — with all three overlay mounts still up.

**Verify:**
```bash
pgrep -f 'lab-bratislava.*app.log' | wc -l           # expected: 0  (the writer is gone)
sudo du -sk /opt/lab-bratislava/c1/upper /opt/lab-bratislava/c2/upper /opt/lab-bratislava/c3/upper
                                                      # expected: every upperdir ≤ ~8 KB
mount | grep -c 'overlay on /opt/lab-bratislava'      # expected: 3  (all containers still mounted)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Cork: the directory that emptied itself"
**Solution:**
```bash
findmnt /opt/lab-cork/data
# TARGET               SOURCE  FSTYPE  OPTIONS
# /opt/lab-cork/data   tmpfs   tmpfs   rw,size=8192k...   <- something is mounted OVER the data
sudo umount /opt/lab-cork/data
cat /opt/lab-cork/data/important.txt      # cork-data-safe — it was there all along
```
**Why this works & what it teaches:** Rung 3B says it plainly: mounting grafts a filesystem onto a directory, and *whatever was there before is hidden (not deleted) until you umount*. An empty tmpfs mounted over the data made the files unreachable while their bytes never moved — which is exactly why root-fs usage didn't drop. `findmnt <path>` is the one-command test that should precede any "files disappeared" panic. Where people go wrong: reaching for backups or `fsck` before asking the mount table what is actually grafted at that path.
**Cleanup:** `sudo rm -rf /opt/lab-cork`

### Scenario 2 — "Leipzig: root can't run its own script"
**Solution:**
```bash
findmnt -o TARGET,FSTYPE,OPTIONS /opt/lab-leipzig
# /opt/lab-leipzig  tmpfs  rw,nosuid,noexec,...          <- there's the denial
sudo mount -o remount,exec /opt/lab-leipzig               # lift ONLY the noexec flag, in place
/opt/lab-leipzig/deploy.sh                                # leipzig-deployed
```
**Why this works & what it teaches:** Mount options are enforced at the VFS layer on every access, so `noexec` overrides both the `+x` permission bits *and* root itself (Prediction 2) — `execve` on anything from that mount returns EACCES no matter who asks. The tell that separates "permissions problem" from "mount-option problem" is precisely that root is refused too. `mount -o remount,exec` changes the graft's constraints without unmounting. Where people go wrong: an hour of `chmod`/`chown`/ACL archaeology on a file whose bits were never the issue; and note the workaround `sh /opt/lab-leipzig/deploy.sh` *would* run (that's reading, not executing) — a hint, not a fix.
**Cleanup:** `sudo umount /opt/lab-leipzig; sudo rmdir /opt/lab-leipzig`

### Scenario 3 — "Toulouse: df says full, du says empty"
**Solution:**
```bash
sudo lsof +L1 /opt/lab-toulouse
# COMMAND  PID ... NLINK ... NAME
# tail    4711 ...     0 ... /opt/lab-toulouse/ghost.log (deleted)   <- zero links, still open
sudo kill 4711                     # (use the PID lsof printed) release the last reference
df --output=used -BM /opt/lab-toulouse | tail -1    # space is back
```
**Why this works & what it teaches:** `rm` removes a *name* from a directory, but the inode and its blocks survive as long as any process holds the file open — `df` asks the filesystem's block accounting (blocks still allocated), `du` walks directory entries (name gone), and the gap between them *is* the deleted-but-open file. `lsof +L1` lists open files with link count 0 — the exact tool for the gap. Killing the holder (or, to keep the process alive, truncating via its fd: `sudo sh -c ': > /proc/4711/fd/3'`) frees the blocks instantly, no unmount needed. Where people go wrong: deleting a busy log instead of truncating it — the space doesn't return until the writer closes the fd, which for a long-lived daemon may be never. This is the #1 real-world cause of "disk full but nothing's there" on nodes.
**Cleanup:** `sudo umount /opt/lab-toulouse; sudo rmdir /opt/lab-toulouse; rm -rf /tmp/lab-toulouse-img`

### Scenario 4 — "Valencia: we fixed the image, the container disagrees"
**Solution:**
```bash
cat /opt/lab-valencia/upper/config.conf     # version=1-broken  <- a stale COPY-UP is shadowing the fix
sudo umount /opt/lab-valencia/merged        # never edit upperdir while the overlay is mounted
sudo rm /opt/lab-valencia/upper/config.conf # drop the stale upper copy
sudo mount -t overlay overlay \
  -o lowerdir=/opt/lab-valencia/lower,upperdir=/opt/lab-valencia/upper,workdir=/opt/lab-valencia/work \
  /opt/lab-valencia/merged
cat /opt/lab-valencia/merged/config.conf    # version=2-fixed — lookup falls through to lower again
```
**Why this works & what it teaches:** Overlay lookups are top-down and the first hit wins (Rung 3D): the container's long-ago runtime edit copy-upped `config.conf` into upperdir, and that private copy permanently shadows every later improvement to the lower layer — the exact reason "we pushed a fixed image but the container still sees old files" happens when writable layers are reused. Two traps ambush the fix: `rm` through the *merged* view writes a **whiteout** that hides the lower file too (worse!), and modifying upperdir while mounted is undefined behavior — so the correct sequence is umount → clean upper → remount. In real Kubernetes the equivalent fix is simply recreating the container (fresh, empty upperdir), which is why "restart the pod picked up the fix" works. Where people go wrong: editing the lowerdir harder, instead of asking *which layer is actually serving this file?*
**Cleanup:** `sudo umount /opt/lab-valencia/merged; sudo rm -rf /opt/lab-valencia`

### Scenario 5 — "Rotterdam: the 150 MB that df can see and du cannot find"
**Solution:**
```bash
mkdir -p /tmp/lab-rotterdam-peek
sudo mount --bind /opt/lab-rotterdam /tmp/lab-rotterdam-peek   # bind the PARENT; binds don't recurse into submounts
ls /tmp/lab-rotterdam-peek/data                                 # old-hog.bin  marker.txt — the entombed originals!
cat /tmp/lab-rotterdam-peek/data/marker.txt | tee /tmp/lab-rotterdam-answer.txt   # rotterdam-hidden
sudo rm /tmp/lab-rotterdam-peek/data/old-hog.bin                # reclaim the 150 MB from the ROOT fs
sudo umount /tmp/lab-rotterdam-peek && rmdir /tmp/lab-rotterdam-peek
findmnt /opt/lab-rotterdam/data                                 # the "database disk" never blinked
```
**Why this works & what it teaches:** A mount hides, never deletes (Rung 3B) — the old files still occupy root-fs blocks, which is why `df` counts them while every `du` walk gets deflected onto the tmpfs at the mount point. The escape hatch: a plain (non-recursive) bind mount of the *parent* directory replays the underlying filesystem's tree **without** its submounts, so `/tmp/lab-rotterdam-peek/data` shows the entombed originals while the production mount stays untouched — the same "same inodes, second window" mechanism as Prediction 1, used as a periscope. Where people go wrong: `umount`ing production storage "just for a second" to look underneath, or trusting `du` alone and concluding the kernel is miscounting; when `df` and `du` disagree, the bytes are either held by a deleted-open file (Toulouse) or buried under a mount (here).
**Cleanup:** `sudo umount /opt/lab-rotterdam/data; sudo rm -rf /opt/lab-rotterdam; rm -f /tmp/lab-rotterdam-answer.txt`

### Scenario 6 — "Bratislava: three containers, one of them is eating the node"
**Solution:**
```bash
# 1) WHERE do overlay writes land? In each container's upperdir. Rank them:
sudo du -sk /opt/lab-bratislava/*/upper | sort -rn
# 123456  /opt/lab-bratislava/c2/upper      <- the offender, and growing on every re-run
# 8       /opt/lab-bratislava/c1/upper
# 8       /opt/lab-bratislava/c3/upper
# 2) WHO is writing? Find the process aimed at that container's merged view:
pgrep -af 'lab-bratislava'
# 4711 sh -c while true; do dd ... >> /opt/lab-bratislava/c2/merged/app.log ...; sleep 1; done
sudo kill 4711                                       # stop the bleed (kills the loop; its dd dies with it)
# 3) Reclaim: app.log was born in upperdir (new file, no copy-up), so rm through merged truly frees it:
sudo rm /opt/lab-bratislava/c2/merged/app.log
sudo du -sk /opt/lab-bratislava/*/upper              # all back to ~4-8K; mounts untouched
```
**Why this works & what it teaches:** Every byte a container writes lands in its private **upperdir** on the host (Rung 3D / Rung 5 step 4) — so node-level disk triage at container granularity is `du` over upperdirs, which is literally what you do under `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs` when a real node hits DiskPressure and `df` names the filesystem but not the culprit (Prediction 4's finale: "the container writes into its upperdir — that's where a runaway container log grows"). Deleting through the merged view is safe *here* because `app.log` exists only in upper — no lower copy means a real deletion, not a whiteout — and the space returns the moment no process holds it open (the Toulouse rule, obeyed by killing the writer first). Where people go wrong: `rm`-ing the log while the writer lives (deleted-but-open, zero bytes freed), or restarting all three containers when the evidence pinned it to one.
**Cleanup:** `for c in c1 c2 c3; do sudo umount /opt/lab-bratislava/$c/merged; done; sudo rm -rf /opt/lab-bratislava`
