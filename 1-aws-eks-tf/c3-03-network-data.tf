# Data sources to dynamically fetch subnets by type from the specified VPC

# Public Subnets
data "aws_subnets" "public" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["public"]]
  }
}

# Bastion Subnets
data "aws_subnets" "bastion" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["bastion"]]
  }
}

# Private Subnets for EKS Nodes
data "aws_subnets" "node" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["node"]]
  }
}

# Private Subnets for Databases
data "aws_subnets" "db" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["db"]]
  }
}

# Private Subnets for Kubernetes Pod Deployment
data "aws_subnets" "pod" {
  vpc_id = var.vpc_id

  filter {
    name   = "tag:${var.subnet_tag_key}"
    values = [var.subnet_type_tags["pod"]]
  }
}

# Fetch security groups dynamically
data "aws_security_groups" "eks" {
  vpc_id = var.vpc_id

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

# Outputs for verification
output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = data.aws_subnets.public.ids
}

output "bastion_subnet_ids" {
  description = "IDs of bastion subnets"
  value       = data.aws_subnets.bastion.ids
}

output "node_subnet_ids" {
  description = "IDs of private subnets for EKS nodes"
  value       = data.aws_subnets.node.ids
}

output "db_subnet_ids" {
  description = "IDs of private subnets for databases"
  value       = data.aws_subnets.db.ids
}

output "pod_subnet_ids" {
  description = "IDs of private subnets for pod deployment"
  value       = data.aws_subnets.pod.ids
}

output "eks_security_group_ids" {
  description = "IDs of security groups fetched for EKS cluster"
  value       = data.aws_security_groups.eks.ids
}
