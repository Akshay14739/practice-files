# 🐧 Linux Foundations for the Retail-Store DevOps Project — The Learning Ladder Edition
### Every Linux concept this project stands on — climbed Pain → Idea → Machinery → Hands-on, so you *derive* the commands instead of memorizing them

> **What this file is:** the complete Linux prerequisite layer for the [kalyan-course project](00-INDEX.md) — Docker (S02–05), Terraform+EKS (S06–07), Kubernetes core (S08–11), Helm (S12/19), AWS data plane (S13–16), autoscaling (S17–18), observability (S20), CI/CD GitOps (S21) and Istio (S22). Ten concepts, each climbed on the **Learning Ladder** used in [../../Linux/](../../Linux/00-README.md): **🔥 Pain → 💡 One Idea → ⚙️ Machinery → 🏷️ Vocabulary → 🔬 Trace → ⚖️ Contrast → 🧪 Hands-on (predict first!) → 🏔 Capstone.**
>
> **The one rule:** read *up* the ladder, never down. Commands live at the top (🧪) for a reason — run them only after you hold the machinery. And always **write your prediction before pressing Enter**: a wrong prediction is your mental model repairing itself, and that's the most valuable event in the whole process.
>
> **Go deeper:** every climb ends with a link to the full single-concept ladder in [../../Linux/](../../Linux/00-README.md). This file is the project-scoped fast path; those files are the deep dives.

---

## 🎯 RUNG 0 — The Setup (for this whole file)

- **What am I learning?** The ten Linux primitives the retail-store project exercises on every single page: shell & environment, the filesystem, permissions, processes & signals, scripting, text processing, streams & pipes, namespaces+cgroups (containers), storage & OverlayFS, and package management.
- **Why did it land on my desk?** Because every "DevOps" action in this course is a Linux action wearing a costume: `${DB_PASSWORD}` in Compose is shell expansion; `docker stop` is a SIGTERM; `OOMKilled` is a cgroup; the CI pipeline's tag update is one `sed` line; a container *is* namespaces + cgroups + OverlayFS. When a demo breaks, the fix is always one rung below the tool.
- **What do I already know?** You can type commands. What's likely fuzzy is the *mechanism* under them — exactly what this file closes.

### Where each concept bites in this project

| # | Climb | Where the project forces it on you |
|---|---|---|
| 1 | Shell, Environment & PATH | `export DB_PASSWORD` for Compose (S04), `RETAIL_*` env vars (S04/08/14), `terraform output` capture, `$GITHUB_ENV` in CI (S21) |
| 2 | Filesystem & "everything is a file" | `~/.kube/config`, `/etc/resolv.conf` in pods, `/mnt/secrets-store` CSI mounts (S09/14), Dockerfile `COPY` paths (S03) |
| 3 | Permissions, ownership & non-root | `chmod +x create-cluster.sh`, `runAsUser: 1000`/`fsGroup` (S08), `readOnlyRootFilesystem`, mounted-secret modes (S09) |
| 4 | Processes, signals & PID 1 | `docker stop` grace (S02), zero-downtime rolling updates (S08/21), `CrashLoopBackOff`, `OOMKilled` (S18/19), `port-forward ... &` |
| 5 | Shell scripting | `create-cluster-with-karpenter.sh` (S19), the 5-service Helm install loop, `git-push.sh`, heredoc `trust-policy.json` (S21) |
| 6 | Text processing | CI's `sed -i` tag write-back (S21), `base64 -d` Argo CD password, `jq` on SQS messages (S14), jsonpath |
| 7 | Streams, redirection & pipes | `kubectl logs -f`, `>> $GITHUB_ENV` (S21), `2>/dev/null`, `terraform output \| pbcopy`-style plumbing |
| 8 | Namespaces & cgroups | what `docker run` builds (S02), `resources.requests/limits` (S08), the Spring-Boot-needs-350Mi OOM incident (S19), HPA % (S18) |
| 9 | Storage, mounts & OverlayFS | image layers & buildx cache (S03/05), `emptyDir` (S08), EBS PV/PVC (S10), CSI secret volumes (S09/14) |
| 10 | Packages & the CLI toolchain | installing docker/kubectl/helm/terraform/aws/argocd — step 0 of every section; `apt-get` lines in Dockerfiles (S03) |

---
---

# CLIMB 1 — The Shell, Environment Variables & PATH

## 🔥 Rung 1 — The Pain

Programs need per-environment configuration (a DB password in dev ≠ prod), and they need it **without editing code**. Before environment variables, config was hardcoded or passed in ever-longer argument lists; sharing a machine meant editing each other's files. And without `PATH`, you'd type `/usr/local/bin/terraform` every time.

**Where this project makes you feel it (S04):** the Compose file says `RETAIL_CATALOG_PERSISTENCE_PASSWORD: ${DB_PASSWORD}`. Forget `export DB_PASSWORD=...` in your shell and all four database containers crash-loop with empty-password errors — the course does this to you deliberately. Then S21 does the same trick in CI: `echo "TAG=sha-${GITHUB_SHA::7}" >> $GITHUB_ENV` is how one workflow step passes a variable to the next.

## 💡 Rung 2 — The One Idea

> **The shell is a program that turns your text into process launches, and every process is born with a private copy of its parent's exported variables — so "configuration" is just ancestry.**

Derive from this: why `export` matters (un-exported vars don't reach children), why editing a Compose env needs `--force-recreate` (the container process was *born* with the old copy — S04's core lesson), why a new terminal loses your variables (new parent), and why `PATH` is just one of those inherited variables.

## ⚙️ Rung 3 — The Machinery

```
your terminal
   └─ bash (reads ~/.bashrc at start)          shell variable:  DB_PASSWORD=x      (bash's private memory)
        │  export DB_PASSWORD                  environment var: DB_PASSWORD=x      (copied to every CHILD)
        ├─ docker compose up          ← child: SEES it (interpolates ${DB_PASSWORD} into container env)
        ├─ terraform apply            ← child: SEES it (e.g. AWS_REGION, TF_VAR_*)
        └─ a container's main process ← grandchild: sees ONLY what Docker chose to pass in
```

- **Resolution of a command:** `helm` → bash checks aliases → builtins → then walks `PATH` left-to-right (`/usr/local/bin:/usr/bin:...`) and runs the **first** match. `which helm` / `type helm` shows the verdict.
- **The copy is made at fork time.** Change the parent's variable *after* launching a child → child keeps the old value. This is exactly why S04 teaches `docker compose up -d --force-recreate ui`: `stop`/`start` reuses the *existing* container (old env frozen at creation); only re-*creating* re-reads the YAML and re-injects env.
- **Startup files:** interactive shells read `~/.bashrc` — that's why `export AWS_REGION=us-east-1` put there survives new terminals, but one typed in a terminal dies with it.

> **✅ Check yourself:** S04 Lab: you edit `RETAIL_UI_THEME: orange` in the compose file and run `docker compose stop ui && docker compose start ui`. Why is the theme still purple, mechanically? (Answer in terms of *when the env copy is made*.)

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where it appears in the project |
|---|---|---|
| shell / `bash` | the text→process launcher | every terminal session, every `.sh` script |
| environment variable | a key=value copied to children at launch | `${DB_PASSWORD}` (S04), `RETAIL_*` (S04/08/14), `AWS_REGION` |
| `export` | "include this var in copies given to children" | `export DB_PASSWORD=...` before `docker compose up` |
| `PATH` | the ordered dir list searched for commands | why `terraform`, `kubectl`, `helm` "just work" after install |
| `~/.bashrc` | per-shell startup script | where your `alias k=kubectl` and exports persist |
| `$GITHUB_ENV` | a *file* GitHub Actions re-reads between steps to build env | the CI tag hand-off (S21 workflow step 4) |
| `envFrom` / `env` (K8s) | Kubernetes' way of setting a container's env at creation | ConfigMap/Secret injection (S08/09/14) |

Same-thing-different-name: Compose `environment:`, Dockerfile `ENV`, K8s `env:`/`envFrom:`, and GitHub Actions `env:` are all the **same primitive** — writing the env block a process is born with.

## 🔬 Rung 5 — The Trace: `${DB_PASSWORD}` from your keyboard to MySQL

1. You type `export DB_PASSWORD=DB101` → bash marks it exported in its own memory.
2. You run `docker compose up -d` → bash forks; the compose process inherits `DB_PASSWORD`.
3. Compose interpolates `${DB_PASSWORD}` while *parsing the YAML* — before any container exists.
4. It calls the Docker API: "create container `catalog-db` with env `MYSQL_PASSWORD=DB101`".
5. The container's PID 1 (`mysqld`) is **born** with that value in its environment — a private copy.
6. You later change the export and `stop/start` → nothing changes (step 5 already happened). Only `up -d --force-recreate catalog-db` repeats steps 3–5.

## ⚖️ Rung 6 — The Contrast

- **Env vars vs config files:** env is per-process, invisible on disk, great for secrets-ish values and 12-factor apps (the retail store reads *everything* from `RETAIL_*` vars). Files are auditable and structured — that's why K8s pairs both: ConfigMap→env for scalars, mounted files for certs/large config.
- **When NOT env:** truly secret material at rest (S09/14 moves it to Secrets Manager + CSI mounts — env still gets it *last-mile*, but the source of truth leaves Git and disk).

## 🧪 Rung 7 — Hands-on (predict FIRST, then run)

**Lab 1 — export vs not, and the frozen copy (reproduces the S04 trap):**
> **My prediction:** the child shell sees only the exported var; and after I change the parent's value, an already-running child still holds the old one — because the copy is made at fork time.

```bash
DB_PASSWORD=first            # shell var only
bash -c 'echo "child sees: [$DB_PASSWORD]"'     # → []  (not exported)

export DB_PASSWORD=first
bash -c 'echo "child sees: [$DB_PASSWORD]"'     # → [first]

# The frozen-copy proof (a mini force-recreate lesson):
sleep 300 &                       # a child born NOW, with DB_PASSWORD=first
export DB_PASSWORD=second
cat /proc/$!/environ | tr '\0' '\n' | grep DB_PASSWORD   # → DB_PASSWORD=first  (frozen!)
kill %1                           # cleanup ("recreate" is the only fix — same as the container)
```
**Verify:** the running child's `/proc/<pid>/environ` still shows `first` even though your shell now says `second`. That file *is* the container-env lesson: recreation, not restart, re-reads config.

**Lab 2 — PATH resolution order (why `which` is your friend when two versions exist):**
> **My prediction:** a fake `kubectl` placed in a directory earlier in `PATH` will shadow the real one, because bash takes the first match walking left-to-right.

