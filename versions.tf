terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    bucket  = "sctp-tfstate-ce13"
    key     = "tag/3.6-snyk-scan/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}