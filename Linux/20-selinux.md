# SELinux — Type Enforcement, Contexts, Booleans, audit2allow

*The missing security chapter: how RHEL/OpenShift nodes decide that `container_t` is allowed to touch `container_file_t` — and nothing else.*

---

## Rung 0 — 🎯 The Setup

**What you're learning:** SELinux (Security-Enhanced Linux) — a *label-based Mandatory Access Control* (MAC) system baked into the Linux kernel. Every process and every file carries a **security context** (a label). The kernel consults a policy that says which label may touch which label, and enforces it *on top of* normal Unix permissions. If the label check fails, the operation is denied — even if `rwx` said "yes" and even for root.

**Why it landed on your desk:** You run a workload on an OpenShift cluster (or a RHEL/CentOS/Rocky-based Kubernetes node). A pod that works perfectly on your Ubuntu dev cluster comes up `CrashLoopBackOff` in production. The app logs say `Permission denied` writing to its PersistentVolume mount at `/data`. You `exec` in, run `ls -ld /data`, and the permissions are `drwxrwxrwx` — wide open. `chmod 777` already, root already, still denied. Someone on the platform channel types one word: **"SELinux."** You need to know what that means, why `777` didn't save you, and how to fix it *the right way* (not by turning SELinux off).

**What you already know that transfers:**
- **Standard permissions** (file `05`): owner/group/other, `rwx`, root bypasses them. SELinux is a *second, independent gate* — root does **not** bypass it.
- **Namespaces & cgroups** (`13`, `14`): the kernel already isolates and limits containers. SELinux is the *third leg* — it isolates what a process may **access** by label.
- **Capabilities & seccomp** (`17`, `18`): you've seen the kernel restrict what a process may *do* (syscalls, privileged ops). SELinux restricts what it may *touch* (objects), by label.
- **AppArmor** (`19`): you just learned Ubuntu's path-based MAC. SELinux is the RHEL-family cousin — same *goal*, radically different *mechanism* (labels, not paths).

Keep AppArmor fresh: the entire punchline of this file is **"same problem, opposite design."**

---

## Rung 1 — 🔥 The Pain

Rewind to a world with only **Discretionary Access Control (DAC)** — the classic Unix `rwx` model.

**"Discretionary" is the problem.** DAC means the *owner* of a file decides who can access it. If I own a file, I can `chmod 777` it, and the system obeys me. That's fine for a laptop. It's a catastrophe for a multi-tenant server:

1. **Root is all-powerful.** Any process running as root (UID 0) bypasses every `rwx` check. In the container era, *thousands* of workloads historically ran as root inside their containers. One compromised process that escaped its namespace could read `/etc/shadow`, tamper with `/etc/kubernetes/pki`, or scribble on another tenant's data — because DAC says "you're root, go ahead."

2. **Compromise = total access.** A web server exploited via a bug now runs with the web server's full identity. Under DAC, if that user can read the database socket, the attacker can too. There's no way to say "the web server binary may listen on port 80 but may *never* read `/home`, no matter who runs it."

3. **No notion of "this program's job."** DAC ties permission to *who you are* (UID/GID), not *what role you're playing*. Apache running as `apache` and a shell running as `apache` have identical power. The system can't tell a legitimate httpd from a reverse shell wearing httpd's UID.

**What people did before, and why it hurt:** They hardened by hand — dropped privileges, ran services as dedicated low-priv users, wrote fragile `chmod`/`chown` scripts, and prayed. Each service needed bespoke lockdown; a single missed file undid it. There was no *system-wide, mandatory* policy that the file owner could not override.

**Who feels it most:** Multi-tenant platform operators. The NSA (who wrote SELinux) and later Red Hat wanted a server where *even a full root compromise inside one service* couldn't pivot to the rest of the box. In Kubernetes terms: **you run untrusted or semi-trusted workloads from many teams on shared nodes.** Without MAC, a container breakout means the attacker inherits the node. With SELinux enforcing, a breakout lands the attacker in the `container_t` domain — confined, unable to touch `kubelet`'s files, unable to read another pod's volume, boxed in by a policy no in-container root can rewrite.

> **Check yourself before Rung 2:** DAC lets the file's owner change its permissions at will. In one sentence, what must be true about *who controls the rules* for MAC to defend a node whose containers run as root?

---

## Rung 2 — 💡 The One Idea

> **Every process and every object wears a label; the kernel allows an action only if a central, admin-owned policy explicitly permits `subject-label → object-label` for that action — and nobody, not even root, can talk their way past it.**

Memorize that sentence. Everything below is derived from it:

- **"Every process and object wears a label"** → contexts, `ls -Z`, `ps -Z`, `id -Z`, relabeling with `chcon`/`restorecon`.
- **"a central, admin-owned policy"** → the compiled policy in `/etc/selinux/`, `booleans` as policy switches, `semanage` to edit it. The file owner can't touch it.
- **"explicitly permits subject → object"** → **type enforcement** and `allow` rules. *Default deny*: if no rule grants it, it's denied.
- **"for that action"** → rules are per *class* (file, dir, socket, process) and per *permission* (read, write, execute, connectto…).
- **"not even root"** → this is the whole point. MAC sits *after* DAC. Both must say yes.

Two gates, in series:

```
   syscall (open /data for write)
        │
        ▼
 ┌──────────────┐   deny → EACCES
 │  DAC check   │────────────────►  (rwx / ownership)
 │  (rwx)       │
 └──────┬───────┘  allow
        ▼
 ┌──────────────┐   deny → EACCES + AVC log
 │  MAC check   │────────────────►  (SELinux label policy)
 │  (SELinux)   │
 └──────┬───────┘  allow
        ▼
     operation proceeds
```

Your `chmod 777` fixed the **top** gate. The `Permission denied` came from the **bottom** one. That single realization is 80% of operating SELinux.

> **Check yourself before Rung 3:** Given the two-gate model, explain why `chmod 777 /data` had no effect on an SELinux denial — and predict which log the *other* gate writes to when it says no.

---

## Rung 3 — ⚙️ The Machinery (go slow here)

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture a high-security warehouse where every worker and every box wears a **name badge**, and one central rulebook — owned by management, untouchable by workers — says exactly which badge may touch which badge.
>
> - **What's on a badge (3.1).** Each badge has four lines: an identity line, a role line, a **job-title line**, and a clearance line. The job title is the star — almost every decision comes down to it (for example, "container worker" vs "container storage box"). The fourth line holds clearance stamps: on ordinary setups, its little category codes are what keep two neighboring tenants' workers out of each other's boxes even when everything else about them looks identical.
> - **The rulebook (3.2).** The rulebook is a long list of one-shape sentences: "a worker with job title A may do these specific actions to a box with job title B." If no sentence covers your exact combination, the answer is **no** — there is no "otherwise, allow" page. That's why a box wearing the *wrong* badge blocks even a perfectly well-behaved worker: the rules mention the right badge, not the wrong one the box accidentally got.
> - **How a check actually happens (3.3).** When a worker reaches for a box, the ordinary door lock (classic file permissions) is checked first. If that passes, a built-in checkpoint quietly asks the security office: "worker badge X, box badge Y, action Z — allowed?" To stay fast, the office keeps a **cheat sheet of recent answers** (a cache) and only consults the full rulebook for brand-new combinations. On a "no," the worker just gets a bland "permission denied," and the real reason is written in the **incident logbook** — the only place the truth appears. The warehouse also has a training mode: same questions, same log entries, but nothing actually blocked — perfect for discovering what a new worker needs before enforcement is switched on.
> - **Where badges come from (3.4).** A box's badge is written on a sticker glued to the box itself (so it travels with the box), and new boxes inherit a badge from the shelf they're created on. There's also a master registry of "what badge each shelf's boxes *should* wear." Two ways to fix a wrong badge: scribble a new one by hand (quick, but the next registry-based re-check erases it) or update the registry and then re-stamp (permanent).
> - **The switches (3.5).** Some rule bundles have an on/off switch so managers can enable optional behaviors without rewriting the rulebook — but flip the switch the non-permanent way and it resets after a building restart.

