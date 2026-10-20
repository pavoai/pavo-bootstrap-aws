# =============================================================================
# Cell-scoped Interface VPC endpoints
# -----------------------------------------------------------------------------
# These AWS APIs are needed *before* the first instance tofu plan on a
# private / no-NAT cell. Instance refresh calls them while reading existing
# state; without PrivateLink (and with no NAT) that refresh times out.
#
#   kms                  — data.aws_kms_key.cell_cmk (DescribeKey)
#   secretsmanager       — ESO / RDS master-password refresh
#   iam                  — CreateRole / IRSA / permission-boundary attach
#   rds                  — DescribeDBSubnetGroups / existing postgres
#   elasticache          — DescribeCacheSubnetGroups
#   sns / sqs            — existing topics and DLQs
#   elasticfilesystem    — existing EFS file system
#   email                — SES v2 GetEmailIdentity
#
# Instance tofu (terraform-omnistrate-aws/vpc_endpoints.tf) still lists them
# and will skip when a foreign private-DNS endpoint already exists. Name these
# with the cluster, not an instance id (`pavo-vpce-<svc>-<eks_cluster_name>`),
# so the instance skip treats them as foreign and does not destroy them.
#
# REUSE — same live-describe rule as the instance module. hashicorp/aws 5.x
# has no plural aws_vpc_endpoints, so we list VPCE ENIs and look each one up.
# Skip a service only when a *foreign* private-DNS Interface VPCE exists
# (Name != pavo-vpce-<service>-<eks_cluster_name>). Our own named endpoints
# stay in for_each so a later apply does not destroy them.
#
# Workload-only endpoints (Bedrock runtime / control plane) stay on the
# instance module — they are not in existing state, so they do not block plan.
# =============================================================================

locals {
  vpc_interface_endpoint_services = concat(
    [
      "kms",
      "secretsmanager",
      "iam",
      "rds",
      "elasticache",
      "sns",
      "sqs",
      "elasticfilesystem",
      "email",
    ],
    # Opt-in connector endpoint (enable_sagemaker_api_endpoint): the Amazon
    # SageMaker API for the SageMaker connector on a strict cell. Workload-only,
    # unlike the list above, but kept here so every interface endpoint on the
    # cell follows one pattern (same reuse rule, naming and security group) and
    # two endpoints can never claim private DNS for the same service. Off by
    # default.
    var.enable_sagemaker_api_endpoint ? ["sagemaker.api"] : [],
  )

  vpc_endpoint_service_name = {
    for s in local.vpc_interface_endpoint_services :
    s => s == "iam" ? "com.amazonaws.iam" : "com.amazonaws.${data.aws_region.current.name}.${s}"
  }
}

data "aws_vpc" "interface_endpoints" {
  id = local.vpc_id
}

# Live Interface VPCEs in this VPC. Gateway endpoints have no ENIs.
data "aws_network_interfaces" "vpc_endpoint" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  filter {
    name   = "interface-type"
    values = ["vpc_endpoint"]
  }
}

data "aws_network_interface" "vpc_endpoint" {
  for_each = toset(data.aws_network_interfaces.vpc_endpoint.ids)
  id       = each.value
}

locals {
  existing_interface_vpce_ids = toset(compact([
    for eni in data.aws_network_interface.vpc_endpoint :
    try(regex("vpce-[a-z0-9]+", eni.description), "")
  ]))
}

data "aws_vpc_endpoint" "existing_interface" {
  for_each = local.existing_interface_vpce_ids
  id       = each.value
}

locals {
  existing_interface_service_key = {
    for id, ep in data.aws_vpc_endpoint.existing_interface :
    id => ep.service_name == "com.amazonaws.iam" ? "iam" : trimprefix(ep.service_name, "com.amazonaws.${data.aws_region.current.name}.")
  }

  foreign_private_dns_services = toset([
    for id, ep in data.aws_vpc_endpoint.existing_interface :
    local.existing_interface_service_key[id]
    if ep.vpc_endpoint_type == "Interface" && ep.state == "available" && ep.private_dns_enabled && try(ep.tags["Name"], "") != "pavo-vpce-${local.existing_interface_service_key[id]}-${local.eks_cluster_name}"
  ])

  vpc_interface_endpoints_to_create = setsubtract(
    toset(local.vpc_interface_endpoint_services),
    local.foreign_private_dns_services,
  )
}

# One subnet per AZ — interface endpoints permit at most one subnet per AZ.
data "aws_subnet" "interface_endpoint" {
  for_each = toset(local.private_subnet_ids)
  id       = each.value
}

locals {
  _interface_subnets_by_az = {
    for id, s in data.aws_subnet.interface_endpoint : s.availability_zone => id...
  }
  vpc_interface_endpoint_subnet_ids = [for az, ids in local._interface_subnets_by_az : ids[0]]
}

resource "aws_security_group" "vpc_interface_endpoints" {
  count       = length(local.vpc_interface_endpoints_to_create) > 0 ? 1 : 0
  name        = "pavo-vpce-sg-${local.eks_cluster_name}"
  description = "HTTPS from within the VPC to PrivateLink interface endpoints"
  vpc_id      = local.vpc_id

  # Every VPC CIDR block, primary and secondary: under the VPC CNI a pod's IP can
  # come from a secondary block, and such a pod must reach these endpoints too
  # (the strict egress NetworkPolicy allows the same set). The same list as the
  # primary block alone on a VPC with one CIDR, so nothing changes there.
  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = data.aws_vpc.interface_endpoints.cidr_block_associations[*].cidr_block
  }

  egress {
    description = "Return traffic within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = data.aws_vpc.interface_endpoints.cidr_block_associations[*].cidr_block
  }

  tags = {
    Name       = "pavo-vpce-sg-${local.eks_cluster_name}"
    managed_by = "pavo"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.vpc_interface_endpoints_to_create

  vpc_id              = local.vpc_id
  service_name        = local.vpc_endpoint_service_name[each.value]
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.vpc_interface_endpoint_subnet_ids
  security_group_ids  = [aws_security_group.vpc_interface_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name       = "pavo-vpce-${each.value}-${local.eks_cluster_name}"
    managed_by = "pavo"
    purpose    = "cell-interface"
  }
}
