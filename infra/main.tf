module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = local.namespace
  name      = local.name
}

data "aws_caller_identity" "current" {}

locals {
  profile    = var.profile
  region     = var.region
  identity   = data.aws_caller_identity.current
  account_id = local.identity.account_id
  name       = var.name
  namespace  = var.namespace
  id         = module.label.id
  # prefixes
  ssm_prefix = "${"/"}${join("/", compact([
    module.label.namespace != "" ? module.label.namespace : null,
    module.label.name != "" ? module.label.name : null
  ]))}"
  pascal_prefix = replace(title(module.label.id), "/\\W+/", "")
}

