# Kernel Tuning, Modules & the Boot Process

*From the power button to PID 1, and the handful of kernel knobs and modules without which your Kubernetes node quietly refuses to network — how the machine wakes up, and how you tune the thing every container secretly depends on.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** How a Linux machine boots — the chain from firmware to `systemd` — and, more usefully for you, how to *tune the running kernel*: loading **kernel modules** (drivers/features you snap into the kernel at runtime) and turning **sysctl knobs** (`/proc/sys` parameters that change kernel behavior live). This is the layer *underneath* everything else in this guide. Namespaces (see [namespaces](13-namespaces.md)), cgroups (see [cgroups](14-cgroups.md)), and iptables (see [iptables-netfilter](12-iptables-netfilter.md)) are all kernel features — and some of them only *work* if you've loaded the right module or flipped the right knob first.

**Why did this land on my desk?** You're bootstrapping a fresh Kubernetes node with `kubeadm`, and preflight blows up before the control plane ever starts:

```bash
sudo kubeadm init
# [preflight] Running pre-flight checks
# error execution phase preflight:
#   [ERROR FileContent--proc-sys-net-bridge-bridge-nf-call-iptables]:
#     /proc/sys/net/bridge/bridge-nf-call-iptables contents are not set to 1
#   [ERROR FileContent--proc-sys-net-ipv4-ip_forward]:
#     /proc/sys/net/ipv4/ip_forward contents are not set to 1
#   [ERROR Swap]: running with swap on is not supported. Please disable swap
```

kubeadm is reading three files out of the kernel and refusing to continue. Not YAML, not a config server — plain virtual files under `/proc/sys`. To fix this credibly (and to make it *survive a reboot*, which the naïve fix does not) you need to understand what those files are, which subsystem reads them, why Kubernetes demands them, and how the node's boot process loads the modules that make them exist in the first place.

**What do I already know that transfers?**
- **"Everything is a file"** (see [linux-philosophy](01-linux-philosophy.md)) — kernel tuning is *entirely* reading and writing virtual files under `/proc` and `/sys`. `cat` and `echo` (or `sysctl`, a thin wrapper over them) are the whole API.
- **systemd** (see [systemd-services](16-systemd-services.md)) — you know `systemctl`. What you may not know is that systemd is **PID 1**, the first process the kernel starts, and the top of the boot chain lands right on it.
- **iptables / netfilter** (see [iptables-netfilter](12-iptables-netfilter.md)) — kube-proxy programs `KUBE-*` chains. Those chains only see bridged pod traffic if a specific module + sysctl are enabled. Today you'll see *why*.
- **Kubernetes `kubeadm`, `kubelet`, `containerd`, CNI** — you've run them. You've never seen the kernel prerequisites they silently assume. Today you will.

---

## 🔥 Rung 1 — The Pain

**The problem that FORCED this to exist: a kernel that could do *everything* would be too big to boot, and a kernel frozen at boot time couldn't adapt to a changing machine.**

Rewind to the design tension the Linux kernel has always lived with. The kernel is one program that must drive *every* piece of hardware and offer *every* feature — thousands of network card drivers, filesystems, crypto algorithms, netfilter hooks, overlay filesystems. Two bad options present themselves:

- **Compile everything into one monolithic kernel image.** Now your boot image is enormous, wastes RAM holding drivers for hardware you don't have, and every new driver means recompiling and rebooting the kernel. On a server you'd never touch 95% of it.
- **Freeze the kernel's behavior at compile time.** Then the one number that's perfect for a laptop (small network buffers, aggressive power saving) is wrong for a 64-core router pushing millions of packets — and you can't change it without a rebuild and reboot.

Both are intolerable for a general-purpose OS. So Linux grew two escape hatches:

1. **Loadable kernel modules** — chunks of kernel code (`.ko` files) you insert and remove *at runtime*. The base kernel stays lean; you snap in the `overlay` filesystem driver or the `br_netfilter` hook only on machines that need them. `modprobe overlay` and the feature exists; `rmmod` and it's gone.
2. **Runtime-tunable parameters (`sysctl`)** — thousands of kernel variables exposed as writable files under `/proc/sys`. Change `net.ipv4.ip_forward` from `0` to `1` and the kernel *starts routing packets between interfaces* the instant you write the file. No recompile, no reboot.

**What did people do before, and why did it hurt?**
- **Custom-compiled kernels per machine.** Weeks of `make menuconfig`, and every tweak was a reboot. A production fleet running slightly different hand-rolled kernels was an unauditable nightmare.
- **Hard-coded tunables.** Network stack behavior baked in; the only "tuning" was choosing a different kernel build. Web servers and databases fought over one-size-fits-none defaults.

**Who feels this pain most in the Kubernetes world? You — the platform engineer bringing up nodes.** A Kubernetes node is a *general-purpose kernel forced into a very specific job*: routing pod traffic across virtual bridges, stacking container images as overlay filesystems, running thousands of processes each watching thousands of files. The stock Ubuntu defaults are tuned for a *laptop*, not for that. So:

- **Without the `overlay` module**, containerd can't use the fast copy-on-write OverlayFS snapshotter — image layers can't stack.
- **Without `br_netfilter` + `net.bridge.bridge-nf-call-iptables=1`**, packets crossing the Linux bridge that connects pods **bypass iptables entirely** — so kube-proxy's `KUBE-SERVICES` rules never fire, and *ClusterIP Services silently don't work*. Pods can ping each other but can't reach a Service. This is the single most common "my CNI is broken" ghost.
- **Without `net.ipv4.ip_forward=1`**, the node won't forward a packet from one interface (or pod veth) to another — so pod-to-pod traffic across the node, and all CNI routing, dies.
- **With swap on**, the kubelet historically refused to start (`failSwapOn: true`), because swap makes memory limits and OOM behavior unpredictable — the whole cgroup accounting model (see [cgroups](14-cgroups.md)) assumes a page charged is a page in RAM.
- **Without enough `fs.inotify` watches/instances**, once you pack many pods onto a node, `kubelet`, `containerd`, and log shippers run out of file-watch slots and you get `too many open files` / `no space left on device` errors that have nothing to do with disk.

