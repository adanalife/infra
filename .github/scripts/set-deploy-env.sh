#!/bin/bash

# this script is a helper that allows us to set ENV vars
# based on which terraform directory we're using

# Set DEPLOY_ENV based on the input directory
case $1 in
  terraform/core)
    echo "DEPLOY_ENV=core" >> $GITHUB_ENV
    echo "AWS_ACCESS_KEY_ID=${CI_CORE_AWS_ACCESS_KEY_ID}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${CI_CORE_AWS_SECRET_ACCESS_KEY}" >> $GITHUB_ENV
    ;;
  terraform/prod-1)
    echo "DEPLOY_ENV=prod" >> $GITHUB_ENV
    echo "AWS_ACCESS_KEY_ID=${CI_PROD_AWS_ACCESS_KEY_ID}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${CI_PROD_AWS_SECRET_ACCESS_KEY}" >> $GITHUB_ENV
    ;;
  terraform/stage-1)
    echo "DEPLOY_ENV=stage" >> $GITHUB_ENV
    echo "AWS_ACCESS_KEY_ID=${CI_STAGE_AWS_ACCESS_KEY_ID}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${CI_STAGE_AWS_SECRET_ACCESS_KEY}" >> $GITHUB_ENV
    ;;
  *)
    echo "Unknown environment: $1"
    exit 1
    ;;
esac

# Save DEPLOY_ENV to GITHUB_STATE
echo "DEPLOY_ENV=$DEPLOY_ENV" >> $GITHUB_STATE
