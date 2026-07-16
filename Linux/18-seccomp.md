# seccomp — System Call Filtering

*The second wall: after you strip a process of capabilities, seccomp decides which of the ~400 kernel syscalls it is even allowed to ask for — and RuntimeDefault is quietly doing this for your pods right now.*

---

## 🪜 Rung 0 — The Setup

**What am I learning?** *seccomp* (secure computing mode) — a Linux kernel feature that filters, per-process, **which system calls that process may make**. A syscall is the only doorway an application has into the kernel (open a file, send a packet, fork a process, mount a filesystem — every one is a syscall). seccomp lets you install a rulebook that says "this process may call `read`, `write`, `openat`… but if it ever calls `mount` or `ptrace`, deny it / kill it / log it." It is a *whitelist/blacklist for the kernel's front door*.

**Why did it land on my desk?** You're a Kubernetes platform engineer (~6 years DevOps/support, strong on `kubectl`, newer to Linux internals). You're studying for the **CKS** (Certified Kubernetes Security Specialist), and a security audit finding just landed: *"Containers run without a seccomp profile; the container runtime default is not enforced."* You `kubectl get pod -o yaml` and there's no `securityContext.seccompProfile` anywhere. Your lead says: "Turn on `RuntimeDefault` cluster-wide, then build a **custom** profile that blocks `mkdir` for one hardened workload, and prove in `/proc` that the container is actually confined." You know capabilities already ([capabilities](17-capabilities.md)) — you dropped `CAP_NET_RAW` and felt clever. Now someone is telling you capabilities are only *half* the wall. seccomp is the other half, and you can't see it from `kubectl` alone.

**What do I already know (assumed)?**
- From [capabilities](17-capabilities.md): root's power is split into ~40 capability bits; you can drop bits to shrink a process's privilege. seccomp is the *complementary* control — capabilities gate *privileged* operations, seccomp gates *which syscalls exist at all* for the process.
- From [linux-philosophy](01-linux-philosophy.md): `/proc/PID/status` is the kernel exposing per-process state as a file. We'll read a `Seccomp:` line straight out of it.
- From [processes-job-control](07-processes-job-control.md): a process, its PID, and that signals (like `SIGKILL`) come from the kernel.
- `kubectl` fluency: `securityContext`, Pod vs container-level fields.
- That **containerd** runs your containers and the **kubelet** configures them on each node under `/var/lib/kubelet`.

You do **not** need to know BPF or write C. That's the point of the ladder.

---

## 🔥 Rung 1 — The Pain

Sit with the problem before any command. If you feel the pain, the design becomes obvious.

