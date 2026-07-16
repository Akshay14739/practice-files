# 🗺️ The Complete Linux ↔ Kubernetes Map
### The capstone: every Kubernetes abstraction, unmasked as the Linux primitive it really is — plus a node-triage playbook you can run at 3 AM

> This is the synthesis file. Every other file in this guide taught you *one* primitive in depth. This one ties them together into a single claim and then proves it:
>
> **Every Kubernetes feature you administer is a Linux kernel primitive wearing a friendlier name. A Pod is not a new kind of object — it's a bundle of namespaces and cgroups. A Service is not magic — it's a pile of iptables rules. A Secret volume is a `tmpfs` mount. Once you can see the primitive underneath, Kubernetes stops being a black box and becomes *obvious* — because you already know what the kernel does, and K8s is just automating it.**
>
> You came in strong on `kubectl` but newer to the kernel. This file closes the loop: it lets you read a K8s symptom and know *exactly which file on the node to `cat`* to confirm what's really happening. That skill — dropping from the control plane onto the node and verifying the kernel's own accounting — is what separates someone who *operates* Kubernetes from someone who *understands* it.

---

## 🔥 The pain this file removes

You've lived every one of these, and each time the answer lived on the node, not in `kubectl`:

- A pod shows `OOMKilled` but `kubectl describe node` says 60 GB free. Who lied? (Nobody — you were reading the wrong ceiling.)
- A `ClusterIP` Service works, but you have no idea *how* a virtual IP that belongs to no interface routes to a real pod.
- `kubectl exec` drops you into "the container" — but what actually happened at the kernel level to put your shell "inside"?
- A node goes `NotReady` and you're staring at `kubectl get nodes` with no idea which of a dozen node-level facts broke.

The cure is always the same move: **stop trusting the abstraction, drop to the node, and read the kernel's own state.** This file is the map for that move.

---

## The full mapping

Read this table as: *"When I do X in Kubernetes, the kernel does Y, and I can prove it by inspecting Z."* The final column points to the file in this guide where that primitive is taught from the ground up.