*Now the original technical deep-dive — the same ideas, in precise form:*

### 3.1 The label: `user:role:type:level`

Every context has **four fields**, colon-separated:

```
system_u : object_r : container_file_t : s0:c123,c456
   │           │            │                  │
 SELinux    SELinux       TYPE            MLS/MCS level
  user       role      (the star)      sensitivity+categories
```

- **SELinux user** (`system_u`, `unconfined_u`, `staff_u`) — *not* the Unix user. It's a policy identity mapped from the Linux login. Governs which roles are reachable.
- **Role** (`object_r`, `system_r`, `staff_r`) — a bridge between users and types. **Files always have `object_r`** (objects don't play roles). Processes carry a real role like `system_r`. Roles exist mainly for Role-Based Access Control on *users*; for server/container work you mostly ignore them.
- **Type** (`container_t`, `container_file_t`, `httpd_t`, `kubelet_exec_t`) — **THE field that matters.** For processes the type is called a **domain**. Type Enforcement (TE) is the engine that decides everything. 95% of SELinux troubleshooting is "wrong type."
- **Level** (`s0`, `s0:c123,c456`) — the **MLS/MCS** field: sensitivity (`s0`…`s15`) plus **categories** (`c0`…`c1023`). On a default targeted policy sensitivity is always `s0`; the **categories** are what isolate containers/pods from each other. Hold this thought — it's the pod-isolation mechanism.

### 3.2 Type Enforcement — the heart

The policy is a giant compiled set of **`allow` rules**. Each rule has the shape:

```
allow  SOURCE_TYPE  TARGET_TYPE : CLASS  { PERMISSIONS } ;

  e.g.  allow container_t container_file_t : file { read write open getattr append } ;
        allow container_t container_file_t : dir  { search add_name remove_name write } ;
```

Read it as a sentence: *"A process in domain `container_t` may `read`/`write`/`open` a `file` object labeled `container_file_t`."* No matching `allow` rule → **denied by default**. There is no "allow everything" fallthrough. This is *default-deny*, which is why a *mislabeled* file breaks even a correct app: the app's domain has a rule for the *right* label, not the *wrong* one your volume accidentally got.

### 3.3 Where the check physically happens: the LSM hook + AVC

SELinux is a **Linux Security Module (LSM)** — the same kernel framework AppArmor plugs into (only one "major" LSM is active per boot; RHEL ships SELinux, Ubuntu ships AppArmor). Here's the path of a single `open()`:

```
  USER SPACE            │  KERNEL SPACE
                        │
  app: open("/data",    │   ┌────────────┐
        O_WRONLY) ──────┼──►│  syscall   │
                        │   │  open()    │
                        │   └─────┬──────┘
                        │         │ 1. normal DAC (rwx) check — passes
                        │         ▼
                        │   ┌──────────────────┐
                        │   │  LSM security     │  2. security_file_open()
                        │   │  hook fires        │     hook → SELinux
                        │   └─────┬─────────────┘
                        │         ▼
                        │   ┌──────────────────┐   3. build the question:
                        │   │  SELinux LSM      │      subj=container_t
                        │   │  security_compute │      obj =container_file_t
                        │   │  _av()            │      class=file  perm=write
                        │   └─────┬─────────────┘
                        │         ▼
                        │   ┌──────────────────┐   4. fast path: is this
                        │   │  AVC              │      (subj,obj,class) cached?
                        │   │ Access Vector     │      hit → answer instantly
                        │   │  Cache            │      miss → ask the policy
                        │   └─────┬─────────────┘
                        │         ▼ (miss)
                        │   ┌──────────────────┐   5. walk compiled policy
                        │   │  Security Server  │      (binary in kernel,
                        │   │  (policy in mem)  │       loaded from /etc/selinux)
                        │   └─────┬─────────────┘
                        │         │ 6. ALLOW or DENY, cache the result
                        │         ▼
                        │   DENY → return -EACCES to app
                        │        + write an AVC denial to the
                        │          audit subsystem → /var/log/audit/audit.log
```

Key facts the app never sees:
- The **AVC (Access Vector Cache)** makes this fast — a lookup per novel `(source, target, class)` tuple, then cached. Steady state adds negligible overhead.
- On a **deny**, the kernel emits an **AVC message** to the audit subsystem. `auditd` writes it to `/var/log/audit/audit.log`. That log is your entire debugging surface — no AVC line, no SELinux denial.
- **Enforcing vs permissive is decided right here.** In *enforcing* mode a deny returns `-EACCES`. In *permissive* mode the kernel **logs the identical AVC but returns success** — nothing is blocked. That's the mode you use to *discover* every rule an app needs before you flip enforcing back on.

### 3.4 Where labels come from (this is subtle and important)

A file's label is stored in the **`security.selinux` extended attribute (xattr)** on the filesystem — same mechanism as any xattr, viewable with `getfattr -n security.selinux`. So labels persist on disk with the file. New files get their label from **type transition rules** (usually: inherit the parent directory's type). This is why `restorecon` works: the *correct* label for a path is defined by a **file-context database** (`/etc/selinux/targeted/contexts/files/file_contexts`, edited via `semanage fcontext`), and `restorecon` resets each file's xattr to whatever that database says the path *should* be.

Two ways to set a label — memorize the difference, it bites everyone:

| Tool | What it does | Survives a relabel? |
|---|---|---|
| `chcon` | Writes the xattr **directly**, right now. | **No** — a later `restorecon` reverts it. |
| `semanage fcontext -a` + `restorecon` | Updates the **policy database** of what the path *should* be, then applies it. | **Yes** — it's now the canonical rule. |

`chcon` is a hotfix; `semanage fcontext` is the permanent fix.

### 3.5 Booleans — policy switches without recompiling

Some access is *conditionally* allowed. A **boolean** is a runtime on/off toggle inside the policy that enables a bundle of `allow` rules. Example: `container_manage_cgroup` gates whether `container_t` may write the cgroup filesystem (needed by some workloads that manage nested cgroups). `getsebool -a` lists them; `setsebool -P` flips one **P**ersistently (survives reboot by writing the on-disk policy). Without `-P` the change is lost at reboot — a classic 3am gotcha.

