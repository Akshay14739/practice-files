# 🔄 Section 4 — Application Lifecycle Management (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 4 transcript.

---

## 1. Rolling Updates & Rollbacks

### ❓ What
A Deployment upgrade mechanism: each pod-template change triggers a **rollout** that creates a **new ReplicaSet** and shifts pods old→new batch by batch, recorded as a **revision** you can roll back to.

### 🔥 Pain points it solves & why this?
- Stop-all/start-all upgrades = downtime windows and angry users.
- A bad release with no undo = manual panic recovery.
- Batched replacement means capacity never drops below the safety margin, and revisions give one-command rollback.

### ⚙️ How exactly it works
```
RollingUpdate:  [v1 v1 v1 v1] → [v1 v1 v1 v2] → … → [v2 v2 v2 v2]   (seamless)
Recreate:       [v1 v1 v1 v1] → [           ] → [v2 v2 v2 v2]        (downtime!)
```

| Vocabulary | Meaning |
|---|---|
| **rollout** | the transition to a new template |
| **revision** | saved snapshot per rollout (`rollout history`) |
| **RollingUpdate** | default; `maxSurge`/`maxUnavailable` (25 % each) control batch size |
| **Recreate** | kill all old first — only when versions can't coexist |
| `set image` | fast imperative update (⚠️ your YAML file drifts) |

### 🧪 Hands-on examples

**Example 1 — Update and watch the RS swap:**
```bash
kubectl create deployment web --image=nginx:1.25 --replicas=4
kubectl set image deployment/web nginx=nginx:1.26
kubectl rollout status deployment/web
kubectl get rs                       # old RS → 0, new RS → 4
# Verify: two ReplicaSets exist; only the new one has pods.
```

**Example 2 — Roll back a bad release:**
```bash
kubectl set image deployment/web nginx=nginx:doesnotexist
kubectl get pods                     # new pods ImagePullBackOff; OLD PODS STILL SERVING
kubectl rollout undo deployment/web
kubectl rollout history deployment/web
# Verify: the app never went down (old RS kept serving); undo restored 1.26.
```

**Example 3 — Switch strategy to Recreate:**
```bash
kubectl edit deployment web
#  spec.strategy.type: Recreate     (and DELETE the rollingUpdate: block)
kubectl set image deployment/web nginx=nginx:1.27
kubectl get pods -w                  # ALL pods terminate, THEN new ones start
# Verify: a visible gap with zero pods — the Recreate downtime, live.
```

---

## 2. Commands & Arguments (ENTRYPOINT/CMD → command/args)

### ❓ What
Pod-spec fields that override what process a container runs: `command:` overrides the image's **ENTRYPOINT**, `args:` overrides its **CMD**.

### 🔥 Pain points it solves & why this?
- A container runs one process defined by the image; you often need different flags/durations without rebuilding the image.
- The naming trap — `command` ≠ Docker's `CMD` — causes real exam mistakes; learning the mapping kills the confusion.

### ⚙️ How exactly it works

| Docker | Pod field | Overrides |
|---|---|---|
| `ENTRYPOINT ["sleep"]` | `command:` | the executable |
| `CMD ["5"]` | `args:` | its default arguments |

Array elements must be **strings** (`["sleep","5000"]`, never a bare number). Imperatively: everything after `--` = args; add `--command` to set the entrypoint too.

### 🧪 Hands-on examples

**Example 1 — Override just the args:**
```yaml
# image ubuntu-sleeper: ENTRYPOINT ["sleep"], CMD ["5"]
spec:
  containers:
  - name: sleeper
    image: ubuntu-sleeper
    args: ["10"]                 # runs "sleep 10" (entrypoint kept)
```
```bash
kubectl apply -f sleeper.yaml && kubectl get pod sleeper
# Verify: pod survives ~10 s, not 5 — args replaced CMD only.
```

**Example 2 — Override both, imperatively:**
```bash
kubectl run app --image=busybox --command -- sleep 1000   # command = sleep, args = 1000
kubectl run web --image=webapp-color -- --color green     # args only (after --)
kubectl get pod app -o jsonpath='{.spec.containers[0].command}{"\n"}'
# Verify: app has command:["sleep","1000"]; web has only args.
```

**Example 3 — The string-vs-number unmarshal error:**
```yaml
command: ["sleep", 5000]     # ← WRONG: 5000 is a number
```
```bash
kubectl apply -f bad.yaml    # error: cannot unmarshal number into ... string
# fix: ["sleep", "5000"]
# Verify: quoting the number fixes it — a 10-second exam save.
```

---

## 3. Environment Variables, ConfigMaps & Secrets

### ❓ What
Externalized configuration: plain `env` vars, **ConfigMaps** (non-secret key/values), and **Secrets** (sensitive values, base64-encoded — *not* encrypted).

