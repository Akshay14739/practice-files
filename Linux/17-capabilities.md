# Linux Capabilities, Climbed the Ladder 🪜

*How the kernel chopped the god-powers of root into ~40 tiny switches — and why your hardened pod runs as UID 0 but still can't do anything dangerous.*

> This is Linux capabilities rebuilt on the Learning Ladder. We do **not** lead with `setcap`. We climb from **why root had to be split** → **the one core idea** → **the five capability sets and the bitmask machinery** → and only at the top, the commands. Each rung ends with a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every `getcap`/`setcap`/`capsh` command lives at the TOP of the ladder (Rung 7). You'll understand *what bit the kernel flips* before you run it — and why `drop: [ALL]` + `add: [NET_BIND_SERVICE]` is the single most important line in a CKS exam.

---

## 🪜 Rung 0 — The Setup

**What am I learning?**
The Linux **capability** system — the mechanism that breaks the single, all-powerful "are you root?" check into ~40 independent privileges (bind a low port, load a kernel module, change any file's owner, trace another process...), each of which can be granted or revoked on its own. Plus the tools that read and write them: `capsh`, `getcap`, `setcap`, and the `Cap*` lines in `/proc/PID/status`.

**Why did it land on my desk?**
A very Kubernetes-flavoured incident. A security scanner flagged a Deployment as "runs as root." The dev team pushed back: *"But it only listens on port 80 — it has to be root for that, right?"* You set `runAsNonRoot: true` and the pod crash-loops with `permission denied` on `bind(:80)`. Meanwhile a different team's pod runs `privileged: true` "because it needs to mount a volume," and your CKS-minded brain twitches, because `privileged: true` hands the container **every capability on the host kernel**. Three questions, one root cause: **you've been treating "root" as a single yes/no bit, when the kernel stopped doing that in 1999.** Today you learn the real model so the fixes become obvious: `drop: [ALL]`, then `add: [NET_BIND_SERVICE]`, and the pod binds port 80 as UID 1000.

**What do I already know (assumed)?**
- From [permissions & ownership](05-permissions-ownership.md): the `rwx`/UID/GID model, and the **SUID bit** — a binary that runs as its *owner* (usually root) regardless of who launched it. `passwd` and `ping` are the classic examples.
- From [users, groups, sudo](06-users-groups-sudo.md): UID 0 is root, and historically UID 0 bypasses almost every kernel permission check.
- From [processes](07-processes-job-control.md): every process has an entry in `/proc/PID/`, and `/proc/PID/status` is a text dump of its kernel state.
- From [namespaces](13-namespaces.md) and [cgroups](14-cgroups.md): a container is just a process on the node with its own namespaces and cgroup — kubelet asks containerd, which asks `runc`, to launch it.

You do **not** need to know any `cap_*` names yet. That's the point.

---

## 🔥 Rung 1 — The Pain

Sit with the problem before touching `setcap`.

For its first ~30 years, Unix had exactly **two** privilege levels: **UID 0 (root), who could do everything**, and **everyone else, who could do almost nothing sensitive**. The kernel was littered with checks that read, in effect, `if (uid == 0) allow;`. Binding to a port below 1024? Root only. Loading a kernel module? Root only. Changing a file's owner? Root only. Rebooting, mounting, setting the clock, sending raw packets, tracing another process? Root, root, root, root, root.

This is **all-or-nothing privilege**, and it hurts in two directions at once:

- **Too much power granted.** A web server needs *one* god-power: bind port 80. To get it, you ran the **whole server as root**. Now a buffer-overflow in your request parser doesn't just leak memory — it's arbitrary code execution *as UID 0*, which can rewrite `/etc/passwd`, load a rootkit, and mount your disks. You wanted "bind a low port"; you were forced to grant "own the entire machine."
- **SUID: the ugly workaround.** To let a *normal* user run one privileged operation (like `passwd` writing to root-owned `/etc/shadow`, or `ping` opening a raw socket), Unix used the **SUID bit**: mark the binary so it runs as its owner (root). But SUID is all-or-nothing *too* — during that execution the process is **fully root**. Every SUID binary is a potential privilege-escalation bomb: find one bug in `ping`, and you've found a path to root. The history of Linux local-root exploits is largely a history of SUID binaries doing slightly more than they needed to.

```
THE ALL-OR-NOTHING WORLD (why "run as root" is a loaded gun)

   web server needs:  bind(:80)              ← ONE tiny power
   to get it, runs as: ★ UID 0 = ALL POWER ★

   bug in parser ──▶ code exec as root ──▶ rewrite /etc/passwd,
                                            load kernel module,
                                            mount disks, read every key.

   SUID ping needs:   raw socket
   to get it, becomes: ★ UID 0 for the whole run ★
   bug in ping ──▶ instant local root.
```

**What breaks without a finer model, in your world?** Containers become indefensible. A container is just a process on the node. If "privileged operation" means "full root on the host kernel," then any container that needs *one* small power (say, `chown` on a mounted volume, or binding `:443`) would need real host root — and a container escape becomes a node takeover. Kubernetes' entire `securityContext.capabilities` field, the `runAsNonRoot` guarantee, and the whole CKS "least privilege" doctrine are **impossible** without the kernel first splitting root into pieces you can drop individually.

**Who feels the pain most?** The platform engineer defending a multi-tenant node. Dozens of pods from teams you've never met share one kernel. "Run as root or don't run" is not a security posture — it's a surrender.

> **Check yourself before Rung 2:** A web server needs exactly one privileged operation: `bind()` to port 80. In the all-or-nothing model, what is the *smallest* privilege you are forced to grant it, and what is the blast radius if that server has a remote code-execution bug?

---

## 💡 Rung 2 — The One Idea

> **A capability is one slice of root's power, tracked as a single bit; the kernel checks the specific capability bit for a task instead of asking "is this UID 0?", so you can grant exactly the powers a process needs and drop all the rest.**

Memorize that sentence. Everything else is derivation.

Derive the rest from it:
- *"One slice of root's power"* → root got carved into ~40 named capabilities: `CAP_NET_BIND_SERVICE` (low ports), `CAP_SYS_MODULE` (load modules), `CAP_CHOWN` (change owners), `CAP_NET_RAW` (raw sockets), `CAP_SYS_ADMIN` (a giant grab-bag), and so on. Each is a discrete power.
- *"Tracked as a single bit"* → a set of capabilities is a **bitmask**. Cap number *N* is bit *N*. That's why `/proc/PID/status` shows caps as a hex number, and why decoding it is just "which bits are set."
- *"The kernel checks the specific bit"* → the old `if (uid==0)` checks became `if (capable(CAP_X))`. Same code path, finer question.
- *"Grant exactly what's needed, drop the rest"* → **least privilege**. A server keeps only `CAP_NET_BIND_SERVICE`; a container drops `ALL` and adds back the one or two it truly needs.
- *"Instead of asking is this UID 0"* → the punchline for Kubernetes: **you can be UID 0 with zero capabilities** (harmless), or **UID 1000 with `CAP_NET_BIND_SERVICE`** (can bind :80, nothing else). Identity (UID) and privilege (caps) are now **decoupled**.

If you internalize "root = a pile of bits; the kernel checks one bit at a time," you can read any pod's `securityContext` and any `/proc/PID/status` Cap line.

> **Check yourself before Rung 3:** In one sentence, what does the kernel's `capable()` function actually inspect, and how is that different from the old `if (uid == 0)` test? What does it mean, in privilege terms, to be "UID 0 with zero capabilities"?

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture a big office building where, for decades, there was only one kind of key: the master key. Either you had the key that opened *everything* — every office, the vault, the electrical room — or you had nothing special at all. This section explains how the building switched to a **keyring of about forty separate little keys**, one per door.
>
> - **The new question at every door (3.1).** The security guards used to ask "are you the boss?" (in computer terms: "is this the all-powerful root account?"). Now every door has its own guard who asks a narrower question: "do you carry the *specific* key for *this* door?" The boss still normally carries all the keys, so nothing feels different for them — but the keys are what matter now, not the job title. Take the keys away from the boss and the boss gets turned away at doors too.
> - **Everyone carries five keyrings (3.2).** Each worker (each running program) actually holds five lists of keys, used at different moments: the keys **in their hand right now** (the only ones guards accept); the keys **in their pocket** they're allowed to take out; a small **hand-me-down** list of keys that can pass to a program they launch (an older, fiddly system); a **hard outer limit** — keys that were confiscated from this worker can never be gotten back by them *or anyone they hire*, ever; and a **modern hand-me-down** list that makes passing keys to launched programs actually work for ordinary, non-boss workers.
> - **The keys are a punch card (3.3).** Under the hood, each keyring is just a row of forty-ish on/off holes, written as a compact code number. More holes punched = more power; all punched = full boss power; none punched = a "boss" in name only. A little translator tool turns the code back into readable key names.
> - **Special tools with a key taped on (3.4).** The old trick for letting ordinary staff do one privileged task was: "while using this tool, you temporarily *become the boss*" — dangerous, because a flaw in the tool made you fully boss. The modern trick: tape **one specific key** to the tool itself. Use the tool, get that single key, nothing more.
> - **How container platforms use this (3.5).** When Kubernetes (the software that runs apps in sealed boxes) starts an app, it can say "confiscate ALL keys, then hand back just this one" — so even a break-in only steals one key. The setting called "privileged" does the opposite: it hands the box the entire master keyring, which is why security reviewers hunt for it first.

*Now the original technical deep-dive — the same ideas, in precise form:*

### 3.1 The kernel check that changed everything

Deep in the kernel, the old code looked morally like this:

```c
if (current->uid == 0) allow();   /* the ONE bit era */
```

Since Linux 2.2 (1999) it looks like this:

```c
if (capable(CAP_NET_BIND_SERVICE)) allow();   /* the capability era */
```

`capable()` doesn't look at UID. It looks at whether **the relevant capability bit is set in this task's *effective* set**. UID 0 still *usually* starts life with all bits set (for backward compatibility), which is why "root works." But the bits are the truth now, not the UID. Strip the bits from a root process and it can't do the privileged thing — even though `id` still says `uid=0`.

### 3.2 Each process carries FIVE capability sets

A capability isn't a single number per process. Every task holds **five** 64-bit masks. You must know what each one is *for*, because Kubernetes and file capabilities manipulate different ones.

| Set | Kernel name | One-line job |
|---|---|---|
| **Effective** | `CapEff` | The set the kernel *actually checks right now*. `capable(X)` reads this. If the bit isn't here, you can't do X **this instant**. |
| **Permitted** | `CapPrm` | The **ceiling** of what this process may move into Effective. A process can raise a permitted cap into effective, but can never gain a cap that isn't permitted. |
| **Inheritable** | `CapInh` | Caps that *survive an `execve()`* into the new program's permitted set — but only if the executed file also marks them inheritable. Fiddly, legacy, rarely used directly. |
| **Bounding** | `CapBnd` | A **hard cap ceiling** for the process *and all its descendants*. A bit not in the bounding set can **never** be acquired, even by exec of a file-cap binary. **This is the one containers shrink.** |
| **Ambient** | `CapAmb` | The modern fix that lets a **non-root** process pass caps across `execve()` without file capabilities. A cap here appears in the child's Permitted+Effective. Subset of Permitted ∩ Inheritable. |

Mental model of the ceilings, from loosest to strictest:

```
   Bounding  ⊇  Permitted  ⊇  Effective
   (hard wall) (may-have)    (have-right-now)

   You can only ADD to Effective what's in Permitted.
   You can only have in Permitted what's inside Bounding.
   Drop a bit from Bounding → it's gone for you and every child, forever.
```

### 3.3 The bitmask — reading the hex

A capability set is a 64-bit integer. Capability *N* lives at bit *N*. So:

```
 cap number:  CAP_CHOWN=0  CAP_DAC_OVERRIDE=1  CAP_NET_BIND_SERVICE=10  CAP_NET_RAW=13  CAP_SYS_ADMIN=21
 bit:         2^0          2^1                 2^10                     2^13            2^21
```

`/proc/PID/status` prints each set as 16 hex digits:

```
CapInh: 0000000000000000     ← nothing inheritable
CapPrm: 00000000a80425fb     ← permitted ceiling
CapEff: 00000000a80425fb     ← effective (== permitted here)
CapBnd: 00000000a80425fb     ← bounding hard-wall
CapAmb: 0000000000000000     ← nothing ambient
```

That `00000000a80425fb` is not random — it's the **default set Docker/containerd hand a container** (14 caps). You never decode hex by hand; you feed it to `capsh --decode=` (Rung 7). But know the shape: **more bits = more power; `000001ffffffffff` ≈ full root (all ~41 caps set), `0000000000000000` = a process that is UID 0 in name only.**

### 3.4 File capabilities — the modern replacement for SUID

Here's how a *non-root* user runs `ping` without SUID-root. Instead of "run as owner," the binary carries **file capabilities** stored in an extended attribute named `security.capability` on the file's inode (see [file operations](04-file-operations.md) for xattrs). At `execve()`, the kernel reads that xattr and folds it into the new process's sets.

```
   OLD WAY (SUID):                 NEW WAY (file capabilities):
   ┌──────────────────┐            ┌──────────────────────────────┐
   │ -rwsr-xr-x root   │           │ -rwxr-xr-x root               │
   │ ping              │           │ ping   xattr: cap_net_raw=ep  │
   │ SUID bit set      │           │ NO SUID bit                   │
   └────────┬─────────┘            └──────────────┬───────────────┘
            │ exec                                │ exec
            ▼                                     ▼
   process becomes FULL ROOT           process gets ONLY cap_net_raw
   (all ~40 powers)                    in Permitted+Effective.
   bug = total root                    bug = can open raw sockets. That's it.
```

The `=ep` / `+ep` suffix names *which sets* the file grants: **e** = effective (auto-activate on exec), **p** = permitted, **i** = inheritable. `cap_net_raw=ep` means "put `CAP_NET_RAW` in the new process's permitted set and turn it on in effective." That's the whole magic that lets an unprivileged `ping` open a raw ICMP socket while being able to do *nothing else* root can do.

### 3.5 Where Kubernetes plugs in

A container is a process. kubelet → containerd → `runc` builds it. When your pod spec says:

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]
```

`runc` sets the container process's **bounding set** (and permitted/effective/ambient) to *exactly* `CAP_NET_BIND_SERVICE` and nothing else. Because bounding is a hard wall for all descendants, no child process inside that container can ever regain `CAP_SYS_ADMIN`, even by execing a file-cap binary. Conversely, `privileged: true` tells runc to leave the **full capability set** in place (all ~41 bits) *and* disables the device cgroup, seccomp, and AppArmor confinement — the container is essentially root on the host kernel. That is why, on a CKS review, `privileged: true` is the first thing you hunt for and delete.

> **Check yourself before Rung 4:** Name the five capability sets and, in a few words each, say *when* the kernel consults each one. Which single set does `drop:[ALL]` shrink, and why does shrinking it also protect every child process inside the container?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Capability** | One named slice of root's power (e.g. `CAP_NET_RAW`), identified by an integer 0–40 | The bit the kernel's `capable()` checks |
| **CAP_NET_BIND_SERVICE** (10) | Power to bind sockets to ports < 1024 | The single cap most web pods need |
| **CAP_SYS_ADMIN** (21) | Giant grab-bag: mount, pivot_root, many `*_admin` ops — "the new root" | The dangerous one to add in a container |
| **CAP_NET_RAW** (13) | Open raw/packet sockets (ping, tcpdump, crafting packets) | The file cap on `/usr/bin/ping` |
| **CAP_CHOWN** (0) | Change the owner (UID) of any file | Init containers that fix volume ownership |
| **CAP_SETUID / CAP_SETGID** (7 / 6) | Change process UID/GID arbitrarily | How `su`, and dropping-privilege servers, switch users |
| **CAP_SYS_PTRACE** (19) | Trace/inspect other processes' memory (`strace`, debuggers) | Debug sidecars; a container-escape risk |
| **Effective set (`CapEff`)** | Bits the kernel checks *right now* | `capable()` reads this |
| **Permitted set (`CapPrm`)** | Ceiling of what can be moved into Effective | Bound on Effective |
| **Inheritable set (`CapInh`)** | Caps that can pass across `execve` via file caps | Legacy cross-exec path |
| **Bounding set (`CapBnd`)** | Hard wall of caps for a process and all children | What `drop:[ALL]` shrinks |
| **Ambient set (`CapAmb`)** | Modern way to carry caps across exec without file caps or root | Non-root cap inheritance |
| **File capability** | An xattr (`security.capability`) on a binary granting caps at exec | The SUID replacement |
| **`+ep` / `=ep`** | Which sets a file cap loads: e=effective, p=permitted, i=inheritable | `setcap` syntax |
| **SUID bit** | Older mechanism: run a binary as its owner (all-or-nothing) | The thing file caps replace |
| **`capsh`** | User-space tool to print/decode capability sets and drop caps | Reads/formats the bitmasks |
| **`getcap` / `setcap`** | Read / write file capabilities on a binary | Manipulate the `security.capability` xattr |
| **privileged: true** | Pod setting granting the full cap set + disabling seccomp/AppArmor/device cgroup | Leaves bounding set fully open |

**"Same kind of thing wearing different names":**
- **Effective / Permitted / Inheritable / Bounding / Ambient** are all just **64-bit masks of the same 41 caps** — they differ only in *when* the kernel consults them (now vs. ceiling vs. across-exec vs. hard-wall).
- **File capability + SUID bit** are two answers to the *same question*: "how does an unprivileged user run one privileged operation?" — SUID grants everything; file caps grant a slice.
- **`CapPrm` in `/proc` and "Permitted set" and `p` in `+ep`** are three names for one mask.
- **`privileged: true`, "all caps", and `CapBnd = 000001ffffffffff`** describe the same runtime state from three altitudes (pod spec, English, hex).

> **Check yourself before Rung 5:** `CapPrm` in `/proc/PID/status`, "the permitted set," and the `p` in `cap_net_raw=ep` are three names for what one thing? And in your own words, why is `privileged: true` equivalent to leaving `CapBnd = 000001ffffffffff`?

---

## 🔬 Rung 5 — The Trace

Follow one concrete action end-to-end: **your hardened pod (`runAsUser: 1000`, `drop:[ALL]`, `add:[NET_BIND_SERVICE]`) starts nginx, which binds port 80.**

1. **kubelet** reads the Pod spec, sees `securityContext.capabilities`, and passes it to the CRI as part of the container config.
2. **containerd** translates it into an **OCI runtime spec** (`config.json`): a `process.capabilities` block listing `bounding/permitted/effective/inheritable/ambient` = `["CAP_NET_BIND_SERVICE"]` only. (Kubernetes names caps *without* the `CAP_` prefix; the runtime adds it.)
3. **runc** forks the container's init process. Before executing nginx, it walks the bounding set and calls `prctl(PR_CAPBSET_DROP, N)` for **every capability except bit 10**, then sets the permitted/effective/ambient masks to just bit 10. The hard wall is now up.
4. Container init `execve()`s nginx. The kernel recomputes capability sets across the exec; because ambient has `CAP_NET_BIND_SERVICE`, nginx's **effective** set ends up with exactly bit 10 — running as **UID 1000**.
5. nginx calls `bind(fd, 0.0.0.0:80)`. The kernel reaches the privileged-port check and calls `capable(CAP_NET_BIND_SERVICE)`. It reads nginx's **effective** set, finds bit 10 set → **allow**. Port 80 binds successfully as a non-root user.
6. Now nginx (or an attacker who owns it) tries something nasty: `mount()`. Kernel calls `capable(CAP_SYS_ADMIN)` → reads effective → bit 21 **not set** → `-EPERM`. Even a `setuid(0)` wouldn't help: the **bounding set** has no bit 21, so it can never be regained. Blast radius: bind low ports. Nothing else.
7. **You, on the node**, verify: find the container's host PID via `crictl inspect`, read `/proc/PID/status`, and decode `CapEff` — you should see exactly `cap_net_bind_service`.

```
 Pod spec            OCI config.json         runc                    kernel @ bind(:80)
 drop:[ALL]     ┌──▶ capabilities:      ┌──▶ prctl DROP all      ┌──▶ capable(NET_BIND_SERVICE)?
 add:[NBS]      │    bounding:[NBS]     │    but bit 10          │    read CapEff → bit10 SET
 (kubelet) ─────┘    (containerd) ──────┘    setcap sets         │    ✓ ALLOW → port 80 up
                                             (runc)              │
                                                       mount() ──┘  capable(SYS_ADMIN)? bit21 CLEAR
                                                                    ✗ EPERM (and CapBnd blocks forever)
