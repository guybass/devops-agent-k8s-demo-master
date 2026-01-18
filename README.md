# DevOps Agent Demo - Kubernetes Manifests

This repository contains production-ready Kubernetes manifests for deploying the DevOps Agent Demo microservices application to Amazon EKS, with GitOps-based continuous delivery powered by ArgoCD.

## Architecture Overview

The application consists of 19 microservices organized into the following categories:

### Frontend (2 services)
- **web-ui** (port 3000) - Main web application
- **admin-dashboard** (port 3001) - Admin panel

### Gateway (1 service)
- **api-gateway** (port 8080) - Central API gateway routing to all backend services

### Backend (6 services)
- **auth-service** (port 8002) - Authentication and JWT management
- **user-service** (port 8001) - User profile management
- **product-service** (port 8004) - Product catalog
- **order-service** (port 8003) - Order processing
- **payment-service** (port 8005) - Payment processing
- **notification-service** (port 8006) - Notification delivery

### Processing (5 services)
- **event-processor** (port 8010) - Event stream processing
- **analytics-service** (port 8011) - Analytics and reporting
- **report-generator** (port 8012) - Report generation
- **data-aggregator** (port 8013) - Data aggregation
- **image-processor** (port 8020) - Image processing

### Infrastructure (6 services)
- **db-proxy** (port 5433) - PostgreSQL connection proxy (connects to RDS)
- **cache-manager** (port 6380) - Redis cache proxy (connects to ElastiCache)
- **config-service** (port 9093) - Configuration management
- **metrics-collector** (port 9090) - Metrics collection
- **queue-monitor** (port 9091) - Message queue monitoring
- **health-checker** (port 9092) - Service health monitoring

### GitOps Infrastructure
- **ArgoCD** - GitOps continuous delivery platform for automated deployments

## GitOps Workflow

This repository implements a GitOps workflow using ArgoCD:

1. **Git as Source of Truth**: All Kubernetes configurations are stored in this repository
2. **Automatic Sync**: ArgoCD monitors the repository and automatically deploys changes
3. **Self-Healing**: ArgoCD corrects any drift from the desired state defined in Git
4. **Auto-Prune**: Resources removed from Git are automatically deleted from the cluster
5. **Full Audit Trail**: All changes go through Git, providing complete change history

```
Developer --> Git Push --> ArgoCD Detects --> Auto Sync --> Kubernetes Cluster
                              ^                                    |
                              |                                    v
                              +-------- Self-Heal on Drift <-------+
```

## Directory Structure

```
.
├── base/                           # Base Kubernetes manifests
│   ├── namespace/                  # Namespace definition
│   ├── configmaps/                 # ConfigMaps for configuration
│   ├── secrets/                    # Secrets (placeholders + External Secrets)
│   ├── rbac/                       # ServiceAccounts, Roles, RoleBindings
│   ├── deployments/                # Deployment manifests
│   │   ├── frontend/               # Frontend deployments
│   │   ├── gateway/                # API Gateway deployment
│   │   ├── backend/                # Backend service deployments
│   │   ├── processing/             # Processing service deployments
│   │   └── infrastructure/         # Infrastructure service deployments
│   ├── services/                   # Kubernetes Services
│   ├── ingress/                    # Ingress configuration (ALB/NGINX)
│   ├── hpa/                        # HorizontalPodAutoscalers
│   ├── pdb/                        # PodDisruptionBudgets
│   ├── networkpolicies/            # NetworkPolicies
│   └── kustomization.yaml          # Base kustomization
├── overlays/                       # Environment-specific overlays
│   ├── dev/                        # Development environment
│   ├── dev-no-domain/              # Development without custom domain
│   │   └── allowed-cidrs.yaml      # Shared CIDR configuration for IP whitelisting
│   ├── staging/                    # Staging environment
│   └── production/                 # Production environment
├── infrastructure/                 # Cluster infrastructure components
│   └── argocd/                     # ArgoCD GitOps platform
│       ├── namespace.yaml          # ArgoCD namespace
│       ├── kustomization.yaml      # Kustomize configuration
│       ├── values.yaml             # Helm values for ArgoCD
│       ├── manifests.yaml          # Helm-templated ArgoCD manifests
│       ├── ingress.yaml            # ALB Ingress for ArgoCD UI
│       ├── secret-store.yaml       # SecretStore for AWS Secrets Manager
│       ├── repository-secret.yaml  # ExternalSecret for GitHub SSH key
│       ├── redis-secret.yaml       # ExternalSecret for Redis password
│       └── external-secrets-sa.yaml # ServiceAccount with IRSA
├── argocd-apps/                    # ArgoCD Application definitions
│   ├── kustomization.yaml          # Kustomize for ArgoCD apps
│   ├── project.yaml                # AppProject definition
│   └── app-dev-no-domain.yaml      # Application for dev environment
├── docs/                           # Documentation
│   ├── argocd-setup.md             # ArgoCD setup and configuration guide
│   └── troubleshooting.md          # Troubleshooting guide
└── README.md
```

