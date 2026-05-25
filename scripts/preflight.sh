#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pavo-bootstrap-aws preflight check
# -----------------------------------------------------------------------------
# Run this BEFORE `terraform init` against this module. The bootstrap module
# now creates K8s and Helm resources on the cell's EKS cluster (PR #114
# rescope), so the operator's principal needs cluster-admin RBAC AND the local
# environment needs the AWS / kubectl / Helm CLIs available.
#
# Exit code:
#   0  preflight passed; safe to run terraform init / apply
#   1  preflight failed; see the FAIL line for what to fix
#
# This script intentionally does no destructive operations — it only reads.
# -----------------------------------------------------------------------------
set -euo pipefail

EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

pass() { printf '[ok]   %s\n' "$1"; }
warn() { printf '[warn] %s\n' "$1" >&2; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

# --- 1. CLI dependencies --------------------------------------------------
# `aws`, `kubectl`, `helm` are HARD requirements — bootstrap uses all three.
# `jq` is intentionally NOT required by preflight; it's only needed by
# scripts/create-aws-instance.sh (Pavo-side), not by the bootstrap apply.
for cmd in aws kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "missing required CLI: $cmd (install before running terraform init)"
  fi
  pass "$cmd present ($(command -v "$cmd"))"
done

# --- 2. EKS_CLUSTER_NAME + AWS_REGION ------------------------------------
if [ -z "$EKS_CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
  fail "set EKS_CLUSTER_NAME and AWS_REGION env vars before running preflight"
fi
pass "EKS_CLUSTER_NAME=$EKS_CLUSTER_NAME, AWS_REGION=$AWS_REGION"

# --- 3. AWS credentials work ---------------------------------------------
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "aws sts get-caller-identity failed — refresh credentials (e.g., aws sso login)"
fi
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
pass "AWS caller: $CALLER_ARN"

# --- 4. EKS cluster reachable + kubeconfig context exists ----------------
if ! aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  fail "EKS cluster '$EKS_CLUSTER_NAME' not visible from this caller in $AWS_REGION (wrong account? cluster not provisioned yet?)"
fi
pass "EKS cluster '$EKS_CLUSTER_NAME' reachable"

# Refresh kubeconfig so subsequent kubectl invocations work.
# --alias keeps the context name predictable for downstream tooling.
aws eks update-kubeconfig \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --alias "$EKS_CLUSTER_NAME" >/dev/null
pass "kubeconfig refreshed (context: $EKS_CLUSTER_NAME)"

# --- 5. Hard gate: cluster-admin RBAC -----------------------------------
# kubectl auth can-i '*' '*' --all-namespaces is the canonical cluster-admin
# check. If this is not "yes", the bootstrap apply will fail mid-way through
# helm_release / kubectl_manifest / kubernetes_role with an opaque 403.
# Better to fail loudly here with the Case-B remediation runbook reference.
if ! CAN_I=$(kubectl auth can-i '*' '*' --all-namespaces 2>/dev/null); then
  fail "kubectl auth can-i '*' '*' --all-namespaces returned non-zero — RBAC denied (Case B). See README → 'Bootstrapping a brand-new cell' for the manual access-entry remediation."
fi
if [ "$CAN_I" != "yes" ]; then
  fail "kubectl auth can-i '*' '*' --all-namespaces returned '$CAN_I' (expected 'yes'). RBAC denied (Case B). See README → 'Bootstrapping a brand-new cell' for the manual access-entry remediation."
fi
pass "cluster-admin RBAC confirmed (kubectl auth can-i '*' '*' --all-namespaces = yes)"

# --- 6. Specific can-i diagnostics ---------------------------------------
# These should all pass given the hard gate above; they're here so a failure
# during apply (rare — usually means custom RBAC overrides) is easier to
# diagnose. None of these cause preflight failure on their own when the
# hard gate already passed.
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

# --- 7. ESO + cert-manager CRD readiness (informational) -----------------
# These CRDs are installed by the bootstrap apply (ESO Helm release does its
# own CRD install via `installCRDs=true`). They're NOT prerequisites here —
# but we report what the cluster looks like so the operator can sanity-check
# state against expectation.
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

printf '\nPreflight passed. Safe to run: terraform init && terraform apply\n'
