# 🎯 ROADMAP — Jul 18 → Aug 31, 2026 (LWD: Aug 30)
### Two tracks, six weeks: get interview-lethal + CKA-ready, with applications running from day one.

> **The diagnosis this plan fixes** (from [00-FEEDBACK-and-Action-Plan.md](interview-preps/interview-Q&As/00-FEEDBACK-and-Action-Plan.md), 19 real interviews): *"strong conceptually, light on hands-on."* So the rule for every topic below is: **do it in a terminal first, read second, then say it out loud from memory.** Never study a topic without its hands-on lab. Never end a week without the recorded Sunday checkpoint.
>
> **The four golden habits (apply in every single interview):**
> 1. Never "another team did that" — own it: what you understand + what you'd do.
> 2. Never "long back, can't recall" — the labs below make it *"I did this last week."*
> 3. Scenario questions: **triage first** (monitoring → logs → error codes → isolate), infra second.
> 4. Wrong-answer risk: reason aloud from fundamentals; never guess-and-commit.

---

## 📅 Daily rhythm (the engine — protect it)

| Slot | Weekday (~2.5–3h) | Saturday (~6h) | Sunday (~4h) |
|---|---|---|---|
| Deep block | 90–120 min: **this week's hands-on lab** | 3h lab | 2h lab / overflow |
| Skill block | 30–45 min: Python ([Ladder 03](AI Infra-Projects/Ladder-learning/03-python-from-zero-for-both-books.md)) → later CKA drills | 2h: Q&A drills out loud | 1h: **recorded checkpoint** (phone, no notes) |
| Admin | 15 min: applications/follow-ups | 1h: applications + LinkedIn outreach | 1h: log the week, plan next |

**Interview days:** the interview *replaces* the deep block. Same evening, non-negotiable: write down every question asked → self-grade → add to `interview-preps/` → patch the top gap within 48h. (Your transcript system already proved this flywheel works — keep feeding it.)

**Budget guardrails:** all K8s labs on **kind** ($0). AWS VPC lab: build → screenshot → **tear down same day** (NAT GW ~$0.05/h — half a day max; S3 *gateway* endpoint is free; TGW ~$0.07/h — create, inspect, delete within the hour). AWS Budgets alarm at **$25** before Week 1.

---

## WEEK 0 — Fri Jul 18 → Sun Jul 20: LAUNCH WEEKEND 🚀
*Nothing this weekend is study. It's all positioning.*

- [ ] **Resume fixes:** Wipro end date 07/2026 → **08/2026**; sweep every bullet for "I" language; every number gets its mechanism ("saved 15 h/wk **by** a script that…"). Export fresh PDF.
- [ ] **Application tracker** (sheet): company · role · link · date · status · contact · next action.
- [ ] **Apply to all 10 Tier-1 live openings:** Roku, FIS, State Street/Charles River, Morgan Stanley, CRED, HPE, Omnissa, RingCentral, Société Générale, Apple.
- [ ] **LinkedIn:** headline → "Senior DevOps/SRE · Multi-tenant EKS · Terraform · ArgoCD · Observability"; Open-to-Work (recruiters only); message 5 ex-colleagues (First American, Wipro/Harman, TEK, ITC) for referrals into target companies.
- [ ] **Book the CKA now** for a **Sept 2–5** slot (Linux Foundation; watch for the frequent 30–40% coupon; includes **2× killer.sh** sessions; rescheduling is free up to 24h before — booking early is zero-risk and forces the finish line).
- [ ] Set the **$25 AWS budget alarm**.
- [ ] Re-read [00-FEEDBACK-and-Action-Plan.md](interview-preps/interview-Q&As/00-FEEDBACK-and-Action-Plan.md) end to end; pin the golden rules where you work.
- [ ] Evening starter: [Ladder 03](AI Infra-Projects/Ladder-learning/03-python-from-zero-for-both-books.md) **Part 0** (setup + reading errors).

---

## WEEK 1 — Jul 21–27: STOP THE BLEEDING I — AWS Networking + Linux 🔴
*The two topics that literally sank interviews (HDFC, Persistent, HTC). Highest ROI of the whole plan.*

