#!/bin/bash
set -euo pipefail

# this script is a helper that allows us to set ENV vars
# based on which terraform directory we're using

# Set DEPLOY_ENV based on the input directory
case "$1" in
  terraform/core)
    DEPLOY_ENV=core
    AWS_ACCESS_KEY_ID="${CI_CORE_AWS_ACCESS_KEY_ID}"
    AWS_SECRET_ACCESS_KEY="${CI_CORE_AWS_SECRET_ACCESS_KEY}"
    ;;
  terraform/platform)
    # platform's AWS resources live in the core account
    DEPLOY_ENV=platform
    AWS_ACCESS_KEY_ID="${CI_CORE_AWS_ACCESS_KEY_ID}"
    AWS_SECRET_ACCESS_KEY="${CI_CORE_AWS_SECRET_ACCESS_KEY}"
    ;;
  terraform/prod-1)
    DEPLOY_ENV=prod
    AWS_ACCESS_KEY_ID="${CI_PROD_AWS_ACCESS_KEY_ID}"
    AWS_SECRET_ACCESS_KEY="${CI_PROD_AWS_SECRET_ACCESS_KEY}"
    ;;
  terraform/stage-1)
    DEPLOY_ENV=stage
    AWS_ACCESS_KEY_ID="${CI_STAGE_AWS_ACCESS_KEY_ID}"
    AWS_SECRET_ACCESS_KEY="${CI_STAGE_AWS_SECRET_ACCESS_KEY}"
    ;;
  *)
    echo "Unknown environment: $1"
    exit 1
    ;;
esac

{
  echo "DEPLOY_ENV=${DEPLOY_ENV}"
  echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
  echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
} >> "$GITHUB_ENV"
echo "DEPLOY_ENV=${DEPLOY_ENV}" >> "$GITHUB_STATE"
