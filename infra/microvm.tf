# Lambda MicroVM image built from an app zip (Dockerfile at root) in the
# artifacts bucket.
#
# NOTE: for now the code artifact is HARDCODED — assume app.zip has been
# zipped and uploaded to the artifacts bucket manually
# (e.g. `aws s3 cp ./app.zip s3://<artifacts-bucket>/app.zip --sse AES256`).
# Later this gets wired to an automated package+upload step.

data "aws_region" "current" {}

locals {
  # Managed base image published by Lambda MicroVMs (Amazon Linux 2023).
  microvm_base_image_arn = "arn:aws:lambda:${data.aws_region.current.region}:aws:microvm-image:al2023-1"

  # Hardcoded for now — manually uploaded artifact.
  microvm_code_uri = "s3://${module.artifacts_bucket.bucket_id}/app.zip"
}

resource "aws_lambdamicrovms_image" "app" {
  name           = module.label.id
  base_image_arn = local.microvm_base_image_arn

  # Build role: reads the artifact from S3 and writes build logs.
  build_role_arn = module.lambda_role.arn

  code_artifact {
    uri = local.microvm_code_uri
  }

  # Explicit even though it's the only/default value today.
  cpu_configuration {
    architecture = "ARM_64"
  }

  description = "microVM image for ${module.label.id}"
  tags        = module.label.tags
}
