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

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios (Project-Grounded)

> **How to use this lab:** These are hands-on, [sadservers.com](https://sadservers.com)-style challenges — one per broken box, with a story, a task, and an objective **Verify** command that proves you fixed it. They are organized by the ten climbs above; each climb has **6 scenarios of rising difficulty** (🟢 Easy → 🟡 Medium → 🟠 Hard → 🔴 Expert), and every scenario is tied to a real artifact of the Retail-Store DevOps project (see the **Project link** line).
>
> **Run them on a disposable Ubuntu/Debian VM** (Multipass, Vagrant, or a throwaway cloud instance) — many setups use `sudo` and deliberately break things. Everything is scoped to `/opt/lab-*`, `/tmp/lab-*`, `labuser*` accounts, and ports `8000–8999` so nothing real is touched. Where the project uses an AWS/EKS object you can't run locally (an EBS volume, a Security Group, an ALB, Istio mTLS), the setup builds a **faithful local analogue** (a loop device, an `iptables` chain, `nginx`, `openssl s_server`) and the answer maps it back to the real thing.
>
> **The drill:** run the **Setup**, read the **Situation**, do the **Task**, and confirm with **Verify** — *before* peeking at the 🔑 solutions at the very bottom of this file. Answers include cleanup steps for anything that changes global state.

### Climb 1 — Shell, Environment Variables & PATH

> **Ground rules for every scenario in this file:** use a **disposable Ubuntu/Debian VM** (Multipass, EC2 t3.micro, or a throwaway VirtualBox box). Every lab confines itself to `/opt/lab-*`, `/tmp/lab-*`, uids `10001+`/`labuser*`. Run the **Setup** block top-to-bottom (it *ends by showing you the broken symptom*), then work the task **without looking at the answers file**. The **Verify** block is your objective pass/fail gate.

#### 🟢 Scenario 1.1 — "Austin: the variable that vanished between two shells" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-austin
sudo tee /opt/lab-austin/.env >/dev/null <<'EOF'
# dev credentials for the retail-store stack
DB_PASSWORD=retail-dev-101
EOF
sudo tee /opt/lab-austin/launch-stack.sh >/dev/null <<'EOF'
#!/bin/bash
# stand-in for `docker compose up`: interpolates ${DB_PASSWORD} exactly like Compose does
if [ -z "$DB_PASSWORD" ]; then
  echo "catalog-db  | ERROR 1045: empty password — refusing to start" >&2
  exit 1
fi
echo "catalog-db  | started with password '${DB_PASSWORD}'"
EOF
sudo chmod +x /opt/lab-austin/launch-stack.sh
# reproduce the incident exactly as the previous engineer hit it:
cd /opt/lab-austin
source ./.env
echo "my shell sees: [$DB_PASSWORD]"     # ← prints the password fine...
./launch-stack.sh                         # ← ...and this still fails
```

**Situation:** A teammate "loaded the credentials" with `source ./.env` and can `echo $DB_PASSWORD` all day long — the value is right there in the terminal. Yet the stack launcher (a child process, just like `docker compose` is) reports an **empty** password and refuses to start. The ticket says: *"env vars are broken on this VM."*

**Your task:** Make `./launch-stack.sh` succeed **without editing either file**. Then explain, in one sentence using the words *shell variable*, *environment variable*, and *fork*, why `echo` saw the value but the child did not.

**Project link:** This is S04's `RETAIL_CATALOG_PERSISTENCE_PASSWORD: ${DB_PASSWORD}` trap: forget the *export* and all four database containers crash-loop with empty-password errors, even though your shell happily echoes the variable.

**Verify:**

```bash
cd /opt/lab-austin && ./launch-stack.sh
# expected: catalog-db  | started with password 'retail-dev-101'   (exit code 0)
bash -c 'echo "a child shell sees: [$DB_PASSWORD]"'
# expected: a child shell sees: [retail-dev-101]   (not empty brackets)
```

---

#### 🟢 Scenario 1.2 — "Denver: the impostor first on the PATH" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-denver/stale-bin /opt/lab-denver/new-bin
sudo tee /opt/lab-denver/stale-bin/retailctl >/dev/null <<'EOF'
#!/bin/sh
echo "retailctl v1.2.0"
EOF
sudo tee /opt/lab-denver/new-bin/retailctl >/dev/null <<'EOF'
#!/bin/sh
echo "retailctl v2.0.0"
EOF
sudo chmod +x /opt/lab-denver/stale-bin/retailctl /opt/lab-denver/new-bin/retailctl
# months ago someone hand-installed v1.2.0; yesterday "the upgrade" put v2.0.0 in a second dir:
export PATH="/opt/lab-denver/stale-bin:/opt/lab-denver/new-bin:$PATH"
retailctl        # ← you upgraded... but it still says v1.2.0
```

**Situation:** The release notes say you're on `retailctl v2.0.0`. The binary for v2.0.0 is installed, on disk, executable, and even on your `PATH`. But every invocation answers `v1.2.0`. Nothing was "cached by the tool" — the tool has no cache.

**Your task:** Using `type -a retailctl` (not `which`) first, explain exactly *why* v1.2.0 answers. Then fix it so plain `retailctl` runs v2.0.0 — and afterwards explain what `hash -r` is for by observing what bash does immediately after your fix.

**Project link:** This bites in S06/S07 the day you hand-download a newer `terraform` or `kubectl` next to a package-manager copy: two binaries, one PATH, and the *first match walking left-to-right* wins — `type -a` lists all of them in verdict order.

**Verify:**

```bash
retailctl
# expected: retailctl v2.0.0
type -a retailctl | head -1
# expected: retailctl is /opt/lab-denver/new-bin/retailctl
```

---

#### 🟡 Scenario 1.3 — "Portland: the process that was born with the old password" (Medium)

**Setup:**

```bash
sudo mkdir -p /opt/lab-portland
sudo tee /opt/lab-portland/.env >/dev/null <<'EOF'
DB_PASSWORD=rotated-NEW-secret
EOF
sudo tee /opt/lab-portland/catalog-db.sh >/dev/null <<'EOF'
#!/bin/bash
# stand-in for a container's PID 1: forever reports the password it was BORN with
while true; do
  echo "$(date +%T) auth attempt with password: ${DB_PASSWORD:-<empty>}" >> /tmp/lab-portland-auth.log
  sleep 2
done
EOF
sudo chmod +x /opt/lab-portland/catalog-db.sh
sudo tee /opt/lab-portland/stackctl >/dev/null <<'EOF'
#!/bin/bash
# mini docker-compose. Faithful detail: env is FROZEN into the "container object"
# at CREATE time; stop/start reuse that frozen copy; only recreate re-reads .env
case "$1" in
  create)   set -a; . /opt/lab-portland/.env; set +a
            env | grep '^DB_PASSWORD=' > /tmp/lab-portland.frozen-env
            "$0" start;;
  start)    [ -f /tmp/lab-portland.frozen-env ] || { echo "no container — run: stackctl create"; exit 1; }
            set -a; . /tmp/lab-portland.frozen-env; set +a
            nohup /opt/lab-portland/catalog-db.sh >/dev/null 2>&1 &
            echo $! > /tmp/lab-portland.pid
            echo "started pid $(cat /tmp/lab-portland.pid)";;
  stop)     kill "$(cat /tmp/lab-portland.pid 2>/dev/null)" 2>/dev/null; echo "stopped";;
  recreate) "$0" stop; rm -f /tmp/lab-portland.frozen-env; "$0" create;;
  *) echo "usage: stackctl create|stop|start|recreate"; exit 2;;
esac
EOF
sudo chmod +x /opt/lab-portland/stackctl
# history: the container was CREATED before security rotated the password...
echo 'DB_PASSWORD=old-LEAKED-secret' > /tmp/lab-portland.frozen-env
/opt/lab-portland/stackctl start
# ...then ops "applied" the rotation the obvious (wrong) way:
/opt/lab-portland/stackctl stop
/opt/lab-portland/stackctl start
sleep 3
tail -2 /tmp/lab-portland-auth.log     # ← STILL authenticating with old-LEAKED-secret
```

**Situation:** Security rotated the leaked DB password. The new value is verifiably in `/opt/lab-portland/.env`. Ops restarted the service (`stackctl stop && stackctl start`) — twice — yet `/tmp/lab-portland-auth.log` shows every auth attempt still using `old-LEAKED-secret`. The incident channel is asking how a password that exists in *no file with the old value* keeps being used.

**Your task:** (1) Without restarting anything, produce forensic proof of where the old password lives right now — read the running process's **frozen environment copy** out of `/proc/<pid>/environ`. (2) Apply the one `stackctl` verb that actually picks up the rotation, and explain why `stop`/`start` mechanically *cannot*.

**Project link:** This is S04's core lesson verbatim: `docker compose stop ui && docker compose start ui` keeps the old `RETAIL_UI_THEME`, because env is copied into the container at **creation**; only `docker compose up -d --force-recreate` re-reads the YAML and re-injects env.

**Verify:**

```bash
tr '\0' '\n' < /proc/$(cat /tmp/lab-portland.pid)/environ | grep '^DB_PASSWORD='
# expected: DB_PASSWORD=rotated-NEW-secret
sleep 3; tail -1 /tmp/lab-portland-auth.log
# expected: <time> auth attempt with password: rotated-NEW-secret
```

---

#### 🟡 Scenario 1.4 — "Seattle: the tag that never crossed the step boundary" (Medium)

**Setup:**

```bash
sudo mkdir -p /opt/lab-seattle/steps
sudo tee /opt/lab-seattle/runner.sh >/dev/null <<'EOF'
#!/bin/bash
# mini GitHub Actions runner: every step runs in a FRESH shell — steps are
# SIBLINGS, not parent/child. Between steps the runner re-reads $GITHUB_ENV.
export GITHUB_ENV=/tmp/lab-seattle-github-env
: > "$GITHUB_ENV"
for step in /opt/lab-seattle/steps/*.sh; do
  echo "── running $(basename "$step") ──"
  bash -c "set -a; . '$GITHUB_ENV'; set +a; exec bash '$step'" \
    || { echo "runner: step failed" >&2; exit 1; }
done
echo "runner: workflow succeeded"
EOF
sudo tee /opt/lab-seattle/steps/10-build.sh >/dev/null <<'EOF'
#!/bin/bash
GITHUB_SHA=4f7c2a19b8e0d3c6a5f41e2d9b8c7a6f5e4d3c2b
export TAG="sha-${GITHUB_SHA::7}"        # ← the hand-off that never arrives
echo "built image retail-ui:$TAG"
EOF
sudo tee /opt/lab-seattle/steps/20-deploy.sh >/dev/null <<'EOF'
#!/bin/bash
if [ -z "$TAG" ]; then
  echo "FATAL: TAG is empty — refusing to deploy :latest" >&2
  exit 1
fi
echo "kubectl set image deployment/ui ui=retail-ui:$TAG"
EOF
sudo chmod +x /opt/lab-seattle/runner.sh /opt/lab-seattle/steps/*.sh
/opt/lab-seattle/runner.sh     # ← step 10 prints the tag, step 20 says TAG is empty
```

**Situation:** The build step computes the image tag and even `export`s it — the step's own log proves the value exists (`built image retail-ui:sha-4f7c2a1`). The very next step sees `$TAG` empty and aborts the deploy. "But I exported it!" is already in the ticket.

**Your task:** Fix **only** `10-build.sh` so the tag survives into step 20, using the same mechanism the real GitHub Actions runner uses. Then explain, with the process tree in hand (runner → step-shells), why `export` is *mechanically incapable* of crossing a step boundary.

**Project link:** S21's workflow does exactly this hand-off: `echo "TAG=sha-${GITHUB_SHA::7}" >> $GITHUB_ENV` in the build step is what lets the later `sed -i` tag write-back step see the tag — because steps are sibling processes and `$GITHUB_ENV` is a *file* the runner re-reads between them.

**Verify:**

```bash
/opt/lab-seattle/runner.sh
# expected: last two lines:
#   kubectl set image deployment/ui ui=retail-ui:sha-4f7c2a1
#   runner: workflow succeeded          (exit code 0)
```

---

#### 🟠 Scenario 1.5 — "Boise: it works in my terminal, not in the runner" (Hard)

**Setup:**

```bash
sudo mkdir -p /opt/lab-boise/bin
sudo tee /opt/lab-boise/bin/deployctl >/dev/null <<'EOF'
#!/bin/sh
echo "deployctl ok: deploying retail-store from $(hostname)"
EOF
sudo chmod +x /opt/lab-boise/bin/deployctl
# the "install" a previous engineer did — PATH via .bashrc only:
grep -q 'lab-boise' ~/.bashrc || echo 'export PATH="/opt/lab-boise/bin:$PATH"' >> ~/.bashrc
export PATH="/opt/lab-boise/bin:$PATH"
deployctl                              # ① works in YOUR terminal...
env -i /bin/bash -c 'deployctl'        # ② ..."the CI runner" says: command not found
sudo deployctl                         # ③ ...and sudo can't find it either
```

**Situation:** Three invocations of the *same installed tool* on the *same VM*: your interactive shell runs it fine, the CI runner's clean-environment shell (faithfully reproduced by `env -i /bin/bash -c`) gets `command not found`, and `sudo deployctl` fails too. Three callers, three different `PATH` values, and only one of them contains the tool.

**Your task:** (1) Print the three PATHs side by side — your shell's, the clean-env shell's, and sudo's — and identify where each one comes from (`~/.bashrc`, bash's compiled-in default, `secure_path` in `/etc/sudoers`). (2) Make **all three** invocations work *without changing how any of them is invoked* and without editing sudoers or the runner. There is a single directory that all three PATHs already agree on.

**Project link:** This is the S21 classic — "the workflow can't find `helm`/`terraform` but my laptop can" — and the S19 variant where `sudo ./create-cluster-with-karpenter.sh` can't find a tool your user's PATH has. Interactive `~/.bashrc` exports simply do not exist for non-interactive runners or for sudo's `secure_path`.

**Verify:**

```bash
deployctl
# expected: deployctl ok: deploying retail-store from <hostname>
env -i /bin/bash -c 'deployctl'
# expected: deployctl ok: deploying retail-store from <hostname>
sudo deployctl
# expected: deployctl ok: deploying retail-store from <hostname>   (all three exit 0)
```

---

#### 🔴 Scenario 1.6 — "Tucson: the password the shell ate a piece of" (Expert)

**Setup:**

```bash
sudo mkdir -p /opt/lab-tucson
sudo tee /opt/lab-tucson/.env >/dev/null <<'EOF'
DB_PASSWORD=S3cur3$tore!9
EOF
sudo tee /opt/lab-tucson/mysqld-stub.sh >/dev/null <<'EOF'
#!/bin/bash
# stand-in for MySQL: accepts exactly the password provisioned at the server side
EXPECTED='S3cur3$tore!9'
if [ "$DB_PASSWORD" = "$EXPECTED" ]; then
  echo "catalog-db | ready — password accepted"
else
  echo "catalog-db | ERROR 1045 (28000): Access denied (client sent: [$DB_PASSWORD])" >&2
  exit 1
fi
EOF
sudo tee /opt/lab-tucson/launch.sh >/dev/null <<'EOF'
#!/bin/bash
# the .env loader a previous engineer wrote — looks harmless, eats bytes
eval "export $(cat /opt/lab-tucson/.env)"
exec /opt/lab-tucson/mysqld-stub.sh
EOF
sudo chmod +x /opt/lab-tucson/mysqld-stub.sh /opt/lab-tucson/launch.sh
/opt/lab-tucson/launch.sh
# ← Access denied (client sent: [S3cur3!9]) — five bytes of password just vanished
```

**Situation:** Security issued a strong password: `S3cur3$tore!9`. It is byte-for-byte correct in `.env` (prove it: `cat -A /opt/lab-tucson/.env`). Yet the app is denied — and the error shows it sent `S3cur3!9`. Nothing "truncated the file"; the file is perfect. Somewhere between the file and the process's environment, the shell **re-expanded** the value and `$tore` — an unset variable — silently became nothing.

**Your task:** (1) Explain precisely which line of `launch.sh` performs an *extra round of shell expansion* and what `$tore` became. (2) Rewrite `launch.sh` with a **byte-safe** `.env` loader: no `eval`, no word-splitting, no expansion of the value — every byte in the file arrives in the environment. (3) State how you would write this same literal password in a `docker-compose.yml` `environment:` block so Compose's own interpolation doesn't eat it.

**Project link:** S04's Compose interpolation runs the same risk: `${DB_PASSWORD}` is *deliberate* expansion, but a literal `$` inside a value must be escaped as `$$` or Compose warns and substitutes empty — the exact class of bug that makes "strong passwords break the stack" tickets.

**Verify:**

```bash
/opt/lab-tucson/launch.sh
# expected: catalog-db | ready — password accepted   (exit code 0)
env -i /opt/lab-tucson/launch.sh
# expected: same success from a completely clean environment
```

---

### Climb 2 — Filesystem, Paths & "Everything Is a File"

#### 🟢 Scenario 2.1 — "Omaha: kubectl is answering from the wrong file" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-omaha/bin /opt/lab-omaha/home/.kube
sudo tee /opt/lab-omaha/home/.kube/config >/dev/null <<'EOF'
# the config `aws eks update-kubeconfig` wrote this morning (healthy cluster)
current-context: retail-dev
EOF
cat > /tmp/lab-omaha-stale-kubeconfig <<'EOF'
# scratch config from last week's experiment — that cluster is destroyed
current-context: eksdemo-deleted
EOF
sudo tee /opt/lab-omaha/bin/kctl >/dev/null <<'EOF'
#!/bin/bash
# stub kubectl — implements the REAL config lookup order:
#   1) $KUBECONFIG if set      2) else the conventional dotfile (~/.kube/config)
cfg="${KUBECONFIG:-/opt/lab-omaha/home/.kube/config}"   # ← the stub's "$HOME/.kube/config"
ctx=$(awk '/^current-context:/{print $2}' "$cfg")
echo "answering from: $cfg  (current-context: $ctx)"
if [ "$ctx" = "eksdemo-deleted" ]; then
  echo 'Unable to connect to the server: dial tcp: lookup eksdemo-deleted: no such host' >&2
  exit 1
fi
printf 'NAME                  READY   STATUS\nui-6d5f8b9c7-x2kqp    1/1     Running\n'
EOF
sudo chmod +x /opt/lab-omaha/bin/kctl
export PATH="/opt/lab-omaha/bin:$PATH"
export KUBECONFIG=/tmp/lab-omaha-stale-kubeconfig    # ← forgotten export from last week
kctl get pods    # ← "no such host" — yet this morning's kubeconfig is fine on disk
```

**Situation:** You rebuilt the dev cluster this morning and `update-kubeconfig` wrote a fresh, correct config file. But `kctl get pods` keeps trying to reach a cluster that was destroyed last week. The config file on disk is provably right — so *which file is the tool actually reading, and why?*

**Your task:** (1) Without touching any file, determine which config file `kctl` is answering from and *why the lookup chose it* (env var beats conventional dotfile). (2) Fix your shell so `kctl` reads the healthy config, and state the one command you'd add to your incident-runbook to diagnose this class of bug in three seconds.

**Project link:** S07 exactly: `aws eks update-kubeconfig` writes `~/.kube/config`, but `kubectl` checks `$KUBECONFIG` *first* — one stale `export KUBECONFIG=...` in a terminal (or `.bashrc`) and every kubectl command talks to the wrong cluster. Fixing kubectl is fixing a *file lookup*, not a daemon.

**Verify:**

```bash
kctl get pods
# expected: answering from: /opt/lab-omaha/home/.kube/config  (current-context: retail-dev)
#           ui-6d5f8b9c7-x2kqp    1/1     Running       (exit code 0)
echo "KUBECONFIG is now: [${KUBECONFIG:-<unset>}]"
# expected: KUBECONFIG is now: [<unset>]
```

---

#### 🟢 Scenario 2.2 — "Fresno: the log file nobody can find" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-fresno /tmp/lab-fresno/.cache/run
sudo tee /opt/lab-fresno/orders-svc.sh >/dev/null <<'EOF'
#!/bin/bash
# writes its log to a RELATIVE path — it lands wherever the process was STARTED from
while true; do
  echo "$(date +%T) order processed id=$RANDOM" >> orders.log
  sleep 2
done
EOF
sudo chmod +x /opt/lab-fresno/orders-svc.sh
cd /tmp/lab-fresno/.cache/run          # ← the odd cwd it was launched from
nohup /opt/lab-fresno/orders-svc.sh >/dev/null 2>&1 &
echo $! > /tmp/lab-fresno.pid
cd - >/dev/null
ls /opt/lab-fresno/                    # ← no orders.log here...
ls /var/log/orders.log 2>&1            # ← ...and not here either
```

**Situation:** The orders service is up (the pid file proves it) and a teammate swears "it logs to `orders.log`". But `orders.log` is not next to the script, not in `/var/log`, and a `find /` is off the table on this box. The service must not be restarted. You need the live log file *now*.

**Your task:** Using **only** the `/proc/<pid>/` window (`cwd`, `fd`, and `environ` if you want the launch context) — no `find`, no guessing — recover the log's exact absolute path and show a growing tail. Then explain the relative-path trap: what single fact about the *process* (not the script) decided where `orders.log` landed?

**Project link:** Climb 2's `/proc` machinery doing real work: the same `/proc/<pid>/cwd` + `/proc/<pid>/fd` forensics that answer "where is this container actually writing?" (S02) and "what env was this pod's PID 1 born with?" — kernel state exposed as files you can `ls -l`.

**Verify:**

```bash
pid=$(cat /tmp/lab-fresno.pid)
readlink /proc/$pid/cwd
# expected: /tmp/lab-fresno/.cache/run
tail -2 /tmp/lab-fresno/.cache/run/orders.log
# expected: two recent "order processed id=..." lines with advancing timestamps
```

---

#### 🟡 Scenario 2.3 — "Tulsa: COPY says the file is not there, and it is right" (Medium)

> **Requires:** Docker (`sudo apt-get install -y docker.io`, or any VM that already runs Docker).

**Setup:**

```bash
sudo mkdir -p /opt/lab-tulsa/retail-ui/src /opt/lab-tulsa/retail-ui/docker
echo 'console.log("retail ui")' | sudo tee /opt/lab-tulsa/retail-ui/src/app.js >/dev/null
sudo tee /opt/lab-tulsa/retail-ui/docker/Dockerfile >/dev/null <<'EOF'
FROM alpine:3.19
COPY src/ /app/
CMD ["cat", "/app/app.js"]
EOF
cd /opt/lab-tulsa/retail-ui/docker
ls ../src/app.js                       # ← the file is RIGHT THERE...
sudo docker build -t lab-tulsa-ui .    # ← ...and COPY fails: "src": not found
```

**Situation:** The engineer stands in `docker/`, can `ls ../src/app.js` with their own eyes, and Docker still insists `COPY src/ /app/` has nothing to copy. Changing it to `COPY ../src/ /app/` makes it *worse* ("forbidden path outside the build context"). The file exists; Docker says it doesn't. One of them is lying — or they're talking about two different worlds.

**Your task:** (1) Explain what the **build context** actually is (the directory tree the client tars up and ships to the daemon) and why `COPY` paths resolve against *it*, never against your shell's cwd — and why `../` can never escape it. (2) Fix the build **without moving or editing any file**, using the `-f` flag from the repo root. (3) Confirm the built image actually contains `app.js`.

**Project link:** S03's Dockerfile work: `docker build .` passes a context, and every `COPY src/ /app/` in the retail-store images resolves against that context — the single most common "works on my machine, fails in CI" build error, since CI builds from the repo root.

**Verify:**

```bash
sudo docker run --rm lab-tulsa-ui
# expected: console.log("retail ui")
```

---

#### 🟡 Scenario 2.4 — "Reno: is it the mount, or is it the injection?" (Medium)

**Setup:**

```bash
sudo mkdir -p /opt/lab-reno/secrets-store
# the "CSI driver" materializes the secret as a tmpfs-backed FILE (RAM only, like the real one):
sudo mount -t tmpfs -o size=1m lab-reno-tmpfs /opt/lab-reno/secrets-store
echo -n 'catalog-Passw0rd' | sudo tee /opt/lab-reno/secrets-store/db-password >/dev/null
sudo tee /opt/lab-reno/catalog-app.sh >/dev/null <<'EOF'
#!/bin/bash
# stand-in for the catalog pod's PID 1: needs the password IN ITS ENVIRONMENT
while true; do
  if [ -z "$RETAIL_CATALOG_PERSISTENCE_PASSWORD" ]; then
    echo "$(date +%T) FATAL: RETAIL_CATALOG_PERSISTENCE_PASSWORD is not set" >> /tmp/lab-reno-app.log
  else
    echo "$(date +%T) connected to catalog-db" >> /tmp/lab-reno-app.log
  fi
  sleep 2
done
EOF
sudo chmod +x /opt/lab-reno/catalog-app.sh
# the "pod" starts — but one of the two secret hops silently failed:
nohup /opt/lab-reno/catalog-app.sh >/dev/null 2>&1 &
echo $! > /tmp/lab-reno.pid
sleep 3
tail -1 /tmp/lab-reno-app.log          # ← FATAL: password is not set
```

**Situation:** "The app can't find its DB password." In the real project that sentence hides **two** independent hops: (1) the CSI driver *mounts* the secret as a file, (2) the synced Secret is *injected* into the container's env via `secretKeyRef`. Here you have the same two hops in miniature: a tmpfs-mounted secret file, and a process that expects the value in its environment. One hop works. One is broken. Guessing is forbidden.

**Your task:** (1) Localize the fault by reading exactly **two files** — one that proves whether the *mount hop* delivered (`/opt/lab-reno/secrets-store/db-password`, plus `mount | grep lab-reno` to see the graft), one that proves whether the *injection hop* delivered (`/proc/<pid>/environ`). Write down your verdict: which hop is broken? (2) Fix it the way the platform would: recreate the process with its env populated **from the mounted file**, and confirm the log flips to "connected".

**Project link:** This is Climb 2's check-yourself question made into a drill, and the S09/S14 debugging flow verbatim: `kubectl exec <pod> -- cat /mnt/secrets-store/...` (mount hop) versus `kubectl exec <pod> -- tr '\0' '\n' < /proc/1/environ` (injection hop) — two file reads that cut the problem space in half.

**Verify:**

```bash
mount | grep lab-reno-tmpfs >/dev/null && echo "mount hop: OK"
# expected: mount hop: OK
tr '\0' '\n' < /proc/$(cat /tmp/lab-reno.pid)/environ | grep '^RETAIL_CATALOG_PERSISTENCE_PASSWORD='
# expected: RETAIL_CATALOG_PERSISTENCE_PASSWORD=catalog-Passw0rd
sleep 3; tail -1 /tmp/lab-reno-app.log
# expected: <time> connected to catalog-db
```

---

#### 🟠 Scenario 2.5 — "Boulder: no space left on a disk that is 90% empty" (Hard)

**Setup:**

```bash
sudo mkdir -p /opt/lab-boulder/var-lib-docker
sudo dd if=/dev/zero of=/opt/lab-boulder/disk.img bs=1M count=64 status=none
sudo mkfs.ext4 -q -N 128 /opt/lab-boulder/disk.img     # tiny fs with only ~128 inodes
sudo mount -o loop /opt/lab-boulder/disk.img /opt/lab-boulder/var-lib-docker
sudo mkdir -p /opt/lab-boulder/var-lib-docker/overlay2
# an image-layer extractor went wild creating thousands of tiny files:
i=0
while sudo touch "/opt/lab-boulder/var-lib-docker/overlay2/layer-$i" 2>/dev/null; do
  i=$((i+1))
done
echo "layer files created before the disk 'filled': $i"
sudo touch /opt/lab-boulder/var-lib-docker/pull.tmp
# ← "No space left on device" ... and yet:
df -h /opt/lab-boulder/var-lib-docker   # ← ~90% FREE
```

**Situation:** Image pulls onto this "Docker data disk" die with `No space left on device`. Every dashboard and every `df -h` agrees the filesystem is about 90% *empty*. Deleting a big file changes nothing. The disk has plenty of bytes — it has run out of something else.

