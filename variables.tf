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
    # Strict IAM-role-ARN match. Rejects assumed-role session ARNs
    # (arn:aws:sts::<acct>:assumed-role/<RoleName>/<session>) AND is deliberately
    # strict because the account parsed out of this ARN is now load-bearing: it is
    # the deterministic cell-account guard for the injected AWS provider (see
    # providers.tf preconditions on data.aws_eks_cluster.primary).
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.runner_role_arn))
    error_message = "runner_role_arn must be an IAM role ARN (arn:aws:iam::<acct>:role/<RoleName>), not an assumed-role session ARN. Use `aws iam list-roles` to find the role, or strip the trailing `/<session>` and replace `:sts::<acct>:assumed-role/` with `:iam::<acct>:role/`."
  }
}

variable "k8s_get_token_role_arn" {
  description = <<-EOT
    Cross-account compatibility input for exec-based EKS authentication. When set,
    the kubernetes/helm/kubectl providers run `aws eks get-token --role-arn <this>`.
    The AWS CLI runs independently of Terraform's AWS provider, so the process's
    AMBIENT AWS credentials must be able to assume this role. This does NOT inherit
    provider-only assume-role options (e.g. external_id). Empty (default) = use
    ambient credentials directly (correct when the run already executes in the cell
    account). The role must already have an EKS access entry + AmazonEKSClusterAdminPolicy
    on the cluster; the module does NOT create it (a one-time operator prerequisite,
    once per role/cluster pair). It must differ from runner_role_arn and live in the
    same account as the injected AWS provider (enforced in providers.tf).
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.k8s_get_token_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.k8s_get_token_role_arn))
    error_message = "k8s_get_token_role_arn must be empty or an IAM role ARN (arn:aws:iam::<acct>:role/<name>)."
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

variable "install_private_ca" {
  description = <<-EOT
    Install the in-cell private CA (a cert-manager ClusterIssuer `pavo-private-ca`
    backed by a self-signed root -> issuing intermediate) on this cell. Required
    for a strict, zero-egress customer (network_posture = strict in the per-instance
    module), whose ingress certs are issued by the private CA instead of public
    ACME (Let's Encrypt HTTP-01 needs egress). Off by default; unnecessary on
    standard cells (whose ingresses use the pavo-letsencrypt-prod ACME issuer).

    INSTALL-ONCE / monotonic: flip false -> true when onboarding a strict cell; do
    NOT flip back on a live cell. The CA objects are apply_only (never deleted by
    Terraform) so the root/intermediate signing keys are not silently destroyed,
    but flipping to false withdraws /pavo/cells/<eks_cluster_name>/private_ca_ready,
    which makes every strict instance on the cell fail its readiness gate. Rotating
    or retiring the root is an explicit multi-step rollover, not a flag flip.

    When true the cell publishes /pavo/cells/<eks_cluster_name>/private_ca_ready=true
    only after the ClusterIssuer is actually Ready; the per-instance module reads it
    and fails-fast if a strict instance is created before the CA exists.
  EOT
  type        = bool
  default     = false
}

variable "network_policy_ready" {
  description = <<-EOT
    Assert that AWS VPC CNI NetworkPolicy ENFORCEMENT is enabled on this cell
    (support enabled, NETWORK_POLICY_ENFORCING_MODE=standard). This is an
    Omnistrate-owned cell add-on setting we cannot toggle from Terraform, so the
    operator sets this true ONLY after Omnistrate confirms it. Off by default.

    When true the cell publishes /pavo/cells/<eks_cluster_name>/network_policy_ready
    =true; the per-instance module reads it and fails-fast if a network_posture=
    strict instance is created before enforcement is on — otherwise the staged
    default-deny NetworkPolicies would be inert and the "strict" instance would
    silently still egress. Pair with install_private_ca for a production strict cell.
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
    Route Prometheus alerts to Pavo (via the in-VPC alert sanitizer, 9-key
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
    Pavo's alert-ingest URL the sanitizer forwards 9-key metadata to (DESTINATION_URL
    via a Secret, never a literal). SECRET: the URL embeds a component that
    authenticates the request, so treat the whole value as a credential and supply it
    via TF_VAR at apply. Required when pavo_app_alerts_enabled = true.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "customer_name" {
  description = <<-EOT
    Human-readable customer/tenant name, stamped as CUSTOMER_NAME into the alert
    sanitizer's 9-key metadata allowlist (only used when pavo_app_alerts_enabled).
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
    CIDR of the Pavo alert-ingest endpoint the sanitizer forwards 9-key metadata
    to. Only used to render the sanitizer's egress NetworkPolicy leg (inert until
    CNI network-policy enforcement is on). Empty = that leg is not rendered.
  EOT
  type        = string
  default     = ""
}

variable "ghcr_dockerconfig" {
  description = <<-EOT
    ghcr.io dockerconfigjson (org-scoped pavoai read credential — the SAME one
    pavoInfra and the service Helm charts use for image pulls). Materialized as
    the `pavo-ghcr-signature-pull` Secret in the pavo-observability namespace so
    the sanitizer pod can pull its private ghcr.io/pavoai image, exactly as
    zitadel-provisioner does in the instance namespace. Already base64-encoded
    (stored via binary_data). Required only when the sanitizer is enabled.
  EOT
  type        = string
  default     = ""
  sensitive   = true
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
  description = <<-EOT
    Helm chart version for prometheus-community/prometheus.

    HOOK INVARIANT: the observability workloads run with wait = false so a
    brand-new cell can apply before it has worker nodes. `wait = false` skips only
    the readiness poll — Helm hook Jobs still block a release independently — so
    that only holds while this chart renders NO `helm.sh/hook` resources. The
    pinned default was audited and renders none.

    Before changing this, render the chart with the values in observability/ and
    confirm it still emits no hooks. A chart that introduces a hook Job silently
    restores the fresh-cell apply failure this module removed.
  EOT
  type        = string
  default     = "29.17.0"
}

variable "observability_grafana_chart_version" {
  description = <<-EOT
    Helm chart version for grafana/grafana.

    HOOK INVARIANT: the observability workloads run with wait = false so a
    brand-new cell can apply before it has worker nodes. `wait = false` skips only
    the readiness poll — Helm hook Jobs still block a release independently — so
    that only holds while this chart renders NO `helm.sh/hook` resources. The
    pinned default was audited and renders none.

    Before changing this, render the chart with the values in observability/ and
    confirm it still emits no hooks. A chart that introduces a hook Job silently
    restores the fresh-cell apply failure this module removed.
  EOT
  type        = string
  default     = "10.5.15"
}

variable "observability_otel_collector_chart_version" {
  description = <<-EOT
    Helm chart version for open-telemetry/opentelemetry-collector.

    HOOK INVARIANT: the observability workloads run with wait = false so a
    brand-new cell can apply before it has worker nodes. `wait = false` skips only
    the readiness poll — Helm hook Jobs still block a release independently — so
    that only holds while this chart renders NO `helm.sh/hook` resources. The
    pinned default was audited and renders none.

    Before changing this, render the chart with the values in observability/ and
    confirm it still emits no hooks. A chart that introduces a hook Job silently
    restores the fresh-cell apply failure this module removed.
  EOT
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

variable "cert_manager_namespace" {
  description = <<-EOT
    Namespace cert-manager runs in, which is also its cluster-resource namespace —
    where a CA-type ClusterIssuer reads the keypair Secret the private CA depends
    on.

    Defaults to `cert-manager-ns`, NOT `cert-manager`. cert-manager is an
    Omnistrate-managed deployment-cell amenity and they install it into
    `cert-manager-ns`; its controller runs with
    `--cluster-resource-namespace=$(POD_NAMESPACE)`, so the cluster-resource
    namespace follows the release namespace. Verified on hc-fmnwao4ct and
    hc-d75sozh69, 2026-09-15.

    Override only if a cell runs cert-manager somewhere else.

    CHANGING THIS ON A CELL THAT ALREADY HAS THE CA IS NOT A MOVE, IT IS A NEW CA.
    The root and intermediate Secrets are created by cert-manager in whichever
    namespace this names, and the CA objects are apply_only, so pointing at a
    different namespace mints a fresh root and intermediate rather than reusing
    the existing keys. Every certificate issued under the old root then fails to
    validate against the new one, and the old root stays installed on customer
    devices via MDM. If a cell ever needs to move namespaces, copy
    `pavo-cell-root-ca` and `pavo-cell-intermediate-ca` across first and treat it
    as a deliberate rollover.

    Not a concern for the default change from `cert-manager` to `cert-manager-ns`:
    no cell has ever had `install_private_ca = true`, so no CA key material exists
    to preserve (verified on hc-fmnwao4ct and hc-d75sozh69, 2026-09-15).
  EOT
  type        = string
  default     = "cert-manager-ns"

  validation {
    # DNS-1123 label, which is what Kubernetes enforces on a namespace name.
    # Length alone was not enough: "Cert-Manager", "cert-manager_" and a 70-char
    # name all passed here and then failed at apply against the API server, which
    # is a worse place to find out.
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cert_manager_namespace)) && length(var.cert_manager_namespace) <= 63
    error_message = "cert_manager_namespace must be a DNS-1123 label: lowercase alphanumerics and '-', starting and ending alphanumeric, at most 63 characters."
  }
}

