#!/bin/bash
set -euo pipefail

# GitHub Actions Runner Controller (ARC) deployment on k3d
# Idempotent setup script - safe to run multiple times

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_USER="github-runner"
RUNNER_HOME="/srv/docker/github-runner"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"

# Handle kubeconfig for sudo execution
if [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    SUDO_UID=$(id -u "$SUDO_USER")
    SUDO_GID=$(id -g "$SUDO_USER")
    export KUBECONFIG="${KUBECONFIG:-${SUDO_HOME}/.kube/config}"
    mkdir -p "$(dirname "$KUBECONFIG")"
    chown "$SUDO_UID:$SUDO_GID" "$(dirname "$KUBECONFIG")"
fi

fix_kubeconfig_perms() {
    if [[ -n "${SUDO_USER:-}" && -f "$KUBECONFIG" ]]; then
        chown "$SUDO_UID:$SUDO_GID" "$KUBECONFIG"
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() { log_error "$*"; exit 1; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v docker >/dev/null 2>&1 || die "docker is not installed"
    docker info >/dev/null 2>&1 || die "docker daemon is not running or user lacks permissions"

    if ! command -v k3d >/dev/null 2>&1; then
        log_info "Installing k3d..."
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        log_info "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm -f kubectl
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    log_info "Prerequisites OK"
}

setup_user() {
    log_info "Setting up $RUNNER_USER user..."

    if ! id "$RUNNER_USER" >/dev/null 2>&1; then
        sudo useradd --system --shell /usr/sbin/nologin \
            --home-dir "$RUNNER_HOME" --create-home "$RUNNER_USER"
        log_info "Created user $RUNNER_USER"
    else
        log_info "User $RUNNER_USER already exists"
    fi

    if [[ ! -d "$RUNNER_HOME" ]]; then
        sudo mkdir -p "$RUNNER_HOME"
        sudo chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
    fi

    # Add runner user to docker group for socket access
    if getent group docker >/dev/null 2>&1; then
        sudo usermod -aG docker "$RUNNER_USER" 2>/dev/null || true
    fi

    log_info "User setup complete"
}

setup_k3d_cluster() {
    log_info "Setting up k3d cluster: $K3D_CLUSTER_NAME..."

    if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME} "; then
        log_info "Cluster $K3D_CLUSTER_NAME already exists"
    else
        k3d cluster create "$K3D_CLUSTER_NAME" \
            --agents 2 \
            --k3s-arg "--disable=traefik@server:0" \
            --wait
        log_info "Created k3d cluster $K3D_CLUSTER_NAME"
    fi

    # Ensure kubeconfig is set
    k3d kubeconfig merge "$K3D_CLUSTER_NAME" --kubeconfig-merge-default
    kubectl config use-context "k3d-${K3D_CLUSTER_NAME}"

    # Wait for cluster to be ready
    log_info "Waiting for cluster nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    fix_kubeconfig_perms
    log_info "k3d cluster ready"
}

deploy_arc_controller() {
    log_info "Deploying ARC controller..."

    local ns="arc-systems"
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

    if helm status arc -n "$ns" >/dev/null 2>&1; then
        log_info "ARC controller already installed, upgrading..."
        helm upgrade arc \
            --namespace "$ns" \
            oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
            --wait
    else
        helm install arc \
            --namespace "$ns" \
            --create-namespace \
            oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
            --wait
    fi

    log_info "ARC controller deployed"
}

create_github_app_secret() {
    local config_file="$1"
    local ns="${RUNNER_NAMESPACE:-arc-runners}"
    local secret_name="github-app-secret"

    log_info "Creating GitHub App secret..."

    # Source config
    # shellcheck source=/dev/null
    source "$config_file"

    [[ -n "${GITHUB_APP_ID:-}" ]] || die "GITHUB_APP_ID not set in config"
    [[ -n "${GITHUB_APP_INSTALLATION_ID:-}" ]] || die "GITHUB_APP_INSTALLATION_ID not set in config"
    [[ -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]] || die "GITHUB_APP_PRIVATE_KEY_PATH not set in config"
    [[ -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]] || die "Private key file not found: $GITHUB_APP_PRIVATE_KEY_PATH"

    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

    # Delete existing secret if present (idempotent update)
    kubectl delete secret "$secret_name" -n "$ns" 2>/dev/null || true

    kubectl create secret generic "$secret_name" \
        --namespace="$ns" \
        --from-literal=github_app_id="$GITHUB_APP_ID" \
        --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
        --from-file=github_app_private_key="$GITHUB_APP_PRIVATE_KEY_PATH"

    log_info "GitHub App secret created in namespace $ns"
}

deploy_runner_scale_set() {
    local config_file="$1"

    log_info "Deploying runner scale set..."

    # shellcheck source=/dev/null
    source "$config_file"

    local ns="${RUNNER_NAMESPACE:-arc-runners}"
    local scale_set_name="${RUNNER_SCALE_SET_NAME:-k3d-runner}"
    local github_org="${GITHUB_ORG:-}"
    local github_repo="${GITHUB_REPO:-}"
    local min_runners="${MIN_RUNNERS:-0}"
    local max_runners="${MAX_RUNNERS:-5}"

    [[ -n "$github_org" ]] || die "GITHUB_ORG not set in config"

    local github_config_url
    if [[ -n "$github_repo" ]]; then
        github_config_url="https://github.com/${github_org}/${github_repo}"
    else
        github_config_url="https://github.com/${github_org}"
    fi

    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

    local helm_args=(
        --namespace "$ns"
        --set githubConfigUrl="$github_config_url"
        --set githubConfigSecret=github-app-secret
        --set minRunners="$min_runners"
        --set maxRunners="$max_runners"
    )

    if helm status "$scale_set_name" -n "$ns" >/dev/null 2>&1; then
        log_info "Runner scale set already installed, upgrading..."
        helm upgrade "$scale_set_name" \
            "${helm_args[@]}" \
            oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
            --wait
    else
        helm install "$scale_set_name" \
            "${helm_args[@]}" \
            --create-namespace \
            oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
            --wait
    fi

    log_info "Runner scale set '$scale_set_name' deployed"
    log_info "Runners will register at: $github_config_url"
}

print_usage() {
    cat <<EOF
Usage: sudo $0 <config-file>

Deploys GitHub Actions self-hosted runners on k3d/Kubernetes using ARC.

Arguments:
  config-file    Path to configuration file (see config.env.example)

Example:
  sudo $0 /path/to/config.env

The config file must contain:
  GITHUB_APP_ID              - GitHub App ID
  GITHUB_APP_INSTALLATION_ID - GitHub App Installation ID
  GITHUB_APP_PRIVATE_KEY_PATH - Path to PEM private key file
  GITHUB_ORG                 - GitHub organization name

Optional config:
  GITHUB_REPO          - Repository name (omit for org-level runners)
  RUNNER_NAMESPACE     - Kubernetes namespace (default: arc-runners)
  RUNNER_SCALE_SET_NAME - Scale set name (default: k3d-runner)
  MIN_RUNNERS          - Minimum runners (default: 0)
  MAX_RUNNERS          - Maximum runners (default: 5)
  K3D_CLUSTER_NAME     - k3d cluster name (default: arc-cluster)
EOF
}

main() {
    if [[ $# -lt 1 ]]; then
        print_usage
        exit 1
    fi

    local config_file="$1"
    [[ -f "$config_file" ]] || die "Config file not found: $config_file"

    # Load config for K3D_CLUSTER_NAME if set
    # shellcheck source=/dev/null
    source "$config_file"
    K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"

    check_prerequisites
    setup_user
    setup_k3d_cluster
    deploy_arc_controller
    create_github_app_secret "$config_file"
    deploy_runner_scale_set "$config_file"

    log_info "Deployment complete!"
    log_info "Use 'runs-on: ${RUNNER_SCALE_SET_NAME:-k3d-runner}' in your workflows"
}

main "$@"
