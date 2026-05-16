#!/usr/bin/env bash
# lib/cli.sh — CLI parsing, help text, config-file resolution, environment
# derivation, manifest rendering. Sourced by setup-kubernetes.sh.
#
# Globals consumed:  SCRIPT_DIR, CONFIGS_DIR, MANIFESTS_DIR (from dispatcher).
# Globals produced:  all the INSTALL_*/DEPLOY_*/SHOW_*/RESTART_* flags via
#                    init_flag_defaults() and parse_arguments(); plus
#                    KUBE_HOST/ARGOCD_HOST/VAULT_HOST via apply_environment().
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/cli.sh requires common-kubernetes.sh" >&2; exit 1; }

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

# Minimal help text shown BEFORE the config file is sourced (on --help or no args).
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
    --seed-vault                  Write secrets from configs/secrets.<env>
                                  into Vault (KV-v2). Re-runnable: each call
                                  replaces the latest version of each entry.

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
    Copy configs/config.example to configs/config.<env> and edit it.
    Available configs: $(list_available_configs)
HELPEOF
}

# Resolve which config file to source based on positional args.
# Pre-scans for --dev/--test/--prod/--config before full parse_arguments runs.
# Exports CONFIG_FILE; exits with diagnostic if no usable config is found.
load_config() {
    local DEPLOY_ENV_ARG=""
    local CUSTOM_CONFIG=""
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
            CONFIG_FILE="${CONFIGS_DIR}/config.${DEPLOY_ENV_ARG}"
        fi
    else
        local env CANDIDATE
        for env in prod dev test; do
            CANDIDATE=$(resolve_config_for_env "$env")
            if [[ -n "${CANDIDATE}" ]]; then
                CONFIG_FILE="${CANDIDATE}"
                break
            fi
        done
        if [[ -z "${CONFIG_FILE:-}" ]]; then
            echo "ERROR: No configuration file found."
            echo "       Copy configs/config.example to configs/config.<env> (e.g. configs/config.dev) and customise it."
            echo "       Available: $(list_available_configs)"
            exit 1
        fi
    fi

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
        echo "       Copy configs/config.example to configs/config.<env> and customise it."
        echo "       Available: $(list_available_configs)"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    export CONFIG_FILE
}

# Initialize default values for every flag parse_arguments may set.
# Called by the dispatcher after load_config but before parse_arguments.
init_flag_defaults() {
    # Installation flags
    INSTALL_MICROK8S=true
    CONFIGURE_STORAGE=true
    CONFIGURE_CERT_MANAGER=true
    INSTALL_CLI_TOOLS=true
    SETUP_ALIASES=true
    FORCE_INSTALL=false
    VERIFY_ONLY=false

    # Deployment flags
    DEPLOY_IDP=false
    DEPLOY_KUBE=false
    DEPLOY_ARGOCD=false
    DEPLOY_VAULT=false
    SEED_VAULT=false
    FORCE_DEPLOY=false

    # Cleanup flags
    CLEANUP_IDP=false
    CLEANUP_KUBE=false
    CLEANUP_ARGOCD=false
    CLEANUP_VAULT=false

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

    # CREDENTIALS_DIR depends on MICROK8S_USER (set by the config file).
    CREDENTIALS_DIR="/home/${MICROK8S_USER}/secrets"
}

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
            --deploy-idp)
                DEPLOY_IDP=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
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
                # IdP MUST come before ArgoCD so the OIDC clientSecret K8s
                # Secrets are pre-created in each consumer namespace by the
                # time their helm install runs.
                DEPLOY_IDP=true; DEPLOY_KUBE=true; DEPLOY_ARGOCD=true; DEPLOY_VAULT=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --seed-vault)
                # Standalone-friendly: don't disable other flags so it composes
                # with --deploy-vault for a one-shot bring-up. Pre-flight DNS
                # check is skipped because this step doesn't touch the public
                # ingress — it talks to vault-0 via kubectl exec only.
                SEED_VAULT=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift
                ;;
            --install-idp) # alias for --deploy-idp
                DEPLOY_IDP=true
                INSTALL_MICROK8S=false; CONFIGURE_STORAGE=false; CONFIGURE_CERT_MANAGER=false; INSTALL_CLI_TOOLS=false; SETUP_ALIASES=false
                shift ;;
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
            --uninstall-idp) CLEANUP_IDP=true; shift ;;
            --uninstall-kube) CLEANUP_KUBE=true; shift ;;
            --uninstall-argocd) CLEANUP_ARGOCD=true; shift ;;
            --uninstall-vault) CLEANUP_VAULT=true; shift ;;
            --upgrade-idp) UPGRADE_APP="idp"; shift ;;
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
    IDP_HOST="${IDP_HOST_PREFIX:-idp}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    KUBE_HOST="${KUBE_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    ARGOCD_HOST="${ARGOCD_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    VAULT_HOST="${VAULT_HOST_PREFIX}.${DEPLOY_ENV}.${DOMAIN_SUFFIX}"
    log_info "Environment: ${DEPLOY_ENV} (hosts: ${IDP_HOST}, ${KUBE_HOST}, ${ARGOCD_HOST}, ${VAULT_HOST})"
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
        -e "s|__IDP_HOST__|${IDP_HOST:-}|g" \
        -e "s|__CLUSTER_ISSUER__|${CLUSTER_ISSUER_NAME}|g" \
        -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
        -e "s|__VAULT_STORAGE_SIZE__|${VAULT_STORAGE_SIZE}|g" \
        -e "s|__IDP_SECRET_KEY__|${IDP_SECRET_KEY:-}|g" \
        -e "s|__IDP_BOOTSTRAP_PASSWORD__|${IDP_BOOTSTRAP_PASSWORD:-}|g" \
        -e "s|__IDP_BOOTSTRAP_EMAIL__|${IDP_BOOTSTRAP_EMAIL:-}|g" \
        -e "s|__IDP_POSTGRES_PASSWORD__|${IDP_POSTGRES_PASSWORD:-}|g" \
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
    --seed-vault                  Configure Vault prereqs (kv-v2, kubernetes
                                  auth, external-secrets policy + role) and
                                  write configs/secrets.<env> into Vault.
                                  Idempotent — safe to re-run; each call
                                  supersedes the previous KV-v2 version.
                                  Composes with --deploy-vault for a one-shot
                                  bring-up:  --dev --deploy-vault --seed-vault

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
