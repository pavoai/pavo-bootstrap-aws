# =============================================================================
# In-cell private CA (strict / zero-egress cells) — cert-manager ClusterIssuer
# =============================================================================
# A strict cell (network_posture=strict, per-instance module) issues ingress
# certs from a private CA instead of public ACME — Let's Encrypt HTTP-01 needs
# egress, which a zero-egress cell forbids. The chain is:
#
#   Issuer pavo-cell-selfsigned (selfSigned)
#     -> Certificate pavo-cell-root-ca (isCA)                 [MDM trust anchor]
#       -> Issuer pavo-cell-root-issuer (ca, root secret)     [signs the intermediate]
#         -> Certificate pavo-cell-intermediate-ca (isCA)     [signs all leaves]
#           -> ClusterIssuer pavo-private-ca (ca, intermediate secret)
#             -> ingress leaf certs
#
# The root does NOT sign leaves directly, so rotating the intermediate never
# forces re-pushing the root (which customers install via MDM). All objects live
# in cert-manager's cluster-resource namespace (`cert-manager`), where a CA-type
# ClusterIssuer reads its keypair Secret — the same namespace the ACME
# ClusterIssuer keeps its account key. The cert-manager Certificate controllers
# PRODUCE the key Secrets; Terraform never creates them (one owner of the key
# material) and keys never enter TF state. cert-manager is a cell prerequisite
# (preflight.sh), same as for the ACME ClusterIssuer.
#
# INSTALL-ONCE: gated on var.install_private_ca and apply_only=true (additive,
# never deleted on teardown — same lifecycle as the ACME ClusterIssuer). Flipping
# the flag off does not destroy the signing keys; see the variable docs.

locals {
  private_ca_count          = var.install_private_ca ? 1 : 0
  private_ca_namespace      = "cert-manager"
  private_ca_root_secret    = "pavo-cell-root-ca"
  private_ca_int_secret     = "pavo-cell-intermediate-ca"
  private_ca_cluster_issuer = "pavo-private-ca"
}

# 1. SelfSigned bootstrap Issuer — signs only the root CA.
resource "kubectl_manifest" "private_ca_selfsigned" {
  count = local.private_ca_count

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "pavo-cell-selfsigned"
      namespace = local.private_ca_namespace
    }
    spec = { selfSigned = {} }
  })

  depends_on = [
    aws_ssm_parameter.single_cell_guard,
    time_sleep.wait_for_eks_access,
  ]
}

# 2. Root CA — the MDM trust anchor. rotationPolicy Never + 20y so a cert-manager
#    renewal never silently regenerates the root key; rotating the root is an
#    explicit multi-step rollover (distribute new root -> overlap -> switch chain
#    -> retire old), never an automatic action.
resource "kubectl_manifest" "private_ca_root" {
  count = local.private_ca_count

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "pavo-cell-root-ca"
      namespace = local.private_ca_namespace
    }
    spec = {
      isCA        = true
      commonName  = "pavo-cell-root-ca-${var.eks_cluster_name}"
      secretName  = local.private_ca_root_secret
      duration    = "175200h" # 20y — the trust anchor; long-lived by design.
      renewBefore = "17520h"  # 2y
      privateKey = {
        algorithm      = "ECDSA"
        size           = 256
        rotationPolicy = "Never" # never auto-rotate the trust-anchor key.
      }
      issuerRef = {
        name  = "pavo-cell-selfsigned"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })

  # Match Ready by condition TYPE, not by array position. During issuance a
  # Certificate carries BOTH Ready and Issuing, and nothing guarantees their order
  # within status.conditions, so indexing [0] can read Issuing=True and return
  # while the cert is still being issued, leaving the next resource to read a
  # Secret that does not exist yet. Upstream on the Issuing condition: "It will be
  # removed by the 'issuing' controller upon completing issuance."
  # (cert-manager pkg/apis/certmanager/v1/types_certificate.go)
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.private_ca_selfsigned]
}

# 3. Root CA Issuer — a CA-type Issuer backed by the root Secret; its only job is
#    to sign the intermediate. (A Certificate is not an Issuer, so this object is
#    required to issue anything from the root.)
resource "kubectl_manifest" "private_ca_root_issuer" {
  count = local.private_ca_count

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata = {
      name      = "pavo-cell-root-issuer"
      namespace = local.private_ca_namespace
    }
    spec = { ca = { secretName = local.private_ca_root_secret } }
  })

  depends_on = [kubectl_manifest.private_ca_root]
}

# 4. Issuing intermediate CA — signs all leaf certs; may rotate normally under
#    the same root without touching the customer-installed trust anchor.
resource "kubectl_manifest" "private_ca_intermediate" {
  count = local.private_ca_count

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "pavo-cell-intermediate-ca"
      namespace = local.private_ca_namespace
    }
    spec = {
      isCA        = true
      commonName  = "pavo-cell-intermediate-ca-${var.eks_cluster_name}"
      secretName  = local.private_ca_int_secret
      duration    = "43800h" # 5y
      renewBefore = "4380h"  # 6mo
      privateKey  = { algorithm = "ECDSA", size = 256 }
      issuerRef = {
        name  = "pavo-cell-root-issuer"
        kind  = "Issuer"
        group = "cert-manager.io"
      }
    }
  })

  # Ready/Issuing race, see private_ca_root above.
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.private_ca_root_issuer]
}

# 5. The ClusterIssuer strict ingresses reference
#    (cert-manager.io/cluster-issuer: pavo-private-ca). Cluster-scoped, so it
#    reads the intermediate Secret from the cluster-resource namespace.
resource "kubectl_manifest" "private_ca_cluster_issuer" {
  count = local.private_ca_count

  server_side_apply = true
  force_conflicts   = true
  apply_only        = true

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = local.private_ca_cluster_issuer }
    spec       = { ca = { secretName = local.private_ca_int_secret } }
  })

  # ClusterIssuer only ever carries Ready, so position is unambiguous here. Use
  # the same form as the Certificates above rather than two idioms in one file.
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.private_ca_intermediate]
}

# Readiness gate (cell -> instance): published ONLY after the ClusterIssuer is
# actually Ready (wait_for above), never merely because Terraform submitted the
# manifests. The per-instance module reads this via data.aws_ssm_parameter and
# fails-fast if a network_posture=strict instance is created before the private CA
# exists — same cell->instance SSM "API" as eck_ready.
resource "aws_ssm_parameter" "private_ca_ready" {
  count = local.private_ca_count

  name  = "/pavo/cells/${var.eks_cluster_name}/private_ca_ready"
  type  = "String"
  value = "true"

  depends_on = [kubectl_manifest.private_ca_cluster_issuer]
}
