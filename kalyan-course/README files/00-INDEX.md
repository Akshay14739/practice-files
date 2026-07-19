# 📚 Course Index — Ultimate DevOps Real-World Project Implementation on AWS

> **AWS EKS Kubernetes Karpenter DevOps Production Guide** · 21 sections · 235 lectures · 38h 15m — rebuilt as a study companion you can learn and execute from without watching the videos.
> Reference app: **5-microservice retail store** — UI (Spring Boot) · Catalog (Go → RDS MySQL) · Carts (Spring Boot → DynamoDB) · Orders (Spring Boot → RDS PostgreSQL + SQS) · Checkout (Node.js → ElastiCache Redis).
> Course repo clone: [`../devops-real-world-project-implementation-on-aws/`](../devops-real-world-project-implementation-on-aws/)

| # | Section file | One-line summary | Transcript source |
|---|---|---|---|
| 01 | [Project Overview](01-project-overview.md) | The retail-store microservices app, its architecture, and the course roadmap | `0)` |
| 02 | [Docker Commands](02-docker-commands.md) | Docker on EC2: terminology, pull/run/exec lifecycle, build & push to Docker Hub | `1)` |
| 03 | [Dockerfile Mastery](03-dockerfile-mastery.md) | Dockerfile instructions, multi-stage builds, build cache & prune strategies | `2)` |
| 04 | [Docker Compose](04-docker-compose.md) | Full retail store on one host: service definitions, depends_on, compose commands | `3)` |
| 05 | [Docker BuildKit / Buildx](05-docker-buildx.md) | Multi-platform (amd64+arm64) images, ARM verification, buildx cache | `4)` |
| 06 | [Terraform Basics](06-terraform-basics.md) | HCL foundation → production VPC → variable precedence → S3/DynamoDB remote state → modules | `5)` + `6)` |
| 07 | [Terraform EKS Cluster](07-terraform-eks-cluster.md) | Why K8s/EKS; cluster + nodegroup IAM; remote-state datasource; full EKS build via TF | `7)` |
| 08 | [Kubernetes Foundation](08-kubernetes-foundation.md) | Pods → Deployments → ClusterIP Services → ConfigMaps → StatefulSets + headless DNS | `8)` (part 1) |
| 09 | [Kubernetes Secrets](09-kubernetes-secrets.md) | K8s Secrets → EKS Pod Identity → Secrets Store CSI + ASCP → Secrets Manager for catalog | `8)` (tail) + `9)` + `10)` |
| 10 | [Kubernetes Persistent Storage](10-kubernetes-persistent-storage.md) | EBS CSI driver, SC/PV/PVC, volumeClaimTemplates → production swap to RDS MySQL | `11)` |
| 11 | [Kubernetes Ingress](11-kubernetes-ingress.md) | AWS Load Balancer Controller, NodePort, instance vs IP mode, HTTP → HTTPS ingress | `13)` |
| 12 | [Helm Package Manager](12-helm-package-manager.md) | Helm workflow, custom values, chart anatomy, package/publish to ECR, retail-store deploy | `14)` |
| 13 | [Terraform EKS with Add-Ons](13-terraform-eks-addons.md) | Automating PIA, LBC, EBS CSI, Secrets Store CSI installs via TF Helm provider | `15)` (part 1) |
| 14 | [Retail Store — AWS Data Plane](14-retailstore-aws-dataplane.md) | TF-built RDS/DynamoDB/ElastiCache/SQS + all 5 microservices wired to them | `15)` (part 2) |
| 15 | [Terraform EKS with ExternalDNS](15-terraform-eks-externaldns.md) | ExternalDNS controller: auto-managing Route 53 records from Ingress/Service | `16)` (part 1) |
| 16 | [Retail Store with ExternalDNS](16-retailstore-externaldns.md) | DNS-annotated Ingress HTTP/HTTPS + ACM demo end to end; upsert-only vs sync | `16)` (part 2) |
| 17 | [Autoscaling — Karpenter](17-karpenter-autoscaling.md) | Karpenter architecture, TF install, NodePools/EC2NodeClass, on-demand + Spot + PDB interruption handling | `17)` |
| 18 | [Autoscaling — HPA](18-hpa-autoscaling.md) | HPA + metrics server, PDB, Topology Spread Constraints, zone-aware scheduling demos | `18)` |
| 19 | [Helm Retail Store + AWS Data Plane](19-helm-retailstore-dataplane.md) | Versioned Helm charts (v1→v2) deploying the full app against the AWS data plane | `19)` |
| 20 | [Observability — OpenTelemetry](20-observability-opentelemetry.md) | ADOT: traces→X-Ray, logs→CloudWatch, metrics→AMP+AMG Grafana; cost-filtering health checks | `20)` |
| 20.5 | [Observability — Prometheus & Grafana](20.5-observability-prometheus-grafana.md) | **Alternative to §20:** self-hosted LGTM — Prometheus (metrics) + Loki (logs) + Tempo (traces) + Grafana, no AWS-managed fees | *extension* |
| 21 | [DevOps CI/CD Pipeline (GitOps)](21-cicd-gitops.md) | GitHub Actions (OIDC, no keys) → ECR → Helm values bump → ArgoCD auto-sync → EKS | `21)` |
| 22 | [Production Service Mesh — Istio](22-istio-project.md) | **Capstone extension:** STRICT mTLS, deny-by-default authz, weighted canary, circuit breaking, ACM gateway, Kiali — zero app changes | *extension* |

**Companion files:** [GLOSSARY.md](GLOSSARY.md) — ASR-error map + AWS↔K8s term map · [PROGRESS.md](PROGRESS.md) — checklist / resume point · [Istio_Learning_Ladder.md](../../Istio_Learning_Ladder.md) — climb the mesh mechanism before §22.

> **Extension sections (20.5, 22)** aren't from the course transcripts — they're resume-grade additions that reuse the same cluster + retail store app so you follow along hands-on **01 → 22**: §20.5 gives you the *second* (and interview-default) observability toolchain, and §22 puts a production Istio mesh over the whole platform.

## Key cross-cutting themes (instructor's own emphasis)
- **Cost:** ~70% savings via Karpenter Spot (S17); ~85% observability cost cut by filtering health-check traces (S20).
- **Zero downtime:** PDBs + Spot interruption handling (S17), TSC zone spreading (S18).
- **No static AWS keys:** EKS Pod Identity for pods (S09/S13), GitHub OIDC for CI (S21).
- **GitOps:** CI builds/pushes image + bumps Helm values → ArgoCD detects & syncs (S21).
