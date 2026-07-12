# Project 10 — Multi-Node Training: NCCL/EFA Fabric, Fault Tolerance & Goodput Engineering

**Difficulty:** ★★★★★ | **Time:** 6–7 weekends | **Cost:** ~$45–100 (fabric sessions: 2× g6.8xlarge spot ≈ $2.2/hr for the pair, ~3 sessions; platform: 4× g5 spot; one 2-hr multi-node A100/EFA window shared with P15 — prices as of July 2026)

*Cross the line that separates "ran a fine-tune" from "operates distributed training" — then make it survive. Phases 1–4 bring up a real 2-node EFA (AWS's RDMA-class) fabric, measure NCCL collectives with `nccl-tests`, and run multi-node FSDP and DeepSpeed ZeRO-3 via the Kubeflow Training Operator. Phases 5–8 build the reliability layer frontier labs hire for on its own: elastic torchrun, async sharded checkpointing, XID-driven remediation, and goodput/MFU/straggler analytics.*

## 1. The production problem

Meta's Llama-3 paper reports **466 job interruptions in 54 days** on a 16k-H100 run — ~78 % from hardware (GPU/HBM failures dominating). At that scale a *daily* failure is guaranteed; the difference between labs is not avoiding failures but **goodput**: the fraction of wall-clock GPU time producing useful training progress. Google, Meta, and cloud providers all publish goodput methodologies. P07 (project-07-topology-aware-gang-scheduler.md) got distributed jobs *admitted* as gangs; this project builds the fabric they run on and then makes the training *survive* — which is precisely the SRE-flavored AI-infra work your background maps to.

Failure taxonomy you'll handle: GPU **XID errors** (48/63/64 = memory/ECC, 79 = fell off the bus), NCCL timeouts/hangs, stragglers (one slow rank stalls all ranks — allreduce is synchronous), spot reclaims, silent fabric degradation (EFA→TCP fallback), and plain OOMs.

## 2. The theory you'll turn into measurements

- **Data-parallel step:** forward → backward → **AllReduce(gradients)** → optimizer. The AllReduce moves ~2× model-size bytes per step (ring algorithm) — *network is the ceiling*.
- **FSDP/ZeRO-3:** parameters/grads/optimizer state **sharded**; each layer does AllGather (params) + ReduceScatter (grads). More comms, radically less memory — how big models fit at all.
- **The fabric hierarchy:** NVLink (intra-node, 600–900 GB/s) → InfiniBand/**EFA** (inter-node, 100–400 Gb/s) → plain TCP (the sad path). You can't rent NVLink cheaply, but **EFA on 8xlarge-class G instances is real userspace-bypass networking** (SRD protocol via libfabric) — the same *operational* skillset as InfiniBand.
- **The metrics:** `nccl-tests` **busbw** (bus bandwidth) for the fabric; **goodput** and **MFU** for the training itself. Your deliverables are the TCP-vs-EFA busbw table and the goodput dashboard.

## 3. Architecture

```
 Fabric plane (Phases 1–4):
   2× g6.8xlarge (1× L4 + EFA each, same AZ/subnet) — Karpenter gpu-efa NodePool
     └─ aws-ofi-nccl → libfabric → EFA (SRD)
     └─ nccl-tests busbw: TCP vs EFA  |  Kubeflow PyTorchJob: FSDP / ZeRO-3

 Reliability plane (Phases 5–8):
   JobSet (replicated training job, Kueue-admitted, topology-aware)
     └─ torchrun elastic (--nnodes=2:4, c10d rendezvous, max-restarts)
          └─ train.py: async distributed checkpoints (local NVMe → S3),
                       per-step timing + heartbeat metrics
   Node health plane:
     node-problem-detector (dmesg XID watcher) ─▶ NodeCondition GpuXidError
          └─▶ remediator (tiny controller): cordon → drain → delete node
                   └─▶ Karpenter provisions replacement → job elastically resumes
   Goodput plane:
     Prometheus: step_time, tokens/s, MFU, restarts, ckpt overhead
     → goodput = productive_step_time / wallclock (dashboard + weekly report)
```

## 4. Phase 1 — EFA-enabled node group

EFA needs: a supported instance type, a security group allowing **all traffic within itself**, same subnet/AZ (EFA traffic cannot cross AZs — ideally a cluster placement group), the EFA device plugin, and huge pages. Instance choice (us-east-1 prices as of July 2026):

| Pair | GPU | EFA capability | On-demand / spot (each) |
|---|---|---|---|
| **2× g6.8xlarge (recommended)** | 1× L4 | EFA **with RDMA read/write** (Nitro v4) | $2.01 / ~$1.11 |
| 2× g4dn.8xlarge (budget) | 1× T4 | EFA, no RDMA read/write (Nitro v3) | $2.18 / ~$0.75 |
| 2× g5.8xlarge | 1× A10G | EFA, no RDMA read/write (Nitro v3) | $2.45 / ~$1.23 |

Sub-8xlarge G sizes have **no EFA** at all. Honesty note: AWS's official EFA+NCCL guide nominally covers only P-series, and GPUDirect RDMA (`FI_EFA_USE_DEVICE_RDMA=1`) is documented for p4d+ — G-series NCCL-over-EFA is *functional rehearsal* of the fabric plumbing, not p4d-representative performance. EFA itself is free. Karpenter NodePool:

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
        - { key: node.kubernetes.io/instance-type, operator: In, values: ["g6.8xlarge"] }
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot","on-demand"] }
        - { key: topology.kubernetes.io/zone, operator: In, values: ["<one-az>"] }  # same AZ = EFA reqmt
  limits: { nvidia.com/gpu: 2 }
```

```yaml
# EC2NodeClass additions vs P1:
spec:
  # interruption-tolerant lab: cluster placement group is ideal but optional on G-series
  metadataOptions: { httpPutResponseHopLimit: 2 }
```

Install the **EFA device plugin** (exposes `vpc.amazonaws.com/efa`) and verify:

```bash
kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-efa-k8s-device-plugin/crds/manifest.yaml   # or helm chart aws-efa-k8s-device-plugin
kubectl describe node <n> | grep -E "vpc.amazonaws.com/efa|nvidia.com/gpu"
#   nvidia.com/gpu: 1     vpc.amazonaws.com/efa: 1
```

> Security-group note: EKS-managed SGs usually qualify, but EFA silently falls back to TCP if self-referencing all-traffic rules are missing — you'll *prove* which path you're on in Phase 2 rather than trusting it. That sentence is an interview answer about operating RDMA fabrics.

## 5. Phase 2 — nccl-tests: measure the fabric

Container image (`bench/Dockerfile`) with the full comms stack — CUDA + NCCL + **libfabric + aws-ofi-nccl** (the NCCL→EFA shim) + OpenMPI:

```dockerfile
FROM public.ecr.aws/hpc-cloud/nccl-tests:latest   # AWS-maintained: nccl-tests + aws-ofi-nccl + EFA libs; pin the tag you tested
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
                "-x", "FI_EFA_USE_DEVICE_RDMA=1",   # GPUDirect RDMA path — documented for p4d+; inert on G-series
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

## 6. Phase 3 — Multi-node FSDP with Kubeflow Training Operator

```bash
kubectl apply --server-side -k "github.com/kubeflow/training-operator.git/manifests/overlays/standalone?ref=v1.8.1"   # pin to your tested release
```

`train/fsdp_train.py` (core; full file in repo) — Qwen2.5-0.5B full-finetune (small enough that 2 single-GPU nodes make FSDP *sharding for real*, not toy LoRA):

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
    mixed_precision=MixedPrecision(param_dtype=torch.bfloat16,     # L4/A10G: bf16; on T4 use fp16 (Turing has no BF16 tensor cores)
                                   reduce_dtype=torch.bfloat16),
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
  labels: { kueue.x-k8s.io/queue-name: team-ml }     # P07's gang admission guards this
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

**Numbers to publish:** step time & tokens/sec for {1 node, 2 nodes×TCP, 2 nodes×EFA}; scaling efficiency = `T1/(2×T2)`; peak memory single-GPU-no-FSDP vs FSDP (the sharding proof). Honest expected result on 2 single-GPU nodes: modest speedup, big memory win, EFA clearly beating TCP — and *explaining why* (comm/compute ratio at 0.5B scale) is a better interview than fake-perfect scaling.

## 7. Phase 4 — DeepSpeed ZeRO-3 comparison

Same model/data, `deepspeed --hostfile` inside the same PyTorchJob shape, `ds_config.json`:

```json
{ "train_micro_batch_size_per_gpu": 4,
  "gradient_accumulation_steps": 8,
  "bf16": { "enabled": true },
  "zero_optimization": {
    "stage": 3,
    "overlap_comm": true,
    "contiguous_gradients": true,
    "stage3_prefetch_bucket_size": 5e7 },
  "wall_clock_breakdown": true }
```

(On T4, swap `bf16` for `"fp16": { "enabled": true }`.) One-page write-up: FSDP (PyTorch-native, wrap-policy control) vs ZeRO-3 (config-driven, CPU/NVMe offload options, `wall_clock_breakdown` timing) — when a team picks each. Add ZeRO **stage-2 vs stage-3** memory/step-time deltas from your runs.

## 8. Phase 5 — elastic, resumable training

`train.py` (core ~100 lines; FSDP-wrapped small model like TinyLlama/1.1B so it runs on A10Gs):

```python
import os, signal, time, threading
import torch, torch.distributed as dist
import torch.distributed.checkpoint as dcp
from torch.distributed.checkpoint.state_dict import get_state_dict, set_state_dict
from torch.distributed.fsdp import FullyShardedDataParallel as FSDP
from prometheus_client import Gauge, Counter, start_http_server

STEP_TIME = Gauge("train_step_seconds", "per-step wallclock")
TOKENS    = Counter("train_tokens_total", "tokens processed")
CKPT_SECS = Counter("train_ckpt_blocked_seconds_total", "time training blocked on ckpt")

CKPT_DIR = os.environ.get("CKPT_LOCAL", "/local_nvme/ckpt")   # hostPath/ephemeral NVMe

def latest_step():
    try:  return max(int(d.split("-")[1]) for d in os.listdir(CKPT_DIR) if d.startswith("step-"))
    except Exception: return 0

def main():
    dist.init_process_group("nccl")           # torchrun sets env
    rank, world = dist.get_rank(), dist.get_world_size()
    if rank == 0: start_http_server(9400)
    model = FSDP(build_model().cuda())
    opt   = torch.optim.AdamW(model.parameters(), lr=2e-5)

    start = latest_step()
    if start:                                  # resume: every rank loads its shards
        sd_m, sd_o = get_state_dict(model, opt)
        dcp.load({"model": sd_m, "optim": sd_o}, checkpoint_id=f"{CKPT_DIR}/step-{start}")
        set_state_dict(model, opt, model_state_dict=sd_m, optim_state_dict=sd_o)

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())   # spot reclaim / drain → save & exit

    ckpt_future = None
    for step, batch in enumerate(dataloader(start), start=start + 1):
        t0 = time.time()
        loss = model(**batch).loss; loss.backward(); opt.step(); opt.zero_grad()
        STEP_TIME.set(time.time() - t0); TOKENS.inc(batch["input_ids"].numel() * world)

        if step % 100 == 0 or stop.is_set():
            if ckpt_future: t=time.time(); ckpt_future.result(); CKPT_SECS.inc(time.time()-t)
            sd_m, sd_o = get_state_dict(model, opt)
            ckpt_future = dcp.async_save({"model": sd_m, "optim": sd_o},
                                         checkpoint_id=f"{CKPT_DIR}/step-{step}")
            # background uploader sidecar syncs /local_nvme/ckpt → s3 (aws s3 sync loop)
        if stop.is_set(): break
    dist.destroy_process_group()

if __name__ == "__main__": main()
```

Key ideas to internalize (and say out loud in interviews): **async, sharded** checkpointing (`dcp.async_save`) keeps GPUs busy during I/O — checkpoint *stall* drops from minutes to seconds; **hierarchical storage** (NVMe first, S3 async) is how big runs checkpoint every few minutes affordably; `--max-restarts` + resumable dataloader (store `step` in the checkpoint, seed/skip deterministically) makes restarts cheap. Reality check (July 2026): `dcp.async_save` needs PyTorch ≥ 2.4 and is still flagged *experimental* in the 2.13 docs — pin your release (2.9 added `DefaultStager` for pinned-memory staging overlap). Keep one checkpoint in flight (the code does) and budget CPU RAM ≈ checkpoint-size-per-rank.

JobSet + Kueue (topology annotations from P15's labels):

```yaml
apiVersion: jobset.x-k8s.io/v1alpha2
kind: JobSet
metadata:
  name: tinyllama-sft
  labels: {kueue.x-k8s.io/queue-name: training}
spec:
  failurePolicy: {maxRestarts: 10}
  replicatedJobs:
  - name: worker
    template:
      spec:
        parallelism: 4
        completions: 4
        backoffLimit: 0
        template:
          metadata:
            annotations:
              kueue.x-k8s.io/podset-preferred-topology: topology.k8s.aws/network-node-layer-3
          spec:
            terminationGracePeriodSeconds: 300        # room to checkpoint on SIGTERM
            containers:
            - name: trainer
              image: <your-ecr>/endure:latest
              command: ["torchrun","--nnodes=2:4","--nproc_per_node=1",
                        "--max-restarts=5","--rdzv_backend=c10d",
                        "--rdzv_endpoint=tinyllama-sft-worker-0-0.tinyllama-sft:29500",
                        "--rdzv_id=tinyllama-sft","train.py"]
              env:
              - {name: TORCH_NCCL_ASYNC_ERROR_HANDLING, value: "1"}
              - {name: TORCH_NCCL_TRACE_BUFFER_SIZE, value: "2000"}   # NCCL flight recorder
              - {name: TORCH_NCCL_DUMP_ON_TIMEOUT, value: "1"}
              - {name: NCCL_DEBUG, value: "WARN"}
              resources: {limits: {nvidia.com/gpu: 1}}
              volumeMounts: [{name: nvme, mountPath: /local_nvme}]
            volumes: [{name: nvme, emptyDir: {}}]     # real runs: local NVMe hostPath/RAID
```

`--nnodes=2:4` = **elastic**: lose a node and training re-rendezvouses at world size 3 instead of dying. Demonstrate it live — and be precise (interviewers probe this): torchrun elastic does **group restarts**: on any failure or membership change *all* workers stop and restart (up to `--max-restarts`) with new `RANK`/`WORLD_SIZE`; it never hot-swaps one worker, so cheap restarts depend entirely on your checkpoint path. c10d is the recommended rendezvous backend. JobSet is still `v1alpha2` at release v0.12.0 as of July 2026 (v0.12 added pod-level elastic scaling) — pin the CRD release you install.

## 9. Phase 6 — detect: turning kernel noise into NodeConditions

node-problem-detector custom plugin (DaemonSet) — `xid-check.sh`:

```bash
#!/bin/bash
# NPD custom-plugin contract: exit 0 = OK, 1 = problem; stdout = message
recent=$(dmesg --time-format iso 2>/dev/null | tail -2000 | grep -E "NVRM: Xid.*(48|63|64|74|79|94|95)")
if [ -n "$recent" ]; then echo "GPU XID detected: $(echo "$recent" | tail -1)"; exit 1; fi
exit 0
```

NPD config maps that to `NodeCondition: GpuXidError=True` + an Event. Also enable **DCGM background health checks** (GPU Operator ships DCGM; `dcgmi health -s a`) and scrape `DCGM_FI_DEV_XID_ERRORS`. Inject a fake failure for testing by writing a matching line via `/dev/kmsg` on a lab node. Remember: **NPD detects and reports only** — it never remediates; that requires a second actor, which you build next.

## 10. Phase 7 — remediate: close the loop automatically

Tiny remediator (Python, ~50 lines, runs as a Deployment; this is your "AIOps automation" story):

```python
from kubernetes import client, config, watch
config.load_incluster_config(); v1 = client.CoreV1Api()
BAD = {"GpuXidError", "GpuUnhealthy"}
for ev in watch.Watch().stream(v1.list_node):
    node = ev["object"]; name = node.metadata.name
    if any(c.type in BAD and c.status == "True" for c in (node.status.conditions or [])):
        if not node.spec.unschedulable:
            v1.patch_node(name, {"spec": {"unschedulable": True}})          # cordon
            v1.patch_node(name, {"metadata": {"labels": {"remediation": "draining"}}})
            # evict pods (respect PDBs), then delete the Node object —
            # Karpenter treats it as disrupted and replaces the instance.
            for p in v1.list_pod_for_all_namespaces(field_selector=f"spec.nodeName={name}").items:
                if p.metadata.owner_references and p.metadata.owner_references[0].kind != "DaemonSet":
                    v1.create_namespaced_pod_eviction(p.metadata.name, p.metadata.namespace,
                        client.V1Eviction(metadata=client.V1ObjectMeta(name=p.metadata.name)))
            v1.delete_node(name)
```

End-to-end drill: inject XID → NPD flags → remediator drains → trainer catches SIGTERM, checkpoints, exits → Karpenter replaces node → elastic rendezvous resumes from `step-N`. **Time it.** MTTR is your headline metric (target: < 5 min with warm capacity).

Know the managed equivalents your DIY controller competes with (as of July 2026): the **EKS node monitoring agent + auto repair** (XID 64 → reboot after 10 min by default, configurable to replace), NVIDIA **NVSentinel** (detect/classify → cordon+drain+break-fix), and **Karpenter Node Auto Repair** — still **alpha** (`NodeRepair=true` feature gate, since v1.1.0; Karpenter's NodePool/NodeClaim API itself is stable v1), which force-terminates a node once a condition persists past its toleration and *requires* a condition-setting agent. Being able to compare your controller against these is the interview.

## 11. Phase 8 — goodput & straggler analytics

Definitions (Google-style): **goodput = productive time / total wallclock**, where productive excludes: init/rendezvous, checkpoint-blocked time, re-computation after restore (steps since last checkpoint), and hang time. Compute from your metrics:

```promql
# scheduled step throughput vs ideal
1 - (
  (increase(train_ckpt_blocked_seconds_total[1d])
   + <restart_lost_seconds via recording rule on restarts × mean recompute>)
  / (86400 * <num_ranks>)
)
```

**MFU** (model FLOPs utilization): `MFU = tokens/s × 6 × params / (Ngpu × peak_flops)` — 6·P FLOPs/token for dense transformers (add the 12·L·H·Q·T attention term for the PaLM-exact numerator). The denominator is always the **dense** tensor peak: the PaLM paper, which set the MFU convention, uses A100 = 312 TFLOPS dense matmul — never the 2× "with sparsity" figures, which require 2:4 structured-sparse weights no standard training run has. Dense BF16/FP16 peaks for this project's GPUs (datasheet values, verified July 2026):

| GPU (instance) | Dense BF16/FP16 tensor peak | Trap to avoid |
|---|---|---|
| A100 SXM/PCIe, 40 & 80 GB (p4d/p4de) | **312 TFLOPS** | 624 is the sparse figure |
| A10G (g5) | **70 TFLOPS** | the widely quoted ~125 TFLOPS is the *A10's* dense number — a different SKU; A10G sparse is 140. Third-party spec pages (even AWS's G5 page) copy A10-class numbers onto the A10G |
| L4 (g6) | **121 TFLOPS** | NVIDIA's L4 datasheet prints sparse-first (242, with a "one-half without sparsity" footnote) |
| T4 (g4dn) | **65 TFLOPS, FP16 only** | Turing has no BF16 tensor path and no sparsity mode at all |

Quote a sparse peak (or an A10 number on an A10G) and your MFU is skewed ~2× — the most common MFU bug in the wild. Export MFU from rank 0. If you also report **HFU** (hardware FLOPs utilization): model FLOPs exclude activation recomputation — recompute counts only toward HFU (PaLM 540B: 46.2 % MFU vs 57.8 % HFU).

**Stragglers**: per-rank `train_step_seconds` histogram; a rank consistently >1.5× median is your suspect — correlate with `DCGM_FI_DEV_GPU_TEMP` (thermal throttling) and `DCGM_FI_DEV_SM_CLOCK`. **Hangs**: NCCL flight recorder dumps (`TORCH_NCCL_DUMP_ON_TIMEOUT`) tell you *which collective on which rank* stalled — practice reading one.

Deliverable: a Grafana "Training Reliability" dashboard (goodput %, MFU, restarts/day, MTTR, checkpoint overhead %, per-rank step-time heatmap) + a one-page weekly-review template. This *is* the job at scale.

## 12. Acceptance suite & NCCL troubleshooting matrix

Break it on purpose; every row is reproduced, documented, and fixed in `docs/nccl-debug-playbook.md`. These are the **training-job-level** checks — cluster-level validation (node burn-in, `dcgmi diag` levels, cluster-wide nccl-tests sweeps, topology labeling) lives in P15 (project-15-nvidia-networking-nccl-cluster-validation.md); cross-reference, don't duplicate.

| # | Failure (induce it) | Symptom | Detection | Fix / policy |
|---|---|---|---|---|
| 1 | **NCCL hang/timeout** — kill one worker mid-step | `Watchdog caught collective timeout`; surviving ranks block | flight-recorder dump (`TORCH_NCCL_DUMP_ON_TIMEOUT` + `TORCH_NCCL_TRACE_BUFFER_SIZE`), `NCCL_DEBUG=INFO` | restart-from-checkpoint policy; elastic re-rendezvous (Phase 5) |
| 2 | **Silent TCP fallback** — remove the `vpc.amazonaws.com/efa` resource limit | job "works" but slow | busbw baseline delta + absence of `Selected provider is efa` log line | restore the EFA limit; verify SG self-referencing all-traffic rule |
| 3 | **/dev/shm too small** — drop the shm mount | NCCL bus error | error string in worker logs | memory-backed `emptyDir` ≥ 8Gi — the fix everyone learns once |
| 4 | **Straggler** — `stress-ng` one node's CPUs | step time = slowest worker | per-rank `train_step_seconds` >1.5× median; DCGM temp/SM-clock correlation | topology/health-aware placement (P07 TAS, P15 health gates) |
| 5 | **Version skew** — mismatch NCCL between images | cryptic init/collective errors | error taxonomy in playbook | pin training images monorepo-style |
| 6 | **GPU XID** — inject via `/dev/kmsg` | `NodeCondition GpuXidError=True` | NPD custom plugin + `DCGM_FI_DEV_XID_ERRORS` | remediator cordon→drain→replace; elastic resume (Phases 6–7) |

**Pre-flight acceptance gate** (labs really do this): run a 60-s NCCL allreduce + `dcgmi diag -r 1` as an initContainer; refuse to start training on a sick node. Wire it into the JobSet template and show a sick node getting rejected.

## 13. Done criteria & interview ammo

- [ ] `Selected provider is efa` captured; busbw table TCP vs EFA published (all_reduce + all_gather + reduce_scatter)
- [ ] 2-node FSDP converging; scaling-efficiency + memory table published
- [ ] ZeRO-3 comparison page written (stage-2 vs stage-3 deltas included)
- [ ] Kueue gates the whole PyTorchJob as one gang (no partial 1-node starts)
- [ ] All six matrix failures reproduced with fixes
- [ ] Kill-a-node drill: training resumes automatically, ≤100 steps lost, MTTR recorded
- [ ] Spot-reclaim drill (SIGTERM path) with graceful checkpoint
- [ ] Goodput measured before/after async checkpointing (show the improvement)
- [ ] One NCCL hang diagnosed from a flight-recorder dump (induce via `iptables` drop between ranks)
- [ ] MFU on the dashboard computed against **dense** peaks (70 TFLOPS on g5, 121 on g6, 312 on A100)

**Resume bullet:** *"Built and operated a multi-node training platform on EKS: EFA/RDMA fabric benchmarked with nccl-tests (X Gb/s busbw, Y× over TCP), 2-node FSDP + DeepSpeed ZeRO-3 via Kubeflow with measured scaling efficiency, elastic torchrun + JobSet/Kueue with topology-aware placement, async sharded checkpointing (NVMe→S3) cutting checkpoint stall >90 %, XID-based node health detection (NPD/DCGM) with an automated cordon-drain-replace remediation controller (Karpenter), and goodput/MFU/straggler dashboards — sub-5-minute MTTR for injected GPU failures."*

Whiteboard-ready: ring-AllReduce byte math (2(N−1)/N × size); why FSDP trades memory for comms and where that stops paying; EFA/SRD vs InfiniBand vs RoCE in 90 seconds; how you *detect* that a fabric silently degraded; why gang scheduling is a prerequisite for any of this; why the MFU denominator is the dense peak and what happens when someone quotes the sparse number.

## 14. Teardown & budget

Fabric nodes are the expensive kind: `make down` deletes MPIJob/PyTorchJob, scales the `gpu-efa` NodePool limits to 0, verifies `kubectl get nodeclaims` empty — set a phone timer when you start a session, seriously. Platform logic runs on 4× g5.xlarge spot. Only the P15 EFA window needs A100s (p4d ≈ $22/hr on-demand as of July 2026 — down from the old $32 list price; P15 is the only project that pays for it). `kubectl delete jobset -A --all && eksctl delete nodegroup training-*`; empty the S3 ckpt bucket (lifecycle rule: expire after 7 days).

## 15. Extensions

- **TorchFT** (per-step fault-tolerant HSDP without full group restarts) — deploy its Lighthouse and compare restart cost vs. elastic torchrun. Label it honestly: experimental, nightly-wheels-only with no versioned release as of July 2026, but demonstrated at scale (PyTorch blog: Llama training through ~2,000 synthetic failures at ~15-s intervals with no checkpoint recovery).
- **Ray Train** version of the same pipeline — compare operator ergonomics with Kubeflow (favorite panel question).
- **Gradient compression** (PowerSGD hook) on the TCP path — measure whether it closes the EFA gap at this model size.
- Export **per-rank step time + collective time** to Prometheus; alert on straggler ratio >1.3× — feeds P12's AIOps (project-12-ai-fleet-sre-finops-aiops.md).
- Swap your DIY remediator for **Karpenter Node Auto Repair** (alpha, `NodeRepair=true`) + the EKS node monitoring agent and compare MTTR against your controller.

## 📣 Build in public

- **LinkedIn post:** publish your TCP-vs-EFA busbw table (8 MB → 1 GB sweep across all_reduce/all_gather/reduce_scatter) next to the 2-node FSDP scaling-efficiency number, and explain why the network — not the GPUs — set the ceiling at 0.5B scale.
- **X/Twitter thread:** live-tweet the kill-a-node drill with timestamps — XID injected via `/dev/kmsg` → NPD condition → cordon/drain → Karpenter replacement → elastic re-rendezvous — closing with the measured MTTR and steps lost (≤100).
- **YouTube demo:** screen-record goodput before vs after enabling `dcp.async_save` (checkpoint-stall seconds on the dashboard dropping >90 %), then walk through a real NCCL flight-recorder dump and name the exact collective and rank that hung.
