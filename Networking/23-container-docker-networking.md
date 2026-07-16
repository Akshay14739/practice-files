# Container & Docker Networking

*How a process in a box gets an IP, talks to its neighbors, and reaches the outside world — and why Kubernetes threw the default model away.*

---

## 🎯 Rung 0 — The Setup

**What am I learning?** How containers get networking: Docker's network drivers (**bridge**, **host**, **none**, **overlay**), container-to-container communication, embedded DNS, and port mapping.

**Why did it land on my desk?** Before you can understand the flat, magical Kubernetes pod network ([24-kubernetes-pod-networking-cni.md](24-kubernetes-pod-networking-cni.md)), you need the model it *reacted against*. Docker's default bridge network — with its NAT and per-host isolation — is where most engineers first meet container networking, and it's what your local `docker run` and CI builds still use every day.

**What do I already know?** You know a switch bridges L2 frames ([05-mac-addresses-switching-arp.md](05-mac-addresses-switching-arp.md)), NAT rewrites addresses ([14-nat-and-pat.md](14-nat-and-pat.md)), and Linux namespaces isolate a process's view ([../Linux/13-namespaces.md](../Linux/13-namespaces.md)). Container networking is those three ideas assembled.

---

## 🔥 Rung 1 — The Pain

A container is just a Linux process in its own **network namespace** — its own private network stack: its own interfaces, its own routing table, its own ports. Great for isolation, but it raises immediate questions:

- How do two containers on the same host **talk to each other** if each lives in its own network namespace?
- How does a container **reach the internet** to pull a dependency?
- How does the outside world **reach a service inside** a container whose IP is private and changes on every restart?

Before container networking drivers, you'd have wired up namespaces, `veth` pairs, bridges, and iptables by hand for every container — the exact manual toil you saw in [../Linux/13-namespaces.md](../Linux/13-namespaces.md). And you'd hit a nastier problem: **container IPs are ephemeral.** Restart a container and its IP changes, so hardcoding `10.17.0.4` in your app breaks the moment anything reschedules.

**Who feels it most?** Developers wanting `docker run` to "just work," and platform engineers who need a repeatable model that survives restarts.

> **✅ Check yourself before Rung 2:** If each container has its own isolated network namespace, why can't two containers on the same machine reach each other without something extra connecting them?

---

## 💡 Rung 2 — The One Idea

Memorize this:

> **Docker gives each container a private network namespace and connects it to a virtual switch (a bridge) on the host, so containers talk to each other over that bridge by name, reach the outside via NAT, and are reachable from outside only through explicit port mappings.**

Everything derives from "private namespace + a bridge + NAT + port maps":

- *Private namespace* → isolation, own IP, own ports.
- *A bridge (virtual switch)* → containers on it can reach each other; Docker's embedded DNS lets them use **names** instead of ephemeral IPs.
- *NAT outbound* → containers share the host's IP to reach the internet.
- *Explicit port mapping* → the outside can only reach a container port you deliberately publish.

> **✅ Check yourself before Rung 3:** Why do you connect to another container by *name* rather than by its IP address?

---

## ⚙️ Rung 3 — The Machinery

### The default bridge model

When Docker starts, it creates a virtual switch called **`docker0`** — a Linux bridge ([13-network-devices.md](13-network-devices.md)). Each container gets a **veth pair**: one end (`eth0`) inside the container's namespace, the other end plugged into `docker0`. The bridge switches L2 frames between all attached containers, exactly like a physical switch.

