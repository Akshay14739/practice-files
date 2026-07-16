# Shell Scripting, Climbed the Ladder 🪜
### Learning bash scripting from the ground up for a Kubernetes engineer — deriving how a script thinks, not memorizing syntax

> This is your Linux-from-scratch guide, rebuilt on the Learning Ladder. Instead of leading with syntax, we climb from **why scripts exist** → **the one core idea** → **the machinery** → and only at the very top, the hands-on commands. Each rung ends with a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The persona:** you're a Kubernetes platform engineer, ~6 years in DevOps/support, fluent in `kubectl` but newer to what happens *inside* the scripts that glue your platform together. You've copy-pasted a hundred `deploy.sh` files. Today you learn to *read one like a compiler does* — so the next one that fails a rollout at 2 AM doesn't scare you.

---

# RUNG 0 — The Setup

**What am I learning?**
**Bash scripting** — how to write a file of shell commands that runs top-to-bottom as one program: variables, arrays, arithmetic, control flow (`if`/`case`/`for`/`while`), functions with `local` variables and return codes, error handling with `set -euo pipefail` and `trap`, and how a script signals success or failure through **exit codes**.

**Why did it land on my desk?**
Your team's deployment is a 30-line `deploy.sh` that someone wrote two years ago. It does `kubectl set image`, waits for the rollout, and checks health. Last week it "succeeded" while the app was actually crash-looping — the script exited `0` even though a step silently failed. Your lead asked you to *own* that script: make it fail loudly when a step fails, clean up after itself, and be readable by the next on-call engineer. To do that you can't cargo-cult bash anymore. You need to know what `set -euo pipefail` actually protects you from, why `$?` matters, and how a `trap` guarantees cleanup even when the script dies halfway.

**What do I already know about it?**
You know a script starts with `#!/bin/bash`. You've written `for` loops over pods interactively. You've seen `$1` and `$@` and vaguely know they're "arguments." You know `echo $?` shows "whether the last thing worked." You do *not* yet have a crisp model of: why a plain bash script barrels past failures by default, the difference between a shell variable and an environment variable inside a function, what `local` really scopes, how `${VAR:-default}` and `${VAR^^}` work, or how a `trap` fires on exit. By the top of this ladder, a production deploy script is something you can *write from the mechanism*, not paste from memory.

---

# RUNG 1 — The Pain 🔥
### *Why does shell scripting exist at all?*

Sit with the problem before you touch a command. If you feel the pain, you can *derive* what a script must do — and most of the syntax stops needing memorization.

### The problem that forced scripting into existence

Interactively, the shell is a conversation: you type a line, see the result, decide the next line *with your human brain in the loop*. That's wonderful for exploration and useless for repetition. The moment you need to run *the same twelve commands, in order, with decisions between them, ten times a day* — the human-in-the-loop becomes the bottleneck. You mistype step 7. You forget step 4 exists. You do steps in the wrong order at 2 AM.

So the raw pain is: **a sequence of commands, with decisions and repetition baked in, needs to run without a human retyping it each time — and it needs to make the same decisions the human would have made.** A script is the shell's answer: a *saved conversation* that can branch (`if`), loop (`for`/`while`), remember values (variables), and factor out repetition (functions).

```
INTERACTIVE SHELL vs SCRIPT — the gap scripting fills

  Interactive:                       Script:
  you ──type──▶ shell ──▶ result     file ──feeds──▶ shell ──▶ result
      ▲___________|                       (no human between lines)
      human decides next line             the FILE decides, via
                                          if / for / while / functions

  Fine for 3 commands once.          Required for 30 commands, daily,
  A nightmare for 30 commands        with branching and no typos.
  ten times a day.
```

### What people did *before* — and why it hurt

Before scripts, repetition was done **by hand** (retype everything, hope you remember the order) or with **fragile shortcuts**: a text file of commands you'd copy-paste line by line into the terminal. That "runbook in a wiki" approach is still everywhere — and it hurts precisely because *there's no logic in it*. A pasted runbook can't check "did the previous command succeed before I run the next?" It can't loop over an unknown number of pods. It can't stop when step 3 fails — it just keeps pasting steps 4, 5, 6 into a broken system. That's exactly how your `deploy.sh` reported success over a crash-loop: it had no notion of "stop on failure."

### What breaks without it (the Kubernetes angle)

Scripting is not just *your* convenience — it is the connective tissue of the whole platform:

- **kubelet** runs container lifecycle hooks and health probes; `exec` liveness/readiness probes are literally shell commands (`command: ["sh","-c","curl -f localhost:8080/healthz"]`) whose **exit code** decides if your pod is restarted. A probe that returns non-zero = a restart. Exit codes are life-and-death.
- **Init containers, `postStart`/`preStop` hooks, Jobs, CronJobs** are overwhelmingly small bash scripts. When they misbehave, you debug bash.
- **Helm chart hooks, CI/CD pipelines, node bootstrap (kubeadm wrappers, cloud-init)** are scripts. A missing `set -e` in a node-provisioning script means a half-configured node that *reports ready* — the worst kind of failure.
- Container **`ENTRYPOINT`s** are frequently `#!/bin/bash` wrapper scripts that template config, wait for a dependency, then `exec` the real process.

Without disciplined scripting, every one of these silently swallows failure. The entire "did it actually work?" question in Kubernetes bottoms out in *an exit code a script produced*.

> **✅ Check yourself before Rung 2:** In one breath — why is a copy-paste runbook fundamentally weaker than a script, even if it contains the exact same commands? (Hint: what can a script do *between* two commands that a paste cannot?)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Memorize this exact sentence. Every other fact in this file can be *derived* from it:

> **A bash script is just the lines you'd type, run in order by a shell process, where every command produces an exit code (0 = success), and all of scripting is (a) storing values in variables, (b) branching and looping on those exit codes, and (c) controlling what happens when one is non-zero.**

