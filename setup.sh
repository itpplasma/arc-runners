#!/bin/bash
set -euo pipefail

# GitHub Actions Runner Controller (ARC) deployment on k3d
# Idempotent setup script - safe to run multiple times

RUNNER_USER="github-runner"
RUNNER_HOME="/srv/docker/github-runner"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"
ENABLE_CACHE_PROXY="${ENABLE_CACHE_PROXY:-true}"
CACHE_DIR="${RUNNER_HOME}/cache"

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

setup_cache_dirs() {
    if [[ "$ENABLE_CACHE_PROXY" != "true" ]]; then
        return
    fi

    log_info "Setting up cache directories at $CACHE_DIR..."

    local dirs=("registry" "apt" "squid")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "${CACHE_DIR}/${dir}" ]]; then
            sudo mkdir -p "${CACHE_DIR}/${dir}"
            log_info "Created ${CACHE_DIR}/${dir}"
        fi
    done

    sudo chown -R "$RUNNER_USER:$RUNNER_USER" "$CACHE_DIR"
    sudo chmod -R 777 "$CACHE_DIR"
    log_info "Cache directories ready"
}

deploy_cache_proxies() {
    if [[ "$ENABLE_CACHE_PROXY" != "true" ]]; then
        log_info "Cache proxy disabled, skipping"
        return
    fi

    log_info "Deploying cache proxies..."

    local ns="cache-system"
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

    # Deploy PVs (hostPath pointing to k3d-mounted dirs), PVCs, and services
    kubectl apply -n "$ns" -f - <<'EOF'
---
# PersistentVolumes using hostPath (mapped from host via k3d volume mount)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: registry-cache-pv
spec:
  capacity:
    storage: 50Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cache-storage
  hostPath:
    path: /cache/registry
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: apt-cache-pv
spec:
  capacity:
    storage: 20Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cache-storage
  hostPath:
    path: /cache/apt
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: squid-cache-pv
spec:
  capacity:
    storage: 30Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cache-storage
  hostPath:
    path: /cache/squid
    type: DirectoryOrCreate
---
# PersistentVolumeClaims
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-cache-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cache-storage
  volumeName: registry-cache-pv
  resources:
    requests:
      storage: 50Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: apt-cache-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cache-storage
  volumeName: apt-cache-pv
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: squid-cache-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: cache-storage
  volumeName: squid-cache-pv
  resources:
    requests:
      storage: 30Gi
---
# Registry mirror deployment (pull-through cache for Docker Hub)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry-mirror
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry-mirror
  template:
    metadata:
      labels:
        app: registry-mirror
    spec:
      containers:
        - name: registry
          image: registry:2
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_PROXY_REMOTEURL
              value: "https://registry-1.docker.io"
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          volumeMounts:
            - name: cache
              mountPath: /var/lib/registry
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: registry-cache-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: registry-mirror
spec:
  selector:
    app: registry-mirror
  ports:
    - port: 5000
      targetPort: 5000
---
# APT cache (apt-cacher-ng)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apt-cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: apt-cache
  template:
    metadata:
      labels:
        app: apt-cache
    spec:
      containers:
        - name: apt-cacher-ng
          image: sameersbn/apt-cacher-ng:3.7.4-20220421
          ports:
            - containerPort: 3142
          volumeMounts:
            - name: cache
              mountPath: /var/cache/apt-cacher-ng
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: apt-cache-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: apt-cache
spec:
  selector:
    app: apt-cache
  ports:
    - port: 3142
      targetPort: 3142
---
# Squid HTTP cache proxy
apiVersion: v1
kind: ConfigMap
metadata:
  name: squid-config
data:
  squid.conf: |
    acl localnet src 10.0.0.0/8
    acl localnet src 172.16.0.0/12
    acl localnet src 192.168.0.0/16
    acl SSL_ports port 443
    acl Safe_ports port 80
    acl Safe_ports port 443
    acl Safe_ports port 1025-65535
    acl CONNECT method CONNECT
    http_access deny !Safe_ports
    http_access deny CONNECT !SSL_ports
    http_access allow localnet
    http_access allow localhost
    http_access deny all
    http_port 3128
    cache_dir ufs /var/spool/squid 20000 16 256
    maximum_object_size 1 GB
    cache_mem 512 MB
    refresh_pattern -i \.tar\.     10080 90% 43200 override-expire
    refresh_pattern -i \.tar\.gz$  10080 90% 43200 override-expire
    refresh_pattern -i \.tar\.bz2$ 10080 90% 43200 override-expire
    refresh_pattern -i \.tar\.xz$  10080 90% 43200 override-expire
    refresh_pattern -i \.deb$      10080 90% 43200 override-expire
    refresh_pattern -i \.rpm$      10080 90% 43200 override-expire
    refresh_pattern -i \.whl$      10080 90% 43200 override-expire
    refresh_pattern .              0     20%  4320
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: squid-cache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: squid-cache
  template:
    metadata:
      labels:
        app: squid-cache
    spec:
      initContainers:
        - name: init-cache
          image: ubuntu/squid:latest
          command: ["/bin/sh", "-c", "chown -R proxy:proxy /var/spool/squid"]
          volumeMounts:
            - name: cache
              mountPath: /var/spool/squid
      containers:
        - name: squid
          image: ubuntu/squid:latest
          ports:
            - containerPort: 3128
          volumeMounts:
            - name: cache
              mountPath: /var/spool/squid
            - name: config
              mountPath: /etc/squid/squid.conf
              subPath: squid.conf
      volumes:
        - name: cache
          persistentVolumeClaim:
            claimName: squid-cache-pvc
        - name: config
          configMap:
            name: squid-config
---
apiVersion: v1
kind: Service
metadata:
  name: squid-cache
spec:
  selector:
    app: squid-cache
  ports:
    - port: 3128
      targetPort: 3128
EOF

    log_info "Waiting for cache proxies to be ready..."
    kubectl rollout status deployment/registry-mirror -n "$ns" --timeout=120s
    kubectl rollout status deployment/apt-cache -n "$ns" --timeout=120s
    kubectl rollout status deployment/squid-cache -n "$ns" --timeout=120s

    log_info "Cache proxies deployed in namespace $ns"
}

