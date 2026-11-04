#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pavo-bootstrap-aws — create the Terraform state backend (S3 + DynamoDB)
# -----------------------------------------------------------------------------
# Creates the remote state backend this module's `terraform init` needs, in the
# CURRENTLY-AUTHENTICATED AWS account. One backend per AWS account; all cells in
# that account share it, keyed per cell (see below). Run this ONCE per AWS
# account, before the first `terraform init` for any cell in it.
#
# Naming convention (derived from the caller's account ID — do not hand-name):
#   S3 bucket   = pavo-tf-state-<account-id>   (versioned, AES256, public-blocked)
#   Lock table  = pavo-tf-state-locks          (DynamoDB, LockID hash key)
#   State key   = pavo-bootstrap-aws/<cluster>/terraform.tfstate   (per cell)
#
# Idempotent: safe to re-run. Existing bucket/table are adopted (and the
# versioning / encryption / public-access-block settings are re-asserted), so
# this doubles as a drift-fixer. Does NOT delete anything.
#
# Usage:
#   AWS_PROFILE=<account-profile> ./scripts/create-state-backend.sh [region]
#     region defaults to us-east-1 (matches the deployment cells).
#
# After it prints the backend config, commit it as
# cells/<cluster>/backend.s3.tfbackend and init with:
#   terraform init -backend-config=cells/<cluster>/backend.s3.tfbackend
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-us-east-1}"

command -v aws >/dev/null 2>&1 || { echo "[FAIL] aws CLI not found" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
  echo "[FAIL] could not resolve AWS account — check AWS_PROFILE / credentials" >&2
  exit 1
}
BUCKET="pavo-tf-state-${ACCOUNT_ID}"
TABLE="pavo-tf-state-locks"

echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${REGION}"
echo "Bucket  : ${BUCKET}"
echo "Table   : ${TABLE}"
echo

# --- S3 state bucket -------------------------------------------------------
if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  # Verify the existing bucket's real region so we never emit a backend config
  # that points state at the wrong region. S3 returns null/"None" for us-east-1.
  LOC="$(aws s3api get-bucket-location --bucket "${BUCKET}" --query 'LocationConstraint' --output text)"
  case "${LOC}" in None|null|"") LOC="us-east-1" ;; esac
  if [ "${LOC}" != "${REGION}" ]; then
    echo "[FAIL] bucket ${BUCKET} exists in ${LOC}, not ${REGION} — refusing to split state across regions" >&2
    exit 1
  fi
  echo "[ok]   bucket ${BUCKET} already exists in ${REGION} — adopting"
else
  # us-east-1 must NOT pass a LocationConstraint; every other region must.
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  echo "[ok]   created bucket ${BUCKET}"
fi

# State-bucket hygiene — idempotent, re-asserted on every run.
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
# TLS-only: deny any non-HTTPS access to the state bucket.
TLS_POLICY="$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::${BUCKET}","arn:aws:s3:::${BUCKET}/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
JSON
)"
aws s3api put-bucket-policy --bucket "${BUCKET}" --policy "${TLS_POLICY}"
echo "[ok]   versioning + AES256 encryption + public-access-block + TLS-only policy enforced"

# --- DynamoDB lock table ---------------------------------------------------
if aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "[ok]   lock table ${TABLE} already exists — adopting"
else
  aws dynamodb create-table --table-name "${TABLE}" --region "${REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "${TABLE}" --region "${REGION}"
  echo "[ok]   created lock table ${TABLE}"
fi

# --- Emit the per-cell backend config -------------------------------------
cat <<EOF

Done. Add a per-cell backend file (replace <cluster> with the EKS cluster name):

  # cells/<cluster>/backend.s3.tfbackend
  bucket         = "${BUCKET}"
  key            = "pavo-bootstrap-aws/<cluster>/terraform.tfstate"
  region         = "${REGION}"
  dynamodb_table = "${TABLE}"
  encrypt        = true

Then: terraform init -backend-config=cells/<cluster>/backend.s3.tfbackend
EOF