That's the whole trick. Read it again. Everything else is detail on one of its three parts.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"the lines you'd type, run in order by a shell process"* → the **shebang** `#!/bin/bash` just says *which* shell process; the script is otherwise nothing magic — same expansion, same `fork`/`execve` as your interactive shell.
- *"every command produces an exit code (0 = success)"* → this is why `if` doesn't test a boolean, it tests an **exit code**. `if kubectl get ns prod` branches on whether that command *succeeded*, not on any value. `$?` is just the last exit code, saved.
- *"storing values in variables"* → `NAME="x"`, arrays, `${VAR:-default}`, `$(( ))`, `$(...)` — all just *ways to produce and shape values* you'll branch on or pass to commands.
- *"branching and looping on those exit codes"* → `if`/`elif`/`case`/`for`/`while` are all built on "run this, look at the exit code (or a value), decide."
- *"controlling what happens when one is non-zero"* → this is `set -euo pipefail`, `trap`, `error() { ... >&2; exit 1; }`, and return codes from functions. It's the entire discipline of *not marching past failure*.

Once you see that **the exit code is the atom** — every command emits one, and every control structure and safety flag is a way of *reacting to it* — bash stops being a pile of cryptic punctuation and becomes one idea applied many ways.

> **✅ Check yourself before Rung 3:** Cover the sentence. Say it from memory. Then answer: when you write `if kubectl get ns prod >/dev/null 2>&1; then`, what *exactly* is the `if` testing — the text output, or something else? Why does that mean `if [[ ... ]]` is really just a command too?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

We open the hood. There are five things to understand: **(A) what the shebang does at exec time, (B) the exit-code substrate everything sits on, (C) how variables and expansion produce values, (D) how `set -euo pipefail` rewires the shell's default "barrel past failure" behavior, and (E) how functions, scope, and traps work.**

## (A) The shebang — what actually happens when you run `./deploy.sh`

The shebang line `#!/bin/bash` is not a bash feature — it's a **kernel** feature. When you `execve("./deploy.sh", ...)`, the kernel reads the first two bytes of the file. If they are `#!` (hex `23 21`, called a "shebang" or "hashbang"), the kernel does *not* try to run the file as a binary. Instead it reads the rest of that first line as an interpreter path, and re-runs as if you'd typed **that interpreter with your file as an argument**.

```
WHAT THE KERNEL DOES WITH  ./deploy.sh   (first line: #!/bin/bash)

  you: ./deploy.sh --image=nginx:1.27
        │
        ▼  execve("./deploy.sh", ["./deploy.sh","--image=nginx:1.27"], env)
  ┌───────────────── kernel ─────────────────┐
  │ read first 2 bytes: '#' '!'  → shebang!  │
  │ read interpreter:  /bin/bash             │
  │ REWRITE the exec as:                     │
  │   execve("/bin/bash",                    │
  │     ["/bin/bash","./deploy.sh",          │
  │       "--image=nginx:1.27"], env)        │
  └───────────────────┬──────────────────────┘
                      ▼
              /bin/bash now runs, reading deploy.sh line by line.
              Inside the script: $0=./deploy.sh  $1=--image=nginx:1.27
```

Consequences you can now *derive*:
- **Why it matters:** without the shebang, the kernel doesn't know your text file is a bash program. Whether it runs at all then depends on *who* is launching it and how — a subtle, non-portable mess. The shebang makes the file self-describing: "run me with bash."
- `#!/bin/bash` vs `#!/bin/sh`: on Ubuntu `/bin/sh` is **dash**, a minimal POSIX shell with **no arrays, no `[[ ]]`, no `${VAR^^}`**. If your script uses those (it will), `#!/bin/bash` is mandatory. In an Alpine container there may be *no* `/bin/bash` at all — only `/bin/sh` (busybox). This is a real Kubernetes gotcha: a script with `#!/bin/bash` fails inside a slim image with `exec: bash: not found`.
- `#!/usr/bin/env bash` is the portable variant: it searches `$PATH` for bash instead of hard-coding `/bin/bash`, useful when bash lives elsewhere (macOS/Homebrew, Nix).

## (B) The exit-code substrate — the thing everything sits on

Every process that ends hands the kernel an **8-bit exit status** (0–255). The parent shell reads it via `wait()` and stores it in the special variable **`$?`**. Convention, honored by essentially all Unix tools:

- **`0` = success.** Non-zero = some kind of failure (and the specific number can encode *which* failure).
- `1` = generic error, `2` = misuse of builtins, `126` = found but not executable, `127` = command not found, `128+N` = killed by signal N (so `137` = `128+9` = SIGKILL — **the OOM-killed exit code you see in `kubectl describe pod`**, and `143` = `128+15` = SIGTERM).

This is the load-bearing fact: **`if`, `while`, `&&`, `||`, and `set -e` all read `$?`, not any text.** A command's *output* goes to stdout; its *verdict* goes to the exit code. Tests are just commands too — `[[ "$x" == "Running" ]]` is a command that exits `0` if the comparison holds, `1` otherwise. `[` is literally a program (`/usr/bin/[`) as well as a builtin.

```
THE ATOM: every command → an exit code → $?

  kubectl rollout status ...        prints text to stdout/stderr
        └────────────────────────▶  AND exits with a code
                                         0  rollout complete
                                         1  timed out / failed
                                         ▼
                              shell stores it in  $?
                                         ▼
        if / while / && / || / set -e   all branch on THIS number
```

## (C) Variables and expansion — how values are produced and shaped

A variable is just a name → string mapping in the shell's memory. `NAME="x"` sets it (no spaces around `=` — `NAME = "x"` tries to *run a command* called `NAME`). `$NAME` or `${NAME}` expands it. Everything bash does with values is **parameter expansion**, and bash gives you a rich toolkit *inside the braces*:

```
PARAMETER EXPANSION — shaping a value without calling any external tool
  (APP="checkout")

  ${APP}          checkout          the value
  ${#APP}         8                 LENGTH of the value
  ${APP^^}        CHECKOUT          UPPERCASE  (^ = one char, ^^ = all)
  ${APP,,}        checkout          lowercase
  ${APP:0:5}      check             SUBSTRING: offset 0, length 5
  ${APP:5}        out               substring from offset 5 to end
  ${REPLICAS:-3}  3 (if REPLICAS unset/empty)   DEFAULT value
  ${REPLICAS:=3}  3 AND assigns REPLICAS=3      default + assign
  ${IMG#*/}       strip shortest leading match of */   (registry strip)
  ${IMG%:*}       strip shortest trailing :... (drop the tag; % vs %% = shortest vs longest match)
  ${TAG/-/_}      replace first '-' with '_'
```

