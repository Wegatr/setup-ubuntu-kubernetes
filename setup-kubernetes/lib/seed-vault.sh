#!/usr/bin/env bash
# lib/seed-vault.sh — Vault seed step. Reads configs/secrets.<env>, configures
# the prereqs ESO needs (kv-v2 mount, kubernetes auth, external-secrets policy
# + role with bound app namespaces), then writes one KV-v2 entry per app from
# VAULT_SCHEMA.
#
# Re-runnable: every step is idempotent.
#   - `vault secrets enable` / `vault auth enable`: skipped when already mounted
#   - `vault write auth/.../config`, `vault policy write`, `vault write
#     auth/.../role/...`: always overwrite-on-write
#   - `vault kv put` on a KV-v2 mount: creates a new VERSION, the current view
#     becomes the new values (older versions stay in history for rollback,
#     Vault keeps the last 10 by default)
# Re-running with new values in configs/secrets.<env> replaces what apps see.
#
# Globals consumed (set by lib/cli.sh):
#   VAULT_NAMESPACE, VAULT_HOST, DEPLOY_ENV, CONFIGS_DIR, CREDENTIALS_DIR
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/seed-vault.sh requires common-kubernetes.sh" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Internal helper: parse one VAULT_SCHEMA row into (var, category, name, key).
# Accepts both 4-field (var|category|name|key) and legacy 3-field rows
# (var|name|key, where category defaults to "app"). Writes the four parts to
# the caller-provided named variables.
# Args: $1=row, $2=out_var, $3=out_category, $4=out_name, $5=out_key
# ----------------------------------------------------------------------------
_seed_vault_parse_row() {
    local row="$1"
    local -n _v="$2" _c="$3" _n="$4" _k="$5"
    local f1 f2 f3 f4
    # bash `read -d ''` would swallow lines; use a plain IFS read.
    IFS='|' read -r f1 f2 f3 f4 <<<"$row"
    if [[ -z "${f4}" ]]; then
        # 3-field legacy form: VAR|name|key  → category defaults to "app".
        _v="$f1"; _c="app"; _n="$f2"; _k="$f3"
    else
        _v="$f1"; _c="$f2"; _n="$f3"; _k="$f4"
    fi
}

# ----------------------------------------------------------------------------
# Build a flat JSON object {k1: v1, k2: v2, ...} for one (category, name)
# tuple from VAULT_SCHEMA. Suitable for piping to `vault kv put` via @file.
# Uses jq --arg so every value gets proper JSON-string escaping regardless of
# whether it's a single token, a multi-line PEM, or contains $ / " / newlines.
# Args: $1=category, $2=name
# Stdout: JSON document.
# ----------------------------------------------------------------------------
_seed_vault_build_entry_json() {
    local target_cat="$1" target_name="$2"
    local row var cat name key
    local -a jq_args=()
    local jq_filter='{'
    local first=1
    local i=0

    for row in "${VAULT_SCHEMA[@]}"; do
        _seed_vault_parse_row "$row" var cat name key
        [[ "$cat" == "$target_cat" && "$name" == "$target_name" ]] || continue

        local arg_name="v${i}"
        jq_args+=(--arg "$arg_name" "${!var-}")
        if (( first )); then
            first=0
        else
            jq_filter+=', '
        fi
        jq_filter+="\"${key}\": \$${arg_name}"
        i=$((i + 1))
    done
    jq_filter+='}'

    jq -n "${jq_args[@]}" "$jq_filter"
}

