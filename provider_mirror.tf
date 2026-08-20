# =============================================================================
# In-account OpenTofu provider mirror (BYOC)
# =============================================================================
# A private per-cell S3 bucket in the customer's own account that serves the
# OpenTofu provider plugins to this cell's tf-executor over the S3 gateway
# endpoint. This resource only PROVISIONS the bucket; a companion spec change
# (cliConfigFileOverride, separate PR) activates consumption by pointing every AWS
# cell's network_mirror at it, with NO registry fallback. Once that wiring lands:
#   - every AWS cell installs providers from its in-account mirror (a strict,
#     default-deny cell therefore needs no registry egress at all), and
#   - the bucket must be POPULATED before a cell's next terraform apply, or that
#     apply fails. Populate with scripts/populate-provider-mirror.sh
#     (tofu providers mirror -> aws s3 sync s3://<bucket>/providers), and re-run it
#     whenever a provider version bumps. (Pavo-run cells can instead use the
#     monorepo's scripts/build-provider-mirror.sh, which reads the workload locks.)
#
# Created unconditionally (no gating flag): because the mirror is authoritative
# with no fallback, a cell without this bucket would fail terraform, so it is not
# something to opt out of per cell.

locals {
  provider_mirror_bucket = "pavo-tf-mirror-${var.eks_cluster_name}"
}

resource "aws_s3_bucket" "provider_mirror" {
  bucket = local.provider_mirror_bucket

  # The bucket name is eks_cluster_name-derived and must byte-match the spec's
  # network_mirror URL host (built from the raw $sys.deploymentCell.kubernetesClusterID),
  # so it cannot be sanitized here. EKS allows uppercase/underscores and up to 100
  # chars; a virtual-hosted S3 URL needs a 3-63 char lowercase alphanumeric/hyphen
  # name (no dots — they break the wildcard TLS cert). Fail fast with a clear
  # message if the cluster name yields an invalid name (Omnistrate cluster IDs are
  # already S3-safe, so this only guards against a misconfigured eks_cluster_name).
  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", local.provider_mirror_bucket))
      error_message = "Provider-mirror bucket name '${local.provider_mirror_bucket}' is invalid: eks_cluster_name must be lowercase, hyphen-only (no dots/underscores), and yield a 3-63 character bucket name."
    }
  }

  tags = {
    managed-by = "omnistrate"
    purpose    = "byoc-tf-provider-mirror"
  }
}

# SSE-S3 (AES256), deliberately NOT the cell CMK: the objects are public provider
# plugins (no secrets), and OpenTofu fetches the archives anonymously (it never
# signs archive requests), so a CMK would break reads by requiring kms:Decrypt.
resource "aws_s3_bucket_server_side_encryption_configuration" "provider_mirror" {
  bucket = aws_s3_bucket.provider_mirror.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block Public Access stays fully ON. The read policy below is conditioned on
# aws:SourceVpc, which S3 evaluates as NON-public, so BlockPublicPolicy /
# RestrictPublicBuckets still permit it while ACL-based public access is blocked.
resource "aws_s3_bucket_public_access_block" "provider_mirror" {
  bucket = aws_s3_bucket.provider_mirror.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Anonymous read, but ONLY for requests arriving from this cell's VPC (via the S3
# gateway endpoint). OpenTofu's network mirror fetches provider archives without
# credentials, so the objects must be anonymously GET-able; the aws:SourceVpc
# condition keeps that access private to the cell and off the public internet.
# Non-TLS access is denied (network_mirror uses https).
resource "aws_s3_bucket_policy" "provider_mirror" {
  bucket = aws_s3_bucket.provider_mirror.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowVpcScopedAnonymousRead"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.provider_mirror.arn}/*"
        Condition = {
          StringEquals = { "aws:SourceVpc" = var.vpc_id }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.provider_mirror.arn,
          "${aws_s3_bucket.provider_mirror.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  # Set the public-access block first so the VPC-scoped policy applies cleanly.
  depends_on = [aws_s3_bucket_public_access_block.provider_mirror]
}

output "provider_mirror_bucket" {
  description = "In-account OpenTofu provider mirror bucket. Populate with scripts/populate-provider-mirror.sh before the cell's next terraform apply."
  value       = aws_s3_bucket.provider_mirror.bucket
}

output "provider_mirror_network_mirror_url" {
  description = "network_mirror base URL wired into the spec cliConfigFileOverride."
  value       = "https://${aws_s3_bucket.provider_mirror.bucket}.s3.${data.aws_region.current.name}.amazonaws.com/providers/"
}
