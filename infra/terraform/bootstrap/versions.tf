terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Chicken-and-egg: this stack creates the state bucket, so its own state
  # stays local (terraform.tfstate in this folder). It's tiny and rarely
  # changes - back it up, but don't commit it.
}
