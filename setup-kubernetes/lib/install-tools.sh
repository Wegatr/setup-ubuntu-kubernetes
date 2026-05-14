#!/usr/bin/env bash
# lib/install-tools.sh — CLI tools (argocd, vault, yq, jq, tailscale),
# kubectl + helm shell aliases, kubeconfig export for the MICROK8S_USER.
#
# Globals consumed: MICROK8S_USER, FORCE_INSTALL.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/install-tools.sh requires common-kubernetes.sh" >&2; exit 1; }

install_cli_tools() {
    log_step "Installing CLI tools..."

    local failed_tools=()

    # Install prerequisites
    log_info "Ensuring prerequisites (curl, unzip)..."
    apt-get update -qq 2>/dev/null || true
    apt-get install -y curl unzip 2>/dev/null || log_warn "Failed to install some prerequisites"

    # Install jq first (needed by other parts of the script)
    if is_cli_tool_installed "jq" && [[ "${FORCE_INSTALL}" != "true" ]]; then
        log_ok "jq already installed (version: $(get_cli_tool_version jq)), skipping"
    else
        log_info "Installing jq via apt..."
        apt-get install -y jq || {
            log_error "Failed to install jq"
            failed_tools+=("jq")
        }
        is_cli_tool_installed "jq" && log_ok "jq installed (version: $(get_cli_tool_version jq))"
    fi

    # Install argocd
    if is_cli_tool_installed "argocd" && [[ "${FORCE_INSTALL}" != "true" ]]; then
        log_ok "argocd already installed (version: $(get_cli_tool_version argocd)), skipping"
    else
        log_info "Installing argocd CLI..."
        if curl -sSL -o /usr/local/bin/argocd \
            https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64; then
            chmod +x /usr/local/bin/argocd
            log_ok "argocd installed (version: $(get_cli_tool_version argocd))"
        else
            log_error "Failed to download argocd"
            failed_tools+=("argocd")
        fi
    fi

    # Install vault (latest version auto-detected from HashiCorp releases)
    if is_cli_tool_installed "vault" && [[ "${FORCE_INSTALL}" != "true" ]]; then
        log_ok "vault already installed (version: $(get_cli_tool_version vault)), skipping"
    else
        log_info "Detecting latest Vault version..."
        local vault_version
        vault_version=$(curl -sSL https://api.releases.hashicorp.com/v1/releases/vault/latest 2>/dev/null | jq -r '.version')
        if [[ -z "${vault_version}" || "${vault_version}" == "null" ]]; then
            log_error "Failed to detect latest Vault version"
            failed_tools+=("vault")
        else
            log_info "Installing vault CLI (version: ${vault_version})..."
            local vault_zip="/tmp/vault_${vault_version}_linux_amd64.zip"
            if curl -sSL -o "${vault_zip}" \
                "https://releases.hashicorp.com/vault/${vault_version}/vault_${vault_version}_linux_amd64.zip" && \
               unzip -o "${vault_zip}" -d /usr/local/bin/; then
                rm -f "${vault_zip}"
                chmod +x /usr/local/bin/vault
                log_ok "vault installed (version: $(get_cli_tool_version vault))"
            else
                rm -f "${vault_zip}"
                log_error "Failed to install vault"
                failed_tools+=("vault")
            fi
        fi
    fi

    # Install yq (latest version auto-detected from GitHub)
    if is_cli_tool_installed "yq" && [[ "${FORCE_INSTALL}" != "true" ]]; then
        log_ok "yq already installed (version: $(get_cli_tool_version yq)), skipping"
    else
        log_info "Installing yq (latest)..."
        if curl -sSL -o /usr/local/bin/yq \
            "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"; then
            chmod +x /usr/local/bin/yq
            log_ok "yq installed (version: $(get_cli_tool_version yq))"
        else
            log_error "Failed to download yq"
            failed_tools+=("yq")
        fi
    fi

    # Install tailscale
    if is_cli_tool_installed "tailscale" && [[ "${FORCE_INSTALL}" != "true" ]]; then
        log_ok "tailscale already installed (version: $(get_cli_tool_version tailscale)), skipping"
    else
        log_info "Installing Tailscale..."
        if curl -fsSL https://tailscale.com/install.sh | sh; then
            systemctl enable --now tailscaled 2>/dev/null || true
            log_ok "tailscale installed (version: $(get_cli_tool_version tailscale))"
        else
            log_error "Failed to install tailscale"
            failed_tools+=("tailscale")
        fi
    fi

    if [[ ${#failed_tools[@]} -gt 0 ]]; then
        log_warn "Failed to install: ${failed_tools[*]}"
        return 1
    fi

    log_ok "All CLI tools installed successfully"
    return 0
}

setup_kubectl_alias() {
    log_step "Setting up kubectl alias..."

    local user_home="/home/${MICROK8S_USER}"
    local bashrc="${user_home}/.bashrc"
    local zshrc="${user_home}/.zshrc"

    # Add to .bashrc
    if [[ -f "${bashrc}" ]]; then
        if grep -q "alias kubectl='microk8s.kubectl'" "${bashrc}"; then
            log_ok "kubectl alias already exists in .bashrc"
        else
            log_info "Adding kubectl alias to .bashrc..."
            echo "" >> "${bashrc}"
            echo "# Added by kubernetes-setup.sh" >> "${bashrc}"
            echo "alias kubectl='microk8s.kubectl'" >> "${bashrc}"
            log_ok "kubectl alias added to .bashrc"
        fi
    fi

    # Add to .zshrc if exists
    if [[ -f "${zshrc}" ]]; then
        if grep -q "alias kubectl='microk8s.kubectl'" "${zshrc}"; then
            log_ok "kubectl alias already exists in .zshrc"
        else
            log_info "Adding kubectl alias to .zshrc..."
            echo "" >> "${zshrc}"
            echo "# Added by kubernetes-setup.sh" >> "${zshrc}"
            echo "alias kubectl='microk8s.kubectl'" >> "${zshrc}"
            log_ok "kubectl alias added to .zshrc"
        fi
    fi

    return 0
}

setup_helm_alias() {
    log_step "Setting up helm alias..."

    local user_home="/home/${MICROK8S_USER}"
    local bashrc="${user_home}/.bashrc"
    local zshrc="${user_home}/.zshrc"

    # Add to .bashrc
    if [[ -f "${bashrc}" ]]; then
        if grep -q "alias helm='microk8s.helm3'" "${bashrc}"; then
            log_ok "helm alias already exists in .bashrc"
        else
            log_info "Adding helm alias to .bashrc..."
            echo "alias helm='microk8s.helm3'" >> "${bashrc}"
            log_ok "helm alias added to .bashrc"
        fi
    fi

    # Add to .zshrc if exists
    if [[ -f "${zshrc}" ]]; then
        if grep -q "alias helm='microk8s.helm3'" "${zshrc}"; then
            log_ok "helm alias already exists in .zshrc"
        else
            log_info "Adding helm alias to .zshrc..."
            echo "alias helm='microk8s.helm3'" >> "${zshrc}"
            log_ok "helm alias added to .zshrc"
        fi
    fi

    return 0
}

export_kubeconfig() {
    log_step "Exporting kubeconfig..."

    local user_home="/home/${MICROK8S_USER}"
    local kube_dir="${user_home}/.kube"
    local kubeconfig="${kube_dir}/config"

    # Create .kube directory
    if [[ ! -d "${kube_dir}" ]]; then
        mkdir -p "${kube_dir}"
        chown "${MICROK8S_USER}:${MICROK8S_USER}" "${kube_dir}"
    fi

    # Export kubeconfig
    log_info "Exporting kubeconfig to ${kubeconfig}..."
    microk8s config > "${kubeconfig}" || {
        log_error "Failed to export kubeconfig"
        return 1
    }

    # Set ownership
    chown "${MICROK8S_USER}:${MICROK8S_USER}" "${kubeconfig}"
    chmod 600 "${kubeconfig}"

    log_ok "Kubeconfig exported successfully"
    return 0
}
