# Input values for the awstest dev cell (hc-fmnwao4ct), Pavo dev AWS account
# 453542520145, us-east-1. Consumed by the bootstrap apply and (future) the
# "Release Omnistrate Bootstrap Dev" GitHub Action.
#
# Non-secret infra identifiers only (VPC/subnet/OIDC/cluster + an Omnistrate
# role ARN). The first five come from the Omnistrate console / SSM
# (/pavo/cells/hc-fmnwao4ct/*).

aws_region         = "us-east-1"
vpc_id             = "vpc-0ea2317980247669a"
private_subnet_ids = ["subnet-0e627382dcb74e001", "subnet-0c8570408aa48b807", "subnet-0430320668ebd7ad1"]
eks_cluster_name   = "hc-fmnwao4ct"
eks_oidc_provider  = "oidc.eks.us-east-1.amazonaws.com/id/16BBB24DBDE3D17FEE6EA9210738A6DB"

# The Omnistrate Terraform runner role (applies pavoInfra); needs cluster-admin.
runner_role_arn = "arn:aws:iam::453542520145:role/omnistrate-custom-terraform-role-for-sm-YO9bljX5OX"

# Sigstore enforcement: currently "warn" while we confirm every running
# ghcr.io/pavoai image on this cell verifies. Flip to "enforce" once the warn
# window is clean (see README → "Enforcement rollout").
image_policy_mode = "warn"

# awstest mirrors a full customer cell that will host self-hosted in-VPC ES.
enable_eck = true
