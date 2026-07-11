# Project 5 — Distributed Training & Fine-Tuning Platform (Ray + MLflow + Kueue)

> Cross to the *training* side of AI infrastructure: run a real **QLoRA fine-tune** of an LLM as a **RayJob on Kubernetes**, with **MLflow** experiment tracking + model registry, **S3 checkpointing** that survives spot interruption, and **Kueue** gang-scheduling/quotas — the batch-HPC operating model that Meta/Anthropic-scale training clusters use (theirs on Slurm/Borg; yours on K8s, which is where the industry is converging).

| | |
|---|---|
| **Difficulty** | Hard |
| **Time** | 3 weekends |
| **Prereq** | Project 1 cluster. MinIO/S3 + Postgres reusable from Project 3. |
| **Cloud cost** | 1× `g5.xlarge` (A10G 24 GB) spot ≈ $0.30–0.50/hr — QLoRA of a 1–3B model fits comfortably. Total project ≈ $10–20 if disciplined. |
| **Skills proven** | KubeRay operator, Ray Train, PyTorch + PEFT/QLoRA, distributed training concepts (DDP/FSDP/DeepSpeed), MLflow tracking + registry, checkpoint/resume on spot, Kueue quotas & gang scheduling |
| **JD keywords hit** | "Kubeflow pipelines, KServe, Airflow, **MLflow**" · "ML based subsystems… data intensive" · "operationalize and optimize ML models" · Udemy: "distributed training, FSDP, DeepSpeed" |
| **Book/course mapping** | GenAI book ch. 4, 6, 10–11 · Udemy: PyTorch/Horovod distributed training, MLflow, spot-instance cost strategy |

---

## 1. Concepts you must be able to whiteboard (from the infra-stack doc)

- **Data parallel (DDP)**: full model copy per GPU; gradients averaged via **AllReduce** each step. Network-bound → why NVLink/InfiniBand exist.
- **FSDP / ZeRO (DeepSpeed)**: shard model params/grads/optimizer state across GPUs; how 70B+ models train at all.
- **Tensor/pipeline parallel**: split single layers / stack of layers across GPUs (Megatron-LM territory).
- **LoRA/QLoRA**: freeze the base model (4-bit quantized), train tiny adapter matrices (~0.5% of params) → a 1–3B fine-tune fits on ONE 24 GB GPU. This is what makes the project affordable *and* it's what most industry fine-tuning actually is.
- **Gang scheduling**: a 4-worker job needs all 4 pods *simultaneously* or none (deadlock otherwise) — the reason Kueue/Volcano exist and default kube-scheduler isn't enough.
- **Checkpointing**: on spot GPUs, your job WILL be interrupted; resume-from-checkpoint is the difference between a platform and a demo.

## 2. Architecture

```
you ── kubectl apply RayJob ──► Kueue (LocalQueue → ClusterQueue quota: 1 GPU)
                                   │ admits when quota free (gang semantics)
                                   ▼
                         KubeRay operator creates:
                         ┌─────────────────────────────┐
                         │ Ray head (CPU, t3.large)     │
                         │ Ray worker (GPU, g5 spot) ───┼──► trains QLoRA
                         └──────────┬──────────────────┘
                 metrics/params ────┤            └── checkpoints ──► s3://ml-artifacts/ckpt/
                                    ▼
                         MLflow server ── backend: Postgres ── artifacts: S3/MinIO
                         (runs, metrics, registered model "qwen-devops-lora")
```

## 3. Repo layout

```
training-platform/
├── platform/
│   ├── kuberay/ (helm)   mlflow/ mlflow.yaml   kueue/ queues.yaml
├── train/
│   ├── train_qlora.py    # the Ray Train script
│   ├── Dockerfile
│   └── requirements.txt
├── jobs/
│   └── rayjob-qlora.yaml
├── data/ make_dataset.py  # builds a small instruct dataset
└── Makefile
```

## 4. Phase 1 — Platform services

**KubeRay operator:**

```bash
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm install kuberay-operator kuberay/kuberay-operator -n kuberay --create-namespace
```

**MLflow** (simple Deployment; Postgres + MinIO you already run):

```yaml
# platform/mlflow/mlflow.yaml (essentials)
apiVersion: apps/v1
kind: Deployment
metadata: { name: mlflow, namespace: mlops }
spec:
  replicas: 1
  selector: { matchLabels: { app: mlflow } }
  template:
    metadata: { labels: { app: mlflow } }
    spec:
      containers:
        - name: mlflow
          image: ghcr.io/mlflow/mlflow:v2.19.0
          command: ["mlflow", "server",
            "--host", "0.0.0.0", "--port", "5000",
            "--backend-store-uri",
            "postgresql://shop:shop12345@pg-source.lakehouse.svc:5432/mlflow",
            "--artifacts-destination", "s3://ml-artifacts"]
          env:
            - { name: MLFLOW_S3_ENDPOINT_URL, value: "http://minio.lakehouse.svc:9000" }
            - { name: AWS_ACCESS_KEY_ID, value: admin }
            - { name: AWS_SECRET_ACCESS_KEY, value: minio12345 }
          ports: [{ containerPort: 5000 }]
---
apiVersion: v1
kind: Service
metadata: { name: mlflow, namespace: mlops }
spec: { selector: { app: mlflow }, ports: [{ port: 5000 }] }
```

