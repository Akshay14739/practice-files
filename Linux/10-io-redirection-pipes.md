# I/O Redirection & Pipes, Climbed the Ladder 🪜
### Learning where a command's output *actually goes* — deriving `2>/dev/null`, `apply -f -`, and `diff <(...) <(...)`, not memorizing symbols

> This is Linux I/O redirection rebuilt on the Learning Ladder framework. Instead of leading with `grep | awk`, we climb from **why streams exist** → **the one core idea (three open files per process)** → **the machinery in the file-descriptor table** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every `>`, `2>&1`, `|`, `tee`, `xargs`, and `<<EOF` you've pasted lives at the TOP of the ladder (Rung 7). You'll understand *which file descriptor each symbol rewires* before you run it — and why `kubectl apply -f - <<EOF` is the same trick as `cat`.

---

# RUNG 0 — The Setup

**What am I learning?**
Standard I/O — the three streams every process is born with (`stdin`, `stdout`, `stderr`), the redirection operators that rewire them (`>`, `>>`, `2>`, `&>`, `2>&1`, `<`), the pipe `|` that welds one command's output to the next's input, and the tool-belt that hangs off all of it: `tee`, `xargs`, `while read`, heredocs, here-strings, and process substitution.

**Why did it land on my desk?**
A very Kubernetes-flavoured afternoon. You wanted to bulk-delete every crash-looping pod, and the one-liner you copied — `kubectl get pods | grep CrashLoop | awk '{print $1}' | xargs kubectl delete pod` — worked, but you couldn't have written it from scratch or explained why `xargs` was needed instead of just piping. Then a teammate handed you a manifest as `kubectl apply -f - <<EOF … EOF` and you weren't sure where the file was. Then a `find / -name '*.key' 2>/dev/null` scrolled clean while yours drowned in "Permission denied." Three different tricks, one root cause: **you learned the shell's plumbing by copy-paste and never saw the pipes behind the wall.** Today you see them.

**What do I already know about it?**
You know `>` writes to a file and `|` "chains commands." You've typed `2>/dev/null` to hush noise without knowing what `2` is. You know `kubectl logs pod > out.txt` saves logs. What you *don't* have is the model that unifies all of it: that a process holds a tiny numbered table of open files, that `stdout` is just slot `1` in that table, and that every redirection operator is a *one-line edit to that table* performed by the shell **before** your command even starts running.

---

# RUNG 1 — The Pain 🔥
### *Why does I/O redirection exist at all?*

Sit with the problem before touching a single `>`. If you understand the pain, the whole operator zoo becomes derivable instead of memorizable.

### The problem that forced streams into existence

Imagine every program had to know *where* its output should go. `ls` would need code for "write to the terminal," and *different* code for "write to a file," and *more* code for "send my output into `sort`." Every one of the thousands of Unix utilities would re-implement file-opening, terminal-handling, and inter-program plumbing. And the moment you wanted `ls`'s output to go somewhere its author never imagined, you'd be out of luck — you'd have to patch and recompile `ls`.

That is the pain: **without a shared convention, output destination is hard-coded into every program, and composition is impossible.**

### What people did *before* — and why it hurt

Early batch systems did exactly this: a program named its input and output files internally. If you wanted program B to consume program A's output, you ran A (writing to `TAPE1`), then ran B (reading `TAPE1`), managing the intermediate file by hand.

```
THE PRE-STREAM PAIN (every program hard-wires its destinations)

  ┌─────────┐  writes   ┌────────┐  you manually   ┌─────────┐
  │  sort   │ ────────▶ │ TEMP1  │ ─── feed it ───▶ │  uniq   │
  │ knows   │           │ (file  │   into the next  │ knows   │
  │ "write  │           │  on    │   program by     │ "read   │
  │  TEMP1" │           │  disk) │   hand           │  TEMP1" │
  └─────────┘           └────────┘                  └─────────┘

Pain points:
• Every program must contain file-management code.
• To combine A and B you juggle temp files and clean them up.
• A program can only feed programs it was WRITTEN to know about.
• No such thing as "just send this anywhere" — destinations are baked in.
```

Ken Thompson and Doug McIlroy's fix (Unix, ~1973) was to say: *programs shouldn't name their destinations at all.* Every program is handed three already-open channels and just reads/writes those. **Where those channels point is somebody else's job** — the shell's. That single decoupling is what makes `a | b | c` possible and is arguably the most important idea in the entire Unix design.

### What breaks without it — in your world specifically

- **No pipelines.** `kubectl get pods | grep CrashLoop | awk '{print $1}'` only exists because each stage reads a generic input stream and writes a generic output stream. Kill the convention and this line is impossible.
- **No log capture.** `kubelet` writing structured logs to `stdout`/`stderr` is the *entire basis* of container logging. `containerd` captures a container's `stdout`/`stderr` to a file under `/var/log/pods/`, and `kubectl logs` reads it back. If containers hard-coded their own log files, `kubectl logs` couldn't exist.
- **No stream separation.** `2>/dev/null` to silence `find`'s permission errors while keeping real results requires that errors and results travel on *different* channels. Merge them and you can never separate signal from noise again.

**Who feels this pain most?** The platform engineer wiring tools together under time pressure. Developers can stay inside one program; *you* live in the seams *between* programs — bulk-deleting pods, decoding secrets into `openssl`, diffing two namespaces. The seams are made entirely of redirection and pipes.

