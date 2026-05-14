# Setup Ubuntu Kubernetes

Two halves of a complete Kubernetes platform, in one repo:

1. **Cluster installer** (`setup-kubernetes/`) — automated, idempotent setup of a
   **MicroK8s 1.35** cluster on Ubuntu, plus the three Helm-managed
   "control-plane" apps: Headlamp dashboard, ArgoCD, and HashiCorp Vault.
2. **GitOps platform** (`apps/`, `argocd/`, `charts/`, `platform/`) — the
   ArgoCD-managed application tree. Once Argo is up, point it at this repo
   and it deploys the per-env platform: CoreDNS rewrites, MongoDB, PostgreSQL,
   Redis, Postfix, Seq, DBGate, observability (Prometheus / Grafana / Loki /
   Tempo / Alloy), Tekton, and the image-builder pipeline.

All examples below use `<env>` as a placeholder — replace with one of
`dev`, `test`, or `prod` to match the config file you're using.

## Repository layout

```
.
├── README.md             You are here.
├── CLAUDE.md             Notes for Claude Code sessions in this repo.
│
├── setup-kubernetes/     Cluster installer — shell scripts + per-env configs.
│   ├── setup-kubernetes.sh       Main script — install, deploy, maintain.
│   ├── reset-cluster.sh          Robust cluster wipe (preserves data mount).
│   ├── common-kubernetes.sh      Shared function library.
│   ├── manage-secrets.sh         Backup/restore credentials (GPG encrypted).
│   ├── manage-secrets.config     Files included in the secrets backup.
│   ├── config.example            Documented config template (checked in).
│   ├── configs/                  Per-env configs `config.<env>` (gitignored).
│   └── manifests/
│       ├── kube/                 Headlamp (Dashboard) Helm values + Ingress.
│       ├── argocd/               ArgoCD Helm values (Ingress in values.yaml).
│       └── vault/                Vault Helm values + Traefik IngressRoute,
│                                 ServersTransport, cert-manager Certificate.
│
├── platform/             Centralized platform-wide values consumed by every
│                         chart via Helm's `global:` convention. Edit one file
│                         to change the domain, alert recipients, storage
│                         class, ClusterIssuer, etc.
│
├── charts/               Reusable Helm library charts (chart-of-charts):
│                         deployment, ingress, middleware, pvc, rbac,
│                         configmap, cronjob, acr-secret, external-secret,
│                         secret-store, monitoring.
│
├── apps/                 Per-app umbrella Helm charts (one dir per app):
│                         coredns, mongodb, postgresql, redis, postfix, seq,
│                         dbgate, observability, tekton, image-builder.
│
└── argocd/               Per-env GitOps bootstrap:
    ├── dev/
    │   ├── root-app.yaml         App-of-Apps entry point (kubectl apply once).
    │   └── apps/
    │       └── applicationset.yaml   Generates one Application per app.
    ├── test/  (same shape)
    └── prod/  (same shape)
```

The scripts inside `setup-kubernetes/` compute their own `SCRIPT_DIR`, so you
run them from inside that directory. The repo root stays clean for the GitOps
tree.

## Quick start

### Phase 1 — Install the cluster

```bash
cd setup-kubernetes/

# 1. Copy the example config and edit it (substitute <env>)
cp config.example configs/config.<env>
vim configs/config.<env>   # set CLUSTER_NAME, DOMAIN_SUFFIX, LETSENCRYPT_EMAIL, ...

# 2. (Pre-work outside the script) Add DNS A records for the three hostnames
#    `kube.<env>.<DOMAIN_SUFFIX>`, `argo.<env>.<DOMAIN_SUFFIX>`,
#    `vault.<env>.<DOMAIN_SUFFIX>`  →  this host's public IPv4.
#    Wildcard `*.<env>.<DOMAIN_SUFFIX>` also works. The script will fail-fast
#    at the start of `--deploy-all` if any of these don't resolve.

# 3. Install MicroK8s + addons + CLI tools
sudo ./setup-kubernetes.sh --<env>

# 4. Deploy infrastructure apps (idempotent)
sudo ./setup-kubernetes.sh --<env> --deploy-all

# 5. Check everything is running (expect 32/32 OK)
sudo ./setup-kubernetes.sh --<env> --check
```

