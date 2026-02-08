#!/bin/bash
#
# EKS Deployment Script for EC2
# Run from: ~/devops-agent-k8s-demo-master
# EC2 uses IAM role - no manual key export needed! Just set AWS_DEFAULT_REGION.
#

set -e

# Configuration
CLUSTER_NAME="demo-pre-prod-cluster"
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

# Force delete a resource by removing its finalizers first
force_delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3

    kubectl patch $resource_type $resource_name -n $namespace -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete $resource_type $resource_name -n $namespace --force --grace-period=0 2>/dev/null || true
}

# Force finalize a namespace
force_finalize_namespace() {
    local ns=$1
    if kubectl get namespace $ns &>/dev/null; then
        log_info "Force-finalizing namespace: $ns"
        kubectl get namespace $ns -o json | sed 's/"finalizers": \[.*\]/"finalizers": []/' | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
    fi
}

# Teardown existing deployment
teardown() {
    log_info "Tearing down existing deployment..."

    # Step 0: Delete webhooks that block resource deletion
    log_info "Removing blocking webhooks..."
    kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
    kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
    kubectl delete validatingwebhookconfiguration externalsecret-validate 2>/dev/null || true
    kubectl delete validatingwebhookconfiguration secretstore-validate 2>/dev/null || true

    for ns in argocd devops-agent-demo external-secrets; do
        if kubectl get namespace $ns &>/dev/null; then
            log_info "Cleaning up namespace: $ns"

            # Step 1: Force delete all ingresses
            for ing in $(kubectl get ingress -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing ingress: $ing"
                force_delete_resource ingress $ing $ns
            done

            # Step 2: Force delete all targetgroupbindings
            for tgb in $(kubectl get targetgroupbindings -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing targetgroupbinding: $tgb"
                force_delete_resource targetgroupbinding $tgb $ns
            done

            # Step 3: Force delete ArgoCD applications
            for app in $(kubectl get applications -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing application: $app"
                force_delete_resource application $app $ns
            done

            # Step 4: Force delete ArgoCD appprojects
            for proj in $(kubectl get appprojects -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing appproject: $proj"
                force_delete_resource appproject $proj $ns
            done

            # Step 5: Force delete ExternalSecrets
            for es in $(kubectl get externalsecrets -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing externalsecret: $es"
                force_delete_resource externalsecret $es $ns
            done

            # Step 6: Force delete SecretStores
            for ss in $(kubectl get secretstores -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                log_info "  Removing secretstore: $ss"
                force_delete_resource secretstore $ss $ns
            done

            # Step 7: Force delete all pods
            kubectl delete pods --all -n $ns --force --grace-period=0 2>/dev/null || true
        fi
    done

    # Step 8: Delete namespaces
    log_info "Deleting namespaces..."
    kubectl delete namespace devops-agent-demo --wait=false 2>/dev/null || true
    kubectl delete namespace argocd --wait=false 2>/dev/null || true
    kubectl delete namespace external-secrets --wait=false 2>/dev/null || true

    # Step 9: Wait briefly
    sleep 5

    # Step 10: Force finalize any stuck namespaces
    for ns in argocd devops-agent-demo external-secrets; do
        force_finalize_namespace $ns
    done

    # Step 11: Verify cleanup
    sleep 3
    local remaining=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -E "^(argocd|devops-agent-demo|external-secrets)$" | wc -l)
    if [[ $remaining -gt 0 ]]; then
        log_warn "Some namespaces still exist. Retrying force-finalize..."
        for ns in argocd devops-agent-demo external-secrets; do
            force_finalize_namespace $ns
        done
        sleep 3
    fi

    log_info "Teardown complete"
}

# Deploy all services (20 services)
deploy_all() {
    log_info "Deploying all 20 services..."

    cd "$REPO_PATH"
    kustomize build --load-restrictor=LoadRestrictionsNone overlays/dev-no-domain/ > /tmp/all-rendered.yaml
    kubectl apply -f /tmp/all-rendered.yaml --server-side --force-conflicts

    log_info "Waiting for pods to start..."
    sleep 30

    log_info "All pods:"
    kubectl get pods -n devops-agent-demo

    POD_COUNT=$(kubectl get pods -n devops-agent-demo --no-headers 2>/dev/null | wc -l)
    log_info "Deployed: $POD_COUNT pods"
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
    deploy_all

    # Final summary with ALB URL
    echo ""
    log_info "Deployment complete!"
    wait_for_alb
}

# Help
show_help() {
    echo "EKS Deployment Script"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup       - Check prerequisites and configure kubectl"
    echo "  deploy      - Full deployment (teardown + deploy all 20 services)"
    echo "  teardown    - Remove all deployments (back to Phase 0)"
    echo "  url         - Get the ALB ingress URL"
    echo "  status      - Show current deployment status"
    echo "  help        - Show this help"
    echo ""
    echo "Environment variables:"
    echo "  AWS_DEFAULT_REGION (default: us-east-2)"
    echo ""
    echo "Authentication:"
    echo "  - On EC2: Uses IAM role attached to instance (recommended)"
    echo "  - Local:  Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    echo ""
    echo "Workflow:"
    echo "  $0 setup      # Configure kubectl (Phase 0)"
    echo "  $0 status     # Verify clean state"
    echo "  $0 deploy     # Deploy all 20 services"
    echo "  $0 url        # Get ALB URL"
    echo "  $0 teardown   # Back to Phase 0 (clean state)"
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