| Kubernetes Concept | Linux Primitive (the real thing) | Where / how to inspect it on the node | Deep-dive file |
|---|---|---|---|
| **Pod isolation** (each pod its own network/PID/mount view) | **Namespaces** — 8 kernel namespaces (net, pid, mnt, uts, ipc, user, cgroup, time). A pod = a shared set of namespaces its containers join | `lsns`; `ls -l /proc/<pid>/ns/`; `nsenter -t <pid> -n ip addr` | [13-namespaces.md](13-namespaces.md) |
| **CPU limit** (`resources.limits.cpu`) | **cgroup v2 `cpu.max`** — quota/period pair; the CFS bandwidth controller throttles the group | `cat /sys/fs/cgroup/kubepods.slice/.../cpu.max` → `20000 100000` = 0.2 CPU | [14-cgroups.md](14-cgroups.md) |
| **Memory limit** (`resources.limits.memory`) | **cgroup v2 `memory.max`** — hard ceiling on the group's page usage | `cat .../memory.max` and `.../memory.current` | [14-cgroups.md](14-cgroups.md) |
| **CPU request** (`requests.cpu`) | **cgroup `cpu.weight`** — proportional share under contention (NOT a cap) | `cat .../cpu.weight` (weight, derived from millicores) | [14-cgroups.md](14-cgroups.md) |
| **OOMKilled** | **Kernel OOM killer**, scoped to the container's memory cgroup, fired when `memory.current` hits `memory.max` | `dmesg -T \| grep -i oom`; `cat .../memory.events` (`oom_kill` counter) | [14-cgroups.md](14-cgroups.md) |
| **QoS classes** (Guaranteed / Burstable / BestEffort) | **cgroup nesting + `oom_score_adj`** — which cgroup slice the pod lands in and how kill-attractive its processes are | `cat /proc/<pid>/oom_score_adj`; cgroup path `kubepods-{burstable,besteffort}.slice` | [14-cgroups.md](14-cgroups.md) |
| **Container image layers** | **OverlayFS** — a union mount: read-only image layers (lowerdir) + a writable container layer (upperdir) | `mount \| grep overlay`; `ctr snapshot ls`; look under `/var/lib/containerd/.../snapshots` | [15-storage-mounts.md](15-storage-mounts.md) |
| **ClusterIP Service** | **iptables (or IPVS) DNAT** — the virtual IP is never on any interface; a `KUBE-SERVICES` rule rewrites the destination to a real pod IP | `iptables -t nat -L KUBE-SERVICES -n`; `ipvsadm -Ln` (IPVS mode) | [12-iptables-netfilter.md](12-iptables-netfilter.md) |
| **NodePort Service** | **iptables DNAT on a host port** — `KUBE-NODEPORTS` chain catches traffic to the node's port and DNATs to the service | `iptables -t nat -L KUBE-NODEPORTS -n`; `ss -ltnp` shows the port held open | [12-iptables-netfilter.md](12-iptables-netfilter.md) |
| **Pod-to-pod networking** (same node) | **veth pair + Linux bridge** — each pod gets one end of a virtual ethernet cable; the other end plugs into a bridge (e.g. `cni0`) | `ip link` (see `vethXXXX@ifN`); `bridge link`; `ip -n <netns> addr` | [13-namespaces.md](13-namespaces.md), [11-networking.md](11-networking.md) |
| **Pod networking** (cross-node) | **VXLAN / IP-in-IP overlay or routed CNI** — encapsulation over the node network, or plain routes | `ip -d link show flannel.1` (VXLAN); `ip route`; `bridge fdb show` | [11-networking.md](11-networking.md) |
| **NetworkPolicy** | **iptables / nftables / eBPF rules injected by the CNI** — allow/deny by source pod, port, namespace | `iptables -L -n \| grep -i cilium/calico`; CNI-specific (`calicoctl`, `cilium`) | [12-iptables-netfilter.md](12-iptables-netfilter.md) |
| **CoreDNS / service DNS** | **`/etc/resolv.conf` injected into the pod's mnt namespace** — points at the CoreDNS ClusterIP; `search` domains do the short-name magic | `kubectl exec -- cat /etc/resolv.conf`; on node `nsenter -t <pid> -m cat /etc/resolv.conf` | [11-networking.md](11-networking.md) |
| **ConfigMap volume** | **Bind mount + symlink farm** — the kubelet writes keys into a timestamped `..data` dir and symlinks them, then bind-mounts into the container | `mount \| grep <cm-name>`; `ls -la` the mount inside the pod shows `..data` symlinks | [15-storage-mounts.md](15-storage-mounts.md), [04-file-operations.md](04-file-operations.md) |
| **Secret volume** | **`tmpfs` mount** — secrets live in RAM-backed filesystem, never touch the node's disk | `mount \| grep tmpfs` (you'll see the secret's mount path); `findmnt` | [15-storage-mounts.md](15-storage-mounts.md) |
| **emptyDir** | **A plain directory** under `/var/lib/kubelet/pods/.../volumes/` (or `tmpfs` if `medium: Memory`) | `findmnt`; `du -sh /var/lib/kubelet/pods/*/volumes/` | [15-storage-mounts.md](15-storage-mounts.md) |
| **PersistentVolume / PVC** | **A `mount`** — the CSI driver attaches a block device or network FS and `mount`s it into the pod's mnt namespace | `findmnt <path>`; `lsblk`; `mount \| grep <pvc-id>` | [15-storage-mounts.md](15-storage-mounts.md) |
| **securityContext.runAsUser** | **Process UID** — the container's PID 1 is `exec`'d with that UID; it's just `setuid` before exec | `ps -o uid,pid,cmd -p <pid>`; `cat /proc/<pid>/status \| grep Uid` | [05-permissions-ownership.md](05-permissions-ownership.md), [06-users-groups-sudo.md](06-users-groups-sudo.md) |
| **fsGroup** | **Supplementary GID + `chown`/setgid on the volume** — kubelet recursively sets group ownership so the process can write | `ls -ln <volume-mount>` (check group); `cat /proc/<pid>/status \| grep Groups` | [05-permissions-ownership.md](05-permissions-ownership.md) |
| **seccompProfile** | **seccomp-bpf** — a BPF filter attached to the process that allows/denies individual syscalls | `grep Seccomp /proc/<pid>/status` (2 = filter mode); `cat /proc/<pid>/status \| grep Seccomp_filters` | [18-seccomp.md](18-seccomp.md) |
| **capabilities** (`securityContext.capabilities`) | **Linux capabilities** — the root privilege split into ~40 bits (`CAP_NET_ADMIN`, etc.) | `grep Cap /proc/<pid>/status`; `getpcaps <pid>`; `capsh --decode=<hex>` | [17-capabilities.md](17-capabilities.md) |
| **AppArmor annotation** | **AppArmor profile** — path-based mandatory access control confining the process | `cat /proc/<pid>/attr/current`; `aa-status` | [19-apparmor.md](19-apparmor.md) |
| **SELinux (`seLinuxOptions`)** | **SELinux type enforcement** — labels on processes and files, type transitions | `ps -Z`; `ls -Z`; `ausearch -m avc` for denials | [20-selinux.md](20-selinux.md) |
| **kubelet** | **A `systemd` service** — a plain daemon supervised by systemd, restarted on failure | `systemctl status kubelet`; `journalctl -u kubelet` | [16-systemd-services.md](16-systemd-services.md) |
| **Static pods** (control plane) | **Manifest files watched on disk** — kubelet polls `/etc/kubernetes/manifests` and runs whatever YAML appears there, no API server needed | `ls /etc/kubernetes/manifests/`; edit a file → kubelet reacts | [16-systemd-services.md](16-systemd-services.md) |
| **Container stdout/stderr → logs** | **File descriptors 1 & 2 redirected to a log file** — the runtime wires the container's fd 1/2 to a file the kubelet reads | `ls -l /var/log/pods/<ns>_<pod>_.../`; `ls -l /proc/<pid>/fd/1` | [10-io-redirection-pipes.md](10-io-redirection-pipes.md), [01-linux-philosophy.md](01-linux-philosophy.md) |
| **`kubectl exec`** | **`nsenter` into the container's namespaces + a pty on `/dev/pts`** — you join the same namespaces and get a pseudo-terminal | on node: `nsenter -t <pid> -a /bin/sh`; `ls /dev/pts` inside | [13-namespaces.md](13-namespaces.md), [07-processes-job-control.md](07-processes-job-control.md) |
| **Node `NotReady`** | **kubelet stopped POSTing status** — usually the systemd service died, or its container runtime socket is gone | `systemctl status kubelet containerd`; `journalctl -u kubelet -p err` | [16-systemd-services.md](16-systemd-services.md) |
| **API server / etcd TLS** | **x509 PKI** — a CA plus leaf certs; everything is mutual TLS | `openssl x509 -in <crt> -noout -dates`; `kubeadm certs check-expiration` | [26-tls-pki-openssl.md](26-tls-pki-openssl.md) |
| **Required sysctls** | **Kernel parameters** — `net.bridge.bridge-nf-call-iptables=1` (so iptables sees bridged traffic) and `net.ipv4.ip_forward=1` (so the node routes) | `sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward`; `lsmod \| grep br_netfilter` | [24-kernel-tuning-boot.md](24-kernel-tuning-boot.md) |
| **Swap must be off** | **`swapoff`** — the scheduler and cgroup memory accounting assume no swap, so memory limits mean what they say | `swapon --show` (should be empty); `free -h` (Swap: 0) | [24-kernel-tuning-boot.md](24-kernel-tuning-boot.md), [14-cgroups.md](14-cgroups.md) |