### Deep blocks — AWS networking end-to-end
- [ ] Study spine: [02-AWS-QnA](interview-preps/interview-Q&As/02-AWS-QnA.md) + [10-Networking-QnA](interview-preps/interview-Q&As/10-Networking-QnA.md), backed by [Networking/20-aws-vpc](Networking/20-aws-vpc.md), [03-subnetting-cidr](Networking/03-subnetting-and-cidr.md), [08-routing](Networking/08-routing-and-forwarding.md), [14-nat-pat](Networking/14-nat-and-pat.md), [17-firewalls-sg-nacls](Networking/17-firewalls-security-groups-nacls.md), [18-load-balancing](Networking/18-load-balancing.md), [21-cdn-edge-waf](Networking/21-cdn-edge-waf.md).
- [ ] **LAB (the HDFC fix):** build in AWS: VPC → public subnet (ALB only) + private subnets (app) + isolated (db); IGW; NAT for egress; route tables per tier; SGs chained (ALB-SG → app-SG → db-SG); **S3 gateway VPC endpoint** (see the route-table entry it adds). Screenshot → **tear down**.
- [ ] **LAB:** second VPC + peering; connect app→db across VPCs. Then articulate when **Transit Gateway** replaces peering (3+ VPCs, hub-and-spoke, on-prem). Create a TGW, attach, inspect, **delete within the hour**.
- [ ] Whiteboard from memory ×3 during the week: web→app→db multi-VPC diagram; "UI pods go in **private** subnets behind a public ALB" — say why; NAT = **egress-only**, ingress = ALB/IGW.

### Linux blocks (1h/day)
- [ ] Spine: [09-Linux-QnA](interview-preps/interview-Q&As/09-Linux-QnA.md) + [Linux/07-processes-job-control](Linux/07-processes-job-control.md), [05-permissions-ownership](Linux/05-permissions-ownership.md), [06-users-groups-sudo](Linux/06-users-groups-sudo.md), [11-networking](Linux/11-networking.md), [16-systemd-services](Linux/16-systemd-services.md), [21-performance-monitoring](Linux/21-performance-monitoring.md).
- [ ] **LAB (WSL/any box):** process vs thread (`ps -eLf`), signals (`kill -TERM` vs `-KILL`), nice/renice; chmod/chown octal drills; su vs sudo; find what's on a port 3 ways (`ss -tlnp`, `lsof -i`, `curl -v`/`telnet`); one unit file + `journalctl -u` walk.

### Terraform internals (weekend block)
- [ ] Redo hands-on in a scratch dir: **`terraform refresh`** (state ← reality — you explained it backwards at Barclays; prove the direction by manually deleting a resource and refreshing), state-per-env via **separate backend keys** vs **workspaces** (when each), plan/apply cycle narration. Spine: [03-Terraform-QnA](interview-preps/interview-Q&As/03-Terraform-QnA.md).

### Evenings + admin
- [ ] Python [Ladder 03](AI Infra-Projects/Ladder-learning/03-python-from-zero-for-both-books.md) Part 1 (variables → dicts → loops).
- [ ] Applications: +6 **Tier-4** (Razorpay, PhonePe, Juspay, Groww, Swiggy, Flipkart).

**✅ Sunday checkpoint (record, no notes):** VPC endpoint purpose · NAT vs IGW direction · peering vs TGW · SG vs NACL · subnet placement for a 3-tier app · process vs thread · `terraform refresh` direction. Grade yourself; re-do any stumble Monday.

---

## WEEK 2 — Jul 28–Aug 3: STOP THE BLEEDING II — K8s Scenarios + Docker Internals 🔴
*The probe/init/RBAC/HPA scenario questions you missed 4+ times, plus Docker under the hood.*

