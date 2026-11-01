#!/bin/bash

ROOT_PATH=$(realpath $(dirname "$0"))
INFRA_PATH="$ROOT_PATH/infra"
ENV_FILENAME="$ROOT_PATH/.env"

# echo "ROOT_PATH:$ROOT_PATH" >&2
# echo "INFRA_PATH:$INFRA_PATH" >&2
# echo "INFRA_PATH:$ENV_FILENAME" >&2

set -a
. $ENV_FILENAME
set +a

"$TERRAFORM_BIN" -chdir=$INFRA_PATH \
  "$@"
