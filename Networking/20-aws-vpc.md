# The AWS VPC

*Your own private wing inside the shared skyscraper of the cloud — where every EKS node, pod, and load balancer actually lives.*

---

## 🛠️ Rung 0 — The Setup

**What am I learning?** The **AWS VPC** (Virtual Private Cloud): a logically-isolated, software-defined private network that *you* own inside AWS's shared physical datacenters. You give it an address range, carve it into subnets, decide which subnets can touch the internet, and control every packet in and out.

**Why did it land on my desk?** You run an EKS cluster. This morning a teammate asked: *"Why can't the new worker nodes pull images?"* You look — the nodes are in a **private subnet** with no route to a **NAT Gateway**. Last week a different fire: the ALB was healthy but returned 504s because the **Security Group** on the nodes didn't allow the health-check port. Every one of these problems is a VPC problem wearing a Kubernetes costume. You've been clicking through the VPC console for years on muscle memory. Now you're rebuilding the mental model from the packet up.

**What do I already know?** You already understand:

- **IP addressing** and **private ranges** — [ip-addressing](02-ip-addressing.md): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.
- **CIDR math** — [subnetting-and-cidr](03-subnetting-and-cidr.md): a `/16` gives you 65,536 addresses, a `/24` gives 256.
- **NAT** — [nat-and-pat](14-nat-and-pat.md): how a private host reaches the internet through a shared public IP.
- **Firewalls** — [firewalls-security-groups-nacls](17-firewalls-security-groups-nacls.md): stateful vs stateless filtering.
- **Load balancing** — [load-balancing](18-load-balancing.md): L4 vs L7, ALB/NLB.

A VPC is where *all* of that stops being theory and becomes the thing your cluster runs inside.

---

## 🔥 Rung 1 — The Pain

Before VPCs, AWS had **EC2-Classic** (2006–2013). Every instance you launched dropped onto one **giant flat shared network** with every other AWS customer in that region. Think of it as a hostel dormitory: your bed is in the same room as thousands of strangers.

What hurt:

- **No isolation.** Your instance got a public IP whether you wanted one or not. Your database and a stranger's database were neighbors on the same L2 broadcast domain (mitigated by Security Groups, but the *topology* was shared).
- **No private address space of your own.** You couldn't say "my network is `10.0.0.0/16`." AWS assigned addresses; you lived with them.
- **No subnets, no route tables.** You could not express "this tier is public, this tier is private, and traffic between them follows *these* rules." Everything was reachable-by-default and firewalled after the fact.
- **No way to model an on-prem network.** Enterprises wanted their cloud to look like their datacenter: DMZ in front, app tier behind, database tier locked in the back. Flat networking made that impossible.

Who felt it most? **Anyone running multi-tier applications** and **anyone with compliance requirements** (PCI, HIPAA) that mandate network segmentation. And today — **you**, the platform engineer. Without a VPC there is no place to put private worker nodes, no NAT for outbound image pulls, no security boundary between the ALB and the pods. EKS literally cannot exist without a VPC; the control plane talks to your nodes across it.

The VPC was AWS's answer: *give every customer their own private, sliceable, routable network that behaves like the datacenter they already know.*

> **Check yourself before Rung 2:** In EC2-Classic every host was reachable by default and firewalled afterward. What single capability must a VPC give you so that a host can be **unreachable from the internet by default** yet still download OS patches? (Name the two components involved.)

---

## 💡 Rung 2 — The One Idea

Here is the sentence. Memorize it:

> **A VPC is your own private, CIDR-sized IP space in the cloud, carved into subnets whose *route tables* decide who can reach the internet — and everything else (IGW, NAT, Security Groups, EKS nodes) is just plumbing hung off that decision.**

Everything derives from this:

- **CIDR-sized** → you pick `10.0.0.0/16`; that's your total address pool. → subnet sizing → **how many pods you can run** (VPC-CNI hands pods real subnet IPs).
- **Carved into subnets** → each subnet lives in **one Availability Zone** → multi-AZ high availability falls out for free.
- **Route tables decide internet reachability** → a subnet is "**public**" *only because* its route table sends `0.0.0.0/0` to an **Internet Gateway**; it's "**private**" *only because* its route table sends `0.0.0.0/0` to a **NAT Gateway** (or nowhere). Public vs private is **not a flag on the subnet — it is a routing decision.** This is the single most misunderstood fact about VPCs. Tattoo it on your brain.
- **Everything else is plumbing** → IGW = the front door, NAT GW = the concierge who hides you, Security Groups = the bouncer at each instance, NACLs = the guard at the neighborhood gate.

