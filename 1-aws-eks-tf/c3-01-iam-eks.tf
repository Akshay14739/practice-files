################################################################################
# FILE: c3-01-iam-eks.tf
# PURPOSE: Configure IAM roles and policies for EKS control plane
# EXPLANATION:
#   - EKS control plane (Kubernetes API server) runs within AWS
#   - It needs IAM permissions to manage resources like ENIs, NLBs, security groups
#   - This file creates the IAM role that the EKS control plane assumes
################################################################################

# ============================================================================
# EKS CONTROL PLANE IAM ROLE
# ============================================================================
# PURPOSE: IAM role for the EKS control plane (Kubernetes API server)
# WHO ASSUMES THIS ROLE: The AWS EKS service itself
# WHY NEEDED: EKS needs to create/manage EC2 ENIs, NLBs, and security groups
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"

  # Trust Policy: Allows the EKS service to assume this role
  # This is a service-to-service role assumption (EKS assumes the role, not a user)
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",      # Permission to assume this role
      Effect    = "Allow",
      Principal = {
        Service = "eks.amazonaws.com"    # Only AWS EKS service can assume this role
      }
    }]
  })
}

# ============================================================================
# EKS CLUSTER POLICY ATTACHMENT
# ============================================================================
# PURPOSE: AWS managed policy with essential EKS control plane permissions
# PERMISSIONS GRANTED:
#   - Manage VPC networking (ENIs, security groups)
#   - Create and manage load balancers for services
#   - Manage CloudWatch logs for cluster logging
#   - Manage IAM roles for service accounts
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ============================================================================
# VPC RESOURCE CONTROLLER POLICY ATTACHMENT
# ============================================================================
# PURPOSE: Allows EKS to manage VPC resources (ENI, IP address management)
# EXPLANATION: Required for EKS to assign pod IPs and manage network interfaces
# USED BY: CNI (Container Network Interface) plugins for pod networking
resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}