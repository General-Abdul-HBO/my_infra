variable "name" {
  description = "Name prefix applied to every resource (e.g. \"main\")."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across. Order matters: index N pairs with public_subnet_cidrs[N] and private_subnet_cidrs[N]."
  type        = list(string)

  validation {
    condition     = length(var.azs) > 0
    error_message = "At least one availability zone is required."
  }
}

variable "public_subnet_cidrs" {
  description = "One public subnet CIDR per AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One private subnet CIDR per AZ."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway in the first AZ shared by all private subnets (cheaper). false = one NAT gateway per AZ, so private subnets keep internet egress if a single AZ fails."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "Extra tags for public subnets only (e.g. kubernetes.io/role/elb = 1 so the AWS Load Balancer Controller can place internet-facing ALBs there)."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags for private subnets only (e.g. kubernetes.io/role/internal-elb = 1 for internal load balancers)."
  type        = map(string)
  default     = {}
}
