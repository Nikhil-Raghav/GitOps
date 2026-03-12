#!/usr/bin/env bash
# =============================================================================
# eks-gateway-setup.sh
# Deploy Online Boutique with Kubernetes Gateway API on AWS EKS
#
# Usage:
#   chmod +x eks-gateway-setup.sh
#   ./eks-gateway-setup.sh                        # full install
#   ./eks-gateway-setup.sh --teardown             # remove everything
#   ./eks-gateway-setup.sh --status               # show current state
#
# What this script does (in order):
#   1. Validates prerequisites (kubectl, helm, aws cli, kustomize)
#   2. Verifies EKS cluster connectivity
#   3. Installs Gateway API CRDs (standard channel)
#   4. Installs Envoy Gateway controller via Helm
#   5. Waits for Envoy Gateway controller to be healthy
#   6. Applies the EKS overlay (kustomize overlays/eks)
#   7. Waits for Gateway to become Programmed/Ready
#   8. Waits for all application pods to be Running
#   9. Prints the NLB external hostname
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; }

# ── Configuration — edit these if needed ─────────────────────────────────────
GATEWAY_API_VERSION="v1.2.1"
ENVOY_GATEWAY_VERSION="v1.3.2"
ENVOY_GATEWAY_NAMESPACE="envoy-gateway-system"
APP_NAMESPACE="default"
OVERLAY_PATH="overlays/eks"
GATEWAY_NAME="online-boutique-gateway"

# Script directory (so it can be called from anywhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="install"
for arg in "$@"; do
  case $arg in
    --teardown) MODE="teardown" ;;
    --status)   MODE="status"   ;;
    --help|-h)
      echo "Usage: $0 [--teardown | --status | --help]"
      exit 0
      ;;
  esac
done

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

check_command() {
  local cmd=$1
  local install_hint=$2
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' not found. $install_hint"
  fi
  success "'$cmd' found: $(command -v "$cmd")"
}

wait_for_deployment() {
  local namespace=$1
  local deployment=$2
  local timeout=${3:-180}
  info "Waiting for deployment '$deployment' in namespace '$namespace' (timeout: ${timeout}s)..."
  if kubectl rollout status deployment/"$deployment" \
      -n "$namespace" --timeout="${timeout}s"; then
    success "Deployment '$deployment' is ready."
  else
    error "Deployment '$deployment' did not become ready within ${timeout}s."
  fi
}

