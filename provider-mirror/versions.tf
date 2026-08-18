# =============================================================================
# GENERATED FILE — DO NOT EDIT BY HAND.
# =============================================================================
# The required_providers of the AWS workload module (terraform-omnistrate-aws),
# extracted so pavo-bootstrap-aws/scripts/populate-provider-mirror.sh can build the
# in-account OpenTofu provider mirror (provider_mirror.tf) WITHOUT the workload repo.
#
# This is NOT part of the pavo-bootstrap-aws root module — it is a standalone config
# used only by `tofu providers mirror`, so the bootstrap apply's own provider set is
# unaffected.
#
# No .terraform.lock.hcl is committed here (nor does the workload module commit one).
# populate resolves the newest release satisfying each constraint below, and a
# lock-less cell likewise installs newest-satisfying-in-mirror — so the mirror always
# holds a version the cell can select. This matches scripts/build-provider-mirror.sh.
#
# Regenerate with:  python3 scripts/render-mirror-providers.py
# CI (check-policy-drift) fails if this file drifts from terraform-omnistrate-aws/
# providers.tf, so the customer mirror can never silently miss a provider the AWS
# workload installs. Change providers in terraform-omnistrate-aws/providers.tf, not here.
# =============================================================================

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.33.0, < 6.0"
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
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.15"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
