# AI Infrastructure Engineering Portfolio — Master Roadmap

**Goal:** Kubernetes/DevOps engineer (EKS, Terraform, ArgoCD, Karpenter, ELK) → **Big Data / ML Platform / AI Infrastructure Engineer** at a frontier AI lab, GPU neocloud, or AI-infra vendor.

**Method:** two books + one Udemy course for concepts → **16 build-in-public projects** for proof, in three tiers. Every project ends as a **public repo with measured numbers**, because that is what actually gets you hired.

**Companion theory:** [genai-k8s-field-guide.html](genai-k8s-field-guide.html) · [bigdata-k8s-field-guide.html](bigdata-k8s-field-guide.html) — read the relevant chapter *before* each project, not instead of it.

> Versions and prices in these documents were verified against primary sources (NVIDIA datasheets, upstream repos, cloud pricing pages) **as of July 2026**. These ecosystems move monthly — always check the linked upstream release before installing.

---

## 1. Read this first: ship four, then interview

You have ~24 project documents and **zero shipped repos**. That is the actual bottleneck. All 16 projects at their own estimates is 12+ months of weekends, and you are applying *now*.

**So commit to exactly four, in this order, and start interviewing the moment they are public:**

| Sprint | Project | Why this one | Weeks |
|---|---|---|---|
| 1 | **[P16 — CUDA & GPU Performance Engineering](project-16-cuda-gpu-performance-engineering.md)** | Cheapest, fastest, and it makes every later project sharper. The market post literally says *"CUDA."* Nsight + roofline + one real kernel = you can read a GPU, not just schedule one. | 2 |
| 2 | **[P07 — GPU Batch & Gang Scheduling (+ your own Go plugin)](project-07-topology-aware-gang-scheduler.md)** | The single highest-leverage project. Runs on **kind/kwok for ~$0**. You *operate* Kueue/Volcano **and build a scheduler plugin in Go** — both verbs on the résumé. Hits the Cisco control-plane JD verbatim. | 4 |
| 3 | **[P08 — Fractional GPUs & Multi-Tenancy](project-08-fractional-gpu-dra-multitenancy.md)** | MIG · HAMi · MPS · DRA · KAI. ~$15–35 total now that MIG runs on a **single rented A100**, not a p4d. This is the "how do you get a fleet from 15% to 70% utilization" interview. | 3 |
| 4 | **[P10 — Multi-Node Training: NCCL/EFA + Goodput](project-10-fault-tolerant-training-goodput.md)** | The fabric + the reliability specialty. NCCL busbw, FSDP scaling, elastic restart, XID remediation, **goodput/MFU measured**. Frontier labs hire for exactly this. | 3–4 |

**≈12 weeks. ≈$70–150 total.** Together they cover **scheduling + fabric + GPU fluency** — the core of every JD you uploaded.

**The rule that makes this work:** a project is not "done" when it runs. It is done when the repo is public, the README carries *your* measured numbers, one post is up, and one video is recorded. **Then** you start the next one. No exceptions — the specs have hit diminishing returns; artifacts have not.

Everything below is the continuation, not the prerequisite.

---

## 2. The three tiers (16 projects)

### Foundation (P1–P6) — the platform underneath everything

| # | Project | Difficulty | Core stack |
|---|---------|-----------|------------|
| 1 | [GPU-Ready Kubernetes Platform](project-1-gpu-kubernetes-platform.md) | Medium | EKS · Terraform · GPU Operator · time-slicing · DCGM · Karpenter |
| 2 | [LLM Inference Platform](project-2-llm-inference-platform.md) | Medium-Hard | vLLM · KEDA · Argo Rollouts · k6 · SLO metrics |
| 3 | [Lakehouse on Kubernetes](project-3-lakehouse-on-kubernetes.md) | Hard | Strimzi Kafka · Debezium CDC · Spark Operator · Iceberg · Airflow · Trino |
| 4 | [Streaming RAG Platform](project-4-streaming-rag-platform.md) | Hard | Qdrant · FastEmbed · FastAPI · LangFuse · ArgoCD |
| 5 | [Distributed Training Platform](project-5-distributed-training-platform.md) | Hard | KubeRay · QLoRA/PEFT · MLflow · Kueue · spot checkpointing |
| 6 | [AI Platform Control Plane](project-6-ai-platform-control-plane.md) | Expert | CRD + kopf operator · Kyverno · Envoy Gateway · OpenCost · SLO burn rates |

