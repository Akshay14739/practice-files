# 🔐 Section 6 — Security (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 6 transcript. The spine: **authentication** (who are you?) → **authorization** (what may you do?) → **workload confinement**.

---

## 1. TLS certificates — the foundation

### ❓ What
**Asymmetric crypto** made usable: a certificate = a public key + an identity (CN/SANs) **signed by a CA**; a **CSR** asks the CA to sign; **PKI** is the whole trust system.

### 🔥 Pain points it solves & why this?
- Symmetric keys are fast but the key exchange is interceptable → asymmetric pairs solve exchange; TLS then negotiates a symmetric session key safely.
- "Is this really the API server / really admin?" needs a trusted third party → the CA's signature is that proof.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| public / private key | share freely / keep secret (`.crt`/`.pem` vs **`.key`**) |
| **CA** | the signer everyone trusts; its cert verifies all others |
| **CSR** | "please sign my public key + identity" |
| **server cert** | apiserver/etcd/kubelet proving themselves to clients |
| **client cert** | admin/scheduler/kubelet proving themselves to the apiserver |
| CN / O | username / group inside a client cert's subject |

### 🧪 Hands-on examples

**Example 1 — Generate a CA, then sign a user cert with it:**
```bash
openssl genrsa -out ca.key 2048
openssl req -new -x509 -key ca.key -subj "/CN=KUBERNETES-CA" -out ca.crt   # self-signed root
openssl genrsa -out admin.key 2048
openssl req -new -key admin.key -subj "/CN=kube-admin/O=system:masters" -out admin.csr
openssl x509 -req -in admin.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out admin.crt
# Verify: openssl x509 -in admin.crt -text -noout → Issuer=KUBERNETES-CA, Subject O=system:masters.
```

**Example 2 — Inspect any cluster cert (the exam skill):**
```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout
# read: Subject CN, Issuer, Validity (expiry!), and:
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 "Alternative Name"
# Verify: SANs include kubernetes.default.svc, the ClusterIP 10.96.0.1, the node IP.
```

**Example 3 — Verify which CA signed a cert:**
```bash
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/apiserver.crt        # OK
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/etcd/server.crt      # FAILS
openssl verify -CAfile /etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/server.crt # OK
# Verify: etcd has its OWN CA — mixing them = "certificate signed by unknown authority".
```

---

## 2. Where cluster certs live & cert troubleshooting

### ❓ What
kubeadm puts all PKI under **`/etc/kubernetes/pki/`** (cluster CA + component certs, with a **separate etcd CA** in `pki/etcd/`), wired into the static-pod manifests.

### 🔥 Pain points it solves & why this?
- A wrong cert path or wrong CA in a manifest takes the **whole control plane down** — and with it, `kubectl`.
- Knowing the layout + `crictl` fallback turns a dead-cluster panic into a 3-minute fix.

### ⚙️ How exactly it works
```
/etc/kubernetes/pki/
├── ca.crt / ca.key                    # CLUSTER CA (Issuer "kubernetes")
├── apiserver.crt/.key                 # apiserver serving cert
├── apiserver-etcd-client.crt/.key     # apiserver → etcd (client)
├── apiserver-kubelet-client.crt/.key  # apiserver → kubelet (client)
└── etcd/ca.crt / server.crt …         # SEPARATE etcd CA + serving cert
```
Which cert is used where = read the flags in `/etc/kubernetes/manifests/kube-apiserver.yaml` / `etcd.yaml`.

### 🧪 Hands-on examples

**Example 1 — Map every cert to its flag:**
```bash
sudo grep -E 'tls-cert|client-ca|etcd-cafile|etcd-certfile' /etc/kubernetes/manifests/kube-apiserver.yaml
sudo grep -E 'cert-file|trusted-ca-file' /etc/kubernetes/manifests/etcd.yaml
# Verify: you can say which file each flag points to and which CA signs it.
```

