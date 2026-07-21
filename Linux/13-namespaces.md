# Linux Namespaces
> A namespace is a private copy of one kind of kernel resource — and a container is just a process the kernel lied to about what exists. Learn the eight lies, and containers stop being magic.

---

## Rung 0 — 🛠 The Setup

**What am I learning?** Linux **namespaces** — the kernel feature that gives a process its own private view of a global resource (its own process list, its own network stack, its own filesystem root, its own hostname). Namespaces are the *"what a process can SEE"* half of a container. The other half is cgroups (what a process is *allowed to USE* — CPU, memory), which live next door in [14-cgroups.md](14-cgroups.md). Together those two features **are** a container. There is no `container` object in the kernel; there is a process wearing a set of namespaces and a cgroup.

**Why did it land on my desk?** Pick your on-call flavor:
- A pod is `CrashLoopBackOff` and the image is **distroless** — no shell, no `ls`, no `cat`. `kubectl exec` fails with `exec: "/bin/sh": stat /bin/sh: no such file or directory`. You need to look inside a container that has no tools of its own.
- Two containers in the same pod can reach each other on `localhost:8080` but a container in a *different* pod cannot. Why does `localhost` mean "the pod" and not "the node"?
- CNI is broken. Pods come up but get no IP, or can't reach each other. Someone says "the veth pair didn't get moved into the pod's netns." You need to know what that sentence means.
- You run `ps aux` inside a container and PID 1 is your app, but `ps aux` on the node shows that same app as PID 48213. Which number is real?

Every one of these is a **namespace** question wearing a Kubernetes costume. You cannot answer them from the `kubectl` layer — the answers live one floor down, in the kernel.

**What do I already know?** You are fluent in `kubectl`, pods, and deployments. You know a container "isolates" a process. You've heard "a pod shares a network namespace." What you may not have yet is the mechanical picture: that *isolation* is not a wall the kernel builds around a process, but a **private lookup table** the kernel hands the process so that when it asks "what processes exist?" or "what is my IP?", it gets a filtered answer. By the end you will read `/proc/PID/ns/`, compare inode numbers to prove two processes share a namespace, build a network namespace and a veth pair by hand (exactly what CNI does), and use `nsenter` to debug a distroless container from the node.

---

## Rung 1 — 🔥 The Pain

**The problem that forced namespaces to exist.** A normal Unix process shares almost everything global with every other process on the machine:
- **One** process table — every process can `kill` or `ps` every other process (subject to permissions).
- **One** network stack — one set of interfaces, one routing table, one `:80` that only one process can bind.
- **One** filesystem tree rooted at `/` — everyone sees the same `/etc/hosts`, the same `/usr`.
- **One** hostname, **one** set of System V IPC queues, **one** user/group ID space.

That is fine for a single-tenant server. It is a disaster the moment you want to run **many independent workloads on one host** — the original use case being cheap, dense hosting (thousands of "virtual servers" on one kernel). Two tenants both want to run a process called PID 1. Both want to bind `:80`. Both want a `/etc/hosts`. Both want the hostname `web`. On a shared global kernel, they collide, they can see each other, and one can `kill` the other.

**What people did before, and why it hurt.**
- **`chroot` (1979)** gave you a private *filesystem root* and nothing else. Your process still saw every other process, shared the network, shared the hostname, and — famously — a root process could break *out* of a chroot. It solved 1/8th of the problem.
- **Full virtual machines (VMware, KVM)** gave perfect isolation by booting an entire second kernel per tenant. It worked, but the tax is brutal: every VM carries a full OS, gigabytes of RAM, a boot cycle measured in tens of seconds, and a hypervisor between the workload and the CPU. To run 200 small services you booted 200 kernels.
- **BSD Jails / Solaris Zones** were closer to the right idea (OS-level isolation, one kernel) but were whole-hog and not composable — you couldn't say "isolate the network but *share* the filesystem."

