# =============================================================================
# Artifact-plane image pins for cell Helm / observability workloads
# =============================================================================
# mirrored-images.json is the input the artifact-plane publish workflow already
# mirrors into
#   <registry>/<prefix>/<upstream-host>/<path>@<digest>
# (ECR stores by digest). This module must consume those pins in helm_release
# values and the Grafana Postgres image. Leaving them out rewrites a no-NAT
# cell back to public registries (ghcr.io, docker.elastic.co, oci.external-secrets.io)
# and helm_release wait=true hangs on ImagePullBackOff.
#
# Chart keys differ (repository+tag vs registry+sha vs name+tag). The shapes
# below match the values this module previously applied on a private cell.

locals {
  mirrored_images_manifest = jsondecode(file("${path.module}/mirrored-images.json"))
  artifact_plane           = "${local.mirrored_images_manifest.registry}/${local.mirrored_images_manifest.prefix}"

  mirrored = {
    for name, img in local.mirrored_images_manifest.images : name => {
      registry         = local.mirrored_images_manifest.registry
      split_repository = "${local.mirrored_images_manifest.prefix}/${img.repository}"
      repository       = "${local.artifact_plane}/${img.repository}"
      tag              = img.tag
      digest           = img.digest
      digest_hex       = trimprefix(img.digest, "sha256:")
      tag_at_digest    = "${img.tag}@${img.digest}"
      pull             = "${local.artifact_plane}/${img.repository}:${img.tag}@${img.digest}"
    }
  }
}