If you remember only "route tables decide," you can re-derive the entire VPC from first principles.

---

## ⚙️ Rung 3 — The Machinery (the important one — go slow)

> ### 🧸 Plain-English first (read this before the technical version)
>
> Think of the cloud as a giant shared skyscraper, and a VPC as your company's own private wing inside it. This section builds that wing piece by piece:
>
> **Your block of addresses (3.1).** First you claim a range of internal room numbers — about 65,000 of them. These numbers only mean something inside your wing; the outside world can't dial them directly.
>
> **Floors in different buildings (3.2).** You divide your room numbers into smaller groups called "subnets" — think floors. Each floor physically sits in one particular building (an "Availability Zone" — a separate data center). Put floors in two buildings, and if one building loses power, the other keeps running. A handful of rooms per floor are reserved for building services, so a 256-room floor really holds 251 guests.
>
> **The front door (3.3 — the "Internet Gateway").** One main entrance connects your wing to the street. A floor counts as "public" purely because its directions sign (the "route table" — a list saying "for this destination, go that way") points street-bound traffic at the front door. Public floors can be reached from outside AND can reach out. Crucially: public vs private is not a label on the floor — it's just what the directions say.
>
> **The discreet concierge (3.4 — the "NAT Gateway").** Private floors must be unreachable from the street, yet the servers there still need to fetch things — updates, software images. So their directions point outward traffic at a concierge who runs errands on their behalf, using the concierge's own street address so the outside never learns your room numbers. Replies to errands YOU started come back; strangers can't dial in. Quirk: the concierge's desk must sit on a public floor — otherwise the concierge can't reach the street either. And you want one per building, for resilience.
>
> **The whole map (3.5).** A diagram then shows it assembled: front door on top, public floors holding the concierge desks and the greeter (the load balancer), private floors holding your app servers.
>
> **Two checkpoints (3.6).** Every message passes two guards: the gate guard at the neighborhood entrance (the "NACL," watching a whole floor, no memory, checks everyone both ways, can hold bans) and the bouncer at each individual front door (the "Security Group," per machine, remembers approved conversations so replies pass freely, allow-list only). A packet must satisfy both.
>
> **Where Kubernetes fits (3.7).** Your cluster's worker machines live on the private floors. AWS's networking plugin gives every pod (small app container) a real room number from your range — which means the size of your floors directly limits how many pods you can run. Public-facing traffic comes in via a load balancer on the public floor; private servers fetch images through the concierge; and AWS quietly installs a few phone jacks (network interfaces) in your wing so its managed control room can talk to your machines — your bouncers must allow those calls.

*Now the original technical deep-dive — the same ideas, in precise form:*

Let's build a VPC from nothing and watch each part snap into place.

### 3.1 The address space

You create a VPC and hand it a **CIDR block**: `10.0.0.0/16`. That's `2^(32-16) = 65,536` total addresses (`10.0.0.0` → `10.0.255.255`). This is your private wing of the skyscraper — nobody else's traffic is in it, and these are private IPs ([ip-addressing](02-ip-addressing.md)) that mean nothing on the public internet.

### 3.2 Subnets = floors, one per Availability Zone

You slice the `/16` into subnets. Each subnet is a `/24` (256 addresses) or bigger, and **each subnet lives in exactly one AZ** (`us-east-1a`, `us-east-1b`, …). AWS reserves **5 addresses per subnet** (network address, VPC router, DNS, future use, broadcast), so a `/24` gives you **251 usable**, not 254.

```
VPC 10.0.0.0/16  (65,536 addresses — YOUR private wing)
│
├── AZ us-east-1a
│     ├── 10.0.0.0/24   public   (ALB, NAT GW, bastion live here)
│     └── 10.0.10.0/24  private  (EKS nodes + pods live here)
│
└── AZ us-east-1b
      ├── 10.0.1.0/24   public
      └── 10.0.11.0/24  private
```

Two AZs = if a whole datacenter (AZ) burns down, the other keeps serving. That is **multi-AZ high availability**, and it costs you nothing but planning.

### 3.3 The Internet Gateway (IGW) — the front door

The **IGW** is a horizontally-scaled, redundant AWS-managed component you attach to the *VPC* (one per VPC). It does two jobs:

1. Provides a target in route tables for internet-bound traffic.
2. Performs **1:1 NAT** between an instance's private IP and its **public/Elastic IP** — this is why a public instance needs *both* a public IP *and* an IGW route.

A subnet becomes **public** the moment its route table contains:

```
Destination     Target
10.0.0.0/16     local          <- every route table has this; intra-VPC traffic
0.0.0.0/0       igw-0abc123    <- THIS line makes the subnet public
```