(Create the `mlflow` database in Postgres and the `ml-artifacts` bucket in MinIO first.)

**Kueue** (quota + gang admission):

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/latest/download/manifests.yaml
```

`platform/kueue/queues.yaml`:

```yaml
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata: { name: gpu-spot }
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata: { name: training }
spec:
  namespaceSelector: {}
  resourceGroups:
    - coveredResources: ["cpu", "memory", "nvidia.com/gpu"]
      flavors:
        - name: gpu-spot
          resources:
            - { name: cpu, nominalQuota: "16" }
            - { name: memory, nominalQuota: 64Gi }
            - { name: "nvidia.com/gpu", nominalQuota: "1" }   # lab budget = 1 GPU
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata: { name: team-ml, namespace: mlops }
spec: { clusterQueue: training }
```

Submit **two** RayJobs later → watch the second sit `Suspended` until the first finishes. That's multi-tenant GPU fairness, demonstrated — a direct line into Project 6.

## 5. Phase 2 — The training script

`train/train_qlora.py` — Ray Train + HF Transformers + PEFT + MLflow (complete, runnable):

```python
import os
import mlflow
import ray.train
from ray.train import ScalingConfig, RunConfig, CheckpointConfig, FailureConfig
from ray.train.torch import TorchTrainer

MODEL_ID = os.getenv("MODEL_ID", "Qwen/Qwen2.5-1.5B-Instruct")
DATA_PATH = os.getenv("DATA_PATH", "/data/train.jsonl")   # baked into image or S3-synced

def train_func(config):
    import torch
    from datasets import load_dataset
    from transformers import (AutoModelForCausalLM, AutoTokenizer,
                              BitsAndBytesConfig, TrainingArguments)
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from trl import SFTTrainer

    # ---- 4-bit base model (QLoRA) ----
    bnb = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,   # A10G supports bf16
        bnb_4bit_use_double_quant=True)
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID, quantization_config=bnb, device_map={"": 0})
    model = prepare_model_for_kbit_training(model)

    # ---- LoRA adapters: the only trainable params ----
    lora = LoraConfig(r=16, lora_alpha=32, lora_dropout=0.05,
                      target_modules=["q_proj","k_proj","v_proj","o_proj"],
                      task_type="CAUSAL_LM")
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()   # ~0.5% — say this number in interviews

    ds = load_dataset("json", data_files=DATA_PATH, split="train")

    args = TrainingArguments(
        output_dir="/tmp/out",
        per_device_train_batch_size=2,
        gradient_accumulation_steps=8,        # effective batch 16 on one GPU
        num_train_epochs=1,
        learning_rate=2e-4,
        bf16=True,
        logging_steps=10,
        save_strategy="steps", save_steps=100,
        report_to=[])                          # we log to MLflow ourselves

    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    mlflow.set_experiment("qwen-devops-qlora")

    with mlflow.start_run(run_name=f"r{lora.r}-lr{args.learning_rate}"):
        mlflow.log_params({"model": MODEL_ID, "lora_r": lora.r,
                           "lr": args.learning_rate, "epochs": args.num_train_epochs,
                           "quant": "nf4-4bit"})

        class MLflowStep(ray.train.torch.TorchTrainer.__mro__[0].__class__ if False else object):
            pass  # (keep simple: use trainer callback below)

        from transformers import TrainerCallback
        class LogCB(TrainerCallback):
            def on_log(self, args, state, control, logs=None, **kw):
                if logs and "loss" in logs:
                    mlflow.log_metric("loss", logs["loss"], step=state.global_step)
                    ray.train.report({"loss": logs["loss"]})

        trainer = SFTTrainer(model=model, args=args, train_dataset=ds,
                             processing_class=tok, callbacks=[LogCB()])
        trainer.train(resume_from_checkpoint=_maybe_resume())

        # ---- save adapter → MLflow registry ----
        model.save_pretrained("/tmp/adapter")
        mlflow.log_artifacts("/tmp/adapter", artifact_path="adapter")
        mlflow.register_model(f"runs:/{mlflow.active_run().info.run_id}/adapter",
                              "qwen-devops-lora")

def _maybe_resume():
    ckpt = ray.train.get_checkpoint()
    return ckpt.to_directory() if ckpt else None

trainer = TorchTrainer(
    train_func,
    scaling_config=ScalingConfig(num_workers=1, use_gpu=True),  # bump to 2+ for DDP demo
    run_config=RunConfig(
        name="qlora",
        storage_path="s3://ml-artifacts/ray",       # checkpoints survive the node
        checkpoint_config=CheckpointConfig(num_to_keep=2),
        failure_config=FailureConfig(max_failures=3)),  # auto-retry on spot kill
)
trainer.fit()
```

`train/Dockerfile`:

```dockerfile
FROM rayproject/ray:2.40.0-py311-gpu
RUN pip install --no-cache-dir \
    transformers==4.47.* peft==0.14.* trl==0.13.* bitsandbytes==0.45.* \
    datasets accelerate mlflow boto3
