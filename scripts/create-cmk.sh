#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pavo-bootstrap-aws — create the per-cell customer-managed KMS key (CMK)
# -----------------------------------------------------------------------------
# Creates the ONE CMK a Pavo cell uses to encrypt everything: RDS storage, the
# RDS-managed master-password Secrets Manager secret, and (on self-hosted cells)
# the Elasticsearch / in-VPC-observability EBS volumes. Its ARN is the instance
# `cell_kms_key_arn` apiParameter.
#
# This creates a plain symmetric key with the DEFAULT key policy (root -> kms:*).
# That is sufficient whenever the workload + ESO roles live in the SAME account
# (all dev/test cells, e.g. awstest): their IAM policies grant key use, so NO
# key-policy statements are needed. For a LOCKED-DOWN customer key that does not
# delegate to account root, do NOT use this script — follow the 8-statement key
# policy in RUNBOOKS.md "Setting up the CMK".
#
# Idempotent via the alias `alias/pavo-<name>`: re-running adopts the existing key.
#
# Usage:
#   AWS_PROFILE=<account-profile> ./scripts/create-cmk.sh <cell-or-customer-name> [region]
#     e.g. AWS_PROFILE=pavo-multitenant-test ./scripts/create-cmk.sh awsmultitenanttest
#     region defaults to us-east-1.
# -----------------------------------------------------------------------------
set -euo pipefail

NAME="${1:?usage: create-cmk.sh <cell-or-customer-name> [region]}"
REGION="${2:-us-east-1}"

# Allow only the safe alias character set before NAME is embedded anywhere. It
# goes into a JMESPath AliasName filter (list-aliases) and the alias name itself;
# a quote or JMESPath operator could otherwise inject an extra predicate and make
# KEY_ID resolve to an unintended CMK, which tag-resource would then tag.
case "${NAME}" in
  ""|*[!a-zA-Z0-9._-]*)
    echo "[FAIL] invalid name '${NAME}': use only letters, digits, dot, underscore, hyphen" >&2
    exit 1 ;;
esac

ALIAS="alias/pavo-${NAME}"

command -v aws >/dev/null 2>&1 || { echo "[FAIL] aws CLI not found" >&2; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
  echo "[FAIL] could not resolve AWS account — check AWS_PROFILE / credentials" >&2
  exit 1
}

echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${REGION}"
echo "Alias   : ${ALIAS}"
echo

# Idempotent: if the alias already exists, adopt the key it points at. A missing
# alias yields "None" (not an error); real API failures must propagate, so no
# 2>/dev/null || true masking here.
KEY_ID="$(aws kms list-aliases --region "${REGION}" \
  --query "Aliases[?AliasName=='${ALIAS}'].TargetKeyId | [0]" --output text)"

if [ -n "${KEY_ID}" ] && [ "${KEY_ID}" != "None" ]; then
  ACTION="adopted existing"
else
  KEY_ID="$(aws kms create-key --region "${REGION}" \
    --description "Pavo cell CMK for ${NAME}" \
    --tags TagKey=managed_by,TagValue=pavo TagKey=customer,TagValue="${NAME}" \
    --query 'KeyMetadata.KeyId' --output text)"
  aws kms create-alias --region "${REGION}" --alias-name "${ALIAS}" --target-key-id "${KEY_ID}"
  ACTION="created"
fi

# Tag the key so Omnistrate's EBS CSI driver is allowed to use it. On self-hosted
# cells the driver encrypts the Elasticsearch / in-VPC-observability EBS volumes
# with this CMK, and its IAM role scopes kms:CreateGrant (+ crypto) to keys tagged
# omnistrate.com/customer-managed-kms=true. WITHOUT this tag CreateGrant is denied:
# each encrypted volume is created and then deleted seconds later, so the volume
# claim (e.g. the ES data PVC) hangs Pending forever and provisioning stalls.
# Run unconditionally so the adopt-existing path back-tags older keys too;
# tag-resource is idempotent.
aws kms tag-resource --region "${REGION}" --key-id "${KEY_ID}" \
  --tags TagKey=omnistrate.com/customer-managed-kms,TagValue=true

# Resolve the canonical, partition-correct key ARN and confirm the key is usable
# BEFORE reporting success (guards against an alias pointing at a disabled or
# wrong-type key on adoption).
KEY_META="$(aws kms describe-key --region "${REGION}" --key-id "${KEY_ID}" \
  --query 'KeyMetadata.[Arn,KeyState,KeySpec,KeyUsage]' --output text)"
read -r KEY_ARN KEY_STATE KEY_SPEC KEY_USAGE <<<"${KEY_META}"
[ "${KEY_STATE}" = "Enabled" ] || { echo "[FAIL] key ${KEY_ID} is ${KEY_STATE}, expected Enabled" >&2; exit 1; }
{ [ "${KEY_SPEC}" = "SYMMETRIC_DEFAULT" ] && [ "${KEY_USAGE}" = "ENCRYPT_DECRYPT" ]; } || {
  echo "[FAIL] key ${KEY_ID} is ${KEY_SPEC}/${KEY_USAGE}, expected SYMMETRIC_DEFAULT/ENCRYPT_DECRYPT" >&2
  exit 1
}
echo "[ok]   ${ACTION} key ${KEY_ID} + alias ${ALIAS} (Enabled, symmetric encrypt/decrypt)"
# alias ARN shares partition/region/account with the key ARN
ALIAS_ARN="${KEY_ARN%:key/*}:${ALIAS}"

cat <<EOF

Done. Set the instance apiParameter cell_kms_key_arn to either form:
  key ARN   : ${KEY_ARN}
  alias ARN : ${ALIAS_ARN}

Default key policy (root -> kms:*) is used; same-account workload + ESO roles
grant key use via their IAM policies, so no key-policy edits are needed.
For a customer-governed key (access granted by the key policy), see RUNBOOKS.md "Setting up the CMK".
EOF
