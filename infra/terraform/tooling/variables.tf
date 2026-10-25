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

# GitHub puts these numeric IDs in the OIDC token's "sub" claim. Look them up:
#   curl -s https://api.github.com/repos/OWNER/REPO | jq '.owner.id, .id'
# If a pipeline run fails with "Not authorized to perform
# sts:AssumeRoleWithWebIdentity", compare with the real claim in CloudTrail
# (see the guide's troubleshooting table).
variable "github_owner_id" {
  description = "Numeric ID of the repo owner (user/org). null = use the name-only sub format."
  type        = number
  default     = 85952139
}

variable "github_repository_id" {
  description = "Numeric ID of the repository. null = use the name-only sub format."
  type        = number
  default     = 1404672337
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
