data "aws_caller_identity" "current" {}

# ============================================================================
# Workload permission boundary — driven by policy-statements.json (single
# source of truth, also surfaced into spec/spec-byoc.yaml by CI).
# ============================================================================
locals {
  policy_statements = jsondecode(file("${path.module}/policy-statements.json"))

  # The workload permission boundary caps only pavo-*/keda-* workload roles
  # (app IRSA, ESO, es-snapshots, zitadel-prov, keda-sqs). It must NOT carry the
  # provisioning-runner-only statements (scope="runner") — no bounded role uses
  # them, and including them blew the boundary past the 6144 IAM policy-size cap.
  # scope="runner" → runner policy only (spec CUSTOM_TERRAFORM_POLICY); the
  # runner role is not bounded by this boundary. Absent scope = shared (both).
  boundary_statements = [
    for s in local.policy_statements : s if lookup(s, "scope", "shared") != "runner"
  ]

  # The bootstrap operators (ESO, ECK, policy-controller, reloader) are cluster
  # infrastructure, not tenant workloads — the same category as CoreDNS, the
  # cluster-autoscaler, and the CSI drivers, which all tolerate CriticalAddonsOnly
  # and run on the system/critical node pool. Give our operators the same
  # toleration so they schedule on a BRAND-NEW cell that has only the system pool:
  # tenant workload nodes are created lazily by Omnistrate when an instance
  # deploys, but ECK must be up first (it publishes eck_ready, which gates the
  # first self-hosted-ES instance) — a circular dependency without this. Tenant
  # app + ES *data* pods deliberately do NOT get this toleration, so they still
  # schedule on workload nodes. Matches Omnistrate's own critical add-ons
  # (verified: coredns tolerates {key=CriticalAddonsOnly, operator=Exists}).
  critical_addon_toleration = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
}

data "aws_iam_policy_document" "pavo_permission_boundary" {
  dynamic "statement" {
    for_each = local.boundary_statements
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

  lifecycle {
    # Fail-closed on an unsupported "scope": a typo (e.g. "runer") must NOT
    # silently route a statement into the wrong policy. Allowed values:
    # shared | runner | boundary (absent = shared). Mirrored in
    # scripts/render-policy.sh and scripts/sync-policy-to-spec.py.
    precondition {
      condition = alltrue([
        for s in local.policy_statements :
        contains(["shared", "runner", "boundary"], lookup(s, "scope", "shared"))
      ])
      error_message = "policy-statements.json: every statement's \"scope\" must be one of shared|runner|boundary (absent = shared)."
    }
  }
}

# ============================================================================
# ESO IRSA role (assumed by the external-secrets ServiceAccount in EKS)
# ============================================================================
# Secret reads go through per-instance roles (pavo-eso-<instance_id>, owned by
# terraform-omnistrate-aws) behind namespaced SecretStores. This role stays as
# the ESO controller's ambient identity — the IRSA annotation is what injects
# AWS_STS_REGIONAL_ENDPOINTS=regional, which the controller's STS calls need on
# cells without a global-STS route — but grants nothing by default. The explicit
# Deny overrides customer key policies that grant this role kms:Decrypt directly.
data "aws_iam_policy_document" "pavo_eso_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.eks_oidc_provider}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_provider}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role" "pavo_eso" {
  # Cell-scoped: the trust policy is bound to one cluster's OIDC provider, and
  # ESO is installed once per cell (one external-secrets ServiceAccount per
  # cluster), so this role is inherently per-cell — keyed on eks_cluster_name.
  name                 = "pavo-eso-${local.eks_cluster_name}"
  assume_role_policy   = data.aws_iam_policy_document.pavo_eso_trust.json
  permissions_boundary = aws_iam_policy.pavo_permission_boundary.arn

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

data "aws_iam_policy_document" "pavo_eso_permissions" {
  dynamic "statement" {
    for_each = var.legacy_eso_cell_secret_read ? [] : [1]
    content {
      sid       = "DenySecretRead"
      effect    = "Deny"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "kms:Decrypt"]
      resources = ["*"]
    }
  }

  # Legacy: account-wide read for instances still on a per-instance
  # ClusterSecretStore that authenticates as this role.
  dynamic "statement" {
    for_each = var.legacy_eso_cell_secret_read ? [1] : []
    content {
      effect  = "Allow"
      actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [
        "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
      ]
    }
  }
  dynamic "statement" {
    for_each = var.legacy_eso_cell_secret_read ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:DescribeKey"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
      }
    }
  }
}

