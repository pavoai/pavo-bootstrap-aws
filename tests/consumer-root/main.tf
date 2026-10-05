# Child-module consumer fixture (aliased AWS provider on purpose).
#
# Purpose: prove that pavo-bootstrap-aws composes as a child module with a
# caller-injected, ALIASED aws provider — the path our own direct-root apply and
# awstest never exercise. Specifying a `providers` map cancels default-provider
# inheritance, so `terraform init && terraform validate` here is the authority on
# the COMPLETE required providers map a consumer must pass. If validate demands
# time/random (the module uses time_sleep + random_password without provider
# blocks), add them to the map below and to the consumer docs.
#
# Not applied — validate-only. Inputs are dummy values.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  alias  = "cell"
  region = "us-east-1"
}

module "bootstrap" {
  source = "../.."

  providers = {
    aws = aws.cell
  }

  vpc_id             = "vpc-0fixture000000000"
  private_subnet_ids = ["subnet-0fixture00000000", "subnet-0fixture00000001", "subnet-0fixture00000002"]
  eks_cluster_name   = "hc-fixture"
  eks_oidc_provider  = "oidc.eks.us-east-1.amazonaws.com/id/FIXTURE0000000000000000000000000"
  runner_role_arn    = "arn:aws:iam::123456789012:role/fixture-runner"
}
