# The per-cell OpenTofu provider-mirror bucket is no longer consumed: cells install
# providers from Pavo's artifact-plane mirror. Forget the bucket without deleting
# it (it may hold objects). Manual cleanup after the apply:
#   aws s3 rb "s3://pavo-tf-mirror-<cluster>" --force
# Drop this file once every consumer is past v0.7.0.

removed {
  from = aws_s3_bucket.provider_mirror
  lifecycle { destroy = false }
}

removed {
  from = aws_s3_bucket_server_side_encryption_configuration.provider_mirror
  lifecycle { destroy = false }
}

removed {
  from = aws_s3_bucket_public_access_block.provider_mirror
  lifecycle { destroy = false }
}

removed {
  from = aws_s3_bucket_policy.provider_mirror
  lifecycle { destroy = false }
}
