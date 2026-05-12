#!/bin/bash
# setup-kubernetes.sh
# One-time installation script for MicroK8s Kubernetes cluster
# Usage: sudo ./setup-kubernetes.sh [OPTIONS]

set -uo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
CONFIGS_DIR="${SCRIPT_DIR}/configs"

# Resolve config file for an env name: prefer configs/config.<env>, fall back to legacy ${SCRIPT_DIR}/config.<env>.
resolve_config_for_env() {
    local env="$1"
    if [[ -f "${CONFIGS_DIR}/config.${env}" ]]; then
        printf '%s\n' "${CONFIGS_DIR}/config.${env}"
    elif [[ -f "${SCRIPT_DIR}/config.${env}" ]]; then
        printf '%s\n' "${SCRIPT_DIR}/config.${env}"
    fi
}

# List available config.* files from both locations (excluding config.example).
list_available_configs() {
    {
        ls -1 "${CONFIGS_DIR}"/config.* 2>/dev/null
        ls -1 "${SCRIPT_DIR}"/config.* 2>/dev/null
    } | grep -Ev '/config\.example$' \
      | sed -e "s|${CONFIGS_DIR}/|configs/|" -e "s|${SCRIPT_DIR}/||" \
      | sort -u | tr '\n' ' '
}

# Handle --help and no-args early (before config loading)
# Minimal help — full show_help() needs common functions loaded
print_early_help() {
    cat <<HELPEOF
USAGE: sudo ./setup-kubernetes.sh --<env> [OPTIONS]

Unified script for MicroK8s setup, infrastructure deployment, and maintenance.

ENVIRONMENT (required for most operations):
    --dev                         Use configs/config.dev
    --test                        Use configs/config.test
    --prod                        Use configs/config.prod (default if config exists)
    --config PATH                 Use a custom configuration file

SETUP:
    --install-microk8s            Install only MicroK8s
    --configure-storage           Configure only storage
    --configure-cert-manager      Configure only cert-manager
    --install-cli-tools           Install only CLI tools
    --setup-aliases               Setup only kubectl/helm aliases
    --skip-microk8s / --skip-storage / --skip-cert-manager / --skip-cli-tools / --skip-aliases

INFRASTRUCTURE:
    --deploy-kube / --deploy-argocd / --deploy-vault / --deploy-all
    --install-kube / --install-argocd / --install-vault    (aliases for deploy)
    --uninstall-kube / --uninstall-argocd / --uninstall-vault
    --upgrade-kube / --upgrade-argocd / --upgrade-vault

MAINTENANCE:
    --check                       Run full health check on cluster and apps
    --status                      Show infrastructure applications status
    --show-config                 Show resolved configuration
    --show-credentials            Display access credentials
    --show-urls                   Display access URLs
    --get-kube-token              Get dashboard access token
    --verify-tls                  Verify TLS certificates
    --restart-app APP             Restart app (kube/argocd/vault)
    --upgrade-app APP             Upgrade app to latest version
    --update-ingress [APP]        Update ingress config (kube/argocd/vault/all)
    --update-cli-tools            Update all CLI tools
    --logs APP                    Show logs for app

GENERAL:
    --help, -h                    Show this help message
    --verify                      Verify installation only
    --force                       Force reinstall/redeploy

EXAMPLES:
    sudo ./setup-kubernetes.sh --dev                          # Full cluster install
    sudo ./setup-kubernetes.sh --dev --deploy-all             # Deploy all apps
    sudo ./setup-kubernetes.sh --dev --check                  # Health check
    sudo ./setup-kubernetes.sh --dev --show-config            # Show config

CONFIGURATION:
    Copy config.example to configs/config.<env> and edit it.
    Available configs: $(list_available_configs)
HELPEOF
}

if [[ $# -eq 0 ]]; then
    print_early_help
    exit 0
fi

for arg in "$@"; do
    if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
        print_early_help
        exit 0
    fi
done

# Determine config file from environment flag
# Pre-scan args for --dev/--test/--prod/--config before full parsing
DEPLOY_ENV_ARG=""
CUSTOM_CONFIG=""
for arg in "$@"; do
    case "$arg" in
        --dev)  DEPLOY_ENV_ARG="dev" ;;
        --test) DEPLOY_ENV_ARG="test" ;;
        --prod) DEPLOY_ENV_ARG="prod" ;;
        --config) CUSTOM_CONFIG="next" ;;
        *)
            if [[ "${CUSTOM_CONFIG}" == "next" ]]; then
                CUSTOM_CONFIG="$arg"
            fi
            ;;
    esac
done

if [[ -n "${CUSTOM_CONFIG}" && "${CUSTOM_CONFIG}" != "next" ]]; then
    CONFIG_FILE="${CUSTOM_CONFIG}"
elif [[ -n "${DEPLOY_ENV_ARG}" ]]; then
    CONFIG_FILE=$(resolve_config_for_env "${DEPLOY_ENV_ARG}")
    if [[ -z "${CONFIG_FILE}" ]]; then
        # Point the error at the preferred location for this env.
        CONFIG_FILE="${CONFIGS_DIR}/config.${DEPLOY_ENV_ARG}"
    fi
else
    # Auto-detect: prefer prod, then dev, then test — searching configs/ first, then legacy locations.
    for env in prod dev test; do
        CANDIDATE=$(resolve_config_for_env "$env")
        if [[ -n "${CANDIDATE}" ]]; then
            CONFIG_FILE="${CANDIDATE}"
            break
        fi
    done
    if [[ -z "${CONFIG_FILE:-}" ]]; then
        echo "ERROR: No configuration file found."
        echo "       Copy config.example to configs/config.<env> (e.g. configs/config.dev) and customise it."
        echo "       Available: $(list_available_configs)"
        exit 1
    fi
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    echo "       Copy config.example to configs/config.<env> and customise it."
    echo "       Available: $(list_available_configs)"
    exit 1
fi
source "${CONFIG_FILE}"

# Load common functions
COMMON_FUNCTIONS="${SCRIPT_DIR}/common-kubernetes.sh"
if [[ ! -f "${COMMON_FUNCTIONS}" ]]; then
    echo "ERROR: Common functions file not found: ${COMMON_FUNCTIONS}"
    exit 1
fi
source "${COMMON_FUNCTIONS}"

# Initialize logging
init_logging

# Installation flags
INSTALL_MICROK8S=true
CONFIGURE_STORAGE=true
CONFIGURE_CERT_MANAGER=true
INSTALL_CLI_TOOLS=true
SETUP_ALIASES=true
FORCE_INSTALL=false
VERIFY_ONLY=false

