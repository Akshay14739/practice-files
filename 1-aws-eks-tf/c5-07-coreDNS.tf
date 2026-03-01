################################################################################
# FILE: c5-07-coreDNS.tf
# PURPOSE: Install and manage CoreDNS add-on
# EXPLANATION:
#   - CoreDNS provides DNS resolution for Kubernetes services
#   - Allows pods to discover services by DNS name (e.g., service-name.namespace.svc.cluster.local)
#   - Usually pre-installed but managed here for version control
################################################################################

# Data source to get latest compatible version
data "aws_eks_addon_version" "coredns_latest" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Install CoreDNS as EKS managed add-on
resource "aws_eks_addon" "coredns" {
  cluster_name    = aws_eks_cluster.main.name
  addon_name      = "coredns"
  addon_version   = data.aws_eks_addon_version.coredns_latest.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_addon.pod_identity,          # Pod Identity must be running
    aws_eks_node_group.private_nodes     # Nodes must be ready
  ]
}