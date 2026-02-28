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

  # Remote State Backend Configuration
  # PURPOSE: Store Terraform state in S3 for team collaboration and safety
  # WHY: Prevents state file corruption, enables state locking, and allows team sharing
  # NOTE: Replace 'bucket-name' with your actual S3 bucket name before running terraform init
  backend "s3" {
    bucket         = "bucket-name"         # S3 bucket where state will be stored
    key            = "/terraform.tfstate"   # Path to state file within bucket
    region         = "us-east-1"           # AWS region where S3 bucket exists
    encrypt        = true                  # Enable encryption at rest for state file
    use_lockfile   = true                  # Enable DynamoDB state locking (prevents concurrent modifications)
  }
}

# AWS Provider Configuration
# This provider block tells Terraform which AWS region to use for all resources
# Region is passed dynamically from variables to allow flexibility across environments
provider "aws" {
  region = var.aws_region  # Region will be set at runtime via variables or defaults to "us-east-1"
}
