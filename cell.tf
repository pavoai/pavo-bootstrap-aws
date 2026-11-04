# Cell inputs the caller left null, read from the provider's account.

# Omnistrate names its clusters hc-<id>; bootstrap allows one cell per account.
data "aws_eks_clusters" "all" {
  count = var.eks_cluster_name == null ? 1 : 0

  lifecycle {
    postcondition {
      condition     = length([for n in self.names : n if startswith(n, "hc-")]) == 1
      error_message = "Expected exactly one hc-* EKS cluster in the provider's account/region, found ${jsonencode(self.names)}. Set eks_cluster_name or fix the provider's account/region."
    }
  }
}

data "aws_subnets" "private" {
  count = var.private_subnet_ids == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  # Same rule terraform-omnistrate-aws uses for the cell's private subnets.
  tags = { "kubernetes.io/role/internal-elb" = "1" }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "No subnet tagged kubernetes.io/role/internal-elb=1 in the cluster VPC."
    }
  }
}

locals {
  eks_cluster_name = var.eks_cluster_name != null ? var.eks_cluster_name : one([for n in data.aws_eks_clusters.all[0].names : n if startswith(n, "hc-")])

  vpc_id             = coalesce(var.vpc_id, data.aws_eks_cluster.primary.vpc_config[0].vpc_id)
  private_subnet_ids = var.private_subnet_ids != null ? var.private_subnet_ids : sort(data.aws_subnets.private[0].ids)
  eks_oidc_provider  = coalesce(var.eks_oidc_provider, trimprefix(data.aws_eks_cluster.primary.identity[0].oidc[0].issuer, "https://"))
}
