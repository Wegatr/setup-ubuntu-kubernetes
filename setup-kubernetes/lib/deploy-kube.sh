#!/usr/bin/env bash
# lib/deploy-kube.sh — Headlamp (Kubernetes Dashboard) deploy + the permanent
# service-account-token dance that the UI needs for cluster-admin access.
#
# Globals consumed: ENABLE_KUBE, FORCE_DEPLOY, MANIFESTS_DIR,
#                   KUBE_REPO_NAME, KUBE_REPO_URL, KUBE_NAMESPACE, KUBE_RELEASE,
#                   KUBE_HOST.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/deploy-kube.sh requires common-kubernetes.sh" >&2; exit 1; }

# Create a long-lived ServiceAccount token (the dashboard UI needs one to log in).
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
