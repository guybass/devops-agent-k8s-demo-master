#!/bin/bash
#
# EKS Deployment Script for EC2
# Run from: ~/devops-agent-k8s-demo-master
# EC2 uses IAM role - no manual key export needed! Just set AWS_DEFAULT_REGION.
#

set -e

# Configuration
CLUSTER_NAME="devops-agent-demo-cluster"
REGION="${AWS_DEFAULT_REGION:-us-east-2}"
REPO_PATH="$HOME/devops-agent-k8s-demo-master"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not installed"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl not found. Installing..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi

    # Check kustomize
    if ! command -v kustomize &> /dev/null; then
        log_warn "kustomize not found. Installing..."
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        sudo mv kustomize /usr/local/bin/
    fi

    # Verify AWS identity (works with IAM role or explicit credentials)
    log_info "Verifying AWS identity..."
    if ! aws sts get-caller-identity; then
        log_error "AWS authentication failed. On EC2, ensure the instance has an IAM role attached."
        log_error "Or export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        exit 1
    fi

    log_info "Prerequisites OK"
}

# Configure kubectl for EKS
configure_kubeconfig() {
    log_info "Configuring kubectl for EKS cluster: $CLUSTER_NAME"
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

    log_info "Testing cluster connection..."
    kubectl cluster-info || { log_error "Cannot connect to cluster"; exit 1; }
    log_info "Connected to EKS cluster"
}

# Teardown existing deployment
teardown() {
    log_info "Tearing down existing deployment..."

    # Remove ArgoCD finalizers
    for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
        kubectl patch $app -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
    kubectl patch appproject devops-agent-demo -n argocd -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true

    # Delete namespaces
    kubectl delete namespace devops-agent-demo --wait=false 2>/dev/null || true
    kubectl delete namespace argocd --wait=false 2>/dev/null || true

    # Wait for cleanup
    log_info "Waiting for namespaces to terminate..."
    sleep 10

    # Force delete if stuck
    for ns in argocd devops-agent-demo; do
        if kubectl get namespace $ns &>/dev/null; then
            log_warn "Force-deleting stuck namespace: $ns"
            kubectl get namespace $ns -o json | sed 's/"finalizers": \[.*\]/"finalizers": []/' > /tmp/${ns}-ns.json
            kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f /tmp/${ns}-ns.json 2>/dev/null || true
        fi
    done

    # Verify clean
    if kubectl get namespaces | grep -qE "argocd|devops-agent-demo"; then
        log_warn "Namespaces still exist, waiting..."
        sleep 10
    fi

    log_info "Teardown complete"
}

# Deploy Phase 1
deploy_phase1() {
    log_info "Deploying Phase 1 (19 services, no notification-service)..."

    cd "$REPO_PATH"
    kustomize build --load-restrictor=LoadRestrictionsNone overlays/dev-no-domain-phase1/ > /tmp/phase1-rendered.yaml
    kubectl apply -f /tmp/phase1-rendered.yaml --server-side --force-conflicts

    log_info "Waiting for pods to start..."
    sleep 20

    log_info "Phase 1 pods:"
    kubectl get pods -n devops-agent-demo

    POD_COUNT=$(kubectl get pods -n devops-agent-demo --no-headers 2>/dev/null | wc -l)
    log_info "Phase 1 deployed: $POD_COUNT pods"
}

# Deploy Phase 2
deploy_phase2() {
    log_info "Deploying Phase 2 (adding notification-service)..."

    cd "$REPO_PATH"
    kustomize build --load-restrictor=LoadRestrictionsNone overlays/dev-no-domain-phase2/ > /tmp/phase2-rendered.yaml
    kubectl apply -f /tmp/phase2-rendered.yaml --server-side --force-conflicts

    log_info "Waiting for notification-service to start..."
    sleep 15

    log_info "Notification service status:"
    kubectl get pods -n devops-agent-demo | grep notification

    POD_COUNT=$(kubectl get pods -n devops-agent-demo --no-headers 2>/dev/null | wc -l)
    log_info "Phase 2 deployed: $POD_COUNT pods total"
}

