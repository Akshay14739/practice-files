# Kubeadm Install, Climbed the Ladder 🪜
### Section 10 of the CKA — deriving how prepared VMs become a cluster

> Bootstrapping a real multi-node cluster with **kubeadm**: prerequisites (runtime, cgroups, sysctls), `kubeadm init`, deploying a CNI, joining workers. We climb from **the pain of installing Kubernetes by hand** → **the "two commands over prepared nodes" idea** → **the machinery** → then the sequence as predictions. Each rung ends with a **✅ Check yourself**.

---

# RUNG 0 — The Setup 🎯

**What am I learning?** The exact, ordered procedure to turn bare Linux VMs into a working cluster: prepare every node, `kubeadm init` the control plane, deploy a pod network, and `kubeadm join` the workers.

**Why did it land on my desk?** *Installation & Configuration* is part of the 25% Cluster-Architecture domain, and building or **joining a node** to a cluster can be a task. It's also the foundation for the upgrade tasks ([Section 5](05-cluster-maintenance.md)).

**What do I already know?** Maybe that `kubeadm init` "sets up the master." What's fuzzy: *why* you must fix the cgroup driver and sysctls first, and why a freshly-initialized node is `NotReady`.

---

# RUNG 1 — The Pain 🔥
### *Why does kubeadm exist at all?*

Installing Kubernetes "the hard way" means assembling a dozen moving parts by hand:

```
INSTALLING KUBERNETES BY HAND (the pain)
  generate a CA + ~10 certs (apiserver, etcd, kubelet, client…) → one wrong SAN = broken TLS
  write systemd units / static-pod manifests for apiserver, etcd, scheduler, controller-mgr
  wire every component's flags to the right cert paths and etcd endpoints
  bootstrap each worker's kubelet with a signed cert, by hand
  → days of work, a hundred ways to typo it
```

