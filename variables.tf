# Optional cell inputs: null = read from the provider's account (see cell.tf).
variable "eks_cluster_name" {
  description = "EKS cluster name; null = the one hc-* cluster in the provider's account/region."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "VPC ID of the EKS cluster; null = read from the cluster."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Private subnet IDs; null = the cluster VPC's subnets tagged kubernetes.io/role/internal-elb=1."
  type        = list(string)
  default     = null
}

variable "eks_oidc_provider" {
  description = "EKS OIDC issuer without https:// (e.g. oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE); null = read from the cluster."
  type        = string
  default     = null

  validation {
    # Concatenated into arn:aws:iam::<acct>:oidc-provider/<this>; a scheme prefix only fails at apply.
    condition     = !can(regex("^https?://", var.eks_oidc_provider))
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

variable "external_secrets_chart_version" {
  description = <<-EOT
    Helm chart version for external-secrets/external-secrets. Default 0.10.4,
    which installs the v1beta1 CRDs the instance module's SecretStores use.
    The container image tag is pinned separately in mirrored-images.json;
    bumping this chart without that pin (and a CRD compatibility check) will
    not move the running image and can break SecretStore admission.
  EOT
  type        = string
  default     = "0.10.4"
}

variable "reloader_chart_version" {
  description = <<-EOT
    Helm chart version for stakater/reloader. Default 1.1.0. The container
    image tag is pinned separately in mirrored-images.json; keep the two
    together when bumping.
  EOT
  type        = string
  default     = "1.1.0"
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

variable "network_posture" {
  description = <<-EOT
    Cell network posture. Mirrors the instance apiParameter: 'standard' (default —
    NAT / public egress allowed) or 'strict' (dedicated zero-egress / endpoint-only
    cell). Strict cells need the Route53 interface VPCE so host-cluster external-dns
    can publish Omnistrate ingress names without NAT. Dedicated strict cells only
    (1 cell = 1 customer). This is the only gate for the Route53 interface VPCE.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.network_posture)
    error_message = "network_posture must be \"standard\" or \"strict\"."
  }
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
# In-VPC observability (self-hosted Grafana/Prometheus) — on by default.
# When true, bootstrap installs the metrics stack + the OTel
# collector into the pavo-observability namespace. See README "Cell self-hosting
# flags". No readiness SSM: a grafana_mode=self_hosted misroute just drops
# telemetry (soft), unlike ECK's hard failure.
# -----------------------------------------------------------------------------
variable "enable_observability" {
  description = <<-EOT
    Install the in-VPC observability stack (Prometheus + Grafana + Postgres +
    OTel collector) on this cell (grafana_mode = self_hosted). DEFAULTS ON;
    requires cell_kms_key_arn and observability_grafana_host. Set false only on a
    cell whose instances send telemetry to Grafana Cloud (grafana_mode = cloud).
  EOT
  type        = bool
  default     = true
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
    namespace follows the release namespace. Verified on live Omnistrate
    cells, 2026-09-15.

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
    to preserve (verified on live Omnistrate cells, 2026-09-15).
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

variable "enable_microvm_image_builds" {
  description = "Initially create the account-owned MicroVM publisher/build boundaries. Once either readiness marker exists, false or omitted input retains them; decommission requires a separate drain and state-owned cleanup."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Connector access from a strict cell. All three default to off/empty, so a cell
# that sets none of them renders exactly as before. The two value inputs are
# published as /pavo/cells/<eks_cluster_name>/* parameters (main.tf) instead of
# being Omnistrate instance parameters: every instance deploy runs an early
# Terraform phase WITHOUT instance parameters, and a grant gated on one is
# dropped and later restored on every deploy (0b5f9db: the MicroVM grants were
# revoked for 79 and 28 minutes that way). A cell value is present in every phase.
# -----------------------------------------------------------------------------

variable "connector_assumable_role_arns" {
  description = <<-EOT
    IAM roles in the customer's own accounts that Pavo's connectors may assume
    (today: the Amazon SageMaker connector's IAM-role mode). Exact role ARNs only,
    no wildcards. Default empty: no workload role may assume any role.

    When non-empty, the cell publishes
    /pavo/cells/<eks_cluster_name>/connector_assumable_role_arns, which the
    per-instance module reads to let the workload role assume exactly these roles.
    The permission boundary's matching ceiling (ConnectorAssumeCustomerRoles in
    policy-statements.json) is always present, admits only a Pavo-issued external
    ID (the "pavo-" prefix), and allows nothing on its own. The
    customer's role must still trust the workload role (the principal shown in
    Pavo's SageMaker setup panel) with the same external ID. That trust policy is
    the customer's own and this input does not change it.

    Why a prefix and not the exact external ID: the exact ID is derived per Pavo
    tenant only once the Pavo instance exists, which is after this module is
    applied, so it cannot be named here or in the boundary. The customer's trust
    policy pins the exact value.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.connector_assumable_role_arns :
      can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))
    ])
    error_message = "connector_assumable_role_arns entries must be exact IAM role ARNs (arn:aws:iam::<12-digit account>:role/<name>), with no wildcards."
  }
}

