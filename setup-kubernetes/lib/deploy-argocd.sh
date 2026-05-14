#!/usr/bin/env bash
# lib/deploy-argocd.sh — ArgoCD Helm install + initial admin password capture.
#
# Globals consumed: ENABLE_ARGOCD, FORCE_DEPLOY, MANIFESTS_DIR,
#                   ARGOCD_REPO_NAME, ARGOCD_REPO_URL,
#                   ARGOCD_NAMESPACE, ARGOCD_RELEASE, ARGOCD_HOST.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/deploy-argocd.sh requires common-kubernetes.sh" >&2; exit 1; }

deploy_argocd() {
    if [[ "${ENABLE_ARGOCD}" != "true" ]]; then
        log_warn "ArgoCD is disabled in config, skipping"
        return 0
    fi

    log_step "Deploying ArgoCD..."

    # Add Helm repo
    add_helm_repo "${ARGOCD_REPO_NAME}" "${ARGOCD_REPO_URL}" || return 1

    # Update repos
    update_helm_repos || return 1

    # Create namespace
    create_namespace_if_not_exists "${ARGOCD_NAMESPACE}" || return 1

    # Check if already deployed
    local is_new_deployment=false
    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        if [[ "${FORCE_DEPLOY}" == "true" ]]; then
            log_warn "ArgoCD already deployed, forcing upgrade..."
        else
            log_ok "ArgoCD already deployed, skipping"
            return 0
        fi
    else
        is_new_deployment=true
    fi

    # Deploy with Helm (rendered with current environment hostnames)
    local values_file
    values_file=$(render_manifest "${MANIFESTS_DIR}/argocd/values.yaml")
    install_helm_chart "${ARGOCD_RELEASE}" \
        "${ARGOCD_REPO_NAME}/argo-cd" \
        "${ARGOCD_NAMESPACE}" \
        "${values_file}" || {
        rm -f "${values_file}"
        log_error "Failed to deploy ArgoCD"
        return 1
    }
    rm -f "${values_file}"

    # Wait for deployment
    wait_for_pods_ready "${ARGOCD_NAMESPACE}" "app.kubernetes.io/name=argocd-server" || {
        log_warn "ArgoCD pods not ready yet"
    }

    # Wait for certificate
    wait_for_certificate_ready "${ARGOCD_NAMESPACE}" "argocd-server-tls" || {
        log_warn "Certificate not ready yet (may take a few minutes)"
    }

    # Get initial admin password (only for new deployments)
    if [[ "${is_new_deployment}" == "true" ]]; then
        log_info "Retrieving ArgoCD initial admin password..."
        sleep 10  # Wait for secret to be created
        local password=$(get_argocd_admin_password)
        if [[ -n "${password}" ]]; then
            save_credential "argocd" \
                "URL: https://${ARGOCD_HOST}" \
                "Username: admin" \
                "Password: ${password}"
            log_info "Username: admin"
        fi
    fi

    log_ok "ArgoCD deployed successfully"
    log_info "Access at: https://${ARGOCD_HOST}"
    log_info "Username: admin"
    return 0
}