## Prerequisites

1. **EKS Cluster**: A running EKS cluster (Kubernetes 1.30+)
2. **kubectl**: Configured to access your cluster
3. **kustomize**: Version 4.0+ (or use `kubectl -k`)
4. **AWS CLI**: Configured with appropriate permissions
5. **AWS Load Balancer Controller**: For ALB Ingress
6. **Metrics Server**: For HorizontalPodAutoscaler
7. **External Secrets Operator**: For secrets management (required for ArgoCD)
8. **ArgoCD CLI** (optional): For command-line management of ArgoCD

## Quick Start

### Option A: Deploy with ArgoCD (Recommended)

ArgoCD provides GitOps-based continuous delivery with automatic sync and self-healing.

#### 1. Deploy ArgoCD Infrastructure

```bash
# Deploy ArgoCD and its dependencies
kubectl apply -k infrastructure/argocd

# Wait for ArgoCD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

#### 2. Deploy ArgoCD Applications

```bash
# Deploy the ArgoCD application definitions
kubectl apply -k argocd-apps

# Verify applications are syncing
kubectl get applications -n argocd
```

#### 3. Access ArgoCD UI

```bash
# Get the ArgoCD URL
kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Get the admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```

Access the URL in your browser and login with username `admin` and the password retrieved above.

For detailed ArgoCD setup instructions, see [docs/argocd-setup.md](docs/argocd-setup.md).

### Option B: Deploy with kubectl (Manual)

#### 1. Update ECR Image References

Replace `AWS_ACCOUNT_ID` and `AWS_REGION` in all deployment files with your actual values:

```bash
# Using sed (Linux/macOS)
find base/deployments -name "*.yaml" -exec sed -i 's/AWS_ACCOUNT_ID/123456789012/g' {} \;
find base/deployments -name "*.yaml" -exec sed -i 's/AWS_REGION/us-east-2/g' {} \;

# Or use kustomize to set images
cd base
kustomize edit set image \
  AWS_ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com/devops-agent-demo-api-gateway=123456789012.dkr.ecr.us-east-2.amazonaws.com/devops-agent-demo-api-gateway:latest
```

#### 2. Configure Secrets

**Using placeholder secrets (not recommended for production):**
```bash
# Update base/secrets/secrets.yaml with base64-encoded values
echo -n "your-db-host" | base64
# Update the DB_HOST value in secrets.yaml
```

**Using External Secrets Operator (recommended):**
```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace

# Enable external secrets in kustomization.yaml
# Uncomment: - secrets/external-secrets.yaml
```

#### 3. Update Ingress Configuration

Edit `base/ingress/ingress.yaml`:
- Update hostnames to your domain
- Configure SSL certificate ARN
- Update security groups

#### 4. Deploy

```bash
# Preview what will be deployed
kubectl kustomize overlays/dev

# Deploy to development
kubectl apply -k overlays/dev

# Deploy to staging
kubectl apply -k overlays/staging

# Deploy to production
kubectl apply -k overlays/production
```

#### 5. Verify Deployment

```bash
# Check all resources
kubectl get all -n devops-agent-demo

# Check pod status
kubectl get pods -n devops-agent-demo

# Check services
kubectl get svc -n devops-agent-demo

# Check ingress
kubectl get ingress -n devops-agent-demo