> **✅ Check yourself before Rung 2:** In one breath — why can `sort` feed `uniq` without either program containing any code that mentions the other? (Hint: who decides where `sort`'s output goes, and *when* is that decided?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — every operator in this document can be *derived* from it:

> **Every process is born holding a small numbered table of open files; `0` is where it reads (stdin), `1` is where it writes (stdout), `2` is where it writes errors (stderr) — and redirection and pipes are just the shell editing that table before the process starts.**

That's the whole trick. `>`, `2>&1`, `|`, `<<EOF` — all of them are edits to three (or more) numbered slots.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"a numbered table"* → those numbers are **file descriptors** (FDs). `0`, `1`, `2` are just the first three entries.
- *"`1` is where it writes"* → `command > file` means **"point slot 1 at `file` instead of the terminal."** The program still blindly writes to slot 1; it has no idea it's a file now.
- *"`2` is where it writes errors"* → `2>/dev/null` means **"point slot 2 at the trash."** Slot 1 (real output) is untouched — that's why errors vanish but results stay.
- *"`2>&1`"* → **"make slot 2 point at wherever slot 1 currently points."** `&1` means "the thing FD 1 references," not "a file named 1."
- *"pipes edit the table"* → `a | b` means **"point `a`'s slot 1 at a kernel buffer, and point `b`'s slot 0 at the *same* buffer."** The pipe *is* that shared buffer.
- *"the shell edits it before the process starts"* → this is why order matters, why `> file 2>&1` differs from `2>&1 > file`, and why the program itself never knows any of this happened.

Once you see that **there is no such thing as "printing to the screen"** — only "writing to FD 1, which *currently happens* to point at your terminal" — every redirection stops being a magic symbol and becomes an obvious edit.

> **✅ Check yourself before Rung 3:** Cover the sentence. Say it out loud from memory. Then answer: when you run `ls > out.txt`, does `ls` open the file? If not, who does, and at what moment relative to `ls` starting?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Four ideas, using one picture: every running program is an office worker who never mails anything directly — they just drop letters into numbered mail slots on their own desk, and the building's mail system decides where each slot's letters actually go.
>
> - **(A) The numbered mail slots.** Each worker's desk has a small row of numbered slots (each number is a "file descriptor" — just an index, not the destination itself). Three come standard: slot 0 is the **in-tray** (where instructions arrive), slot 1 is the **results out-tray**, and slot 2 is a separate **complaints out-tray**. Fresh out of the box, all three are connected to you — the person at the screen and keyboard. Why two out-trays? So results and complaints can be routed to different places independently — keep one, bin the other.
> - **(B) The dispatcher rewires the slots before the worker sits down.** When you ask for "run this and save the results in a file," the worker is never told about the file. Instead the dispatcher (your "shell" — the program that reads what you type) quietly re-plumbs the desk *first*: it connects slot 1's tube to the file, *then* seats the worker. The worker drops letters in slot 1 as always, blissfully unaware they now land in a file. Because rewiring steps are applied one at a time, left to right, **order matters** — and the instruction "make slot 2 go wherever slot 1 goes" copies slot 1's *current* destination, like photographing a signpost: if slot 1 is re-aimed afterwards, slot 2 doesn't follow. That snapshot-not-a-live-link detail is the single most common gotcha here.
> - **(C) What a pipe really is.** The vertical bar `|` between two commands asks the building to install a short **pneumatic tube with a small holding tank**: worker A's results out-tray feeds the tank, worker B's in-tray drains it. Three consequences: only the *results* tray goes through the tube (complaints still land on your desk unless you merge them in first); both workers are on shift *at the same time* — if the tank fills up, A simply waits until B catches up; and the pair's official "did it succeed?" verdict is, by default, only the *last* worker's — the first one may have failed silently.
> - **(D) Faking a file for workers who insist on one.** Some workers refuse loose letters and demand "a document." Two tricks satisfy them: a **heredoc** lets you dictate a block of text on the spot, which gets fed straight into the worker's in-tray as if it were a document (never touching the filing cabinet); and **process substitution** goes further — it hands the worker a *document name* that is secretly the end of a live tube from another worker. That's how a compare-two-things worker can be fed *two* live outputs at once, something an ordinary single tube can't do.

*Now the original technical deep-dive — the same ideas, in precise form:*

We now open the hood. There are four things to understand: **(A) the file-descriptor table, (B) how the shell rewires it before exec, (C) what a pipe physically is, and (D) how heredocs and process substitution fake a file.**

## (A) The file-descriptor table: what a process actually holds

A **file descriptor** is not a file. It's a small non-negative integer — an *index* into a per-process table the kernel keeps. Each entry points (through a couple of kernel layers) at something you can read bytes from or write bytes to: a regular file, a pipe, a terminal, a socket, `/dev/null`. The program says "write these bytes to descriptor 1"; the kernel follows the pointer and delivers the bytes wherever slot 1 leads.

```
WHAT A FRESH PROCESS HOLDS (before any redirection)

  Process "ls"
  ┌──────────────────────────┐
  │  FD table (per process)  │
  │  ┌────┬─────────────────┐│         ┌──────────────────┐
  │  │ 0  │ stdin  ─────────┼┼────────▶│  /dev/pts/0      │
  │  │ 1  │ stdout ─────────┼┼────────▶│  (your terminal) │
  │  │ 2  │ stderr ─────────┼┼────────▶│                  │
  │  └────┴─────────────────┘│         └──────────────────┘
  └──────────────────────────┘         All three point at the
                                        terminal by default — so
                                        output AND errors show up
                                        on screen, and typing feeds
                                        stdin.
```

The three standard descriptors:

| FD | Name | Default target | The program uses it to… |
|----|------|----------------|-------------------------|
| `0` | **stdin** | terminal keyboard | read input |
| `1` | **stdout** | terminal screen | write normal results |
| `2` | **stderr** | terminal screen | write diagnostics/errors |

**Why two output channels?** So that *results* and *complaints* can be routed independently. `find`'s found files go to FD 1; its "Permission denied" gripes go to FD 2. Because they're separate channels, you can keep one and discard the other — the whole basis of `2>/dev/null`.

## (B) The real mechanism: the shell rewires the table, *then* runs your program

This is the part that feels like magic until you see the sequence. When you type `ls > out.txt`, here's what the shell actually does — and the crucial fact is that **`ls` is never told about `out.txt`.**

```
WHAT THE SHELL DOES FOR:  ls > out.txt

 1. Shell PARSES the line, sees "> out.txt". It strips that off —
    "ls" will be run with NO arguments about out.txt.

 2. Shell fork()s a child process (a copy of itself).

 3. IN THE CHILD, before running ls, the shell:
       • open("out.txt", write, create/truncate)  → gets FD 3
       • dup2(3, 1)   ← copy FD 3 onto FD 1 (slot 1 now = out.txt)
       • close(3)     ← tidy up the spare
    Now slot 1 points at the file. Slot 2 still points at the terminal.

 4. Shell calls exec("ls") — REPLACES the child with the ls program.
    exec does NOT reset the FD table. ls inherits slots 0,1,2 as edited.

 5. ls runs. It writes results to FD 1 — which now leads to out.txt.
    ls has NO IDEA. It thinks it's writing to the screen as always.
```

Two things to burn in:

1. **The redirection happens *between* fork and exec** — after the child exists but before your program takes over. Your program starts life with the table already rewired.
2. **FD numbers are inherited across `exec`.** That inheritance is the whole reason redirection works: the shell edits the slots, then hands the running program a table it never chose. This is also *exactly* how `containerd` sets up a container's logging — it opens the pod's log file and wires the container's FD 1 and FD 2 to it before exec'ing your entrypoint. Your app just writes to stdout; containerd already pointed stdout at `/var/log/pods/<pod>/<container>/0.log`.

**Order matters, and now you can see why.** Compare:

```
 command > file 2>&1          command 2>&1 > file
 ───────────────────          ───────────────────
 1. FD1 → file                1. FD2 → (copy of FD1 = terminal)
 2. FD2 → (copy of FD1=file)  2. FD1 → file
 RESULT: both in file ✅       RESULT: FD2 still terminal,
                                       FD1 in file ✗ (errors leak
                                       to screen)
```

`2>&1` means "make FD 2 a duplicate of **whatever FD 1 is right now**." It's a snapshot, not a live link. If FD 1 later moves, FD 2 does *not* follow. That is the single most common redirection bug, and it's fully explained by "the shell applies these left-to-right, each as an independent `dup2`."

## (C) What a pipe physically is

A **pipe** is a kernel object: a small in-memory buffer (~64 KB on Linux) with two ends — a write end and a read end, each represented by a file descriptor. `a | b` is the shell doing this:

```
WHAT THE SHELL DOES FOR:  sort | uniq

 1. pipe()  → kernel creates a buffer, hands back two FDs:
       readEnd, writeEnd

 2. fork child #1 (will become sort):
       dup2(writeEnd, 1)   ← sort's stdout = the pipe's write end
       close both original pipe FDs; exec("sort")

 3. fork child #2 (will become uniq):
       dup2(readEnd, 0)    ← uniq's stdin = the pipe's read end
       close both original pipe FDs; exec("uniq")

 4. Both run CONCURRENTLY. sort writes bytes into the buffer;
    uniq reads them out. The kernel handles flow control:
    if the buffer fills, sort BLOCKS until uniq drains it.
```

```
   sort ──write──▶ ╔═══════════════╗ ──read──▶ uniq
   (FD1)           ║ kernel pipe   ║           (FD0)
                   ║ buffer ~64KB  ║
                   ╚═══════════════╝
   Two processes, running at once, joined by shared memory.
   No temp file ever touches disk.
```

Three consequences that trip people up, all derivable from "it's a concurrent shared buffer":

- **Pipes carry FD 1 only, not FD 2.** `a | b` sends `a`'s stdout to `b`. `a`'s stderr still goes to the terminal. To pipe errors too you must first merge them: `a 2>&1 | b`.
- **Every stage runs at the same time**, not one-then-the-other. That's why `tail -f log | grep ERROR` streams live.
- **Exit status is the *last* command's by default.** `false | true` succeeds, because `true` (the last stage) succeeded — even though `false` failed. This is the trap `pipefail` exists to fix (Rung 4).

## (D) How heredocs and process substitution fake a file

Some commands (`kubectl apply -f`, `openssl x509 -in`, `diff`) want a *filename* or want to *read a file*. Redirection lets you hand them one that isn't really a file on disk.

```
HEREDOC:  kubectl apply -f - <<EOF ... EOF

  The shell collects every line up to EOF, stuffs it into a
  temporary buffer, and points the command's FD 0 (stdin) at it.
  The "-f -" tells kubectl "read the manifest from stdin."
  So the heredoc IS the file — it lives in the pipe, not on disk.

    <<EOF   → the lines you type become stdin
    <<-EOF  → same, but LEADING TABS are stripped (lets you indent)
    <<<"x"  → here-STRING: a single line becomes stdin (no EOF needed)


PROCESS SUBSTITUTION:  diff <(cmd A) <(cmd B)

  <(cmd) runs cmd in the background, connects its stdout to a pipe,
  and substitutes a FILENAME that refers to that pipe's read end —
  on Linux it looks like /dev/fd/63. diff opens "/dev/fd/63" and
  reads cmd's live output as if it were a file.

    <(cmd)  → a filename you can READ that yields cmd's stdout
    >(cmd)  → a filename you can WRITE that feeds cmd's stdin
```

Process substitution is the missing piece pipes can't provide: a pipe feeds **one** stdin, but `diff` needs **two** inputs *at once*. `<(...)` manufactures a file-like name for each, so a two-argument program can consume two live command outputs without any temp files. This is *the* idiomatic way to diff two clusters/namespaces.

> **✅ Check yourself before Rung 4:** Draw the FD table for `find / 2>/dev/null | wc -l` from memory. Specifically: (1) where does FD 2 of `find` point? (2) where does FD 1 of `find` point? (3) which FD of `wc` is connected, and to what? (4) why does the "Permission denied" text never reach `wc`?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now that you have the machinery, the jargon has somewhere to land. Every term below is *just a label for a part of the picture you already understand.*

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **File descriptor (FD)** | A small integer indexing a process's open-files table | The whole table (Rung 3A) |
| **stdin / FD 0** | The slot a program reads input from | Table slot 0 |
| **stdout / FD 1** | The slot a program writes normal output to | Table slot 1 |
| **stderr / FD 2** | The slot a program writes errors to | Table slot 2 |
| **`>`** | Point FD 1 at a file, truncating it first | `open`+`dup2` on slot 1 (Rung 3B) |
| **`>>`** | Point FD 1 at a file, *appending* | Same, opened in append mode |
| **`2>`** | Point FD 2 at a file | `dup2` on slot 2 |
| **`<`** | Point FD 0 at a file (read from it) | `dup2` on slot 0 |
| **`2>&1`** | Make FD 2 duplicate FD 1's *current* target | A `dup2(1,2)` snapshot |
| **`&>` / `>&`** | Point *both* FD 1 and FD 2 at a file (bash shorthand) | Two slots at once |
| **`/dev/null`** | A kernel device that discards all writes, reads as empty | A target you point a slot at |
| **`\|` (pipe)** | Kernel buffer joining one FD 1 to the next FD 0 | The shared buffer (Rung 3C) |
| **`tee`** | A T-junction: copies stdin to a file *and* to stdout | Sits mid-pipe; writes two places |
| **`pipefail`** | Shell option: pipeline fails if *any* stage fails | Changes how exit status is computed |
| **`xargs`** | Reads items from stdin, turns them into *arguments* for a command | Converts a stream into argv |
| **`xargs -I{}`** | Same, but substitutes each item at the `{}` placeholder | Per-item argv templating |
| **`while read -r`** | Loop that reads stdin one line at a time into variables | Consumes FD 0 line by line |
| **`read -r`** | Read one line; `-r` = don't treat backslash as escape | The safe line reader |
| **Heredoc `<<EOF`** | Inline block of text handed to a command as stdin | Fakes a file on FD 0 (Rung 3D) |
| **`<<-EOF`** | Heredoc that strips leading **tabs** (lets you indent) | Same, with tab-stripping |
| **Here-string `<<<`** | A single string handed to a command as stdin | One-line stdin |
| **Process substitution `<(...)`** | A filename (`/dev/fd/63`) that yields a command's output | Pipe wrapped as a readable file |
| **`>(...)`** | A filename that *feeds* a command's stdin | Pipe wrapped as a writable file |

### The big unlock: which terms are the *same kind of thing*

New learners drown because they think these are 20 unrelated symbols. They're not. Group them:

```
GROUP 1 — "Move an output slot to a file" (all edits to FD 1 and/or 2):
   >  >>  2>  &>  2>&1
   → Every one is open()+dup2() on slot 1, slot 2, or both.
     The ONLY differences: which slot, truncate vs append,
     and whether the target is a file or another slot.

GROUP 2 — "Move the input slot" (all edits to FD 0):
   <   <<EOF   <<<   <(...)-as-input
   → All make FD 0 read from something other than the keyboard:
     a file, a heredoc buffer, a string, or a pipe-file.

GROUP 3 — "Join two programs" (all are kernel pipes):
   |     <(...)     >(...)
   → All three are the SAME object — a kernel pipe buffer.
     |    joins stdout→stdin inline.
     <()  exposes the read end as a filename.
     >()  exposes the write end as a filename.

GROUP 4 — "Turn a stream into something else":
   xargs      → stream of lines  → command ARGUMENTS
   while read → stream of lines  → shell VARIABLES (one line at a time)
   tee        → stream           → duplicated to file + downstream

GROUP 5 — "Fake a file from inline text":
   <<EOF   <<-EOF   <<<
   → All three synthesize stdin content the shell holds in memory.
```

If you hold those five groups, you hold the whole vocabulary. Notice **`<`, `<<`, `<<<`, and `<(...)` are all "give this program input from somewhere unusual"** — they differ only in *where the bytes come from* (a file, a typed block, a string, another command).

> **✅ Check yourself before Rung 5:** Without looking — `<<<"hello"` and `<(echo hello)` both feed something to a command. What's the difference in *what the command receives*? (One arrives on stdin as text; the other arrives as a *filename* the command must open.)

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; a single traced command sears the model in. Let's trace the exact line you'll use to nuke crash-looping pods, because it touches four groups at once:

```bash
kubectl get pods 2>/dev/null | grep CrashLoop | awk '{print $1}' | xargs kubectl delete pod
```

**Step 1 — The shell parses the whole line first.**
Before *anything* runs, the shell reads the entire pipeline, sees three `|` symbols and one `2>/dev/null`, and plans: it will create **three kernel pipes** (one between each pair of commands) and one file redirection. Nothing has executed yet.

**Step 2 — The shell sets up the plumbing.**
It calls `pipe()` three times, getting three buffers. Then it `fork()`s four children — one per command — and in each child, *before* exec, it rewires the FD table:
- `kubectl get pods` child: `dup2(pipe1_write, 1)`; then for `2>/dev/null`, it `open("/dev/null")` and `dup2` that onto FD 2. Now FD 1 → pipe1, FD 2 → the void.
- `grep CrashLoop` child: `dup2(pipe1_read, 0)`, `dup2(pipe2_write, 1)`.
- `awk '{print $1}'` child: `dup2(pipe2_read, 0)`, `dup2(pipe3_write, 1)`.
- `xargs kubectl delete pod` child: `dup2(pipe3_read, 0)`. Its FD 1 stays on the terminal.

**Step 3 — All four exec simultaneously and start streaming.**
`kubectl` queries the API server and writes the pod table to FD 1 (pipe1). Any warnings it emits (e.g., "deprecated flag") go to FD 2 → `/dev/null`, vanishing. This is why the pipeline stays clean: **the noise is severed at the source.**

**Step 4 — `grep` filters the stream line by line.**
`grep` reads pipe1 on FD 0, keeps only lines containing `CrashLoop`, writes survivors to FD 1 (pipe2). It never buffers the whole table — it processes as bytes arrive.

**Step 5 — `awk` extracts column 1.**
`awk` reads pipe2, splits each line on whitespace, prints `$1` (the pod name) to FD 1 (pipe3). Now pipe3 carries a bare list of pod names, one per line.

**Step 6 — `xargs` is the crucial hinge: stream → arguments.**
`xargs` reads the pod names off pipe3 (FD 0) and does the thing a pipe *cannot*: it collects them and builds a **command line**, appending the names as *arguments* to `kubectl delete pod`. It effectively runs `kubectl delete pod crashy-1 crashy-2 crashy-3`. Why can't you skip `xargs` and pipe directly into `kubectl delete pod`? Because `kubectl delete pod` reads its targets from **argv**, not from stdin — it ignores whatever you pipe at it. `xargs` is the adapter that turns a stream into argv.

**Step 7 — `kubectl delete pod` runs with real arguments.**
It receives the pod names as arguments, issues DELETE calls to the API server, and writes `pod "crashy-1" deleted` to its FD 1 — the terminal. You see the results.

```
VISUAL OF THE TRACE

 kubectl get pods
   FD2 ─────────▶ /dev/null   (warnings die here)
   FD1 ─┐
        └──▶[ pipe1 ]──┐
                       ▼
 grep CrashLoop      (FD0)
   FD1 ─┐
        └──▶[ pipe2 ]──┐
                       ▼
 awk '{print $1}'    (FD0)
   FD1 ─┐
        └──▶[ pipe3 ]──┐
                       ▼
 xargs ──builds──▶ kubectl delete pod  crashy-1 crashy-2 crashy-3
                        │  (names are ARGV now, not a stream)
                        ▼
                   FD1 → terminal:  pod "crashy-1" deleted ...

 Four programs, running at once, three pipes, one severed FD2.
```

> **✅ Check yourself before Rung 6:** At Step 6, why is `xargs` mandatory — what would happen if you wrote `... | awk '{print $1}' | kubectl delete pod` with no `xargs`? And at Step 3, if you *removed* the `2>/dev/null`, where would kubectl's warnings appear — in `grep`'s input, or on your screen? Why?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand redirection best by seeing where the *old* / *alternative* way stops and it begins. Two contrasts matter most for you.

### Contrast A: Pipes vs. temporary files

The pre-Unix approach (Rung 1) was to write output to a temp file, then read it back. You *can* still do that today — and sometimes must.

```
TEMP FILE                         PIPE
─────────                         ────
cmd1 > /tmp/x                     cmd1 | cmd2
cmd2 < /tmp/x                     
rm /tmp/x                         

• Runs sequentially (cmd1 fully     • Runs concurrently (streaming);
  finishes before cmd2 starts)        cmd2 sees bytes as cmd1 emits them
• Data hits disk (slow, needs       • Data stays in RAM (~64KB buffer)
  cleanup, needs space)             • Nothing to clean up
• cmd2 can re-read / seek the       • cmd2 gets a ONE-WAY stream; it
  file, run multiple passes           cannot seek backwards or re-read
• Both can inspect the file after   • Data is gone once consumed
```

| Task | Temp file | Pipe | Why |
|---|---|---|---|
| Stream huge/infinite output (`tail -f`) | ❌ never finishes | ✅ | Pipe is concurrent; file would grow forever |
| Feed the same data to a program *twice* | ✅ | ❌ | A stream is consumed once; a file can be re-read |
| A program that needs `seek()` (random access) | ✅ | ❌ | Pipes are sequential only |
| Avoid touching disk / no temp cleanup | ❌ | ✅ | Pipe lives in RAM |
| Keep the intermediate result for debugging | ✅ | ⚠️ use `tee` | `tee` gives you both |

### Contrast B: `xargs` vs. `while read` — two ways to consume a stream

Both turn a stream of lines into repeated actions. They are *not* interchangeable.

```
xargs                              while read -r
─────                              ─────────────
... | xargs kubectl delete pod     ... | while read -r name; do
                                        kubectl delete pod "$name"
                                      done

• Builds ONE (or few) big command  • Runs the body ONCE PER LINE
  with many arguments — efficient   • Full shell available: conditionals,
• Limited logic (it just runs a       multiple commands, variables
  command with args)                • Splits each line into MULTIPLE vars
• -I{} for per-item templating        (name ready status ...)
• Great for "delete all of these"   • Great for "for each, do several
                                        things / decide per item"
```

**The `for` trap that makes `while read` safer.** A tempting alternative is `for x in $(cmd)`. It is subtly broken: the shell splits `$(cmd)` on **all whitespace** (spaces, tabs, newlines) *and* performs glob expansion. A pod name is unlikely to contain spaces, but a filename or a label value can — and then `for` silently splits one item into several. `while read -r line` reads **one full line at a time**, so a value containing spaces stays intact. And `-r` stops `read` from eating backslashes. Rule of thumb: **iterate lines with `while read -r`, never with `for … in $(…)`.**

### When would I NOT reach for these?

- **Don't pipe when you need the data twice or need random access** — use a temp file (or `tee` to keep a copy).
- **Don't use `xargs` when the per-item logic needs branching or multiple commands** — use `while read -r`.
- **Don't use `while read` for a simple bulk action** — `xargs kubectl delete pod` is one API-efficient call; the loop is N calls.
- **Don't use process substitution in `/bin/sh` scripts** — `<(...)` is a bash/zsh feature; POSIX `sh` (which is what `#!/bin/sh` and many container shells give you) doesn't support it. Use `#!/bin/bash` or a temp file.

**One-sentence "why this over that":**
> Reach for a pipe to stream data concurrently between two programs; reach for a temp file when you need to re-read, seek, or keep the intermediate; reach for `xargs` to fan a stream into one big command, and for `while read -r` when each line needs real per-item logic.

> **✅ Check yourself before Rung 7:** Explain to a colleague why `for f in $(ls)` breaks on a file named `my report.txt` but `ls | while read -r f` does not — in terms of *when and on what* the shell splits.

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive — and notice the reframing.** Each one is a **hypothesis you commit to first**, then verify. Predicting before running is what converts "I typed the command" into "I understand the system." For each: read the prediction, cover the outcome, decide if you agree, *then* run it. These deliberately span different scenarios — a normal case, ordering edge cases, failure modes, and Kubernetes-flavoured cases.

---

## Prediction 1 — `>` truncates, `>>` appends, and stderr ignores both

> **My prediction:** "If I redirect a command's stdout with `>` and it also emits an error, the error will *still hit my screen* — *because* `>` only rewires FD 1, and the error travels on FD 2, which I left pointing at the terminal. `>>` will differ from `>` only in that it keeps prior file contents."

```bash
# Normal case: capture output, then append more
echo "line 1" > demo.txt        # FD1 → demo.txt (truncate)
echo "line 2" >> demo.txt       # FD1 → demo.txt (append)
cat demo.txt                     # => line 1 \n line 2

# Now prove stderr is a separate channel:
ls /nope > out.txt               # FD1→out.txt, FD2 still on screen
# On screen you STILL see: ls: cannot access '/nope': No such file or directory
cat out.txt                      # => empty! the error never went to FD1
```

**Verify:** `demo.txt` has two lines; the `ls /nope` error prints to your terminal *despite* the `> out.txt`, and `out.txt` is empty. If the error had landed in `out.txt`, your model of "> touches only FD 1" would need repair.

---

## Prediction 2 — `2>&1` order is a snapshot, not a live link

> **My prediction:** "If I write `> f 2>&1` all output lands in `f`, but if I flip to `2>&1 > f`, the errors leak to the screen — *because* `2>&1` copies FD 1's target *at that instant*, and in the flipped order FD 1 still points at the terminal when the copy is made."

```bash
# Correct: stdout first, then clone FD2 onto it
ls /etc /nope > both.log 2>&1
cat both.log        # contains BOTH the listing AND the error ✅

# Flipped: clone happens while FD1 is still the terminal
ls /etc /nope 2>&1 > only-stdout.log
# => the error prints on SCREEN; only-stdout.log has just the listing
cat only-stdout.log # no error line inside ✗

# The modern bash shorthand for "both to a file":
ls /etc /nope &> apply.log
cat apply.log       # both streams, one operator
```

**Verify:** `both.log` and `apply.log` each contain the listing *and* the error; `only-stdout.log` is missing the error (it went to your screen). If the flipped version had captured the error too, revisit Rung 3B — `2>&1` would have to be a live link, which it isn't.

---

## Prediction 3 — `/dev/null` hushes `find`'s noise without losing results

> **My prediction:** "If I run `find` across the whole filesystem with `2>/dev/null`, the 'Permission denied' spam disappears but the real matches remain — *because* `find` sends errors to FD 2 (redirected to the void) and matches to FD 1 (untouched, still on screen or in the pipe)."

```bash
# Without hushing — drowns in permission errors:
find / -name '*.key' -type f | head       # stderr noise interleaves

# With hushing — clean list of real matches only:
find / -name '*.key' -type f 2>/dev/null | head
# e.g. /etc/kubernetes/pki/ca.key  (the real hit survives)

# tee to watch AND save the clean results at once:
find / -name '*.key' -type f 2>/dev/null | tee keys.txt | wc -l
cat keys.txt
```

**Verify:** The second command shows only real paths, no "Permission denied"; `tee` both prints the count *and* leaves `keys.txt` on disk. If matches also vanished, you accidentally redirected FD 1 (results) instead of FD 2 — recheck which number precedes the `>`.

---

## Prediction 4 — `pipefail` changes who owns the pipeline's exit code

> **My prediction:** "If a middle stage of a pipe fails, by default the pipeline still reports success (exit 0) because only the *last* command's status counts — but with `set -o pipefail`, the pipeline reports failure — *because* `pipefail` makes the shell return the rightmost *non-zero* status instead of just the last stage's."

```bash
# Default behavior: failure of an early stage is masked.
# (Getting a NAMED pod that doesn't exist reliably errors with exit 1 —
#  note: `get pods -n <bad-ns>` does NOT fail, it just prints
#  "No resources found" and exits 0, so we query a specific pod instead.)
kubectl get pod does-not-exist-pod | wc -l
echo "exit status = $?"        # => 0, because wc succeeded! ✗ misleading

# Turn on pipefail (do this at the top of every serious script):
set -o pipefail
kubectl get pod does-not-exist-pod | wc -l
echo "exit status = $?"        # => non-zero, the real failure surfaces ✅
set +o pipefail                # (turn it back off for the demo)
```

**Verify:** Same pipeline, two different exit codes — `0` before, non-zero after enabling `pipefail`. This is the #1 reason CI scripts pass while silently broken: without `pipefail`, `kubectl get ... | grep ...` reports success even when `kubectl` itself errored. If both runs gave `0`, confirm your shell is bash (`pipefail` is not in POSIX `sh`).

---

## Prediction 5 — `xargs -I{}` templates one item per invocation

> **My prediction:** "Plain `xargs cmd` appends *all* items as arguments to one command, but `xargs -I{} cmd {} suffix` runs the command *once per item* with `{}` replaced — *because* `-I` switches xargs from 'batch all into argv' to 'substitute each item into a template, one run at a time.'"

```bash
# Batch mode: ONE kubectl call with many pod-name arguments (efficient)
kubectl get pods --no-headers | grep CrashLoop | awk '{print $1}' \
  | xargs kubectl delete pod
# => runs: kubectl delete pod crashy-1 crashy-2 crashy-3

# Template mode: ONE call PER item, item placed at {} (needed when the
# item isn't the last arg, or you want per-item flags)
kubectl get pods --no-headers -o custom-columns=NAME:.metadata.name \
  | xargs -I{} kubectl annotate pod {} reviewed=true --overwrite
# => runs: kubectl annotate pod crashy-1 reviewed=true --overwrite
#          kubectl annotate pod crashy-2 reviewed=true --overwrite  (etc.)
```

**Verify:** In batch mode the pods delete in a single API call (fast); in `-I{}` mode you see one annotate line per pod. If `-I{}` seemed to run only once with everything jammed in, check that `{}` appears in the template exactly. Edge note: `xargs` splits on whitespace by default, so a filename with spaces breaks it — use `xargs -0` with `find -print0` for those.

---

## Prediction 6 — A heredoc *is* the manifest: `kubectl apply -f - <<EOF`

> **My prediction:** "If I pipe a heredoc into `kubectl apply -f -`, the resource will be created with no file on disk — *because* `-f -` tells kubectl to read the manifest from stdin, and the heredoc points kubectl's FD 0 at an in-memory buffer holding the YAML."

```bash
# Create a ConfigMap with no file anywhere — the heredoc is the file:
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ladder-demo
data:
  lesson: "stdin is FD 0"
EOF
# => configmap/ladder-demo created

kubectl get configmap ladder-demo -o jsonpath='{.data.lesson}'; echo
# => stdin is FD 0

# <<-EOF strips leading TABS so you can indent inside a function/if-block.
# (The lines below must be indented with real tab characters, not spaces.)
if true; then
	kubectl apply -f - <<-EOF
	apiVersion: v1
	kind: ConfigMap
	metadata:
	  name: ladder-demo-2
	data: {note: "tabs stripped"}
	EOF
fi

# A here-string feeds a single line to stdin — handy for base64:
base64 <<< "supersecret"          # => c3VwZXJzZWNyZXQK
```

**Verify:** `configmap/ladder-demo created` with no `.yaml` file present; `jsonpath` echoes the value back. `base64 <<< "x"` prints one encoded line. If `<<-EOF` complained about indentation, you indented with spaces — `<<-` strips **tabs only**. Clean up: `kubectl delete configmap ladder-demo ladder-demo-2 --ignore-not-found`.

---

## Prediction 7 — Process substitution diffs two live clusters and decodes a secret

> **My prediction:** "If I run `diff <(kubectl get pods -n a) <(kubectl get pods -n b)`, diff will compare the two namespaces' live output with no temp files — *because* each `<(...)` becomes a `/dev/fd/NN` filename that diff opens and reads. And `openssl x509 < <(...)` will parse a base64-decoded secret straight from a pipe."

```bash
# Diff the pod inventories of two namespaces, no temp files:
diff <(kubectl get pods -n default --no-headers | awk '{print $1}' | sort) \
     <(kubectl get pods -n kube-system --no-headers | awk '{print $1}' | sort)
# => < / > lines show pods unique to each namespace

# Prove <() is really a filename:
echo <(true)                       # => /dev/fd/63  (or similar)

# Decode a TLS secret and inspect the cert via process substitution.
# This reads the cert into openssl WITHOUT ever writing tls.crt to disk:
openssl x509 -noout -subject -enddate \
  < <(kubectl get secret my-tls -n default \
        -o jsonpath='{.data.tls\.crt}' | base64 -d)
# => subject=CN=my-service ... / notAfter=Aug 30 12:00:00 2026 GMT
```

**Verify:** `diff` prints only the differing pod names (nothing if identical); `echo <(true)` reveals a `/dev/fd/NN` path — proof the shell handed a *filename*, not text. The `openssl` line prints the cert's subject and expiry with no `tls.crt` file created. If `<()` gave a "syntax error," you're in `sh`, not `bash` — rerun under `bash`. Replace `my-tls` with a real secret name (`kubectl get secrets` to find one).

---

## The prediction habit, generalized

Fill this in for anything new you try with redirection:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> Every process holds a numbered table of open files where `0`/`1`/`2` are stdin/stdout/stderr, and redirection, pipes, heredocs, and process substitution are all just the shell editing that table — pointing a slot at a file, at the void, or at another program's slot — before your command ever runs.

**Explain it to a beginner in 3 sentences:**
> 1. A program doesn't decide where its output goes; it just writes to "channel 1" (stdout) and complaints to "channel 2" (stderr), and the shell decides where those channels actually lead — the screen, a file, or another program.
> 2. `>` and `2>` bend those output channels to files, `<` and `<<EOF` feed the input channel from a file or inline text, and `|` welds one program's channel-1 directly into the next program's channel-0 through a shared memory buffer.
> 3. Everything fancier — `tee` to save-and-pass, `xargs` to turn a stream into command arguments, `while read -r` to loop per line, `<(...)` to make a command look like a file — is a variation on the same one move: control where the bytes flow.

**Map of sub-capability → the one core idea (all one pattern):**

```
Every capability = "edit which file a numbered slot points at":

>  >>  2>  &>   → point an OUTPUT slot (1 and/or 2) at a file
<              → point the INPUT slot (0) at a file
2>&1           → point slot 2 at slot 1's current target
/dev/null      → point a slot at the discard device
| (pipe)       → point one program's slot 1 at another's slot 0
tee            → duplicate a stream: to a file AND onward
xargs          → drain a stream, rebuild it as command arguments
while read -r  → drain a stream, one line into shell variables
<<EOF / <<<    → point slot 0 at an in-memory text buffer
<(...) >(...)  → wrap a pipe as a readable/writable filename
```

Ten rows, one idea: *output destination is data the shell edits, not logic the program owns.*

**Which rung will I most likely need to revisit hands-on?**

Be honest with yourself, but the two usual suspects are:

- **Rung 3B (order of `2>&1`).** The snapshot-not-a-link behavior is counterintuitive until you've been bitten. The fix: run Prediction 2 both ways and watch the error move.
- **Rung 6, Contrast B (`xargs` vs `while read`, and the `for` trap).** You can *state* "don't loop with `for $(...)`," but explaining *why the shell splits on whitespace and globs* takes a couple of reps. Rehearse it against a filename with a space in it.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [The Unix Philosophy: Everything is a File](01-linux-philosophy.md) — *why* stdin/stdout/stderr are just files, and where file descriptors come from (`/proc/<pid>/fd`).
- [The Shell & Environment](02-shell-and-environment.md) — the shell is the thing that *parses* redirection and edits the FD table before `exec`.
- [Text Processing](09-text-processing.md) — `grep`, `awk`, `sed`, `jq`: the programs you weld together with the pipes from this chapter.
- [Shell Scripting](08-shell-scripting.md) — `set -o pipefail`, `while read -r` loops, traps, and where redirection lives inside real scripts.
- [Processes & Job Control](07-processes-job-control.md) — `fork`/`exec`, how children inherit the FD table, and how pipes coordinate concurrent processes.
- [TLS, PKI & OpenSSL](26-tls-pki-openssl.md) — the `openssl x509 < <(... | base64 -d)` secret-decoding trick, in depth.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why can `sort` feed `uniq` without either program containing any code that mentions the other? Who decides where `sort`'s output goes, and *when* is that decided?

**A:** Because neither program names its destinations at all — each is born holding three already-open channels and just reads FD 0 and writes FD 1 blindly. The **shell** decides where those channels point, and it decides *before either program starts running*: for `sort | uniq` it creates a kernel pipe buffer, points `sort`'s stdout at the pipe's write end and `uniq`'s stdin at the pipe's read end, then execs both. That decoupling — programs write to a generic channel, the shell wires the channels — is the Unix design bet that makes arbitrary composition (`a | b | c`) possible without any program knowing about any other.

### Before Rung 3
**Q:** Say the core sentence from memory. When you run `ls > out.txt`, does `ls` open the file? If not, who does, and at what moment relative to `ls` starting?

**A:** The core sentence: every process is born holding a small numbered table of open files; `0` is where it reads (stdin), `1` is where it writes (stdout), `2` is where it writes errors (stderr) — and redirection and pipes are just the shell editing that table before the process starts. No — `ls` never opens `out.txt` and is never even told it exists; the shell strips `> out.txt` off the command line during parsing. The **shell** opens the file in the forked child, *between fork and exec*: it does `open("out.txt")`, `dup2`s that descriptor onto FD 1, then execs `ls`. Since exec doesn't reset the FD table, `ls` inherits slot 1 already pointing at the file and just writes to FD 1 as always, thinking it's the screen.

### Before Rung 4
**Q:** Draw the FD table for `find / 2>/dev/null | wc -l`. (1) Where does FD 2 of `find` point? (2) Where does FD 1 of `find` point? (3) Which FD of `wc` is connected, and to what? (4) Why does the "Permission denied" text never reach `wc`?

**A:** (1) `find`'s FD 2 points at `/dev/null`, the kernel device that discards all writes. (2) `find`'s FD 1 points at the write end of the kernel pipe the shell created for `|`. (3) `wc`'s FD 0 (stdin) is connected to the read end of that same pipe; its FD 1 still points at the terminal, so you see the count. (4) The "Permission denied" text never reaches `wc` because a pipe carries FD 1 only — the errors travel on FD 2, which was severed to `/dev/null` at the source, a completely separate channel from the pipe joining find's stdout to wc's stdin. So `wc -l` counts only real matches.

### Before Rung 5
**Q:** `<<<"hello"` and `<(echo hello)` both feed something to a command. What's the difference in *what the command receives*?

**A:** With the here-string `<<<"hello"`, the command receives the text on **stdin**: the shell points the command's FD 0 at an in-memory buffer holding the string, and the program just reads FD 0 — no name, no open() needed. With process substitution `<(echo hello)`, the command receives a **filename** as an argument (something like `/dev/fd/63`, the read end of a pipe wrapped as a path) which the command must itself open and read. That's why `<(...)` is the tool when a program wants file *arguments* rather than stdin — e.g. `diff` needing two inputs at once, which a single stdin can never provide.

### Before Rung 6
**Q:** At Step 6, why is `xargs` mandatory — what happens with `... | awk '{print $1}' | kubectl delete pod` and no `xargs`? And at Step 3, if you removed the `2>/dev/null`, where would kubectl's warnings appear — in `grep`'s input, or on your screen? Why?

**A:** `xargs` is mandatory because `kubectl delete pod` reads its targets from **argv** (command-line arguments), not from stdin — pipe pod names at it and it simply ignores the stream, deleting nothing (it would just complain that no pod names were given). `xargs` is the adapter that drains the stream and rebuilds it as arguments, effectively running `kubectl delete pod crashy-1 crashy-2 crashy-3`. Without `2>/dev/null`, kubectl's warnings would appear **on your screen**, not in `grep`'s input: a pipe connects only FD 1 to the next stage's FD 0, and warnings travel on FD 2, which — with the redirection removed — still points at the terminal. Stderr never rides the pipe unless you explicitly merge it first with `2>&1`.

### Before Rung 7
**Q:** Why does `for f in $(ls)` break on a file named `my report.txt` but `ls | while read -r f` does not — in terms of *when and on what* the shell splits?

**A:** In `for f in $(ls)`, the shell expands `$(ls)` first and then word-splits the whole result on **all whitespace** — spaces, tabs, and newlines alike — and also performs glob expansion on the pieces. So `my report.txt` is split at the space into two separate iterations, `my` and `report.txt`, neither of which exists. `while read -r f` never does that expansion-then-split: `read` consumes the stream **one full line at a time**, so the line `my report.txt` lands intact in `$f` (and `-r` additionally stops `read` from treating backslashes as escapes). The rule of thumb: iterate lines with `while read -r`, never with `for … in $(…)` — the difference is splitting on any whitespace at expansion time versus splitting only on newlines at read time.

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios

> **How to use this lab:** Use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance). Each **Setup** drops a small script or data file under `/opt/lab-*`; your job is to wire streams together with the right redirection/pipe/`xargs`/heredoc/process-substitution move and prove it with the **Verify** command — *without* peeking at the solutions at the bottom of this file. Difficulty rises from Scenario 1 to 6. Every fix is a file-descriptor move from this chapter, not a Kubernetes trick.

