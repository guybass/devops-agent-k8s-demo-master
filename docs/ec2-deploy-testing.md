# EC2 Deploy Script Testing Guide

## Prerequisites (Run Once on EC2)

```bash
# EC2 uses IAM role - no manual key export needed!
# Just set the region:
export AWS_DEFAULT_REGION='us-east-2'

# Verify IAM role is working:
aws sts get-caller-identity

# Navigate to repo
cd ~/devops-agent-k8s-demo-master

# Make scripts executable
chmod +x scripts/ec2-deploy.sh scripts/get-alb-url.sh
```

---

## Phase 0: Verify Clean State (Nothing Deployed)

### Step 1: Connect to EKS cluster
```bash
./scripts/ec2-deploy.sh setup
```
Expected: "Connected to EKS cluster"

### Step 2: Check for namespaces
```bash
kubectl get namespaces | grep -E "argocd|devops-agent-demo"
```
**Clean state:** No output (empty) = nothing deployed

### Step 3: Check for pods
```bash
kubectl get pods -n devops-agent-demo
```
**Clean state:** `Error from server (NotFound): namespaces "devops-agent-demo" not found`

### Step 4: Check for ingress/ALB
```bash
./scripts/get-alb-url.sh
```
**Clean state:** `ALB_URL=NOT_READY`

### Or use the all-in-one status command:
```bash
./scripts/ec2-deploy.sh status
```

**Expected output for CLEAN Phase 0:**
```
=== Namespaces ===
No relevant namespaces found

=== Pods in devops-agent-demo ===
Namespace not found

=== Ingress ===
No ingress found
```

### Verification checklist for Phase 0:
- [ ] `kubectl get namespaces` shows NO `argocd` or `devops-agent-demo`
- [ ] `kubectl get pods -n devops-agent-demo` returns "not found"
- [ ] `./scripts/get-alb-url.sh` returns `NOT_READY`

---

## Phase 1: Deploy Web Application

### Commands to run:
```bash
# Option A: Deploy Phase 1 only (19 services, no notification-service)
./scripts/ec2-deploy.sh phase1

# Option B: Full deploy (teardown + phase1 + phase2 with notification-service)
./scripts/ec2-deploy.sh deploy
```

### Get ALB URL:
```bash
# Method 1: Using the get-alb-url script
./scripts/get-alb-url.sh

# Method 2: Using ec2-deploy.sh
./scripts/ec2-deploy.sh url

# Method 3: Direct kubectl (after kubeconfig is configured)
kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

### Expected output:
```
ALB_URL=http://k8s-devopsag-maininge-xxxxxxxx-xxxxxxxxx.us-east-2.elb.amazonaws.com
```

### Verification checklist:
- [ ] ALB URL is returned (not `NOT_READY`)
- [ ] URL is accessible in browser (may take 2-3 minutes for ALB to be fully healthy)
- [ ] `./scripts/ec2-deploy.sh status` shows pods in Running state

### Check pod status:
```bash
./scripts/ec2-deploy.sh status
# Or directly:
kubectl get pods -n devops-agent-demo
```

---

## Back to Phase 0: Teardown Everything

### Commands to run:
```bash
# Teardown all deployments
./scripts/ec2-deploy.sh teardown
```

### Expected output:
```
[INFO] Tearing down existing deployment...
[INFO] Waiting for namespaces to terminate...
[INFO] Teardown complete
```

### Verify teardown:
```bash
# Check status - should return to clean state
./scripts/ec2-deploy.sh status
```

### Verification checklist:
- [ ] `devops-agent-demo` namespace deleted
- [ ] `argocd` namespace deleted
- [ ] No pods running
- [ ] No ingress resources
- [ ] ALB URL no longer accessible

---

## Quick Command Summary

| Phase | Command | Purpose |
|-------|---------|---------|
| Setup | `./scripts/ec2-deploy.sh setup` | Configure kubectl for EKS |
| Phase 0 Check | `./scripts/ec2-deploy.sh status` | Verify clean state |
| Phase 1 Deploy | `./scripts/ec2-deploy.sh phase1` | Deploy 19 services |
| Full Deploy | `./scripts/ec2-deploy.sh deploy` | Teardown + Phase1 + Phase2 |
| Get URL | `./scripts/get-alb-url.sh` | Get ALB URL |
| Teardown | `./scripts/ec2-deploy.sh teardown` | Remove everything |

---

## Troubleshooting

### ALB URL shows NOT_READY
- Wait 1-2 minutes for ALB provisioning
- Run `./scripts/get-alb-url.sh` again

### Namespace stuck terminating
The script handles this automatically with finalizer removal. If still stuck:
```bash
kubectl get namespace devops-agent-demo -o json | sed 's/"finalizers": \[.*\]/"finalizers": []/' | kubectl replace --raw "/api/v1/namespaces/devops-agent-demo/finalize" -f -
```

### Cannot connect to cluster
```bash
# Re-run setup
./scripts/ec2-deploy.sh setup

# Verify AWS credentials
aws sts get-caller-identity
```
