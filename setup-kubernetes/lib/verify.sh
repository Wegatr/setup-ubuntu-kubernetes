#!/usr/bin/env bash
# lib/verify.sh — installation verification + full cluster health check.
#
# Globals consumed: MICROK8S_USER, ADDONS, STORAGE_DIRECTORY,
#                   CLUSTER_ISSUER_NAME, ENABLE_KUBE/ARGOCD/VAULT,
#                   KUBE_HOST/ARGOCD_HOST/VAULT_HOST,
#                   KUBE_RELEASE/ARGOCD_RELEASE/VAULT_RELEASE,
#                   KUBE_NAMESPACE/ARGOCD_NAMESPACE/VAULT_NAMESPACE,
#                   DEPLOY_ENV.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/verify.sh requires common-kubernetes.sh" >&2; exit 1; }

verify_installation() {
    log_step "Verifying installation..."

    local errors=0

    # Check MicroK8s
    if is_microk8s_installed; then
        log_ok "MicroK8s is installed (version: $(get_microk8s_version))"
    else
        log_error "MicroK8s is not installed"
        errors=$((errors + 1))
    fi

    # Check if running
    if is_microk8s_running; then
        log_ok "MicroK8s is running"
    else
        log_error "MicroK8s is not running"
        errors=$((errors + 1))
    fi

    # Check user in group
    if is_user_in_microk8s_group; then
        log_ok "User ${MICROK8S_USER} is in microk8s group"
    else
        log_error "User ${MICROK8S_USER} is not in microk8s group"
        errors=$((errors + 1))
    fi

    # Check addons
    for addon in "${ADDONS[@]}"; do
        if is_addon_enabled "${addon}"; then
            log_ok "Addon '${addon}' is enabled"
        else
            log_error "Addon '${addon}' is not enabled"
            errors=$((errors + 1))
        fi
    done

    # Check storage
    if is_storage_configured; then
        if [[ -n "${STORAGE_DIRECTORY}" ]]; then
            log_ok "Storage is configured correctly (${STORAGE_DIRECTORY})"
        else
            log_ok "Storage is configured correctly (default MicroK8s hostpath)"
        fi
    else
        log_warn "Storage configuration may need attention"
    fi

    # Check default storage class
    if is_default_storage_class_set; then
        log_ok "Default storage class is set to hostpath-storage"
    else
        log_warn "Default storage class is not set"
    fi

    # Check ClusterIssuer
    if is_cluster_issuer_ready; then
        log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is ready"
    else
        log_warn "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is not ready"
    fi

    # Check CLI tools
    for tool in argocd vault yq jq tailscale; do
        if is_cli_tool_installed "${tool}"; then
            log_ok "CLI tool '${tool}' is installed (version: $(get_cli_tool_version ${tool}))"
        else
            log_warn "CLI tool '${tool}' is not installed"
        fi
    done

    # Check aliases
    if verify_kubectl_alias; then
        log_ok "kubectl alias is configured"
    else
        log_warn "kubectl alias is not configured"
    fi

    if verify_helm_alias; then
        log_ok "helm alias is configured"
    else
        log_warn "helm alias is not configured"
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "Verification found ${errors} error(s)"
        return 1
    fi

    log_ok "Verification completed successfully"
    return 0
}

