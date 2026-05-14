#!/usr/bin/env bash
# lib/maintenance.sh — read-only status / display / logs commands plus the
# print_summary used at the end of a clean install.
#
# Globals consumed: MICROK8S_STORAGE_PATH, STORAGE_DIRECTORY,
#                   CLUSTER_ISSUER_NAME, CREDENTIALS_DIR, DEPLOY_ENV,
#                   KUBE_*, ARGOCD_*, VAULT_*.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/maintenance.sh requires common-kubernetes.sh" >&2; exit 1; }

infra_show_status() {
    log_step "=== Infrastructure Applications Status ==="
    echo

    # Dashboard
    log_info "Kubernetes Dashboard (${KUBE_NAMESPACE}):"
    if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_ok "  Helm release: deployed"
        kubectl get pods -n "${KUBE_NAMESPACE}" -l app.kubernetes.io/name=headlamp
        echo
    else
        log_warn "  Not deployed"
        echo
    fi

    # ArgoCD
    log_info "ArgoCD (${ARGOCD_NAMESPACE}):"
    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        log_ok "  Helm release: deployed"
        kubectl get pods -n "${ARGOCD_NAMESPACE}"
        echo
    else
        log_warn "  Not deployed"
        echo
    fi

    # Vault
    log_info "Vault (${VAULT_NAMESPACE}):"
    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        log_ok "  Helm release: deployed"
        kubectl get pods -n "${VAULT_NAMESPACE}"
        echo
    else
        log_warn "  Not deployed"
        echo
    fi

    # Ingresses
    log_info "Ingresses:"
    kubectl get ingress --all-namespaces | grep -E "(${KUBE_NAMESPACE}|${ARGOCD_NAMESPACE}|${VAULT_NAMESPACE})"
    echo

    # Certificates
    log_info "TLS Certificates:"
    kubectl get certificates --all-namespaces | grep -E "(${KUBE_NAMESPACE}|${ARGOCD_NAMESPACE}|${VAULT_NAMESPACE})"
    echo

    return 0
}

