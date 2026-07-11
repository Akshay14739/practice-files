# AI Infrastructure Engineering Portfolio — Roadmap & Index

**Goal:** DevOps/SRE (EKS, Terraform, ArgoCD, Karpenter) → **AI Infrastructure / ML Platform Engineer** at a top AI company.
**Method:** two books for concepts + **15 build-in-public projects** for proof, in three tiers.

---

## 1. Honest answer: are the two books enough?

**No — they're the right ~65% (concepts), and these projects are the other 35% (operated systems).** Every JD you collected hires on systems you've *run*, not chapters you've read. The books give vocabulary and architecture; the projects give evidence. Interviews at AI companies test the second.

## 2. The three tiers

- **Foundation (P1–P6):** the core platform — GPU orchestration, LLM serving, data lakehouse, RAG, training, and a control plane. Start here.
- **Advanced (P7–P12):** tougher, more elaborate systems — **two dedicated GPU-scheduling projects**, multi-node RDMA training, frontier inference, AIOps, and multi-cluster fleet ops.
- **NVIDIA track (P13–P15):** GPUs, CUDA, and AI factories — the vendor stack and hardware fluency the market is shouting about.

### Foundation tier

| # | Project | Difficulty | Core stack |
|---|---------|-----------|------------|
| 1 | [GPU-Ready Kubernetes Platform](project-1-gpu-kubernetes-platform.md) | Medium | EKS · Terraform · GPU Operator · time-slicing · DCGM · Karpenter |
| 2 | [LLM Inference Platform](project-2-llm-inference-platform.md) | Medium-Hard | vLLM · KEDA · Argo Rollouts · k6 · SLO metrics |
| 3 | [Lakehouse on Kubernetes](project-3-lakehouse-on-kubernetes.md) | Hard | Strimzi Kafka · Debezium CDC · Spark Operator · Iceberg · Airflow · Trino |
| 4 | [Streaming RAG Platform](project-4-streaming-rag-platform.md) | Hard | Qdrant · FastEmbed · FastAPI · LangFuse · ArgoCD |
| 5 | [Distributed Training Platform](project-5-distributed-training-platform.md) | Hard | KubeRay · QLoRA/PEFT · MLflow · Kueue · spot checkpointing |
| 6 | [AI Platform Control Plane](project-6-ai-platform-control-plane.md) | Expert | CRD + kopf operator · Kyverno · Envoy Gateway · OpenCost · SLO burn rates |

### Advanced tier (tougher; includes the 2 GPU-scheduling projects)

| # | Project | Difficulty | Core stack |
|---|---------|-----------|------------|
| 7 | [🎯 GPU Batch Scheduling: Kueue vs Volcano, Gang, Preemption, DRA](project-7-gpu-batch-scheduling.md) | Expert | Kueue cohorts/borrowing · Volcano · gang scheduling · preemption · **DRA** · frag analyzer |
| 8 | [🎯 GPU Sharing & Partitioning at Fleet Scale](project-8-gpu-sharing-partitioning-fleet.md) | Expert | **MIG** (real A100) · MPS · **HAMi** fractional · **KAI Scheduler** · cost-per-tenant |
| 9 | [Multi-Node Distributed Training: NCCL, EFA, FSDP](project-9-multinode-training-nccl-efa.md) | Expert | EFA/RDMA · nccl-tests · aws-ofi-nccl · Kubeflow PyTorchJob · FSDP · DeepSpeed ZeRO-3 |
| 10 | [Advanced Inference: KV-Aware Routing, Multi-LoRA, Disaggregation](project-10-advanced-inference-gateway.md) | Expert | Gateway API Inference Extension · multi-LoRA · prefix cache · speculative decode · P/D disagg |
| 11 | [AIOps & Full-Stack Observability](project-11-aiops-observability-platform.md) | Expert | LGTM stack · anomaly detection · predictive GPU failure · LLM RCA agent · burn-rate SLOs |
| 12 | [Multi-Cluster Global Platform: Fleet, DR, Arbitrage](project-12-multicluster-global-platform.md) | Expert | Cluster API · ArgoCD ApplicationSets · Cluster Mesh · **MultiKueue** · regional DR drill |

