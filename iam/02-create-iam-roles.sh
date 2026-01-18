#!/bin/bash
#------------------------------------------------------------------------------
# IAM Roles and Policies Setup for EKS IRSA
#------------------------------------------------------------------------------
# This script creates all necessary IAM roles and policies for the EKS cluster
# workloads to access AWS services via IRSA (IAM Roles for Service Accounts).
#
# AWS Resources:
#   - S3 Bucket: devops-agent-demo-images-pre-prod
#   - Secrets Manager: demo/pre-prod/database
#   - ElastiCache: demo-pre-prod-redis
#   - ECR: devops-agent-demo-* repositories
#
# Service Accounts:
#   - external-secrets-sa -> Secrets Manager access
#   - infrastructure-sa   -> Secrets Manager + ElastiCache (if IAM auth)
#   - processing-sa       -> S3 access (for image-processor)
#   - All SAs            -> ECR pull access (handled by node role usually)
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - OIDC provider already configured (run 01-oidc-provider.sh first)
#   - jq installed for JSON manipulation
#------------------------------------------------------------------------------

set -euo pipefail

# Configuration
AWS_ACCOUNT_ID="852140462703"
AWS_REGION="us-east-2"
EKS_CLUSTER_NAME="demo-pre-prod-cluster"
NAMESPACE="devops-agent-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "EKS IRSA Roles and Policies Setup"
echo "=============================================="
echo "Account ID: ${AWS_ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${EKS_CLUSTER_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "=============================================="

#------------------------------------------------------------------------------
# Step 1: Get OIDC Provider ID
#------------------------------------------------------------------------------
echo ""
echo "[Step 1] Getting OIDC Provider ID..."