### 🔥 Pain points it solves & why this?
- Config baked into images = rebuild for every setting change; per-env images multiply.
- Passwords in manifests/images end up in Git — Secrets separate them (and Kubernetes only ships a secret to nodes that need it, kept in tmpfs).
- One object, many consumers: change the ConfigMap, every pod referencing it picks it up on next start.

### ⚙️ How exactly it works
**Create** then **inject** — three injection shapes, identical for CM/Secret:

| Injection | ConfigMap | Secret |
|---|---|---|
| whole object → env | `envFrom: [configMapRef]` | `envFrom: [secretRef]` |
| one key → one var | `valueFrom.configMapKeyRef` | `valueFrom.secretKeyRef` |
| as files | `volumes[].configMap` | `volumes[].secret` |

Secrets in YAML: base64 under `data:` (`echo -n 'x' | base64`) or plaintext under `stringData:`.

### 🧪 Hands-on examples

**Example 1 — ConfigMap → whole-object env injection:**
```bash
kubectl create configmap app-config --from-literal=APP_COLOR=blue --from-literal=APP_MODE=prod
kubectl run webapp --image=nginx --dry-run=client -o yaml > w.yaml
# add to the container:   envFrom: [ { configMapRef: { name: app-config } } ]
kubectl apply -f w.yaml
kubectl exec webapp -- printenv | grep APP_
# Verify: both keys appear as env vars.
```

**Example 2 — Secret with decode round-trip:**
```bash
kubectl create secret generic db-secret --from-literal=DB_PASSWORD='p@ss123'
kubectl get secret db-secret -o yaml           # value is base64…
kubectl get secret db-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
# Verify: base64 -d returns the plaintext — proof Secrets are ENCODED, not encrypted.
```

**Example 3 — Mount a ConfigMap as files:**
```yaml
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts: [ { name: cfg, mountPath: /etc/appcfg } ]
  volumes:
  - name: cfg
    configMap: { name: app-config }
```
```bash
kubectl exec app -- ls /etc/appcfg          # APP_COLOR  APP_MODE (one file per key)
kubectl exec app -- cat /etc/appcfg/APP_COLOR
# Verify: each key = a file; file contents = the value.
```

---

## 4. Encrypting Secrets at Rest

### ❓ What
Configuring the API server to **encrypt Secrets inside etcd** using an `EncryptionConfiguration` (aescbc/secretbox provider + key).

### 🔥 Pain points it solves & why this?
- Without it, anyone who can read etcd (or its backups!) reads every secret in plaintext.
- Base64 is not protection; encryption at rest closes the etcd/backup exposure.

### ⚙️ How exactly it works
1. Write an `EncryptionConfiguration` with providers in order — **the first provider encrypts**; `identity: {}` (no encryption) goes last.
2. Point the apiserver at it: `--encryption-provider-config=/etc/kubernetes/enc/enc.yaml` (+ volume mount) — the static pod restarts.
3. Only **new/updated** secrets get encrypted → rewrite existing ones.

### 🧪 Hands-on examples

**Example 1 — Prove secrets are plaintext in etcd first:**
```bash
kubectl create secret generic s1 --from-literal=key1=supersecret
ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/s1 | hexdump -C | grep -A2 super
# Verify: "supersecret" is readable in the raw etcd value. Yikes.
```

**Example 2 — Enable encryption:**
```bash
head -c 32 /dev/urandom | base64      # the key
sudo mkdir -p /etc/kubernetes/enc && sudo tee /etc/kubernetes/enc/enc.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - aescbc: { keys: [ { name: key1, secret: <BASE64-KEY> } ] }
  - identity: {}
EOF
# add --encryption-provider-config + hostPath volume/mount to kube-apiserver.yaml; wait for restart
# Verify: apiserver returns; kubectl works again after ~1 min.
```

**Example 3 — Confirm + re-encrypt old secrets:**
```bash
kubectl create secret generic s2 --from-literal=key2=alsosecret
# etcdctl get /registry/secrets/default/s2 | hexdump -C   → starts with k8s:enc:aescbc — encrypted!
kubectl get secrets -A -o json | kubectl replace -f -      # rewrite EXISTING secrets
# Verify: s1's etcd value is now also unreadable; only rewritten secrets get encrypted.
```

---

## 5. Scaling (manual + HPA)

### ❓ What
Changing replica count: manually (`kubectl scale`) or automatically via the **HorizontalPodAutoscaler** driving `replicas` from metrics.

### 🔥 Pain points it solves & why this?
- Traffic varies; fixed replica counts either waste money or fall over.
- HPA closes the loop: observed CPU% vs target → adjust replicas (needs the Metrics Server from [Section 3](03-logging-monitoring.md)).

### ⚙️ How exactly it works
HPA loop: every ~15 s, desiredReplicas = ceil(current / target × replicas), clamped to min/max.

