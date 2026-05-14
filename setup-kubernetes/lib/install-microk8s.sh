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

    if [[ ${#failed_addons[@]} -gt 0 ]]; then
        log_error "Failed to enable addons: ${failed_addons[*]}"
        return 1
    fi

    log_ok "All addons enabled successfully"
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
    if [[ ${#DISABLED_ADDONS[@]:-0} -eq 0 ]]; then
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