run_health_check() {
    local errors=0
    local warnings=0
    local checks=0

    _pass() { checks=$((checks + 1)); log_ok "$*"; }
    _fail() { checks=$((checks + 1)); errors=$((errors + 1)); log_error "$*"; }
    _warn() { checks=$((checks + 1)); warnings=$((warnings + 1)); log_warn "$*"; }

    log_step "=== Cluster Health Check ==="
    echo

    # --- Node ---
    log_info "--- Node ---"
    if is_microk8s_installed; then
        _pass "MicroK8s installed ($(get_microk8s_version))"
    else
        _fail "MicroK8s is not installed"
    fi

    if is_microk8s_running; then
        _pass "MicroK8s is running"
    else
        _fail "MicroK8s is not running"
    fi

    local node_status
    node_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "${node_status}" == "True" ]]; then
        local node_name node_version node_ip
        node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        node_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        _pass "Node '${node_name}' is Ready (${node_version}, IP: ${node_ip})"
    else
        _fail "Node is not Ready"
    fi

    if is_user_in_microk8s_group; then
        _pass "User '${MICROK8S_USER}' is in microk8s group"
    else
        _warn "User '${MICROK8S_USER}' is not in microk8s group"
    fi
    echo

    # --- Addons ---
    log_info "--- Addons ---"
    for addon in "${ADDONS[@]}"; do
        if is_addon_enabled "${addon}"; then
            _pass "Addon '${addon}' is enabled"
        else
            _fail "Addon '${addon}' is not enabled"
        fi
    done
    echo

    # --- Storage ---
    log_info "--- Storage ---"
    if is_default_storage_class_set; then
        local sc_name
        sc_name=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
        _pass "Default StorageClass: ${sc_name}"
    else
        _fail "No default StorageClass set"
    fi

    if [[ -n "${STORAGE_DIRECTORY}" ]]; then
        if is_storage_configured; then
            _pass "External storage configured (${STORAGE_DIRECTORY})"
        else
            _fail "External storage not properly configured"
        fi
    else
        _pass "Using default MicroK8s hostpath storage"
    fi
    echo

    # --- Cert-Manager ---
    log_info "--- Cert-Manager ---"
    if is_cert_manager_ready; then
        _pass "Cert-manager pods are running"
    else
        _fail "Cert-manager pods are not ready"
    fi

    if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
        _pass "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is Ready"
    else
        _fail "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is not Ready"
    fi
    echo

    # --- Ingress Controller ---
    log_info "--- Ingress Controller ---"
    local ingress_pods
    ingress_pods=$(kubectl get pods -n ingress -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
    if [[ ${ingress_pods} -ge 1 ]]; then
        _pass "Ingress controller running (${ingress_pods} pod(s))"
    else
        _fail "Ingress controller is not running"
    fi
    echo

    # --- System Pods ---
    log_info "--- System Pods ---"
    local not_running
    not_running=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded") | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase))"')
    if [[ -z "${not_running}" ]]; then
        local total_pods
        total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
        _pass "All ${total_pods} pod(s) are Running"
    else
        _fail "Pods not running:"
        echo "${not_running}" | while read -r line; do
            log_error "  ${line}"
        done
    fi
    echo

    # --- CLI Tools ---
    log_info "--- CLI Tools ---"
    for tool in argocd vault yq jq tailscale; do
        if is_cli_tool_installed "${tool}"; then
            _pass "${tool} $(get_cli_tool_version ${tool})"
        else
            _warn "${tool} is not installed"
        fi
    done
    echo

    # --- Shell Aliases ---
    log_info "--- Shell Aliases ---"
    if verify_kubectl_alias; then
        _pass "kubectl alias configured"
    else
        _warn "kubectl alias not configured"
    fi
    if verify_helm_alias; then
        _pass "helm alias configured"
    else
        _warn "helm alias not configured"
    fi

    local kubeconfig="/home/${MICROK8S_USER}/.kube/config"
    if [[ -f "${kubeconfig}" ]]; then
        _pass "Kubeconfig exists (${kubeconfig})"
    else
        _warn "Kubeconfig not found (${kubeconfig})"
    fi
    echo

    # --- Infrastructure Apps ---
    log_info "--- Infrastructure Apps ---"

    if [[ "${ENABLE_KUBE}" == "true" ]]; then
        if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
            local kube_pods
            kube_pods=$(kubectl get pods -n "${KUBE_NAMESPACE}" -l app.kubernetes.io/name=headlamp -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${kube_pods} -ge 1 ]]; then
                _pass "Kube Dashboard deployed and running (${kube_pods} pod(s))"
            else
                _fail "Kube Dashboard deployed but no pods running"
            fi
            if is_certificate_ready "${KUBE_NAMESPACE}" "dashboard-tls"; then
                _pass "Kube Dashboard TLS certificate is Ready"
            else
                _warn "Kube Dashboard TLS certificate is not Ready"
            fi
        else
            _warn "Kube Dashboard not deployed (https://${KUBE_HOST})"
        fi
    else
        log_info "  Kube Dashboard: disabled in config"
    fi

    if [[ "${ENABLE_ARGOCD}" == "true" ]]; then
        if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
            local argo_pods
            argo_pods=$(kubectl get pods -n "${ARGOCD_NAMESPACE}" -l app.kubernetes.io/name=argocd-server -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${argo_pods} -ge 1 ]]; then
                _pass "ArgoCD deployed and running (${argo_pods} pod(s))"
            else
                _fail "ArgoCD deployed but server pod not running"
            fi
            if is_certificate_ready "${ARGOCD_NAMESPACE}" "argocd-server-tls"; then
                _pass "ArgoCD TLS certificate is Ready"
            else
                _warn "ArgoCD TLS certificate is not Ready"
            fi
        else
            _warn "ArgoCD not deployed (https://${ARGOCD_HOST})"
        fi
    else
        log_info "  ArgoCD: disabled in config"
    fi

    if [[ "${ENABLE_VAULT}" == "true" ]]; then
        if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
            local vault_pods
            vault_pods=$(kubectl get pods -n "${VAULT_NAMESPACE}" -l app.kubernetes.io/name=vault -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${vault_pods} -ge 1 ]]; then
                _pass "Vault deployed and running (${vault_pods} pod(s))"
            else
                _fail "Vault deployed but no pods running"
            fi
            if is_certificate_ready "${VAULT_NAMESPACE}" "vault-tls"; then
                _pass "Vault TLS certificate is Ready"
            else
                _warn "Vault TLS certificate is not Ready"
            fi
        else
            _warn "Vault not deployed (https://${VAULT_HOST})"
        fi
    else
        log_info "  Vault: disabled in config"
    fi
    echo

    # --- Credentials ---
    log_info "--- Credentials ---"
    local cred_dir="/home/${MICROK8S_USER}/secrets"
    for app in kube argocd vault; do
        local cred_file="${cred_dir}/${app}-${DEPLOY_ENV}.txt"
        if [[ -f "${cred_file}" ]]; then
            _pass "${app}-${DEPLOY_ENV}.txt exists"
        else
            log_info "  ${app}-${DEPLOY_ENV}.txt: not yet created (deploy app first)"
        fi
    done
    echo

    # --- Summary ---
    log_step "=== Health Check Summary ==="
    log_info "Checks: ${checks}  Passed: $((checks - errors - warnings))  Warnings: ${warnings}  Errors: ${errors}"
    echo

    if [[ ${errors} -gt 0 ]]; then
        log_error "Health check found ${errors} error(s)"
        return 1
    elif [[ ${warnings} -gt 0 ]]; then
        log_warn "Health check passed with ${warnings} warning(s)"
        return 0
    else
        log_ok "All checks passed"
        return 0
    fi
}
