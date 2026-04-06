# Setup Ubuntu Kubernetes

Automated, idempotent setup of a **MicroK8s** Kubernetes cluster on Ubuntu with
optional infrastructure applications (Dashboard, ArgoCD, Vault).

## Quick start

```bash
# 1. Copy the example config and edit it
cp config.example config.dev
vim config.dev          # set CLUSTER_NAME, DOMAIN_SUFFIX, LETSENCRYPT_EMAIL, ...

# 2. Install MicroK8s + addons + CLI tools
sudo ./setup-kubernetes.sh --dev

# 3. Deploy infrastructure apps
sudo ./setup-kubernetes.sh --dev --deploy-all

# 4. Check everything is running
sudo ./setup-kubernetes.sh --dev --status
```

## Repository structure

```
config.example           Documented config template (checked in)
config.dev / .test / .prod   Environment configs (gitignored)
setup-kubernetes.sh      Main script — install, deploy, maintain
common-kubernetes.sh     Shared function library
manage-secrets.sh        Backup/restore credentials (GPG encrypted)
manage-secrets.config    Lists which secret files to backup
manifests/
  kube/                  Headlamp (Dashboard) Helm values + ingress
  argocd/                ArgoCD Helm values
  vault/                 Vault Helm values, ingress, cert, ingressroute
```

## Configuration

All settings live in a single config file per environment (`config.<env>`).
Copy `config.example` to get started — every variable is documented with
comments explaining what it does and when to change it.

The script loads the right config automatically based on the environment flag:

| Flag | Config file loaded |
|---|---|
| `--dev` | `config.dev` |
| `--test` | `config.test` |
| `--prod` (default) | `config.prod` |
| `--config PATH` | Custom path |

### Required settings

| Variable | Description | Example |
|---|---|---|
| `CLUSTER_NAME` | Human name for the cluster | `simetrix-dev` |
| `DOMAIN_SUFFIX` | Base DNS domain | `simetrix.ch` |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt | `user@example.com` |
| `DEPLOY_ENV` | Environment name | `dev`, `test`, `prod` |

### Storage configuration

Two modes are supported:

**Default (single-disk VM)** — leave `STORAGE_PATH`, `STORAGE_DEVICE`, and
`STORAGE_DIRECTORY` empty. PersistentVolume data is stored under the default
MicroK8s hostpath directory (`/var/snap/microk8s/common/default-storage`). No
symlink is created.

**External disk** — set all three variables to redirect PV data to a dedicated
mount. The script will:

1. Verify `STORAGE_DEVICE` is mounted at `STORAGE_PATH`
2. Create `STORAGE_DIRECTORY` on the mount
3. Symlink the MicroK8s default storage path to `STORAGE_DIRECTORY`

```bash
# Example: external disk at /mnt/data
STORAGE_PATH="/mnt/data"
STORAGE_DEVICE="/dev/sdb1"
STORAGE_DIRECTORY="/mnt/data/kubernetes-storage"
```

This is useful when you want PV data on a larger or faster disk, or on a disk
that is backed up separately.

### Infrastructure apps

Three apps can be deployed on top of MicroK8s. Each is optional and controlled
by an `ENABLE_*` flag in the config:

| App | Config flag | Hostname | Description |
|---|---|---|---|
| Kube Dashboard | `ENABLE_KUBE` | `kube.<env>.<domain>` | Headlamp cluster UI |
| ArgoCD | `ENABLE_ARGOCD` | `argo.<env>.<domain>` | GitOps controller |
| Vault | `ENABLE_VAULT` | `vault.<env>.<domain>` | Secrets management |

Set `ENABLE_*="false"` to skip an app entirely. Deploy, upgrade, and uninstall
commands for a disabled app are silently skipped.

## Usage

### Phase 1 — Cluster installation

```bash
# Full install (MicroK8s + addons + storage + cert-manager + CLI tools + aliases)
sudo ./setup-kubernetes.sh --dev

# Install only specific components
sudo ./setup-kubernetes.sh --dev --install-microk8s
sudo ./setup-kubernetes.sh --dev --configure-storage
sudo ./setup-kubernetes.sh --dev --configure-cert-manager
sudo ./setup-kubernetes.sh --dev --install-cli-tools
sudo ./setup-kubernetes.sh --dev --setup-aliases

# Skip specific components
sudo ./setup-kubernetes.sh --dev --skip-storage --skip-aliases
```

