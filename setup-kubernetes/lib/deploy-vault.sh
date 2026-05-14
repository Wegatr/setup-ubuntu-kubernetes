#!/usr/bin/env bash
# lib/deploy-vault.sh — Vault Helm install + Traefik IngressRoute + the
# load-bearing init/unseal flow with the exec-ability probe that prevents
# clobbering an existing credentials file when vault-0 is stuck.
#
# Globals consumed: ENABLE_VAULT, FORCE_DEPLOY, MANIFESTS_DIR,
#                   VAULT_REPO_NAME, VAULT_REPO_URL,
#                   VAULT_NAMESPACE, VAULT_RELEASE, VAULT_HOST,
#                   DEPLOY_ENV, CREDENTIALS_DIR.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/deploy-vault.sh requires common-kubernetes.sh" >&2; exit 1; }

deploy_vault() {
    if [[ "${ENABLE_VAULT}" != "true" ]]; then
        log_warn "Vault is disabled in config, skipping"
        return 0
    fi

    log_step "Deploying Vault..."

    # Add Helm repo
    add_helm_repo "${VAULT_REPO_NAME}" "${VAULT_REPO_URL}" || return 1

    # Update repos
    update_helm_repos || return 1

    # Create namespace
    create_namespace_if_not_exists "${VAULT_NAMESPACE}" || return 1

    # Check if already deployed. We deliberately do NOT return early here
    # (unlike deploy_kube / deploy_argocd) because the init+unseal step that
    # runs further down is the only place where the root token and unseal
    # keys ever exist — if init was blocked on a previous run (e.g. TLS Secret
    # missing → vault-0 stuck in ContainerCreating → kubectl exec failed),
    # the Helm release exists but Vault is uninitialized. We need to fall
    # through to the init check so a re-run of --deploy-all unblocks it.
    local skip_helm_install=false
    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        if [[ "${FORCE_DEPLOY}" == "true" ]]; then
            log_warn "Vault already deployed, forcing upgrade..."
        else
            log_ok "Vault Helm release already deployed — skipping install, will verify init status"
            skip_helm_install=true
        fi
    fi

    if [[ "${skip_helm_install}" != "true" ]]; then
        # Deploy with Helm (rendered with current environment hostnames)
        local values_file
        values_file=$(render_manifest "${MANIFESTS_DIR}/vault/values.yaml")
        install_helm_chart "${VAULT_RELEASE}" \
            "${VAULT_REPO_NAME}/vault" \
            "${VAULT_NAMESPACE}" \
            "${values_file}" || {
            rm -f "${values_file}"
            log_error "Failed to deploy Vault"
            return 1
        }
        rm -f "${values_file}"
    fi

    # Apply ServersTransport (Traefik CRD — skips backend TLS verification so
    # Traefik can talk to Vault's HTTPS listener that has a different cert).
    local transport_file="${MANIFESTS_DIR}/vault/serverstransport.yaml"
    log_info "Applying Vault ServersTransport..."
    kubectl apply -f "${transport_file}" --request-timeout=30s || {
        log_warn "Failed to apply Vault ServersTransport"
    }

    # Apply certificate (rendered with current environment hostnames)
    local cert_file
    cert_file=$(render_manifest "${MANIFESTS_DIR}/vault/certificate.yaml")
    log_info "Applying Vault certificate..."
    kubectl apply -f "${cert_file}" --request-timeout=30s || {
        log_warn "Failed to apply Vault certificate"
    }
    rm -f "${cert_file}"

    # Apply IngressRoute (Traefik CRD, rendered with current env hostnames)
    local ingressroute_file
    ingressroute_file=$(render_manifest "${MANIFESTS_DIR}/vault/ingressroute.yaml")
    log_info "Applying Vault IngressRoute..."
    kubectl apply -f "${ingressroute_file}" --request-timeout=30s || {
        rm -f "${ingressroute_file}"
        log_error "Failed to apply Vault IngressRoute"
        return 1
    }
    rm -f "${ingressroute_file}"

    # Wait for deployment
    wait_for_pods_ready "${VAULT_NAMESPACE}" "app.kubernetes.io/name=vault" || {
        log_warn "Vault pods not ready yet"
    }

    # Wait for certificate
    wait_for_certificate_ready "${VAULT_NAMESPACE}" "vault-tls" || {
        log_warn "Certificate not ready yet (may take a few minutes)"
    }

    # Initialize Vault (only if not already initialized).
    log_info "Checking Vault initialization status..."

    # Make sure vault-0 is actually exec-able before trying to talk to it.
    # Without this guard, a stuck pod (e.g. waiting for vault-tls Secret) would
    # let `kubectl exec` fail silently, the init JSON would come back empty,
    # and we'd save an "Initialization failed" placeholder to the credentials
    # file — losing the keys forever on the next successful init attempt that
    # would otherwise overwrite the placeholder.
    if ! kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- /bin/true &>/dev/null; then
        log_warn "vault-0 is not exec-able yet (pod likely waiting for vault-tls Secret)."
        log_warn "Skipping init. Once the certificate is issued and vault-0 is Running,"
        log_warn "re-run: sudo ./setup-kubernetes.sh --${DEPLOY_ENV} --deploy-vault"
        log_warn "Diagnose with: kubectl describe pod -n ${VAULT_NAMESPACE} vault-0"
        return 0
    fi

    local vault_status
    vault_status=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status -tls-skip-verify -format=json 2>/dev/null || true)

    if [[ -n "${vault_status}" ]] && echo "${vault_status}" | jq -e '.initialized == true' &>/dev/null; then
        log_ok "Vault is already initialized"
        # Don't clobber an existing credentials file: if init succeeded on a
        # previous run, the unseal keys are in there and a "Status: Already
        # initialized" placeholder would erase them.
        local existing_cred="${CREDENTIALS_DIR}/vault-${DEPLOY_ENV}.txt"
        if [[ ! -f "${existing_cred}" ]]; then
            save_credential "vault" \
                "URL: https://${VAULT_HOST}" \
                "Status: Already initialized (unseal keys were shown at first init)"
        else
            log_info "Preserving existing credentials file: ${existing_cred}"
        fi
    else
        log_info "Initializing Vault..."
        local init_output
        init_output=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault operator init -tls-skip-verify -format=json 2>/dev/null)

        if [[ -z "${init_output}" ]]; then
            log_error "Failed to initialize Vault"
            save_credential "vault" \
                "URL: https://${VAULT_HOST}" \
                "Status: Initialization failed — run manually:" \
                "  kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault operator init -tls-skip-verify"
        else
            # Extract keys and root token
            local root_token
            root_token=$(echo "${init_output}" | jq -r '.root_token')
            local unseal_keys
            unseal_keys=$(echo "${init_output}" | jq -r '.unseal_keys_b64[]')

            local key_lines=()
            local key_num=1
            while IFS= read -r key; do
                key_lines+=("Unseal Key ${key_num}: ${key}")
                key_num=$((key_num + 1))
            done <<< "${unseal_keys}"

            save_credential "vault" \
                "URL: https://${VAULT_HOST}" \
                "" \
                "${key_lines[@]}" \
                "" \
                "Root Token: ${root_token}" \
                "" \
                "To unseal Vault, run 3 of the 5 unseal keys:" \
                "  kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault operator unseal -tls-skip-verify <KEY>"

            log_ok "Vault initialized — unseal keys and root token saved"
            log_info "Root Token: ${root_token}"
            log_warn "SAVE THE UNSEAL KEYS! They are required to unseal Vault after restarts."

            # Auto-unseal with the first 3 keys
            log_info "Unsealing Vault..."
            local unseal_count=0
            while IFS= read -r key; do
                if [[ ${unseal_count} -ge 3 ]]; then
                    break
                fi
                kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault operator unseal -tls-skip-verify "${key}" &>/dev/null || {
                    log_warn "Failed to unseal with key $((unseal_count + 1))"
                }
                unseal_count=$((unseal_count + 1))
            done <<< "${unseal_keys}"

            # Verify unsealed
            local sealed
            sealed=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status -tls-skip-verify -format=json 2>/dev/null | jq -r '.sealed')
            if [[ "${sealed}" == "false" ]]; then
                log_ok "Vault is unsealed and ready"
            else
                log_warn "Vault is still sealed — unseal manually with 3 of the 5 keys"
            fi
        fi
    fi

    log_ok "Vault deployed successfully"
    log_info "Access at: https://${VAULT_HOST}"
    return 0
}