Traffic to the IGW is **bidirectional** — the outside world can reach these instances (if a Security Group allows it) and they can reach out.

### 3.4 The NAT Gateway — the concierge who hides you

Private subnets must *not* be reachable from the internet, but your EKS nodes still need **outbound** access — to `docker pull` images, hit the EKS API, call AWS APIs, download OS updates. Enter the **NAT Gateway**: an AWS-managed component that does **outbound-only** source NAT (SNAT/masquerade — see [nat-and-pat](14-nat-and-pat.md)).

Three facts that trip everyone up:

1. **The NAT Gateway itself lives IN a public subnet.** It needs an IGW route to reach the internet. A NAT GW in a private subnet is a dead concierge.
2. It **hides private IPs.** Outbound packets leave with the NAT GW's Elastic IP as the source; the internet never learns `10.0.10.37`.
3. It is **stateful and outbound-only.** Return traffic for connections *you* initiated flows back; unsolicited inbound is dropped. Nobody dials in.

The private subnet's route table:

```
Destination     Target
10.0.0.0/16     local
0.0.0.0/0       nat-0def456    <- outbound goes to the NAT GW (which sits in the public subnet)
```

For real HA you run **one NAT Gateway per AZ** and point each private subnet at the NAT GW in its own AZ — otherwise an AZ failure kills outbound for everyone, and you pay cross-AZ data charges.

### 3.5 The whiteboard: the whole VPC

```
                          INTERNET
                              │
                        ┌─────┴─────┐
                        │    IGW    │  (attached to VPC, 1:1 NAT + door)
                        └─────┬─────┘
        ════════════════════ VPC 10.0.0.0/16 ════════════════════
        ║                     │                                  ║
        ║   ┌──── AZ us-east-1a ────┐    ┌──── AZ us-east-1b ───┐║
        ║   │ PUBLIC 10.0.0.0/24    │    │ PUBLIC 10.0.1.0/24   │║
        ║   │  ┌─────┐  ┌────────┐  │    │  ┌────────┐          │║
        ║   │  │ ALB │  │ NAT GW │  │    │  │ NAT GW │          │║
        ║   │  └──┬──┘  └───┬────┘  │    │  └───┬────┘          │║
        ║   │     │  ▲      │       │    │      │               │║
        ║   │ route→IGW  route→IGW  │    │  route→IGW           │║
        ║   └─────┼──────┼──────────┘    └──────┼──────────────┘║
        ║         │      │ (outbound)           │                ║
        ║   ┌─────┼──────┼──────────┐    ┌──────┼──────────────┐║
        ║   │ PRIVATE 10.0.10.0/24  │    │ PRIVATE 10.0.11.0/24 │║
        ║   │  ┌──────────────┐     │    │  ┌──────────────┐    │║
        ║   │  │ EKS node     │◄────┘    │  │ EKS node     │    │║
        ║   │  │ pods: VPC IPs│  route→NAT│ │ pods: VPC IPs│    │║
        ║   │  └──────────────┘  0.0.0.0/0│ └──────────────┘    │║
        ║   └───────────────────────┘    └──────────────────────┘║
        ═══════════════════════════════════════════════════════
```

### 3.6 The two firewalls — Security Group vs NACL

Two layers of packet filtering, and they are *not* the same thing (full treatment in [firewalls-security-groups-nacls](17-firewalls-security-groups-nacls.md)):

- **Security Group (SG)** — attached to an **instance / ENI** (elastic network interface). **Stateful**: if you allow an inbound request, the response is automatically allowed back out (and vice-versa). Allow-rules only; there is no "deny." This is the bouncer standing at *each door*.
- **NACL (Network ACL)** — attached to a **subnet**. **Stateless**: it evaluates every packet independently, so you must write *both* the inbound rule *and* the matching outbound rule (including the ephemeral port range `1024–65535` for return traffic). Supports allow *and* deny, evaluated by rule number. This is the guard at the *neighborhood gate*.

Analogy: the **NACL** checks your ID at the gated-community entrance (subnet); the **Security Group** checks it again at the actual house's front door (instance). A packet must satisfy both.

### 3.7 Where EKS plugs in

This is the payoff. In EKS:

- **Worker nodes live in VPC subnets** — production node groups almost always go in **private** subnets.
- The **Amazon VPC-CNI** plugin gives every **pod a real IP from the subnet's CIDR** (not an overlay). A pod at `10.0.10.42` is a first-class citizen of your VPC. → this is why **subnet size directly caps pod count**: a `/24` private subnet (251 usable) minus node primary IPs minus ENI overhead can run out of pod IPs fast. Big clusters need `/20` or bigger subnets, or secondary CIDRs.
- **Public node group vs private node group:** public nodes get public IPs and route to the IGW; private nodes route outbound through the **NAT Gateway** to pull images and reach the EKS API.
- The **ALB** (from the AWS Load Balancer Controller) sits in **public subnets** and forwards to pods/nodes in **private subnets** — the request flow you'll trace in Rung 5.
- **Control-plane cross-account ENIs:** the EKS control plane runs in an AWS-managed account, but AWS injects **ENIs into *your* VPC subnets** so the managed control plane can reach your nodes' kubelet (`10250`) and vice-versa. Those ENIs are why your node Security Groups must allow the control-plane SG on `443` and `10250`.

> **Check yourself before Rung 4:** A NAT Gateway is described as "in a public subnet." Using only the route-table idea from Rung 2, explain *why* it has to be there and what specifically breaks if you place it in a private subnet.

---

## 🏷️ Rung 4 — The Vocabulary Map

| Term | What it actually is | Which part of the machinery it touches |
|---|---|---|
| **VPC** | A logically-isolated virtual network you own, defined by a CIDR block | The whole private wing — the container for everything below |
| **CIDR block** | The address range of the VPC/subnet, e.g. `10.0.0.0/16` | Sizes the total IP pool → caps pods & instances |
| **Subnet** | A slice of the VPC CIDR bound to **one AZ**, e.g. `10.0.10.0/24` | A "floor"; public or private depending on its route table |
| **Availability Zone (AZ)** | An isolated datacenter within a region | Each subnet lives in exactly one → multi-AZ HA |
| **Route table** | A list of `destination → target` rules attached to subnets | The decision-maker: public vs private is defined here |
| **Internet Gateway (IGW)** | VPC-attached component; door + 1:1 NAT to public IPs | Target `0.0.0.0/0` in *public* subnet route tables |
| **NAT Gateway** | Managed outbound-only SNAT device in a public subnet | Target `0.0.0.0/0` in *private* subnet route tables |
| **Elastic IP (EIP)** | A static public IPv4 you own | Attached to NAT GW / public instances |
| **Security Group (SG)** | **Stateful** firewall on an instance/ENI, allow-only | The bouncer at each door (instance) |
| **NACL** | **Stateless** firewall on a subnet, allow + deny | The guard at the neighborhood gate (subnet) |
| **ENI** | Elastic Network Interface — a virtual NIC with IP(s) | What SGs attach to; what pods & control plane use |
| **Bastion / jump host** | A hardened instance in a public subnet used to SSH into private ones | Controlled human entry point to private subnets |
| **VPC peering** | A 1:1 private connection between two VPCs | Requires **non-overlapping CIDRs**; adds routes both sides |
| **Transit Gateway (TGW)** | A hub-and-spoke router connecting many VPCs/on-prem | Scales beyond peering's mesh; still needs non-overlapping CIDRs |
| **VPC-CNI** | The EKS CNI that gives pods real subnet IPs | Consumes subnet addresses → subnet size = pod capacity |

**Same kind of thing, different names:**

- **IGW and NAT Gateway** are *both* NAT devices — IGW does **bidirectional 1:1** NAT (public instances), NAT GW does **outbound-only many:1** NAT (private instances hiding behind one EIP). Same family, opposite doors.
- **Security Group and NACL** are *both* packet firewalls — one is **stateful/per-instance/allow-only**, the other **stateless/per-subnet/allow+deny**. Two rings of the same defense.
- **VPC peering and Transit Gateway** are *both* VPC interconnects — peering is a point-to-point cable, TGW is a central switchboard. Both forbid overlapping CIDRs.
- **Public subnet and private subnet** are *the same object* — a subnet — distinguished *only* by whether its route table's `0.0.0.0/0` points at an IGW or a NAT GW.

---

## 🔬 Rung 5 — The Trace

**The action:** a user in a browser opens `https://shop.example.com`, which is an EKS app. Nodes are in private subnets; an ALB fronts them. Follow the request all the way to a pod and back.