Every one of those is a *kernel not yet tuned for its job*. kubeadm's preflight exists precisely because these failures are silent and maddening — it checks the knobs up front so you fail loudly at `init` instead of mysteriously three hours later when a Service won't resolve.

> **Check yourself before Rung 2:** Pods on the same node can ping each other by IP, but `curl` to a ClusterIP Service times out. Given the pain above, name the *two* kernel prerequisites most likely missing — and explain why "ping works" doesn't rule them out. (Hint: which one is about the *bridge* and iptables, which about *forwarding*?)

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it exactly:

> **The kernel is a running program you configure through the filesystem: you snap features in as modules and turn behavior dials with sysctl — both change the LIVE kernel immediately, and neither survives a reboot unless you also write it to a config file that the boot process replays.**

That one sentence has two halves and one crucial catch, and everything else derives from it:

- **"snap features in as modules"** → `modprobe <name>` loads a `.ko`; `lsmod` lists what's loaded; `rmmod`/`modprobe -r` removes; `modinfo` describes one. Features like `overlay` and `br_netfilter` are *not present until loaded*.
- **"turn behavior dials with sysctl"** → every file under `/proc/sys` is a dial. `sysctl net.ipv4.ip_forward` reads it; `sysctl -w net.ipv4.ip_forward=1` writes it. `net.ipv4.ip_forward` *is literally* the file `/proc/sys/net/ipv4/ip_forward` with the dots as slashes.
- **"change the LIVE kernel immediately"** → the write takes effect on the next packet / next syscall. No restart of anything.
- **THE CATCH: "neither survives a reboot unless…"** → `/proc` and `/sys` are virtual (RAM-backed). A reboot wipes them back to defaults. To *persist*, you drop the module name in `/etc/modules-load.d/*.conf` and the sysctl in `/etc/sysctl.d/*.conf`, and the **boot process replays those files** on the way up. This is why the naïve `echo 1 > /proc/...` fix "works" until the node reboots and Kubernetes breaks again.

And the boot chain is just the machinery that *does that replay*: firmware → bootloader → kernel → PID 1 (systemd) → systemd runs `systemd-modules-load` (reads `/etc/modules-load.d/`) and `systemd-sysctl` (reads `/etc/sysctl.d/`). **The boot process is how your persisted tunables get re-applied.**

If you remember nothing else: **modules snap features in; sysctl turns dials; both are live-but-volatile; config files + the boot replay make them permanent.**

> **Check yourself before Rung 3:** From the one sentence alone, predict: you run `sysctl -w net.ipv4.ip_forward=1`, `kubeadm init` now passes, the cluster runs fine for weeks — then the node reboots for a kernel patch and pods can't reach Services again. What exactly did you forget to do, and which boot-time component would have replayed it if you had?

---

## ⚙️ Rung 3 — The Machinery (the important rung — go slow)

Two mechanisms to build here: **(A) the boot chain** that gets you from firmware to a tuned, running node, and **(B) how modules and sysctl actually plug into and steer the kernel**. Then we tie both to Kubernetes.

### (A) The boot chain: power button → PID 1 → tuned node

Each stage's only job is to find, load, and hand control to the next, adding a little more capability each hop.

```
THE BOOT CHAIN  (each box hands off to the next)

┌────────────────────────────────────────────────────────────────────┐
│ 1. FIRMWARE  (UEFI, or legacy BIOS)                                 │
│    • lives in a chip on the motherboard, runs at power-on           │
│    • POST (self-test), then finds a bootloader                      │
│    • UEFI reads the EFI System Partition (FAT32) for a .efi         │
│                         │ hands off to                              │
│                         ▼                                           │
│ 2. BOOTLOADER  (GRUB2 on most distros)                             │
│    • shows the menu; knows where the kernel + initramfs live        │
│    • loads two files into RAM:                                      │
│        - vmlinuz   (the compressed kernel image)                    │
│        - initramfs (a tiny temporary root filesystem)               │
│    • passes the KERNEL COMMAND LINE (e.g. root=UUID=… quiet)        │
│                         │ jumps into                                │
│                         ▼                                           │
│ 3. KERNEL + INITRAMFS                                               │
│    • kernel decompresses, detects CPU/RAM, mounts initramfs as /    │
│    • initramfs holds JUST the drivers needed to find the REAL root  │
│      disk (e.g. NVMe, LVM, LUKS crypto modules)                     │
│    • kernel reads /proc/cmdline to know root=, mounts real root     │
│    • pivots from initramfs to the real root filesystem              │
│                         │ starts the FIRST process                  │
│                         ▼                                           │
│ 4. PID 1  = /sbin/init  ->  systemd                                │
│    • the ancestor of every other process; if it dies, kernel panics │
│    • brings the system up by activating a TARGET (a goal state)     │
│                         │ pulls in units incl.                      │
│                         ▼                                           │
│ 5. systemd TARGETS & the tuning replay                             │
│    • default.target -> usually multi-user.target (or graphical)     │
│    • along the way runs:                                            │
│        systemd-modules-load.service  → reads /etc/modules-load.d/*  │
│                                         → modprobe each listed module│
│        systemd-sysctl.service        → reads /etc/sysctl.d/*        │
│                                         → applies each knob          │
│    • then starts your services: containerd, kubelet, sshd …         │
└────────────────────────────────────────────────────────────────────┘
```

Two ideas do a lot of work here:

- **The initramfs (initial RAM filesystem)** is a chicken-and-egg fix: to mount your real root disk the kernel needs that disk's driver, but the driver lives *on* the disk. So GRUB loads a tiny throwaway filesystem into RAM that contains just enough drivers (NVMe, RAID, LVM, LUKS) to reach and mount the real root, then the kernel pivots to it. On a cloud K8s node this is usually invisible, but it's why a mis-generated initramfs = an unbootable node.
- **The kernel command line** is a string of options GRUB hands the kernel, readable forever after at `/proc/cmdline`. It sets `root=` (which disk to mount), can pin CPU behavior, and — relevant to Kubernetes — is where you'd add `systemd.unified_cgroup_hierarchy=1` (force cgroup v2) or `cgroup_no_v1=all`. When a colleague asks "is this node on cgroup v2?", one place to look is `cat /proc/cmdline`.

