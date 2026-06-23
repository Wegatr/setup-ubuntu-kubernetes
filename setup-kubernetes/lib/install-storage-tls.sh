#!/usr/bin/env bash
# lib/install-storage-tls.sh — hostpath storage symlink + default StorageClass
# patching, and the cert-manager ClusterIssuer install (with a retry path for
# stuck ACME registration after pod restart).
#
# Globals consumed: STORAGE_PATH, STORAGE_DIRECTORY, MICROK8S_STORAGE_PATH,
#                   FORCE_INSTALL, CLUSTER_ISSUER_NAME, ACME_SERVER,
#                   LETSENCRYPT_EMAIL, STATE_DIR.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/install-storage-tls.sh requires common-kubernetes.sh" >&2; exit 1; }

configure_hostpath_storage() {
    log_step "Configuring hostpath storage..."

    # If no external storage path configured, skip symlink — just ensure default storage class
    if [[ -z "${STORAGE_PATH}" ]]; then
        log_info "No external storage path configured, using default MicroK8s hostpath"
    else
        # Verify storage path is mounted
        if ! check_storage_mount; then
            log_error "Storage path ${STORAGE_PATH} is not properly mounted"
            return 1
        fi

        # Create storage directory if it doesn't exist
        if [[ ! -d "${STORAGE_DIRECTORY}" ]]; then
            log_info "Creating storage directory: ${STORAGE_DIRECTORY}"
            mkdir -p "${STORAGE_DIRECTORY}" || {
                log_error "Failed to create storage directory"
                return 1
            }
            chmod 755 "${STORAGE_DIRECTORY}"
        else
            log_ok "Storage directory already exists: ${STORAGE_DIRECTORY}"
        fi

        # Check if symlink exists and points correctly
        if [[ -L "${MICROK8S_STORAGE_PATH}" ]]; then
            local current_target=$(readlink -f "${MICROK8S_STORAGE_PATH}")
            if [[ "${current_target}" == "${STORAGE_DIRECTORY}" ]]; then
                log_ok "Symlink already configured correctly"
            else
                if [[ "${FORCE_INSTALL}" == "true" ]]; then
                    log_warn "Symlink points to wrong location, fixing..."
                    rm -f "${MICROK8S_STORAGE_PATH}"
                else
                    log_ok "Symlink exists but points to: ${current_target}"
                    log_ok "Skipping symlink creation (use --force to reconfigure)"
                fi
            fi
        fi

        # Backup and create symlink if not exists
        if [[ ! -L "${MICROK8S_STORAGE_PATH}" ]]; then
            if [[ -d "${MICROK8S_STORAGE_PATH}" ]]; then
                local backup="${MICROK8S_STORAGE_PATH}.orig.$(date +%Y%m%d_%H%M%S)"
                log_info "Backing up original storage directory to: ${backup}"
                mv "${MICROK8S_STORAGE_PATH}" "${backup}" || {
                    log_error "Failed to backup original storage directory"
                    return 1
                }
            fi

            log_info "Creating symlink: ${MICROK8S_STORAGE_PATH} -> ${STORAGE_DIRECTORY}"
            ln -sf "${STORAGE_DIRECTORY}" "${MICROK8S_STORAGE_PATH}" || {
                log_error "Failed to create symlink"
                return 1
            }
        fi
    fi

    # Set default storage class (detect actual name from cluster)
    if ! is_default_storage_class_set; then
        local sc_name
        sc_name=$(microk8s kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "${sc_name}" ]]; then
            log_info "Setting '${sc_name}' as default storage class..."
            microk8s kubectl patch storageclass "${sc_name}" \
                -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || {
                log_warn "Failed to set default storage class (may need to retry)"
            }
        else
            log_warn "No storage class found yet (hostpath-storage addon may still be initializing)"
        fi
    else
        log_ok "Default storage class already set"
    fi

    log_ok "Storage configured successfully"
    return 0
}

