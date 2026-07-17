# AWS — Interview Q&A (from Akshay's real interviews)

Reconstructed from actual interview transcripts, deduped and grouped by sub-theme. Each entry keeps his real answer honestly, then gives an authoritative correct answer plus a runnable snippet. Weakest areas were AWS networking (endpoints/peering/TGW/subnet placement), IAM (assume-role/STS), and EC2 status checks — those are given extra-clear treatment.

---

## IAM & Security

## Q1. What is an assume role?
**Asked in:** Trianz  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I think assume role gets assigned by default, I believe." After the interviewer explained it, said "I was not aware of this."

**✅ Correct answer:**
`sts:AssumeRole` is the STS action that lets a *principal* (an IAM user, an EC2/EKS workload, or another role) temporarily **become a different IAM role** and receive short-lived credentials (AccessKeyId + SecretAccessKey + SessionToken) instead of using long-lived keys. It is the backbone of:
- **Cross-account access** — a role in Account B has a *trust policy* naming Account A as principal; identities in A call `AssumeRole` to get B's permissions.
- **Least privilege / privilege escalation on demand** — base identity has almost nothing; assumes an elevated role only when needed.
- **Workloads** — EC2 instance profiles and EKS IRSA both work by assuming a role under the hood.

Two policies are always involved:
1. **Trust policy** (attached to the target role, `AssumeRolePolicyDocument`) — *who is allowed to assume it* (the `Principal`).
2. **Permissions policy** (on the caller) — the caller must be allowed to call `sts:AssumeRole` on that role ARN.

Both must allow the call. This is the exact thing he should drill: **Effect / Action / Resource / Principal**.

```json
// Trust policy ON the target role in Account B (222222222222)
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::111111111111:root" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:ExternalId": "akshay-demo" } }
  }]
}
// Permission policy on the CALLER in Account A:
// { "Effect":"Allow","Action":"sts:AssumeRole","Resource":"arn:aws:iam::222222222222:role/CrossAcctRole" }
// CLI:  aws sts assume-role --role-arn arn:aws:iam::222222222222:role/CrossAcctRole --role-session-name akshay
```

---

## Q2. What is S3 / what is STS?
**Asked in:** GlobalLogic  |  **My performance:** Didn't-know

**My answer (from transcript):**
Response was garbled/non-committal ("Yes T. Yes... sorry, no sir"). Effectively did not answer.

**✅ Correct answer:**
- **S3 (Simple Storage Service):** object storage — data stored as objects in buckets, addressed by key, 11-nines durability, virtually unlimited. Not a filesystem or block device; you GET/PUT whole objects over HTTPS. Used for artifacts, backups, static websites, data lakes, Terraform state, logs.
- **STS (Security Token Service):** the service that issues **temporary, expiring credentials**. Key APIs: `AssumeRole` (cross-account / role switching), `AssumeRoleWithWebIdentity` (OIDC — this is what EKS IRSA and GitHub Actions OIDC use), `GetCallerIdentity` (who am I?). STS is *how* you get creds without hardcoding access keys.

They pair constantly: e.g. an EKS pod uses **STS `AssumeRoleWithWebIdentity`** to get a role that grants **S3** access — no static keys anywhere.

```bash
# Who am I right now (account, user/role ARN, userId)?
aws sts get-caller-identity

# Basic S3 usage
aws s3 mb s3://akshay-demo-bucket
aws s3 cp ./app.tar.gz s3://akshay-demo-bucket/artifacts/app.tar.gz
aws s3 ls s3://akshay-demo-bucket/artifacts/
```

---

## VPC & Networking

## Q3. What is the use of a VPC endpoint?
**Asked in:** Trianz  |  **My performance:** Incorrect

**My answer (from transcript):**
Said a VPC endpoint is used to connect different AWS services across multiple AWS accounts, and (when pushed) across multiple regions. (Missed the core purpose; conflated it with peering / PrivateLink cross-account.)

**✅ Correct answer:**
A **VPC endpoint** gives resources inside your VPC **private connectivity to AWS services without traversing the public internet** (no IGW, no NAT, traffic stays on the AWS backbone). Two kinds — know the difference cold:

| Type | Backed by | Used for | How it works |
|------|-----------|----------|--------------|
| **Gateway endpoint** | Route table entry | **S3 and DynamoDB only** | Adds a prefix-list route in your route table; free |
| **Interface endpoint** (PrivateLink) | ENI + private IP in your subnet | Most other services (ECR, STS, SQS, SNS, Secrets Manager, EKS API, *and your own services*) | Puts an ENI with a private IP into your subnet; you hit that IP |

It is **not** about crossing accounts or regions in general — it's private access to a *service*. (Cross-account *service exposure* is PrivateLink/Interface endpoints; cross-VPC *network* connectivity is peering / Transit Gateway.)

```hcl
# Gateway endpoint for S3 (free) — no NAT needed for S3 from private subnets
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# Interface endpoint (PrivateLink) for ECR pulls without internet
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

---

## Q4. What is the difference between VPC peering and Transit Gateway?
**Asked in:** GlobalLogic  |  **My performance:** Didn't-know

**My answer (from transcript):**
VPC peering connects two different VPCs so they can communicate. Not sure about Transit Gateway — "I've heard of it but I'm not sure, I can look into it."

**✅ Correct answer:**
Both connect VPCs privately, but they scale very differently:

- **VPC Peering** — a **1:1**, point-to-point link between exactly two VPCs. **Non-transitive**: if A↔B and B↔C are peered, A **cannot** reach C through B. For *n* fully-connected VPCs you need *n(n-1)/2* peerings (a mesh that explodes). No bandwidth bottleneck, no hourly cost per connection (just data transfer). Good for a couple of VPCs.
- **Transit Gateway (TGW)** — a **regional hub-and-spoke router**. Every VPC (and VPN/Direct Connect, and other regions via peering) attaches once to the TGW; routing between them is handled centrally with route tables. **Transitive** and scales to thousands of attachments. This is the answer for **many VPCs / multi-account** networking, centralized egress, and hybrid connectivity. Costs per attachment + per GB.

Rule of thumb: 2-3 VPCs → peering; an organization with many accounts/VPCs → Transit Gateway.

```hcl
resource "aws_ec2_transit_gateway" "hub" { description = "org-hub" }