**The pattern to internalize:** there is no column of "Kubernetes magic." Every row resolves to a file you can `cat`, a mount you can `findmnt`, a rule you can list, or a process attribute you can read from `/proc`. Kubernetes is an *orchestrator of these primitives*, not a replacement for them.

---

## ⚙️ How the pieces connect

Let's trace two things end-to-end, because a K8s object is never *one* primitive — it's a stack of them cooperating.

### Trace A — A memory limit becoming an OOMKill

```
YAML you wrote                          What the kernel actually does
─────────────                           ─────────────────────────────
resources:
  limits:
    memory: 128Mi   ────┐
                        │  kubelet computes the cgroup path
                        ▼
        /sys/fs/cgroup/kubepods.slice/
          kubepods-burstable.slice/          ← QoS class picks the parent slice
            kubepods-burstable-pod<uid>.slice/
              cri-containerd-<id>.scope/
                memory.max  ◀── echo 134217728   (128Mi in bytes)
                                        │
   app allocates memory...             │ every page charged to this cgroup
   memory.current climbs ──────────────┤
                                        ▼
   memory.current == memory.max  →  kernel OOM killer fires
                                        │  (scoped to THIS cgroup only —
                                        │   the node's 60GB free is irrelevant)
                                        ▼
                     kills the biggest process in the cgroup
                                        │
                     memory.events: oom_kill 1 ──┐
                                        │         │ kubelet reads this
                                        ▼         ▼
                     container exits 137   →   Pod status: OOMKilled
```

