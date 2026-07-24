# 🌐 Networking Foundations for the Retail-Store DevOps Project — The Learning Ladder Edition
### Every networking concept this project stands on — climbed Pain → Idea → Machinery → Hands-on, so you *derive* the packet's path instead of memorizing consoles

> **What this file is:** the complete networking prerequisite layer for the [kalyan-course project](00-INDEX.md) — Docker networks (S02–04), the Terraform VPC + EKS (S06–07), Services/Ingress (S08/11), the AWS data plane & security groups (S14), ExternalDNS (S15–16), load balancers (S11/16/22), CI/CD (S21) and the Istio mesh (S22). Ten concepts, each climbed on the **Learning Ladder** used in [../../Networking/](../../Networking/00-README.md): **🔥 Pain → 💡 One Idea → ⚙️ Machinery → 🏷️ Vocabulary → 🔬 Trace → ⚖️ Contrast → 🧪 Hands-on (predict first!) → 🏔 Capstone.**
>
> **The one rule:** read *up* the ladder. Commands and consoles arrive at Rung 7 only. Before every lab, **say your prediction out loud** — where the packet goes, which device rewrites which field, and why. A wrong prediction is your model repairing itself; chase that.
>
> **Go deeper:** every climb links its full single-concept ladder in [../../Networking/](../../Networking/00-README.md).

---

## 🎯 RUNG 0 — The Setup (for this whole file)

- **What am I learning?** The ten primitives under every cluster action in this course: IP addressing & CIDR, ports & sockets, DNS, HTTP(S), TLS, routing & NAT, security groups, load balancing, container/pod networking, and the Kubernetes service-delivery chain up to the Istio mesh.
- **Why did it land on my desk?** Because the project's every layer is these primitives wearing AWS/K8s costumes: the Terraform VPC is subnet math (S06); "only ui publishes 8888" is port exposure control (S04); `catalog-mysql` → RDS is a DNS alias (S14); the RDS security group referencing the cluster SG is a stateful firewall rule (S14); the ALB Ingress and the Istio 90/10 canary are L7 load balancing (S11/22). When `/topology` shows red, the fix is one of these ten — every time.
- **What do I already know?** You've clicked these consoles. What's likely fuzzy is which header each box rewrites and which question each failure maps to — exactly what this file closes.

### Where each concept bites in this project

| # | Climb | Where the project forces it on you |
|---|---|---|
| 1 | IP addressing, CIDR & subnetting | VPC `10.0.0.0/16`, public `10.0.1.0/24`/`10.0.2.0/24`, private `10.0.11.0/24`/`10.0.12.0/24` (S06–07); VPC CNI pod IPs |
| 2 | Ports & sockets | `containerPort: 8080`, Compose `8888:8080` (S04), `port-forward 7080:8080` (S08), 3306/5432/6379 (S14), Argo CD `8080:443` (S21) |
| 3 | DNS | Compose service names (S04), `catalog-service.default.svc.cluster.local` (S08), ExternalName→RDS (S14), ExternalDNS→Route 53 (S15/16) |
| 4 | HTTP & HTTPS | `/health` probes, `/topology`, REST endpoints (S02–08), ALB 502/504 triage, the `x-canary` header (S22) |
| 5 | TLS & certificates | ACM cert on the ALB (S16), `argocd login --insecure` (S21), Istio STRICT mTLS (S22), chart repos over HTTPS (S12) |
| 6 | Routing, gateways & NAT | IGW vs NAT GW (S06), private nodes pulling ECR images (S07/21), kube-proxy DNAT, docker MASQUERADE |
| 7 | Security groups & NACLs | RDS SG admits *only the cluster SG* (S14), Redis 6379 rule, "connect timeout" troubleshooting rows (S14/19) |
| 8 | Load balancing | ALB Ingress ip-mode (S11), NLB for Istio gateway (S22), target-group health checks, 502 vs 504 |
| 9 | Container & pod networking | Docker bridge + embedded DNS (S04), veth pairs, VPC CNI = real VPC IPs for pods (S07+) |
| 10 | Services → Ingress → mesh | all five Service types the course uses, kube-proxy, EndpointSlices, ALB Ingress (S11), Envoy sidecar + VirtualService canary (S22) |

---
---

# CLIMB 1 — IP Addressing, CIDR & Subnetting: the VPC's Grammar

## 🔥 Rung 1 — The Pain

Machines need unambiguous addresses, and networks need to be *carved into zones* — public-facing vs private — without listing every address individually. Before CIDR, rigid address "classes" wasted millions of addresses; without private ranges, every laptop would need a globally unique IP.

**Where this project makes you feel it (S06–07):** the Terraform VPC project *is* subnet math — VPC `10.0.0.0/16`, public subnets `10.0.1.0/24` + `10.0.2.0/24` (ALB, NAT GW live here), private subnets `10.0.11.0/24` + `10.0.12.0/24` (worker nodes and pods live here). Size them wrong and EKS runs out of pod IPs mid-scale — on EKS the **VPC CNI hands pods real subnet IPs**, so every pod consumes one.

## 💡 Rung 2 — The One Idea

> **An IPv4 address is 32 bits, and a `/N` mask says "the first N bits name the network, the rest name hosts" — so CIDR is just choosing where to cut the bit-string, and a subnet is a smaller cut inside a bigger one.**

## ⚙️ Rung 3 — The Machinery

```
10.0.0.0/16   =  00001010.00000000 | hhhhhhhh.hhhhhhhh     16 network bits → 65,536 addresses
10.0.1.0/24   =  00001010.00000000.00000001 | hhhhhhhh      24 network bits → 256 addresses
                                                             (AWS reserves 5 per subnet → 251 usable)
Same address, three questions:
  is it in my subnet?      compare the first N bits
  is it private?           RFC1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16  ← never routed on internet
  how many hosts fit?      2^(32−N) − 2  (network + broadcast; AWS: −5)
```

- **The mask is a decision boundary, not decoration.** The kernel (and every VPC route table) answers "local or via a gateway?" by masking the destination and comparing — Climb 6 builds on exactly this.
- **The course's layout is a pattern, not an accident:** `/16` VPC → room for many `/24`s; low numbers (`.1`, `.2`) public, teens (`.11`, `.12`) private, one per **Availability Zone** (us-east-1a/1b) because subnets are AZ-scoped — that's why every tier has two.
- **Overlaps are forever:** peering/VPN between VPCs with overlapping CIDRs is impossible — why S06 plans ranges up front. Also reserved: `127.0.0.1` loopback (Climb 2 of the Linux file), `169.254.x.x` link-local (EKS Pod Identity's magic endpoint `169.254.170.23` uses this).
- **EKS twist:** service ClusterIPs come from a *separate, virtual* CIDR (EKS default `172.20.0.0/16` — e.g. cluster DNS at `172.20.0.10`); pod IPs come from your real subnets via the VPC CNI. Two different address spaces answering two different questions.

> **✅ Check yourself:** `10.0.11.57` — inside `10.0.0.0/16`? Inside `10.0.1.0/24`? Which course subnet does it belong to, and is a node with this IP public or private?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| CIDR `/N` | "first N bits = network" | every `cidr_block` in the S06 VPC module |
| subnet | a smaller cut of the VPC range, AZ-scoped | `10.0.1.0/24` public-1a, `10.0.11.0/24` private-1a |
| RFC1918 | the private, non-internet-routable ranges | why the VPC is `10.x`, your home is `192.168.x` |
| network/broadcast (+AWS 5) | unusable addresses per subnet | why a `/24` yields 251 hosts on AWS |
| pod CIDR vs service CIDR | real subnet IPs vs virtual VIP range | VPC CNI pods vs `172.20.0.0/16` ClusterIPs (EKS) |
| link-local `169.254/16` | never-routed, same-link only | Pod Identity agent endpoint, EC2 metadata `169.254.169.254` |
| secondary CIDR | extra range added to a VPC later | the escape hatch when pods exhaust IPs |

## 🔬 Rung 5 — The Trace: Terraform plans the S06 VPC

1. `vpc_cidr = "10.0.0.0/16"` — one decision: 65k addresses, private range, no overlap with your other networks.
2. Public subnets carve `10.0.1.0/24` (1a) and `10.0.2.0/24` (1b) — where things with public IPs (ALB, NAT GW) must sit.
3. Private subnets carve `10.0.11.0/24` (1a) and `10.0.12.0/24` (1b) — nodes; each pod later takes one of these IPs via the VPC CNI.
4. EKS (S07) is told *only the private subnet IDs* for its node group — the subnet choice IS the "workers are not on the internet" security decision.
5. Scale day: 50 pods/node × 20 nodes ≈ 1,000 pod IPs — your two `/24`s (502 usable) run dry; now you know *why* (and what a secondary CIDR fixes).

## ⚖️ Rung 6 — The Contrast

- **CIDR vs the old classes (A/B/C):** classes forced 16M/65k/254 sizes; CIDR cuts anywhere. "Class C" survives only as slang for `/24`.
- **One big subnet vs tiers:** a single `/16` subnet would "work" — but public/private separation (Climb 6's route tables + Climb 7's SGs) is *the* security architecture of the course; subnets are its unit.

## 🧪 Rung 7 — Hands-on

**Lab 1 — do the course's subnet math, then verify with code:**
> **My prediction:** `10.0.0.0/16` holds 65,536 addresses; `10.0.11.0/24` holds 256 (251 usable on AWS); `10.0.11.57` is inside the private-1a subnet but NOT inside `10.0.1.0/24` — because only the first 24 bits are compared.

```bash
python3 - <<'EOF'
import ipaddress as ip
vpc  = ip.ip_network('10.0.0.0/16')
subs = [ip.ip_network(s) for s in ('10.0.1.0/24','10.0.2.0/24','10.0.11.0/24','10.0.12.0/24')]
print(f"VPC {vpc} → {vpc.num_addresses} addresses")
for s in subs:
    print(f"  {s}  hosts={s.num_addresses-2}  (AWS usable={s.num_addresses-5})  inside VPC? {s.subnet_of(vpc)}")
probe = ip.ip_address('10.0.11.57')
for s in subs: print(f"  {probe} in {s}? {probe in s}")
print("overlap check 10.0.1.0/24 vs 10.0.11.0/24:", subs[0].overlaps(subs[2]))
EOF
```
**Verify:** the membership answers match your bit-mask reasoning. Bonus: change the probe to `10.0.2.200` and predict before running.

**Lab 2 — read YOUR machine's addressing like a node:**
> **My prediction:** my interfaces hold an RFC1918 address with a `/N`, loopback holds `127.0.0.1/8`, and docker's bridge owns its own private subnet — because every network attachment carries address+mask, exactly like a VPC subnet.

```bash
ip -br addr                      # each interface: name, state, IP/mask
ip route | head -5               # the masks DOING something (Climb 6 preview)
docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}'   # docker's own "VPC"
python3 -c "import ipaddress;print(ipaddress.ip_address('$(hostname -I | awk '{print $1}')').is_private)"
```
**Verify:** your LAN IP reports `is_private=True` (RFC1918) and docker runs its own `172.17.0.0/16`-style range — a VPC-in-miniature on your laptop, which Climb 9 dissects.

## 🏔 Capstone

> **One sentence:** a `/N` mask cuts 32 bits into network-vs-host, subnets are smaller cuts placed per-AZ, and the course's whole public/private architecture is just choosing which cut things live in.

📚 **Go deeper:** [../../Networking/02-ip-addressing.md](../../Networking/02-ip-addressing.md), [../../Networking/03-subnetting-and-cidr.md](../../Networking/03-subnetting-and-cidr.md), [../../Networking/20-aws-vpc.md](../../Networking/20-aws-vpc.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 1</b> (say it aloud first, then open)</summary>

**Q:** `10.0.11.57` — inside `10.0.0.0/16`? Inside `10.0.1.0/24`? Which course subnet, public or private?

**A:** Compare the network bits:
- **Inside `10.0.0.0/16`?** `/16` = first 16 bits (`10.0`) are the network. `10.0.11.57` starts with `10.0` → **YES**, it's in the VPC.
- **Inside `10.0.1.0/24`?** `/24` = first 24 bits (`10.0.1`) are the network. Our address's third octet is **11**, not 1 → **NO**.
- It belongs to **`10.0.11.0/24`** (third octet 11), which in the course layout is a **private** subnet — the teens (`.11`/`.12`) are private, the low numbers (`.1`/`.2`) are public.

So a node with `10.0.11.57` is a **private worker node**: internal IP only, internet via the NAT Gateway, unreachable inbound. (The Climb 1 Python lab confirms `10.0.11.57 ∈ 10.0.11.0/24` only.)

</details>

---
---

# CLIMB 2 — Ports & Sockets: One IP, Many Services

## 🔥 Rung 1 — The Pain

One machine, one IP — but twenty programs want network traffic. Without a second number to divide the doorway, only one service could exist per host. And without control over *which* ports are exposed *where*, everything is reachable by everyone.

**Where this project makes you feel it:** all five retail services listen on **8080** *inside* their containers, yet coexist on one host because each container has its own network view (Climb 9); Compose publishes **only** `8888:8080` for ui and gives every backend `ports: []` (S04's "deliberate exposure control"); the data plane speaks in ports — MySQL **3306**, PostgreSQL **5432**, Redis **6379** (S14); `kubectl port-forward` maps `7080:8080` (S08) and `8080:443` for Argo CD (S21).

## 💡 Rung 2 — The One Idea

> **A connection is fully named by five values — protocol + source IP:port + destination IP:port — so a port is just the 16-bit suffix that picks *which process* at an IP, and "exposing" a service is deciding who may reach that suffix.**

## ⚙️ Rung 3 — The Machinery

```
                    one node IP: 10.0.11.57
     :22 sshd   :443 https   :8080 ui-container   :10250 kubelet
       ▲            ▲              ▲                  ▲
  ───── the port DE-multiplexes arriving packets to the right SOCKET ─────

server side:  bind(8080) + listen()      → socket in LISTEN   (ss -tlnp shows these)
client side:  connect() from an EPHEMERAL port (32768–60999) → ESTABLISHED pair:
              10.0.11.57:43712  ⇄  10.20.30.40:3306
              └── random, temporary ──┘  └── well-known, fixed ──┘
```

- **Well-known vs ephemeral:** servers *choose* their port (80/443/3306/5432/6379/8080…); clients get a random high one per connection. This asymmetry is why firewall rules name the *server* port only (and why stateless NACLs must open the ephemeral range for replies — Climb 7's trap).
- **Port mapping = translation at a boundary:** Compose `8888:8080` means "host doorway 8888 forwards to container doorway 8080" (mechanically a DNAT rule — Climb 6). K8s repeats the pattern three deep: Service `port` → `targetPort` (container), and NodePort adds a node-level doorway (30000–32767).
- **Only one listener per address:port:** a second bind fails with `EADDRINUSE` — the "port already allocated" Docker error, and why all-services-on-8080 *requires* per-container network namespaces.
- **`ss -tlnp` is the truth:** what is *actually* listening, on which address, owned by which process — the first command of every "connection refused" triage.

> **✅ Check yourself:** in S04, why can your browser reach `localhost:8888` (ui) but not the carts service — and via which two different mechanisms could you still reach carts for debugging? (Hint: `exec` + localhost, or add a temporary publish.)

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| port | 16-bit process-selector at an IP | 8080 apps, 3306/5432/6379 stores (S04/14) |
| socket | kernel object a process opens for net I/O | what `ss` lists; LISTEN vs ESTABLISHED |
| ephemeral port | random client-side port per connection | the return path SGs handle statefully (Climb 7) |
| published port | host→container doorway mapping (DNAT) | `8888:8080` ui-only (S04) |
| `containerPort`/`targetPort`/`port` | container's real port vs Service's front port | every S08 Service manifest |
| NodePort range | 30000–32767 node-level doorways | Service type ladder (S08/11) |
| `EADDRINUSE` | second bind on a taken port | "port is already allocated" (S02) |
| `ss -tlnp` / `nc -zv` | list listeners / probe a port | first commands in every connectivity triage |

## 🔬 Rung 5 — The Trace: checkout talks to Redis (S14)

1. Checkout reads env `..._REDIS_HOST:6379` (Climb 3 resolves the name).
2. Its kernel picks an **ephemeral** source port (say 51844) and sends `SYN` to `<elasticache-ip>:6379`.
3. The Redis node's kernel demultiplexes on **dstPort 6379** → the `redis-server` listening socket accepts.
4. The five-tuple `(tcp, pod-ip:51844, redis-ip:6379)` now names the connection on both ends; replies to 51844 flow back (the SG tracked it — Climb 7).
5. `ss -tn` on either side shows the ESTABLISHED pair; `redis-cli -h $REDIS_HOST -p $REDIS_PORT ping` (the course's verification pod) exercises the same path.

## ⚖️ Rung 6 — The Contrast

- **`ports: []` vs published:** internal-only reachability (compose network / ClusterIP) vs a doorway from outside. The course's rule — publish only the UI, keep data stores internal — is production posture at every layer (Compose → ClusterIP → private subnets).
- **`nc -zv` (L4: does the port answer?) vs `curl` (L7: does the app answer sensibly?):** learn to name which one failed; "refused" = no listener, "timeout" = filtered path (Climb 7), HTTP 5xx = app problem (Climb 4).

## 🧪 Rung 7 — Hands-on

**Lab 1 — listeners, ephemeral ports & EADDRINUSE:**
> **My prediction:** my http server appears in `ss -tlnp` on :8080; a second server on 8080 dies with "address in use"; my curl's connection uses a random high source port — because one LISTEN per address:port, ephemeral for clients.

```bash
python3 -m http.server 8080 >/dev/null 2>&1 &
sleep 1; ss -tlnp | grep 8080                       # the LISTEN socket + owning pid
python3 -m http.server 8080 2>&1 | head -2          # OSError: Address already in use
curl -s localhost:8080 >/dev/null &
ss -tn | grep 8080 | head -3                        # ESTABLISHED pair: high port ⇄ 8080
sysctl net.ipv4.ip_local_port_range                 # where that high port came from
kill %1
```
**Verify:** the ESTABLISHED line shows `127.0.0.1:<random-high>` talking to `127.0.0.1:8080` — the five-tuple, live. That random-high side is what NACLs forget (Climb 7).

**Lab 2 — reproduce the S04 exposure model with containers:**
> **My prediction:** the published container answers on `localhost:8888`; the unpublished one is unreachable from my laptop but reachable from *inside* the network — because publish = host DNAT doorway, and no publish = internal-only.

```bash
docker network create shopnet
docker run -d --name ui    --network shopnet -p 8888:8080 busybox sh -c \
  'mkdir /www && echo "ui ok" > /www/index.html && httpd -f -p 8080 -h /www'
docker run -d --name carts --network shopnet busybox sh -c \
  'mkdir /www && echo "carts internal" > /www/index.html && httpd -f -p 8080 -h /www'
curl -s localhost:8888                                    # ui ok  (published doorway)
curl -s --max-time 2 localhost:8080 || echo "carts NOT published — as designed"
docker run --rm --network shopnet busybox wget -qO- http://carts:8080   # inside: reachable!
docker rm -f ui carts; docker network rm shopnet
```
**Verify:** the same carts:8080 is dead from the host and alive from the network — S04's `ports: []` lesson, and the exact model ClusterIP repeats in S08.

## 🏔 Capstone

> **One sentence:** ports demultiplex one IP into many processes, clients arrive from ephemeral ports, and every exposure decision in this course — `8888:8080`, `ports: []`, targetPort, NodePort — is just placing or withholding a doorway to a listening socket.

📚 **Go deeper:** [../../Networking/04-ports-sockets-multiplexing.md](../../Networking/04-ports-sockets-multiplexing.md), [../../Networking/07-transport-layer-tcp-udp.md](../../Networking/07-transport-layer-tcp-udp.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 2</b> (say it aloud first, then open)</summary>

**Q:** In S04, why can your browser reach `localhost:8888` (ui) but not carts — and which two mechanisms could still reach carts for debugging?

**A:** Only **ui** *publishes* a port (`8888:8080`) — a host-level doorway (a DNAT rule) that lets your browser in. carts has `ports: []` (no published mapping), so it's reachable **only on the internal Docker network**, by other containers — deliberate exposure control, not an omission.

Two ways to still reach carts for debugging:
1. **`docker compose exec` + localhost from inside:** `docker compose exec carts sh` then `curl localhost:8080/...` — you're now inside carts' own network namespace where its port is local. (Or from another container on the same network: `curl http://carts:8080/...` by service name.)
2. **Temporarily publish a port:** add `ports: ["8081:8080"]` to carts, `docker compose up -d --force-recreate carts`, hit `localhost:8081`, then remove it after.

Both prove the port works; only the *doorway* was withheld. This is the same model ClusterIP (internal-only) vs LoadBalancer/Ingress (a doorway) repeats in Kubernetes.

</details>

---
---

# CLIMB 3 — DNS: Names Over Addresses (the Project's Most-Used Primitive)

## 🔥 Rung 1 — The Pain

Addresses change — pods die, RDS endpoints rotate, load balancers get new IPs. Hardcode an IP anywhere and you've built a time bomb. Before DNS, every machine kept a hand-copied `/etc/hosts` of the whole network (the file still exists as a fossil — and still *wins* over DNS, which is both a tool and a trap).

**Where this project makes you feel it — everywhere:** Compose services call each other **by service name** (S04: `carts`, `catalog` — container DNS); K8s gives every Service a name (`catalog-service.default.svc.cluster.local`, S08); the **ExternalName** Service aliases `catalog-mysql` → `mydb3.xxxx.us-east-1.rds.amazonaws.com` so app config never changes (S14); **ExternalDNS** writes your Ingress hostname into **Route 53** automatically (S15/16); the StatefulSet's **headless** Service gives per-pod names (`catalog-mysql-0.catalog-mysql...`, S08); Helm repos and OIDC endpoints are just HTTPS names (S12/21).

## 💡 Rung 2 — The One Idea

> **DNS is a distributed, cached phone book that turns a stable name into the current address at the moment of use — so systems glue themselves together with names, and "who answers, in what order" (`hosts` file → configured resolver → authoritative servers) is the entire debugging surface.**

## ⚙️ Rung 3 — The Machinery

```
app asks: "catalog-mysql?"                            RECORD TYPES you'll actually meet:
  1. /etc/nsswitch.conf: order = files, dns             A     name → IPv4
  2. /etc/hosts: match? DONE (dig never sees it!)       CNAME name → another name (alias)
  3. /etc/resolv.conf → nameserver X + search domains   ALIAS/route53-alias → AWS LB names
  4. resolver X answers from CACHE (TTL) or asks up     NS/SOA delegation & authority
     the tree: root → .com → amazonaws.com → answer     TXT   proofs (ACM validation! S16)

IN A POD: resolv.conf is WRITTEN BY KUBELET:
  nameserver 172.20.0.10        ← CoreDNS's ClusterIP (EKS default; 10.96.0.10 on kubeadm)
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5
  → short name "catalog-service" + search list = catalog-service.default.svc.cluster.local
  → CoreDNS answers Service names from the K8s API; forwards the rest (rds.amazonaws.com) upstream
```

- **Caching with TTLs is why DNS scales — and why changes "take a while":** every resolver on the path may hold the old answer until TTL expiry.
- **The course's name-based glue, one mechanism four ways:** Compose's embedded DNS (127.0.0.11) maps *service name → container IP*; CoreDNS maps *Service name → ClusterIP* (and headless: → pod IPs directly, no VIP — the "don't load-balance my DB writes" tool); **ExternalName is literally a CNAME** served by CoreDNS (`catalog-mysql` → RDS hostname); ExternalDNS is a controller *writing* Route 53 records from Ingress annotations — DNS as reconciled infrastructure.
- **`dig`/`nslookup` bypass `/etc/hosts` and nsswitch** — they ask the nameserver directly. So "dig resolves it but the app can't" (or the reverse) means the *file* layer disagrees with the *server* layer. That asymmetry solves real tickets.

> **✅ Check yourself:** after `terraform destroy` + re-apply of the data plane, the RDS endpoint changed. Why does the catalog app need **zero** config change in the ExternalName design (S14), and which single K8s object gets the new value pasted in?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it actually is | Where in the project |
|---|---|---|
| A / CNAME record | name→IP / name→name alias | Route 53 records ExternalDNS creates (S15/16) |
| resolver / nameserver | the server that answers (and caches) | CoreDNS in-cluster; VPC `.2` resolver; 127.0.0.11 in Docker |
| `/etc/resolv.conf` | "who do I ask + search suffixes" | written by kubelet into every pod |
| search domains + ndots | auto-complete for short names | why `catalog-service` works without the FQDN |
| TTL | cache lifetime of an answer | why DNS changes propagate "slowly" |
| ExternalName Service | CoreDNS-served CNAME to an external host | `catalog-mysql` → RDS (S14) |
| headless Service | name → pod IPs directly (no VIP) | `catalog-mysql-0.catalog-mysql...` (S08) |
| ExternalDNS | controller reconciling Route 53 from Ingress | the `external-dns.alpha...hostname` annotation (S15/16) |
| zone / hosted zone | the DB of records for a domain | your Route 53 hosted zone (S15) |

## 🔬 Rung 5 — The Trace: catalog opens its database connection (S14)

1. Catalog's config says endpoint `catalog-mysql:3306` — a *short name*, by design.
2. glibc consults `nsswitch` → `/etc/hosts` (no match) → `resolv.conf` → asks CoreDNS, search list expands to `catalog-mysql.default.svc.cluster.local`.
3. CoreDNS finds an **ExternalName** Service → answers with a **CNAME**: `mydb3.xxxx.us-east-1.rds.amazonaws.com`.
4. That name isn't cluster-local → CoreDNS forwards to the VPC resolver → Route 53 private resolution → the RDS instance's current **private IP**.
5. Catalog connects to that IP:3306 (Climbs 2/6/7 carry the packet). RDS endpoint changes later? Only the ExternalName's target string changes — the app never knew the IP *or* the real hostname.

## ⚖️ Rung 6 — The Contrast

- **Names vs hardcoded IPs:** the entire course architecture assumes churn (pods, LBs, DBs) — names are the only stable handles. The one place the course pastes *values* (Terraform outputs into values files, S19) it pastes **hostnames**, never IPs.
- **ExternalName vs ConfigMap endpoint (S14 shows both deliberately):** DNS alias = app config never changes, but it's DNS-only (no port/extra keys); ConfigMap = explicit and multi-key (orders needs DB *and* SQS) but must be edited on change. Know the trade, pick per service.
- **When DNS is the wrong tool:** sub-second failover (TTL caches defeat you — that's the load balancer's job, Climb 8).

## 🧪 Rung 7 — Hands-on

**Lab 1 — walk the resolution chain & prove files-beat-DNS:**
> **My prediction:** `getent` (uses the full chain) will honor a fake `/etc/hosts` entry while `dig` (asks the server directly) ignores it — because the hosts file wins in nsswitch, and dig never reads it.

```bash
grep hosts: /etc/nsswitch.conf
cat /etc/resolv.conf                       # who your laptop asks (systemd-resolved: 127.0.0.53)
dig +short github.com                      # server path: the current A answer(s)
dig +short www.github.com                  # a real CNAME → github.com → IPs (ExternalName's mechanic!)

echo "1.2.3.4 mydb3.fake.rds.internal" | sudo tee -a /etc/hosts >/dev/null
getent hosts mydb3.fake.rds.internal       # 1.2.3.4  ← files layer answered
dig +short mydb3.fake.rds.internal         # (empty)  ← server layer never heard of it
sudo sed -i '/mydb3.fake.rds.internal/d' /etc/hosts   # cleanup
```
**Verify:** `getent` and `dig` disagreeing on the SAME name is the signature of a hosts-file override — and `www.github.com`'s CNAME hop is exactly what an ExternalName Service serves inside the cluster.

**Lab 2 — container DNS: why Compose services find each other by name (S04's secret):**
> **My prediction:** on a user-defined network, one container resolves another *by container name* via Docker's embedded resolver at 127.0.0.11; on the default bridge, name resolution fails — because the embedded DNS is a user-defined-network feature.

```bash
docker network create shopnet
docker run -d --name catalog --network shopnet busybox sleep 300
docker run --rm --network shopnet busybox sh -c \
  'cat /etc/resolv.conf; nslookup catalog 2>&1 | tail -2; ping -c1 -W1 catalog >/dev/null && echo "reached catalog by NAME"'
docker run --rm busybox sh -c 'ping -c1 -W1 catalog >/dev/null 2>&1 || echo "default bridge: name NOT resolvable"'
docker rm -f catalog; docker network rm shopnet
```
**Verify:** `resolv.conf` inside shows `127.0.0.11` (Docker's resolver) and the name resolves — this is precisely why the S04 compose file contains zero IP addresses, and the same pattern CoreDNS scales up to `*.svc.cluster.local`.

## 🏔 Capstone

> **One sentence:** DNS turns stable names into current addresses through a cached hosts-file→resolver→authority chain — and Compose names, Service names, ExternalName's CNAME-to-RDS, headless per-pod names, and ExternalDNS's Route 53 records are one mechanism at five scales.

📚 **Go deeper:** [../../Networking/09-dns.md](../../Networking/09-dns.md), [../../Networking/26-kubernetes-dns-service-discovery.md](../../Networking/26-kubernetes-dns-service-discovery.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 3</b> (say it aloud first, then open)</summary>

**Q:** After destroy + re-apply, the RDS endpoint changed. Why does the catalog app need **zero** config change in the ExternalName design, and which single object gets the new value?

**A:** The app is configured to talk to the **stable in-cluster name** `catalog-mysql` (e.g. `catalog-mysql:3306` in its ConfigMap) — **not** the raw RDS hostname or IP. `catalog-mysql` is an **ExternalName Service**: a CoreDNS-served CNAME that aliases to the real RDS endpoint. When RDS's endpoint changes, the app's config still says `catalog-mysql` (unchanged), because the app never knew the real hostname — it only ever resolved the alias.

The **single object** that gets the new value pasted in is the **ExternalName Service** — its `spec.externalName` field → the new `mydbXXXX.….rds.amazonaws.com`. One edit, one object; every app that dials `catalog-mysql` transparently follows. That's the payoff of "names over addresses": the indirection absorbs the churn.

</details>

---
---

# CLIMB 4 — HTTP & HTTPS: the Protocol Every Microservice Speaks

## 🔥 Rung 1 — The Pain

Once bytes can reach a socket (Climbs 1–3), both sides still need a *shared grammar* for "get me this resource / here's my data / here's what went wrong." Without one, every pair of services invents its own — and no generic component (ALB, Ingress, Envoy, probes) could ever route or health-check anything.

**Where this project makes you feel it:** every retail service is a REST API — `GET /health`, `/topology`, `/catalog/products` (S02/08); Compose healthchecks run `curl -f http://localhost:8080/actuator/health` (S04); K8s liveness/readiness probes are HTTP GETs (S08); the ALB routes and health-checks by path (S11); Argo CD polls a Git HTTPS API (S21); the Istio canary matches an HTTP **header** `x-canary: true` (S22) — only possible because the proxy *understands* HTTP.

## 💡 Rung 2 — The One Idea

> **HTTP is a stateless request/response text protocol — method + path + headers (+ body) in, status code + headers + body out — and because every hop can read it, the whole delivery chain (probes, ALBs, Ingress, Envoy) makes decisions on methods, paths, headers, and codes.**

## ⚙️ Rung 3 — The Machinery

```
REQUEST                                    RESPONSE
GET /catalog/products HTTP/1.1             HTTP/1.1 200 OK
Host: retail-store.example.com  ◄─ routing │ Content-Type: application/json
x-canary: true                  ◄─ Istio   │ {"products":[...]}
(then: body for POST/PUT)                  └─ status code = the machine-readable verdict

STATUS CODES AS TRIAGE MAP (memorize the *classes*):
2xx OK        4xx = CLIENT's fault           5xx = SERVER side's fault
200 ok        401/403 auth/authz             500 app crashed handling it
201 created   404 no such path               502 proxy reached NO healthy backend
              429 rate-limited               503 unavailable (probes failing?)
                                             504 backend too SLOW (timeout)
502 vs 504 at the ALB: "couldn't connect/bad response" vs "connected but it never answered in time"
```

- **Statelessness is why replicas work:** any pod can answer any request (session state moved to Redis, S14 — a *direct architectural consequence*). Cookies/tokens re-add identity on top.
- **`Host:` header = one LB, many sites:** the ALB and the Istio Gateway route on it (S16/22 hostnames).
- **Health checks are just tiny HTTP:** `curl -f` exits non-zero on ≥400 — that exit code (Linux Climb 5!) is the healthcheck verdict; K8s probes and ALB target-group checks are the same GET-and-judge loop, built in.
- **HTTPS = HTTP inside a TLS tunnel (Climb 5):** same grammar, encrypted transport; the ALB "terminates" TLS then speaks plain HTTP to pods.

> **✅ Check yourself:** `/topology` shows checkout red; `curl` from the ui pod to checkout returns 500, but the ALB shows the site fine otherwise. Which layer is broken — connectivity, the checkout app, or its dependency — and which status class told you?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| method (GET/POST/PUT/DELETE) | the verb | REST CRUD on carts/orders (S02+) |
| path | the resource | `/health`, `/topology`, `/catalog/products` |
| header | key:value metadata | `Host:` routing, `x-canary` (S22), auth tokens |
| status code class | machine-readable verdict | probe pass/fail, ALB 502/504 triage |
| `curl -f` / `-v` / `-I` | fail-on-4xx+ / show anatomy / headers-only | Compose healthchecks (S04), all debugging |
| stateless + external session | no per-connection memory | why checkout's session lives in Redis (S14) |
| endpoint / REST API | path-shaped contract | every microservice boundary in the store |
| keep-alive / HTTP2 | connection reuse / multiplexing | why LBs pool backend connections |

## 🔬 Rung 5 — The Trace: the Compose healthcheck gates the UI (S04)

1. Docker runs carts' healthcheck: `curl -f http://localhost:8080/actuator/health` inside the container.
2. curl resolves localhost, connects to :8080 (Climbs 2–3), sends `GET /actuator/health`.
3. Spring answers `200` + JSON → curl exits 0 → Docker marks carts **healthy**.
4. The `depends_on: {carts: {condition: service_healthy}}` gate opens → Docker now starts ui.
5. Sabotage the path to `/wrong` (the course's Lab C) → `404` → curl exits 22 → carts stays unhealthy → **ui never starts**. One status code held the whole stack's startup order.

## ⚖️ Rung 6 — The Contrast

- **HTTP (universal, inspectable, cacheable) vs raw TCP protocols (MySQL 3306, Redis 6379):** the data plane speaks binary protocols — which is *why* the ALB can't route them and they get Services/SGs instead of Ingress paths (S14).
- **REST vs gRPC:** gRPC (HTTP/2 + protobuf) is faster for service-to-service but needs L7 infra that understands it (Envoy does; classic ALB is happier with REST). The store choosing REST keeps every hop debuggable with curl.

## 🧪 Rung 7 — Hands-on

**Lab 1 — dissect requests and status codes with a live server:**
> **My prediction:** `curl -v` shows my exact request lines and the server's status line; a missing file returns 404; `curl -f` converts ≥400 into a non-zero *exit code* — the healthcheck mechanism.

```bash
cd $(mktemp -d) && echo '{"status":"UP"}' > health && python3 -m http.server 8080 >/dev/null 2>&1 &
sleep 1
curl -v http://localhost:8080/health 2>&1 | grep -E '^(>|<)'    # the raw grammar, both directions
curl -s -o /dev/null -w 'code=%{http_code}\n' http://localhost:8080/health   # 200
curl -s -o /dev/null -w 'code=%{http_code}\n' http://localhost:8080/nope     # 404
curl -f -s http://localhost:8080/nope; echo "curl exit=$?"                    # 22 ← probe verdict!
rm health; curl -f -s http://localhost:8080/health; echo "after delete: exit=$?"
kill %1
```
**Verify:** deleting `health` flipped the exit code — you just ran a liveness probe by hand. Map: Compose `test:` line, K8s `httpGet` probe, ALB health check = this loop, automated.

**Lab 2 — headers steer behavior (the `x-canary` warm-up for S22):**
> **My prediction:** the server sees any header I send; `-H "Host: shop.example.com"` changes what a name-based router would pick; requests are stateless unless I carry state myself — because each request stands alone with its headers.

```bash
python3 - <<'EOF' >/dev/null 2>&1 &
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        pool = "v2-canary" if self.headers.get("x-canary")=="true" else "v1-stable"
        host = self.headers.get("Host","-")
        self.send_response(200); self.end_headers()
        self.wfile.write(f"routed-to={pool} host={host}\n".encode())
    def log_message(self,*a): pass
HTTPServer(("127.0.0.1",8080),H).serve_forever()
EOF
sleep 1
curl -s localhost:8080/                          # routed-to=v1-stable
curl -s -H "x-canary: true" localhost:8080/      # routed-to=v2-canary  ← S22's tester pin!
curl -s -H "Host: shop.example.com" localhost:8080/
kill %1
```
**Verify:** one header flipped the routing decision — precisely what the Istio VirtualService's `match: headers: x-canary: exact "true"` does at the mesh layer (S22 §6.5), and what `Host:` does for every name-routed LB.

## 🏔 Capstone

> **One sentence:** HTTP's method+path+headers→status-code grammar is readable by every hop, which is why probes, healthcheck gates, ALB path routing, 502/504 triage, and header-pinned canaries are all the same skill: reading the request and the verdict.

📚 **Go deeper:** [../../Networking/10-http-and-https.md](../../Networking/10-http-and-https.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 4</b> (say it aloud first, then open)</summary>

**Q:** `/topology` shows checkout red; `curl` ui→checkout returns 500, but the ALB shows the site fine. Which layer is broken, and which status class told you?

**A:** The **5xx class (server-side)** is the tell. A 500 means the request **reached checkout and it failed while handling it** — so connectivity, DNS, port, and the checkout process are all working. Contrast:
- a **timeout / connection refused** would point at connectivity or the process being down (Climb 7),
- a **4xx** would blame the caller (bad request/auth).

A 5xx puts the fault in **checkout itself or, more likely (since everything else is fine), checkout's own downstream dependency** — its Redis/ElastiCache, or a bad config like a wrong endpoint. The ALB shows the *site* fine because it fronts the healthy ui; the failure is one hop deeper (ui → checkout → its store). Next step: read checkout's logs. The status class alone localized it to "checkout or what checkout depends on" — not connectivity, not the ui/ALB.

</details>

---
---

# CLIMB 5 — TLS, Certificates & mTLS: Trust on the Wire

## 🔥 Rung 1 — The Pain

Plain HTTP crosses networks readable and forgeable by every middlebox — passwords, sessions, everything. And encryption alone isn't enough: you must know you're encrypting *to the right party*, or you've built a private line to an impostor.

**Where this project makes you feel it:** the ALB serves HTTPS with an **ACM** certificate, DNS-validated via a TXT/CNAME record (S16); `argocd login localhost:8080 --insecure` and `curl -k` exist because Argo CD ships a **self-signed** cert (S21 — you consciously skip verification, and should be able to say why that's OK on localhost and not in prod); Helm repos, ECR pushes, OIDC token exchange — all TLS (S12/21); and S22's **STRICT mTLS** makes *both* sides prove identity by certificate — the mesh's zero-trust core ("a NetworkPolicy knows spoofable IPs; mTLS knows cryptographic identity").

## 💡 Rung 2 — The One Idea

> **TLS wraps a socket in encryption whose keys are negotiated fresh per session, and certificates make it trustworthy: a server proves "a CA you already trust vouches that this key belongs to this name" — mTLS just makes the client prove the same thing back.**

## ⚙️ Rung 3 — The Machinery

```
THE HANDSHAKE (simplified):                       THE CHAIN OF TRUST:
client ── ClientHello (+SNI: which name?) ──▶     leaf cert: CN=retail-store.example.com
       ◀─ cert CHAIN + key exchange ──────        signed by ▲ intermediate CA
verify: name matches? not expired?                 signed by ▲ root CA  ← lives in YOUR trust store
        chain ends in MY trust store?              (browser/OS/container image ships these)
       ── encrypted session keys agreed ──▶
       ══ everything after is encrypted ══        FAIL any check → "certificate verify failed"
                                                   -k / --insecure = "skip the checks" (know when!)

mTLS (S22): the SAME dance BOTH directions — istiod acts as the mesh CA, issues each pod's
Envoy a short-lived cert encoding its ServiceAccount → AuthorizationPolicy matches that identity.
```

- **Termination points are architecture:** the ALB *terminates* TLS (browser⇄ALB encrypted; ALB⇄pod plain HTTP inside the VPC) — S16's design. Istio moves encryption *inside*: pod⇄pod is mTLS via sidecars, closing the "plain inside" gap without touching app code.
- **Certificates expire** — the classic "nothing changed but everything broke." ACM's job is auto-renewal; the *validation record* in Route 53 is how ACM proves you own the name (S16's DNS-validation step).
- **SNI:** the client names its target host *inside* the ClientHello so one IP/LB can serve many certs — how the ALB picks the right cert.

> **✅ Check yourself:** why is `--insecure` acceptable for `argocd login localhost:8080` (port-forward to a self-signed service) but `-k` against your production ALB would be malpractice? Name the exact check you're disabling and who could exploit it.

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| certificate (leaf) | signed statement: this key ↔ this name | the ACM cert on the ALB (S16) |
| CA / chain / root store | the vouching hierarchy + your trusted roots | why curl trusts amazonaws.com out of the box |
| self-signed | cert vouched for by itself | Argo CD's default (S21) → `--insecure` |
| SNI | "which hostname I want" in the hello | one ALB, many certs |
| ACM + DNS validation | AWS-managed cert, ownership proven via Route 53 record | S16's cert issuance flow |
| termination | where TLS ends and plain begins | ALB (S16) vs mesh sidecars (S22) |
| mTLS | both sides present certs | Istio STRICT PeerAuthentication (S22) |
| expiry / rotation | certs are time-bombs by design | ACM auto-renew; istiod's short-lived workload certs |

## 🔬 Rung 5 — The Trace: browser → `https://retail-store.<domain>` (S16)

1. DNS (Climb 3) resolves the name — the Route 53 record ExternalDNS wrote — to the ALB.
2. TCP to :443 (Climb 2), then ClientHello with SNI `retail-store.<domain>`.
3. ALB presents the ACM chain; browser verifies name+dates+chain-to-trusted-root → green lock.
4. Encrypted session established; the HTTP request (Climb 4) travels inside it.
5. ALB decrypts, forwards plain HTTP to the ui pod's IP:8080 (ip-mode target, Climb 8). With S22 in place, that inner hop upgrades to mTLS between Envoys — encryption edge-to-pod-to-pod.

## ⚖️ Rung 6 — The Contrast

- **TLS (encrypt + authenticate server) vs mTLS (authenticate both):** browsers can't manage client certs at scale, so the edge uses TLS+login; machines *can*, so the mesh uses mTLS+AuthorizationPolicy. Different trust problems, same machinery.
- **mTLS vs NetworkPolicy (S22's argument):** IP-based allow-lists break under IP churn/spoofing; certificate identity survives rescheduling — the compliance answer the course's capstone leans on.

## 🧪 Rung 7 — Hands-on

**Lab 1 — read a real chain like an SRE (expiry is the #1 outage):**
> **My prediction:** `openssl s_client` shows a leaf for `github.com` chaining to a root my system already trusts, with dates I can check — because verification is name+time+chain, nothing more mystical.

```bash
echo | openssl s_client -connect github.com:443 -servername github.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
echo | openssl s_client -connect github.com:443 -servername github.com 2>/dev/null \
  | grep -E 'Verify return code|depth'
curl -sv https://github.com 2>&1 | grep -iE 'SSL|subject|issuer|expire' | head -5
```
**Verify:** `Verify return code: 0 (ok)` + sane `notAfter` date = all three checks passing. Habit to build: when anything TLS "suddenly" fails, check `-dates` *first*.

**Lab 2 — build the Argo CD situation: self-signed server, `-k`, then proper trust:**
> **My prediction:** curl refuses my self-signed server (unknown chain), `-k` bypasses it (encryption WITHOUT authentication), and `--cacert` restores full verification — because trust is just "does the chain end in a store I hold?"

```bash
cd $(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
openssl s_server -accept 8443 -cert cert.pem -key key.pem -www >/dev/null 2>&1 &
sleep 1
curl -s https://localhost:8443 >/dev/null || echo "REFUSED: self-signed (the Argo CD default)"
curl -sk https://localhost:8443 | head -1 && echo "-k: encrypted but UNAUTHENTICATED"
curl -s --cacert cert.pem https://localhost:8443 | head -1 && echo "--cacert: fully verified"
kill %1
```
**Verify:** three outcomes, one server — the difference was purely *whose trust store*. `--insecure` in S21 is the middle case, on localhost, for a service you port-forwarded yourself: acceptable. The same flag against a real domain hands the session to any interceptor.

## 🏔 Capstone

> **One sentence:** TLS is per-session encryption made trustworthy by certificate chains ending in a store you hold — the ALB terminates it at the edge with ACM, Argo CD's self-signed cert is why `--insecure` exists, and Istio's mTLS runs the same handshake both ways to give pods cryptographic identity.

📚 **Go deeper:** [../../Networking/11-tls-ssl-encryption-in-transit.md](../../Networking/11-tls-ssl-encryption-in-transit.md), [../../Linux/26-tls-pki-openssl.md](../../Linux/26-tls-pki-openssl.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 5</b> (say it aloud first, then open)</summary>

**Q:** Why is `--insecure` acceptable for `argocd login localhost:8080` (self-signed, port-forward) but `-k` against a production ALB is malpractice? Name the exact check disabled and who could exploit it.

**A:** `--insecure`/`-k` disables **server-certificate verification** — the checks that the presented cert (a) chains to a trusted CA and (b) matches the hostname (and isn't expired). It does **not** disable encryption; the channel is still TLS-encrypted — just **encrypted to an unverified party**.

- **`argocd login localhost:8080`:** you're talking to a **self-signed** service *you* port-forwarded, over loopback — the traffic never leaves your machine, so there's no third party in the path to impersonate the server. Skipping verification is fine: there's literally no one to MITM you on localhost.
- **`-k` against a production ALB over the internet:** you'd accept **any** cert any interceptor presents. An on-path attacker (rogue Wi-Fi, compromised router, DNS/BGP hijack, malicious proxy) presents their own cert, you "securely" connect to **them**, and they read/modify everything — a man-in-the-middle. The exploiter is anyone who can sit on the network path between you and the real server, which on the public internet is a large, real set.

Encryption without authentication is a private line to a stranger. That's why the mesh (Climb 5's mTLS) authenticates *both* ends by cert.

</details>

---
---

# CLIMB 6 — Routing, Gateways & NAT: How Private Things Reach the World

## 🔥 Rung 1 — The Pain

Two problems, one pair of answers. First: a packet leaving a machine must pick a next hop *without* the app knowing topology. Second: RFC1918 addresses (your whole VPC, Climb 1) are unroutable on the internet — yet private nodes must pull images and call AWS APIs. Without routing tables and NAT, "private subnet" would mean "isolated subnet."

**Where this project makes you feel it (S06–07):** the VPC has an **Internet Gateway**; public subnets' route table sends `0.0.0.0/0 → IGW`; private subnets send `0.0.0.0/0 → NAT Gateway` (which sits *in a public subnet*); that is the ONLY reason your private EKS nodes can pull from ECR and reach S3/Secrets Manager (S07/13/21). Meanwhile kube-proxy's ClusterIP magic is the *other* NAT direction (DNAT), and the NAT-GW hourly cost is the "destroy after every session" villain of the cost warnings.

## 💡 Rung 2 — The One Idea

> **Every hop answers "where next?" by longest-prefix-match in a route table, and NAT is a hop that additionally *rewrites addresses* — SNAT hides many private sources behind one public IP (NAT GW), DNAT swaps a public/virtual destination for a real private one (LBs, ClusterIPs).**

## ⚙️ Rung 3 — The Machinery

```
THE COURSE VPC'S TWO ROUTE TABLES:
public subnets (10.0.1/24, 10.0.2/24):    private subnets (10.0.11/24, 10.0.12/24):
  10.0.0.0/16 → local                        10.0.0.0/16 → local
  0.0.0.0/0   → igw-xxxx                     0.0.0.0/0   → nat-xxxx   ← lives in a PUBLIC subnet

SNAT AT THE NAT GW (node 10.0.11.57 pulls an ECR layer):
  out:  src 10.0.11.57 ──▶ NAT GW rewrites ──▶ src 52.1.2.3 (its Elastic IP), REMEMBERS the flow
  back: dst 52.1.2.3   ──▶ NAT GW un-rewrites ──▶ dst 10.0.11.57
  ⇒ outbound-only: the internet can never INITIATE inward (no mapping exists) — that's the security.

DNAT (the mirror image): ALB/NodePort/ClusterIP take traffic aimed at a front address
  dst 172.20.44.7:80 (ClusterIP) ──▶ kube-proxy's iptables rewrite ──▶ dst 10.0.11.213:8080 (a pod)
```

- **Longest prefix wins:** `10.0.0.0/16 local` beats `0.0.0.0/0` for VPC-internal traffic — so east-west never touches the NAT GW.
- **Your laptop runs the identical stack:** `ip route` shows `default via <home-router>`; Docker MASQUERADEs container traffic out your WiFi IP — a NAT gateway in miniature you can *read* (Lab 2).
- **Two NAT directions, one table:** SNAT = source rewritten on egress (NAT GW, Docker); DNAT = destination rewritten on ingress (published ports, Service VIPs). Every "how did that packet get there?" is one of these two.

> **✅ Check yourself:** why must the NAT Gateway sit in a *public* subnet, and what breaks (exactly which route) if you place it in a private one? Then: which rewrite — S or D — is `-p 8888:8080`?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| route table | per-subnet "destination→target" rules | the S06 public/private tables |
| longest-prefix match | most specific route wins | `local` beats default for VPC traffic |
| IGW | the VPC's door to the internet (1:1, both ways) | public subnets' 0.0.0.0/0 target |
| NAT Gateway | managed SNAT box with an Elastic IP | private nodes' egress; the cost-warning star |
| SNAT / MASQUERADE | rewrite source on the way out | NAT GW; Docker's POSTROUTING rule |
| DNAT | rewrite destination on the way in | published ports, NodePort, ClusterIP→pod |
| default route `0.0.0.0/0` | "everything else" | both route tables' last line |
| conntrack | the flow memory making rewrites reversible | how replies find their way back (Climb 7 too) |

## 🔬 Rung 5 — The Trace: a private node pulls the ui image from ECR (S21's deploy moment)

1. Kubelet on `10.0.11.57` needs `123...dkr.ecr.us-east-1.amazonaws.com/retail-store/ui:sha-1a2b3c4`; DNS (Climb 3) → a public ECR IP.
2. Node's routing: not `10.0.0.0/16` → falls to `0.0.0.0/0 → NAT GW`.
3. NAT GW (public subnet) SNATs src `10.0.11.57` → its Elastic IP, notes the flow, forwards via the IGW.
4. ECR's response returns to the Elastic IP; conntrack maps it back to `10.0.11.57`; TLS (Climb 5) verifies it's really ECR; layers download.
5. Nobody on the internet could have *started* a connection to `10.0.11.57` — no route, no mapping, no public IP. Private-but-not-isolated, achieved.

## ⚖️ Rung 6 — The Contrast

- **NAT GW egress vs public nodes:** giving nodes public IPs also "works" and saves NAT cost — and exposes every node to the internet directly; the course's private-nodes design is the production default (S07: "wiring EKS *wrong* produces public workers").
- **NAT vs VPC endpoints:** for heavy S3/ECR traffic, PrivateLink/gateway endpoints skip the NAT (cheaper, private-er) — the optimization to name in interviews when asked "how do you reduce NAT GW cost?"

## 🧪 Rung 7 — Hands-on

**Lab 1 — read your routing table and predict the exit:**
> **My prediction:** `ip route get` to an internet IP names my default gateway and WiFi interface; to a docker container it names `docker0`; because longest-prefix match picks per-destination.

```bash
ip route                                   # your table: default via ... + specific subnets
ip route get 8.8.8.8                       # → via <gw> dev <wifi/eth>  (the "IGW/NAT" path)
docker run -d --name r busybox sleep 120 >/dev/null
CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' r)
ip route get "$CIP"                        # → dev docker0 (the "local route" — no gateway!)
docker rm -f r >/dev/null
```
**Verify:** two destinations, two different exits, zero app involvement — the same two-line logic as the VPC route tables (`local` vs `0.0.0.0/0`).

**Lab 2 — find your laptop's NAT Gateway (Docker's MASQUERADE) and a real DNAT:**
> **My prediction:** iptables' nat table holds (a) a MASQUERADE rule SNATing container traffic — my personal NAT GW — and (b) after I publish a port, a DNAT rule rewriting host:8888 → container:8080 — because both cloud boxes are these two rules at scale.

```bash
sudo iptables -t nat -L POSTROUTING -n | grep -i masq        # SNAT: containers → world
docker run -d --name ui -p 8888:8080 busybox sh -c \
  'mkdir /www && echo hi > /www/index.html && httpd -f -p 8080 -h /www'
sudo iptables -t nat -L DOCKER -n | grep 8888                # DNAT: :8888 → <container-ip>:8080
curl -s localhost:8888                                       # ride the DNAT yourself
sudo conntrack -L 2>/dev/null | grep 8080 | head -2 || sudo cat /proc/net/nf_conntrack 2>/dev/null | grep 8080 | head -2
docker rm -f ui >/dev/null
```
**Verify:** MASQUERADE = the NAT Gateway's job; the DOCKER-chain DNAT = the published port/NodePort/ClusterIP job; conntrack (if shown) = the flow memory that reverses both. You've now *read* the mechanisms AWS sells as boxes.

## 🏔 Capstone

> **One sentence:** route tables pick the next hop by longest prefix, SNAT (NAT GW/MASQUERADE) lets private sources out without letting anyone in, and DNAT (published ports, Service VIPs) swaps front addresses for real backends — the VPC's whole public/private design is those three moves.

📚 **Go deeper:** [../../Networking/08-routing-and-forwarding.md](../../Networking/08-routing-and-forwarding.md), [../../Networking/14-nat-and-pat.md](../../Networking/14-nat-and-pat.md), [../../Networking/20-aws-vpc.md](../../Networking/20-aws-vpc.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 6</b> (say it aloud first, then open)</summary>

**Q:** Why must the NAT Gateway sit in a *public* subnet, and which route breaks if you put it in a private one? Then: which rewrite — S or D — is `-p 8888:8080`?

**A:** The NAT GW's job is to give private instances **outbound internet** by SNAT-ing their traffic out and receiving replies. To reach the internet *itself*, the NAT GW needs a path to the **Internet Gateway** — and only a **public subnet's route table** has `0.0.0.0/0 → IGW`. So it lives in a public subnet (with an Elastic IP) precisely so its own egress goes out the IGW.

Put it in a **private** subnet and that subnet's default route is `0.0.0.0/0 → the NAT GW` (itself) — so the NAT GW would have **no route to the internet**; the broken route is its own `0.0.0.0/0`, which now loops back instead of reaching the IGW. Private instances' egress dies.

Second part: `-p 8888:8080` rewrites the **destination** (host:8888 → container:8080 on the way in) → it's **DNAT**. (SNAT = the NAT GW's outbound *source* rewrite; DNAT = inbound published-port / Service-VIP *destination* rewrite.)

</details>

---
---

# CLIMB 7 — Firewalls: Security Groups & NACLs

## 🔥 Rung 1 — The Pain

Reachability without *policy* means every open port is open to everyone. You need "who may talk to whom, on which port" enforced *outside* the apps — and you need it to survive the fact that clients reply from random ephemeral ports (Climb 2).

**Where this project makes you feel it (S14, constantly):** the RDS MySQL SG allows 3306 **only from the EKS cluster's security group** — not a CIDR, a *group reference*; Redis 6379 and PostgreSQL 5432 repeat the pattern; "plain Redis has no AWS auth — **the security group IS the auth boundary**" (S14 §6.4); half the troubleshooting tables' "connect timeout" rows end in "fix the SG source." Compose's `ports: []` and S22's deny-all AuthorizationPolicy are the same *idea* at other layers.

## 💡 Rung 2 — The One Idea

> **A firewall is a per-packet allow/deny decision; a *stateful* one (security groups) remembers each connection it allowed and auto-admits its replies, while a *stateless* one (NACLs) evaluates every packet — including replies on ephemeral ports — from scratch.**

## ⚙️ Rung 3 — The Machinery

```
TWO AWS LAYERS, ONE PACKET:                     THE S14 PATTERN (SG references SG):
subnet boundary: NACL  (stateless, ordered      ┌──────────────────────────────────────┐
                 rules, explicit allow AND      │ rds-mysql-sg:                        │
                 the return-traffic rules!)     │   ingress 3306 from sg-eks-cluster   │
ENI/instance:    Security Group (stateful,      │   (NOT from 10.0.0.0/16!)            │
                 allow-only, all rules          └──────────────────────────────────────┘
                 evaluated, replies free)       WHY: pods/nodes churn IPs constantly —
                                                but they always CARRY the cluster SG.
checkout → redis:6379:
  SG check at redis ENI: source carries sg-eks-cluster? → allow + conntrack the flow
  reply redis → checkout:51844 (ephemeral): stateful → automatically allowed, no rule needed
  a NACL doing this needs: outbound 6379 AND inbound 1024–65535 — forget the second, mystery hangs
```

- **Group-reference > CIDR is the cloud-native move:** membership (which ENIs carry the SG) *is* the identity; IPs can churn freely. This is the closest AWS-native thing to "identity-based" policy before Istio's cert identities (S22).
- **The failure signatures differ (memorize):** **"connection refused"** = reached the host, nothing listening (SG passed! check the app/port — Climb 2); **"connection timed out"** = packets silently *dropped* — SG/NACL/route problem. The course's troubleshooting tables are built on this split.
- **Default posture:** SGs deny all ingress until you allow; NACLs default-allow (until someone "hardens" them and breaks ephemeral replies). SGs can't *block* a specific IP (no deny rules) — that's a NACL job.

> **✅ Check yourself:** catalog crash-loops with `dial tcp ...:3306: i/o timeout` (S14's exact symptom). Timeout, not refused — which three suspects does that word alone eliminate, and which one does the course's fix ("SG source = EKS cluster SG") confirm?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| security group | stateful, allow-only, per-ENI | every RDS/Redis/EKS SG in S06–14 |
| NACL | stateless, ordered, per-subnet, allow+deny | the default-allow layer you rarely touch — until you do |
| stateful | replies of allowed flows auto-admitted | why no "egress 51844" rule exists anywhere |
| SG-references-SG | source = group membership, not IPs | `security_groups = [eks_cluster_sg_id]` (S14 §6.2) |
| conntrack | the kernel/hypervisor flow-memory | the machinery behind "stateful" |
| refused vs timeout | listener problem vs filter/route problem | the S14/S19 troubleshooting split |
| defense in depth | SG + NACL + NetworkPolicy + mTLS stacked | the course's full posture by S22 |

## 🔬 Rung 5 — The Trace: the catalog pod's first query to RDS (S14, healthy path)

1. Packet leaves the pod for `<rds-ip>:3306` (Climbs 2–3 named it, Climb 6 routes it — `local`, so no NAT).
2. Subnet NACLs: default-allow both directions → pass.
3. RDS ENI's SG: ingress rule "3306 from sg-eks-cluster" — the packet's source ENI (the node/pod ENI) carries that SG → **allow**, flow recorded.
4. MySQL answers; reply to the pod's ephemeral port sails through statefully (no rule consulted).
5. Break it the course's way (Lab C: change source to your laptop's CIDR) → step 3 silently drops → the app logs `i/o timeout` → you now *derive* the fix instead of pattern-matching it.

## ⚖️ Rung 6 — The Contrast

- **SG (identity-ish, stateful, can't deny) vs NACL (positional, stateless, can deny):** use SGs for 99% of policy; NACLs for subnet-wide blocklists and compliance edges.
- **SGs vs K8s NetworkPolicy vs Istio AuthorizationPolicy:** node/ENI layer vs pod-selector layer vs cryptographic-identity layer (S22's argument for the mesh) — stack them, don't pick one.

## 🧪 Rung 7 — Hands-on

**Lab 1 — feel "refused" vs "timeout" (the triage split that solves S14 tickets):**
> **My prediction:** probing a closed port answers instantly with "refused" (the kernel says no); a DROP rule makes the same probe *hang* until timeout (nobody says anything) — because reject talks back, drop stays silent.

```bash
nc -zv -w3 127.0.0.1 9099 2>&1 | tail -1              # refused, instantly (no listener)
sudo iptables -A INPUT -p tcp --dport 9099 -j DROP     # simulate the wrong SG
time nc -zv -w3 127.0.0.1 9099 2>&1 | tail -1          # ~3s silence → timeout ("SG symptom")
sudo iptables -D INPUT -p tcp --dport 9099 -j DROP     # CLEANUP — remove the rule!
nc -zv -w3 127.0.0.1 9099 2>&1 | tail -1               # refused again
```
**Verify:** same port, two different failures, two different root-cause families. From now on, `i/o timeout` in a pod log reads as "filter or route," never "app."

**Lab 2 — statefulness made visible (why replies need no rules):**
> **My prediction:** while a connection I initiated is alive, the kernel's conntrack table holds its five-tuple with state ESTABLISHED — the memory that lets a stateful firewall admit replies automatically.

```bash
python3 -m http.server 8080 >/dev/null 2>&1 &
sleep 1
curl -s localhost:8080 >/dev/null &
sudo conntrack -L 2>/dev/null | grep 8080 | head -3 \
  || sudo cat /proc/net/nf_conntrack 2>/dev/null | grep 8080 | head -3 \
  || ss -tn | grep 8080                                # fallback view: the ESTABLISHED pair itself
kill %1
```
**Verify:** the tracked flow (or the ESTABLISHED socket pair) shows client `:ephemeral` ⇄ server `:8080`. A stateful SG consults exactly this memory; a NACL has none — hence its notorious ephemeral-range return rules.

## 🏔 Capstone

> **One sentence:** security groups are stateful allow-lists best written as group-references (the S14 "only from the cluster SG" pattern), NACLs are stateless subnet filters that must handle ephemeral replies explicitly — and "refused vs timeout" tells you in one word whether policy or process is your problem.

📚 **Go deeper:** [../../Networking/17-firewalls-security-groups-nacls.md](../../Networking/17-firewalls-security-groups-nacls.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 7</b> (say it aloud first, then open)</summary>

**Q:** catalog crash-loops with `dial tcp …:3306: i/o timeout`. Timeout, not refused — which three suspects does that word eliminate, and which one does the fix ("SG source = EKS cluster SG") confirm?

**A:** **"Timeout"** (SYN silently dropped, no answer) vs **"refused"** (host reachable, nothing listening, instant RST) is the whole triage. Timeout **eliminates** the three "the path worked and something actively responded" suspects:
1. **DNS** — a name failure gives "could not resolve," not a timeout on an IP:port; it's already dialing `…:3306`, so the name resolved.
2. **The DB process down / not listening** — that gives **connection refused**, an instant answer, not silence.
3. **Wrong port** — also typically refused, not timed out.

What "timeout" *points at* is a **filtering/routing drop** — a firewall silently discarding the SYN. The fix ("SG source = EKS cluster SG") **confirms it was the security group**: the RDS SG wasn't admitting traffic from the cluster (wrong/missing source), so SYNs were dropped → timeout. Referencing the EKS cluster SG (which the node/pod ENIs carry) opens the path → it connects. One word — refused vs timeout — splits "process/port problem" from "filter/route problem."

</details>

---
---

# CLIMB 8 — Load Balancing: L4 vs L7, Health Checks & the Front Door

## 🔥 Rung 1 — The Pain

Replicas (Climb 10's Services, S08's Deployments) are useless if clients must pick one themselves — and dangerous if traffic keeps flowing to a dead one. Something in front must spread load, *notice failures*, and (at L7) route by content: paths, hosts, headers.

**Where this project makes you feel it:** the **ALB Ingress** (S11) is the store's front door — path routing, target-group **health checks against `/actuator/health`-style endpoints**, `ip` target mode straight to pod IPs; **ExternalDNS + ACM** hang the domain and cert on it (S16); Istio's ingress gateway rides an **NLB** (S22) because the mesh wants raw TCP+TLS passed through to Envoy; 502/504 triage at the ALB is a rite of passage; and the S22 **DestinationRule outlier detection** ("eject after 5 consecutive 5xx") is load-balancer health logic moved into the mesh.

## 💡 Rung 2 — The One Idea

> **A load balancer is a reverse proxy that spreads requests across a *health-checked* pool — L4 (NLB) balances TCP connections it cannot read, L7 (ALB/Envoy) terminates HTTP and can route on path/host/header — so "which layer?" decides what routing is even possible.**

## ⚙️ Rung 3 — The Machinery

```
                         ┌── health checker: GET /health every N s
client ── TCP ──▶ ALB ───┤    fail threshold → target OUT of pool (untouched by traffic)
   TLS ends here (ACM)   │    pass threshold → back IN
                         └── router: Host + path (+header) rules → TARGET GROUP → pick target
                              (ip-mode: targets are POD IPs — thank the VPC CNI, Climb 9)

TWO CONNECTIONS, NOT ONE (the 5xx decoder):        L4 NLB CONTRAST:
client ⇄ ALB        ALB ⇄ pod                      passes bytes; can't see paths;
502 = pod refused/garbled the 2nd connection        preserves client IP; near-zero
504 = pod accepted but exceeded ALB's timeout       latency; ideal for TLS-passthrough
503 = no healthy targets in the pool                (→ Istio gateway, S22)
```

- **Health checks make LBs *availability* devices, not just spreaders:** a deploy where new pods fail their check never receives traffic — that interlock (readiness → target health) is what makes S21's rolling updates zero-downtime *end to end*.
- **The L7 proxy is a man-in-the-middle by design:** it terminates TLS (Climb 5), reads the request (Climb 4), and originates a *new* connection — hence separate timeouts, connection pools, and the ability to retry or shift 10% of traffic (Envoy's whole S22 feature set is "L7 LB, per-pod").
- **In-cluster twin:** a K8s Service (Climb 10) is an L4 balancer you can't see; Ingress adds the L7 layer; Istio makes *every pod's sidecar* an L7 balancer with per-route policy.

> **✅ Check yourself:** users report intermittent 502s after a deploy; `kubectl get pods` says Running. Which two health-check/readiness misconfigurations produce exactly this, and why does "Running" not exonerate the pods? (Hint: Running ≠ Ready ≠ passing the ALB's own check.)

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| reverse proxy | server-side middleman terminating requests | ALB, nginx, Envoy — same role, three scales |
| target group | the health-checked backend pool | what the ALB Ingress controller populates (S11) |
| `ip` vs `instance` target mode | pod IPs directly vs NodePort hop | S11 uses ip-mode (VPC CNI makes it possible) |
| health check / threshold | probe + in/out pool decision | `/health` GETs from the ALB (S11) |
| ALB (L7) vs NLB (L4) | reads HTTP vs forwards TCP | Ingress front door vs Istio gateway (S22) |
| 502 / 503 / 504 | backend broke / pool empty / backend slow | the triage trio |
| algorithm (RR, least-conn) | pick-a-target policy | defaults are fine; know they exist |
| outlier detection | passive ejection on errors | S22's circuit breaker = health check, passive form |

## 🔬 Rung 5 — The Trace: one purchase click through the front door (S16 stack)

1. `https://retail-store.<domain>/checkout` → DNS (Climb 3, ExternalDNS's record) → ALB.
2. TLS terminates at the ALB with the ACM cert (Climb 5).
3. Listener rules match Host+path → ui target group; ALB picks a **healthy** pod-IP target (health checker has been GETting `/health` all along).
4. New connection ALB→`10.0.11.213:8080` (Climb 6's DNAT-free ip-mode — it's a real VPC IP).
5. ui fans out to catalog/carts/checkout (Climb 10's Services; with S22, each hop via Envoy = another tiny L7 LB with retries/timeouts). A pod that starts failing checks silently leaves the pool — users never see it die.

## ⚖️ Rung 6 — The Contrast

- **ALB vs NLB:** need path/host/header routing, ACM termination, WAF → ALB. Need raw TCP/TLS passthrough, fixed IPs, client-IP preservation, extreme throughput → NLB (exactly why Istio's gateway takes one, S22).
- **LB health checks vs K8s probes:** same GET, different enforcer (ALB pool vs kubelet/EndpointSlice) — production needs both aligned on a truthful endpoint, or the layers disagree about who's alive.

## 🧪 Rung 7 — Hands-on

**Lab 1 — build the ALB in miniature: round-robin + passive health ejection:**
> **My prediction:** nginx alternates my curls across two backends; when I kill one, at most one request errors and then all traffic converges on the survivor — because the proxy marks the failed target down (the target-group mechanic).

```bash
docker network create lbnet
for v in v1 v2; do docker run -d --name $v --network lbnet busybox sh -c \
  "mkdir /www && echo catalog-$v > /www/index.html && httpd -f -p 8080 -h /www"; done
cat > $(pwd)/nginx.conf <<'EOF'
events {}
http { upstream pool { server v1:8080; server v2:8080; }
  server { listen 80; location / { proxy_pass http://pool; proxy_connect_timeout 1s; } } }
EOF
docker run -d --name lb --network lbnet -p 8080:80 -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine
sleep 1; for i in 1 2 3 4; do curl -s localhost:8080; done      # alternation (round robin)
docker stop v2 >/dev/null
for i in 1 2 3 4; do curl -s --max-time 2 localhost:8080; done  # ≤1 hiccup, then all v1
docker rm -f lb v1 v2 >/dev/null; docker network rm lbnet >/dev/null; rm nginx.conf
```
**Verify:** the convergence-after-failure is passive health checking (nginx's `max_fails`) — the ALB does it actively with probe GETs, Envoy does it as outlier detection (S22); one concept, three uniforms.

**Lab 2 — L7 path routing (the Ingress rule, hand-made):**
> **My prediction:** the same front port serves `/catalog` from one backend and `/orders` from another — impossible for an L4 balancer — because only an HTTP-terminating proxy can see the path.

```bash
docker network create l7net
docker run -d --name cat --network l7net busybox sh -c 'mkdir /www && echo CATALOG > /www/index.html && httpd -f -p 8080 -h /www'
docker run -d --name ord --network l7net busybox sh -c 'mkdir /www && echo ORDERS  > /www/index.html && httpd -f -p 8080 -h /www'
cat > $(pwd)/nginx.conf <<'EOF'
events {}
http { server { listen 80;
  location /catalog { proxy_pass http://cat:8080/; }
  location /orders  { proxy_pass http://ord:8080/; }
  location /health  { return 200 "lb ok\n"; } } }
EOF
docker run -d --name ingress --network l7net -p 8080:80 -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine
sleep 1; curl -s localhost:8080/catalog; curl -s localhost:8080/orders; curl -s localhost:8080/health
docker rm -f ingress cat ord >/dev/null; docker network rm l7net >/dev/null; rm nginx.conf
```
**Verify:** path→backend mapping in a proxy config *is* an Ingress manifest's `rules:` block (S11), which *is* an ALB listener rule — you've now written the primitive all three compile down to.

## 🏔 Capstone

> **One sentence:** a load balancer is a health-checked reverse proxy — L4 forwards connections blind (NLB/Istio gateway), L7 terminates and routes on host/path/header (ALB/Ingress/Envoy) — and 502/503/504 plus "who left the pool" is the entire triage grammar.

📚 **Go deeper:** [../../Networking/18-load-balancing.md](../../Networking/18-load-balancing.md), [../../Networking/27-kubernetes-ingress-gateway-api.md](../../Networking/27-kubernetes-ingress-gateway-api.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 8</b> (say it aloud first, then open)</summary>

**Q:** Intermittent 502s after a deploy, pods "Running." Which two health-check/readiness misconfigs produce this, and why doesn't "Running" exonerate them?

**A:** "Running" only means the container *process started* — it does **not** mean the pod is **Ready** (passing its readiness probe) or that the **ALB's target-group health check** considers it healthy. Three separate gates. Two misconfigs that produce exactly intermittent 502s (502 = the ALB got no valid response from a backend it forwarded to):
1. **No/incorrect readiness probe (or too-short initialDelay):** the pod joins the target group before the app can actually serve (JVM warming up), so requests routed to it in that window fail → 502. Only *some* pods *some* of the time → intermittent.
2. **ALB health-check path/port mismatch or loose thresholds:** the check points at the wrong path/port, or lets a not-yet-ready / already-terminating pod flap in and out of the pool → requests hit a target the ALB *thinks* is healthy but isn't → 502. (Deploy-time variant: old pods terminate before draining from the target group — no deregistration delay/preStop — so in-flight requests hit a dying pod.)

"Running" is the weakest signal; **readiness (kubelet/EndpointSlice) AND the ALB's own check must both agree** a pod can serve, or you get exactly these deploy-time intermittent 502s.

</details>

---
---

# CLIMB 9 — Container & Pod Networking: bridge, veth, CNI

## 🔥 Rung 1 — The Pain

Every container needs its own network world (own ports — that's how five services all bind 8080), yet they must reach each other, the host, and the internet. Do this with real hardware and you'd need a NIC per container. And Kubernetes raises the bar: *every pod gets a real, routable IP* so pods talk without port gymnastics.

**Where this project makes you feel it:** S02–04 live on Docker's bridge (published ports, service-name DNS, `ports: []` internals); on EKS (S07+) the **AWS VPC CNI** hands each pod an IP *from your private subnets* — the reason ALB ip-mode targets pods directly (S11) and pod SG/routing behave like plain VPC traffic; the Istio sidecar (S22) can only intercept because it shares the pod's network namespace (Linux Climb 8).

## 💡 Rung 2 — The One Idea

> **Container networking is namespaces + virtual cables: each container/pod gets a private network namespace, a veth pair patches it to the host (bridge or VPC ENI), and a CNI plugin is just the program that builds that plumbing and assigns the IP.**

## ⚙️ Rung 3 — The Machinery

```
DOCKER (your laptop, S02–04):                EKS + VPC CNI (S07+):
┌── container netns ──┐                      ┌── pod netns ──┐
│ eth0 10.17.0.5      │                      │ eth0 10.0.11.213  ← a REAL subnet IP │
└───────┬─────────────┘                      └───────┬────────┘
   veth pair (two-ended cable)                  veth pair
        │                                            │
   docker0 bridge (a virtual switch)           node ENI(s) — the CNI pre-allocates
        │  MASQUERADE → host IP (Climb 6)      subnet IPs on them and hands them out
   host eth0 → internet                        → pod-to-pod = ordinary VPC routing,
                                                 NO overlay, NO encapsulation
A POD = one netns SHARED by its containers (pause container holds it):
app + Envoy sidecar see the SAME eth0, talk over localhost — that's sidecar interception.
```

- **The four K8s networking rules** (every CNI must deliver): every pod an IP; pods reach pods (all nodes) without NAT; agents reach pods; the pod sees its own IP. The VPC CNI satisfies them with *real* VPC addresses — other CNIs (Flannel/Calico) use overlay networks (VXLAN) instead; same contract, different plumbing.
- **Why you care in this course:** pod IPs consume subnet space (Climb 1's sizing!), ALB ip-mode targets *are* pod IPs (Climb 8), SG-per-node covers pods (Climb 7), and `ip link | grep veth` on any node shows one cable per pod — the abstraction made touchable.
- **Docker's embedded DNS (Climb 3) + bridge + MASQUERADE (Climb 6)** is the complete Compose story: names → container IPs → bridge hops → SNAT out.

> **✅ Check yourself:** all five retail services bind :8080 and never conflict — name the exact primitive that makes that true (it is NOT port mapping). Then: why does ALB ip-mode require the VPC CNI's "real IP" property?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| network namespace | a private net stack (ifaces, routes, ports) | every container (S02); every pod |
| veth pair | two-ended virtual patch cable | `ip link \| grep veth` per container/pod |
| bridge (`docker0`) | virtual switch joining veth ends | Docker/Compose networking (S02–04) |
| CNI plugin | the program kubelet calls to wire a pod | AWS VPC CNI (S07+) |
| VPC CNI / ENI | pods get real subnet IPs from node ENIs | ip-mode targets (S11), subnet sizing (S06) |
| overlay (VXLAN) | pod traffic tunneled node-to-node | the Flannel/Calico alternative — not used here |
| pause container | holds the pod's shared namespaces | why pod IP survives app restarts |
| sidecar | second container, same netns | Envoy (S22), sharing localhost with the app |

## 🔬 Rung 5 — The Trace: ui pod → catalog pod, different nodes (EKS, S08+)

1. ui (10.0.11.213, node A) sends to catalog's *Service* VIP; kube-proxy DNATs to a catalog pod IP 10.0.12.87 (node B) — Climb 10's half.
2. Packet exits ui's netns via its veth into node A's stack.
3. Node A routing: `10.0.0.0/16 → local` — destination is just another VPC address (no overlay, no tunnel).
4. VPC delivers to node B's ENI that owns 10.0.12.87; the CNI's wiring forwards down the right veth into catalog's netns.
5. catalog answers to 10.0.11.213 — plain VPC routing back. Every hop was ordinary L3; *that* simplicity is what the VPC CNI buys, at the price of consuming real subnet IPs (Climb 1's trade).

## ⚖️ Rung 6 — The Contrast

- **VPC CNI (native IPs: simple path, SG/ALB/flow-log friendly, but IP-hungry) vs overlays (IP-thrifty, cloud-agnostic, but encapsulation overhead and another debugging layer):** the course's EKS choice is the former; know both for interviews.
- **Docker bridge vs host network:** `--network host` skips isolation (no port privacy — one :8080 only) — the exception that proves why namespaces exist.

## 🧪 Rung 7 — Hands-on

**Lab 1 — find the cable: match a container's eth0 to its host veth:**
> **My prediction:** starting a container adds exactly one `veth*` on my host, and the container's `eth0` interface index+1 (its `iflink`) equals that veth's `ifindex` — because they're two ends of one kernel-created pair.

```bash
ip -br link | grep -c veth                        # count before
docker run -d --name probe busybox sleep 300 >/dev/null
ip -br link | grep veth                           # one NEW veth appeared (the host end)
IDX=$(docker exec probe cat /sys/class/net/eth0/iflink)
grep -l "^${IDX}$" /sys/class/net/veth*/ifindex   # ← THE matching host end, by index
docker exec probe ip -br addr                     # the container's private view: eth0 + lo only
docker rm -f probe >/dev/null
```
**Verify:** the grep names exactly one veth — you physically located the pod-side/node-side cable that `kubectl describe` never shows. On an EKS node, the same loop maps pods to veths.

**Lab 2 — build a "pod network" by hand (be the CNI for two minutes):**
> **My prediction:** after I create a netns, a veth pair, move one end in, and assign 10.244.0.2/24 + 10.244.0.1/24, the namespace and my host can ping each other — because that's ALL a CNI fundamentally does per pod.

```bash
sudo ip netns add pod1
sudo ip link add veth-host type veth peer name veth-pod
sudo ip link set veth-pod netns pod1
sudo ip addr add 10.244.0.1/24 dev veth-host && sudo ip link set veth-host up
sudo ip netns exec pod1 ip addr add 10.244.0.2/24 dev veth-pod
sudo ip netns exec pod1 ip link set veth-pod up
sudo ip netns exec pod1 ip link set lo up
ping -c2 10.244.0.2                                # host → "pod"
sudo ip netns exec pod1 ping -c2 10.244.0.1        # "pod" → host
sudo ip netns exec pod1 ip route                   # its tiny private routing table
sudo ip netns del pod1                             # cleanup
```
**Verify:** two pings across a namespace boundary you wired yourself. kubelet+CNI repeat this (plus IP allocation from the subnet/ENI and route programming) for every pod in the course — the "magic" is ~6 commands.

## 🏔 Capstone

> **One sentence:** every container/pod is a private network namespace patched to the node by a veth pair — Docker plugs it into a MASQUERADEd bridge, the AWS VPC CNI plugs it into real subnet IPs on ENIs — and sidecars/pods sharing one namespace is what makes localhost-level interception (Istio) possible.

📚 **Go deeper:** [../../Networking/23-container-docker-networking.md](../../Networking/23-container-docker-networking.md), [../../Networking/24-kubernetes-pod-networking-cni.md](../../Networking/24-kubernetes-pod-networking-cni.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 9</b> (say it aloud first, then open)</summary>

**Q:** All five services bind `:8080` without conflict — name the primitive (it's NOT port mapping). Then: why does ALB ip-mode require the VPC CNI's "real IP" property?

**A:** The primitive is the **network namespace**. Each pod (each container) gets its **own private network namespace** with its own `eth0` and its own port space. Port 8080 is unique only *within* a namespace, so five pods each bind `:8080` at once — five separate `:8080`s in five separate network stacks. No collision, and no remapping involved (isolation, not translation).

**ALB ip-mode** registers **pod IPs directly** as targets (ALB → pod IP, skipping the node/NodePort hop). For the ALB to send packets straight to a pod IP, that IP must be **routable inside the VPC** — a real subnet address the ALB's network can reach. The **AWS VPC CNI** gives each pod a real VPC-subnet IP (from the node's ENIs), so pod IPs are first-class VPC addresses. With an overlay CNI (Flannel/Calico VXLAN), pod IPs live on a virtual overlay the ALB can't route to → ip-mode wouldn't work. So ip-mode's "target the pod IP" depends on the CNI's "pods get real, VPC-routable IPs."

</details>

---
---

# CLIMB 10 — Kubernetes Services → Ingress → Mesh: the Delivery Chain

## 🔥 Rung 1 — The Pain

Pod IPs churn with every reschedule (Climb 9 gave pods IPs; Deployments kill and recreate them freely). Nothing can hardcode a pod IP — so Kubernetes needs a *stable front* per app, then a front door for the cluster, then (at scale) per-request traffic policy. That three-step escalation *is* Sections 08 → 11 → 22.

**Where this project makes you feel it:** S08's ClusterIP `catalog-service` + headless `catalog-mysql`; S11's ALB Ingress; S14's ExternalName to RDS; S16's LoadBalancer/Ingress + ExternalDNS; S21's rolling update relying on EndpointSlices updating live; S22's Envoy sidecars, `DestinationRule` subsets and the 90/10 + `x-canary` VirtualService — the course uses **all five Service types** and both upper layers.

## 💡 Rung 2 — The One Idea

> **A Service is a stable virtual name+IP mapped by label selector to an always-current list of pod IPs (EndpointSlices), enforced by kube-proxy's NAT rules — Ingress adds one L7 front door for HTTP, and the mesh moves L7 control into every pod's sidecar.**

## ⚙️ Rung 3 — The Machinery

```
THE LADDER OF FRONTS (all used in this course):
ClusterIP    stable VIP+DNS inside the cluster          catalog-service (S08)
  headless   clusterIP: None → DNS gives POD IPs        catalog-mysql-0… (S08, DBs: no LB for writes!)
  ExternalName → CNAME to an outside host               catalog-mysql → RDS (S14)
NodePort     every node opens :3xxxx → Service          the LB's attachment point (S08/11)
LoadBalancer cloud LB in front of NodePorts/pods        NLB/ALB (S16/22)
Ingress      ONE L7 router for many Services            ALB Ingress, path rules (S11)
Mesh         Envoy beside EVERY pod, policy per request VirtualService/DestinationRule (S22)

HOW A ClusterIP ACTUALLY WORKS (no process listens on it!):
  Service catalog-service = VIP 172.20.44.7:80, selector app=catalog
  controller watches pods with that label → writes EndpointSlices [10.0.11.213:8080, 10.0.12.87:8080]
  kube-proxy (every node) compiles iptables/IPVS: "dst 172.20.44.7:80 → DNAT to ONE of the endpoints"
  → the "load balancer" is a NAT rule in the kernel of the node the CLIENT is on (Climb 6's DNAT!)

MESH TWIST (S22): Envoy in each pod intercepts outbound; VirtualService says
  90% → subset v1, 10% → subset v2 (or header x-canary → v2); DestinationRule defines subsets
  by pod LABELS → canary at request level, no Deployment/replica surgery.
```

- **Labels are the join key everywhere:** Service selector ↔ pod labels ↔ EndpointSlices ↔ (S22) DestinationRule subsets. One mislabel = empty endpoints = "Service exists but nothing answers" — the classic S08 debugging moment.
- **Readiness gates membership:** a pod failing its readiness probe is *removed from EndpointSlices* — the k8s half of the zero-downtime interlock (Climb 8's health checks are the ALB half; S21's rolling update leans on both).
- **Why headless for MySQL (S08):** a VIP would load-balance writes across replicas; `clusterIP: None` returns pod DNS records so the app targets `catalog-mysql-0` (the master) *by name*.

> **✅ Check yourself:** `curl catalog-service` from the ui pod hangs; `kubectl get endpoints catalog-service` shows `<none>`. Which join broke, which two objects do you diff, and why is kube-proxy *not* a suspect yet?

## 🏷️ Rung 4 — Vocabulary Map

| Term | What it is | Where in the project |
|---|---|---|
| ClusterIP / VIP | stable virtual IP, DNAT'd by kube-proxy | every internal service (S08) |
| EndpointSlices | the live pod-IP list behind a Service | what readiness edits; what you check first |
| selector / labels | the Service↔pod join | `app.kubernetes.io/name: catalog` (S08) |
| headless Service | DNS→pod IPs, no VIP | `catalog-mysql` StatefulSet pairing (S08) |
| ExternalName | DNS CNAME Service | → RDS endpoint (S14) |
| NodePort / LoadBalancer | node doorway / cloud LB front | the Ingress/NLB attachment path (S11/16/22) |
| Ingress (+controller) | L7 rules + the proxy realizing them | ALB Ingress controller (S11/16) |
| VirtualService / DestinationRule | route rules / subset+policy defs | the 90/10 canary + circuit breaker (S22) |
| sidecar (Envoy) | per-pod L7 proxy in the shared netns | injected by Istio (S22); Climb 9's namespace share |

## 🔬 Rung 5 — The Trace: the S22 canary, end to end (everything in this file, once)

1. Tester hits `https://retail-store.<domain>` — DNS via ExternalDNS's Route 53 record (C3), TLS at the NLB/Gateway with ACM (C5/C8).
2. Istio ingress gateway (Envoy, an L7 proxy — C8) forwards to the ui pod's Envoy — pod IPs are real VPC addresses (C9, C1).
3. ui calls `catalog` — its sidecar intercepts (shared netns, C9), consults the VirtualService: header `x-canary: true`? → subset v2; else 90/10 by weight (C4's headers, C8's L7 routing).
4. Subset v2 = pods labeled `version: v2` (DestinationRule) — Envoy picks a pod from the *ready* endpoints (C10), connects pod-to-pod over **mTLS** (C5), SGs permitting the node/pod path (C7), plain VPC routing carrying it (C6).
5. Response streams back; Kiali/Prometheus record the edge (golden signals, S20). Rollback? Set v1's weight to 100 — a routing change, no pods touched. Ten climbs, one request.

## ⚖️ Rung 6 — The Contrast

- **Service (L4, connection-level, cluster-internal) vs Ingress (L7, one front door) vs Mesh (L7 *between every pair*):** each layer exists because the previous one can't do finer-grained work — S22 §2 argues exactly this ("Rollouts are coarse… no way to send 10% of live traffic" without L7 in the path).
- **When NOT the mesh:** small clusters, latency-critical paths, or teams without the ops maturity — the sidecar tax (resource + complexity) must buy features you actually use (S22's own caveat).

## 🧪 Rung 7 — Hands-on

**Lab 1 — the 90/10 canary + header pin, reproduced with a proxy (S22 §6.5 semantics on your laptop):**
> **My prediction:** ~90% of my curls hit v1, ~10% v2, and `x-canary: true` *always* hits v2 — because a weighted pool plus a header-match route IS what a VirtualService compiles to in Envoy.

```bash
docker network create mesh
docker run -d --name v1 --network mesh busybox sh -c 'mkdir /www && echo "catalog v1" > /www/index.html && httpd -f -p 8080 -h /www'
docker run -d --name v2 --network mesh busybox sh -c 'mkdir /www && echo "catalog V2-CANARY" > /www/index.html && httpd -f -p 8080 -h /www'
cat > $(pwd)/nginx.conf <<'EOF'
events {}
http {
  upstream weighted { server v1:8080 weight=9; server v2:8080 weight=1; }   # the 90/10
  upstream canary   { server v2:8080; }
  map $http_x_canary $pool { default weighted; "true" canary; }             # the header pin
  server { listen 80; location / { proxy_pass http://$pool; } }
}
EOF
docker run -d --name vs --network mesh -p 8080:80 -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro nginx:alpine
sleep 1
for i in $(seq 20); do curl -s localhost:8080; done | sort | uniq -c        # ≈18 v1 / ≈2 v2
for i in 1 2 3; do curl -s -H "x-canary: true" localhost:8080; done          # ALWAYS v2
sed -i 's/weight=9/weight=0 down/; s/v2:8080 weight=1/v2:8080/' nginx.conf 2>/dev/null || true
docker rm -f vs v1 v2 >/dev/null; docker network rm mesh >/dev/null; rm nginx.conf
```
**Verify:** weights + header-match reproduce the S22 VirtualService exactly; "instant rollback" is editing one weight — no backend touched. Now read S22 §6.5 again: every YAML line has a home.

**Lab 2 — the sidecar position: two containers, one network namespace (the pod/Envoy model):**
> **My prediction:** a second container joined to the first one's network reaches the app on `localhost` and shows the *same* eth0/IP — because a pod is a shared netns, which is the only reason a sidecar can transparently sit in the traffic path.

```bash
docker run -d --name app busybox sh -c 'mkdir /www && echo "app answers" > /www/index.html && httpd -f -p 8080 -h /www'
docker run --rm --network container:app busybox sh -c \
  'echo "--- my view (the sidecar):"; ip -br addr; wget -qO- http://localhost:8080'
docker exec app ip -br addr        # identical interfaces — one namespace, two processes
docker rm -f app >/dev/null
```
**Verify:** the "sidecar" fetched the app over localhost without any published port — Istio's Envoy does exactly this (then iptables in the netns redirects all in/out traffic through itself). Pods (S08's "sidecars share net+storage") and injection (S22) are now mechanical, not magical.

**Lab 3 (optional, if you have kind/minikube or the course EKS cluster) — see the real thing:**
```bash
kubectl create deployment catalog --image=nginx --replicas=2
kubectl expose deployment catalog --port=80 --name=catalog-service
kubectl get endpointslices -l kubernetes.io/service-name=catalog-service   # the live pod-IP list
kubectl run client --rm -it --image=busybox --restart=Never -- nslookup catalog-service
kubectl scale deployment catalog --replicas=3 && kubectl get endpointslices -l kubernetes.io/service-name=catalog-service
kubectl delete deployment catalog; kubectl delete svc catalog-service
```
**Verify:** scaling edits EndpointSlices live — the churn-absorbing indirection every climb above feeds into.

## 🏔 Capstone

> **One sentence:** Services are label-joined VIPs whose endpoint lists absorb pod churn via kube-proxy NAT, Ingress puts one L7 router in front of them, and the mesh puts an L7 router beside *every* pod — so canaries, retries, and mTLS become per-request routing policy instead of infrastructure surgery.

📚 **Go deeper:** [../../Networking/25-kubernetes-services-kube-proxy.md](../../Networking/25-kubernetes-services-kube-proxy.md), [../../Networking/27-kubernetes-ingress-gateway-api.md](../../Networking/27-kubernetes-ingress-gateway-api.md), [../../Networking/29-service-mesh-and-sidecars.md](../../Networking/29-service-mesh-and-sidecars.md), [Istio ladder](../../Istio_Learning_Ladder.md)

<details>
<summary><b>✅ Check-yourself answer — Climb 10</b> (say it aloud first, then open)</summary>

**Q:** `curl catalog-service` from the ui pod hangs; `kubectl get endpoints catalog-service` shows `<none>`. Which join broke, which two objects do you diff, and why is kube-proxy *not* a suspect yet?

**A:** The broken join is the **label-selector match** between Service and pods. A Service's endpoints are populated by matching `Service.spec.selector` against pod **labels**; `<none>` means **no pods matched** — so there's nothing behind the ClusterIP, and the curl hangs (traffic DNAT'd to an empty backend set → no answer → timeout).

**Diff these two objects:** (1) the **Service's `spec.selector`** and (2) the **pods' `metadata.labels`** (i.e. the Deployment's `spec.template.metadata.labels`). They must match exactly — a typo or mismatched key/value on either side breaks the join.

**Why kube-proxy isn't a suspect yet:** kube-proxy only *programs iptables/IPVS rules from whatever is in EndpointSlices*. Empty endpoints → kube-proxy is faithfully doing nothing (correctly). The failure is **upstream** of it, at the label→endpoint population step, not the NAT-programming step. Fix the labels so endpoints populate; only if endpoints are correct but traffic still fails would you look at kube-proxy.

</details>

---
---

# 🏔 FINAL CAPSTONE — Compress the Whole File

Say each climb in one sentence, out loud, no notes. A stall = that climb's 🧪 labs are your next session.

| # | Climb | The one sentence you must own |
|---|---|---|
| 1 | IP & CIDR | `/N` cuts 32 bits into network/host; subnets are per-AZ cuts; public vs private is which cut you're in. |
| 2 | Ports & sockets | Five values name a connection; servers hold well-known ports, clients arrive ephemeral; exposing = placing a doorway. |
| 3 | DNS | hosts-file→resolver→authority, cached by TTL; Compose names, Service names, ExternalName, ExternalDNS = one phone book at four scales. |
| 4 | HTTP | method+path+headers → status code, readable at every hop — probes, path routing, 502/504, and `x-canary` all read the same grammar. |
| 5 | TLS | per-session encryption trusted via cert chains to your root store; mTLS runs it both ways; expiry is the classic outage. |
| 6 | Routing & NAT | longest-prefix picks the hop; SNAT lets private out (NAT GW), DNAT swaps fronts for backends (ports, VIPs). |
| 7 | SG & NACL | stateful allow-lists referencing *groups* vs stateless subnet filters; refused = no listener, timeout = filtered. |
| 8 | Load balancing | a health-checked reverse proxy; L4 forwards blind, L7 terminates and routes; pools eject the failing. |
| 9 | Container networking | netns + veth pair + (bridge \| VPC ENI); the CNI is the plumber; pods share one netns — hence sidecars. |
| 10 | Services→Ingress→mesh | label-joined VIPs over live endpoints, one L7 front door, then an L7 proxy per pod for per-request policy. |

**Suggested order against the course:** Climbs 1–2 before S02–04 (Docker/Compose) · 3–4 before S04 healthchecks and S08 Services · 1+6+7 before S06–07 (VPC/EKS Terraform) · 8 before S11 (Ingress) · 7 again at S14 (data-plane SGs) · 3 again at S15–16 (ExternalDNS) · 5 before S16 (ACM) and S21 (`--insecure`) · 9–10 before S08 and essential for S22.

**The recurring primitive to watch for:** almost everything here is *"a name or address, resolved → routed → filtered → proxied."* Compose DNS, CoreDNS, ExternalName, Route 53; docker0, VPC route tables; SG references; nginx, ALB, kube-proxy, Envoy — four verbs, endlessly re-costumed. The moment you catch yourself saying "oh, this is just DNAT again" or "that's the phone book again," you've stopped memorizing the course and started deriving it.

---

*Companion file: [00A — Linux Foundations](00A-linux-foundations-learning-ladder.md) · Full deep-dive ladders: [../../Networking/](../../Networking/00-README.md) · Course index: [00-INDEX.md](00-INDEX.md)*

---

## 🧪 Troubleshooting Lab — SadServers-Style Scenarios (Project-Grounded)

> **How to use this lab:** These are hands-on, [sadservers.com](https://sadservers.com)-style challenges — one per broken box, with a story, a task, and an objective **Verify** command that proves you fixed it. They are organized by the ten climbs above; each climb has **6 scenarios of rising difficulty** (🟢 Easy → 🟡 Medium → 🟠 Hard → 🔴 Expert), and every scenario is tied to a real artifact of the Retail-Store DevOps project (see the **Project link** line).
>
> **Run them on a disposable Ubuntu/Debian VM** (Multipass, Vagrant, or a throwaway cloud instance) — many setups use `sudo` and build mini-networks with `ip netns`, `veth` pairs, a `lab0` bridge, and `iptables`. Everything is scoped to `labns-*` namespaces, `labveth*` interfaces, `/opt/lab-*` paths, and ports `8000–8999`; all firewall rules live in dedicated `LAB-*` chains so your real connectivity is never disturbed. Where the project uses an AWS/EKS object you can't run locally (a VPC subnet, a NAT gateway, a Security Group, Route 53, an ALB, kube-proxy, a service mesh), the setup builds a **faithful local analogue** and the answer maps it back to the real thing.
>
> **The drill:** run the **Setup**, read the **Situation**, do the **Task**, and confirm with **Verify** — *before* peeking at the 🔑 solutions at the very bottom of this file. Every scenario that changes global state (a sysctl, an `iptables` rule, a namespace) carries a **Cleanup** line in its answer.

### Climb 1 — IP Addressing, CIDR & Subnetting: the VPC's Grammar

#### 🟢 Scenario 1.1 — "Bologna: the mask decides who is local" (Easy)
**Setup:**
```bash
mkdir -p /opt/lab-bologna
cat > /opt/lab-bologna/layout.txt <<'EOF'
# retail-store VPC plan (mirrors S06 Terraform)
vpc      10.0.0.0/16
public   10.0.1.0/24  10.0.2.0/24
private  10.0.11.0/24 10.0.12.0/24
probe    10.0.11.57
EOF
cat /opt/lab-bologna/layout.txt
```
**Situation:** A new SRE joins the retail-store team and asks, on their first day, "the node that keeps paging us has IP `10.0.11.57` — is that a public box facing the ALB or a private worker?" Nobody wants to guess. The S06 VPC plan is right there in `/opt/lab-bologna/layout.txt`.

**Your task:** Without any AWS access, determine (a) whether `10.0.11.57` is inside the VPC `10.0.0.0/16`, (b) whether it is inside `10.0.1.0/24`, (c) which of the four course subnets actually contains it, and (d) how many *usable* hosts an AWS `/24` yields (AWS reserves 5). Prove each answer with `python3`'s `ipaddress` module.

**Project link:** S06–07 VPC subnet math — `vpc_cidr = "10.0.0.0/16"`, public `.1`/`.2`, private `.11`/`.12`.

**Verify:**
```bash
python3 - <<'EOF'
import ipaddress as ip
probe = ip.ip_address('10.0.11.57')
print('in 10.0.0.0/16 ?', probe in ip.ip_network('10.0.0.0/16'))   # expected: True
print('in 10.0.1.0/24 ?', probe in ip.ip_network('10.0.1.0/24'))   # expected: False
print('home subnet     ?', probe in ip.ip_network('10.0.11.0/24'))  # expected: True
print('AWS usable /24  =', ip.ip_network('10.0.11.0/24').num_addresses - 5)  # expected: 251
EOF
# expected: private worker in 10.0.11.0/24, 251 usable hosts on AWS
```

#### 🟢 Scenario 1.2 — "Verona: read your node's addressing" (Easy)
**Setup:**
```bash
ip -br addr
ip route | head -5
```
**Situation:** Before trusting the VPC plan on paper, the team wants you to read a *real* Linux host the way a worker node carries its addressing — every attachment has an IP and a mask, exactly like a VPC subnet. Your disposable VM stands in for the node.

**Your task:** List every interface with its IP/mask, identify which address is RFC1918 (private, like the `10.x` VPC), and confirm the loopback carries `127.0.0.0/8`. Report the CIDR mask on your primary interface and state how many host bits it leaves.

**Project link:** Rung 7 Lab 2 — "read YOUR machine's addressing like a node"; every attachment carries address+mask like a VPC subnet.

**Verify:**
```bash
ip -br addr show lo | grep -q '127.0.0.1/8' && echo "loopback /8 ok"   # expected: loopback /8 ok
python3 -c "import ipaddress,subprocess;a=subprocess.check_output(['hostname','-I']).split()[0].decode();print(a,'is_private=',ipaddress.ip_address(a).is_private)"
# expected: primary IP prints is_private= True
```

#### 🟡 Scenario 1.3 — "Palermo: the overlap that breaks peering" (Medium)
**Setup:**
```bash
mkdir -p /opt/lab-palermo
cat > /opt/lab-palermo/plan.tf.txt <<'EOF'
# proposed subnets for a SECOND retail-store VPC (to be peered with 10.0.0.0/16)
subnet_a = "10.0.1.0/24"     # public-1a
subnet_b = "10.0.2.0/24"     # public-1b
subnet_c = "10.0.11.0/24"    # private-1a
subnet_d = "10.1.11.0/24"    # private-1b  (typo? intended 10.0.12.0/24)
EOF
cat /opt/lab-palermo/plan.tf.txt
```
**Situation:** An engineer copy-pasted subnet blocks for a *second* VPC that must be VPC-peered with the production `10.0.0.0/16`. Peering silently forbids overlapping CIDRs, and the plan reuses `10.0.1.0/24`, `10.0.2.0/24`, `10.0.11.0/24` — all already carved in prod. The plan will `terraform apply` fine and then peering will refuse.

**Your task:** Write a check that flags every proposed subnet that overlaps the production VPC `10.0.0.0/16`, and propose a non-overlapping replacement block (e.g. `10.2.0.0/16`) whose subnets do NOT collide. Prove the replacement is clean.

**Project link:** Rung 3 — "Overlaps are forever: peering/VPN between VPCs with overlapping CIDRs is impossible — why S06 plans ranges up front."

**Verify:**
```bash
python3 - <<'EOF'
import ipaddress as ip
prod = ip.ip_network('10.0.0.0/16')
proposed = ['10.0.1.0/24','10.0.2.0/24','10.0.11.0/24','10.1.11.0/24']
for s in proposed:
    n = ip.ip_network(s)
    print(s, 'overlaps prod?', n.overlaps(prod))
repl = ip.ip_network('10.2.0.0/16')
print('replacement 10.2.0.0/16 overlaps prod?', repl.overlaps(prod))
EOF
# expected: the three 10.0.x subnets overlap=True, 10.1.11.0/24 and 10.2.0.0/16 overlap=False
```

#### 🟡 Scenario 1.4 — "Genoa: the day the pods ran out of IPs" (Medium)
**Setup:**
```bash
mkdir -p /opt/lab-genoa
cat > /opt/lab-genoa/scale.txt <<'EOF'
# EKS VPC CNI: every pod takes a REAL subnet IP (S07)
private_subnets = 10.0.11.0/24, 10.0.12.0/24   # two /24
pods_per_node   = 50
nodes_target    = 20
EOF
cat /opt/lab-genoa/scale.txt
```
**Situation:** Scale day. The retail-store cluster autoscales toward 20 nodes at ~50 pods each. Pods start landing in `ContainerCreating` and events read `failed to assign an IP address to container`. On EKS the VPC CNI hands every pod a real subnet IP, so the two private `/24`s are the true ceiling.

**Your task:** Compute the total pod IPs demanded (50×20) versus the AWS-usable capacity of two `/24`s (each `256 − 5`). Show the deficit. Then size a **secondary CIDR** (e.g. add `100.64.0.0/16`) big enough to absorb the shortfall, and state how many usable addresses it adds.

**Project link:** Rung 5 step 5 — "50 pods/node × 20 nodes ≈ 1,000 pod IPs — your two /24s (502 usable) run dry"; secondary CIDR is the fix.

**Verify:**
```bash
python3 - <<'EOF'
import ipaddress as ip
demand = 50*20
usable = sum(ip.ip_network(s).num_addresses-5 for s in ('10.0.11.0/24','10.0.12.0/24'))
print('demand', demand, 'usable', usable, 'deficit', demand-usable)
sec = ip.ip_network('100.64.0.0/16')
print('secondary CIDR adds usable', sec.num_addresses-5)
EOF
# expected: demand 1000 usable 502 deficit 498; secondary adds 65531 — comfortably covers it
```

#### 🟠 Scenario 1.5 — "Pisa: two subnets, one wrong mask" (Hard)
**Setup:**
```bash
sudo ip netns add labns-pub
sudo ip netns add labns-priv
sudo ip link add labveth-pub type veth peer name labveth-pub-br
sudo ip link add labveth-priv type veth peer name labveth-priv-br
sudo ip link set labveth-pub netns labns-pub
sudo ip link set labveth-priv netns labns-priv
sudo ip link add lab0 type bridge
sudo ip link set labveth-pub-br master lab0
sudo ip link set labveth-priv-br master lab0
sudo ip link set lab0 up
sudo ip link set labveth-pub-br up
sudo ip link set labveth-priv-br up
# public node: correct /24 in 10.0.1.0/24
sudo ip netns exec labns-pub ip addr add 10.0.1.10/24 dev labveth-pub
sudo ip netns exec labns-pub ip link set labveth-pub up
sudo ip netns exec labns-pub ip link set lo up
# private node: BUG — given a /28 mask so 10.0.1.10 looks "off-link"
sudo ip netns exec labns-priv ip addr add 10.0.11.10/28 dev labveth-priv
sudo ip netns exec labns-priv ip link set labveth-priv up
sudo ip netns exec labns-priv ip link set lo up
```
**Situation:** Two netns "nodes" hang off the `lab0` bridge — a public node `10.0.1.10` and a private node `10.0.11.10` — the veth+bridge standing in for ENIs on a shared VPC segment. The private node was handed a `/28` instead of the shared-segment mask, so its kernel thinks almost every peer is off-link and needs a gateway that does not exist. Pings across the segment fail.

**Your task:** From `labns-priv`, demonstrate the failure reaching `10.0.1.10`, explain via the mask why the kernel refuses, then correct the private node's mask so both nodes share one broadcast domain and can reach each other. Use only `ip` inside the namespaces.

**Project link:** Rung 3 — "The mask is a decision boundary, not decoration. The kernel answers 'local or via a gateway?' by masking the destination and comparing"; veth+bridge = subnet/ENI analogue.

**Verify:**
```bash
sudo ip netns exec labns-priv ping -c1 -W1 10.0.1.10 && echo "cross-node reachable after mask fix"
# expected: 1 packet received, "cross-node reachable after mask fix"
```

#### 🔴 Scenario 1.6 — "Siena: which private node can't phone home" (Expert)
**Setup:**
```bash
sudo ip netns add labns-a
sudo ip netns add labns-b
sudo ip netns add labns-gw
sudo ip link add lab0 type bridge
sudo ip link set lab0 up
for n in a b gw; do
  sudo ip link add labveth-$n type veth peer name labveth-$n-br
  sudo ip link set labveth-$n netns labns-$n
  sudo ip link set labveth-$n-br master lab0
  sudo ip link set labveth-$n-br up
  sudo ip netns exec labns-$n ip link set lo up
  sudo ip netns exec labns-$n ip link set labveth-$n up
done
# gateway node holds .1 of the private-1a subnet
sudo ip netns exec labns-gw   ip addr add 10.0.11.1/24  dev labveth-gw
# node A: correct private-1a address + default route via gw
sudo ip netns exec labns-a    ip addr add 10.0.11.20/24 dev labveth-a
sudo ip netns exec labns-a    ip route add default via 10.0.11.1
# node B: BUG — provisioned into the WRONG subnet (private-1b 10.0.12.x) on the 1a segment
sudo ip netns exec labns-b    ip addr add 10.0.12.30/24 dev labveth-b
sudo ip netns exec labns-b    ip route add default via 10.0.11.1
```
**Situation:** Three netns nodes share the `10.0.11.0/24` private-1a segment through `lab0`: a gateway `.1`, node A `.20`, and node B — which was mistakenly given a `10.0.12.30/24` address (the private-1b range) while cabled onto the 1a segment. A retail-store pod on node B can't reach the gateway (its route to `10.0.11.1` is treated as off-link because B's own subnet is `10.0.12.0/24`), while node A is healthy.

**Your task:** Prove node A reaches the gateway and node B does not. Diagnose — using each node's address/mask and route table — exactly why B fails though it shares the wire. Re-address node B into the correct `10.0.11.0/24` subnet (keep host `.30`) so it reaches the gateway, without touching node A or the gateway.

**Project link:** Rung 5 steps 3–4 + Check-yourself — subnets are AZ-scoped; putting a node in the wrong subnet CIDR breaks its on-link/gateway decision. netns+veth+bridge = subnets/ENIs.

**Verify:**
```bash
sudo ip netns exec labns-a ping -c1 -W1 10.0.11.1 && echo "A ok"
sudo ip netns exec labns-b ping -c1 -W1 10.0.11.1 && echo "B ok after re-address"
# expected: both print "ok"; before the fix, only A succeeds
```

### Climb 2 — Ports & Sockets: One IP, Many Services

#### 🟢 Scenario 2.1 — "Trieste: who is holding 8080?" (Easy)
**Setup:**
```bash
mkdir -p /opt/lab-trieste/www
echo "catalog ok" > /opt/lab-trieste/www/index.html
( cd /opt/lab-trieste/www && python3 -m http.server 8080 >/dev/null 2>&1 & )
sleep 1
```
**Situation:** A retail-store backend refuses to start: "port already allocated." Before blaming Docker, the on-call rule (S02) is to ask the kernel what is *actually* listening. A stray `python3 -m http.server` is squatting on 8080 in your VM, mimicking the stuck container.

**Your task:** Use `ss -ltnp` to find which process and PID own the LISTEN socket on port 8080, then confirm the service answers with `curl`. Report the owning command and PID.

**Project link:** Rung 3 — "`ss -tlnp` is the truth… the first command of every 'connection refused' triage"; `EADDRINUSE` (S02).

**Verify:**
```bash
ss -ltnp | grep ':8080 '        # expected: one LISTEN line naming python3 + its pid
curl -s localhost:8080          # expected: catalog ok
```

#### 🟢 Scenario 2.2 — "Parma: the five-tuple, live" (Easy)
**Setup:**
```bash
mkdir -p /opt/lab-parma/www
echo "ui ok" > /opt/lab-parma/www/index.html
( cd /opt/lab-parma/www && python3 -m http.server 8081 >/dev/null 2>&1 & )
sleep 1
```
**Situation:** The team wants to *see* what "a connection is named by five values" means, using the retail ui as the example. A server listens on 8081; a client dials it. You will catch the ESTABLISHED pair and the ephemeral source port the client borrowed.

**Your task:** Open a client connection to `localhost:8081`, then use `ss -tn` to show the ESTABLISHED pair. Identify the client's ephemeral source port and confirm it falls inside the kernel's `net.ipv4.ip_local_port_range`.

**Project link:** Rung 3 + Rung 7 Lab 1 — ephemeral client port (32768–60999) vs fixed server port; the five-tuple.

**Verify:**
```bash
( curl -s --max-time 3 localhost:8081 >/dev/null & )
sleep 1
ss -tn | grep ':8081'                    # expected: ESTABLISHED, 127.0.0.1:<high> -> 127.0.0.1:8081
sysctl net.ipv4.ip_local_port_range      # expected: the range containing that high port
```

#### 🟡 Scenario 2.3 — "Granada: EADDRINUSE, two services one port" (Medium)
**Setup:**
```bash
mkdir -p /opt/lab-granada
cat > /opt/lab-granada/carts.service.sh <<'EOF'
#!/usr/bin/env bash
# carts backend — hardcoded to 8080 like the container's listen port
exec python3 -m http.server 8080 --bind 127.0.0.1
EOF
cat > /opt/lab-granada/orders.service.sh <<'EOF'
#!/usr/bin/env bash
# orders backend — ALSO hardcoded to 8080; will collide on one host
exec python3 -m http.server 8080 --bind 127.0.0.1
EOF
chmod +x /opt/lab-granada/*.sh
/opt/lab-granada/carts.service.sh >/dev/null 2>&1 &
sleep 1
```
**Situation:** Two retail backends — carts and orders — each hardcode `--bind 127.0.0.1:8080`. On separate container network namespaces they coexist fine (Climb 9), but someone runs both directly on one host and orders dies instantly with "Address already in use." carts is already up.

**Your task:** Start `orders.service.sh` and capture the `EADDRINUSE` failure. Prove carts owns 8080 via `ss`. Then fix orders to listen on a free port in the lab range (e.g. 8082) — editing the script — so both services run at once, and verify both answer.

**Project link:** Rung 3 — "Only one listener per address:port: a second bind fails with EADDRINUSE — the 'port already allocated' Docker error, and why all-services-on-8080 requires per-container network namespaces."

**Verify:**
```bash
/opt/lab-granada/orders.service.sh 2>&1 | grep -qi "address already in use" && echo "collision reproduced"
# after editing orders to 8082 and starting it:
# curl -s 127.0.0.1:8080 >/dev/null && curl -s 127.0.0.1:8082 >/dev/null && echo "both up"
# expected: collision reproduced; then both up on 8080 and 8082
```

#### 🟡 Scenario 2.4 — "Segovia: publish the ui, hide the carts" (Medium)
**Setup:**
```bash
sudo ip netns add labns-svc
sudo ip link add labveth-svc type veth peer name labveth-svc-host
sudo ip link set labveth-svc netns labns-svc
sudo ip addr add 10.9.0.1/24 dev labveth-svc-host
sudo ip link set labveth-svc-host up
sudo ip netns exec labns-svc ip addr add 10.9.0.2/24 dev labveth-svc
sudo ip netns exec labns-svc ip link set labveth-svc up
sudo ip netns exec labns-svc ip link set lo up
mkdir -p /opt/lab-segovia/www
echo "carts internal only" > /opt/lab-segovia/www/index.html
sudo ip netns exec labns-svc bash -c 'cd /opt/lab-segovia/www && python3 -m http.server 8080 >/dev/null 2>&1 &'
sleep 1
```
**Situation:** This reproduces S04's exposure model without Docker: `labns-svc` is a "container" running carts on 8080, reachable only across the veth link (its internal Docker network). The host is your laptop. carts must stay internal; only the ui gets a published doorway. Right now nothing on the host's own `localhost` reaches carts — as designed.

**Your task:** Show that carts on `10.9.0.2:8080` is reachable from the host across the veth (internal path) but NOT on the host's `localhost:8888` (no doorway). Then *publish* it the way `-p 8888:8080` does — add a userspace DNAT doorway with `socat` from host `localhost:8888` to `10.9.0.2:8080` — and prove `localhost:8888` now answers. This is the `8888:8080` mapping, by hand.

**Project link:** Rung 3 + Rung 7 Lab 2 — "Compose `8888:8080` means host doorway 8888 forwards to container doorway 8080 (mechanically a DNAT rule)"; S04 `ports: []` = internal only.

**Verify:**
```bash
curl -s --max-time 2 10.9.0.2:8080                                   # expected: carts internal only (internal path works)
curl -s --max-time 2 localhost:8888 || echo "no doorway yet"         # expected: no doorway yet
# after: socat TCP-LISTEN:8888,fork,reuseaddr TCP:10.9.0.2:8080 &
# curl -s localhost:8888                                             # expected: carts internal only (doorway added)
```

#### 🟠 Scenario 2.5 — "Toledo: port → targetPort → nodePort, three doorways deep" (Hard)
**Setup:**
```bash
mkdir -p /opt/lab-toledo/www
echo "catalog v1" > /opt/lab-toledo/www/index.html
# the POD: app listens on containerPort/targetPort 8080
( cd /opt/lab-toledo/www && python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 & )
sleep 1
cat > /opt/lab-toledo/service-chain.txt <<'EOF'
# mirrors an S08 Service manifest, mapped to local socat hops:
#   containerPort/targetPort 8080  (the pod, already up)
#   Service port             7080  (ClusterIP front port -> targetPort)
#   NodePort                 30080  (node-level doorway -> Service port)
EOF
cat /opt/lab-toledo/service-chain.txt
```
**Situation:** In S08 a client never hits the container port directly: a Service exposes `port: 7080 → targetPort: 8080`, and a NodePort adds `30080` at the node edge. Someone reports `kubectl port-forward 7080:8080` "works" but the NodePort URL 404s, and asks you to model the whole three-hop chain locally so the team can see which hop breaks.

**Your task:** Using `socat`, build the chain: NodePort `30080` → Service port `7080` → targetPort `8080` (the running pod). Verify each hop answers `catalog v1`. Then simulate the bug — a Service whose `targetPort` points at the wrong port (9999, nothing listening) — and show that the *node/Service* ports still accept the TCP connection but the app reply never comes (connection resets/empties), isolating the misconfigured hop.

**Project link:** Rung 3 — "K8s repeats the pattern three deep: Service `port` → `targetPort` (container), and NodePort adds a node-level doorway (30000–32767)"; every S08 Service manifest.

**Verify:**
```bash
socat TCP-LISTEN:7080,fork,reuseaddr TCP:127.0.0.1:8080 >/dev/null 2>&1 &
socat TCP-LISTEN:30080,fork,reuseaddr TCP:127.0.0.1:7080 >/dev/null 2>&1 &
sleep 1
curl -s 127.0.0.1:8080     # expected: catalog v1  (targetPort)
curl -s 127.0.0.1:7080     # expected: catalog v1  (Service port)
curl -s 127.0.0.1:30080    # expected: catalog v1  (NodePort — full chain)
# mis-target demo: socat TCP-LISTEN:7081,fork,reuseaddr TCP:127.0.0.1:9999 &
# curl -s --max-time 2 127.0.0.1:7081 || echo "connects but no app reply — bad targetPort"
```

#### 🔴 Scenario 2.6 — "Cadiz: refused vs timeout — name the failure" (Expert)
**Setup:**
```bash
sudo ip netns add labns-db
sudo ip link add labveth-db type veth peer name labveth-db-host
sudo ip link set labveth-db netns labns-db
sudo ip addr add 10.8.0.1/24 dev labveth-db-host
sudo ip link set labveth-db-host up
sudo ip netns exec labns-db ip addr add 10.8.0.2/24 dev labveth-db
sudo ip netns exec labns-db ip link set labveth-db up
sudo ip netns exec labns-db ip link set lo up
# a "MySQL" listener on 3306 inside the db netns
sudo ip netns exec labns-db bash -c 'python3 -m http.server 3306 >/dev/null 2>&1 &'
# a stateful-firewall analogue: DROP inbound to 5432 (Redis/PG port) to force a TIMEOUT
sudo ip netns exec labns-db bash -c 'command -v iptables >/dev/null && iptables -A INPUT -p tcp --dport 5432 -j DROP || true'
sleep 1
```
**Situation:** Two S14 data-plane symptoms land in the same ticket: checkout gets "connection refused" hitting one store and "connection timeout" hitting another. One means no listener (refused), the other means a firewall/SG silently dropping (timeout) — the exact distinction the S14/S19 troubleshooting rows turn on. The db netns runs a listener on 3306, has nothing on 6379, and DROPs 5432.

**Your task:** From the host, probe `10.8.0.2` on ports 3306 (up), 6379 (no listener), and 5432 (dropped) with `nc -zv` and short timeouts. Classify each result: which is "refused" (RST → no listener → app/port wrong), which is "timeout" (filtered → firewall/SG → Climb 7). Map the timeout to what an SG rule fixes.

**Project link:** Rung 6 — "`nc -zv` (L4: does the port answer?) vs `curl`… 'refused' = no listener, 'timeout' = filtered path (Climb 7)"; S14/S19 connect-timeout troubleshooting rows.

**Verify:**
```bash
nc -zv -w1 10.8.0.2 3306   # expected: succeeded  (listener present)
nc -zv -w1 10.8.0.2 6379   # expected: Connection refused  (RST, no listener)
nc -zv -w2 10.8.0.2 5432   # expected: timed out  (packet dropped — filtered)
```

### Climb 3 — DNS: Names Over Addresses

#### 🟢 Scenario 3.1 — "Salamanca: the hosts file that wins" (Easy)
**Setup:**
```bash
sudo cp /etc/hosts /opt/lab-salamanca-hosts.bak 2>/dev/null || cp /etc/hosts /tmp/lab-salamanca-hosts.bak
echo "203.0.113.9 catalog-mysql.lab.internal" | sudo tee -a /etc/hosts >/dev/null
grep hosts: /etc/nsswitch.conf
```
**Situation:** A ticket: "`getent` says the catalog DB is `203.0.113.9` but `dig` says it doesn't exist — which is right?" This is the classic files-beat-DNS asymmetry: `/etc/hosts` is consulted before DNS in `nsswitch`, and `dig` bypasses the file entirely. Someone pinned a fake host entry.

**Your task:** Show that `getent hosts catalog-mysql.lab.internal` (full glibc chain) returns `203.0.113.9` while `dig +short catalog-mysql.lab.internal` (server-only path) returns nothing. Explain which layer each tool reads and why they disagree.

**Project link:** Rung 3 + Rung 7 Lab 1 — "`dig`/`nslookup` bypass `/etc/hosts` and nsswitch… 'dig resolves it but the app can't' means the file layer disagrees with the server layer."

**Verify:**
```bash
getent hosts catalog-mysql.lab.internal    # expected: 203.0.113.9 catalog-mysql.lab.internal
dig +short catalog-mysql.lab.internal      # expected: (empty)
# Cleanup restores /etc/hosts — see answer file.
```

#### 🟢 Scenario 3.2 — "Girona: who does this box ask?" (Easy)
**Setup:**
```bash
cat /etc/resolv.conf
grep -E 'hosts:' /etc/nsswitch.conf
```
**Situation:** A pod's `resolv.conf` is written by kubelet and points at CoreDNS; your VM's is written by the host and points at a stub resolver. Before debugging any name failure, the team's first move is to read *who this box asks and with what search suffixes*. You will read your own machine's resolver config as the model.

**Your task:** Report the `nameserver` line(s) your VM uses, any `search` domains, and the `nsswitch` `hosts:` order. State, in one line, the analogue: in a pod this same file would name CoreDNS (`172.20.0.10`) and the `svc.cluster.local` search domains.

**Project link:** Rung 3 — "IN A POD: resolv.conf is WRITTEN BY KUBELET: nameserver 172.20.0.10 (CoreDNS)… search default.svc.cluster.local…"; Rung 7 Lab 1.

**Verify:**
```bash
grep -E '^nameserver' /etc/resolv.conf       # expected: at least one nameserver line
getent hosts localhost                        # expected: 127.0.0.1 localhost (chain works)
```

#### 🟡 Scenario 3.3 — "Braga: stand up a Route 53 in a can" (Medium)
**Setup:**
```bash
mkdir -p /opt/lab-braga
cat > /opt/lab-braga/zone.conf <<'EOF'
# local dnsmasq = a Route 53 "hosted zone" for lab.internal (S15 analogue)
port=8053
no-resolv
no-hosts
listen-address=127.0.0.1
bind-interfaces
address=/shop.lab.internal/198.51.100.20
address=/catalog.lab.internal/198.51.100.21
EOF
cat /opt/lab-braga/zone.conf
```
**Situation:** ExternalDNS (S15/16) writes your Ingress hostnames into a Route 53 hosted zone. To rehearse that locally, you run `dnsmasq` on `127.0.0.1:8053` as a private hosted zone for `lab.internal`, holding A records for `shop` and `catalog` — never touching the VM's real `/etc/resolv.conf`.

**Your task:** Launch `dnsmasq` with `/opt/lab-braga/zone.conf`, then resolve both names by querying that resolver directly with `dig @127.0.0.1 -p 8053`. Confirm the A records match the zone. Add a third record (`checkout.lab.internal → 198.51.100.22`), reload, and resolve it.

**Project link:** Rung 4 — "zone / hosted zone: the DB of records for a domain → your Route 53 hosted zone (S15)"; local dnsmasq zone = Route 53 hosted zone.

**Verify:**
```bash
sudo dnsmasq --conf-file=/opt/lab-braga/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
dig @127.0.0.1 -p 8053 +short shop.lab.internal       # expected: 198.51.100.20
dig @127.0.0.1 -p 8053 +short catalog.lab.internal    # expected: 198.51.100.21
```

#### 🟡 Scenario 3.4 — "Coimbra: the CNAME that hides the RDS churn" (Medium)
**Setup:**
```bash
mkdir -p /opt/lab-coimbra
cat > /opt/lab-coimbra/zone.conf <<'EOF'
# ExternalName Service analogue: catalog-mysql is a CNAME to the "RDS" hostname (S14)
port=8053
no-resolv
no-hosts
listen-address=127.0.0.1
bind-interfaces
# the real "RDS" endpoint and its address:
address=/mydb3.abc123.lab-rds.internal/192.0.2.55
# the stable alias the app dials — a CNAME, exactly like ExternalName:
cname=catalog-mysql.svc.lab.internal,mydb3.abc123.lab-rds.internal
EOF
cat /opt/lab-coimbra/zone.conf
```
**Situation:** In S14 the app dials the stable name `catalog-mysql`, which CoreDNS serves as an **ExternalName** — literally a CNAME to the current RDS hostname. When RDS rotates, only that one alias target changes; the app never learns the real hostname or IP. You reproduce this with a `dnsmasq` CNAME.

**Your task:** Resolve `catalog-mysql.svc.lab.internal` and show the CNAME hop landing on `mydb3.abc123.lab-rds.internal` and finally `192.0.2.55`. Then simulate a `terraform destroy`+re-apply: edit ONLY the RDS A record to a new IP (`192.0.2.77`), reload, and show the alias now resolves to the new IP with the app-facing name unchanged.

**Project link:** Rung 5 (catalog opens its DB connection) + Check-yourself — "ExternalName is literally a CNAME served by CoreDNS (catalog-mysql → RDS hostname)"; one object absorbs the churn.

**Verify:**
```bash
sudo dnsmasq --conf-file=/opt/lab-coimbra/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
dig @127.0.0.1 -p 8053 catalog-mysql.svc.lab.internal    # expected: CNAME -> mydb3... , A 192.0.2.55
dig @127.0.0.1 -p 8053 +short catalog-mysql.svc.lab.internal | tail -1   # expected: 192.0.2.55 (then 192.0.2.77 after edit)
```

#### 🟠 Scenario 3.5 — "Faro: short names, search domains & ndots" (Hard)
**Setup:**
```bash
sudo ip netns add labns-pod
sudo ip netns exec labns-pod ip link set lo up
sudo mkdir -p /etc/netns/labns-pod
# per-netns resolv.conf = what kubelet writes into a pod (never touches host resolv.conf)
cat > /opt/lab-faro-resolv.conf <<'EOF'
nameserver 127.0.0.1
options ndots:5
search default.svc.lab.internal svc.lab.internal lab.internal
EOF
sudo cp /opt/lab-faro-resolv.conf /etc/netns/labns-pod/resolv.conf
mkdir -p /opt/lab-faro
cat > /opt/lab-faro/zone.conf <<'EOF'
port=53
no-resolv
no-hosts
listen-address=127.0.0.1
bind-interfaces
# only the FQDN exists — short name must be completed via search domains:
address=/catalog-service.default.svc.lab.internal/172.20.0.55
EOF
cat /opt/lab-faro/zone.conf /etc/netns/labns-pod/resolv.conf
```
**Situation:** In-cluster, an app dials the *short* name `catalog-service` and it resolves to `catalog-service.default.svc.cluster.local` because kubelet wrote `search` domains and `ndots:5` into the pod's `resolv.conf`. You reproduce this: a per-netns `resolv.conf` with search domains, and a resolver that only knows the FQDN. The short name must be auto-completed.

**Your task:** Inside `labns-pod`, run a `dnsmasq` bound to `127.0.0.1:53` (namespace-local) serving only the FQDN, then show that `getent hosts catalog-service` (which honors `search`) resolves via the search list to `172.20.0.55`, while a raw `dig +short catalog-service` (no search expansion) does NOT. Explain the role of `ndots:5` and the search list.

**Project link:** Rung 3 + Rung 4 — "short name 'catalog-service' + search list = catalog-service.default.svc.cluster.local"; "search domains + ndots: auto-complete for short names."

**Verify:**
```bash
sudo ip netns exec labns-pod dnsmasq --conf-file=/opt/lab-faro/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
sudo ip netns exec labns-pod getent hosts catalog-service          # expected: 172.20.0.55 (search-completed)
sudo ip netns exec labns-pod dig +short catalog-service.default.svc.lab.internal   # expected: 172.20.0.55 (FQDN)
```

#### 🔴 Scenario 3.6 — "Cascais: ExternalDNS reconciles the zone" (Expert)
**Setup:**
```bash
mkdir -p /opt/lab-cascais/records.d
cat > /opt/lab-cascais/zone.conf <<'EOF'
port=8053
no-resolv
no-hosts
listen-address=127.0.0.1
bind-interfaces
conf-dir=/opt/lab-cascais/records.d,*.conf
EOF
# an "Ingress" with an external-dns hostname annotation (S15/16) — no record exists YET
cat > /opt/lab-cascais/ingress.txt <<'EOF'
# external-dns.alpha.kubernetes.io/hostname: shop.lab.internal
# ingress ADDRESS (ALB analogue):            203.0.113.80
hostname=shop.lab.internal
target=203.0.113.80
ttl=60
EOF
cat > /opt/lab-cascais/externaldns.sh <<'EOF'
#!/usr/bin/env bash
# tiny ExternalDNS: read the ingress annotation, WRITE the Route 53 (dnsmasq) record, reload
set -euo pipefail
src="/opt/lab-cascais/ingress.txt"
host=$(grep '^hostname=' "$src" | cut -d= -f2)
tgt=$(grep '^target='   "$src" | cut -d= -f2)
printf 'address=/%s/%s\n' "$host" "$tgt" > /opt/lab-cascais/records.d/managed.conf
echo "reconciled: $host -> $tgt"
pkill -HUP dnsmasq 2>/dev/null || true
EOF
chmod +x /opt/lab-cascais/externaldns.sh
sudo dnsmasq --conf-file=/opt/lab-cascais/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
```
**Situation:** ExternalDNS is a controller that *writes* Route 53 records from Ingress annotations — DNS as reconciled infrastructure (S15/16). You model the whole loop: a `dnsmasq` hosted zone with a records drop-dir, an "Ingress" annotation file, and a tiny reconciler script. Before reconcile the name is `NXDOMAIN`; after, it resolves; change the annotation and it converges again.

**Your task:** Show `shop.lab.internal` is unresolved before running the reconciler. Run `externaldns.sh`, reload the zone, and show it now returns `203.0.113.80`. Then edit `ingress.txt`'s target to a new ALB IP (`203.0.113.99`), re-run, and prove convergence — noting where the TTL means a cached client would lag. Map each piece back to the real objects.

**Project link:** Rung 3 + Rung 4 — "ExternalDNS is a controller writing Route 53 records from Ingress annotations — DNS as reconciled infrastructure"; the `external-dns.alpha…hostname` annotation (S15/16); TTL/caching.

**Verify:**
```bash
dig @127.0.0.1 -p 8053 +short shop.lab.internal        # expected BEFORE: (empty / NXDOMAIN)
/opt/lab-cascais/externaldns.sh                        # expected: reconciled: shop.lab.internal -> 203.0.113.80
sleep 1
dig @127.0.0.1 -p 8053 +short shop.lab.internal        # expected AFTER: 203.0.113.80
```


> **How these labs work (sadservers.com style):** each scenario is a broken (or suspicious) system you build on a **disposable Ubuntu/Debian VM** with only `python3`, `openssl`, `curl` and `nc` — nothing to install. Paste the **Setup** block, read the **Situation**, and fix it using the **Your task** constraints. You are done when every command in **Verify** prints its `# expected:` line. Everything lives under a dedicated `/opt/lab-*` directory and ports 8000–8999; every scenario has a Cleanup block in the answers. One safety rule throughout: **never install a lab CA into the system trust store** — always point at it explicitly with `--cacert` / `-CAfile`. Predict out loud before every command: which status code, which exit code, which handshake verdict — then check.

### Climb 4 — HTTP & HTTPS: the Protocol Every Microservice Speaks

Six on-call pages, all decided by reading the request and the verdict: methods, paths, headers, status codes, and the curl exit codes that probes live on.

#### 🟢 Scenario 4.1 — "Dubai: the health path that held the whole stack hostage" (Easy)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-dubai
cd /opt/lab-dubai && mkdir -p www
echo '{"status":"UP"}' > www/actuator-health        # the app team's health document
nohup python3 -m http.server 8010 --directory /opt/lab-dubai/www >/dev/null 2>&1 &
echo $! > pids
cat > gate.sh <<'GATE'
#!/bin/bash
# Compose's `depends_on: {carts: {condition: service_healthy}}` gate, by hand:
# poll the healthcheck; only when it passes does "ui" get to start.
until curl -fsS http://localhost:8010/health >/dev/null 2>&1; do sleep 2; done
date > /opt/lab-dubai/ui.started
echo "ui STARTED"
GATE
chmod +x gate.sh
nohup ./gate.sh > gate.log 2>&1 &
echo $! >> pids
```

**Situation:** the "carts" service (port 8010) is up and serving — `ps` shows both processes alive, and the app team swears the health JSON is deployed. Yet a minute later `/opt/lab-dubai/ui.started` still doesn't exist: the startup gate never opens, so "ui" never starts. Last night's deploy "only renamed a file."

**Your task:**
- Run the healthcheck **by hand** exactly as the gate does: `curl -f http://localhost:8010/health`. Read both the HTTP status code and curl's **exit code** (`echo $?`) — the exit code *is* the health verdict.
- Find what the server actually serves (`curl http://localhost:8010/` lists the docroot).
- Fix it **on the app side** so `ui.started` appears within ~2 seconds. Constraint: do **not** edit `gate.sh` — in the real stack the probe path (`/health`) is the platform's contract; the app must honor it.

**Project link:** this is S04's Lab C verbatim: the Compose healthcheck `curl -f http://localhost:8080/actuator/health` returning 404 makes curl exit 22, Docker marks carts unhealthy forever, and `depends_on: condition: service_healthy` keeps ui from ever starting. K8s readiness probes and ALB target-group health checks are the same GET-and-judge loop.

**Verify:**

```bash
curl -fsS -o /dev/null -w 'code=%{http_code}\n' http://localhost:8010/health
# expected: code=200
sleep 3; cat /opt/lab-dubai/ui.started
# expected: a timestamp — the gate opened and "ui" started
grep -q "ui STARTED" /opt/lab-dubai/gate.log && echo GATE-OPENED
# expected: GATE-OPENED
```

#### 🟢 Scenario 4.2 — "Doha: reading the verdict: 200, 404, and the exit code that is a probe" (Easy)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-doha
cd /opt/lab-doha
cat > app.py <<'EOF'
import http.server
ROUTES = {
    "/health":   (200, b'{"status":"UP"}\n'),
    "/orders":   (200, b'{"orders":[{"id":1,"total":42}]}\n'),
    "/admin":    (403, b'{"error":"forbidden: no token"}\n'),
    "/checkout": (500, b'{"error":"NullPointerException in CartTotals"}\n'),
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = ROUTES.get(self.path, (404, b'{"error":"no such path"}\n'))
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def do_HEAD(self):
        code, _ = ROUTES.get(self.path, (404, b""))
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8020), H).serve_forever()
EOF
nohup python3 app.py >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** a junior teammate pasted five failing URLs into the incident channel with the caption "the whole retail API is down." It isn't. Five paths, five different verdicts — your job is to triage them the way an ALB, a probe, and an SRE each would, using only curl's four reading tools: `-v`, `-I`, `-w`, `-f`.

**Your task:**
- For each of `/health /orders /cart /admin /checkout` on port 8020, capture the status code with `-s -o /dev/null -w '%{http_code}'` and classify it: **2xx works / 4xx caller's fault / 5xx server side's fault**. Which single path would page *the checkout team* rather than the caller?
- Use `-v` on `/checkout` and read both directions of the raw grammar (`>` request lines, `<` status line).
- Use `-I` on `/orders` to fetch the verdict without the body (HEAD — what monitors do to stay cheap).
- Run `curl -f` against `/cart` and capture `$?`. Explain in one sentence why every healthcheck in the course consumes this **exit code** and never parses the body.

**Project link:** the status-class triage map of Climb 4 Rung 3 — probe pass/fail (`curl -f` exit 22 on ≥400), ALB 4xx-vs-5xx dashboards, and the S02–S08 REST endpoints (`/health`, `/topology`, `/catalog/products`) all speak exactly these verdicts.

**Verify:**

```bash
for p in /health /orders /cart /admin /checkout; do
  curl -s -o /dev/null -w "$p -> %{http_code}\n" http://localhost:8020$p
done
# expected: /health -> 200, /orders -> 200, /cart -> 404, /admin -> 403, /checkout -> 500
curl -f -s http://localhost:8020/cart >/dev/null; echo "probe exit=$?"
# expected: probe exit=22
curl -f -s http://localhost:8020/health >/dev/null; echo "probe exit=$?"
# expected: probe exit=0
```

#### 🟡 Scenario 4.3 — "Muscat: 502 at the door: the backend that wasn't there" (Medium)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-muscat
cd /opt/lab-muscat
cat > catalog.py <<'EOF'
import http.server, os
PORT = int(os.environ.get("CATALOG_PORT", "8031"))
class B(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"products":["kimono","mug","cap"]}\n')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", PORT), B).serve_forever()
EOF
cat > proxy.py <<'EOF'
# the ALB analogue: forwards everything to its one registered target, 127.0.0.1:8031
import http.client, http.server
class P(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            c = http.client.HTTPConnection("127.0.0.1", 8031, timeout=2)
            c.request("GET", self.path)
            r = c.getresponse(); body = r.read()
            self.send_response(r.status); self.end_headers(); self.wfile.write(body)
        except Exception:
            self.send_response(502); self.end_headers()
            self.wfile.write(b"502 Bad Gateway: no healthy upstream\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8030), P).serve_forever()
EOF
nohup python3 proxy.py >/dev/null 2>&1 &
echo $! > pids
CATALOG_PORT=8032 nohup python3 catalog.py >/dev/null 2>&1 &   # last night's "harmless" unit-file edit
echo $! >> pids
```

**Situation:** since last night's maintenance window every catalog page behind the load balancer (port 8030) returns **502 Bad Gateway**. The first responder is stuck because `ps` shows *both* processes running — proxy and catalog — so "nothing is down." Nobody has yet asked the only question a 502 ever asks: *is anything actually listening where the proxy connects?*

**Your task:**
- Reproduce: `curl` port 8030 and confirm the 502.
- Find where the proxy connects (read `proxy.py` — its "target group" is hard-wired to `127.0.0.1:8031`).
- Prove with `nc -z` (and/or `ss -ltn`) that **nothing listens on 8031**, then find which port the catalog process actually bound and why (read the last Setup line — a typo'd `CATALOG_PORT`).
- Fix it so the proxy answers 200: put a catalog listener on 8031 (kill the mis-bound one first; append any new PID to `/opt/lab-muscat/pids`).

**Project link:** ALB 502 triage (S11/S16): "502 = the LB tried to reach a target and got connection-refused or garbage." Same shape as an ip-mode target group pointing at pod IPs that no longer exist. Rung 3's triage line: 502 = proxy reached **no healthy backend**.

**Verify:**

```bash
curl -s -o /dev/null -w 'code=%{http_code}\n' http://localhost:8030/catalog/products
# expected: code=200
nc -z 127.0.0.1 8031 && echo "backend listening on 8031"
# expected: backend listening on 8031
```

#### 🟡 Scenario 4.4 — "Amman: one address, many shops: the Host header that missed" (Medium)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-amman
cd /opt/lab-amman
cat > vhosts.py <<'EOF'
# one listener, many sites — routing purely on the Host header
# (exactly what ALB host-header rules and Ingress `host:` blocks do)
import http.server
SITES = {
    "shop.devopsinminutes.com":  b"<h1>retail-store ui: 42 products</h1>\n",
    "admin.devopsinminutes.com": b"<h1>admin console</h1>\n",
}
class V(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        body = SITES.get(host)
        if body is None:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404: no vhost for Host=" + host.encode() + b"\n")
        else:
            self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8040), V).serve_forever()
EOF
nohup python3 vhosts.py >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** mid-migration, DNS for `shop.devopsinminutes.com` doesn't point at this box yet, so everyone "tests by IP": `curl http://localhost:8040/` — and gets 404. A teammate has concluded the load balancer is broken and the deploy failed. Both shops are in fact deployed and serving, behind **one** address.

**Your task:**
- Reproduce the 404 and actually **read the 404 body** — the router tells you exactly which key it looked up and missed.
- Get the storefront without touching DNS: send the routing key yourself with `-H "Host: shop.devopsinminutes.com"`.
- Then do it the honest way with `--resolve shop.devopsinminutes.com:8040:127.0.0.1` and the real URL — so the URL, the Host header, and (over TLS) the SNI would all agree. Explain in one sentence why `--resolve` is the better habit than `-H "Host:"` once HTTPS is involved.
- State what a *browser* on this machine would need to test the same thing (an `/etc/hosts` line — the manual version of what ExternalDNS automates).

**Project link:** `Host:` is Rung 3's "one LB, many sites" line: ALB listener rules route on host header (S16), the Istio Gateway routes on `hosts:` (S22), and Ingress `host:` blocks (S11) — one IP, many services, chosen per request by this single header.

**Verify:**

```bash
curl -s http://localhost:8040/ | head -1
# expected: 404: no vhost for Host=localhost   (the router names the missed key)
curl -s -H "Host: shop.devopsinminutes.com" http://localhost:8040/
# expected: <h1>retail-store ui: 42 products</h1>
curl -s --resolve shop.devopsinminutes.com:8040:127.0.0.1 http://shop.devopsinminutes.com:8040/
# expected: <h1>retail-store ui: 42 products</h1>
```

#### 🟠 Scenario 4.5 — "Beirut: 503: healthy pods, an unready store" (Hard)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-beirut
cd /opt/lab-beirut
cat > checkout.py <<'EOF'
# the checkout pod: alive, but /ready tells the truth about its Redis dependency
import http.server, socket
class B(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ready":
            try:
                socket.create_connection(("127.0.0.1", 8052), timeout=0.3).close()
                self.send_response(200); self.end_headers()
                self.wfile.write(b'{"status":"UP","redis":"ok"}\n')
            except OSError:
                self.send_response(503); self.end_headers()
                self.wfile.write(b'{"status":"DOWN","redis":"connect refused 127.0.0.1:8052"}\n')
        elif self.path == "/":
            self.send_response(200); self.end_headers()
            self.wfile.write(b"checkout: cart total = $42\n")
        else:
            self.send_response(404); self.end_headers()
            self.wfile.write(b"404\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8051), B).serve_forever()
EOF
cat > lb.py <<'EOF'
# readiness-gated LB: before forwarding, probe the target at the path named in lb.conf.
# probe != 200  =>  target unready  =>  503 to the caller (the ALB's "0 ready targets").
import http.client, http.server
class L(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        probe = open("/opt/lab-beirut/lb.conf").read().strip()
        try:
            c = http.client.HTTPConnection("127.0.0.1", 8051, timeout=2)
            c.request("GET", probe)
            ok = c.getresponse().status == 200
        except Exception:
            ok = False
        if not ok:
            self.send_response(503); self.end_headers()
            self.wfile.write(b"503 Service Unavailable: 0 of 1 targets ready\n")
            return
        c = http.client.HTTPConnection("127.0.0.1", 8051, timeout=2)
        c.request("GET", self.path)
        r = c.getresponse(); body = r.read()
        self.send_response(r.status); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8050), L).serve_forever()
EOF
echo "/healthz" > lb.conf        # probe path copied from the OLD chart's values
nohup python3 checkout.py >/dev/null 2>&1 &
echo $! > pids
nohup python3 lb.py >/dev/null 2>&1 &
echo $! >> pids
```

**Situation:** page: "checkout returns 503 Service Unavailable." Confusingly, everything looks *healthy*: the checkout process is up, the LB is up, and `curl http://localhost:8051/` straight at the pod returns 200 with a cart total. Yet through the LB (port 8050) it's 503 — "0 of 1 targets ready." **Two independent faults are stacked** in this system; fixing only one leaves the 503 in place. That trap — declaring victory after the first fix — is the whole lesson.

**Your task:** triage strictly layer by layer, proving each step with a curl **before** moving on:
- Read the LB's 503 body: it's a *readiness* verdict, not a crash.
- Probe the target the way the LB does: what does its configured probe path (see `lb.conf`) return directly against 8051? What does the app's real readiness path `/ready` return, and what does its **body** blame?
- Fix fault #1: the Redis dependency. Anything accepting TCP on `127.0.0.1:8052` satisfies it — `python3 -m http.server 8052 --bind 127.0.0.1` is fine (append its PID to `/opt/lab-beirut/pids`). Confirm `/ready` flips to 200 directly… and observe the LB **still** says 503.
- Fix fault #2: point the LB's probe at the app's real readiness path (edit `lb.conf` — the LB re-reads it per request). Confirm 200 end-to-end.
- Say out loud why 503 (unready) is a *different disease* from 502 (unreachable/garbage) — one is a failed readiness contract, the other a failed connection.

**Project link:** readiness probes gating Service endpoints (S08) and ALB target-group health checks marking targets unhealthy (S11): a pod can be alive (liveness OK) yet **unready** — commonly because a dependency like checkout's Redis (S14) is down, or because the probe path in the chart simply doesn't match the app. Rung 3: 503 = unavailable, "probes failing?".

**Verify:**

```bash
curl -s -o /dev/null -w 'ready=%{http_code}\n' http://localhost:8051/ready
# expected: ready=200
curl -s http://localhost:8050/
# expected: checkout: cart total = $42
cat /opt/lab-beirut/lb.conf
# expected: /ready
```

#### 🔴 Scenario 4.6 — "Tashkent: 502 or 504? the two ways a backend breaks a promise" (Expert)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-tashkent
cd /opt/lab-tashkent
touch truncate.on slow.on          # tonight's two regressions, flag-controlled
cat > catalog.py <<'EOF'
# catalog backend :8061 — promises a Content-Length, then (bug) stops early
import http.server, os
class T(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"products":["...large catalog payload..."]}' * 20
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if os.path.exists("/opt/lab-tashkent/truncate.on"):
            self.wfile.write(body[:40])       # breaks the promise mid-body
        else:
            self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8061), T).serve_forever()
EOF
cat > orders.py <<'EOF'
# orders backend :8062 — answers correctly, but (bug) takes 10 seconds
import http.server, os, time
class S(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if os.path.exists("/opt/lab-tashkent/slow.on"):
            time.sleep(10)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"orders":[{"id":1}]}\n')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8062), S).serve_forever()
EOF
cat > proxy.py <<'EOF'
# the ALB analogue :8060 — 3s upstream timeout; /catalog -> 8061, /orders -> 8062
import http.client, http.server, socket
UPSTREAM = {"/catalog": 8061, "/orders": 8062}
class P(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = UPSTREAM.get(self.path)
        if port is None:
            self.send_response(404); self.end_headers(); return
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            c.request("GET", self.path)
            r = c.getresponse(); body = r.read()
            self.send_response(r.status); self.end_headers(); self.wfile.write(body)
        except socket.timeout:
            self.send_response(504); self.end_headers()
            self.wfile.write(b"504 Gateway Timeout: upstream exceeded 3s\n")
        except Exception as e:
            self.send_response(502); self.end_headers()
            self.wfile.write(("502 Bad Gateway: bad upstream response (%s)\n"
                              % type(e).__name__).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8060), P).serve_forever()
EOF
nohup python3 catalog.py >/dev/null 2>&1 & echo $! > pids
nohup python3 orders.py  >/dev/null 2>&1 & echo $! >> pids
nohup python3 proxy.py   >/dev/null 2>&1 & echo $! >> pids
```

**Situation:** after tonight's deploy, both `/catalog` and `/orders` fail through the load balancer (port 8060) — and the postmortem draft already says "the ALB is broken." It isn't: the two paths fail with **different status codes for different reasons**, and the fastest discriminator on call is not the code but the **time-to-failure**. Your job: prove the LB innocent, classify both failures like an ALB access log would, and fix both.

**Your task:**
- Through the proxy, capture code **and** timing for both paths: `curl -s -o /dev/null -w 'code=%{http_code} time=%{time_total}s\n' http://localhost:8060/catalog` (and `/orders`). One fails near-instantly, one at ~3s (the proxy's timeout). Write down which is 502 and which is 504 *before* looking at the backends.
- Go direct to 8061 (`/catalog`): plain `curl -s http://localhost:8061/catalog; echo $?` exits **18** — read the `-sS` error text ("...bytes missing"): the backend advertised a `Content-Length` and closed early. That broken promise is what the proxy converts into **502** ("bad response" — the other half of 502 besides "couldn't connect", which was Muscat).
- Go direct to 8062 (`/orders`): first prove with `nc -vz 127.0.0.1 8062` that TCP connects **instantly** — so this is not connectivity — then time the request and watch it take ~10s, three times the proxy's 3s budget → **504**.
- Fix both regressions (each is a flag file — `rm` them) and re-verify through the proxy.
- Close with the ALB sentence from Rung 3: 502 = "couldn't connect **or** bad response", 504 = "connected but it never answered in time."

**Project link:** the ALB 502-vs-504 triage row (S11/S16, Climb 8): 502 blames the target's *answer* (crashed mid-response, malformed reply, connection refused), 504 blames the target's *clock* (healthy but slower than the idle timeout — usually a slow downstream like a cold database). Reading `time_total` against the LB's timeout setting is exactly how you split them in CloudWatch.

**Verify:**

```bash
curl -s -o /dev/null -w '/catalog code=%{http_code} time=%{time_total}s\n' http://localhost:8060/catalog
curl -s -o /dev/null -w '/orders  code=%{http_code} time=%{time_total}s\n' http://localhost:8060/orders
# expected: both code=200, each well under 1 second
curl -s http://localhost:8061/catalog >/dev/null; echo "direct catalog exit=$?"
# expected: direct catalog exit=0   (the Content-Length promise is kept again)
```

### Climb 5 — TLS, Certificates & mTLS: Trust on the Wire

Six trust failures — self-signed, expired, misnamed, chain-broken, and identity-checked both ways — each reproduced with nothing but `openssl` and `curl`, each mapping to a real object in the project (ACM on the ALB, Argo CD's default cert, Istio STRICT mTLS). Reminder: lab CAs are trusted **only** via `--cacert`/`-CAfile`, never installed system-wide.

#### 🟢 Scenario 5.1 — "Tbilisi: --insecure on localhost, and why it's fine here" (Easy)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-tbilisi
cd /opt/lab-tbilisi
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 30 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
nohup openssl s_server -accept 8443 -cert cert.pem -key key.pem -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** you just port-forwarded a freshly installed Argo CD–style service to `localhost:8443`. Like Argo CD out of the box (S21), it serves HTTPS with a **self-signed** certificate — vouched for by nobody but itself. Plain `curl` refuses it, the docs say "use `--insecure`," and your security-conscious teammate asks: *"isn't that exactly what we tell people never to do?"* Settle it with evidence.

**Your task:**
- Run the three curls and record each outcome: `curl https://localhost:8443/` (refused — which exit code, and which of the three verification checks failed?), `curl -k https://localhost:8443/` (works — but what property did you give up?), `curl --cacert /opt/lab-tbilisi/cert.pem https://localhost:8443/` (works — why is this one *fully* verified?).
- Inspect what the server presents: `echo | openssl s_client -connect localhost:8443 2>/dev/null | openssl x509 -noout -subject -issuer` — subject and issuer are the **same** line: the definition of self-signed.
- Write the one-sentence rule: when is `-k`/`--insecure` acceptable, and what makes localhost the special case? (Hint: who can sit on the path between you and 127.0.0.1?)
- Note what you did **not** do: install `cert.pem` into the system trust store. Say why `--cacert` (scoped, per-command trust) is the right tool for a lab CA.

**Project link:** `argocd login localhost:8080 --insecure` (S21) is exactly this lab: a self-signed service you port-forwarded yourself, over loopback. The same flag against the production ALB would hand your session to any on-path interceptor — that's the Climb 5 check-yourself answer, now proven by hand.

**Verify:**

```bash
curl -s https://localhost:8443/ >/dev/null; echo "default exit=$?"
# expected: default exit=60   (chain doesn't end in any store curl holds)
curl -sk https://localhost:8443/ | head -1
# expected: an HTML line from s_server — encrypted but UNAUTHENTICATED
curl -s --cacert /opt/lab-tbilisi/cert.pem https://localhost:8443/ | head -1
# expected: the same HTML line — fully verified against the cert you pinned
```

#### 🟢 Scenario 5.2 — "Yerevan: check the dates first: reading a chain like an SRE" (Easy)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-yerevan
cd /opt/lab-yerevan
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 90 \
  -subj "/CN=Lab Root CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout cart.key -out cart.csr \
  -subj "/CN=cart.devopsinminutes.com" 2>/dev/null
openssl x509 -req -in cart.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 20 \
  -extfile <(echo "subjectAltName=DNS:cart.devopsinminutes.com,DNS:localhost") \
  -out cart.crt 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout catalog.key -out catalog.csr \
  -subj "/CN=catalog.devopsinminutes.com" 2>/dev/null
openssl x509 -req -in catalog.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 \
  -extfile <(echo "subjectAltName=DNS:catalog.devopsinminutes.com,DNS:localhost") \
  -out catalog.crt 2>/dev/null
nohup openssl s_server -accept 8444 -cert cart.crt -key cart.key -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** you inherit a small fleet: one live TLS endpoint on port 8444 and a directory of certificate files nobody has audited. Expiry is the #1 TLS outage ("nothing changed but everything broke"), so the SRE habit is: **read the dates first**, and do it with commands a cron job could run — exit codes, not eyeballs. One of these certs needs a renewal ticket filed *this sprint*. Find it.

**Your task:**
- Interrogate the live endpoint the standard way: `echo | openssl s_client -connect localhost:8444 -CAfile /opt/lab-yerevan/ca.crt 2>/dev/null | openssl x509 -noout -subject -issuer -dates` — whose cert is served, who vouches for it, and when does it die? Also grep the s_client output for `Verify return code` (with `-CAfile` pointing at the lab CA it should be `0 (ok)`).
- Audit the files with the machine-readable check: `openssl x509 -in <crt> -noout -checkend $((30*24*3600))` for both `cart.crt` and `catalog.crt`. Exit 1 = "will expire within the window" = file the ticket. This exit code is exactly what monitoring wraps.
- Also run `-checkend 0` on both ("is it expired *right now*?") and note both pass — the point is catching expiry **before** it happens.
- State the habit: whenever anything TLS "suddenly" fails, `-dates` first, everything else second.

**Project link:** ACM's whole job (S16) is making this audit unnecessary at the edge — auto-renewal, DNS-validated via the Route 53 record. But Argo CD's cert, chart-repo endpoints, webhook receivers, and anything self-managed still need exactly this `-dates`/`-checkend` loop — and istiod rotates its short-lived workload certs (S22) so aggressively precisely so nobody has to run it for the mesh.

**Verify:**

```bash
openssl x509 -in /opt/lab-yerevan/cart.crt -noout -checkend $((30*24*3600)); echo "cart exit=$?"
# expected: "Certificate will expire" and cart exit=1   (inside the 30-day window -> ticket)
openssl x509 -in /opt/lab-yerevan/catalog.crt -noout -checkend $((30*24*3600)); echo "catalog exit=$?"
# expected: "Certificate will not expire" and catalog exit=0
echo | openssl s_client -connect localhost:8444 -CAfile /opt/lab-yerevan/ca.crt 2>/dev/null | grep 'Verify return code'
# expected: Verify return code: 0 (ok)
```

#### 🟡 Scenario 5.3 — "Baku: the cert for the shop that got renamed" (Medium)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-baku
cd /opt/lab-baku
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 90 \
  -subj "/CN=Lab Root CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout shop.key -out shop.csr \
  -subj "/CN=old-shop.devopsinminutes.com" 2>/dev/null
openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 \
  -extfile <(echo "subjectAltName=DNS:old-shop.devopsinminutes.com") -out shop.crt 2>/dev/null
nohup openssl s_server -accept 8445 -cert shop.crt -key shop.key -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** marketing renamed the storefront from `old-shop.devopsinminutes.com` to `retail.devopsinminutes.com`. DNS was moved, the app was redeployed — but monitoring went red with SSL errors, and the responder is confused: *"the cert can't be the problem, I checked, it's valid for months!"* Valid dates, trusted CA… and still failing. The third verification check is the one everyone forgets: does the cert's **name** match the name the client asked for?

**Your task:**
- Reproduce exactly what monitoring sees (use `--resolve` to stand in for the moved DNS): `curl --cacert /opt/lab-baku/ca.crt --resolve retail.devopsinminutes.com:8445:127.0.0.1 https://retail.devopsinminutes.com:8445/` — capture the exit code (60).
- Get the *precise* complaint with `-v`: `no alternative certificate subject name matches target hostname 'retail.devopsinminutes.com'`. Then look at what the cert actually covers: `openssl x509 -in /opt/lab-baku/shop.crt -noout -ext subjectAltName` — modern clients match against **SAN entries only**; the CN is ignored.
- Fix it the way ACM would (reissue for the new name — the CA key is on this box, playing ACM's role): create a CSR for `retail.devopsinminutes.com`, sign it with the lab CA **including the new SAN**, save it as `retail.crt`/`retail.key`, restart `s_server` with the new pair (kill the old one via `/opt/lab-baku/pids`, then append the new PID).
- Say why `-k` would have "fixed" monitoring and been exactly the wrong call.

**Project link:** the ACM certificate on the ALB (S16) covers specific names; rename the site (or add a hostname to the Ingress/Istio Gateway) without reissuing/adding a SAN and every client fails verification exactly like this. The `s_server` + lab CA pair here is the ALB + ACM pair there — and DNS-validated reissue in ACM is the production version of the CSR you just signed.

**Verify:**

```bash
curl -s --cacert /opt/lab-baku/ca.crt \
  --resolve retail.devopsinminutes.com:8445:127.0.0.1 \
  https://retail.devopsinminutes.com:8445/ >/dev/null; echo "exit=$?"
# expected: exit=0
openssl x509 -in /opt/lab-baku/retail.crt -noout -ext subjectAltName
# expected: DNS:retail.devopsinminutes.com
```

#### 🟡 Scenario 5.4 — "Samarkand: the certificate that expired at midnight" (Medium)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-samarkand
cd /opt/lab-samarkand
mkdir -p ca/newcerts && touch ca/index.txt && echo 1000 > ca/serial
echo "unique_subject = no" > ca/index.txt.attr   # let the CA re-issue for the same name (renewals)
cat > ca/openssl.cnf <<'CNF'
[ ca ]
default_ca = lab_ca
[ lab_ca ]
dir              = /opt/lab-samarkand/ca
database         = $dir/index.txt
new_certs_dir    = $dir/newcerts
serial           = $dir/serial
certificate      = $dir/ca.crt
private_key      = $dir/ca.key
default_md       = sha256
policy           = lab_policy
x509_extensions  = leaf_ext
copy_extensions  = copy
[ lab_policy ]
commonName = supplied
[ leaf_ext ]
basicConstraints = CA:FALSE
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca/ca.key -out ca/ca.crt -days 90 \
  -subj "/CN=Lab Root CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
# sign with a validity window entirely in the PAST — the portable way to mint an expired cert
openssl ca -config ca/openssl.cnf -batch -notext \
  -startdate 20240101000000Z -enddate 20250101000000Z \
  -in leaf.csr -out leaf.crt 2>/dev/null
nohup openssl s_server -accept 8446 -cert leaf.crt -key leaf.key -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** the classic: *nothing was deployed, nothing was changed, and at 00:00 the payments-callback endpoint (port 8446) went red everywhere at once.* Simultaneous failure across every client with zero changes has a one-item differential diagnosis. You drilled the habit in Yerevan — now run it under fire, and then actually perform the renewal.

**Your task:**
- Dates first: `echo | openssl s_client -connect localhost:8446 2>/dev/null | openssl x509 -noout -dates` — read `notAfter`.
- Confirm all three verdict forms an SRE meets: `s_client -CAfile ca/ca.crt` → `Verify return code: 10 (certificate has expired)`; `openssl x509 -in leaf.crt -noout -checkend 0` → "Certificate will expire", exit 1; `curl --cacert ca/ca.crt https://localhost:8446/` → exit 60.
- Renew: the CSR is still on disk — sign it again with a *future* window: `openssl ca -config ca/openssl.cnf -batch -notext -days 30 -in leaf.csr -out leaf-renewed.crt`. Confirm the new dates and the copied SAN (`-ext subjectAltName` — `copy_extensions = copy` carried it from the CSR).
- Swap the cert: kill the old `s_server` (PID in `/opt/lab-samarkand/pids`), start it with `leaf-renewed.crt` + the same `leaf.key`, append the new PID. Verify code 0 and curl exit 0.

**Project link:** expiry is why ACM exists: the ALB's cert (S16) auto-renews because ACM re-proves domain ownership via the Route 53 validation record — the automated version of the `openssl ca` re-sign you just did. istiod goes further (S22): workload certs live hours, not years, so rotation is constant and an "expired at midnight" page is structurally impossible in the mesh.

**Verify:**

```bash
echo | openssl s_client -connect localhost:8446 -CAfile /opt/lab-samarkand/ca/ca.crt 2>/dev/null | grep 'Verify return code'
# expected: Verify return code: 0 (ok)
curl -s --cacert /opt/lab-samarkand/ca/ca.crt https://localhost:8446/ >/dev/null; echo "exit=$?"
# expected: exit=0
openssl x509 -in /opt/lab-samarkand/leaf-renewed.crt -noout -checkend 0 && echo VALID
# expected: "Certificate will not expire" and VALID
```

#### 🟠 Scenario 5.5 — "Almaty: the missing link: works in curl, fails in the browser" (Hard)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-almaty
cd /opt/lab-almaty
openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 90 \
  -subj "/CN=Lab Root CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr \
  -subj "/CN=Lab Intermediate CA" 2>/dev/null
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -days 90 \
  -extfile <(echo "basicConstraints=CA:TRUE,pathlen:0") -out int.crt 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
openssl x509 -req -in leaf.csr -CA int.crt -CAkey int.key -CAcreateserial -days 90 \
  -extfile <(echo "subjectAltName=DNS:localhost") -out leaf.crt 2>/dev/null
cat root.crt int.crt > ops-bundle.pem   # the extra-fat CA bundle the ops laptop curls with
# tonight's deploy: serves the LEAF ONLY — the intermediate never made it into the config
nohup openssl s_server -accept 8447 -cert leaf.crt -key leaf.key -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** deploy night. The ops smoke test is green — `curl --cacert ops-bundle.pem https://localhost:8447/` returns 200 — so the change ships. Then customers (whose browsers and OSes trust only the **root**) start reporting security warnings. "Works in curl, fails in the browser": the ops bundle happens to contain the intermediate CA, so *the client was quietly completing the server's homework*. Real clients hold roots, not intermediates — and this server sends a chain with a missing link.

**Your task:**
- Reproduce both realities: `curl --cacert ops-bundle.pem https://localhost:8447/` (works) vs `curl --cacert root.crt https://localhost:8447/` (exit 60 — the customer experience). Two commands, one server: the difference is purely which certs the *client* brought.
- Diagnose on the wire: `echo | openssl s_client -connect localhost:8447 -CAfile /opt/lab-almaty/root.crt 2>/dev/null | grep 'Verify return code'` → **21 (unable to verify the first certificate)** — the signature says "unable to build a path from the leaf to your root." Count what the server actually sends: `echo | openssl s_client -connect localhost:8447 2>/dev/null | grep -c 'BEGIN CERT'` → 1 cert, no chain.
- Diagnose offline (no server needed — the portable technique): `openssl verify -CAfile root.crt leaf.crt` fails ("unable to get local issuer certificate"), but `openssl verify -CAfile root.crt -untrusted int.crt leaf.crt` → `OK`. Translation: *the leaf is fine; the chain the server serves is incomplete.* `-untrusted` = "here are intermediates you may use for path-building without trusting them as roots."
- Fix the server, not the clients: restart `s_server` with the intermediate attached — `-cert leaf.crt -key leaf.key -cert_chain int.crt` (kill the old PID from `/opt/lab-almaty/pids`, append the new). This is "install the fullchain, not the cert."
- Re-verify: code 21 → `0 (ok)`, and `curl --cacert root.crt` now succeeds — clients holding only the root are happy.

**Project link:** the eternal "works on my machine" TLS ticket. Servers must serve **leaf + intermediates** (the `fullchain.pem` every ACME client nags about); clients hold roots. ACM handles this invisibly on the ALB (S16) — it deploys the full chain for you — which is why you meet this bug on self-managed endpoints (webhook receivers, chart repos, S12/S21) and almost never at the ALB. Browsers sometimes mask it by fetching intermediates themselves; a strict client like curl-with-only-a-root tells the truth.

**Verify:**

```bash
echo | openssl s_client -connect localhost:8447 -CAfile /opt/lab-almaty/root.crt 2>/dev/null | grep 'Verify return code'
# expected: Verify return code: 0 (ok)
curl -s --cacert /opt/lab-almaty/root.crt https://localhost:8447/ >/dev/null; echo "root-only exit=$?"
# expected: root-only exit=0
echo | openssl s_client -connect localhost:8447 2>/dev/null | grep -c 'BEGIN CERT'
# expected: 2   (leaf + intermediate now both on the wire)
```

#### 🔴 Scenario 5.6 — "Bishkek: same name, wrong CA: the sidecar that lied" (Expert)

**Setup:**

```bash
sudo install -d -o "$(id -un)" /opt/lab-bishkek
cd /opt/lab-bishkek
# istiod analogue: the mesh CA that issues every sidecar's identity
openssl req -x509 -newkey rsa:2048 -nodes -keyout mesh-ca.key -out mesh-ca.crt -days 90 \
  -subj "/CN=Mesh CA (istiod)" 2>/dev/null
# checkout's receiving sidecar (server side of the mTLS pair)
openssl req -newkey rsa:2048 -nodes -keyout checkout.key -out checkout.csr \
  -subj "/CN=checkout.default.svc" 2>/dev/null
openssl x509 -req -in checkout.csr -CA mesh-ca.crt -CAkey mesh-ca.key -CAcreateserial -days 90 \
  -extfile <(echo "subjectAltName=DNS:localhost") -out checkout.crt 2>/dev/null
# ui's sidecar: a legitimate mesh workload identity
openssl req -newkey rsa:2048 -nodes -keyout ui.key -out ui.csr \
  -subj "/CN=ui.default.svc" 2>/dev/null
openssl x509 -req -in ui.csr -CA mesh-ca.crt -CAkey mesh-ca.key -CAcreateserial -days 90 \
  -out ui.crt 2>/dev/null
# an attacker who KNOWS the right name but holds the wrong CA
openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue-ca.key -out rogue-ca.crt -days 90 \
  -subj "/CN=Rogue CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout rogue.key -out rogue.csr \
  -subj "/CN=ui.default.svc" 2>/dev/null
openssl x509 -req -in rogue.csr -CA rogue-ca.crt -CAkey rogue-ca.key -CAcreateserial -days 90 \
  -out rogue.crt 2>/dev/null
# STRICT mode: demand a client cert signed by the mesh CA, or hang up mid-handshake
nohup openssl s_server -accept 8448 -cert checkout.crt -key checkout.key \
  -CAfile mesh-ca.crt -Verify 2 -verify_return_error -www >/dev/null 2>&1 &
echo $! > pids
```

**Situation:** the platform team flipped the mesh's `PeerAuthentication` to **STRICT** (S22): checkout's sidecar (port 8448) now demands that every caller *prove its identity by certificate* — the same three checks as normal TLS, run in reverse, against the mesh CA. Two tickets land at once: a legacy cron VM *outside* the mesh "suddenly can't call checkout," and a pentest report claims mTLS is bypassable because "we minted a certificate with the exact same name, `ui.default.svc`." Run the full three-way matrix and settle both tickets with handshake evidence.

**Your task:**
- **Case A — no client cert (the legacy cron VM):** `curl --cacert mesh-ca.crt https://localhost:8448/` → exit 56, and the `-sS` error text names the TLS alert `certificate required`. The server's TLS is fine — the *caller* failed the identity check. Confirm with `echo | openssl s_client -connect localhost:8448 -CAfile mesh-ca.crt` and find the alert in the output.
- **Case B — legitimate mesh identity:** `curl -s -o /dev/null -w 'code=%{http_code}\n' --cacert mesh-ca.crt --cert ui.crt --key ui.key https://localhost:8448/` → **200**. Both directions verified: you checked checkout's cert against the mesh CA; checkout checked yours.
- **Case C — the pentester's cert: same name, wrong CA:** `curl --cacert mesh-ca.crt --cert rogue.crt --key rogue.key https://localhost:8448/` → exit 56 again, alert `unknown ca`. The name `ui.default.svc` bought the attacker **nothing**: the server never asks "what are you called?", it asks "**who signed you?**" — and only the mesh CA's signature counts.
- Write the two ticket replies: (A) the cron VM isn't broken, it's *outside the trust domain* — it needs a mesh-issued identity (or a mesh entry point), not a firewall change; (C) the pentest claim is false — identity in mTLS is the CA's signature, not the subject string, which is exactly why S22 argues "a NetworkPolicy knows spoofable IPs; mTLS knows cryptographic identity."

**Project link:** the paired `s_server`/`s_client` with `-Verify` is two Envoy sidecars under Istio STRICT `PeerAuthentication` (S22): `-CAfile mesh-ca.crt -Verify 2` = the sidecar validating peers against istiod's CA; `CN=ui.default.svc` plays the SPIFFE ServiceAccount identity (`spiffe://cluster.local/ns/default/sa/ui`) that `AuthorizationPolicy` matches; Case A is every non-mesh workload the day STRICT lands; Case C is why the mesh survives IP spoofing and name games that would beat any IP allow-list.

**Verify:**

```bash
curl -s --cacert /opt/lab-bishkek/mesh-ca.crt https://localhost:8448/ >/dev/null; echo "no-cert exit=$?"
# expected: no-cert exit=56   (handshake rejected: certificate required)
curl -s -o /dev/null -w 'mesh-identity code=%{http_code}\n' \
  --cacert /opt/lab-bishkek/mesh-ca.crt \
  --cert /opt/lab-bishkek/ui.crt --key /opt/lab-bishkek/ui.key https://localhost:8448/
# expected: mesh-identity code=200
curl -s --cacert /opt/lab-bishkek/mesh-ca.crt \
  --cert /opt/lab-bishkek/rogue.crt --key /opt/lab-bishkek/rogue.key \
  https://localhost:8448/ >/dev/null; echo "rogue exit=$?"
# expected: rogue exit=56   (alert: unknown ca — the name didn't matter)
```


### Climb 6 — Routing, Gateways & NAT: How Private Things Reach the World

> Local analogue: a mini-"VPC" built from `ip netns` + `veth` + a `lab0` bridge. Router namespaces play NAT Gateways (`iptables MASQUERADE`), `ip route` tables are the S06 route tables, `sysctl net.ipv4.ip_forward` is the "is this box even a router?" switch. Lab CIDR `10.99.0.0/16` stands in for the course's `10.0.0.0/16`. Every scenario that touches global state has a **Cleanup:** line in its answer.

#### 🟢 Scenario 6.1 — "Seoul: an IP is not a way out" (Easy)
**Setup:**
```bash
sudo ip netns add labns-seoul
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.11.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
sudo ip link add labveth-seoul type veth peer name labveth-seoulb
sudo ip link set labveth-seoul master lab0
sudo ip link set labveth-seoul up
sudo ip link set labveth-seoulb netns labns-seoul
sudo ip netns exec labns-seoul ip link set lo up
sudo ip netns exec labns-seoul ip link set labveth-seoulb up
sudo ip netns exec labns-seoul ip addr add 10.99.11.57/24 dev labveth-seoulb
# NOTE: the "private node" has an address but NO default route
```
**Situation:** A freshly-provisioned private-subnet node (`10.99.11.57`, mirroring an EKS worker in `10.0.11.0/24`) got its interface and IP but cannot pull any ECR image. It can reach its own subnet neighbours, nothing else. Its route table has no `0.0.0.0/0` line.

**Your task:** Give `labns-seoul` a default route out via the subnet's gateway (`10.99.11.1`, the `lab0` bridge = the "router" address) so an internet-bound lookup names a next hop instead of failing `unreachable`.

**Project link:** S06–07 private-subnet route table — the `0.0.0.0/0 → NAT GW` line that makes "private" mean "private, not isolated."

**Verify:**
```bash
sudo ip netns exec labns-seoul ip route get 8.8.8.8   # expected: "via 10.99.11.1 dev labveth-seoulb", not "unreachable"
```

#### 🟢 Scenario 6.2 — "Busan: longest prefix always wins" (Easy)
**Setup:**
```bash
sudo ip netns add labns-busan
sudo ip netns exec labns-busan ip link set lo up
sudo ip netns exec labns-busan ip link add dummy0 type dummy
sudo ip netns exec labns-busan ip link set dummy0 up
sudo ip netns exec labns-busan ip addr add 10.99.11.60/24 dev dummy0
sudo ip netns exec labns-busan ip route add default via 10.99.11.1 dev dummy0
sudo ip netns exec labns-busan ip route add 10.99.0.0/16 dev dummy0 scope link 2>/dev/null || true
# Two candidate routes now exist: a /16 "local" and a /0 "default"
```
**Situation:** East-west traffic between microservices (ui → catalog, both inside `10.99.0.0/16`) must never take the NAT-Gateway path — that would be nonsense latency and cost. You must prove the kernel already does this by longest-prefix match, exactly like `10.0.0.0/16 local` beating `0.0.0.0/0` in the S06 tables.

**Your task:** Without changing any route, predict then confirm which exit the kernel chooses for a VPC-internal destination (`10.99.12.9`) versus an internet destination (`1.1.1.1`).

**Project link:** S06 Rung 3 — "longest prefix wins: `10.0.0.0/16 local` beats `0.0.0.0/0`, so east-west never touches the NAT GW."

**Verify:**
```bash
sudo ip netns exec labns-busan ip route get 10.99.12.9   # expected: matched by 10.99.0.0/16 (link route, NO gateway)
sudo ip netns exec labns-busan ip route get 1.1.1.1      # expected: "via 10.99.11.1" (the default / "NAT" path)
```

#### 🟡 Scenario 6.3 — "Incheon: the router that refuses to route" (Medium)
**Setup:**
```bash
sudo ip netns add labns-incheon-node
sudo ip netns add labns-incheon-rtr
sudo ip link add labveth-inca type veth peer name labveth-incb
sudo ip link set labveth-inca netns labns-incheon-node
sudo ip link set labveth-incb netns labns-incheon-rtr
sudo ip netns exec labns-incheon-node ip link set lo up
sudo ip netns exec labns-incheon-rtr ip link set lo up
sudo ip netns exec labns-incheon-node ip addr add 10.99.11.57/24 dev labveth-inca
sudo ip netns exec labns-incheon-node ip link set labveth-inca up
sudo ip netns exec labns-incheon-rtr ip addr add 10.99.11.1/24 dev labveth-incb
sudo ip netns exec labns-incheon-rtr ip link set labveth-incb up
sudo ip netns exec labns-incheon-node ip route add default via 10.99.11.1
# A second "downstream" leg on the router, plus a loopback target to reach through it
sudo ip netns exec labns-incheon-rtr ip addr add 192.0.2.1/32 dev lo
# ip_forward is 0 by default inside a fresh netns → the router drops transit packets
```
**Situation:** The node has a perfect default route to the router, the router has both legs — yet packets aimed *through* the router to `192.0.2.1` die. Someone stood up a "NAT instance" but never told the kernel it is allowed to be a router.

**Your task:** Make `labns-incheon-rtr` actually forward transit traffic so the node can reach `192.0.2.1`, then reverse it in cleanup.

**Project link:** S07 — a NAT box (or any forwarding node) is inert until `net.ipv4.ip_forward=1`; the same knob the VPC/CNI relies on for pod traffic.

**Verify:**
```bash
sudo ip netns exec labns-incheon-rtr sysctl net.ipv4.ip_forward   # expected AFTER fix: net.ipv4.ip_forward = 1
sudo ip netns exec labns-incheon-node ping -c1 -W2 192.0.2.1      # expected AFTER fix: 1 received
```

#### 🟡 Scenario 6.4 — "Jeju: replies that can't find their way home" (Medium)
**Setup:**
```bash
sudo ip netns add labns-jeju
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.11.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
sudo ip link add labveth-jeju type veth peer name labveth-jejub
sudo ip link set labveth-jeju master lab0
sudo ip link set labveth-jeju up
sudo ip link set labveth-jejub netns labns-jeju
sudo ip netns exec labns-jeju ip link set lo up
sudo ip netns exec labns-jeju ip link set labveth-jejub up
sudo ip netns exec labns-jeju ip addr add 10.99.11.57/24 dev labveth-jejub
sudo ip netns exec labns-jeju ip route add default via 10.99.11.1
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
# The host forwards, but there is NO MASQUERADE: the node's 10.99.11.57 source
# leaves as-is and any real upstream cannot route a reply back to RFC1918.
```
**Situation:** The private node can now hand packets to the host-router, and forwarding is on — but an outbound `curl` to an external service still hangs. Its private `10.99.11.57` source address goes out unmasqueraded; the far side has no route back to RFC1918 space. This is a NAT Gateway with the SNAT rule missing.

**Your task:** Add a scoped `MASQUERADE` (SNAT) rule in a dedicated `LAB-JEJU` chain so the node's source is rewritten to the host's address on egress — the NAT-Gateway move — and fully remove it in cleanup.

**Project link:** S06 Rung 3 SNAT — "NAT GW rewrites src `10.0.11.57` → its Elastic IP, remembers the flow"; Docker's `POSTROUTING` MASQUERADE is the same rule.

**Verify:**
```bash
sudo iptables -t nat -S LAB-JEJU               # expected: a MASQUERADE rule for source 10.99.11.0/24
sudo ip netns exec labns-jeju ping -c1 -W2 10.99.11.1   # expected: reaches the gateway leg (sanity)
```

#### 🟠 Scenario 6.5 — "Daegu: the front door nobody rewrote (DNAT)" (Hard)
**Setup:**
```bash
sudo ip netns add labns-daegu
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.11.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
sudo ip link add labveth-daegu type veth peer name labveth-daegub
sudo ip link set labveth-daegu master lab0
sudo ip link set labveth-daegu up
sudo ip link set labveth-daegub netns labns-daegu
sudo ip netns exec labns-daegu ip link set lo up
sudo ip netns exec labns-daegu ip link set labveth-daegub up
sudo ip netns exec labns-daegu ip addr add 10.99.11.213/24 dev labveth-daegub
sudo ip netns exec labns-daegu ip route add default via 10.99.11.1
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
# A "pod" backend listens inside the namespace on 8080, but nothing on the host maps a front port to it:
sudo ip netns exec labns-daegu sh -c 'python3 -m http.server 8080 >/dev/null 2>&1 &'
# Front address 10.99.11.1:8888 currently goes nowhere.
```
**Situation:** The catalog "pod" answers on `10.99.11.213:8080` inside its namespace, but clients only know the front address `10.99.11.1:8888` (think NodePort / ClusterIP). Right now hitting `8888` on the host is refused — there is no destination rewrite. You must build the DNAT that a published port / Service VIP performs.

**Your task:** In a dedicated `LAB-DAEGU` chain on the `nat` table, DNAT host-arriving `:8888` to `10.99.11.213:8080`, ensuring the return path works, so `curl 10.99.11.1:8888` serves the pod. Reverse everything in cleanup.

**Project link:** S06 Rung 3 DNAT — "dst `172.20.44.7:80` (ClusterIP) → kube-proxy iptables rewrite → dst `10.0.11.213:8080` (a pod)"; `-p 8888:8080` is this same rewrite.

**Verify:**
```bash
sudo iptables -t nat -S LAB-DAEGU                       # expected: a DNAT rule :8888 → 10.99.11.213:8080
curl -s --max-time 3 http://10.99.11.1:8888/ | head -1  # expected: an HTTP directory listing line (the pod answered)
```

#### 🔴 Scenario 6.6 — "Taipei: the whole VPC, and it's all broken" (Expert)
**Setup:**
```bash
# Public "subnet" gets a fake internet endpoint; private "subnet" node must reach it, outbound-only.
sudo ip netns add labns-taipei-priv
sudo ip netns add labns-taipei-nat
sudo ip netns add labns-taipei-net       # plays "the internet / ECR"
# priv <-> nat link (private subnet leg)
sudo ip link add labveth-tpa type veth peer name labveth-tpb
sudo ip link set labveth-tpa netns labns-taipei-priv
sudo ip link set labveth-tpb netns labns-taipei-nat
# nat <-> net link (public / IGW leg)
sudo ip link add labveth-tpc type veth peer name labveth-tpd
sudo ip link set labveth-tpc netns labns-taipei-nat
sudo ip link set labveth-tpd netns labns-taipei-net
for NS in labns-taipei-priv labns-taipei-nat labns-taipei-net; do sudo ip netns exec $NS ip link set lo up; done
sudo ip netns exec labns-taipei-priv ip addr add 10.99.11.57/24 dev labveth-tpa
sudo ip netns exec labns-taipei-priv ip link set labveth-tpa up
sudo ip netns exec labns-taipei-nat ip addr add 10.99.11.1/24 dev labveth-tpb
sudo ip netns exec labns-taipei-nat ip link set labveth-tpb up
sudo ip netns exec labns-taipei-nat ip addr add 203.0.113.1/24 dev labveth-tpc
sudo ip netns exec labns-taipei-nat ip link set labveth-tpc up
sudo ip netns exec labns-taipei-net ip addr add 203.0.113.9/24 dev labveth-tpd
sudo ip netns exec labns-taipei-net ip link set labveth-tpd up
sudo ip netns exec labns-taipei-priv ip route add default via 10.99.11.1
# "ECR" listens on the public side:
sudo ip netns exec labns-taipei-net sh -c 'python3 -m http.server 8443 >/dev/null 2>&1 &'
# DELIBERATELY LEFT BROKEN: nat ns has ip_forward=0 AND no MASQUERADE; net ns has no route back to 10.99/16.
```
**Situation:** The full picture: a private node (`10.99.11.57`), a NAT namespace with two legs (private `10.99.11.1` + "public" `203.0.113.1`), and an "ECR/internet" endpoint (`203.0.113.9:8443`). The private node must pull from ECR. Nothing works: forwarding is off in the NAT ns, there is no SNAT so `203.0.113.9` can't reply to an RFC1918 source, and — critically — the internet endpoint must **never** be able to initiate a connection inward.

**Your task:** Make `labns-taipei-priv` reach `http://203.0.113.9:8443/` through the NAT namespace: enable forwarding in the NAT ns, add a scoped `MASQUERADE` (in a `LAB-TAIPEI` chain) rewriting `10.99.11.0/24` to `203.0.113.1`, and confirm the flow is outbound-only (conntrack shows the SNAT mapping; the net side cannot start one back). Fully reverse in cleanup.

**Project link:** S07/S21 Rung 5 trace — a private node pulling the ui image from ECR: routing falls to `0.0.0.0/0 → NAT GW`, NAT SNATs the source, conntrack maps the reply back, and nobody on the internet can initiate inward.

**Verify:**
```bash
sudo ip netns exec labns-taipei-priv curl -s --max-time 4 http://203.0.113.9:8443/ | head -1  # expected: an HTTP listing line
sudo ip netns exec labns-taipei-nat conntrack -L 2>/dev/null | grep 8443 | head -1            # expected: a tracked flow showing src rewritten to 203.0.113.1
sudo ip netns exec labns-taipei-net curl -s --max-time 3 http://10.99.11.57:8080/ ; echo "exit=$?"  # expected: non-zero exit — internet CANNOT initiate inward
```

---

### Climb 7 — Firewalls: Security Groups & NACLs

> Local analogue: `iptables` LAB-* chains are the firewall. Stateful (`-m conntrack --ctstate ESTABLISHED,RELATED`) = a **security group**; stateless (evaluate every packet, no conntrack) = a **NACL**. A source-IP match standing in for "only from the cluster SG." `nc`/`ss` reproduce the S14 "refused vs timeout" split. Everything is scoped to dedicated LAB-* chains and reversed in **Cleanup:**.

#### 🟢 Scenario 7.1 — "Kaohsiung: the two failures that mean opposite things" (Easy)
**Setup:**
```bash
sudo iptables -N LAB-KAOHSIUNG 2>/dev/null || true
sudo iptables -C INPUT -p tcp -j LAB-KAOHSIUNG 2>/dev/null || sudo iptables -I INPUT -p tcp -j LAB-KAOHSIUNG
sudo iptables -A LAB-KAOHSIUNG -p tcp --dport 8080 -j DROP
# Port 8099 has no listener; port 8080 is silently DROPped by the "wrong SG"
```
**Situation:** An S14 ticket says "catalog can't reach the DB." You must teach yourself the one-word triage before touching any config: a closed port answers instantly (`refused`), a firewall DROP hangs to timeout (`timeout`). Port `8099` is simply closed; port `8080` is being DROPped like a mis-scoped security group.

**Your task:** Probe both ports and record which gives `connection refused` (instant) and which gives a `timeout` (silent ~3s). Do not fix anything yet — just classify.

**Project link:** S14/S19 troubleshooting split — "connection refused = listener problem; connection timed out = filter/route problem."

**Verify:**
```bash
nc -zv -w3 127.0.0.1 8099 2>&1 | tail -1                 # expected: "refused" instantly (no listener)
time nc -zv -w3 127.0.0.1 8080 2>&1 | tail -1            # expected: ~3s then "timed out" (the DROP = SG symptom)
```

#### 🟢 Scenario 7.2 — "Tainan: default-deny, then allow the one thing" (Easy)
**Setup:**
```bash
sudo useradd -r -s /usr/sbin/nologin labuser-tainan 2>/dev/null || true
sudo -u labuser-tainan sh -c 'python3 -m http.server 8081 >/dev/null 2>&1 &' 2>/dev/null || \
  sh -c 'python3 -m http.server 8081 >/dev/null 2>&1 &'
sleep 1
sudo iptables -N LAB-TAINAN 2>/dev/null || true
sudo iptables -C INPUT -p tcp --dport 8081 -j LAB-TAINAN 2>/dev/null || sudo iptables -I INPUT -p tcp --dport 8081 -j LAB-TAINAN
sudo iptables -A LAB-TAINAN -j DROP
# The app listens on 8081 but the chain's posture is deny-all: every SYN is dropped.
```
**Situation:** A backend is up and listening on `8081` (verify with `ss`), yet clients time out. The security group in front is default-deny with no allow rule — the AWS SG posture: "deny all ingress until you allow." You must add the single allow that opens exactly this port.

**Your task:** Insert an ACCEPT for tcp `8081` *above* the DROP in `LAB-TAINAN` so the listener becomes reachable, leaving everything else denied. Reverse in cleanup.

**Project link:** S14 Rung 3 — SGs deny all ingress until you allow; "the security group IS the auth boundary" for plain Redis.

**Verify:**
```bash
ss -ltnp 2>/dev/null | grep 8081                        # expected: LISTEN on 8081 (app was never the problem)
nc -zv -w3 127.0.0.1 8081 2>&1 | tail -1                # expected AFTER fix: "succeeded"/open
```

#### 🟡 Scenario 7.3 — "Shenzhen: stateful means replies ride free" (Medium)
**Setup:**
```bash
sudo iptables -N LAB-SHENZHEN 2>/dev/null || true
sudo iptables -C OUTPUT -p tcp -j LAB-SHENZHEN 2>/dev/null || sudo iptables -I OUTPUT -p tcp -j LAB-SHENZHEN
# Broken "NACL-style" egress: allow NEW connections to 9000, but nothing admits the returning replies.
sudo iptables -A LAB-SHENZHEN -p tcp --dport 9000 -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -A LAB-SHENZHEN -p tcp -j DROP
sh -c 'python3 -m http.server 9000 >/dev/null 2>&1 &'
sleep 1
```
**Situation:** A "checkout → redis" style egress rule allows the outbound SYN to port `9000` but was written stateless: it drops everything else, including the server's replies arriving on the client's ephemeral port. The connection half-opens and hangs — the classic NACL mistake of forgetting the return traffic.

**Your task:** Add the *one* stateful rule — `--ctstate ESTABLISHED,RELATED -j ACCEPT` — that a security group applies automatically, so replies of already-allowed flows sail through. Reverse in cleanup.

**Project link:** S14 Rung 3 — "reply redis → checkout:51844 (ephemeral): stateful → automatically allowed, no rule needed"; conntrack is the machinery behind "stateful."

**Verify:**
```bash
curl -s --max-time 3 http://127.0.0.1:9000/ | head -1   # expected AFTER fix: an HTTP listing line (reply admitted)
sudo iptables -S LAB-SHENZHEN | grep ESTABLISHED        # expected: the ctstate ESTABLISHED,RELATED ACCEPT rule
```

#### 🟡 Scenario 7.4 — "Chengdu: the source is a group, not a CIDR" (Medium)
**Setup:**
```bash
sudo ip netns add labns-chengdu-db
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.14.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
sudo ip link add labveth-cd type veth peer name labveth-cdb
sudo ip link set labveth-cd master lab0
sudo ip link set labveth-cd up
sudo ip link set labveth-cdb netns labns-chengdu-db
sudo ip netns exec labns-chengdu-db ip link set lo up
sudo ip netns exec labns-chengdu-db ip link set labveth-cdb up
sudo ip netns exec labns-chengdu-db ip addr add 10.99.14.50/24 dev labveth-cdb
sudo ip netns exec labns-chengdu-db sh -c 'python3 -m http.server 3306 >/dev/null 2>&1 &'
# "RDS SG" admits 3306 only from the WRONG source (a laptop CIDR), not the cluster:
sudo ip netns exec labns-chengdu-db iptables -N LAB-CHENGDU 2>/dev/null || true
sudo ip netns exec labns-chengdu-db iptables -I INPUT -p tcp --dport 3306 -j LAB-CHENGDU
sudo ip netns exec labns-chengdu-db iptables -A LAB-CHENGDU -s 192.168.7.0/24 -j ACCEPT
sudo ip netns exec labns-chengdu-db iptables -A LAB-CHENGDU -j DROP
```
**Situation:** This is S14 Lab C exactly: the "RDS MySQL" SG (here, the DB namespace's INPUT chain) admits `3306` only from `192.168.7.0/24` — someone's laptop CIDR — instead of from the cluster. The gateway/host source (`10.99.14.1`, our stand-in for "carries the cluster SG") is DROPped, so probes from the host time out with `i/o timeout`.

**Your task:** Fix the SG source: make `LAB-CHENGDU` admit `3306` from `10.99.14.0/24` (the "cluster" side) instead of the laptop CIDR, then confirm the connection succeeds. Reverse in cleanup.

**Project link:** S14 §6.2 — `security_groups = [eks_cluster_sg_id]`: source is group membership, not a CIDR; "pods/nodes churn IPs, but always carry the cluster SG."

**Verify:**
```bash
nc -zv -w3 10.99.14.50 3306 2>&1 | tail -1              # expected AFTER fix: "succeeded"/open from the host side
sudo ip netns exec labns-chengdu-db iptables -S LAB-CHENGDU | grep 10.99.14.0/24   # expected: the corrected source
```

#### 🟠 Scenario 7.5 — "Xian: the stateless firewall forgets the way back" (Hard)
**Setup:**
```bash
sudo ip netns add labns-xian
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.14.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
sudo ip link add labveth-xian type veth peer name labveth-xianb
sudo ip link set labveth-xian master lab0
sudo ip link set labveth-xian up
sudo ip link set labveth-xianb netns labns-xian
sudo ip netns exec labns-xian ip link set lo up
sudo ip netns exec labns-xian ip link set labveth-xianb up
sudo ip netns exec labns-xian ip addr add 10.99.14.60/24 dev labveth-xianb
sudo ip netns exec labns-xian ip route add default via 10.99.14.1
sudo ip netns exec labns-xian sh -c 'python3 -m http.server 6379 >/dev/null 2>&1 &'
# STATELESS "NACL": explicit allow both directions, NO conntrack. Inbound 6379 is allowed,
# but the return traffic (replies leave FROM 6379 TO the client's ephemeral port) is NOT.
sudo ip netns exec labns-xian iptables -N LAB-XIAN-IN 2>/dev/null || true
sudo ip netns exec labns-xian iptables -N LAB-XIAN-OUT 2>/dev/null || true
sudo ip netns exec labns-xian iptables -I INPUT -j LAB-XIAN-IN
sudo ip netns exec labns-xian iptables -I OUTPUT -j LAB-XIAN-OUT
sudo ip netns exec labns-xian iptables -A LAB-XIAN-IN -p tcp --dport 6379 -j ACCEPT
sudo ip netns exec labns-xian iptables -A LAB-XIAN-IN -j DROP
sudo ip netns exec labns-xian iptables -A LAB-XIAN-OUT -j DROP
```
**Situation:** Someone "hardened" the Redis subnet with a NACL-style stateless ruleset: inbound `6379` is explicitly allowed, but because a NACL has no flow memory, the *outbound replies* (leaving source-port `6379` to the client's ephemeral `1024–65535`) are dropped. The handshake never completes; the connection mysteriously hangs — the textbook stateless-firewall bug.

**Your task:** Without adding conntrack (keep it stateless, like a real NACL), add the explicit outbound rule that lets replies leave: allow tcp `--sport 6379` to the ephemeral range in `LAB-XIAN-OUT`. Then verify the connect succeeds. Reverse in cleanup.

**Project link:** S14 Rung 3 — "a NACL doing this needs: outbound 6379 AND inbound 1024–65535 — forget the second, mystery hangs." (Here the missing leg is the outbound reply.)

**Verify:**
```bash
nc -zv -w3 10.99.14.60 6379 2>&1 | tail -1                              # expected AFTER fix: "succeeded"/open
sudo ip netns exec labns-xian iptables -S LAB-XIAN-OUT | grep 'sport 6379'  # expected: explicit return-traffic rule
```

#### 🔴 Scenario 7.6 — "Harbin: two firewalls, one silent drop" (Expert)
**Setup:**
```bash
# A subnet-level stateless "NACL" (router ns) PLUS an ENI-level stateful "SG" (db ns). One of them drops.
sudo ip netns add labns-harbin-rtr
sudo ip netns add labns-harbin-db
sudo ip link add name lab0 type bridge 2>/dev/null || true
sudo ip addr add 10.99.14.1/24 dev lab0 2>/dev/null || true
sudo ip link set lab0 up
# router ns sits between host and db: host<->rtr on lab0, rtr<->db on a private link
sudo ip link add labveth-hba type veth peer name labveth-hbb
sudo ip link set labveth-hba master lab0
sudo ip link set labveth-hba up
sudo ip link set labveth-hbb netns labns-harbin-rtr
sudo ip link add labveth-hbc type veth peer name labveth-hbd
sudo ip link set labveth-hbc netns labns-harbin-rtr
sudo ip link set labveth-hbd netns labns-harbin-db
sudo ip netns exec labns-harbin-rtr ip link set lo up
sudo ip netns exec labns-harbin-db ip link set lo up
sudo ip netns exec labns-harbin-rtr ip addr add 10.99.14.2/24 dev labveth-hbb
sudo ip netns exec labns-harbin-rtr ip link set labveth-hbb up
sudo ip netns exec labns-harbin-rtr ip addr add 10.99.20.1/24 dev labveth-hbd
sudo ip netns exec labns-harbin-rtr ip link set labveth-hbd up 2>/dev/null || true
sudo ip netns exec labns-harbin-rtr ip addr add 10.99.20.1/24 dev labveth-hbc
sudo ip netns exec labns-harbin-rtr ip link set labveth-hbc up
sudo ip netns exec labns-harbin-db ip addr add 10.99.20.50/24 dev labveth-hbd
sudo ip netns exec labns-harbin-db ip link set labveth-hbd up
sudo ip netns exec labns-harbin-db ip route add default via 10.99.20.1
sudo ip netns exec labns-harbin-rtr sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo ip route add 10.99.20.0/24 via 10.99.14.2 dev lab0 2>/dev/null || true
sudo ip netns exec labns-harbin-db sh -c 'python3 -m http.server 3306 >/dev/null 2>&1 &'
# TWO firewalls in the path, ONE is the culprit:
#  (a) NACL layer, stateless, on the router ns FORWARD — allows inbound 3306 but DROPs the return
sudo ip netns exec labns-harbin-rtr iptables -N LAB-HARBIN-NACL 2>/dev/null || true
sudo ip netns exec labns-harbin-rtr iptables -I FORWARD -j LAB-HARBIN-NACL
sudo ip netns exec labns-harbin-rtr iptables -A LAB-HARBIN-NACL -p tcp --dport 3306 -j ACCEPT
sudo ip netns exec labns-harbin-rtr iptables -A LAB-HARBIN-NACL -p tcp --sport 3306 -j DROP
sudo ip netns exec labns-harbin-rtr iptables -A LAB-HARBIN-NACL -j ACCEPT
#  (b) SG layer, stateful, on the db ns — correct (admits 3306 + established)
sudo ip netns exec labns-harbin-db iptables -N LAB-HARBIN-SG 2>/dev/null || true
sudo ip netns exec labns-harbin-db iptables -I INPUT -j LAB-HARBIN-SG
sudo ip netns exec labns-harbin-db iptables -A LAB-HARBIN-SG -p tcp --dport 3306 -j ACCEPT
sudo ip netns exec labns-harbin-db iptables -A LAB-HARBIN-SG -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```
**Situation:** Full defense-in-depth: a stateless NACL layer on the subnet router and a stateful SG layer on the DB ENI. A `3306` probe from the host times out. The SG layer is written correctly (allows `3306` + established). The NACL layer allows the inbound `3306` but DROPs the return traffic (`--sport 3306`) — so the SYN reaches the DB, the DB replies, and the reply is silently discarded at the subnet boundary. You must find which of the two firewalls drops, using `refused vs timeout` + conntrack reasoning, then fix only that layer.

**Your task:** Diagnose that the SG (db ns) is fine and the NACL (router ns) return rule is the culprit; fix the NACL layer so it permits the `--sport 3306` return traffic to the ephemeral range; confirm the connect succeeds end to end. Reverse everything in cleanup.

**Project link:** S14/S22 defense-in-depth — SG + NACL stacked; "connection timed out = packets silently dropped"; a stateless NACL must handle ephemeral replies explicitly or the flow hangs.

**Verify:**
```bash
nc -zv -w3 10.99.20.50 3306 2>&1 | tail -1                                        # expected AFTER fix: "succeeded"/open
sudo ip netns exec labns-harbin-rtr iptables -S LAB-HARBIN-NACL | grep 'sport 3306'  # expected: the return-traffic now ACCEPTed
sudo ip netns exec labns-harbin-db iptables -S LAB-HARBIN-SG                       # expected: SG was already correct (unchanged)
```

---

### Climb 8 — Load Balancing: L4 vs L7, Health Checks & the Front Door

> Local analogue: `python3 -m http.server` processes on ports 8000–8999 are the backend "pods"; `nginx` is the L7 front door (ALB/Ingress); `socat` is the L4 pass-through (NLB). `ss -ltnp` inspects the pool; `curl` rides the balancer. `nginx`'s `max_fails` = passive health ejection = the target-group health check / Envoy outlier detection. Every scenario reverses its state in **Cleanup:**.

#### 🟢 Scenario 8.1 — "Suzhou: two backends, one front door" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-suzhou-v1 /opt/lab-suzhou-v2 /opt/lab-suzhou
echo 'catalog-v1' | sudo tee /opt/lab-suzhou-v1/index.html >/dev/null
echo 'catalog-v2' | sudo tee /opt/lab-suzhou-v2/index.html >/dev/null
python3 -m http.server 8001 --directory /opt/lab-suzhou-v1 >/dev/null 2>&1 &
python3 -m http.server 8002 --directory /opt/lab-suzhou-v2 >/dev/null 2>&1 &
sleep 1
sudo tee /opt/lab-suzhou/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool { server 127.0.0.1:8001; server 127.0.0.1:8002; }
  server { listen 8080; location / { proxy_pass http://pool; } }
}
EOF
# nginx is NOT started yet — the front door has no LB running.
```
**Situation:** Two catalog replicas answer on `8001` and `8002` (S08's Deployment scaled to 2). Clients currently have to pick a backend by hand — useless. You must stand up the front door (nginx) that spreads requests round-robin across the pool, the miniature ALB target group.

**Your task:** Start nginx with the provided config and confirm four curls alternate across `catalog-v1` and `catalog-v2`. Reverse in cleanup.

**Project link:** S11 ALB Ingress + target group — the LB spreads requests across a health-checked pool; nginx `upstream` = the target group.

**Verify:**
```bash
sudo nginx -c /opt/lab-suzhou/nginx.conf
for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/; done   # expected: alternates catalog-v1 / catalog-v2 (round robin)
```

#### 🟢 Scenario 8.2 — "Guilin: the pool is half empty" (Easy)
**Setup:**
```bash
sudo mkdir -p /opt/lab-guilin-v1 /opt/lab-guilin-v2 /opt/lab-guilin
echo 'ui-v1' | sudo tee /opt/lab-guilin-v1/index.html >/dev/null
echo 'ui-v2' | sudo tee /opt/lab-guilin-v2/index.html >/dev/null
# Only ONE of two intended backends is actually started (8011). 8012 is DOWN.
python3 -m http.server 8011 --directory /opt/lab-guilin-v1 >/dev/null 2>&1 &
sleep 1
sudo tee /opt/lab-guilin/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool { server 127.0.0.1:8011; server 127.0.0.1:8012; }
  server { listen 8080; location / { proxy_pass http://pool; }
           location /health { return 200 "lb ok\n"; } }
}
EOF
sudo nginx -c /opt/lab-guilin/nginx.conf
```
**Situation:** The ui target group should have two members but roughly half of requests fail — a `502` every other curl. The LB is configured for `8011` and `8012`, but `8012` has no listener (its "pod" never came up). This is "no healthy target" for half the pool. First you must *see* the empty slot, then bring the missing backend up.

**Your task:** Use `ss -ltnp` to confirm only `8011` is listening, then start the missing `8012` backend so both pool members are healthy and every request succeeds. Reverse in cleanup.

**Project link:** S11 — target-group health: a member with nothing listening is a `502`/`503` source until its pod is Ready and serving.

**Verify:**
```bash
ss -ltnp 2>/dev/null | grep -E '801[12]'                     # expected BEFORE fix: only 8011 listening
for i in 1 2 3 4; do curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/; done  # expected AFTER fix: all 200
```

#### 🟡 Scenario 8.3 — "Macau: eject the dead, converge on the living" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-macau-v1 /opt/lab-macau-v2 /opt/lab-macau
echo 'carts-v1' | sudo tee /opt/lab-macau-v1/index.html >/dev/null
echo 'carts-v2' | sudo tee /opt/lab-macau-v2/index.html >/dev/null
python3 -m http.server 8021 --directory /opt/lab-macau-v1 >/dev/null 2>&1 &
python3 -m http.server 8022 --directory /opt/lab-macau-v2 >/dev/null 2>&1 &
sleep 1
# Naive config: NO passive health check — a killed backend keeps getting traffic (repeated 502s).
sudo tee /opt/lab-macau/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool { server 127.0.0.1:8021; server 127.0.0.1:8022; }
  server { listen 8080; location / { proxy_pass http://pool; } }
}
EOF
sudo nginx -c /opt/lab-macau/nginx.conf
```
**Situation:** During a rolling deploy one carts pod dies. With the current pool config, every other request still gets routed to the corpse — persistent intermittent `502s` — because nginx keeps the dead target in rotation. You must add passive health ejection so a failing target leaves the pool and traffic converges on the survivor, the way a target group / Envoy outlier detection ejects a bad pod.

**Your task:** Rewrite the upstream with `max_fails=1 fail_timeout=10s` on each member, reload nginx, kill `8022`, and confirm traffic converges on `carts-v1` after at most one hiccup. Reverse in cleanup.

**Project link:** S11/S22 — passive health ejection = target-group health check / DestinationRule outlier detection ("eject after N consecutive 5xx"); one concept, three uniforms.

**Verify:**
```bash
sudo nginx -c /opt/lab-macau/nginx.conf -s reload
pkill -f 'http.server 8022'
for i in 1 2 3 4 5 6; do curl -s --max-time 2 http://127.0.0.1:8080/; done   # expected: <=1 hiccup, then all carts-v1
```

#### 🟡 Scenario 8.4 — "Hangzhou: only L7 can read the path" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-hangzhou-cat /opt/lab-hangzhou-ord /opt/lab-hangzhou
echo 'CATALOG' | sudo tee /opt/lab-hangzhou-cat/index.html >/dev/null
echo 'ORDERS'  | sudo tee /opt/lab-hangzhou-ord/index.html >/dev/null
python3 -m http.server 8031 --directory /opt/lab-hangzhou-cat >/dev/null 2>&1 &
python3 -m http.server 8032 --directory /opt/lab-hangzhou-ord >/dev/null 2>&1 &
sleep 1
# Current config is L4-style: one backend for everything — path is invisible to it.
sudo tee /opt/lab-hangzhou/nginx.conf >/dev/null <<'EOF'
events {}
http {
  server { listen 8080; location / { proxy_pass http://127.0.0.1:8031/; } }
}
EOF
sudo nginx -c /opt/lab-hangzhou/nginx.conf
```
**Situation:** The store's front door must send `/catalog` to the catalog service and `/orders` to the orders service — path-based routing, an Ingress `rules:` block. The current config forwards *everything* to one backend (an L4 balancer literally cannot see the path). You must turn it into an L7 path router with a `/health` endpoint for the LB's own check.

**Your task:** Replace the config with `location /catalog` → `8031`, `location /orders` → `8032`, and `location /health` → `return 200`. Reload and confirm each path hits the right backend. Reverse in cleanup.

**Project link:** S11 — path→backend mapping in a proxy IS the Ingress `rules:` block IS an ALB listener rule; only an HTTP-terminating (L7) proxy can route on path.

**Verify:**
```bash
sudo nginx -c /opt/lab-hangzhou/nginx.conf -s reload
curl -s http://127.0.0.1:8080/catalog   # expected: CATALOG
curl -s http://127.0.0.1:8080/orders    # expected: ORDERS
curl -s http://127.0.0.1:8080/health    # expected: lb ok
```

#### 🟠 Scenario 8.5 — "Qingdao: 502 says broke, 504 says slow" (Hard)
**Setup:**
```bash
sudo mkdir -p /opt/lab-qingdao
# Backend A on 8041 REFUSES (nothing listens) → the ALB's "502" source.
# Backend B on 8042 is SLOW: a tiny server that sleeps past the proxy timeout → the "504" source.
cat > /opt/lab-qingdao/slow.py <<'EOF'
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(5)
        self.send_response(200); self.end_headers(); self.wfile.write(b'slow-ok\n')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8042), H).serve_forever()
EOF
python3 /opt/lab-qingdao/slow.py >/dev/null 2>&1 &
sleep 1
# LB: /broke -> the refusing backend (502); /slow -> the sleepy backend with a 2s read timeout (504).
sudo tee /opt/lab-qingdao/nginx.conf >/dev/null <<'EOF'
events {}
http {
  server { listen 8080;
    location /broke { proxy_pass http://127.0.0.1:8041/; }
    location /slow  { proxy_pass http://127.0.0.1:8042/; proxy_read_timeout 2s; }
  }
}
EOF
sudo nginx -c /opt/lab-qingdao/nginx.conf
```
**Situation:** Two distinct ALB tickets arrive. Users of `/broke` get `502`; users of `/slow` get `504`. You must reproduce and *distinguish* them from the LB's side — 502 = backend refused/garbled the second connection; 504 = backend accepted but blew the LB's timeout — the S11 5xx decoder. No fix is required; the task is correct diagnosis and articulating the two-connections model.

**Your task:** Curl both paths, capture the exact status codes, and state which backend condition each proves (refusing pod → 502; slow pod exceeding `proxy_read_timeout` → 504). Reverse in cleanup.

**Project link:** S11 Rung 3 5xx decoder — "two connections, not one: 502 = pod refused/garbled the 2nd connection; 504 = pod accepted but exceeded the ALB's timeout."

**Verify:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/broke               # expected: 502 (backend refused)
curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://127.0.0.1:8080/slow   # expected: 504 (backend too slow)
```

#### 🔴 Scenario 8.6 — "Ulaanbaatar: Running is not Ready" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-ub-good /opt/lab-ub-bad /opt/lab-ub
echo 'ui-good' | sudo tee /opt/lab-ub-good/index.html >/dev/null
echo 'ui-bad'  | sudo tee /opt/lab-ub-bad/index.html >/dev/null
# GOOD pod: serves 200 on /health.  BAD pod: process is "Running" (port open) but /health returns 503 (not Ready).
cat > /opt/lab-ub/bad.py <<'EOF'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(503); self.end_headers(); self.wfile.write(b'not ready\n')
        else:
            self.send_response(200); self.end_headers(); self.wfile.write(b'ui-bad\n')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8052), H).serve_forever()
EOF
cat > /opt/lab-ub/good.py <<'EOF'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 200
        self.send_response(code); self.end_headers()
        self.wfile.write(b'ui-good\n' if self.path != '/health' else b'ok\n')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8051), H).serve_forever()
EOF
python3 /opt/lab-ub/good.py >/dev/null 2>&1 &
python3 /opt/lab-ub/bad.py  >/dev/null 2>&1 &
sleep 1
# BROKEN front door: an L7 pool with NO health check — both "Running" ports get traffic,
# so the bad pod (Running, port open, but /health=503) causes intermittent bad responses.
sudo tee /opt/lab-ub/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool { server 127.0.0.1:8051; server 127.0.0.1:8052; }
  server { listen 8080; location / { proxy_pass http://pool; } }
}
EOF
sudo nginx -c /opt/lab-ub/nginx.conf
```
**Situation:** After a deploy, users report intermittent bad responses even though both "pods" are Running (both ports are open). One pod is a liar: its `/health` returns `503` — process up, not actually Ready — yet the L7 pool has no health gate, so it forwards to the bad pod half the time. Meanwhile the ops team also wants to prove that an L4 pass-through (socat, the NLB/Istio-gateway analogue) could *not* have fixed this, because L4 can't read `/health`. You must make the L7 front door only serve the truthfully-healthy pod.

**Your task:** Reproduce the intermittent bad response, then make nginx health-gate the pool so the `503`-on-`/health` pod is ejected and only `ui-good` is served. Demonstrate the L4 contrast: a `socat` TCP forwarder to a single backend forwards bytes blind (no `/health` awareness), proving why the L7 layer is where readiness lives. Reverse everything in cleanup.

**Project link:** S11/S21 Check-yourself — "Running ≠ Ready ≠ passing the ALB's own check"; intermittent 502s after a deploy come from a pod that joins the pool before it can truthfully serve; L4 (NLB, S22) cannot health-check on content.

**Verify:**
```bash
for i in $(seq 1 6); do curl -s http://127.0.0.1:8080/; done                 # expected BEFORE fix: mix of ui-good / ui-bad
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8052/health        # expected: 503 (the liar pod)
# AFTER fix (health-gated pool): all responses are ui-good
for i in $(seq 1 6); do curl -s http://127.0.0.1:8080/; done                 # expected AFTER fix: only ui-good
```


> **How to use this lab (Climbs 9–10):** use a **disposable** Ubuntu/Debian VM (Multipass, Vagrant, or a throwaway cloud instance) — every scenario needs `sudo` and several deliberately break networking. No Kubernetes and no Docker required: everything is built from the same primitives the course's clusters use — `python3`, `iproute2`, `iptables` (plus a standalone `nginx` binary in 10.4 and 10.6). For each scenario: run the **Setup** (paste the whole block), read the **Situation**, accomplish the **Your task**, prove it with **Verify** — *without* peeking at the answers section. Run **one scenario at a time** and always run its **Cleanup** (in the answers) before starting the next: they share the lab bridge `lab0`. Everything lives in namespaces `labns-*`, veths `labveth*`, iptables chains `LAB-*`, files under `/opt/lab-*`, ports 8000–8999 — nothing touches your real networking except where a scenario says so (and then it records and restores).
>
> One-time prerequisites:
>
> ```bash
> sudo apt-get update -qq
> sudo apt-get install -y iproute2 iptables curl python3 tcpdump >/dev/null
> # nginx is needed only for scenarios 10.4 and 10.6 — their Setups install it
> ```

### Climb 9 — Container & Pod Networking: bridge, veth, CNI

#### 🟢 Scenario 9.1 — "Havana: the cable plugged in but never switched on" (Easy)
**Setup:**
```bash
sudo ip netns add labns-hav
sudo ip link add labveth-hav type veth peer name eth0 netns labns-hav
sudo ip addr add 10.90.1.1/24 dev labveth-hav
sudo ip link set labveth-hav up
sudo ip netns exec labns-hav ip addr add 10.90.1.2/24 dev eth0
sudo ip netns exec labns-hav ip link set lo up
# (the "CNI plugin" crashed right here — one command short of a working pod)
```
**Situation:** monitoring pages you: the new "payments pod" (`labns-hav`, 10.90.1.2) is unreachable from its node. `ping -c2 -W1 10.90.1.2` loses 100%. The teammate before you already "checked the cable": *"the veth exists, it's plugged in, I can see it in `ip link` — must be an IP problem."* It isn't.

**Your task:** diagnose **from the host side only** first — read the exact operational state of `labveth-hav` with `ip -br link` and explain what that state word says about the *other* end of the cable, the end you can't see from here. Then fix the pod's connectivity.

**Project link:** this is a CNI `ADD` call that died mid-sequence — on EKS, kubelet asks the VPC CNI to create the veth, move one end into the pod, assign the IP, *and bring the links up*; a pod can show `Running` while its cable was never switched on. `LOWERLAYERDOWN` on a node's `veth*` is exactly how you spot it from the node.

**Verify:**
```bash
ip -br link show labveth-hav
# expected: state UP (not LOWERLAYERDOWN)
ping -c2 -W1 10.90.1.2
# expected: 2 packets transmitted, 2 received, 0% packet loss
```

#### 🟢 Scenario 9.2 — "San Juan: three cables, one guilty pod" (Easy)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.2.1/24 dev lab0
IDX=1
for POD in $(shuf -e ui cart catalogue); do
  NS="labns-sj-$POD"
  sudo ip netns add "$NS"
  sudo ip link add "labveth-p$IDX" type veth peer name eth0 netns "$NS"
  sudo ip link set "labveth-p$IDX" master lab0 up
  sudo ip netns exec "$NS" ip addr add "10.90.2.$((IDX + 1))/24" dev eth0
  sudo ip netns exec "$NS" ip link set eth0 up
  sudo ip netns exec "$NS" ip link set lo up
  IDX=$((IDX + 1))
done
GUILTY=$(shuf -n1 -e ui cart catalogue)
sudo ip netns exec "labns-sj-$GUILTY" bash -c 'nohup ping -i 0.01 10.90.2.1 >/dev/null 2>&1 &'
unset GUILTY
```
**Situation:** the node is drowning in interrupts. Three pods (`ui`, `cart`, `catalogue`) hang off the `lab0` bridge, and one of them is flooding the node with ~100 packets/second. Sample the counters twice and you'll see one host veth racing:

```bash
ip -s -br link | grep labveth-p; sleep 2; echo ---; ip -s -br link | grep labveth-p
```

But `labveth-p2` (or whichever is hot for you) is just a number — the scheduler (`shuf`) assigned veth names to pods randomly, so *don't guess*.

**Your task:** map the hot host-side veth to the network namespace that owns its other end, using the `iflink`/`ifindex` pair-matching trick — **name the guilty pod** — then kill the flooding process *inside that namespace only* (the other two pods must stay untouched).

**Project link:** this is "which pod is flooding my EKS node's NIC?" — `kubectl` will never show you the pod↔veth mapping, but every host veth's `iflink` equals the pod-side `eth0`'s `ifindex` (Rung 7 Lab 1 of this climb, run in anger). Same technique identifies the pod behind any `veth*` in `tcpdump` output on a node.

**Verify:**
```bash
A=$(cat /sys/class/net/lab0/statistics/rx_packets); sleep 2; B=$(cat /sys/class/net/lab0/statistics/rx_packets); echo $((B - A))
# expected: fewer than 10 (it was ~200 per 2s during the flood)
sudo ip netns pids labns-sj-ui | wc -l; sudo ip netns pids labns-sj-cart | wc -l; sudo ip netns pids labns-sj-catalogue | wc -l
# expected: 0 for the guilty pod, and 0 for the innocents too (they never ran anything) — but you must be able to SAY which one was guilty and how you proved it
```

#### 🟡 Scenario 9.3 — "Nassau: the switch with an unplugged port" (Medium)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.3.1/24 dev lab0
# pod 1: ui
sudo ip netns add labns-na-ui
sudo ip link add labveth-na1 type veth peer name eth0 netns labns-na-ui
sudo ip link set labveth-na1 master lab0 up
sudo ip netns exec labns-na-ui ip addr add 10.90.3.2/24 dev eth0
sudo ip netns exec labns-na-ui ip link set eth0 up
sudo ip netns exec labns-na-ui ip link set lo up
# pod 2: catalogue
sudo ip netns add labns-na-cat
sudo ip link add labveth-na2 type veth peer name eth0 netns labns-na-cat
sudo ip link set labveth-na2 up
sudo ip netns exec labns-na-cat ip addr add 10.90.3.3/24 dev eth0
sudo ip netns exec labns-na-cat ip link set eth0 up
sudo ip netns exec labns-na-cat ip link set lo up
```
**Situation:** the ui pod cannot reach the catalogue pod:

```bash
sudo ip netns exec labns-na-ui ping -c2 -W1 10.90.3.3
# 100% packet loss
```

And here is what makes it maddening: **every link involved reports UP.** Both host veths, both pod `eth0`s — no `LOWERLAYERDOWN` anywhere, so the Havana lesson doesn't apply. IPs are right, same /24, no firewall rules. The cables are fine; something else in the path is not.

**Your task:** prove exactly where the L2 path breaks using `bridge link show` and `ip -d link show`, then reconnect it with one command. Along the way, answer: what is a veth that is UP but enslaved to no bridge actually connected *to*?

**Project link:** a bridge port that was never enslaved is Docker's `docker0` (or a CNI bridge plugin) failing the "attach" half of its job: the container has a perfectly healthy cable dangling in the air. `docker network connect` and the CNI's bridge `master` assignment are exactly this one command. Rung 3's diagram calls the bridge "a virtual switch" — this is the switch with a port physically unplugged.

**Verify:**
```bash
bridge link show | grep -c labveth-na
# expected: 2
sudo ip netns exec labns-na-ui ping -c2 -W1 10.90.3.3
# expected: 2 received, 0% packet loss
```

#### 🟡 Scenario 9.4 — "Bridgetown: the pod that couldn't phone ECR" (Medium)
**Setup:**
```bash
sudo mkdir -p /opt/lab-bt/registry
cat /proc/sys/net/ipv4/ip_forward | sudo tee /opt/lab-bt/ip_forward.orig >/dev/null
sudo sysctl -qw net.ipv4.ip_forward=0
# the "private-subnet pod" behind this host (the host plays NAT gateway)
sudo ip netns add labns-bt-pod
sudo ip link add labveth-bt1 type veth peer name eth0 netns labns-bt-pod
sudo ip addr add 10.90.4.1/24 dev labveth-bt1
sudo ip link set labveth-bt1 up
sudo ip netns exec labns-bt-pod ip addr add 10.90.4.2/24 dev eth0
sudo ip netns exec labns-bt-pod ip link set eth0 up
sudo ip netns exec labns-bt-pod ip link set lo up
sudo ip netns exec labns-bt-pod ip route add default via 10.90.4.1
# "ECR" — a registry out on the internet. Deliberately: it has NO route back to
# 10.90.4.0/24, because the real internet cannot route to your private IPs either.
sudo ip netns add labns-bt-ecr
sudo ip link add labveth-bt2 type veth peer name eth0 netns labns-bt-ecr
sudo ip addr add 10.90.44.1/24 dev labveth-bt2
sudo ip link set labveth-bt2 up
sudo ip netns exec labns-bt-ecr ip addr add 10.90.44.2/24 dev eth0
sudo ip netns exec labns-bt-ecr ip link set eth0 up
sudo ip netns exec labns-bt-ecr ip link set lo up
echo 'PULL OK: retail-store/catalogue:v1.2.3' | sudo tee /opt/lab-bt/registry/manifest.txt >/dev/null
sudo ip netns exec labns-bt-ecr bash -c 'cd /opt/lab-bt/registry && nohup python3 -m http.server 8443 --bind 10.90.44.2 >/dev/null 2>&1 &'
# the NAT gateway's rulebook exists and is hooked up — but it is empty
sudo iptables -t nat -N LAB-NAT-BT
sudo iptables -t nat -A POSTROUTING -s 10.90.4.0/24 -j LAB-NAT-BT
```
**Situation:** the pod is in the lab's version of `ImagePullBackOff` — its image pull from "ECR" (10.90.44.2:8443) hangs and dies:

```bash
sudo ip netns exec labns-bt-pod curl -s --max-time 3 http://10.90.44.2:8443/manifest.txt
# ...3 seconds of nothing, exit code 28 (timeout)
```

The pod's own wiring is fine — it can ping its gateway 10.90.4.1. The registry is fine — the host can `curl 10.90.44.2:8443/manifest.txt` directly. The break is in the middle, on the box that is supposed to be the NAT gateway: this host. **Timeout, not refused** — remember what that combination means.

**Your task:** fix it **on the host only** — you may not touch `labns-bt-ecr` in any way (you don't get to reconfigure Amazon's routers, and the missing return route over there is a *feature* of the internet, not a bug). There are **two** independent faults; `tcpdump -ni labveth-bt2` while the curl runs will show you the second one after you've fixed the first. When you're done, note what `/opt/lab-bt/ip_forward.orig` is for — labs on shared boxes record what they change.

**Project link:** this is the private EKS node pulling from ECR through the NAT gateway (S06/S07/S21, Climb 6): `ip_forward=1` is the "be a router" switch every NAT GW/instance-router needs, and MASQUERADE is the SNAT that rewrites the pod's private source to an address the far side can actually route back to. Without it your SYNs *arrive* and the SYN-ACKs die on a routerless return path — the classic asymmetric-route timeout.

**Verify:**
```bash
sudo ip netns exec labns-bt-pod curl -s --max-time 3 http://10.90.44.2:8443/manifest.txt
# expected: PULL OK: retail-store/catalogue:v1.2.3
sudo iptables -t nat -L LAB-NAT-BT -nv | tail -1
# expected: a MASQUERADE rule with a non-zero pkts counter
```

#### 🟠 Scenario 9.5 — "Panama City: two pods, one IP" (Hard)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.5.1/24 dev lab0
sudo mkdir -p /opt/lab-pc/www
echo 'cart OK: 3 items' | sudo tee /opt/lab-pc/www/index.html >/dev/null
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-pc-client labveth-pc1 10.90.5.2
mkpod labns-pc-cart   labveth-pc2 10.90.5.3
mkpod labns-pc-ghost  labveth-pc3 10.90.5.3   # the IPAM double-allocation
sudo ip netns exec labns-pc-cart bash -c 'cd /opt/lab-pc/www && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
# freeze the coin-flip: in real life duplicate IPs make an ARP *race*; for a
# deterministic lab, the setup poisons the client's ARP cache so the ghost "won"
GHOST_MAC=$(sudo ip netns exec labns-pc-ghost cat /sys/class/net/eth0/address)
sudo ip netns exec labns-pc-client ip neigh replace 10.90.5.3 lladdr "$GHOST_MAC" dev eth0 nud permanent
unset GHOST_MAC
```
**Situation:** the client pod cannot buy anything:

```bash
sudo ip netns exec labns-pc-client curl -s --max-time 3 http://10.90.5.3:8080/
# curl: (7) Failed to connect to 10.90.5.3 port 8080 ... Connection refused
```

Yet the cart pod is provably healthy: `sudo ip netns pids labns-pc-cart` shows its server running, and `sudo ip netns exec labns-pc-cart curl -s http://localhost:8080/` returns `cart OK`. Apply Climb 7's iron rule before touching anything: **refused means something answered.** A dead pod times out; this connection was *rejected by a live host*. So who, exactly, is answering for 10.90.5.3?

**Your task:** do the neighbor-table forensics from inside the client: read its ARP entry for 10.90.5.3 (notice anything odd about its state?), compare that MAC against the `eth0` MAC of every candidate namespace, and identify the impostor. Then fix it under one constraint: **the cart pod keeps 10.90.5.3** (the Service's EndpointSlice already points there). Finish with the client curl returning `cart OK`.

**Project link:** duplicate pod IPs are what happens when CNI IPAM state is corrupted or a pod is recreated while a stale ARP entry for its predecessor lives on — the VPC CNI's whole job is to make IP leases *exclusive*. And the triage rule is Climb 7's: connection refused vs timeout told you a live-but-wrong host owned the IP before you ever looked at a MAC address.

**Verify:**
```bash
sudo ip netns exec labns-pc-client curl -s --max-time 3 http://10.90.5.3:8080/
# expected: cart OK: 3 items
CART_MAC=$(sudo ip netns exec labns-pc-cart cat /sys/class/net/eth0/address); sudo ip netns exec labns-pc-client ip neigh show 10.90.5.3 | grep -c "$CART_MAC"
# expected: 1 — the client's neighbor entry now holds the CART pod's MAC (and it is not PERMANENT)
```

#### 🔴 Scenario 9.6 — "San José: the sidecar died and kept the traffic" (Expert)
**Setup:**
```bash
sudo mkdir -p /opt/lab-sj/www
echo 'checkout app: order placed' | sudo tee /opt/lab-sj/www/index.html >/dev/null
sudo ip netns add labns-sanjose
sudo ip link add labveth-sj6 type veth peer name eth0 netns labns-sanjose
sudo ip addr add 10.90.6.1/24 dev labveth-sj6
sudo ip link set labveth-sj6 up
sudo ip netns exec labns-sanjose ip addr add 10.90.6.2/24 dev eth0
sudo ip netns exec labns-sanjose ip link set eth0 up
sudo ip netns exec labns-sanjose ip link set lo up
sudo ip netns exec labns-sanjose ip route add default via 10.90.6.1
# the app container: checkout, listening on :8080 in the pod's namespace
sudo ip netns exec labns-sanjose bash -c 'cd /opt/lab-sj/www && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
# istio-init already ran: inside THIS netns only, all inbound tcp/8080 is
# REDIRECTed to the sidecar's inbound port :8150
sudo ip netns exec labns-sanjose iptables -t nat -N LAB-MESH-SJ
sudo ip netns exec labns-sanjose iptables -t nat -A PREROUTING -p tcp --dport 8080 -j LAB-MESH-SJ
sudo ip netns exec labns-sanjose iptables -t nat -A LAB-MESH-SJ -p tcp -j REDIRECT --to-ports 8150
# the sidecar "binary" the platform team ships. It is NOT running — it crashed at 03:12.
sudo tee /opt/lab-sj/envoy.py >/dev/null <<'PYEOF'
"""lab-sj sidecar: a 20-line 'Envoy' — accept on :8150, pipe bytes to the app on 127.0.0.1:8080."""
import socket
import threading

def pipe(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", 8150))
srv.listen(16)
while True:
    client, _ = srv.accept()
    upstream = socket.socket()
    upstream.connect(("127.0.0.1", 8080))
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
PYEOF
```
**Situation:** the checkout pod is "down" — but only from outside:

```bash
curl -s --max-time 3 http://10.90.6.2:8080/          # from the host / other pods
# curl: (7) ... Connection refused
sudo ip netns exec labns-sanjose curl -s http://localhost:8080/
# checkout app: order placed        ← the app is FINE from inside
ping -c1 10.90.6.2                                    # even ping works!
```

The app team says "our container is healthy, the network is broken." The network team says "the veth is UP, ping works, routing is fine." Both are right, and the pod is still down. Somewhere in this namespace a dead process is still owed all the traffic.

**Your task:** explain the exact mechanism behind *refused-from-outside / fine-from-inside / ping-works* by reading this namespace's **own** nat table and its listener list. Then bring the pod back **without touching the iptables rules** — in a real pod, those were written by `istio-init` and you don't get to unwrite them; the correct fix is to resurrect the sidecar (its "binary" is `/opt/lab-sj/envoy.py`) **in the right place**.

**Project link:** this is a crashed Envoy sidecar (S22) with `istio-init`'s REDIRECT rules still armed: iptables rules live *in the pod's network namespace* and the namespace is held open by the **pause container**, so the rules outlive the sidecar that consumed them. Inbound traffic keeps being redirected to a port nobody listens on (refused), while the app's own `localhost` view (locally generated traffic doesn't traverse PREROUTING) and ICMP (the rule matches only tcp/8080) stay perfect.

**Verify:**
```bash
curl -s --max-time 3 http://10.90.6.2:8080/
# expected: checkout app: order placed
sudo ip netns exec labns-sanjose ss -tln | grep -c ':8150 '
# expected: 1 — the sidecar is back on its inbound port, inside the pod's namespace
```

### Climb 10 — Kubernetes Services → Ingress → Mesh: the Delivery Chain

#### 🟢 Scenario 10.1 — "Belize City: the VIP nobody listens on" (Easy)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.7.1/24 dev lab0
sudo mkdir -p /opt/lab-bz/www
echo 'catalogue pod answers' | sudo tee /opt/lab-bz/www/index.html >/dev/null
sudo ip netns add labns-bz
sudo ip link add labveth-bz1 type veth peer name eth0 netns labns-bz
sudo ip link set labveth-bz1 master lab0 up
sudo ip netns exec labns-bz ip addr add 10.90.7.2/24 dev eth0
sudo ip netns exec labns-bz ip link set eth0 up
sudo ip netns exec labns-bz ip link set lo up
sudo ip netns exec labns-bz ip route add default via 10.90.7.1
sudo ip netns exec labns-bz bash -c 'cd /opt/lab-bz/www && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
# pin the whole "Service CIDR" onto the lab bridge, so VIP traffic can never
# leak out of this VM through your default route
sudo ip route add 10.96.0.0/16 dev lab0 2>/dev/null || true
# kube-proxy's skeleton: the Service chain exists and is hooked into nat — but it is EMPTY
sudo iptables -t nat -N LAB-SVC-BZ
sudo iptables -t nat -A OUTPUT     -d 10.96.0.0/16 -j LAB-SVC-BZ
sudo iptables -t nat -A PREROUTING -d 10.96.0.0/16 -j LAB-SVC-BZ
```
**Situation:** someone "created a Service": VIP `10.96.10.1:8080` is supposed to front the catalogue pod (10.90.7.2:8080). It doesn't work:

```bash
curl -s --max-time 3 http://10.96.10.1:8080/
# times out
```

A teammate ran `ss -ltn` on the host, found nothing listening on 8080, and declared: *"of course it can't work — nothing listens on that IP. We need to start a process on 10.96.10.1."* That diagnosis is wrong, and so is the mental model behind it. There is a machine part missing, but it is not a socket.

**Your task:** be kube-proxy for one minute — write, by hand, the **one iptables rule** that makes VIP `10.96.10.1:8080` deliver to `10.90.7.2:8080` (it goes inside `LAB-SVC-BZ`, which Setup already hooked into `OUTPUT` and `PREROUTING`, exactly where kube-proxy hooks `KUBE-SERVICES`). Then run the teammate's `ss` check again *while the VIP is working* and explain to them what a ClusterIP actually is.

**Project link:** this DNAT rule is exactly what kube-proxy writes for the catalog ClusterIP (S08) — Rung 3 of this climb says it verbatim: *"no process listens on it!"* A ClusterIP is a promise kept by the kernel's nat table on the client's own node, not a socket anywhere. That's also why you can't ping-debug a Service into existence and why `ss` on any node will never show it.

**Verify:**
```bash
curl -s --max-time 3 http://10.96.10.1:8080/
# expected: catalogue pod answers
sudo ss -ltn | grep -c ':8080 '
# expected: 0 — the VIP works and STILL nothing listens on 8080: it's NAT, not a socket
```

#### 🟢 Scenario 10.2 — "Roseau: the pod that forgot the phone book" (Easy)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.8.1/24 dev lab0
sudo mkdir -p /opt/lab-ro/www
echo 'catalogue: 42 products' | sudo tee /opt/lab-ro/www/index.html >/dev/null
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-ro     labveth-ro1 10.90.8.2
mkpod labns-ro-cat labveth-ro2 10.90.8.3
sudo ip netns exec labns-ro-cat bash -c 'cd /opt/lab-ro/www && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
```
**Situation:** the ui pod (`labns-ro`) calls its dependency **by name**, like every service in this course does:

```bash
sudo ip netns exec labns-ro curl -s --max-time 3 http://catalogue.retail.svc.cluster.local:8080/
# curl: (6) Could not resolve host: catalogue.retail.svc.cluster.local
```

Curling the IP `10.90.8.3:8080` works fine — connectivity is perfect, the pod just has no phone book. Constraints: there is **no DNS server** in this lab, and you may **not** edit the host's `/etc/hosts` (other teams share this node, and their pods must not see your names).

**Your task:** give this **one pod** its own name→IP mapping using the per-namespace mechanism `ip netns exec` natively supports (hint: `man ip-netns`, look for `/etc/netns/`). Prove the host's own resolution is untouched afterwards.

**Project link:** per-pod phone books are the whole point of Compose's embedded DNS (S04) and CoreDNS + the `/etc/hosts` and `/etc/resolv.conf` that kubelet writes *into every pod* (S08): resolution is namespace-scoped, so `catalogue` can mean one thing inside a pod and nothing at all on the node. `/etc/netns/<name>/hosts` is the raw Linux primitive under that idea.

**Verify:**
```bash
sudo ip netns exec labns-ro curl -s --max-time 3 http://catalogue.retail.svc.cluster.local:8080/
# expected: catalogue: 42 products
getent hosts catalogue.retail.svc.cluster.local; echo "host exit: $?"
# expected: no address printed, host exit: 2 — the node's own phone book never learned the name
```

#### 🟡 Scenario 10.3 — "Castries: the selector that matched nothing" (Medium)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.9.1/24 dev lab0
sudo mkdir -p /opt/lab-cs/pods /opt/lab-cs/www1 /opt/lab-cs/www2
echo 'catalogue pod 1' | sudo tee /opt/lab-cs/www1/index.html >/dev/null
echo 'catalogue pod 2' | sudo tee /opt/lab-cs/www2/index.html >/dev/null
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-cs-1 labveth-cs1 10.90.9.2
mkpod labns-cs-2 labveth-cs2 10.90.9.3
sudo ip netns exec labns-cs-1 bash -c 'cd /opt/lab-cs/www1 && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
sudo ip netns exec labns-cs-2 bash -c 'cd /opt/lab-cs/www2 && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
sudo ip route add 10.96.0.0/16 dev lab0 2>/dev/null || true
sudo iptables -t nat -N LAB-SVC-CS
sudo iptables -t nat -A OUTPUT -d 10.96.10.3/32 -j LAB-SVC-CS
# the pod registry — what kubelet would report about running pods
sudo tee /opt/lab-cs/pods/catalogue-1.env >/dev/null <<'EOF'
LABELS="app=catalogue,version=v1"
IP="10.90.9.2"
TGTPORT="8080"
EOF
sudo tee /opt/lab-cs/pods/catalogue-2.env >/dev/null <<'EOF'
LABELS="app=catalogue,version=v1"
IP="10.90.9.3"
TGTPORT="8080"
EOF
sudo tee /opt/lab-cs/pods/cart-1.env >/dev/null <<'EOF'
LABELS="app=cart,version=v1"
IP="10.90.9.9"
TGTPORT="8080"
EOF
# the Service spec — typed by a human at 6pm on a Friday
sudo tee /opt/lab-cs/service.env >/dev/null <<'EOF'
SELECTOR="app=catalouge"
VIP="10.96.10.3"
PORT="8080"
EOF
# the whole control plane in ~30 lines: endpoints-controller + kube-proxy
sudo tee /opt/lab-cs/controller.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# lab-cs control plane: endpoints-controller + kube-proxy, one file
set -eu
source /opt/lab-cs/service.env            # SELECTOR, VIP, PORT
ENDPOINTS=""
COUNT=0
for f in /opt/lab-cs/pods/*.env; do       # the join: Service.selector vs pod labels
  LABELS="" IP="" TGTPORT=""
  source "$f"
  match=0
  IFS=',' read -ra KVS <<< "$LABELS"
  for kv in "${KVS[@]}"; do
    if [ "$kv" = "$SELECTOR" ]; then
      match=1
    fi
  done
  if [ "$match" -eq 1 ]; then
    ENDPOINTS="$ENDPOINTS $IP:$TGTPORT"
    COUNT=$((COUNT + 1))
  fi
done
echo "endpoints-controller: selector '$SELECTOR' matched $COUNT pod(s):${ENDPOINTS:- <none>}"
iptables -t nat -F LAB-SVC-CS             # kube-proxy: compile endpoints into NAT rules
i=0
for ep in $ENDPOINTS; do
  left=$((COUNT - i))
  if [ "$left" -gt 1 ]; then
    iptables -t nat -A LAB-SVC-CS -d "$VIP/32" -p tcp --dport "$PORT" \
      -m statistic --mode nth --every "$left" --packet 0 \
      -j DNAT --to-destination "$ep"
  else
    iptables -t nat -A LAB-SVC-CS -d "$VIP/32" -p tcp --dport "$PORT" \
      -j DNAT --to-destination "$ep"
  fi
  i=$((i + 1))
done
echo "kube-proxy: LAB-SVC-CS now holds $COUNT DNAT rule(s)"
EOF
sudo chmod +x /opt/lab-cs/controller.sh
sudo /opt/lab-cs/controller.sh
```
**Situation:** the "Service" `10.96.10.3:8080` is dead:

```bash
curl -s --max-time 3 http://10.96.10.3:8080/
# times out
```

Both catalogue pods are demonstrably healthy (curl their IPs directly — both answer). The on-call channel has already decided whodunit: *"kube-proxy is broken again — someone go debug the iptables layer."* Before you touch a single rule, scroll up: the Setup's last line printed the controller's own confession — `matched 0 pod(s): <none>`.

**Your task:** read `/opt/lab-cs/controller.sh` and follow the join it performs between `service.env`'s `SELECTOR` and each pod's `LABELS`. Explain **why the iptables layer is innocent** — what does kube-proxy faithfully do when the endpoint list is empty? Then find the real culprit (diff the selector against the pod labels character by character), fix it, re-run the controller, and prove the VIP now alternates between both pods.

**Project link:** this is the classic S08 debugging moment — `kubectl get endpoints catalog-service` shows `<none>` — and the check-yourself question of this very climb: the broken join is Service `spec.selector` ↔ pod `metadata.labels`, and kube-proxy is *not a suspect* because it only compiles whatever EndpointSlices give it. Zero endpoints in, zero rules out: it's doing its job perfectly.

**Verify:**
```bash
sudo /opt/lab-cs/controller.sh
# expected: endpoints-controller: selector 'app=catalogue' matched 2 pod(s): 10.90.9.2:8080 10.90.9.3:8080
# expected: kube-proxy: LAB-SVC-CS now holds 2 DNAT rule(s)
for i in 1 2 3 4; do curl -s --max-time 3 http://10.96.10.3:8080/; done
# expected: catalogue pod 1 / catalogue pod 2, alternating (statistic-mode round robin)
```

#### 🟡 Scenario 10.4 — "Willemstad: one front door, 502 on aisle /cart" (Medium)
**Setup:**
```bash
sudo apt-get install -y nginx >/dev/null      # we use only the BINARY — silence the distro service
sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.10.1/24 dev lab0
sudo mkdir -p /opt/lab-wl/www-ui /opt/lab-wl/www-cart
echo 'ui: welcome to the retail store' | sudo tee /opt/lab-wl/www-ui/index.html >/dev/null
echo 'cart: 3 items, total 42' | sudo tee /opt/lab-wl/www-cart/cart >/dev/null
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-wl-ui   labveth-wl1 10.90.10.2
mkpod labns-wl-cart labveth-wl2 10.90.10.3
sudo ip netns exec labns-wl-ui   bash -c 'cd /opt/lab-wl/www-ui   && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
sudo ip netns exec labns-wl-cart bash -c 'cd /opt/lab-wl/www-cart && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
# the Ingress controller's compiled config (someone edited targetPort in the YAML last night)
sudo tee /opt/lab-wl/nginx.conf >/dev/null <<'EOF'
pid /opt/lab-wl/nginx.pid;
error_log /opt/lab-wl/error.log;
worker_processes 1;
events {}
http {
  access_log /opt/lab-wl/access.log;
  server {
    listen 8480;
    location /cart { proxy_pass http://10.90.10.3:8090; }
    location /     { proxy_pass http://10.90.10.2:8080; }
  }
}
EOF
sudo nginx -c /opt/lab-wl/nginx.conf
```
**Situation:** one front door (`:8480`), path-routed to two backends — and one aisle is on fire:

```bash
curl -s http://localhost:8480/
# ui: welcome to the retail store          ← fine
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8480/cart
# 502                                      ← Bad Gateway
```

The cart team swears their pod is healthy, and they're right: `sudo ip netns exec labns-wl-cart ss -tln` shows `:8080` listening, and `curl 10.90.10.3:8080/cart` from the host returns the cart. So the pod is fine, the path rule exists… and users still get 502.

**Your task:** triage this the way you'd triage an ALB 502 — **from the proxy's own evidence**, not by guessing: read `/opt/lab-wl/error.log`, find the line that names exactly which upstream address the proxy tried and what the kernel told it (refused? timed out? — Climb 7's rule again), conclude *wrong port, not dead pod*, fix `/opt/lab-wl/nginx.conf`, and reload the running binary with `sudo nginx -c /opt/lab-wl/nginx.conf -s reload` (no restart — front doors don't get to drop connections).

**Project link:** this is an ALB Ingress (S11) whose rule points at a `targetPort` that no container actually opens — the #1 cause of ALB 502s in the course's stack. A 502 means *the proxy itself is alive and answering you; its upstream hop failed* — and the proxy's error log (ALB access logs + target-group health reasons in AWS) names the exact backend:port it tried. Triage the delivery chain from the box that generated the status code.

**Verify:**
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8480/cart
# expected: 200
curl -s http://localhost:8480/cart
# expected: cart: 3 items, total 42
curl -s http://localhost:8480/
# expected: ui: welcome to the retail store   (the other aisle must still work)
```

#### 🟠 Scenario 10.5 — "Montego Bay: half the checkouts are dying" (Hard)
**Setup:**
```bash
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.11.1/24 dev lab0
sudo mkdir -p /opt/lab-mb
sudo tee /opt/lab-mb/pod.py >/dev/null <<'PYEOF'
"""lab-mb checkout pod: answers every GET (including /healthz) with the status code given on the CLI."""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATUS = int(sys.argv[1])
BODY = (sys.argv[2] + "\n").encode()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(STATUS)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass

HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PYEOF
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-mb-1 labveth-mb1 10.90.11.2
mkpod labns-mb-2 labveth-mb2 10.90.11.3
sudo ip netns exec labns-mb-1 bash -c 'nohup python3 /opt/lab-mb/pod.py 200 "checkout pod-1: order placed" >/dev/null 2>&1 &'
sudo ip netns exec labns-mb-2 bash -c 'nohup python3 /opt/lab-mb/pod.py 500 "checkout pod-2: NullPointerException" >/dev/null 2>&1 &'
sudo ip route add 10.96.0.0/16 dev lab0 2>/dev/null || true
sudo iptables -t nat -N LAB-SVC-MB
sudo iptables -t nat -A OUTPUT -d 10.96.10.5/32 -j LAB-SVC-MB
# the readiness controller: probes each pod, keeps only READY pods in the Service rotation
sudo tee /opt/lab-mb/readiness.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# lab-mb readiness controller: probe /healthz, rebuild the rotation with READY pods only
set -u
VIP="10.96.10.5"
PORT="8080"
PODS="10.90.11.2 10.90.11.3"
READY=""
COUNT=0
for ip in $PODS; do
  if curl -s --max-time 2 "http://$ip:$PORT/healthz" >/dev/null; then
    READY="$READY $ip"
    COUNT=$((COUNT + 1))
  fi
done
echo "readiness: $COUNT of 2 pods ready:${READY:- <none>}"
iptables -t nat -F LAB-SVC-MB
i=0
for ip in $READY; do
  left=$((COUNT - i))
  if [ "$left" -gt 1 ]; then
    iptables -t nat -A LAB-SVC-MB -d "$VIP/32" -p tcp --dport "$PORT" \
      -m statistic --mode nth --every "$left" --packet 0 \
      -j DNAT --to-destination "$ip:$PORT"
  else
    iptables -t nat -A LAB-SVC-MB -d "$VIP/32" -p tcp --dport "$PORT" \
      -j DNAT --to-destination "$ip:$PORT"
  fi
  i=$((i + 1))
done
echo "kube-proxy: rotation rebuilt with $COUNT endpoint(s)"
EOF
sudo chmod +x /opt/lab-mb/readiness.sh
sudo /opt/lab-mb/readiness.sh
```
**Situation:** exactly half of all checkouts fail — with beautiful regularity:

```bash
for i in $(seq 8); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://10.96.10.5:8080/; done
# 200 / 500 / 200 / 500 / 200 / 500 / 200 / 500
```

Pod-2 is genuinely sick: it answers **HTTP 500 on every request, including `/healthz`**. That's fine — that's what readiness controllers are *for*: probe, notice, eject from rotation. Except this one just printed `readiness: 2 of 2 pods ready`. It probed the sick pod's `/healthz`, received a `500 NullPointerException` … and called it ready. The on-call verdict — *"kube-proxy keeps routing to a dead pod"* — is wrong twice: the pod isn't dead (worse: it's alive and failing), and kube-proxy only serves what readiness feeds it.

**Your task:** read `/opt/lab-mb/readiness.sh` and find why a probe that *received an HTTP 500* reports success — the bug is one missing flag on one line. Say precisely the distinction the buggy probe collapses: **transport success** (TCP connected, an HTTP response arrived) vs **HTTP success** (that response was 2xx). Fix the probe, re-run the controller, and prove the rotation now holds only the healthy pod. (Don't "fix" pod-2 itself — sick pods are a fact of life; controllers that can't see sickness are the outage.)

**Project link:** this is a readinessProbe that checks "port open" when it should check "HTTP 200" — the k8s readiness probe removing a pod from **EndpointSlices** is what keeps S21's rolling updates zero-downtime, and the ALB's target-group health check expecting `200` (Climb 8) is the same idea one layer up. `curl -f` is the one-character-class difference between "the pod spoke" and "the pod is well".

**Verify:**
```bash
sudo /opt/lab-mb/readiness.sh
# expected: readiness: 1 of 2 pods ready: 10.90.11.2
# expected: kube-proxy: rotation rebuilt with 1 endpoint(s)
for i in $(seq 6); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://10.96.10.5:8080/; done
# expected: six 200s — the failing pod has been ejected from the statistic-mode rotation
```

#### 🔴 Scenario 10.6 — "Antigua: the canary stuck at 100/0" (Expert)
**Setup:**
```bash
sudo apt-get install -y nginx >/dev/null      # standalone binary again — silence the distro service
sudo systemctl stop nginx 2>/dev/null || true
sudo systemctl disable nginx 2>/dev/null || true
sudo ip link add lab0 type bridge 2>/dev/null || true
sudo ip link set lab0 up
sudo ip addr add 10.90.12.1/24 dev lab0
sudo mkdir -p /opt/lab-ag/www-v1 /opt/lab-ag/www-v2
echo 'catalogue v1' | sudo tee /opt/lab-ag/www-v1/index.html >/dev/null
echo 'catalogue V2-CANARY' | sudo tee /opt/lab-ag/www-v2/index.html >/dev/null
mkpod() {   # mkpod <netns> <host-veth> <ip>
  sudo ip netns add "$1"
  sudo ip link add "$2" type veth peer name eth0 netns "$1"
  sudo ip link set "$2" master lab0 up
  sudo ip netns exec "$1" ip addr add "$3/24" dev eth0
  sudo ip netns exec "$1" ip link set eth0 up
  sudo ip netns exec "$1" ip link set lo up
}
mkpod labns-ag-v1 labveth-ag1 10.90.12.2
mkpod labns-ag-v2 labveth-ag2 10.90.12.3
sudo ip netns exec labns-ag-v1 bash -c 'cd /opt/lab-ag/www-v1 && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
sudo ip netns exec labns-ag-v2 bash -c 'cd /opt/lab-ag/www-v2 && nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
# the "VirtualService", compiled to nginx: 90/10 by weight + header pin to the canary
sudo tee /opt/lab-ag/nginx.conf >/dev/null <<'EOF'
pid /opt/lab-ag/nginx.pid;
error_log /opt/lab-ag/error.log;
worker_processes 1;
events {}
http {
  access_log /opt/lab-ag/access.log;
  proxy_connect_timeout 1s;
  upstream weighted {
    server 10.90.12.2:8080 weight=9;
    server 10.90.12.3:8080 weight=1;
  }
  upstream canary {
    server 10.90.12.3:8080;
  }
  map $http_canary $pool {
    default weighted;
    "true"  canary;
  }
  server {
    listen 8490;
    location / { proxy_pass http://$pool; }
  }
}
EOF
sudo nginx -c /opt/lab-ag/nginx.conf
# ...and then the night shift happened. Two changes landed overnight; you'll
# meet them both from the symptoms. (Resist reverse-engineering these lines.)
sudo ip link set labveth-ag2 down
```
**Situation:** yesterday QA signed off on the canary rollout: 90% `catalogue v1`, 10% `catalogue V2-CANARY`, and the header pin `x-canary: true` → always V2 (the S22 §6.5 semantics exactly). This morning the dashboard shows **100% v1, 0% v2 — with zero errors and zero alerts** (only a p99 latency blip nobody can explain). Worse:

```bash
for i in $(seq 30); do curl -s http://localhost:8490/; done | sort | uniq -c
#     30 catalogue v1          ← the canary receives NOTHING
curl -s -H 'x-canary: true' http://localhost:8490/
# catalogue v1                 ← even QA's absolute pin returns v1!
```

Product is asking whether the canary "silently rolled itself back". It didn't. **Two independent faults** are stacked, and each one is masking evidence of the other: one is silently eating the canary's 10%, the other broke the header pin — so no path reaches v2 at all.

**Your task:** untangle both. Start where a mesh operator starts: the proxy's error log (`/opt/lab-ag/error.log`) — if v2 is getting zero traffic *and* zero errors are reaching clients, is the proxy even *trying* v2? (It is. Find the evidence, and name the retry behavior that turns a dead upstream into "no errors, just latency".) Chase that dead upstream down the stack from Climb 9: pod process → pod listener → the pod's cable on the host. Then, with the cable fixed, the weighted 90/10 will work — but the header pin still won't: read the `map` line against how nginx names header variables (what variable does the header `x-canary` actually become?). Fix the config and reload: `sudo nginx -c /opt/lab-ag/nginx.conf -s reload`. **Verify demands both halves.**

**Project link:** this is the S22 VirtualService canary with two real-world failure modes stacked: (1) Envoy/nginx **silent retry** (`proxy_next_upstream` / Envoy retry policy) masking a dead subset — traffic "fails over" so cleanly that the canary flatlines with no 5xx, only a latency bump, exactly why canary *dashboards* must watch per-subset traffic, not error rate; and (2) the header-match bug — nginx maps header `x-canary` to `$http_x_canary` (dashes→underscores), so `$http_canary` matches a header literally named `Canary` — the config-that-looks-right class of bug that code review misses and only a 5/5 pin test catches.

**Verify:**
```bash
for i in $(seq 30); do curl -s http://localhost:8490/; done | sort | uniq -c
# expected: 27 catalogue v1 / 3 catalogue V2-CANARY (smooth weighted round-robin makes it exactly 27/3)
for i in $(seq 5); do curl -s -H 'x-canary: true' http://localhost:8490/; done | sort | uniq -c
# expected: 5 catalogue V2-CANARY — the pin is absolute, all five
```



---

## 🔑 Lab Answers — Solutions & Explanations

> Attempt each scenario above with the **Verify** command before reading these. Each solution explains not just *what* to type but *why it works* — tying the fix back to the climb's machinery and to the specific Retail-Store project artifact it mirrors, with a one-line map from each local analogue to the real AWS/Kubernetes object.

### Climb 1 — IP Addressing, CIDR & Subnetting: the VPC's Grammar

#### Scenario 1.1 — "Bologna: the mask decides who is local"
**Solution:**
```bash
python3 - <<'EOF'
import ipaddress as ip
vpc   = ip.ip_network('10.0.0.0/16')
subs  = [ip.ip_network(s) for s in ('10.0.1.0/24','10.0.2.0/24','10.0.11.0/24','10.0.12.0/24')]
probe = ip.ip_address('10.0.11.57')
print('in VPC /16 ?', probe in vpc)
print('in 10.0.1.0/24 ?', probe in ip.ip_network('10.0.1.0/24'))
for s in subs:
    if probe in s:
        print('home subnet:', s, '-> private (teens .11/.12)')
print('AWS usable /24 =', subs[2].num_addresses - 5)
EOF
```
**Why this works & what it teaches:** A `/N` mask compares only the first N bits. `10.0.11.57` shares the first 16 bits (`10.0`) with the VPC → inside; but bits 17–24 are `11`, not `1`, so it is NOT in `10.0.1.0/24` — it lands in `10.0.11.0/24`, a **private** subnet (course convention: teens = private). A `/24` is `2^(32−24)=256` addresses; AWS reserves 5, leaving 251. This is exactly the S06–07 subnet plan and the Rung 5 trace — the third octet alone tells you public vs private.

#### Scenario 1.2 — "Verona: read your node's addressing"
**Solution:**
```bash
ip -br addr                                   # every attachment: name state IP/mask
ip -br addr show lo                            # loopback 127.0.0.1/8
PRIMARY=$(hostname -I | awk '{print $1}')
python3 -c "import ipaddress,sys;a='$PRIMARY';n=ipaddress.ip_address(a);print(a,'is_private=',n.is_private)"
# host bits left on a /N: 32 - N
```
**Why this works & what it teaches:** Every Linux interface carries address+mask just like a VPC subnet attachment; `ip -br addr` is the local equivalent of reading an ENI's private IP. An RFC1918 address (`10.x`, `172.16–31.x`, `192.168.x`) reports `is_private=True` — the same ranges the VPC uses (Rung 3). Loopback's `/8` means all of `127.0.0.0/8` is local-only. This is Rung 7 Lab 2: your laptop is a VPC-in-miniature.

#### Scenario 1.3 — "Palermo: the overlap that breaks peering"
**Solution:**
```bash
python3 - <<'EOF'
import ipaddress as ip
prod = ip.ip_network('10.0.0.0/16')
for s in ('10.0.1.0/24','10.0.2.0/24','10.0.11.0/24','10.1.11.0/24'):
    print(s, 'OVERLAP' if ip.ip_network(s).overlaps(prod) else 'clean')
# clean replacement block for the second VPC:
for s in ('10.2.1.0/24','10.2.2.0/24','10.2.11.0/24','10.2.12.0/24'):
    print(s, 'overlaps prod?', ip.ip_network(s).overlaps(prod))
EOF
```
**Why this works & what it teaches:** VPC peering routes between two CIDR spaces, so any address that could exist in both is ambiguous — AWS forbids the peering outright. `10.0.1.0/24`, `10.0.2.0/24`, `10.0.11.0/24` are all subsets of the prod `10.0.0.0/16`, so `.overlaps()` is True; only `10.1.11.0/24` (different second octet) is clean. Choosing a fresh `/16` like `10.2.0.0/16` for the whole second VPC guarantees no collision. This is Rung 3's "overlaps are forever" — the reason S06 plans ranges up front. **Where people go wrong:** assuming `terraform apply` succeeding means the design is sound — the overlap only bites later, at peering time.

#### Scenario 1.4 — "Genoa: the day the pods ran out of IPs"
**Solution:**
```bash
python3 - <<'EOF'
import ipaddress as ip
demand = 50 * 20
usable = sum(ip.ip_network(s).num_addresses - 5 for s in ('10.0.11.0/24','10.0.12.0/24'))
print('pod IP demand :', demand)
print('usable (2x/24):', usable, '= 2 * (256-5)')
print('deficit       :', demand - usable)
print('secondary 100.64.0.0/16 adds:', ip.ip_network('100.64.0.0/16').num_addresses - 5)
EOF
```
**Why this works & what it teaches:** On EKS the VPC CNI gives every pod a **real subnet IP**, so pod capacity is literally the subnets' host count, not a K8s setting. Two `/24`s = `2 × (256−5) = 502` usable, but 20 nodes × 50 pods = 1,000 pods → a 498-IP deficit, and pods stick in `ContainerCreating` with "failed to assign an IP." A **secondary CIDR** (AWS supports adding ranges like `100.64.0.0/16`, RFC6598 CGNAT space) attaches more subnets to the same VPC and adds tens of thousands of IPs. This is Rung 5 step 5 verbatim. **Where people go wrong:** blaming the autoscaler when the true ceiling is subnet sizing.

#### Scenario 1.5 — "Pisa: two subnets, one wrong mask"
**Solution:**
```bash
# reproduce the failure from the private node:
sudo ip netns exec labns-priv ip route get 10.0.1.10   # shows no on-link route / needs gateway
sudo ip netns exec labns-priv ping -c1 -W1 10.0.1.10 || echo "unreachable: /28 hid the peer"
# FIX: the shared segment is a /24 — re-mask the private node
sudo ip netns exec labns-priv ip addr del 10.0.11.10/28 dev labveth-priv
sudo ip netns exec labns-priv ip addr add 10.0.11.10/24 dev labveth-priv
sudo ip netns exec labns-priv ping -c1 -W1 10.0.1.10 && echo "reachable after /24"
```
**Why this works & what it teaches:** The kernel decides "local or via gateway?" by masking the destination with the interface mask and comparing to its own network. Both nodes share one L2 broadcast domain via `lab0`, but with `10.0.11.10/28` the private node's network is only `10.0.11.0/15..` — actually `10.0.11.0–10.0.11.15` — so `10.0.1.10` (and even `10.0.11.20`) falls *outside* and the kernel demands a non-existent gateway. Correcting to `/24` makes the peer on-link and ARP resolves directly. This is Rung 3's "the mask is a decision boundary, not decoration." **Where people go wrong:** copying a host's IP but not its mask. **Local→AWS map:** the two netns nodes on `lab0` = two ENIs/instances on one VPC subnet segment; the mask bug = a subnet/ENI configured with the wrong prefix length.
**Cleanup:**
```bash
sudo ip netns del labns-pub; sudo ip netns del labns-priv; sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 1.6 — "Siena: which private node can't phone home"
**Solution:**
```bash
sudo ip netns exec labns-a ip route get 10.0.11.1    # on-link via labveth-a
sudo ip netns exec labns-a ping -c1 -W1 10.0.11.1 && echo "A ok"
sudo ip netns exec labns-b ip route get 10.0.11.1    # B: gateway seen as off-link (wrong subnet)
sudo ip netns exec labns-b ping -c1 -W1 10.0.11.1 || echo "B fails: node is in 10.0.12.0/24, gw in 10.0.11.0/24"
# FIX: re-address B into the correct private-1a subnet, keep host .30
sudo ip netns exec labns-b ip addr del 10.0.12.30/24 dev labveth-b
sudo ip netns exec labns-b ip addr add 10.0.11.30/24 dev labveth-b
sudo ip netns exec labns-b ip route replace default via 10.0.11.1
sudo ip netns exec labns-b ping -c1 -W1 10.0.11.1 && echo "B ok after re-address"
```
**Why this works & what it teaches:** Node B sits on the right *wire* but was given a `10.0.12.30/24` address, so its own network is `10.0.12.0/24`. Its default route `via 10.0.11.1` requires the gateway to be on-link, but `10.0.11.1` is outside B's `10.0.12.0/24` — the kernel can't even ARP for it, so the route is unusable and every packet dies. Node A, correctly in `10.0.11.0/24`, resolves `.1` directly. Re-addressing B into `10.0.11.0/24` makes the gateway on-link. This is Rung 5 (subnets are AZ-scoped; the subnet choice *is* the placement decision) and the Check-yourself lesson that the third octet defines the subnet. **Local→AWS map:** the netns nodes = worker instances/ENIs; putting B in `10.0.12.x` on the 1a segment = launching a node into the wrong subnet ID, breaking its route to the subnet's gateway.
**Cleanup:**
```bash
for n in a b gw; do sudo ip netns del labns-$n; done; sudo ip link del lab0 2>/dev/null || true
```

### Climb 2 — Ports & Sockets: One IP, Many Services

#### Scenario 2.1 — "Trieste: who is holding 8080?"
**Solution:**
```bash
ss -ltnp | grep ':8080 '          # LISTEN + users:(("python3",pid=...,fd=...))
PID=$(ss -ltnp | awk -F'pid=' '/:8080 /{split($2,a,",");print a[1]}')
echo "port 8080 owned by pid $PID"
curl -s localhost:8080
```
**Why this works & what it teaches:** `ss -ltnp` lists LISTEN sockets (`-l`), TCP (`-t`), numeric (`-n`), with owning process (`-p`) — the single source of truth for "what is actually bound here," the first move in every "port already allocated"/"connection refused" triage (Rung 3). The `pid=` field names the squatter so you can kill or reconfigure it. This is the mechanic behind the S02 `EADDRINUSE` Docker error. **Where people go wrong:** `curl`-ing the port and reading a 5xx/refused without first asking `ss` *whether anything is even listening*.

#### Scenario 2.2 — "Parma: the five-tuple, live"
**Solution:**
```bash
( curl -s --max-time 3 localhost:8081 >/dev/null & )
sleep 1
ss -tn | grep ':8081'             # ESTABLISHED 127.0.0.1:<ephemeral> -> 127.0.0.1:8081
sysctl net.ipv4.ip_local_port_range
```
**Why this works & what it teaches:** A connection is named by the five-tuple (proto, srcIP:srcPort, dstIP:dstPort). The server owns the fixed port 8081; the client's kernel borrows a random **ephemeral** port from `net.ipv4.ip_local_port_range` (typically 32768–60999) per connection. `ss -tn` shows both ends of the ESTABLISHED pair live. This asymmetry — fixed server port, random client port — is why firewall/SG rules name only the server port, and why stateless NACLs must open the ephemeral return range (the Climb 7 trap noted in Rung 3).

#### Scenario 2.3 — "Granada: EADDRINUSE, two services one port"
**Solution:**
```bash
/opt/lab-granada/orders.service.sh 2>&1 | grep -i "address already in use"   # collision
ss -ltnp | grep ':8080 '                                                     # carts owns it
# fix: point orders at a free lab port
sed -i 's/8080/8082/' /opt/lab-granada/orders.service.sh
/opt/lab-granada/orders.service.sh >/dev/null 2>&1 &
sleep 1
curl -s 127.0.0.1:8080 >/dev/null && curl -s 127.0.0.1:8082 >/dev/null && echo "both up"
```
**Why this works & what it teaches:** Only one socket may hold a given `address:port`; the second `bind()` fails with `EADDRINUSE`. carts grabbed `127.0.0.1:8080` first, so orders — hardcoded to the same tuple — cannot start. On a real cluster both listen on 8080 happily because each container has its **own network namespace** (a distinct address per pod), so the tuples differ — exactly why "all services on 8080" works in K8s but not when run bare on one host (Rung 3). Moving orders to 8082 makes the tuples distinct. **Where people go wrong:** thinking the port number itself is taken globally — it's the *address:port* pair, per namespace.

#### Scenario 2.4 — "Segovia: publish the ui, hide the carts"
**Solution:**
```bash
curl -s --max-time 2 10.9.0.2:8080          # internal path works (the veth = docker network)
curl -s --max-time 2 localhost:8888 || echo "no doorway (like ports: [])"
# publish 8888:8080 by hand — socat is the userspace DNAT doorway
socat TCP-LISTEN:8888,fork,reuseaddr TCP:10.9.0.2:8080 >/dev/null 2>&1 &
sleep 1
curl -s localhost:8888                       # now answers: carts internal only
```
**Why this works & what it teaches:** carts listens inside `labns-svc` and is reachable only across the veth link — its "internal Docker network." The host's `localhost:8888` has no path in until you add one, mirroring S04's `ports: []` (internal only) vs `8888:8080` (a published doorway). `socat TCP-LISTEN:8888 → 10.9.0.2:8080` is the userspace equivalent of the iptables DNAT rule Docker installs for `-p 8888:8080` (Rung 3: "mechanically a DNAT rule"). Same listening socket, only the *doorway* was added — the ClusterIP-vs-LoadBalancer lesson S08 repeats. **Local→AWS map:** netns+veth = container network namespace; `socat` doorway = the `-p` DNAT / a K8s NodePort.
**Cleanup:**
```bash
pkill -f 'TCP-LISTEN:8888' 2>/dev/null || true
sudo ip netns del labns-svc; sudo ip link del labveth-svc-host 2>/dev/null || true
```

#### Scenario 2.5 — "Toledo: port → targetPort → nodePort, three doorways deep"
**Solution:**
```bash
socat TCP-LISTEN:7080,fork,reuseaddr  TCP:127.0.0.1:8080 >/dev/null 2>&1 &   # Service port -> targetPort
socat TCP-LISTEN:30080,fork,reuseaddr TCP:127.0.0.1:7080 >/dev/null 2>&1 &   # NodePort -> Service port
sleep 1
curl -s 127.0.0.1:8080    # targetPort (the pod)
curl -s 127.0.0.1:7080    # Service port
curl -s 127.0.0.1:30080   # NodePort — full three-hop chain
# bug: targetPort points at a dead port
socat TCP-LISTEN:7081,fork,reuseaddr TCP:127.0.0.1:9999 >/dev/null 2>&1 &
sleep 1
curl -s --max-time 2 127.0.0.1:7081 || echo "TCP accepted, no app reply -> bad targetPort"
```
**Why this works & what it teaches:** K8s Services are port translation three deep: NodePort (30000–32767) → Service `port` → `targetPort` (the container's real port). Each `socat` hop is one translation; chaining them reproduces a client's path to a pod (Rung 3). When `targetPort` points at a port nothing listens on (9999), the *front* hops still complete the TCP handshake — so `nc`/`port-forward` "connects" — but the app reply never arrives, isolating the broken hop. This is why "`port-forward 7080:8080` works but the NodePort 404s" points at the Service/targetPort mapping, not the pod. **Where people go wrong:** concluding "the port is open" from a successful connect when the *targetPort* is wrong.
**Cleanup:**
```bash
pkill -f 'TCP-LISTEN:7080' 2>/dev/null; pkill -f 'TCP-LISTEN:30080' 2>/dev/null; pkill -f 'TCP-LISTEN:7081' 2>/dev/null || true
```

#### Scenario 2.6 — "Cadiz: refused vs timeout — name the failure"
**Solution:**
```bash
nc -zv -w1 10.8.0.2 3306   # succeeded  -> listener present
nc -zv -w1 10.8.0.2 6379   # refused (RST) -> nothing listening on that port
nc -zv -w2 10.8.0.2 5432   # timed out   -> packet DROPped (filtered)
```
**Why this works & what it teaches:** Two failures look alike to `curl` but are opposites at L4. **Refused** = the host sent a TCP RST because no socket listens (6379) → fix the app/port. **Timeout** = packets vanish with no reply because a firewall/SG DROPs them (5432) → open the rule. The listener on 3306 succeeds. `nc -zv` names which happened before you touch the app. This is Rung 6's L4-vs-L7 distinction and the S14/S19 "connect timeout" rows: a timeout maps to an SG rule that must admit the client (Climb 7's stateful firewall), never to app code. **Where people go wrong:** restarting the app for a *timeout* (a firewall problem) or editing SGs for a *refused* (a listener problem). **Local→AWS map:** the `iptables … DROP` = a Security Group with no inbound rule for that port.
**Cleanup:**
```bash
sudo ip netns del labns-db; sudo ip link del labveth-db-host 2>/dev/null || true
```

### Climb 3 — DNS: Names Over Addresses

#### Scenario 3.1 — "Salamanca: the hosts file that wins"
**Solution:**
```bash
grep hosts: /etc/nsswitch.conf                 # order: files dns
getent hosts catalog-mysql.lab.internal        # 203.0.113.9  (files layer answers)
dig +short catalog-mysql.lab.internal          # (empty)      (server layer never heard of it)
```
**Why this works & what it teaches:** `nsswitch.conf` lists `hosts: files dns`, so glibc checks `/etc/hosts` *before* any nameserver — a match there ends resolution and DNS is never consulted (Rung 3). `getent`/apps honor this chain; `dig`/`nslookup` bypass files and ask the server directly. So `getent` returning an IP that `dig` denies is the unmistakable signature of a hosts-file override — the exact asymmetry that solves "dig resolves it but the app can't" (or the reverse) tickets. This same CNAME/alias mechanic is what an ExternalName Service serves in-cluster.
**Cleanup:**
```bash
sudo sed -i '/catalog-mysql.lab.internal/d' /etc/hosts    # restore original /etc/hosts
```

#### Scenario 3.2 — "Girona: who does this box ask?"
**Solution:**
```bash
grep -E '^(nameserver|search|options)' /etc/resolv.conf
grep -E 'hosts:' /etc/nsswitch.conf
getent hosts localhost
```
**Why this works & what it teaches:** `/etc/resolv.conf` answers "who do I ask + which suffixes do I try," and `nsswitch` answers "in what order (files vs dns)." Reading them is the mandatory first step before debugging any name failure, because a pod's version of this same file is written by kubelet to point at CoreDNS (`nameserver 172.20.0.10`, `search default.svc.cluster.local svc.cluster.local cluster.local`, `options ndots:5`). Your VM's resolver (often `127.0.0.53` systemd-resolved or a stub) is the local analogue of that CoreDNS pointer (Rung 3).

#### Scenario 3.3 — "Braga: stand up a Route 53 in a can"
**Solution:**
```bash
sudo dnsmasq --conf-file=/opt/lab-braga/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
dig @127.0.0.1 -p 8053 +short shop.lab.internal      # 198.51.100.20
dig @127.0.0.1 -p 8053 +short catalog.lab.internal   # 198.51.100.21
# add a record and reload the zone:
echo 'address=/checkout.lab.internal/198.51.100.22' | sudo tee -a /opt/lab-braga/zone.conf >/dev/null
sudo pkill -HUP dnsmasq
dig @127.0.0.1 -p 8053 +short checkout.lab.internal  # 198.51.100.22
```
**Why this works & what it teaches:** A `dnsmasq` instance holding `address=/name/ip` records is a private authoritative zone — the local stand-in for a Route 53 hosted zone (Rung 4: "the DB of records for a domain"). Querying it with `dig @127.0.0.1 -p 8053` targets that resolver directly without ever touching the VM's real `/etc/resolv.conf` (safe, reversible). Adding a record and `SIGHUP`-reloading models ExternalDNS/console edits to a zone. **Local→AWS map:** the dnsmasq zone = a Route 53 hosted zone; each `address=` line = an A record.
**Cleanup:**
```bash
sudo pkill -f 'lab-braga/zone.conf' 2>/dev/null || true
```

#### Scenario 3.4 — "Coimbra: the CNAME that hides the RDS churn"
**Solution:**
```bash
sudo dnsmasq --conf-file=/opt/lab-coimbra/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
dig @127.0.0.1 -p 8053 catalog-mysql.svc.lab.internal        # CNAME -> mydb3... , A 192.0.2.55
# simulate terraform destroy+apply: only the RDS A record changes
sudo sed -i 's#mydb3.abc123.lab-rds.internal/192.0.2.55#mydb3.abc123.lab-rds.internal/192.0.2.77#' /opt/lab-coimbra/zone.conf
sudo pkill -HUP dnsmasq
dig @127.0.0.1 -p 8053 +short catalog-mysql.svc.lab.internal | tail -1   # 192.0.2.77 — alias name unchanged
```
**Why this works & what it teaches:** `catalog-mysql` is served as a **CNAME** to the current RDS hostname — precisely what a K8s ExternalName Service is (Rung 5). The app dials the stable alias and never learns the real hostname or IP. When RDS rotates, you paste the new value into exactly one place (the alias target / `spec.externalName`), and every app that dials `catalog-mysql` follows transparently — the Check-yourself payoff: "one edit, one object." The CNAME hop you see in `dig` is the same one `www.github.com` shows, and the same mechanic across all four course scales. **Local→AWS map:** the `cname=` line = the ExternalName Service; the RDS A record = the actual RDS endpoint that churns.
**Cleanup:**
```bash
sudo pkill -f 'lab-coimbra/zone.conf' 2>/dev/null || true
```

#### Scenario 3.5 — "Faro: short names, search domains & ndots"
**Solution:**
```bash
sudo ip netns exec labns-pod dnsmasq --conf-file=/opt/lab-faro/zone.conf --no-daemon >/dev/null 2>&1 &
sleep 1
sudo ip netns exec labns-pod getent hosts catalog-service                        # 172.20.0.55 (search-completed)
sudo ip netns exec labns-pod dig +short catalog-service.default.svc.lab.internal # 172.20.0.55 (explicit FQDN)
sudo ip netns exec labns-pod dig +short catalog-service                          # (empty — dig does NOT apply search)
```
**Why this works & what it teaches:** Only the FQDN `catalog-service.default.svc.lab.internal` exists in the zone. glibc's resolver, driven by the per-netns `resolv.conf`, appends each `search` suffix to the short name until one resolves — so `getent hosts catalog-service` succeeds via `…default.svc.lab.internal` (Rung 3/4). `ndots:5` means any name with fewer than 5 dots is tried against the search list *first*, which is why bare Service names work in-cluster. `dig` performs no search expansion, so `dig catalog-service` fails while the full FQDN succeeds — the same files-vs-server-vs-search asymmetry that solves real tickets. Using a per-netns `resolv.conf` (in `/etc/netns/labns-pod/`) means the host's real resolver is never touched. **Local→AWS map:** the per-netns resolv.conf = kubelet-written pod resolv.conf; the search list = CoreDNS `svc.cluster.local` search paths.
**Cleanup:**
```bash
sudo ip netns exec labns-pod pkill dnsmasq 2>/dev/null || true
sudo rm -rf /etc/netns/labns-pod; sudo ip netns del labns-pod
```

#### Scenario 3.6 — "Cascais: ExternalDNS reconciles the zone"
**Solution:**
```bash
dig @127.0.0.1 -p 8053 +short shop.lab.internal        # BEFORE: empty (NXDOMAIN)
/opt/lab-cascais/externaldns.sh                        # reconciled: shop.lab.internal -> 203.0.113.80
sleep 1
dig @127.0.0.1 -p 8053 +short shop.lab.internal        # AFTER: 203.0.113.80
# change the Ingress ALB target and re-reconcile:
sed -i 's/203.0.113.80/203.0.113.99/' /opt/lab-cascais/ingress.txt
/opt/lab-cascais/externaldns.sh
sleep 1
dig @127.0.0.1 -p 8053 +short shop.lab.internal        # 203.0.113.99 (converged)
```
**Why this works & what it teaches:** The reconciler reads the desired hostname/target from the "Ingress annotation" file and *writes* the record into the hosted zone, then reloads — DNS as reconciled infrastructure, exactly what ExternalDNS does with Route 53 from `external-dns.alpha.kubernetes.io/hostname` (Rung 3/4). Before reconcile the name is `NXDOMAIN`; after, it resolves; changing the annotation converges the zone again. The `ttl=60` matters: a resolver that cached the old answer keeps serving it until TTL expiry — why DNS changes "take a while" (Rung 3 caching) and why DNS is the wrong tool for sub-second failover (Rung 6). **Local→AWS map:** `externaldns.sh` = the ExternalDNS controller; `ingress.txt` = the Ingress + its annotation; the `records.d` drop-dir + dnsmasq = the Route 53 hosted zone; `target` = the ALB address ExternalDNS reads.
**Cleanup:**
```bash
sudo pkill -f 'lab-cascais/zone.conf' 2>/dev/null || true
rm -rf /opt/lab-cascais
```


### Climb 4 — HTTP & HTTPS: the Protocol Every Microservice Speaks

#### Scenario 4.1 — "Dubai: the health path that held the whole stack hostage"
**Solution:**
```bash
# Run the probe by hand exactly as gate.sh does — read status AND exit code
curl -f http://localhost:8010/health; echo "probe exit=$?"   # 404 body, exit 22
# See what the server actually serves: last night's rename left the doc at /actuator-health
curl -s http://localhost:8010/ | grep -o 'actuator-health'
# Fix ON THE APP SIDE (do NOT touch gate.sh — /health is the platform contract).
# Publish the health document at the path the probe demands:
cp /opt/lab-dubai/www/actuator-health /opt/lab-dubai/www/health
# gate.sh loops every 2s; within ~2s the probe now returns 200 and the gate opens
sleep 3
cat /opt/lab-dubai/ui.started
```
**Why this works & what it teaches:** The startup gate is `depends_on: {condition: service_healthy}` by hand — it polls `curl -f /health` and only opens when curl exits 0. Last night's "harmless rename" put the JSON at `/actuator-health`, so `/health` 404s, `curl -f` exits 22, and the gate blocks forever. The fix belongs on the app (serve the document at the contract path), never on the probe. Local analogue: `python3 -m http.server` docroot = the carts container; the `until curl -fsS` loop = Compose's `service_healthy` gate / a K8s readiness probe / an ALB target-group health check. Where people go wrong: they "fix" the probe path instead of honoring the platform's fixed contract, or they read the 200-on-`/` and miss that the probe hits a different path.

#### Scenario 4.2 — "Doha: reading the verdict: 200, 404, and the exit code that is a probe"
**Solution:**
```bash
# Triage all five paths by status class: 2xx works / 4xx caller / 5xx server-side
for p in /health /orders /cart /admin /checkout; do
  curl -s -o /dev/null -w "$p -> %{http_code}\n" http://localhost:8020$p
done
# /checkout -> 500 is the ONE that pages the checkout team (server-side fault), not the caller
# Read both directions of the raw grammar on /checkout
curl -v http://localhost:8020/checkout 2>&1 | grep -E '^[<>]'
# HEAD-only verdict on /orders — what cheap monitors do (no body)
curl -I http://localhost:8020/orders
# The probe exit code: -f makes curl exit 22 on >=400, 0 on 2xx — the health verdict itself
curl -f -s http://localhost:8020/cart >/dev/null;   echo "probe exit=$?"   # 22
curl -f -s http://localhost:8020/health >/dev/null;  echo "probe exit=$?"  # 0
```
**Why this works & what it teaches:** Nothing is broken here — the lesson is triage by status class using curl's four reading tools (`-v -I -w -f`). `-f` converts any `>=400` into exit 22, which is exactly why every healthcheck in the course consumes the exit code and never parses the body: the kernel/curl already rendered the verdict. `/checkout` 500 is the only server-side fault (pages the owning team); 403/404 are caller faults. Local analogue: this handler is any S02–S08 REST service (`/health`, `/topology`, `/catalog/products`), and the exit-code test is the ALB target-group health check and the K8s probe. Where people go wrong: reading a 4xx/5xx body and paging the wrong team, instead of letting the status class route the page.

#### Scenario 4.3 — "Muscat: 502 at the door: the backend that wasn't there"
**Solution:**
```bash
# Reproduce the 502 through the proxy (the ALB analogue)
curl -s -o /dev/null -w 'code=%{http_code}\n' http://localhost:8030/catalog/products  # 502
# The proxy's target group is hard-wired to 127.0.0.1:8031 — prove nothing listens there
nc -z 127.0.0.1 8031 && echo up || echo "NOTHING on 8031"
ss -ltn | grep -E ':803[12]'          # catalog bound 8032 (typo'd CATALOG_PORT in setup)
# Kill the mis-bound catalog, then start one on the port the proxy actually connects to
kill "$(tail -1 /opt/lab-muscat/pids)" 2>/dev/null
cd /opt/lab-muscat
CATALOG_PORT=8031 nohup python3 catalog.py >/dev/null 2>&1 &
echo $! >> /opt/lab-muscat/pids
sleep 1
curl -s -o /dev/null -w 'code=%{http_code}\n' http://localhost:8030/catalog/products  # 200
```
**Why this works & what it teaches:** A 502 asks exactly one question — is anything listening where the proxy connects? Both processes being "up" is a red herring: the catalog bound 8032 (a typo'd env var), while the proxy's fixed target is 8031, so the proxy gets connection-refused and returns 502. `nc -z`/`ss -ltn` prove the empty port; rebinding catalog to 8031 heals it. Local analogue: `proxy.py`'s single hard-wired target = an ALB ip-mode target group pointing at a pod IP that no longer exists (S11/S16). Where people go wrong: trusting `ps` ("nothing is down") instead of checking the actual listen socket the proxy dials.

#### Scenario 4.4 — "Amman: one address, many shops: the Host header that missed"
**Solution:**
```bash
# Reproduce the 404 and READ the body — the router names the key it missed
curl -s http://localhost:8040/ | head -1     # 404: no vhost for Host=localhost
# Send the routing key yourself — no DNS needed
curl -s -H "Host: shop.devopsinminutes.com" http://localhost:8040/
# The honest way: --resolve makes URL, Host header, and (over TLS) SNI all agree
curl -s --resolve shop.devopsinminutes.com:8040:127.0.0.1 \
  http://shop.devopsinminutes.com:8040/
# A browser on this box would need an /etc/hosts line (the manual ExternalDNS):
#   127.0.0.1  shop.devopsinminutes.com
```
**Why this works & what it teaches:** One listener multiplexes many sites purely on the `Host` header; `curl http://localhost/` sends `Host: localhost`, which matches no vhost → 404, and the body prints the missed key. `-H "Host:"` overrides just that header, but `--resolve` is the better habit because over HTTPS it also fixes SNI and certificate name-matching — with `-H` the TLS SNI/cert would still say `localhost` and fail verification, whereas `--resolve` keeps the real hostname in the URL, Host, and SNI. Local analogue: the `Host`-based `SITES` dict = ALB listener host rules (S16), Istio Gateway `hosts:` (S22), and Ingress `host:` blocks (S11); `/etc/hosts`/`--resolve` = the manual version of ExternalDNS (S15-16). Where people go wrong: concluding "the LB is broken" from a by-IP test that never sent the real routing key.

#### Scenario 4.5 — "Beirut: 503: healthy pods, an unready store"
**Solution:**
```bash
# Read the LB's 503 body — it's a readiness verdict, not a crash
curl -s http://localhost:8050/                       # 503 ... 0 of 1 targets ready
# Probe the way the LB does (path from lb.conf), then the app's real path
cat /opt/lab-beirut/lb.conf                           # /healthz  (wrong path)
curl -s -o /dev/null -w 'healthz=%{http_code}\n' http://localhost:8051/healthz   # 404
curl -s http://localhost:8051/ready                   # 503 ... redis connect refused 8052
# FAULT #1 — satisfy checkout's Redis dependency: anything accepting TCP on 8052
nohup python3 -m http.server 8052 --bind 127.0.0.1 >/dev/null 2>&1 &
echo $! >> /opt/lab-beirut/pids
curl -s -o /dev/null -w 'ready=%{http_code}\n' http://localhost:8051/ready        # now 200
curl -s http://localhost:8050/                        # STILL 503 — fault #2 remains
# FAULT #2 — point the LB's probe at the app's real readiness path (re-read per request)
echo "/ready" > /opt/lab-beirut/lb.conf
curl -s http://localhost:8050/                        # checkout: cart total = $42
```
**Why this works & what it teaches:** Two stacked faults, and fixing one leaves the 503 in place — that trap is the whole lesson. The app is alive (`/` returns 200) but unready because its Redis dependency (TCP 8052) is down, so `/ready` returns 503; separately the LB probes the wrong path (`/healthz`) copied from an old chart. You must satisfy the dependency AND fix the probe path, proving each layer with a curl before moving on. 503 (unready — a failed readiness contract) is a different disease from 502 (unreachable/garbage — a failed connection). Local analogue: readiness probes gating Service endpoints (S08) and ALB target-group health checks (S11); checkout's Redis = S14. Where people go wrong: declaring victory after fixing only the dependency, or only the probe path. **Cleanup:** `kill $(cat /opt/lab-beirut/pids) 2>/dev/null; rm -rf /opt/lab-beirut`.

#### Scenario 4.6 — "Tashkent: 502 or 504? the two ways a backend breaks a promise"
**Solution:**
```bash
# Through the proxy: capture code AND timing for both paths
curl -s -o /dev/null -w '/catalog code=%{http_code} time=%{time_total}s\n' http://localhost:8060/catalog
curl -s -o /dev/null -w '/orders  code=%{http_code} time=%{time_total}s\n' http://localhost:8060/orders
# Predict first: /catalog fails near-instantly => 502 (bad response); /orders ~3s => 504 (timeout)
# Direct to 8061: backend advertised Content-Length then closed early -> curl exit 18
curl -sS http://localhost:8061/catalog >/dev/null; echo "direct catalog exit=$?"   # 18, "bytes missing"
# Direct to 8062: TCP connects instantly (not connectivity), but the answer takes ~10s > 3s budget
nc -vz 127.0.0.1 8062
# Fix both regressions — each is a flag file
rm -f /opt/lab-tashkent/truncate.on /opt/lab-tashkent/slow.on
# Re-verify through the proxy: both 200, well under 1s
curl -s -o /dev/null -w '/catalog code=%{http_code} time=%{time_total}s\n' http://localhost:8060/catalog
curl -s -o /dev/null -w '/orders  code=%{http_code} time=%{time_total}s\n' http://localhost:8060/orders
```
**Why this works & what it teaches:** The fastest on-call discriminator is time-to-failure, not the code: `/catalog` fails near-instantly (backend promised a `Content-Length` then truncated → curl exit 18 direct, which the proxy renders as 502 "bad response"), while `/orders` fails at ~3s (backend healthy but 10s > the proxy's 3s budget → 504). Both regressions are flag files; `rm` them and both go 200. The ALB sentence: 502 = "couldn't connect OR bad response," 504 = "connected but never answered in time." Local analogue: the ALB 502-vs-504 triage row (S11/S16) — 502 blames the target's answer, 504 blames the target's clock; reading `time_total` against the LB idle timeout is how you split them in CloudWatch. Where people go wrong: blaming the LB, or conflating 502 (Muscat's connection-refused / this scenario's truncation) with 504 (slow-but-alive). **Cleanup:** `kill $(cat /opt/lab-tashkent/pids) 2>/dev/null; rm -rf /opt/lab-tashkent`.

### Climb 5 — TLS, Certificates & mTLS: Trust on the Wire

#### Scenario 5.1 — "Tbilisi: --insecure on localhost, and why it's fine here"
**Solution:**
```bash
# Default curl refuses a self-signed cert — which verification check failed?
curl -s https://localhost:8443/ >/dev/null; echo "default exit=$?"   # 60: chain-of-trust
# -k works but drops AUTHENTICATION (encrypted, but you trust whoever answered)
curl -sk https://localhost:8443/ | head -1
# --cacert pins THIS cert as its own trust anchor -> fully verified, scoped to this command
curl -s --cacert /opt/lab-tbilisi/cert.pem https://localhost:8443/ | head -1
# Prove self-signed: subject == issuer
echo | openssl s_client -connect localhost:8443 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# Rule: -k is acceptable only when YOU control both ends of a loopback path (127.0.0.1),
# where no on-path attacker can sit. --cacert (scoped per-command trust) is the right tool
# for a lab CA — never install it into the system trust store.
```
**Why this works & what it teaches:** Three curls demonstrate the three verification checks: default fails the chain-of-trust check (exit 60) because the cert ends in no store curl holds; `-k` succeeds but silently trades away authentication (you get encryption to an unverified peer); `--cacert cert.pem` pins the self-signed cert as its own anchor and is fully verified. On loopback no one can sit on the path, so `-k` is defensible there and only there. Local analogue: `argocd login localhost:8080 --insecure` (S21) is exactly this — a self-signed service you port-forwarded yourself over loopback; the same flag against the production ALB would hand your session to any on-path interceptor. Where people go wrong: normalizing `-k` beyond loopback, or installing the lab CA system-wide instead of scoping trust with `--cacert`. **Cleanup:** `kill $(cat /opt/lab-tbilisi/pids) 2>/dev/null; rm -rf /opt/lab-tbilisi`.

#### Scenario 5.2 — "Yerevan: check the dates first: reading a chain like an SRE"
**Solution:**
```bash
# Interrogate the live endpoint: subject/issuer/dates + the verify verdict
echo | openssl s_client -connect localhost:8444 -CAfile /opt/lab-yerevan/ca.crt 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
echo | openssl s_client -connect localhost:8444 -CAfile /opt/lab-yerevan/ca.crt 2>/dev/null \
  | grep 'Verify return code'                                        # 0 (ok)
# Machine-readable expiry audit (what a cron/monitor wraps): exit 1 = expires in window
openssl x509 -in /opt/lab-yerevan/cart.crt    -noout -checkend $((30*24*3600)); echo "cart exit=$?"     # 1 -> file the ticket
openssl x509 -in /opt/lab-yerevan/catalog.crt -noout -checkend $((30*24*3600)); echo "catalog exit=$?"  # 0
# Expired right now? both pass -checkend 0 — the point is catching it BEFORE it happens
openssl x509 -in /opt/lab-yerevan/cart.crt    -noout -checkend 0; echo "cart now exit=$?"
openssl x509 -in /opt/lab-yerevan/catalog.crt -noout -checkend 0; echo "catalog now exit=$?"
```
**Why this works & what it teaches:** Expiry is the #1 TLS outage ("nothing changed but everything broke"), so the SRE habit is dates-first with exit codes, not eyeballs. `cart.crt` (20-day validity) is inside the 30-day window → `-checkend` exits 1 → renewal ticket; `catalog.crt` (365 days) exits 0. `-checkend 0` shows neither is expired yet — the whole point is pre-emption. Local analogue: ACM (S16) auto-renews the ALB's cert via the Route 53 DNS-validation record so this audit is unnecessary at the edge, and istiod rotates hours-long workload certs (S22) for the same reason — but self-managed endpoints (Argo CD, chart repos, webhook receivers) still need exactly this `-dates`/`-checkend` loop. Where people go wrong: eyeballing `-dates` instead of wrapping the exit code, so nothing pages before midnight. **Cleanup:** `kill $(cat /opt/lab-yerevan/pids) 2>/dev/null; rm -rf /opt/lab-yerevan`.

#### Scenario 5.3 — "Baku: the cert for the shop that got renamed"
**Solution:**
```bash
cd /opt/lab-baku
# Reproduce what monitoring sees (--resolve stands in for the moved DNS) -> exit 60
curl -s --cacert ca.crt --resolve retail.devopsinminutes.com:8445:127.0.0.1 \
  https://retail.devopsinminutes.com:8445/ >/dev/null; echo "exit=$?"
# The precise complaint + what the cert actually covers (clients match SAN only, CN is ignored)
curl -v --cacert ca.crt --resolve retail.devopsinminutes.com:8445:127.0.0.1 \
  https://retail.devopsinminutes.com:8445/ 2>&1 | grep -i 'subject name'
openssl x509 -in shop.crt -noout -ext subjectAltName        # DNS:old-shop...
# Fix like ACM would: reissue for the new name WITH the new SAN, using the lab CA
openssl req -newkey rsa:2048 -nodes -keyout retail.key -out retail.csr \
  -subj "/CN=retail.devopsinminutes.com" 2>/dev/null
openssl x509 -req -in retail.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 \
  -extfile <(echo "subjectAltName=DNS:retail.devopsinminutes.com") -out retail.crt 2>/dev/null
# Swap the server cert: kill old s_server, start with the new pair, record the PID
kill "$(cat pids)" 2>/dev/null
nohup openssl s_server -accept 8445 -cert retail.crt -key retail.key -www >/dev/null 2>&1 &
echo $! > pids
sleep 1
curl -s --cacert ca.crt --resolve retail.devopsinminutes.com:8445:127.0.0.1 \
  https://retail.devopsinminutes.com:8445/ >/dev/null; echo "exit=$?"    # 0
```
**Why this works & what it teaches:** Valid dates and a trusted CA still fail the third check — hostname match. The cert's SAN covers `old-shop`, the client asks for `retail`, so verification fails with exit 60 and "no alternative certificate subject name matches." Modern clients match SAN entries only (the CN is ignored), so the fix is to reissue with the new SAN — impersonating ACM's DNS-validated reissue with the lab CA on-box. Local analogue: the ACM cert on the ALB (S16) covers specific names; renaming the site or adding an Ingress/Istio Gateway host without adding a SAN fails every client this way; `s_server` + lab CA = ALB + ACM. Where people go wrong: reaching for `-k`, which would "fix" monitoring while blinding it to a real name-mismatch that browsers would still reject. **Cleanup:** `kill $(cat /opt/lab-baku/pids) 2>/dev/null; rm -rf /opt/lab-baku`.

#### Scenario 5.4 — "Samarkand: the certificate that expired at midnight"
**Solution:**
```bash
cd /opt/lab-samarkand
# Dates first — read notAfter (it's in the past)
echo | openssl s_client -connect localhost:8446 2>/dev/null | openssl x509 -noout -dates
# The three verdict forms an SRE meets
echo | openssl s_client -connect localhost:8446 -CAfile ca/ca.crt 2>/dev/null | grep 'Verify return code'  # 10 expired
openssl x509 -in leaf.crt -noout -checkend 0; echo "checkend exit=$?"    # exit 1
curl -s --cacert ca/ca.crt https://localhost:8446/ >/dev/null; echo "exit=$?"   # 60
# Renew: re-sign the SAME CSR with a FUTURE window; copy_extensions=copy carries the SAN
openssl ca -config ca/openssl.cnf -batch -notext -days 30 -in leaf.csr -out leaf-renewed.crt 2>/dev/null
openssl x509 -in leaf-renewed.crt -noout -dates -ext subjectAltName
# Swap the cert: same key, new cert, record the PID
kill "$(cat pids)" 2>/dev/null
nohup openssl s_server -accept 8446 -cert leaf-renewed.crt -key leaf.key -www >/dev/null 2>&1 &
echo $! > pids
sleep 1
echo | openssl s_client -connect localhost:8446 -CAfile ca/ca.crt 2>/dev/null | grep 'Verify return code'  # 0 (ok)
curl -s --cacert ca/ca.crt https://localhost:8446/ >/dev/null; echo "exit=$?"   # 0
```
**Why this works & what it teaches:** Simultaneous failure across every client with zero deploys has a one-item differential: expiry. `s_client` reports `Verify return code: 10 (certificate has expired)`, `-checkend 0` exits 1, and curl exits 60 — three faces of the same fact. The renewal re-signs the on-disk CSR with a future window; `copy_extensions = copy` carries the SAN from the CSR so the renewed cert keeps `DNS:localhost`. Local analogue: ACM (S16) auto-renews the ALB cert by re-proving domain ownership via the Route 53 record — the automated `openssl ca` re-sign — and istiod (S22) issues hours-long certs so "expired at midnight" is structurally impossible in the mesh. Where people go wrong: minting a new keypair when only a re-sign is needed, or forgetting `copy_extensions` and shipping a renewed cert with no SAN. **Cleanup:** `kill $(cat /opt/lab-samarkand/pids) 2>/dev/null; rm -rf /opt/lab-samarkand`.

#### Scenario 5.5 — "Almaty: the missing link: works in curl, fails in the browser"
**Solution:**
```bash
cd /opt/lab-almaty
# Two clients, one server: difference is purely which certs the CLIENT brought
curl -s --cacert ops-bundle.pem https://localhost:8447/ >/dev/null; echo "bundle exit=$?"   # 0 (bundle has the intermediate)
curl -s --cacert root.crt      https://localhost:8447/ >/dev/null; echo "root exit=$?"     # 60 (customer reality)
# On the wire: verdict 21, and count how many certs the server sends
echo | openssl s_client -connect localhost:8447 -CAfile root.crt 2>/dev/null | grep 'Verify return code'  # 21
echo | openssl s_client -connect localhost:8447 2>/dev/null | grep -c 'BEGIN CERT'                        # 1 (no chain)
# Offline proof: leaf is fine, the SERVED chain is incomplete
openssl verify -CAfile root.crt leaf.crt                       # fails: local issuer
openssl verify -CAfile root.crt -untrusted int.crt leaf.crt    # OK
# Fix the SERVER, not the clients: serve leaf + intermediate (the fullchain)
kill "$(cat pids)" 2>/dev/null
nohup openssl s_server -accept 8447 -cert leaf.crt -key leaf.key -cert_chain int.crt -www >/dev/null 2>&1 &
echo $! > pids
sleep 1
echo | openssl s_client -connect localhost:8447 -CAfile root.crt 2>/dev/null | grep 'Verify return code'  # 0 (ok)
curl -s --cacert root.crt https://localhost:8447/ >/dev/null; echo "root-only exit=$?"                    # 0
echo | openssl s_client -connect localhost:8447 2>/dev/null | grep -c 'BEGIN CERT'                        # 2
```
**Why this works & what it teaches:** The server sends the leaf only; the ops bundle happens to include the intermediate, so ops' smoke test quietly completed the server's homework, while customers (who hold only the root) hit exit 60 / verify code 21 ("unable to verify the first certificate" = can't build a path). `openssl verify -untrusted int.crt` proves the leaf is fine and the served chain is the defect. The fix is `-cert_chain int.crt` — "install the fullchain, not the cert" — on the server, not the clients. Local analogue: servers must serve leaf + intermediates (`fullchain.pem`); clients hold roots. ACM deploys the full chain invisibly on the ALB (S16), which is why you meet this only on self-managed endpoints (webhook receivers, chart repos, S12/S21). Where people go wrong: "fixing" it by shipping the intermediate to clients, or trusting a lenient client (a browser that fetches missing intermediates) over a strict root-only curl. **Cleanup:** `kill $(cat /opt/lab-almaty/pids) 2>/dev/null; rm -rf /opt/lab-almaty`.

#### Scenario 5.6 — "Bishkek: same name, wrong CA: the sidecar that lied"
**Solution:**
```bash
cd /opt/lab-bishkek
# CASE A — no client cert (the legacy cron VM): handshake rejected, exit 56, alert "certificate required"
curl -sS --cacert mesh-ca.crt https://localhost:8448/ >/dev/null; echo "no-cert exit=$?"   # 56
echo | openssl s_client -connect localhost:8448 -CAfile mesh-ca.crt 2>&1 | grep -i 'certificate required'
# CASE B — legitimate mesh identity: both directions verify -> 200
curl -s -o /dev/null -w 'mesh-identity code=%{http_code}\n' \
  --cacert mesh-ca.crt --cert ui.crt --key ui.key https://localhost:8448/                  # 200
# CASE C — pentester's cert: same name (CN=ui.default.svc), WRONG CA -> exit 56, alert "unknown ca"
curl -sS --cacert mesh-ca.crt --cert rogue.crt --key rogue.key https://localhost:8448/ >/dev/null; echo "rogue exit=$?"  # 56
echo | openssl s_client -connect localhost:8448 -CAfile mesh-ca.crt \
  -cert rogue.crt -key rogue.key 2>&1 | grep -i 'unknown ca'
# Ticket replies:
#  (A) the cron VM isn't broken — it's OUTSIDE the trust domain; it needs a mesh-issued
#      identity (or a mesh ingress), not a firewall change.
#  (C) the pentest claim is false — mTLS identity is the CA's SIGNATURE, not the subject
#      string; the matching name bought the attacker nothing.
```
**Why this works & what it teaches:** STRICT mTLS runs the same three checks in reverse against the mesh CA. Case A (no client cert) fails with `certificate required` (exit 56) — the caller, not the server, failed identity. Case B (a mesh-signed cert) verifies both directions → 200. Case C is the crux: a cert with the exact name `ui.default.svc` but signed by a rogue CA is rejected with `unknown ca`, because the server asks "who signed you?", never "what are you called?". Local analogue: the `s_server -Verify 2 -CAfile mesh-ca.crt` pair = two Envoy sidecars under Istio STRICT `PeerAuthentication` (S22); `CN=ui.default.svc` plays the SPIFFE identity `spiffe://cluster.local/ns/default/sa/ui` that `AuthorizationPolicy` matches. Case A is every non-mesh workload the day STRICT lands; Case C is why the mesh beats IP allow-lists — a NetworkPolicy knows spoofable IPs, mTLS knows cryptographic identity. Where people go wrong: reading a matching subject as proof of identity, or treating the cron VM's failure as a network/firewall bug. **Cleanup:** `kill $(cat /opt/lab-bishkek/pids) 2>/dev/null; rm -rf /opt/lab-bishkek`.


### Climb 6 — Routing, Gateways & NAT: How Private Things Reach the World

#### Scenario 6.1 — "Seoul: an IP is not a way out"
**Solution:**
```bash
sudo ip netns exec labns-seoul ip route add default via 10.99.11.1
sudo ip netns exec labns-seoul ip route get 8.8.8.8    # now: via 10.99.11.1 dev labveth-seoulb
```
**Why this works & what it teaches:** An interface + address only gives you the on-link `/24`; anything off-subnet needs a `0.0.0.0/0` next hop. Adding the default route is the local twin of the S06 private-subnet line `0.0.0.0/0 → NAT GW` — the single line that turns "isolated" into "private-but-reachable-outward." Where people go wrong: they see a UP interface and assume connectivity; routing, not addressing, decides the exit.
**Cleanup:**
```bash
sudo ip netns del labns-seoul
sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 6.2 — "Busan: longest prefix always wins"
**Solution:**
```bash
sudo ip netns exec labns-busan ip route get 10.99.12.9   # matched by 10.99.0.0/16 (link route, no gateway)
sudo ip netns exec labns-busan ip route get 1.1.1.1      # matched by default → via 10.99.11.1
```
**Why this works & what it teaches:** The kernel evaluates every candidate route and picks the most specific prefix: a `/16` beats `/0` for any VPC-internal address, so east-west traffic never hits the "NAT" gateway — exactly why `10.0.0.0/16 local` beats `0.0.0.0/0` in the S06 tables and east-west never touches the NAT GW (latency + cost win). Nothing to fix; the routing table already encodes the policy.
**Cleanup:**
```bash
sudo ip netns del labns-busan
```

#### Scenario 6.3 — "Incheon: the router that refuses to route"
**Solution:**
```bash
sudo ip netns exec labns-incheon-rtr sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec labns-incheon-node ping -c1 -W2 192.0.2.1   # now: 1 received
```
**Why this works & what it teaches:** A Linux box drops transit packets unless `net.ipv4.ip_forward=1` — it is a host, not a router, until you say so. This is the same switch a NAT instance / CNI-forwarding node depends on (S07): correct routes on both sides are useless if the middle box won't forward. AWS's *managed* NAT GW has this baked in; a self-managed forwarder does not. Maps to AWS: the NAT Gateway / NAT instance is a forwarding node — `ip_forward` is its always-on premise.
**Cleanup:**
```bash
sudo ip netns exec labns-incheon-rtr sysctl -w net.ipv4.ip_forward=0
sudo ip netns del labns-incheon-node
sudo ip netns del labns-incheon-rtr
```

#### Scenario 6.4 — "Jeju: replies that can't find their way home"
**Solution:**
```bash
sudo iptables -t nat -N LAB-JEJU 2>/dev/null || true
sudo iptables -t nat -C POSTROUTING -s 10.99.11.0/24 -j LAB-JEJU 2>/dev/null || \
  sudo iptables -t nat -A POSTROUTING -s 10.99.11.0/24 -j LAB-JEJU
sudo iptables -t nat -A LAB-JEJU -s 10.99.11.0/24 ! -d 10.99.11.0/24 -j MASQUERADE
sudo iptables -t nat -S LAB-JEJU    # shows the MASQUERADE rule
```
**Why this works & what it teaches:** MASQUERADE rewrites the private source to the host's outbound address and records the flow in conntrack, so the far side replies to a routable address and the kernel un-rewrites it back — this IS the NAT Gateway's SNAT (S06 Rung 3), and byte-for-byte Docker's own POSTROUTING rule. Where people go wrong: they enable `ip_forward` and stop, forgetting that unmasqueraded RFC1918 sources are undeliverable on the far side. Maps to AWS: the NAT Gateway = this MASQUERADE at managed scale with an Elastic IP.
**Cleanup:**
```bash
sudo iptables -t nat -D POSTROUTING -s 10.99.11.0/24 -j LAB-JEJU 2>/dev/null || true
sudo iptables -t nat -F LAB-JEJU 2>/dev/null || true
sudo iptables -t nat -X LAB-JEJU 2>/dev/null || true
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null
sudo ip netns del labns-jeju
sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 6.5 — "Daegu: the front door nobody rewrote (DNAT)"
**Solution:**
```bash
sudo iptables -t nat -N LAB-DAEGU 2>/dev/null || true
sudo iptables -t nat -C PREROUTING -p tcp --dport 8888 -j LAB-DAEGU 2>/dev/null || \
  sudo iptables -t nat -A PREROUTING -p tcp --dport 8888 -j LAB-DAEGU
# locally-generated traffic (curl on the host) hits OUTPUT, not PREROUTING — cover both:
sudo iptables -t nat -C OUTPUT -p tcp --dport 8888 -d 10.99.11.1 -j LAB-DAEGU 2>/dev/null || \
  sudo iptables -t nat -A OUTPUT -p tcp --dport 8888 -d 10.99.11.1 -j LAB-DAEGU
sudo iptables -t nat -A LAB-DAEGU -p tcp --dport 8888 -j DNAT --to-destination 10.99.11.213:8080
# ensure replies return via SNAT so the pod answers the host correctly:
sudo iptables -t nat -A POSTROUTING -s 10.99.11.0/24 -d 10.99.11.213 -p tcp --dport 8080 -j MASQUERADE
curl -s --max-time 3 http://10.99.11.1:8888/ | head -1
```
**Why this works & what it teaches:** DNAT swaps the *destination* on the way in: front `:8888` → real `10.99.11.213:8080`, precisely what a published port, NodePort, and ClusterIP→pod rewrite do (S06 Rung 3). `-p 8888:8080` is DNAT, not SNAT — destination in, source out. Where people go wrong: forgetting locally-generated packets traverse OUTPUT (not PREROUTING), so a host-side `curl` needs the OUTPUT rule too. Maps to AWS: kube-proxy's ClusterIP iptables rewrite = this DNAT chain.
**Cleanup:**
```bash
sudo iptables -t nat -D PREROUTING -p tcp --dport 8888 -j LAB-DAEGU 2>/dev/null || true
sudo iptables -t nat -D OUTPUT -p tcp --dport 8888 -d 10.99.11.1 -j LAB-DAEGU 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 10.99.11.0/24 -d 10.99.11.213 -p tcp --dport 8080 -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -F LAB-DAEGU 2>/dev/null || true
sudo iptables -t nat -X LAB-DAEGU 2>/dev/null || true
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null
sudo ip netns del labns-daegu
sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 6.6 — "Taipei: the whole VPC, and it's all broken"
**Solution:**
```bash
# 1) the NAT ns must forward
sudo ip netns exec labns-taipei-nat sysctl -w net.ipv4.ip_forward=1
# 2) SNAT the private source to the public leg (the NAT Gateway move)
sudo ip netns exec labns-taipei-nat iptables -t nat -N LAB-TAIPEI 2>/dev/null || true
sudo ip netns exec labns-taipei-nat iptables -t nat -A POSTROUTING -o labveth-tpc -j LAB-TAIPEI
sudo ip netns exec labns-taipei-nat iptables -t nat -A LAB-TAIPEI -s 10.99.11.0/24 -j MASQUERADE
# 3) the "internet" ns needs a route back only to the NAT's public leg (never to 10.99/16 — that's the point)
sudo ip netns exec labns-taipei-net ip route add default via 203.0.113.1 2>/dev/null || true
# ride it:
sudo ip netns exec labns-taipei-priv curl -s --max-time 4 http://203.0.113.9:8443/ | head -1
sudo ip netns exec labns-taipei-nat conntrack -L 2>/dev/null | grep 8443 | head -1
```
**Why this works & what it teaches:** The private node's egress needs three things that a managed NAT GW bundles: a forwarding middle box (`ip_forward`), a source rewrite (`MASQUERADE` → `203.0.113.1`), and the middle box's own path onward. Conntrack records the SNAT mapping so replies un-rewrite back to `10.99.11.57` — and because no inbound mapping ever exists, the "internet" ns cannot initiate a connection back to the private node: outbound-only, exactly the S07/S21 ECR-pull trace. Where people go wrong: adding a route from the internet side back to RFC1918 "to make it work" — that destroys the very isolation NAT provides. Maps to AWS: NAT GW in a public subnet SNATing private nodes to its Elastic IP; the IGW is the public leg's onward path.
**Cleanup:**
```bash
sudo ip netns exec labns-taipei-nat iptables -t nat -D POSTROUTING -o labveth-tpc -j LAB-TAIPEI 2>/dev/null || true
sudo ip netns exec labns-taipei-nat iptables -t nat -F LAB-TAIPEI 2>/dev/null || true
sudo ip netns exec labns-taipei-nat iptables -t nat -X LAB-TAIPEI 2>/dev/null || true
sudo ip netns del labns-taipei-priv
sudo ip netns del labns-taipei-nat
sudo ip netns del labns-taipei-net
```

---

### Climb 7 — Firewalls: Security Groups & NACLs

#### Scenario 7.1 — "Kaohsiung: the two failures that mean opposite things"
**Solution:**
```bash
nc -zv -w3 127.0.0.1 8099 2>&1 | tail -1        # "Connection refused" — instant RST, a listener/port problem
time nc -zv -w3 127.0.0.1 8080 2>&1 | tail -1   # ~3s silence then timeout — the DROP = a filter/route problem
```
**Why this works & what it teaches:** A closed port answers immediately with an RST ("refused") because the kernel actively rejects; a DROP rule stays silent, so the client waits out its timeout — the entire S14/S19 triage in one word. From here, `i/o timeout` in a pod log reads as "SG/NACL/route," never "the app." Where people go wrong: treating a timeout as an app bug and restarting pods, when the SYN never survived the firewall.
**Cleanup:**
```bash
sudo iptables -D INPUT -p tcp -j LAB-KAOHSIUNG 2>/dev/null || true
sudo iptables -F LAB-KAOHSIUNG 2>/dev/null || true
sudo iptables -X LAB-KAOHSIUNG 2>/dev/null || true
```

#### Scenario 7.2 — "Tainan: default-deny, then allow the one thing"
**Solution:**
```bash
# insert the ACCEPT ABOVE the DROP in the chain (order matters, first match wins):
sudo iptables -I LAB-TAINAN 1 -p tcp --dport 8081 -j ACCEPT
nc -zv -w3 127.0.0.1 8081 2>&1 | tail -1    # now "succeeded"
```
**Why this works & what it teaches:** A security group's posture is deny-until-allowed; the app on `8081` was healthy all along (`ss` proved it), the missing piece was the single ingress allow — "the security group IS the auth boundary" (S14). Where people go wrong: appending the ACCEPT *after* the DROP — iptables is first-match, so the DROP would still win; it must go above.
**Cleanup:**
```bash
sudo iptables -D INPUT -p tcp --dport 8081 -j LAB-TAINAN 2>/dev/null || true
sudo iptables -F LAB-TAINAN 2>/dev/null || true
sudo iptables -X LAB-TAINAN 2>/dev/null || true
sudo pkill -f 'http.server 8081' 2>/dev/null || true
sudo userdel labuser-tainan 2>/dev/null || true
```

#### Scenario 7.3 — "Shenzhen: stateful means replies ride free"
**Solution:**
```bash
# add the ONE rule a security group applies for free — admit replies of allowed flows:
sudo iptables -I LAB-SHENZHEN 1 -p tcp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
curl -s --max-time 3 http://127.0.0.1:9000/ | head -1   # now the reply is admitted
```
**Why this works & what it teaches:** Conntrack remembers each flow the firewall allowed, so `ESTABLISHED,RELATED` auto-admits the return packets without a per-ephemeral-port rule — this is *statefulness*, why no "egress 51844" rule exists anywhere in the project (S14). A stateless NACL has no such memory and must spell out the return range. Where people go wrong: writing an allow for the destination port only and forgetting that replies arrive on a different (ephemeral) port.
**Cleanup:**
```bash
sudo iptables -D OUTPUT -p tcp -j LAB-SHENZHEN 2>/dev/null || true
sudo iptables -F LAB-SHENZHEN 2>/dev/null || true
sudo iptables -X LAB-SHENZHEN 2>/dev/null || true
sudo pkill -f 'http.server 9000' 2>/dev/null || true
```

#### Scenario 7.4 — "Chengdu: the source is a group, not a CIDR"
**Solution:**
```bash
# swap the wrong laptop CIDR for the "cluster" side (the gateway/host source 10.99.14.0/24):
sudo ip netns exec labns-chengdu-db iptables -I LAB-CHENGDU 1 -s 10.99.14.0/24 -j ACCEPT
# (optional) drop the stale laptop rule:
sudo ip netns exec labns-chengdu-db iptables -D LAB-CHENGDU -s 192.168.7.0/24 -j ACCEPT 2>/dev/null || true
nc -zv -w3 10.99.14.50 3306 2>&1 | tail -1   # now "succeeded" from the host side
```
**Why this works & what it teaches:** This is S14 Lab C: the RDS SG was admitting the wrong source (a laptop CIDR) and silently dropped everything else → `i/o timeout`. Fixing the source to the "cluster" side opens the path. In real AWS the source is a *group reference* (`security_groups = [eks_cluster_sg_id]`), not a CIDR — because pods/nodes churn IPs but always carry the cluster SG (S14 §6.2). Here a stable subnet stands in for that membership. Where people go wrong: widening to `0.0.0.0/0` to "just make it work," discarding the whole identity-scoping point.
**Cleanup:**
```bash
sudo ip netns del labns-chengdu-db
sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 7.5 — "Xian: the stateless firewall forgets the way back"
**Solution:**
```bash
# keep it STATELESS (like a real NACL): explicitly allow the outbound reply leg.
sudo ip netns exec labns-xian iptables -I LAB-XIAN-OUT 1 -p tcp --sport 6379 --dport 1024:65535 -j ACCEPT
nc -zv -w3 10.99.14.60 6379 2>&1 | tail -1   # now "succeeded"
```
**Why this works & what it teaches:** A NACL evaluates every packet with no flow memory, so admitting inbound `6379` is only half the job — the replies leave *from* source-port `6379` *to* the client's ephemeral port and need their own explicit allow. This is the S14 line "outbound 6379 AND inbound 1024–65535 — forget the second, mystery hangs," here mirrored as the missing outbound reply. Where people go wrong: reaching for `--ctstate ESTABLISHED` — that would work, but it makes the firewall stateful (an SG), defeating the point of *demonstrating* what a NACL must do by hand.
**Cleanup:**
```bash
sudo ip netns del labns-xian
sudo ip link del lab0 2>/dev/null || true
```

#### Scenario 7.6 — "Harbin: two firewalls, one silent drop"
**Solution:**
```bash
# Diagnose: the SG (db ns) already allows 3306 + ESTABLISHED — it is correct.
sudo ip netns exec labns-harbin-db iptables -S LAB-HARBIN-SG      # 3306 ACCEPT + conntrack ESTABLISHED — fine
# The NACL (router ns) allows inbound 3306 but DROPs the return (--sport 3306): that is the culprit.
sudo ip netns exec labns-harbin-rtr iptables -S LAB-HARBIN-NACL
# Fix ONLY the NACL layer: permit the return traffic to the ephemeral range, above the DROP.
sudo ip netns exec labns-harbin-rtr iptables -D LAB-HARBIN-NACL -p tcp --sport 3306 -j DROP 2>/dev/null || true
sudo ip netns exec labns-harbin-rtr iptables -I LAB-HARBIN-NACL 1 -p tcp --sport 3306 --dport 1024:65535 -j ACCEPT
nc -zv -w3 10.99.20.50 3306 2>&1 | tail -1   # now "succeeded" end to end
```
**Why this works & what it teaches:** With SG + NACL stacked, a timeout means *some* layer drops silently; you isolate it by reasoning about state. The stateful SG admits replies for free, so it can't be the return-path culprit; the stateless NACL DROPs `--sport 3306`, killing the reply at the subnet boundary — classic NACL ephemeral-return bug. Fix only the layer that's wrong, leaving the correct SG untouched (defense in depth, S14/S22). Where people go wrong: "fixing" the SG (which was fine) and never inspecting the second, stateless layer.
**Cleanup:**
```bash
sudo ip netns del labns-harbin-rtr
sudo ip netns del labns-harbin-db
sudo ip route del 10.99.20.0/24 via 10.99.14.2 dev lab0 2>/dev/null || true
sudo ip link del lab0 2>/dev/null || true
```

---

### Climb 8 — Load Balancing: L4 vs L7, Health Checks & the Front Door

#### Scenario 8.1 — "Suzhou: two backends, one front door"
**Solution:**
```bash
sudo nginx -c /opt/lab-suzhou/nginx.conf
for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/; done   # alternates catalog-v1 / catalog-v2
```
**Why this works & what it teaches:** An `upstream` block with two servers is a target group; nginx spreads requests round-robin so no client has to pick a backend — the S11 ALB Ingress role in miniature. The app pods never coordinate; the front door does. Maps to AWS: nginx `upstream pool` = the ALB's target group.
**Cleanup:**
```bash
sudo nginx -c /opt/lab-suzhou/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'http.server 8001' 2>/dev/null || true
sudo pkill -f 'http.server 8002' 2>/dev/null || true
sudo rm -rf /opt/lab-suzhou /opt/lab-suzhou-v1 /opt/lab-suzhou-v2
```

#### Scenario 8.2 — "Guilin: the pool is half empty"
**Solution:**
```bash
ss -ltnp 2>/dev/null | grep -E '801[12]'    # only 8011 listens — the empty target-group slot
python3 -m http.server 8012 --directory /opt/lab-guilin-v2 >/dev/null 2>&1 &
sleep 1
for i in 1 2 3 4; do curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/; done   # all 200 now
```
**Why this works & what it teaches:** A pool member with nothing listening is a `502`/`503` source for its share of requests; `ss -ltnp` is the fastest way to see which "pods" are actually serving. Starting the missing backend fills the target group — the S11 lesson that a target is only healthy once its process is up and Ready. Where people go wrong: blaming the LB for intermittent 502s when one backend simply never bound its port.
**Cleanup:**
```bash
sudo nginx -c /opt/lab-guilin/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'http.server 8011' 2>/dev/null || true
sudo pkill -f 'http.server 8012' 2>/dev/null || true
sudo rm -rf /opt/lab-guilin /opt/lab-guilin-v1 /opt/lab-guilin-v2
```

#### Scenario 8.3 — "Macau: eject the dead, converge on the living"
**Solution:**
```bash
sudo tee /opt/lab-macau/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool {
    server 127.0.0.1:8021 max_fails=1 fail_timeout=10s;
    server 127.0.0.1:8022 max_fails=1 fail_timeout=10s;
  }
  server { listen 8080; location / { proxy_pass http://pool; proxy_connect_timeout 1s; } }
}
EOF
sudo nginx -c /opt/lab-macau/nginx.conf -s reload
pkill -f 'http.server 8022'
for i in 1 2 3 4 5 6; do curl -s --max-time 2 http://127.0.0.1:8080/; done   # <=1 hiccup, then all carts-v1
```
**Why this works & what it teaches:** `max_fails`/`fail_timeout` is passive health checking: after a failed request nginx marks the target down and stops sending to it, so traffic converges on the survivor — the same interlock as an ALB target-group health check and Envoy outlier detection ("eject after N consecutive 5xx," S22). One concept, three uniforms. Where people go wrong: no health config, so the LB keeps routing to a dead pod indefinitely.
**Cleanup:**
```bash
sudo nginx -c /opt/lab-macau/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'http.server 8021' 2>/dev/null || true
sudo pkill -f 'http.server 8022' 2>/dev/null || true
sudo rm -rf /opt/lab-macau /opt/lab-macau-v1 /opt/lab-macau-v2
```

#### Scenario 8.4 — "Hangzhou: only L7 can read the path"
**Solution:**
```bash
sudo tee /opt/lab-hangzhou/nginx.conf >/dev/null <<'EOF'
events {}
http {
  server { listen 8080;
    location /catalog { proxy_pass http://127.0.0.1:8031/; }
    location /orders  { proxy_pass http://127.0.0.1:8032/; }
    location /health  { return 200 "lb ok\n"; }
  }
}
EOF
sudo nginx -c /opt/lab-hangzhou/nginx.conf -s reload
curl -s http://127.0.0.1:8080/catalog   # CATALOG
curl -s http://127.0.0.1:8080/orders    # ORDERS
curl -s http://127.0.0.1:8080/health    # lb ok
```
**Why this works & what it teaches:** Only an HTTP-terminating (L7) proxy can see the request path, so `location` blocks route `/catalog` and `/orders` to different backends — this proxy config IS an Ingress `rules:` block IS an ALB listener rule (S11). An L4 balancer forwards bytes and literally cannot make this decision. Maps to AWS: ALB path-based listener rules / the Ingress `rules:` you write in S11.
**Cleanup:**
```bash
sudo nginx -c /opt/lab-hangzhou/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'http.server 8031' 2>/dev/null || true
sudo pkill -f 'http.server 8032' 2>/dev/null || true
sudo rm -rf /opt/lab-hangzhou /opt/lab-hangzhou-cat /opt/lab-hangzhou-ord
```

#### Scenario 8.5 — "Qingdao: 502 says broke, 504 says slow"
**Solution:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/broke               # 502
curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://127.0.0.1:8080/slow   # 504
```
**Why this works & what it teaches:** The LB opens a *second* connection to the backend, so its 5xx describes that second hop: `502` = the backend refused/garbled the connection (nothing listened on `8041`); `504` = the backend accepted but blew the LB's `proxy_read_timeout` (the sleepy `8042`). That's the entire S11 5xx decoder — "two connections, not one." Where people go wrong: reading a 504 as "the LB is down" when it means "your backend is too slow," and a 502 as a network blip when it means "your backend refused/crashed."
**Cleanup:**
```bash
sudo nginx -c /opt/lab-qingdao/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'lab-qingdao/slow.py' 2>/dev/null || true
sudo rm -rf /opt/lab-qingdao
```

#### Scenario 8.6 — "Ulaanbaatar: Running is not Ready"
**Solution:**
```bash
# Reproduce: the pool has no health gate, so the 503-on-/health pod gets half the traffic.
for i in $(seq 1 6); do curl -s http://127.0.0.1:8080/; done          # mix of ui-good / ui-bad
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8052/health # 503 — Running but NOT Ready
# Fix: health-gate the L7 pool so the lying pod is ejected (active check on /health).
sudo tee /opt/lab-ub/nginx.conf >/dev/null <<'EOF'
events {}
http {
  upstream pool {
    server 127.0.0.1:8051 max_fails=1 fail_timeout=10s;
    server 127.0.0.1:8052 max_fails=1 fail_timeout=10s;
  }
  server {
    listen 8080;
    # gate: probe /health; a non-2xx on a target takes it out of rotation for real traffic
    location / {
      proxy_next_upstream error timeout http_503 http_502;
      proxy_pass http://pool;
    }
    location = /_probe { proxy_pass http://pool/health; }
  }
}
EOF
sudo nginx -c /opt/lab-ub/nginx.conf -s reload
for i in $(seq 1 6); do curl -s http://127.0.0.1:8080/; done          # only ui-good now
# L4 contrast: a blind TCP forwarder cannot health-check on /health content.
socat -T2 TCP-LISTEN:8060,reuseaddr,fork TCP:127.0.0.1:8052 &
curl -s http://127.0.0.1:8060/         # forwards bytes to the "bad" pod regardless — L4 sees no /health
kill %1 2>/dev/null || true
```
**Why this works & what it teaches:** "Running" only means the process started; Ready (passing the health probe) and "passing the LB's own check" are two more, independent gates — a pod can be Running with its port open yet return `503` on `/health`, and an ungated pool forwards to it half the time (the S11/S21 intermittent-502-after-deploy signature). Adding `proxy_next_upstream` + `max_fails` makes nginx retry off a failing target and eject it — content-aware ejection an L4 balancer cannot do, which is exactly why readiness lives at L7 (ALB/Envoy) and the NLB/Istio-gateway just passes bytes (S22). Where people go wrong: trusting `kubectl get pods` "Running" and never aligning the readiness probe with the LB's health-check path.
**Cleanup:**
```bash
sudo nginx -c /opt/lab-ub/nginx.conf -s stop 2>/dev/null || true
sudo pkill -f 'lab-ub/good.py' 2>/dev/null || true
sudo pkill -f 'lab-ub/bad.py' 2>/dev/null || true
sudo pkill -x socat 2>/dev/null || true
sudo rm -rf /opt/lab-ub /opt/lab-ub-good /opt/lab-ub-bad
```


### Climb 9 — Container & Pod Networking: bridge, veth, CNI

#### Scenario 9.1 — "Havana: the cable plugged in but never switched on"
**Solution:**
```bash
# Host-side read: the state word tells you about the END YOU CAN'T SEE
ip -br link show labveth-hav
# state LOWERLAYERDOWN  -> the host end is up, but the PEER (pod eth0) is DOWN:
# a veth needs BOTH ends up to carry the carrier.
# Bring up the pod-side end — the one command the crashed "CNI plugin" never ran
sudo ip netns exec labns-hav ip link set eth0 up
# Now both ends are up; connectivity returns
ip -br link show labveth-hav       # state UP
ping -c2 -W1 10.90.1.2             # 0% loss
```
**Why this works & what it teaches:** A veth is one cable with two ends; `LOWERLAYERDOWN` on the host side means the host end is up but its peer has no carrier because the pod-side `eth0` was never set `up`. IP config is irrelevant until L2 carrier exists, which is why "it's an IP problem" is wrong. Local analogue: this is a CNI `ADD` that died mid-sequence — on EKS kubelet asks the VPC CNI to make the veth, move one end into the pod, assign the IP, and bring both links up; a pod can read `Running` while its cable was never switched on, and `LOWERLAYERDOWN` on a node `veth*` is how you spot it. Where people go wrong: reading `ip link` on the host, seeing the interface exists and is UP, and never checking the peer's state. **Cleanup:** `sudo ip netns del labns-hav`.

#### Scenario 9.2 — "San Juan: three cables, one guilty pod"
**Solution:**
```bash
# Sample the counters twice to find the hot HOST veth
ip -s -br link | grep labveth-p; sleep 2; echo ---; ip -s -br link | grep labveth-p
# Say the hot one, e.g. labveth-p2. Map host veth -> owning namespace by ifindex/iflink:
# the host veth's iflink == the pod-side eth0's ifindex.
HOT=labveth-p2                                        # substitute whichever is racing for you
PEER_IDX=$(cat /sys/class/net/$HOT/iflink)
for NS in labns-sj-ui labns-sj-cart labns-sj-catalogue; do
  IDX=$(sudo ip netns exec "$NS" cat /sys/class/net/eth0/ifindex)
  [ "$IDX" = "$PEER_IDX" ] && echo "GUILTY POD: $NS"
done
# Kill the flooding process INSIDE that namespace only (leave the other two untouched)
sudo ip netns pids "$(  for NS in labns-sj-ui labns-sj-cart labns-sj-catalogue; do
    IDX=$(sudo ip netns exec "$NS" cat /sys/class/net/eth0/ifindex)
    [ "$IDX" = "$PEER_IDX" ] && echo "$NS"; done )" | xargs -r sudo kill
# Verify the flood stopped
A=$(cat /sys/class/net/lab0/statistics/rx_packets); sleep 2; \
B=$(cat /sys/class/net/lab0/statistics/rx_packets); echo $((B - A))   # < 10
```
**Why this works & what it teaches:** `kubectl` never shows the pod↔veth mapping, but the kernel does: every host veth's `iflink` equals the pod-side `eth0`'s `ifindex`, so you match the hot host interface to exactly one namespace instead of guessing (the `shuf` in setup randomized the names on purpose). Then `ip netns pids` scopes the kill to that pod alone. Local analogue: "which pod is flooding my EKS node's NIC?" — the same `iflink`/`ifindex` pairing identifies the pod behind any `veth*` in `tcpdump` on a node. Where people go wrong: assuming `labveth-p2` belongs to the second pod created, when the scheduler assigned names randomly. **Cleanup:** `for p in ui cart catalogue; do sudo ip netns del labns-sj-$p; done; sudo ip link del lab0`.

#### Scenario 9.3 — "Nassau: the switch with an unplugged port"
**Solution:**
```bash
# Every link reports UP, yet ui can't reach catalogue. Find where L2 breaks:
bridge link show | grep labveth-na          # only labveth-na1 is enslaved to lab0
ip -d link show labveth-na2 | grep -i master # no 'master lab0' -> not on the switch
# na2 is UP but enslaved to NO bridge: its cable dangles in the air, connected to nothing.
# Plug the port in — one command:
sudo ip link set labveth-na2 master lab0
# Verify both ports on the switch and end-to-end reachability
bridge link show | grep -c labveth-na       # 2
sudo ip netns exec labns-na-ui ping -c2 -W1 10.90.3.3   # 0% loss
```
**Why this works & what it teaches:** Setup brought `labveth-na2` up but never ran `master lab0`, so catalogue's cable is live but connected to no switch — L2 frames have nowhere to go even though every link is UP and IPs are correct. `bridge link show` lists only enslaved ports; `ip -d link` confirms the missing master. Local analogue: a bridge port never enslaved is Docker's `docker0` (or a CNI bridge plugin) failing the "attach" half of its job — `docker network connect` and the CNI's `master` assignment are exactly this one command; the bridge is "a virtual switch" with a port physically unplugged. Where people go wrong: trusting that "all links UP" means connected, when membership in the bridge is a separate fact. **Cleanup:** `sudo ip netns del labns-na-ui; sudo ip netns del labns-na-cat; sudo ip link del lab0`.

#### Scenario 9.4 — "Bridgetown: the pod that couldn't phone ECR"
**Solution:**
```bash
# Reproduce: pull times out (exit 28), not refused -> packets leave but nothing returns
sudo ip netns exec labns-bt-pod curl -s --max-time 3 http://10.90.44.2:8443/manifest.txt; echo $?
# FAULT #1 — the host isn't a router. Turn on forwarding:
sudo sysctl -qw net.ipv4.ip_forward=1
# FAULT #2 — SYNs arrive at ECR but SYN-ACKs die on a routerless return path (private src
# IP unrouteable). Watch it, then SNAT the pod's source with MASQUERADE:
#   sudo tcpdump -ni labveth-bt2   # shows SYNs in, no SYN-ACK back
sudo iptables -t nat -A LAB-NAT-BT -j MASQUERADE
# Verify the pull succeeds and the MASQUERADE rule shows traffic
sudo ip netns exec labns-bt-pod curl -s --max-time 3 http://10.90.44.2:8443/manifest.txt
sudo iptables -t nat -L LAB-NAT-BT -nv | tail -1     # MASQUERADE with non-zero pkts
# /opt/lab-bt/ip_forward.orig records the box's original ip_forward so cleanup can restore it.
```
**Why this works & what it teaches:** Timeout (not refused) means the SYN arrives but the reply never comes back. Two independent host-side faults: `ip_forward=0` means the host drops transit packets instead of routing them; and even once forwarding is on, the pod's private source `10.90.4.2` has no return route from ECR (the internet can't route your private IPs — a feature, not a bug), so SYN-ACKs die until MASQUERADE rewrites the source to the host's routable address. Local analogue: a private EKS node pulling from ECR through a NAT gateway (S06/S07/S21) — `ip_forward=1` is the "be a router" switch, MASQUERADE is the SNAT; without it you get the classic asymmetric-route timeout. Where people go wrong: fixing only forwarding and stopping, or trying to add a return route on the ECR side (which you don't own). **Cleanup:** `sudo sysctl -qw net.ipv4.ip_forward=$(cat /opt/lab-bt/ip_forward.orig); sudo iptables -t nat -D POSTROUTING -s 10.90.4.0/24 -j LAB-NAT-BT; sudo iptables -t nat -F LAB-NAT-BT; sudo iptables -t nat -X LAB-NAT-BT; sudo ip netns del labns-bt-pod; sudo ip netns del labns-bt-ecr; sudo rm -rf /opt/lab-bt`.

#### Scenario 9.5 — "Panama City: two pods, one IP"
**Solution:**
```bash
# Refused means something ANSWERED (a live host rejected it) — not a dead pod (which times out).
# Read the client's ARP entry for the VIP-in-question: it's PERMANENT (poisoned), and its MAC
# belongs to the ghost, not cart.
sudo ip netns exec labns-pc-client ip neigh show 10.90.5.3     # note lladdr + PERMANENT
GHOST_MAC=$(sudo ip netns exec labns-pc-ghost cat /sys/class/net/eth0/address)
CART_MAC=$(sudo ip netns exec labns-pc-cart  cat /sys/class/net/eth0/address)
echo "client points at: $(sudo ip netns exec labns-pc-client ip neigh show 10.90.5.3 | awk '{print $5}')"
echo "ghost=$GHOST_MAC  cart=$CART_MAC"     # confirms client -> ghost (the impostor)
# Fix under the constraint that CART keeps 10.90.5.3: remove the impostor and the poisoned entry.
# Delete the ghost's duplicate address (and shut it down) so it stops answering:
sudo ip netns exec labns-pc-ghost ip addr del 10.90.5.3/24 dev eth0
# Repoint the client's neighbor entry at the real cart MAC (dynamic, not permanent)
sudo ip netns exec labns-pc-client ip neigh replace 10.90.5.3 lladdr "$CART_MAC" dev eth0 nud reachable
# Verify
sudo ip netns exec labns-pc-client curl -s --max-time 3 http://10.90.5.3:8080/     # cart OK: 3 items
```
**Why this works & what it teaches:** Climb 7's iron rule — refused means a live host rejected you — sends you to the neighbor table, not to the cart pod. Two pods share `10.90.5.3`; setup froze the ARP race by poisoning the client's cache with a PERMANENT entry pointing at the ghost (which has no listener → connection refused). Matching the cached MAC against each namespace's `eth0` names the impostor. The fix keeps cart's IP (its EndpointSlice already points there): strip the duplicate off the ghost and repoint the client's neighbor entry at cart's real MAC as a dynamic (non-permanent) entry. Local analogue: duplicate pod IPs from corrupted CNI IPAM or a stale ARP entry surviving a pod recreation — the VPC CNI's job is exclusive IP leases. Where people go wrong: debugging cart (which is healthy) instead of asking who actually answers for the IP. **Cleanup:** `for n in client cart ghost; do sudo ip netns del labns-pc-$n; done; sudo ip link del lab0; sudo rm -rf /opt/lab-pc`.

#### Scenario 9.6 — "San José: the sidecar died and kept the traffic"
**Solution:**
```bash
# Diagnose from INSIDE the namespace: the nat table redirects inbound tcp/8080 -> :8150,
# and nothing listens on :8150 (the sidecar crashed).
sudo ip netns exec labns-sanjose iptables -t nat -L LAB-MESH-SJ -n     # REDIRECT --to-ports 8150
sudo ip netns exec labns-sanjose ss -tln                              # :8080 up, :8150 ABSENT
# Mechanism: PREROUTING REDIRECT rewrites external tcp/8080 to a dead :8150 -> refused;
# locally-generated traffic (localhost) skips PREROUTING -> app fine from inside;
# ICMP/ping matches no rule (rule is tcp/8080 only) -> ping works.
# Fix WITHOUT touching iptables — resurrect the sidecar in the RIGHT place (the pod's netns):
sudo ip netns exec labns-sanjose bash -c 'nohup python3 /opt/lab-sj/envoy.py >/dev/null 2>&1 &'
sleep 1
# Verify from outside + the sidecar is listening on :8150 inside the namespace
curl -s --max-time 3 http://10.90.6.2:8080/                          # checkout app: order placed
sudo ip netns exec labns-sanjose ss -tln | grep -c ':8150 '          # 1
```
**Why this works & what it teaches:** `istio-init`'s REDIRECT rules live in the pod's network namespace and are held open by the pause container, so they outlive the sidecar that consumed them. With Envoy dead, inbound tcp/8080 is redirected to an unlistened :8150 → refused from outside; the app's own `localhost` view bypasses PREROUTING so it works from inside; ICMP matches no rule so ping succeeds — that triad is the fingerprint. You must not unwrite the rules (you don't own them in a real pod); the correct fix is to restart the sidecar inside the namespace so :8150 has a listener again. Local analogue: a crashed Envoy sidecar (S22) with `istio-init`'s rules still armed. Where people go wrong: blaming the network (ping works!) or the app (fine from inside), and trying to delete the "broken" iptables rules instead of restoring the process they point at. **Cleanup:** `sudo ip netns del labns-sanjose; sudo ip link del labveth-sj6 2>/dev/null; sudo rm -rf /opt/lab-sj`.

### Climb 10 — Kubernetes Services → Ingress → Mesh: the Delivery Chain

#### Scenario 10.1 — "Belize City: the VIP nobody listens on"
**Solution:**
```bash
# Be kube-proxy: one DNAT rule in LAB-SVC-BZ maps VIP 10.96.10.1:8080 -> pod 10.90.7.2:8080
sudo iptables -t nat -A LAB-SVC-BZ -d 10.96.10.1/32 -p tcp --dport 8080 \
  -j DNAT --to-destination 10.90.7.2:8080
# The VIP now works — AND nothing listens on 8080: it's NAT, not a socket
curl -s --max-time 3 http://10.96.10.1:8080/       # catalogue pod answers
sudo ss -ltn | grep -c ':8080 '                    # 0
```
**Why this works & what it teaches:** A ClusterIP is not a socket anywhere — it's a DNAT rule in the kernel's nat table on the client's own node. The teammate's `ss` check finds nothing because there is nothing to find; the missing "machine part" is the rule, not a listener. Adding one DNAT into `LAB-SVC-BZ` (already hooked into OUTPUT and PREROUTING exactly where kube-proxy hooks `KUBE-SERVICES`) makes the VIP deliver, while `ss` still shows nothing on 8080. Local analogue: exactly the rule kube-proxy writes for the catalog ClusterIP (S08) — which is why you can't ping-debug a Service into existence and `ss` never shows it. Where people go wrong: trying to "start a process on the VIP," misreading a ClusterIP as an address something binds. **Cleanup:** `sudo iptables -t nat -D OUTPUT -d 10.96.0.0/16 -j LAB-SVC-BZ; sudo iptables -t nat -D PREROUTING -d 10.96.0.0/16 -j LAB-SVC-BZ; sudo iptables -t nat -F LAB-SVC-BZ; sudo iptables -t nat -X LAB-SVC-BZ; sudo ip route del 10.96.0.0/16 dev lab0; sudo ip netns del labns-bz; sudo ip link del lab0; sudo rm -rf /opt/lab-bz`.

#### Scenario 10.2 — "Roseau: the pod that forgot the phone book"
**Solution:**
```bash
# Give THIS pod its own name->IP map via /etc/netns/<ns>/hosts (ip netns bind-mounts it over /etc/hosts)
sudo mkdir -p /etc/netns/labns-ro
echo '10.90.8.3  catalogue.retail.svc.cluster.local catalogue' \
  | sudo tee /etc/netns/labns-ro/hosts >/dev/null
# The pod resolves the name; the host's own resolution is untouched
sudo ip netns exec labns-ro curl -s --max-time 3 http://catalogue.retail.svc.cluster.local:8080/
getent hosts catalogue.retail.svc.cluster.local; echo "host exit: $?"   # no address, exit 2
```
**Why this works & what it teaches:** `ip netns exec` bind-mounts `/etc/netns/<ns>/hosts` over `/etc/hosts` inside that namespace only, so the mapping is per-pod — no DNS server, no edit to the shared host `/etc/hosts`, and other teams' pods never see the name. Local analogue: per-pod phone books are Compose's embedded DNS (S04) and CoreDNS plus the `/etc/hosts`/`/etc/resolv.conf` kubelet writes into every pod (S08); resolution is namespace-scoped, so `catalogue` means one thing in a pod and nothing on the node. `/etc/netns/<name>/hosts` is the raw Linux primitive under that idea. Where people go wrong: editing the host's `/etc/hosts` (leaks the name to every namespace) or assuming DNS must exist to map a name. **Cleanup:** `sudo rm -rf /etc/netns/labns-ro; sudo ip netns del labns-ro; sudo ip netns del labns-ro-cat; sudo ip link del lab0; sudo rm -rf /opt/lab-ro`.

#### Scenario 10.3 — "Castries: the selector that matched nothing"
**Solution:**
```bash
# kube-proxy is innocent: it faithfully compiles whatever endpoints it's given; zero endpoints
# in -> zero DNAT rules out. The bug is upstream, in the selector<->labels join.
grep SELECTOR /opt/lab-cs/service.env                     # SELECTOR="app=catalouge"  (typo!)
grep LABELS   /opt/lab-cs/pods/catalogue-1.env            # LABELS="app=catalogue,version=v1"
# 'catalouge' != 'catalogue' — the selector matches no pod. Fix the typo:
sudo sed -i 's/app=catalouge/app=catalogue/' /opt/lab-cs/service.env
# Re-run the control plane; endpoints now populate and kube-proxy writes 2 DNAT rules
sudo /opt/lab-cs/controller.sh
# Prove round-robin across both pods
for i in 1 2 3 4; do curl -s --max-time 3 http://10.96.10.3:8080/; done
```
**Why this works & what it teaches:** The controller's own log confessed `matched 0 pod(s)`, so the iptables layer is faultless — kube-proxy only compiles the EndpointSlice it's handed, and an empty endpoint list correctly produces zero rules (a working VIP with nothing to route to = timeout). The real culprit is a one-character typo in `spec.selector` (`catalouge` vs pod label `catalogue`), which makes the selector↔labels join match nothing. Fix the selector, re-run, and the VIP alternates between both pods via statistic-mode nth. Local analogue: the classic S08 moment where `kubectl get endpoints` shows `<none>` — the broken join is Service `spec.selector` ↔ pod `metadata.labels`, and kube-proxy is not a suspect. Where people go wrong: "debug the iptables layer" when the endpoint list was empty by construction. **Cleanup:** `sudo iptables -t nat -D OUTPUT -d 10.96.10.3/32 -j LAB-SVC-CS; sudo iptables -t nat -F LAB-SVC-CS; sudo iptables -t nat -X LAB-SVC-CS; sudo ip route del 10.96.0.0/16 dev lab0; sudo ip netns del labns-cs-1; sudo ip netns del labns-cs-2; sudo ip link del lab0; sudo rm -rf /opt/lab-cs`.

#### Scenario 10.4 — "Willemstad: one front door, 502 on aisle /cart"
**Solution:**
```bash
# Triage from the PROXY's own evidence, not by guessing: read the error log
tail -3 /opt/lab-wl/error.log
# -> "connect() failed (111: Connection refused) ... upstream: http://10.90.10.3:8090/cart"
# Refused (not timeout) at :8090 = wrong port; the cart pod actually listens on :8080.
sudo ip netns exec labns-wl-cart ss -tln | grep ':8080'    # confirms 8080, not 8090
# Fix the compiled Ingress config: point /cart at the real targetPort
sudo sed -i 's#http://10.90.10.3:8090#http://10.90.10.3:8080#' /opt/lab-wl/nginx.conf
# Reload the running binary WITHOUT dropping connections
sudo nginx -c /opt/lab-wl/nginx.conf -s reload
# Verify: /cart heals, / still works
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8480/cart   # 200
curl -s http://localhost:8480/cart                                     # cart: 3 items, total 42
curl -s http://localhost:8480/                                         # ui: welcome...
```
**Why this works & what it teaches:** A 502 means the proxy itself is alive and answering — its upstream hop failed — and the proxy's error log names the exact `backend:port` it tried and what the kernel said. Here it's `connect() ... Connection refused` to `10.90.10.3:8090`; refused (vs timeout, Climb 7's rule) plus a healthy pod on 8080 = wrong `targetPort`, not a dead pod. Editing the compiled config to `:8080` and reloading (not restarting — front doors don't drop connections) heals `/cart` while `/` stays up. Local analogue: an ALB Ingress rule pointing at a `targetPort` no container opens (S11) — the #1 cause of ALB 502s; ALB access logs + target-group health reasons are the cloud version of this error log. Where people go wrong: "guessing" from the client side instead of reading the box that generated the 502. **Cleanup:** `sudo nginx -c /opt/lab-wl/nginx.conf -s stop; sudo ip netns del labns-wl-ui; sudo ip netns del labns-wl-cart; sudo ip link del lab0; sudo rm -rf /opt/lab-wl`.

#### Scenario 10.5 — "Montego Bay: half the checkouts are dying"
**Solution:**
```bash
# The buggy probe treats "an HTTP response arrived" as success. Find the line:
grep 'curl -s --max-time 2' /opt/lab-mb/readiness.sh
# Plain `curl -s .../healthz` exits 0 even on HTTP 500 — transport success, not HTTP success.
# Fix: add -f so curl exits non-zero on >=400 (the one-character-class difference).
sudo sed -i 's/curl -s --max-time 2/curl -sf --max-time 2/' /opt/lab-mb/readiness.sh
# Re-run: pod-2 (500 on /healthz) is now ejected; only the healthy pod stays in rotation
sudo /opt/lab-mb/readiness.sh                    # readiness: 1 of 2 pods ready: 10.90.11.2
# Prove all traffic now lands on the healthy pod
for i in $(seq 6); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://10.96.10.5:8080/; done
```
**Why this works & what it teaches:** The probe collapses two distinct notions: transport success (TCP connected, an HTTP response arrived) vs HTTP success (that response was 2xx). Plain `curl -s` exits 0 on a 500, so the sick pod is called "ready" and kept in rotation — kube-proxy then faithfully round-robins into it, giving the tidy 200/500/200/500. Adding `-f` makes curl exit 22 on `>=400`, so the readiness loop ejects pod-2 and rebuilds the rotation with only the healthy endpoint. Don't "fix" pod-2 — sick pods are a fact of life; a controller blind to sickness is the outage. Local analogue: a readinessProbe checking "port open" when it should check "HTTP 200" — the same distinction that keeps S21 rolling updates zero-downtime and that an ALB target-group health check (Climb 8) makes one layer up. Where people go wrong: blaming kube-proxy for "routing to a dead pod" when the pod is alive-and-failing and readiness fed it in. **Cleanup:** `sudo iptables -t nat -D OUTPUT -d 10.96.10.5/32 -j LAB-SVC-MB; sudo iptables -t nat -F LAB-SVC-MB; sudo iptables -t nat -X LAB-SVC-MB; sudo ip route del 10.96.0.0/16 dev lab0 2>/dev/null; sudo ip netns del labns-mb-1; sudo ip netns del labns-mb-2; sudo ip link del lab0; sudo rm -rf /opt/lab-mb`.

#### Scenario 10.6 — "Antigua: the canary stuck at 100/0"
**Solution:**
```bash
# Fault 1 — the canary subset is DEAD but nginx silently retries the other upstream member,
# so clients see zero errors, only a latency blip. The error log proves it's trying v2:
grep -i 'upstream' /opt/lab-ag/error.log        # connect() to 10.90.12.3:8080 failed -> retried
# Chase the dead upstream down Climb 9's stack: process up? listener up? cable up?
sudo ip netns exec labns-ag-v2 ss -tln | grep ':8080'     # app + listener are fine...
ip -br link show labveth-ag2                               # ...state DOWN (the night-shift change)
sudo ip link set labveth-ag2 up                           # switch the cable back on
# Fault 2 — the header pin: nginx maps header 'x-canary' to $http_x_canary (dashes->underscores),
# so `map $http_canary` reads a header literally named 'Canary' and never matches x-canary.
sudo sed -i 's/\$http_canary/$http_x_canary/' /opt/lab-ag/nginx.conf
sudo nginx -c /opt/lab-ag/nginx.conf -s reload
# Verify BOTH halves
for i in $(seq 30); do curl -s http://localhost:8490/; done | sort | uniq -c        # ~27 v1 / 3 v2
for i in $(seq 5);  do curl -s -H 'x-canary: true' http://localhost:8490/; done | sort | uniq -c  # 5 V2-CANARY
```
**Why this works & what it teaches:** Two stacked faults each mask the other's evidence. (1) `labveth-ag2` was set down overnight, so the v2 pod is unreachable; nginx's implicit `proxy_next_upstream` retries the surviving weighted member, so the canary flatlines to 0% with no 5xx — only a p99 bump, which is why canary dashboards must watch per-subset traffic, not error rate. Chasing the dead upstream down the Climb 9 stack (process → listener → cable) finds the downed veth. (2) Even with v2 reachable, the pin fails because nginx exposes header `x-canary` as `$http_x_canary` (dashes become underscores), so `map $http_canary` was matching a nonexistent header named `Canary`; fixing the variable makes the `x-canary: true` pin absolute. Local analogue: the S22 VirtualService canary with silent-retry masking (Envoy retry policy) plus the header-match config-that-looks-right bug that only a 5/5 pin test catches. Where people go wrong: trusting "zero errors" as "canary healthy," or reverse-engineering the setup instead of reading the error log and the variable-naming rule. **Cleanup:** `sudo nginx -c /opt/lab-ag/nginx.conf -s stop; sudo ip netns del labns-ag-v1; sudo ip netns del labns-ag-v2; sudo ip link del lab0; sudo rm -rf /opt/lab-ag`.