configure_cert_manager() {
    log_step "Configuring cert-manager..."

    # Wait for cert-manager to be ready
    wait_for_cert_manager_ready || {
        log_error "Cert-manager is not ready"
        return 1
    }

    # Check if ClusterIssuer already exists
    if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
        if [[ "${FORCE_INSTALL}" == "true" ]]; then
            log_warn "ClusterIssuer already exists, forcing reconfiguration..."
            microk8s kubectl delete clusterissuer "${CLUSTER_ISSUER_NAME}" || {
                log_warn "Failed to delete existing ClusterIssuer"
            }
        else
            log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' already configured and ready"
            return 0
        fi
    fi

    # Empty LETSENCRYPT_EMAIL → local self-signed CA mode (no ACME / internet needed).
    # Used for *.local domains where Let's Encrypt cannot issue certificates.
    if [[ -z "${LETSENCRYPT_EMAIL:-}" ]]; then
        configure_local_ca
        return
    fi

    # Create ClusterIssuer YAML
    local issuer_yaml="${STATE_DIR}/clusterissuer.yaml"
    cat > "${issuer_yaml}" << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CLUSTER_ISSUER_NAME}
spec:
  acme:
    server: ${ACME_SERVER}
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          ingressClassName: public
EOF

    # Apply ClusterIssuer
    log_info "Creating ClusterIssuer: ${CLUSTER_ISSUER_NAME}"
    microk8s kubectl apply -f "${issuer_yaml}" || {
        log_error "Failed to create ClusterIssuer"
        return 1
    }

    # Wait for ClusterIssuer to be ready
    local elapsed=0
    local timeout=60
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
            log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    # ClusterIssuer not ready — likely cert-manager pod has stale network state.
    # Restart cert-manager pods and retry.
    log_warn "ClusterIssuer not ready, restarting cert-manager pods and retrying..."
    microk8s kubectl rollout restart deployment -n cert-manager 2>/dev/null || true
    sleep 15

    # Delete and re-apply ClusterIssuer to trigger fresh registration
    microk8s kubectl delete clusterissuer "${CLUSTER_ISSUER_NAME}" --ignore-not-found 2>/dev/null || true
    sleep 5
    microk8s kubectl apply -f "${issuer_yaml}" || {
        log_error "Failed to re-create ClusterIssuer"
        return 1
    }

    # Wait again
    elapsed=0
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
            log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is ready (after retry)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_warn "ClusterIssuer created but not ready yet (this may take a few moments)"
    return 0
}

# Create a self-signed local CA and a CA-type ClusterIssuer for *.local domains.
# Called by configure_cert_manager() when LETSENCRYPT_EMAIL is empty.
configure_local_ca() {
    local mdir="${SCRIPT_DIR}/manifests/local-ca"
    log_step "Creating self-signed local CA (ClusterIssuer: ${CLUSTER_ISSUER_NAME})..."

    # 1. selfSigned bootstrapper (issues the CA cert below)
    microk8s kubectl apply -f "${mdir}/clusterissuer-selfsigned.yaml" || {
        log_error "Failed to create selfsigned-bootstrapper ClusterIssuer"
        return 1
    }
    sleep 5

    # 2. CA Certificate (stored in cert-manager namespace as local-ca-tls Secret)
    microk8s kubectl apply -f "${mdir}/certificate-ca.yaml" || {
        log_error "Failed to create local CA Certificate"
        return 1
    }

    log_info "Waiting for CA certificate Secret (local-ca-tls) to appear..."
    local elapsed=0
    while [[ ${elapsed} -lt 120 ]]; do
        if microk8s kubectl -n cert-manager get secret local-ca-tls &>/dev/null; then
            log_ok "CA certificate Secret ready"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    if ! microk8s kubectl -n cert-manager get secret local-ca-tls &>/dev/null; then
        log_error "CA certificate Secret did not appear within 120s"
        return 1
    fi

    # 3. CA-type ClusterIssuer that signs all platform Ingress/Certificate resources
    microk8s kubectl apply -f "${mdir}/clusterissuer-local-ca.yaml" || {
        log_error "Failed to create local-ca ClusterIssuer"
        return 1
    }

    elapsed=0
    while [[ ${elapsed} -lt 60 ]]; do
        if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
            log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' (local CA) is ready"
            log_info "Extract CA cert to install in browsers/OS:"
            log_info "  microk8s kubectl -n cert-manager get secret local-ca-tls \\"
            log_info "    -o jsonpath='{.data.ca\\.crt}' | base64 -d > local-ca.crt"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    log_warn "ClusterIssuer '${CLUSTER_ISSUER_NAME}' created but not ready yet (may take a moment)"
    return 0
}
