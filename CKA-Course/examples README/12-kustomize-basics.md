# 🧩 Section 12 — Kustomize Basics (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 12 transcript. **Kustomize is on the current CKA** (built into `kubectl -k`).

---

## 1. The base + overlays model

### ❓ What
Template-free per-environment config: one **base** of plain YAML + per-env **overlays** (dev/staging/prod) that change only what differs.

### 🔥 Pain points it solves & why this?
- Copying the manifest set per environment guarantees drift; hand-editing per deploy is fragile.
- Unlike Helm templates, everything stays **plain, valid YAML** — readable, lintable, individually `kubectl apply`-able.
- Single source of truth: a shared change happens once, in the base.

### ⚙️ How exactly it works
```
myapp/
├── base/                        # shared defaults
│   ├── kustomization.yaml
│   ├── deployment.yaml          # replicas: 1
│   └── service.yaml
└── overlays/
    ├── dev/kustomization.yaml       # resources: [../../base]      (default 1)
    ├── staging/kustomization.yaml   # + patch → replicas: 2
    └── prod/kustomization.yaml      # + patch → replicas: 5
```
Kustomize renders **base + overlay → final manifests**; the base files on disk never change.

### 🧪 Hands-on examples

**Example 1 — Build the structure and deploy prod:**
```bash
mkdir -p base overlays/{dev,prod}
kubectl create deployment web --image=nginx --dry-run=client -o yaml > base/deployment.yaml
cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml]
EOF
cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [../../base]
patches:
- target: { kind: Deployment, name: web }
  patch: |-
    - op: replace
      path: /spec/replicas
      value: 5
EOF
kubectl apply -k overlays/prod
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'   # 5
# Verify: prod renders 5; grep replicas base/deployment.yaml → still 1.
```

**Example 2 — Switch environments by switching overlays:**
```bash
cat > overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [../../base]
EOF
kubectl apply -k overlays/dev
kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'   # 1 (base default)
# Verify: same base, different overlay, different result — zero duplication.
```

**Example 3 — Change something shared, once:**
```bash
sed -i 's/image: nginx/image: nginx:1.26/' base/deployment.yaml
kubectl apply -k overlays/prod        # prod gets 1.26 AND keeps replicas 5
# Verify: one edit in the base propagated to every overlay.
```

---

## 2. kustomization.yaml + build/apply

### ❓ What
The control file Kustomize reads (must be named **`kustomization.yaml`**): `resources:` (files or **directories**) + transformations. Deploy with **`kubectl apply -k`**; render-only with `kustomize build`.

### 🔥 Pain points it solves & why this?
- Multi-directory projects (`api/`, `db/`) need one deploy command, not per-folder applies.
- `kustomize build` **only prints** — knowing that avoids the "I built but nothing deployed" confusion.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `resources:` | files or directories (each dir has its own kustomization.yaml) |
| `kustomize build <dir>` | render final YAML to stdout (no apply) |
| `kubectl apply -k <dir>` | render + apply (built-in kustomize) |
| `kubectl delete -k <dir>` | remove everything it manages |

### 🧪 Hands-on examples

**Example 1 — One apply across multiple directories:**
```bash
# k8s/{api,db}/ each with their manifests + kustomization.yaml, then:
cat > k8s/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [api/, db/]
EOF
kubectl apply -k k8s/
kubectl get pods            # api + db together
# Verify: one command deployed the whole tree.
```

**Example 2 — build vs apply:**
```bash
kustomize build k8s/ | head -20     # rendered YAML on stdout, cluster untouched
kubectl get deploy                   # nothing new
kustomize build k8s/ | kubectl apply -f -    # the pipe equivalent of -k
# Verify: build = preview; -k (or the pipe) = deploy.
```

**Example 3 — Tear it all down:**
```bash
kubectl delete -k k8s/
kubectl get all | grep -E 'api|db'   # gone
# Verify: -k manages the full set symmetrically (apply ↔ delete).
```

---

## 3. Transformers (broad changes)

### ❓ What
Declarative bulk edits across **all** resources in a kustomization: `commonLabels`/`labels`, `commonAnnotations`, `namePrefix`/`nameSuffix`, `namespace`, `images`.

### 🔥 Pain points it solves & why this?
- "Label everything," "prefix every name," "retag this image everywhere" by hand = touch every file, miss one.
- **Scope control**: a transformer in the root kustomization hits *all* imported resources; in a subdir's kustomization, only that subdir — layered conventions for free.

