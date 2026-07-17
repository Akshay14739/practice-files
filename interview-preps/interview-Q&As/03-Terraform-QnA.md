# Terraform / IaC — Interview Q&A (from real interviews)

Consolidated and de-duplicated from Akshay's actual Terraform interview rounds (Compunnel, Trianz, Accion, PwC, Pure-SW, Shell, Persistent, HTC, GlobalLogic, HCL, Barclays, Virtusa).
Each question carries the faithful transcript answer, an authoritative correct answer, and a runnable HCL/CLI snippet. Weak spots are flagged with 🔴 — nail those before the next round.

---

## Q1. What is the difference between input variables and `.tfvars`?
**Asked in:** Trianz  |  **My performance:** Partial

**My answer (from transcript):**
The `variable` block provides input arguments to resource blocks; the `terraform.tfvars` file supersedes the variables' default values and provides the value to resource blocks.

**✅ Correct answer:**
They live at two different layers and you conflated them slightly.
- A `variable` block *declares* an input — its name, type, optional `default`, `description`, and `validation`. It does not hold environment-specific data; it defines the contract.
- A `.tfvars` file *assigns* concrete values to those declared variables for a particular run. `terraform.tfvars` and `*.auto.tfvars` are auto-loaded; any other file (e.g. `prod.tfvars`) must be passed with `-var-file`.
- Precedence (lowest → highest): `default` in the `variable` block → `terraform.tfvars` / `*.auto.tfvars` → `-var-file` → `-var` on the CLI → `TF_VAR_*` env vars. So `-var` beats a `.tfvars` file, which beats the declared `default`.
- Values do **not** go straight "into resource blocks" — you reference them as `var.<name>`.

```hcl
# variables.tf — declaration (the contract)
variable "instance_type" {
  type        = string
  default     = "t3.micro"          # used only if nothing overrides it
  description = "EC2 size"
}

# prod.tfvars — assignment for one environment (NOT auto-loaded)
instance_type = "m5.large"

# usage
resource "aws_instance" "app" {
  instance_type = var.instance_type
}
# terraform apply -var-file="prod.tfvars"
```

---

## Q2. Can you write a simple VPC in Terraform without using a module?
**Asked in:** Persistent  |  **My performance:** Partial

**My answer (from transcript):**
Verbally structured it (had screen-sharing issues): a `terraform` block (required providers, version, backend), a `provider` block (credentials profile, region) in `versions.tf`; `variables.tf` for CIDR; a VPC resources file with VPC, subnets, NAT gateway, internet gateway, route tables, and route-table–subnet associations. Structured modules folder plus per-environment folders with backend and tfvars.

**✅ Correct answer:**
The structure you named is right; the gap was not producing actual HCL. A minimal, correct VPC needs: `aws_vpc`, public/private `aws_subnet`, `aws_internet_gateway`, a NAT (`aws_eip` + `aws_nat_gateway`), route tables, and `aws_route_table_association`. Use references (not hardcoded IDs) so Terraform builds the dependency graph implicitly.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr           # e.g. "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

---

## Q3. How do you make `terraform apply` fail when required tags are missing?
**Asked in:** PwC-K8s  |  **My performance:** Partial

**My answer (from transcript):**
Put a CI/CD pipeline with an approval gate that checks tag format before merge to main; add pre-commit hooks / pipeline checks to validate the tag conditions, failing otherwise. (Did not mention Sentinel/OPA/policy-as-code or variable validation.)

**✅ Correct answer:**
A pipeline gate helps, but the interviewer wanted the *in-Terraform* enforcement you missed. Three layers, strongest last:
1. **Variable `validation` blocks** — fail `plan`/`apply` locally if a required tag key is absent.
2. **Policy-as-code** — HashiCorp **Sentinel** (TF Cloud/Enterprise) or **OPA/Conftest** in CI evaluate the plan JSON and reject non-compliant tags. This is the canonical answer.
3. **`default_tags`** on the provider so every resource inherits mandatory tags automatically (defence in depth, not enforcement).

```hcl
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["Owner", "Environment", "CostCenter"] : contains(keys(var.tags), k)])
    error_message = "tags must include Owner, Environment and CostCenter."
  }
}

# Provider-level guarantee that tags are applied everywhere:
provider "aws" {
  default_tags { tags = var.tags }
}
```
```rego
# OPA/Conftest against `terraform show -json tfplan`
deny[msg] {
  r := input.resource_changes[_]
  not r.change.after.tags.Owner
  msg := sprintf("%s is missing required tag 'Owner'", [r.address])
}
```

---

## Q4. Given 4 developers with microservices — what are the steps to deploy a microservice into an EKS cluster?
**Asked in:** Virtusa  |  **My performance:** Partial

**My answer (from transcript):**
Write Terraform scripts to provision the Lambda/resources, integrate to app repos (Helm/other Kubernetes objects), then test and promote the application code. (Somewhat conflated Lambda vs EKS microservice; high level.)

**✅ Correct answer:**
Separate the two planes cleanly (you mixed Lambda into an EKS question):
- **Infra plane (Terraform):** provision the EKS cluster, node groups/Karpenter, IRSA/pod-identity roles, and the container registry (ECR). Terraform stops at the platform; it should not deploy app pods.
- **App plane (GitOps/CD):** build image → push to ECR → package a Helm chart / Kustomize manifests (Deployment, Service, Ingress, HPA) → deploy via Argo CD or a CD pipeline. Argo CD continuously reconciles the desired state.

```bash
# Infra (once, per env)
terraform apply -var-file=prod.tfvars      # EKS + IRSA + ECR

# App (per release)
docker build -t $ECR/svc:$SHA . && docker push $ECR/svc:$SHA
helm upgrade --install svc ./chart --set image.tag=$SHA -n team-a
# Argo CD then reconciles the chart in Git to the cluster
```

---

## Q5. What is the Terraform workflow?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
`terraform init` (downloads providers/dependencies into `.terraform`), `terraform validate` (syntax), `terraform plan` (reads scripts, checks state bucket, determines what to create/modify), `terraform apply` (provision all or specific resources), and `terraform destroy` for unneeded resources.

**✅ Correct answer:**
Solid. To round it out: `init` also configures the backend and writes the dependency lock file (`.terraform.lock.hcl`); `fmt` canonicalises style; `validate` checks configuration validity (types/refs), not just syntax; `plan` refreshes state against real infra and produces a diff you can save with `-out`; `apply` executes that plan and updates state; `destroy` is `apply` of the deletion graph.

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan  -out=tfplan
terraform apply tfplan       # apply the exact reviewed plan
terraform destroy            # tear down
```

---

## Q6. When you run Terraform, what folder gets created, and what's in it?
**Asked in:** Trianz  |  **My performance:** Correct

**My answer (from transcript):**
The `.terraform` folder gets created where the provider dependencies are downloaded.

**✅ Correct answer:**
Correct. `terraform init` creates `.terraform/` holding downloaded provider plugins (`.terraform/providers/…`), module caches (`.terraform/modules/…`), and the backend config. Alongside it, init writes `.terraform.lock.hcl` — the **dependency lock file** pinning provider versions and checksums; commit *that* to Git, but `.terraform/` is machine-local and belongs in `.gitignore`.

```bash
$ terraform init
$ tree -a -L 2 .terraform
.terraform
├── providers/registry.terraform.io/hashicorp/aws/5.x/...
└── modules/modules.json
# commit .terraform.lock.hcl ; gitignore .terraform/ and *.tfstate
```

---

## Q7. What is the role of `versions.tf` — why do we mention it?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
It's common across all Terraform scripts; it holds the `terraform` block (downloads provider dependencies like AWS) and the `provider` block (connects and makes API calls from local scripts to AWS APIs so resources get provisioned and the S3 state file gets updated). Keeps common code reusable and less clumsy.

**✅ Correct answer:**
Right idea. Convention is to split concerns: `versions.tf` (or `terraform.tf`) holds the **`terraform` block** — `required_version`, `required_providers` (source + version constraints), and the `backend`. The **`provider` block** (region, profile, assume-role) is often kept in `providers.tf`. Pinning versions here makes builds reproducible across the team; the `.terraform.lock.hcl` then locks exact resolved versions.

```hcl
# versions.tf
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.40" }
  }
  backend "s3" { /* configured per environment */ }
}
```

---

## Q8. How does Terraform connect to the cloud / can it make an API call?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
Yes. During init the `terraform` block downloads provider dependencies into `.terraform`; the `provider` block connects the scripts to the remote cloud APIs (e.g. AWS API calls) to create the defined resources.

**✅ Correct answer:**
Correct. The **provider plugin** is the API client: it translates HCL resources into the cloud's REST/SDK calls, using credentials from the environment (env vars, shared profile, or an assumed role). Beyond CRUD on resources, `data` sources are read-only API queries, and the `external`/`http` providers let you make arbitrary calls. Terraform itself is just the engine building a dependency graph; the provider does the talking.

```hcl
provider "aws" {
  region  = "ap-south-1"
  profile = "platform"          # or assume_role { role_arn = ... }
}