variable "strict_egress_extra_destinations" {
  description = <<-EOT
    Extra destinations that pods of a network_posture = "strict" instance may
    reach, on top of the VPC, same-region S3 and the cluster's own services. For
    the customer's own network only: an outbound proxy, or an on-premises range
    reached over the customer's Transit Gateway or Direct Connect (for example a
    self-hosted Confluence). Each entry is one IPv4 CIDR, the TCP ports allowed to
    it, and a description that becomes the audit trail. Default empty: the strict
    egress policy is unchanged.

    Use a /32 for a single host (a proxy, a Confluence server). The floor is /16,
    so a typo cannot open a whole internal network.

    Published as /pavo/cells/<eks_cluster_name>/strict_egress_extra_destinations;
    the per-instance strict egress NetworkPolicy adds one rule per entry, opening
    only that CIDR and only those ports. This opens the Kubernetes policy only.
    Routing to the destination (Transit Gateway, route tables, firewalls) is the
    customer's network.
  EOT
  type = list(object({
    cidr        = string
    ports       = list(number)
    description = string
  }))
  default = []

  validation {
    # try() on each part: validation conditions are not guaranteed to
    # short-circuit (CI pins 1.9.8), so each part must be safe on its own. The
    # regex keeps IPv6 out: the strict policy and the /16 floor are IPv4.
    condition = alltrue([
      for d in var.strict_egress_extra_destinations :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", d.cidr)) && try(cidrsubnet(d.cidr, 0, 0) == d.cidr, false) && try(tonumber(split("/", d.cidr)[1]) >= 16, false)
    ])
    error_message = "strict_egress_extra_destinations: each cidr must be a canonical IPv4 CIDR (network address) with a prefix of /16 or longer; use /32 for a single host such as a proxy (e.g. 10.20.30.40/32)."
  }

  validation {
    condition = alltrue([
      for d in var.strict_egress_extra_destinations :
      length(d.ports) > 0 && alltrue([for p in d.ports : p >= 1 && p <= 65535 && floor(p) == p])
    ])
    error_message = "strict_egress_extra_destinations: each entry needs at least one TCP port, each a whole number from 1 to 65535."
  }

  validation {
    condition     = alltrue([for d in var.strict_egress_extra_destinations : trimspace(d.description) != ""])
    error_message = "strict_egress_extra_destinations: each entry needs a description saying what the destination is."
  }
}

variable "enable_sagemaker_api_endpoint" {
  description = <<-EOT
    Add the Amazon SageMaker API (com.amazonaws.<region>.sagemaker.api) to this
    cell's interface endpoints (vpc_interface_endpoints.tf), with private DNS, so
    the SageMaker connector reaches SageMaker in this region without leaving the
    AWS network. Default false. Same reuse rule as the other cell endpoints: if a
    foreign private-DNS SageMaker API endpoint already exists in the VPC, it is
    reused and none is created.

    Covers the SageMaker API in this cell's region only. SageMaker in another
    region, and MLflow Apps (AWS publishes no PrivateLink endpoint for them), need
    a separate route.
  EOT
  type        = bool
  default     = false
}

