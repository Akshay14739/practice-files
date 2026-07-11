# Project 10 — Endure: Fault-Tolerant Distributed Training & Goodput Engineering

**Difficulty:** ★★★★★ | **Time:** 4 weekends | **Cost:** ~$25–70 (4× g5 spot for the platform; one 2-hr multi-node A100/EFA window shared with P15)

## 1. The production problem

Meta's Llama-3 paper reports **466 job interruptions in 54 days** on a 16k-H100 run — ~78 % from hardware (GPU/HBM failures dominating). At that scale a *daily* failure is guaranteed; the difference between labs is not avoiding failures but **goodput**: the fraction of wall-clock GPU time producing useful training progress. Google, Meta, and cloud providers all publish goodput methodologies. Your first-track Ray/Kueue project ran distributed training; this project makes it *survive* — which is precisely the SRE-flavored AI-infra work your background maps to.

Failure taxonomy you'll handle: GPU **XID errors** (48/63/64 = memory/ECC, 79 = fell off the bus), NCCL timeouts/hangs, stragglers (one slow rank stalls all ranks — allreduce is synchronous), spot reclaims, and plain OOMs.

## 2. Architecture

```
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

## 3. Phase 1 — elastic, resumable training

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

Key ideas to internalize (and say out loud in interviews): **async, sharded** checkpointing (`dcp.async_save`) keeps GPUs busy during I/O — checkpoint *stall* drops from minutes to seconds; **hierarchical storage** (NVMe first, S3 async) is how big runs checkpoint every few minutes affordably; `--max-restarts` + resumable dataloader (store `step` in the checkpoint, seed/skip deterministically) makes restarts cheap.

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

`--nnodes=2:4` = **elastic**: lose a node and training re-rendezvouses at world size 3 instead of dying. Demonstrate it live.

## 4. Phase 2 — detect: turning kernel noise into NodeConditions

node-problem-detector custom plugin (DaemonSet) — `xid-check.sh`:

```bash
#!/bin/bash
# NPD custom-plugin contract: exit 0 = OK, 1 = problem; stdout = message
recent=$(dmesg --time-format iso 2>/dev/null | tail -2000 | grep -E "NVRM: Xid.*(48|63|64|74|79|94|95)")
if [ -n "$recent" ]; then echo "GPU XID detected: $(echo "$recent" | tail -1)"; exit 1; fi
exit 0
```

NPD config maps that to `NodeCondition: GpuXidError=True` + an Event. Also enable **DCGM background health checks** (GPU Operator ships DCGM; `dcgmi health -s a`) and scrape `DCGM_FI_DEV_XID_ERRORS`. Inject a fake failure for testing by writing a matching line via `/dev/kmsg` on a lab node.

## 5. Phase 3 — remediate: close the loop automatically

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

## 6. Phase 4 — goodput & straggler analytics

Definitions (Google-style): **goodput = productive time / total wallclock**, where productive excludes: init/rendezvous, checkpoint-blocked time, re-computation after restore (steps since last checkpoint), and hang time. Compute from your metrics:

```promql
# scheduled step throughput vs ideal
1 - (
  (increase(train_ckpt_blocked_seconds_total[1d])
   + <restart_lost_seconds via recording rule on restarts × mean recompute>)
  / (86400 * <num_ranks>)
)
```

**MFU** (model FLOPs utilization): `MFU = tokens/s × 6 × params / (Ngpu × peak_flops)` (6·P FLOPs/token for dense transformers; peak A10G BF16 ≈ 125 TFLOPs, A100 ≈ 312). Export it from rank 0. **Stragglers**: per-rank `train_step_seconds` histogram; a rank consistently >1.5× median is your suspect — correlate with `DCGM_FI_DEV_GPU_TEMP` (thermal throttling) and `DCGM_FI_DEV_SM_CLOCK`. **Hangs**: NCCL flight recorder dumps (`TORCH_NCCL_DUMP_ON_TIMEOUT`) tell you *which collective on which rank* stalled — practice reading one.

Deliverable: a Grafana "Training Reliability" dashboard (goodput %, MFU, restarts/day, MTTR, checkpoint overhead %, per-rank step-time heatmap) + a one-page weekly-review template. This *is* the job at scale.

## 7. Done criteria & interview ammo

- [ ] Kill-a-node drill: training resumes automatically, ≤100 steps lost, MTTR recorded.
- [ ] Spot-reclaim drill (SIGTERM path) with graceful checkpoint.
- [ ] Goodput measured before/after async checkpointing (show the improvement).
- [ ] One NCCL hang diagnosed from a flight-recorder dump (induce via `iptables` drop between ranks).

**Resume bullet:** *"Built a fault-tolerant training platform on EKS: elastic torchrun + JobSet/Kueue with topology-aware placement, async sharded checkpointing (NVMe→S3) cutting checkpoint stall >90 %, XID-based node health detection (NPD/DCGM) with an automated cordon-drain-replace remediation controller (Karpenter), and goodput/MFU/straggler dashboards — sub-5-minute MTTR for injected GPU failures."*

## 8. Teardown & budget

Platform logic on 4× g5.xlarge spot. Only the P15 EFA window needs A100s. `kubectl delete jobset -A --all && eksctl delete nodegroup training-*`; empty the S3 ckpt bucket (lifecycle rule: expire after 7 days).

## 9. Extensions

- **TorchFT** (fault-tolerant HSDP without full restarts) — deploy its lighthouse and compare restart cost vs. elastic torchrun.
- Ray Train version of the same pipeline (bridges to your first-track Ray project).
- Pre-flight gate: run a 60-s NCCL allreduce + `dcgmi diag -r 1` as an initContainer; refuse to start on a sick node (labs really do this).