```

The whole security guarantee is one sentence: **the kernel checked a specific bit, and that bit wasn't set.**

> **Check yourself before Rung 6:** When the hardened pod's nginx tries `mount()` and gets `EPERM`, name the exact capability bit the kernel checked and the two sets that guarantee it can never be raised. Why wouldn't a `setuid(0)` call inside the container rescue it?

---

## ⚖️ Rung 6 — The Contrast

The thing capabilities replaced is the **SUID/SGID bit** — "run this binary as its owner."

| | **SUID bit** (old) | **File capabilities** (modern) |
|---|---|---|
| Granularity | All-or-nothing — process becomes fully root | One slice — only the named caps |
| Blast radius of a bug | Total root compromise | Just the granted capability |
| Where stored | Mode bit (`-rwsr-xr-x`) in the inode | `security.capability` xattr on the inode |
| Set with | `chmod u+s` | `setcap cap_x+ep` |
| Audit | `find / -perm -4000` | `getcap -r /` |
| Identity vs privilege | Coupled (you *become* the owner) | Decoupled (stay yourself, gain one power) |
| Container fit | Terrible — a SUID root binary in an image is an escape aid | Native — pods add/drop individual caps |

**What each can do that the other cannot:** SUID can switch the process to *any* aspect of the owner's identity (useful when a program genuinely needs to *be* another user, like `sudo`). File caps cannot change your UID — they only grant kernel powers. Conversely, file caps can hand out `CAP_NET_RAW` **without ever making you root**, which SUID structurally cannot.

**When would I NOT need capabilities?** If a process needs no privileged kernel operation at all — most application containers. Then the correct answer isn't "pick a capability," it's `drop: ["ALL"]` and add nothing. Capabilities matter precisely when a process needs *some* small kernel power.

**Why this over that:** *Grant the one power, not the whole identity — so a bug in the binary costs you a slice, not the machine.*

> **Check yourself before Rung 7:** Your image contains a SUID-root helper. You also set the container's bounding set to `drop:[ALL]`. When that helper runs, does it become root's full power? Explain using the bounding set, not intuition.

---

## 🧪 Rung 7 — The Prediction Test

Now, and only now, the commands. Before each, commit to the prediction out loud. A surprise here is worth ten pages of reading.

### Example 1 — Normal case: decode your own shell's capabilities, then decode the Docker default mask

**Prediction:** *If I run `capsh --print` as a normal user, then my Current effective set will be empty (I'm unprivileged); BECAUSE a non-root login shell carries no capability bits — the kernel would deny any privileged syscall.* And *if I decode `00000000a80425fb`, I'll get exactly 14 caps — the container default — BECAUSE that hex is the bitmask containerd hands unprivileged containers.*

```bash
# install the tools if missing (Debian/Ubuntu). RHEL/CentOS/Fedora: dnf install libcap
sudo apt-get install -y libcap2-bin

