locals {
  public_subnets  = zipmap(var.azs, var.public_subnet_cidrs)
  private_subnets = zipmap(var.azs, var.private_subnet_cidrs)

  # AZs that get a NAT gateway (and their own private route table).
  nat_azs = var.single_nat_gateway ? [var.azs[0]] : var.azs
}

# VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = length(var.public_subnet_cidrs) == length(var.azs) && length(var.private_subnet_cidrs) == length(var.azs)
      error_message = "public_subnet_cidrs and private_subnet_cidrs must each have one entry per AZ in var.azs."
    }
  }
}

# Internet GW
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

# Subnets
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(var.tags, var.public_subnet_tags, {
    Name = "${var.name}-public-${index(var.azs, each.key) + 1}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(var.tags, var.private_subnet_tags, {
    Name = "${var.name}-private-${index(var.azs, each.key) + 1}"
    Tier = "private"
  })
}

# Public routing: 0.0.0.0/0 -> internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# NAT gateway(s), placed in public subnets
resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# Private routing: 0.0.0.0/0 -> NAT gateway (outbound only, for patches/updates)
resource "aws_route_table" "private" {
  for_each = toset(local.nat_azs)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = var.single_nat_gateway ? "${var.name}-private" : "${var.name}-private-${each.key}"
  })
}

resource "aws_route" "private_nat" {
  for_each = toset(local.nat_azs)

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? var.azs[0] : each.key].id
}
