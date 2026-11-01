# microvm-dev

A workspace to experiment with AWS Lambda MicroVMs — Firecracker-isolated,
snapshot-resumable compute environments that run a container inside a microVM.

* AWS guide: https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html
* Getting started: https://docs.aws.amazon.com/lambda/latest/dg/microvms-getting-started.html

## Contents

* [What's here](#whats-here)
  * [How the pieces fit](#how-the-pieces-fit)
* [Infrastructure (`infra/`)](#infrastructure-infra)
  * [Provision](#provision)
* [Prerequisites](#prerequisites)
* [Using the Makefile](#using-the-makefile)
* [Workflow](#workflow)
* [Workflow — raw CLI (getting-started reference)](#workflow--raw-cli-getting-started-reference)
  * [Package and upload artifact](#package-and-upload-artifact-now-handled-by-make-image)
  * [Fetch MicroMV Image](#fetch-micromv-image)
  * [Run microVM](#run-microvm)
  * [Fetch MicroMV state](#fetch-micromv-state)
  * [Create Auth Token](#create-auth-token)
  * [Cleanup](#cleanup)

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
| IAM execution role (`…-microvm-exec`) | `iam.tf` | Assumed by the **running MicroVM** at runtime. Trust: `lambda.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`). Permissions: CloudWatch Logs scoped to the runtime log group. Required when runtime logging is enabled. |
| MicroVM image (`aws_lambdamicrovms_image`) | `microvm.tf` | Built from the S3 artifact + managed base image, CPU arch `ARM_64`. |

> **Packaging is in Terraform.** `microvm.tf` zips `app/` (`archive_file`) and
> uploads it (`aws_s3_object`) on `apply` — no manual zip/upload needed. The
> `code_artifact.uri` pins the uploaded object's `versionId`, so changing the
> app source triggers an in-place image rebuild (a new image version, major
> bump `1.0 → 2.0 → …`) rather than a destroy/recreate.

> **Logging.** Two CloudWatch streams, both under
> `/aws/lambda-microvms/<namespace>-<name>` (e.g.
> `/aws/lambda-microvms/ql4b-microvm-dev`):
> *build logs* (image creation, written via the build role) and *runtime logs*
> (the app's stdout/stderr). Runtime logging is enabled on `run-microvm`
> (`--logging`), which **requires** an execution role — hence the
> `…-microvm-exec` role above. Tail with
> `aws logs tail /aws/lambda-microvms/ql4b-microvm-dev --follow`.

### Provision

```bash
source ./activate   # loads .env and puts the `tf` wrapper on PATH
tf init
tf apply            # creates the bucket, build role, execution role, image
```

> `tf` is a thin wrapper (on PATH after `source ./activate`) that runs
> `terraform -chdir=infra` with `.env` loaded — so run it from the repo root,
> no `cd infra` needed.

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

## Using the Makefile

A `Makefile` at the repo root wraps the whole workflow. Load the environment
first (`source activate` reads `.env`: `AWS_PROFILE`, `AWS_REGION`, the
`TF_VAR_*` values), then drive everything with `make`:

```bash
source activate      # sets AWS_PROFILE / AWS_REGION / TF_VAR_* from .env
make help            # list all targets

make init            # terraform init
make plan            # preview infra + image changes
make image           # terraform apply: package app/, upload, build/update image
make image-info      # show the current image (arn, version, state)
make logs            # tail the MicroVM log group (LOG_ARGS="--follow ...")

make run             # run a MicroVM (refuses if one is already tracked; FORCE=1 to override)
make state           # get the running MicroVM's state
make suspend         # suspend the tracked MicroVM (RUNNING -> SUSPENDED)
make resume          # resume the tracked MicroVM (SUSPENDED -> RUNNING)
make list            # list MicroVMs (RUNNING by default; STATE=ALL for all)
make token           # mint an auth token (TOKEN_MINUTES=30 by default)
make call            # curl the endpoint (mints a short-lived token)
make clean           # terminate the tracked MicroVM (or MICROVM=<id>) + clear state
```

The lifecycle targets are stateful: `make run` records the `microvmId` and
`endpoint` in a gitignored `.microvm/` directory, so `state`, `token`, `call`
and `clean` operate on it without passing IDs around. `make run` refuses if
`AWS_REGION` isn't set (i.e. you forgot `source activate`), and also refuses if
a tracked MicroVM is still live — pass `FORCE=1` to launch another anyway, or
`make clean` the current one first. `make clean MICROVM=<id>` terminates a
specific MicroVM (handy for orphans shown by `make list`); it only clears the
local `.microvm/` state when that id matches the tracked one.

`make run` enables runtime logging: it reads the execution role ARN from the
`execution_role_arn` Terraform output and passes it as `--execution-role-arn`
alongside `--logging` (required together). App logs go to
`/aws/lambda-microvms/<namespace>-<name>`; override the group with
`make run LOG_GROUP=/my/group` (the execution role's permissions are scoped to
the default group, so a custom group may need the policy widened).

Typical loop:

```bash
make image && make run && make call
# ... iterate on app/ ...
make image && make run && make call
make clean
```

## Workflow

The end-to-end loop, using the `make` targets. Run `source ./activate` once per
shell first.

1. **Build / update the image** — package `app/`, upload, and build (or rebuild)
   the MicroVM image:

   ```bash
   make image
   make image-info        # arn, version, state
   ```

2. **Run a MicroVM** — launch an instance from the current image (with runtime
   logging + execution role wired in automatically); the id and endpoint are
   saved under `.microvm/`:

   ```bash
   make run
   make state             # poll until state is RUNNING
   ```

3. **Call it** — hit the endpoint (mints a short-lived auth token for you):

   ```bash
   make call | jq
   # {
   #   "status": "ok",
   #   "path": "/",
   #   "microvm": { "image_name": "ql4b-microvm-dev", "image_version": "3.0" }
   # }
   ```

   The `GET <url>` banner prints to stderr, so piping stdout to `jq` parses the
   response cleanly (use `make call 2>/dev/null | jq` to hide the banner too).
   Need a longer-lived token (e.g. for your own `curl`)? `make token`.

4. **Inspect logs** — application stdout/stderr (and build logs) in CloudWatch.
   `make logs` tails the log group; append CLI flags via `LOG_ARGS`:

   ```bash
   make logs                                    # tail recent events
   make logs LOG_ARGS="--follow"                # live tail
   make logs LOG_ARGS="--since 3h --format short"
   ```

5. **Tear down** — terminate the MicroVM and clear local state:

   ```bash
   make clean
   ```

Iterating on the app is just steps 1–3 again (`make image && make run && make
call`). The next section shows the raw `aws` commands each target runs, for
reference / the getting-started phase.

## Workflow — raw CLI (getting-started reference)

> These are the underlying `aws` / `terraform` commands the `make` targets run.
> For day-to-day use prefer the Makefile targets above; this section is kept as
> a getting-started reference and for one-off debugging. Packaging (the first
> step) is now done by `make image` / `tf apply`, not by hand.

### Package and upload artifact (now handled by `make image`)

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
  --execution-role-arn arn:aws:iam::123456789012:role/ql4b-microvm-dev-microvm-exec \
  --ingress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:ALL_INGRESS" \
  --egress-network-connectors "arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS" \
  --logging '{"cloudWatch":{"logGroup":"/aws/lambda-microvms/ql4b-microvm-dev"}}' \
  --idle-policy '{"autoResumeEnabled":true,"maxIdleDurationSeconds":900,"suspendedDurationSeconds":300}'
```

> `--logging` requires `--execution-role-arn`; the running MicroVM assumes that
> role to write its application logs.

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
