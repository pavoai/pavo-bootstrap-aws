# =============================================================================
# Route53 interface VPCE for host-cluster external-dns (no-NAT cells)
# -----------------------------------------------------------------------------
# Omnistrate Monitoring is not a Helm wait. It resolves
# $sys.network.externalClusterEndpoint and probes :443. Host-cluster
# external-dns publishes that name via the Route53 API at
# https://route53.amazonaws.com. On an endpoint-only cell there is no NAT, so
# that call only works through PrivateLink.
#
# Service name is GLOBAL (com.amazonaws.route53), not
# com.amazonaws.<region>.route53 — the regional name does not exist.
#
# Ownership is cell bootstrap, not instance tofu:
#   - external-dns starts at cell create, before the first instance
#   - instance tofu names endpoints pavo-vpce-<svc>-<instance_id> and uses
#     regional service names (wrong for Route53)
#   - we name this pavo-vpce-route53-<eks_cluster_name> so instance tofu
#     treats it as foreign if Route53 is ever added there
#
# Assumes no hand-made Route53 endpoint in the VPC; AWS rejects a second
# private-DNS one, so create fails fast. Own SG: pavo-vpce-sg-<cluster> belongs
# to vpc_interface_endpoints.tf.
#
# After the VPCE exists, annotate the external-dns pod template with the
# endpoint id. A pod that has been failing for days caches public 44.x IPs
# and burns the AWS SDK retry quota; the annotation roll is what makes
# ListHostedZones succeed. Later applies keep the same annotation (no-op).
#
# GATED — only when network_posture = strict. A standard / NAT cell is a no-op.
# =============================================================================

locals {
  route53_wanted = var.network_posture == "strict"
}

data "aws_vpc" "route53" {
  count = local.route53_wanted ? 1 : 0
  id    = local.vpc_id
}

data "aws_subnet" "route53_private" {
  for_each = local.route53_wanted ? toset(local.private_subnet_ids) : toset([])
  id       = each.value
}

data "kubernetes_resources" "external_dns" {
  count          = local.route53_wanted ? 1 : 0
  api_version    = "apps/v1"
  kind           = "Deployment"
  namespace      = "external-dns-ns"
  field_selector = "metadata.name=external-dns"
  limit          = 1
}

locals {
  # Interface endpoints allow at most one subnet per AZ.
  route53_subnets_by_az = {
    for id, s in data.aws_subnet.route53_private : s.availability_zone => id...
  }
  route53_subnet_ids = [for az, ids in local.route53_subnets_by_az : ids[0]]
}

resource "aws_security_group" "route53_vpce" {
  count       = local.route53_wanted ? 1 : 0
  name        = "pavo-vpce-route53-sg-${local.eks_cluster_name}"
  description = "HTTPS from within the VPC to the Route53 PrivateLink endpoint"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.route53[0].cidr_block]
  }

  egress {
    description = "Return traffic within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.route53[0].cidr_block]
  }

  tags = {
    Name = "pavo-vpce-route53-sg-${local.eks_cluster_name}"
  }
}

resource "aws_vpc_endpoint" "route53" {
  count = local.route53_wanted ? 1 : 0

  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.route53"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.route53_subnet_ids
  security_group_ids  = [aws_security_group.route53_vpce[0].id]
  private_dns_enabled = true

  tags = {
    Name              = "pavo-vpce-route53-${local.eks_cluster_name}"
    "pavo.ai/cell"    = local.eks_cluster_name
    "pavo.ai/purpose" = "host-cluster-external-dns"
  }
}

# Roll external-dns once the VPCE id is known. Same annotation on later
# applies is a no-op. Missing Deployment fails the precondition — amenities
# must be up; do not create a strict instance until this apply succeeds.
resource "kubernetes_annotations" "external_dns_route53_vpce" {
  count = local.route53_wanted ? 1 : 0

  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "external-dns"
    namespace = "external-dns-ns"
  }
  # template_annotations lands on the pod template, which is what rolls
  # external-dns. Deployment-level annotations would not restart the pods.
  template_annotations = {
    "pavo.ai/route53-vpce" = aws_vpc_endpoint.route53[0].id
  }

  lifecycle {
    precondition {
      condition     = length(data.kubernetes_resources.external_dns[0].objects) == 1
      error_message = "Host-cluster Deployment external-dns (namespace external-dns-ns) is missing. Cell amenities must install external-dns before bootstrap can publish Route53. Re-apply after Omnistrate has created that Deployment; do not create a strict instance until this succeeds."
    }
  }
}
