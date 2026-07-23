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

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of the operating system's core (the "kernel") as a busy government office. A program can't do anything real — open a file, send mail, start a helper — without walking up to the service counter and filing a request. There are about 400 different request forms. **Seccomp** is a security screener standing at the counter with a checklist for each visitor, deciding which request forms that visitor is even allowed to submit.
>
> - **Where the screener stands (3.1).** The screener is positioned at the *very front door* of the office — before any clerk even looks at whether you have the right permissions for a request. If your checklist says "no 'create folder' forms," you're turned away at the door with a polite "not allowed," and the deeper permission checks never happen. So there are layers: the door screener (seccomp) first, then the permission clerks (capabilities and other guards) behind them.
> - **What the checklist really is (3.2).** The screener doesn't read a wordy policy document. The rules are compiled into a tiny, ultra-fast flip-book of yes/no checks — deliberately simple so it can screen millions of requests per second and can never misbehave. One important limit: the screener can only look at the *form number* and a few numbers written in its boxes — they cannot open attached envelopes. So the rule can be "no 'open file' forms at all," but never "no opening *this particular* file." There's also an ancient, ultra-strict version of the screener that allows only four forms total — basically a historical curiosity; the flexible "checklist" version is what everyone actually uses.
> - **The badge on the visitor (3.3).** Every program wears a badge you can read that says which screening it's under: 0 = no screening at all, 1 = the ancient four-form jail, 2 = a checklist is active. Auditors love this: "is this app confined?" becomes "read the badge — is it a 2?"
> - **How a checklist is written (3.4).** Every checklist has just two parts: a default answer ("deny everything…" or "allow everything…") plus a list of exceptions. The standard built-in checklist says "deny by default, but allow the ~300 everyday forms" — which quietly bans the ~44 most dangerous ones.
> - **How it reaches your apps (3.5).** In Kubernetes (the software that manages apps in sealed boxes), the node's caretaker reads your app's settings, hands the checklist down a short chain of helpers, and the last helper pins it on the program just before it starts. You can pick: the sensible built-in checklist, a custom one you wrote and stored on the machine, or — the bad option — no screening at all.

*Now the original technical deep-dive — the same ideas, in precise form:*

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

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** You dropped ALL capabilities from a container. Name one dangerous thing the process can still ask the kernel to do, and explain why capabilities didn't stop it.

**A:** It can still call syscalls like `ptrace` (attach to its own child and read its memory), `keyctl`, `unshare`, `bpf`, or `userfaultfd` — the very syscalls where many kernel privilege-escalation CVEs live (Dirty COW via `madvise`, the `waitid` CVE-2017-5123, bpf verifier holes). Capabilities didn't stop it because capabilities only gate *privileged* operations: `capable()` is checked inside specific privileged code paths, and calling `ptrace` on your own child is not a privileged operation, so no capability bit is ever consulted. Dropping all caps shrinks *privilege* but leaves the full ~300-450-syscall kernel attack surface reachable; one exploitable bug behind any of those calls is a container escape. That surface reduction is seccomp's job, not capabilities'.

### Before Rung 3
**Q:** From the one sentence alone, explain why seccomp cannot make a rule like "block `open` but only for `/etc/shadow`."

**A:** The one idea says the filter's verdict is based on "the syscall number and its arguments" — meaning the six raw *register* values in `seccomp_data`, not what they point to. The filename in an `open`/`openat` call is passed as a pointer to a string in user memory, and the BPF filter must not dereference pointers: following one safely is impossible because userspace could change the string between the check and the actual syscall (a TOCTOU race). So seccomp can only filter by *which* syscall and *scalar* argument values, never by "which file" — path-based rules belong to AppArmor/SELinux.

### Before Rung 4
**Q:** (1) Does seccomp fire before or after the capability check? (2) What are the four inputs the BPF filter gets, and which one can it not follow? (3) What does `Seccomp: 0` in `/proc/PID/status` tell your auditor?

**A:** (1) **Before** — seccomp sits right at the syscall entry gate; if it returns ERRNO or KILL, the kernel short-circuits and the capability check (and any LSM hook) never runs. (2) The filter sees the fixed `seccomp_data` struct: the **syscall number** (`nr`), the **architecture** (`arch`), the **instruction pointer**, and the **six raw arguments** (`args[6]`); it cannot follow the *pointer arguments* — any argument that is a pointer (e.g. a filename string) stays opaque, only the scalar register value is visible. (3) `Seccomp: 0` means the process is Unconfined — no filter is installed — so the container is running with the full, unfiltered kernel syscall surface (~300-450 syscalls reachable). That is precisely the audit finding: the runtime default is not being enforced.