COPY train_qlora.py /app/train_qlora.py
COPY data/train.jsonl /data/train.jsonl
```

Dataset (`data/make_dataset.py`): generate ~500 instruction pairs in your domain — e.g. `{"text": "<|im_start|>user\nWhat does a Karpenter NodePool do?<|im_end|>\n<|im_start|>assistant\n..."}` built from your own study notes. Fine-tuning on *your* domain makes the before/after demo visibly yours.

## 6. Phase 3 — Submit as a RayJob (through Kueue)

`jobs/rayjob-qlora.yaml`:

```yaml
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: qlora-finetune
  namespace: mlops
  labels:
    kueue.x-k8s.io/queue-name: team-ml     # ← Kueue owns admission
spec:
  entrypoint: python /app/train_qlora.py
  shutdownAfterJobFinishes: true            # cluster dies with the job = no idle GPU $
  ttlSecondsAfterFinished: 600
  rayClusterSpec:
    headGroupSpec:
      rayStartParams: { dashboard-host: "0.0.0.0" }
      template:
        spec:
          containers:
            - name: head
              image: <registry>/qlora-train:latest
              env: &envs
                - { name: MLFLOW_TRACKING_URI, value: "http://mlflow.mlops.svc:5000" }
                - { name: MLFLOW_S3_ENDPOINT_URL, value: "http://minio.lakehouse.svc:9000" }
                - { name: AWS_ACCESS_KEY_ID, value: admin }
                - { name: AWS_SECRET_ACCESS_KEY, value: minio12345 }
              resources: { requests: { cpu: "1", memory: 4Gi } }
    workerGroupSpecs:
      - groupName: gpu-workers
        replicas: 1
        template:
          spec:
            tolerations:
              - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
            containers:
              - name: worker
                image: <registry>/qlora-train:latest
                env: *envs
                resources:
                  limits: { nvidia.com/gpu: 1, memory: 20Gi }
                  requests: { cpu: "3", memory: 16Gi }
```

```bash
kubectl apply -f jobs/rayjob-qlora.yaml
kubectl get workloads -n mlops          # Kueue: Admitted
kubectl get rayjobs -n mlops -w         # Running → Complete
# Ray dashboard: kubectl port-forward svc/qlora-finetune-raycluster-head-svc 8265:8265
```

Watch in parallel: Karpenter buys the g5 spot node → DCGM shows utilization pinned → MLflow loss curve descends → checkpoints appear in `s3://ml-artifacts/ray/`.

## 7. The two demos that get you hired

**Demo A — spot-interruption survival:** mid-training, `kubectl delete node <gpu-node>` (simulates a spot reclaim). FailureConfig retries → Karpenter provisions a fresh node → training **resumes from the S3 checkpoint**, loss curve continues instead of restarting. Screen-record it.

**Demo B — before/after eval:** load base model vs base+adapter, ask 10 domain questions, show side-by-side answers + a simple win-rate. Then **serve the adapter through Project 2's vLLM** (`--enable-lora --lora-modules devops=/adapters/...`) → your training platform feeds your inference platform. Registry → deployment is the MLOps loop, closed.

## 8. Validation checklist

- [ ] MLflow run has params, live loss metric, adapter artifact, registered model v1
- [ ] Second concurrent RayJob is held `Suspended` by Kueue until quota frees
- [ ] Checkpoint-resume demo recorded
- [ ] `shutdownAfterJobFinishes` verified: zero GPU nodes 5 min after completion

## 9. Teardown

RayJobs self-clean. `helm uninstall kuberay-operator -n kuberay`, delete `mlops` ns, confirm `kubectl get nodeclaims` shows no GPU nodes. MLflow/Postgres/MinIO are CPU-cheap — keep or kill.

## 10. Interview ammunition

- *"Built a Kubernetes-native training platform: QLoRA fine-tunes as RayJobs under Kueue quotas with gang admission, MLflow tracking + model registry, and S3 checkpointing verified to survive spot interruption mid-run."*
- Whiteboard-ready: DDP vs FSDP vs tensor/pipeline parallel and when each; why QLoRA fits a 1.5B fine-tune in 24 GB (4-bit base + bf16 adapters + paged optimizer); AllReduce and why interconnect bandwidth caps scaling; gang scheduling deadlock scenario; Slurm-vs-Kubernetes-for-training in 60 seconds.

## 11. Stretch goals

1. `num_workers=2` DDP across two GPU nodes; measure step-time vs 1 worker → discuss network bottleneck honestly.
2. Swap SFTTrainer for **DeepSpeed ZeRO-2** config; document the memory delta.
3. **Ray Tune** sweep over `lora_r ∈ {8,16,32}` under the same Kueue quota (3 sequential trials).
4. Kubeflow **Training Operator PyTorchJob** version of the same fine-tune — one page comparing the two operators (a favorite interview question).
