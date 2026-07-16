data "aws_caller_identity" "current" {}

# ============================================================================
# Workload permission boundary — driven by policy-statements.json (single
# source of truth, also surfaced into spec/spec-byoc.yaml by CI).
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
# Elastic Cloud on Kubernetes (ECK) operator — Helm release (cell-scoped)
# ============================================================================
# Cluster-global CRDs + operator for self-hosted Elasticsearch (per-instance
# hosting_mode = self_hosted). Opt-in per cell via var.enable_eck (default false)
# — unnecessary on cells with only Elastic-Cloud instances, where an idle
# operator + CRDs + validating webhook would add avoidable surface.
#
# Deliberately NOT here (validated live on hc-fmnwao4ct):
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

  name  = "/pavo/cells/${var.eks_cluster_name}/eck_ready"
  type  = "String"
  value = "true"

  depends_on = [helm_release.eck_operator]
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
      webhook = {
        replicaCount = 2
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