> **Check yourself before Rung 4:** A file has the xattr `container_file_t` on disk, but the policy's file-context database says that path *should* be `httpd_sys_content_t`. What does `restorecon` do, and why would `chcon`'s effect on the same file be temporary?

---

## Rung 4 — 🏷️ The Vocabulary Map

| Term | What it actually is | Which part of the machinery |
|---|---|---|
| **DAC** | Discretionary Access Control — classic `rwx`/ownership, owner-controlled, root bypasses. | The **top** gate (checked first). |
| **MAC** | Mandatory Access Control — admin policy, no owner override, root does *not* bypass. | The **bottom** gate (SELinux). |
| **Context / Label** | The `user:role:type:level` 4-tuple on every process & object. | Stored in `security.selinux` xattr (files) / task struct (processes). |
| **Type** | 3rd field, e.g. `container_file_t`. The unit of policy for objects. | Type Enforcement decision. |
| **Domain** | A **type applied to a process**, e.g. `container_t`. Same concept, process-flavored. | Source side of `allow` rules. |
| **Type Enforcement (TE)** | The engine: `allow SRC TGT : CLASS perms`, default-deny. | Security Server + compiled policy. |
| **MLS / MCS** | Multi-Level / Multi-Category Security — the 4th (`level`) field. | Categories `c0..c1023` isolate peers. |
| **Category (`c123`)** | A tag in the level field; two contexts must share categories to interact. | **Pod-to-pod isolation** on the same UID. |
| **AVC** | Access Vector Cache — kernel cache of decisions; also the name of a *denial log line*. | Fast-path in the kernel. |
| **LSM** | Linux Security Module framework SELinux plugs into (so does AppArmor). | The kernel hook that calls SELinux. |
| **Boolean** | Runtime on/off switch enabling a bundle of `allow` rules. | `getsebool`/`setsebool -P`. |
| **Enforcing / Permissive / Disabled** | The three global modes: block+log / log-only / off. | Decision point after the policy answers. |
| **`chcon`** | Directly writes a label xattr (temporary). | Object label, imperative. |
| **`restorecon`** | Resets labels to what the **fcontext DB** says they should be. | Reconciles xattr ↔ policy DB. |
| **`semanage fcontext`** | Edits the **fcontext database** (the canonical path→label rules). | Permanent label policy. |
| **`audit2allow`** | Reads AVC denials, generates the `allow` rules that would permit them. | Turns logs → policy module. |
| **fcontext DB** | `.../contexts/files/file_contexts` — regex path→default-label map. | Source of truth for `restorecon`. |

**Same-kind-of-thing, different names — don't be fooled:**
- **Type** and **Domain** are *the same field* — "domain" just means "a type that happens to be on a running process." `container_t` is a domain; `container_file_t` is a type. Identical machinery.
- **"AVC"** names *two* things: the kernel cache **and** each denial log line ("an AVC"). Context tells you which.
- **"SELinux user" vs Linux user** — unrelated namespaces. `system_u` is not `root`. The `id -Z` you'll run shows the SELinux one.
- **`chcon` vs `semanage fcontext`** — both "set a label," but one is a temporary xattr poke and the other is durable policy. Treat them as *different tools*, not synonyms.
- **Boolean vs allow rule** — a boolean is just an `if` guard *around* a group of allow rules; conceptually the same TE engine, exposed as a switch.

> **Check yourself before Rung 5:** Using only the map above, name the *field* of a context that carries a **domain**, the *tool* that changes a label durably (surviving `restorecon`), and the *file* `restorecon` consults to decide what a path's label *should* be.

---

## Rung 5 — 🔬 The Trace