### 🟢 Scenario 1 — "Toyama: keep the findings, bin the noise" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-toyama
sudo tee /opt/lab-toyama/scan.sh >/dev/null <<'EOF'
#!/bin/bash
echo "result: alpha"
echo "scan error: cannot read /root/secret" >&2
echo "result: bravo"
echo "scan error: permission denied /etc/shadow" >&2
echo "result: charlie"
EOF
sudo chmod +x /opt/lab-toyama/scan.sh
```
**Situation:** A scanner writes real findings to **stdout** and permission-error noise to **stderr**. You want a clean file containing only the findings, with the error spam thrown away.

**Your task:** Run `/opt/lab-toyama/scan.sh`, capturing **only its stdout** (the `result:` lines) into `/tmp/lab-toyama.out`, and discard the error output entirely.

**Verify:**
```bash
[ "$(wc -l < /tmp/lab-toyama.out)" = 3 ] && ! grep -q error /tmp/lab-toyama.out && echo CORRECT
# expected: CORRECT  (3 result lines, zero error lines)
```

### 🟢 Scenario 2 — "Fukui: one timeline, both streams" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-fukui
sudo tee /opt/lab-fukui/deploy.sh >/dev/null <<'EOF'
#!/bin/bash
echo "INFO: starting rollout"
echo "WARN: replica 2 not ready" >&2
echo "INFO: rollout complete"
EOF
sudo chmod +x /opt/lab-fukui/deploy.sh
```
**Situation:** For an incident timeline you need a **single** log file that contains both the `INFO` output (stdout) and the `WARN` diagnostics (stderr) together — and nothing should scroll past on your terminal.

