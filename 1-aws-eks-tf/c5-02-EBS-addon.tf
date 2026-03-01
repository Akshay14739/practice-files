################################################################################
# FILE: c5-02-EBS-addon.tf
# PURPOSE: Install AWS EBS CSI Driver add-on
# EXPLANATION:
#   - EBS CSI driver enables Kubernetes to provision AWS EBS volumes as persistent storage
#   - Requires IAM permissions to create/delete/manage EBS volumes
#   - Uses Pod Identity to securely assume IAM role without static credentials
#   - Must have Pod Identity Agent running first
################################################################################

# ============================================================================
# 1) EBS CSI IAM ROLE
# ============================================================================
# PURPOSE: Permissions for EBS CSI driver to manage EBS volumes
# WHO ASSUMES THIS ROLE: EBS CSI driver pod (via Pod Identity)
resource "aws_iam_role" "ebs_csi_iam_role" {
  name               = "ebs-csi-iam-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json  # Shared trust policy from c5-01

}

# Attach AWS managed EBS CSI policy
# PURPOSE: Grants permissions to create/delete/manage EBS volumes and snapshots
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_iam_role.name
}

# ============================================================================
# 2) EBS CSI POD IDENTITY ASSOCIATION
# ============================================================================
# PURPOSE: Link EBS CSI pod to IAM role for secure credential access
# HOW IT WORKS: Pod Identity webhook intercepts pod creation and injects AWS credentials
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"    # Default service account created by EBS CSI add-on
  role_arn        = aws_iam_role.ebs_csi_iam_role.arn
}

# ============================================================================
# 3) EBS CSI ADD-ON INSTALLATION
# ============================================================================
# PURPOSE: Install EBS CSI driver as an EKS managed add-on

# Fetch latest version compatible with cluster K8s version
data "aws_eks_addon_version" "ebs_csi_latest" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Install EBS CSI as EKS managed add-on
# PURPOSE: Deploys EBS CSI driver pod in kube-system namespace
# The pod will use Pod Identity to assume the ebs_csi_iam_role
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi_latest.version
  service_account_role_arn = aws_iam_role.ebs_csi_iam_role.arn   # Links IAM role to add-on

  resolve_conflicts_on_create = "OVERWRITE"  # Replace if conflicts exist
  resolve_conflicts_on_update = "OVERWRITE"  # Replace on updates

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_policy,       # IAM role must have policy first
    aws_eks_pod_identity_association.ebs_csi,            # Pod Identity link must exist
    aws_eks_addon.pod_identity,                          # Pod Identity Agent must be running
    aws_eks_node_group.private_nodes                     # Worker nodes must be ready
  ]
}