**Scenario:** A pod mounts a PersistentVolume at `/data`. The container process (a plain non-OpenShift RHEL node with `crio`/`containerd`) tries to write `/data/app.log`. The volume was provisioned by a CSI driver and its files came out labeled with the *default* filesystem type `unlabeled_t` (or the node's generic `default_t`) — **not** `container_file_t`. SELinux is **enforcing**.

Follow the write end to end:

```
 ┌─ pod process (domain: container_t, level: s0:c123,c456)
 │      write("/data/app.log")
 │
 1│ syscall enters kernel: openat(... O_WRONLY|O_CREAT)
 │
 2│ DAC check: uid/gid vs mode 0777 on /data → PASS (rwx wide open)
 │
 3│ LSM hook fires → SELinux security server builds the question:
 │        subject = container_t
 │        object  = default_t        ◄── the mislabeled volume
 │        class   = file
 │        perm    = { create write open }
 │
 4│ AVC lookup: (container_t, default_t, file) → MISS
 │
 5│ Security server walks policy:  is there
 │        allow container_t default_t : file { write } ;  ?
 │        → NO such rule.  Default-deny.
 │
 6│ Decision = DENY.  Mode = enforcing → return -EACCES to the app.
 │
 7│ Kernel emits AVC denial → auditd → /var/log/audit/audit.log:
 │     type=AVC msg=audit(...): avc:  denied  { write } for  pid=4127
 │       comm="myapp" name="app.log" scontext=system_u:system_r:container_t:s0:c123,c456
 │       tcontext=system_u:object_r:default_t:s0  tclass=file permissive=0
 │
 8│ App receives EACCES → logs "Permission denied" → crashes → CrashLoopBackOff
```

Now the **fix trace** — what you actually do:

```
 A│ ausearch -m avc -ts recent        → find the AVC above (tcontext=default_t)
 B│ read it: scontext container_t wants a file it can't → LABEL is wrong
 C│ restorecon won't help (fcontext DB has no rule for a random PV path),
 │   so relabel explicitly:
 │      chcon -Rt container_file_t /data           (hotfix, this boot)
 │   OR the durable way for a known mount path:
 │      semanage fcontext -a -t container_file_t "/data(/.*)?"
 │      restorecon -Rv /data
 D│ re-run: object is now container_file_t
 │      allow container_t container_file_t : file { write } ;  EXISTS → ALLOW
 E│ pod writes /data/app.log → Running.
```

The **real** Kubernetes fix is to never hit this: tell the runtime to relabel the mount for you (the `:Z` bind-mount flag or `securityContext.seLinuxOptions`) — covered in Rung 7. But tracing the manual path is how you understand *what that flag automates.*

> **Check yourself before Rung 6:** In step 7 the log shows `permissive=0`. Predict exactly what changes in steps 6, 7, and 8 if the node were in **permissive** mode instead — and why that makes permissive dangerous as a "fix."

---

## Rung 6 — ⚖️ The Contrast

The alternative you already met: **AppArmor** (`19`) — the MAC that ships enabled on Ubuntu/Debian/SUSE. Both are LSMs, both are MAC, both confine processes. The design is opposite.

**The core split: labels vs paths.**
- **SELinux keys on labels** stored *in the filesystem* (xattrs). A file *is* `container_file_t` no matter what path you reach it by — hard links, bind mounts, symlinks all resolve to the same label. Powerful, precise, filesystem-integrated… and it **breaks the instant a label is wrong**, which is most of the operational pain.
- **AppArmor keys on pathnames** in a per-profile text file (`/etc/apparmor.d/…`). A rule reads `/data/** rw,`. No xattrs, human-readable, easy to write… but *aliasing* (two paths to one file, bind mounts) can slip past a path rule, and it's coarser.

| Dimension | **SELinux** (RHEL/OpenShift) | **AppArmor** (Ubuntu) |
|---|---|---|
| Decides based on | **Labels** (xattr on inode) | **Path** strings |
| Scope | *Everything* — files, ports, sockets, IPC, processes, keys | Mostly per-program file/capability/network profiles |
| Policy form | Compiled binary policy, booleans, `semanage` | Plain-text per-app profiles, `enforce`/`complain` |
| Multi-tenant isolation | **MCS categories** isolate peers at same UID | No native per-instance category isolation |
| Learning curve | Steep; contexts + audit2allow | Gentler; readable rules |
| Survives cp/mv/rename | Label follows inode; new files need transition/relabel | Path rule matches wherever it lands |
| Default distro | RHEL, CentOS, Fedora, Rocky, **OpenShift** | Ubuntu, Debian, SUSE |
| Modes | enforcing / permissive / disabled (global + per-domain) | enforce / complain (per profile) |

**What SELinux can do that AppArmor can't (easily):** isolate *many identical pods* running as the *same UID* from each other, via **MCS categories** — the runtime gives each container a unique `c-pair` (e.g. `s0:c123,c456`) so container A literally cannot read container B's files even though both are `container_t` and both run as UID 0. Path-based AppArmor has no comparable per-instance dimension. Also: SELinux confines *network ports, sockets, and IPC* with the same label machinery — much broader than typical AppArmor profiles.

**What AppArmor does better:** it's *legible*. You can read and write a profile in five minutes; SELinux policy is a compiled artifact you coax with `audit2allow`. For a single-app box, AppArmor's path rules are faster to reason about.

**When would you NOT need SELinux?** On a single-tenant Ubuntu node where AppArmor already covers you, or a throwaway dev VM. And you should **never "not need it" by setting `SELINUX=disabled`** on a shared RHEL/OpenShift node — that throws away the whole MAC layer for every workload. If a label is fighting you, *permissive* (log, don't block) while you fix labels beats *disabled*.

**Why this over that, in one sentence:** On RHEL-based and OpenShift nodes SELinux is already the enforced, filesystem-integrated MAC that gives you per-pod MCS isolation for free — so you *operate* it, you don't replace it.

> **Check yourself before Rung 7:** Two pods run as UID 0 (root) on the same node with SELinux enforcing. Pod A cannot read Pod B's volume. It's not DAC (both are root) and not namespaces (assume a shared hostPath). Which *field* of the context is doing the isolating, and what's different about that field between the two pods?

---

## Rung 7 — 🧪 The Prediction Test

Commit to each prediction **out loud before you run the command.** Being wrong here is where the model actually forms. These assume a RHEL-family box (RHEL/CentOS/Rocky/Fedora) with SELinux present. On Ubuntu, `getenforce` returns `Disabled`/absent — note that and read along, or spin up a Fedora VM.

### Example 1 — Normal case: see the modes and the labels

**Prediction:** `getenforce` prints a single word (`Enforcing`). `sestatus` shows more detail including the loaded policy. `id -Z` shows *my shell's* context, `ps -Z` shows a process's domain, and `ls -Z` shows a *file's* type — and system files (including everything under `/etc/kubernetes`) will carry types like `etc_t`, **not** the same label as my shell.

```bash
getenforce
# Enforcing

sestatus
# SELinux status:                 enabled
# SELinuxfs mount:                /sys/fs/selinux
# SELinux root directory:         /etc/selinux
# Loaded policy name:             targeted
# Current mode:                   enforcing
# Mode from config file:          enforcing
# Policy MLS status:              enabled
# Policy deny_unknown status:     allowed

id -Z
# unconfined_u:unconfined_r:unconfined_t:s0     ← an admin shell is "unconfined"

ps -Z -p 1
# LABEL                             PID TTY  ...
# system_u:system_r:init_t:s0         1 ?    /usr/lib/systemd/systemd

ls -Z /etc/kubernetes
# system_u:object_r:etc_t:s0        admin.conf
# system_u:object_r:etc_t:s0        kubelet.conf
# system_u:object_r:etc_t:s0        pki           ← default kubeadm: plain etc_t
#                                                   (no dedicated fcontext rule)
```

**Verify:** `getenforce` says `Enforcing` and the four-field context appears everywhere. If `id -Z` says `unconfined_t`, that's expected for an interactive admin — *unconfined* means "policy loaded but this domain is deliberately unrestricted." If instead you see `command not found`/`Disabled`, you're on a non-SELinux distro (Ubuntu) — that itself teaches you *which* MAC this host runs.

### Example 2 — Edge/failure case: a denial, and reading the audit log

**Prediction:** If I put a file in a directory with the *wrong* type and then make a confined service read it, the write/read is **denied even as root**, and a matching `avc: denied` line appears in `/var/log/audit/audit.log`. `chcon` to the right type makes the *same* operation succeed with no other change.

```bash
# Create a file, then FORCE a wrong label on it (simulating a mislabeled volume):
mkdir -p /data && echo hi > /data/app.log
ls -Z /data/app.log
# unconfined_u:object_r:default_t:s0   /data/app.log   ← generic, not container_file_t

# Try to consume it from a confined context (or observe a real service denial).
# Trigger + hunt the denial:
ausearch -m avc -ts recent
# type=AVC msg=audit(1721145600.123:456): avc:  denied  { write } for
#   pid=4127 comm="myapp" name="app.log"
#   scontext=system_u:system_r:container_t:s0:c123,c456
#   tcontext=unconfined_u:object_r:default_t:s0 tclass=file permissive=0

# Fix the label (hotfix), then retry — no other change:
chcon -t container_file_t /data/app.log
ls -Z /data/app.log
# unconfined_u:object_r:container_file_t:s0   /data/app.log   ← now the right type
```

**Verify:** Look at `tcontext` in the AVC — the **type** (`default_t`) is the culprit, and `permissive=0` confirms it was *actually blocked* (that's your EACCES). After `chcon`, `ls -Z` shows `container_file_t` and the operation stops being denied. If you *don't* find an AVC line, either the op wasn't actually blocked (check `getenforce`), or `auditd` isn't running (`systemctl status auditd`) — no auditd, no visibility, and that blind spot is itself the lesson.

**Generate the policy the "wrong" way, then decide:** you *can* feed the denial to `audit2allow`, but pause — for a mislabel the answer is *relabel*, not a new rule:

```bash
ausearch -m avc -ts recent | audit2allow -m mylocal
# module mylocal 1.0;
# require { type container_t; type default_t; class file write; }
# #============= container_t ==============
# allow container_t default_t:file write;     ← DON'T ship this: it grants
#                                                container_t write to ALL default_t.
```

**Verify:** `audit2allow` faithfully turns the denial into an `allow` rule — and reading it teaches you *why you often shouldn't apply it*. Granting `container_t → default_t` write is far broader than fixing one mislabeled path. Use `audit2allow` for genuinely-missing access (a boolean or a real new capability), and use **relabeling** for the far-more-common "wrong label" case.

### Example 3 — Kubernetes-flavored case: booleans, durable relabel, and the `:Z` mount

**Prediction (booleans):** `getsebool -a` lists dozens of toggles. A workload that manages nested cgroups (some CI/build or nested-container pods) gets denied touching the cgroup fs until I enable `container_manage_cgroup`; with `-P` the change **survives reboot**, without `-P` it's lost.

```bash
getsebool -a | grep container
# container_connect_any --> off
# container_manage_cgroup --> off        ← the one we need
# container_use_cephfs --> off

setsebool -P container_manage_cgroup on
getsebool container_manage_cgroup
# container_manage_cgroup --> on
```

**Verify:** the boolean flips to `on`. Reboot (or `getsebool` after) and confirm it's *still* on — that proves `-P` wrote the on-disk policy. Omit `-P` and it reverts on reboot; that reversion is the exact "worked yesterday, broke after the node rebooted" ticket.

**Prediction (durable relabel):** For a *known* mount path, `semanage fcontext -a` + `restorecon` sets the label durably, so a future `restorecon` (or `autorelabel`) keeps it — unlike `chcon`, which a `restorecon` would wipe.

```bash
# Make container_file_t the canonical, permanent type for a mount path:
semanage fcontext -a -t container_file_t "/data(/.*)?"
restorecon -Rv /data
# Relabeled /data from unconfined_u:object_r:default_t:s0
#        to unconfined_u:object_r:container_file_t:s0
# Relabeled /data/app.log ...

# Prove it's durable: chcon it wrong, then restorecon reverts to the policy value.
chcon -t default_t /data/app.log
restorecon -v /data/app.log
# Relabeled /data/app.log from ...:default_t:s0 to ...:container_file_t:s0
```

**Verify:** after `semanage` + `restorecon`, `ls -Z /data` shows `container_file_t`. The clincher: your deliberate wrong `chcon` gets *undone* by `restorecon`, because the fcontext DB now says this path *should* be `container_file_t`. That's the difference between the temporary and durable fix, proven in one shot.

**Prediction (the runtime does it for you — `:Z` and `seLinuxOptions`):** With Docker/Podman/CRI-O, adding `:Z` to a bind mount makes the runtime **relabel the volume to a private `container_file_t` with a unique MCS category** so *only that container* can access it. Kubernetes does the equivalent automatically for most volume types, and you can pin the context with `securityContext.seLinuxOptions`.

```bash
# Podman/Docker: :Z = relabel private (unique MCS);  :z = relabel shared (no MCS)
podman run --rm -v /data:/data:Z docker.io/library/busybox \
  sh -c 'id -Z; ls -Z /data'
# system_u:system_r:container_t:s0:c247,c811     ← unique category pair
# system_u:object_r:container_file_t:s0:c247,c811  app.log   ← volume now matches
```

```yaml
# Kubernetes: pin the pod's SELinux context explicitly (rarely needed; the
# runtime usually assigns a unique MCS pair per pod automatically).
apiVersion: v1
kind: Pod
metadata:
  name: labeled-pod
spec:
  securityContext:
    seLinuxOptions:
      type: container_t          # domain for the container processes
      level: "s0:c123,c456"      # MCS categories → isolates this pod from peers
  containers:
    - name: app
      image: busybox
      command: ["sh", "-c", "id -Z; sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      hostPath:
        path: /data
```

**Verify:** in the `podman` run, `id -Z` (process) and `ls -Z /data` (volume) show the **same** `container_file_t` type **and the same `c###,c###` category pair** — that shared category is *why the container can read its own volume and no other pod's.* Drop the `:Z` and repeat: the volume keeps its old label, the container gets denied — reproducing the Rung-5 PV bug on demand. In the Pod, `kubectl exec labeled-pod -- id -Z` should echo `s0:c123,c456`. **The gotcha to internalize:** if you `setenforce 0` (permissive) the denied mount suddenly "works" — but you've only silenced the alarm; the real fix is the label/`:Z`, and re-enforcing without it brings the outage right back.

```bash
setenforce 0   # permissive: denials are LOGGED but NOT blocked → app limps along
getenforce     # Permissive
# ...fix labels properly...
setenforce 1   # back to Enforcing — do NOT leave a shared node permissive
# Permanent mode lives in /etc/selinux/config:
#   SELINUX=enforcing   (values: enforcing | permissive | disabled)
#   NOTE: going disabled→enforcing requires a full filesystem RELABEL on reboot
#         (touch /.autorelabel; reboot) because xattrs went stale while off.
```

---

## Rung 8 — 🏔 Capstone: Compress It

**One sentence (no notes):** SELinux is a kernel MAC that labels every process and file and lets the admin's default-deny policy — not the file owner, not root — decide which label may touch which.

**Three-sentence beginner explanation:** On RHEL and OpenShift nodes, every file and process wears a `user:role:type:level` label, and the kernel only permits an action if a central policy has an explicit `allow` rule for that source-type → target-type. Standard `rwx` permissions are still checked first, but SELinux is a *second* gate that even root can't override, so a `chmod 777` won't fix a label problem — you fix it by relabeling (`chcon`/`restorecon`/`semanage fcontext`) or, in containers, letting the runtime relabel with `:Z`. When a pod is mysteriously denied on a wide-open PV, you read `/var/log/audit/audit.log` (`ausearch -m avc`), see the wrong `tcontext` type, and either relabel to `container_file_t` or flip a boolean — with MCS categories quietly keeping each pod's data invisible to its neighbors.

**Sub-capabilities → the one idea ("label + admin policy, default-deny, no root override"):**
| Sub-capability | How it derives from the core idea |
|---|---|
| Modes (enforcing/permissive/disabled) | *When* the deny half of the policy actually blocks vs just logs. |
| Contexts / `ls -Z`,`ps -Z`,`id -Z` | The **labels** the whole idea rests on — you're just reading them. |
| Type Enforcement + `allow` rules | The **policy** matching source-label → target-label. |
| MCS categories | The label's 4th field, used to make same-UID pods mutually invisible. |
| Booleans | Admin-owned switches that turn bundles of `allow` rules on/off. |
| `chcon`/`restorecon`/`semanage fcontext` | Setting/repairing the **labels** so the existing policy permits the app. |
| `ausearch`/`audit2allow` | Reading the deny-log, then (carefully) minting the missing rule. |
| `:Z` / `seLinuxOptions` | Kubernetes/runtime automating "give this container a matching label + unique MCS." |

**Which rung to revisit hands-on:** **Rung 7, Example 2 and the `:Z` half of Example 3.** Reading contexts (Ex 1) sticks fast; the muscle memory that pays off in an incident is *reproducing a denial, finding its AVC, and telling "relabel" apart from "add a rule"* — plus watching a `:Z` mount hand out a matching MCS category. If short on time, re-run only the "drop the `:Z`, watch it get denied, add it back" loop — that single experiment encodes the whole file.

---

## Related concepts

- [apparmor](19-apparmor.md) — the path-based MAC on Ubuntu; the direct design contrast to SELinux.
- [permissions-ownership](05-permissions-ownership.md) — the DAC `rwx` gate that SELinux sits *behind*.
- [capabilities](17-capabilities.md) — restricting what a process may *do*; complements SELinux restricting what it may *touch*.
- [seccomp](18-seccomp.md) — syscall-level confinement, the third pillar alongside SELinux and capabilities.
- [storage-mounts](15-storage-mounts.md) — bind mounts, xattrs, and volume labeling where the `:Z` relabel actually lands.
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — where SELinux fits in the full node-triage and Linux↔K8s map.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** DAC lets the file's owner change its permissions at will. In one sentence, what must be true about who controls the rules for MAC to defend a node whose containers run as root?

**A:** The rules must be owned by the administrator and enforced centrally by the kernel, so that neither the file's owner nor a root process inside a workload can change or bypass them. That is the "Mandatory" in MAC: the policy lives outside the discretion of the subjects it confines (compiled policy in `/etc/selinux/`, checked after DAC), so even a full root compromise inside a container lands the attacker in a confined domain like `container_t`, boxed in by rules no in-container root can rewrite.

### Before Rung 3
**Q:** Given the two-gate model, why did `chmod 777 /data` have no effect on an SELinux denial — and which log does the other gate write to when it says no?

**A:** `chmod 777` only opens the **top** gate, the DAC (`rwx`/ownership) check — but the two gates are in series and both must say yes. The denial came from the **bottom** gate: SELinux compared the process's label (`container_t`) against the file's label and found no `allow` rule, so it returned `-EACCES` regardless of the wide-open mode bits, and even for root. When the MAC gate says no, it emits an **AVC denial** to the audit subsystem, which `auditd` writes to `/var/log/audit/audit.log` — that log (searchable with `ausearch -m avc`) is your entire SELinux debugging surface.

### Before Rung 4
**Q:** A file's xattr says `container_file_t`, but the policy's file-context database says the path should be `httpd_sys_content_t`. What does `restorecon` do, and why is `chcon`'s effect on the same file temporary?

**A:** `restorecon` resets the file's `security.selinux` xattr to whatever the **fcontext database** (`/etc/selinux/targeted/contexts/files/file_contexts`) says the path *should* be — so it relabels the file from `container_file_t` to `httpd_sys_content_t`. `chcon` is temporary because it writes the xattr **directly** without touching the policy database: the canonical path→label rule still says something else, so the very next `restorecon` (or a system autorelabel) reverts the file to the database's value. That's the operational split to memorize: `chcon` is a hotfix; `semanage fcontext -a` + `restorecon` updates the database itself and is the permanent fix.

### Before Rung 5
**Q:** Name the field of a context that carries a domain, the tool that changes a label durably (surviving `restorecon`), and the file `restorecon` consults to decide what a path's label should be.

**A:** The **type** field — the third field of `user:role:type:level` — carries the domain; "domain" is just the name for a type applied to a running process (e.g. `container_t`), while the same field on an object is called a type (e.g. `container_file_t`). The durable tool is **`semanage fcontext -a`** (followed by `restorecon` to apply it), because it edits the canonical policy database rather than poking the xattr like `chcon`. `restorecon` consults the **fcontext database** — `/etc/selinux/targeted/contexts/files/file_contexts` — the regex path→default-label map that defines what each path's label should be.

### Before Rung 6
**Q:** In step 7 the log shows `permissive=0`. What changes in steps 6, 7, and 8 in permissive mode — and why does that make permissive dangerous as a "fix"?

**A:** Step 6: the decision is still DENY, but in permissive mode the kernel **returns success** instead of `-EACCES` — nothing is blocked. Step 7: the AVC denial line is still written to `/var/log/audit/audit.log`, now with `permissive=1`. Step 8: the app's write succeeds, so no `Permission denied`, no crash, no `CrashLoopBackOff` — the pod "works." That's exactly why permissive is dangerous as a fix: it only silences the alarm without repairing the mislabel — the volume is still `default_t` and the missing `allow` rule still doesn't exist — so the moment anyone re-enables enforcing (or the node reverts to its configured `SELINUX=enforcing`), the identical outage returns. Permissive is a *discovery* mode for finding every rule an app needs, never the remedy.

### Before Rung 7
**Q:** Two pods run as UID 0 on the same node with SELinux enforcing, sharing a hostPath. Pod A cannot read Pod B's volume. Which field of the context does the isolating, and what differs between the pods?

**A:** The **level** field — the fourth field, specifically its **MCS categories** (`c0`…`c1023`). The container runtime assigns each pod a unique category pair (e.g. Pod A gets `s0:c123,c456`, Pod B gets `s0:c247,c811`) and labels each pod's files with the matching pair. Two contexts must share categories to interact, so even though both processes are the same domain (`container_t`) and both run as UID 0 — making DAC useless here — Pod A's categories don't match the categories on Pod B's files, and the kernel denies the access. This per-instance MCS isolation is exactly what path-based AppArmor has no equivalent for, and what the `:Z` mount flag / `seLinuxOptions.level` automates.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** SELinux is the RHEL-family MAC, so these scenarios need a **disposable Rocky / AlmaLinux / Fedora VM with SELinux `Enforcing`** — **not** Ubuntu/Debian (which ship AppArmor and where `getenforce` returns `Disabled`). Each scenario's intro names the distro. Install helpers once: `sudo dnf install -y policycoreutils policycoreutils-python-utils container-selinux setools-console`. Several setups need `sudo` and some deliberately break things. Run the **Setup**, read the **Situation**, do the **Task**, and prove it with **Verify** — *without* peeking at the solutions. Difficulty rises from Scenario 1 to 6.

### 🟢 Scenario 1 — "Florianopolis: read the labels, find the odd one out" (Easy)
*(Rocky/Alma/Fedora, SELinux Enforcing.)*
**Setup:**
```bash
getenforce   # expected: Enforcing  (if it says Disabled you are on the wrong distro)
sudo mkdir -p /opt/lab-floripa
for f in one two three four; do echo x | sudo tee /opt/lab-floripa/$f >/dev/null; done
sudo chcon -t etc_t /opt/lab-floripa/three   # force ONE file to a different type
ls -Z /opt/lab-floripa
```
**Situation:** You're on a Rocky/Alma/Fedora node with SELinux enforcing. A tenant reports that one file in `/opt/lab-floripa` "behaves differently" from its siblings. All four look identical to `ls -l`. You suspect a label mismatch — the thing `ls -l` cannot show you.

**Your task:** Using SELinux context tooling, identify which file carries a **different type** than the others, and name that type.

**Verify:**
```bash
ls -Z /opt/lab-floripa
# expected: 'three' shows type etc_t; the other three show default_t (the dir's inherited type)
```

### 🟢 Scenario 2 — "Ushuaia: chmod 777 didn't help" (Easy)
*(Rocky/Alma/Fedora, SELinux Enforcing.)*
**Setup:**
```bash
sudo mkdir -p /var/www/html
echo "<h1>hi</h1>" | sudo tee /var/www/html/index.html >/dev/null
sudo chmod 777 /var/www/html/index.html
sudo chcon -t user_home_t /var/www/html/index.html   # clobber the label
ls -Z /var/www/html/index.html   # ...:user_home_t:...  (wrong for a web root)
```
**Situation:** On a Rocky/Alma/Fedora web node, `index.html` returns `403` to the web server even though it's mode `777` and correctly owned. Someone already tried `chmod 777` — no help, because the block is coming from the *second* gate (SELinux), not DAC. The file lives under `/var/www/html`, whose correct label the policy already knows.

**Your task:** Restore the file to the correct SELinux type the policy defines for `/var/www/html`, using the tool that consults the **file-context database** (don't hand-guess the type with `chcon`).

**Verify:**
```bash
ls -Z /var/www/html/index.html
# expected: type httpd_sys_content_t
```

### 🟡 Scenario 3 — "Sucre: the volume label that won't survive" (Medium)
*(Rocky/Alma/Fedora, SELinux Enforcing.)*
**Setup:**
```bash
sudo mkdir -p /opt/lab-sucre/data
echo data | sudo tee /opt/lab-sucre/data/app.log >/dev/null
ls -Z /opt/lab-sucre/data   # default_t — NOT container_file_t
```
**Situation:** A container-style workload needs `/opt/lab-sucre/data` labeled `container_file_t`. A colleague already ran `chcon -t container_file_t`, and it worked — until the nightly `restorecon` sweep reverted the label to `default_t` and the workload broke again. You need a label that is **permanent**.

**Your task:** Make `container_file_t` the **canonical, durable** label for `/opt/lab-sucre/data` (surviving any future `restorecon`), then apply it. Prove durability by deliberately mislabeling with `chcon` and showing `restorecon` restores the correct type.

**Verify:**
```bash
sudo chcon -t default_t /opt/lab-sucre/data/app.log     # deliberately break the label
sudo restorecon -v /opt/lab-sucre/data/app.log          # policy-driven repair
ls -Z /opt/lab-sucre/data/app.log
# expected: type container_file_t (restorecon put it back from the fcontext DB)
```

### 🟡 Scenario 4 — "Trujillo: worked yesterday, broke after reboot" (Medium)
*(Rocky/Alma/Fedora, SELinux Enforcing.)*
**Setup:**
```bash
getsebool container_manage_cgroup      # container_manage_cgroup --> off
sudo setsebool container_manage_cgroup on   # someone set it WITHOUT -P
getsebool container_manage_cgroup      # on ... but only until the next reboot
```
**Situation:** A workload needs the `container_manage_cgroup` SELinux boolean enabled. It works right now, but every time the node reboots the feature breaks and the on-call re-runs a `setsebool` by hand. The change never survives a reboot — the classic "worked yesterday, broke after the node rebooted" ticket.

**Your task:** Make the boolean setting **persistent** so it survives reboots, using the correct flag.

**Verify:**
```bash
sudo semanage boolean -l | grep container_manage_cgroup
# expected: the (current, persisted-default) pair reads (on   ,  on) — both on
```

### 🟠 Scenario 5 — "Cuenca: the confined service denied on a wide-open dir" (Hard)
*(Rocky/Alma/Fedora, SELinux Enforcing; needs container-selinux for the `container_t` domain.)*
**Setup:**
```bash
sudo mkdir -p /opt/lab-cuenca/data
sudo chmod 777 /opt/lab-cuenca/data
ls -Zd /opt/lab-cuenca/data   # default_t (wrong type for container_t to write)
# reproduce the denial: run a writer in the container_t domain
runcon -t container_t bash -c 'echo hello > /opt/lab-cuenca/data/out.txt' 2>&1 || echo "WRITE DENIED"
ls /opt/lab-cuenca/data   # out.txt is absent — it was blocked
```
**Situation:** On a Rocky/Alma/Fedora node, a task in the `container_t` domain must write `/opt/lab-cuenca/data/out.txt`. The directory is mode `777` and root-owned, but the write fails and `out.txt` never appears. `chmod` can't fix a label problem, and even root doesn't bypass SELinux.

**Your task:** Use the audit log (`ausearch` / `audit2why`) to diagnose the denial, determine it is a **mislabel** (not a genuinely-missing policy rule), relabel the directory to the correct type **durably**, then re-run the `container_t` writer and confirm the file appears.

**Verify:**
```bash
sudo ausearch -m avc -ts recent | tail -n 5
# shows: avc: denied { write/create } ... tcontext=...:default_t:... tclass=... permissive=0
runcon -t container_t bash -c 'echo hello > /opt/lab-cuenca/data/out.txt' && cat /opt/lab-cuenca/data/out.txt
# expected: hello  (after the relabel to container_file_t)
```

### 🔴 Scenario 6 — "Maracaibo: two denials, two different fixes" (Expert)
*(Rocky/Alma/Fedora, SELinux Enforcing; needs container-selinux + policycoreutils-python-utils.)*
**Setup:**
```bash
sudo mkdir -p /opt/lab-maracaibo/data
sudo chmod 777 /opt/lab-maracaibo/data
ls -Zd /opt/lab-maracaibo/data     # default_t   (label problem #1)
getsebool container_connect_any    # container_connect_any --> off   (boolean problem #2)
# start a plain listener the confined task will try to reach:
( python3 -m http.server 8093 --bind 127.0.0.1 >/dev/null 2>&1 & )
sleep 1
# reproduce BOTH denials from the container_t domain:
runcon -t container_t bash -c 'echo x > /opt/lab-maracaibo/data/out.txt' 2>&1 || echo "WRITE DENIED"
runcon -t container_t bash -c 'exec 3<>/dev/tcp/127.0.0.1/8093 && echo CONNECT_OK || echo CONNECT_DENIED' 2>&1 || echo "CONNECT DENIED"
```
**Situation:** On a Rocky/Alma/Fedora node, a `container_t` task has **two separate** SELinux problems: it can't write its data dir, and it can't open an outbound TCP connection to a service on `127.0.0.1:8093`. A junior engineer wants to `audit2allow` everything into a custom policy module. You must fix each denial with the **correct, minimal** mechanism — a durable relabel for the file access and a persistent boolean for the network access — leaving **no** hand-written allow rules behind.

**Your task:** Diagnose both AVCs, relabel the data dir to `container_file_t` durably, enable `container_connect_any` persistently, then prove **both** the write and the outbound connection succeed from the `container_t` domain.

**Verify:**
```bash
# write works after the relabel:
runcon -t container_t bash -c 'echo x > /opt/lab-maracaibo/data/out.txt' && cat /opt/lab-maracaibo/data/out.txt   # expected: x
# connection works after the boolean:
runcon -t container_t bash -c 'exec 3<>/dev/tcp/127.0.0.1/8093 && echo CONNECT_OK'   # expected: CONNECT_OK
# and the boolean is persisted:
sudo semanage boolean -l | grep container_connect_any   # expected: (on   ,  on)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Florianopolis: read the labels, find the odd one out"
**Solution:**
```bash
ls -Z /opt/lab-floripa
# system_u:object_r:default_t:s0     one
# system_u:object_r:default_t:s0     two
# unconfined_u:object_r:etc_t:s0     three   ← the odd one: type etc_t
# system_u:object_r:default_t:s0     four
```
**Why this works & what it teaches:** Every file carries a `user:role:type:level` context stored in the `security.selinux` xattr, and `ls -Z` prints it. The **type** (3rd field) is what Type Enforcement decides on — 95% of SELinux troubleshooting is "wrong type." `ls -l` shows mode/owner but never the label, which is exactly why label bugs feel invisible. Here `three` was forced to `etc_t` while its siblings inherited the directory's `default_t`. **Where people go wrong:** staring at `rwx`/owner when the difference lives in a field only `-Z` reveals. **Cleanup:** `sudo rm -rf /opt/lab-floripa`.

### Scenario 2 — "Ushuaia: chmod 777 didn't help"
**Solution:**
```bash
sudo restorecon -v /var/www/html/index.html
# Relabeled /var/www/html/index.html from ...:user_home_t:s0 to ...:httpd_sys_content_t:s0
ls -Z /var/www/html/index.html   # ...:httpd_sys_content_t:s0
```
**Why this works & what it teaches:** SELinux is a second gate *after* DAC — both must pass — so `chmod 777` (a DAC change) can't fix a label denial. `restorecon` resets a file's label to whatever the **file-context database** (`/etc/selinux/targeted/contexts/files/file_contexts`) says the path *should* be; the policy already knows `/var/www/html` → `httpd_sys_content_t`, and the web server's domain (`httpd_t`) has an `allow` rule to read that type. **Where people go wrong:** `chcon -t httpd_sys_content_t` also works but is a hand-typed hotfix; for a path the policy already knows, `restorecon` is the right, guess-free tool. **Cleanup:** `sudo rm -rf /var/www/html/index.html`.

### Scenario 3 — "Sucre: the volume label that won't survive"
**Solution:**
```bash
sudo semanage fcontext -a -t container_file_t "/opt/lab-sucre/data(/.*)?"
sudo restorecon -Rv /opt/lab-sucre/data
ls -Z /opt/lab-sucre/data   # ...:container_file_t:s0
# durability proof:
sudo chcon -t default_t /opt/lab-sucre/data/app.log
sudo restorecon -v /opt/lab-sucre/data/app.log   # reverts to container_file_t
```
**Why this works & what it teaches:** `chcon` writes the xattr **directly** and is temporary — the canonical path→label rule still says something else, so the next `restorecon`/autorelabel wipes it. `semanage fcontext -a` edits the **policy database** of what the path *should* be; `restorecon` then applies that rule, and forever after the database owns the path — a stray `chcon` gets undone. That is the exact hotfix-vs-durable-fix split (`chcon` vs `semanage fcontext`). **Where people go wrong:** relying on `chcon` in automation and getting mysteriously reverted at the next relabel. **Cleanup:** `sudo semanage fcontext -d "/opt/lab-sucre/data(/.*)?"; sudo rm -rf /opt/lab-sucre`.

### Scenario 4 — "Trujillo: worked yesterday, broke after reboot"
**Solution:**
```bash
sudo setsebool -P container_manage_cgroup on
sudo semanage boolean -l | grep container_manage_cgroup   # (on   ,  on)
```
**Why this works & what it teaches:** A boolean is a runtime switch that gates a bundle of `allow` rules. `setsebool NAME on` flips only the **current** (in-memory) value — lost at reboot. The `-P` flag also writes the **on-disk** policy so the setting persists. `semanage boolean -l` shows both values as a pair `(current, persisted)`; without `-P` you'd see `(on, off)` — the tell-tale of a change that will vanish on reboot. **Where people go wrong:** omitting `-P` and re-fixing the same boolean after every reboot. **Cleanup:** `sudo setsebool -P container_manage_cgroup off`.

### Scenario 5 — "Cuenca: the confined service denied on a wide-open dir"
**Solution:**
```bash
# 1) Diagnose: read the AVC and let audit2why explain it.
sudo ausearch -m avc -ts recent | audit2why
#   ... tcontext=...:default_t:... — "Missing type enforcement (TE) allow rule."
#   The subject container_t wants a file the policy only lets it touch as container_file_t → it's a LABEL bug.
# 2) Fix by relabeling (NOT audit2allow), durably:
sudo semanage fcontext -a -t container_file_t "/opt/lab-cuenca/data(/.*)?"
sudo restorecon -Rv /opt/lab-cuenca/data
# 3) Prove it:
runcon -t container_t bash -c 'echo hello > /opt/lab-cuenca/data/out.txt' && cat /opt/lab-cuenca/data/out.txt
```
**Why this works & what it teaches:** The AVC's `tcontext` type (`default_t`) is the culprit: the policy ships `allow container_t container_file_t:file { create write ... }`, but the wide-open volume was `default_t`, for which no rule exists → default-deny, even at mode `777` and even for root. Relabeling to `container_file_t` makes the *existing* rule match. Reading `audit2why` teaches the discrimination: this is a mislabel, so the fix is **relabel**, not a new rule. **Where people go wrong:** piping the denial into `audit2allow` and shipping `allow container_t default_t:file write` — far too broad (it grants container_t write to *all* `default_t`), papering over a simple label mistake. **Cleanup:** `sudo semanage fcontext -d "/opt/lab-cuenca/data(/.*)?"; sudo rm -rf /opt/lab-cuenca`.

### Scenario 6 — "Maracaibo: two denials, two different fixes"
**Solution:**
```bash
# Diagnose both AVCs:
sudo ausearch -m avc -ts recent | audit2why
#   - one denial: tcontext=...:default_t:... file write  → LABEL bug (relabel)
#   - one denial: ...:tcp_socket name_connect... → gated by boolean container_connect_any
# Fix #1 — durable relabel for the file access:
sudo semanage fcontext -a -t container_file_t "/opt/lab-maracaibo/data(/.*)?"
sudo restorecon -Rv /opt/lab-maracaibo/data
# Fix #2 — persistent boolean for the network access:
sudo setsebool -P container_connect_any on
# Prove both:
runcon -t container_t bash -c 'echo x > /opt/lab-maracaibo/data/out.txt' && cat /opt/lab-maracaibo/data/out.txt   # x
runcon -t container_t bash -c 'exec 3<>/dev/tcp/127.0.0.1/8093 && echo CONNECT_OK'                                # CONNECT_OK
sudo semanage boolean -l | grep container_connect_any   # (on   ,  on)
```
**Why this works & what it teaches:** The two denials look similar in the log but demand different remedies. The file-write denial is a **label** problem — the existing `container_t → container_file_t` rule just needs the volume labeled right (`semanage fcontext` + `restorecon`, durable). The network denial is not a missing rule at all; the policy already contains the rule *guarded by a boolean*, so the fix is to flip `container_connect_any` on **persistently** (`setsebool -P`). Neither needs a custom module. This is the core operating skill: read `audit2why`, then choose relabel vs boolean vs (rarely) a real new rule — not `audit2allow` for everything. **Where people go wrong:** generating a broad custom policy module that grants both accesses to all of `default_t`/all ports, masking the real cause and widening the attack surface. **Cleanup:** `sudo setsebool -P container_connect_any off; sudo semanage fcontext -d "/opt/lab-maracaibo/data(/.*)?"; sudo rm -rf /opt/lab-maracaibo; pkill -f 'http.server 8093'`.
