# The Shell & Environment, Climbed the Ladder 🪜
### Learning bash from the ground up for a Kubernetes engineer — deriving how commands are found and run, not memorizing them

> This is your Linux-from-scratch guide, rebuilt on the Learning Ladder. Instead of leading with commands, we climb from **why the shell exists** → **the one core idea** → **the machinery** → and only at the very top, the hands-on commands. Each rung ends with a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The persona:** you're a Kubernetes platform engineer, ~6 years in DevOps/support, fluent in `kubectl` but newer to what actually happens *below* it. You type `kubectl get pods` a hundred times a day — but do you know how the shell finds `kubectl`, or why your `alias k=kubectl` vanishes in a new terminal? That's this file.

---

# RUNG 0 — The Setup

**What am I learning?**
The **shell** — specifically **bash** — the program that reads what you type, figures out what you mean, and asks the kernel to run it. Plus its **environment**: the variables, `PATH`, and config files that shape every command's behavior.

**Why did it land on my desk?**
You're prepping for the CKA exam and you keep losing minutes. Everyone online says "set up your aliases and completion first." You dutifully ran `alias k=kubectl` in the exam-practice terminal, it worked, you opened a second terminal — and `k` was gone. You `export`ed `KUBECONFIG=/some/path`, it worked in that shell, then a script you launched couldn't see it either... wait, no, the script *could* see it, but a variable you set *without* export could not. You've also been handed a Dockerfile where `ENTRYPOINT ["sh","-c","exec my-app"]` behaves differently from `ENTRYPOINT ["my-app"]`, and nobody on the team can cleanly explain why. Every one of these is the same missing mental model: **how the shell resolves and runs commands, and how the environment is inherited.**

**What do I already know about it?**
You know a terminal gives you a prompt. You know `$PATH` is "where commands live." You've seen `~/.bashrc`. You know Kubernetes runs containers, and containers run processes. You do *not* yet have a crisp model of: builtin vs external command, shell variable vs environment variable, login vs interactive shell, or why `sh -c` matters to a container `ENTRYPOINT`. By the top of this ladder, all of that is one connected picture.

---

# RUNG 1 — The Pain 🔥
### *Why does a shell exist at all?*

Sit with the problem before you touch a command. If you feel the pain, you can *derive* what the shell must do — and most of it stops needing memorization.

### The problem that forced the shell into existence

The kernel is the program that actually controls the machine: it starts processes, manages memory, talks to disks and network cards. But the kernel has **no human interface**. It exposes *system calls* — `fork()`, `execve()`, `open()` — raw C functions. You cannot "type" a system call. There is no place to type it.

So the raw pain is: **a human sitting at a keyboard needs some running program to turn typed words into system calls on their behalf.** Something has to read "run `ls`", find the `ls` program on disk, ask the kernel to launch it, wait for it, and show you the result. That something is the shell.

```
WITHOUT A SHELL — the gap between you and the machine

   You (human, typing words)
        │
        │   ??? nothing here ???
        ▼
   Kernel (only speaks system calls: fork/execve/open/wait)
        │
        ▼
   Hardware (CPU, disk, NIC)

There is no way to cross the ??? by hand.
You cannot type execve("/bin/ls", ...) at a keyboard.
```

### What people did *before* — and why it hurt

The earliest computers had **no interactive interface at all**: you submitted a stack of punch cards (a "batch job"), an operator fed them to the machine, and hours later you got printout. Want to change one thing? New card deck, back of the queue. There was no "type a command, see a result, type the next" — the *conversation* with the computer didn't exist.

The shell (Thompson shell, 1971; Bourne shell `sh`, 1979; **bash** — the "Bourne Again Shell" — 1989) was the invention of that conversation. It made the computer **interactive**: a read-eval-print loop for the whole operating system.

**Who feels this pain most?** Anyone who needs to compose the system's tools quickly — which is exactly you at a CKA terminal or debugging a node at 3 AM. Without a shell you'd have no pipes, no `grep | awk`, no `for` loop over pods, no `$(...)` to capture a value, no history, no completion. Every one of those is a shell feature invented to reduce a specific friction.

### What breaks without it (the Kubernetes angle)

The shell is not just *your* convenience — it's load-bearing inside Kubernetes:

- `kubectl exec -it pod -- /bin/bash` drops you into a shell **inside the container's namespaces**. No shell in the image → you get `/bin/sh` or nothing, and debugging gets painful (this is why "distroless" images are hard to `exec` into).
- A container's **`ENTRYPOINT`/`CMD`** is often run *through* a shell (`sh -c "..."`) so that `$VAR` expansion, `&&`, and globbing work. Choose the wrong form and your `$VAR` never expands.
- The **kubelet** launches container processes via the container runtime, which ultimately does the same `fork`+`execve` the shell does — the shell is just the human-facing version of the same primitive the whole platform is built on.