**Targets** replace the old SysV "runlevels": a target is a named *goal state* (a bundle of units to activate). `multi-user.target` = full text-mode server; `graphical.target` = plus a GUI. A K8s node sits at `multi-user.target`.

### (B) How a module and a sysctl actually steer the kernel

**A kernel module** is compiled kernel code that runs in kernel space, exposing new capabilities. It is NOT a userspace program.

```
MODULE LOADING  (modprobe overlay)

  you: modprobe overlay
         │
         ▼
  modprobe resolves DEPENDENCIES via /lib/modules/$(uname -r)/modules.dep
    (overlay may need other modules first — modprobe loads them in order;
     rmmod/insmod would NOT — that's why you use modprobe, not insmod)
         │
         ▼
  finds /lib/modules/$(uname -r)/kernel/fs/overlayfs/overlay.ko
         │
         ▼
  init_module() syscall → kernel links the .ko INTO the running kernel
         │
         ▼
  the "overlay" filesystem type now EXISTS
    → shows up in  lsmod  and  /proc/filesystems
    → containerd's overlayfs snapshotter can now mount image layers
```

Key facts that trip people up:
- `modprobe` is dependency-aware (reads `modules.dep`); `insmod` takes a raw `.ko` path and does *not* resolve deps. **Always `modprobe`.**
- A module can be **built-in** instead of loadable (compiled into the kernel). Built-ins won't appear in `lsmod` but the feature is present. `overlay` and `br_netfilter` are loadable on stock Ubuntu, so `lsmod | grep` is a valid check there.
- Loading is volatile. `/etc/modules-load.d/k8s.conf` is the persistence file `systemd-modules-load` replays at boot.

**A sysctl** is a named kernel variable exposed as a file. Writing it flips a branch deep in a subsystem:

```
SYSCTL  (net.ipv4.ip_forward = 1)

  net.ipv4.ip_forward   ==   /proc/sys/net/ipv4/ip_forward
      (dots become slashes — it is literally that file)

  echo 1 > /proc/sys/net/ipv4/ip_forward
  sysctl -w net.ipv4.ip_forward=1     ← same effect, nicer syntax
         │
         ▼
  the IPv4 stack's forwarding flag flips 0 → 1
         │
         ▼
  a packet arriving on eth0 addressed to a pod on cni0 is now ROUTED
  between interfaces instead of dropped. CNI pod-to-pod traffic lives here.
```

### The Kubernetes-critical set, and WHY each one

```
┌──────────────────────────────┬───────────────────────────────────────────┐
│ Knob / module                │ What breaks without it (K8s)                │
├──────────────────────────────┼───────────────────────────────────────────┤
│ module: overlay              │ containerd overlayfs snapshotter can't stack│
│                              │ image layers → images won't unpack fast     │
├──────────────────────────────┼───────────────────────────────────────────┤
│ module: br_netfilter         │ registers the hook that makes BRIDGED       │
│                              │ traffic traverse iptables — required for    │
│                              │ the next knob to even exist/work            │
├──────────────────────────────┼───────────────────────────────────────────┤
│ net.bridge.bridge-nf-call-   │ =1 → packets crossing the Linux bridge      │
│   iptables = 1               │ (pod↔pod on a node) hit kube-proxy's        │
│                              │ KUBE-* chains. =0 → ClusterIP Services      │
│                              │ silently fail; DNAT never happens           │
├──────────────────────────────┼───────────────────────────────────────────┤
│ net.ipv4.ip_forward = 1      │ node routes packets between interfaces/veths│
│                              │ → pod-to-pod across node + CNI routing work │
├──────────────────────────────┼───────────────────────────────────────────┤
│ fs.inotify.max_user_instances│ enough inotify instances/watches for many   │
│ fs.inotify.max_user_watches  │ pods; kubelet/containerd/log agents watch   │
│                              │ files → "too many open files" at scale      │
├──────────────────────────────┼───────────────────────────────────────────┤
│ swap OFF (swapoff -a)        │ kubelet's failSwapOn historically refused   │
│                              │ to start; memory accounting stays honest    │
└──────────────────────────────┴───────────────────────────────────────────┘
```

Note the ordering dependency the whole cluster hinges on: **`net.bridge.bridge-nf-call-iptables` only appears as a file after `br_netfilter` is loaded.** The `net/bridge/` sysctl subtree is *registered by that module*. Try to set the sysctl first and you get `No such file or directory`. That's why every kubeadm guide loads the module, *then* writes the sysctl — and why the persisted config uses both `/etc/modules-load.d/k8s.conf` and `/etc/sysctl.d/k8s.conf` together.

### The whiteboard picture — the whole node coming up tuned

```
     BOOT TIME                          │        WHAT KUBERNETES THEN GETS
                                        │
  firmware → GRUB → kernel+initramfs    │
        │                               │
        ▼                               │
    systemd (PID 1)                     │
        │                               │
        ├─ systemd-modules-load ────────┼─► modprobe overlay, br_netfilter
        │    reads /etc/modules-load.d/ │      → OverlayFS type exists
        │    k8s.conf                   │      → bridge-nf sysctls now EXIST
        │                               │
        ├─ systemd-sysctl ──────────────┼─► write /proc/sys values:
        │    reads /etc/sysctl.d/       │      net.bridge.bridge-nf-call-iptables=1
        │    k8s.conf                   │      net.ipv4.ip_forward=1
        │                               │      fs.inotify.max_user_watches=...
        │                               │
        ├─ swap.target masked / no swap │─► kubelet's failSwapOn satisfied
        │                               │
        ├─ containerd.service ──────────┼─► uses overlayfs snapshotter ✅
        │                               │
        └─ kubelet.service ─────────────┼─► preflight knobs all =1 ✅
                                        │      CNI routes pods; kube-proxy's
                                        │      KUBE-* chains see bridged traffic ✅
```

The app team and even most cluster users never see any of the left column. When a Service "doesn't work," this is the invisible layer you walk down into.