```
                    HOST (single machine)
 ┌───────────────────────────────────────────────────────────┐
 │  eth0 (host's real NIC, e.g. 192.168.1.20) ── to LAN/internet
 │     ▲  NAT/MASQUERADE (iptables) for outbound container traffic
 │     │                                                        │
 │  ┌──┴─────────────────  docker0 bridge  172.17.0.1 ───────┐ │
 │  │        (virtual switch — a broadcast domain)           │ │
 │  │   veth│           veth│            veth│                │ │
 │  └───────┼───────────────┼────────────────┼───────────────┘ │
 │       eth0│           eth0│            eth0│                  │
 │     ┌─────┴────┐    ┌─────┴────┐     ┌─────┴────┐            │
 │     │ web      │    │ api      │     │ redis    │            │
 │     │172.17.0.2│    │172.17.0.3│     │172.17.0.4│            │
 │     └──────────┘    └──────────┘     └──────────┘            │
 │   (each container = own network namespace)                   │
 └───────────────────────────────────────────────────────────┘
```

- **Container-to-container:** `web` reaches `api` over `docker0` — an L2 hop through the virtual switch. On a **user-defined** bridge network, Docker runs an **embedded DNS server** (at `127.0.0.11`) so `web` can `curl http://api:8080` and the name resolves to `api`'s current IP. (The legacy *default* `bridge` lacks name resolution — you need a user-defined network for DNS-by-name.)
- **Container-to-internet (outbound):** the container's default route points at `docker0` (172.17.0.1); the host then **SNAT/MASQUERADEs** the packet to its own IP as it leaves `eth0` — so many containers share the host's public identity ([14-nat-and-pat.md](14-nat-and-pat.md)).
- **Outside-to-container (inbound):** blocked by default. You must **publish a port**: `-p 8080:80` installs an iptables **DNAT** rule so a connection to the host's `:8080` is rewritten to the container's `:80`.

### The driver menu

| Driver | What it does | Isolation | Use when |
|---|---|---|---|
| **bridge** (default) | Private virtual switch on one host + NAT | High | Single-host apps, local dev |
| **host** | Container shares the host's network namespace directly (no veth, no NAT — container's `:80` *is* the host's `:80`) | None | Max performance, no isolation |
| **none** | No networking at all (only loopback) | Total | Batch jobs needing no network |
| **overlay** | A multi-host network using **VXLAN** ([16-vlans-and-segmentation.md](16-vlans-and-segmentation.md)) to tunnel L2 frames between hosts | High | Swarm/clusters spanning machines |

**Overlay** is the interesting one: it lets containers on *different* hosts share one virtual L2 network. Each host encapsulates the container's frame in a VXLAN packet, ships it across the real network to the peer host, which decapsulates and delivers it. That "flat network spanning machines" idea is exactly what Kubernetes needs — and it's why VXLAN-based CNIs like Flannel exist.

> **✅ Check yourself before Rung 4:** With the default bridge, why can two containers on the *same* host reach each other directly, but a container on host A cannot reach a container on host B by its `172.17.x.x` IP?

---

## 🏷️ Rung 4 — The Vocabulary Map

| Scary term | What it actually is | Which part of the machinery |
|---|---|---|
| **Network namespace** | A process's private network stack | Per-container isolation |
| **`docker0` / bridge** | A virtual L2 switch on the host | Connects containers on one host |
| **veth pair** | A virtual cable: one end in the container, one in the bridge | Links namespace to bridge |
| **Embedded DNS (127.0.0.11)** | Docker's per-network name resolver | Name → current container IP |
| **Port publishing (`-p`)** | An iptables DNAT rule host:port → container:port | Inbound reachability |
| **MASQUERADE / SNAT** | Rewrites container source IP to host IP outbound | Outbound reachability |
| **host driver** | Share the host netns directly | No isolation, no NAT |
| **overlay driver** | Multi-host virtual network via VXLAN | Cross-host container comms |
| **CNM** | Docker's Container Network Model | The plugin architecture |

**Same-kind-of-thing groupings:** *docker0, a user-defined bridge, cni0* are all "virtual switches." *veth pair* is "the virtual cable" in every model. *Embedded DNS, CoreDNS* both do "name → IP for containers/pods."

---

## 🔬 Rung 5 — The Trace

**You run a web container that publishes port 8080 and calls a `redis` container by name on a user-defined network.**

