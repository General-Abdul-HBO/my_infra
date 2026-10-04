provider "aws" {
  region = var.aws_region

  # Every taggable AWS resource in this stack gets these tags automatically.
  default_tags {
    tags = {
      Project   = var.project
      Stack     = "eks"
      ManagedBy = "terraform"
    }
  }
}
