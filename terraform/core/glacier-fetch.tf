# The in-cluster Glacier retrieval of the dashcam originals (video-pipeline's
# glacier-fetch CronJob in stage-1). A core-account bot, because the vault is
# here; it can read the job list, start retrievals and download their output on
# the Dashcam vault, and nothing else — no deletes, no uploads, no other vault.
#
# The access key is minted out-of-band so it never lands in state, then seeded
# into the stage account's /k8s/video-pipeline/glacier-fetch (stage-1/secrets.tf),
# where the stage-1 SecretStore reads it (IAM refuses a non-MFA session token,
# hence --no-session):
#
#   aws-vault exec adanalife-core --no-session -- aws iam create-access-key \
#     --user-name GlacierFetchUser \
#     --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text | read -r ak sk
#   aws-vault exec adanalife-stage -- aws ssm put-parameter \
#     --name /k8s/video-pipeline/glacier-fetch --type SecureString --overwrite \
#     --value "$(jq -nc --arg a "$ak" --arg s "$sk" \
#       '{AWS_ACCESS_KEY_ID: $a, AWS_SECRET_ACCESS_KEY: $s}')"

resource "aws_iam_user" "glacier_fetch" {
  name = "GlacierFetchUser"
  path = "/bots/"
  tags = {
    Name = "GlacierFetchUser"
  }
  force_destroy = false
}

data "aws_iam_policy_document" "glacier_fetch" {
  statement {
    sid = "RetrieveDashcamArchives"
    actions = [
      "glacier:ListJobs",
      "glacier:DescribeJob",
      "glacier:InitiateJob",
      "glacier:GetJobOutput",
    ]
    resources = [aws_glacier_vault.dashcam.arn]
  }
}

resource "aws_iam_user_policy" "glacier_fetch" {
  name   = "DashcamGlacierRetrieval"
  user   = aws_iam_user.glacier_fetch.name
  policy = data.aws_iam_policy_document.glacier_fetch.json
}
