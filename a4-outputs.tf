/*
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks_cluster.eks_cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint for kubectl configuration"
  value       = module.eks_cluster.eks_cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks_cluster.eks_cluster_version
}

output "cluster_platform_version" {
  description = "EKS platform version"
  value       = module.eks_cluster.eks_cluster_platform_version
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = module.eks_cluster.eks_cluster_arn
}

output "cluster_ca_certificate" {
  description = "Certificate Authority (CA) data for the cluster (base64 encoded)"
  value       = module.eks_cluster.eks_cluster_ca_certificate
  sensitive   = true
}

output "node_group_id" {
  description = "ID of the EKS Node Group"
  value       = module.eks_cluster.eks_node_group_id
}

output "node_group_arn" {
  description = "ARN of the Node Group"
  value       = module.eks_cluster.eks_node_group_arn
}

output "node_group_capacity_type" {
  description = "Node group capacity type (ON_DEMAND or SPOT)"
  value       = module.eks_cluster.eks_node_group_capacity_type
}

output "node_group_scaling_config" {
  description = "Node group auto-scaling configuration"
  value       = module.eks_cluster.eks_node_group_scaling_config
}

output "public_subnet_ids" {
  description = "IDs of discovered public subnets (SubnetType=public)"
  value       = module.eks_cluster.public_subnet_ids
}

output "bastion_subnet_ids" {
  description = "IDs of discovered bastion subnets (SubnetType=bastion)"
  value       = module.eks_cluster.bastion_subnet_ids
}

output "node_subnet_ids" {
  description = "IDs of discovered node subnets where worker nodes are deployed (SubnetType=node)"
  value       = module.eks_cluster.node_subnet_ids
}

output "db_subnet_ids" {
  description = "IDs of discovered DB subnets for databases (SubnetType=db)"
  value       = module.eks_cluster.db_subnet_ids
}

output "pod_subnet_ids" {
  description = "IDs of discovered pod subnets for Kubernetes pod IP assignment (SubnetType=pod)"
  value       = module.eks_cluster.pod_subnet_ids
}

output "security_group_ids" {
  description = "IDs of discovered security groups used by the EKS cluster"
  value       = module.eks_cluster.eks_security_group_ids
}

output "pod_identity_agent_version" {
  description = "Version of Pod Identity Agent add-on (prerequisite for other add-ons)"
  value       = module.eks_cluster.pod_identity_agent_version
}

output "ebs_csi_driver_version" {
  description = "Version of EBS CSI Driver add-on (for persistent volumes)"
  value       = module.eks_cluster.ebs_csi_driver_version
}

output "vpc_cni_version" {
  description = "Version of VPC CNI add-on (for pod networking)"
  value       = module.eks_cluster.vpc_cni_version
}

output "kube_proxy_version" {
  description = "Version of Kube Proxy add-on (for service networking)"
  value       = module.eks_cluster.kube_proxy_version
}

output "coredns_version" {
  description = "Version of CoreDNS add-on (for pod DNS resolution)"
  value       = module.eks_cluster.coredns_version
}

output "cluster_iam_role_arn" {
  description = "ARN of the IAM role for the EKS control plane"
  value       = module.eks_cluster.cluster_iam_role_arn
}

output "node_group_iam_role_arn" {
  description = "ARN of the IAM role for worker nodes"
  value       = module.eks_cluster.node_group_iam_role_arn
}

output "ebs_csi_iam_role_arn" {
  description = "ARN of the IAM role for EBS CSI Driver (uses Pod Identity)"
  value       = module.eks_cluster.ebs_csi_iam_role_arn
}

output "vpc_cni_iam_role_arn" {
  description = "ARN of the IAM role for VPC CNI (uses Pod Identity)"
  value       = module.eks_cluster.vpc_cni_iam_role_arn
}

output "kubectl_config_update_command" {
  description = "Command to update local kubeconfig to connect to this EKS cluster"
  value       = module.eks_cluster.kubectl_config_update_command
}

output "next_steps" {
  description = "Instructions for post-deployment verification"
  value       = <<-EOT
POST-DEPLOYMENT CHECKLIST:

1. Update your local kubeconfig:
   ${module.eks_cluster.kubectl_config_update_command}

2. Verify cluster connectivity:
   kubectl cluster-info

3. Check worker nodes are running:
   kubectl get nodes
   
4. Verify all add-ons are installed:
   kubectl get pods -n kube-system
   
5. List all deployed add-ons:
   aws eks list-addons --cluster-name ${module.eks_cluster.eks_cluster_name} --region ${var.aws_region}

6. Check pod networking (VPC CNI):
   kubectl get ds aws-node -n kube-system

7. Check EBS CSI Driver:
   kubectl get pods -n kube-system | grep ebs-csi

8. Monitor cluster health:
   kubectl get events -A
   kubectl top nodes
   kubectl top pods -A

9. Deploy a test workload:
   kubectl create deployment test-deployment --image=nginx --replicas=2
   kubectl get pods
   kubectl logs <pod-name>

10. Clean up test workload:
    kubectl delete deployment test-deployment

COMMON COMMANDS:
- Get cluster info: kubectl cluster-info
- Get nodes: kubectl get nodes
- Get pods: kubectl get pods --all-namespaces
- View logs: kubectl logs <pod-name> -n <namespace>
- Port forward: kubectl port-forward <pod-name> <local-port>:<pod-port>
- SSH to node: aws ec2-instance-connect start-session --target <instance-id>

TERRAFORM COMMANDS:
- View all outputs: terraform output
- View specific output: terraform output <output-name>
- Refresh state: terraform refresh
- Destroy cluster: terraform destroy
EOT
}

*/