**What breaks without namespaces, for you specifically.** Without namespaces there is no container, so there is no Kubernetes. Concretely, the pain that namespaces relieve is exactly the pain Kubernetes depends on being solved:
- Two pods each need to think *they* own PID 1 and can bind `:8080`. On a shared host that's impossible — namespaces make each pod's PID 1 and `:8080` private.
- A pod must have its **own IP** and its own routing table, independent of the node's. That's a network namespace.
- A container must see its **own** `/` (its image's root filesystem) without seeing the node's `/`. That's a mount namespace.

**Who feels the pain most?** The platform engineer who has to run hundreds of mutually-distrusting workloads on shared nodes at high density and low latency — that is, you. VMs were too heavy; `chroot` was too weak. Namespaces are the "one kernel, many private views, composable per resource" answer that made the container economy possible.

> Check yourself before Rung 2: `chroot` isolated the filesystem and *nothing else*. From that single fact, *derive* how many *more* "chroot-like" features the kernel would need before a process could be fooled into thinking it's alone on the machine — and roughly what each one would have to privatize.

---

## Rung 2 — 💡 The One Idea

Here is the sentence. Memorize it exactly:

> **A namespace makes one kind of global kernel resource appear private to the processes inside it, so those processes see their own isolated instance of that resource instead of the host's.**

That's the whole trick. Everything else is detail. Two corollaries fall right out and are worth burning in:

1. **Isolation is per-resource-kind, and composable.** There isn't *one* "container namespace." There are **eight independent kinds**, and a process holds a set — one membership per kind. You can privatize the network but *share* the filesystem, privatize PIDs but *share* the hostname. **This composability is the entire secret behind a Kubernetes pod:** the containers in a pod *share* net + ipc + uts namespaces (same IP, same `localhost`, same hostname) but each get their *own* mnt + pid (own filesystem, own process tree). A pod is a hand-picked namespace-sharing recipe.

2. **A namespace is a "what can I SEE" filter, not a "what can I DO" wall.** It changes the *answer the kernel gives* when a process asks "what processes exist / what's my IP / what's at `/`". It does **not** limit CPU or memory — that's cgroups. Say it out loud: **namespaces = visibility; cgroups = resource limits.** Confusing the two is the #1 beginner mistake.

Watch how much derives from the One Idea:
- "one kind of resource appears private" → therefore there is a **list of kinds**: pid, net, mnt, uts, ipc, user, cgroup, time (**8 of them**).
- "appears private to the processes inside it" → therefore a namespace is a thing with an **identity** you can point at and compare — it's represented as a file (an inode) under `/proc/PID/ns/`. Two processes in the *same* namespace point at the *same* inode.
- "instead of the host's" → therefore there's always a **root/host namespace** you started in, and creating a new one (`unshare`, `clone`) forks off a private copy, while `nsenter` lets you *join* an existing one.

If you remember only one thing: **a container is a process the kernel lied to about what exists, and the lie is told one resource-kind at a time.**

> Check yourself before Rung 3: Using only the One Idea, explain why "the containers in a pod share `localhost`" and "each container in a pod has its own `/`" are *not* contradictory — which clause of the sentence makes both true at once?

---

## Rung 3 — ⚙️ The Machinery (the important one — go slow)

We now open the hood. There are four things to understand: **(A) the eight kinds and exactly what each privatizes, (B) how a namespace is represented as a file you can inspect and compare, (C) how a process gets into a new or existing namespace, and (D) how this composes into a Kubernetes pod.**

### 3.1 The eight namespace kinds — what each one actually isolates

Every namespace privatizes exactly one class of global kernel state. Learn the table; the rest of Linux containerization is applied knowledge of it.

| # | Kind | Flag (`clone`/`unshare`) | What becomes private | The tell — how you notice it |
|---|------|--------------------------|----------------------|------------------------------|
| 1 | **pid** | `CLONE_NEWPID` | The process-ID number space. First process inside becomes **PID 1**. Processes inside can't see or signal processes outside. | `ps` inside shows a tiny tree starting at PID 1 |
| 2 | **net** | `CLONE_NEWNET` | Network interfaces, routing tables, iptables/nftables rules, socket port space (`:80`), `/proc/net`. A fresh netns has only a `lo` (down). | Your own IP, your own routing table, your own listening ports |
| 3 | **mnt** | `CLONE_NEWNS` | The mount table — the set of what's mounted where, i.e. the filesystem tree the process sees, including its `/`. | A private `/`; mounts you make don't leak to the host |
| 4 | **uts** | `CLONE_NEWUTS` | The **hostname** and **domainname** (UTS = UNIX Time-sharing System). | `hostname foo` inside doesn't rename the host |
| 5 | **ipc** | `CLONE_NEWIPC` | System V IPC (message queues, semaphores, shared memory segments) and POSIX message queues. | `ipcs` shows a private, empty set |
| 6 | **user** | `CLONE_NEWUSER` | The UID/GID number space — maps IDs inside to different IDs outside. **root (0) inside can be an unprivileged UID outside.** The only namespace an unprivileged user can create unaided. | `id` shows root inside; on the host you're UID 1000 |
| 7 | **cgroup** | `CLONE_NEWCGROUP` | The cgroup **root** the process sees under `/proc/PID/cgroup` and `/sys/fs/cgroup` — hides the host's cgroup tree above the container's own node. | Container thinks it's at the cgroup root, not buried under `kubepods` |
| 8 | **time** | `CLONE_NEWTIME` | The offsets for `CLOCK_MONOTONIC` and `CLOCK_BOOTTIME` (boot/uptime clocks). **Note:** the wall-clock (`CLOCK_REALTIME`) is *not* namespaced. Newest of the eight (kernel 5.6, 2020). | A container can show a different uptime/boot time |

Two things to burn in:
- **`user` is special.** It's the only namespace an ordinary user can create without being root, *and* it can be a parent that grants the ability to create the other seven. This is how "rootless containers" (Podman without root) work, and it's a big attack surface — many CVEs live here.
- **`time` does NOT change `date`.** People expect a "time namespace" to fake the clock for a container. It doesn't touch wall-clock; it only offsets the monotonic/boot clocks. Kubernetes barely uses it.

### 3.2 A namespace is a file — the inode is its identity

Here is the mechanism that makes namespaces *inspectable*, and it's beautifully in keeping with Linux's "everything is a file" philosophy ([01-linux-philosophy.md](01-linux-philosophy.md)). For every process, the kernel exposes its namespace memberships as a directory of magic symlinks:

```
/proc/<PID>/ns/
├── pid    -> pid:[4026531836]
├── net    -> net:[4026531840]
├── mnt    -> mnt:[4026531841]
├── uts    -> uts:[4026531838]
├── ipc    -> ipc:[4026531839]
├── user   -> user:[4026531837]
├── cgroup -> cgroup:[4026531835]
└── time   -> time:[4026531834]
```

Each symlink's target is `kind:[INODE_NUMBER]`. That number **is the namespace's identity**. The rule is dead simple and it's the single most useful debugging fact in this whole document:

> **Two processes are in the SAME namespace of a given kind if and only if their `/proc/PID/ns/<kind>` symlinks point at the same inode number.**

So to answer "do these two containers share a network namespace?" you don't guess — you compare two integers. The numbers `4026531xxx` are the **host/root** namespaces (they start high and are the same across all normal processes). A containerized process will show *different*, lower-or-differently-numbered inodes for the kinds it has privatized, and the *same* host numbers for the kinds it still shares.

A namespace lives as long as *something* references it: a member process, a bind-mount of its `ns` file, or an open file descriptor to it. When the last reference goes away, the kernel destroys the namespace. **This is why Kubernetes needs the pause container** (§3.4) — something has to hold the pod's namespaces open while app containers restart.

### 3.3 Getting into a namespace: create (`unshare`/`clone`) vs join (`setns`/`nsenter`)

There are exactly three syscalls in play, and every tool is a wrapper over them:

```
                 ┌────────────────────────────────────────────────┐
                 │  THREE SYSCALLS, THREE VERBS                    │
                 ├────────────────────────────────────────────────┤
   clone(2)      │  CREATE a NEW process directly INTO new ns(s)   │
                 │  → this is how containerd/runc start a container│
                 ├────────────────────────────────────────────────┤
   unshare(2)    │  Move the CALLING process into NEW ns(s) now    │
                 │  → CLI tool: `unshare`                          │
                 ├────────────────────────────────────────────────┤
   setns(2)      │  JOIN an EXISTING ns (via an fd to its ns file) │
                 │  → CLI tool: `nsenter`  (= what kubectl exec does)│
                 └────────────────────────────────────────────────┘
```

- **`clone(2)`** — like `fork()` but you pass `CLONE_NEW*` flags to say "put the child in fresh namespaces of these kinds." This is the birth of a container. `runc` calls this.
- **`unshare(2)`** — "un-share" the calling process from the host: give *me* a new namespace of these kinds, right now. The `unshare` CLI wraps it.
- **`setns(2)`** — given a file descriptor to an existing `/proc/PID/ns/<kind>` file, *enter* that namespace. The `nsenter` CLI wraps it. This is join, not create.

**The PID-namespace gotcha (why `--fork --mount-proc` exists).** The PID namespace has a special rule: `unshare(CLONE_NEWPID)` does **not** move the calling process into the new PID namespace — it only makes the process's *children* land there as PID 1. That's because a process's PID can't change under its feet. So `unshare --pid` alone does almost nothing useful; you need `--fork` so `unshare` forks a child (which becomes PID 1 in the new namespace) and runs your shell there. And `ps` reads `/proc`, which is still the *host's* `/proc` unless you also give it a fresh mount namespace and remount `/proc` — that's `--mount-proc`, which does `unshare(CLONE_NEWNS)` + mounts a new procfs so `ps` reflects the new PID view. Hence the canonical incantation `unshare --pid --fork --mount-proc bash`.

### 3.4 How this composes into a Kubernetes pod

Now the payoff. A **pod** is not a kernel object — it's a *recipe for which namespaces a group of containers share*. The kubelet, via the CRI (Container Runtime Interface) and containerd, implements it like this:

```
   NODE (host namespaces: host net, host pid, host mnt, ...)
   │
   │   kubelet ── CRI ──► containerd ──► runc
   │
   ▼
   ┌──────────────────────── POD "web" ────────────────────────┐
   │                                                            │
   │   [ pause / sandbox container ]  ← created FIRST           │
   │        holds:  net ns  ipc ns  uts ns   (the shared ones)  │
   │        does nothing else: sleeps forever, reaps zombies    │
   │                                                            │
   │        ┌──────────────┐        ┌──────────────┐            │
   │        │  app: nginx  │        │ sidecar: log │            │
   │        │  OWN mnt ns  │        │  OWN mnt ns  │            │
   │        │  OWN pid ns* │        │  OWN pid ns* │            │
   │        │  SHARES net  │        │  SHARES net  │  ◄── both  │
   │        │  SHARES ipc  │        │  SHARES ipc  │      join  │
   │        │  SHARES uts  │        │  SHARES uts  │      pause │
   │        └──────────────┘        └──────────────┘      ns    │
   │             one IP, one localhost, one hostname            │
   └────────────────────────────────────────────────────────────┘
   * pid ns is per-container by default; shareProcessNamespace:true
     merges them into one pod-wide pid ns.
```

Step by mechanism:
1. **kubelet** tells **containerd** "start a pod sandbox." containerd (via runc/`clone`) creates the **pause container** — a tiny process that just calls `pause()` and sleeps forever. Its whole job is to **create and hold open** the pod's **net + ipc + uts** namespaces. Because a namespace lives as long as a member process references it (§3.2), the pause container is the anchor.
2. **CNI** is invoked against the pause container's **network namespace**: it creates a **veth pair** and moves one end into that netns, giving the pod its IP (see the Trace, Rung 5). Because app containers *join* the pause container's netns, they all get that same IP.
3. Each **app container** is started with `setns` into the pause container's net/ipc/uts namespaces (that's `CLONE_NEWNET` *not* set for those; instead runc joins the existing ones), but with its **own fresh mnt namespace** (so it sees its own image's `/`) and its **own pid namespace** (unless `shareProcessNamespace: true`).
4. App containers can be killed and restarted (`CrashLoopBackOff`) all day; the **pause container never dies**, so the pod keeps its IP and namespaces across restarts. That's the deep reason the sandbox exists.

And `kubectl exec`? It's just **`nsenter`** (well, the CRI's `exec`, which does `setns`) into that container's namespaces, then runs your command there. That's the whole magic. When you understand `nsenter`, you understand `kubectl exec`.