# Check HPA status
kubectl get hpa -n devops-agent-demo
```

## Configuration Details

### ConfigMaps

| ConfigMap | Description |
|-----------|-------------|
| `common-config` | Shared configuration (environment, log level, service URLs) |
| `database-config` | PostgreSQL connection settings (non-sensitive) |
| `redis-config` | Redis/ElastiCache settings |
| `jwt-config` | JWT configuration (algorithm, expiry) |
| `allowed-cidrs` | Shared CIDR configuration for IP whitelisting (used by multiple ingresses) |

### Secrets

| Secret | Description |
|--------|-------------|
| `database-credentials` | RDS PostgreSQL credentials |
| `redis-credentials` | ElastiCache Redis URL |
| `jwt-secret` | JWT signing key |
| `rabbitmq-credentials` | RabbitMQ connection URL |

### ArgoCD Secrets (External Secrets)

ArgoCD uses External Secrets Operator to sync secrets from AWS Secrets Manager:

| ExternalSecret | AWS Secret Path | K8s Secret Created | Description |
|----------------|-----------------|-------------------|-------------|
| `github-ssh-key` | `argocd/github-ssh-key` | `github-repo-creds` | SSH private key for Git repository access |
| `argocd-redis` | `argocd/redis` | `argocd-redis` | Redis password for ArgoCD caching |

These secrets are managed via IRSA (IAM Roles for Service Accounts) using the `ArgoCD-ExternalSecrets-Role`.

### ServiceAccounts

| ServiceAccount | Used By |
|----------------|---------|
| `frontend-sa` | web-ui, admin-dashboard |
| `api-gateway-sa` | api-gateway |
| `backend-sa` | auth, user, product, order, payment, notification services |
| `processing-sa` | event-processor, analytics, report-generator, data-aggregator, image-processor |
| `infrastructure-sa` | db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker |

## Security Features

### Pod Security
- All pods run as non-root users (`runAsNonRoot: true`)
- Read-only root filesystem (`readOnlyRootFilesystem: true`)
- Capabilities dropped (`capabilities.drop: ALL`)
- No privilege escalation (`allowPrivilegeEscalation: false`)

### Network Security
- Default deny ingress policy
- Service-to-service communication controlled via NetworkPolicies
- Component-based access control (frontend, gateway, backend, processing, infrastructure)

### RBAC
- Least-privilege ServiceAccounts
- Role-based access to ConfigMaps and Secrets
- Specific permissions for monitoring services

## Scaling Configuration

### HorizontalPodAutoscaler

| Service | Min Replicas | Max Replicas | CPU Target | Memory Target |
|---------|--------------|--------------|------------|---------------|
| api-gateway | 3 | 10 | 70% | 80% |
| web-ui | 2 | 8 | 75% | - |
| auth-service | 2 | 6 | 70% | 80% |
| order-service | 2 | 8 | 65% | 75% |
| payment-service | 2 | 6 | 60% | 70% |
| product-service | 2 | 6 | 70% | - |
| event-processor | 2 | 8 | 70% | 75% |
| db-proxy | 2 | 4 | 70% | 80% |

### PodDisruptionBudgets

All critical services have PDBs ensuring at least 1 pod remains available during voluntary disruptions.

## Resource Requirements

### Minimum Cluster Resources (Development)
- 2 nodes, t3.medium (2 vCPU, 4 GB RAM each)
- ~2 GB RAM total
- ~2 vCPU total

### Recommended Cluster Resources (Production)
- 4+ nodes, t3.large or larger
- Multi-AZ deployment
- ~8 GB RAM minimum
- ~8 vCPU minimum

## Monitoring

### Prometheus Integration
All deployments include annotations for Prometheus scraping:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<service-port>"
```

### Health Endpoints
All services expose `/health` endpoints for readiness and liveness probes.

## Troubleshooting