### Before Rung 5
**Q:** What is the runtime-behavior difference between `SCMP_ACT_ERRNO` and `SCMP_ACT_KILL` on a blocked `mkdir`, and which would you choose while first rolling out a new profile?

**A:** With `SCMP_ACT_ERRNO` the `mkdir` syscall fails with a chosen errno (e.g. `EPERM`): the app sees "Operation not permitted," and the process keeps running — graceful degradation. With `SCMP_ACT_KILL` the process is killed the instant it makes the call (`SIGSYS`, exit code 159 = 128+31) — a hard stop, no chance to handle it. For a first rollout you'd actually start with `SCMP_ACT_LOG` (allow but tattle) to discover what a deny would break, then move to `SCMP_ACT_ERRNO` rather than KILL, because ERRNO lets the app survive an unexpected blocked syscall and degrade gracefully instead of dying mid-request — denying blind with KILL is how you cause a 2 a.m. outage.

### Before Rung 6
**Q:** At step 7 the kernel "short-circuits." Did the capability check run? And why does an app experience a seccomp-denied `mkdir` as identical to a permissions denial?

**A:** No — the capability check never ran. "Short-circuit" means the BPF filter's `ERRNO(EPERM)` verdict at the syscall entry gate made the kernel return `-EPERM` immediately, without ever invoking the real `mkdirat` handler, the capability check, or the DAC/LSM checks that would normally follow. The app can't tell the difference because both paths surface the same way: the syscall returns `-1` with `errno = EPERM`, so libc's `mkdir()` prints "Operation not permitted" exactly as it would for an ordinary file-permission failure. The denial mechanism is invisible to userspace; only the node-side view (`Seccomp: 2` in `/proc/PID/status`) reveals a filter was responsible.

### Before Rung 7
**Q:** A teammate says "we have AppArmor denying writes to `/etc`, so we don't need seccomp." What class of attack does AppArmor leave open that RuntimeDefault seccomp would close?

**A:** Kernel-exploit attacks through syscalls that never touch a file path. AppArmor is object-oriented MAC — it gates access to files (by path), ports, and capabilities — but it does not reason in terms of syscall numbers, so a process can still *utter* `mount`, `keyctl`, `bpf`, `kexec_load`, `init_module`, `userfaultfd`, and friends. A kernel bug behind one of those (a `keyctl` or bpf-verifier CVE) is a container escape that involves no `/etc` write at all, so the AppArmor policy never fires. RuntimeDefault seccomp closes this class by keeping those ~44 dangerous syscalls off its allow-list entirely — the syscall is denied at the entry gate before any kernel handler (and any AppArmor hook) runs. The layers are complementary: LSMs gate objects, seccomp shrinks the raw syscall surface.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — several setups need `sudo` and some deliberately break things. These scenarios use **systemd's `SystemCallFilter=`** (the same libseccomp → BPF machinery Kubernetes uses, minus a cluster) plus `strace`. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Arequipa: is this service actually confined?" (Easy)
**Setup:**
```bash
sudo tee /etc/systemd/system/lab-arequipa.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Arequipa - confined sleeper
[Service]
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
ExecStart=/bin/sleep 3600
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-arequipa.service
```
**Situation:** An audit asks you to prove, from the kernel's own view rather than the unit file, whether `lab-arequipa` runs with a seccomp filter installed. `kubectl`-style YAML reading is not enough — you need the ground truth from `/proc`.

**Your task:** Read the seccomp **mode integer** of the service's main process and state whether a filter is active.

**Verify:**
```bash
PID=$(systemctl show -p MainPID --value lab-arequipa.service)
grep Seccomp /proc/$PID/status
# expected: Seccomp:  2   (filter mode = a BPF filter is installed)
```

