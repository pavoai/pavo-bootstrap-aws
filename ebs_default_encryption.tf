# Account EBS default key = cell CMK, so volumes created without an explicit key
# land on it: Omnistrate's node launch templates (Encrypted, no KmsKeyId) and the
# keyless gp3 StorageClass. Account+region wide; safe under one cell per account.
# Existing volumes keep their key until the nodes / PVCs are replaced.

locals {
  ebs_default_cmk_count = var.cell_kms_key_arn != "" ? 1 : 0

  # Node launches run as these service-linked roles (CloudTrail RunInstances /
  # CreateFleet); neither can use a customer key without a grant.
  ebs_node_launch_roles = {
    autoscaling   = "aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
    eks_nodegroup = "aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"
  }
}

resource "aws_kms_grant" "ebs_node_launch" {
  for_each          = local.ebs_default_cmk_count == 1 ? local.ebs_node_launch_roles : {}
  name              = "pavo-ebs-${each.key}"
  key_id            = var.cell_kms_key_arn
  grantee_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${each.value}"
  operations = [
    "Encrypt", "Decrypt", "ReEncryptFrom", "ReEncryptTo",
    "GenerateDataKey", "GenerateDataKeyWithoutPlaintext", "DescribeKey", "CreateGrant",
  ]
}

resource "aws_ebs_encryption_by_default" "this" {
  count   = local.ebs_default_cmk_count
  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  count   = local.ebs_default_cmk_count
  key_arn = var.cell_kms_key_arn

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws[a-z-]*:kms:[^:]+:[0-9]{12}:key/", var.cell_kms_key_arn))
      error_message = "cell_kms_key_arn must be a KMS key ARN (…:key/<id>), not an alias, for the EBS default key and its grants."
    }
  }

  # Grants first, or the next node launch fails on the key.
  depends_on = [aws_kms_grant.ebs_node_launch]
}