infra_get_kube_token() {
    log_step "=== Kubernetes Dashboard Token ==="
    echo

    if ! is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_error "Dashboard is not deployed"
        return 1
    fi

    # Ensure service account and permanent token exist
    if ! kubectl get serviceaccount dashboard-admin -n "${KUBE_NAMESPACE}" &> /dev/null; then
        log_info "Creating dashboard-admin service account..."
        kubectl create serviceaccount dashboard-admin -n "${KUBE_NAMESPACE}" || {
            log_error "Failed to create service account"
            return 1
        }
    fi

    if ! kubectl get clusterrolebinding dashboard-admin &> /dev/null; then
        log_info "Creating cluster-admin binding..."
        kubectl create clusterrolebinding dashboard-admin \
            --clusterrole=cluster-admin \
            --serviceaccount="${KUBE_NAMESPACE}:dashboard-admin" || {
            log_error "Failed to create cluster role binding"
            return 1
        }
    fi

    if ! kubectl get secret dashboard-admin-token -n "${KUBE_NAMESPACE}" &> /dev/null; then
        log_info "Creating permanent token secret..."
        create_permanent_dashboard_token "${KUBE_NAMESPACE}" "dashboard-admin"
    fi

    # Get permanent token from secret
    local dashboard_token=$(kubectl get secret dashboard-admin-token -n "${KUBE_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

    if [[ -n "${dashboard_token}" ]]; then
        log_info "Permanent Dashboard Access Token:"
        echo
        echo "${dashboard_token}"
        echo
        log_info "Dashboard URL: https://${KUBE_HOST}"
        log_info "This token is permanent and does not expire."
        return 0
    else
        log_error "Token not found. Try: sudo ./setup-kubernetes.sh --deploy-kube --force"
        return 1
    fi
}

infra_show_credentials() {
    log_step "=== Access Credentials ==="
    echo

    # ArgoCD
    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        log_info "ArgoCD:"
        log_info "  URL: https://${ARGOCD_HOST}"
        log_info "  Username: admin"
        log_info "  Password: (saved in ${CREDENTIALS_DIR}/argocd-${DEPLOY_ENV}.txt)"
        echo
    fi

    # Dashboard
    if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_info "Kubernetes Dashboard:"
        log_info "  URL: https://${KUBE_HOST}"
        log_info "  Token: (use --get-kube-token to display)"
        echo
    fi

    # Vault
    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        log_info "Vault:"
        log_info "  URL: https://${VAULT_HOST}"
        log_info "  Initialize with: kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault operator init -tls-skip-verify"
        echo
    fi

    return 0
}

infra_show_urls() {
    log_step "=== Access URLs ==="
    echo

    if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_info "Kubernetes Dashboard: https://${KUBE_HOST}"
    fi

    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        log_info "ArgoCD: https://${ARGOCD_HOST}"
    fi

    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        log_info "Vault: https://${VAULT_HOST}"
    fi

    echo
    return 0
}

infra_verify_tls() {
    log_step "=== TLS Certificates Status ==="
    echo

    # Dashboard certificate
    if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_info "Kubernetes Dashboard Certificate:"
        if is_certificate_ready "${KUBE_NAMESPACE}" "dashboard-tls"; then
            log_ok "  Status: Ready"
            kubectl get certificate -n "${KUBE_NAMESPACE}" dashboard-tls -o wide
        else
            log_warn "  Status: Not Ready"
            kubectl describe certificate -n "${KUBE_NAMESPACE}" dashboard-tls | grep -A 5 "Conditions:"
        fi
        echo
    fi

    # ArgoCD certificate
    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        log_info "ArgoCD Certificate:"
        if is_certificate_ready "${ARGOCD_NAMESPACE}" "argocd-server-tls"; then
            log_ok "  Status: Ready"
            kubectl get certificate -n "${ARGOCD_NAMESPACE}" argocd-server-tls -o wide
        else
            log_warn "  Status: Not Ready"
            kubectl describe certificate -n "${ARGOCD_NAMESPACE}" argocd-server-tls | grep -A 5 "Conditions:"
        fi
        echo
    fi

    # Vault certificate
    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        log_info "Vault Certificate:"
        if is_certificate_ready "${VAULT_NAMESPACE}" "vault-tls"; then
            log_ok "  Status: Ready"
            kubectl get certificate -n "${VAULT_NAMESPACE}" vault-tls -o wide
        else
            log_warn "  Status: Not Ready"
            kubectl describe certificate -n "${VAULT_NAMESPACE}" vault-tls | grep -A 5 "Conditions:"
        fi
        echo
    fi

    return 0
}

infra_show_logs() {
    local app="$1"

    case "${app}" in
        kube)
            log_step "Showing Kubernetes Dashboard logs..."
            kubectl logs -n "${KUBE_NAMESPACE}" -l app.kubernetes.io/name=headlamp --tail=100 -f
            ;;
        argocd)
            log_step "Showing ArgoCD logs..."
            kubectl logs -n "${ARGOCD_NAMESPACE}" -l app.kubernetes.io/name=argocd-server --tail=100 -f
            ;;
        vault)
            log_step "Showing Vault logs..."
            kubectl logs -n "${VAULT_NAMESPACE}" vault-0 --tail=100 -f
            ;;
        *)
            log_error "Unknown app: ${app}"
            log_error "Valid apps: kube, argocd, vault"
            return 1
            ;;
    esac

    return 0
}

print_summary() {
    log_step "=== Installation Complete ==="
    echo
    log_ok "MicroK8s Kubernetes cluster is ready!"
    echo
    log_info "Installed components:"
    log_info "  - MicroK8s: $(get_microk8s_version)"
    log_info "  - Storage: ${STORAGE_DIRECTORY:-${MICROK8S_STORAGE_PATH} (default)}"
    log_info "  - ClusterIssuer: ${CLUSTER_ISSUER_NAME}"
    log_info "  - CLI Tools: argocd, vault, yq, jq, tailscale"
    echo
    log_info "Next steps:"
    log_info "  1. Re-login or run: newgrp microk8s"
    log_info "  2. Test kubectl: kubectl get nodes"
    log_info "  3. Test helm: helm version"
    log_info "  4. Deploy infrastructure: sudo ./setup-kubernetes.sh --deploy-all"
    echo
}
