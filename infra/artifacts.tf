# S3 bucket for microVM artifacts (kernels, rootfs images, etc.).
module "artifacts_bucket" {
  source  = "cloudposse/s3-bucket/aws"
  version = "4.15.0"

  context    = module.label.context
  attributes = ["artifacts"]

  # Private, owner-only; block all public access.
  acl                     = "private"
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  # Keep history of artifacts and encrypt at rest.
  versioning_enabled           = true
  sse_algorithm                = "AES256"
  bucket_key_enabled           = true
  allow_encrypted_uploads_only = true

  # Guard against accidental deletion of a non-empty bucket.
  force_destroy = false
}
