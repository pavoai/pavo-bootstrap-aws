terraform {
  required_version = ">= 1.0"

  # No backend block here. Add a separate `backend.tf` file with your chosen
  # backend BEFORE running `terraform init`. See README "Configuring Terraform
  # state" section for examples (S3 + DynamoDB recommended for AWS, or
  # Terraform Cloud, etc.).
  #
  # WARNING: without a backend block, `terraform init -backend-config=...` flags
  # are SILENTLY IGNORED and Terraform defaults to local state. This is standard
  # Terraform behaviour for partial backend configuration — not a Pavo choice.

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
