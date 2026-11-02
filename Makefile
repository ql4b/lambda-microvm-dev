# microvm-dev — workflow automation
#
# Mirrors the runbook in README.md. Run `source activate` first so AWS_PROFILE,
# AWS_REGION and the TF_VAR_* values from .env are in the environment.
#
# Packaging + upload is handled by Terraform (archive_file + aws_s3_object),
# so `make image` applies the config; there is no manual zip/upload step.
#
# Stateful targets (run/state/token/call/terminate) persist the running MicroVM's
# id and endpoint under .microvm/ so they can chain across make invocations.

SHELL := /bin/bash

INFRA_DIR  := infra
STATE_DIR  := .microvm
ID_FILE    := $(STATE_DIR)/microvm-id
ENDPOINT_FILE := $(STATE_DIR)/endpoint

# Lambda-managed network connectors (region comes from the environment).
REGION ?= $(AWS_REGION)
INGRESS := arn:aws:lambda:$(REGION):aws:network-connector:aws-network-connector:ALL_INGRESS
EGRESS  := arn:aws:lambda:$(REGION):aws:network-connector:aws-network-connector:INTERNET_EGRESS

# Idle Policy configuration
# When enabled, the idle policy controls automatic suspension and resumption.
# The presence of traffic through the MicroVM's endpoint signals activity.
# If no traffic arrives for the configured idle duration, the MicroVM is treated as idle and suspended.
# NOTE: For asynchronous applications that do not actively send or receive traffic through the endpoint,
# disable automatic suspension or configure a suitable idle duration.

# Idle policy — override individual fields, or replace IDLE_POLICY wholesale.
#   make run MAX_IDLE=60 SUSPENDED=120 AUTO_RESUME=false
#   make run IDLE_POLICY='{"autoResumeEnabled":true,"maxIdleDurationSeconds":10,"suspendedDurationSeconds":5}'

# When true, the MicroVM automatically resumes when traffic arrives at its endpoint while suspended.
AUTO_RESUME ?= true
# The number of seconds without traffic after which the MicroVM is suspended. Default: 15m Maximum: 28,800 (8 hours).
MAX_IDLE    ?= 900
# The number of seconds a MicroVM remains in the suspended state before Lambda terminates it. Default: 5m
SUSPENDED   ?= 300

IDLE_POLICY ?= {"autoResumeEnabled":$(AUTO_RESUME),"maxIdleDurationSeconds":$(MAX_IDLE),"suspendedDurationSeconds":$(SUSPENDED)}
TOKEN_MINUTES ?= 30

# Default state filter for `make list` (RUNNING; use STATE=ALL for everything).
STATE ?= RUNNING

# Lifecycle hooks config for `make hooks-enable` (port the app's hook server
# listens on + which hooks to enable). Override wholesale with HOOKS='{...}'.
HOOK_PORT ?= 9000
HOOKS ?= {"port":$(HOOK_PORT),"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":30},"microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":5,"resume":"ENABLED","resumeTimeoutInSeconds":5,"suspend":"ENABLED","suspendTimeoutInSeconds":5,"terminate":"ENABLED","terminateTimeoutInSeconds":5}}

# Optional per-VM payload delivered to the /run hook (runHookPayload).
RUN_PAYLOAD ?=

# Runtime log group for the MicroVM's application stdout/stderr. Defaults to
# /aws/lambda-microvms/<namespace>-<name>; override with LOG_GROUP=... .
LOG_GROUP ?= /aws/lambda-microvms/$(NAMESPACE)-$(NAME)
LOGGING   := {"cloudWatch":{"logGroup":"$(LOG_GROUP)"}}

# Terraform wrapper (uses pinned binary from .env if present, else `terraform`).
TF := $(if $(TERRAFORM_BIN),$(TERRAFORM_BIN),terraform)

.DEFAULT_GOAL := help

## help: show available targets
.PHONY: help
help:
	@echo "microvm-dev workflow — run 'source activate' first"
	@echo
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /' | column -t -s ':'

# --- infrastructure / image -------------------------------------------------

## init: terraform init
.PHONY: init
init:
	$(TF) -chdir=$(INFRA_DIR) init

## plan: preview infrastructure + image changes
.PHONY: plan
plan:
	$(TF) -chdir=$(INFRA_DIR) plan

