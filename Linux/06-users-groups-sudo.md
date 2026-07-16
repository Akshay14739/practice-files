# Users, Groups & sudo
### Learning Linux identity from the ground up — who a process *is*, how the kernel decides, and why `runAsUser: 1000` is just a number

> This is the identity rung of your Linux ladder. Before permissions (`rwx`) can mean anything, the kernel has to answer a more basic question: *who is this process?* That "who" is a **number** — a UID — and everything else (usernames, groups, sudo, PAM) is scaffolding humans built around that number. We climb from **why identity exists** → **the one idea** → **the machinery** → and only at the top, the commands. Each rung ends with a "check yourself" question. If you can answer it in your own words, climb on.
>
> **The one rule:** every command in Rung 7 sits at the TOP of the ladder. You'll understand *what it does to the machinery* before you run it.

---

# RUNG 0 — The Setup

**What am I learning?**
Linux **users, groups, and `sudo`** — the identity layer. What a UID and GID actually are, how `/etc/passwd`, `/etc/shadow`, and `/etc/group` store them, the difference between a human login and a service account, and how `sudo` lets a normal user borrow root's power in a scoped, audited way.

**Why did it land on my desk?**
You're a Kubernetes platform engineer. A `kubectl describe pod` showed you `securityContext: { runAsUser: 1000 }` and you nodded along without really knowing what 1000 *is* on the node. Then a security review asked: "Why is etcd's data directory owned by `etcd:etcd` and not root? Can the `kubelet` process read your CA key?" Then a teammate needed to restart kubelet on prod nodes but you were told "don't give them full root — scope it." Every one of those is a users/groups/sudo question. You've been running `kubectl` for six years; now you need to know who the processes on the *node* actually are.

**What do I already know?**
You know the previous rung — the `rwx` permission model, `chmod`, `chown`, that files have an owner and a group. You know root is all-powerful. You've typed `sudo apt install` a thousand times. What you *don't* have yet is the model underneath: that "owner" is a number, that root is just UID 0, and that `sudo` is an ordinary program — not a kernel feature — that you can configure to a razor's edge.

---

# RUNG 1 — The Pain 🔥
### *Why does an identity system exist at all?*

Sit with the problem before touching a command. If you understand the pain, the entire design of `/etc/passwd` and `sudo` stops needing memorization — you can *derive* it.

### The problem that forced this into existence

A computer runs code from many sources at once: your shell, a web server, a database, a backup job, and — on a Kubernetes node — kubelet, containerd, etcd, kube-proxy, and dozens of containers. They all share **one kernel, one filesystem, one memory space, one network stack.** The kernel needs a way to answer, for *every single action*:

- Is this process allowed to read `/etc/kubernetes/pki/ca.key`?
- May it kill that other process?
- Can it write to etcd's data directory?
- Can it bind to port 443?

Without an identity attached to each process, the answer is always "yes to everything," and any bug in any program can trash the whole machine. You need a **cheap, universal label** the kernel can stamp on every process and check on every operation — millions of times per second.

### What people did *before* — and why it hurt

Early multi-user systems (1970s timesharing) had many humans sharing one physical machine. The very first need was simply *billing and blame*: which account ran up the CPU bill, whose files are whose. But the killer requirement was **isolation** — student A must not read professor B's exam file. The design that won was brutally simple: **give every account an integer, and make the kernel compare integers.**

Why an integer and not a name? Because the kernel does this check constantly and a string comparison ("does `alice` equal `alice`?") is far more expensive than an integer comparison (`1000 == 1000`). Names are for humans; numbers are for the kernel. That split — **name for people, number for the machine** — is the original sin (in the good sense) that explains *everything* downstream, including why a container's `runAsUser: 1000` needs no matching name at all.

### What breaks without it

```
NO IDENTITY LAYER = NO ISOLATION

┌────────────────────────────────────────────────┐
│  Every process runs as "the computer"          │
│                                                 │
│  web server bug ──▶ reads /etc/shadow          │
│  backup script  ──▶ deletes the database        │
│  a container    ──▶ reads the host's CA key     │
│  student A      ──▶ opens professor B's exam    │
│                                                 │
│  No owner = no boundary = no security.          │
└────────────────────────────────────────────────┘
```

**Who feels the pain most?** The platform/ops engineer — you. Developers write the app; you're the one who has to guarantee that a compromised container *can't* read the node's private keys, that a junior can restart kubelet *without* being able to `rm -rf /`, and that when the auditor asks "who can become root on these nodes?" you have a precise, defensible answer. Identity is fundamentally an **operator's tool.**

