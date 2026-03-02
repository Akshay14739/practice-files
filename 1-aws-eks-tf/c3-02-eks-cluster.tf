################################################################################
# FILE: c3-02-eks-cluster.tf
# PURPOSE: Create and configure the AWS EKS Kubernetes cluster
# EXPLANATION:
#   - Provisions the managed Kubernetes control plane (API server, etcd, scheduler)
#   - Configures networking, endpoints, logging, and cluster properties
#   - Uses data sources to dynamically discover subnets and security groups
################################################################################

# ============================================================================
# EKS CLUSTER RESOURCE
# ============================================================================
# PURPOSE: This is the main EKS control plane resource
# WHAT IT DOES:
#   - Creates managed Kubernetes control plane
#   - Manages API server, etcd database, scheduler
#   - AWS handles patching and maintenance
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name       # Cluster name (visible in AWS console)
  version  = var.cluster_version    # Kubernetes version (e.g., 1.33)
  role_arn = aws_iam_role.eks_cluster.arn  # IAM role for API server permissions
  
  # ========================================================================
  # VPC CONFIGURATION - Network settings for EKS
  # ========================================================================
  vpc_config {
    # SUBNET IDS: EKS requires subnets across multiple AZs
    # We dynamically concat three subnet types:
    #   1. public - Where load balancers and bastion hosts live
    #   2. node - Where Kubernetes worker node EC2 instances run (PRIVATE)
    #   3. pod - Where Kubernetes pods are deployed (PRIVATE)
    # AWS will distribute the control plane ENIs across these subnets
    subnet_ids = concat(
      data.aws_subnets.public.ids,  # Load balancer subnets
      data.aws_subnets.node.ids,    # Worker node subnets (must be different AZs)
      data.aws_subnets.pod.ids      # Pod deployment subnets
    )
    
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  # ========================================================================
  # KUBERNETES NETWORKING CONFIGURATION
  # ========================================================================
  kubernetes_network_config {
    # Service CIDR: IP range used for Kubernetes ClusterIP services
    # Must NOT overlap with:
    #   - VPC CIDR (e.g., 10.0.0.0/16)
    #   - Pod CIDR (assigned by CNI plugin)
    # Example cidr ranges: 172.20.0.0/16, 10.100.0.0/16
    service_ipv4_cidr = var.cluster_service_ipv4_cidr
  }

  # ========================================================================
  # CLUSTER LOGGING CONFIGURATION
  # ========================================================================
  # PURPOSE: Send EKS control plane logs to CloudWatch for monitoring/debugging
  # Each log type helps with different diagnostic tasks
  enabled_cluster_log_types = [
    "api",              # EKS API calls and API server access logs
    "audit",            # Kubernetes audit logs (who did what)
    "authenticator",    # IAM authentication and RBAC decisions
    "controllerManager", # Kubernetes controller manager logs (auto-healing, scaling)
    "scheduler"         # Kubernetes scheduler logs (pod placement decisions)
  ]
  # NEXT STEP: View logs in CloudWatch Logs under /aws/eks/cluster-name/

  # ========================================================================
  # DEPENDENCY MANAGEMENT
  # ========================================================================
  # Wait for IAM policies to be attached before creating cluster
  # This ensures EKS has all required permissions from the start
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]
}