> Check yourself before Rung 4: A pod's app container crashes and restarts 50 times, but the pod's IP never changes. Using §3.2 and §3.4, explain *mechanically* why the IP survives — which process holds which namespace, and what would happen to the IP if that process died.

---

## Rung 4 — 🏷️ The Vocabulary Map

| Term | What it actually is | Which machinery it touches |
|------|--------------------|-----------------------------|
| **Namespace** | A private instance of one kind of global kernel resource | The whole show; §3.1 |
| **PID namespace** | Private process-ID number space; first process = PID 1 | §3.1 #1; the `--pid --fork` dance |
| **Network namespace (netns)** | Private interfaces, routes, iptables, port space | §3.1 #2; CNI, `ip netns`, veth |
| **Mount namespace (mnt)** | Private mount table → private filesystem tree / `/` | §3.1 #3; `--mount-proc`, container rootfs |
| **UTS namespace** | Private hostname + domainname | §3.1 #4; pod hostname |
| **IPC namespace** | Private System V / POSIX IPC objects | §3.1 #5; shared within a pod |
| **User namespace** | Private UID/GID map; root-inside ≠ root-outside | §3.1 #6; rootless containers |
| **cgroup namespace** | Private view of the cgroup tree root | §3.1 #7; ties to [14-cgroups.md](14-cgroups.md) |
| **time namespace** | Private monotonic/boot clock offsets (not wall-clock) | §3.1 #8 |
| **`/proc/PID/ns/`** | Directory of magic symlinks, one per namespace kind | §3.2; the inode is the identity |
| **inode number** | The integer that uniquely identifies a namespace instance | §3.2; compare to prove sharing |
| **`clone(2)`** | Syscall: create a new process directly into new namespaces | §3.3; how runc births a container |
| **`unshare(2)` / `unshare`** | Syscall/CLI: move *self* into freshly-created namespaces | §3.3 |
| **`setns(2)` / `nsenter`** | Syscall/CLI: *join* an existing namespace via its ns file | §3.3; = kubectl exec |
| **veth pair** | A virtual Ethernet cable: two linked interfaces; packets in one come out the other | §3.4, Rung 5; the pod's link to the node |
| **pause / sandbox container** | Tiny process that creates & holds the pod's shared namespaces | §3.4; anchors net/ipc/uts |
| **CNI** | Container Network Interface plugin that wires the pod's netns | §3.4, Rung 5 |
| **`lsns`** | CLI that lists all namespaces on the host and their members | Rung 7; the map of everything |
| **`crictl`** | CRI debugging CLI (talks to containerd like kubelet does) | Rung 5/7; gets the container PID |

