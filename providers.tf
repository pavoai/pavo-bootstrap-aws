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

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# Kubernetes / Helm / kubectl providers — exec auth against the cell's EKS cluster
# -----------------------------------------------------------------------------
# Bootstrap is operator-applied (NOT Omnistrate-runner-applied), so AWS creds
# come from the operator's local CLI (e.g., `aws sso login`). The same
# `aws eks get-token` exec-auth pattern used in `terraform-omnistrate-aws`
# works locally — `aws` CLI must be on PATH.
#
# Preflight (scripts/preflight.sh) verifies aws/kubectl/helm CLIs are present
# AND the operator's principal has the K8s permissions bootstrap needs.
# -----------------------------------------------------------------------------

data "aws_eks_cluster" "primary" {
  name = var.eks_cluster_name
}

locals {
  eks_exec_api_version = "client.authentication.k8s.io/v1beta1"
  eks_exec_command     = "aws"
  eks_exec_args = [
    "eks", "get-token",
    "--cluster-name", var.eks_cluster_name,
    "--region", var.aws_region,
    "--output", "json",
  ]
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
