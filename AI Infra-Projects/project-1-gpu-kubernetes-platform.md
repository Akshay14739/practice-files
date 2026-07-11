# Project 1 — GPU-Ready Kubernetes Platform Foundation

> Build the layer every AI company runs on: an EKS cluster that can schedule, share, monitor, and autoscale **GPUs** — the exact substrate under vLLM at Anthropic-scale inference shops.

| | |
|---|---|
| **Difficulty** | Medium |
| **Time** | 2–3 weekends |
| **Cloud cost** | ~$0.20–0.55/hr while running (1× `g4dn.xlarge` spot + small system nodes). **Tear down after every session.** |
| **Skills proven** | Terraform, EKS, NVIDIA GPU Operator, device plugin, GPU **time-slicing**, DCGM observability, Karpenter GPU autoscaling |
| **JD keywords hit** | "NVIDIA GPU Operators, CUDA tooling, systems-level configuration for GPU nodes" · "Karpenter, KEDA, cert-manager add-ons" · "Terraform advanced modules" · "GPU/CUDA technologies integrated into infrastructure" |
| **Book/course mapping** | GenAI book ch. 3, 6, 10 · Big Data book ch. 3, 12 · Udemy: GPU architecture, CUDA, DCGM, autoscaling |

---

## 1. Why this project

Every JD you collected assumes you can answer: *"How does a pod actually get a GPU?"* Most DevOps engineers can't. After this project you can whiteboard the whole chain: **node → NVIDIA driver → container toolkit → device plugin → `nvidia.com/gpu` resource → scheduler → pod**, and you'll have Grafana dashboards of live GPU telemetry to prove it.

You already run EKS + Karpenter at Harman — this project extends *your existing strengths* one layer down into the GPU stack, which is the single highest-leverage move for the pivot.

## 2. Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ EKS (Terraform)                                                │
│                                                                │
│  system nodepool (t3.medium, on-demand)                        │
│   ├── karpenter controller                                     │
│   ├── kube-prometheus-stack (Prometheus + Grafana)             │
│   └── gpu-operator control pods                                │
│                                                                │
│  gpu nodepool (Karpenter-provisioned, g4dn spot, tainted)      │
│   ├── nvidia driver daemonset      ┐                           │
│   ├── container-toolkit daemonset  │ installed by GPU Operator │
│   ├── device-plugin daemonset      │                           │
│   └── dcgm-exporter daemonset      ┘ → /metrics → Prometheus   │
│                                                                │
│  workloads: cuda-vectoradd Job · 4× time-sliced test pods      │
└────────────────────────────────────────────────────────────────┘
```

## 3. Repo layout

```
gpu-platform/
├── terraform/
│   ├── main.tf            # VPC + EKS + Karpenter (modules)
│   ├── variables.tf
│   └── outputs.tf
├── karpenter/
│   ├── nodeclass-gpu.yaml
│   └── nodepool-gpu.yaml
├── gpu-operator/
│   ├── values.yaml
│   └── time-slicing-config.yaml
├── monitoring/
│   ├── kube-prometheus-values.yaml
│   └── dcgm-servicemonitor.yaml
├── workloads/
│   ├── cuda-vectoradd-job.yaml
│   └── timeslice-test.yaml
└── Makefile               # up / verify / down — cost safety
```

## 4. Phase 1 — Terraform the cluster

`terraform/main.tf` (trimmed to essentials; uses the community modules you already know):

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.80" }
    helm       = { source = "hashicorp/helm", version = "~> 2.16" }
  }
}

provider "aws" { region = var.region }

locals {
  name = "ai-platform"
  azs  = ["${var.region}a", "${var.region}b"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = local.name
  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true   # lab cost control

  # Karpenter discovers subnets by this tag
  private_subnet_tags = { "karpenter.sh/discovery" = local.name }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  # small system pool; ALL GPU capacity comes from Karpenter
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  node_security_group_tags = { "karpenter.sh/discovery" = local.name }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  node_iam_role_use_name_prefix = false
  node_iam_role_name    = "${local.name}-karpenter-node"
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.1.1"

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      annotations = { "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn }
    }
  })]
}
```

Apply:

```bash
cd terraform && terraform init && terraform apply
aws eks update-kubeconfig --name ai-platform --region <region>
kubectl get nodes   # 2 system nodes Ready
```

## 5. Phase 2 — Karpenter GPU NodePool

The pattern that matters in interviews: **GPU nodes are tainted, expensive, spot-first, and consolidated aggressively.**

`karpenter/nodeclass-gpu.yaml`:

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
    - alias: al2023@latest        # AL2023 accelerated AMI resolves via alias
  role: ai-platform-karpenter-node
  subnetSelectorTerms:
    - tags: { "karpenter.sh/discovery": ai-platform }
  securityGroupSelectorTerms:
    - tags: { "karpenter.sh/discovery": ai-platform }
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 100Gi, volumeType: gp3 }   # model images are big
```

`karpenter/nodepool-gpu.yaml`:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    metadata:
      labels: { workload-type: gpu }
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: gpu }
      taints:
        - key: nvidia.com/gpu          # nothing lands here without tolerating it
          effect: NoSchedule
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g4dn", "g5"]       # T4 (cheapest) and A10G
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["xlarge", "2xlarge"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]   # spot preferred automatically
  limits:
    nvidia.com/gpu: 2                  # hard cost ceiling for the lab
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s              # GPU $/hr makes fast scale-down critical
```

