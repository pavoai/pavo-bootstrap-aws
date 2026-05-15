variable "aws_region" {
  description = "AWS region where the Pavo deployment lives."
  type        = string
}

variable "instance_id" {
  description = "Pavo deployment instance ID (matches Omnistrate's sys.id). Used in: K8s namespace, IAM role/policy names (pavo-*-<instance_id>), ClusterSecretStore name, SSM parameter paths. Constrained to satisfy the intersection of K8s namespace + IAM role name rules: lowercase alphanumeric + hyphens, no leading/trailing hyphen, max 40 characters (leaves headroom for the longest derived name 'pavo-permission-boundary-<instance_id>' which must fit in IAM's 64-char role-name limit)."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.instance_id))
      && length(var.instance_id) <= 40
    )
    error_message = "instance_id must be 1-40 characters, lowercase alphanumeric and hyphens only, and must not start or end with a hyphen."
  }
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