data "aws_caller_identity" "me" {}   # a live read-only API call
output "account" { value = data.aws_caller_identity.me.account_id }
```

---

## Q9. What's the difference between a module and a resource block?
**Asked in:** Barclays, Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
A `resource` block represents an individual AWS resource provisioned via HCL; a `module` contains multiple resource blocks made reusable via variabilization so the same structure works across environments.

**✅ Correct answer:**
Correct. A `resource` is a single managed object (one API-backed thing). A **module** is a container of resources/data/other-modules exposed through `variables` (inputs) and `outputs` (return values) — the unit of reuse and versioning. The root directory you run `terraform` in is itself the "root module"; anything it calls via a `module` block is a child module.

```hcl
# resource: one thing
resource "aws_s3_bucket" "logs" { bucket = "acme-logs" }

# module: a reusable bundle, versioned and parameterised
module "network" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"
  cidr    = var.vpc_cidr
}
```

---

## Q10. How do you reference multiple child modules (IAM, S3, …) in your main module?
**Asked in:** Accion-1  |  **My performance:** Correct

**My answer (from transcript):**
In the main module use a `module` block with a custom name, define the `source` as the path to the child module, pass input variables, define outputs/custom logic, and set the lifecycle.

**✅ Correct answer:**
Correct conceptually. Each child is a `module` block with a `source` (local path, Git, or registry) and a pinned `version` for remote sources. Wire modules together by passing one module's **output** into another's **input** — that reference is what orders them in the graph (child modules don't take a top-level `lifecycle` block, though; lifecycle lives on the resources inside).

```hcl
module "iam" {
  source = "./modules/iam"
  name   = var.name
}

module "s3" {
  source     = "./modules/s3"
  bucket     = "${var.name}-data"
  reader_arn = module.iam.role_arn      # output of iam -> input of s3 (creates dependency)
}
```

---

## Q11. How does IaC differ from traditional infrastructure management?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Manual provisioning via console is tedious, slow, and error-prone, and backing up/auditing state is hard. IaC manages everything through code — easy to audit and manage — and with modules you get reusability across environments.

**✅ Correct answer:**
Good. Frame it around the four properties interviewers listen for: **declarative & reproducible** (same code → same infra), **version-controlled & auditable** (Git history = change log, PR review, rollback), **idempotent** (re-apply converges, no drift from click-ops), and **reusable/scalable** (modules parameterised per environment). Traditional click-ops is imperative, undocumented, and non-repeatable.

```hcl
# One reviewed, versioned definition replaces N manual console clicks:
module "eks" {
  source       = "./modules/eks"
  cluster_name = "prod"
  version      = "1.29"
}
# git blame shows who changed what, when, and why (PR link)
```

---

## Q12. What's the best practice for using IaC?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
Have dedicated modules for each critical resource, and for each module have environment folders with subfolders dedicated to each environment.

**✅ Correct answer:**
Right direction. The fuller checklist: **remote state** with locking (S3+DynamoDB or a native lock) and **isolated state per environment**; **small, versioned, single-purpose modules**; **no secrets in code or state** (pull from Vault/SSM/Infisical); **pin provider & module versions** + commit the lock file; **`plan` in CI on every PR, `apply` gated** behind review; **`prevent_destroy`/policy-as-code** on critical resources; and DRY environments (same code, different `.tfvars`/backend).

```hcl
# DRY: identical code, environment supplied at apply time
# envs/prod/backend.tf
terraform { backend "s3" { key = "prod/terraform.tfstate" } }
# envs/prod/prod.tfvars
environment = "prod"
node_count  = 6
```

---

## Q13. Are you familiar with Pulumi?
**Asked in:** Compunnel  |  **My performance:** Didn't know

**My answer (from transcript):**
No — not familiar (moved on).

**✅ Correct answer:**
One-line positioning is enough: **Pulumi** is IaC that lets you define infrastructure in general-purpose languages (TypeScript, Python, Go, C#) instead of a DSL, so you get loops, functions, unit tests, and IDE tooling natively. It uses a state model similar to Terraform's and can even reuse Terraform providers. Trade-off vs Terraform: more language power and testability, but HCL is simpler, more declarative, and has a larger ecosystem/community. (Terraform's own answer to "real languages" is **CDKTF**.)

```typescript
// Pulumi (TypeScript) — infra as real code
import * as aws from "@pulumi/aws";
const bucket = new aws.s3.Bucket("data", { versioning: { enabled: true } });
export const name = bucket.id;
```

---

# 🗄️ State management

## Q14. 🔴 How do you segregate the state file per environment so dev and prod state aren't mixed?
**Asked in:** Barclays  |  **My performance:** Incorrect

**My answer (from transcript):**
Said state can be in an S3 bucket with versioning. When pushed on per-environment segregation, suggested separate S3 buckets defined in each submodule's `versions.tf`. The interviewer kept pushing that identical code needs distinct state per env; I eventually admitted I couldn't recall — did not land it.

**✅ Correct answer (nail this):**
Versioning is durability, **not** segregation. With one codebase you get one state per environment in two standard ways:

1. **Backend `key` prefix per environment (recommended).** Same S3 bucket, different object key per env. You do *not* hardcode the backend per submodule — you keep `backend "s3" {}` partial and pass the key at init with `-backend-config` (a `backend.hcl` file per env). Distinct key ⇒ distinct state file ⇒ dev and prod never touch.

2. **Terraform workspaces.** `terraform workspace new prod` stores state under `env:/prod/…` automatically; select with `terraform workspace select`. Simple, but easy to apply to the wrong workspace, so many teams prefer explicit per-env backend keys for prod.

Either way the DynamoDB lock is keyed to the state path, so per-env state also means per-env locking.

```hcl
# backend.tf (partial — no key hardcoded)
terraform { backend "s3" {
  bucket         = "acme-tf-state"
  region         = "ap-south-1"
  dynamodb_table = "tf-locks"
}}
```
```bash
# Option 1: per-env key file  ->  distinct state object per env
# envs/dev/backend.hcl :  key = "dev/network.tfstate"
# envs/prod/backend.hcl:  key = "prod/network.tfstate"
terraform init -backend-config=envs/prod/backend.hcl

