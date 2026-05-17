#!/usr/bin/env bash
# lib/install-microk8s.sh — MicroK8s installation + the four OS-specific
# workarounds the comments call out as load-bearing:
#   - configure_kube_proxy_nftables (avoid kube-proxy/Calico backend split)
#   - fix_coredns_upstream         (systemd-resolved doesn't reach pods)
#   - align_calico_backend         (NFT vs legacy iptables backend mismatch)
#
# Globals consumed: MICROK8S_CHANNEL, MICROK8S_USER, ADDONS, DISABLED_ADDONS,
#                   FORCE_INSTALL, DNS_UPSTREAM_SERVERS, DNS_FORCE_TCP.
[[ -z "${_COMMON_KUBERNETES_LOADED:-}" ]] && { echo "lib/install-microk8s.sh requires common-kubernetes.sh" >&2; exit 1; }

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

    # Configure kube-proxy to use native nftables mode BEFORE any addon is
    # enabled. MicroK8s 1.35+ defaults kube-proxy to ipvs/iptables-legacy,
    # which then conflicts with Calico Felix (NFT) — host-to-pod and
    # pod-to-pod traffic gets dropped because rules end up in two different
    # backends. Setting this immediately after install means kube-proxy
    # paints to native nf_tables on its first run; no legacy/IPVS rules
    # ever get written.
    configure_kube_proxy_nftables || log_warn "kube-proxy nftables configuration incomplete"

    return 0
}

# Pin kube-proxy to native nftables mode by appending --proxy-mode=nftables
# to /var/snap/microk8s/current/args/kube-proxy and restarting kubelite.
# Idempotent: skips both the append and the restart if already configured.
configure_kube_proxy_nftables() {
    local args_file="/var/snap/microk8s/current/args/kube-proxy"

    if [[ ! -f "${args_file}" ]]; then
        log_warn "kube-proxy args file not present at ${args_file} — skipping"
        return 0
    fi

    if grep -q -- '--proxy-mode=' "${args_file}"; then
        log_ok "kube-proxy proxy-mode already set: $(grep -- '--proxy-mode=' "${args_file}")"
        return 0
    fi

    log_step "Setting kube-proxy --proxy-mode=nftables..."
    echo '--proxy-mode=nftables' >> "${args_file}" || {
        log_error "Failed to write to ${args_file}"
        return 1
    }

    log_info "Restarting kubelite to pick up the new kube-proxy args..."
    systemctl restart snap.microk8s.daemon-kubelite.service || {
        log_warn "kubelite restart failed — kube-proxy will pick up the new mode on the next snap restart"
    }

    wait_for_microk8s_ready 120 || log_warn "MicroK8s slow to settle after kubelite restart"
    log_ok "kube-proxy now using native nftables proxier"
}