resource "aws_ec2_transit_gateway_vpc_attachment" "app" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.app.id
  subnet_ids         = aws_subnet.app_private[*].id
}
# Then add routes in each VPC route table pointing the "other" CIDRs at the TGW:
# route { cidr_block = "10.20.0.0/16"  transit_gateway_id = aws_ec2_transit_gateway.hub.id }
```

---

## Q5. Multi-account, all infra in private subnets, no jump host per account — route every account's internet-bound traffic through one central org/root gateway account. How?
**Asked in:** Trianz-K8s  |  **My performance:** Incorrect

**My answer (from transcript):**
First suggested VPC endpoints between child accounts and the master account. Interviewer corrected that VPC endpoints are only for AWS-service communication (e.g. S3), not general internet. Then guessed "VPN network associations / some VPN connectivity between the children." (Missed the intended Transit Gateway centralized-egress answer.)

**✅ Correct answer:**
This is the classic **centralized egress** pattern, built on **Transit Gateway**:
1. Create a **Transit Gateway** in the network/egress account and share it via **AWS RAM** to all child accounts.
2. Each child (spoke) VPC **attaches** to the TGW and has a **default route `0.0.0.0/0` → TGW**. Spokes have **no NAT and no IGW** of their own.
3. A central **egress VPC** in the network account holds the **NAT Gateways** (in public subnets) and the **Internet Gateway**. Its TGW route table sends `0.0.0.0/0` out through the NAT → IGW.
4. TGW route tables tie it together: spoke default route → egress VPC attachment; egress VPC returns via TGW.

Result: one shared, auditable, cost-consolidated internet exit for the whole org. (VPC endpoints were wrong because they only reach *AWS services*, not the general internet.)

```hcl
# Spoke VPC: default route to the shared Transit Gateway (no local NAT/IGW)
resource "aws_route" "spoke_default_to_tgw" {
  route_table_id         = aws_route_table.spoke_private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.shared_tgw_id
}

# In the central egress VPC, the TGW route table sends 0.0.0.0/0 to the egress attachment,
# whose private route tables point 0.0.0.0/0 at the NAT Gateway -> Internet Gateway.
resource "aws_ec2_transit_gateway_route" "default_via_egress" {
  transit_gateway_route_table_id = var.tgw_rt_id
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.egress.id
}
```

---

## Q6. Public and private subnets — in which node group do you deploy the UI? What's the correct architecture for a frontend app?
**Asked in:** Virtusa  |  **My performance:** Incorrect

**My answer (from transcript):**
First said UI can go in public or private, "I think we can go with public." Interviewer warned that public exposes it to the internet. Wavered, then said even in a private subnet the request can still route via backend connectivity, and mentioned NAT gateway (which the interviewer corrected is for *outbound*). Interviewer had to state the pattern.

**✅ Correct answer:**
**Application/frontend pods (and their nodes) belong in PRIVATE subnets. Only the load balancer sits in the PUBLIC subnets.** This holds even for a public-facing frontend:
- The **internet-facing ALB/NLB** lives in public subnets (it has the public IP and is the single internet entry point).
- The **EKS worker nodes and pods** — frontend included — live in **private subnets**. They have **no public IP**; they are never directly reachable from the internet.
- Inbound flow: `Internet → ALB (public subnet) → target pods (private subnet)`.
- Outbound (pulling images, calling APIs): private subnet → **NAT Gateway** (which lives in the public subnet) → IGW. NAT is *egress only* — it does **not** let the internet initiate connections in, which is exactly why it's safe.

"Public subnet for the frontend" is the anti-pattern — it needlessly exposes compute. The subnet tags below are how the AWS Load Balancer Controller knows which subnets to use.

```hcl
# Tell the AWS Load Balancer Controller where to place LBs
# Public subnets host the internet-facing ALB:
tags = { "kubernetes.io/role/elb" = "1" }        # public subnets
# Private subnets host nodes/pods and internal LBs:
tags = { "kubernetes.io/role/internal-elb" = "1" } # private subnets
```
```yaml
# Ingress: internet-facing LB in public subnets, pods stay private
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
```

---

## Q7. Multiple AWS accounts have EKS clusters; one cluster must talk to another account's EKS cluster without routing through the internet — what mechanism?
**Asked in:** Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
Started describing his org's business-unit vs workload account network model. After the interviewer simplified the question, answered "VPC endpoints" — but only after the interviewer prompted with "VPC endpoints." Didn't independently offer VPC peering / PrivateLink / Transit Gateway.

**✅ Correct answer:**
Pick based on *what* must talk and *how many*:
- **VPC Peering** — simplest for **two** VPCs in different accounts to route to each other privately (full network reachability between CIDRs). Non-transitive.
- **Transit Gateway** — when **many** accounts/clusters must interconnect; hub-and-spoke, transitive, scales.
- **AWS PrivateLink (interface endpoint + endpoint service)** — when you only need to expose **one specific service/endpoint** (e.g. a single app's NLB) to another account, *not* the whole network. Most locked-down (unidirectional, service-scoped).

For general "cluster A reaches cluster B's services privately," VPC peering (two accounts) or TGW (many) is the right primary answer; PrivateLink if it's a single published service. Plain "VPC endpoints" is only correct in the PrivateLink sense — for AWS services or a specific published endpoint, not arbitrary cluster-to-cluster networking.

```hcl
# Cross-account VPC peering (requester in Account A, accepter in Account B)
resource "aws_vpc_peering_connection" "a_to_b" {
  vpc_id        = aws_vpc.a.id            # requester (Account A)
  peer_vpc_id   = var.account_b_vpc_id
  peer_owner_id = "222222222222"          # Account B
  peer_region   = "us-east-1"
}
# Accepter side (Account B provider):
resource "aws_vpc_peering_connection_accepter" "b" {
  vpc_peering_connection_id = aws_vpc_peering_connection.a_to_b.id
  auto_accept               = true
}
# Then add routes on BOTH sides pointing the peer CIDR at the pcx- connection.
```

---

## Q8. Difference between ALB and NLB, and why prefer ALB for sending traffic?
**Asked in:** Trianz  |  **My performance:** Partial

**My answer (from transcript):**
App deployments (pods) work at layer 7 so use ALB; for networking aspects use NLB. NLB works at OSI layers 3/4; ALB routes requests to the respective backend services which NLB doesn't.

**✅ Correct answer:**
Directionally right, but sharpen it — and note ALB is *not* always preferred:

| | **ALB (Application LB)** | **NLB (Network LB)** |
|---|---|---|
| OSI layer | **7** (HTTP/HTTPS) | **4** (TCP/UDP/TLS) |
| Routing | Content-based: **host, path, header, query** routing | Flow-based, by IP/port only |
| Features | WAF integration, TLS termination, redirects, sticky sessions, gRPC | Ultra-low latency, millions of req/s, **static/Elastic IP**, preserves client source IP |
| IP | Dynamic (DNS name) | Can have a **static IP per AZ** |

**Prefer ALB when** you need L7 features — path/host routing, WAF, TLS, HTTP-aware health checks (typical web/microservice ingress). **Prefer NLB when** you need extreme performance/low latency, non-HTTP protocols (TCP/UDP), a **static IP**, or source-IP preservation. So "always prefer ALB" is wrong as a blanket statement — it's workload-dependent. (Also: use IngressClass/annotations in EKS to choose.)

```yaml
# ALB via Ingress (L7 path routing)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - http:
      paths:
      - path: /api
        pathType: Prefix
        backend: { service: { name: api-svc, port: { number: 80 } } }