```bash
mkdir -p ~/fakebin && printf '#!/bin/sh\necho "I am the impostor"\n' > ~/fakebin/kubectl
chmod +x ~/fakebin/kubectl
PATH="$HOME/fakebin:$PATH" kubectl version --client   # → "I am the impostor"
which kubectl                                          # your real one (unmodified shell)
rm -rf ~/fakebin
```
**Verify:** the impostor answered only in the modified-PATH invocation. Real-world version: two `terraform` binaries after a manual install — `type -a terraform` lists *all* matches in order.

## 🏔 Capstone — Compress it

> **One sentence:** the shell launches processes that inherit a frozen copy of its exported variables, so all config injection — Compose, Dockerfile, K8s, CI — is just deciding what's in that copy at birth.

📚 **Go deeper:** [../../Linux/02-shell-and-environment.md](../../Linux/02-shell-and-environment.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 1</b> (say it aloud first, then open)</summary>

**Q:** You edit `RETAIL_UI_THEME: orange` in the compose file, then `docker compose stop ui && docker compose start ui` — why is the theme still purple?

**A:** A process's environment is a **copy handed to it at the moment the container is *created***, and it's frozen there. `stop` then `start` restarts the **same existing container** — its PID 1 was born with the OLD env copy (no THEME var), and `start` does **not** re-read the compose YAML; it just re-runs the already-created container. So no new env copy is ever made → the theme stays purple. Only **recreating** the container (`docker compose up -d --force-recreate ui`) builds a *new* container whose process is born with the current YAML's env. This is the frozen-copy-at-fork mechanic from Rung 3: config injection = deciding what's in that copy *at birth*, and only re-birth re-reads it.

</details>

---
---

# CLIMB 2 — The Filesystem, Paths & "Everything Is a File"

## 🔥 Rung 1 — The Pain

Without one unified tree, every tool would invent its own way to find things. Unix's answer: **one root `/`**, everything addressable by path — including *non-files* like kernel state (`/proc`), devices (`/dev`), and runtime config (`/etc/resolv.conf`). If you don't know where things live, you can't debug: "is my kubeconfig stale?", "what DNS server is this pod using?", "where did the CSI driver mount my secret?"

**Where this project makes you feel it:** `docker build` context paths and `COPY src/ /app/` (S03); `~/.kube/config` (S07 — `aws eks update-kubeconfig` *writes this file*); `/etc/resolv.conf` inside pods (how DNS actually happens, S08); `/mnt/secrets-store` (S09/14 — your Secrets Manager values appear as *files*); `terraform.tfstate` (S06 — the file whose location/locking is the whole remote-state story).

## 💡 Rung 2 — The One Idea

> **Linux exposes everything — data, config, kernel state, devices, even a container's secrets — as entries in one tree rooted at `/`, so "debugging" is mostly knowing which file to read.**

## ⚙️ Rung 3 — The Machinery

```
/                       the single root — every path starts here
├── etc/                host config:  resolv.conf (DNS), hosts, passwd
├── home/you/           ~  your files: ~/.kube/config, ~/.aws/credentials, ~/.bashrc
├── proc/               a WINDOW into the kernel, not a disk: /proc/<pid>/environ, /proc/mounts
├── sys/                kernel knobs & state (cgroups live under /sys/fs/cgroup)
├── var/                growing data: /var/lib/docker (images!), logs
├── tmp/                scratch, wiped on reboot
└── mnt/, /media        mount points — where OTHER filesystems get grafted onto the tree
```

- **Absolute vs relative:** `/app/main.go` vs `./main.go` — relative resolves against the process's *current working directory*. Docker build contexts are the classic trap: `COPY` paths are relative to the **build context** you passed (`docker build .`), not your shell's cwd.
- **Hidden files:** `.` prefix (`~/.kube`, `~/.aws`, `.git`, `.gitignore`) — the entire credential/config layer of this course is dotfiles.
- **`/proc` is a live API:** `cat /proc/self/environ` is your own env; `/proc/<pid>/ns/` shows namespaces (Climb 8 uses this). Nothing under `/proc` is on disk — reads are answered by the kernel *at that moment*.
- **A mount grafts a subtree:** when the EBS CSI driver (S10) attaches a volume, or the Secrets CSI driver (S09) materializes `/mnt/secrets-store/username`, they are *mounting* — inserting another filesystem at a directory. Same primitive as a USB stick.

> **✅ Check yourself:** a pod's app "can't find its DB password". Name the two *files* you'd read to decide whether the problem is env injection or the CSI mount ( hint: `/proc/<pid>/environ` and a path under `/mnt/secrets-store`).

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| FHS | the convention for what lives where | why kubeconfig is in `~/.kube` and docker state in `/var/lib/docker` |
| `~/.kube/config` | YAML file of clusters/users/contexts | written by `aws eks update-kubeconfig` (S07), read by every `kubectl` |
| `/proc` | kernel state pretending to be files | `/proc/<pid>/environ`, `/proc/mounts` for debugging |
| mount point | directory where another FS is grafted | `/mnt/secrets-store` (S09/14), PV mounts (S10) |
| working directory | the dir relative paths resolve from | Terraform runs *per-directory* (S06); build contexts (S03) |
| dotfile | hidden config file | `~/.aws/credentials`, `.gitignore`, `.github/workflows/` (S21) |
| inode / symlink | the real file object / a name pointing at another name | how K8s swaps ConfigMap contents atomically under a mount |

## 🔬 Rung 5 — The Trace: `kubectl get pods` finds its cluster

1. You run `kubectl get pods` → kubectl needs to know *which* cluster.
2. It checks `$KUBECONFIG`; unset → falls back to the conventional path `~/.kube/config`.
3. Reads that YAML: current-context → cluster `eksdemo-dev` (endpoint URL + CA) + user (exec plugin → `aws eks get-token`).
4. The `aws` CLI it shells out to reads *its* dotfiles: `~/.aws/credentials`, `~/.aws/config`.
5. HTTPS request goes to the API server; the response renders in your terminal.
   *Every hop was a file read you can inspect yourself — nothing magic.*

## ⚖️ Rung 6 — The Contrast

- **One tree + mounts (Linux)** vs **drive letters (Windows):** Linux grafts everything into one namespace — which is exactly what makes container volumes natural (any directory can be a mount).
- **`/proc` vs metrics agents:** metrics-server (S18) and OpenTelemetry (S20) ultimately *read these same kernel files* — the agent is convenience, not new data.

## 🧪 Rung 7 — Hands-on

**Lab 1 — read kernel state as files (`/proc` is live):**
> **My prediction:** `/proc/self/environ` shows my shell's env NUL-separated, and two different `cat /proc/uptime` reads differ — because `/proc` is answered live by the kernel, not stored.

```bash
tr '\0' '\n' < /proc/self/environ | head -5      # your env, as a "file"
cat /proc/uptime; sleep 2; cat /proc/uptime      # numbers moved — live kernel state
grep -m3 "" /proc/meminfo                        # what `free` and metrics-server read
ls -l /proc/self/ns/                             # your namespaces (Climb 8 payoff)
```
**Verify:** uptime advanced by ~2s between reads. There is no file on disk being updated — the read *is* the query.

**Lab 2 — the kubeconfig/dotfile treasure hunt:**
> **My prediction:** my cloud/k8s tooling state is all dotfiles in `$HOME`, and `kubectl config view` is just pretty-printing one of them.

```bash
ls -la ~ | grep '^\.\|\.kube\|\.aws\|\.config' || ls -la ~
cat ~/.kube/config 2>/dev/null | head -20        # clusters/contexts/users (if you have one)
kubectl config view --minify 2>/dev/null | head  # SAME data, filtered — prove it's the file
find ~/.aws -maxdepth 1 -type f 2>/dev/null      # credentials & config used by terraform/aws
```
**Verify:** everything `kubectl config` reports exists verbatim in `~/.kube/config`. Corollary for S07: if `kubectl` hits the wrong cluster, you fix a *file*, not a daemon.

## 🏔 Capstone

> **One sentence:** one tree, everything is a path in it — config is dotfiles, kernel state is `/proc`, and volumes/secrets arrive by mounting — so debugging is choosing the right file to read.

📚 **Go deeper:** [../../Linux/01-linux-philosophy.md](../../Linux/01-linux-philosophy.md), [../../Linux/03-filesystem-navigation.md](../../Linux/03-filesystem-navigation.md), [../../Linux/04-file-operations.md](../../Linux/04-file-operations.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 2</b> (say it aloud first, then open)</summary>

**Q:** A pod's app "can't find its DB password." Name the two *files* you'd read to decide whether the problem is env injection or the CSI mount.

**A:** Read one file from each layer:
1. **`/proc/<pid>/environ`** (e.g. `kubectl exec <pod> -- sh -c 'tr "\0" "\n" < /proc/1/environ | grep -i PASS'`, or just `env | grep`). This shows whether the password env var was actually **injected into the process**. Missing/empty here → the fault is env injection: the ConfigMap/Secret wiring (`envFrom`/`secretKeyRef`), or the synced Secret was never created.
2. **A path under `/mnt/secrets-store`** (e.g. `kubectl exec <pod> -- cat /mnt/secrets-store/password`). This shows whether the **CSI driver actually fetched and mounted** the secret. File missing → the SecretProviderClass / Pod Identity / mount path failed; file present but env var missing → the sync-into-a-native-Secret / `secretKeyRef` step failed.

Reading both files localizes the break to exactly one hop — because on Linux everything, including a pod's injected config and its mounted secret, is just a file you can `cat`.

</details>

---
---

# CLIMB 3 — Permissions, Ownership & the Non-Root Container

## 🔥 Rung 1 — The Pain

Multi-user machines needed a way to stop users trampling each other; containers inherited the same model wholesale. Without it: any process could read any secret and overwrite any binary. With it *misunderstood*: the classic project failures — "permission denied" on a script you just wrote, a pod that can't read its mounted volume, an image that runs as root and fails a security review.

**Where this project makes you feel it:** every script needs `chmod +x` before `./create-cluster-with-karpenter.sh` runs (S19); the catalog Deployment pins `runAsUser: 1000`, `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, drops ALL capabilities (S08); `fsGroup: 1000` exists *specifically* so mounted volumes are writable by the non-root app; the Dockerfile creates `appuser` uid 1000 (S03) instead of running as root.

## 💡 Rung 2 — The One Idea

> **Every file carries an owner, a group, and three rwx triplets (user/group/other), and the kernel picks exactly ONE triplet per access — matching your uid first, then gid, then "other" — so every permission bug is "which triplet matched, and what's in it?"**

## ⚙️ Rung 3 — The Machinery

```
-rwxr-x---  1  appuser  appgroup   script.sh
 │└┬┘└┬┘└┬┘     owner     group
 │ │  │  └─ other: ---  (everyone else: nothing)
 │ │  └──── group: r-x  (members of appgroup: read+execute)
 │ └─────── user:  rwx  (appuser: everything)
 └── type (- file, d dir, l symlink)

r=4 w=2 x=1  →  rwxr-x--- = 750.   chmod 750 script.sh ≡ chmod u=rwx,g=rx,o= script.sh
```

- **The matching is exclusive:** if you *are* the owner, only the owner triplet applies — even if group/other would allow more.
- **Directories redefine rwx:** `r` = list names, `w` = create/delete entries, `x` = *enter/traverse*. A file can be `644` and still unreachable if a parent dir lacks `x`.
- **Execute bit is why `./script.sh` fails fresh from `git clone`/editor:** the file was created without `x` (umask 022 → 644). `chmod +x` flips it. (`bash script.sh` works regardless — you're executing *bash*, which merely *reads* the script.)
- **Containers reuse this verbatim:** `runAsUser: 1000` = the container's PID 1 gets uid 1000; files in the image owned by root with `640` become unreadable → the classic non-root breakage. `fsGroup: 1000` = kubelet chowns/chgrps mounted volumes so gid 1000 can write them. `readOnlyRootFilesystem` = the whole image mount becomes `ro`; the app may write only to explicit volumes (`emptyDir` for `/tmp`).
- **SSH cares too:** private keys must be `600/400` — the ssh client *refuses* group/other-readable keys.

> **✅ Check yourself:** the S08 pod runs as uid 1000 with `readOnlyRootFilesystem: true` and crashes trying to write `/tmp/cache`. Two independent fixes exist — name both (hint: one is a volume, one is a spec change you should *not* make).

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| uid / gid | the numeric identity the kernel checks (names are cosmetic) | `runAsUser: 1000` (S08) = uid, no matter what the user is *called* |
| `chmod` / `chown` | change triplets / change owner:group | `chmod +x *.sh` before every course script |
| octal mode (750, 644) | the three triplets as digits | `defaultMode` on Secret volumes; key files `0400` |
| umask | bits *removed* from new files' default perms | why fresh files are 644 and dirs 755 |
| `fsGroup` | K8s: gid applied to volumes at mount | mounted volume writable by non-root app (S08) |
| `runAsNonRoot` | kubelet refuses to start uid-0 containers | S08 securityContext — the audit checkbox |
| `readOnlyRootFilesystem` | image FS mounted read-only | S08 — root filesystem becomes untamperable |
| capabilities | root's powers, sliced (~40 slices) | `capabilities: {drop: [ALL]}` (S08); deep dive → [17-capabilities](../../Linux/17-capabilities.md) |

## 🔬 Rung 5 — The Trace: uid-1000 catalog reads its mounted secret

1. Kubelet creates the pod; `securityContext` says `runAsUser: 1000`, `fsGroup: 1000`.
2. CSI driver mounts the secret at `/mnt/secrets-store`; kubelet applies `fsGroup` → files gid 1000, mode `440`.
3. App (uid 1000, gid 1000) opens `/mnt/secrets-store/password`: kernel walks each dir (needs `x`), reaches the file.
4. uid 1000 ≠ file owner (root) → owner triplet skipped; gid 1000 matches → group triplet `r--` → **read allowed**.
5. Same app tries to write `/etc/foo` → root-owned, `readOnlyRootFilesystem` besides → **EROFS/EACCES**, exactly as designed.

## ⚖️ Rung 6 — The Contrast

- **Run-as-root convenience vs non-root discipline:** root containers "just work" (and own any file they touch) — until a container escape gives root on the node. The project's posture (non-root + drop ALL + read-only FS) is the production default; the price is you must *understand* this climb.
- **rwx vs capabilities vs seccomp/AppArmor:** rwx guards *files*; capabilities slice *root's powers*; seccomp/AppArmor filter *syscalls/paths*. Different layers — a "permission denied" can come from any of them (S08 uses the first two).

## 🧪 Rung 7 — Hands-on

**Lab 1 — the exclusive-triplet surprise + the `chmod +x` ritual:**
> **My prediction:** a file with mode `044` is readable by *everyone except its owner*, because the owner triplet matches first and it says `---`; and my fresh script won't run until `+x`.

```bash
cd $(mktemp -d)
echo "secret" > weird.txt && chmod 044 weird.txt
cat weird.txt                      # Permission denied — YOU are the owner, owner=---
sudo -u nobody cat weird.txt 2>/dev/null || cat weird.txt  # (other users CAN — if sudo allows)

printf '#!/bin/bash\necho it runs\n' > run.sh
./run.sh                           # Permission denied (mode 644 — no x)
bash run.sh                        # works — bash READS it
chmod +x run.sh && ./run.sh        # works — now IT executes
ls -l                              # read the triplets you just made
```
**Verify:** the owner being *denied* while others are allowed proves matching is exclusive, not cumulative. This is the model that makes every K8s `securityContext` line predictable.

**Lab 2 — reproduce the non-root container problem (S08 in one command):**
> **My prediction:** as uid 1000 inside a container, writing `/` fails (root-owned) but `/tmp` works (mode 1777); and a root-owned `640` file is unreadable — the exact reason images must chown app dirs.

```bash
docker run --rm --user 1000:1000 alpine sh -c '
  id
  touch /newfile      && echo wrote /  || echo "cannot write / (as expected)"
  touch /tmp/newfile  && echo wrote /tmp
  ls -l /etc/shadow; cat /etc/shadow || echo "cannot read shadow (as expected)"'
# Bonus — fsGroup intuition: mount a host dir owned by root and watch the write fail:
d=$(mktemp -d) && sudo chown root:root "$d" && sudo chmod 750 "$d"
docker run --rm --user 1000:1000 -v "$d":/data alpine touch /data/x || echo "this is why fsGroup exists"
sudo rm -rf "$d"
```
**Verify:** every failure maps to a triplet decision you can now narrate. The last one *is* the pod-volume problem `fsGroup: 1000` solves by re-owning the mount.

## 🏔 Capstone

> **One sentence:** the kernel picks one rwx triplet per access by matching uid then gid then other — and the project's whole non-root container posture (`runAsUser`, `fsGroup`, `readOnlyRootFilesystem`, `chmod +x`) is just arranging those triplets on purpose.

📚 **Go deeper:** [../../Linux/05-permissions-ownership.md](../../Linux/05-permissions-ownership.md), [../../Linux/06-users-groups-sudo.md](../../Linux/06-users-groups-sudo.md), [../../Linux/17-capabilities.md](../../Linux/17-capabilities.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 3</b> (say it aloud first, then open)</summary>

**Q:** The S08 pod runs as uid 1000 with `readOnlyRootFilesystem: true` and crashes writing `/tmp/cache`. Name the two independent fixes — one a volume, one a spec change you should *not* make.

**A:** The write fails because the whole root filesystem (which includes `/tmp`) is mounted **read-only**.
- **Fix 1 (the right one — a volume):** mount a writable volume over `/tmp` — an `emptyDir: {}` (or `emptyDir: {medium: Memory}` for tmpfs). Now `/tmp/cache` lands on a real writable filesystem *grafted over that one path*, while the rest of the root FS stays immutable. You punch a writable hole exactly where the app needs it.
- **Fix 2 (the one you should NOT make):** set `readOnlyRootFilesystem: false`. It "works," but it throws away the hardening — the entire image filesystem becomes writable and tamperable.

The lesson: keep the protection, add a targeted writable mount. This is Climb 3 (which triplet blocks the write) meeting Climb 9 (mounts bypass the read-only layer).

</details>

---
---

# CLIMB 4 — Processes, Signals & PID 1

## 🔥 Rung 1 — The Pain

You need to run many programs at once, stop them *cleanly* (finish the in-flight request, close the DB connection), and know why one died. Without signals there is only the power cord. Without understanding **PID 1**, containers stop slowly, zombies accumulate, and "graceful shutdown" silently isn't.

**Where this project makes you feel it:** `docker stop` takes exactly 10 s on some containers (S02) — that's SIGTERM ignored, then SIGKILL; Kubernetes rolling updates (S08/S21) are only zero-downtime **if the app exits on SIGTERM** within `terminationGracePeriodSeconds`; `CrashLoopBackOff` = "your PID 1 keeps exiting"; `OOMKilled`/exit 137 = SIGKILL from the kernel (S19's Spring-Boot-at-256Mi incident); `kubectl port-forward svc/argocd-server 8080:443 &` (S21) is job control.

## 💡 Rung 2 — The One Idea

> **A process is a running program with a PID, a parent, and an exit code; signals are the only way to talk to it from outside — and in a container, your app is PID 1, so *it* personally receives every stop request.**

## ⚙️ Rung 3 — The Machinery

```
THE STOP SEQUENCE every orchestrator uses (docker stop / kubectl delete pod / rollout):

  SIGTERM ──▶ PID 1 in container        "please finish up and exit"
     │            ├─ app handles it: close conns, exit 0     → stop takes ~0s  ✅
     │            └─ app ignores it (or never receives it)…
     └── grace period (docker: 10s, K8s: terminationGracePeriodSeconds, default 30s)
              └──▶ SIGKILL ──▶ kernel destroys it, no cleanup → exit code 137  ⚠️
```

- **Exit codes talk:** `0` success; `1..127` app errors; `128+signal` killed-by-signal → **137 = 128+9 (SIGKILL: OOM or grace expiry)**, **143 = 128+15 (SIGTERM, clean-ish)**. You'll read these in `kubectl describe pod` for the rest of your career.
- **PID 1 is special:** it gets no default signal handlers (must install its own) and must *reap* children (zombies otherwise). This is why Dockerfiles insist on **exec form** `CMD ["app"]` — shell form `CMD app` makes `/bin/sh` PID 1, and sh doesn't forward SIGTERM to your app → every stop waits out the full grace period.
- **Foreground/background & job control:** `cmd &` runs without holding your terminal; `jobs`, `fg`, `kill %1`. Port-forwards in the course run this way.
- **The kernel's own signal:** the OOM killer (Climb 8) sends SIGKILL directly — no grace, no negotiation.

> **✅ Check yourself:** a rolling update (S21, replicas 3) replaces pods one at a time. Explain where SIGTERM, readiness, and the grace period each fit to make that *zero-downtime* — and what breaks if the app ignores SIGTERM.

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| PID / PPID | process id / parent's id | `ps`, `/proc/<pid>`, container PID 1 |
| SIGTERM / SIGKILL / SIGINT | polite stop / unblockable destroy / Ctrl-C | `docker stop`, pod eviction, canceling `terraform apply` |
| exit code 137 / 143 | 128+9 killed / 128+15 terminated | `OOMKilled` (S19), normal pod shutdown |
| grace period | time between TERM and KILL | Docker 10s; K8s `terminationGracePeriodSeconds` 30s |
| PID 1 | first process in a namespace; signal-special | your app in every container (S02/03) |
| exec vs shell form | `CMD ["app"]` vs `CMD app` | why the retail images use exec form (S03) |
| `CrashLoopBackOff` | kubelet restarting an exiting PID 1 with backoff | S14 wrong-endpoint errors, S19 memory incident |
| `&`, `jobs`, `kill %1` | job control | `kubectl port-forward ... &` (S21) |

## 🔬 Rung 5 — The Trace: one pod's death during the S21 rolling update

1. Argo CD syncs the new image tag → Deployment creates new ReplicaSet → new pod starts.
2. New pod passes its readiness probe → Service adds it to EndpointSlices.
3. Old pod is chosen to die: kubelet removes it from endpoints (traffic drains) **and** sends SIGTERM to its PID 1.
4. The app's SIGTERM handler stops accepting, finishes in-flight requests, exits 0 (well within 30s).
5. Kubelet sees exit; pod object goes away. Had the app ignored TERM: 30 s pause, then SIGKILL, exit 137 — connections severed mid-flight. Repeat per pod → maxUnavailable respected → user sees V904 with zero dropped requests.

## ⚖️ Rung 6 — The Contrast

- **Signals vs API shutdown endpoints:** some apps expose `/shutdown` — orchestrators don't call those; the *universal* contract is SIGTERM. Apps built for K8s (all five retail services) treat SIGTERM as first-class.
- **`kill` vs `kill -9`:** default TERM allows cleanup; `-9` is for processes already beyond saving. Habitual `-9` is how data gets corrupted — same reasoning as never setting grace period to 0.

## 🧪 Rung 7 — Hands-on

**Lab 1 — measure the grace period: trap vs no trap (the whole graceful-shutdown story in 30 s):**
> **My prediction:** stopping a container whose PID 1 ignores SIGTERM takes ~10 s and exits 137; one that traps SIGTERM stops instantly with 0 — because `docker stop` = TERM, wait, KILL.

```bash
docker run -d --name deaf alpine sleep 999          # sleep does NOT handle TERM
time docker stop deaf                                # ~10s
docker inspect -f 'exit={{.State.ExitCode}}' deaf    # 137 = 128+9
docker rm deaf

docker run -d --name polite alpine sh -c \
  'trap "echo bye; exit 0" TERM; while true; do sleep 1; done'
time docker stop polite                              # ~1s
docker inspect -f 'exit={{.State.ExitCode}}' polite  # 0
docker logs polite; docker rm polite                 # "bye" — the handler ran
```
**Verify:** 10 s vs 1 s, 137 vs 0. Every slow `kubectl delete pod` you'll ever see is the left column.

**Lab 2 — read the process tree & exit codes like `kubectl describe` does:**
> **My prediction:** `sleep 500 &` appears in `ps` with my shell as PPID; `kill %1` ends it and `$?`-style status shows the signal — because children report death to parents.

```bash
sleep 500 &
ps -o pid,ppid,stat,etime,cmd -p $!       # your child, PPID = your bash's PID
jobs                                       # [1]+ Running
kill %1 && wait %1; echo "status: $?"      # 143 = 128+15 (TERM) — same math as pod exits
ps aux --sort=-%mem | head -5              # biggest memory consumers (pre-OOM triage habit)
```
**Verify:** status 143 is *exactly* what a gracefully-terminated pod reports; 137 in `kubectl describe` now reads as "SIGKILL — OOM or grace expiry", not a mystery number.

## 🏔 Capstone

> **One sentence:** containers stop by SIGTERM-wait-SIGKILL aimed at your app as PID 1, so graceful shutdown, rolling updates, 137s, and CrashLoopBackOff are all one story: what your process does with signals and exit codes.

📚 **Go deeper:** [../../Linux/07-processes-job-control.md](../../Linux/07-processes-job-control.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 4</b> (say it aloud first, then open)</summary>

**Q:** A rolling update (replicas 3) replaces pods one at a time. Where do SIGTERM, readiness, and the grace period each fit to make it zero-downtime — and what breaks if the app ignores SIGTERM?

**A:** Per pod replaced:
- **Readiness probe** — the NEW pod must pass it before the Service adds it to EndpointSlices, so traffic only ever flows to a pod that's actually ready (no requests dropped onto a warming-up pod).
- **SIGTERM** — the OLD pod is first removed from EndpointSlices (traffic drains away) *and* sent SIGTERM; its handler stops accepting new work, finishes in-flight requests, exits 0.
- **Grace period** (`terminationGracePeriodSeconds`, default 30s) — the window the pod gets to do that cleanly before the kernel sends SIGKILL.

`maxUnavailable: 1` keeps ≥2 pods serving throughout, so the user never sees an outage.

**If the app ignores SIGTERM:** it keeps running until the grace period expires, then gets **SIGKILLed (exit 137)** — in-flight requests on that pod are severed mid-flight, and shutdown is neither graceful nor prompt. Readiness still stops routing to un-ready pods, but connections already on the dying pod are dropped → not truly zero-downtime. (This is why K8s-ready apps treat SIGTERM as first-class.)

</details>

---
---

# CLIMB 5 — Shell Scripting: the Automation Muscle

## 🔥 Rung 1 — The Pain

Typing the same 12 commands in order, twice a day, across cluster create/destroy cycles — that's this course without scripts. Humans forget steps and ignore failures mid-sequence. The instructor's answer everywhere: `create-cluster-with-karpenter.sh`, `create-aws-dataplane.sh`, `03_v1.0.0_install_remote_helm_charts.sh`, `git-pull.sh`/`git-push.sh` (S19/21) — "straight-through commands, no clever if-else," run identically every time.

## 💡 Rung 2 — The One Idea

> **A script is the terminal session you wish you'd typed, made repeatable — and its two load-bearing features are variables (don't repeat values) and exit codes (don't continue past failure).**

## ⚙️ Rung 3 — The Machinery

- **Shebang** `#!/bin/bash` — kernel reads the first line to pick the interpreter; needs `chmod +x` (Climb 3).
- **Exit codes drive control flow:** every command returns 0 (success) or non-zero. `a && b` runs b only on success; `a || b` only on failure; `set -e` aborts the script on any failure — the difference between "cluster half-created" and "stopped at the broken step."
- **Variables & command substitution:** `AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)` — capture output, reuse. **Quote expansions** (`"$var"`) or spaces will split them.
- **Loops over lists:** the course's signature pattern (S19):
  ```bash
  for SVC in catalog carts checkout orders ui; do
    helm upgrade --install $SVC stacksimplify/retailstore-sample-${SVC}-chart \
      --version 1.0.0 -f values-${SVC}.yaml --wait --timeout 5m && echo "$SVC ok"
  done
  ```
- **Heredocs write files from scripts** — S21 builds IAM trust policy JSON with live variable substitution:
  ```bash
  cat > trust-policy.json <<EOF
  { "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/..."} }
  EOF
  ```
- **Arguments:** `$1`, `$#`, `"$@"` — `git-push.sh "V904 commit"` passes the commit message as `$1`.
- **Functions & traps:** `cleanup() {...}; trap cleanup EXIT` — teardown that runs even on failure (the cost-hygiene sections beg for this).

> **✅ Check yourself:** in the Helm loop above, what exactly does `&&` guard, and what would `set -e` at the top of the script change about a mid-loop failure?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| shebang | interpreter selector, line 1 | every `.sh` in the repo |
| `$?` / exit code | last command's verdict | `&& echo "$SVC installed successfully"` (S19) |
| `set -euo pipefail` | abort on error/undef var/pipe failure | what production versions of the course scripts add |
| `$(cmd)` | command substitution | `$(aws sts get-caller-identity ...)` (S21), `$(terraform output -raw ...)` |
| heredoc `<<EOF` | multi-line stdin/file authoring | `trust-policy.json` (S21) |
| `$1` `"$@"` | positional args | `git-push.sh "msg"`, `update-ui-home-html.sh V904` |
| `for`/`while` | iteration | 5-service install/uninstall loops (S19/21) |
| trap | run code on signal/exit | cleanup-on-exit patterns |

## 🔬 Rung 5 — The Trace: `./git-push.sh "V904 commit"` (S21)

1. Kernel sees `./git-push.sh` → shebang → launches bash with the file.
2. `$1` = `V904 commit` (quoted → one argument, space preserved).
3. Script runs `git add -A && git commit -m "$1" && git push` — each `&&` gates on the previous exit code.
4. If commit fails (nothing staged), push never runs — the chain *is* the error handling.
5. Script's own exit code = last command's → your terminal (or CI) can chain on it in turn.

## ⚖️ Rung 6 — The Contrast

- **Scripts vs Terraform/Helm:** declarative tools reconcile *state*; scripts sequence *actions*. The course uses both correctly: Terraform owns infrastructure state; scripts own orchestration order (create VPC → create EKS → install charts).
- **When NOT bash:** >100 lines, real data structures, needs testing → Python/Go. Bash is the glue, not the application.

## 🧪 Rung 7 — Hands-on

**Lab 1 — exit codes & `&&` chains (the course's error-handling in miniature):**
> **My prediction:** with plain `;` all steps run even after failure; with `&&` the chain stops at the first failure; `set -e` makes the whole script stop — because each command's exit code gates continuation.

```bash
cd $(mktemp -d)
cat > deploy.sh <<'EOF'
#!/bin/bash
echo "step 1: build";      true
echo "step 2: push";       false        # ← simulated failure
echo "step 3: deploy — should NOT run after a failed push"
EOF
chmod +x deploy.sh && ./deploy.sh; echo "script exit: $?"   # step 3 RAN (bad!)

sed -i 's/;       false/ \&\& false/; s/^echo "step 3/false || exit 1\necho "step 3/' deploy.sh 2>/dev/null
# simpler: rewrite with set -e
cat > deploy.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "step 1: build" && true
echo "step 2: push"  && false
echo "step 3: deploy"
EOF
./deploy.sh; echo "script exit: $?"                          # stops after step 2, exit 1
```
**Verify:** first version lies (deploys after failed push); `set -e` version stops honestly. Now reread the S19 install loop and spot its `&&`.

**Lab 2 — reproduce the S21 heredoc + args + substitution pattern:**
> **My prediction:** the heredoc expands `${ACCOUNT}` at write time, `$1` arrives from the command line, and `$(date ...)` is captured — because heredocs interpolate unless the delimiter is quoted.

```bash
cd $(mktemp -d)
cat > make-policy.sh <<'EOF'
#!/bin/bash
set -euo pipefail
REPO="${1:?usage: make-policy.sh <github-repo>}"      # required arg with error message
ACCOUNT=$(printf '%012d' 42)                          # stand-in for aws sts get-caller-identity
cat > trust-policy.json <<POLICY
{ "Statement": [{ "Principal": {"Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"},
   "Condition": {"StringLike": {"token.actions.githubusercontent.com:sub": "repo:${REPO}:*"}} }] }
POLICY
echo "wrote trust-policy.json for repo ${REPO}"
EOF
chmod +x make-policy.sh
./make-policy.sh || true                              # see the usage error (arg validation!)
./make-policy.sh myuser/argocd-repo && cat trust-policy.json
```
**Verify:** the JSON contains the substituted account and repo — this is *exactly* how S21 §6.1 builds its trust policy. Note `<<'EOF'` (quoted) for the outer script prevented *your shell* from expanding anything early, while the inner unquoted `<<POLICY` expands at run time — the two heredoc modes in one lab.

## 🏔 Capstone

> **One sentence:** a script is replayable terminal history where variables remove repetition and exit codes (`&&`, `set -e`) stop the march past failure — the entire create/destroy discipline of this course is built from that.

📚 **Go deeper:** [../../Linux/08-shell-scripting.md](../../Linux/08-shell-scripting.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 5</b> (say it aloud first, then open)</summary>

**Q:** In the Helm loop `helm upgrade --install $SVC … && echo "$SVC ok"`, what does `&&` guard, and what would `set -e` change about a mid-loop failure?

**A:** The `&&` guards only the **`echo`** — the "ok" message prints just when `helm` returned exit 0. It does **not** stop the loop: if one service's install fails, `&&` skips that echo and the `for` loop **marches on to the next service** — a partial, half-broken deploy that still looks like it's progressing.

Adding **`set -e`** at the top makes the script **abort on the first non-zero exit** — the moment a `helm upgrade` fails, the script stops (no further services attempted) and exits non-zero. Trade-off: fail-fast honesty (stop at the broken step) instead of soldiering through a partial deploy. That's the difference between "cluster half-installed, exit 0" and "stopped at the broken service, exit 1." (`set -euo pipefail` is the production default for exactly this reason.)

</details>

---
---

# CLIMB 6 — Text Processing: grep, sed, awk, jq, base64

## 🔥 Rung 1 — The Pain

Everything infra emits is text: logs, YAML, JSON, `kubectl` output, Terraform output. Without tools to *filter, extract, and edit* text programmatically, you're eyeballing thousands of lines — and CI can't eyeball at all.

**Where this project makes you feel it:** the *entire CI→CD handoff* (S21) is one sed line: `sed -i "s/^  tag: .*/  tag: $TAG/" source/ui/chart/values-ui.yaml`; the Argo CD password is `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`; SQS verification (S14) is `aws sqs receive-message ... | jq -r '.Messages[].Body' | jq`; every debugging session starts `kubectl logs deploy/catalog | grep -i timeout`.

## 💡 Rung 2 — The One Idea

> **Four verbs cover 95% of infra text work — grep *selects lines*, sed *edits lines*, awk *extracts columns*, jq *walks JSON* — and pipes chain them because each reads stdin and writes stdout.**

## ⚙️ Rung 3 — The Machinery

- **grep** matches a pattern per line: `-i` case-fold, `-v` invert, `-E` extended regex, `-r` recurse, `-A3/-B3` context. Regex basics that pay rent: `^` start, `$` end, `.` any, `.*` anything, `[abc]`, `\.` literal dot.
- **sed** applies an edit script per line; the workhorse is substitution `s/pattern/replacement/` (+`g` all matches). `-i` edits **in place** — that's what makes it CI's file-editing tool. `^  tag: .*` in S21 anchors to the *exact YAML indentation* — sed doesn't understand YAML, only lines, which is both its power and its danger.
- **awk** splits each line into `$1..$NF` by whitespace (or `-F:` custom): `kubectl get pods | awk '$3!="Running" {print $1}'` — select column(s) with conditions.
- **jq** is grep+awk for JSON: `.key`, `.[]` iterate, `-r` raw strings, `|` pipes *inside* jq. `kubectl -o json | jq '.items[].metadata.name'`. (`kubectl -o jsonpath={...}` is the built-in cousin.)
- **base64** is **encoding, not encryption** — K8s Secrets are base64: `echo -n 'x' | base64`, decode with `base64 -d`. The `-n` matters: a stray newline inside a Secret breaks DB logins invisibly (classic S09 bug).

> **✅ Check yourself:** why does the S21 sed pattern start with `^  tag:` (two spaces) and what would happen to the chart if it were just `tag:`? (Think: `image.tag` vs any other `tag:` deeper in the file.)

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| regex | pattern language for text | grep/sed patterns everywhere |
| `sed -i 's/../../'` | in-place line edit | THE CI tag write-back (S21) |
| `awk '{print $1}'` | column extraction | parsing `kubectl get` tables |
| `jq -r '.a[].b'` | JSON query, raw output | SQS message bodies (S14), Actions debugging |
| jsonpath | kubectl's built-in JSON query | `-o jsonpath='{.data.password}'` (S21) |
| `base64 -d` | decode (NOT decrypt) | Argo CD initial password (S21), reading Secrets (S09) |
| `sort \| uniq -c` | frequency table | log triage: top error kinds |
| `cut -d: -f1` | field slice by delimiter | quick extractions |

## 🔬 Rung 5 — The Trace: CI updates the Helm values file (S21 step 6)

1. Workflow computed `TAG=sha-1a2b3c4`.
2. `sed -i "s/^  tag: .*/  tag: $TAG/" source/ui/chart/values-ui.yaml` — double quotes let the shell substitute `$TAG` *before* sed runs.
3. sed streams the file line by line; only lines matching `^  tag: ` (start-of-line, two spaces) are rewritten; `.*` swallows the old tag; `-i` writes the file back atomically.
4. `git diff` now shows exactly one changed line → committed by ci-bot → this diff *is* the deployment event Argo CD reacts to.
   *One regex, correctly anchored, drives the entire CD pipeline.*

## ⚖️ Rung 6 — The Contrast

- **sed/grep vs yq/jq:** line tools don't parse structure — fine for one anchored line (S21), dangerous for arbitrary YAML edits (use `yq` when structure matters).
- **base64 vs encryption:** anyone can decode base64 — that's *why* the course moves secrets to AWS Secrets Manager (S09/14) instead of trusting K8s Secret "encoding."

## 🧪 Rung 7 — Hands-on

**Lab 1 — replicate the CI tag write-back on a real values file:**
> **My prediction:** the anchored sed changes only the image tag line and leaves the HPA's `targetCPUUtilizationPercentage` etc. untouched, because `^  tag:` matches exactly one line.

```bash
cd $(mktemp -d)
cat > values-ui.yaml <<'EOF'
image:
  repository: 123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui
  tag: sha-0ld0000
autoscaling:
  enabled: true
  minReplicas: 1
metadata:
  tag: do-not-touch-me
EOF
TAG=sha-1a2b3c4
sed -i "s/^  tag: .*/  tag: $TAG/" values-ui.yaml
grep -n "tag:" values-ui.yaml
```
**Verify:** line 3 now says `sha-1a2b3c4`; the decoy `tag: do-not-touch-me` (4 spaces deep? no — same 2-space indent under metadata!) *also* changed if it had identical indentation — observe whether it did, and appreciate why S21's file has only ONE line at that indent with that key. If both changed, you've just discovered sed's structure-blindness firsthand — the exact reason `yq` exists.

**Lab 2 — the pipeline quartet + base64 round-trip (Argo CD password style):**
> **My prediction:** `grep` narrows lines, `awk` takes a column, `sort|uniq -c` counts, `jq` walks JSON, and base64 round-trips only if I used `-n` — because echo adds a newline that becomes part of the "secret".

```bash
printf 'GET /health 200\nGET /topology 200\nPOST /cart 500\nGET /health 200\nPOST /orders 500\n' > access.log
grep -E ' 5[0-9][0-9]$' access.log                      # only errors
awk '{print $2}' access.log | sort | uniq -c | sort -rn  # top endpoints by hits

echo '{"Messages":[{"Body":"{\"orderId\":\"42\"}"}]}' | jq -r '.Messages[].Body' | jq .   # S14 SQS pattern

P_BAD=$(echo    'DB101' | base64)   # newline smuggled in!
P_OK=$(echo  -n 'DB101' | base64)
echo "bad=$P_BAD ok=$P_OK"                                # different!
echo "$P_BAD" | base64 -d | od -c | head -1               # see the trailing \n
```
**Verify:** the two encodings differ — the `\n` inside the decoded value is the invisible bug that breaks DB auth when hand-crafting Secrets. `-n` forever.

## 🏔 Capstone

> **One sentence:** grep selects, sed edits, awk extracts, jq walks JSON, base64 merely encodes — chained by pipes they are the entire "glue" layer of this project's CI, verification, and debugging.

📚 **Go deeper:** [../../Linux/09-text-processing.md](../../Linux/09-text-processing.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 6</b> (say it aloud first, then open)</summary>

**Q:** Why does the S21 sed pattern start with `^  tag:` (two spaces), and what would happen if it were just `tag:`?

**A:** sed is **line-oriented and structure-blind** — it matches text, not YAML nesting. `^  tag:` anchors to start-of-line (`^`) plus exactly two spaces of indentation, which uniquely identifies the `tag:` key nested under `image:` (i.e. `image.tag`). If the pattern were just `tag:` (unanchored), sed would match **every** line containing `tag:` at any indentation — any other `tag:` key elsewhere in the file would also get rewritten to the image SHA, corrupting unrelated config. The two-space anchor makes the substitution surgical: exactly one line changes. (This structure-blindness is precisely why `yq` exists for anything more complex than a single, reliably-indented line — see the Climb 6 Lab 1 decoy.)

</details>

---
---

# CLIMB 7 — I/O Streams, Redirection & Pipes

## 🔥 Rung 1 — The Pain

Programs need input, output, and a place for errors — *composably*, so one tool's output feeds the next without temp files everywhere. Get streams wrong and you pipe error messages into parsers, lose logs, or overwrite files you meant to append to.

**Where this project makes you feel it:** `kubectl logs -f deploy/orders` *is* a stream (container stdout is the pod log — that's the whole K8s logging contract); `echo "TAG=..." >> $GITHUB_ENV` (S21) — append, not overwrite, or you'd clobber earlier steps' vars; `2>/dev/null` hides expected noise in checks; `terraform output | ...` feeds endpoints into the next command; `curl -s ... | jq` everywhere.

## 💡 Rung 2 — The One Idea

> **Every process is born with three open files — stdin(0), stdout(1), stderr(2) — and redirection (`>`, `>>`, `2>`) or a pipe (`|`) just re-points those file descriptors before the program starts.**

## ⚙️ Rung 3 — The Machinery

```
 keyboard ──▶ 0 stdin  ┌─────────┐ 1 stdout ──▶ terminal   (or > file, or | next-cmd)
                       │ process │
                       └─────────┘ 2 stderr ──▶ terminal   (separate! survives a pipe)

cmd > f      truncate f, stdout→f          cmd >> f     append stdout to f
cmd 2> f     stderr→f                      cmd &> f     both→f     cmd 2>&1  merge 2 into 1
cmd1 | cmd2  cmd1's stdout → cmd2's stdin  (kernel pipe buffer, runs BOTH concurrently)
```

- **The pipe only carries stdout.** Errors still hit your terminal — which is why `curl ... | jq` shows curl errors *around* jq output. To pipe both: `2>&1 |`.
- **Container logging is literally this:** the runtime captures the PID 1's fd 1 and fd 2 into files; `kubectl logs` reads them; `-f` follows like `tail -f`. An app that writes to a log *file* inside the container is invisible to `kubectl logs` — the retail services log to stdout on purpose.
- **`tee` splits a stream** (screen *and* file); `xargs` turns a stream into arguments (`kubectl get pods -o name | xargs kubectl delete` — with care!).
- **`>` vs `>>` is the S21 gotcha:** `$GITHUB_ENV` accumulates across steps; `>` would erase previous exports.

> **✅ Check yourself:** why does `kubectl logs` show nothing for an app that writes `/var/log/app.log` inside its container, and what one-line app change fixes it?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| fd 0/1/2 | stdin/stdout/stderr file descriptors | container logs = fd1+fd2 captured |
| `>` / `>>` | truncate / append redirect | `>> $GITHUB_ENV` (S21), heredoc `cat > file` |
| `2>/dev/null` | discard errors | quiet existence checks in scripts |
| `2>&1` | merge stderr into stdout | logging both to one file/pipe |
| `\|` pipe | connect stdout→stdin, concurrent | every `... \| jq`, `... \| grep` chain |
| `tee` | split stream to file + screen | keeping evidence of long applies |
| `/dev/null` | the discard device (a file!) | Climb 2's philosophy cameo |
| `-f` follow | keep reading as file grows | `kubectl logs -f`, `docker compose logs -f` |

## 🔬 Rung 5 — The Trace: `docker compose logs -f ui` shows a request

1. Browser hits the UI → the Node app writes one access line to **its stdout (fd 1)**.
2. Docker's runtime holds the other end of that fd → appends the line (JSON-wrapped) to the container's log file.
3. `docker compose logs -f ui` opens that file, prints existing lines, and *follows* — blocking until more bytes appear.
4. Ctrl-C stops *your* follower only; the app and its stream never noticed. Same pipeline serves `kubectl logs -f` with kubelet in Docker's role.

## ⚖️ Rung 6 — The Contrast

- **Pipes vs temp files:** `a | b` streams concurrently with no disk; temp files persist evidence but need cleanup. CI uses both: pipes for transforms, `$GITHUB_ENV` (a file!) precisely *because* steps are separate processes that can't share a pipe.
- **stdout logging vs file logging:** 12-factor (stdout) delegates rotation/shipping to the platform — the reason S20's OpenTelemetry collector can scrape everything uniformly.

## 🧪 Rung 7 — Hands-on

**Lab 1 — prove stderr bypasses the pipe (then merge it):**
> **My prediction:** the error line ignores `grep` and hits my terminal raw; adding `2>&1` sends it through the pipe — because `|` connects only fd 1.

```bash
err() { echo "NORMAL line"; echo "ERROR line" >&2; }
err | grep -c line          # count = 1, but "ERROR line" still PRINTED (bypassed pipe!)
err 2>&1 | grep -c line     # count = 2 — both went through
err 2>/dev/null             # errors discarded — the script-quieting idiom
err > out.txt 2> err.txt && cat out.txt err.txt   # split destinations
```
**Verify:** first command printed ERROR *above* the count — visually out of band. Now `curl -s https://wrong.host | jq` failures make sense: jq saw empty stdin; curl's complaint was fd 2.

**Lab 2 — `>` vs `>>` and the $GITHUB_ENV pattern:**
> **My prediction:** simulating two CI steps with `>` loses step 1's variable; `>>` keeps both — because truncate vs append.

```bash
cd $(mktemp -d); GITHUB_ENV=./github.env
echo "TAG=sha-1a2b3c4"  > "$GITHUB_ENV"      # step A (wrong: truncates)
echo "IMAGE_BASE=ecr/ui" > "$GITHUB_ENV"     # step B clobbers A!
cat "$GITHUB_ENV"                             # TAG is GONE

echo "TAG=sha-1a2b3c4"  >  "$GITHUB_ENV"     # reset
echo "IMAGE_BASE=ecr/ui" >> "$GITHUB_ENV"    # step B appends (the real CI way)
cat "$GITHUB_ENV"; source "$GITHUB_ENV"; echo "next step sees: $TAG + $IMAGE_BASE"
```
**Verify:** with `>>` both survive and `source` (what Actions effectively does between steps) exposes them — the exact S21 mechanism, demystified.

## 🏔 Capstone

> **One sentence:** three inherited file descriptors plus redirection and pipes compose every tool chain in this course — and container "logging" is nothing but the platform capturing fd 1 and fd 2.

📚 **Go deeper:** [../../Linux/10-io-redirection-pipes.md](../../Linux/10-io-redirection-pipes.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 7</b> (say it aloud first, then open)</summary>

**Q:** Why does `kubectl logs` show nothing for an app that writes `/var/log/app.log` inside its container, and what one-line app change fixes it?

**A:** `kubectl logs` (like `docker logs`) reads **only the container's stdout (fd 1) and stderr (fd 2)** — the runtime captures those two streams into the pod's log file, and that's the entire logging contract. An app writing to a **file** inside the container (`/var/log/app.log`) is writing to its own filesystem, which the capture pipeline never reads → `kubectl logs` sees nothing.

**One-line fix:** make the app log to **stdout/stderr** instead of a file — reconfigure the logger's destination to `stdout`, or `ln -sf /dev/stdout /var/log/app.log`. Now the runtime captures it and `kubectl logs` shows it — and rotation/shipping become the platform's job (why S20's collectors can scrape every pod uniformly). This is 12-factor logging: fd 1/fd 2 are the interface.

</details>

---
---

# CLIMB 8 — Namespaces & cgroups: What a Container Actually Is

## 🔥 Rung 1 — The Pain

You want many apps on one machine that (a) can't *see* each other and (b) can't *starve* each other — without the weight of a VM per app. Before containers: VMs (minutes to boot, GBs each) or shared hosts (one runaway process kills all, port conflicts, dependency hell — the exact "works on my machine" pain S01 opens with).

**Where this project makes you feel it:** `docker run` (S02) builds one of these in milliseconds; `resources: {requests: {cpu: 100m, memory: 128Mi}, limits: {memory: 256Mi}}` (S08) *is* a cgroup; the S19 incident — Spring Boot services CrashLoopBackOff at 256Mi until raised to 400Mi — is the memory cgroup killing PID 1; HPA's "70% CPU" (S18) is read from cgroup accounting; Istio's sidecar (S22) can only intercept traffic because it *shares the pod's network namespace*.

## 💡 Rung 2 — The One Idea

> **A container is just a normal Linux process wearing blinders (namespaces: what it can SEE) and a straitjacket (cgroups: what it can USE) — there is no "container" object in the kernel.**

## ⚙️ Rung 3 — The Machinery

```
                    ordinary process (your app, PID 1234 on the host)
                          │
   NAMESPACES (view) ─────┼───── CGROUPS (budget)
   pid:   sees itself as PID 1     cpu:    cpu.max     "50ms per 100ms" → throttling
   net:   own eth0/routes/ports    memory: memory.max  exceed → OOM-kill (exit 137)
   mnt:   own / (the image FS)     (+ io, pids ...)
   uts:   own hostname
   ipc, user, time, cgroup NSs
                          │
                 + OverlayFS root (Climb 9) + dropped capabilities (Climb 3)
                 = everything `docker run` / kubelet actually assembles
```

- **Namespaces are per-resource views.** Every process has them (`ls -l /proc/<pid>/ns/`); "in a container" = "in *different* namespaces than the host." A **pod** = several containers deliberately **sharing** net (and optionally more) namespaces — that's why the Istio sidecar sees the app's traffic on `localhost` and why S08 says "one main container per pod, sidecars share net+storage."
- **cgroups are hierarchical budgets** mounted at `/sys/fs/cgroup` (files again!). K8s translation: `requests` → scheduler math + `cpu.weight` (soft priority); `limits.cpu` → `cpu.max` (hard throttle — app slows down); `limits.memory` → `memory.max` (hard wall — **the OOM killer SIGKILLs**, exit 137, `OOMKilled: true`). CPU over limit = slow; memory over limit = dead. That asymmetry explains half of production debugging.
- **HPA closes the loop (S18):** cgroup usage ÷ *request* = the % HPA compares to its 70% target.

> **✅ Check yourself:** S19 set Spring Boot services to 256Mi limits and they crash-looped; CPU was later cut to 100m and they merely ran "2% used". Explain both behaviors from the cpu-throttles-vs-memory-kills asymmetry.

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| namespace (pid/net/mnt/uts…) | per-process view of one resource | what `docker run` creates; what a pod shares |
| cgroup | kernel resource budget (files under /sys/fs/cgroup) | `resources.requests/limits` (S08/18/19) |
| `memory.max` | the OOM wall | 256Mi→CrashLoop incident (S19) |
| `cpu.max` | quota per period → throttling | why CPU limits slow, not kill |
| OOM killer | kernel's SIGKILL on memory breach | `OOMKilled`, exit 137 |
| requests vs limits | scheduler reservation vs hard ceiling | S08 table: 100m/128Mi vs 200m/256Mi |
| pause container | the process that *holds* a pod's shared namespaces | why pod IP survives app-container restarts |
| sidecar | second container in the same net namespace | Envoy (S22), log agents |

## 🔬 Rung 5 — The Trace: `docker run -d --memory=256m retail-catalog`

1. Docker asks the kernel: new pid+net+mnt+uts+ipc namespaces (`clone()` with NS flags).
2. Creates cgroup `…/docker-<id>.scope`, writes `268435456` into its `memory.max`.
3. Mounts the image's OverlayFS as the process's `/` (Climb 9), sets uid/caps (Climb 3).
4. Execs the catalog binary → it wakes up as PID 1 in an empty world with its own eth0.
5. It allocates beyond 256Mi → kernel can't reclaim → OOM killer SIGKILLs PID 1 → exit 137 → restart policy loops it. On K8s the same story prints `CrashLoopBackOff` + `OOMKilled: true` — the S19 incident, mechanically.

## ⚖️ Rung 6 — The Contrast

- **Containers vs VMs:** VM = virtual *hardware* + guest kernel (strong isolation, heavy); container = shared kernel + namespaced view (millisecond start, image = tarball of files). The course's whole premise — 10 services on one box (S04) — is only sane with containers.
- **When NOT containers:** kernel-version-specific workloads, hostile multi-tenancy (share a kernel = share kernel bugs) → VMs or microVMs.

## 🧪 Rung 7 — Hands-on

**Lab 1 — build a "container" with zero Docker (namespaces by hand):**
> **My prediction:** inside `unshare --pid --fork --mount-proc --uts` I'll be PID 1, see almost no processes, and a hostname change won't leak to the host — because I'm in new pid+uts namespaces, not a new machine.

```bash
hostname                                   # your real hostname
sudo unshare --pid --fork --mount-proc --uts bash
  # now INSIDE your hand-made "container":
  echo $$                                  # 1  ← you are PID 1 (Climb 4 payoff!)
  ps aux | head                            # just bash + ps — the blinders work
  hostname retail-pod-0 && hostname        # changed...
  exit
hostname                                   # ...but NOT here. Isolation held.
# Compare namespace ids: yours vs PID 1's (different files = different worlds)
ls -l /proc/self/ns/pid /proc/1/ns/pid
```
**Verify:** `$$ = 1` and the private hostname are the entire "container" illusion, produced by two syscall flags. Docker adds net+mnt namespaces, cgroups, and an image — but you've now seen the core with your own eyes.

**Lab 2 — reproduce the S19 OOM incident and CPU throttling (137 vs slow):**
> **My prediction:** a 100Mi-limited container that keeps allocating gets SIGKILLed (exit 137, OOMKilled true); a CPU-capped container never dies — it just takes proportionally longer — because memory is a wall and CPU is a valve.

```bash
docker run -d --name oomer --memory=100m alpine sh -c 'tail /dev/zero'   # allocates forever
sleep 3; docker inspect -f 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' oomer
docker rm oomer                                    # exit=137 oom=true — the S19 crash-loop cause

docker run --rm --cpus=0.2 alpine sh -c 'time sh -c "i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done"'
docker run --rm            alpine sh -c 'time sh -c "i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done"'
```
**Verify:** ~137/oom=true for memory; the 0.2-CPU run is ~5× slower but exits 0. Now the K8s rule writes itself: undersize memory → death (raise to 400Mi like S19); undersize CPU → latency (and HPA at 70% of *request* scales you out, S18).

## 🏔 Capstone

> **One sentence:** a container is a process in private namespaces (view) under a cgroup (budget) — so pods are shared namespaces, limits are cgroup files, OOMKilled is the memory wall, throttling is the CPU valve, and none of it is magic.

📚 **Go deeper:** [../../Linux/13-namespaces.md](../../Linux/13-namespaces.md), [../../Linux/14-cgroups.md](../../Linux/14-cgroups.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 8</b> (say it aloud first, then open)</summary>

**Q:** S19 set Spring Boot to 256Mi limits and it crash-looped; CPU cut to 100m merely ran "2% used." Explain both from the throttle-vs-kill asymmetry.

**A:** Memory and CPU cgroup limits fail in **opposite** ways:
- **Memory is a hard wall.** When the process allocates past `memory.max` (256Mi) and the kernel can't reclaim enough, the **OOM killer SIGKILLs PID 1** (exit 137). The JVM needs ≥~350Mi just to boot, so at 256Mi it dies during startup, over and over → CrashLoopBackOff. The only fix is *more memory* (400Mi) — you can't "run slower to fit."
- **CPU is a throttle (valve), not a wall.** When the process wants more than `cpu.max` (100m = 0.1 core), the kernel just **schedules it less** — it runs slower but is never killed. At 100m the app still boots fine; "2% used" means it isn't even trying to use its small quota under light load.

One line: **undersize memory → death; undersize CPU → latency.** That asymmetry is why raising memory fixed the crash while cutting CPU was safe cost-saving — and why HPA (%-of-request) scales you out on CPU pressure rather than letting pods die.

</details>

---
---

# CLIMB 9 — Storage, Mounts & OverlayFS

## 🔥 Rung 1 — The Pain

Three separate storage problems hit every containerized system: (1) shipping the *same* filesystem to every environment (the image), (2) letting a running container write *without* mutating that shared image, (3) keeping data that must *outlive* the container. Solve them wrong and you get 10 GB images, "it changed after restart" mysteries, and databases that lose data on reschedule.

**Where this project makes you feel it:** layer caching makes your second `docker build` seconds instead of minutes (S03), and buildx cache reuse (S05) is the same mechanism; `emptyDir` scratch space for the read-only-rootfs pods (S08); the MySQL StatefulSet needs an EBS-backed PersistentVolume with `WaitForFirstConsumer` (S10 — volumes are AZ-pinned!); Secrets-Manager values *materialize as a mounted volume* at `/mnt/secrets-store` (S09/14).

## 💡 Rung 2 — The One Idea

> **Container storage is three stacked answers: read-only image layers (OverlayFS) + one throwaway writable layer per container + explicit mounts for anything that must survive — and "where does this file actually live?" is always one of those three.**

## ⚙️ Rung 3 — The Machinery

```
what the container sees at /        ┌───────────────────────────────┐
                                    │  merged view (OverlayFS)      │
                                    ├───────────────────────────────┤
  writable, per-container, DIES ──▶ │ upper layer (container layer) │  copy-on-write happens here
  with the container                ├───────────────────────────────┤
  read-only, SHARED by every ─────▶ │ layer: COPY app /app          │  ← one per Dockerfile step
  container from this image         │ layer: RUN apt-get install    │     (this is the build cache!)
                                    │ layer: FROM ubuntu (base)     │
                                    └───────────────────────────────┘
  + MOUNTS punched through the view: -v volumes, K8s emptyDir / PV(EBS) / configMap / secret / CSI
```

- **Copy-on-write:** modify a file from a lower layer → it's *copied up* to the writable layer first; the image layer never changes. Delete the container → the upper layer (all its writes) evaporates. That's why "I installed curl in the running container and it vanished."
- **Layers = cache units:** an unchanged Dockerfile step reuses its layer. Order matters — `COPY package.json` + `npm install` *before* `COPY src/` is why S03's images rebuild fast when only code changes.
- **Mounts bypass Overlay entirely:** a volume (`-v`, PV, emptyDir, secret) is a different filesystem grafted at a path (Climb 2). Writes there are real and survive per that filesystem's rules. `emptyDir` = node-local dir with pod lifetime ( `medium: Memory` = tmpfs = RAM). EBS PV = a network block device that exists in **one AZ** — the reason S10 teaches `WaitForFirstConsumer` (bind the volume only where the pod actually schedules).
- **The stateless conclusion the course draws (S14):** don't fight this for databases — move state to RDS/DynamoDB/ElastiCache and let containers be disposable.

> **✅ Check yourself:** three files in a running catalog pod: `/app/main` (binary), `/tmp/scratch.dat`, `/mnt/secrets-store/password`. For each: which storage answer is serving it, and what happens to it when the pod is deleted?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| image layer | read-only tarball of one build step | `docker history`, build cache (S03/05) |
| container (upper) layer | per-container scratch, copy-on-write | why in-container edits vanish |
| OverlayFS | the union filesystem merging them | `mount \| grep overlay` on any docker host |
| volume / bind mount | external FS grafted into the view | `-v` (S02), PV/PVC (S10) |
| `emptyDir` | pod-lifetime node dir (or tmpfs) | scratch for read-only-rootfs pods (S08) |
| PV / PVC / StorageClass | cluster volume, claim, provisioner | EBS CSI gp3 (S10) |
| `WaitForFirstConsumer` | delay volume creation until pod placed | the AZ-pinning fix (S10) |
| CSI driver | plugin that mounts external systems | EBS (S10), Secrets Store (S09/14) |

## 🔬 Rung 5 — The Trace: MySQL writes a row (S10 stack, top to bottom)

1. `INSERT` → mysqld writes to `/var/lib/mysql/...` inside the container.
2. That path is a **mount**: the PVC-bound EBS PersistentVolume — OverlayFS never sees the write.
3. Kernel filesystem (ext4) on the EBS block device persists it; the device lives in us-east-1a.
4. Pod dies, StatefulSet recreates `catalog-mysql-0` → PVC re-attaches the *same* EBS volume (scheduler constrained to 1a) → row still there.
5. Had mysqld written anywhere *outside* the mount, step 4 would resurrect a blank database — the entire reason PVs exist.

## ⚖️ Rung 6 — The Contrast

- **OverlayFS layers vs full-copy images:** without layers, every image is a full OS copy (GBs, no cache); with them, 10 services share one base (S04's stack fits on a laptop).
- **emptyDir vs PV:** pod-lifetime scratch vs infrastructure-lifetime data. **PV vs managed DB (S14):** PV keeps state *in* the cluster (you patch/backup); RDS moves it out — the course's final answer for production.

## 🧪 Rung 7 — Hands-on

**Lab 1 — watch copy-on-write and the vanishing write:**
> **My prediction:** a file created in a running container is gone after `rm`+`run` of the same image, but a file in a mounted volume survives — because writes land in the disposable upper layer unless a mount catches them.

```bash
docker run -d --name w alpine sleep 999
docker exec w sh -c 'echo scratch > /data.txt && cat /data.txt'
docker rm -f w
docker run --rm alpine cat /data.txt 2>&1 | head -1        # No such file — upper layer died

v=$(mktemp -d)
docker run --rm -v "$v":/data alpine sh -c 'echo durable > /data/data.txt'
docker run --rm -v "$v":/data alpine cat /data/data.txt    # durable — the mount survived
rm -rf "$v"
```
**Verify:** same path, opposite fates — the mount boundary is the persistence boundary. Map it: `/data.txt` ≙ container FS, the volume ≙ PV/EBS.

**Lab 2 — see the layers and the build cache do their job (S03's speed secret):**
> **My prediction:** rebuilding after touching only the "app" file reuses the expensive early layer (cache hit) and reruns only the later COPY — because each Dockerfile step is a cached layer keyed on its inputs.

```bash
cd $(mktemp -d)
printf 'FROM alpine\nRUN sleep 5 && echo built-deps > /deps.txt\nCOPY app.txt /app.txt\n' > Dockerfile
echo v1 > app.txt
time docker build -t layerdemo .          # ~5s+ (RUN executes)
echo v2 > app.txt
time docker build -t layerdemo .          # ~instant for RUN — "CACHED" — only COPY reran
docker history layerdemo | head -5        # one line per layer, sizes visible
docker rmi layerdemo >/dev/null
```
**Verify:** the second build printed `CACHED` for the sleep layer and finished in ~1s. Now S03's ordering rule ("copy dependency manifests before source") and S05's buildx cache flags are *derivable*, not memorized.

## 🏔 Capstone

> **One sentence:** images are shared read-only layers, each container adds one disposable writable layer, and anything that must survive goes through an explicit mount (emptyDir/PV/CSI) — three answers that locate every file in the project.

📚 **Go deeper:** [../../Linux/15-storage-mounts.md](../../Linux/15-storage-mounts.md), [../../Linux/04-file-operations.md](../../Linux/04-file-operations.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 9</b> (say it aloud first, then open)</summary>

**Q:** Three files in a running catalog pod — `/app/main` (binary), `/tmp/scratch.dat`, `/mnt/secrets-store/password`. Which storage answer serves each, and what happens on pod delete?

**A:**
- **`/app/main`** → a **read-only image layer** (OverlayFS lower layer, baked in at build time). On delete: nothing is lost — it's immutable; a new pod gets an identical fresh copy. (Any runtime edit to it would go to the disposable upper layer and vanish, but the image layer never changes.)
- **`/tmp/scratch.dat`** → the container's **writable upper layer** (or an emptyDir if `/tmp` is mounted). On delete: **destroyed** — pod-lifetime scratch, gone.
- **`/mnt/secrets-store/password`** → an **explicit CSI mount**. On delete: the file disappears with the pod, but the **value survives in AWS Secrets Manager** (its source of truth), and the synced K8s Secret is garbage-collected on last unmount — nothing persistent is lost.

The unifying move: locate every file as one of three answers — read-only layer (regenerated), disposable upper layer (lost), or explicit mount (survives per that backend). That's how you predict what a pod delete does to any path.

</details>

---
---

# CLIMB 10 — Package Management & the CLI Toolchain

## 🔥 Rung 1 — The Pain

Software has dependencies of dependencies; installing by hand from tarballs breaks and can't be reproduced. This project needs a precise toolbox — `docker`, `kubectl`, `helm`, `terraform`, `aws`, `argocd`, `istioctl`, `jq` — and its *images* need reproducible package installs (`RUN apt-get install ...` in every Dockerfile, S03).

## 💡 Rung 2 — The One Idea

> **A package manager is a dependency-resolving installer working from an index of repositories — so "install X" is: update the index, resolve the graph, fetch signed packages, place files, record them for clean removal.**

## ⚙️ Rung 3 — The Machinery

- **Two layers:** `apt` (Debian/Ubuntu: resolver, repos, index) over `dpkg` (the actual file-placer/DB). RHEL-family mirrors it: `dnf/yum` over `rpm`.
- **The index is local and stale by default** → `apt-get update` first (refresh index), *then* `install`. In Dockerfiles they're chained in ONE `RUN` (`apt-get update && apt-get install -y --no-install-recommends curl`) so the cached layer (Climb 9!) never holds a stale index alone.
- **Not everything is apt:** vendor tools ship as direct binaries (kubectl, argocd — `curl -LO` + `install`), vendor repos (terraform, docker add their own apt repo + GPG key), or install scripts (helm). Same trust question every time: *whose* repository, *whose* signature?
- **Where files land:** `dpkg -L <pkg>` lists them; hand-installed binaries go to `/usr/local/bin` (earlier in PATH than `/usr/bin` — Climb 1 explains why that wins).

> **✅ Check yourself:** why do Dockerfiles chain `update && install` in one RUN, and why add `rm -rf /var/lib/apt/lists/*` at the end? (Both answers are Climb 9 answers.)

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Project use |
|---|---|---|
| repository | HTTP server of packages + signed index | Ubuntu archive; HashiCorp/Docker apt repos |
| `apt-get update` vs `install` | refresh index vs act on it | Dockerfile RUN chains (S03) |
| `--no-install-recommends` | skip optional deps → smaller images | image-slimming (S03) |
| `dpkg -L` / `apt-cache policy` | list a pkg's files / show versions+origin | "where did this binary come from?" |
| GPG key / signed index | authenticity of the repo | the `curl ... \| gpg --dearmor` lines in install docs |
| `/usr/local/bin` | conventional home for hand-installed binaries | kubectl, argocd, istioctl |
| version pinning | `pkg=1.2.3` exact installs | reproducible images & nodes |

## 🔬 Rung 5 — The Trace: `RUN apt-get update && apt-get install -y curl` during `docker build`

1. Build starts the step in a fresh layer atop the base image.
2. `update` downloads package indexes from the repos listed in `/etc/apt/sources.list*` into `/var/lib/apt/lists/`.
3. `install curl` resolves the dependency graph against that index, downloads `.deb`s, verifies signatures.
4. `dpkg` unpacks files into place and records them in its database.
5. Layer is committed — indexes and all, unless you `rm -rf /var/lib/apt/lists/*` in the *same* RUN (smaller layer, and it can't go stale because installs happened already).

## ⚖️ Rung 6 — The Contrast

- **Package manager vs `curl | bash`:** apt gives signatures, dependency resolution, clean uninstall, upgrades; the pipe gives convenience and vendor-freshness. This project uses both deliberately — OS deps via apt, fast-moving CLIs via vendor binaries — but *knowing which trust model you're in* is the skill.
- **Pinned vs latest:** demos ride latest; production images pin (`FROM ubuntu:22.04`, `pkg=ver`) so builds are reproducible next year.

## 🧪 Rung 7 — Hands-on

**Lab 1 — toolchain audit: what's installed, from where, and which one wins PATH:**
> **My prediction:** `command -v` finds each tool, `apt-cache policy`/`dpkg -S` reveals which came from apt vs hand-install, and anything in `/usr/local/bin` shadows an apt twin — because PATH order decides.

```bash
for t in docker kubectl helm terraform aws jq git; do
  printf '%-10s' "$t"; command -v "$t" >/dev/null && echo "$(command -v $t)  ($($t --version 2>/dev/null | head -1 | cut -c1-40))" || echo "MISSING"
done
dpkg -S "$(command -v jq)" 2>/dev/null || echo "jq not from apt (hand-installed or missing)"
apt-cache policy docker.io docker-ce 2>/dev/null | grep -A2 -E '^docker'   # which docker lineage?
```
**Verify:** every MISSING is your literal to-do before S02; the `dpkg -S` result tells you who owns each binary — the answer to future "why is my terraform old?" (two installs, PATH picked one).

**Lab 2 — the Dockerfile install pattern, benchmarked (ties Climb 9's cache to apt):**
> **My prediction:** splitting `update` and `install` into two RUNs works today but caches a stale index layer; the combined RUN with list-cleanup produces a smaller image — because layers are cached and committed per step.

```bash
cd $(mktemp -d)
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
EOF
docker build -t apt-good . && docker image ls apt-good --format 'good: {{.Size}}'
cat > Dockerfile <<'EOF'
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y curl
EOF
docker build -t apt-naive . && docker image ls apt-naive --format 'naive: {{.Size}}'
docker rmi apt-good apt-naive >/dev/null
```
**Verify:** the "good" image is noticeably smaller (no cached indexes, no recommends), and you can now *explain* every apt line in the retail-store Dockerfiles instead of copying them.

## 🏔 Capstone

> **One sentence:** package managers turn "install X" into resolve-verify-place-record against a repo index — and this project's Dockerfile apt idioms are just that mechanism arranged to respect layer caching.

📚 **Go deeper:** [../../Linux/22-package-management.md](../../Linux/22-package-management.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 10</b> (say it aloud first, then open)</summary>

**Q:** Why chain `update && install` in one RUN, and why add `rm -rf /var/lib/apt/lists/*` at the end? (Both are Climb 9 answers.)

**A:** Both are **layer-caching** consequences (Climb 9):
- **One RUN for `update && install`:** each Dockerfile instruction is a cached layer keyed on its inputs. If `apt-get update` were its own layer, a later build could reuse a **stale cached index** while running a fresh `install` against it → the classic "package not found / old version" bug, because the install resolves against a frozen index. Chaining them means the refresh and the install always happen together, so the install always sees a just-fetched index.
- **`rm -rf /var/lib/apt/lists/*` in the *same* RUN:** the downloaded indexes (tens of MB) would otherwise be **committed into that layer forever**, bloating the image, and they're useless after install. Deleting them *before the layer is committed* (same RUN) keeps them out of the final image. Doing it in a *separate* RUN wouldn't help — the earlier layer already captured them.

Both are just arranging the apt mechanism to respect how layers are cached and committed.

</details>

---
---

# 🏔 FINAL CAPSTONE — Compress the Whole File

Say each climb in one sentence, out loud, no notes. If one stalls, that climb's 🧪 labs are your next session.

| # | Climb | The one sentence you must own |
|---|---|---|
| 1 | Shell & env | Processes inherit a frozen copy of exported vars at birth — all config injection is deciding that copy. |
| 2 | Filesystem | One tree; config is dotfiles, kernel state is `/proc`, secrets/volumes arrive by mounting. |
| 3 | Permissions | One rwx triplet is chosen per access (uid→gid→other); non-root containers are arranged triplets. |
| 4 | Processes | Stop = SIGTERM→grace→SIGKILL at your app as PID 1; 137/143 and CrashLoopBackOff are its dialect. |
| 5 | Scripting | Replayable history + variables + exit-code gates (`&&`, `set -e`) = every course script. |
| 6 | Text | grep selects, sed edits, awk extracts, jq walks JSON — the CI handoff is one anchored sed. |
| 7 | Streams | fd 0/1/2 + redirection + pipes; container logs are captured fd 1/2. |
| 8 | Namespaces+cgroups | A container is a process with a private view and a budget; pods share views, limits are budget files. |
| 9 | Storage | Read-only layers + disposable upper layer + explicit mounts — three answers locate every file. |
| 10 | Packages | Resolve-verify-place-record from a repo index; Dockerfile apt idioms respect layer cache. |

**Suggested order against the course:** Climbs 1–2 before S02 (Docker commands) · 3–4 before S03–04 (Dockerfiles/Compose) · 5–7 before S06 (Terraform scripts) and again at S21 (CI) · 8–9 before S08 (K8s foundation) and S18–19 (autoscaling/sizing) · 10 anytime before S02.

**The recurring primitives you'll now recognize everywhere:** frozen env copies (Compose→K8s→CI), signals (docker stop→rolling updates), cgroup walls (OOM incident→HPA), mounts (secrets→PVs), and exit codes (scripts→probes→pipelines). When S22's Istio injects a sidecar, you'll see it instantly: *same net namespace, second process* — old primitives, new costume.

---

*Companion file: [00B — Networking Foundations](00B-networking-foundations-learning-ladder.md) · Full deep-dive ladders: [../../Linux/](../../Linux/00-README.md) · Course index: [00-INDEX.md](00-INDEX.md)*