### Advanced (P07–P12) — the systems that separate "runs GPUs on K8s" from "designs GPU platforms"

| # | Project | Difficulty | Core stack | Cost |
|---|---------|-----------|------------|------|
| 07 | [🎯 **GPU Batch & Gang Scheduling** — operate Kueue/Volcano, then build your own topology-aware scheduler plugin in Go](project-07-topology-aware-gang-scheduler.md) | ★★★★★ | Kueue cohorts/borrowing · Volcano · deadlock/starvation/reclaim matrix · DRA · **Go scheduler plugin** (scheduler-plugins fork) · kwok @ 1000 nodes | ~$0–10 |
| 08 | [🎯 **Fractional GPUs & Multi-Tenancy**](project-08-fractional-gpu-dra-multitenancy.md) | ★★★★☆ | time-slicing · MPS · **HAMi** (enforced memory isolation) · **MIG on a single A100** · **DRA** (GA in K8s 1.34) · **KAI Scheduler** · cost-per-tenant | ~$15–35 |
| 09 | [**Disaggregated, KV-Aware LLM Inference** + advanced gateway](project-09-disaggregated-inference-llm-d.md) | ★★★★★ | Gateway API Inference Extension (`InferencePool` v1) · EPP · **multi-LoRA** · prefix cache → chunked prefill → speculative decoding ladder · **P/D disaggregation** (llm-d/NIXL) · LMCache | ~$30–70 |
| 10 | [**Multi-Node Training: NCCL/EFA Fabric, Fault Tolerance & Goodput**](project-10-fault-tolerant-training-goodput.md) | ★★★★★ | EFA + aws-ofi-nccl · nccl-tests busbw · FSDP vs ZeRO-3 · elastic torchrun · async DCP checkpointing · XID/NPD remediation · **goodput & MFU (dense peaks)** | ~$45–100 |
| 11 | [**Petabyte-Scale Data & Feature Platform**](project-11-petabyte-data-feature-platform.md) | ★★★★☆ | Iceberg REST catalog · Flink CDC exactly-once · Celeborn shuffle · Feast · lineage | ~$10–25 |
| 12 | [**AI Fleet SRE: Observability · SLOs · FinOps · AIOps · Multi-Cluster DR**](project-12-ai-fleet-sre-finops-aiops.md) | ★★★★★ | LGTM · burn-rate SLOs · GPU-failure prediction · LLM RCA · OpenCost · **CAPI · ApplicationSets · MultiKueue · regional DR drill** | ~$5–20 |

### NVIDIA track (P13–P16) — GPUs, CUDA, and AI factories

| # | Project | Difficulty | Core stack | Cost |
|---|---------|-----------|------------|------|
| 13 | [🟩 **TensorRT-LLM + Triton Model Factory**](project-13-nvidia-tensorrt-llm-triton-factory.md) | ★★★★☆ | Phase 0 Nsight profiling · `trtllm-serve` / LLM API · quantization (FP8/INT4) · Triton · **NIM vs OSS** economics · AIPerf | ~$15–35 |
| 14 | [🟩 **NVIDIA Dynamo — the Inference OS**](project-14-nvidia-dynamo-inference-os.md) | ★★★★★ | Dynamo Frontend/Router · KVBM · **NIXL** · SLA Planner · `DynamoGraphDeployment` CRDs · Grove · vs. llm-d (P09) | ~$20–40 |
| 15 | [🟩 **NVIDIA Networking, NCCL & Cluster Validation → AI-Factory capstone**](project-15-nvidia-networking-nccl-cluster-validation.md) | ★★★★★ | EFA/libfabric on EKS · NCCL tuning · `dcgmi diag` acceptance suite · **Network Operator (on-prem IB/RoCE — honestly scoped)** · DGX/SuperPOD BOM literacy · one-command GitOps bring-up | ~$70–140 (the **only** p4d spend) |
| 16 | [🟩 **CUDA & GPU Performance Engineering**](project-16-cuda-gpu-performance-engineering.md) | ★★★★☆ | CUDA/cuDNN/NCCL literacy · **Nsight Systems/Compute** · roofline · Tensor Cores · write & optimize a real kernel | ~$5–15 |

