#!/bin/bash
# reset-cluster.sh
# Aggressively wipes a MicroK8s cluster and all script-generated state.
#
# GUARANTEES (audit the deletes below before running if you're nervous):
#   - The /mnt/data mount and the disk underneath are NEVER unmounted or wiped.
#     Only the per-env PV subdirectories on /mnt/data are removed.
#   - NO file inside this repo folder is touched. The script reads
#     configs/config.<env> (read-only) to know the STORAGE_DIRECTORY, that's
#     it. Manifests, scripts, configs, .git/ — all stay intact.
#   - User CLI tools in /usr/local/bin (argocd, vault, yq, jq, tailscale)
#     and the dev user's account are left alone.
#
# Use when:
#   - Switching MicroK8s channels (e.g. 1.32 -> 1.35) and need a clean base
#   - A previous install left the cluster half-broken
#   - `snap remove microk8s --purge` hung or refused
#   - You just want a confident fresh start
#
# Usage: sudo ./reset-cluster.sh [--dev|--test|--prod|--config PATH] [--yes]

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# ---- argument parsing -----------------------------------------------------
SKIP_CONFIRM="false"
CONFIG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
SECRETS_DIR="${SCRIPT_DIR}/secrets"

usage() {
    cat <<HELP
USAGE: sudo ./reset-cluster.sh (--dev|--test|--prod|--config PATH) [--yes]

Wipes a MicroK8s cluster and all script-generated state. Preserves the
data mount (whatever \$STORAGE_PATH points to in your config) and the disk
underneath, the user account, and CLI tools installed in /usr/local/bin.

You MUST pass an env flag — the reset uses your config to find:
  - STORAGE_PATH       (the mount to keep — e.g. /mnt/data, /data, ...)
  - STORAGE_DIRECTORY  (the PV subdirectory on that mount — only this gets wiped)
Hard-coding those values would be wrong: not every host mounts data at /mnt/data.

OPTIONS:
    --dev | --test | --prod   Load configs/config.<env>
    --config PATH             Use a custom config file
    --yes, -y                 Skip the confirmation prompt
    --help, -h                Show this help
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) SKIP_CONFIRM="true"; shift ;;
        --dev)    CONFIG_FILE="${CONFIGS_DIR}/config.dev"; shift ;;
        --test)   CONFIG_FILE="${CONFIGS_DIR}/config.test"; shift ;;
        --prod)   CONFIG_FILE="${CONFIGS_DIR}/config.prod"; shift ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

if [[ -z "${CONFIG_FILE}" ]]; then
    log_error "An env flag is required so the reset can read STORAGE_PATH / STORAGE_DIRECTORY."
    log_error "  sudo ./reset-cluster.sh --test"
    log_error "  sudo ./reset-cluster.sh --prod"
    log_error "  sudo ./reset-cluster.sh --config /path/to/config"
    exit 1
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Config file not found: ${CONFIG_FILE}"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run with sudo"
    exit 1
fi

log_info "Reading storage config from ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

SETUP_USER="${SUDO_USER:-${MICROK8S_USER:-$(whoami)}}"
SETUP_HOME="/home/${SETUP_USER}"

# STORAGE_PATH = the mount we must NOT wipe (the disk).
# STORAGE_DIRECTORY = the PV subdir on that mount that we DO wipe.
# Both can be empty (single-disk-VM mode where MicroK8s uses its default
# hostpath under /var/snap/microk8s/...) — in which case there's no
# external storage to preserve or clean and snap --purge handles it all.
DATA_MOUNT="${STORAGE_PATH:-}"
STORAGE_DIRS=()
[[ -n "${STORAGE_DIRECTORY:-}" ]] && STORAGE_DIRS+=("${STORAGE_DIRECTORY}")