setup_k3d_cluster() {
    log_info "Setting up k3d cluster: $K3D_CLUSTER_NAME..."

    if k3d cluster list 2>/dev/null | grep -q "^${K3D_CLUSTER_NAME} "; then
        log_info "Cluster $K3D_CLUSTER_NAME already exists"
    else
        local volume_args=()
        if [[ "$ENABLE_CACHE_PROXY" == "true" ]]; then
            volume_args=(--volume "${CACHE_DIR}:/cache@all")
        fi

        k3d cluster create "$K3D_CLUSTER_NAME" \
            --agents 2 \
            --k3s-arg "--disable=traefik@server:0" \
            "${volume_args[@]}" \
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

    # Warn if private key has permissive permissions
    local key_perms
    key_perms=$(stat -c '%a' "$GITHUB_APP_PRIVATE_KEY_PATH" 2>/dev/null || stat -f '%Lp' "$GITHUB_APP_PRIVATE_KEY_PATH")
    if [[ ! "$key_perms" =~ ^[0-6]00$ ]]; then
        log_warn "Private key has permissive permissions: $key_perms (recommend: chmod 600)"
    fi

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
    local scale_set_name="${RUNNER_SCALE_SET_NAME:-plasma-runners}"
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

    # Build proxy environment variables if cache proxy is enabled
    local proxy_env=""
    local dind_env=""
    if [[ "$ENABLE_CACHE_PROXY" == "true" ]]; then
        proxy_env='
          - name: HTTP_PROXY
            value: "http://squid-cache.cache-system.svc.cluster.local:3128"
          - name: HTTPS_PROXY
            value: "http://squid-cache.cache-system.svc.cluster.local:3128"
          - name: http_proxy
            value: "http://squid-cache.cache-system.svc.cluster.local:3128"
          - name: https_proxy
            value: "http://squid-cache.cache-system.svc.cluster.local:3128"
          - name: NO_PROXY
            value: "localhost,127.0.0.1,.cluster.local,.svc,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
          - name: no_proxy
            value: "localhost,127.0.0.1,.cluster.local,.svc,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
          - name: APT_PROXY
            value: "http://apt-cache.cache-system.svc.cluster.local:3142"'
        dind_env='
          - name: DOCKER_OPTS
            value: "--registry-mirror=http://registry-mirror.cache-system.svc.cluster.local:5000"'
    fi

    # Create values file with DinD config and IfNotPresent pull policy
    # (Using manual template instead of containerMode.type=dind to control imagePullPolicy)
    local values_file
    values_file=$(mktemp)
    cat > "$values_file" <<EOF
githubConfigUrl: "$github_config_url"
githubConfigSecret: github-app-secret
minRunners: $min_runners
maxRunners: $max_runners
template:
  spec:
    initContainers:
      - name: init-dind-externals
        image: ghcr.io/actions/actions-runner:latest
        imagePullPolicy: IfNotPresent
        command: ["cp", "-r", "-v", "/home/runner/externals/.", "/home/runner/tmpDir/"]
        volumeMounts:
          - name: dind-externals
            mountPath: /home/runner/tmpDir
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        imagePullPolicy: IfNotPresent
        command: ["/home/runner/run.sh"]
        env:
          - name: DOCKER_HOST
            value: unix:///var/run/docker.sock${proxy_env}
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
      - name: dind
        image: docker:dind
        imagePullPolicy: IfNotPresent
        args: ["\${DOCKER_OPTS:-}"]
        securityContext:
          privileged: true
        env:${dind_env:-"
          []"}
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
          - name: dind-externals
            mountPath: /home/runner/externals
    volumes:
      - name: work
        emptyDir: {}
      - name: dind-sock
        emptyDir: {}
      - name: dind-externals
        emptyDir: {}
EOF

    local helm_args=(
        --namespace "$ns"
        -f "$values_file"
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

    rm -f "$values_file"
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
  RUNNER_SCALE_SET_NAME - Scale set name (default: plasma-runners)
  MIN_RUNNERS          - Minimum runners (default: 0)
  MAX_RUNNERS          - Maximum runners (default: 5)
  K3D_CLUSTER_NAME     - k3d cluster name (default: arc-cluster)
  ENABLE_CACHE_PROXY   - Enable caching proxies (default: true)
                         Deploys registry mirror, apt cache, and HTTP proxy
                         Cache persisted at /srv/docker/github-runner/cache
EOF
}

main() {
    if [[ $# -lt 1 ]]; then
        print_usage
        exit 1
    fi

    local config_file="$1"
    [[ -f "$config_file" ]] || die "Config file not found: $config_file"

    # Load config
    # shellcheck source=/dev/null
    source "$config_file"
    K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-arc-cluster}"
    ENABLE_CACHE_PROXY="${ENABLE_CACHE_PROXY:-true}"

    check_prerequisites
    setup_user
    setup_cache_dirs
    setup_k3d_cluster
    deploy_arc_controller
    deploy_cache_proxies
    create_github_app_secret "$config_file"
    deploy_runner_scale_set "$config_file"

    log_info "Deployment complete!"
    log_info "Use 'runs-on: ${RUNNER_SCALE_SET_NAME:-plasma-runners}' in your workflows"
    if [[ "$ENABLE_CACHE_PROXY" == "true" ]]; then
        log_info "Cache proxies enabled - data persisted at $CACHE_DIR"
    fi
}

main "$@"
