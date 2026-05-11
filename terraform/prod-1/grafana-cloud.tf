# KEEP-IN-SYNC: terraform/{stage-1,prod-1}/grafana-cloud.tf
#
# Grafana Cloud bootstrap notes — SM containers live in secrets.tf as of the
# 2026-05-11 consolidation. This file is intentionally near-empty today; it
# stays around so its presence still signals "this env wires Grafana Cloud."
# Future grafana_cloud_* provider config (if we lift it out of stage-1's
# grafana.tf into core/ or prod-1/) would land here.