### 🧪 Hands-on examples

**Example 1 — Manual scale, three ways:**
```bash
kubectl scale deployment web --replicas=5
kubectl edit deployment web                    # spec.replicas
kubectl patch deployment web -p '{"spec":{"replicas":2}}'
# Verify: get deploy shows READY tracking each change.
```

**Example 2 — Create an HPA:**
```bash
kubectl autoscale deployment web --min=2 --max=10 --cpu-percent=70
kubectl get hpa                                # TARGETS e.g. 5%/70%
# Verify: replicas sit at min while idle.
```

**Example 3 — Trigger it with load:**
```bash
kubectl run load --image=busybox -it --rm -- \
  sh -c 'while true; do wget -qO- http://web >/dev/null; done'
kubectl get hpa -w                             # utilization climbs → replicas increase
# Verify: replicas scale up under load and (after ~5 min cool-down) back down.
```

---

## 6. Multi-Container Pods: co-located, init & sidecar

### ❓ What
Patterns for helper containers sharing a pod's network (localhost), volumes, and lifecycle: **co-located** (run together), **init** (run to completion first, in order), **sidecar** (native ≥1.33: an init container with `restartPolicy: Always` that keeps running alongside).

### 🔥 Pain points it solves & why this?
- Apps need companions (log shipper, proxy, DB-wait, migrations) without merging codebases.
- Ordering: the app must not start before its dependency check passes → init containers gate startup.
- A log-shipper must live exactly as long as the app, beside it → sidecar.

### ⚙️ How exactly it works
```
┌──────────────── Pod ────────────────┐
│ initContainers: run IN ORDER, each   │  ← must exit 0; failure restarts the pod's init phase
│   to completion, BEFORE main         │
│ containers: [ app, helper ]          │  ← start together, run for pod life
│   share localhost + volumes          │
└──────────────────────────────────────┘
```
`restartPolicy` (Always/OnFailure/Never) acts per **container** — crashed containers restart in place.

### 🧪 Hands-on examples

**Example 1 — Init container gates the app on a service:**
```yaml
spec:
  initContainers:
  - name: wait-db
    image: busybox:1.31
    command: ["sh","-c","until nslookup mydb; do echo waiting; sleep 2; done"]
  containers: [ { name: app, image: nginx } ]
```
```bash
kubectl apply -f app.yaml
kubectl get pod app              # Init:0/1 (blocked)
kubectl logs app -c wait-db      # "waiting…"
kubectl create deployment mydb --image=redis && kubectl expose deployment mydb --port=80
kubectl get pod app              # Running
# Verify: pod starts ONLY after mydb resolves.
```

**Example 2 — Native sidecar (init + restartPolicy Always):**
```yaml
spec:
  initContainers:
  - name: log-shipper                   # starts FIRST, keeps running
    image: busybox:1.31
    restartPolicy: Always
    command: ["sh","-c","while true; do echo shipping; sleep 10; done"]
  containers:
  - { name: app, image: busybox:1.28, command: ["sh","-c","echo run && sleep 3600"] }
```
```bash
kubectl apply -f sidecar.yaml && kubectl get pod -w    # 2/2 Running
kubectl logs <pod> -c log-shipper --tail=3
# Verify: the "init" container never exits — it's a sidecar, up before and beside the app.
```

**Example 3 — Co-located containers sharing a volume:**
```yaml
spec:
  containers:
  - name: writer
    image: busybox
    command: ["sh","-c","while true; do date >> /data/log.txt; sleep 5; done"]
    volumeMounts: [ { name: shared, mountPath: /data } ]
  - name: reader
    image: busybox
    command: ["sh","-c","tail -f /data/log.txt"]
    volumeMounts: [ { name: shared, mountPath: /data } ]
  volumes: [ { name: shared, emptyDir: {} } ]
```
```bash
kubectl logs <pod> -c reader -f
# Verify: reader streams what writer writes — shared emptyDir, shared lifecycle.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **Probes** (CKA-relevant even though this course section skips them): `livenessProbe` restarts a stuck container; `readinessProbe` gates Service traffic — and readiness is what a RollingUpdate waits on before scaling the old RS down.
- **Secret Store CSI driver** (course bonus): pulls secrets from AWS/Vault at runtime and mounts them as files — no Kubernetes Secret object exists at all.
- Editing a **Deployment's** pod template (`kubectl edit deployment`) automatically rolls new pods — no `replace --force` gymnastics like with bare pods.

---

## Related
[01-core-concepts](01-core-concepts.md) (Deployments/RS) · [03-logging-monitoring](03-logging-monitoring.md) (crash logs) · [06-security](06-security.md) (RBAC around secrets) · [07-storage](07-storage.md) (volumes) · Ladder version: [../README/04-application-lifecycle-management.md](../README/04-application-lifecycle-management.md)
