# =============================================================================
# S3 / DynamoDB gateway endpoints for the node/pod route tables
# =============================================================================
# Omnistrate provisions an S3 (and DynamoDB) gateway endpoint but associates it
# only with the VPC's MAIN route table. The EKS node/pod subnets are associated
# with OTHER route tables that have no S3 route, so pod->S3/DynamoDB traffic
# egresses via NAT: aws:SourceVpc is never set (VPC-scoped bucket policies deny),
# and on a strict default-deny cell (NAT blocked) pods can't reach S3/DynamoDB at
# all. This is a prerequisite for the in-account provider mirror AND for every
# strict cell (RDS snapshots, storage, etc.).
#
# We add our own gateway endpoints associated with all NON-main route tables so
# that pod->S3/DynamoDB stays private in-VPC. AWS permits a second gateway
# endpoint per service as long as it is placed on route tables that do not
# already have one; the main route table (Omnistrate's endpoint) is excluded.
#
# NOTE: assumes no non-main route table already carries an S3/DynamoDB gateway
# endpoint (true on Omnistrate cells today — theirs is main-RT only). If that
# changes, the apply fails fast on the conflicting association rather than
# silently; exclude those route tables here if so.

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
  # Every route table in the cell VPC except the main one (already covered by
  # Omnistrate's gateway endpoint). The node/pod route tables are all non-main.
  private_route_table_ids = [
    for rt in data.aws_route_tables.cell.ids : rt if rt != data.aws_route_table.main.id
  ]
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = {
    managed-by = "omnistrate"
    purpose    = "byoc-private-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb_gateway" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = {
    managed-by = "omnistrate"
    purpose    = "byoc-private-dynamodb"
  }
}
