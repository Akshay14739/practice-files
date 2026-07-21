# Application Lifecycle, Climbed the Ladder 🪜
### Section 4 of the CKA — deriving how apps are configured, updated, and scaled

> Running and evolving apps: rollouts/rollbacks, commands/args, env + ConfigMaps + Secrets, and multi-container/init/sidecar patterns. We climb from **the pain of updating apps by hand** → **the one "it's all the pod template" idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** Everything about an app's life *after* you can create a pod: updating it with zero downtime, feeding it config and secrets, controlling its process, running helper containers, and scaling it.

**Why did it land on my desk?** *Workloads & Scheduling* is 15% of the CKA, and ConfigMaps/Secrets/rollouts show up in tasks and in troubleshooting (bad config = `CrashLoopBackOff`). This is high-YAML, high-imperative-shortcut territory.

**What do I already know?** Probably `kubectl set image`. What's fuzzy: why a rollout is "safe," the `command`↔`args` Docker trap, and that Secrets are *not* encrypted.

---

# RUNG 1 — The Pain 🔥
### *Why does lifecycle management exist at all?*

You can create a Deployment. Now real life happens: you need to ship v2, change a setting, rotate a password, and handle a spike — without an outage.

```
LIFE WITHOUT LIFECYCLE MANAGEMENT (the pain)

  new version   ─▶ stop ALL v1, start ALL v2         → downtime window, and no undo
  change a config value ─▶ rebuild the image, redeploy → 20-min loop for a one-line change
  a password    ─▶ baked into the image / in Git      → leaked forever
  bad deploy    ─▶ "how do we get back to yesterday?"  → panic, manual rollback
  traffic spike ─▶ SSH in and start more copies        → too slow, done by hand
```

**Before / without it:** config and secrets were baked into images (rebuild to change anything), updates were stop-the-world, and there was no revision history to roll back to.

**What breaks without it:** availability (no zero-downtime updates), agility (config changes need image rebuilds), security (secrets in images), and recoverability (no rollback).

**Who feels it most?** Everyone shipping software — but the platform team owns making updates *safe and reversible* for every team.