The whole "OOMKilled mystery" dissolves: the ceiling was `memory.max` on the *container's cgroup*, not the node. The node being 60 GB free is a category error — the kernel enforces the limit on the *box of PIDs*, per [14-cgroups.md](14-cgroups.md).

### Trace B — A packet from `curl svc` to a pod

```
Pod A does:  curl http://my-svc:80        (my-svc ClusterIP = 10.96.0.50)
     │
     │ 1. DNS: /etc/resolv.conf (in Pod A's mnt ns) → CoreDNS ClusterIP
     │        CoreDNS answers 10.96.0.50           [11-networking.md]
     ▼
   packet: dst=10.96.0.50:80  — but NO interface owns this IP!
     │
     │ 2. Leaves Pod A via its veth into the node's net namespace
     │        veth pair + bridge cni0                [13, 11]
     ▼
   netfilter nat/PREROUTING → KUBE-SERVICES chain
     │
     │ 3. DNAT: rewrite dst 10.96.0.50:80 → 10.244.2.7:8080 (a real pod)
     │        kube-proxy wrote this rule             [12-iptables-netfilter.md]
     ▼
   routing decision on the (now real) dst IP
     │
     │ 4a. Pod on THIS node  → across bridge cni0 → target veth
     │ 4b. Pod on ANOTHER node → VXLAN encap → node NIC → remote node
     │        requires ip_forward=1 + br_netfilter   [24-kernel-tuning-boot.md]
     ▼
   arrives in Pod B's net namespace, dst 10.244.2.7:8080
     │
     │ 5. conntrack remembers the DNAT so the reply is un-rewritten
     ▼
   Pod B's app sees a normal TCP connection. It never knew about the VIP.
```

Five primitives — a file (`resolv.conf`), a virtual cable (`veth`), a bridge, a netfilter rule, a routing/encap decision — cooperated to make "a Service" work. Nothing else. That's the whole trick.

---

## Node triage workflow

When a node misbehaves — `NotReady`, pods stuck `ContainerCreating`, mysterious evictions — run this script on the node (via SSH or a debug pod with `nsenter`). It's ordered from *most likely to explain the outage* to *deeper forensics*, and each block tells you which deep-dive file to open if that check is the culprit.

