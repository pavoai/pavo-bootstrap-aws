#!/usr/bin/env bash
# Apply pavo-bootstrap-aws on the one hc-* cell in the account, with cell-account creds.
# Re-runnable: state backend and apply are idempotent. The CMK is created beforehand (create-cmk.sh)
# and passed in, so bootstrap uses the same key as the instance's cell_kms_key_arn.
# Usage: AWS_PROFILE=<profile> ./scripts/run-bootstrap.sh <runner-role-arn> <cell-kms-key-arn> <grafana-host> [--strict]
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: run-bootstrap.sh <runner-role-arn> <cell-kms-key-arn> <grafana-host> [--strict]"
runner_role_arn="${1:?$usage}"
kms_key_arn="${2:?$usage}"
grafana_host="${3:?$usage}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
# tf 1.5 S3 backend can't read sso_session profiles; hand everything plain creds.
eval "$(aws configure export-credentials --format env)"

account_id="$(aws sts get-caller-identity --query Account --output text)"
cell="$(aws eks list-clusters --query 'clusters[?starts_with(@, `hc-`)]' --output text)"
[ "$(wc -w <<<"$cell")" -eq 1 ] || { echo "expected one hc-* cluster, found: ${cell:-none}" >&2; exit 1; }

network_posture=standard
install_private_ca=false
enable_eck=true  # new customers always run self-hosted Elasticsearch
network_policy_ready=false
if [ "${4:-}" = "--strict" ]; then
  network_posture=strict
  install_private_ca=true
  # vpc-cni is Omnistrate-owned; assert enforcement only when the add-on reports it.
  [ "$(aws eks describe-addon --cluster-name "$cell" --addon-name vpc-cni \
        --query addon.configurationValues --output text | jq -r .enableNetworkPolicy)" = true ] \
    || { echo "vpc-cni network policy is not enabled on $cell" >&2; exit 1; }
  network_policy_ready=true
fi

# Fails fast if the cluster API is unreachable or we're not cluster-admin.
EKS_CLUSTER_NAME="$cell" ./scripts/preflight.sh --mode=direct

./scripts/create-state-backend.sh "$AWS_REGION" "$kms_key_arn"

printf 'terraform {\n  backend "s3" {}\n}\n' > backend.tf
terraform init -reconfigure \
  -backend-config="bucket=pavo-tf-state-$account_id" \
  -backend-config="key=pavo-bootstrap-aws/$cell/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=pavo-tf-state-locks" \
  -backend-config="encrypt=true"

terraform apply \
  -var "runner_role_arn=$runner_role_arn" \
  -var "cell_kms_key_arn=$kms_key_arn" \
  -var "observability_grafana_host=$grafana_host" \
  -var "network_posture=$network_posture" \
  -var "install_private_ca=$install_private_ca" \
  -var "enable_eck=$enable_eck" \
  -var "network_policy_ready=$network_policy_ready"

if [ "$network_posture" = strict ]; then
  ./scripts/populate-provider-mirror.sh "$cell" "$AWS_REGION"
fi