> **Check yourself before Rung 4:** Explain, in cause-and-effect order, why running `sysctl -w net.bridge.bridge-nf-call-iptables=1` on a fresh node can fail with "No such file or directory," and what single command makes it succeed. Which subsystem *creates* that file?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually IS | Which machinery it touches |
|---|---|---|
| **BIOS / UEFI** | Firmware on the motherboard that runs at power-on | Boot chain stage 1; finds the bootloader |
| **Bootloader / GRUB2** | Program that loads the kernel + initramfs into RAM | Boot chain stage 2; passes the cmdline |
| **vmlinuz** | The compressed kernel image file | Loaded by GRUB, decompressed into RAM |
| **initramfs / initrd** | Tiny temporary root FS with drivers to reach the real disk | Boot stage 3; solves the driver chicken-and-egg |
| **kernel command line** | Options GRUB passes the kernel (`root=`, `quiet`, cgroup flags) | Readable at `/proc/cmdline` forever after |
| **`/proc/cmdline`** | Virtual file exposing the kernel command line | Where you confirm boot params live |
| **PID 1 / init** | The first process the kernel starts; ancestor of all | Boot stage 4; on modern distros it's systemd |
| **systemd** | The init system + service/target manager | PID 1; runs the modules/sysctl replay units |
| **target** | A named goal state = bundle of units (replaces runlevels) | `multi-user.target` for a server/K8s node |
| **kernel module (`.ko`)** | Compiled kernel code snapped in at runtime | Adds a feature (overlay, br_netfilter) live |
| **`modprobe`** | Loads a module *and its dependencies* | Reads `modules.dep`; the correct loader |
| **`insmod` / `rmmod`** | Insert / remove a single `.ko`, no dep resolution | Low-level; prefer modprobe / `modprobe -r` |
| **`lsmod`** | Lists currently loaded modules | Reads `/proc/modules` |
| **`modinfo`** | Prints a module's metadata (path, params, deps) | Inspects a `.ko` before/without loading it |
| **`/etc/modules-load.d/*.conf`** | List of modules to load at boot | Replayed by `systemd-modules-load` |
| **sysctl** | A tunable kernel variable exposed as a file | Live kernel dial under `/proc/sys` |
| **`/proc/sys/...`** | The virtual files backing every sysctl | `net.ipv4.ip_forward` = `net/ipv4/ip_forward` |
| **`sysctl -w`** | Write a sysctl for the running kernel (volatile) | Same as `echo … > /proc/sys/…` |
| **`/etc/sysctl.d/*.conf`** | Persisted sysctl settings | Replayed by `systemd-sysctl` at boot |
| **`sysctl --system`** | Re-read ALL sysctl config files now | Applies persisted knobs without a reboot |
| **`br_netfilter`** | Module registering the bridge→netfilter hook | Makes bridged pod traffic hit iptables |
| **`overlay`** | The OverlayFS filesystem module | containerd's image-layer snapshotter |
| **swap** | Disk space used as overflow "RAM" | `swapoff -a` / `free -h`; kubelet failSwapOn |
| **inotify** | Kernel file-change notification subsystem | `fs.inotify.*` limits; kubelet/log watchers |

**"Same kind of thing wearing different names" — the groupings that matter:**

- **A sysctl name and its file are the SAME object.** `net.ipv4.ip_forward` *is* `/proc/sys/net/ipv4/ip_forward`. `sysctl -w net.ipv4.ip_forward=1` and `echo 1 > /proc/sys/net/ipv4/ip_forward` are the identical write. Dots ↔ slashes.
- **"Load a module now" vs "load it at boot" are two files for one goal:** `modprobe overlay` (now, volatile) and a line `overlay` in `/etc/modules-load.d/k8s.conf` (at boot, persistent). You almost always want *both*.
- **"Set a knob now" vs "set it at boot":** `sysctl -w …` / `echo > /proc/sys/…` (now) and a line in `/etc/sysctl.d/*.conf` replayed by `sysctl --system` / boot (persistent). Again, do both.
- **`init`, `PID 1`, and `systemd`** are the same process on a modern node — three names for the thing at the top of the boot chain.
- **`initramfs` and `initrd`** are used interchangeably in docs; both mean the temporary early-boot root filesystem.
- **`systemd-modules-load` : `/etc/modules-load.d/`** as **`systemd-sysctl` : `/etc/sysctl.d/`** — the exact same "boot unit replays a drop-in directory" pattern, once for modules, once for knobs.

> **Check yourself before Rung 5:** Using only the vocabulary above, name the two files a colleague must `cat` to answer "is `ip_forward` on right now, and will it survive a reboot?" — and say which term connects the second file to the boot process that re-applies it. (Hint: one lives under `/proc/sys`, the other under `/etc/sysctl.d/`, and a `systemd-*` unit ties them together.)

---

## 🔬 Rung 5 — The Trace

Let's follow ONE concrete, high-stakes action end to end: **a fresh Ubuntu 22.04 node boots, applies its Kubernetes tuning, and a pod successfully `curl`s a ClusterIP Service** — the exact thing that was broken in Rung 0. Who does what, in order.