**The problem:** capabilities are not enough. Suppose you drop *every* capability from a container (`capabilities: {drop: ["ALL"]}`). The process is now unprivileged — it cannot bind low ports, cannot load kernel modules, cannot change file ownership. Feels locked down. But it can **still call every non-privileged syscall in the kernel**: `ptrace` (attach to and read another process's memory), `keyctl` (kernel keyring), `unshare` (spin up new namespaces), `add_key`, `bpf`, `userfaultfd`, dozens of obscure calls. Many kernel privilege-escalation CVEs live in exactly these rarely-used syscalls — a bug in `keyctl` or `waitid` or an eBPF verifier flaw. Your container doesn't *need* those syscalls to serve HTTP, but the kernel will happily accept them, and a single kernel bug behind one of them is a container escape.

**The attack-surface framing:** the Linux kernel exposes roughly **300–450 syscalls** (varies by arch). A typical web app uses **40–70** of them. That means **hundreds of syscalls your app never calls are sitting there as live, reachable code paths into the kernel** — and the kernel is a shared, monolithic thing. Every pod on that node shares the same kernel. One exploited syscall = one compromised node = potentially every pod on it.

**What people did before — and why it hurt:**
- **Nothing (the default).** A container was just a process with namespaces and cgroups; it could invoke any syscall its capabilities allowed. Container escapes via syscall bugs (Dirty COW via `madvise`, `waitid` CVE-2017-5123, various `bpf` verifier holes) are the historical receipts.
- **Kernel recompiles / grsecurity patches.** Some shops ran hardened kernels that removed features. This hurt: you fork the kernel, you own patching it forever, and you can't tune it per-workload.
- **LSMs like SELinux/AppArmor** ([selinux](20-selinux.md), [apparmor](19-apparmor.md)) — powerful but *policy-object* oriented (files, ports, capabilities by path/label), and notoriously hard to author. They don't think in terms of "may this process call `syscall #165 (mount)`." That syscall-level granularity was the missing tool.

**Who feels the pain most?** You, at audit time and at 2 a.m. The developer sees "container runs." *You* are the one who has to answer "what is the blast radius if this container is popped?" Without seccomp, the honest answer is "the entire host kernel's syscall surface." With seccomp `RuntimeDefault`, the answer shrinks to "the ~60 syscalls we allowed, and we blocked ~44 dangerous ones outright."

> **Check yourself before Rung 2:** You dropped ALL capabilities from a container. Name one dangerous thing the process can *still* ask the kernel to do, and explain why capabilities didn't stop it. (Hint: capabilities gate *privileged* operations; is calling `ptrace` on your own child a *privileged* operation?)

---

## 💡 Rung 2 — The One Idea

Here it is. Memorize this exact sentence — everything else derives from it:

> **seccomp installs a per-process kernel filter that inspects every syscall the process makes and returns a verdict — allow, error, log, trap, or kill — based on the syscall number and its arguments, checked in the kernel before the syscall runs.**

That's the whole trick. Now derive the rest:

- *"per-process… installed"* → a process **opts in** by calling `prctl(PR_SET_SECCOMP, …)` or `seccomp(2)`. Once installed, the filter is **irrevocable** and **inherited by children** — you can only ever *add* more restriction, never loosen it. (This one-way ratchet is why it's safe: a compromised process can't turn seccomp off.)
- *"inspects every syscall"* → the check sits on the **syscall entry path** in the kernel. Every `read`, `write`, `mmap` the process makes is screened first. This is a *hot path*, so the filter must be tiny and fast → that's why it's **BPF** (a minimal, verified bytecode).
- *"based on the syscall number and its arguments"* → the filter sees the **syscall number** (e.g. `openat` = 257 on x86-64) and the **six raw register arguments**. It does **not** see dereferenced pointers (it can't safely follow a pointer to a filename — that would be a TOCTOU race). So seccomp filters by *which* syscall and *scalar* argument values, not by "which file."
- *"returns a verdict"* → the verdict is one of a fixed menu of **actions**: `SCMP_ACT_ALLOW` (let it through), `SCMP_ACT_ERRNO` (fail it with a chosen errno, e.g. `EPERM`, app keeps running), `SCMP_ACT_LOG` (allow but log — the profiling mode), `SCMP_ACT_TRAP` (send `SIGSYS`), `SCMP_ACT_KILL` (kill the thread/process instantly).
- *"checked in the kernel before the syscall runs"* → there's a **`defaultAction`** (what happens to any syscall you didn't name) plus a **list of exceptions** (`syscalls[]`). That two-part shape — one default + a list of overrides — *is* the entire seccomp profile JSON. A "deny by default, allow a list" profile is a whitelist; an "allow by default, error a list" profile is a blacklist.

If you hold "**one default action + a list of per-syscall overrides, enforced in-kernel on every syscall, ratchet-only**," you can read any seccomp profile and predict what it does.

> **Check yourself before Rung 3:** From the one sentence alone, explain why seccomp cannot make a rule like "block `open` but only for `/etc/shadow`." (Hint: what part of the syscall does the filter get to see, and what part is behind a pointer it must not follow?)

---

## ⚙️ Rung 3 — The Machinery (the important rung — go slow)

We now open the hood. Three things to understand: **(A) where the filter physically sits, (B) what a filter actually *is* (BPF), and (C) the three modes and the `Seccomp:` field that reports them.**

### 3.1 Where the check lives: the syscall entry gate

When any process makes a syscall, the CPU switches to kernel mode and the kernel runs its syscall dispatcher. seccomp inserts a checkpoint **right at that gate, before the real syscall handler runs**:

```
   USER SPACE                         KERNEL SPACE
 ┌───────────────┐        syscall     ┌──────────────────────────────────────┐
 │  your process │   (e.g. mkdir())   │                                      │
 │  in a container│ ─────────────────▶│  1. syscall entry / dispatcher       │
 │  (nginx, etc.)│                    │            │                         │
 └───────────────┘                    │            ▼                         │
                                      │   ┌───────────────────────┐          │
        the app thinks it just        │   │  SECCOMP FILTER (BPF)  │  ◀── the │
        called mkdir and it worked/   │   │  input: syscall_nr,    │   second │
        failed like normal            │   │         arch, args[6]  │    wall  │
                                      │   └──────────┬────────────┘          │
                                      │              │ verdict               │
                                      │      ┌───────┼─────────┬──────────┐   │
                                      │      ▼       ▼         ▼          ▼   │
                                      │   ALLOW    ERRNO      LOG        KILL │
                                      │     │      (return    (allow+    (send│
                                      │     ▼      -EPERM,    audit log) SIGSYS/│
                                      │  real      app runs)              die)│
                                      │  mkdir()                              │
                                      │  handler                              │
                                      └──────────────────────────────────────┘
                                                     │
                                                     ▼
                                            capability check (CAP_*)
                                            DAC/LSM (SELinux/AppArmor)
                                            …then the actual work
```

Notice the **ordering**: seccomp fires *before* the capability check and *before* the LSM (SELinux/AppArmor) hooks. That's why we call it the **second wall** — but it's really the *first gate* on the syscall path. If seccomp says `ERRNO` on `mkdir`, the kernel never even reaches the capability check; the process just gets `EPERM` back as though it were an unprivileged failure. Capabilities and seccomp are **independent, layered** controls: capabilities ask "are you *allowed* to do this privileged thing?"; seccomp asks "are you even permitted to *utter this syscall*?"

### 3.2 What a filter actually is: BPF (why it's bytecode, not JSON)

The kernel does not read your JSON. JSON is a *human/tooling* format. What actually gets installed is a **BPF program** — classic Berkeley Packet Filter bytecode, the same tiny instruction set originally built for `tcpdump`. Here's the pipeline:

```
  YOU / KUBELET write:           libseccomp / runtime          KERNEL stores:
  seccomp profile JSON     ──▶   compiles it to           ──▶  a BPF program
  { defaultAction,               classic BPF opcodes            attached to the
    syscalls:[...] }             (load syscall_nr,              process (fd/task)
                                  compare, return verdict)
```

A BPF seccomp program is deliberately crippled so it's **safe and fast**: no loops, no memory writes, bounded length, must pass the kernel verifier. Its input is a fixed struct — `struct seccomp_data { int nr; __u32 arch; __u64 instruction_pointer; __u64 args[6]; }`. So the program can branch on the **syscall number**, the **architecture** (important! syscall #1 means different things on x86-64 vs i386, so real profiles pin `architectures`), and the **six scalar args** — but it *cannot dereference a pointer*. That is the hard, permanent boundary of seccomp: **it filters by syscall and scalar arguments, never by the contents behind a pointer** (no filtering by filename, no filtering by the string a `write` sends).

**Two modes of seccomp exist:**

- **Strict mode** (`SECCOMP_SET_MODE_STRICT`, the original 2005 feature): the process may call **exactly four syscalls** — `read`, `write`, `_exit`, `sigreturn` — and *nothing else*; any other syscall = instant `SIGKILL`. No configuration, no list. It was designed for "run this untrusted number-crunching blob that only reads from an fd, computes, and writes to an fd." Almost nothing real can live under it (you can't even `close` an fd), so it's a historical curiosity today.
- **Filter mode** (`SECCOMP_SET_MODE_FILTER`, added 2012): the flexible one. *You* supply the BPF filter, so you decide the default and the per-syscall verdicts. **This is what containers, Docker, and Kubernetes use.** When people say "seccomp profile," they mean a filter-mode BPF program.

### 3.3 The `Seccomp:` field in /proc/PID/status — reading the mode

The kernel reports each process's seccomp state as a single integer in `/proc/PID/status`:

```
Seccomp:   0      →  disabled          (no filter — full syscall surface)
Seccomp:   1      →  strict mode        (the 4-syscall jail)
Seccomp:   2      →  filter mode        (a BPF filter is installed) ← what you want on a pod
```

There's also a companion line on newer kernels:

```
Seccomp_filters:  1   →  how many filters are stacked on this process
                        (filters ADD — you can layer a second, never remove the first)
```

**This is your audit oracle.** "Is this container confined?" becomes a concrete, checkable fact: find the container's PID on the node and read `Seccomp:` from `/proc`. `2` means a filter is enforced; `0` means the container is running with the **full, unfiltered kernel syscall surface** — which is exactly the audit finding you were handed.

### 3.4 The profile JSON shape (the format kubelet loads)

A Localhost profile is just a JSON file. Its skeleton is *the one idea made concrete* — one default, a list of overrides:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",      // what happens to any syscall NOT listed below
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["read", "write", "openat", "close", "mmap", "exit_group"],
      "action": "SCMP_ACT_ALLOW"          // the exceptions to the default
    }
  ]
}
```

- `defaultAction` = the verdict for everything you didn't name. `SCMP_ACT_ALLOW` here = a *blacklist* (allow all, then block a few); `SCMP_ACT_ERRNO`/`SCMP_ACT_KILL` here = a *whitelist* (block all, then allow a few). **The container runtime `RuntimeDefault` profile is actually a *whitelist*** — its `defaultAction` is `SCMP_ACT_ERRNO`, paired with a large allow-list of ~300+ syscalls that normal apps need. The net effect is that ~44 notable dangerous syscalls (`mount`, `reboot`, `kexec_load`, `init_module`, `keyctl`, `bpf`, `ptrace` under most conditions, …) are simply *not on the allow-list* and therefore denied. People often call it a "blacklist" as a mental shortcut (they picture "the ~44 blocked ones"), but mechanically it is **default-deny**.
- `architectures` = which CPU ABIs this applies to. You list them because syscall numbers differ per ABI, and an attacker on x86-64 could otherwise slip in via the 32-bit ABI.
- `syscalls[]` = the override list. Each entry names one or more syscalls and the action to apply.

### 3.5 How this reaches your pods: kubelet → containerd → runc

Here is the Kubernetes machinery, end to end:

```
  Pod spec:                          Node filesystem:
  securityContext:                   /var/lib/kubelet/seccomp/
    seccompProfile:                     profiles/
      type: Localhost                     deny-mkdir.json   ← your custom JSON lives here
      localhostProfile:  ─────────────────────┘
        profiles/deny-mkdir.json

        │ kubelet reads the pod spec
        ▼
   kubelet resolves the profile path (relative to /var/lib/kubelet/seccomp/)
        │ passes it in the OCI runtime spec (config.json → "linux.seccomp")
        ▼
   containerd  ──▶  runc  reads the OCI seccomp block, compiles it to BPF,
                          calls seccomp(2) to install the filter…
        │                 …THEN execs your container's entrypoint
        ▼
   your container process now has  Seccomp: 2  and the filter is active
