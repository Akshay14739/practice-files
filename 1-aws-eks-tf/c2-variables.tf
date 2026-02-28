variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix in names of related resources."
  type        = string
  default     = "eksdemo"
}


variable "cluster_version" {
  description = "Kubernetes minor version to use for the EKS cluster (e.g. 1.28, 1.29)"
  type        = string
  default     = "1.33"
}

variable "cluster_service_ipv4_cidr" {
  description = "Service CIDR range for Kubernetes services. Optional — leave null to use AWS default."
  type        = string
  default     = "172.20.0.0/16"
}


variable "cluster_endpoint_private_access" {
  description = "Whether to enable private access to EKS control plane endpoint"
  type        = bool
  default     = true
}


variable "cluster_endpoint_public_access" {
  description = "Whether to enable public access to EKS control plane endpoint"
  type        = bool
  default     = true
}


variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks allowed to access public EKS endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "List of EC2 instance types for the node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "Instance capacity type: ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

# Root volume size (GiB) for worker nodes
variable "node_disk_size" {
  description = "Disk size in GiB for worker nodes"
  type        = number
  default     = 200
}

variable "vpc_id" {
  description = "VPC ID where EKS cluster will be deployed"
  type        = string
}

variable "security_group_name_filter" {
  description = "Name pattern to filter security groups in the VPC (e.g., 'eks-*')"
  type        = string
  default     = "*"
}

variable "security_group_tags" {
  description = "Map of tags to filter security groups (optional)"
  type        = map(string)
  default     = {}
}
variable "subnet_type_tags" {
  description = "Map of subnet types to their tag filter values. Keys: public, bastion, node, db, pod. Values are tag values to match."
  type        = map(string)
  default     = {
    public  = "public"
    bastion = "bastion"
    node    = "node"
    db      = "db"
    pod     = "pod"
  }
}

variable "subnet_tag_key" {
  description = "Tag key used to identify subnet types (e.g., 'SubnetType')"
  type        = string
  default     = "SubnetType"
}