variable "kubeconfig_path" {
  description = <<-EOT
    Path to a ready-made kubeconfig for every Kubernetes-facing provider
    (kubernetes, kubectl, helm). Empty (the default) derives the endpoint from the
    cluster and authenticates with `aws eks get-token`, which is correct for every
    cell whose Kubernetes API is publicly reachable.

    Set this only for a PRIVATE-ONLY cell. Such a cell has
    `endpointPublicAccess = false`, so the derived endpoint resolves to private IPs
    and cannot be dialled from outside the VPC, whatever IAM permissions the caller
    holds. In practice the file comes from
    `omnistrate-ctl deployment-cell update-kubeconfig <cell> --role cluster-admin`,
    which targets an Omnistrate-side proxy and uses client certificates instead of
    an exec plugin. That proxy port is gated by the account CloudFormation
    parameter `K8sDebugAccessEnabled`, so whether this path exists at all is the
    customer's decision.

    The file must already be valid when Terraform runs: it is read by the
    providers, not produced by them. Credentials in it are short-lived, so refresh
    it before a long apply rather than reusing a stale one.
  EOT
  type        = string
  default     = ""

  validation {
    # A kubeconfig is only consulted when non-empty, so a typo'd path would
    # otherwise fall through to the derived endpoint and fail later with a
    # confusing connection error against an unreachable private API.
    # try() rather than a bare `||`: validation conditions are NOT guaranteed to
    # short-circuit, so `fileexists("")` is evaluated even when the left side is
    # already true. It does not return false, it ERRORS ("." is a directory, not
    # a file), which fails the whole validate rather than the validation. Newer
    # Terraform short-circuits and hides this; CI pins 1.9.8, which does not.
    # Same family of trap as the `&&` note in cell_gates.tf.
    condition     = var.kubeconfig_path == "" || try(fileexists(var.kubeconfig_path), false)
    error_message = "kubeconfig_path must point at an existing file (or be empty to derive the endpoint from the cluster)."
  }
}