```
$ docker network create appnet                 # user-defined bridge (with DNS)
$ docker run -d --name redis --network appnet redis
$ docker run -d --name web --network appnet -p 8080:80 mywebapp

── Outside client hits the published port ──
Client → host_ip:8080
  │ 1. iptables DNAT (from -p 8080:80): dst rewritten to web's IP:80
  ▼
web container :80  (172.18.0.3)

── web calls redis by NAME ──
web: connect to "redis:6379"
  │ 2. resolver 127.0.0.11 (Docker embedded DNS) → redis = 172.18.0.2
  │ 3. packet leaves web's eth0 → veth → appnet bridge (L2 switch)
  ▼
redis container :6379  (172.18.0.2)

── redis (or web) reaches the internet ──
redis: connect to 1.2.3.4:443
  │ 4. default route → bridge gateway 172.18.0.1
  │ 5. host SNAT/MASQUERADE: src rewritten to host_ip
  ▼
out host eth0 → internet   (the remote server sees the HOST's IP, not the container's)
```

Every hard part — inbound (DNAT), name resolution (embedded DNS), east-west (bridge), outbound (SNAT) — is one of the four mechanisms from Rung 2.

> **✅ Check yourself before Rung 6:** In step 5, what source IP does the remote internet server see — the container's or the host's? Why does that mean the container is "hidden" behind the host?

---

## ⚖️ Rung 6 — The Contrast

**The alternative that Kubernetes chose instead: a flat network where every pod gets a real, routable IP and pods talk directly with NO NAT.**

| Property | Docker bridge (default) | Kubernetes pod network |
|---|---|---|
| Container/pod IP scope | Host-local, NATed | Cluster-wide, routable |
| Cross-host by IP | ❌ needs overlay/publish | ✅ every pod reaches every pod |
| NAT between workloads | ✅ (source hidden) | ❌ (no NAT pod-to-pod) |
| Inbound access | Explicit `-p` per port | Via Services ([25](25-kubernetes-services-kube-proxy.md)) |
| Who wires it | Docker (CNM drivers) | CNI plugins ([24](24-kubernetes-pod-networking-cni.md)) |

**Why Kubernetes rejected the bridge model:** with hundreds of pods across many nodes, per-host NAT and port-publishing becomes a nightmare — you'd track which host:port maps to which pod, and pod-to-pod across nodes wouldn't "just work." Kubernetes demands a **flat** network (every pod directly addressable, no NAT between pods), which is why it uses CNI, not `docker0`.

**When Docker bridge is still perfect:** single-host local development, CI test containers, `docker compose` stacks on one machine. It's simple and it works.

**One-sentence why-this-over-that:** *Docker bridge is a fine per-host model for local/dev; Kubernetes needs a flat, routable, cross-host pod network, so it replaces the bridge with CNI.*

---

## 🧪 Rung 7 — The Prediction Test

### Example 1 — Normal case: resolve a container by name on a user-defined network

> **Prediction:** "If I put two containers on the same user-defined bridge, one can reach the other by container name, BECAUSE Docker's embedded DNS (127.0.0.11) resolves names to their current IPs on that network."

```bash
docker network create appnet
docker run -d --name redis --network appnet redis:7
docker run --rm --network appnet busybox sh -c 'nslookup redis; nc -zv redis 6379'
# Server: 127.0.0.11                 <- Docker's embedded DNS
# Name: redis  Address: 172.18.0.2
# redis (172.18.0.2:6379) open       <- reachable by NAME
```

**Verify:** the name `redis` resolves and port 6379 is open. Now try the same on the *default* bridge (`--network bridge`) — name resolution fails, proving DNS-by-name needs a user-defined network.

### Example 2 — Edge/failure case: an unpublished port is unreachable from outside

> **Prediction:** "If I run a web container WITHOUT `-p`, I cannot reach it from the host's network, BECAUSE inbound is blocked until an explicit DNAT (port publish) rule exists — but I *can* still reach it via its container IP from the bridge."