```
   User (203.0.113.9)
        │  1. DNS → ALB's public IP; opens TCP :443 (TLS handshake)
        ▼
 ┌──────────────┐
 │     IGW      │  2. bidirectional door; DNAT public IP → ALB in public subnet
 └──────┬───────┘
        ▼
 PUBLIC subnet 10.0.0.0/24
 ┌──────────────┐
 │     ALB      │  3. L7 LB terminates TLS, picks a healthy target,
 │ (SG allows   │     opens a NEW conn to a target in the private subnet
 │  :443 in)    │
 └──────┬───────┘
        │  4. ALB's route table: dest 10.0.10.0/24 → local (intra-VPC)
        ▼
 PRIVATE subnet 10.0.10.0/24
 ┌──────────────┐
 │ Node SG      │  5. SG on node/ENI: allow :30080 (NodePort/target) FROM the ALB's SG
 │ ✔ stateful   │
 ├──────────────┤
 │ kube-proxy   │  6. iptables/IPVS DNAT: target port → a pod IP:containerPort
 ├──────────────┤
 │ Pod 10.0.10.42 (real VPC IP via VPC-CNI)  7. app handles request
 └──────┬───────┘
        │  8. response — SG is STATEFUL, return traffic auto-allowed
        ▼   (no explicit outbound rule needed)
      back through ALB ──► IGW ──► User
```

Step by step:

1. **DNS resolves** `shop.example.com` to the ALB's public IP ([dns](09-dns.md)). The user's browser opens **TCP port 443** and begins the **TLS handshake** ([tls-ssl](11-tls-ssl-encryption-in-transit.md)) after the **TCP 3-way handshake** (`SYN → SYN-ACK → ACK`, see [transport-layer](07-transport-layer-tcp-udp.md)).
2. The packet hits the **Internet Gateway** — the bidirectional door — which maps the public destination IP to the ALB's interface inside the VPC.
3. The **ALB** lives in the **public subnet**. Its Security Group allows `:443` inbound from the internet. It terminates TLS, chooses a healthy backend, and opens a **brand-new connection** into the private subnet.
4. The ALB's **route table** matches destination `10.0.10.0/24` against the `local` route — this is **intra-VPC** traffic, no IGW/NAT involved.
5. The packet arrives at the **node's Security Group** on the target port (e.g. `30080`, within the NodePort range `30000–32767`). The SG allows that port **from the ALB's Security Group** — SGs can reference other SGs, not just CIDRs. Stateful, so the reply path is pre-approved.
6. **kube-proxy** on the node (iptables or IPVS mode) does **DNAT** — rewriting the destination to a specific **pod IP:containerPort** ([kubernetes-services-kube-proxy](25-kubernetes-services-kube-proxy.md)).
7. The **pod at `10.0.10.42`** — holding a **real VPC IP** thanks to the VPC-CNI — processes the HTTP request.
8. The response flows back. Because the node's Security Group is **stateful**, the return traffic needs **no explicit rule**. It rides back through the ALB, out the IGW, to the user.

Notice: the pod initiating an *outbound* call (say, to an external API) would instead follow `0.0.0.0/0 → NAT Gateway → IGW → internet`, and its private IP would be hidden behind the NAT GW's EIP. Same VPC, different door.

> **Check yourself before Rung 6:** At step 5 the node SG references the ALB's SG rather than a CIDR. If instead you had used a stateless **NACL** on the private subnet to allow `:30080` inbound, what *second* rule would you be forced to add, and why does the Security Group not need it?

---

## ⚖️ Rung 6 — The Contrast

**The older/alternative approach:** **EC2-Classic** (flat shared network) and, more broadly, **running your own network in an on-prem datacenter**.

| Capability | On-prem / EC2-Classic | AWS VPC |
|---|---|---|
| Isolation | Physical cabling / VLANs; shared L2 in Classic | Full logical isolation per tenant, on demand |
| Define your own CIDR | Yes (on-prem); No (Classic) | Yes — pick any RFC 1918 range |
| Public vs private tiers | Manual firewalls, DMZ hardware | Route-table decision, seconds to change |
| Outbound-only for private hosts | NAT appliance you rack & maintain | Managed **NAT Gateway**, no servers |
| Multi-AZ HA | Build a second datacenter | Spread subnets across AZs, done |
| Per-instance stateful firewall | Host firewall you configure | **Security Groups**, native |
| Connect networks | MPLS, VPN hardware, routers | **VPC peering / Transit Gateway** |
| Elastic scaling of the network | Buy more hardware | Software-defined, instant |

**What the VPC can do that the alternative cannot:** reshape your entire network topology — new subnets, new routes, new firewalls — with an API call and zero hardware, and hand every pod a routable IP automatically.

**What the alternative can do that VPC cannot (cleanly):** give you full control of the physical layer and Layer 2 semantics (broadcast, multicast, custom routing protocols). VPC deliberately hides L2 — there's no ARP-spoofing, no promiscuous sniffing, no custom BGP inside a subnet.

**When would I NOT need this?** If you're running a single toy instance with a public IP and no isolation requirements — but even then AWS puts you in a **default VPC**, so you're always in one. There's no "no VPC" anymore.