# ---- pre-flight: show what will happen, confirm ---------------------------
log_step "=== MicroK8s Cluster Reset ==="
echo
log_warn "This will WIPE:"
log_warn "  - MicroK8s snap (any channel) + /var/snap/microk8s/"
log_warn "  - Any lingering kubelite/kube-proxy/containerd/calico processes"
log_warn "  - Stale iptables (legacy + nft) chains: KUBE-*, cali-*, CNI-*"
log_warn "  - Native nft tables created by kube-proxy nftables proxier"
log_warn "  - CNI configs (/etc/cni/net.d/) and Calico interfaces"
if [[ ${#STORAGE_DIRS[@]} -gt 0 ]]; then
    log_warn "  - PV data directories on ${DATA_MOUNT}:"
    for d in "${STORAGE_DIRS[@]}"; do log_warn "      ${d}"; done
fi
log_warn "  - legacy ${SETUP_HOME}/secrets/, ${SETUP_HOME}/secrets-user/ (old location)"
log_warn "    NOTE: ${SECRETS_DIR}/ (consolidated secrets) is PRESERVED on reset"
log_warn "  - ${SETUP_HOME}/.kube/"
log_warn "  - /var/lib/kubernetes-setup/, /var/log/kubernetes-setup/"
log_warn "  - ${SETUP_HOME}/.cache/helm, ${SETUP_HOME}/.config/helm"
log_warn "  - kubectl/helm aliases in ${SETUP_HOME}/.bashrc (.zshrc)"
echo
log_info "PRESERVED:"
if [[ -n "${DATA_MOUNT}" ]]; then
    log_info "  - ${DATA_MOUNT} mount and the disk underneath"
fi
log_info "  - User account ${SETUP_USER} and unrelated home files"
log_info "  - CLI tools in /usr/local/bin (argocd, vault, yq, jq, tailscale)"
log_info "  - System packages (curl, unzip, jq, tailscaled service)"
log_info "  - Everything in this repo: configs, manifests, scripts, .git/"
echo

if [[ -n "${DATA_MOUNT}" ]] && ! findmnt "${DATA_MOUNT}" &>/dev/null; then
    log_warn "${DATA_MOUNT} is NOT currently mounted — storage cleanup will be skipped."
fi

if [[ "${SKIP_CONFIRM}" != "true" ]]; then
    read -p "Proceed with reset? (type 'yes' to confirm): " -r
    [[ "${REPLY}" != "yes" ]] && { log_warn "Reset cancelled."; exit 0; }
fi

# ---- helpers --------------------------------------------------------------
# Remove all cali-*, KUBE-*, CNI-* chains from the given iptables binary.
#
# Iterates up to 8 passes. Each pass:
#   A) deletes rules in the standard chains (INPUT/FORWARD/OUTPUT/PRE-
#      ROUTING/POSTROUTING) that target cali-/KUBE-/CNI- chains. We delete
#      by line number rather than by rule body — `iptables -S` quotes
#      comments with embedded special chars (e.g. `--comment "cali:abc"`),
#      and feeding that back via bash word-splitting passes the literal
#      quotes to iptables, which can't match the actual rule.
#   B) flushes + deletes prefixed chains themselves.
#
# Multiple passes catch chains that referenced each other and couldn't
# be deleted until their parent chain was flushed.
remove_iptables_chains() {
    local cmd="$1"
    command -v "${cmd}" &>/dev/null || return 0
    local table chain line pass after total_after std_chains

    for pass in 1 2 3 4 5 6 7 8; do
        total_after=0
        for table in filter nat mangle raw; do
            # Standard chains differ per table.
            case "${table}" in
                filter) std_chains="INPUT FORWARD OUTPUT" ;;
                nat)    std_chains="PREROUTING INPUT OUTPUT POSTROUTING" ;;
                mangle) std_chains="PREROUTING INPUT FORWARD OUTPUT POSTROUTING" ;;
                raw)    std_chains="PREROUTING OUTPUT" ;;
                *)      continue ;;
            esac

            # Step A: delete rules in standard chains that target our prefixes
            for chain in ${std_chains}; do
                while : ; do
                    line=$("${cmd}" -t "${table}" -nL "${chain}" --line-numbers 2>/dev/null \
                           | awk '$0 ~ /(cali-|KUBE-|CNI-)/ && NR>2 {print $1; exit}')
                    [[ -z "${line}" ]] && break
                    "${cmd}" -t "${table}" -D "${chain}" "${line}" 2>/dev/null || break
                done
            done

            # Step B: flush + delete prefixed chains
            for chain in $("${cmd}" -t "${table}" -S 2>/dev/null \
                           | grep -E '^-N (cali-|KUBE-|CNI-)' \
                           | cut -d' ' -f2); do
                "${cmd}" -t "${table}" -F "${chain}" 2>/dev/null || true
                "${cmd}" -t "${table}" -X "${chain}" 2>/dev/null || true
            done

            after=$("${cmd}" -t "${table}" -S 2>/dev/null \
                    | grep -cE '^-N (cali-|KUBE-|CNI-)' || true)
            total_after=$((total_after + after))
        done
        [[ ${total_after} -eq 0 ]] && return 0
    done

    return 0
}