At this point you have a running MicroK8s cluster with Headlamp + ArgoCD + Vault
reachable at `kube/argo/vault.<env>.<DOMAIN_SUFFIX>`. ArgoCD is empty —
no Applications yet.

### Phase 2 — Bootstrap the GitOps platform

ArgoCD reads the GitOps tree (`apps/`, `argocd/<env>/`, `charts/`, `platform/`)
from this very repo. To wire it up:

```bash
# 1. Replace the placeholder repoURL with the real Git remote in every
#    ArgoCD manifest. Run from the repo root.
REAL_REPO=https://github.com/<your-account>/setup-ubuntu-kubernetes.git
REAL_BRANCH=main
find argocd -name '*.yaml' -exec \
  sed -i "s|https://to-your-repo-folder|$REAL_REPO|g; s|targetRevision: master|targetRevision: $REAL_BRANCH|g" {} \;
git add argocd && git commit -m "argocd: point at the real Git remote" && git push

# 2. Apply the per-env root-app. ArgoCD picks it up and creates the
#    ApplicationSet, which in turn creates one Application per app under
#    apps/.
microk8s kubectl apply -f argocd/<env>/root-app.yaml

# 3. Watch the apps sync (sync waves: 3=tekton, 5=coredns, 10=mongodb+postgresql,
#    20=postfix+redis+seq, 25=image-builder, 30=dbgate+observability)
microk8s kubectl -n argocd get applications -w
```

### Phase 3 — Vault data + ESO bootstrap