# Option 2: workspaces
terraform workspace new prod        # state at env:/prod/...
terraform workspace select prod
```

---

## Q15. 🔴 Where do you store `.tfvars` / sensitive values when working as a team (not locally)?
**Asked in:** Trianz  |  **My performance:** Partial

**My answer (from transcript):**
Passwords were "in the module itself" with an environments folder of `.tfvars`. When challenged, said they had Infisical integrated with GitHub to fetch from; when pushed for a general approach, said use Vault/Infisical to fetch secrets and run Terraform. (Initially gave the insecure answer.)

**✅ Correct answer (nail this):**
Lead with the secure answer, never the insecure one. **Secrets must not live in `.tfvars`, HCL, or Git** — and critically, **anything a resource consumes ends up in plaintext in the state file**, so state itself must be treated as sensitive (encrypted backend, tight IAM, never committed).
- Pull secrets at run time from **Vault / AWS Secrets Manager / SSM Parameter Store / Infisical** via a `data` source or the provider, so the value is fetched, not stored in VCS.
- Mark variables/outputs `sensitive = true` so they're redacted in plan/apply logs.
- Prefer **short-lived, dynamically-generated credentials** (e.g. Vault dynamic secrets, IAM roles/OIDC) over any static secret at all.
- Encrypt state at rest (SSE-KMS on S3) and restrict who can read it.

```hcl
# Fetch at apply time — nothing secret in Git
data "aws_secretsmanager_secret_version" "db" {
  secret_id = "prod/db/password"
}

resource "aws_db_instance" "db" {
  password = data.aws_secretsmanager_secret_version.db.secret_string
}

variable "api_token" { type = string, sensitive = true }   # redacted in logs
# NOTE: db password is still visible in terraform.tfstate -> encrypt + lock down state
```

---

## Q16. How do you handle the state file in a team to prevent conflicts?
**Asked in:** Compunnel, Persistent  |  **My performance:** Correct

**My answer (from transcript):**
Stored state in a dedicated S3 bucket; state locking enabled by default via the backend when multiple engineers work on the same state; enabled S3 versioning for safety. (Persistent: concurrent runs cause temporary locking — state is locked until the command completes, others wait.)

**✅ Correct answer:**
Correct. The mechanism worth naming explicitly: the **S3 backend locks via a DynamoDB table** (`LockID` item) — the first `plan`/`apply` acquires the lock, concurrent runs get `Error acquiring the state lock` and must wait. Versioning gives point-in-time recovery. (As of newer Terraform, S3 also supports native lockfile-based locking via `use_lockfile`, reducing the DynamoDB dependency.) If a run crashes mid-apply and the lock sticks, `terraform force-unlock <LOCK_ID>` clears it — carefully.

```hcl
terraform {
  backend "s3" {
    bucket         = "acme-tf-state"
    key            = "prod/network.tfstate"
    dynamodb_table = "tf-locks"     # <- the locking mechanism
    encrypt        = true
  }
}
# stuck lock after a crash:
# terraform force-unlock 3f2b1c9a-....
```

---

## Q17. Why do we use a state file, and how do you manage the remote backend?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
The state file is like the brain of Terraform — it tracks all current configuration changes (create/modify/delete) from the beginning. Since we enable versioning on the backend S3 buckets, it's recoverable.

**✅ Correct answer:**
Good metaphor. Precisely: state is the **mapping between your configuration and the real-world resource IDs**, plus cached attributes and resource dependencies. It's how Terraform knows a resource already exists (so `plan` diffs instead of recreating), and it enables `-target`, dependency ordering, and drift detection. A **remote backend** (S3+DynamoDB, or Terraform Cloud) makes it shared, locked, versioned, and encrypted — never keep prod state on a laptop.

```hcl
terraform {
  backend "s3" {
    bucket = "acme-tf-state"
    key    = "prod/eks.tfstate"
    encrypt = true
    dynamodb_table = "tf-locks"
  }
}
# inspect the mapping:  terraform state list ; terraform state show aws_eks_cluster.this
```

---

## Q18. How is change tracking done — what changed/was destroyed, who's authorized, can others review state?
**Asked in:** HCL  |  **My performance:** Partial

**My answer (from transcript):**
State in S3 with versioning. Architects audited state every week or two; only architects/platform team could review, anyone could view. (Interviewer suggested using a pipeline instead of manual CLI.)

**✅ Correct answer:**
Manual weekly audits are the weak part the interviewer flagged. Change tracking should be automated and layered:
- **Git + PR review** is the primary change log — every infra change is a reviewed diff, `terraform plan` posted on the PR shows exactly what will create/modify/**destroy**.
- **CI/CD pipeline** runs `plan` on PR and gated `apply` on merge, so nobody runs prod from a laptop.
- **State access** is controlled by **IAM policy on the S3 bucket/DynamoDB** (least privilege), with S3 **access logging / CloudTrail** for who-read-what, and KMS encryption. Humans rarely read raw state — they read `plan` output and Git history.

```bash
# In CI, on every PR: surface exactly what changes (incl. destroys)
terraform plan -out=tfplan
terraform show -no-color tfplan > plan.txt   # post to the PR for review
# S3 bucket policy limits state read/write to the platform role only
```

---

## Q19. Best practice to pass VPC CIDR, VPC ID, SG IDs, subnet IDs to an EKS module when the VPC already exists — not hardcoding, not tfvars?
**Asked in:** Virtusa  |  **My performance:** Correct

**My answer (from transcript):**
After hardcoding and tfvars were rejected, landed on: use a `data` source to retrieve the VPC/subnet details, store fetched values in a `locals` block, and feed those locals as inputs to the EKS module. Interviewer confirmed correct.

**✅ Correct answer:**
Correct — **query existing infrastructure with `data` sources** (or a `terraform_remote_state` read of the networking stack) so values are discovered at run time, never copied. Filter by tags to stay portable across accounts/regions.

```hcl
data "aws_vpc" "main" { tags = { Name = "prod-vpc" } }

data "aws_subnets" "private" {
  filter { name = "vpc-id"  values = [data.aws_vpc.main.id] }
  tags   = { Tier = "private" }
}

module "eks" {
  source     = "./modules/eks"
  vpc_id     = data.aws_vpc.main.id
  subnet_ids = data.aws_subnets.private.ids     # discovered, not hardcoded
  vpc_cidr   = data.aws_vpc.main.cidr_block
}
```

---

# 📦 Modules & reusable code

## Q20. Create a folder structure for multiple environments where the Terraform code is the same across all environments.
**Asked in:** Barclays, PwC-1, HCL, Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
An `environments` folder with `dev.tfvars` / `<env>.tfvars` per environment, and a submodule folder per resource (VPC, EC2, EKS…); the environment tfvars input drives which submodules provision resources. (Structure named, but state separation was not clearly explained — see Q14.)

**✅ Correct answer:**
The pattern is right; the missing piece is that each environment needs its **own backend/state**, not just its own `.tfvars`. Two common layouts:
- **Env-per-directory:** `envs/dev|stage|prod/` each with `backend.tf` + `<env>.tfvars`, all calling the same `modules/`. Explicit and safe for prod.
- **Workspaces:** one directory, `terraform workspace select prod`, state auto-namespaced.

```text
.
├── modules/
│   ├── vpc/        # reusable
│   └── eks/
└── envs/
    ├── dev/   { main.tf -> module "vpc"/"eks",  backend.tf(key=dev/…),  dev.tfvars }
    ├── stage/ { …                               backend.tf(key=stage/…), stage.tfvars }
    └── prod/  { …                               backend.tf(key=prod/…),  prod.tfvars }
```
```bash
cd envs/prod && terraform init -backend-config=backend.hcl && terraform apply -var-file=prod.tfvars
```

---

## Q21. How do you organize modules/repo so it's usable and safe — not one single state file?
**Asked in:** Accion-1  |  **My performance:** Partial

**My answer (from transcript):**
Divided by environments (dev, integration, production) using environment `.tfvars`. Main module referenced submodules — VPC, EKS, ArgoCD, external secrets, IAM roles — with inputs from `.tfvars`. (Did not clearly explain state separation.)

**✅ Correct answer:**
Two orthogonal decisions the interviewer was probing:
1. **Separate state by environment** (per-env backend key/workspace) — so a bad `apply` in dev can't corrupt prod.
2. **Separate state by blast radius / lifecycle** — split networking, cluster, and app-platform into their own state files (a.k.a. "stacks"), wired together via `terraform_remote_state` or data sources. A single monolithic state means one lock for everyone and a huge blast radius. Keep long-lived infra (VPC) in its own state from fast-changing infra (app roles).

```hcl
# app stack reads the network stack's outputs instead of sharing one state
data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = "acme-tf-state", key = "prod/network.tfstate", region = "ap-south-1" }
}
module "eks" {
  source     = "./modules/eks"
  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}
