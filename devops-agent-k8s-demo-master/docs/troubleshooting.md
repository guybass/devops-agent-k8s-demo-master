# Troubleshooting Guide

This document provides solutions for common issues encountered when deploying and operating the DevOps Agent Demo on Amazon EKS.

## Table of Contents

- [Quick Diagnosis Commands](#quick-diagnosis-commands)
- [Known Fixed Issues](#known-fixed-issues)
- [EKS Connection Issues](#eks-connection-issues)
- [External Secrets Issues](#external-secrets-issues)
- [SecretStore Authentication Issues](#secretstore-authentication-issues)
- [Pod Failures](#pod-failures)
- [Networking Issues](#networking-issues)
- [Ingress and ALB Issues](#ingress-and-alb-issues)
- [Port-Forward Issues](#port-forward-issues)
- [Database Connectivity Issues](#database-connectivity-issues)
- [Redis Connectivity Issues](#redis-connectivity-issues)
- [Resource Issues](#resource-issues)
- [IRSA Issues](#irsa-issues)
- [NGINX Frontend Issues](#nginx-frontend-issues)
- [ArgoCD Issues](#argocd-issues)
- [Debugging Commands Reference](#debugging-commands-reference)

## Quick Diagnosis Commands

Run these commands to get an overview of the deployment status:

```bash
# Check all resources in the namespace
kubectl get all -n devops-agent-demo

# Check pod status and events
kubectl get pods -n devops-agent-demo -o wide
kubectl get events -n devops-agent-demo --sort-by='.lastTimestamp'

# Check External Secrets status (both database and Redis)
kubectl get externalsecret -n devops-agent-demo
kubectl get secretstore -n devops-agent-demo

# Check ingress status
kubectl get ingress -n devops-agent-demo

# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Check for failed pods
kubectl get pods -n devops-agent-demo --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check ArgoCD application status
kubectl get applications -n argocd
kubectl get pods -n argocd
```

## Known Fixed Issues

This section documents issues that were encountered and resolved during the initial deployment.

### 1. Python Services: Missing email-validator

**Symptom:** Python services (auth-service, user-service, etc.) failed to start with `ImportError: email-validator is not installed`.

**Cause:** Pydantic v2 requires `email-validator` to be installed separately for email validation.

**Fix:** Added `pydantic[email]` to requirements.txt in affected services:

```txt
# requirements.txt
pydantic[email]>=2.0.0
```

### 2. db-proxy: SlowQuery Import Error

**Symptom:** db-proxy service failed with `ImportError: cannot import name 'SlowQuery' from 'app'`.

**Cause:** Missing export in `__init__.py` file.

**Fix:** Updated `/app/__init__.py` to include SlowQuery in exports:

```python
from .models import SlowQuery
```

### 3. ALB Controller: DescribeListenerAttributes Permission

**Symptom:** Ingress stuck without ALB address. Controller logs showed:
```
AccessDenied: User is not authorized to perform: elasticloadbalancing:DescribeListenerAttributes
```

**Cause:** The AWS Load Balancer Controller IAM policy was missing the `DescribeListenerAttributes` permission.

**Fix:** Updated the IAM policy to include the missing permission:

```bash
# Download updated policy and create new version
aws iam create-policy-version \
  --policy-arn arn:aws:iam::852140462703:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/updated-policy.json \
  --set-as-default
```

### 4. Ingress: SSL Redirect Without HTTPS Listener

**Symptom:** ALB health checks failing. Requests returning 308 redirect loops.

**Cause:** Default ALB configuration includes SSL redirect annotation, but no HTTPS listener was configured (no SSL certificate).

**Fix:** Removed SSL redirect and configured HTTP-only listener in dev-no-domain overlay:

```yaml
annotations:
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
  # Removed: alb.ingress.kubernetes.io/ssl-redirect: '443'
```

### 5. NGINX Frontend: Read-Only Filesystem

**Symptom:** web-ui and admin-dashboard pods failing with:
```
nginx: [emerg] open() "/etc/nginx/conf.d/default.conf" failed (30: Read-only file system)
```

**Cause:** Security context set `readOnlyRootFilesystem: true`, but NGINX needed to write config files.

**Fix:** Added EmptyDir volume for writable NGINX config directory:

```yaml
volumeMounts:
  - name: nginx-config
    mountPath: /etc/nginx/conf.d
volumes:
  - name: nginx-config
    emptyDir: {}
```

### 6. HPA Conflicts in Dev Environment

**Symptom:** Pods scaling unexpectedly or HPA showing errors about target not found.

**Cause:** HPAs were defined in base but dev overlays scaled replicas to 1, causing conflicts.

**Fix:** Removed HPAs from dev overlays entirely:

```yaml
# In overlays/dev-no-domain/kustomization.yaml
# HPAs are not included - prevents scaling conflicts with single replica
```

### 7. Service URLs Missing dev- Prefix in ConfigMap

**Symptom:** Services unable to communicate with each other. Pods show connection errors like:
```
Failed to connect to auth-service:8002
Connection refused: user-service:8001
```

**Cause:** The `dev-no-domain` overlay uses `namePrefix: dev-` which adds a `dev-` prefix to all resource names including Services. However, the ConfigMap service URLs were not updated to match, causing services to look for `auth-service` instead of `dev-auth-service`.

**Fix:** Updated the ConfigMap patch in `overlays/dev-no-domain/app/kustomization.yaml` to include all service URLs with the `dev-` prefix:

```yaml
# In overlays/dev-no-domain/app/kustomization.yaml
- patch: |-
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: common-config
    data:
      # Service URLs with dev- prefix to match namePrefix transformation
      AUTH_SERVICE_URL: "http://dev-auth-service:8002"
      USER_SERVICE_URL: "http://dev-user-service:8001"
      PRODUCT_SERVICE_URL: "http://dev-product-service:8004"
      ORDER_SERVICE_URL: "http://dev-order-service:8003"
      PAYMENT_SERVICE_URL: "http://dev-payment-service:8005"
      NOTIFICATION_SERVICE_URL: "http://dev-notification-service:8006"
      EVENT_PROCESSOR_URL: "http://dev-event-processor:8010"
      ANALYTICS_SERVICE_URL: "http://dev-analytics-service:8011"
      REPORT_GENERATOR_URL: "http://dev-report-generator:8012"
      DATA_AGGREGATOR_URL: "http://dev-data-aggregator:8013"
      IMAGE_PROCESSOR_URL: "http://dev-image-processor:8020"
      DB_PROXY_URL: "http://dev-db-proxy:5433"
      CACHE_MANAGER_URL: "http://dev-cache-manager:6380"
      CONFIG_SERVICE_URL: "http://dev-config-service:9093"
      METRICS_COLLECTOR_URL: "http://dev-metrics-collector:9090"
      QUEUE_MONITOR_URL: "http://dev-queue-monitor:9091"
      HEALTH_CHECKER_URL: "http://dev-health-checker:9092"
      API_GATEWAY_URL: "http://dev-api-gateway:8080"
  target:
    kind: ConfigMap
    name: common-config
```

**Note:** When using `namePrefix` in kustomize overlays, always remember to update any ConfigMap values that reference resource names (like service URLs) to include the same prefix.

### 8. API Gateway Route Prefix Missing for ALB Path-Based Routing

**Symptom:** API requests through the ALB return 404 errors. For example:
```
GET http://<ALB_DNS>/api/auth/register -> 404 Not Found
GET http://<ALB_DNS>/api/products -> 404 Not Found
```

But direct service calls work:
```
kubectl exec -it <pod> -- curl http://api-gateway:8080/auth/register -> 200 OK
```

**Cause:** When using path-based routing with the ALB Ingress (e.g., `dev-no-domain` overlay), the ALB forwards the full request path to the backend. For example:
- ALB receives: `GET /api/auth/register`
- ALB forwards to api-gateway: `GET /api/auth/register` (full path preserved)

However, the FastAPI routers in the API Gateway were defined without the `/api` prefix:
```python
# Before (incorrect)
app.include_router(auth.router, tags=["auth"])  # Routes: /auth/register, /auth/login
app.include_router(products.router, tags=["products"])  # Routes: /products
```

This caused a mismatch - the ALB sends `/api/auth/register` but the app expects `/auth/register`.

**Fix:** Updated the API Gateway (`services/api-gateway/src/main.py`) to include the `/api` prefix on all routers:

```python
# After (correct)
app.include_router(auth.router, prefix="/api", tags=["auth"])  # Routes: /api/auth/register, /api/auth/login
app.include_router(products.router, prefix="/api", tags=["products"])  # Routes: /api/products
app.include_router(users.router, prefix="/api", tags=["users"])
app.include_router(orders.router, prefix="/api", tags=["orders"])
app.include_router(health_router, prefix="/api", tags=["health"])
```

**Note:** This fix is required when using path-based routing where the ingress routes `/api/*` to the API Gateway. If using host-based routing (e.g., `api.example.com`), the `/api` prefix may not be needed since the entire domain is dedicated to the API.

### 9. Product Data Transformation - Frontend/Backend Field Name Mismatch

**Symptom:** Products page shows products but prices display as `$0.00` or `NaN`, and stock shows as `undefined` or `0`.

**Cause:** The backend `product-service` returns data in a different format than what the frontend expects:

| Field | Backend Format | Frontend Expects |
|-------|---------------|------------------|
| Price | `price_cents: 1999` (integer, cents) | `price: 19.99` (float, dollars) |
| Stock | `inventory.available: 50` (nested) | `stock: 50` (top-level) |

Example backend response:
```json
{
  "id": "prod_123",
  "name": "Widget",
  "price_cents": 1999,
  "inventory": {
    "available": 50,
    "reserved": 5
  }
}
```

Example frontend expectation:
```json
{
  "id": "prod_123",
  "name": "Widget",
  "price": 19.99,
  "stock": 50
}
```

**Fix:** Added a `_transform_product()` function to the API Gateway's products route (`services/api-gateway/src/routes/products.py`) that transforms the backend response to the frontend format:

```python
def _transform_product(product: dict) -> dict:
    """Transform backend product format to frontend format."""
    transformed = product.copy()

    # Convert price_cents (integer) to price (float dollars)
    if "price_cents" in transformed:
        transformed["price"] = transformed["price_cents"] / 100.0

    # Extract stock from inventory.available
    if "inventory" in transformed and isinstance(transformed["inventory"], dict):
        transformed["stock"] = transformed["inventory"].get("available", 0)

    return transformed
```

**Note:** This is a common pattern when the API Gateway serves as a Backend-for-Frontend (BFF). The API Gateway can transform data formats between backend services and frontend clients without requiring changes to either.

## EKS Connection Issues

### Cannot Connect to EKS Cluster

**Symptoms:**
- `kubectl` commands timeout or fail
- "Unable to connect to the server" errors
- "Unauthorized" errors

**Diagnosis:**

```bash
# Check AWS credentials
aws sts get-caller-identity

# Check kubeconfig
kubectl config view
kubectl config current-context

# Test cluster connectivity
kubectl cluster-info
```

**Solutions:**

1. **Update kubeconfig:**
   ```bash
   aws eks update-kubeconfig \
     --name demo-pre-prod-cluster \
     --region us-east-1
   ```

2. **Verify IAM permissions:**
   ```bash
   # Check if your IAM user/role has eks:DescribeCluster permission
   aws eks describe-cluster --name demo-pre-prod-cluster --region us-east-1
   ```

3. **Check aws-auth ConfigMap:**
   ```bash
   kubectl get configmap aws-auth -n kube-system -o yaml
   ```

### Private Endpoint Access Issues

**Symptoms:**
- Cannot connect from outside VPC
- Timeout when running kubectl commands

**Diagnosis:**

```bash
# Check cluster endpoint configuration
aws eks describe-cluster \
  --name demo-pre-prod-cluster \
  --region us-east-1 \
  --query 'cluster.resourcesVpcConfig'
```

**Solutions:**

1. **Use VPN or bastion host:**
   ```bash
   # Connect via bastion
   ssh -i key.pem ec2-user@bastion-host

   # Then run kubectl commands from bastion
   ```

2. **Use SSM Session Manager:**
   ```bash
   # Start port forwarding session
   aws ssm start-session \
     --target i-xxxxxxxxxxxxx \
     --document-name AWS-StartPortForwardingSessionToRemoteHost \
     --parameters '{"host":["eks-endpoint"],"portNumber":["443"],"localPortNumber":["6443"]}'
   ```

3. **Enable public endpoint (if allowed by security policy):**
   ```bash
   aws eks update-cluster-config \
     --name demo-pre-prod-cluster \
     --region us-east-1 \
     --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
   ```

## External Secrets Issues

### External Secrets CRD Version Issues

**Symptoms:**
- "no matches for kind 'ExternalSecret' in version 'external-secrets.io/v1beta1'" error
- CRD not found errors

**Diagnosis:**

```bash
# Check installed CRDs
kubectl get crd | grep external-secrets

# Check CRD versions
kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'
```

**Solutions:**

1. **Update External Secrets Operator:**
   ```bash
   helm repo update
   helm upgrade external-secrets external-secrets/external-secrets \
     --namespace external-secrets \
     --set installCRDs=true
   ```

2. **Update API version in manifests:**

   Change from:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   ```

   To:
   ```yaml
   apiVersion: external-secrets.io/v1
   ```

3. **Reinstall External Secrets Operator:**
   ```bash
   helm uninstall external-secrets -n external-secrets
   kubectl delete crd externalsecrets.external-secrets.io
   kubectl delete crd secretstores.external-secrets.io
   kubectl delete crd clustersecretstores.external-secrets.io

   helm install external-secrets external-secrets/external-secrets \
     --namespace external-secrets \
     --create-namespace \
     --set installCRDs=true
   ```

### ExternalSecret Not Syncing

**Symptoms:**
- ExternalSecret shows `SecretSyncedError` status
- Kubernetes Secret not created
- Secret data is empty

**Diagnosis:**

```bash
# Check ExternalSecret status (both database and Redis)
kubectl get externalsecret -n devops-agent-demo
kubectl describe externalsecret database-credentials-external -n devops-agent-demo
kubectl describe externalsecret redis-credentials-external -n devops-agent-demo

# Check events
kubectl get events -n devops-agent-demo --field-selector involvedObject.name=database-credentials-external
kubectl get events -n devops-agent-demo --field-selector involvedObject.name=redis-credentials-external

# Check operator logs
kubectl logs -l app.kubernetes.io/name=external-secrets -n external-secrets --tail=50
```

**Solutions:**

1. **Verify SecretStore is ready:**
   ```bash
   kubectl get secretstore -n devops-agent-demo
   # Should show STATUS=Valid and READY=True
   ```

2. **Check secret paths in AWS:**
   ```bash
   # Database secret
   aws secretsmanager get-secret-value \
     --secret-id demo/pre-prod/database \
     --region us-east-1

   # Redis secret
   aws secretsmanager get-secret-value \
     --secret-id demo/pre-prod/redis \
     --region us-east-1
   ```

3. **Verify secret keys match:**
   Ensure the `property` values in ExternalSecret match the actual keys in AWS Secrets Manager.

4. **Force refresh:**
   ```bash
   kubectl annotate externalsecret database-credentials-external \
     -n devops-agent-demo \
     force-sync=$(date +%s) \
     --overwrite

   kubectl annotate externalsecret redis-credentials-external \
     -n devops-agent-demo \
     force-sync=$(date +%s) \
     --overwrite
   ```

## SecretStore Authentication Issues

### SecretStore Shows "AuthenticationFailed"

**Symptoms:**
- SecretStore status shows authentication errors
- "AccessDeniedException" in operator logs
- "AssumeRoleWithWebIdentity" failures

**Diagnosis:**

```bash
# Check SecretStore status
kubectl describe secretstore aws-secrets-manager -n devops-agent-demo

# Check ServiceAccount annotation
kubectl get sa external-secrets-sa -n devops-agent-demo -o yaml

# Check operator logs for detailed error
kubectl logs -l app.kubernetes.io/name=external-secrets -n external-secrets | grep -i error
```

**Solutions:**

1. **Verify IRSA annotation:**
   ```bash
   kubectl get sa external-secrets-sa -n devops-agent-demo \
     -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

   # Should output:
   # arn:aws:iam::852140462703:role/devops-agent-demo-external-secrets-role
   ```

2. **Verify IAM role trust policy:**
   ```bash
   aws iam get-role --role-name devops-agent-demo-external-secrets-role \
     --query 'Role.AssumeRolePolicyDocument'
   ```

   Ensure it contains:
   - Correct OIDC provider ARN
   - Correct ServiceAccount: `system:serviceaccount:devops-agent-demo:external-secrets-sa`

3. **Verify OIDC ID matches:**
   ```bash
   # Get cluster OIDC ID
   aws eks describe-cluster \
     --name demo-pre-prod-cluster \
     --region us-east-1 \
     --query 'cluster.identity.oidc.issuer' \
     --output text | cut -d '/' -f 5

   # Compare with trust policy OIDC ID
   aws iam get-role --role-name devops-agent-demo-external-secrets-role \
     --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Federated'
   ```

4. **Test credentials from a pod:**
   ```bash
   kubectl run aws-test --rm -it \
     --image=amazon/aws-cli \
     --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
     -n devops-agent-demo \
     -- sts get-caller-identity
   ```

5. **Verify policy permissions include both secrets:**
   ```bash
   aws iam list-attached-role-policies \
     --role-name devops-agent-demo-external-secrets-role

   # Get policy document - should include both demo/pre-prod/database* and demo/pre-prod/redis*
   aws iam get-policy-version \
     --policy-arn arn:aws:iam::852140462703:policy/devops-agent-demo-secrets-manager-policy \
     --version-id v1
   ```

### OIDC Provider Not Found

**Symptoms:**
- "OpenIDConnect provider does not exist" error
- Trust relationship cannot be established

**Solutions:**

```bash
# Create OIDC provider
eksctl utils associate-iam-oidc-provider \
  --cluster demo-pre-prod-cluster \
  --region us-east-1 \
  --approve

# Verify
aws iam list-open-id-connect-providers
```

## Pod Failures

### Pods Stuck in Pending

**Symptoms:**
- Pods remain in `Pending` state
- Pods not scheduled to nodes

**Diagnosis:**

```bash
kubectl describe pod <pod-name> -n devops-agent-demo

# Look for events like:
# - Insufficient cpu/memory
# - No nodes available
# - Taint/toleration issues
# - PVC binding issues
```

**Solutions:**

1. **Insufficient resources:**
   ```bash
   # Check node resources
   kubectl describe nodes | grep -A 5 "Allocated resources"

   # Scale down replicas or increase node count
   kubectl scale deployment <name> --replicas=1 -n devops-agent-demo
   ```

2. **Node taints:**
   ```bash
   # Check node taints
   kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'

   # Add tolerations to deployment if needed
   ```

3. **PVC issues:**
   ```bash
   kubectl get pvc -n devops-agent-demo
   kubectl describe pvc <pvc-name> -n devops-agent-demo
   ```

### Pods in CrashLoopBackOff

**Symptoms:**
- Pods repeatedly restart
- `CrashLoopBackOff` status

**Diagnosis:**

```bash
# Check current logs
kubectl logs <pod-name> -n devops-agent-demo

# Check previous container logs
kubectl logs <pod-name> -n devops-agent-demo --previous

# Check container exit code
kubectl get pod <pod-name> -n devops-agent-demo -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

**Solutions:**

1. **Application error:**
   - Check application logs for startup errors
   - Verify environment variables and secrets

2. **Resource limits too low:**
   ```yaml
   resources:
     limits:
       memory: "512Mi"  # Increase if OOMKilled
   ```

3. **Probe configuration:**
   ```bash
   # Check if probes are failing
   kubectl describe pod <pod-name> -n devops-agent-demo | grep -A 10 "Liveness\|Readiness"

   # Adjust probe settings
   # - Increase initialDelaySeconds
   # - Increase timeoutSeconds
   # - Increase failureThreshold
   ```

4. **Missing secrets or configmaps:**
   ```bash
   kubectl get events -n devops-agent-demo | grep -i "secret\|configmap"
   ```

### Pods OOMKilled

**Symptoms:**
- `OOMKilled` exit code (137)
- Container restarts due to memory

**Solutions:**

```yaml
# Increase memory limits
resources:
  requests:
    memory: "256Mi"
  limits:
    memory: "1Gi"  # Increase as needed
```

### ImagePullBackOff

**Symptoms:**
- `ImagePullBackOff` or `ErrImagePull` status
- Cannot pull container image

**Diagnosis:**

```bash
kubectl describe pod <pod-name> -n devops-agent-demo | grep -A 5 "Events"

# Common causes:
# - Image not found
# - Authentication failed
# - Network issues
```

**Solutions:**

1. **Verify image exists:**
   ```bash
   aws ecr describe-images \
     --repository-name devops-agent-demo-api-gateway \
     --region us-east-1
   ```

2. **Check ECR authentication:**
   ```bash
   # Nodes should have ECR pull permissions via instance role
   # Verify node role has AmazonEC2ContainerRegistryReadOnly policy
   ```

3. **Verify image tag:**
   ```bash
   # List available tags
   aws ecr list-images \
     --repository-name devops-agent-demo-api-gateway \
     --region us-east-1
   ```

## Networking Issues

### Service Not Accessible

**Symptoms:**
- Cannot reach service from other pods
- Service endpoints empty

**Diagnosis:**

```bash
# Check service endpoints
kubectl get endpoints <service-name> -n devops-agent-demo

# Check service selector matches pod labels
kubectl get svc <service-name> -n devops-agent-demo -o yaml
kubectl get pods -n devops-agent-demo -l <selector-labels>
```

**Solutions:**

1. **Fix label selectors:**
   Ensure service selector matches pod labels exactly.

2. **Check pod readiness:**
   ```bash
   # Pods must be Ready to be added to endpoints
   kubectl get pods -n devops-agent-demo -o wide
   ```

### DNS Resolution Fails

**Symptoms:**
- Cannot resolve service names
- `nslookup` fails inside pods

**Diagnosis:**

```bash
# Test DNS from a debug pod
kubectl run debug --rm -it --image=busybox -n devops-agent-demo -- \
  nslookup api-gateway.devops-agent-demo.svc.cluster.local

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**Solutions:**

1. **Restart CoreDNS:**
   ```bash
   kubectl rollout restart deployment/coredns -n kube-system
   ```

2. **Check NetworkPolicy allows DNS:**
   Ensure egress to kube-dns is allowed on port 53.

### NetworkPolicy Blocking Traffic

**Symptoms:**
- Connections timeout between services
- Works when NetworkPolicy is deleted

**Diagnosis:**

```bash
# List NetworkPolicies
kubectl get networkpolicy -n devops-agent-demo

# Describe specific policy
kubectl describe networkpolicy <policy-name> -n devops-agent-demo

# Test connectivity
kubectl run debug --rm -it --image=curlimages/curl -n devops-agent-demo -- \
  curl -v http://api-gateway:8080/health
```

**Solutions:**

1. **Verify policy selectors:**
   Ensure `podSelector` and `namespaceSelector` match correctly.

2. **Check ingress/egress rules:**
   Verify ports and protocols are correct.

3. **Temporarily disable for testing:**
   ```bash
   kubectl delete networkpolicy <policy-name> -n devops-agent-demo
   # Test connectivity
   # Re-apply corrected policy
   ```

## Ingress and ALB Issues

### Ingress Shows No Address

**Symptoms:**
- `kubectl get ingress` shows empty ADDRESS field
- ALB not created in AWS

**Diagnosis:**

```bash
# Check ingress status
kubectl get ingress -n devops-agent-demo
kubectl describe ingress -n devops-agent-demo

# Check AWS Load Balancer Controller logs
kubectl logs -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system
```

**Common Causes and Solutions:**

| Cause | Solution |
|-------|----------|
| AWS LB Controller not installed | Install AWS Load Balancer Controller |
| Missing IAM permissions | Attach correct IAM policy to controller |
| Invalid ingress class | Verify `ingressClassName: alb` is set |
| Subnet issues | Tag subnets correctly for ALB discovery |
| Security group issues | Check security group allows traffic |

```bash
# Check AWS Load Balancer Controller is running
kubectl get deployment -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Install AWS Load Balancer Controller if missing
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=demo-pre-prod-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Check subnet tags for ALB discovery
aws ec2 describe-subnets \
  --filters "Name=tag:kubernetes.io/cluster/demo-pre-prod-cluster,Values=owned,shared" \
  --query 'Subnets[*].[SubnetId,Tags[?Key==`kubernetes.io/role/elb`].Value]'
```

### ALB Not Provisioning

**Symptoms:**
- Ingress created but ALB stuck in provisioning
- Ingress ADDRESS remains empty after 5+ minutes

**Diagnosis:**

```bash
# Check events for the ingress
kubectl describe ingress -n devops-agent-demo | grep -A20 Events

# Check controller logs for errors
kubectl logs -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --tail=100

# Check TargetGroup health
aws elbv2 describe-target-groups \
  --query 'TargetGroups[?contains(TargetGroupName, `devops-agent`)]'
```

**Common Issues:**

1. **Subnet not found:**
   ```bash
   # Ensure subnets are tagged for ALB
   # For internet-facing ALB (public subnets):
   aws ec2 create-tags --resources subnet-xxx --tags Key=kubernetes.io/role/elb,Value=1

   # For internal ALB (private subnets):
   aws ec2 create-tags --resources subnet-xxx --tags Key=kubernetes.io/role/internal-elb,Value=1
   ```

2. **Security group restrictions:**
   ```bash
   # Check security groups allow ingress
   aws ec2 describe-security-groups --group-ids sg-xxx \
     --query 'SecurityGroups[*].IpPermissions'
   ```

3. **IAM permissions missing:**
   ```bash
   # Verify controller has required permissions
   kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn
   ```

### ALB Target Health Failing

**Symptoms:**
- ALB created but targets show unhealthy
- 502/503 errors when accessing the application

**Diagnosis:**

```bash
# Get Target Group ARN
TG_ARN=$(aws elbv2 describe-target-groups \
  --query 'TargetGroups[?contains(TargetGroupName, `devops-agent`)].TargetGroupArn' \
  --output text)

# Check target health
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

**Solutions:**

```bash
# 1. Verify health check path exists
kubectl exec -it deployment/web-ui -n devops-agent-demo -- curl localhost:3000/health

# 2. Check health check configuration in ingress
kubectl get ingress -n devops-agent-demo -o yaml | grep healthcheck

# 3. Verify security groups allow ALB to reach pods
# - ALB security group needs egress to node security group
# - Node security group needs ingress from ALB security group

# 4. Check if pods are ready
kubectl get pods -n devops-agent-demo -o wide | grep -v Running
```

### Ingress Issues When No Domain is Configured

**Problem:** You want to access the application but don't have a domain name configured.

**Solution 1 - Use Path-Based Routing (`dev-no-domain` overlay):**

```bash
# Deploy using the dev-no-domain overlay
kubectl apply -k overlays/dev-no-domain

# Wait for ALB to be provisioned (2-5 minutes)
kubectl get ingress -n devops-agent-demo -w

# Get the ALB DNS name
ALB_DNS=$(kubectl get ingress -n devops-agent-demo \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "Access the application at: http://$ALB_DNS"

# Access paths:
# - Web UI:          http://<ALB_DNS>/
# - Admin Dashboard: http://<ALB_DNS>/admin/
# - API Gateway:     http://<ALB_DNS>/api/
```

**Solution 2 - Use Port Forward (`dev-port-forward` overlay):**

```bash
# Deploy without ingress
kubectl apply -k overlays/dev-port-forward

# Forward ports locally
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo &
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo &
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo &

# Access at localhost
curl http://localhost:3000/health
curl http://localhost:8080/health
```

### Path-Based Routing Not Working

**Symptoms:**
- ALB returns 404 for paths like `/api` or `/admin`
- Only root path `/` works

**Diagnosis:**

```bash
# Check ingress path configuration
kubectl get ingress -n devops-agent-demo -o yaml | grep -A20 "rules:"

# Verify services exist
kubectl get svc -n devops-agent-demo
```

**Solutions:**

```bash
# 1. Ensure path order is correct (more specific paths first)
# In ingress-patch.yaml:
#   - /api (first)
#   - /admin (second)
#   - / (last, catch-all)

# 2. Check if applications handle path prefixes
# Some apps need BASE_PATH configuration
kubectl get configmap common-config -n devops-agent-demo -o yaml

# 3. Verify target services are healthy
kubectl get endpoints -n devops-agent-demo
```

## Port-Forward Issues

### Port-Forward Connection Refused

**Symptoms:**
- `kubectl port-forward` runs but connection is refused
- `curl localhost:<port>` fails

**Diagnosis:**

```bash
# Check if pod is running
kubectl get pods -n devops-agent-demo

# Check if service exists and has endpoints
kubectl get svc -n devops-agent-demo
kubectl get endpoints -n devops-agent-demo
```

**Solutions:**

```bash
# 1. Ensure pod is ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=web-ui -n devops-agent-demo --timeout=60s

# 2. Forward to correct service port
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo

# 3. Try forwarding directly to pod
POD=$(kubectl get pods -l app.kubernetes.io/name=web-ui -n devops-agent-demo -o name | head -1)
kubectl port-forward $POD 3000:3000 -n devops-agent-demo

# 4. Check container port
kubectl get pod -l app.kubernetes.io/name=web-ui -n devops-agent-demo -o jsonpath='{.items[0].spec.containers[*].ports[*].containerPort}'
```

### Port-Forward Disconnects

**Symptoms:**
- Port-forward works initially but disconnects after some time
- "lost connection to pod" error

**Solutions:**

```bash
# 1. Use a wrapper script to auto-reconnect
while true; do
  kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo
  echo "Connection lost, reconnecting..."
  sleep 1
done

# 2. Keep-alive with address binding
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo --address='0.0.0.0'

# 3. Check pod stability
kubectl get pods -n devops-agent-demo -w
```

### Multiple Services Port-Forward

**Managing multiple port-forwards:**

```bash
# Start all in background
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo &
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo &
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo &

# List background jobs
jobs

# Stop all port-forwards
killall kubectl

# Or use a script
cat > port-forward.sh << 'EOF'
#!/bin/bash
trap 'kill $(jobs -p)' EXIT
kubectl port-forward svc/dev-web-ui 3000:3000 -n devops-agent-demo &
kubectl port-forward svc/dev-admin-dashboard 3001:3001 -n devops-agent-demo &
kubectl port-forward svc/dev-api-gateway 8080:8080 -n devops-agent-demo &
wait
EOF
chmod +x port-forward.sh
./port-forward.sh
```

## Database Connectivity Issues

### Cannot Connect to RDS

**Symptoms:**
- Application fails to connect to database
- Connection timeout or refused

**Diagnosis:**

```bash
# Check if db-proxy pod is running
kubectl get pods -l app.kubernetes.io/name=db-proxy -n devops-agent-demo

# Check db-proxy logs
kubectl logs deployment/db-proxy -n devops-agent-demo

# Verify database secret is mounted
kubectl exec deployment/db-proxy -n devops-agent-demo -- env | grep DB_
```

**Common Causes and Solutions:**

| Cause | Solution |
|-------|----------|
| Security group blocking | Add EKS node security group to RDS ingress |
| Wrong credentials | Verify ExternalSecret is syncing correctly |
| VPC/subnet issues | Ensure pods can reach RDS subnet |
| Wrong endpoint | Verify DB_HOST value matches RDS endpoint |

```bash
# Test connectivity from a pod
kubectl run db-test --rm -it --image=postgres:15 -n devops-agent-demo -- \
  psql "postgresql://$(kubectl get secret database-credentials -n devops-agent-demo -o jsonpath='{.data.DB_USER}' | base64 -d):$(kubectl get secret database-credentials -n devops-agent-demo -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)@$(kubectl get secret database-credentials -n devops-agent-demo -o jsonpath='{.data.DB_HOST}' | base64 -d):5432/devops_agent_demo" -c "SELECT 1"

# Check RDS security group
aws rds describe-db-instances --db-instance-identifier demo-pre-prod-postgres \
  --query 'DBInstances[0].VpcSecurityGroups'
```

## Redis Connectivity Issues

### Cannot Connect to ElastiCache Redis

**Symptoms:**
- Application fails to connect to Redis
- Connection timeout to Redis endpoint

**Diagnosis:**

```bash
# Check if cache-manager pod is running
kubectl get pods -l app.kubernetes.io/name=cache-manager -n devops-agent-demo

# Check cache-manager logs
kubectl logs deployment/cache-manager -n devops-agent-demo

# Verify Redis secret is mounted
kubectl exec deployment/cache-manager -n devops-agent-demo -- env | grep REDIS_
```

**Common Causes and Solutions:**

| Cause | Solution |
|-------|----------|
| Security group blocking | Add EKS node security group to Redis ingress |
| Wrong credentials | Verify redis-credentials-external is syncing |
| VPC/subnet issues | Ensure pods can reach ElastiCache subnet |
| Wrong endpoint | Verify REDIS_HOST matches ElastiCache endpoint |
| TLS issues | Use `rediss://` for TLS connections |

```bash
# Test Redis connectivity
kubectl run redis-test --rm -it --image=redis:7 -n devops-agent-demo -- \
  redis-cli -h master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com -p 6379 PING

# Check ElastiCache security group
aws elasticache describe-replication-groups --replication-group-id demo-pre-prod-redis \
  --query 'ReplicationGroups[0].SecurityGroups'

# Verify Redis secret values
kubectl get secret redis-credentials -n devops-agent-demo -o jsonpath='{.data.REDIS_HOST}' | base64 -d
kubectl get secret redis-credentials -n devops-agent-demo -o jsonpath='{.data.REDIS_URL}' | base64 -d
```

### Redis TLS Connection Issues

```bash
# If using TLS (rediss://), ensure the connection uses TLS
kubectl run redis-tls-test --rm -it --image=redis:7 -n devops-agent-demo -- \
  redis-cli -h master.demo-pre-prod-redis.wfksw8.use1.cache.amazonaws.com -p 6379 --tls PING

# Check if REDIS_URL uses rediss:// (TLS) or redis:// (non-TLS)
kubectl get secret redis-credentials -n devops-agent-demo -o jsonpath='{.data.REDIS_URL}' | base64 -d
```

## Resource Issues

### HPA Not Scaling

**Symptoms:**
- HPA shows `unknown` for metrics
- Pods not scaling despite load

**Diagnosis:**

```bash
# Check HPA status
kubectl get hpa -n devops-agent-demo
kubectl describe hpa <hpa-name> -n devops-agent-demo

# Check metrics-server
kubectl get pods -n kube-system | grep metrics-server
kubectl top pods -n devops-agent-demo
```

**Solutions:**

1. **Install metrics-server:**
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
   ```

2. **Verify resource requests are set:**
   ```yaml
   resources:
     requests:
       cpu: "100m"    # Required for CPU-based HPA
       memory: "128Mi"
   ```

### Evicted Pods

**Symptoms:**
- Pods show `Evicted` status
- DiskPressure or MemoryPressure on nodes

**Diagnosis:**

```bash
# Check node conditions
kubectl describe nodes | grep -A 5 "Conditions"

# Check evicted pods
kubectl get pods -n devops-agent-demo --field-selector=status.phase=Failed
```

**Solutions:**

1. **Clean up disk space:**
   - Remove unused images
   - Clear log files
   - Increase node disk size

2. **Increase memory:**
   - Add more nodes
   - Use larger instance types

3. **Delete evicted pods:**
   ```bash
   kubectl delete pods -n devops-agent-demo --field-selector=status.phase=Failed
   ```

## IRSA Issues

### Pod Cannot Assume IAM Role

**Symptoms:**
- AWS SDK returns "Access Denied"
- "Unable to locate credentials" errors

**Diagnosis:**

```bash
# Check ServiceAccount annotation
kubectl get sa <sa-name> -n devops-agent-demo -o yaml

# Check pod uses correct ServiceAccount
kubectl get pod <pod-name> -n devops-agent-demo -o jsonpath='{.spec.serviceAccountName}'

# Check AWS web identity token is mounted
kubectl exec <pod-name> -n devops-agent-demo -- ls -la /var/run/secrets/eks.amazonaws.com/serviceaccount/
```

**Solutions:**

1. **Restart pod after IRSA changes:**
   ```bash
   kubectl rollout restart deployment/<name> -n devops-agent-demo
   ```

2. **Verify environment variables:**
   ```bash
   kubectl exec <pod-name> -n devops-agent-demo -- env | grep AWS
   # Should show AWS_WEB_IDENTITY_TOKEN_FILE and AWS_ROLE_ARN
   ```

3. **Test credentials:**
   ```bash
   kubectl exec <pod-name> -n devops-agent-demo -- aws sts get-caller-identity
   ```

## NGINX Frontend Issues

### NGINX Config Template Not Processing

**Symptoms:**
- web-ui or admin-dashboard returns 502 errors
- NGINX cannot connect to upstream

**Diagnosis:**

```bash
# Check NGINX config
kubectl exec deployment/web-ui -n devops-agent-demo -- cat /etc/nginx/conf.d/default.conf

# Check environment variable
kubectl exec deployment/web-ui -n devops-agent-demo -- env | grep API_GATEWAY

# Check template file exists
kubectl exec deployment/web-ui -n devops-agent-demo -- cat /templates/default.conf.template
```

**Solutions:**

1. **Verify API_GATEWAY_HOST is set:**
   ```bash
   kubectl get deployment web-ui -n devops-agent-demo -o yaml | grep -A2 API_GATEWAY_HOST
   ```

2. **Check docker-entrypoint.sh runs envsubst:**
   ```bash
   kubectl exec deployment/web-ui -n devops-agent-demo -- cat /docker-entrypoint.sh
   ```

3. **Verify writable config volume:**
   ```bash
   kubectl get deployment web-ui -n devops-agent-demo -o yaml | grep -A5 volumeMounts
   ```

### NGINX Cannot Write to Config Directory

**Symptoms:**
```
nginx: [emerg] open() "/etc/nginx/conf.d/default.conf" failed (30: Read-only file system)
```

**Solution:**

Ensure EmptyDir volume is mounted at `/etc/nginx/conf.d`:

```yaml
spec:
  containers:
    - name: web-ui
      volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
  volumes:
    - name: nginx-config
      emptyDir: {}
```

### NGINX Upstream Connection Refused

**Symptoms:**
```
connect() failed (111: Connection refused) while connecting to upstream
```

**Diagnosis:**

```bash
# Check if api-gateway is running
kubectl get pods -l app.kubernetes.io/name=api-gateway -n devops-agent-demo

# Check if api-gateway service exists
kubectl get svc api-gateway -n devops-agent-demo

# Test connectivity from NGINX pod
kubectl exec deployment/web-ui -n devops-agent-demo -- wget -O- http://api-gateway:8080/health
```

**Solutions:**

1. **Verify API Gateway is healthy:**
   ```bash
   kubectl describe pod -l app.kubernetes.io/name=api-gateway -n devops-agent-demo
   ```

2. **Check API_GATEWAY_HOST value:**
   - Should be `api-gateway` (service name) for Kubernetes DNS
   - Not the full FQDN unless necessary

3. **Check NetworkPolicy allows traffic:**
   ```bash
   kubectl get networkpolicy -n devops-agent-demo
   ```

## ArgoCD Issues

### Application Not Syncing

**Symptoms:**
- Application shows `OutOfSync` status
- Sync errors in ArgoCD UI
- Resources not being deployed

**Diagnosis:**

```bash
# Check application status
kubectl get applications -n argocd
kubectl describe application devops-agent-demo-dev -n argocd

# Check application controller logs
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=100

# Check repo-server logs
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd --tail=100

# Get sync status via CLI
argocd app get devops-agent-demo-dev
```

**Common Causes and Solutions:**

| Cause | Solution |
|-------|----------|
| Repository access denied | Check GitHub SSH key ExternalSecret |
| Invalid manifests | Run `kubectl kustomize overlays/dev-no-domain` locally |
| Resource conflicts | Check for resources managed by multiple sources |
| Webhook not triggering | Wait for polling (3 minutes) or configure webhook |

### Repository Connection Failed

**Symptoms:**
- `rpc error: code = Unknown desc = error creating SSH agent`
- `Permission denied (publickey)`
- ArgoCD cannot clone repository

**Diagnosis:**

```bash
# Check repository secret exists
kubectl get secret github-repo-creds -n argocd

# Check ExternalSecret status
kubectl describe externalsecret github-ssh-key -n argocd

# Check repo-server logs
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd | grep -i error

# Test repository connection
argocd repo list
argocd repo get git@github.com:your-org/devops-agent-k8s-demo.git
```

**Solutions:**

```bash
# 1. Verify SSH key secret is synced
kubectl get externalsecret github-ssh-key -n argocd

# 2. Check secret contents (should have sshPrivateKey)
kubectl get secret github-repo-creds -n argocd -o jsonpath='{.data}' | jq .

# 3. Force refresh the ExternalSecret
kubectl annotate externalsecret github-ssh-key -n argocd force-sync=$(date +%s) --overwrite

# 4. Check AWS secret exists
aws secretsmanager get-secret-value --secret-id argocd/github-ssh-key --region us-east-1

# 5. Restart repo-server if needed
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### ArgoCD ExternalSecrets Not Syncing

**Symptoms:**
- SecretStore shows `Valid: False`
- ExternalSecret shows `SecretSyncedError`
- ArgoCD secrets not created

**Diagnosis:**

```bash
# Check ArgoCD SecretStore status
kubectl get secretstore -n argocd
kubectl describe secretstore argocd-aws-secrets-manager -n argocd

# Check ExternalSecrets status
kubectl get externalsecret -n argocd
kubectl describe externalsecret github-ssh-key -n argocd
kubectl describe externalsecret argocd-redis -n argocd

# Check ServiceAccount IRSA annotation
kubectl get sa external-secrets-sa -n argocd -o yaml | grep role-arn
```

**Solutions:**

```bash
# 1. Verify IRSA is configured correctly
kubectl get sa external-secrets-sa -n argocd -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# Expected: arn:aws:iam::852140462703:role/ArgoCD-ExternalSecrets-Role

# 2. Test AWS credentials from argocd namespace
kubectl run aws-test --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n argocd \
  -- secretsmanager get-secret-value --secret-id argocd/github-ssh-key --region us-east-1

# 3. Verify IAM role trust policy includes argocd namespace
aws iam get-role --role-name ArgoCD-ExternalSecrets-Role \
  --query 'Role.AssumeRolePolicyDocument'
# Should contain: system:serviceaccount:argocd:external-secrets-sa

# 4. Force refresh ExternalSecrets
kubectl annotate externalsecret github-ssh-key -n argocd force-sync=$(date +%s) --overwrite
kubectl annotate externalsecret argocd-redis -n argocd force-sync=$(date +%s) --overwrite
```

### ArgoCD UI Not Accessible

**Symptoms:**
- Cannot reach ArgoCD URL
- ALB returns 502/503 errors
- Connection timeout

**Diagnosis:**

```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# Check argocd-server pod specifically
kubectl describe pod -l app.kubernetes.io/name=argocd-server -n argocd

# Check ingress status
kubectl get ingress argocd-ingress -n argocd
kubectl describe ingress argocd-ingress -n argocd

# Check ALB controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

**Solutions:**

```bash
# 1. Verify ArgoCD server is running
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# 2. Check CIDR whitelist includes your IP
kubectl get configmap allowed-cidrs -n devops-agent-demo -o yaml
# Verify your IP is in the cidrs value

# 3. Check ALB target group health
ALB_ARN=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `argocd`)].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn $ALB_ARN --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# 4. Restart ArgoCD server if needed
kubectl rollout restart deployment argocd-server -n argocd
```

### Self-Heal Not Working

**Symptoms:**
- Manual changes to resources persist
- ArgoCD not correcting drift
- Application shows Synced but resources differ

**Diagnosis:**

```bash
# Check if self-heal is enabled
kubectl get application devops-agent-demo-dev -n argocd -o jsonpath='{.spec.syncPolicy.automated.selfHeal}'
# Should return: true

# Check application controller logs for heal events
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd | grep -i heal

# Check app refresh status
argocd app get devops-agent-demo-dev
```

**Solutions:**

```bash
# 1. Verify sync policy in application manifest
kubectl get application devops-agent-demo-dev -n argocd -o yaml | grep -A5 "syncPolicy"

# 2. Force hard refresh
argocd app refresh devops-agent-demo-dev --hard

# 3. Force sync if needed
argocd app sync devops-agent-demo-dev --force

# 4. Check if there are sync hooks preventing heal
kubectl get application devops-agent-demo-dev -n argocd -o jsonpath='{.status.operationState}'
```

### ArgoCD Redis Connection Issues

**Symptoms:**
- ArgoCD components failing to start
- `NOAUTH Authentication required` errors
- ArgoCD server cannot connect to cache

**Diagnosis:**

```bash
# Check Redis pod
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-redis

# Check Redis secret exists
kubectl get secret argocd-redis -n argocd

# Check ExternalSecret status
kubectl describe externalsecret argocd-redis -n argocd

# Check argocd-server logs for Redis errors
kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd | grep -i redis
```

**Solutions:**

```bash
# 1. Verify Redis secret has correct key
kubectl get secret argocd-redis -n argocd -o jsonpath='{.data.auth}' | base64 -d

# 2. Force refresh Redis secret
kubectl annotate externalsecret argocd-redis -n argocd force-sync=$(date +%s) --overwrite

# 3. Restart ArgoCD Redis
kubectl rollout restart deployment argocd-redis -n argocd

# 4. Restart ArgoCD server to pick up new Redis password
kubectl rollout restart deployment argocd-server -n argocd
```

### Application Sync Stuck in Progressing

**Symptoms:**
- Application shows `Progressing` status indefinitely
- Some resources not becoming healthy

**Diagnosis:**

```bash
# Check application status
argocd app get devops-agent-demo-dev

# Check which resources are not healthy
argocd app resources devops-agent-demo-dev

# Check events in the application namespace
kubectl get events -n devops-agent-demo --sort-by='.lastTimestamp' | tail -20
```

**Solutions:**

```bash
# 1. Check specific unhealthy resources
kubectl describe deployment <name> -n devops-agent-demo

# 2. Check if pods are stuck
kubectl get pods -n devops-agent-demo | grep -v Running

# 3. Terminate stuck sync operation
argocd app terminate-op devops-agent-demo-dev

# 4. Force sync with replace
argocd app sync devops-agent-demo-dev --force --replace
```

### ArgoCD Getting Initial Admin Password

**Common Task:**

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

# Login via CLI
argocd login <ALB_DNS> --username admin --password <password> --insecure

# Change password
argocd account update-password
```

### ArgoCD Debugging Commands

```bash
# Application status
argocd app list
argocd app get devops-agent-demo-dev
argocd app history devops-agent-demo-dev

# Sync operations
argocd app sync devops-agent-demo-dev --dry-run
argocd app sync devops-agent-demo-dev --prune
argocd app diff devops-agent-demo-dev

# Repository operations
argocd repo list
argocd repo rm git@github.com:your-org/devops-agent-k8s-demo.git
argocd repo add git@github.com:your-org/devops-agent-k8s-demo.git --ssh-private-key-path ~/.ssh/id_rsa

# Cluster operations
argocd cluster list
argocd cluster get https://kubernetes.default.svc

# Logs
kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd --tail=50
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd --tail=50
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=50
```

## Debugging Commands Reference

### Quick Diagnostics

```bash
# Cluster overview
kubectl get nodes
kubectl get pods --all-namespaces | grep -v Running

# Namespace resources
kubectl get all -n devops-agent-demo
kubectl get events -n devops-agent-demo --sort-by='.lastTimestamp' | tail -20

# Pod details
kubectl describe pod <pod-name> -n devops-agent-demo
kubectl logs <pod-name> -n devops-agent-demo --tail=100
kubectl logs <pod-name> -n devops-agent-demo --previous

# Interactive debugging
kubectl exec -it <pod-name> -n devops-agent-demo -- /bin/sh
kubectl debug <pod-name> -n devops-agent-demo --image=busybox -it
```

### Network Debugging

```bash
# DNS test
kubectl run debug --rm -it --image=busybox -n devops-agent-demo -- nslookup kubernetes

# HTTP test
kubectl run debug --rm -it --image=curlimages/curl -n devops-agent-demo -- curl -v http://api-gateway:8080/health

# Port connectivity
kubectl run debug --rm -it --image=busybox -n devops-agent-demo -- nc -zv api-gateway 8080
```

### AWS Debugging

```bash
# Test IRSA from pod
kubectl run aws-debug --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"processing-sa"}}' \
  -n devops-agent-demo \
  -- sts get-caller-identity

# Test Secrets Manager access (database)
kubectl run aws-debug --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n devops-agent-demo \
  -- secretsmanager get-secret-value --secret-id demo/pre-prod/database --region us-east-1

# Test Secrets Manager access (redis)
kubectl run aws-debug --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"external-secrets-sa"}}' \
  -n devops-agent-demo \
  -- secretsmanager get-secret-value --secret-id demo/pre-prod/redis --region us-east-1

# Test S3 access
kubectl run aws-debug --rm -it \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"processing-sa"}}' \
  -n devops-agent-demo \
  -- s3 ls s3://devops-agent-images-pre-prod/
```

### External Secrets Debugging

```bash
# Check operator
kubectl get pods -n external-secrets
kubectl logs -l app.kubernetes.io/name=external-secrets -n external-secrets --tail=50

# Check resources (both database and redis)
kubectl get secretstore -n devops-agent-demo
kubectl get externalsecret -n devops-agent-demo
kubectl describe secretstore aws-secrets-manager -n devops-agent-demo
kubectl describe externalsecret database-credentials-external -n devops-agent-demo
kubectl describe externalsecret redis-credentials-external -n devops-agent-demo

# Force sync
kubectl annotate externalsecret database-credentials-external \
  -n devops-agent-demo \
  force-sync=$(date +%s) --overwrite

kubectl annotate externalsecret redis-credentials-external \
  -n devops-agent-demo \
  force-sync=$(date +%s) --overwrite
```

## Getting Help

If you cannot resolve an issue:

1. **Collect diagnostics:**
   ```bash
   # Export all resources
   kubectl get all -n devops-agent-demo -o yaml > diagnostics.yaml

   # Export events
   kubectl get events -n devops-agent-demo --sort-by='.lastTimestamp' > events.txt

   # Export logs from problematic pods
   kubectl logs deployment/<name> -n devops-agent-demo > pod-logs.txt
   ```

2. **Check AWS resources:**
   ```bash
   # Check ALB status
   aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `devops-agent`)]'

   # Check target group health
   aws elbv2 describe-target-health --target-group-arn <tg-arn>

   # Check CloudWatch logs
   aws logs filter-log-events --log-group-name /aws/eks/demo-pre-prod-cluster/cluster
   ```

3. **Review related documentation:**
   - [Architecture Documentation](./architecture.md)
   - [ArgoCD Setup](./argocd-setup.md)
   - [Secrets Management](./secrets-management.md)
   - [IAM Setup](./iam-setup.md)
   - [Deployment Guide](./deployment-guide.md)