capsh --print
# Current: =                          ← empty effective set for a normal user
# Bounding set =cap_chown,cap_dac_override,...  (host bounding is usually full)
# Ambient set =
# ...

# Decode the famous container-default mask WITHOUT running a container:
capsh --decode=00000000a80425fb
# 0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
# cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,
# cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
```

**Verify:** `capsh --print`'s `Current:` line is empty (or `=`) for your normal shell — that's the correct "I have no caps" state. The decode prints **14** capability names. If you instead saw `cap_sys_admin` in that decoded list, you'd have learned the mask wasn't the container default (SYS_ADMIN is deliberately *not* in it). Run the same `capsh --print` under `sudo` and watch the Current set fill up — that visualizes UID 0 carrying the bits.

### Example 2 — File capabilities: inspect `ping`/`tcpdump`, then grant and revoke a cap yourself

**Prediction:** *If I `getcap /usr/bin/ping`, I'll see `cap_net_raw` and NO SUID bit in `ls -l`; BECAUSE modern distros replaced SUID-root ping with a single file capability.* Then *if I `setcap cap_net_bind_service+ep` on a copy of a binary, `getcap` will report it, and `setcap -r` will wipe it clean.*

```bash
getcap /usr/bin/ping
# /usr/bin/ping cap_net_raw=ep         ← one slice of root, not SUID
ls -l /usr/bin/ping
# -rwxr-xr-x 1 root root ...  ← note: NO 's' in the mode. Not SUID.
# (On some minimal images ping instead relies on the net.ipv4.ping_group_range
#  sysctl and has no file cap — getcap prints nothing. That's also valid.)

