# Text Processing — grep, awk, sed & friends, Climbed the Ladder 🪜
### Learning the stream-of-lines toolkit from the ground up — deriving *why `kubectl get pods | grep -v Running` works*, not memorizing flags

> This is Linux text processing rebuilt on the Learning Ladder framework. Instead of leading with `awk '{print $1}'`, we climb from **why these tools exist** → **the one core idea (a stream of lines flowing through filters)** → **the machinery (records, fields, and the pattern→action loop)** → and only at the very top, the commands. Each rung has a "check yourself" question. If you can answer it in your own words, climb on. If not, that rung is your next hands-on session.
>
> **The one rule:** every `grep`/`awk`/`sed`/`sort`/`uniq`/`jq` command lives at the TOP of the ladder (Rung 7). You'll understand *what each one does to a stream of lines* before you run it — and why `kubectl get events | grep -i oomkill` and `sort | uniq -c | sort -rn` are the two moves you'll reach for every single on-call shift.

---

# RUNG 0 — The Setup

**What am I learning?**
The classic Unix text-processing toolkit — the programs that read text a line at a time and transform it: `grep` (find lines), `sed` (edit lines), `awk` (compute over columns), and the small sharp tools `cut`, `sort`, `uniq`, `tr`, `wc` — plus the JSON-aware pair you use on `kubectl -o json`: `jq` and `kubectl -o jsonpath`.

**Why did it land on my desk?**
A very Kubernetes-flavoured on-call shift. An alert fires: "pods restarting in `payments`." You run `kubectl get pods -n payments` and get 60 lines back — you need the ones that *aren't* `Running`. Then `kubectl get events` dumps 400 lines and your lead asks "what's the most common event reason?" Then someone wants the total memory across all pods from `kubectl top pods`, and a teammate pastes a `sed` one-liner to bump an image tag in a manifest and asks you to "just template it." Four asks, one root skill: **you can read `kubectl` output, but you've been eyeballing it instead of *processing* it.** Today you learn the mechanism so 400 lines collapse into the one answer you need.

**What do I already know about it?**
You've typed `| grep something` a hundred times and it "finds the thing." You've seen `awk '{print $1}'` in a blog post and copied it. You know `sort` sorts and `wc -l` counts lines. What you *don't* have is a model that says *why* all these tools chain together with `|`, what a "field" really is, why `uniq -c` gives wrong counts unless you `sort` first, and why `awk` can do arithmetic but `grep` can't. Once you see they're all variations on **"a stream of lines flows in, a filter transforms it, a stream flows out,"** the whole toolkit becomes one idea wearing eight hats.

---

# RUNG 1 — The Pain 🔥
### *Why do these tools exist at all?*

Sit with the problem before touching a single pipe. If you understand the pain, the whole toolkit becomes derivable instead of memorizable.

### The problem that forced them into existence

Unix was built on a radical bet: **almost everything worth knowing about a running system is text, arranged as lines.** Log files, config files, `/etc/passwd`, `/proc/*`, process listings, and — in your world — `kubectl` output are all just streams of newline-separated records. The instant that's true, one question dominates every operational task:

- How do I find the *few lines that matter* in a file of ten thousand?
- How do I pull *one column* out of a table without a spreadsheet?
- How do I *count* how often each distinct thing appears?
- How do I *rewrite* a value across a whole file without opening an editor?

Doing any of that by hand — scrolling, eyeballing, retyping — does not scale past about twenty lines. And the data you care about at 3 AM is never twenty lines.

### What people did *before* — and why it hurt

Before a composable toolkit, each of these tasks meant **writing a whole program.** Want to count error types in a log? Write a C program: open the file, loop lines, `strcmp` each, increment counters, print. Fifty lines of code and a compile step to answer one throwaway question you'll never ask again.

```
THE PRE-TOOLKIT PAIN (one throwaway question = one whole program)

   "How many 5xx errors per URL in this log?"
        │
        ▼
   ┌─────────────────────────────────────────┐
   │  write parse_log.c                       │
   │    open file, malloc buffers,            │
   │    split on spaces, compare strings,     │
   │    build a hash map, sort it, print...   │
   │  compile it. debug the segfault.         │
   │  run it. throw it away.                  │
   └─────────────────────────────────────────┘
        │
        ▼
   Next question ("...but only for /api/*?") → rewrite the program.

   The data is trivial. The ceremony is enormous.
```

The Unix answer, from Ken Thompson and friends, was the opposite bet: build **small single-purpose programs that each do ONE transformation to a stream of text, and let you snap them together with a pipe (`|`).** `grep` finds lines. `cut` takes columns. `sort` orders. `uniq -c` counts adjacent duplicates. None is impressive alone. Chained, they answer that log question in one line with zero compilation — and the *next* question by editing that line, not rewriting a program.

**Who feels this pain most?** The **operator / SRE / platform engineer** — you. Developers work inside one app's code; you work *across* the output of dozens of tools (`kubectl`, `journalctl`, `dmesg`, `ip`, `ss`, `ps`) that all speak lines-of-text. A Kubernetes node is a firehose of textual telemetry, and these tools are the nozzle. Without them you're reduced to scrolling and squinting; with them you turn 400 event lines into "OOMKilled: 37" in one pipe.

### What breaks without it — in your world specifically

- **Triage becomes scrolling.** `kubectl get pods -A` on a busy cluster is hundreds of lines; without `grep -v Running` you're hunting the broken ones by eye.
- **No aggregation.** "Which event reason is spiking?" is unanswerable without `sort | uniq -c | sort -rn`. You'd be tallying with your finger on the screen.
- **No math on output.** `kubectl top` gives you per-pod numbers; summing them to "are we near the node limit?" needs `awk` — nothing else in the pipe can add.
- **No safe bulk edits.** Templating a manifest (swap `staging`→`production`, inject an image tag) by hand across many files invites typos; `sed` does it deterministically.

> **✅ Check yourself before Rung 2:** In one breath — why is "snap together tiny programs with a pipe" a fundamentally more powerful design than "one big program with lots of options," *given that the questions you ask of your logs are unpredictable and mostly one-off*?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything else hangs off*

Here it is. Memorize this exact sentence — the entire toolkit can be *derived* from it:

> **Every one of these tools reads text as a STREAM OF RECORDS (by default, one line = one record, split into FIELDS by whitespace), applies a PATTERN to decide which records to act on, performs an ACTION on the matches, and writes the result to stdout — so you compose complex transforms by piping one tool's output stream into the next's input.**

That's the whole trick. Everything else is detail.

### Why this sentence lets you derive the rest

Watch how much falls out of that one idea:

- *"a stream of records, one line each"* → that's why `wc -l` counts lines, why `sort` reorders lines, why everything is *line-oriented*. The line is the atom.
- *"split into fields"* → that's `awk`'s `$1 $2 ... $NF` and `cut -f`. A record has *internal structure* (columns), and the tools that understand fields (`awk`, `cut`) can pull columns; the ones that don't (`grep`, `sort` by default) treat the whole line as one blob.
- *"apply a PATTERN to decide which records"* → that's `grep`'s regex, `awk`'s `/pattern/ {…}`, `sed`'s `/pattern/d`. Selection comes first.
- *"perform an ACTION on the matches"* → print (`grep`, `awk` default), substitute (`sed s///`), delete (`sed d`), sum (`awk sum+=`). Different tools, same *pattern→action* skeleton.
- *"write to stdout … pipe into the next"* → that's `|`. Because every tool reads stdin and writes stdout, the *output* of one is legal *input* to the next. That single convention is what makes them compose.

Once you see that **`grep`, `sed`, and `awk` are the same machine — read a record, test a pattern, do an action — just with richer actions each step up**, the toolkit stops being eight unrelated commands and becomes one loop you configure eight ways.

