variable "aws_region" {
  description = "AWS region where the Pavo deployment lives."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster runs (Omnistrate-provisioned)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (Omnistrate-tagged kubernetes.io/role/internal-elb=1)."
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name (Omnistrate-provisioned)."
  type        = string
}

variable "eks_oidc_provider" {
  description = "EKS OIDC issuer URL without https:// prefix (e.g., oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE)."
  type        = string

  validation {
    # The IRSA/OIDC wiring downstream concatenates this with `arn:aws:iam::<acct>:oidc-provider/`,
    # so a `https://` prefix on input produces a malformed ARN and fails only at apply time.
    # Catch it at the module boundary.
    condition     = length(var.eks_oidc_provider) > 0 && !startswith(var.eks_oidc_provider, "https://") && !startswith(var.eks_oidc_provider, "http://")
    error_message = "eks_oidc_provider must be the issuer host/path without the https:// or http:// prefix."
  }
}

variable "runner_role_arn" {
  description = "IAM role ARN of the Omnistrate Terraform runner principal that needs cluster-admin RBAC on this EKS cluster. MUST be the underlying role ARN (arn:aws:iam::<acct>:role/<RoleName>), NOT an assumed-role session ARN. See README → 'Onboarding a new AWS BYOC cell' for how to obtain it."
  type        = string

  validation {
    # Reject assumed-role session ARNs — they look like
    #   arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>
    # and they're a common mistake when copying from `aws sts get-caller-identity`.
    # AWS access entries need the underlying role ARN, not the assumed session.
    condition = (
      length(var.runner_role_arn) > 0 &&
      startswith(var.runner_role_arn, "arn:aws:iam::") &&
      length(regexall("[:/]assumed-role/", var.runner_role_arn)) == 0
    )
    error_message = "runner_role_arn must be an IAM role ARN (arn:aws:iam::<acct>:role/<RoleName>), not an assumed-role session ARN. Use `aws iam list-roles` to find the role, or strip the trailing `/<session>` and replace `:sts::<acct>:assumed-role/` with `:iam::<acct>:role/`."
  }
}

# -----------------------------------------------------------------------------
# Sigstore Policy Controller (cell-scoped, single owner per EKS cluster)
# -----------------------------------------------------------------------------
# The policy controller chart, its CRDs (ClusterImagePolicy), and the per-service
# ClusterImagePolicy objects are cluster-scoped — they belong in cell bootstrap,
# NOT per-instance pavoInfra. See README → "Sigstore policy controller" for the
# ownership model and the image-manifest.json that drives the per-service CIPs.

