variable "aws_region" {
  description = "AWS region where EKS cluster will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC ID where EKS cluster and subnets already exist (REQUIRED)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eksdemo"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.33"
}

variable "environment" {
  description = "Environment name for tagging (e.g., dev, staging, production)"
  type        = string
  default     = "dev"
}
