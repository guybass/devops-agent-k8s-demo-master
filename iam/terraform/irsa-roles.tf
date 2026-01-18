#------------------------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts) Configuration
#------------------------------------------------------------------------------
# This Terraform configuration creates IAM roles and policies for EKS workloads
# to access AWS services using IRSA.
#
# Prerequisites:
#   - EKS cluster with OIDC provider configured
#   - AWS provider configured
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# Variables
#------------------------------------------------------------------------------
variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
  default     = "852140462703"
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-2"
}

variable "eks_cluster_name" {
  description = "EKS Cluster Name"
  type        = string
  default     = "demo-pre-prod-cluster"
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "devops-agent-demo"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "pre-prod"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "devops-agent-demo"
}

#------------------------------------------------------------------------------
# Data Sources
#------------------------------------------------------------------------------
data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

locals {
  oidc_provider_arn = data.aws_iam_openid_connect_provider.eks.arn
  oidc_provider_url = replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")

  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
  }
}

#------------------------------------------------------------------------------
# IAM Policies
#------------------------------------------------------------------------------

# Secrets Manager Policy
resource "aws_iam_policy" "secrets_manager" {
  name        = "${var.project_name}-secrets-manager-policy"
  description = "Policy for accessing AWS Secrets Manager secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerReadAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:demo/${var.environment}/database*",
          "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:demo/${var.environment}/redis*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# S3 Access Policy
resource "aws_iam_policy" "s3_access" {
  name        = "${var.project_name}-s3-access-policy"
  description = "Policy for accessing S3 bucket for image processing"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketListAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::devops-agent-demo-images-${var.environment}"
        ]
      },
      {
        Sid    = "S3ObjectReadWriteAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging"
        ]
        Resource = [
          "arn:aws:s3:::devops-agent-demo-images-${var.environment}/*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# ECR Pull Policy
resource "aws_iam_policy" "ecr_pull" {
  name        = "${var.project_name}-ecr-pull-policy"
  description = "Policy for pulling images from ECR repositories"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRGetAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPullImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = [
          "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.project_name}-*"
        ]
      }
    ]
  })

  tags = local.common_tags
}

# ElastiCache Policy (for IAM authentication if enabled)
resource "aws_iam_policy" "elasticache" {
  name        = "${var.project_name}-elasticache-policy"
  description = "Policy for ElastiCache access (IAM auth)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ElastiCacheDescribeAccess"
        Effect = "Allow"
        Action = [
          "elasticache:DescribeReplicationGroups",
          "elasticache:DescribeCacheClusters"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

#------------------------------------------------------------------------------
# IAM Role: external-secrets-sa
#------------------------------------------------------------------------------
resource "aws_iam_role" "external_secrets" {
  name        = "${var.project_name}-external-secrets-role"
  description = "IRSA role for external-secrets-sa ServiceAccount"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:${var.namespace}:external-secrets-sa"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    ServiceAccount = "external-secrets-sa"
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets_sm" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.secrets_manager.arn
}

#------------------------------------------------------------------------------
# IAM Role: infrastructure-sa
#------------------------------------------------------------------------------
resource "aws_iam_role" "infrastructure" {
  name        = "${var.project_name}-infrastructure-role"
  description = "IRSA role for infrastructure-sa ServiceAccount"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:${var.namespace}:infrastructure-sa"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    ServiceAccount = "infrastructure-sa"
  })
}

resource "aws_iam_role_policy_attachment" "infrastructure_sm" {
  role       = aws_iam_role.infrastructure.name
  policy_arn = aws_iam_policy.secrets_manager.arn
}

resource "aws_iam_role_policy_attachment" "infrastructure_elasticache" {
  role       = aws_iam_role.infrastructure.name
  policy_arn = aws_iam_policy.elasticache.arn
}

#------------------------------------------------------------------------------
# IAM Role: processing-sa
#------------------------------------------------------------------------------
resource "aws_iam_role" "processing" {
  name        = "${var.project_name}-processing-role"
  description = "IRSA role for processing-sa ServiceAccount"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:${var.namespace}:processing-sa"
            "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    ServiceAccount = "processing-sa"
  })
}

resource "aws_iam_role_policy_attachment" "processing_s3" {
  role       = aws_iam_role.processing.name
  policy_arn = aws_iam_policy.s3_access.arn
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------
output "external_secrets_role_arn" {
  description = "ARN of the IAM role for external-secrets-sa"
  value       = aws_iam_role.external_secrets.arn
}

output "infrastructure_role_arn" {
  description = "ARN of the IAM role for infrastructure-sa"
  value       = aws_iam_role.infrastructure.arn
}

output "processing_role_arn" {
  description = "ARN of the IAM role for processing-sa"
  value       = aws_iam_role.processing.arn
}

output "service_account_annotations" {
  description = "ServiceAccount annotations for IRSA"
  value = {
    "external-secrets-sa" = "eks.amazonaws.com/role-arn: ${aws_iam_role.external_secrets.arn}"
    "infrastructure-sa"   = "eks.amazonaws.com/role-arn: ${aws_iam_role.infrastructure.arn}"
    "processing-sa"       = "eks.amazonaws.com/role-arn: ${aws_iam_role.processing.arn}"
  }
}
