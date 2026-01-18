# IAM Setup Documentation

This document provides detailed documentation for configuring IAM roles, policies, and IRSA (IAM Roles for Service Accounts) for the DevOps Agent Demo EKS deployment.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [OIDC Provider Setup](#oidc-provider-setup)
- [IAM Policies](#iam-policies)
- [IAM Roles](#iam-roles)
- [Trust Policies](#trust-policies)
- [ServiceAccount Mapping](#serviceaccount-mapping)
- [Setup Commands](#setup-commands)
- [Verification](#verification)

## Overview

### AWS Environment

| Setting | Value |
|---------|-------|
| AWS Account ID | `852140462703` |
| Region | `us-east-1` |
| EKS Cluster | `demo-pre-prod-cluster` |
| Namespace | `devops-agent-demo` |

### IAM Resources Summary

| Resource Type | Name | Purpose |
|---------------|------|---------|
| OIDC Provider | EKS Cluster OIDC | Enables IRSA |
| IAM Policy | devops-agent-demo-secrets-manager-policy | Secrets Manager access |
| IAM Policy | devops-agent-demo-s3-access-policy | S3 bucket access |
| IAM Policy | devops-agent-demo-ecr-pull-policy | ECR image pull |
| IAM Policy | devops-agent-demo-elasticache-policy | ElastiCache access |
| IAM Policy | AWSLoadBalancerControllerIAMPolicy | ALB Controller permissions |
| IAM Policy | ArgoCD-ExternalSecrets-Policy | ArgoCD secrets access |
| IAM Role | devops-agent-demo-external-secrets-role | For external-secrets-sa |
| IAM Role | devops-agent-demo-infrastructure-role | For infrastructure-sa |
| IAM Role | devops-agent-demo-processing-role | For processing-sa |
| IAM Role | AmazonEKSLoadBalancerControllerRole | For aws-load-balancer-controller |
| IAM Role | ArgoCD-ExternalSecrets-Role | For argocd:external-secrets-sa |

## Prerequisites

Before setting up IAM, ensure you have:

1. **AWS CLI** configured with appropriate permissions:
   ```bash
   aws sts get-caller-identity
   ```

2. **kubectl** configured to access the EKS cluster:
   ```bash
   kubectl cluster-info
   ```

3. **eksctl** installed (recommended for OIDC setup):
   ```bash
   eksctl version
   ```

4. **jq** installed for JSON manipulation:
   ```bash
   jq --version
   ```

### Required IAM Permissions

The user/role running these commands needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy",
        "iam:CreateRole",
        "iam:AttachRolePolicy",
        "iam:GetRole",
        "iam:ListAttachedRolePolicies",
        "iam:CreateOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviders",
        "eks:DescribeCluster"
      ],
      "Resource": "*"
    }
  ]
}
```

## OIDC Provider Setup

The OIDC provider enables EKS to authenticate ServiceAccounts with AWS IAM.

### Using eksctl (Recommended)

```bash
# Associate OIDC provider with the cluster
eksctl utils associate-iam-oidc-provider \
  --cluster demo-pre-prod-cluster \
  --region us-east-1 \
  --approve

# Verify OIDC provider
eksctl get iamidentitymapping --cluster demo-pre-prod-cluster --region us-east-1
```

### Using AWS CLI (Manual)

```bash
# Step 1: Get the OIDC issuer URL
OIDC_URL=$(aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' \
  --output text)

echo "OIDC URL: $OIDC_URL"

# Step 2: Extract OIDC ID
OIDC_ID=$(echo $OIDC_URL | cut -d '/' -f 5)
echo "OIDC ID: $OIDC_ID"

# Step 3: Check if OIDC provider already exists
aws iam list-open-id-connect-providers | grep $OIDC_ID

# Step 4: Get the thumbprint (usually not needed for EKS as AWS manages it)
# For EKS in us-east-1, AWS trusts the certificate automatically

# Step 5: Create OIDC provider (if not exists)
aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
```

### Verify OIDC Provider

```bash
# List all OIDC providers
aws iam list-open-id-connect-providers

# Get details of the EKS OIDC provider
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/$OIDC_ID
```

## IAM Policies

### 1. Secrets Manager Policy

**Name:** `devops-agent-demo-secrets-manager-policy`

**Purpose:** Allows reading secrets from AWS Secrets Manager for both database and Redis credentials.

**File:** `iam/policies/secrets-manager-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerReadAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:852140462703:secret:demo/pre-prod/database*",
        "arn:aws:secretsmanager:us-east-1:852140462703:secret:demo/pre-prod/redis*"
      ]
    },
    {
      "Sid": "SecretsManagerListAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "secretsmanager:ResourceTag/Environment": "pre-prod"
        }
      }
    }
  ]
}
```

**Secret Paths Covered:**
- `demo/pre-prod/database` - PostgreSQL RDS credentials
- `demo/pre-prod/redis` - ElastiCache Redis credentials

**Create Command:**

```bash
aws iam create-policy \
  --policy-name devops-agent-demo-secrets-manager-policy \
  --policy-document file://iam/policies/secrets-manager-policy.json \
  --description "Policy for accessing AWS Secrets Manager secrets for devops-agent-demo" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo
```

### 2. S3 Access Policy

**Name:** `devops-agent-demo-s3-access-policy`

**Purpose:** Allows read/write access to S3 bucket for image processing.

**File:** `iam/policies/s3-access-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3BucketListAccess",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::devops-agent-images-pre-prod"
      ]
    },
    {
      "Sid": "S3ObjectReadWriteAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectVersion",
        "s3:GetObjectTagging",
        "s3:PutObjectTagging"
      ],
      "Resource": [
        "arn:aws:s3:::devops-agent-images-pre-prod/*"
      ]
    }
  ]
}
```

**Create Command:**

```bash
aws iam create-policy \
  --policy-name devops-agent-demo-s3-access-policy \
  --policy-document file://iam/policies/s3-access-policy.json \
  --description "Policy for accessing S3 bucket devops-agent-images-pre-prod" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo
```

### 3. ECR Pull Policy

**Name:** `devops-agent-demo-ecr-pull-policy`

**Purpose:** Allows pulling container images from ECR repositories.

**File:** `iam/policies/ecr-pull-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRGetAuthorizationToken",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPullImages",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": [
        "arn:aws:ecr:us-east-1:852140462703:repository/devops-agent-demo-*"
      ]
    }
  ]
}
```

**Note:** ECR pull is typically handled by the EKS node IAM role. This policy is provided if you need pod-level ECR access.

### 4. ElastiCache Policy

**Name:** `devops-agent-demo-elasticache-policy`

**Purpose:** Allows access to ElastiCache (for IAM authentication if enabled).

**File:** `iam/policies/elasticache-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ElastiCacheDescribeAccess",
      "Effect": "Allow",
      "Action": [
        "elasticache:DescribeReplicationGroups",
        "elasticache:DescribeCacheClusters",
        "elasticache:DescribeCacheSubnetGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ElastiCacheConnectAccess",
      "Effect": "Allow",
      "Action": [
        "elasticache:Connect"
      ],
      "Resource": [
        "arn:aws:elasticache:us-east-1:852140462703:replicationgroup:demo-pre-prod-redis",
        "arn:aws:elasticache:us-east-1:852140462703:user:*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Environment": "pre-prod"
        }
      }
    }
  ]
}
```

**Redis Endpoint:** `master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com:6379`

**Note:** This policy is for future use if you enable IAM authentication for ElastiCache. Currently, password authentication via `REDIS_URL` from Secrets Manager is used.

### 5. AWS Load Balancer Controller Policy

**Name:** `AWSLoadBalancerControllerIAMPolicy`

**Purpose:** Allows the AWS Load Balancer Controller to manage ALB/NLB resources.

**Source:** Downloaded from AWS official repository.

```bash
# Download the latest policy
curl -o /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

# Create the policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam-policy.json
```

**Key Permissions:**
- `elasticloadbalancing:*` - Full ELB management
- `ec2:Describe*` - EC2 resource discovery
- `ec2:AuthorizeSecurityGroupIngress` - Security group management
- `ec2:CreateSecurityGroup` - Create security groups for ALBs
- `wafv2:*` - WAF association (optional)
- `shield:*` - Shield integration (optional)

**Important Fix Applied:**

The policy was updated to include the `elasticloadbalancing:DescribeListenerAttributes` permission, which is required by newer versions of the controller:

```bash
# If you see errors about DescribeListenerAttributes, update the policy:
aws iam create-policy-version \
  --policy-arn arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/updated-iam-policy.json \
  --set-as-default