### NVIDIA track (the LinkedIn post's thesis: GPUs, CUDA, AI factories)

| # | Project | Difficulty | Core stack |
|---|---------|-----------|------------|
| 13 | [🟩 CUDA & GPU Performance Engineering](project-13-cuda-gpu-performance-engineering.md) | Hard | CUDA/cuDNN/NCCL literacy · Nsight Systems/Compute · roofline · Tensor Cores · TensorRT · a real kernel |
| 14 | [🟩 The NVIDIA Inference Stack](project-14-nvidia-inference-stack.md) | Expert | Triton · TensorRT-LLM engines · NIM · Dynamo · model-analyzer · vendor-vs-OSS |
| 15 | [🟩 Build an "AI Factory": NVIDIA Reference Architecture](project-15-nvidia-ai-factory-reference.md) | Expert | GPU Operator + validator · **Network Operator** (RDMA/GPUDirect) · NIM Operator · MIG tenancy · NeMo loop · BOM |

**🎯 = GPU scheduling · 🟩 = NVIDIA track.** Two GPU-scheduling projects (7, 8) and three NVIDIA projects (13–15) as requested.

## 3. Execution order & timeline

**Linear path:** 1 → 2 → 3 → 4 → 5 → 6, then 7 → 8 → 9 → 10 → 11 → 12, then 13 → 14 → 15.

**Smarter interleaving** (recommended): the NVIDIA-track P13 (CUDA/Nsight) pairs naturally right after P1 — do it early, it makes P8/P9/P14 sharper. P7 (scheduling) slots right after P5. Suggested real order: **1 → 13 → 2 → 3 → 4 → 5 → 7 → 6 → 8 → 9 → 10 → 14 → 11 → 12 → 15.**

**Calendar (weekends-only):** Foundation ≈ 4–5 months; Advanced ≈ 4–6 months; NVIDIA track ≈ 2.5–3 months. You do **not** need all 15 to start interviewing — after P4 you're credible for platform roles; after P7–P8 you're credible for *GPU-scheduling* roles specifically; after P13–P15 you're credible for NVIDIA-ecosystem/GPU-cloud roles. Pick the tier that matches the job.

**How the tiers compose (the portfolio narrative):** the advanced projects deliberately build on the foundation — P7/P8 schedule and partition P1's GPUs; P9 scales P5's training across nodes; P10 supercharges P2's serving and serves P5's adapters; P11 observes everything; P12 federates it all; and P13–P15 express the whole thing in NVIDIA's stack. It reads as *one platform that grew*, not fifteen demos.

## 4. Coverage maps

**Against your five JDs (foundation + advanced + NVIDIA):**

| JD | Hit hardest by |
|---|---|
| AWS Cloud Architect (Terraform/EKS/governance/cost) | P1, P6, P12 (cost governance), all IaC |
| Cisco K8s Platform Eng – AI Infra (AIOps, MLOps, RAG, vector DBs) | **P11** (AIOps verbatim), P4, P5, P2, P10 |
| Cisco AI Control Plane Eng (CRDs/operators/Kubebuilder, APIs, SLO, GPU) | **P6** front-to-back, P7, P1 |
| Remote K8s Platform Eng (CAPI, multi-tenancy, GitOps, Cluster Mesh, LGTM, DR, FinOps) | **P12** (CAPI/mesh/DR verbatim), P11 (LGTM), P6, P7 |
| SentinelOne Staff (70+ clusters, multi-region EKS/GKE, Karpenter/KEDA/Cilium) | **P12** (fleet), P1, P2, P11 |
| GPU Neocloud AI Infra Eng (GPU Operator, CNI, RDMA/InfiniBand, MIG, validated vCluster) | **P15** (the whole JD), P8 (MIG), P9 (RDMA), P1, P13 |

