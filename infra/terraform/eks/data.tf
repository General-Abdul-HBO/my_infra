# Look up the VPC built by the aws_vpc stack by its Name tag, instead of
# reading that stack's state. The two stacks stay decoupled: all this one
# needs is "a VPC called main with subnets tagged Tier=private".
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
