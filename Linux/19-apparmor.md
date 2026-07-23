# AppArmor — Path-Based Mandatory Access Control

*The kernel's second opinion: even when the file permissions say "yes," AppArmor can still say "no."*

---

## 🪜 Rung 0 — The Setup

**What am I learning?** AppArmor — a Linux Security Module (LSM) that confines a program to a *whitelist* of files it may touch, networks it may open, and capabilities it may use. It is **path-based Mandatory Access Control (MAC)**: rules are written against filesystem paths like `/etc/shadow`, loaded into the kernel as a *profile*, and attached to a process. Once attached, the kernel enforces the profile on **every** syscall that program makes — regardless of who owns the process or what the file permissions say.

**Why did it land on my desk?** You're the platform engineer on call. A pod that ran fine yesterday is now `CrashLoopBackOff`. The container logs show a generic "permission denied" writing to `/var/lib/myapp`, but you check the mount — it's owned by the right UID, mode `0755`, the process runs as that user. DAC says this should work. Then someone runs `dmesg` on the node and pastes:

```
audit: type=1400 ... apparmor="DENIED" operation="open" profile="k8s-myapp" name="/var/lib/myapp/state.db" pid=48213 comm="myapp" requested_mask="wc" denied_mask="wc"
```

That single word — `apparmor="DENIED"` — is the whole mystery. The file permissions were never the problem. A **second gatekeeper**, invisible to `ls -l`, refused the write. Someone tightened the node's AppArmor profile (or the pod requested a profile that doesn't list this path), and now the kernel is vetoing an operation the classic permission model happily allows.

**What do I already know already?** You know [permissions & ownership](05-permissions-ownership.md) — the `rwx` bits, `chmod`, `chown`. You know [Linux capabilities](17-capabilities.md) (chopping root into pieces) and [seccomp](18-seccomp.md) (filtering syscalls). AppArmor is the fourth member of that "confine the process" family. Where capabilities restrict *which privileged operations* and seccomp restricts *which syscalls*, AppArmor restricts *which files and network endpoints* — by name, by path. If you've internalized "seccomp is a syscall firewall," then "AppArmor is a filesystem firewall" is the sentence to carry in.

---

## 🔥 Rung 1 — The Pain

The classic Unix permission model — **Discretionary Access Control (DAC)** — has one fatal design assumption baked into the word *discretionary*: **the owner of a resource decides who can access it.** If you own a file, you can `chmod 777` it. If a process runs as root (UID 0), DAC essentially waves it through everything — root bypasses permission checks by design.

That assumption breaks the moment you run untrusted or exploitable code:

- **Root is all-or-nothing.** A web server that gets popped and drops a shell as root can read `/etc/shadow`, write to `/boot`, load kernel modules, read every other tenant's data. DAC has no way to say "this particular nginx binary may read its config and write its logs, and *nothing else* — even as root."
- **The owner can loosen their own security.** A compromised app running as its normal user can `chmod` its own files world-writable, plant a backdoor in its own `~/.bashrc`, and DAC considers that entirely legitimate. There is no policy *above* the user that the user cannot override.
- **Blast radius is enormous.** Before MAC, "contain a service" meant chroot jails, dropping privileges, and prayer. A single path-traversal bug (`../../etc/shadow`) turned a log-reader into a credential thief, because nothing external constrained *which paths* the process could name.

**Who felt this pain most?** Multi-tenant hosts and, later, **containers**. A container is just a process in [namespaces](13-namespaces.md) and [cgroups](14-cgroups.md) — it shares the host kernel. If a containerized process escapes namespace confinement or the runtime has a bug, DAC alone won't stop root-in-the-container from becoming root-on-the-node. Kubernetes multiplies this: hundreds of pods from different teams, different trust levels, all sharing kubelet's nodes. You need a policy layer that says "regardless of UID, regardless of file mode, *this workload* may only touch *these paths*" — and that the workload itself cannot rewrite.

That layer is **Mandatory** Access Control: the policy is set by the administrator/kernel, applies system-wide, and **the confined process cannot alter it**, not even as root. AppArmor was built (originally by Immunix, later maintained by SUSE and Canonical) to deliver exactly that, with profiles simple enough to actually write — path-based, human-readable, per-program.

> **Check yourself before Rung 2:** Root can `chmod` any file and bypass DAC checks. So *why* can't a root process inside an AppArmor-confined program simply turn its own profile off to regain full access? What would have to be true about *where* the policy lives for that to be impossible?

---

## 💡 Rung 2 — The One Idea

> **AppArmor attaches a per-process whitelist of allowed paths/networks/capabilities, enforced by the kernel on every access — and the confined process cannot escape or edit its own rules.**

Memorize that sentence. Everything else is a corollary:

- **"per-process"** → the confinement is bound to a running task, visible at `/proc/PID/attr/current`. Different processes can run under different profiles simultaneously.
- **"whitelist of paths"** → rules are written against filesystem *paths* (`/usr/sbin/nginx r`), which is what makes AppArmor *path-based* MAC (contrast: SELinux labels the inode itself).
- **"enforced by the kernel on every access"** → AppArmor is an LSM; it hooks the same kernel checkpoints that DAC uses, and runs *after* DAC. Both must say yes.
- **"cannot escape or edit its own rules"** → the policy lives in kernel memory, loaded by a privileged tool from `/etc/apparmor.d/`. A confined process has no syscall to say "unconfine me." That's the *Mandatory* in MAC.
- **Two answers, not three** → for any access the kernel asks AppArmor "allow or deny?" In **enforce** mode a deny is blocked and logged; in **complain** mode it's *allowed* but logged (learning mode). That single mode switch is the entire difference between "protect me" and "tell me what I'd break."

If you can derive those five bullets from the one sentence, you understand AppArmor. The commands are just how you load, inspect, and toggle that whitelist.

> **Check yourself before Rung 3:** AppArmor runs *after* DAC and both must agree. So can an AppArmor profile *grant* access to a file that DAC already denied (wrong mode/owner)? Predict which layer wins when they disagree — and why "either can say no, neither can override the other's no" is the only safe ordering.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> Imagine an office building where every door already has an ordinary lock (the classic "do you have the right key?" permission system). This section explains a **second, stricter security desk** that questions you *after* your key already worked.
>
> - **The built-in checkpoint system.** The building was constructed with inspection stations at every sensitive spot — every filing-room door, every mailroom window, every phone line. At each station, first the normal lock is checked. Only if your key works does the station then radio the **security desk** (AppArmor) and ask: "this worker wants to open this drawer — approve?" Both must say yes; either one can refuse. Important detail: this security desk judges you by the **room's address** ("cabinet 3, hallway B"), while a rival system (SELinux) judges by a **sticker glued onto each item**. That's why, under AppArmor, renaming or moving an item changes which rules apply — the rules follow the address, not the item.
> - **The moving parts.** The security desk's rulebooks start life as plain-text documents in a filing cabinet on disk (one rulebook per program, e.g. "the web server may read its settings, write its logs, and nothing else"). Editing those papers does *nothing by itself* — a special clerk (a "parser," i.e. a compiler/loader) must read the papers, condense them into a fast lookup chart, and hand that chart to the guards' live memory. Only then are they in force. Each worker in the building wears a **badge** you can read that names which rulebook currently governs them. And because most workers need the same basics (the cafeteria, the restroom, the supply closet), rulebooks can "include" shared starter-packs instead of listing everything from scratch.
> - **The worker never knows.** When the security desk refuses something, the worker just hears the same bland "permission denied" they'd get from a failed key. No mention of the security desk at all. The *only* place the real reason is written is the building's **incident logbook** — which is why these denials feel so mysterious until you read the log.
> - **Where Kubernetes fits.** Kubernetes (the software that runs apps in sealed boxes on many machines) can assign a rulebook to each app as it starts — but it only passes along the rulebook's *name*. The rulebook itself must already have been loaded into that particular machine's guard desk, or the app simply won't start.