```
THE ONE LOOP, three tools climbing the same skeleton:

   for each record (line):
       if PATTERN matches:      ← grep stops here (action = "print the line")
           do ACTION            ← sed adds edit actions (s///, d, p)
                                ← awk adds fields, variables, math, END blocks
```

> **✅ Check yourself before Rung 3:** Cover the sentence and say it from memory. Then derive: why can `awk` sum a column of numbers but `grep` fundamentally cannot? (Hint: which part of the one-sentence model does `grep` simply not implement?)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works under the hood — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Picture a mail-sorting room in a post office. Text pours in as a long paper tape, and a set of specialist clerks each do one simple job to it, passing the result to the next clerk down the belt.
>
> - **(A) The conveyor belt everyone shares.** All the clerks work the same way: the incoming tape is cut into individual **lines** (each line is one "record" — one item on the belt), and, for clerks who care about columns, each line is further cut into **fields** (the words/columns on that line, split wherever there's a gap). Each clerk handles one line at a time: look at it, maybe act, pass it on. You can tell a clerk to cut columns at a different mark (say, at colons instead of spaces) when the paperwork uses a different layout.
> - **(B) The gatekeeper clerk (`grep`).** The simplest clerk holds a description of what to look for and does one thing: if a line matches the description, pass it through untouched; otherwise, bin it. It never edits, never counts columns — it only *selects*. The description is written in a compact pattern shorthand (called a "regular expression" — symbols meaning things like "starts with," "any character," "this OR that"). Little switches flip its behavior: keep only NON-matches, just count matches, ignore capital-vs-small letters, and so on.
> - **(C) The correction clerk (`sed`).** This clerk has a tiny desk that holds exactly one line at a time. For each line: place it on the desk, apply corrections ("replace this word with that word," "throw this line away"), then send the line onward. Fine print worth knowing: by default it fixes only the *first* occurrence per line unless told "fix them all"; you can restrict it to certain lines only ("only lines 5 through 10," "only lines starting with #"); and it can mark up the original document directly — ideally after making a backup copy first.
> - **(D) The accountant clerk (`awk`).** The powerhouse. This clerk automatically splits every line into columns, keeps a running notebook (variables it can do real math in), and follows a rulebook of "if the line looks like this, do that" instructions. It can also do something once before the tape starts and once after it ends — which is how it can *total up a column* and announce the sum at the end. Rule of thumb: the moment your task involves a column or a number, this is your clerk.
> - **(E) The matched pair: the alphabetizer (`sort`) and the stacker (`uniq`).** The stacker collapses duplicate items into "3 x apple" — but it has a one-item memory: it only merges duplicates that arrive *back to back*. So you must send the pile through the alphabetizer first, so identical items become neighbors. That's why they're always used together. (Small helpers nearby: one snips out a single column, one swaps or deletes individual letters, one just counts lines.)
> - **(F) The one thing the mail room can't handle.** Some documents arrive not as flat lines but as nested folders-within-folders (a format called JSON). Line-based clerks shred those. For that you call a specialist (`jq`, or its lightweight cousin "jsonpath") who actually understands the folder structure and can walk straight to the item you need.

*Now the original technical deep-dive — the same ideas, in precise form:*

We open the hood. Five things to understand: **(A) the stream/record/field model that's shared by all of them, (B) grep's mechanism, (C) sed's line-editor mechanism, (D) awk's pattern-action loop, and (E) why `sort`/`uniq` are a matched pair.** This is where the mental model gets built — go slow.

## (A) The shared substrate: records and fields

Every tool here sits on the same conveyor belt. Text arrives on **stdin** as a byte stream. The tool chops it into **records** at a separator (the newline `\n` by default) and, if it understands columns, chops each record into **fields** at a field separator (runs of whitespace by default). It processes one record at a time and emits bytes on **stdout**.

```
THE CONVEYOR BELT (the model ALL of these tools share)

  stdin bytes:  "web-1  Running  0  5d\nweb-2  Pending  3  1h\n..."
        │
        │  split on RECORD separator (RS = '\n')
        ▼
  ┌────────────────────────────────────────────┐
  │ record 1:  "web-1  Running  0  5d"          │
  │ record 2:  "web-2  Pending  3  1h"          │  ← one line = one record
  └────────────────────────────────────────────┘
        │
        │  split each on FIELD separator (FS = whitespace) — only field-aware
        │  tools (awk, cut) do this step
        ▼
  record 2 fields:  $1="web-2"  $2="Pending"  $3="3"  $4="1h"
                     └── NF (number of fields) = 4 ──┘
                     NR (record number so far)  = 2

        │  PATTERN test → ACTION → emit
        ▼
  stdout bytes → (a pipe) → next tool's stdin
```

Two knobs you'll turn constantly live right here:
- **The field separator.** Whitespace is the default, but `/etc/passwd` is colon-delimited, so you tell the tool: `awk -F:` or `cut -d:`. Same conveyor, different chop.
- **The record separator.** Almost always the newline — which is *why* these tools are called "line-oriented" and why `wc -l` (count records) is such a natural primitive.

`awk` even exposes these as variables you already met in the diagram: **`NR`** = record number (how many lines seen so far), **`NF`** = number of fields in the current record, **`$0`** = the whole record, **`$1..$NF`** = the fields. Hold those four and you hold awk's worldview.

## (B) grep — the pure filter

`grep` (from the old `ed` editor command `g/re/p` — "**g**lobally match **re**gular expression, **p**rint") is the simplest realization of the loop: for each line, test a pattern; if it matches, print the *whole line* unchanged. It has no concept of fields and never edits — it only *selects*.

```
grep's loop (selection only, line is atomic):

  for each line:
      if line matches PATTERN:  print line   (unchanged)
      else:                     drop it

  -v  inverts the test  (print NON-matches)   ← "not Running"
  -c  print the COUNT of matches, not the lines
  -i  case-insensitive match                  ← oomkill == OOMKilled
  -o  print only the MATCHED substring, not the whole line  ← extract IPs
  -E  pattern is Extended regex (|, +, (), {} without backslashes)
  -w  match whole WORD only  (so "pod" doesn't match "podium")
  -r  recurse into a directory tree of files
  -n  prefix each hit with its line number
  -l  print only the FILENAMES that contain a match
  -f FILE  read patterns from a file (one per line)
  -A n / -B n / -C n  print n lines After / Before / around (Context) each hit
```

The one subtlety: **the pattern is a regular expression** — a mini-language where `.` = any char, `*` = "zero or more of the previous," `^`/`$` = line start/end, `[abc]` = character class. "Fixed string" search (`grep -F`, or `fgrep`) turns that off when you want a literal `.` or `[`. Basic regex (BRE, the default) needs backslashes for `+`, `?`, `|`, `()`; **extended** regex (`grep -E`) does not — which is why `grep -E "Error|Warning"` needs the `-E` for the `|` alternation to mean "or."

## (C) sed — the stream editor with a one-line buffer

`sed` = **s**tream **ed**itor. It's `grep`'s loop plus *editing actions*. Its mechanism is a tiny virtual machine with a single **pattern space** (a buffer holding the current line). For each line: load it into the pattern space, run your script of commands against it, then (by default) print the pattern space and move on.

```
sed's cycle (per line):

  ┌─────────────────────────────────────────────┐
  │ 1. read next line INTO the pattern space     │
  │ 2. run each command whose ADDRESS matches:   │
  │       s/old/new/     substitute (once/line)  │
  │       s/old/new/g    substitute ALL on line  │
  │       d              delete (clear + skip)   │
  │       p              print now (explicit)    │
  │ 3. auto-print the pattern space  ──┐         │
  │ 4. go to 1                         │         │
  └────────────────────────────────────┼─────────┘
                                        │
   -n  SUPPRESSES step 3's auto-print ──┘
       → now nothing prints unless YOU say 'p'
       → this is why `sed -n '5,10p'` prints ONLY lines 5-10
```

Key mechanical facts most people never internalize:
- **`s/old/new/` replaces the FIRST match on each line; the `/g` flag makes it replace ALL matches on the line.** No `/g` = one per line.
- **An "address" selects WHICH lines a command runs on.** It can be a regex (`/^#/d` = delete lines starting with `#`) or a line-number *range* (`5,10p` = act on lines 5 through 10). Address = sed's version of the PATTERN from the one-sentence model.
- **`-n` flips the default.** Normally sed prints every line (edited or not). `-n` says "print nothing unless I explicitly `p`," which turns sed into a precise extractor.
- **`-i` edits the file IN PLACE** instead of writing to stdout — dangerous, because it overwrites. **`-i.bak` writes a backup first** (`file` → edited, `file.bak` → original). On **GNU sed** (Ubuntu) `-i` takes an optional suffix glued on (`-i.bak`); on **BSD/macOS sed** `-i` *requires* an argument (`-i ''` for no backup) — a real portability trap.
- **`-e` lets you stack multiple scripts** in one invocation: `sed -e 's/a/b/' -e 's/c/d/'`.

## (D) awk — the pattern-action language (the powerhouse)

`awk` (named for its authors **A**ho, **W**einberger, **K**ernighan) is the full realization of the one-sentence model: it splits every line into fields *automatically*, and its program is a list of **`pattern { action }`** rules. For each line, awk tests every rule's pattern; for the ones that match, it runs the action. Omit the pattern and the action runs on *every* line; omit the action and the default is "print the whole line."

```
awk's execution model:

  BEGIN { ... }          ← runs ONCE, before any input (headers, set FS, init sums)
        │
        ▼
  for each input line:
      $0 = whole line;  split into $1..$NF;  NR++ ;  set NF
      test each  pattern { action } :
          NR==1            { ... }   ← pattern is a numeric/boolean test
          /Error/          { ... }   ← pattern is a regex
          $3 > 100         { ... }   ← pattern is a field comparison
          { print $1,$3 }            ← no pattern = every line
        │
        ▼
  END { ... }            ← runs ONCE, after the last line (print totals/reports)
```

What awk adds beyond sed, all flowing from "it understands fields and has variables":
- **Fields**: `$1` is the first column, `$NF` is the *last* column (because `NF` = count of fields), `$0` is the whole line. `awk 'NR>1 {print $1,$3}'` prints columns 1 and 3, skipping the header line (NR>1).
- **`-F` sets the field separator**: `awk -F: '{print $1,$3}' /etc/passwd` splits on colons to print username and UID.
- **Variables and arithmetic**: awk has real numbers and math. `awk '{sum+=$3} END{print sum}'` accumulates column 3 across all lines and prints the total once at the end — the classic "sum a column" that nothing else in the pipe can do.
- **Arrays** (associative / hash maps): `count[$1]++` tallies occurrences keyed by a field — a group-by in one expression.
- **`printf`** for formatted output (columns, decimals): `printf "%-20s %5d\n", $1, $2`.
- **`gsub(/re/, "new")`** does a global substitution *inside* awk (sed's `s///g`, but usable mid-computation).

The mental leap: **sed edits text; awk *computes* over structured records.** The moment your task involves a *column* or a *number* (sum, average, count-by, reformat), you've left grep/sed territory and entered awk's.

## (E) sort + uniq — the aggregation pair (why order matters)

`sort` and `uniq` are the counting duo, and there's a mechanical gotcha baked into *why* they must be used together.

```
uniq's mechanism: it only compares ADJACENT lines.

   input (unsorted):        uniq -c gives (WRONG count):
     apple                    1 apple
     banana                   1 banana
     apple      ──uniq──▶     1 apple     ← two "apple" groups, never merged
     apple                              (the 2nd/3rd apple weren't adjacent
     banana                              to the 1st, so uniq saw them separately)

   FIX — sort first so identical lines become NEIGHBORS:
     sort:  apple apple apple banana banana
     uniq -c:  3 apple
               2 banana          ← now correct
```

**`uniq` collapses only *consecutive* duplicate lines** — it's a streaming dedup with a one-line memory, not a global one. So `uniq -c` (count each group) is *only correct on sorted input*. That's the single most common beginner bug in this whole toolkit, and it's why the canonical aggregation idiom is a sandwich:

```
sort | uniq -c | sort -rn
  │        │         └─ sort by NUMBER (-n), REVERSED (-r) → biggest count on top
  │        └─ collapse identical adjacent lines, prefix each with its count
  └─ bring identical lines together so uniq can see them
```

The other `sort` knobs you'll lean on:
- **`-n`** numeric sort (so `10` sorts after `9`, not before it as text would).
- **`-r`** reverse (descending).
- **`-k N`** sort by the Nth field/column, not the whole line.
- **`-u`** unique — dedup as part of sorting (a global dedup, unlike `uniq`).

And the truly small tools that round out the kit:
- **`cut -d: -f1`** — pull field 1, splitting on `:`. Simpler than awk but *dumber*: `cut` treats **every** delimiter as a boundary (two colons = an empty field), whereas `awk`'s default whitespace-FS collapses runs of spaces. This bites on space-aligned tables — use awk there.
- **`tr`** — **tr**anslate/delete *characters* (not lines): `tr 'a-z' 'A-Z'` upcases; `tr -d ' '` deletes spaces; `tr -s ' '` squeezes repeats. It's the only tool here that operates below the line level, on raw characters.
- **`wc -l`** — count lines (records). Also `wc -w` (words), `wc -c` (bytes).

## (F) The JSON exception: jq and jsonpath

Everything above assumes **lines and columns.** But `kubectl -o json` emits a *nested tree*, not a table — and column tools shatter on it (a value can span lines, contain spaces, be deeply nested). For JSON you need a *structure-aware* tool:

- **`jq`** — a full query language for JSON. `jq '.items[].spec.containers[].image'` walks the tree: for every item, into its pod spec, across each container, emit the `image` field. It understands objects, arrays, and types — `grep`/`awk` never could.
- **`kubectl -o jsonpath`** — a *lighter* built-in path expression, no external tool needed: `kubectl get pod X -o jsonpath='{.status.podIP}'` pulls one value straight out. Great for a single field in a script; `jq` wins when you need filtering, math, or reshaping.

The rule of thumb: **the moment the data is JSON, reach for `jq`/`jsonpath`, not `grep`/`awk`** — parsing structured JSON with line tools is the classic "why is my pipe returning garbage" trap.

> **✅ Check yourself before Rung 4:** Draw the conveyor belt from memory. Then: (1) in `awk`, what are `NR` and `NF`, and what does `$NF` refer to? (2) Why does `sed -n '5,10p'` print only lines 5-10 — what does `-n` change? (3) Why is `uniq -c` wrong without a preceding `sort`?

---

# RUNG 4 — The Vocabulary Map 🏷️
### *Pin every scary term to its role in the machinery from Rung 3*

Now the jargon has somewhere to land. Every term is just a label for a part of the conveyor belt you already hold.

| Scary term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **stream** | A flow of bytes on stdin/stdout, consumed a bit at a time | The conveyor belt itself (Rung 3A) |
| **record** | One unit of processing — by default, one line | What the tools loop over |
| **field** | A column inside a record, split at the field separator | What `awk $1..$NF` / `cut -f` pull out |
| **RS / FS** | Record separator (`\n`) / Field separator (whitespace) | The two "chop" knobs; `-F` / `-d` set FS |
| **pattern** | The test deciding which records get acted on | grep regex, sed address, awk `pattern{}` |
| **action** | What happens to a matching record | print / substitute / delete / sum |
| **regular expression (regex)** | A mini-language for matching text patterns | grep/sed/awk patterns; `.` `*` `^` `$` `[]` |
| **BRE vs ERE** | Basic vs Extended regex (ERE = `|`,`+`,`()` without `\`) | grep default vs `grep -E`; why `Error|Warn` needs `-E` |
| **stdin / stdout** | Standard input / output streams | The pipe's endpoints |
| **pipe (`\|`)** | Connects one tool's stdout to the next's stdin | The composition mechanism |
| **pattern space** | sed's one-line working buffer | Where sed edits happen (Rung 3C) |
| **`s///g`** | sed substitute, `g` = all matches on the line | sed's core edit action |
| **address / range** | Which lines a sed command applies to (`/re/`, `5,10`) | sed's PATTERN |
| **`-i` / `-i.bak`** | Edit file in place / with a backup copy | sed writing back to disk, not stdout |
| **NR** | awk: number of records (lines) seen so far | The record counter |
| **NF** | awk: number of fields in the current record | `$NF` = last field |
| **`$0` / `$1`** | awk: whole record / first field | Field access |
| **BEGIN / END** | awk blocks running once before / after all input | Init and final-report hooks |
| **associative array** | awk's hash map, e.g. `count[$1]++` | group-by / tallying |
| **`gsub`** | awk's global in-string substitution | sed's `s///g` inside awk |
| **delimiter** | The character `cut`/`awk` split on (`-d` / `-F`) | Sets the FS |
| **`uniq -c`** | Collapse *adjacent* dup lines, prefix a count | Needs sorted input (Rung 3E) |
| **`jq`** | A query language for JSON trees | The structured-data escape hatch |
| **`jsonpath`** | kubectl's built-in JSON path expression | Pull one field from `-o json` |

### The big unlock: which terms are the *same kind of thing*

New learners drown thinking these are twenty unrelated commands. They're not. Group them:

```
GROUP 1 — "The one loop, three power levels" (all: read record → test pattern → act):
   grep  = select lines           (action: print the whole line)
   sed   = select + EDIT lines    (action: s///, d, p on the pattern space)
   awk   = select + COMPUTE       (action: fields, math, arrays, printf, END)
   → Same skeleton. Climb it when your ACTION needs to be richer.

GROUP 2 — "Selecting which records" (all just a PATTERN in different syntax):
   grep 'RE'   ≡   sed '/RE/ ...'   ≡   awk '/RE/ { ... }'
   grep -v     ≡   sed '/RE/d' (delete matches)  ≡  awk '!/RE/'
   → Print-if-match, delete-if-match, print-if-NOT-match are one idea, three tools.

GROUP 3 — "Pulling out a column" (same job, dumb vs smart):
   cut -d: -f1   (dumb: fixed single-char delimiter, no whitespace collapsing)
   awk -F: '{print $1}'   (smart: real fields, math, conditions)
   → Reach for cut on clean single-delimiter data; awk on messy aligned tables.

GROUP 4 — "The counting sandwich" (order is mandatory):
   sort | uniq -c | sort -rn
   → uniq only sees ADJACENT dups, so sort MUST come first.

GROUP 5 — "Substitution, two homes for the same regex-replace":
   sed 's/old/new/g'   (on a stream/file)
   awk '{ gsub(/old/,"new") } 1'   (inside an awk computation)

GROUP 6 — "When it's JSON, not lines":
   jq '.a.b[]'   ≡   kubectl -o jsonpath='{.a.b[*]}'
   → Structure-aware tools; the line tools do NOT belong here.
```

Hold those six groups and you hold the entire toolkit. The most important realization: **`grep`, `sed`, and `awk` are one machine at three power levels** — so "which tool?" is really "how rich does my *action* need to be: just find it (grep), edit it (sed), or compute on it (awk)?"

> **✅ Check yourself before Rung 5:** Without looking — write three ways to print every line that does NOT contain `Running`: one with `grep`, one with `sed`, one with `awk`. (If you can, Group 2 is solid: selection is one idea in three costumes.)

---

# RUNG 5 — The Trace 🔬
### *Follow ONE concrete action end-to-end*

Abstractions blur; one traced pipeline sears the model in. Let's trace the exact on-call question from Rung 0: **"what are the most common Kubernetes event reasons right now?"** — the `sort | uniq -c | sort -rn` idiom you'll run more than any other. We'll follow the data through every hop.

The command:

```bash
kubectl get events -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn | head
```

**Step 1 — `kubectl get events` produces the raw stream.**
kubectl asks the API server for Event objects, formats them as a text table, and writes lines to stdout. Because we passed `-A` (all namespaces), the table gains a leading **NAMESPACE** column, so the header is `NAMESPACE  LAST SEEN  TYPE  REASON  OBJECT  MESSAGE` — and `--no-headers` drops that header row so it doesn't pollute the count. Each line looks like `payments  2m  Warning  OOMKilling  pod/web-1  Memory cgroup out of memory`. This is our record stream entering the conveyor belt.

**Step 2 — the pipe hands that stream to `awk`.**
The `|` connects kubectl's stdout to awk's stdin. awk splits each line on whitespace into fields. With the NAMESPACE column present the layout is `$1`=NAMESPACE, `$2`=LAST SEEN, `$3`=TYPE, `$4`=REASON, `$5`=OBJECT. So `{print $4}` — no pattern, so it runs on every line — prints field 4, the event **REASON** column (`OOMKilling`, `BackOff`, `Scheduled`, …). Out comes a stream of bare reason words, one per line.

> Note the fragility this trace exposes: `$4` assumes the REASON is column 4, which is only true *with* `-A` — drop the `-A` and the NAMESPACE column disappears, so REASON slides to `$3` and `awk '{print $4}'` would silently print the OBJECT instead. Positional field indexing drifts whenever the column set changes, which is exactly why for anything robust you'd prefer `kubectl get events -o jsonpath` or `jq`. The trace teaches the idiom *and* its sharp edge.

**Step 3 — first `sort`: bring identical reasons together.**
Reasons arrive in event-time order, all jumbled (`OOMKilling`, `Scheduled`, `OOMKilling`, `BackOff`, `Scheduled`…). `sort` reorders the whole stream alphabetically so every identical reason is now **adjacent**: all `BackOff` lines together, then all `OOMKilling`, then all `Scheduled`. This step exists *entirely* to satisfy the next one.

**Step 4 — `uniq -c`: collapse adjacent dups and count.**
`uniq` walks the now-sorted stream comparing each line to the previous one. Each run of identical adjacent lines collapses to a single line, and `-c` prefixes the run length. Output: `12 BackOff`, `37 OOMKilling`, `88 Scheduled`. Because step 3 sorted first, these counts are *correct* — every `OOMKilling` was neighbors with the rest.

**Step 5 — second `sort -rn`: rank by count.**
Those count-prefixed lines are still in *reason* order, not *count* order. `sort -rn` re-sorts: `-n` reads the leading number numerically (so `88` > `37` > `12`, not the string order where "12" would precede "37" precede "88"), and `-r` reverses to put the largest on top. Now the biggest offender leads.

**Step 6 — `head`: keep the top few.**
`head` (default 10 lines) trims to the worst offenders and closes the stream. Final output:

```
     88 Scheduled
     37 OOMKilling
     12 BackOff
      5 FailedMount
```

You now have the answer — "OOMKilling is the top *problem* reason, 37 events" — from 400 raw lines, in one pipe, in about a second.

```
VISUAL OF THE TRACE (watch the stream shrink and reshape at each hop)

  kubectl get events -A --no-headers
      │  400 full lines:  "payments 2m Warning OOMKilling pod/web-1 Memory cgroup..."
      ▼
  awk '{print $4}'          ← keep only column 4 (REASON; NAMESPACE is $1 under -A)
      │  400 bare words:  OOMKilling / Scheduled / OOMKilling / BackOff ...
      ▼
  sort                      ← identical reasons become NEIGHBORS
      │  BackOff BackOff ... OOMKilling OOMKilling ... Scheduled Scheduled
      ▼
  uniq -c                   ← collapse adjacent runs + count each
      │  12 BackOff / 37 OOMKilling / 88 Scheduled   (order: alphabetical)
      ▼
  sort -rn                  ← rank by the NUMBER, biggest first
      │  88 Scheduled / 37 OOMKilling / 12 BackOff
      ▼
  head                      ← keep the top 10
      ▼
  ANSWER: the event histogram, most-frequent first.

  Each tool did ONE thing. The pipe made them a reporting engine.
```

The lesson the trace makes concrete: **no single tool here is smart, but the pipe composes dumb steps into an answer.** And the two `sort`s are doing *different jobs* — the first exists to make `uniq` correct (adjacency), the second to rank the result (magnitude). Miss either and the output is wrong in a way that *looks* plausible, which is why understanding the mechanism beats memorizing the idiom.

> **✅ Check yourself before Rung 6:** There are TWO `sort`s in that pipe doing different jobs. Explain what each is for, and predict what breaks if you delete the *first* one. (Hint: uniq's one-line memory.)

---

# RUNG 6 — The Contrast ⚖️
### *The boundary of a concept defines the concept*

You understand the line-tool toolkit best by seeing where it stops and other approaches begin. Two contrasts matter: **line tools vs. structured (JSON) tools**, and **the composable-pipe philosophy vs. a general-purpose scripting language**.

### Contrast 1 — line tools (grep/awk/sed) vs. structured tools (jq/jsonpath)

The line tools assume the data *is* lines-and-columns. That assumption is a superpower on `ps`, `journalctl`, `/etc/passwd`, and `kubectl get` *table* output — and a liability on JSON, where a single value can contain spaces, span multiple lines, or nest arbitrarily deep.

```
WHERE EACH TOOL FAMILY OPERATES

                     Flat table text          Nested JSON / YAML tree
                     (ps, kubectl get)         (kubectl -o json)
                     ──────────────────        ────────────────────────
grep / awk / sed:    ✅ native habitat         ❌ brittle: splits on the
                                                  wrong spaces, can't nest
jq / jsonpath:       ⚠️ overkill for a table   ✅ understands structure,
                                                  types, arrays, filters

The trap: `kubectl get pod -o json | grep image` "works" until an image
name wraps or a field you didn't expect also contains "image". Use jq.
```

| The task | grep/awk/sed | jq / jsonpath | Why the difference |
|---|---|---|---|
| Filter `kubectl get pods` table for non-Running | ✅ `grep -v Running` | ⚠️ awkward | Table output is line-oriented — line tools' home turf |
| Extract every container image from `-o json` | ❌ brittle | ✅ `jq '.items[].spec.containers[].image'` | JSON nesting; a line can't be assumed to be one field |
| Pull `.status.podIP` for a script | ⚠️ fragile column math | ✅ `jsonpath='{.status.podIP}'` | Path expression is exact; column position is not |
| Sum a numeric column from `kubectl top` | ✅ `awk '{sum+=$3}'` | ⚠️ needs `jq` math + `-o json` | top is a table; awk's arithmetic is built for it |
| Rewrite a value across a plain-text manifest | ✅ `sed s///` | ❌ wrong tool | sed edits text streams; jq only speaks JSON |

The pattern in the "why": **match the tool to the *shape* of the data.** Tables → line tools. Trees → jq/jsonpath. Fighting a JSON tree with `grep` is the single most common self-inflicted wound in this whole area.

### Contrast 2 — the Unix pipe vs. a "real" language (Python/Perl)

The older/alternative approach to "process this text" is to write a program in a general language. When would you *not* reach for the pipe?

| Dimension | grep/awk/sed pipe | Python/Perl script |
|---|---|---|
| One-off ad-hoc question | ✅ one line, no file, instant | ⚠️ ceremony: file, run, edit |
| Reusable, tested, multi-step logic | ⚠️ becomes unreadable past ~3 stages | ✅ functions, tests, clarity |
| Arithmetic / simple group-by | ✅ awk is purpose-built | ✅ but heavier |
| Complex data structures, HTTP, JSON schemas | ❌ | ✅ real libraries |
| Available on a bare node / distroless-ish debug pod | ✅ almost always present | ⚠️ maybe no interpreter |
| Readable by the next on-call engineer | ✅ if short | ✅ if well-written |

**When would I NOT use the pipe?** When the logic outgrows a screen: multiple joins, nested data, error handling, anything you'll *maintain* rather than throw away. A 200-character awk one-liner with three `gsub`s and nested conditionals is a Python script wearing a disguise — write the script. Conversely, spinning up Python to answer "how many pods aren't Running?" is over-engineering a `grep -c`.

**One-sentence "why this over that":**
> Reach for the grep/awk/sed pipe for fast, ad-hoc, line-oriented questions on tabular text you can answer and forget; switch to `jq`/`jsonpath` the instant the data is JSON, and to a real language the instant the logic is something you'll maintain rather than throw away.

> **✅ Check yourself before Rung 7:** Explain to an imaginary colleague why `kubectl get pod -o json | grep image` is *structurally* the wrong approach — not "it might miss something," but *why the line-and-column assumption is invalid for JSON in the first place*.

---

# RUNG 7 — The Prediction Test 🧪
### *Write the prediction BEFORE you run the command. A wrong prediction is your model repairing itself.*

**This is where the commands finally arrive.** Each is a **hypothesis you commit to first**, then verify. Predicting-before-running is what converts "I typed `awk`" into "I understand the record loop." For each: read the prediction, cover the outcome, decide if you agree, *then* run it.

Safe sandbox — build a little data set once, then everything below runs as a normal user (Ubuntu 22.04 / any modern Linux; GNU coreutils assumed — BSD/macOS differences are noted where they bite):

```bash
mkdir -p ~/text-lab && cd ~/text-lab

# A fake "kubectl get pods" table (space-aligned, with a header):
cat > pods.txt <<'EOF'
NAME     STATUS       RESTARTS   NODE
web-1    Running      0          node-a
web-2    CrashLoopBackOff 7      node-b
api-1    Running      0          node-a
api-2    OOMKilled    3          node-c
db-1     Pending      0          node-b
job-x    Completed    0          node-a
EOF

# A fake "kubectl top pods" table (numbers to sum):
cat > top.txt <<'EOF'
POD     CPU(cores)  MEM(Mi)
web-1   120m        350
web-2   88m         512
api-1   45m         210
api-2   300m        900
EOF

# A fake log to grep:
cat > app.log <<'EOF'
2026-07-16 10:00:01 INFO  starting up on 10.244.1.7
2026-07-16 10:00:02 WARN  slow query 1200ms
2026-07-16 10:00:03 ERROR db connection refused 10.96.0.10
2026-07-16 10:00:05 INFO  request from 10.244.2.31
2026-07-16 10:00:09 ERROR OOMKilled container payments
EOF
```

---

## Prediction 1 — grep selects lines; `-v` inverts, `-c` counts (the normal case)

> **My prediction:** "If I `grep -v Running pods.txt`, then I'll get every line that does NOT contain `Running` — *including the header row* (it has no 'Running'), so I should add a header-skip; and `grep -c Running pods.txt` will print `2` — *because* grep's whole job is per-line select, `-v` flips the test to non-matches, and `-c` reports the count of matches, not the lines."

```bash
grep -v Running pods.txt
# NAME     STATUS       RESTARTS   NODE          ← header sneaks in (no 'Running')
# web-2    CrashLoopBackOff 7      node-b
# api-2    OOMKilled    3          node-c
# db-1     Pending      0          node-b
# job-x    Completed    0          node-a

grep -c Running pods.txt        # 2   ← COUNT of matching lines, not the lines

grep -iw error app.log          # -i case-insensitive, -w whole word
# 2026-07-16 10:00:03 ERROR db connection refused 10.96.0.10
# 2026-07-16 10:00:09 ERROR OOMKilled container payments

grep -i oomkill pods.txt app.log   # case-insensitive: matches OOMKilled / OOMKilling
# pods.txt:api-2    OOMKilled    3          node-c
# app.log:2026-07-16 10:00:09 ERROR OOMKilled container payments
```

**Verify:** `grep -v Running` returns 5 lines (4 non-Running pods **plus the header** — that's the teachable surprise: `grep` doesn't know about headers). `grep -c Running` prints exactly `2`. If `-c` printed the lines instead of a number, you mixed it up with `-n` (line numbers). The header leak is *why* real pipelines start with `kubectl ... --no-headers` or `awk 'NR>1'`.

---

## Prediction 2 — context flags and `-o` extract, not just match (the "reach into the line" case)

> **My prediction:** "If I `grep -o` with an IP regex, then I'll get ONLY the IP substrings, one per line — not the whole log line — *because* `-o` prints just the matched part; and `grep -B1 -A1 ERROR app.log` will print each ERROR line *plus one line before and after* — *because* `-A`/`-B` are the After/Before context flags that show a match in its neighborhood."

```bash
# Extract only IPv4-looking substrings from the log (-E for + and {}):
grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' app.log
# 10.244.1.7
# 10.96.0.10
# 10.244.2.31

# Show each ERROR with 1 line of context before and after:
grep -B1 -A1 ERROR app.log
# 2026-07-16 10:00:02 WARN  slow query 1200ms          ← B1 of match 1 (before)
# 2026-07-16 10:00:03 ERROR db connection refused ...   ← match 1
# 2026-07-16 10:00:05 INFO  request from 10.244.2.31    ← A1 of match 1 AND B1 of match 2
# 2026-07-16 10:00:09 ERROR OOMKilled container payments   ← match 2 (last line, no A1)
# (NO "--" separator here: the two matches' context windows OVERLAP on the INFO line,
#  so grep merges them into a single contiguous block and prints that line only once.)

# Match EITHER of two words — needs -E for the | alternation:
grep -E "ERROR|WARN" app.log | wc -l      # 3
```

**Verify:** `-oE` prints three bare IP strings and nothing else. The context grep prints **four lines with NO `--` separator**: the two ERROR matches sit close enough that their context windows overlap (both include the `10:00:05 INFO` line), so grep merges them into one contiguous block and prints that shared line only once. A `--` separator appears only between context blocks that are *not* adjacent — space the matches further apart and you'll see it. `grep -E "ERROR|WARN"` finds 3 lines; if you drop the `-E`, the `|` is treated as a *literal pipe character* and matches nothing — proving why alternation needs extended regex.

---

## Prediction 3 — awk does what grep can't: fields, skipping headers, and arithmetic (the compute case)

> **My prediction:** "If I `awk 'NR>1 {sum+=$3} END{print sum}' top.txt`, then I'll get `1972` — the sum of the MEM column — *because* `NR>1` skips the header, `sum+=$3` accumulates field 3 line by line, and `END` prints the running total exactly once after the last line. `grep` could never produce this: it has no fields and no arithmetic."

```bash
# Sum the MEM (3rd) column, skipping the header:
awk 'NR>1 {sum+=$3} END{print sum}' top.txt      # 1972

# Print selected columns, skip header (the everyday reshaping move):
awk 'NR>1 {print $1, $3}' top.txt
# web-1 350
# web-2 512
# api-1 210
# api-2 900

# Colon-delimited data: username + UID from /etc/passwd
awk -F: '{print $1, $3}' /etc/passwd | head -3
# root 0
# daemon 1
# bin 2

# A formatted BEGIN/END report with printf and a computed average:
awk 'NR>1 {sum+=$3; n++}
     END {printf "pods=%d  total_mem=%dMi  avg=%.1fMi\n", n, sum, sum/n}' top.txt
# pods=4  total_mem=1972Mi  avg=493.0Mi

# $NF = the LAST field, whatever the column count:
awk 'NR>1 {print $1, $NF}' pods.txt      # pod name + NODE (last col)
# web-1 node-a
# web-2 node-b
# ...
```

**Verify:** The sum is `1972` (350+512+210+900). The `printf` report shows `avg=493.0Mi`. If your sum came out including a header artifact or was off, you likely forgot `NR>1` and awk tried to add the string `"MEM(Mi)"` as a number (which awk treats as 0 — so it wouldn't error, it'd just silently be wrong: a perfect example of why predicting the value first catches bugs). This is the "sum a `kubectl top` column" move from Rung 0.

---

## Prediction 4 — sed substitutes and templates; `-n` + `p` extracts a range (the edit case)

> **My prediction:** "If I `sed 's/staging/production/g'`, then every `staging` on every line becomes `production` — *because* `s///g` substitutes ALL occurrences per line; and `sed -n '2,4p'` prints ONLY lines 2-4 — *because* `-n` suppresses the default auto-print, so only the explicit `p` on the 2,4 range emits. A `{{IMAGE_TAG}}` placeholder can be filled the same way, which is manifest templating."

```bash
# Substitution (stream → stdout, original file untouched):
echo "deploy to staging, staging config, staging.example.com" | sed 's/staging/production/g'
# deploy to production, production config, production.example.com
# (without /g, only the FIRST 'staging' on the line would change)

# Extract a line RANGE with -n + p (nothing else prints):
sed -n '2,4p' pods.txt
# web-1    Running      0          node-a
# web-2    CrashLoopBackOff 7      node-b
# api-1    Running      0          node-a

# Delete comment lines (address is a regex: lines starting with #):
printf '# header\nkey: value\n# note\nname: web\n' | sed '/^#/d'
# key: value
# name: web

# Manifest templating: fill placeholders from shell variables.
cat > deploy.tmpl.yaml <<'EOF'
image: myregistry/app:{{IMAGE_TAG}}
env: {{ENVIRONMENT}}
EOF
IMAGE_TAG=v2.4.1
ENVIRONMENT=production
sed -e "s/{{IMAGE_TAG}}/${IMAGE_TAG}/g" -e "s/{{ENVIRONMENT}}/${ENVIRONMENT}/g" deploy.tmpl.yaml
# image: myregistry/app:v2.4.1
# env: production

# In-place edit WITH a backup (the safe form):
cp deploy.tmpl.yaml deploy.yaml
sed -i.bak 's/{{IMAGE_TAG}}/v2.4.1/g' deploy.yaml
ls deploy.yaml deploy.yaml.bak     # deploy.yaml (edited)  deploy.yaml.bak (original)
```

**Verify:** The substitution changes all three `staging`s (drop `/g` and only the first changes — try it). `sed -n '2,4p'` prints exactly three lines. `sed -i.bak` leaves both the edited file *and* a `.bak` original. Note the quoting rule: templating uses **double quotes** so the shell expands `${IMAGE_TAG}`, but the placeholder-*defining* heredocs use `'EOF'` (single-quoted) to keep `{{...}}` literal. On **BSD/macOS** `sed -i` needs an explicit suffix arg (`sed -i '' 's/.../.../'`) — the GNU `-i` with no suffix would error there.

---

## Prediction 5 — the counting sandwich, and why `uniq -c` breaks without `sort` (the edge/failure case)

> **My prediction:** "If I run `uniq -c` on UNSORTED node names, then some nodes will appear MORE THAN ONCE in the output with split counts — *because* `uniq` only collapses ADJACENT duplicates, and unsorted data has non-adjacent repeats. Adding `sort` first fixes it, and `sort -rn` at the end ranks by count. I predict the broken version shows `node-a` twice."

```bash
# Column 4 (NODE) from the pods table, skipping the header:
awk 'NR>1 {print $4}' pods.txt
# node-a
# node-b
# node-a
# node-c
# node-b
# node-a

# BROKEN: uniq without sort — adjacency fails:
awk 'NR>1 {print $4}' pods.txt | uniq -c
#   1 node-a       ← node-a appears in THREE separate groups
#   1 node-b
#   1 node-a       ← ...because the three node-a lines were never adjacent
#   1 node-c
#   1 node-b
#   1 node-a

# CORRECT: sort first so identical names are neighbors, then rank:
awk 'NR>1 {print $4}' pods.txt | sort | uniq -c | sort -rn
#   3 node-a
#   2 node-b
#   1 node-c

# The real-world version — busiest event reasons (the Rung 5 idiom):
# kubectl get events -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn | head
```

**Verify:** The broken pipe lists `node-a` **three separate times** with count 1 each; the fixed pipe shows `3 node-a` once, ranked on top. If the "broken" version *happened* to be correct, your input was already sorted — shuffle it and retry. This is the single most important idiom in the toolkit and the most common silent bug: **`uniq -c` is only correct on sorted input.**

---

## Prediction 6 — JSON needs jq/jsonpath, not line tools (the Kubernetes structured-data case)

> **My prediction:** "If I try to pull container images out of `kubectl get pods -o json` with `grep`, it'll be brittle/garbage, but `jq '.items[].spec.containers[].image'` will cleanly emit one image per line — *because* JSON is a nested tree and `jq` walks it structurally, whereas `grep` assumes flat lines. And `kubectl -o jsonpath` will pull a single scalar field (podIP, nodeName) without any external tool."

```bash
# If you have a cluster, run these directly. Otherwise simulate with a JSON file:
cat > pods.json <<'EOF'
{"items":[
  {"metadata":{"name":"web-1"},"spec":{"nodeName":"node-a","containers":[
     {"name":"app","image":"myreg/app:v2.4.1"},
     {"name":"sidecar","image":"envoyproxy/envoy:v1.29"}]},
   "status":{"podIP":"10.244.1.7"}},
  {"metadata":{"name":"api-1"},"spec":{"nodeName":"node-c","containers":[
     {"name":"api","image":"myreg/api:v9"}]},
   "status":{"podIP":"10.244.2.31"}}
]}
EOF

# jq walks the tree: every item → its containers → each image. -r = raw (no quotes).
jq -r '.items[].spec.containers[].image' pods.json
# myreg/app:v2.4.1
# envoyproxy/envoy:v1.29
# myreg/api:v9

# A table of pod → node → IP with jq (structure + reshaping):
jq -r '.items[] | "\(.metadata.name)\t\(.spec.nodeName)\t\(.status.podIP)"' pods.json
# web-1   node-a  10.244.1.7
# api-1   node-c  10.244.2.31

# On a REAL cluster — kubectl jsonpath pulls single fields, no external tool:
# kubectl get pod web-1 -o jsonpath='{.status.podIP}'      # 10.244.1.7
# kubectl get pod web-1 -o jsonpath='{.spec.nodeName}'     # node-a
# All images across all pods via jsonpath (note the range/loop syntax):
# kubectl get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'

# Contrast — the WRONG way, to feel the pain:
grep image pods.json
#   "image":"myreg/app:v2.4.1"},      ← quotes, commas, braces, key name...
#   ...you'd need more cleanup, and it breaks the moment JSON is minified to one line.
```

**Verify:** `jq -r '.items[].spec.containers[].image'` yields exactly three clean image strings (note it correctly finds *both* containers in the first pod — a line tool would need you to know how many containers exist). The `grep image` version returns quoted, comma-laden fragments and would return **nothing** if the JSON were minified onto a single line — the definitive proof that JSON is a tree, not lines. `jq -r`'s `-r` strips the surrounding quotes; drop it and you'll see `"myreg/app:v2.4.1"` with quotes, teaching what raw mode does.

---

## The prediction habit, generalized

Fill this in for anything new you try with these tools:

| Prediction: "If I do X, then Y, because [mechanism]" | Ran it? | Right? | If wrong, what did my model miss? |
|---|---|---|---|
| 1. |  |  |  |
| 2. |  |  |  |
| 3. |  |  |  |

**Handy real-world one-liners you'll reach for on-call** (each maps to a rung above):

```bash
# Non-Running pods across all namespaces (grep -v, plus header handling):
kubectl get pods -A | grep -vw Running

# Case-insensitive hunt for OOM anywhere in events:
kubectl get events -A | grep -i oomkill

# Event histogram, most frequent first (the counting sandwich):
# ($4 = REASON because -A adds a leading NAMESPACE column; without -A it would be $3)
kubectl get events -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn | head

# Total memory used across pods (awk arithmetic on kubectl top):
kubectl top pods --no-headers | awk '{sum+=$3} END{print sum "Mi"}'

# Every image running in the cluster, deduplicated (jq → sort -u):
kubectl get pods -A -o json | jq -r '.items[].spec.containers[].image' | sort -u

# One pod's IP and node for a script (jsonpath, no external tool):
kubectl get pod web-1 -o jsonpath='{.status.podIP}{"\t"}{.spec.nodeName}{"\n"}'

# Count how many lines (pods) a namespace has, minus the header:
kubectl get pods -n payments --no-headers | wc -l

# Uppercase + strip spaces from a value (tr, the character-level tool):
echo "  Prod-Cluster  " | tr -d ' ' | tr 'a-z' 'A-Z'      # PROD-CLUSTER
```

The Kubernetes payoff: **every one of these is the same conveyor belt** — kubectl emits a stream of records, and you select (`grep`), reshape (`awk`/`cut`), aggregate (`sort`/`uniq`), or descend into JSON (`jq`/`jsonpath`). Once the model is automatic, you stop copying blog one-liners and start *composing the exact pipe your question needs*.

---

# 🏔 CAPSTONE — Compress It
### *If you can't do this, you've found your gap — which is useful*

**One sentence, no notes:**
> `grep`, `sed`, and `awk` are one machine at three power levels — read text as a stream of line-records split into fields, test a pattern to select records, then act (print / edit / compute) and emit to stdout — and you compose them with pipes (adding `sort`/`uniq` to aggregate and `jq`/`jsonpath` when the data is a JSON tree) to turn a firehose of `kubectl` output into the one answer you need.

**Explain it to a beginner in 3 sentences:**
> 1. These tools all read text one line at a time, and most of them can split each line into columns (fields) split on spaces or a delimiter you choose with `-F`/`-d`; `grep` finds the lines you want, `sed` edits lines, and `awk` does math and grouping over the columns.
> 2. Because every tool reads standard input and writes standard output, you snap them together with the pipe `|` — so `kubectl get events -A | awk '{print $4}' | sort | uniq -c | sort -rn` collapses hundreds of lines into "which event happened most," one dumb step at a time.
> 3. The one big exception is JSON: `kubectl -o json` is a nested tree, not a table, so you use `jq` or `kubectl -o jsonpath` to walk it — using `grep` on JSON is the classic mistake because a value can span lines and nest arbitrarily.

**Map of sub-capability → the one core idea (all one pattern — "read record, test pattern, do action, emit"):**

```
grep (find/-v/-c/-i/-o/-E/-A/-B/-C/-w/-r/-f)  → action = "print matching lines"
sed  (s///g, -i, -n p, /d, ranges, templating) → action = "EDIT the pattern space"
awk  ($1..$NF, NR, NF, -F, BEGIN/END, arrays)  → action = "COMPUTE over fields"
cut  (-d -f)                                    → dumb single-delimiter field pull
sort (-n -r -k -u)                              → reorder records (make uniq possible)
uniq (-c)                                       → collapse ADJACENT dups + count
tr                                              → translate/delete CHARACTERS (sub-line)
wc   (-l)                                       → count records
jq / kubectl -o jsonpath                        → the SAME idea for JSON trees
```

Nine sub-skills, one idea: *a stream of records flows through filters you compose with pipes.*

**Which rung will I most likely need to revisit hands-on?**

Be honest — the three usual suspects:

- **Rung 3E / Prediction 5 (the `sort | uniq -c` adjacency trap).** Everyone "knows" it and everyone still forgets the `sort` under pressure. The fix: run Prediction 5's *broken* version until watching `node-a` appear three times is muscle memory.
- **Rung 3D / Prediction 3 (awk fields, `NR>1`, `$NF`, `sum+=`).** Stating "`$3` is the third column" is easy; instinctively reaching for `awk 'NR>1{sum+=$3}END{print}'` to sum a `kubectl top` column takes reps. Do Prediction 3 against real `kubectl top pods`.
- **Rung 3F / Prediction 6 (JSON needs jq, not grep).** The pull to `grep` a JSON blob is strong at 3 AM. Rehearse `jq -r '.items[].spec.containers[].image'` and `jsonpath='{.status.podIP}'` until they're the reflex, so you never fight a tree with a line tool.

If any check-yourself felt shaky, that's your next 30-minute hands-on session — go there first.

---

## Related concepts

- [io-redirection-pipes](10-io-redirection-pipes.md) — the `|`, stdin/stdout, and `tee`/`xargs`/heredocs that make these tools *compose* into pipelines in the first place
- [shell-scripting](08-shell-scripting.md) — where these one-liners graduate into scripts: variables, loops, and when to switch from a pipe to a real language
- [linux-philosophy](01-linux-philosophy.md) — "everything is a file / a stream of text," the design bet that makes grep/awk/sed universal across `/proc`, logs, and `kubectl`
- [processes-job-control](07-processes-job-control.md) — the `ps`/`pgrep` text output you'll constantly pipe through `grep` and `awk` during node triage
- [performance-monitoring](21-performance-monitoring.md) — `dmesg`, `journalctl`, `vmstat`, and `lsof` output are all line streams these tools filter and aggregate
- [linux-kubernetes-map](27-linux-kubernetes-map.md) — the full map tying `kubectl` output parsing and node triage back to these Linux text primitives

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Why is "snap together tiny programs with a pipe" a fundamentally more powerful design than "one big program with lots of options," given that the questions you ask of your logs are unpredictable and mostly one-off?

**A:** Because a big program with options can only answer the questions its author anticipated, while your on-call questions are unpredictable and mostly throwaway — before the toolkit, every new question meant writing (and debugging, and discarding) a whole program. Small single-purpose tools that each do ONE transformation to a stream of text, joined by `|`, let you *compose* the answer to a question nobody planned for, in one line with zero compilation. And when the next question arrives ("...but only for /api/*?"), you edit the pipe rather than rewrite a program. None of the tools is impressive alone; the composition is the power.

### Before Rung 3
**Q:** Say the core sentence from memory. Then derive: why can `awk` sum a column of numbers but `grep` fundamentally cannot? Which part of the one-sentence model does `grep` simply not implement?

**A:** The core sentence: every one of these tools reads text as a stream of records (one line = one record, split into fields by whitespace), applies a pattern to decide which records to act on, performs an action on the matches, and writes the result to stdout — so you compose transforms by piping one tool's output into the next's input. `grep` doesn't implement the "split into FIELDS" part of the model, and its only action is "print the whole line unchanged" — it treats the line as one atomic blob and has no variables or arithmetic. `awk` implements the full model: it splits each record into `$1..$NF` automatically and its actions include real variables and math, so `{sum+=$3} END{print sum}` can accumulate a column. Same loop skeleton, but grep stops at "select"; awk climbs to "compute."

### Before Rung 4
**Q:** Draw the conveyor belt from memory. Then: (1) in `awk`, what are `NR` and `NF`, and what does `$NF` refer to? (2) Why does `sed -n '5,10p'` print only lines 5-10 — what does `-n` change? (3) Why is `uniq -c` wrong without a preceding `sort`?

**A:** The conveyor belt: bytes arrive on stdin, get chopped into records at the record separator (`\n`), field-aware tools further chop each record into fields at the field separator (whitespace, or `-F`/`-d`), each record is pattern-tested, the action runs on matches, and bytes are emitted on stdout into the next tool's stdin. (1) `NR` is the number of records (lines) seen so far; `NF` is the number of fields in the current record; since `$N` accesses field N, `$NF` is the *last* field of the line, whatever the column count. (2) sed normally auto-prints the pattern space after each cycle (step 3 of its loop); `-n` suppresses that auto-print, so nothing is emitted except what an explicit `p` command prints — and the `5,10` address restricts that `p` to lines 5 through 10. (3) `uniq` only compares *adjacent* lines — it's a streaming dedup with a one-line memory — so non-adjacent repeats form separate groups with split counts; `sort` must come first to make identical lines neighbors so the counts are correct.

### Before Rung 5
**Q:** Write three ways to print every line that does NOT contain `Running`: one with `grep`, one with `sed`, one with `awk`.

**A:** With grep: `grep -v Running pods.txt` — `-v` inverts the test to print non-matches. With sed: `sed '/Running/d' pods.txt` — the regex address selects matching lines and `d` deletes them, so only non-matching lines auto-print. With awk: `awk '!/Running/' pods.txt` — the negated regex pattern with no action uses awk's default action, "print the whole line." All three are Group 2's one idea in three costumes: a PATTERN selecting records, with print-if-NOT-match as the action.

### Before Rung 6
**Q:** There are TWO `sort`s in the event-histogram pipe doing different jobs. Explain what each is for, and predict what breaks if you delete the *first* one.

**A:** The first `sort` exists entirely to make `uniq` correct: it reorders the reason stream alphabetically so every identical reason becomes *adjacent*, which is required because uniq has only a one-line memory and collapses only consecutive duplicates. The second `sort -rn` does a different job — ranking: it re-sorts the count-prefixed lines numerically (`-n`, so 88 > 37 > 12 rather than string order) and reversed (`-r`) so the biggest count lands on top. Delete the first sort and the counts fracture: each reason appears multiple times with split counts (e.g. `OOMKilling` showing up in several small groups instead of one `37 OOMKilling`), producing output that is wrong but *looks* plausible — the classic silent bug.

### Before Rung 7
**Q:** Explain why `kubectl get pod -o json | grep image` is *structurally* the wrong approach — why is the line-and-column assumption invalid for JSON in the first place?

**A:** The line tools' entire model assumes the data is a flat stream where one line = one record and columns split cleanly on a delimiter. JSON breaks that assumption at the root: it is a *nested tree*, where a single value can contain spaces, span multiple lines, or sit arbitrarily deep — and the same text could legally be pretty-printed across many lines or minified onto one line, in which case `grep image` returns everything or garbage fragments full of quotes, commas, and braces. There is simply no stable line/column structure for the pattern to key on, so any match is a coincidence of formatting, not of structure. The right tools are structure-aware ones — `jq '.items[].spec.containers[].image'` or `kubectl -o jsonpath` — which walk the tree by path, immune to how the text happens to be laid out: match the tool to the *shape* of the data.