wait_for_gateway() {
  local name=$1
  local namespace=$2
  local timeout=120
  local elapsed=0
  local interval=5

  info "Waiting for Gateway '$name' to be Programmed (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local condition
    condition=$(kubectl get gateway "$name" -n "$namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)

    if [ "$condition" = "True" ]; then
      success "Gateway '$name' is Programmed."
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
    echo -n "."
  done

  echo ""
  warn "Gateway '$name' did not reach Programmed=True within ${timeout}s."
  warn "Current status:"
  kubectl get gateway "$name" -n "$namespace" -o yaml | grep -A 20 "status:" || true
}

get_nlb_hostname() {
  local namespace=$1
  local timeout=180
  local elapsed=0
  local interval=10

  info "Waiting for NLB hostname to be assigned (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local hostname
    hostname=$(kubectl get gateway "$GATEWAY_NAME" -n "$namespace" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

    if [ -n "$hostname" ]; then
      echo "$hostname"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
    echo -n "."
  done

  echo ""
  warn "NLB hostname not yet assigned. Check: kubectl get gateway $GATEWAY_NAME -n $namespace"
  echo "pending"
}

# =============================================================================
# STATUS
# =============================================================================

show_status() {
  header "Current Cluster State"

  info "Gateway API CRDs:"
  kubectl get crd | grep gateway.networking.k8s.io || warn "Gateway API CRDs not found."

  echo ""
  info "Envoy Gateway controller:"
  kubectl get pods -n "$ENVOY_GATEWAY_NAMESPACE" 2>/dev/null || warn "Envoy Gateway namespace not found."

  echo ""
  info "GatewayClass:"
  kubectl get gatewayclass 2>/dev/null || warn "No GatewayClass found."

  echo ""
  info "Gateway:"
  kubectl get gateway -n "$APP_NAMESPACE" 2>/dev/null || warn "No Gateway found."

  echo ""
  info "HTTPRoutes:"
  kubectl get httproute -n "$APP_NAMESPACE" 2>/dev/null || warn "No HTTPRoutes found."

  echo ""
  info "Application pods:"
  kubectl get pods -n "$APP_NAMESPACE" 2>/dev/null || true

  echo ""
  info "NLB address:"
  kubectl get gateway "$GATEWAY_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.addresses[*].value}' 2>/dev/null \
    && echo "" || warn "Gateway not found."
}

# =============================================================================
# TEARDOWN
# =============================================================================

teardown() {
  header "Tearing Down Online Boutique + Gateway API"

  warn "This will delete all application resources and the Gateway from namespace '$APP_NAMESPACE'."
  read -rp "Are you sure? (yes/no): " confirm
  [ "$confirm" = "yes" ] || { info "Aborted."; exit 0; }

  info "Removing kustomize overlay resources..."
  kubectl delete -k "${SCRIPT_DIR}/${OVERLAY_PATH}" --ignore-not-found=true || true

  info "Removing Envoy Gateway Helm release..."
  helm uninstall eg -n "$ENVOY_GATEWAY_NAMESPACE" 2>/dev/null || warn "Envoy Gateway Helm release not found."

  info "Removing Gateway API CRDs..."
  kubectl delete -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    --ignore-not-found=true || true

  success "Teardown complete."
}

# =============================================================================
# INSTALL
# =============================================================================

install() {

  # ── Step 1: Prerequisites ──────────────────────────────────────────────────
  header "Step 1 — Checking Prerequisites"

  check_command kubectl  "Install: https://kubernetes.io/docs/tasks/tools/"
  check_command helm     "Install: https://helm.sh/docs/intro/install/"
  check_command aws      "Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  check_command kustomize "Install: https://kubectl.docs.kubernetes.io/installation/kustomize/"

  # ── Step 2: Cluster connectivity ──────────────────────────────────────────
  header "Step 2 — Verifying EKS Cluster Connectivity"

  CLUSTER_INFO=$(kubectl cluster-info 2>&1) || error "Cannot connect to cluster.\nRun: aws eks update-kubeconfig --name <cluster-name> --region <region>"
  success "Connected to cluster."
  echo "$CLUSTER_INFO" | head -2

  # Confirm it looks like EKS
  SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if echo "$SERVER" | grep -qi "eks.amazonaws.com"; then
    success "Cluster endpoint looks like EKS: $SERVER"
  else
    warn "Cluster endpoint does not look like EKS: $SERVER"
    warn "Proceeding anyway — make sure you are targeting the right cluster."
  fi

  # Show current context
  CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
  info "Current kubectl context: $CONTEXT"

  # ── Step 3: Gateway API CRDs ───────────────────────────────────────────────
  header "Step 3 — Installing Gateway API CRDs (${GATEWAY_API_VERSION})"

  CRD_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

  # Idempotent: apply even if already present
  info "Applying Gateway API standard-install CRDs..."
  kubectl apply -f "$CRD_URL"

  # Wait for CRDs to be established
  info "Waiting for CRDs to be established..."
  for crd in \
    gatewayclasses.gateway.networking.k8s.io \
    gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io; do
    kubectl wait --for=condition=Established crd/"$crd" --timeout=60s
    success "CRD ready: $crd"
  done

  # ── Step 4: Envoy Gateway controller ──────────────────────────────────────
  header "Step 4 — Installing Envoy Gateway (${ENVOY_GATEWAY_VERSION})"

  # Add Helm repo
  helm repo add envoy-gateway https://charts.envoyproxy.io 2>/dev/null || true
  helm repo update envoy-gateway

  # Install or upgrade (idempotent)
  if helm status eg -n "$ENVOY_GATEWAY_NAMESPACE" &>/dev/null; then
    info "Envoy Gateway already installed — upgrading..."
    helm upgrade eg envoy-gateway/gateway-helm \
      --version "$ENVOY_GATEWAY_VERSION" \
      --namespace "$ENVOY_GATEWAY_NAMESPACE" \
      --wait \
      --timeout 5m
  else
    info "Installing Envoy Gateway..."
    helm install eg envoy-gateway/gateway-helm \
      --version "$ENVOY_GATEWAY_VERSION" \
      --namespace "$ENVOY_GATEWAY_NAMESPACE" \
      --create-namespace \
      --wait \
      --timeout 5m
  fi

  success "Envoy Gateway Helm release is up."

  # ── Step 5: Wait for Envoy Gateway controller pods ────────────────────────
  header "Step 5 — Waiting for Envoy Gateway Controller"

  wait_for_deployment "$ENVOY_GATEWAY_NAMESPACE" "envoy-gateway" 180

  # ── Step 6: Apply EKS overlay (app + GatewayClass + HTTPRoutes) ───────────
  header "Step 6 — Applying EKS Kustomize Overlay"

  info "Running: kubectl apply -k ${OVERLAY_PATH}"
  kubectl apply -k "${SCRIPT_DIR}/${OVERLAY_PATH}"
  success "Kustomize overlay applied."

  # ── Step 7: Wait for Gateway to be Programmed ─────────────────────────────
  header "Step 7 — Waiting for Gateway to be Programmed"

  wait_for_gateway "$GATEWAY_NAME" "$APP_NAMESPACE"

  # ── Step 8: Wait for application pods ─────────────────────────────────────
  header "Step 8 — Waiting for Application Pods"

  APP_DEPLOYMENTS=(
    adservice
    authservice
    cartservice
    checkoutservice
    currencyservice
    emailservice
    frontend
    paymentservice
    productcatalogservice
    recommendationservice
    shippingservice
    shoppingassistantservice
  )

  for dep in "${APP_DEPLOYMENTS[@]}"; do
    # Some deployments might not exist — skip gracefully
    if kubectl get deployment "$dep" -n "$APP_NAMESPACE" &>/dev/null; then
      wait_for_deployment "$APP_NAMESPACE" "$dep" 300
    else
      warn "Deployment '$dep' not found in '$APP_NAMESPACE' — skipping."
    fi
  done

  # ── Step 9: Print summary ──────────────────────────────────────────────────
  header "Step 9 — Deployment Summary"

  NLB_HOSTNAME=$(get_nlb_hostname "$APP_NAMESPACE")

  echo ""
  success "Online Boutique deployed successfully on EKS with Gateway API!"
  echo ""
  echo -e "  ${BOLD}Gateway:${RESET}        $GATEWAY_NAME (namespace: $APP_NAMESPACE)"
  echo -e "  ${BOLD}GatewayClass:${RESET}   online-boutique-gw-class (Envoy Gateway)"
  echo -e "  ${BOLD}Controller:${RESET}     $ENVOY_GATEWAY_NAMESPACE"
  echo ""

  if [ "$NLB_HOSTNAME" != "pending" ]; then
    echo -e "  ${BOLD}${GREEN}NLB Endpoint:${RESET}   http://${NLB_HOSTNAME}"
    echo -e "  ${BOLD}${GREEN}             ${RESET}   https://${NLB_HOSTNAME}"
    echo ""
    echo -e "  ${YELLOW}Note:${RESET} NLB DNS propagation can take 1–3 minutes."
    echo -e "  Test with:"
    echo -e "    curl -v http://${NLB_HOSTNAME}/"
  else
    warn "NLB hostname not yet assigned. Check later with:"
    echo "    kubectl get gateway $GATEWAY_NAME -n $APP_NAMESPACE"
  fi

  echo ""
  info "Useful commands:"
  echo "    kubectl get gateway,httproute -n $APP_NAMESPACE"
  echo "    kubectl get pods -n $APP_NAMESPACE"
  echo "    kubectl describe gateway $GATEWAY_NAME -n $APP_NAMESPACE"
  echo "    kubectl logs -n $ENVOY_GATEWAY_NAMESPACE -l control-plane=envoy-gateway"
  echo ""
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

case $MODE in
  install)  install  ;;
  teardown) teardown ;;
  status)   show_status ;;
esac
