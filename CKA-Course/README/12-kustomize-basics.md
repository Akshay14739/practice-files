# Kustomize, Climbed the Ladder 🪜
### Section 12 of the CKA — deriving template-free, per-environment YAML

> Kustomize — plain-YAML customization built into `kubectl` (`-k`), and **on the current CKA curriculum** (unlike Helm). We climb from **the pain of copying manifests per environment** → **the "one base, layered overlays" idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How to keep one set of YAML and produce per-environment variants (dev/staging/prod) by patching only what differs — no templating language.

**Why did it land on my desk?** Kustomize is the config tool the **CKA actually tests** (it's built into `kubectl`), and it appears in tasks like "add a label/namespace/replica count across these manifests."

**What do I already know?** Maybe `kubectl apply -f`. What's fuzzy: base vs overlay, when to use a *transformer* vs a *patch*, and the two patch styles.

---

# RUNG 1 — The Pain 🔥
### *Why does Kustomize exist at all?*

Three environments, each needing small differences (dev 1 replica, staging 2, prod 5):

```
CUSTOMIZING PER ENVIRONMENT BY HAND (the pain)
  copy the whole manifest set ×3 (dev/, staging/, prod/) → drift is guaranteed
  a shared change (new label) → edit it in THREE places, miss one
  hand-edit replicas/image per env → error-prone, no single source of truth
```

**Before / without it:** you duplicated manifests per environment (they drift apart) or edited them by hand each deploy. Helm solves this with *templating*, but templated YAML is no longer plain/valid YAML you can read and `kubectl apply` directly.

**What breaks without it:** a single source of truth (duplicates diverge) and safe per-env variation (manual edits are fragile).

**Who feels it most?** Platform/app teams promoting the same app across environments.

> **✅ Check yourself before Rung 2:** Why is "copy the manifests into dev/, staging/, prod/ folders" a maintenance trap? What happens when you need to change something shared by all three?

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Kustomize keeps ONE **base** of plain, valid YAML and layers per-environment **overlays** that patch only what differs — with no templating language — so dev/staging/prod share a single source of truth and you never duplicate manifests.**

Derivations:
- *"one base… overlays patch only what differs"* → the base holds shared defaults; each overlay references the base (`resources: [../../base]`) and changes just its deltas.
- *"no templating language"* → everything stays **plain, valid YAML** (unlike Helm's `{{ }}`), so you can still `kubectl apply` a piece on its own and read it directly.
- *"patch only what differs"* → two tools for changing things: **transformers** (broad, e.g. label/namespace *everything*) and **patches** (surgical, e.g. *this* deployment's replicas).
- *(built-in)* `kubectl apply -k` renders base+overlay and applies — no separate binary needed.

> **✅ Check yourself before Rung 3:** In one sentence, what's the difference in *purpose* between a base and an overlay? What does an overlay do to avoid duplicating the base?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

## (A) base + overlays + `kustomization.yaml`

```
myapp/
├── base/                        # shared defaults
│   ├── kustomization.yaml
│   ├── deployment.yaml          # replicas: 1
│   └── service.yaml
└── overlays/
    ├── dev/kustomization.yaml       # resources: [../../base]  (uses default 1)
    ├── staging/kustomization.yaml   # + patch replicas: 2
    └── prod/kustomization.yaml      # + patch replicas: 5
```
Kustomize only reads a file named **`kustomization.yaml`** with two core parts: **`resources`** (the manifests) and **transformations**.
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
commonLabels: { company: KodeKloud }     # a transformer
```
```bash
kustomize build k8s/                    # RENDERS final YAML to stdout (does NOT apply)
kubectl apply -k k8s/                   # built-in: render + apply
kubectl delete -k k8s/                  # delete what it manages
```
> 🎯 `kustomize build` only **prints**; use **`kubectl apply -k`** to deploy. A root `kustomization.yaml` can list **directories** (each with its own kustomization) instead of files — one `apply -k` deploys everything.

## (B) Transformers — broad changes

Apply the **same change across many resources**:
| Transformer | Effect |
|---|---|
| `commonLabels` (newer: `labels`) | add a label to every resource |
| `commonAnnotations` | add an annotation to every resource |
| `namePrefix` / `nameSuffix` | prepend/append to every name |
| `namespace` | put every resource in a namespace |
| `images` | swap image name/tag |
```yaml
namespace: dev
namePrefix: kodekloud-
images:
- { name: mongo, newName: postgres, newTag: "4.2" }   # match on IMAGE name; quote numeric tags
```
> 🎯 **Scope:** a transformer in the **root** kustomization applies to **all** imported resources; the same in a **subdir's** kustomization applies **only** there. For `images`, match on the **image** name (not the container name).

## (C) Patches — surgical changes

Change one field on one object. Two styles:

**Strategic Merge Patch** (partial YAML — usually easier): paste a snippet with only what changes; merged by name.
```yaml
patches:
- path: replica-patch.yaml       # or inline with `patch: |`
```
```yaml
# replica-patch.yaml — a partial Deployment
apiVersion: apps/v1
kind: Deployment
metadata: { name: api-deployment }   # identifies the target
spec: { replicas: 5 }                # the only change
```
**JSON 6902 Patch** (op/path/value — precise, best for lists):
```yaml
patches:
- target: { kind: Deployment, name: api-deployment }
  patch: |-
    - op: replace                 # add | remove | replace
      path: /spec/replicas
      value: 5
```
- **`op`:** `replace` / `add` / `remove`. **`path`:** `/spec/replicas`, `/metadata/name`…
- **Lists use an index**: `/spec/template/spec/containers/0`; **`/-`** = append to the end.

> 🎯 **Strategic merge** = partial-YAML-that-looks-like-the-resource (readable, adding/changing fields). **JSON6902** = `op/path/value` (best for lists — indexes/`/-`, `remove`). Both can be inline (`patch: |-`) or a file (`path:`). Transformers = broad; patches = one-object surgery.

> **✅ Check yourself before Rung 4:** You want to (a) put every resource in namespace `prod`, and (b) set *one* deployment's replicas to 5. Which is a transformer and which is a patch?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which part |
|---|---|---|
| **base** | Shared default manifests | Model |
| **overlay** | Per-env layer referencing the base | Model |
| **kustomization.yaml** | The file Kustomize reads (`resources` + transforms) | Model |
| **resources** | Files or dirs to manage | kustomization |
| **transformer** | Broad change across resources | Transformers |
| **commonLabels / namePrefix / namespace / images** | Specific transformers | Transformers |
| **patch** | Change on one/few objects | Patches |
| **strategic-merge** | Partial-YAML patch, merged by name | Patches |
| **JSON6902** | `op/path/value` patch | Patches |
| **op / path / `/-`** | replace-add-remove / field path / append | JSON6902 |
| **kubectl apply -k** | Render + apply | Build/apply |
| **kustomize build** | Render to stdout only | Build/apply |

**The unlock — two axes:**
```
BREADTH:  transformer (many resources) ── vs ── patch (one object)
STYLE:    strategic-merge (partial YAML) ── vs ── JSON6902 (op/path/value)
STRUCTURE: base (shared) ── + ── overlay (per-env deltas)
```

> **✅ Check yourself before Rung 5:** Sort these into transformer vs patch: `namePrefix: kk-`; bump `api-deployment` replicas to 5; label everything `env=prod`; add a sidecar container to one pod.

---

# RUNG 5 — The Trace 🎬

**Trace — `kubectl apply -k overlays/prod`:**
1. Kustomize reads `overlays/prod/kustomization.yaml`.
2. Its `resources: [../../base]` pulls in the **base** manifests (deployment `replicas: 1`, service).
3. **Transformers** in the overlay run across those resources (e.g. `namespace: prod`, `namePrefix: prod-`, a `commonLabels`).
4. **Patches** run on their targets — e.g. a JSON6902 `replace /spec/replicas → 5` on the `web` Deployment.
5. Kustomize emits the **final rendered YAML** (base + transforms + patches); `kubectl` applies it.
6. The **base is untouched** (`replicas: 1`); only the rendered prod output has `5`. Swapping to `overlays/dev` renders the default `1` — same base, different result.

```
apply -k prod → read overlay → import base(replicas:1) → transformers(ns/prefix/labels)
             → patches(replicas→5) → final YAML → kubectl apply   (base stays 1)
```

> **✅ Check yourself before Rung 6:** After applying `overlays/prod`, what's `replicas` in the *base* deployment.yaml file on disk? Why didn't it change?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **Kustomize** | **Helm** | plain-YAML overlays, no templating, built into kubectl vs Go-templating + releases |
| **transformer** | **patch** | same change across many resources vs one-object surgery |
| **strategic-merge** | **JSON6902** | partial YAML by name vs `op/path/value` (best for lists) |
| **`kubectl apply -k`** | **`kustomize build`** | render + apply vs render to stdout only |
| **root-scope transformer** | **subdir-scope** | applies to all imported resources vs only that subdir |

**When NOT to:** don't use Kustomize when you need loops/conditionals/complex templating (that's Helm); don't forget it's `apply -k` to deploy (`build` alone only prints); don't reach for a patch when a transformer covers it (label/namespace everything → transformer).

**One-sentence "why this over that":**
> Use Kustomize for template-free, per-environment YAML that stays a single readable source of truth (and it's what the CKA tests); use Helm when you need full templating and packaged releases.

> **✅ Check yourself before Rung 7:** You need to append a container to the *end* of one pod's container list. Which patch style, and what does the `path` look like?

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — One `apply -k` deploys multiple directories

> **My prediction:** "If a root `kustomization.yaml` lists `api/` and `db/` (each with its own kustomization), then one `kubectl apply -k` creates everything — *because* Kustomize recurses into listed directories."

```bash
cat > k8s/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [api/, db/]
EOF
kubectl apply -k k8s/ ; kubectl get pods      # api + db from one command
```
**Verify:** one `apply -k` created resources across subdirectories — no per-folder apply.

## Prediction 2 — Overlays change replicas without touching the base

> **My prediction:** "If the base sets `replicas: 1` and the prod overlay patches it to 5, then `apply -k overlays/prod` deploys 5 while the base file still reads 1 — *because* the overlay patches the *rendered* output, not the base file."

```bash
# overlays/prod/kustomization.yaml: resources:[../../base] + a replace patch to 5
kubectl apply -k overlays/prod
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'   # 5
grep replicas base/deployment.yaml                            # still 1
```
**Verify:** prod = 5, base file = 1. Switch to `overlays/dev` → default 1.

## Prediction 3 — Transformers relabel/namespace/retag everything at once

> **My prediction:** "If I set `namespace`, `namePrefix`, `commonLabels`, and `images` in the root kustomization, then every object lands in that namespace, gets the prefix + label, and the image tag changes — *because* transformers apply broadly."

```yaml
# root kustomization.yaml
namespace: staging
namePrefix: kk-
images: [{ name: nginx, newTag: "1.26" }]
commonLabels: { env: staging }
```
```bash
kubectl apply -k k8s/
kubectl get deploy -n staging                              # names prefixed kk-, label env=staging
kubectl get deploy kk-web -n staging -o jsonpath='{..image}{"\n"}'   # nginx:1.26
```
**Verify:** every object got the namespace, prefix, label, and new tag — no manifest edits.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Kustomize renders a single base of plain YAML plus per-environment overlays that use transformers (broad changes) and patches (surgical changes) to alter only what differs — deployed with `kubectl apply -k`, no templating.

**Explain it to a beginner in 3 sentences:**
> 1. You keep one shared "base" of normal YAML and, per environment, a small overlay that changes only what's different.
> 2. Broad changes (namespace, labels, image, name prefix) are "transformers"; one-off changes (this deployment's replicas) are "patches."
> 3. `kubectl apply -k <dir>` renders base + overlay and applies it — and it's all valid YAML you can still read and apply by hand.

**Which rung to revisit hands-on?** Rung 3C — the **two patch styles** and JSON6902 list paths (`/containers/0`, `/-`) are the fiddly, testable bit.

---

## 🎯 CKA exam tips & quick notes

- **Deploy with `kubectl apply -k <dir>`** (or `kustomize build <dir> | kubectl apply -f -`). `build` alone only prints.
- **`kustomization.yaml`** must be named exactly that: `resources:` + transformers/patches.
- **Transformers** (`commonLabels`/`labels`, `namePrefix`/`nameSuffix`, `namespace`, `commonAnnotations`, `images`) = broad; **patches** = per-object.
- **Two patch styles:** strategic-merge (partial YAML, by `name`) and JSON6902 (`op/path/value`, `target`); lists use **index** or **`/-`**; quote numeric image tags.
- **Scope:** root transformer → all resources; subdir → only that subdir.
- **base + overlays:** overlay's `resources: [../../base]`, then patch the deltas. `kubectl delete -k` tears it down.

## 📌 Command cheat sheet
```bash
kubectl apply -k k8s/                 # deploy a kustomization
kubectl delete -k k8s/                # remove it
kustomize build k8s/                  # render only (stdout)
kustomize build k8s/ | kubectl apply -f -
# keys: resources, commonLabels/labels, namePrefix, nameSuffix, namespace,
#       commonAnnotations, images, patches (strategic-merge or JSON6902)
```

---

## Related sections

- [Section 11 — Helm Basics](11-helm-basics.md) — the templating alternative (contrast: templates vs plain-YAML overlays).
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — the manifests Kustomize customizes.
- [Section 1 — Core Concepts](01-core-concepts.md) — declarative `kubectl apply` that `-k` extends.
- [Section 7 — Storage](07-storage.md) / [Section 6 — Security](06-security.md) — resources you'd patch per environment.
