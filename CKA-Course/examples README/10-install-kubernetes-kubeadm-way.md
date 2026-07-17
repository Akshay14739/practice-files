# ⚙️ Section 10 — Install Kubernetes the Kubeadm Way (What · Pain · How · Examples)

> Every topic: **What** → **Pain & why** → **How it works** (machinery + vocabulary) → **3+ hands-on examples**. Source: CKA course Section 10 transcript. **Order matters:** prereqs on every node → `init` → CNI → `join`.

---

## 1. Node prerequisites (runtime, cgroups, sysctls, swap)

### ❓ What
The per-node preparation without which the kubelet can't run pods: kernel modules + sysctls for pod networking, **swap off**, a container runtime (containerd) with the **systemd cgroup driver**, and pinned `kubeadm/kubelet/kubectl`.

### 🔥 Pain points it solves & why this?
- These four cause almost every `kubeadm init` preflight failure.
- **Why cgroup match:** kubelet and runtime both account resources via cgroups — different drivers = two bookkeepers disagreeing → pods misbehave.
- **Why sysctls:** CNIs bridge pod traffic; without `br_netfilter`/`ip_forward`, bridged packets skip iptables and don't forward.
- **Why swap off:** the kubelet's memory accounting assumes no swap.

### ⚙️ How exactly it works

| Vocabulary | Meaning |
|---|---|
| `overlay`, `br_netfilter` | kernel modules for container storage + bridged-traffic filtering |
| `net.ipv4.ip_forward=1` | node routes pod traffic |
| `SystemdCgroup = true` | containerd's cgroup driver — must match the kubelet (systemd) |
| `apt-mark hold` | pin versions so upgrades don't drift |

### 🧪 Hands-on examples

**Example 1 — Kernel modules + sysctls + swap (every node):**
```bash
sudo modprobe overlay && sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
sudo swapoff -a
# Verify: sysctl net.ipv4.ip_forward → 1 ; free -h shows Swap 0B.
```

**Example 2 — containerd with the right cgroup driver:**
```bash
sudo apt-get install -y containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
grep SystemdCgroup /etc/containerd/config.toml     # true
# Verify: kubelet (systemd default ≥1.22) and containerd now agree.
```

**Example 3 — Install + pin the tools:**
```bash
sudo apt-get install -y kubelet=1.31.1-1.1 kubeadm=1.31.1-1.1 kubectl=1.31.1-1.1
sudo apt-mark hold kubelet kubeadm kubectl
apt-mark showhold          # all three held
# Verify: an apt upgrade won't silently change cluster-critical versions.
```

---

## 2. `kubeadm init` (bootstrap the control plane)

### ❓ What
One command that generates the **whole PKI**, writes the control plane as **static pods**, starts it, and prints your kubeconfig setup + the worker **join command**.

### 🔥 Pain points it solves & why this?
- By hand this is ~10 certs with correct SANs + 4 static-pod manifests + wiring — days of error-prone work ("the hard way").
- Flags matter: the wrong `--apiserver-advertise-address` (multi-NIC VMs!) or a pod CIDR that mismatches your CNI cause subtle breakage later.

### ⚙️ How exactly it works
Preflight checks → generate CA + certs (`/etc/kubernetes/pki`) → write manifests (`/etc/kubernetes/manifests/`) → local kubelet starts them → bootstrap token created → prints next steps.

| Flag | Why |
|---|---|
| `--apiserver-advertise-address` | the control-plane IP others will dial (pick the right NIC) |
| `--pod-network-cidr` | must match the CNI (Flannel default `10.244.0.0/16`) |
| `--control-plane-endpoint=<LB>` | add if you might go HA later |
| `--upload-certs` | share CP certs for extra control-plane nodes |

### 🧪 Hands-on examples

**Example 1 — init + wire up kubectl:**
```bash
sudo kubeadm init \
  --apiserver-advertise-address=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1) \
  --pod-network-cidr=10.244.0.0/16
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes        # NotReady — EXPECTED until a CNI exists
# Verify: control plane answers; NotReady is normal at this stage.
```

**Example 2 — See what init created:**
```bash
ls /etc/kubernetes/pki | head          # CA + component certs
ls /etc/kubernetes/manifests           # 4 static-pod YAMLs
kubectl get pods -n kube-system        # apiserver/etcd/scheduler/ctrl-mgr as pods
# Verify: the control plane IS static pods run by the local kubelet.
```

