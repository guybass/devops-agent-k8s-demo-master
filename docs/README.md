# DevOps Agent Demo - Kubernetes Documentation

Welcome to the DevOps Agent Demo Kubernetes project documentation. This guide provides comprehensive information about deploying and managing the microservices application on Amazon EKS.

## Quick Links

| Document | Description |
|----------|-------------|
| [Architecture](./architecture.md) | System architecture and component overview |
| [ArgoCD Setup](./argocd-setup.md) | GitOps deployment with ArgoCD |
| [Secrets Management](./secrets-management.md) | AWS Secrets Manager integration with External Secrets |
| [IAM Setup](./iam-setup.md) | IRSA configuration and IAM policies |
| [Deployment Guide](./deployment-guide.md) | Step-by-step deployment instructions |
| [Troubleshooting](./troubleshooting.md) | Common issues and solutions |

## Project Overview

The DevOps Agent Demo is a production-ready microservices application consisting of 20 services deployed on Amazon EKS. The application demonstrates enterprise-grade Kubernetes patterns including:

- **Microservices Architecture**: 20 services organized into logical tiers
- **GitOps with ArgoCD**: Automated deployment with auto-sync, self-heal, and auto-prune
- **Kustomize Overlays**: Environment-specific configurations for dev, staging, and production
- **Security-First**: IRSA, NetworkPolicies, Pod Security Standards
- **External Secrets**: AWS Secrets Manager integration via External Secrets Operator (database, Redis, and ArgoCD credentials)
- **High Availability**: HPA, PDB, pod anti-affinity, multi-AZ distribution
- **Flexible Deployment**: Multiple overlay options for different access modes
- **AWS Load Balancer Controller**: ALB-based ingress with path-based routing

## Current Status

**Deployment Status**: All 20 microservices deployed and running on EKS cluster `demo-pre-prod-cluster`.

| Component | Status | Details |
|-----------|--------|---------|
| Base Manifests | Complete | All 20 services with deployments, services, HPA, PDB |
| External Secrets | Complete | Database and Redis credentials synced via ESO (API v1) |
| IRSA Configuration | Complete | IAM roles for external-secrets-sa, infrastructure-sa, processing-sa |
| Network Policies | Complete | Zero-trust network model with tier-based isolation |
| Kustomize Overlays | Complete | 5 overlays: dev, dev-no-domain, dev-port-forward, staging, production |
| AWS Load Balancer Controller | Complete | Installed via Helm with IRSA |
| Ingress (dev-no-domain) | Active | ALB with path-based routing, CIDR-restricted access |
| ArgoCD | Complete | GitOps deployment with auto-sync, self-heal, and auto-prune |
| ArgoCD External Secrets | Complete | GitHub SSH key and Redis password via ESO |

### Current ALB Endpoint

```
http://k8s-devopsag-devdevop-1bb3545a8a-469037918.us-east-2.elb.amazonaws.com
```

| Path | Service | Description |
|------|---------|-------------|
| `/` | web-ui | Main web application |
| `/api` | api-gateway | API endpoints |
| `/admin` | admin-dashboard | Admin interface |

**Security Note**: Inbound access is restricted to CIDR `79.181.131.147/32` via ALB annotation.

## AWS Environment

| Setting | Value |
|---------|-------|
| AWS Account ID | `852140462703` |
| Region | `us-east-2` |
| EKS Cluster | `demo-pre-prod-cluster` |
| Namespace | `devops-agent-demo` |

## AWS Resources

| Resource | Name/Path | Purpose |
|----------|-----------|---------|
| S3 Bucket | `devops-agent-demo-images-pre-prod` | Image storage |
| Secrets Manager | `demo/pre-prod/database` | Database credentials |
| Secrets Manager | `demo/pre-prod/redis` | Redis credentials |
| Secrets Manager | `argocd/github-ssh-key` | ArgoCD GitHub SSH key |
| Secrets Manager | `argocd/redis` | ArgoCD Redis password |
| ElastiCache | `demo-pre-prod-redis` | Caching layer |
| Redis Endpoint | `master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com:6379` | Redis primary endpoint |
| ECR | `devops-agent-demo-*` | Container images (tagged `1.0.0`) |
| RDS PostgreSQL | `demo-pre-prod-postgres` | Application database |
| IAM Role | `AmazonEKSLoadBalancerControllerRole` | ALB Controller IRSA |
| IAM Policy | `AWSLoadBalancerControllerIAMPolicy` | ALB Controller permissions |
| IAM Role | `ArgoCD-ExternalSecrets-Role` | ArgoCD External Secrets IRSA |
| IAM Policy | `ArgoCD-ExternalSecrets-Policy` | ArgoCD secrets access |

