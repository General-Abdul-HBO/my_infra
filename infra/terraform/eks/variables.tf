variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "devops-lab"
}

variable "vpc_name" {
  description = "Name tag of the existing VPC (built by the aws_vpc stack)."
  type        = string
  default     = "main"
}

variable "cluster_name" {
  type    = string
  default = "devops-lab-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Upgrade one minor version at a time."
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API over the internet - set this to YOUR public IP as x.x.x.x/32. Nodes use the private endpoint, so this only affects you (kubectl/helm/ansible)."
  type        = list(string)

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "Set at least one CIDR, e.g. [\"203.0.113.10/32\"] (find your IP with: curl -s https://checkip.amazonaws.com)."
  }
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM user/role ARNs that get cluster-admin. Whoever runs `terraform apply` is already admin."
  type        = list(string)
  default     = []
}

variable "cluster_log_types" {
  description = "Control plane log types shipped to CloudWatch Logs."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  type    = number
  default = 7
}

variable "node_instance_types" {
  description = <<-EOT
    t3.medium = 2 vCPU / 4 GiB / max 17 pods per node. The VPC CNI gives every
    pod a VPC IP, so the instance type caps pods per node. ArgoCD + the
    Prometheus stack + the app need ~31 pods, so 3 x t3.medium (51 slots) is
    the smallest setup that fits. Micro/small instances (4-11 pods) do not.
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT (cheaper, but AWS can reclaim nodes at short notice)."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "3 = one node per availability zone."
  type        = number
  default     = 3
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size_gb" {
  type    = number
  default = 40
}
