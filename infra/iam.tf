# IAM role that Lambda MicroVMs assumes at image BUILD time to read microVM
# artifacts from the artifacts bucket and write build logs to CloudWatch.

data "aws_iam_policy_document" "lambda_artifacts" {
  statement {
    sid       = "ReadArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.artifacts_bucket.bucket_arn}/*"]
  }

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

module "lambda_role" {
  source  = "cloudposse/iam-role/aws"
  version = "1.0.0"

  context    = module.label.context
  attributes = ["lambda", "build"]

  # Trust policy: only the Lambda service may assume this role.
  principals = {
    Service = ["lambda.amazonaws.com"]
  }
  assume_role_actions = ["sts:AssumeRole", "sts:TagSession"]

  # Inline least-privilege policy (S3 GetObject + CloudWatch Logs).
  role_description   = "Build role for microVM images (read artifacts, write build logs)"
  policy_description = "Allow Lambda to read microVM artifacts and write logs"
  policy_documents   = [data.aws_iam_policy_document.lambda_artifacts.json]
}