> **✅ Check yourself before Rung 2:** Name two things that force an image rebuild in the "before" world that Kubernetes lets you change *without* touching the image. (Hint: a setting, and a password.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **An app's entire life — the process it runs, the config and secrets it reads, how many copies exist, and how it's upgraded — is described in the Deployment's **pod template**; change the template and the Deployment performs a **rollout**: a new ReplicaSet scaled up as the old one scales down, recorded as a revision you can reverse.**

Derivations:
- *"the process it runs"* → `command`/`args` in the template override the image's ENTRYPOINT/CMD.
- *"config and secrets it reads"* → `env` / ConfigMaps / Secrets injected into the template; changing them is a template change → a new rollout.
- *"how many copies"* → `replicas` (scaling) — or an HPA driving it from metrics.
- *"how it's upgraded… new RS up as old scales down"* → this is why updates are **zero-downtime** and **contained**: a bad new version only affects the *new* ReplicaSet while the old keeps serving.
- *"recorded as a revision you can reverse"* → `kubectl rollout undo` = reconcile back to a previous template.

Once you see **every change is "edit the pod template, Kubernetes reconciles,"** rollouts, config, and scaling stop being separate topics.

> **✅ Check yourself before Rung 3:** If you `kubectl set image` a Deployment to a broken image, why do your *existing* users usually keep getting served during the failed rollout? (Hint: which ReplicaSet are the broken pods in?)

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of your app as a restaurant kitchen staffed by several identical cooks, all trained from one **master recipe card** (the "pod template"). This section is about five things: how the kitchen switches to a new recipe without closing, how you tell a cook exactly what to do, how you hand cooks their settings and passwords, how helper staff work, and how you add more cooks.
>
> **(A) Switching recipes without closing (rollouts).** When you update the recipe, the kitchen doesn't fire everyone at once. It hires one new-recipe cook, waits until that cook proves they can actually cook (passes a health check), then lets one old-recipe cook go — and repeats, batch by batch, so the restaurant never stops serving. Every recipe version is kept in a filing drawer (a "revision"), so if the new dish is a disaster you say "go back to yesterday's recipe" (rollback) and the swap runs in reverse. There's also a blunt alternative — fire everyone, then hire the new crew ("Recreate") — which closes the restaurant briefly and is only for when old and new can't work side by side. Crucially, if the new cooks turn out to be broken, the old crew keeps serving: a bad update stalls instead of taking you down.
>
> **(B) Telling the cook what to do (command and args).** Each cook runs exactly one job, and quits when it ends. The training manual (the app's packaged image) has a default job and default instructions; the recipe card can override either. The classic trap: the two override fields don't line up with the names people expect from the packaging tool (Docker) — one replaces the *program*, the other its *arguments*.
>
> **(C) Settings and passwords (ConfigMaps and Secrets).** Instead of laminating settings into the training manual (rebuilding the image for every change), you keep them on separate slips of paper: a pinboard note for ordinary settings (a "ConfigMap") and a sealed envelope for sensitive ones (a "Secret"). Either can be handed to a cook three ways: pin the whole sheet up, copy out one line, or leave it as a file in their station. One big warning: the "sealed" envelope is only *scrambled in a reversible way* (base64 encoding), not locked — anyone with access to the record room can read it. Real protection means locking the record room itself ("encryption at rest") and controlling who may enter.
>
> **(D) Helper staff (multi-container patterns).** A cooking station (pod) can hold more than one worker, sharing the same counter and phone line: a **prep worker** ("init container") who must finish setup — e.g. wait until the pantry is stocked — before the cook may start; and a **standing assistant** ("sidecar") who works alongside the cook the whole shift, e.g. carrying notes to the office.
>
> **(E) More cooks (scaling).** You can simply order five cooks instead of three, or install a thermostat (an "autoscaler") that hires and releases cooks automatically based on how busy the kitchen gets.

*Now the original technical deep-dive — the same ideas, in precise form:*

## (A) The rollout engine

A Deployment version = **rollout → new ReplicaSet → revision**. Kubernetes scales the new RS up while scaling the old down, one batch at a time.

```
RollingUpdate (default):  [v1 v1 v1 v1] → [v1 v1 v1 v2] → … → [v2 v2 v2 v2]   (seamless)
Recreate:                 [v1 v1 v1 v1] → [           ] → [v2 v2 v2 v2]        (downtime!)
```

| Strategy | Behavior | Downtime |
|---|---|---|
| **RollingUpdate** (default) | new RS up / old RS down in batches (`maxSurge`, `maxUnavailable`, default 25% each) | none |
| **Recreate** | kill all old, then create all new | brief outage |

```bash
kubectl rollout status deployment/web            # watch it
kubectl rollout history deployment/web           # revisions
kubectl set image deployment/web nginx=nginx:1.26   # imperative update (drifts from your file)
kubectl apply -f deploy.yaml                         # declarative (file = source of truth)
kubectl rollout undo deployment/web                  # roll back to previous
kubectl rollout undo deployment/web --to-revision=2
```
> 🎯 `set image` is fastest but your YAML no longer matches the live object. Switch strategy by editing `spec.strategy.type` (remove the `rollingUpdate:` block for `Recreate`). A bad new version = `CrashLoopBackOff`/`ImagePullBackOff` on the *new* RS → `kubectl rollout undo`.

## (B) The process it runs — command & args

A container runs **one process**; when it exits, the container exits. The image's `ENTRYPOINT`/`CMD` set that process; the pod overrides them:

| Docker | Pod field | Overrides |
|---|---|---|
| `ENTRYPOINT ["sleep"]` | `command:` | the executable |
| `CMD ["5"]` | `args:` | its default arguments |

```yaml
# Image: ENTRYPOINT ["sleep"]  CMD ["5"]  → default "sleep 5"
spec:
  containers:
  - name: ubuntu-sleeper
    image: ubuntu-sleeper
    command: ["sleep"]     # overrides ENTRYPOINT
    args: ["10"]           # overrides CMD → "sleep 10"
```
⚠️ **The trap:** `command` = ENTRYPOINT, **not** Docker's `CMD`. Array elements must be **strings** (`["sleep","5000"]`). Imperatively: everything after `--` is **args**; add `--command` to override the entrypoint too:
```bash
kubectl run web --image=webapp-color -- --color green     # args
kubectl run app --image=busybox --command -- sleep 1000   # command
```

## (C) Config & secrets — externalize what varies

**ConfigMap** (non-secret) and **Secret** (sensitive) are the same shape; you **create** then **inject**.

```bash
kubectl create configmap app-config --from-literal=APP_COLOR=blue --from-file=app.properties
kubectl create secret generic db-secret --from-literal=DB_PASSWORD='p@ss'
echo -n 'mysql' | base64        # encode for declarative YAML   |   base64 -d to decode
```
Inject three ways (identical for ConfigMap/Secret — swap `configMapRef`↔`secretRef`):
```yaml
envFrom:                                   # (a) whole object as env vars
- configMapRef: { name: app-config }
- secretRef:    { name: db-secret }
env:                                        # (b) one key → one env var
- name: APP_COLOR
  valueFrom: { configMapKeyRef: { name: app-config, key: APP_COLOR } }
volumes:                                    # (c) as files in a volume
- name: cfg
  configMap: { name: app-config }
```
> ⚠️ **Secrets are base64-*encoded*, not encrypted** — anyone with etcd/API access can decode them. Safety comes from *practice*: don't commit secret YAML, enable **encryption at rest**, use RBAC. Kubernetes helps: a Secret is only sent to nodes that need it and the kubelet keeps it in **tmpfs (RAM)**.

**Encryption at rest** (make etcd store secrets encrypted):
```bash
# 1) EncryptionConfiguration with an aescbc/secretbox provider + a base64 32-byte key
# 2) add to kube-apiserver.yaml:  --encryption-provider-config=/etc/kubernetes/enc/enc.yaml (+ mount)
# 3) verify it's no longer plaintext in etcd:
ETCDCTL_API=3 etcdctl --cacert=... --cert=... --key=... get /registry/secrets/default/my-secret | hexdump -C
kubectl get secrets -A -o json | kubectl replace -f -   # re-encrypt EXISTING secrets
```
Provider **order matters** — the *first* encrypts; put `identity` (no encryption) last. Only new/updated secrets get encrypted until you re-`replace`.

## (D) Multi-container patterns

Helpers that share the pod's **network (localhost), storage, and lifecycle** without merging code:

```
┌──────────────── Pod ────────────────┐
│ initContainers (run to completion,   │  ← wait for DB, run migrations (in ORDER, exit 0)
│    in ORDER)                         │
│           ↓ then                     │
│ containers: [ main-app, sidecar ]    │  ← run together for the pod's life
│    share localhost + volumes         │
└──────────────────────────────────────┘
```

| Pattern | Where | Lifecycle |
|---|---|---|
| **Co-located** | extra entries in `containers:` | start together, run for pod life |
| **Init** | `initContainers:` | sequential, **to completion**, before main; each exits 0 |
| **Sidecar** (native v1.33+) | `initContainers:` + `restartPolicy: Always` | starts first, **stays running** alongside |

```yaml
spec:
  initContainers:
  - name: init-db
    image: busybox:1.31
    command: ["sh","-c","until nslookup mydb; do sleep 2; done"]
  - name: log-sidecar               # native sidecar
    image: busybox:1.31
    restartPolicy: Always
    command: ["sh","-c","while true; do echo shipping logs; sleep 10; done"]
  containers:
  - { name: app, image: busybox:1.28, command: ["sh","-c","echo run && sleep 3600"] }
```
> 🎯 A pod stuck `Init:0/2` is waiting on an **init container** → `kubectl logs <pod> -c <init-name>`. `restartPolicy` is **container-level** (a crashed container restarts in place).

## (E) Scaling
```bash
kubectl scale deployment web --replicas=5
kubectl autoscale deployment web --min=2 --max=10 --cpu-percent=70   # HPA (needs Metrics Server)
```

> **✅ Check yourself before Rung 4:** Three questions, one each: (1) which pod field overrides the image's ENTRYPOINT? (2) which injection method makes a ConfigMap show up as *files*? (3) does base64-encoding a Secret make it secure — why/why not?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Machinery |
|---|---|---|
| **Rollout** | The process of moving to a new template version | Rollout engine |
| **Revision** | A saved snapshot of a rollout (for rollback) | `rollout history/undo` |
| **RollingUpdate / Recreate** | Strategies: batched swap / stop-all-start-all | `spec.strategy` |
| **maxSurge / maxUnavailable** | How many extra/absent pods during a roll | RollingUpdate knobs |
| **command / args** | ENTRYPOINT / CMD overrides | The container process |
| **env / envFrom / valueFrom** | Inject one var / whole object / one key | Config injection |
| **ConfigMap** | Externalized non-secret config | Config |
| **Secret** | Base64 (not encrypted) sensitive config | Config |
| **encryption at rest** | Make etcd store secrets encrypted | apiserver provider |
| **initContainer** | Runs to completion before the app | Multi-container |
| **sidecar** | Long-running helper (init + `restartPolicy: Always`) | Multi-container |
| **restartPolicy** | Always/OnFailure/Never, per **container** | Lifecycle |
| **HPA** | Autoscaler driving `replicas` from metrics | Scaling |

**The unlock:** everything is a **pod-template field** (`command`, `env`, `initContainers`, `replicas`). Change any → new template → the Deployment reconciles via a rollout. ConfigMap and Secret are *the same object* with different sensitivity + injection keyword.

> **✅ Check yourself before Rung 5:** Which of these trigger a new rollout when changed on a Deployment: `image`, `env`, `replicas`? (Two do something different from the third — which, and why?)

---

# RUNG 5 — The Trace 🎬

**Trace — a rolling update, then a rollback:**
1. `kubectl set image deployment/web nginx=nginx:1.26` edits the **pod template**.
2. The Deployment controller creates a **new ReplicaSet** (revision 2) at 0 replicas.
3. It scales the **new RS +1** (`maxSurge`) and, as those pods pass **readiness**, scales the **old RS −1** (`maxUnavailable`). Repeat batch by batch.
4. At each step total capacity stays ~100%, so **users never see downtime**; the old RS serves until the new pods are Ready.
5. You push a bad `nginx:doesnotexist`: the new RS's pods go `ImagePullBackOff` and **never become Ready**, so the rollout **stalls with the old RS still serving** — the failure is contained.
6. `kubectl rollout undo deployment/web` re-selects the previous template; the good old RS scales back to full, the bad RS to 0.

```
set image ─▶ template v2 ─▶ new RS(0) ──surge+1──▶ new pods Ready? ──yes──▶ old RS −1 … ─▶ all v2
                                              └── no (bad image) → stall, old RS keeps serving
undo ─▶ template v1 ─▶ old RS back to full, bad RS → 0
```

**Trace — config reaches the app:** at container start, the kubelet reads the referenced ConfigMap/Secret and sets the env vars (or mounts the volume) *before* running the process, so `printenv` inside shows `APP_COLOR`. Change the ConfigMap later → env vars **don't** update live (you must roll the pods); a mounted volume *does* eventually update.

> **✅ Check yourself before Rung 6:** In step 5, what specific pod condition stops the rollout from proceeding — and why is that the safety mechanism, not a bug?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **RollingUpdate** | **Recreate** | zero-downtime batched swap vs stop-all (needed when versions can't coexist) |
| **command** | **args** | overrides ENTRYPOINT (the program) vs CMD (its arguments) |
| **ConfigMap** | **Secret** | non-sensitive plaintext vs base64 sensitive (+ tmpfs, need-to-know delivery) |
| **env injection** | **volume mount** | fixed at start, no live update vs file that can update live |
| **init container** | **sidecar** | runs once to completion, blocks app vs runs alongside for pod life |
| **`set image`** | **`apply -f`** | fast but drifts from file vs file stays source of truth |

**When NOT to:** don't use `Recreate` for a stateless web app (needless downtime); don't put real secrets in a ConfigMap; don't rely on env-injected config updating live (it won't — roll the pods).

**One-sentence "why this over that":**
> Edit the pod template and let a RollingUpdate reconcile for zero-downtime, reversible changes; externalize settings to ConfigMaps and sensitive values to Secrets (with encryption at rest); use init containers to *gate* startup and sidecars to *accompany* the app.

> **✅ Check yourself before Rung 7:** A colleague changed a ConfigMap value but the running pods still show the old value. Explain *why*, and what makes it take effect.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — A bad image is contained to the new ReplicaSet

> **My prediction:** "If I `set image` to a non-existent tag, then new pods go `ImagePullBackOff` and the rollout stalls, but the app stays up — *because* the old RS keeps serving until the new pods are Ready, which they never become; `rollout undo` restores it."

```bash
kubectl create deployment web --image=nginx:1.25 --replicas=4
kubectl set image deployment/web nginx=nginx:1.26 && kubectl rollout status deployment/web
kubectl set image deployment/web nginx=nginx:doesnotexist
kubectl get pods                 # new pods ImagePullBackOff; old still Running
kubectl rollout undo deployment/web
```
**Verify:** during the bad roll, old pods keep serving; after `undo`, all run 1.26. If the whole app went down, check you weren't on `Recreate`.

## Prediction 2 — Injected config is immutable on a live pod

> **My prediction:** "If I `kubectl edit pod` to add `envFrom`, it's rejected (immutable), and I must `replace --force`; afterward `printenv` shows the ConfigMap + Secret values — *because* env is set at container start and can't change on a live pod."

```bash
kubectl create configmap web-config --from-literal=APP_COLOR=dark-blue
kubectl create secret generic db-secret --from-literal=DB_PASSWORD='p@ss123'
kubectl edit pod webapp-color        # add envFrom → save fails → kubectl saves to /tmp
kubectl replace --force -f /tmp/kubectl-edit-XXXXX.yaml
kubectl exec webapp-color -- printenv | grep -E 'APP_COLOR|DB_PASSWORD'
```
**Verify:** both values print after recreate. On a Deployment you'd just `kubectl edit deployment` (it rolls new pods automatically).

## Prediction 3 — An init container gates the app until its dependency exists

> **My prediction:** "If a pod has an init container that waits for service `mydb`, then the pod sits at `Init:0/1` until I create `mydb`, then flips to `Running` — *because* init containers must exit 0 before the main container starts."

```yaml
spec:
  initContainers:
  - name: wait-db
    image: busybox:1.31
    command: ["sh","-c","until nslookup mydb; do echo waiting; sleep 2; done"]
  containers: [{ name: app, image: nginx }]
```
```bash
kubectl apply -f app.yaml
kubectl get pod app            # Init:0/1
kubectl logs app -c wait-db    # "waiting..."
kubectl expose deployment mydb --port=80    # nslookup succeeds → app starts
```
**Verify:** `Init:0/1` → `Running` only after `mydb` exists. The *init* container's logs (via `-c`) explain the block.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> An app's process, config, secrets, replica count and update path all live in the Deployment's pod template — edit it and Kubernetes rolls a new ReplicaSet up as the old scales down (zero-downtime, reversible), while ConfigMaps/Secrets externalize settings and init/sidecar containers add setup and companions.

**Explain it to a beginner in 3 sentences:**
> 1. You never rebuild an image to change a setting or a password — you put those in ConfigMaps and Secrets and inject them into the pod.
> 2. To ship a new version you change the Deployment's template, and Kubernetes swaps pods a few at a time so users never see downtime — and keeps old versions so you can roll back instantly.
> 3. Extra containers can prepare the pod before the app starts (init) or run alongside it (sidecar), all sharing the pod's network and storage.

**Which rung to revisit hands-on?** Rung 3C — the ConfigMap/Secret injection shapes (`envFrom` vs `valueFrom` vs volume) and the "base64 ≠ encrypted" fact are the most-tested and most-confused.

---

## 🎯 CKA exam tips & quick notes

- **Rollout trio:** `kubectl set image deploy/x c=img:tag`, `kubectl rollout status|undo deploy/x`. Know cold.
- **`command` = ENTRYPOINT, `args` = CMD.** Container args after `--`; `--command` overrides the entrypoint.
- **Injection:** `envFrom` (whole), `env.valueFrom.*KeyRef` (one key), volume (files). `configMapRef`↔`secretRef`.
- **Secrets = base64, not encryption.** `echo -n x | base64` / `base64 -d`; `stringData:` skips manual encoding.
- **Immutable pod edit** → `kubectl replace --force -f /tmp/kubectl-edit-...yaml`; Deployment pods → `kubectl edit deployment`.
- **Init/sidecar debug:** `kubectl logs <pod> -c <container>`; `Init:x/y` = init phase.
- `kubectl create cm/secret --dry-run=client -o yaml > f.yaml` to template fast.

## 📌 Command cheat sheet
```bash
# ROLLOUTS
k set image deploy/web nginx=nginx:1.26
k rollout status|history|undo deploy/web
k rollout undo deploy/web --to-revision=2
k scale deploy web --replicas=5
# COMMANDS / ARGS
k run app --image=busybox --command -- sleep 1000     # command
k run web --image=webapp -- --color green             # args
# CONFIGMAP / SECRET
k create cm app-config --from-literal=K=V --from-file=app.props
k create secret generic db --from-literal=PASSWORD=p@ss
echo -n 'val' | base64      /      base64 -d
# INJECT (YAML):  envFrom:[{configMapRef|secretRef:{name:x}}]
```

---

## Related sections

- [Section 1 — Core Concepts](01-core-concepts.md) — Deployments/ReplicaSets that rollouts manage.
- [Section 7 — Storage](07-storage.md) — mounting ConfigMaps/Secrets as volumes.
- [Section 6 — Security](06-security.md) — encryption at rest, RBAC protecting secrets.
- [Section 3 — Logging & Monitoring](03-logging-monitoring.md) — `logs -c` for init/sidecar debugging.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — CrashLoopBackOff/ImagePullBackOff during rollouts.
- [../../Linux/26-tls-pki-openssl.md](../../Linux/26-tls-pki-openssl.md) — base64/OpenSSL underpinning Secrets and encryption at rest.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Name two things that force an image rebuild in the "before" world that Kubernetes lets you change *without* touching the image.

**A:** (1) **A setting (config value):** before, config was baked into the image, so a one-line change meant a rebuild-and-redeploy loop; Kubernetes externalizes it into a **ConfigMap** injected as env vars or files. (2) **A password (sensitive value):** before, secrets were baked into images or committed to Git — leaked forever; Kubernetes puts them in a **Secret** object injected at container start. In both cases you change the object and roll the pods — the image is never touched.

### Before Rung 3
**Q:** If you `kubectl set image` a Deployment to a broken image, why do your *existing* users usually keep getting served during the failed rollout?

**A:** Because a rollout is "a **new ReplicaSet** scaled up as the old one scales down" — the broken pods live entirely in the *new* ReplicaSet. Those pods go `ImagePullBackOff`/`CrashLoopBackOff` and never become Ready, so the Deployment never proceeds to scale the *old* ReplicaSet down; the old RS's healthy pods keep serving traffic the whole time. The failure is contained to the new RS, the rollout stalls, and `kubectl rollout undo` reverses it — that containment is exactly why rolling updates are "safe."

### Before Rung 4
**Q:** (1) Which pod field overrides the image's ENTRYPOINT? (2) Which injection method makes a ConfigMap show up as *files*? (3) Does base64-encoding a Secret make it secure — why/why not?

**A:** (1) **`command:`** overrides ENTRYPOINT (and `args:` overrides CMD — the classic trap is thinking `command` maps to Docker's CMD; it doesn't). (2) Mounting the ConfigMap as a **volume** (`volumes: - configMap: {name: ...}`) — each key becomes a file in the mount path; `envFrom` and `env.valueFrom` produce env vars, not files. (3) **No** — base64 is *encoding*, not encryption; anyone with etcd or API access can trivially `base64 -d` it back. Real safety comes from practice: don't commit secret YAML, enable **encryption at rest** on the API server, and restrict access with RBAC. Kubernetes helps a bit by sending a Secret only to nodes that need it and keeping it in tmpfs (RAM) on the kubelet.

### Before Rung 5
**Q:** Which of these trigger a new rollout when changed on a Deployment: `image`, `env`, `replicas`? Two do something different from the third — which, and why?

**A:** **`image` and `env` trigger a rollout; `replicas` does not.** `image` and `env` are fields *inside the pod template*, and the rule is: change the template → the Deployment creates a new ReplicaSet and performs a rollout, recorded as a new revision. `replicas` lives on the Deployment spec *outside* the pod template — changing it is pure scaling: the *existing* ReplicaSet is resized up or down, no new RS, no new revision, nothing to roll back.

### Before Rung 6
**Q:** In step 5 of the rollout trace, what specific pod condition stops the rollout from proceeding — and why is that the safety mechanism, not a bug?

**A:** The new pods never become **Ready** — with `nginx:doesnotexist` they sit in `ImagePullBackOff`, so the readiness condition that gates each batch is never met. The RollingUpdate engine only scales the old RS down (−1 per `maxUnavailable`) *after* the surged new pods pass readiness; since they never do, the rollout **stalls with the old ReplicaSet still at full strength and still serving**. That's the safety mechanism by design: readiness is the proof-of-health checkpoint between batches, so a bad version can never replace a good one — capacity stays ~100%, the blast radius is one stalled RS, and `rollout undo` cleanly reverses it.

### Before Rung 7
**Q:** A colleague changed a ConfigMap value but the running pods still show the old value. Why, and what makes it take effect?

**A:** Because the pods consume the ConfigMap as **env vars**, and env vars are set by the kubelet once, at container start, *before* the process runs — they are never updated on a live container. Changing the ConfigMap object afterward changes nothing inside already-running pods. To make it take effect you must **roll the pods** so new containers start and re-read the ConfigMap — e.g. `kubectl rollout restart deploy/web` or any pod-template change that triggers a rollout. (The exception: a ConfigMap mounted as a **volume** does eventually update live in the files — only env-injected config is frozen at start.)
