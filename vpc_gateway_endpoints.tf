# =============================================================================
# S3 / DynamoDB gateway endpoints for the node/pod route tables (ADAPTIVE)
# =============================================================================
# The EKS node/pod subnets sit on non-main route tables. For pod->S3/DynamoDB
# traffic to stay private in-VPC (so aws:SourceVpc is set and a strict
# default-deny cell with NAT blocked can still reach S3/DynamoDB), every such
# route table needs a gateway-endpoint route for the service.
#
# Omnistrate provisions its own S3/DynamoDB gateway endpoints. It used to
# associate them only with the VPC's MAIN route table, so this module covered ALL
# non-main route tables unconditionally. That no longer holds: on some cells
# Omnistrate's endpoints already span non-main route tables too, and a route
# table may carry only ONE gateway-endpoint route per service, so associating our
# endpoint with an already-covered table fails the apply with RouteAlreadyExists
# (the Coursera bring-up).
#
# ADAPTIVE MODEL — cover exactly the route tables Omnistrate does not:
#
#   required = non-main route tables
#   missing  = required - Omnistrate_endpoint.route_table_ids
#
# We read Omnistrate's endpoint directly (below), so our own endpoint never
# enters the calculation and cannot count itself.
#
# DISCOVERY — a LIVE describe of Omnistrate's endpoint per service, scoped to
# exactly this cell and to the `available` state. This is the live source of
# truth (not the eventually-consistent Resource Groups Tagging API, whose stale
# entries broke an earlier approach), so a deleted endpoint elsewhere in the
# account cannot affect this plan, and an in-flight replacement (state
# `deleting`) is excluded. It uses ec2:DescribeVpcEndpoints, already granted to
# the runner — no Tagging API, no new caller permission.
#
# CONTRACT — the `aws_vpc_endpoint` data source resolves EXACTLY ONE endpoint.
# This encodes the invariant that Omnistrate supplies exactly one available S3
# and one available DynamoDB gateway endpoint per cell. Zero or two matches fails
# planning before any mutation (a clear, safe failure, not silent-wrong). During
# an Omnistrate endpoint replacement there may momentarily be no `available`
# match; the plan fails then too, which is correct — external coverage is not
# stable, and Pavo should not race in to rewrite gateway routing.

data "aws_route_tables" "cell" {
  vpc_id = var.vpc_id
}

data "aws_route_table" "main" {
  vpc_id = var.vpc_id
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

locals {
  # Non-main route tables: the node/pod route tables that must end up with
  # S3/DynamoDB gateway routing.
  required_route_table_ids = toset([
    for rt in data.aws_route_tables.cell.ids : rt if rt != data.aws_route_table.main.id
  ])

  s3_service_name  = "com.amazonaws.${data.aws_region.current.name}.s3"
  ddb_service_name = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
}

# Omnistrate's cell-owned gateway endpoints. Scoped to this exact cell
# (host-cluster-id) and the `available` state so exactly one resolves.
data "aws_vpc_endpoint" "omnistrate_s3" {
  vpc_id       = var.vpc_id
  service_name = local.s3_service_name
  state        = "available"
  filter {
    name   = "vpc-endpoint-type"
    values = ["Gateway"]
  }
  filter {
    name   = "tag:omnistrate.com/host-cluster-id"
    values = [var.eks_cluster_name]
  }
  filter {
    name   = "tag:omnistrate.com/managed-by"
    values = ["omnistrate"]
  }
}

data "aws_vpc_endpoint" "omnistrate_dynamodb" {
  vpc_id       = var.vpc_id
  service_name = local.ddb_service_name
  state        = "available"
  filter {
    name   = "vpc-endpoint-type"
    values = ["Gateway"]
  }
  filter {
    name   = "tag:omnistrate.com/host-cluster-id"
    values = [var.eks_cluster_name]
  }
  filter {
    name   = "tag:omnistrate.com/managed-by"
    values = ["omnistrate"]
  }
}

locals {
  # Supply exactly the required route tables Omnistrate does not already cover.
  s3_missing_route_table_ids  = setsubtract(local.required_route_table_ids, toset(data.aws_vpc_endpoint.omnistrate_s3.route_table_ids))
  ddb_missing_route_table_ids = setsubtract(local.required_route_table_ids, toset(data.aws_vpc_endpoint.omnistrate_dynamodb.route_table_ids))
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count             = length(local.s3_missing_route_table_ids) > 0 ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = local.s3_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.s3_missing_route_table_ids

  tags = {
    managed-by = "omnistrate"
    purpose    = "byoc-private-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb_gateway" {
  count             = length(local.ddb_missing_route_table_ids) > 0 ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = local.ddb_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.ddb_missing_route_table_ids

  tags = {
    managed-by = "omnistrate"
    purpose    = "byoc-private-dynamodb"
  }
}

# Address migration: these endpoints were un-indexed before `count` was added.
# Map the old address to [0] so an existing owner's endpoint is preserved, not
# destroyed + recreated. If `count` resolves to 0 (Omnistrate already covers
# everything), there is no [0] instance and Terraform destroys the moved
# resource — the intended, safe relinquish.
moved {
  from = aws_vpc_endpoint.s3_gateway
  to   = aws_vpc_endpoint.s3_gateway[0]
}

moved {
  from = aws_vpc_endpoint.dynamodb_gateway
  to   = aws_vpc_endpoint.dynamodb_gateway[0]
}
