################################################################################
# FILE: c6-outputs.tf
# PURPOSE: Consolidate all output values from the EKS cluster provisioning
# EXPLANATION:
#   - Displays important information about deployed resources
#   - Used to verify deployment success and get connection details
#   - Run `terraform output` to see all outputs after apply
################################################################################

# ============================================================================
# EKS CLUSTER OUTPUTS
# ============================================================================
/*
output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.main.arn
}

output "eks_cluster_version" {
  description = "Kubernetes version of the EKS cluster"
  value       = aws_eks_cluster.main.version
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint (use for kubectl config)"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_platform_version" {
  description = "Platform version of the EKS cluster"
  value       = aws_eks_cluster.main.platform_version
}

output "eks_cluster_ca_certificate" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

# ============================================================================
# EKS NODE GROUP OUTPUTS
# ============================================================================
output "eks_node_group_id" {
  description = "Node group ID"
  value       = aws_eks_node_group.private_nodes.id
}

output "eks_node_group_arn" {
  description = "ARN of the node group"
  value       = aws_eks_node_group.private_nodes.arn
}

output "eks_node_group_capacity_type" {
  description = "Type of capacity (ON_DEMAND or SPOT)"
  value       = aws_eks_node_group.private_nodes.capacity_type
}

output "eks_node_group_scaling_config" {
  description = "Scaling configuration of the node group"
  value       = aws_eks_node_group.private_nodes.scaling_config[0]
}

# ============================================================================
# NETWORK OUTPUTS (DISCOVERED SUBNETS & SECURITY GROUPS)
# ============================================================================
output "public_subnet_ids" {
  description = "IDs of public subnets discovered"
  value       = data.aws_subnets.public.ids
}

output "bastion_subnet_ids" {
  description = "IDs of bastion subnets discovered"
  value       = data.aws_subnets.bastion.ids
}

output "node_subnet_ids" {
  description = "IDs of private subnets for EKS worker nodes"
  value       = data.aws_subnets.node.ids
}

output "db_subnet_ids" {
  description = "IDs of private subnets for databases"
  value       = data.aws_subnets.db.ids
}

output "pod_subnet_ids" {
  description = "IDs of private subnets for Kubernetes pod deployment"
  value       = data.aws_subnets.pod.ids
}

output "eks_security_group_ids" {
  description = "IDs of security groups fetched for EKS cluster"
  value       = data.aws_security_groups.eks.ids
}

# ============================================================================
# ADD-ON OUTPUTS
# ============================================================================
output "pod_identity_addon_version" {
  description = "Installed version of Pod Identity Agent"
  value       = aws_eks_addon.pod_identity.addon_version
}

output "ebs_csi_addon_version" {
  description = "Installed version of EBS CSI driver"
  value       = aws_eks_addon.ebs_csi.addon_version
}

output "vpc_cni_addon_version" {
  description = "Installed version of VPC CNI"
  value       = aws_eks_addon.vpc_cni.addon_version
}

output "kube_proxy_addon_version" {
  description = "Installed version of Kube Proxy"
  value       = aws_eks_addon.kube_proxy.addon_version
}

output "coredns_addon_version" {
  description = "Installed version of CoreDNS"
  value       = aws_eks_addon.coredns.addon_version
}

# ============================================================================
# IAM ROLE OUTPUTS
# ============================================================================
output "eks_cluster_iam_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_group_iam_role_arn" {
  description = "ARN of the EKS node group IAM role"
  value       = aws_iam_role.eks_nodegroup_role.arn
}

output "ebs_csi_iam_role_arn" {
  description = "ARN of the EBS CSI driver IAM role"
  value       = aws_iam_role.ebs_csi_iam_role.arn
}

output "vpc_cni_iam_role_arn" {
  description = "ARN of the VPC CNI IAM role"
  value       = aws_iam_role.vpc_cni_iam_role.arn
}

# ============================================================================
# KUBECTL CONFIGURATION HELPER
# ============================================================================
output "kubectl_config_update_command" {
  description = "Command to update kubeconfig for kubectl access"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}

output "next_steps" {
  description = "Next steps to connect to the cluster"
  value       = <<-EOT
    1. Update kubeconfig:
       aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}
    
    2. Verify cluster access:
       kubectl get nodes
       kubectl get pods -A
    
    3. Check add-ons:
       kubectl get pods -n kube-system
    
    4. View cluster logs (CloudWatch):
       https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:log-groups/aws/eks/${aws_eks_cluster.main.name}
  EOT
}

*/