### Deep blocks — Kubernetes (on kind, $0)
- [ ] **LAB (build the broken-pod demo — your #1 scenario fix):** (a) app returns 503s on scale-up → fix with **readinessProbe**; (b) app starts before DB → **initContainer** wait; (c) slow-start app killed by liveness → **startupProbe**. Narrate the triage order while doing it: *events → logs → probes → then infra.* Spine: [01-Kubernetes-QnA](interview-preps/interview-Q&As/01-Kubernetes-QnA.md) + [CKA README 04](CKA-Course/README/04-application-lifecycle-management.md).
- [ ] **LAB — RBAC done right:** Role + RoleBinding + SA on kind; verify with `kubectl auth can-i --as`. Say it correctly: RBAC grants **Kubernetes API** permissions (Pure Software fix); IRSA/Pod Identity is what grants **AWS** permissions — you know this from First American, connect the two aloud.
- [ ] **LAB — the scaling table:** HPA (pods) vs VPA (requests) vs Cluster Autoscaler/Karpenter (nodes) — deploy metrics-server + a real HPA on kind and watch it scale. HDFC fix: HPA ≠ nodes.
- [ ] **LAB:** node affinity vs **pod** affinity/anti-affinity (co-locate/spread relative to *pods*) — two-deployment demo. [CKA README 02](CKA-Course/README/02-scheduling.md).

### Docker internals (spine: [05-Docker-QnA](interview-preps/interview-Q&As/05-Docker-QnA.md))
- [ ] **LAB:** image immutability vs **copy-on-write** container layer (`docker diff` a running container); `docker run` vs `start`; create + find + prune **dangling images**; rebuild one of your images with **multi-stage + .dockerignore + distroless** and show the size drop.

### Evenings + admin
- [ ] Python Ladder 03: finish Part 1 (functions, comprehensions).
- [ ] **Write 6 STAR stories** ([12-Behavioral](interview-preps/interview-Q&As/12-Behavioral-HR-QnA.md)): major incident · cluster migration/decommission · automation win · conflict · a failure · cost saving. Each ends with a number **and** its mechanism. Kill "we"; kill "long back."
- [ ] Applications: +6–8 **Tier-2 BFSI GCCs** (JPMorgan, Goldman, Visa, PayPal, Wells Fargo, Fidelity, Intuit).

**✅ Sunday checkpoint:** run the broken-pod demo live while narrating triage; explain copy-on-write cold; the HPA/VPA/CA/Karpenter table from memory; RBAC in one correct sentence.

---

## WEEK 3 — Aug 4–10: OWN WHAT YOU OUTSOURCED + CI/CD & Observability Depth 🟠
*Every "another team handled that" becomes "I built it last week."*

### Deep blocks (spines: [04-CICD-QnA](interview-preps/interview-Q&As/04-CICD-QnA.md), [07-Security-QnA](interview-preps/interview-Q&As/07-Security-QnA.md))
- [ ] **LAB — golden image:** build one AMI (or container image) with **Packer**; explain golden-image pipeline + patching story.
- [ ] **LAB — scan & sign:** **Trivy** scan one of your images → fix one CVE (bump base image) → rescan; **cosign** sign + verify. Bonus: generate an SBOM (`syft` or `trivy sbom`) and trace image → Dockerfile via labels.
- [ ] **LAB — traffic switching for real (Pure Software fix):** on kind, blue/green as two Deployments + one Service; **flip the selector**, watch traffic move; then a 90/10 canary (two Deployments behind one Service by replica ratio, or Ingress weights). Add a smoke-test step before the flip.
- [ ] **LAB — git:** `rebase` (feature onto main + interactive squash) and `submodule` add/update in scratch repos, 3 reps each.

### Observability (spine: [06-Observability-QnA](interview-preps/interview-Q&As/06-Observability-QnA.md))
- [ ] Rewire the story: **Prometheus = metrics/SLIs/SLOs; ELK = logs; the shipper is *Filebeat*** (name it!). Write the math: error budget = 100% − SLO; burn rate = consumption speed; fast-burn (2%/1h) + slow-burn alert pair.
- [ ] **LAB:** on kind, kube-prometheus-stack; one recording rule (availability SLI) + one burn-rate alert. Screenshot the Grafana panel — now the SLO answer is *demonstrated*, not narrated.

### Evenings + admin
- [ ] Python Ladder 03 Part 2 (files, exceptions, JSON, reading classes).
- [ ] Applications: +6–8 **retail/engineering GCCs** (Walmart GT, Target, Lowe's, Tesco, Maersk, Bosch, Philips, GE HealthCare).
- [ ] Interviews are likely flowing now — flywheel every one of them.

**✅ Sunday checkpoint:** say, in present tense, "I build the golden image with Packer, scan with Trivy, sign with cosign, and gate deploys on it" — then field your own follow-up drill. Burn-rate math cold. Blue-green switch mechanics cold.

---

## WEEK 4 — Aug 11–17: SRE THEORY + THE PYTHON ARTIFACT + CKA RAMP 🟡
*(Aug 15 Independence Day — bonus deep-work day.)*

### SRE vocabulary → fluency (spine: [08-SRE-QnA](interview-preps/interview-Q&As/08-SRE-QnA.md))
- [ ] CAP theorem · MTBF/MTTR/MTTD · error-budget **policy** (what happens when it's spent) · chaos engineering (it's fault-injection, NOT load testing — Trianz fix) · shift-left · toil. One paragraph each, out loud.

### The Python artifact (your live-coding fix, spine: [11-Python-QnA](interview-preps/interview-Q&As/11-Python-QnA.md))
- [ ] **Rewrite your K8s cleanup script properly:** `kubernetes` Python client (list/delete by namespace + age label) + `boto3` (correctly — e.g., report orphaned EBS volumes) + `argparse` (`--dry-run`, `--namespace`) + try/except + logging + **one pytest**. Push to GitHub. This is now a talking artifact: *"I rewrote it last week — here's the repo."* (Use Ladder 03 §3.4/§3.9 as scaffolding.)

### CKA ramp begins (goal: exam-fit by Sept 2–5)
- [ ] Speed habits: `alias k=kubectl`, `--dry-run=client -o yaml`, `kubectl explain`, vim basics.
- [ ] Drill [examples README](CKA-Course/examples README/00-README.md) sections **01–07** (core, scheduling, logging, lifecycle, maintenance, security, storage) on kind + free killercoda CKA scenarios (~45 min/day).

### Evenings + admin
- [ ] [Ladder 02 GenAI foundations](AI Infra-Projects/Ladder-learning/02-k8s-for-genai-foundations.md) Concepts 1–2 (the Track-B seed).
- [ ] Applications: +6–8 **Tier-3 product cos** — lead with your hooks: **CrowdStrike** (you deployed their product fleet-wide — say so in the note), **Elastic** (your ELK depth), Cisco, Nutanix, NetApp, Rubrik, Palo Alto, Cloudflare.
- [ ] One **mock interview** (friend, or self-record 10 random questions from [Interview-Questions-Bank.md](interview-preps/Interview-Questions-Bank.md)).

**✅ Sunday checkpoint:** error-budget policy + chaos definition cold; demo the Python tool with `--dry-run`; CKA sections 01–07 tasks done without docs.

---

## WEEK 5 — Aug 18–24: CKA SPRINT I + SPACED REPETITION 🧪
- [ ] Drill [examples README](CKA-Course/examples README/00-README.md) **08–13** — networking, cluster design, kubeadm install, helm, kustomize, and **troubleshooting** (biggest exam weight; use [README/13](CKA-Course/README/13-troubleshooting.md) flows: node NotReady → kubelet/journalctl; pod pending → describe/events; service unreachable → endpoints → labels).
- [ ] Daily killercoda scenario + one timed task set.
- [ ] **Saturday: killer.sh session #1** — full 2h simulation. **Sunday: review every miss** (the review IS the learning; killer.sh runs harder than the real exam — don't panic at the score).
- [ ] 1h/day spaced repetition: re-answer Week 1–3 Priority-1 lists out loud, unprompted (independent recall was your weak spot — this builds it).
- [ ] K8s networking depth while it's warm: [Networking/24-pod-networking-cni](Networking/24-kubernetes-pod-networking-cni.md), [25-services-kube-proxy](Networking/25-kubernetes-services-kube-proxy.md), [26-dns](Networking/26-kubernetes-dns-service-discovery.md), [28-network-policies](Networking/28-kubernetes-network-policies.md) — these serve both CKA and interviews.
- [ ] Evenings: Ladder 02 Concepts 3–4. Applications: +5 (**new-2026 GCCs**: Coupang, Intuitive Surgical, Zeiss, Glean, Revolut) + follow up every application >7 days old.

**✅ Sunday checkpoint:** killer.sh misses re-done from scratch; etcd backup/restore and a kubeadm upgrade executed without notes.

---

## WEEK 6 — Aug 25–31: CKA SPRINT II + CLOSEOUT + TRACK-B TEE-UP 🏁
- [ ] **killer.sh session #2** early in the week → target comfortable ≥75%. Patch remaining weak areas ([README/05 maintenance](CKA-Course/README/05-cluster-maintenance.md), [06 security](CKA-Course/README/06-security.md), [08 networking](CKA-Course/README/08-networking.md), [13 troubleshooting](CKA-Course/README/13-troubleshooting.md)).
- [ ] Exam-day prep: quiet room, government ID, PSI system check, bookmarklet-free docs habit.
- [ ] **LWD logistics (don't let these bite later):** relieving + experience letters, final payslips, PF/gratuity paperwork, reference commitments from 2 managers/leads, personal copies of *your* (permitted) artifacts, LinkedIn recommendations requested.
- [ ] **Interview retro:** list every real question from Aug interviews → top 3 recurring gaps → patch them this week (this replaces one lab day).
- [ ] Stretch (evenings, optional — only if weeks 1–5 are green): **Go on-ramp** for project-07 — Tour of Go 1h/day ×4 + one tiny CLI; Ladder 02 Concepts 5–6.
- [ ] Sunday Aug 31: write `SEPT-PLAN.md` — CKA exam date, project-1 kickoff (Kalyan-as-substrate + GPU Operator), project-16 parallel start.

**✅ Final checkpoint (the "did this work?" bar for Aug 31):**
- [ ] 40+ applications out; 8–12 active processes; ≥2 loops at advanced stages.
- [ ] Every 🔴 Priority-1 weakness: hands-on done + answerable cold on recording.
- [ ] 6 STAR stories rehearsed; zero "another team" / "long back" in any Aug interview.
- [ ] Python artifact on GitHub; golden-image/Trivy/cosign demos done.
- [ ] killer.sh ×2 done; CKA sitting in the first week of Sept.
- [ ] Ladder 02 + 03 read; Go started (stretch).

---

*Then September belongs to the other roadmap: CKA exam → project-1 ∥ project-16 → 07 → 2, GenAI book riding alongside — with, ideally, a signed DevOps/SRE offer already in hand while you build it.*
