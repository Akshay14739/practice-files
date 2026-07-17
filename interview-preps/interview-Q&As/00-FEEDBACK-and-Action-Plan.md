# 📋 Overall Feedback & Action Plan — Based on 19 Real Interview Transcripts

> Analysis of your recorded interviews with: Accion Labs (×2), Barclays, Compunnel, GlobalLogic, HCL, HDFC, HTC (×2), Persistent, Pure Software, PwC (×3), Shell (×2), Trianz (×2), Virtusa.
> ~445 questions analyzed across 12 topics. Read this FIRST, then work through the topic files (`01`–`12`).

---

## 1. The Headline Verdict

**Interviewers consistently described you the same way: "Strong conceptually, but light on hands-on."** This exact phrase (or a version of it) came up in HDFC, Trianz, Shell, and Persistent. That is the single most important pattern to fix.

You interview well on **narrating architecture** (Kubernetes runtime, CI/CD pipeline flow, observability stack, incident process) but get exposed when interviewers drill into:
- **Internals** ("how does it work *under the hood*")
- **Hands-on specifics** ("what's the *exact command / field / flow*")
- **Ownership** — too many answers were *"another team handled that"* (image scanning, golden images, node upgrades, Docker builds). At senior level this reads as a red flag.

### Your strengths (keep leaning on these)
✅ Terraform workflow, state, drift (conceptual) · ✅ CI/CD pipeline narration & security-scanning awareness · ✅ Observability SLI/SLO/alert-fatigue talking points · ✅ Secrets management (Pod Identity + Secrets Manager story) · ✅ Kubernetes runtime objects (Services, Ingress, HPA, DaemonSet, probes at a high level) · ✅ Incident management storytelling.

---

## 2. Critical Weaknesses (ranked — fix in this order)

### 🔴 Priority 1 — the ones that FAILED interviews

| # | Gap | What happened | Where |
|---|---|---|---|
| 1 | **AWS Networking** | Couldn't connect web→app tier across VPCs; wrong purpose for VPC endpoint; didn't know Transit Gateway, DMZ, subnet placement (put UI pods in public subnets); confused NAT (egress) with ingress | HDFC (sank it), Virtusa, Trianz, GlobalLogic |
| 2 | **Linux fundamentals** | Didn't-know on process scheduling, process vs thread, telnet/port troubleshooting; hedged on chmod/chown, su/sudo. Self-rated 2.5–3/5 | Persistent, HTC |
| 3 | **Hands-on ownership gaps** | Image scanning, golden/machine images, Docker builds, node upgrades all "done by another team" — couldn't go deep | Shell, HDFC, Trianz, Barclays |
| 4 | **Kubernetes probes & startup ordering** | Missed readiness/startup/liveness + init containers on 4+ scenario questions (503s on scale-up, app-before-DB); blamed network/SG instead | PwC-K8s, Shell |
| 5 | **Terraform internals** | `terraform refresh` explained **backwards**; couldn't segregate state per environment; shaky on workspaces & provisioner idempotency | Barclays, Shell, PwC-K8s |

### 🟠 Priority 2 — recurring conceptual errors (you'll keep losing points)

- **K8s RBAC misunderstanding** — you explained Role/RoleBinding as granting access to *cloud/AWS* resources. It grants permissions on the **Kubernetes API**. (Pure Software)
- **HPA scope error** — you said HPA scales *both pods and nodes*. HPA = pods only; nodes = Cluster Autoscaler/Karpenter. (HDFC) Also HPA vs VPA confusion. (Trianz)
- **Docker internals** — couldn't explain image immutability vs the writable **copy-on-write** container layer; `docker run` vs `docker start` wrong; didn't know dangling images. (Trianz, Barclays)
- **Pod affinity vs node affinity** — conflated them. Pod affinity = co-locate relative to *other pods*. (Pure Software)
- **Blue-green traffic switching** — confidently explained blue-green, then admitted you'd never actually switched traffic (Service selector). Don't claim what you can't drill into. (Pure Software)
- **IAM depth** — couldn't recall policy elements (Effect/Action/Resource/Principal) or explain assume-role. (Barclays, HDFC)
- **ELK vs Prometheus for SLOs** — you used **ELK for SLIs/SLOs**, which interviewers repeatedly flagged as unconventional; Prometheus is the standard for metrics/SLOs, ELK is for logs. And you couldn't name **Filebeat** (kept saying "Elasticsearch agent"). (Compunnel, HDFC)
- **SLO/error-budget math** — "96% SLO with 35% error budget" is inconsistent. Error budget = 100% − SLO. Learn burn-rate. (HCL/Trianz)