**Why this over that:** *Use a VPC because it turns network architecture — segmentation, NAT, HA, firewalling — into software you change in seconds instead of hardware you rack in weeks.*

> **Check yourself before Rung 7:** You want to connect VPC-A (`10.0.0.0/16`) to VPC-B (`10.0.0.0/16`) via peering so their EKS clusters can talk. Predict what happens and explain the mechanism from the route-table idea.

---

## 🧪 Rung 7 — The Prediction Test

Now the hands-on. **Write your prediction first, then run.** These use the AWS CLI (`aws ec2 …`), `kubectl`, and standard Linux net tools. Assume a configured profile and region.

### Prediction 1 (normal case): The route table is what makes a subnet "public"

> **Prediction:** *If I inspect a public subnet's route table, I will see a `0.0.0.0/0 → igw-…` route; the private subnet's will show `0.0.0.0/0 → nat-…`. BECAUSE public vs private is purely a routing decision, not a subnet attribute.*

```bash
# List route tables and their routes for the VPC
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-0aaa111" \
  --query 'RouteTables[].{RT:RouteTableId,Routes:Routes[].{Dest:DestinationCidrBlock,GW:GatewayId,NAT:NatGatewayId}}' \
  --output table
# Expected: one RT has GW=igw-xxxx for 0.0.0.0/0  (public)
#           another has NAT=nat-xxxx for 0.0.0.0/0 (private)
```

**Verify:** The public RT's default route targets the **IGW**; the private RT's targets the **NAT GW**. If a "private" subnet shows `igw-…`, it is *actually public* and your nodes are exposed — a real security finding. If it shows *no* `0.0.0.0/0` route at all, the subnet is fully isolated (fine for internal-only tiers, but breaks image pulls).

### Prediction 2 (edge/failure case): No NAT route = private instance cannot reach the internet

> **Prediction:** *If I SSH into a private instance (via a bastion) and curl the internet while its subnet has NO NAT route, the connection will hang and time out. BECAUSE with no `0.0.0.0/0` target, the VPC router has nowhere to send the packet — it's dropped.*

```bash
# From the bastion (public subnet) hop to the private node
ssh -J ec2-user@BASTION_PUBLIC_IP ec2-user@10.0.10.37

# On the private node — try outbound
curl -v --max-time 5 https://registry-1.docker.io/v2/
# Expected (no NAT): curl: (28) Connection timed out after 5001 ms

# Confirm you CAN reach something inside the VPC (proves the node is alive)
ping -c1 10.0.10.1   # the VPC router / gateway — replies
```

**Verify:** Internet curl **times out** (not "connection refused" — refused would mean a firewall RST; timeout means *no route*). Intra-VPC ping works, proving the node itself is healthy and the problem is purely the missing NAT route. Add the `0.0.0.0/0 → nat-…` route and the same curl succeeds. **This is the exact cause of "my private EKS nodes can't pull images."**

```bash
# The fix: add the default route to the NAT Gateway
aws ec2 create-route \
  --route-table-id rtb-0priv999 \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id nat-0def456
```

### Prediction 3 (Kubernetes-flavored case): Subnet size caps pod count via VPC-CNI

> **Prediction:** *If my nodes sit in a small subnet and I scale a Deployment aggressively, some pods will get stuck in `ContainerCreating` with a "failed to assign an IP" CNI error. BECAUSE the VPC-CNI draws each pod's IP from the subnet CIDR, and a `/24` (251 usable) shared across nodes, ENIs, and existing pods runs dry.*

```bash
# How many free IPs remain in the private subnet?
aws ec2 describe-subnets --subnet-ids subnet-0priv10 \
  --query 'Subnets[0].{Cidr:CidrBlock,Free:AvailableIpAddressCount}'
# e.g. {"Cidr":"10.0.10.0/24","Free":12}

# Scale hard and watch pods fail to get IPs
kubectl scale deploy/shop --replicas=200
kubectl get pods -o wide | grep -c ContainerCreating

# The smoking gun — VPC-CNI can't allocate
kubectl describe pod <stuck-pod> | grep -A2 -i "failed to assign\|InsufficientFreeAddresses"
# Events: ... failed to assign an IP address to container ...
```

**Verify:** `AvailableIpAddressCount` drops toward 0 as pods scale; new pods stall in `ContainerCreating` with an IP-assignment error in their events. A wrong result (pods schedule fine forever) would teach you the subnet is large enough — but the lesson stands: **in EKS with the VPC-CNI, subnet CIDR size is a hard ceiling on pods.** The fix is bigger subnets (a `/20` = 4,091 usable) or attaching a **secondary CIDR** to the VPC.

