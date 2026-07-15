variable "aws_region" {
  description = "AWS region where the Pavo deployment lives."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster runs (Omnistrate-provisioned)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (Omnistrate-tagged kubernetes.io/role/internal-elb=1)."
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name (Omnistrate-provisioned)."
  type        = string
}

variable "eks_oidc_provider" {
  description = "EKS OIDC issuer URL without https:// prefix (e.g., oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE)."
  type        = string

  validation {
    # The IRSA/OIDC wiring downstream concatenates this with `arn:aws:iam::<acct>:oidc-provider/`,
    # so a `https://` prefix on input produces a malformed ARN and fails only at apply time.
    # Catch it at the module boundary.
    condition     = length(var.eks_oidc_provider) > 0 && !startswith(var.eks_oidc_provider, "https://") && !startswith(var.eks_oidc_provider, "http://")
    error_message = "eks_oidc_provider must be the issuer host/path without the https:// or http:// prefix."
  }
}

variable "runner_role_arn" {
  description = "IAM role ARN of the Omnistrate Terraform runner principal that needs cluster-admin RBAC on this EKS cluster. MUST be the underlying role ARN (arn:aws:iam::<acct>:role/<RoleName>), NOT an assumed-role session ARN. See README → 'Onboarding a new AWS BYOC cell' for how to obtain it."
  type        = string

  validation {
    # Reject assumed-role session ARNs — they look like
    #   arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>
    # and they're a common mistake when copying from `aws sts get-caller-identity`.
    # AWS access entries need the underlying role ARN, not the assumed session.
    condition = (
      length(var.runner_role_arn) > 0 &&
      startswith(var.runner_role_arn, "arn:aws:iam::") &&
      length(regexall("[:/]assumed-role/", var.runner_role_arn)) == 0
    )
    error_message = "runner_role_arn must be an IAM role ARN (arn:aws:iam::<acct>:role/<RoleName>), not an assumed-role session ARN. Use `aws iam list-roles` to find the role, or strip the trailing `/<session>` and replace `:sts::<acct>:assumed-role/` with `:iam::<acct>:role/`."
  }
}

# -----------------------------------------------------------------------------
# Sigstore Policy Controller (cell-scoped, single owner per EKS cluster)
# -----------------------------------------------------------------------------
# The policy controller chart, its CRDs (ClusterImagePolicy), and the per-service
# ClusterImagePolicy objects are cluster-scoped — they belong in cell bootstrap,
# NOT per-instance pavoInfra. See README → "Sigstore policy controller" for the
# ownership model and the image-manifest.json that drives the per-service CIPs.

variable "image_policy_mode" {
  description = <<-EOT
    Sigstore ClusterImagePolicy enforcement mode for ghcr.io/pavoai/** images.
    - "enforce" (default): reject admission of images that fail verification.
    - "warn":              admit images that fail verification, emit Warning to
                           admission caller (and controller log entry). Reserved
                           for one-off signing-bake-in on a fresh image lineup.
    The policy verifies: cosign signature + CycloneDX SBOM attestation presence +
    cosign-vuln attestation presence. Attestation CONTENT is not inspected — CVE
    gating happens in central-ci's signing pipeline.
  EOT
  type        = string
  default     = "enforce"
  validation {
    condition     = contains(["warn", "enforce"], var.image_policy_mode)
    error_message = "image_policy_mode must be \"warn\" or \"enforce\"."
  }
}

variable "policy_controller_chart_version" {
  description = <<-EOT
    Helm chart version for sigstore/policy-controller. Bump deliberately and
    test in DEV warn mode first — chart upgrades can change webhook config
    paths or CRD API versions.
  EOT
  type        = string
  default     = "0.10.6"
}

variable "central_ci_project_id" {
  description = <<-EOT
    GCP project that hosts Pavo's central Cloud Build (the one that builds
    and signs all ghcr.io/pavoai/* images). The per-service signing SAs live
    here: cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com.
    Provisioned by central-ci/ in this repo. Default matches today's
    onboarding-455713 project. Pavo images are built in GCP regardless of
    which cloud the customer deploys to, so this is still a GCP project ID
    even in the AWS BYOC cell-bootstrap module.
  EOT
  type        = string
  default     = "onboarding-455713"
}

variable "enable_eck" {
  description = <<-EOT
    Install the Elastic Cloud on Kubernetes (ECK) operator on this cell. Required
    for customers running self-hosted Elasticsearch in-VPC (hosting_mode = self_hosted
    in the per-instance module). Unnecessary on cells with only Elastic-Cloud
    (hosting_mode = cloud) instances — an idle operator, CRDs, and validating
    webhook add avoidable surface — so it is opt-in per cell and DEFAULTS OFF.
    Set true on any cell that will host a self_hosted-Elasticsearch instance. When
    true, the cell publishes /pavo/cells/<eks_cluster_name>/eck_ready=true, which
    the per-instance module reads and fails-fast on if a self_hosted instance is
    created before ECK exists.
  EOT
  type        = bool
  default     = false
}

variable "eck_operator_chart_version" {
  description = <<-EOT
    Helm chart version for elastic/eck-operator. Operator and CRDs move in
    lockstep with this chart. Confirm the ECK <-> Elasticsearch version support
    matrix before bumping (ECK 3.x supports the 8.x and 9.x stacks).
  EOT
  type        = string
  default     = "3.4.0"
}
