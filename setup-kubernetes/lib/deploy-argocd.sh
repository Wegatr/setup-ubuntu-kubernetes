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

    # Pattern (same as deploy-vault): never skip — Helm install/upgrade is
    # idempotent and is the ONLY way to push in-place changes from
    # manifests/argocd/values.yaml (e.g. new Ingress annotations) without
    # requiring an --force flag the operator has to remember. Initial-bootstrap
    # only steps (admin password capture) stay gated on is_new_deployment.
    local is_new_deployment=true
    if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        is_new_deployment=false
        log_info "ArgoCD already deployed — running helm upgrade to apply any values changes"
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

    # Apply our own Cert + IngressRoute (chart's bundled k8s Ingress is
    # disabled in values.yaml). Same Traefik-CRD pattern as Vault + IdP.
    local ingressroute_file
    ingressroute_file=$(render_manifest "${MANIFESTS_DIR}/argocd/ingressroute.yaml")
    log_info "Applying ArgoCD IngressRoute..."
    kubectl apply -f "${ingressroute_file}" --request-timeout=30s || {
        rm -f "${ingressroute_file}"
        log_error "Failed to apply ArgoCD IngressRoute"
        return 1
    }
    rm -f "${ingressroute_file}"

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