## Quick Start

### Prerequisites

Ensure you have the following tools installed:

```bash
# AWS CLI v2
aws --version

# kubectl
kubectl version --client

# Helm 3
helm version

# eksctl (optional but recommended)
eksctl version

# kustomize (or use kubectl -k)
kustomize version
```

### 1. Connect to EKS Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig \
  --name demo-pre-prod-cluster \
  --region us-east-2

# Verify connection
kubectl get nodes
kubectl cluster-info
```

### 2. Choose Your Deployment Method

We provide multiple deployment overlays to suit different scenarios:

#### Option A: Development with Domain (overlays/dev)
For development with custom domain names configured in DNS:

```bash
kubectl apply -k overlays/dev
```

#### Option B: Development without Domain (overlays/dev-no-domain) - CURRENTLY DEPLOYED
For development without a domain name. Uses path-based routing on ALB's auto-generated DNS:

```bash
# Deploy the application
kubectl apply -k overlays/dev-no-domain

# Get the ALB DNS name
kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'

# Current ALB URL:
#   http://k8s-devopsag-devdevop-1bb3545a8a-469037918.us-east-2.elb.amazonaws.com

# Access URLs:
#   - Web UI:          http://<ALB_DNS>/
#   - Admin Dashboard: http://<ALB_DNS>/admin/
#   - API Gateway:     http://<ALB_DNS>/api/
```

**Configuration Notes:**
- HTTP only (no SSL/TLS certificate configured)
- Inbound CIDR restricted to `79.181.131.147/32` via `alb.ingress.kubernetes.io/inbound-cidrs` annotation
- All services running with 1 replica (HPA disabled in dev overlay)

#### Option C: Development with Port Forward (overlays/dev-port-forward)
For local development without any ingress. Access services via kubectl port-forward:

```bash
# Deploy the application (no ingress created)
kubectl apply -k overlays/dev-port-forward

# Forward ports to access services locally (run in separate terminals)
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo

# Access URLs:
#   - Web UI:          http://localhost:3000
#   - Admin Dashboard: http://localhost:3001
#   - API Gateway:     http://localhost:8080
```

#### Option D: Staging Environment (overlays/staging)

```bash
kubectl apply -k overlays/staging
```

#### Option E: Production Environment (overlays/production)

```bash
kubectl apply -k overlays/production
```

#### Option F: GitOps with ArgoCD (Recommended)

Deploy using ArgoCD for automated GitOps workflow:

```bash
# Deploy ArgoCD infrastructure
kubectl apply -k infrastructure/argocd

# Wait for ArgoCD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Deploy ArgoCD applications
kubectl apply -k argocd-apps

# Get ArgoCD URL
kubectl get ingress argocd-ingress -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

See [ArgoCD Setup](./argocd-setup.md) for detailed configuration.

### 3. Verify Deployment

```bash
# Check all resources
kubectl get all -n devops-agent-demo

# Check pod status
kubectl get pods -n devops-agent-demo -o wide

# Check services
kubectl get svc -n devops-agent-demo

# Check ingress and get ALB URL (if using dev or dev-no-domain)
kubectl get ingress -n devops-agent-demo

# Check External Secrets sync status
kubectl get externalsecret -n devops-agent-demo

# Check ArgoCD application status (if using GitOps)
kubectl get applications -n argocd
```

## Available Overlays

| Overlay | Use Case | Ingress | Access Method |
|---------|----------|---------|---------------|
| `dev` | Development with domain | Yes (host-based) | Via domain names |
| `dev-no-domain` | Development without domain | Yes (path-based) | Via ALB DNS with path routing |
| `dev-port-forward` | Local development | No | kubectl port-forward |
| `staging` | Pre-production testing | Yes (host-based) | Via domain names |
| `production` | Production deployment | Yes (host-based) | Via domain names |

