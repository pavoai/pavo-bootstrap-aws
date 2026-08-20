terraform {
  required_version = ">= 1.5"

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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.2.0, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS provider is CALLER-OWNED (standard composable-module pattern)
# -----------------------------------------------------------------------------
# This module declares only `required_providers` (terraform block above) and
# instantiates NO `provider "aws"` block, so it inherits the caller's default aws
# provider. Callers own region / credentials / assume_role in their root. Region
# is read back from that injected provider (data.aws_region.current), so the module
# is never a second region authority. Applying the module directly as a root uses
# an implicit aws provider whose region comes from AWS_REGION in the environment.
# -----------------------------------------------------------------------------
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Kubernetes / Helm / kubectl providers — exec auth against the cell's EKS cluster
# -----------------------------------------------------------------------------
# These authenticate with `aws eks get-token`, a subprocess reading the run's
# AMBIENT AWS credentials (NOT the Terraform AWS provider's assume_role). When the
# ambient creds are in a different account than the cell (e.g. a central Atlantis/
# CI account that assumes into the cell only at the provider level), set
# var.k8s_get_token_role_arn so the token call assumes the cell role too. Empty =
# ambient creds directly. `aws` CLI must be on PATH.
# -----------------------------------------------------------------------------

data "aws_eks_cluster" "primary" {
  name = var.eks_cluster_name

  lifecycle {
    # The injected AWS provider must point at the cell account. runner_role_arn is
    # the deterministic anchor (the Omnistrate runner role lives in the cell
    # account); the named-cluster read is only a soft backstop because cluster
    # names are not globally unique.
    precondition {
      condition     = local.runner_role_account_id == local.provider_account_id
      error_message = "The injected AWS provider must target the same AWS account as runner_role_arn (the Omnistrate runner role lives in the cell account). The caller's provider appears to be pointed at the wrong account."
    }
    precondition {
      condition     = var.k8s_get_token_role_arn == "" || local.k8s_auth_account_id == local.provider_account_id
      error_message = "k8s_get_token_role_arn must target the same AWS account as the injected AWS provider."
    }
    precondition {
      condition     = var.k8s_get_token_role_arn == "" || var.k8s_get_token_role_arn != var.runner_role_arn
      error_message = "k8s_get_token_role_arn must differ from runner_role_arn; the module already owns the EKS access entry for runner_role_arn, so reusing it as the exec principal creates a bootstrap/duplicate-ownership conflict."
    }
  }
}

locals {
  provider_account_id    = data.aws_caller_identity.current.account_id
  runner_role_account_id = try(split(":", var.runner_role_arn)[4], "")
  k8s_auth_account_id    = var.k8s_get_token_role_arn == "" ? "" : try(split(":", var.k8s_get_token_role_arn)[4], "")

  eks_exec_api_version = "client.authentication.k8s.io/v1beta1"
  eks_exec_command     = "aws"
  # Region comes from the injected provider. --role-arn is appended only for
  # cross-account runs (ambient creds in a different account than the cell).
  eks_exec_args = concat(
    ["eks", "get-token", "--cluster-name", var.eks_cluster_name, "--region", data.aws_region.current.name, "--output", "json"],
    var.k8s_get_token_role_arn != "" ? ["--role-arn", var.k8s_get_token_role_arn] : [],
  )
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.primary.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)

  exec {
    api_version = local.eks_exec_api_version
    command     = local.eks_exec_command
    args        = local.eks_exec_args
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.primary.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = local.eks_exec_api_version
    command     = local.eks_exec_command
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.primary.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.primary.certificate_authority[0].data)

    exec {
      api_version = local.eks_exec_api_version
      command     = local.eks_exec_command
      args        = local.eks_exec_args
    }
  }
}