```bash
docker run -d --name web nginx                 # NOTE: no -p
curl -s -m 3 http://localhost:80 ; echo "exit=$?"
# exit=7    <- connection refused/timeout: nothing published on the host

# But the container is alive and reachable on its bridge IP:
CIP=$(docker inspect -f '{{.NetworkSettings.IPAddress}}' web)
curl -s -o /dev/null -w '%{http_code}\n' http://$CIP:80
# 200       <- works via the container IP directly

# Republish it properly and the host port now works (DNAT installed):
docker rm -f web; docker run -d --name web -p 8080:80 nginx
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080
# 200
```

**Verify:** unpublished → host access fails but container-IP access works; after `-p 8080:80` → `localhost:8080` returns 200. That gap is the DNAT rule appearing.

### Example 3 — Kubernetes-flavored: host networking removes the isolation layer

> **Prediction:** "If I run a pod with `hostNetwork: true`, its container binds directly on the node's IP with no veth/NAT — just like Docker's `--network host` — BECAUSE the container shares the host's network namespace instead of getting its own."

```yaml
# host-net-pod.yaml
apiVersion: v1
kind: Pod
metadata: { name: hostnet-demo }
spec:
  hostNetwork: true
  containers:
  - name: nginx
    image: nginx
    ports: [{ containerPort: 80 }]
```

```bash
kubectl apply -f host-net-pod.yaml
kubectl get pod hostnet-demo -o wide
# the pod's IP equals the NODE's IP (not a pod-CIDR IP) — it shares the node netns
# NAME           IP            NODE
# hostnet-demo   10.0.3.15     ip-10-0-3-15   <- pod IP == node IP
```

**Verify:** the pod IP equals the node IP — no separate pod-network address, because `hostNetwork` skips the CNI/veth just as Docker `--network host` skips `docker0`. (Docker analog: `docker run --network host nginx` — the container's `:80` becomes the host's `:80` directly.)

---

## 🏔 Capstone — Compress It

**One sentence:** Docker gives each container a private network namespace wired to a host virtual switch (`docker0`), so containers reach each other by name over the bridge, reach the internet via NAT, and are reachable from outside only through published ports — a neat per-host model that Kubernetes replaces with a flat, routable pod network.

**Explain it to a beginner in 3 sentences:**
1. Each container is isolated with its own network stack, so Docker plugs them all into a virtual switch on the host and lets them talk to each other there, resolving each other by name.
2. To reach the internet, containers share the host's IP through NAT; to be reached from outside, you must explicitly map a host port to a container port.
3. This works great on one machine, but it doesn't scale to a cluster of many hosts, which is exactly why Kubernetes uses CNI to give every pod a real, routable IP instead.

**Sub-parts mapped to the one idea (private namespace + bridge + NAT + port maps):**
```
Container-to-container  → the bridge (virtual switch) + embedded DNS
Container-to-internet   → SNAT/MASQUERADE to the host IP
Outside-to-container    → explicit -p DNAT rule
host driver             → no namespace of its own (share the host)
overlay driver          → VXLAN to span multiple hosts
```

**Which rung to revisit hands-on:** Rung 7 Example 2 — feeling the difference between "reachable on the container IP" and "reachable on the host port" makes NAT/DNAT concrete.

---

## Related concepts

- [Kubernetes Pod Networking & CNI](24-kubernetes-pod-networking-cni.md) — the flat model that replaces the Docker bridge.
- [Linux Namespaces](../Linux/13-namespaces.md) — the network namespace that *is* a container's isolation.
- [NAT & PAT](14-nat-and-pat.md) — the SNAT (outbound) and DNAT (published ports) behind Docker networking.
- [Network Devices](13-network-devices.md) — `docker0` is a virtual switch/bridge.
- [VLANs & Segmentation](16-vlans-and-segmentation.md) — VXLAN, the overlay driver's tunneling mechanism.
- [MAC Addresses, Switching & ARP](05-mac-addresses-switching-arp.md) — the L2 switching the bridge performs.
