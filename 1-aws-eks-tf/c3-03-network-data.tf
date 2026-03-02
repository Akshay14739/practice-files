################################################################################
# FILE: c3-03-network-data.tf
# PURPOSE: Dynamically discover network resources (subnets, security groups)
# EXPLANATION:
#   - Instead of hardcoding subnet IDs, this file uses data sources to find them
#   - Searches VPC for subnets tagged with specific types (public, node, pod, etc.)
#   - Same approach for security groups - finds them by name pattern or tags
#   - Makes the module reusable across different VPCs and environments
# HOW IT WORKS:
#   - User provides VPC ID
#   - Each data source queries AWS for subnets/SGs matching the tag criteria
#   - Results are passed to cluster and node group resources
################################################################################

# ============================================================================
# SUBNET DISCOVERY DATA SOURCES
# ============================================================================
# PURPOSE: Dynamically fetch subnets from the VPC based on tags
# WHY: Avoids hardcoding subnet IDs, makes module reusable
# HOW: AWS searches for subnets in the VPC with tag key=SubnetType and specific values

# Public Subnets
# CONTAINS: Load balancers, NAT gateways, potentially bastion hosts
# ROUTE: Has route to Internet Gateway (0.0.0.0/0 -> IGW)
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:${var.subnet_tag_key}"      # Search for tag: SubnetType
    values = [var.subnet_type_tags["public"]] # Tag value: public
  }
}

# Bastion Subnets
# CONTAINS: Jump servers (bastion hosts) for secure SSH access
# ROUTE: Could be public or private depending on design
data "aws_subnets" "bastion" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["bastion"]]
  }
}

# Private Subnets for EKS Worker Nodes
# CONTAINS: EC2 instances that run Kubernetes worker nodes
# ROUTE: NO direct IGW route - must use NAT gateway for internet access
# CRITICAL: These must be different from pod subnets for networking isolation
data "aws_subnets" "node" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["node"]]
  }
}

# Private Subnets for Databases
# CONTAINS: RDS databases, DynamoDB VPC endpoints, other data stores
# ROUTE: NO direct IGW route - isolated from public internet
# SECURITY: Separate from pod/node subnets for network segmentation
data "aws_subnets" "db" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["db"]]
  }
}

# Private Subnets for Kubernetes Pod Deployment
# CONTAINS: Kubernetes pods and container workloads
# ROUTE: NO direct IGW route - controlled egress through NAT gateway
# PURPOSE: Separate subnet for pods allows for different:
#   - Network policies
#   - Scaling behavior
#   - Cost allocation (pods scale dynamically, nodes don't)
data "aws_subnets" "pod" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["pod"]]
  }
}

# ============================================================================
# SECURITY GROUPS DISCOVERY DATA SOURCE
# ============================================================================
# PURPOSE: Dynamically fetch security groups for EKS cluster
# WHY: Avoids hardcoding security group IDs
# HOW: Searches by name pattern and optional tags
# WHAT IT DOES:
#   - Finds security groups by wildcard name (e.g., "eks-*")
#   - Filters by tags if provided (e.g., Environment=prod)
data "aws_security_groups" "eks" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "group-name"
    values = [var.security_group_name_filter]
  }

  dynamic "filter" {
    for_each = var.security_group_tags
    content {
      name   = "tag:${filter.key}"
      values = [filter.value]
    }
  }
}

# ============================================================================
# OUTPUT VALUES FOR VERIFICATION
# ============================================================================
# PURPOSE: Display discovered subnet and security group IDs
# USAGE: Run `terraform output` to see all discovered resources
# USEFUL FOR: Debugging - confirm you got the right subnets/SGs

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
