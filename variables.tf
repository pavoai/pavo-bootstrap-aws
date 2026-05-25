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
