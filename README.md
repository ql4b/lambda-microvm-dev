# microvm-dev

A workspace to experiment with AWS Lambda MicroVMs — Firecracker-isolated,
snapshot-resumable compute environments that run a container inside a microVM.

* AWS guide: https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html
* Getting started: https://docs.aws.amazon.com/lambda/latest/dg/microvms-getting-started.html

## What's here

```
.
├── app/            # the application packaged into the MicroVM image
│   ├── app.js      #   minimal Node HTTP server on :8080
│   ├── Dockerfile  #   FROM node:24-alpine — the container base image
│   └── app.zip     #   built artifact (Dockerfile + app), uploaded to S3
└── infra/          # Terraform: the AWS resources behind the workflow below
```

### How the pieces fit

A MicroVM image is built from two independent layers:

* **Container base image** — your `Dockerfile`'s `FROM` (here `node:24-alpine`).
  This is what your app runs on inside the MicroVM.
* **Managed base image** — the Lambda-managed MicroVM platform layer
  (`arn:aws:lambda:<region>:aws:microvm-image:al2023-1`), supplied separately
  as `base_image_arn`. It provides the Firecracker snapshot/boot/resume
  machinery and the MicroVM OS environment.

Lambda compiles the `Dockerfile` on top of the managed base, boots the app,
and captures a snapshot. `run-microvm` launches instances from that snapshot.

## Infrastructure (`infra/`)

Terraform provisions, using Cloud Posse modules and the `null-label` naming
convention (`<namespace>-<name>-<attributes>`):

| Resource | File | Purpose |
|---|---|---|
| S3 bucket (`…-artifacts`) | `artifacts.tf` | Stores the zipped app artifact. Private, versioned, SSE-AES256, encrypted-uploads-only. |
| IAM build role (`…-lambda-build`) | `iam.tf` | Assumed by Lambda MicroVMs at **image build** time. Trust: `lambda.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`). Permissions: `s3:GetObject` on the bucket + CloudWatch Logs. |
| MicroVM image (`aws_lambdamicrovms_image`) | `microvm.tf` | Built from the S3 artifact + managed base image, CPU arch `ARM_64`. |

> **Note:** `microvm.tf` currently **hardcodes** the artifact key as
> `app.zip` and assumes it was zipped and uploaded manually (see below).
> This gets wired to an automated package+upload step later.

### Provision

```bash
cd infra
terraform init
terraform apply   # creates the bucket and build role first
```

> Per the repo's IaC delivery rule, applies in a shared/graduated stack go
> through the environment branch, not a local working copy. For this dev
> stack (local state, no traffic) a hand-apply from a pushed PR is fine.

## Prerequisites

* Terraform `~> 1.15`, AWS provider `~> 6.71`
* AWS credentials with permission to create S3/IAM/Lambda-MicroVM resources
  (set `AWS_REGION`, or a profile)
* `aws` CLI with Lambda MicroVMs support, plus `jq`
* The MicroVM artifact bucket and image must be in the **same region**

> The account IDs, ARNs, endpoints and tokens in the examples below are from a
> real run and are illustrative — substitute your own. Use
> `terraform output -json microvm_image | jq` to get the current image ARN.

## Workflow (getting-started)

### Package and upload artifact

```bash
cd app
zip app.zip app.js Dockerfile
aws s3 cp app.zip s3://ql4b-microvm-dev-artifacts/app.zip --sse AES256
```

> The `--sse AES256` flag is required: the bucket policy denies uploads that
> don't request server-side encryption. The object key must be `app.zip` to
> match the hardcoded `code_artifact.uri` in `infra/microvm.tf`.

### Fetch MicroMV Image 

```bash
tf output -json microvm_image | jq
```

### Run microVM

```bash
aws lambda-microvms run-microvm \
  --image-identifier arn:aws:lambda:us-east-1:123456789012:microvm-image:ql4b-microvm-dev  \
  --ingress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS" \
  --egress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
  --idle-policy '{"autoResumeEnabled":true,"maxIdleDurationSeconds":900,"suspendedDurationSeconds":300}'
```

```bash
{
    "microvmId": "microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "state": "PENDING",
    "endpoint": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.lambda-microvm.us-east-1.on.aws",
    "imageArn": "arn:aws:lambda:us-east-1:123456789012:microvm-image:ql4b-microvm-dev",
    "imageVersion": "1.0",
    "idlePolicy": {
        "maxIdleDurationSeconds": 900,
        "suspendedDurationSeconds": 300,
        "autoResumeEnabled": true
    },
    "maximumDurationInSeconds": 28800,
    "startedAt": "2026-11-01T22:02:27.861000+01:00",
    "ingressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
    ],
    "egressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
    ]
}
```

### Fetch MicroMV state 

```bash
aws lambda-microvms get-microvm \
  --microvm-identifier  microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

```bash
{
    "microvmId": "microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "state": "RUNNING",
    "endpoint": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.lambda-microvm.us-east-1.on.aws",
    "imageArn": "arn:aws:lambda:us-east-1:123456789012:microvm-image:ql4b-microvm-dev",
    "imageVersion": "1.0",
    "idlePolicy": {
        "maxIdleDurationSeconds": 900,
        "suspendedDurationSeconds": 300,
        "autoResumeEnabled": true
    },
    "maximumDurationInSeconds": 28800,
    "startedAt": "2026-11-01T22:02:27.861000+01:00",
    "ingressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
    ],
    "egressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
    ]
}
```

### Create Auth Token

```bash
aws lambda-microvms create-microvm-auth-token   \
    --microvm-identifier  microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  --expiration-in-minutes 30   \
    --allowed-ports '[{"allPorts":{}}]'
```

```bash 
curl -sS -H 'X-aws-proxy-auth:  <auth-token>' \
    https://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.lambda-microvm.us-east-1.on.aws
```

```bash
{
  "status": "ok",
  "path": "/"
}
```

### Cleanup

```bash
aws lambda-microvms terminate-microvm \
  --microvm-identifier  microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx 
```
```bash
aws lambda-microvms get-microvm \
  --microvm-identifier  microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

```bash
{
    "microvmId": "microvm-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "state": "TERMINATED",
    "endpoint": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.lambda-microvm.us-east-1.on.aws",
    "imageArn": "arn:aws:lambda:us-east-1:123456789012:microvm-image:ql4b-microvm-dev",
    "imageVersion": "1.0",
    "idlePolicy": {
        "maxIdleDurationSeconds": 900,
        "suspendedDurationSeconds": 300,
        "autoResumeEnabled": true
    },
    "maximumDurationInSeconds": 28800,
    "startedAt": "2026-11-01T22:02:27.861000+01:00",
    "terminatedAt": "2026-11-01T22:18:58.297000+01:00",
    "stateReason": "Success.",
    "ingressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS"
    ],
    "egressNetworkConnectors": [
        "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS"
    ]
}
```
