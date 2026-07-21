# Security, Climbed the Ladder 🪜
### Section 6 of the CKA — deriving how the cluster proves identity and limits power

> The largest CKA section — TLS/PKI, the CSR API, kubeconfig, RBAC, service accounts, image secrets, security contexts, and network policies. It looks like ten unrelated topics; it's really **one layered idea**. We climb from **the pain of an open cluster** → **the gatekeeping idea** → **the machinery** → then the commands as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** How Kubernetes answers two questions on *every* action — *who are you?* and *what may you do?* — plus how it confines what a running workload can do and reach.

**Why did it land on my desk?** Security spans two big CKA domains (Cluster Architecture 25% for RBAC/certs; Services & Networking 20% for NetworkPolicy). **Cert troubleshooting and RBAC tasks are exam staples**, and a broken cert can take the whole control plane down.

**What do I already know?** Maybe `kubectl config use-context`. What's fuzzy: why there are *two* CAs, the difference between "unauthorized" and "forbidden," and why a NetworkPolicy sometimes does nothing.

---

# RUNG 1 — The Pain 🔥
### *Why does cluster security exist at all?*

The API server is the keys to the kingdom — it can create, read, and delete everything, including Secrets. Without security layers:

```
THE OPEN-CLUSTER PAIN
  anyone who reaches :6443 ─▶ full control of every workload + every Secret
  a compromised pod        ─▶ runs as root with all Linux capabilities → owns the node
  any pod                  ─▶ can reach any other pod (flat network) → lateral movement
  a new teammate           ─▶ "just share the admin kubeconfig" → nobody has least privilege
  a private image          ─▶ can't be pulled at all (no registry creds)
```

**Before / without it:** no cryptographic identity (anyone claiming to be admin *is* admin), no least privilege (every credential is all-powerful), and a flat network where one popped pod can scan the whole cluster.

**What breaks without it:** confidentiality (Secrets readable by all), integrity (anyone mutates anything), and blast-radius control (one compromise = total compromise).

**Who feels it most?** The platform/security team — you must let many humans and apps use one cluster *without* handing each the master key.

