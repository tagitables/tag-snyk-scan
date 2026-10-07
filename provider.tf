provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "tag-snyk-scan"
      ManagedBy = "Terraform"
    }
  }
}
