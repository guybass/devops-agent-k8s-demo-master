# Demo Deployment Guide - One-Liner Commands

## Prerequisites
- AWS CLI configured with credentials
- kubectl installed
- kustomize installed
- Connected to EKS cluster:
  ```bash
  aws eks update-kubeconfig --region us-east-2 --name demo-pre-prod-cluster
  ```

---

## Step 1: Tear Down Everything

### 1.1 Remove ArgoCD finalizers and delete namespaces
```bash
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do kubectl patch $app -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge; done; kubectl patch appproject devops-agent-demo -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; kubectl delete namespace devops-agent-demo argocd --wait=false
```

### 1.2 Verify namespaces are gone (wait until empty)
```bash
kubectl get namespaces | grep -E "argocd|devops-agent-demo"
```

### 1.3 Force-delete stuck namespaces (only if stuck in Terminating)
```bash
kubectl get namespace devops-agent-demo -o json 2>/dev/null | sed 's/"finalizers": \[.*\]/"finalizers": []/' | kubectl replace --raw "/api/v1/namespaces/devops-agent-demo/finalize" -f - 2>/dev/null; kubectl get namespace argocd -o json 2>/dev/null | sed 's/"finalizers": \[.*\]/"finalizers": []/' | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f - 2>/dev/null; kubectl get namespaces | grep -E "argocd|devops-agent-demo"
```

---

## Step 2: Deploy Phase 1 (19 services, NO notification-service)

```bash
cd "/mnt/c/Users/Lenovo i7/Desktop/my_personal_projects/devops-agent-k8s-demo-master" && kustomize build --load-restrictor=LoadRestrictionsNone overlays/dev-no-domain-phase1/ > /tmp/phase1-rendered.yaml && kubectl apply -f /tmp/phase1-rendered.yaml --server-side --force-conflicts
```

### Verify Phase 1 (should show 19 pods, NO notification-service)
```bash
kubectl get pods -n devops-agent-demo
```

---

## Step 3: Get Application URL

```bash
kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' && echo ""
```

Wait ~1-2 minutes for ALB to register targets, then open URL in browser.

---

## Step 4: Deploy Phase 2 (notification-service)

```bash
kustomize build --load-restrictor=LoadRestrictionsNone overlays/dev-no-domain-phase2/ > /tmp/phase2-rendered.yaml && kubectl apply -f /tmp/phase2-rendered.yaml --server-side --force-conflicts && sleep 15 && kubectl get pods -n devops-agent-demo | grep notification
```

### Verify Phase 2 (should show 20 pods total)
```bash
kubectl get pods -n devops-agent-demo
```

---

## Quick Status Checks

### Check all pods
```bash
kubectl get pods -n devops-agent-demo
```

### Check ingress and URL
```bash
kubectl get ingress -n devops-agent-demo
```

### Check your IP is allowed
```bash
curl -s ifconfig.me && echo "" && kubectl describe ingress dev-devops-agent-demo-ingress -n devops-agent-demo | grep inbound-cidrs
```

### Check services
```bash
kubectl get svc -n devops-agent-demo
```

---

---

## How to Verify Notification Service is Working

### Before Phase 2 (19 pods):
- Admin Dashboard → System Health → notification-service shows **unhealthy/missing**

### After Phase 2 (20 pods):
1. **Admin Dashboard → System Health** → notification-service shows **healthy** (green, ~25ms latency)
2. **Admin Dashboard → Message Queues** → See `notifications.email` and `notifications.sms` queues with message counts
3. **API Endpoint:** `GET <URL>/api/notifications/stats` → Shows sent/pending/failed counts

### User Actions That Trigger Notifications:
- User registration → Welcome email
- Order creation → Order confirmation email
- Order ships → Shipping notification
- Payment fails → Payment failed email

---

## Troubleshooting

### If pods show CreateContainerConfigError
Check if ConfigMap/Secret references have `dev-` prefix:
```bash
kubectl describe pod <pod-name> -n devops-agent-demo | tail -30
```

### If website times out
1. Check your IP is in the allowed CIDRs
2. Check ALB target health in AWS Console
3. Wait for ALB to register targets (~1-2 min)

### If namespace stuck in Terminating
Use the force-delete command from Step 1.3
