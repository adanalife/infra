# these are the permissions that Developer users get
data "aws_iam_policy_document" "developer_role" {
  statement {
    sid = "S3ReadOnlyAccess"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
    ]
    resources = [
      "arn:aws:s3:::adanalife-core-dashcam-videos",
      "arn:aws:s3:::adanalife-core-dashcam-videos/*",
    ]
  }
}

resource "aws_iam_policy" "developer_role" {
  name   = "AllowAccessForDeveloperRole"
  policy = data.aws_iam_policy_document.developer_role.json
}

# this allows users to browse around the AWS web console
data "aws_iam_policy_document" "basic_web_console_viewing" {
  statement {
    sid = "BasicWebConsoleViewingAccess"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeLaunchConfigurations",
      "batch:DescribeComputeEnvironments",
      "batch:DescribeJobDefinitions",
      "batch:DescribeJobQueues",
      "batch:DescribeJobs",
      "batch:ListJobs",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "dynamodb:DescribeBackup",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTables",
      "ec2:AssociateIamInstanceProfile",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeClientVpnEndpoints",
      "ec2:DescribeHosts",
      "ec2:DescribeIamInstanceProfileAssociations",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceAttribute",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstances",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeNatGateways",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribeNetworkInterfaceAttribute",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRegions",
      "ec2:DescribeReservedInstances",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroupReferences",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshotAttribute",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSpotFleetInstances",
      "ec2:DescribeSpotFleetRequestHistory",
      "ec2:DescribeSpotFleetRequests",
      "ec2:DescribeSpotInstanceRequests",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeStaleSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumeAttribute",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeVpcs",
      "ecr:DescribeRepositories",
      "ecs:DescribeClusters",
      "ecs:DescribeContainerInstances",
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListAttributes",
      "ecs:ListClusters",
      "ecs:ListContainerInstances",
      "ecs:ListServices",
      "ecs:ListTagsForResource",
      "ecs:ListTaskDefinitionFamilies",
      "ecs:ListTaskDefinitions",
      "ecs:ListTasks",
      "eks:ListClusters",
      "elasticloadbalancing:DescribeInstanceHealth",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeLoadBalancerPolicies",
      "elasticloadbalancing:DescribeLoadBalancerPolicyTypes",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "iam:GetAccountSummary",
      "iam:GetInstanceProfile",
      "iam:ListAccountAliases",
      "iam:ListGroups",
      "iam:ListInstanceProfiles",
      "iam:ListPolicies",
      "iam:ListRoles",
      "iam:ListServerCertificates",
      "iam:ListUsers",
      "rds:DescribeCertificates",
      "rds:DescribeDBClusterSnapshots",
      "rds:DescribeDBInstanceAutomatedBackups",
      "rds:DescribeDBInstances",
      "rds:DescribeDBLogFiles",
      "rds:DescribeDBSecurityGroups",
      "rds:DescribeDBSnapshotAttributes",
      "rds:DescribeDBSnapshots",
      "rds:DescribeDBSubnetGroups",
      "rds:DescribeEngineDefaultClusterParameters",
      "rds:DescribeEngineDefaultParameters",
      "rds:DescribeEventCategories",
      "rds:DescribeEventSubscriptions",
      "rds:DescribeEvents",
      "rds:DescribeExportTasks",
      "rds:DescribeOptionGroupOptions",
      "rds:DescribeOptionGroups",
      "rds:DescribeOrderableDBInstanceOptions",
      "rds:DescribePendingMaintenanceActions",
      "rds:DescribeReservedDBInstances",
      "rds:DescribeReservedDBInstancesOfferings",
      "rds:DescribeSourceRegions",
      "rds:DescribeValidDBInstanceModifications",
      "rds:DownloadCompleteDBLogFile",
      "rds:DownloadDBLogFilePortion",
      "rds:ListTagsForResource",
      "route53:GetHostedZoneCount",
      "route53:ListHealthChecks",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:TestDNSAnswer",
      "s3:ListAllMyBuckets",
    ]
    resources = ["*"]
  }

  statement {
    sid = "BasicWebConsoleRoute53ViewingAccess"
    actions = [
      "route53:GetHealthCheck",
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:ListTagsForResources",
      "route53:ListVPCAssociationAuthorizations",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${aws_route53_zone.primary_subdomain_zone.zone_id}",
      "arn:aws:route53:::hostedzone/${aws_route53_zone.secondary_subdomain_zone.zone_id}",
      "arn:aws:route53:::healthcheck/*",
    ]
  }

  statement {
    sid = "BasicWebConsoleEKSViewingAccess"
    actions = [
      "eks:DescribeCluster",
      "eks:DescribeNodegroup",
      "eks:DescribeUpdate",
      "eks:ListNodegroups",
      "eks:ListTagsForResource",
      "eks:ListUpdates",
    ]
    resources = [
      "arn:aws:eks:*:*:cluster/*",
      "arn:aws:eks:*:*:fargateprofile/*/*/*",
      "arn:aws:eks:*:*:nodegroup/*/*/*",
    ]
  }

  statement {
    sid = "BasicWebConsoleRDSViewingAccess"
    actions = [
      "rds:DescribeDBEngineVersions",
      "rds:DescribeDBParameterGroups",
      "rds:DescribeDBParameters",
    ]
    resources = ["arn:aws:rds:*:*:pg:*"]
  }
}

resource "aws_iam_policy" "basic_web_console_viewing" {
  name   = "AllowBasicWebConsoleViewing"
  policy = data.aws_iam_policy_document.basic_web_console_viewing.json
}

data "aws_iam_policy_document" "allow_external_dns_updates" {
  # ChangeResourceRecordSets is scoped to the specific zones managed in this
  # workspace.
  statement {
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:TestDNSAnswer",
    ]
    resources = [
      "arn:aws:route53:::hostedzone/${aws_route53_zone.primary_subdomain_zone.zone_id}",
      "arn:aws:route53:::hostedzone/${aws_route53_zone.secondary_subdomain_zone.zone_id}",
    ]
  }

  # The discovery actions don't support resource-level permissions and must
  # stay "*".
  # See: https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md#iam-policy
  statement {
    actions = [
      "route53:GetChange",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "allow_external_dns_updates" {
  name   = "AllowExternalDNSUpdates"
  policy = data.aws_iam_policy_document.allow_external_dns_updates.json
}
