################################################################################
# FILE: c5-06-vpc-cni.tf
# PURPOSE: Install and manage AWS VPC CNI (Container Network Interface) add-on
# EXPLANATION:
#   - VPC CNI is the default networking plugin for EKS
#   - Assigns pod IPs directly from VPC subnets
#   - Usually pre-installed but managed here for version control
#   - Requires IAM permissions via Pod Identity
################################################################################

# 1) VPC CNI IAM Role
# PURPOSE: Permissions for VPC CNI to manage ENIs and IP addresses
resource "aws_iam_role" "vpc_cni_iam_role" {
  name               = "vpc-cni-iam-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json  # From c5-01
}

# Attach AWS managed VPC CNI policy
resource "aws_iam_role_policy_attachment" "vpc_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni_iam_role.name
}

# 2) VPC CNI Pod Identity Association
# PURPOSE: Link VPC CNI pod to IAM role
resource "aws_eks_pod_identity_association" "vpc_cni" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "aws-node"  # Default service account created by VPC CNI add-on
  role_arn        = aws_iam_role.vpc_cni_iam_role.arn
}

# 3) VPC CNI Add-on Installation
# Data source to get latest compatible version
data "aws_eks_addon_version" "vpc_cni_latest" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Install VPC CNI as EKS managed add-on
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  addon_version            = data.aws_eks_addon_version.vpc_cni_latest.version
  service_account_role_arn = aws_iam_role.vpc_cni_iam_role.arn  # Link IAM role to add-on

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni_policy,  # IAM role must have policy
    aws_eks_pod_identity_association.vpc_cni,       # Pod Identity link must exist
    aws_eks_addon.pod_identity                      # Pod Identity Agent must be running
  ]
}