> **✅ Check yourself before Rung 2:** In one breath — why can't you just "type a system call"? What specific job is the shell doing that the kernel refuses to do for you?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this exact sentence. Every other fact in this file can be *derived* from it:

> **The shell is a normal user program that reads your line, expands it, finds the command, and asks the kernel to `fork` a child and `execve` the program in it — carrying along a copy of the environment.**

That's the whole trick. Read it again. Everything else is detail on one of its verbs.

### Why this sentence lets you derive the rest

Watch how much falls out:

- *"reads your line ... expands it"* → **quoting and expansion** exist because the shell rewrites your line (`$VAR`, `*`, `$(...)`) *before* running anything. If you don't want that rewrite, you quote.
- *"finds the command"* → that's **`PATH` lookup** (for external commands) versus **builtins** (which the shell runs itself, no lookup, no new process).
- *"fork a child and execve"* → every external command is a **new child process**. That single fact explains inheritance, why `cd` *can't* be external, and why a subshell can't change its parent.
- *"carrying along a COPY of the environment"* → this is the crux of `export`. **Environment variables are copied into children; plain shell variables are not.** A copy means the child can't change *your* variables, and a variable you set after launching a child never reaches it.

So: builtins, `PATH`, `export`, inheritance, quoting, subshells, and why aliases die in a new terminal — all are consequences of that one sentence. Hold the sentence; derive the rest.

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then answer: the sentence says the child gets a *copy* of the environment. From that one word "copy," predict two things — (a) can a child process change a variable in your shell? (b) if you set a variable *after* the child started, can the child ever see it?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. There are four things to nail: **(A) the read-eval loop and where the shell sits, (B) builtins vs external commands and PATH lookup, (C) shell variables vs the environment and how `export` and inheritance work, and (D) the startup files that pre-load your environment.**

## (A) Where the shell sits, and its loop

The shell is just a user-space program (`/usr/bin/bash`) — no special privilege, same as `ls`. What makes it special is what it does in a loop:

```
THE READ–EVAL LOOP  (this is bash's whole life)

┌──────────────────────────────────────────────────────────┐
│  1. PROMPT   print $PS1  ("user@host:~$ ")                │
│  2. READ     read one line from the terminal              │
│  3. EXPAND   rewrite the line:                            │
│                 $VAR → value    (parameter expansion)     │
│                 *.yaml → files  (globbing)                │
│                 $(cmd) → output (command substitution)    │
│                 "..." '...'     (quoting controls all ↑)  │
│  4. SPLIT    break into words → command + arguments       │
│  5. RESOLVE  is word 1 a builtin? a function? an alias?   │
│                 else → look it up in $PATH                 │
│  6. RUN      builtin → run inside bash itself             │
│              external → fork() a child, execve() in it,   │
│                          wait() for it to finish          │
│  7. goto 1                                                │
└──────────────────────────────────────────────────────────┘

        You                bash (user program)            Kernel
    "kubectl get po"  ──▶  expand, resolve, fork/exec ──▶  runs kubectl
                     ◀──   print result            ◀──    exit status
```

Step 5's ordering is a real rule bash follows top to bottom: **alias → function → builtin → `$PATH` executable**. Knowing that order is how you predict which thing actually runs when a name collides.

## (B) Builtins vs external commands, and PATH lookup

Two kinds of "commands" live in a shell, and telling them apart is half the battle:

- A **builtin** is code *compiled into bash itself*. Running it is a function call inside the already-running shell — **no `fork`, no `execve`, no new process.** Examples: `cd`, `export`, `alias`, `type`, `source`, `echo` (bash has its own), `pwd`, `read`.
- An **external command** is a separate executable file on disk (e.g. `/usr/bin/ls`, `/usr/local/bin/kubectl`). To run it, bash must **find the file**, then `fork`+`execve`.

How does bash find an external file? It walks **`$PATH`** — a colon-separated list of directories — left to right, and runs the **first** match:

```
PATH LOOKUP for "kubectl"

$PATH = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

bash checks, in order, until it finds an executable file named kubectl:
   /usr/local/sbin/kubectl   ✗ not here
   /usr/local/bin/kubectl    ✓ FOUND → execve this one, stop searching

(To skip aliases/builtins and see the real file bash WOULD exec:
   command -v kubectl   →  /usr/local/bin/kubectl
   type kubectl         →  kubectl is /usr/local/bin/kubectl
 To see if a name is a builtin instead:
   type cd              →  cd is a shell builtin )
```