**Before / without it:** you did all of the above manually (Kelsey Hightower's "Kubernetes the Hard Way") — educational, but unthinkable for real setup.

**What breaks without a bootstrapper:** correctness (hand-made PKI and manifests are error-prone) and speed (a cluster should be minutes, not days). And nodes must be *prepared* (runtime, cgroups, kernel settings) or the kubelet won't run pods at all.

**Who feels it most?** Anyone standing up a non-managed cluster — the platform team on-prem or in raw VMs.

> **✅ Check yourself before Rung 2:** Name two things `kubeadm init` generates for you that would be tedious and error-prone to build by hand. (Hint: think TLS, and think control-plane process definitions.)

---

# RUNG 2 — The One Idea 💡
### *The single sentence everything hangs off*

> **kubeadm turns prepared Linux VMs into a cluster with two commands — `kubeadm init` generates all the PKI and writes the control plane as **static pods** on the first node, then `kubeadm join` uses a **token + CA-cert hash** to securely enroll each worker — but only after you've fixed the **container runtime, cgroup driver, sysctls, and swap** on *every* node.**

Derivations:
- *"only after you've fixed runtime/cgroup/sysctls/swap"* → these are the **preflight** requirements; miss one and `init`/pods fail. The kubelet refuses swap; CNIs need bridge/forwarding sysctls; the runtime's cgroup driver **must match** the kubelet's.
- *"init… writes the control plane as static pods"* → the apiserver/etcd/scheduler/controller-manager land in `/etc/kubernetes/manifests/` — the same static pods you saw in [Section 1](01-core-concepts.md).
- *"join… token + CA hash"* → a worker proves it's talking to the *real* control plane (CA hash) and is *authorized* to join (token); tokens expire in 24h.
- *(implicit)* the cluster is `NotReady` until you **deploy a CNI** — pods can't get IPs without one.

> **✅ Check yourself before Rung 3:** Why must the container runtime's cgroup driver match the kubelet's? What kind of failure do you get if they disagree?

---

# RUNG 3 — The Machinery ⚙️
### *How it ACTUALLY works — go slow. Order matters.*

> ### 🧸 Plain-English first (read this before the technical version)
>
> Imagine opening a chain of franchise restaurants from a startup kit. You can't just unlock the doors and start cooking — there's a strict order: get every building up to code, set up the headquarters, install the phone lines, then enroll the branch locations. That's exactly what this section walks through, in four steps.
>
> - **Step A — Prepare every building first.** Before anything else, every computer that will be part of the cluster (the group of machines working together) needs some housekeeping:
>   - Flip a few switches in the operating system so network traffic between apps can flow and be inspected properly (like making sure the building's plumbing and wiring meet code).
>   - Turn off "swap" (a trick where the computer uses slow disk space as pretend memory) — Kubernetes' on-site manager program, the **kubelet**, refuses to work if it's on, because it makes performance unpredictable.
>   - Install the "kitchen equipment": the **container runtime** (the software that actually runs your apps in their sealed boxes). One gotcha: the runtime and the kubelet must agree on the same accounting system for resources (the "cgroup driver") — like two managers who must use the same ledger, or the books never balance and everything crashes.
>   - Install the toolkit and **pin the versions** so an automatic update doesn't quietly swap your tools mid-project.
>
> - **Step B — Set up headquarters (`kubeadm init`, run on one machine only).** One command builds the entire head office: it prints all the security ID badges and certificates (so every part can prove who it is), writes the instruction sheets that start the management programs, and hands you two things — a login file so you can talk to the cluster, and an invitation command for the branches. Oddly, HQ reports itself as "NotReady" at first — that's expected, not broken.
>
> - **Step C — Install the phone system (the CNI, or pod network).** The machines can't pass messages between apps until you install a networking add-on. One small agent runs on every machine (like putting one telephone technician in each building), and it hands out internal phone numbers (IP addresses) to the apps. Once installed, "NotReady" flips to "Ready."
>
> - **Step D — Enroll the branches (`kubeadm join`).** Each worker machine joins using two secrets: a **token** (a temporary invitation code that expires in 24 hours — you can print a fresh one anytime) and a **certificate hash** (a fingerprint that lets the branch verify it's really talking to the genuine HQ, not an impostor). The branch then gets its own signed ID badge and is registered as part of the chain.
>
> The one rule above all: **order matters.** Skip a preparation step and the later steps fail in confusing ways.

*Now the original technical deep-dive — the same ideas, in precise form:*

**The workflow:** provision VMs → **runtime** on all nodes → **kubeadm/kubelet/kubectl** on all nodes → **`kubeadm init`** on control plane → **deploy CNI** → **`kubeadm join`** workers.

## (A) Prerequisites — on EVERY node (and *why* each)

```bash
# 1) Kernel modules + sysctls: CNIs/kube-proxy need bridged traffic to hit iptables + IP forwarding
sudo modprobe overlay && sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
# 2) Swap OFF — the kubelet refuses to run with swap by default
sudo swapoff -a
```
**Container runtime (containerd) — the cgroup-driver gotcha:**
```bash
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml   # MATCH the kubelet
sudo systemctl restart containerd
```
> 🎯 The **kubelet and runtime must use the SAME cgroup driver** (systemd on a systemd host). kubeadm ≥1.22 defaults the *kubelet* to systemd, but you must set **`SystemdCgroup = true`** in containerd yourself.

**Install the tools (pinned + held):**
```bash
sudo apt-get install -y kubelet=1.31.1-1.1 kubeadm=1.31.1-1.1 kubectl=1.31.1-1.1
sudo apt-mark hold kubelet kubeadm kubectl    # pin so a stray upgrade doesn't drift versions
```

## (B) `kubeadm init` — control-plane node only

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.56.11 \   # the RIGHT NIC's IP
  --pod-network-cidr=10.244.0.0/16                 # must match your CNI
  # --control-plane-endpoint=<LB>   ← add if you MIGHT go HA later
```
Under the hood it: generates the **CA + all component certs** (`/etc/kubernetes/pki`), writes the **static-pod manifests**, starts the control plane, and prints (1) the **kubeconfig setup** and (2) the **`kubeadm join`** command.
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes        # control plane = NotReady  (expected until CNI)
```

## (C) Deploy a CNI

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get nodes        # flips to Ready
```
The addon runs as a **DaemonSet** (one agent per node) and owns the **pod CIDR** (match `--pod-network-cidr`).

## (D) Join the workers

```bash
# control plane: (re)generate the join command anytime — tokens last 24h
kubeadm token create --print-join-command
# worker (as root):
sudo kubeadm join 192.168.56.11:6443 --token <t> --discovery-token-ca-cert-hash sha256:<hash>
```
The **token** authorizes the join; the **CA-cert hash** lets the worker verify it's the real control plane (not a MITM). The worker's kubelet does a TLS bootstrap, gets a signed cert, and registers the node.

> **✅ Check yourself before Rung 4:** After `kubeadm init` succeeds, `kubectl get nodes` shows `NotReady`. Is that a bug? What single action fixes it, and why was the node not Ready before?

---

# RUNG 4 — The Vocabulary Map 🏷️

| Term | What it actually is | Which step |
|---|---|---|
| **br_netfilter / ip_forward** | Kernel module/sysctl so bridged pod traffic hits iptables + is forwarded | Prereqs |
| **swapoff** | Disable swap (kubelet requirement) | Prereqs |
| **cgroup driver / SystemdCgroup** | How the runtime + kubelet account resources; must match | Prereqs |
| **kubeadm / kubelet / kubectl** | Bootstrapper / node agent / CLI | Prereqs |
| **apt-mark hold** | Pin versions against upgrades | Prereqs |
| **kubeadm init** | Bootstraps the control plane | Init |
| **--apiserver-advertise-address** | The control-plane IP to advertise | Init flag |
| **--pod-network-cidr** | Pod IP range (match the CNI) | Init flag |
| **/etc/kubernetes/pki** | Generated CA + certs | Init output |
| **admin.conf** | The admin kubeconfig | Init output |
| **CNI addon** | DaemonSet giving pods IPs | CNI |
| **kubeadm join** | Enroll a worker | Join |
| **token / discovery-token-ca-cert-hash** | Authorize join / verify the control plane | Join |
| **kubeadm reset** | Undo a join/init on a node | Recovery |

**The unlock — three phases:**
```
PREPARE every node:  runtime + cgroup driver + sysctls + swapoff + pinned tools
INIT one node:       kubeadm init → PKI + static-pod manifests + kubeconfig + join cmd
JOIN + NETWORK:      deploy CNI (→ Ready) ; kubeadm join workers (token + CA hash)
```

> **✅ Check yourself before Rung 5:** Which command runs on the control plane and which on a worker: `kubeadm init`, `kubeadm join`? What does the token protect against, and what does the CA-cert hash protect against?

---

# RUNG 5 — The Trace 🎬
### *Follow the bring-up end-to-end*

**Trace — `kubeadm init`, then a worker joins:**
1. **Preflight:** kubeadm checks swap off, runtime up, cgroup driver, ports free. Any failure aborts with a clear message.
2. **PKI:** it generates the **cluster CA** and every component cert (apiserver serving/SANs, etcd, kubelet client…) under `/etc/kubernetes/pki`.
3. **Manifests:** it writes static-pod YAML for apiserver/etcd/scheduler/controller-manager to `/etc/kubernetes/manifests/`; the local **kubelet** sees them and starts the control plane.
4. **Bootstrap:** once the apiserver is up, kubeadm creates a **bootstrap token** and prints the `join` command + the kubeconfig setup. You copy `admin.conf` to `~/.kube/config`.
5. **NotReady:** `kubectl get nodes` shows the node `NotReady` — no CNI yet, so pods can't get IPs.
6. **CNI:** `kubectl apply -f <addon>` deploys a DaemonSet; the node flips **Ready**.
7. **Worker join:** on the worker, `kubeadm join` contacts `:6443`, **verifies the CA hash** (real control plane?), presents the **token** (authorized?), TLS-bootstraps the kubelet (gets a signed cert), and registers the node — `NotReady` until the CNI DaemonSet schedules a pod there, then **Ready**.

```
init: preflight ✓ → CA+certs → static-pod manifests → kubelet starts control plane → token+join printed
      → NotReady → apply CNI → Ready
join: worker → :6443 (verify CA hash) → present token → kubelet TLS-bootstrap → node registers → Ready
```

> **✅ Check yourself before Rung 6:** At which step do the control-plane *certificates* get created, and at which step does a *worker* first prove it's contacting the genuine control plane?

---

# RUNG 6 — The Contrast ⚖️

| This… | vs that… | Difference |
|---|---|---|
| **kubeadm** | **minikube** | you provide VMs, multi-node vs it makes one VM, single-node |
| **kubeadm** | **"the hard way"** | automates PKI + manifests vs everything by hand |
| **kubeadm** | **managed (EKS/GKE)** | you run the control plane vs the cloud runs it |
| **`kubeadm init`** | **`kubeadm join`** | create the control plane vs enroll a worker |
| **before CNI** | **after CNI** | node `NotReady` (no pod IPs) vs `Ready` |

**When NOT to:** don't reach for kubeadm to *learn basic kubectl* (minikube is faster); don't skip the prereqs (swap/runtime/cgroup/sysctls) — they're the top cause of `init` failures; don't reuse a >24h-old token (regenerate it).

**One-sentence "why this over that":**
> Use kubeadm to bootstrap a real multi-node cluster you control — it automates the PKI and static-pod manifests — after you've prepped every node's runtime, cgroup driver, sysctls, and swap.

> **✅ Check yourself before Rung 7:** A worker's `kubeadm join` fails with "token expired." Why do tokens expire, and what's the one-line fix on the control plane?

---

# RUNG 7 — The Prediction Test 🧪

## Prediction 1 — Full bring-up: init → CNI → join

> **My prediction:** "If I `kubeadm init` then apply a CNI then join a worker, then both nodes go `Ready` — *because* init creates the control plane, the CNI gives pods IPs (flipping NotReady→Ready), and join enrolls the worker."

```bash
# control plane:
sudo kubeadm init --apiserver-advertise-address=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1) \
  --pod-network-cidr=10.244.0.0/16
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubeadm token create --print-join-command      # copy → run on the worker with sudo
kubectl get nodes                              # both Ready
```
**Verify:** both `Ready`, CNI DaemonSet has a pod per node. `NotReady` before the CNI is normal.

## Prediction 2 — A missed prereq blocks `init`

> **My prediction:** "If swap is on, the runtime is down, `SystemdCgroup` is false, or a sysctl is missing, then `kubeadm init` fails preflight with a specific message — *because* the kubelet/runtime can't operate under those conditions."

```bash
sudo kubeadm init ...            # read the preflight error
free -h                          # swap on? → sudo swapoff -a
sudo systemctl status containerd # down? → start/restart
grep SystemdCgroup /etc/containerd/config.toml   # false? → set true + restart
sysctl net.ipv4.ip_forward       # 0? → apply /etc/sysctl.d/k8s.conf
```
**Verify:** fixing the flagged prereq lets `init` complete. These four are the classic blockers.

## Prediction 3 — An expired token needs regenerating (and reset before re-join)

> **My prediction:** "If a node's join token expired (24h), a fresh `kubeadm token create --print-join-command` works; a previously-broken node must `kubeadm reset` first — *because* tokens are short-lived and a half-joined node has stale state."

```bash
# control plane:
kubeadm token create --print-join-command
# worker (if previously joined/broken):
sudo kubeadm reset -f
sudo kubeadm join 192.168.56.11:6443 --token <new> --discovery-token-ca-cert-hash sha256:<hash>
```
**Verify:** the node re-appears `Ready`. Reusing an old token fails; regenerate rather than reuse.

| Prediction: "If I do X, then Y, because [mechanism]" | Ran? | Right? | Miss? |
|---|---|---|---|
| 1. |  |  |  |

---

# 🎁 CAPSTONE — Compress It

**One sentence, no notes:**
> After preparing every node's runtime, cgroup driver, sysctls, and swap, `kubeadm init` generates the PKI and writes the control plane as static pods, a CNI addon makes the node Ready, and `kubeadm join` enrolls workers with a token + CA-cert hash.

**Explain it to a beginner in 3 sentences:**
> 1. First you prep each machine — install a container runtime with the matching cgroup driver, turn off swap, and set a couple of kernel networking options — or the kubelet won't run pods.
> 2. `kubeadm init` on the first node creates all the certificates and starts the control plane, then prints a join command.
> 3. You deploy a pod-network add-on (which turns the node Ready) and run the join command on each worker, which uses a token and a CA fingerprint to enroll securely.

**Which rung to revisit hands-on?** Rung 3A + Prediction 2 — the **prereqs** (cgroup driver, sysctls, swap) cause most real `init` failures, and the fixes are muscle memory worth building.

---

## 🎯 CKA exam tips & quick notes

- **Order:** runtime → kubeadm/kubelet/kubectl → `kubeadm init` → CNI → `kubeadm join`.
- **Prereqs that block init:** swap on, runtime down, wrong **cgroup driver** (`SystemdCgroup = true`), missing sysctls (`br_netfilter`, `ip_forward`).
- **init flags:** `--apiserver-advertise-address` (right NIC), `--pod-network-cidr` (match CNI), `--control-plane-endpoint` (HA), `--upload-certs` (multi-CP).
- **kubeconfig:** copy `/etc/kubernetes/admin.conf` → `~/.kube/config`.
- Node **NotReady** right after init = **deploy a CNI**.
- **Regenerate the join command** with `kubeadm token create --print-join-command` (24h tokens); `kubeadm reset -f` before re-joining a broken node.
- Control-plane components are **static pods** in `/etc/kubernetes/manifests/`; the **kubelet is a systemd service** you keep running.

## 📌 Command cheat sheet
```bash
# PREREQS (all nodes)
sudo swapoff -a
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml && sudo systemctl restart containerd
# CONTROL PLANE
sudo kubeadm init --apiserver-advertise-address=<ip> --pod-network-cidr=10.244.0.0/16
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config
kubectl apply -f <cni>.yaml
kubeadm token create --print-join-command
# WORKER
sudo kubeadm join <ip>:6443 --token <t> --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Related sections

- [Section 9 — Design & Install a Kubernetes Cluster](09-design-and-install-kubernetes-cluster.md) — the HA/topology design you're implementing.
- [Section 5 — Cluster Maintenance](05-cluster-maintenance.md) — upgrading the cluster you just built.
- [Section 8 — Networking](08-networking.md) — CNI / pod-CIDR details for the network addon step.
- [Section 6 — Security](06-security.md) — the PKI kubeadm generates under `/etc/kubernetes/pki`.
- [Section 13 — Troubleshooting](13-troubleshooting.md) — when control-plane static pods won't start.
- [../../Linux/14-cgroups.md](../../Linux/14-cgroups.md) · [../../Linux/24-kernel-tuning-boot.md](../../Linux/24-kernel-tuning-boot.md) — the cgroup driver and sysctls/modules you configure in prereqs.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** Name two things `kubeadm init` generates for you that would be tedious and error-prone to build by hand. (Hint: TLS, and control-plane process definitions.)

**A:** (1) The entire PKI — the cluster CA plus roughly ten component certificates (apiserver serving cert with its SANs, etcd certs, kubelet client certs, etc.) under `/etc/kubernetes/pki`; done by hand, one wrong SAN means broken TLS. (2) The static-pod manifests for the control-plane processes — apiserver, etcd, scheduler, and controller-manager — written to `/etc/kubernetes/manifests/` with every component's flags correctly wired to the right cert paths and etcd endpoints. Building either manually is "the hard way": days of work with a hundred ways to typo it.

### Before Rung 3
**Q:** Why must the container runtime's cgroup driver match the kubelet's? What kind of failure do you get if they disagree?

**A:** The cgroup driver is how the runtime and the kubelet account for and enforce resource limits on containers; if the two use different drivers (e.g. containerd on `cgroupfs` while the kubelet uses `systemd`), they manage two conflicting views of the cgroup hierarchy on the same host. The result is instability: the kubelet and runtime fight over resource management, so pods fail to start or the node becomes flaky, and `kubeadm init` can fail its preflight/bring-up. That's why on a systemd host you set `SystemdCgroup = true` in `/etc/containerd/config.toml` yourself — kubeadm ≥1.22 already defaults the kubelet to the systemd driver.

### Before Rung 4
**Q:** After `kubeadm init` succeeds, `kubectl get nodes` shows `NotReady`. Is that a bug? What single action fixes it, and why was the node not Ready before?

**A:** It's not a bug — it's the expected state right after `init`. The single fix is to deploy a CNI network addon (e.g. `kubectl apply -f kube-flannel.yml`), after which the node flips to `Ready`. The node was `NotReady` because without a CNI plugin pods can't get IPs, so the kubelet reports the node's network as not ready; the addon runs as a DaemonSet (one agent per node) and owns the pod CIDR that must match `--pod-network-cidr`.

### Before Rung 5
**Q:** Which command runs on the control plane and which on a worker: `kubeadm init`, `kubeadm join`? What does the token protect against, and what does the CA-cert hash protect against?

**A:** `kubeadm init` runs on the control-plane node (it bootstraps the control plane); `kubeadm join` runs on each worker (it enrolls that node). The token authorizes the join — it proves to the control plane that this worker is allowed to join the cluster (and it expires after 24h, limiting the window of abuse). The CA-cert hash protects the worker in the other direction: it lets the worker verify it is talking to the genuine control plane and not a man-in-the-middle impersonating it.

### Before Rung 6
**Q:** At which step do the control-plane *certificates* get created, and at which step does a *worker* first prove it's contacting the genuine control plane?

**A:** The certificates are created in step 2 of the trace — right after preflight passes, kubeadm generates the cluster CA and every component cert (apiserver serving/SANs, etcd, kubelet client, etc.) under `/etc/kubernetes/pki`, before the static-pod manifests are written. A worker first verifies it's contacting the genuine control plane in step 7, at the start of `kubeadm join`: it contacts `:6443` and checks the discovery-token-ca-cert-hash against the control plane's CA, and only then presents its token and TLS-bootstraps the kubelet.

### Before Rung 7
**Q:** A worker's `kubeadm join` fails with "token expired." Why do tokens expire, and what's the one-line fix on the control plane?

**A:** Bootstrap tokens are deliberately short-lived — they expire after 24 hours — so a leaked or stale token can't be used indefinitely to enroll rogue nodes into the cluster. The one-line fix on the control plane is `kubeadm token create --print-join-command`, which mints a fresh token and prints the complete join command (including the CA-cert hash) to run on the worker. Don't reuse an old token — regenerate it; and if the worker had a previous half-completed join, run `sudo kubeadm reset -f` on it first.