## GitOps with ArgoCD

The project includes ArgoCD configuration for GitOps-based deployment:

| Component | Location | Description |
|-----------|----------|-------------|
| ArgoCD Infrastructure | `infrastructure/argocd/` | Helm-templated ArgoCD manifests |
| ArgoCD Applications | `argocd-apps/` | Application and project definitions |
| Shared CIDRs | `overlays/dev-no-domain/allowed-cidrs.yaml` | IP whitelist for ingresses |

**ArgoCD Features:**
- **Auto-sync**: Automatically deploys changes pushed to Git
- **Self-heal**: Corrects drift from desired state
- **Auto-prune**: Removes resources no longer in Git
- **Secure Secrets**: GitHub SSH key and Redis password via External Secrets

See [ArgoCD Setup](./argocd-setup.md) for detailed documentation.

## Service Architecture

### Service Tiers

| Tier | Services | Description |
|------|----------|-------------|
| **Frontend** | web-ui, admin-dashboard | NGINX-based user-facing applications |
| **Gateway** | api-gateway | Central API routing (Python/FastAPI) |
| **Backend** | auth, user, product, order, payment, notification | Business logic services (Python/FastAPI) |
| **Processing** | event-processor, analytics, report-generator, data-aggregator, image-processor | Data processing services |
| **Infrastructure** | db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker, scheduler | Platform services (7 total) |

### NGINX Frontend Configuration

The frontend services (web-ui, admin-dashboard) use NGINX with configurable upstream routing:

- **API Gateway Host**: Configured via `API_GATEWAY_HOST` environment variable
- **Template File**: `/templates/default.conf.template` processed by `envsubst`
- **Config Volume**: EmptyDir mounted at `/etc/nginx/conf.d` for writable configuration
- **Startup**: `docker-entrypoint.sh` generates NGINX config from template on container start

### Service Ports

| Service | Port | Protocol |
|---------|------|----------|
| web-ui | 3000 | HTTP |
| admin-dashboard | 3001 | HTTP |
| api-gateway | 8080 | HTTP |
| auth-service | 8002 | HTTP |
| user-service | 8001 | HTTP |
| product-service | 8004 | HTTP |
| order-service | 8003 | HTTP |
| payment-service | 8005 | HTTP |
| notification-service | 8006 | HTTP |
| event-processor | 8010 | HTTP |
| analytics-service | 8011 | HTTP |
| report-generator | 8012 | HTTP |
| data-aggregator | 8013 | HTTP |
| image-processor | 8020 | HTTP |
| db-proxy | 5433 | TCP |
| cache-manager | 6380 | TCP |
| config-service | 9093 | HTTP |
| metrics-collector | 9090 | HTTP |
| queue-monitor | 9091 | HTTP |
| health-checker | 9092 | HTTP |
| scheduler | 9094 | HTTP |

## Security Features

### Pod Security

All deployments implement security best practices:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

### Network Security

- Default deny ingress NetworkPolicy
- Component-based network segmentation
- Prometheus scraping allowed from monitoring namespace

### Secrets Management

- AWS Secrets Manager for sensitive data (database and Redis credentials)
- External Secrets Operator for Kubernetes integration
- IRSA for secure AWS authentication
- Automatic secret refresh every hour

## Resource Requirements

### Development Environment

- 2 nodes (t3.medium)
- ~2 GB RAM total
- ~2 vCPU total

### Production Environment

- 4+ nodes (t3.large or larger)
- Multi-AZ deployment
- ~8 GB RAM minimum
- ~8 vCPU minimum

## Monitoring

All services expose Prometheus metrics:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "<service-port>"
  prometheus.io/path: "/metrics"
```

Health endpoints are available at `/health` for all services.

## Support

For issues and questions:

1. Check the [Troubleshooting Guide](./troubleshooting.md)
2. Review the [Architecture Documentation](./architecture.md)
3. Consult the [Deployment Guide](./deployment-guide.md) for setup issues
