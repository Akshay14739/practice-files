# 🛠️ Resources Required — Hands-On Kit for the Tier-1 & Tier-2 AI-Infra Projects
### Everything you need to *procure* — accounts, cloud, GPUs, local tools — with the exact instance types, prices (July 2026), and where to get each. Read this before spending a rupee.

> **The one rule that keeps this affordable:** GPU nodes exist **only during scripted benchmark sessions**. Every project ships a teardown/`make down`. Set an **AWS Budgets alarm at $25** and a **phone timer on every GPU session** before you start. Total realistic spend for all six Tier-1/Tier-2 builds is **~$120–220** — most of it is a handful of hours of spot GPU time, and two of the four Tier-1 projects cost essentially **$0**.
>
> **Two cost realities you must internalize up front:**
> 1. **MIG (hardware GPU partitioning) does not exist on any AWS G instance.** It needs A100/A30/Hopper/Blackwell silicon. On AWS that means p4d (~$22/hr) — *don't*. Rent **one single-A100** off-AWS (GCP/Lambda/RunPod, ~$1.4–2/hr) for a 2–3 hr scripted session instead. This is the single most important money decision in the whole plan.
> 2. **Project-16 (CUDA) can be ~$0** if you own a laptop/desktop with **any NVIDIA RTX GPU** — all the Nsight profiling, roofline, and mixed-precision work runs locally. Only cloud if you have no NVIDIA GPU.

---

## 0. The universal kit — get these once, they serve every project

### 0.1 — Accounts to create (all free to open)

