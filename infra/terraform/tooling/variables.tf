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

# --- GitHub Actions (CI/CD) ---------------------------------------------------

variable "github_repository" {
  description = "owner/repo whose workflows may push images. Case-sensitive - must match GitHub exactly."
  type        = string
  default     = "General-Abdul-HBO/my_infra"
}

variable "github_branch" {
  description = "Only workflow runs on this branch can assume the CI role."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    true = this stack creates and OWNS the GitHub OIDC provider (the normal case).
    Set false ONLY if the very first apply fails with EntityAlreadyExists, i.e. the
    provider was created outside this stack. Never flip it to false after this stack
    created the provider: Terraform would DELETE it and CI logins to AWS would break.
  EOT
  type        = bool
  default     = true
}