**Your task:** Run `/opt/lab-fukui/deploy.sh` capturing **both** stdout and stderr into `/tmp/lab-fukui.log`.

**Verify:**
```bash
grep -q 'INFO: rollout complete' /tmp/lab-fukui.log \
  && grep -q 'WARN: replica 2 not ready' /tmp/lab-fukui.log && echo CORRECT
# expected: CORRECT  (both streams landed in the one file)
```

### 🟡 Scenario 3 — "Matsue: quarantine every crash-looper" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-matsue
sudo tee /opt/lab-matsue/pods.txt >/dev/null <<'EOF'
NAME     STATUS             NODE
web-1    Running            node-a
web-2    CrashLoopBackOff   node-b
api-1    Running            node-a
api-2    CrashLoopBackOff   node-c
db-1     CrashLoopBackOff   node-b
EOF
```
**Situation:** You need to run a bulk action on every crash-looping pod. Simulate it: for each pod whose STATUS is `CrashLoopBackOff`, drop a marker file named after the pod under `/tmp/lab-matsue-quarantine/`. The pod names come out of a pipeline as a *stream*, but `touch` needs them as *arguments*.

**Your task:** Extract the `CrashLoopBackOff` pod names from the table and, turning that stream into command arguments, create one empty marker file per pod under `/tmp/lab-matsue-quarantine/`.

**Verify:**
```bash
[ "$(ls /tmp/lab-matsue-quarantine 2>/dev/null | sort | tr '\n' ',')" = "api-2,db-1,web-2," ] && echo CORRECT
# expected: CORRECT  (exactly the three crash-loopers, no others)
```

### 🟡 Scenario 4 — "Matsuyama: names with spaces break the loop" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-matsuyama
sudo tee /opt/lab-matsuyama/services.txt >/dev/null <<'EOF'
payment gateway
user service
order queue
EOF
```
**Situation:** A list of service display-names — each containing a space — must each get its own directory under `/tmp/lab-matsuyama-out/`. A naive `for name in $(cat services.txt)` splits on every space and creates six wrong directories (`payment`, `gateway`, `user`, …). You must iterate so each **full line** becomes exactly one directory.

