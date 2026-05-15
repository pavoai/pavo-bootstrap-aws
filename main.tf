data "aws_caller_identity" "current" {}

# ============================================================================
# Workload permission boundary — driven by policy-statements.json (single
# source of truth, also surfaced into spec/spec-aws-byoc.yaml by CI).
# ============================================================================
locals {
  policy_statements = jsondecode(file("${path.module}/policy-statements.json"))
}

data "aws_iam_policy_document" "pavo_permission_boundary" {
  dynamic "statement" {
    for_each = local.policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = flatten([
          for test_name, vars in lookup(statement.value, "conditions", {}) :
          [for var_name, vals in vars : {
            test     = test_name
            variable = var_name
            values   = tolist(flatten([vals]))
          }]
        ])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "pavo_permission_boundary" {
  name        = "pavo-permission-boundary-${var.instance_id}"
  description = "Permission boundary for Pavo workload IAM roles. Source: policy-statements.json."
  policy      = data.aws_iam_policy_document.pavo_permission_boundary.json
}

# ============================================================================
# ESO IRSA role (assumed by the external-secrets ServiceAccount in EKS)
# ============================================================================
data "aws_iam_policy_document" "pavo_eso_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role" "pavo_eso" {
  name                 = "pavo-eso-${var.instance_id}"
  assume_role_policy   = data.aws_iam_policy_document.pavo_eso_trust.json
  permissions_boundary = aws_iam_policy.pavo_permission_boundary.arn
}

data "aws_iam_policy_document" "pavo_eso_permissions" {
  # Read the RDS-managed master user secret + any pavo-* secrets.
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:pavo-*",
    ]
  }

  # Decrypt the customer's CMK when SecretsManager invokes it on our behalf.
  # Without this, GetSecretValue on a CMK-encrypted RDS-managed secret returns
  # AccessDeniedException at the KMS layer. kms:ViaService scopes the use to
  # the SecretsManager service principal — ESO can't call kms:Decrypt directly.
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pavo_eso" {
  name   = "pavo-eso-policy-${var.instance_id}"
  role   = aws_iam_role.pavo_eso.id
  policy = data.aws_iam_policy_document.pavo_eso_permissions.json
}

# ============================================================================
# SSM params — integration "API" between bootstrap and workload modules.
# The workload module reads these values rather than receiving them via
# Terraform variables (which would require Pavo-side wiring through Omnistrate).
# ============================================================================
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/pavo/${var.instance_id}/vpc_id"
  type  = "String"
  value = var.vpc_id
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/pavo/${var.instance_id}/private_subnet_ids"
  type  = "StringList"
  value = join(",", var.private_subnet_ids)
}

resource "aws_ssm_parameter" "eks_cluster_name" {
  name  = "/pavo/${var.instance_id}/eks_cluster_name"
  type  = "String"
  value = var.eks_cluster_name
}

resource "aws_ssm_parameter" "eks_oidc_provider" {
  name  = "/pavo/${var.instance_id}/eks_oidc_provider"
  type  = "String"
  value = var.eks_oidc_provider
}

resource "aws_ssm_parameter" "eso_role_arn" {
  name  = "/pavo/${var.instance_id}/eso_role_arn"
  type  = "String"
  value = aws_iam_role.pavo_eso.arn
}

resource "aws_ssm_parameter" "permission_boundary_arn" {
  name  = "/pavo/${var.instance_id}/permission_boundary_arn"
  type  = "String"
  value = aws_iam_policy.pavo_permission_boundary.arn
}

# ============================================================================
# EBS CSI driver permission boundary — separate from the workload boundary.
# Mirrors AmazonEBSCSIDriverPolicy. Permission boundaries are intersection
# caps, so attaching the workload boundary to the EBS CSI role would silently
# block ec2:CreateVolume / Attach / Detach / Delete / snapshot operations.
# ============================================================================
locals {
  ebs_csi_policy_statements = jsondecode(file("${path.module}/ebs-csi-policy-statements.json"))
}

data "aws_iam_policy_document" "pavo_ebs_csi_permission_boundary" {
  dynamic "statement" {
    for_each = local.ebs_csi_policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = flatten([
          for test_name, vars in lookup(statement.value, "conditions", {}) :
          [for var_name, vals in vars : {
            test     = test_name
            variable = var_name
            values   = tolist(flatten([vals]))
          }]
        ])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "pavo_ebs_csi_permission_boundary" {
  # Naming matches the IAMCreateRolesOnlyWithBoundary ArnLike pattern
  # (arn:aws:iam::*:policy/pavo-permission-boundary-*) so the boundary-
  # enforcement condition still allows roles created with this boundary.
  name        = "pavo-permission-boundary-ebs-csi-${var.instance_id}"
  description = "Permission boundary for the Pavo EBS CSI driver IRSA role. Source: ebs-csi-policy-statements.json (mirrors AmazonEBSCSIDriverPolicy v14)."
  policy      = data.aws_iam_policy_document.pavo_ebs_csi_permission_boundary.json
}

resource "aws_ssm_parameter" "ebs_csi_permission_boundary_arn" {
  name  = "/pavo/${var.instance_id}/ebs_csi_permission_boundary_arn"
  type  = "String"
  value = aws_iam_policy.pavo_ebs_csi_permission_boundary.arn
}