variable "image_policy_mode" {
  description = <<-EOT
    Sigstore ClusterImagePolicy enforcement mode for ghcr.io/pavoai/** images.
    - "enforce" (default): reject admission of images that fail verification.
    - "warn":              admit images that fail verification, emit Warning to
                           admission caller (and controller log entry). Reserved
                           for one-off signing-bake-in on a fresh image lineup.
    The policy verifies: cosign signature + CycloneDX SBOM attestation presence +
    cosign-vuln attestation presence. Attestation CONTENT is not inspected — CVE
    gating happens in central-ci's signing pipeline.
  EOT
  type        = string
  default     = "enforce"
  validation {
    condition     = contains(["warn", "enforce"], var.image_policy_mode)
    error_message = "image_policy_mode must be \"warn\" or \"enforce\"."
  }
}

variable "policy_controller_chart_version" {
  description = <<-EOT
    Helm chart version for sigstore/policy-controller. Bump deliberately and
    test in DEV warn mode first — chart upgrades can change webhook config
    paths or CRD API versions.
  EOT
  type        = string
  default     = "0.10.6"
}

variable "central_ci_project_id" {
  description = <<-EOT
    GCP project that hosts Pavo's central Cloud Build (the one that builds
    and signs all ghcr.io/pavoai/* images). The per-service signing SAs live
    here: cloud-build-<service>@<central_ci_project_id>.iam.gserviceaccount.com.
    Provisioned by central-ci/ in this repo. Default matches today's
    onboarding-455713 project. Pavo images are built in GCP regardless of
    which cloud the customer deploys to, so this is still a GCP project ID
    even in the AWS BYOC cell-bootstrap module.
  EOT
  type        = string
  default     = "onboarding-455713"
}

variable "enable_eck" {
  description = <<-EOT
    Install the Elastic Cloud on Kubernetes (ECK) operator on this cell. Required
    for customers running self-hosted Elasticsearch in-VPC (es_mode = self_hosted
    in the per-instance module). Unnecessary on cells with only Elastic-Cloud
    (es_mode = cloud) instances — an idle operator, CRDs, and validating
    webhook add avoidable surface — so it is opt-in per cell and DEFAULTS OFF.
    Set true on any cell that will host a self_hosted-Elasticsearch instance. When
    true, the cell publishes /pavo/cells/<eks_cluster_name>/eck_ready=true, which
    the per-instance module reads and fails-fast on if a self_hosted instance is
    created before ECK exists.
  EOT
  type        = bool
  default     = false
}

variable "eck_operator_chart_version" {
  description = <<-EOT
    Helm chart version for elastic/eck-operator. Operator and CRDs move in
    lockstep with this chart. Confirm the ECK <-> Elasticsearch version support
    matrix before bumping (ECK 3.x supports the 8.x and 9.x stacks).
  EOT
  type        = string
  default     = "3.4.0"
}

# -----------------------------------------------------------------------------
# In-VPC observability (self-hosted Grafana/Prometheus) — opt-in per cell.
# Mirrors enable_eck. When true, bootstrap installs the metrics stack + the OTel
# collector into the pavo-observability namespace. See README "Cell self-hosting
# flags". No readiness SSM: a grafana_mode=self_hosted misroute just drops
# telemetry (soft), unlike ECK's hard failure.
# -----------------------------------------------------------------------------
variable "enable_observability" {
  description = <<-EOT
    Install the in-VPC observability stack (Prometheus + Grafana + Postgres +
    OTel collector) on this cell, for customers whose telemetry must not leave
    the VPC (grafana_mode = self_hosted). Opt-in per cell, DEFAULTS OFF — a
    cloud-observability cell must not run an unused monitoring stack.
  EOT
  type        = bool
  default     = false
}

variable "observability_grafana_host" {
  description = <<-EOT
    Public hostname the in-VPC Grafana is served at (the cell's external
    endpoint). Grafana's ingress host is grafana.<this>, and root_url derives
    from it. Required when enable_observability = true.
  EOT
  type        = string
  default     = ""
}

variable "pavo_app_alerts_enabled" {
  description = <<-EOT
    Route Prometheus alerts to Pavo (via the in-VPC alert sanitizer, 8-key
    metadata only) in addition to the customer's own webhook. When false, only
    the customer webhook leg is wired. Independent of enable_observability.
  EOT
  type        = bool
  default     = false
}

variable "customer_alert_webhook_url" {
  description = <<-EOT
    Customer's own alert-receiver URL. Alertmanager posts the raw alert here
    (via a Secret file, never the break-glass-readable ConfigMap). Required only
    if you want customer alert delivery; empty disables the customer leg.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "pavo_alert_webhook_url" {
  description = <<-EOT
    Pavo's alert-ingest URL the sanitizer forwards 8-key metadata to (DESTINATION_URL
    via a Secret, never a literal). Required only when pavo_app_alerts_enabled = true.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "customer_name" {
  description = <<-EOT
    Human-readable customer/tenant name, stamped as CUSTOMER_NAME into the alert
    sanitizer's 8-key metadata allowlist (only used when pavo_app_alerts_enabled).
  EOT
  type        = string
  default     = ""
}

variable "sanitizer_image" {
  description = <<-EOT
    Fully-pinned, cosign-signed digest of the pavo-alert-sanitizer image
    (ghcr.io/pavoai/pavo-alert-sanitizer@sha256:...). The cell ClusterImagePolicy
    admits ONLY the signed digest, so this must be a real digest from the signing
    pipeline (see observability/sanitizer/SIGNING.md), not a tag. The sanitizer
    Deployment is applied only when pavo_app_alerts_enabled = true AND this is set;
    empty (default) means the Pavo alert leg stays off until the image is built.
  EOT
  type        = string
  default     = ""
}

variable "pavo_webhook_cidr" {
  description = <<-EOT
    CIDR of the Pavo alert-ingest endpoint the sanitizer forwards 8-key metadata
    to. Only used to render the sanitizer's egress NetworkPolicy leg (inert until
    CNI network-policy enforcement is on). Empty = that leg is not rendered.
  EOT
  type        = string
  default     = ""
}

variable "customer_alert_cidr" {
  description = <<-EOT
    CIDR of the customer's own alert receiver, for the Alertmanager egress
    NetworkPolicy leg (inert until CNI network-policy enforcement is on). Empty =
    that leg is not rendered; the SG-level egress default-deny remains the control.
  EOT
  type        = string
  default     = ""
}

variable "observability_prometheus_chart_version" {
  description = "Helm chart version for prometheus-community/prometheus."
  type        = string
  default     = "29.17.0"
}

variable "observability_grafana_chart_version" {
  description = "Helm chart version for grafana/grafana."
  type        = string
  default     = "10.5.15"
}

variable "observability_postgres_chart_version" {
  description = "Helm chart version for bitnami/postgresql (Grafana metadata backend)."
  type        = string
  default     = "18.7.13"
}

variable "observability_otel_collector_chart_version" {
  description = "Helm chart version for open-telemetry/opentelemetry-collector."
  type        = string
  default     = "0.108.0"
}

variable "cell_kms_key_arn" {
  description = <<-EOT
    The cell's single customer-managed KMS key ARN — encrypts everything at rest
    under the customer's own key (RDS, self-hosted ES + snapshots, and the in-VPC
    observability volumes). One key for the whole deployment: least customer
    effort, uniform key custody. Required when enable_observability = true (used
    for the gp3-cmk StorageClass the observability PVCs bind to).
  EOT
  type        = string
  default     = ""
}
