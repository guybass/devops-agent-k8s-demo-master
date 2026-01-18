# Architecture Documentation

This document describes the overall architecture of the DevOps Agent Demo Kubernetes deployment, including directory structure, components, and how microservices are organized.

## Table of Contents

- [High-Level Architecture](#high-level-architecture)
- [Directory Structure](#directory-structure)
- [Microservices Organization](#microservices-organization)
- [Kubernetes Resources](#kubernetes-resources)
- [Network Architecture](#network-architecture)
- [Data Flow](#data-flow)
- [GitOps with ArgoCD](#gitops-with-argocd)

## High-Level Architecture

```
                                    Internet
                                        |
                                        v
                              +------------------+
                              |   AWS ALB        |
                              |   (Ingress)      |
                              +--------+---------+
                                       |
              +------------------------+------------------------+
              |                        |                        |
              v                        v                        v
      +-------+-------+       +--------+--------+      +--------+--------+
      |    web-ui     |       | admin-dashboard |      |   api-gateway   |
      |   (Frontend)  |       |   (Frontend)    |      |    (Gateway)    |
      +---------------+       +-----------------+      +--------+--------+
                                                               |
                    +-------------------------------------------+
                    |                    |                      |
                    v                    v                      v
            +-------+-------+    +-------+-------+      +-------+-------+
            | Backend Tier  |    | Processing    |      | Infrastructure|
            | - auth        |    | - analytics   |      | - db-proxy    |
            | - user        |    | - event-proc  |      | - cache-mgr   |
            | - product     |    | - report-gen  |      | - config-svc  |
            | - order       |    | - data-agg    |      | - metrics     |
            | - payment     |    | - image-proc  |      | - queue-mon   |
            | - notification|    +---------------+      | - health-chk  |
            +---------------+                           +-------+-------+
                                                               |
                    +-------------------------------------------+
                    |                                           |
                    v                                           v
            +-------+-------+                           +-------+-------+
            |  AWS RDS      |                           | AWS ElastiCache|
            |  PostgreSQL   |                           |    Redis       |
            +---------------+                           +---------------+
```

## Directory Structure

```
devops-agent-k8s-demo/
|
+-- base/                              # Base Kubernetes manifests
|   +-- namespace/
|   |   +-- namespace.yaml             # Namespace definition
|   |
|   +-- configmaps/
|   |   +-- common-config.yaml         # Shared configuration
|   |   +-- database-config.yaml       # Database settings (non-sensitive)
|   |   +-- redis-config.yaml          # Redis/ElastiCache settings
|   |   +-- jwt-config.yaml            # JWT configuration
|   |
|   +-- secrets/
|   |   +-- secrets.yaml               # Placeholder secrets (dev only)
|   |   +-- external-secrets.yaml      # External Secrets configuration (database + Redis)
|   |   +-- serviceaccount.yaml        # External Secrets ServiceAccount
|   |   +-- iam-policy.json            # IAM policy for Secrets Manager access
|   |   +-- iam-trust-policy.json      # IAM trust policy for IRSA
|   |   +-- setup-external-secrets.sh  # Setup script for External Secrets
|   |
|   +-- rbac/
|   |   +-- service-accounts.yaml      # ServiceAccounts for all services
|   |   +-- roles.yaml                 # Roles for resource access
|   |   +-- role-bindings.yaml         # RoleBindings
|   |
|   +-- deployments/
|   |   +-- frontend/
|   |   |   +-- web-ui.yaml
|   |   |   +-- admin-dashboard.yaml
|   |   |
|   |   +-- gateway/
|   |   |   +-- api-gateway.yaml
|   |   |
|   |   +-- backend/
|   |   |   +-- auth-service.yaml
|   |   |   +-- user-service.yaml
|   |   |   +-- product-service.yaml
|   |   |   +-- order-service.yaml
|   |   |   +-- payment-service.yaml
|   |   |   +-- notification-service.yaml
|   |   |
|   |   +-- processing/
|   |   |   +-- event-processor.yaml
|   |   |   +-- analytics-service.yaml
|   |   |   +-- report-generator.yaml
|   |   |   +-- data-aggregator.yaml
|   |   |   +-- image-processor.yaml
|   |   |
|   |   +-- infrastructure/
|   |       +-- db-proxy.yaml
|   |       +-- cache-manager.yaml
|   |       +-- config-service.yaml
|   |       +-- metrics-collector.yaml
|   |       +-- queue-monitor.yaml
|   |       +-- health-checker.yaml
|   |
|   +-- services/
|   |   +-- services.yaml              # All Service definitions
|   |
|   +-- ingress/
|   |   +-- ingress.yaml               # ALB/NGINX Ingress
|   |
|   +-- hpa/
|   |   +-- hpa.yaml                   # HorizontalPodAutoscalers
|   |
|   +-- pdb/
|   |   +-- pdb.yaml                   # PodDisruptionBudgets
|   |
|   +-- networkpolicies/
|   |   +-- network-policies.yaml      # NetworkPolicies
|   |
|   +-- kustomization.yaml             # Base kustomization
|
+-- overlays/                          # Environment-specific configurations
|   +-- dev/
|   |   +-- kustomization.yaml         # Development overlay (with domain)
|   |
|   +-- dev-no-domain/
|   |   +-- kustomization.yaml         # Development overlay (path-based routing)
|   |   +-- ingress-patch.yaml         # Ingress patch for path-based routing
|   |
|   +-- dev-port-forward/
|   |   +-- kustomization.yaml         # Development overlay (no ingress, port-forward)
|   |
|   +-- staging/
|   |   +-- kustomization.yaml         # Staging overlay
|   |
|   +-- production/
|       +-- kustomization.yaml         # Production overlay
|
+-- iam/                               # IAM configuration for IRSA
|   +-- 01-oidc-provider.sh            # OIDC provider setup
|   +-- 02-create-iam-roles.sh         # IAM roles creation
|   +-- README.md                      # IAM documentation
|   +-- policies/                      # IAM policy documents
|   |   +-- secrets-manager-policy.json
|   |   +-- s3-access-policy.json
|   |   +-- ecr-pull-policy.json
|   |   +-- elasticache-policy.json
|   |   +-- combined-workload-policy.json
|   |
|   +-- trust-policies/                # Trust policy templates
|   |   +-- external-secrets-trust-policy.json
|   |   +-- infrastructure-sa-trust-policy.json
|   |   +-- processing-sa-trust-policy.json
|   |   +-- *-generated.json           # Generated trust policies with OIDC ID
|   |
|   +-- k8s-manifests/
|       +-- service-accounts-with-irsa.yaml
|
+-- docs/                              # Documentation
|   +-- README.md
|   +-- architecture.md
|   +-- argocd-setup.md
|   +-- secrets-management.md
|   +-- iam-setup.md
|   +-- deployment-guide.md
|   +-- troubleshooting.md
|
+-- infrastructure/                    # Infrastructure components
|   +-- argocd/
|       +-- namespace.yaml             # ArgoCD namespace
|       +-- kustomization.yaml         # Kustomize configuration
|       +-- values.yaml                # Helm values for argo-cd chart
|       +-- manifests.yaml             # Helm-templated ArgoCD manifests
|       +-- ingress.yaml               # ALB Ingress for ArgoCD UI
|       +-- secret-store.yaml          # SecretStore for ArgoCD namespace
|       +-- repository-secret.yaml     # ExternalSecret for GitHub SSH key
|       +-- redis-secret.yaml          # ExternalSecret for Redis password
|       +-- external-secrets-sa.yaml   # ServiceAccount with IRSA
|
+-- argocd-apps/                       # ArgoCD application definitions
    +-- kustomization.yaml             # Kustomize for ArgoCD apps
    +-- project.yaml                   # AppProject definition
    +-- app-dev-no-domain.yaml         # Application for dev-no-domain overlay
```

## Microservices Organization

### Frontend Tier (2 services)

NGINX-based web applications that serve the UI and proxy API requests.

| Service | Port | Description | ServiceAccount |
|---------|------|-------------|----------------|
| web-ui | 3000 | Main web application | frontend-sa |
| admin-dashboard | 3001 | Administrative interface | frontend-sa |

**Characteristics:**
- Stateless NGINX containers
- No direct AWS access required
- Served via ALB Ingress
- Configurable upstream via `API_GATEWAY_HOST` environment variable
- Template-based NGINX config (`/templates/default.conf.template`)
- EmptyDir volume at `/etc/nginx/conf.d` for writable config

**NGINX Configuration:**
```
# Template processed by envsubst on startup
upstream api {
    server ${API_GATEWAY_HOST}:8080;
}
```

### Gateway Tier (1 service)

Central entry point for all API traffic.

| Service | Port | Description | ServiceAccount |
|---------|------|-------------|----------------|
| api-gateway | 8080 | API routing and aggregation | api-gateway-sa |

**Characteristics:**
- Routes requests to backend services
- Handles authentication verification
- Rate limiting and request validation
- High availability with pod anti-affinity

### Backend Tier (6 services)

Core business logic services.

| Service | Port | Description | ServiceAccount |
|---------|------|-------------|----------------|
| auth-service | 8002 | Authentication and JWT management | backend-sa |
| user-service | 8001 | User profile management | backend-sa |
| product-service | 8004 | Product catalog management | backend-sa |
| order-service | 8003 | Order processing | backend-sa |
| payment-service | 8005 | Payment processing | backend-sa |
| notification-service | 8006 | Notification delivery | backend-sa |

**Characteristics:**
- Access database via db-proxy
- Access cache via cache-manager
- No direct AWS access (uses infrastructure tier)
- Communicate via internal Kubernetes DNS

### Processing Tier (5 services)

Data processing and analytics services.

| Service | Port | Description | ServiceAccount |
|---------|------|-------------|----------------|
| event-processor | 8010 | Event stream processing | processing-sa |
| analytics-service | 8011 | Analytics and metrics | processing-sa |
| report-generator | 8012 | Report generation | processing-sa |
| data-aggregator | 8013 | Data aggregation | processing-sa |
| image-processor | 8020 | Image processing | processing-sa |

**Characteristics:**
- S3 access for image-processor (via IRSA)
- Background processing workloads
- May have longer processing times

### Infrastructure Tier (7 services)

Platform services that provide shared capabilities.

| Service | Port | Description | ServiceAccount |
|---------|------|-------------|----------------|
| db-proxy | 5433 | PostgreSQL connection proxy | infrastructure-sa |
| cache-manager | 6380 | Redis cache proxy | infrastructure-sa |
| config-service | 9093 | Configuration management | infrastructure-sa |
| metrics-collector | 9090 | Metrics aggregation | infrastructure-sa |
| queue-monitor | 9091 | Message queue monitoring | infrastructure-sa |
| health-checker | 9092 | Service health monitoring | infrastructure-sa |
| scheduler | 9094 | Task scheduling service | infrastructure-sa |

**Characteristics:**
- Secrets Manager access for credentials (via IRSA)
- ElastiCache access (if IAM auth enabled)
- Critical for all other services
- Higher availability requirements

## Kubernetes Resources

### ConfigMaps

| ConfigMap | Purpose |
|-----------|---------|
| common-config | Environment, logging, service URLs |
| database-config | Database connection settings (non-sensitive) |
| redis-config | Redis/ElastiCache settings |
| jwt-config | JWT algorithm and expiry settings |

### Secrets

| Secret | Source | Purpose |
|--------|--------|---------|
| database-credentials | External Secrets (demo/pre-prod/database) | RDS PostgreSQL credentials |
| redis-credentials | External Secrets (demo/pre-prod/redis) | ElastiCache Redis connection |
| jwt-secret | External Secrets | JWT signing key |
| rabbitmq-credentials | External Secrets | RabbitMQ connection |

### ExternalSecrets

| ExternalSecret | AWS Secret Path | Target Secret | Keys |
|----------------|-----------------|---------------|------|
| database-credentials-external | demo/pre-prod/database | database-credentials | DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DATABASE_URL |
| redis-credentials-external | demo/pre-prod/redis | redis-credentials | REDIS_HOST, REDIS_PORT, REDIS_URL |

### ServiceAccounts

| ServiceAccount | Services | IRSA Role |
|----------------|----------|-----------|
| frontend-sa | web-ui, admin-dashboard | None |
| api-gateway-sa | api-gateway | None |
| backend-sa | auth, user, product, order, payment, notification | None |
| processing-sa | event-processor, analytics, report-generator, data-aggregator, image-processor | devops-agent-demo-processing-role |
| infrastructure-sa | db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker | devops-agent-demo-infrastructure-role |
| external-secrets-sa | External Secrets Operator | devops-agent-demo-external-secrets-role |

### HorizontalPodAutoscalers

| Service | Min | Max | CPU Target | Memory Target |
|---------|-----|-----|------------|---------------|
| api-gateway | 3 | 10 | 70% | 80% |
| web-ui | 2 | 8 | 75% | - |
| auth-service | 2 | 6 | 70% | 80% |
| order-service | 2 | 8 | 65% | 75% |
| payment-service | 2 | 6 | 60% | 70% |
| product-service | 2 | 6 | 70% | - |
| event-processor | 2 | 8 | 70% | 75% |
| db-proxy | 2 | 4 | 70% | 80% |

### PodDisruptionBudgets

All critical services have PDBs ensuring at least 1 pod remains available during voluntary disruptions (node drains, cluster upgrades).

## Network Architecture

### NetworkPolicies

The deployment implements a zero-trust network model:

```
+-------------------+     +-------------------+     +-------------------+
|    Internet       |     |   kube-system     |     |   monitoring      |
+--------+----------+     +--------+----------+     +--------+----------+
         |                         |                         |
         | (Ingress allowed)       | (DNS allowed)           | (Scraping allowed)
         v                         v                         v
+--------+-------------------------------------------------------------+
|                          devops-agent-demo namespace                  |
|                                                                       |
|   +-------------+                                                     |
|   |  Frontend   |<---- Ingress traffic allowed                        |
|   +------+------+                                                     |
|          |                                                            |
|          | (Not allowed - must go through API Gateway)                |
|          v                                                            |
|   +------+------+                                                     |
|   | API Gateway |<---- Ingress traffic allowed                        |
|   +------+------+                                                     |
|          |                                                            |
|          | (Allowed to backend)                                       |
|          v                                                            |
|   +------+------+     +-------------+                                 |
|   |   Backend   |<--->|  Processing |  (Inter-tier communication)     |
|   +------+------+     +------+------+                                 |
|          |                   |                                        |
|          | (Allowed)         | (Allowed)                              |
|          v                   v                                        |
|   +------+-------------------+------+                                 |
|   |        Infrastructure          |                                  |
|   +--------------------------------+                                  |
|                    |                                                  |
+--------------------+--------------------------------------------------+
                     |
                     | (Egress to AWS services)
                     v
            +--------+--------+
            |  AWS Services   |
            | RDS, ElastiCache|
            | S3, Secrets Mgr |
            +-----------------+
```

### Ingress Configuration

The application supports multiple ingress modes:

#### Host-Based Routing (dev, staging, production)

| Host | Service | Port |
|------|---------|------|
| app.devops-agent-demo.example.com | web-ui | 3000 |
| admin.devops-agent-demo.example.com | admin-dashboard | 3001 |
| api.devops-agent-demo.example.com | api-gateway | 8080 |

#### Path-Based Routing (dev-no-domain)

Uses the ALB's auto-generated DNS name with path prefixes:

| Path | Service | Port |
|------|---------|------|
| / | web-ui | 3000 |
| /admin | admin-dashboard | 3001 |
| /api | api-gateway | 8080 |

#### Port Forward Mode (dev-port-forward)

No ingress created. Access services directly via kubectl port-forward:

| Local Port | Service | Port |
|------------|---------|------|
| localhost:3000 | web-ui | 3000 |
| localhost:3001 | admin-dashboard | 3001 |
| localhost:8080 | api-gateway | 8080 |

## Data Flow

### User Request Flow

```
1. User -> ALB -> web-ui (Frontend)
2. web-ui -> ALB -> api-gateway
3. api-gateway -> auth-service (JWT validation)
4. api-gateway -> backend-service (business logic)
5. backend-service -> db-proxy -> RDS PostgreSQL
6. backend-service -> cache-manager -> ElastiCache Redis
7. Response flows back through the chain
```

### Secrets Flow

```
+-----------------------------------------------------------------------------------+
|                                    AWS Cloud                                       |
|                                                                                   |
|   +------------------------+         +------------------------+                   |
|   | AWS Secrets Manager    |         | AWS Secrets Manager    |                   |
|   | demo/pre-prod/database |         | demo/pre-prod/redis    |                   |
|   |  - username            |         |  - host                |                   |
|   |  - password            |         |  - port                |                   |
|   |  - host, port, dbname  |         |  - connection_string   |                   |
|   |  - DATABASE_URL        |         +------------+-----------+                   |
|   +------------+-----------+                      |                               |
|                |                                  |                               |
|                +----------------------------------+                               |
|                                |                                                  |
|                                | (1) GetSecretValue via IRSA                      |
|                                v                                                  |
+-----------------------------------------------------------------------------------+
                                 |
                                 v
+-----------------------------------------------------------------------------------+
|                              EKS Cluster                                          |
|                                                                                   |
|   +-----------------------------------------------------------------------+       |
|   |                    devops-agent-demo namespace                        |       |
|   |                                                                       |       |
|   |   +-------------------+                                               |       |
|   |   | ServiceAccount    |                                               |       |
|   |   | external-secrets- |  (IRSA: devops-agent-demo-external-secrets-   |       |
|   |   | sa                |         role)                                 |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |            v                                                          |       |
|   |   +--------+----------+                                               |       |
|   |   | SecretStore       |                                               |       |
|   |   | aws-secrets-      |                                               |       |
|   |   | manager           |                                               |       |
|   |   +--------+----------+                                               |       |
|   |            |                                                          |       |
|   |     +------+------+                                                   |       |
|   |     |             |                                                   |       |
|   |     v             v                                                   |       |
|   |  +--+----------+  +--+----------+                                     |       |
|   |  |ExternalSecret|  |ExternalSecret|                                   |       |
|   |  |database-    |  |redis-       |                                     |       |
|   |  |credentials- |  |credentials- |                                     |       |
|   |  |external     |  |external     |                                     |       |
|   |  +------+------+  +------+------+                                     |       |
|   |         |                |                                            |       |
|   |         v                v                                            |       |
|   |  +------+------+  +------+------+                                     |       |
|   |  | K8s Secret  |  | K8s Secret  |                                     |       |
|   |  | database-   |  | redis-      |                                     |       |
|   |  | credentials |  | credentials |                                     |       |
|   |  +------+------+  +------+------+                                     |       |
|   |         |                |                                            |       |
|   |         +-------+--------+                                            |       |
|   |                 |                                                     |       |
|   |                 v (Mounted as env vars)                               |       |
|   |         +-------+--------+                                            |       |
|   |         | Application    |                                            |       |
|   |         | Pods           |                                            |       |
|   |         +----------------+                                            |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
+-----------------------------------------------------------------------------------+
```

**Secrets Flow Summary:**

1. AWS Secrets Manager stores credentials for both database and Redis
2. External Secrets Operator (with IRSA) authenticates to AWS
3. ExternalSecrets sync AWS secrets to Kubernetes Secrets
4. Pods mount secrets as environment variables
5. Secrets auto-refresh every 1 hour

### Image Processing Flow

```
1. API Gateway receives image upload request
2. Request forwarded to image-processor
3. image-processor uses IRSA to access S3
4. Processed image stored in S3 bucket
5. Metadata stored in database via db-proxy
```

## Environment Overlays

### Development (overlays/dev)
- Single replica per service
- Debug logging enabled
- Image tags: `1.0.0`
- Host-based ingress routing (requires domain)
- **HPAs removed** to prevent scaling conflicts with single replica

### Development - No Domain (overlays/dev-no-domain) - CURRENTLY DEPLOYED
- Single replica per service (scaled down for dev environment)
- Debug logging enabled
- Image tags: `1.0.0`
- Path-based ingress routing (uses ALB DNS)
- No domain configuration required
- **HPAs removed** to prevent scaling conflicts with single replica
- ALB with CIDR restriction for security
- HTTP only (no SSL redirect)

**Current Configuration:**
```yaml
# Ingress annotations for dev-no-domain
alb.ingress.kubernetes.io/scheme: internet-facing
alb.ingress.kubernetes.io/target-type: ip
alb.ingress.kubernetes.io/inbound-cidrs: "79.181.131.147/32"
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
```

### Development - Port Forward (overlays/dev-port-forward)
- Single replica per service
- Debug logging enabled
- Image tags: `1.0.0`
- No ingress created
- Access via kubectl port-forward
- **HPAs removed** to prevent scaling conflicts

### Staging (overlays/staging)
- Production-like configuration
- Staging image tags
- Integration testing environment
- HPAs enabled

### Production (overlays/production)
- Increased replicas for critical services
- WARN logging level
- Semantic version image tags
- Full HA configuration
- HPAs enabled

## GitOps with ArgoCD

The project implements GitOps using ArgoCD for automated, declarative continuous delivery.

### ArgoCD Architecture

```
+-----------------------------------------------------------------------------------+
|                              Git Repository                                        |
|                                                                                   |
|   +-----------------------------------------------------------------------+       |
|   | devops-agent-k8s-demo                                                 |       |
|   |                                                                       |       |
|   |   +-- overlays/dev-no-domain/    (Application Source)                 |       |
|   |   +-- infrastructure/argocd/     (ArgoCD Configuration)               |       |
|   |   +-- argocd-apps/               (Application Definitions)            |       |
|   +-----------------------------------------------------------------------+       |
|                                |                                                  |
|                                | Git Clone (SSH)                                  |
|                                v                                                  |
+-----------------------------------------------------------------------------------+
                                 |
                                 v
+-----------------------------------------------------------------------------------+
|                              EKS Cluster                                          |
|                                                                                   |
|   +-----------------------------------------------------------------------+       |
|   |                         argocd namespace                              |       |
|   |                                                                       |       |
|   |   +-------------------+    +-------------------+                      |       |
|   |   | argocd-server     |    | argocd-repo-server|                      |       |
|   |   | (API + UI)        |    | (Git Operations)  |                      |       |
|   |   +--------+----------+    +--------+----------+                      |       |
|   |            |                        |                                 |       |
|   |            v                        v                                 |       |
|   |   +--------+------------------------+----------+                      |       |
|   |   | argocd-application-controller              |                      |       |
|   |   | (Sync Engine)                              |                      |       |
|   |   +--------+-----------------------------------+                      |       |
|   |            |                                                          |       |
|   |            | Manages                                                  |       |
|   |            v                                                          |       |
|   +-----------------------------------------------------------------------+       |
|                |                                                                  |
|                v                                                                  |
|   +-----------------------------------------------------------------------+       |
|   |                    devops-agent-demo namespace                        |       |
|   |                                                                       |       |
|   |   Synced from: overlays/dev-no-domain                                 |       |
|   |   Sync Policy: Auto-sync, Self-heal, Auto-prune                       |       |
|   |                                                                       |       |
|   |   +-- Deployments (20 services)                                       |       |
|   |   +-- Services                                                        |       |
|   |   +-- ConfigMaps                                                      |       |
|   |   +-- Secrets (via External Secrets)                                  |       |
|   |   +-- Ingress                                                         |       |
|   |   +-- NetworkPolicies                                                 |       |
|   |                                                                       |       |
|   +-----------------------------------------------------------------------+       |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### ArgoCD Components

| Component | Description | Namespace |
|-----------|-------------|-----------|
| argocd-server | API server and Web UI | argocd |
| argocd-repo-server | Clones and processes Git repositories | argocd |
| argocd-application-controller | Syncs applications to desired state | argocd |
| argocd-redis | Caching layer for ArgoCD | argocd |
| argocd-dex-server | SSO/OIDC provider (optional) | argocd |

### ArgoCD Application Structure

```
argocd-apps/
+-- kustomization.yaml          # Kustomize configuration
+-- project.yaml                # AppProject: devops-agent-demo
+-- app-dev-no-domain.yaml      # Application: devops-agent-demo-dev
```

### Sync Policy Configuration

The `devops-agent-demo-dev` application is configured with:

| Setting | Value | Description |
|---------|-------|-------------|
| automated.prune | true | Remove resources not in Git |
| automated.selfHeal | true | Correct drift from desired state |
| automated.allowEmpty | false | Prevent sync if source is empty |
| CreateNamespace | true | Create namespace if not exists |
| PrunePropagationPolicy | foreground | Wait for dependents before pruning |
| PruneLast | true | Prune after other syncs complete |
| retry.limit | 5 | Retry failed syncs up to 5 times |

### ArgoCD Secrets Management

ArgoCD secrets are managed via External Secrets Operator:

| ExternalSecret | AWS Secret Path | Target K8s Secret | Purpose |
|----------------|-----------------|-------------------|---------|
| github-ssh-key | argocd/github-ssh-key | github-repo-creds | Git repository access |
| argocd-redis | argocd/redis | argocd-redis | Redis authentication |

### ArgoCD Access

| Setting | Value |
|---------|-------|
| URL | `http://<ALB_DNS>/` |
| Protocol | HTTP (no TLS) |
| IP Whitelist | Via shared `allowed-cidrs.yaml` ConfigMap |
| Default User | admin |

### Shared CIDR Configuration

IP whitelisting is managed centrally using Kustomize replacements:

```yaml
# overlays/dev-no-domain/allowed-cidrs.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: allowed-cidrs
  namespace: devops-agent-demo
data:
  cidrs: "79.181.131.147/32"
```

This ConfigMap value is injected into both:
- Application Ingress (`devops-agent-demo-ingress`)
- ArgoCD Ingress (`argocd-ingress`)

For detailed ArgoCD configuration, see [ArgoCD Setup](./argocd-setup.md).
