#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pavo-bootstrap-aws — populate the in-account OpenTofu provider mirror
# -----------------------------------------------------------------------------
# Fills the per-cell S3 mirror bucket (provider_mirror.tf, named
# pavo-tf-mirror-<eks_cluster_name>) with the OpenTofu provider plugins the cell's
# terraform apply installs. Once the spec wiring is active every AWS cell installs
# providers from this bucket with NO registry fallback, so a strict, zero-egress
# cell runs terraform with no egress to registry.opentofu.org — BUT an empty or
# stale bucket makes that cell's next apply fail. Run this:
#   - once, right after the first `terraform apply` of pavo-bootstrap-aws creates
#     the bucket (before the cell's workload apply runs), and
#   - again whenever a provider version bumps in provider-mirror/versions.tf.
#
# Self-contained: it mirrors the providers pinned in
# pavo-bootstrap-aws/provider-mirror/versions.tf (generated from the AWS workload's
# required_providers), so it needs only this repo — not the workload module. Run it
# on any host WITH registry access; the cell later consumes the bucket WITHOUT any.
#
# Idempotent: builds a clean local tree each run and `aws s3 sync --delete` makes the
# bucket exactly match it (adds new versions, prunes ones no longer pinned).
#
# Usage:
#   AWS_PROFILE=<account-profile> ./scripts/populate-provider-mirror.sh <eks-cluster-name> [region]
#     e.g. AWS_PROFILE=pavo-omnistrate-aws ./scripts/populate-provider-mirror.sh hc-fmnwao4ct
#     region defaults to us-east-1. <eks-cluster-name> is the same value passed to
#     the bootstrap apply (Omnistrate's kubernetesClusterID); the bucket name is
#     derived as pavo-tf-mirror-<eks-cluster-name>.
# -----------------------------------------------------------------------------
set -euo pipefail

CLUSTER="${1:?usage: populate-provider-mirror.sh <eks-cluster-name> [region]}"
REGION="${2:-us-east-1}"

# The bucket name must byte-match provider_mirror.tf: pavo-tf-mirror-<eks_cluster_name>
# served as a virtual-hosted S3 URL, so validate the derived name up front with the
# same rule the terraform precondition enforces (3-63 char, lowercase, hyphen-only).
BUCKET="pavo-tf-mirror-${CLUSTER}"
if ! [[ "${BUCKET}" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  echo "[FAIL] derived bucket '${BUCKET}' is not a valid S3 bucket name: eks_cluster_name must be lowercase, hyphen-only (no dots/underscores)." >&2
  exit 1
fi

# tf-executor runs linux; cover amd64 + arm64 (Graviton) so the mirror serves either
# node arch. Matches scripts/build-provider-mirror.sh.
PLATFORMS=(linux_amd64 linux_arm64)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_SRC_DIR="${SCRIPT_DIR}/../provider-mirror"

command -v tofu >/dev/null 2>&1 || { echo "[FAIL] tofu (OpenTofu) not found on PATH" >&2; exit 1; }
command -v aws  >/dev/null 2>&1 || { echo "[FAIL] aws CLI not found on PATH" >&2; exit 1; }
[ -f "${MIRROR_SRC_DIR}/versions.tf" ] || { echo "[FAIL] ${MIRROR_SRC_DIR}/versions.tf not found (run scripts/render-mirror-providers.py?)" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
  echo "[FAIL] could not resolve AWS account — check AWS_PROFILE / credentials" >&2
  exit 1
}

echo "Account : ${ACCOUNT_ID}"
echo "Region  : ${REGION}"
echo "Cluster : ${CLUSTER}"
echo "Bucket  : s3://${BUCKET}/providers"
echo

# Build into a fresh temp tree each run. `tofu providers mirror` only adds/updates
# versions, so a reused directory keeps stale ones; building clean + syncing --delete
# makes the bucket exactly match versions.tf.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

plat_args=()
for p in "${PLATFORMS[@]}"; do plat_args+=(-platform="$p"); done

echo "==> Mirroring providers from provider-mirror/versions.tf"
# -backend=false / -input=false: provider installation only, no state, no prompts.
( cd "${MIRROR_SRC_DIR}" \
    && tofu init -backend=false -input=false >/dev/null \
    && tofu providers mirror "${plat_args[@]}" "${STAGING_DIR}" )

echo ""
echo "==> Mirror built. Provider hosts:"
ls -1 "${STAGING_DIR}" | sed 's/^/    /'

echo ""
echo "==> Syncing to s3://${BUCKET}/providers (--delete makes the bucket match this build)"
aws s3 sync "${STAGING_DIR}" "s3://${BUCKET}/providers" --region "${REGION}" --delete
echo "[ok]   mirror populated at s3://${BUCKET}/providers"