seed_vault() {
    log_step "Seeding Vault..."

    local secrets_file="${CONFIGS_DIR}/secrets.${DEPLOY_ENV}"
    local creds_file="${CREDENTIALS_DIR}/vault-${DEPLOY_ENV}.txt"

    # --- Sanity checks ------------------------------------------------------
    if [[ ! -f "${secrets_file}" ]]; then
        log_error "Secrets file not found: ${secrets_file}"
        log_error "Copy setup-kubernetes/configs/secrets.example to ${secrets_file} and fill it in."
        return 1
    fi

    if [[ ! -f "${creds_file}" ]]; then
        log_error "Vault credentials file not found: ${creds_file}"
        log_error "Run --deploy-vault first to initialize Vault."
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required for --seed-vault. Install it: apt install jq"
        return 1
    fi

    if ! kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- /bin/true &>/dev/null; then
        log_error "vault-0 is not exec-able. Is the Vault pod Running?"
        log_error "Diagnose with: kubectl describe pod -n ${VAULT_NAMESPACE} vault-0"
        return 1
    fi

    # --- Extract root token + verify Vault is unsealed ----------------------
    local root_token
    root_token=$(grep -m1 '^Root Token:' "${creds_file}" | awk '{print $3}')
    if [[ -z "${root_token}" ]]; then
        log_error "No 'Root Token:' line in ${creds_file}"
        log_error "If Vault was initialized externally, set VAULT_ROOT_TOKEN in the env and re-run."
        return 1
    fi
    # Allow env-var override (e.g. when running from an automation pipeline).
    root_token="${VAULT_ROOT_TOKEN:-${root_token}}"

    # Local Vault listener is HTTPS (TLS issued by cert-manager). Use
    # -tls-skip-verify because the cert's SAN list doesn't include 127.0.0.1.
    # NOTE on jq: `.sealed // "true"` would be wrong here — jq's `//` operator
    # treats `false` as nullish and would return the alternative for a vault
    # that is actually unsealed. Read the raw value; bash gets literal
    # "true"/"false"/"null".
    local sealed
    sealed=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- sh -c \
        'VAULT_ADDR=https://127.0.0.1:8200 vault status -tls-skip-verify -format=json 2>/dev/null' \
        | jq -r '.sealed')
    if [[ "${sealed}" != "false" ]]; then
        log_error "Vault is sealed (or status unreadable; jq returned: ${sealed})."
        log_error "Unseal with 3 of the 5 keys in ${creds_file}:"
        log_error "  kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- vault operator unseal -tls-skip-verify <KEY>"
        return 1
    fi
    log_ok "Vault is unsealed."

    # --- Source secrets file + validate every required var is non-empty -----
    # Don't pollute global namespace with junk by sourcing in a sub-environment
    # — but we DO need VAULT_SCHEMA + every variable referenced by it in our
    # current process so the loop below can read them. So source directly.
    # shellcheck disable=SC1090
    source "${secrets_file}"

    if [[ -z "${VAULT_SCHEMA[*]:-}" ]]; then
        log_error "${secrets_file} did not define VAULT_SCHEMA (or it's empty)."
        return 1
    fi

    local row var cat name key missing=()
    for row in "${VAULT_SCHEMA[@]}"; do
        _seed_vault_parse_row "$row" var cat name key
        if [[ -z "${!var-}" ]]; then
            missing+=("$var")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "Secrets file is missing values for these variables:"
        local m; for m in "${missing[@]}"; do log_error "  $m"; done
        log_error "Edit ${secrets_file} and fill them in."
        return 1
    fi

    # --- Distinct (category, name) tuples ------------------------------------
    # Two outputs:
    #   entries          — every (category,name) we'll write to Vault
    #   workload_apps    — distinct names with category=app, for the
    #                      external-secrets role's bound_service_account_
    #                      namespaces. (system/ entries are control-plane
    #                      creds; their namespaces do not run ESO.)
    local -A entry_seen
    local -a entries=()
    local -A workload_seen
    local -a workload_apps=()
    for row in "${VAULT_SCHEMA[@]}"; do
        _seed_vault_parse_row "$row" var cat name key
        local tuple="${cat}|${name}"
        if [[ -z "${entry_seen[$tuple]:-}" ]]; then
            entries+=("$tuple")
            entry_seen[$tuple]=1
        fi
        if [[ "$cat" == "app" && -z "${workload_seen[$name]:-}" ]]; then
            workload_apps+=("$name")
            workload_seen[$name]=1
        fi
    done

    # External tenants that are NOT in this repo's VAULT_SCHEMA but DO run
    # ESO + a `vault-backend` SecretStore in their own namespace + need
    # read access against this Vault. Listed in configs/config.<env> as
    # EXTERNAL_ESO_NAMESPACES=(my-tenant-ns another-app-ns). Each entry
    # gets added to the role's bound_service_account_namespaces so its
    # `external-secrets-sa` SA can log in.
    for ns in "${EXTERNAL_ESO_NAMESPACES[@]:-}"; do
        [[ -z "${ns}" ]] && continue
        if [[ -z "${workload_seen[$ns]:-}" ]]; then
            workload_apps+=("$ns")
            workload_seen[$ns]=1
        fi
    done

    local namespaces_csv
    namespaces_csv=$(IFS=,; echo "${workload_apps[*]}")

    # --- Bind system:auth-delegator to vault's SA so it can validate JWTs ---
    # Idempotent via kubectl apply on a generated manifest. The Vault Helm
    # chart creates SA `vault` in VAULT_NAMESPACE; ESO logs in as
    # external-secrets-sa in each app namespace, and Vault validates that
    # incoming token via the TokenReview API — which requires the
    # system:auth-delegator role.
    log_info "Ensuring ClusterRoleBinding vault-auth-delegator (system:auth-delegator → ${VAULT_NAMESPACE}:vault)..."
    if ! kubectl create clusterrolebinding vault-auth-delegator \
            --clusterrole=system:auth-delegator \
            --serviceaccount="${VAULT_NAMESPACE}:vault" \
            --dry-run=client -o yaml 2>/dev/null \
         | kubectl apply -f - >/dev/null; then
        log_warn "Failed to apply vault-auth-delegator ClusterRoleBinding (continuing — it may already exist)."
    fi

    # --- Vault prereqs: kv-v2 mount, kubernetes auth, policy, role ----------
    # Pipe a shell script into vault-0 over `kubectl exec -i`. Local listener
    # http://127.0.0.1:8200 avoids the public-TLS dance. Heredoc is unquoted
    # so ${root_token} and ${namespaces_csv} expand here and arrive as
    # literals inside the pod.
    log_info "Configuring Vault prerequisites (kv-v2 + kubernetes auth + policy + role)..."
    if ! kubectl exec -n "${VAULT_NAMESPACE}" -i vault-0 -- sh -s <<INNER