> **✅ Check yourself before Rung 2:** Name the two distinct questions any secure system must answer for a request, and give a Kubernetes example of each. (Hint: identity, then permission.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **Kubernetes security is layered gatekeeping: the API server first **authenticates** *who you are* (TLS client certs for humans/components, tokens for service accounts) then **authorizes** *what you may do* (RBAC) — and separately, each workload is **confined** by the identity it runs as (security context) and which pods it may reach (network policy).**

Derivations:
- *"authenticates via TLS certs / tokens"* → all the PKI, the `/etc/kubernetes/pki` certs, the **CSR API** (how a new user gets a cert), and **kubeconfig** (where your cert lives) are just *authentication plumbing*.
- *"authorizes via RBAC"* → **Role/RoleBinding** (namespaced) and **ClusterRole/ClusterRoleBinding** (cluster-wide) are *authorization*. A `403 Forbidden` is an authz failure; a `401 Unauthorized` is an authn failure.
- *"tokens for service accounts"* → pods get a **ServiceAccount** identity, then RBAC decides what that SA may do — same two-step, just for apps.
- *"confined by identity it runs as"* → **security context** (runAsUser, dropped Linux capabilities).
- *"which pods it may reach"* → **NetworkPolicy** (a pod-level firewall).

Every topic in this section is one of those four boxes: **who / what-may-you-do / what-power / who-can-it-talk-to.**

> **✅ Check yourself before Rung 3:** A user's `kubectl get pods` returns `Forbidden`. Which of the two gates did they pass, and which did they fail? What would `Unauthorized` have meant instead?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — the most important rung. Go slow.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of the cluster as a high-security office building. This section explains, piece by piece, how the building checks who you are, what you're allowed to do, and what each worker inside can touch.
>
> **(A) Proving identity with certificates.** Everyone in the building carries a tamper-proof ID badge. A "certificate" is that badge: it names you, and it carries the signature of a trusted badge office (the "CA," or Certificate Authority — the office everyone agrees to trust). Each badge comes in two parts: a public half anyone can look at, and a private half (a secret key) you must never share — like the raised seal only the real owner can produce. The building actually has **two separate badge offices**: one for the whole building, and a private one used only by the records vault (etcd — the cluster's filing cabinet where everything is stored). Mixing up which office stamped which badge is a classic way the front desk stops recognizing people.
>
> **(B) Getting a badge.** A newcomer fills out a badge application (a "CSR" — Certificate Signing Request), a manager approves it, and the badge office stamps it. Your wallet (the "kubeconfig" file) then holds your badge plus the building's address, so you can walk up and be recognized.
>
> **(C) Permissions.** A valid badge only proves *who* you are. A separate permissions list ("RBAC" — role-based access control) says *what* you may do: "this person may read the mailroom, but not open the safe." Some permission lists apply to one floor only (a Role, for one namespace — a walled-off department); others apply building-wide (a ClusterRole). There's even a way to test "could this person do X?" without them actually trying.
>
> **(D) Badges for machines.** Software running inside the building gets its own kind of badge too — a "service account" with a short-lived pass slipped into its room — so apps are checked the same way people are.
>
> **(E) Limiting workers once inside.** Three final controls: a job description limiting what powers a program runs with (the "security context" — e.g., never run as the all-powerful root user); a stored courier password for fetching packages from private warehouses ("image pull secrets" for private software downloads); and internal door locks ("NetworkPolicy") deciding which rooms may talk to which — by default every room can call every other room, until you lock one down and list its allowed visitors. One catch: the locks only work if the building's wiring contractor (the network plugin) actually installs them — some contractors silently ignore the order.

*Now the original technical deep-dive — the same ideas, in precise form:*

## (A) The TLS/PKI foundation — how identity is proven

- **Asymmetric crypto:** a key **pair** — a **public key** (share freely) and a **private key** (kept secret). A **certificate** = public key + identity (CN/SANs) **signed by a CA**. You trust a cert if a **CA you trust** signed it. A **CSR** asks a CA to sign your public key + identity. **PKI** = the whole system.
- Naming: `.crt`/`.pem` = public cert; **`.key` = private key** (keep secret).
- **Three cert roles:** **server** certs (apiserver/etcd/kubelet prove *they* are legit), **client** certs (admin/scheduler/controller-manager/kubelet authenticate *to* the apiserver), **CA** cert (everyone verifies the others with `ca.crt`).

**Where the certs live (kubeadm) — note the TWO CAs:**
```
/etc/kubernetes/pki/
├── ca.crt / ca.key                    # CLUSTER CA (Issuer: "kubernetes")
├── apiserver.crt / .key               # apiserver SERVING cert
├── apiserver-etcd-client.crt/.key     # apiserver → etcd (client)
├── apiserver-kubelet-client.crt/.key  # apiserver → kubelet (client)
└── etcd/
    ├── ca.crt / ca.key                # SEPARATE etcd CA (Issuer: "etcd-ca")
    └── server.crt / server.key        # etcd serving cert
```
```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout
# read:  Subject: CN=kube-apiserver   Issuer: CN=kubernetes
#        X509v3 Subject Alternative Name: DNS:kubernetes, ...svc.cluster.local, IP:10.96.0.1
#        Validity: Not Before / Not After   ← expiry
```
> 🎯 When `kubectl` is dead, the control-plane containers still exist: **`crictl ps -a | grep apiserver`** + **`crictl logs <id>`**. The classic break is a wrong cert **path** or the **wrong CA** in `etcd.yaml`/`kube-apiserver.yaml` → "certificate signed by unknown authority" (you mixed the cluster CA with etcd's own CA).

## (B) Authentication — getting and using a client cert

**The CSR API** (how a new human gets access): they make a key + CSR; the admin creates a **CertificateSigningRequest**, approves it; the **controller-manager** signs it (with `--cluster-signing-cert-file/-key-file`).

```bash
openssl genrsa -out akshay.key 2048
openssl req -new -key akshay.key -out akshay.csr -subj "/CN=akshay"   # CN = username, O = group
```
```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: { name: akshay }
spec:
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
  request: <cat akshay.csr | base64 -w0>        # SINGLE line (no wraps!)
```
```bash
kubectl apply -f csr.yaml
kubectl certificate approve akshay              # or: certificate deny <name>
kubectl get csr akshay -o jsonpath='{.status.certificate}' | base64 -d > akshay.crt
```
> 🎯 `base64 -w0` prevents wrapping ("illegal base64 data" otherwise). **`CN` = username, `O` = group** — a CSR requesting `O=system:masters` = full cluster-admin, so **`deny`** suspicious ones.

**kubeconfig** (`~/.kube/config`) bundles **clusters** (endpoint + CA), **users** (client cert/token), **contexts** (user × cluster × namespace):
```bash
kubectl config get-contexts
kubectl config use-context prod-admin@prod
kubectl config set-context --current --namespace=dev
```
Certs go as file paths *or* inline base64 (`client-certificate-data`). A wrong path = "unable to read client cert."

## (C) Authorization — RBAC

**Modes** on the apiserver (evaluated in order; deny → next, allow → stop): `--authorization-mode=Node,RBAC,Webhook`. **Node** authorizes kubelets; **RBAC** is what you configure; ABAC/Webhook/AlwaysAllow-Deny exist.

**Role + RoleBinding = namespaced.** A Role is `(apiGroups, resources, verbs)` rules; a RoleBinding grants it to a subject *in one namespace*.
```yaml
kind: Role                             # apiVersion: rbac.authorization.k8s.io/v1
metadata: { name: developer, namespace: default }
rules:
- apiGroups: [""]                      # "" = core (pods, services, configmaps)
  resources: ["pods"]
  verbs: ["get","list","create","delete"]
  # resourceNames: ["blue"]            # optional: restrict to NAMED objects
---
kind: RoleBinding
metadata: { name: dev-binding, namespace: default }
subjects: [{ kind: User, name: dev-user, apiGroup: rbac.authorization.k8s.io }]
roleRef: { kind: Role, name: developer, apiGroup: rbac.authorization.k8s.io }
```
**ClusterRole + ClusterRoleBinding = cluster-wide** (for cluster-scoped resources — nodes, PVs, namespaces, CSRs — or a namespaced resource across *all* namespaces).
```bash
kubectl create role developer --verb=get,list,create,delete --resource=pods
kubectl create rolebinding dev-binding --role=developer --user=dev-user
kubectl create clusterrole node-reader --verb=get,list,watch --resource=nodes
kubectl create clusterrolebinding michelle-binding --clusterrole=node-reader --user=michelle
kubectl auth can-i create deployments --as dev-user -n blue     # TEST without logging in
kubectl api-resources --namespaced=false                        # what's cluster-scoped
```
> 🎯 Roles/bindings are **namespaced** — always `-n <ns>`. "Forbidden" ⇒ check the Role's `apiGroups`/`resources`/`verbs`/`resourceNames` and the binding's `subjects`. `apiGroups: [""]`=core, `["apps"]`=deployments/replicasets.

## (D) Service Accounts — identity for pods

Users are for humans; **ServiceAccounts** for apps. Every namespace has a `default` SA; its **bound token** (short-lived, projected) mounts at `/var/run/secrets/kubernetes.io/serviceaccount/token`.
```bash
kubectl create serviceaccount dashboard-sa
kubectl create token dashboard-sa --duration=48h      # short-lived token
```
```yaml
spec:
  serviceAccountName: dashboard-sa
  automountServiceAccountToken: false     # opt out
```
Grant permissions via RBAC with `subjects: [{kind: ServiceAccount, name: dashboard-sa, namespace: default}]`.

## (E) Workload confinement — security context, image secrets, network policy

**Security context** — the UID and Linux **capabilities** a container runs with. Pod-level applies to all; container-level overrides; **capabilities are container-only.**
```yaml
spec:
  securityContext: { runAsUser: 1001, fsGroup: 2000 }   # POD level
  containers:
  - name: app
    securityContext:                                     # CONTAINER (wins)
      runAsUser: 1002
      runAsNonRoot: true
      readOnlyRootFilesystem: true
      capabilities: { add: ["NET_ADMIN"], drop: ["ALL"] }
```
**Image pull secrets** — private registries:
```bash
kubectl create secret docker-registry regcred \
  --docker-server=my-registry.io:5000 --docker-username=u --docker-password='p'
# then: spec.imagePullSecrets: [{ name: regcred }]
```
**NetworkPolicy** — **default is every pod can reach every pod.** Selecting a pod flips it to **default-deny** for the chosen direction; you add explicit allows. **Replies are auto-allowed** (stateful) — only reason about the direction traffic *originates*. **Needs an enforcing CNI** (Calico/Cilium/Weave) — **plain Flannel ignores it silently.**
```yaml
kind: NetworkPolicy                    # networking.k8s.io/v1
metadata: { name: db-policy }
spec:
  podSelector: { matchLabels: { role: db } }    # protect db
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: { matchLabels: { name: api } }   # allow only api
    ports: [{ protocol: TCP, port: 3306 }]
```
**AND vs OR gotcha:** `podSelector` + `namespaceSelector` in the **same `from` item** = AND; split into **two `-` items** = OR. `ipBlock` allows external CIDRs.
> 🎯 An **Egress** policy that selects a pod **blocks its DNS too** — allow egress to CoreDNS (UDP/TCP **53**) or name resolution breaks.

> **✅ Check yourself before Rung 4:** Four quick ones: (1) which CA signs a *user's* client cert? (2) does `403` mean authn or authz failed? (3) where does a pod find its service-account token? (4) why might a NetworkPolicy you applied do nothing?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which box |
|---|---|---|
| **CA / PKI** | Trust anchor / whole cert system | Authn (identity) |
| **client cert (CN/O)** | A human/component's identity (CN=user, O=group) | Authn |
| **CSR / signerName** | Request to sign a cert / which signer | Authn (issue) |
| **kubeconfig (cluster/user/context)** | Where your cert + endpoint live | Authn (use) |
| **server cert** | apiserver/etcd/kubelet proving themselves | Authn (TLS) |
| **authorization-mode** | Node,RBAC,Webhook order | Authz |
| **Role / RoleBinding** | Namespaced permissions + grant | Authz |
| **ClusterRole / ClusterRoleBinding** | Cluster-wide permissions + grant | Authz |
| **verbs / apiGroups / resources** | The permission triple | Authz |
| **can-i** | Test a permission as a user | Authz (debug) |
| **ServiceAccount / bound token** | App identity + its credential | Authn (pods) |
| **imagePullSecret** | Registry creds for private images | Workload |
| **securityContext / capabilities** | UID + Linux powers a container has | Confinement (power) |
| **NetworkPolicy / podSelector** | Pod firewall + who it targets | Confinement (reach) |
| **CRD / Operator** | New API kind / its controller | (awareness) |

### The big unlock: four boxes, not ten topics

```
WHO ARE YOU (authn):        certs · CSR API · kubeconfig · service-account tokens
WHAT MAY YOU DO (authz):    Role/RoleBinding · ClusterRole/ClusterRoleBinding · can-i
WHAT POWER (confine):       securityContext (runAsUser, capabilities) · imagePullSecrets
WHO CAN IT TALK TO (confine): NetworkPolicy (podSelector/namespaceSelector/ipBlock)
```

Human and ServiceAccount are the **same two-step** (identity → RBAC), just different identity sources.

> **✅ Check yourself before Rung 5:** Sort into the four boxes: a `ClusterRoleBinding`, a `runAsNonRoot: true`, a `CertificateSigningRequest`, a `podSelector` ingress rule.

---

# RUNG 5 — The Trace 🎬
### *Follow ONE request through every gate*

**Trace — `kubectl get pods -n blue` as user `akshay`:**
1. **kubeconfig** selects akshay's context → his **client cert** + the cluster CA + endpoint `:6443`.
2. **TLS handshake:** the apiserver presents its **server cert** (akshay verifies it against the cluster CA); akshay presents his **client cert**; the apiserver verifies it was **signed by the cluster CA**. ✅ **Authentication** passes → identity = `CN=akshay`, groups from `O=…`. (A cert signed by an untrusted CA → **401 Unauthorized**, and the trace ends here.)
3. **Authorization:** modes run in order. **Node** doesn't apply (akshay isn't a kubelet). **RBAC** searches namespace `blue` for a (Cluster)RoleBinding whose subject is akshay, whose Role allows verb `list` on resource `pods`. If found → allow; if not → **403 Forbidden** (authenticated but not permitted).
4. **Admission** controllers run ([Section 2](02-scheduling.md)) — none reject a read.
5. The apiserver reads pods from **etcd** and returns them.

```
kubeconfig → TLS (server cert ✓ + client cert signed by cluster CA ✓)  ── authn ──▶ CN=akshay
      → Node? no · RBAC: binding+role allow (list,pods,blue)? ── authz ──▶ allow/403
      → admission → etcd → pod list
```

**Trace — a blocked pod-to-pod call:** `web` pod → `db:3306`. The `db-policy` NetworkPolicy selected `db` for Ingress, allowing only `podSelector name=api`. The CNI (Calico) has programmed the node's dataplane to **drop** `web`'s SYN to `db:3306` → `web`'s `nc` times out, while `api`'s connects (its reply is auto-allowed).

> **✅ Check yourself before Rung 6:** In the first trace, at which step would a cert signed by the *wrong* CA fail, and what HTTP error results? At which step does a missing RoleBinding fail, and what error?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **Authentication (401)** | **Authorization (403)** | *unknown identity* vs *known but not permitted* |
| **Cluster CA** | **etcd CA** | signs apiserver/user/kubelet certs vs signs only etcd's certs (separate trust) |
| **Role / RoleBinding** | **ClusterRole / ClusterRoleBinding** | one namespace vs cluster-wide (or all namespaces) |
| **User** | **ServiceAccount** | human identity (cert) vs app identity (token), same RBAC after |
| **pod-level** | **container-level** securityContext | default for all containers vs override (container wins; caps are container-only) |
| **default network** | **NetworkPolicy** | allow-all vs default-deny once a pod is selected |
| **same `from` item** | **two `from` items** | AND (pod *and* namespace) vs OR |

**When NOT to:** don't grant `ClusterRole` when a namespaced `Role` suffices (least privilege); don't run containers as root or with `capabilities.add` beyond need (`drop: ["ALL"]` first); don't apply a NetworkPolicy on Flannel expecting enforcement; don't forget DNS egress when locking a pod's egress.

**One-sentence "why this over that":**
> Authenticate with certs/tokens and authorize with the *narrowest* RBAC (namespaced Role over ClusterRole), then confine workloads to a non-root identity with dropped capabilities and a default-deny NetworkPolicy — trust nothing more than it needs.

> **✅ Check yourself before Rung 7:** A pod runs fine but `etcd` throws "certificate signed by unknown authority" after someone edited `etcd.yaml`. Which CA did they probably point it at, and which should it be?

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — CSR + RBAC gives exactly the granted access, nothing more

> **My prediction:** "If I sign akshay a cert and bind a pods-only Role, then `can-i delete pods --as akshay` is **yes** but `can-i delete nodes` is **no** — *because* authentication succeeds (valid cert) but authorization only matches the pods Role."

```bash
openssl genrsa -out akshay.key 2048
openssl req -new -key akshay.key -out akshay.csr -subj "/CN=akshay"
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: { name: akshay }
spec:
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
  request: $(cat akshay.csr | base64 -w0)
EOF
kubectl certificate approve akshay
kubectl create role pod-mgr --verb=get,list,create,delete --resource=pods
kubectl create rolebinding akshay-binding --role=pod-mgr --user=akshay
kubectl auth can-i delete pods  --as akshay      # yes
kubectl auth can-i delete nodes --as akshay      # no
```
**Verify:** `yes` for pods, `no` for nodes. A wrong `apiGroups`/`resourceNames` is the usual "forbidden."

## Prediction 2 — A wrong cert path kills the control plane; crictl reveals it

> **My prediction:** "If a control-plane manifest points at a non-existent cert path, `kubectl` returns *connection refused* and the fix is only visible via `crictl logs` — *because* the apiserver/etcd container fails to start and there's no API to query."

```bash
kubectl get pods                         # connection refused
crictl ps -a | grep -E 'apiserver|etcd'  # exited container
crictl logs <etcd-id>                    # "server.crt: no such file"
ls /etc/kubernetes/pki/etcd/             # real file name
sudo vi /etc/kubernetes/manifests/etcd.yaml   # fix --cert-file path
watch crictl ps                          # etcd + apiserver restart
```
**Verify:** `kubectl` responds after the path fix. Check both the *path* and that etcd uses **its own** CA.

## Prediction 3 — A NetworkPolicy default-denies everyone except the allowed selector

> **My prediction:** "If I select `db` for Ingress allowing only `name=api`, then `api` reaches `db:3306` but `web` times out — *because* selecting the pod flips it to default-deny and only the api rule is permitted (assuming an enforcing CNI)."

```bash
kubectl label pod db role=db ; kubectl label pod api name=api
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-policy }
spec:
  podSelector: { matchLabels: { role: db } }
  policyTypes: [Ingress]
  ingress:
  - from: [{ podSelector: { matchLabels: { name: api } } }]
    ports: [{ protocol: TCP, port: 3306 }]
EOF
kubectl exec api -- nc -zv -w3 db 3306      # allowed
kubectl exec web -- nc -zv -w3 db 3306      # blocked (timeout)
```
**Verify:** `api` connects, `web` times out. If `web` *also* connects, your CNI isn't enforcing policy (Flannel) — that's the silent-no-op trap.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> Every API request is authenticated (TLS client cert or SA token, verified against the cluster CA) then authorized (RBAC Role/ClusterRole bindings), while workloads are confined by the identity they run as (security context) and the pods they may reach (NetworkPolicy).

**Explain it to a beginner in 3 sentences:**
> 1. To use the cluster you present a certificate the cluster's CA signed (that's *who you are*), and RBAC rules then decide *what you're allowed to do* — a `403` means you're known but not permitted.
> 2. Apps get the same treatment through service accounts and tokens instead of certificates.
> 3. On top of that, you make containers run as non-root with minimal Linux powers, and use NetworkPolicies to stop pods from talking to pods they shouldn't.

**Which rung to revisit hands-on?**
- **Rung 3A (the two CAs)** — cluster CA vs etcd CA trips people on control-plane cert breaks. Fix: Prediction 2.
- **Rung 3E (NetworkPolicy AND/OR + DNS egress)** — the same-item-vs-two-items rule and the DNS-egress gotcha. Fix: Prediction 3, then add an egress policy and watch DNS break.

---

## 🎯 CKA exam tips & quick notes

- **Certs:** `openssl x509 -in <f> -text -noout` → **Subject(CN)/Issuer/SAN/validity**. All under `/etc/kubernetes/pki` (etcd has its own CA). kubectl down → **`crictl ps -a` + `crictl logs`**.
- **CSR:** `request` must be **`base64 -w0`**; `certificate approve/deny`; `CN`=user, `O`=group; deny `system:masters`.
- **RBAC:** `create role/rolebinding` (namespaced, `-n`) vs `clusterrole/clusterrolebinding`; **test with `kubectl auth can-i <verb> <res> --as <user> -n <ns>`**; `apiGroups: [""]`=core.
- **Service accounts:** `create serviceaccount`, `serviceAccountName` in spec, `create token`; token at `/var/run/secrets/kubernetes.io/serviceaccount`.
- **imagePullSecrets** + `create secret docker-registry` for private images.
- **securityContext:** container overrides pod; **caps container-only**; `runAsUser` immutable live → `replace --force`.
- **NetworkPolicy:** selecting a pod = default-deny that direction; replies auto-allowed; **egress must allow DNS(53)**; needs Calico/Cilium (not Flannel); same-`from`-item = AND.

## 📌 Command cheat sheet
```bash
# CERTS
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout
crictl ps -a | grep apiserver ; crictl logs <id>
# CSR
kubectl get csr ; kubectl certificate approve <name> ; kubectl certificate deny <name>
# RBAC (test!)
k create role dev --verb=get,list,create --resource=pods
k create rolebinding devb --role=dev --user=dev-user
k create clusterrole nr --verb=get,list --resource=nodes
k create clusterrolebinding nrb --clusterrole=nr --user=michelle
k auth can-i create pods --as dev-user -n blue
# SERVICE ACCOUNTS / IMAGES
k create serviceaccount app-sa ; k create token app-sa
k create secret docker-registry regcred --docker-server=r --docker-username=u --docker-password=p
# KUBECONFIG
k config use-context <ctx> ; k config set-context --current --namespace=dev
```

---

## Related sections

- [Section 2 — Scheduling](02-scheduling.md) — admission controllers that run *after* RBAC.
- [Section 4 — Application Lifecycle Management](04-application-lifecycle-management.md) — Secrets + encryption at rest.
- [Section 8 — Networking](08-networking.md) — the CNI that enforces NetworkPolicies; DNS for egress rules.
- [Section 5 — Cluster Maintenance](05-cluster-maintenance.md) — the PKI you back up with etcd.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — cert/control-plane recovery with `crictl`.
- [../../Linux/26-tls-pki-openssl.md](../../Linux/26-tls-pki-openssl.md) · [../../Linux/17-capabilities.md](../../Linux/17-capabilities.md) — the OpenSSL/PKI and Linux capabilities under certs and security contexts.
- [../../Networking/28-kubernetes-network-policies.md](../../Networking/28-kubernetes-network-policies.md) — NetworkPolicy from the networking side.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Name the two distinct questions any secure system must answer for a request, and give a Kubernetes example of each.

**A:** The two questions are **authentication — "who are you?"** — and **authorization — "what may you do?"**. In Kubernetes, authentication is answered by presenting a TLS client certificate signed by the cluster CA (for humans/components) or a service-account token (for pods); failing it yields `401 Unauthorized`. Authorization is answered by RBAC: the apiserver looks for a Role/ClusterRole bound to your identity that allows the verb on the resource; failing it yields `403 Forbidden`.

### Before Rung 3
**Q:** A user's `kubectl get pods` returns `Forbidden`. Which of the two gates did they pass, and which did they fail? What would `Unauthorized` have meant instead?

**A:** `403 Forbidden` means they **passed authentication** (the apiserver knows who they are — their cert or token was valid) but **failed authorization** — no RoleBinding/ClusterRoleBinding grants their identity the `get`/`list` verb on `pods` in that namespace. `401 Unauthorized` would have meant the first gate failed: the cluster couldn't establish their identity at all, e.g. a cert signed by an untrusted CA or an invalid token — the request never even reaches RBAC.

### Before Rung 4
**Q:** Four quick ones: (1) which CA signs a *user's* client cert? (2) does `403` mean authn or authz failed? (3) where does a pod find its service-account token? (4) why might a NetworkPolicy you applied do nothing?

**A:** (1) The **cluster CA** (`/etc/kubernetes/pki/ca.crt`/`ca.key`, Issuer `CN=kubernetes`) — the controller-manager signs approved CSRs with it; the separate etcd CA signs only etcd's certs. (2) `403 Forbidden` is an **authorization (RBAC)** failure — authentication already succeeded. (3) At **`/var/run/secrets/kubernetes.io/serviceaccount/token`** — a short-lived bound token mounted into the pod. (4) Because the cluster's **CNI doesn't enforce NetworkPolicy** — plain Flannel ignores policies silently; you need an enforcing CNI like Calico, Cilium, or Weave.

### Before Rung 5
**Q:** Sort into the four boxes: a `ClusterRoleBinding`, a `runAsNonRoot: true`, a `CertificateSigningRequest`, a `podSelector` ingress rule.

**A:** `ClusterRoleBinding` → **WHAT MAY YOU DO (authz)** — it grants a ClusterRole's permissions cluster-wide. `runAsNonRoot: true` → **WHAT POWER (confinement)** — a securityContext field limiting the identity a container runs as. `CertificateSigningRequest` → **WHO ARE YOU (authn)** — it's how a new user gets a signed client cert, i.e. authentication plumbing. A `podSelector` ingress rule → **WHO CAN IT TALK TO (confinement)** — part of a NetworkPolicy, the pod-level firewall.

### Before Rung 6
**Q:** In the first trace, at which step would a cert signed by the *wrong* CA fail, and what HTTP error results? At which step does a missing RoleBinding fail, and what error?

**A:** A cert signed by the wrong CA fails at **step 2, the TLS handshake** — the apiserver cannot verify the client cert against the cluster CA, so authentication fails with **`401 Unauthorized`** and the trace ends there. A missing RoleBinding fails at **step 3, authorization** — RBAC searches namespace `blue` for a (Cluster)RoleBinding whose subject is akshay with a Role allowing `list` on `pods`, finds none, and returns **`403 Forbidden`** (authenticated but not permitted).

### Before Rung 7
**Q:** etcd throws "certificate signed by unknown authority" after someone edited `etcd.yaml`. Which CA did they probably point it at, and which should it be?

**A:** They probably pointed etcd at the **cluster CA** (`/etc/kubernetes/pki/ca.crt`), but etcd has its **own separate CA** — it should be `/etc/kubernetes/pki/etcd/ca.crt` (Issuer `etcd-ca`). The two CAs are separate trust domains: the cluster CA signs apiserver/user/kubelet certs, while the etcd CA signs only etcd's certs, so mixing them makes cert verification fail with "signed by unknown authority." Diagnose with `crictl ps -a` and `crictl logs` since `kubectl` is down, then fix the CA path in `/etc/kubernetes/manifests/etcd.yaml`.
