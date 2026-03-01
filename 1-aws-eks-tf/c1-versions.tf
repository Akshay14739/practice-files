################################################################################
# FILE: c1-versions.tf
# PURPOSE: Configure Terraform version requirements, AWS provider, and remote state
# EXPLANATION:
#   - Specifies required Terraform providers and their versions
#   - Configures S3 backend for remote state management (better for team collaboration)
#   - Sets up AWS provider with region from variables
################################################################################

terraform {
  # AWS Provider Configuration
  # - source: Official HashiCorp AWS provider
  # - version: >= 6.0 ensures compatibility with modern AWS EKS features
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region  # Region will be set at runtime via variables or defaults to "us-east-1"
}