# Legacy ClusterSecretStores (pavo-aws-sm-<instance_id>) authenticate as this
# role. Listed after the ESO release so a fresh cell reads them once the CRDs
# exist. Pins external-secrets.io/v1beta1; remove this guard (and
# legacy_eso_cell_secret_read) once every cell has migrated.
data "kubernetes_resources" "legacy_eso_cluster_secret_stores" {
  api_version = "external-secrets.io/v1beta1"
  kind        = "ClusterSecretStore"

  depends_on = [helm_release.external_secrets]
}

locals {
  legacy_eso_cluster_secret_stores = [
    for o in data.kubernetes_resources.legacy_eso_cluster_secret_stores.objects :
    o.metadata.name if startswith(o.metadata.name, "pavo-aws-sm-")
  ]
}

check "legacy_eso_cell_secret_read_stale" {
  assert {
    # Ternary, not ||. Terraform 1.9 does not short-circuit ||, so
    # `true || <unknown list>` stays unknown and warns "known after apply"
    # on a fresh cell: the flag is false, and the External Secrets CRDs do
    # not exist until this apply. The false branch is a known true.
    condition     = var.legacy_eso_cell_secret_read ? length(local.legacy_eso_cluster_secret_stores) > 0 : true
    error_message = "legacy_eso_cell_secret_read is true but no pavo-aws-sm-* ClusterSecretStore remains: the flag is stale; remove it."
  }
}

