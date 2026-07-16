# Permissions & Ownership, Climbed the Ladder 🪜
### Learning the rwx model from the ground up — deriving *why kubelet refuses your key*, not memorizing chmod numbers

> This is Linux file permissions rebuilt on the Learning Ladder framework. Instead of leading with `chmod 600`, we climb from **why permissions exist** → **the one core idea** → **the machinery in the inode** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every `chmod`/`chown`/`umask` command lives at the TOP of the ladder (Rung 7). You'll understand *what each one writes into the inode* before you run it — and why a world-readable `id_rsa` makes `ssh` and `kubelet` slam the door.

---

# RUNG 0 — The Setup

**What am I learning?**
The Unix permission and ownership model — the `rwxr-xr-x` strings you've stared at in `ls -l` a thousand times — and the commands that change them: `chmod`, `chown`, `chgrp`, `umask`, plus the identity commands `id` and `groups`.

**Why did it land on my desk?**
A very Kubernetes-flavoured morning. You `scp`'d a fresh `id_rsa` to a jump host and `ssh` refused it: `Permissions 0644 for 'id_rsa' are too open`. Then a `kubeadm` bootstrap failed because someone had `chmod 644`'d `/etc/kubernetes/pki/*.key`. Then a pod with `securityContext.runAsUser: 1000` couldn't write to its mounted volume, and the fix turned out to be `fsGroup`. Three different fires, one root cause: **you never really learned the permission model — you memorized `600` and hoped.** Today you learn the mechanism so the fires become predictable.

**What do I already know about it?**
You can read `drwxr-xr-x` well enough to guess "owner can do everything, others can read." You know `chmod +x script.sh` makes a script runnable and `chmod 600` is "the SSH key thing." You know pods have a `runAsUser`. What you *don't* have is a model connecting the three-character groups to numbers, to the two identity fields on every file, to why the *execute* bit means something totally different on a directory — and to what the kernel actually checks, in order, when a process touches a file.

---

# RUNG 1 — The Pain 🔥
### *Why do permissions exist at all?*

Sit with the problem before touching `chmod`. If you understand the pain, the whole model becomes derivable instead of memorizable.

### The problem that forced permissions into existence

Unix was born on a shared machine — many users, one kernel, one filesystem. The instant two humans share a computer, three questions appear and never go away:

- Can Alice read Bob's files? (Should your salary file be readable by the intern?)
- Can a random user overwrite `/bin/login` or `/etc/passwd`? (If yes, they own the machine.)
- Can a normal user run a program that needs root power *just for one task* (like changing their own password, which writes to a root-owned file)?

Without an answer baked into the filesystem itself, a multi-user system is impossible. Every file needs to record **who owns it** and **what everyone else is allowed to do to it.**

### What people did *before* — and why it hurt

There was no "before" that worked. Early single-user systems (DOS, the original microcomputers) simply had **no permissions at all** — every program could touch every file. That's fine for one person on one floppy disk. It is a catastrophe the moment the machine is shared or connected to a network:

```
THE NO-PERMISSIONS WORLD (why it can't scale past one trusted user)

   User A ──┐
   User B ──┼──▶  [ every file, wide open ]  ◀── any process, any user
   User C ──┘         /etc/passwd  ← anyone edits → anyone becomes root
                      ~alice/taxes ← anyone reads
                      /bin/ls      ← anyone replaces with a trojan

   One malicious or buggy program = total compromise.
   No blast radius. No isolation. No accountability.
```

The pain lands hardest on **anyone running a shared or networked machine** — which, in 2026, is *every server you operate*. A Kubernetes node is the ultimate shared machine: dozens of pods from different teams, the kubelet, containerd, etcd, and system daemons all sharing one Linux filesystem. The permission model is the oldest, most load-bearing isolation primitive on that node — the thing underneath namespaces, underneath cgroups, underneath SELinux.

### What breaks without it — in your world specifically

- **`ssh` / `kubelet` won't trust a loose key.** A private key readable by other local users is, to `ssh`, a compromised key. It refuses rather than risk it. Same logic protects `/etc/kubernetes/pki/*.key`.
- **A pod can't isolate its data.** `securityContext.runAsUser` only means something because the filesystem enforces owner/group/other. No permission model → `runAsNonRoot` is meaningless.
- **Shared scratch space becomes a griefing tool.** `/tmp` is writable by everyone; without the *sticky bit*, any user (or pod) could delete another's files there.

> **✅ Check yourself before Rung 2:** In one breath — why can't a normal user be allowed to write `/etc/passwd`, and why does that single restriction require the filesystem itself (not the app) to enforce who-can-do-what?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — the entire model can be *derived* from it:

> **Every file carries an owner, a group, and three permission triads (owner / group / other), each a 3-bit number rwx = 4+2+1; when a process touches the file, the kernel picks the ONE triad matching the process's identity and checks those bits.**