**Example 2 — Fix a dead apiserver caused by a bad etcd cert path:**
```bash
kubectl get pods                          # connection refused
sudo crictl ps -a | grep -E 'etcd|apiserver'   # etcd container Exited
sudo crictl logs <etcd-id> | tail        # "open …/server-certificate.crt: no such file"
ls /etc/kubernetes/pki/etcd/             # real name: server.crt
sudo vi /etc/kubernetes/manifests/etcd.yaml    # fix --cert-file
watch sudo crictl ps                     # etcd, then apiserver, return
# Verify: kubectl responds again; the log named the exact broken path.
```

**Example 3 — Check every cert's expiry:**
```bash
for c in /etc/kubernetes/pki/*.crt; do
  echo "$c: $(openssl x509 -in $c -noout -enddate)"; done
kubeadm certs check-expiration            # the built-in view
# Verify: kubeadm certs last 1 year; upgrades renew them.
```

---

## 3. The Certificates API (CSR workflow)

### ❓ What
A Kubernetes-native way to sign new user certs: submit a **CertificateSigningRequest** object, approve it, download the signed cert — the **controller-manager** does the signing.

### 🔥 Pain points it solves & why this?
- Without it, an admin SSHes to the CA box and runs openssl by hand for every new user.
- Approval becomes a visible, auditable API action (`kubectl get csr`) instead of a shell habit.

### ⚙️ How exactly it works
User: `openssl genrsa` + `openssl req` (CN = username, O = groups). Admin: wrap the CSR in a `CertificateSigningRequest` (`request:` = **single-line base64**, `signerName: kubernetes.io/kube-apiserver-client`, `usages: [client auth]`) → `approve` → extract `.status.certificate`.

### 🧪 Hands-on examples

