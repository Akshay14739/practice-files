# Project 15 — Build an "AI Factory": NVIDIA Cloud-Native Reference Architecture
### 🟩 NVIDIA TRACK 3 of 3 — the capstone of the NVIDIA track

> "AI factory" is NVIDIA's term for a full-stack GPU datacenter that turns data + GPUs into intelligence, as a repeatable production system. This project assembles one on Kubernetes using the **complete NVIDIA cloud-native stack** — GPU Operator, **Network Operator** (RDMA/GPUDirect), **NIM Operator**, **NeMo**-style fine-tuning, DCGM fleet health, and **MIG/MPS** partitioning — into a single validated, multi-tenant, observable, cost-governed reference architecture. It's the synthesis project: everything you learned, expressed the way NVIDIA prescribes it, so you can walk into any GPU-cloud/AI-factory role and say "I've built this."

| | |
|---|---|
| **Difficulty** | Expert (capstone) |
| **Time** | 5–6 weekends |
| **Prereq** | Ideally P1, P8, P9, P11, P14. This is where the NVIDIA track lands. |
| **Cloud cost** | Full end-to-end demos need GPUs (ideally 2 + an A100 window for MIG); strictly session-based. Control/validation plane on kind/CPU. Budget $25–45 total across the project. |
| **Skills proven** | NVIDIA reference-architecture assembly, GPU Operator + Network Operator (RDMA/GPUDirect), NIM Operator, DCGM Exporter fleet health, MIG/MPS multi-tenancy, NeMo fine-tuning pipeline, GPUDirect Storage concepts, validation & acceptance testing, capacity/BOM design, DGX/SuperPOD literacy |
| **Post/JD mapping** | "AI factories will run the next decade" (the post) · NVIDIA-cert syllabus end-to-end · GPU-neocloud JD: "bare metal GPU node infrastructure, CNI, GPU Operator, distributed storage, RDMA/InfiniBand, validated vCluster environment" (this project **is** that JD) |

---

## 1. What an AI factory is (the reference model)

NVIDIA's Cloud Native Stack + Enterprise reference architecture, layer by layer — you've touched every layer across P1–P14; here they become one coherent, validated whole:

```
┌─────────────────────────────────────────────────────────────────┐
│ TENANTS: NIM inference services · NeMo fine-tuning · notebooks   │ ← consumption
├─────────────────────────────────────────────────────────────────┤
│ PLATFORM: multi-tenancy (MIG/vCluster) · scheduling (Kueue/KAI)  │ ← P6/7/8/12
│           observability (DCGM+LGTM) · cost (OpenCost)            │ ← P11
├─────────────────────────────────────────────────────────────────┤
│ NVIDIA OPERATORS: GPU Operator · Network Operator · NIM Operator │ ← this project's core
├─────────────────────────────────────────────────────────────────┤
│ KUBERNETES (validated: NVIDIA Cloud Native Stack versions)       │
├─────────────────────────────────────────────────────────────────┤
│ ACCELERATED COMPUTE: GPUs (MIG) · CUDA · NVLink                  │ ← P1/8/13
├─────────────────────────────────────────────────────────────────┤
│ HIGH-SPEED FABRIC: RDMA/InfiniBand/RoCE · GPUDirect RDMA & GDS   │ ← P9 + Network Operator
├─────────────────────────────────────────────────────────────────┤
│ BARE METAL: GPU nodes · NVMe · DPUs (BlueField)                  │
└─────────────────────────────────────────────────────────────────┘
```

The neocloud JD lists these exact components. This project is you building their platform.

## 2. Phase 1 — The validated foundation (Cloud Native Stack)

NVIDIA publishes **validated version sets** (K8s + driver + operator + CNI combos they test together) as "NVIDIA Cloud Native Stack." Reproduce one:

- Provision GPU node(s); install a CNCF-conformant K8s at a version in NVIDIA's support matrix.
- Install **GPU Operator** (from P1) pinned to the validated version — driver, toolkit, device plugin, DCGM, MIG manager, NFD, **and the validator** (`nvidia-operator-validator` runs CUDA + device-plugin + NCCL sanity checks automatically).
- Capture the validator passing — that green check is "this node is AI-factory-ready," and reproducing NVIDIA's validated stack is exactly what GPU-cloud onboarding engineers do.

`docs/validated-stack.md`: your exact version matrix + the validation output. Boring-looking, extremely credible.

## 3. Phase 2 — Network Operator: RDMA & GPUDirect (the neocloud differentiator)

P9 got NCCL over EFA working manually. The **NVIDIA Network Operator** productizes RDMA on K8s — it deploys the RDMA shared device plugin, the OFED driver, secondary networks (Multus), and enables **GPUDirect RDMA** (NIC → GPU memory directly, bypassing the CPU):

```bash
helm install network-operator nvidia/network-operator -n nvidia-network-operator --create-namespace
```

```yaml
# NicClusterPolicy — RDMA stack + GPUDirect
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata: { name: nic-cluster-policy }
spec:
  ofedDriver: { image: doca-driver, repository: nvcr.io/nvidia/mellanox }
  rdmaSharedDevicePlugin:
    config: |
      { "configList": [{ "resourceName": "rdma_shared",
                         "rdmaHmem": false,
                         "devices": ["eth0"] }] }
  secondaryNetwork:
    multus: {}
    ipamPlugin: { image: whereabouts }
```

Pods then request `rdma/rdma_shared` alongside `nvidia.com/gpu`. Demo: re-run P9's `nccl-tests` but with the Network Operator managing the RDMA stack (vs the manual EFA wiring) and confirm GPUDirect RDMA in the NCCL log (`[GPUDirect RDMA]`). Write `docs/gpudirect.md`: GPUDirect **RDMA** (NIC↔GPU) vs GPUDirect **Storage/GDS** (NVMe↔GPU, skipping the CPU bounce buffer) — the two data-movement optimizations that define factory-grade I/O. On non-RDMA cloud hardware, do this phase as the Network Operator architecture + a GDS concept write-up (still strong).

## 4. Phase 3 — Multi-tenant partitioning (MIG) + NIM services

Combine P8 (MIG) + P14 (NIM) into the factory's serving tenancy:

- Put the A100 in a **mixed MIG geometry** (e.g., `3g.20gb` + 2×`2g.10gb`) via the GPU Operator's mig-manager.
- Deploy **NIM services** (or Triton+TRT-LLM if no NIM entitlement) onto individual MIG slices → 3 isolated, hardware-partitioned inference tenants on one physical GPU, each with its own OpenAI-compatible endpoint.
- Front them with **P10's Inference Gateway** for KV-aware routing across tenants.

Result: a multi-tenant model-serving factory where tenants get **guaranteed** (hardware-isolated) slices — the exact "GPU sharing and isolation, vGPU, MIG… multi-tenant AI workloads" the NVIDIA syllabus describes.

## 5. Phase 4 — NeMo-style fine-tuning pipeline (the "factory produces models" half)

A factory doesn't just serve — it *manufactures* models. Wire a fine-tuning pipeline using **NeMo** (NVIDIA's framework; or your P5 PEFT/Ray path as the open equivalent) as a first-class tenant workload:

- Data prep → fine-tune (RayJob/PyTorchJob from P5/P9, on the training partition) → register in MLflow → **build a NIM/TensorRT-LLM engine from the result** (P14) → deploy to a serving MIG slice.
- That's the closed factory loop: **data in → trained model → optimized engine → served endpoint**, all on the same GPU platform, all declarative. Diagram it and run at least one lap end-to-end (small model) for the demo reel.

## 6. Phase 5 — Fleet health, acceptance testing & the BOM

The operational reality of running a factory:

- **DCGM fleet health** (P11) + the GPU Operator validator as a recurring **acceptance test** — a Job that every new node must pass (CUDA sanity, NCCL bandwidth threshold, DCGM diagnostics `dcgmi diag -r 3`) before it's marked schedulable. This is precisely the neocloud JD's "deploy and validate… ensuring they can operate the platform independently."
- **`dcgmi diag`** run levels and reading them; XID/ECC health gating (predictive drain from P11).
- **Capacity & BOM design doc** (`docs/ai-factory-bom.md`): for a target (say, "serve 50 models + train 5 concurrently"), size GPUs/nodes/network/storage, and speak the reference-hardware language — **DGX** (8-GPU NVLink node), **SuperPOD** (DGX + InfiniBand fabric + reference networking), rack power/cooling envelopes. You won't buy one, but AI-factory roles expect you to reason in these units.

## 7. Phase 6 — Package it as a reproducible reference architecture

The meta-deliverable that ties the *entire portfolio* into one artifact:

- **One GitOps repo** (ArgoCD ApplicationSet from P12) that stands up the whole factory on a fresh cluster: validated stack → GPU Operator → Network Operator → scheduling (Kueue+KAI) → observability (LGTM+DCGM) → cost (OpenCost) → tenancy (MIG/NIM) → the fine-tuning loop.
- **A reference-architecture document** (`AI-FACTORY-REFERENCE.md`) with the layered diagram, component versions, validation results, multi-tenancy model, DR posture (P12), and cost model — written as if onboarding the next engineer. This is your portfolio's centerpiece and the single strongest interview leave-behind.

## 8. Validation checklist

- [ ] GPU Operator **validator passes**; validated version matrix documented
- [ ] Network Operator RDMA stack up; GPUDirect RDMA confirmed in NCCL (or full architecture doc)
- [ ] MIG mixed geometry hosting 3 isolated NIM/Triton tenants behind the inference gateway
- [ ] End-to-end factory loop run once: data → fine-tune → engine → served endpoint
- [ ] Node acceptance test (`dcgmi diag` + NCCL threshold) gates scheduling
- [ ] BOM/capacity doc written in DGX/SuperPOD terms
- [ ] One-command GitOps reproduction + reference-architecture doc published

## 9. Teardown

The most disciplined teardown of all — A100 + multi-GPU windows are the costliest. Scripted `make factory-up` / `make factory-down`; every GPU node consolidated to zero after each session; validation evidence, diagrams, and the reference doc are the durable output. Set timers; verify `nodeclaims` empty before you log off.

## 10. Interview ammunition

- *"Built a complete NVIDIA AI-factory reference architecture on Kubernetes: reproduced a validated Cloud Native Stack (GPU Operator + validator), deployed the Network Operator for RDMA/GPUDirect, partitioned A100s with MIG to host isolated NIM inference tenants behind a KV-aware gateway, ran a closed fine-tune→engine→serve loop, gated node onboarding with DCGM acceptance tests, and packaged the whole platform as a one-command GitOps reference architecture with a capacity BOM in DGX/SuperPOD terms."*
- That single paragraph is the GPU-neocloud "AI Infrastructure Engineer" JD, delivered. And it's the post's thesis — GPUs, CUDA, and AI factories — made real by someone who can *operate* one.
- Whiteboard-ready: the AI-factory layer stack; validated stack & why version matrices matter; GPUDirect RDMA vs GDS; MIG multi-tenancy for guaranteed QoS; the manufacture→serve model loop; node acceptance testing; DGX/SuperPOD reference topology; where every P1–P14 skill fits.

## 11. Stretch goals

1. **BlueField DPU / DOCA** concept chapter — offloading networking/security/storage to the DPU (the frontier of factory node design).
2. **Multi-node NVLink** (NVLink Switch / GB200 NVL72) architecture write-up — how the newest factories collapse the intra/inter-node boundary.
3. **Confidential computing** on H100 (GPU TEE) for a multi-tenant factory handling sensitive data — ties to compliance JDs.
4. Turn the reference architecture into a **conference talk / blog series** — "How a DevOps engineer built an AI factory on Kubernetes" is a genuinely rare, hireable narrative.
