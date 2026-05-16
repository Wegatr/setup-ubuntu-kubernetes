#!/usr/bin/env bash
# setup-kubernetes.sh
# Unified one-touch installer for a MicroK8s 1.35 Kubernetes cluster + the
# three Helm-managed control-plane apps (Headlamp, ArgoCD, HashiCorp Vault).
#
# This file is a THIN DISPATCHER. Every actual operation lives in lib/<topic>.sh
# (sourced below). Behavior is byte-identical to the pre-split monolith —
# every flag, every output, every exit code is preserved.
#
# Usage: sudo ./setup-kubernetes.sh [OPTIONS]   (see --help for the full list)

set -uo pipefail

# Directory layout
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
CONFIGS_DIR="${SCRIPT_DIR}/configs"

# ---- Library sourcing ------------------------------------------------------
# common-kubernetes.sh MUST be sourced before any lib/*.sh (each lib has a
# sentinel guard that aborts if common is missing).

if [[ ! -f "${SCRIPT_DIR}/common-kubernetes.sh" ]]; then
    echo "ERROR: Common functions file not found: ${SCRIPT_DIR}/common-kubernetes.sh"
    exit 1
fi
# shellcheck source=common-kubernetes.sh
source "${SCRIPT_DIR}/common-kubernetes.sh"

# Lib files — order matters only in that cli.sh must come first (defines
# print_early_help, load_config, init_flag_defaults, parse_arguments, etc.
# that main() calls below).
for _lib in cli preflight install-microk8s install-storage-tls install-tools \
            verify deploy-idp deploy-kube deploy-argocd deploy-vault seed-vault \
            lifecycle maintenance; do
    if [[ ! -f "${LIB_DIR}/${_lib}.sh" ]]; then
        echo "ERROR: Missing library: ${LIB_DIR}/${_lib}.sh"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${LIB_DIR}/${_lib}.sh"
done
unset _lib

# ---- Early help / no-args (must work without a config loaded) --------------
if [[ $# -eq 0 ]]; then
    print_early_help
    exit 0
fi
for _arg in "$@"; do
    if [[ "$_arg" == "--help" || "$_arg" == "-h" ]]; then
        print_early_help
        exit 0
    fi
done
unset _arg

# ---- Load config + init flag defaults --------------------------------------
load_config "$@"          # sources configs/config.<env> or legacy config.<env>
init_logging              # creates /var/lib/kubernetes-setup if root
init_flag_defaults        # sets INSTALL_*/DEPLOY_*/SHOW_*/CREDENTIALS_DIR

# ---- main ------------------------------------------------------------------

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
    if [[ "${DEPLOY_IDP}" == "true" || "${DEPLOY_KUBE}" == "true" || "${DEPLOY_ARGOCD}" == "true" || "${DEPLOY_VAULT}" == "true" ]]; then
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

        if [[ "${deploying_infra}" == "true" ]]; then
            check_ingress_dns_resolves || die "Public DNS for ingress hostnames is missing — fix that before deploying."
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
        # Disable any addons the per-env config listed in DISABLED_ADDONS
        # (e.g. the built-in `registry` addon — superseded by GitOps-managed
        # Zot in apps/registry/). Idempotent + no-op when the array is empty.
        disable_addons || log_warn "Some DISABLED_ADDONS entries failed to disable"
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

    # Deploy infrastructure applications.
    #
    # ORDER MATTERS: IdP first — ArgoCD / Headlamp / Vault all consume the
    # `*-oidc` K8s Secrets that deploy_idp pre-creates in their namespaces.
    # If you re-run --deploy-argocd standalone, you can skip --deploy-idp
    # provided the secrets already exist from a prior bootstrap.
    if [[ "${DEPLOY_IDP}" == "true" ]]; then
        deploy_idp || log_warn "IdP deployment had issues"
    fi

    if [[ "${DEPLOY_KUBE}" == "true" ]]; then
        deploy_kube || log_warn "Dashboard deployment had issues"
    fi

    if [[ "${DEPLOY_ARGOCD}" == "true" ]]; then
        deploy_argocd || log_warn "ArgoCD deployment had issues"
    fi

    if [[ "${DEPLOY_VAULT}" == "true" ]]; then
        deploy_vault || log_warn "Vault deployment had issues"
    fi

    # Seed Vault. Runs AFTER deploy_vault when both flags are set so an
    # initial cluster bring-up can do --deploy-vault --seed-vault in one shot.
    # Also runnable standalone against an already-deployed Vault.
    if [[ "${SEED_VAULT}" == "true" ]]; then
        seed_vault || log_warn "Vault seeding had issues"
    fi

    # Print summary
    if [[ "${installing_k8s}" == "true" ]]; then
        print_summary
    fi

    log_info "=== MicroK8s Setup Script Completed ==="
}

main "$@"