### Phase 2 — Infrastructure deployment

```bash
# Deploy all enabled apps
sudo ./setup-kubernetes.sh --dev --deploy-all

# Deploy individually
sudo ./setup-kubernetes.sh --dev --deploy-kube
sudo ./setup-kubernetes.sh --dev --deploy-argocd
sudo ./setup-kubernetes.sh --dev --deploy-vault

# Upgrade to latest chart version
sudo ./setup-kubernetes.sh --dev --upgrade-kube
sudo ./setup-kubernetes.sh --dev --upgrade-argocd
sudo ./setup-kubernetes.sh --dev --upgrade-vault

# Uninstall (Helm uninstall + cleanup resources)
sudo ./setup-kubernetes.sh --dev --uninstall-kube
sudo ./setup-kubernetes.sh --dev --uninstall-argocd
sudo ./setup-kubernetes.sh --dev --uninstall-vault
```

### Maintenance

```bash
# Show pods, ingresses, certificates for all apps
sudo ./setup-kubernetes.sh --dev --status

# Show resolved config (hostnames, enabled apps)
./setup-kubernetes.sh --dev --show-config

# Show access URLs
sudo ./setup-kubernetes.sh --dev --show-urls

# Show saved credentials
sudo ./setup-kubernetes.sh --dev --show-credentials

# Get dashboard access token
sudo ./setup-kubernetes.sh --dev --get-kube-token

# Verify TLS certificates
sudo ./setup-kubernetes.sh --dev --verify-tls

# Restart an app
sudo ./setup-kubernetes.sh --dev --restart-app kube
sudo ./setup-kubernetes.sh --dev --restart-app argocd
sudo ./setup-kubernetes.sh --dev --restart-app vault

# Update ingress hostnames (after changing config)
sudo ./setup-kubernetes.sh --dev --update-ingress all

# Show logs
sudo ./setup-kubernetes.sh --dev --logs vault

# Update all CLI tools to latest versions
sudo ./setup-kubernetes.sh --dev --update-cli-tools
```

### Force mode

Add `--force` to any command to skip "already exists" checks and
reinstall/redeploy from scratch:

```bash
sudo ./setup-kubernetes.sh --dev --deploy-kube --force
```

## Credentials

After deploying infrastructure apps, credentials are automatically saved to
`~/secrets/`:

| File | Contents |
|---|---|
| `kube-<env>.txt` | Dashboard URL + permanent bearer token |
| `argocd-<env>.txt` | ArgoCD URL + admin username + initial password |
| `vault-<env>.txt` | Vault URL + initialization instructions |

Files are created with `chmod 600` (owner-only access).

### Backup and restore

```bash
# Encrypt and push to git
./manage-secrets.sh --backup

# Decrypt and restore
./manage-secrets.sh --restore

# List files that would be backed up
./manage-secrets.sh --list

# Remove secret files (with confirmation)
./manage-secrets.sh --remove
```

The file patterns to backup are defined in `manage-secrets.config`.

## CLI tools installed

| Tool | Purpose |
|---|---|
| `argocd` | ArgoCD CLI for managing applications |
| `vault` | HashiCorp Vault CLI |
| `yq` | YAML processor |
| `jq` | JSON processor |
| `tailscale` | Tailscale VPN client (CLI only, no registration) |

## Manifest templates

Manifests under `manifests/` use placeholder tokens that are replaced at
runtime by `render_manifest()`:

| Placeholder | Replaced with |
|---|---|
| `__KUBE_HOST__` | Kube dashboard hostname |
| `__ARGOCD_HOST__` | ArgoCD hostname |
| `__VAULT_HOST__` | Vault hostname |
| `__CLUSTER_ISSUER__` | ClusterIssuer name |
| `__CLUSTER_NAME__` | Cluster display name |
| `__VAULT_STORAGE_SIZE__` | Vault PVC size |

## Requirements

- Ubuntu Linux (22.04+ recommended)
- Root/sudo access
- Internet connectivity (for snap, Helm repos, Let's Encrypt, CLI downloads)
- DNS records pointing `*.{env}.{domain}` to the server's public IP
