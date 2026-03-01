################################################################################
# FILE: c5-03-kube-proxy.tf
# PURPOSE: Install and manage Kube Proxy add-on
# EXPLANATION:
#   - Kube Proxy implements Kubernetes networking rules (iptables/IPVS)
#   - Handles service load balancing and network routing
#   - Usually pre-installed but managed here for version control
################################################################################

# Data source to get latest compatible version
data "aws_eks_addon_version" "kube_proxy_latest" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# Install/manage the Kube Proxy add-on
resource "aws_eks_addon" "kube_proxy" {
  cluster_name    = aws_eks_cluster.main.name
  addon_name      = "kube-proxy"
  addon_version   = data.aws_eks_addon_version.kube_proxy_latest.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_addon.pod_identity,          # Pod Identity must be running
    aws_eks_node_group.private_nodes     # Nodes must be ready
  ]
}