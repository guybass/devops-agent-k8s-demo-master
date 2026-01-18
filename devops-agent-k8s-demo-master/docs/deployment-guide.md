# Deployment Guide

This document provides step-by-step instructions for deploying the DevOps Agent Demo application to Amazon EKS.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Connect to EKS Cluster](#step-1-connect-to-eks-cluster)
- [Step 2: Setup OIDC and IAM Roles](#step-2-setup-oidc-and-iam-roles)
- [Step 3: Install External Secrets Operator](#step-3-install-external-secrets-operator)
- [Step 3.5: Install AWS Load Balancer Controller](#step-35-install-aws-load-balancer-controller)
- [Step 4: Configure Secrets](#step-4-configure-secrets)
- [Step 5: Update Configuration](#step-5-update-configuration)
- [Step 6: Choose Deployment Option](#step-6-choose-deployment-option)
- [Step 7: Verification](#step-7-verification)
- [GitOps with ArgoCD (Recommended)](#gitops-with-argocd-recommended)
- [Post-Deployment Tasks](#post-deployment-tasks)

## Prerequisites

### Required Tools

Install the following tools before proceeding:

| Tool | Minimum Version | Installation |
|------|-----------------|--------------|
| AWS CLI | v2.0+ | [Install Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| kubectl | v1.28+ | [Install Guide](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3.0+ | [Install Guide](https://helm.sh/docs/intro/install/) |
| eksctl | v0.150+ | [Install Guide](https://eksctl.io/introduction/#installation) |
| kustomize | v4.0+ | [Install Guide](https://kubectl.docs.kubernetes.io/installation/kustomize/) |
| jq | v1.6+ | `apt install jq` or `brew install jq` |

### Verify Installations

```bash
# Verify all tools
aws --version
kubectl version --client
helm version
eksctl version
kustomize version
jq --version
```

### AWS Credentials

Configure AWS CLI with credentials that have access to the EKS cluster:

```bash
# Configure AWS credentials
aws configure

# Verify credentials
aws sts get-caller-identity

# Expected output:
# {
#     "UserId": "AIDAXXXXXXXXXXXXXXXXX",
#     "Account": "852140462703",
#     "Arn": "arn:aws:iam::852140462703:user/your-user"
# }
```

### Required IAM Permissions

Your AWS user/role needs the following permissions:

- `eks:DescribeCluster`
- `eks:ListClusters`
- `iam:CreatePolicy` (for IAM setup)
- `iam:CreateRole` (for IAM setup)
- `iam:AttachRolePolicy` (for IAM setup)
- `secretsmanager:GetSecretValue` (for verification)

## Step 1: Connect to EKS Cluster

### Update kubeconfig

```bash
# Update kubeconfig for the EKS cluster
aws eks update-kubeconfig \
  --name demo-pre-prod-cluster \
  --region us-east-1

# Verify connection
kubectl cluster-info

# Expected output:
# Kubernetes control plane is running at https://XXXXX.gr7.us-east-1.eks.amazonaws.com
# CoreDNS is running at https://XXXXX.gr7.us-east-1.eks.amazonaws.com/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

### Verify Cluster Access

```bash
# Check nodes
kubectl get nodes

# Expected: List of worker nodes in Ready state

# Check existing namespaces
kubectl get namespaces

# Check your permissions
kubectl auth can-i create deployments --all-namespaces
# Expected: yes
```

### Troubleshooting: Private Endpoint

If your EKS cluster has a private endpoint only, you may need to:

1. Connect via VPN or bastion host
2. Use AWS Systems Manager Session Manager
3. Configure kubectl to use a proxy

```bash
# Example: Using SSM port forwarding
aws ssm start-session \
  --target i-xxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters "localPortNumber=6443,portNumber=443"

# Then update kubeconfig to use localhost:6443
```

## Step 2: Setup OIDC and IAM Roles

### 2.1 Configure OIDC Provider

```bash
# Associate OIDC provider with the cluster
eksctl utils associate-iam-oidc-provider \
  --cluster demo-pre-prod-cluster \
  --region us-east-1 \
  --approve

# Verify OIDC provider exists
aws iam list-open-id-connect-providers | grep $(aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' \
  --output text | cut -d '/' -f 5)
```

### 2.2 Create IAM Policies and Roles

```bash
# Navigate to the project directory
cd /path/to/devops-agent-k8s-demo

# Make scripts executable
chmod +x iam/01-oidc-provider.sh iam/02-create-iam-roles.sh

# Run the IAM setup script
./iam/02-create-iam-roles.sh

# Expected output:
# [Step 1] Getting OIDC Provider ID...
# OIDC Provider ID: XXXXXXXXXXXXXXXXXXXXX
# [Step 2] Creating IAM Policies...
# [Step 3] Generating trust policies...
# [Step 4] Creating IAM Roles...
# [Step 5] IAM Roles Created
```

### 2.3 Verify IAM Setup

```bash
# Verify roles were created
aws iam get-role --role-name devops-agent-demo-external-secrets-role
aws iam get-role --role-name devops-agent-demo-infrastructure-role
aws iam get-role --role-name devops-agent-demo-processing-role

# Verify policies are attached
aws iam list-attached-role-policies --role-name devops-agent-demo-external-secrets-role
```

## Step 3: Install External Secrets Operator

### 3.1 Add Helm Repository

```bash
# Add External Secrets Helm repository
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

### 3.2 Install the Operator

```bash
# Install External Secrets Operator
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --set webhook.port=9443 \
  --wait

# Verify installation
kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets

# Expected CRDs:
# clustersecretstores.external-secrets.io
# externalsecrets.external-secrets.io
# secretstores.external-secrets.io
```

### 3.3 Verify Operator is Running

```bash
# Check operator pods
kubectl get pods -n external-secrets

# Expected output:
# NAME                                         READY   STATUS    RESTARTS   AGE
# external-secrets-XXXXX-XXXXX                 1/1     Running   0          1m
# external-secrets-cert-controller-XXXXX       1/1     Running   0          1m
# external-secrets-webhook-XXXXX               1/1     Running   0          1m
```

## Step 3.5: Install AWS Load Balancer Controller

The AWS Load Balancer Controller is required for ALB-based ingress routing.

### 3.5.1 Create IAM Policy

```bash
# Download the IAM policy
curl -o /tmp/iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json

# Create the IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/iam-policy.json

# Note: If policy already exists, you may need to update it with:
# aws iam create-policy-version --policy-arn arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
#   --policy-document file:///tmp/iam-policy.json --set-as-default
```

**Important**: The IAM policy must include the `elasticloadbalancing:DescribeListenerAttributes` permission. If you encounter errors about this permission, update the policy:

```bash
# Add the missing permission if needed
aws iam get-policy-version \
  --policy-arn arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
  --version-id v1 | jq '.PolicyVersion.Document'

# If DescribeListenerAttributes is missing, download updated policy and create new version
```

### 3.5.2 Create IAM Role for Service Account

```bash
# Create IAM role with IRSA
eksctl create iamserviceaccount \
  --cluster=demo-pre-prod-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name=AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region=us-east-1
```

### 3.5.3 Install Controller via Helm

```bash
# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=demo-pre-prod-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=$(aws eks describe-cluster --name demo-pre-prod-cluster --query 'cluster.resourcesVpcConfig.vpcId' --output text)
```

### 3.5.4 Verify Controller Installation

```bash
# Check controller pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Expected output:
# NAME                                           READY   STATUS    RESTARTS   AGE
# aws-load-balancer-controller-xxxxxxxxx-xxxxx   1/1     Running   0          1m
# aws-load-balancer-controller-xxxxxxxxx-xxxxx   1/1     Running   0          1m

# Check controller logs for errors
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
```

## Step 4: Configure Secrets

### 4.1 Create Namespace

```bash
# Create the namespace first
kubectl apply -f base/namespace/namespace.yaml

# Verify
kubectl get namespace devops-agent-demo
```

### 4.2 Apply ServiceAccounts with IRSA

```bash
# Apply ServiceAccounts with IRSA annotations
kubectl apply -f iam/k8s-manifests/service-accounts-with-irsa.yaml

# Verify annotations
kubectl get sa -n devops-agent-demo
kubectl get sa external-secrets-sa -n devops-agent-demo -o yaml | grep eks.amazonaws.com
```

### 4.3 Enable External Secrets in Kustomization

Edit `base/kustomization.yaml` to enable External Secrets:

```yaml
# Uncomment the external-secrets line
resources:
  # ...
  - secrets/secrets.yaml
  - secrets/external-secrets.yaml  # <-- Uncomment this line
  - secrets/serviceaccount.yaml    # <-- Add if not present
```

### 4.4 Apply SecretStore and ExternalSecret

```bash
# Apply the External Secrets configuration
kubectl apply -f base/secrets/serviceaccount.yaml
kubectl apply -f base/secrets/external-secrets.yaml

# Verify SecretStore
kubectl get secretstore -n devops-agent-demo

# Expected output:
# NAME                   AGE   STATUS   CAPABILITIES   READY
# aws-secrets-manager    1m    Valid    ReadWrite      True

# Verify ExternalSecrets (both database and Redis)
kubectl get externalsecret -n devops-agent-demo

# Expected output:
# NAME                           STORE                 REFRESH INTERVAL   STATUS         READY
# database-credentials-external  aws-secrets-manager   1h                 SecretSynced   True
# redis-credentials-external     aws-secrets-manager   1h                 SecretSynced   True

# Verify Kubernetes Secrets were created
kubectl get secret database-credentials -n devops-agent-demo
kubectl get secret redis-credentials -n devops-agent-demo
```

### 4.5 Troubleshooting Secrets Sync

If the ExternalSecret shows errors:

```bash
# Check ExternalSecret status
kubectl describe externalsecret database-credentials-external -n devops-agent-demo
kubectl describe externalsecret redis-credentials-external -n devops-agent-demo

# Check operator logs
kubectl logs -l app.kubernetes.io/name=external-secrets -n external-secrets

# Common issues:
# - SecretStore authentication failed: Check IRSA configuration
# - Secret not found: Check secret path in AWS Secrets Manager
# - Access denied: Check IAM policy permissions
```

## Step 5: Update Configuration

### Important: Kustomize namePrefix and Service URLs

When using overlays that apply a `namePrefix` (like `dev-` in `dev-no-domain`), all Kubernetes resource names are prefixed automatically. This includes:

- Deployments
- Services
- ConfigMaps
- Secrets
- ServiceAccounts

**Gotcha:** ConfigMap values that reference service URLs are NOT automatically updated. You must manually patch these values to include the prefix.

For example, if using `namePrefix: dev-`:

```yaml
# Wrong - services won't be found
AUTH_SERVICE_URL: "http://auth-service:8002"

# Correct - matches the prefixed service name
AUTH_SERVICE_URL: "http://dev-auth-service:8002"
```

The `dev-no-domain` overlay includes a patch for this in `overlays/dev-no-domain/app/kustomization.yaml`. See [Troubleshooting - Issue #7](./troubleshooting.md#7-service-urls-missing-dev--prefix-in-configmap) for more details.

### 5.1 Update ECR Image References

Replace placeholder values with your actual ECR repository URLs:

```bash
# Option 1: Using sed
find base/deployments -name "*.yaml" -exec sed -i \
  's/AWS_ACCOUNT_ID/852140462703/g; s/AWS_REGION/us-east-1/g' {} \;

# Option 2: Using kustomize (in overlays)
# Images are already configured in overlay kustomization.yaml files
```

### 5.2 Update Ingress Configuration (for host-based routing)

Edit `base/ingress/ingress.yaml` if using the `dev`, `staging`, or `production` overlays:

```yaml
spec:
  rules:
    - host: app.your-domain.com    # Update with your domain
    - host: admin.your-domain.com  # Update with your domain
    - host: api.your-domain.com    # Update with your domain
```

Add SSL certificate ARN if using HTTPS:

```yaml
annotations:
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:852140462703:certificate/xxxxx
```

### 5.3 Configure Security Groups (Optional)

```yaml
annotations:
  alb.ingress.kubernetes.io/security-groups: sg-xxxxxxxxxxxxx
```

## Step 6: Choose Deployment Option

We provide five deployment overlays to suit different scenarios:

### Option A: Development with Domain (`overlays/dev`)

For development with custom domain names configured in DNS.

```bash
# Preview what will be deployed
kubectl kustomize overlays/dev

# Deploy
kubectl apply -k overlays/dev

# Access via your configured domain names:
# - app.devops-agent-demo.example.com
# - admin.devops-agent-demo.example.com
# - api.devops-agent-demo.example.com
```

### Option B: Development without Domain (`overlays/dev-no-domain`) - CURRENTLY DEPLOYED

For development without a domain name. Uses path-based routing on the ALB's auto-generated DNS name.

```bash
# Preview what will be deployed
kubectl kustomize overlays/dev-no-domain

# Deploy
kubectl apply -k overlays/dev-no-domain

# Wait for ALB to provision (may take 2-5 minutes)
kubectl get ingress -n devops-agent-demo -w

# Get the ALB DNS name
ALB_DNS=$(kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"

# Current ALB URL:
# http://k8s-devopsag-devdevop-1bb3545a8a-469037918.us-east-1.elb.amazonaws.com

# Access URLs:
# - Web UI:          http://<ALB_DNS>/
# - Admin Dashboard: http://<ALB_DNS>/admin/
# - API Gateway:     http://<ALB_DNS>/api/
```

**Configuration Details:**

| Setting | Value |
|---------|-------|
| Replicas | 1 per service (scaled down for dev) |
| HPAs | Disabled (removed in overlay) |
| SSL/TLS | Disabled (HTTP only) |
| Inbound CIDR | `79.181.131.147/32` (restricted access) |

**Path-Based Routing Explanation:**

With `dev-no-domain`, the ingress uses path prefixes instead of hostnames:

| Path | Service | Description |
|------|---------|-------------|
| `/` | web-ui | Main web application (catch-all) |
| `/admin` | admin-dashboard | Admin interface |
| `/api` | api-gateway | API endpoints |

**Important:** When using path-based routing, the ALB forwards the full path to the backend. For example, `/api/auth/register` is forwarded as-is to the API Gateway. The API Gateway must be configured to handle routes with the `/api` prefix. See [Troubleshooting - Issue #8](./troubleshooting.md#8-api-gateway-route-prefix-missing-for-alb-path-based-routing) for details.

**Ingress Annotations:**

```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
  alb.ingress.kubernetes.io/inbound-cidrs: "79.181.131.147/32"
  # Note: SSL redirect disabled (no HTTPS listener configured)
```

The routing is configured in `overlays/dev-no-domain/ingress-patch.yaml`:

```yaml
spec:
  rules:
    - http:  # No host specified - matches any hostname
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-gateway
                port:
                  number: 8080
          - path: /admin
            pathType: Prefix
            backend:
              service:
                name: admin-dashboard
                port:
                  number: 3001
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-ui
                port:
                  number: 3000
```

### Option C: Development with Port Forward (`overlays/dev-port-forward`)

For local development without any ingress. Access services via kubectl port-forward.

```bash
# Preview what will be deployed
kubectl kustomize overlays/dev-port-forward

# Deploy (no ingress will be created)
kubectl apply -k overlays/dev-port-forward

# Wait for pods to be ready
kubectl get pods -n devops-agent-demo -w

# Forward ports to access services locally (run in separate terminals)

# Terminal 1: Web UI
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo

# Terminal 2: Admin Dashboard
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo

# Terminal 3: API Gateway
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo

# Access URLs:
# - Web UI:          http://localhost:3000
# - Admin Dashboard: http://localhost:3001
# - API Gateway:     http://localhost:8080
```

**Port-Forward Tips:**

```bash
# Forward all three services in background (Bash)
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo &
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo &
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo &

# List background jobs
jobs

# Stop all port-forwards
killall kubectl
```

### Option D: Staging Environment (`overlays/staging`)

For pre-production testing with production-like configuration.

```bash
kubectl apply -k overlays/staging
```

### Option E: Production Environment (`overlays/production`)

For production deployment with full HA configuration.

```bash
kubectl apply -k overlays/production
```

### Deployment Comparison

| Feature | dev | dev-no-domain | dev-port-forward | staging | production |
|---------|-----|---------------|------------------|---------|------------|
| Replicas | 1 | 1 | 1 | 2 | 3+ |
| Ingress | Yes (host-based) | Yes (path-based) | No | Yes | Yes |
| Domain Required | Yes | No | No | Yes | Yes |
| ALB Created | Yes | Yes | No | Yes | Yes |
| Log Level | DEBUG | DEBUG | DEBUG | INFO | WARN |
| HPA Enabled | Limited | Limited | Limited | Yes | Yes |
| Best For | Dev with DNS | Dev without DNS | Local dev | Pre-prod testing | Production |

### Option F: GitOps with ArgoCD (Recommended)

For production-ready GitOps workflow with automated deployments. See [GitOps with ArgoCD](#gitops-with-argocd-recommended) section below.

## Step 7: Verification

### 7.1 Check All Resources

```bash
# Get all resources in the namespace
kubectl get all -n devops-agent-demo

# Check pods
kubectl get pods -n devops-agent-demo -o wide

# Check services
kubectl get svc -n devops-agent-demo

# Check ingress (if applicable)
kubectl get ingress -n devops-agent-demo

# Check HPA
kubectl get hpa -n devops-agent-demo

# Check PDB
kubectl get pdb -n devops-agent-demo

# Check External Secrets
kubectl get externalsecret -n devops-agent-demo
```

### 7.2 Verify Pod Health

```bash
# Check all pods are running
kubectl get pods -n devops-agent-demo

# Expected: All pods should show STATUS=Running and READY=1/1

# Check for any issues
kubectl get pods -n devops-agent-demo | grep -v Running

# Describe problematic pods
kubectl describe pod <pod-name> -n devops-agent-demo

# Check logs
kubectl logs <pod-name> -n devops-agent-demo
```

### 7.3 Verify Ingress and ALB

```bash
# Get ingress details
kubectl get ingress devops-agent-demo-ingress -n devops-agent-demo

# Get ALB address (for dev-no-domain)
kubectl get ingress -n devops-agent-demo \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'

# Test the endpoint
# For dev-no-domain:
curl -v http://<alb-url>/health
curl -v http://<alb-url>/api/health
curl -v http://<alb-url>/admin/health
```

### 7.4 Verify Service Connectivity

```bash
# Test internal DNS resolution
kubectl run debug --rm -it --image=busybox -n devops-agent-demo -- \
  nslookup api-gateway.devops-agent-demo.svc.cluster.local

# Test service connectivity
kubectl run debug --rm -it --image=curlimages/curl -n devops-agent-demo -- \
  curl http://api-gateway:8080/health

# Test database connectivity (from db-proxy pod)
kubectl exec -it deployment/db-proxy -n devops-agent-demo -- \
  sh -c 'echo "SELECT 1" | psql $DATABASE_URL'
```

### 7.5 Verify Secrets

```bash
# Check if secrets are populated
kubectl get secret database-credentials -n devops-agent-demo -o jsonpath='{.data.DB_HOST}' | base64 -d
kubectl get secret redis-credentials -n devops-agent-demo -o jsonpath='{.data.REDIS_HOST}' | base64 -d

# Verify secret is mounted in pods
kubectl exec -it deployment/db-proxy -n devops-agent-demo -- env | grep DB_
kubectl exec -it deployment/cache-manager -n devops-agent-demo -- env | grep REDIS_
```

## Post-Deployment Tasks

### Configure DNS (for host-based routing)

Point your domain names to the ALB:

```bash
# Get ALB hostname
ALB_HOSTNAME=$(kubectl get ingress devops-agent-demo-ingress -n devops-agent-demo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Configure these DNS records:"
echo "app.your-domain.com  -> CNAME -> $ALB_HOSTNAME"
echo "admin.your-domain.com -> CNAME -> $ALB_HOSTNAME"
echo "api.your-domain.com   -> CNAME -> $ALB_HOSTNAME"
```

### Enable Monitoring

```bash
# Verify Prometheus annotations
kubectl get pods -n devops-agent-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.prometheus\.io/scrape}{"\n"}{end}'

# If using Prometheus Operator, create ServiceMonitor
# kubectl apply -f monitoring/servicemonitor.yaml
```

### Setup Alerts

Configure alerts for:
- Pod restarts
- High error rates
- Resource exhaustion
- External secret sync failures

### Backup Configuration

```bash
# Export current configuration
kubectl get all -n devops-agent-demo -o yaml > backup/all-resources.yaml
kubectl get secrets -n devops-agent-demo -o yaml > backup/secrets.yaml
kubectl get configmaps -n devops-agent-demo -o yaml > backup/configmaps.yaml
```

## Deployment Checklist

Use this checklist to verify your deployment:

- [ ] EKS cluster accessible via kubectl
- [ ] OIDC provider configured
- [ ] IAM roles and policies created
- [ ] External Secrets Operator installed
- [ ] SecretStore status is Valid/Ready
- [ ] ExternalSecrets status is SecretSynced/Ready (both database and Redis)
- [ ] Kubernetes Secrets created from AWS Secrets Manager
- [ ] All pods are Running and Ready
- [ ] Services have endpoints
- [ ] Ingress has ALB address (if applicable)
- [ ] Health endpoints responding
- [ ] DNS configured (if using host-based routing)
- [ ] HTTPS/TLS configured (if applicable)
- [ ] Monitoring enabled
- [ ] Alerts configured

## Rollback Procedure

If deployment fails:

```bash
# Check rollout history
kubectl rollout history deployment/<name> -n devops-agent-demo

# Rollback to previous version
kubectl rollout undo deployment/<name> -n devops-agent-demo

# Rollback to specific revision
kubectl rollout undo deployment/<name> -n devops-agent-demo --to-revision=2

# Rollback all deployments
kubectl get deployments -n devops-agent-demo -o name | \
  xargs -I {} kubectl rollout undo {} -n devops-agent-demo
```

## Switching Between Overlays

To switch from one overlay to another:

```bash
# First, delete the current deployment
kubectl delete -k overlays/dev-no-domain

# Then deploy the new overlay
kubectl apply -k overlays/dev-port-forward
```

Or to avoid downtime, apply the new overlay over the existing one (may leave orphaned resources):

```bash
# Apply new overlay (resources will be updated)
kubectl apply -k overlays/dev-port-forward

# Clean up any orphaned ingress if switching to port-forward
kubectl delete ingress --all -n devops-agent-demo
```

## GitOps with ArgoCD (Recommended)

ArgoCD provides automated, declarative GitOps-based continuous delivery. This is the recommended approach for production deployments.

### ArgoCD Overview

| Feature | Description |
|---------|-------------|
| Auto-sync | Automatically deploys changes pushed to Git |
| Self-heal | Corrects drift from desired state |
| Auto-prune | Removes resources no longer in Git |
| Audit Trail | Full history of all deployments via Git |
| Rollback | Easy rollback to any previous revision |

### Step 1: Create ArgoCD AWS Secrets

Create the required secrets in AWS Secrets Manager:

```bash
# Create GitHub SSH key secret
aws secretsmanager create-secret \
  --name argocd/github-ssh-key \
  --description "GitHub SSH private key for ArgoCD repository access" \
  --secret-string '{"sshPrivateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"}' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=argocd \
  --region us-east-1

# Create Redis password secret
aws secretsmanager create-secret \
  --name argocd/redis \
  --description "Redis password for ArgoCD" \
  --secret-string '{"password":"your-redis-password"}' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=argocd \
  --region us-east-1
```

### Step 2: Create ArgoCD IAM Resources

```bash
# Get OIDC ID
OIDC_ID=$(aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' \
  --output text | cut -d '/' -f 5)

# Create IAM policy
aws iam create-policy \
  --policy-name ArgoCD-ExternalSecrets-Policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        "Resource": ["arn:aws:secretsmanager:us-east-1:852140462703:secret:argocd/*"]
      }
    ]
  }'

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
  --assume-role-policy-document file:///tmp/argocd-trust-policy.json

# Attach policy
aws iam attach-role-policy \
  --role-name ArgoCD-ExternalSecrets-Role \
  --policy-arn arn:aws:iam::852140462703:policy/ArgoCD-ExternalSecrets-Policy
```

### Step 3: Deploy ArgoCD

```bash
# Navigate to project directory
cd /path/to/devops-agent-k8s-demo

# Deploy ArgoCD infrastructure (includes namespace, manifests, ingress, and external secrets)
kubectl apply -k infrastructure/argocd

# Wait for ArgoCD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Verify ArgoCD pods
kubectl get pods -n argocd
```

### Step 4: Verify ArgoCD Secrets

```bash
# Check SecretStore status
kubectl get secretstore -n argocd

# Check ExternalSecrets status
kubectl get externalsecret -n argocd

# Verify secrets were created
kubectl get secret github-repo-creds -n argocd
kubectl get secret argocd-redis -n argocd
```

### Step 5: Deploy ArgoCD Applications

```bash
# Deploy ArgoCD applications (project and application definitions)
kubectl apply -k argocd-apps

# Verify application was created
kubectl get applications -n argocd
```

### Step 6: Access ArgoCD UI

```bash
# Get ArgoCD URL
kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

# Login via CLI (optional)
argocd login <ALB_DNS> --username admin --password <password> --insecure
```

### Step 7: Verify Application Sync

```bash
# Check application status
kubectl get applications -n argocd

# Expected output:
# NAME                    SYNC STATUS   HEALTH STATUS
# devops-agent-demo-dev   Synced        Healthy

# View application details
argocd app get devops-agent-demo-dev
```

### ArgoCD Deployment Workflow

Once ArgoCD is configured, deployments are automated:

1. **Make changes** to Kubernetes manifests in your repository
2. **Commit and push** the changes to Git
3. **ArgoCD detects** the change (via webhook or polling)
4. **ArgoCD syncs** the changes to the cluster automatically
5. **Verify** the deployment in ArgoCD UI or CLI

```bash
# Example: Update replica count
git add overlays/dev-no-domain/
git commit -m "Increase web-ui replicas to 2"
git push origin main

# ArgoCD will automatically sync within 3 minutes (or immediately with webhook)
# Monitor sync status:
argocd app get devops-agent-demo-dev
```

### ArgoCD Components Deployed

| Component | Location | Description |
|-----------|----------|-------------|
| Namespace | `infrastructure/argocd/namespace.yaml` | ArgoCD namespace |
| Manifests | `infrastructure/argocd/manifests.yaml` | Helm-templated ArgoCD (v7.7.10) |
| Ingress | `infrastructure/argocd/ingress.yaml` | ALB ingress for ArgoCD UI |
| SecretStore | `infrastructure/argocd/secret-store.yaml` | AWS Secrets Manager connection |
| GitHub Secret | `infrastructure/argocd/repository-secret.yaml` | SSH key for Git access |
| Redis Secret | `infrastructure/argocd/redis-secret.yaml` | Redis password |
| ServiceAccount | `infrastructure/argocd/external-secrets-sa.yaml` | IRSA-enabled SA |
| AppProject | `argocd-apps/project.yaml` | Project definition |
| Application | `argocd-apps/app-dev-no-domain.yaml` | Application syncing dev-no-domain overlay |

### Shared CIDR Configuration

IP whitelisting is managed centrally via a ConfigMap:

**File:** `overlays/dev-no-domain/allowed-cidrs.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: allowed-cidrs
  namespace: devops-agent-demo
data:
  cidrs: "79.181.131.147/32"
```

This value is injected into both the application ingress and ArgoCD ingress using Kustomize replacements, providing a single source of truth for IP whitelisting.

### Updating the IP Whitelist

```bash
# Edit the allowed-cidrs.yaml file
# Change: cidrs: "79.181.131.147/32"
# To: cidrs: "79.181.131.147/32,10.0.0.0/8"

# Commit and push
git add overlays/dev-no-domain/allowed-cidrs.yaml
git commit -m "Add internal network to IP whitelist"
git push origin main

# ArgoCD will automatically sync the change
```

For detailed ArgoCD configuration, see [ArgoCD Setup](./argocd-setup.md).

## Next Steps

- Review the [Troubleshooting Guide](./troubleshooting.md) for common issues
- Review the [ArgoCD Setup](./argocd-setup.md) for detailed GitOps configuration
- Implement canary or blue-green deployments with ArgoCD Rollouts
- Configure ArgoCD notifications for deployment alerts
