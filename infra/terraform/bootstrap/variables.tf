variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  description = "Short name used as a prefix for resource names and tags."
  type        = string
  default     = "devops-lab"
}
