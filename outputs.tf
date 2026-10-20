output "eso_role_arn" {
  description = "ARN of the ESO controller's cell IRSA role. Grants no secret read (see legacy_eso_cell_secret_read); per-instance pavo-eso-<instance_id> roles read each instance's secrets."
  value       = aws_iam_role.pavo_eso.arn
}

output "permission_boundary_arn" {
  description = "ARN of the workload IAM permission boundary (attached to pavo-role-*)."
  value       = aws_iam_policy.pavo_permission_boundary.arn
}

output "ssm_shared_prefix" {
  description = "SSM Parameter Store prefix for account-scoped bootstrap state (permission boundaries)."
  value       = "/pavo/shared"
}

output "ssm_cell_prefix" {
  description = "SSM Parameter Store prefix for cell-scoped bootstrap state (VPC/subnets/OIDC, ESO role ARN)."
  value       = "/pavo/cells/${local.eks_cluster_name}"
}

output "route53_vpc_endpoint_id" {
  description = "Cell Route53 interface VPCE id, or null unless network_posture is strict."
  value       = one(aws_vpc_endpoint.route53[*].id)
}

output "microvm_publisher_boundary_arn" {
  description = "Publisher permission boundary ARN, or null before managed builds have ever been enabled."
  value       = try(aws_iam_policy.microvm_publisher_boundary[0].arn, null)
}

output "microvm_build_boundary_arn" {
  description = "Lambda build-role permission boundary ARN, or null before managed builds have ever been enabled."
  value       = try(aws_iam_policy.microvm_build_boundary[0].arn, null)
}

output "vpc_interface_endpoint_ids" {
  description = "Cell-scoped Interface VPC endpoint IDs (kms / secretsmanager / iam / rds / elasticache / sns / sqs / elasticfilesystem / email), keyed by service. Empty when every service already has a foreign private-DNS endpoint."
  value       = { for svc, ep in aws_vpc_endpoint.interface : svc => ep.id }
}

output "snowflake_vpce_id" {
  description = "Snowflake PrivateLink interface endpoint ID, for the AWSVPCEID network rule in the customer's Snowflake account; null unless snowflake_privatelink is set."
  value       = try(aws_vpc_endpoint.snowflake[0].id, null)
}

output "snowflake_vpce_dns_name" {
  description = "Regional DNS name of the Snowflake PrivateLink interface endpoint, for the customer's own CNAME records when snowflake_privatelink.manage_dns is false; null unless the endpoint exists."
  value       = try(aws_vpc_endpoint.snowflake[0].dns_entry[0].dns_name, null)
}
