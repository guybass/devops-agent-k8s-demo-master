#!/bin/bash
#
# Simple script to get and print ALB URL
# Usage: ./get-alb-url.sh
#

CLUSTER_NAME="demo-pre-prod-cluster"
REGION="${AWS_DEFAULT_REGION:-us-east-2}"

# Configure kubectl if needed
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1

# Get and print URL
URL=$(kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

if [[ -n "$URL" ]]; then
    echo "ALB_URL=http://$URL"
else
    echo "ALB_URL=NOT_READY"
fi
