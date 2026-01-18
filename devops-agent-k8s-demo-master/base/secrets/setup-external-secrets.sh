#!/bin/bash
#------------------------------------------------------------------------------
# External Secrets Operator Setup Script for EKS
#------------------------------------------------------------------------------
# This script configures IAM Role for Service Account (IRSA) and installs
# External Secrets Operator to sync AWS Secrets Manager secrets to Kubernetes.
#
# Prerequisites:
# - AWS CLI v2 configured with appropriate permissions
# - kubectl configured to access the EKS cluster
# - Helm v3 installed
# - eksctl installed (for IRSA configuration)
#
# AWS Account: 852140462703
# Region: us-east-1
# EKS Cluster: demo-pre-prod-cluster
# Namespace: devops-agent-demo
# Secret: demo/pre-prod/database
#------------------------------------------------------------------------------

set -euo pipefail

# Configuration
AWS_ACCOUNT_ID="852140462703"
AWS_REGION="us-east-1"
EKS_CLUSTER_NAME="demo-pre-prod-cluster"
NAMESPACE="devops-agent-demo"
SERVICE_ACCOUNT_NAME="external-secrets-sa"
IAM_ROLE_NAME="external-secrets-irsa-role"
IAM_POLICY_NAME="external-secrets-policy"
SECRET_PATH="demo/pre-prod/database"

echo "=========================================="
echo "External Secrets Operator Setup for EKS"
echo "=========================================="

#------------------------------------------------------------------------------
# Step 1: Get OIDC Provider URL
#------------------------------------------------------------------------------
echo ""
echo "[Step 1/6] Getting OIDC provider information..."

OIDC_PROVIDER=$(aws eks describe-cluster \
    --name "${EKS_CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query "cluster.identity.oidc.issuer" \
    --output text | sed 's|https://||')

echo "OIDC Provider: ${OIDC_PROVIDER}"

# Check if OIDC provider is already associated
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" 2>/dev/null; then
    echo "OIDC provider already exists."
else
    echo "Creating OIDC provider..."
    eksctl utils associate-iam-oidc-provider \
        --cluster "${EKS_CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --approve
fi

#------------------------------------------------------------------------------
# Step 2: Create IAM Policy
#------------------------------------------------------------------------------
echo ""
echo "[Step 2/6] Creating IAM policy for Secrets Manager access..."

# Create the IAM policy document
cat > /tmp/external-secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGetSecretValue",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:${SECRET_PATH}*"
      ]
    },
    {
      "Sid": "AllowListSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Create or update the policy
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

if aws iam get-policy --policy-arn "${POLICY_ARN}" 2>/dev/null; then
    echo "Policy exists, creating new version..."
    aws iam create-policy-version \
        --policy-arn "${POLICY_ARN}" \
        --policy-document file:///tmp/external-secrets-policy.json \
        --set-as-default
else
    echo "Creating new policy..."
    aws iam create-policy \
        --policy-name "${IAM_POLICY_NAME}" \
        --policy-document file:///tmp/external-secrets-policy.json
fi

#------------------------------------------------------------------------------
# Step 3: Create IAM Role with Trust Policy
#------------------------------------------------------------------------------
echo ""
echo "[Step 3/6] Creating IAM role for service account..."

# Create trust policy
cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

if aws iam get-role --role-name "${IAM_ROLE_NAME}" 2>/dev/null; then
    echo "Role exists, updating trust policy..."
    aws iam update-assume-role-policy \
        --role-name "${IAM_ROLE_NAME}" \
        --policy-document file:///tmp/trust-policy.json
else
    echo "Creating new role..."
    aws iam create-role \
        --role-name "${IAM_ROLE_NAME}" \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --description "IAM role for External Secrets Operator in EKS"
fi

# Attach policy to role
echo "Attaching policy to role..."
aws iam attach-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"

#------------------------------------------------------------------------------
# Step 4: Install External Secrets Operator
#------------------------------------------------------------------------------
echo ""
echo "[Step 4/6] Installing External Secrets Operator..."

# Add Helm repository
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install or upgrade External Secrets Operator
helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace \
    --set installCRDs=true \
    --set webhook.port=9443 \
    --wait

echo "External Secrets Operator installed successfully."

#------------------------------------------------------------------------------
# Step 5: Create Namespace and ServiceAccount
#------------------------------------------------------------------------------
echo ""
echo "[Step 5/6] Creating namespace and service account..."

# Create namespace if it doesn't exist
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Apply the service account
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: devops-agent-demo
    app.kubernetes.io/component: secrets
    app.kubernetes.io/managed-by: external-secrets
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

echo "ServiceAccount created successfully."

#------------------------------------------------------------------------------
# Step 6: Apply External Secrets manifests
#------------------------------------------------------------------------------
echo ""
echo "[Step 6/6] Applying External Secrets manifests..."

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Apply the SecretStore and ExternalSecret
kubectl apply -f "${SCRIPT_DIR}/external-secrets.yaml"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Resources created:"
echo "  - IAM Policy: ${POLICY_ARN}"
echo "  - IAM Role: ${ROLE_ARN}"
echo "  - ServiceAccount: ${NAMESPACE}/${SERVICE_ACCOUNT_NAME}"
echo "  - SecretStore: aws-secrets-manager"
echo "  - ExternalSecret: database-credentials-external"
echo ""
echo "The Kubernetes secret 'database-credentials' will be created"
echo "in the '${NAMESPACE}' namespace once the ExternalSecret syncs."
echo ""
echo "Verify with:"
echo "  kubectl get externalsecret -n ${NAMESPACE}"
echo "  kubectl get secret database-credentials -n ${NAMESPACE}"
echo ""