### 🟢 Scenario 2 — "Salvador: turn the filter on" (Easy)
**Setup:**
```bash
sudo tee /etc/systemd/system/lab-salvador.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Salvador - unconfined sleeper
[Service]
ExecStart=/bin/sleep 3600
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-salvador.service
PID=$(systemctl show -p MainPID --value lab-salvador.service)
grep Seccomp /proc/$PID/status   # Seccomp:  0   (no filter — full syscall surface)
```
**Situation:** The audit finding says `lab-salvador` runs with the **full, unfiltered kernel syscall surface** (`Seccomp: 0`) — exactly the "runtime default is not enforced" problem. Your lead wants a seccomp filter enforced on it using systemd's built-in mechanism, without rewriting the app.

**Your task:** Add a system-call filter to the unit so the service's process reports **filter mode**, then reload and restart and confirm.

**Verify:**
```bash
PID=$(systemctl show -p MainPID --value lab-salvador.service)
grep Seccomp /proc/$PID/status
# expected: Seccomp:  2
```

### 🟡 Scenario 3 — "Recife: the service that dies the instant it works" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-recife
sudo tee /opt/lab-recife/run.sh >/dev/null <<'EOF'
#!/bin/bash
echo "starting"
mkdir -p /opt/lab-recife/workdir
echo "made workdir"
sleep 3600
EOF
sudo chmod +x /opt/lab-recife/run.sh
sudo tee /etc/systemd/system/lab-recife.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Recife - over-filtered service
[Service]
SystemCallFilter=@system-service
SystemCallFilter=~mkdir mkdirat
ExecStart=/opt/lab-recife/run.sh
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-recife.service 2>/dev/null || true
sleep 1
systemctl status lab-recife.service --no-pager | tail -n 6
# Main process exited, code=killed, status=31/SYS
```
**Situation:** `lab-recife` starts, logs "starting", and then instantly dies. `systemctl status` shows `status=31/SYS` — killed by `SIGSYS`. There is no stack trace and no errno in the app log: a seccomp filter is *killing* the process the moment it makes one particular syscall.

**Your task:** Determine **which** system call the filter is killing the process for, then adjust the unit so the service runs to completion (reaches "made workdir" and stays up). Keep a seccomp filter in place.

**Verify:**
```bash
systemctl is-active lab-recife.service      # expected: active
test -d /opt/lab-recife/workdir && echo OK  # expected: OK
```

### 🟡 Scenario 4 — "Manaus: crash-loop vs graceful deny" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-manaus
sudo tee /opt/lab-manaus/app.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import os, time
while True:
    try:
        os.mkdir("/opt/lab-manaus/probe")
        print("mkdir ok", flush=True)
        os.rmdir("/opt/lab-manaus/probe")
    except OSError as e:
        print("mkdir refused: %s (still running)" % e, flush=True)
    time.sleep(3)
EOF
sudo tee /etc/systemd/system/lab-manaus.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Manaus - crash loop on a blocked syscall
[Service]
Restart=always
RestartSec=1
SystemCallFilter=@system-service
SystemCallFilter=~mkdir mkdirat
ExecStart=/usr/bin/python3 /opt/lab-manaus/app.py
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-manaus.service
sleep 5
systemctl show -p NRestarts --value lab-manaus.service   # a climbing number — it is crash-looping
```
**Situation:** `lab-manaus` was *written* to tolerate a blocked `mkdir` — it catches the exception and keeps looping. But in production it's crash-looping instead: `NRestarts` keeps climbing. The seccomp action is **killing** the process (uncatchable `SIGSYS`), so the app never gets a chance to handle the error.

**Your task:** Change the seccomp configuration so a blocked `mkdir` **returns an error to the app** (which it catches) instead of killing it. The service must stop restarting, stay up, and log "mkdir refused ... still running".

**Verify:**
```bash
sudo systemctl restart lab-manaus.service
sleep 8
journalctl -u lab-manaus.service --no-pager | tail -n 3
systemctl is-active lab-manaus.service
# expected: log shows "mkdir refused ... still running"; is-active = active; NRestarts stops climbing
```

### 🟠 Scenario 5 — "Cali: build the allow-list from a trace" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-cali
sudo tee /opt/lab-cali/app.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 8089))   # network work
s.close()
with open("/opt/lab-cali/done", "w") as f:   # filesystem work
    f.write("completed\n")
