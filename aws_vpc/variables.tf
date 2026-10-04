variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "main"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many AZs (taken from the region's available AZs) to spread subnets across."
  type        = number
  default     = 3
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "single_nat_gateway" {
  description = "Set to false for one NAT gateway per AZ (HA egress, higher cost)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
