#!/usr/bin/env bash
# start-tunnel-dev.sh
# Open an SSH tunnel from this laptop to the dev MicroK8s cluster and
# merge the cluster's kubeconfig into ~/.kube/config under context `dev`.
#
# After this script is running:
#   kubectl config use-context dev
#   kubectl get nodes
#
# Press Ctrl+C to close the tunnel + leave the kubeconfig in place.
# Only the SSH process is cleaned up; ~/.kube/config stays so you can
# re-tunnel later without re-fetching.

set -euo pipefail

# --- Dev cluster ---
DEV_HOST="server.dev.digitaplatform.com"
DEV_USER="server"
DEV_K8S_LOCAL_PORT=16443
DEV_K8S_REMOTE_PORT=16443

# --- Kubeconfig ---
KUBE_DIR="${HOME}/.kube"
KUBECONFIG_PATH="${KUBE_DIR}/config"
KUBECONFIG_DEV="${KUBE_DIR}/config-dev"

# Temp files (cleaned on exit)
TMP_DEV_CONFIG=""

# SSH background PID
DEV_SSH_PID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cleanup() {
    echo ""
    echo "Shutting down tunnel..."
    if [[ -n "$DEV_SSH_PID" ]] && kill -0 "$DEV_SSH_PID" 2>/dev/null; then
        kill "$DEV_SSH_PID" 2>/dev/null || true
        echo -e "   ${GREEN}Dev tunnel (PID ${DEV_SSH_PID}) stopped${NC}"
    fi
    if [[ -n "$TMP_DEV_CONFIG" && -f "$TMP_DEV_CONFIG" ]]; then
        rm -f "$TMP_DEV_CONFIG"
    fi
    echo "Tunnel closed."
    exit 0
}
trap cleanup INT TERM