**Your task:** Create one directory per line (spaces preserved) under `/tmp/lab-matsuyama-out/` — three directories total.

**Verify:**
```bash
[ "$(ls /tmp/lab-matsuyama-out 2>/dev/null | wc -l)" = 3 ] \
  && [ -d "/tmp/lab-matsuyama-out/payment gateway" ] \
  && [ -d "/tmp/lab-matsuyama-out/user service" ] \
  && [ -d "/tmp/lab-matsuyama-out/order queue" ] && echo CORRECT
# expected: CORRECT  (three dirs, each a whole line)
```

### 🟠 Scenario 5 — "Kochi: the failures the pipe swallowed" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-kochi
sudo tee /opt/lab-kochi/job.sh >/dev/null <<'EOF'
#!/bin/bash
for i in 1 2 3 4 5; do
  if (( i % 2 == 0 )); then
    echo "task $i FAILED" >&2
  else
    echo "task $i ok"
  fi
done
EOF
sudo chmod +x /opt/lab-kochi/job.sh
```
**Situation:** A batch job writes its `ok` lines to stdout and its `FAILED` lines to **stderr**. You need a count of how many tasks failed, but the obvious `job.sh | grep -c FAILED` returns `0` — because a pipe carries **only stdout (FD 1)**, and the failures rode away on FD 2 to the terminal, never entering the pipe.

**Your task:** Count how many tasks `FAILED` and write just that number to `/tmp/lab-kochi.txt`.

**Verify:**
```bash
grep -qx '2' /tmp/lab-kochi.txt && echo CORRECT   # expected: CORRECT (2 tasks failed)
```

### 🔴 Scenario 6 — "Naha: what runs in prod but not stage?" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-naha
sudo tee /opt/lab-naha/prod-pods.txt >/dev/null <<'EOF'
api
cache
db
frontend
worker
EOF
sudo tee /opt/lab-naha/stage-pods.txt >/dev/null <<'EOF'
api
db
frontend
metrics
worker
EOF
```
**Situation:** You must find which workloads run in **prod but not in stage**. You have two name lists. The clean way — no temp files — is to feed two *sorted live streams* into a two-input comparison tool by making each stream look like a file.