```

---

## Q22. Are you maintaining an umbrella pattern, or is it all one repo? How big was the infra?
**Asked in:** Accion-1  |  **My performance:** Vague

**My answer (from transcript):**
Resources were in one single repository. Multiple teams each had their own infra setup; his team helped compose data/manifests and organize them. Stayed high-level.

**✅ Correct answer:**
Give a concrete structural answer. The two industry patterns:
- **Monorepo** — all modules + envs in one repo; easy cross-referencing and atomic changes, but coarse access control and CI must scope to changed paths.
- **Multi-repo / "umbrella"** — a versioned **modules repo** (published, tagged) consumed by thin per-team/per-env **live repos** that just call `module "x" { source = "git::…//modules/eks?ref=v1.4.0" }`. This gives independent versioning, controlled rollout (bump the ref per env), and clear ownership. Tools like Terragrunt formalise the umbrella/DRY layer.

```hcl
# live repo pins a version of the shared module (umbrella pattern)
module "eks" {
  source = "git::https://github.com/acme/tf-modules.git//eks?ref=v1.4.0"
  # bump ref in dev -> test -> prod for a controlled rollout
}
```

---

## Q23. Walk through how you provisioned EKS and made it usable across all environments.
**Asked in:** Accion-2, PwC-1, HCL  |  **My performance:** Correct

**My answer (from transcript):**
One main EKS module with two submodules — VPC/networking and EKS (EKS resource, Karpenter, pod-identity, drivers). Each had `variables.tf`. Below them an `environments` folder with per-env subfolders (dev/integration/UAT/prod), each with `backend.tf` and an `<env>.tfvars`. The `.tfvars` override inputs; `backend.tf` keeps a separate state per env; a CI/CD pipeline runs checks on PR before apply.

**✅ Correct answer:**
That's a clean, correct design. Reinforce the reusability levers: parameterise everything that differs per env (cluster version, node/Karpenter sizing, CIDRs, replica counts) through variables; keep the *code* identical and let `.tfvars` + backend key carry the environment; pin the module version; and gate `apply` behind PR review. That's exactly "write once, deploy to N environments."

```hcl
# envs/prod/main.tf — same module, prod inputs
module "platform" {
  source          = "../../modules/eks-platform"
  cluster_version = var.cluster_version   # 1.29
  karpenter_max   = var.karpenter_max     # prod: larger
  vpc_cidr        = var.vpc_cidr
}
# envs/prod/backend.tf -> key = "prod/eks.tfstate"  (isolated state)
```

---

## Q24. Write a reusable module for a `t2.micro` EC2 that always fetches the latest AWS-published Ubuntu AMI.
**Asked in:** PwC-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Use a `data` source to query the AWS AMI APIs with a regex/name filter for the region-specific latest Ubuntu AMI ID, feed it into the `ami` argument of `aws_instance`. Put both in a module, store in Git, call from a parent module.

**✅ Correct answer:**
Correct. The key detail is `most_recent = true` plus `owners` set to Canonical's account (`099720109477`) and a `name` filter — so the AMI is resolved fresh at every plan, never hardcoded.

```hcl
# modules/ec2/main.tf
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]          # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
resource "aws_instance" "this" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type        # default "t2.micro"
}
output "id" { value = aws_instance.this.id }

# parent
module "web" { source = "./modules/ec2", instance_type = "t2.micro" }
```

---

## Q25. 6 developers, 6 Lambda microservices reading env vars from Parameter Store — read from Parameter Store, then create the Lambdas. How?
**Asked in:** Virtusa  |  **My performance:** Vague

**My answer (from transcript):**
Asked where Parameter Store is (AWS). Said its values feed the Lambdas, "that part I can figure out." Suggested passing inputs via variables and per-environment variable sets. Vague — didn't name the `aws_ssm_parameter` data source.

**✅ Correct answer:**
Name the concrete resource: read each value with the **`aws_ssm_parameter` data source** and pass it into the Lambda's `environment.variables`. Iterate over the 6 services with `for_each`. For *secret* params use `with_decryption`; better yet, don't bake secrets into env vars — grant the Lambda IAM permission to read SSM at runtime.

```hcl
variable "services" { type = map(object({ param = string })) }

data "aws_ssm_parameter" "cfg" {
  for_each        = var.services
  name            = each.value.param
  with_decryption = true
}

resource "aws_lambda_function" "svc" {
  for_each      = var.services
  function_name = each.key
  role          = aws_iam_role.lambda[each.key].arn
  handler       = "main.handler"
  runtime       = "python3.12"
  filename      = "${each.key}.zip"
  environment { variables = { CONFIG = data.aws_ssm_parameter.cfg[each.key].value } }
}
```

---

# ⚙️ Provisioners, meta-arguments & lifecycle

## Q26. 🔴 Do you know idempotency? Will `remote-exec` run only the first time or every time? Isn't that a problem?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
Explained idempotency (re-running the same code shouldn't unnecessarily change infra). Said `remote-exec` "will continue to run every time since we are executing it," and agreed that's a problem.

**✅ Correct answer (nail this):**
Your idempotency definition was right, but the provisioner behaviour was wrong. A `remote-exec`/`local-exec` **creation-time** provisioner runs **only once — when the resource is first created** — not on every `apply`. It does **not** re-run on subsequent applies, because provisioners aren't tracked as desired state. The real problems are different:
- Provisioners are **not idempotent by design** — the *script* is your responsibility; if the resource is *tainted/recreated*, it runs again from scratch.
- They're a **last resort** (HashiCorp's own guidance): no drift detection, failures mark the resource **tainted**, and output isn't stored usefully.
- To force a re-run you'd `terraform taint` / `-replace`; to run on destroy you use a `when = destroy` provisioner.

Prefer cloud-native config: **user_data / cloud-init**, SSM, Ansible, or golden AMIs (see Q29).

```hcl
resource "aws_instance" "web" {
  # ...
  provisioner "remote-exec" {          # runs ONCE, at creation only
    inline = ["sudo apt-get update -y", "sudo apt-get install -y nginx"]
  }
}
# re-run intentionally:
# terraform apply -replace="aws_instance.web"
```

---

## Q27. Is there a better, cloud-native way than `remote-exec`? What are its drawbacks? Is its output saved to state?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
If `remote-exec` fails the Terraform execution also fails. Not sure about outputs — "I don't think it'll be stored in the state file; it might be in AWS resource logs but not state."

**✅ Correct answer:**
Drawbacks (say these crisply): requires connectivity/SSH or WinRM + credentials; **no idempotency, no drift detection**; a failure **taints** the resource and fails the apply; and it runs on the host doing the apply, hurting reproducibility. On output: **provisioner stdout is streamed to the CLI log, not persisted in state** — so your instinct was right, but the takeaway is you can't rely on capturing it. Cloud-native alternatives: **`user_data`/cloud-init** for bootstrap, **AWS SSM Run Command / State Manager**, **Ansible** post-provision, or bake a **golden AMI** with Packer.

```hcl
# Better: cloud-init via user_data (declarative, no SSH, re-created cleanly)
resource "aws_instance" "web" {
  user_data = <<-EOF
    #cloud-config
    packages: [nginx]
    runcmd: [ "systemctl enable --now nginx" ]
  EOF
}
```

---

## Q28. What is the use of the `remote-exec` provisioner?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
To execute a script on a remote server (e.g. a shell script inside a remote EC2). Put a `remote-exec` block inside the EC2 resource referencing the script; when the instance is provisioned the script runs inside it. For local testing use `local-exec`.

**✅ Correct answer:**
Correct. `remote-exec` runs commands **on the created remote resource** over an SSH/WinRM `connection`; `local-exec` runs on the machine executing Terraform. Both are creation-time by default and are meant for gap-filling only. Always define the `connection` block (host, user, private key).

```hcl
resource "aws_instance" "web" {
  # ...
  connection {
    type        = "ssh"
    host        = self.public_ip
    user        = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
  }
  provisioner "remote-exec" {
    inline = ["sudo systemctl restart myapp"]
  }
}
```

---

## Q29. You must run a post-deploy config script but not via `remote-exec`. What else?
**Asked in:** Shell-1  |  **My performance:** Partial

**My answer (from transcript):**
First proposed Terraform + Ansible (Ansible checks a condition and only runs if not already executed — idempotent). When pushed on servers behind firewalls with no SSH, suggested a cloud-native approach — a Lambda triggered on provisioning to run the installs. (Interviewer accepted Lambda-on-event or AWS Systems Manager.)

**✅ Correct answer:**
Good that you reached SSM/Lambda. Rank the options: **golden AMI (Packer)** — bake config in, nothing to run post-boot (best for immutable infra); **cloud-init `user_data`** — declarative bootstrap; **AWS Systems Manager (Run Command / State Manager)** — agent-based, works for no-SSH/firewalled hosts, idempotent and auditable (the strongest answer for the firewall constraint); **Ansible** — for richer, idempotent config management; **event-driven Lambda** — for reacting to resource creation. Terraform provisions; a dedicated config tool configures.

```hcl
# SSM State Manager association — idempotent, agent-based, no inbound SSH
resource "aws_ssm_association" "bootstrap" {
  name = "AWS-ApplyAnsiblePlaybooks"
  targets { key = "tag:Role", values = ["web"] }
  parameters = { PlaybookFile = "site.yml" }
}
```

---

## Q30. What's the difference between `for_each` and `count`?
**Asked in:** Barclays  |  **My performance:** Partial

**My answer (from transcript):**
Both are meta-arguments. `for_each` provisions a resource for each component in a list/set (e.g. across AZs); `count` provisions a specified number of identical resources. (Missed the key distinction about stable addressing.)

**✅ Correct answer:**
The distinction you missed is the important one: **`count` addresses instances by numeric index** (`res[0]`, `res[1]`), so **removing an item in the middle shifts every later index**, causing Terraform to destroy/recreate unrelated resources. **`for_each` addresses by map/set key** (`res["prod"]`), so instances are stable — adding/removing one key touches only that key. Rule of thumb: use `count` for N identical copies or simple on/off toggles; use `for_each` for a set/map of distinct, named things.

```hcl
# count — index-addressed (fragile ordering)
resource "aws_instance" "c" { count = 3 }                 # aws_instance.c[0..2]