*Now the original technical deep-dive — the same ideas, in precise form:*

### The Linux Security Module (LSM) framework

The kernel doesn't hardcode AppArmor. Instead it exposes **LSM hooks**: hundreds of checkpoints sprinkled through the kernel at security-relevant moments — `open()`ing a file, `bind()`ing a socket, `execve()`ing a binary, using a capability. At each hook the kernel first runs its normal **DAC** check (the `rwx` bits from [permissions](05-permissions-ownership.md)). *If DAC passes*, it then calls out to whatever LSM is loaded and asks: "This task wants to do this thing — allow?" AppArmor (or SELinux) answers.

Two consequences fall straight out of this design:

1. **MAC is layered on top of DAC, never underneath.** If DAC already denied (wrong file mode), AppArmor never even gets consulted. If DAC allowed, AppArmor gets the final word. **Both must agree.** That's why your pod's file was mode `0755`, owned correctly (DAC = yes), yet the write still failed (AppArmor = no).
2. **AppArmor sees the *path*, SELinux sees the *label*.** When the kernel resolves an `open("/var/log/nginx/access.log")`, AppArmor matches that resolved pathname against the profile's file rules. SELinux instead reads a security label stored *on the inode* (the xattr `security.selinux`). This is the deepest structural difference between them — and it's why moving/renaming a file changes what AppArmor allows but not what SELinux allows.

### The moving parts

```
   PROFILE SOURCE                KERNEL                        RUNNING PROCESS
  ┌────────────────────┐                                    ┌──────────────────┐
  │ /etc/apparmor.d/   │                                    │  nginx (pid 48213)│
  │   usr.sbin.nginx   │                                    │                  │
  │                    │   apparmor_parser -r               │  attr/current =  │
  │  /usr/sbin/nginx r │──────────────┐                     │   "docker-nginx  │
  │  /var/log/**  w    │              │                     │      (enforce)"  │
  │  deny /etc/shadow r│              ▼                     └────────┬─────────┘
  │  network inet tcp  │      ┌───────────────────┐                  │
  └────────────────────┘      │  KERNEL: AppArmor │                  │ open("/etc/shadow")
                              │  LSM module       │                  │ execve(...)
   abstractions/  ───include─▶│                   │                  │ connect(...)
   tunables/                  │  loaded profiles: │◀─────────────────┘
                              │   in kernel memory│   LSM hook fires on every syscall
                              │   (apparmorfs)    │
                              └─────────┬─────────┘
                                        │ decision: ALLOW / DENY
                                        │ + audit record if denied (or if complain)
                                        ▼
                              ┌───────────────────┐
                              │ kernel audit ──▶  │  dmesg / journalctl / auditd
                              │  apparmor="DENIED"│
                              └───────────────────┘
```

Walk the pieces:

- **`/etc/apparmor.d/`** — the on-disk profile *source* directory. Files here are text. Convention: the filename is the binary path with `/` replaced by `.`, e.g. the profile for `/usr/sbin/nginx` lives in `/etc/apparmor.d/usr.sbin.nginx`. **These files are just source.** Editing them changes nothing until you *load* them.
- **`apparmor_parser`** — the compiler/loader. It reads a text profile, compiles it into the kernel's internal representation (a DFA — a deterministic finite automaton that matches paths *fast*), and pushes it into kernel memory. `apparmor_parser -r` = **r**eplace an already-loaded profile. This is the actual "apply" step.
- **The kernel AppArmor module** — holds all loaded profiles in memory. It exposes a virtual filesystem, **apparmorfs**, mounted at `/sys/kernel/security/apparmor/`, where `aa-status` reads live state (`profiles`, `.access`, etc.). This is the [`/proc` and `/sys` "everything is a file"](01-linux-philosophy.md) idea again: kernel state surfaced as files.
- **`/proc/PID/attr/current`** — per-process, the name of the profile currently confining that task, plus its mode. `cat`ing it tells you *what is guarding this process right now*. For a container you'll see something like `docker-nginx (enforce)` or `cri-containerd.apparmor.d (enforce)` or your custom `k8s-nginx (enforce)`.
- **abstractions & tunables** — reusable include files under `/etc/apparmor.d/abstractions/` and `/etc/apparmor.d/tunables/`. An *abstraction* is a bundle of common rules (`#include <abstractions/base>` pulls in the ~50 paths *every* program needs: shared libs, `/dev/null`, locale data). A *tunable* is a variable (e.g. `@{HOME}` expands to the home-dir glob) so profiles stay portable. Without these, every profile would be thousands of lines.

### What the app never sees

The confined process has **no idea it's confined**. It calls `open()`, gets back `-1 EACCES` (permission denied), exactly the same errno DAC would return. There is no "AppArmor denied you" error surfaced to the program — that's *deliberate*, so you can confine software that has no awareness of AppArmor. The *only* place the AppArmor-specific reason appears is the **kernel audit log** (the `apparmor="DENIED"` line). This is why debugging feels mysterious: the app says "permission denied," `ls -l` says "you have permission," and the truth is only in `dmesg`/`journalctl`.

### Where Kubernetes fits

On a Kubernetes node, **containerd/CRI-O launch each container as a normal Linux process** inside namespaces and cgroups. The runtime can attach an AppArmor profile to that process at exec time — it's just another attribute set alongside the seccomp profile, the cgroup path (`kubepods/...`), and the capability set. The kubelet passes the requested profile name down through the CRI to the runtime; the runtime, when it `execve`s your entrypoint, transitions the new process into that AppArmor profile. From that instant, `/proc/1/attr/current` inside the container shows the profile, and every file the container touches is filtered by the kernel against it. **Crucial gotcha:** the profile must already be *loaded into the kernel of that specific node* (`apparmor_parser -r` on each node, or via a DaemonSet/the Security Profiles Operator). Kubernetes does **not** ship the profile for you — it only references it by name. Reference a profile that isn't loaded on the node the pod lands on, and the pod fails to start.

