# =============================================================================
# S3 / DynamoDB gateway endpoints for the node/pod route tables (ADAPTIVE)
# =============================================================================
# The EKS node/pod subnets sit on non-main route tables. For pod->S3/DynamoDB
# traffic to stay private in-VPC (so aws:SourceVpc is set and a strict
# default-deny cell with NAT blocked can still reach S3/DynamoDB), every such
# route table needs a gateway-endpoint route for the service.
#
# Omnistrate provisions its own S3/DynamoDB gateway endpoints. Historically it
# associated them only with the VPC's MAIN route table, so this module covered
# ALL non-main route tables unconditionally. That assumption no longer holds: on
# some cells Omnistrate's endpoints already span non-main route tables too. A
# route table may carry only ONE gateway-endpoint route per service, so blindly
# associating our endpoint with an already-covered route table fails the apply
# with RouteAlreadyExists (this bit the Coursera bring-up).
#
# ADAPTIVE MODEL — cover exactly the route tables nobody external covers:
#
#   required          = non-main route tables
#   external_coverage = route tables already covered by a NON-Pavo (Omnistrate)
#                       gateway endpoint for the service
#   missing           = required - external_coverage   (what WE must supply)
#
# Ownership (self vs external) is recognised by EITHER the canonical
# `pavo:managed-by = pavo-bootstrap-aws` marker OR the legacy per-service
# `purpose` tag this module has set since the endpoints were introduced
# (PR #322). Every Pavo endpoint carries `purpose`, so recognising it lets this
# release apply with NO pre-seeding: our own endpoints are excluded from external
# coverage on the very first plan, so we never subtract our own coverage and
# never oscillate. Keep the legacy `purpose` clause until there is positive
# evidence every owner has converged onto the canonical marker.
#
# DISCOVERY — via the Resource Groups Tagging API (see the CALLER PREREQUISITE
# below). The pinned AWS provider has no plural `aws_vpc_endpoints` list data
# source, its `aws_route_table` data source omits gateway prefix-list routes, and
# the singular `aws_vpc_endpoint` lookup errors on multiple matches — so the
# tagging API is the only native way to enumerate endpoints. It returns every
# ec2:vpc-endpoint in the account/region that is (or was) tagged. This does NOT
# enumerate an endpoint that has NEVER carried any tag; that is an accepted,
# documented limitation. The contract this relies on is therefore: every Pavo
# and Omnistrate cell gateway endpoint is tagged (both classes always are).
#
# CALLER PREREQUISITE (required contract; verify BEFORE apply):
#   The plan-time provider identity MUST resolve `allowed` for `tag:GetResources`
#   (effective permission, i.e. through any permission boundary / SCP), e.g.
#     aws iam simulate-principal-policy --policy-source-arn <runner-role> \
#       --action-names tag:GetResources
#   The Tagging API has no resource-level scoping and no service-specific
#   condition keys, so the grant is necessarily `Action: tag:GetResources` on
#   `Resource: "*"` (read-only). This module intentionally does NOT provision
#   that permission: the data source runs during planning, so a self-granted
#   permission would arrive too late — a plan-time dependency cycle. Because this
#   permission is a new requirement, v0.6.0 is a CALLER-CONTRACT change (the
#   minor bump signals exactly this): a consumer without it fails at plan.

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
  # Non-main route tables — the node/pod route tables that must end up with
  # S3/DynamoDB gateway routing.
  required_route_table_ids = toset([
    for rt in data.aws_route_tables.cell.ids : rt if rt != data.aws_route_table.main.id
  ])

  s3_service_name  = "com.amazonaws.${data.aws_region.current.name}.s3"
  ddb_service_name = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
}

# Enumerate tagged VPC endpoints in the account/region. Runs as the provider
# identity (assumes the cell role), so it is cross-account correct. See the
# CALLER PREREQUISITE above for the tag:GetResources requirement.
data "aws_resourcegroupstaggingapi_resources" "vpc_endpoints" {
  resource_type_filters = ["ec2:vpc-endpoint"]
}