# for_each — key-addressed (stable)
resource "aws_instance" "e" {
  for_each      = toset(["blue", "green", "red"])
  tags          = { Name = each.key }                      # aws_instance.e["blue"]
}
# removing "green" leaves "blue"/"red" untouched
```

---

## Q31. Write Terraform to create 3 EC2 instances across multiple AZs, same AMI/type, unique names.
**Asked in:** Barclays  |  **My performance:** Partial

**My answer (from transcript):**
Proposed a `data` source for all AZs, then a resource using `for_each` over the AZs with the AZ as part of the name. Wrote rough code, admitted it was incomplete/unverified.

**✅ Correct answer:**
Approach is right; use `for_each` over a toset of AZs (or slice to 3) so each instance is keyed by its AZ and gets a unique name. Using `for_each` (not `count`) keeps addressing stable if the AZ list changes.

```hcl
data "aws_availability_zones" "available" { state = "available" }

locals { azs = slice(data.aws_availability_zones.available.names, 0, 3) }

resource "aws_instance" "web" {
  for_each          = toset(local.azs)
  ami               = data.aws_ami.ubuntu.id
  instance_type     = "t3.micro"
  availability_zone = each.value
  tags              = { Name = "web-${each.value}" }   # web-ap-south-1a, ...
}
```

---

## Q32. How do you apply only a specific resource from your Terraform code?
**Asked in:** Barclays  |  **My performance:** Correct

**My answer (from transcript):**
Use `-target`, e.g. `terraform apply -target=aws_instance.<name>`, to apply only that resource.

**✅ Correct answer:**
Correct. `-target` limits the operation to a resource/module and its dependencies. Caveat to mention: it's an **escape hatch for recovery/debugging**, not routine use — it can produce a partial apply and desync your mental model of state, so HashiCorp advises against habitual use.

```bash
terraform plan  -target=aws_instance.web
terraform apply -target=aws_instance.web
terraform apply -target=module.network        # a whole module + its deps
```

---

## Q33. In Terraform, how do you avoid accidental destruction of resources?
**Asked in:** Pure-SW  |  **My performance:** Correct

**My answer (from transcript):**
Set the prevent/deletion option so even a manual delete or `terraform destroy` throws an error and the resource is protected.

**✅ Correct answer:**
Correct — the mechanism is the **`lifecycle { prevent_destroy = true }`** meta-argument: any plan that would destroy the resource errors out. Complement it with provider-level **`deletion_protection`** (RDS, ELB, etc.), backend state protections, and CI policy checks. Note `prevent_destroy` blocks `destroy` but you must remove the block to *intentionally* delete.

```hcl
resource "aws_db_instance" "prod" {
  # ...
  deletion_protection = true          # provider-side guard
  lifecycle {
    prevent_destroy = true            # Terraform-side guard
  }
}
```

---

# 🌍 Multi-environment & CI/CD

## Q34. Have you heard about workspaces in Terraform?
**Asked in:** Shell-1  |  **My performance:** Didn't know

**My answer (from transcript):**
"I've heard of it, but I've not used it." (Interviewer explained workspaces are for environment segregation, and noted the custom-folder approach is a more primitive way with three separate state files and pipeline logic rather than native Terraform.)

**✅ Correct answer (learn this):**
A **workspace** is a named, isolated instance of state within one backend. `default` exists always; `terraform workspace new dev` creates another, and state is stored at a workspace-namespaced path (`env:/dev/…`). Reference the current one with `terraform.workspace` to vary inputs. Trade-offs: great for lightweight/ephemeral env separation with identical code; but the same code/providers apply to all workspaces, it's easy to `apply` to the wrong one, and many teams still prefer **directory-per-env with separate backends** for production isolation. (Note: CLI workspaces ≠ Terraform Cloud workspaces, which are heavier.)

```bash
terraform workspace new dev
terraform workspace new prod
terraform workspace select prod
terraform apply -var-file="${terraform.workspace}.tfvars"
```
```hcl
locals { node_count = terraform.workspace == "prod" ? 6 : 2 }
```

---

## Q35. Three AWS accounts/environments — do you change the code, provide different config, or use a pipeline to switch dev→test?
**Asked in:** Shell-1  |  **My performance:** Correct

**My answer (from transcript):**
Use a pipeline. Once the module has input sections, automate deployment with approval gates that take inputs like account IDs and target environment; based on those the pipeline triggers Terraform to deploy.

**✅ Correct answer:**
Correct — **code stays identical; environment is data**. The pipeline selects the right backend + `.tfvars` + credentials per stage (dev→test→prod), each stage assuming a role into its own account (OIDC, no static keys), with manual approval before prod. Cross-account is handled by **provider `assume_role`**, not code changes.

```hcl
provider "aws" {
  region = var.region
  assume_role { role_arn = "arn:aws:iam::${var.account_id}:role/terraform" }
}
```
```yaml
# CI: same code, per-env inputs + gated promotion
deploy:
  matrix: [dev, test, prod]
  steps:
    - terraform init  -backend-config=envs/$ENV/backend.hcl
    - terraform apply -var-file=envs/$ENV/$ENV.tfvars   # prod needs approval