### Prediction 4 (firewall case): Security Group is stateful; a missing SG rule refuses, a NACL needs two rules

> **Prediction:** *If the node's Security Group does not allow the ALB's health-check port, curling that port from the ALB's subnet gives an immediate "connection timed out" (SG silently drops); once I add ONE inbound allow rule, it works — I never touch outbound, BECAUSE SGs are stateful.*

```bash
# See what the node SG currently allows inbound
aws ec2 describe-security-groups --group-ids sg-0node \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Src:UserIdGroupPairs[].GroupId||IpRanges[].CidrIp}'

# Add ONE stateful inbound rule: allow the target port FROM the ALB's SG
aws ec2 authorize-security-group-ingress \
  --group-id sg-0node \
  --protocol tcp --port 30080 \
  --source-group sg-0alb
# Note: no matching egress rule needed — return traffic is auto-allowed.

# From a host in the ALB subnet, confirm reachability
nc -vz 10.0.10.37 30080     # succeeds after the rule; times out before it
```

**Verify:** Before the rule, `nc` **times out** (SG drops silently — no RST). After adding a *single* inbound rule, it connects, and you added **no egress rule** — proof of statefulness. Contrast: on a **stateless NACL** you'd need *both* an inbound allow for `:30080` *and* an outbound allow for the ephemeral return range `1024–65535`, or the response is silently dropped. (Deep dive: [firewalls-security-groups-nacls](17-firewalls-security-groups-nacls.md).)

### Prediction 5 (peering case): Overlapping CIDRs make peering impossible

> **Prediction:** *If I try to peer VPC-A `10.0.0.0/16` with VPC-B `10.0.0.0/16`, the peering connection can be created but adding the cross-route fails / traffic never flows. BECAUSE a route table can't decide where `10.0.5.7` lives when it exists in both VPCs — the destination is ambiguous.*

```bash
aws ec2 create-vpc-peering-connection \
  --vpc-id vpc-0aaa111 --peer-vpc-id vpc-0bbb222
# Accept it, then try to route B's range from A:
aws ec2 create-route --route-table-id rtb-0A \
  --destination-cidr-block 10.0.0.0/16 \
  --vpc-peering-connection-id pcx-0xyz
# Expected: RouteAlreadyExists — 10.0.0.0/16 is A's OWN local range; ambiguous.
```

**Verify:** You cannot install a non-overlapping route because `10.0.0.0/16` already resolves to `local` in VPC-A. The lesson: **VPC peering (and Transit Gateway) require non-overlapping CIDRs** — this is why you must plan address space across *all* clusters/accounts up front. The correct design gives B a distinct range like `10.1.0.0/16`, then each side adds a route to the other's CIDR via the peering connection (`pcx-…`) or the TGW attachment.

---

## 🏔️ Capstone — Compress It

**One sentence (no notes):**
A VPC is your own CIDR-sized private network in AWS, sliced into per-AZ subnets whose route tables decide — via an IGW or a NAT Gateway — who reaches the internet, and it's where every EKS node, pod, and load balancer lives.

**Three-sentence beginner explanation:**
A VPC is a private, isolated network you rent inside AWS and give an address range like `10.0.0.0/16`. You cut it into subnets across multiple availability zones, and a subnet is "public" if its route table sends internet traffic to an Internet Gateway or "private" if it sends outbound traffic to a NAT Gateway (which hides your private IPs). Two firewalls guard it — Security Groups on each instance (stateful) and NACLs on each subnet (stateless) — and in EKS your worker nodes sit in private subnets while an ALB in the public subnets carries user traffic to pods that hold real VPC IPs.

**Sub-parts mapped to the one core idea** (*route tables decide who reaches the internet*):

| Sub-part | Derives from the core idea how |
|---|---|
| Public subnet | Route table → `0.0.0.0/0` → **IGW** |
| Private subnet | Route table → `0.0.0.0/0` → **NAT GW** |
| NAT GW in public subnet | It needs the IGW route to function |
| Multi-AZ HA | Subnets are per-AZ; spread them, survive AZ loss |
| VPC-CNI pod IPs | Pods draw from subnet CIDR → size caps pods |
| SG vs NACL | Two filter rings layered on the routed path |
| Peering / TGW | Extra routes to *other* VPCs — non-overlapping CIDRs |

**Which rung to revisit hands-on:** **Rung 7, Prediction 2 (missing NAT route)** and **Prediction 3 (subnet size caps pods)** — these two are the failures you will actually hit on EKS, and running them once cements the whole model. If the *machinery* still feels fuzzy, re-draw the Rung 3.5 whiteboard from memory before touching the console.

---

## Related concepts

