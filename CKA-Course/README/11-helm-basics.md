# Helm, Climbed the Ladder 🪜
### Section 11 of the CKA — deriving why a whole app can be one versioned package

> Helm — the **package manager for Kubernetes**. We climb from **the pain of managing dozens of manifests** → **the "an app is one versioned package" idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**. *Note: Helm is largely supplementary to the current CKA (Kustomize is the tested config tool — [Section 12](12-kustomize-basics.md)), but it's essential real-world knowledge, in the course, and `helm.sh/docs` is allowed in the exam.*

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How Helm bundles an entire application's Kubernetes objects into one installable, upgradable, rollback-able package.

**Why did it land on my desk?** It's in the CKA course and it's how real teams ship apps (WordPress, Prometheus, etc.). Even if the exam leans on Kustomize, knowing Helm's chart/release/revision model is table stakes on the job.

**What do I already know?** Maybe `helm install`. What's fuzzy: the chart-vs-release-vs-revision distinction, and why a rollback creates a *new* revision instead of deleting history.

---

# RUNG 1 — The Pain 🔥
### *Why does Helm exist at all?*

A real app is a dozen-plus objects (Deployments, Services, PVCs, Secrets, ConfigMaps):

```
MANAGING A REAL APP WITHOUT HELM (the pain)
  install:  kubectl apply -f  (×15 files, in the right order)
  tweak:    change PV size / replicas → hand-edit multiple YAMLs
  upgrade:  track all 15 objects, apply the changed ones, hope nothing drifts
  rollback: "what did it look like yesterday?" → no record
  remove:   kubectl delete ×15, and miss one
```

**Before / without it:** you `kubectl apply` each file, hand-edit to change one value, manually track everything to upgrade, and delete objects one-by-one — with no notion of "the app, version 3."

