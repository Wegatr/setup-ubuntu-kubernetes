#!/usr/bin/env bash
# lib/preflight.sh — Pre-flight validation + the load-bearing DNS guard +
# iptables backend detection used by Calico alignment.
#
# Globals consumed: DOMAIN_SUFFIX, LETSENCRYPT_EMAIL, DEPLOY_ENV,
#                   ENABLE_KUBE/ARGOCD/VAULT, KUBE_HOST, ARGOCD_HOST, VAULT_HOST.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/preflight.sh requires common-kubernetes.sh" >&2; exit 1; }

validate_config() {
    local warnings=0
    if [[ "${DOMAIN_SUFFIX}" == "example.com" ]]; then
        log_warn "DOMAIN_SUFFIX is still 'example.com' -- update your config file"
        warnings=$((warnings + 1))
    fi
    if [[ "${LETSENCRYPT_EMAIL}" == "user@example.com" ]]; then
        log_warn "LETSENCRYPT_EMAIL is still 'user@example.com' -- update your config file"
        warnings=$((warnings + 1))
    fi
    if [[ ${warnings} -gt 0 ]]; then
        log_warn "Config validation found ${warnings} warning(s)"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Pre-flight DNS check before deploying any infrastructure app. cert-manager's
# HTTP-01 challenge runs a self-check that resolves the ingress hostname via
# CoreDNS → public upstream resolvers; if the name doesn't resolve, the
# Challenge stays "pending" forever and the per-app deploy_* functions
# eventually time out and save a failure placeholder to ~/secrets/<app>-<env>.txt
# (most importantly: vault never gets initialized, so the unseal keys are lost).
#
# Fail fast here with the host's detected public IPv4 so the user can fix DNS
# before anything else runs.
check_ingress_dns_resolves() {
    local public_ipv4
    public_ipv4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || true)

    local unresolved=()
    if [[ "${ENABLE_IDP:-true}" == "true" ]] && ! getent hosts "${IDP_HOST}" &>/dev/null; then
        unresolved+=("${IDP_HOST}")
    fi
    if [[ "${ENABLE_KUBE}" == "true" ]] && ! getent hosts "${KUBE_HOST}" &>/dev/null; then
        unresolved+=("${KUBE_HOST}")
    fi
    if [[ "${ENABLE_ARGOCD}" == "true" ]] && ! getent hosts "${ARGOCD_HOST}" &>/dev/null; then
        unresolved+=("${ARGOCD_HOST}")
    fi
    if [[ "${ENABLE_VAULT}" == "true" ]] && ! getent hosts "${VAULT_HOST}" &>/dev/null; then
        unresolved+=("${VAULT_HOST}")
    fi

    if [[ ${#unresolved[@]} -eq 0 ]]; then
        log_ok "Ingress hostnames resolve in public DNS"
        return 0
    fi

    log_error "Ingress hostnames are NOT resolvable in public DNS:"
    for h in "${unresolved[@]}"; do
        log_error "  - ${h}"
    done
    log_error ""
    log_error "cert-manager's HTTP-01 challenge will hang indefinitely without these records."
    log_error "Aborting before deploy_vault saves an 'Initialization failed' placeholder over"
    log_error "the unseal keys that would otherwise be irrecoverable."
    log_error ""
    log_error "Fix: at your DNS provider, add an A record for each name (or a wildcard"
    log_error "*.${DEPLOY_ENV}.${DOMAIN_SUFFIX}) pointing to this host's public IPv4:"
    if [[ -n "${public_ipv4}" ]]; then
        log_error "  Public IPv4 (detected): ${public_ipv4}"
    else
        log_error "  (could not auto-detect public IPv4 — check from elsewhere with: curl ifconfig.me)"
    fi
    log_error ""
    log_error "After adding the record, wait ~1-5 min for propagation, then re-run."
    log_error "If the records exist but your LAN's DNS hasn't picked them up yet, verify with:"
    log_error "  dig +short A ${unresolved[0]} @1.1.1.1"
    return 1
}

# Detect the host's default iptables backend (nft or legacy).
# Returns "nft" if detection fails — modern default and safer fallback.
# Used by align_calico_backend to decide which Felix backend to pin.
detect_host_iptables_backend() {
    local target=""
    [[ -L /etc/alternatives/iptables ]] && target=$(readlink -f /etc/alternatives/iptables 2>/dev/null)
    [[ -z "${target}" ]] && target=$(readlink -f "$(command -v iptables 2>/dev/null)" 2>/dev/null)
    case "${target}" in
        *iptables-legacy*) echo "legacy" ;;
        *)                 echo "nft" ;;
    esac
}

# Interactive confirmation prompt shown before MicroK8s installation runs.
# Lists every step the script is about to take, marks [SKIP] for steps that
# are already done. Asks the user to press y to proceed.
show_summary() {
    log_step "=== Installation Summary ==="
    log_info "The following components will be installed/configured:"
    echo

    if [[ "${INSTALL_MICROK8S}" == "true" ]]; then
        if is_microk8s_installed && [[ "${FORCE_INSTALL}" != "true" ]]; then
            log_ok "  [SKIP] MicroK8s (already installed: $(get_microk8s_version))"
        else
            log_info "  [INSTALL] MicroK8s (channel: ${MICROK8S_CHANNEL})"
        fi
    fi

    if [[ "${CONFIGURE_STORAGE}" == "true" ]]; then
        if is_storage_configured && [[ "${FORCE_INSTALL}" != "true" ]]; then
            log_ok "  [SKIP] Storage configuration (already configured)"
        else
            if [[ -n "${STORAGE_PATH}" ]]; then
                log_info "  [CONFIGURE] Storage (path: ${STORAGE_PATH})"
            else
                log_info "  [CONFIGURE] Storage (default MicroK8s hostpath)"
            fi
        fi
    fi

    if [[ "${CONFIGURE_CERT_MANAGER}" == "true" ]]; then
        if is_cluster_issuer_ready && [[ "${FORCE_INSTALL}" != "true" ]]; then
            log_ok "  [SKIP] Cert-Manager (already configured)"
        else
            log_info "  [CONFIGURE] Cert-Manager (ClusterIssuer: ${CLUSTER_ISSUER_NAME})"
        fi
    fi

    if [[ "${INSTALL_CLI_TOOLS}" == "true" ]]; then
        log_info "  [INSTALL] CLI Tools:"
        for tool in argocd vault yq jq tailscale; do
            if is_cli_tool_installed "${tool}" && [[ "${FORCE_INSTALL}" != "true" ]]; then
                log_ok "    - ${tool} (already installed: $(get_cli_tool_version ${tool}))"
            else
                log_info "    - ${tool}"
            fi
        done
    fi

    if [[ "${SETUP_ALIASES}" == "true" ]]; then
        if verify_kubectl_alias && verify_helm_alias && [[ "${FORCE_INSTALL}" != "true" ]]; then
            log_ok "  [SKIP] Aliases (already configured)"
        else
            log_info "  [CONFIGURE] Kubectl and Helm aliases"
        fi
    fi

    echo
    read -p "Proceed with installation? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Installation cancelled by user"
        exit 0
    fi
}