**Example 1 — Onboard user akshay end-to-end:**
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
kubectl get csr                            # Pending
kubectl certificate approve akshay
kubectl get csr akshay -o jsonpath='{.status.certificate}' | base64 -d > akshay.crt
# Verify: akshay.crt decodes to a cert with Issuer=kubernetes, Subject CN=akshay.
```

**Example 2 — Deny a suspicious CSR:**
```bash
kubectl get csr agent-smith -o yaml | grep -A3 groups     # requesting system:masters!
kubectl certificate deny agent-smith
kubectl get csr agent-smith                                # Denied
# Verify: system:masters = full cluster-admin — never approve it casually.
```

**Example 3 — The base64 line-wrap trap:**
```bash
cat akshay.csr | base64 | head -2          # wrapped lines — WILL break the CSR object
cat akshay.csr | base64 -w0 | head -c50    # one line — correct
# Verify: a wrapped `request:` field errors with "illegal base64 data"; -w0 fixes it.
```

---

## 4. kubeconfig

### ❓ What
The file (`~/.kube/config`) bundling **clusters** (endpoint + CA), **users** (client cert/token), and **contexts** (user × cluster × default namespace), with a `current-context`.

### 🔥 Pain points it solves & why this?
- Typing `--server --client-certificate --client-key --certificate-authority` on every command is unusable.
- Multiple clusters/identities need fast, explicit switching.

### ⚙️ How exactly it works
`kubectl` reads `current-context` → resolves the context's user + cluster → uses that cert against that endpoint. Certs by path (`client-certificate:`) or inline (`client-certificate-data:` base64).

### 🧪 Hands-on examples

**Example 1 — Read and switch contexts:**
```bash
kubectl config view                        # clusters/users/contexts
kubectl config get-contexts                # * marks current
kubectl config use-context prod-admin@prod
kubectl config set-context --current --namespace=dev    # default ns for this context
# Verify: get-contexts shows the new current + namespace column.
```

**Example 2 — Use a non-default kubeconfig:**
```bash
kubectl get pods --kubeconfig=/root/my-kube-config
export KUBECONFIG=/root/my-kube-config     # or make it the session default
# Verify: identities/clusters come from that file, not ~/.kube/config.
```

**Example 3 — Fix a broken user entry:**
```bash
kubectl get pods
# error: unable to read client-cert .../users/dev-user.crt: no such file
grep -A3 'name: dev-user' ~/.kube/config       # wrong path in client-certificate
# correct the path (or embed: client-certificate-data: $(base64 -w0 < dev-user.crt))
# Verify: kubectl works; you know both file-path and inline-data forms.
```

---

## 5. Authorization — RBAC (Role / ClusterRole)

### ❓ What
After authentication, **RBAC** decides *what you may do*: **Role**+**RoleBinding** grant verbs on resources **within a namespace**; **ClusterRole**+**ClusterRoleBinding** do it cluster-wide (nodes, PVs, or all namespaces).

### 🔥 Pain points it solves & why this?
- Sharing the admin kubeconfig with everyone = everyone is root.
- Old ABAC needed a policy file + apiserver restarts per change; RBAC is live API objects.
- Least privilege: developers get pods in *their* namespace, not nodes.

### ⚙️ How exactly it works
Modes on the apiserver (`--authorization-mode=Node,RBAC,Webhook`) run in order — deny passes on, allow stops. A Role is `(apiGroups, resources, verbs[, resourceNames])`; a binding attaches it to `subjects` (User/Group/ServiceAccount).

| Vocabulary | Meaning |
|---|---|
| `apiGroups: [""]` | the core group (pods, services, configmaps) |
| `verbs` | get, list, watch, create, delete, update… |
| `resourceNames` | restrict to specific named objects |
| `kubectl auth can-i` | test permissions (with `--as` to impersonate) |

### 🧪 Hands-on examples

**Example 1 — Namespaced Role + binding, then test:**
```bash
kubectl create role developer --verb=get,list,create,delete --resource=pods -n default
kubectl create rolebinding dev-binding --role=developer --user=dev-user -n default
kubectl auth can-i create pods --as dev-user            # yes
kubectl auth can-i create deployments --as dev-user     # no
# Verify: can-i answers without ever logging in as dev-user.
```

**Example 2 — ClusterRole for cluster-scoped resources:**
```bash
kubectl api-resources --namespaced=false | head          # what's cluster-scoped
kubectl create clusterrole node-reader --verb=get,list,watch --resource=nodes
kubectl create clusterrolebinding michelle-binding --clusterrole=node-reader --user=michelle
kubectl auth can-i list nodes --as michelle              # yes
# Verify: nodes/PVs/CSRs need ClusterRole — a namespaced Role can't grant them.
```

**Example 3 — Debug a "forbidden" error:**
```bash
kubectl get pods --as dev-user -n blue      # Forbidden
kubectl describe rolebinding -n blue        # is dev-user a subject?
kubectl describe role developer -n blue     # right apiGroups/resources/verbs? resourceNames?
kubectl create rolebinding fix --role=developer --user=dev-user -n blue
# Verify: Forbidden = authenticated but not authorized; the fix is a Role/binding in THAT namespace.
```

---

## 6. Service Accounts

### ❓ What
Identities for **applications** (not humans): every namespace has a `default` SA; pods mount its **bound token** at `/var/run/secrets/kubernetes.io/serviceaccount/`.

### 🔥 Pain points it solves & why this?
- In-cluster apps (Prometheus, Jenkins, dashboards) must call the API — they can't hold a human's cert.
- Modern **bound tokens** are short-lived and pod-scoped (old scheme: eternal tokens in Secrets — a leak risk).

### ⚙️ How exactly it works
Create SA → grant it RBAC (`subjects: kind: ServiceAccount`) → set `serviceAccountName` in the pod spec (or `automountServiceAccountToken: false` to opt out). `kubectl create token` mints short-lived tokens on demand.

### 🧪 Hands-on examples

**Example 1 — SA + token:**
```bash
kubectl create serviceaccount dashboard-sa
kubectl create token dashboard-sa --duration=48h        # prints a JWT
# Verify: paste the JWT at jwt.io — sub = system:serviceaccount:default:dashboard-sa.
```

**Example 2 — Give an SA read access and use it from a pod:**
```bash
kubectl create role pod-reader --verb=get,list --resource=pods
kubectl create rolebinding sa-read --role=pod-reader \
  --serviceaccount=default:dashboard-sa
