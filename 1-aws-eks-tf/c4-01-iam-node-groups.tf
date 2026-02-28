################################################################################
# FILE: c4-01-iam-node-groups.tf
# PURPOSE: Configure IAM roles and policies for EKS worker nodes (EC2 instances)
# EXPLANATION:
#   - EKS worker nodes are regular EC2 instances running as Kubernetes nodes
#   - These nodes need IAM permissions to:
#     * Pull container images from ECR (Elastic Container Registry)
#     * Communicate with EKS control plane API
#     * Manage VPC networking (ENIs, elastic IPs)
#   - This file creates the IAM role assumed by worker node EC2 instances
################################################################################

# ============================================================================
# EKS WORKER NODE IAM ROLE
# ============================================================================
# PURPOSE: IAM role for EC2 worker node instances
# WHO ASSUMES THIS ROLE: EC2 instances running as Kubernetes nodes
# HOW IT'S USED: Attached to EC2 launch template/auto-scaling group
# WHY NEEDED: Nodes need permission to pull images, manage networking, access control plane
resource "aws_iam_role" "eks_nodegroup_role" {
  name = "eks-nodegroup-role-1"

  # Trust Policy: Allows EC2 service to assume this role
  # This is how EC2 instances get temporary credentials
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",         # Permission to assume this role
      Effect    = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"       # Only EC2 service can assume this role
      }
    }]
  })
}

# ============================================================================
# WORKER NODE POLICY ATTACHMENT
# ============================================================================
# PURPOSE: AWS managed policy with essential permissions for EKS worker nodes
# PERMISSIONS GRANTED:
#   - Describe EC2 instances and security groups
#   - Manage ENI (Elastic Network Interfaces) - required for pod networking
#   - Describe instance status
#   - Communicate with EKS control plane
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodegroup_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  # This is the foundation policy - all worker nodes must have this
}

# ============================================================================
# CNI (CONTAINER NETWORKING INTERFACE) POLICY ATTACHMENT
# ============================================================================
# PURPOSE: Permissions for the AWS VPC CNI plugin (pod networking)
# WHAT IT MANAGES:
#   - Pod IP address management (assigning IPs from VPC subnets to pods)
#   - ENI creation and management
#   - Secondary private IP assignment to nodes
# WHY CRITICAL: Without this, pods cannot get IP addresses
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodegroup_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  # Required for pod networking - no pods can be deployed without this
}

# ============================================================================
# ECR (ELASTIC CONTAINER REGISTRY) READ-ONLY POLICY ATTACHMENT
# ============================================================================
# PURPOSE: Permissions to pull container images from ECR
# PERMISSIONS GRANTED:
#   - List ECR repositories
#   - Pull images from ECR repositories
#   - Get image layer security scanning results
# WHY NEEDED: Kubelet on each node pulls container images when scheduling pods
# NOTE: Only read access - nodes cannot push images
resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  role       = aws_iam_role.eks_nodegroup_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  # Required for pulling container images - pods won't start without this
}
