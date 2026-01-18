#!/bin/bash
#------------------------------------------------------------------------------
# OIDC Provider Setup for EKS IRSA
#------------------------------------------------------------------------------
# This script creates the OIDC provider for IAM Roles for Service Accounts (IRSA)
# Run this ONCE per EKS cluster before creating any IRSA roles
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - kubectl configured to access the EKS cluster
#   - eksctl installed (optional, simplifies the process)
#------------------------------------------------------------------------------

set -euo pipefail

# Configuration
AWS_ACCOUNT_ID="852140462703"
AWS_REGION="us-east-2"
EKS_CLUSTER_NAME="demo-pre-prod-cluster"

echo "=============================================="
echo "EKS OIDC Provider Setup"
echo "=============================================="
echo "Account ID: ${AWS_ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${EKS_CLUSTER_NAME}"
echo "=============================================="

# Method 1: Using eksctl (Recommended)
echo ""
echo "Method 1: Using eksctl (Recommended)"
echo "----------------------------------------------"
echo "Run the following command:"
echo ""
echo "eksctl utils associate-iam-oidc-provider \\"
echo "  --cluster ${EKS_CLUSTER_NAME} \\"
echo "  --region ${AWS_REGION} \\"
echo "  --approve"
echo ""

# Method 2: Using AWS CLI (Manual)
echo "Method 2: Using AWS CLI (Manual)"
echo "----------------------------------------------"
echo ""

# Get OIDC issuer URL
echo "# Step 1: Get OIDC issuer URL"
echo "OIDC_URL=\$(aws eks describe-cluster \\"
echo "  --name ${EKS_CLUSTER_NAME} \\"
echo "  --region ${AWS_REGION} \\"
echo "  --query 'cluster.identity.oidc.issuer' \\"
echo "  --output text)"
echo ""
echo "# Step 2: Extract OIDC ID"
echo "OIDC_ID=\$(echo \$OIDC_URL | cut -d '/' -f 5)"
echo ""
echo "# Step 3: Check if OIDC provider already exists"
echo "aws iam list-open-id-connect-providers | grep \$OIDC_ID || echo 'OIDC provider not found'"
echo ""
echo "# Step 4: Create OIDC provider (if not exists)"
echo "aws iam create-open-id-connect-provider \\"
echo "  --url \$OIDC_URL \\"
echo "  --client-id-list sts.amazonaws.com \\"
echo "  --thumbprint-list $(echo | openssl s_client -servername oidc.eks.${AWS_REGION}.amazonaws.com -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null | openssl x509 -fingerprint -sha1 -noout | cut -d '=' -f 2 | tr -d ':' | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "THUMBPRINT_PLACEHOLDER")"
echo ""

echo "=============================================="
echo "Verification Commands"
echo "=============================================="
echo ""
echo "# Verify OIDC provider exists:"
echo "aws iam list-open-id-connect-providers --region ${AWS_REGION}"
echo ""
echo "# Get OIDC issuer for trust policy:"
echo "aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.identity.oidc.issuer' --output text"