print("app finished")
EOF
sudo tee /etc/systemd/system/lab-cali.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Cali - incomplete whitelist
[Service]
Type=oneshot
SystemCallFilter=@basic-io @process @signal
ExecStart=/usr/bin/python3 /opt/lab-cali/app.py
UNIT
sudo systemctl daemon-reload
sudo rm -f /opt/lab-cali/done
sudo systemctl start lab-cali.service 2>/dev/null || true
sleep 1
systemctl status lab-cali.service --no-pager | tail -n 6
test -f /opt/lab-cali/done && echo "done exists" || echo "app did NOT finish"
```
**Situation:** `lab-cali` is a batch job hardened with a **hand-picked** seccomp allow-list, but it dies before producing its output file `/opt/lab-cali/done` — killed by `SIGSYS`. The author guessed the needed syscall groups (`@basic-io @process @signal`) and guessed wrong: the job also opens a socket and writes a file.

**Your task:** Use `strace` to *discover* the system calls the app truly makes, then correct the `SystemCallFilter=` allow-list so the job completes and writes `/opt/lab-cali/done` — while keeping it a **deny-by-default whitelist** (do **not** switch to allow-all or a blacklist).

**Verify:**
```bash
sudo systemctl daemon-reload
sudo rm -f /opt/lab-cali/done
sudo systemctl restart lab-cali.service
sleep 2
test -f /opt/lab-cali/done && cat /opt/lab-cali/done
# expected: completed
```

### 🔴 Scenario 6 — "Guayaquil: keep it serving, wall off the dangerous syscalls" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-guayaquil
sudo tee /opt/lab-guayaquil/server.py >/dev/null <<'EOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok\n")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8088), H).serve_forever()
EOF
sudo tee /etc/systemd/system/lab-guayaquil.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Guayaquil - under-hardened web service
[Service]
ExecStart=/usr/bin/python3 /opt/lab-guayaquil/server.py
UNIT
sudo systemctl daemon-reload
sudo systemctl start lab-guayaquil.service
sleep 1
PID=$(systemctl show -p MainPID --value lab-guayaquil.service)
grep Seccomp /proc/$PID/status   # Seccomp:  0   (no filter at all)
curl -s http://127.0.0.1:8088/   # ok
```
**Situation:** `lab-guayaquil` serves HTTP on `127.0.0.1:8088` but runs with `Seccomp: 0` — the entire kernel syscall surface. Security requires it be confined so it can **never** reach the kernel-escape syscalls (`mount`, `ptrace`, `keyctl`, module loading, `swapon`, `reboot`), while it keeps serving traffic. You must also **prove** the dangerous calls are actually blocked, not just assert it.

**Your task:** Install a deny-by-default seccomp allow-list on the service so it stays up serving `8088` with `Seccomp: 2`, yet a dangerous syscall like `mount` is refused. Prove **both**: the service still answers on 8088 under a filter, and a probe running under the same filter is denied the dangerous call.