`${VAR:-default}` is the workhorse of robust scripts: *"use `$VAR`, but if it's unset or empty, use this fallback."* That's how you write `REPLICAS="${REPLICAS:-3}"` — respect an override, default to 3.

Two more value-producers you'll lean on constantly:

- **Arithmetic** `$(( ... ))`: bash does integer math *inside* the double parens. `$(( COUNT * 2 ))`, `$(( ATTEMPT + 1 ))`. Inside, you don't need `$` on variable names: `$(( COUNT*2 ))` works. Bash has **no floating point** — `$(( 3/2 ))` is `1`; reach for `awk`/`bc` for decimals.
- **Command substitution** `$( ... )`: run a command and *substitute its stdout* as a value. `CTX="$(kubectl config current-context)"` captures the current context into a variable. This is different from `if kubectl ...` (which branches on the exit code); `$(...)` captures the **text**. (The old backtick form `` `...` `` does the same but doesn't nest cleanly — always prefer `$(...)`.)

**`readonly`** freezes a variable: `readonly NAMESPACE="prod"` makes any later `NAMESPACE=...` an error. Use it for constants you never want a later line (or a sourced file) to clobber.

**Arrays** hold multiple values:
```
INDEXED ARRAY                        ASSOCIATIVE ARRAY (bash 4+)
  NAMESPACES=(prod stage dev)          declare -A IMAGE       # MUST declare -A first
  ${NAMESPACES[0]}   → prod            IMAGE[web]=nginx:1.27
  ${NAMESPACES[@]}   → all elements    IMAGE[api]=api:2.3
  ${#NAMESPACES[@]}  → 3 (count)       ${IMAGE[web]}     → nginx:1.27
  NAMESPACES+=(qa)   → append          ${!IMAGE[@]}      → keys: web api
                                       ${IMAGE[@]}       → values
```
`"${NAMESPACES[@]}"` (quoted, with `@`) expands to each element as a *separate* word — the correct way to loop. `"${NAMESPACES[*]}"` joins them into one string. **Associative arrays require `declare -A` first** — without it, `IMAGE[web]=...` is interpreted as an arithmetic-index assignment and silently misbehaves.

## (D) `set -euo pipefail` — rewiring the shell's dangerous defaults

Here's the crux of your `deploy.sh` bug. **By default, bash barrels past failures.** A command fails, `$?` becomes non-zero, and bash... runs the next line anyway. That default made sense for an interactive shell (you don't want your terminal to close because `ls` failed) and is a *disaster* for a script that must not proceed on a broken step. Four settings fix it:

```
THE FOUR GUARDS — put them at the top, right after the shebang

  set -e            errexit:  if ANY command exits non-zero, STOP the
                    script immediately (don't run the next line).
                    → your deploy stops the instant `set image` fails.

  set -u            nounset:  referencing an UNSET variable is an error,
                    not an empty string.
                    → typo `$NAMESPCE` aborts instead of silently
                      expanding to "" and `kubectl -n ""` hitting default.

  set -o pipefail   a pipeline's exit code is the FIRST non-zero in it,
                    not just the last command's.
                    → `kubectl get pods | grep Running` : without this,
                      exit code is grep's. With it, if kubectl itself
                      failed, the pipeline fails.

  set -euo pipefail   all three at once (o pipefail written long-form).

  IFS=$'\n\t'       (optional, "unofficial strict mode") shrink the word-
                    splitting characters to newline+tab, so spaces in
                    values don't split unexpectedly.
```

Crucial nuances you must know, or `set -e` will bite *you*:
- `set -e` does **not** trigger when a command is the condition of `if`, `while`, `&&`, or `||`. That's by design: `if kubectl get ns prod; then` is *supposed* to tolerate the failure. So `if ! command; then` is safe under `set -e`.
- A function's failure propagates, but a command whose non-zero result you *want* to handle should be written `cmd || true` or captured: `out=$(cmd) || rc=$?`.
- Under `set -u`, reference optional vars defensively: `"${REPLICAS:-3}"` — the `:-` default means an unset `REPLICAS` doesn't abort.

## (E) Functions, `local` scope, and traps

A **function** is a named block of commands: `deploy() { ...; }`. Inside, the arguments become positional params **`$1`, `$2`, ... `$@`** (all args), `$#` (arg count) — *shadowing* the script's own `$1`/`$@` for the duration of the call. A function "returns" via `return N` (an exit code 0–255) or by *printing* to stdout (captured with `$(...)`). Its exit code becomes `$?`.

**`local`** is the one word that keeps functions from corrupting each other. By default every variable in bash is **global** — a variable you set inside a function leaks out and can clobber a caller's variable of the same name. `local name="$1"` scopes `name` to that function call only. In any function longer than two lines, **declare your working variables `local`** or you *will* eventually overwrite an outer loop's counter and spend an hour debugging it.

**stderr and `error()`.** A process has two output streams: **stdout (fd 1)** for results, **stderr (fd 2)** for diagnostics. Error messages belong on stderr so they don't pollute data that something downstream is capturing with `$(...)`. The idiom `echo "message" >&2` redirects to fd 2. A canonical helper:
```
error() { echo "ERROR: $*" >&2; exit 1; }   # complain on stderr, then die
log()   { echo "[$(date '+%H:%M:%S')] $*"; } # timestamped info on stdout
```

**`trap`** — the cleanup guarantee. `trap 'HANDLER' SIGNAL...` registers code to run when the shell receives a signal or hits a pseudo-signal. The magic one for scripts is **`EXIT`**: the handler runs **no matter how the script ends** — normal completion, `set -e` abort, `error() → exit 1`, or Ctrl-C. This is how you guarantee a temp file gets deleted or a `kubectl port-forward` gets killed even when the script dies mid-flight.

```
THE TRAP SAFETY NET

  trap cleanup EXIT          # register once, near the top
  trap 'error "interrupted"' INT TERM

  cleanup() {
    rc=$?                    # capture the exit code that triggered us
    rm -f "$TMPFILE"        # always runs...
    kill "$PF_PID" 2>/dev/null || true   # ...even on crash or Ctrl-C
    return $rc
  }

  script body: mktemp → work → maybe die anywhere
                                 └──────────▶ EXIT fires ──▶ cleanup runs
```

