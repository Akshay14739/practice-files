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