clear_port() {
    local port=$1
    local port_name=$2
    echo "   Checking port ${port} (${port_name})..."
    local pid
    pid=$(lsof -ti :"${port}" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        local process_name
        process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        echo -e "   Found existing process: ${YELLOW}${process_name} (PID ${pid})${NC}"
        echo -e "   ${RED}Killing process...${NC}"
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
        echo -e "   ${GREEN}Port ${port} is now free${NC}"
    else
        echo -e "   ${GREEN}Port ${port} is available${NC}"
    fi
}

# Replace server URL with localhost tunnel target, drop CA data + add
# insecure-skip-tls-verify (cert isn't valid for `localhost`), rename
# context/cluster/user to `dev`. Same sed pattern as the proven original.
process_kubeconfig() {
    local raw_config="$1"
    local local_port="$2"
    local remote_port="$3"
    local context_name="$4"
    # tr -d '\r' is a safety: Linux ssh delivers LF (no-op), but ensures
    # the `$` end-anchors still match if someone ever runs this on a host
    # where the remote shell adds CR.
    echo "$raw_config" | tr -d '\r' | sed \
        -e "s|^\(\s*\)server:\s*https://[^:]*:${remote_port}|\1server: https://localhost:${local_port}\n\1insecure-skip-tls-verify: true|" \
        -e '/^\s*certificate-authority-data:/d' \
        -e "s|name: microk8s-cluster|name: ${context_name}|g" \
        -e "s|cluster: microk8s-cluster|cluster: ${context_name}|g" \
        -e "s|name: microk8s$|name: ${context_name}|" \
        -e "s|name: admin|name: ${context_name}-admin|g" \
        -e "s|user: admin|user: ${context_name}-admin|g" \
        -e "s|current-context:.*|current-context: ${context_name}|"
}

# Step 1: free the local port
echo ""
echo "Checking and clearing required port..."
clear_port $DEV_K8S_LOCAL_PORT "Kubernetes API (dev)"

# Step 2: SSH reachability
echo ""
echo "Testing SSH connectivity to DEV cluster..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "${DEV_USER}@${DEV_HOST}" "echo Connected" 2>&1; then
    echo -e "${RED}SSH connection to DEV failed.${NC}"
    echo -e "${YELLOW}Try:${NC}"
    echo "   ssh-add -l                              # keys loaded?"
    echo "   ssh ${DEV_USER}@${DEV_HOST}             # interactive test"
    echo "   ssh-keyscan ${DEV_HOST} >> ~/.ssh/known_hosts   # add to known_hosts"
    exit 1
fi
echo -e "${GREEN}DEV SSH connection successful${NC}"

# Step 3: ensure ~/.kube exists
if [[ ! -d "$KUBE_DIR" ]]; then
    echo ""
    echo "Creating .kube directory at ${KUBE_DIR}..."
    mkdir -p "$KUBE_DIR"
fi

# Step 4: fetch kubeconfig from DEV MicroK8s
echo ""
echo "Fetching kubeconfig from DEV MicroK8s..."
RAW_DEV_CONFIG=$(ssh "${DEV_USER}@${DEV_HOST}" microk8s config 2>&1)
if [[ -z "$RAW_DEV_CONFIG" ]]; then
    echo -e "${RED}Failed to retrieve DEV kubeconfig.${NC}"
    exit 1
fi
echo -e "   ${GREEN}DEV kubeconfig retrieved${NC}"

# Step 5: rewrite for localhost tunnel
echo ""
echo "Processing DEV kubeconfig..."
PROCESSED_DEV=$(process_kubeconfig "$RAW_DEV_CONFIG" "$DEV_K8S_LOCAL_PORT" "$DEV_K8S_REMOTE_PORT" "dev")
echo -e "   ${GREEN}Server -> https://localhost:${DEV_K8S_LOCAL_PORT}, context -> dev${NC}"

# Step 6: merge into ~/.kube/config and write the per-context file
echo ""
echo "Merging kubeconfig..."
TMP_DEV_CONFIG=$(mktemp)
echo "$PROCESSED_DEV" > "$TMP_DEV_CONFIG"

if [[ -f "$KUBECONFIG_PATH" ]]; then
    # Merge with existing (preserves other contexts). Write to a sibling
    # file first so a kubectl error doesn't truncate the real config.
    if ! KUBECONFIG="${KUBECONFIG_PATH}:${TMP_DEV_CONFIG}" kubectl config view --flatten > "${KUBECONFIG_PATH}.new" 2>&1; then
        echo -e "${RED}kubectl config view --flatten failed:${NC}"
        cat "${KUBECONFIG_PATH}.new" || true
        rm -f "${KUBECONFIG_PATH}.new"
        echo -e "${YELLOW}Existing ${KUBECONFIG_PATH} may be corrupt — delete it and re-run.${NC}"
        exit 1
    fi
    if [[ ! -s "${KUBECONFIG_PATH}.new" ]]; then
        echo -e "${RED}Merged config is empty — aborting.${NC}"
        rm -f "${KUBECONFIG_PATH}.new"
        exit 1
    fi
    mv "${KUBECONFIG_PATH}.new" "$KUBECONFIG_PATH"
else
    cp "$TMP_DEV_CONFIG" "$KUBECONFIG_PATH"
fi
echo -e "${GREEN}Merged kubeconfig saved to ${KUBECONFIG_PATH}${NC}"

# Per-context standalone file (use with `KUBECONFIG=...` in another shell).
cp "$KUBECONFIG_PATH" "$KUBECONFIG_DEV"
KUBECONFIG="$KUBECONFIG_DEV" kubectl config use-context dev >/dev/null 2>&1 || true
echo -e "   ${GREEN}${KUBECONFIG_DEV} (current-context: dev)${NC}"

# Step 7: start tunnel
echo ""
echo "Starting DEV SSH tunnel..."
ssh -N -L "${DEV_K8S_LOCAL_PORT}:localhost:${DEV_K8S_REMOTE_PORT}" "${DEV_USER}@${DEV_HOST}" &
DEV_SSH_PID=$!
echo -e "   ${CYAN}Kubernetes API:  localhost:${DEV_K8S_LOCAL_PORT} -> ${DEV_HOST}:${DEV_K8S_REMOTE_PORT}${NC}"
echo -e "   ${GREEN}Dev tunnel started (PID ${DEV_SSH_PID})${NC}"

echo ""
echo "============================================================"
echo -e "${GREEN}DEV tunnel running.${NC}"
echo "============================================================"
echo ""
echo -e "${YELLOW}Use kubectl:${NC}"
echo "   kubectl config use-context dev"
echo "   kubectl get nodes"
echo ""
echo -e "${YELLOW}Or in a separate shell:${NC}"
echo "   export KUBECONFIG=\"${KUBECONFIG_DEV}\""
echo "   kubectl get nodes"
echo ""
echo "Press Ctrl+C to close the tunnel."
echo ""

wait
