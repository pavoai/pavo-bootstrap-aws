# Child-module consumer fixture (aliased AWS provider on purpose).
#
# Purpose: prove that pavo-bootstrap-aws composes as a child module with a
# caller-injected, ALIASED aws provider — the path our own direct-root apply and
# a direct-root apply never exercise. Specifying a `providers` map cancels default-provider
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

  runner_role_arn            = "arn:aws:iam::123456789012:role/fixture-runner"
  cell_kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/example"
  observability_grafana_host = "fixture.example.com"
}
