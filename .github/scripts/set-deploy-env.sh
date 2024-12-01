#!/usr/bin/env bash

# Set DEPLOY_ENV based on the input directory
case $1 in
  terraform/core)
    #echo "DEPLOY_ENV=core" >> $GITHUB_STATE
    echo "AWS_ACCESS_KEY_ID=${{ secrets.CI_AWS_ACCESS_KEY_ID }}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${{ secrets.CI_AWS_SECRET_ACCESS_KEY }}" >> $GITHUB_ENV
    #echo "AWS_ACCESS_KEY_ID=${{ secrets.CI_CORE_AWS_ACCESS_KEY_ID }}" >> $GITHUB_ENV
    #echo "AWS_SECRET_ACCESS_KEY=${{ secrets.CI_CORE_AWS_SECRET_ACCESS_KEY }}" >> $GITHUB_ENV
    ;;
  terraform/prod-1)
    #echo "DEPLOY_ENV=prod" >> $GITHUB_STATE
    echo "AWS_ACCESS_KEY_ID=${{ secrets.CI_PROD_AWS_ACCESS_KEY_ID }}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${{ secrets.CI_PROD_AWS_SECRET_ACCESS_KEY }}" >> $GITHUB_ENV
    ;;
  terraform/stage-1)
    #echo "DEPLOY_ENV=stage" >> $GITHUB_STATE
    echo "AWS_ACCESS_KEY_ID=${{ secrets.CI_AWS_ACCESS_KEY_ID }}" >> $GITHUB_ENV
    echo "AWS_SECRET_ACCESS_KEY=${{ secrets.CI_AWS_SECRET_ACCESS_KEY }}" >> $GITHUB_ENV
    # echo "AWS_ACCESS_KEY_ID=${{ secrets.CI_STAGE_AWS_ACCESS_KEY_ID }}" >> $GITHUB_ENV
    # echo "AWS_SECRET_ACCESS_KEY=${{ secrets.CI_STAGE_AWS_SECRET_ACCESS_KEY }}" >> $GITHUB_ENV
    ;;
  *)
    echo "Unknown environment: $1"
    exit 1
    ;;
esac
