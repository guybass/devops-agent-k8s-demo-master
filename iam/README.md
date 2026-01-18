# IAM Configuration for EKS Workloads

This directory contains all IAM policies, roles, and configuration needed for EKS workloads to access AWS services using IRSA (IAM Roles for Service Accounts).

## AWS Environment

| Setting | Value |
|---------|-------|
| AWS Account ID | `852140462703` |
| Region | `us-east-2` |
| EKS Cluster | `demo-pre-prod-cluster` |
| Namespace | `devops-agent-demo` |

## AWS Resources Summary

| Resource | Name/Path | Purpose |
|----------|-----------|---------|
| **S3 Bucket** | `devops-agent-demo-images-pre-prod` | Image storage for image-processor |
| **Secrets Manager** | `demo/pre-prod/database` | Database credentials (PostgreSQL) |
| **ElastiCache Redis** | `demo-pre-prod-redis` | Caching layer |
| **ECR Repositories** | `devops-agent-demo-*` | Container images |
| **RDS PostgreSQL** | `demo-pre-prod-postgres` | Application database |

## Service Account to AWS Resource Mapping

| ServiceAccount | Services | AWS Access Required |
|----------------|----------|---------------------|
| `external-secrets-sa` | External Secrets Operator | Secrets Manager (read) |
| `infrastructure-sa` | db-proxy, cache-manager, config-service, metrics-collector, queue-monitor, health-checker | Secrets Manager (read), ElastiCache (if IAM auth) |
| `processing-sa` | image-processor, analytics-service, report-generator, data-aggregator, event-processor | S3 (read/write) |
| `backend-sa` | auth, user, product, order, payment, notification | None (uses internal services) |
| `frontend-sa` | web-ui, admin-dashboard | None |
| `api-gateway-sa` | api-gateway | None |

## Directory Structure

```
iam/
├── README.md                           # This file
├── 01-oidc-provider.sh                 # OIDC provider setup script
├── 02-create-iam-roles.sh              # Main IAM setup script
├── policies/
│   ├── secrets-manager-policy.json     # Secrets Manager access
│   ├── s3-access-policy.json           # S3 bucket access
│   ├── ecr-pull-policy.json            # ECR image pull
│   ├── elasticache-policy.json         # ElastiCache access (IAM auth)
│   └── combined-workload-policy.json   # All permissions combined
├── trust-policies/
│   ├── external-secrets-trust-policy.json
│   ├── infrastructure-sa-trust-policy.json
│   └── processing-sa-trust-policy.json
└── k8s-manifests/
    └── service-accounts-with-irsa.yaml # K8s ServiceAccounts with annotations
```

## Setup Instructions

### Prerequisites

1. AWS CLI configured with appropriate permissions
2. kubectl configured to access the EKS cluster
3. eksctl installed (recommended)
4. jq installed for JSON manipulation

### Step 1: Configure OIDC Provider

```bash
# Using eksctl (recommended)
eksctl utils associate-iam-oidc-provider \
  --cluster demo-pre-prod-cluster \
  --region us-east-2 \
  --approve

# Verify
aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-2 \
  --query 'cluster.identity.oidc.issuer' \
  --output text
```

### Step 2: Create IAM Policies and Roles

```bash
# Make scripts executable
chmod +x iam/01-oidc-provider.sh iam/02-create-iam-roles.sh

# Run the setup script
./iam/02-create-iam-roles.sh
```

### Step 3: Apply Kubernetes ServiceAccounts

```bash
# Apply ServiceAccounts with IRSA annotations
kubectl apply -f iam/k8s-manifests/service-accounts-with-irsa.yaml

# Verify annotations
kubectl get sa -n devops-agent-demo -o yaml | grep eks.amazonaws.com/role-arn
```

### Step 4: Restart Pods to Pick Up New Credentials

```bash
# Restart deployments to get new AWS credentials
kubectl rollout restart deployment -n devops-agent-demo
```

## IAM Roles Created

### 1. devops-agent-demo-external-secrets-role

**ServiceAccount:** `external-secrets-sa`

