#!/bin/bash
# common-kubernetes.sh
# Shared functions library for Kubernetes setup and maintenance scripts

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging Functions
log() {
    local level="$1"
    shift
    local message="$*"

    # Console output only (with colors if enabled)
    if [[ "${ENABLE_COLOR}" == "true" ]]; then
        case "${level}" in
            INFO)
                echo -e "${BLUE}[INFO]${NC} ${message}"
                ;;
            OK)
                echo -e "${GREEN}[OK]${NC} ${message}"
                ;;
            WARN)
                echo -e "${YELLOW}[WARN]${NC} ${message}"
                ;;
            ERROR)
                echo -e "${RED}[ERROR]${NC} ${message}"
                ;;
            STEP)
                echo -e "${CYAN}[STEP]${NC} ${message}"
                ;;
            *)
                echo "[${level}] ${message}"
                ;;
        esac
    else
        echo "[${level}] ${message}"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_ok() {
    log "OK" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_step() {
    log "STEP" "$@"
}

die() {
    log_error "$@"
    exit 1
}

# Deploy-issue collector. Deploy steps deliberately keep going on non-fatal
# problems (e.g. a Let's Encrypt cert that isn't Ready yet) so one slow
# component doesn't abort the whole bring-up — but those problems must not
# vanish into scroll-back. Anything recorded here is replayed as a summary
# at the end of the run, and the run exits non-zero so "script finished
# green" really means "everything came up".
DEPLOY_ISSUES=()

record_deploy_issue() {
    DEPLOY_ISSUES+=("$1")
}

print_deploy_issue_summary() {
    # Returns 0 when there were no issues, 1 otherwise — callers can use
    # the return code as the script's exit status.
    if [[ ${#DEPLOY_ISSUES[@]} -eq 0 ]]; then
        return 0
    fi

    echo
    log_warn "=== Deployment finished with ${#DEPLOY_ISSUES[@]} unresolved issue(s) ==="
    local issue
    for issue in "${DEPLOY_ISSUES[@]}"; do
        log_warn "  - ${issue}"
    done
    log_warn "Re-run the corresponding --deploy-* flag once the cause is fixed (all steps are idempotent)."
    return 1
}

# Pre-flight Checks
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        return 1
    fi
    return 0
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        return 1
    fi

    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]]; then
        log_error "This script is designed for Ubuntu (detected: ${ID})"
        return 1
    fi

    log_info "Detected Ubuntu ${VERSION_ID}"
    return 0
}

check_storage_mount() {
    # If no external storage path configured, nothing to check
    if [[ -z "${STORAGE_PATH}" ]]; then
        log_ok "No external storage path configured, using default MicroK8s hostpath"
        return 0
    fi

    if [[ ! -d "${STORAGE_PATH}" ]]; then
        log_error "Storage path ${STORAGE_PATH} does not exist"
        return 1
    fi

    if ! mountpoint -q "${STORAGE_PATH}"; then
        log_warn "Storage path ${STORAGE_PATH} is not a mount point"
        log_warn "Expected ${STORAGE_DEVICE} to be mounted at ${STORAGE_PATH}"
        return 1
    fi

    log_ok "Storage path ${STORAGE_PATH} is mounted"
    return 0
}

# MicroK8s Status Functions
is_microk8s_installed() {
    if command -v microk8s &> /dev/null; then
        return 0
    fi
    return 1
}

is_microk8s_running() {
    if ! is_microk8s_installed; then
        return 1
    fi

    if microk8s status --wait-ready --timeout 5 &> /dev/null; then
        return 0
    fi
    return 1
}

get_microk8s_version() {
    if ! is_microk8s_installed; then
        echo "not installed"
        return 1
    fi

    microk8s version | head -n 1 | awk '{print $2}'
}

is_addon_enabled() {
    local addon="$1"

    if ! is_microk8s_installed; then
        return 1
    fi

    # Extract only the enabled section (between "enabled:" and "disabled:") then check for addon
    if microk8s status 2>/dev/null | sed -n '/^  enabled:/,/^  disabled:/p' | grep -q "^\s*${addon}\s"; then
        return 0
    fi

    return 1
}

# User and Group Functions
is_user_in_microk8s_group() {
    local user="${1:-${MICROK8S_USER}}"

    if groups "${user}" 2>/dev/null | grep -q microk8s; then
        return 0
    fi
    return 1
}

can_use_kubectl_without_sudo() {
    local user="${1:-${MICROK8S_USER}}"

    # Check if user is in microk8s group
    if ! is_user_in_microk8s_group "${user}"; then
        return 1
    fi

    # Try to run kubectl as user
    if su - "${user}" -c "microk8s kubectl get nodes" &> /dev/null; then
        return 0
    fi
    return 1
}

# Alias Verification (check the actual user's bashrc, not root's)
verify_kubectl_alias() {
    local user_bashrc="/home/${MICROK8S_USER}/.bashrc"
    if grep -q "alias kubectl='microk8s.kubectl'" "${user_bashrc}" 2>/dev/null; then
        return 0
    fi
    return 1
}

verify_helm_alias() {
    local user_bashrc="/home/${MICROK8S_USER}/.bashrc"
    if grep -q "alias helm='microk8s.helm3'" "${user_bashrc}" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Cert-Manager Functions
is_cert_manager_ready() {
    if ! is_microk8s_running; then
        return 1
    fi

    # Check if cert-manager webhook pod is running (the last one to become ready)
    local webhook_ready=$(microk8s kubectl get pods -n cert-manager -l app=webhook -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)

    if [[ ${webhook_ready} -ge 1 ]]; then
        return 0
    fi

    # Fallback: check if at least 3 pods are running (older MicroK8s)
    local ready_pods=$(microk8s kubectl get pods -n cert-manager -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)

    if [[ ${ready_pods} -ge 3 ]]; then
        return 0
    fi
    return 1
}

is_cluster_issuer_ready() {
    local issuer_name="${1:-${CLUSTER_ISSUER_NAME}}"

    if ! is_microk8s_running; then
        return 1
    fi

    # Check if ClusterIssuer exists
    if ! microk8s kubectl get clusterissuer "${issuer_name}" &> /dev/null; then
        return 1
    fi

    # Check if ClusterIssuer is ready (handle missing/null .status.conditions)
    local ready=$(microk8s kubectl get clusterissuer "${issuer_name}" -o json 2>/dev/null | \
        jq -r '(.status.conditions // [])[] | select(.type=="Ready") | .status')

    if [[ "${ready}" == "True" ]]; then
        return 0
    fi
    return 1
}

# Wait Functions
wait_for_microk8s_ready() {
    local timeout="${1:-${MICROK8S_READY_TIMEOUT}}"

    log_info "Waiting for MicroK8s to be ready (timeout: ${timeout}s)..."

    if microk8s status --wait-ready --timeout "${timeout}"; then
        log_ok "MicroK8s is ready"
        return 0
    else
        log_error "MicroK8s did not become ready within ${timeout}s"
        return 1
    fi
}

wait_for_cert_manager_ready() {
    local timeout="${1:-${CERT_MANAGER_READY_TIMEOUT}}"
    local elapsed=0
    local interval=5

    log_info "Waiting for cert-manager to be ready (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_cert_manager_ready; then
            log_ok "Cert-manager is ready"
            return 0
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
        log_info "Waiting... (${elapsed}/${timeout}s)"
    done

    log_error "Cert-manager did not become ready within ${timeout}s"
    log_info "Current cert-manager pod status:"
    microk8s kubectl get pods -n cert-manager 2>/dev/null || true
    return 1
}

wait_for_addon_enabled() {
    local addon="$1"
    local timeout="${2:-${ADDON_ENABLE_TIMEOUT}}"
    local elapsed=0
    local interval=5

    log_info "Waiting for addon '${addon}' to be enabled (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_addon_enabled "${addon}"; then
            log_ok "Addon '${addon}' is enabled"
            return 0
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    log_error "Addon '${addon}' did not enable within ${timeout}s"
    return 1
}

# Storage Functions
is_storage_configured() {
    # If no external storage configured, check that default path exists
    if [[ -z "${STORAGE_DIRECTORY}" ]]; then
        if [[ -d "${MICROK8S_STORAGE_PATH}" || -L "${MICROK8S_STORAGE_PATH}" ]]; then
            return 0
        fi
        return 1
    fi

    # Check if storage directory exists
    if [[ ! -d "${STORAGE_DIRECTORY}" ]]; then
        return 1
    fi

    # Check if symlink exists and points correctly
    if [[ -L "${MICROK8S_STORAGE_PATH}" ]]; then
        local target=$(readlink -f "${MICROK8S_STORAGE_PATH}")
        if [[ "${target}" == "${STORAGE_DIRECTORY}" ]]; then
            return 0
        fi
    fi

    return 1
}

is_default_storage_class_set() {
    if ! is_microk8s_running; then
        return 1
    fi

    local default_sc=$(microk8s kubectl get storageclass -o json 2>/dev/null | \
        jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name')

    if [[ -n "${default_sc}" ]]; then
        return 0
    fi
    return 1
}

# CLI Tools Functions
is_cli_tool_installed() {
    local tool="$1"

    if command -v "${tool}" &> /dev/null; then
        return 0
    fi
    return 1
}

get_cli_tool_version() {
    local tool="$1"

    case "${tool}" in
        argocd)
            "${tool}" version --client --short 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+'
            ;;
        vault)
            "${tool}" version 2>/dev/null | grep -oP 'Vault v\K[0-9]+\.[0-9]+\.[0-9]+'
            ;;
        yq)
            "${tool}" --version 2>/dev/null | grep -oP 'version v\K[0-9]+\.[0-9]+\.[0-9]+'
            ;;
        jq)
            "${tool}" --version 2>/dev/null | grep -oP 'jq-\K[0-9]+\.[0-9]+'
            ;;
        tailscale)
            "${tool}" version 2>/dev/null | head -1
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

