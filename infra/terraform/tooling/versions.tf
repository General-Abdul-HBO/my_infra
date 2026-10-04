terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  # bucket/region/locking come from ../backend.hcl:
  #   terraform init -backend-config=../backend.hcl
  backend "s3" {
    key = "tooling/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "tooling"
      ManagedBy = "terraform"
    }
  }
}