Now assemble it. A production deploy script is *exactly* these five machines wired together:

```
        ┌──────────────────── deploy.sh ───────────────────────┐
  #!/bin/bash               (A) kernel picks bash as interpreter
  set -euo pipefail         (D) stop on any failure / unset var
  readonly APP="checkout"   (C) constants, frozen
  readonly NS="${1:?need namespace}"

  error(){ echo "ERROR: $*" >&2; exit 1; }   (E) stderr + die
  log(){   echo "[$(date '+%T')] $*"; }
  trap 'log "exit code $?"' EXIT             (E) cleanup net

  check_prerequisites(){                      (E) function + local
     local ctx; ctx="$(kubectl config current-context)"  (C) capture
     kubectl cluster-info >/dev/null 2>&1 || error "no cluster"  (B) exit code guard
     log "context=$ctx"
  }
  update_image(){ kubectl -n "$NS" set image deploy/$APP $APP="$1"; }
  wait_for_rollout(){ kubectl -n "$NS" rollout status deploy/$APP --timeout=120s; }
          └──────── every step's exit code (B) decides if we continue (D) ───────┘
        └──────────────────────────────────────────────────────┘
```

> **✅ Check yourself before Rung 4:** Without looking — your `deploy.sh` ran `kubectl set image ...` which failed, yet the script printed "Deploy succeeded" and exited 0. Name the *two* machinery facts (one from B, one from D) that together explain the bug, and the one line that would have prevented it.

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary word to what it actually is*

| Term | What it actually is | Which machinery it touches |
|---|---|---|
| **Shebang** `#!/bin/bash` | First-line marker the *kernel* reads to pick the interpreter | (A) exec-time interpreter selection |
| **Exit code / status** | 8-bit number (0–255) a process returns; 0 = success | (B) the atom everything branches on |
| **`$?`** | Special var holding the *last* command's exit code | (B) exit-code substrate |
| **`set -e` (errexit)** | Abort script on any non-zero exit (outside if/while/&&/\|\|) | (D) failure control |
| **`set -u` (nounset)** | Referencing an unset variable is a fatal error | (D) catches typos |
| **`set -o pipefail`** | A pipeline fails if *any* stage fails, not just the last | (D) failure control |
| **Parameter expansion** | `${VAR}`, `${#VAR}`, `${VAR^^}`, `${VAR:-def}` — shaping a value | (C) value production |
| **`${VAR:-default}`** | Use `$VAR`, else a fallback if unset/empty | (C) defaults, works with `set -u` |
| **`readonly`** | Freeze a variable so later assignments error | (C) constants |
| **Command substitution `$(...)`** | Run a command, substitute its *stdout* as a value | (C) capture text |
| **Arithmetic `$(( ))`** | Integer math; `$` optional on names inside | (C) numeric values |
| **Indexed array** `(a b c)` | Ordered list, `${arr[@]}`, `${#arr[@]}` | (C) multi-value storage |
| **Associative array** `declare -A` | Key→value map; needs `declare -A` first | (C) keyed storage |
| **Positional params** `$1 $2 $@ $#` | Arguments to the script *or* the current function | (E) input to script/function |
| **`local`** | Scopes a variable to the current function call | (E) function isolation |
| **`return N`** | A function's exit code (0–255) | (B)+(E) function verdict |
| **stderr / fd 2 / `>&2`** | The diagnostics stream, separate from stdout (fd 1) | (E) `error()` output routing |
| **`trap 'cmd' EXIT`** | Run `cmd` whenever the shell exits, however it exits | (E) cleanup guarantee |
| **`[[ ... ]]`** | Bash's test *command*; exits 0 if condition true | (B) it's a command with an exit code |
| **`[` / `test`** | POSIX test command (also a real binary `/usr/bin/[`) | (B) exit-code test |

### Terms that are "the same kind of thing wearing different names"

- **Exit code = exit status = return status = `$?` (after the fact) = a function's `return` value.** One concept: the 0–255 verdict. `$?` is just where the last one is parked.
- **`[[ ... ]]` = `[ ... ]` = `test ...` = *any command in an `if`*.** They are all just *commands that produce an exit code*. `if grep -q ...` and `if [[ -f file ]]` work by the identical mechanism. `[[ ]]` is the bash-only, safer version (no word-splitting/globbing surprises, supports `==`, `&&`, `=~` regex).
- **Parameter expansion, command substitution, and arithmetic expansion** are all "**expansions**" — the shell replacing `${...}` / `$(...)` / `$(( ... ))` with a computed value *before* the command runs. Same expansion phase you learned in the shell/environment ladder.
- **`set -e` / `set -o errexit`, `set -u` / `set -o nounset`** — the short letter flag and the long `-o name` are the *same switch*. `set -euo pipefail` is just three of them compressed.
- **Positional params in a script vs in a function** — `$1`/`$@` mean "the script's args" at top level and "the function's args" inside a function. Same names, scoped to the current call frame.

> **✅ Check yourself before Rung 5:** Someone says "`[[ ]]` is special bash syntax for conditions." Correct them using the word "exit code": what is `[[ "$phase" == "Running" ]]` *really*, and why can you therefore drop it into an `if` the same way you'd drop `kubectl get pod`?

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; one traced run sears the model in. Let's trace running a real deploy script that updates an image and waits for the rollout — and watch what happens when the rollout **fails**, because that's the case your bug was hiding.

The script (`deploy.sh`), invoked as `./deploy.sh prod nginx:1.27-broken`:

```bash
#!/bin/bash
set -euo pipefail
readonly APP="checkout"
readonly NS="${1:?namespace required}"
readonly IMAGE="${2:?image required}"

error() { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "[$(date '+%T')] $*"; }
trap 'log "script exiting with code $?"' EXIT

update_image()    { kubectl -n "$NS" set image "deploy/$APP" "$APP=$IMAGE"; }
wait_for_rollout(){ kubectl -n "$NS" rollout status "deploy/$APP" --timeout=60s; }

log "deploying $IMAGE to $NS"
update_image
wait_for_rollout
log "deploy succeeded"
```

**Step 1 — exec & shebang.** You run `./deploy.sh prod nginx:1.27-broken`. The kernel reads `#!`, rewrites the exec to `/bin/bash ./deploy.sh prod nginx:1.27-broken`. Bash starts, with `$1=prod`, `$2=nginx:1.27-broken`.

