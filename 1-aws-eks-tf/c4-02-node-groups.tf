################################################################################
# FILE: c4-02-node-groups.tf
# PURPOSE: Create and configure EKS node groups (worker node auto-scaling groups)
# EXPLANATION:
#   - Node groups are managed groups of EC2 instances that run your Kubernetes workloads
#   - AWS manages the scaling, patching, and lifecycle of these instances
#   - This is a managed alternative to managing ASGs manually
################################################################################

# ============================================================================
# EKS NODE GROUP RESOURCE
# ============================================================================
# PURPOSE: Create a managed group of EC2 worker nodes for the EKS cluster
# WHAT IT CREATES:
#   - Auto Scaling Group with EC2 instances
#   - Launch template with optimized EKS AMI (Amazon Linux 2023)
#   - CloudFormation stack to manage the ASG
resource "aws_eks_node_group" "private_nodes" {
  # Basic Configuration
  cluster_name    = aws_eks_cluster.main.name           # Link to EKS cluster created in c3-02
  node_group_name = "private-ng-1"                      # Unique name for this node group
  node_role_arn   = aws_iam_role.eks_nodegroup_role.arn # IAM role (permissions from c4-01)

  # ========================================================================
  # NETWORK CONFIGURATION
  # ========================================================================
  # SUBNET IDS: EKS will launch EC2 instances in these private subnets
  # IMPORTANT: Should be PRIVATE subnets with NAT gateway (not direct IGW)
  # Multiple subnets = multi-AZ deployment for high availability
  subnet_ids = data.aws_subnets.node.ids

  # ========================================================================
  # INSTANCE CONFIGURATION
  # ========================================================================
  # INSTANCE TYPES: EC2 instance types for this node group
  # Can specify multiple types - AWS will use whichever is available
  # Allow EC2 to optimize for capacity and cost
  instance_types = var.node_instance_types

  # CAPACITY TYPE: ON_DEMAND vs SPOT instances
  # ON_DEMAND: Reliable, higher cost (use for production)
  # SPOT: Cheaper, can be interrupted (use for batch jobs, dev/test)
  capacity_type = var.node_capacity_type

  # AMI TYPE: Operating system and runtime for nodes
  # AL2023_x86_64_STANDARD: Amazon Linux 2023 with containerd runtime
  # Other options: AL2_x86_64, AL2_x86_64_GPU, WINDOWS_CORE_2022_x86_64
  ami_type = "AL2023_x86_64_STANDARD"

  # DISK SIZE: Root volume (EBS) size in GiB
  # Stores OS, container images, and temporary container storage
  # 200 GiB is reasonable for most workloads
  # Increase if running large container images or heavy I/O workloads
  disk_size = var.node_disk_size

  # ========================================================================
  # SCALING CONFIGURATION
  # ========================================================================
  # Controls how many nodes should run at different times
  scaling_config {
    # DESIRED SIZE: Target number of nodes to keep running
    # Start with 3 to avoid single points of failure
    desired_size = 3

    # MIN SIZE: Never go below this number (maintains availability)
    # At minimum 2 across different AZs for HA
    min_size = 2

    # MAX SIZE: Never exceed this number (cost control)
    # Prevent runaway scaling due to misconfigured HPA
    max_size = 6
  }

  # ========================================================================
  # UPDATE CONFIGURATION
  # ============================================================================
  # Controls how AWS replaces nodes during OS updates or version upgrades
  update_config {
    # MAX UNAVAILABLE PERCENTAGE: Max % of nodes that can be down during updates
    # 33% = If we have 3 nodes, 1 can be down at a time during updates
    # AWS drains pods gracefully before terminating old nodes
    max_unavailable_percentage = 33
  }

  # ========================================================================
  # DEPENDENCY MANAGEMENT
  # ========================================================================
  # Wait for IAM policies to be attached before creating nodes
  # Ensures nodes have all required permissions from the start
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy
  ]

  # ========================================================================
  # LIFECYCLE NOTE
  # ========================================================================
  # When you update instance_types or other properties:
  # - AWS creates new nodes with new config
  # - Gracefully drains old nodes (respects pod disruption budgets)
  # - Removes old nodes after new ones are ready
  # This is why update_config is important - controls how many nodes update at once
}