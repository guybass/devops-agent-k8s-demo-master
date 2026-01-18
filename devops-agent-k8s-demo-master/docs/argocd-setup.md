# ArgoCD Setup Documentation

This document provides comprehensive documentation for the ArgoCD GitOps implementation in the DevOps Agent Demo project.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Installation](#installation)
- [Secrets Management](#secrets-management)
- [Access Configuration](#access-configuration)
- [ArgoCD Applications](#argocd-applications)
- [Shared CIDR Configuration](#shared-cidr-configuration)
- [IAM Configuration](#iam-configuration)
- [Usage Guide](#usage-guide)
- [Troubleshooting](#troubleshooting)

## Overview

ArgoCD provides GitOps-based continuous delivery for the DevOps Agent Demo application. It automatically syncs Kubernetes manifests from the Git repository to the EKS cluster, ensuring the cluster state matches the desired state defined in Git.

### Key Features

- **GitOps Workflow**: All changes go through Git, providing full audit trail
- **Auto-Sync**: Automatic deployment when changes are pushed to the repository
- **Self-Heal**: Automatically corrects drift from desired state
- **Auto-Prune**: Removes resources that are no longer in Git
- **Secure Secrets**: GitHub SSH keys and Redis password managed via External Secrets

### Current Status

| Component | Status | Details |
|-----------|--------|---------|
| ArgoCD Installation | Complete | Helm-templated manifests (v7.7.10) |
| External Secrets Integration | Complete | GitHub SSH key and Redis password synced |
| IRSA Configuration | Complete | ArgoCD-ExternalSecrets-Role |
| ALB Ingress | Complete | Path-based routing with IP whitelist |
| Application Configuration | Complete | devops-agent-demo-dev application syncing |

## Architecture

### Directory Structure

```
devops-agent-k8s-demo/
|
+-- infrastructure/
|   +-- argocd/
|       +-- namespace.yaml              # ArgoCD namespace definition
|       +-- kustomization.yaml          # Kustomize configuration
|       +-- values.yaml                 # Helm values for argo-cd chart
|       +-- manifests.yaml              # Helm-templated ArgoCD manifests
|       +-- ingress.yaml                # ALB Ingress for ArgoCD UI
|       +-- secret-store.yaml           # SecretStore for ArgoCD namespace
|       +-- repository-secret.yaml      # ExternalSecret for GitHub SSH key
|       +-- redis-secret.yaml           # ExternalSecret for Redis password
|       +-- external-secrets-sa.yaml    # ServiceAccount with IRSA
|
+-- argocd-apps/
|   +-- kustomization.yaml              # Kustomize for ArgoCD apps
|   +-- project.yaml                    # AppProject definition
|   +-- app-dev-no-domain.yaml          # Application for dev-no-domain overlay
|
+-- overlays/
    +-- dev-no-domain/
        +-- allowed-cidrs.yaml          # Shared CIDR ConfigMap
        +-- kustomization.yaml          # Updated with CIDR replacements
```

### Component Diagram

```
+-----------------------------------------------------------------------------------+
|                                    AWS Cloud                                       |
|                                                                                   |
|   +------------------------+         +------------------------+                   |
|   | AWS Secrets Manager    |         | AWS Secrets Manager    |                   |
|   |                        |         |                        |                   |
|   | Secret:                |         | Secret:                |                   |
|   | argocd/github-ssh-key  |         | argocd/redis           |                   |
|   |  - sshPrivateKey       |         |  - password            |                   |
|   +------------+-----------+         +------------+-----------+                   |
|                |                                  |                               |
|                +----------------------------------+                               |
|                                |                                                  |
|                                | (1) GetSecretValue via IRSA                      |
|                                v                                                  |
|   +----------------------------+------------------+                               |
|   | IAM Role                                      |                               |
|   | ArgoCD-ExternalSecrets-Role                   |                               |
|   | Policy: ArgoCD-ExternalSecrets-Policy         |                               |
|   | Access: argocd/* secrets                      |                               |
|   +----------------------------+------------------+                               |
|                                |                                                  |
+-----------------------------------------------------------------------------------+
                                 |
                                 | (2) Web Identity Token
                                 v
+-----------------------------------------------------------------------------------+
|                              EKS Cluster                                          |
|                                                                                   |
|   +-----------------------------------------------------------------------+       |
|   |                         argocd namespace                              |       |
|   |                                                                       |       |
|   |   +-------------------+                                               |       |
|   |   | ServiceAccount    |                                               |       |
|   |   | external-secrets- |  (IRSA: ArgoCD-ExternalSecrets-Role)          |       |
|   |   | sa                |                                               |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |            v                                                          |       |
|   |   +--------+----------+                                               |       |
|   |   | SecretStore       |                                               |       |
|   |   | argocd-aws-       |                                               |       |
|   |   | secrets-manager   |                                               |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |     +------+------+                                                   |       |
|   |     |             |                                                   |       |
|   |     v             v                                                   |       |
|   |  +--+----------+  +--+----------+                                     |       |
|   |  |ExternalSecret|  |ExternalSecret|                                   |       |
|   |  |github-ssh-  |  |argocd-redis |                                     |       |
|   |  |key          |  |             |                                     |       |
|   |  +------+------+  +------+------+                                     |       |
|   |         |                |                                            |       |
|   |         v                v                                            |       |
|   |  +------+------+  +------+------+                                     |       |
|   |  | K8s Secret  |  | K8s Secret  |                                     |       |
|   |  | github-repo |  | argocd-     |                                     |       |
|   |  | -creds      |  | redis       |                                     |       |
|   |  +------+------+  +------+------+                                     |       |
|   |         |                |                                            |       |
|   |         v                v                                            |       |
|   |  +------+----------------+------+                                     |       |
|   |  |       ArgoCD Components      |                                     |       |
|   |  | - argocd-server              |                                     |       |
|   |  | - argocd-repo-server         |                                     |       |
|   |  | - argocd-application-ctrl    |                                     |       |
|   |  | - argocd-redis               |                                     |       |
|   |  +------------------------------+                                     |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
|                                                                                   |
|   +-----------------------------------------------------------------------+       |
|   |                    devops-agent-demo namespace                        |       |
|   |                                                                       |       |
|   |   Managed by ArgoCD Application: devops-agent-demo-dev                |       |
|   |   Source: overlays/dev-no-domain                                      |       |
|   |   Sync: Auto-sync, Self-heal, Auto-prune enabled                      |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

## Installation

### Prerequisites

- External Secrets Operator installed cluster-wide
- AWS Secrets Manager secrets created for ArgoCD
- OIDC provider configured for the EKS cluster

### Step 1: Create AWS Secrets

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

### Step 2: Create IAM Resources

See [IAM Configuration](#iam-configuration) section for details.

### Step 3: Deploy ArgoCD

```bash
# Navigate to project directory
cd /path/to/devops-agent-k8s-demo

# Deploy ArgoCD infrastructure
kubectl apply -k infrastructure/argocd

# Wait for ArgoCD pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Verify deployment
kubectl get pods -n argocd
```

### Step 4: Deploy ArgoCD Applications

```bash
# Deploy ArgoCD applications
kubectl apply -k argocd-apps

# Verify application status
kubectl get applications -n argocd
```

### Installed Components

| Component | Description |
|-----------|-------------|
| argocd-server | API server and UI |
| argocd-repo-server | Repository server for Git operations |
| argocd-application-controller | Syncs applications to desired state |
| argocd-redis | Caching layer for ArgoCD |
| argocd-dex-server | SSO/OIDC provider (optional) |
| argocd-notifications-controller | Notifications (optional) |

## Secrets Management

### GitHub SSH Key

The GitHub SSH key allows ArgoCD to clone private repositories.

**AWS Secret Path:** `argocd/github-ssh-key`

**Secret Structure:**
```json
{
  "sshPrivateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"
}
```

**ExternalSecret Configuration:**

File: `infrastructure/argocd/repository-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: github-ssh-key
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: argocd-aws-secrets-manager
    kind: SecretStore
  target:
    name: github-repo-creds
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repository
      data:
        type: "git"
        url: "git@github.com:your-org/devops-agent-k8s-demo.git"
        sshPrivateKey: "{{ .sshPrivateKey }}"
  data:
    - secretKey: sshPrivateKey
      remoteRef:
        key: argocd/github-ssh-key
        property: sshPrivateKey
```

### Redis Password

The Redis password secures the ArgoCD Redis cache.

**AWS Secret Path:** `argocd/redis`

**Secret Structure:**
```json
{
  "password": "your-secure-redis-password"
}
```

**ExternalSecret Configuration:**

File: `infrastructure/argocd/redis-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-redis
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: argocd-aws-secrets-manager
    kind: SecretStore
  target:
    name: argocd-redis
    creationPolicy: Owner
  data:
    - secretKey: auth
      remoteRef:
        key: argocd/redis
        property: password
```

### SecretStore Configuration

File: `infrastructure/argocd/secret-store.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: argocd-aws-secrets-manager
  namespace: argocd
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

### Verification Commands

```bash
# Check SecretStore status
kubectl get secretstore -n argocd
kubectl describe secretstore argocd-aws-secrets-manager -n argocd

# Check ExternalSecrets status
kubectl get externalsecret -n argocd
kubectl describe externalsecret github-ssh-key -n argocd
kubectl describe externalsecret argocd-redis -n argocd

# Verify secrets were created
kubectl get secret github-repo-creds -n argocd
kubectl get secret argocd-redis -n argocd

# Force refresh secrets
kubectl annotate externalsecret github-ssh-key -n argocd force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret argocd-redis -n argocd force-sync=$(date +%s) --overwrite
```

## Access Configuration

### ALB Ingress

ArgoCD is exposed via an AWS Application Load Balancer with path-based routing.

**Ingress Configuration:**

File: `infrastructure/argocd/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/inbound-cidrs: "79.181.131.147/32"
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

### Access Details

| Setting | Value |
|---------|-------|
| URL | `http://<ALB_DNS>/` |
| Protocol | HTTP (no TLS) |
| IP Whitelist | Configured via `allowed-cidrs.yaml` |
| Authentication | ArgoCD built-in (admin user) |

### Getting the ArgoCD URL

```bash
# Get ArgoCD ALB URL
kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Initial Admin Password

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

# Login via CLI
argocd login <ALB_DNS> --username admin --password <password> --insecure
```

### Shared CIDR Configuration

The IP whitelist is managed via a shared ConfigMap that is injected into both the application ingress and ArgoCD ingress using Kustomize replacements.

File: `overlays/dev-no-domain/allowed-cidrs.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: allowed-cidrs
  namespace: devops-agent-demo
data:
  cidrs: "79.181.131.147/32"
```

This provides a single source of truth for IP whitelisting across all ingresses.

## ArgoCD Applications

### AppProject

File: `argocd-apps/project.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: devops-agent-demo
  namespace: argocd
spec:
  description: DevOps Agent Demo Project
  sourceRepos:
    - 'git@github.com:your-org/devops-agent-k8s-demo.git'
  destinations:
    - namespace: devops-agent-demo
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

### Application: devops-agent-demo-dev

File: `argocd-apps/app-dev-no-domain.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devops-agent-demo-dev
  namespace: argocd
spec:
  project: devops-agent-demo
  source:
    repoURL: git@github.com:your-org/devops-agent-k8s-demo.git
    targetRevision: main
    path: overlays/dev-no-domain
  destination:
    server: https://kubernetes.default.svc
    namespace: devops-agent-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Sync Policy Details

| Setting | Value | Description |
|---------|-------|-------------|
| `automated.prune` | true | Remove resources not in Git |
| `automated.selfHeal` | true | Correct drift from desired state |
| `automated.allowEmpty` | false | Prevent sync if source is empty |
| `CreateNamespace` | true | Create namespace if not exists |
| `PrunePropagationPolicy` | foreground | Wait for dependents before pruning |
| `PruneLast` | true | Prune after other syncs complete |

### Application Management

```bash
# List applications
kubectl get applications -n argocd

# Get application status
argocd app get devops-agent-demo-dev

# Sync application manually
argocd app sync devops-agent-demo-dev

# View application history
argocd app history devops-agent-demo-dev

# Rollback to previous version
argocd app rollback devops-agent-demo-dev <revision>

# Refresh application (check for updates)
argocd app refresh devops-agent-demo-dev
```

## Shared CIDR Configuration

### Overview

The IP whitelist for ALB ingresses is managed centrally using a ConfigMap and Kustomize replacements. This ensures both the application ingress and ArgoCD ingress use the same IP whitelist.

### Configuration Files

**ConfigMap:** `overlays/dev-no-domain/allowed-cidrs.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: allowed-cidrs
  namespace: devops-agent-demo
data:
  cidrs: "79.181.131.147/32"
```

**Kustomization Replacements:**

In `overlays/dev-no-domain/kustomization.yaml`:

```yaml
replacements:
  - source:
      kind: ConfigMap
      name: allowed-cidrs
      fieldPath: data.cidrs
    targets:
      - select:
          kind: Ingress
          name: devops-agent-demo-ingress
        fieldPaths:
          - metadata.annotations.[alb.ingress.kubernetes.io/inbound-cidrs]
```

### Updating the IP Whitelist

To update the allowed CIDRs:

1. Edit `overlays/dev-no-domain/allowed-cidrs.yaml`
2. Commit and push the change
3. ArgoCD will automatically sync the update

```bash
# Manual update example
kubectl patch configmap allowed-cidrs -n devops-agent-demo \
  --type merge -p '{"data":{"cidrs":"79.181.131.147/32,10.0.0.0/8"}}'
```

## IAM Configuration

### IAM Policy

**Policy Name:** `ArgoCD-ExternalSecrets-Policy`

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

### IAM Role

**Role Name:** `ArgoCD-ExternalSecrets-Role`

**Trust Policy:**

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
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:argocd:external-secrets-sa",
          "oidc.eks.us-east-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### ServiceAccount

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

### Creating IAM Resources

```bash
# Create IAM policy
aws iam create-policy \
  --policy-name ArgoCD-ExternalSecrets-Policy \
  --policy-document file://iam/policies/argocd-secrets-policy.json \
  --description "Policy for ArgoCD to access secrets in AWS Secrets Manager"

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

## Usage Guide

### Deploying Changes

With ArgoCD configured, deployments are triggered automatically when changes are pushed to Git:

1. Make changes to Kubernetes manifests
2. Commit and push to the repository
3. ArgoCD detects the change and syncs automatically

```bash
# Example workflow
git add overlays/dev-no-domain/
git commit -m "Update replica count"
git push origin main

# ArgoCD will automatically detect and sync the change
# Monitor sync status:
argocd app get devops-agent-demo-dev
```

### Manual Sync

```bash
# Sync with prune
argocd app sync devops-agent-demo-dev --prune

# Sync specific resources
argocd app sync devops-agent-demo-dev --resource deployment:web-ui

# Dry run
argocd app sync devops-agent-demo-dev --dry-run
```

### Viewing Application Status

```bash
# Via CLI
argocd app get devops-agent-demo-dev

# Via kubectl
kubectl get applications devops-agent-demo-dev -n argocd -o yaml

# View resources managed by application
argocd app resources devops-agent-demo-dev
```

### Accessing ArgoCD UI

1. Get the ALB URL:
   ```bash
   kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
   ```

2. Get the admin password:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```

3. Open the URL in your browser and login with username `admin`

## Troubleshooting

### Application Not Syncing

**Symptoms:**
- Application shows `OutOfSync` status
- Sync errors in ArgoCD UI

**Diagnosis:**

```bash
# Check application status
argocd app get devops-agent-demo-dev

# Check sync status details
kubectl describe application devops-agent-demo-dev -n argocd

# Check argocd-application-controller logs
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=100
```

**Common Causes:**

| Issue | Solution |
|-------|----------|
| Repository access denied | Check GitHub SSH key secret |
| Invalid manifests | Run `kubectl kustomize overlays/dev-no-domain` locally |
| Resource conflicts | Check for resources managed by multiple sources |
| Webhook not triggering | Verify webhook configuration or wait for polling |

### Repository Connection Failed

**Symptoms:**
- `rpc error: code = Unknown desc = error creating SSH agent`
- `Permission denied (publickey)`

**Solutions:**

```bash
# Verify SSH key secret exists
kubectl get secret github-repo-creds -n argocd

# Check ExternalSecret status
kubectl describe externalsecret github-ssh-key -n argocd

# Test repository connection
argocd repo list
argocd repo get git@github.com:your-org/devops-agent-k8s-demo.git
```

### ExternalSecrets Not Syncing

**Symptoms:**
- SecretStore shows `Valid: False`
- ExternalSecret shows `SecretSyncedError`

**Diagnosis:**

```bash
# Check SecretStore status
kubectl describe secretstore argocd-aws-secrets-manager -n argocd

# Check ServiceAccount IRSA annotation
kubectl get sa external-secrets-sa -n argocd -o yaml | grep role-arn

# Test AWS credentials
kubectl run aws-test --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n argocd \
  -- secretsmanager get-secret-value --secret-id argocd/github-ssh-key --region us-east-1
```

### ArgoCD UI Not Accessible

**Symptoms:**
- Cannot reach ArgoCD URL
- ALB health checks failing

**Solutions:**

```bash
# Check ArgoCD server pods
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Check ingress status
kubectl describe ingress argocd-ingress -n argocd

# Check ALB controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# Verify CIDR whitelist includes your IP
kubectl get configmap allowed-cidrs -n devops-agent-demo -o yaml
```

### Redis Connection Issues

**Symptoms:**
- ArgoCD components failing to start
- `NOAUTH Authentication required` errors

**Solutions:**

```bash
# Check Redis secret
kubectl get secret argocd-redis -n argocd

# Check ExternalSecret status
kubectl describe externalsecret argocd-redis -n argocd

# Restart ArgoCD Redis
kubectl rollout restart deployment argocd-redis -n argocd
```

### Self-Heal Not Working

**Symptoms:**
- Manual changes to resources persist
- ArgoCD not correcting drift

**Verification:**

```bash
# Check if self-heal is enabled
argocd app get devops-agent-demo-dev -o json | jq '.spec.syncPolicy.automated.selfHeal'

# Check application controller logs
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd | grep -i heal
```

### Debugging Commands Reference

```bash
# ArgoCD status
argocd app list
argocd app get devops-agent-demo-dev
argocd app history devops-agent-demo-dev

# Kubernetes resources
kubectl get applications -n argocd
kubectl get appprojects -n argocd
kubectl describe application devops-agent-demo-dev -n argocd

# Logs
kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd --tail=50
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd --tail=50
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=50

# External Secrets
kubectl get externalsecret -n argocd
kubectl get secretstore -n argocd
kubectl describe externalsecret github-ssh-key -n argocd

# Force refresh
argocd app refresh devops-agent-demo-dev --hard
```

## Related Documentation

- [Architecture Documentation](./architecture.md)
- [Secrets Management](./secrets-management.md)
- [IAM Setup](./iam-setup.md)
- [Deployment Guide](./deployment-guide.md)
- [Troubleshooting](./troubleshooting.md)