**Step 2 — `set -euo pipefail`.** Bash flips three switches on itself: errexit, nounset, pipefail. From now on, any non-zero exit (outside a condition) aborts, and any unset-var reference aborts.

**Step 3 — `readonly` + `${1:?...}`.** `NS="${1:?namespace required}"` expands: `$1` is `prod`, so `NS=prod` and it's frozen. `IMAGE=nginx:1.27-broken`, frozen. Had you forgotten an argument, `${1:?namespace required}` would print `deploy.sh: line 4: 1: namespace required` to **stderr** and exit non-zero *right here* — a guard, courtesy of the `:?` expansion.

**Step 4 — function definitions + `trap`.** `error`, `log`, `update_image`, `wait_for_rollout` are *defined*, not run. `trap 'log "..."' EXIT` registers the EXIT handler in bash's trap table. Nothing has executed yet except registration.

**Step 5 — `log "deploying ..."`.** Bash calls the `log` function. Inside, `$*` is the function's args (the message); `$(date '+%T')` is a **command substitution** — bash forks `date`, captures its stdout (`14:22:07`), substitutes it. `echo` writes to **stdout**. `$?` = 0.

**Step 6 — `update_image`.** Bash runs `kubectl -n prod set image deploy/checkout checkout=nginx:1.27-broken`. Suppose this *succeeds* (the API accepts the new image spec) — exit 0. errexit is satisfied, bash continues. Note: kubectl accepting the spec does *not* mean the pods are healthy — it just recorded the desired state in etcd.

**Step 7 — `wait_for_rollout`.** Bash runs `kubectl -n prod rollout status deploy/checkout --timeout=60s`. The new pods pull `nginx:1.27-broken`, which crash-loops. After 60s, `kubectl rollout status` gives up and **exits non-zero** (code 1), printing `error: deployment "checkout" exceeded its progress deadline` to **stderr**.

**Step 8 — errexit fires.** `$?` is now 1. This command is *not* inside an `if`/`while`/`&&`/`||`, so `set -e` triggers. Bash **aborts the script immediately** — it never reaches `log "deploy succeeded"`. *This is the exact line your old, `set -e`-less script wrongly ran.*

**Step 9 — EXIT trap runs.** Because bash is exiting, the `EXIT` trap fires. The handler `log "script exiting with code $?"` runs — `$?` is still 1 — printing `[14:23:07] script exiting with code 1`. Then bash exits the whole script with code **1**.

**Step 10 — the caller sees the truth.** Whatever ran `./deploy.sh` (your CI job, or you) reads exit code `1`. CI marks the stage **failed**. The deploy is correctly reported as broken — *not* silently "succeeded."

```
VISUAL OF THE TRACE  (./deploy.sh prod nginx:1.27-broken)

  kernel: #! → /bin/bash ./deploy.sh prod nginx:1.27-broken
     │
     ▼
  ┌──────────────── bash (running the script) ─────────────────┐
  │ set -euo pipefail        (errexit armed)                   │
  │ NS=prod  IMAGE=…broken   (readonly, frozen)                │
  │ define error/log/... ; trap … EXIT   (registered)          │
  │ log "deploying…"                     → stdout, $?=0        │
  │ update_image  → kubectl set image    → $?=0 (spec stored)  │
  │ wait_for_rollout → kubectl rollout status --timeout=60s    │
  │        pods crash-loop … 60s … kubectl EXITS 1  ──────┐    │
  │                                                        ▼    │
  │  set -e sees $?=1, NOT in a condition  → ABORT script       │
  │        (log "deploy succeeded"  is NEVER reached)  ✗        │
  │                            │                                │
  │              EXIT trap ────┘  runs: "exiting with code 1"   │
  └────────────────────────────┬───────────────────────────────┘
                               ▼  exit 1
                    CI reads $?=1  →  stage FAILED (correct!)
```

Notice: **the whole difference between "silently succeeded" and "correctly failed" is Steps 2 and 8** — `set -e` reading the exit code from Step 7 and refusing to march on. And **the EXIT trap in Step 9 ran even though the script died abnormally** — that's the cleanup guarantee. The entire trace is Rung 2's sentence in motion: run in order, produce exit codes, control what happens on non-zero.

> **✅ Check yourself before Rung 6:** At which single step would removing `set -e` change the outcome, and what would the script have printed and exited with instead? Then: why did the EXIT trap still fire in Step 9 even though `wait_for_rollout` failed?

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines it*

You understand shell scripting best by seeing what it *isn't* — and when to walk away from it.

### Contrast A: bash script vs the interactive shell

They run the *same* language, but the defaults and intent differ, and that difference is the whole safety story:

| Aspect | Interactive shell | Bash script |
|---|---|---|
| On a failed command | keeps going (you decide next) | should **stop** — add `set -e` |
| Unset variable | expands to empty (convenient) | dangerous — add `set -u` |
| History / completion / prompt | on | off (not needed) |
| Reads config | `~/.bashrc` (interactive) | none by default (`$BASH_ENV` if set) |
| Human in the loop | yes | no — the file decides |
| Right tool for | exploration, one-offs | repeatable, unattended automation |

The punchline: an interactive shell's *forgiving* defaults are a *liability* in a script. `set -euo pipefail` exists to convert the forgiving shell into a strict program runner.

### Contrast B: bash vs a real programming language (Python/Go)

| Task | Bash | Python / Go |
|---|---|---|
| Glue 5 CLI tools together | ✅ native, terse | ⚠️ subprocess boilerplate |
| Loop over `kubectl get` output | ✅ trivial | ✅ but heavier |
| Integer math | ✅ `$(( ))` | ✅ |
| Floating-point / decimals | ❌ none (need `awk`/`bc`) | ✅ |
| Real data structures (nested) | ❌ flat arrays only | ✅ |
| Error handling | ⚠️ `set -e`/`trap` duct tape | ✅ exceptions / typed errors |
| Testing / unit tests | ⚠️ awkward (bats) | ✅ mature |
| Parsing JSON | ⚠️ shell out to `jq` | ✅ native |
| ~500+ lines of logic | ❌ becomes unmaintainable | ✅ |