# Deployment flags
DEPLOY_KUBE=false
DEPLOY_ARGOCD=false
DEPLOY_VAULT=false
FORCE_DEPLOY=false

# Cleanup flags
CLEANUP_KUBE=false
CLEANUP_ARGOCD=false
CLEANUP_VAULT=false

# Environment flag (set before config is re-evaluated)
# DEPLOY_ENV is set in config, but can be overridden by --test/--prod/--dev

# Maintenance flags
SHOW_INFRA_STATUS=false
SHOW_CREDENTIALS=false
SHOW_URLS=false
GET_KUBE_TOKEN=false
VERIFY_TLS=false
RESTART_APP=""
UPGRADE_APP=""
UPDATE_INGRESS=""
SHOW_LOGS=""
UPDATE_CLI_TOOLS=false
SHOW_CONFIG=false
RUN_CHECK=false

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --verify)
                VERIFY_ONLY=true
                shift
                ;;
            --check)
                RUN_CHECK=true
                shift
                ;;
            --install-microk8s)
                INSTALL_MICROK8S=true
                CONFIGURE_STORAGE=false
                CONFIGURE_CERT_MANAGER=false
                INSTALL_CLI_TOOLS=false
                SETUP_ALIASES=false
                shift
                ;;
            --configure-storage)
                INSTALL_MICROK8S=false
                CONFIGURE_STORAGE=true
                CONFIGURE_CERT_MANAGER=false
                INSTALL_CLI_TOOLS=false
                SETUP_ALIASES=false
                shift
                ;;
            --configure-cert-manager)
                INSTALL_MICROK8S=false
                CONFIGURE_STORAGE=false
                CONFIGURE_CERT_MANAGER=true
                INSTALL_CLI_TOOLS=false
                SETUP_ALIASES=false
                shift
                ;;
            --install-cli-tools)
                INSTALL_MICROK8S=false
                CONFIGURE_STORAGE=false
                CONFIGURE_CERT_MANAGER=false
                INSTALL_CLI_TOOLS=true
                SETUP_ALIASES=false
                shift
                ;;
            --setup-aliases)
                INSTALL_MICROK8S=false
                CONFIGURE_STORAGE=false
                CONFIGURE_CERT_MANAGER=false
                INSTALL_CLI_TOOLS=false
                SETUP_ALIASES=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                FORCE_DEPLOY=true
                shift
                ;;
            --skip-microk8s)
                INSTALL_MICROK8S=false
                shift
                ;;
            --skip-storage)
                CONFIGURE_STORAGE=false
                shift
                ;;
            --skip-cert-manager)
                CONFIGURE_CERT_MANAGER=false
                shift
                ;;
            --skip-cli-tools)
                INSTALL_CLI_TOOLS=false
                shift
                ;;
            --skip-aliases)
                SETUP_ALIASES=false
                shift
                ;;
            --deploy-kube)
                DEPLOY_KUBE=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --deploy-argocd)
                DEPLOY_ARGOCD=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --deploy-vault)
                DEPLOY_VAULT=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --deploy-all)
                DEPLOY_KUBE=true; DEPLOY_ARGOCD=true; DEPLOY_VAULT=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --install-kube) # alias for --deploy-kube
                DEPLOY_KUBE=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift ;;
            --install-argocd) # alias for --deploy-argocd
                DEPLOY_ARGOCD=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift ;;
            --install-vault) # alias for --deploy-vault
                DEPLOY_VAULT=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift ;;
            --uninstall-kube) CLEANUP_KUBE=true; shift ;;
            --uninstall-argocd) CLEANUP_ARGOCD=true; shift ;;
            --uninstall-vault) CLEANUP_VAULT=true; shift ;;
            --upgrade-kube) UPGRADE_APP="kube"; shift ;;
            --upgrade-argocd) UPGRADE_APP="argocd"; shift ;;
            --upgrade-vault) UPGRADE_APP="vault"; shift ;;
            --status)
                SHOW_INFRA_STATUS=true
                shift
                ;;
            --restart-app)
                RESTART_APP="$2"
                shift 2
                ;;
            --upgrade-app)
                UPGRADE_APP="$2"
                shift 2
                ;;
            --update-ingress)
                UPDATE_INGRESS="${2:-all}"
                shift
                # Consume next arg if it's not another flag
                if [[ $# -gt 0 && "$1" != --* ]]; then
                    UPDATE_INGRESS="$1"
                    shift
                fi
                ;;
            --logs)
                SHOW_LOGS="$2"
                shift 2
                ;;
            --show-credentials)
                SHOW_CREDENTIALS=true
                shift
                ;;
            --get-kube-token)
                GET_KUBE_TOKEN=true
                shift
                ;;
            --show-urls)
                SHOW_URLS=true
                shift
                ;;
            --verify-tls)
                VERIFY_TLS=true
                shift
                ;;
            --dev)
                DEPLOY_ENV="dev"
                shift
                ;;
            --test)
                DEPLOY_ENV="test"
                shift
                ;;
            --prod)
                DEPLOY_ENV="prod"
                shift
                ;;
            --update-cli-tools)
                UPDATE_CLI_TOOLS=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift ;;
            --show-config)
                SHOW_CONFIG=true
                shift ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Re-evaluate hostnames after DEPLOY_ENV is set by argument parsing