set -e
# Local listener is HTTPS with a cert that doesn't have 127.0.0.1 in its
# SAN list — skip TLS verification for the in-pod loopback only.
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
export VAULT_TOKEN='${root_token}'

# Mount KV-v2 at secret/ if not already mounted.
if ! vault secrets list -format=json 2>/dev/null | grep -q '"secret/"'; then
  vault secrets enable -path=secret kv-v2
  echo "[seed-vault] enabled kv-v2 at secret/"
else
  echo "[seed-vault] kv-v2 already mounted at secret/"
fi

# Enable kubernetes auth at the default path if not already enabled.
if ! vault auth list -format=json 2>/dev/null | grep -q '"kubernetes/"'; then
  vault auth enable kubernetes
  echo "[seed-vault] enabled kubernetes auth at auth/kubernetes/"
else
  echo "[seed-vault] kubernetes auth already enabled"
fi

# Configure the auth method (always overwrite — idempotent).
# disable_iss_validation=true tolerates JWTs issued by older K8s versions
# whose 'iss' claim doesn't match the strict-mode value Vault expects.
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  disable_iss_validation=true >/dev/null
echo "[seed-vault] wrote auth/kubernetes/config"

# external-secrets policy: read-only on secret/data/* and secret/metadata/*.
vault policy write external-secrets - >/dev/null <<'POLICY'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read"]
}
POLICY
echo "[seed-vault] wrote policy external-secrets"

# external-secrets role: every app namespace where charts/secret-store/
# materializes the SA external-secrets-sa.
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets-sa \
  bound_service_account_namespaces='${namespaces_csv}' \
  policies=external-secrets \
  ttl=24h >/dev/null
echo "[seed-vault] wrote role auth/kubernetes/role/external-secrets (namespaces: ${namespaces_csv})"
INNER
    then
        log_error "Vault prerequisite configuration failed."
        return 1
    fi
    log_ok "Vault prerequisites configured."

    # --- Write KV entries — one per (category, name) tuple -----------------
    # Pipe a flat JSON object on stdin into the pod, stage to a temp file,
    # then `vault kv put @file`. The CLI handles KV-v2 versioning: each call
    # creates a new version (older versions stay in history). Token and path
    # are passed as positional args so $-bearing values in the JSON body
    # never go through shell quoting.
    log_info "Writing KV-v2 entries (each call creates a new version)..."
    local kv_path body tuple cat name
    for tuple in "${entries[@]}"; do
        IFS='|' read -r cat name <<<"$tuple"
        body=$(_seed_vault_build_entry_json "$cat" "$name") || {
            log_error "Failed to build JSON body for ${cat}/${name}"
            return 1
        }
        kv_path="${DEPLOY_ENV}/${cat}/${name}"

        # `vault kv put` accepts @file (NOT @- for stdin), so stage the JSON
        # body to a temp file inside the pod, write it, then delete it. The
        # `trap` makes sure the file is cleaned up even if `vault` fails.
        if ! echo "${body}" | kubectl exec -n "${VAULT_NAMESPACE}" -i vault-0 -- \
                sh -c '
                    set -e
                    token="$1"; path="$2"
                    # busybox mktemp on alpine rejects a suffix after XXXXXX,
                    # so leave the random portion at the end.
                    f=$(mktemp /tmp/seed-vault.XXXXXX)
                    trap "rm -f \"$f\"" EXIT
                    cat > "$f"
                    export VAULT_ADDR=https://127.0.0.1:8200
                    export VAULT_SKIP_VERIFY=true
                    export VAULT_TOKEN="$token"
                    vault kv put "secret/$path" @"$f" >/dev/null
                ' _ "${root_token}" "${kv_path}"
        then
            log_error "  FAILED  secret/${kv_path}"
            return 1
        fi
        log_ok  "  wrote   secret/${kv_path}  ($(echo "$body" | jq 'length') keys)"
    done

    log_ok "Vault seeded for env=${DEPLOY_ENV}."
    echo
    log_info "Verify:"
    log_info "  kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- sh -c '"
    log_info "    VAULT_TOKEN=<root> vault kv list secret/${DEPLOY_ENV}/app/'"
    log_info "  kubectl exec -n ${VAULT_NAMESPACE} vault-0 -- sh -c '"
    log_info "    VAULT_TOKEN=<root> vault kv get secret/${DEPLOY_ENV}/app/mongodb'"
    return 0
}
