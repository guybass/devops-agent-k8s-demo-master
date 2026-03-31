#!/bin/bash
# Fix missing IAM roles for EKS cluster
# Run on EC2: bash scripts/fix-iam-roles.sh

set -e

OIDC="oidc.eks.us-east-2.amazonaws.com/id/44CE8DEBE88BE7CCA95850A4BE818542"
ACCOUNT="852140462703"
REGION="us-east-2"

echo "=== Step 1: Create ALB Controller Trust Policy ==="
python3 -c "
import json
oidc='$OIDC'
d={
  'Version':'2012-10-17',
  'Statement':[{
    'Effect':'Allow',
    'Principal':{'Federated':'arn:aws:iam::${ACCOUNT}:oidc-provider/'+oidc},
    'Action':'sts:AssumeRoleWithWebIdentity',
    'Condition':{'StringEquals':{
      oidc+':aud':'sts.amazonaws.com',
      oidc+':sub':'system:serviceaccount:kube-system:aws-load-balancer-controller'
    }}
  }]
}
json.dump(d,open('/tmp/alb-trust.json','w'))
print('Trust policy written to /tmp/alb-trust.json')
"

echo "=== Step 2: Delete existing broken role (if any) ==="
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole 2>/dev/null && echo "Deleted old role" || echo "No old role to delete"

echo "=== Step 3: Create ALB Controller Role ==="
aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file:///tmp/alb-trust.json

echo "=== Step 4: Download ALB Controller IAM Policy ==="
curl -sL -o /tmp/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
echo "Downloaded ALB IAM policy"

echo "=== Step 5: Create IAM Policy ==="
POLICY_ARN=$(aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json \
  --query "Policy.Arn" --output text 2>/dev/null) || \
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/AWSLoadBalancerControllerIAMPolicy"
echo "Policy ARN: $POLICY_ARN"

echo "=== Step 6: Attach Policy to Role ==="
aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn "$POLICY_ARN"
echo "Policy attached"

echo "=== Step 7: Restart ALB Controller ==="
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system
echo "ALB controller restarting"

echo "=== Step 8: Wait and verify ==="
sleep 15
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
echo ""
echo "=== Checking ALB controller logs ==="
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=10 2>/dev/null
echo ""
echo "=== Checking ingress ==="
kubectl get ingress -A
echo ""
echo "=== DONE ==="
echo "If ingress still has no ADDRESS, wait 2-3 minutes and run:"
echo "  kubectl get ingress -A"