## image: build/update the MicroVM image (packages app/, uploads, applies)
.PHONY: image
image:
	$(TF) -chdir=$(INFRA_DIR) apply

## image-info: show the current MicroVM image (arn, version, state)
.PHONY: image-info
image-info:
	$(TF) -chdir=$(INFRA_DIR) output -json microvm_image | jq

## logs: tail the MicroVM log group; pass extra args via LOG_ARGS="..."
# e.g. make logs LOG_ARGS="--follow --format short"
#      make logs LOG_ARGS="--since 3h"
.PHONY: logs
logs:
	aws logs tail $(LOG_GROUP) $(LOG_ARGS)

## hooks-enable: enable lifecycle hooks on the image (out-of-band; builds a new version)
# Re-submits the Terraform-managed image via update-microvm-image with --hooks.
# NOTE: the provider has no `hooks` attribute, so Terraform neither tracks nor
# detects this — a plain `tf apply` stays a no-op and PRESERVES the hooks.
# They are only dropped when Terraform re-submits the image for another reason
# (e.g. you edit app/ and code_artifact.uri changes); re-run this afterwards.
.PHONY: hooks-enable
hooks-enable:
	@set -e; \
	img=$$($(TF) -chdir=$(INFRA_DIR) output -raw microvm_image_arn); \
	base=$$($(TF) -chdir=$(INFRA_DIR) output -raw microvm_base_image_arn); \
	uri=$$($(TF) -chdir=$(INFRA_DIR) output -raw microvm_code_uri); \
	role=$$($(TF) -chdir=$(INFRA_DIR) output -raw build_role_arn); \
	echo "Enabling hooks on $$img (new version build) ..." >&2; \
	aws lambda-microvms update-microvm-image \
	  --image-identifier "$$img" \
	  --base-image-arn "$$base" \
	  --build-role-arn "$$role" \
	  --code-artifact "uri=$$uri" \
	  --cpu-configurations '[{"architecture":"ARM_64"}]' \
	  --hooks '$(HOOKS)' | jq

# --- MicroVM lifecycle ------------------------------------------------------

## run: run a MicroVM from the current image; saves id + endpoint locally
.PHONY: run
run: require-region
	@set -e; \
	if [ -f $(ID_FILE) ] && [ -z "$(FORCE)" ]; then \
	  existing=$$(cat $(ID_FILE)); \
	  state=$$(aws lambda-microvms get-microvm --microvm-identifier "$$existing" \
	    --query 'state' --output text 2>/dev/null || true); \
	  case "$$state" in \
	    ""|TERMINATED|TERMINATING) ;; \
	    *) echo "A MicroVM is already tracked: $$existing ($$state)." >&2; \
	       echo "  terminate it with 'make terminate', or re-run with FORCE=1 to launch another." >&2; \
	       exit 1 ;; \
	  esac; \
	fi; \
	mkdir -p $(STATE_DIR); \
	image_arn=$$($(TF) -chdir=$(INFRA_DIR) output -raw microvm_image_arn 2>/dev/null || true); \
	test -n "$$image_arn" || { \
	  echo "Could not read the image ARN from terraform outputs." >&2; \
	  echo "  - did you run 'source activate'?" >&2; \
	  echo "  - has the image been built?  run 'make image'" >&2; \
	  echo "  - check: $(TF) -chdir=$(INFRA_DIR) output microvm_image_arn" >&2; \
	  exit 1; \
	}; \
	echo "Running MicroVM from $$image_arn ..."; \
	exec_role_arn=$$($(TF) -chdir=$(INFRA_DIR) output -raw execution_role_arn 2>/dev/null || true); \
	test -n "$$exec_role_arn" || { \
	  echo "Could not read the execution role ARN (output 'execution_role_arn')." >&2; \
	  echo "  logging requires an execution role; run 'make image' to refresh outputs." >&2; \
	  exit 1; \
	}; \
	resp=$$(aws lambda-microvms run-microvm \
	  --image-identifier "$$image_arn" \
	  --execution-role-arn "$$exec_role_arn" \
	  --ingress-network-connectors "$(INGRESS)" \
	  --egress-network-connectors "$(EGRESS)" \
	  --logging '$(LOGGING)' \
	  $(if $(RUN_PAYLOAD),--run-hook-payload '$(RUN_PAYLOAD)',) \
	  --idle-policy '$(IDLE_POLICY)'); \
	echo "$$resp" | jq; \
	echo "$$resp" | jq -r '.microvmId' > $(ID_FILE); \
	echo "$$resp" | jq -r '.endpoint'  > $(ENDPOINT_FILE); \
	echo "Saved id -> $(ID_FILE), endpoint -> $(ENDPOINT_FILE)"