**🎯 = GPU scheduling · 🟩 = NVIDIA track.** Numbered 16 last, but **P16 is the first thing you build** — see the sprint above.

---

## 3. Execution order (after the four-project sprint)

**Sprint:** 16 → 07 → 08 → 10. *Interview from here.*

**Then, in dependency order:** 09 (serving depth) → 13 (engines) → 14 (Dynamo) → 12 (fleet + DR) → 11 (data platform) → 15 (capstone, the one paid p4d window) — with P1–P6 filled in wherever you have gaps in the foundation.

**How they compose (the portfolio narrative):** P07/P08 schedule and partition P1's GPUs; P09 supercharges P2's serving and serves P5's adapters; P10 scales P5's training across nodes over a real fabric; P11 feeds all of it; P12 watches and federates it; P13–P15 express the whole thing in NVIDIA's production stack; P16 is the microscope you use on every one of them. It reads as **one platform that grew**, not sixteen demos.

---

## 4. Coverage map: your JDs

| JD | Hit hardest by |
|---|---|
| **Cisco AI Control Plane Eng** (Golang, CRDs/Kubebuilder, gRPC, eBPF, SLOs) | **P07** (you *write* a scheduler in Go — not just operate one), P6, P12 |
| **Cisco K8s Platform Eng – AI Infra** (AIOps, anomaly detection, Kubeflow/KServe/MLflow, RAG) | **P12** (AIOps verbatim), P09, P13, P11, P4 |
| **SentinelOne Staff / Remote K8s Platform Eng** (70+ clusters, CAPI, Cluster Mesh, MultiKueue, DR, FinOps) | **P12** (fleet + DR drill verbatim), P1, P2 |
| **GPU Neocloud AI Infra Eng** (bare-metal GPU, GPU Operator, RDMA/InfiniBand, MIG, validation) | **P15** (the whole JD), **P08** (MIG/HAMi), **P10** (fabric), P16 |
| **AWS Cloud Architect** (Terraform, EKS, networking, governance, cost) | P1, P6, P12; IaC + FinOps threaded through every project |
| Frontier-lab **training reliability** (goodput, elastic, checkpointing, XID) | **P10** — a hireable specialty on its own |

## 5. Coverage map: books & course

- **"Kubernetes for Generative AI Solutions"** — GPU nodes/Operator, autoscaling, serving, cost, security, RAG → extended far past the book by P07–P09, P12–P14.
- **"Big Data on Kubernetes"** — Spark, Kafka, Airflow, lakehouse → P3, P4, and extended by **P11** (Iceberg REST catalog, Flink CDC exactly-once, Celeborn, Feast, lineage).
- **Udemy "AI Infrastructure: Zero to Hero"** — GPU arch/CUDA/NVLink → **P16**; Nsight/TensorRT/DCGM → P16/P13; MIG/vGPU/sharing → **P08**; distributed training/FSDP/DeepSpeed/AllReduce → **P10**; K8s GPU scheduling → **P07**; Triton/NGC/serving at scale → P13/P14; MLflow/CI-CD → P5/P11; HPA/KEDA/canary/p95/p99 → P2/P09; Prometheus/Grafana/OTel → **P12**; Kafka/pipelines → P3/P11; security/IAM/mTLS → P6; cost/spot/multi-tenant → P08/P12. *Edge AI (Jetson) intentionally skipped — irrelevant to your JDs.*

**Still theory-only (be fluent, be honest):** 1000-GPU pretraining, NVLink Switch/GB200 rack-scale fabrics, real SuperPOD operations, Slurm at hyperscale. P10 (EFA), P15 (BOM/DGX literacy), and P16 (CUDA) get you as close as a personal budget allows. *"I operated the affordable analogue and studied the rest"* is a respected answer; pretending otherwise is not.

---