getcap /usr/sbin/tcpdump
# /usr/sbin/tcpdump cap_net_admin,cap_net_raw=ep   ← if the pkg shipped caps
# (Debian's apt tcpdump often ships WITHOUT caps; then getcap prints nothing
#  and tcpdump must run as root. Both outcomes are real — note which you got.)

# Grant a capability to a binary yourself:
cp /bin/sleep /tmp/myapp
setcap cap_net_bind_service+ep /tmp/myapp
getcap /tmp/myapp
# /tmp/myapp cap_net_bind_service=ep

# Remove it:
setcap -r /tmp/myapp
getcap /tmp/myapp
# (no output — the xattr is gone)
```

**Verify:** `getcap /usr/bin/ping` shows `cap_net_raw` while `ls -l` shows **no `s`** in the permission string — proof that capability replaced SUID. After `setcap ... +ep`, `getcap` echoes your cap back; after `setcap -r`, output is empty. If `setcap` fails with `Operation not supported`, you're on a filesystem without xattr support (some tmpfs/overlay configs) — a real gotcha when baking file caps into container images on OverlayFS. If it fails with `Operation not permitted`, you forgot `sudo` (writing file caps needs `CAP_SETFCAP`).

### Example 3 — Edge/failure case: prove that dropping the bounding cap makes root itself powerless

**Prediction:** *If I run a shell with `CAP_NET_BIND_SERVICE` dropped from the bounding set and try to bind port 80 — even as UID 0 — it will fail with EACCES/EPERM; BECAUSE `capable()` reads the effective set, and a bit removed from bounding can never be raised into effective, regardless of UID.*

```bash
# capsh --drop removes a cap from the bounding set of the shell it spawns.
sudo capsh --drop=cap_net_bind_service --  -c '
  cat /proc/self/status | grep -E "CapBnd|CapEff"
  # CapBnd will be missing bit 10 (cap_net_bind_service)
  python3 -c "import socket; s=socket.socket(); s.bind((\"0.0.0.0\",80)); print(\"bound :80\")"
