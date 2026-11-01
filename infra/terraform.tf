# You cannot create a new backend by simply defining this and then
# immediately proceeding to "terraform apply". The S3 backend must
# be bootstrapped according to the simple yet essential procedure in
# https://github.com/cloudposse/terraform-aws-tfstate-backend#usage
module "terraform_state_backend" {
  source  = "cloudposse/tfstate-backend/aws"
  version = "1.9.0"
  enabled = false

  profile = local.profile

  namespace  = module.label.namespace
  name       = module.label.name
  attributes = ["tfstate"]

  # S3 native state locking (use_lockfile) — the current strategy.
  # Requires Terraform >= 1.10 (satisfied by required_version ~> 1.12).
  # Replaces the deprecated DynamoDB lock table.
  s3_state_lock_enabled = true
  dynamodb_enabled      = false

  terraform_backend_config_file_path = "."
  terraform_backend_config_file_name = "backend.tf"
  force_destroy                      = true
}