**What bash can do that they can't (cheaply):** be the *native language of the command line* — piping, redirection, and calling `kubectl`/`grep`/`awk` are first-class and one line each. For "run these tools in this order with these decisions," nothing beats it for speed.

**What they can do that bash can't:** hold real data structures, do float math, handle errors with structure, and stay maintainable past a few hundred lines.

### When would I NOT reach for a bash script?

- **Complex logic or data** (nested JSON transforms, non-trivial math): use Python/Go, or at least `jq`.
- **It must run under `/bin/sh` (dash/busybox in slim containers):** arrays, `[[ ]]`, `${VAR^^}`, `local` (partially) are bashisms that break. Either force `#!/bin/bash` *and* ensure bash is installed, or write POSIX `sh`.
- **Untrusted input:** shell + string interpolation + `eval` = injection. Never build a command string from user input.
- **When Kubernetes has a native primitive:** a `while` loop polling for a pod is often better expressed as `kubectl wait --for=condition=Ready`, or as a Job's `restartPolicy`, or a readiness probe — let the platform do the waiting.

**One-sentence "why this over that":**
> Use a bash script to *orchestrate command-line tools in sequence with simple branching* (deploys, health checks, node bootstrap); drop to a real language the moment you need real data structures, float math, or maintainable logic past a few hundred lines.

> **✅ Check yourself before Rung 7:** Your teammate wrote a 400-line bash script that parses JSON with `grep`/`cut`, does percentage math, and has three levels of nested state. Give them the *two* specific reasons (from the tables) this should be Python — and the *one* thing bash was still right for at the start.

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**Here the commands finally arrive — as hypotheses you commit to first.** For each: read the prediction, cover the outcome, decide if you agree, *then* run it. All commands are correct on Ubuntu 22.04 / bash 5.x. Where dash/`sh` differs, it's noted. A running cluster (kind/minikube/real) is assumed for the Kubernetes cases; where you lack one, the logic still teaches.

---

## Prediction 1 — Exit codes and `$?` drive everything (the normal case)

> **My prediction:** "`true` exits 0 and `false` exits 1, and `$?` will show exactly those. An `if` will branch on the *exit code*, not any text — so `if false; then ... else ...` takes the `else` branch. `[[ ... ]]` is itself just a command with an exit code, so `[[ 5 -gt 3 ]]; echo $?` prints 0 — *because* every command hands the shell a 0–255 verdict and control flow reads that number."

```bash
true;  echo "$?"          # 0
false; echo "$?"          # 1

if false; then echo yes; else echo no; fi     # no   (branched on exit code 1)

[[ 5 -gt 3 ]]; echo "$?"  # 0   ← [[ ]] is a command; true → exit 0
[[ 5 -gt 9 ]]; echo "$?"  # 1

# Prove `if` and `[[ ]]` are the SAME mechanism as any command:
if grep -q root /etc/passwd; then echo "found"; fi   # found (grep exit 0)
```

**Verify:** `$?` is `0` after `true`, `1` after `false`. The `if false` block prints `no`. `[[ 5 -gt 3 ]]; echo $?` prints `0`. If you expected `[[ ]]` to *print* something, that's the correction: `[[ ]]` produces no output — only an exit code. That single fact is why it slots into `if` identically to `grep -q`.

---

## Prediction 2 — Parameter expansion, arrays, and arithmetic shape values (normal/feature case)

> **My prediction:** "`${#APP}` gives the string length, `${APP^^}` uppercases it, `${APP:0:5}` is a substring, and `${REPLICAS:-3}` yields `3` when `REPLICAS` is unset. An indexed array iterates with `${arr[@]}` and counts with `${#arr[@]}`; `$(( COUNT*2 ))` doubles a number — *because* these are all in-shell expansions computed before any command runs, with no external tool needed."

```bash
APP="checkout"
echo "${#APP}"            # 8       (length)
echo "${APP^^}"          # CHECKOUT (uppercase all)
echo "${APP:0:5}"        # check   (offset 0, length 5)

unset REPLICAS
echo "${REPLICAS:-3}"    # 3       (default: REPLICAS is unset)
REPLICAS=5
echo "${REPLICAS:-3}"    # 5       (value present → default ignored)

NAMESPACES=(prod stage dev)
echo "${#NAMESPACES[@]}" # 3       (element count)
for NS in "${NAMESPACES[@]}"; do echo "ns=$NS"; done   # ns=prod / ns=stage / ns=dev

COUNT=4
echo "$(( COUNT*2 ))"    # 8       (integer arithmetic, no $ needed inside)
echo "$(( 3/2 ))"        # 1       (bash truncates — NO floats!)
```

**Verify:** `${#APP}` is `8`, `${APP^^}` is `CHECKOUT`, the default flips from `3` to `5` when `REPLICAS` is set. The loop prints three namespaces. `$(( 3/2 ))` is `1`, not `1.5` — proving bash integer math. If `${APP^^}` errored with `bad substitution`, you're running this under `dash`/`sh`, not bash — that's the correction: `^^` is a bashism, so the shebang and interpreter matter.

---

## Prediction 3 — `set -euo pipefail` turns silent failure into a hard stop (the edge/failure case)

> **My prediction:** "A script *without* `set -e` will keep running after a failed command and can exit `0` despite the failure; the *same* script *with* `set -euo pipefail` will abort at the failing line and exit non-zero. And `set -u` will abort on a typo'd unset variable instead of expanding it to empty — *because* errexit and nounset make bash react to the exit-code substrate instead of ignoring it."

```bash
# --- WITHOUT the guards: silent march-past ---
cat > /tmp/loose.sh <<'EOF'
#!/bin/bash
false                    # a failing step (stands in for a failed kubectl)
echo "reached the end"   # runs anyway!
EOF
bash /tmp/loose.sh; echo "exit=$?"
# reached the end
# exit=0        ← LIED: a step failed but script "succeeded"

# --- WITH the guards: hard stop ---
cat > /tmp/strict.sh <<'EOF'
#!/bin/bash
set -euo pipefail
false                    # fails → errexit aborts HERE
echo "reached the end"   # never runs
EOF
bash /tmp/strict.sh; echo "exit=$?"
# exit=1        ← correct: aborted at the failure

# --- set -u catches a typo'd variable ---
cat > /tmp/nounset.sh <<'EOF'
#!/bin/bash
set -euo pipefail
NAMESPACE="prod"
kubectl_ns="$NAMESPCE"   # TYPO: NAMESPCE is unset
echo "using ns=$kubectl_ns"
EOF
bash /tmp/nounset.sh; echo "exit=$?"
# /tmp/nounset.sh: line 4: NAMESPCE: unbound variable
# exit=1        ← caught the typo instead of using ""
```

