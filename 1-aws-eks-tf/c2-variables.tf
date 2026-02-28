################################################################################
# FILE: c2-variables.tf
# PURPOSE: Define all input variables for EKS cluster provisioning
# EXPLANATION:
#   - Contains cluster configuration variables (name, version, networking)
#   - Contains node group configuration variables (instance types, scaling)
#   - Contains network lookup variables (VPC ID, subnet tags, security groups)
#   - All variables have sensible defaults but can be overridden at runtime
################################################################################

# ============================================================================
# AWS REGION CONFIGURATION
# ============================================================================
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
  # USAGE: -var="aws_region=us-west-2"
}

# ============================================================================
# EKS CLUSTER CONFIGURATION
# ============================================================================
variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix in names of related resources."
  type        = string
  default     = "eksdemo"
  # USAGE: -var="cluster_name=my-production-cluster"
  # NOTE: This name appears in EKS console and is used to tag related resources
}


variable "cluster_version" {
  description = "Kubernetes minor version to use for the EKS cluster (e.g. 1.28, 1.29)"
  type        = string
  default     = "1.33"
  # USAGE: -var="cluster_version=1.29"
  # NOTE: AWS automatically patches patch versions. Check AWS docs for supported K8s versions.
}

variable "cluster_service_ipv4_cidr" {
  description = "Service CIDR range for Kubernetes services. Optional — leave null to use AWS default."
  type        = string
  default     = "172.20.0.0/16"
  # USAGE: -var="cluster_service_ipv4_cidr=10.100.0.0/16"
  # PURPOSE: Kubernetes ClusterIP service IPs come from this range
  # NOTE: Must not overlap with VPC CIDR or node pod CIDR ranges
}


# ============================================================================
# EKS ENDPOINT ACCESS CONFIGURATION
# ============================================================================
variable "cluster_endpoint_private_access" {
  description = "Whether to enable private access to EKS control plane endpoint"
  type        = bool
  default     = true
  # PURPOSE: Allows nodes and internal clients to access EKS API via private endpoint
  # SECURITY: Recommended to keep true - reduces exposure of control plane
}


variable "cluster_endpoint_public_access" {
  description = "Whether to enable public access to EKS control plane endpoint"
  type        = bool
  default     = true
  # PURPOSE: Allows kubectl CLI access from internet (restricted by CIDR below)
  # SECURITY: Restrict with cluster_endpoint_public_access_cidrs - do NOT use 0.0.0.0/0 in production
}


variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks allowed to access public EKS endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
  # USAGE: -var="cluster_endpoint_public_access_cidrs=[\"10.0.0.0/8\",\"203.0.113.0/24\"]"
  # WARNING: Default \"0.0.0.0/0\" allows ANY IP - restrict in production to your office/VPN IPs
  # EXAMPLE: -var="cluster_endpoint_public_access_cidrs=[\"203.0.113.100/32\"]"
}

# ============================================================================
# EKS NODE GROUP CONFIGURATION
# ============================================================================
variable "node_instance_types" {
  description = "List of EC2 instance types for the node group"
  type        = list(string)
  default     = ["t3.medium"]
  # USAGE: -var="node_instance_types=[\"t3.medium\",\"t3.large\"]"
  # PURPOSE: EC2 instance types for Kubernetes worker nodes
  # NOTE: Supports multiple types - AWS auto-selects based on availability
  # RECOMMENDATION: Use t3 family for dev/test, c5/m5 for production
}

variable "node_capacity_type" {
  description = "Instance capacity type: ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
  # USAGE: -var="node_capacity_type=SPOT"
  # ON_DEMAND: Higher cost but guaranteed availability
  # SPOT: Lower cost but instances can be interrupted (use for non-critical workloads)
}

variable "node_disk_size" {
  description = "Disk size in GiB for worker nodes (root volume size)"
  type        = number
  default     = 200
  # USAGE: -var="node_disk_size=100"
  # PURPOSE: EBS volume size for node OS and container storage
  # SIZING: 200 GiB is reasonable for most workloads; increase if running large containers
}

# ============================================================================
# NETWORK CONFIGURATION (VPC, SUBNETS, SECURITY GROUPS)
# ============================================================================
variable "vpc_id" {
  description = "VPC ID where EKS cluster will be deployed"
  type        = string
  # REQUIRED: Must be provided at runtime
  # USAGE: -var="vpc_id=vpc-0123456789abcdef0"
  # PURPOSE: Identifies which VPC contains the subnets for EKS
  # NOTE: This is how we dynamically discover subnets instead of hardcoding them
}

variable "security_group_name_filter" {
  description = "Name pattern to filter security groups in the VPC (e.g., 'eks-*')"
  type        = string
  default     = "*"
  # USAGE: -var="security_group_name_filter=eks-*"
  # PURPOSE: Wildcard pattern to find security groups for EKS cluster
  # NOTE: Uses AWS EC2 name pattern matching (not regex)
}

variable "security_group_tags" {
  description = "Map of tags to filter security groups (optional)"
  type        = map(string)
  default     = {}
  # USAGE: -var="security_group_tags={Environment=prod,Team=platform}"
  # PURPOSE: Filter security groups by tags for more granular control
}

# ============================================================================
# SUBNET DISCOVERY CONFIGURATION
# ============================================================================
# PURPOSE: These variables define how to discover 5 subnet types in the VPC:
#   1. Public: Contains NAT gateways, bastion hosts
#   2. Bastion: Jump servers for secure SSH access
#   3. Node: Private subnets for EKS worker node EC2 instances
#   4. DB: Private subnets isolated for databases (RDS, DynamoDB, etc.)
#   5. Pod: Private subnets for Kubernetes pods to be deployed
# 
# All subnets are discovered using tags on the subnet resources
# This prevents hardcoding subnet IDs and makes the module reusable
variable "subnet_type_tags" {
  description = "Map of subnet types to their tag filter values. Keys: public, bastion, node, db, pod. Values are tag values to match."
  type        = map(string)
  default     = {
    public  = "public"    # Subnets with SubnetType=public (has IGW route)
    bastion = "bastion"   # Subnets with SubnetType=bastion (jump servers)
    node    = "node"      # PRIVATE subnets with SubnetType=node (EKS worker nodes)
    db      = "db"        # PRIVATE subnets with SubnetType=db (databases)
    pod     = "pod"       # PRIVATE subnets with SubnetType=pod (K8s pods)
  }
  # USAGE: To use different tag values, override with -var="subnet_type_tags={public=public-tier,node=private-nodes,pod=pod-tier,db=rds-tier,bastion=jump}"
}

variable "subnet_tag_key" {
  description = "Tag key used to identify subnet types (e.g., 'SubnetType')"
  type        = string
  default     = "SubnetType"
  # USAGE: -var="subnet_tag_key=Environment"
  # PURPOSE: AWS will look for subnets with this tag key
  # EXAMPLE: If subnet_tag_key=SubnetType, it looks for tags like SubnetType=node, SubnetType=pod, etc.
}