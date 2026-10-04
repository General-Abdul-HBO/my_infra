terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }

  # Remote state. Uncomment AFTER infra/terraform/bootstrap has been applied,
  # then run: terraform init -migrate-state -backend-config=../infra/terraform/backend.hcl
  # (bucket/region/locking come from backend.hcl; only the key is set here).
  backend "s3" {
    key = "vpc/terraform.tfstate"
  }
}
