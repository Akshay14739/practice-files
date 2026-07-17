# 📖 GLOSSARY

## Part 1 — ASR-error map (what the transcript says → what it means)

> The transcripts are auto-generated speech-to-text. These systematic mis-transcriptions are normalized silently in every section file. Extended as new ones are found while writing sections.

| Transcript says | Means |
|---|---|
| cube CTL / cube control / cube cuddle | `kubectl` |
| cube system | `kube-system` |
| Alb / amb | ALB (Application Load Balancer) |
| ECS cluster *(in K8s context)* | EKS cluster |
| ozone layer four/seven | OSI layer 4/7 |
| SIP service | ClusterIP service |
| Im role / II role / I am role | IAM role |
| x pod identity association | EKS Pod Identity Association |
| Pia | Pod Identity Agent / Pod Identity Association (context) |
| carpenter | Karpenter |
| helm charts → "hem charts" | Helm charts |
| terra form / terraform destroy auto approve | `terraform destroy -auto-approve` |
| Mysqldb | MySQL DB |
| TFConfig / TF configs | Terraform configuration files |
| ASCP | AWS Secrets & Configuration Provider (Secrets Store CSI provider for AWS) |
| ADOT | AWS Distro for OpenTelemetry |
| AMP / AMG | Amazon Managed Prometheus / Amazon Managed Grafana |
| PDB | PodDisruptionBudget |
| TSC | Topology Spread Constraints |
| LBC | AWS Load Balancer Controller |

| "P3 large" (S02) | **t3.large** (2 vCPU/8 GB) — P3 is a GPU family |
| "AT&T port" (S02) | the **8080** port |
| "terraform log dot HTML" (S06) | **`.terraform.lock.hcl`** — the dependency lock file |
| "Sidr / cinder / CI-d-r" (S06) | **CIDR** (`cidrsubnet`, `cidr_block`) |
| "flower brackets" | curly braces `{}` |
| "docker rem" | `docker rm` |
| "Pia agent / PII association" (S13+) | Pod Identity Agent / Pod Identity **A**ssociation |
| "pkg host" (S14) | `PGHOST` (psql env var) |
| "slash DT" (S14) | `\dt` (psql list tables) |
| "read this OS cash / reddest / Reddis" | Redis |
| "retail store DB secret one" | Secrets Manager secret `retailstore-db-secret-1` |
| "zinc / sink" (S16) | `sync` (ExternalDNS policy, vs `upsert-only`) |
| "Irca" (S16) | IRSA (IAM Roles for Service Accounts) |
| "spark node pool" (S17) | spot node pool |
| "card on / code on" (S17) | cordon |
| "trains are used to repel pods" (S17) | **taints** are used to repel pods |
| "Army / mi / Ami" (S17) | AMI; "Al 2023 at the rate latest" = `al2023@latest` |
| "x axis entry / ECS access entry" (S17) | EKS **access entry** (`EC2_LINUX` / `STANDARD`) |
| "TSS enabled" (S17) | SSE (SQS server-side encryption) |
| "Open Container Initial" (S17) | Open Container Initiative (OCI) |
| "max Q / max queue / max skew" (S18) | `maxSkew` (topology spread) |
| "2:56 a.m. I / 400 mi" (S18/19) | 256Mi / 400Mi (memory quantities) |
| "Hppa / HFPA" (S18) | HPA |
| "cards / Scott's / courts / Cod service" | carts (microservice) |
| "SCS" (S19) | SQS |
| "a dot / Adot" (S20) | ADOT (AWS Distro for OpenTelemetry) |
| "hotel / Otel / OT LP / what LP / OTC" (S20) | OTel / OTLP |
| "jogger / Jageer / Jaguar" (S20) | Jaeger |
| "z database / z request" (S20) | etcd |
| "See advisor / Si advisor" (S20) | cAdvisor |
| "reliable configs" (S20) | `relabel_configs` (Prometheus) |
| "seek for / SIG for / Sigv4" (S20) | SigV4 (AWS request signing) |
| "1313" (S20) | 13133 (OTel collector health-check port) |
| "Asia / Sha / a hyphen" (S21) | the `sha-` image-tag prefix |
| "QT colon colon seven" (S21) | `${GITHUB_SHA::7}` |
| "or DC / Oidc" (S21) | OIDC |
| "value siphon UI" (S21) | `values-ui.yaml` |
| "cruds" (S21) | CRDs |
| "sinking" (S21) | syncing (Argo CD) |

*(New entries get appended here per section as they're discovered.)*

## Part 2 — AWS ↔ Kubernetes ↔ plain-English term map

| AWS term | Kubernetes term | Plain English |
|---|---|---|
| EKS | (managed) control plane | AWS runs the K8s brain for you |
| EC2 node group | worker nodes | The VMs your pods run on |
| EKS Pod Identity Association | ServiceAccount → IAM role binding | Lets a pod call AWS APIs as a role, no keys |
| ALB (via LBC) | Ingress | The HTTP(S) front door routing by host/path |
| NLB | Service `type: LoadBalancer` | L4 load balancer per service |
| EBS volume (CSI) | PersistentVolume | A disk that follows the pod's claim |
| gp3 StorageClass | StorageClass | Template that creates the disk on demand |
| Secrets Manager (+ ASCP) | Secret / SecretProviderClass | Central vault mounted/synced into pods |
| Route 53 (+ ExternalDNS) | Ingress/Service annotations | DNS records auto-managed from cluster state |
| Karpenter | node autoscaler (NodePool/EC2NodeClass) | Provisions right-sized EC2 just-in-time |
| CloudWatch / X-Ray / AMP | logs / traces / metrics backends | Where ADOT ships the three signals |
| ECR | image registry | Where CI pushes, where nodes pull |
| GitHub OIDC provider | — | CI authenticates to AWS with no stored keys |
| ArgoCD | GitOps CD controller | Cluster state reconciled from a Git repo |

*(Extended per section.)*