**Your task:** Using **process substitution** to hand a comparison tool two sorted inputs at once, list the names present in `prod-pods.txt` but absent from `stage-pods.txt`, and write them (one per line) to `/tmp/lab-naha.txt`.

**Verify:**
```bash
grep -qx 'cache' /tmp/lab-naha.txt && [ "$(wc -l < /tmp/lab-naha.txt)" = 1 ] && echo CORRECT
# expected: CORRECT  (only "cache" is prod-only)
```

---

## 🔑 Lab Answers — Solutions & Explanations

### Scenario 1 — "Toyama: keep the findings, bin the noise"
**Solution:**
```bash
/opt/lab-toyama/scan.sh > /tmp/lab-toyama.out 2>/dev/null
cat /tmp/lab-toyama.out    # only the three result: lines
```
**Why this works & what it teaches:** `find`-style noise and real results travel on **separate channels** — results on FD 1, errors on FD 2 (Rung 3A). `> /tmp/lab-toyama.out` re-points FD 1 at the file; `2>/dev/null` re-points FD 2 at the kernel's discard device. Because the two are independent slots, keeping one and binning the other is trivial. **Where people go wrong:** writing `2>/tmp/lab-toyama.out` (capturing the *errors* instead of the results) or `&>` (capturing *both*) — the digit before `>` selects exactly which slot you are rewiring.