> **Check yourself before Rung 4:** You edit `/etc/apparmor.d/usr.sbin.nginx`, save the file, and nginx behaves exactly as before. Which single step did you skip, which binary actually performs it, and where does the change take effect — on disk or in kernel memory?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **DAC** (Discretionary Access Control) | The classic `rwx`/owner permission model; owner decides, root bypasses | Runs *first* at every LSM hook, before AppArmor |
| **MAC** (Mandatory Access Control) | Admin/kernel-set policy the process can't override | The category AppArmor and SELinux belong to |
| **LSM** (Linux Security Module) | Kernel framework of security hooks | Where AppArmor plugs in; runs after DAC |
| **AppArmor** | Path-based MAC LSM (Ubuntu/Debian/SUSE default) | Matches resolved pathnames against profile rules |
| **Profile** | A named whitelist of file/network/capability rules for one program | Text in `/etc/apparmor.d/`, compiled into kernel |
| **Enforce mode** | Deny is blocked *and* logged | A per-profile flag in kernel memory |
| **Complain mode** | Deny is *allowed* but logged (learning) | Same flag, opposite behavior |
| **`apparmor_parser`** | The compiler that loads/replaces profiles | Text profile → kernel DFA |
| **DFA** | Compiled state machine that matches paths fast | The in-kernel form of your rules |
| **apparmorfs** | Virtual FS at `/sys/kernel/security/apparmor/` | Live profile state; what `aa-status` reads |
| **`/proc/PID/attr/current`** | Per-process file naming its active profile + mode | The attach point on a running task |
| **Abstraction** | Reusable `#include` bundle of common rules | Pulled into profiles at compile time |
| **Tunable** | A profile variable like `@{HOME}` | Expanded by the parser at compile time |
| **Access mode letters** (`r w ix Px ...`) | Per-rule permissions: read, write, exec-inherit, exec-transition | The grammar of file rules |
| **`aa-status`** | Reports loaded profiles + confined processes | Reads apparmorfs |
| **`aa-enforce` / `aa-complain`** | Flip one profile's mode | Rewrites the flag + reloads via parser |
| **`aa-genprof` / `aa-logprof`** | Interactive profile generators | Watch audit log, propose rules |

**Same kind of thing, different names — group them:**

