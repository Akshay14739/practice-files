# From-Zero Learning Ladders — Read These BEFORE the Hands-On Projects 🪜

Every technical concept in the Tier-1/Tier-2 portfolio projects, broken down for a non-technical adult — one ladder per project, each climbing **Pain → One Idea → Machinery → Jargon → Trace → Contrast → Predict → Capstone**. Read the ladder (≈30–45 min), say the capstone back cold, then open the project file and build.

## Tier 1 — the portfolio (build in this order, ~2–3 months)

| Read this ladder | Then build | Notes |
|---|---|---|
| [04 · GPU platform from zero](04-p1-gpu-platform-from-zero.md) | [project-1](../project-1-gpu-kubernetes-platform.md) | The substrate; your EKS/Karpenter stack + the GPU Operator layer |
| [05 · CUDA performance from zero](05-p16-cuda-performance-from-zero.md) | [project-16](../project-16-cuda-gpu-performance-engineering.md) | ~$0; do in PARALLEL with #1 |
| [06 · Gang scheduler from zero](06-p07-gang-scheduler-from-zero.md) | [project-07](../project-07-topology-aware-gang-scheduler.md) | The Go differentiator; kwok fake nodes, ~$0, independent of #1 |
| [07 · LLM inference from zero](07-p2-llm-inference-from-zero.md) | [project-2](../project-2-llm-inference-platform.md) | Needs #1's cluster |

## Tier 2 — credible → strong (start only once interviewing off Tier 1, ~+3–4 months)

| Read this ladder | Then build | Notes |
|---|---|---|
| [08 · Fractional GPUs from zero](08-p8-fractional-gpu-from-zero.md) | [project-8](../project-8-gpu-sharing-partitioning-fleet.md) + merge [project-08](../project-08-fractional-gpu-dra-multitenancy.md) | One short non-AWS A100 session for MIG |
| [09 · Fault-tolerant training from zero](09-p10-fault-tolerant-training-from-zero.md) | [project-10-fault-tolerant…](../project-10-fault-tolerant-training-goodput.md) | The frontier-lab reliability specialty |
| [10 · Control plane from zero](10-p6-control-plane-from-zero.md) | [project-6](../project-6-ai-platform-control-plane.md) | Build a platform, not just use one; laptop-free until demo |
| [11 · Disaggregated inference from zero](11-p09-disaggregated-inference-from-zero.md) | [project-09](../project-09-disaggregated-inference-llm-d.md) + merge [project-10-advanced…](../project-10-advanced-inference-gateway.md) | Same topic pair — build from 09 |

**Deeper technical versions of the four Tier-1 ladders:** `../../Tier1-AI-Projects_Learning_Ladder.md` (written for your platform-engineer self — read it after the from-zero version, before executing).

**Foundations already in this folder:** [01 big-data-on-k8s](01-big-data-on-k8s-foundations.md) · [02 k8s-for-genai](02-k8s-for-genai-foundations.md) · [03 python-from-zero](03-python-from-zero-for-both-books.md) · [resources needed](AI-Infra-Projects-Resources-Required.md)