# ---- step 1: stop microk8s systemd services -------------------------------
log_step "Stopping MicroK8s services..."
mapfile -t mk8s_units < <(systemctl list-units --type=service --all --no-legend --plain \
                          'snap.microk8s.*' 2>/dev/null | awk '{print $1}')
if [[ ${#mk8s_units[@]} -gt 0 ]]; then
    for u in "${mk8s_units[@]}"; do
        systemctl stop "${u}" 2>/dev/null || true
    done
    sleep 2
    log_ok "Stopped ${#mk8s_units[@]} MicroK8s service(s)"
else
    log_info "No MicroK8s systemd services running"
fi

# ---- step 2: remove the snap (with escalation if needed) ------------------
log_step "Removing MicroK8s snap..."
if snap list microk8s &>/dev/null; then
    if ! timeout 90 snap remove microk8s --purge 2>&1 | sed 's/^/  /'; then
        log_warn "snap remove timed out — killing snap processes and retrying"
        pkill -9 -f '/snap/microk8s/' 2>/dev/null || true
        sleep 3
        if ! timeout 60 snap remove microk8s --purge --terminate 2>&1 | sed 's/^/  /'; then
            log_error "snap remove still failing; you may need to: "
            log_error "  sudo systemctl stop snap.microk8s.*"
            log_error "  sudo umount -l /var/snap/microk8s/common/var/lib/kubelet/* 2>/dev/null"
            log_error "  sudo snap remove microk8s --purge --terminate"
        fi
    fi
    log_ok "MicroK8s snap removal attempted"
else
    log_info "MicroK8s snap not installed"
fi

# ---- step 3: kill any residual processes ----------------------------------
log_step "Killing leftover container/kubelet processes..."
killed=0
for pat in kubelite kube-proxy kube-apiserver kube-controller-manager \
           kube-scheduler kubelet containerd calico-node felix \
           etcd dqlite-driver; do
    if pgrep -f "${pat}" &>/dev/null; then
        pkill -9 -f "${pat}" 2>/dev/null && killed=$((killed + 1)) || true
    fi
done
[[ ${killed} -gt 0 ]] && log_info "killed ${killed} process group(s)" || log_info "no leftover processes"

# ---- step 4: scrub residual snap dirs -------------------------------------
log_step "Removing residual snap state..."
for d in /var/snap/microk8s; do
    [[ -e "$d" ]] && rm -rf "$d" && log_info "removed $d"
done

# ---- step 5: iptables cleanup (legacy + nft) ------------------------------
log_step "Cleaning iptables chains (cali-, KUBE-, CNI-)..."
for bin in iptables-nft iptables-legacy; do
    if command -v "${bin}" &>/dev/null; then
        remove_iptables_chains "${bin}"
        log_info "cleaned ${bin}"
    fi
done

# ---- step 6: clean native nft tables (kube-proxy nftables proxier) --------
log_step "Cleaning native nft tables..."
if command -v nft &>/dev/null; then
    for fam in inet ip ip6; do
        for tbl in kube-proxy kube-router calico; do
            if nft list table "${fam}" "${tbl}" &>/dev/null; then
                nft delete table "${fam}" "${tbl}" 2>/dev/null \
                  && log_info "removed ${fam}/${tbl} table"
            fi
        done
    done
fi

# ---- step 7: CNI artifacts + Calico interfaces + routes -------------------
log_step "Cleaning CNI configs and Calico network interfaces..."
[[ -d /etc/cni/net.d ]] && rm -rf /etc/cni/net.d/* 2>/dev/null && log_info "wiped /etc/cni/net.d/"
[[ -d /opt/cni/bin ]]   && rm -rf /opt/cni/bin/*   2>/dev/null && log_info "wiped /opt/cni/bin/"

while IFS= read -r iface; do
    [[ -z "${iface}" ]] && continue
    ip link delete "${iface}" 2>/dev/null && log_info "removed interface ${iface}"
done < <(ip -br link show | awk '/^(vxlan\.calico|cali[a-f0-9]+|tunl0@)/ {print $1}' | cut -d'@' -f1)

while IFS= read -r route; do
    [[ -z "${route}" ]] && continue
    ip route del blackhole "${route}" 2>/dev/null && log_info "removed blackhole route ${route}"
done < <(ip route | awk '/^blackhole/ {print $2}')

# ---- step 8: wipe PV data on the data mount -------------------------------
log_step "Wiping PV data on ${DATA_MOUNT:-(no external mount configured)}..."
if [[ -z "${DATA_MOUNT}" ]]; then
    log_info "No STORAGE_PATH configured in the config — nothing to wipe here"
    log_info "(MicroK8s default hostpath was under /var/snap/microk8s/, already removed)"
elif ! findmnt "${DATA_MOUNT}" &>/dev/null; then
    log_warn "${DATA_MOUNT} not mounted — skipping storage cleanup"
    log_warn "If the disk is currently elsewhere, mount it at ${DATA_MOUNT} and re-run."
else
    for d in "${STORAGE_DIRS[@]}"; do
        if [[ -d "$d" ]]; then
            rm -rf "$d"
            log_info "removed $d"
        fi
    done
fi

# ---- step 9: user state ---------------------------------------------------
# NOTE: only the LEGACY ~/secrets is cleaned here. The consolidated secrets
# directory (${SECRETS_DIR}, inside the repo) is DELIBERATELY preserved across a
# reset — it holds the hand-authored seed inputs (secrets.<env>) and the
# control-plane credentials, all of which the user wants to keep + restore.
log_step "Cleaning user state in ${SETUP_HOME}..."
for d in "${SETUP_HOME}/secrets" "${SETUP_HOME}/secrets-user" "${SETUP_HOME}/.kube" \
         "${SETUP_HOME}/.cache/helm" "${SETUP_HOME}/.config/helm"; do
    [[ -e "${d}" ]] && rm -rf "${d}" && log_info "removed ${d}"
done

# Strip kubectl/helm aliases from shell rc files (idempotent).
for rc in "${SETUP_HOME}/.bashrc" "${SETUP_HOME}/.zshrc"; do
    if [[ -f "${rc}" ]]; then
        sed -i \
            -e '/# Added by kubernetes-setup.sh/d' \
            -e "/alias kubectl='microk8s.kubectl'/d" \
            -e "/alias helm='microk8s.helm3'/d" \
            "${rc}"
        log_info "cleaned aliases from $(basename "${rc}")"
    fi
done

# ---- step 10: system state ------------------------------------------------
log_step "Cleaning system state..."
for d in /var/lib/kubernetes-setup /var/log/kubernetes-setup; do
    [[ -e "${d}" ]] && rm -rf "${d}" && log_info "removed ${d}"
done

# ---- step 11: final verification ------------------------------------------
echo
log_step "=== RESET COMPLETE ==="
echo
if [[ -n "${DATA_MOUNT}" ]]; then
    log_info "${DATA_MOUNT} status:"
    findmnt "${DATA_MOUNT}" || log_warn "  ${DATA_MOUNT} NOT mounted!"
    echo
    log_info "Disk usage:"
    df -h "${DATA_MOUNT}" 2>/dev/null | sed 's/^/  /' || log_warn "  could not read df"
else
    log_info "No external storage mount configured."
fi
echo
if command -v microk8s &>/dev/null; then
    log_warn "microk8s binary STILL present at $(command -v microk8s) — removal incomplete"
else
    log_ok "microk8s binary fully removed"
fi
if [[ -d /var/snap/microk8s ]]; then
    log_warn "/var/snap/microk8s/ still present — removal incomplete"
else
    log_ok "/var/snap/microk8s/ fully removed"
fi
# Stale iptables chains (should be zero across both backends)
for bin in iptables-nft iptables-legacy; do
    if command -v "${bin}" &>/dev/null; then
        for tbl in filter nat; do
            n=$("${bin}" -t "${tbl}" -L -n 2>/dev/null | grep -cE '^Chain (cali-|KUBE-|CNI-)' || true)
            if [[ "${n}" -gt 0 ]]; then
                log_warn "${bin} -t ${tbl}: ${n} stale chain(s) remain — run reset again or investigate"
            fi
        done
    fi
done
echo
log_info "Next step:"
log_info "  cd ${SCRIPT_DIR}"
log_info "  git pull"
log_info "  sudo ./setup-kubernetes.sh --<env>"