- **The policy category:** *MAC* is the umbrella; *AppArmor* and *SELinux* are two implementations of it. Don't confuse the concept with the tool.
- **The two modes are one flag:** *enforce* and *complain* aren't two mechanisms — they're one boolean per profile. "Learning mode," "complain," "audit-only" all mean the same thing.
- **Load-the-profile trio:** `apparmor_parser -r` (the low-level truth), `aa-enforce`/`aa-complain` (convenience wrappers that ultimately call the parser), and `systemctl reload apparmor` (bulk-loads everything in `/etc/apparmor.d/`) all do the same underlying act: push text into the kernel.
- **"What's confining me?" trio:** `aa-status`, `cat /proc/PID/attr/current`, and reading apparmorfs directly are three windows onto the *same* kernel state.
- **The two audit sinks:** `dmesg` and `journalctl` (and `auditd`'s `/var/log/audit/audit.log` where present) are three faucets on the *same* kernel audit stream.

> **Check yourself before Rung 5:** If `aa-complain` and `aa-enforce` both ultimately call `apparmor_parser`, what is the *one* thing that actually differs in the kernel after each runs — and why does that single difference change whether a denied `open()` returns an error?

---

## 🔬 Rung 5 — The Trace

**One concrete action:** an nginx process, confined by profile `k8s-nginx` in enforce mode, tries to read `/etc/shadow` (a path the profile never whitelists). Follow it hop by hop.

1. **App makes a syscall.** nginx (PID 48213 on the node, PID 1 inside the container) calls `open("/etc/shadow", O_RDONLY)`. It has no idea AppArmor exists.
2. **Kernel resolves the path.** The VFS layer walks the pathname to an inode. Before returning a file descriptor, the kernel reaches the LSM hook `security_file_open`.
3. **DAC check runs first.** Normal permission check: is the process allowed by `rwx`/owner? nginx here runs as root inside the container, so **DAC says yes** — root bypasses. (This is exactly why DAC alone is insufficient.)
4. **AppArmor hook fires.** The kernel calls AppArmor's hook implementation, passing the task's current profile (`k8s-nginx`) and the resolved path (`/etc/shadow`) with requested mask `r`.
5. **DFA match.** AppArmor runs the path through the compiled state machine for `k8s-nginx`. It finds **no allow rule** matching `/etc/shadow` — the path was never whitelisted. Default-deny → **DENY**. (This matters: because it's a *default* deny, not an explicit `deny` rule, complain mode can later flip it to ALLOW. Explicit `deny` rules stay blocked even in complain mode.)
6. **Decision applied (enforce mode).** Because the profile is in *enforce* mode, the kernel makes `open()` return `-1` with `errno = EACCES`. nginx sees a plain "Permission denied."
7. **Audit record emitted.** AppArmor writes an audit event: `apparmor="DENIED" operation="open" profile="k8s-nginx" name="/etc/shadow" requested_mask="r" denied_mask="r" pid=48213 comm="nginx"`. This flows into the kernel audit buffer → visible in `dmesg`, `journalctl`, and auditd.
8. **You debug it.** On the node you grep the audit stream, see the `DENIED`, and now *know* it was AppArmor — not a file mode, not a missing capability.

*(Had the profile been in **complain** mode, step 6 flips: `open()` **succeeds**, nginx reads the file, but step 7 still fires — you'd get the same audit line tagged `apparmor="ALLOWED"`. That's how you discover what a profile *would* block before you enforce it.)*

```
 nginx (in pod)                 KERNEL                                  YOU (on node)
      │                                                                     
      │ open("/etc/shadow","r")                                            
      ├──────────────▶ [ VFS resolves path → inode ]                       
      │                        │                                            
      │                        ▼                                            
      │                 [ LSM hook: security_file_open ]                    
      │                        │                                            
      │                 ┌──────┴───────┐                                    
      │                 │ 1. DAC check │  root ⇒ ALLOW  (not the gate here) 
      │                 └──────┬───────┘                                    
      │                        ▼                                            
      │                 ┌──────────────┐   profile=k8s-nginx                
      │                 │ 2. AppArmor  │   /etc/shadow: not whitelisted     
      │                 │    DFA match │───────────────▶ DENY               
      │                 └──────┬───────┘                                    
      │   errno=EACCES         │                                            
      │◀───────────────────────┤  (enforce ⇒ block)                        
      │  "Permission denied"   │                                            
      │                        └── audit: apparmor="DENIED" ──▶ dmesg/journalctl
      │                                                          │          
      │                                              grep apparmor ◀────────┘
```

> **Check yourself before Rung 6:** Re-run the trace with the profile in **complain** mode instead of enforce. Which numbered step changes its outcome, does nginx still get its file descriptor, and does the step-7 audit line still fire — if so, what tag does it carry now?

---

## ⚖️ Rung 6 — The Contrast

**The alternative: SELinux** — the RHEL/CentOS/Fedora default MAC. Same *goal* (kernel-enforced mandatory confinement, an LSM after DAC), radically different *mechanism*.

- **AppArmor is path-based.** Rules name paths (`/var/log/nginx/** w`). Simple to read and write. But: rename or bind-mount a file and the rule that matched by path may no longer apply — the policy follows the *name*, not the object.
- **SELinux is label-based (type enforcement).** Every file, process, and port carries a *security context* label (e.g. `system_u:object_r:httpd_log_t:s0`) stored in the inode's extended attributes. Rules are written between *types* ("httpd_t may write httpd_log_t"), not paths. Move the file, the label moves with it — but you must *label* every object, and policy is far more complex (`audit2allow`, booleans, `semanage`). See [SELinux](20-selinux.md).

| | **AppArmor** | **SELinux** |
|---|---|---|
| Policy anchored to | Filesystem **path** | Inode **label** (context) |
| Default on | Ubuntu, Debian, SUSE | RHEL, CentOS, Fedora |
| Learning curve | Gentle; human-readable profiles | Steep; contexts + type rules |
| Profile per | Program (binary path) | Domain/type (many objects) |
| Survives file rename | No (path changed) | Yes (label travels with inode) |
| Modes | enforce / complain | enforcing / permissive (system-wide + per-domain) |
| K8s field | Same `appArmorProfile` API | `securityContext.seLinuxOptions` |
| Tooling | `aa-status`, `aa-genprof`, `apparmor_parser` | `sestatus`, `semanage`, `audit2allow`, `chcon` |

**What each does that the other struggles with:** AppArmor lets you confine a single binary in ten readable lines — great for "just lock down this one service." SELinux enforces a coherent *system-wide* type model where object identity survives moves — stronger against certain evasion, but it's an all-in commitment.

**When would I NOT need AppArmor?** If your nodes run RHEL/Flatcar with SELinux (don't run both enforcing on the same objects — pick one per node). If your threat model is fully covered by [seccomp](18-seccomp.md) + [capabilities](17-capabilities.md) + read-only root filesystem and you don't need path-level file confinement. Or in a hardened distroless setup where the attack surface is already minimal — AppArmor is defense-in-depth, not a substitute for the others.

**Why this over that:** on Ubuntu/Debian nodes, AppArmor is *already there and enabled* — you get MAC with human-readable, per-program profiles for the cost of loading a file, which is the lowest-friction way to shrink a container's filesystem blast radius.

> **Check yourself before Rung 7:** A teammate `mv`s a log file that an AppArmor rule protected into a new directory not covered by any rule. Does the confinement still apply? Now answer the same for SELinux. Which underlying design fact forces each answer?

---

## 🧪 Rung 7 — The Prediction Test

Commit to each prediction **before** running the command. Assumptions: Ubuntu 22.04, systemd, AppArmor enabled (`apparmor` package + `apparmor-utils` for the `aa-*` helpers: `sudo apt install apparmor-utils`). Run node/host commands with `sudo`. Distro note: on RHEL you'd be in [SELinux](20-selinux.md) land instead; these tools won't be present.

### Example 1 — Normal case: see what's confined right now

**Prediction:** `aa-status` will report a number of *loaded* profiles, split into enforce vs complain, plus a list of *processes* currently confined. Most system daemons (like the snap-confined ones, `man`, `tcpdump`) will show up. I predict my running shell is **unconfined** (no profile attached), so `cat /proc/self/attr/current` prints `unconfined`. **BECAUSE** a profile only confines a process if one was attached at exec — my interactive shell wasn't launched under any profile.

```bash
sudo aa-status
# apparmor module is loaded.
# 42 profiles are loaded.
# 39 profiles are in enforce mode.
#    /usr/sbin/tcpdump
#    /usr/bin/man
#    ...
# 3 profiles are in complain mode.
# 8 processes have profiles defined.
# 8 processes are in enforce mode.
#    /usr/sbin/tcpdump (48213) 

cat /proc/self/attr/current
# unconfined
```

**Verify:** The counts in `aa-status` = profiles living in kernel memory (loaded), *not* files in `/etc/apparmor.d/` (there are usually more files than loaded profiles). If `/proc/self/attr/current` printed a profile name instead of `unconfined`, that would teach you your shell *was* launched under confinement (e.g. inside a snap or a confined container) — worth knowing before you get surprised by a denial.

### Example 2 — Edge/failure case: write a profile, watch enforce vs complain flip the outcome

**Prediction:** I'll confine a tiny script that reads two files. In **complain** mode both reads succeed but the un-whitelisted one gets logged as `ALLOWED`. After `aa-enforce`, that same read returns "Permission denied" and logs `DENIED` — **BECAUSE** the only thing that changed is the profile's mode flag: a *non-whitelisted* (default-denied) access is merely *logged* in complain mode but *blocked* in enforce mode. (I deliberately leave `/etc/shadow` off the whitelist rather than writing an explicit `deny` rule — an explicit `deny` stays blocked even in complain mode, which would hide the very difference I'm trying to show.)

First, the profile. Save as `/etc/apparmor.d/myapp`:

```bash
# /etc/apparmor.d/myapp
abi <abi/3.0>,
include <tunables/global>

profile myapp /usr/local/bin/myapp {
  include <abstractions/base>
  include <abstractions/bash>   # the interpreter runs under this same profile

  /usr/local/bin/myapp r,       # may read its own script
  /etc/myapp/**       r,         # may read its config tree
  /var/log/myapp/**   w,         # may write its logs
  # /etc/shadow is simply NOT listed -> default-denied (and logged when hit)

  network inet tcp,              # may open IPv4 TCP sockets
}
```

Set it up and load it in complain mode:

```bash
# tiny stand-in binary the profile names
sudo tee /usr/local/bin/myapp >/dev/null <<'EOF'
#!/bin/bash
# read files with bash's own redirection -- no child processes to confine
echo "config: $(< /etc/myapp/config)"
if { : < /etc/shadow ; } 2>/dev/null; then echo "READ shadow OK"; else echo "shadow DENIED"; fi
EOF
sudo chmod +x /usr/local/bin/myapp
sudo mkdir -p /etc/myapp && echo "hello=1" | sudo tee /etc/myapp/config >/dev/null

# compile + load the profile (-r replace, -W write cache). This is the real "apply".
sudo apparmor_parser -r -W /etc/apparmor.d/myapp

# start in complain (learning) mode
sudo aa-complain /usr/local/bin/myapp
# Setting /usr/local/bin/myapp to complain mode.

sudo /usr/local/bin/myapp
# config: hello=1
# READ shadow OK        <-- complain mode ALLOWS, but still logs it

# now enforce and repeat
sudo aa-enforce /usr/local/bin/myapp
# Setting /usr/local/bin/myapp to enforce mode.

sudo /usr/local/bin/myapp
# config: hello=1
# shadow DENIED         <-- enforce mode BLOCKS the un-whitelisted read
```

Confirm the mode flip and read the audit trail:

```bash
sudo aa-status | grep myapp
#    /usr/local/bin/myapp

# the denial, straight from the kernel audit stream:
sudo dmesg | grep "apparmor.*DENIED"
# audit: type=1400 ... apparmor="DENIED" operation="open" profile="myapp" name="/etc/shadow" pid=... comm="myapp" requested_mask="r" denied_mask="r"

# same events via journald (follow live in another terminal while you run myapp):
sudo journalctl -f | grep apparmor
# ... apparmor="DENIED" ... name="/etc/shadow" ...
```

**Verify:** The *only* change between the two runs was `aa-complain` → `aa-enforce`, yet the shadow read went from succeeding to failing. That's the one-flag insight from Rung 4 made physical. If enforce mode had *still* let the shadow read through, that would teach you the profile wasn't actually loaded/attached — re-run `apparmor_parser -r` and check `aa-status`. (Complain mode is exactly how you'd safely discover every path a new app needs before locking it down — see `aa-logprof` below, which reads these same audit lines and proposes rules.)

### Example 3 — Kubernetes-flavored case: confine a pod's container, then prove it from inside

**Prediction:** After loading a custom profile `k8s-nginx` on the node and asking Kubernetes to attach it to the nginx container, `/proc/1/attr/current` *inside* the pod will read `k8s-nginx (enforce)` — **BECAUSE** the CRI runtime transitions the container's init process into that profile at exec, and PID 1 in the pod's PID namespace is that process. And a write the profile forbids will surface as `apparmor="DENIED"` in the node's audit log, not as any Kubernetes-level error.

Step 1 — **load the profile on the node** (must be done on *every* node the pod could schedule to; in production use a DaemonSet or the Security Profiles Operator):

```bash
# /etc/apparmor.d/k8s-nginx  (on the node)
sudo tee /etc/apparmor.d/k8s-nginx >/dev/null <<'EOF'
abi <abi/3.0>,
include <tunables/global>

profile k8s-nginx flags=(attach_disconnected) {
  include <abstractions/base>

  /usr/sbin/nginx     r,
  /var/log/nginx/**   w,      # the ONLY writable path; everything else default-denied
  audit deny /etc/shadow r,   # explicit + audited deny of the classic target

  network inet tcp,
}
# NOTE: a whitelist needs no "deny /** w" catch-all -- anything not allowed is
# already denied (and logged) by default. And beware: an explicit `deny` in
# AppArmor OVERRIDES any allow rule for the same path, so "deny /** w" would
# have silently killed the /var/log/nginx writes above. Deny always wins.
EOF
sudo apparmor_parser -r -W /etc/apparmor.d/k8s-nginx
sudo aa-status | grep k8s-nginx   # confirm it's loaded on THIS node
```

Step 2 — **reference it from the pod.** Modern Kubernetes (1.30+) has a first-class field; older clusters use the annotation. Both shown:

```yaml
# modern API (K8s >= 1.30): securityContext.appArmorProfile
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx
    securityContext:
      appArmorProfile:
        type: Localhost           # use a profile loaded on the node
        localhostProfile: k8s-nginx
```

```yaml
# older API (deprecated in 1.30, still honored for backward compat): the annotation
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  annotations:
    container.apparmor.security.beta.kubernetes.io/nginx: localhost/k8s-nginx
spec:
  containers:
  - name: nginx
    image: nginx
```

Step 3 — **prove the confinement from inside the container**, then trip a denial:

```bash
kubectl apply -f nginx.yaml
kubectl exec nginx -- cat /proc/1/attr/current
# k8s-nginx (enforce)        <-- the runtime attached your profile to PID 1

# try something the profile forbids (write outside /var/log/nginx):
kubectl exec nginx -- sh -c 'echo x > /etc/test.txt'
# sh: can't create /etc/test.txt: Permission denied

# the real reason is only on the NODE's audit log, not in kubectl:
# (ssh to the node, or use a node-shell/nsenter)
sudo journalctl -f | grep apparmor
# ... apparmor="DENIED" operation="mknod" profile="k8s-nginx" name="/etc/test.txt" comm="sh" ...
```

**Verify:** `cat /proc/1/attr/current` returning `k8s-nginx (enforce)` is your ground truth that Kubernetes → CRI → runtime successfully attached the profile. If instead the **pod won't start** with an event like `Cannot enforce AppArmor: profile "k8s-nginx" is not loaded`, that's the #1 real-world failure: the profile isn't loaded *on the node this pod landed on*. Fix = run `apparmor_parser -r` on that node (or roll it out via DaemonSet), because Kubernetes references profiles by name but never ships them. If `/proc/1/attr/current` says `unconfined`, the attach silently didn't happen — check the field/annotation spelling and that the container name matches (`nginx`).

---

## 🏔 Rung 8 — Capstone: Compress It

**One sentence (no notes):** AppArmor is a kernel-enforced, path-based mandatory whitelist attached per-process that says exactly which files, networks, and capabilities a program may use — and the program can't turn it off.

**Three-sentence beginner explanation:** Normal Linux permissions (DAC) let the file owner and root do almost anything, which makes a compromised service dangerous. AppArmor adds a second gate *after* the permission check: the admin loads a profile listing the only paths and networks a specific program is allowed to touch, and the kernel blocks everything else — even for root — logging blocked attempts as `apparmor="DENIED"`. In Kubernetes you load the profile on each node and point a pod at it (via `securityContext.appArmorProfile` or the older annotation) to shrink what a container can reach if it's exploited.

**Sub-capabilities → the one idea** (*"per-process kernel-enforced whitelist you can't escape"*):

| Sub-capability | How it derives from the one idea |
|---|---|
| enforce vs complain | The whitelist can *block* (enforce) or merely *watch* (complain) — one flag |
| file rules `r/w/ix` | The whitelist's grammar for "which paths, what access" |
| `deny` rules | Explicit holes punched in an otherwise-allowed set |
| `/proc/PID/attr/current` | Where you read *which* whitelist guards a live process |
| `apparmor_parser -r` | How the text whitelist becomes the in-kernel one |
| abstractions/tunables | Reusable pieces so whitelists stay short and portable |
| dmesg/journalctl DENIED | The audit trail the whitelist emits when it says no |
| K8s `appArmorProfile` | Attaching the whitelist to a container at exec, per node |

**Which rung to revisit hands-on:** **Rung 7, Example 2.** Flipping one real profile between complain and enforce and watching the *same* `open()` change from success to `EACCES` — while the audit line stays constant — is the muscle memory that makes the whole model click. Do it once on a throwaway VM and AppArmor stops being mysterious.

---

## Related concepts

- [permissions-ownership](05-permissions-ownership.md) — the DAC layer AppArmor sits on top of
- [capabilities](17-capabilities.md) — confining *which privileged operations*, a sibling primitive
- [seccomp](18-seccomp.md) — confining *which syscalls*, the other half of container hardening
- [selinux](20-selinux.md) — the label-based MAC alternative on RHEL/Fedora
- [namespaces](13-namespaces.md) — the isolation AppArmor complements for containers
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — where MAC fits in the full node-security picture

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Root can `chmod` any file and bypass DAC. Why can't a root process inside an AppArmor-confined program simply turn its own profile off? What must be true about where the policy lives?

**A:** Because the policy is *Mandatory*, not discretionary: it is set by the administrator and enforced by the kernel, and the confined process — root or not — has no syscall that means "unconfine me." For that to be impossible, the policy must live *outside* the process's reach: profiles are loaded from `/etc/apparmor.d/` into **kernel memory** by a privileged tool (`apparmor_parser`), and the kernel checks them at LSM hooks on every access. DAC's weakness is that the owner controls the policy on their own resources; MAC fixes this by putting the policy above the user, in the kernel, where the confined task cannot alter or escape it.

### Before Rung 3
**Q:** AppArmor runs after DAC and both must agree. Can an AppArmor profile grant access to a file that DAC already denied? Which layer wins when they disagree?

**A:** No. MAC is layered *on top of* DAC, never underneath: at each LSM hook the kernel runs the DAC check first, and if DAC denies (wrong mode/owner), AppArmor is never even consulted — there is nothing for the profile to "grant." If DAC allows, AppArmor gets the final word and can still deny. So both must say yes; either can say no, and neither can override the other's no. That's the only safe ordering, because a security *module* should only ever be able to remove access, never add it — otherwise loading an LSM could weaken the base permission model instead of strictly tightening it.

### Before Rung 4
**Q:** You edit `/etc/apparmor.d/usr.sbin.nginx`, save, and nginx behaves exactly as before. Which step did you skip, which binary performs it, and where does the change take effect?

**A:** You skipped the *load* step. Files in `/etc/apparmor.d/` are just on-disk **source**; the kernel enforces the compiled copy held in kernel memory (visible via apparmorfs at `/sys/kernel/security/apparmor/`). The binary that performs the apply is **`apparmor_parser`** — `sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.nginx` compiles the text into a DFA and replaces the loaded profile. The change takes effect **in kernel memory**, not on disk: until the parser runs, the kernel keeps enforcing the old version regardless of what the file says.

### Before Rung 5
**Q:** If `aa-complain` and `aa-enforce` both ultimately call `apparmor_parser`, what one thing actually differs in the kernel after each — and why does that change whether a denied `open()` returns an error?

**A:** The only difference is the profile's **mode flag** — a single boolean per profile in kernel memory. The whitelist, the DFA, the rules are identical; the flag just tells the kernel what to *do* with a deny verdict. In **enforce** mode a denied access is blocked: the syscall returns `-1` with `errno = EACCES` and an `apparmor="DENIED"` audit line fires. In **complain** mode the very same denied access is *allowed through* but still logged (tagged `ALLOWED`) — learning mode. So the DFA match result never changes; the mode flag decides whether that result is applied to the syscall's return value or merely reported.

### Before Rung 6
**Q:** Re-run the trace with the profile in complain mode. Which step changes its outcome, does nginx get its file descriptor, and does the step-7 audit line still fire — with what tag?

**A:** Only **step 6** changes: instead of the kernel making `open()` return `-1 EACCES`, the call **succeeds** — nginx gets its file descriptor and reads `/etc/shadow`. Steps 1–5 are identical: the DFA still matches, still finds no allow rule, and still reaches the DENY verdict; complain mode just doesn't apply it. Step 7 still fires — the audit record is emitted exactly as before, but tagged `apparmor="ALLOWED"` instead of `apparmor="DENIED"`. That's precisely how complain mode works as learning mode: you see everything the profile *would* block before you enforce it. (Note this works because `/etc/shadow` was default-denied, not hit by an explicit `deny` rule — explicit denies stay blocked even in complain mode.)

### Before Rung 7
**Q:** A teammate `mv`s a log file that an AppArmor rule protected into a new directory not covered by any rule. Does the confinement still apply? Same question for SELinux. Which design fact forces each answer?

**A:** For AppArmor: no — the confinement no longer applies to that file. AppArmor is **path-based**: the DFA matches the resolved *pathname* at access time, so the policy follows the name, not the object; once the file lives at a path no rule covers, the old rule simply never matches (the access is then governed by whatever the profile says about the new path — often default-deny for a confined process, but the original protection rule is gone). For SELinux: yes — confinement still applies. SELinux is **label-based**: the security context is stored in the inode's extended attribute (`security.selinux`), and `mv` preserves the inode, so the label — and every type-enforcement rule written against it — travels with the file. The forcing facts: AppArmor anchors policy to the filesystem path; SELinux anchors it to the inode's label.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — AppArmor ships enabled there. Install the helpers once: `sudo apt-get install -y apparmor-utils`. Several setups need `sudo` and some deliberately break things. For each scenario: run the **Setup**, read the **Situation**, accomplish the **Task**, and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "La Paz: what is confining this process?" (Easy)
**Setup:**
```bash
sudo apt-get install -y apparmor-utils >/dev/null 2>&1 || true
sudo mkdir -p /opt/lab-lapaz
sudo tee /opt/lab-lapaz/app.sh >/dev/null <<'EOF'
#!/bin/bash
while true; do sleep 5; done
EOF
sudo chmod +x /opt/lab-lapaz/app.sh
sudo tee /etc/apparmor.d/lab-lapaz >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-lapaz /opt/lab-lapaz/app.sh {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-lapaz/app.sh r,
  /usr/bin/bash ix,
  /usr/bin/sleep ix,
}
PROF
sudo apparmor_parser -r /etc/apparmor.d/lab-lapaz
sudo aa-exec -p lab-lapaz -- /opt/lab-lapaz/app.sh &
sleep 1
```
**Situation:** A background process is running and you're told it's under AppArmor confinement — but not *which* profile, nor in which mode. Before you touch anything you need to identify the guard.

**Your task:** Determine the profile **name** and **mode** currently confining the running `app.sh` process.

**Verify:**
```bash
PID=$(pgrep -f /opt/lab-lapaz/app.sh | head -n1)
cat /proc/$PID/attr/current
# expected: lab-lapaz (enforce)
```

### 🟢 Scenario 2 — "Asuncion: the profile that isn't loaded" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-asuncion
sudo tee /opt/lab-asuncion/app.sh >/dev/null <<'EOF'
#!/bin/bash
echo hi
EOF
sudo chmod +x /opt/lab-asuncion/app.sh
sudo tee /etc/apparmor.d/lab-asuncion >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-asuncion /opt/lab-asuncion/app.sh {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-asuncion/app.sh r,
  /usr/bin/bash ix,
}
PROF
# NOTE: the file is on disk but was NEVER loaded into the kernel:
sudo aa-status | grep -c lab-asuncion   # 0
```
**Situation:** A colleague wrote an AppArmor profile and dropped it in `/etc/apparmor.d/` yesterday, but `aa-status` doesn't list it and the app still runs unconfined. "The file is right there," they insist. Editing a profile source file changes nothing on its own.

**Your task:** Load the profile into the kernel so it becomes active in **enforce** mode, using the tool that compiles profile source into the in-kernel form.

**Verify:**
```bash
sudo aa-status | grep lab-asuncion
# expected: lab-asuncion appears in the loaded/enforce list
```

### 🟡 Scenario 3 — "Punta Arenas: permission denied but ls says yes" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-punta /var/log/lab-punta /etc/lab-punta
echo "cfg=1" | sudo tee /etc/lab-punta/config >/dev/null
sudo tee /opt/lab-punta/app.sh >/dev/null <<'EOF'
#!/bin/bash
cat /etc/lab-punta/config >/dev/null
echo "$(date) run" >> /var/log/lab-punta/out.log
echo "wrote log"
EOF
sudo chmod +x /opt/lab-punta/app.sh
sudo chmod 0777 /var/log/lab-punta
sudo tee /etc/apparmor.d/lab-punta >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-punta /opt/lab-punta/app.sh {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-punta/app.sh r,
  /usr/bin/bash ix,
  /usr/bin/cat ix,
  /usr/bin/date ix,
  /etc/lab-punta/** r,
}
PROF
sudo apparmor_parser -r /etc/apparmor.d/lab-punta
sudo aa-exec -p lab-punta -- /opt/lab-punta/app.sh
# app.sh: line 3: /var/log/lab-punta/out.log: Permission denied
ls -ld /var/log/lab-punta   # drwxrwxrwx  (DAC says anyone may write here)
```
**Situation:** The app reads its config fine but fails to write `/var/log/lab-punta/out.log` with "Permission denied" — yet `ls -ld` shows the directory is mode `0777`, world-writable. DAC clearly permits the write. A second, invisible gatekeeper is vetoing it, and it isn't in `ls -l`.

**Your task:** Find the AppArmor denial in the kernel audit log, identify the exact path being blocked, add the minimal rule to permit the log write, reload the profile, and confirm the app writes its log.

**Verify:**
```bash
sudo aa-exec -p lab-punta -- /opt/lab-punta/app.sh && tail -n1 /var/log/lab-punta/out.log
# expected: "wrote log" printed, and a dated line present in out.log
```

### 🟡 Scenario 4 — "Mendoza: complain mode was masking a missing rule" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-mendoza /var/lib/lab-mendoza /etc/lab-mendoza
echo "cfg" | sudo tee /etc/lab-mendoza/config >/dev/null
sudo tee /opt/lab-mendoza/app.sh >/dev/null <<'EOF'
#!/bin/bash
cat /etc/lab-mendoza/config >/dev/null
echo "state $(date +%s)" > /var/lib/lab-mendoza/state
echo "ok"
EOF
sudo chmod +x /opt/lab-mendoza/app.sh
sudo tee /etc/apparmor.d/lab-mendoza >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-mendoza /opt/lab-mendoza/app.sh {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-mendoza/app.sh r,
  /usr/bin/bash ix,
  /usr/bin/cat ix,
  /usr/bin/date ix,
  /etc/lab-mendoza/** r,
}
PROF
sudo apparmor_parser -r /etc/apparmor.d/lab-mendoza
sudo aa-complain /opt/lab-mendoza/app.sh
sudo aa-exec -p lab-mendoza -- /opt/lab-mendoza/app.sh   # "ok" — works, because complain mode allows+logs
```
**Situation:** `lab-mendoza` is in **complain** (learning) mode and appears to work perfectly — it writes `/var/lib/lab-mendoza/state` and prints "ok". But the audit log is full of `ALLOWED` violations for the state file, which means the instant you flip it to enforce it will break. You need to ship it enforcing **without** breaking it.

**Your task:** Switch the profile to enforce, confirm it now breaks on the state write, add the missing rule, reload, and end with the profile in **enforce** mode while the app still succeeds.

**Verify:**
```bash
sudo aa-status | sed -n '/enforce mode/,/complain mode/p' | grep -q lab-mendoza && echo "ENFORCE"
sudo aa-exec -p lab-mendoza -- /opt/lab-mendoza/app.sh && cat /var/lib/lab-mendoza/state
# expected: ENFORCE printed, "ok" printed, and a "state ..." line present
```

### 🟠 Scenario 5 — "Iquitos: the allow rule that never wins" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-iquitos/data
sudo tee /opt/lab-iquitos/app.sh >/dev/null <<'EOF'
#!/bin/bash
echo "public $(date +%s)" > /opt/lab-iquitos/data/public.log && echo "public OK"
echo "secret $(date +%s)" > /opt/lab-iquitos/data/secret.log && echo "secret OK"
EOF
sudo chmod +x /opt/lab-iquitos/app.sh
sudo tee /etc/apparmor.d/lab-iquitos >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-iquitos /opt/lab-iquitos/app.sh {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-iquitos/app.sh r,
  /usr/bin/bash ix,
  /usr/bin/date ix,
  /opt/lab-iquitos/data/** w,
  deny /opt/lab-iquitos/data/secret.log w,
}
PROF
sudo apparmor_parser -r /etc/apparmor.d/lab-iquitos
sudo aa-exec -p lab-iquitos -- /opt/lab-iquitos/app.sh
# public OK
# app.sh: line 3: /opt/lab-iquitos/data/secret.log: Permission denied
```
**Situation:** `lab-iquitos` writes two files into the *same* directory. `public.log` succeeds but `secret.log` fails with "Permission denied" — even though the profile has an obvious `/opt/lab-iquitos/data/** w,` allow rule that plainly covers `secret.log`. The developer keeps re-reading the allow line, baffled that a broad allow doesn't apply.

**Your task:** Explain why the broad allow rule doesn't grant the `secret.log` write, fix the profile so **both** writes succeed, and reload. (Hint: in AppArmor, one kind of rule always beats an allow.)

**Verify:**
```bash
sudo aa-exec -p lab-iquitos -- /opt/lab-iquitos/app.sh && cat /opt/lab-iquitos/data/secret.log
# expected: "public OK" and "secret OK" printed, and secret.log contains a line
```

### 🔴 Scenario 6 — "Barranquilla: confine it from scratch, prove it, and block shadow" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-barranquilla /var/log/lab-barranquilla /etc/lab-barranquilla
echo "listen=8091" | sudo tee /etc/lab-barranquilla/config >/dev/null
sudo tee /opt/lab-barranquilla/app.sh >/dev/null <<'EOF'
#!/bin/bash
cat /etc/lab-barranquilla/config >/dev/null
echo "$(date) start" >> /var/log/lab-barranquilla/app.log
if cat /etc/shadow >/dev/null 2>&1; then echo "SHADOW READABLE (bad)"; else echo "shadow blocked (good)"; fi
echo "done"
EOF
sudo chmod +x /opt/lab-barranquilla/app.sh
# NOTE: no profile exists yet — the app currently runs UNCONFINED and CAN read /etc/shadow:
sudo /opt/lab-barranquilla/app.sh
```
**Situation:** A new service, `/opt/lab-barranquilla/app.sh`, ships with **no** AppArmor profile — it runs unconfined and can currently read `/etc/shadow` (the setup run prints "SHADOW READABLE (bad)"). You must author a complete **enforce-mode** profile from scratch that (a) lets it read its config and write its log, and (b) blocks *and audits* any attempt to read `/etc/shadow`, then prove the confinement is live.

**Your task:** Write, load, and enforce a profile so that running `app.sh` under it (1) shows your profile in `/proc/.../attr/current`, (2) still writes `/var/log/lab-barranquilla/app.log`, and (3) is **denied** reading `/etc/shadow` (printing "shadow blocked (good)" and logging `apparmor="DENIED"`).

**Verify:**
```bash
sudo aa-exec -p lab-barranquilla -- /opt/lab-barranquilla/app.sh
# expected: prints "shadow blocked (good)" then "done"
tail -n1 /var/log/lab-barranquilla/app.log
# expected: a dated "start" line
sudo dmesg | grep 'apparmor="DENIED"' | grep shadow | tail -n1
# expected: an apparmor="DENIED" record naming /etc/shadow
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "La Paz: what is confining this process?"
**Solution:**
```bash
PID=$(pgrep -f /opt/lab-lapaz/app.sh | head -n1)
cat /proc/$PID/attr/current        # lab-lapaz (enforce)
sudo aa-status | grep lab-lapaz    # cross-check: listed as a loaded, enforcing profile
```
**Why this works & what it teaches:** A process's active AppArmor confinement is exposed per-task at `/proc/PID/attr/current` — it names the profile *and* its mode. This is the ground-truth attach point: `aa-status` gives the fleet-wide view (all loaded profiles + confined processes), but `attr/current` tells you exactly what is guarding *this* PID right now. **Where people go wrong:** assuming a profile in `/etc/apparmor.d/` is confining something — a profile only binds to a process that was launched under it. **Cleanup:** `pkill -f /opt/lab-lapaz/app.sh; sudo apparmor_parser -R /etc/apparmor.d/lab-lapaz; sudo rm /etc/apparmor.d/lab-lapaz; sudo rm -rf /opt/lab-lapaz`.

### Scenario 2 — "Asuncion: the profile that isn't loaded"
**Solution:**
```bash
sudo apparmor_parser -r /etc/apparmor.d/lab-asuncion   # compile + load into the kernel
sudo aa-status | grep lab-asuncion                     # now listed
```
**Why this works & what it teaches:** Files in `/etc/apparmor.d/` are just **source**. The kernel enforces the compiled copy (a DFA) held in kernel memory; until `apparmor_parser` reads the text, compiles it, and pushes it in, nothing is enforced. `apparmor_parser -r` (replace) is the actual "apply" step — `aa-enforce`/`systemctl reload apparmor` are just wrappers that ultimately call it. **Where people go wrong:** editing/saving the profile and expecting live effect, or reloading the wrong path. **Cleanup:** `sudo apparmor_parser -R /etc/apparmor.d/lab-asuncion; sudo rm /etc/apparmor.d/lab-asuncion; sudo rm -rf /opt/lab-asuncion`.

### Scenario 3 — "Punta Arenas: permission denied but ls says yes"
**Solution:**
```bash
# Find the real reason in the kernel audit stream:
sudo dmesg | grep 'apparmor="DENIED"' | tail -n1
#   ... apparmor="DENIED" operation="open" profile="lab-punta"
#       name="/var/log/lab-punta/out.log" requested_mask="wc" denied_mask="wc" ...
# Add the missing write rule, then reload:
sudo sed -i '/\/etc\/lab-punta\/\*\* r,/a\  /var/log/lab-punta/** w,' /etc/apparmor.d/lab-punta
sudo apparmor_parser -r /etc/apparmor.d/lab-punta
sudo aa-exec -p lab-punta -- /opt/lab-punta/app.sh && tail -n1 /var/log/lab-punta/out.log
```
**Why this works & what it teaches:** AppArmor is MAC layered *after* DAC — both must say yes. DAC (mode `0777`) allowed the write, but the profile's whitelist named no rule for `/var/log/lab-punta`, so it was default-denied. The confined app just sees `EACCES` ("Permission denied"), identical to a file-mode failure; the AppArmor-specific reason lives **only** in the kernel audit log (`dmesg`/`journalctl -k`). Adding `/var/log/lab-punta/** w,` and reloading lets the write through. **Where people go wrong:** `chmod`/`chown`-ing the path (DAC was never the problem) instead of reading `dmesg` for the `DENIED` line. **Cleanup:** `sudo apparmor_parser -R /etc/apparmor.d/lab-punta; sudo rm /etc/apparmor.d/lab-punta; sudo rm -rf /opt/lab-punta /var/log/lab-punta /etc/lab-punta`.

### Scenario 4 — "Mendoza: complain mode was masking a missing rule"
**Solution:**
```bash
sudo aa-enforce /opt/lab-mendoza/app.sh                 # flip to enforce
sudo aa-exec -p lab-mendoza -- /opt/lab-mendoza/app.sh  # now FAILS: state write denied
# Discover the needed rule from the log (or use aa-logprof to propose it), then add it:
sudo dmesg | grep 'apparmor="DENIED"' | grep lab-mendoza | tail -n1
sudo sed -i '/\/etc\/lab-mendoza\/\*\* r,/a\  /var/lib/lab-mendoza/** w,' /etc/apparmor.d/lab-mendoza
sudo apparmor_parser -r /etc/apparmor.d/lab-mendoza     # reload (stays enforce)
sudo aa-exec -p lab-mendoza -- /opt/lab-mendoza/app.sh && cat /var/lib/lab-mendoza/state
```
**Why this works & what it teaches:** Enforce and complain are one boolean flag on the same profile. In **complain** mode a default-denied access is *allowed but logged* (`apparmor="ALLOWED"`) — the app works while you learn what it needs. In **enforce** the identical denial is *blocked* (`EACCES` + `apparmor="DENIED"`). The safe rollout is: run complain, collect the audit lines (`aa-logprof` reads exactly these and proposes rules), add them, then enforce. Here the missing `/var/lib/lab-mendoza/** w,` rule was invisible until enforce exposed it. **Where people go wrong:** shipping straight to enforce with an incomplete profile (a 2am outage), or leaving it in complain forever (no protection). **Cleanup:** `sudo apparmor_parser -R /etc/apparmor.d/lab-mendoza; sudo rm /etc/apparmor.d/lab-mendoza; sudo rm -rf /opt/lab-mendoza /var/lib/lab-mendoza /etc/lab-mendoza`.

### Scenario 5 — "Iquitos: the allow rule that never wins"
**Solution:**
```bash
# An explicit `deny` OVERRIDES any allow for the same path — deny always wins.
# Remove the deny line, then reload:
sudo sed -i '/deny \/opt\/lab-iquitos\/data\/secret.log w,/d' /etc/apparmor.d/lab-iquitos
sudo apparmor_parser -r /etc/apparmor.d/lab-iquitos
sudo aa-exec -p lab-iquitos -- /opt/lab-iquitos/app.sh && cat /opt/lab-iquitos/data/secret.log
```
**Why this works & what it teaches:** AppArmor rule precedence is not "most specific wins" or "last match wins" — an explicit `deny` rule is absolute and beats any overlapping `allow`, no matter how broad the allow is. So `/opt/lab-iquitos/data/** w,` genuinely permits `secret.log`, but the `deny .../secret.log w,` line vetoes it. Deleting the deny (or narrowing it) lets the allow apply. This is why the file warns that a catch-all like `deny /** w,` would silently kill your intended writes. **Where people go wrong:** piling on *more* allow rules trying to out-vote the deny — impossible; deny is final. **Cleanup:** `sudo apparmor_parser -R /etc/apparmor.d/lab-iquitos; sudo rm /etc/apparmor.d/lab-iquitos; sudo rm -rf /opt/lab-iquitos`.

### Scenario 6 — "Barranquilla: confine it from scratch, prove it, and block shadow"
**Solution:**
```bash
sudo tee /etc/apparmor.d/lab-barranquilla >/dev/null <<'PROF'
abi <abi/3.0>,
include <tunables/global>
profile lab-barranquilla /opt/lab-barranquilla/app.sh flags=(attach_disconnected) {
  include <abstractions/base>
  include <abstractions/bash>
  /opt/lab-barranquilla/app.sh r,
  /usr/bin/bash ix,
  /usr/bin/cat ix,
  /usr/bin/date ix,
  /etc/lab-barranquilla/** r,      # read its config
  /var/log/lab-barranquilla/** w,  # write its log
  audit deny /etc/shadow r,        # explicitly + audibly block the classic target
}
PROF
sudo apparmor_parser -r /etc/apparmor.d/lab-barranquilla
sudo aa-enforce /opt/lab-barranquilla/app.sh   # (profiles load enforce by default; this is belt-and-braces)
sudo aa-exec -p lab-barranquilla -- /opt/lab-barranquilla/app.sh   # "shadow blocked (good)" / "done"
tail -n1 /var/log/lab-barranquilla/app.log
sudo dmesg | grep 'apparmor="DENIED"' | grep shadow | tail -n1
```
**Why this works & what it teaches:** This is the full authoring loop: start from `abstractions/base` (the ~50 paths every program needs) so you don't hand-list libraries, then whitelist exactly the app's config-read and log-write paths. Because a whitelist is default-deny, `/etc/shadow` is already blocked — the `audit deny /etc/shadow r,` line makes that denial *explicit and logged* (the `audit` keyword forces an audit record even for a rule that would otherwise be silent). `/proc/PID/attr/current` proves the process is actually confined; the `dmesg` `DENIED` line proves the shadow read was vetoed by AppArmor, not by DAC. **Where people go wrong:** forgetting `include <abstractions/bash>` (the shell interpreter can't run), or writing a `deny /** w,` catch-all that also kills the intended log write (deny wins). **Cleanup:** `sudo apparmor_parser -R /etc/apparmor.d/lab-barranquilla; sudo rm /etc/apparmor.d/lab-barranquilla; sudo rm -rf /opt/lab-barranquilla /var/log/lab-barranquilla /etc/lab-barranquilla`.