locals {
  # ARN form: arn:aws:ec2:<region>:<account>:vpc-endpoint/vpce-xxxx
  discovered_endpoint_ids = toset([
    for m in data.aws_resourcegroupstaggingapi_resources.vpc_endpoints.resource_tag_mapping_list :
    reverse(split("/", m.resource_arn))[0]
  ])
}

# Look each discovered endpoint up by its UNIQUE id (singular data source, so no
# multiple-match error) to read vpc_id / type / service / route_table_ids / tags.
data "aws_vpc_endpoint" "discovered" {
  for_each = local.discovered_endpoint_ids
  id       = each.value
}

locals {
  # Restrict to THIS VPC's gateway endpoints for the two services we manage.
  s3_endpoints = {
    for id, ep in data.aws_vpc_endpoint.discovered : id => ep
    if ep.vpc_id == var.vpc_id && ep.vpc_endpoint_type == "Gateway" && ep.service_name == local.s3_service_name
  }
  ddb_endpoints = {
    for id, ep in data.aws_vpc_endpoint.discovered : id => ep
    if ep.vpc_id == var.vpc_id && ep.vpc_endpoint_type == "Gateway" && ep.service_name == local.ddb_service_name
  }

  # Union the route tables covered by NON-Pavo (external) endpoints per service.
  # Self = canonical marker OR legacy per-service purpose tag.
  s3_external_route_table_ids = toset(flatten([
    for id, ep in local.s3_endpoints : try(tolist(ep.route_table_ids), [])
    if !(try(ep.tags["pavo:managed-by"], "") == "pavo-bootstrap-aws" || try(ep.tags["purpose"], "") == "byoc-private-s3")
  ]))
  ddb_external_route_table_ids = toset(flatten([
    for id, ep in local.ddb_endpoints : try(tolist(ep.route_table_ids), [])
    if !(try(ep.tags["pavo:managed-by"], "") == "pavo-bootstrap-aws" || try(ep.tags["purpose"], "") == "byoc-private-dynamodb")
  ]))

  # We supply exactly the required RTs no external endpoint already covers. RTs
  # our own endpoint covers are NOT in the external set (ours is excluded above),
  # so they stay here and our endpoint keeps them — the plan is stable.
  s3_missing_route_table_ids  = setsubtract(local.required_route_table_ids, local.s3_external_route_table_ids)
  ddb_missing_route_table_ids = setsubtract(local.required_route_table_ids, local.ddb_external_route_table_ids)
}

resource "aws_vpc_endpoint" "s3_gateway" {
  count             = length(local.s3_missing_route_table_ids) > 0 ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = local.s3_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.s3_missing_route_table_ids

  tags = {
    managed-by        = "omnistrate"
    "pavo:managed-by" = "pavo-bootstrap-aws"
    purpose           = "byoc-private-s3"
  }
}

resource "aws_vpc_endpoint" "dynamodb_gateway" {
  count             = length(local.ddb_missing_route_table_ids) > 0 ? 1 : 0
  vpc_id            = var.vpc_id
  service_name      = local.ddb_service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.ddb_missing_route_table_ids

  tags = {
    managed-by        = "omnistrate"
    "pavo:managed-by" = "pavo-bootstrap-aws"
    purpose           = "byoc-private-dynamodb"
  }
}

# Address migration: these endpoints were un-indexed before `count` was added.
# Map the old address to [0] so an existing owner's endpoint is preserved (tags
# normalised in place), not destroyed + recreated. If `count` resolves to 0
# (everything already externally covered), there is no [0] instance and Terraform
# destroys the moved resource — the intended, safe relinquish.
moved {
  from = aws_vpc_endpoint.s3_gateway
  to   = aws_vpc_endpoint.s3_gateway[0]
}

moved {
  from = aws_vpc_endpoint.dynamodb_gateway
  to   = aws_vpc_endpoint.dynamodb_gateway[0]
}