```

Two profile **types** you'll set in `seccompProfile.type`:
- **`RuntimeDefault`** → use the container runtime's built-in default profile (containerd/Docker ship one). No file needed; it's baked into the runtime. This is the sane, broad hardening you want on **by default** for every workload.
- **`Localhost`** → use a **custom JSON file** you placed under `/var/lib/kubelet/seccomp/` on the node, named by `localhostProfile` (a path *relative* to that base dir). This is how you build a tighter, workload-specific profile.
- (There's also `Unconfined` = no seccomp = `Seccomp: 0`. That's the pre-audit state you're eliminating.)

**Why should `RuntimeDefault` be on by default?** Because it's a broad, battle-tested default-deny profile (a whitelist with a generous allow-list) that keeps the historically dangerous syscalls (`mount`, `umount2`, `reboot`, `swapon`, `kexec_load`, `init_module`, `finit_module`, `delete_module`, `ptrace` in most cases, `keyctl`, etc.) *off* the allow-list while allowing the ~300+ syscalls normal apps need — so it almost never breaks a workload, yet it removes ~44 of the juiciest kernel-escape doorways. It's the highest security-per-risk ratio control you have. Since Kubernetes 1.27 you can even make it the cluster-wide default via the kubelet flag `--seccomp-default=true` (feature `SeccompDefault`, GA in 1.27) so every pod that doesn't specify a profile gets `RuntimeDefault` automatically.

> **Check yourself before Rung 4:** Draw the syscall gate from memory. (1) Does seccomp fire before or after the capability check? (2) What are the exactly-four inputs the BPF filter gets, and which one can it *not* follow? (3) If `/proc/PID/status` shows `Seccomp: 0`, what does that tell your auditor about the container's kernel attack surface?

---

## 🏷️ Rung 4 — The Vocabulary Map

Every scary term now has a place to land in the machinery you just built.

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **syscall** | The only interface from a process into the kernel (open, write, mount…) | The thing being filtered at the entry gate (3.1) |
| **seccomp** | Kernel feature that filters syscalls per-process | The whole second wall |
| **strict mode** | The original mode: only `read/write/_exit/sigreturn` allowed | `Seccomp: 1`; the 4-syscall jail (3.2) |
| **filter mode** | Flexible mode: you supply a BPF filter | `Seccomp: 2`; what containers use (3.2) |
| **BPF** | Tiny verified bytecode the kernel actually runs as the filter | What JSON compiles down to (3.2) |
| **seccomp_data** | The fixed struct the filter sees: `nr`, `arch`, `args[6]` | The filter's *only* inputs (3.2) |
| **prctl / seccomp(2)** | The syscalls a process calls to install its own filter | How the filter gets attached (2, 3.5) |
| **defaultAction** | The verdict for any syscall not explicitly listed | Top of the profile JSON (3.4) |
| **syscalls[]** | The override list: names + action | Body of the profile JSON (3.4) |
| **SCMP_ACT_ALLOW** | Verdict: let the syscall run | An action (3.1) |
| **SCMP_ACT_ERRNO** | Verdict: fail with an errno (e.g. EPERM); app keeps running | An action — used for graceful denies (3.1) |
| **SCMP_ACT_LOG** | Verdict: allow but write an audit log line | The *profiling* action (3.1, Rung 7) |
| **SCMP_ACT_TRAP** | Verdict: deliver `SIGSYS` to the process | An action |
| **SCMP_ACT_KILL** | Verdict: kill the thread/process immediately | The harshest action (3.1) |
| **architectures** | Which CPU ABIs the profile pins | `architectures` array (3.4) |
| **RuntimeDefault** | The runtime's built-in default profile | `type` in K8s (3.5) |
| **Localhost** | A custom JSON under `/var/lib/kubelet/seccomp/` | `type` + `localhostProfile` (3.5) |
| **Unconfined** | No seccomp at all | `Seccomp: 0` (3.5) |
| **Seccomp: 0/1/2** | The mode integer in `/proc/PID/status` | Your audit oracle (3.3) |
| **strace** | A debugger that traces every syscall a process makes | The tool to *discover* needed syscalls (Rung 7) |
| **libseccomp** | The userspace library that compiles rules → BPF | The JSON→BPF compiler (3.2) |

### The big unlock: which terms are the *same kind of thing*

```
GROUP 1 — "The mode integer" (one concept, several faces):
   Seccomp: 0 = Unconfined = "no filter"
   Seccomp: 1 = strict mode
   Seccomp: 2 = filter mode = "a BPF profile is installed" = RuntimeDefault/Localhost