**Example 3 — Diagnose a failing init (the classic four):**
```bash
sudo kubeadm init ...            # read the preflight error, then check:
free -h                          # swap on? → swapoff -a
sudo systemctl status containerd # runtime down? → restart
grep SystemdCgroup /etc/containerd/config.toml   # false? → fix + restart
sysctl net.ipv4.ip_forward       # 0? → sysctl --system
# Verify: each preflight message maps to one of these; fix and re-run init.
```

---

## 3. Deploy a pod network (CNI)

### ❓ What
Applying a network addon (Flannel/Calico/Weave) — a **DaemonSet** that implements pod networking and flips nodes to **Ready**.

### 🔥 Pain points it solves & why this?
- Kubernetes defines the network model but ships no implementation — no CNI, no pod IPs, `NotReady` nodes.
- The addon's expected CIDR must match `--pod-network-cidr` or pods get unroutable addresses.

### ⚙️ How exactly it works
`kubectl apply -f <addon>.yaml` → DaemonSet schedules one agent per node → agent wires bridges/routes → kubelet reports NetworkReady → node `Ready`.

### 🧪 Hands-on examples

**Example 1 — Deploy Flannel and watch readiness flip:**
```bash
kubectl get nodes                    # NotReady
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get pods -n kube-flannel -w  # agent Running
kubectl get nodes                    # Ready
# Verify: readiness was blocked ONLY on the CNI.
```

**Example 2 — Confirm the CIDR match:**
```bash
kubectl logs -n kube-flannel -l app=flannel | grep -i cidr
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}{"\n"}'
# Verify: both show 10.244.x — matching the --pod-network-cidr from init.
```

**Example 3 — Smoke-test pod networking:**
```bash
kubectl run web --image=nginx
kubectl run client --image=busybox -it --rm -- wget -qO- $(kubectl get pod web -o jsonpath='{.status.podIP}') | head -1
# Verify: pod-to-pod traffic flows — the CNI is doing its one job.
```

---

## 4. Join worker nodes

### ❓ What
`kubeadm join <cp>:6443 --token … --discovery-token-ca-cert-hash sha256:…` — enrolls a prepared node: the **token** authorizes it, the **CA hash** lets it verify it's talking to the *real* control plane.

### 🔥 Pain points it solves & why this?
- Manually bootstrapping a kubelet (cert signing, kubeconfig) per node is exactly the tedium kubeadm kills.
- Security both ways: cluster trusts the node (token), node trusts the cluster (CA fingerprint) — no MITM.
- Tokens expire (**24 h**) — regeneration is a needed skill.

### ⚙️ How exactly it works
Worker contacts the apiserver → verifies the CA hash → presents the token → kubelet does TLS bootstrap (gets a signed cert) → node registers (NotReady until the CNI DaemonSet lands on it).

### 🧪 Hands-on examples

**Example 1 — Join a worker:**
```bash
# control plane:
kubeadm token create --print-join-command
# worker (prereqs done, as root):
sudo kubeadm join 192.168.56.11:6443 --token <t> --discovery-token-ca-cert-hash sha256:<hash>
kubectl get nodes -w      # node appears → Ready once CNI pod lands
# Verify: both nodes Ready; kubectl run schedules onto the worker.
```

**Example 2 — Expired token? Regenerate:**
```bash
kubeadm token list                          # old one expired (TTL 24h)
kubeadm token create --print-join-command   # fresh command, same CA hash
# Verify: join works with the new token; never reuse old ones.
```

**Example 3 — Re-join a broken node cleanly:**
```bash
# worker that half-joined before:
sudo kubeadm reset -f            # clears stale state (certs, manifests, CNI config)
sudo kubeadm join <ip>:6443 --token <new> --discovery-token-ca-cert-hash sha256:<hash>
# Verify: node registers fresh; reset-before-rejoin avoids "already exists" errors.
```

---

## ➕ Added (not in the transcript, worth knowing)

- **The full order as one line:** prereqs (all nodes) → `init` (CP) → kubeconfig → CNI → `join` (workers) — recite it.
- `kubeadm init phase …` lets you run/re-run single phases (e.g. regenerate certs) — handy beyond the exam.
- This freshly built cluster is what [Section 5](05-cluster-maintenance.md) upgrades and backs up — the flows compose.

---

## Related
[09-design-and-install](09-design-and-install-kubernetes-cluster.md) (the design you're building) · [05-cluster-maintenance](05-cluster-maintenance.md) (upgrades) · [08-networking](08-networking.md) (CNI details) · [13-troubleshooting](13-troubleshooting.md) · Ladder version: [../README/10-install-kubernetes-kubeadm-way.md](../README/10-install-kubernetes-kubeadm-way.md)
