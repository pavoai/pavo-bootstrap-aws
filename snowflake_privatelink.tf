# =============================================================================
# Snowflake over AWS PrivateLink (snowflake_privatelink, customer opt-in)
# =============================================================================
# For a customer on Snowflake Business Critical (or higher) hosted on AWS in this
# cell's region. Creates nothing unless snowflake_privatelink is set.
#
# Separate from the list in vpc_interface_endpoints.tf because Snowflake's
# endpoint differs from an AWS service endpoint in two ways: the service name is
# the customer's (from SYSTEM$GET_PRIVATELINK_CONFIG), and the service publishes
# no private DNS (so this file also creates a private hosted zone for the
# PrivateLink hostnames). It reuses that file's VPC lookup and per-AZ subnet
# grouping, keeping only the zones the Snowflake service supports.
#
# HTTPS only. Snowflake's PrivateLink guide also opens port 80, for the drivers'
# OCSP response cache. From 4.8.0 the Snowflake Connector for Python checks no
# certificate revocation (OCSP) unless a client opts in, so this requires every
# Pavo Snowflake client in the cell to run 4.8 or later without opting in; the
# bootstrap release that carries this depends on those pins. A client that does
# opt in needs port 80 and the two ocsp. hostnames added back.
#
# The endpoint's IPs sit inside the VPC CIDR, so the strict egress NetworkPolicy
# already allows them and needs no change. Not covered: a Snowflake account in
# another region (internal stages have no cross-region private path).
# =============================================================================

locals {
  snowflake_privatelink_enabled = var.snowflake_privatelink != null
  # The private zone and its records are optional: a customer whose VPCs already
  # resolve privatelink.snowflakecomputing.com sets manage_dns = false and adds
  # the records on their side, from the snowflake_vpce_dns_name output.
  snowflake_privatelink_dns = local.snowflake_privatelink_enabled && try(var.snowflake_privatelink.manage_dns, false)
}

# An endpoint service is offered only in some Availability Zones, and an
# interface endpoint fails to create in a subnet whose zone the service does not
# support. Zone names map to different physical zones in each AWS account, so
# read the zones the service offers to this account and keep only the cell
# subnets in them. Needs the customer's SYSTEM$AUTHORIZE_PRIVATELINK first, as
# does the endpoint itself.
data "aws_vpc_endpoint_service" "snowflake" {
  count        = local.snowflake_privatelink_enabled ? 1 : 0
  service_name = var.snowflake_privatelink.vpce_service_name
}

locals {
  snowflake_service_azs = toset(flatten(data.aws_vpc_endpoint_service.snowflake[*].availability_zones))
  snowflake_endpoint_subnet_ids = [
    for az, ids in local._interface_subnets_by_az : ids[0] if contains(local.snowflake_service_azs, az)
  ]
}

# Its own security group, allowing HTTPS from every VPC CIDR block (primary and
# secondary: pod IPs can come from a secondary block under the VPC CNI). Not the
# shared interface-endpoint group, which exists only when an AWS service
# endpoint is created.
resource "aws_security_group" "snowflake_privatelink" {
  count = local.snowflake_privatelink_enabled ? 1 : 0

  name        = "pavo-snowflake-vpce-${local.eks_cluster_name}"
  description = "HTTPS from the cell VPC to the Snowflake PrivateLink endpoint"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS (Snowflake account URLs) from the cell VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = data.aws_vpc.interface_endpoints.cidr_block_associations[*].cidr_block
  }

  egress {
    description = "Return traffic within the cell VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = data.aws_vpc.interface_endpoints.cidr_block_associations[*].cidr_block
  }

  tags = {
    Name       = "pavo-snowflake-vpce-${local.eks_cluster_name}"
    managed_by = "pavo"
  }

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_vpc_endpoint" "snowflake" {
  count = local.snowflake_privatelink_enabled ? 1 : 0

  vpc_id             = local.vpc_id
  service_name       = var.snowflake_privatelink.vpce_service_name
  vpc_endpoint_type  = "Interface"
  subnet_ids         = local.snowflake_endpoint_subnet_ids
  security_group_ids = [aws_security_group.snowflake_privatelink[0].id]
  # Snowflake's endpoint service publishes no private DNS name; the hosted zone
  # below provides the names instead.
  private_dns_enabled = false

  tags = {
    Name       = "pavo-vpce-snowflake-${local.eks_cluster_name}"
    managed_by = "pavo"
    purpose    = "connector-snowflake"
  }

  lifecycle {
    precondition {
      condition     = length(local.snowflake_endpoint_subnet_ids) > 0
      error_message = "None of the cell's private subnets is in an Availability Zone that the Snowflake endpoint service ${var.snowflake_privatelink.vpce_service_name} supports (${join(", ", sort(tolist(local.snowflake_service_azs)))}). Add a private subnet in one of those zones."
    }
  }

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# Private zone, associated with this cell's VPC only: the PrivateLink hostnames
# resolve to the endpoint here and nowhere else, and nothing outside the VPC
# changes. If the customer already shares a privatelink.snowflakecomputing.com
# zone into this VPC, or forwards snowflakecomputing.com to their own DNS, set
# snowflake_privatelink.manage_dns = false: the endpoint is still created and
# the customer adds the records on their side instead.
resource "aws_route53_zone" "snowflake_privatelink" {
  count = local.snowflake_privatelink_dns ? 1 : 0

  name    = "privatelink.snowflakecomputing.com"
  comment = "Snowflake PrivateLink hostnames for Pavo cell ${local.eks_cluster_name}; resolves only inside the cell VPC"

  vpc {
    vpc_id = local.vpc_id
  }

  tags = {
    Name       = "pavo-snowflake-privatelink-${local.eks_cluster_name}"
    managed_by = "pavo"
  }

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_route53_record" "snowflake_privatelink" {
  for_each = local.snowflake_privatelink_dns ? toset([for h in var.snowflake_privatelink.hostnames : lower(h)]) : toset([])

  zone_id = aws_route53_zone.snowflake_privatelink[0].zone_id
  name    = each.value
  type    = "CNAME"
  ttl     = 300
  records = [aws_vpc_endpoint.snowflake[0].dns_entry[0].dns_name]
}
