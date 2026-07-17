# Networking — Interview Q&A (General + Cloud/K8s Networking)

Real questions from Akshay's past interviews (HDFC, Compunnel, Persistent), rebuilt with faithful transcripts and authoritative answers.
Networking — especially **AWS VPC networking** — is a flagged weak area, so the correct answers below go deep on the exact traps that came up.

---

## Q1. Customer can't log in — give a 5-step technical approach to check whether the request actually landed on your application (Kubernetes environment).
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Check DNS is configured; check ingress resources via `kubectl get ingress` in the namespace; verify the ingress controller is working; check the load balancer is receiving requests; log into the console to check LB status and health.

**✅ Correct answer:**
The right mental model is to **trace the request top-down along the path it travels** and prove where it stops. The path is:
`Client → DNS → Load Balancer → Ingress Controller → Service → Pod → Container/App`.

A clean 5-step answer:
1. **DNS resolution** — does the app hostname resolve to the correct LB address? `nslookup app.company.com` / `dig`. If DNS is stale/wrong, the request never leaves the client.
2. **Load balancer** — is the LB healthy and are its target group / health checks passing? (AWS console or CLI). An unhealthy target group means the LB has nowhere to send traffic → 503.
3. **Ingress + Ingress controller** — `kubectl get ingress -n <ns>`, confirm host/path rules and that the controller (nginx/ALB controller) pods are Running and reconciling. Check controller logs for the specific hostname.
4. **Service → Endpoints** — `kubectl get svc,endpoints -n <ns>`. If **Endpoints is empty**, the Service selector doesn't match any Pod labels → traffic dies here. This is the single most common "request never lands" cause.
5. **Pod / application** — `kubectl get pods`, `kubectl logs`, `kubectl describe`. Confirm pods are Ready, readiness probes pass, and the app logs show (or don't show) the request arriving. If you see the request in app logs, it landed; the failure is app-side (auth).

The key insight the interviewer wanted: **each hop can be independently confirmed**, and an empty `Endpoints` list is the classic silent break between Service and Pods.

```bash
# Trace the request path, hop by hop
dig +short app.company.com                      # 1. DNS -> LB address
aws elbv2 describe-target-health \              # 2. LB target health
  --target-group-arn <arn> --query 'TargetHealthDescriptions[].TargetHealth.State'
kubectl get ingress -n app                      # 3. Ingress rules present?
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep app.company.com
kubectl get svc,endpoints -n app                # 4. Endpoints NON-EMPTY? (selector match)
kubectl get pods -n app -o wide                 # 5. Pods Ready?
kubectl logs -n app deploy/app | tail           #    Did the request actually arrive?
```

---

## Q2. How do you validate the load balancer is actually receiving/handling the request? And for a single customer request, what more can the LB tell you?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Logged into the console to check LB status and health groups. Beyond that: check labels/selectors matching between service and deployment (mismatch = traffic won't reach pods), check network policies (default-deny if enabled), and check whether security-group rules on worker nodes changed.

**✅ Correct answer:**
The label/selector, NetworkPolicy and security-group points are all correct and good — but the interviewer specifically asked **what the LB itself can tell you about one request**. The answer is **access/request logs and CloudWatch metrics**:

- **Access logs** (ALB logs to S3) give you *per-request* detail: source IP, the target it chose, the **backend response code vs the LB response code**, and processing times split into `request_processing_time`, `target_processing_time`, `response_processing_time`. This alone localizes the fault:
  - LB returns **503** with no target → no healthy targets.
  - LB returns **502** → target returned a malformed/reset response (app crashed mid-response).
  - LB returns **504** → target didn't answer within the idle timeout (slow backend).
- **Target health** — `HealthyHostCount` / `UnHealthyHostCount` metrics and target-group health state.
- **Metrics** — `RequestCount`, `HTTPCode_ELB_5XX_Count` vs `HTTPCode_Target_5XX_Count` (LB-generated vs app-generated errors — this distinction tells you *which side* failed).

So: **console for health, access logs for the individual request, `X-Forwarded-For` to trace the client**.

```bash
# ALB access log line (S3) — reading a single request:
# type time elb client:port target:port req_proc_time target_proc_time resp_proc_time
#   elb_status_code target_status_code ...
# Example: elb_status_code=502, target_status_code=- => app reset the connection
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_Target_5XX_Count --statistics Sum \
  --dimensions Name=LoadBalancer,Value=app/my-alb/xxxx \
  --start-time 2026-07-17T00:00:00Z --end-time 2026-07-17T01:00:00Z --period 300
```

---

## Q3. (AWS networking) Are you aware what the DMZ layer is called?
**Asked in:** HDFC  |  **My performance:** Didn't-know

**My answer (from transcript):**
"Sorry, I'm not aware of that."

**✅ Correct answer:**
A **DMZ (Demilitarized Zone)** is the network segment that sits **between the public internet and your private/trusted internal network** — it holds the internet-facing components (load balancers, reverse proxies, bastion hosts) while keeping application servers and databases in a protected zone behind it.

In **AWS/VPC terms, the DMZ maps to the public subnet(s)**. The standard secure layout:
- **Public subnet (the DMZ):** only internet-facing resources — the **Application/Network Load Balancer, NAT gateway, bastion host**. These have routes to an **Internet Gateway**.
- **Private subnet (trusted zone):** the **application pods/EKS nodes** — no direct internet route in.
- **Private/isolated subnet (data tier):** the **database (RDS)** — most locked down.

The rule to say out loud: **"Only the load balancer lives in the public subnet (DMZ); app pods and DB live in private subnets and are never directly internet-reachable."** That single sentence answers half of the AWS networking questions in this file.

```text
                Internet
                   │
          ┌────────▼─────────┐  Internet Gateway
   PUBLIC │   ALB   NAT-GW    │  <-- DMZ (public subnet)
   SUBNET │  bastion          │
          └────────┬─────────┘
          ┌────────▼─────────┐
  PRIVATE │  EKS app pods    │  <-- no inbound from internet
   SUBNET │  (egress via NAT)│
          └────────┬─────────┘
          ┌────────▼─────────┐
  DATA    │  RDS database    │  <-- isolated, only app SG allowed
   SUBNET └──────────────────┘
```

---

## Q4. Cross-VPC connectivity: web layer in one VPC, app (EKS) + DB in another VPC — how do you establish connectivity between them from scratch, and how does the flow go?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Initially "we can use VPC endpoints." When pushed, said either VPC peering or VPC endpoints; described VPC endpoints as connecting to AWS services without going through the internet. Also (separately) said: perform VPC peering between the two VPCs, set route tables and NAT gateways if required, with the relevant ingress/egress and ports defined. Admitted "how exactly it's done I'm not exactly sure."

**✅ Correct answer:**
This is the **most important correction to internalize.** For **VPC-to-VPC (your own resources talking to each other), the answer is VPC peering (or Transit Gateway), NOT VPC endpoints.** These are completely different tools:

| Tool | What it connects | Use it for |
|------|------------------|-----------|
| **VPC Peering** | Two VPCs, 1-to-1, private routing | Web VPC ↔ App VPC (this question). No transitive routing. |
| **Transit Gateway** | Many VPCs (hub-and-spoke) | 3+ VPCs / hybrid at scale; replaces a mesh of peerings. |
| **VPC Endpoint** | Your VPC ↔ an **AWS service** (S3, ECR, Secrets Manager) | Private access to AWS APIs **without an internet path**. NOT for VPC-to-VPC, NOT cross-region. |

Establishing web-VPC ↔ app-VPC connectivity requires **four things** (peering alone is never enough — see Q6):
1. **Create the VPC peering connection** and accept it on both sides.
2. **Add routes on BOTH VPCs' route tables** — each VPC needs a route to the *other's* CIDR pointing at the peering connection. (Non-overlapping CIDRs are mandatory.)
3. **Security groups** — the app's SG must allow inbound from the web tier's SG/CIDR on the app port. (SGs can reference peer SGs only within same-region same-account setups; otherwise use CIDRs.)
4. **NACLs** — ensure subnet NACLs don't block the traffic.

Flow: web server → its route table sees the app VPC CIDR → routes over the peering link → app subnet NACL + SG allow it → reaches EKS pod. **NAT gateway is irrelevant here** — NAT is for egress to the *internet*, not for private VPC-to-VPC traffic.

```hcl
# 1. Peering connection
resource "aws_vpc_peering_connection" "web_to_app" {
  vpc_id      = aws_vpc.web.id       # requester
  peer_vpc_id = aws_vpc.app.id       # accepter
  auto_accept = true
}
# 2. Routes on BOTH sides (this is the step people forget)
resource "aws_route" "web_to_app" {
  route_table_id            = aws_route_table.web.id
  destination_cidr_block    = aws_vpc.app.cidr_block      # 10.1.0.0/16
  vpc_peering_connection_id = aws_vpc_peering_connection.web_to_app.id
}
resource "aws_route" "app_to_web" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = aws_vpc.web.cidr_block      # 10.0.0.0/16
  vpc_peering_connection_id = aws_vpc_peering_connection.web_to_app.id
}
# 3. SG on app allows web CIDR on app port
resource "aws_security_group_rule" "app_from_web" {
  type = "ingress" from_port = 8080 to_port = 8080 protocol = "tcp"
  cidr_blocks = ["10.0.0.0/16"] security_group_id = aws_security_group.app.id
}
```

---

## Q5. What is the purpose of a NAT gateway?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
Lets instances in private subnets communicate to the external network. (Interviewer noted this isn't relevant to web-to-app connectivity within the VPC.)

**✅ Correct answer:**
Your definition is **correct** — the interviewer's point was about *when it applies*, not that it was wrong. Precisely:

A **NAT gateway provides outbound (egress) internet access for instances in a private subnet, while preventing any unsolicited inbound connections from the internet.** Private instances (e.g., EKS pods pulling an image from a public registry, or calling a third-party API) send traffic to the NAT gateway, which lives in a **public** subnet; the NAT gateway translates the source to its own public/Elastic IP and forwards it out via the Internet Gateway. Return traffic for that established connection comes back — but nothing on the internet can *initiate* a connection inward.

Key distinctions to nail:
- **NAT gateway = egress (outbound) only.** For **ingress** (inbound from internet) you use an **Internet Gateway + Load Balancer**, not NAT.
- NAT is for **private-subnet → internet**. It has **nothing to do with VPC-to-VPC** traffic (that's peering) or **VPC-to-AWS-service** traffic (that's endpoints). That's exactly why it was "not relevant" in Q4.
- The NAT GW itself sits in a **public** subnet and needs a route to the IGW.

```text
Private subnet pod ──(0.0.0.0/0)──▶ NAT Gateway (public subnet, EIP)
                                        │
                                        ▼
                                 Internet Gateway ──▶ Internet
  ✔ outbound allowed (image pull, API call)
  ✘ inbound from internet blocked (NAT never accepts new inbound)
```

---

## Q6. Is VPC peering alone sufficient for connectivity, or what else is needed at the subnet level?
**Asked in:** HDFC  |  **My performance:** Didn't-know

**My answer (from transcript):**
"No, definitely not... subnet connectivity between VPCs, sorry I'm not sure about this, I think I should check."

**✅ Correct answer:**
**No — peering alone does nothing until you add routes.** A VPC peering connection just creates the *possibility* of a private link; traffic won't flow until every layer permits it. The full checklist:

1. **Route tables (the missing piece here):** In **each** VPC, the route table associated with the relevant subnets needs an entry: *destination = other VPC's CIDR → target = the peering connection*. Without this route, packets have no path and are dropped. This is the #1 thing people forget.
2. **Non-overlapping CIDRs:** The two VPCs must not have overlapping IP ranges, or routing is ambiguous/impossible.
3. **Security groups:** Must allow the traffic (SG can reference the peer's SG in same-region/same-account, else use CIDR).
4. **Network ACLs:** Subnet-level NACLs (stateless) must allow both request and response.
5. **No transitive peering:** If A↔B and B↔C are peered, A **cannot** reach C. Each pair needs its own peering (or use Transit Gateway).

So the "subnet-level" answer the interviewer wanted: **you must edit the route tables of the specific subnets on both sides to point the other VPC's CIDR at the peering connection**, and ensure NACLs/SGs permit it.

```bash
# The subnet-level step: add the route on each side's route table
aws ec2 create-route --route-table-id rtb-web \
  --destination-cidr-block 10.1.0.0/16 \
  --vpc-peering-connection-id pcx-abc123     # web subnet -> app VPC
aws ec2 create-route --route-table-id rtb-app \
  --destination-cidr-block 10.0.0.0/16 \
  --vpc-peering-connection-id pcx-abc123     # app subnet -> web VPC
# Verify:
aws ec2 describe-route-tables --route-table-ids rtb-web \
  --query 'RouteTables[].Routes[?VpcPeeringConnectionId!=`null`]'
```

---

## Q7. Same VPC: app on EKS and DB as RDS — how do you establish connectivity so the app can talk to the DB?
**Asked in:** HDFC  |  **My performance:** Partial

**My answer (from transcript):**
The DB subnet's security group should allow ingress from the application/web subnet; with that single directional ingress rule the connectivity is established, along with proper route tables.

**✅ Correct answer:**
This answer is **essentially correct** — within a single VPC this is the clean, minimal setup, and it's worth stating precisely:

- **Within one VPC, all subnets can already route to each other by default** (the VPC's local route `10.0.0.0/16 → local` exists automatically). So you usually **don't** need to touch route tables at all — the routing is implicit. (Good to acknowledge, but don't over-claim it as the key step.)
- The **real control point is the RDS security group**: add an **inbound rule allowing the DB port (e.g., 5432 for Postgres, 3306 for MySQL) sourced from the EKS nodes'/app's security group** (reference the SG, not a CIDR — cleaner and survives IP changes).
- Because **security groups are stateful**, one inbound rule is enough — the response traffic is automatically allowed. That's why a single directional ingress rule works.
- Best practice: put RDS in **private DB subnets** (a DB subnet group across AZs), never publicly accessible, and store credentials in **Secrets Manager**.

So the refined answer: *"Same VPC means routing is already handled by the local route. I just add an inbound rule on the RDS security group allowing the DB port from the EKS node security group; SGs are stateful so the return path is automatic."*

```bash
# Allow EKS nodes' SG to reach RDS on Postgres port (SG-referencing rule)
aws ec2 authorize-security-group-ingress \
  --group-id sg-rds \
  --protocol tcp --port 5432 \
  --source-group sg-eks-nodes
# App connects using the RDS endpoint DNS name:
#   psql -h mydb.abc123.us-east-1.rds.amazonaws.com -p 5432 -U app appdb
```

---

## Q8. Your application makes a third-party HTTPS call outside the company network (e.g., a bank app calling a third-party biller) — how do you approach this integration?
**Asked in:** HDFC  |  **My performance:** Didn't-know

**My answer (from transcript):**
"I'm sorry, I'm not sure about this."

**✅ Correct answer:**
This is **outbound (egress) integration** from a private app to an external HTTPS endpoint. The approach:

1. **Egress path:** App pods run in a **private subnet**, so their outbound internet traffic goes through a **NAT gateway** (Q5) → Internet Gateway → third party. In tightly controlled/regulated environments (banks), you often force traffic through an **egress proxy / forward proxy (e.g., Squid)** or a firewall appliance for inspection and logging.
2. **Static source IP for allow-listing:** The third party typically **allow-lists your source IP**. A NAT gateway gives a **stable Elastic IP**, so you give them that EIP. (This is the classic reason NAT gateways matter for integrations.)
3. **TLS / trust:** It's **HTTPS**, so the app validates the third party's TLS certificate (server auth). For sensitive B2B/bank integrations you often add **mutual TLS (mTLS)** — you present a **client certificate** the third party issued/registered. Store keys/certs in **Secrets Manager**.
4. **DNS:** The app resolves the third party's hostname (public DNS via CoreDNS → upstream resolver).
5. **Controls:** Restrict egress with **security groups / NetworkPolicy / proxy allow-lists** so pods can only reach that specific endpoint; log calls for audit.

One-liner: *"Private pods egress via a NAT gateway with a stable Elastic IP (which the third party allow-lists), over HTTPS/mTLS with certs from Secrets Manager, optionally through an egress proxy for inspection."*

```text
EKS app pod (private subnet)
   │ HTTPS (+ optional mTLS client cert)
   ▼
[egress proxy / SG allow-list]  ──▶  NAT Gateway (fixed EIP 52.x.x.x)
                                         │  (third party allow-lists this EIP)
                                         ▼
                                   Internet ──▶ https://api.biller.com
```

---

## Q9. Have you worked on REST APIs?
**Asked in:** Compunnel  |  **My performance:** Didn't-know

**My answer (from transcript):**
"No, not on REST APIs." (essentially no experience)

**✅ Correct answer:**
As a DevOps/SRE you interact with REST APIs constantly even if you don't *build* them — worth being able to speak to it. A **REST API** is an HTTP interface where **resources** (e.g., `/users`, `/orders/42`) are acted on with **HTTP methods**:

- **GET** (read, safe/idempotent), **POST** (create), **PUT** (replace, idempotent), **PATCH** (partial update), **DELETE** (idempotent). Stateless — each request carries its own auth (Bearer token / API key in headers).
- Responses use **HTTP status codes** (200 OK, 201 Created, 400 Bad Request, 401/403 auth, 404 Not Found, 429 rate-limited, 5xx server) and usually **JSON** bodies.

Your DevOps touchpoints: **the Kubernetes API is a REST API** — every `kubectl get pods` is a `GET /api/v1/namespaces/default/pods`. You also hit cloud APIs, Prometheus, and health/readiness endpoints. So a good answer is: *"I haven't built REST services, but I work with REST APIs daily — the Kubernetes API itself is REST, and I use `curl`/`kubectl -v` to debug them."*

```bash
# The Kubernetes API IS a REST API — prove it:
kubectl get --raw /api/v1/namespaces/default/pods | jq '.items[].metadata.name'
kubectl get pods -v=8 2>&1 | grep -E 'GET|Response Status'   # see the raw REST call

# Generic REST interaction with curl:
curl -s -H "Authorization: Bearer $TOKEN" https://api.example.com/v1/orders/42   # GET
curl -X POST -H 'Content-Type: application/json' \
  -d '{"item":"book"}' https://api.example.com/v1/orders -i   # POST, -i shows status
```

---

## Q10. Do you know about HTTP error codes in applications? What do they resemble?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Said 500/502 is a connectivity/server issue and 400 is access/permission related. The interviewer clarified a non-loading app with an unreachable backend would show 503; he was "almost there."

**✅ Correct answer:**
Close, but tighten the categories and — critically — **learn the 5xx gateway trio**, because as an SRE you'll be paged on these constantly:

- **2xx success:** 200 OK, 201 Created, 204 No Content.
- **3xx redirect:** 301 permanent, 302 found, 304 not modified.
- **4xx client error (caller's fault):** **400** Bad Request (malformed) — *not* permission; **401** Unauthorized (not authenticated); **403** Forbidden (authenticated but not allowed — *this* is the "access/permission" one); **404** Not Found; **429** Too Many Requests.
- **5xx server error (server's fault):** **500** Internal Server Error (app threw/unhandled exception); **502** Bad Gateway (proxy/LB got an invalid response — **backend is up but returned garbage or crashed the connection**); **503** Service Unavailable (**no healthy backend / overloaded — the interviewer's answer**); **504** Gateway Timeout (backend too slow, exceeded timeout).

The one to say precisely: **503 = no healthy backend to send to** (e.g., all pods down / Service has no endpoints), which is exactly the "app won't load, backend unreachable" scenario.

```text
In a K8s ingress → Service → Pod chain:
  502  ingress reached a pod, pod crashed / reset / returned invalid response
  503  ingress had NO healthy endpoints to route to (0 ready pods / bad selector)
  504  pod accepted the request but didn't respond within the timeout (slow / deadlock)
  500  the app itself threw an unhandled error (bug, DB down) and returned it
```

---

## Q11. An API runs on a host on port 54321; from your Linux machine the call times out. How do you troubleshoot?
**Asked in:** Persistent  |  **My performance:** Didn't-know

**My answer (from transcript):**
Suggested configuring a connectivity timeout duration — the only thing he could think of. The interviewer wanted `telnet` on the port to check if it's open/listening; he did not name a networking troubleshooting command.

**✅ Correct answer:**
A **timeout** (vs. a "connection refused") specifically points to **the packet being dropped silently** — usually a **firewall/security group/NACL blocking the port**, or the host not being reachable — *not* the app being down (a down app on a reachable host gives **connection refused**, not timeout). Systematic layered check:

1. **Is the host reachable at all?** `ping <host>` (ICMP may be blocked, so not definitive) and `traceroute <host>` to see where it dies.
2. **Is the port open/listening? (the answer the interviewer wanted):** `telnet <host> 54321`, or better `nc -vz <host> 54321` (netcat), or `nmap -p 54321 <host>`. A hang/timeout = filtered by firewall; "refused" = reachable host, nothing listening.
3. **On the server side:** `ss -tlnp | grep 54321` (or `netstat -tlnp`) — is the process actually listening, and on `0.0.0.0` (all interfaces) vs `127.0.0.1` (localhost only — a very common cause: it's up but bound to loopback)?
4. **Firewall layers:** security group inbound rule, NACL, host `iptables`/`firewalld`/`ufw`.
5. **The actual call:** `curl -v --connect-timeout 5 http://<host>:54321/` to see where it stalls.

The key vocabulary to have ready: **`telnet` / `nc -vz` / `nmap` to test the port, `ss -tlnp` to confirm it's listening**, and the **timeout-vs-refused distinction** that localizes firewall vs app.

```bash
# Test if the port is reachable (interviewer wanted this):
telnet 10.0.5.20 54321          # classic 10-min test: connects = open, hangs = filtered
nc -vz 10.0.5.20 54321          # modern equivalent; -z scan, -v verbose
nmap -p 54321 10.0.5.20         # reports open | closed | filtered

# On the server: is anything actually listening, and on which interface?
ss -tlnp | grep 54321           # 0.0.0.0:54321 = all; 127.0.0.1:54321 = localhost-only (bug!)

# Full request with visibility into where it stalls:
curl -v --connect-timeout 5 http://10.0.5.20:54321/
# timeout  => firewall/SG/NACL dropping packets (filtered)
# refused  => host reachable, nothing listening on that port
```

---

## 🔺 Advanced Questions to Master (not asked yet — practice these)

These are the standard networking questions a Senior DevOps/SRE is expected to answer cold. Rehearse each out loud.

### AQ1. Explain the OSI model (7 layers) and map real tools/protocols to each.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
7 layers, remember **"All People Seem To Need Data Processing"** (top→bottom: Application, Presentation, Session, Transport, Network, Data Link, Physical). What matters operationally is the bottom half plus knowing where things live:

- **L7 Application** — HTTP, DNS, gRPC (ALB, Ingress operate here → "L7 LB").
- **L6 Presentation** — TLS/encryption, encoding.
- **L5 Session** — connection sessions.
- **L4 Transport** — **TCP/UDP, ports** (NLB, `kube-proxy`, Service operate here → "L4 LB").
- **L3 Network** — **IP, routing, ICMP** (VPC route tables, `ping`, CNI).
- **L2 Data Link** — MAC, ARP, switches, VLANs.
- **L1 Physical** — cables, signals.

The practical framing: **L4 = IP+port only (fast, dumb); L7 = understands the HTTP request (host, path, headers).**

```text
L7 Application  | HTTP, DNS      | ALB, Ingress, curl        | data: message
L6 Presentation | TLS, JSON      | cert termination          |
L5 Session      | sessions       |                           |
L4 Transport    | TCP/UDP + PORT | NLB, Service, kube-proxy  | data: segment
L3 Network      | IP, ICMP       | route tables, CNI, ping   | data: packet
L2 Data Link    | MAC, ARP       | switch, bridge, veth      | data: frame
L1 Physical     | signals        | cable, NIC                | data: bits
```

### AQ2. TCP vs UDP — differences and when to use each.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**TCP** = connection-oriented, reliable, ordered, with a handshake, acknowledgements, retransmission, and flow/congestion control. Use for correctness-critical traffic: HTTP/HTTPS, SSH, database connections, gRPC. **UDP** = connectionless, no handshake, no delivery guarantee, no ordering — but low-latency and low-overhead. Use for DNS, DHCP, VoIP/video streaming, QUIC/HTTP-3, metrics (statsd). Trade-off in one line: **TCP trades latency for reliability; UDP trades reliability for speed.** In K8s, a Service `protocol:` can be TCP (default) or UDP (e.g., CoreDNS listens on UDP/53 and TCP/53).

```text
                 TCP                         UDP
connection       yes (3-way handshake)       none
reliability      guaranteed + retransmit     best-effort, may drop
ordering         yes                         no
speed/overhead   higher latency, more bytes  minimal, fast
use cases        HTTP, SSH, DB, gRPC         DNS, DHCP, VoIP, QUIC
```

### AQ3. Walk through the TCP three-way handshake (and connection teardown).
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
Establishing a TCP connection takes **three packets**:
1. **SYN** — client → server: "I want to connect", sends its initial sequence number (seq=x).
2. **SYN-ACK** — server → client: acknowledges (ack=x+1) and sends its own seq=y.
3. **ACK** — client → server: acknowledges (ack=y+1). Connection is now **ESTABLISHED**.

Teardown is a **four-way** exchange (FIN → ACK → FIN → ACK), after which the initiator sits in **TIME_WAIT**. This is why a **timeout during connect** (SYN sent, no SYN-ACK back) means the SYN is being dropped by a firewall — directly relevant to Q11. You can watch it with `tcpdump`.

```text
Client                         Server
  │ ── SYN  seq=x ───────────▶ │   (1)
  │ ◀─ SYN-ACK seq=y ack=x+1 ─ │   (2)
  │ ── ACK  ack=y+1 ─────────▶ │   (3)  => ESTABLISHED
# tcpdump to watch it:
#   tcpdump -ni any 'tcp port 443 and (tcp[tcpflags] & (tcp-syn|tcp-ack) != 0)'
```

### AQ4. DNS record types and the full resolution flow.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**Record types:** **A** (name → IPv4), **AAAA** (→ IPv6), **CNAME** (alias → another name), **MX** (mail), **TXT** (SPF/verification), **NS** (nameservers), **SOA** (zone authority), **PTR** (reverse, IP → name), **SRV** (service host+port). AWS adds **Alias** records (Route 53) to point a zone apex at an ALB/CloudFront.

**Resolution flow (recursive):** stub resolver → **recursive resolver** (checks cache) → **root** servers (`.`) → **TLD** servers (`.com`) → **authoritative** nameserver for the domain → returns the A record, cached per **TTL**. In Kubernetes, pods resolve via **CoreDNS**; a Service name like `svc.ns.svc.cluster.local` resolves to the ClusterIP.

```text
curl app.company.com
  └▶ stub → recursive resolver (cache miss)
        └▶ root (.)          → "ask .com TLD"
        └▶ TLD (.com)        → "ask ns1.company.com"
        └▶ authoritative     → A 52.1.2.3  (cached for TTL)
# Tools:  dig +trace app.company.com   |   nslookup app.company.com
# In-cluster: kubectl exec pod -- nslookup my-svc.my-ns.svc.cluster.local
```

### AQ5. What happens, end to end, when you `curl https://example.com`?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
The canonical senior-level question — narrate the whole stack:
1. **DNS resolution** — resolve `example.com` to an IP (cache → recursive → authoritative).
2. **TCP connection** — 3-way handshake (SYN/SYN-ACK/ACK) to the IP on **port 443**.
3. **TLS handshake** — negotiate version/cipher, server presents cert, client validates chain, keys exchanged (see AQ6).
4. **HTTP request** — `GET / HTTP/1.1\r\nHost: example.com` sent over the encrypted channel.
5. **Server/LB processing** — LB routes to backend (Ingress → Service → Pod in K8s).
6. **HTTP response** — status code + headers + body stream back.
7. **Render/close** — connection kept alive or closed (FIN). Each step is a place it can fail (DNS fail, connect timeout, TLS cert error, 5xx).

```text
curl https://example.com
 1 DNS      example.com -> 93.184.x.x
 2 TCP      SYN/SYN-ACK/ACK to :443
 3 TLS      ClientHello -> cert -> key exchange -> encrypted
 4 HTTP     GET / Host: example.com
 5 route    LB -> Ingress -> Service -> Pod
 6 resp     HTTP/1.1 200 OK + body
# See each stage's timing:
curl -w 'dns:%{time_namelookup} conn:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer}\n' -o /dev/null -s https://example.com
```

### AQ6. Explain the TLS handshake.
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
TLS establishes an encrypted, authenticated channel on top of TCP:
1. **ClientHello** — client sends supported TLS versions, cipher suites, and a random.
2. **ServerHello** — server picks version/cipher, sends its random and its **certificate** (public key, signed by a CA).
3. **Cert validation** — client verifies the cert chain up to a trusted root CA and that the hostname matches (SNI).
4. **Key exchange** — via **ECDHE** both sides derive the same **session key** (ephemeral → forward secrecy).
5. **Finished** — both switch to symmetric encryption with the session key; application data flows encrypted.
TLS 1.3 compresses this to **1 round trip**. Common failures: expired cert, hostname mismatch, untrusted CA, protocol/cipher mismatch. **mTLS** adds a step where the *client* also presents a cert (relevant to Q8).

```bash
# Inspect the handshake / cert:
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# curl showing the TLS layer:
curl -v https://example.com 2>&1 | grep -E 'SSL connection|subject:|issuer:'
```

### AQ7. Load balancer: L4 vs L7 — what's the difference and which AWS/K8s objects are which?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
- **L4 (transport) LB** routes on **IP + port** only; it doesn't read the HTTP request. Fast, protocol-agnostic (any TCP/UDP), preserves source IP easily. AWS = **NLB**; K8s = **Service type LoadBalancer / kube-proxy**.
- **L7 (application) LB** understands **HTTP** — can route by **host, path, headers, cookies**, terminate TLS, do redirects and sticky sessions. AWS = **ALB**; K8s = **Ingress controller** (nginx/ALB). Slightly higher latency for far more intelligence.

Rule of thumb: **need path/host routing or TLS termination → L7 (ALB/Ingress). Need raw TCP/UDP throughput or non-HTTP → L4 (NLB).**

```text
L4 (NLB / Service)        L7 (ALB / Ingress)
routes on IP:port         routes on Host / path / header
any TCP/UDP               HTTP/HTTPS/gRPC only
no TLS termination        TLS termination, redirects, WAF
example: 10.0.0.5:443     example: Host=api.co, path=/orders -> svc-a
```

### AQ8. How does traffic actually reach a pod? (Service, kube-proxy, CNI)
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
- **CNI plugin** (Calico, Cilium, AWS VPC CNI) gives each pod an IP and wires pod-to-pod routing. With AWS VPC CNI, pods get **real VPC IPs**.
- **Service** = a stable **ClusterIP** (virtual IP) + a label **selector**. The selector populates **Endpoints/EndpointSlices** with the matching pods' IPs. (Empty endpoints = the Q1 failure.)
- **kube-proxy** programs the node's **iptables/IPVS** rules so that traffic to the ClusterIP is **DNAT'd and load-balanced** across the healthy pod IPs. (Cilium can replace kube-proxy with eBPF.)
- Service types: **ClusterIP** (internal), **NodePort** (opens a port on every node), **LoadBalancer** (provisions a cloud LB).

```text
client -> ClusterIP 10.96.0.10:80
            │ (kube-proxy iptables/IPVS DNAT + LB)
            ├─▶ pod 10.244.1.5:8080
            └─▶ pod 10.244.2.7:8080   (from Endpoints of matching selector)
# kubectl get endpointslices -l kubernetes.io/service-name=my-svc
# iptables-save | grep my-svc     (see the DNAT rules kube-proxy wrote)
```

### AQ9. What is CoreDNS and how does DNS work inside a cluster?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
**CoreDNS** is the cluster DNS server (a Deployment in `kube-system`, fronted by a Service usually at `10.96.0.10`). Every pod's `/etc/resolv.conf` points at that ClusterIP with a `search` domain list. It resolves:
- **Service names** → `my-svc.my-ns.svc.cluster.local` → the Service ClusterIP.
- **Headless service pods** → individual pod A records.
- **External names** → forwarded upstream (`forward . /etc/resolv.conf`).
Config lives in the **`coredns` ConfigMap** (the Corefile). Common outage cause: CoreDNS pods down or overloaded → *everything* looks like it's failing. The `search` domains let you use short names like `my-svc` from within the same namespace.

```text
# Pod /etc/resolv.conf:
nameserver 10.96.0.10
search my-ns.svc.cluster.local svc.cluster.local cluster.local
# so "curl my-svc" expands to my-svc.my-ns.svc.cluster.local
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get configmap coredns -o yaml   # the Corefile
```

### AQ10. Ingress vs Service — when do you use which?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
- A **Service** gives a stable virtual IP/DNS for a set of pods and does **L4** load-balancing. `LoadBalancer` type gets you one cloud LB **per service** (expensive, no path routing).
- An **Ingress** is an **L7** HTTP router in front of many Services — one entry point that dispatches by **host/path**, terminates **TLS**, etc. It needs an **Ingress controller** (nginx, AWS ALB) to actually do the work. **Gateway API** is the newer successor.
Rule: **internal pod-to-pod or raw TCP → Service (ClusterIP/NodePort). External HTTP with host/path routing and TLS for many apps behind one LB → Ingress.**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
spec:
  tls: [{hosts: [api.company.com], secretName: api-tls}]
  rules:
  - host: api.company.com
    http:
      paths:
      - {path: /orders, pathType: Prefix, backend: {service: {name: orders-svc, port: {number: 80}}}}
      - {path: /users,  pathType: Prefix, backend: {service: {name: users-svc,  port: {number: 80}}}}
# One ALB, TLS terminated, routes /orders and /users to different Services.
```

### AQ11. What is a NetworkPolicy and how does default-deny work?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
A **NetworkPolicy** is pod-level firewalling (L3/L4) enforced by the **CNI** (Calico/Cilium — the CNI must support it; flat CNIs ignore it). By default **all pods can talk to all pods**. Once *any* NetworkPolicy selects a pod, that pod becomes **default-deny** for the specified direction, and only the listed `ingress`/`egress` rules are allowed. Rules match by **pod labels, namespaces, or IP blocks** on specific ports. Best practice: apply a **default-deny-all** in the namespace, then explicitly allow required flows (zero-trust). This is the Q2 "default-deny NetworkPolicy silently blocks traffic" scenario.

```yaml
# Default deny all ingress, then allow only frontend -> backend:80
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all-ingress, namespace: app}
spec: {podSelector: {}, policyTypes: [Ingress]}   # selects all pods, no ingress = deny
---
kind: NetworkPolicy
spec:
  podSelector: {matchLabels: {app: backend}}
  ingress:
  - from: [{podSelector: {matchLabels: {app: frontend}}}]
    ports: [{protocol: TCP, port: 80}]
```

### AQ12. CIDR and subnetting — how do you read `10.0.0.0/16` and size subnets?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
CIDR notation `IP/prefix` — the **prefix** is how many leading bits are the network portion; the rest are host bits. `/16` = 16 network bits → **65,536** addresses (`10.0.x.x`); `/24` = **256** addresses (`10.0.1.x`); `/28` = 16 addresses. Formula: hosts = **2^(32−prefix)**. Smaller prefix = bigger block. In AWS: a **VPC** gets a CIDR (e.g., `/16`), carved into **subnet** CIDRs (e.g., `/24` per subnet per AZ). **AWS reserves 5 IPs per subnet** (first 4 + last). VPCs that you peer must have **non-overlapping** CIDRs (Q4/Q6). Rule of thumb: **prefix down by 1 = double the size.**

```text
10.0.0.0/16   -> 65,536 IPs   (whole VPC)
 ├ 10.0.1.0/24  -> 256 IPs    public subnet  AZ-a  (AWS usable: 251)
 ├ 10.0.2.0/24  -> 256 IPs    private subnet AZ-a
 └ 10.0.3.0/24  -> 256 IPs    private subnet AZ-b
hosts = 2^(32 - prefix);  /28 = 16,  /24 = 256,  /16 = 65536
```

### AQ13. What are ports, and which well-known ports should you know cold?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
A **port** is a 16-bit number (0–65535) at **L4** that identifies a specific service/socket on a host, so one IP can run many services. `IP:port` = a socket. **0–1023** = well-known/privileged, **1024–49151** registered, **49152+** ephemeral (client source ports). Memorize: **22** SSH, **53** DNS, **80** HTTP, **443** HTTPS, **3306** MySQL, **5432** Postgres, **6379** Redis, **6443** Kubernetes API, **2379/2380** etcd, **10250** kubelet, **9090** Prometheus. Knowing the port is half of firewall/SG debugging (Q7, Q11).

```text
22   SSH        443  HTTPS       6443   kube-apiserver
53   DNS        3306 MySQL       10250  kubelet
80   HTTP       5432 Postgres    2379/2380 etcd
# See what's listening on which port:
ss -tlnp        # TCP listeners + owning process
```

### AQ14. HTTP 502 vs 503 vs 504 in a Kubernetes ingress — how do you tell them apart on-call?
**My answer:** *(Not asked — study & rehearse)*

**✅ Correct answer:**
This is the SRE-paging version of Q10 — know the **cause and the fix** for each:
- **502 Bad Gateway** — ingress reached a pod but got an **invalid/reset response**: app crashed mid-request, listening on the wrong port, or protocol mismatch (plain HTTP to an HTTPS backend). Check pod logs + `containerPort` vs Service `targetPort`.
- **503 Service Unavailable** — **no healthy endpoints**: 0 ready pods, failing readiness probe, or a **selector/label mismatch** so Endpoints is empty. `kubectl get endpoints` — if empty, that's it.
- **504 Gateway Timeout** — pod got the request but **didn't respond in time**: slow query, deadlock, or an ingress `proxy-read-timeout` shorter than the app's response time. Check app latency + timeout annotations.

```text
502  reached pod, bad response   -> pod logs, targetPort/containerPort, http vs https
503  no healthy endpoints        -> kubectl get endpoints (empty?), readiness probe, selector
504  pod too slow to answer      -> app latency, ingress proxy-read-timeout
# Fast triage:
kubectl get endpoints my-svc -n app        # empty => 503 root cause
kubectl describe ingress -n app            # timeout / backend annotations
kubectl logs -n app deploy/app --tail=50   # crash => 502, slow => 504
```

---
