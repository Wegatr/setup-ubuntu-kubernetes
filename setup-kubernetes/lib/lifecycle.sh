#!/usr/bin/env bash
# lib/lifecycle.sh — credentials saver + per-app uninstall / upgrade / restart /
# update-ingress. save_credential() is used by deploy-*.sh too.
#
# Globals consumed: MICROK8S_USER, DEPLOY_ENV, CREDENTIALS_DIR, MANIFESTS_DIR,
#                   KUBE_*, ARGOCD_*, VAULT_*.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/lifecycle.sh requires common-kubernetes.sh" >&2; exit 1; }

# Save credentials to a per-app file: ~/secrets/<app>-<env>.txt
# Usage: save_credential "app-name" "key=value" ...
# Bug-fixed: chowns the directory too — without this, the script-as-root
# leaves /home/<user>/secrets/ owned by root, and any later non-root write
# (e.g. running deploy_vault outside sudo) silently fails the redirect.
save_credential() {
    local app="$1"
    shift
    local cred_file="${CREDENTIALS_DIR}/${app}-${DEPLOY_ENV}.txt"

    mkdir -p "${CREDENTIALS_DIR}"
    chown "${MICROK8S_USER}:${MICROK8S_USER}" "${CREDENTIALS_DIR}"
    chmod 700 "${CREDENTIALS_DIR}"

    {
        echo "${app} (${DEPLOY_ENV})"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        for entry in "$@"; do
            echo "${entry}"
        done
    } > "${cred_file}" || {
        log_error "Failed to write credentials to ${cred_file}"
        return 1
    }

    chown "${MICROK8S_USER}:${MICROK8S_USER}" "${cred_file}"
    chmod 600 "${cred_file}"
    log_info "Credentials saved to: ${cred_file}"
}

uninstall_idp() {
    if ! is_helm_release_deployed "${IDP_RELEASE}" "${IDP_NAMESPACE}"; then
        log_warn "IdP (Authentik) not deployed, nothing to uninstall"
        return 0
    fi

    log_step "Uninstalling IdP (Authentik)..."
    helm uninstall "${IDP_RELEASE}" -n "${IDP_NAMESPACE}" || log_warn "Helm uninstall failed"

    # The bundled PostgreSQL StatefulSet's PVCs are NOT auto-deleted with the
    # Helm release (intentional — protects user data). Wipe them so the next
    # --deploy-idp gets a fresh DB. This is the nuclear-recovery path used
    # after blueprint duplicates or other DB-level wedges.
    kubectl delete pvc -n "${IDP_NAMESPACE}" --all --ignore-not-found
    kubectl delete certificate -n "${IDP_NAMESPACE}" idp-tls --ignore-not-found
    kubectl delete ingressroute -n "${IDP_NAMESPACE}" idp --ignore-not-found
    kubectl delete middleware -n "${IDP_NAMESPACE}" forwardauth --ignore-not-found
    kubectl delete configmap -n "${IDP_NAMESPACE}" idp-blueprints --ignore-not-found
    kubectl delete secret -n "${IDP_NAMESPACE}" idp-bootstrap --ignore-not-found

    # Drop the per-consumer OIDC secrets that deploy_idp pre-creates — they
    # carry the now-stale client_secrets. Next --deploy-idp generates new ones.
    kubectl delete secret -n argocd argocd-oidc --ignore-not-found
    kubectl delete secret -n kubernetes-dashboard headlamp-oidc --ignore-not-found
    kubectl delete secret -n vault vault-oidc --ignore-not-found

    # Credentials file ~/secrets/idp-<env>.txt is DELIBERATELY preserved (same
    # pattern as Vault unseal keys). It is the source of truth; the next
    # --deploy-idp reads it back and restores Authentik to byte-identical
    # secret_key / bootstrap_password / client_secrets — so consumer apps
    # (argocd-oidc, headlamp-oidc, vault-oidc K8s Secrets + the entries in
    # configs/secrets.<env>) STAY VALID across --uninstall + --deploy cycles.
    # No need to re-update secrets.<env> or re-deploy ArgoCD/Headlamp/Vault.
    #
    # To FORCE fresh secrets (e.g. genuine rotation event), delete the file
    # manually before re-installing:
    #   rm ~/secrets/idp-${DEPLOY_ENV}.txt
    log_ok "IdP (Authentik) uninstalled (credentials in ${CREDENTIALS_DIR}/idp-${DEPLOY_ENV}.txt preserved)"
    log_info "Re-run: sudo ./setup-kubernetes.sh --${DEPLOY_ENV} --deploy-idp"
}

