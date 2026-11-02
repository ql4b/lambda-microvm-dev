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
  * [Lifecycle hooks](#lifecycle-hooks)
* [Workflow](#workflow)

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

> Use `terraform output -json microvm_image | jq` to get the current image ARN.

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
make hooks-enable    # enable lifecycle hooks on the image (out-of-band)
make logs            # tail the MicroVM log group (LOG_ARGS="--follow ...")

make run             # run a MicroVM (refuses if one is already tracked; FORCE=1 to override)
make state           # get the running MicroVM's state
make suspend         # suspend the tracked MicroVM (RUNNING -> SUSPENDED)
make resume          # resume the tracked MicroVM (SUSPENDED -> RUNNING)
make list            # list MicroVMs (RUNNING by default; STATE=ALL for all)
make token           # mint an auth token (TOKEN_MINUTES=30 by default)
make call            # curl the endpoint (mints a short-lived token)
make terminate       # terminate the tracked MicroVM (or MICROVM=<id>) + clear state
```

The lifecycle targets are stateful: `make run` records the `microvmId` and
`endpoint` in a gitignored `.microvm/` directory, so `state`, `token`, `call`
and `terminate` operate on it without passing IDs around. `make run` refuses if
`AWS_REGION` isn't set (i.e. you forgot `source activate`), and also refuses if
a tracked MicroVM is still live — pass `FORCE=1` to launch another anyway, or
`make terminate` the current one first. `make terminate MICROVM=<id>` terminates
a specific MicroVM (handy for orphans shown by `make list`); it only clears the
local `.microvm/` state when that id matches the tracked one.

`make run`'s idle policy is overridable — tweak a single field or replace the
whole blob:

```bash
make run MAX_IDLE=60                        # maxIdleDurationSeconds
make run AUTO_RESUME=false SUSPENDED=120    # autoResumeEnabled + suspendedDurationSeconds
make run IDLE_POLICY='{"autoResumeEnabled":true,"maxIdleDurationSeconds":10,"suspendedDurationSeconds":5}'
```

Likewise `LOG_GROUP=` overrides the runtime log group and `TOKEN_MINUTES=`
the auth-token lifetime.

`make run` enables runtime logging: it reads the execution role ARN from the
`execution_role_arn` Terraform output and passes it as `--execution-role-arn`
alongside `--logging` (required together). App logs go to
`/aws/lambda-microvms/<namespace>-<name>`; override the group with
`make run LOG_GROUP=/my/group` (the execution role's permissions are scoped to
the default group, so a custom group may need the policy widened).

### Lifecycle hooks

Reference: [microvms-launching-lifecycle-hooks](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html#microvms-launching-lifecycle-hooks)

The app (`app/app.js`) runs a second HTTP server on port `9000` that answers the
MicroVM lifecycle hook paths (`/aws/lambda-microvms/runtime/v1/{ready,validate,
run,resume,suspend,terminate}`), logs each call, and returns `200`. Hooks let the
app react to build/run/suspend/resume/terminate transitions.

Enable them on the image (then exercise and observe via the logs):

```bash
make hooks-enable                          # re-submit the image with --hooks (new version)
make run RUN_PAYLOAD='{"session":"abc"}'   # /run fires with this payload
make suspend                               # /suspend fires
make resume                                # /resume fires
make terminate                             # /terminate fires
make logs LOG_ARGS="--since 15m"           # each hook logs a line
```

Notes:

* **`RUN_PAYLOAD` requires hooks** — `run-microvm` rejects a `runHookPayload`
  unless the image has the `run` hook enabled (run `make hooks-enable` first),
  otherwise: `ValidationException: The run hook must be enabled ...`.
* **Enabling any runtime hook requires `/ready`** — the default `HOOKS` config
  enables it; the app answers it, so the build succeeds.
* **Out-of-band, by necessity.** The Terraform provider's
  `aws_lambdamicrovms_image` has no `hooks`/`logging`/`resources` arguments yet
  ([hashicorp/terraform-provider-aws#49821](https://github.com/hashicorp/terraform-provider-aws/issues/49821)),
  so hooks are applied with `update-microvm-image`. Terraform doesn't track
  them: a no-op `tf apply` preserves them, but a rebuild driven by a changed
  `code_artifact.uri` (i.e. editing `app/`) resets them to null — re-run
  `make hooks-enable` after such a rebuild.

Typical loop:

```bash
make image && make run && make call
# ... iterate on app/ ...
make image && make run && make call
make terminate
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
   make terminate
   ```

Iterating on the app is just steps 1–3 again (`make image && make run && make
call`).