That's the whole trick. Everything else is detail.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"owner, group, and three triads"* → that's the `-rwxr-xr-x` string and the two names in `ls -l`. Nine permission bits = three triads of three.
- *"rwx = 4+2+1"* → the numbers. `rwx`=7, `rw-`=6, `r--`=4, `r-x`=5. `chmod 644` isn't magic, it's `6=rw-`, `4=r--`, `4=r--`.
- *"picks the ONE triad matching the identity"* → the kernel does **not** OR the triads together. It finds the *first* matching class and uses *only* that. This is why removing your own read bit locks *you* out even if "other" can read.
- *"when a process touches the file"* → permissions are checked at **open time**, against the *process's* UID/GID — which is exactly what `runAsUser` sets. The file doesn't know about users named "alice"; it stores a *number* (UID). Identity is numeric.

Once you see that a permission check is just *"match the process's numeric identity to one triad, read three bits,"* every command becomes "which bits am I flipping, in which triad, on whose file."

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then derive: if a file is owned by you and its owner-triad is `---` but its other-triad is `rwx`, can *you* read it? (Careful — the answer surprises people, and it's the whole point of "the ONE triad.")

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. Four things to understand: **(A) where permissions physically live (the inode), (B) how the kernel checks them, (C) why `x` means opposite things on files vs directories, and (D) the special bits.**

## (A) Where the bits actually live: the inode

A filename is not the file. The real file is an **inode** (index node) — a fixed-size record the filesystem keeps for every file. The directory entry just maps a *name* → an *inode number*. All permission and ownership data lives in the inode:

```
THE INODE (the file's real identity card — the filename is just a label pointing here)

   directory entry:  "id_rsa"  ──▶  inode #524301
                                     ┌───────────────────────────────┐
                                     │ mode:  16 bits                 │
                                     │   ┌──────┬─────┬───────────┐   │
                                     │   │ type │spec │  rwxrwxrwx │   │
                                     │   │ (4)  │ bits│  (9 perm)  │   │
                                     │   └──────┴─────┴───────────┘   │
                                     │ owner UID: 0        (root)     │
                                     │ group GID: 0        (root)     │
                                     │ size, timestamps, link count   │
                                     │ pointers to data blocks ──▶▶▶  │
                                     └───────────────────────────────┘

   The "mode" is ONE 16-bit number. In octal it prints as 100600. The part that
   concerns permissions is the trailing FOUR digits, 0600:
        0 = special-bits digit: SUID(4) SGID(2) sticky(1)   ← here: 0 = none
      600 = the 9 rwx bits  →  rw- --- ---  →  owner rw, group nothing, other nothing
   (the leading "100" marks the file type: regular file, S_IFREG)
```

Owner and group are stored as **numbers** (UID/GID). `ls -l` shows names only because it looks each number up in `/etc/passwd` and `/etc/group`. If the name doesn't exist, `ls` prints the raw number — which is exactly what you see inside a container whose UID isn't in the image's `/etc/passwd`.

## (B) The check: how the kernel decides, in strict order

When any process calls `open("id_rsa", O_RDONLY)`, the kernel runs this decision. **Order matters and it stops at the first matching class:**

```
THE PERMISSION CHECK (runs on every open/exec/access — this is the whole ballgame)

   process wants to READ inode #524301
   process identity: euid=1000 (user "alice"), egid=1000, groups={1000, 27}
                      │
                      ▼
   ┌─ Is euid == 0 (root)? ───────────────▶ YES → allow (root bypasses rwx*)
   │                                              (*except exec needs ANY x bit set)
   │  NO
   ▼
   ┌─ Is euid == the file's owner UID? ───▶ YES → check OWNER triad ONLY. Done.
   │                                              (even if group/other are wider!)
   │  NO
   ▼
   ┌─ Is file's GID in my group set? ─────▶ YES → check GROUP triad ONLY. Done.
   │                                              (owner already failed to match)
   │  NO
   ▼
   └─ Use OTHER triad. Done.

   For a READ, the chosen triad must have the r(4) bit. Else → EACCES ("Permission denied").
```

Two consequences engineers trip on constantly:

1. **The triads are not additive.** If you own a file and your owner-triad lacks `r`, you're denied — the kernel never falls through to the group or other triad for you. "But other can read it!" doesn't help; you matched as *owner* and stopped there.
2. **Identity is the *process's* effective UID/GID, not the filename's.** This is the exact hinge Kubernetes turns. `securityContext.runAsUser: 1000` makes the container's processes run with euid=1000, so every file check inside that pod uses the UID-1000 row of this diagram. `fsGroup: 2000` adds GID 2000 to the process's group set *and* chowns the volume's group to 2000 — so the "Is file's GID in my group set?" branch succeeds on mounted storage.

## (C) The `x` bit means DIFFERENT things on files vs directories

This is the single most misunderstood corner of the model. The nine bits are the same nine bits, but a directory is not a file, so the bits *do* different things:

```
                 FILE                          DIRECTORY
   ┌──────────────────────────────┐  ┌────────────────────────────────────┐
 r │ read the file's contents     │  │ LIST the names inside (ls)          │
 w │ modify the file's contents   │  │ ADD/REMOVE/RENAME entries (create,  │
   │                              │  │   delete, mv) — note: deleting a    │
   │                              │  │   file needs w on its DIRECTORY,    │
   │                              │  │   NOT on the file!                  │
 x │ EXECUTE it as a program      │  │ TRAVERSE / enter it (cd, and use it │
   │ (run the binary/script)      │  │   as a path component to reach      │
   │                              │  │   things deeper)                    │
   └──────────────────────────────┘  └────────────────────────────────────┘

   Killer combos on a directory:
     r-x  = you can ls it AND cd through it        (normal, e.g. 755)
     --x  = you can cd/traverse but NOT ls it      ("search-only": you must
            know exact names; you can reach files inside if you know their path)
     r--  = you can ls names but NOT enter or stat them  (nearly useless)
```

This is why `~/.ssh` must be `700` (`rwx------`): you need `x` to enter it and `r`/`w` to manage keys, but **nobody else may even traverse in** to reach your `id_rsa`. `700` on the dir + `600` on the key is defense in depth: even a permission slip on the key is contained because outsiders can't `cd` in. It's also why a directory almost always has `x` wherever it has `r` — `r` without `x` lets you see names you can't use.

## (D) The special bits: the fourth octal digit

Above the nine rwx bits sit three more, shown as a leading octal digit (`chmod 4755`). They repurpose the `x` position in the `ls -l` string:

```
   SUID (4000) — on an executable file
     → the program runs with the FILE OWNER's identity, not the caller's.
       /usr/bin/passwd is SUID-root: you run it, but it acts AS root to edit
       /etc/shadow, then drops back. Shows as  -rwsr-xr-x  (s in owner-x slot).

   SGID (2000) — on an executable: run as the file's GROUP.
              — on a DIRECTORY: new files inside INHERIT the directory's group
                (instead of the creator's primary group). Shown as  drwxr-sr-x.
                This is how shared team/project dirs keep one consistent group.

   Sticky (1000) — on a DIRECTORY: only a file's OWNER (or root) may delete/rename
                it, even though the dir is world-writable. /tmp is the canonical
                case:  drwxrwxrwt  (t in other-x slot). Everyone can create files;
                nobody can nuke someone else's.
```

Capital vs lowercase in the string tells you whether the underlying `x` is also set: `-rws` = SUID **and** owner-x; `-rwS` = SUID set but owner-x **off** (usually a mistake). Same for `t` vs `T` on the sticky bit.

The Kubernetes tie: **`/tmp`'s sticky bit is the model for pod ephemeral storage.** A pod's `emptyDir` and the node's shared scratch behave like `/tmp` — multiple writers, but the sticky bit stops one pod's process from deleting another's files by name. SGID directories mirror how `fsGroup` forces a consistent group onto everything a pod writes to a shared PV.

> **✅ Check yourself before Rung 4:** Draw the check-order diagram from memory. Then: (1) which triad does the kernel use for a process that owns the file but isn't root? (2) On a directory, which bit do you need to `cd` in, and which to `ls`? (3) What does SUID on `/usr/bin/passwd` actually change about the running process?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now the jargon has somewhere to land. Every term is just a label for a part of the picture you already hold.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **inode** | The on-disk record holding a file's mode, UID, GID, timestamps, block pointers | Where all permission data physically lives (Rung 3A) |
| **mode** | The 16-bit number: file-type + special bits + 9 rwx bits | The whole permission field of the inode |
| **triad / class** | One 3-bit group: owner, group, or other | The three columns the kernel chooses among |
| **owner (user)** | The UID that owns the file | The "owner triad" branch of the check |
| **group** | The GID associated with the file | The "group triad" branch |
| **other (world)** | Everyone who's neither owner nor in the group | The fallback triad |
| **UID / GID** | The *numbers* behind a user/group name | Stored in the inode; matched against the process's identity |
| **euid / egid** | *Effective* UID/GID of the running process | The identity the check compares against (what SUID/`runAsUser` set) |
| **rwx** | read(4) / write(2) / execute(1) permission bits | The three bits inside each triad |
| **octal / numeric mode** | Permissions as base-8 digits (e.g. 755) | A shorthand for the 9 (or 12) bits |
| **symbolic mode** | Relative edits like `u+x`, `g-w`, `o=r` | A different *notation* for the same bits |
| **SUID (setuid)** | "Run as the file's owner" bit (4000) | Rewrites the process's euid at exec (Rung 3D) |
| **SGID (setgid)** | "Run as file's group" / "inherit dir group" bit (2000) | euid's group OR directory group-inheritance |
| **sticky bit** | "Only owner may delete" on a dir (1000) | Restricts unlink in world-writable dirs |
| **umask** | A mask of bits to *remove* from default perms on new files | Applied at file *creation*, before the inode is written |
| **chmod** | Command that writes new permission bits into the mode | Edits the 9/12 bits |
| **chown / chgrp** | Commands that change the owner UID / group GID | Edits the UID/GID fields |
| **`fsGroup`** | K8s field: supplemental GID + chgrp of mounted volumes | Makes the *group* triad succeed for pod storage |
| **`runAsUser` / `runAsGroup`** | K8s fields setting the container process euid/egid | Sets the identity the kernel check compares against |

### The big unlock: which terms are the *same kind of thing*

New learners drown thinking these are unrelated. They're not. Group them:

```
GROUP 1 — "The permission bits, three notations for ONE thing":
   rwx string  =  octal number  =  symbolic edits
   -rw-r--r--  =  644           =  u=rw,go=r
   (ls shows it, chmod 644 sets it, chmod g-w edits it — same 9 bits)

GROUP 2 — "Identity: name vs number, always the number underneath":
   username "alice" = UID 1000    |    group "devs" = GID 27
   The inode stores the NUMBER. runAsUser sets the NUMBER. ls shows the NAME.

GROUP 3 — "The three special bits, one octal digit":
   SUID(4) + SGID(2) + sticky(1)  →  the 4th digit in chmod 4755 / 2775 / 1777

GROUP 4 — "Commands that edit the inode's identity fields":
   chown (UID), chgrp (GID), chown user:group (both at once)

GROUP 5 — "Things that set the PROCESS identity the check runs against":
   SUID/SGID (Linux) ≡ runAsUser/runAsGroup/fsGroup (Kubernetes)
   Same knob, one turned by a file bit, the other by pod YAML.
```

Hold those five groups and you hold the entire vocabulary. The most important realization: **`755`, `rwxr-xr-x`, and `u=rwx,go=rx` are the identical nine bits in three costumes** — so `chmod` "numeric vs symbolic" is a notation choice, never a capability difference.

> **✅ Check yourself before Rung 5:** Without looking — write `rw-r-----` as an octal number, then as a symbolic `chmod` argument. (If you can round-trip all three notations, Group 1 is solid.)

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; one traced action sears the model in. Let's trace the exact failure from Rung 0: **`ssh -i id_rsa user@host` when `id_rsa` is mode `0644`** — and then the successful `600` case. This is the same check `kubelet` runs on `/etc/kubernetes/pki`.

**Step 1 — You run `ssh -i id_rsa user@host`.**
The `ssh` client process starts with *your* identity: say euid=1000 (alice), egid=1000, group set {1000}.

**Step 2 — `ssh` calls `open("id_rsa", O_RDONLY)`.**
Before trusting the key, `ssh` also `stat()`s it to inspect the mode — this is a deliberate client-side safety check, layered *on top of* the kernel's own check.

**Step 3 — The kernel runs the permission check (Rung 3B).**
The inode says owner=1000, group=1000, mode `100644` → owner `rw-`, group `r--`, other `r--`. Process euid 1000 == owner 1000 → kernel uses the **owner triad** `rw-`. It has `r`. The kernel *allows* the read. So far, so fine — the OS would let `ssh` read it.

**Step 4 — `ssh`'s OWN check overrules the kernel.**
`ssh` looks at the mode it just `stat`'d and sees the **group and other triads have `r`** — meaning *other local users could read this private key*. `ssh` treats that as a compromised key and **refuses**, printing:

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@ WARNING: UNPROTECTED PRIVATE KEY FILE! @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Permissions 0644 for 'id_rsa' are too open.
This private key will be ignored.
```

**Step 5 — You fix it: `chmod 600 id_rsa`.**
`chmod` writes new bits into the inode's mode: `100600` → owner `rw-`, group `---`, other `---`. Only the UID that owns it can read it; nobody else can even see the bytes.

**Step 6 — Re-run `ssh`. Now both checks pass.**
Kernel: euid 1000 == owner → owner triad `rw-` has `r` → allow. `ssh`'s safety check: group and other are `---` → key is protected → proceed with authentication. Connection continues.

```
VISUAL OF THE TRACE

  chmod state:  id_rsa = 0644  (rw-r--r--)
        │
        ▼
   ssh open()  ──▶  KERNEL check: euid==owner, owner has r  → ALLOW ✅
        │
        ▼
   ssh's OWN stat check: group=r OR other=r ?  → YES  → REFUSE ❌
        │                                         "too open, ignored"
        ▼
   you: chmod 600 id_rsa   (rw-------)
        │
        ▼
   ssh open()  ──▶  KERNEL: owner has r → ALLOW ✅
        │
        ▼
   ssh's stat check: group=--- , other=--- → protected → PROCEED ✅  🔒

  Same story for kubelet + /etc/kubernetes/pki/*.key:
  kubelet reads the key, but the component/kubeadm treats world/group-readable
  private keys as a fatal misconfig — a loose key is a leaked key.
```

The lesson the trace makes concrete: **the kernel's rwx check and an application's own stricter policy are two separate gates.** `chmod 600` didn't just satisfy the kernel (which was already happy) — it satisfied `ssh`'s defense-in-depth rule that *private key material must be unreadable by anyone but its owner*. Kubernetes components apply the same reasoning to `/etc/kubernetes/pki/*.key` and to a `kubeconfig` (which embeds client certs/tokens — hence `600`).

> **✅ Check yourself before Rung 6:** At `0644`, the *kernel* was willing to let `ssh` read the key — so what exactly rejected it, and why is that a smart design rather than the OS being too permissive? (Name the two separate gates.)

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand rwx best by seeing where it stops and richer models begin.

### The alternative: ACLs, and beyond them, MAC (SELinux/AppArmor)

The classic rwx model has a hard limit: it can express permissions for **exactly three identities** — one owner, one group, everybody else. The moment you need *"alice and bob get write, carol gets read, nobody else anything,"* three triads can't hold it. Two richer systems exist:

- **POSIX ACLs** (`getfacl`/`setfacl`) — Access Control Lists — bolt *additional* named-user and named-group entries onto the inode. They extend the same *discretionary* model (the owner decides). An `ls -l` shows a trailing `+` (e.g. `-rw-rw-r--+`) when ACLs are present.
- **MAC — Mandatory Access Control** (SELinux, AppArmor) — a *separate* label-based system where a central policy, not the file owner, decides — and it can override rwx entirely. This is a different axis, not a bigger rwx.

```
THE LAYERS OF "CAN THIS PROCESS TOUCH THIS FILE?"  (checked top to bottom; ALL must pass)

   1. DAC — rwx bits + ACLs         ← this document. Owner-controlled ("discretionary").
   2. Linux capabilities           ← can root-ish powers be split? (CAP_DAC_OVERRIDE
                                       lets a process bypass layer 1 entirely)
   3. MAC — SELinux / AppArmor      ← central policy. Can DENY even when rwx says yes.

   A pod write to a hostPath can pass rwx but still be blocked by SELinux type
   enforcement — that's layer 3 vetoing layer 1. They are independent gates.
```

### What rwx can do that the alternatives can't (and vice versa)

| The task | rwx (this doc) | POSIX ACLs | SELinux (MAC) | Why the difference |
|---|---|---|---|---|
| Owner/group/other access | ✅ | ✅ | ✅ | rwx is the base everything builds on |
| Per-*named*-user grants | ❌ | ✅ | ✅ | rwx has only 3 identity slots |
| Universally present, zero setup | ✅ | ⚠️ (needs FS support/`acl` mount) | ⚠️ (needs policy) | rwx is in every inode, always |
| SUID/SGID/sticky semantics | ✅ | ❌ (orthogonal) | ✅ (via policy) | Special bits are an rwx feature |
| Override the file owner's wishes | ❌ | ❌ | ✅ | MAC is *mandatory*; DAC is *discretionary* |
| Confine a compromised root process | ❌ | ❌ | ✅ | rwx trusts root completely |

The pattern in the "why": **rwx is small, universal, and owner-controlled by design.** Its three-identity limit isn't a bug — it's the trade that made it simple enough to live in every inode of every Unix ever shipped. ACLs add identities; MAC adds a second, non-negotiable authority. Both are *extra layers on top of*, not replacements for, the rwx bits you're learning here.

### When would I NOT lean on plain rwx?

- **Complex shared access** (many named users, mixed rights) → reach for ACLs; contorting groups to fake it gets unmaintainable.
- **Untrusted multi-tenant nodes / defense against a root-level compromise** → you *need* MAC (SELinux/AppArmor) and capabilities; rwx alone trusts root and can't confine it.
- **But for ~95% of daily K8s node work** — key files, kubeconfigs, pki, volume ownership, `runAsUser`/`fsGroup` — plain rwx *is* the tool, and the richer layers are noise until you actually hit rwx's limits.

**One-sentence "why this over that":**
> Use plain rwx for the near-universal case of owner/group/other file access (keys, certs, volumes, `runAsUser`); add ACLs only when you need per-named-user grants, and rely on MAC (SELinux/AppArmor) only when you must override the owner or confine root — because those are different, higher gates, not a bigger rwx.

> **✅ Check yourself before Rung 7:** Explain to an imaginary colleague why an SELinux policy can block a pod from reading a file even though `ls -l` shows `rw-r--r--` and the pod's UID owns it — i.e., why rwx being satisfied is *necessary but not sufficient*. (Hint: independent gates, discretionary vs mandatory.)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each is a **hypothesis you commit to first**, then verify. Predicting-before-running is what converts "I typed `chmod`" into "I understand the inode." For each: read the prediction, cover the outcome, decide if you agree, *then* run it.

Safe sandbox — everything below runs as a normal user in a scratch dir (Ubuntu 22.04 / any modern Linux). The SUID/mount examples note where you need root.

```bash
mkdir -p ~/perm-lab && cd ~/perm-lab
```

---

## Prediction 1 — Reading `ls -l` and round-tripping numeric ⇄ symbolic (the normal case)

> **My prediction:** "If I create a file, `chmod 644` it, and read `ls -l`, then the string will be `-rw-r--r--`, and `chmod u=rw,go=r` on a fresh copy will produce the *identical* string — *because* `644` and `u=rw,go=r` are two notations for the same nine bits: owner `rw-`(6), group `r--`(4), other `r--`(4)."

```bash
touch report.txt copy.txt
chmod 644 report.txt
chmod u=rw,go=r copy.txt
ls -l report.txt copy.txt
# -rw-r--r-- 1 alice alice 0 Jul 16 10:00 copy.txt
# -rw-r--r-- 1 alice alice 0 Jul 16 10:00 report.txt
#  ^type
#  │ ^^^ owner rwx = rw-
#  │    ^^^ group  = r--
#  │       ^^^ other= r--
```

Read the string field by field: char 1 = type (`-` file, `d` dir, `l` symlink); chars 2-4 = owner triad; 5-7 = group; 8-10 = other. The two names are **owner** then **group**.

**Verify:** Both lines are byte-identical `-rw-r--r--`. If they differ, you mis-decoded an octal digit — redo the 4/2/1 sum. This proves Group 1 from the vocab map: numeric and symbolic are the same bits.

---

## Prediction 2 — The `x` bit on a *directory* controls traversal, not reading (the "aha" case)

> **My prediction:** "If I make a directory `r--` (remove its `x`), then even though I can `ls` the *names* inside, I will NOT be able to `cd` into it or read any file within by path — *because* on a directory `r`=list-names but `x`=traverse/enter, and without `x` the kernel can't use the dir as a path component."

```bash
mkdir vault && echo "secret" > vault/data.txt
chmod 400 vault/data.txt      # file itself is readable by owner
chmod 400 vault               # dir = r-------- (r but NO x)
ls -ld vault                  # dr-------- ... vault
ls vault                      # data.txt   ← r lets you SEE the name
cat vault/data.txt            # cat: vault/data.txt: Permission denied  ← no x = can't traverse
cd vault                      # bash: cd: vault: Permission denied
```

Now restore traversal and watch it flip:

```bash
chmod 500 vault               # r-x: add the traverse bit back
cat vault/data.txt            # secret     ← now the path works
```

**Verify:** With `400` on the dir you can `ls` names but every *path* through it (`cat`, `cd`) fails; with `500` it works. If `cat` succeeded at `400`, you're likely `root` (root bypasses rwx) — retry as a normal user. This is exactly why `~/.ssh` needs `700`, not `600`: without `x` you can't enter your own key directory.

---

## Prediction 3 — `umask` decides default permissions at *creation* (the mechanism-behind-the-scenes case)

> **My prediction:** "If my `umask` is `022`, then a new file will be born `644` and a new directory `755` — *because* umask is a set of bits *subtracted* from the base (666 for files, 777 for dirs), and 022 strips write from group and other. If I tighten umask to `077`, new files will be `600` — the pattern SSH wants by default."

```bash
umask                         # 0022   ← current mask
touch default_file; mkdir default_dir
ls -l  default_file           # -rw-r--r--  (666 & ~022 = 644)
ls -ld default_dir            # drwxr-xr-x  (777 & ~022 = 755)

umask 077                     # tighten: strip ALL group+other bits
touch private_file; mkdir private_dir
ls -l  private_file           # -rw-------  (666 & ~077 = 600)
ls -ld private_dir            # drwx------  (777 & ~077 = 700)
```

**Verify:** With `022` you get `644`/`755`; with `077` you get `600`/`700`. If new files came out `666`, your umask didn't apply to this shell — `umask` is per-process/shell, not persistent (set it in `~/.bashrc` or `/etc/profile` to make it stick). The takeaway: files are never *born* executable (base is 666, not 777) — that's a deliberate safety default, and why `chmod +x` is always an explicit act.

---

## Prediction 4 — `chown`/`chgrp` need root, and this is what `fsGroup` automates (the failure + K8s case)

> **My prediction:** "If I, as a normal user, try to `chown` a file to root, it will FAIL with `Operation not permitted` — *because* giving away ownership is a privileged act (only root may change a file's owner UID); but I *can* `chgrp` to a group I belong to. And this exact chgrp-to-a-shared-group is what Kubernetes `fsGroup` does automatically to a mounted volume."

```bash
touch owned.txt
chown root owned.txt          # chown: changing ownership of 'owned.txt':
                              #   Operation not permitted   ← unprivileged: denied
id -Gn                        # list MY groups, e.g.: alice sudo docker
chgrp docker owned.txt        # succeeds IF you're in 'docker'
ls -l owned.txt               # -rw-r--r-- 1 alice docker 0 ... owned.txt
                              #                    ^^^^^^ group changed, owner unchanged
```

The Kubernetes parallel, made explicit:

```yaml
# A pod that CANNOT write its volume until fsGroup fixes the group:
securityContext:
  runAsUser: 1000       # process euid = 1000  (not a file owner of the PV)
  runAsGroup: 3000      # process egid = 3000
  fsGroup: 2000         # kubelet chgrp's the mounted volume to GID 2000 AND
                        # adds 2000 to the process's supplementary group set
# Result: the volume becomes group-owned by 2000, group perms allow rwx,
# and the process (member of 2000) passes the GROUP-triad branch of Rung 3B.
```

**Verify:** `chown root` fails for you but `chgrp <your-group>` succeeds — proving *owner change = privileged, group change = allowed within your groups*. If `chown root` *succeeded*, you're root (or have `CAP_CHOWN`). Then connect the dots: `fsGroup` is `chgrp` + a supplementary-group grant, performed by the kubelet at mount time so an unprivileged pod UID can write shared storage.

---

## Prediction 5 — SUID makes a program run as the *file owner*, which is why `passwd` works (the special-bit case)

> **My prediction:** "If I inspect `/usr/bin/passwd`, then it will show an `s` in the owner-execute slot (`-rwsr-xr-x`) and be owned by root — *because* editing `/etc/shadow` (mode `640`, root-owned) requires root, yet any user must change their own password; SUID-root lets the `passwd` process temporarily assume root's identity. A normal binary like `id` has no such bit."

```bash
ls -l /usr/bin/passwd         # -rwsr-xr-x 1 root root ... /usr/bin/passwd
#                                   ^ the 's' = SUID: run as owner (root)
ls -l /etc/shadow             # -rw-r----- 1 root shadow ... /etc/shadow  (mode 640: no 'other')
ls -l /usr/bin/id             # -rwxr-xr-x 1 root root ... /usr/bin/id   (plain x, no SUID)

# See the identity swap for yourself — SUID demo you can safely build as root:
sudo cp /bin/cat /tmp/scat
sudo chmod 4755 /tmp/scat     # 4000 = SUID; 755 = rwxr-xr-x  → -rwsr-xr-x
ls -l /tmp/scat               # -rwsr-xr-x 1 root root ... /tmp/scat
/tmp/scat /etc/shadow         # a NORMAL user can now read root-only /etc/shadow!
                              # (because scat runs with euid=root via SUID)
sudo rm /tmp/scat             # CLEAN UP — a SUID-root cat is a real security hole
```

**Verify:** `passwd` shows `-rwsr-xr-x`; your SUID `scat` lets a non-root user read `/etc/shadow` that plain `cat` cannot. If the `s` shows as capital `S`, the owner-`x` bit is off (SUID set but not executable-by-owner — usually a mistake). The security lesson lands hard: **an attacker who can create a SUID-root binary owns the box** — which is exactly why Kubernetes lets you drop it with `allowPrivilegeEscalation: false` and `securityContext.capabilities`, and why `no_new_privs`/read-only rootfs matter.

---

## Prediction 6 — The sticky bit protects shared dirs, the `/tmp` = ephemeral-storage model (the K8s tie-in case)

> **My prediction:** "If I look at `/tmp`, then it will show a trailing `t` (`drwxrwxrwt`) — world-writable but sticky — *because* every user (and every pod's node-level scratch) must create files there, yet the sticky bit ensures only a file's *owner* can delete it, so one tenant can't wipe another's data. Without the sticky bit, world-writable = anyone-deletes-anything."

```bash
ls -ld /tmp                   # drwxrwxrwt 20 root root ... /tmp
#                                       ^ the 't' = sticky: delete only if you own the file

# Reproduce the danger and the fix in your lab:
mkdir shared && chmod 777 shared          # world-writable, NO sticky (drwxrwxrwx)
touch shared/alice_file
# (as another user, they could 'rm shared/alice_file' even though they don't own it)

chmod +t shared                            # add sticky → drwxrwxrwt
ls -ld shared                              # drwxrwxrwt ... shared
# now only the file's owner (or root) can delete files inside, even though
# the directory itself is still writable by everyone.
```

Bonus — the SGID-directory cousin, which mirrors `fsGroup`'s "consistent group" behavior:

```bash
mkdir team && sudo chgrp docker team
chmod 2775 team                            # 2000 = SGID on a dir → drwxrwsr-x
touch team/newfile
ls -l team/newfile                         # group is 'docker' (INHERITED from dir),
                                           # NOT your primary group — that's SGID.
```

**Verify:** `/tmp` shows `t`; your `shared` dir gains `t` after `chmod +t`; and files created in the SGID `team` dir inherit the `docker` group instead of your primary group. If a new file in `team/` shows *your* primary group, the SGID bit didn't take (recheck the `2` in `2775`). Tie it home: **a pod's `emptyDir` and node scratch behave like sticky `/tmp`** (many writers, owner-scoped deletes), and **SGID directories are the filesystem-native version of what `fsGroup` enforces** on a shared PersistentVolume.

---

## The prediction habit, generalized

Fill this in for anything new you try with permissions:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

**Handy identity/context commands you'll lean on** (who am I, to the kernel?):

```bash
id                            # uid=1000(alice) gid=1000(alice) groups=1000(alice),27(sudo),999(docker)
id -u                         # 1000        (just the numeric UID)
id -Gn                        # alice sudo docker   (all my group NAMES)
groups                        # alice sudo docker   (same, older command)
whoami                        # alice

# The identity of a RUNNING process — the exact UID a permission check uses.
# This is how you confirm what runAsUser actually produced inside a container:
cat /proc/$$/status | grep -E '^(Uid|Gid|Groups)'
#   Uid:  1000  1000  1000  1000     (real, effective, saved-set, filesystem)
#   Gid:  1000  1000  1000  1000
#   Groups: 27 999 1000

# For a specific PID (e.g. a container's main process seen from the node):
cat /proc/1234/status | grep Uid    # Uid: 1000 1000 1000 1000
```

The Kubernetes payoff: when a pod's `securityContext.runAsUser: 1000` is set, `cat /proc/<pid>/status | grep Uid` on the node (or `id` inside the container) will show `1000` in all four columns — that number *is* the identity every rwx check in Rung 3B compares against. If a volume write fails, this is your first probe: what UID/GID is the process *actually* running as, and does the file's owner/group triad grant that identity `w`?

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> Every file's inode stores an owner UID, a group GID, and nine rwx bits split into owner/group/other triads (plus three special bits), and the kernel enforces access by matching a process's effective identity to the *single* applicable triad — which is exactly the primitive Kubernetes drives with `runAsUser`, `runAsGroup`, and `fsGroup`.

**Explain it to a beginner in 3 sentences:**
> 1. Every file records *who owns it* (a user and a group, stored as numbers) and three sets of read/write/execute permissions — one for the owner, one for the group, one for everyone else — and you read or edit those with `ls -l`, `chmod`, and `chown`.
> 2. When a program tries to touch a file, the kernel figures out which single set applies to *that program's* identity and checks just those three bits, which is why a private SSH key or a Kubernetes kubeconfig must be `600` (owner-only) — anything looser and `ssh`/`kubelet` treat it as leaked and refuse it.
> 3. Kubernetes' `securityContext.runAsUser`/`runAsGroup`/`fsGroup` are nothing exotic — they just set the UID/GID a container's processes run as (and re-group its volumes), so the same ancient Linux permission check decides what a pod can read and write.

**Map of sub-capability → the one core idea (all one pattern — "match identity to a triad, read the bits"):**

```
Reading ls -l          → decode the 9 bits into owner/group/other triads
chmod numeric (755/644 → set all bits at once via octal (rwx = 4+2+1)
  600/400)             → 600 = owner-only rw (keys, kubeconfig); 400 = read-only (ca.key)
chmod symbolic         → edit specific bits relatively (u+x, g-w, o=r, a+x)
chown / chgrp          → change the inode's identity fields (owner UID / group GID)
umask                  → decide which default bits are stripped at file creation
SUID / SGID            → make a process run as the file's owner/group (≡ runAsUser)
sticky bit             → owner-scoped deletes in shared dirs (≡ /tmp ≡ pod emptyDir)
id / groups / /proc    → discover the process identity the check runs against
```

Nine sub-skills, one idea: *the inode names an identity, and the kernel checks one triad's rwx bits against the process's identity.*

**Which rung will I most likely need to revisit hands-on?**

Be honest — the two usual suspects:

- **Rung 3C (x on directories) and 3B (the single-triad check).** These feel intuitive until they don't: "I own the file but can't read it" and "I can `ls` but can't `cat`" both violate naive intuition. The fix is Predictions 1-2 — run them, break them, watch the kernel behave exactly as the diagram says.
- **Rung 3D → Kubernetes (SUID/SGID/sticky ↔ runAsUser/fsGroup).** Stating "runAsUser sets the euid" is easy; *proving* it with `cat /proc/<pid>/status | grep Uid` on a real node, and predicting a volume-permission failure *before* it happens, takes a couple of reps. Do Predictions 4 and 6 against an actual pod.

If either check-yourself felt shaky, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [users-groups-sudo](06-users-groups-sudo.md) — where UIDs/GIDs actually come from (`/etc/passwd`, `/etc/group`, `/etc/shadow`) and how `sudo` grants the root that SUID mimics
- [file-operations](04-file-operations.md) — inodes, hard/soft links, and why deleting a file needs write on its *directory*, not the file
- [capabilities](17-capabilities.md) — splitting root's all-or-nothing power (e.g. `CAP_DAC_OVERRIDE` bypasses rwx; `CAP_CHOWN` allows the `chown` you couldn't do)
- [selinux](20-selinux.md) — the mandatory layer that can veto a file access even when rwx says yes
- [storage-mounts](15-storage-mounts.md) — how `fsGroup`, mount options, and OverlayFS interact with file ownership on volumes
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full map tying `runAsUser`/`fsGroup`/pki permissions back to these Linux primitives for node triage