**Policies Attached:**
- `devops-agent-demo-secrets-manager-policy`

**Purpose:** Allows External Secrets Operator to read secrets from AWS Secrets Manager.

### 2. devops-agent-demo-infrastructure-role

**ServiceAccount:** `infrastructure-sa`

**Policies Attached:**
- `devops-agent-demo-secrets-manager-policy`
- `devops-agent-demo-elasticache-policy`

**Purpose:** Allows infrastructure services (db-proxy, cache-manager) to access Secrets Manager and ElastiCache.

### 3. devops-agent-demo-processing-role

**ServiceAccount:** `processing-sa`

**Policies Attached:**
- `devops-agent-demo-s3-access-policy`

**Purpose:** Allows processing services (especially image-processor) to read/write to S3.

## Policy Details

### Secrets Manager Policy

```json
{
  "Action": [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret"
  ],
  "Resource": [
    "arn:aws:secretsmanager:us-east-2:852140462703:secret:demo/pre-prod/database*"
  ]
}
```

### S3 Policy

```json
{
  "Action": [
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",
    "s3:ListBucket"
  ],
  "Resource": [
    "arn:aws:s3:::devops-agent-demo-images-pre-prod",
    "arn:aws:s3:::devops-agent-demo-images-pre-prod/*"
  ]
}
```

### ECR Policy

```json
{
  "Action": [
    "ecr:GetAuthorizationToken",
    "ecr:BatchCheckLayerAvailability",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchGetImage"
  ],
  "Resource": [
    "arn:aws:ecr:us-east-2:852140462703:repository/devops-agent-demo-*"
  ]
}
```

## Verification Commands

```bash
# Verify OIDC provider
aws iam list-open-id-connect-providers

# Verify IAM roles
aws iam get-role --role-name devops-agent-demo-external-secrets-role
aws iam get-role --role-name devops-agent-demo-infrastructure-role
aws iam get-role --role-name devops-agent-demo-processing-role

# Verify ServiceAccount annotations
kubectl get sa external-secrets-sa -n devops-agent-demo -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Test credentials from a pod
kubectl run aws-cli-test --rm -it \
  --image=amazon/aws-cli \
  --serviceaccount=processing-sa \
  -n devops-agent-demo \
  -- sts get-caller-identity
```

## Troubleshooting

### Pod cannot assume IAM role

1. Verify ServiceAccount has correct annotation:
   ```bash
   kubectl get sa <sa-name> -n devops-agent-demo -o yaml
   ```

2. Verify trust policy has correct OIDC ID:
   ```bash
   aws iam get-role --role-name <role-name> --query 'Role.AssumeRolePolicyDocument'
   ```

3. Check if OIDC provider exists:
   ```bash
   aws iam list-open-id-connect-providers
   ```

### AccessDenied errors

1. Verify policy is attached to role:
   ```bash
   aws iam list-attached-role-policies --role-name <role-name>
   ```

2. Check resource ARNs in policy match actual resources

3. Verify pod is using correct ServiceAccount:
   ```bash
   kubectl get pod <pod-name> -n devops-agent-demo -o jsonpath='{.spec.serviceAccountName}'
   ```

## Security Notes

1. **Least Privilege:** Each ServiceAccount only has access to the AWS resources it needs
2. **No Wildcards:** Resource ARNs are specific, not using `*` where possible
3. **Namespace Scoped:** Trust policies restrict access to specific namespace/ServiceAccount pairs
4. **Secrets Encrypted:** Secrets Manager secrets are encrypted at rest
5. **S3 Encrypted:** S3 bucket uses SSE-S3 encryption
6. **TLS Enabled:** ElastiCache has transit encryption enabled

## Notes on ElastiCache

The current ElastiCache configuration uses password authentication via `REDIS_URL` secret, not IAM authentication. The ElastiCache IAM policy is included for future use if you enable IAM authentication.

To enable IAM authentication for Redis:
1. Update ElastiCache replication group with `--transit-encryption-enabled` and `--auth-token-enabled false`
2. Create ElastiCache user with IAM authentication
3. Update application to use IAM auth instead of password