kubectl run api-client --image=curlimages/curl --overrides='{"spec":{"serviceAccountName":"dashboard-sa"}}' \
  --command -- sleep 3600
kubectl exec api-client -- sh -c 'curl -sk -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default/api/v1/namespaces/default/pods | head -5'
# Verify: the pod lists pods using ITS OWN identity — no human credentials involved.
```

**Example 3 — See the auto-mounted token (and opt out):**
```bash
kubectl exec api-client -- ls /var/run/secrets/kubernetes.io/serviceaccount   # ca.crt namespace token
# opt out in a pod spec:  automountServiceAccountToken: false
# Verify: with automount off, the directory doesn't exist — smaller attack surface.
```

---

## 7. Image Security (private registries)

### ❓ What
Pulling images from authenticated registries via a **`docker-registry` Secret** referenced as `imagePullSecrets`.

### 🔥 Pain points it solves & why this?
- Internal images can't live on public Docker Hub; nodes must authenticate to your registry.
- Image `nginx` really means `docker.io/library/nginx:latest` — knowing the full form explains what registry is being hit.

### ⚙️ How exactly it works
The kubelet uses the secret's credentials when pulling. `ImagePullBackOff` + "unauthorized" = missing/wrong pull secret.

### 🧪 Hands-on examples

**Example 1 — Create the secret + use it:**
```bash
kubectl create secret docker-registry regcred \
  --docker-server=my-registry.io:5000 \
  --docker-username=user --docker-password='pass' --docker-email=me@x.com
# pod spec:
#   imagePullSecrets: [ { name: regcred } ]
#   containers: [ { name: app, image: my-registry.io:5000/apps/internal:1.2 } ]
# Verify: pod pulls and Runs; without the secret → ImagePullBackOff "unauthorized".
```

**Example 2 — Decode the full image name:**
```bash
kubectl run t --image=nginx --dry-run=client -o yaml | grep image:
# nginx == docker.io/library/nginx:latest  (registry/user/image:tag)
# Verify: you can expand any short image name to its 4 parts.
```

**Example 3 — Diagnose a private-pull failure:**
```bash
kubectl describe pod app | grep -A5 Events    # "pull access denied / unauthorized"
kubectl get secret regcred -o yaml            # exists? right server?
kubectl get pod app -o jsonpath='{.spec.imagePullSecrets}{"\n"}'   # referenced at all?
# Verify: the triad — secret exists, correct registry, referenced in the pod.
```

---

## 8. Security Contexts

### ❓ What
Pod/container settings controlling the **UID** the process runs as and its **Linux capabilities** (plus `runAsNonRoot`, `readOnlyRootFilesystem`).

### 🔥 Pain points it solves & why this?
- Containers default to **root** — a breakout inherits root on the node.
- Apps rarely need all of root's powers; capabilities let you grant just `NET_ADMIN` instead of everything.

### ⚙️ How exactly it works
Pod-level `securityContext` applies to all containers; **container-level overrides it**; **capabilities are container-level only**. Immutable on a live pod → `replace --force`.

### 🧪 Hands-on examples

**Example 1 — Who am I running as?**
```bash
kubectl run whoami --image=ubuntu --command -- sleep 3600
kubectl exec whoami -- whoami            # root (the default!)
# Verify: the uncomfortable default that security contexts exist to fix.
```

**Example 2 — Pod vs container precedence:**
```yaml
spec:
  securityContext: { runAsUser: 1001 }        # pod level
  containers:
  - name: app
    image: ubuntu
    command: ["sleep","3600"]
    securityContext: { runAsUser: 1002 }      # container level WINS