**Verify:**
```bash
# 1) still serving + confined:
PID=$(systemctl show -p MainPID --value lab-guayaquil.service)
grep Seccomp /proc/$PID/status              # expected: Seccomp:  2
curl -s http://127.0.0.1:8088/              # expected: ok
# 2) the dangerous call is blocked under the same policy (no real mount happens):
sudo systemd-run --wait --pipe -p SystemCallFilter=@system-service -p SystemCallErrorNumber=EPERM \
  python3 -c 'import ctypes; libc=ctypes.CDLL(None, use_errno=True); \
rc=libc.mount(b"none", b"/mnt", b"tmpfs", 0, 0); print("mount rc", rc, "errno", ctypes.get_errno())'
# expected: mount rc -1 errno 1   (EPERM — @system-service excludes the mount syscall)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Arequipa: is this service actually confined?"
**Solution:**
```bash
PID=$(systemctl show -p MainPID --value lab-arequipa.service)
grep Seccomp /proc/$PID/status
# Seccomp:  2
```
**Why this works & what it teaches:** The kernel reports each process's seccomp state as one integer in `/proc/PID/status`: `0` = disabled (Unconfined), `1` = strict mode, `2` = filter mode (a BPF filter is installed). `systemd`'s `SystemCallFilter=` compiled the `@system-service` set into BPF via libseccomp and installed it before `execve`, so the sleeper reads `Seccomp: 2`. This field is your audit oracle — it answers "is this container/process confined?" as a checkable fact independent of any config file. **Cleanup:** `sudo systemctl disable --now lab-arequipa.service; sudo rm /etc/systemd/system/lab-arequipa.service; sudo systemctl daemon-reload`.

### Scenario 2 — "Salvador: turn the filter on"
**Solution:**
```bash
# add a filter line under [Service], e.g.:
#   SystemCallFilter=@system-service
sudo sed -i '/^\[Service\]/a SystemCallFilter=@system-service' /etc/systemd/system/lab-salvador.service
sudo systemctl daemon-reload
sudo systemctl restart lab-salvador.service
PID=$(systemctl show -p MainPID --value lab-salvador.service)
grep Seccomp /proc/$PID/status   # Seccomp:  2
```
**Why this works & what it teaches:** `@system-service` is systemd's curated allow-list of the syscalls a normal service needs (a deny-by-default whitelist that excludes the ~44 dangerous ones) — the same "sane broad default" shape as Kubernetes' `RuntimeDefault`. Adding it flips the process from `Seccomp: 0` to `Seccomp: 2` with essentially zero risk to a sleeper. **Where people go wrong:** forgetting `daemon-reload` (systemd keeps the old unit) or editing the wrong copy of the unit. **Cleanup:** `sudo systemctl disable --now lab-salvador.service; sudo rm /etc/systemd/system/lab-salvador.service; sudo systemctl daemon-reload`.

### Scenario 3 — "Recife: the service that dies the instant it works"
**Solution:**
```bash
# Discover the killing syscall — either read the journal (status=31/SYS) or strace the script:
sudo strace -f -e trace=%file /opt/lab-recife/run.sh 2>&1 | grep -i mkdir
#   mkdirat(AT_FDCWD, "/opt/lab-recife/workdir", 0777)  ← the call that trips SIGSYS
# The unit subtracts mkdir/mkdirat from the allow-list; remove that deny line so they're allowed again:
sudo sed -i '/^SystemCallFilter=~mkdir mkdirat$/d' /etc/systemd/system/lab-recife.service
sudo systemctl daemon-reload
sudo systemctl restart lab-recife.service
systemctl is-active lab-recife.service          # active
test -d /opt/lab-recife/workdir && echo OK      # OK
```
**Why this works & what it teaches:** A `SystemCallFilter=` line beginning with `~` is a *subtraction* — it removes those syscalls from the allowed set. With no `SystemCallErrorNumber=` configured, systemd's default action for a filtered-out call is to **kill** the thread with `SIGSYS` (exit `31`, hence `status=31/SYS`). `strace` reveals the exact syscall (`mkdirat`); removing the `~mkdir mkdirat` subtraction restores it while `@system-service` still confines everything else. **Where people go wrong:** chasing a phantom permissions/EACCES bug — a `SIGSYS` kill with no errno is the fingerprint of seccomp, not DAC. **Cleanup:** `sudo systemctl disable --now lab-recife.service; sudo rm /etc/systemd/system/lab-recife.service; sudo rm -rf /opt/lab-recife; sudo systemctl daemon-reload`.

### Scenario 4 — "Manaus: crash-loop vs graceful deny"
**Solution:**
```bash
# Switch the seccomp action from KILL (default) to ERRNO so the app can catch the failure:
sudo sed -i '/^\[Service\]/a SystemCallErrorNumber=EPERM' /etc/systemd/system/lab-manaus.service
sudo systemctl daemon-reload
sudo systemctl restart lab-manaus.service
sleep 8
journalctl -u lab-manaus.service --no-pager | tail -n 3   # "mkdir refused: ... still running"
systemctl is-active lab-manaus.service                    # active (no more restart loop)
```
**Why this works & what it teaches:** Seccomp's verdict for a blocked syscall is configurable. `SCMP_ACT_KILL` (systemd's default when no error number is set) delivers an uncatchable `SIGSYS` — the Python `try/except` never runs, so the process dies and `Restart=always` loops it. `SystemCallErrorNumber=EPERM` maps to `SCMP_ACT_ERRNO`: the `mkdir` syscall simply returns `-EPERM`, Python raises a catchable `OSError`, and the loop survives. This is the exact ERRNO-vs-KILL trade — graceful degradation vs hard stop. **Where people go wrong:** trying to "fix" the loop with `RestartSec`/backoff instead of changing the *action* that's killing it. **Cleanup:** `sudo systemctl disable --now lab-manaus.service; sudo rm /etc/systemd/system/lab-manaus.service; sudo rm -rf /opt/lab-manaus; sudo systemctl daemon-reload`.

### Scenario 5 — "Cali: build the allow-list from a trace"
**Solution:**
```bash
# 1) Trace the app to see which syscalls it really makes:
strace -f -e trace=all -o /tmp/cali.txt /usr/bin/python3 /opt/lab-cali/app.py
awk -F'(' '/^[a-z_]+\(/{print $1}' /tmp/cali.txt | sort -u | head
#   ... socket, bind, openat, write, mmap, ...  (network + filesystem + memory)
# 2) The narrow list was missing network, file, and memory groups. The pragmatic, still
#    deny-by-default whitelist that covers a normal service is @system-service:
sudo sed -i 's/^SystemCallFilter=@basic-io @process @signal$/SystemCallFilter=@system-service/' \
  /etc/systemd/system/lab-cali.service