---
# NLB via Service (L4, static/low-latency)
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec: { type: LoadBalancer }
```

---

## Q9. An EC2 gets a default hostname like `ip-x.ec2.internal`. I want my own domain (e.g. `trianz.com`) automatically on every instance at launch. How?
**Asked in:** Trianz-K8s  |  **My performance:** Partial

**My answer (from transcript):**
First read it as changing the OS domain at the instance level with root access. When told it must be automatic at launch, suggested building a Packer AMI baking in the customized DNS so every EC2 gets the constant domain — "but the Packer process I need to figure out." (Missed the intended DHCP option sets.)

**✅ Correct answer:**
The intended answer is a **DHCP Option Set** on the VPC. DHCP option sets control the `domain-name` and `domain-name-servers` handed to every instance at launch via DHCP — so you set `domain-name = trianz.com` once on the VPC and **every** instance launched into it automatically gets that domain suffix in its hostname/resolv.conf. No per-instance scripting, no baked AMI needed.

(Packer would work to hardcode a hostname but it's the wrong tool — it's static, per-image, and doesn't scale/stay consistent the way a VPC-level DHCP option set does. Also relevant: Route 53 Private Hosted Zones for actual DNS *records*, but the launch-time domain suffix is the DHCP option set.)

```hcl
resource "aws_vpc_dhcp_options" "custom" {
  domain_name         = "trianz.com"
  domain_name_servers = ["AmazonProvidedDNS"]
}
resource "aws_vpc_dhcp_options_association" "assoc" {
  vpc_id          = aws_vpc.main.id
  dhcp_options_id = aws_vpc_dhcp_options.custom.id
}
# Every EC2 launched in this VPC now gets hostnames under trianz.com automatically.
```

---

## Q10. VPC exists and app is deployed but the running app is not accessible from outside (public URL). What do you check?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Check security groups and if needed NACLs. NACLs give ingress/egress rules at the subnet level; security groups at the instance level (fine-grained). Also check route table creation, route-table-to-subnet associations, and security groups with proper ports/protocols.

**✅ Correct answer:**
Solid answer. The full checklist, roughly in path order:
1. **Internet Gateway** attached to the VPC.
2. **Route table** for the public subnet has `0.0.0.0/0 → igw-…`, and is **associated** with that subnet.
3. **Security group** (stateful, instance/ENI level) allows **inbound** on the app port (e.g. 80/443) from the source.
4. **NACL** (stateless, subnet level) allows both the inbound port **and** the ephemeral return ports (1024-65535) outbound — a common gotcha since NACLs, unlike SGs, don't auto-allow return traffic.
5. **Public IP / Elastic IP** actually assigned; the LB is **internet-facing** not internal.
6. App is **listening** on the port/interface, and target/health checks are passing.

Key distinction he nailed: **SG = stateful, instance level; NACL = stateless, subnet level.**

```bash
# Quick triage from the CLI
aws ec2 describe-security-groups --group-ids sg-123 \
  --query "SecurityGroups[].IpPermissions"
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-abc \
  --query "RouteTables[].Routes"
aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=subnet-abc \
  --query "NetworkAcls[].Entries"
```

---

## Q11. Where do you put your Internet Gateway — which subnet?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Internet gateway is attached to the VPC directly (receives requests from external network); NAT gateway goes in the public subnet to route requests from private subnets to the external world. (Slightly muddled wording but core concept correct.)

**✅ Correct answer:**
Precise version: An **Internet Gateway is not "in" a subnet at all** — it's a horizontally-scaled, VPC-level component **attached to the VPC**. A subnet becomes "public" purely because its **route table** has a route `0.0.0.0/0 → igw-…`. The **NAT Gateway**, by contrast, *does* live **in a public subnet** (with an Elastic IP) and gives **private** subnets outbound-only internet access (`0.0.0.0/0 → nat-…` in the private route table). So:
- IGW → attached to VPC; enables bidirectional internet for subnets whose route table points at it.
- NAT GW → sits in a public subnet; enables egress-only internet for private subnets.

```hcl
resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id }  # attached to VPC

resource "aws_nat_gateway" "nat" {                                  # lives in a PUBLIC subnet
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}
resource "aws_route" "private_egress" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}
```

---

## Q12. What is a VPC and how does it work?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
VPC is Virtual Private Cloud, responsible for all networking of AWS services. Any service (RDS, EC2, ECS) needs a way to communicate internally or externally. VPC contains subnets, internet gateways, NAT gateways, subnet associations, elastic IPs, etc.

**✅ Correct answer:**
A **VPC** is a logically isolated, software-defined network you own within an AWS region, defined by a **CIDR block** (e.g. `10.0.0.0/16`). Inside it you carve **subnets** (each pinned to one **AZ**), and control traffic with:
- **Route tables** (where traffic goes), **Internet Gateway** (public in/out), **NAT Gateway** (private egress),
- **Security Groups** (stateful, instance level) and **NACLs** (stateless, subnet level),
- **VPC endpoints** (private AWS-service access), **peering / TGW** (VPC-to-VPC), **Elastic IPs / ENIs**.

It spans **multiple AZs** in one region (a subnet does not span AZs). Everything else — EC2, RDS, EKS nodes, Lambda-in-VPC — runs *inside* subnets and inherits this networking. His answer captured the essence.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "main-vpc" }
}
resource "aws_subnet" "public"  { vpc_id = aws_vpc.main.id  cidr_block = "10.0.1.0/24"  availability_zone = "us-east-1a"  map_public_ip_on_launch = true }
resource "aws_subnet" "private" { vpc_id = aws_vpc.main.id  cidr_block = "10.0.11.0/24" availability_zone = "us-east-1a" }
```

---

## Q13. How do you design a highly available architecture for a 3-tier application?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
Start with multi-AZ (min two). Three subnets: public subnet with IGW and jump/SSH servers; first private subnet talks out via NAT; a bottom private subnet with no NAT/internet for databases/Lambda. Configure route tables accordingly.

**✅ Correct answer:**
Strong answer. Fleshed out as the standard **multi-AZ 3-tier**:
- **Across ≥2 AZs**, replicate every tier's subnets so one AZ failure doesn't take the app down.
- **Web/public tier:** public subnets holding the **internet-facing ALB** (and optionally a bastion). This is the only internet-exposed layer.
- **App tier:** private subnets with the app servers / EKS nodes; outbound via **NAT Gateway** (one per AZ for HA). Fronted by an *internal* ALB from the web tier.
- **Data tier:** isolated private subnets, **no NAT/IGW**, for **RDS Multi-AZ** (or Aurora), caches, etc. Only the app tier's SG can reach the DB SG.
- **HA glue:** Auto Scaling Groups / EKS across AZs, RDS Multi-AZ standby, Route 53 health checks; optionally multi-region for DR.

```hcl
# App tier auto-scaling across AZs + Multi-AZ RDS = HA
resource "aws_db_instance" "app" {
  engine               = "postgres"
  instance_class       = "db.r6g.large"
  multi_az             = true                       # standby in another AZ
  db_subnet_group_name = aws_db_subnet_group.data.name   # isolated data subnets
}
resource "aws_autoscaling_group" "app" {
  min_size            = 2
  max_size            = 6
  vpc_zone_identifier = aws_subnet.app_private[*].id      # spread over AZs
}
```

