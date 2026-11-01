# Lambda MicroVM image built from the app/ source (Dockerfile at root).
#
# Packaging is handled in-config (mirrors the ql4b terraform-aws-lambda-function
# module): archive_file zips app/ at plan time, aws_s3_object uploads it to the
# artifacts bucket (versioned), and the image's code_artifact pins the object
# version. Changing the source produces a new object version, which the
# provider applies as an in-place UpdateMicrovmImage (new image version).

data "aws_region" "current" {}

locals {
  # Managed base image published by Lambda MicroVMs (Amazon Linux 2023).
  microvm_base_image_arn = "arn:aws:lambda:${data.aws_region.current.region}:aws:microvm-image:al2023-1"

  # Source dir containing app.js + Dockerfile.
  app_source_dir = "${path.module}/../app"
  artifact_key   = "app.zip"
}

# Zip the app source at plan time.
data "archive_file" "app" {
  type        = "zip"
  output_path = "${path.module}/.terraform/tmp/${module.label.id}.zip"

  source_dir = local.app_source_dir
  excludes   = ["app.zip"] # don't zip a previously-built artifact into itself
}

# Upload the packaged artifact to the artifacts bucket.
resource "aws_s3_object" "app" {
  bucket = module.artifacts_bucket.bucket_id
  key    = local.artifact_key
  source = data.archive_file.app.output_path

  # Content-addressed: changes when the source changes, triggering re-upload.
  etag = data.archive_file.app.output_md5

  # Bucket policy requires SSE on upload.
  server_side_encryption = "AES256"
}

resource "aws_lambdamicrovms_image" "app" {
  name           = module.label.id
  base_image_arn = local.microvm_base_image_arn

  # Build role: reads the artifact from S3 and writes build logs.
  build_role_arn = module.lambda_role.arn

  code_artifact {
    # Pin to the uploaded object version. When the app source changes,
    # aws_s3_object.app gets a new version_id, the URI changes, and the
    # provider issues UpdateMicrovmImage — which builds a NEW image version
    # in place (major bump: 1.0 -> 2.0 -> ...), keeping the same image ARN,
    # instead of destroying and recreating.
    uri = "s3://${aws_s3_object.app.bucket}/${aws_s3_object.app.key}?versionId=${aws_s3_object.app.version_id}"
  }

  # Explicit even though it's the only/default value today.
  cpu_configuration {
    architecture = "ARM_64"
  }

  description = "microVM image for ${module.label.id}"
  tags        = module.label.tags
}