variable "snowflake_privatelink" {
  description = <<-EOT
    Snowflake over AWS PrivateLink, for a customer on Snowflake Business Critical
    (or higher) hosted on AWS in this cell's region. Default null: nothing is
    created. Both values come from SYSTEM$GET_PRIVATELINK_CONFIG, run in the
    customer's Snowflake account after a Snowflake ACCOUNTADMIN has authorized this
    AWS account with SYSTEM$AUTHORIZE_PRIVATELINK:
      - vpce_service_name: the "privatelink-vpce-id" value
        (com.amazonaws.vpce.<region>.vpce-svc-<id>).
      - hostnames: the "privatelink-account-url" and
        "regionless-privatelink-account-url" values. The two OCSP URLs are not
        needed: this module opens HTTPS only, which requires Pavo's Snowflake
        clients to run connector 4.8 or later (no OCSP checking by default).

    Creates an interface endpoint to that service, a security group allowing only
    HTTPS (443) from the cell VPC, and a Route 53 private hosted zone
    privatelink.snowflakecomputing.com, associated with this VPC only, with one
    CNAME per hostname pointing at the endpoint. Set manage_dns = false when the
    customer's VPCs already resolve privatelink.snowflakecomputing.com (a shared
    private hosted zone, or forwarding to their own resolvers): then only the
    endpoint and its security group are created, hostnames may be empty, and the
    customer's DNS team points the account hostnames at the endpoint's DNS name
    (output snowflake_vpce_dns_name). The endpoint's IPs are inside the
    VPC CIDR, which the strict egress policy already allows. In Pavo the
    connector's account is then entered as the PrivateLink account identifier
    (<locator>.<region>.privatelink): no code or connector field changes.
    Snowflake's internal stages are reached through the cell's S3 gateway endpoint,
    which only works when Snowflake is in this cell's region.
  EOT
  type = object({
    vpce_service_name = string
    hostnames         = optional(list(string), [])
    manage_dns        = optional(bool, true)
  })
  default = null

  validation {
    # The attribute access sits inside can(), so a null input never errors here
    # even though validation conditions do not short-circuit (CI pins 1.9.8).
    condition     = var.snowflake_privatelink == null || can(regex("^com\\.amazonaws\\.vpce\\.[a-z0-9-]+\\.vpce-svc-[0-9a-f]+$", var.snowflake_privatelink.vpce_service_name))
    error_message = "snowflake_privatelink.vpce_service_name must be the privatelink-vpce-id from SYSTEM$GET_PRIVATELINK_CONFIG (com.amazonaws.vpce.<region>.vpce-svc-<id>)."
  }

  validation {
    condition = var.snowflake_privatelink == null || try(
      (length(var.snowflake_privatelink.hostnames) > 0 || !var.snowflake_privatelink.manage_dns) && alltrue([
        for h in var.snowflake_privatelink.hostnames :
        can(regex("^(?i)[a-z0-9][a-z0-9.-]*\\.privatelink\\.snowflakecomputing\\.com$", h))
      ]),
      false,
    )
    error_message = "snowflake_privatelink.hostnames must list the PrivateLink account URLs from SYSTEM$GET_PRIVATELINK_CONFIG, each ending in .privatelink.snowflakecomputing.com. At least one is required unless manage_dns is false."
  }
}

variable "legacy_eso_cell_secret_read" {
  description = "Keep the cell ESO role's account-wide read of RDS-managed (rds!*) secrets for instances still on the old per-instance ClusterSecretStore. Default false: the role denies all secret reads and each instance reads only its own secrets through its own SecretStore. Plan fails while any pavo-aws-sm-* ClusterSecretStore exists and this is false; upgrade those instances, or set true until they are upgraded."
  type        = bool
  default     = false
}
