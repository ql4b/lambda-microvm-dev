output "env" {
  value = {
    profile    = local.profile
    region     = local.region
    namespace  = module.label.namespace
    name       = module.label.name
    id         = module.label.id
    account_id = local.account_id
  }
}

output "artifacts_bucket" {
  value = {
    id          = module.artifacts_bucket.bucket_id
    arn         = module.artifacts_bucket.bucket_arn
    region      = module.artifacts_bucket.bucket_region
    domain_name = module.artifacts_bucket.bucket_domain_name
  }
}

output "lambda_role" {
  value = {
    name = module.lambda_role.name
    arn  = module.lambda_role.arn
    id   = module.lambda_role.id
  }
}

# Flat string output for scripting (used by the Makefile `run` target as the
# MicroVM execution role — required when runtime logging is enabled).
output "lambda_role_arn" {
  value = module.lambda_role.arn
}

output "execution_role" {
  value = {
    name = module.execution_role.name
    arn  = module.execution_role.arn
    id   = module.execution_role.id
  }
}

# Flat string output: the MicroVM execution role ARN (passed to run-microvm
# as --execution-role-arn; required when runtime logging is enabled).
output "execution_role_arn" {
  value = module.execution_role.arn
}

output "microvm_image" {
  value = {
    arn           = aws_lambdamicrovms_image.app.arn
    name          = aws_lambdamicrovms_image.app.name
    image_version = aws_lambdamicrovms_image.app.image_version
    state         = aws_lambdamicrovms_image.app.state
  }
}

# Flat string output for scripting (used by the Makefile `run` target).
output "microvm_image_arn" {
  value = aws_lambdamicrovms_image.app.arn
}