1. **Power on.** UEFI firmware runs POST, reads the EFI System Partition, and finds GRUB2's `.efi`. It hands control to GRUB.
2. **GRUB** reads its config, loads `vmlinuz` (kernel) and the `initramfs` into RAM, and jumps into the kernel — passing the **kernel command line** (`root=UUID=… ro quiet`).
3. **The kernel** decompresses, probes hardware, mounts the initramfs as a temporary `/`, uses the disk drivers inside it to find the real root (via `root=` from `/proc/cmdline`), mounts the real root, and **pivots** to it.
4. **The kernel starts PID 1 = systemd.** Every future process descends from here.
5. **systemd activates `multi-user.target`**, which pulls in ordering units. Early among them: **`systemd-modules-load.service`** reads `/etc/modules-load.d/k8s.conf`, sees `overlay` and `br_netfilter`, and runs the equivalent of `modprobe overlay` + `modprobe br_netfilter`. Loading `br_netfilter` **registers the `net/bridge/` sysctl subtree** — the files `net.bridge.bridge-nf-call-iptables` now *exist*.
6. **`systemd-sysctl.service`** reads `/etc/sysctl.d/k8s.conf` and writes each knob: `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1`, `fs.inotify.max_user_watches=524288`. Because step 5 already made the bridge file exist, this succeeds. The live kernel is now tuned for Kubernetes.
7. **No swap is active** (fstab has no swap / `swapoff` ran / the swap unit is masked), so the kubelet's `failSwapOn` check will pass.
8. **`containerd.service` starts**, sees the `overlay` module present, and initializes its **overlayfs snapshotter** — ready to stack image layers.
9. **`kubelet.service` starts**, its preflight-equivalent knobs all reading `1`. It talks to containerd via CRI, the **CNI** plugin wires up pod veths into the node's bridge, and **kube-proxy** programs `KUBE-SERVICES`/`KUBE-SVC-*` iptables chains (see [iptables-netfilter](12-iptables-netfilter.md)).
10. **A pod runs `curl http://my-svc` (a ClusterIP).** The packet leaves the pod's veth and crosses the node's Linux **bridge**. *Because* `br_netfilter` is loaded and `bridge-nf-call-iptables=1`, that bridged packet is handed to **netfilter**, where kube-proxy's `KUBE-SERVICES` chain **DNATs** the ClusterIP to a real pod IP. *Because* `ip_forward=1`, the node **routes** the rewritten packet on toward the backend pod. The Service call succeeds — the exact failure from Rung 0, now working, and it will keep working across reboots because every step above replays from a config file.

```
VISUAL OF THE TRACE  (boot → tuned kernel → working Service)

 power  →  GRUB  →  kernel+initramfs  →  systemd (PID 1)
                                              │
              ┌───────────────────────────────┼───────────────────────────┐
              ▼                               ▼                            ▼
  systemd-modules-load            systemd-sysctl                 (swap off)
   /etc/modules-load.d/k8s.conf    /etc/sysctl.d/k8s.conf
     modprobe overlay               bridge-nf-call-iptables=1
     modprobe br_netfilter  ──┐      ip_forward=1
                              │      inotify.max_user_watches=…
        registers the ────────┘                 │
        net/bridge/ sysctls  (so the write above can succeed)
              │                                 │
              └───────────────┬─────────────────┘
                              ▼
                    containerd (overlayfs) + kubelet + CNI + kube-proxy
                              │
     pod: curl http://my-svc (ClusterIP)
        │  packet crosses the node bridge
        ▼  br_netfilter + bridge-nf-call-iptables=1
     netfilter KUBE-SERVICES: DNAT ClusterIP → pod IP
        │  ip_forward=1
        ▼  node routes to backend pod
     200 OK   ✅ (and survives reboot, because it all replays)
```

