################################################################################
# FILE: c5-01-PIA-add-on.tf
# PURPOSE: Install AWS EKS Pod Identity Agent
# EXPLANATION:
#   - Pod Identity enables pods to assume IAM roles securely
#   - Must be installed first before other add-ons that need IAM access
#   - Provides webhook and controller for pod-to-role mapping
################################################################################

# Data source: fetch latest compatible version of the EKS Pod Identity Agent
data "aws_eks_addon_version" "pia_latest" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Install the Pod Identity Agent add-on
# PURPOSE: Enables IAM role assumption for pods
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.pia_latest.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.private_nodes   # Nodes must exist before agent pods can run
  ]
}

# Reusable trust policy — allows EKS Pod Identity to assume IAM roles
# This is referenced by other add-ons (EBS CSI, VPC CNI) that need IAM permissions
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]  # Pod Identity service principal
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}