| Account | Why every project needs it | Where | Cost |
|---|---|---|---|
| **AWS account** | EKS clusters, GPU EC2, ECR, IAM, Route 53 — the substrate for P1, P2, P6, P08, P10-train, P09 | [aws.amazon.com](https://aws.amazon.com/) → Create account | Free to open; pay-per-use. **You already have this from Harman-style work.** |
| **Hugging Face account** | Download model weights (Llama gated, Qwen/Mistral open) for vLLM/training; the `HF_TOKEN` | [huggingface.co/join](https://huggingface.co/join) → Settings → Access Tokens | Free |
| **GitHub account** | Fork `scheduler-plugins` (P07), build-in-public repos, GitOps source | [github.com](https://github.com/) | Free |
| **NVIDIA NGC account** | Pull `nvcr.io` containers (CUDA samples, GPU Operator images, Triton, NIM) | [ngc.nvidia.com](https://ngc.nvidia.com/) → Sign up → generate API key | Free |
| **Docker Hub** (optional) | Push your own images if not using ECR only | [hub.docker.com](https://hub.docker.com/) | Free tier |
| **One non-AWS GPU cloud** (for the A100/MIG session — pick ONE) | The only way to touch MIG without a $22/hr p4d | see §0.4 | pay-per-hour |

### 0.2 — AWS quota you MUST request *before* you start (this bites people)

New/low-usage AWS accounts have a **GPU vCPU quota of 0** for the relevant families. Request increases **a week ahead** (approval can take 24–48h):

| Service Quota to raise | For which instances | Ask for | Where |
|---|---|---|---|
| **Running On-Demand G and VT instances** (vCPUs) | g4dn / g5 / g6 (T4/A10G/L4) | ≥ 16 vCPUs (one g4dn.xlarge = 4; g5.12xlarge = 48) | [Service Quotas console](https://console.aws.amazon.com/servicequotas/) → EC2 → search "G and VT" |
| **All G and VT Spot Instance Requests** (vCPUs) | spot G-family (what you'll actually use — cheaper) | ≥ 48 vCPUs | Service Quotas → EC2 → "Spot Instance Requests" |
| **Running On-Demand P instances** (only if you ever touch p4d — you mostly won't) | p4d | leave at 0 unless doing P15 | — |

> Verify with: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA` (G/VT on-demand). **Do this in Week 0 — a rejected GPU launch at project time costs you a weekend.**

### 0.3 — Local tools to install (your laptop/workstation)

| Tool | Used by | Install |
|---|---|---|
| **AWS CLI v2** | all AWS projects | [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| **kubectl** | all | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| **Helm** | P1, P2, P6, P08, P10 (charts) | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |
| **Terraform** ≥1.7 | P1 (and its cluster reused by P2/P6) | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| **eksctl** | EKS nodegroup ops | [eksctl.io/installation](https://eksctl.io/installation/) |
| **Docker Desktop / Engine** | build images, run kind | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **kind** (Kubernetes-in-Docker) | **P07 (free), P08 DRA lab, P6 dev** | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/) |
| **kwok** (fake kubelets) | **P07 1,000-node sim (free)** | [kwok.sigs.k8s.io](https://kwok.sigs.k8s.io/) |
| **Go** ≥1.22 | **P07 scheduler plugin** | [go.dev/dl](https://go.dev/dl/) — do [Tour of Go](https://go.dev/tour/) first |
| **Python 3.11+** + pip/venv | P2, P6, P16, P10, P08 tools | [python.org](https://www.python.org/downloads/) — see [Ladder 03](03-python-from-zero-for-both-books.md) |
| **k6** (load testing) | **P2, P09** | [k6.io/docs/get-started/installation](https://k6.io/docs/get-started/installation/) |
| **jq / yq** | JSON/YAML wrangling everywhere | [jqlang.org](https://jqlang.org/) · [github.com/mikefarah/yq](https://github.com/mikefarah/yq) |
| **NVIDIA driver + CUDA Toolkit + Nsight** (only if using a local RTX for P16) | **P16 free path** | [developer.nvidia.com/cuda-downloads](https://developer.nvidia.com/cuda-downloads) · [Nsight Systems](https://developer.nvidia.com/nsight-systems) · [Nsight Compute](https://developer.nvidia.com/nsight-compute) |
| **kubebuilder** (Tier-2) | P6 operator | [book.kubebuilder.io/quick-start](https://book.kubebuilder.io/quick-start.html) |

### 0.4 — Non-AWS GPU providers (rent ONE for the A100/MIG session — Tier 2 only)

MIG (P08 centerpiece) needs A100-class silicon. Rent a **single A100** for a 2–3 hr scripted session (~$4–8 total). Pick whichever you can sign up for fastest:

| Provider | Instance | A100 price (July 2026) | Notes | Link |
|---|---|---|---|---|
| **Lambda Labs** (recommended, simplest) | 1× A100 40GB | **$1.99/hr** on-demand | Cleanest UX; per-second billing; the old "$1.29" quotes are obsolete | [lambda.ai/service/gpu-cloud](https://lambda.ai/service/gpu-cloud) |
| **RunPod** | A100 80GB | $1.39–1.49/hr Secure; ~$0.89/hr Community (interruptible) | 80GB → MIG profiles are `1g.10gb…7g.80gb` (names differ from 40GB) | [runpod.io](https://www.runpod.io/) |
| **GCP** `a2-highgpu-1g` | 1× A100 40GB | ~$3.67/hr on-demand, **~$1.93/hr spot** | ⚠️ trackers quoting $0.39–0.83 **exclude the GPU** — confirm the A100 is in the price | [cloud.google.com/compute/gpus-pricing](https://cloud.google.com/compute/gpus-pricing) |
| **Vast.ai** (cheapest, marketplace) | varies (A100/H100) | often < $1/hr interruptible | Marketplace — variable reliability; fine for a scripted MIG session | [vast.ai](https://vast.ai/) |

> **What you're NOT paying for:** p4d.24xlarge (8× A100) is ~$22/hr on-demand. The single-A100 spot box is ~**1/11th the cost for an identical MIG lab** (MIG behavior is per-GPU — one A100 rehearses everything except heterogeneous multi-GPU configs). Reserve p4d strictly for a hypothetical future P15.

---
---

# TIER 1 — the four portfolio projects (~$40–70 total, two are ~$0)

## P1 — [GPU-Ready Kubernetes Platform](../project-1-gpu-kubernetes-platform.md)  ·  the substrate
**Cost while running:** ~$0.20–0.55/hr · **Total:** ~$10–20 (a few teardown-disciplined sessions)

| Resource | Exact spec | Where / how |
|---|---|---|
| **AWS EKS cluster** | via Terraform (`terraform-aws-modules/eks`), K8s 1.31, small `t3.medium` system nodegroup | You provision it (repo's `terraform/`) |
| **GPU node (Karpenter-provisioned)** | **`g4dn.xlarge` spot** (1× **T4**, 16GB) — cheapest; `g5.xlarge` (A10G) optional | Karpenter buys it on demand; NodePool caps `nvidia.com/gpu: 2` |
| **NVIDIA GPU Operator** | Helm chart from NGC | [helm.ngc.nvidia.com/nvidia](https://catalog.ngc.nvidia.com/orgs/nvidia/helm-charts/gpu-operator) |
| **kube-prometheus-stack** | Prometheus + Grafana (Helm) | [github.com/prometheus-community/helm-charts](https://github.com/prometheus-community/helm-charts) |
| **DCGM dashboard** | Grafana dashboard **ID 12239** | [grafana.com/grafana/dashboards/12239](https://grafana.com/grafana/dashboards/12239) |
| **CUDA test image** | `nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0` | NGC (needs NGC login) |
| Local tools | Terraform, kubectl, Helm, eksctl, AWS CLI | §0.3 |

**Reused by:** P2 (needs this cluster), P6 (GPU demos), P08 (time-slicing/HAMi pools).

---

## P16 — [CUDA & GPU Performance Engineering](../project-16-cuda-gpu-performance-engineering.md)  ·  cheapest, highest fluency/hr
**Cost:** **< $15 total** — or **$0** if you own an NVIDIA RTX laptop/desktop · Do in **parallel with P1**

| Resource | Exact spec | Where / how |
|---|---|---|
| **A GPU to profile — pick one path** | | |
| → *Free path* | **any local NVIDIA RTX** (2060/3060/4070/etc.) — all Nsight/roofline/AMP work runs on it | your own machine |
| → *Cloud path* | **`g4dn.xlarge` spot (T4)** ~$0.16–0.25/hr; Tensor-Core comparisons nicer on **`g5.xlarge` (A10G)** ~$0.40/hr | AWS (a couple of hours per session) |
| **CUDA Toolkit** (nvcc, for the vecadd/matmul kernels) | 12.x matching your driver | [developer.nvidia.com/cuda-downloads](https://developer.nvidia.com/cuda-downloads) |
| **Nsight Systems** (`nsys` — timeline profiler) | latest | [developer.nvidia.com/nsight-systems](https://developer.nvidia.com/nsight-systems) |
| **Nsight Compute** (`ncu` — kernel profiler) | latest | [developer.nvidia.com/nsight-compute](https://developer.nvidia.com/nsight-compute) |
| **PyTorch** (+ torch-tensorrt for Phase 5) | CUDA build matching your toolkit | [pytorch.org/get-started](https://pytorch.org/get-started/locally/) · [torch-tensorrt](https://github.com/pytorch/TensorRT) |
| **GPU datasheets** (dense-vs-sparse peaks) | T4/A10G/L4/A100 | [NVIDIA T4](https://www.nvidia.com/en-us/data-center/tesla-t4/) · [A10](https://www.nvidia.com/en-us/data-center/products/a10-gpu/) · [L4](https://www.nvidia.com/en-us/data-center/l4/) · [A100](https://www.nvidia.com/en-us/data-center/a100/) |

> **No standing infra — pure compute sessions.** Provision → run scripted benchmarks → destroy the instant numbers are captured. Set a billing alarm anyway (a forgotten `g5` = ~$290/month).

---

## P07 — [Topology-Aware Gang Scheduler (Go)](../project-07-topology-aware-gang-scheduler.md)  ·  the differentiator, ~$0
**Cost:** **~$0–10** (kind + kwok are free; optional real-GPU validation only) · **Doesn't need P1 finished**

| Resource | Exact spec | Where / how |
|---|---|---|
| **kind** cluster (local) | 1 control-plane + 3 workers, GPUs **faked** via `kubectl patch --subresource=status` | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/) — runs on your laptop |
| **kwok** | fake kubelets → **1,000 fake 8-GPU nodes** on a laptop | [kwok.sigs.k8s.io](https://kwok.sigs.k8s.io/) |
| **Go** ≥1.22 | for the scheduler plugin | [go.dev/dl](https://go.dev/dl/) + [Tour of Go](https://go.dev/tour/) (do first — you're new to Go) |
| **scheduler-plugins fork** | fork of `kubernetes-sigs/scheduler-plugins`, `release-1.34` branch | [github.com/kubernetes-sigs/scheduler-plugins](https://github.com/kubernetes-sigs/scheduler-plugins) |
| **Kueue** | Helm/manifest install (operate scenario matrix) | [kueue.sigs.k8s.io](https://kueue.sigs.k8s.io/) |
| **Volcano** | Helm chart | [volcano.sh](https://volcano.sh/) · [github.com/volcano-sh/volcano](https://github.com/volcano-sh/volcano) |
| **Python kubernetes client** (`gpu_frag.py`) | `pip install kubernetes` | [github.com/kubernetes-client/python](https://github.com/kubernetes-client/python) |
| *Optional* real-GPU validation | 2× `g5.12xlarge` for ~2 hr (~$10) — proves AWS topology labels end-to-end | AWS (skippable) |

> **The whole build is free** except the optional final validation. This is the project to lean into hardest for the Cisco "Golang + scheduler internals" role — no GPU spend required to have the strongest artifact.

---

## P2 — [LLM Inference Platform (vLLM)](../project-2-llm-inference-platform.md)  ·  serving, the core thing
**Cost:** ~$0.20–0.60/hr · **Total:** ~$15–25 · **Needs P1's cluster**

| Resource | Exact spec | Where / how |
|---|---|---|
| **P1 cluster** | GPU Operator + Prometheus + Karpenter already running | from P1 |
| **GPU node** | **`g4dn.xlarge` spot (T4 16GB)** for a 1.5B model; **`g5.xlarge` (A10G 24GB)** for a 7B model | Karpenter |
| **Model weights** | `Qwen/Qwen2.5-1.5B-Instruct` or `TinyLlama-1.1B` (T4); `mistralai/Mistral-7B-Instruct-v0.3` (A10G) | [huggingface.co](https://huggingface.co/) (needs `HF_TOKEN`; Llama is gated → request access) |
| **vLLM** | image `vllm/vllm-openai:v0.8.5` (check latest) | [docs.vllm.ai](https://docs.vllm.ai/) · [github.com/vllm-project/vllm](https://github.com/vllm-project/vllm) |
| **KEDA** | Helm (`kedacore/keda`) — autoscale on Prometheus queue depth | [keda.sh](https://keda.sh/) |
| **Argo Rollouts** | canary gated on p95 | [argoproj.github.io/argo-rollouts](https://argoproj.github.io/argo-rollouts/) |
| **k6** | load-test ramp (10→30 VUs) | [k6.io](https://k6.io/) |
| **gp3 PVC** (50Gi) | HF weight cache — never re-download | EBS CSI (from course/P1) |

---
---

# TIER 2 — the strong-tier projects (~$90–150 total; start only once interviewing off Tier 1)

## Fractional GPU — [P8 sharing/partitioning](../project-8-gpu-sharing-partitioning-fleet.md) + [P08 DRA depth](../project-08-fractional-gpu-dra-multitenancy.md)
**Cost:** ~$15–35 (spot G-family + **one 2–3 hr single-A100 rental ≈ $4–8 for MIG**)

| Resource | Exact spec | Where / how |
|---|---|---|
| **Time-slicing / MPS pool** | `g5.xlarge` / `g5` spot (**A10G**) — 4 of the 5 sharing modes | AWS (rides P1 economics) |
| **HAMi fractional pool** | `g4dn` (**T4**) — software mem/SM caps on any NVIDIA GPU | HAMi: [github.com/Project-HAMi/HAMi](https://github.com/Project-HAMi/HAMi) (CNCF Incubating) |
| **Whole-GPU / DRA pool** | `g6` (**L4**) | — |
| **KAI Scheduler** | NVIDIA's fractional scheduler | [github.com/NVIDIA/KAI-Scheduler](https://github.com/NVIDIA/KAI-Scheduler) |
| **Kueue** | quota/fair-share | [kueue.sigs.k8s.io](https://kueue.sigs.k8s.io/) |
| **DRA driver (NVIDIA)** | `k8s-dra-driver-gpu` — needs **K8s ≥1.34 (GA)** or 1.32+ (beta gates); start on **kind** free | [github.com/NVIDIA/k8s-dra-driver-gpu](https://github.com/NVIDIA/k8s-dra-driver-gpu) · [example driver](https://github.com/kubernetes-sigs/dra-example-driver) |
| ⭐ **MIG — the one thing AWS G can't do** | **1× A100** (40GB → `1g.5gb`…`7g.40gb` profiles), single-node `kubeadm`, 2–3 hr scripted session | **Lambda / RunPod / GCP** — §0.4. Path A: `kubeadm init` on the rented VM → GPU Operator with mig-manager |

> **MIG hardware requirement (memorize):** A100 / A30 / Hopper (H100/H200) / Blackwell (B200) — **never** T4/A10G/L4/L40S. Restore whole-GPU mode with `nvidia.com/mig.config=all-disabled`, destroy the A100 box within 2–3 hrs.

---

## P10-train — [Fault-Tolerant Training + Goodput/MFU](../project-10-fault-tolerant-training-goodput.md)
**Cost:** ~$45–100 (the priciest Tier-2 — multi-node EFA fabric sessions)

| Resource | Exact spec | Where / how |
|---|---|---|
| **EFA-capable GPU pair (fabric)** | **2× `g6.8xlarge` spot** (1× **L4** + EFA-with-RDMA each, ~$2.2/hr the pair) — recommended | AWS; **must be `.8xlarge`+** (smaller G sizes have **no EFA**), same AZ/subnet, Karpenter `gpu-efa` NodePool |
| → budget alt | 2× `g4dn.8xlarge` (T4+EFA, no RDMA-read, ~$0.75/hr each spot) or 2× `g5.8xlarge` (A10G) | AWS |
| **EFA** (Elastic Fabric Adapter) | free; the low-latency NIC for NCCL | [aws.amazon.com/hpc/efa](https://aws.amazon.com/hpc/efa/) |
| **NCCL + aws-ofi-nccl** | the collective-comms + EFA plugin | [github.com/NVIDIA/nccl](https://github.com/NVIDIA/nccl) · [aws-ofi-nccl](https://github.com/aws/aws-ofi-nccl) |
| **Kubeflow Training Operator** | `MPIJob` / `PyTorchJob` | [github.com/kubeflow/training-operator](https://github.com/kubeflow/training-operator) |
| **JobSet** | multi-group elastic jobs | [github.com/kubernetes-sigs/jobset](https://github.com/kubernetes-sigs/jobset) |
| **Node Problem Detector** | XID error → node condition → drain | [github.com/kubernetes/node-problem-detector](https://github.com/kubernetes/node-problem-detector) |
| **FSDP / DeepSpeed ZeRO-3** | PyTorch distributed sharding | [pytorch FSDP](https://pytorch.org/docs/stable/fsdp.html) · [deepspeed.ai](https://www.deepspeed.ai/) |
| **A model + dataset** | small (≤3B) from HF | [huggingface.co](https://huggingface.co/) |

> **Honesty note baked into the project:** G-series NCCL-over-EFA is *functional rehearsal* of the fabric plumbing, not p4d-representative performance (GPUDirect RDMA `FI_EFA_USE_DEVICE_RDMA=1` is a p4d+ path). Keep fabric sessions to ~2 hrs each, ~3 sessions.

---

## P6 — [AI Platform Control Plane](../project-6-ai-platform-control-plane.md)  ·  proves you can *build* a platform (maps to Cisco Control Plane JD)
**Cost:** **CPU-only — develop on kind for FREE**; end-to-end GPU demos ~$0.30–0.60/hr

| Resource | Exact spec | Where / how |
|---|---|---|
| **kind cluster** | free local dev of the operator | [kind.sigs.k8s.io](https://kind.sigs.k8s.io/) |
| **kopf** (Python operator framework) → **kubebuilder** (Go, the graduation) | build the `ModelDeployment` CRD + controller | [github.com/nolar/kopf](https://github.com/nolar/kopf) · [book.kubebuilder.io](https://book.kubebuilder.io/) |
| **Kyverno** | admission policy (ClusterPolicy) | [kyverno.io](https://kyverno.io/) |
| **Envoy Gateway** (Gateway API) | HTTPRoute / SecurityPolicy / BackendTrafficPolicy | [gateway.envoyproxy.io](https://gateway.envoyproxy.io/) |
| **KEDA** | ScaledObject the operator generates | [keda.sh](https://keda.sh/) |
| **OpenCost** | per-tenant GPU cost | [opencost.io](https://www.opencost.io/) |
| **Prometheus** (PrometheusRule / SLO burn) | from kube-prometheus-stack | [prometheus.io](https://prometheus.io/) |
| *Optional* GPU node | `g4dn`/`g5` spot for the end-to-end demo | AWS |

> The whole control plane is CPU — you can build and demo 90% of it with **zero GPU spend** on kind.

---

## Advanced Inference — [P09 disaggregated (llm-d)](../project-09-disaggregated-inference-llm-d.md) + [P10 gateway](../project-10-advanced-inference-gateway.md)
**Cost:** ~$30–70 (2–4× g5/g6 spot; short 2-GPU disagg window)

| Resource | Exact spec | Where / how |
|---|---|---|
| **P1 cluster** | GPU platform base | from P1 |
| **GPU nodes** | **2–4× `g5.xlarge` spot (A10G)** (~$0.30/hr each) for most phases; **2× `g5.12xlarge`** for the disagg benchmark (keep < 2 hrs) | Karpenter (`gpu-decode` / `gpu-prefill` nodegroups) |
| **Gateway API Inference Extension** | `InferencePool` / `InferenceObjective` / `HTTPRoute` (KV-aware routing) | [github.com/kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) |
| **vLLM** (prefill/decode split, chunked prefill, speculative decode) | latest | [docs.vllm.ai](https://docs.vllm.ai/) |
| **llm-d** (disaggregation pattern) | reference | [github.com/llm-d/llm-d](https://github.com/llm-d/llm-d) |
| **k6** | load / SLO measurement | [k6.io](https://k6.io/) |
| Models | 7B-class from HF | [huggingface.co](https://huggingface.co/) |

---
---

## 📋 Procurement checklist (tick before you build)

**Week 0 — accounts & quota (do now, some take days):**
- [ ] AWS account + **G/VT vCPU quota raised** (on-demand ≥16, spot ≥48) — §0.2
- [ ] Hugging Face account + `HF_TOKEN` + Llama access request
- [ ] GitHub account + fork `scheduler-plugins`
- [ ] NGC account + API key (for `nvcr.io`)
- [ ] **AWS Budgets alarm at $25**
- [ ] One non-AWS GPU provider signed up (Lambda simplest) — *only needed at Tier 2 / P08*

**Local machine — install once:**
- [ ] AWS CLI, kubectl, Helm, Terraform, eksctl, Docker, kind, kwok, Go, Python, k6, jq/yq (§0.3)
- [ ] *If local RTX for P16:* CUDA Toolkit + Nsight Systems + Nsight Compute + PyTorch

**Per-tier GPU spend, budgeted:**
- [ ] Tier 1: ~$40–70 (P1 ~$15, P16 ~$0–15, P07 ~$0, P2 ~$20) — two projects are basically free
- [ ] Tier 2: ~$90–150 (Fractional ~$25 incl. one A100 session, P10-train ~$70, P6 ~$5, Adv-Inference ~$50)
- [ ] **Phone timer on every GPU session. `make down` / teardown after every session.**

---

## 💡 The cost-smart sequencing (money-first reading of your build order)

1. **Start with the two ~$0 projects in parallel:** P07 (kind/kwok, free) is your strongest artifact and needs no cluster; P16 (local RTX, free) sharpens everything — you can be *building portfolio* before spending a rupee on GPUs.
2. **Then P1** (~$15) — the one cluster P2, P6, and the Tier-2 inference projects all reuse. Build it once, tear it down between sessions, `terraform apply` to bring it back.
3. **Then P2** (~$20) on P1's cluster.
4. **Tier 2 only once interviewing.** The single A100 session (P08 MIG, ~$8 off-AWS) and the EFA pair (P10-train, ~$70) are the only real spend; everything else rides P1 or runs free on kind.

> **The whole Tier-1 portfolio can be built for under ~$70 of GPU time**, and the two most differentiating pieces (the Go scheduler, the CUDA fluency) cost **nothing** if you have any NVIDIA GPU. Spend where it proves something an interviewer will test; simulate everything else.

---

*Companion files in this folder: the concept foundations ([01](01-big-data-on-k8s-foundations.md) · [02](02-k8s-for-genai-foundations.md)), the Python guide ([03](03-python-from-zero-for-both-books.md)), and the project Learning Ladders (`../../Tier1-AI-Projects_Learning_Ladder.md`). Climb the ladder → gather these resources → build. Understanding first, procurement second, commands last.*