```

---

## Q36. Four environments (UAT/QA/staging/prod) each need a database — how do you integrate Terraform with CI/CD to automate creating the DB per environment?
**Asked in:** PwC-K8s  |  **My performance:** Correct

**My answer (from transcript):**
Use a module with a DB (Postgres) folder; an `environments` folder with subfolders (dev/QA/integration/prod), each with its own backend and `.tfvars`. When the pipeline triggers, it picks that env's tfvars/backend and applies to the DB module.

**✅ Correct answer:**
Correct pattern. Emphasise: one reusable `rds` module, four thin env configs (each its own **backend key** ⇒ isolated state, and `.tfvars` for size/multi-AZ/retention), and a pipeline that runs `plan` on PR and gated `apply` per env. Store the DB password via Secrets Manager (Q15), and set `deletion_protection`/`prevent_destroy` on prod.

```hcl
# modules/rds/main.tf
resource "aws_db_instance" "pg" {
  engine            = "postgres"
  instance_class    = var.instance_class      # dev: db.t3.micro, prod: db.r6g.large
  multi_az          = var.multi_az            # prod: true
  allocated_storage = var.storage
  password          = data.aws_secretsmanager_secret_version.db.secret_string
}
# envs/prod/prod.tfvars: instance_class="db.r6g.large"  multi_az=true
```

---

## Q37. Given dev/QA/stage/prod, will you use IaC for all environments or only some, and how per environment?
**Asked in:** PwC-1  |  **My performance:** Correct

**My answer (from transcript):**
IaC for all environments. Main module with VPC + EKS folders plus an `environments` folder (dev/integration/prod), each with `backend.tf` and env `.tfvars`. During init/validate/plan/apply the tfvars supply env-specific inputs; each env's state is in its own S3 bucket; a PR triggers the pipeline.

**✅ Correct answer:**
Correct — **use IaC for every environment**, precisely so lower environments are faithful, cheaper-sized replicas of prod (same code, smaller `.tfvars`). Manually building any environment defeats reproducibility and lets drift creep in. The only nuance: sizing/feature flags differ by env, never the code.

```hcl
# Same module everywhere; only inputs differ
# dev.tfvars  : node_count = 2   instance_type = "t3.medium"
# prod.tfvars : node_count = 6   instance_type = "m5.xlarge"
module "eks" { source = "../../modules/eks", node_count = var.node_count }
```

---

## Q38. What's your hands-on Terraform experience?
**Asked in:** Trianz, Persistent, HTC-1, Accion-1, HCL  |  **My performance:** Correct

**My answer (from transcript):**
Provisioned VPC and EKS/AKS clusters and decommissioned EKS clusters. Was part of the team that built the EKS module (VPC + EKS submodules, Karpenter, pod identity, drivers). Built a custom module integrating **Infisical** (a Vault alternative) via its Terraform provider — calling Infisical APIs, creating separate objects per app to onboard secrets — tied into the CD pipeline so app teams onboard secrets through the audited module.

**✅ Correct answer:**
This is a strong, senior narrative — keep it structured: (1) **platform modules** (VPC, EKS, Karpenter, IRSA/pod-identity, CSI drivers), (2) **secrets platform** (Infisical provider as a reusable, audited onboarding module), (3) **lifecycle ops** (graceful cluster decommission handling dependent drivers), (4) **multi-env delivery** (per-env backend + tfvars, PR-gated pipeline). Quantify where you can (clusters, environments, teams onboarded). Be careful not to mix AKS/EKS in the same breath — state which cloud.

```hcl
# Infisical secrets onboarding as a reusable module (audited via PR + CD)
module "app_secrets" {
  source   = "./modules/infisical-onboarding"
  for_each = var.apps
  app_name = each.key
  env      = var.environment
}
```

---

# 🔍 Drift, import & troubleshooting

## Q39. 🔴 What's the use of `terraform refresh`?
**Asked in:** Barclays  |  **My performance:** Incorrect

**My answer (from transcript):**
Claimed `terraform refresh` "enforces whatever is in the state file onto the AWS cloud resources" and removes other provisioned resources. Interviewer challenged twice ("Are you sure?", "or is it vice versa?"); I stuck with the incorrect answer.

**✅ Correct answer (this is exactly backwards — memorise it):**
`terraform refresh` reads the **real infrastructure** and **updates the STATE FILE to match it**. It flows **cloud → state**, one direction only. It does **not** touch or "enforce" anything onto cloud resources, and it never creates, modifies, or deletes real infrastructure.
- Direction: **reality → state** (never state → reality). To change reality you use `apply`.
- It's how drift becomes visible: after a refresh, `plan` shows the difference between your *config* and the now-current *state*.
- `terraform refresh` is **deprecated as a standalone command**; the modern equivalent is `terraform apply -refresh-only` (which asks for approval before writing the refreshed state) or the automatic refresh that `plan`/`apply` already do. Use `-refresh=false` to skip it.

```bash
# Someone changed a resource in the console. Reconcile STATE to reality:
terraform apply -refresh-only        # cloud -> state (approve to save)
terraform plan                       # now shows config-vs-reality drift
# refresh NEVER pushes state onto the cloud; only `apply` changes real infra
```

---

## Q40. There are manual console changes you want to keep without Terraform overriding them — how?
**Asked in:** Barclays  |  **My performance:** Partial

**My answer (from transcript):**
Suggested `terraform import` to bring changes into state, then `terraform refresh`/`state list` to check differences. (Import is more for unmanaged resources; the cleaner answers — `ignore_changes` or reconciling code — weren't given.)

**✅ Correct answer:**
Distinguish two cases:
- The resource is **already managed** and someone changed one attribute you want to preserve → use **`lifecycle { ignore_changes = [...] }`** so Terraform stops trying to revert that attribute. This is the intended tool here — not `import`.
- The change created a **brand-new, unmanaged resource** → then `import` it into state so Terraform manages it going forward.

The durable fix is usually to **reconcile the code to reality** (update HCL to match) so config, state, and cloud agree. `import` is for adoption, not for "keep a manual tweak."

```hcl
resource "aws_autoscaling_group" "app" {
  desired_capacity = 2
  lifecycle {
    ignore_changes = [desired_capacity]   # let ops scale manually; TF won't revert
  }
}
```

---

## Q41. How do you troubleshoot drift in Terraform?
**Asked in:** GlobalLogic, Accion-2, HTC-1  |  **My performance:** Partial

**My answer (from transcript):**
Use `terraform state list` to see TF-provisioned resources and compare with the console; if drift, run `terraform plan` (said "target") to see the difference, then `terraform import` to sync. Gatekeeper CI tests run `state list`/history and fail on discrepancy. (Somewhat garbled; import isn't always the fix.)

**✅ Correct answer:**
Tighten the flow: **`plan` (or `apply -refresh-only`) is the drift detector**, not `state list`. Terraform refreshes state from reality and `plan` shows the diff between your *config* and the *real* world — that IS the drift report. Then choose the remedy by intent:
- Want reality back to code → **`terraform apply`** (re-converge).
- Want to keep the manual change → update the **code** (or `ignore_changes`).
- Resource exists but Terraform doesn't know it → **`import`**.

`state list` just enumerates what's tracked; it doesn't detect drift by itself. In CI, run scheduled `plan -detailed-exitcode` (exit code `2` = drift) and alert.

```bash
terraform plan -refresh-only              # see drift (config vs reality)
terraform plan -detailed-exitcode         # exit 2 => drift detected (use in CI/cron)
terraform apply                           # re-converge reality to code
```

---

## Q42. If I manually delete a security group and you run `terraform plan`, what happens?
**Asked in:** Persistent  |  **My performance:** Correct

**My answer (from transcript):**
A resource drift is detected during `plan`. To verify, run `terraform state list` (TF-provisioned vs console), find differences, and import the changes using `terraform import`.

**✅ Correct answer:**
Mostly right, one correction on the fix. On `plan`, Terraform refreshes, finds the SG **missing** in reality but present in state, and the plan shows it will be **re-created** (`+ create`) to match your config. Since it was *deleted* (not newly created outside TF), you don't `import` — you just **`apply`** and Terraform recreates it. `import` is for the opposite case (a resource that exists in the cloud but not in state).

```bash
terraform plan
#   # aws_security_group.web will be created  (+)  -> it was deleted out-of-band
terraform apply       # recreates it to match config; no import needed
```

---

## Q43. Terraform failed midway, some resources already created — how do you continue and ensure consistency?
**Asked in:** HTC-1  |  **My performance:** Correct

**My answer (from transcript):**
Run `terraform state list` to see deployed vs available, cross-check the console, run `terraform plan` to see provisioned vs pending, cross-verify with history, then `terraform apply`. If something needs importing, use `terraform import`.

**✅ Correct answer:**
Correct instinct — Terraform is **resumable** because state records what already succeeded. Just re-run `plan` then `apply`: created resources are skipped, only the remaining/failed ones are actioned. Watch for a **tainted** resource (provisioner failed) — it'll be replaced; and clear a **stale lock** with `force-unlock` if the crash left one. Use `import` only for anything created out-of-band that state missed.

```bash
terraform plan        # shows only what's left / what's tainted
terraform apply       # resumes; already-created resources are untouched
# if a provisioner failed: resource is tainted -> apply replaces it
# if a lock is stuck:      terraform force-unlock <LOCK_ID>
```

---

## Q44. I created an RDS instance manually — the team wants to manage it via Terraform. How do you import it?
**Asked in:** GlobalLogic  |  **My performance:** Correct

**My answer (from transcript):**
Use `terraform import`. Once it compiles, the manually created RDS becomes part of the state file and can be managed via Terraform code going forward.

**✅ Correct answer:**
Correct. Two-step: **write matching HCL first** (a `resource "aws_db_instance"` shell), then bind the real resource to it. `terraform import` maps the real ID into state but does **not** generate code — if your HCL doesn't match, the next `plan` shows changes. The modern, reviewable way is the **`import` block** (Terraform 1.5+), which lets you import via `plan`/`apply` and can even generate config with `-generate-config-out`.

```hcl
# Modern, plan-reviewable import (TF 1.5+)
import {
  to = aws_db_instance.legacy
  id = "my-manual-rds"
}
resource "aws_db_instance" "legacy" { /* fill to match, or -generate-config-out */ }
```
```bash
# Classic CLI equivalent
terraform import aws_db_instance.legacy my-manual-rds
terraform plan     # must show "no changes" once HCL matches
```

---

## Q45. Since you use `terraform import` etc., I assume you use Terraform locally / not Terraform Cloud?
**Asked in:** Accion-2  |  **My performance:** Correct

**My answer (from transcript):**
The team proposed workspaces, but stuck to local Terraform executions with state in S3 buckets, and were fine with that.

**✅ Correct answer:**
Fine as a factual answer; strengthen the contrast for seniority. **Local/OSS Terraform + S3/DynamoDB remote backend** gives you remote, locked, versioned state while running the CLI yourself (or in your own CI). **Terraform Cloud/Enterprise** adds managed state, remote runs, a run UI, VCS-driven plans, Sentinel policy, and team RBAC. `import` works in both — it isn't tied to running locally. The mature setup is OSS Terraform driven by CI/CD (not laptops), which the interviewers repeatedly nudged toward.

```hcl
# OSS Terraform with a remote, locked backend (no Terraform Cloud required)
terraform {
  backend "s3" {
    bucket = "acme-tf-state", key = "prod/rds.tfstate"
    dynamodb_table = "tf-locks", encrypt = true
  }
}
```

---

## Q46. Tell me about a learning from a mistake (cluster decommission).
**Asked in:** Shell-2  |  **My performance:** Correct

**My answer (from transcript):**
Tasked to gracefully decommission a non-prod cluster. Missed platform-dependent drivers (CSI/EBS drivers, ingress controllers) whose lifecycles were still active, so `terraform destroy` looped. Took ~2 extra days: had to `terraform state list`, disable individual lifecycles, then destroy again. Documented every step in Confluence.

**✅ Correct answer:**
Good STAR story — sharpen the *technical* root cause and prevention. The loop was a **dependency/finalizer** problem: Kubernetes-managed cloud objects (ELBs from ingress, EBS volumes from CSI, ENIs) weren't in Terraform's graph, so destroy couldn't delete the VPC/cluster until those were removed. Prevention: uninstall in-cluster controllers (or `helm uninstall`) **before** `destroy`; model destroy ordering with `depends_on`; use `terraform plan -destroy` to preview; and script teardown order. Documenting it as a runbook is exactly right.

```bash
# Right order: drain the cluster-created cloud objects first, then destroy infra
helm uninstall ingress-nginx aws-ebs-csi-driver -n kube-system
terraform plan -destroy         # preview the teardown graph
terraform destroy
```

---

# 🔺 Advanced Questions to Master (not asked yet — practice these)

## Q47. How does state locking actually work with the S3 backend, and how do you recover from a stuck lock?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
The S3 backend writes a lock item into a **DynamoDB table** keyed by `LockID = <bucket>/<key>` (or `<key>-md5`), holding the run's ID, user, and timestamp. Any concurrent operation that can't write that item fails with `Error acquiring the state lock`. On a crashed run the item can persist — clear it with `terraform force-unlock <ID>` (verify no run is truly active first). Newer Terraform supports **native S3 lockfile locking** via `use_lockfile = true`, reducing the DynamoDB dependency.

```hcl
terraform {
  backend "s3" {
    bucket = "acme-tf-state", key = "prod/eks.tfstate"
    dynamodb_table = "tf-locks"   # LockID (String) partition key
    use_lockfile   = true         # native S3 lock (newer TF)
  }
}
```

---

## Q48. When should you use `count` vs `for_each` — and what's the classic index-shift pitfall?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Use **`count`** only for N truly-identical copies or a boolean toggle (`count = var.enabled ? 1 : 0`). Use **`for_each`** for any collection of *distinct* things, because it keys instances by map/set key, keeping addresses stable. The pitfall: with `count`, deleting a middle element renumbers every later index, so Terraform destroys and recreates unrelated resources. Also: `for_each` values must be known at plan time (can't be derived from unknown computed attributes).

```hcl
resource "aws_iam_user" "u" {
  for_each = toset(["alice", "bob", "carol"])   # stable: aws_iam_user.u["bob"]
  name     = each.key
}
# removing "bob" leaves alice/carol untouched (with count, indexes would shift)
```

---

## Q49. What are `dynamic` blocks and when do you use them (and when not)?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
A `dynamic` block programmatically generates **repeatable nested blocks** (e.g. `ingress` rules, `setting` blocks) from a collection, so you don't hand-write each one. Use it when the number of nested blocks is data-driven; avoid overusing it for static config, since it hurts readability. Iterate with `for_each`, referencing `<label>.value`.

```hcl
resource "aws_security_group" "web" {
  dynamic "ingress" {
    for_each = var.ingress_ports        # [80, 443]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}
```

---

## Q50. What do `moved` and `import` blocks give you over the CLI commands?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Both are **config-as-code state operations** (Terraform 1.1+/1.5+), reviewable in `plan` and safe in CI — unlike the imperative `terraform state mv` / `terraform import`. A **`moved`** block refactors addresses (rename a resource, move into/out of a module) **without destroy/recreate**. An **`import`** block adopts existing infra into state via `apply`, optionally generating config with `-generate-config-out`. They live in code, so teammates get the change through the normal PR flow.

```hcl
moved {
  from = aws_instance.web
  to   = module.compute.aws_instance.web   # refactor, no recreate
}
import {
  to = aws_s3_bucket.legacy
  id = "acme-legacy-bucket"
}
```

---

## Q51. How and why do you use provider aliasing?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
**`alias`** lets you configure multiple instances of the same provider — different regions or accounts — and pick one per resource/module via the `provider` argument. Essential for multi-region (e.g. an ACM cert in `us-east-1` for CloudFront while resources live elsewhere) and cross-account deployments. Child modules declare needed aliases via `configuration_aliases`.

```hcl
provider "aws" { region = "ap-south-1" }                 # default
provider "aws" { alias = "us_east_1", region = "us-east-1" }

resource "aws_acm_certificate" "cdn" {
  provider = aws.us_east_1          # CloudFront requires us-east-1
  domain_name = "www.example.com"
}
```

---

## Q52. How do you version and pin modules and providers for reproducible builds?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Pin **providers** with `required_providers` version constraints (`~>` pessimistic) and commit **`.terraform.lock.hcl`** (locks exact versions + checksums across platforms). Pin **modules**: registry modules take a `version` argument; Git sources take a `?ref=<tag>`. Never track `main`. Promote a version bump env-by-env. Use `terraform init -upgrade` to intentionally move pins and update the lock file.

```hcl
terraform {
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.40" } }
}
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"                                 # exact registry pin
}
module "eks" { source = "git::https://github.com/acme/mods.git//eks?ref=v2.3.0" }
```

---

## Q53. Design a CI/CD pipeline for Terraform. What are the stages and guardrails?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
On PR: `fmt -check` → `init` → `validate` → **`plan -out`** (posted to the PR) → security/policy scan (tfsec/Checkov + OPA/Sentinel) → cost estimate (Infracost). On merge to main: **gated `apply` of the saved plan** per environment, promoted dev→stage→prod with manual approval before prod. Auth via **OIDC-assumed roles** (no static keys), remote state with locking, and a nightly `plan -detailed-exitcode` drift check that alerts.

```yaml
on: pull_request
jobs:
  plan:
    permissions: { id-token: write }         # OIDC, no static creds
    steps:
      - run: terraform fmt -check && terraform init && terraform validate
      - run: terraform plan -out=tfplan
      - run: checkov -f tfplan   # + conftest/OPA policy gate
# on merge: terraform apply tfplan  (prod behind an approval environment)
```

---

## Q54. How do you test Terraform code?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Layer it: **static** (`fmt`, `validate`, tflint, tfsec/Checkov); **policy** (OPA/Conftest, Sentinel) against plan JSON; **unit/contract** with the native **`terraform test`** framework (`.tftest.hcl`, runs plan/apply assertions, can mock providers); and **integration** with **Terratest** (Go) that really applies to a sandbox account, asserts via SDK/HTTP, then destroys. Run static + `terraform test` on every PR; run Terratest on a schedule or pre-release due to cost/time.

```hcl
# tests/vpc.tftest.hcl  (native terraform test)
run "cidr_is_correct" {
  command = plan
  variables { vpc_cidr = "10.0.0.0/16" }
  assert {
    condition     = aws_vpc.main.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR did not match input"
  }
}
```

---

## Q55. How do you continuously detect drift across many state files?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Run **`terraform plan -detailed-exitcode`** on a schedule per stack (exit `0` = no changes, `2` = drift, `1` = error) and alert on `2`. Use `-refresh-only` plans to isolate real-world drift from code changes. At scale, use Terraform Cloud/Enterprise **drift detection**, or tools like **driftctl**/env0/Spacelift. Feed results to Slack/PagerDuty and open a ticket automatically. Pair with `prevent_destroy` and `default_tags` to reduce drift sources (click-ops).

```bash
# cron / CI job per stack
terraform plan -refresh-only -detailed-exitcode -out=drift.plan
case $? in
  0) echo "no drift" ;;
  2) notify-slack "DRIFT in $STACK"; terraform show drift.plan ;;
  1) fail "plan error" ;;