```

## IAM Roles

### 1. External Secrets Role

**Name:** `devops-agent-demo-external-secrets-role`

**ServiceAccount:** `external-secrets-sa`

**Policies Attached:**
- `devops-agent-demo-secrets-manager-policy`

**Purpose:** Allows External Secrets Operator to read secrets from AWS Secrets Manager (both database and Redis credentials).

### 2. Infrastructure Role

**Name:** `devops-agent-demo-infrastructure-role`

**ServiceAccount:** `infrastructure-sa`

**Policies Attached:**
- `devops-agent-demo-secrets-manager-policy`
- `devops-agent-demo-elasticache-policy`

**Purpose:** Allows infrastructure services (db-proxy, cache-manager) to access Secrets Manager and ElastiCache.

### 3. Processing Role

**Name:** `devops-agent-demo-processing-role`

**ServiceAccount:** `processing-sa`

**Policies Attached:**
- `devops-agent-demo-s3-access-policy`

**Purpose:** Allows processing services (especially image-processor) to read/write to S3.

### 4. AWS Load Balancer Controller Role

**Name:** `AmazonEKSLoadBalancerControllerRole`

**ServiceAccount:** `aws-load-balancer-controller` (in `kube-system` namespace)

**Policies Attached:**
- `AWSLoadBalancerControllerIAMPolicy`

**Purpose:** Allows the AWS Load Balancer Controller to create and manage ALBs for Kubernetes Ingress resources.

**Creation Command:**

```bash
eksctl create iamserviceaccount \
  --cluster=demo-pre-prod-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name=AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region=us-east-1
```

**Verification:**

```bash
# Check ServiceAccount annotation
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn

# Expected output:
# eks.amazonaws.com/role-arn: arn:aws:iam::852140462703:role/AmazonEKSLoadBalancerControllerRole
```

### 5. ArgoCD External Secrets Policy

**Name:** `ArgoCD-ExternalSecrets-Policy`

**Purpose:** Allows ArgoCD External Secrets to read secrets from AWS Secrets Manager (for GitHub SSH key and Redis password).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ArgoCDSecretsManagerReadAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:852140462703:secret:argocd/*"
      ]
    }
  ]
}
```

**Create Command:**

```bash
aws iam create-policy \
  --policy-name ArgoCD-ExternalSecrets-Policy \
  --policy-document file://iam/policies/argocd-secrets-policy.json \
  --description "Policy for ArgoCD to access secrets in AWS Secrets Manager" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=argocd
```

### 6. ArgoCD External Secrets Role

**Name:** `ArgoCD-ExternalSecrets-Role`

**ServiceAccount:** `external-secrets-sa` (in argocd namespace)

**Policies Attached:**
- `ArgoCD-ExternalSecrets-Policy`

**Purpose:** Allows External Secrets Operator in the argocd namespace to read ArgoCD secrets from AWS Secrets Manager.

**Creation Command:**

```bash
# Get OIDC ID
OIDC_ID=$(aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' \
  --output text | cut -d '/' -f 5)

# Create trust policy
cat > /tmp/argocd-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:argocd:external-secrets-sa",
          "oidc.eks.us-east-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create IAM role
aws iam create-role \
  --role-name ArgoCD-ExternalSecrets-Role \
  --assume-role-policy-document file:///tmp/argocd-trust-policy.json \
  --description "IRSA role for ArgoCD External Secrets"

# Attach policy to role
aws iam attach-role-policy \
  --role-name ArgoCD-ExternalSecrets-Role \
  --policy-arn arn:aws:iam::852140462703:policy/ArgoCD-ExternalSecrets-Policy
```

**ServiceAccount Configuration:**

File: `infrastructure/argocd/external-secrets-sa.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: argocd
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::852140462703:role/ArgoCD-ExternalSecrets-Role
```

**Verification:**

```bash
# Check ServiceAccount annotation
kubectl get sa external-secrets-sa -n argocd -o yaml | grep role-arn

# Expected output:
# eks.amazonaws.com/role-arn: arn:aws:iam::852140462703:role/ArgoCD-ExternalSecrets-Role

# Test AWS credentials from argocd namespace
kubectl run aws-test --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n argocd \
  -- secretsmanager get-secret-value --secret-id argocd/github-ssh-key --region us-east-1
```

## Trust Policies

Trust policies define which ServiceAccounts can assume the IAM roles.

### Template Structure

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:NAMESPACE:SERVICE_ACCOUNT",
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### External Secrets Trust Policy

**File:** `iam/trust-policies/external-secrets-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:sub": "system:serviceaccount:devops-agent-demo:external-secrets-sa",
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### Infrastructure SA Trust Policy

**File:** `iam/trust-policies/infrastructure-sa-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:sub": "system:serviceaccount:devops-agent-demo:infrastructure-sa",
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### Processing SA Trust Policy

