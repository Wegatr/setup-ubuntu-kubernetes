#!/bin/bash
# manage-secrets.sh
# Encrypt/backup and decrypt/restore secret files listed in manage-secrets.config
# Usage: ./manage-secrets.sh --backup | --restore | --remove | --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCRYPTED_FILE="${SCRIPT_DIR}/secrets.enc"

# Load config
CONFIG_FILE="${SCRIPT_DIR}/manage-secrets.config"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi
source "${CONFIG_FILE}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

show_usage() {
    cat <<EOF
USAGE: ./manage-secrets.sh [--backup | --restore | --remove | --list | --help]

Encrypt and backup or decrypt and restore secret files.
Files are defined in manage-secrets.config.

OPTIONS:
    --backup     Encrypt matching files into secrets.enc, commit and push
    --restore    Decrypt secrets.enc and restore files
    --remove     Remove matching secret files (with confirmation)
    --list       List files that would be backed up
    --help, -h   Show this help message
EOF
}

# Expand the SECRET_FILES globs (relative to SCRIPT_DIR) into existing files,
# skipping the tracked *.example template. Paths are emitted RELATIVE to
# SCRIPT_DIR so the tar archive restores into the current repo on any host.
# Runs in the process-substitution subshell of its callers, so the `cd` does
# not leak into the main script's working directory.
resolve_secret_files() {
    local files=() pattern expanded f
    cd "${SCRIPT_DIR}" || return 1
    for pattern in "${SECRET_FILES[@]}"; do
        # shellcheck disable=SC2206
        expanded=( ${pattern} )
        for f in "${expanded[@]}"; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.example ]] && continue
            files+=("$f")
        done
    done
    # Emit ONLY when non-empty: `printf '%s\n' "${empty[@]}"` would still print a
    # single newline, which mapfile turns into a 1-element array holding "" — that
    # silently defeats the callers' `${#files[@]} -eq 0` guard and would make
    # do_backup run `tar ""` and clobber secrets.enc with garbage.
    if (( ${#files[@]} )); then
        printf '%s\n' "${files[@]}"
    fi
}

do_backup() {
    local files
    mapfile -t files < <(resolve_secret_files)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "No secret files found matching patterns in config"
        exit 1
    fi

    log_info "Files to backup:"
    for f in "${files[@]}"; do
        log_info "  ${f}"
    done

    # Prompt for encryption password (with confirmation)
    local password password_confirm
    read -rsp "Enter encryption password: " password
    echo
    if [[ -z "${password}" ]]; then
        log_error "Password must not be empty"
        exit 1
    fi
    read -rsp "Confirm encryption password: " password_confirm
    echo
    if [[ "${password}" != "${password_confirm}" ]]; then
        log_error "Passwords do not match"
        exit 1
    fi

    log_info "Encrypting ${#files[@]} file(s) ..."
    # -C SCRIPT_DIR + relative paths → portable archive (no host-absolute paths).
    tar -C "${SCRIPT_DIR}" -cz "${files[@]}" | \
        gpg --symmetric --cipher-algo AES256 --batch --passphrase-fd 3 \
        3< <(printf '%s' "${password}") > "${ENCRYPTED_FILE}"

    log_ok "Encrypted backup written to ${ENCRYPTED_FILE}"

    # Git add, commit, push. secrets.enc is intentionally NOT gitignored (see
    # .gitignore) — the encrypted blob is the off-site recovery copy.
    log_info "Committing encrypted backup ..."
    git -C "${SCRIPT_DIR}" add "${ENCRYPTED_FILE}"
    git -C "${SCRIPT_DIR}" \
        -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' \
        commit -m "secrets: update encrypted backup (manage-secrets.sh --backup)"
    git -C "${SCRIPT_DIR}" push

    log_ok "Backup complete and pushed to origin"
}

do_restore() {
    if [[ ! -f "${ENCRYPTED_FILE}" ]]; then
        log_error "Encrypted file not found: ${ENCRYPTED_FILE}"
        exit 1
    fi

    # Prompt for decryption password
    local password
    read -rsp "Enter decryption password: " password
    echo
    if [[ -z "${password}" ]]; then
        log_error "Password must not be empty"
        exit 1
    fi

    log_info "Decrypting ${ENCRYPTED_FILE} ..."
    # Archive holds SCRIPT_DIR-relative paths (secrets/...); restore them under
    # this repo's setup-kubernetes/ regardless of its absolute location.
    gpg --decrypt --batch --passphrase-fd 3 \
        3< <(printf '%s' "${password}") "${ENCRYPTED_FILE}" | \
        tar -C "${SCRIPT_DIR}" -xz

    log_ok "Secrets restored into ${SCRIPT_DIR}/secrets/"
}

do_remove() {
    local files
    mapfile -t files < <(resolve_secret_files)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "No secret files found matching patterns in config"
        exit 0
    fi

    log_info "Files to remove:"
    for f in "${files[@]}"; do
        log_info "  ${f}"
    done

    read -rp "Remove these ${#files[@]} file(s)? (y/N): " confirm
    if [[ "${confirm}" != [yY] ]]; then
        log_info "Cancelled"
        exit 0
    fi

    # files[] are SCRIPT_DIR-relative (resolve_secret_files cd's into SCRIPT_DIR
    # only inside its subshell), so anchor the rm to SCRIPT_DIR — otherwise a
    # remove run from another cwd would silently delete nothing.
    for f in "${files[@]}"; do
        rm -f "${SCRIPT_DIR}/$f"
    done
    log_ok "Removed ${#files[@]} file(s)"
}

do_list() {
    local files
    mapfile -t files < <(resolve_secret_files)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "No secret files found matching patterns in config"
        exit 0
    fi

    log_info "Secret files (${#files[@]}):"
    for f in "${files[@]}"; do
        echo "  ${f}"
    done
}

# Main
case "${1:-}" in
    --backup)
        do_backup
        ;;
    --restore)
        do_restore
        ;;
    --remove)
        do_remove
        ;;
    --list)
        do_list
        ;;
    --help|-h)
        show_usage
        ;;
    "")
        log_error "No option specified"
        show_usage
        exit 1
        ;;
    *)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac
