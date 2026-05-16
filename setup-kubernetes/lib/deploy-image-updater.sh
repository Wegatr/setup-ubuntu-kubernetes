#!/usr/bin/env bash
# lib/deploy-image-updater.sh — ArgoCD Image Updater (helm install in argocd
# namespace) so committed Zot-image tag bumps land automatically in git and
# ArgoCD reconciles them.
#
# Platform-tier (not GitOps): runs alongside ArgoCD itself, can't be managed
# by ArgoCD (chicken-and-egg). Install order is `idp → kube → argocd →
# vault → seed-vault → image-updater`.
#
# Per-app opt-in: an Application gets watched only when its
# `argocd/<env>/apps/applicationset.yaml` entry carries an `imageUpdater:`
# block. All existing 12 apps stay manual (they pin upstream Bitnami /
# Grafana / Prometheus versions). See CLAUDE.md "When you change the GitOps
# tree" for the per-app annotation block syntax.
#
# Credentials: reuses the same image-builder git PAT and Zot pull-user
# password the rest of the platform already uses — no new secret rotation
# surface added. Both are read from configs/secrets.<env> at deploy time
# and materialized into K8s Secrets directly (no ESO chicken-egg).
#
# Globals consumed: ENABLE_IMAGE_UPDATER, MANIFESTS_DIR,
#                   IMAGE_UPDATER_REPO_NAME, IMAGE_UPDATER_REPO_URL,
#                   IMAGE_UPDATER_NAMESPACE, IMAGE_UPDATER_RELEASE,
#                   DEPLOY_ENV, DOMAIN_SUFFIX, CONFIGS_DIR.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/deploy-image-updater.sh requires common-kubernetes.sh" >&2; exit 1; }

# Materialize the two Secrets Image Updater needs:
#   - argocd-image-updater-secret: git-token (HTTPS PAT extracted from the
#     image-builder gitcredentials multi-line file) + zot-creds (Zot pull
#     user:pw in registries.conf format).
#   - argocd-image-updater-zot-creds: dockerconfigjson for the Zot
#     registry, referenced from values.yaml's
#     `config.registries[].credentials: pullsecret:argocd/...`.
#
# Sources configs/secrets.<env> locally (NOT global env — these vars are
# only needed within this function). Idempotent kubectl apply.
_iu_apply_credentials_secret() {
    local secrets_file="${CONFIGS_DIR}/secrets.${DEPLOY_ENV}"
    if [[ ! -f "${secrets_file}" ]]; then
        log_warn "${secrets_file} not found — image-updater secrets will be empty (controller starts but can't authenticate)"
        return 0
    fi
    # shellcheck disable=SC1090
    source "${secrets_file}"

    # Extract token from the multi-line `https://<user>:<pat>@<host>` file
    # the image-builder git-clone task consumes. We only need the token
    # part for HTTPS push — git-credentials-store format is for git CLI,
    # image-updater wants just <pat> in GIT_PASSWORD env.
    local git_token=""
    if [[ -n "${IMAGE_BUILDER_GIT_CREDENTIALS:-}" ]]; then
        git_token=$(printf '%s\n' "${IMAGE_BUILDER_GIT_CREDENTIALS}" \
            | grep -oE 'https://[^:]+:[^@]+@' | head -1 \
            | sed -E 's|https://[^:]+:([^@]+)@|\1|')
    fi

    kubectl -n "${IMAGE_UPDATER_NAMESPACE}" create secret generic argocd-image-updater-secret \
        --from-literal=git-token="${git_token}" \
        --from-literal=git-username="argocd-image-updater" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Zot pull-user dockerconfigjson — referenced from values.yaml as
    # `pullsecret:argocd/argocd-image-updater-zot-creds`. Same creds the
    # workload namespaces use to pull images, just colocated here so
    # Image Updater can authenticate its registry-poll requests.
    if [[ -n "${REGISTRY_PULL_USER:-}" && -n "${REGISTRY_PULL_PASSWORD:-}" ]]; then
        kubectl -n "${IMAGE_UPDATER_NAMESPACE}" create secret docker-registry argocd-image-updater-zot-creds \
            --docker-server="zot.${DEPLOY_ENV}.${DOMAIN_SUFFIX}" \
            --docker-username="${REGISTRY_PULL_USER}" \
            --docker-password="${REGISTRY_PULL_PASSWORD}" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    else
        log_warn "REGISTRY_PULL_USER / REGISTRY_PULL_PASSWORD not set — Image Updater can't poll Zot until you add them to ${secrets_file} and re-run --deploy-image-updater"
    fi
}

deploy_image_updater() {
    if [[ "${ENABLE_IMAGE_UPDATER:-true}" != "true" ]]; then
        log_warn "Image Updater is disabled in config, skipping"
        return 0
    fi

    log_step "Deploying ArgoCD Image Updater..."

    add_helm_repo "${IMAGE_UPDATER_REPO_NAME}" "${IMAGE_UPDATER_REPO_URL}" || return 1
    update_helm_repos || return 1
    create_namespace_if_not_exists "${IMAGE_UPDATER_NAMESPACE}" || return 1

    # Pre-create the credentials Secrets so the pod's envFrom + volume
    # mounts have something to read on the first start (helm install
    # doesn't wait for these to exist — pod CrashLoopBackOff'd otherwise).
    _iu_apply_credentials_secret

    if is_helm_release_deployed "${IMAGE_UPDATER_RELEASE}" "${IMAGE_UPDATER_NAMESPACE}"; then
        log_info "Image Updater already deployed — running helm upgrade to apply any values changes"
    fi

    local values_file
    values_file=$(render_manifest "${MANIFESTS_DIR}/image-updater/values.yaml")
    install_helm_chart "${IMAGE_UPDATER_RELEASE}" \
        "${IMAGE_UPDATER_REPO_NAME}/argocd-image-updater" \
        "${IMAGE_UPDATER_NAMESPACE}" \
        "${values_file}" || {
        rm -f "${values_file}"
        log_error "Failed to deploy Image Updater"
        return 1
    }
    rm -f "${values_file}"

    wait_for_pods_ready "${IMAGE_UPDATER_NAMESPACE}" "app.kubernetes.io/name=argocd-image-updater" || {
        log_warn "Image Updater pods not ready yet — controller will retry on its own"
    }

    log_ok "ArgoCD Image Updater deployed successfully"
    log_info "Per-app opt-in: add an 'imageUpdater:' block to an entry in argocd/${DEPLOY_ENV}/apps/applicationset.yaml"
    return 0
}