### Scenario 2 — "Fukui: one timeline, both streams"
**Solution:**
```bash
/opt/lab-fukui/deploy.sh > /tmp/lab-fukui.log 2>&1
# equivalently (bash shorthand):
#   /opt/lab-fukui/deploy.sh &> /tmp/lab-fukui.log
cat /tmp/lab-fukui.log     # INFO lines and the WARN line, interleaved
```
**Why this works & what it teaches:** `> file` first points FD 1 at the log; then `2>&1` points FD 2 at **whatever FD 1 currently references** — the file — so both streams converge there (Rung 3B). **Where people go wrong:** the classic order trap — writing `2>&1 > file` clones FD 2 onto FD 1 *while FD 1 still points at the terminal*, so errors leak to the screen and only stdout reaches the file. `2>&1` is a snapshot of FD 1's target at that instant, not a live link, so it must come **after** the `> file`.

### Scenario 3 — "Matsue: quarantine every crash-looper"
**Solution:**
```bash
mkdir -p /tmp/lab-matsue-quarantine
grep CrashLoopBackOff /opt/lab-matsue/pods.txt | awk '{print $1}' \
  | xargs -I{} touch /tmp/lab-matsue-quarantine/{}
ls /tmp/lab-matsue-quarantine    # api-2  db-1  web-2
```
**Why this works & what it teaches:** `grep`+`awk` produce a *stream* of pod names on stdout, but `touch` takes its targets from **argv**, not stdin — piping directly at `touch` would do nothing. `xargs` is the adapter that drains the stream and rebuilds it as arguments (Rung 3C / Rung 5, the same reason `xargs kubectl delete pod` exists). `-I{}` runs `touch` once per name with `{}` substituted, so the name can sit mid-path. **Where people go wrong:** expecting `... | touch` to work (a pipe feeds FD 0, but `touch` reads argv), or using plain `xargs touch DIR/` where the name isn't the trailing argument — that's exactly when `-I{}` templating is required.