**"Same kind of thing wearing different names":**
- **`clone` / `unshare` / `setns`** are the three verbs of one idea (create-with-new-process / create-for-self / join-existing). Every tool below is one of these three.
- **`unshare` (CLI) ≈ what runc does at container birth**; **`nsenter` (CLI) ≈ what `kubectl exec` / `crictl exec` / `docker exec` do** — all four are `setns` into a running container's namespaces.
- **`ip netns add` is just a specialized `unshare --net`** plus a bind-mount under `/var/run/netns/` so the netns has a *name* and outlives its creator (that bind-mount is the persistent reference from §3.2).
- **"pod sandbox," "pause container," and "infra container"** are three names for the same anchor process.
- **"container," to the kernel, is not a word at all** — it's a process holding a set of namespaces + a cgroup. "Container" is a userspace convention.

> Check yourself before Rung 5: `ip netns add mypodns` creates a network namespace that *persists* even with no process running in it, but `unshare --net bash` creates one that *vanishes* when you exit the shell. Using §3.2, explain the difference in one sentence — what is `ip netns` holding open that `unshare` isn't?

---

## Rung 5 — 🔬 The Trace

Let's follow ONE concrete action end to end: **CNI gives a brand-new pod its network** — a veth pair, one end on the node, one end in the pod. This is the single most important namespace operation in Kubernetes, and you can reproduce every step by hand. We'll trace it with the exact primitive commands CNI plugins run under the hood.

