#!/usr/bin/env bash
# lib/deploy-idp.sh — Authentik (Identity Provider) deploy.
#
# Authentik is the platform IdP. It lives at the same tier as ArgoCD /
# Headlamp / Vault — managed by THIS install script, NOT by ArgoCD GitOps.
# Reason: ArgoCD itself authenticates via Authentik. If Authentik were in
# the GitOps tree, a broken Authentik = locked out of ArgoCD = no way to
# fix Authentik. So bootstrap order is: cluster → cert-manager → Authentik
# → ArgoCD → GitOps reconciles.
#
# What this function does:
#   1. Generate first-time secrets (admin password, secret_key, 4 OIDC
#      client_secrets, postgres+redis passwords) and save them all to
#      ~/secrets/idp-<env>.txt. On re-run, READ them back from that file so
#      no values rotate.
#   2. Create a ConfigMap from manifests/idp/blueprints/*.yaml (mounted
#      into Authentik pods at /blueprints/local; auto-applied at startup).
#   3. Create a K8s Secret `idp-bootstrap` in the idp namespace that
#      Authentik server + worker mount via envFrom. The Blueprint engine
#      resolves ${IDP_*} variables from this env at startup.
#   4. helm install/upgrade the upstream authentik/authentik chart with our
#      rendered values.yaml.
#   5. Apply the Certificate + IngressRoute (Traefik CRD) and Middleware.
#   6. Create per-consumer K8s Secrets (argocd-oidc in argocd ns,
#      authentik-oidc in kubernetes-dashboard ns, vault-oidc in vault ns)
#      so the next deploy-{argocd,kube,vault} runs find them ready.
#
# Globals consumed: ENABLE_IDP, FORCE_DEPLOY, MANIFESTS_DIR,
#                   IDP_REPO_NAME, IDP_REPO_URL,
#                   IDP_NAMESPACE, IDP_RELEASE, IDP_HOST,
#                   IDP_BOOTSTRAP_EMAIL,
#                   DEPLOY_ENV, DOMAIN_SUFFIX, CREDENTIALS_DIR,
#                   MICROK8S_USER.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/deploy-idp.sh requires common-kubernetes.sh" >&2; exit 1; }

# Generate or recover Authentik secrets. Sets the IDP_*_GENERATED env vars
# used to render values.yaml + idp-bootstrap Secret. Re-runnable: if the
# credentials file from a previous install exists, we read those values
# back so secrets DON'T rotate (rotating secret_key would invalidate all
# existing OIDC sessions + JWT signatures).
_idp_generate_or_load_secrets() {
    local cred_file="${CREDENTIALS_DIR}/idp-${DEPLOY_ENV}.txt"

    if [[ -f "${cred_file}" ]]; then
        log_info "Found existing ${cred_file} — reading current values"
        # Parse "Key: value" lines (matches save_credential's output format).
        # Tolerate leading whitespace and arbitrary suffix.
        IDP_SECRET_KEY=$(awk -F': ' '/^Secret key:/{print $2}' "${cred_file}")
        IDP_BOOTSTRAP_PASSWORD=$(awk -F': ' '/^Admin password:/{print $2}' "${cred_file}")
        IDP_POSTGRES_PASSWORD=$(awk -F': ' '/^Postgres password:/{print $2}' "${cred_file}")
        IDP_REDIS_PASSWORD=$(awk -F': ' '/^Redis password:/{print $2}' "${cred_file}")
        IDP_ARGOCD_CLIENT_SECRET=$(awk -F': ' '/^ArgoCD client_secret:/{print $2}' "${cred_file}")
        IDP_GRAFANA_CLIENT_SECRET=$(awk -F': ' '/^Grafana client_secret:/{print $2}' "${cred_file}")
        IDP_HEADLAMP_CLIENT_SECRET=$(awk -F': ' '/^Headlamp client_secret:/{print $2}' "${cred_file}")
        IDP_VAULT_CLIENT_SECRET=$(awk -F': ' '/^Vault client_secret:/{print $2}' "${cred_file}")
    fi

    # Fill any blanks with freshly-generated random values. On first install
    # everything is blank; on re-runs only NEW additions get generated.
    [[ -z "${IDP_SECRET_KEY:-}" ]]              && IDP_SECRET_KEY=$(openssl rand -hex 32)
    [[ -z "${IDP_BOOTSTRAP_PASSWORD:-}" ]]      && IDP_BOOTSTRAP_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_POSTGRES_PASSWORD:-}" ]]       && IDP_POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_REDIS_PASSWORD:-}" ]]          && IDP_REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_ARGOCD_CLIENT_SECRET:-}" ]]    && IDP_ARGOCD_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_GRAFANA_CLIENT_SECRET:-}" ]]   && IDP_GRAFANA_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_HEADLAMP_CLIENT_SECRET:-}" ]]  && IDP_HEADLAMP_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    [[ -z "${IDP_VAULT_CLIENT_SECRET:-}" ]]     && IDP_VAULT_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

    # Always (re-)write the credentials file so the latest set is on disk.
    save_credential "idp" \
        "URL: https://${IDP_HOST}" \
        "Admin email: ${IDP_BOOTSTRAP_EMAIL}" \
        "Admin user: akadmin" \
        "Admin password: ${IDP_BOOTSTRAP_PASSWORD}" \
        "" \
        "Secret key: ${IDP_SECRET_KEY}" \
        "Postgres password: ${IDP_POSTGRES_PASSWORD}" \
        "Redis password: ${IDP_REDIS_PASSWORD}" \
        "" \
        "ArgoCD client_secret: ${IDP_ARGOCD_CLIENT_SECRET}" \
        "Grafana client_secret: ${IDP_GRAFANA_CLIENT_SECRET}" \
        "Headlamp client_secret: ${IDP_HEADLAMP_CLIENT_SECRET}" \
        "Vault client_secret: ${IDP_VAULT_CLIENT_SECRET}"
}