---

## Compute — EC2 / ECS / EKS / Fargate

## Q14. What is the difference between EC2, ECS, EKS, and Fargate?
**Asked in:** GlobalLogic  |  **My performance:** Incorrect

**My answer (from transcript):**
Fargate is serverless. EC2 is part of node groups (a node group has multiple EC2 instances). ECS is Elastic Container Service to deploy and test individual containers. Did not clearly explain EKS; ECS description weak, EKS essentially skipped.

**✅ Correct answer:**
Two axes: **orchestrator** vs **compute (where containers actually run)**.

- **EC2** — raw **virtual machines**. IaaS building block; you manage OS, patching, scaling. Not container-specific, but it's the *compute* other things can run on.
- **ECS (Elastic Container Service)** — AWS's **own** container **orchestrator**. Simpler than Kubernetes, AWS-proprietary. Runs tasks/services.
- **EKS (Elastic Kubernetes Service)** — **managed Kubernetes** orchestrator. AWS runs the control plane; you get standard k8s API (great for portability / existing k8s skills).
- **Fargate** — **serverless compute** *for* ECS **or** EKS. It's not an orchestrator — it's the "where it runs" option where **you don't manage nodes**; AWS provisions right-sized capacity per task/pod.

So the matrix: ECS or EKS = the *orchestrator*; EC2 or Fargate = the *launch type / data plane*. You can run EKS on EC2 node groups **or** on Fargate. Fargate = no node management (pay per pod, cannot use DaemonSets/privileged/GPU); EC2 nodes = full control, cheaper at scale, more ops.

```bash
# EKS on managed EC2 node group
eksctl create nodegroup --cluster prod --name ng-1 \
  --node-type m6i.large --nodes 3 --nodes-min 2 --nodes-max 6

# EKS on Fargate (no nodes to manage) — pods matching this profile run serverless
eksctl create fargateprofile --cluster prod --name fp-app \
  --namespace app --labels compute=fargate
```

---

## Q15. On an EC2 instance there are 3/3 status checks — what are those checks?
**Asked in:** Trianz-K8s  |  **My performance:** Didn't-know

**My answer (from transcript):**
Guessed they are health checks for liveness/readiness. When pressed: "I'm not sure exactly what those 3 checks are." Had not hit a scenario where a check fails and the instance is unreachable.

