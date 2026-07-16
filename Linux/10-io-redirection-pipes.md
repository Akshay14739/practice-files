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