apply_environment() {
    KUBE_HOST="${KUBE_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    ARGOCD_HOST="${ARGOCD_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    VAULT_HOST="${VAULT_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    log_info "Environment: ${DEPLOY_ENV} (hosts: ${KUBE_HOST}, ${ARGOCD_HOST}, ${VAULT_HOST})"
}

# Render a manifest file by replacing placeholders with the current environment's values.
# Creates a temp file and prints its path.
render_manifest() {
    local source_file="$1"
    local tmp_file
    tmp_file=$(mktemp "/tmp/k8s-manifest-XXXXXX.yaml")
    sed \
        -e "s|__KUBE_HOST__|${KUBE_HOST}|g" \
        -e "s|__ARGOCD_HOST__|${ARGOCD_HOST}|g" \
        -e "s|__VAULT_HOST__|${VAULT_HOST}|g" \
        -e "s|__CLUSTER_ISSUER__|${CLUSTER_ISSUER_NAME}|g" \
        -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
        -e "s|__VAULT_STORAGE_SIZE__|${VAULT_STORAGE_SIZE}|g" \
        "${source_file}" > "${tmp_file}"
    echo "${tmp_file}"
}

show_help() {
    cat << EOF
USAGE: sudo ./setup-kubernetes.sh [OPTIONS]

Unified script for MicroK8s setup, infrastructure deployment, and maintenance.

KUBERNETES SETUP OPTIONS:
    --install-microk8s            Install only MicroK8s
    --configure-storage           Configure only storage
    --configure-cert-manager      Configure only cert-manager
    --install-cli-tools           Install only CLI tools
    --setup-aliases               Setup only kubectl/helm aliases
    --skip-microk8s              Skip MicroK8s installation
    --skip-storage               Skip storage configuration
    --skip-cert-manager          Skip cert-manager configuration
    --skip-cli-tools             Skip CLI tools installation
    --skip-aliases               Skip aliases setup

INFRASTRUCTURE DEPLOYMENT OPTIONS:
    --deploy-kube                 Deploy Kubernetes Dashboard (Headlamp)
    --deploy-argocd               Deploy ArgoCD
    --deploy-vault                Deploy HashiCorp Vault
    --deploy-all                  Deploy all infrastructure apps
    --install-kube                Alias for --deploy-kube
    --install-argocd              Alias for --deploy-argocd
    --install-vault               Alias for --deploy-vault
    --uninstall-kube              Helm uninstall Kubernetes Dashboard
    --uninstall-argocd            Helm uninstall ArgoCD (also removes ArgoCD CRDs)
    --uninstall-vault             Helm uninstall Vault (also removes Vault PVCs)
    --upgrade-kube                Upgrade Kubernetes Dashboard to latest version
    --upgrade-argocd              Upgrade ArgoCD to latest version
    --upgrade-vault               Upgrade Vault to latest version

MAINTENANCE OPTIONS:
    --status                      Show infrastructure applications status
    --restart-app APP             Restart specific app (kube/argocd/vault)
    --upgrade-app APP             Upgrade specific app to latest version
    --update-ingress [APP]        Update ingress/hostname config only (kube/argocd/vault/all)
    --logs APP                    Show logs for specific app
    --show-credentials            Display access credentials for all apps
    --get-kube-token              Get permanent kube dashboard access token
    --show-urls                   Display access URLs
    --verify-tls                  Verify TLS certificates
    --update-cli-tools            Update all CLI tools to latest versions
    --show-config                 Show resolved configuration and exit
    --check                       Run full health check on cluster and apps

ENVIRONMENT OPTIONS:
    --dev                         Deploy with dev hostnames (<prefix>.dev.<domain>)
    --test                        Deploy with test hostnames (<prefix>.test.<domain>)
    --prod                        Deploy with prod hostnames (<prefix>.prod.<domain>) [default]
    --config PATH                 Use a custom configuration file

GENERAL OPTIONS:
    --help, -h                    Show this help message
    --verify                      Verify installation only (no changes)
    --force                       Force reinstall/redeploy (skip existing checks)

EXAMPLES:
    # Full MicroK8s installation
    sudo ./setup-kubernetes.sh

    # Deploy all infrastructure apps
    sudo ./setup-kubernetes.sh --deploy-all

    # Deploy kube dashboard only
    sudo ./setup-kubernetes.sh --deploy-kube

    # Deploy kube dashboard to dev environment
    sudo ./setup-kubernetes.sh --dev --deploy-kube

    # Show status of infrastructure
    sudo ./setup-kubernetes.sh --status

    # Restart ArgoCD
    sudo ./setup-kubernetes.sh --restart-app argocd

    # Get kube dashboard token
    sudo ./setup-kubernetes.sh --get-kube-token

    # Show logs for Vault
    sudo ./setup-kubernetes.sh --logs vault

    # Verify TLS certificates
    sudo ./setup-kubernetes.sh --verify-tls

    # Deploy all infrastructure to dev
    sudo ./setup-kubernetes.sh --dev --deploy-all

    # Show resolved config
    sudo ./setup-kubernetes.sh --show-config

CONFIGURATION:
    Edit configs/config.<env> to customize settings.
EOF
}

show_config() {
    log_step "=== Resolved Configuration ==="
    echo
    log_info "Cluster:     ${CLUSTER_NAME}"
    log_info "Domain:      ${DOMAIN_SUFFIX}"
    log_info "Environment: ${DEPLOY_ENV}"
    log_info "Email:       ${LETSENCRYPT_EMAIL}"
    echo
    log_info "Kube Host:   ${KUBE_HOST} (enabled: ${ENABLE_KUBE})"
    log_info "ArgoCD Host: ${ARGOCD_HOST} (enabled: ${ENABLE_ARGOCD})"
    log_info "Vault Host:  ${VAULT_HOST} (enabled: ${ENABLE_VAULT})"
    echo
    log_info "Config File: ${CONFIG_FILE}"
}

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

install_microk8s() {
    log_step "Installing MicroK8s..."

    # Check if already installed
    if is_microk8s_installed; then
        if [[ "${FORCE_INSTALL}" == "true" ]]; then
            log_warn "MicroK8s already installed, forcing reinstall..."
            snap remove microk8s --purge || {
                log_error "Failed to remove existing MicroK8s"
                return 1
            }
        else
            log_ok "MicroK8s already installed (version: $(get_microk8s_version)), skipping"
            return 0
        fi
    fi

    # Install MicroK8s
    log_info "Installing MicroK8s from snap (channel: ${MICROK8S_CHANNEL})..."
    snap install microk8s --classic --channel="${MICROK8S_CHANNEL}" || {
        log_error "Failed to install MicroK8s"
        return 1
    }

    # Wait for MicroK8s to be ready
    wait_for_microk8s_ready || {
        log_error "MicroK8s installation failed"
        return 1
    }

    log_ok "MicroK8s installed successfully (version: $(get_microk8s_version))"
    return 0
}

add_user_to_group() {
    log_step "Adding user to microk8s group..."

    # Check if user is already in group
    if is_user_in_microk8s_group "${MICROK8S_USER}"; then
        log_ok "User ${MICROK8S_USER} already in microk8s group, skipping"
        return 0
    fi

    # Add user to group
    log_info "Adding user ${MICROK8S_USER} to microk8s group..."
    usermod -a -G microk8s "${MICROK8S_USER}" || {
        log_error "Failed to add user to microk8s group"
        return 1
    }

    # Change ownership of .kube directory
    if [[ -d "/home/${MICROK8S_USER}/.kube" ]]; then
        chown -R "${MICROK8S_USER}:${MICROK8S_USER}" "/home/${MICROK8S_USER}/.kube" || {
            log_warn "Failed to change ownership of .kube directory"
        }
    fi

    log_ok "User ${MICROK8S_USER} added to microk8s group"
    log_warn "User must re-login or run 'newgrp microk8s' for changes to take effect"
    return 0
}

# Patch CoreDNS's Corefile to forward external lookups to explicit resolvers
# (e.g. 1.1.1.1, 9.9.9.9). Without this, CoreDNS inherits the host's
# /etc/resolv.conf which on systemd-resolved systems is 127.0.0.53 — not
# reachable from inside pods. Idempotent: only acts if the current Corefile
# doesn't already match the desired forward config. Works on any MicroK8s
# version because it patches the live ConfigMap (avoids `microk8s disable/
# enable dns`, which is fragile inside scripts on 1.32+).
#
# Set DNS_FORCE_TCP=true to add a `force_tcp` directive — required on networks
# that block outbound UDP/53 to public resolvers but allow TCP/53 (some
# corporate/VLAN egress policies).
fix_coredns_upstream() {
    if [[ -z "${DNS_UPSTREAM_SERVERS:-}" ]]; then
        return 0
    fi

    local current
    current=$(microk8s kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null) || {
        log_info "CoreDNS ConfigMap not present yet, skipping upstream patch"
        return 0
    }

    local upstreams="${DNS_UPSTREAM_SERVERS//,/ }"
    local force_tcp="${DNS_FORCE_TCP:-false}"
    local desired_label="forward . ${upstreams}"
    [[ "${force_tcp}" == "true" ]] && desired_label="${desired_label} (force_tcp)"

    # Already correctly configured?
    local has_upstreams=0 has_force_tcp=0
    echo "${current}" | grep -qE "forward \. ${upstreams}( \{|$)" && has_upstreams=1
    echo "${current}" | grep -q 'force_tcp' && has_force_tcp=1
    if [[ ${has_upstreams} -eq 1 ]]; then
        if [[ "${force_tcp}" == "true" && ${has_force_tcp} -eq 1 ]] \
           || [[ "${force_tcp}" != "true" && ${has_force_tcp} -eq 0 ]]; then
            log_ok "CoreDNS upstream already configured (${desired_label})"
            return 0
        fi
    fi

    log_step "Patching CoreDNS Corefile: ${desired_label}"

    # Replace the entire Corefile via patch-file. We hardcode the full Corefile
    # template (matching MicroK8s 1.32's default) so the patch is reliable
    # regardless of the current state.
    local forward_block
    if [[ "${force_tcp}" == "true" ]]; then
        forward_block="forward . ${upstreams} {
            force_tcp
        }"
    else
        forward_block="forward . ${upstreams}"
    fi

    local patch_file
    patch_file=$(mktemp "/tmp/coredns-patch-XXXXXX.yaml")
    cat > "${patch_file}" <<EOF
data:
  Corefile: |
    .:53 {
        errors
        health {
          lameduck 5s
        }
        ready
        log . {
          class error
        }
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        ${forward_block}
        cache 30
        loop
        reload
        loadbalance
    }
EOF

    microk8s kubectl -n kube-system patch configmap coredns --patch-file="${patch_file}" >/dev/null || {
        rm -f "${patch_file}"
        log_error "Failed to patch CoreDNS ConfigMap"
        return 1
    }
    rm -f "${patch_file}"

    microk8s kubectl -n kube-system rollout restart deployment coredns >/dev/null 2>&1 || true
    microk8s kubectl -n kube-system rollout status deployment coredns --timeout=60s >/dev/null 2>&1 || true
    log_ok "CoreDNS now forwarding to: ${desired_label}"
}