```
   BEFORE                          AFTER veth is wired
   ┌─────────────┐                 ┌─────────────┐        ┌──────────────┐
   │ node / host │                 │ node / host │        │ pod netns    │
   │ netns       │                 │ netns       │        │ "mypodns"    │
   │             │                 │             │        │              │
   │  eth0       │                 │  eth0       │        │              │
   │             │                 │  veth0 ●━━━━━━━━━━━━━━━● veth1      │
   │             │                 │  (host end) │  cable  │ (pod end)    │
   │             │                 │   ▲ bridged │        │  10.244.1.7  │
   │             │                 │   │ to cni0 │        │  lo up       │
   └─────────────┘                 └───┼─────────┘        └──────────────┘
                                       │
                                   node routing / bridge → real network
```

Step by step, naming who does what:

1. **kubelet → containerd:** "Create pod sandbox." containerd/runc `clone()`s the **pause container** into a fresh **net namespace** (empty: only a down `lo`). *(§3.4)*
2. **containerd → CNI:** kubelet-configured CNI plugin is invoked with the pause container's netns path (something like `/proc/<pausePID>/ns/net`, often bind-mounted to `/var/run/netns/<id>`).
3. **CNI creates the veth pair** in the host netns — two interfaces joined like a cable: `ip link add veth0 type veth peer name veth1`. Right now *both* ends are on the host.
4. **CNI moves one end into the pod:** `ip link set veth1 netns mypodns`. The instant this runs, `veth1` *disappears from the host* and *appears inside the pod's netns*. **This is the namespace primitive doing its one job** — the interface now belongs to a different network namespace.
5. **CNI configures the pod end:** inside the pod netns it renames `veth1` to `eth0`, brings it up, and assigns the IP from the IPAM plugin (`ip addr add 10.244.1.7/24 dev eth0; ip link set eth0 up; ip link set lo up`).
6. **CNI configures the host end:** brings `veth0` up and attaches it to the node bridge (`cni0`) or sets up routes, so packets leaving the pod reach the rest of the cluster.
7. **App containers join:** each app container is `setns`'d into the pause container's netns, so they *inherit* `eth0` and `10.244.1.7`. That's why every container in the pod shares one IP and `localhost`.

The load-bearing hop is **step 4**. "CNI moves one end of the veth into the pod's netns" is the entire sentence you hear in every Kubernetes networking talk — and now you know it's literally `ip link set veth1 netns mypodns`, a namespace membership change on one interface.

> Check yourself before Rung 6: In step 4, `veth1` vanishes from the host the moment it's moved. Using the One Idea, explain why the *host* can no longer see it but its *partner* `veth0` still works as a cable — what's namespaced (the interface) and what isn't (the wire between the pair)?

---

## Rung 6 — ⚖️ The Contrast

**The older/alternative approach: full virtual machines (and, further back, `chroot`).**

A VM isolates by running a **whole second kernel** on virtual hardware. A namespace isolates by giving a process a **private view within the one shared kernel**. That difference drives everything:

| | **Namespaces (containers)** | **Virtual machines** | **`chroot`** |
|---|---|---|---|
| Kernels running | 1 (shared) | 1 per VM | 1 (shared) |
| Isolation boundary | Kernel data structures (per-resource) | Virtual hardware / hypervisor | Filesystem root only |
| Startup time | Milliseconds | Tens of seconds (boots an OS) | Instant |
| Overhead per instance | ~a process | Full OS + RAM reservation | ~a process |
| Density on a node | Hundreds–thousands | Tens | N/A |
| Isolation strength | **Weaker** — shared kernel; a kernel exploit escapes | **Stronger** — separate kernel + hypervisor | **Very weak** — root escapes trivially |
| Composable per resource | **Yes** — share net, isolate mnt, etc. | No — all-or-nothing | No |
| Run a different kernel/OS | No (shares host kernel) | **Yes** (Windows VM on Linux host) | No |

