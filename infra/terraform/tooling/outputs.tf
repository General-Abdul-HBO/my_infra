output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "ecr_registry" {
  description = "Registry hostname for `docker login`."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "github_actions_role_arn" {
  description = "Put this in the GitHub repo variable AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}