# Get ingress URL
get_url() {
    log_info "Getting ingress URL..."
    URL=$(kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

    if [[ -n "$URL" ]]; then
        echo ""
        echo "=============================================="
        echo -e "${GREEN}Application URL:${NC}"
        echo "http://$URL"
        echo "=============================================="
        echo ""
    else
        log_warn "Ingress URL not yet available. Check again in a few minutes."
    fi
}

# Wait for ALB and display URL prominently
wait_for_alb() {
    log_info "Waiting for ALB to be ready..."
    local max_attempts=30
    local attempt=1
    local URL=""

    while [[ $attempt -le $max_attempts ]]; do
        URL=$(kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [[ -n "$URL" ]]; then
            break
        fi
        echo -n "."
        sleep 5
        ((attempt++))
    done
    echo ""

    if [[ -n "$URL" ]]; then
        print_alb_banner "$URL"
    else
        log_warn "ALB URL not available yet. Run '$0 url' to check later."
    fi
}

# Print ALB URL banner
print_alb_banner() {
    local URL="$1"
    local CYAN='\033[0;36m'
    local BOLD='\033[1m'

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                                                                              ║${NC}"
    echo -e "${BOLD}║${NC}  ${GREEN}✓ DEPLOYMENT COMPLETE${NC}                                                      ${BOLD}║${NC}"
    echo -e "${BOLD}║                                                                              ║${NC}"
    echo -e "${BOLD}║${NC}  ${CYAN}ALB URL:${NC}                                                                    ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${YELLOW}http://${URL}${NC}"
    echo -e "${BOLD}║                                                                              ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Copy this URL to access your application in a browser."
    echo ""

    # Also output just the URL for easy copying/parsing
    echo "ALB_URL=http://$URL"
}

# Show status
status() {
    log_info "Cluster status:"
    echo ""
    echo "=== Namespaces ==="
    kubectl get namespaces | grep -E "argocd|devops-agent-demo|external-secrets" || echo "No relevant namespaces found"
    echo ""
    echo "=== Pods in devops-agent-demo ==="
    kubectl get pods -n devops-agent-demo 2>/dev/null || echo "Namespace not found"
    echo ""
    echo "=== Ingress ==="
    kubectl get ingress -n devops-agent-demo 2>/dev/null || echo "No ingress found"
}

# Full deployment (no prompts)
full_deploy() {
    check_prerequisites
    configure_kubeconfig
    teardown
    deploy_phase1
    deploy_phase2

    # Final summary with ALB URL
    echo ""
    log_info "Deployment complete!"
    echo "ALB_URL=http://$(kubectl get ingress -n devops-agent-demo -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')"
}

# Help
show_help() {
    echo "EKS Deployment Script"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup       - Check prerequisites and configure kubectl"
    echo "  teardown    - Remove existing deployment"
    echo "  phase1      - Deploy Phase 1 (19 services)"
    echo "  phase2      - Deploy Phase 2 (add notification-service)"
    echo "  url         - Get the ingress URL"
    echo "  status      - Show current deployment status"
    echo "  deploy      - Full deployment (teardown + phase1 + phase2)"
    echo "  help        - Show this help"
    echo ""
    echo "Environment variables:"
    echo "  AWS_DEFAULT_REGION (default: us-east-2)"
    echo ""
    echo "Authentication:"
    echo "  - On EC2: Uses IAM role attached to instance (recommended)"
    echo "  - Local:  Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    echo ""
    echo "Example (EC2 with IAM role):"
    echo "  export AWS_DEFAULT_REGION='us-east-2'"
    echo "  $0 deploy"
    echo ""
    echo "Example (local with credentials):"
    echo "  export AWS_ACCESS_KEY_ID='...'"
    echo "  export AWS_SECRET_ACCESS_KEY='...'"
    echo "  export AWS_DEFAULT_REGION='us-east-2'"
    echo "  $0 deploy"
}

# Main
case "${1:-deploy}" in
    setup)
        check_prerequisites
        configure_kubeconfig
        ;;
    teardown)
        check_prerequisites
        configure_kubeconfig
        teardown
        ;;
    phase1)
        check_prerequisites
        configure_kubeconfig
        deploy_phase1
        get_url
        ;;
    phase2)
        check_prerequisites
        configure_kubeconfig
        deploy_phase2
        get_url
        ;;
    url)
        configure_kubeconfig
        get_url
        ;;
    status)
        configure_kubeconfig
        status
        ;;
    deploy)
        full_deploy
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
