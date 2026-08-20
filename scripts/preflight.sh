#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pavo-bootstrap-aws preflight check
# -----------------------------------------------------------------------------
# Run this BEFORE `terraform init` against this module. A mode is REQUIRED, because
# the two ways this module is applied have different, non-interchangeable auth
# models:
#
#   --mode=direct  You apply this directory as a Terraform root with credentials
#                  already in the cell account (Pavo's own cells). Preflight can
#                  and does verify cluster-admin against those ambient creds.
#
#   --mode=child   You consume this repo as a Terraform CHILD MODULE. Your root/CI
#                  owns the AWS provider (assume_role/OIDC/env) and the EKS
#                  authorization for the exec-auth principal. A generic shell
#                  script cannot reproduce arbitrary caller auth, so preflight
#                  validates only environment-independent prerequisites. Verify
#                  EKS authorization separately with the recipe in
#                  README -> "Consuming as a child module".
#
# Exit code: 0 pass; 1 fail (see the FAIL line).
# This script does no destructive operations — it only reads.
# -----------------------------------------------------------------------------
set -euo pipefail

pass() { printf '[ok]   %s\n' "$1"; }
warn() { printf '[warn] %s\n' "$1" >&2; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=direct) MODE="direct" ;;
    --mode=child) MODE="child" ;;
    --mode=*) fail "unknown ${arg%%=*} value (use --mode=direct or --mode=child)" ;;
    *) fail "unknown argument: $arg (use --mode=direct or --mode=child)" ;;
  esac
done

if [ -z "$MODE" ]; then
  fail "a mode is required: --mode=direct (you apply with credentials already in the cell account) or --mode=child (you consume this as a Terraform child module; your root/CI owns AWS + EKS auth)"
fi

# --- CLI deps common to both modes: aws + terraform -----------------------
# `aws` is invoked by the Kubernetes providers' exec-auth (`aws eks get-token`).
for cmd in aws terraform; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "missing required CLI: $cmd (install before running terraform init)"
  fi
  pass "$cmd present ($(command -v "$cmd"))"
done

# --- Child/consumer mode: environment-independent checks only -------------
if [ "$MODE" = "child" ]; then
  # helm/kubectl BINARIES are intentionally NOT required here: the hashicorp/helm
  # provider embeds the Helm SDK and alekc/kubectl is a self-contained Terraform
  # provider — neither shells out to a local binary. `kubectl` is needed only if
  # you run the manual authorization-verification recipe (README).
  printf '\nPreflight (child mode) passed.\n'
  printf 'Your root/CI must supply the AWS provider for the cell account, and the\n'
  printf 'exec-auth principal (k8s_get_token_role_arn, or your ambient role) must have\n'
  printf 'an EKS access entry + AmazonEKSClusterAdminPolicy on the cluster. Verify with\n'
  printf 'the recipe in README -> "Consuming as a child module".\n'
  exit 0
fi

# =============================================================================
# --mode=direct : Pavo direct-apply with ambient cell-account credentials
# =============================================================================
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# helm/kubectl CLIs are used by this direct-mode preflight's cluster checks below.
for cmd in kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "missing required CLI: $cmd (needed for --mode=direct cluster checks)"
  fi
  pass "$cmd present ($(command -v "$cmd"))"
done

# --- EKS_CLUSTER_NAME + AWS_REGION ---------------------------------------
if [ -z "$EKS_CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  fail "set EKS_CLUSTER_NAME and AWS_REGION env vars before running preflight"
fi
pass "EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME, AWS_REGION=$AWS_REGION"

# --- AWS credentials work -------------------------------------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "aws sts get-caller-identity failed — refresh credentials (e.g., aws sso login)"
fi
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
pass "AWS caller: $CALLER_ARN"

# --- EKS cluster reachable + kubeconfig context exists -------------------
if ! aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  fail "EKS cluster '$EKS_CLUSTER_NAME' not visible from this caller in $AWS_REGION (wrong account? cluster not provisioned yet?)"
fi
pass "EKS cluster '$EKS_CLUSTER_NAME' reachable"

aws eks update-kubeconfig \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --alias "$EKS_CLUSTER_NAME" >/dev/null
pass "kubeconfig refreshed (context: $EKS_CLUSTER_NAME)"

# --- Hard gate: cluster-admin RBAC ---------------------------------------
if ! CAN_I=$(kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null); then
  fail "kubectl auth can-i '*' '*' --all-namespaces returned non-zero — RBAC denied (Case B). See RUNBOOKS.md → 'Case B' for the manual access-entry remediation."
fi
if [ "$CAN_I" != "yes" ]; then
  fail "kubectl auth can-i '*' '*' --all-namespaces returned '$CAN_I' (expected 'yes'). RBAC denied (Case B). See RUNBOOKS.md → 'Case B' for the manual access-entry remediation."
fi
pass "cluster-admin RBAC confirmed (kubectl auth can-i '*' '*' --all-namespaces = yes)"

# --- Specific can-i diagnostics ------------------------------------------
check_can_i() {
  local verb="$1" resource="$2"
  shift 2
  if [ "$(kubectl auth can-i "$verb" "$resource" "$@" 2>/dev/null || true)" = "yes" ]; then
    pass "can-i $verb $resource $*"
  else
    warn "can-i $verb $resource $* returned non-yes — bootstrap may fail on this resource type"
  fi
}

check_can_i create customresourcedefinitions.apiextensions.k8s.io
check_can_i create clusterroles.rbac.authorization.k8s.io
check_can_i create clusterrolebindings.rbac.authorization.k8s.io
check_can_i create storageclasses.storage.k8s.io
check_can_i create namespaces
check_can_i patch serviceaccounts --namespace kube-system
check_can_i create ingressclasses.networking.k8s.io

# --- ESO + cert-manager CRD readiness (informational) --------------------
if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  pass "externalsecrets.external-secrets.io CRD already installed (cell previously bootstrapped or partially bootstrapped)"
else
  pass "externalsecrets.external-secrets.io CRD not yet installed (bootstrap will install via ESO Helm release)"
fi

if kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  pass "clusterissuers.cert-manager.io CRD already installed (cert-manager present — bootstrap will adopt the existing ClusterIssuer via SSA)"
else
  warn "clusterissuers.cert-manager.io CRD missing — bootstrap's pavo_letsencrypt_prod resource will fail to apply. Install cert-manager before bootstrap, or skip that resource until cert-manager is present."
fi

printf '\nPreflight (direct mode) passed. Safe to run: terraform init && terraform apply\n'