**✅ Correct answer:**
EC2 **status checks** are automated AWS checks (not app liveness/readiness — that's k8s/ALB). The console shows them as e.g. **3/3 checks passed**:
1. **System status check** — the **underlying AWS host/infrastructure**: physical host, network reachability, power, hypervisor. If it fails, the problem is on AWS's side → the fix is usually **stop/start** (which migrates the instance to a healthy host). You can't fix it from inside.
2. **Instance status check** — the **guest OS / your config**: OS reachable, networking configured, kernel booted, no exhausted memory/corrupt filesystem. Failure is *your* problem → reboot / fix config.
3. **EBS status check** — the **attached EBS volumes'** reachability/health (I/O to the root and attached volumes).

(Older instances showed **2/2**; EBS status is the third, newer one — so both 2/2 and 3/3 come up.) Alarm on these with CloudWatch `StatusCheckFailed_System` / `_Instance` and auto-recover.

```bash
# See the individual checks
aws ec2 describe-instance-status --instance-ids i-0abc123 \
  --query "InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}"

# Auto-recover on SYSTEM check failure (moves to healthy host, keeps IP/EBS)
aws cloudwatch put-metric-alarm --alarm-name recover-i-0abc123 \
  --namespace AWS/EC2 --metric-name StatusCheckFailed_System \
  --statistic Maximum --period 60 --evaluation-periods 2 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=InstanceId,Value=i-0abc123 \
  --alarm-actions arn:aws:automate:us-east-1:ec2:recover
```

---

## Q16. Were you using AWS-provided AMIs for your EKS environment or custom images?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
Custom images built from Packer, used for node groups/EC2s. Patches were infrequent but they did patch (e.g. around New Year).

**✅ Correct answer:**
Good, real-world answer. Common practice: start from the **EKS-optimized AMI** (Amazon Linux 2/2023 or Bottlerocket) as the base and **layer hardening with Packer** — CIS benchmarks, agents (CloudWatch, security/EDR), baked configs — producing an immutable golden AMI per release. Key points to mention: pin the AMI in the launch template, rotate on a cadence (CVE-driven, not just calendar), and roll nodes via **managed node group updates** / new launch template versions so patching is a rolling replace, not in-place. Bottlerocket is worth naming as a minimal, container-optimized alternative that reduces the patch surface.

```hcl
# Packer: build a hardened EKS node AMI from the EKS-optimized base
source "amazon-ebs" "eks_node" {
  source_ami_filter {
    filters = { name = "amazon-eks-node-1.29-v*" }
    owners  = ["602401143452"]   # Amazon EKS AMI account
    most_recent = true
  }
  instance_type = "m6i.large"
  ami_name      = "eks-node-hardened-{{timestamp}}"
}
build {
  sources = ["source.amazon-ebs.eks_node"]
  provisioner "shell" { inline = ["sudo dnf -y update", "sudo bash harden-cis.sh"] }
}
```

---

## Storage

## Q17. Why did you choose the Amazon EBS CSI driver instead of EFS? What made you choose EBS?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
The requirement was one app team bound to a single region with traffic only from that region. StatefulSets mounted EBS (gp3) so on restart the app keeps a stable identity and persistent storage. A later POC proposed multi-AZ expansion; he'd left by then but agrees EFS makes more sense for multi-AZ. At implementation it was single-AZ/single-region, so EBS.

**✅ Correct answer:**
Correct and well-reasoned. The core technical distinction:
- **EBS** = **block** storage, **`ReadWriteOnce`**, **bound to a single AZ**. A pod using an EBS PVC can only be scheduled where that volume lives. Perfect for **StatefulSets** needing low-latency, single-writer persistent disks (databases, per-replica state) — which matches his single-AZ case. gp3 is the right modern default (decoupled IOPS/throughput, cheaper than gp2).
- **EFS** = **NFS file** storage, **`ReadWriteMany`**, **spans all AZs in a region**. Right when **many pods across AZs share the same data**, or when you need pods to reschedule across AZs freely. Higher latency, pay-per-use.

So EBS = single-AZ, single-writer, low latency; EFS = multi-AZ, shared, many writers. His migration instinct (EBS→EFS when going multi-AZ shared) is exactly right.

```yaml
# EBS gp3 StorageClass for single-AZ StatefulSet (RWO)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: ebs-gp3 }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # bind PVC in the AZ the pod lands
parameters: { type: gp3, iops: "3000", throughput: "125", encrypted: "true" }
---
# EFS StorageClass for multi-AZ shared access (RWX)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: efs-sc }
provisioner: efs.csi.aws.com
parameters: { provisioningMode: efs-ap, fileSystemId: fs-0abc123, directoryPerms: "700" }
```

---

## Other Services, HA/DR & Scenarios

## Q18. Have you used CloudFormation?
**Asked in:** Barclays  |  **My performance:** Didn't-know

**My answer (from transcript):**
No.

**✅ Correct answer:**
Honest is fine, but be ready to bridge from what you *do* know (Terraform). **CloudFormation** is AWS's **native IaC** service: you declare resources in a YAML/JSON **template**, deploy it as a **stack**, and CFN handles create/update/rollback and drift detection. Vs Terraform: CFN is AWS-only, state is managed by AWS (no remote-state backend to run), supports **change sets** (preview) and **StackSets** (deploy across accounts/regions). Terraform is multi-cloud, HCL, you manage state. Concepts map 1:1, so "I've used Terraform heavily; CloudFormation is the AWS-native equivalent and I can pick it up quickly" is a strong reframe.

```yaml
# Minimal CloudFormation template (an S3 bucket)
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  MyBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: akshay-cfn-demo
      VersioningConfiguration: { Status: Enabled }
Outputs:
  BucketArn: { Value: !GetAtt MyBucket.Arn }
# Deploy:  aws cloudformation deploy --template-file tpl.yaml --stack-name demo
```

---

## Q19. Have you done MySQL administration?
**Asked in:** Compunnel  |  **My performance:** Didn't-know

**My answer (from transcript):**
Integrated Kubernetes apps with MySQL, but has not done MySQL administration.

**✅ Correct answer:**
Fair to be honest, but frame it toward the **AWS-managed** angle you *do* touch: on AWS you rarely do raw DBA work — you use **RDS for MySQL** (or **Aurora MySQL**), where AWS handles patching, backups, failover, and replication. Admin tasks become: **parameter groups** (my.cnf tuning), **Multi-AZ** for HA, **read replicas** for scale, automated **snapshots/PITR**, and monitoring via **Performance Insights / CloudWatch**. Access/creds via **Secrets Manager** with rotation. That reframes "MySQL admin" into the managed-cloud operations you actually own.

```bash
# Managed MySQL on RDS: Multi-AZ + automated backups + a read replica
aws rds create-db-instance --db-instance-identifier app-mysql \
  --engine mysql --db-instance-class db.r6g.large --multi-az \
  --allocated-storage 100 --backup-retention-period 7 \
  --master-username admin --manage-master-user-password   # stored in Secrets Manager

aws rds create-db-instance-read-replica \
  --db-instance-identifier app-mysql-ro --source-db-instance-identifier app-mysql
```

---

## Q20. Deploy a dynamic UI web app on EKS that must reach the outside world — walk through the full architecture and AWS services (you manage DNS in AWS).
**Asked in:** Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
Piece by piece with heavy prompting: UI microservice has deployment + service + ingress; mentioned WAF for web security; traffic via DNS. Missed CloudFront/CDN. Eventually assembled Route 53 → WAF → ALB (ingress) → path-based routing → backend ClusterIP → pod. Needed the interviewer to supply the WAF-attachment and Route 53 pieces.

**✅ Correct answer:**
Full internet-to-pod path, front to back:
1. **Route 53** — hosted zone; an **Alias A record** for the app domain pointing at CloudFront (or the ALB).
2. **CloudFront (CDN)** — caches static assets at edge, terminates TLS with an **ACM cert**, lowers latency. *(The piece he missed.)*
3. **AWS WAF** — attached to CloudFront (or the ALB) to filter malicious traffic (SQLi/XSS/rate-limit) before it reaches the app.
4. **Internet-facing ALB** — provisioned by the **AWS Load Balancer Controller** from a k8s **Ingress**; sits in **public subnets**; does host/path routing.
5. **Ingress → Service (ClusterIP) → Pods** — pods and nodes in **private subnets**; `target-type: ip` registers pod IPs directly.
6. **Egress** for the pods (image pulls, API calls) via **NAT Gateway → IGW**.
Flow: `User → Route 53 → CloudFront (+WAF, +ACM) → ALB (public subnet) → Ingress → ClusterIP Service → Pod (private subnet)`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ui
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111111111111:certificate/abc
    alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:us-east-1:111111111111:regional/webacl/ui/xyz
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
spec:
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: { service: { name: ui-svc, port: { number: 80 } } }
# Then: Route 53 Alias app.example.com -> CloudFront; CloudFront origin -> the ALB; WAF on CloudFront too.
```

---

## Q21. How do you design for reliability / high availability in the cloud?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
Two options for HA: deploy across multiple AZs in the same region, or across multiple regions, and scale accordingly. For security: AWS WAF in front of the VPC, Route 53 for routing, and a CDN in front of Route 53 for faster retrieval — scalable, reliable, secure.

**✅ Correct answer:**
Good instincts; tighten the layering:
- **Redundancy:** multi-AZ first (cheap, low-latency HA within a region); multi-region only for regional-failure DR or global latency. **No single points of failure** — ≥2 of everything.
- **Elasticity:** Auto Scaling Groups / EKS HPA + Cluster Autoscaler so capacity tracks demand; health-check-based replacement of bad instances.
- **Load distribution:** ALB/NLB across AZs; **Route 53** health checks + latency/failover routing across regions.
- **Data:** RDS **Multi-AZ** standby + cross-region read replicas / snapshots; S3 (11 nines) with cross-region replication.
- **Edge/security:** **CloudFront** (CDN) + **WAF** + **Shield** at the edge; note WAF attaches to CloudFront/ALB/API GW, not "the VPC."
- Frame it with the **Well-Architected Reliability pillar**: recover automatically, test recovery, scale horizontally, stop guessing capacity.

```hcl
# Route 53 failover across regions with health checks
resource "aws_route53_health_check" "primary" {
  fqdn = "app-primary.example.com"  type = "HTTPS"  port = 443
  resource_path = "/healthz"  failure_threshold = 3  request_interval = 30
}
resource "aws_route53_record" "app" {
  zone_id = var.zone_id  name = "app.example.com"  type = "A"
  set_identifier  = "primary"
  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.primary.id
  alias { name = aws_lb.primary.dns_name  zone_id = aws_lb.primary.zone_id  evaluate_target_health = true }
}
```

---

## Q22. What about backup / disaster recovery?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
For DR, deploy across multiple regions so if one region goes down, traffic switches to the second region and the app stays up, meeting SLAs.

**✅ Correct answer:**
Right direction; the interview-grade version names the **DR strategies by RTO/RPO/cost** trade-off:
1. **Backup & Restore** — cheapest, slowest. Cross-region snapshots/backups (via **AWS Backup**); restore on disaster. RTO/RPO hours.
2. **Pilot Light** — core (DB replicated cross-region) always on, rest scaled to zero; scale up on failover. RTO minutes-hours.
3. **Warm Standby** — a smaller full stack always running in the DR region; scale up on failover. RTO minutes.
4. **Multi-site Active/Active** — full capacity both regions, Route 53 splitting traffic. Near-zero RTO/RPO, highest cost. *(His answer describes this tier.)*

Define **RPO** (data-loss tolerance) and **RTO** (downtime tolerance) first, then pick the cheapest strategy that meets them. Mention **AWS Backup** for centralized, cross-region, cross-account backup policies, and **regularly testing** the failover.

```bash
# Centralized cross-region DR backups via AWS Backup
aws backup put-backup-plan --backup-plan '{
  "BackupPlanName": "dr-plan",
  "Rules": [{
    "RuleName": "daily-cross-region",
    "TargetBackupVaultName": "Default",
    "ScheduleExpression": "cron(0 5 * * ? *)",
    "Lifecycle": { "DeleteAfterDays": 30 },
    "CopyActions": [{
      "DestinationBackupVaultArn": "arn:aws:backup:us-west-2:111111111111:backup-vault:dr-vault"
    }]
  }]
}'
```

---

## Q23. What image scanner did you use? How is Veracode different from Trivy?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
Used Veracode for image scanning. On how it differs from Trivy — had not heard of Trivy; they were focused on their own toolset.

**✅ Correct answer:**
Fine to admit unfamiliarity with a specific tool, but the concepts:
- **Trivy** (Aqua, open-source) — fast, free scanner for **container images, filesystems, IaC, and git repos**; detects OS/library **CVEs**, misconfigs, and secrets. Trivially dropped into CI (`trivy image myimg`); very common in the k8s ecosystem.
- **Veracode** — commercial **application security** platform focused on **SAST/DAST/SCA** for application code and dependencies, with compliance reporting and policy gates; heavier, enterprise governance oriented.

Overlap is **SCA / dependency CVEs**; the distinction is Trivy = lightweight, container/infra-centric, OSS in the pipeline; Veracode = enterprise AppSec suite (code-level SAST/DAST + compliance). Naming Trivy, Grype, or ECR's built-in scanning (Clair/Inspector) shows breadth.

```bash
# Trivy: fail the CI build on HIGH/CRITICAL image vulnerabilities
trivy image --severity HIGH,CRITICAL --exit-code 1 myrepo/app:1.4.2