**File:** `iam/trust-policies/processing-sa-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:sub": "system:serviceaccount:devops-agent-demo:processing-sa",
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID_PLACEHOLDER:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

## ServiceAccount Mapping

| ServiceAccount | Namespace | IAM Role | AWS Access |
|----------------|-----------|----------|------------|
| external-secrets-sa | devops-agent-demo | devops-agent-demo-external-secrets-role | Secrets Manager (read: database + redis) |
| infrastructure-sa | devops-agent-demo | devops-agent-demo-infrastructure-role | Secrets Manager (read), ElastiCache |
| processing-sa | devops-agent-demo | devops-agent-demo-processing-role | S3 (read/write) |
| aws-load-balancer-controller | kube-system | AmazonEKSLoadBalancerControllerRole | ELB, EC2, WAF, Shield |
| external-secrets-sa | argocd | ArgoCD-ExternalSecrets-Role | Secrets Manager (read: argocd/*) |
| backend-sa | devops-agent-demo | None | No direct AWS access |
| frontend-sa | devops-agent-demo | None | No direct AWS access |
| api-gateway-sa | devops-agent-demo | None | No direct AWS access |

## Setup Commands

### Complete Setup Script

Run the setup script from the `iam/` directory:

```bash
# Make scripts executable
chmod +x iam/01-oidc-provider.sh iam/02-create-iam-roles.sh

# Step 1: Setup OIDC provider (if not already done)
# Review the script first, then run eksctl command
./iam/01-oidc-provider.sh

# Step 2: Create IAM policies and roles
./iam/02-create-iam-roles.sh
```

### Manual Setup Commands

```bash
# Variables
AWS_ACCOUNT_ID="852140462703"
AWS_REGION="us-east-1"
EKS_CLUSTER_NAME="demo-pre-prod-cluster"
NAMESPACE="devops-agent-demo"

# Get OIDC ID
OIDC_URL=$(aws eks describe-cluster \
  --name ${EKS_CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'cluster.identity.oidc.issuer' \
  --output text)
OIDC_ID=$(echo ${OIDC_URL} | cut -d '/' -f 5)

# Create policies
aws iam create-policy \
  --policy-name devops-agent-demo-secrets-manager-policy \
  --policy-document file://iam/policies/secrets-manager-policy.json

aws iam create-policy \
  --policy-name devops-agent-demo-s3-access-policy \
  --policy-document file://iam/policies/s3-access-policy.json

aws iam create-policy \
  --policy-name devops-agent-demo-elasticache-policy \
  --policy-document file://iam/policies/elasticache-policy.json

# Generate trust policies with actual OIDC ID
sed "s/OIDC_ID_PLACEHOLDER/${OIDC_ID}/g" \
  iam/trust-policies/external-secrets-trust-policy.json > /tmp/external-secrets-trust.json

sed "s/OIDC_ID_PLACEHOLDER/${OIDC_ID}/g" \
  iam/trust-policies/infrastructure-sa-trust-policy.json > /tmp/infrastructure-trust.json

sed "s/OIDC_ID_PLACEHOLDER/${OIDC_ID}/g" \
  iam/trust-policies/processing-sa-trust-policy.json > /tmp/processing-trust.json

# Create roles
aws iam create-role \
  --role-name devops-agent-demo-external-secrets-role \
  --assume-role-policy-document file:///tmp/external-secrets-trust.json \
  --description "IRSA role for external-secrets-sa ServiceAccount"

aws iam create-role \
  --role-name devops-agent-demo-infrastructure-role \
  --assume-role-policy-document file:///tmp/infrastructure-trust.json \
  --description "IRSA role for infrastructure-sa ServiceAccount"

aws iam create-role \
  --role-name devops-agent-demo-processing-role \
  --assume-role-policy-document file:///tmp/processing-trust.json \
  --description "IRSA role for processing-sa ServiceAccount"

# Attach policies to roles
aws iam attach-role-policy \
  --role-name devops-agent-demo-external-secrets-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-secrets-manager-policy

aws iam attach-role-policy \
  --role-name devops-agent-demo-infrastructure-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-secrets-manager-policy

aws iam attach-role-policy \
  --role-name devops-agent-demo-infrastructure-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-elasticache-policy

aws iam attach-role-policy \
  --role-name devops-agent-demo-processing-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-s3-access-policy
```

### Updating the Secrets Manager Policy

If you need to add additional secret paths (e.g., adding Redis), update the policy:

```bash
# Create updated policy document with both paths
cat > /tmp/updated-secrets-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerReadAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:852140462703:secret:demo/pre-prod/database*",
        "arn:aws:secretsmanager:us-east-1:852140462703:secret:demo/pre-prod/redis*"
      ]
    },
    {
      "Sid": "SecretsManagerListAccess",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "secretsmanager:ResourceTag/Environment": "pre-prod"
        }
      }
    }
  ]
}
EOF

