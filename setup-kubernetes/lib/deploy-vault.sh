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

    # Apply the zero-click auto-redirect helper (nginx + ConfigMap + Service)
    # BEFORE the IngressRoute so the Service exists when Traefik resolves
    # the route. Idempotent.
    log_info "Applying Vault auto-redirect helper (zero-click SSO)..."
    kubectl apply -f "${MANIFESTS_DIR}/vault/auto-redirect.yaml" --request-timeout=30s || {
        log_warn "Failed to apply Vault auto-redirect helper — Vault UI still reachable, but the bare hostname won't auto-redirect to Authentik"
    }

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

    # Clean up the legacy Traefik Middleware we used briefly (replaced
    # by the auto-redirect Pod) so the cluster doesn't carry an orphaned
    # CR after a `git pull`. Idempotent: --ignore-not-found means
    # repeated runs are no-ops once it's gone.
    kubectl -n "${VAULT_NAMESPACE}" delete middleware vault-oidc-redirect \
        --ignore-not-found=true >/dev/null 2>&1 || true

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

    # Wire OIDC auth method against the IdP (Authentik). Idempotent: skip if
    # already enabled. Reads client config from the `vault-oidc` K8s Secret
    # pre-created in this namespace by deploy_idp.
    enable_vault_oidc || log_warn "Vault OIDC configuration incomplete (browser UI gates will fall back to token login)"

    log_ok "Vault deployed successfully"
    log_info "Access at: https://${VAULT_HOST}"
    return 0
}

# Enable + configure Vault's OIDC auth method so browser UI logins go
# through Authentik. The Vault HTTP API stays token-driven (unchanged).
#
# Pre-reqs (deploy_idp creates these):
#   - K8s Secret 'vault-oidc' in this namespace with keys clientID,
#     clientSecret, issuerURL.
#   - IdP must be reachable from inside vault-0 (cluster-internal DNS
#     resolves authentik via the regular service mesh; or the public
#     issuerURL works via egress).
#
# Idempotent: if `vault auth list` already shows oidc/, skip the enable
# step. Still re-writes the config + role so values stay in sync with
# the K8s Secret (deploy_idp could have rotated client_secret).
enable_vault_oidc() {
    log_info "Wiring Vault OIDC auth method against the IdP..."

    if ! kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- /bin/true &>/dev/null; then
        log_warn "vault-0 not exec-able yet — skipping OIDC config"
        return 0
    fi

    # Pull the OIDC client config from the K8s Secret deploy_idp created.
    if ! kubectl -n "${VAULT_NAMESPACE}" get secret vault-oidc &>/dev/null; then
        log_warn "vault-oidc Secret not found — run --deploy-idp first to create it"
        return 0
    fi

    local oidc_client_id oidc_client_secret oidc_issuer_url
    oidc_client_id=$(kubectl -n "${VAULT_NAMESPACE}" get secret vault-oidc -o jsonpath='{.data.clientID}' | base64 -d)
    oidc_client_secret=$(kubectl -n "${VAULT_NAMESPACE}" get secret vault-oidc -o jsonpath='{.data.clientSecret}' | base64 -d)
    oidc_issuer_url=$(kubectl -n "${VAULT_NAMESPACE}" get secret vault-oidc -o jsonpath='{.data.issuerURL}' | base64 -d)

    if [[ -z "${oidc_client_id}" || -z "${oidc_client_secret}" || -z "${oidc_issuer_url}" ]]; then
        log_warn "vault-oidc Secret incomplete — skipping OIDC config"
        return 0
    fi

    # The Vault root token lives in ~/secrets/vault-<env>.txt. Parse it.
    local root_token
    root_token=$(awk -F': ' '/^Root Token:/{print $2}' "${CREDENTIALS_DIR}/vault-${DEPLOY_ENV}.txt" 2>/dev/null)
    if [[ -z "${root_token}" ]]; then
        log_warn "Vault root token not found in ${CREDENTIALS_DIR}/vault-${DEPLOY_ENV}.txt — skipping OIDC config"
        return 0
    fi

    # Run the enable + write in one exec to keep VAULT_TOKEN ephemeral.
    kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
        env VAULT_SKIP_VERIFY=true \
            VAULT_ADDR="https://127.0.0.1:8200" \
            VAULT_TOKEN="${root_token}" \
            OIDC_CLIENT_ID="${oidc_client_id}" \
            OIDC_CLIENT_SECRET="${oidc_client_secret}" \
            OIDC_ISSUER_URL="${oidc_issuer_url}" \
            VAULT_HOST_PUB="${VAULT_HOST}" \
        sh -c '
            set -e
            if ! vault auth list 2>/dev/null | grep -q "^oidc/"; then
                vault auth enable oidc
            fi
            # Admin policy — sudo-equivalent on every path. Granted to OIDC
            # users via the default role so a single-operator setup can
            # manage all kv-v2 secrets through the UI. Idempotent: vault
            # policy write overwrites whatever is there. Root token still
            # exists for emergency recovery (~/secrets/vault-<env>.txt).
            cat <<POLICY | vault policy write admin -
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo", "patch"]
}
POLICY
            vault write auth/oidc/config \
                oidc_discovery_url="$OIDC_ISSUER_URL" \
                oidc_client_id="$OIDC_CLIENT_ID" \
                oidc_client_secret="$OIDC_CLIENT_SECRET" \
                default_role="default" >/dev/null
            vault write auth/oidc/role/default \
                bound_audiences="$OIDC_CLIENT_ID" \
                user_claim="preferred_username" \
                oidc_scopes="profile email groups" \
                allowed_redirect_uris="https://${VAULT_HOST_PUB}/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback" \
                policies="admin" >/dev/null
        ' >/dev/null 2>&1 || {
        log_warn "vault auth enable/write oidc failed — check vault-0 logs for details"
        return 1
    }

    log_ok "Vault OIDC method configured (browser UI logs in via the IdP)"
    return 0
}