## state: fetch the running MicroVM's current state
.PHONY: state
state: require-id
	@aws lambda-microvms get-microvm \
	  --microvm-identifier "$$(cat $(ID_FILE))" | jq

## suspend: suspend the tracked MicroVM (RUNNING -> SUSPENDED)
.PHONY: suspend
suspend: require-id
	@aws lambda-microvms suspend-microvm \
	  --microvm-identifier "$$(cat $(ID_FILE))" | jq

## resume: resume the tracked MicroVM (SUSPENDED -> RUNNING)
.PHONY: resume
resume: require-id
	@aws lambda-microvms resume-microvm \
	  --microvm-identifier "$$(cat $(ID_FILE))" | jq

## token: mint an auth token (TOKEN_MINUTES, default 30); prints the token
.PHONY: token
token: require-id
	@aws lambda-microvms create-microvm-auth-token \
	  --microvm-identifier "$$(cat $(ID_FILE))" \
	  --expiration-in-minutes $(TOKEN_MINUTES) \
	  --allowed-ports '[{"allPorts":{}}]' \
	  | jq -r '.authToken."X-aws-proxy-auth"'

## call: curl the running MicroVM endpoint (mints a short-lived token)
.PHONY: call
call: require-id
	@set -e; \
	endpoint=$$(cat $(ENDPOINT_FILE)); \
	token=$$(aws lambda-microvms create-microvm-auth-token \
	  --microvm-identifier "$$(cat $(ID_FILE))" \
	  --expiration-in-minutes 5 \
	  --allowed-ports '[{"allPorts":{}}]' \
	  | jq -r '.authToken."X-aws-proxy-auth"'); \
	echo "GET https://$$endpoint/" >&2; \
	curl -sS -D /dev/stderr -H "X-aws-proxy-auth: $$token" "https://$$endpoint/"; \
	echo

## terminate: terminate the tracked MicroVM (or MICROVM=<id>) and clear local state
.PHONY: terminate
terminate:
	@set -e; \
	id="$(MICROVM)"; \
	if [ -z "$$id" ]; then \
	  if [ ! -f $(ID_FILE) ]; then \
	    echo "No tracked MicroVM ($(ID_FILE) missing). Pass MICROVM=<id> to terminate a specific one." >&2; \
	    exit 1; \
	  fi; \
	  id=$$(cat $(ID_FILE)); \
	fi; \
	aws lambda-microvms terminate-microvm --microvm-identifier "$$id" | jq; \
	if [ -f $(ID_FILE) ] && [ "$$id" = "$$(cat $(ID_FILE))" ]; then \
	  rm -f $(ID_FILE) $(ENDPOINT_FILE); \
	  echo "Terminated $$id and cleared local state."; \
	else \
	  echo "Terminated $$id."; \
	fi

## list: list MicroVMs (RUNNING by default; STATE=ALL or STATE=<state> to filter)
.PHONY: list
list:
	@aws lambda-microvms list-microvms \
	  | jq -r --arg s "$(STATE)" \
	    '.items | map(select($$s=="ALL" or .state==$$s)) \
	      | (["MICROVM_ID","STATE","IMAGE_VERSION","STARTED_AT"], \
	         (.[] | [.microvmId,.state,.imageVersion,.startedAt])) | @tsv' \
	  | column -t

# --- guards -----------------------------------------------------------------

.PHONY: require-id
require-id:
	@if [ ! -f $(ID_FILE) ]; then \
	  echo "No running MicroVM recorded ($(ID_FILE) missing). Run 'make run' first." >&2; \
	  exit 1; \
	fi

.PHONY: require-region
require-region:
	@if [ -z "$(REGION)" ]; then \
	  echo "AWS_REGION is not set. Run 'source activate' first." >&2; \
	  exit 1; \
	fi