'
# Traceback ... PermissionError: [Errno 13] Permission denied
# Even though we are UID 0 inside capsh, the bind is DENIED.

# Contrast: same thing WITHOUT dropping the cap succeeds:
sudo python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0",80)); print("bound :80")'
# bound :80
```

**Verify:** The dropped-cap run raises `PermissionError` on `bind(:80)` even as root, and `grep CapBnd /proc/self/status` shows bit 10 absent from the bounding mask. This is the whole lesson made physical: **UID 0 is not privilege; the bits are.** If the bind had *succeeded* despite the drop, you'd have learned your kernel/capsh applied the drop to the wrong set — recheck with `capsh --print` inside the shell. This is exactly the guarantee `drop:[ALL]` gives a pod.

### Example 4 — Kubernetes-flavoured: read a live container's caps from the node

**Prediction:** *If I deploy a pod with `drop:[ALL]` + `add:[NET_BIND_SERVICE]` and decode its `CapEff` from the node's `/proc`, I'll see exactly `cap_net_bind_service`; BECAUSE runc set the container's effective set to just that one bit — the kernel's view on the node is the source of truth.*

```yaml
# hardened.yaml
apiVersion: v1
kind: Pod
metadata: { name: cap-demo }
spec:
  containers:
  - name: web
    image: nginx:stable
    securityContext:
      runAsUser: 1000
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
        add:  ["NET_BIND_SERVICE"]   # note: NO "CAP_" prefix in K8s
