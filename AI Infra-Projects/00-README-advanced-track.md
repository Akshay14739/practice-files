# AI Infrastructure Portfolio — Advanced Track (Projects 07–15)

**Who this is for:** A senior Kubernetes/DevOps engineer (EKS, Terraform, ArgoCD, Karpenter, GitHub Actions, ELK) pivoting into **Big Data / ML Platform / AI Infrastructure** roles at frontier AI labs and AI-infra companies.

**How it relates to the first track:** Projects 01–06 (GPU-ready EKS platform, vLLM inference, lakehouse, streaming RAG, Ray/Kueue distributed training, custom operator) built the *foundation*. Projects 07–15 are the *differentiators* — the systems-level depth that separates "runs GPUs on K8s" from "designs GPU platforms."

---

## The 9 projects

| # | Project | Theme | Difficulty | Real-world analogue |
|---|---------|-------|-----------|---------------------|
| 07 | Topology-Aware Gang Scheduler (Go) | **GPU scheduling** | ★★★★☆ | The scheduler work every frontier lab does on top of vanilla K8s |
| 08 | Fractional GPUs: MIG + DRA + KAI multi-tenancy | **GPU scheduling** | ★★★★☆ | Internal GPU clouds / "neocloud" multi-tenant platforms |
| 09 | Disaggregated LLM Inference Platform (llm-d pattern) | Inference at scale | ★★★★★ | How large labs serve frontier models (prefill/decode split, KV-aware routing) |
| 10 | Fault-Tolerant Training Platform + Goodput Engineering | Training reliability | ★★★★★ | Meta's Llama-3 training ops (466 interruptions in 54 days — publicly documented) |
| 11 | Petabyte-Scale Data & Feature Platform | Big Data for ML | ★★★★☆ | Data platforms feeding training + online inference features |
| 12 | AI Fleet SRE: Observability, FinOps & AIOps Control Plane | SRE/ops | ★★★★☆ | GPU-fleet SRE teams; maps directly to the Cisco AIOps JD |
| 13 | NVIDIA TensorRT-LLM + Triton Model Optimization Factory | **NVIDIA** | ★★★★☆ | Inference performance engineering teams |
| 14 | NVIDIA Dynamo — Datacenter-Scale Inference "OS" | **NVIDIA** | ★★★★★ | NVIDIA's answer to disaggregated serving (GTC 2025+) |
| 15 | NVIDIA Networking, NCCL & Cluster Validation | **NVIDIA** | ★★★★★ | Cluster bring-up/acceptance — exactly the GPU-neocloud JD you uploaded |

## How they map to your uploaded JDs

- **Cisco AI Control Plane Engineer** (Golang, CRDs/Kubebuilder, gRPC, eBPF, SLOs, live upgrades) → P07 (Go scheduler plugins), P12 (eBPF telemetry + SLOs), plus your earlier operator project.
- **Cisco K8s Platform Engineer – AI Infra** (AIOps, anomaly detection, Kubeflow/KServe/MLflow, RAG, vector DBs) → P12 (AIOps + anomaly detection), P09/P13 (serving), P11 (pipelines).
- **Staff Kubernetes Platform Engineer** (multi-cluster fleets, ArgoCD, Karpenter, KEDA, SRE, FinOps) → P09 (multi-region cells), P12 (SLOs/FinOps), P10 (Karpenter remediation).
- **AI Infrastructure Engineer, GPU neocloud** (bare-metal GPU nodes, GPU Operator, RDMA/InfiniBand, CNI, Ceph/Rook, vCluster, validation) → P15 (the whole project), P08 (GPU Operator deep config).
- **AWS Cloud Architect** (Terraform, EKS, networking, governance, cost) → threaded through every project's IaC and FinOps sections.

## Coverage map: books + Udemy course

- **"Kubernetes for Generative AI Solutions" (Packt)** — GPU nodes/Operator, autoscaling, inference serving, cost optimization, security, RAG: extended far beyond the book by P07–P09, P12–P14.
- **"Big Data on Kubernetes" (Packt)** — Spark, Kafka, Airflow, lakehouse: extended by P11 (Iceberg REST catalog, Flink CDC exactly-once, Celeborn shuffle, feature store, lineage).
- **Udemy "Complete Guide to AI Infrastructure: Zero to Hero"** — CPU/GPU/TPU + NVLink/HBM (P13/P15), CUDA stack (P13), object storage/data lakes/Kafka (P11), distributed training PyTorch/Horovod (P10), MLOps/MLflow/CI-CD (P11/P13), Triton/TorchServe/FastAPI serving (P13/P09), Prometheus/Grafana/security/drift (P12), cost & multi-cloud (P12), edge (P14 extension).

## Recommended order & time budget

07 → 08 → 15 → 10 → 09 → 14 → 13 → 11 → 12. (Scheduling first — it's the lens for everything else; networking early because training/inference projects depend on it.)
Each project: 2–4 weekends. Total: ~4–5 months alongside a full-time job.

## Cost discipline (read before spending)

- **Simulate first**: P07 uses `kwok` (fake 1000-node clusters, $0 GPU cost). P08's DRA work runs on `kind` with the NVIDIA DRA driver in CPU-simulation mode before touching real GPUs.
- **Small GPUs for logic, big GPUs for benchmarks**: g5.xlarge/g6.xlarge (A10G/L4, ~$1/hr) for all control-plane logic; time-box p4d.24xlarge (8×A100, ~$32/hr on-demand — use capacity blocks/spot) to 2–4 hr benchmark windows only (P10/P15).
- Every project ends with a **teardown script**. Run it. Set an AWS budget alarm at $50 before starting.

## The interview narrative these unlock

"I built and operated the four systems every AI lab runs: a **GPU scheduler** (gang + topology), a **disaggregated inference plane** (KV-aware routing, SLO autoscaling), a **fault-tolerant training platform** (goodput measured, auto-remediation), and the **data + observability planes** feeding and watching them — all on Kubernetes, all with NVIDIA's production stack (GPU Operator, MIG, DCGM, TensorRT-LLM, Triton, Dynamo, NCCL over EFA)."

Versions noted in each file were current as of early 2026 — these ecosystems move monthly, so always check the linked upstream repos for the latest release before installing.