esac
```

---

## Q56. Where do secrets end up in Terraform, and how do you keep state safe?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Any secret consumed by a resource (DB password, private key) is **written in plaintext into the state file** — so state is a secret. Mitigations: **encrypt state at rest** (S3 SSE-KMS) and restrict IAM; **never commit** `*.tfstate`; mark variables/outputs **`sensitive = true`**; fetch secrets at run time from **Vault/Secrets Manager/SSM/Infisical**; prefer **ephemeral/dynamic** credentials; and, in newer Terraform, use **ephemeral resources/values** and **write-only arguments** that avoid persisting the secret to state at all.

```hcl
variable "db_password" { type = string, sensitive = true }
output "endpoint"      { value = aws_db_instance.db.address }   # ok
# NEVER: output "pw" { value = var.db_password }  -> lands in state/logs
# state bucket: SSE-KMS + bucket policy limiting reads to the platform role
```

---

## Q57. What's the difference between `depends_on`, implicit dependencies, and `lifecycle` ordering?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Terraform builds a graph from **implicit dependencies** — whenever resource A references B's attribute (`b.id`), A waits for B. That's the preferred mechanism (this was the crux of the Virtusa "S3 before Lambda" question — reference the bucket, don't just `depends_on`). Use explicit **`depends_on`** only for *hidden* dependencies with no attribute reference (e.g. IAM policy must exist before a Lambda uses the role at runtime). **`lifecycle`** tunes *how* changes apply: `create_before_destroy` (avoid downtime), `prevent_destroy`, `ignore_changes`, `replace_triggered_by`.

```hcl
resource "aws_s3_bucket" "assets" { bucket = "acme-assets" }