################################################################################
# INFRASTRUCTURE FUNCTIONS
################################################################################

# kubectl and helm wrapper functions that work with sudo
kubectl() {
    if command -v microk8s &> /dev/null; then
        microk8s kubectl "$@"
    else
        command kubectl "$@"
    fi
}

helm() {
    if command -v microk8s &> /dev/null; then
        microk8s helm3 "$@"
    else
        command helm "$@"
    fi
}

# Export functions so they're available in subshells
export -f kubectl
export -f helm

# Pre-flight Checks
check_kubectl() {
    # When running with sudo, use microk8s directly
    if command -v microk8s &> /dev/null; then
        if ! microk8s kubectl get nodes &> /dev/null; then
            log_error "kubectl cannot connect to cluster"
            log_error "Please verify Kubernetes cluster is running"
            return 1
        fi
        log_ok "kubectl is available and connected to cluster"
        return 0
    fi

    # Fallback to kubectl command (when running without sudo)
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not available"
        log_error "Please complete Phase 1 setup first: ./setup-kubernetes.sh"
        return 1
    fi

    if ! kubectl get nodes &> /dev/null; then
        log_error "kubectl cannot connect to cluster"
        log_error "Please verify Kubernetes cluster is running"
        return 1
    fi

    log_ok "kubectl is available and connected to cluster"
    return 0
}