OIDC_URL=$(aws eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.identity.oidc.issuer' \
  --output text 2>/dev/null || echo "")

if [ -z "${OIDC_URL}" ]; then
  echo "ERROR: Could not retrieve OIDC URL. Ensure the cluster exists and OIDC is configured."
  echo "Run 01-oidc-provider.sh first."
  exit 1
fi

OIDC_ID=$(echo "${OIDC_URL}" | cut -d '/' -f 5)
echo "OIDC Provider ID: ${OIDC_ID}"
echo "OIDC URL: ${OIDC_URL}"

#------------------------------------------------------------------------------
# Step 2: Create IAM Policies
#------------------------------------------------------------------------------
echo ""
echo "[Step 2] Creating IAM Policies..."

# Secrets Manager Policy
echo "  Creating SecretsManager access policy..."
aws iam create-policy \
  --policy-name "devops-agent-demo-secrets-manager-policy" \
  --policy-document file://${SCRIPT_DIR}/policies/secrets-manager-policy.json \
  --description "Policy for accessing AWS Secrets Manager secrets for devops-agent-demo" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  2>/dev/null || echo "  Policy already exists or error occurred"

# S3 Access Policy
echo "  Creating S3 access policy..."
aws iam create-policy \
  --policy-name "devops-agent-demo-s3-access-policy" \
  --policy-document file://${SCRIPT_DIR}/policies/s3-access-policy.json \
  --description "Policy for accessing S3 bucket devops-agent-demo-images-pre-prod" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  2>/dev/null || echo "  Policy already exists or error occurred"

# ECR Pull Policy
echo "  Creating ECR pull policy..."
aws iam create-policy \
  --policy-name "devops-agent-demo-ecr-pull-policy" \
  --policy-document file://${SCRIPT_DIR}/policies/ecr-pull-policy.json \
  --description "Policy for pulling images from ECR repositories" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  2>/dev/null || echo "  Policy already exists or error occurred"

# ElastiCache Policy (for IAM authentication if enabled)
echo "  Creating ElastiCache access policy..."
aws iam create-policy \
  --policy-name "devops-agent-demo-elasticache-policy" \
  --policy-document file://${SCRIPT_DIR}/policies/elasticache-policy.json \
  --description "Policy for ElastiCache access (IAM auth)" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  2>/dev/null || echo "  Policy already exists or error occurred"

#------------------------------------------------------------------------------
# Step 3: Create Trust Policy Files with actual OIDC ID
#------------------------------------------------------------------------------
echo ""
echo "[Step 3] Generating trust policies with OIDC ID..."

# Generate trust policies with actual OIDC ID
for TRUST_POLICY in ${SCRIPT_DIR}/trust-policies/*-trust-policy.json; do
  GENERATED_FILE="${TRUST_POLICY%.json}-generated.json"
  sed "s/OIDC_ID_PLACEHOLDER/${OIDC_ID}/g" "${TRUST_POLICY}" > "${GENERATED_FILE}"
  echo "  Generated: $(basename ${GENERATED_FILE})"
done

#------------------------------------------------------------------------------
# Step 4: Create IAM Roles
#------------------------------------------------------------------------------
echo ""
echo "[Step 4] Creating IAM Roles..."

# Role 1: external-secrets-sa role
ROLE_NAME="devops-agent-demo-external-secrets-role"
echo "  Creating role: ${ROLE_NAME}"
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://${SCRIPT_DIR}/trust-policies/external-secrets-trust-policy-generated.json \
  --description "IRSA role for external-secrets-sa ServiceAccount" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo Key=ServiceAccount,Value=external-secrets-sa \
  2>/dev/null || echo "  Role already exists or error occurred"

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-secrets-manager-policy" \
  2>/dev/null || echo "  Policy attachment skipped"

# Role 2: infrastructure-sa role
ROLE_NAME="devops-agent-demo-infrastructure-role"
echo "  Creating role: ${ROLE_NAME}"
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://${SCRIPT_DIR}/trust-policies/infrastructure-sa-trust-policy-generated.json \
  --description "IRSA role for infrastructure-sa ServiceAccount (db-proxy, cache-manager)" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo Key=ServiceAccount,Value=infrastructure-sa \
  2>/dev/null || echo "  Role already exists or error occurred"

# Attach Secrets Manager policy (for db-proxy if it needs direct access)
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-secrets-manager-policy" \
  2>/dev/null || echo "  Policy attachment skipped"

# Attach ElastiCache policy (for cache-manager IAM auth if enabled)
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-elasticache-policy" \
  2>/dev/null || echo "  Policy attachment skipped"

# Role 3: processing-sa role
ROLE_NAME="devops-agent-demo-processing-role"
echo "  Creating role: ${ROLE_NAME}"
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file://${SCRIPT_DIR}/trust-policies/processing-sa-trust-policy-generated.json \
  --description "IRSA role for processing-sa ServiceAccount (image-processor needs S3)" \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo Key=ServiceAccount,Value=processing-sa \
  2>/dev/null || echo "  Role already exists or error occurred"

# Attach S3 policy for image-processor
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/devops-agent-demo-s3-access-policy" \
  2>/dev/null || echo "  Policy attachment skipped"

#------------------------------------------------------------------------------
# Step 5: Display Role ARNs
#------------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "IAM Roles Created"
echo "=============================================="
echo ""
echo "Role ARNs for ServiceAccount annotations:"
echo ""
echo "external-secrets-sa:"
echo "  arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-external-secrets-role"
echo ""
echo "infrastructure-sa:"
echo "  arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-infrastructure-role"
echo ""
echo "processing-sa:"
echo "  arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-processing-role"
echo ""

#------------------------------------------------------------------------------
# Step 6: Output kubectl commands for ServiceAccount annotations
#------------------------------------------------------------------------------
echo "=============================================="
echo "ServiceAccount Annotation Commands"
echo "=============================================="
echo ""
echo "# Annotate external-secrets-sa:"
echo "kubectl annotate serviceaccount external-secrets-sa \\"
echo "  -n ${NAMESPACE} \\"
echo "  eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-external-secrets-role \\"
echo "  --overwrite"
echo ""
echo "# Annotate infrastructure-sa:"
echo "kubectl annotate serviceaccount infrastructure-sa \\"
echo "  -n ${NAMESPACE} \\"
echo "  eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-infrastructure-role \\"
echo "  --overwrite"
echo ""
echo "# Annotate processing-sa:"
echo "kubectl annotate serviceaccount processing-sa \\"
echo "  -n ${NAMESPACE} \\"
echo "  eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/devops-agent-demo-processing-role \\"
echo "  --overwrite"
echo ""
echo "=============================================="
echo "Setup Complete!"
echo "=============================================="