enable_addons() {
    log_step "Enabling MicroK8s addons..."

    local failed_addons=()

    for addon in "${ADDONS[@]}"; do
        # For the dns addon, pass explicit upstream resolvers on first-time enable.
        # If DNS was auto-enabled by `microk8s install`, fix_coredns_upstream below
        # patches the live ConfigMap instead.
        local enable_arg="${addon}"
        if [[ "${addon}" == "dns" && -n "${DNS_UPSTREAM_SERVERS:-}" ]]; then
            enable_arg="dns:${DNS_UPSTREAM_SERVERS}"
        fi

        if is_addon_enabled "${addon}"; then
            log_ok "Addon '${addon}' already enabled, skipping"
            continue
        fi

        log_info "Enabling addon '${enable_arg}'..."
        microk8s enable "${enable_arg}" || {
            log_error "Failed to enable addon '${addon}'"
            failed_addons+=("${addon}")
            continue
        }

        wait_for_addon_enabled "${addon}" || {
            log_warn "Addon '${addon}' enabled but verification timeout"
        }
    done

    # After all addons are up, patch CoreDNS if it's still using the broken default.
    # Runs whether DNS was auto-enabled at install time or enabled by us above.
    fix_coredns_upstream || log_warn "CoreDNS upstream fix incomplete"

    # Patch the nginx-ingress controller DaemonSet to use hostNetwork.
    # Without this, the hostPort on the controller pod isn't plumbed to the
    # host's :80/:443 (Calico CNI doesn't include portmap by default), so
    # inbound HTTP is unreachable and Let's Encrypt HTTP-01 challenges fail.
    fix_ingress_hostnetwork || log_warn "Could not configure ingress controller hostNetwork"

    if [[ ${#failed_addons[@]} -gt 0 ]]; then
        log_error "Failed to enable addons: ${failed_addons[*]}"
        return 1
    fi

    log_ok "All addons enabled successfully"
    return 0
}

# Patch the nginx-ingress controller DaemonSet to use hostNetwork: true and
# ClusterFirstWithHostNet so it binds port 80/443 on the host directly.
# Idempotent: skips if already set. Required on MicroK8s because Calico's CNI
# doesn't include the portmap plugin, so the controller's hostPort declarations
# never reach the host's network stack.
fix_ingress_hostnetwork() {
    if ! microk8s kubectl -n ingress get ds nginx-ingress-microk8s-controller &>/dev/null; then
        log_info "nginx-ingress controller DaemonSet not present (yet) — skipping hostNetwork patch"
        return 0
    fi

    local current
    current=$(microk8s kubectl -n ingress get ds nginx-ingress-microk8s-controller \
        -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null)
    if [[ "${current}" == "true" ]]; then
        log_ok "Ingress controller already on hostNetwork"
        return 0
    fi

    log_step "Patching ingress controller to use hostNetwork (binds host :80 and :443)..."
    microk8s kubectl -n ingress patch daemonset nginx-ingress-microk8s-controller \
        --type=strategic \
        --patch='{"spec":{"template":{"spec":{"hostNetwork":true,"dnsPolicy":"ClusterFirstWithHostNet"}}}}' >/dev/null || {
        log_error "Failed to patch ingress controller DaemonSet"
        return 1
    }

    microk8s kubectl -n ingress rollout status ds/nginx-ingress-microk8s-controller --timeout=120s >/dev/null 2>&1 || {
        log_warn "Ingress controller rollout did not complete within 120s — investigate manually"
    }

    log_ok "Ingress controller now on hostNetwork"
}

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

verify_installation() {
    log_step "Verifying installation..."

    local errors=0

    # Check MicroK8s
    if is_microk8s_installed; then
        log_ok "MicroK8s is installed (version: $(get_microk8s_version))"
    else
        log_error "MicroK8s is not installed"
        errors=$((errors + 1))
    fi

    # Check if running
    if is_microk8s_running; then
        log_ok "MicroK8s is running"
    else
        log_error "MicroK8s is not running"
        errors=$((errors + 1))
    fi

    # Check user in group
    if is_user_in_microk8s_group; then
        log_ok "User ${MICROK8S_USER} is in microk8s group"
    else
        log_error "User ${MICROK8S_USER} is not in microk8s group"
        errors=$((errors + 1))
    fi

    # Check addons
    for addon in "${ADDONS[@]}"; do
        if is_addon_enabled "${addon}"; then
            log_ok "Addon '${addon}' is enabled"
        else
            log_error "Addon '${addon}' is not enabled"
            errors=$((errors + 1))
        fi
    done

    # Check storage
    if is_storage_configured; then
        if [[ -n "${STORAGE_DIRECTORY}" ]]; then
            log_ok "Storage is configured correctly (${STORAGE_DIRECTORY})"
        else
            log_ok "Storage is configured correctly (default MicroK8s hostpath)"
        fi
    else
        log_warn "Storage configuration may need attention"
    fi

    # Check default storage class
    if is_default_storage_class_set; then
        log_ok "Default storage class is set to hostpath-storage"
    else
        log_warn "Default storage class is not set"
    fi

    # Check ClusterIssuer
    if is_cluster_issuer_ready; then
        log_ok "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is ready"
    else
        log_warn "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is not ready"
    fi

    # Check CLI tools
    for tool in argocd vault yq jq tailscale; do
        if is_cli_tool_installed "${tool}"; then
            log_ok "CLI tool '${tool}' is installed (version: $(get_cli_tool_version ${tool}))"
        else
            log_warn "CLI tool '${tool}' is not installed"
        fi
    done

    # Check aliases
    if verify_kubectl_alias; then
        log_ok "kubectl alias is configured"
    else
        log_warn "kubectl alias is not configured"
    fi

    if verify_helm_alias; then
        log_ok "helm alias is configured"
    else
        log_warn "helm alias is not configured"
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "Verification found ${errors} error(s)"
        return 1
    fi

    log_ok "Verification completed successfully"
    return 0
}

run_health_check() {
    local errors=0
    local warnings=0
    local checks=0

    _pass() { checks=$((checks + 1)); log_ok "$*"; }
    _fail() { checks=$((checks + 1)); errors=$((errors + 1)); log_error "$*"; }
    _warn() { checks=$((checks + 1)); warnings=$((warnings + 1)); log_warn "$*"; }

    log_step "=== Cluster Health Check ==="
    echo

    # --- Node ---
    log_info "--- Node ---"
    if is_microk8s_installed; then
        _pass "MicroK8s installed ($(get_microk8s_version))"
    else
        _fail "MicroK8s is not installed"
    fi

    if is_microk8s_running; then
        _pass "MicroK8s is running"
    else
        _fail "MicroK8s is not running"
    fi

    local node_status
    node_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "${node_status}" == "True" ]]; then
        local node_name node_version node_ip
        node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        node_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        _pass "Node '${node_name}' is Ready (${node_version}, IP: ${node_ip})"
    else
        _fail "Node is not Ready"
    fi

    if is_user_in_microk8s_group; then
        _pass "User '${MICROK8S_USER}' is in microk8s group"
    else
        _warn "User '${MICROK8S_USER}' is not in microk8s group"
    fi
    echo

    # --- Addons ---
    log_info "--- Addons ---"
    for addon in "${ADDONS[@]}"; do
        if is_addon_enabled "${addon}"; then
            _pass "Addon '${addon}' is enabled"
        else
            _fail "Addon '${addon}' is not enabled"
        fi
    done
    echo

    # --- Storage ---
    log_info "--- Storage ---"
    if is_default_storage_class_set; then
        local sc_name
        sc_name=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
        _pass "Default StorageClass: ${sc_name}"
    else
        _fail "No default StorageClass set"
    fi

    if [[ -n "${STORAGE_DIRECTORY}" ]]; then
        if is_storage_configured; then
            _pass "External storage configured (${STORAGE_DIRECTORY})"
        else
            _fail "External storage not properly configured"
        fi
    else
        _pass "Using default MicroK8s hostpath storage"
    fi
    echo

    # --- Cert-Manager ---
    log_info "--- Cert-Manager ---"
    if is_cert_manager_ready; then
        _pass "Cert-manager pods are running"
    else
        _fail "Cert-manager pods are not ready"
    fi

    if is_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}"; then
        _pass "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is Ready"
    else
        _fail "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is not Ready"
    fi
    echo

    # --- Ingress Controller ---
    log_info "--- Ingress Controller ---"
    local ingress_pods
    ingress_pods=$(kubectl get pods -n ingress -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
    if [[ ${ingress_pods} -ge 1 ]]; then
        _pass "Ingress controller running (${ingress_pods} pod(s))"
    else
        _fail "Ingress controller is not running"
    fi
    echo

    # --- System Pods ---
    log_info "--- System Pods ---"
    local not_running
    not_running=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded") | "\(.metadata.namespace)/\(.metadata.name) (\(.status.phase))"')
    if [[ -z "${not_running}" ]]; then
        local total_pods
        total_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
        _pass "All ${total_pods} pod(s) are Running"
    else
        _fail "Pods not running:"
        echo "${not_running}" | while read -r line; do
            log_error "  ${line}"
        done
    fi
    echo

    # --- CLI Tools ---
    log_info "--- CLI Tools ---"
    for tool in argocd vault yq jq tailscale; do
        if is_cli_tool_installed "${tool}"; then
            _pass "${tool} $(get_cli_tool_version ${tool})"
        else
            _warn "${tool} is not installed"
        fi
    done
    echo

    # --- Shell Aliases ---
    log_info "--- Shell Aliases ---"
    if verify_kubectl_alias; then
        _pass "kubectl alias configured"
    else
        _warn "kubectl alias not configured"
    fi
    if verify_helm_alias; then
        _pass "helm alias configured"
    else
        _warn "helm alias not configured"
    fi

    local kubeconfig="/home/${MICROK8S_USER}/.kube/config"
    if [[ -f "${kubeconfig}" ]]; then
        _pass "Kubeconfig exists (${kubeconfig})"
    else
        _warn "Kubeconfig not found (${kubeconfig})"
    fi
    echo

    # --- Infrastructure Apps ---
    log_info "--- Infrastructure Apps ---"

    if [[ "${ENABLE_KUBE}" == "true" ]]; then
        if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
            local kube_pods
            kube_pods=$(kubectl get pods -n "${KUBE_NAMESPACE}" -l app.kubernetes.io/name=headlamp -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${kube_pods} -ge 1 ]]; then
                _pass "Kube Dashboard deployed and running (${kube_pods} pod(s))"
            else
                _fail "Kube Dashboard deployed but no pods running"
            fi
            if is_certificate_ready "${KUBE_NAMESPACE}" "dashboard-tls"; then
                _pass "Kube Dashboard TLS certificate is Ready"
            else
                _warn "Kube Dashboard TLS certificate is not Ready"
            fi
        else
            _warn "Kube Dashboard not deployed (https://${KUBE_HOST})"
        fi
    else
        log_info "  Kube Dashboard: disabled in config"
    fi

    if [[ "${ENABLE_ARGOCD}" == "true" ]]; then
        if is_helm_release_deployed "${ARGOCD_RELEASE}" "${ARGOCD_NAMESPACE}"; then
            local argo_pods
            argo_pods=$(kubectl get pods -n "${ARGOCD_NAMESPACE}" -l app.kubernetes.io/name=argocd-server -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${argo_pods} -ge 1 ]]; then
                _pass "ArgoCD deployed and running (${argo_pods} pod(s))"
            else
                _fail "ArgoCD deployed but server pod not running"
            fi
            if is_certificate_ready "${ARGOCD_NAMESPACE}" "argocd-server-tls"; then
                _pass "ArgoCD TLS certificate is Ready"
            else
                _warn "ArgoCD TLS certificate is not Ready"
            fi
        else
            _warn "ArgoCD not deployed (https://${ARGOCD_HOST})"
        fi
    else
        log_info "  ArgoCD: disabled in config"
    fi

    if [[ "${ENABLE_VAULT}" == "true" ]]; then
        if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
            local vault_pods
            vault_pods=$(kubectl get pods -n "${VAULT_NAMESPACE}" -l app.kubernetes.io/name=vault -o json 2>/dev/null | \
                jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
            if [[ ${vault_pods} -ge 1 ]]; then
                _pass "Vault deployed and running (${vault_pods} pod(s))"
            else
                _fail "Vault deployed but no pods running"
            fi
            if is_certificate_ready "${VAULT_NAMESPACE}" "vault-tls"; then
                _pass "Vault TLS certificate is Ready"
            else
                _warn "Vault TLS certificate is not Ready"
            fi
        else
            _warn "Vault not deployed (https://${VAULT_HOST})"
        fi
    else
        log_info "  Vault: disabled in config"
    fi
    echo

    # --- Credentials ---
    log_info "--- Credentials ---"
    local cred_dir="/home/${MICROK8S_USER}/secrets"
    for app in kube argocd vault; do
        local cred_file="${cred_dir}/${app}-${DEPLOY_ENV}.txt"
        if [[ -f "${cred_file}" ]]; then
            _pass "${app}-${DEPLOY_ENV}.txt exists"
        else
            log_info "  ${app}-${DEPLOY_ENV}.txt: not yet created (deploy app first)"
        fi
    done
    echo

    # --- Summary ---
    log_step "=== Health Check Summary ==="
    log_info "Checks: ${checks}  Passed: $((checks - errors - warnings))  Warnings: ${warnings}  Errors: ${errors}"
    echo

    if [[ ${errors} -gt 0 ]]; then
        log_error "Health check found ${errors} error(s)"
        return 1
    elif [[ ${warnings} -gt 0 ]]; then
        log_warn "Health check passed with ${warnings} warning(s)"
        return 0
    else
        log_ok "All checks passed"
        return 0
    fi
}

