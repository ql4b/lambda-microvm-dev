# microvm-dev — workflow automation
#
# Mirrors the runbook in README.md. Run `source activate` first so AWS_PROFILE,
# AWS_REGION and the TF_VAR_* values from .env are in the environment.
#
# Packaging + upload is handled by Terraform (archive_file + aws_s3_object),
# so `make image` applies the config; there is no manual zip/upload step.
#
# Stateful targets (run/state/token/call/clean) persist the running MicroVM's
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
IDLE_POLICY := {"autoResumeEnabled":true,"maxIdleDurationSeconds":900,"suspendedDurationSeconds":300}
TOKEN_MINUTES ?= 30

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

# --- MicroVM lifecycle ------------------------------------------------------

## run: run a MicroVM from the current image; saves id + endpoint locally
.PHONY: run
run: require-region
	@set -e; \
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
	echo "GET https://$$endpoint/"; \
	curl -sS -H "X-aws-proxy-auth: $$token" "https://$$endpoint/"; \
	echo

## clean: terminate the running MicroVM and remove local state
.PHONY: clean
clean: require-id
	@set -e; \
	id=$$(cat $(ID_FILE)); \
	aws lambda-microvms terminate-microvm --microvm-identifier "$$id" | jq; \
	rm -f $(ID_FILE) $(ENDPOINT_FILE); \
	echo "Terminated $$id and cleared local state."

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
