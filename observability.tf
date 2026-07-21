# =============================================================================
# In-VPC observability stack (cell-scoped, opt-in via var.enable_observability)
# =============================================================================
# For customers whose telemetry must not leave the VPC (grafana_mode=self_hosted,
# e.g. BCBSNC). Installs, into the `pavo-observability` namespace:
#   - Postgres        (Grafana metadata backend)
#   - Prometheus      (in-VPC TSDB; scrapes ES exporter + KSM + node-exporter;
#                      accepts remote-write from the OTel collector)
#   - Grafana         (in-VPC UI, internal ingress, dashboards as-code)
#   - OTel collector  (receives app OTLP metrics -> remote-writes to Prometheus)
# All PVCs bind the customer's single CMK via the gp3-cmk StorageClass below.
# Zero egress: nothing here targets anything outside the cluster.
#
# Secrets are generated with random_password (bootstrap state is customer-local,
# so they stay in the customer's control; the break-glass Role cannot read k8s
# Secrets). This is the customer-applied analogue of the ES fileRealm ESO
# generators (which live in Omnistrate-managed state, hence ESO there).

locals {
  obs_count = var.enable_observability ? 1 : 0
  obs_ns    = "pavo-observability"

  # Pavo alert leg (sanitizer + its route). Off unless explicitly enabled AND a
  # real signed image digest is provided — the cell ClusterImagePolicy admits only
  # the signed digest, so there is nothing to deploy until the signing build runs.
  obs_sanitizer_enabled = var.enable_observability && var.pavo_app_alerts_enabled && var.sanitizer_image != ""
}

# VPC CIDR for the (staged) egress NetworkPolicy's in-VPC k8s-API allowance.
data "aws_vpc" "cell" {
  count = local.obs_count
  id    = var.vpc_id
}

# CMK-encrypted gp3 StorageClass for the observability PVCs — the customer's one
# cell CMK. Named gp3-cmk (referenced by the prometheus/postgres values).
resource "kubernetes_storage_class_v1" "gp3_cmk" {
  count = local.obs_count

  # Fail fast if the stack is enabled without the CMK: an empty kmsKeyId would
  # silently fall back to provisioner-default encryption, defeating the one-CMK
  # invariant. Only evaluated when obs_count > 0 (i.e. enable_observability).
  lifecycle {
    precondition {
      condition     = var.cell_kms_key_arn != ""
      error_message = "cell_kms_key_arn must be set when enable_observability = true."
    }
  }

  metadata {
    name = "gp3-cmk"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.cell_kms_key_arn
  }
}

resource "kubernetes_namespace_v1" "observability" {
  count = local.obs_count
  metadata {
    name = local.obs_ns
  }
}

# ---- Generated secrets --------------------------------------------------------
resource "random_password" "grafana_admin" {
  count   = local.obs_count
  length  = 24
  special = false
}

resource "random_password" "grafana_pg_user" {
  count   = local.obs_count
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = local.obs_count
  metadata {
    name      = "pavo-grafana-admin"
    namespace = local.obs_ns
  }
  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin[0].result
  }
  depends_on = [kubernetes_namespace_v1.observability]
}

resource "kubernetes_secret_v1" "grafana_postgres" {
  count = local.obs_count
  metadata {
    name      = "pavo-grafana-postgres"
    namespace = local.obs_ns
  }
  # The official postgres image creates user `grafana` (POSTGRES_USER) as the DB
  # owner, so a single password is all Grafana and the DB need.
  data = {
    "password" = random_password.grafana_pg_user[0].result
  }
  depends_on = [kubernetes_namespace_v1.observability]
}

# Customer's own alert-receiver URL (may be empty until they want alert delivery).
# Alertmanager reads it via url_file, so it never lands in the ConfigMap.
resource "kubernetes_secret_v1" "customer_alert_webhook" {
  count = local.obs_count
  metadata {
    name      = "customer-alert-webhook"
    namespace = local.obs_ns
  }
  data = {
    url = var.customer_alert_webhook_url
  }
  depends_on = [kubernetes_namespace_v1.observability]
}