#######################################
# Infrastructure Deployment Functions
#######################################

# Credentials directory for the actual (non-root) user
CREDENTIALS_DIR="/home/${MICROK8S_USER}/secrets"

# Save credentials to a per-app file: ~/secrets/<app>-<env>.txt
# Usage: save_credential "app-name" "key=value" ...
save_credential() {
    local app="$1"
    shift
    local cred_file="${CREDENTIALS_DIR}/${app}-${DEPLOY_ENV}.txt"

    mkdir -p "${CREDENTIALS_DIR}"

    # Overwrite with current credentials
    {
        echo "${app} (${DEPLOY_ENV})"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        for entry in "$@"; do
            echo "${entry}"
        done
    } > "${cred_file}"

    chown "${MICROK8S_USER}:${MICROK8S_USER}" "${cred_file}"
    chmod 600 "${cred_file}"
    log_info "Credentials saved to: ${cred_file}"
}

create_permanent_dashboard_token() {
    local namespace=$1
    local service_account=$2
    local secret_name="${service_account}-token"

    log_info "Creating permanent token for ${service_account}..."

    # Check if secret already exists
    if kubectl get secret "${secret_name}" -n "${namespace}" &> /dev/null; then
        log_info "Permanent token secret already exists"
        return 0
    fi

    # Create a Secret that will generate a permanent token
    if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: ${service_account}
type: kubernetes.io/service-account-token
EOF
    then
        log_error "Failed to create permanent token secret"
        return 1
    fi

    # Wait for token to be generated
    log_info "Waiting for token to be generated..."
    local max_wait=30
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if kubectl get secret "${secret_name}" -n "${namespace}" -o jsonpath='{.data.token}' &> /dev/null; then
            local token_data=$(kubectl get secret "${secret_name}" -n "${namespace}" -o jsonpath='{.data.token}')
            if [ -n "${token_data}" ]; then
                log_ok "Permanent token created successfully"
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_error "Timeout waiting for token generation"
    return 1
}

