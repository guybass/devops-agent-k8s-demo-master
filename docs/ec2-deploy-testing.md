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

### Connect to EKS cluster and check status:
```bash
./scripts/ec2-deploy.sh setup
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
- [ ] No `argocd` or `devops-agent-demo` namespaces
- [ ] No pods running
- [ ] `./scripts/get-alb-url.sh` returns `NOT_READY`

---

## Deploy: All 20 Services

### Command:
```bash
./scripts/ec2-deploy.sh deploy
```

This performs: teardown (if needed) -> deploy all 20 services

### Get ALB URL:
```bash
./scripts/get-alb-url.sh
# or
./scripts/ec2-deploy.sh url
```

### Expected output:
```
ALB_URL=http://k8s-devopsag-devdevop-xxxxxxxx-xxxxxxxxx.us-east-2.elb.amazonaws.com
```

### Verification checklist:
- [ ] ALB URL is returned (not `NOT_READY`)
- [ ] URL is accessible in browser (may take 2-3 minutes for ALB to be healthy)
- [ ] `./scripts/ec2-deploy.sh status` shows 20 pods in Running state

---

## Back to Phase 0: Teardown Everything

### Command:
```bash
./scripts/ec2-deploy.sh teardown
```

### Expected output:
```
[INFO] Tearing down existing deployment...
[INFO] Waiting for namespaces to terminate...
[INFO] Teardown complete
```

### Verify clean state:
```bash
./scripts/ec2-deploy.sh status
```

### Verification checklist:
- [ ] `devops-agent-demo` namespace deleted
- [ ] `argocd` namespace deleted
- [ ] No pods running
- [ ] No ingress resources

---

## Quick Command Summary

| Command | Purpose |
|---------|---------|
| `./scripts/ec2-deploy.sh setup` | Configure kubectl for EKS |
| `./scripts/ec2-deploy.sh status` | Check current state |
| `./scripts/ec2-deploy.sh deploy` | Deploy all 20 services |
| `./scripts/ec2-deploy.sh url` | Get ALB URL |
| `./scripts/ec2-deploy.sh teardown` | Back to Phase 0 (clean state) |
| `./scripts/get-alb-url.sh` | Get ALB URL (standalone) |

---

## Troubleshooting

### ALB URL shows NOT_READY
- Wait 1-2 minutes for ALB provisioning
- Run `./scripts/get-alb-url.sh` again

### Namespace stuck terminating
The script handles this automatically. If still stuck:
```bash
# Remove targetgroupbinding finalizers
for tgb in $(kubectl get targetgroupbindings -n devops-agent-demo -o name); do kubectl patch $tgb -n devops-agent-demo -p '{"metadata":{"finalizers":[]}}' --type=merge; done

# Force delete namespace
kubectl get namespace devops-agent-demo -o json | sed 's/"finalizers": \[.*\]/"finalizers": []/' | kubectl replace --raw "/api/v1/namespaces/devops-agent-demo/finalize" -f -
```

### Cannot connect to cluster
```bash
./scripts/ec2-deploy.sh setup
aws sts get-caller-identity
```