**Verify:** The loose script prints `reached the end` and `exit=0` — the exact shape of your original bug. The strict script prints `exit=1` and never reaches the end. The nounset script aborts on `unbound variable`. If the strict script *still* reached the end, check the shebang ran under bash and `set -e` is actually the first executed line — a `set -e` placed after the failing command can't retroactively stop it. This is the single most important habit in the file: **the guards go right after the shebang.**

---

## Prediction 4 — Functions, `local` scope, return codes, and `error()` on stderr (mechanism case)

> **My prediction:** "A function without `local` will clobber a same-named variable in its caller (bash defaults to global scope); adding `local` isolates it. A function's `return N` becomes `$?`. And `error()` writing with `>&2` sends its message to stderr, so it survives even when stdout is captured by `$(...)` — *because* stdout (fd 1) and stderr (fd 2) are separate streams, and `local` scopes a name to the call frame."

```bash
# --- local vs global clobber ---
name="OUTER"
without_local() { name="clobbered"; }
with_local()    { local name="safe"; }
without_local; echo "$name"    # clobbered   ← global leak!
name="OUTER"; with_local; echo "$name"   # OUTER   ← local kept it safe

# --- return code becomes $? ---
is_even() { (( $1 % 2 == 0 )) && return 0 || return 1; }
is_even 4; echo "$?"           # 0  (even → success)
is_even 5; echo "$?"           # 1  (odd  → failure)
if is_even 10; then echo "10 is even"; fi   # 10 is even

# --- stderr routing: error() survives stdout capture ---
error() { echo "ERROR: $*" >&2; return 1; }
log()   { echo "[$(date '+%T')] $*"; }

captured="$(log "hello")"      # stdout captured into the variable
echo "captured=[$captured]"    # captured=[[14:22:07] hello]

# Now capture a function that errors — the error still reaches your terminal:
out="$(error "disk full" 2>/tmp/err.txt)" || true
echo "stdout out=[$out]"       # stdout out=[]      ← error() wrote NOTHING to stdout
cat /tmp/err.txt               # ERROR: disk full   ← it went to stderr (fd 2)
```

**Verify:** `without_local` leaves `name=clobbered`; `with_local` leaves it `OUTER`. `is_even 4` gives `$?`=0. The captured `log` output lands *in the variable*, but `error()`'s message does **not** — it appears via stderr (in `/tmp/err.txt`). If your `error()` message ended up inside `$out`, you forgot the `>&2` — that's the lesson: diagnostics on stderr keep your captured data clean.

---

## Prediction 5 — A wait-for-rollout loop with `while` and `kubectl wait` (the Kubernetes case)

> **My prediction:** "A `while ! kubectl get ... ; do sleep; done` loop will keep retrying until the guard command *succeeds* (exit 0), then fall through. Scraping a field with `$(kubectl get -o jsonpath=...)` into a variable lets me compare it with `[[ ]]`. `kubectl wait --for=condition=Ready` blocks until ready or times out non-zero — *because* the loop and the `if` both branch on kubectl's exit code, and jsonpath capture uses command substitution for the text." 

```bash
# Guard the whole thing first — refuse to run against a dead/unreachable cluster:
kubectl cluster-info >/dev/null 2>&1 || { echo "no cluster reachable" >&2; exit 1; }

CTX="$(kubectl config current-context)"   # capture context text
echo "operating on context: $CTX"

# Spin up something to watch:
kubectl create deployment web --image=nginx --replicas=2

# --- C-style for as a bounded retry (never loop forever) ---
NS="default"
for (( attempt=1; attempt<=30; attempt++ )); do
  # Scrape the ready replica count into a variable via jsonpath:
  READY="$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}')"
  READY="${READY:-0}"                     # default 0 when field is absent/empty
  DESIRED="$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}')"
  echo "[attempt $attempt] ready=$READY desired=$DESIRED"
  if [[ "$READY" == "$DESIRED" ]]; then
    echo "rollout complete"; break
  fi
  sleep 2
done

# --- while-until pattern (retry until a command SUCCEEDS) ---
while ! kubectl -n "$NS" rollout status deploy/web --timeout=5s >/dev/null 2>&1; do
  echo "still rolling out..."; sleep 2
done
echo "rollout status reports success"

# --- let the platform do the waiting (cleaner than a hand-rolled loop) ---
kubectl -n "$NS" wait --for=condition=Available deploy/web --timeout=60s
echo "kubectl wait exit code: $?"          # 0 if Available within 60s, else 1

kubectl delete deployment web              # cleanup
```

**Verify:** `cluster-info` guard passes (or the script exits before doing damage). The `for` loop prints climbing attempts and stops when `ready == desired`; the `${READY:-0}` default prevents a `set -u`/comparison blowup while the field is still absent early in the rollout. `kubectl wait` exits `0`. If the `for` loop runs all 30 attempts without completing, `readyReplicas` never matched `spec.replicas` — inspect `kubectl describe deploy web` (bad image, no resources) — teaching you that the *loop* was fine; the *cluster* couldn't satisfy it, exactly the distinction between script logic and platform reality.

---

## Prediction 6 — `case`, `trap` cleanup, and a full guarded deploy (integration/edge case)

> **My prediction:** "A `case "$1" in` will dispatch to the matching branch (with `*)` as the catch-all). A `trap cleanup EXIT` will run `cleanup` no matter how the script ends — normal, `error()` exit, or Ctrl-C — so a temp file and a background port-forward are always released — *because* the EXIT pseudo-signal fires on every exit path, and `case` branches on a pattern match."