**What breaks without it:** atomicity (an app is many objects but should be managed as one), parameterization (changing one value shouldn't mean editing many files), and history (no clean upgrade/rollback of the whole app).

**Who feels it most?** Anyone deploying off-the-shelf or complex apps repeatedly across environments.

> **✅ Check yourself before Rung 2:** Name two operations that are painful on a 15-object app without a package manager that Helm makes a single command. (Hint: install, and undo.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Helm treats a whole application as one *versioned package*: a **chart** is a set of templated manifests + default **values**, installing it creates a **release**, and every install/upgrade/rollback is a numbered **revision** you can move between — so you manage N objects as one unit.**

Derivations:
- *"chart = templated manifests + values"* → `templates/*.yaml` with `{{ .Values.x }}` placeholders filled from `values.yaml`; that's how one chart serves many configs.
- *"installing creates a release"* → the same chart can be installed many times (each a separate **release** with its own name), and Helm stores each release's state **as a Secret in the cluster** so the whole team sees it.
- *"every action is a numbered revision"* → `helm history` is an audit trail; a **rollback to revision 1 creates revision 3** (history only moves forward, never deletes).
- *"manage N objects as one unit"* → one `install`/`upgrade`/`uninstall` acts on the entire app.

> **✅ Check yourself before Rung 3:** Chart, release, revision — say what each is in one phrase. If you install the same chart twice, how many releases and how many revisions exist?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow*

## (A) The model

| Term | What it is |
|---|---|
| **Chart** | The package — templates + default values + metadata |
| **Release** | One *installation* of a chart (many per chart, each named) |
| **Revision** | A snapshot; each install/upgrade/rollback makes a new one |
| **Repository** | Where charts are hosted (Bitnami…); **Artifact Hub** lists them all |
| **Release state** | Stored **as Secrets in the cluster** (team-visible) |

## (B) Helm 2 vs 3 (know the differences)

- **Tiller removed in Helm 3** — Helm 2 needed a cluster-side `Tiller` running in "god mode" (a security hole). Helm 3 talks straight to the API server using **your RBAC** (like kubectl).
- **Three-way strategic merge** — Helm 3 upgrades/rollbacks compare the **old chart, new chart, AND live cluster state**, so it preserves manual `kubectl` changes on upgrade and reverts them correctly on rollback (Helm 2 only compared charts).
- **`Chart.yaml apiVersion`:** `v1` = Helm 2; **`v2` = Helm 3** (adds `dependencies`, `type`).

## (C) Chart structure

```
mychart/
├── Chart.yaml        # metadata (apiVersion v2, name, version, appVersion)
├── values.yaml       # DEFAULT config values (the file you usually edit)
├── templates/        # templated manifests ({{ .Values.x }})
└── charts/           # sub-charts (dependencies)
```
```yaml
# Chart.yaml
apiVersion: v2            # v2 = Helm 3
name: wordpress
version: 15.2.5           # the CHART version
appVersion: "6.1.0"       # the APP version it deploys (informational)
```
`version` = chart version; `appVersion` = the app it ships. `{{ .Values.foo }}` pulls from `values.yaml`.

## (D) Commands + override precedence

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm search hub wordpress          # Artifact Hub (all repos)   |  search repo = your repos
helm install my-site bitnami/wordpress      # <release> <chart>
helm list -A                                 # all releases
helm upgrade my-site bitnami/wordpress
helm history my-site                         # revisions + action
helm rollback my-site 1                       # → a NEW revision with rev-1's config
helm uninstall my-site
```
**Customize (precedence: `--set` > `--values` > chart `values.yaml`):**
```bash
helm install my-site bitnami/wordpress --set wordpressBlogName="Helm Tutorials"
helm install my-site bitnami/wordpress --values custom-values.yaml
helm pull bitnami/wordpress --untar && vi wordpress/values.yaml && helm install my-site ./wordpress
```
> 🎯 A **rollback to revision 1 creates revision 3** — Helm never deletes history, it moves forward. `helm template` / `--dry-run` renders without installing. Rollbacks restore **manifests, not data** (a PV's DB isn't in a revision).

> **✅ Check yourself before Rung 4:** If `values.yaml` sets `replicas: 1`, a `--values` file sets `3`, and `--set replicas=5`, how many replicas deploy — and why?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which part |
|---|---|---|
| **Chart** | The package | Model |
| **Release** | One install of a chart | Model |
| **Revision** | A versioned snapshot | Model / history |
| **Repository / Artifact Hub** | Chart hosting / index | Distribution |
| **values.yaml** | Default config | Templating |
| **template / `{{ .Values }}`** | Manifest with placeholders | Templating |
| **Chart.yaml (apiVersion v2)** | Metadata; v2 = Helm 3 | Metadata |
| **version vs appVersion** | Chart version vs app version | Metadata |
| **Tiller** | Helm 2's removed server component | Helm 2 vs 3 |
| **three-way merge** | old chart + new chart + live state | Helm 3 upgrades |
| **--set / --values** | CLI override / file override | Customization |
| **helm pull --untar** | Download a chart locally | Customization |

**The unlock:** a chart is a **template**; a release is a **rendered instance**; a revision is a **saved version of that instance**. Everything else (repos, values, history) supports that trio.

> **✅ Check yourself before Rung 5:** Which stores where the app's *runtime data* lives — a Helm revision, or the PV? So what does a rollback actually restore?

---

# RUNG 5 — The Trace 🎬

**Trace — install → upgrade → rollback:**
1. `helm install my-site bitnami/wordpress`: Helm **fetches the chart**, **renders** `templates/` with `values.yaml` into concrete manifests, **applies** them to the cluster, and records **release `my-site`, revision 1** as a Secret.
2. `helm upgrade my-site …`: Helm renders the new chart/values, does a **three-way merge** against live state, applies the diff, and records **revision 2**.
3. A problem appears. `helm history my-site` shows rev 1 and 2. `helm rollback my-site 1`: Helm re-applies rev 1's manifests and records **revision 3** (whose config equals rev 1's) — history moved forward, nothing was deleted.
4. `helm uninstall my-site` removes every object of the release in one shot.

```
install → render(chart+values) → apply → release/rev 1 (Secret)
upgrade → render → 3-way merge → apply → rev 2
rollback 1 → re-apply rev-1 manifests → rev 3 (=rev1 config)
```

> **✅ Check yourself before Rung 6:** After the rollback, what revision number is live, and what config does it contain? Why isn't it "revision 1" again?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **Helm** | **Kustomize** | Go-templating + values + releases vs plain-YAML overlays (no templating) |
| **Helm** | **raw `kubectl apply`** | whole-app package + rollback vs per-file, no history |
| **Helm 3** | **Helm 2** | uses your RBAC, no Tiller, 3-way merge vs Tiller in god-mode, 2-way |
| **version** | **appVersion** | the chart's version vs the app's version |
| **`--set`** | **`--values` / values.yaml** | inline override (highest) vs file / defaults |

**When NOT to:** for the **CKA exam**, reach for **Kustomize** (it's the tested tool); don't expect Helm rollbacks to restore *data* (only manifests); don't hand-edit a release's live objects (the next upgrade's 3-way merge may fight you — change values instead).

**One-sentence "why this over that":**
> Use Helm to install and version *whole applications* (especially third-party ones) as parameterized packages with real upgrade/rollback; use Kustomize for plain-YAML, template-free per-environment tweaks — and that's what the CKA tests.

> **✅ Check yourself before Rung 7:** Why is Helm 3 considered more secure than Helm 2 for a shared cluster? Name the component that went away and what replaced its permissions.

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — One command installs the whole app; one removes it

> **My prediction:** "If I `helm install`, then a Deployment + Service (and more) appear from a single command, and `helm uninstall` removes them all at once — *because* Helm manages the release as one unit."

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
helm install web bitnami/nginx
helm list ; kubectl get pods,svc          # created by one command
helm uninstall web                        # all gone
```
**Verify:** one install created multiple objects; one uninstall removed them. Compare to N `kubectl apply`/`delete`.

## Prediction 2 — Rollback creates a new, higher revision

> **My prediction:** "If I install, upgrade, then `helm rollback … 1`, then `helm history` shows revision 3 labeled 'rollback to 1', not a return to revision 1 — *because* Helm's history only moves forward."

```bash
helm install nginx-release bitnami/nginx --version 13.2.10
helm upgrade nginx-release bitnami/nginx        # → rev 2
helm rollback nginx-release 1                    # → rev 3 (= rev 1 config)
helm history nginx-release                       # rev 3 "rollback to 1"
```
**Verify:** the live revision is 3 with rev-1's config. The pod image reverts, but the revision number climbed.

## Prediction 3 — `--set` beats `--values` beats defaults

> **My prediction:** "If I override a value with `--set`, `helm get values` shows my override taking effect over the chart default — *because* `--set` has the highest precedence."

```bash
helm install my-site bitnami/wordpress --set wordpressBlogName="My Site" --set wordpressUsername=admin
helm get values my-site                   # confirms the overrides
```
**Verify:** `helm get values` lists your overrides layered over defaults.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Helm packages a whole app as a chart (templated manifests + default values); installing it makes a release whose every install/upgrade/rollback is a numbered, cluster-recorded revision — so you manage many objects, and their history, as one unit.

**Explain it to a beginner in 3 sentences:**
> 1. Instead of applying and tracking a dozen YAML files, you install one chart, and Helm creates and manages all the objects together as a "release."
> 2. You customize a chart's values at install time, and each install/upgrade/rollback is a numbered revision you can move between.
> 3. Helm 3 talks to the cluster with your own permissions (no Tiller), and rollbacks restore the manifests — but not the app's data.

**Which rung to revisit hands-on?** Rung 3D + Prediction 2 — the **revision model** (rollback = new revision) and **override precedence** are the two things people get wrong.

---

## 🎯 CKA / real-world tips & quick notes

- **Helm 3 = no Tiller**, uses your **RBAC**; `apiVersion: v2` in `Chart.yaml`.
- **Chart vs release vs revision:** package / one install / a snapshot.
- **Commands:** `repo add/update`, `search hub/repo`, `install`, `list -A`, `upgrade`, `history`, `rollback <rev>`, `uninstall`, `pull --untar`.
- **Override precedence:** `--set` > `--values` > chart `values.yaml`.
- **Rollback = new revision** (forward-only) and restores **manifests, not data**.
- `helm template` / `--dry-run` renders without applying; release metadata is stored as **Secrets**.

## 📌 Command cheat sheet
```bash
helm repo add <name> <url> && helm repo update
helm search repo <chart>            helm search hub <chart>
helm install <release> <chart> [--set k=v] [--values f.yaml] [--version x]
helm list -A                        helm history <release>
helm upgrade <release> <chart>      helm rollback <release> <revision>
helm uninstall <release>            helm pull <chart> --untar
helm get values <release>           helm template <chart>      # render only
```

---

## Related sections

- [Section 12 — Kustomize Basics](12-kustomize-basics.md) — the config tool that IS on the CKA (contrast with Helm).
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — rollouts/rollbacks Helm wraps.
- [Section 1 — Core Concepts](01-core-concepts.md) — the objects a chart bundles.
- [Section 6 — Security](06-security.md) — the RBAC Helm 3 relies on.