check_helm() {
    # When running with sudo, use microk8s directly
    if command -v microk8s &> /dev/null; then
        if ! microk8s helm3 version &> /dev/null; then
            log_error "helm is not available"
            log_error "Please complete Phase 1 setup first: ./setup-kubernetes.sh"
            return 1
        fi
        log_ok "helm is available"
        return 0
    fi

    # Fallback to helm command (when running without sudo)
    if ! command -v helm &> /dev/null; then
        log_error "helm is not available"
        log_error "Please complete Phase 1 setup first: ./setup-kubernetes.sh"
        return 1
    fi

    log_ok "helm is available"
    return 0
}

check_cluster_issuer() {
    local issuer="${1:-${CLUSTER_ISSUER_NAME}}"

    if ! kubectl get clusterissuer "${issuer}" &> /dev/null; then
        log_error "ClusterIssuer '${issuer}' does not exist"
        log_error "Please complete Phase 1 setup first: ../setup-kubernetes/setup-kubernetes.sh"
        return 1
    fi

    local ready=$(kubectl get clusterissuer "${issuer}" -o json 2>/dev/null | \
        jq -r '(.status.conditions // [])[] | select(.type=="Ready") | .status')

    if [[ "${ready}" != "True" ]]; then
        log_error "ClusterIssuer '${issuer}' is not ready"
        return 1
    fi

    log_ok "ClusterIssuer '${issuer}' is ready"
    return 0
}

check_ingress_controller() {
    if ! kubectl get pods -n ingress &> /dev/null; then
        log_error "Ingress controller namespace not found"
        log_error "Please enable ingress addon in Phase 1 setup"
        return 1
    fi

    local ready_pods=$(kubectl get pods -n ingress -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)

    if [[ ${ready_pods} -lt 1 ]]; then
        log_error "Ingress controller is not running"
        return 1
    fi

    log_ok "Ingress controller is running"
    return 0
}

# Helm Functions
add_helm_repo() {
    local name="$1"
    local url="$2"

    # Check if repo already exists
    if helm repo list -o json 2>/dev/null | jq -e ".[] | select(.name==\"${name}\")" &> /dev/null; then
        log_ok "Helm repo '${name}' already added"
        return 0
    fi

    log_info "Adding Helm repo: ${name} (${url})"
    helm repo add "${name}" "${url}" || {
        log_error "Failed to add Helm repo '${name}'"
        return 1
    }

    log_ok "Helm repo '${name}' added"
    return 0
}