get_permanent_dashboard_token() {
    local namespace=$1
    local service_account=$2
    local secret_name="${service_account}-token"

    # Get token from secret
    local token=$(kubectl get secret "${secret_name}" -n "${namespace}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)

    if [ -n "${token}" ]; then
        echo "${token}"
        return 0
    else
        log_warn "Could not retrieve permanent token from secret ${secret_name}"
        return 1
    fi
}

deploy_kube() {
    if [[ "${ENABLE_KUBE}" != "true" ]]; then
        log_warn "Kube dashboard is disabled in config, skipping"
        return 0
    fi

    log_step "Deploying Headlamp (Kubernetes Dashboard)..."

    # Add Helm repo
    add_helm_repo "${KUBE_REPO_NAME}" "${KUBE_REPO_URL}" || return 1

    # Update repos
    update_helm_repos || return 1

    # Create namespace
    create_namespace_if_not_exists "${KUBE_NAMESPACE}" || return 1

    # Check if already deployed
    if is_helm_release_deployed "${KUBE_RELEASE}" "${KUBE_NAMESPACE}"; then
        if [[ "${FORCE_DEPLOY}" == "true" ]]; then
            log_warn "Dashboard already deployed, forcing upgrade..."
        else
            log_ok "Dashboard already deployed, skipping"
            return 0
        fi
    fi

    # Deploy with Helm
    local values_file="${MANIFESTS_DIR}/kube/values.yaml"
    install_helm_chart "${KUBE_RELEASE}" \
        "${KUBE_REPO_NAME}/headlamp" \
        "${KUBE_NAMESPACE}" \
        "${values_file}" || {
        log_error "Failed to deploy Headlamp Dashboard"
        return 1
    }

    # Apply ingress (rendered with current environment hostnames)
    local ingress_file
    ingress_file=$(render_manifest "${MANIFESTS_DIR}/kube/ingress.yaml")
    log_info "Applying Dashboard ingress..."
    kubectl apply -f "${ingress_file}" --request-timeout=30s || {
        rm -f "${ingress_file}"
        log_error "Failed to apply Dashboard ingress"
        return 1
    }
    rm -f "${ingress_file}"

    # Wait for deployment
    wait_for_pods_ready "${KUBE_NAMESPACE}" "app.kubernetes.io/name=headlamp" || {
        log_warn "Headlamp pods not ready yet"
    }

    # Wait for certificate
    wait_for_certificate_ready "${KUBE_NAMESPACE}" "dashboard-tls" || {
        log_warn "Certificate not ready yet (may take a few minutes)"
    }

    # Create dashboard admin service account and token
    log_info "Creating dashboard admin service account..."

    # Create service account if it doesn't exist
    if ! kubectl get serviceaccount dashboard-admin -n "${KUBE_NAMESPACE}" &> /dev/null; then
        kubectl create serviceaccount dashboard-admin -n "${KUBE_NAMESPACE}" || {
            log_warn "Failed to create service account"
        }
    else
        log_info "Service account 'dashboard-admin' already exists"
    fi

    # Create cluster role binding if it doesn't exist
    if ! kubectl get clusterrolebinding dashboard-admin &> /dev/null; then
        kubectl create clusterrolebinding dashboard-admin \
            --clusterrole=cluster-admin \
            --serviceaccount="${KUBE_NAMESPACE}:dashboard-admin" || {
            log_warn "Failed to create cluster role binding"
        }
    else
        log_info "Cluster role binding 'dashboard-admin' already exists"
    fi

    # Create permanent token
    create_permanent_dashboard_token "${KUBE_NAMESPACE}" "dashboard-admin"

    # Retrieve and display the permanent token
    log_info "Retrieving dashboard access token..."
    local dashboard_token=$(get_permanent_dashboard_token "${KUBE_NAMESPACE}" "dashboard-admin")

    if [[ -n "${dashboard_token}" ]]; then
        save_credential "kube" \
            "URL: https://${KUBE_HOST}" \
            "Token: ${dashboard_token}"
        log_ok "Dashboard permanent access token created and saved"
        echo
        log_info "This token does not expire and can be reused."
    fi

    log_ok "Headlamp Dashboard deployed successfully"
    log_info "Access at: https://${KUBE_HOST}"
    return 0
}

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

    # Check if already deployed
    if is_helm_release_deployed "${VAULT_RELEASE}" "${VAULT_NAMESPACE}"; then
        if [[ "${FORCE_DEPLOY}" == "true" ]]; then
            log_warn "Vault already deployed, forcing upgrade..."
        else
            log_ok "Vault already deployed, skipping"
            return 0
        fi
    fi

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

    # Apply certificate (rendered with current environment hostnames)
    local cert_file
    cert_file=$(render_manifest "${MANIFESTS_DIR}/vault/certificate.yaml")
    log_info "Applying Vault certificate..."
    kubectl apply -f "${cert_file}" --request-timeout=30s || {
        log_warn "Failed to apply Vault certificate"
    }
    rm -f "${cert_file}"

    # Apply Ingress (rendered with current environment hostnames).
    # Uses nginx-ingress annotations to talk to Vault's HTTPS listener.
    local ingress_file
    ingress_file=$(render_manifest "${MANIFESTS_DIR}/vault/ingress.yaml")
    log_info "Applying Vault ingress..."
    kubectl apply -f "${ingress_file}" --request-timeout=30s || {
        rm -f "${ingress_file}"
        log_error "Failed to apply Vault ingress"
        return 1
    }
    rm -f "${ingress_file}"

    # Wait for deployment
    wait_for_pods_ready "${VAULT_NAMESPACE}" "app.kubernetes.io/name=vault" || {
        log_warn "Vault pods not ready yet"
    }

    # Wait for certificate
    wait_for_certificate_ready "${VAULT_NAMESPACE}" "vault-tls" || {
        log_warn "Certificate not ready yet (may take a few minutes)"
    }

    # Initialize Vault (only if not already initialized)
    log_info "Checking Vault initialization status..."
    local vault_status
    vault_status=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status -tls-skip-verify -format=json 2>/dev/null || true)

    if [[ -n "${vault_status}" ]] && echo "${vault_status}" | jq -e '.initialized == true' &>/dev/null; then
        log_ok "Vault is already initialized"
        save_credential "vault" \
            "URL: https://${VAULT_HOST}" \
            "Status: Already initialized (unseal keys were shown at first init)"
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
    kubectl delete certificate -n "${VAULT_NAMESPACE}" vault-tls --ignore-not-found
    kubectl delete pvc -n "${VAULT_NAMESPACE}" --all --ignore-not-found
    log_ok "Vault uninstalled"
    log_warn "Released PersistentVolume(s) may still exist on the host — remove manually if reclaim policy is Retain"
}

