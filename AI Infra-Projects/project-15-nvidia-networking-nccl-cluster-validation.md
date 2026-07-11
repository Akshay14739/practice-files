# Project 15 — Fabric: GPU Networking, NCCL Performance & Cluster Validation (NVIDIA 3/3)

**Difficulty:** ★★★★★ | **Time:** 3 weekends (mostly prep) + one 2–3 hr paid GPU window | **Cost:** ~$0 prep + $70–140 for one 2-hr 2×p4d window (share it with P10's multi-node drill)

## 1. The production problem

This is the project version of your uploaded **GPU-neocloud JD**, almost line for line: *"bare metal GPU node infrastructure, CNI configuration, GPU Operator setup, distributed storage backends, and RDMA/InfiniBand… deploy and validate Kubernetes… GPU-powered managed K8s."* When a lab receives 1,000 GPUs, someone must prove the **fabric** delivers before a single training job runs — because a cluster that trains at 60 % of expected NCCL bandwidth silently doubles the cost of every run. That validation/acceptance discipline (NVIDIA formalizes it for SuperPODs; every cloud team reinvents it) is a hireable specialty in itself.

Concepts you'll own: **RDMA** (NIC reads/writes app memory directly, bypassing the kernel), **GPUDirect RDMA** (NIC ↔ GPU HBM directly, bypassing host RAM — the difference between ~tens of GB/s and a bounce-buffer crawl), **EFA** (AWS's RDMA-class fabric: libfabric + SRD, its InfiniBand-equivalent role), **NVLink/NVSwitch** (intra-node, ~an order of magnitude faster than the inter-node fabric — why topology-aware placement matters), and **NCCL** (the collectives library whose `busbw` number *is* your cluster's health).

## 2. Architecture

```
 eksctl: EFA-enabled nodegroup in ONE AZ + cluster placement group
   ├─ GPU Operator (drivers, DCGM)          ├─ aws-efa-k8s-device-plugin (vpc.amazonaws.com/efa)
   ├─ AMI ships EFA driver + aws-ofi-nccl (the NCCL→libfabric shim)
   └─ Kubeflow MPI Operator ─▶ nccl-tests MPIJobs (the measurement)
 Validation suite: dcgmi diag → gpu-burn → NCCL intra-node → NCCL inter-node
                   → storage fio (FSx Lustre) → signed acceptance report
 Scheduling tie-in: topology.k8s.aws/network-node-layer-* labels → Kueue TAS / your P07 scheduler
```

## 3. Phase 1 — provision the fabric correctly ($0 until apply)

`cluster.yaml` (eksctl does the EFA heavy lifting — launch-template ENIs, security groups):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata: {name: fabric-lab, region: us-east-1, version: "1.31"}
managedNodeGroups:
- name: gpu-efa
  instanceType: p4d.24xlarge          # 8×A100, 4×100 Gbps EFA. Budget rehearsal: see note below
  desiredCapacity: 2
  availabilityZones: ["us-east-1c"]   # ONE AZ — placement groups don't span AZs
  efaEnabled: true                    # attaches all EFA interfaces + self-referencing SG
  placement: {groupName: fabric-lab-pg}   # cluster placement group (create it first)
  capacityReservation: ...            # use ODCR/Capacity Blocks; p4d spot is scarce
```

Rules that bite people (memorize): one AZ; **cluster** placement group; the EFA security group must allow **all traffic to/from itself**; EFA pods need `hugepages-2Mi` and the `vpc.amazonaws.com/efa` resource; instance support varies (p4d/p5, g4dn.8xlarge+, g5.48xlarge, g6e families — verify against AWS's current EFA list). **Budget rehearsal:** the entire pipeline below runs first on 2× g4dn.8xlarge (~$2.2/hr each, EFA-capable) — wrong absolute numbers, right muscle memory; then one 2-hr p4d window for the real report.

Install the pieces the AMI doesn't schedule for you:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm upgrade -i aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin -n kube-system
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.6.0/deploy/v2beta1/mpi-operator.yaml
# GPU Operator from P08 (driver.enabled=false if the EKS GPU AMI ships drivers)
```

(On-prem/InfiniBand equivalent — one design-note paragraph: NVIDIA **Network Operator** manages RDMA device plugins/SR-IOV/OFED the way GPU Operator manages GPUs; name-dropping it correctly covers the JD's InfiniBand line.)

## 4. Phase 2 — the measurement: nccl-tests via MPIJob

```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata: {name: allreduce-2node}
spec:
  slotsPerWorker: 8
  runPolicy: {cleanPodPolicy: Running}
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          containers:
          - name: launcher
            image: <ecr>/nccl-tests:cuda12-efa    # aws-samples/awsome-distributed-training has Dockerfiles
            command: ["mpirun","--allow-run-as-root","-np","16","--map-by","ppr:8:node",
              "-x","FI_PROVIDER=efa","-x","FI_EFA_USE_DEVICE_RDMA=1",
              "-x","NCCL_DEBUG=INFO","-x","NCCL_SOCKET_IFNAME=^lo,docker",
              "/opt/nccl-tests/build/all_reduce_perf","-b","8","-e","2G","-f","2","-g","1"]
    Worker:
      replicas: 2
      template:
        spec:
          containers:
          - name: worker
            image: <ecr>/nccl-tests:cuda12-efa
            resources:
              limits: {nvidia.com/gpu: 8, vpc.amazonaws.com/efa: 4,
                       hugepages-2Mi: 5120Mi, memory: 800Gi}
              requests: {memory: 800Gi}
```

**Reading the output** (this is the skill): `algbw` = bytes/time; **`busbw`** = algbw adjusted for the collective's traffic pattern (allreduce ×2(n−1)/n) — the hardware-comparable number. Run three ladders and tabulate busbw at 1 GiB:

1. **Intra-node** (1 node, `-g 8` equivalent via 8 ranks): NVLink path — expect very high (order 200+ GB/s on 8×A100; record yours).
2. **Inter-node with GPUDirect** (`FI_EFA_USE_DEVICE_RDMA=1`): p4d's 4×100 Gbps EFA ⇒ theoretical 50 GB/s; healthy runs land in the ~35–45 GB/s busbw ballpark at large sizes.
3. **Inter-node crippled** (`FI_PROVIDER=tcp` or RDMA off): watch it collapse — your control group, and the exact signature of a misconfigured production cluster.

Confirm the data path from `NCCL_DEBUG=INFO` logs: `NET/OFI Selected Provider is efa` and `[send/recv via NET/AWS Libfabric]`. Also run `all_gather_perf` and `reduce_scatter_perf` (FSDP's actual traffic), and small-message sizes (latency regime) not just bandwidth.

Tuning table to experiment with (one variable at a time, record deltas): `NCCL_ALGO=Ring|Tree`, `NCCL_PROTO=Simple|LL128`, `NCCL_BUFFSIZE`, `NCCL_NSOCKS_PERTHREAD` (TCP only), channels via `NCCL_MIN/MAX_CTAS`. The meta-lesson: defaults are good; you tune to *diagnose*, rarely to run.

## 5. Phase 3 — the acceptance suite (the deliverable)

`validate.sh` — run on every node/pair, emit a signed markdown report:

1. **Inventory**: `nvidia-smi -q` (ECC on, expected clocks), `nvidia-smi topo -m` (NVLink matrix — screenshot it; interviewers love it), `fi_info -p efa` (all EFA devices visible).
2. **Health**: `dcgmi diag -r 3` (add `-r 4` in the p4d window if time allows) — the NVIDIA burn-in standard; any fail ⇒ node rejected (your P10 remediator's admission gate).
3. **Stress**: `gpu-burn 600` per GPU — watch `DCGM_FI_DEV_GPU_TEMP`/`POWER_USAGE` for throttlers; a thermally weak GPU is tomorrow's straggler.
4. **Fabric**: the three NCCL ladders above; pass = ≥85 % of your recorded healthy baseline.
5. **Storage**: FSx-for-Lustre PVC + `fio` (seq read 1M×16 jobs, randread 4k) — checkpoints (P10) die on slow storage; record GB/s vs the filesystem's provisioned throughput. (Name Rook/Ceph and Weka as the self-managed alternatives — JD checkbox, honestly earned by comparison notes.)
6. **Topology proof**: `kubectl get nodes -L topology.k8s.aws/network-node-layer-3` — then run a 2-node NCCL job **with** Kueue TAS `podset-required-topology: …layer-3` vs **without**, on a >2-node pool. Same-leaf vs cross-spine busbw delta = the empirical justification for P07.

**Troubleshooting matrix** (build it from faults you *inject*): busbw ~single-digit GB/s ⇒ TCP fallback (provider/plugin missing) · pods Pending ⇒ EFA resource/hugepages absent · `fi_getinfo` errors ⇒ SG not self-referencing · good bandwidth, bad latency ⇒ cross-leaf placement · one slow rank ⇒ throttling GPU (DCGM temps) · NCCL hang ⇒ P10's flight recorder.

## 6. Done criteria & interview ammo

- [ ] Rehearsal on cheap EFA instances + one real p4d report with all six suite sections.
- [ ] GPUDirect on/off and same-leaf/cross-spine deltas measured, not recited.
- [ ] Troubleshooting matrix validated by injected faults.

**Resume bullet:** *"Built a GPU-cluster validation & acceptance pipeline on EKS: EFA-enabled placement-grouped nodegroups, GPUDirect-RDMA NCCL benchmarking via MPIJobs (all_reduce/all_gather busbw ladders, intra- vs inter-node, tuning matrix), DCGM level-3 diagnostics and thermal stress gating, FSx Lustre fio validation, and topology-aware placement verification (Kueue TAS) — with a fault-injected troubleshooting runbook."*

**Teardown (do it immediately):** `eksctl delete nodegroup gpu-efa --cluster fabric-lab` the moment the report is written; then `eksctl delete cluster`. Set a billing alarm before the window.

## 7. Extensions

- **vCluster** per tenant on the validated pool (the JD's exact ask): validate once, hand out virtual clusters.
- p5/H100 delta study (32×EFA, 3200 Gbps) as a paper exercise with published numbers.
- Feed acceptance results into P12 as a "node birth certificate" metric; auto-quarantine on regression.
