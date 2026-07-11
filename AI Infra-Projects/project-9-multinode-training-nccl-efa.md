# Project 9 — Multi-Node Distributed Training: NCCL, EFA & FSDP/DeepSpeed in Anger

> Cross the line that separates "ran a fine-tune" from "operates distributed training": a **2-node GPU cluster with EFA (AWS's RDMA-class fabric)**, **NCCL** collectives measured with `nccl-tests`, a **multi-node FSDP** run via Kubeflow Training Operator, a **DeepSpeed ZeRO-3** comparison, and the debugging playbook (NCCL_DEBUG, timeouts, stragglers) that training-infra teams live in. This is the affordable, honest version of the InfiniBand/NVLink layer from your infra-stack doc.

| | |
|---|---|
| **Difficulty** | Expert |
| **Time** | 3–4 weekends |
| **Prereq** | Projects 1, 5 |
| **Cloud cost** | The pricey one — plan sessions: 2× `g4dn.8xlarge` (1× T4 + **EFA support**, 32 vCPU) spot ≈ $0.70–0.90/hr *each*. Full bench+train session ≈ 3–4 hrs ≈ **$5–8/session**, ~3 sessions total. |
| **Skills proven** | NCCL (AllReduce/AllGather/ReduceScatter), EFA/libfabric on EKS, aws-ofi-nccl, GPUDirect concepts, torchrun/c10d rendezvous, Kubeflow PyTorchJob, FSDP vs DeepSpeed ZeRO, gradient accumulation math, straggler & NCCL-hang debugging |
| **JD keywords hit** | "distributed systems architecture and fundamentals" · "RDMA/InfiniBand" (GPU-neocloud JD — EFA is the AWS analogue) · Udemy: "AllReduce, mixed precision, Horovod/FSDP/DeepSpeed" |

---

## 1. The theory you'll turn into measurements

- **Data-parallel step:** forward → backward → **AllReduce(gradients)** → optimizer. The AllReduce moves ~2× model-size bytes per step (ring algorithm) — *network is the ceiling*.
- **FSDP/ZeRO-3:** parameters/grads/optimizer state **sharded**; each layer does AllGather (params) + ReduceScatter (grads). More comms, radically less memory — how big models fit at all.
- **The fabric hierarchy** (from your infra-stack doc): NVLink (intra-node, 600–900 GB/s) → InfiniBand/**EFA** (inter-node, 100–400 Gb/s) → plain TCP (the sad path). You can't rent NVLink cheaply, but **EFA on g4dn.8xlarge is real userspace-bypass networking** (SRD protocol via libfabric) — the same *operational* skillset as InfiniBand.
- **The metric:** `nccl-tests` **busbw** (bus bandwidth). Your deliverable is the table: TCP vs EFA, 1-node vs 2-node.

## 2. Phase 1 — EFA-enabled node group

EFA needs: supported instance type, security group allowing **all traffic within itself**, same subnet/placement, the EFA device plugin, and huge pages. Karpenter EC2NodeClass/NodePool:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: gpu-efa }
spec:
  template:
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu-efa }
      taints: [{ key: nvidia.com/gpu, effect: NoSchedule }]
      requirements:
        - { key: node.kubernetes.io/instance-type, operator: In, values: ["g4dn.8xlarge"] }
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot","on-demand"] }
        - { key: topology.kubernetes.io/zone, operator: In, values: ["<one-az>"] }  # same AZ = EFA reqmt
  limits: { nvidia.com/gpu: 2 }
```

```yaml
# EC2NodeClass additions vs P1:
spec:
  # interruption-tolerant lab: cluster placement group is ideal but optional on g4dn
  metadataOptions: { httpPutResponseHopLimit: 2 }
```

Install the **EFA device plugin** (exposes `vpc.amazonaws.com/efa`) and verify:

```bash
kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-efa-k8s-device-plugin/crds/manifest.yaml   # or helm chart aws-efa-k8s-device-plugin
kubectl describe node <n> | grep -E "vpc.amazonaws.com/efa|nvidia.com/gpu"
#   nvidia.com/gpu: 1     vpc.amazonaws.com/efa: 1
```

> Security-group note: EKS-managed SGs usually qualify, but EFA silently falls back to TCP if self-referencing all-traffic rules are missing — you'll *prove* which path you're on in Phase 2 rather than trusting it. That sentence is an interview answer about operating RDMA fabrics.

## 3. Phase 2 — nccl-tests: measure the fabric

Container image (`bench/Dockerfile`) with the full comms stack — CUDA + NCCL + **libfabric + aws-ofi-nccl** (the NCCL→EFA shim) + OpenMPI:

```dockerfile
FROM public.ecr.aws/hpc-cloud/nccl-tests:latest   # AWS-maintained: nccl-tests + aws-ofi-nccl + EFA libs
# (fallback: build from nvidia/cuda:12.4-devel + git clone nccl-tests + efa-installer — recipe in repo)
```

Two-pod all_reduce across nodes — the raw MPI-style launch (Volcano `ssh` plugin or an mpi-operator MPIJob both work; MPIJob shown):

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata: { name: allreduce-bench }
spec:
  slotsPerWorker: 1
  runPolicy: { cleanPodPolicy: Running }
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
            - name: launcher
              image: <bench-image>
              command: ["mpirun", "-np", "2", "--allow-run-as-root",
                "-x", "FI_PROVIDER=efa",
                "-x", "NCCL_DEBUG=INFO",
                "-x", "FI_EFA_USE_DEVICE_RDMA=1",
                "/opt/nccl-tests/build/all_reduce_perf",
                "-b", "8", "-e", "1G", "-f", "2", "-g", "1"]
    Worker:
      replicas: 2
      template:
        spec:
          tolerations: [{ key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }]
          containers:
            - name: worker
              image: <bench-image>
              resources:
                limits:
                  nvidia.com/gpu: 1
                  vpc.amazonaws.com/efa: 1     # ← the fabric device itself
                  hugepages-2Mi: 5120Mi
                  memory: 16Gi
              volumeMounts: [{ name: shm, mountPath: /dev/shm }]
          volumes: [{ name: shm, emptyDir: { medium: Memory, sizeLimit: 8Gi } }]
```

**The proof lines** in NCCL_DEBUG output — learn to read them cold:

```
NCCL INFO NET/OFI Selected provider is efa           ← EFA path active
NCCL INFO Channel 00 : ... [send] via NET/AWS Libfabric/0
```

Run the matrix and publish it:

| Message size | busbw TCP (Gb/s) | busbw EFA (Gb/s) | speedup |
|---:|---:|---:|---:|
| 8 MB / 128 MB / 1 GB | *measured* (unset FI_PROVIDER, `NCCL_NET=Socket`) | *measured* | typically 2–5× at large sizes |

Then run **all_gather_perf** and **reduce_scatter_perf** too — FSDP's actual collectives.

## 4. Phase 3 — Multi-node FSDP with Kubeflow Training Operator

```bash
kubectl apply --server-side -k "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.8.1"
```

`train/fsdp_train.py` (core; full file in repo) — Qwen2.5-0.5B full-finetune (small enough that 2× T4 FSDP is *sharding for real*, not toy LoRA):

```python
import os, torch, torch.distributed as dist
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP, MixedPrecision
from torch.distributed.fsdp.wrap import transformer_auto_wrap_policy
from transformers import AutoModelForCausalLM, AutoTokenizer
from transformers.models.qwen2.modeling_qwen2 import Qwen2DecoderLayer
from functools import partial

dist.init_process_group("nccl")                      # rendezvous via torchrun env
rank, local = dist.get_rank(), int(os.environ["LOCAL_RANK"])
torch.cuda.set_device(local)

model = AutoModelForCausalLM.from_pretrained("Qwen/Qwen2.5-0.5B", torch_dtype=torch.float32)
model = FSDP(model,
    auto_wrap_policy=partial(transformer_auto_wrap_policy,
                             transformer_layer_cls={Qwen2DecoderLayer}),
    mixed_precision=MixedPrecision(param_dtype=torch.float16,      # T4: fp16
                                   reduce_dtype=torch.float16),
    device_id=local,
    limit_all_gathers=True)

# ... dataloader with DistributedSampler, AdamW, standard loop ...
# every step: loss.backward() triggers ReduceScatter; each fwd layer AllGathers params
if rank == 0 and step % 10 == 0:
    print(f"step={step} loss={loss.item():.4f} "
          f"mem={torch.cuda.max_memory_allocated()/1e9:.1f}GB")
```

PyTorchJob — the operator injects `MASTER_ADDR/RANK/WORLD_SIZE` and runs torchrun semantics:

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: fsdp-2node
  labels: { kueue.x-k8s.io/queue-name: team-ml }     # P7's gang admission guards this
spec:
  nprocPerNode: "1"
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      template: &tpl
        spec:
          tolerations: [{ key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }]
          containers:
            - name: pytorch
              image: <train-image>
              command: ["torchrun", "--nnodes=2", "--nproc_per_node=1", "fsdp_train.py"]
              env:
                - { name: NCCL_DEBUG, value: WARN }
                - { name: FI_PROVIDER, value: efa }
                - { name: FI_EFA_USE_DEVICE_RDMA, value: "1" }
              resources:
                limits: { nvidia.com/gpu: 1, vpc.amazonaws.com/efa: 1,
                          memory: 24Gi, hugepages-2Mi: 5120Mi }
              volumeMounts: [{ name: shm, mountPath: /dev/shm }]
          volumes: [{ name: shm, emptyDir: { medium: Memory, sizeLimit: 8Gi } }]
    Worker:
      replicas: 1
      template: *tpl
```

**Numbers to publish:** step time & tokens/sec for {1 node, 2 nodes×TCP, 2 nodes×EFA}; scaling efficiency = `T1/(2×T2)`; peak memory single-GPU-no-FSDP vs FSDP (the sharding proof). Honest expected result on 2× T4: modest speedup, big memory win, EFA clearly beating TCP — and *explaining why* (comm/compute ratio at 0.5B scale) is a better interview than fake-perfect scaling.

## 5. Phase 4 — DeepSpeed ZeRO-3 comparison

Same model/data, `deepspeed --hostfile` inside the same PyTorchJob shape, `ds_config.json`:

```json
{ "train_micro_batch_size_per_gpu": 4,
  "gradient_accumulation_steps": 8,
  "fp16": { "enabled": true },
  "zero_optimization": {
    "stage": 3,
    "overlap_comm": true,
    "contiguous_gradients": true,
    "stage3_prefetch_bucket_size": 5e7 },
  "wall_clock_breakdown": true }
```

One-page write-up: FSDP (PyTorch-native, wrap-policy control) vs ZeRO-3 (config-driven, CPU/NVMe offload options, `wall_clock_breakdown` timing) — when a team picks each. Add ZeRO **stage-2 vs stage-3** memory/step-time deltas from your runs.

## 6. Phase 5 — The debugging playbook (`docs/nccl-debug-playbook.md`)

Break it on purpose; document detection → diagnosis → fix for each:

1. **NCCL hang/timeout** (`Watchdog caught collective timeout`): kill one worker mid-step → observe the other block → `NCCL_DEBUG=INFO` + `TORCH_NCCL_TRACE_BUFFER_SIZE` flight recorder → restart-from-checkpoint policy.
2. **Silent TCP fallback:** remove the `efa` resource limit → job "works" but slow → detection query = your busbw baseline + the `Selected provider` log line.
3. **/dev/shm too small:** drop the shm mount → NCCL bus error → the fix everyone learns once.
4. **Straggler:** `stress-ng` one node's CPUs → step time = slowest worker → per-rank step-time metric + the case for topology/health-aware placement (ties to P7 TAS, P15 health checks).
5. **Version skew:** mismatch NCCL between images → error taxonomy → why training images are pinned monorepo-style.

## 7. Validation checklist

- [ ] `Selected provider is efa` captured; busbw table TCP vs EFA published
- [ ] 2-node FSDP converging; scaling-efficiency + memory table published
- [ ] ZeRO-3 comparison page written
- [ ] All five playbook failures reproduced with fixes
- [ ] Kueue gates the whole PyTorchJob as one gang (no partial 1-node starts)

## 8. Teardown

These nodes are the expensive kind: `make down` deletes MPIJob/PyTorchJob, scales `gpu-efa` NodePool limits to 0, verifies `kubectl get nodeclaims` empty. Set a phone timer when you start a session — seriously.

## 9. Interview ammunition

- *"Operated multi-node distributed training on EKS with EFA: benchmarked NCCL AllReduce/AllGather at Xk Gb/s busbw (Y× over TCP), ran 2-node FSDP and DeepSpeed ZeRO-3 fine-tunes via Kubeflow Training Operator with fp16 mixed precision, and wrote the NCCL failure playbook — hangs, silent TCP fallback, shm sizing, stragglers, version skew."*
- Whiteboard-ready: ring-AllReduce byte math (2(N−1)/N × size); why FSDP trades memory for comms and where that stops paying; EFA/SRD vs InfiniBand vs RoCE in 90 seconds; how you *detect* that a fabric silently degraded; why gang scheduling is a prerequisite for any of this.

## 10. Stretch goals

1. **Ray Train multi-node** version of the same run — compare operator ergonomics with Kubeflow (favorite panel question).
2. Add **elastic training** (torchrun `--max-restarts` + `--nnodes=1:2`): kill a node, watch world-size shrink and training continue.
3. **Gradient compression** (PowerSGD hook) on the TCP path — measure whether it closes the EFA gap at this model size.
4. Export **per-rank step time + collective time** to Prometheus; alert on straggler ratio >1.3× (feeds P11's AIOps).
