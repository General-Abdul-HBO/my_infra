variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "devops-lab"
}

variable "ecr_repositories" {
  description = "One ECR repository per application image."
  type        = list(string)
  default     = ["example-app"]
}

variable "ecr_force_delete" {
  description = "Lab setting: allow `terraform destroy` to delete repositories that still contain images."
  type        = bool
  default     = true
}