```bash
#!/usr/bin/env bash
# node-triage.sh — systematic first-30-seconds check of a sick Kubernetes node.
# Run as root on the node. Read top-to-bottom; the first RED block is usually the cause.
set -uo pipefail

line() { printf '\n\033[1;36m===== %s =====\033[0m\n' "$1"; }

# ── 1. SYSTEM HEALTH ── is the box itself alive and sane? ──────────────────────
# High load, no free memory, or a full disk explains a HUGE fraction of node issues.
line "1. SYSTEM HEALTH (uptime / memory / disk)"
uptime                              # load averages vs core count; recent reboot?
free -h                             # Mem available? Swap MUST read 0 (K8s requires swap off)
df -h /var /var/lib /               # a full /var is the #1 cause of NotReady + image pull fails
#   → disk full?      see [15-storage-mounts.md]
#   → swap non-zero?  see [24-kernel-tuning-boot.md] (kubelet refuses to run with swap on by default)

# ── 2. CORE SERVICES ── the two daemons the node cannot live without ───────────
# A node is NotReady almost always because kubelet stopped POSTing status.
line "2. CORE SERVICES (kubelet + container runtime)"
systemctl is-active kubelet containerd || true
systemctl status kubelet --no-pager -l | head -n 15
systemctl status containerd --no-pager -l | head -n 8
#   → dead/activating? see [16-systemd-services.md]; check the runtime socket below.
ls -l /run/containerd/containerd.sock 2>/dev/null || echo "runtime socket MISSING"

# ── 3. RECENT KUBELET ERRORS ── what did it complain about before dying? ───────
line "3. KUBELET ERRORS (last 15 min, error priority only)"
journalctl -u kubelet -p err --since "-15min" --no-pager | tail -n 40
#   Common smoking guns: cert expired, CNI not ready, image pull auth, disk pressure.
#   → cert errors?  see [26-tls-pki-openssl.md]   → CNI errors? see [11]/[12]

# ── 4. OOM & KERNEL EVENTS ── did the kernel kill something important? ─────────
line "4. OOM / KERNEL EVENTS (dmesg)"
dmesg -T --level=err,warn | grep -iE 'oom|killed process|memory' | tail -n 20
#   System-wide OOM (not a single pod's cgroup) means node memory pressure —
#   the kubelet may start EVICTING pods.  see [14-cgroups.md] & [21-performance-monitoring.md]

# ── 5. DISK USAGE OF THE K8s STATE DIRS ── what's eating /var? ─────────────────
line "5. DISK USAGE of /var/lib/* (kubelet, containerd, etcd)"
du -sh /var/lib/kubelet /var/lib/containerd /var/log/pods 2>/dev/null
du -sh /var/lib/etcd 2>/dev/null   # control-plane nodes only
#   Runaway container logs or orphaned volumes here → disk pressure → eviction.  [15]

# ── 6. LISTENING PORTS ── are the control-plane sockets actually up? ───────────
line "6. LISTENING PORTS (control-plane & kubelet)"
ss -ltnp | grep -E ':(6443|10250|10259|10257|2379|2380)\b' || echo "  (none of the well-known ports are listening)"
#   6443=apiserver  10250=kubelet API  2379=etcd client  2380=etcd peer
#   Missing 10250 → kubelet down. Missing 2379/2380 on a CP node → etcd down.  [11-networking.md]

# ── 7. RESOURCE PRESSURE (PSI) ── is the node stalling on cpu/mem/io? ──────────
# PSI = Pressure Stall Information: % of time tasks were STALLED waiting for a resource.
line "7. PRESSURE STALL INFORMATION (/proc/pressure/*)"
for r in cpu memory io; do
  printf '%-7s ' "$r:"; awk '/^some/{print}' /proc/pressure/$r 2>/dev/null
done
#   avg10 climbing on memory/io is the earliest warning of pressure eviction.  [21-performance-monitoring.md]

# ── 8. CORE PROCESSES ── are kubelet/runtime/etcd actually running as processes? ─
line "8. CORE PROCESSES (top consumers + K8s daemons)"
ps -eo pid,ppid,uid,pcpu,pmem,rss,comm --sort=-pcpu | head -n 12
pgrep -a kubelet containerd etcd kube-apiserver 2>/dev/null || true
#   Cross-check: systemd says active but no process? runtime says active but no shim? [07-processes-job-control.md]

line "TRIAGE COMPLETE — the first block above showing red is almost always your root cause."
```

**How to read the output:** work top-down and stop at the *first* block that's abnormal — the ordering is deliberate (a full disk in block 1 explains failures that would otherwise look like kubelet or CNI bugs in later blocks). Nine times out of ten a `NotReady` node is one of: disk full (block 1/5), kubelet or containerd dead (block 2), or expired certs (block 3).

---

## CKA/CKS quick-reference

Grouped by the *kind of question* you're answering, because in an incident (or an exam) you think in symptoms, not alphabetical order. Every command here is a direct handle on one of the primitives in the mapping table.

### Process inspection — "what is this container, really?"