### Scenario 4 — "Matsuyama: names with spaces break the loop"
**Solution:**
```bash
mkdir -p /tmp/lab-matsuyama-out
while read -r name; do
  mkdir -p "/tmp/lab-matsuyama-out/$name"
done < /opt/lab-matsuyama/services.txt
ls /tmp/lab-matsuyama-out    # 'order queue'  'payment gateway'  'user service'
```
**Why this works & what it teaches:** `while read -r` consumes stdin **one whole line at a time**, so a line containing spaces lands intact in `$name` (and `-r` stops backslashes being eaten) — Rung 6, Contrast B. The redirection `< file` points the loop's FD 0 at the file. **Where people go wrong:** `for name in $(cat services.txt)` — the shell word-splits the command substitution on *all* whitespace (and globs it) at expansion time, shattering `payment gateway` into two iterations and producing six wrong directories. Iterate lines with `while read -r`, never with `for … in $(…)`; and always quote `"$name"`.

### Scenario 5 — "Kochi: the failures the pipe swallowed"
**Solution:**
```bash
/opt/lab-kochi/job.sh 2>&1 | grep -c FAILED > /tmp/lab-kochi.txt
cat /tmp/lab-kochi.txt     # 2
```
**Why this works & what it teaches:** A pipe wires only the producer's **FD 1** into the consumer's FD 0 (Rung 3C) — the `FAILED` lines were written to FD 2, so `job.sh | grep` never saw them and counted `0`. Prefixing the pipe with `2>&1` merges FD 2 into FD 1 **before** the `|`, so both streams flow into `grep`, which now counts the two failures. **Where people go wrong:** putting the merge in the wrong place (`job.sh | grep -c FAILED 2>&1` merges *grep's* streams, far too late) — stderr must be folded into stdout on the **producer** side of the pipe, i.e. immediately after `job.sh`.

### Scenario 6 — "Naha: what runs in prod but not stage?"
**Solution:**
```bash
comm -23 <(sort /opt/lab-naha/prod-pods.txt) <(sort /opt/lab-naha/stage-pods.txt) \
  > /tmp/lab-naha.txt
cat /tmp/lab-naha.txt      # cache
```
**Why this works & what it teaches:** `comm` needs **two** sorted file inputs at once — something a single pipe (one stdin) can never provide. Each `<(sort …)` runs its command in the background, wraps its stdout as a `/dev/fd/NN` **filename**, and hands that path to `comm` (Rung 3D). `comm -23` suppresses column 2 (lines only in stage) and column 3 (shared), leaving column 1 — names only in prod: `cache`. No temp files touch disk. **Where people go wrong:** reaching for temp files (`sort a > /tmp/a; sort b > /tmp/b; comm …`) and forgetting to clean them, or trying to feed both lists through one `|` — two-input tools like `comm`/`diff` are precisely what process substitution exists for. (`diff <(sort a) <(sort b)` is the same idea when you want the full delta.)

