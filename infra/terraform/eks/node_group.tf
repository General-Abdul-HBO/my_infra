# ---------------------------------------------------------------------------
# IAM role for the worker nodes (EC2 instances)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",          # join the cluster
    "AmazonEKS_CNI_Policy",               # VPC CNI assigns VPC IPs to pods
    "AmazonEC2ContainerRegistryPullOnly", # pull images from ECR
    "AmazonSSMManagedInstanceCore",       # shell into nodes with SSM - no SSH keys
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# Launch template: encrypted gp3 root disk, IMDSv2 enforced, Name tag.
# No AMI is set, so EKS picks the right EKS-optimized AL2023 image.
# ---------------------------------------------------------------------------
resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.cluster_name}-nodes-"
  update_default_version = true

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 2 lets pods reach the instance metadata service. Hardening step for
    # later: set this to 1 so pods can't borrow the node's IAM role (our
    # controllers use Pod Identity, so they don't need it).
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

# ---------------------------------------------------------------------------
# Managed node group - PRIVATE subnets only. Nodes have no public IPs; they
# reach the internet (image pulls, OS patches) through the NAT gateway.
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private.ids

  # Nodes follow the control plane: on a version upgrade Terraform upgrades
  # the cluster first, then rolls the nodes onto the matching AMI.
  version = aws_eks_cluster.this.version

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Rolling updates (new AMI, new launch template) replace one node at a time.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  labels = {
    "node-group" = "default"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    # CNI + kube-proxy + pod identity agent should be in place before nodes join.
    aws_eks_addon.before_nodes,
  ]
}