**Your task:** (1) Produce the one command whose output *objectively proves* what resource is exhausted (bytes are fine; what's at 100%?). (2) Explain what an inode is and why ten thousand empty files can "fill" a mostly-empty disk. (3) Find where the inodes went (hint: `du` counts bytes and will mislead you — count *files*), free them, and prove writes work again — without unmounting or reformatting.

**Project link:** The real-world version is `/var/lib/docker` on a build host or an EKS node: overlay2 layers are *thousands of small files*, and nodes go `DiskPressure`/`no space left` with gigabytes free. `df -i` is the discriminator; `docker system prune` is the production-shaped cleanup.

**Verify:**

```bash
df -i /opt/lab-boulder/var-lib-docker | awk 'NR==2{print "inodes in use:", $5}'
# expected: inodes in use: well below 100% (e.g. 15%)
sudo touch /opt/lab-boulder/var-lib-docker/pull.tmp && echo "WRITE-OK"
# expected: WRITE-OK
```

---

#### 🔴 Scenario 2.6 — "Savannah: the config updated everywhere except where the app looks" (Expert)

**Setup:**

```bash
# 1) the "kubelet" side: a ConfigMap projected volume with the REAL ..data machinery
sudo mkdir -p '/opt/lab-savannah/kubelet/ui-config/..2026_07_20_09_00_00' \
             /opt/lab-savannah/stale-snapshot /opt/lab-savannah/app/config
echo 'theme=purple' | sudo tee '/opt/lab-savannah/kubelet/ui-config/..2026_07_20_09_00_00/ui.properties' >/dev/null
sudo ln -s '..2026_07_20_09_00_00' '/opt/lab-savannah/kubelet/ui-config/..data'
sudo ln -s '..data/ui.properties' /opt/lab-savannah/kubelet/ui-config/ui.properties
# 2) the wiring mistake: months ago someone bind-mounted a debug SNAPSHOT (a copy!)
#    into the app's config path "temporarily" — and forgot it
sudo cp /opt/lab-savannah/kubelet/ui-config/ui.properties /opt/lab-savannah/stale-snapshot/
sudo mount --bind /opt/lab-savannah/stale-snapshot /opt/lab-savannah/app/config
# 3) today: the ConfigMap is edited, and the updater performs kubelet's ATOMIC flip
sudo mkdir '/opt/lab-savannah/kubelet/ui-config/..2026_07_24_14_30_00'
echo 'theme=orange' | sudo tee '/opt/lab-savannah/kubelet/ui-config/..2026_07_24_14_30_00/ui.properties' >/dev/null
sudo ln -s '..2026_07_24_14_30_00' '/opt/lab-savannah/kubelet/ui-config/..data.tmp'
sudo mv -T '/opt/lab-savannah/kubelet/ui-config/..data.tmp' '/opt/lab-savannah/kubelet/ui-config/..data'
# the symptom:
cat /opt/lab-savannah/kubelet/ui-config/ui.properties   # ← theme=orange (updated!)
cat /opt/lab-savannah/app/config/ui.properties          # ← theme=purple (the app's view: frozen)
```

**Situation:** The UI theme ConfigMap was updated to `orange`. The projected volume on the "node" proves the update landed — atomically, mid-read-safe. Ops can `cat` the new value. Monitoring can `cat` the new value. The **app** — which reads `/opt/lab-savannah/app/config/ui.properties` — still serves `purple`, and will serve `purple` forever, through every future update. No file it reads is stale; the *path* it reads is lying.

**Your task:** (1) Explain the `..data` machinery you can see in `ls -la /opt/lab-savannah/kubelet/ui-config/`: why does kubelet update via *new dir → symlink → atomic `rename()`*, and what torn state does this make impossible for a reader mid-update? (2) Find why the app's path is frozen — `findmnt --target /opt/lab-savannah/app/config` is your witness — and say precisely what a bind mount *covers*. (3) Re-wire the app's config path so it tracks the live projected volume (umount the stale cover, bind the real volume dir), and prove a *future* atomic flip propagates.

**Project link:** This is why S08's ConfigMap volumes update live **but `subPath` mounts never do**: a `subPath` bind-mounts the *resolved directory of the moment*, bypassing the `..data` symlink flip — the exact "covered by a mount" freeze you just debugged, shipping in real clusters every day.

**Verify:**

```bash
cat /opt/lab-savannah/app/config/ui.properties
# expected: theme=orange
findmnt -n -o SOURCE --target /opt/lab-savannah/app/config
# expected: a source ending in [/opt/lab-savannah/kubelet/ui-config]  (NOT stale-snapshot)
```

---

### Climb 3 — Permissions, Ownership & the Non-Root Container

#### 🟢 Scenario 3.1 — "Asheville: the script you just wrote refuses to run" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-asheville
sudo tee /opt/lab-asheville/create-cluster.sh >/dev/null <<'EOF'
#!/bin/bash
echo "eksctl: creating cluster eksdemo-dev with Karpenter ... done (simulated)"
EOF
sudo chmod 644 /opt/lab-asheville/create-cluster.sh   # exactly what a git clone / editor gives you
cd /opt/lab-asheville
./create-cluster.sh          # ← bash: ./create-cluster.sh: Permission denied
bash create-cluster.sh       # ← ...but THIS works?!
```

**Situation:** Fresh checkout, first command of the runbook: `./create-cluster.sh` → `Permission denied`. Confusingly, `bash create-cluster.sh` runs the very same file perfectly. Same file, same user, same directory — one invocation denied, one allowed.

**Your task:** (1) Fix `./create-cluster.sh` with the one-command ritual every course script needs. (2) Then explain the asymmetry precisely: in each of the two invocations, **which file is the kernel being asked to execute**, and which permission bit does it check on *that* file? (Hint: `ls -l /usr/bin/bash` vs `ls -l create-cluster.sh`.) (3) Bonus: why did the file arrive as `644` at all? (`umask` is the answer — check yours.)

**Project link:** S19 verbatim: `chmod +x create-cluster-with-karpenter.sh` before the first run — and the same ritual before `git-push.sh` and every other course script. Files fresh from `git clone` or an editor are born `644` because of umask `022`; the execute bit is a deliberate opt-in.

**Verify:**

```bash
/opt/lab-asheville/create-cluster.sh
# expected: eksctl: creating cluster eksdemo-dev with Karpenter ... done (simulated)   (exit 0)
ls -l /opt/lab-asheville/create-cluster.sh | cut -c1-10
# expected: -rwxr-xr-x   (x present in the user triplet at minimum)
```

---

#### 🟢 Scenario 3.2 — "Wichita: the right file, the wrong triplet" (Easy)

**Setup:**

```bash
sudo groupadd -g 10020 labapp 2>/dev/null || true
sudo useradd -u 10001 -m -s /bin/bash labuser1 2>/dev/null || true
sudo mkdir -p /opt/lab-wichita
echo 'catalog-Passw0rd' | sudo tee /opt/lab-wichita/db-password >/dev/null
sudo chown root:labapp /opt/lab-wichita/db-password
sudo chmod 640 /opt/lab-wichita/db-password
sudo chmod 755 /opt/lab-wichita
ls -l /opt/lab-wichita/db-password              # ← -rw-r----- root labapp ... looks readable?
sudo -u labuser1 cat /opt/lab-wichita/db-password   # ← Permission denied
```

**Situation:** The app runs as `labuser1` (uid 10001 — the local stand-in for a pod's `runAsUser`). The password file exists, the *group* triplet plainly says `r--`, and yet `labuser1` is denied. Nothing about the file is wrong. Something about *who matches which triplet* is.

**Your task:** (1) Narrate the kernel's decision for this exact access: uid 10001 vs owner `root` → owner triplet skipped; then the gid check — what are `labuser1`'s groups (`id labuser1`), and which triplet ends up applying? (2) Grant access **the fsGroup way**: no `chmod 644` (never widen `other`), no `chown` — change *the user's group membership* so the group triplet matches. (3) State the exclusive-match rule this lab runs on: why would `chmod 044` deny even the *owner*?

**Project link:** S08's `fsGroup: 1000` is exactly this move at the Kubernetes layer: don't loosen the file, give the process's identity a gid that matches the file's group triplet — how the non-root catalog pod reads its `440` mounted secret.

**Verify:**

```bash
id labuser1 | grep -o 'labapp' 
# expected: labapp   (membership granted)
sudo -u labuser1 cat /opt/lab-wichita/db-password
# expected: catalog-Passw0rd
ls -l /opt/lab-wichita/db-password | cut -c1-10
# expected: -rw-r-----   (mode unchanged — other still gets nothing)
```

---

#### 🟡 Scenario 3.3 — "Anchorage: the file is readable, the doorway is not" (Medium)

**Setup:**

```bash
sudo useradd -u 10001 -m -s /bin/bash labuser1 2>/dev/null || true   # reused from 3.2 if present
sudo mkdir -p /opt/lab-anchorage/secrets
echo 'api-token-8842' | sudo tee /opt/lab-anchorage/secrets/token.txt >/dev/null
sudo chmod 644 /opt/lab-anchorage/secrets/token.txt   # the FILE is world-readable
sudo chmod 700 /opt/lab-anchorage/secrets             # ...the DOORWAY is not
sudo chmod 755 /opt/lab-anchorage
ls -l /opt/lab-anchorage/secrets/token.txt 2>/dev/null || sudo ls -l /opt/lab-anchorage/secrets/token.txt
sudo -u labuser1 cat /opt/lab-anchorage/secrets/token.txt   # ← Permission denied. But it's 644!
```

**Situation:** The token file is mode `644` — readable by literally every uid on the machine. And yet `labuser1` gets `Permission denied` on it. The file's triplets cannot be the problem. Something *on the way to the file* is.

**Your task:** (1) Explain which check fails: the kernel walks **every directory in the path** and demands `x` (traverse) on each — where does the walk die? (2) Fix it with the **minimal single bit**: `labuser1` must be able to `cat` the file *by its full path*, but must still be **unable to list** the directory (this is the classic secrets-dir posture: traverse without enumerate). `chmod -R` or `755` is an automatic fail. (3) Demonstrate the difference between directory `r` (list names) and directory `x` (pass through) with the two commands in Verify.

**Project link:** S09's mounted-secret directories live on this exact distinction: pods traverse into `/mnt/secrets-store` to read known filenames while listing can stay locked down — and every "the file is 644 but the pod can't read it" ticket is a missing `x` on a parent directory.

**Verify:**

```bash
sudo -u labuser1 cat /opt/lab-anchorage/secrets/token.txt
# expected: api-token-8842
sudo -u labuser1 ls /opt/lab-anchorage/secrets 2>&1 | grep -o 'Permission denied'
# expected: Permission denied   (traverse granted, listing still blocked)
stat -c '%a' /opt/lab-anchorage/secrets
# expected: 701
```

---

#### 🟡 Scenario 3.4 — "Fargo: the non-root container that cannot write its volume" (Medium)

> **Requires:** Docker (`sudo apt-get install -y docker.io`, or any VM that already runs Docker).

**Setup:**

```bash
sudo mkdir -p /opt/lab-fargo/data
sudo chown root:root /opt/lab-fargo/data
sudo chmod 755 /opt/lab-fargo/data
# the hardened container: non-root uid 10001, host volume mounted at /data
sudo docker run --rm --user 10001:10001 -v /opt/lab-fargo/data:/data alpine:3.19 \
  sh -c 'id; echo hello > /data/orders.db'
# ← uid=10001 ... sh: can't create /data/orders.db: Permission denied
```

**Situation:** Security policy says the container runs as uid 10001 (`runAsNonRoot` in spirit). The volume is mounted fine — `ls /data` works from inside. But the very first write dies. Running the container as root "fixes" it, which is exactly the fix the security review will reject.

**Your task:** (1) Narrate the triplet decision for the failed write: who owns `/opt/lab-fargo/data`, which triplet does uid 10001 match, and does that triplet contain `w`? (2) Fix the **host directory** the way Kubernetes' `fsGroup` does — group-own the volume to a gid the container's process has, grant the group write, and add the setgid bit so future files inherit the group. Do **not** run the container as root and do **not** `chmod 777`. (3) Prove a fresh non-root container can now write, and that the file it creates carries gid 10001.

**Project link:** S08's `fsGroup: 1000` exists *precisely* for this: kubelet re-groups and re-modes mounted volumes at pod start so the `runAsUser: 1000` app can write them — you just performed kubelet's chown/chmod by hand and now know exactly what that one YAML line does.

**Verify:**

```bash
sudo docker run --rm --user 10001:10001 -v /opt/lab-fargo/data:/data alpine:3.19 \
  sh -c 'echo hello > /data/orders.db && ls -ln /data/orders.db'
# expected: write succeeds; ls shows the file with gid 10001, e.g.:
#           -rw-r--r--  1 10001 10001  6 ... /data/orders.db
stat -c '%a' /opt/lab-fargo/data
# expected: 2775   (setgid + group-writable)
```

---

#### 🟠 Scenario 3.5 — "Spokane: two services, one shared volume, one loses every time" (Hard)

**Setup:**

```bash
sudo useradd -u 10001 -m -s /bin/bash labuser1 2>/dev/null || true   # "catalog"
sudo useradd -u 10002 -m -s /bin/bash labuser2 2>/dev/null || true   # "cart"
sudo groupadd -g 10030 labshare 2>/dev/null || true
sudo usermod -aG labshare labuser1
sudo usermod -aG labshare labuser2
sudo mkdir -p /opt/lab-spokane/shared          # the "ReadWriteMany PV"
sudo chown root:labshare /opt/lab-spokane/shared
sudo chmod 775 /opt/lab-spokane/shared
# reproduce today's fight: catalog writes a work file, cart tries to append to it
sudo -u labuser1 bash -c 'umask 022; echo "batch-1 (from catalog)" > /opt/lab-spokane/shared/queue.txt'
ls -l /opt/lab-spokane/shared/queue.txt        # ← owned labuser1:labuser1, mode 644
sudo -u labuser2 bash -c 'echo "batch-2 (from cart)" >> /opt/lab-spokane/shared/queue.txt' \
  || echo ">>> cart lost again <<<"
# the team's current 'fix' is a cron chown -R every 5 minutes. It loses every race.
```

**Situation:** Two services share one volume. Both users are in the `labshare` group; the directory is group-writable; on paper this should work. In practice, every file `catalog` creates is born `labuser1:labuser1 644` — so `cart` matches the *other* triplet (`r--`) and loses. The team's cron-based `chown -R` band-aid re-fixes the volume every 5 minutes, and every file created *between* runs breaks `cart` again. You're here to kill the cron.

**Your task:** Make the directory **self-correcting**: every *future* file, created by either user with any umask, must (a) belong to group `labshare` and (b) be group-writable — with **no cron, no post-hoc chmod, no umask coordination between teams**. That takes two independent mechanisms, and you must explain what each contributes: the **setgid bit** on the directory (which controls the *group* of new files) and a **default ACL** (which controls the *permissions* of new files, overriding umask). Install ACL tooling if needed (`sudo apt-get install -y acl`). Heal the existing `queue.txt` casualty once by hand, then prove the directory heals itself for new files.

**Project link:** S10's shared volumes (a ReadWriteMany PV / EFS mount used by two deployments) hit this exact race: `fsGroup` fixes each pod's *mount-time* ownership, but files two apps create *for each other* on shared storage need setgid + default ACLs on the volume itself — the on-disk equivalent of an EFS access point's enforced gid.

**Verify:**

```bash
sudo -u labuser1 bash -c 'umask 022; echo "batch-3" > /opt/lab-spokane/shared/new.txt'
sudo -u labuser2 bash -c 'echo "batch-4" >> /opt/lab-spokane/shared/new.txt' && echo "CART-WROTE-OK"
# expected: CART-WROTE-OK   (no chown/chmod ran between the two commands)
ls -l /opt/lab-spokane/shared/new.txt
# expected: group = labshare, group has rw (e.g. -rw-rw-r--+ ... labuser1 labshare ...)
getfacl -p /opt/lab-spokane/shared | grep '^default:group::'
# expected: default:group::rwx
```

---

#### 🔴 Scenario 3.6 — "Lubbock: rebuild the hardened pod on a bare VM" (Expert)

**Setup:**

```bash
sudo useradd -u 10003 -m -s /bin/bash labuser3 2>/dev/null || true   # the pod's runAsUser
# the "image" (writable build side) and the "container rootfs" (what the pod sees):
sudo mkdir -p /opt/lab-lubbock/image/app /opt/lab-lubbock/image/tmp \
             /opt/lab-lubbock/image/secrets /opt/lab-lubbock/rootfs
sudo tee /opt/lab-lubbock/image/app/entrypoint.sh >/dev/null <<'EOF'
#!/bin/bash
set -e
pw=$(cat /opt/lab-lubbock/rootfs/secrets/db-password)
echo "cache-$(date +%s)" > /opt/lab-lubbock/rootfs/tmp/cache
echo "catalog started: secret read OK, cache written OK (password ${#pw} bytes)"
EOF
sudo chmod 600 /opt/lab-lubbock/image/app/entrypoint.sh    # ← image bug: entrypoint has NO exec bit
# assemble the pod from raw Linux, exactly as the kubelet would:
sudo mount --bind /opt/lab-lubbock/image /opt/lab-lubbock/rootfs
sudo mount -o remount,ro,bind /opt/lab-lubbock/rootfs       # readOnlyRootFilesystem: true
sudo mount -t tmpfs -o size=1m lab-lubbock-secrets /opt/lab-lubbock/rootfs/secrets
echo -n 'S3cur3-catalog-pw' | sudo tee /opt/lab-lubbock/rootfs/secrets/db-password >/dev/null
sudo chmod 0400 /opt/lab-lubbock/rootfs/secrets/db-password # ← defaultMode 0400, owner root
# start the "pod" as its runAsUser:
sudo -u labuser3 /opt/lab-lubbock/rootfs/app/entrypoint.sh
# ← Permission denied. Fix that and the NEXT failure appears. There are three in total.
```

**Situation:** You've been handed a hardened pod rebuilt from raw Linux primitives: a read-only root filesystem (ro bind mount), a RAM-backed secret volume (tmpfs, file mode `0400`, root-owned), and a non-root `runAsUser` (uid 10003). It does not start. Fixing the first failure reveals a second; fixing that reveals a third. Each failure is a different permission mechanism, and each fix must **preserve the hardening** — if your fix is "run it as root", "chmod 777", or "make the rootfs writable", you failed the security review.

**Your task:** Drive the pod to a clean start through **three distinct fixes**, and name the Kubernetes knob each one corresponds to:
1. The entrypoint won't execute → fix it **in the image** (the writable `/opt/lab-lubbock/image` side — note your fix appears through the ro mount without ever writing through it). *K8s name: a `RUN chmod +x` line in the Dockerfile (S03).*
2. The secret is unreadable by uid 10003 → fix the **secret file's group/mode**, not the user and not `644`. *K8s names: `fsGroup` + the volume's `defaultMode` (S08/S09).*
3. The cache write dies on the read-only rootfs → graft a **writable tmpfs over exactly `rootfs/tmp`**, leaving everything else immutable. *K8s name: an `emptyDir` volume mounted at `/tmp` (the Climb 3 check-yourself answer).*

Then prove the hardening survived: a write anywhere else on the rootfs must still fail with `Read-only file system`.

**Project link:** This is S08's whole `securityContext` block — `runAsUser: 1000`, `runAsNonRoot`, `readOnlyRootFilesystem: true`, `fsGroup`, secret `defaultMode` — rebuilt out of `mount`, `chmod`, and `chgrp`, so every YAML line now maps to a syscall-level decision you have personally made.

**Verify:**

```bash
sudo -u labuser3 /opt/lab-lubbock/rootfs/app/entrypoint.sh
# expected: catalog started: secret read OK, cache written OK (password 17 bytes)   (exit 0)
sudo -u labuser3 touch /opt/lab-lubbock/rootfs/app/hack 2>&1 | grep -o 'Read-only file system'
# expected: Read-only file system   (hardening intact everywhere except /tmp)
mount | grep -c 'lab-lubbock'
# expected: 3   (ro rootfs bind + secrets tmpfs + your new tmp tmpfs)
```


### Climb 4 — Processes, Signals & PID 1

#### 🟢 Scenario 4.1 — "Tampere: the container that ignored its shutdown notice" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-tampere
sudo tee /opt/lab-tampere/app.sh >/dev/null <<'EOF'
#!/bin/bash
# checkout-app: the team never wrote a shutdown handler.
# (In a container this app would be PID 1, which gets NO default signal handlers;
#  on this bare VM we simulate that immunity by explicitly ignoring TERM.)
trap '' TERM
echo "checkout-app: serving (pid $$)"
while true; do sleep 1; done
EOF
sudo tee /opt/lab-tampere/vm-stop.sh >/dev/null <<'EOF'
#!/bin/bash
# emulates `docker stop` on a bare VM: SIGTERM, wait up to 10s, then SIGKILL
APP="${1:?usage: vm-stop.sh <app-script>}"
"$APP" & PID=$!
sleep 1
START=$SECONDS
kill -TERM "$PID"
for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$PID" 2>/dev/null; then
  echo "grace period expired — escalating to SIGKILL"
  kill -KILL "$PID"
fi
wait "$PID"; CODE=$?
echo "stopped in $((SECONDS - START))s, exit=$CODE"
EOF
sudo chmod +x /opt/lab-tampere/app.sh /opt/lab-tampere/vm-stop.sh
```

**Situation:** Every deploy of the checkout container takes forever to roll. Ops timed it: `docker stop` sits there for exactly 10 seconds on this one service, then the container dies with exit code 137. Every other service stops in under a second with exit 0. The app team swears "we don't do anything weird on shutdown" — which, it turns out, is exactly the problem. `/opt/lab-tampere/vm-stop.sh` reproduces the orchestrator's stop sequence on this VM so you can watch it happen without Docker.

**Your task:** Run `/opt/lab-tampere/vm-stop.sh /opt/lab-tampere/app.sh` and observe the 10-second hang and the exit code. Explain where 137 comes from (do the arithmetic). Then fix `/opt/lab-tampere/app.sh` so it shuts down *gracefully and immediately* on SIGTERM: print a goodbye line and exit 0, in well under 2 seconds. (If you have Docker installed, also try `docker run -d --name deaf alpine sleep 999; time docker stop deaf; docker inspect -f '{{.State.ExitCode}}' deaf` — same story, real container.)

**Project link:** This is `docker stop` in S02 taking exactly 10 s on some containers, and every slow `kubectl delete pod` you will ever see: SIGTERM → grace period (`terminationGracePeriodSeconds`, default 30 s) → SIGKILL → exit 137 in `kubectl describe pod`.

**Verify:**

```bash
sudo /opt/lab-tampere/vm-stop.sh /opt/lab-tampere/app.sh
# expected: your goodbye line, then "stopped in 0s, exit=0" (1s at most)
# before the fix it printed: "grace period expired — escalating to SIGKILL"
#                            "stopped in 10s, exit=137"   ← 137 = 128 + 9 (SIGKILL)
```

---

#### 🟢 Scenario 4.2 — "Turku: the port-forward nobody remembered starting" (Easy)

**Setup:**

```bash
sudo mkdir -p /opt/lab-turku
sudo tee /opt/lab-turku/forward.sh >/dev/null <<'EOF'
#!/bin/bash
# stand-in for a long-forgotten: kubectl port-forward svc/argocd-server 8445:443 &
exec python3 -m http.server 8445 --bind 127.0.0.1
EOF
sudo chmod +x /opt/lab-turku/forward.sh
( setsid /opt/lab-turku/forward.sh >/dev/null 2>&1 & )
sleep 1
```

**Situation:** You try to start a new port-forward for a demo and get `bind: address already in use` on port 8445. Nobody on the team admits to running anything on 8445. Whoever started it closed their terminal weeks ago — yet the listener is still alive, parented to nobody. This happens constantly with `kubectl port-forward ... &` sessions people background and forget.

**Your task:** Find what is listening on 127.0.0.1:8445 (`ss -ltnp` or `lsof -i :8445`). Inspect the process with `ps -o pid,ppid,user,etime,cmd -p <PID>` and explain why its PPID is 1 even though a human started it from a terminal. Kill it *politely* — SIGTERM, not `-9` — and free the port. Finally, prove the exit-code arithmetic to yourself with a child of your own shell: background a `sleep`, TERM it, and read the status.

**Project link:** S21 runs `kubectl port-forward svc/argocd-server 8080:443 &` — job control (`&`, `jobs`, `kill %1`) and orphaned background processes are that line's whole failure mode. Exit 143 is exactly what a gracefully terminated pod reports in `kubectl describe`.

**Verify:**

```bash
ss -ltn | grep 8445 || echo "port 8445 free"
# expected: "port 8445 free"

sleep 500 & kill -TERM %1; wait %1; echo "exit status: $?"
# expected: "exit status: 143"   ← 143 = 128 + 15 (SIGTERM), same math as pod exits
```

---

#### 🟡 Scenario 4.3 — "Aarhus: the wrapper that ate the SIGTERM" (Medium)

**Setup:**

```bash
sudo mkdir -p /opt/lab-aarhus
sudo tee /opt/lab-aarhus/app.sh >/dev/null <<'EOF'
#!/bin/bash
# the actual service: it DOES handle SIGTERM properly
graceful() { echo "app: SIGTERM received — graceful shutdown, bye"; exit 0; }
trap graceful TERM
echo "app: serving (pid $$)"
while true; do sleep 1 & wait $!; done
EOF
sudo tee /opt/lab-aarhus/entrypoint.sh >/dev/null <<'EOF'
#!/bin/bash
# added last sprint to "prepare the environment" before the app starts
echo "entrypoint: warming cache…"
sleep 1
echo "entrypoint: starting app"
/opt/lab-aarhus/app.sh
EOF
sudo chmod +x /opt/lab-aarhus/app.sh /opt/lab-aarhus/entrypoint.sh
```

**Situation:** The carts image used to stop instantly — the app has a beautiful SIGTERM handler, and the Dockerfile uses exec-form `CMD ["./app"]`. Last sprint somebody inserted an entrypoint wrapper script to warm a cache first, and ever since, `docker stop` takes the full 10 seconds again and the "graceful shutdown" log line never appears. The app's signal handler didn't change. Something between the orchestrator and the app is eating the signal.

**Your task:** Reproduce it: run `/opt/lab-aarhus/entrypoint.sh > /tmp/lab-aarhus.log 2>&1 &`, note the background PID, give it 2 seconds, then `kill -TERM` that PID. Check the log and check whether `app.sh` is still running (`pgrep -f /opt/lab-aarhus/app.sh`). Explain who actually received the SIGTERM and why the app never saw it. Then fix `entrypoint.sh` with a **one-word change** so the signal reaches the app. Clean up any stray `app.sh` you orphaned along the way.

**Project link:** This is exactly why the retail-store Dockerfiles (S03) insist on **exec form** `CMD ["app"]`: shell-form `CMD app` makes `/bin/sh` PID 1, and sh doesn't forward SIGTERM — so every `docker stop` and every rolling-update pod replacement (S08/S21) waits out the full grace period and ends in a 137.

**Verify:**

```bash
/opt/lab-aarhus/entrypoint.sh > /tmp/lab-aarhus.log 2>&1 &
sleep 2; kill -TERM $!; sleep 1
grep bye /tmp/lab-aarhus.log && ! pgrep -f /opt/lab-aarhus/app.sh
# expected: "app: SIGTERM received — graceful shutdown, bye" and NO surviving app.sh
# before the fix: no "bye" in the log, and pgrep shows app.sh still running, orphaned
```

---

#### 🟡 Scenario 4.4 — "Odense: the service that restarts every two seconds" (Medium)

**Setup:**

```bash
sudo mkdir -p /opt/lab-odense
sudo tee /opt/lab-odense/orders-api.sh >/dev/null <<'EOF'
#!/bin/bash
: "${LISTEN_PORT:?LISTEN_PORT is required}"
echo "orders-api: listening on ${LISTEN_PORT}"
exec python3 -m http.server "${LISTEN_PORT}" --bind 127.0.0.1
EOF
sudo chmod +x /opt/lab-odense/orders-api.sh
sudo tee /opt/lab-odense/env >/dev/null <<'EOF'
# orders-api runtime configuration
LISTEN_PROT=8410
EOF
sudo tee /etc/systemd/system/lab-odense.service >/dev/null <<'EOF'
[Unit]
Description=lab-odense orders-api
StartLimitIntervalSec=0

[Service]
EnvironmentFile=/opt/lab-odense/env
ExecStart=/opt/lab-odense/orders-api.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl start lab-odense
```

**Situation:** The orders API was "deployed" to this VM an hour ago and has been flapping ever since: `systemctl status lab-odense` shows `activating (auto-restart)`, the PID changes every couple of seconds, and `curl 127.0.0.1:8410` never answers. Nothing is wrong with the network, the port is free, and the script runs fine when a developer exports the right variables by hand — the classic "works on my shell" crash loop.

**Your task:** Watch the loop (`systemctl status lab-odense`, then `watch -n1 systemctl show -p NRestarts,ActiveState lab-odense` if you like). Read *why* PID 1 keeps exiting: `journalctl -u lab-odense -n 20 --no-pager`. Find the root cause (it is one character-level mistake in one file under `/opt/lab-odense/`), fix it, restart the unit, and confirm the API answers on port 8410.

**Project link:** This is `CrashLoopBackOff` with the costume off: kubelet (here: systemd `Restart=always`) faithfully restarting a PID 1 that keeps exiting, with backoff (`RestartSec` ≈ the CrashLoop backoff timer). The S14 wrong-endpoint errors and the S19 memory incident both looked exactly like this — and `journalctl -u` is your `kubectl logs --previous`.

**Verify:**

```bash
systemctl is-active lab-odense
# expected: "active"   (was: "activating")
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8410/
# expected: 200
R1=$(systemctl show -p NRestarts --value lab-odense); sleep 5
R2=$(systemctl show -p NRestarts --value lab-odense)
[ "$R1" = "$R2" ] && echo "restart counter stable"
# expected: "restart counter stable"  (it was climbing every ~2s before the fix)
```

---

#### 🟠 Scenario 4.5 — "Trondheim: the checkout counter full of ghosts" (Hard)

**Setup:**

```bash
sudo mkdir -p /opt/lab-trondheim
sudo tee /opt/lab-trondheim/checkout-counter.py >/dev/null <<'EOF'
#!/usr/bin/env python3
"""checkout-counter: forks a short-lived 'receipt printer' child per sale."""
import os, time
print(f"checkout-counter up (pid {os.getpid()})", flush=True)
n = 0
while True:
    pid = os.fork()
    if pid == 0:
        os._exit(0)        # receipt printed; child exits — but who collects the body?
    n += 1
    print(f"receipt #{n} printed by pid {pid}", flush=True)
    time.sleep(1)
EOF
# run it as PID 1 of its own PID namespace — exactly a container's situation:
sudo unshare --pid --fork --mount-proc \
  python3 /opt/lab-trondheim/checkout-counter.py >/tmp/lab-trondheim.log 2>&1 &
```

**Situation:** A monitoring alert fires: process count on the node climbing steadily, one new entry per second, forever. `ps -eo pid,ppid,stat,cmd | awk '$3 ~ /^Z/'` shows an ever-growing crowd of `<defunct>` python processes — zombies. They hold no memory and can't be killed (`kill -9` does nothing to them — try it). The parent is a little "checkout counter" running as **PID 1 inside its own PID namespace**, the same seat your app occupies in every container.

**Your task:** Watch the zombie count grow for ~10 seconds and explain precisely what a zombie *is* (what the kernel is keeping, and for whom) and why `kill -9` can't remove one. Explain what would normally reap them on a full Linux box and why being PID 1 in a namespace changes the rules. Then stop the counter (`sudo pkill -f checkout-counter.py`), fix `/opt/lab-trondheim/checkout-counter.py` by installing a **SIGCHLD handler that reaps** (`os.waitpid(-1, os.WNOHANG)` in a loop), relaunch the same `unshare` command, and confirm the ghost population stays at zero. (No sudo available? Run the script plainly — `python3 /opt/lab-trondheim/checkout-counter.py &` — zombies accumulate under any non-reaping parent; the namespace just makes it PID 1 like a container.)

**Project link:** PID 1 must reap children — this is why `tini`, `docker run --init`, and K8s `shareProcessNamespace` exist, and one of the two reasons Rung 3 says "PID 1 is special." A container whose entrypoint forks helpers and never waits fills the node with defunct entries until the pid cgroup limit trips.

**Verify:**

```bash
sleep 10
ps -eo stat,comm | awk '$1 ~ /^Z/ && $2 == "python3"' | wc -l
# expected after the fix: 0    (buggy version: roughly one new zombie per second)
grep -c receipt /tmp/lab-trondheim.log
# expected: a growing number — the counter is still doing its job, just reaping now
```

---

#### 🔴 Scenario 4.6 — "Stavanger: the rolling update that dropped the shopping carts" (Expert)

**Setup:**

```bash
sudo mkdir -p /opt/lab-stavanger
sudo tee /opt/lab-stavanger/worker.py >/dev/null <<'EOF'
#!/usr/bin/env python3
"""One 'pod' of the carts service: slow to start (3s warmup), graceful on SIGTERM."""
import http.server, signal, socketserver, sys, threading, time

PORT, VERSION = int(sys.argv[1]), sys.argv[2]
WARMUP = 3.0

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ready\n"); return
        time.sleep(0.3)                       # simulated in-flight work per request
        self.send_response(200); self.end_headers()
        self.wfile.write(f"carts {VERSION}\n".encode())
    def log_message(self, *args): pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = False                    # finish in-flight requests before closing

print(f"worker {VERSION}:{PORT} starting (warming up {WARMUP}s)…", flush=True)
time.sleep(WARMUP)                            # JVM-style slow start: port NOT bound yet
srv = Server(("127.0.0.1", PORT), Handler)

def on_term(signum, frame):
    print(f"worker {VERSION}:{PORT} got SIGTERM — draining, then exiting", flush=True)
    threading.Thread(target=srv.shutdown).start()

signal.signal(signal.SIGTERM, on_term)
print(f"worker {VERSION}:{PORT} READY", flush=True)
srv.serve_forever()
print(f"worker {VERSION}:{PORT} stopped cleanly", flush=True)
EOF
sudo tee /opt/lab-stavanger/load.sh >/dev/null <<'EOF'
#!/bin/bash
# shopper simulator: hammers whatever the endpoints file says is in service
EP=/tmp/lab-stavanger/endpoints
DURATION="${1:-12}"
total=0 ok=0 dropped=0
end=$(( SECONDS + DURATION ))
while (( SECONDS < end )); do
  mapfile -t ports < "$EP"
  (( ${#ports[@]} == 0 )) && { dropped=$((dropped+1)); continue; }
  port="${ports[RANDOM % ${#ports[@]}]}"
  if curl -fsS --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    dropped=$((dropped+1))
  fi
  total=$((total+1))
done
echo "requests=${total} ok=${ok} dropped=${dropped}"
(( dropped == 0 ))
EOF
sudo tee /opt/lab-stavanger/start.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail
RUN=/tmp/lab-stavanger
mkdir -p "$RUN"
python3 /opt/lab-stavanger/worker.py 8461 v1 >>"$RUN/worker.log" 2>&1 &
echo $! > "$RUN/worker-8461.pid"
until curl -fsS --max-time 1 http://127.0.0.1:8461/healthz >/dev/null 2>&1; do sleep 0.2; done
echo 8461 > "$RUN/endpoints"
echo "v1 serving on 8461, endpoints file live"
EOF
sudo tee /opt/lab-stavanger/rollout-bad.sh >/dev/null <<'EOF'
#!/bin/bash
# ship v2 of carts — the way that pages you at 2am
RUN=/tmp/lab-stavanger
kill -9 "$(cat "$RUN/worker-8461.pid")"            # sever v1 mid-request
python3 /opt/lab-stavanger/worker.py 8462 v2 >>"$RUN/worker.log" 2>&1 &
echo $! > "$RUN/worker-8462.pid"
echo 8462 > "$RUN/endpoints"                        # route traffic before v2 is ready
echo "rollout-bad: done (or was it?)"
EOF
sudo chmod +x /opt/lab-stavanger/*.sh
```

**Situation:** This VM carries a miniature of the whole rolling-update machine: `worker.py` is a "pod" (3-second warm-up before it binds its port, graceful SIGTERM drain), `/tmp/lab-stavanger/endpoints` is the EndpointSlice (the load balancer's routing table, one port per line), and `load.sh` is your customers, reading that file for every request. Marketing is watching a live dashboard. The current deploy script, `rollout-bad.sh`, "ships v2" — and every time it runs, the dashboard turns red: hundreds of carts requests dropped. Run it and feel the pain first: `/opt/lab-stavanger/start.sh`, then `( sleep 3; /opt/lab-stavanger/rollout-bad.sh ) &`, then `/opt/lab-stavanger/load.sh 12`.

**Your task:** Read `rollout-bad.sh` and enumerate *every distinct way* it drops requests (there are at least three: think in-flight, warm-up window, and routing order). Then write `/tmp/lab-stavanger/rollout-good.sh` that ships v2 (port 8462) with **zero dropped requests**, reordering the same ingredients the Kubernetes way: start new → **readiness-gate** it (`/healthz`) → add it to endpoints → **remove old from endpoints and let it drain** → grace window → **SIGTERM** old → wait for clean exit. Update the endpoints file *atomically* (write a temp file, `mv` over) so the load client never reads a half-written table. To retry after a failed attempt: kill any workers (`pkill -f lab-stavanger/worker.py`), `rm -rf /tmp/lab-stavanger`, and start over from `start.sh`.

**Project link:** This is the Rung 5 trace of Climb 4 made executable — the S21 rolling update, pod by pod: readiness probes gate EndpointSlice membership, the dying pod is removed from endpoints *and* SIGTERMed, `terminationGracePeriodSeconds` is your grace window, and "V904 with zero dropped requests" is precisely `dropped=0` here. `rollout-bad.sh` is what `kill -9`-style deploys and `terminationGracePeriodSeconds: 0` actually do to users.

**Verify:**

```bash
pkill -f lab-stavanger/worker.py; rm -rf /tmp/lab-stavanger
/opt/lab-stavanger/start.sh
( sleep 3; /tmp/lab-stavanger/rollout-good.sh ) &
/opt/lab-stavanger/load.sh 12; echo "load exit: $?"
# expected: "requests=<N> ok=<N> dropped=0" and "load exit: 0"
#           (rollout-bad under the same load dropped hundreds)
curl -s http://127.0.0.1:8462/
# expected: "carts v2"  — the new version is what's serving
grep 'stopped cleanly' /tmp/lab-stavanger/worker.log
# expected: v1's clean-exit line — it was TERMed and drained, not murdered
```

---

### Climb 5 — Shell Scripting: the Automation Muscle

#### 🟢 Scenario 5.1 — "Uppsala: the commit message that split in two" (Easy)

**Setup:**

```bash
rm -rf /tmp/lab-uppsala && mkdir -p /tmp/lab-uppsala
git init --bare -q /tmp/lab-uppsala/remote.git
git clone -q /tmp/lab-uppsala/remote.git /tmp/lab-uppsala/repo 2>/dev/null
cd /tmp/lab-uppsala/repo
git config user.email lab@devopsinminutes.com
git config user.name "Lab User"
git checkout -q -b main
echo "V903" > version.txt
git add -A && git commit -qm "initial" && git push -q origin main
cat > git-push.sh <<'EOF'
#!/bin/bash
# quick push helper (S21 pattern)
git add -A
git commit -m $1
git push origin main
EOF
chmod +x git-push.sh
```

**Situation:** The team's `git-push.sh` helper has worked for months — because everyone's commit messages were single words like `V903`. Today someone ran `./git-push.sh "V904 commit"` and got `error: pathspec 'commit' did not match any file(s) known to git`. No commit was made, the push said "Everything up-to-date", and — worst of all — the script exited 0, so the CI step that calls it went green while shipping nothing.

**Your task:** Reproduce it: `cd /tmp/lab-uppsala/repo`, edit `version.txt` to say `V904`, run `./git-push.sh "V904 commit"`, and read the error. Explain exactly what argument list `git commit` received and why the quotes you typed on the command line didn't survive into the script. Fix `git-push.sh` (one pair of characters) and push the change for real.

**Project link:** S21's `git-push.sh "V904 commit"` verbatim — Rung 5 of Climb 5 traces this exact script. The rule it teaches ("quote your expansions or spaces split them") is the same one that breaks `--name ${CLUSTER_NAME}` and `-f values-${SVC}.yaml` everywhere else in the course.

**Verify:**

```bash
cd /tmp/lab-uppsala/repo && git log -1 --pretty=%s
# expected: V904 commit          ← one message, space intact
git --git-dir=/tmp/lab-uppsala/remote.git log -1 --pretty=%s main
# expected: V904 commit          ← and it actually reached the remote
```

---

#### 🟢 Scenario 5.2 — "Gothenburg: the deploy that lied about succeeding" (Easy)

**Setup:**

```bash
rm -rf /tmp/lab-gothenburg && mkdir -p /tmp/lab-gothenburg/bin
cat > /tmp/lab-gothenburg/bin/helm <<'EOF'
#!/bin/bash
# lab stub standing in for the real helm CLI — carts is broken today
sleep 0.2
if [[ "$*" == *carts* ]]; then
  echo 'Error: INSTALLATION FAILED: timed out waiting for the condition' >&2
  exit 1
fi
echo "Release \"$3\" has been upgraded. Happy Helming!"
EOF
chmod +x /tmp/lab-gothenburg/bin/helm
cat > /tmp/lab-gothenburg/deploy.sh <<'EOF'
#!/bin/bash
# S19-style 5-service install loop
export PATH="/tmp/lab-gothenburg/bin:$PATH"
for SVC in catalog carts checkout orders ui; do
  helm upgrade --install "$SVC" "stacksimplify/retailstore-sample-${SVC}-chart" \
    --version 1.0.0 --wait --timeout 5m && echo "$SVC installed successfully"
done
echo "ALL 5 SERVICES DEPLOYED"
EOF
chmod +x /tmp/lab-gothenburg/deploy.sh
```

**Situation:** Friday, 5:57pm. The deploy pipeline ran `/tmp/lab-gothenburg/deploy.sh`, printed `ALL 5 SERVICES DEPLOYED`, exited 0, CI went green, everyone went home. Saturday morning: carts is down, and it turns out carts *failed to install* — the error is right there in Friday's log, sandwiched between four cheerful success lines. The script saw the failure, stepped over the body, and declared victory. (A stub `helm` on the PATH simulates the S19 loop without needing a cluster; carts always fails.)

**Your task:** Run `./deploy.sh; echo "exit=$?"` and confirm the lie: carts errors, yet the summary prints and the exit code is 0. Explain precisely what the `&&` in the loop body guards — and what it does **not** guard. Then fix `deploy.sh` so a failed service can never produce a green build: it must still *attempt* every service (ops wants the full damage report), print which ones failed, and exit non-zero if any did. Say what plain `set -e` at the top would have done differently (fail-fast at carts) and why both designs beat the lie.

**Project link:** This is the S19 Helm install loop `helm upgrade --install $SVC … && echo "$SVC installed successfully"` — and the Climb 5 check-yourself question made flesh. Every CI pipeline in S21 trusts exit codes; a script that swallows them poisons everything downstream.

**Verify:**

```bash
/tmp/lab-gothenburg/deploy.sh; echo "exit=$?"
# expected: catalog/checkout/orders/ui succeed, "FAILED: carts" on stderr,
#           a summary naming carts, and "exit=1"
# buggy version printed "ALL 5 SERVICES DEPLOYED" and "exit=0" despite the error
```

---

#### 🟡 Scenario 5.3 — "Vilnius: the trust policy that trusted ${literally-nobody}" (Medium)

**Setup:**

```bash
rm -rf /tmp/lab-vilnius && mkdir -p /tmp/lab-vilnius && cd /tmp/lab-vilnius
cat > make-trust-policy.sh <<'OUTER'
#!/bin/bash
# builds the IAM trust policy for the GitHub-Actions OIDC role (S21 §6.1 pattern)
REPO=$1
AWS_ACCOUNT_ID=$(printf '%012d' 424242)   # stand-in for: aws sts get-caller-identity --query Account
cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${REPO}:*" } }
  }]
}
EOF
echo "trust policy written for repo: ${REPO}"
OUTER
chmod +x make-trust-policy.sh
```

**Situation:** A teammate automated the S21 trust-policy step, but `aws iam create-role` keeps rejecting the JSON with an invalid-principal error. You open the generated `trust-policy.json` and find the ARN reads — literally — `arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/...`. The shell never substituted anything. Bonus bug: run the script with **no** argument and it happily writes a policy for repo "" and exits 0 — a trust policy for nobody, or depending on the wildcard, anybody.

**Your task:** Run `./make-trust-policy.sh myuser/retail-store` and inspect the JSON — find the un-expanded `${...}` placeholders. Explain *which* heredoc delimiter quoting caused this (`<<'EOF'` vs `<<EOF`) and why the same script *deliberately* uses the quoted form somewhere else conceptually (hint: how did this Setup block itself write `$1` into the script without your shell eating it?). Fix two things: (1) make the inner heredoc expand its variables; (2) make a missing argument a **loud usage error** using the `${1:?...}` parameter form, plus `set -euo pipefail`.

**Project link:** S21 §6.1 builds `trust-policy.json` with exactly this heredoc-plus-`$(aws sts get-caller-identity)` pattern, and Climb 5's Lab 2 previews the two heredoc modes. Getting the delimiter quoting wrong in IAM JSON is a *security* bug, not a style bug.

**Verify:**

```bash
cd /tmp/lab-vilnius
./make-trust-policy.sh 2>&1 | tail -1; echo "no-arg exit: ${PIPESTATUS[0]}"
# expected: a usage message and "no-arg exit: 1"  (buggy version exited 0)
./make-trust-policy.sh myuser/retail-store
grep -c '\${' trust-policy.json
# expected: 0   ← no literal placeholders left
grep -o 'repo:[^"]*' trust-policy.json
# expected: repo:myuser/retail-store:*
python3 -m json.tool trust-policy.json >/dev/null && echo "valid JSON"
# expected: "valid JSON"
```

---

#### 🟡 Scenario 5.4 — "Kaunas: the cluster named nothing" (Medium)

**Setup:**

```bash
rm -rf /tmp/lab-kaunas && mkdir -p /tmp/lab-kaunas/bin && cd /tmp/lab-kaunas
cat > bin/terraform <<'EOF'
#!/bin/bash
# lab stub: state was wiped, so `terraform output` fails — as it does after a botched destroy
echo 'Error: No outputs found. The state file either has no outputs defined,' >&2
echo 'or all the defined outputs are empty.' >&2
exit 1
EOF
chmod +x bin/terraform
cat > delete-cluster.sh <<'EOF'
#!/bin/bash
# nightly cost-hygiene teardown
export PATH="/tmp/lab-kaunas/bin:$PATH"
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null | tr -d '"')
echo "deleting cluster: ${CLUSTER_NAME}"
# stand-in for: eksctl delete cluster --name ${CLUSTER_NAME}
echo "eksctl delete cluster --name ${CLUSTER_NAME}" > /tmp/lab-kaunas/issued-command.log
echo "teardown complete"
EOF
chmod +x delete-cluster.sh
```

**Situation:** The nightly teardown "worked" — exit 0, log says `teardown complete` — yet the EKS bill kept climbing, because the command it actually issued was `eksctl delete cluster --name` … with **no name**. Someone had wiped the Terraform state earlier that day, `terraform output` had been failing loudly ever since, but the script's `2>/dev/null` gagged the error and the pipeline's `| tr` laundered the exit code. `CLUSTER_NAME` was empty, and bash cheerfully interpolated nothing. (A stub `terraform` on the PATH reproduces the failing output; the destructive command is captured to a log instead of run.)

**Your task:** Run `./delete-cluster.sh; echo "exit=$?"` and inspect `/tmp/lab-kaunas/issued-command.log` — see the nameless delete. Explain the **two** separate mechanisms that hid the failure: the `2>/dev/null`, and why even `set -eu` would NOT have caught it while the `| tr` pipe is there (prove it: `bash -c 'set -eu; X=$(false | tr -d x); echo "still here"'`). Then harden the script so it can never issue a destructive command with an empty name: `set -euo pipefail`, drop the stderr gag, and add a `${VAR:?message}` guard as a second fence.

**Project link:** Every teardown script in the course captures `$(terraform output -raw ...)` (S06/S07/S19) and feeds it to a destructive command. `set -euo pipefail` is listed in Climb 5's vocabulary as "what production versions of the course scripts add" — this scenario is *why*, one flag at a time.

**Verify:**

```bash
cd /tmp/lab-kaunas && rm -f issued-command.log
./delete-cluster.sh; echo "exit=$?"
# expected: terraform's real error on stderr, NO "deleting cluster:" line, "exit=1"
ls issued-command.log 2>/dev/null || echo "no destructive command was issued"
# expected: "no destructive command was issued"
# buggy version: "deleting cluster: " (blank), exit=0, and a nameless eksctl line in the log
```

---

#### 🟠 Scenario 5.5 — "Tartu: the teardown that never cleaned up after itself" (Hard)

**Setup:**

```bash
rm -rf /tmp/lab-tartu && mkdir -p /tmp/lab-tartu && cd /tmp/lab-tartu
cat > teardown.sh <<'EOF'
#!/bin/bash
set -e
LOCK=/tmp/lab-tartu/teardown.lock
if [ -e "$LOCK" ]; then
  echo "another teardown is already running ($LOCK exists) — aborting" >&2
  exit 1
fi
touch "$LOCK"
WORKDIR=$(mktemp -d /tmp/lab-tartu/work.XXXXXX)
# stand-in for: kubectl port-forward svc/argocd-server 8446:443 &
sleep 300 & PF_PID=$!
echo "port-forward up (pid $PF_PID), workdir $WORKDIR"
echo "step 1/3: helm uninstall the 5 services"
false   # ← today, the uninstall step fails
echo "step 2/3: delete nodegroups"
echo "step 3/3: terraform destroy"
kill "$PF_PID"; rm -rf "$WORKDIR"; rm -f "$LOCK"   # cleanup lives on the happy path only
EOF
chmod +x teardown.sh
```

**Situation:** The cost-hygiene teardown script is careful: it takes a lock file so two teardowns can't fight, opens a port-forward, and works in a private tempdir — and it cleans all three up… on the last line. Today step 1 failed, `set -e` (correctly!) aborted the script, and the cleanup line never ran. Now there's a stale lock refusing all future runs ("another teardown is already running" — no, that's your own corpse), a leaked `sleep 300` posing as a port-forward, and an orphaned workdir. The 2am operator's fix was `rm` the lock by hand and move on — until next time.

**Your task:** Run `./teardown.sh` twice. First run: fails at step 1, leaves all three resources behind (`ls /tmp/lab-tartu`, `pgrep -f 'sleep 300'`). Second run: locked out by the first run's debris. Explain why `set -e` and end-of-script cleanup are fundamentally incompatible. Then restructure with a `cleanup()` function registered via `trap cleanup EXIT INT TERM` **immediately after each resource is acquired**, so the lock, the port-forward, and the workdir are released on success, on failure, *and* on Ctrl-C — while keeping `set -e` (upgrade it to `set -euo pipefail`) and keeping the failing step exactly where it is.

**Project link:** Climb 5's machinery rung promises `cleanup() {...}; trap cleanup EXIT` as "teardown that runs even on failure — the cost-hygiene sections beg for this." Every `kubectl port-forward ... &` in S21 and every `mktemp`-using script in the course leaks exactly like this without a trap.

**Verify:**

```bash
cd /tmp/lab-tartu && rm -f teardown.lock && rm -rf work.*
./teardown.sh; echo "exit=$?"
# expected: fails at step 1 with "exit=1" BUT prints your cleanup line first
ls /tmp/lab-tartu
# expected: only teardown.sh — no lock, no work.* dir
pgrep -f 'sleep 300' || echo "no leaked port-forward"
# expected: "no leaked port-forward"
./teardown.sh 2>&1 | head -1
# expected: "port-forward up …" — a fresh run STARTS instead of refusing;
# buggy version said: "another teardown is already running"
```

---

#### 🔴 Scenario 5.6 — "Reykjavik: the invisible carriage returns from a Windows laptop" (Expert)

**Setup:**

```bash
rm -rf /tmp/lab-reykjavik && mkdir -p /tmp/lab-reykjavik/bin && cd /tmp/lab-reykjavik
# the service list a colleague edited in Notepad and pushed from a Windows laptop:
printf 'catalog\r\ncarts\r\ncheckout\r\norders\r\nui\r\n' > services.txt
cat > bin/check-service <<'EOF'
#!/bin/bash
# lab stub for: kubectl rollout status deploy/"$1" / curl the service health endpoint
svc="$1"
case "$svc" in
  orders)
    n=$(cat /tmp/lab-reykjavik/.orders-attempts 2>/dev/null || echo 0)
    n=$((n+1)); echo "$n" > /tmp/lab-reykjavik/.orders-attempts
    if [ "$n" -lt 3 ]; then echo "orders: connection refused (still rolling out)" >&2; exit 1; fi
    echo "orders: healthy" ;;
  catalog|carts|checkout|ui)
    echo "$svc: healthy" ;;
  *)
    printf 'unknown service: %q\n' "$svc" >&2; exit 1 ;;
esac
EOF
chmod +x bin/check-service
cat > check-all.sh <<'EOF'
#!/bin/bash
export PATH="/tmp/lab-reykjavik/bin:$PATH"
for svc in $(cat /tmp/lab-reykjavik/services.txt); do
  check-service "$svc" || echo "$svc FAILED"
done
EOF
chmod +x check-all.sh
```

**Situation:** The post-deploy health gate suddenly reports **all five services failing** — `catalog FAILED`, `carts FAILED`, … — yet every service is demonstrably healthy when checked by hand. The only change: a colleague reordered `services.txt` in Notepad on Windows and pushed it. `cat services.txt` looks perfectly normal. The names *are* correct. Or are they? (`orders` is also genuinely mid-rollout: it refuses its first two checks and succeeds on the third — the gate has no retry, so even fixing the file leaves it flaky.)

**Your task:** Run `./check-all.sh` and read the stderr closely — the stub prints failing names through `printf %q`, which is the debugging trick of this whole scenario. Confirm the diagnosis with `file services.txt` and `cat -A services.txt` (what is `^M`?). Explain why `$(cat file)` word-splitting kept the `\r` glued to every name, and why even the recommended `while IFS= read -r` loop **still keeps it** (what exactly does `-r` protect against — and what doesn't it touch?). Then rewrite `check-all.sh` production-grade: (1) `while IFS= read -r` line loop with an explicit `${line%$'\r'}` carriage-return strip, skipping blank lines; (2) a reusable `retry <max-tries> <cmd…>` function with exponential backoff so the mid-rollout `orders` passes on attempt 3; (3) a final summary of healthy vs broken services, exiting 0 only when nothing is broken. Do **not** edit `services.txt` — Windows colleagues exist; your script must survive them.

**Project link:** S21's CI checks services in a loop after Argo CD syncs; one CRLF file from a Windows checkout (or a missing `.gitattributes`) produces exactly this all-red mystery, and `kubectl get deploy "carts\r"` fails just as strangely. The retry-with-backoff function is the same pattern as waiting for `helm --wait`, readiness probes, and `aws eks wait`.

**Verify:**

```bash
cd /tmp/lab-reykjavik && rm -f .orders-attempts
./check-all.sh; echo "exit=$?"
# expected: 4 services healthy immediately; orders fails twice, succeeds on attempt 3;
#           summary shows "healthy (5): catalog carts checkout orders ui" / broken: none;
#           "exit=0"
# buggy version: unknown service: $'catalog\r' … all 5 FAILED, yet exit=0
cat .orders-attempts
# expected: 3   ← proof the retry function earned its keep
```


### Climb 6 — Text Processing: grep, sed, awk, jq, base64

#### 🟢 Scenario 6.1 — "Nairobi: The Timeout Needle in the Log Haystack" (Easy)

**Setup:**
```bash
mkdir -p /tmp/lab-c6-1 && cd /tmp/lab-c6-1
cat > catalog.log <<'EOF'
2026-07-24T09:00:01Z INFO  GET /catalogue 200 12ms
2026-07-24T09:00:02Z ERROR GET /catalogue 500 Timeout connecting to mysql:3306
2026-07-24T09:00:03Z INFO  GET /health 200 1ms
2026-07-24T09:00:04Z WARN  slow query on catalog db 950ms
2026-07-24T09:00:05Z ERROR GET /catalogue 500 timeout waiting for connection pool
2026-07-24T09:00:06Z INFO  GET /catalogue/size 200 8ms
2026-07-24T09:00:07Z ERROR GET /catalogue 500 mysql: too many connections
2026-07-24T09:00:08Z ERROR checkout call failed: connect TIMEOUT to checkout:8080
EOF
```

**Situation:** The catalog service is intermittently returning 500s to the UI, and a teammate has already saved the output of `kubectl logs deploy/catalog` to `/tmp/lab-c6-1/catalog.log` before the pod restarted. On-call wants a fast answer: is this a timeout problem, and is *every* error a timeout — or is something else hiding in there?

**Your task:** Using only `grep`: (1) count how many lines mention a timeout in **any** capitalization (`Timeout`, `timeout`, `TIMEOUT`), (2) print each timeout line together with the line just before it for context, and (3) print any ERROR line that is **not** a timeout — that's your second suspect.

**Project link:** Every debugging session in the course starts with `kubectl logs deploy/catalog | grep -i timeout` (Climb 6 Rung 1 / S20 observability).

**Verify:**
```bash
grep -ic timeout /tmp/lab-c6-1/catalog.log
# expected: 3
grep ERROR /tmp/lab-c6-1/catalog.log | grep -vic timeout
# expected: 1   (the "too many connections" line — a different incident!)
```

#### 🟢 Scenario 6.2 — "Kigali: Decoding the Argo CD Front Door" (Easy)

**Setup:**
```bash
command -v jq >/dev/null || sudo apt-get install -y jq   # jq is required for this climb
mkdir -p /tmp/lab-c6-2 && cd /tmp/lab-c6-2
cat > argocd-secret.json <<'EOF'
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "argocd-initial-admin-secret",
    "namespace": "argocd"
  },
  "type": "Opaque",
  "data": {
    "password": "elg5LXJFdGFpbFN0b3JlMjE="
  }
}
EOF
```

**Situation:** You have just installed Argo CD (S21) and need the initial admin password to log in to the web UI. A colleague saved the Secret for you with `kubectl -n argocd get secret argocd-initial-admin-secret -o json > argocd-secret.json` — but what's inside `data.password` looks like gibberish ending in `=`. It is not encrypted; it is only dressed up.

**Your task:** Extract the `data.password` field with `jq -r` and decode it with `base64 -d` in a single pipeline — the disk-file equivalent of the course's `kubectl ... -o jsonpath='{.data.password}' | base64 -d` one-liner. State the plain-text password.

**Project link:** S21's Argo CD login step: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

**Verify:**
```bash
jq -r '.data.password' /tmp/lab-c6-2/argocd-secret.json | base64 -d; echo
# expected: zX9-rEtailStore21
```

#### 🟡 Scenario 6.3 — "Accra: The sed That Rewrote Too Much" (Medium)

**Setup:**
```bash
mkdir -p /tmp/lab-c6-3 && cd /tmp/lab-c6-3
cat > values-ui.yaml <<'EOF'
image:
  repository: 123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-ui
  tag: sha-9f8e7d6
autoscaling:
  enabled: true
  targetCPUUtilizationPercentage: 70
metadata:
  tag: sha-9f8e7d6
EOF
```

**Situation:** A junior engineer "improved" the CI write-back step (S21) by dropping the anchor: they ran `sed -i "s/tag: .*/tag: $TAG/" values-ui.yaml`. The unanchored pattern matched **both** `tag:` lines, so the chart-metadata tag — which must always read `retail-store-ui` — was clobbered with the image SHA too. Argo CD is now flagging the app as degraded, and a *new* build (`sha-1a2b3c4`) is already waiting to be written back.

**Your task:** Repair the file with `sed` only: (1) restore the `tag:` under `metadata:` to `retail-store-ui` **without** touching the image tag — you'll need a sed *address range* (`/^metadata:/,...`) because both broken lines are now textually identical; (2) then perform the write-back of `TAG=sha-1a2b3c4` scoped to the `image:` block. Confirm exactly the right two lines changed.

**Project link:** THE S21 CI→CD handoff line: `sed -i "s/^  tag: .*/  tag: $TAG/" source/ui/chart/values-ui.yaml` — and why its `^  ` anchor exists.

**Verify:**
```bash
grep -n '  tag:' /tmp/lab-c6-3/values-ui.yaml
# expected:
# 3:  tag: sha-1a2b3c4
# 8:  tag: retail-store-ui
```

#### 🟡 Scenario 6.4 — "Lagos: Reading the Order Queue with jq" (Medium)

**Setup:**
```bash
command -v jq >/dev/null || sudo apt-get install -y jq
mkdir -p /tmp/lab-c6-4 && cd /tmp/lab-c6-4
cat > sqs-receive.json <<'EOF'
{
  "Messages": [
    {
      "MessageId": "8a1f3c2e-0001-4b2a-9c1d-aaaaaaaaaaaa",
      "ReceiptHandle": "AQEBzJ...truncated...",
      "Body": "{\"orderId\":\"ORD-1001\",\"customer\":\"amina\",\"total\":25.00,\"items\":2}"
    },
    {
      "MessageId": "8a1f3c2e-0002-4b2a-9c1d-bbbbbbbbbbbb",
      "ReceiptHandle": "AQEB7Q...truncated...",
      "Body": "{\"orderId\":\"ORD-1002\",\"customer\":\"kwame\",\"total\":60.25,\"items\":5}"
    },
    {
      "MessageId": "8a1f3c2e-0003-4b2a-9c1d-cccccccccccc",
      "ReceiptHandle": "AQEBpX...truncated...",
      "Body": "{\"orderId\":\"ORD-1003\",\"customer\":\"zola\",\"total\":14.75,\"items\":1}"
    }
  ]
}
EOF
```

**Situation:** In S14 the checkout service publishes each completed order to an SQS queue and the orders service consumes it. To verify the wiring you ran `aws sqs receive-message --queue-url ... --max-number-of-messages 3` and saved the raw output. The catch: each `Body` is a JSON document **stored as an escaped string inside JSON** — one `jq` pass isn't enough; you must parse twice.

**Your task:** With `jq`: (1) list the three `orderId`s (raw, no quotes), (2) compute the total revenue sitting in the queue by summing the `total` fields, and (3) print only orders with `items >= 2` as `orderId<TAB>items`. Hint: `fromjson` re-parses a string value, exactly like the course's `| jq -r '.Messages[].Body' | jq .` double-pipe.

**Project link:** S14's SQS verification: `aws sqs receive-message ... | jq -r '.Messages[].Body' | jq` on the checkout→orders queue.

**Verify:**
```bash
jq -r '.Messages[].Body | fromjson | .orderId' /tmp/lab-c6-4/sqs-receive.json
# expected: ORD-1001  ORD-1002  ORD-1003   (one per line)
jq '[.Messages[].Body | fromjson | .total] | add' /tmp/lab-c6-4/sqs-receive.json
# expected: 100
```

#### 🟠 Scenario 6.5 — "Dakar: Fleet Triage from a Frozen Snapshot" (Hard)

**Setup:**
```bash
command -v jq >/dev/null || sudo apt-get install -y jq
mkdir -p /tmp/lab-c6-5 && cd /tmp/lab-c6-5
cat > pods.json <<'EOF'
{"apiVersion":"v1","kind":"List","items":[
 {"metadata":{"name":"catalog-6d5f7c9b8d-x2kfp","namespace":"retail-store"},
  "spec":{"containers":[{"name":"catalog","image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-catalog:sha-1a2b3c4"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"catalog","restartCount":0,"lastState":{}}]}},
 {"metadata":{"name":"ui-59b8c7d6f5-q8wzn","namespace":"retail-store"},
  "spec":{"containers":[{"name":"ui","image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-ui:sha-1a2b3c4"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"ui","restartCount":1,"lastState":{}}]}},
 {"metadata":{"name":"cart-7c8d9e6f4a-m3jlt","namespace":"retail-store"},
  "spec":{"containers":[{"name":"cart","image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-cart:sha-1a2b3c4"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"cart","restartCount":0,"lastState":{}}]}},
 {"metadata":{"name":"checkout-5f6a7b8c9d-r7vhs","namespace":"retail-store"},
  "spec":{"containers":[{"name":"checkout","image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-checkout:sha-1a2b3c4"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"checkout","restartCount":2,"lastState":{}}]}},
 {"metadata":{"name":"orders-84bd9f6c77-t9pqx","namespace":"retail-store"},
  "spec":{"containers":[{"name":"orders","image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store-orders:sha-0ld0000"}]},
  "status":{"phase":"Running","containerStatuses":[{"name":"orders","restartCount":7,"lastState":{"terminated":{"reason":"OOMKilled","exitCode":137}}}]}}
]}
EOF
```

**Situation:** During an incident review you're handed `pods.json` — a `kubectl get pods -n retail-store -o json` snapshot taken at 09:14, minutes before the cluster was torn down. All five services show `Running`, yet customers saw failed orders all morning. The evidence is in the snapshot; the cluster is gone. This is exactly the query `kubectl get pod orders-... -o jsonpath='{.status.containerStatuses[0].restartCount}'` would have answered live — now you must do it with `jq` over a file.

**Your task:** Build pipelines that answer, from `pods.json` alone: (1) which pod has `restartCount > 3` (a `jq` `select`), (2) what its last termination `reason` was, (3) a frequency table of running image **tags** (`jq` for the image, then `awk -F:` + `sort | uniq -c` for the tag histogram) — and from that, (4) name the pod running an image tag different from the fleet. Write one sentence connecting the two findings to explain the morning's failures.

**Project link:** S21's jsonpath queries + the S19 incident post-mortem — `kubectl get pods -o json` is the raw form behind every `-o jsonpath` you type.

**Verify:**
```bash
jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 3) | .metadata.name' /tmp/lab-c6-5/pods.json
# expected: orders-84bd9f6c77-t9pqx
jq -r '.items[].spec.containers[0].image' /tmp/lab-c6-5/pods.json | awk -F: '{print $2}' | sort | uniq -c | sort -rn
# expected:
#       4 sha-1a2b3c4
#       1 sha-0ld0000
```

#### 🔴 Scenario 6.6 — "Tunis: The Invisible Newline That Locked Out MySQL" (Expert)

**Setup:**
```bash
command -v jq >/dev/null || sudo apt-get install -y jq
mkdir -p /tmp/lab-c6-6 && cd /tmp/lab-c6-6
BAD=$(echo 'RetailDB#2026' | base64)   # the bug: echo (not printf) smuggled in a newline
cat > mysql-secret.json <<EOF
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": { "name": "mysql-credentials", "namespace": "retail-store" },
  "type": "Opaque",
  "data": {
    "username": "$(printf 'catalog' | base64)",
    "password": "$BAD"
  }
}
EOF
unset BAD
```

**Situation:** The catalog service is in `CrashLoopBackOff` with `Access denied for user 'catalog'@'10.0.2.17'` — yet when a teammate decodes the Secret's password it "looks exactly right" on screen, and the same password pasted into `mysql -p` works fine. The Secret was hand-crafted last week with `echo 'RetailDB#2026' | base64` instead of `printf`/`echo -n`, so the byte MySQL never accepts is one your eyes can't see. You have the exported Secret as `mysql-secret.json`.

**Your task:** (1) Prove the corruption forensically: decode `data.password` and expose the invisible byte with `od -c`, and show the decoded length with `wc -c` (13 characters should never weigh 14 bytes). (2) Re-encode the password correctly with `printf`. (3) Patch the JSON **in place with jq itself** (`jq --arg p "$NEW" '.data.password = $p'` — sed on JSON is how you create the next incident). (4) Re-verify the decoded value is exactly 13 bytes with no trailing `\n`.

**Project link:** Climb 6's `-n` warning + S09's hand-crafted-Secret bug class — the reason the course moves DB credentials to AWS Secrets Manager (S09/S14).

**Verify:**
```bash
jq -r '.data.password' /tmp/lab-c6-6/mysql-secret.json | base64 -d | wc -c
# expected: 13   (was 14 before the fix)
jq -r '.data.password' /tmp/lab-c6-6/mysql-secret.json | base64 -d | od -c | head -1
# expected: 0000000   R   e   t   a   i   l   D   B   #   2   0   2   6    (no \n at the end)
```

### Climb 7 — I/O Streams, Redirection & Pipes

#### 🟢 Scenario 7.1 — "Cairo: The Warning That Dodged the Pipe" (Easy)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-1 && cd /tmp/lab-c7-1
cat > healthcheck.sh <<'EOF'
#!/bin/bash
echo "ui OK"
echo "WARN: catalog probe skipped (istio sidecar not ready)" >&2
echo "cart OK"
echo "checkout OK"
echo "WARN: orders responded in 1900ms (threshold 1000ms)" >&2
EOF
chmod +x healthcheck.sh
```

**Situation:** Your post-deploy smoke script checks each retail-store service and prints `<service> OK` per healthy service. A teammate runs `./healthcheck.sh | grep -c OK` to count healthy services — the count is right, but two WARN lines *still splash across the terminal*, apparently ignoring the pipe entirely. They're confused: "I piped everything into grep!"

**Your task:** Explain and demonstrate: (1) run the pipeline and observe the WARNs bypass `grep` — they travel on fd 2, and `|` connects only fd 1; (2) rerun with stderr discarded (`2>/dev/null`) for a clean count; (3) split the streams into `ok.txt` and `warn.txt` in one invocation; (4) rerun with `2>&1` so the WARNs *do* enter the pipe and count them.

**Project link:** `2>/dev/null` in the course's quiet existence checks, and why `curl -s ... | jq` failures print curl's complaint *around* jq's output (Climb 7 Rung 3).

**Verify:**
```bash
cd /tmp/lab-c7-1
./healthcheck.sh 2>/dev/null | grep -c OK
# expected: 3   (and NO WARN lines on the terminal this time)
./healthcheck.sh 2>&1 | grep -c WARN
# expected: 2
```

#### 🟢 Scenario 7.2 — "Casablanca: The Clobbered \$GITHUB_ENV" (Easy)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-2 && cd /tmp/lab-c7-2
export GITHUB_ENV=/tmp/lab-c7-2/github.env
cat > step-a.sh <<'EOF'
#!/bin/bash
echo "TAG=sha-1a2b3c4" >> "$GITHUB_ENV"
EOF
cat > step-b.sh <<'EOF'
#!/bin/bash
echo "IMAGE_BASE=retail-store-ui" > "$GITHUB_ENV"
EOF
chmod +x step-a.sh step-b.sh
```

**Situation:** Your GitHub Actions workflow (S21) computes the image tag in one step and the ECR repo base in the next, exporting both via `$GITHUB_ENV` so the `sed` write-back step can use them. Since yesterday the deploy step fails with an empty `$TAG`. The two step scripts above are faithful copies of the workflow steps — one of them contains a single-character bug.

**Your task:** (1) Run `./step-a.sh` then `./step-b.sh` (each in a fresh shell, like real CI steps) and inspect `github.env` — where did `TAG` go? (2) Spot the `>` vs `>>` difference, fix step-b, rerun both from a clean file, and (3) `source` the env file the way Actions effectively does between steps and show both variables survive.

**Project link:** S21's `echo "TAG=sha-$SHORT_SHA" >> $GITHUB_ENV` — append, never truncate, because every step shares that one file.

**Verify:**
```bash
cd /tmp/lab-c7-2 && rm -f github.env && ./step-a.sh && ./step-b.sh
. "$GITHUB_ENV" && echo "$TAG $IMAGE_BASE"
# expected: sha-1a2b3c4 retail-store-ui   (after your fix; before it, TAG is empty)
```

#### 🟡 Scenario 7.3 — "Windhoek: Following the Firehose" (Medium)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-3 && cd /tmp/lab-c7-3
cat > order-stream.sh <<'EOF'
#!/bin/bash
# simulates a live pod: one log line per second for 30s, every 5th is an ERROR
LOG="$(dirname "$(readlink -f "$0")")/orders.log"
: > "$LOG"
for i in $(seq 1 30); do
  if [ $((i % 5)) -eq 0 ]; then
    echo "$(date -u +%FT%TZ) ERROR publish to SQS failed for ORD-1$(printf '%03d' $i) (credentials expired)" >> "$LOG"
  else
    echo "$(date -u +%FT%TZ) INFO  order ORD-1$(printf '%03d' $i) accepted, published to queue" >> "$LOG"
  fi
  sleep 1
done
EOF
chmod +x order-stream.sh
nohup ./order-stream.sh >/dev/null 2>&1 &
echo $! > writer.pid
```

**Situation:** The orders service is live and emitting a log line every second; some orders are failing to publish to SQS (S14). You need to watch the failures *as they happen* — the on-disk file `/tmp/lab-c7-3/orders.log` is your stand-in for a pod's log stream, and following it is exactly what `kubectl logs -f deploy/orders` does.

**Your task:** (1) Follow the log live and filter to errors only, keeping a copy as evidence: `tail -f orders.log | grep --line-buffered ERROR | tee errors.txt` — watch at least two ERROR lines arrive, then press Ctrl-C. (2) Prove Ctrl-C killed only *your follower*, not the app: `kill -0 $(cat writer.pid)` still succeeds while the writer is within its 30s life. (3) Explain why `--line-buffered` is needed (without it, grep writing into the `tee` pipe buffers ~4KB before you see anything). Wait for the writer to finish, then verify.

**Project link:** `kubectl logs -f` / `docker compose logs -f ui` — Climb 7 Rung 5's trace: the follower blocks until more bytes appear, and Ctrl-C never touches the app.

**Verify:**
```bash
sleep 32   # let the 30s writer finish if it hasn't
grep -c ERROR /tmp/lab-c7-3/orders.log
# expected: 6
test -s /tmp/lab-c7-3/errors.txt && echo "evidence captured"
# expected: evidence captured
```

#### 🟡 Scenario 7.4 — "Gaborone: Two Redirects, Wrong Order" (Medium)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-4 && cd /tmp/lab-c7-4
cat > tf-output.sh <<'EOF'
#!/bin/bash
echo 'Warning: the "eks_cluster" output is deprecated, use "cluster_endpoint"' >&2
echo 'cluster_endpoint = "https://A1B2C3D4.gr7.us-east-1.eks.amazonaws.com"'
EOF
cat > capture.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$(readlink -f "$0")")"
./tf-output.sh 2>&1 > all.log
EOF
chmod +x tf-output.sh capture.sh
```

**Situation:** After `terraform apply` (S06/07) your team archives `terraform output` — endpoint *and* any warnings — into one log for the audit trail. A colleague wrote `capture.sh` using `2>&1 > all.log`, reasoning "merge stderr into stdout, then send it all to the file." Yet the deprecation warning still hits the terminal, and `all.log` contains only the endpoint line. The command *looks* right and is subtly, classically wrong.

**Your task:** (1) Run `./capture.sh` and confirm the broken behavior (`wc -l all.log` shows 1; the warning escaped). (2) Explain the left-to-right rule: `2>&1` means "point fd 2 where fd 1 points **now**" (the terminal) — the later `> all.log` moves only fd 1. Redirections are `dup2()` calls executed in order, not a declarative wish-list. (3) Fix the script to `> all.log 2>&1` (or `&> all.log`) and confirm both lines land in the file.

**Project link:** The course's `terraform output | ...` plumbing and every `>> "$LOG" 2>&1` line in `create-cluster-with-karpenter.sh` (S19) — order decides what you capture.

**Verify:**
```bash
cd /tmp/lab-c7-4 && ./capture.sh && wc -l < all.log
# expected: 2   (endpoint + warning; broken version gives 1 and a leaked warning)
```

#### 🟠 Scenario 7.5 — "Kampala: The Logs kubectl Never Saw" (Hard)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-5 && cd /tmp/lab-c7-5
cat > orders-app.sh <<'EOF'
#!/bin/bash
# the "orders container" PID 1: logs to a FILE, not stdout (the anti-pattern)
DIR="$(dirname "$(readlink -f "$0")")"
for i in $(seq 1 30); do
  echo "$(date -u +%FT%TZ) POST /orders 201 ORD-2$(printf '%03d' $i)" >> "$DIR/app.log"
  sleep 1
done
EOF
cat > start-pod.sh <<'EOF'
#!/bin/bash
# plays the container runtime: captures the app's fd1+fd2 exactly like kubelet does
DIR="$(dirname "$(readlink -f "$0")")"
bash "$DIR/orders-app.sh" </dev/null > "$DIR/capture.log" 2>&1 &
echo $! > "$DIR/pod.pid"
echo "pod started, pid $(cat "$DIR/pod.pid")"
EOF
cat > kubectl-logs.sh <<'EOF'
#!/bin/bash
# `kubectl logs` analogue: shows ONLY what the runtime captured from fd1/fd2
cat "$(dirname "$(readlink -f "$0")")/capture.log"
EOF
chmod +x orders-app.sh start-pod.sh kubectl-logs.sh
./start-pod.sh
```

**Situation:** A vendor container for the orders service was "migrated" into the cluster, and now `kubectl logs deploy/orders` prints *nothing* — while support insists the app "definitely logs every request." In this lab, `start-pod.sh` is the container runtime (it captured the app's fd 1/fd 2 into `capture.log`), `kubectl-logs.sh` is `kubectl logs`, and the app is writing somewhere else entirely. You may not modify `orders-app.sh` — treat it as a vendor image you can't rebuild.

**Your task:** (1) Diagnose from `/proc`: with `PID=$(cat pod.pid)`, run `ls -l /proc/$PID/fd/` and `readlink /proc/$PID/fd/1` — fd 1 points at `capture.log` (empty), while the app opens `app.log` per write. `./kubectl-logs.sh` proves the capture pipeline works but receives nothing. (2) Fix it *without touching the app code*, the classic nginx-image trick: stop the pod (`kill $PID`), replace the log file with a symlink to the process's own stdout — `ln -sf /dev/stdout app.log` — and restart with `./start-pod.sh`. (3) Show `./kubectl-logs.sh` now streams the requests.

**Project link:** Climb 7's check-yourself question and S20: the K8s logging contract is *fd 1 + fd 2 only* — the retail services log to stdout on purpose so the OpenTelemetry collector can scrape them.

**Verify:**
```bash
cd /tmp/lab-c7-5 && sleep 3 && ./kubectl-logs.sh | tail -2
# expected: two "POST /orders 201 ORD-2..." lines (before the fix: no output at all)
readlink /tmp/lab-c7-5/app.log
# expected: /dev/stdout
```

#### 🔴 Scenario 7.6 — "Lusaka: The Pipeline That Lied to CI" (Expert)

**Setup:**
```bash
mkdir -p /tmp/lab-c7-6 && cd /tmp/lab-c7-6
cat > curl-endpoint.sh <<'EOF'
#!/bin/bash
# stands in for: curl -sf http://<ui-load-balancer>/actuator/health
echo "curl: (7) Failed to connect to ui.retail-store.svc port 8080: Connection refused" >&2
exit 7
EOF
cat > ci-step.sh <<'EOF'
#!/bin/bash
# post-deploy smoke-test step, as currently written — CI says it PASSES
DIR="$(dirname "$(readlink -f "$0")")"
"$DIR/curl-endpoint.sh" | tee "$DIR/check.log"
EOF
chmod +x curl-endpoint.sh ci-step.sh
```

**Situation:** Friday's release shipped a UI that was down, yet the S21 pipeline's smoke-test step glowed green and Argo CD happily synced. The step pipes the health-check through `tee` to keep evidence — and that `tee` is the perjurer: a pipeline's exit status is the **last** command's, so `curl-fails | tee-succeeds` reports success. CI never saw curl's exit 7.

**Your task:** (1) Reproduce the lie: `./ci-step.sh; echo $?` prints 0 despite the connection failure. (2) Autopsy the pipeline with `"${PIPESTATUS[@]}"` immediately after running it in your shell — see `7 0`. (3) Fix `ci-step.sh` with `set -o pipefail` so the pipeline's status becomes the rightmost *non-zero* member, and prove the step now fails with curl's own code. (4) Go one level deeper: a pipe is a kernel object you can hold in your hand — `mkfifo lab.fifo`, run `./curl-endpoint.sh 2> lab.fifo &` and `grep -c refused < lab.fifo` in the same shell, then remove it. Two processes, one kernel buffer: that's all `|` ever was.

**Project link:** S21's GitHub Actions steps — every `run:` block is a bash pipeline, and without `pipefail` any `... | tee` / `... | grep` step can bury a failing deploy.

**Verify:**
```bash
cd /tmp/lab-c7-6 && ./ci-step.sh 2>/dev/null; echo "exit=$?"
# expected: exit=7   (after the pipefail fix; before it: exit=0)
```

### Climb 8 — Namespaces & cgroups: What a Container Actually Is

#### 🟢 Scenario 8.1 — "Maputo: Namespaces Are Just Files" (Easy)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-1
hostname > /tmp/lab-c8-1/host-name-before.txt   # evidence for later
```

**Situation:** A new teammate claims containers are "mini-VMs." You have a plain Ubuntu VM, no Docker — and you're going to show them a "container boundary" is nothing but a process pointing at different namespace files. Every process advertises its namespaces under `/proc/<pid>/ns/`, and `docker run` (S02) merely creates processes whose links point at *different* inodes than yours.

**Your task:** (1) Inspect your own namespace links: `ls -l /proc/self/ns/` — each is a symlink like `uts:[4026531838]`; same number as another process = same world. (2) Compare with PID 1: `readlink /proc/self/ns/uts /proc/1/ns/uts` — identical, you share the host's UTS namespace. (3) Now step into a new one: `sudo unshare --uts bash`, and inside run `hostname retail-pod-maputo`, confirm with `hostname`, compare `readlink /proc/self/ns/uts` with the number you saw before (different inode = different world), then `exit`. (4) Confirm the host hostname never changed.

**Project link:** S02's `docker run` — the "isolation" of every retail-store container starts as exactly these per-resource views; no hypervisor anywhere.

**Verify:**
```bash
sudo unshare --uts bash -c 'hostname retail-pod-maputo; hostname'
# expected: retail-pod-maputo
hostname; diff <(hostname) /tmp/lab-c8-1/host-name-before.txt && echo "host untouched"
# expected: your original hostname + "host untouched"
```

#### 🟢 Scenario 8.2 — "Harare: Becoming PID 1" (Easy)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-2
ps -e --no-headers | wc -l > /tmp/lab-c8-2/host-proc-count.txt   # how crowded the host is
```

**Situation:** In S02 you noticed every container's main process is PID 1, and Climb 4 told you PID 1 has special signal duties. Time to manufacture that situation with zero Docker: a new PID namespace plus a fresh `/proc` mount gives you the exact "alone in the world" view a retail-store container wakes up to.

**Your task:** (1) Note the host's process count (setup saved it — likely hundreds). (2) Run `sudo unshare --pid --fork --mount-proc bash`; inside, run `echo $$` (you are PID 1) and `ps -e` (a nearly empty world — the blinders work). (3) Explain the two flags: `--fork` because the *child* must be the first process of the new namespace, and `--mount-proc` because `ps` reads `/proc`, which must be remounted to show the new namespace's view — without it `ps` would still show the host. (4) `exit` and confirm the host view is unchanged.

**Project link:** S02's `docker run retail-store-catalog` — the catalog binary "wakes up as PID 1 in an empty world" (Climb 8 Rung 5, step 4); this is that moment, hand-made.

**Verify:**
```bash
sudo unshare --pid --fork --mount-proc bash -c 'echo "inner pid: $$"; ps -e --no-headers | wc -l'
# expected: inner pid: 1   and a process count of 2-3 (vs hundreds on the host)
```

#### 🟡 Scenario 8.3 — "Abuja: A Pod's Budget Is a Directory" (Medium)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-3
stat -fc %T /sys/fs/cgroup/   # must print: cgroup2fs (cgroup v2 — default on modern Ubuntu)
```

**Situation:** In S08 you wrote `resources: {requests: {memory: 128Mi}, limits: {memory: 256Mi}}` for the catalog Deployment and kubectl accepted it silently. Today you find out where those numbers actually *land*: a directory of plain files under `/sys/fs/cgroup` that the kubelet writes on your behalf. You'll play kubelet by hand for one "pod."

**Your task:** (1) Create the budget: `sudo mkdir /sys/fs/cgroup/lab-catalog`. (2) Write the S08 limit into it: `echo $((256*1024*1024)) | sudo tee /sys/fs/cgroup/lab-catalog/memory.max` — that's `limits.memory: 256Mi` compiled to its final form. (3) Enroll a "container": start `sleep 300 &`, then `echo <its pid> | sudo tee /sys/fs/cgroup/lab-catalog/cgroup.procs`. (4) Read the meters: `cat /proc/<pid>/cgroup` (the process knows its cgroup) and `cat /sys/fs/cgroup/lab-catalog/memory.current` (live usage — what `kubectl top` ultimately reads). (5) Clean up: kill the sleep, `sudo rmdir /sys/fs/cgroup/lab-catalog`.

**Project link:** S08's `resources.requests/limits` table — `limits.memory` → `memory.max`, and HPA/`kubectl top` (S18) read the same accounting files.

**Verify:**
```bash
cat /sys/fs/cgroup/lab-catalog/memory.max
# expected: 268435456   (exactly 256Mi — run before the cleanup step)
sleep 300 & echo $! > /tmp/lab-c8-3/p.pid; echo "$(cat /tmp/lab-c8-3/p.pid)" | sudo tee /sys/fs/cgroup/lab-catalog/cgroup.procs >/dev/null
grep lab-catalog /proc/$(cat /tmp/lab-c8-3/p.pid)/cgroup
# expected: 0::/lab-catalog
kill "$(cat /tmp/lab-c8-3/p.pid)"
```

#### 🟡 Scenario 8.4 — "Marrakesh: Reproducing the 256Mi Crash-Loop" (Medium)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-4 && cd /tmp/lab-c8-4
sudo mkdir -p /sys/fs/cgroup/lab-orders
echo $((100*1024*1024)) | sudo tee /sys/fs/cgroup/lab-orders/memory.max >/dev/null
echo 0 | sudo tee /sys/fs/cgroup/lab-orders/memory.swap.max >/dev/null 2>&1 || true
cat > run-orders.sh <<'EOF'
#!/bin/bash
# stands in for the orders Spring Boot container: needs ~150M just to warm up
echo $$ > /sys/fs/cgroup/lab-orders/cgroup.procs
head -c 150M /dev/zero | tail >/dev/null && echo "orders service warmed up successfully"
EOF
```

**Situation:** This is the S19 incident, on a bare VM. The "orders service" (a stand-in that must hold ~150M in memory to warm up, like Spring Boot needing ~350Mi to boot) keeps dying instantly inside its cgroup, which someone budgeted at 100M. On the cluster this printed `CrashLoopBackOff` / `OOMKilled: true`; here you get to watch the kernel do it and read the kill report yourself. (Docker alternative if you prefer: `docker run --memory=100m alpine sh -c 'tail /dev/zero'` — same wall, same 137.)

**Your task:** (1) Run the service in its budget: `sudo bash run-orders.sh; echo "exit=$?"` — it dies with 137 (128+9: SIGKILL from the OOM killer) and never prints its success line. (2) Read the kernel's confession: `sudo dmesg | grep -i 'oom\|killed process' | tail -5`. (3) Apply the S19 fix — raise the limit, don't shrink the app: `echo $((400*1024*1024)) | sudo tee /sys/fs/cgroup/lab-orders/memory.max`. (4) Rerun: exit 0 and the success line. (5) State the rule this proves: memory over limit = death (a wall), never slowness.

**Project link:** S19's incident — Spring Boot services CrashLoopBackOff at `limits.memory: 256Mi` until raised to 400Mi; exit code 137 = `OOMKilled: true`.

**Verify:**
```bash
echo $((400*1024*1024)) | sudo tee /sys/fs/cgroup/lab-orders/memory.max >/dev/null
sudo bash /tmp/lab-c8-4/run-orders.sh; echo "exit=$?"
# expected: orders service warmed up successfully / exit=0   (at 100M instead: no message, exit=137)
```

#### 🟠 Scenario 8.5 — "Alexandria: The Valve and the Wall" (Hard)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-5 && cd /tmp/lab-c8-5
sudo mkdir -p /sys/fs/cgroup/lab-checkout
echo "20000 100000" | sudo tee /sys/fs/cgroup/lab-checkout/cpu.max >/dev/null   # limits.cpu: 200m
cat > busy.sh <<'EOF'
#!/bin/bash
i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done
EOF
```

**Situation:** After the Marrakesh OOM fix, the same team cut the checkout service's CPU to `limits.cpu: 200m` to save money — and unlike the memory change, *nothing died*. Checkout just got slower under load, and HPA (S18) quietly scaled it out. Today you prove the asymmetry with a stopwatch and the cgroup's own throttle ledger, then do HPA's percentage math by hand.

**Your task:** (1) Baseline: `time bash busy.sh` unconfined. (2) Confined: `sudo bash -c 'echo $$ > /sys/fs/cgroup/lab-checkout/cgroup.procs; time bash /tmp/lab-c8-5/busy.sh'` — roughly 5× slower on a `20000 100000` quota (20ms of CPU per 100ms period), but it *finishes*, exit 0. (3) Read the ledger: `grep -E '^(nr_throttled|throttled_usec)' /sys/fs/cgroup/lab-checkout/cpu.stat` — the kernel counted every time it paused you. (4) Be the HPA: start a permanent load in the cgroup (`sudo bash -c 'echo $$ > /sys/fs/cgroup/lab-checkout/cgroup.procs; while :; do :; done' &`), sample `usage_usec` from `cpu.stat` twice 10 seconds apart, and compute `(ΔU/10s)/1,000,000 = cores used`, then divide by a 100m *request* — that percentage vs the 70% target is exactly HPA's scaling decision. Kill the load when done.

**Project link:** S18's `targetCPUUtilizationPercentage: 70` — HPA compares cgroup `usage ÷ request`; and Climb 8's law: CPU limits throttle (valve), memory limits kill (wall).

**Verify:**
```bash
grep -E '^nr_throttled' /sys/fs/cgroup/lab-checkout/cpu.stat
# expected: nr_throttled <some number greater than 0> — the kernel throttled you, but nothing was killed
```

#### 🔴 Scenario 8.6 — "Durban: Hand-Building a Pod" (Expert)

**Setup:**
```bash
mkdir -p /tmp/lab-c8-6
sudo mkdir -p /sys/fs/cgroup/lab-pod-durban          # the pod's shared budget
command -v python3 >/dev/null || sudo apt-get install -y python3
```

**Situation:** S08 claims a pod's containers "share the network namespace," S22 claims the Istio sidecar "sees the app's traffic on localhost," and the vocabulary map says a *pause container* holds the pod's namespaces so the pod IP survives app restarts. Today you build all three claims from raw syscalls: a pause process owning net+uts namespaces, an "app container" and a "sidecar" entering them with `nsenter`, and localhost as the private wire between them — no Docker, no Kubernetes, port 8480.

**Your task:** (1) Start the pause: `sudo unshare --net --uts bash -c 'hostname lab-pod-durban; echo $$ > /tmp/lab-c8-6/pause.pid; sleep 600' &` and enroll it in the pod cgroup: `cat /tmp/lab-c8-6/pause.pid | sudo tee /sys/fs/cgroup/lab-pod-durban/cgroup.procs`. (2) A fresh net namespace has a dead loopback — bring it up: `sudo nsenter -t $(cat /tmp/lab-c8-6/pause.pid) -n ip link set lo up`. (3) Launch the "app container" *into the pause's namespaces*: `sudo nsenter -t $(cat /tmp/lab-c8-6/pause.pid) -n -u python3 -m http.server 8480 --bind 127.0.0.1 >/tmp/lab-c8-6/app.log 2>&1 &`. (4) Play the sidecar: `sudo nsenter -t $(cat /tmp/lab-c8-6/pause.pid) -n -u curl -s http://127.0.0.1:8480/` — it reaches the app on *the pod's* localhost. (5) Prove isolation: the same `curl` from the host fails — the pod's 8480 is not the host's 8480. (6) Kill only the python "app," restart it with the same `nsenter` line, and note the network namespace (the "pod IP") survived — because the *pause* process holds it. Clean up: kill the pause, `sudo rmdir /sys/fs/cgroup/lab-pod-durban`.

**Project link:** S08 "sidecars share net+storage," S22's Envoy intercepting on localhost, and the pause-container row of Climb 8's vocabulary map — a pod is namespaces shared on purpose plus one cgroup budget.

**Verify:**
```bash
sudo nsenter -t "$(cat /tmp/lab-c8-6/pause.pid)" -n -u curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8480/
# expected: 200   (the sidecar reaches the app over the pod's shared localhost)
curl -s --max-time 2 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8480/ || true
# expected: 000   (host loopback is a different namespace — connection refused)
sudo nsenter -t "$(cat /tmp/lab-c8-6/pause.pid)" -u hostname
# expected: lab-pod-durban   (while `hostname` on the host is unchanged)
```


### Climb 9 — Storage, Mounts & OverlayFS

#### 🟢 Scenario 9.1 — "Hanoi: the file behind the mount" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-hanoi/host-data /opt/lab-hanoi/container-view
echo "order-2025-log" | sudo tee /opt/lab-hanoi/host-data/orders.log >/dev/null
# container-view is empty right now — the app "sees" nothing
ls /opt/lab-hanoi/container-view
```
**Situation:** The retail-store catalog service is supposed to read `orders.log` from a durable host path, but inside the "container view" directory the file is missing — the ops runbook says the data lives on the host but the app can't see it. Someone forgot to graft the real filesystem into the view.

**Your task:** Bind-mount `/opt/lab-hanoi/host-data` onto `/opt/lab-hanoi/container-view` so `orders.log` appears *through* the view (not copied), and confirm the path is a mount boundary rather than a plain directory.

**Project link:** Mirrors `-v` bind mounts in `docker run` (S02) and the general idea that a volume grafts an external FS into the container's OverlayFS view (Climb 9, Rung 3).

**Verify:**
```bash
mountpoint -q /opt/lab-hanoi/container-view && echo "IS A MOUNT"   # expected: IS A MOUNT
cat /opt/lab-hanoi/container-view/orders.log                       # expected: order-2025-log
```

#### 🟢 Scenario 9.2 — "Da Nang: scratch that dies with the pod" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-danang/scratch
# a read-only-rootfs pod needs somewhere writable — an emptyDir (medium: Memory = tmpfs)
findmnt /opt/lab-danang/scratch || echo "nothing mounted yet"
```
**Situation:** An S08 pod runs with `readOnlyRootFilesystem: true`, so the app crashes trying to write its render cache to disk. The manifest gives it an `emptyDir` with `medium: Memory` — a RAM-backed tmpfs — for scratch. You must reproduce that emptyDir locally and prove its pod-lifetime volatility.

**Your task:** Mount a 16 MB `tmpfs` at `/opt/lab-danang/scratch`, write a cache file into it, confirm it is RAM-backed, then unmount it and show the file is gone (a pod delete destroys emptyDir).

**Project link:** Reproduces the `emptyDir` scratch volume for read-only-rootfs pods (S08); `medium: Memory` = tmpfs = RAM (Climb 9, Rung 3/4).

**Verify:**
```bash
findmnt -t tmpfs /opt/lab-danang/scratch     # expected: a tmpfs line for the scratch path
test ! -e /opt/lab-danang/scratch/cache.dat && echo "GONE AFTER UNMOUNT"  # expected: GONE AFTER UNMOUNT
```

#### 🟡 Scenario 9.3 — "Penang: the volume that outlives the container" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-penang /mnt/lab-penang
sudo dd if=/dev/zero of=/opt/lab-penang/ebs.img bs=1M count=64 status=none
# ebs.img is our stand-in block device — an EBS volume as a file
ls -lh /opt/lab-penang/ebs.img
```
**Situation:** The MySQL StatefulSet (`catalog-mysql-0`) keeps losing its database on every reschedule because the data was landing in the container's writable layer, not on a PersistentVolume. You'll build a faithful local EBS PV — a loop-device-backed ext4 filesystem — and prove data survives a "container recreation" (unmount/remount cycle).

**Your task:** Attach `ebs.img` to a loop device, format it ext4, mount it at `/mnt/lab-penang`, write a "row" file, unmount, then remount and confirm the row is still there.

**Project link:** Local analogue of the EBS-backed PersistentVolume behind the MySQL StatefulSet (S10); the mount boundary = the persistence boundary from Rung 5's write-trace.

**Verify:**
```bash
grep -q "row-1" /mnt/lab-penang/rows.txt && echo "DATA SURVIVED REMOUNT"  # expected: DATA SURVIVED REMOUNT
losetup -j /opt/lab-penang/ebs.img                                        # expected: shows the loop device backing the img
```

#### 🟡 Scenario 9.4 — "Bandung: the secret with the wrong lock" (Medium)
**Setup:**
```bash
sudo useradd -m labuser1 2>/dev/null || true
sudo mkdir -p /mnt/secrets-store
# a wrong-perms secret materialized world-readable — should be 0400 owned by the app user
echo "s3cr3t-db-pass" | sudo tee /mnt/secrets-store/db-password >/dev/null
sudo chmod 0644 /mnt/secrets-store/db-password
stat -c '%a %U' /mnt/secrets-store/db-password   # 644 root — too open
```
**Situation:** The Secrets Store CSI driver is supposed to materialize the Secrets-Manager DB password as a mounted file at `/mnt/secrets-store/db-password`, readable *only* by the app user (`runAsUser`/`fsGroup`, mode `0400`). Right now it's world-readable and root-owned — a `readOnlyRootFilesystem` audit flagged it. Rebuild the mount correctly as a tmpfs (secrets never touch disk) with a 0400 file owned by `labuser1`.

**Your task:** Mount a tmpfs at `/mnt/secrets-store`, write `db-password` as mode `0400` owned by `labuser1`, and prove `labuser1` can read it while another unprivileged user cannot.

**Project link:** Reproduces the Secrets Store CSI secret volume at `/mnt/secrets-store` and its restrictive mounted-secret mode (S09/S14); tmpfs keeps the secret off disk (Climb 9, Rung 4 CSI driver).

**Verify:**
```bash
stat -c '%a %U' /mnt/secrets-store/db-password           # expected: 400 labuser1
sudo -u labuser1 cat /mnt/secrets-store/db-password       # expected: s3cr3t-db-pass
findmnt -t tmpfs /mnt/secrets-store                       # expected: tmpfs line (secret is in RAM)
```

#### 🟠 Scenario 9.5 — "Cebu: copy-on-write, caught in the act" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-cebu/{base,appdeps,upper,work,merged}
# two read-only "image layers": base (FROM) and appdeps (RUN apt-get install)
echo "base-libc"      | sudo tee /opt/lab-cebu/base/libc.txt >/dev/null
echo "installed-curl" | sudo tee /opt/lab-cebu/appdeps/curl.txt >/dev/null
echo "shared-config-v1" | sudo tee /opt/lab-cebu/base/app.conf >/dev/null
```
**Situation:** Explaining to the team why "I edited `/app.conf` inside the running catalog container and it vanished on restart" — and why `docker build` reuses layers. You'll hand-build the exact OverlayFS stack Docker builds: two read-only lowerdirs (image layers), one writable upperdir (the container layer), and prove copy-on-write leaves the lower layers pristine.

**Your task:** `mount -t overlay` with `lowerdir=appdeps:base`, `upperdir`, and `workdir` onto `merged`. Through the merged view, edit `app.conf` (a file that lives in a lower layer). Confirm the edit was *copied up* into `upper` while the original lower-layer file is byte-for-byte unchanged.

**Project link:** Hand-built stand-in for Docker image layers + the disposable container layer and copy-on-write (S03 layer cache, S05 buildx cache); exactly the Rung 3 diagram and Lab 1's "vanishing write".

**Verify:**
```bash
grep -q "shared-config-v2" /opt/lab-cebu/upper/app.conf && echo "WRITE WENT TO UPPER"   # expected: WRITE WENT TO UPPER
grep -q "shared-config-v1" /opt/lab-cebu/base/app.conf && echo "LOWER LAYER PRISTINE"     # expected: LOWER LAYER PRISTINE
cat /opt/lab-cebu/merged/app.conf                                                          # expected: shared-config-v2 (merged view)
```

#### 🔴 Scenario 9.6 — "Chiang Mai: the disk that's full of nothing" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-chiangmai /mnt/lab-node
# a small "node disk" (emptyDir/upper-layer backing) we can fill on purpose
sudo dd if=/dev/zero of=/opt/lab-chiangmai/node.img bs=1M count=40 status=none
LOOP=$(sudo losetup --find --show /opt/lab-chiangmai/node.img)
sudo mkfs.ext4 -q "$LOOP"
sudo mount "$LOOP" /mnt/lab-node
# a logger writes, then its file is "rotated" (deleted) while still held open
sudo bash -c 'dd if=/dev/zero of=/mnt/lab-node/app.log bs=1M count=30 status=none; \
  exec 9>/mnt/lab-node/app.log; rm /mnt/lab-node/app.log; sleep 3000 &' 
df -h /mnt/lab-node   # shows FULL even though du sees almost nothing
```
**Situation:** A catalog pod is `Evicted` / crashing with "no space left on device" on its node's ephemeral storage, yet `du` on the mount reports the directory is nearly empty. `df` says full, `du` says empty — the classic deleted-but-still-open log file. A rotated log was `unlink`ed while a process still holds the file descriptor, so the blocks are never freed until that fd closes.

**Your task:** Diagnose the `df`/`du` discrepancy, use `lsof` to find the process holding the deleted (unlinked) file open, reclaim the space (release the fd / kill the holder), and confirm `df` drops back down — all without unmounting.

**Project link:** The ephemeral-storage-full failure mode on nodes backing `emptyDir` / the container writable upper layer (S08/S18); teaches that a mount's free space is governed by open fds, not just directory contents (Rung 5 mount reasoning).

**Verify:**
```bash
lsof -n /mnt/lab-node 2>/dev/null | grep -q "(deleted)" || echo "NO DELETED-FILE HOLDER LEFT"  # expected after fix: NO DELETED-FILE HOLDER LEFT
df --output=pcent /mnt/lab-node | tail -1   # expected: well under 100% once the fd is released
```

### Climb 10 — Package Management & the CLI Toolchain

#### 🟢 Scenario 10.1 — "Vientiane: who owns this binary?" (Easy)
**Setup:**
```bash
sudo apt-get update -qq 2>/dev/null || true
command -v jq >/dev/null || sudo apt-get install -y -qq jq 2>/dev/null || true
# pretend a rogue hand-installed copy also exists later; first, audit the apt-managed one
command -v jq git
```
**Situation:** A teammate asks "why is our `terraform` old on this box?" — the answer is always *which install won PATH*. Before touching the fast-moving CLIs, you audit the simple case: for each core tool, is it apt-managed (has an owning package) or a hand-dropped binary?

**Your task:** For `jq` and `git`, print the resolved path (`command -v`) and use `dpkg -S` to report which `.deb` package owns it — or state clearly that it is hand-installed / not apt-managed.

**Project link:** Toolchain audit from Rung 7 Lab 1 — `dpkg -S` answers "where did this binary come from?" (Climb 10, Rung 3/4), the pre-S02 install checklist.

**Verify:**
```bash
dpkg -S "$(command -v git)"   # expected: git: /usr/bin/git  (an owning package line)
dpkg -S "$(command -v jq)" 2>/dev/null || echo "jq not apt-owned (hand-installed?)"  # expected: a package line, or the fallback text
```

#### 🟢 Scenario 10.2 — "Yangon: the binary that shadows its twin" (Easy)
**Setup:**
```bash
sudo mkdir -p /usr/local/bin
# a vendor-dropped kubectl in /usr/local/bin shadows any apt-installed twin in /usr/bin
printf '#!/bin/sh\necho "Client Version: v1.31.0 (vendor /usr/local/bin)"\n' | sudo tee /usr/local/bin/kubectl >/dev/null
printf '#!/bin/sh\necho "Client Version: v1.24.0 (apt /usr/bin)"\n'          | sudo tee /usr/bin/kubectl >/dev/null
sudo chmod +x /usr/local/bin/kubectl /usr/bin/kubectl
```
**Situation:** `kubectl` reports a different version than a colleague on the same image, and `apt` swears it installed v1.24. Two copies exist — one hand-installed in `/usr/local/bin`, one from apt in `/usr/bin` — and PATH order decides the winner. You must prove which one runs and why.

**Your task:** Use `command -v` and `type -a kubectl` to list *both* copies in PATH order, identify which one actually executes, and explain (from PATH ordering) why `/usr/local/bin` wins.

**Project link:** `/usr/local/bin` is the conventional home for hand-installed binaries (kubectl/argocd/istioctl) and sits earlier in PATH than `/usr/bin` — Climb 1's PATH ordering decides shadowing (Climb 10, Rung 3/4).

**Verify:**
```bash
command -v kubectl                       # expected: /usr/local/bin/kubectl (the winner)
type -a kubectl                          # expected: BOTH paths listed, /usr/local/bin first
kubectl 2>/dev/null | grep -q vendor && echo "VENDOR COPY RAN"   # expected: VENDOR COPY RAN
```

#### 🟡 Scenario 10.3 — "Surabaya: your own package, your own repo" (Medium)
**Setup:**
```bash
sudo rm -rf /opt/lab-repo /opt/lab-surabaya
mkdir -p /opt/lab-surabaya/retail-tool_1.0_all/DEBIAN
mkdir -p /opt/lab-surabaya/retail-tool_1.0_all/usr/local/bin
cat > /opt/lab-surabaya/retail-tool_1.0_all/DEBIAN/control <<'EOF'
Package: retail-tool
Version: 1.0
Architecture: all
Maintainer: ops <ops@devopsinminutes.com>
Description: internal retail-store helper CLI
EOF
printf '#!/bin/sh\necho "retail-tool v1.0"\n' > /opt/lab-surabaya/retail-tool_1.0_all/usr/local/bin/retail-tool
chmod +x /opt/lab-surabaya/retail-tool_1.0_all/usr/local/bin/retail-tool
```
**Situation:** The team wants an internal helper CLI baked into the retail-store images reproducibly — not `curl | bash`, but a real signed-able package installed the apt way. You'll build a tiny `.deb`, serve it from a local lab repository, wire it into apt, and inspect it with `apt-cache policy` — all without touching the VM's real repos.

**Your task:** Build `retail-tool_1.0_all.deb` with `dpkg-deb -b`, place it in `/opt/lab-repo`, generate a `Packages` index, register `/etc/apt/sources.list.d/lab-surabaya.list` pointing at the local repo, `apt-get update`, and show `apt-cache policy retail-tool` resolves the 1.0 candidate from your lab origin. Preview the install with `--dry-run` (don't mutate the box's real state beyond the lab list).

**Project link:** The reproducible-package alternative to `curl|bash` for baking tools into Dockerfiles (S03 apt idioms, Rung 6 trust models); `dpkg-deb`/local repo = the apt half of "resolve-verify-place-record".

**Verify:**
```bash
dpkg-deb -I /opt/lab-repo/retail-tool_1.0_all.deb | grep -q "Package: retail-tool" && echo "DEB BUILT"  # expected: DEB BUILT
apt-cache policy retail-tool | grep -q "1.0"    # expected: Candidate 1.0 from the lab repo
```
**Cleanup note:** this scenario adds `/etc/apt/sources.list.d/lab-surabaya.list` — the answer file removes it.

#### 🟡 Scenario 10.4 — "Kuching: the version that must not move" (Medium)
**Setup:**
```bash
sudo apt-get update -qq 2>/dev/null || true
# pick a small, present package to pin; ca-certificates is on every box
PKG=ca-certificates
apt-cache policy "$PKG" | head -3
```
**Situation:** The node AMI / base image must be *reproducible next year* — an unattended `apt-get upgrade` silently bumping a pinned dependency would break the "builds the same in 12 months" guarantee (Rung 6, pinned vs latest). You need to freeze a package at its current version so upgrades skip it, then prove it and lift the hold.

**Your task:** Put `ca-certificates` on hold with `apt-mark hold`, confirm it appears in `apt-mark showhold`, demonstrate with `apt-get upgrade --dry-run` that it is *kept back* (not upgraded), then release it with `apt-mark unhold`.

**Project link:** Version pinning / reproducible images & nodes — `pkg=1.2.3` and holds keep builds reproducible (Climb 10, Rung 4/6).

**Verify:**
```bash
sudo apt-mark hold ca-certificates >/dev/null; apt-mark showhold | grep -q ca-certificates && echo "HELD"  # expected: HELD
apt-get -s upgrade 2>/dev/null | grep -qi "kept back\|held" && echo "UPGRADE SKIPS IT" || echo "nothing to upgrade (still held)"
```

#### 🟠 Scenario 10.5 — "Davao: trust, then install" (Hard)
**Setup:**
```bash
sudo rm -rf /opt/lab-davao; mkdir -p /opt/lab-davao/release; cd /opt/lab-davao/release
# stand in for a vendor kubectl release + its published checksum and signature
printf '#!/bin/sh\necho "kubectl fake release v1.31.0"\n' > kubectl
sha256sum kubectl > kubectl.sha256
# a throwaway signing key acts as the "vendor GPG key"
gpg --batch --quick-generate-key "vendor <vendor@devopsinminutes.com>" default default never 2>/dev/null || true
gpg --batch --yes --output kubectl.sig --detach-sign kubectl 2>/dev/null || true
```
**Situation:** You're installing `kubectl` the vendor-binary way (`curl -LO`, no apt) — which means *you* own the trust step apt would normally do. Before dropping the binary into PATH, you must verify both its checksum and its detached GPG signature (Rung 6: "whose repository, whose signature?"). A corrupted or tampered download must be caught *before* `install`.

**Your task:** Verify `kubectl` against `kubectl.sha256` with `sha256sum -c`, verify `kubectl.sig` against the vendor public key with `gpg --verify`, and only on success `install` it to `/usr/local/bin`. Then tamper one byte and show the checksum verification now fails (install must abort).

**Project link:** The vendor-binary trust model for hand-installed CLIs (kubectl/argocd) — `curl -LO` + checksum/GPG verify + `install` to `/usr/local/bin` (Climb 10, Rung 3/4/6).

**Verify:**
```bash
cd /opt/lab-davao/release && sha256sum -c kubectl.sha256 && echo "CHECKSUM OK"   # expected: kubectl: OK / CHECKSUM OK
gpg --verify kubectl.sig kubectl 2>&1 | grep -qi "Good signature" && echo "SIGNATURE OK"  # expected: SIGNATURE OK
test -x /usr/local/bin/kubectl && echo "INSTALLED"   # expected: INSTALLED (only after both checks passed)
```

#### 🔴 Scenario 10.6 — "Malacca: the resolver vs the file-placer" (Expert)
**Setup:**
```bash
sudo rm -rf /opt/lab-malacca /opt/lab-mrepo
mkdir -p /opt/lab-mrepo
# build a package that DEPENDS on another, to expose the apt-vs-dpkg split
build_deb() {
  d="/opt/lab-malacca/$1"; mkdir -p "$d/DEBIAN" "$d/usr/local/bin"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: ops <ops@devopsinminutes.com>\n%sDescription: %s\n' \
    "$1" "$2" "$3" "$1" > "$d/DEBIAN/control"
  printf '#!/bin/sh\necho "%s %s"\n' "$1" "$2" > "$d/usr/local/bin/$1"; chmod +x "$d/usr/local/bin/$1"
  dpkg-deb -b "$d" "/opt/lab-mrepo/$1_$2_all.deb" >/dev/null
}
build_deb retail-lib 1.0 ""
build_deb retail-app 2.0 "Depends: retail-lib (>= 1.0)\n"
ls /opt/lab-mrepo
```
**Situation:** Baking the retail-store toolchain into an image, a `dpkg -i retail-app.deb` fails with "dependency problems — retail-lib is not installed", while the *same* package installs cleanly through apt. This is the Rung 3 two-layer truth made painful: `dpkg` only places files, `apt` resolves the graph. You'll reproduce the unmet-dependency failure, then fix it two ways (the apt resolver, and `apt-get install -f`), and map it to why Dockerfiles chain `apt-get update && apt-get install` in one layer-cached RUN.

**Your task:** (1) Show `dpkg -i /opt/lab-mrepo/retail-app_2.0_all.deb` fails on the missing `retail-lib` dependency. (2) Publish `/opt/lab-mrepo` as a local apt repo (`apt-ftparchive`/`dpkg-scanpackages` + `sources.list.d/lab-malacca.list`), then `apt-get install retail-app` and watch apt pull in `retail-lib` automatically. (3) State in one line how this maps to the Dockerfile `update && install` single-RUN idiom and its stale-index / layer-cache reasoning.

**Project link:** The `apt` (resolver) over `dpkg` (file-placer) two-layer machinery and the Dockerfile single-RUN `update && install` idiom respecting layer cache (S03, Climb 10 Rung 3/5 + Climb 9 cache).

**Verify:**
```bash
dpkg -i /opt/lab-mrepo/retail-app_2.0_all.deb 2>&1 | grep -qi "depend" && echo "DPKG ALONE FAILS (unmet dep)"  # expected: DPKG ALONE FAILS (unmet dep)
command -v retail-lib >/dev/null && command -v retail-app >/dev/null && echo "APT RESOLVED BOTH"   # expected after fix: APT RESOLVED BOTH
```
**Cleanup note:** adds `/etc/apt/sources.list.d/lab-malacca.list` and installs `retail-app`/`retail-lib` — the answer file removes all three.



---

## 🔑 Lab Answers — Solutions & Explanations

> Attempt each scenario above with the **Verify** command before reading these. Each solution explains not just *what* to type but *why it works* — tying the fix back to the climb's machinery and to the specific Retail-Store project artifact it mirrors.

### Climb 1 — Shell, Environment Variables & PATH

#### Scenario 1.1 — "Austin: the variable that vanished between two shells"
**Solution:**
```bash
cd /opt/lab-austin
source ./.env          # DB_PASSWORD is now a *shell* variable in THIS shell only
export DB_PASSWORD     # promote it to an *environment* variable so children inherit it
./launch-stack.sh      # child fork now carries DB_PASSWORD → "started with password 'retail-dev-101'"
# one-liner alternative that never touches the files:
#   cd /opt/lab-austin && set -a && source ./.env && set +a && ./launch-stack.sh
```
**Why this works & what it teaches:** `source ./.env` sets a *shell variable* — visible to `echo` in the current shell, but a plain shell variable is NOT copied into the environment block that a `fork`/`exec` hands to a child, so the launcher (a child process, exactly like `docker compose`) sees it empty. `export` moves the name into the process's environment table, which is the only thing inherited across a fork. This is S04's `RETAIL_CATALOG_PERSISTENCE_PASSWORD: ${DB_PASSWORD}` trap verbatim: forget the export and every DB container crash-loops on an empty password even though your terminal echoes the value. Where people go wrong: they "prove" the value exists with `echo` (same shell) instead of `bash -c 'echo $VAR'` (a child, the real test).

---

#### Scenario 1.2 — "Denver: the impostor first on the PATH"
**Solution:**
```bash
type -a retailctl                 # shows BOTH, in verdict order: stale-bin first → that's why v1.2.0 answers
export PATH="/opt/lab-denver/new-bin:/opt/lab-denver/stale-bin:${PATH#*/opt/lab-denver/stale-bin:/opt/lab-denver/new-bin:}"
hash -r                           # forget bash's cached path→binary mapping for retailctl
retailctl                         # now: retailctl v2.0.0
type -a retailctl | head -1       # retailctl is /opt/lab-denver/new-bin/retailctl
```
**Why this works & what it teaches:** PATH is searched strictly left-to-right and the *first* match wins; `stale-bin` was prepended before `new-bin`, so v1.2.0 always answered even though v2.0.0 was on disk, executable, and on PATH. Putting `new-bin` ahead of `stale-bin` flips the verdict, and `hash -r` matters because bash caches the resolved location of a command after first use — without clearing the hash table, bash would keep executing the old path until the cache expired. This is the S06/S07 two-binaries bite: a hand-downloaded `terraform`/`kubectl` next to a package-manager copy. Where people go wrong: reaching for `which` (which may consult its own logic) instead of `type -a`, which shows bash's actual resolution order.

---

#### Scenario 1.3 — "Portland: the process that was born with the old password"
**Solution:**
```bash
# (1) forensic proof: read the RUNNING process's frozen environment copy
tr '\0' '\n' < /proc/$(cat /tmp/lab-portland.pid)/environ | grep '^DB_PASSWORD='
#   → DB_PASSWORD=old-LEAKED-secret   (lives ONLY in the live process, in no file with that value)
# (2) the ONLY verb that re-reads .env and re-injects env is recreate:
/opt/lab-portland/stackctl recreate
sleep 3
tail -1 /tmp/lab-portland-auth.log   # → auth attempt with password: rotated-NEW-secret
```
**Why this works & what it teaches:** A process's environment is a copy made at `exec` time; `stackctl stop` just sends a signal and `stackctl start` re-launches from the *frozen* `/tmp/lab-portland.frozen-env` snapshot, so neither ever re-reads `.env` — the old value survives in the process's `/proc/<pid>/environ` and nowhere on disk. Only `recreate` deletes the frozen snapshot and rebuilds it from `.env`, which is why it alone picks up the rotation. This is S04's core lesson: `docker compose stop ui && start ui` keeps the old env because env is baked in at *container creation*; only `docker compose up -d --force-recreate` re-reads the YAML. **Cleanup:** `/opt/lab-portland/stackctl stop` to kill the leftover background auth loop.

---

#### Scenario 1.4 — "Seattle: the tag that never crossed the step boundary"
**Solution:**
```bash
# Fix ONLY 10-build.sh: write the tag to the $GITHUB_ENV *file* the runner re-reads between steps
sudo tee /opt/lab-seattle/steps/10-build.sh >/dev/null <<'EOF'
#!/bin/bash
GITHUB_SHA=4f7c2a19b8e0d3c6a5f41e2d9b8c7a6f5e4d3c2b
TAG="sha-${GITHUB_SHA::7}"
echo "TAG=$TAG" >> "$GITHUB_ENV"       # the real hand-off: append to the runner's env file
echo "built image retail-ui:$TAG"
EOF
sudo chmod +x /opt/lab-seattle/steps/10-build.sh
/opt/lab-seattle/runner.sh             # → kubectl set image ... :sha-4f7c2a1 / workflow succeeded
```
**Why this works & what it teaches:** `export` only propagates *downward* to child processes; step 10 and step 20 are **sibling** shells the runner spawns one after another, so an exported var in step 10 dies with step 10's process and can never reach its sibling. The runner re-reads `$GITHUB_ENV` (a file) before each step, so persisting the tag there is the only mechanism that crosses the boundary — exactly S21's `echo "TAG=sha-${GITHUB_SHA::7}" >> $GITHUB_ENV`. Where people go wrong: "but I exported it!" — export is mechanically incapable of reaching a sibling; the shared *file* is the channel.

---

#### Scenario 1.5 — "Boise: it works in my terminal, not in the runner"
**Solution:**
```bash
# (1) print the three PATHs and see where each comes from:
echo "interactive : $PATH"                                   # from ~/.bashrc export
env -i /bin/bash -c 'echo "clean-env   : $PATH"'             # bash compiled-in default
sudo sh -c 'echo "sudo        : $PATH"'                      # secure_path in /etc/sudoers
# (2) the one dir all three already contain is /usr/local/bin — install the tool there:
sudo ln -sf /opt/lab-boise/bin/deployctl /usr/local/bin/deployctl
deployctl
env -i /bin/bash -c 'deployctl'
sudo deployctl                                               # all three now succeed
```
**Why this works & what it teaches:** The three callers each build PATH from a different source — your interactive shell reads `~/.bashrc`, a non-interactive clean shell uses bash's compiled-in default, and sudo replaces PATH with `secure_path` from sudoers — and only your interactive PATH held `/opt/lab-boise/bin`. `/usr/local/bin` is on *all three* PATHs by convention, so installing (symlinking) the tool there makes every caller find it without editing sudoers or the runner. This is the S21 classic "the workflow can't find `helm` but my laptop can" and the S19 `sudo ./create-cluster...` variant. **Cleanup:** `sudo rm -f /usr/local/bin/deployctl` and drop the `lab-boise` line from `~/.bashrc` if you want the box pristine.

---

#### Scenario 1.6 — "Tucson: the password the shell ate a piece of"
**Solution:**
```bash
# (1) proof the file is perfect: cat -A /opt/lab-tucson/.env  → DB_PASSWORD=S3cur3$tore!9$
#     The culprit is:  eval "export $(cat .../.env)"  — eval RE-EXPANDS the line, so $tore
#     (an unset var) expands to nothing, turning S3cur3$tore!9 into S3cur3!9.
# (2) rewrite launch.sh with a byte-safe loader: no eval, no word-splitting, no re-expansion
sudo tee /opt/lab-tucson/launch.sh >/dev/null <<'EOF'
#!/bin/bash
# byte-safe .env loader: read each line raw, split on the FIRST '=', export literally
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in \#*) continue;; esac
  key=${line%%=*}
  val=${line#*=}
  export "$key=$val"           # value is assigned literally — the shell never re-expands $tore
done < /opt/lab-tucson/.env
exec /opt/lab-tucson/mysqld-stub.sh
EOF
sudo chmod +x /opt/lab-tucson/launch.sh
/opt/lab-tucson/launch.sh              # → password accepted
env -i /opt/lab-tucson/launch.sh       # → same success from a clean environment
# (3) In docker-compose.yml, escape the literal $ by DOUBLING it:
#       environment:
#         DB_PASSWORD: "S3cur3$$tore!9"     # Compose interpolation turns $$ back into one $
```
**Why this works & what it teaches:** `eval` runs its argument through a *second* full pass of shell parsing and expansion, so `$tore` (undefined) silently vanished — five bytes gone with no error. The `while IFS= read -r` loader reads each line verbatim (`-r` keeps backslashes, no `$IFS` splitting on the value) and assigns via `export "$key=$val"`, where the RHS is a literal string that is never re-expanded, so every byte in `.env` arrives intact. This is the same class of bug as S04 Compose interpolation eating a literal `$` unless it's written as `$$`. Where people go wrong: `eval`, `export $(cat .env)`, and bare `source` all subject the *value* to expansion; only a raw read-and-assign is byte-safe.

---

### Climb 2 — Filesystem, Paths & "Everything Is a File"

#### Scenario 2.1 — "Omaha: kubectl is answering from the wrong file"
**Solution:**
```bash
echo "KUBECONFIG=[${KUBECONFIG:-<unset>}]"   # 3-second diagnosis: an env var beats the dotfile
unset KUBECONFIG                             # stop pointing kubectl at last week's dead cluster
kctl get pods                                # → answering from .../home/.kube/config (retail-dev), Running
```
**Why this works & what it teaches:** `kubectl` (and this stub) resolve their config in a fixed order — `$KUBECONFIG` first, and only if unset do they fall back to the conventional `~/.kube/config`. A forgotten `export KUBECONFIG=...stale...` therefore silently overrides the fresh, correct dotfile that `aws eks update-kubeconfig` wrote. Fixing it is fixing a *file lookup*, not restarting a daemon: `unset KUBECONFIG` restores the fallback. This is S07 exactly, and `echo "${KUBECONFIG:-<unset>}"` belongs in your runbook — it diagnoses "kubectl is talking to the wrong cluster" in one line.

---

#### Scenario 2.2 — "Fresno: the log file nobody can find"
**Solution:**
```bash
pid=$(cat /tmp/lab-fresno.pid)
readlink /proc/$pid/cwd                       # → /tmp/lab-fresno/.cache/run  (where it was LAUNCHED)
ls -l /proc/$pid/fd | grep orders.log         # confirms the open fd's absolute target
tail -f /proc/$pid/cwd/orders.log             # growing tail of the live log, no find, no restart
```
**Why this works & what it teaches:** The script wrote to the *relative* path `orders.log`, and a relative path resolves against the **process's current working directory**, not the script's location — and that cwd is a fact of the *process* (the `cd` its launcher did), frozen at exec, readable at `/proc/<pid>/cwd`. `/proc/<pid>/fd` even shows the open file descriptor pointing at the exact absolute path, so you never need `find`. This is Climb 2's `/proc` forensics doing real work — the same window that answers "where is this container actually writing?" (S02). **Cleanup:** `kill $(cat /tmp/lab-fresno.pid)` to stop the background writer.

---

#### Scenario 2.3 — "Tulsa: COPY says the file is not there, and it is right"
**Solution:**
```bash
cd /opt/lab-tulsa/retail-ui                                   # the repo root = the build context
sudo docker build -t lab-tulsa-ui -f docker/Dockerfile .     # context is '.', Dockerfile via -f
sudo docker run --rm lab-tulsa-ui                            # → console.log("retail ui")
```
**Why this works & what it teaches:** `COPY` paths resolve against the **build context** — the directory tree the client tars up and ships to the daemon (the final `.` argument) — never against your shell's cwd, and `../` can never escape the context because those files were never shipped. Building from `docker/` made the context `docker/`, which has no `src/`; building from the repo root with `-f docker/Dockerfile .` ships `src/` into the context so `COPY src/ /app/` resolves. This is S03's single most common "works on my machine, fails in CI" build error, since CI builds from the repo root. Where people go wrong: "fixing" it with `COPY ../src/` — which Docker rejects as a path outside the context.

---

#### Scenario 2.4 — "Reno: is it the mount, or is it the injection?"
**Solution:**
```bash
# Localize with two file reads:
mount | grep lab-reno-tmpfs                                   # mount hop: the tmpfs graft is present
cat /opt/lab-reno/secrets-store/db-password; echo            # mount hop delivered: catalog-Passw0rd
tr '\0' '\n' < /proc/$(cat /tmp/lab-reno.pid)/environ | grep RETAIL_CATALOG   # → EMPTY = injection broke
# Verdict: mount OK, INJECTION hop is broken. Fix = recreate the process with env FROM the file:
kill "$(cat /tmp/lab-reno.pid)" 2>/dev/null
export RETAIL_CATALOG_PERSISTENCE_PASSWORD="$(cat /opt/lab-reno/secrets-store/db-password)"
nohup /opt/lab-reno/catalog-app.sh >/dev/null 2>&1 &
echo $! > /tmp/lab-reno.pid
sleep 3; tail -1 /tmp/lab-reno-app.log                       # → connected to catalog-db
```
**Why this works & what it teaches:** "The app can't find its password" hides two independent hops — the CSI driver *mounts* the secret as a file, and a Secret is *injected* into env via `secretKeyRef`. Reading exactly two files cuts the problem in half: the mounted file proves the mount hop delivered, and `/proc/<pid>/environ` proves the injection hop did not. The fix recreates the process with its env populated from the mounted file — env is fixed at exec, so an already-running process can't be patched, only relaunched. This is the S09/S14 debug flow verbatim: `kubectl exec -- cat /mnt/secrets-store/...` vs `kubectl exec -- tr '\0' '\n' < /proc/1/environ`. **Cleanup:** `kill $(cat /tmp/lab-reno.pid)`.

---

#### Scenario 2.5 — "Boulder: no space left on a disk that is 90% empty"
**Solution:**
```bash
df -i /opt/lab-boulder/var-lib-docker          # THE discriminator: IUse% is 100% while bytes are ~10%
# inodes are exhausted — each of the thousands of tiny layer files consumed one inode, not bytes.
# find where the inodes went by COUNTING FILES (not bytes — du would mislead):
sudo rm -f /opt/lab-boulder/var-lib-docker/overlay2/layer-*    # free the inodes
df -i /opt/lab-boulder/var-lib-docker | awk 'NR==2{print "inodes in use:", $5}'
sudo touch /opt/lab-boulder/var-lib-docker/pull.tmp && echo "WRITE-OK"
```
**Why this works & what it teaches:** A filesystem has two independent budgets — data blocks (bytes) and **inodes** (one per file/dir, allocated at `mkfs` time and fixed). An inode holds a file's metadata; ten thousand *empty* files consume zero bytes but ten thousand inodes, so the disk can be 90% empty on `df -h` yet 100% full on `df -i`, and every new create fails with `No space left on device`. Deleting a *big* file frees bytes, not inodes — you must delete *many* files. The real version is `/var/lib/docker`/overlay2 on a build host or EKS node going `DiskPressure` with gigabytes free; `df -i` is the discriminator and `docker system prune` the production cleanup. **Cleanup:** `sudo umount /opt/lab-boulder/var-lib-docker`.

---

#### Scenario 2.6 — "Savannah: the config updated everywhere except where the app looks"
**Solution:**
```bash
ls -la /opt/lab-savannah/kubelet/ui-config/          # see ..data → timestamped dir, ui.properties → ..data/...
findmnt --target /opt/lab-savannah/app/config        # witness: source is stale-snapshot (a bind COVER)
sudo umount /opt/lab-savannah/app/config             # remove the frozen debug snapshot cover
sudo mount --bind /opt/lab-savannah/kubelet/ui-config /opt/lab-savannah/app/config   # track the live volume
cat /opt/lab-savannah/app/config/ui.properties       # → theme=orange
findmnt -n -o SOURCE --target /opt/lab-savannah/app/config   # → source ends [/opt/.../kubelet/ui-config]
```
**Why this works & what it teaches:** kubelet updates a projected volume by writing a *new* timestamped dir, pointing a `..data.tmp` symlink at it, then `rename()`-ing it over `..data` — a single atomic syscall, so a reader following `ui.properties → ..data/ui.properties` sees only the old *or* the new version, never a torn half-write. The app was frozen because a stale `mount --bind` of a *copy* **covered** its config path: a bind mount overlays the directory so the app reads the snapshot's bytes, bypassing the `..data` flip entirely. Re-binding the real projected-volume directory makes the app follow the live symlink, so future atomic flips propagate. This is precisely why S08 ConfigMap volumes update live but **`subPath` mounts never do** — a subPath bind-mounts the resolved directory of the moment. **Cleanup:** `sudo umount /opt/lab-savannah/app/config`.

---

### Climb 3 — Permissions, Ownership & the Non-Root Container

#### Scenario 3.1 — "Asheville: the script you just wrote refuses to run"
**Solution:**
```bash
chmod +x /opt/lab-asheville/create-cluster.sh    # the one-command ritual every course script needs
/opt/lab-asheville/create-cluster.sh             # now runs
umask                                            # → 0022, which is why the file was born 644
```
**Why this works & what it teaches:** `./create-cluster.sh` asks the kernel to `exec` *that file*, so it checks the execute bit on `create-cluster.sh` — which was `644` (no `x`) → `Permission denied`. `bash create-cluster.sh` instead asks the kernel to exec `/usr/bin/bash` (which has `x`) and merely *reads* the script as data, so no execute bit on the script is required. Files from `git clone`/an editor are born `644` because `umask 022` strips the `x` bits from the default `666` — the execute bit is a deliberate opt-in. This is S19 verbatim: `chmod +x create-cluster-with-karpenter.sh` before the first run.

---

#### Scenario 3.2 — "Wichita: the right file, the wrong triplet"
**Solution:**
```bash
id labuser1                                       # only its own group → matches OTHER triplet (---) → denied
sudo usermod -aG labapp labuser1                  # fsGroup-style: give the identity the file's group
sudo -u labuser1 cat /opt/lab-wichita/db-password # → catalog-Passw0rd  (fresh session picks up the new gid)
```
**Why this works & what it teaches:** The kernel picks **one** triplet by first match: uid 10001 ≠ owner `root`, so the owner triplet is skipped; then it checks group membership — `labuser1` was not in `labapp`, so it fell through to the `other` triplet (`---`) and was denied, even though the *group* triplet plainly showed `r--`. Adding `labuser1` to `labapp` makes the group check match, so the `r--` group triplet applies — no `chmod` widening `other`, no `chown`. This is S08's `fsGroup: 1000`: don't loosen the file, give the process's identity a matching gid. The exclusive-match rule is why `chmod 044` denies even the owner — the owner triplet (`---`) matches first and the kernel never consults group/other.

---

#### Scenario 3.3 — "Anchorage: the file is readable, the doorway is not"
**Solution:**
```bash
sudo chmod 701 /opt/lab-anchorage/secrets          # +x for other = traverse; no r = can't list
sudo -u labuser1 cat /opt/lab-anchorage/secrets/token.txt   # → api-token-8842 (traverse by full path OK)
sudo -u labuser1 ls  /opt/lab-anchorage/secrets             # → Permission denied (no r = no enumerate)
```
**Why this works & what it teaches:** To reach a file the kernel walks *every* directory in the path and demands **`x` (traverse)** on each; the `700` secrets dir gave `labuser1` (in the `other` triplet) no `x`, so the walk died at the doorway even though the file itself is `644`. Granting `701` adds only the single missing traverse bit for `other` — `labuser1` can now `cat` the file *by its known full path* but still can't `ls` it, because directory **`r` (list names)** and directory **`x` (pass through)** are independent. This is the classic secrets-dir posture S09 relies on: pods traverse into `/mnt/secrets-store` to read known filenames while listing stays locked. Where people go wrong: `chmod -R` or `755` — either leaks the listing.

---

#### Scenario 3.4 — "Fargo: the non-root container that cannot write its volume"
**Solution:**
```bash
sudo chgrp 10001 /opt/lab-fargo/data          # group-own to a gid the container's process has
sudo chmod 2775  /opt/lab-fargo/data          # group +w AND setgid so new files inherit gid 10001
sudo docker run --rm --user 10001:10001 -v /opt/lab-fargo/data:/data alpine:3.19 \
  sh -c 'echo hello > /data/orders.db && ls -ln /data/orders.db'   # write succeeds, file gid 10001
```
**Why this works & what it teaches:** uid 10001 owns nothing here — `/opt/lab-fargo/data` is `root:root 755`, so the process matches the `other` triplet (`r-x`, no `w`) and the write dies. Group-owning the directory to gid 10001 and granting the group `w` makes uid 10001 (whose gid is 10001) match the *group* triplet with write; the **setgid** bit (`2` in `2775`) makes every new file inherit the directory's group, so `orders.db` is born gid 10001 too. That is exactly what `fsGroup: 1000` does — kubelet chowns/chmods the mounted volume at pod start so the `runAsUser` app can write it — with no root and no `chmod 777`. **Cleanup:** `sudo rm -f /opt/lab-fargo/data/orders.db`.

---

#### Scenario 3.5 — "Spokane: two services, one shared volume, one loses every time"
**Solution:**
```bash
command -v setfacl >/dev/null || sudo apt-get install -y acl
# mechanism 1 — setgid: forces the GROUP of every new file to labshare
sudo chmod g+s /opt/lab-spokane/shared
# mechanism 2 — default ACL: forces the PERMISSIONS of every new file (overrides each user's umask)
sudo setfacl -d -m u::rwx,g::rwx,o::r-x /opt/lab-spokane/shared
# heal the one existing casualty by hand:
sudo chgrp labshare /opt/lab-spokane/shared/queue.txt
sudo chmod g+rw     /opt/lab-spokane/shared/queue.txt
# prove it self-heals for NEW files (no cron, no post-hoc chmod, no umask coordination):
sudo -u labuser1 bash -c 'umask 022; echo "batch-3" > /opt/lab-spokane/shared/new.txt'
sudo -u labuser2 bash -c 'echo "batch-4" >> /opt/lab-spokane/shared/new.txt' && echo "CART-WROTE-OK"
```
**Why this works & what it teaches:** The two properties `cart` needs are controlled by two *different* mechanisms. The **setgid bit** on the directory decides the *group* of new files (labshare, not the creator's private group), so both services land in the shared group. A **default ACL** decides the *permissions* of new files and overrides each process's umask, so even `catalog`'s `umask 022` can't strip group-write — files are born group-writable. Neither alone suffices, which is why the cron `chown -R` band-aid always loses the race against files created between runs. This is S10's ReadWriteMany/EFS shared-volume race: `fsGroup` fixes each pod's mount-time ownership, but files two apps create *for each other* need setgid + default ACLs on the volume — the on-disk equivalent of an EFS access point's enforced gid.

---

#### Scenario 3.6 — "Lubbock: rebuild the hardened pod on a bare VM"
**Solution:**
```bash
# FIX 1 — entrypoint has no exec bit: fix it in the IMAGE (writable side); appears through the ro mount.
#   K8s knob: a `RUN chmod +x` line in the Dockerfile (S03).
sudo chmod +x /opt/lab-lubbock/image/app/entrypoint.sh
# FIX 2 — secret unreadable by uid 10003: group it to labuser3's gid, mode 0440 (not the user, not 644).
#   K8s knobs: fsGroup + the volume's defaultMode (S08/S09).
sudo chgrp "$(id -g labuser3)" /opt/lab-lubbock/rootfs/secrets/db-password
sudo chmod 0440 /opt/lab-lubbock/rootfs/secrets/db-password
# FIX 3 — cache write dies on the read-only rootfs: graft a writable tmpfs over EXACTLY rootfs/tmp.
#   K8s knob: an emptyDir volume mounted at /tmp.
sudo mount -t tmpfs -o size=1m lab-lubbock-tmp /opt/lab-lubbock/rootfs/tmp
# drive it to a clean start and prove the hardening survived everywhere else:
sudo -u labuser3 /opt/lab-lubbock/rootfs/app/entrypoint.sh
sudo -u labuser3 touch /opt/lab-lubbock/rootfs/app/hack   # still: Read-only file system
```
**Why this works & what it teaches:** Three independent permission mechanisms fail in sequence, each fixed without breaking the hardening. (1) The execute bit is a property of the file — fixing it on the writable image side shows through the ro bind mount because it's the *same inode*, so you never write through the read-only view. (2) The `0400` root-owned secret is invisible to uid 10003 until you group it to a gid the process carries and open the *group* read bit to `0440` — the `fsGroup` + `defaultMode` move, never `chmod 644`. (3) `readOnlyRootFilesystem` blocks the cache write until you overlay a writable tmpfs on just `/tmp`, leaving the rest immutable — an `emptyDir` at `/tmp`. Together these are S08's entire `securityContext` block rebuilt out of `mount`/`chmod`/`chgrp`. **Cleanup:** `sudo umount /opt/lab-lubbock/rootfs/tmp /opt/lab-lubbock/rootfs/secrets /opt/lab-lubbock/rootfs`.


### Climb 4 — Processes, Signals & PID 1

#### Scenario 4.1 — "Tampere: the container that ignored its shutdown notice"
**Solution:**
```bash
# Observe first: the 10s hang and exit=137 (128 + 9, SIGKILL) because app.sh ignores SIGTERM.
sudo /opt/lab-tampere/vm-stop.sh /opt/lab-tampere/app.sh   # before fix: escalates to SIGKILL, exit=137
# Fix app.sh: install a SIGTERM handler that says goodbye and exits 0 promptly.
sudo tee /opt/lab-tampere/app.sh >/dev/null <<'EOF'
#!/bin/bash
graceful() { echo "checkout-app: SIGTERM received — draining, goodbye"; exit 0; }
trap graceful TERM
echo "checkout-app: serving (pid $$)"
while true; do sleep 1 & wait $!; done   # wait makes the trap fire immediately, not after sleep
EOF
sudo chmod +x /opt/lab-tampere/app.sh
sudo /opt/lab-tampere/vm-stop.sh /opt/lab-tampere/app.sh   # → goodbye line, "stopped in 0s, exit=0"
```
**Why this works & what it teaches:** The orchestrator's stop is SIGTERM → grace period → SIGKILL; the original app trapped-and-ignored TERM, so it survived the grace window and was killed with signal 9, yielding exit `128 + 9 = 137`. Installing a real TERM handler that exits 0 lets it stop *immediately and cleanly*. The `sleep 1 & wait $!` pattern matters: a bare `sleep 1` blocks the shell so the trap only runs after it returns, whereas `wait` is interruptible and fires the handler at once. This is `docker stop` in S02 taking exactly 10s and every slow `kubectl delete pod`: SIGTERM → `terminationGracePeriodSeconds` → SIGKILL → 137 in `kubectl describe`.

---

#### Scenario 4.2 — "Turku: the port-forward nobody remembered starting"
**Solution:**
```bash
sudo ss -ltnp 'sport = :8445'                                     # find the listener + its pid=
pid=$(sudo ss -ltnpH 'sport = :8445' | grep -oP 'pid=\K[0-9]+' | head -1)
ps -o pid,ppid,user,etime,cmd -p "$pid"                           # PPID is 1 — it was re-parented to init
kill -TERM "$pid"                                                  # polite stop, frees the port
ss -ltn | grep 8445 || echo "port 8445 free"
```
**Why this works & what it teaches:** The forwarder was launched with `setsid` in a subshell and its terminal closed, so when its original parent died the kernel **re-parented the orphan to PID 1** (init) — that's why `ps` shows PPID 1 even though a human started it. `ss -ltnp` maps the listening socket back to the owning pid, and a plain `kill -TERM` (never `-9`) lets it release port 8445 cleanly. This is S21's `kubectl port-forward svc/argocd-server 8080:443 &` failure mode — backgrounded, forgotten, orphaned. A process a shell reaps after TERM reports `128 + 15 = 143`, exactly what a gracefully terminated pod shows in `kubectl describe`.

---

#### Scenario 4.3 — "Aarhus: the wrapper that ate the SIGTERM"
**Solution:**
```bash
# One-word fix: exec the app so it REPLACES the wrapper shell and becomes the signal target.
sudo tee /opt/lab-aarhus/entrypoint.sh >/dev/null <<'EOF'
#!/bin/bash
echo "entrypoint: warming cache…"
sleep 1
echo "entrypoint: starting app"
exec /opt/lab-aarhus/app.sh          # <-- added "exec"
EOF
sudo chmod +x /opt/lab-aarhus/entrypoint.sh
pkill -f /opt/lab-aarhus/app.sh 2>/dev/null   # reap any orphan from earlier reproduction
```
**Why this works & what it teaches:** Without `exec`, the wrapper shell stays alive as the parent and `app.sh` runs as its child; SIGTERM is delivered to the *wrapper* (the process the orchestrator signals), and a bash script running a foreground child does not forward the signal, so the app never sees it and is orphaned when the wrapper dies. `exec` replaces the wrapper process image with `app.sh` in the *same PID*, so the app itself becomes the signal target and its handler runs. This is exactly why the retail-store Dockerfiles (S03) insist on **exec-form** `CMD ["app"]`: shell-form `CMD app` makes `/bin/sh` PID 1, and sh doesn't forward SIGTERM, so every `docker stop` waits out the full grace period into a 137. **Cleanup:** the `pkill` line above.

---

#### Scenario 4.4 — "Odense: the service that restarts every two seconds"
**Solution:**
```bash
journalctl -u lab-odense -n 20 --no-pager     # root cause: "LISTEN_PORT is required" → var never set
# the env file has a typo: LISTEN_PROT (should be LISTEN_PORT) — one character
sudo sed -i 's/^LISTEN_PROT=/LISTEN_PORT=/' /opt/lab-odense/env
sudo systemctl restart lab-odense
systemctl is-active lab-odense                # → active
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8410/   # → 200
```
**Why this works & what it teaches:** systemd's `Restart=always` faithfully re-launches PID 1 every time it exits, and the script exits instantly because `: "${LISTEN_PORT:?...}"` aborts when `LISTEN_PORT` is unset — the `EnvironmentFile` defined `LISTEN_PROT` (transposed letters), so the required variable never arrived and the service crash-looped with `RestartSec=2` backoff. Fixing the one-character typo lets the guard pass and the server bind. This is `CrashLoopBackOff` with the costume off: `Restart=always` ≈ kubelet, `RestartSec` ≈ the backoff timer, and `journalctl -u` is your `kubectl logs --previous`. **Cleanup:** `sudo systemctl stop lab-odense && sudo systemctl disable lab-odense`.

---

#### Scenario 4.5 — "Trondheim: the checkout counter full of ghosts"
**Solution:**
```bash
sudo pkill -f checkout-counter.py             # stop the non-reaping parent
sudo tee /opt/lab-trondheim/checkout-counter.py >/dev/null <<'EOF'
#!/usr/bin/env python3
"""checkout-counter: forks a receipt-printer child per sale AND reaps it."""
import os, signal, time

def reap(signum, frame):
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)   # collect any/all finished children
        except ChildProcessError:
            break
        if pid == 0:
            break

signal.signal(signal.SIGCHLD, reap)               # reap on child-exit notifications
print(f"checkout-counter up (pid {os.getpid()})", flush=True)
n = 0
while True:
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    n += 1
    print(f"receipt #{n} printed by pid {pid}", flush=True)
    time.sleep(1)
EOF
sudo unshare --pid --fork --mount-proc \
  python3 /opt/lab-trondheim/checkout-counter.py >/tmp/lab-trondheim.log 2>&1 &
```
**Why this works & what it teaches:** A **zombie** is a process that has exited but whose exit status the kernel still keeps in the process table because the *parent has not `wait()`ed* for it — it holds no memory and can't be killed, because `kill -9` signals a *running* process and a zombie is already dead; only the parent reaping it (or the parent dying) clears it. On a normal box init reaps orphans, but here the counter is **PID 1 of its own PID namespace** — exactly a container's entrypoint — so nothing above it reaps, and unreaped children pile up. Installing a `SIGCHLD` handler that loops `os.waitpid(-1, WNOHANG)` collects every finished child immediately. This is why `tini`, `docker run --init`, and `shareProcessNamespace` exist: PID 1 must reap, or the node fills with defunct entries until the pid cgroup limit trips. **Cleanup:** `sudo pkill -f checkout-counter.py`.

---

#### Scenario 4.6 — "Stavanger: the rolling update that dropped the shopping carts"
**Solution:**
```bash
# rollout-bad drops requests three ways: (1) kill -9 severs v1 mid-request (in-flight lost),
# (2) it routes to 8462 before v2 finishes its 3s warm-up (connection refused),
# (3) it points endpoints at 8462 while v2 isn't bound yet (routing-before-ready).
# rollout-good does it the Kubernetes way: start → readiness-gate → add → remove old → drain → TERM.
cat > /tmp/lab-stavanger/rollout-good.sh <<'EOF'
#!/bin/bash
set -euo pipefail
RUN=/tmp/lab-stavanger
# 1) start v2 but do NOT route to it yet
python3 /opt/lab-stavanger/worker.py 8462 v2 >>"$RUN/worker.log" 2>&1 &
echo $! > "$RUN/worker-8462.pid"
# 2) readiness gate: wait until v2's /healthz answers (past the 3s warm-up, port bound)
until curl -fsS --max-time 1 http://127.0.0.1:8462/healthz >/dev/null 2>&1; do sleep 0.2; done
# 3) add v2 to endpoints ATOMICALLY (both serving) — write temp, mv over
printf '8461\n8462\n' > "$RUN/endpoints.tmp"; mv -f "$RUN/endpoints.tmp" "$RUN/endpoints"
# 4) remove v1 from endpoints ATOMICALLY — stop routing to it BEFORE killing it
printf '8462\n' > "$RUN/endpoints.tmp"; mv -f "$RUN/endpoints.tmp" "$RUN/endpoints"
# 5) grace window so any in-flight v1 request finishes
sleep 1
# 6) SIGTERM v1 (graceful drain) and wait for its clean exit — never kill -9
v1=$(cat "$RUN/worker-8461.pid")
kill -TERM "$v1"
while kill -0 "$v1" 2>/dev/null; do sleep 0.1; done
echo "rollout-good: v2 live, v1 drained cleanly"
EOF
chmod +x /tmp/lab-stavanger/rollout-good.sh
```
**Why this works & what it teaches:** Zero-drop rollout reorders the same ingredients so traffic only ever points at a *ready* endpoint and a dying endpoint is *drained*, not murdered. The readiness gate on `/healthz` refuses to route until v2 has bound its port past the warm-up (kills drop #2 and #3); removing v1 from the routing table *before* SIGTERM, plus a grace window and waiting for its clean exit, means no request is ever sent to a process that's about to die (kills drop #1). Writing the endpoints file via `write-temp + mv` makes each update atomic, so `load.sh` never reads a half-written table. This is S21's rolling update pod-by-pod: readiness probes gate EndpointSlice membership, the dying pod is removed from endpoints *and* SIGTERMed, and `terminationGracePeriodSeconds` is the grace window — `dropped=0` is "V904 with zero dropped requests." **Cleanup:** `pkill -f lab-stavanger/worker.py; rm -rf /tmp/lab-stavanger`.

---

### Climb 5 — Shell Scripting: the Automation Muscle

#### Scenario 5.1 — "Uppsala: the commit message that split in two"
**Solution:**
```bash
# git commit -m $1 received TWO args: "-m", "V904" and then "commit" as a pathspec → error.
# Fix: quote the expansion so the whole message stays one argument.
cat > /tmp/lab-uppsala/repo/git-push.sh <<'EOF'
#!/bin/bash
git add -A
git commit -m "$1"        # <-- the one pair of characters: quotes around $1
git push origin main
EOF
chmod +x /tmp/lab-uppsala/repo/git-push.sh
cd /tmp/lab-uppsala/repo && echo V904 > version.txt && ./git-push.sh "V904 commit"
```
**Why this works & what it teaches:** An unquoted `$1` undergoes **word-splitting**: `V904 commit` was split on the space into two words, so `git commit` saw `-m V904` and then a stray `commit`, which it treated as a pathspec and rejected — no commit made, yet the script exited 0. The quotes you typed on the command line grouped the argument *into the script's* `$1`, but they don't travel with the value; only re-quoting `"$1"` inside the script preserves it as a single argument. This is S21's `git-push.sh "V904 commit"` verbatim, and the same rule that protects `--name "${CLUSTER_NAME}"` and `-f "values-${SVC}.yaml"` everywhere.

---

#### Scenario 5.2 — "Gothenburg: the deploy that lied about succeeding"
**Solution:**
```bash
cat > /tmp/lab-gothenburg/deploy.sh <<'EOF'
#!/bin/bash
export PATH="/tmp/lab-gothenburg/bin:$PATH"
failed=()
for SVC in catalog carts checkout orders ui; do
  if helm upgrade --install "$SVC" "stacksimplify/retailstore-sample-${SVC}-chart" \
       --version 1.0.0 --wait --timeout 5m; then
    echo "$SVC installed successfully"
  else
    echo "FAILED: $SVC" >&2          # report, but keep going for the full damage report
    failed+=("$SVC")
  fi
done
if (( ${#failed[@]} )); then
  echo "SERVICES FAILED: ${failed[*]}" >&2
  exit 1                              # a failed service can never produce a green build
fi
echo "ALL 5 SERVICES DEPLOYED"
EOF
chmod +x /tmp/lab-gothenburg/deploy.sh
/tmp/lab-gothenburg/deploy.sh; echo "exit=$?"
```
**Why this works & what it teaches:** In the original loop, `helm … && echo "$SVC installed successfully"` — the `&&` only guards whether the *success echo* runs; it does **not** propagate the failure, and a `for` loop's exit status is that of its *last* iteration (ui, which succeeded), so the script exited 0 and printed victory over carts' error. Tracking failures in an array and exiting non-zero if any occurred means the build goes red while still attempting every service. Plain `set -e` at the top would instead **fail-fast** at carts (no full report) — both beat the lie because both make the exit code tell the truth, which every S21 CI stage downstream trusts.

---

#### Scenario 5.3 — "Vilnius: the trust policy that trusted ${literally-nobody}"
**Solution:**
```bash
cat > /tmp/lab-vilnius/make-trust-policy.sh <<'OUTER'
#!/bin/bash
set -euo pipefail
REPO="${1:?usage: make-trust-policy.sh <owner/repo>}"   # missing arg = loud error, exit non-zero
AWS_ACCOUNT_ID=$(printf '%012d' 424242)
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${REPO}:*" } }
  }]
}
EOF
echo "trust policy written for repo: ${REPO}"
OUTER
chmod +x /tmp/lab-vilnius/make-trust-policy.sh
cd /tmp/lab-vilnius && ./make-trust-policy.sh myuser/retail-store
```
**Why this works & what it teaches:** A heredoc with a **quoted** delimiter (`<<'EOF'`) is literal — no expansion — which is why `${AWS_ACCOUNT_ID}` and `${REPO}` reached the JSON verbatim and IAM rejected the invalid principal. Switching the *inner* heredoc to the **unquoted** `<<EOF` lets the shell substitute the real values, while the *outer* `<<'OUTER'` stays quoted for the very reason this Setup used `<<'OUTER'` to write `$1` into the file untouched. `${1:?message}` turns a missing argument into a loud failure instead of a trust policy for `repo::*`, and `set -euo pipefail` hardens the rest. Getting heredoc quoting wrong in IAM JSON (S21 §6.1) is a *security* bug, not a style one.

---

#### Scenario 5.4 — "Kaunas: the cluster named nothing"
**Solution:**
```bash
cat > /tmp/lab-kaunas/delete-cluster.sh <<'EOF'
#!/bin/bash
set -euo pipefail
export PATH="/tmp/lab-kaunas/bin:$PATH"
CLUSTER_NAME=$(terraform output -raw cluster_name | tr -d '"')   # no 2>/dev/null gag
: "${CLUSTER_NAME:?refusing to delete: cluster name is empty}"    # second fence
echo "deleting cluster: ${CLUSTER_NAME}"
echo "eksctl delete cluster --name ${CLUSTER_NAME}" > /tmp/lab-kaunas/issued-command.log
echo "teardown complete"
EOF
chmod +x /tmp/lab-kaunas/delete-cluster.sh
cd /tmp/lab-kaunas && rm -f issued-command.log && ./delete-cluster.sh; echo "exit=$?"
```
**Why this works & what it teaches:** Two mechanisms hid the original failure. `2>/dev/null` swallowed terraform's loud error, so nobody saw the state was gone; and the `| tr` pipe meant even `set -eu` wouldn't help, because a pipeline's exit status is its *last* command (`tr`, which succeeded) — proven by `bash -c 'set -eu; X=$(false | tr -d x); echo still-here'` printing `still-here`. `set -euo pipefail` makes `pipefail` propagate terraform's failure through the pipe, dropping the stderr gag surfaces the error, and `${CLUSTER_NAME:?...}` is a second fence that refuses to issue a nameless destructive command. Every S06/S07/S19 teardown captures `$(terraform output -raw ...)` and feeds a destructive command — this is why `set -euo pipefail` is the production default.

---

#### Scenario 5.5 — "Tartu: the teardown that never cleaned up after itself"
**Solution:**
```bash
cat > /tmp/lab-tartu/teardown.sh <<'EOF'
#!/bin/bash
set -euo pipefail
LOCK=/tmp/lab-tartu/teardown.lock
if [ -e "$LOCK" ]; then
  echo "another teardown is already running ($LOCK exists) — aborting" >&2
  exit 1
fi
touch "$LOCK"
cleanup() { kill "${PF_PID:-}" 2>/dev/null; rm -rf "${WORKDIR:-}"; rm -f "$LOCK"; echo "cleanup: released lock, port-forward, workdir"; }
trap cleanup EXIT INT TERM          # registered right after the FIRST resource is held
WORKDIR=$(mktemp -d /tmp/lab-tartu/work.XXXXXX)
sleep 300 & PF_PID=$!
echo "port-forward up (pid $PF_PID), workdir $WORKDIR"
echo "step 1/3: helm uninstall the 5 services"
false                                # today, step 1 fails — set -e aborts, but trap still fires
echo "step 2/3: delete nodegroups"
echo "step 3/3: terraform destroy"
EOF
chmod +x /tmp/lab-tartu/teardown.sh
cd /tmp/lab-tartu && rm -f teardown.lock && rm -rf work.* && ./teardown.sh; echo "exit=$?"
```
**Why this works & what it teaches:** `set -e` and end-of-script cleanup are fundamentally incompatible: the moment any step fails, `set -e` aborts *before* reaching the cleanup line, so the lock, port-forward, and workdir leak — and the stale lock then locks out every future run. Registering `cleanup` via `trap cleanup EXIT INT TERM` immediately after acquiring each resource guarantees it runs on success, on failure (`set -e`'s exit still fires the `EXIT` trap), *and* on Ctrl-C. This is Climb 5's promised `cleanup(){...}; trap cleanup EXIT` — "teardown that runs even on failure" — the fix every `kubectl port-forward … &` and `mktemp` script in S21 needs.

---

#### Scenario 5.6 — "Reykjavik: the invisible carriage returns from a Windows laptop"
**Solution:**
```bash
cat > /tmp/lab-reykjavik/check-all.sh <<'EOF'
#!/bin/bash
export PATH="/tmp/lab-reykjavik/bin:$PATH"

retry() {                              # retry <max> <cmd...> with exponential backoff
  local max="$1"; shift
  local n=1 delay=1
  while true; do
    "$@" && return 0
    (( n >= max )) && return 1
    sleep "$delay"; n=$((n+1)); delay=$((delay*2))
  done
}

healthy=(); broken=()
while IFS= read -r line; do
  line=${line%$'\r'}                   # strip the trailing carriage return
  [ -z "$line" ] && continue           # skip blank lines
  if retry 3 check-service "$line"; then
    healthy+=("$line")
  else
    broken+=("$line")
  fi
done < /tmp/lab-reykjavik/services.txt

echo "healthy (${#healthy[@]}): ${healthy[*]}"
if (( ${#broken[@]} )); then
  echo "broken (${#broken[@]}): ${broken[*]}" >&2
  exit 1
fi
echo "broken: none"
EOF
chmod +x /tmp/lab-reykjavik/check-all.sh
cd /tmp/lab-reykjavik && rm -f .orders-attempts && ./check-all.sh; echo "exit=$?"
```
**Why this works & what it teaches:** The file was saved with Windows CRLF line endings, so each name carried a trailing `\r` (`^M`) — invisible to `cat` but real, so `check-service` was called with `catalog\r`, `carts\r`, … and every one was "unknown". `$(cat file)` word-splitting glued the `\r` to each name, and even `while IFS= read -r` keeps it, because `-r` only stops *backslash* interpretation — it does nothing about carriage returns, which are ordinary bytes inside the line. The explicit `${line%$'\r'}` strips it; blank lines are skipped; and the `retry` function with exponential backoff lets the genuinely-mid-rollout `orders` pass on its third attempt. This is S21's post-sync health loop meeting one CRLF file from a Windows checkout — and the retry pattern is the same one behind `helm --wait`, readiness probes, and `aws eks wait`.


### Climb 6 — Text Processing: grep, sed, awk, jq, base64

#### Scenario 6.1 — "Nairobi: The Timeout Needle in the Log Haystack"

**Solution:**
```bash
cd /tmp/lab-c6-1
grep -ic timeout catalog.log                 # (1) 3 — -i folds Timeout/timeout/TIMEOUT, -c counts
grep -i -B1 timeout catalog.log              # (2) each timeout + the line before it (context)
grep ERROR catalog.log | grep -vi timeout    # (3) the non-timeout error: "mysql: too many connections"
```

**Why this works & what it teaches:** `grep` is a *line selector*: `-i` widens the match across capitalizations, `-c` turns matches into a count, `-B1` pulls context, and `-v` inverts — chaining two greps ("select ERROR, then reject timeout") is the standard way to peel a log one condition at a time, exactly what you'd do live with `kubectl logs deploy/catalog | grep -i timeout`. The payoff here is finding the `too many connections` line: the incident is *two* problems, and an unanchored "it's timeouts" diagnosis would have missed the connection-pool exhaustion. Where people go wrong: forgetting `-i` and reporting 1 timeout instead of 3, because `Timeout` and `TIMEOUT` came from different code paths (Go's mysql driver vs the checkout HTTP client).

#### Scenario 6.2 — "Kigali: Decoding the Argo CD Front Door"

**Solution:**
```bash
cd /tmp/lab-c6-2
jq -r '.data.password' argocd-secret.json | base64 -d; echo
# -> zX9-rEtailStore21
# the live-cluster twin of this pipeline:
#   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

**Why this works & what it teaches:** `jq -r` walks the JSON to `.data.password` and prints it *raw* (no surrounding quotes — quotes would corrupt the base64), and `base64 -d` reverses the **encoding** — not encryption, encoding, which is why anyone with `get secret` rights can read every K8s Secret, and why the course moves real credentials to AWS Secrets Manager (S09/14). The trailing `echo` is only cosmetic: the decoded secret has no newline of its own, so your prompt would glue onto it. Where people go wrong: omitting `-r`, piping `"elg5...="` *with quotes* into `base64 -d` and getting `invalid input`.

**Cleanup:** `rm -rf /tmp/lab-c6-2` (and note the Setup may have run `apt-get install jq` — keep it, the whole climb needs it).

#### Scenario 6.3 — "Accra: The sed That Rewrote Too Much"

**Solution:**
```bash
cd /tmp/lab-c6-3
# (1) repair the metadata tag — both lines are identical now, so scope by ADDRESS RANGE:
sed -i '/^metadata:/,$ s/^  tag: .*/  tag: retail-store-ui/' values-ui.yaml
# (2) the correct S21 write-back, scoped to the image: block:
TAG=sha-1a2b3c4
sed -i "/^image:/,/^[^ ]/ s/^  tag: .*/  tag: $TAG/" values-ui.yaml
grep -n '  tag:' values-ui.yaml
# 3:  tag: sha-1a2b3c4
# 8:  tag: retail-store-ui
```

**Why this works & what it teaches:** sed is structure-blind — after the botched run both `tag:` lines are byte-identical, so no *pattern* can tell them apart; only *position* can. An address range `/^metadata:/,$` says "apply the substitution only between the line matching `^metadata:` and end-of-file," and `/^image:/,/^[^ ]/` bounds the image block by "from `image:` until the next non-indented line" — sed's closest thing to understanding YAML nesting. Note the quoting split: the repair script is single-quoted (nothing to expand), the write-back is double-quoted so the shell substitutes `$TAG` *before* sed ever runs — the exact mechanics of the S21 pipeline line. Where people go wrong: reaching for a "more specific regex" instead of an address, or running the unanchored original again and clobbering both lines — this incident is precisely why the real S21 pattern anchors with `^  tag:` and why `yq` exists for anything structurally ambitious.

#### Scenario 6.4 — "Lagos: Reading the Order Queue with jq"

**Solution:**
```bash
cd /tmp/lab-c6-4
jq -r '.Messages[].Body | fromjson | .orderId' sqs-receive.json          # (1) ORD-1001/2/3
jq '[.Messages[].Body | fromjson | .total] | add' sqs-receive.json       # (2) 100
jq -r '.Messages[].Body | fromjson
       | select(.items >= 2) | "\(.orderId)\t\(.items)"' sqs-receive.json # (3) ORD-1001 2 / ORD-1002 5
```

**Why this works & what it teaches:** SQS wraps your payload as an escaped **string**, so `.Messages[].Body` yields text, not an object — `fromjson` performs the second parse in-stream, the tidy equivalent of the course's two-process `| jq -r '.Messages[].Body' | jq .` idiom (S14). The sum shows jq is a real query language, not just a pretty-printer: `[...]` collects the iterated totals into an array and `add` folds it; `select()` + string interpolation `"\(.x)"` give you awk-grade extraction over JSON. Where people go wrong: trying `.Messages[].Body.orderId` (indexing into a *string* returns an error) — the moment you see `\"` inside a JSON value, think `fromjson`.

**Cleanup:** `rm -rf /tmp/lab-c6-4`.

#### Scenario 6.5 — "Dakar: Fleet Triage from a Frozen Snapshot"

**Solution:**
```bash
cd /tmp/lab-c6-5
# (1) the restart-looper — jq's select() over the snapshot:
jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 3) | .metadata.name' pods.json
# -> orders-84bd9f6c77-t9pqx
# (2) why it kept dying — last termination reason ("//" gives a default for the healthy pods):
jq -r '.items[] | [.metadata.name,
                   (.status.containerStatuses[0].restartCount|tostring),
                   (.status.containerStatuses[0].lastState.terminated.reason // "-")] | @tsv' pods.json
# -> orders ... 7  OOMKilled
# (3) tag histogram — jq extracts, awk slices the tag off the image ref, uniq -c counts:
jq -r '.items[].spec.containers[0].image' pods.json | awk -F: '{print $2}' | sort | uniq -c | sort -rn
#       4 sha-1a2b3c4
#       1 sha-0ld0000
# (4) the odd one out, joined in pure jq:
jq -r '.items[] | select(.spec.containers[0].image | endswith("sha-1a2b3c4") | not) | .metadata.name' pods.json
# -> orders-84bd9f6c77-t9pqx
```
One-sentence synthesis: *the orders pod is still running last week's `sha-0ld0000` image — the build that OOMKills — because the S21 write-back never reached values-orders.yaml, so it crash-looped 7 times while `kubectl get pods` cheerfully said `Running`.*

**Why this works & what it teaches:** `phase: Running` is a *snapshot of now*, not a health verdict — the truth lives deeper in the object, at `containerStatuses[].restartCount` and `lastState.terminated`, which is why `kubectl get pod ... -o jsonpath='{.status.containerStatuses[0].restartCount}'` exists and why saved `-o json` blobs are fully triage-able after the cluster is gone. The pipeline shows the division of labor at its best: jq walks structure, awk slices the `repo:tag` string, `sort | uniq -c` turns rows into a histogram — four small verbs, one diagnosis. Where people go wrong: stopping at finding the restarts and never running the tag histogram — the *cause* (stale image = missed CI write-back) only appears when you cross-reference the two findings.

**Cleanup:** `rm -rf /tmp/lab-c6-5`.

#### Scenario 6.6 — "Tunis: The Invisible Newline That Locked Out MySQL"

**Solution:**
```bash
cd /tmp/lab-c6-6
# (1) forensics — make the invisible byte visible:
jq -r '.data.password' mysql-secret.json | base64 -d | od -c | head -2
# 0000000   R   e   t   a   i   l   D   B   #   2   0   2   6  \n     <- there it is
jq -r '.data.password' mysql-secret.json | base64 -d | wc -c
# 14  (13 characters + 1 smuggled newline)
# (2) re-encode without the newline — printf adds nothing you didn't write:
NEW=$(printf 'RetailDB#2026' | base64)
# (3) patch the JSON with jq itself (never sed on JSON):
jq --arg p "$NEW" '.data.password = $p' mysql-secret.json > tmp.json && mv tmp.json mysql-secret.json
# (4) re-verify: 13 bytes, no \n
jq -r '.data.password' mysql-secret.json | base64 -d | wc -c    # 13
```

**Why this works & what it teaches:** `echo` appends `\n` by definition, `base64` faithfully encodes those 14 bytes, Kubernetes faithfully mounts them, and MySQL faithfully rejects `RetailDB#2026\n` — every component "worked," which is what makes this bug class so vicious; `od -c` and `wc -c` are the forensic pair because *terminals render the corruption invisibly* (your eyes see the same 13 characters either way). The repair leg matters as much as the diagnosis: `jq --arg` treats the new value as data and rewrites the document structurally, whereas sed on JSON risks matching inside some other value — the same structure-blindness lesson as Accra, now on the write path. Where people go wrong: "verifying" by decoding to the screen and eyeballing it (looks identical!), and re-encoding with `echo -n` in a script whose shell's `echo` doesn't honor `-n` — `printf` is the only portable spelling, which is why the ladder says `-n` forever and the course retires hand-crafted Secrets for AWS Secrets Manager (S09/14).

**Cleanup:** `rm -rf /tmp/lab-c6-6` (contains a "credential"). If Setup installed jq via apt, keep it for the remaining climbs.

### Climb 7 — I/O Streams, Redirection & Pipes

#### Scenario 7.1 — "Cairo: The Warning That Dodged the Pipe"

**Solution:**
```bash
cd /tmp/lab-c7-1
./healthcheck.sh | grep -c OK          # (1) prints 3 — but both WARNs ALSO hit the terminal, un-grepped
./healthcheck.sh 2>/dev/null | grep -c OK   # (2) clean 3 — stderr discarded
./healthcheck.sh > ok.txt 2> warn.txt       # (3) split: 3 lines in ok.txt, 2 in warn.txt
./healthcheck.sh 2>&1 | grep -c WARN        # (4) 2 — stderr merged INTO the pipe
```

**Why this works & what it teaches:** `|` connects the left command's **fd 1 only** to the right command's fd 0 — fd 2 still points at your terminal, so the WARNs travel around the pipe, not through it; that's the entire mystery. `2>/dev/null` re-points fd 2 at the discard device (the course's quiet-check idiom), `> ok.txt 2> warn.txt` gives each stream its own file, and `2>&1` copies fd 1's current destination (the pipe) into fd 2 so grep finally sees the warnings. This is also why a failing `curl -s ... | jq` prints curl's complaint *around* jq's output — same two lanes. Where people go wrong: assuming a pipe is a wall that catches everything; it's a lane for exactly one stream.

#### Scenario 7.2 — "Casablanca: The Clobbered $GITHUB_ENV"

**Solution:**
```bash
cd /tmp/lab-c7-2 && export GITHUB_ENV=/tmp/lab-c7-2/github.env
./step-a.sh && ./step-b.sh && cat github.env   # (1) only IMAGE_BASE — TAG is gone
# (2) the one-character bug: step-b.sh uses >  (truncate) instead of >> (append). Fix:
sed -i 's/" > "/" >> "/' step-b.sh
rm -f github.env && ./step-a.sh && ./step-b.sh # rerun both "CI steps" clean
. "$GITHUB_ENV" && echo "$TAG $IMAGE_BASE"     # (3) sha-1a2b3c4 retail-store-ui — both survive
```

**Why this works & what it teaches:** `>` opens the file with `O_TRUNC` — it zeroes the file *before* writing — while `>>` opens with `O_APPEND`; since every GitHub Actions step is a **separate process** that can't share a pipe or shell variables, `$GITHUB_ENV` is a plain file used as the inter-step mailbox, and one truncating writer erases every earlier step's exports (S21). The `source` at the end is what the Actions runner effectively does before each step. Where people go wrong: "it worked when I tested the step alone" — truncation only bites when a *previous* step had already written something, so the bug hides in single-step tests and detonates in the full pipeline.

#### Scenario 7.3 — "Windhoek: Following the Firehose"

**Solution:**
```bash
cd /tmp/lab-c7-3
# (1) follow live, filter, keep evidence (Ctrl-C after 2+ ERROR lines):
tail -f orders.log | grep --line-buffered ERROR | tee errors.txt
# (2) your Ctrl-C killed the tail/grep/tee pipeline only — the "pod" is still logging:
kill -0 "$(cat writer.pid)" && echo "writer still alive"
# (3) after the writer's 30s life:
grep -c ERROR orders.log      # 6 — every 5th of 30 lines
wc -l < errors.txt            # >=1 — whatever you caught while following
```

**Why this works & what it teaches:** `tail -f` is the whole trick behind `kubectl logs -f`: open the log, print what exists, then *block* until more bytes appear — the follower is a reader with no power over the writer, which is why Ctrl-C stops your view and nothing else (Climb 7 Rung 5's trace, step 4). `--line-buffered` fights a real production annoyance: when grep's stdout is a pipe (into `tee`) rather than a terminal, libc switches it to ~4KB block buffering, so at one log line per second you'd stare at silence for minutes while "following live" — the same reason `kubectl logs -f | grep` can feel laggy. Where people go wrong: believing Ctrl-C on `kubectl logs -f` restarts or disturbs the pod — you only hung up your own phone call.

**Cleanup:** `kill "$(cat /tmp/lab-c7-3/writer.pid)" 2>/dev/null; rm -rf /tmp/lab-c7-3` (writer self-terminates after 30s anyway).

#### Scenario 7.4 — "Gaborone: Two Redirects, Wrong Order"

**Solution:**
```bash
cd /tmp/lab-c7-4
./capture.sh; wc -l < all.log     # (1) 1 — and the warning leaked to the terminal
# (2) left-to-right dup2 semantics:
#    2>&1      -> fd2 := copy of fd1's CURRENT target (the terminal!)
#    > all.log -> fd1 := all.log  (fd2 still points at the terminal)
# (3) fix: point fd1 at the file FIRST, then copy it into fd2:
sed -i 's|2>&1 > all.log|> all.log 2>\&1|' capture.sh   # note: & is special in sed replacements — escape it!
./capture.sh; wc -l < all.log     # 2 — endpoint + warning both captured
```

**Why this works & what it teaches:** redirections are not a declarative wish-list — the shell executes them left to right as `dup2()` calls *before* the program runs, and `2>&1` snapshots where fd 1 points **at that instant**; write it before `> all.log` and fd 2 inherits the terminal, not the file. `> all.log 2>&1` (or bash's shorthand `&> all.log`) does the operations in the only order that captures both. This is the exact pattern in every `some-command >> "$LOG" 2>&1` line of the course's cluster-creation scripts (S19) and the reason audit logs sometimes mysteriously miss the errors they were built to keep. Where people go wrong: reading `2>&1` as "merge stderr into stdout forever" instead of "duplicate fd 1's current target into fd 2 right now."

#### Scenario 7.5 — "Kampala: The Logs kubectl Never Saw"

**Solution:**
```bash
cd /tmp/lab-c7-5
PID=$(cat pod.pid)
# (1) diagnosis straight from /proc — where do the app's descriptors actually point?
ls -l /proc/$PID/fd/
readlink /proc/$PID/fd/1        # -> /tmp/lab-c7-5/capture.log  (the runtime's capture — EMPTY)
wc -l app.log                   # growing — the app logs to a file the capture never reads
./kubectl-logs.sh               # nothing: the contract only covers fd1/fd2
# (2) the no-rebuild fix (the trick official nginx images use):
kill $PID
rm -f app.log
ln -s /dev/stdout app.log       # opening app.log now opens THIS process's fd 1
./start-pod.sh
# (3) proof:
sleep 3; ./kubectl-logs.sh | tail -2    # the POST /orders lines, now visible
```

**Why this works & what it teaches:** the container logging contract is brutally small — the runtime captures **fd 1 and fd 2 of PID 1**, nothing else — so an app writing `/var/log/app.log` inside its own filesystem is invisible to `kubectl logs` while "definitely logging every request" (Climb 7's check-yourself question, verbatim). The symlink works because `/dev/stdout` is a per-process alias for `/proc/self/fd/1`: when the app opens `app.log` for append, the kernel resolves the link to *the app's own* already-captured stdout, so every write lands in `capture.log` without touching a line of vendor code. `readlink /proc/$PID/fd/1` is the underused diagnostic gem here — it answers "where is this process *really* writing?" for any process on any box. Where people go wrong: making the symlink while the old process still holds the old `app.log` open (writes keep going to the deleted inode), or symlinking to *your shell's* `/dev/stdout` conceptually — the link must be resolved by the app process itself; that's why the restart matters. This is 12-factor logging and the reason all retail-store services log to stdout so S20's OpenTelemetry collector can scrape them uniformly.

**Cleanup:** `kill "$(cat /tmp/lab-c7-5/pod.pid)" 2>/dev/null; rm -rf /tmp/lab-c7-5`.

#### Scenario 7.6 — "Lusaka: The Pipeline That Lied to CI"

**Solution:**
```bash
cd /tmp/lab-c7-6
./ci-step.sh; echo "exit=$?"            # (1) exit=0 — CI would go green, UI is down
# (2) autopsy — per-member statuses of the LAST pipeline:
./curl-endpoint.sh | tee check.log; echo "PIPESTATUS: ${PIPESTATUS[@]}"
# PIPESTATUS: 7 0   -> curl failed (7), tee succeeded (0), $? kept only tee's 0
# (3) the fix — one line at the top of the step:
sed -i '2i set -o pipefail' ci-step.sh
./ci-step.sh; echo "exit=$?"            # exit=7 — the step now fails loudly
# (4) hold the pipe in your hand — a FIFO is the same kernel object `|` creates anonymously:
mkfifo lab.fifo
./curl-endpoint.sh 2> lab.fifo & grep -c refused < lab.fifo   # 1
rm lab.fifo
```

**Why this works & what it teaches:** a pipeline's exit status is the **last** command's by POSIX rule, so any evidence-keeping `| tee` (or filtering `| grep`) launders failures into success — the deadliest version being exactly this: a green CI smoke-test over a dead deployment (S21, where every `run:` block is a bash pipeline). `PIPESTATUS` is bash's per-member ledger (read it *immediately* — the next command overwrites it), and `set -o pipefail` changes the rule to "rightmost non-zero wins," which is why serious CI templates open with `set -euo pipefail`. The FIFO leg demystifies `|` itself: `mkfifo` creates the identical kernel buffer as a named filesystem object, two unrelated processes attach by path, and the writer blocks until a reader opens — pipes are files, like everything else in this course. Where people go wrong: checking `$?` after an intermediate `echo` has already replaced it, or "fixing" the step by removing `tee` and losing the evidence instead of keeping both with pipefail.

### Climb 8 — Namespaces & cgroups: What a Container Actually Is

#### Scenario 8.1 — "Maputo: Namespaces Are Just Files"

**Solution:**
```bash
ls -l /proc/self/ns/                              # (1) uts:[4026531838], net:[...], pid:[...] — views as symlinks
readlink /proc/self/ns/uts /proc/1/ns/uts         # (2) identical inode — you and PID 1 share one hostname-world
sudo unshare --uts bash                           # (3) step into a NEW uts namespace
  hostname retail-pod-maputo && hostname          #     changed... in here
  readlink /proc/self/ns/uts                      #     a DIFFERENT inode number — different world
  exit
hostname                                          # (4) untouched — the change never existed out here
```

**Why this works & what it teaches:** a namespace is not a box the kernel puts processes *into* — it's a per-resource **view**, advertised as a symlink under `/proc/<pid>/ns/`, and "being in a container" reduces to "your ns links point at different inodes than mine." `unshare --uts` asks the kernel for one fresh view (hostname/domainname only), so the rename is real *within that view* and non-existent outside it — multiply by pid+net+mnt+ipc and you have every bit of isolation `docker run` gives the retail-store services (S02); there is no "container" object in the kernel to find. Where people go wrong: expecting some heavyweight boundary — the whole demo is two processes disagreeing about the answer to `hostname`, and that disagreement *is* the technology.

#### Scenario 8.2 — "Harare: Becoming PID 1"

**Solution:**
```bash
cat /tmp/lab-c8-2/host-proc-count.txt              # (1) hundreds of processes out here
sudo unshare --pid --fork --mount-proc bash        # (2) enter a new PID namespace
  echo $$                                          #     1 — you are init of this world (Climb 4 payoff)
  ps -e                                            #     just bash + ps — the blinders work
  exit
ps -e --no-headers | wc -l                         # (4) host unchanged
```

**Why this works & what it teaches:** PID namespaces number processes from 1 *per view*, but two flags carry the demo: `--fork` because the calling process can't renumber itself — only a **child** can be born as PID 1 of the new namespace — and `--mount-proc` because `ps` doesn't ask the kernel directly, it reads `/proc`, so without a fresh procfs mount you'd be PID 1 *while ps still lists the host* (a genuinely confusing half-container state worth experiencing once by dropping the flag). This is the exact moment in Climb 8 Rung 5 where the catalog binary "wakes up as PID 1 in an empty world" after `docker run` (S02) — and why Climb 4's PID-1 signal duties (the `docker stop` grace period) apply to every containerized process. Where people go wrong: thinking PID 1 status is cosmetic — it changes signal semantics, which is why the S02 `docker stop` timeout exists at all.

#### Scenario 8.3 — "Abuja: A Pod's Budget Is a Directory"

**Solution:**
```bash
sudo mkdir /sys/fs/cgroup/lab-catalog                                   # (1) a budget is... mkdir
echo $((256*1024*1024)) | sudo tee /sys/fs/cgroup/lab-catalog/memory.max # (2) limits.memory: 256Mi, compiled
sleep 300 &                                                             # (3) the "container"
echo $! | sudo tee /sys/fs/cgroup/lab-catalog/cgroup.procs              #     enrollment = write one pid
P=$!; cat /proc/$P/cgroup                                               # (4) 0::/lab-catalog — the process knows
cat /sys/fs/cgroup/lab-catalog/memory.current                           #     live usage — kubectl top's raw feed
kill $P; sudo rmdir /sys/fs/cgroup/lab-catalog                          # (5) cleanup (rmdir only when empty)
```

**Why this works & what it teaches:** cgroup v2 has no API beyond the filesystem — *creating* a budget is `mkdir`, *setting* the S08 limit is writing `268435456` into `memory.max`, *scheduling a pod into it* is writing a PID into `cgroup.procs`, and *monitoring* is reading `memory.current`; the kubelet does precisely these four file operations when your Deployment says `resources.limits.memory: 256Mi`, and HPA/`kubectl top` (S18) read the same accounting files back. Everything-is-a-file (Climb 2) pays its biggest dividend here. Where people go wrong: trying to `rmdir` while a process is still enrolled (Device or resource busy — move or kill the processes first), or looking for a daemon to restart when cgroup limits "don't apply" — there is no daemon, only files.

**Cleanup:** `kill %1 2>/dev/null; sudo rmdir /sys/fs/cgroup/lab-catalog 2>/dev/null; rm -rf /tmp/lab-c8-3`.

#### Scenario 8.4 — "Marrakesh: Reproducing the 256Mi Crash-Loop"

**Solution:**
```bash
cd /tmp/lab-c8-4
sudo bash run-orders.sh; echo "exit=$?"       # (1) exit=137, no success line — 128+9 = SIGKILLed
sudo dmesg | grep -i 'oom\|killed process' | tail -5   # (2) "Memory cgroup out of memory: Killed process ... (tail)"
echo $((400*1024*1024)) | sudo tee /sys/fs/cgroup/lab-orders/memory.max  # (3) the S19 fix: raise the wall
sudo bash run-orders.sh; echo "exit=$?"       # (4) "orders service warmed up successfully" / exit=0
# (5) the rule: memory over limit = DEATH (wall). It can never "run slower to fit."
```

**Why this works & what it teaches:** the hog (`head -c 150M /dev/zero | tail` — tail must buffer all 150M) charges pages to the `lab-orders` cgroup until `memory.current` would cross `memory.max`; the kernel finds nothing reclaimable (swap is capped at 0, like most K8s nodes), so the **OOM killer sends SIGKILL** — exit 137 with *no dying words*, because SIGKILL can't be caught. That silent 137 is byte-for-byte the S19 incident: Spring Boot needs ~350Mi to boot, the chart said 256Mi, kubelet wrote that into `memory.max`, and the pod printed `CrashLoopBackOff`/`OOMKilled: true` until the limit was raised to 400Mi — the fix is *more memory*, never "try again," because the requirement is a floor. `dmesg` is the kernel's confession booth; on a real node it names the killed process inside the pod's cgroup path. Where people go wrong: hunting application logs for a crash reason that was never written, and confusing this wall with CPU's valve (next scenario). Docker path (`docker run --memory=100m alpine sh -c 'tail /dev/zero'` then `docker inspect -f '{{.State.OOMKilled}}'`) shows the same 137/true.

**Cleanup:** `sudo rmdir /sys/fs/cgroup/lab-orders; rm -rf /tmp/lab-c8-4`.

#### Scenario 8.5 — "Alexandria: The Valve and the Wall"

**Solution:**
```bash
cd /tmp/lab-c8-5
time bash busy.sh                                            # (1) baseline, e.g. ~2s
sudo bash -c 'echo $$ > /sys/fs/cgroup/lab-checkout/cgroup.procs; time bash /tmp/lab-c8-5/busy.sh'
#                                                            # (2) ~5x slower (0.2 CPU) — but exit 0. Nothing died.
grep -E '^(nr_throttled|throttled_usec)' /sys/fs/cgroup/lab-checkout/cpu.stat   # (3) the throttle ledger
# (4) be the HPA: steady load, then sample usage over a 10s window
sudo bash -c 'echo $$ > /sys/fs/cgroup/lab-checkout/cgroup.procs; while :; do :; done' &
HOG=$!
U1=$(awk '$1=="usage_usec"{print $2}' /sys/fs/cgroup/lab-checkout/cpu.stat); sleep 10
U2=$(awk '$1=="usage_usec"{print $2}' /sys/fs/cgroup/lab-checkout/cpu.stat)
awk -v d=$((U2-U1)) 'BEGIN{c=d/10/1000000; printf "%.3f cores = %.0f%% of a 100m request (HPA target 70%%)\n", c, c/0.1*100}'
# -> ~0.200 cores = ~200% of request  => HPA would scale OUT
sudo kill $HOG
```

**Why this works & what it teaches:** `cpu.max = "20000 100000"` grants 20ms of CPU per 100ms period (`limits.cpu: 200m`); when the loop exhausts its 20ms the scheduler simply parks it until the next period — `nr_throttled` counts those parkings, `throttled_usec` the time spent parked — so CPU over limit means **latency, never death**, the exact opposite failure mode of Marrakesh's memory wall. The sampling leg is HPA's real algorithm laid bare (S18): `Δusage_usec` over a window ÷ the *request* (not the limit!) gives the utilization percentage compared against `targetCPUUtilizationPercentage: 70` — at ~200% the HPA scales out, which is why undersized CPU shows up as replica count and p99 latency, not restarts. Where people go wrong: reading HPA percentages against limits (a pod using 0.2 cores with a 100m request is at 200%, even though it's "only" at 100% of its limit), and cost-cutting CPU while expecting OOM-style crashes as the warning sign — the valve never trips an alarm, it just quietly slows checkout.

**Cleanup:** ensure no stragglers: `cat /sys/fs/cgroup/lab-checkout/cgroup.procs` (should be empty), then `sudo rmdir /sys/fs/cgroup/lab-checkout; rm -rf /tmp/lab-c8-5`.

#### Scenario 8.6 — "Durban: Hand-Building a Pod"

**Solution:**
```bash
# (1) the pause container: OWNS net+uts, does nothing else — exactly its K8s job
sudo unshare --net --uts bash -c 'hostname lab-pod-durban; echo $$ > /tmp/lab-c8-6/pause.pid; sleep 600' &
sleep 1; PAUSE=$(cat /tmp/lab-c8-6/pause.pid)
cat /tmp/lab-c8-6/pause.pid | sudo tee /sys/fs/cgroup/lab-pod-durban/cgroup.procs   # pod budget = one cgroup
# (2) fresh net namespaces are born with loopback DOWN:
sudo nsenter -t "$PAUSE" -n ip link set lo up
# (3) the "app container" JOINS the pause's namespaces (this is what kubelet arranges):
sudo nsenter -t "$PAUSE" -n -u python3 -m http.server 8480 --bind 127.0.0.1 >/tmp/lab-c8-6/app.log 2>&1 &
sleep 1
# (4) the "sidecar" sees the app on the POD's localhost — Istio's whole trick (S22):
sudo nsenter -t "$PAUSE" -n -u curl -s -o /dev/null -w 'sidecar->app: %{http_code}\n' http://127.0.0.1:8480/
# (5) the host cannot — pod 8480 is not host 8480:
curl -s --max-time 2 http://127.0.0.1:8480/ || echo "host: connection refused (different netns)"
# (6) app restarts, "pod IP" survives — because the PAUSE holds the namespace, not the app:
sudo pkill -f 'http.server 8480'; sleep 1
sudo nsenter -t "$PAUSE" -n -u python3 -m http.server 8480 --bind 127.0.0.1 >>/tmp/lab-c8-6/app.log 2>&1 &
sleep 1; sudo nsenter -t "$PAUSE" -n -u curl -s -o /dev/null -w 'after restart: %{http_code}\n' http://127.0.0.1:8480/
# cleanup:
sudo pkill -f 'http.server 8480'; sudo kill "$PAUSE"
sleep 1; sudo rmdir /sys/fs/cgroup/lab-pod-durban
```

**Why this works & what it teaches:** a pod is not a kernel object either — it's a *convention*: one do-nothing **pause process** created first to own the shared namespaces (net+uts here, exactly why `kubectl get pod -o wide` shows one IP for all containers), every real container then `setns()`-ed into them (`nsenter` is that syscall with a command line), and one cgroup holding the collective budget. The three verifications each prove a course claim mechanically: sidecar-curl-succeeds is S22's Envoy seeing app traffic on localhost; host-curl-fails is network namespace isolation (the pod's 127.0.0.1:8480 simply isn't the host's); and the app surviving restart with its network intact is the vocabulary-map line "why pod IP survives app-container restarts" — the namespace lives exactly as long as its *pause* holder, not its workload. Where people go wrong: forgetting `ip link set lo up` (fresh netns loopback is DOWN, so even localhost refuses connections — a great five-minute head-scratcher), and killing the pause while "just restarting the app," which on real clusters is the difference between a container restart (IP kept) and pod recreation (new IP).

**Cleanup:** included above; verify with `ip netns list` staying empty and `ls /sys/fs/cgroup/ | grep -c lab-` printing 0.


### Climb 9 — Storage, Mounts & OverlayFS

#### Scenario 9.1 — "Hanoi: the file behind the mount"
**Solution:**
```bash
sudo mount --bind /opt/lab-hanoi/host-data /opt/lab-hanoi/container-view
mountpoint /opt/lab-hanoi/container-view
cat /opt/lab-hanoi/container-view/orders.log      # order-2025-log — appears THROUGH the mount
# undo:
sudo umount /opt/lab-hanoi/container-view
```
**Why this works & what it teaches:** A bind mount grafts one existing directory tree onto another path, so the file isn't copied — the same inodes are now reachable through a second location, exactly how `-v /host:/container` (S02) or a PV punches an external filesystem into the OverlayFS view (Climb 9, Rung 3). `mountpoint` proves the path is a mount boundary, not a plain dir. **Where people go wrong:** copying files in and wondering why edits don't reflect back — a bind is a live view of one FS, not a snapshot.
**Cleanup:** `sudo umount /opt/lab-hanoi/container-view 2>/dev/null; sudo rm -rf /opt/lab-hanoi`

#### Scenario 9.2 — "Da Nang: scratch that dies with the pod"
**Solution:**
```bash
sudo mount -t tmpfs -o size=16m tmpfs /opt/lab-danang/scratch
echo "render-cache" | sudo tee /opt/lab-danang/scratch/cache.dat >/dev/null
findmnt -t tmpfs /opt/lab-danang/scratch          # confirms RAM-backed tmpfs
sudo umount /opt/lab-danang/scratch               # == pod delete: emptyDir destroyed
ls /opt/lab-danang/scratch                        # empty — cache.dat is gone
```
**Why this works & what it teaches:** `tmpfs` is a RAM-backed filesystem; mounting it at the scratch path is precisely an `emptyDir` with `medium: Memory` (S08's read-only-rootfs pods get writable scratch this way). Its data lives only as long as the mount — unmounting is the local analogue of deleting the pod, and the bytes evaporate (Climb 9, Rung 3: emptyDir = pod-lifetime, Memory = tmpfs). **Where people go wrong:** assuming `/tmp` inside a container is durable — it's the disposable upper layer or an emptyDir, never persistence.
**Cleanup:** `sudo umount /opt/lab-danang/scratch 2>/dev/null; sudo rm -rf /opt/lab-danang`

#### Scenario 9.3 — "Penang: the volume that outlives the container"
**Solution:**
```bash
LOOP=$(sudo losetup --find --show /opt/lab-penang/ebs.img)   # attach the "EBS volume"
sudo mkfs.ext4 -q "$LOOP"
sudo mount "$LOOP" /mnt/lab-penang
echo "row-1" | sudo tee /mnt/lab-penang/rows.txt >/dev/null   # mysqld INSERT lands on the PV
sudo umount /mnt/lab-penang                                   # pod dies
sudo mount "$LOOP" /mnt/lab-penang                            # StatefulSet recreates → PVC re-attaches
grep row-1 /mnt/lab-penang/rows.txt                          # row-1 — survived
```
**Why this works & what it teaches:** A loop device turns a regular file into a block device you can format and mount — a faithful stand-in for an EBS volume. Because the write landed on that filesystem (a mount) rather than the container's writable upper layer, it survives the unmount/remount cycle exactly as Rung 5's trace describes `catalog-mysql-0`'s PVC re-attaching the same EBS volume (S10). **Map to real:** loop-device ext4 = EBS-backed PersistentVolume; the AZ-pin the real one needs is why S10 uses `WaitForFirstConsumer`.
**Cleanup:** `sudo umount /mnt/lab-penang 2>/dev/null; sudo losetup -d "$LOOP" 2>/dev/null; sudo rm -rf /opt/lab-penang /mnt/lab-penang`

#### Scenario 9.4 — "Bandung: the secret with the wrong lock"
**Solution:**
```bash
sudo umount /mnt/secrets-store 2>/dev/null || true
sudo mount -t tmpfs tmpfs /mnt/secrets-store               # secret in RAM, never on disk
echo "s3cr3t-db-pass" | sudo tee /mnt/secrets-store/db-password >/dev/null
sudo chown labuser1 /mnt/secrets-store/db-password
sudo chmod 0400 /mnt/secrets-store/db-password
stat -c '%a %U' /mnt/secrets-store/db-password             # 400 labuser1
sudo -u labuser1 cat /mnt/secrets-store/db-password        # readable by owner
sudo useradd -m labuser2 2>/dev/null || true
sudo -u labuser2 cat /mnt/secrets-store/db-password 2>&1 | grep -qi "permission denied" && echo "OTHERS BLOCKED"
```
**Why this works & what it teaches:** `0400` grants read to the owner only and nothing to group/other, so only `labuser1` (the pod's `runAsUser`) can read it — the mounted-secret mode the CSI driver enforces at `/mnt/secrets-store` (S09/S14). Mounting it on tmpfs keeps the secret off persistent disk, matching how Secrets Store CSI materializes Secrets-Manager values as an ephemeral volume (Climb 9, Rung 4). **Where people go wrong:** leaving the file `0644`/root-owned — every co-located process can read the DB password, which a `readOnlyRootFilesystem` security audit rightly flags.
**Cleanup:** `sudo umount /mnt/secrets-store 2>/dev/null; sudo rm -rf /mnt/secrets-store; sudo userdel -r labuser2 2>/dev/null`

#### Scenario 9.5 — "Cebu: copy-on-write, caught in the act"
**Solution:**
```bash
sudo mount -t overlay overlay \
  -o lowerdir=/opt/lab-cebu/appdeps:/opt/lab-cebu/base,upperdir=/opt/lab-cebu/upper,workdir=/opt/lab-cebu/work \
  /opt/lab-cebu/merged
# edit a file that lives only in a LOWER layer, through the merged view:
echo "shared-config-v2" | sudo tee /opt/lab-cebu/merged/app.conf >/dev/null
cat /opt/lab-cebu/upper/app.conf     # shared-config-v2 — the write was COPIED UP
cat /opt/lab-cebu/base/app.conf      # shared-config-v1 — lower layer untouched
cat /opt/lab-cebu/merged/app.conf    # shared-config-v2 — merged view shows the upper wins
sudo umount /opt/lab-cebu/merged
```
**Why this works & what it teaches:** OverlayFS presents `lowerdir`s (read-only image layers) unioned under a writable `upperdir` (the container layer). Writing to a lower-origin file triggers copy-on-write: the file is copied into `upper` and edited there, so the merged view changes while the image layer stays byte-for-byte identical — precisely why "I edited it in the running container and it vanished on restart" (the upper layer is discarded) and why `docker build` reuses unchanged lower layers as cache (S03/S05). **Map to real:** `lowerdir`s = `docker history` image layers; `upperdir` = the per-container writable layer.
**Cleanup:** `sudo umount /opt/lab-cebu/merged 2>/dev/null; sudo rm -rf /opt/lab-cebu`

#### Scenario 9.6 — "Chiang Mai: the disk that's full of nothing"
**Solution:**
```bash
df -h /mnt/lab-node                      # ~100% used
du -sh /mnt/lab-node                     # tiny — the discrepancy is the whole clue
# find the process holding a DELETED (unlinked) file open on this mount:
sudo lsof -n /mnt/lab-node | grep '(deleted)'    # shows PID + fd 9 -> app.log (deleted)
PID=$(sudo lsof -tn /mnt/lab-node 2>/dev/null | head -1)
# reclaim without unmount: truncate the still-open fd via /proc, then release the holder
sudo truncate -s 0 "/proc/$PID/fd/9" 2>/dev/null || sudo kill "$PID"
df -h /mnt/lab-node                      # space reclaimed — back well under 100%
```
**Why this works & what it teaches:** On Linux, `unlink` (rm) only removes the directory entry; the inode and its blocks are freed *when the last open fd closes*. A logger that `rm`'d its rotated log but kept the descriptor open holds the space hostage — `df` counts the blocks (allocated), `du` walks directory entries (file is gone), hence the mismatch. `lsof ... | grep deleted` names the culprit; truncating `/proc/PID/fd/N` (or killing the holder) releases the blocks with no unmount needed. This is the ephemeral-storage-full eviction on nodes backing `emptyDir`/the writable upper layer (S08/S18). **Where people go wrong:** deleting more files (there's nothing to delete) or rebooting the node instead of finding the open fd.
**Cleanup:** `sudo pkill -f 'sleep 3000' 2>/dev/null; sudo umount /mnt/lab-node 2>/dev/null; L=$(sudo losetup -j /opt/lab-chiangmai/node.img | cut -d: -f1); sudo losetup -d "$L" 2>/dev/null; sudo rm -rf /opt/lab-chiangmai /mnt/lab-node`

### Climb 10 — Package Management & the CLI Toolchain

#### Scenario 10.1 — "Vientiane: who owns this binary?"
**Solution:**
```bash
for t in git jq; do
  p=$(command -v "$t") || { echo "$t MISSING"; continue; }
  printf '%-6s %s -> ' "$t" "$p"
  dpkg -S "$p" 2>/dev/null || echo "not apt-owned (hand-installed)"
done
```
**Why this works & what it teaches:** `command -v` resolves the path PATH actually picks; `dpkg -S <path>` searches dpkg's file database for the package that placed it. A hit means apt-managed (clean upgrade/removal); no hit means a hand-dropped binary that apt can't see — the root of "why is my terraform old?" (two installs, PATH chose one). This is Rung 7 Lab 1's audit and the pre-S02 install checklist (Climb 10, Rung 3/4). **Where people go wrong:** running `dpkg -S jq` (a name) instead of the resolved path — always feed it the exact file `command -v` returned.

#### Scenario 10.2 — "Yangon: the binary that shadows its twin"
**Solution:**
```bash
command -v kubectl        # /usr/local/bin/kubectl — the one that runs
type -a kubectl           # lists BOTH, in PATH order: /usr/local/bin then /usr/bin
echo "$PATH" | tr ':' '\n' | grep -nE '/usr/(local/)?bin'   # /usr/local/bin appears first
kubectl                   # prints the vendor line -> proves /usr/local/bin won
```
**Why this works & what it teaches:** The shell searches PATH left to right and runs the first match. Default PATH lists `/usr/local/bin` before `/usr/bin`, so a hand-installed binary there shadows an apt-installed twin — which is exactly why `/usr/local/bin` is the convention for vendor CLIs like kubectl/argocd/istioctl (Climb 10 Rung 4; PATH ordering is Climb 1). `type -a` reveals every candidate so you can see the shadow. **Where people go wrong:** `apt upgrade` bumps `/usr/bin/kubectl` and nothing changes at runtime because the `/usr/local/bin` copy still wins — remove or update the shadowing binary.
**Cleanup:** `sudo rm -f /usr/local/bin/kubectl /usr/bin/kubectl`

#### Scenario 10.3 — "Surabaya: your own package, your own repo"
**Solution:**
```bash
sudo mkdir -p /opt/lab-repo
dpkg-deb --build /opt/lab-surabaya/retail-tool_1.0_all /opt/lab-repo/retail-tool_1.0_all.deb
dpkg-deb -I /opt/lab-repo/retail-tool_1.0_all.deb          # inspect control metadata
cd /opt/lab-repo && dpkg-scanpackages -m . /dev/null | gzip -9c > Packages.gz
echo "deb [trusted=yes] file:/opt/lab-repo ./" | sudo tee /etc/apt/sources.list.d/lab-surabaya.list >/dev/null
sudo apt-get update -qq -o Dir::Etc::sourceparts=/etc/apt/sources.list.d
apt-cache policy retail-tool                               # Candidate: 1.0 from the lab repo
sudo apt-get install -y --dry-run retail-tool             # preview only — no real mutation
```
**Why this works & what it teaches:** `dpkg-deb -b` packs a `DEBIAN/control` + file tree into a `.deb`; `dpkg-scanpackages` builds the `Packages` index that turns a directory into an apt repository; the `sources.list.d` entry tells apt where to look. Now `apt-cache policy` shows apt resolving your package against a signed-style index — the reproducible, cleanly-removable alternative to `curl|bash` for baking tools into images (S03, Rung 6 trust models). `--dry-run` previews the resolve-verify-place-record without changing the box. **Where people go wrong:** forgetting the index (`Packages.gz`) — apt ignores loose `.deb`s in a dir until they're indexed.
**Cleanup:** `sudo rm -f /etc/apt/sources.list.d/lab-surabaya.list; sudo apt-get update -qq; sudo rm -rf /opt/lab-repo /opt/lab-surabaya`

#### Scenario 10.4 — "Kuching: the version that must not move"
**Solution:**
```bash
sudo apt-mark hold ca-certificates          # freeze at current version
apt-mark showhold | grep ca-certificates    # confirms the hold
apt-get -s upgrade | grep -i ca-certificates # simulated upgrade shows it "kept back", not bumped
sudo apt-mark unhold ca-certificates        # release when done
```
**Why this works & what it teaches:** `apt-mark hold` sets a dpkg selection flag that makes apt refuse to upgrade (or remove) the package until unheld — so an unattended `apt-get upgrade` skips it and leaves it "kept back". That is version pinning for reproducible nodes/images: the "builds the same next year" guarantee (Rung 6, pinned vs latest). For an exact target you'd instead `apt-get install pkg=1.2.3`. **Where people go wrong:** pinning in one place but letting a Dockerfile `apt-get upgrade` or a vendor repo re-bump it — the hold must live wherever the install runs.
**Cleanup:** `sudo apt-mark unhold ca-certificates 2>/dev/null`

#### Scenario 10.5 — "Davao: trust, then install"
**Solution:**
```bash
cd /opt/lab-davao/release
sha256sum -c kubectl.sha256 || { echo "CHECKSUM FAILED — abort"; exit 1; }
gpg --verify kubectl.sig kubectl 2>&1 | grep -qi "Good signature" || { echo "SIG FAILED — abort"; exit 1; }
sudo install -m 0755 kubectl /usr/local/bin/kubectl    # only reached when BOTH pass
/usr/local/bin/kubectl
# now prove tamper-detection: flip a byte and re-verify
printf 'x' >> kubectl
sha256sum -c kubectl.sha256 2>&1 | grep -qi FAILED && echo "TAMPER CAUGHT — install would abort"
```
**Why this works & what it teaches:** With vendor binaries there's no apt to verify provenance, so you replay what apt does for free: `sha256sum -c` proves the bytes match what the vendor published (integrity), and `gpg --verify` proves the checksum/artifact came from the holder of the vendor key (authenticity). Only after both do you `install` into `/usr/local/bin`. Appending a byte changes the hash, so `sha256sum -c` reports FAILED and the guard aborts — catching a corrupted or tampered download *before* it enters PATH (Climb 10 Rung 6: "whose repository, whose signature?"). **Where people go wrong:** `curl -LO ... && install` with no verify — the convenience path that ships whatever the network handed you.
**Cleanup:** `sudo rm -f /usr/local/bin/kubectl; sudo rm -rf /opt/lab-davao`

#### Scenario 10.6 — "Malacca: the resolver vs the file-placer"
**Solution:**
```bash
# 1) dpkg alone only places files — it FAILS on the unmet dependency:
sudo dpkg -i /opt/lab-mrepo/retail-app_2.0_all.deb    # error: retail-lib not installed
# 2) publish the local repo so APT (the resolver) can walk the graph:
cd /opt/lab-mrepo && dpkg-scanpackages -m . /dev/null | gzip -9c > Packages.gz
echo "deb [trusted=yes] file:/opt/lab-mrepo ./" | sudo tee /etc/apt/sources.list.d/lab-malacca.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y retail-app                     # apt pulls in retail-lib automatically
command -v retail-lib && command -v retail-app
# (fallback route if you'd already dpkg-installed the broken app:)  sudo apt-get install -f -y
```
**Why this works & what it teaches:** This is the Rung 3 two-layer split made concrete: `dpkg` is the file-placer/DB — it unpacks and records but does *not* resolve dependencies, so it aborts when `retail-lib` is absent. `apt` is the resolver sitting above dpkg — given a repo index it computes the dependency graph, fetches `retail-lib`, and orders the installs (`apt-get install -f` fixes an already-broken dpkg state the same way). **Maps to the Dockerfile idiom:** this is why images chain `apt-get update && apt-get install -y ...` in one RUN — `update` refreshes the index the resolver reads, and keeping them in a single layer-cached RUN (Climb 9) stops a stale cached index from being resolved against, the classic "package not found / old version" build bug.
**Cleanup:** `sudo apt-get remove -y retail-app retail-lib 2>/dev/null; sudo rm -f /etc/apt/sources.list.d/lab-malacca.list; sudo apt-get update -qq; sudo rm -rf /opt/lab-malacca /opt/lab-mrepo`