```bash
ps -eo pid,ppid,uid,pcpu,pmem,comm --sort=-pmem | head   # top memory hogs on the node
pgrep -a <name>                                          # PID + full cmdline by name
cat /proc/<pid>/status                                   # UID, Gid, Groups, CapEff, Seccomp — one-stop shop
cat /proc/<pid>/cgroup                                   # which cgroup(s) this PID lives in → maps to a pod
ls -l /proc/<pid>/ns/                                    # the 8 namespace handles (inode = identity)
ls -l /proc/<pid>/fd/                                    # open files; fd 1 & 2 are the container's stdout/stderr
readlink /proc/<pid>/root                                # the container's rootfs (its mnt-ns view of /)
```

### Namespace debugging with nsenter — "get me *inside* without kubectl exec"

```bash
# Find a pod's main PID from its container ID (crictl talks to the runtime directly):
crictl ps                                                # list running containers
crictl inspect <container-id> | jq .info.pid             # the host PID of the container's PID 1

PID=<that-pid>
nsenter -t $PID -n ip addr                               # enter ONLY the net ns → see the pod's IP/routes
nsenter -t $PID -n ss -tlnp                              # what's the pod actually listening on?
nsenter -t $PID -m cat /etc/resolv.conf                  # enter mnt ns → the pod's DNS config
nsenter -t $PID -a /bin/sh                               # enter ALL namespaces → this IS kubectl exec
lsns -t net                                              # list all network namespaces on the node
```

### cgroup inspection — "what are this pod's *real* limits and usage?"

```bash
CG=/sys/fs/cgroup/$(awk -F: '{print $3}' /proc/<pid>/cgroup | head -1)
cat $CG/memory.max        $CG/memory.current             # the limit vs live usage (bytes; 'max' = unlimited)
cat $CG/memory.events                                    # oom_kill counter — proves an OOMKill happened here
cat $CG/cpu.max                                          # "quota period" e.g. 20000 100000 = 0.2 CPU
cat $CG/cpu.weight                                       # proportional share (from requests.cpu)
cat $CG/cpu.stat                                         # nr_throttled / throttled_usec → CPU throttling proof
cat $CG/pids.current      $CG/pids.max                   # PID count vs limit (fork-bomb guard)
```

### Network debugging + iptables — "how does traffic actually reach the pod?"

```bash
ip addr; ip route                                        # node interfaces & routing table
ip -d link show                                          # detailed (see VXLAN devices like flannel.1)
bridge link; bridge fdb show                             # bridge members + forwarding DB (overlay MACs)
ss -tlnp                                                 # listening TCP sockets + owning process
iptables -t nat -L KUBE-SERVICES -n --line-numbers       # ClusterIP DNAT rules (the Service → pod magic)
iptables -t nat -L KUBE-NODEPORTS -n                     # NodePort rules
ipvsadm -Ln                                              # if kube-proxy is in IPVS mode instead of iptables
conntrack -L | head                                      # active connections + their DNAT translations
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables   # both MUST be 1
```

### Service & log management (systemd + journald) — "why is kubelet unhappy?"

```bash
systemctl status kubelet containerd                      # up? failed? since when?
systemctl cat kubelet                                    # the unit file + all drop-in overrides it merges
journalctl -u kubelet -p err --since "-1h" --no-pager    # error-priority logs, last hour
journalctl -u kubelet -f                                 # live tail
systemctl restart kubelet                                # the "have you tried turning it off and on" of nodes
ls /etc/kubernetes/manifests/                            # static pod manifests (apiserver/etcd/scheduler/cm)
```

### Storage — "what's mounted, and is the disk full?"

```bash
df -h /var /var/lib                                       # free space where K8s state lives
findmnt <path>                                           # exactly what's mounted at a path + its options
mount | grep -E 'overlay|tmpfs'                          # overlayfs (image layers) & tmpfs (secrets/emptyDir-mem)
lsblk                                                     # block devices → PersistentVolumes attach here
du -sh /var/lib/kubelet/pods/*/volumes/* 2>/dev/null      # per-volume disk usage (find the fat emptyDir)
crictl imagefs info; crictl stats                        # runtime's view of image disk & per-container usage
```

### Security & capabilities — "what privileges does this container hold?"

