locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ---------------------------------------------------------------------------
# KMS key for envelope-encrypting Kubernetes Secrets in etcd
# ---------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name} Kubernetes secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

# ---------------------------------------------------------------------------
# Control plane logs -> CloudWatch. Created up front so we control retention
# (if EKS creates it, logs are kept forever and you pay for that).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days
}

# ---------------------------------------------------------------------------
# IAM role assumed by the EKS control plane
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "cluster_kms" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [aws_kms_key.eks.arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "kms-secrets-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

# ---------------------------------------------------------------------------
# The EKS cluster
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Control plane network interfaces live in the private subnets.
    subnet_ids = data.aws_subnets.private.ids

    # Nodes talk to the API server privately, inside the VPC...
    endpoint_private_access = true
    # ...and you reach it from your laptop over the internet, but only from
    # the CIDRs you list. Production would usually be private-only + VPN.
    endpoint_public_access = true
    public_access_cidrs    = var.cluster_endpoint_public_access_cidrs
  }

  # Access entries (API mode) replace the old aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = var.cluster_log_types

  # STANDARD = when this version leaves standard support, EKS auto-upgrades
  # it. EXTENDED (the AWS default) keeps it running but costs 6x more per hour.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# Extra cluster admins (optional). The identity that ran `terraform apply`
# is already admin via bootstrap_cluster_creator_admin_permissions.
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "admins" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admins" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}
