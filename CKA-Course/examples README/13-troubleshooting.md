# 🔧 Section 13 — Troubleshooting (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 13 transcript. **Troubleshooting = 30 % of the exam** — the biggest single domain.

---

## 1. Application failure

### ❓ What
Diagnosing a broken app by **walking its request map** — `user → web Service → web Pod → db Service → db Pod` — checking every hop until one fails.

### 🔥 Pain points it solves & why this?
- Randomly editing objects under a clock makes things worse; the map gives an ordered, finite search.
- The most common faults are *wiring* faults (names, selectors, ports, env) — each visible from one specific command.

### ⚙️ How exactly it works
Check front-to-back: reachability (`curl`) → Service wiring (`describe svc`: **Endpoints**, selector, ports) → Pod health (`get/describe/logs --previous`) → config (env vars).

| Symptom | Root cause | Fix |
|---|---|---|
| `Endpoints: <none>` | Service **selector** ≠ pod **labels** | fix selector |
| "name does not resolve" | wrong **Service name** (`mysql` vs `mysql-service`) | rename / fix env |
| "connection refused" | **targetPort** ≠ container port (8080 vs 3306) | fix targetPort |
| "access denied" | wrong DB **user/password** env | fix env/secret |
| timeout on node port | wrong **nodePort** | fix nodePort |

### 🧪 Hands-on examples

**Example 1 — The two-tier walk (lab fault: wrong service name):**
```bash
kubectl config set-context --current --namespace=alpha
curl -s localhost:30081 | grep -i error     # "Can't connect to mysql-service … not resolve"
kubectl get svc                              # actual service is named "mysql"!
# fix: recreate the service as mysql-service (or point the app's DB_HOST at mysql)
curl -s localhost:30081                      # SUCCESS
# Verify: the error text itself named the failing hop.
```

**Example 2 — Selector & port mismatches:**
```bash
kubectl describe svc web-service | grep -E 'Selector|Endpoints|TargetPort'
# Endpoints: <none>          → selector doesn't match pod labels → fix selector
# TargetPort: 8080 but the app listens on 3306 → fix targetPort
kubectl get pods --show-labels               # compare against the selector
# Verify: Endpoints populate the moment selector+labels align; curl works when ports align.
```

**Example 3 — Crash + credentials:**
```bash
kubectl get pods                             # webapp CrashLoopBackOff
kubectl logs webapp-pod --previous          # "access denied for user 'sql-user'"
kubectl describe deploy webapp | grep -A5 Env    # DB_User=sql-user vs db expects root
kubectl set env deployment/webapp DB_User=root
# Verify: --previous exposed the real error; env fix rolls a working pod.
```

---

## 2. Control-plane failure

### ❓ What
Diagnosing broken control-plane components (static pods in `kube-system`) — where the **symptom names the component**.

### 🔥 Pain points it solves & why this?
- "The whole cluster is weird" decomposes into per-component signatures — no guessing.
- When the **apiserver** is down, `kubectl` is useless — you need the `crictl` fallback.

### ⚙️ How exactly it works

| Symptom | Broken component |
|---|---|
| pods stuck **Pending** (`Node: <none>`) | **kube-scheduler** |
| scaling/self-healing doesn't happen | **kube-controller-manager** |
| `kubectl` fails ("connection refused") | **kube-apiserver** (or etcd) |

Checklist: `get nodes` → `get pods -n kube-system` → `describe`/`logs` the broken one (or `crictl ps -a` + `crictl logs` if kubectl is dead) → fix the manifest in `/etc/kubernetes/manifests/` (kubelet auto-restarts it). Common breaks: wrong `command`, wrong file **path**, wrong volume **hostPath**.

### 🧪 Hands-on examples

**Example 1 — Pending pods → scheduler (lab fault: mangled command):**
```bash
kubectl get pods                             # app Pending, Node: <none>
kubectl get pods -n kube-system              # kube-scheduler CrashLoopBackOff
kubectl describe pod kube-scheduler-controlplane -n kube-system | grep -i error
# "exec: \"kube-schedulerrrr\": executable file not found"
sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml    # fix the command
kubectl get pods                             # pod schedules → Running
# Verify: Pending + Node:<none> ⇒ scheduler, every time.
```

**Example 2 — Scaling ignored → controller-manager (lab fault: bad kubeconfig path):**
```bash
kubectl scale deployment app --replicas=3 ; kubectl get pods    # still 1!
kubectl logs kube-controller-manager-controlplane -n kube-system | tail
# "stat /etc/kubernetes/controller-manager-XXXX.conf: no such file"
sudo vi /etc/kubernetes/manifests/kube-controller-manager.yaml   # fix --kubeconfig path
kubectl get pods                             # scales to 3
# Verify: no-scaling/no-self-heal ⇒ controller-manager.
```

**Example 3 — kubectl dead → crictl (lab fault: wrong PKI hostPath):**
```bash
kubectl get pods                             # connection refused
sudo crictl ps -a | grep -E 'apiserver|controller'
sudo crictl logs <controller-id> | tail     # "unable to load client CA file /etc/kubernetes/pki/ca.crt"
sudo grep -A3 'name: k8s-certs' /etc/kubernetes/manifests/kube-controller-manager.yaml
# hostPath: /etc/kubernetes/WRONG-pki  → fix to /etc/kubernetes/pki
watch sudo crictl ps                         # components return; kubectl works
# Verify: with no API, crictl is your eyes; the volume hostPath was the break.
```

---

## 3. Worker-node failure

