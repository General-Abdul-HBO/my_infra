# EKS managed add-ons: AWS installs, patches and supports these components.
# Each add-on runs the version AWS marks as the default for the cluster's
# Kubernetes version - bump kubernetes_version and the add-ons follow.

locals {
  # Daemonsets that nodes need from their first boot.
  addons_before_nodes = {
    "vpc-cni" = {
      # Turns on the network policy agent so NetworkPolicy objects are enforced.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    "kube-proxy"             = { configuration_values = null }
    "eks-pod-identity-agent" = { configuration_values = null }
  }

  # Deployments - these need running nodes to become healthy.
  addons_after_nodes = {
    "coredns"            = { configuration_values = null }
    "aws-ebs-csi-driver" = { configuration_values = null } # PersistentVolumes on EBS (Prometheus, Grafana)
  }
}

data "aws_eks_addon_version" "this" {
  for_each = merge(local.addons_before_nodes, local.addons_after_nodes)

  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = false # false = AWS's default (well-tested) version, not the newest
}

resource "aws_eks_addon" "before_nodes" {
  for_each = local.addons_before_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "after_nodes" {
  for_each = local.addons_after_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.default,
    # The EBS CSI controller must find its IAM role when its pods first start.
    aws_eks_pod_identity_association.this,
  ]
}