```bash
grep -E 'Uid|Gid|Groups|Cap|Seccomp' /proc/<pid>/status  # identity + capabilities + seccomp in one shot
getpcaps <pid>                                           # human-readable effective capabilities
capsh --decode=00000000a80425fb                          # decode a CapEff hex bitmask into names
cat /proc/<pid>/attr/current                             # AppArmor profile (or 'unconfined')
ps -eZ | grep <name>                                     # SELinux context (if enforcing)
aa-status                                                # loaded AppArmor profiles & enforce/complain counts
ausearch -m avc -ts recent                               # recent SELinux/AppArmor denials (why it broke)
```

### etcd snapshot & health — "protect / verify the cluster's memory"

```bash
# etcd speaks mutual TLS; you must present the certs kubeadm placed on the CP node.
export E="--endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"
ETCDCTL_API=3 etcdctl $E endpoint health                 # is etcd serving?
ETCDCTL_API=3 etcdctl $E endpoint status --write-out=table  # leader, DB size, raft term
ETCDCTL_API=3 etcdctl $E snapshot save /backup/etcd-$(date +%F).db   # THE backup that saves your job
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-....db --write-out=table   # verify the snapshot
```

### Certificate expiry — "is the control plane about to lock itself out?"

```bash
kubeadm certs check-expiration                           # every kubeadm-managed cert + days remaining
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate     # one cert's expiry date
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Subject Alternative'  # SANs
kubeadm certs renew all                                  # renew everything (then restart control-plane pods)
# Verify a kubeconfig's embedded client cert:
grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d | openssl x509 -noout -dates
```

*(Full treatment of the PKI model — CA, chain of trust, mutual TLS — is in [26-tls-pki-openssl.md](26-tls-pki-openssl.md).)*

---

## ⚖️ Contrast — where the abstraction leaks

Knowing the primitive also tells you *where Kubernetes stops being able to help you*, which is exactly what senior debugging is:

| The symptom | The naive (control-plane) view | The real (kernel) view — and why it matters |
|---|---|---|
| Pod `OOMKilled`, node has free RAM | "Weird, plenty of memory" | The **container's `memory.max` cgroup** hit its ceiling; node free RAM is irrelevant. Fix the limit, not the node. |
| Service resolves but connection hangs | "DNS is fine, must be the app" | DNS gave you a **ClusterIP that no NIC owns**; the hang is a missing/broken **iptables DNAT** or `ip_forward=0`. |
| `kubectl exec` works but the app can't reach a syscall | "Permissions?" | A **seccomp** filter is blocking the syscall; check `Seccomp:` in `/proc/<pid>/status`, not RBAC. |
| Secret readable in the pod but "gone" after reboot | "Did it get deleted?" | Secrets live on **`tmpfs` (RAM)** — never written to disk, so a reboot legitimately clears the backing store. |
| ConfigMap update not seen by the app | "Rollout bug" | The kubelet updates the **`..data` symlink** atomically, but apps that `open()`'d the old inode keep the old file — that's inode semantics, not a K8s bug. |

The through-line: **the abstraction is honest until it isn't, and the moment it leaks, you need the primitive.** That's why this whole guide exists.

---

## 🧪 Prediction test — prove the map to yourself

Before running each, write your prediction. A wrong prediction is your model repairing itself (the whole philosophy of this guide).

1. **cgroup = limit.** Pick a running pod with a memory limit. Predict the exact bytes in its `memory.max`, then `cat` the cgroup file. Right?
2. **Service = iptables.** `kubectl get svc` a ClusterIP. Predict that grepping `iptables -t nat -L -n` for that IP shows a `DNAT` to a pod IP. Confirm.
3. **exec = nsenter.** Get a pod's host PID via `crictl inspect`. Predict that `nsenter -t $PID -n ip addr` shows the *same* IP as `kubectl get pod -o wide`. Confirm they match — proving `exec` is just namespace entry.
4. **Secret = tmpfs.** Mount a Secret as a volume. Predict `mount | grep <path>` shows `tmpfs`, and that the node's disk never contains the plaintext. Confirm.
5. **NotReady = kubelet.** On a healthy node, predict that `systemctl stop kubelet` flips the node to `NotReady` within ~40s while *existing pods keep running* (because the container runtime, not kubelet, runs them). Confirm, then `start` it back.

