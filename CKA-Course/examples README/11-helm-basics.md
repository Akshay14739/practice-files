# ⎈ Section 11 — Helm Basics (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 11 transcript. *(Helm is supplementary on the current CKA — Kustomize is the tested tool — but essential real-world knowledge.)*

---

## 1. Why Helm — the package-manager model

### ❓ What
The **package manager for Kubernetes**: a whole app (deployments + services + PVCs + secrets…) becomes one **chart**, installed as a named **release**, with every change recorded as a **revision**.

### 🔥 Pain points it solves & why this?
- A real app is 15+ manifests: apply each, hand-edit to change one value, track all to upgrade, delete one-by-one — and no "undo."
- One command per lifecycle action (`install`/`upgrade`/`rollback`/`uninstall`) treats the app as a unit.
- Release state is stored **as Secrets in the cluster**, so the whole team sees what's deployed.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| **Chart** | the package: templates + default values + metadata |
| **Release** | one *installation* of a chart (same chart → many named releases) |
| **Revision** | a snapshot; each install/upgrade/rollback creates a new one |
| **Repository / Artifact Hub** | where charts live / the global index |

### 🧪 Hands-on examples

**Example 1 — Install a whole app with one command:**
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm search repo nginx
helm install web bitnami/nginx
helm list ; kubectl get pods,svc     # several objects from ONE command
# Verify: release "web" revision 1; uninstalling later removes everything at once.
```

**Example 2 — Same chart, two releases:**
```bash
helm install site-a bitnami/nginx
helm install site-b bitnami/nginx
helm list                            # two independent releases of one chart
# Verify: chart = template; release = an instance — you can run many.
```

**Example 3 — Where Helm keeps its state:**
```bash
kubectl get secrets | grep sh.helm.release
# Verify: release metadata lives as in-cluster Secrets — team-visible, no local state file.
```

---

## 2. Helm 2 vs Helm 3

### ❓ What
The two-generation split: Helm 3 **removed Tiller**, adopted **three-way strategic merge**, and marks charts `apiVersion: v2` in `Chart.yaml`.

### 🔥 Pain points it solves & why this?
- Helm 2's **Tiller** ran in the cluster with god-mode rights — a security hole and an extra moving part. Helm 3 talks straight to the API server with **your RBAC**.
- Helm 2 compared only old-chart vs new-chart — it missed live `kubectl` edits. Helm 3's **three-way merge** (old chart + new chart + **live state**) preserves manual changes on upgrade and reverts them correctly on rollback.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| Tiller | Helm 2's removed server-side component |
| three-way merge | diff across old chart, new chart, live objects |
| `apiVersion: v1` / **`v2`** | Helm 2 chart / **Helm 3** chart (adds `dependencies`, `type`) |

### 🧪 Hands-on examples

**Example 1 — Prove there's no Tiller:**
```bash
kubectl get pods -A | grep -i tiller     # nothing
helm version                              # v3.x — client-only architecture
# Verify: no cluster-side component; Helm uses your kubeconfig identity.
```

**Example 2 — Helm respects your RBAC:**
```bash
kubectl auth can-i create deployments --as dev-user     # no
# as dev-user: helm install web bitnami/nginx → FORBIDDEN
# Verify: Helm 3 can do exactly what YOU can — no privilege bypass.
```

**Example 3 — Spot a chart's Helm generation:**
```bash
helm pull bitnami/nginx --untar
grep apiVersion nginx/Chart.yaml         # v2 → Helm 3 chart
# Verify: v1 = legacy Helm 2 chart; v2 supports dependencies/type.
```

---

## 3. Chart structure (Chart.yaml, values.yaml, templates/)

### ❓ What
A chart's anatomy: `Chart.yaml` (metadata), `values.yaml` (default config), `templates/` (manifests with `{{ .Values.x }}` placeholders), `charts/` (sub-chart dependencies).

### 🔥 Pain points it solves & why this?
- One chart must serve many configs (sizes, hostnames, passwords) → templating splits *structure* (templates) from *settings* (values).
- Two version fields confuse people: **`version`** = the chart's own version; **`appVersion`** = the app it deploys (informational).

### ⚙️ How exactly it works
```
mychart/
├── Chart.yaml        # apiVersion: v2, name, version (CHART), appVersion (APP)
├── values.yaml       # defaults the templates read
├── templates/        # deployment.yaml etc. with {{ .Values.replicaCount }}
└── charts/           # dependencies (e.g. mariadb for wordpress)
```
At install, Helm renders templates with values → concrete manifests → applies them.

### 🧪 Hands-on examples

**Example 1 — Dissect a real chart:**
```bash
helm pull bitnami/wordpress --untar
cat wordpress/Chart.yaml | head          # version vs appVersion, dependencies (mariadb!)
head -30 wordpress/values.yaml           # the knobs users override
grep -m2 "{{" wordpress/templates/deployment.yaml
# Verify: you can point at where a value flows from values.yaml into a template.
```

**Example 2 — Render without installing:**
```bash
helm template wordpress ./wordpress | head -40
helm install my-site ./wordpress --dry-run | head -40
# Verify: concrete YAML with placeholders filled — inspect before you commit.
```

**Example 3 — Make your own minimal chart:**
```bash
helm create mychart                      # scaffold
sed -i 's/replicaCount: 1/replicaCount: 3/' mychart/values.yaml
helm install demo ./mychart
kubectl get deploy                       # 3 replicas from your value
# Verify: your edit in values.yaml drove the rendered Deployment.
```

---

## 4. Core commands (install/upgrade/history/rollback)

### ❓ What
The lifecycle verbs: `repo add/update`, `search hub|repo`, `install`, `list`, `upgrade`, `history`, `rollback`, `uninstall`.

### 🔥 Pain points it solves & why this?
- The revision trail (`history`) is a deploy audit log you get for free.
- **Rollback creates a NEW revision** (rev 3 = rev 1's config) — history only moves forward, so nothing is ever lost.
- ⚠️ Rollbacks restore **manifests, not data** (a PV's contents aren't in a revision).

### ⚙️ How exactly it works
`upgrade` renders the new chart/values, three-way merges with live state, applies, bumps the revision. `rollback <rev>` re-applies that revision's manifests as a new revision.

### 🧪 Hands-on examples

**Example 1 — Upgrade then inspect history:**
```bash
helm install nginx-release bitnami/nginx --version 13.2.10
helm upgrade nginx-release bitnami/nginx           # → revision 2
helm history nginx-release                          # install, upgrade rows
# Verify: each action = a numbered revision with its own status.
```

**Example 2 — Roll back and read the numbers:**
```bash
helm rollback nginx-release 1                       # → revision 3 (rev-1 config)
helm history nginx-release                          # rev 3: "Rollback to 1"
kubectl describe pod -l app.kubernetes.io/name=nginx | grep Image   # old image back
# Verify: live revision is 3, config equals 1 — forward-only history.
```

**Example 3 — Clean removal:**
```bash
helm uninstall nginx-release
kubectl get all | grep nginx        # gone
helm list                            # empty
# Verify: one command removed every object of the release.
```

---

## 5. Customizing values (--set, --values, pull & edit)

### ❓ What
Three ways to override chart defaults: `--set k=v` (inline), `--values file.yaml` (bulk), or `helm pull --untar` + edit `values.yaml` + install from the local dir.

### 🔥 Pain points it solves & why this?
- Defaults never fit production; you need per-install config without forking the chart.
- Predictable layering: **`--set` > `--values` > chart `values.yaml`**.

### ⚙️ How exactly it works
All overrides merge onto the chart's `values.yaml` before rendering. `helm get values <release>` shows what you overrode; `--version` pins a chart version.

### 🧪 Hands-on examples

**Example 1 — Quick inline overrides:**
```bash
helm install my-site bitnami/wordpress \
  --set wordpressBlogName="Helm Tutorials" --set wordpressEmail=john@example.com