**Why `cd` *must* be a builtin (this is the killer insight).** Recall from Rung 2: an external command runs in a *child* process, and a child gets a *copy* of the environment and its own working directory. If `cd` were an external program, it would change the *child's* directory and then exit — leaving *your* shell exactly where it was. `cd` can only work by being a builtin that changes the *current* shell's own state. The same logic forces `export`, `alias`, and `source` to be builtins: they all must mutate the running shell, and a child can never do that to its parent.

```bash
type cd        # cd is a shell builtin        ← changes THIS shell → must be builtin
type ls        # ls is /usr/bin/ls  (aliased  ← a real file → runs in a child
               #  to `ls --color=auto` on Ubuntu)
```

## (C) Shell variables vs the environment — the heart of `export`

Every process on Linux carries a block of `KEY=value` strings called its **environment**. Bash keeps *two* pools of variables, and the difference is the single most useful thing in this file:

```
INSIDE ONE bash PROCESS

   ┌───────────────────────────────────────────────┐
   │  bash                                          │
   │                                                │
   │   SHELL (local) variables      ENVIRONMENT     │
   │   ┌──────────────────┐        ┌──────────────┐ │
   │   │ X=hello          │        │ PATH=...     │ │
   │   │ tmp=/data        │        │ HOME=/root   │ │
   │   │ (private to bash)│        │ KUBECONFIG=… │ │
   │   └──────────────────┘        │ X=hello ◀────┼─┼─ export X moves/copies
   │                               └──────┬───────┘ │   it into here
   └──────────────────────────────────────┼─────────┘
                                          │ fork() + execve()
                                          ▼  child gets a COPY of
                                     ┌──────────────┐  the ENVIRONMENT only
                                     │ child process│  (never the shell vars)
                                     │ sees: PATH,  │
                                     │ HOME, KUBE-  │
                                     │ CONFIG, X    │
                                     │ NOT: tmp     │  ← tmp was never exported
                                     └──────────────┘
```

- A **shell (local) variable** — `X=hello` — lives only inside *this* bash. Children never see it. It's a scratchpad for the current shell.
- An **environment variable** — created by `export X` — is placed in the environment block, which `execve` **copies into every child**. That copy is the whole mechanism of inheritance.

Three consequences fall straight out of "the child gets a **copy**":

