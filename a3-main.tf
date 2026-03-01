module "eks_cluster" {
  source = "./1-aws-eks-tf"

  vpc_id = var.vpc_id

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_service_ipv4_cidr = "172.20.0.0/16"

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

  node_instance_types = ["t3.medium"]

  node_capacity_type = "ON_DEMAND"

  node_disk_size = 200

  subnet_tag_key = "SubnetType"
  subnet_type_tags = {
    public  = "public"
    bastion = "bastion"
    node    = "node"
    db      = "db"
    pod     = "pod"
  }

  security_group_name_filter = "*"

  security_group_tags = {}
}