update_helm_repos() {
    # Ensure all required repos are added
    [[ "${ENABLE_KUBE:-true}" == "true" ]] && add_helm_repo "${KUBE_REPO_NAME}" "${KUBE_REPO_URL}" || return 1
    [[ "${ENABLE_ARGOCD:-true}" == "true" ]] && add_helm_repo "${ARGOCD_REPO_NAME}" "${ARGOCD_REPO_URL}" || return 1
    [[ "${ENABLE_VAULT:-true}" == "true" ]] && add_helm_repo "${VAULT_REPO_NAME}" "${VAULT_REPO_URL}" || return 1

    log_info "Updating Helm repositories..."
    helm repo update || {
        log_error "Failed to update Helm repositories"
        return 1
    }

    log_ok "Helm repositories updated"
    return 0
}

is_helm_release_deployed() {
    local release="$1"
    local namespace="$2"

    if helm list -n "${namespace}" -o json 2>/dev/null | jq -e ".[] | select(.name==\"${release}\")" &> /dev/null; then
        return 0
    fi
    return 1
}

install_helm_chart() {
    local release="$1"
    local chart="$2"
    local namespace="$3"
    local values_file="${4:-}"

    # Argument array instead of a string + eval: spaces/globs in any value
    # (e.g. a path with a space) can never be re-split or re-expanded.
    local -a helm_args=(upgrade --install "${release}" "${chart}" -n "${namespace}")

    if [[ -n "${values_file}" && -f "${values_file}" ]]; then
        helm_args+=(-f "${values_file}")
    fi

    log_info "Installing Helm chart: ${chart} as ${release} in ${namespace}"
    helm "${helm_args[@]}" || {
        log_error "Failed to install Helm chart"
        return 1
    }

    log_ok "Helm chart installed successfully"
    return 0
}

upgrade_helm_release() {
    local release="$1"
    local chart="$2"
    local namespace="$3"
    local values_file="${4:-}"

    if ! is_helm_release_deployed "${release}" "${namespace}"; then
        log_warn "Release '${release}' not deployed, installing instead..."
        install_helm_chart "${release}" "${chart}" "${namespace}" "${values_file}"
        return $?
    fi

    local -a helm_args=(upgrade "${release}" "${chart}" -n "${namespace}")

    if [[ -n "${values_file}" && -f "${values_file}" ]]; then
        helm_args+=(-f "${values_file}")
    fi

    log_info "Upgrading Helm release: ${release} in ${namespace}"
    helm "${helm_args[@]}" || {
        log_error "Failed to upgrade Helm release"
        return 1
    }

    log_ok "Helm release upgraded successfully"
    return 0
}

# Namespace Management
namespace_exists() {
    local namespace="$1"

    if kubectl get namespace "${namespace}" &> /dev/null; then
        return 0
    fi
    return 1
}

create_namespace_if_not_exists() {
    local namespace="$1"

    if namespace_exists "${namespace}"; then
        log_ok "Namespace '${namespace}' already exists"
        return 0
    fi

    log_info "Creating namespace: ${namespace}"
    kubectl create namespace "${namespace}" || {
        log_error "Failed to create namespace '${namespace}'"
        return 1
    }

    log_ok "Namespace '${namespace}' created"
    return 0
}

# Deployment Verification
is_deployment_ready() {
    local namespace="$1"
    local deployment="$2"

    if ! kubectl get deployment -n "${namespace}" "${deployment}" &> /dev/null; then
        return 1
    fi

    local ready=$(kubectl get deployment -n "${namespace}" "${deployment}" -o json 2>/dev/null | \
        jq -r '.status.conditions[] | select(.type=="Available") | .status')

    if [[ "${ready}" == "True" ]]; then
        return 0
    fi
    return 1
}

wait_for_deployment_ready() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-${DEPLOYMENT_READY_TIMEOUT}}"
    local elapsed=0
    local interval=10

    log_info "Waiting for deployment '${deployment}' in namespace '${namespace}' (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_deployment_ready "${namespace}" "${deployment}"; then
            log_ok "Deployment '${deployment}' is ready"
            return 0
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
        log_info "Waiting... (${elapsed}/${timeout}s)"
    done

    log_error "Deployment '${deployment}' did not become ready within ${timeout}s"
    return 1
}

wait_for_pods_ready() {
    local namespace="$1"
    local label_selector="$2"
    local timeout="${3:-${POD_READY_TIMEOUT}}"
    local elapsed=0
    local interval=10

    log_info "Waiting for pods with label '${label_selector}' in namespace '${namespace}' (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local running_pods=$(kubectl get pods -n "${namespace}" -l "${label_selector}" -o json 2>/dev/null | \
            jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)

        if [[ ${running_pods} -gt 0 ]]; then
            log_ok "Pods are ready (${running_pods} running)"
            return 0
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
        log_info "Waiting... (${elapsed}/${timeout}s)"
    done

    log_error "Pods did not become ready within ${timeout}s"
    return 1
}