```
```bash
kubectl exec ctx-demo -- sh -c 'id -u'    # 1002
# Verify: container-level overrides pod-level.
```

**Example 3 — Drop everything, add one capability:**
```yaml
    securityContext:
      runAsNonRoot: true
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"], add: ["NET_BIND_SERVICE"] }
```
```bash
kubectl exec hardened -- sh -c 'touch /x'        # Read-only file system — blocked
# Verify: least privilege in practice — the app still binds :80 but can't write / or escalate.
```

---

## 9. Network Policies

### ❓ What
A **pod-level firewall**: selecting a pod flips it to **default-deny** for the chosen direction (`Ingress`/`Egress`); rules add explicit allows by `podSelector`, `namespaceSelector`, or `ipBlock`.

### 🔥 Pain points it solves & why this?
- Default cluster networking is **allow-all** — one compromised pod can scan/reach everything (a compliance fail for web→db architectures).
- L3/4 control by *label*, not by fragile IPs.

### ⚙️ How exactly it works
- Think from the **target pod's** perspective; only the direction traffic *originates* matters — **replies are auto-allowed** (stateful).
- **AND vs OR:** `podSelector` + `namespaceSelector` in the **same** `from` item = AND; as **two** items = OR.
- Needs an **enforcing CNI** (Calico/Cilium/Weave) — **Flannel ignores policies silently**.
- An **egress** policy also blocks DNS unless you allow port **53**.

### 🧪 Hands-on examples

**Example 1 — Lock a DB to its API clients:**
```bash
kubectl label pod db role=db; kubectl label pod api name=api
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: db-policy }
spec:
  podSelector: { matchLabels: { role: db } }
  policyTypes: [Ingress]
  ingress:
  - from: [ { podSelector: { matchLabels: { name: api } } } ]
    ports: [ { protocol: TCP, port: 3306 } ]
EOF
kubectl exec api -- nc -zv -w3 db 3306     # open
kubectl exec web -- nc -zv -w3 db 3306     # times out (default-deny)
# Verify: only api connects. If web ALSO connects → your CNI doesn't enforce (Flannel).
```

**Example 2 — AND vs OR selectors:**
```yaml
# AND (api pods IN prod namespace only):
  - from:
    - podSelector: { matchLabels: { name: api } }
      namespaceSelector: { matchLabels: { env: prod } }
# OR (api pods anywhere, OR anything in prod):
  - from:
    - podSelector: { matchLabels: { name: api } }
    - namespaceSelector: { matchLabels: { env: prod } }
```
```bash
# apply each variant, test with nc from an api pod in a NON-prod namespace
# Verify: AND blocks it; OR allows it — the dash placement is the whole difference.
```

**Example 3 — Egress policy that doesn't break DNS:**
```yaml
spec:
  podSelector: { matchLabels: { role: app } }
  policyTypes: [Egress]
  egress:
  - to: [ { ipBlock: { cidr: 192.168.5.0/24 } } ]
    ports: [ { protocol: TCP, port: 80 } ]
  - to: []                                   # DNS allowance
    ports: [ { protocol: UDP, port: 53 }, { protocol: TCP, port: 53 } ]
```
```bash
kubectl exec app -- nslookup web-service    # still works (53 allowed)
# Remove the 53 rule and nslookup times out.
# Verify: every egress policy needs the DNS clause or name resolution dies.
```

---

## ➕ Added (bonus topics from the transcript + extras)

- **kubectx / kubens** — fast context/namespace switchers (quality of life, not on the exam).
- **CRDs & Operators** (awareness level): a **CustomResourceDefinition** teaches the API server a new kind (`apiextensions.k8s.io/v1`, `scope`, group/versions/schema); a **custom controller** acts on it; an **Operator** = CRD + controller packaged (etcd/Prometheus operators). CKA may ask you to *apply/inspect* a CRD, not write controllers.
- **Authn vs authz errors:** `401 Unauthorized` = identity failed (bad cert/token); `403 Forbidden` = identity fine, RBAC said no — instantly tells you *which* layer to debug.

---

## Related
[02-scheduling](02-scheduling.md) (admission after RBAC) · [04-application-lifecycle-management](04-application-lifecycle-management.md) (secrets/encryption at rest) · [08-networking](08-networking.md) (CNI enforcing NetPol, DNS) · [13-troubleshooting](13-troubleshooting.md) (crictl cert debugging) · Ladder version: [../README/06-security.md](../README/06-security.md)
