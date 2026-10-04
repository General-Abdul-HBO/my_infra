output "region" {
  value = var.aws_region
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "vpc_id" {
  description = "Needed by the AWS Load Balancer Controller (passed in by the ArgoCD bootstrap)."
  value       = data.aws_vpc.main.id
}

output "vpc_cidr" {
  value = data.aws_vpc.main.cidr_block
}

output "node_group_subnet_ids" {
  description = "Private subnets the worker nodes run in."
  value       = data.aws_subnets.private.ids
}

output "pod_identity_role_arns" {
  value = { for k, r in aws_iam_role.pod_identity : k => r.arn }
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name} --alias ${aws_eks_cluster.this.name}"
}
