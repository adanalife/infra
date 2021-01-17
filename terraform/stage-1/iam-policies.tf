# these are the permissions that Developer users get
resource aws_iam_policy developer_role {
  name   = "AllowAccessForDeveloperRole"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3ReadOnlyAccess",
            "Action": [
              "s3:ListBucket",
              "s3:GetObject"
            ],
            "Effect": "Allow",
            "Resource": [
                "arn:aws:s3:::adanalife-core-dashcam-videos",
                "arn:aws:s3:::adanalife-core-dashcam-videos/*"
            ]
        }
    ]
}
EOF
}

# this allows users to browse around the AWS web console
resource aws_iam_policy basic_web_console_viewing {
  name   = "AllowBasicWebConsoleViewing"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "BasicWebConsoleViewingAccess",
            "Effect": "Allow",
            "Action": [
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
                "s3:ListAllMyBuckets"
            ],
            "Resource": "*"
        },
        {
            "Sid": "BasicWebConsoleRoute53ViewingAccess",
            "Effect": "Allow",
            "Action": [
                "route53:GetHealthCheck",
                "route53:GetHostedZone",
                "route53:ListResourceRecordSets",
                "route53:ListTagsForResource",
                "route53:ListTagsForResources",
                "route53:ListVPCAssociationAuthorizations"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/*",
                "arn:aws:route53:::healthcheck/*"
            ]
        },
        {
            "Sid": "BasicWebConsoleEKSViewingAccess",
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:DescribeNodegroup",
                "eks:DescribeUpdate",
                "eks:ListNodegroups",
                "eks:ListTagsForResource",
                "eks:ListUpdates"
            ],
            "Resource": [
                "arn:aws:eks:*:*:cluster/*",
                "arn:aws:eks:*:*:fargateprofile/*/*/*",
                "arn:aws:eks:*:*:nodegroup/*/*/*"
            ]
        },
        {
            "Sid": "BasicWebConsoleRDSViewingAccess",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBEngineVersions",
                "rds:DescribeDBParameterGroups",
                "rds:DescribeDBParameters"
            ],
            "Resource": "arn:aws:rds:*:*:pg:*"
        }
    ]
}
EOF
}

resource aws_iam_policy allow_external_dns_updates {
  name = "AllowExternalDNSUpdates"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
}