# Configure kube-apiserver to trust OIDC tokens issued by the platform IdP
# (Authentik). Required for Headlamp to authenticate users — Headlamp
# forwards the user's id_token to the API server as a bearer token, and
# without these flags the API server rejects every request with 401.
#
# Idempotent: writes one flag at a time, skipping any already present
# with the same value, replacing in place if the value drifted. Restarts
# kubelite only if at least one flag changed.
#
# IDP_HOST must be set in the env (sourced from configs/config.<env>).
# Safe to call before Authentik is up — kube-apiserver doesn't crash on
# an unreachable issuer URL, it just fails token validation until the
# URL becomes reachable.
configure_kube_apiserver_oidc() {
    local args_file="/var/snap/microk8s/current/args/kube-apiserver"

    if [[ ! -f "${args_file}" ]]; then
        log_warn "kube-apiserver args file not present at ${args_file} — skipping"
        return 0
    fi

    if [[ -z "${IDP_HOST:-}" ]]; then
        log_warn "IDP_HOST not set in config — skipping kube-apiserver OIDC wiring"
        return 0
    fi

    local issuer_url="https://${IDP_HOST}/application/o/headlamp/"
    # client_id MUST equal the OAuth2Provider's client_id in Authentik
    # for `headlamp`. The id_token's `aud` claim is checked against
    # this value during validation.
    #
    # username-claim is `preferred_username`, NOT `email`, deliberately:
    # K8s' OIDC authenticator hard-codes a check that rejects the token
    # when claim=="email" and `email_verified` is not true. Authentik's
    # default OAuth2 email scope mapping returns `email_verified: false`
    # for users without an explicit verification flow, breaking login
    # for the bootstrap admin and any UI-created user. `preferred_username`
    # carries the Authentik username (e.g. "akadmin") and is checked
    # without the verified-flag dependency. Resulting K8s username
    # becomes `oidc:<username>` (e.g. `oidc:akadmin`); ClusterRoleBindings
    # match users via the `oidc:` prefix.
    declare -A desired=(
        ["--oidc-issuer-url"]="${issuer_url}"
        ["--oidc-client-id"]="headlamp"
        ["--oidc-username-claim"]="preferred_username"
        ["--oidc-username-prefix"]="oidc:"
        ["--oidc-groups-claim"]="groups"
        ["--oidc-groups-prefix"]="oidc:"
    )

    local changed=0
    local flag value current_line
    for flag in "${!desired[@]}"; do
        value="${desired[${flag}]}"
        current_line=$(grep -E "^${flag}=" "${args_file}" || true)
        if [[ -n "${current_line}" ]]; then
            if [[ "${current_line}" == "${flag}=${value}" ]]; then
                continue
            fi
            # In-place value update
            sed -i "s|^${flag}=.*|${flag}=${value}|" "${args_file}"
            changed=1
            log_info "Updated ${flag} → ${value}"
        else
            echo "${flag}=${value}" >> "${args_file}"
            changed=1
            log_info "Added ${flag}=${value}"
        fi
    done

    if [[ ${changed} -eq 0 ]]; then
        log_ok "kube-apiserver OIDC flags already set for ${IDP_HOST}"
        return 0
    fi

    log_step "Restarting kubelite to apply kube-apiserver OIDC flags..."
    systemctl restart snap.microk8s.daemon-kubelite.service || {
        log_warn "kubelite restart failed — flags will activate on next snap restart"
    }
    wait_for_microk8s_ready 120 || log_warn "MicroK8s slow to settle after kubelite restart"
    log_ok "kube-apiserver now trusts OIDC tokens from ${issuer_url}"
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

    # Align Calico's iptables backend with the host's default. Modern Calico
    # defaults to Auto-detect, but on bleeding-edge kernels (notably 26.04 /
    # kernel 7.0) the auto-detect can pick Legacy while the host runs nft —
    # the resulting split-brain shows up as pod-to-internet DNS lookups timing
    # out from CoreDNS to its upstream resolvers. Safe to call on every run.
    align_calico_backend || log_warn "Calico backend alignment incomplete"

    # Allow Ingresses to reference Traefik Middlewares in a different namespace.
    # Default is locked-down (same-namespace only). We need cross-namespace so
    # the shared `forwardauth` Middleware in the `idp` namespace (Authentik
    # embedded Outpost) can gate Ingresses living in tekton / dbgate / seq /
    # other future apps. Safe to call on every run.
    configure_traefik_addon || log_warn "Traefik cross-namespace config incomplete"

    if [[ ${#failed_addons[@]} -gt 0 ]]; then
        log_error "Failed to enable addons: ${failed_addons[*]}"
        return 1
    fi

    log_ok "All addons enabled successfully"
    return 0
}

# Patch the Traefik (MicroK8s ingress addon) DaemonSet with platform-level
# config that the addon doesn't expose: cross-namespace middleware refs +
# any extra TCP entrypoints declared in `TRAEFIK_EXTRA_TCP_ENTRYPOINTS`.
# Triggers a DaemonSet rollout (single-node deadlock-safe pattern) when any
# patch is applied.
#
# Why patch instead of helm upgrade: the addon owns the Helm release; manual
# `helm upgrade traefik` against the latest chart conflicts on schema diffs
# (e.g. ports.web.redirections rejected) and silently no-ops. kubectl patch
# is the supported escape hatch for addon-managed installs and idempotent.
#
# Patch 1 — cross-namespace middleware refs:
#   Default Traefik ships with cross-namespace middleware refs DISABLED. An
#   Ingress in ns X cannot reference a Middleware in ns Y unless this flag
#   is on. We have a single shared forwardAuth Middleware in the `idp` ns
#   (Authentik), referenced cluster-wide as `idp-forwardauth@kubernetescrd`.
#
# Patch 2 — extra TCP entrypoints (from TRAEFIK_EXTRA_TCP_ENTRYPOINTS array):
#   Each `name:port` entry adds `--entryPoints.<name>.address=:<port>/tcp`
#   to args + a `containerPort=<port>, hostPort=<port>` to the pod, so
#   IngressRouteTCP CRs that reference that entrypoint actually have a
#   listener to route into. Single-node hostPort exposure (no LoadBalancer
#   needed). Empty array = patch is a no-op.
#
# Idempotent: each patch is gated on a grep of the current container args.
# Re-runs only patch what's missing. Force-roll only fires if the LIVE pod
# lags the template.
configure_traefik_addon() {
    if ! microk8s kubectl -n ingress get daemonset traefik >/dev/null 2>&1; then
        log_warn "Traefik DaemonSet not found in 'ingress' namespace — skipping patches"
        return 0
    fi

    # Step 1: ensure the DaemonSet TEMPLATE contains every required arg + port.
    local ds_args
    ds_args=$(microk8s kubectl -n ingress get daemonset traefik \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)

    # 1a — cross-namespace flag
    if ! echo "${ds_args}" | grep -q "allowCrossNamespace=true"; then
        log_info "Patching Traefik DaemonSet — enabling cross-namespace middleware refs..."
        microk8s kubectl -n ingress patch daemonset traefik --type=json \
            -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--providers.kubernetescrd.allowCrossNamespace=true"}]' \
            >/dev/null || {
            log_error "Failed to patch Traefik DaemonSet (cross-ns flag)"
            return 1
        }
    fi

    # 1b — extra TCP entrypoints (loop over TRAEFIK_EXTRA_TCP_ENTRYPOINTS)
    local entry name port
    for entry in "${TRAEFIK_EXTRA_TCP_ENTRYPOINTS[@]:-}"; do
        [[ -z "${entry}" ]] && continue
        name="${entry%%:*}"
        port="${entry##*:}"
        if [[ -z "${name}" || -z "${port}" || "${name}" == "${entry}" ]]; then
            log_warn "TRAEFIK_EXTRA_TCP_ENTRYPOINTS: skipping malformed entry '${entry}' (expected name:port)"
            continue
        fi

        # Skip if entrypoint args already contain this name (idempotent re-run).
        if echo "${ds_args}" | grep -q "entryPoints\\.${name}\\.address"; then
            log_ok "Traefik entrypoint '${name}' already in DaemonSet template"
            continue
        fi

        log_info "Patching Traefik DaemonSet — adding TCP entrypoint ${name} on :${port}..."
        microk8s kubectl -n ingress patch daemonset traefik --type=json -p="[
            {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--entryPoints.${name}.address=:${port}/tcp\"},
            {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/ports/-\",\"value\":{\"name\":\"${name}\",\"containerPort\":${port},\"hostPort\":${port},\"protocol\":\"TCP\"}}
        ]" >/dev/null || {
            log_error "Failed to patch Traefik DaemonSet (entrypoint ${name})"
            return 1
        }
    done

    # Step 2: ensure the LIVE pod actually has everything the template specifies.
    #
    # The DaemonSet's default updateStrategy is RollingUpdate with maxSurge=1
    # and maxUnavailable=0 — fine on multi-node, but deadlocks on single-node:
    # the new pod is created BEFORE the old one is killed, but both pods need
    # the same host ports → new pod is stuck in Pending forever, old keeps
    # serving traffic with the OLD args.
    #
    # The fix: detect any mismatch (cross-ns flag OR any configured entrypoint
    # missing) and force-roll by deleting wedged Pending pods + the Running
    # one. DS controller recreates a single new pod which grabs the now-free
    # host ports and comes up with the new args.
    local live_args needs_roll=false
    live_args=$(microk8s kubectl -n ingress get pods -l app.kubernetes.io/name=traefik \
        -o jsonpath='{.items[?(@.status.phase=="Running")].spec.containers[0].args}' 2>/dev/null)

    if ! echo "${live_args}" | grep -q "allowCrossNamespace=true"; then
        needs_roll=true
    fi
    for entry in "${TRAEFIK_EXTRA_TCP_ENTRYPOINTS[@]:-}"; do
        [[ -z "${entry}" ]] && continue
        name="${entry%%:*}"
        [[ -z "${name}" || "${name}" == "${entry}" ]] && continue
        if ! echo "${live_args}" | grep -q "entryPoints\\.${name}\\.address"; then
            needs_roll=true
        fi
    done

    if [[ "${needs_roll}" != "true" ]]; then
        log_ok "Traefik live pod fully configured (cross-ns + ${#TRAEFIK_EXTRA_TCP_ENTRYPOINTS[@]} extra TCP entrypoint(s))"
        return 0
    fi

    log_info "Live Traefik pod lags the template — force-rolling DaemonSet..."

    # Clear any wedged Pending pods first (no grace, no host port held).
    microk8s kubectl -n ingress delete pod -l app.kubernetes.io/name=traefik \
        --field-selector=status.phase=Pending --grace-period=0 --force \
        >/dev/null 2>&1 || true

    # Then drop the running pod so the controller can replace it with one
    # rendered from the patched template.
    microk8s kubectl -n ingress delete pod -l app.kubernetes.io/name=traefik \
        --field-selector=status.phase=Running --grace-period=10 \
        >/dev/null 2>&1 || true

    log_info "Waiting for new Traefik pod with full config..."
    microk8s kubectl -n ingress rollout status daemonset/traefik --timeout=90s >/dev/null 2>&1 || {
        log_warn "Traefik rollout did not complete within 90s"
    }

    log_ok "Traefik DaemonSet patched + rolled (cross-ns + ${#TRAEFIK_EXTRA_TCP_ENTRYPOINTS[@]} extra TCP entrypoint(s))"
    return 0
}

# Disable every addon listed in DISABLED_ADDONS. Idempotent: addons that are
# already off are skipped, and a missing/empty DISABLED_ADDONS is a no-op.
#
# Use case: addons that snap-installed MicroK8s defaults `auto-enabled` (the
# built-in `registry` addon being the prime example, since we run Zot via
# GitOps instead) and that we want OFF on every fresh + every existing
# install. Adding the addon name here means a future re-run of
# `--install-microk8s` always lands the cluster in the same state, regardless
# of what the previous run / snap default did.
disable_addons() {
    # `${#ARRAY[@]}` is safe even when ARRAY is undeclared — returns 0.
    # Older code tried `${#DISABLED_ADDONS[@]:-0}` which is a syntax error:
    # the `${#…}` length form does not accept the `:-default` modifier.
    if [[ ${#DISABLED_ADDONS[@]} -eq 0 ]]; then
        return 0
    fi

    log_step "Disabling MicroK8s addons listed in DISABLED_ADDONS..."

    for addon in "${DISABLED_ADDONS[@]}"; do
        if ! is_addon_enabled "${addon}"; then
            log_ok "Addon '${addon}' already disabled, skipping"
            continue
        fi

        log_info "Disabling addon '${addon}'..."
        # `microk8s disable` returns 0 even if the addon was already off,
        # so we don't have to special-case the race-with-another-process case.
        microk8s disable "${addon}" || {
            log_warn "Failed to disable addon '${addon}' — continuing"
            continue
        }

        log_ok "Addon '${addon}' disabled"
    done

    return 0
}

# Force Calico's Felix to use a specific iptables backend so it can't disagree
# with the host. We only patch FelixConfiguration and restart calico-node —
# we don't touch iptables rules directly. The earlier version of this function
# flushed the "other" backend's tables, which on a working host wiped the CNI
# portmap DNAT rules and silently broke hostPort plumbing for the ingress
# controller. Felix will handle stale-rule cleanup on its own during repaint.
# References: canonical/microk8s#2180, canonical/microk8s#4686.
align_calico_backend() {
    if ! microk8s kubectl get felixconfiguration default &>/dev/null; then
        log_info "FelixConfiguration not present (yet) — skipping Calico backend alignment"
        return 0
    fi

    local host_backend felix_target
    host_backend=$(detect_host_iptables_backend)
    case "${host_backend}" in
        nft)    felix_target="NFT" ;;
        legacy) felix_target="Legacy" ;;
        *)      log_warn "Could not detect host iptables backend — skipping"; return 0 ;;
    esac

    local current
    current=$(microk8s kubectl get felixconfiguration default \
        -o jsonpath='{.spec.iptablesBackend}' 2>/dev/null)
    # "Auto" or empty means Felix will pick the right backend itself.
    if [[ "${current}" == "${felix_target}" || "${current}" == "Auto" || -z "${current}" ]]; then
        log_ok "Calico Felix backend OK (${current:-Auto}, host=${host_backend})"
        return 0
    fi

    log_step "Aligning Calico Felix backend: ${current} → ${felix_target} (host=${host_backend})"
    microk8s kubectl patch felixconfiguration default --type=merge \
        -p "{\"spec\":{\"iptablesBackend\":\"${felix_target}\"}}" >/dev/null || {
        log_error "Failed to patch FelixConfiguration"
        return 1
    }

    microk8s kubectl -n kube-system rollout restart daemonset/calico-node >/dev/null 2>&1 || true
    microk8s kubectl -n kube-system rollout status daemonset/calico-node --timeout=120s >/dev/null 2>&1 || {
        log_warn "calico-node rollout did not complete within 120s — investigate manually"
    }
    log_ok "Calico Felix now on ${felix_target}"
}