The pivotal hop is step 10: the *only reason* a bridged packet visits iptables at all is the module+knob loaded back at steps 5–6. Miss them and step 10 silently drops into a black hole — ping still works (that's plain L3, no Service DNAT needed), which is exactly why the bug is so confusing.

> **Check yourself before Rung 6:** In this trace, `ping pod-ip` between two pods works even on a *mis-tuned* node, but `curl clusterip` only works on the tuned one. Point to the exact step that explains the difference, and say which kernel feature the ping never needed.

---

## ⚖️ Rung 6 — The Contrast

**The older/alternative approaches: recompiling the kernel, and the `/etc/sysctl.conf` monolith + `/etc/modules` list.**

Before loadable modules and drop-in config directories, tuning the kernel meant one of these:

- **Recompile the kernel** (`make menuconfig` → `make` → install → reboot) to add a driver or change a compiled-in default. Correct, powerful, and *glacially* slow — every change is a build and a reboot, and your fleet drifts into a zoo of bespoke kernels.
- **One giant `/etc/sysctl.conf`** and a flat `/etc/modules` file. Runtime-tunable (good) but a *single shared file*: two tools (say, your base image and a Kubernetes setup script) both editing it stomp each other, and there's no clean per-concern separation.

The modern way keeps the runtime flexibility and adds **composability** via drop-in directories:

```
OLD                                      NEW (drop-in dirs)

recompile kernel to add overlay   →      modprobe overlay        (live)
                                         /etc/modules-load.d/k8s.conf (boot)

edit the one /etc/sysctl.conf     →      /etc/sysctl.d/k8s.conf   ← K8s owns this file
   (everyone fights over it)             /etc/sysctl.d/99-tuning.conf ← you own this one
                                         sysctl --system applies ALL of them, in order
```

| Capability | Modules + `sysctl` + drop-in dirs | Recompile kernel | One `/etc/sysctl.conf` |
|---|---|---|---|
| Add a feature/driver without reboot | ✅ `modprobe` | ❌ rebuild + reboot | n/a (not what it does) |
| Change behavior on the live kernel | ✅ `sysctl -w` | ❌ rebuild + reboot | ✅ but edit + reload |
| Per-concern config files (no stomping) | ✅ drop-in `*.d/` | n/a | ❌ one shared file |
| Survives reboot | ✅ via `*.d/` replay | ✅ (baked in) | ✅ |
| Remove a feature at runtime | ✅ `modprobe -r` | ❌ | n/a |
| Change something *only compiled-in* (e.g. enable a scheduler class) | ❌ needs rebuild | ✅ the only way | ❌ |
| Auditability across a fleet | ✅ same files everywhere | ⚠️ kernel-per-host drift | ⚠️ merge conflicts |

**When would I NOT reach for this?** When the thing you need is **compiled into the kernel, not a module or a sysctl** — e.g. enabling a kernel feature that ships disabled at build time, or a security hardening that's a compile flag. Then a custom kernel (or a different distro kernel package) is genuinely the only path. Also, a handful of settings are **boot-time only** and can't be changed live — they belong on the kernel command line in GRUB (e.g. forcing cgroup v2 with `systemd.unified_cgroup_hierarchy=1`, or `cgroup_no_v1=all`), applied by editing `/etc/default/grub` and rerunning `update-grub`, then rebooting.

**Why modules + sysctl + drop-in dirs over the alternatives, in one sentence:** *You get live, reversible, per-concern kernel tuning that any automation (kubeadm, cloud-init, your base image) can compose without recompiling anything or fighting over one file — which is exactly the shape of provisioning a fleet of identical Kubernetes nodes.*

> **Check yourself before Rung 7:** Your team wants every node to force cgroup v2. Explain why this one is different from setting `ip_forward=1` — which mechanism must you use, which file do you edit, and why won't `sysctl -w` or a drop-in do it?

---

## 🧪 Rung 7 — The Prediction Test

Now you commit to a prediction *before* running each command. The learning is in the gap between prediction and result. These assume **Ubuntu 22.04, systemd, cgroup v2**, and root (`sudo -i` or prefix `sudo`). Distro differences are noted where they bite.

First, orient yourself — read the boot params and cgroup version the node actually came up with:

```bash
cat /proc/cmdline
# BOOT_IMAGE=/boot/vmlinuz-5.15.0-XX-generic root=UUID=…  ro quiet splash
#   ↑ this is exactly what GRUB handed the kernel; root= is which disk it mounted

stat -f -c %T /sys/fs/cgroup
# cgroup2fs   -> unified v2 (modern default; what kubelet/containerd expect)
```

---

### Example 1 — The normal case: a live sysctl change takes effect instantly but vanishes on reboot

**Prediction:** *If I read `net.ipv4.ip_forward`, it will be `0` on a stock (non-K8s) box; if I `sysctl -w` it to `1`, the change is instant and the backing file `/proc/sys/net/ipv4/ip_forward` also reads `1` — BECAUSE the sysctl name and that file are the same object, and the write flips a live flag in the IPv4 stack. But it will NOT survive a reboot, because `/proc` is RAM-backed and nothing replays my ad-hoc write.*

```bash
# Read it two equivalent ways — they show the SAME value:
sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 0
cat /proc/sys/net/ipv4/ip_forward
# 0

# Turn the dial on the LIVE kernel:
sysctl -w net.ipv4.ip_forward=1
# net.ipv4.ip_forward = 1

# Prove the file changed too (same object):
cat /proc/sys/net/ipv4/ip_forward
# 1
```

**Verify:** The `cat` after the write reads `1` — confirming `sysctl -w` *is* a write to that file. **The reboot test:** if you rebooted now without persisting, it would revert to `0`. **A wrong result** — it was already `1` before you wrote it — means Kubernetes/Docker already persisted it (check `/etc/sysctl.d/`), which is itself the lesson: persistence is what makes it stick. To persist it properly, see Example 3.

---

### Example 2 — The edge/failure case: the K8s bridge sysctl doesn't exist until its module is loaded

**Prediction:** *If I try to set `net.bridge.bridge-nf-call-iptables` on a fresh node where `br_netfilter` isn't loaded, it will FAIL with "No such file or directory" — BECAUSE that sysctl file is registered by the `br_netfilter` module and simply doesn't exist yet. After `modprobe br_netfilter`, the same write will succeed, because loading the module created the `/proc/sys/net/bridge/` subtree.*

```bash
# Confirm the module is NOT loaded (no output = not loaded):
lsmod | grep br_netfilter
#   (nothing)

# Try to set the sysctl BEFORE loading the module — expect failure:
sysctl -w net.bridge.bridge-nf-call-iptables=1
# sysctl: cannot stat /proc/sys/net/bridge/bridge-nf-call-iptables: No such file or directory

# Now load the module (modprobe, NOT insmod — it resolves dependencies):
modprobe br_netfilter

# Verify it loaded:
lsmod | grep br_netfilter
# br_netfilter           32768  0
# bridge                307200  1 br_netfilter    ← note: it pulled in `bridge` as a dep

# The sysctl file now EXISTS — the same write succeeds:
sysctl -w net.bridge.bridge-nf-call-iptables=1
# net.bridge.bridge-nf-call-iptables = 1
```

**Verify:** The first write fails with `No such file or directory`; after `modprobe`, `lsmod` shows `br_netfilter` (and `bridge` as a dependency it pulled in — proof `modprobe` did dep resolution that `insmod` wouldn't), and the write succeeds. **A wrong result** — the first write *succeeds* — means `br_netfilter` was already loaded (some base images pre-load it) or built into your kernel; `lsmod | grep br_netfilter` up front tells you which world you're in. **The Kubernetes lesson:** this exact ordering (module first, sysctl second) is why kubeadm guides always load modules before writing sysctls, and why the persisted config needs *both* drop-in files.

You can inspect a module without loading it:

```bash
modinfo overlay
# filename: /lib/modules/5.15.0-XX-generic/kernel/fs/overlayfs/overlay.ko
# alias:    fs-overlay
# license:  GPL
# description: Overlay filesystem
#   ↑ confirms overlay is a LOADABLE module here (not built-in) and where its .ko lives
```

---

### Example 3 — The Kubernetes case: persist the full node prerequisite set so it survives reboot

**Prediction:** *If I write the two modules to `/etc/modules-load.d/k8s.conf` and the sysctls to `/etc/sysctl.d/k8s.conf`, then load them once by hand, the node will be Kubernetes-ready NOW and stay ready across reboots — BECAUSE `systemd-modules-load` and `systemd-sysctl` replay those exact drop-in files on every boot, and `sysctl --system` re-applies them immediately without waiting for a reboot.*

```bash
# 1) Persist the MODULES (replayed at boot by systemd-modules-load):
echo -e "overlay\nbr_netfilter" > /etc/modules-load.d/k8s.conf

# Load them NOW too (persistence alone doesn't load them this boot):
modprobe overlay
modprobe br_netfilter

# 2) Persist the SYSCTLS (replayed at boot by systemd-sysctl):
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 512
fs.inotify.max_user_watches         = 524288
EOF

# 3) Apply ALL sysctl.d files to the LIVE kernel right now (no reboot):
sysctl --system
# * Applying /etc/sysctl.d/k8s.conf ...
# net.bridge.bridge-nf-call-iptables = 1
# net.ipv4.ip_forward = 1
# fs.inotify.max_user_watches = 524288
#   … (also re-applies every other file it finds, in lexical order)
```

**Verify:** Read the values back and confirm they stuck:

```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables fs.inotify.max_user_watches
# net.ipv4.ip_forward = 1
# net.bridge.bridge-nf-call-iptables = 1
# fs.inotify.max_user_watches = 524288
```

A **reboot** would now leave these intact because the boot units replay the two files. **A wrong result** — `sysctl --system` errors on the `net.bridge.*` lines — means step 1's `modprobe br_netfilter` didn't run this boot, so the file doesn't exist yet (load the module, rerun). **The payoff:** this is precisely the tuning kubeadm's preflight checks for; do this and `kubeadm init` sails past the `bridge-nf-call-iptables`, `ip_forward`, and file-content errors from Rung 0.

---

### Example 4 — The swap case: why kubelet wanted it off, and how to make "off" permanent

**Prediction:** *If I check `free -h`, a stock cloud image may show a nonzero Swap line; `swapoff -a` disables it live (Swap total → 0), satisfying the kubelet's `failSwapOn`. But swap comes BACK on reboot unless I also remove it from `/etc/fstab` — BECAUSE `swapoff -a` only affects the running kernel; the boot process re-enables any swap listed in fstab.*

```bash
# See current memory + swap:
free -h
#               total  used   free  shared  buff/cache  available
# Mem:           7.8Gi 1.2Gi  5.9Gi   12Mi      0.7Gi      6.3Gi
# Swap:          2.0Gi    0B  2.0Gi          ← swap is ON (bad for kubelet by default)

# Disable ALL swap on the live kernel:
swapoff -a

# Confirm it's gone NOW:
free -h
# Swap:            0B     0B     0B          ← kubelet failSwapOn is satisfied

# Make it PERMANENT — comment out swap entries so boot won't re-enable them:
sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab
grep -i swap /etc/fstab
# #/swap.img   none  swap  sw  0  0          ← now commented; won't come back
```

**Verify:** After `swapoff -a`, `free -h` shows `Swap: 0B` across the board. After the fstab edit, a reboot keeps swap off. **A wrong result** — swap reappears after reboot — means an entry in `/etc/fstab` (or a `swap.target`/systemd swap unit, or cloud-init) is re-enabling it; on some cloud images you also `systemctl mask swap.target` or disable the provider's swap unit. **The Kubernetes nuance to state out loud:** historically the kubelet *refused* to run with swap on (`failSwapOn: true`) so that a page charged to a cgroup was guaranteed to be real RAM, keeping OOM behavior (see [cgroups](14-cgroups.md)) predictable. **Newer Kubernetes (beta swap support, `NodeSwap`)** lets you deliberately run with swap by setting `failSwapOn: false` and a `memorySwap` behavior in the kubelet config — but it's opt-in, node-scoped, and only for cgroup v2. Unless you've explicitly enabled it, swap off is still the default expectation.

---

### The prediction habit, generalized

Fill this in for any kernel knob or module you touch:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

## 🏔 Rung 8 — Capstone: Compress It

**One-sentence summary:** A Linux machine boots firmware → GRUB → kernel+initramfs → systemd (PID 1), and from there you tune the *running* kernel by snapping in modules (`modprobe`) and turning sysctl dials (`/proc/sys`) — changes that are instant but volatile, made permanent only by drop-in files (`/etc/modules-load.d/`, `/etc/sysctl.d/`) that the boot process replays, which is exactly the set of prerequisites — `overlay`, `br_netfilter`, `bridge-nf-call-iptables=1`, `ip_forward=1`, swap off — a Kubernetes node needs.

**Explain it to a beginner in three sentences:** When a computer turns on, a chain of programs each loads the next until Linux hands control to `systemd`, the first real process, which then applies your saved settings and starts services. You can change how the kernel behaves *while it's running* by loading feature modules and writing tiny setting files under `/proc/sys`, but those changes disappear on reboot unless you also save them in special config folders that get re-applied every boot. Kubernetes needs a specific few of these — a filesystem module, a bridge-networking module and switch, packet forwarding turned on, and swap turned off — or Services and pod networking silently fail.

**Sub-capabilities, each mapped back to the one core idea (configure the live kernel via files; persist via boot replay):**

| Sub-capability | Which part of the one idea it is |
|---|---|
| `modprobe overlay` / `br_netfilter` | **snap a feature in** to the live kernel |
| `/etc/modules-load.d/k8s.conf` | **persist** the module load; boot **replays** it |
| `sysctl -w net.ipv4.ip_forward=1` | **turn a dial** on the live kernel (a `/proc/sys` file) |
| `/etc/sysctl.d/k8s.conf` + `sysctl --system` | **persist** the dial; replayed at boot / re-applied now |
| `bridge-nf-call-iptables=1` needing `br_netfilter` first | modules **register** the sysctl files dials live in |
| firmware → GRUB → kernel → PID 1 → targets | the boot chain that **does the replay** at the end |
| `/proc/cmdline` & GRUB cmdline (cgroup v2) | boot-time-only config, set **before** the live kernel exists |
| `swapoff -a` + fstab / `free -h` | a **dial-like** state the kubelet checks; persist via fstab |
| `fs.inotify.max_user_watches` | a **dial** scaled up so many pods can watch files |

**Which rung to revisit hands-on:** **Rung 7, Examples 2 and 3.** Example 2 makes the module→sysctl ordering dependency real in 20 seconds — do it until "the sysctl doesn't exist until the module is loaded" is reflex, because that single fact demystifies half of all "my CNI is broken" tickets. Then Example 3 is the one you'll actually run on every node you build; being able to write both drop-in files and prove they survive a reboot is the difference between a fix that holds and a 3 a.m. page after the next kernel patch. If the boot chain in Rung 3A still feels like a blur, `cat /proc/cmdline` and `systemd-analyze critical-chain` on a live node to watch the real handoff, and `systemctl status systemd-sysctl systemd-modules-load` to see the replay units that tuned your kernel.

---

## Related concepts

- [iptables-netfilter](12-iptables-netfilter.md) — why `br_netfilter` + `bridge-nf-call-iptables=1` are the gate that lets kube-proxy's `KUBE-*` chains see bridged pod traffic
- [cgroups](14-cgroups.md) — why swap-off keeps memory accounting honest, and where the kernel command line forces cgroup v2
- [systemd-services](16-systemd-services.md) — PID 1, targets, and the `systemd-modules-load` / `systemd-sysctl` units that replay your tuning at boot
- [storage-mounts](15-storage-mounts.md) — OverlayFS (the `overlay` module) as containerd's image-layer snapshotter, plus swap and fstab
- [linux-philosophy](01-linux-philosophy.md) — "everything is a file": why `cat`/`echo` on `/proc/sys` is the entire sysctl API
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full Linux↔Kubernetes mapping and node-triage quick reference

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Pods on the same node can ping each other by IP, but `curl` to a ClusterIP Service times out. Which two kernel prerequisites are most likely missing, and why doesn't "ping works" rule them out?

**A:** The two likely-missing prerequisites are (1) the **`br_netfilter` module plus `net.bridge.bridge-nf-call-iptables=1`** — the bridge-and-iptables one — and (2) **`net.ipv4.ip_forward=1`** — the forwarding one. Without br_netfilter and its sysctl, packets crossing the Linux bridge that connects pods bypass iptables entirely, so kube-proxy's `KUBE-SERVICES` chain never fires and the ClusterIP is never DNAT'ed to a real pod IP; without ip_forward, the node won't route packets between interfaces/veths at all. "Ping works" rules out neither, because pod-to-pod ping by IP is plain L3 traffic across the bridge that needs no Service DNAT and no iptables traversal — it succeeds even while every bridged packet is bypassing netfilter. Only Service traffic, which depends on the DNAT happening in the `KUBE-*` chains, exposes the missing knobs — which is why this is the classic "my CNI is broken" ghost.

### Before Rung 3
**Q:** You ran `sysctl -w net.ipv4.ip_forward=1`, kubeadm passed, weeks later the node reboots and pods can't reach Services. What did you forget, and which boot-time component would have replayed it?

**A:** `sysctl -w` only wrote the live, RAM-backed `/proc/sys` file — a volatile change that a reboot wipes back to the default `0`. You forgot the persistence half: writing the knob into a drop-in file such as `/etc/sysctl.d/k8s.conf` (and, for the modules, `/etc/modules-load.d/k8s.conf`). The boot-time component that would have replayed it is **`systemd-sysctl.service`**, which systemd runs on the way up to read `/etc/sysctl.d/*` and re-apply every knob (its sibling `systemd-modules-load.service` replays the module list). The one-sentence rule: live changes are instant but volatile; only config files that the boot process replays make them permanent.

### Before Rung 4
**Q:** Why can `sysctl -w net.bridge.bridge-nf-call-iptables=1` fail with "No such file or directory" on a fresh node, and what single command fixes it? Which subsystem creates that file?

**A:** Cause-and-effect order: on a fresh node the **`br_netfilter` module** is not loaded; that module is what *registers* the `net/bridge/` sysctl subtree; therefore the file `/proc/sys/net/bridge/bridge-nf-call-iptables` simply does not exist yet; so the write fails with `cannot stat ... No such file or directory`. The single command that makes it succeed is `modprobe br_netfilter` — loading the module creates the `/proc/sys/net/bridge/` subtree (and modprobe also pulls in the `bridge` dependency), after which the identical `sysctl -w` succeeds. The file is created by the br_netfilter kernel module registering its sysctls — which is exactly why every kubeadm guide loads modules first and writes sysctls second, and why persistence needs both `/etc/modules-load.d/k8s.conf` and `/etc/sysctl.d/k8s.conf`.

### Before Rung 5
**Q:** Which two files must a colleague `cat` to answer "is `ip_forward` on right now, and will it survive a reboot?" — and which term connects the second file to the boot process?

**A:** For "is it on right now," `cat /proc/sys/net/ipv4/ip_forward` — the virtual file that *is* the sysctl `net.ipv4.ip_forward` (dots become slashes), showing the live kernel's value. For "will it survive a reboot," `cat /etc/sysctl.d/k8s.conf` (or whichever `/etc/sysctl.d/*.conf` drop-in holds the line `net.ipv4.ip_forward = 1`) — the persisted setting. The connecting term is **`systemd-sysctl`** (systemd-sysctl.service), the boot unit that reads `/etc/sysctl.d/*` and re-applies each knob on every boot — the same "boot unit replays a drop-in directory" pattern that `systemd-modules-load` : `/etc/modules-load.d/` follows for modules.

### Before Rung 6
**Q:** In the trace, `ping pod-ip` works even on a mis-tuned node, but `curl clusterip` only works on the tuned one. Which step explains the difference, and which kernel feature did the ping never need?

**A:** The difference is **step 10**: when the pod curls a ClusterIP, the packet crossing the node's Linux bridge is handed to netfilter *only because* `br_netfilter` is loaded and `bridge-nf-call-iptables=1` (from steps 5–6), letting kube-proxy's `KUBE-SERVICES` chain DNAT the ClusterIP to a real pod IP (and `ip_forward=1` then routes the rewritten packet on). Ping between pod IPs never needed that feature: it is plain L3 traffic to a real, existing pod IP with no Service DNAT required, so it never depends on bridged traffic traversing iptables — the `br_netfilter` + `bridge-nf-call-iptables` hook is the kernel feature ping never touched. On a mis-tuned node the Service packet drops into a black hole while ping keeps working, which is exactly why the bug is so confusing.

### Before Rung 7
**Q:** Your team wants every node to force cgroup v2. Why is this different from setting `ip_forward=1` — which mechanism, which file, and why won't `sysctl -w` or a drop-in do it?

**A:** Forcing cgroup v2 is a **boot-time-only** setting, not a runtime sysctl dial: the cgroup hierarchy mode is decided as the kernel comes up, before any live tuning is possible, so it must go on the **kernel command line** that GRUB hands the kernel — e.g. `systemd.unified_cgroup_hierarchy=1` (or `cgroup_no_v1=all`). The mechanism is editing **`/etc/default/grub`**, rerunning `update-grub`, and rebooting; you can confirm it took effect with `cat /proc/cmdline` and `stat -f -c %T /sys/fs/cgroup` (expect `cgroup2fs`). `sysctl -w` and `/etc/sysctl.d/` drop-ins can't do it because there is no `/proc/sys` file backing this choice — it isn't a tunable of the running kernel at all; it's a parameter that must exist *before* the live kernel does, unlike `ip_forward`, which is an ordinary live dial you flip and then persist.
