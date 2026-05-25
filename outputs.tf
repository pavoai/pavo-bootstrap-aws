output "eso_role_arn" {
  description = "ARN of the ESO IRSA role. Use this when attaching the customer CMK key policy (statement 5: AllowESORoleDecryptViaSecretsManager)."
  value       = aws_iam_role.pavo_eso.arn
}

output "permission_boundary_arn" {
  description = "ARN of the workload IAM permission boundary (attached to pavo-role-*)."
  value       = aws_iam_policy.pavo_permission_boundary.arn
}

output "ebs_csi_permission_boundary_arn" {
  description = "ARN of the EBS CSI driver permission boundary (attached to pavo-ebs-csi-*)."
  value       = aws_iam_policy.pavo_ebs_csi_permission_boundary.arn
}

output "ssm_shared_prefix" {
  description = "SSM Parameter Store prefix for account-scoped bootstrap state (permission boundaries)."
  value       = "/pavo/shared"
}

output "ssm_cell_prefix" {
  description = "SSM Parameter Store prefix for cell-scoped bootstrap state (VPC/subnets/OIDC, ESO role ARN)."
  value       = "/pavo/cells/${var.eks_cluster_name}"
}