GROUP 2 — "Verdicts / actions" (all the same menu, pick one per syscall):
   SCMP_ACT_ALLOW / ERRNO / LOG / TRAP / KILL
   → ERRNO = graceful deny (app survives);  KILL = brutal deny (app dies);
     LOG = "allow but tattle" (profiling);  ALLOW = permit.

GROUP 3 — "The profile is just two things":
   defaultAction (the catch-all)  +  syscalls[] (the overrides)
   → whitelist = deny-default + allow-list;  blacklist = allow-default + deny-list

GROUP 4 — "K8s profile source" (where the BPF comes from):
   RuntimeDefault (baked into containerd) | Localhost (your JSON file) | Unconfined (none)

GROUP 5 — "The tooling layer" (never seen at runtime):
   your JSON  →  libseccomp  →  BPF bytecode  →  the kernel
```

Hold those five groups and the jargon collapses into one idea applied five ways.

> **Check yourself before Rung 5:** Without looking — what is the difference in *runtime behavior* between `SCMP_ACT_ERRNO` and `SCMP_ACT_KILL` on a blocked `mkdir`, and which one would you choose while first rolling out a new profile, and why?

---

## 🔬 Rung 5 — The Trace

Let's trace **one concrete action end to end**: a pod is created with a **Localhost** profile that denies `mkdir`, the container runs `mkdir /tmp/foo`, and we watch the verdict travel. Assume the profile below is at `/var/lib/kubelet/seccomp/profiles/deny-mkdir.json` with `defaultAction: SCMP_ACT_ALLOW` and `mkdir`/`mkdirat` set to `SCMP_ACT_ERRNO`.

1. **kubectl apply → API server → scheduler → kubelet.** The Pod spec carries `securityContext.seccompProfile.type: Localhost` and `localhostProfile: profiles/deny-mkdir.json`. The scheduler places the pod; the node's **kubelet** picks it up.
2. **kubelet resolves the profile path.** It joins `localhostProfile` to the base dir → `/var/lib/kubelet/seccomp/profiles/deny-mkdir.json`, reads the JSON, and writes it into the **OCI runtime spec** (`config.json`) under `linux.seccomp`. If the file is missing, the pod fails to start with `CreateContainerError` — the kubelet won't silently run it unconfined.
3. **kubelet → containerd → runc.** containerd hands the OCI spec to **runc**. runc calls **libseccomp**, which compiles the JSON into a **BPF program** (default = ALLOW; `mkdir`/`mkdirat` → return ERRNO).
4. **runc installs the filter, then execs.** runc calls `seccomp(2)` to attach the BPF program to the soon-to-be container process, **then `execve`s your entrypoint**. From this instant the process's `/proc/PID/status` reads `Seccomp: 2`. The ratchet is set — nothing in the container can undo it.
5. **The app runs `mkdir /tmp/foo`.** The libc `mkdir()` wrapper issues the `mkdirat` syscall. The CPU traps into the kernel and hits the **syscall entry gate**.
6. **The BPF filter fires.** It loads `seccomp_data.nr`, sees it equals the syscall number for `mkdirat`, matches the rule, and returns the verdict **`ERRNO(EPERM)`**.
7. **The kernel short-circuits.** It does **not** run the real `mkdirat` handler and never reaches the capability check. It returns `-EPERM` to userspace.
8. **The app sees a normal failure.** `mkdir()` returns `-1`, `errno = EPERM`. The app prints `mkdir: cannot create directory '/tmp/foo': Operation not permitted` — indistinguishable from a permissions error. **The app keeps running** (that's `ERRNO`, not `KILL`).
9. **You verify from the node.** You read `/proc/PID/status` → `Seccomp: 2`, confirming the filter is live. Had the profile used `SCMP_ACT_LOG` instead, step 6 would ALLOW the `mkdir` *and* emit a kernel audit line you could read with `journalctl -k | grep seccomp`.

```
 kubectl apply                                            deny-mkdir.json
      │  Pod: type: Localhost                             (on the node)
      ▼  localhostProfile: profiles/deny-mkdir.json            │
 [API server] ──▶ [scheduler] ──▶ [KUBELET on node] ◀──────────┘ reads file
                                       │ writes linux.seccomp into OCI spec
                                       ▼
                                 [containerd] ──▶ [runc]
                                                   │ libseccomp: JSON → BPF
                                                   │ seccomp(2) installs filter
                                                   │ execve(entrypoint)
                                                   ▼
                                        ┌────────────────────────┐
                                        │  container process     │  Seccomp: 2
                                        │  runs: mkdir /tmp/foo   │
                                        └───────────┬────────────┘
                                                    │ mkdirat syscall
                                                    ▼
                                        [BPF filter] nr == mkdirat?
                                                    │ yes → SCMP_ACT_ERRNO
                                                    ▼
                                        kernel returns -EPERM (handler never runs)
                                                    │
                                                    ▼
                              app: "mkdir: Operation not permitted"  (still alive)