# Or use AWS-native ECR scan-on-push (Amazon Inspector)
aws ecr put-image-scanning-configuration \
  --repository-name app --image-scanning-configuration scanOnPush=true
```

---

## Q24. Which cloud — AWS, Azure, or GCP? Any Azure/GCP experience?
**Asked in:** Pure-SW, Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
Primarily AWS. Short GCP stint long ago (a POC, not a full project). AZ-400 Azure DevOps certified in 2022 but all projects on AWS, so no full Azure project work. Rates Azure 2-3/5.

**✅ Correct answer:**
This is a background question — honesty is the right call; just deliver it with confidence and a mapping mindset. Lead with depth (AWS, primary, years of production EKS/VPC/IaC), acknowledge Azure (AZ-400 certified — shows you understand Azure DevOps pipelines, and core concepts transfer), and be ready to **map services across clouds** to show conceptual (not vendor-locked) understanding:

| Concept | AWS | Azure | GCP |
|---|---|---|---|
| Managed K8s | EKS | AKS | GKE |
| VMs | EC2 | Virtual Machines | Compute Engine |
| Object storage | S3 | Blob Storage | Cloud Storage |
| IAM | IAM + STS | Entra ID / RBAC | Cloud IAM |
| Serverless fn | Lambda | Azure Functions | Cloud Functions |
| IaC native | CloudFormation | ARM/Bicep | Deployment Manager |

Framing: "Deep on AWS, conversant in Azure via AZ-400; the primitives map, so I ramp on a second cloud fast." No snippet needed — this is a fit question.

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

Twelve-plus advanced AWS questions targeting his weak spots — networking, IAM/STS/OIDC, EKS, KMS, multi-account, cost, DR. All answers to be rehearsed.

## Q25. Explain EKS IRSA (IAM Roles for Service Accounts) end-to-end — how does a pod get AWS permissions without node IAM or static keys?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
IRSA lets a **Kubernetes ServiceAccount** map to an **IAM role** so pods get scoped, temporary AWS creds — no node instance-profile sharing, no static keys.
1. The EKS cluster exposes an **OIDC provider** URL; you register it as an **IAM OIDC identity provider**.
2. You create an IAM role whose **trust policy** federates that OIDC provider and conditions on a specific `namespace:serviceaccount` (`sub` claim).
3. You annotate the k8s ServiceAccount with `eks.amazonaws.com/role-arn`.
4. A mutating webhook injects a **projected token** + env vars; the AWS SDK calls **STS `AssumeRoleWithWebIdentity`** with that token → gets temp creds for the role.
Each pod thus gets **least-privilege**, per-workload credentials. (IRSA's successor, **EKS Pod Identity**, removes the OIDC/trust-policy plumbing via an add-on + association — worth naming.)

```json
// IAM role trust policy for IRSA (note the OIDC sub condition)
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::111111111111:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539:sub": "system:serviceaccount:app:s3-reader",
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539:aud": "sts.amazonaws.com"
    }}
  }]
}
```

---

## Q26. Design a multi-account AWS org landing zone. How do you structure accounts, and how do SCPs, centralized networking, and logging fit?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Use **AWS Organizations** with **OUs** (Security, Infrastructure/Network, Workloads-Prod, Workloads-NonProd, Sandbox). Provision via **Control Tower** / landing zone.
- **SCPs (Service Control Policies)** — org-level guardrails that set the *maximum* permissions any account/role can have (e.g. deny leaving the org, deny disabling CloudTrail, restrict regions). They don't *grant*, only *bound*.
- **Centralized networking** — a **Network account** owns a **Transit Gateway** shared via **RAM**; spokes attach for inter-VPC and centralized egress/inspection.
- **Centralized logging/security** — a **Log Archive** account aggregates CloudTrail/Config/VPC Flow Logs to S3; a **Security/Audit** account runs GuardDuty/Security Hub delegated-admin.
- **Access** — **IAM Identity Center (SSO)** with permission sets; humans assume roles, no per-account users.

```json
// SCP: deny anything outside approved regions + block disabling CloudTrail
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "RegionLock", "Effect": "Deny", "NotAction": ["iam:*","sts:*","cloudfront:*","route53:*"],
      "Resource": "*", "Condition": { "StringNotEquals": { "aws:RequestedRegion": ["us-east-1","us-west-2"] } } },
    { "Sid": "ProtectTrail", "Effect": "Deny",
      "Action": ["cloudtrail:StopLogging","cloudtrail:DeleteTrail"], "Resource": "*" }
  ]
}
```

---

## Q27. When do you use VPC Peering vs Transit Gateway vs PrivateLink? Give the decision criteria.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
- **VPC Peering** — full-network reachability between **two** VPCs, non-transitive, no bandwidth cap, cheapest. Use for a small, static number of VPCs that need broad L3 connectivity.
- **Transit Gateway** — **many** VPCs/accounts + hybrid (VPN/DX), transitive hub, centralized routing/egress/inspection. Use at org scale. Costs per attachment + per GB.
- **PrivateLink (interface endpoint + endpoint service)** — expose **one specific service** (behind an NLB) to consumers **without** joining networks; unidirectional, no CIDR overlap concerns, most locked-down. Use for SaaS-style service exposure or cross-account single-service access.
Decision: *whole networks, few* → peering; *whole networks, many* → TGW; *one service, not the network* → PrivateLink. Also: overlapping CIDRs rule out peering/TGW → PrivateLink.

```hcl
# PrivateLink: provider publishes an endpoint service fronted by an NLB
resource "aws_vpc_endpoint_service" "svc" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.app_nlb.arn]
  allowed_principals         = ["arn:aws:iam::222222222222:root"]  # consumer account
}
# Consumer creates an interface endpoint to that service name to reach it privately.
```

---

## Q28. Walk through an IAM policy's structure. Explain the evaluation logic (identity vs resource vs SCP vs permission boundary) and Deny precedence.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A policy statement has: **Effect** (Allow/Deny), **Action** (API calls), **Resource** (ARNs), optionally **Principal** (who — required in *resource*-based/trust policies, absent in identity policies), and **Condition** (keys like `aws:SourceIp`, `aws:PrincipalTag`). Evaluation:
1. **Explicit Deny** anywhere → **denied**, always wins.
2. Otherwise there must be an **explicit Allow**; default is implicit deny.
3. The request must pass **all** applicable policy types: **SCP** (org ceiling), **Permission boundary** (max for the identity), **identity policy**, and **resource policy**. For cross-account, you need an Allow on **both** the identity side *and* the resource side.
Mnemonic: **Deny > Allow > implicit deny**, and every boundary must permit it.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllowReadOneBucket", "Effect": "Allow",
      "Action": ["s3:GetObject","s3:ListBucket"],
      "Resource": ["arn:aws:s3:::akshay-data","arn:aws:s3:::akshay-data/*"] },
    { "Sid": "DenyUnlessTLS", "Effect": "Deny", "Action": "s3:*",
      "Resource": "arn:aws:s3:::akshay-data/*",
      "Condition": { "Bool": { "aws:SecureTransport": "false" } } }
  ]
}
```