> **✅ Check yourself before Rung 2:** In one breath — why did the designers make the kernel-level identity an *integer* instead of a username string? (Hint: think about how often, and how fast, the kernel has to check it.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this exact sentence. The whole topic can be *derived* from it:

> **On Linux, identity is a set of numbers (a UID and one or more GIDs) that the kernel stamps onto every process; usernames, `/etc/passwd`, groups, and `sudo` are all just human-friendly machinery for managing and switching between those numbers.**

That's the whole trick. Everything else is detail.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"identity is numbers"* → so a container can run as UID `1000` with **no username anywhere** on the host. The name is optional; the number is not. (Your `runAsUser: 1000` mystery — solved already.)
- *"the kernel stamps it onto every process"* → so `ps` can show you an owner for every process, and a process can't lie about its own UID (only the kernel changes it).
- *"UID **and** GIDs (plural)"* → so you belong to a **primary** group and any number of **supplementary** groups, which is exactly why `usermod -aG docker devuser` grants docker access.
- *"usernames and /etc/passwd are human machinery"* → so those files are just **lookup tables** translating name ↔ number. Delete the table entry and the number still works; the name just stops resolving.
- *"sudo is machinery for switching numbers"* → so `sudo` is an ordinary program that (after checking a rulebook) asks the kernel to run a command as UID 0. It's not magic; it's configurable.

Once you see that **every command in this topic is either "read the name↔number table," "edit the table," or "switch which number a process runs as,"** the whole thing collapses into one pattern.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then answer: if identity is really just a number, what does the *username* actually do, and what happens to a running process if you delete its username from `/etc/passwd`? (The process keeps running as its number — the name was only ever a label.)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. Four things to understand: **(A) the numbers the kernel actually carries, (B) the three files that translate numbers ↔ names, (C) how a login turns a name into a running shell with the right numbers, and (D) how `sudo` switches the numbers safely.**

## (A) What the kernel actually carries: the credential set

Every process on Linux has a small bundle of identity numbers attached to it by the kernel, stored in the kernel's process table (visible at `/proc/<pid>/status`). The important ones:

```
A PROCESS'S IDENTITY (what the kernel stamps on it)

┌──────────────────────────────────────────────────────┐
│  PID 4821   (the kubelet process, for example)       │
│                                                       │
│   UID  = 0        ← "who am I"     (0 = root)         │
│   GID  = 0        ← my primary group                  │
│   Groups = 0,1,4  ← supplementary groups (a list!)    │
│                                                       │
│  The kernel checks THESE numbers against a file's     │
│  owner/group/mode on every open(), every kill(), etc. │
└──────────────────────────────────────────────────────┘
```

Two things that surprise newcomers:

1. **There is no username in there.** The kernel neither knows nor cares that UID 0 is called "root." Names live in userspace files, not the kernel.
2. **UID 0 is special *to the kernel itself*.** Most permission checks are simply skipped when the UID is 0. That's *all* root is — the number zero. (Modern kernels refine this with **capabilities**, a later rung, but the baseline mental model is "UID 0 = skip the checks.")

There's also a subtlety pros must know: each process actually carries a **real UID**, an **effective UID**, and a **saved UID**. The *effective* UID is the one used for permission checks; the *real* UID is who originally launched it. This triple is exactly the mechanism that lets `sudo` and `passwd` temporarily act as root — hold that thought for part (D).

## (B) The three files: the name↔number translation tables

The kernel uses numbers; humans use names. Three plain-text files (plus the `getent`/NSS layer) bridge the gap. **They are just databases in text form.**

### `/etc/passwd` — the user table (world-readable)

One line per user. Despite the name, it holds **no passwords** anymore.

```
FORMAT:  username:x:UID:GID:comment:home:shell
              │   │  │   │     │      │     └─ login shell (/bin/bash, /sbin/nologin…)
              │   │  │   │     │      └─────── home directory
              │   │  │   │     └────────────── GECOS/comment (full name, etc.)
              │   │  │   └──────────────────── primary GID
              │   │  └──────────────────────── UID
              │   └─────────────────────────── password placeholder ('x' = "see /etc/shadow")
              └─────────────────────────────── login name

Real examples from a Kubernetes node:
root:x:0:0:root:/root:/bin/bash
etcd:x:998:998:etcd user:/var/lib/etcd:/sbin/nologin
kube:x:997:997::/home/kube:/sbin/nologin
devuser:x:1000:1000:Dev User:/home/devuser:/bin/bash
```

The `x` in field 2 means "the real password hash lives in `/etc/shadow`." This split exists for security — see below.

### `/etc/shadow` — the password/credential table (root-readable only, mode 640)

```
FORMAT:  username:$hash:lastchange:min:max:warn:inactive:expire:
                    │
                    └─ the hashed password, e.g. $6$rounds…$… ($6$ = SHA-512)
                       '*' or '!' here means "no password login possible"

devuser:$6$xf3...$Jk9...:19500:0:99999:7:::
etcd:!:19490:0:99999:7:::            ← '!' = etcd can never log in with a password
```

**Why two files?** `/etc/passwd` must be world-readable — *every* program that wants to turn UID 1000 into the name "devuser" (like `ls -l`) reads it. But you must **never** let the password hashes be world-readable (offline cracking). So the hashes were pulled out into `/etc/shadow`, readable only by root. That separation is the entire reason `shadow` exists.

### `/etc/group` — the group table (world-readable)

```
FORMAT:  groupname:x:GID:member1,member2,…
              │    │  │      └─ SUPPLEMENTARY members (comma list)
              │    │  └──────── GID
              │    └─────────── password placeholder (unused normally)
              └──────────────── group name

docker:x:999:devuser        ← devuser is a SUPPLEMENTARY member of docker
etcd:x:998:
devuser:x:1000:             ← devuser's PRIMARY group (empty member list — see below)
```

**Primary vs supplementary — the classic confusion:**

- Your **primary group** is the single GID written in field 4 of your `/etc/passwd` line. New files you create are owned by it. You are *not* listed in `/etc/group`'s member list for it — the passwd line *is* the membership.
- **Supplementary groups** are the extra ones listed against your name in `/etc/group`'s member column. `usermod -aG docker devuser` adds you to docker's member list here. You get *all* their access simultaneously.

```
                 ┌─ primary GID (in /etc/passwd) ──▶ owns new files
   devuser ──────┤
                 └─ supplementary (in /etc/group) ──▶ docker, sudo, …
                        │
                        └─ ALL active at once → kernel's "Groups" list
```

## (C) The trace of a login: name in, numbers out

How does typing `devuser` + a password become a running bash shell carrying UID 1000? This is where **PAM** enters. *One-line definition:* **PAM (Pluggable Authentication Modules) is the pluggable framework Linux programs call to answer "is this login allowed?" — so `login`, `sshd`, and `sudo` don't each hard-code password logic.**

```
FROM NAME TO NUMBERED SHELL

  You type:  devuser  /  hunter2
       │
       ▼
  ┌─────────────┐   asks   ┌──────────┐  reads  ┌──────────────┐
  │ login/sshd  │ ───────▶ │   PAM    │ ──────▶ │ /etc/shadow  │
  └─────────────┘          └──────────┘         └──────────────┘
       │                        │   hash matches? yes
       │  looks up name ───────▶ /etc/passwd → UID 1000, GID 1000, /bin/bash
       │  looks up groups ─────▶ /etc/group  → also docker(999), sudo
       ▼
  kernel setuid(1000)/setgid(1000)/setgroups(999,27,…)
       │
       ▼
  exec /bin/bash  →  now a shell whose kernel credentials are UID 1000
                      (everything it launches inherits these numbers)
```

The key insight: authentication (PAM checking the hash) and identity assignment (the kernel stamping UID 1000) are **two separate steps**. Once the numbers are stamped, the password is irrelevant — the process simply *is* UID 1000 from then on, and every child it spawns inherits the same numbers.

## (D) How `sudo` switches the numbers — safely

`sudo` is **not a kernel feature.** It's an ordinary executable at `/usr/bin/sudo` — with one crucial property: it is **setuid-root** (its file has the setuid bit set and is owned by root, so it *starts running as root no matter who launches it*). That's the hook that lets it do its job.

```
WHAT sudo ACTUALLY DOES

  devuser runs:  sudo systemctl restart kubelet
       │
       ▼
  /usr/bin/sudo  (setuid bit → process's effective UID becomes 0 immediately)
       │
       ├─▶ 1. Read the rulebook: /etc/sudoers (+ /etc/sudoers.d/*)
       │        "Is devuser allowed to run THIS command as root?"
       │
       ├─▶ 2. If rule needs a password → ask PAM → check /etc/shadow
       │        (unless the rule says NOPASSWD)
       │
       ├─▶ 3. Log the attempt (journald / /var/log/auth.log) — the AUDIT trail
       │
       └─▶ 4. setuid(0), then exec the target command AS ROOT
                systemctl restart kubelet   ← now runs with UID 0
```

Three things make `sudo` powerful *and* safe at once:

1. **It's scoped by a rulebook** (`/etc/sudoers`) — you can allow *only* `systemctl restart kubelet` and nothing else.
2. **It authenticates the human** (via PAM) before switching — so a stolen unlocked terminal still needs the password (unless you unwisely used `NOPASSWD`).
3. **It logs everything** — every `sudo` invocation is recorded, giving you the audit answer "who ran what as root, when."

Contrast with the blunt older tool `su`, which asks for the *target account's* password and hands you a full shell as that user — all or nothing, no per-command scoping, weak logging. `sudo` exists precisely to replace that with least-privilege, per-command, audited elevation.

> **✅ Check yourself before Rung 4:** Draw the picture from memory. (1) Where does the actual password hash live and why is it not in `/etc/passwd`? (2) When you log in, what turns your *name* into a UID, and what turns the UID into a shell? (3) What single bit on the `sudo` binary lets a non-root user momentarily become root, and what stops that from being a security hole?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now that you have the machinery, the jargon has somewhere to land. Every term is just a label for a part of the picture you already understand.

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **UID** | An integer identifying a user; the kernel's real "who am I" | (A) stamped on every process |
| **GID** | An integer identifying a group | (A) primary group in the credential set |
| **root / superuser** | The user whose UID is `0`; permission checks are skipped for it | (A) the special number 0 |
| **effective UID (euid)** | The UID used *right now* for permission checks | (A)/(D) what `sudo` flips to 0 |
| **real UID (ruid)** | The UID that originally launched the process | (A) who you "really" are under sudo |
| **/etc/passwd** | World-readable table: name → UID, GID, home, shell | (B) the user lookup table |
| **/etc/shadow** | Root-only table: name → password hash + aging | (B) where hashes actually live |
| **/etc/group** | World-readable table: group name → GID + members | (B) the group lookup table |
| **primary group** | The single GID in your passwd line; owns new files | (B) passwd field 4 |
| **supplementary group** | Extra groups listed in /etc/group; all active at once | (B) group member column |
| **system/service user** | A user for a daemon, low UID, no login shell | (B) `useradd -r`, nologin shell |
| **interactive user** | A human account with a real shell and home | (B) `useradd -m -s /bin/bash` |
| **nologin** | A fake shell (`/sbin/nologin`) that refuses login | (B) passwd field 7 for daemons |
| **GECOS / comment** | The free-text name field in passwd | (B) passwd field 5 |
| **NSS / nsswitch** | The config (`/etc/nsswitch.conf`) deciding *where* name lookups go (files? LDAP?) | (B/C) the layer above the flat files |
| **getent** | Command that queries the NSS databases the "correct" way | (B) reads passwd/group via NSS |
| **PAM** | Pluggable framework programs call to authenticate a login | (C) the auth step before UID is set |
| **setuid bit** | A file mode bit: run the program as its *owner*, not the caller | (D) what makes `sudo` able to become root |
| **sudo** | Setuid-root program that runs one command as another user per a rulebook | (D) scoped, audited elevation |
| **sudoers** | The rulebook `/etc/sudoers` sudo consults | (D) who may run what |
| **visudo** | The safe editor for sudoers (validates syntax before saving) | (D) how you edit the rulebook |
| **NOPASSWD** | A sudoers tag: allow without asking for a password | (D) skips the PAM prompt |
| **su** | Older tool: become another user with *their* password, full shell | (D) the blunt predecessor to sudo |

### The big unlock: which terms are the *same kind of thing*

Newcomers drown thinking these are 20 unrelated concepts. Group them:

```
GROUP 1 — "The number that IS the identity":
   UID ≈ effective UID ≈ "who the kernel thinks this process is"
   (root is just this number = 0)

GROUP 2 — "The name↔number lookup tables" (plain text files):
   /etc/passwd  +  /etc/group  +  /etc/shadow
   → getent and NSS are just the "correct front door" to read them

GROUP 3 — "Kinds of user, same mechanism, different intent":
   interactive user (has shell+home)  vs  system/service user (nologin, -r)
   → SAME row format in /etc/passwd; only the shell/UID-range differs

GROUP 4 — "Group membership, two flavors of one idea":
   primary group (in passwd)  +  supplementary groups (in /etc/group)
   → both end up in the kernel's one 'Groups' list

GROUP 5 — "Becoming someone else":
   sudo (scoped, per-command, audited)  vs  su (whole shell, their password)
   → both ultimately call setuid(); sudo just wraps it in a rulebook + log

GROUP 6 — "The auth framework everyone calls":
   PAM ← used by login, sshd, AND sudo alike
```

Hold those six groups and you hold the vocabulary. Notice the deep symmetry: **a service user and a human user are the *same kind of row* in the *same file*** — Kubernetes leans on this constantly (etcd, kubelet are just system users), and it's why a container's UID 1000 needs no row at all.

> **✅ Check yourself before Rung 5:** Without looking — what's the difference between a "system user" and a "normal user" *mechanically* (not just in intent)? And which single file makes `usermod -aG docker devuser` take effect?

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Let's trace something you'll do on a real node: **you create a service user for a daemon, then a human devops user, then `sudo` runs a command.** We'll follow the exact bytes that move.

### Trace A — `useradd -r -s /sbin/nologin etcd` creates a service account

**Step 1 — `useradd` picks a UID.**
`useradd` (an ordinary program) sees `-r` (system account), so it scans `/etc/passwd` for the highest *unused* UID *below* the normal-user threshold (`SYS_UID_MAX`, default 999; normal users start at `UID_MIN` 1000). Say it lands on `998`. A matching group `etcd` with GID `998` is created too.

**Step 2 — it appends a row to `/etc/passwd`.**
```
etcd:x:998:998::/home/etcd:/sbin/nologin
```
The `/sbin/nologin` shell means: even if someone knew a password, a login attempt just prints "This account is currently not available" and exits. Daemons don't need a shell.

**Step 3 — it appends to `/etc/group` and writes a locked `/etc/shadow` line.**
```
/etc/group :  etcd:x:998:
/etc/shadow:  etcd:!:19490:0:99999:7:::     ← '!' = no password will ever match
```

**Step 4 — later, etcd's data dir is handed to it.**
```
chown -R etcd:etcd /var/lib/etcd
```
Now the etcd *process* runs as UID 998, and the kernel lets it read/write its own data — but a compromised etcd can't touch `/etc/kubernetes/pki/ca.key` (owned by root). That ownership boundary is the whole security payoff.

### Trace B — a `sudo` command, hop by hop

Setup: `devuser` (UID 1000) is allowed, via a sudoers rule, to restart kubelet.

```
devuser@node:~$ sudo systemctl restart kubelet
```

**Step 1 — the shell execs `/usr/bin/sudo`.** Because the file is **setuid-root** (`-rwsr-xr-x root root`), the kernel sets the new process's *effective* UID to 0 the instant it starts — even though the *real* UID is still 1000 (devuser).

**Step 2 — sudo reads the rulebook.** It parses `/etc/sudoers` and `/etc/sudoers.d/*`, searching for a rule matching *user=devuser*, *host=this node*, *command=`/usr/bin/systemctl restart kubelet`*. It finds:
```
devuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart kubelet
```

**Step 3 — authenticate (or skip).** The rule says `NOPASSWD`, so sudo skips the PAM password prompt. (Without that tag, sudo would call PAM → check `/etc/shadow` → prompt for *devuser's own* password.)

**Step 4 — log it.** sudo writes an audit record to journald / `/var/log/auth.log`:
```
sudo: devuser : TTY=pts/0 ; PWD=/home/devuser ; USER=root ;
      COMMAND=/usr/bin/systemctl restart kubelet
```
This line is your answer to "who restarted kubelet at 3AM?"

**Step 5 — become root and exec.** sudo calls `setuid(0)` to make the *real* UID 0 too, then `exec`s `systemctl restart kubelet`. That command now runs as full root and talks to systemd (PID 1) over D-Bus to bounce the kubelet unit.

**Step 6 — anything NOT in the rule is refused.** If devuser tries `sudo rm -rf /var/lib/etcd`, Step 2 finds no matching rule, sudo prints `Sorry, user devuser is not allowed to execute '/usr/bin/rm …'`, logs the *denial*, and exits non-zero. Least privilege, enforced.

```
VISUAL OF TRACE B

devuser (ruid=1000) ──exec──▶ /usr/bin/sudo  ⟵ setuid-root: euid→0
                                   │
                    ┌──────────────┼───────────────┐
                    ▼              ▼                ▼
             read sudoers    (NOPASSWD →     log to auth.log
             match rule?      skip PAM)       "devuser ran…"
                    │
              yes ──┴──▶ setuid(0) ──exec──▶ systemctl restart kubelet
                                                   │ (now UID 0)
                                                   ▼
                                              systemd bounces kubelet
              no  ──────▶ "not allowed", log denial, exit 1
```

> **✅ Check yourself before Rung 6:** In Trace B, at Step 1 the *effective* UID is already 0 but the *real* UID is still 1000. Why does sudo bother reading the rulebook at all if it's already effectively root? (Hint: the setuid bit gives it the *power*; the rulebook is what makes it *safe* — sudo is voluntarily checking permission it already has.)

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand `sudo` best by seeing exactly where the older way stops. The alternative is **`su`** (substitute user) plus raw file ownership — the way privilege was delegated before `sudo` existed.

### `sudo` vs `su`

```
su:                                  sudo:
  $ su -                               $ sudo <command>
  Password: [ROOT's password]          Password: [YOUR OWN password]
       │                                    │
       ▼                                    ▼
  full root shell,                     ONE command as root,
  no per-command limits,               limited by /etc/sudoers,
  weak logging.                        every call logged.

  Everyone who needs root              Nobody needs the root password;
  must KNOW the root password.         you grant slivers of power per-user.
```

| Question | `su` (older) | `sudo` (modern) |
|---|---|---|
| Whose password? | The *target* account's (usually root) | *Your own* |
| Granularity | All-or-nothing full shell | Per-command, per-user, per-host |
| Audit trail | Weak ("someone became root") | Strong (who ran *what*, when) |
| Revoke one person | Change root's password → breaks everyone | Delete one sudoers line |
| Passwordless automation | Awkward | `NOPASSWD:` on a single command |
| Scope to "restart kubelet only" | ❌ impossible | ✅ one line |

The pattern in the "why": **`su` hands over the *keys to the whole house*; `sudo` hands over *a key to one specific door* and writes down each time you use it.** Everything `sudo` can do that `su` can't traces back to the same structural fact — sudo consults a per-command rulebook *and* logs, whereas su just swaps identity wholesale.

### When would I NOT reach for sudo?

- **A daemon that must run as a service user.** You don't `sudo` a daemon; you set its user in the **systemd unit** (`User=etcd`), which does the `setuid` for you at start. sudo is for *interactive* elevation.
- **Inside a container.** Containers usually have no `sudo` and shouldn't — you set the identity with `securityContext.runAsUser`. sudo would be an escalation risk, not a convenience.
- **When capabilities are the right tool.** If a process needs *just* the power to bind port 80, granting `CAP_NET_BIND_SERVICE` (a later rung) is far tighter than full root via sudo.
- **True automation across many hosts.** Prefer a dedicated service account + SSH keys + a narrow `NOPASSWD` rule, not a human typing sudo.

**One-sentence "why this over that":**
> Use `sudo` when a *human* needs a *specific, audited* slice of root power; use service users + systemd `User=` (or container `runAsUser`, or capabilities) when a *process* needs to run as a non-root identity permanently.

> **✅ Check yourself before Rung 7:** Explain to a colleague why `su` *structurally cannot* give someone "restart kubelet but nothing else" — not "it lacks the feature," but *why its design makes it impossible.* (Hint: what does su ask for, and what does it hand back?)

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

Here the commands finally arrive — each as a **hypothesis you commit to first**, then verify. Read the prediction, cover the outcome, decide if you agree, *then* run it. Run these on a throwaway VM or a lab node (Ubuntu 22.04 assumed; distro notes where they matter). Most commands need root, so prefix with `sudo`.

---

## Prediction 1 — Creating an interactive user writes exactly one row per file

> **My prediction:** "If I run `useradd -m -s /bin/bash devuser`, then a new row appears in `/etc/passwd` with UID ≥ 1000 and shell `/bin/bash`, a matching group appears in `/etc/group`, a home dir `/home/devuser` is created, and a locked line lands in `/etc/shadow` (no password yet) — *because* `useradd` is just appending rows to the three lookup tables and copying `/etc/skel` into the home."

```bash
sudo useradd -m -s /bin/bash devuser   # -m = make home, -s = login shell
getent passwd devuser
# devuser:x:1000:1000::/home/devuser:/bin/bash
getent group devuser
# devuser:x:1000:
sudo getent shadow devuser
# devuser:!:19555:0:99999:7:::         ← '!' = no password set → can't log in yet
ls -ld /home/devuser
# drwxr-xr-x 2 devuser devuser ... /home/devuser
# (0755 by default: useradd applies UMASK 022 unless HOME_MODE is set;
#  newer distros / adduser may tighten this to 0750)
```

Now give it a password so login works, and confirm the hash lands in shadow (not passwd):

```bash
sudo passwd devuser                    # type a password twice
sudo getent shadow devuser
# devuser:$6$....$....:19555:0:99999:7:::   ← $6$ = SHA-512 hash now present
```

**Verify:** UID is 1000+ (normal-user range), the hash appears *only* in shadow, and `/etc/passwd` still shows just `x`. If the hash showed up in passwd, your model of the passwd/shadow split is wrong — re-read Rung 3B.

---

## Prediction 2 — A system user looks the same but can't log in

> **My prediction:** "If I run `useradd -r -s /sbin/nologin etcd`, then the new row will have a UID *below* 1000 (system range), no home created by default, and the `/sbin/nologin` shell — and any attempt to `su` into it will be refused — *because* `-r` picks a system UID and nologin is a real program that just prints a message and exits non-zero."

```bash
sudo useradd -r -s /sbin/nologin etcd
getent passwd etcd
# etcd:x:998:998::/home/etcd:/sbin/nologin   (UID < 1000 — system range)

# Prove nologin actually refuses a shell:
sudo su -s /bin/sh etcd -c 'echo hi'   # force a shell → works, proves the ACCOUNT exists
sudo su - etcd                          # use etcd's OWN shell (/sbin/nologin)
# This account is currently not available.
```

Then simulate the Kubernetes ownership pattern:

```bash
sudo mkdir -p /var/lib/etcd
sudo chown -R etcd:etcd /var/lib/etcd
ls -ld /var/lib/etcd
# drwxr-xr-x 2 etcd etcd ... /var/lib/etcd   ← data owned by the service user
```

**Verify:** UID < 1000, `su - etcd` is refused by nologin, and `/var/lib/etcd` is owned `etcd:etcd`. This is *exactly* how real etcd, kubelet, and kube-proxy run — as system users with no shell. If `su - etcd` gave you a shell, its login shell isn't nologin — check field 7.

---

## Prediction 3 — Supplementary groups: `-aG` adds, plain `-G` replaces (the classic footgun)

> **My prediction:** "If I run `usermod -aG docker devuser`, then devuser gains the docker group *in addition to* its existing groups, but the new membership won't appear in devuser's *current* shells — *because* group membership is baked into the process at login time, so already-running sessions keep their old group list until they re-login."

```bash
sudo groupadd docker 2>/dev/null      # ensure the group exists
sudo usermod -aG docker devuser        # -a APPEND, -G to these supplementary groups
getent group docker
# docker:x:999:devuser                 ← devuser now in docker's member list
# (GID 999 is illustrative — plain groupadd assigns the next free GID from the
#  normal range, so yours may differ; the docker package usually makes it a system GID)
id devuser
# uid=1000(devuser) gid=1000(devuser) groups=1000(devuser),999(docker)
```

Now the edge case that has bitten every engineer — **forgetting `-a`**:

```bash
# DANGER (do NOT run casually): plain -G REPLACES the whole supplementary set
# sudo usermod -G docker devuser
# → this would remove devuser from EVERY other supplementary group (e.g. sudo!)
```

**Verify:** `id devuser` shows both `devuser` and `docker`. If you had run `-G` without `-a`, the user would lose `sudo` and any other groups — a real lockout. And note: a user already logged in must open a *new* login session (or run `newgrp docker`) before the docker group is active in their shell. If you expected instant effect in the old shell, that's your model repairing: **the kernel's group list is fixed at login.**

---

## Prediction 4 — `getent` sees more than the flat file (NSS in action)

> **My prediction:** "If I query users with `getent passwd`, then I'll see the same rows as the file *plus* any from other sources NSS is configured to consult (LDAP/SSSD) — *because* `getent` goes through the NSS layer (`/etc/nsswitch.conf`), whereas reading the file directly only ever shows local rows."

```bash
grep '^passwd' /etc/nsswitch.conf
# passwd:  files systemd            ← lookup order: local files, then systemd
getent passwd etcd                  # resolves via NSS
# etcd:x:998:998::/home/etcd:/sbin/nologin
getent passwd 998                   # you can look up by NUMBER too
# etcd:x:998:...                     ← proving name and UID are interchangeable keys
getent group docker
# docker:x:999:devuser
getent passwd 999999                # a UID with no entry
echo $?                             # → 2  (getent exit code: not found)
```

**Verify:** `getent passwd 998` and `getent passwd etcd` return the *same* row — because they're two keys into one table. On a plain node NSS just reads files, but on an LDAP-joined machine `getent passwd` would show directory users that `grep /etc/passwd` never would. That gap is *why* `getent` exists. This directly explains the next prediction's mystery.

---

## Prediction 5 — A container UID with no passwd entry (the K8s `runAsUser` reveal)

> **My prediction:** "If a process runs as UID 1000 but 1000 has **no** `/etc/passwd` row, then `id` will show `uid=1000` with **no name** (just the bare number), files it creates will be owned by numeric `1000`, and yet it still has a perfectly valid identity — *because* identity is the number; the name is an optional lookup that simply fails to resolve."

Simulate exactly what `securityContext.runAsUser: 1000` does on the node — run a process as a UID that has no name:

```bash
# Use a UID that has NO passwd entry (pick one you haven't created, e.g. 4242):
sudo setpriv --reuid 4242 --regid 4242 --clear-groups id
# uid=4242 gid=4242 groups=4242              ← NO name in parentheses; just numbers

# Watch it create a file owned by the bare number:
sudo setpriv --reuid 4242 --regid 4242 --clear-groups \
  sh -c 'touch /tmp/orphan-owned && ls -ln /tmp/orphan-owned'
# -rw-r--r-- 1 4242 4242 0 ... /tmp/orphan-owned   ← 'ls -ln' shows numeric owner
ls -l /tmp/orphan-owned
# -rw-r--r-- 1 4242 4242 ...   ← even 'ls -l' can't show a name; there's none to find
```

**Verify:** `id` prints `uid=4242` with no username, and `ls -l` (which normally shows names) is *forced* to show the number `4242` because the reverse lookup in `/etc/passwd` finds nothing. **This is precisely why a container with `runAsUser: 1000` shows up on the host as bare UID 1000 with no `/etc/passwd` entry** — the container's filesystem might name 1000 "appuser", but the *host* has never heard of it. The kernel doesn't care: the number is the identity. If you expected an error instead of a working process, that's the big reveal of this whole topic landing.

> Note: `setpriv` ships with `util-linux` (present on Ubuntu 22.04). If unavailable, `sudo -u '#4242' id` achieves the same "run as bare UID" effect via sudo's `#UID` syntax.

---

## Prediction 6 — Scoping sudo so devops can restart kubelet but NOT get a root shell

> **My prediction:** "If I write a sudoers rule allowing devuser *only* `systemctl restart kubelet` (with NOPASSWD), then `sudo systemctl restart kubelet` succeeds without a prompt, but `sudo -i` (a root shell) and `sudo cat /etc/shadow` are both **refused** — *because* sudo matches the exact command against the rulebook and denies anything not listed."

Always edit with **`visudo`** (it syntax-checks before saving — a typo in sudoers can lock everyone out of root):

```bash
# Create a scoped drop-in file, validated by visudo:
sudo visudo -f /etc/sudoers.d/devops-kubelet
```
Put in it exactly:
```
# devuser may restart kubelet only — nothing else, no password
devuser ALL=(root) NOPASSWD: /usr/bin/systemctl restart kubelet
```
Save and exit, then test as devuser:
```bash
sudo -u devuser sudo -n systemctl restart kubelet   # -n = non-interactive (no prompt)
# (succeeds silently — NOPASSWD, and the command matches)

sudo -u devuser sudo -n -i                            # try to get a root LOGIN shell
# Sorry, user devuser is not allowed to execute '/bin/bash' as root.

sudo -u devuser sudo -n cat /etc/shadow               # try to read the hashes
# Sorry, user devuser is not allowed to execute '/usr/bin/cat /etc/shadow' as root.

sudo -u devuser sudo -l                               # list what devuser CAN do
#   (root) NOPASSWD: /usr/bin/systemctl restart kubelet
```

**Verify:** The exact allowed command runs; `sudo -i` (login shell as root) and `cat /etc/shadow` are both denied and logged. `sudo -l` prints the *one* line — that's your audit-ready proof of least privilege. If `sudo -i` had worked, your rule was too broad (e.g. you wrote `ALL` as the command). 

> **`sudo -i` vs `sudo -s`:** `-i` starts a *login* shell as the target user (runs their profile, `cd`s to their home — a clean root environment); `-s` starts a *non-login* shell keeping your current environment and directory. `sudo -u etcd -s` would drop you into a shell *as etcd*; `sudo -u etcd id` runs a single command as etcd. And plain `ubuntu ALL=(ALL) NOPASSWD:ALL` (the classic cloud-image line) is the *opposite* of what we did here — full passwordless root, convenient but the least-privilege nightmare you're now equipped to avoid.

---

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

**Cleanup (reset the lab):**
```bash
sudo userdel -r devuser          # -r ALSO removes home dir + mail spool
sudo userdel -r etcd 2>/dev/null # (only if you created a throwaway one)
sudo rm -f /etc/sudoers.d/devops-kubelet
sudo rm -f /tmp/orphan-owned
```
> Note: `userdel -r` removes the home directory and mail spool but does **not** hunt down files the user owns *elsewhere* on the filesystem — those become orphaned, owned by a now-nameless UID (exactly the Prediction 5 situation). `find / -uid 1000` afterwards would still find them.

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> On Linux, a user is a UID and a group is a GID — plain integers the kernel stamps on every process and checks on every operation — while `/etc/passwd`, `/etc/group`, `/etc/shadow`, and `sudo` are just human-facing machinery for naming those numbers, storing credentials, and safely switching which numbers a process runs as.

**Explain it to a beginner in 3 sentences:**
> 1. Every process on Linux has an identity that is really just a number (a UID), and the kernel uses that number — not any username — to decide what the process is allowed to touch, with the number 0 (root) being allowed to do anything.
> 2. Text files (`/etc/passwd` for users, `/etc/group` for groups, `/etc/shadow` for password hashes) are lookup tables that translate those numbers to friendly names and hold the login credentials, which is why a container running as UID 1000 works fine on a host that has never heard the name "1000".
> 3. `sudo` is an ordinary program, marked to start as root, that checks a rulebook (`/etc/sudoers`, edited with `visudo`) and logs every use — so you can grant a person the exact power to, say, restart kubelet without ever handing over full root.

**Map of sub-capability → the one core idea (all one pattern):**

```
Every command here = "read, edit, or switch the identity numbers":

/etc/passwd,group,shadow  → the name↔number tables (READ the mapping)
getent / nsswitch         → the correct front door to READ those tables
useradd -m / -r           → ADD a row (human vs service user, same format)
usermod -aG               → EDIT the group tables (grant supplementary access)
userdel -r                → DELETE a row (+ home)
primary vs supplementary  → which GIDs land in the kernel's Groups list
sudo / visudo / sudoers   → SWITCH to UID 0 for one command, scoped + logged
sudo -u / -i / -s / -l    → SWITCH to a chosen user / shell / list the rules
PAM                       → the gate that authenticates BEFORE the switch
runAsUser: 1000           → a raw number as identity, no name required
```

Ten rows, one idea: **identity is a number; everything else is bookkeeping around it.**

**Which rung will I most likely need to revisit hands-on?**

Be honest, but the two usual suspects:

- **Rung 3B/5 — the passwd/shadow/group split and the login-time group snapshot.** It's easy to *say* "hashes live in shadow" and still be surprised that `usermod -aG` doesn't affect a running shell. Fix: create a user, `id` it, add a group, `id` again in the same shell vs a fresh login — watch the difference with your own eyes.
- **Rung 7 Prediction 6 — sudoers scoping under questioning.** You can paste a `NOPASSWD` line, but writing a rule that allows *exactly* one command and *nothing* adjacent (and proving `sudo -i` is blocked) takes a couple of reps before an audit. Rehearse it in a VM until `sudo -l` shows precisely what you intended.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [Permissions & ownership](05-permissions-ownership.md) — the `rwx` model and `chown` that these UIDs/GIDs plug into; identity is meaningless without the permission checks it feeds.
- [Processes & job control](07-processes-job-control.md) — every process *carries* the UID/GID set from this rung; see how `ps -o user` and signals respect it.
- [Capabilities](17-capabilities.md) — the finer-grained alternative to all-or-nothing root; how to grant one power (e.g. bind port 80) instead of UID 0.
- [systemd & services](16-systemd-services.md) — where a daemon's `User=etcd` is set, doing the `setuid` that runs kubelet/etcd as their service users.
- [TLS/PKI & OpenSSL](26-tls-pki-openssl.md) — why `/etc/kubernetes/pki` ownership matters, and who (root vs kubelet) may read the CA key.
- [Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — the full mapping, including how `securityContext.runAsUser` becomes a bare host UID.