## 6. Cost discipline (total ≈ $180–330 for all 16 — verified July 2026)

The single expensive mistake is a **forgotten GPU node**. Every project ships a teardown script. Run it.

- **Simulate first, rent later.** P07 runs on **kwok** (1,000 fake nodes, $0). P08's DRA lab and P12's fleet phase run on **kind** ($0). Control-plane logic never needs a real GPU.
- **Small GPUs for logic, big GPUs for benchmarks.** g4dn/g5/g6 spot (~$0.30–1.20/hr) for everything except benchmarks.
- **MIG no longer needs a p4d.** A single rented A100 — **GCP `a2-highgpu-1g` spot ≈ $1.93/hr** (on-demand $3.67), Lambda 1× A100 40 GB **$1.99/hr**, or RunPod A100 80 GB **$1.39–1.49/hr** — with single-node kubeadm gives *identical* `mig-manager` hands-on. Same A100-SXM4-40GB silicon, same `nvidia.com/mig.config` workflow, same DCGM per-slice metrics. ⚠️ Watch out: third-party GCP price trackers list `a2-highgpu-1g` at $0.39–0.83/hr — **that excludes the A100 itself.**
- **p4d is reserved for P15 only** — the 8-GPU NVLink intra-node + multi-node EFA numbers genuinely require it. `p4d.24xlarge` is **~$21.96/hr on-demand** (AWS cut P4d ~33% in June 2025 — the old $32.77 figure is dead), ~$13.93/hr spot, Capacity Blocks in us-east-2/us-west-2. Share that one window with P10's multi-node drill.
- **Cheap fabric rehearsal:** 2× `g6.8xlarge` ≈ **$4.03/hr on-demand / ~$2.2/hr spot** for the pair, EFA-capable with RDMA. (Sub-8xlarge G sizes have **no** EFA; both nodes must share one AZ + placement group.)
- Spot always. Models ≤ 3B for logic. **AWS Budgets alarm at $25** before you start. **Phone timer on every A100/multi-GPU session.**

---

## 7. Build in public — the content engine (this is half the value)

You are not doing these projects quietly. Each one ships **four artifacts**, and the same work becomes your hiring funnel:

1. **A public GitHub repo** — Terraform/Helm/Makefile, `make up` / `make down`, real commit history.
2. **A README with *your measured numbers*** — busbw GB/s, tok/s, TTFT p95, MFU %, goodput %, $/tenant, scaling efficiency. Numbers are the entire differentiator; nobody can fake them.
3. **A 5–10 min demo video** — the failure and the fix, not a happy path. ("DevOps engineer builds AI infra" is a badly underserved YouTube niche.)
4. **One deep post** on the hardest problem you actually hit.

Every project file ends with a **📣 Build in public** section giving you the specific LinkedIn / X / YouTube angle for *that* project, tied to a concrete artifact.

**Cadence that compounds:** ship a repo → post the graph the same week → cut the video the week after → thread the "what surprised me" story. Two posts a week beats a monthly essay.