For ESO-backed apps to pull their secrets, two more things must happen
**outside** this repo (the user's sibling `setup-gitops` workflow):

1. **Vault data** under `<env>/app/<name>` for every app that has an
   ExternalSecret — mongodb, postgresql, postfix, seq, dbgate, observability,
   image-builder. See the per-app `values-{common,env}.yaml.externalSecret`
   blocks for the required Vault keys.
2. **Vault role** — every app namespace must be in
   `bound_service_account_namespaces` on Vault's `external-secrets` role.

If you're starting from scratch and haven't bootstrapped Vault yet, the
`setup-kubernetes.sh --deploy-vault` step gives you the unseal keys + root
token; use those to populate the KV store and configure the auth role.

## Configuration

All settings live in a single config file per environment (`configs/config.<env>`).
Copy `config.example` to get started — every variable is documented with
comments explaining what it does and when to change it.

The script loads the right config automatically based on the environment flag:

| Flag | Config file loaded |
|---|---|
| `--dev` | `configs/config.dev` |
| `--test` | `configs/config.test` |
| `--prod` (default) | `configs/config.prod` |
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

### Infrastructure apps (installer-managed)

Three apps can be deployed on top of MicroK8s by the installer itself
(separate from the GitOps platform). Each is optional and controlled
by an `ENABLE_*` flag in the config:

| App | Config flag | Hostname | Description |
|---|---|---|---|
| Kube Dashboard | `ENABLE_KUBE` | `kube.<env>.<domain>` | Headlamp cluster UI |
| ArgoCD | `ENABLE_ARGOCD` | `argo.<env>.<domain>` | GitOps controller |
| Vault | `ENABLE_VAULT` | `vault.<env>.<domain>` | Secrets management |

Set `ENABLE_*="false"` to skip an app entirely. Deploy, upgrade, and uninstall
commands for a disabled app are silently skipped.

## Usage

All commands assume `cd setup-kubernetes/` first.

### Phase 1 — Cluster installation

```bash
# Full install (MicroK8s + addons + storage + cert-manager + CLI tools + aliases)
sudo ./setup-kubernetes.sh --<env>

# Install only specific components
sudo ./setup-kubernetes.sh --<env> --install-microk8s
sudo ./setup-kubernetes.sh --<env> --configure-storage
sudo ./setup-kubernetes.sh --<env> --configure-cert-manager
sudo ./setup-kubernetes.sh --<env> --install-cli-tools
sudo ./setup-kubernetes.sh --<env> --setup-aliases

# Skip specific components
sudo ./setup-kubernetes.sh --<env> --skip-storage --skip-aliases
```

### Phase 2 — Infrastructure deployment

```bash
# Deploy all enabled apps
sudo ./setup-kubernetes.sh --<env> --deploy-all

# Deploy individually
sudo ./setup-kubernetes.sh --<env> --deploy-kube
sudo ./setup-kubernetes.sh --<env> --deploy-argocd
sudo ./setup-kubernetes.sh --<env> --deploy-vault

# Upgrade to latest chart version
sudo ./setup-kubernetes.sh --<env> --upgrade-kube
sudo ./setup-kubernetes.sh --<env> --upgrade-argocd
sudo ./setup-kubernetes.sh --<env> --upgrade-vault

# Uninstall (Helm uninstall + cleanup resources)
sudo ./setup-kubernetes.sh --<env> --uninstall-kube
sudo ./setup-kubernetes.sh --<env> --uninstall-argocd
sudo ./setup-kubernetes.sh --<env> --uninstall-vault
```

Before any `--deploy-*` runs, the script does a DNS pre-flight: it resolves
each enabled host (`kube.<env>.<domain>`, etc.). If any fail, it aborts with
the host's detected public IPv4 and an explicit "add an A record …" message,
instead of letting cert-manager hang on HTTP-01 challenges for 25+ minutes.

### Maintenance

```bash
# Show pods, ingresses, certificates for all apps
sudo ./setup-kubernetes.sh --<env> --status

# Show resolved config (hostnames, enabled apps)
./setup-kubernetes.sh --<env> --show-config

# Show access URLs
sudo ./setup-kubernetes.sh --<env> --show-urls

# Show saved credentials
sudo ./setup-kubernetes.sh --<env> --show-credentials

# Get dashboard access token
sudo ./setup-kubernetes.sh --<env> --get-kube-token

# Verify TLS certificates
sudo ./setup-kubernetes.sh --<env> --verify-tls

# Restart an app
sudo ./setup-kubernetes.sh --<env> --restart-app kube
sudo ./setup-kubernetes.sh --<env> --restart-app argocd
sudo ./setup-kubernetes.sh --<env> --restart-app vault

# Update ingress hostnames (after changing config)
sudo ./setup-kubernetes.sh --<env> --update-ingress all

# Show logs
sudo ./setup-kubernetes.sh --<env> --logs vault

# Update all CLI tools to latest versions
sudo ./setup-kubernetes.sh --<env> --update-cli-tools
```

### Reset (wipe and start fresh)

If a previous install left things in a broken state, you're switching MicroK8s
channels, or you just want a confident clean slate:

```bash
sudo ./reset-cluster.sh --<env>          # required — reads STORAGE_PATH and
                                         # STORAGE_DIRECTORY from configs/config.<env>
sudo ./reset-cluster.sh --<env> --yes    # skip the confirmation prompt
```

The env flag is **required** — the reset reads `STORAGE_PATH` and
`STORAGE_DIRECTORY` from your config so it knows which mount to preserve
(`/mnt/data` is just one possible value — your config might use `/data`,
`/srv/k8s`, or any other path) and which subdirectory to wipe. Hard-coding
`/mnt/data` would be wrong on hosts that mount their data disk elsewhere.

What the reset does:

- Removes the MicroK8s snap (force-kills if stuck), wipes `/var/snap/microk8s/`,
  kills lingering kubelite/containerd/calico processes.
- Cleans stale `cali-*`, `KUBE-*`, `CNI-*` chains from both iptables-nft and
  iptables-legacy, plus any native nft tables (`kube-proxy`, `calico`, etc.).
- Removes `/etc/cni/net.d/`, `/opt/cni/bin/`, Calico vxlan + cali veth
  interfaces, and any pod-CIDR blackhole routes.
- Wipes the PV data directory at `STORAGE_DIRECTORY` —
  **but never unmounts `STORAGE_PATH` or touches the disk underneath**.
- Removes user-level state: `~/secrets/`, `~/.kube/`, `~/.cache/helm`,
  `~/.config/helm`, and the `kubectl`/`helm` aliases from `~/.bashrc`.
- Removes script system state: `/var/lib/kubernetes-setup/`, `/var/log/kubernetes-setup/`.
- **Does not touch any file inside this repo folder.** Configs, manifests,
  and scripts stay intact so you can immediately re-run `setup-kubernetes.sh`.

After reset, reinstall:

```bash
sudo ./setup-kubernetes.sh --<env>
sudo ./setup-kubernetes.sh --<env> --deploy-all
```

### Force mode

Add `--force` to any command to skip "already exists" checks and
reinstall/redeploy from scratch:

```bash
sudo ./setup-kubernetes.sh --<env> --deploy-kube --force
```

## GitOps platform (`apps/` + `argocd/` + `charts/` + `platform/`)

Once ArgoCD is up (Phase 1+2 above), the GitOps tree drives every per-env
platform deployment. ArgoCD reads from this repo continuously and reconciles
the cluster state against the manifests under `apps/`.

### `platform/` — central knobs

One file per env plus a common one. Anything that varies cluster-wide but
not per-app lives here under the `global:` key (Helm's built-in convention
propagates `global:` to every subchart automatically).

```yaml
# platform/values-common.yaml
global:
  domain: <your-domain>           # used in every Ingress host, Vault URL, smtp_from
  timezone: Europe/Amsterdam      # consumed by mongodb / postgresql via Bitnami tpl
  storageClass: microk8s-hostpath # PVC default for every app
  clusterIssuer: letsencrypt-ci   # cert-manager issuer for every Ingress
  secretStoreName: vault-backend  # ESO SecretStore name used by every ExternalSecret
  alertRecipients:                # Alertmanager default fallback receiver
    - <operator-email>
```

```yaml
# platform/values-dev.yaml
global:
  env: dev
  vaultUrl: https://vault.dev.<your-domain>:8200
```

To swap the platform domain, edit one line in `platform/values-common.yaml`,
commit, push — ArgoCD reconciles. Same for the alert mailbox, timezone, etc.

### `charts/` — reusable library charts

Eleven library charts that other apps pull in as Helm dependencies:

| Chart | Emits |
|---|---|
| `deployment` | Deployment + Service (env vars `tpl`'d at render time) |
| `ingress` | Ingress with auto-injected `cert-manager.io/cluster-issuer` and `tpl`'d host / serviceName / tls.secretName |
| `middleware` | Traefik `Middleware` CRD (BasicAuth, rate-limit, …) |
| `pvc` | PVC defaulting to `global.storageClass` |
| `rbac` | ServiceAccount + Role + RoleBinding scaffold |
| `configmap` | Generic ConfigMap |
| `cronjob` | CronJob scaffold |
| `acr-secret` | dockerconfigjson Secret for Azure Container Registry |
| `external-secret` | ESO ExternalSecret defaulting to `global.secretStoreName` |
| `secret-store` | Per-namespace Vault SecretStore + ServiceAccount, reads `global.vaultUrl` |
| `monitoring` | ServiceMonitor / PodMonitor / PrometheusRule / AlertmanagerConfig from values maps; Alloy DaemonSet config + cluster-level rules |

### `apps/` — umbrella charts (one dir per app)

| App | Sync wave | Purpose |
|---|---|---|
| `tekton` | 3 | Tekton Pipelines + Triggers operator install (vendored upstream YAML — see `apps/tekton/README.md`) |
| `coredns` | 5 | DNS rewrites for cluster-internal Vault access (host-DNS → ClusterIP) |
| `mongodb` | 10 | Bitnami mongodb (3-node ReplicaSet) + prometheus-mongodb-exporter |
| `postgresql` | 10 | Bitnami postgresql (standalone) + built-in metrics exporter |
| `postfix` | 20 | Send-only SMTP relay (bokysan chart) with DKIM/SPF/DMARC |
| `redis` | 20 | Bitnami redis (standalone, AOF on, no auth) + redis exporter |
| `seq` | 20 | Datalust Seq structured-log UI |
| `image-builder` | 25 | Tekton-based image build pipeline with multi-provider webhooks. See [`apps/image-builder/README.md`](apps/image-builder/README.md) |
| `dbgate` | 30 | Unified DB UI for Mongo + Redis + Postgres |
| `observability` | 30 | kube-prometheus-stack + Loki + Tempo + Alloy + Alertmanager |

Each app's `Chart.yaml` declares deps on the library charts it needs;
`values-common.yaml` holds env-independent settings, `values-{dev,test,prod}.yaml`
hold per-env overrides.

### `argocd/<env>/` — bootstrap entry point per env

- `root-app.yaml` — single `Application` resource that points at the
  `argocd/<env>/apps/` directory. Apply once with `kubectl apply -f`.
- `apps/applicationset.yaml` — `ApplicationSet` with a list generator that
  enumerates every app + its sync wave, namespace, etc. Generates one
  `Application` per entry. Uses the `goTemplate: true` syntax + a
  `templatePatch` for per-app conditionals (e.g. observability gets
  `ServerSideApply=true` and `ignoreDifferences` for kube-prometheus-stack
  StatefulSet drift).

The `sources:` array uses ArgoCD's multi-source feature with a `$values` ref
so every app's chart automatically loads `platform/values-common.yaml` +
`platform/values-<env>.yaml` *before* its own values files — a single source
of truth for platform constants, no copy-paste.

### Modifying the GitOps platform

- **Change the domain / operator mailbox / storage class** —
  edit `platform/values-common.yaml`, commit, push.
- **Change a per-env Vault URL** — `platform/values-<env>.yaml`.
- **Add a new app** — drop a new `apps/<name>/` dir following the existing
  pattern, then append one entry to each
  `argocd/<env>/apps/applicationset.yaml`'s element list.
- **Tune an existing app** — edit its `apps/<name>/values-{common,env}.yaml`.

## Credentials

After deploying infrastructure apps, credentials are automatically saved to
`~/secrets/`:

| File | Contents |
|---|---|
| `kube-<env>.txt` | Dashboard URL + permanent bearer token |
| `argocd-<env>.txt` | ArgoCD URL + admin username + initial password |
| `vault-<env>.txt` | Vault URL + 5 unseal keys + root token |

Files are created with `chmod 600` (owner-only access).

> Vault's unseal keys and root token are **irrecoverable**. If you lose
> `vault-<env>.txt` and Vault is sealed, the data is gone. Back this file
> up offline (or via `manage-secrets.sh --backup`) before doing anything
> else after `--deploy-all`. The deploy script will not overwrite an
> existing `vault-<env>.txt` on re-runs.

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

Manifests under `setup-kubernetes/manifests/` use placeholder tokens that are
replaced at runtime by `render_manifest()`:

| Placeholder | Replaced with |
|---|---|
| `__KUBE_HOST__` | Kube dashboard hostname |
| `__ARGOCD_HOST__` | ArgoCD hostname |
| `__VAULT_HOST__` | Vault hostname |
| `__CLUSTER_ISSUER__` | ClusterIssuer name |
| `__CLUSTER_NAME__` | Cluster display name |
| `__VAULT_STORAGE_SIZE__` | Vault PVC size |

## Requirements

- Ubuntu Linux 22.04 / 24.04 / 26.04 LTS
- Root/sudo access
- Internet connectivity (for snap, Helm repos, Let's Encrypt, CLI downloads)
- DNS A records pointing `kube/argo/vault.{env}.{domain}` to the host's public
  IPv4 — the deploy step fails fast if these are missing.
- Inbound port 80 from the public internet reachable on the host (for HTTP-01
  challenges).

## Known issues / OS-specific notes

These are wired into the script and apply automatically — listed here so you
know what's happening and what config knob controls each one.

### Traefik (not nginx-ingress)

The script targets `MICROK8S_CHANNEL="1.35/stable"` (Kubernetes v1.35
"Timbernetes", December 2025) — the highest numeric stable channel currently
published in the snap store. 1.36/stable does not exist yet; only edge/
candidate channels carry 1.36 as of May 2026. Starting in MicroK8s 1.35 the
bundled `ingress` addon was
[switched from nginx-ingress to Traefik](https://github.com/canonical/microk8s/issues/5293)
because [Kubernetes SIG Network retired the nginx-ingress project on
24 March 2026](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/).

Practical consequence: Vault's manifests use Traefik CRDs (`IngressRoute` +
`ServersTransport`) rather than a plain Ingress with `nginx.ingress.*`
annotations. Dashboard and ArgoCD use vendor-neutral Ingress resources and
work on Traefik unchanged. Don't pin `MICROK8S_CHANNEL` to anything older
than `1.35/stable` without also reverting the Vault manifests to the
nginx-ingress form (see git history for commit 604f3bd if you need the old
files back).

### Calico iptables backend split-brain (esp. Ubuntu 26.04, kernel 7.0)

On hosts with a "modern" iptables-nft default (Ubuntu 22.04+, but most
visible on Ubuntu 26.04 with kernel 7.0), Calico's Felix can auto-detect the
wrong iptables backend (Legacy) while kube-proxy and the host both use
`iptables-nft`. The two backends paint into separate kernel rule sets —
packets traverse both, and packet forwarding for **pod-to-internet traffic
silently fails**. Symptom: CoreDNS times out forwarding to its upstream
resolvers, ClusterIssuer fails ACME registration, every HTTP-01 challenge
gets connection-refused.

`align_calico_backend()` runs on every install: it patches
`FelixConfiguration.spec.iptablesBackend` to match the host's actual
backend (NFT on modern Ubuntu) and rollout-restarts `calico-node` so Felix
repaints. Idempotent — re-runs are a no-op once aligned. The function
deliberately does **not** flush any iptables rules; an earlier version did,
which broke the CNI `portmap` plugin's `CNI-HOSTPORT-*` chains and silently
killed `hostPort` plumbing.

References:
[canonical/microk8s#2180](https://github.com/canonical/microk8s/issues/2180),
[canonical/microk8s#4686](https://github.com/canonical/microk8s/issues/4686).

### Networks that block outbound UDP/53

Some VPS / corporate / VLAN egress policies allow TCP/53 but drop UDP/53 to
public DNS resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9). systemd-resolved on the host
hides this by silently falling back to TCP; CoreDNS doesn't. Symptom: CoreDNS
logs `i/o timeout` to its upstream resolvers, ClusterIssuer stuck at
`ErrRegisterACMEAccount`.

Set `DNS_FORCE_TCP="true"` in your `configs/config.<env>` and the script will
add a `force_tcp` directive to CoreDNS's `forward` block. Default is `"false"`
so it doesn't slow down DNS on networks where UDP/53 is open.

### Inbound HTTP-01 challenge

cert-manager validates ownership of `kube/argo/vault.<env>.<domain>` over
plain HTTP on port 80 from the public internet. Two prerequisites that the
script enforces or checks:

1. **DNS A records** for the three hostnames must point at this host's public IP.
   The script's `check_ingress_dns_resolves` pre-flight aborts the deploy if
   any of them don't resolve, printing the detected public IPv4 so you can
   add the missing record. (cert-manager itself would otherwise hang on the
   HTTP-01 self-check for ~25 minutes and save failure placeholders into
   `~/secrets/*-<env>.txt` — most importantly losing the Vault unseal keys.)
2. **Inbound port 80** must be reachable from the internet. With MicroK8s 1.35's
   Traefik addon the controller binds :80/:443 on the node by default — verify
   with `sudo ss -tln | grep -E ':(80|443) '`. The script does not auto-check
   this; you'll see HTTP-01 challenges stuck `Waiting for HTTP-01 challenge
   propagation` if port 80 isn't reachable.

### Vault init recovery

If Vault's TLS Secret isn't ready when `deploy_vault` runs (e.g. cert-manager
still issuing the cert), `vault-0` stays in `ContainerCreating` and the
initial `vault operator init` `kubectl exec` returns nothing. Previously
this dropped a "Status: Initialization failed" placeholder into
`~/secrets/vault-<env>.txt` and re-runs of `--deploy-all` did not retry
(because the Helm release already existed).

`deploy_vault` now:

- skips only the Helm install when the release exists, then still runs the
  init+unseal step on every invocation, and
- pre-checks that `vault-0` is exec-able before attempting init, so the
  "Initialization failed" placeholder is only written when we genuinely
  reached `vault operator init` and it failed.

If init was already done and `vault-<env>.txt` exists, subsequent runs log
`Preserving existing credentials file` and never overwrite the keys.
