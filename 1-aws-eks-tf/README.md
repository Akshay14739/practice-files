# AWS EKS Cluster Terraform Module

A comprehensive production-ready Terraform module that provisions a complete AWS EKS (Elastic Kubernetes Service) cluster with worker nodes and essential add-ons.

---

## 📋 Table of Contents

- [Prerequisites](#prerequisites)
- [Console-Side Requirements](#console-side-requirements)
- [Module Structure](#module-structure)
- [Input Variables](#input-variables)
- [Deployment Instructions](#deployment-instructions)
- [Post-Deployment Verification](#post-deployment-verification)
- [Add-ons Included](#add-ons-included)
- [Troubleshooting](#troubleshooting)
- [File Descriptions](#file-descriptions)

---

## 📋 Prerequisites

### Local Environment
- ✅ **Terraform** >= 1.0 installed
- ✅ **AWS CLI** configured with valid credentials
- ✅ **kubectl** installed (for post-deployment verification)
- ✅ **Git** (recommended, for version control)
- ✅ IAM user with permissions to:
  - Create EKS clusters and node groups
  - Create IAM roles and policies
  - Create CloudWatch log groups
  - Attach policies to IAM roles

### Knowledge Requirements
- ✅ Basic understanding of AWS (VPC, IAM, EKS)
- ✅ Familiarity with Terraform
- ✅ Basic Kubernetes concepts

### Pre-Deployment Setup - CRITICAL STEPS

#### 1. **VPC Must Be Pre-Created**
- ✅ VPC must already exist in AWS
- ✅ You must provide the **VPC ID** in `c2-variables.tf`
  - Example: `vpc_id = "vpc-0123456789abcdef0"`
  - This is a **REQUIRED** variable with no default value

#### 2. **S3 Bucket Name Must Be Updated**
- ✅ Create an S3 bucket for Terraform state (must be globally unique)
- ✅ **Update the bucket name in `c1-versions.tf`** (line with `bucket = "bucket-name"`)
  - Replace `"bucket-name"` with your actual bucket name
  - Enable versioning and server-side encryption on the bucket
  - Example: `bucket = "my-unique-terraform-state-bucket"`"

#### 3. **5 Subnets Must Be Pre-Created with Specific Tags**
- ✅ All 5 subnets must already exist in the same VPC
- ✅ Each subnet MUST have the tag `SubnetType` with correct value (shown below)
- ✅ This module uses tag-based discovery to find subnets dynamically

**Required Subnet Configuration:**

| Subnet Type | Tag Key | Tag Value | Routing | Purpose |
|------------|---------|-----------|---------|---------|
| Public Subnet | `SubnetType` | `public` | → Internet Gateway | NAT Gateway, Bastion hosts |
| Bastion Subnet | `SubnetType` | `bastion` | → NAT Gateway | Bastion/Jump hosts |
| Node Subnet | `SubnetType` | `node` | → NAT Gateway | EKS worker nodes |
| DB Subnet | `SubnetType` | `db` | → None (Isolated) | RDS databases |
| Pod Subnet | `SubnetType` | `pod` | → NAT Gateway | Pod IP assignment |

---

## 🖥️ Console-Side Requirements (Pre-Deployment Checklist)

**BEFORE running `terraform init`, ensure these resources exist in AWS Console:**

### Required: VPC with VPC ID
- ✅ VPC must be created (e.g., CIDR: `10.0.0.0/16`)
- ✅ You need the **VPC ID** to pass to Terraform (format: `vpc-xxxxxxxxx`)
- ✅ Location: VPC Dashboard → Your VPCs → Copy VPC ID

### Required: Internet Gateway (IGW)
- ✅ Create Internet Gateway
- ✅ Attach to your VPC
- ✅ Add route in **public subnet route table**: `0.0.0.0/0 → IGW`

### Required: NAT Gateway for Private Subnets
- ✅ Create NAT Gateway in **public subnet**
- ✅ Allocate and assign **Elastic IP** to NAT Gateway
- ✅ Add route in **private subnet route tables** (bastion, node, pod): `0.0.0.0/0 → NAT Gateway`
  - Private subnets WITH internet access: bastion, node, pod
  - Private subnets WITHOUT internet access: db (isolated)

### Required: 5 Subnets with SubnetType Tags
All 5 subnets must exist and be tagged correctly:

| Subnet Type | Example CIDR | AZ | Tag Key | Tag Value | Notes |
|------------|------|-----|---------|----------|-------|
| Public (IGW access) | 10.0.1.0/24 | us-east-1a | `SubnetType` | `public` | Routes to IGW, holds NAT GW |
| Bastion | 10.0.2.0/24 | us-east-1a | `SubnetType` | `bastion` | Routes to NAT GW |
| Node (EKS Workers) | 10.0.3.0/24 | us-east-1a | `SubnetType` | `node` | Routes to NAT GW |
| DB | 10.0.4.0/24 | us-east-1a | `SubnetType` | `db` | No internet route (isolated) |
| Pod | 10.0.5.0/24 | us-east-1a | `SubnetType` | `pod` | Routes to NAT GW |

**How to Tag Subnets:**
1. Go to VPC Dashboard → Subnets
2. Select a subnet
3. Click "Tags" tab → "Manage tags"
4. Add tag: Key=`SubnetType`, Value=`public` (or appropriate value)
5. Save and repeat for all 5 subnets

### Required: Security Groups
- ✅ Create at least one security group in your VPC
- ✅ Configure inbound rules as needed
- ✅ Module will discover security groups automatically by name filter

### Required: S3 Bucket for Terraform State
- ✅ Create S3 bucket (globally unique name required)
- ✅ Enable **Versioning** (Bucket → Properties → Versioning)
- ✅ Enable **Server-side encryption** (Bucket → Properties → Default encryption)
- ✅ Block public access (Bucket → Permissions → Block Public Access: ON)
- ✅ **Update the bucket name in `c1-versions.tf`** before running `terraform init`

---

## 📁 Module Structure

```
1-aws-eks-tf/
├── c1-versions.tf              # Provider & S3 backend config
├── c2-variables.tf             # Input variables
├── c3-01-iam-eks.tf            # EKS control plane IAM role
├── c3-02-eks-cluster.tf        # EKS cluster resource
├── c3-03-network-data.tf       # Subnet & security group discovery
├── c4-01-iam-node-groups.tf    # Worker node IAM role
├── c4-02-node-groups.tf        # Node group resource
├── c5-01-PIA-add-on.tf         # Pod Identity Agent
├── c5-02-EBS-addon.tf          # EBS CSI driver
├── c5-03-kube-proxy.tf         # Kube Proxy add-on
├── c5-06-vpc-cni.tf            # VPC CNI add-on
├── c5-07-coreDNS.tf            # CoreDNS add-on
├── c6-outputs.tf               # Output values
└── README.md                    # This file
```

---

## 🔧 Input Variables

### **REQUIRED**
- **`vpc_id`**: VPC where EKS will be deployed (e.g., `vpc-0123456789abcdef0`)

### **OPTIONAL** (with sensible defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region for resources |
| `cluster_name` | `eksdemo` | EKS cluster name |
| `cluster_version` | `1.33` | Kubernetes version |
| `cluster_service_ipv4_cidr` | `172.20.0.0/16` | Service IP range (don't overlap with VPC) |
| `cluster_endpoint_private_access` | `true` | Enable private endpoint access |
| `cluster_endpoint_public_access` | `true` | Enable public endpoint access |
| `cluster_endpoint_public_access_cidrs` | `["0.0.0.0/0"]` | CIDR blocks allowed public access (⚠️ restrict in prod) |
| `node_instance_types` | `["t3.medium"]` | EC2 instance types for nodes |
| `node_capacity_type` | `ON_DEMAND` | ON_DEMAND or SPOT |
| `node_disk_size` | `200` | Root volume size (GiB) |
| `security_group_name_filter` | `"*"` | Filter security groups by name pattern |
| `subnet_tag_key` | `SubnetType` | Tag key for subnet discovery |
| `subnet_type_tags` | See below | Tag values for each subnet type |

**Default `subnet_type_tags`:**
```terraform
{
  public  = "public"   # For load balancers, NAT
  bastion = "bastion"  # For jump servers
  node    = "node"     # For EKS worker nodes
  db      = "db"       # For databases
  pod     = "pod"      # For Kubernetes pods
}
```

---

## 🚀 Deployment Instructions

### Step 1: Update Backend Configuration
Edit `c1-versions.tf` and replace the bucket name:
```terraform
backend "s3" {
  bucket = "your-actual-bucket-name"  # ← CHANGE THIS
  key    = "/terraform.tfstate"
  region = "us-east-1"
  ...
}
```

**OR** use backend config at init time:
```bash
terraform init -backend-config="bucket=your-actual-bucket-name"
```

### Step 2: Initialize Terraform
```bash
cd 1-aws-eks-tf/
terraform init
```

### Step 3: Validate Configuration
```bash
terraform validate
```

### Step 4: Plan Deployment
```bash
terraform plan -var="vpc_id=vpc-0123456789abcdef0" -out=tfplan
```

### Step 5: Apply Configuration
```bash
terraform apply tfplan
```

**Expected output:**
```
Apply complete! Resources added: 45, changed: 0, destroyed: 0.

Outputs:
eks_cluster_name = "eksdemo"
eks_cluster_endpoint = "https://xxxx.eks.amazonaws.com"
...
```

---

## ✅ Post-Deployment Verification

### 1. Update kubeconfig
```bash
aws eks update-kubeconfig --region us-east-1 --name eksdemo
```

### 2. Verify Cluster Access
```bash
kubectl cluster-info
kubectl get nodes
```

Expected output:
```
NAME                           STATUS   ROLES    AGE     VERSION
ip-10-0-x-x.ec2.internal      Ready    <none>   2m      v1.33.x
ip-10-0-x-x.ec2.internal      Ready    <none>   2m      v1.33.x
ip-10-0-x-x.ec2.internal      Ready    <none>   2m      v1.33.x
```

### 3. Verify Add-ons
```bash
kubectl get pods -n kube-system

# Should see:
# - pod-identity-agent-xxxxx
# - ebs-csi-controller-xxxxx
# - aws-node-xxxxx (VPC CNI)
# - kube-proxy-xxxxx
# - coredns-xxxxx
```

### 4. View Terraform Outputs
```bash
terraform output
```

### 5. Check CloudWatch Logs
```bash
aws logs describe-log-groups --query 'logGroups[?contains(logGroupName, `eksdemo`)].logGroupName'
```

---

## 🔌 Add-ons Included

### 1. **Pod Identity Agent** (Prerequisite)
- **Purpose**: Enables pods to assume IAM roles securely
- **Status**: Installed first, required by other add-ons
- **Namespace**: kube-system
- **IAM**: None (control plane managed)

### 2. **EBS CSI Driver**
- **Purpose**: Provisions EBS volumes as Kubernetes PersistentVolumes
- **Status**: Ready after Pod Identity
- **Namespace**: kube-system
- **IAM**: Yes (separate IAM role with Pod Identity)
- **Usage**: Create `PersistentVolumeClaim` referencing `ebs.csi.aws.com` StorageClass

### 3. **VPC CNI (AWS Container Network Interface)**
- **Purpose**: Network plugin for pod IP assignment
- **Status**: Pre-installed, managed via Terraform
- **Namespace**: kube-system
- **IAM**: Yes (separate IAM role with Pod Identity)
- **How It Works**: Assigns pod IPs directly from VPC subnets

### 4. **Kube Proxy**
- **Purpose**: Implements Kubernetes networking rules
- **Status**: Pre-installed, managed via Terraform
- **Namespace**: kube-system
- **IAM**: None
- **How It Works**: Service load balancing using iptables/IPVS

### 5. **CoreDNS**
- **Purpose**: DNS service for Kubernetes
- **Status**: Pre-installed, managed via Terraform
- **Namespace**: kube-system
- **IAM**: None
- **How It Works**: Resolves service names to ClusterIPs

---

## 🔍 Verification Commands

```bash
# Check cluster status
kubectl get nodes
kubectl get namespaces
kubectl get all -n kube-system

# Test Pod Identity
kubectl run test-pod --image=amazon/aws-cli:latest -it --rm -- sts get-caller-identity

# Create test PersistentVolume (if EBS CSI working)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ebs-sc
  resources:
    requests:
      storage: 10Gi
EOF

# Verify PVC
kubectl get pvc
```

---

## 📊 Outputs Available

After `terraform apply`, run `terraform output` to see:

- **Cluster Information**
  - Cluster name, ARN, version
  - API endpoint (for kubectl config)
  - CA certificate

- **Node Group Information**
  - Node group ID, ARN
  - Capacity type, scaling config
  - Instance types

- **Network Information**
  - Public/private subnet IDs
  - Security group IDs
  - Pod subnet IDs

- **Add-on Versions**
  - Pod Identity Agent version
  - EBS CSI version
  - VPC CNI version
  - Kube Proxy version
  - CoreDNS version

- **IAM Roles**
  - Control plane role ARN
  - Worker node role ARN
  - EBS CSI role ARN
  - VPC CNI role ARN

- **Helper Information**
  - kubectl config update command
  - Post-deployment verification steps

---

## 🆘 Troubleshooting

### Issue: "subnets not found"
**Cause**: Subnets don't have proper `SubnetType` tags  
**Solution**: 
```bash
# Verify subnet tags in AWS console
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxx" --query 'Subnets[*].[SubnetId,Tags]'
```

### Issue: "Access Denied" for S3 backend
**Cause**: S3 bucket permissions  
**Solution**:
```bash
# Check bucket exists and you have access
aws s3api head-bucket --bucket your-bucket-name
```

### Issue: Nodes not joining cluster
**Cause**: Security group rules missing  
**Solution**:
- Ensure node security group allows outbound to control plane (443)
- Ensure control plane security group allows inbound from node CIDR

### Issue: Pods in Pending state
**Cause**: Usually insufficient node resources  
**Solution**:
```bash
kubectl describe pod <pod-name> -n kube-system
kubectl top nodes  # Check available resources
```

### Issue: EBS CSI not working
**Cause**: Pod Identity not running  
**Solution**:
```bash
# Verify Pod Identity pod is running
kubectl get pods -n kube-system | grep pod-identity
```

---

## 📚 File Descriptions

| File | Purpose |
|------|---------|
| **c1-versions.tf** | AWS provider configuration (>= 6.0), S3 backend for remote state |
| **c2-variables.tf** | All input variables with defaults and descriptions |
| **c3-01-iam-eks.tf** | IAM role and policies for EKS control plane |
| **c3-02-eks-cluster.tf** | EKS cluster resource with networking, logging, endpoints |
| **c3-03-network-data.tf** | Data sources to discover subnets and security groups by tags |
| **c4-01-iam-node-groups.tf** | IAM role and policies for EKS worker nodes |
| **c4-02-node-groups.tf** | Node group resource with scaling, instance type, disk config |
| **c5-01-PIA-add-on.tf** | Pod Identity Agent for pod IAM roles |
| **c5-02-EBS-addon.tf** | EBS CSI driver + IAM role + Pod Identity Association |
| **c5-03-kube-proxy.tf** | Kube Proxy for Kubernetes networking |
| **c5-06-vpc-cni.tf** | VPC CNI + IAM role + Pod Identity Association |
| **c5-07-coreDNS.tf** | CoreDNS for pod DNS resolution |
| **c6-outputs.tf** | Output values for cluster info, add-ons, IAM roles |

---

## 🔐 Security Considerations

1. **Restrict Public Access**
   - Change `cluster_endpoint_public_access_cidrs` to your IP
   - Use bastion host for cluster access in production

2. **IAM Policies**
   - Review IAM policies attached to node roles
   - Implement least privilege principles
   - Use Pod Identity instead of node role for pod permissions

3. **Network Policies**
   - Implement Kubernetes Network Policies for pod-to-pod communication
   - Restrict ingress/egress from security groups

4. **Encryption**
   - Enable S3 bucket encryption for state file
   - Consider EBS volume encryption for persistent data
   - Enable CloudWatch log encryption

5. **Monitoring**
   - Review CloudWatch logs regularly
   - Set up CloudWatch alarms for anomalies
   - Monitor node and pod resource usage

---

## 📝 Deployment Checklist

- [ ] AWS credentials configured
- [ ] VPC created with correct CIDR
- [ ] 5 subnets created with SubnetType tags
- [ ] Internet Gateway created and attached
- [ ] NAT Gateway created in public subnet
- [ ] Security groups created
- [ ] S3 bucket created for Terraform state
- [ ] Terraform installed (>= 1.0)
- [ ] kubectl installed
- [ ] `cluster_endpoint_public_access_cidrs` restricted (if production)
- [ ] Bucket name updated in c1-versions.tf
- [ ] `terraform init` executed
- [ ] `terraform plan` reviewed
- [ ] `terraform apply` executed
- [ ] kubeconfig updated
- [ ] Cluster connectivity verified (`kubectl get nodes`)
- [ ] Add-ons verified (`kubectl get pods -n kube-system`)

---