```bash
kubectl apply -f karpenter/
```

## 6. Phase 3 — NVIDIA GPU Operator (the heart of the project)

The GPU Operator installs **driver, container toolkit, device plugin, DCGM exporter, and node feature discovery** as DaemonSets — exactly how GPU neoclouds do it.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update

helm install gpu-operator nvidia/gpu-operator \
  -n gpu-operator --create-namespace \
  -f gpu-operator/values.yaml
```

`gpu-operator/values.yaml`:

```yaml
driver:
  enabled: true          # operator manages the driver (set false if using NVIDIA AMIs)
toolkit:
  enabled: true
devicePlugin:
  enabled: true
  config:                # wire in time-slicing (next step)
    name: time-slicing-config
    default: any
dcgmExporter:
  enabled: true
  serviceMonitor:
    enabled: true        # kube-prometheus-stack picks it up automatically
nfd:
  enabled: true
```

### GPU time-slicing — the interview differentiator

One T4 = one `nvidia.com/gpu`. Time-slicing advertises it as **4 virtual GPUs** so four small pods share it (no memory isolation — know this trade-off vs **MIG**, which is A100/H100-only hard partitioning).

`gpu-operator/time-slicing-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

```bash
kubectl apply -f gpu-operator/time-slicing-config.yaml
kubectl rollout restart ds/nvidia-device-plugin-daemonset -n gpu-operator
```

## 7. Phase 4 — Observability (DCGM → Prometheus → Grafana)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/kube-prometheus-values.yaml
```

`monitoring/kube-prometheus-values.yaml` (key bits):

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false   # scrape ALL ServiceMonitors
    podMonitorSelectorNilUsesHelmValues: false
grafana:
  adminPassword: admin   # lab only
```

Import Grafana dashboard **12239** (NVIDIA DCGM Exporter). The PromQL you should be able to explain cold:

```promql
DCGM_FI_DEV_GPU_UTIL                                  # utilization %
DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_TOTAL * 100      # VRAM %
DCGM_FI_DEV_GPU_TEMP                                  # thermals
rate(DCGM_FI_DEV_XID_ERRORS[5m])                      # the "GPU is dying" signal
```

## 8. Phase 5 — Validate everything

**Test 1 — a pod gets a GPU (triggers Karpenter from zero):**

`workloads/cuda-vectoradd-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: cuda-vectoradd }
spec:
  template:
    spec:
      restartPolicy: OnFailure
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      containers:
        - name: vectoradd
          image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
          resources:
            limits: { nvidia.com/gpu: 1 }
```

```bash
kubectl apply -f workloads/cuda-vectoradd-job.yaml
kubectl get nodeclaims -w            # watch Karpenter buy a g4dn spot node (~90s)
kubectl logs job/cuda-vectoradd      # "Test PASSED"
```

**Test 2 — time-slicing (4 pods, 1 physical GPU):**

```yaml
# workloads/timeslice-test.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: gpu-sharing-test }
spec:
  replicas: 4
  selector: { matchLabels: { app: gpu-share } }
  template:
    metadata: { labels: { app: gpu-share } }
    spec:
      tolerations:
        - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
      containers:
        - name: burn
          image: nvcr.io/nvidia/cuda:12.5.0-base-ubuntu22.04
          command: ["sh", "-c", "nvidia-smi && sleep infinity"]
          resources: { limits: { nvidia.com/gpu: 1 } }
```

All 4 pods schedule on **one** node → check `kubectl describe node` shows `nvidia.com/gpu: 4` allocatable. Watch Grafana utilization climb.

**Test 3 — scale-down economics:** delete the workloads, watch Karpenter consolidate the GPU node away within ~2 min. Screenshot the node lifecycle for your portfolio — *this is the FinOps story*.

## 9. Teardown (non-negotiable)

```makefile
down:
	kubectl delete -f workloads/ --ignore-not-found
	kubectl delete nodepool gpu --ignore-not-found   # kills GPU nodes
	helm uninstall gpu-operator -n gpu-operator || true
	helm uninstall kps -n monitoring || true
	cd terraform && terraform destroy -auto-approve
```

## 10. Interview ammunition

Resume bullets this project earns you (use your real numbers):

- *"Built a GPU-enabled Kubernetes platform on EKS with the NVIDIA GPU Operator; implemented time-slicing to raise effective GPU utilization 4× for sub-16GB workloads."*
- *"Designed Karpenter NodePools for spot-first GPU provisioning with 60-second consolidation, cutting idle GPU spend to near zero."*
- *"Instrumented fleet-wide GPU telemetry (DCGM → Prometheus → Grafana): utilization, VRAM, thermals, and XID error alerting."*

Whiteboard questions you can now answer: pod→GPU scheduling chain; time-slicing vs MPS vs MIG trade-offs; why GPU nodes are tainted; how DCGM XID errors predict hardware failure; driver/CUDA/framework version matrix hell.

## 11. Stretch goals

1. Swap `g5` in and configure **MIG** mode comparison doc (even without an A100, write the config and explain it).
2. Add **Node Problem Detector** + alert on XID errors.
3. Replace AL2023 with **Bottlerocket** and document the driver implications.
4. Write a Python `kubectl-gpu` plugin that prints per-node GPU allocation vs actual utilization (your first infra tool — feeds Project 6).