uninstall_kube() {
    if ! is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        log_warn "Kube Dashboard not deployed, nothing to uninstall"
        return 0
    fi

    log_step "Uninstalling Kubernetes Dashboard..."
    helm uninstall "${KUBE_RELEASE}" -n "${KUBE_NAMESPACE}" || log_warn "Helm uninstall failed"
    kubectl delete ingress -n "${KUBE_NAMESPACE}" kubernetes-dashboard --ignore-not-found
    kubectl delete clusterrolebinding dashboard-admin --ignore-not-found
    kubectl delete sa -n "${KUBE_NAMESPACE}" dashboard-admin --ignore-not-found
    kubectl delete secret -n "${KUBE_NAMESPACE}" dashboard-admin-token --ignore-not-found
    log_ok "Kubernetes Dashboard uninstalled"
}

uninstall_argocd() {
    if ! is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
        log_warn "ArgoCD not deployed, nothing to uninstall"
        return 0
    fi

    log_step "Uninstalling ArgoCD..."
    helm uninstall "${ARGOCD_RELEASE}" -n "${ARGOCD_NAMESPACE}" || log_warn "Helm uninstall failed"

    # ArgoCD's Helm chart does not remove its CRDs on uninstall (intentional —
    # protects user Applications). Remove them explicitly so a future deploy
    # gets the current versions.
    kubectl delete crd \
        applications.argoproj.io \
        applicationsets.argoproj.io \
        appprojects.argoproj.io \
        --ignore-not-found
    log_ok "ArgoCD uninstalled"
}

uninstall_vault() {
    if ! is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        log_warn "Vault not deployed, nothing to uninstall"
        return 0
    fi

    log_step "Uninstalling Vault..."
    helm uninstall "${VAULT_RELEASE}" -n "${VAULT_NAMESPACE}" || log_warn "Helm uninstall failed"
    kubectl delete ingress -n "${VAULT_NAMESPACE}" vault --ignore-not-found
    kubectl delete ingressroute.traefik.io -n "${VAULT_NAMESPACE}" vault --ignore-not-found
    kubectl delete middleware.traefik.io -n "${VAULT_NAMESPACE}" vault-oidc-redirect --ignore-not-found
    kubectl delete certificate -n "${VAULT_NAMESPACE}" vault-tls --ignore-not-found
    # Zero-click SSO helper (Deployment + Service + ConfigMap)
    kubectl delete -n "${VAULT_NAMESPACE}" deploy,svc,cm -l app=vault-auto-redirect --ignore-not-found
    kubectl delete -n "${VAULT_NAMESPACE}" cm vault-auto-redirect --ignore-not-found
    kubectl delete pvc -n "${VAULT_NAMESPACE}" --all --ignore-not-found
    log_ok "Vault uninstalled"
    log_warn "Released PersistentVolume(s) may still exist on the host — remove manually if reclaim policy is Retain"
}

restart_app() {
    local app="$1"

    case "${app}" in
        kube)
            log_step "Restarting Kubernetes Dashboard..."
            kubectl rollout restart deployment -n "${KUBE_NAMESPACE}" -l app.kubernetes.io/name=headlamp || {
                log_error "Failed to restart Dashboard"
                return 1
            }
            log_ok "Dashboard restarted"
            ;;
        argocd)
            log_step "Restarting ArgoCD..."
            kubectl rollout restart deployment -n "${ARGOCD_NAMESPACE}" || {
                log_error "Failed to restart ArgoCD"
                return 1
            }
            log_ok "ArgoCD restarted"
            ;;
        vault)
            log_step "Restarting Vault..."
            kubectl rollout restart statefulset -n "${VAULT_NAMESPACE}" vault || {
                log_error "Failed to restart Vault"
                return 1
            }
            log_ok "Vault restarted"
            ;;
        *)
            log_error "Unknown app: ${app}"
            log_error "Valid apps: kube, argocd, vault"
            return 1
            ;;
    esac

    return 0
}