**GPU-scheduling depth (the two 🎯 projects) maps to:** every training-platform and multi-tenant-allocation requirement, plus the NVIDIA-cert "MIG, GPU sharing and isolation, vGPU, Kubernetes scheduling" objectives — P7 (batch/gang/quota/DRA) and P8 (MIG/MPS/HAMi/KAI fractional) together cover scheduling *and* partitioning end to end.

**Against the books:** Big Data ch. 1–10 → P3; ch. 11 → P4; ch. 12 → P1/P6. GenAI ch. 1–3 → P1/P13; ch. 4–5 → P2/P4/P10; ch. 6–8 → P1/P2/P6/P8; ch. 9 → P6/P12; ch. 10 → P1/P2/P10; ch. 11 → P5/P9; ch. 12 → P2/P4/P14; ch. 13 → P6/P12 (DR); ch. 14 → use Claude/Copilot while building.

**Against the Udemy syllabus (now fully covered):** GPU architecture/CUDA/NVLink → **P13**; Nsight/DLProf/TensorRT/DCGM → P13/P14; MIG/vGPU/GPU sharing → **P8**; distributed training/FSDP/DeepSpeed/AllReduce → **P9**; Kubernetes scheduling of GPUs → **P7**; Triton/NGC/model serving at scale → **P14**; MLflow/CI-CD/registries → P5; HPA/KEDA/canary/p95/p99 → P2/P10; Prometheus/Grafana/OTel/observability → **P11**; Kafka/databases/pipelines → P3/P4; security/IAM/mTLS/rate-limiting → P6; cost/spot/multi-tenant → P8/P12; RAG/LLM infra → P4/P10; edge AI (Jetson) → intentionally skipped (irrelevant to your JDs).

**Still theory-only (be fluent, be honest):** 1000-GPU pretraining, NVLink Switch/GB200 fabrics at rack scale, real SuperPOD operations, Slurm/Borg at hyperscale. P9 (EFA), P13 (CUDA/Nsight), and P15 (BOM/DGX literacy) get you as close as a personal budget allows — and interviewers respect "operated the affordable analogue, studied the rest."

## 5. Build-in-public playbook

Each project ships: a **GitHub repo**, a **README with your measured numbers** (busbw Gb/s, tok/s, TTFT p95, $/tenant, scaling efficiency), a **5–10 min demo video**, and **one blog/LinkedIn post** on the hardest problem. 15 projects → a full channel + a portfolio site + a body of writing, same effort as doing the work quietly. The 🎯 scheduling and 🟩 NVIDIA posts will travel furthest — that's exactly the content the market (and that LinkedIn post) is asking for.

Resume framing: an "AI Platform Engineering (Independent)" section; each project = one impact bullet (templates in every project's *Interview ammunition*). Anchor to Harman: *"operates multi-tenant production EKS **and** built GPU scheduling, distributed training, and an NVIDIA AI-factory reference from scratch."*

## 6. Cost discipline (total budget ≈ $120–220 for all 15)

Foundation ≈ $60–120; advanced adds the pricier windows — **A100 for P8 MIG** (~$1.1–1.5/hr, few hours), **2× EFA nodes for P9** (~$5–8/session), **2-GPU windows for P10/P14/P15**; NVIDIA track mostly rides existing GPU sessions. Rules unchanged: GPU nodes exist **only during scripted test sessions** (`make down` + Karpenter consolidation in every repo), control/scheduling planes on **kind** (free — P7 and most of P12 cost $0), spot always, models ≤ 3B, AWS Budgets alert at $25, **phone timer on every A100/multi-GPU session.** The only expensive mistake is a forgotten node — the Makefiles exist so you never make it.