### 🟡 Priority 3 — vocabulary/theory you were caught not knowing

Git **rebase** (forgot it) · Git **submodules** (answered about Terraform) · **Trivy** (never heard of it) · **code signing / cosign** · **smoke testing** · **CAP theorem** · **MTBF** · **chaos engineering** (thought it was load testing) · **shift-left** · **transit gateway** · **EC2 3× status checks** · **DHCP option sets** · **CNCF / platform engineering**.

### ⚪ Cross-cutting behavioral issues

- **"I did this long back, can't recall"** appeared repeatedly (Barclays especially). Interviewers hear this as *"never really did it."* Re-do the hands-on so it's fresh.
- **Recall is prompt-dependent** — you often completed answers only *after* the interviewer fed the keyword (VPC endpoints, WAF/CloudFront, canary). You need independent recall.
- **Jumping to infra before triage** — in "app is down" scenarios you jumped to VPC/security-groups instead of checking monitoring/logs/error codes first. Fix the instinct: **observe → isolate → fix.**
- **Python** — only linear scripts, self-rated 6/10, no boto3/k8s-client/OOP/tests. Live-coding tasks exposed this (used boto3 to read *local* disk).

---

## 3. Your 4-Week Study Plan

**Week 1 — Stop the bleeding (the interview-killers)**
- AWS Networking end-to-end: VPC, subnets (public/private placement), route tables, IGW vs NAT, VPC peering vs **Transit Gateway** vs **VPC Endpoints/PrivateLink**, DMZ, security groups vs NACLs. → file `02-AWS`, `10-Networking`.
- Linux core: processes/threads/scheduling, signals, permissions, `ss`/`telnet`/`netstat` port troubleshooting, systemd/journalctl. → file `09-Linux`.
- Redo **`terraform refresh`, state segregation, workspaces** hands-on. → file `03-Terraform`.

**Week 2 — Fix the conceptual errors**
- K8s probes + init containers + startup ordering (build the broken-pod demo). K8s **RBAC** (API permissions, not cloud). HPA vs Cluster Autoscaler vs Karpenter vs VPA. Pod vs node affinity. → file `01-Kubernetes`.
- Docker internals: layers, copy-on-write, `run` vs `start`, dangling images, optimization (.dockerignore, multi-stage, distroless). → file `05-Docker`.

**Week 3 — Own what you outsourced + tooling vocab**
- Actually build: a **golden image** (Packer), an **image scan** (Trivy), **image signing** (cosign). Trace an image → Dockerfile via labels/SBOM. → files `05`, `07`.
- Git rebase & submodules hands-on. Smoke tests, canary/blue-green traffic switching for real. → file `04-CICD`.
- Move SLOs to **Prometheus** mentally; learn burn-rate math; name **Filebeat**. → file `06-Observability`.

**Week 4 — Depth + delivery**
- SRE theory: CAP, MTBF/MTTR, chaos engineering, shift-left, error-budget policy. → file `08-SRE`.
- Python: rewrite your cleanup script with the **kubernetes client** + **boto3** properly; add argparse, error handling, one pytest. → file `11-Python`.
- Rehearse **STAR** stories; kill "we", kill "long back", end every story with a number. → file `12-Behavioral`.

---

## 4. Golden Rules for Your Next Interviews

1. **Never say "another team did that."** Say what *you* understand about it + what you'd do. Own it.
2. **Replace "I did this long back"** with a crisp present-tense explanation — re-do the hands-on so it's true.
3. **In scenario questions: triage first** (monitoring → logs → error codes → isolate), *then* infra.
4. **Don't over-claim.** If you name blue-green/canary/chaos, be ready for the drill-down. Depth beats breadth at senior level.
5. **Every number needs a mechanism.** "Saved 20 hrs/week" → *how* the script did it.
6. **When you don't know:** reason out loud from fundamentals, don't guess-and-commit to a wrong answer (you did this with `terraform refresh`). "I haven't hit that directly, but from first principles it'd be X."
7. **Say "I" for your work, "we" only for genuine team efforts.**

---

*Detailed per-topic Q&As — with your actual transcript answers, the correct answers, and code — are in files `01` through `12`. The 🔺 sections in each are new advanced questions to push you past the senior bar.*