# Certificate Verification
is_certificate_ready() {
    local namespace="$1"
    local cert_name="$2"

    if ! kubectl get certificate -n "${namespace}" "${cert_name}" &> /dev/null; then
        return 1
    fi

    local ready=$(kubectl get certificate -n "${namespace}" "${cert_name}" -o json 2>/dev/null | \
        jq -r '.status.conditions[] | select(.type=="Ready") | .status')

    if [[ "${ready}" == "True" ]]; then
        return 0
    fi
    return 1
}

wait_for_certificate_ready() {
    local namespace="$1"
    local cert_name="$2"
    local timeout="${3:-${CERTIFICATE_READY_TIMEOUT}}"
    local elapsed=0
    local interval=15

    log_info "Waiting for certificate '${cert_name}' in namespace '${namespace}' (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_certificate_ready "${namespace}" "${cert_name}"; then
            log_ok "Certificate '${cert_name}' is ready"
            return 0
        fi

        # Check if there are any errors
        local reason=$(kubectl get certificate -n "${namespace}" "${cert_name}" -o json 2>/dev/null | \
            jq -r '.status.conditions[] | select(.type=="Ready") | .reason')

        if [[ -n "${reason}" && "${reason}" != "null" ]]; then
            log_info "Certificate status: ${reason}"
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
        log_info "Waiting... (${elapsed}/${timeout}s)"
    done

    log_warn "Certificate '${cert_name}' did not become ready within ${timeout}s"
    log_warn "This may be normal for Let's Encrypt validation (check manually)"
    # Deliberately non-fatal (callers continue the deploy), but recorded so
    # the end-of-run summary surfaces it and the script exits non-zero.
    record_deploy_issue "Certificate ${namespace}/${cert_name} not Ready after ${timeout}s — check DNS + inbound port 80, then re-run the deploy step"
    return 1
}

get_certificate_status() {
    local namespace="$1"
    local cert_name="$2"

    kubectl describe certificate -n "${namespace}" "${cert_name}"
}

# Ingress Verification
verify_ingress_created() {
    local namespace="$1"
    local ingress_name="$2"

    if kubectl get ingress -n "${namespace}" "${ingress_name}" &> /dev/null; then
        log_ok "Ingress '${ingress_name}' exists in namespace '${namespace}'"
        return 0
    else
        log_error "Ingress '${ingress_name}' does not exist in namespace '${namespace}'"
        return 1
    fi
}

get_ingress_hosts() {
    local namespace="$1"
    local ingress_name="$2"

    kubectl get ingress -n "${namespace}" "${ingress_name}" -o json 2>/dev/null | \
        jq -r '.spec.rules[].host'
}

# URL Testing
test_https_endpoint() {
    local url="$1"
    local timeout="${2:-10}"

    if curl -k -s --max-time "${timeout}" "${url}" &> /dev/null; then
        return 0
    fi
    return 1
}

wait_for_https_ready() {
    local url="$1"
    local timeout="${2:-${HTTPS_READY_TIMEOUT}}"
    local elapsed=0
    local interval=5

    log_info "Waiting for HTTPS endpoint: ${url} (timeout: ${timeout}s)..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if test_https_endpoint "${url}"; then
            log_ok "HTTPS endpoint is accessible: ${url}"
            return 0
        fi

        sleep ${interval}
        elapsed=$((elapsed + interval))
    done

    log_warn "HTTPS endpoint not accessible within ${timeout}s: ${url}"
    return 1
}

# Credential Retrieval
get_argocd_admin_password() {
    local namespace="${ARGOCD_NAMESPACE}"

    if kubectl get secret -n "${namespace}" argocd-initial-admin-secret &> /dev/null; then
        kubectl -n "${namespace}" get secret argocd-initial-admin-secret \
            -o jsonpath="{.data.password}" | base64 -d
        return 0
    else
        log_warn "ArgoCD initial admin secret not found"
        return 1
    fi
}

# Create the state directory (used for the ClusterIssuer YAML, etc.).
# Only meaningful when running as root, since STATE_DIR is under /var/lib.
init_logging() {
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "${STATE_DIR}"
    fi
}

# Sentinel — lib/*.sh files probe this to fail fast if sourced without
# common-kubernetes.sh already loaded. Keep this as the last statement.
readonly _COMMON_KUBERNETES_LOADED=1