# Create the idp-bootstrap Secret in the idp namespace. The Authentik
# server + worker pods mount this via envFrom — env vars become available
# in blueprint string interpolation as ${IDP_*}.
_idp_apply_bootstrap_secret() {
    kubectl -n "${IDP_NAMESPACE}" create secret generic idp-bootstrap \
        --from-literal=IDP_ENV="${DEPLOY_ENV}" \
        --from-literal=IDP_DOMAIN="${DOMAIN_SUFFIX}" \
        --from-literal=IDP_HOST="${IDP_HOST}" \
        --from-literal=IDP_ARGOCD_CLIENT_SECRET="${IDP_ARGOCD_CLIENT_SECRET}" \
        --from-literal=IDP_GRAFANA_CLIENT_SECRET="${IDP_GRAFANA_CLIENT_SECRET}" \
        --from-literal=IDP_HEADLAMP_CLIENT_SECRET="${IDP_HEADLAMP_CLIENT_SECRET}" \
        --from-literal=IDP_VAULT_CLIENT_SECRET="${IDP_VAULT_CLIENT_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Create the idp-blueprints ConfigMap from manifests/idp/blueprints/*.yaml.
# Each file becomes one key in the ConfigMap; Authentik pods auto-load
# every file under /blueprints/local at startup.
_idp_apply_blueprints_configmap() {
    local blueprints_dir="${MANIFESTS_DIR}/idp/blueprints"
    if [[ ! -d "${blueprints_dir}" ]]; then
        log_error "Blueprints directory not found: ${blueprints_dir}"
        return 1
    fi
    kubectl -n "${IDP_NAMESPACE}" create configmap idp-blueprints \
        --from-file="${blueprints_dir}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Create per-consumer K8s Secrets that deploy-{argocd,kube,vault} read at
# their respective install/upgrade steps. Each lives in the consumer's own
# namespace (which may not exist yet on a totally fresh install — we
# create it first; idempotent).
_idp_apply_consumer_oidc_secrets() {
    # ArgoCD: 'argocd-oidc' Secret with the clientSecret key. ArgoCD's
    # configs.cm.oidc.config reads it via $secret:field substitution.
    create_namespace_if_not_exists argocd >/dev/null
    kubectl -n argocd create secret generic argocd-oidc \
        --from-literal=clientSecret="${IDP_ARGOCD_CLIENT_SECRET}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Headlamp: 'headlamp-oidc' in kubernetes-dashboard namespace. The
    # Headlamp Helm values reference its keys via valueFrom.secretKeyRef.
    create_namespace_if_not_exists kubernetes-dashboard >/dev/null
    kubectl -n kubernetes-dashboard create secret generic headlamp-oidc \
        --from-literal=clientID=headlamp \
        --from-literal=clientSecret="${IDP_HEADLAMP_CLIENT_SECRET}" \
        --from-literal=issuerURL="https://${IDP_HOST}/application/o/headlamp/" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Vault: 'vault-oidc' Secret consumed by enable_vault_oidc() in
    # deploy-vault.sh (read via kubectl exec into vault-0).
    create_namespace_if_not_exists vault >/dev/null
    kubectl -n vault create secret generic vault-oidc \
        --from-literal=clientID=vault \
        --from-literal=clientSecret="${IDP_VAULT_CLIENT_SECRET}" \
        --from-literal=issuerURL="https://${IDP_HOST}/application/o/vault/" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

deploy_idp() {
    if [[ "${ENABLE_IDP:-true}" != "true" ]]; then
        log_warn "IdP (Authentik) is disabled in config, skipping"
        return 0
    fi

    log_step "Deploying IdP (Authentik)..."

    add_helm_repo "${IDP_REPO_NAME}" "${IDP_REPO_URL}" || return 1
    update_helm_repos || return 1
    create_namespace_if_not_exists "${IDP_NAMESPACE}" || return 1

    # Generate-or-load all the random values, save to ~/secrets/idp-<env>.txt.
    _idp_generate_or_load_secrets

    # Mount the secrets + env for Blueprint interpolation.
    _idp_apply_bootstrap_secret || { log_error "Failed to apply idp-bootstrap secret"; return 1; }

    # Mount the 7 blueprint YAMLs.
    _idp_apply_blueprints_configmap || { log_error "Failed to apply idp-blueprints ConfigMap"; return 1; }

    # Render Helm values (substitutes __IDP_*__ placeholders).
    local values_file
    values_file=$(render_manifest "${MANIFESTS_DIR}/idp/values.yaml")

    # Pattern (vault-style): never skip — Helm upgrade is idempotent + the
    # only way to push values changes (new chart version, tweaked replicas).
    if is_helm_release_deployed "${IDP_RELEASE}" "${IDP_NAMESPACE}"; then
        log_info "IdP already deployed — running helm upgrade to apply any values changes"
    fi

    install_helm_chart "${IDP_RELEASE}" \
        "${IDP_REPO_NAME}/authentik" \
        "${IDP_NAMESPACE}" \
        "${values_file}" || {
        rm -f "${values_file}"
        log_error "Failed to deploy IdP (Authentik)"
        return 1
    }
    rm -f "${values_file}"

    # Wait for the Authentik server pod to become ready before we apply
    # the IngressRoute (cert-manager won't issue a cert against a non-
    # responding backend; better to fail Service first than confusing
    # cert errors later).
    wait_for_pods_ready "${IDP_NAMESPACE}" "app.kubernetes.io/component=server" || {
        log_warn "IdP server pod not ready yet — will continue, may need re-run after pod stabilizes"
    }

    # Apply the public route (cert + IngressRoute).
    local ingressroute_file
    ingressroute_file=$(render_manifest "${MANIFESTS_DIR}/idp/ingressroute.yaml")
    log_info "Applying IdP IngressRoute..."
    kubectl apply -f "${ingressroute_file}" --request-timeout=30s || {
        rm -f "${ingressroute_file}"
        log_error "Failed to apply IdP IngressRoute"
        return 1
    }
    rm -f "${ingressroute_file}"

    # Apply the forwardAuth Middleware (cross-ns ref'd by gated apps).
    kubectl apply -f "${MANIFESTS_DIR}/idp/middleware-forwardauth.yaml" --request-timeout=30s || {
        log_warn "Failed to apply IdP forwardauth Middleware"
    }

    # Wait for the LE cert.
    wait_for_certificate_ready "${IDP_NAMESPACE}" "idp-tls" || {
        log_warn "IdP certificate not ready yet (may take a few minutes)"
    }

    # Pre-create the per-consumer K8s Secrets so deploy-argocd / deploy-kube
    # / deploy-vault find them ready when they run later in --deploy-all.
    _idp_apply_consumer_oidc_secrets

    log_ok "IdP (Authentik) deployed successfully"
    log_info "Access at: https://${IDP_HOST}"
    log_info "Admin user: akadmin (password in ${CREDENTIALS_DIR}/idp-${DEPLOY_ENV}.txt)"
    return 0
}