#######################################
# Maintenance Functions
#######################################

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
        local rendered_values rendered_cert rendered_ingress
        rendered_values=$(render_manifest "${MANIFESTS_DIR}/vault/values.yaml")
        upgrade_helm_release "${VAULT_RELEASE}" \
            "${VAULT_REPO_NAME}/vault" \
            "${VAULT_NAMESPACE}" \
            "${rendered_values}" || {
            rm -f "${rendered_values}"
            log_error "Failed to update Vault Helm release"
            return 1
        }
        rm -f "${rendered_values}"
        rendered_cert=$(render_manifest "${MANIFESTS_DIR}/vault/certificate.yaml")
        kubectl apply -f "${rendered_cert}" --request-timeout=30s || {
            log_warn "Failed to apply Vault certificate"
        }
        rm -f "${rendered_cert}"
        rendered_ingress=$(render_manifest "${MANIFESTS_DIR}/vault/ingress.yaml")
        kubectl apply -f "${rendered_ingress}" --request-timeout=30s || {
            log_warn "Failed to apply Vault ingress"
        }
        rm -f "${rendered_ingress}"
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

main() {
    log_info "=== MicroK8s Setup Script Started ==="
    log_info "Configuration file: ${CONFIG_FILE}"

    # Parse arguments
    parse_arguments "$@"

    # Apply environment-specific hostnames
    apply_environment

    # Validate configuration
    validate_config

    # Handle --show-config
    if [[ "${SHOW_CONFIG}" == "true" ]]; then
        show_config
        exit 0
    fi

    # Handle --check
    if [[ "${RUN_CHECK}" == "true" ]]; then
        run_health_check
        exit $?
    fi

    # Handle maintenance operations (don't require root)
    if [[ "${SHOW_INFRA_STATUS}" == "true" ]]; then
        infra_show_status
        exit $?
    fi

    if [[ "${GET_KUBE_TOKEN}" == "true" ]]; then
        infra_get_kube_token
        exit $?
    fi

    if [[ "${SHOW_CREDENTIALS}" == "true" ]]; then
        infra_show_credentials
        exit $?
    fi

    if [[ "${SHOW_URLS}" == "true" ]]; then
        infra_show_urls
        exit $?
    fi

    if [[ "${VERIFY_TLS}" == "true" ]]; then
        infra_verify_tls
        exit $?
    fi

    if [[ -n "${SHOW_LOGS}" ]]; then
        infra_show_logs "${SHOW_LOGS}"
        exit $?
    fi

    if [[ -n "${RESTART_APP}" ]]; then
        restart_app "${RESTART_APP}"
        exit $?
    fi

    if [[ -n "${UPGRADE_APP}" ]]; then
        upgrade_app "${UPGRADE_APP}"
        exit $?
    fi

    if [[ -n "${UPDATE_INGRESS}" ]]; then
        update_ingress "${UPDATE_INGRESS}"
        exit $?
    fi

    # Handle --update-cli-tools
    if [[ "${UPDATE_CLI_TOOLS}" == "true" ]]; then
        check_root || die "Root privileges required"
        FORCE_INSTALL=true
        install_cli_tools || log_warn "Some CLI tools may not have updated"
        exit $?
    fi

    # If verify only, run verification and exit
    if [[ "${VERIFY_ONLY}" == "true" ]]; then
        verify_installation
        exit $?
    fi

    # Handle uninstall operations (require root)
    if [[ "${CLEANUP_KUBE}" == "true" ]]; then
        check_root || die "Root privileges required"
        uninstall_kube
        exit $?
    fi

    if [[ "${CLEANUP_ARGOCD}" == "true" ]]; then
        check_root || die "Root privileges required"
        uninstall_argocd
        exit $?
    fi

    if [[ "${CLEANUP_VAULT}" == "true" ]]; then
        check_root || die "Root privileges required"
        uninstall_vault
        exit $?
    fi

    # Check if any deployment flags are set
    local deploying_infra=false
    if [[ "${DEPLOY_KUBE}" == "true" || "${DEPLOY_ARGOCD}" == "true" || "${DEPLOY_VAULT}" == "true" ]]; then
        deploying_infra=true
    fi

    # Check if any installation flags are set
    local installing_k8s=false
    if [[ "${INSTALL_MICROK8S}" == "true" || "${CONFIGURE_STORAGE}" == "true" || \
          "${CONFIGURE_CERT_MANAGER}" == "true" || "${INSTALL_CLI_TOOLS}" == "true" || \
          "${SETUP_ALIASES}" == "true" ]]; then
        installing_k8s=true
    fi

    # Pre-flight checks (only if installing or deploying)
    if [[ "${installing_k8s}" == "true" || "${deploying_infra}" == "true" ]]; then
        log_step "Running pre-flight checks..."
        check_root || die "Root privileges required"

        if [[ "${installing_k8s}" == "true" ]]; then
            check_ubuntu || die "Ubuntu OS required"

            if [[ "${CONFIGURE_STORAGE}" == "true" && -n "${STORAGE_PATH}" ]]; then
                check_storage_mount || die "Storage not properly mounted"
            fi
        fi
    fi

    # Show summary and confirm for Kubernetes installation
    if [[ "${installing_k8s}" == "true" ]]; then
        show_summary
    fi

    # Install MicroK8s
    if [[ "${INSTALL_MICROK8S}" == "true" ]]; then
        install_microk8s || die "MicroK8s installation failed"
        add_user_to_group || log_warn "Failed to add user to group"
        enable_addons || die "Addon enablement failed"
    fi

    # Configure storage
    if [[ "${CONFIGURE_STORAGE}" == "true" ]]; then
        configure_hostpath_storage || die "Storage configuration failed"
    fi

    # Configure cert-manager
    if [[ "${CONFIGURE_CERT_MANAGER}" == "true" ]]; then
        configure_cert_manager || log_warn "Cert-manager configuration incomplete"
    fi

    # Install CLI tools
    if [[ "${INSTALL_CLI_TOOLS}" == "true" ]]; then
        install_cli_tools || log_warn "Some CLI tools may not be installed"
    fi

    # Setup aliases
    if [[ "${SETUP_ALIASES}" == "true" ]]; then
        setup_kubectl_alias || log_warn "kubectl alias setup failed"
        setup_helm_alias || log_warn "helm alias setup failed"
    fi

    # Export kubeconfig
    if [[ "${installing_k8s}" == "true" ]]; then
        export_kubeconfig || log_warn "Kubeconfig export failed"
    fi

    # Verify installation
    if [[ "${installing_k8s}" == "true" ]]; then
        verify_installation || log_warn "Verification found issues"
    fi

    # Deploy infrastructure applications
    if [[ "${DEPLOY_KUBE}" == "true" ]]; then
        deploy_kube || log_warn "Dashboard deployment had issues"
    fi

    if [[ "${DEPLOY_ARGOCD}" == "true" ]]; then
        deploy_argocd || log_warn "ArgoCD deployment had issues"
    fi

    if [[ "${DEPLOY_VAULT}" == "true" ]]; then
        deploy_vault || log_warn "Vault deployment had issues"
    fi

    # Print summary
    if [[ "${installing_k8s}" == "true" ]]; then
        print_summary
    fi

    log_info "=== MicroK8s Setup Script Completed ==="
}

main "$@"
