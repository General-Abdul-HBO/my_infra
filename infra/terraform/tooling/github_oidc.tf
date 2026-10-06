# ---------------------------------------------------------------------------
# GitHub Actions -> AWS without stored keys (OpenID Connect).
#
# Each workflow run gets a signed token from GitHub saying "I am a run of repo
# X on branch Y". AWS checks the signature against this OIDC provider and, if
# the claims match the role's trust policy, hands back credentials that expire
# in an hour. Nothing long-lived exists that could leak.
# ---------------------------------------------------------------------------

# One GitHub OIDC provider per AWS account. If you've already created one
# (e.g. for another project), set create_github_oidc_provider = false.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Who may assume the role: ONLY workflow runs from this repo, on this branch.
# Pull requests, other branches, forks and other repos are all refused.
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.project}-github-actions"
  description          = "Assumed by GitHub Actions (${var.github_repository}@${var.github_branch}) to push images to ECR"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600
}

# What the role may do: log in to ECR and push/read images in OUR repos only.
# No EKS or kubectl access - deploying is ArgoCD's job, triggered by Git.
data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this API has no resource-level permissions
  }

  statement {
    sid = "PushToAppRepositories"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [for repo in aws_ecr_repository.app : repo.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