resource "aws_lambda_function" "fn" {
  s3_bucket  = aws_s3_bucket.assets.id       # implicit: bucket built first
  depends_on = [aws_iam_role_policy.exec]     # explicit hidden dep
  lifecycle { create_before_destroy = true }
}
```

---

## Q58. How do you refactor a large monolithic state without destroying resources?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Split by lifecycle/blast radius into separate stacks (network, cluster, apps), each with its own state, wired via `terraform_remote_state`/data sources. Move resources safely with **`moved` blocks** (in-config, reviewable) or `terraform state mv`; to carve resources into a new state file use `terraform state mv -state-out=` or pull/push. Always `plan` after each move to confirm **"no changes"** (no destroy/recreate). Do it incrementally, one module at a time, behind PRs.

```bash
# carve a module out into its own state, no recreation
terraform state mv -state-out=../network/terraform.tfstate \
  module.vpc aws_vpc.main
terraform plan   # must show 0 to add/change/destroy
```

---

## Q59. What are `null_resource`/`terraform_data` and `triggers` used for?
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
`null_resource` (and its modern replacement **`terraform_data`**, no provider needed) is a resource with no cloud object — a hook to attach provisioners or to force re-execution via **`triggers`**. When a trigger value changes, the resource is replaced and its provisioners re-run. Useful for glue (run a script when a hash changes) but, like all provisioners, a last resort. `terraform_data` also works as a scratch value to drive `replace_triggered_by`.

```hcl
resource "terraform_data" "migrate" {
  triggers_replace = [filemd5("schema.sql")]   # re-run when the file changes
  provisioner "local-exec" { command = "./run-migrations.sh" }
}
```

---

## Q60. Explain `terraform state` subcommands and safe manual state surgery.
**Asked in:** —  |  **My performance:** —

**My answer (from transcript):**
*(Not asked — study & rehearse)*

**✅ Correct answer:**
Key subcommands: **`list`** (enumerate tracked addresses), **`show <addr>`** (inspect attributes), **`mv`** (rename/relocate without recreate — prefer `moved` blocks now), **`rm`** (stop managing without destroying the real resource), **`pull`/`push`** (fetch/replace raw state — dangerous), and **`replace-provider`**. Always back up state (S3 versioning helps) and re-`plan` afterward. Prefer config-based operations (`moved`/`import` blocks) so changes are reviewable; reserve raw surgery for emergencies.

```bash
terraform state list
terraform state show aws_instance.web
terraform state rm aws_instance.legacy      # forget it (real resource stays)
terraform plan                              # verify no unintended changes
```

---