# Get current policy version
POLICY_ARN="arn:aws:iam::852140462703:policy/devops-agent-demo-secrets-manager-policy"

# Create new policy version
aws iam create-policy-version \
  --policy-arn $POLICY_ARN \
  --policy-document file:///tmp/updated-secrets-policy.json \
  --set-as-default
```

### Apply Kubernetes ServiceAccounts

```bash
# Apply ServiceAccounts with IRSA annotations
kubectl apply -f iam/k8s-manifests/service-accounts-with-irsa.yaml

# Or annotate existing ServiceAccounts
kubectl annotate serviceaccount external-secrets-sa \
  -n devops-agent-demo \
  eks.amazonaws.com/role-arn=arn:aws:iam::852140462703:role/devops-agent-demo-external-secrets-role \
  --overwrite

kubectl annotate serviceaccount infrastructure-sa \
  -n devops-agent-demo \
  eks.amazonaws.com/role-arn=arn:aws:iam::852140462703:role/devops-agent-demo-infrastructure-role \
  --overwrite

kubectl annotate serviceaccount processing-sa \
  -n devops-agent-demo \
  eks.amazonaws.com/role-arn=arn:aws:iam::852140462703:role/devops-agent-demo-processing-role \
  --overwrite
```

## Verification

### Verify OIDC Provider

```bash
# List OIDC providers
aws iam list-open-id-connect-providers

# Should show:
# arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXX
```

### Verify IAM Policies

```bash
# List policies
aws iam list-policies --scope Local --query 'Policies[?contains(PolicyName, `devops-agent-demo`)]'

# Get policy details
aws iam get-policy \
  --policy-arn arn:aws:iam::852140462703:policy/devops-agent-demo-secrets-manager-policy

# Get policy document to verify both secret paths
aws iam get-policy-version \
  --policy-arn arn:aws:iam::852140462703:policy/devops-agent-demo-secrets-manager-policy \
  --version-id v1 \
  --query 'PolicyVersion.Document'
```

### Verify IAM Roles

```bash
# Get role details
aws iam get-role --role-name devops-agent-demo-external-secrets-role
aws iam get-role --role-name devops-agent-demo-infrastructure-role
aws iam get-role --role-name devops-agent-demo-processing-role

# List attached policies
aws iam list-attached-role-policies --role-name devops-agent-demo-external-secrets-role
aws iam list-attached-role-policies --role-name devops-agent-demo-infrastructure-role
aws iam list-attached-role-policies --role-name devops-agent-demo-processing-role
```

### Verify ServiceAccount Annotations

```bash
# Check annotations
kubectl get sa -n devops-agent-demo -o yaml | grep eks.amazonaws.com/role-arn

# Individual ServiceAccounts
kubectl get sa external-secrets-sa -n devops-agent-demo -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
kubectl get sa infrastructure-sa -n devops-agent-demo -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
kubectl get sa processing-sa -n devops-agent-demo -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

### Test AWS Credentials from Pod

```bash
# Test external-secrets-sa (should have access to both database and redis secrets)
kubectl run aws-cli-test-secrets --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n devops-agent-demo \
  -- sts get-caller-identity

# Test database secret access
kubectl run aws-cli-test-db --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n devops-agent-demo \
  -- secretsmanager get-secret-value --secret-id demo/pre-prod/database --region us-east-1

# Test redis secret access
kubectl run aws-cli-test-redis --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n devops-agent-demo \
  -- secretsmanager get-secret-value --secret-id demo/pre-prod/redis --region us-east-1

# Test processing-sa (S3 access)
kubectl run aws-cli-test-s3 --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"processing-sa"}}' \
  -n devops-agent-demo \
  -- s3 ls s3://devops-agent-images-pre-prod/

# Test infrastructure-sa (Secrets Manager access)
kubectl run aws-cli-test-sm --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"infrastructure-sa"}}' \
  -n devops-agent-demo \
  -- secretsmanager get-secret-value --secret-id demo/pre-prod/database --region us-east-1
```

### Restart Pods After IRSA Changes

After updating IRSA configuration, restart pods to pick up new credentials:

```bash
# Restart all deployments
kubectl rollout restart deployment -n devops-agent-demo

# Or restart specific deployments
kubectl rollout restart deployment/image-processor -n devops-agent-demo
kubectl rollout restart deployment/db-proxy -n devops-agent-demo
```
