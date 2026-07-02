#!/usr/bin/env bash
#
# One-time Secrets Manager → SSM Parameter Store value copy (SM → SSM
# migration, phase 1 — see terraform/stage-1/secrets.tf for the plan).
#
# For every SM secret in the account, writes its current value to the SSM
# parameter of the same name with a leading slash (k8s/foo → /k8s/foo) as a
# SecureString. Skips secrets still holding their terraform placeholder.
#
# Run once per account, AFTER `task tf:<env>:apply` (the apply creates the
# terraform-managed parameters this overwrites; the container-only secrets —
# stream keys, grafana metrics-write, external-dns creds — are created by
# this script directly):
#
#   bin/migrate-sm-to-ssm.sh adanalife-stage
#   bin/migrate-sm-to-ssm.sh adanalife-prod
#   bin/migrate-sm-to-ssm.sh adanalife-core
#
# Idempotent: --overwrite makes re-runs safe.
set -euo pipefail

profile="${1:?usage: bin/migrate-sm-to-ssm.sh <aws-vault-profile>}"

run() { aws-vault exec "$profile" -- aws "$@"; }

for name in $(run secretsmanager list-secrets --query 'SecretList[].Name' --output text); do
  value=$(run secretsmanager get-secret-value --secret-id "$name" --query SecretString --output text)

  case "$value" in
    "placeholder"* | '{"placeholder"'*)
      echo "SKIP  $name (placeholder — never seeded)"
      continue
      ;;
  esac

  # ponytail: standard tier caps at 4KB; nothing we store is bigger. If this
  # ever fires, bump that one parameter to advanced tier by hand.
  if [ "${#value}" -gt 4096 ]; then
    echo "WARN  $name is >4KB — skipped, needs advanced tier" >&2
    continue
  fi

  run ssm put-parameter --name "/$name" --type SecureString \
    --value "$value" --overwrite >/dev/null
  echo "OK    $name -> /$name"
done
