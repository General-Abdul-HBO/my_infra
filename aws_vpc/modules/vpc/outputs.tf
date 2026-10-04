output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  value = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the same order as var.azs."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in the same order as var.azs."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}

output "private_route_table_ids" {
  value = [for az in local.nat_azs : aws_route_table.private[az].id]
}

output "nat_gateway_ids" {
  value = [for az in local.nat_azs : aws_nat_gateway.this[az].id]
}

output "nat_public_ips" {
  description = "Public IPs private-subnet traffic egresses from (useful for allow-listing)."
  value       = [for az in local.nat_azs : aws_eip.nat[az].public_ip]
}