### ⚙️ How exactly it works
```yaml
namespace: dev
namePrefix: kodekloud-
nameSuffix: -web
commonLabels: { department: engineering }
commonAnnotations: { logging: verbose }
images:
- name: mongo            # matches the IMAGE name (not the container name!)
  newName: postgres
  newTag: "4.2"          # numeric tags must be QUOTED strings
```

### 🧪 Hands-on examples

**Example 1 — Namespace + prefix + label everything:**
```bash
# root kustomization.yaml gains:
#   namespace: staging
#   namePrefix: kk-
#   commonLabels: { env: staging }
kubectl create ns staging
kubectl apply -k k8s/
kubectl get deploy -n staging        # names prefixed kk-, label env=staging
# Verify: every object moved + renamed + labeled from three lines.
```

**Example 2 — Swap an image cluster-wide:**
```bash
# images: [ { name: nginx, newTag: "1.26" } ]
kubectl apply -k k8s/
kubectl get deploy kk-web -n staging -o jsonpath='{..image}{"\n"}'   # nginx:1.26
# Verify: match is on the IMAGE name; the container's name is irrelevant.
```

**Example 3 — Root vs subdir scope:**
```bash
# root kustomization: namePrefix: kodekloud-      (applies to ALL)
# k8s/api/kustomization.yaml: nameSuffix: -api    (applies to api/ only)
kubectl apply -k k8s/
kubectl get deploy       # kodekloud-web-api (both), kodekloud-db (prefix only)
# Verify: transformers compose by scope — global prefix, per-folder suffix.
```

---

## 4. Patches (strategic-merge & JSON6902)

### ❓ What
Surgical changes to **one/few objects**: **strategic-merge** (a partial YAML merged by name) and **JSON 6902** (`op/path/value` operations against a `target`).

### 🔥 Pain points it solves & why this?
- Transformers are all-or-nothing; you often need "*this* deployment's replicas → 5."
- Lists need precision — JSON6902's index paths (`/containers/0`) and append (`/-`) handle what merge-by-name can't.

### ⚙️ How exactly it works
```yaml
# strategic merge — partial resource, matched by kind+name:
patches:
- path: replica-patch.yaml        # a partial Deployment with just spec.replicas: 5

# JSON6902 — explicit ops:
patches:
- target: { kind: Deployment, name: api-deployment }
  patch: |-
    - op: replace                 # add | remove | replace
      path: /spec/replicas
      value: 5
```
Paths: `/spec/template/metadata/labels/org` (map key), `/spec/template/spec/containers/0` (list index), `/-` (append).

### 🧪 Hands-on examples

**Example 1 — Strategic merge for replicas:**
```bash
cat > replica-patch.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: api-deployment }
spec: { replicas: 5 }
EOF
# kustomization.yaml:  patches: [ { path: replica-patch.yaml } ]
kubectl apply -k .
kubectl get deploy api-deployment      # 5 replicas
# Verify: the patch looks like a tiny copy of the resource — merged by name.
```

**Example 2 — JSON6902 add/remove a label:**
```yaml
patches:
- target: { kind: Deployment, name: api-deployment }
  patch: |-
    - op: add
      path: /spec/template/metadata/labels/org
      value: kodekloud
    - op: remove
      path: /spec/template/metadata/labels/old-tag
```
```bash
kubectl apply -k . && kubectl get pods --show-labels
# Verify: org label added, old-tag gone — key-level surgery.
```

**Example 3 — Append a sidecar container with `/-`:**
```yaml
patches:
- target: { kind: Deployment, name: api-deployment }
  patch: |-
    - op: add
      path: /spec/template/spec/containers/-
      value: { name: sidecar, image: busybox, command: ["sleep","3600"] }
```
```bash
kubectl apply -k . && kubectl get pods    # 2/2 containers
# Verify: `/-` appended to the list; `/containers/0` would have targeted the first.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Which tool when:** broad change everywhere → transformer; one object → patch; readable partial YAML → strategic merge; list surgery/removals → JSON6902.
- `kubectl kustomize <dir>` = the built-in render-only command (same as `kustomize build`).
- Kustomize can also generate ConfigMaps/Secrets (`configMapGenerator`) with content-hash names that auto-roll deployments — beyond the course, common in practice.

---

## Related
[11-helm-basics](11-helm-basics.md) (the templating alternative) · [04-application-lifecycle-management](04-application-lifecycle-management.md) (the manifests being customized) · [01-core-concepts](01-core-concepts.md) (`kubectl apply`) · Ladder version: [../README/12-kustomize-basics.md](../README/12-kustomize-basics.md)