upgrade_app() {
    local app="$1"

    case "${app}" in
        kube)
            log_step "Upgrading Kubernetes Dashboard..."
            update_helm_repos || return 1
            local values_file
            values_file=$(render_manifest "${MANIFESTS_DIR}/kube/values.yaml")
            upgrade_helm_release "${KUBE_RELEASE}" \
                "${KUBE_REPO_NAME}/headlamp" \
                "${KUBE_NAMESPACE}" \
                "${values_file}" || {
                rm -f "${values_file}"
                log_error "Failed to upgrade Dashboard"
                return 1
            }
            rm -f "${values_file}"
            log_ok "Dashboard upgraded"
            ;;
        argocd)
            log_step "Upgrading ArgoCD..."
            update_helm_repos || return 1
            local values_file
            values_file=$(render_manifest "${MANIFESTS_DIR}/argocd/values.yaml")
            upgrade_helm_release "${ARGOCD_RELEASE}" \
                "${ARGOCD_REPO_NAME}/argo-cd" \
                "${ARGOCD_NAMESPACE}" \
                "${values_file}" || {
                rm -f "${values_file}"
                log_error "Failed to upgrade ArgoCD"
                return 1
            }
            rm -f "${values_file}"
            log_ok "ArgoCD upgraded"
            ;;
        vault)
            log_step "Upgrading Vault..."
            update_helm_repos || return 1
            local values_file
            values_file=$(render_manifest "${MANIFESTS_DIR}/vault/values.yaml")
            upgrade_helm_release "${VAULT_RELEASE}" \
                "${VAULT_REPO_NAME}/vault" \
                "${VAULT_NAMESPACE}" \
                "${values_file}" || {
                rm -f "${values_file}"
                log_error "Failed to upgrade Vault"
                return 1
            }
            rm -f "${values_file}"
            log_ok "Vault upgraded"
            ;;
        *)
            log_error "Unknown app: ${app}"
            log_error "Valid apps: kube, argocd, vault"
            return 1
            ;;
    esac

    return 0
}

update_ingress() {
    local app="${1:-all}"
    local rc=0

    _update_kube_ingress() {
        log_step "Updating Dashboard ingress..."
        local rendered
        rendered=$(render_manifest "${MANIFESTS_DIR}/kube/ingress.yaml")
        kubectl apply -f "${rendered}" --request-timeout=30s || {
            rm -f "${rendered}"
            log_error "Failed to apply Dashboard ingress"
            return 1
        }
        rm -f "${rendered}"
        log_ok "Dashboard ingress updated (https://${KUBE_HOST})"
    }

    _update_argocd_ingress() {
        log_step "Updating ArgoCD ingress..."
        local rendered
        rendered=$(render_manifest "${MANIFESTS_DIR}/argocd/values.yaml")
        upgrade_helm_release "${ARGOCD_RELEASE}" \
            "${ARGOCD_REPO_NAME}/argo-cd" \
            "${ARGOCD_NAMESPACE}" \
            "${rendered}" || {
            rm -f "${rendered}"
            log_error "Failed to update ArgoCD ingress"
            return 1
        }
        rm -f "${rendered}"
        log_ok "ArgoCD ingress updated (https://${ARGOCD_HOST})"
    }

    _update_vault_ingress() {
        log_step "Updating Vault ingress..."
        # ServersTransport (host-independent) — re-apply in case it was lost.
        kubectl apply -f "${MANIFESTS_DIR}/vault/serverstransport.yaml" --request-timeout=30s \
            || log_warn "Failed to apply Vault ServersTransport"
        local rendered_cert rendered_route
        rendered_cert=$(render_manifest "${MANIFESTS_DIR}/vault/certificate.yaml")
        kubectl apply -f "${rendered_cert}" --request-timeout=30s \
            || log_warn "Failed to apply Vault certificate"
        rm -f "${rendered_cert}"
        rendered_route=$(render_manifest "${MANIFESTS_DIR}/vault/ingressroute.yaml")
        kubectl apply -f "${rendered_route}" --request-timeout=30s \
            || log_warn "Failed to apply Vault IngressRoute"
        rm -f "${rendered_route}"
        log_ok "Vault ingress updated (https://${VAULT_HOST})"
    }

    case "${app}" in
        kube)
            _update_kube_ingress || rc=1
            ;;
        argocd)
            _update_argocd_ingress || rc=1
            ;;
        vault)
            _update_vault_ingress || rc=1
            ;;
        all)
            log_step "Updating ingress for all apps..."
            _update_kube_ingress || rc=1
            _update_argocd_ingress || rc=1
            _update_vault_ingress || rc=1
            ;;
        *)
            log_error "Unknown app: ${app}"
            log_error "Valid apps: kube, argocd, vault, all"
            return 1
            ;;
    esac

    return $rc
}