If any prediction was wrong, that row of the mapping table is your next hands-on session — go to its deep-dive file.

---

## 🏔 Capstone — compress the whole guide into one breath

**One sentence, no notes:**

> Kubernetes is a distributed controller that assembles the same handful of Linux kernel primitives — namespaces for isolation, cgroups for limits, OverlayFS for images, iptables for services, veth/bridges/VXLAN for pod networking, tmpfs/bind-mounts for volumes, capabilities/seccomp/MAC for security, and systemd + PKI to run and trust it all — into the objects you write in YAML; so every K8s problem is, underneath, a Linux problem you can inspect with `cat`, `findmnt`, `iptables -L`, and `/proc`.

**The move that makes you senior:** when the abstraction confuses you, drop to the node and read the kernel's own accounting. The YAML is a request; the files under `/sys`, `/proc`, and `/etc` are the truth.

```
                 ┌─────────────────────────────────────────┐
   kubectl  ───▶ │            The abstraction               │  ← what you request
                 └───────────────────┬─────────────────────┘
                                     │  kubelet / kube-proxy / CRI / CNI translate
                                     ▼
   Pod ─────────▶ namespaces + cgroups            [13][14]
   Service ─────▶ iptables/IPVS DNAT              [12]
   Volume ──────▶ mount / tmpfs / overlayfs       [15]
   Image ───────▶ OverlayFS union mount           [15]
   Networking ──▶ veth + bridge + VXLAN           [11][13]
   Security ────▶ UID + caps + seccomp + MAC      [05][17][18][19][20]
   Runtime ─────▶ systemd + journald + PKI        [16][26]
                                     │
                                     ▼
                 ┌─────────────────────────────────────────┐
                 │       The Linux kernel (the truth)       │  ← what actually runs
                 └─────────────────────────────────────────┘
```

You now hold both halves. When Kubernetes surprises you, you know which file to open — and that is what it means to have *mastered* it.

---

## Related concepts

The primitives that carry the most Kubernetes weight — start here when a triage check points you somewhere:

- [13-namespaces.md](13-namespaces.md) — pod isolation, `kubectl exec` (nsenter), pod networking. The "what a container can SEE" half.
- [14-cgroups.md](14-cgroups.md) — CPU/memory limits, QoS, OOMKills, PSI. The "how MUCH it can USE" half. Together, these two files *are* "what a container is."
- [12-iptables-netfilter.md](12-iptables-netfilter.md) — every Service, NodePort, and NetworkPolicy resolves here.
- [15-storage-mounts.md](15-storage-mounts.md) — OverlayFS images, tmpfs Secrets, PV mounts, and the `/var` disk that causes NotReady.
- [16-systemd-services.md](16-systemd-services.md) — kubelet-as-a-service, static pods, journald. Where node triage begins.
- [11-networking.md](11-networking.md) — resolv.conf/CoreDNS, ports, the overlay, and `ss`/`ip` for network triage.
- [26-tls-pki-openssl.md](26-tls-pki-openssl.md) — the certs behind every control-plane connection; the silent cause of many `NotReady`/apiserver outages.
- [24-kernel-tuning-boot.md](24-kernel-tuning-boot.md) — the required sysctls (`br_netfilter`, `ip_forward`) and swap-off that a node needs before it can be a node at all.
- [21-performance-monitoring.md](21-performance-monitoring.md) — PSI, `dmesg`, `strace`, `lsof` when the node is *slow* rather than *down*.
- [17-capabilities.md](17-capabilities.md) · [18-seccomp.md](18-seccomp.md) · [19-apparmor.md](19-apparmor.md) · [20-selinux.md](20-selinux.md) — the four layers of `securityContext` and the CKS exam's core.
- [00-README.md](00-README.md) — back to the index and the 30-day plan.

*You climbed all 27 rungs. You can now read a Kubernetes symptom, name the Linux primitive underneath it, and `cat` the exact file that proves what's really happening. That round-trip — abstraction down to kernel and back — is mastery. Go debug something.*