sudo systemctl daemon-reload
sudo rm -f /opt/lab-cali/done
sudo systemctl restart lab-cali.service
sleep 2
cat /opt/lab-cali/done   # completed
```
**Why this works & what it teaches:** This is the real profile-authoring workflow: **trace the app, collect the syscalls it uses, allow exactly those (or a superset group), deny the rest.** The app's `socket`/`bind` (network) and `openat`/`write` (filesystem) fell outside `@basic-io @process @signal`, so the deny-by-default whitelist killed it. `@system-service` is a deny-by-default set that includes network, file, and memory syscalls while still excluding the dangerous ones — the correct, low-maintenance answer. **Where people go wrong:** flipping `defaultAction` to allow-all (destroys the whole point) or hand-enumerating individual syscalls and missing one (`mmap`, `rt_sigaction`) that surfaces only under load. **Cleanup:** `sudo systemctl disable --now lab-cali.service 2>/dev/null; sudo rm /etc/systemd/system/lab-cali.service; sudo rm -rf /opt/lab-cali /tmp/cali.txt; sudo systemctl daemon-reload`.

### Scenario 6 — "Guayaquil: keep it serving, wall off the dangerous syscalls"
**Solution:**
```bash
# Add a deny-by-default whitelist + pin the architecture, then reload/restart:
sudo tee /etc/systemd/system/lab-guayaquil.service >/dev/null <<'UNIT'
[Unit]
Description=Lab Guayaquil - hardened web service
[Service]
SystemCallFilter=@system-service
SystemCallArchitectures=native
SystemCallErrorNumber=EPERM
ExecStart=/usr/bin/python3 /opt/lab-guayaquil/server.py
UNIT
sudo systemctl daemon-reload
sudo systemctl restart lab-guayaquil.service
sleep 1
PID=$(systemctl show -p MainPID --value lab-guayaquil.service)
grep Seccomp /proc/$PID/status              # Seccomp:  2
curl -s http://127.0.0.1:8088/              # ok
# prove a dangerous syscall is refused under the same policy:
sudo systemd-run --wait --pipe -p SystemCallFilter=@system-service -p SystemCallErrorNumber=EPERM \
  python3 -c 'import ctypes; libc=ctypes.CDLL(None, use_errno=True); \
print("mount rc", libc.mount(b"none", b"/mnt", b"tmpfs", 0, 0), "errno", ctypes.get_errno())'
# mount rc -1 errno 1   (EPERM)
```
**Why this works & what it teaches:** `@system-service` is a default-deny whitelist: `mount`, `swapon`, `reboot`, `init_module`/`finit_module`, `kexec_load`, `keyctl`, and `ptrace` (in most conditions) are simply **not on the allow-list**, so they're denied at the syscall entry gate before any capability or LSM check runs. The app's HTTP syscalls *are* on the list, so it keeps serving with `Seccomp: 2`. `SystemCallArchitectures=native` blocks the 32-bit-ABI end-run (a different syscall-number table an attacker could use to smuggle a blocked call). The `systemd-run` probe demonstrates the block empirically — `mount()` returns `-1/EPERM` and no filesystem is actually mounted, so proving confinement costs nothing. **Where people go wrong:** blacklisting a handful of syscalls by name (misses the ones you didn't think of) instead of using a default-deny allow-list, or forgetting `SystemCallArchitectures=native`. **Cleanup:** `sudo systemctl disable --now lab-guayaquil.service; sudo rm /etc/systemd/system/lab-guayaquil.service; sudo rm -rf /opt/lab-guayaquil; sudo systemctl daemon-reload`.