### ❓ What
Diagnosing `NotReady` nodes: read the node's **Conditions**, then go on-box to the **kubelet** — its service state, its logs, its two config files.

### 🔥 Pain points it solves & why this?
- A NotReady node takes all its pods with it; the cause is almost always the kubelet (the node's brain).
- Two config files confuse people — knowing which holds what makes fixes surgical.

### ⚙️ How exactly it works
`kubectl describe node` Conditions: `MemoryPressure`/`DiskPressure`/`PIDPressure` = resource exhaustion; **`Ready=Unknown`** + stale heartbeat = kubelet stopped talking. Then SSH: `systemctl status kubelet` → `journalctl -u kubelet` → config.

| File | Holds |
|---|---|
| **`/var/lib/kubelet/config.yaml`** | kubelet behavior: `clientCAFile`, `staticPodPath`, cgroup driver |
| **`/etc/kubernetes/kubelet.conf`** | the kubeconfig: apiserver **address:port (6443!)**, certs |

### 🧪 Hands-on examples

**Example 1 — Kubelet simply stopped:**
```bash
kubectl get nodes                            # node01 NotReady
ssh node01
sudo systemctl status kubelet                # inactive (dead)
sudo systemctl start kubelet
exit; kubectl get nodes                      # Ready
# Verify: the humblest fix first — is the service even running?
```

**Example 2 — Wrong CA path in config.yaml:**
```bash
ssh node01
sudo systemctl status kubelet                # activating (auto-restart), exit 255
sudo journalctl -u kubelet | tail           # "unable to load client CA file /etc/kubernetes/pki/WRONG.crt"
sudo vi /var/lib/kubelet/config.yaml        # clientCAFile: /etc/kubernetes/pki/ca.crt
sudo systemctl restart kubelet
# Verify: journalctl NAMED the file and the bad path — behavior config = config.yaml.
```

**Example 3 — Wrong apiserver port in kubelet.conf:**
```bash
sudo journalctl -u kubelet | tail           # "connect: connection refused … :6553"
sudo grep server /etc/kubernetes/kubelet.conf   # https://controlplane:6553 ← wrong
sudo sed -i 's/6553/6443/' /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
kubectl get nodes                            # Ready
# Verify: connection config = kubelet.conf; the apiserver port is always 6443.
```

---

## 4. Network troubleshooting

### ❓ What
Faults in the cluster's network layers: the **CNI** (pod IPs), **kube-proxy** (service VIPs), and **CoreDNS** (names) — all living in `kube-system`.

### 🔥 Pain points it solves & why this?
- "Pods can't talk" has three different owners; checking the right one first saves the hunt.
- Each layer has a signature: NotReady node = CNI; service unreachable but pods fine = kube-proxy; names don't resolve = CoreDNS.

### ⚙️ How exactly it works
```bash
kubectl get pods -n kube-system              # CNI DaemonSet + kube-proxy + coredns Running?
kubectl logs -n kube-system <kube-proxy-pod> # proxy mode / errors
kubectl exec <pod> -- nslookup <svc>.<ns>    # DNS check
kubectl get svc -n kube-system kube-dns      # CoreDNS front door (10.96.0.10)
```

### 🧪 Hands-on examples

**Example 1 — NotReady right after install = no CNI:**
```bash
kubectl get nodes                            # NotReady
kubectl describe node node01 | grep -i networkready    # "cni plugin not initialized"
kubectl apply -f <weave/flannel/calico addon>.yaml
kubectl get nodes                            # Ready
# Verify: the CNI DaemonSet appearing per node is what flips readiness.
```

**Example 2 — DNS down cluster-wide:**
```bash
kubectl exec app -- nslookup web-service     # timeout
kubectl get pods -n kube-system -l k8s-app=kube-dns    # coredns CrashLoopBackOff
kubectl logs -n kube-system <coredns-pod>    # config error in the Corefile
kubectl get configmap coredns -n kube-system -o yaml    # fix the bad plugin line
# Verify: every name lookup in the cluster rides on these pods.
```

**Example 3 — Service dead but pods healthy = kube-proxy:**
```bash
kubectl exec app -- wget -qO- --timeout=3 http://web-service   # fails
kubectl exec app -- wget -qO- <pod-ip>       # WORKS → pod + CNI fine, VIP broken
kubectl get pods -n kube-system | grep kube-proxy    # CrashLoopBackOff
kubectl logs -n kube-system <kube-proxy-pod>         # e.g. bad --config path in its DaemonSet
kubectl edit ds kube-proxy -n kube-system            # fix; pods restart
# Verify: pod-IP-works-but-VIP-doesn't isolates kube-proxy exactly.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **The universal first moves:** `kubectl describe` (Events tell most stories) and `kubectl logs --previous` (the crashed container's truth).
- **Symptom → layer map** (memorize): app error → walk the map · Pending → scheduler · no scaling → controller-manager · kubectl dead → apiserver/etcd (crictl!) · NotReady → kubelet/CNI · name won't resolve → CoreDNS · VIP dead, pod IP fine → kube-proxy.
- Set the namespace per task (`kubectl config set-context --current --namespace=…`) — troubleshooting questions live in odd namespaces.

---

## Related
[01-core-concepts](01-core-concepts.md) (the map you walk) · [03-logging-monitoring](03-logging-monitoring.md) (logs/describe) · [05-cluster-maintenance](05-cluster-maintenance.md) (etcd recovery) · [08-networking](08-networking.md) (CNI/kube-proxy/CoreDNS) · Ladder version: [../README/13-troubleshooting.md](../README/13-troubleshooting.md)