```

> **Check yourself before Rung 6:** At step 7 the kernel "short-circuits." What does that word mean for the *capability check* that normally follows — did it run? And why does the app experience a `mkdir` denied by seccomp as identical to one denied by ordinary file permissions?

---

## ⚖️ Rung 6 — The Contrast

seccomp isn't the only "confine a process" tool. Its boundary defines it.

### The alternatives: capabilities and LSMs (AppArmor/SELinux)

- **Capabilities** ([capabilities](17-capabilities.md)) split *root's* power into bits. They answer "may this process perform this *privileged* operation?" They do **not** reduce the syscall surface — a process with zero capabilities can still *call* `ptrace`, `keyctl`, `bpf`; it just gets `EPERM` on the privileged ones. Capabilities are coarse (one bit can cover many operations) and only cover *privileged* actions.
- **AppArmor** ([apparmor](19-apparmor.md)) / **SELinux** ([selinux](20-selinux.md)) are **LSMs** — Mandatory Access Control keyed on *objects*: files by path (AppArmor) or by label (SELinux), network ports, capabilities. They answer "may this program *touch this object*?" They can express "deny writes to `/etc/**`" — something seccomp fundamentally *cannot*, because seccomp never sees the path behind the pointer.

### What each can do that the others cannot

| Question | seccomp | capabilities | AppArmor/SELinux |
|---|---|---|---|
| Block an entire syscall (e.g. `mount`, `ptrace`) outright | ✅ core purpose | ⚠️ only if it's a *privileged* op | ⚠️ AppArmor can deny some, not by syscall number |
| Filter by *which file* a syscall touches | ❌ never (pointer, not followed) | ❌ | ✅ their core purpose |
| Restrict *privileged* operations by category | ⚠️ indirectly | ✅ core purpose | ✅ (capability rules) |
| Filter by scalar syscall *argument* (e.g. `clone` flags) | ✅ (args[6]) | ❌ | ❌ |
| Kill the process on violation | ✅ `SCMP_ACT_KILL` | ❌ (just EPERM) | ✅ (enforce mode) |
| Shrink the raw kernel attack surface | ✅ its whole reason to exist | ❌ surface unchanged | ⚠️ partially |
| Easy to author safely | ✅ (RuntimeDefault ships ready) | ✅ | ❌ (notoriously hard) |

The pattern: **seccomp is the only tool that reasons in terms of "which syscall number, with which scalar args."** LSMs reason about objects; capabilities reason about privilege categories. They are **complementary layers**, not competitors — a hardened pod runs *all three*: `RuntimeDefault` seccomp + dropped capabilities + an AppArmor/SELinux profile. Each closes a door the others leave open.

### When would I NOT need a custom seccomp profile?

- You already run `RuntimeDefault` and the workload works — a custom Localhost profile adds maintenance cost (you must re-profile it whenever the app's syscalls change after an upgrade). Don't build a bespoke whitelist unless the threat model justifies it.
- Your requirement is "this app must not read `/etc/shadow`" — that's a *file* rule; use AppArmor/SELinux, not seccomp.
- Your requirement is "no low-port binding, no raw sockets" — that's *capabilities* (`CAP_NET_BIND_SERVICE`, `CAP_NET_RAW`), cheaper than a syscall filter.

**One-sentence "why this over that":**
> Use seccomp when you want to remove whole *syscalls* from a process's reach (shrink the kernel attack surface); use capabilities to gate *privileged operations* and LSMs to gate access to specific *files/objects* — and on anything sensitive, layer all three.

> **Check yourself before Rung 7:** A teammate says "we have AppArmor denying writes to `/etc`, so we don't need seccomp." Explain the class of attack AppArmor leaves open that `RuntimeDefault` seccomp would close. (Hint: think of a kernel `mount` or `keyctl` bug that never touches a file path.)

---

## 🧪 Rung 7 — The Prediction Test

Write the prediction, cover the outcome, decide if you agree, **then** run it. A wrong prediction is your mental model repairing itself. These live on a modern Linux (Ubuntu 22.04, systemd, cgroup v2) with a running Kubernetes node; note distro differences where they bite.

### Prediction 0 — Is seccomp even compiled into this kernel?

> **Prediction:** "If I grep the kernel build config for `CONFIG_SECCOMP`, then it will read `=y` (built in, not a module) — *because* seccomp is core kernel security infra that distros compile in unconditionally; nothing works below this line if it's off."

```bash
grep CONFIG_SECCOMP /boot/config-$(uname -r)
# CONFIG_SECCOMP=y
# CONFIG_SECCOMP_FILTER=y      ← filter mode (BPF) support; you need THIS for profiles
# CONFIG_HAVE_ARCH_SECCOMP_FILTER=y
```

**Verify:** You want both `CONFIG_SECCOMP=y` and `CONFIG_SECCOMP_FILTER=y`. If `CONFIG_SECCOMP_FILTER` were missing, only strict mode would exist and **no container seccomp profile could load** — every pod would silently run `Unconfined`. On a distro without `/boot/config-*` (some minimal images), use `zcat /proc/config.gz | grep CONFIG_SECCOMP` instead.

---

### Prediction 1 — A normal process runs unconfined; count its real syscalls with strace

> **Prediction:** "If I run `strace -c ls`, then I'll get a summary table showing `ls` uses only a few dozen distinct syscalls (openat, read, write, mmap, close, statx…) — *because* a real program touches a tiny fraction of the ~400 the kernel exposes, which is exactly why a whitelist profile is feasible."

```bash
strace -c ls /tmp
#  % time     seconds  usecs/call     calls    errors syscall
#  ------ ----------- ----------- --------- --------- ----------------
#   18.2   0.000112           7        16           mmap
#   12.4   0.000076           6        12           openat
#    9.1   0.000056           5        11           close
#    ...
#  ------ ----------- ----------- --------- --------- ----------------
# 100.00  0.000615                    ~90        3   total
# (roughly 25–35 DISTINCT syscall NAMES in the left column)
```

Now turn that trace into a **minimal syscall whitelist** — the exact workflow for building a custom profile:

```bash
# -f follow children, trace ALL syscalls, then pull unique syscall names:
strace -f -e trace=all -o /tmp/trace.txt ls /tmp
awk -F'(' '/^[a-z_]+\(/{print $1}' /tmp/trace.txt | sort -u
# openat
# read
# write
# close
# mmap
# ... one syscall name per line — this list IS your allow-list
```

**Verify:** The `strace -c` left column lists the distinct syscalls; the `awk` pipeline gives you the deduplicated names to drop into a profile's `syscalls[].names`. If the list is *huge* (hundreds), you traced something with a heavy runtime (JVM/node) — real apps still land well under the full kernel surface. This is precisely how you author a Localhost whitelist: **trace the app, collect the syscalls, allow exactly those, deny the rest.**

---

### Prediction 2 — Audit/LOG mode profiles *without breaking* the app, and the denial lands in the kernel log

> **Prediction:** "If I run a program under a seccomp profile whose `mkdir` action is `SCMP_ACT_LOG`, then the `mkdir` will *succeed* AND a line will appear in the kernel log — *because* `LOG` means 'allow but tattle', which is the safe way to discover what a future *deny* profile would block before you actually block it."

Docker is the easiest local harness for filter-mode profiles (same JSON kubelet uses). Create the audit profile:

```bash
cat > /tmp/audit-mkdir.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_LOG" }
  ]
}
EOF

docker run --rm --security-opt seccomp=/tmp/audit-mkdir.json \
  alpine sh -c 'mkdir /tmp/foo && echo "mkdir SUCCEEDED under LOG mode"'
# mkdir SUCCEEDED under LOG mode      ← LOG allows it

# Now read the kernel ring buffer for the audit line the filter emitted:
journalctl -k | grep seccomp
# ... kernel: audit: type=1326 ... comm="mkdir" ... syscall=83 ... SECCOMP ...
#     (syscall=83 is mkdir on x86-64; the line proves the filter saw it)
```

**Verify:** The container prints success (LOG never blocks), and `journalctl -k | grep seccomp` shows an audit record naming the syscall. If you see *no* log line, your kernel may route seccomp audit through `auditd` instead — try `ausearch -m seccomp` or `dmesg | grep -i seccomp`. **This is the profiling technique:** ship `SCMP_ACT_LOG` first, run the app through its real workload, collect every syscall the log flags, *then* flip the profile to deny. Denying blind is how you cause a 2 a.m. outage.

---

### Prediction 3 — A deny profile makes the syscall fail with EPERM, and the app survives (ERRNO) vs dies (KILL)

> **Prediction:** "If I switch `mkdir`/`mkdirat` to `SCMP_ACT_ERRNO`, then `mkdir` fails with 'Operation not permitted' but the shell keeps running; if I switch to `SCMP_ACT_KILL`, the process is killed the instant it calls `mkdir` — *because* ERRNO returns an errno while KILL sends an un-catchable death, and choosing between them is choosing graceful degradation vs hard stop."

```bash
# ERRNO variant — app survives the denial:
cat > /tmp/deny-mkdir.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO" }
  ]
}
EOF
docker run --rm --security-opt seccomp=/tmp/deny-mkdir.json \
  alpine sh -c 'mkdir /tmp/foo; echo "shell still alive, exit=$?"'
# mkdir: can't create directory '/tmp/foo': Operation not permitted
# shell still alive, exit=1          ← ERRNO: syscall failed, process lived

# KILL variant — flip the action and the process dies mid-syscall:
sed 's/SCMP_ACT_ERRNO/SCMP_ACT_KILL/' /tmp/deny-mkdir.json > /tmp/kill-mkdir.json
docker run --rm --security-opt seccomp=/tmp/kill-mkdir.json \
  alpine sh -c 'mkdir /tmp/foo; echo "you will NEVER see this line"'
# (no output after the mkdir; container exits with code 159 = 128 + SIGSYS(31))
echo "container exit code: $?"   # 159
```

**Verify:** ERRNO → you see "Operation not permitted" and the shell prints its "still alive" line; KILL → the shell is killed at the `mkdir` and the "NEVER see this" line never prints (exit 159 = 128+31, i.e. died on `SIGSYS`). If ERRNO *killed* the process, you mislabeled the action; if KILL *let it continue*, the profile didn't apply. This is the ERRNO-vs-KILL trade you predicted in Rung 4.

---

### Prediction 4 (Kubernetes) — RuntimeDefault sets Seccomp:2; a custom Localhost deny-profile blocks mkdir in a real pod

> **Prediction:** "If I create a pod with `seccompProfile.type: RuntimeDefault`, then reading `/proc/1/status` inside it will show `Seccomp:\t2` (a filter is enforced) — *because* the runtime compiled its default profile to BPF and runc installed it before exec. And if I instead point the pod at a custom Localhost `deny-mkdir.json`, `mkdir` inside the container will fail with EPERM while the container stays Running."

First, place the custom profile on **every node** where the pod might land (kubelet reads it locally, relative to `/var/lib/kubelet/seccomp/`):

```bash
# On the node (or via a DaemonSet that writes it):
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
sudo tee /var/lib/kubelet/seccomp/profiles/deny-mkdir.json >/dev/null <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    { "names": ["mkdir", "mkdirat"], "action": "SCMP_ACT_ERRNO" }
  ]
}
EOF
```

Pod A — the baseline hardening every workload should have (`RuntimeDefault`):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: seccomp-default }
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: alpine
    command: ["sleep", "3600"]
EOF

# Prove it's confined — read the mode integer from inside the container:
kubectl exec seccomp-default -- grep Seccomp /proc/1/status
# Seccomp:        2          ← filter mode active = RuntimeDefault is enforced
# Seccomp_filters:        1
```

Pod B — the custom **Localhost** deny profile:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: seccomp-deny-mkdir }
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-mkdir.json
  containers:
  - name: app
    image: alpine
    command: ["sleep", "3600"]
EOF

# The custom filter is installed (still Seccomp: 2)…
kubectl exec seccomp-deny-mkdir -- grep Seccomp /proc/1/status
# Seccomp:        2

# …and mkdir is specifically blocked while the pod stays Running:
kubectl exec seccomp-deny-mkdir -- mkdir /tmp/foo
# mkdir: can't create directory '/tmp/foo': Operation not permitted
# command terminated with exit code 1
kubectl get pod seccomp-deny-mkdir   # STATUS: Running (ERRNO didn't kill it)
```

**Verify:**
- `RuntimeDefault` pod → `Seccomp: 2`. If it showed `0`, the pod is `Unconfined` (your original audit finding) — check the runtime is containerd and the field is spelled `seccompProfile` under `securityContext`.
- `Localhost` pod → `Seccomp: 2` **and** `mkdir` gives `Operation not permitted`. If the pod is stuck in `CreateContainerError`, the JSON file is missing on that node or `localhostProfile` has a wrong (or leading-slash — it must be *relative*) path. If `mkdir` *succeeded*, the profile didn't apply — confirm the file path and that this node is the one running the pod.
- For the audit at scale, verify no pod runs unconfined by checking each container's PID on the node: `for p in $(pgrep -f pause); do grep Seccomp /proc/$p/status; done` — none should read `0`. (The **pause** container itself is often `RuntimeDefault` too.)

> **CKS note:** the exam loves exactly this loop — given a pod, add `RuntimeDefault`; given a JSON profile, drop it under `/var/lib/kubelet/seccomp/`, wire it via `type: Localhost` + `localhostProfile`, and prove confinement with `grep Seccomp /proc/1/status`. Also know `--seccomp-default=true` (kubelet flag, feature `SeccompDefault`, GA in 1.27) to make `RuntimeDefault` the cluster-wide default so no pod is silently `Unconfined`.

---

## 🏔 Capstone — Compress It

**One sentence, no notes:**
> seccomp installs a per-process, inherited, one-way BPF filter at the kernel's syscall gate that returns a verdict (allow / errno / log / kill) for every syscall based on its number and scalar arguments, shrinking a process's reachable kernel attack surface from ~400 syscalls to the handful it actually needs.

**Explain it to a beginner in 3 sentences:**
> 1. Every program talks to the Linux kernel through system calls, and there are hundreds of them, but any given app only uses a few dozen — the rest just sit there as extra doors an attacker could use to break out of a container.
> 2. seccomp lets you install a tiny in-kernel rulebook that checks each system call a process makes and either allows it, fails it with an error, logs it, or kills the process — and once installed it can never be turned off or loosened, only tightened.
> 3. In Kubernetes you turn this on by setting `seccompProfile.type: RuntimeDefault` (the runtime's ready-made safe profile) or `Localhost` (your own JSON under `/var/lib/kubelet/seccomp/`), and you prove a container is confined by reading `Seccomp: 2` from `/proc/PID/status`.

**Map of sub-capability → the one core idea (one default + a list of syscall verdicts, enforced at the gate):**

```
Strict mode           → the 4-syscall preset (default=KILL, allow read/write/_exit/sigreturn)
Filter mode           → you supply the default + the list  → Seccomp: 2
RuntimeDefault        → a runtime-shipped whitelist (default=ERRNO, allow ~300+ safe syscalls, deny ~44 dangerous ones)
Localhost profile     → your custom JSON: defaultAction + syscalls[]
SCMP_ACT_ALLOW/ERRNO  → the "verdict" half of the idea (permit vs graceful deny)
SCMP_ACT_LOG          → verdict = "allow but tattle" → the safe profiling on-ramp
SCMP_ACT_KILL         → verdict = "hard stop"
strace → awk          → how you DISCOVER the list to put in syscalls[]
/proc/PID/status      → how you READ BACK which verdict-engine (0/1/2) is installed
```

Nine rows, one idea: *a default action plus a list of per-syscall overrides, judged in the kernel on every call.*

**Which rung will I most likely need to revisit hands-on?**
- **Rung 3.2 (BPF / what the filter can see).** The "it can't follow the pointer, so no filtering by filename" boundary is the single most misunderstood fact; the fix is to sit with the `seccomp_data` struct and say out loud what each field is.
- **Rung 7 Prediction 2 (LOG/audit mode).** The *profile-then-deny* workflow — LOG first, collect from `journalctl -k | grep seccomp`, then flip to ERRNO — is the muscle memory that keeps you from shipping a profile that breaks the app. Run it once for real before you trust yourself with a production deny profile.

If either felt shaky on its check-yourself question, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [capabilities](17-capabilities.md) — the *other* wall: gating privileged operations; run it *with* seccomp, not instead of.
- [apparmor](19-apparmor.md) — path-based MAC; filters by *file/object*, the thing seccomp structurally cannot see.
- [selinux](20-selinux.md) — label-based type enforcement; the third layer of a hardened pod.
- [namespaces](13-namespaces.md) — what *isolates* a container; seccomp *confines* what the isolated process may ask the kernel to do.
- [processes-job-control](07-processes-job-control.md) — PIDs, signals (`SIGSYS`/`SIGKILL`), and reading `/proc/PID/status`.
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — where seccomp sits in the full Linux↔K8s security picture.