helm get values my-site
# Verify: your two overrides are recorded on the release.
```

**Example 2 — A values file for many settings:**
```bash
cat > vals.yaml <<'EOF'
wordpressBlogName: My Site
wordpressUsername: admin
EOF
helm install my-site2 bitnami/wordpress --values vals.yaml
# Verify: bulk overrides applied; file is Git-trackable (unlike --set history).
```

**Example 3 — Precedence probe:**
```bash
helm install p bitnami/nginx --values vals.yaml --set replicaCount=5
helm get values p            # replicaCount: 5 — --set beat the file
# Verify: --set > --values > values.yaml, always.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **`helm template`** renders 100 % client-side (no cluster needed) — great for CI diffing.
- Rollback restores manifests **not data** — pair Helm with real backups ([Section 5](05-cluster-maintenance.md)) for stateful apps.
- On the exam, reach for **Kustomize** ([Section 12](12-kustomize-basics.md)) — it's the tested tool; `helm.sh/docs` is allowed if Helm appears.

---

## Related
[12-kustomize-basics](12-kustomize-basics.md) (the exam's config tool) · [04-application-lifecycle-management](04-application-lifecycle-management.md) (rollouts Helm wraps) · [06-security](06-security.md) (the RBAC Helm 3 uses) · Ladder version: [../README/11-helm-basics.md](../README/11-helm-basics.md)