For comprehensive troubleshooting guidance, see:
- [docs/troubleshooting.md](docs/troubleshooting.md) - General Kubernetes troubleshooting
- [docs/argocd-setup.md#troubleshooting](docs/argocd-setup.md#troubleshooting) - ArgoCD-specific troubleshooting

### Known Fixed Issues

The following issues have been identified and resolved:

1. **Service URLs Missing Prefix** - When using `namePrefix` in overlays, ConfigMap service URLs must include the prefix (e.g., `dev-auth-service` not `auth-service`)
2. **API Gateway Route Prefix** - When using path-based routing, API Gateway routers must include `/api` prefix
3. **Product Data Transformation** - API Gateway must transform `price_cents` to `price` and `inventory.available` to `stock`

See [docs/troubleshooting.md](docs/troubleshooting.md) for full details on all resolved issues.

### Common Issues

**Pods stuck in Pending:**
```bash
kubectl describe pod <pod-name> -n devops-agent-demo
# Check for: insufficient resources, node taints, PVC issues
```

**ImagePullBackOff:**
```bash
# Verify ECR authentication
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-2.amazonaws.com

# Check if image exists
aws ecr describe-images --repository-name devops-agent-demo-api-gateway
```

**CrashLoopBackOff:**
```bash
kubectl logs <pod-name> -n devops-agent-demo
kubectl logs <pod-name> -n devops-agent-demo --previous
```

**Service not accessible:**
```bash
# Check endpoints
kubectl get endpoints <service-name> -n devops-agent-demo

# Test DNS
kubectl run debug --rm -it --image=busybox -- nslookup api-gateway.devops-agent-demo.svc.cluster.local
```

## Rollback

```bash
# Check rollout history
kubectl rollout history deployment/<deployment-name> -n devops-agent-demo

# Rollback to previous version
kubectl rollout undo deployment/<deployment-name> -n devops-agent-demo

# Rollback to specific revision
kubectl rollout undo deployment/<deployment-name> -n devops-agent-demo --to-revision=2
```

## CI/CD Integration

### With ArgoCD (GitOps)

When using ArgoCD, CI/CD is simplified to pushing changes to Git:

```yaml
name: Update Manifests

on:
  push:
    branches: [main]
    paths:
      - 'base/**'
      - 'overlays/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate manifests
        run: |
          kubectl kustomize overlays/dev-no-domain > /dev/null
          kubectl kustomize overlays/staging > /dev/null
          kubectl kustomize overlays/production > /dev/null

      # ArgoCD automatically syncs when changes are pushed to main
      # No explicit deploy step needed - ArgoCD handles it
```

### Without ArgoCD (Manual)

Example GitHub Actions workflow for manual deployment:

```yaml
name: Deploy to EKS

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-2

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name demo-pre-prod-cluster

      - name: Deploy
        run: kubectl apply -k overlays/staging
```

## ArgoCD Reference

### Access Information

| Item | Value |
|------|-------|
| URL Pattern | `http://<ALB_DNS>/` |
| Username | `admin` |
| Password | Retrieved from `argocd-initial-admin-secret` |
| Protocol | HTTP (configure HTTPS via ACM certificate for production) |
| IP Whitelist | Configured via `allowed-cidrs.yaml` ConfigMap |

### Quick Commands

```bash
# Get ArgoCD URL
kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Login via ArgoCD CLI
argocd login <ALB_DNS> --username admin --password <password> --insecure

# List applications
argocd app list

# Get application status
argocd app get devops-agent-demo-dev

# Sync application manually
argocd app sync devops-agent-demo-dev

# View application history
argocd app history devops-agent-demo-dev

# Refresh (check for Git changes)
argocd app refresh devops-agent-demo-dev

# Force hard refresh
argocd app refresh devops-agent-demo-dev --hard
```

### Sync Configuration

The ArgoCD application is configured with:

| Setting | Value | Description |
|---------|-------|-------------|
| Auto-Sync | Enabled | Automatically deploys when Git changes |
| Self-Heal | Enabled | Corrects drift from desired state |
| Auto-Prune | Enabled | Removes resources deleted from Git |
| Retry | 5 attempts | Retries failed syncs with exponential backoff |

### Shared CIDR Configuration

IP whitelisting for ALB ingresses is managed centrally via the `allowed-cidrs` ConfigMap:

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

This value is injected into both the application ingress and ArgoCD ingress using Kustomize replacements, providing a single source of truth for IP whitelisting.

For comprehensive ArgoCD documentation, see [docs/argocd-setup.md](docs/argocd-setup.md).

## Related Repositories

- **Terraform Infrastructure**: Contains EKS, ECR, RDS, ElastiCache configuration
- **Application Code**: Contains microservices source code and Dockerfiles

## License

MIT
