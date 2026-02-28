resource "aws_eks_cluster" "main" {
  name     = var.cluster_name

  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn
  vpc_config {
    subnet_ids = concat(
      data.aws_subnets.public.ids,
      data.aws_subnets.node.ids,
      data.aws_subnets.pod.ids
    )
    security_groups = data.aws_security_groups.eks.ids
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.cluster_service_ipv4_cidr
  }

  enabled_cluster_log_types = [
    "api",                 # API server audit logs
    "audit",               # Kubernetes audit logs
    "authenticator",       # Authenticator logs for IAM auth
    "controllerManager",   # Logs for controller manager
    "scheduler"            # Logs for pod scheduling
  ]


  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]

}