resource "aws_iam_role_policy" "pavo_eso" {
  name   = "pavo-eso-policy-${local.eks_cluster_name}"
  role   = aws_iam_role.pavo_eso.id
  policy = data.aws_iam_policy_document.pavo_eso_permissions.json

  lifecycle {
    precondition {
      condition     = var.legacy_eso_cell_secret_read || length(local.legacy_eso_cluster_secret_stores) == 0
      error_message = "ClusterSecretStore(s) ${join(", ", local.legacy_eso_cluster_secret_stores)} still read secrets as the cell ESO role. Upgrade those instances first (they move to per-instance SecretStores), or set legacy_eso_cell_secret_read = true until they are upgraded."
    }
  }

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
  name  = "/pavo/cells/${local.eks_cluster_name}/vpc_id"
  type  = "String"
  value = local.vpc_id

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/pavo/cells/${local.eks_cluster_name}/private_subnet_ids"
  type  = "StringList"
  value = join(",", local.private_subnet_ids)

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eks_cluster_name" {
  name  = "/pavo/cells/${local.eks_cluster_name}/eks_cluster_name"
  type  = "String"
  value = local.eks_cluster_name

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eks_oidc_provider" {
  name  = "/pavo/cells/${local.eks_cluster_name}/eks_oidc_provider"
  type  = "String"
  value = local.eks_oidc_provider

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "eso_role_arn" {
  name  = "/pavo/cells/${local.eks_cluster_name}/eso_role_arn"
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
  value       = local.eks_cluster_name
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
  cluster_name  = local.eks_cluster_name
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
  version          = var.external_secrets_chart_version

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.pavo_eso.arn
  }

  # Tolerate CriticalAddonsOnly on all three ESO deployments (controller,
  # webhook, cert-controller) — see local.critical_addon_toleration.
  # Image pins come from mirrored-images.json so a no-NAT cell does not pull
  # oci.external-secrets.io.
  values = [yamlencode({
    image = {
      repository = local.mirrored.external_secrets.repository
      tag        = local.mirrored.external_secrets.tag_at_digest
    }
    tolerations = local.critical_addon_toleration
    webhook = {
      image = {
        repository = local.mirrored.external_secrets.repository
        tag        = local.mirrored.external_secrets.tag_at_digest
      }
      tolerations = local.critical_addon_toleration
    }
    certController = {
      image = {
        repository = local.mirrored.external_secrets.repository
        tag        = local.mirrored.external_secrets.tag_at_digest
      }
      tolerations = local.critical_addon_toleration
    }
  })]

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# Elastic Cloud on Kubernetes (ECK) operator — Helm release (cell-scoped)
# ============================================================================
# Cluster-global CRDs + operator for self-hosted Elasticsearch (per-instance
# es_mode = self_hosted). Opt-in per cell via var.enable_eck (default false)
# — unnecessary on cells with only Elastic-Cloud instances, where an idle
# operator + CRDs + validating webhook would add avoidable surface.
#
# Deliberately NOT here (validated live on an Omnistrate cell):
#   - vm.max_map_count sysctl (ES >= 8.16 prereq): the Omnistrate node AMI is
#     Bottlerocket, which already ships vm.max_map_count=1048576. No DaemonSet.
#   - S3 gateway VPC endpoint for snapshots: Omnistrate already provisions one
#     on the cell VPC, so in-VPC snapshot traffic is already covered.
# The eck-operator chart installs its CRDs by default (no installCRDs flag).

resource "helm_release" "eck_operator" {
  count = var.enable_eck ? 1 : 0

  name             = "elastic-operator"
  namespace        = "elastic-system"
  create_namespace = true
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = var.eck_operator_chart_version

  # Tolerate CriticalAddonsOnly so the operator can run on the system pool of a
  # fresh cell (no tenant workload nodes yet) — see local.critical_addon_toleration.
  # Image pin from mirrored-images.json (no-NAT cells cannot pull docker.elastic.co).
  values = [yamlencode({
    image = {
      repository = local.mirrored.eck_operator.repository
      tag        = local.mirrored.eck_operator.tag
      digest     = local.mirrored.eck_operator.digest
    }
    tolerations = local.critical_addon_toleration
  })]

  # wait=true (default) blocks until the operator StatefulSet is rolled out, so
  # eck_ready below is only published once the operator is actually up.
  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# eck_ready gate (cell -> instance): published only after the operator release
# is deployed. The per-instance module reads this via data.aws_ssm_parameter and
# fails-fast if a self_hosted Elasticsearch instance is created before ECK
# exists on the cell (same cell->instance SSM "API" as vpc_id/eso_role_arn).
resource "aws_ssm_parameter" "eck_ready" {
  count = var.enable_eck ? 1 : 0

  name  = "/pavo/cells/${local.eks_cluster_name}/eck_ready"
  type  = "String"
  value = "true"

  depends_on = [helm_release.eck_operator]
}

# network_policy_ready gate (cell -> instance): operator-asserted signal that the
# cell's AWS VPC CNI NetworkPolicy enforcement is on (an Omnistrate-owned add-on
# we can't toggle here). The per-instance module fails-fast on it for
# network_posture=strict, so a strict instance can never run with its staged
# default-deny NetworkPolicies inert (which would silently still allow egress).
resource "aws_ssm_parameter" "network_policy_ready" {
  count = var.network_policy_ready ? 1 : 0

  name  = "/pavo/cells/${local.eks_cluster_name}/network_policy_ready"
  type  = "String"
  value = "true"

  # Ownership rules: every cell-shared resource waits on the single-cell
  # sentinel. Without it this marker has no dependencies at all, so Terraform
  # can create it in parallel with the guard — and an apply that the guard
  # rejects would still leave a readiness marker a strict instance can consume.
  # eck_ready and private_ca_ready get this transitively through the workloads
  # they wait on; this one is a bare parameter, so it needs it stated.
  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# connector_assumable_role_arns / strict_egress_extra_destinations (cell -> instance):
# customer-supplied VALUES, not readiness markers. The per-instance module renders
# them into the workload role's sts:AssumeRole statement and the strict egress
# NetworkPolicy. Published here instead of passed as Omnistrate instance
# parameters because an early phase of every instance deploy renders WITHOUT
# instance parameters (see the variables). JSON in a String parameter, not a
# StringList: an IAM role name may itself contain a comma. Empty input, no
# parameter, and the instance renders nothing extra.
resource "aws_ssm_parameter" "connector_assumable_role_arns" {
  count = length(var.connector_assumable_role_arns) > 0 ? 1 : 0

  name  = "/pavo/cells/${local.eks_cluster_name}/connector_assumable_role_arns"
  type  = "String"
  value = jsonencode(var.connector_assumable_role_arns)

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

resource "aws_ssm_parameter" "strict_egress_extra_destinations" {
  count = length(var.strict_egress_extra_destinations) > 0 ? 1 : 0

  name  = "/pavo/cells/${local.eks_cluster_name}/strict_egress_extra_destinations"
  type  = "String"
  value = jsonencode(var.strict_egress_extra_destinations)

  depends_on = [aws_ssm_parameter.single_cell_guard]
}

# observability_ready (cell -> instance): the second half of the same cell->instance
# SSM "API" as eck_ready, and it means something deliberately weaker.
#
# eck_ready means "the ECK operator is UP" — that release runs with the default
# wait = true, so the parameter cannot be written until the operator StatefulSet
# has rolled out.
#
# observability_ready means only "this cell INSTALLED the observability stack".
# It does NOT mean the stack is running. The observability workloads carry
# wait = false / wait_for_rollout = false on purpose, because on a brand-new cell
# they legitimately cannot schedule until Omnistrate creates worker nodes, and
# blocking the customer's Phase-3 apply on that is what forced the manual
# two-phase toggle during an early customer onboarding.
#
# So this parameter answers "is there supposed to be a receiver here?", which is
# what an instance needs in order to fail fast on a misconfiguration
# (grafana_mode = self_hosted against a cell that was never bootstrapped for it).
# Whether the stack actually CONVERGED is asserted separately, once, by the
# Phase-4 barrier in terraform-omnistrate-aws/observability_readiness.tf — which
# runs from outside this cluster and can therefore see failures the in-cluster
# monitoring cannot report about itself.
resource "aws_ssm_parameter" "observability_ready" {
  count = var.enable_observability ? 1 : 0

  name  = "/pavo/cells/${local.eks_cluster_name}/observability_ready"
  type  = "String"
  value = "true"

  # Ordering only — see above. These resources return as soon as the objects are
  # created, not when the pods are Ready.
  depends_on = [
    kubernetes_stateful_set_v1.observability_postgres,
    helm_release.observability_prometheus,
    helm_release.observability_grafana,
    helm_release.observability_otel_collector,
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
  version          = var.reloader_chart_version

  set {
    name  = "reloader.watchGlobally"
    value = "true"
  }

  # Tolerate CriticalAddonsOnly so reloader runs on the system pool of a fresh
  # cell — see local.critical_addon_toleration.
  # Image pin from mirrored-images.json (no-NAT cells cannot pull ghcr.io).
  values = [yamlencode({
    reloader = {
      deployment = {
        image = {
          name = local.mirrored.reloader.repository
          tag  = local.mirrored.reloader.tag_at_digest
        }
        tolerations = local.critical_addon_toleration
      }
    }
  })]

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# ============================================================================
# EBS CSI driver — NOT managed here (Omnistrate owns it, including customer CMK)
# ============================================================================
# Omnistrate pre-installs and lifecycle-manages the EBS CSI driver on every cell
# — the omnistrate-ebs-csi-driver-<cell> IRSA role, its
# kube-system/ebs-csi-controller-sa ServiceAccount, and the lease RBAC. That
# role is already bounded (omnistrate-bootstrap-permissions-boundary) AND now
# carries the customer-CMK KMS permissions (kms:CreateGrant + crypto, scoped by
# kms:ViaService=ec2 and aws:ResourceTag/omnistrate.com/customer-managed-kms —
# Omnistrate's Option 1A; see the CMK onboarding section in README.md).
#
# So this module manages NONE of the driver's role/SA/RBAC. Re-owning it caused
# a reconcile tug-of-war, and re-annotating the SA to a Pavo role (which has NO
# KMS) would REGRESS customer-CMK provisioning. We only add the StorageClass
# below, on top of Omnistrate's ebs.csi.aws.com provisioner.

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

# ============================================================================
# Sigstore Policy Controller + per-service ClusterImagePolicies (cell-scoped)
# ============================================================================
# The policy controller is a cluster-wide admission webhook. Per the ownership
# rule "no cluster-scoped K8s resource may live in terraform-omnistrate-aws"
# (README → Hard rules), both the controller helm release and the per-service
# ClusterImagePolicy resources are owned here in cell-bootstrap, not pavoInfra.
# pavoInfra only adds the `policy.sigstore.dev/include = "true"` label to each
# per-instance namespace; the controller picks up labeled namespaces dynamically.
#
# Service list + image globs come from `image-manifest.json` vendored alongside
# this file (the canonical source is `spec/image-manifest.json`; we vendor
# because customers apply this module standalone — the wider repo isn't shipped
# to them). Keep `pavo-bootstrap-aws/image-manifest.json` in sync with
# `spec/image-manifest.json` when adding a new service.
#
# Per-service signer SAs (cloud-build-<service>@<central_ci_project_id>) are
# provisioned by `central-ci/`. During the migration window the shared
# `cloud-build@...` SA is also accepted (the `pavo-cloud-build-shared-transition`
# authority below) — drop that entry once every Pavo service has been re-signed
# under its per-service SA.

resource "helm_release" "policy_controller" {
  name             = "policy-controller"
  repository       = "https://sigstore.github.io/helm-charts"
  chart            = "policy-controller"
  version          = var.policy_controller_chart_version
  namespace        = "cosign-system"
  create_namespace = true

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # webhook.replicaCount=2 for HA; webhook.configData.no-match-policy=allow is
  # critical — the chart default is REJECT, which would block every non-Pavo
  # image in any labeled Pavo namespace (kube-system, app sidecars from random
  # registries, etc.). We only want to enforce on ghcr.io/pavoai/** via the
  # ClusterImagePolicies below; everything else admits unchanged.
  values = [
    yamlencode({
      # commonTolerations applies to all policy-controller pods — tolerate
      # CriticalAddonsOnly so they run on the system pool of a fresh cell (see
      # local.critical_addon_toleration).
      commonTolerations = local.critical_addon_toleration
      # Image pins from mirrored-images.json. disable-tuf: no-NAT cells cannot
      # refresh the public Sigstore TUF root.
      leasescleanup = {
        image = {
          repository = local.mirrored.leases_cleanup.repository
          version    = local.mirrored.leases_cleanup.tag_at_digest
        }
      }
      webhook = {
        replicaCount = 2
        extraArgs = {
          disable-tuf = true
        }
        image = {
          repository = local.mirrored.policy_controller.repository
          version    = local.mirrored.policy_controller.digest
        }
        configData = {
          "no-match-policy" = "allow"
        }
      }
    })
  ]

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

locals {
  image_manifest = jsondecode(file("${path.module}/image-manifest.json"))
  # Trailing `*` is REQUIRED. Sigstore policy-controller globs use Go
  # `filepath.Match` semantics against the full image reference
  # (`ghcr.io/pavoai/<svc>:<tag>` or `@sha256:...`), so a bare
  # `ghcr.io/pavoai/<svc>` only matches the no-tag/no-digest form — which
  # production pulls never use. Combined with `webhook.no-match-policy=allow`,
  # missing the wildcard would silently bypass enforcement on every Pavo image.
  service_image_globs = {
    for service, cfg in local.image_manifest.services :
    service => [for img in cfg.images : "ghcr.io/pavoai/${img.ghcr_name}*"]
  }
}

resource "kubectl_manifest" "pavo_image_policy" {
  for_each = local.service_image_globs

  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true # NEVER delete on teardown — shared cluster resource

  yaml_body = yamlencode({
    apiVersion = "policy.sigstore.dev/v1beta1"
    kind       = "ClusterImagePolicy"
    metadata = {
      name = "pavo-${each.key}"
    }
    spec = {
      mode   = var.image_policy_mode
      images = [for glob in each.value : { glob = glob }]
      authorities = [
        {
          name = "pavo-cloud-build-${each.key}"
          # Read cosign signatures/attestations from the PRIVATE ghcr.io/pavoai
          # repo. signaturePullSecrets resolve from the admitted workload's
          # namespace; pavoInfra materializes `pavo-ghcr-signature-pull` there.
          source = [
            { signaturePullSecrets = [{ name = "pavo-ghcr-signature-pull" }] }
          ]
          keyless = {
            url = "https://fulcio.sigstore.dev"
            identities = [
              {
                issuer  = "https://accounts.google.com"
                subject = "cloud-build-${each.key}@${var.central_ci_project_id}.iam.gserviceaccount.com"
              }
            ]
          }
          ctlog = {
            url = "https://rekor.sigstore.dev"
          }
          attestations = [
            {
              name          = "require-sbom"
              predicateType = "https://cyclonedx.org/bom"
            },
            {
              name          = "require-vuln"
              predicateType = "https://cosign.sigstore.dev/attestation/vuln/v1"
            },
          ]
        },
        {
          name = "pavo-cloud-build-shared-transition"
          source = [
            { signaturePullSecrets = [{ name = "pavo-ghcr-signature-pull" }] }
          ]
          keyless = {
            url = "https://fulcio.sigstore.dev"
            identities = [
              {
                issuer  = "https://accounts.google.com"
                subject = "cloud-build@${var.central_ci_project_id}.iam.gserviceaccount.com"
              }
            ]
          }
          ctlog = {
            url = "https://rekor.sigstore.dev"
          }
          attestations = [
            {
              name          = "require-sbom"
              predicateType = "https://cyclonedx.org/bom"
            },
            {
              name          = "require-vuln"
              predicateType = "https://cosign.sigstore.dev/attestation/vuln/v1"
            },
          ]
        },
      ]
    }
  })

  depends_on = [helm_release.policy_controller]
}