1. **Set-then-launch order matters.** A child only receives variables that were exported *before* it was forked. Export `KUBECONFIG`, *then* run the script — not the other way around.
2. **Children can't talk back.** A child editing `X` edits *its own copy*. Your shell's `X` is untouched. (This is why a script can't `cd` your interactive shell, and why you sometimes must `source` a script instead of running it — sourcing runs it in *your* shell, no child.)
3. **Plain assignment ≠ export.** `X=hello` makes a shell variable; only `export X` (or `export X=hello`) promotes it to the environment. `bash -c 'echo $X'` will print nothing unless `X` was exported first.

```bash
X=hello                 # shell variable only
bash -c 'echo $X'       # prints an empty line — child never got X
export X                # promote it to the environment
bash -c 'echo $X'       # prints: hello — now the child's copy has it
```

## (D) Startup files — how your environment gets pre-loaded

When a shell starts, it *sources* (reads and executes, in the current shell) certain config files. **Which** files depends on the shell's "type," and this is exactly why `alias k=kubectl` vanished in your second terminal.

Two orthogonal properties classify a shell:

- **Login vs non-login:** a *login* shell is the first shell of a session — SSH in, or a TTY console login. It reads the *profile* files. A *non-login* shell (opening a new terminal tab in a desktop, a subshell) skips them.
- **Interactive vs non-interactive:** an *interactive* shell has a prompt and a human. A *non-interactive* shell runs a script (`bash script.sh`) with no prompt.

```
WHICH FILES GET SOURCED  (bash, Ubuntu)

                    ┌─────────────────────────────────────────┐
  LOGIN shell   ──▶ │ /etc/profile                            │
  (ssh, console)    │   └─▶ /etc/profile.d/*.sh               │
                    │ THEN the FIRST that exists of:          │
                    │   ~/.bash_profile → ~/.bash_login →     │
                    │   ~/.profile                            │
                    └─────────────────────────────────────────┘
                    Convention: ~/.bash_profile just contains
                       [ -f ~/.bashrc ] && . ~/.bashrc
                    so it re-uses your interactive config.

                    ┌─────────────────────────────────────────┐
  INTERACTIVE   ──▶ │ /etc/bash.bashrc  (Debian/Ubuntu)       │
  NON-LOGIN         │ ~/.bashrc                               │
  (new terminal)    └─────────────────────────────────────────┘
  → THIS is where aliases & completion belong.

                    ┌─────────────────────────────────────────┐
  NON-INTERACTIVE ─▶│ NEITHER profile NOR bashrc by default.  │
  (bash script.sh)  │ Only $BASH_ENV, if set, is sourced.     │
                    └─────────────────────────────────────────┘
```

**Now the mystery solves itself.** You put `alias k=kubectl` in a login-only place (or typed it live), then opened a new *non-login interactive* terminal, which reads only `~/.bashrc` — where your alias wasn't. Put aliases and completion in **`~/.bashrc`**, and they load in every interactive shell. To apply an edit *without* opening a new terminal, `source ~/.bashrc` re-runs it in your current shell.

> **✅ Check yourself before Rung 4:** From memory — (1) name two commands that *must* be builtins and say *why the machinery forces it*. (2) You add `export FOO=1` to `~/.bashrc` and open a new SSH session; does a script you launch see `FOO`? Trace the path: which files did the login shell read, and did the export survive into the child?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now the jargon has somewhere to land. Every term is just a label for a part of the picture you already hold.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **Shell** | A user program that reads lines and runs commands | The whole read-eval loop (Rung 3A) |
| **bash** | The specific shell: Bourne Again Shell | The program running the loop |
| **`sh`** | The POSIX shell; on Ubuntu it's **dash**, not bash | A leaner shell; matters for `#!/bin/sh` scripts |
| **Builtin** | A command compiled into bash; no new process | Step 6, run *inside* bash |
| **External command** | A separate executable file on disk | Step 6, run via fork+execve |
| **`fork()`** | Kernel syscall: duplicate the current process | How a child is born |
| **`execve()`** | Kernel syscall: replace a process with a new program | How the child *becomes* `ls`/`kubectl` |
| **`wait()`** | Kernel syscall: parent blocks until child exits | Why your prompt waits for the command |
| **`PATH`** | Colon-separated dir list searched for externals | Step 5 lookup (Rung 3B) |
| **Environment variable** | A `KEY=value` copied into every child | The inherited block (Rung 3C) |
| **Shell / local variable** | A variable private to the current shell | The non-inherited pool (Rung 3C) |
| **`export`** | Builtin that promotes a var into the environment | The move between the two pools |
| **Environment** | The block of `KEY=value` strings a process carries | Copied by execve to children |
| **Expansion** | Bash rewriting `$VAR`, `*`, `$(...)` before running | Step 3 of the loop |
| **Quoting** | `'...'` / `"..."` controlling how much expansion happens | Governs Step 3 |
| **Subshell** | A child bash spawned by `(...)`, a pipe, or `$(...)` | A fork of your shell; changes don't return |
| **`source` / `.`** | Builtin that runs a file *in the current shell* | No fork — mutates this shell |
| **Alias** | A word-substitution done before resolution | Step 5, checked first |
| **Login shell** | First shell of a session; reads profile files | Startup files (Rung 3D) |
| **Interactive shell** | A shell with a prompt and a human | Reads `~/.bashrc` |
| **`~/.bashrc`** | Per-user interactive-shell config | Where aliases/completion live |
| **`/etc/profile`** | System-wide login-shell config | Sourced by all login shells |
| **Shell completion** | Tab-suggestion logic loaded into the shell | A bash feature, loaded via a script |

### The big unlock: which terms are the *same kind of thing*

New learners drown treating these as 20 unrelated ideas. Group them:

```
GROUP 1 — "The thing that finds & runs commands":
   Shell = bash = the read-eval loop
   (sh/dash is a leaner sibling of the same family)

GROUP 2 — "Runs INSIDE bash, no new process":
   Builtin + source + alias + shell function
   → all mutate or use THIS shell directly. cd/export/alias/source
     are here BECAUSE they must change the running shell.

GROUP 3 — "Runs as a NEW child process":
   External command + subshell + $(...) + a pipe stage
   → all are fork+execve. All get a COPY of the environment.
     None can change your shell back.

GROUP 4 — "Variables the child DOES inherit":
   Environment variable = exported variable = what's in `env`
   (PATH, HOME, KUBECONFIG live here)

GROUP 5 — "Variables the child does NOT inherit":
   Shell / local variable = plain X=hello (until you export it)

GROUP 6 — "Files that pre-load your environment at startup":
   /etc/profile + ~/.bash_profile   (login)
   /etc/bash.bashrc + ~/.bashrc     (interactive)
```

The two pairs that trip everyone: **Group 2 vs Group 3** (in-shell vs child) and **Group 4 vs Group 5** (inherited vs not). Master those two contrasts and the rest is labels.

> **✅ Check yourself before Rung 5:** Without looking — `$(kubectl config current-context)` runs in which group, 2 or 3? And therefore: if that command did a `cd /tmp` internally, where is your shell afterward? Explain using the word "copy" or "child."

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; one traced command sears the model in. Let's trace exactly this line, typed at a fresh interactive prompt, with `alias k=kubectl` already loaded from `~/.bashrc`:

```
   k get pods
```

**Step 1 — Read.** Bash, sitting in its loop, prints `$PS1`, and reads the line `k get pods` from the terminal.

**Step 2 — Alias substitution.** Before anything else, bash checks: is the first word `k` an alias? Yes — `~/.bashrc` defined `alias k=kubectl`. Bash rewrites the line to `kubectl get pods`. (Aliases are pure text substitution on the first word, done *first* — Rung 3A, Step 5 order.)

**Step 3 — Expansion.** Bash scans for `$VAR`, `*`, `$(...)`. There are none here (no `$`, no glob). If you'd typed `k get pods -n $NS`, *this* is where `$NS` would be replaced by its value. Quoting would govern it. Nothing to expand → line unchanged.

**Step 4 — Word splitting.** The line splits on whitespace into words: `kubectl`, `get`, `pods`. Word 1 (`kubectl`) is the command; the rest are arguments.

**Step 5 — Resolution.** Bash resolves `kubectl` in order: alias? (already expanded, no) → shell function named `kubectl`? (no) → builtin? (no) → search `$PATH`. It walks `PATH` left to right and finds `/usr/local/bin/kubectl`. This is exactly what `type kubectl` / `command -v kubectl` would have told you.

**Step 6 — fork().** Bash asks the kernel to `fork` — creating a child process that is, for an instant, a duplicate of bash. Crucially, the child receives a **copy of bash's environment block**: `PATH`, `HOME`, and `KUBECONFIG=/home/you/.kube/config` all come along.

**Step 7 — execve().** In the child, bash calls `execve("/usr/local/bin/kubectl", ["kubectl","get","pods"], environ)`. The kernel throws away the bash code in that child and loads the `kubectl` binary in its place. The child *is* now kubectl — but it kept the inherited environment.

**Step 8 — kubectl runs using inherited env.** kubectl starts, reads **`$KUBECONFIG`** from its environment (that inherited copy!) to find the cluster and credentials, talks to the API server, and prints the pod list to its stdout — which is your terminal.

**Step 9 — wait() and exit.** Meanwhile the parent bash is blocked in `wait()`. kubectl finishes and exits with a status code (0 = success). The kernel wakes bash, which stores the code in `$?`, prints a fresh `$PS1`, and returns to Step 1 for your next line.

```
VISUAL OF THE TRACE

  You type:  k get pods
     │
     ▼
  ┌─────────────────── bash (parent) ───────────────────┐
  │ alias:  k → kubectl                                 │
  │ expand: (nothing)                                   │
  │ split:  [kubectl] [get] [pods]                      │
  │ resolve: PATH → /usr/local/bin/kubectl              │
  │ fork() ───────────────────────────┐                 │
  │ wait() … blocked …                │ child (copy of  │
  └───────────────────────────────────┼──  bash + env)  ┘
                                      │ execve(kubectl)
                                      ▼
                            ┌────────────────────┐
                            │ kubectl (the child │
                            │ IS now kubectl)    │
                            │ reads $KUBECONFIG  │ ← inherited copy
                            │ → talks to API     │
                            │ → prints pods      │
                            │ → exit 0           │
                            └─────────┬──────────┘
                                      │ exit status
                     wakes parent ◀───┘   ($? = 0)
  bash prints prompt, loops.
```

Notice: **`KUBECONFIG` worked because it was *exported*** into the environment before the fork. Had you written `KUBECONFIG=... ` without export (as a plain shell variable), the child kubectl would never have seen it — it would fall back to `~/.kube/config`. The whole trace is Rung 2's sentence, in motion.

> **✅ Check yourself before Rung 6:** At which single step does `$KUBECONFIG` cross from your shell into kubectl — and what would break the crossing? Name the exact reason a *non-exported* `KUBECONFIG` fails to reach kubectl here.

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines it*

You understand the shell best by seeing what it *isn't*.

### Contrast A: bash vs `sh` (dash) — the ENTRYPOINT trap

On Ubuntu, `/bin/sh` is **not** bash — it's **dash**, a small, fast, strictly-POSIX shell with no arrays, no `[[ ]]`, limited `${var/…}` substitution, and no interactive niceties. This matters the moment you write a container `ENTRYPOINT`:

```
CONTAINER ENTRYPOINT: shell form vs exec form

  ENTRYPOINT my-app --flag=$HOME          (shell form)
     → Docker runs:  /bin/sh -c "my-app --flag=$HOME"
     → a SHELL exists: $HOME expands, && works, globs glob
     → BUT the shell is PID 1, my-app is its child
       → signals (SIGTERM from kubelet) hit the shell, not my-app
         unless you use `exec`

  ENTRYPOINT ["my-app", "--flag=$HOME"]   (exec form / JSON)
     → NO shell. execve("my-app", ...) directly.
     → my-app is PID 1 → receives SIGTERM cleanly (graceful shutdown ✓)
     → BUT "$HOME" is a LITERAL string — nothing expands it!

  The fix when you need BOTH expansion AND clean signals:
     ENTRYPOINT ["/bin/sh", "-c", "exec my-app --flag=$HOME"]
     → shell expands $HOME, then `exec` REPLACES the shell with
       my-app so my-app becomes PID 1 and gets the signals.
```

This is the same builtin-vs-external, fork-vs-exec machinery from Rung 3 — now deciding whether your pod shuts down gracefully when kubelet sends `SIGTERM`. The pod's `terminationGracePeriodSeconds` only helps if the signal actually reaches your app.

### Contrast B: the shell vs a GUI / a raw API

| Task | GUI / clicking | Raw kernel/API | Shell |
|---|---|---|---|
| Run one program | ✅ easy | ⚠️ write C + `execve` | ✅ type its name |
| Chain 5 tools by data flow | ❌ no pipes | ⚠️ manual plumbing | ✅ `a | b | c` |
| Repeat over 50 pods | ❌ 50 clicks | ⚠️ loop in code | ✅ `for` loop |
| Capture a value into a var | ❌ | ⚠️ | ✅ `x=$(cmd)` |
| Reproducible / scriptable | ❌ | ✅ | ✅ |
| Discoverable for a novice | ✅ | ❌ | ⚠️ must learn it |

The shell's superpower is **composition**: pipes and substitution let you wire independent tools into a one-off program on the fly. A GUI can't pipe; raw syscalls can, but you'd write and compile C. The shell hits the sweet spot — which is why every CKA task and every node-debug session is done in one.

### When would I NOT lean on the shell?

- **Production automation:** a hairy 200-line bash script is a liability — reach for Python/Go once logic gets real (bash has no real types, error handling is `set -euo pipefail` duct tape).
- **Portability across `sh`:** if a script must run under dash/busybox (Alpine containers!), avoid bashisms or set `#!/bin/bash` and ensure bash is installed.
- **Untrusted input:** shell expansion + user input = injection. Don't `eval` strings you didn't build.

**One-sentence "why this over that":**
> Use the shell to *interactively compose and script system tools fast* (your daily kubectl/debug work); drop to a real programming language when the logic outgrows what expansion and pipes can safely express.

> **✅ Check yourself before Rung 7:** Explain to a teammate why `ENTRYPOINT ["my-app", "$HOME"]` prints a literal `$HOME` but `ENTRYPOINT my-app $HOME` prints `/root` — using the words "shell," "execve," and "expansion." Then: which form lets kubelet's SIGTERM reach your app, and how does `exec` rescue the other form?

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**Here the commands finally arrive — as hypotheses you commit to first.** For each: read the prediction, cover the outcome, decide if you agree, *then* run it. All commands are correct on Ubuntu 22.04 / bash 5.x. Where `sh`/dash differs, it's noted.

---

## Prediction 1 — Builtin vs external, and PATH resolution (the normal case)

> **My prediction:** "`type cd` will say it's a *shell builtin* (no file), `type ls` will show a file path (and on Ubuntu, an alias), and `command -v kubectl` will print the single `$PATH` file bash would exec — *because* builtins live inside bash while externals are found by walking `$PATH` left to right."

```bash
type cd                 # cd is a shell builtin
type ls                 # ls is aliased to `ls --color=auto`
                        #   → then: ls is /usr/bin/ls
command -v kubectl      # /usr/local/bin/kubectl   (the real file to exec)
echo $PATH              # /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**Verify:** `type cd` shows *no* path (it's internal); `command -v kubectl` prints exactly one path, and that directory appears in your `echo $PATH` output. If `command -v kubectl` prints nothing, kubectl isn't in any `PATH` directory — that's your "command not found" cause, and it teaches you the lookup is purely `PATH`-driven.

---

## Prediction 2 — The export boundary (the edge/failure case)

> **My prediction:** "A plain `X=hello` will be invisible to a child shell, so `bash -c 'echo $VAR'`-style access prints blank; only after `export X` does the child's *copy* of the environment contain it — *because* execve copies only the environment block to children, never plain shell variables."

```bash
X=hello
bash -c 'echo $X'       # (blank line) — child never received X
env | grep '^X='        # (no output) — X is NOT in the environment

export X                # promote X into the environment
bash -c 'echo $X'       # hello  — the child's copy now has it
env | grep '^X='        # X=hello

# Order matters — export must come BEFORE the child is forked:
unset Y
bash -c 'echo "[$Y]"'   # [] — empty
Y=late; bash -c 'echo "[$Y]"'   # STILL [] — Y set but not exported
export Y; bash -c 'echo "[$Y]"' # [late] — now inherited
```

**Verify:** The first `bash -c` prints an empty line; the post-export one prints `hello`. If the *first* one already printed `hello`, then `X` was exported earlier in this shell (or your setup exports it) — which teaches you inheritance is about the environment block, and once a name is in it, every subsequent child gets it.

---

## Prediction 3 — Quoting controls expansion (edge case: when `$` does and doesn't fire)

> **My prediction:** "Double quotes let `$VAR` expand; single quotes make it a literal. So `echo "$HOME"` prints my home dir, `echo '$HOME'` prints the literal text `$HOME`, and in `bash -c '...'` the `$VAR` is expanded by the *child* shell, not my current one — *because* expansion (Rung 3A Step 3) happens inside whichever shell parses the quotes."

```bash
echo "$HOME"            # /home/you   (double quotes: expanded)
echo '$HOME'            # $HOME       (single quotes: literal)
VAR=outer
bash -c 'echo $VAR'     # (blank) — inner single-quoted; child expands its own $VAR (unset)
bash -c "echo $VAR"     # outer   — OUTER shell expanded $VAR before passing the string in
```

**Verify:** The single-quoted `'$HOME'` prints the four characters `$HOME`, not a path. The two `bash -c` lines differ: single quotes defer expansion to the child (which has no `VAR` unless exported), double quotes let *your* shell expand it first. If both `bash -c` lines matched, re-check your quotes — this contrast is the entire reason quoting exists.

---

## Prediction 4 — Kubernetes aliases, completion, and `source` (the K8s case)

> **My prediction:** "Defining `alias k=kubectl` and `export do='--dry-run=client -o yaml'` makes `k run nginx --image=nginx $do` generate YAML without creating anything. Adding completion via `~/.bashrc` and re-sourcing makes `k g<TAB>` complete — *because* the alias/export live in this shell, and `source ~/.bashrc` re-runs the config in the current shell so completion registers immediately, no new terminal needed."

```bash
# 1. The CKA speed kit
alias k=kubectl
export do="--dry-run=client -o yaml"          # generate, don't apply
export now="--force --grace-period=0"         # for fast pod deletes

# Generate a manifest without touching the cluster:
k run nginx --image=nginx $do                 # prints Pod YAML to stdout, creates nothing

# 2. Make it survive new terminals + enable tab-completion
echo 'alias k=kubectl' >> ~/.bashrc
echo 'source <(kubectl completion bash)' >> ~/.bashrc
# Let `k` (the alias) also complete like kubectl:
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

source ~/.bashrc                               # apply NOW in this shell (no reopen)

# 3. Prove completion + alias are live:
k get p<TAB>                                    # completes to `k get pods`
```

**Verify:** `k run nginx --image=nginx $do` prints a full Pod manifest and `kubectl get pod nginx` returns *NotFound* (nothing was created — `$do` expanded to the dry-run flags). After `source ~/.bashrc`, `k get p<TAB>` completes. If completion doesn't fire, confirm the `bash-completion` package is installed (`sudo apt-get install -y bash-completion`) and that you sourced the file — this teaches that completion is *loaded logic*, not built into the shell, and `source` runs it in the current shell without a fork.

---

## Prediction 5 — Login vs interactive-non-login: the vanishing alias (failure case, explained)

> **My prediction:** "An alias I only type live, or put in `~/.bash_profile`, will be *absent* in a brand-new non-login interactive shell, but one written to `~/.bashrc` will be present — *because* a new terminal is a non-login interactive shell that sources `~/.bashrc` but not the profile files."

```bash
# Simulate a fresh interactive NON-LOGIN shell (like opening a new terminal tab):
alias temp='echo hi'                 # live alias in THIS shell
bash -i -c 'alias temp'              # bash: alias: temp: not found  ← child re-read ~/.bashrc only

# Simulate a LOGIN shell (like an SSH session):
bash -l -c 'echo "$-"; shopt -q login_shell && echo "I am a login shell"'
# → sources /etc/profile + ~/.bash_profile/~/.profile

# Prove which file a login vs interactive shell reads:
bash -l -c 'echo LOGIN reads profile'      # login  → profile chain
bash -i -c 'echo INTERACTIVE reads bashrc' # interactive non-login → ~/.bashrc
```

**Verify:** `bash -i -c 'alias temp'` reports the alias is *not found* — because that fresh interactive child re-read `~/.bashrc` (where `temp` isn't) and never saw your live definition. That is *exactly* why your CKA alias "disappeared." The fix is Prediction 4's `>> ~/.bashrc`. If you instead see the alias, you likely already have it in `~/.bashrc` from an earlier step.

---

## Prediction 6 — Sourcing vs executing: who owns the directory change (subshell case)

> **My prediction:** "Running a script that does `cd /tmp` leaves my shell where it was, but *sourcing* the same script moves my shell to `/tmp` — *because* running forks a child (whose `cd` dies with it) while `source` executes the lines in my *current* shell (no fork)."

```bash
mkdir -p ~/lab && printf 'cd /tmp\necho "inside: $PWD"\n' > ~/lab/go.sh

pwd                    # /home/you
bash ~/lab/go.sh       # inside: /tmp     ← child cd'd, then died
pwd                    # /home/you        ← YOUR shell unmoved

source ~/lab/go.sh     # inside: /tmp     ← ran in THIS shell
pwd                    # /tmp             ← YOUR shell moved!
cd ~                   # (put yourself back)
```

**Verify:** After `bash ~/lab/go.sh`, `pwd` is unchanged; after `source`, `pwd` is `/tmp`. If `bash go.sh` *did* change your directory, something's very wrong with your shell — the child model is broken. This is the same reason a script can't set env vars in your session unless you `source` it (e.g. `source ~/.bashrc`, or the way `. venv/bin/activate` must be sourced).

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
> The shell reads your line, expands it, decides whether the command is a builtin (run inside the shell) or an external file (found via `PATH`, then run in a forked child that inherits a copy of the exported environment), and waits for the result.

**Explain it to a beginner in 3 sentences:**
> 1. The shell (bash) is the program that turns the words you type into actual programs the kernel runs — it finds each command, launches it as a child process, and shows you the output.
> 2. Some commands like `cd` and `export` are *builtins* that run inside the shell itself because they need to change the shell's own state, while most commands are separate files the shell locates by searching the `PATH` directories.
> 3. Variables you `export` become part of the *environment*, which is copied into every child process (that's how `kubectl` finds your `KUBECONFIG`), whereas plain variables and aliases stay private to the current shell — which is why an alias typed in one terminal is gone in the next unless you put it in `~/.bashrc`.

**Map of sub-capability → the one core idea** (*all one pattern: read → expand → resolve → fork/exec → inherit*):

```
Every feature = one verb of the core sentence:

builtins vs external (type/command -v) → "resolve" (in-shell vs PATH file)
PATH lookup (echo $PATH)                → "resolve" (walk dirs left→right)
export / env vars (KUBECONFIG)          → "inherit" (copy env to child)
shell/local vars (X=hello)              → "resolve" (private, not inherited)
child inheritance (bash -c '…')         → "fork/exec" (child gets a copy)
quoting & expansion ("$X" vs '$X')      → "expand" (before resolve)
aliases (alias k=kubectl)               → "resolve" (checked first)
completion (source <(kubectl …))        → loaded logic, in this shell
startup files (~/.bashrc, /etc/profile) → pre-load the environment
source vs run                           → in-shell vs child (fork or not)
sh -c in an ENTRYPOINT                   → "fork/exec" + "expand" in a container
```

Eleven rows, one idea: *the shell finds a command and runs it in a child that inherits a copy of what you exported.*

**Which rung will I most likely need to revisit hands-on?**

- **Rung 3C/3D (export inheritance + startup files).** The "why did my alias vanish" and "why doesn't the child see my variable" confusions live here. The fix: actually run Predictions 2 and 5 and *watch* the blank vs filled output. Do it once with your own eyes and it never confuses you again.
- **Rung 6 (bash vs `sh -c` in ENTRYPOINT).** Stating "exec form has no shell" is easy; explaining why that changes SIGTERM delivery to your pod takes a rep. Rehearse it before your next Dockerfile review.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [Linux philosophy: everything is a file](01-linux-philosophy.md) — file descriptors and `/proc/<pid>/environ`, where a process's inherited environment literally lives.
- [Filesystem navigation & the FHS](03-filesystem-navigation.md) — why `PATH` points at `/usr/bin`, `/usr/local/bin`, and friends.
- [Processes & job control](07-processes-job-control.md) — `fork`/`execve`/`wait`, PID 1, and signals (the SIGTERM half of the ENTRYPOINT story).
- [Shell scripting](08-shell-scripting.md) — variables, functions, and control flow built on this same shell.
- [I/O redirection & pipes](10-io-redirection-pipes.md) — how the shell wires stdin/stdout between the children it forks.
- [The Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — where the shell and environment sit in the full node-triage picture.
