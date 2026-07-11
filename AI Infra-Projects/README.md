# AI Infrastructure Engineering Portfolio — Roadmap & Index

**Goal:** DevOps/SRE (EKS, Terraform, ArgoCD, Karpenter) → **AI Infrastructure / ML Platform Engineer** at a top AI company.
**Method:** two books for concepts + these six build-in-public projects for proof.

---

## 1. Honest answer: are the two books enough?

**No — but they're the right 65%.** The books give you the *vocabulary and architecture* (that's why the field guides exist). What they don't give you, and what every JD you collected demands, is **operated systems**:

| Gap (from your 5 JDs + the AI-stack breakdown + the Udemy syllabus) | Closed by |
|---|---|
| GPU orchestration hands-on: GPU Operator, device plugin, time-slicing/MIG, DCGM, XID errors | **P1** |
| Real LLM serving: vLLM, continuous batching/KV cache, TTFT & p95/p99, KEDA on queue depth, canary | **P2** |
| Data pipelines in anger: Kafka/Strimzi, Spark-on-K8s, Airflow KubernetesExecutor, Iceberg, Trino | **P3** |
| RAG systems + vector DBs at scale, LLM observability (tokens/cost/traces), GitOps delivery | **P4** |
| Distributed training ops: Ray, QLoRA/FSDP concepts, MLflow registry, checkpoints, gang scheduling | **P5** |
| Control-plane engineering: CRDs, operator code, multi-tenancy, gateway, FinOps, SLOs, runbooks | **P6** |
| Python (and a Go bridge) for infra tooling | P3–P6 (code-heavy) |

Books = you can *talk*. Projects = you can *do*. Interviews at AI companies test the second.

## 2. The six projects

| # | Project | Difficulty | Core stack | Time |
|---|---------|-----------|------------|------|
| 1 | [GPU-Ready Kubernetes Platform](project-1-gpu-kubernetes-platform.md) | Medium | EKS · Terraform · GPU Operator · time-slicing · DCGM · Karpenter | 2–3 wknds |
| 2 | [LLM Inference Platform](project-2-llm-inference-platform.md) | Medium-Hard | vLLM · KEDA · Argo Rollouts · k6 · SLO metrics | 2–3 wknds |
| 3 | [Lakehouse on Kubernetes](project-3-lakehouse-on-kubernetes.md) | Hard | Strimzi Kafka · Debezium CDC · Spark Operator · Iceberg · Airflow · Trino | 3–4 wknds |
| 4 | [Streaming RAG Platform](project-4-streaming-rag-platform.md) | Hard | Qdrant · FastEmbed · FastAPI · LangFuse · ArgoCD | 3 wknds |
| 5 | [Distributed Training Platform](project-5-distributed-training-platform.md) | Hard | KubeRay · QLoRA/PEFT · MLflow · Kueue · spot checkpointing | 3 wknds |
| 6 | [AI Platform Control Plane (capstone)](project-6-ai-platform-control-plane.md) | Expert | CRD + kopf operator · Kyverno · Envoy Gateway · OpenCost · SLO burn rates | 4–6 wknds |

**Execution order:** 1 → 2 → 3 → 4 → 5 → 6. P1–P2 are one arc (platform → serving). P3–P4 are the data arc (pipelines → RAG). P5 adds training. P6 composes everything into a product. Realistic calendar at weekends-only pace: **5–7 months** — and you can start interviewing credibly after P4.

## 3. Coverage maps

**Against your five JDs:**

| JD | Hit hardest by |
|---|---|
| AWS Cloud Architect (Terraform/EKS/governance/cost) | P1, P6 (FinOps), all IaC |
| Cisco K8s Platform Eng – AI Infra (AIOps, MLOps tools, RAG, vector DBs) | P3 (Airflow/MLflow-adjacent), P4 (RAG/vector), P5 (MLflow), P2 |
| Cisco AI Control Plane Eng (CRDs/operators/Kubebuilder, APIs, SLO, GPU) | **P6** front-to-back, P1 |
| Remote K8s Platform Eng (multi-tenancy, GitOps, Kyverno, FinOps, SRE docs) | P6, P4 (ArgoCD), P1 |
| GPU Neocloud AI Infra Eng (GPU Operator, CNI/storage, bare-metal-adjacent) | P1, P2; RDMA/InfiniBand = interview-theory from the stack doc |

**Against the books:** Big Data on K8s ch. 1–10 → P3; ch. 11 → P4; ch. 12 → P1/P6. GenAI on K8s ch. 1–3 → P1; ch. 4–5 → P2/P4; ch. 6–8 → P1/P2/P6; ch. 9 → P6; ch. 10 → P1/P2; ch. 11 → P5; ch. 12 → P2/P4; ch. 13 → P6 (DR); ch. 14 → use Claude/Copilot *while building* and say so.

**Against the Udemy syllabus:** GPU architecture/CUDA/NVLink (P1 + theory), Docker/K8s/Helm (all), distributed training/FSDP/DeepSpeed (P5), MLflow/CI-CD/registries (P5), FastAPI/Triton/TensorRT serving, HPA/KEDA, canary/blue-green, p95/p99 (P2/P4), Prometheus/Grafana/OTel-style tracing (P1/P2/P4), Kafka streaming + databases (P3/P4), security/IAM/mTLS/rate-limiting (P6), cost/spot/multi-tenant allocation (P1/P5/P6), RAG/LLM infra (P2/P4/P5). Edge AI (Jetson/TF-Lite) is the one syllabus area intentionally skipped — irrelevant to your target JDs.

**Theory-only topics to study alongside (no home lab can provide them):** InfiniBand/RDMA/NVLink fabrics, MIG on real A100/H100, Slurm vs K8s for training, Borg lineage, tensor/pipeline parallelism at 1000-GPU scale. You have the write-ups; be fluent, be honest that it's studied not operated — interviewers respect that.

## 4. Build-in-public playbook (this is half the value)

Each project ships four artifacts: **GitHub repo** (this structure, real commits), **README with your measured numbers** (tok/s, p95, $/tenant), **a 5–10 min demo video** (feeds your YouTube goal — "DevOps engineer builds AI infra" is an underserved niche), **one LinkedIn/blog post** on the hardest problem you hit. Six projects → six videos → a channel *and* a portfolio, same effort.

Resume framing: create an "AI Platform Engineering (Independent)" section; each project = one impact bullet (templates are in each project's *Interview ammunition* section). Pair with your Harman EKS work — "runs multi-tenant EKS in production *and* built an LLM platform end-to-end" is precisely the profile these JDs describe.

## 5. Cost discipline (total budget: roughly $60–120 for everything)

Rules: GPU nodes exist **only during test sessions** (Karpenter consolidation + `make down` in every repo); develop control planes on **kind** (free); spot always; models ≤ 3B; AWS Budgets alert at $25. The most expensive mistake is a forgotten g5 node — the Makefiles exist so you never make it.
