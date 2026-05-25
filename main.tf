data "aws_caller_identity" "current" {}

# ============================================================================
# Workload permission boundary — driven by policy-statements.json (single
# source of truth, also surfaced into spec/spec-aws-byoc.yaml by CI).
# ============================================================================
locals {
  policy_statements = jsondecode(file("${path.module}/policy-statements.json"))
}

data "aws_iam_policy_document" "pavo_permission_boundary" {
  dynamic "statement" {
    for_each = local.policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = flatten([
          for test_name, vars in lookup(statement.value, "conditions", {}) :
          [for var_name, vals in vars : {
            test     = test_name
            variable = var_name
            values   = tolist(flatten([vals]))
          }]
        ])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "pavo_permission_boundary" {
  # Account-scoped: the workload boundary references no cell/instance resources,
  # so a single account-shared policy is created once per account. The sentinel
  # below (`aws_ssm_parameter.single_cell_guard`) is the hard guard against
  # accidentally triggering a second-cell collision on this name in the same
  # account; the depends_on serializes everything behind it.
  name        = "pavo-permission-boundary-shared"
  description = "Permission boundary for Pavo workload IAM roles. Source: policy-statements.json."
  policy      = data.aws_iam_policy_document.pavo_permission_boundary.json

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# ============================================================================
# ESO IRSA role (assumed by the external-secrets ServiceAccount in EKS)
# ============================================================================
data "aws_iam_policy_document" "pavo_eso_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role" "pavo_eso" {
  # Cell-scoped: the trust policy is bound to one cluster's OIDC provider, and
  # ESO is installed once per cell (one external-secrets ServiceAccount per
  # cluster), so this role is inherently per-cell — keyed on eks_cluster_name.
  name                 = "pavo-eso-${var.eks_cluster_name}"
  assume_role_policy   = data.aws_iam_policy_document.pavo_eso_trust.json
  permissions_boundary = aws_iam_policy.pavo_permission_boundary.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

data "aws_iam_policy_document" "pavo_eso_permissions" {
  # Read the RDS-managed master user secret + any pavo-* secrets.
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:pavo-*",
    ]
  }

  # Decrypt the customer's CMK when SecretsManager invokes it on our behalf.
  # Without this, GetSecretValue on a CMK-encrypted RDS-managed secret returns
  # AccessDeniedException at the KMS layer. kms:ViaService scopes the use to
  # the SecretsManager service principal — ESO can't call kms:Decrypt directly.
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "pavo_eso" {
  name   = "pavo-eso-policy-${var.eks_cluster_name}"
  role   = aws_iam_role.pavo_eso.id
  policy = data.aws_iam_policy_document.pavo_eso_permissions.json

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# ============================================================================
# SSM params — integration "API" between bootstrap and workload modules.
# The workload module reads these values rather than receiving them via
# Terraform variables (which would require Pavo-side wiring through Omnistrate).
#
# Two scopes:
#   /pavo/cells/<eks_cluster_name>/* — cell-scoped (the cell's VPC/subnets/OIDC
#     and the per-cell ESO role)
#   /pavo/shared/*                   — account-scoped (the permission boundaries)
# ============================================================================
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/pavo/cells/${var.eks_cluster_name}/vpc_id"
  type  = "String"
  value = var.vpc_id

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/pavo/cells/${var.eks_cluster_name}/private_subnet_ids"
  type  = "StringList"
  value = join(",", var.private_subnet_ids)

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eks_cluster_name" {
  name  = "/pavo/cells/${var.eks_cluster_name}/eks_cluster_name"
  type  = "String"
  value = var.eks_cluster_name

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eks_oidc_provider" {
  name  = "/pavo/cells/${var.eks_cluster_name}/eks_oidc_provider"
  type  = "String"
  value = var.eks_oidc_provider

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eso_role_arn" {
  name  = "/pavo/cells/${var.eks_cluster_name}/eso_role_arn"
  type  = "String"
  value = aws_iam_role.pavo_eso.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "permission_boundary_arn" {
  name  = "/pavo/shared/permission_boundary_arn"
  type  = "String"
  value = aws_iam_policy.pavo_permission_boundary.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# ============================================================================
# EBS CSI driver permission boundary — separate from the workload boundary.
# Mirrors AmazonEBSCSIDriverPolicy. Permission boundaries are intersection
# caps, so attaching the workload boundary to the EBS CSI role would silently
# block ec2:CreateVolume / Attach / Detach / Delete / snapshot operations.
# ============================================================================
locals {
  ebs_csi_policy_statements = jsondecode(file("${path.module}/ebs-csi-policy-statements.json"))
}

data "aws_iam_policy_document" "pavo_ebs_csi_permission_boundary" {
  dynamic "statement" {
    for_each = local.ebs_csi_policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = flatten([
          for test_name, vars in lookup(statement.value, "conditions", {}) :
          [for var_name, vals in vars : {
            test     = test_name
            variable = var_name
            values   = tolist(flatten([vals]))
          }]
        ])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "pavo_ebs_csi_permission_boundary" {
  # Naming matches the IAMCreateRolesOnlyWithBoundary ArnLike pattern
  # (arn:aws:iam::*:policy/pavo-permission-boundary-*) so the boundary-
  # enforcement condition still allows roles created with this boundary.
  name        = "pavo-permission-boundary-ebs-csi-shared"
  description = "Permission boundary for the Pavo EBS CSI driver IRSA role. Source: ebs-csi-policy-statements.json (mirrors AmazonEBSCSIDriverPolicy v14)."
  policy      = data.aws_iam_policy_document.pavo_ebs_csi_permission_boundary.json

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "ebs_csi_permission_boundary_arn" {
  name  = "/pavo/shared/ebs_csi_permission_boundary_arn"
  type  = "String"
  value = aws_iam_policy.pavo_ebs_csi_permission_boundary.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# ============================================================================
# Single-cell-per-account sentinel
# ============================================================================
# The existing bootstrap module mixes account-scoped resources (workload + EBS
# CSI permission boundaries, `/pavo/shared/*` SSM) with cell-scoped resources
# (per-cluster ESO role, the new K8s/Helm/EKS-access stack below). A second
# bootstrap apply in the same AWS account — meant for a second cell — would
# silently collide on the account-scoped names.
#
# The sentinel is the hard guard: AWS returns `ParameterAlreadyExists` on the
# fixed name when a second cell tries to create it, failing the apply BEFORE
# any IAM boundary, role, or K8s resource is touched. `prevent_destroy = true`
# requires a conscious operator action to drop it (see README → "Recovering
# from a misconfigured cell" + Phase 1 rollback notes in the design doc).
#
# Every account-shared or cell-shared resource in this module gets an explicit
# `depends_on = [aws_ssm_parameter.single_cell_guard]` so the sentinel is the
# first thing Terraform tries to create. Broad-by-design — guardrail, not
# abstraction contest.
#
# The structural fix is to split bootstrap into account-scoped + cell-scoped
# modules; tracked as a follow-up. Until then, the sentinel + this README
# warning loudly defer the issue.
resource "aws_ssm_parameter" "single_cell_guard" {
  name        = "/pavo/shared/bootstrap_cell"
  type        = "String"
  value       = var.eks_cluster_name
  description = "Single-cell-per-account sentinel. See pavo-bootstrap-aws/main.tf and README → Ownership rules."

  lifecycle {
    prevent_destroy = true
  }
}

# ============================================================================
# EKS access entry — grants the Omnistrate runner cluster-admin RBAC
# ============================================================================
# Pre-rescope, this lived in `terraform-omnistrate-aws/` and was created on
# every instance create. Post-rescope, bootstrap creates it once per cell and
# every subsequent pavoInfra apply on the cell reuses it.
#
# Principal is supplied as var.runner_role_arn (not derived from caller_identity
# — bootstrap is operator-applied, so the caller is the operator's principal,
# not the runner's).

resource "aws_eks_access_entry" "runner" {
  cluster_name  = var.eks_cluster_name
  principal_arn = var.runner_role_arn
  type          = "STANDARD"

  lifecycle {
    precondition {
      # Access entries require the cluster auth mode to be API or
      # API_AND_CONFIG_MAP. A CONFIG_MAP-only cluster gets a clear, actionable
      # failure instead of an opaque EKS API error.
      condition = contains(
        ["API", "API_AND_CONFIG_MAP"],
        try(data.aws_eks_cluster.primary.access_config[0].authentication_mode, "")
      )
      error_message = "EKS cluster authentication mode must be API or API_AND_CONFIG_MAP to use access entries. Ask Omnistrate to enable access entries on the cluster."
    }
  }

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_eks_access_policy_association" "runner_admin" {
  # Reference the access-entry attributes (not the data source) so this
  # implicitly depends on aws_eks_access_entry.runner being created first.
  cluster_name  = aws_eks_access_entry.runner.cluster_name
  principal_arn = aws_eks_access_entry.runner.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "time_sleep" "wait_for_eks_access" {
  # 30s of control-plane eventual-consistency headroom before the K8s/Helm
  # resources below run — cheap insurance against flaky 403s.
  depends_on      = [aws_eks_access_policy_association.runner_admin]
  create_duration = "30s"
}

# ============================================================================
# External Secrets Operator — Helm release (cell-scoped)
# ============================================================================
# Installed once per cell in the `external-secrets` namespace. The IRSA
# annotation points at this module's own `aws_iam_role.pavo_eso` (no SSM
# round-trip — same Terraform state).

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.4"

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.pavo_eso.arn
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# Stakater Reloader — Helm release (cell-scoped)
# ============================================================================
# Rolls Deployments when watched Secrets/ConfigMaps change. Each app opts in
# via `secret.reloader.stakater.com/reload` annotation in its own Helm chart.

resource "helm_release" "stakater_reloader" {
  name             = "reloader"
  namespace        = "reloader"
  create_namespace = true
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "1.1.0"

  set {
    name  = "reloader.watchGlobally"
    value = "true"
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# EBS CSI driver — IRSA wiring (cell-scoped, fixes P0.2 lifecycle bug)
# ============================================================================
# Pre-rescope this lived in `terraform-omnistrate-aws/` as a per-instance role
# bound to the cluster-wide `kube-system/ebs-csi-controller-sa` ServiceAccount.
# Deleting one instance could remove or flip the IRSA annotation for the whole
# cell, breaking PVC provisioning for every other instance on the cluster.
#
# Post-rescope: one role per cell, name keyed by cluster (with a deterministic
# hash suffix for IAM-role-name length safety — 64-char limit). Cell teardown
# decommissions it; instance teardown never touches it.

locals {
  # Cell-hash suffix preserves uniqueness even when the cluster-name prefix
  # gets truncated to fit IAM's 64-char role-name limit. Truncate the prefix
  # (not the hash) so collisions remain impossible:  55 + "-" + 8 = 64.
  ebs_csi_cell_hash = substr(sha1("${var.aws_region}:${var.eks_cluster_name}"), 0, 8)
  ebs_csi_name_base = substr("pavo-ebs-csi-${var.eks_cluster_name}", 0, 55)
  ebs_csi_role_name = "${local.ebs_csi_name_base}-${local.ebs_csi_cell_hash}"
}

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${var.eks_oidc_provider}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name                 = local.ebs_csi_role_name
  assume_role_policy   = data.aws_iam_policy_document.ebs_csi_assume_role.json
  permissions_boundary = aws_iam_policy.pavo_ebs_csi_permission_boundary.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# Patch IRSA annotation onto the pre-existing kube-system ServiceAccount
# (Omnistrate's Helm provisioner creates it; this just wires AWS perms onto
# it without touching the pods).
resource "kubernetes_annotations" "ebs_csi_sa" {
  api_version = "v1"
  kind        = "ServiceAccount"
  # Omnistrate's Helm provisioner claims ownership of annotations on this SA
  # during cluster bootstrap. force=true lets Terraform override and keep the
  # IRSA role-arn annotation in sync across re-applies. With cell-scoped
  # ownership (this module being the sole writer), there's now a single owner
  # — no last-writer-wins race across multiple instance states.
  force = true
  metadata {
    name      = "ebs-csi-controller-sa"
    namespace = "kube-system"
  }
  annotations = {
    "eks.amazonaws.com/role-arn" = aws_iam_role.ebs_csi.arn
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    aws_iam_role_policy_attachment.ebs_csi,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# ebs-csi-leases — Role + RoleBinding (cell-scoped, kube-system)
# ============================================================================

resource "kubernetes_role" "ebs_csi_leases" {
  metadata {
    name      = "ebs-csi-leases-role"
    namespace = "kube-system"
  }
  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "watch", "list", "create", "update", "patch"]
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

resource "kubernetes_role_binding" "ebs_csi_leases" {
  metadata {
    name      = "ebs-csi-leases-binding"
    namespace = "kube-system"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ebs_csi_leases.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ebs-csi-controller-sa"
    namespace = "kube-system"
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    kubernetes_role.ebs_csi_leases,
  ]
}

# ============================================================================
# pd-balanced StorageClass (cell-scoped, cluster-wide)
# ============================================================================
# Alias for EBS gp3 — name matches the GCP convention used by connector PVCs.

resource "kubernetes_storage_class_v1" "ebs_gp3" {
  metadata {
    name = "pd-balanced"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    kubernetes_annotations.ebs_csi_sa,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# IngressClass — pavo-nginx (cell-scoped, cluster-scoped K8s object)
# ============================================================================
# alekc/kubectl with apply_only = true:
#   - true SSA patch (no pre-existence check that breaks on shared objects)
#   - apply_only retained as a deletion-safety guard during the migration
#     window; once the rescope settles, `apply_only=true` becomes redundant
#     here (cell teardown SHOULD delete). Tracked as a follow-up.

resource "kubectl_manifest" "pavo_ingress_class" {
  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true # see comment block above

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "IngressClass"
    metadata = {
      name = "pavo-nginx"
      labels = {
        "app.kubernetes.io/component" = "controller"
        "app.kubernetes.io/instance"  = "ingress-nginx"
        "app.kubernetes.io/name"      = "ingress-nginx"
      }
    }
    spec = {
      controller = "k8s.io/ingress-nginx"
    }
  })

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# ClusterIssuer — Let's Encrypt HTTP-01 (cell-scoped, cluster-scoped K8s object)
# ============================================================================

resource "kubectl_manifest" "pavo_letsencrypt_prod" {
  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true # see IngressClass comment block

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "pavo-letsencrypt-prod"
    }
    spec = {
      acme = {
        email               = "dev@pavoai.com"
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = { name = "pavo-letsencrypt-prod-account-key" }
        solvers             = [{ http01 = { ingress = { class = "pavo-nginx" } } }]
      }
    }
  })

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}
