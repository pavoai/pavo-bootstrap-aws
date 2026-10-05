# Account-scoped opt-in ceilings for per-instance MicroVM image publishing.
# These are deliberately separate from the application workload boundary: app
# pods never need image-write or Lambda build-role permissions.

# Once advertised to instances, account prerequisites survive default/false
# inputs. Removing attached boundaries is not a safe feature-toggle operation.
# This read is deliberately independent of the resources it protects.
data "aws_ssm_parameters_by_path" "microvm_bootstrap" {
  path            = "/pavo/shared"
  recursive       = false
  with_decryption = false

  lifecycle {
    postcondition {
      condition = var.enable_microvm_image_builds || length(setintersection(
        toset(self.names), local.microvm_boundary_marker_names,
      )) != 1
      error_message = "MicroVM bootstrap readiness is incomplete: only one boundary marker exists. Keep the existing bootstrap state, set enable_microvm_image_builds = true, and re-apply to reconcile both boundaries and SSM markers. Do not remove markers or detach live instance permission boundaries to disable the feature."
    }
  }
}

locals {
  microvm_boundary_marker_names = toset([
    "/pavo/shared/microvm_publisher_boundary_arn",
    "/pavo/shared/microvm_build_boundary_arn",
  ])
  microvm_builds_enabled = var.enable_microvm_image_builds || length(setintersection(
    toset(data.aws_ssm_parameters_by_path.microvm_bootstrap.names), local.microvm_boundary_marker_names,
  )) > 0
  microvm_builds_count = local.microvm_builds_enabled ? 1 : 0
}

data "aws_iam_policy_document" "microvm_publisher_boundary" {
  count = local.microvm_builds_count

  statement {
    sid    = "PublishArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::pavo-microvm-*",
      "arn:aws:s3:::pavo-microvm-*/*",
    ]
  }

  statement {
    sid       = "EncryptArtifacts"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.*.amazonaws.com"]
    }
  }

  # CreateMicrovmImage is not resource-scopable. Keep it separate so the
  # image-read actions remain limited to Pavo-owned image names.
  statement {
    sid       = "CreateMicrovmImage"
    effect    = "Allow"
    actions   = ["lambda:CreateMicrovmImage"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  # CreateMicrovmImage with provenance tags checks TagResource against "*"
  # before the image exists. Exclude every named Lambda resource so this grant
  # cannot retag an existing image, function, or network connector.
  statement {
    sid           = "TagOnCreateOnly"
    effect        = "Allow"
    actions       = ["lambda:TagResource"]
    not_resources = ["arn:aws:lambda:*:*:*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["source_digest"]
    }
    condition {
      test     = "Null"
      variable = "aws:TagKeys"
      values   = ["false"]
    }
  }

  # Image creation implicitly attaches AWS's INTERNET_EGRESS connector.
  # PassNetworkConnector is not resource-scopable; cap it to this cell's region.
  statement {
    sid       = "PassImageNetworkConnector"
    effect    = "Allow"
    actions   = ["lambda:PassNetworkConnector"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  statement {
    sid    = "ReadMicrovmImages"
    effect = "Allow"
    actions = [
      "lambda:GetMicrovmImage",
      "lambda:GetMicrovmImageVersion", "lambda:ListMicrovmImageVersions",
    ]
    resources = ["arn:aws:lambda:*:${data.aws_caller_identity.current.account_id}:microvm-image:pavo-microvm-*"]
  }

  statement {
    sid       = "DiscoverManagedImages"
    effect    = "Allow"
    actions   = ["lambda:ListManagedMicrovmImages"]
    resources = ["*"]
  }

  statement {
    sid       = "PassMicrovmBuildRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/pavo-microvm-build-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "microvm_build_boundary" {
  count = local.microvm_builds_count

  statement {
    sid       = "ReadBuildArtifact"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::pavo-microvm-*/*"]
  }

  statement {
    sid    = "DecryptBuildArtifact"
    effect = "Allow"
    actions = [
      "kms:Decrypt", "kms:DescribeKey",
    ]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.current.account_id}:key/*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["s3.*.amazonaws.com"]
    }
  }

  statement {
    sid       = "CreateBuildLogGroups"
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup"]
    resources = ["arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda-microvms/pavo-microvm-*"]
  }

  statement {
    sid    = "WriteBuildLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream", "logs:PutLogEvents",
    ]
    # IAM simulation currently returns implicitDeny for these documented
    # log-stream ARNs. Keep the least-privilege resource shape required by the
    # CloudWatch Logs authorization reference and resolve the discrepancy with
    # an actual Dev image build before rollout.
    resources = ["arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda-microvms/pavo-microvm-*:log-stream:*"]
  }
}

resource "aws_iam_policy" "microvm_publisher_boundary" {
  count       = local.microvm_builds_count
  name        = "pavo-permission-boundary-microvm-publisher"
  description = "Boundary for per-instance Pavo MicroVM publisher roles."
  policy      = data.aws_iam_policy_document.microvm_publisher_boundary[0].json
  depends_on  = [aws_ssm_parameter.single_cell_guard]

  lifecycle { prevent_destroy = true }
}

resource "aws_iam_policy" "microvm_build_boundary" {
  count       = local.microvm_builds_count
  name        = "pavo-permission-boundary-microvm-build"
  description = "Boundary for Lambda MicroVM image build roles."
  policy      = data.aws_iam_policy_document.microvm_build_boundary[0].json
  depends_on  = [aws_ssm_parameter.single_cell_guard]

  lifecycle { prevent_destroy = true }
}

resource "aws_ssm_parameter" "microvm_publisher_boundary_arn" {
  count = local.microvm_builds_count
  name  = "/pavo/shared/microvm_publisher_boundary_arn"
  type  = "String"
  value = aws_iam_policy.microvm_publisher_boundary[0].arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "microvm_build_boundary_arn" {
  count = local.microvm_builds_count
  name  = "/pavo/shared/microvm_build_boundary_arn"
  type  = "String"
  value = aws_iam_policy.microvm_build_boundary[0].arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}
