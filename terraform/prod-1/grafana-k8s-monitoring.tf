# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/grafana-k8s-monitoring.tf
#
# grafana-k8s-monitoring placeholder — SM container + CI lifecycle policy
# live in secrets.tf as of the 2026-05-11 consolidation. This file stays as
# a breadcrumb that "this env runs the grafana-k8s-monitoring helm chart"
# and is the natural home if a future TF resource ever needs to manage that
# chart from terraform-side (today the chart is installed by
# `task k8s:prod:platform:up`).