```

```bash
kubectl apply -f hardened.yaml
# From INSIDE the pod (quick check):
kubectl exec cap-demo -- grep Cap /proc/1/status
# CapPrm: 0000000000000400   ← bit 10 only
# CapEff: 0000000000000400
# CapBnd: 0000000000000400

# From the NODE (the real CKS move — trust the kernel, not the pod):
CID=$(sudo crictl ps --name web -q)                    # containerd CRI
PID=$(sudo crictl inspect "$CID" | jq '.info.pid')     # host-side PID
cat /proc/$PID/status | grep Cap
# CapEff: 0000000000000400
capsh --decode=$(grep CapEff /proc/$PID/status | awk '{print $2}')
# 0x0000000000000400=cap_net_bind_service
```

**Verify:** Both the in-pod and on-node decode resolve to exactly `cap_net_bind_service` (hex `...0400` = bit 10). Now compare against a **`privileged: true`** pod: its `CapEff` will be `000001ffffffffff` and `capsh --decode` lists **all ~41 caps** including `cap_sys_admin` and `cap_sys_module` — the visual proof that `privileged` = "root on the host kernel," and precisely what a CKS reviewer flags. If your `drop:[ALL]` pod still showed extra caps, you'd know the container runtime ignored the spec — a serious finding worth escalating.

**Audit the whole node for stray file capabilities** (SUID's modern cousin — attackers love a forgotten `cap_setuid+ep` binary):

```bash
# Portable form (works with any libcap):
find / -type f -exec getcap {} \; 2>/dev/null
# /usr/bin/ping cap_net_raw=ep
# /usr/lib/x86_64-linux-gnu/gstreamer-1.0/gst-ptp-helper cap_net_bind_service,cap_net_raw=ep