- [Subnetting & CIDR](03-subnetting-and-cidr.md) — the math behind VPC and subnet sizing that caps your pods.
- [NAT & PAT](14-nat-and-pat.md) — how the NAT Gateway hides private IPs on the way out.
- [Firewalls, Security Groups & NACLs](17-firewalls-security-groups-nacls.md) — stateful vs stateless, the two rings guarding your subnets.
- [Load balancing](18-load-balancing.md) — the ALB/NLB in your public subnets fronting private nodes.
- [Kubernetes pod networking & CNI](24-kubernetes-pod-networking-cni.md) — how the VPC-CNI turns subnet IPs into pod IPs.
- [VPN & zero-trust connectivity](19-vpn-and-zero-trust-connectivity.md) — the other way (besides peering/TGW) to reach into a VPC.

---

## ✅ Answers — "Check yourself before Rung N"

### Before Rung 2
**Q:** In EC2-Classic every host was reachable by default and firewalled afterward. What single capability must a VPC give you so that a host can be unreachable from the internet by default yet still download OS patches? (Name the two components involved.)

**A:** The capability is **per-subnet route tables** — letting *you* decide, by routing, which subnets can be reached from the internet and which can only reach *out*. The two components are the **Internet Gateway** and the **NAT Gateway**: the host sits in a private subnet whose route table sends `0.0.0.0/0` to a NAT Gateway (not an IGW), and that NAT Gateway sits in a public subnet with an IGW route. Because the NAT Gateway does outbound-only, stateful many:1 SNAT, the host can initiate connections to patch mirrors and get replies back, while unsolicited inbound from the internet is dropped and the host's private IP is never exposed. Unreachable by default, outbound on demand — a pure routing decision, not an after-the-fact firewall.

### Before Rung 4
**Q:** A NAT Gateway is described as "in a public subnet." Using only the route-table idea from Rung 2, explain why it has to be there and what specifically breaks if you place it in a private subnet.

**A:** The NAT Gateway's whole job is to forward private hosts' traffic to the internet with its own Elastic IP as source — so *it* must have a working path to the internet, and by the Rung 2 idea, "has a path to the internet" means "sits in a subnet whose route table sends `0.0.0.0/0` to the IGW," i.e. a public subnet. Put it in a private subnet and its own default route points at… a NAT Gateway (itself, or nowhere) instead of the IGW — a dead concierge: it can accept the nodes' outbound packets but has no route to actually deliver them to the internet, so every outbound connection (image pulls, OS updates, AWS API calls) hangs and times out. Public vs private is not a flag on the subnet; it is purely which target the route table's `0.0.0.0/0` line names, and the NAT GW needs that target to be `igw-…`.

### Before Rung 6
**Q:** At step 5 the node SG references the ALB's SG rather than a CIDR. If instead you had used a stateless NACL on the private subnet to allow `:30080` inbound, what second rule would you be forced to add, and why does the Security Group not need it?

**A:** You would be forced to add an **outbound NACL rule allowing the ephemeral port range 1024–65535** back toward the ALB's subnet, because a NACL is stateless: it evaluates every packet independently, and the pod's response leaves with a high ephemeral destination port that the inbound `:30080` rule says nothing about — without the second rule, the reply is silently dropped at the subnet gate. The Security Group doesn't need it because it is **stateful**: when it allowed the ALB's request in on `:30080`, it recorded the connection, and return traffic for an approved connection is automatically allowed back out — no explicit egress rule ever required. (Bonus of the SG approach: referencing `sg-0alb` instead of a CIDR keeps the rule valid as the ALB scales and its IPs change — a NACL can only match CIDRs.)

### Before Rung 7
**Q:** You want to connect VPC-A (`10.0.0.0/16`) to VPC-B (`10.0.0.0/16`) via peering so their EKS clusters can talk. Predict what happens and explain the mechanism from the route-table idea.

**A:** It fails — traffic can never flow between them, because peering requires **non-overlapping CIDRs**. The mechanism is pure route-table logic: to use the peering you must add a route in VPC-A saying "`10.0.0.0/16` → `pcx-…`", but VPC-A's route table *already* resolves `10.0.0.0/16` to `local` (every route table has the VPC's own CIDR as the local route), so the route can't be installed (`RouteAlreadyExists`) and the destination is ambiguous — when a packet targets `10.0.5.7`, the router cannot decide whether that address lives in A or in B. The fix is address planning: give VPC-B a distinct range like `10.1.0.0/16`, then each side adds a route to the *other's* CIDR via the peering connection (or a Transit Gateway attachment, which has the same non-overlap requirement). This is why you must plan CIDRs across all clusters and accounts up front.
