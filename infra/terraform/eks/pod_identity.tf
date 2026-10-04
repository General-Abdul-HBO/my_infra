# ---------------------------------------------------------------------------
# EKS Pod Identity: give a Kubernetes ServiceAccount an IAM role.
#
# Instead of putting AWS keys in pods (or letting them use the node's role),
# the pod-identity agent hands short-lived credentials for the role below to
# any pod running as <namespace>/<service account>. Nothing is annotated in
# Kubernetes - the mapping lives here, in AWS.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# Grafana: read-only CloudWatch access so it can chart AWS metrics/logs
# (ALB, NAT gateway, EKS control plane logs...) next to Prometheus data.
data "aws_iam_policy_document" "grafana_cloudwatch" {
  statement {
    sid = "CloudWatchRead"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  statement {
    sid = "LogsRead"
    actions = [
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ResourceDiscovery"
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

locals {
  pod_identities = {
    ebs-csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      managed_policy  = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      inline_policy   = null
    }
    aws-load-balancer-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      managed_policy  = null
      # Official policy for LBC v3.5.0, vendored from
      # https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.5.0/docs/install/iam_policy.json
      inline_policy = file("${path.module}/policies/aws-load-balancer-controller.json")
    }
    grafana = {
      namespace       = "monitoring"
      service_account = "grafana"
      managed_policy  = null
      inline_policy   = data.aws_iam_policy_document.grafana_cloudwatch.json
    }
  }
}

resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identities

  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "pod_identity" {
  for_each = { for k, v in local.pod_identities : k => v if v.managed_policy != null }

  role       = aws_iam_role.pod_identity[each.key].name
  policy_arn = each.value.managed_policy
}

resource "aws_iam_role_policy" "pod_identity" {
  for_each = { for k, v in local.pod_identities : k => v if v.inline_policy != null }

  name   = each.key
  role   = aws_iam_role.pod_identity[each.key].id
  policy = each.value.inline_policy
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = local.pod_identities

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.pod_identity[each.key].arn

  depends_on = [aws_eks_addon.before_nodes] # needs eks-pod-identity-agent
}