# Newer libcap has a recursive shortcut (same result, faster):
getcap -r / 2>/dev/null

# And the SUID audit for comparison — capabilities didn't kill SUID entirely:
find / -perm -4000 -type f 2>/dev/null
```

**Verify:** You get a short, explainable list. Any binary you don't recognize carrying `cap_setuid`, `cap_dac_override`, or `cap_sys_admin` is a privilege-escalation lead — investigate it. On a hardened node this list should be tiny.

---

## 🏔 Rung 8 — Capstone: Compress It

**One sentence (no notes):**
Linux capabilities split root's all-or-nothing power into ~40 independently grant-able bits that the kernel checks one at a time, so a process (or pod) can hold exactly the privileges it needs and nothing more.

**Three-sentence beginner explanation:**
Historically "root" was a single switch: you either had every power or almost none, so a web server that just needed to bind port 80 had to run as full root, and any bug in it meant total compromise. Capabilities chop that one switch into many small ones — bind low ports, load modules, change owners, trace processes — each stored as a bit the kernel checks individually, and each grantable to a binary via file capabilities (the modern replacement for the SUID bit). In Kubernetes you use this by writing `capabilities: { drop: ["ALL"], add: ["NET_BIND_SERVICE"] }`, which lets a container bind port 80 while being unable to do anything else root can do — and `privileged: true` is the dangerous opposite that hands back every bit.

**Sub-capabilities mapped to the one core idea** ("root is a pile of bits the kernel checks one at a time"):

| Sub-topic | How it derives from the one idea |
|---|---|
| Five sets (Eff/Prm/Inh/Bnd/Amb) | Five masks of the *same bits*, differing only in *when* the kernel consults them |
| `/proc/PID/status` Cap hex | The bitmasks, printed — decode = "which bits are on" |
| `capsh --decode` | Turns the bitmask number back into cap names |
| File caps (`getcap`/`setcap`) | Store specific bits on a binary so exec grants a *slice* of root, not all of it |
| `CAP_NET_BIND_SERVICE`, `CAP_SYS_ADMIN`... | Names for individual bits; some (SYS_ADMIN) are near-root, most are narrow |
| K8s `drop:[ALL]` + `add:[X]` | Sets the container's bounding/effective masks to just bit X |
| `privileged: true` | Leaves *all* bits set (plus disables seccomp/AppArmor) = the old all-or-nothing root |

**Which rung to revisit hands-on (be honest):**
- If you can't yet predict what `capsh --decode` will print, **Rung 3.3 + Example 1** — sit with the bitmask until hex → cap names feels mechanical.
- If "root but powerless" still feels paradoxical, **Example 3** — run the bounding-set drop and watch UID 0 fail to bind :80. That single failure rewires the intuition permanently.
- If the K8s tie-in is fuzzy, **Rung 5 + Example 4** — trace one pod's caps from spec to `/proc` on the node, then diff it against a `privileged:true` pod.

---

## Related concepts

- [Permissions & Ownership](05-permissions-ownership.md) — the rwx/UID model and the SUID bit that capabilities replace.
- [Users, Groups & sudo](06-users-groups-sudo.md) — why UID 0 mattered before caps decoupled identity from privilege.
- [Namespaces](13-namespaces.md) — the other half of container isolation; user namespaces reshape which caps mean what.
- [seccomp](18-seccomp.md) — the next CKS layer: filter the *syscalls* a process may make, complementing capability drops.
- [AppArmor](19-apparmor.md) — path-based confinement that pairs with dropped caps for defense in depth.
- [Linux ⇄ Kubernetes Map](27-linux-kubernetes-map.md) — where `securityContext` fields land on real kernel primitives.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** A web server needs exactly one privileged operation: `bind()` to port 80. In the all-or-nothing model, what is the smallest privilege you are forced to grant, and what is the blast radius of a remote code-execution bug?

**A:** In the all-or-nothing world the smallest grantable privilege is the *whole thing*: UID 0, full root — because the kernel's check is literally `if (uid == 0) allow`, there is no way to hand out only "bind a low port." The blast radius of an RCE bug is therefore total machine compromise: the attacker's code runs as UID 0 and can rewrite `/etc/passwd`, load a kernel module or rootkit, mount your disks, and read every key. You wanted one tiny power (bind :80); you were forced to grant ownership of the entire machine.

### Before Rung 3
**Q:** In one sentence, what does `capable()` actually inspect, and how does that differ from the old `if (uid == 0)` test? What does "UID 0 with zero capabilities" mean in privilege terms?

**A:** `capable(CAP_X)` inspects whether the specific capability bit X is set in the calling task's **effective set** (`CapEff`) — it never looks at the UID, whereas the old test granted everything to whoever had UID 0. This decouples identity from privilege: the bits are the truth now, not the UID. "UID 0 with zero capabilities" means a process that is root in name only — `id` says `uid=0`, but with `CapEff = 0000000000000000` every `capable()` check fails, so it cannot perform a single privileged operation; it is harmless.

### Before Rung 4
**Q:** Name the five capability sets and when the kernel consults each. Which set does `drop:[ALL]` shrink, and why does shrinking it protect every child process?

**A:** (1) **Effective (`CapEff`)** — the set `capable()` actually checks right now; no bit here, no privileged action this instant. (2) **Permitted (`CapPrm`)** — the ceiling of what the process may raise into Effective. (3) **Inheritable (`CapInh`)** — caps that can survive an `execve()` into the new program's permitted set, but only if the executed file also marks them inheritable (legacy, fiddly). (4) **Bounding (`CapBnd`)** — the hard ceiling for the process *and all its descendants*; a bit not here can never be acquired, even by execing a file-cap binary. (5) **Ambient (`CapAmb`)** — the modern way for a non-root process to carry caps across `execve()` without file capabilities. `drop:[ALL]` shrinks the **bounding set** (runc also sets permitted/effective/ambient to match); because bounding is a hard wall inherited by every child, no process spawned inside the container can ever regain a dropped capability, forever.

### Before Rung 5
**Q:** `CapPrm` in `/proc/PID/status`, "the permitted set," and the `p` in `cap_net_raw=ep` are three names for what one thing? Why is `privileged: true` equivalent to `CapBnd = 000001ffffffffff`?

**A:** All three name the same 64-bit mask: the process's **permitted set** — `CapPrm` is how `/proc` prints it, "permitted set" is the English name, and `p` in file-capability syntax says "load this cap into the new process's permitted set at exec." `privileged: true` tells runc to leave the container's full capability set in place — all ~41 bits set, which in hex is `000001ffffffffff` in the bounding (and effective) mask — so nothing is walled off and the container holds every slice of root on the host kernel; on top of that, `privileged` also disables the device cgroup, seccomp, and AppArmor confinement. Same runtime state, three altitudes: pod spec, English, hex.

### Before Rung 6
**Q:** When the hardened pod's nginx tries `mount()` and gets `EPERM`, name the exact capability bit checked and the two sets that guarantee it can never be raised. Why wouldn't `setuid(0)` rescue it?

**A:** The kernel calls `capable(CAP_SYS_ADMIN)` — bit **21** — and reads nginx's **effective** set, where bit 21 is clear, so it returns `-EPERM`. The two sets that make this permanent are the **effective** set (the bit isn't there now) and the **bounding** set (bit 21 was dropped by runc via `prctl(PR_CAPBSET_DROP)`, so it can never be raised back into permitted/effective by this process or any child, even by execing a file-cap binary). `setuid(0)` wouldn't help because `capable()` never consults the UID — becoming UID 0 doesn't restore capability bits that the bounding set has walled off; identity and privilege are decoupled.

### Before Rung 7
**Q:** Your image contains a SUID-root helper, and the container's bounding set is `drop:[ALL]`. When the helper runs, does it get root's full power?

**A:** No. The SUID bit does change the process's UID to 0 at exec, but the capability sets a process can gain across `execve()` are always limited by the **bounding set** — a bit absent from `CapBnd` can never appear in the new process's permitted or effective sets, regardless of SUID or file capabilities. With `drop:[ALL]` the bounding set is empty, so the helper ends up as "UID 0 with zero capabilities": root in name only, failing every `capable()` check. This is exactly why shrinking the bounding set protects the container against privilege-escalation via forgotten SUID binaries baked into images.