# Pavo alert-ingest URL — consumed by the sanitizer (DESTINATION_URL). Only
# created for the Pavo alert leg, so it does not exist on customer-only cells.
resource "kubernetes_secret_v1" "pavo_alert_webhook" {
  count = local.obs_sanitizer_enabled ? 1 : 0
  metadata {
    name      = "pavo-alert-webhook"
    namespace = local.obs_ns
  }
  data = {
    url = var.pavo_alert_webhook_url
  }
  depends_on = [kubernetes_namespace_v1.observability]
}

# ---- Postgres (Grafana metadata backend) --------------------------------------
# Grafana's own metadata (users/orgs/datasources/annotations) only — NOT metrics
# (those live in Prometheus) and NOT customer data. Dashboards are as-code, so
# loss is recoverable by reload; no backup in v1. A single StatefulSet on the
# official, patched postgres image (not Bitnami, whose free charts were retired
# to bitnamilegacy in 2025). Single-replica: Grafana itself is single-replica, so
# DB HA would only guard a SPOF behind another SPOF — add CloudNativePG if/when
# Grafana goes multi-replica with a UI uptime SLO.
resource "kubernetes_service_v1" "observability_postgres" {
  count = local.obs_count
  metadata {
    name      = "pavo-observability-postgres"
    namespace = local.obs_ns
  }
  spec {
    cluster_ip = "None" # headless: the StatefulSet owns the single stable pod DNS
    selector   = { app = "pavo-observability-postgres" }
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
  depends_on = [kubernetes_namespace_v1.observability]
}

resource "kubernetes_stateful_set_v1" "observability_postgres" {
  count = local.obs_count
  metadata {
    name      = "pavo-observability-postgres"
    namespace = local.obs_ns
    labels    = { app = "pavo-observability-postgres" }
  }
  spec {
    service_name = "pavo-observability-postgres"
    replicas     = 1
    selector {
      match_labels = { app = "pavo-observability-postgres" }
    }
    template {
      metadata {
        labels = { app = "pavo-observability-postgres" }
      }
      spec {
        # postgres uid/gid in the official Debian image is 999; fs_group makes the
        # CMK-encrypted PVC group-writable so it can run non-root.
        security_context {
          run_as_user  = 999
          run_as_group = 999
          fs_group     = 999
        }
        container {
          name  = "postgres"
          image = "postgres:17"
          port {
            name           = "postgres"
            container_port = 5432
          }
          env {
            name  = "POSTGRES_USER"
            value = "grafana"
          }
          env {
            name  = "POSTGRES_DB"
            value = "grafana"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "pavo-grafana-postgres"
                key  = "password"
              }
            }
          }
          # Subdir so initdb doesn't trip over the volume's lost+found.
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "grafana", "-d", "grafana"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "gp3-cmk"
        resources {
          requests = {
            storage = "8Gi"
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_namespace_v1.observability,
    kubernetes_secret_v1.grafana_postgres,
    kubernetes_storage_class_v1.gp3_cmk,
  ]
}

# ---- Helm releases ------------------------------------------------------------
resource "helm_release" "observability_prometheus" {
  count = local.obs_count

  name       = "pavo-observability-prometheus"
  namespace  = local.obs_ns
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = var.observability_prometheus_chart_version
  values = [templatefile("${path.module}/observability/prometheus-values.yaml.tftpl", {
    customer_leg_enabled = var.customer_alert_webhook_url != ""
    pavo_leg_enabled     = local.obs_sanitizer_enabled
  })]

  depends_on = [
    kubernetes_namespace_v1.observability,
    kubernetes_secret_v1.customer_alert_webhook,
    kubernetes_storage_class_v1.gp3_cmk,
  ]
}

resource "helm_release" "observability_grafana" {
  count = local.obs_count

  # Fail fast if enabled without a host: an empty grafana_host renders a broken
  # domain / root_url / ingress host ("grafana.") rather than failing at plan.
  lifecycle {
    precondition {
      condition     = var.observability_grafana_host != ""
      error_message = "observability_grafana_host must be set when enable_observability = true."
    }
  }

  name       = "pavo-observability-grafana"
  namespace  = local.obs_ns
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = var.observability_grafana_chart_version
  values = [templatefile("${path.module}/observability/grafana-values.yaml.tftpl", {
    grafana_host = var.observability_grafana_host
  })]

  depends_on = [
    kubernetes_namespace_v1.observability,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_stateful_set_v1.observability_postgres,
    helm_release.observability_prometheus,
  ]
}

resource "helm_release" "observability_otel_collector" {
  count = local.obs_count

  name              = "pavo-otel"
  namespace         = local.obs_ns
  repository        = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart             = "opentelemetry-collector"
  version           = var.observability_otel_collector_chart_version
  dependency_update = true
  values            = [file("${path.module}/observability/otel-collector-values.yaml")]

  depends_on = [
    kubernetes_namespace_v1.observability,
    helm_release.observability_prometheus,
  ]
}

# ---- Manifests (dashboards / RBAC / NetworkPolicies / sanitizer) ---------------
# Applied with alekc/kubectl (SSA), mirroring the cell-scoped objects in main.tf.
# Multi-doc files are split with kubectl_file_documents; single-doc files apply
# their yaml_body directly.

# ES dashboard ConfigMap — the Grafana sidecar loads it by the grafana_dashboard
# label. App RED + infra dashboards land here too, authored against real series
# after the first self_hosted deploy (see README "Dashboards").
resource "kubectl_manifest" "obs_es_dashboard" {
  count = local.obs_count

  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true

  yaml_body  = file("${path.module}/observability/manifests/dashboard-configmap.yaml")
  depends_on = [kubernetes_namespace_v1.observability]
}

# Break-glass read-only Role (present-and-inert; no RoleBinding shipped).
resource "kubectl_manifest" "obs_support_role" {
  count = local.obs_count

  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true

  yaml_body  = file("${path.module}/observability/manifests/role.yaml")
  depends_on = [kubernetes_namespace_v1.observability]
}

# Staged egress NetworkPolicies (inert until CNI network-policy enforcement is on).
data "kubectl_file_documents" "obs_netpol" {
  count = local.obs_count
  content = templatefile("${path.module}/observability/manifests/netpol.yaml.tftpl", {
    vpc_cidr            = data.aws_vpc.cell[0].cidr_block
    pavo_webhook_cidr   = var.pavo_webhook_cidr
    customer_alert_cidr = var.customer_alert_cidr
  })
}

resource "kubectl_manifest" "obs_netpol" {
  for_each = var.enable_observability ? data.kubectl_file_documents.obs_netpol[0].manifests : {}

  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true

  yaml_body  = each.value
  depends_on = [kubernetes_namespace_v1.observability]
}

# Pavo alert sanitizer (Deployment + Service). Applied only when the Pavo leg is
# enabled AND a signed image digest is set — see local.obs_sanitizer_enabled.
data "kubectl_file_documents" "obs_sanitizer" {
  count = local.obs_sanitizer_enabled ? 1 : 0
  content = templatefile("${path.module}/observability/manifests/sanitizer.yaml.tftpl", {
    sanitizer_image = var.sanitizer_image
    customer_name   = var.customer_name
    cell_id         = var.eks_cluster_name
    aws_region      = var.aws_region
  })
}

resource "kubectl_manifest" "obs_sanitizer" {
  for_each = local.obs_sanitizer_enabled ? data.kubectl_file_documents.obs_sanitizer[0].manifests : {}

  server_side_apply = true
  force_conflicts   = true
  field_manager     = "terraform"
  apply_only        = true

  yaml_body = each.value
  depends_on = [
    kubernetes_namespace_v1.observability,
    kubernetes_secret_v1.pavo_alert_webhook,
  ]
}
