#!/bin/bash
set -euo pipefail

# GitHub Actions Runner Controller (ARC) teardown
# Idempotent teardown script - safe to run multiple times

RUNNER_USER="github-runner"
RUNNER_HOME="/srv/docker/github-runner"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"

# Handle kubeconfig for sudo execution
if [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    export KUBECONFIG="${KUBECONFIG:-${SUDO_HOME}/.kube/config}"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

remove_runner_scale_sets() {
    log_info "Removing runner scale sets..."

    if ! command -v helm >/dev/null 2>&1; then
        log_warn "helm not found, skipping helm cleanup"
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        log_warn "kubectl not found, skipping kubernetes cleanup"
        return 0
    fi

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Kubernetes cluster not accessible, skipping helm cleanup"
        return 0
    fi

    local ns="arc-runners"
    for release in $(helm list -n "$ns" -q 2>/dev/null || true); do
        log_info "Uninstalling helm release: $release"
        helm uninstall "$release" -n "$ns" --wait 2>/dev/null || true
    done

    # Delete namespace
    kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true

    log_info "Runner scale sets removed"
}

remove_arc_controller() {
    log_info "Removing ARC controller..."

    if ! command -v helm >/dev/null 2>&1; then
        return 0
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        return 0
    fi

    local ns="arc-systems"
    helm uninstall arc -n "$ns" --wait 2>/dev/null || true
    kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true

    log_info "ARC controller removed"
}

remove_k3d_cluster() {
    log_info "Removing k3d cluster: $K3D_CLUSTER_NAME..."

    if ! command -v k3d >/dev/null 2>&1; then
        log_warn "k3d not found, skipping cluster removal"
        return 0
    fi

    if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME} "; then
        k3d cluster delete "$K3D_CLUSTER_NAME"
        log_info "Deleted k3d cluster $K3D_CLUSTER_NAME"
    else
        log_info "Cluster $K3D_CLUSTER_NAME does not exist"
    fi

    log_info "k3d cluster removed"
}

remove_user() {
    log_info "Removing $RUNNER_USER user and home directory..."

    if id "$RUNNER_USER" >/dev/null 2>&1; then
        # Kill any processes owned by the user
        sudo pkill -u "$RUNNER_USER" 2>/dev/null || true
        sleep 1

        sudo userdel "$RUNNER_USER" 2>/dev/null || true
        log_info "Deleted user $RUNNER_USER"
    else
        log_info "User $RUNNER_USER does not exist"
    fi

    if [[ -d "$RUNNER_HOME" ]]; then
        sudo rm -rf "$RUNNER_HOME"
        log_info "Deleted home directory $RUNNER_HOME"
    fi

    log_info "User cleanup complete"
}

print_usage() {
    cat <<EOF
Usage: sudo $0 [options]

Tears down GitHub Actions self-hosted runners on k3d/Kubernetes.

Options:
  --keep-user       Do not remove the $RUNNER_USER user and home directory
  --keep-cluster    Do not remove the k3d cluster (only remove ARC)
  --config FILE     Load K3D_CLUSTER_NAME from config file
  -h, --help        Show this help message

Examples:
  sudo $0                           # Full teardown
  sudo $0 --keep-cluster            # Remove ARC but keep k3d cluster
  sudo $0 --config /path/to/config.env
EOF
}

main() {
    local keep_user=false
    local keep_cluster=false
    local config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-user)
                keep_user=true
                shift
                ;;
            --keep-cluster)
                keep_cluster=true
                shift
                ;;
            --config)
                config_file="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    if [[ -n "$config_file" && -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"
    fi

    log_info "Starting teardown..."

    remove_runner_scale_sets
    remove_arc_controller

    if [[ "$keep_cluster" == "false" ]]; then
        remove_k3d_cluster
    else
        log_info "Keeping k3d cluster as requested"
    fi

    if [[ "$keep_user" == "false" ]]; then
        remove_user
    else
        log_info "Keeping user $RUNNER_USER as requested"
    fi

    log_info "Teardown complete!"
}

main "$@"