---

## Q29. Design KMS encryption for a multi-account platform. Explain envelope encryption, key policies vs grants, and cross-account key use.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**KMS** manages **CMKs (KMS keys)**. Data is protected with **envelope encryption**: KMS generates a **data key**, the data key encrypts your data, and KMS encrypts the data key with the CMK; you store the encrypted data key alongside the ciphertext. Only small blobs go to KMS directly.
- **Key policy** — the *root* of trust on the key; a resource policy that says which principals/accounts can use/administer it (unlike other services, IAM alone isn't enough — the key policy must allow it).
- **Grants** — temporary, programmatic, fine-grained delegations (used by services like EBS/RDS) that can be revoked.
- **Cross-account** — the key policy allows the other account's principal, *and* that principal's IAM policy allows `kms:*` on the key ARN.
Prefer **customer-managed keys** (rotation, policy control, auditability) over AWS-managed for regulated data; enable **automatic annual rotation**.

```hcl
resource "aws_kms_key" "app" {
  description             = "app data key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "RootAdmin", Effect = "Allow",
        Principal = { AWS = "arn:aws:iam::111111111111:root" }, Action = "kms:*", Resource = "*" },
      { Sid = "CrossAcctUse", Effect = "Allow",
        Principal = { AWS = "arn:aws:iam::222222222222:role/app" },
        Action = ["kms:Decrypt","kms:GenerateDataKey"], Resource = "*" }
    ]
  })
}
```

---

## Q30. How do you architect and secure EKS pod networking — VPC CNI, IP exhaustion, network policies, and private clusters?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
EKS uses the **AWS VPC CNI**: each pod gets a **real VPC IP** from an ENI on the node — great for native routing/SG-per-pod, but pods consume subnet IPs, so **IP exhaustion** is the classic pitfall. Mitigations: large/secondary CIDRs (`100.64.0.0/10` custom networking), **prefix delegation** (assign /28 prefixes per ENI to raise pod density), right-size subnets. Security:
- **Network Policies** (Calico or the newer VPC CNI native policy) for L3/L4 pod-to-pod segmentation — default-deny then allow.
- **Security groups for pods** for AWS-resource-level control.
- **Private cluster**: private API endpoint, nodes in private subnets, VPC endpoints for ECR/STS/S3/EKS so no internet needed.
- **IRSA/Pod Identity** for AWS creds (see Q25).

```bash
# Raise pod density with prefix delegation (avoids IP exhaustion)
kubectl set env ds aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
```
```yaml
# Default-deny ingress, then allow only from app namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: app }
spec: { podSelector: {}, policyTypes: [Ingress] }
```

---

## Q31. Explain the different DR strategies with their RTO/RPO and cost trade-offs, and how you'd implement a warm-standby for a stateful app.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Four tiers (cheap/slow → costly/fast): **Backup & Restore** (RPO/RTO hours), **Pilot Light** (core replicated, rest off; RTO ~10s of min), **Warm Standby** (scaled-down full stack running; RTO minutes), **Active/Active** (full both regions; near-zero). Choose by **RPO** (data loss) and **RTO** (downtime) targets vs cost.
**Warm standby for a stateful app:** cross-region **Aurora Global Database** (or RDS cross-region read replica) keeps data within ~1s; run a minimal app/EKS footprint in the DR region; **Route 53 failover** health-checks flip DNS; on failover, **promote** the replica and scale the app up. Test with regular game-days.

```bash
# Aurora Global Database: sub-second cross-region replication for warm standby
aws rds create-global-cluster --global-cluster-identifier app-global --engine aurora-postgresql
aws rds create-db-cluster --db-cluster-identifier app-dr \
  --engine aurora-postgresql --global-cluster-identifier app-global --region us-west-2
# On disaster: aws rds failover-global-cluster --global-cluster-identifier app-global \
#   --target-db-cluster-identifier arn:...:cluster:app-dr
```

---

## Q32. How do you control and optimize AWS cost for a large EKS + EC2 workload?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Layered levers:
- **Right-sizing** — Compute Optimizer / metrics to fix over-provisioned instances and requests/limits.
- **Purchasing** — **Savings Plans** / Reserved Instances for steady baseline; **Spot** for fault-tolerant/batch and EKS nodes (via **Karpenter** consolidating to cheapest capacity).
- **Autoscaling** — **Karpenter**/Cluster Autoscaler + HPA so you pay for what you use; **bin-pack** and consolidate.
- **Storage** — gp3 over gp2, S3 lifecycle to IA/Glacier, delete unattached EBS/EIPs, snapshot cleanup.
- **Visibility** — **Cost Explorer**, budgets/alerts, **cost allocation tags**, Kubecost for per-namespace showback.
- **Data transfer** — VPC endpoints and same-AZ traffic to cut NAT/cross-AZ egress charges.

```yaml
# Karpenter NodePool preferring Spot + consolidation for cost efficiency
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: default }
spec:
  template:
    spec:
      requirements:
      - { key: karpenter.sh/capacity-type, operator: In, values: ["spot","on-demand"] }
  disruption: { consolidationPolicy: WhenEmptyOrUnderutilized }
```

---

## Q33. What is a VPC endpoint policy, and how does it differ from an S3 bucket policy for locking down access?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
- A **VPC endpoint policy** is a resource policy **on the endpoint** — it scopes which AWS API actions/resources can be reached *through that endpoint*. It's the network-side control (e.g. "this S3 gateway endpoint may only reach these buckets").
- An **S3 bucket policy** is on the **bucket** — it can restrict access to a **specific VPC or endpoint** via `aws:sourceVpce` / `aws:sourceVpc` conditions ("this bucket only accepts requests coming from our VPC endpoint").
Together they form **data-perimeter** controls: the endpoint policy limits what the network path can touch; the bucket policy refuses anything not arriving via the sanctioned endpoint — blocking data exfiltration to arbitrary buckets and access from outside the VPC.

```json
// Bucket policy: only allow access via our VPC endpoint
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Deny", "Principal": "*", "Action": "s3:*",
    "Resource": ["arn:aws:s3:::akshay-data","arn:aws:s3:::akshay-data/*"],
    "Condition": { "StringNotEquals": { "aws:sourceVpce": "vpce-0abc123" } }
  }]
}
```

---

## Q34. How does the AWS Load Balancer Controller work in EKS, and what's the difference between `instance` and `ip` target modes?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
The **AWS Load Balancer Controller** watches k8s **Ingress** (→ provisions **ALB**) and **Service type LoadBalancer** (→ provisions **NLB**) resources and reconciles the real AWS LBs, target groups, listeners, and security groups. It needs an **IRSA** role and **subnet tags** to know where to place LBs.
- **`instance` target mode** — registers **node IPs + NodePort**; traffic hits a node then kube-proxy hops to the pod (extra hop, needs NodePort, works with `externalTrafficPolicy`).
- **`ip` target mode** — registers **pod IPs directly** (requires VPC CNI); no NodePort hop, preserves client IP better, works with Fargate. Generally preferred for EKS.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip   # register pod IPs
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec: { type: LoadBalancer, selector: { app: app }, ports: [{ port: 80, targetPort: 8080 }] }
```

---

## Q35. Design centralized network inspection/egress for an organization (firewall, GuardDuty, flow logs). How does traffic flow?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Hub-and-spoke on **Transit Gateway** with a dedicated **inspection VPC**:
1. Spoke VPCs have default route → **TGW**.
2. TGW route tables steer inter-VPC and internet-bound traffic **into an inspection VPC** running **AWS Network Firewall** (or 3rd-party appliances) for IPS/domain filtering.
3. Inspected internet traffic exits via that VPC's **NAT → IGW** (centralized egress).
4. **VPC Flow Logs** → central S3/CloudWatch; **GuardDuty** (delegated admin in the Security account) analyzes DNS/flow/CloudTrail for threats; **Security Hub** aggregates findings.
This gives one inspection/egress choke point, consistent policy, and central logging.

```hcl
resource "aws_networkfirewall_firewall" "inspect" {
  name                = "org-inspection"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.p.arn
  vpc_id              = aws_vpc.inspection.id
  dynamic "subnet_mapping" {
    for_each = aws_subnet.firewall[*].id
    content { subnet_id = subnet_mapping.value }
  }
}
# TGW appliance-mode attachment keeps flow symmetry through the firewall.
```

---

## Q36. Explain S3 security in depth: block public access, bucket policy vs ACL, encryption options (SSE-S3/SSE-KMS/DSSE), and cross-account access.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
- **Block Public Access** — account/bucket-level master switch; keep **on** unless intentionally serving public content. Overrides permissive policies/ACLs.
- **Bucket policy vs ACL** — use **bucket policies** (and IAM) for access; **ACLs are legacy** — disable them via **Object Ownership = Bucket owner enforced** so the bucket owner owns all objects.
- **Encryption** — **SSE-S3** (AES-256, AWS-managed, default), **SSE-KMS** (customer-managed CMK, audit + rotation + key policy control), **DSSE-KMS** (dual-layer for strict compliance). Enforce with a policy denying uploads without the right `x-amz-server-side-encryption`.
- **Cross-account** — grant via bucket policy naming the other account principal + KMS key policy allowing that principal (for SSE-KMS objects). Prefer roles + `aws:PrincipalOrgID` conditions.
- Add **TLS-only** (`aws:SecureTransport`) and **VPC endpoint** conditions for a tight perimeter.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyUnencryptedUploads", "Effect": "Deny", "Principal": "*",
    "Action": "s3:PutObject", "Resource": "arn:aws:s3:::akshay-data/*",
    "Condition": { "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" } }
  }]
}
```

---

## Q37. How do you securely give CI/CD (e.g. GitHub Actions) access to AWS without long-lived keys?
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Use **OIDC federation** — the same STS `AssumeRoleWithWebIdentity` pattern as IRSA, but the identity provider is **GitHub's OIDC** (`token.actions.githubusercontent.com`).
1. Register GitHub's OIDC provider in IAM.
2. Create a role whose **trust policy** federates that provider and conditions on `sub` = your specific repo/branch/environment (so only *your* workflow can assume it).
3. The workflow requests an OIDC token and calls AssumeRole → short-lived creds. **No static `AWS_ACCESS_KEY_ID` secrets** to leak or rotate.
Scope the role tightly and condition on branch/environment to prevent fork/PR abuse.

```json
// Trust policy: only main branch of one repo may assume this role
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:akshay/app:ref:refs/heads/main" }
    }
  }]
}
```

---

## Q38. An EC2 instance can't reach the internet from a private subnet even though a NAT Gateway exists. Troubleshoot it methodically.
**Asked in:** —  |  **My performance:** *(Not asked — study & rehearse)*

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Walk the path outbound:
1. **NAT placement** — NAT GW must be in a **public** subnet (route to IGW) with an **Elastic IP**; a NAT in a private subnet can't work.
2. **Private route table** — has `0.0.0.0/0 → nat-…` and is **associated with the instance's subnet**.
3. **Public subnet route** — the NAT's subnet has `0.0.0.0/0 → igw-…` and the IGW is attached to the VPC.
4. **Security group** — allows **outbound** (default allows all egress; check if it was locked down).
5. **NACLs** — subnet NACL allows outbound to `0.0.0.0/0` **and** inbound ephemeral ports (1024-65535) for return traffic (stateless gotcha).
6. **DNS** — `enableDnsSupport`/`enableDnsHostnames` if resolving names.
7. For **AWS services** specifically, a VPC endpoint may be the better path than NAT.

```bash
aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=vpc-abc \
  --query "NatGateways[].{State:State,Subnet:SubnetId,EIP:NatGatewayAddresses[0].PublicIp}"
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=subnet-private \
  --query "RouteTables[].Routes"   # expect 0.0.0.0/0 -> nat-...
```

---

Reference answers reflect AWS behavior as of 2026. Practice the ✅ answers and the 🔺 set aloud, especially the networking, IAM/STS, and EC2-status-check items where the transcripts showed gaps.
