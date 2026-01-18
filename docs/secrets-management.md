# Secrets Management Documentation

This document provides detailed documentation about the secrets management flow in the DevOps Agent Demo project, including AWS Secrets Manager integration, External Secrets Operator setup, and IRSA configuration.

## Table of Contents

- [Overview](#overview)
- [Architecture Diagram](#architecture-diagram)
- [AWS Secrets Manager](#aws-secrets-manager)
- [External Secrets Operator](#external-secrets-operator)
- [IRSA Configuration](#irsa-configuration)
- [SecretStore and ExternalSecret Resources](#secretstore-and-externalsecret-resources)
- [ArgoCD Secrets](#argocd-secrets)
- [Secrets Flow](#secrets-flow)
- [Security Best Practices](#security-best-practices)

## Overview

The DevOps Agent Demo uses a secure secrets management approach that:

1. **Stores secrets in AWS Secrets Manager** - Centralized, encrypted secret storage
2. **Uses External Secrets Operator** - Syncs AWS secrets to Kubernetes
3. **Leverages IRSA** - Secure, pod-level AWS authentication without static credentials
4. **Auto-refreshes secrets** - Secrets are automatically updated every hour

### Current Status

**API Version**: `external-secrets.io/v1` (latest stable API)

All ExternalSecrets are configured and syncing successfully.

### Managed Secrets

The following secrets are synced from AWS Secrets Manager via External Secrets Operator:

### Application Secrets (devops-agent-demo namespace)

| ExternalSecret | AWS Secret Path | Target K8s Secret | Purpose | Status |
|----------------|-----------------|-------------------|---------|--------|
| database-credentials-external | demo/pre-prod/database | database-credentials | PostgreSQL RDS credentials | SecretSynced |
| redis-credentials-external | demo/pre-prod/redis | redis-credentials | ElastiCache Redis connection | SecretSynced |

### ArgoCD Secrets (argocd namespace)

| ExternalSecret | AWS Secret Path | Target K8s Secret | Purpose | Status |
|----------------|-----------------|-------------------|---------|--------|
| github-ssh-key | argocd/github-ssh-key | github-repo-creds | GitHub repository SSH key | SecretSynced |
| argocd-redis | argocd/redis | argocd-redis | ArgoCD Redis password | SecretSynced |

## Architecture Diagram

```
+-----------------------------------------------------------------------------------+
|                                    AWS Cloud                                       |
|                                                                                   |
|   +------------------------+         +------------------------+                   |
|   | AWS Secrets Manager    |         | AWS Secrets Manager    |                   |
|   |                        |         |                        |                   |
|   | Secret:                |         | Secret:                |                   |
|   | demo/pre-prod/database |         | demo/pre-prod/redis    |                   |
|   |  - username            |         |  - host                |                   |
|   |  - password            |         |  - port                |                   |
|   |  - host                |         |  - connection_string   |                   |
|   |  - port                |         +------------+-----------+                   |
|   |  - dbname              |                      |                               |
|   |  - DATABASE_URL        |                      |                               |
|   +------------+-----------+                      |                               |
|                |                                  |                               |
|                +----------------------------------+                               |
|                                |                                                  |
|                                | (1) GetSecretValue                               |
|                                |     (IRSA Authentication)                        |
|                                v                                                  |
|   +----------------------------+------------------+                               |
|   | IAM Role                                      |                               |
|   | devops-agent-demo-external-secrets-role       |                               |
|   | Policy: Access demo/pre-prod/database*        |                               |
|   |         Access demo/pre-prod/redis*           |                               |
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
|   |                    devops-agent-demo namespace                        |       |
|   |                                                                       |       |
|   |   +-------------------+                                               |       |
|   |   | ServiceAccount    |                                               |       |
|   |   | external-secrets- |                                               |       |
|   |   | sa                |                                               |       |
|   |   |                   |                                               |       |
|   |   | Annotation:       |                                               |       |
|   |   | eks.amazonaws.com/|                                               |       |
|   |   | role-arn: ...     |                                               |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |            | (3) References SA                                        |       |
|   |            v                                                          |       |
|   |   +--------+----------+                                               |       |
|   |   | SecretStore       |                                               |       |
|   |   | aws-secrets-      |                                               |       |
|   |   | manager           |                                               |       |
|   |   |                   |                                               |       |
|   |   | Provider: AWS     |                                               |       |
|   |   | Service: Secrets  |                                               |       |
|   |   | Manager           |                                               |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |     +------+------+                                                   |       |
|   |     |             |                                                   |       |
|   |     v             v                                                   |       |
|   |   +-+-------------+-+     +-+-------------+-+                         |       |
|   |   | ExternalSecret  |     | ExternalSecret  |                         |       |
|   |   | database-       |     | redis-          |                         |       |
|   |   | credentials-    |     | credentials-    |                         |       |
|   |   | external        |     | external        |                         |       |
|   |   |                 |     |                 |                         |       |
|   |   | Refresh: 1h     |     | Refresh: 1h     |                         |       |
|   |   +--------+--------+     +--------+--------+                         |       |
|   |            |                       |                                  |       |
|   |            | Creates               | Creates                          |       |
|   |            v                       v                                  |       |
|   |   +--------+--------+     +--------+--------+                         |       |
|   |   | Kubernetes      |     | Kubernetes      |                         |       |
|   |   | Secret          |     | Secret          |                         |       |
|   |   | database-       |     | redis-          |                         |       |
|   |   | credentials     |     | credentials     |                         |       |
|   |   |                 |     |                 |                         |       |
|   |   | - DB_HOST       |     | - REDIS_HOST    |                         |       |
|   |   | - DB_PORT       |     | - REDIS_PORT    |                         |       |
|   |   | - DB_NAME       |     | - REDIS_URL     |                         |       |
|   |   | - DB_USER       |     +--------+--------+                         |       |
|   |   | - DB_PASSWORD   |              |                                  |       |
|   |   | - DATABASE_URL  |              |                                  |       |
|   |   +--------+--------+              |                                  |       |
|   |            |                       |                                  |       |
|   |            +----------+------------+                                  |       |
|   |                       |                                               |       |
|   |                       | (4) Mount as env vars                         |       |
|   |                       v                                               |       |
|   |              +--------+----------+                                    |       |
|   |              | Application Pods  |                                    |       |
|   |              | - db-proxy        |                                    |       |
|   |              | - cache-manager   |                                    |       |
|   |              | - backend-*       |                                    |       |
|   |              +-------------------+                                    |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

## AWS Secrets Manager

### Database Secret Details

| Setting | Value |
|---------|-------|
| Secret Path | `demo/pre-prod/database` |
| Secret ARN | `arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/database` |
| Region | `us-east-2` |
| Encryption | AWS managed key |

#### Database Secret Structure

The database secret contains the following keys (created by Terraform RDS module):

```json
{
  "username": "dbadmin",
  "password": "<generated-password>",
  "engine": "postgres",
  "host": "demo-pre-prod-postgres.xxxxxx.us-east-2.rds.amazonaws.com",
  "port": "5432",
  "dbname": "devops_agent_demo",
  "DATABASE_URL": "postgresql://dbadmin:<password>@<host>:5432/devops_agent_demo"
}
```

### Redis Secret Details

| Setting | Value |
|---------|-------|
| Secret Path | `demo/pre-prod/redis` |
| Secret ARN | `arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/redis` |
| Region | `us-east-2` |
| Encryption | AWS managed key |

#### Redis Secret Structure

The Redis secret contains the following keys (created by Terraform ElastiCache module):

```json
{
  "host": "master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com",
  "port": "6379",
  "connection_string": "rediss://master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com:6379"
}
```

### Creating/Updating Secrets (Reference)

If you need to create or update secrets:

```bash
# Create database secret
aws secretsmanager create-secret \
  --name demo/pre-prod/database \
  --description "Database credentials for DevOps Agent Demo" \
  --secret-string '{
    "username": "dbadmin",
    "password": "your-secure-password",
    "engine": "postgres",
    "host": "your-rds-endpoint",
    "port": "5432",
    "dbname": "devops_agent_demo",
    "DATABASE_URL": "postgresql://dbadmin:password@host:5432/devops_agent_demo"
  }' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  --region us-east-2

# Create Redis secret
aws secretsmanager create-secret \
  --name demo/pre-prod/redis \
  --description "Redis credentials for DevOps Agent Demo" \
  --secret-string '{
    "host": "master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com",
    "port": "6379",
    "connection_string": "rediss://master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com:6379"
  }' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=devops-agent-demo \
  --region us-east-2

# Update an existing secret
aws secretsmanager put-secret-value \
  --secret-id demo/pre-prod/database \
  --secret-string '{"username": "...", ...}' \
  --region us-east-2

# Retrieve a secret (for verification)
aws secretsmanager get-secret-value \
  --secret-id demo/pre-prod/database \
  --region us-east-2 \
  --query 'SecretString' \
  --output text | jq .

aws secretsmanager get-secret-value \
  --secret-id demo/pre-prod/redis \
  --region us-east-2 \
  --query 'SecretString' \
  --output text | jq .
```

## External Secrets Operator

### Installation

The External Secrets Operator must be installed cluster-wide:

```bash
# Add the Helm repository
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install the operator
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --set webhook.port=9443

# Verify installation
kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
```

### Installed CRDs

After installation, you should see these Custom Resource Definitions:

```
clustersecretstores.external-secrets.io
externalsecrets.external-secrets.io
secretstores.external-secrets.io
```

### Operator Configuration

The operator watches for `ExternalSecret` resources and syncs them to Kubernetes `Secret` resources.

## IRSA Configuration

IRSA (IAM Roles for Service Accounts) allows pods to securely authenticate with AWS services without using static credentials.

### How IRSA Works

1. **OIDC Provider**: EKS exposes an OIDC provider endpoint
2. **IAM Trust Policy**: IAM role trusts the OIDC provider for specific ServiceAccounts
3. **ServiceAccount Annotation**: ServiceAccount is annotated with the IAM role ARN
4. **Pod Token**: EKS injects a web identity token into the pod
5. **STS AssumeRole**: AWS SDK uses the token to assume the IAM role

### ServiceAccount Configuration

File: `base/secrets/serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-sa
  namespace: devops-agent-demo
  labels:
    app.kubernetes.io/name: devops-agent-demo
    app.kubernetes.io/component: secrets
    app.kubernetes.io/managed-by: external-secrets
  annotations:
    # IRSA annotation - grants access to AWS Secrets Manager
    eks.amazonaws.com/role-arn: arn:aws:iam::852140462703:role/devops-agent-demo-external-secrets-role
```

### IAM Role Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::852140462703:oidc-provider/oidc.eks.us-east-2.amazonaws.com/id/44CE8DEBE88BE7CCA95850A4BE818542"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-east-2.amazonaws.com/id/44CE8DEBE88BE7CCA95850A4BE818542:sub": "system:serviceaccount:devops-agent-demo:external-secrets-sa",
          "oidc.eks.us-east-2.amazonaws.com/id/44CE8DEBE88BE7CCA95850A4BE818542:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

### IAM Policy

The IAM policy grants access to both database and Redis secrets:

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
        "arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/database*",
        "arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/redis*"
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

## SecretStore and ExternalSecret Resources

### SecretStore

The `SecretStore` defines how to connect to AWS Secrets Manager:

File: `base/secrets/external-secrets.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: devops-agent-demo
  labels:
    app.kubernetes.io/name: devops-agent-demo
    app.kubernetes.io/component: secrets
    app.kubernetes.io/managed-by: external-secrets
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

### ExternalSecret - Database Credentials

The `ExternalSecret` defines which AWS secrets to sync and how to map them:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: database-credentials-external
  namespace: devops-agent-demo
  labels:
    app.kubernetes.io/name: devops-agent-demo
    app.kubernetes.io/component: database
    app.kubernetes.io/managed-by: external-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: database-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          app.kubernetes.io/name: devops-agent-demo
          app.kubernetes.io/component: database
  data:
    - secretKey: DB_HOST
      remoteRef:
        key: demo/pre-prod/database
        property: host
    - secretKey: DB_PORT
      remoteRef:
        key: demo/pre-prod/database
        property: port
    - secretKey: DB_NAME
      remoteRef:
        key: demo/pre-prod/database
        property: dbname
    - secretKey: DB_USER
      remoteRef:
        key: demo/pre-prod/database
        property: username
    - secretKey: DB_PASSWORD
      remoteRef:
        key: demo/pre-prod/database
        property: password
    - secretKey: DB_ENGINE
      remoteRef:
        key: demo/pre-prod/database
        property: engine
    - secretKey: DATABASE_URL
      remoteRef:
        key: demo/pre-prod/database
        property: DATABASE_URL
```

### ExternalSecret - Redis Credentials

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: redis-credentials-external
  namespace: devops-agent-demo
  labels:
    app.kubernetes.io/name: devops-agent-demo
    app.kubernetes.io/component: redis
    app.kubernetes.io/managed-by: external-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: redis-credentials
    creationPolicy: Owner
    template:
      type: Opaque
      metadata:
        labels:
          app.kubernetes.io/name: devops-agent-demo
          app.kubernetes.io/component: redis
  data:
    - secretKey: REDIS_HOST
      remoteRef:
        key: demo/pre-prod/redis
        property: host
    - secretKey: REDIS_PORT
      remoteRef:
        key: demo/pre-prod/redis
        property: port
    - secretKey: REDIS_URL
      remoteRef:
        key: demo/pre-prod/redis
        property: connection_string
```

## ArgoCD Secrets

ArgoCD uses a separate SecretStore and ExternalSecrets in the `argocd` namespace for managing its credentials.

### ArgoCD Secrets Architecture

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
|   +-----------------------------------------------+                               |
|                                                                                   |
+-----------------------------------------------------------------------------------+
                                 |
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
|   |  +-------------+  +-------------+                                     |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### GitHub SSH Key Secret

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

### ArgoCD Redis Password

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

### ArgoCD SecretStore

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
      region: us-east-2
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
```

### ArgoCD IRSA Configuration

**ServiceAccount:** `external-secrets-sa` (in argocd namespace)

**IAM Role:** `ArgoCD-ExternalSecrets-Role`

**IAM Policy:** `ArgoCD-ExternalSecrets-Policy`

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
        "arn:aws:secretsmanager:us-east-2:852140462703:secret:argocd/*"
      ]
    }
  ]
}
```

### Creating ArgoCD Secrets in AWS

```bash
# Create GitHub SSH key secret
aws secretsmanager create-secret \
  --name argocd/github-ssh-key \
  --description "GitHub SSH private key for ArgoCD repository access" \
  --secret-string '{"sshPrivateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"}' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=argocd \
  --region us-east-2

# Create Redis password secret
aws secretsmanager create-secret \
  --name argocd/redis \
  --description "Redis password for ArgoCD" \
  --secret-string '{"password":"your-redis-password"}' \
  --tags Key=Environment,Value=pre-prod Key=Project,Value=argocd \
  --region us-east-2
```

### ArgoCD Secrets Verification

```bash
# Check ArgoCD SecretStore status
kubectl get secretstore -n argocd
kubectl describe secretstore argocd-aws-secrets-manager -n argocd

# Check ArgoCD ExternalSecrets status
kubectl get externalsecret -n argocd
kubectl describe externalsecret github-ssh-key -n argocd
kubectl describe externalsecret argocd-redis -n argocd

# Verify Kubernetes secrets were created
kubectl get secret github-repo-creds -n argocd
kubectl get secret argocd-redis -n argocd

# Force refresh ArgoCD secrets
kubectl annotate externalsecret github-ssh-key -n argocd force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret argocd-redis -n argocd force-sync=$(date +%s) --overwrite
```

For detailed ArgoCD setup, see [ArgoCD Setup](./argocd-setup.md).

## Secrets Flow

### Step-by-Step Flow

1. **Secrets Created in AWS**
   ```
   AWS Secrets Manager:
     - demo/pre-prod/database: username, password, host, port, dbname, DATABASE_URL
     - demo/pre-prod/redis: host, port, connection_string
   ```

2. **External Secrets Operator Deployed**
   ```
   Namespace: external-secrets
   Watches: ExternalSecret resources in all namespaces
   ```

3. **ServiceAccount Created with IRSA**
   ```
   ServiceAccount: external-secrets-sa
   Annotation: eks.amazonaws.com/role-arn: arn:aws:iam::852140462703:role/...
   ```

4. **SecretStore Created**
   ```
   SecretStore: aws-secrets-manager
   Provider: AWS Secrets Manager
   Auth: JWT (references ServiceAccount)
   ```

5. **ExternalSecrets Created**
   ```
   ExternalSecret: database-credentials-external
     References: SecretStore aws-secrets-manager
     Source: demo/pre-prod/database
     Target: Kubernetes Secret named database-credentials
     Refresh: Every 1 hour

   ExternalSecret: redis-credentials-external
     References: SecretStore aws-secrets-manager
     Source: demo/pre-prod/redis
     Target: Kubernetes Secret named redis-credentials
     Refresh: Every 1 hour
   ```

6. **Operator Syncs Secrets**
   ```
   Operator -> IRSA -> AWS STS -> Assume Role
   Operator -> AWS Secrets Manager -> GetSecretValue (database)
   Operator -> AWS Secrets Manager -> GetSecretValue (redis)
   Operator -> Create/Update Kubernetes Secrets
   ```

7. **Pods Consume Secrets**
   ```yaml
   # Database credentials
   env:
     - name: DB_HOST
       valueFrom:
         secretKeyRef:
           name: database-credentials
           key: DB_HOST

   # Redis credentials
   env:
     - name: REDIS_URL
       valueFrom:
         secretKeyRef:
           name: redis-credentials
           key: REDIS_URL
   ```

### Verification Commands

```bash
# Check SecretStore status
kubectl get secretstore -n devops-agent-demo
kubectl describe secretstore aws-secrets-manager -n devops-agent-demo

# Check ExternalSecret status (both database and Redis)
kubectl get externalsecret -n devops-agent-demo
kubectl describe externalsecret database-credentials-external -n devops-agent-demo
kubectl describe externalsecret redis-credentials-external -n devops-agent-demo

# Verify Kubernetes Secrets were created
kubectl get secret database-credentials -n devops-agent-demo
kubectl get secret redis-credentials -n devops-agent-demo

# Verify secret contents (base64 decoded)
kubectl get secret database-credentials -n devops-agent-demo -o jsonpath='{.data.DB_HOST}' | base64 -d
kubectl get secret redis-credentials -n devops-agent-demo -o jsonpath='{.data.REDIS_HOST}' | base64 -d

# Check sync events
kubectl get events -n devops-agent-demo --field-selector involvedObject.name=database-credentials-external
kubectl get events -n devops-agent-demo --field-selector involvedObject.name=redis-credentials-external

# Force refresh secrets
kubectl annotate externalsecret database-credentials-external \
  -n devops-agent-demo \
  force-sync=$(date +%s) --overwrite

kubectl annotate externalsecret redis-credentials-external \
  -n devops-agent-demo \
  force-sync=$(date +%s) --overwrite
```

## Security Best Practices

### 1. Least Privilege IAM Policies

Only grant the minimum required permissions. The policy includes both secret paths:

```json
{
  "Action": [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret"
  ],
  "Resource": [
    "arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/database*",
    "arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/redis*"
  ]
}
```

### 2. Namespace-Scoped ServiceAccounts

Trust policies should specify exact namespace and ServiceAccount:

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.us-east-2.amazonaws.com/id/44CE8DEBE88BE7CCA95850A4BE818542:sub": "system:serviceaccount:devops-agent-demo:external-secrets-sa"
  }
}
```

### 3. Secret Rotation

AWS Secrets Manager supports automatic rotation:

```bash
# Enable rotation (requires Lambda function)
aws secretsmanager rotate-secret \
  --secret-id demo/pre-prod/database \
  --rotation-lambda-arn arn:aws:lambda:us-east-2:852140462703:function:SecretRotationFunction \
  --rotation-rules AutomaticallyAfterDays=30
```

### 4. Audit Logging

Enable CloudTrail logging for Secrets Manager:

```bash
# All Secrets Manager API calls are logged in CloudTrail
# Filter for GetSecretValue events
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --region us-east-2
```

### 5. Network Security

- Use VPC endpoints for Secrets Manager to avoid public internet
- Configure security groups to restrict access
- Enable encryption in transit

### 6. Never Store Secrets in Git

- Use External Secrets Operator or Sealed Secrets
- The `base/secrets/secrets.yaml` file contains only placeholder values
- Real secrets come from AWS Secrets Manager

### 7. Regular Secret Rotation

Configure appropriate `refreshInterval` based on your rotation schedule:

```yaml
spec:
  refreshInterval: 1h  # Sync every hour
```

For more frequent rotation, reduce the interval:

```yaml
spec:
  refreshInterval: 15m  # Sync every 15 minutes
```