```bash
cat > /tmp/deploy.sh <<'EOF'
#!/bin/bash
set -euo pipefail
readonly APP="checkout"

error() { echo "ERROR: $*" >&2; exit 1; }
log()   { echo "[$(date '+%T')] $*"; }

TMPDIR_MADE="$(mktemp -d)"          # temp workspace
cleanup() {
  local rc=$?                        # capture the triggering exit code
  log "cleanup: removing $TMPDIR_MADE (exit was $rc)"
  rm -rf "$TMPDIR_MADE"
}
trap cleanup EXIT                     # ALWAYS runs on any exit path

check_prerequisites() {
  command -v kubectl >/dev/null || error "kubectl not found in PATH"
  log "prerequisites ok; workspace=$TMPDIR_MADE"
}

# Subcommand dispatch:
case "${1:-help}" in
  deploy)  check_prerequisites; log "would deploy $APP"; echo done >"$TMPDIR_MADE/marker" ;;
  status)  check_prerequisites; log "would show status of $APP" ;;
  fail)    check_prerequisites; error "simulated failure mid-run" ;;   # triggers trap!
  help|*)  echo "usage: $0 {deploy|status|fail}" >&2; exit 2 ;;
esac

log "reached normal end"
EOF
chmod +x /tmp/deploy.sh

/tmp/deploy.sh deploy;  echo "rc=$?"   # runs deploy, cleanup fires, rc=0
echo "---"
/tmp/deploy.sh fail;    echo "rc=$?"   # error() → exit 1, but cleanup STILL fires, rc=1
echo "---"
/tmp/deploy.sh bogus;   echo "rc=$?"   # case *) → usage on stderr, rc=2
```

**Verify:** For `deploy`, you see `would deploy`, then the cleanup line, `rc=0`. For `fail`, you see `ERROR: simulated failure` on stderr **and** the `cleanup: removing ...` line **and** `rc=1` — proving the trap fired even though the script died via `error()`. For `bogus`, the `*)` catch-all prints usage and `rc=2`. Check `ls /tmp/tmp.*` afterward: no leftover temp dirs — the trap cleaned every path. If a temp dir survived, the `trap ... EXIT` wasn't registered before the exit — the lesson being that a trap only protects exits that happen *after* it's set.

---

## The prediction habit, generalized

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. exit codes drive `if`/`[[ ]]` |  |  |  |
| 2. expansion/arrays/arithmetic |  |  |  |
| 3. `set -euo pipefail` stops the march |  |  |  |
| 4. `local`, return codes, stderr |  |  |  |
| 5. wait loop + jsonpath + `kubectl wait` |  |  |  |
| 6. `case` + `trap` cleanup |  |  |  |

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> A bash script is a saved sequence of commands run in order by a shell, where every command emits a 0–255 exit code, and all of scripting is producing values (variables, expansions, arrays, arithmetic, command substitution), branching and looping on those exit codes (`if`/`case`/`for`/`while`, `[[ ]]`), and controlling failure (`set -euo pipefail`, `local`, `error()>&2`, `trap … EXIT`).

**Explain it to a beginner in 3 sentences:**
> 1. A script is just the commands you'd type saved in a file that starts with `#!/bin/bash` so the kernel knows to run it with bash, and it runs top to bottom without you in the loop.
> 2. Every command reports success or failure as an exit code (0 means OK), and things like `if`, `while`, and `[[ … ]]` are really just checking that number — which is why `set -euo pipefail` is essential: it tells bash to *stop* the moment a command fails instead of blindly continuing.
> 3. You store values in variables (with tricks like `${VAR:-default}` for fallbacks and arrays for lists), wrap repeated logic in functions with `local` variables, send errors to stderr with `>&2`, and use `trap … EXIT` to guarantee cleanup runs no matter how the script ends.

**Map of sub-capability → the one core idea** (*all one pattern: run in order → produce/shape values → branch on exit codes → control failure*):

```
Every feature = one part of the core sentence:

#!/bin/bash                    → "run in order" (kernel picks the interpreter)
$? and exit codes              → "branch on exit codes" (the atom)
NAME="x", readonly             → "produce values" (store + freeze)
${#APP} ${APP^^} ${VAR:-def}   → "shape values" (parameter expansion)
arrays / declare -A            → "produce values" (lists & maps)
$(( COUNT*2 ))                 → "shape values" (arithmetic)
$(kubectl config …)            → "produce values" (capture command stdout)
if/[[ ]] / case / for / while  → "branch on exit codes" (control flow)
functions, $1/$@, return       → "run in order" (factored, with a verdict)
local                          → scope isolation for functions
error(){ …>&2; exit 1; }       → "control failure" (diagnose on stderr, die)
set -euo pipefail              → "control failure" (stop the march-past)
trap … EXIT                    → "control failure" (guaranteed cleanup)
```

Thirteen rows, one idea: *run commands in order, shape values, branch on exit codes, and refuse to march past failure.*

**Which rung will I most likely need to revisit hands-on?**

- **Rung 3D + Prediction 3 (`set -euo pipefail`).** This is where your production bug lived. Stating "`set -e` stops on failure" is easy; internalizing that it does *not* fire inside `if`/`&&`, and that it must be the first executed line, takes a rep. Run Prediction 3 and watch `exit=0` become `exit=1` with your own eyes.
- **Rung 3E + Prediction 6 (`trap … EXIT` and `local`).** The "cleanup ran even on crash" and "my function clobbered the caller's variable" surprises are muscle-memory failures until you see them once. Rehearse before you refactor a real deploy script.

If either felt shaky on the check-yourself questions, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [The shell & environment](02-shell-and-environment.md) — the `fork`/`execve`, expansion phases, and env inheritance that every script line rides on.
- [Processes & job control](07-processes-job-control.md) — exit codes, signals (`SIGTERM`=143, `SIGKILL`=137), and the `wait()` that fills `$?`; the substrate under `trap`.
- [Text processing](09-text-processing.md) — `grep`/`awk`/`sed`/`jq` and jsonpath, the tools your `$(...)` command substitutions capture from.
- [I/O redirection & pipes](10-io-redirection-pipes.md) — stdout vs stderr (fd 1 vs 2), `>&2`, heredocs (`<<'EOF'`), and `pipefail`'s pipeline mechanics.
- [Scheduled tasks](25-scheduled-tasks.md) — where these scripts run unattended (cron, systemd timers, CronJobs) and why exit codes and `set -e` matter even more there.
- [The Linux ↔ Kubernetes map](27-linux-kubernetes-map.md) — where scripting sits in node triage, probes, hooks, and bootstrap across the platform.
