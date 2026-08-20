# Input values for the awstest dev cell (hc-fmnwao4ct), Pavo dev AWS account
# 453542520145, us-east-1. Consumed by the bootstrap apply and (future) the
# "Release Omnistrate Bootstrap Dev" GitHub Action.
#
# Non-secret infra identifiers only (VPC/subnet/OIDC/cluster + an Omnistrate
# role ARN). The first five come from the Omnistrate console / SSM
# (/pavo/cells/hc-fmnwao4ct/*). Region is NOT set here: it comes from the AWS
# provider (AWS_REGION in the apply environment; us-east-1 for this cell).

vpc_id             = "vpc-0ea2317980247669a"
private_subnet_ids = ["subnet-0e627382dcb74e001", "subnet-0c8570408aa48b807", "subnet-0430320668ebd7ad1"]
eks_cluster_name   = "hc-fmnwao4ct"
eks_oidc_provider  = "oidc.eks.us-east-1.amazonaws.com/id/16BBB24DBDE3D17FEE6EA9210738A6DB"

# The Omnistrate Terraform runner role (applies pavoInfra); needs cluster-admin.
runner_role_arn = "arn:aws:iam::453542520145:role/omnistrate-custom-terraform-role-for-sm-YO9bljX5OX"

# Sigstore enforcement: "enforce" — the warn window is clean (every running
# ghcr.io/pavoai image on this cell verifies) and the cell was flipped live.
# This codifies that so awstest mirrors the prod Coursera/BCBS posture.
image_policy_mode = "enforce"

# awstest mirrors a full customer cell that will host self-hosted in-VPC ES.
enable_eck = true

# In-VPC observability (self-hosted Grafana/Prometheus/OTel) — mirrors a
# grafana_mode=self_hosted customer cell (zero-egress telemetry). Grafana is
# served at grafana.<observability_grafana_host> over the internal pavo-nginx
# ingress. cell_kms_key_arn is the cell's single CMK (also used by RDS/ES);
# the observability PVCs bind it via the gp3-cmk StorageClass.
enable_observability       = true
observability_grafana_host = "awstest.pavoai.dev"
cell_kms_key_arn           = "arn:aws:kms:us-east-1:453542520145:key/81389baa-ae65-44eb-8dea-426a06be52d9"

# Pavo alert leg: route Prometheus alerts through the in-VPC sanitizer (9-key
# metadata only) to the Pavo-central pavo-alert-forwarder, which relays them to
# #pavo-vpc-alerts. The sanitizer image is cosign-signed and admitted by the
# cell ClusterImagePolicy (image_policy_mode=enforce). The forwarder /32 is
# Pavo-central (onboarding-455713) and identical for every cell; only
# customer_name and the enable toggle are per-cell.
#
# pavo_alert_webhook_url and ghcr_dockerconfig are SECRETS, injected via TF_VAR
# at apply (never committed): the webhook URL embeds the forwarder's path secret
# (https://pavo-alerts.pavoai.dev/h/<secret>) — the sanitizer sends no auth
# header, so the URL is the credential — and ghcr_dockerconfig is the org ghcr
# pull credential. In prod both come from the deploy pipeline's secret store.
pavo_app_alerts_enabled = true
customer_name           = "awstest"
sanitizer_image         = "ghcr.io/pavoai/pavo-alert-sanitizer@sha256:2c583f51f427de586ee08c24026fe225b4c67e742faf57f92436022900df2622"
pavo_webhook_cidr       = "34.69.60.12/32"