**What travels furthest:** the 🎯 scheduling posts (P07's gang-deadlock reproduction; the Go plugin) and the 🟩 NVIDIA posts (P08's HAMi memory-bomb demo; P16's kernel going 10× after Nsight). Those are the artifacts the market is loudly asking for right now — lead with them.

**Résumé framing:** an *"AI Platform Engineering (Independent)"* section; each project = one impact bullet (templates live in every project's *Interview ammunition* section). Anchor to your day job: *"operates multi-tenant production EKS **and** built GPU scheduling, fractional-GPU multi-tenancy, a distributed-training fabric, and an NVIDIA AI-factory reference from scratch."*

## 8. The interview narrative these unlock

> "I built and operated the systems every AI lab runs: a **GPU scheduler** (gang + topology-aware, written in Go), a **fractional-GPU multi-tenant platform** (MIG, HAMi, DRA), a **disaggregated inference plane** (KV-aware routing, multi-LoRA, SLO autoscaling), a **fault-tolerant training platform** on a real RDMA fabric (goodput and MFU measured, XID-driven auto-remediation), and the **data + observability + fleet planes** feeding, watching, and federating them — all on Kubernetes, all on NVIDIA's production stack, and I can profile a CUDA kernel to explain *why* any of it is slow."

---

## 9. What changed in this merge (July 2026)

This set consolidates two parallel advanced tracks into one corrected curriculum. Every technical claim below was re-verified against primary sources; several corrections go **further than the review that prompted them**.

- **MFU math fixed (P10).** The old "A10G ≈ 125 TFLOPS" was wrong — but not for the reason flagged. 125 TF is the **A10's dense** figure (a *different SKU*); the **A10G's official dense FP16/BF16 peak is 70 TFLOPS** (140 sparse). A100's 312 was already dense. MFU now uses **dense peaks consistently** (A100 312 · A10G 70 · L4 121 · T4 65), per the PaLM convention, with the sparse-vs-dense trap called out explicitly.
- **Scheduler scaffold fixed (P07).** No more direct `k8s.io/kubernetes` import (~31 staging `replace` directives of pain). You now fork **`kubernetes-sigs/scheduler-plugins`**, which exists precisely for out-of-tree plugins and already solves it. Added the **QueueSort caveat**: *exactly one* QueueSort plugin can be active, and all profiles on a scheduler share it (one pending queue) — so a gang-name sort re-orders **everything** on that scheduler. Correct, and stated.
- **P07 now has both verbs.** *Operate* Kueue/Volcano through a deadlock/starvation/reclaim **scenario matrix**, *then* **build** the Go plugin as the capstone.
- **MIG got 10× cheaper (P08).** Dropped the p4d assumption; MIG now runs on a **single rented A100** (~$1.4–2/hr). **p4d is reserved strictly for P15.**
- **HAMi added (P08)** — memory-isolated fractional GPUs on non-MIG cards (T4/A10G/L4). Now **CNCF Incubating** (promoted July 2026 — not Sandbox), v2.9.0. Includes the memory-bomb demo: the offender OOMs alone, the neighbor survives. Honestly hedged: it's userspace CUDA interception, so there's no *hardware* fault isolation. Also: **KAI's "fractions" are scheduling-level only** — KAI's own docs tell you to pair it with HAMi for real enforcement.
- **Inference API corrected (P09).** `InferenceModel` → `InferenceObjective` was **not** a promotion to v1: it stayed **alpha**, and moved to `llm-d.ai/v1alpha2` in June 2026. What *is* GA is **`InferencePool` at `inference.networking.k8s.io/v1`**. Manifests now pin the GA object and hedge the alpha one.
- **Multi-LoRA + the measured optimization ladder added (P09)** — and the flags were fixed: prefix caching and chunked prefill are **default-on** in vLLM's V1 engine, so the ladder benchmarks them by *disabling* and *tuning* (`--max-num-batched-tokens`), not by "enabling" them. Speculative decoding uses the current `--speculative-config` JSON.
- **Multi-cluster fleet + DR drill added (P12)** — CAPI, ApplicationSets, MultiKueue, a scripted regional failover with measured RTO/RPO. Note: **MultiKueue is beta, not GA** (the review said GA; it isn't — what went GA is the Job `.spec.managedBy` field in K8s 1.35).
- **Network Operator phase made honest (P15).** It does **not** apply to EKS: **EFA is the only RDMA fabric on AWS** (SRD/libfabric — not InfiniBand or RoCE), served by `aws-efa-k8s-device-plugin` + `aws-ofi-nccl`. The Network Operator targets **on-prem ConnectX/BlueField** hardware and is now scoped as a CRD study lab (upstream's own dev path is minikube) plus DGX/SuperPOD BOM literacy — with the BOM corrected too (**DGX H100 has no BlueField-3**; that's the B200).
- **CUDA promoted to a standalone project (P16)** and moved to the **front** of the queue; P13 gained a **Phase 0** that Nsight-profiles the engines you're about to optimize.
- **Kept:** the data platform (P11) survives intact, and training reliability (P10) is a headline, not a stretch goal.

**Superseded originals** (`00-README-advanced-track.md`, `README (2).md`, and the unpadded `project-7…15-*.md` files) are preserved in [archive/](archive/) and in git history.