**What namespaces can do that VMs cannot:** start in milliseconds, pack hundreds per node, and — crucially — **compose** (a pod *shares* some namespaces and *isolates* others; a VM can't half-share its network with another VM). **What VMs can do that namespaces cannot:** provide a genuine security boundary against a hostile kernel exploit, and run a *different* kernel/OS. This is exactly why hostile-multi-tenant platforms reach for **microVMs (Kata Containers, Firecracker, gVisor)** — they wrap a container in a thin VM to get the stronger boundary while keeping container ergonomics.

**When would I NOT need namespaces directly?** Almost never as a K8s engineer *directly* — but you don't reach for them when: you need a hard security boundary against untrusted tenants (use a VM/microVM), or you're running a single trusted workload that owns the whole node (bare process is fine). Also, `time` and even `cgroup` namespaces are ones you may go a whole career without touching by hand.

**Why this over that (one sentence):** Namespaces give you *near-native speed and density with composable, per-resource isolation on a shared kernel* — the exact trade that makes running hundreds of pods per node economically possible, accepting a weaker boundary than a VM.

> Check yourself before Rung 7: A security team says "containers aren't a security boundary." Using the "shared kernel" row of the table, *derive* what they mean and name the one class of exploit that a namespace cannot stop but a VM can.

---

## Rung 7 — 🧪 The Prediction Test

Now the hands-on. For each, **write down your prediction first**, then run, then read the Verify note. A wrong result is more valuable than a right one — it means your model was broken and now you'll fix it.

> Setup assumptions: Ubuntu 22.04+ (systemd, cgroup v2), `util-linux` installed (provides `unshare`, `nsenter`, `lsns` — all present by default), and `iproute2` (`ip`). Some steps need root; use `sudo`. On a K8s node you'll also want `crictl` and `jq`.

### Prediction 1 — Normal case: `unshare` makes a process believe it is PID 1

**Predict:** *If I run `unshare --pid --fork --mount-proc bash`, then inside that shell `ps aux` will show `bash` as PID 1 and only a tiny process list, BECAUSE `--pid` creates a new PID namespace whose first process (forked by `--fork`) becomes PID 1, and `--mount-proc` gives me a fresh `/proc` reflecting that private PID view.*

```bash
# On the host first — note your shell's real PID:
echo $$                       # e.g. 48213

sudo unshare --pid --fork --mount-proc bash
# Now inside the new namespace:
echo $$                       # 1     <-- you are PID 1
ps aux                        # only bash + ps; a 2-line process tree
ls -l /proc/self/ns/pid       # note the inode, e.g. pid:[4026532210]
exit                          # namespace is destroyed on exit
```

**Verify:** You should see `bash` as **PID 1** and a `ps` output with only a couple of processes — not the host's hundreds. If instead `ps` still shows the whole host, you forgot `--mount-proc` (procfs is still the host's). If `echo $$` shows a big number instead of 1, you forgot `--fork` (recall §3.3: `unshare --pid` alone doesn't move the caller — it only affects *children*). That failure *is* the PID-namespace gotcha made visible.

### Prediction 2 — Proving sharing: compare `/proc/PID/ns` inodes and read `lsns`

**Predict:** *If I create a network namespace and compare its `net` inode to the host's, the two numbers will DIFFER, BECAUSE they are two distinct namespace instances; and two processes in the SAME namespace will show the SAME inode. `lsns` will list both.*

```bash
# Host's own net namespace inode:
readlink /proc/self/ns/net            # net:[4026531840]  (host/root netns)

# Create a named netns and read ITS net inode:
sudo ip netns add mypodns
sudo ip netns exec mypodns readlink /proc/self/ns/net   # net:[4026532...] DIFFERENT

# List every namespace on the host, grouped, with member PIDs:
lsns                                  # columns: NS TYPE NPROCS PID USER COMMAND
lsns -t net                           # just the network namespaces

# Now prove a fresh netns is empty (isolation, not sharing):
sudo ip netns exec mypodns ip addr    # only 'lo', and it's DOWN — no eth0, no host IPs

sudo ip netns del mypodns             # cleanup
```

**Verify:** The two `net:[...]` inode numbers must be **different integers** — that's the mechanical proof they're separate namespaces (§3.2). `ip addr` inside `mypodns` shows **only `lo`** and *none* of the host's interfaces or IPs — visible proof that a network namespace privatizes the entire network stack. If you saw the host's `eth0` inside `mypodns`, isolation failed and your model is wrong. `lsns` should list your new netns as a row with `NPROCS` reflecting its members.

### Prediction 3 — Edge/failure case: a namespace with no reference disappears; a named one persists

**Predict:** *If I `unshare --net` a shell and exit it, that netns is destroyed (no references left); but if I `ip netns add`, the netns survives with zero running processes, BECAUSE `ip netns` bind-mounts the ns file under `/var/run/netns/`, which is a persistent reference that keeps it alive (§3.2, Rung 4 check).*

```bash
# Transient: created and destroyed with the shell —
sudo unshare --net bash -c 'ip link add dummy0 type dummy; ip link show; echo "inside now"'
# ...shell exits; that netns and dummy0 are GONE. Prove nothing persisted:
ip link show | grep dummy0 || echo "no dummy0 on host — netns was destroyed"

# Persistent: the named netns survives with no process in it —
sudo ip netns add persist-demo
ls -l /var/run/netns/                 # persist-demo appears here (the bind-mount reference)
ip netns list                         # persist-demo listed even with 0 processes in it
# (note: `lsns` scans /proc, so it WON'T show this one — it has no member process)
sudo ip netns del persist-demo        # removes the bind-mount → namespace destroyed
```

**Verify:** After the `unshare --net bash -c '...'` exits, there is **no `dummy0`** anywhere on the host — the whole netns evaporated because its only reference (the shell) died. The named `persist-demo` shows up under `/var/run/netns/` and outlives any process. If you expected `dummy0` to linger on the host, you've just learned that namespace lifetime is reference-counted, not command-scoped — the exact reason Kubernetes needs a **pause container** to hold a pod's namespaces open across app restarts.

### Prediction 4 — Kubernetes case: `nsenter` into a running container = what `kubectl exec` does

**Predict:** *If I find a running container's PID via `crictl` and `nsenter` into its net namespace, then `ss -tlnp` will show the CONTAINER's listening ports (not the node's), BECAUSE `nsenter` (`setns`) joins me to that process's namespaces so I see exactly what it sees — this is mechanically identical to `kubectl exec`. And I can do this even for a distroless container that has no shell of its own, because the tools come from MY namespace, not the container's.*

```bash
# On a Kubernetes node (containerd runtime). Find the container's host PID:
sudo crictl ps                                        # list containers, grab an ID
CPID=$(sudo crictl inspect <containerID> | jq .info.pid)   # the container's host PID
echo "$CPID"                                          # e.g. 48213 (real PID on the node)

# Enter ALL of its namespaces and get a shell (this is kubectl exec, essentially):
sudo nsenter -t "$CPID" -a bash

# Or surgically — enter ONLY the net namespace to see the app's listening sockets:
sudo nsenter -t "$CPID" --net -- ss -tlnp             # shows the CONTAINER's :8080, etc.

# Debug a DISTROLESS container (no /bin/sh, no ls inside) from the node.
# KEY: do NOT enter its --mount namespace, or you lose the node's tools too
# (once you setns into the container's rootfs, only the image's binaries exist).
#   Inspect the container's ROOTFS with the NODE's ls via the /proc magic symlink:
sudo ls /proc/"$CPID"/root/app                        # node's ls, container's filesystem
#   Run the node's tcpdump/ip/curl against the pod's stack — enter net ns ONLY:
sudo nsenter -t "$CPID" --net -- ip addr              # the pod's IP, using the NODE's ip
```

**Verify:** `ss -tlnp` under `nsenter --net` should show the **container's** listening ports (e.g. your app on `:8080`) and *not* the node's kubelet/sshd ports — proof you joined the container's netns, not the host's. The distroless inspection works **even though the container has no `ls`** — that's the killer insight, but note *why*: you keep the **node's mount namespace**, so `ls /proc/$CPID/root/app` runs the *node's* `ls` while `/proc/PID/root` points into the container's rootfs, and `nsenter --net -- ip addr` runs the *node's* `ip` inside only the container's *net* namespace. The rule: **enter only the namespaces you're inspecting (net/pid); keep the node's mount namespace so the node's tools stay available.** If you had added `--mount`, you'd be in the container's filesystem and the node's `ls`/`ip` would vanish (ENOENT on distroless). If `ss` showed the node's ports instead, you didn't actually enter the namespace (check the PID from `jq .info.pid`). This is exactly why `nsenter` beats `kubectl exec` for distroless: `kubectl exec` needs a shell *in the image*; the node-side approach needs nothing from the image at all.

---

## Rung 8 — 🏔 Capstone: Compress It

**One-sentence summary (no notes):**
A namespace gives a process a private instance of one kind of global kernel resource, and a container is just a process holding a chosen set of the eight namespace kinds (plus a cgroup).

**The 3-sentence beginner explanation:**
Normally every program on a Linux box shares one process list, one network, one filesystem, one hostname. Namespaces let the kernel hand a program a *private copy* of any of those — its own process list where it's PID 1, its own IP, its own `/` — so it can't see or collide with the rest of the machine. A container is a program running inside a bundle of these private copies; a Kubernetes pod is a group of containers that deliberately *share* the network/hostname/IPC copies (so they talk over `localhost`) while keeping *separate* filesystem and process copies.

**Sub-capabilities mapped back to the One Idea** (*"a private instance of one global kernel resource"*):

| Sub-capability | It's just "private instance of…" |
|---|---|
| Container has its own process tree, PID 1 | …the PID number space (pid ns) |
| Pod has its own IP, ports, routes | …the network stack (net ns) |
| Container sees its image's `/`, not the node's | …the mount table (mnt ns) |
| Pod has its own hostname | …the hostname (uts ns) |
| Containers in a pod share System V IPC | …the IPC objects (ipc ns) — shared, not private, on purpose |
| Rootless container: root inside ≠ root outside | …the UID/GID map (user ns) |
| Container sees itself at cgroup root | …the cgroup tree view (cgroup ns) |
| Container can have a different uptime | …the monotonic/boot clock offset (time ns) |
| `kubectl exec` / debugging distroless | join an existing set via `setns`/`nsenter` |
| CNI gives a pod its network | move a veth end into the pod's net ns |
| Pod keeps its IP across restarts | the pause container holds the ns references open |

**Which rung to revisit hands-on (be honest):**
- If you can't yet *predict* what `unshare --pid --fork --mount-proc` does before running it → **Rung 3.3 + Prediction 1**.
- If "compare the inode numbers" doesn't feel like a *proof* to you → **Rung 3.2 + Prediction 2** until it's reflex.
- If the CNI veth trace is still hand-wavy → **Rung 5**, and actually build the veth pair by hand (Prediction 2/3 give you the pieces).
- If `nsenter` vs `kubectl exec` still feels like two different things → **Prediction 4** on a real node; they're the same syscall.

---

## Related concepts

- [14-cgroups.md](14-cgroups.md) — the *other* half of a container: what a process may USE (CPU/memory), while namespaces are what it can SEE.
- [11-networking.md](11-networking.md) — `ip`, `ss`, routing, interfaces — the tools you run *inside* a network namespace.
- [12-iptables-netfilter.md](12-iptables-netfilter.md) — netfilter rules are per-network-namespace; how `kube-proxy` programs the pod/service data path.
- [17-capabilities.md](17-capabilities.md) — the fine-grained root powers that pair with user namespaces to make rootless containers safe(r).
- [01-linux-philosophy.md](01-linux-philosophy.md) — "everything is a file," which is exactly why `/proc/PID/ns/*` lets you inspect and compare namespaces.
- [27-linux-kubernetes-map.md](27-linux-kubernetes-map.md) — the full Linux↔Kubernetes mapping and node-triage quick reference.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** `chroot` isolated the filesystem and nothing else — derive how many more "chroot-like" features the kernel would need before a process is fully fooled, and what each must privatize.

**A:** Seven more, one per remaining kind of global kernel state, for eight in total. Beyond the filesystem view (which became the **mnt** namespace, generalizing chroot to the whole mount table), the kernel must privatize: the **process-ID space** (pid — so the process can be PID 1 and can't see or signal outsiders), the **network stack** (net — own interfaces, routes, port space so it can bind its own `:80`), the **hostname/domainname** (uts), the **System V/POSIX IPC objects** (ipc), the **UID/GID number space** (user — root inside ≠ root outside), the **cgroup tree root** it sees (cgroup), and the **monotonic/boot clock offsets** (time). Only with all of these privatized can a process be fooled into thinking it's alone on the machine — chroot solved 1/8th of the problem.

### Before Rung 3
**Q:** Using only the One Idea, why are "containers in a pod share `localhost`" and "each container has its own `/`" not contradictory?

**A:** Because the One Idea says a namespace privatizes **one kind** of global kernel resource — isolation is per-resource-kind and composable, not all-or-nothing. A process holds a *set* of memberships, one per kind, so a pod can be a hand-picked recipe: all its containers *join the same* **net** (and ipc/uts) namespace — hence one IP and one shared `localhost` — while each container gets its *own fresh* **mnt** namespace, hence its own private `/` from its image. The clause "one kind of global kernel resource" is what makes both true at once: net and mnt are independent lies told separately.

### Before Rung 4
**Q:** An app container crashes and restarts 50 times but the pod's IP never changes. Explain mechanically why — which process holds which namespace, and what happens to the IP if that process dies?

**A:** The pod's IP lives on `eth0` inside the pod's **network namespace**, and that namespace is created and held open by the **pause (sandbox) container** — a tiny process that just sleeps forever as a member of the pod's net/ipc/uts namespaces. Per §3.2, a namespace survives as long as *something* references it (a member process, a bind-mount, or an open fd); the app containers merely `setns`-join the pause container's netns, so when they crash and restart they rejoin the same still-alive namespace and find the same `eth0`/IP waiting. If the pause container itself died, the last reference would drop, the kernel would destroy the netns (taking the veth and IP with it), and the sandbox would have to be recreated — the pod would get a fresh namespace and, typically, a new IP.

### Before Rung 5
**Q:** Why does `ip netns add mypodns` persist with no process inside, while `unshare --net bash` vanishes when the shell exits?

**A:** In one sentence: `ip netns add` **bind-mounts the namespace's ns file under `/var/run/netns/mypodns`**, and that bind-mount is a persistent reference (§3.2) that keeps the namespace alive with zero member processes — whereas the namespace made by `unshare --net` is referenced only by the shell process, so when the shell exits the last reference disappears and the kernel destroys it. Namespace lifetime is reference-counted (process, bind-mount, or open fd), not command-scoped.

### Before Rung 6
**Q:** In step 4 of the trace, `veth1` vanishes from the host the moment it's moved. Why can the host no longer see it, yet its partner `veth0` still works as a cable?

**A:** Network **interfaces are namespaced objects** — an interface belongs to exactly one network namespace at a time, so `ip link set veth1 netns mypodns` changes `veth1`'s membership and the host's netns lookup table simply no longer contains it; per the One Idea, the host now gets a filtered answer that excludes it. But the **pairing between the two veth ends is kernel-internal plumbing, not a namespaced resource** — the "cable" linking them exists in the kernel regardless of which namespaces the two ends sit in. So `veth0` (still in the host netns, bridged to `cni0`) keeps working: a packet pushed into one end still emerges from the other, even though the ends are now visible in different worlds. That cross-namespace cable is exactly how a pod's traffic reaches the node.

### Before Rung 7
**Q:** A security team says "containers aren't a security boundary." Using the shared-kernel row of the table, derive what they mean and name the one class of exploit a namespace cannot stop but a VM can.

**A:** All containers on a node share **one kernel** — namespaces are just private lookup tables inside that single kernel's data structures, not virtual hardware. So any workload that can exploit a bug in the shared kernel is exploiting code that sits *underneath* every namespace on the machine; the "wall" is made of the very thing being attacked. The class a namespace cannot stop is the **kernel exploit** (privilege-escalation via a kernel vulnerability): a compromised container that pops the kernel escapes into every other container and the host. A VM can stop it because each VM runs its **own separate kernel** behind a hypervisor boundary — a guest-kernel compromise stays inside the guest — which is why hostile-multi-tenant platforms wrap containers in microVMs (Kata, Firecracker, gVisor).
