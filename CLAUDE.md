# CLAUDE.md

Guidance for Claude Code sessions in this repo. Read once at the start of a
session and treat the constraints below as durable instructions.

## What this repo does

Two distinct concerns, both checked in here:

1. **Cluster installer** (`setup-kubernetes/`) — automated, idempotent
   installer for a **MicroK8s 1.35** cluster on Ubuntu (22.04 / 24.04 /
   26.04), plus three Helm-managed control-plane apps: **Headlamp**
   dashboard, **ArgoCD**, **HashiCorp Vault**. Shell-script + Helm values.
2. **GitOps platform tree** (`apps/`, `argocd/`, `charts/`, `platform/`) —
   the ArgoCD-managed application tree the cluster runs once Argo is up:
   CoreDNS, MongoDB, PostgreSQL, Redis, Postfix, Seq, DBGate, observability
   (Prometheus/Grafana/Loki/Tempo/Alloy), Tekton, image-builder.

The two halves are independent: the installer can run without ever
bootstrapping the GitOps tree, and the GitOps tree can be applied to any
existing cluster with ArgoCD + the library charts available. They share this
repo because they share a cluster.

See `README.md` for the user-facing docs — don't repeat their content here.

## Layout

```
README.md                User docs.
CLAUDE.md                This file.

setup-kubernetes/        Shell installer + per-env configs + control-plane manifests.
                         Run scripts from inside this dir; SCRIPT_DIR is computed.

platform/                Central Helm globals (one source of truth for the
                         platform domain, env name, vaultUrl, alertRecipients,
                         storageClass, clusterIssuer, secretStoreName,
                         timezone). Consumed by every chart via Helm's
                         `global:` propagation.

charts/                  Reusable Helm library charts (chart-of-charts):
                         deployment / ingress / middleware / pvc / rbac /
                         configmap / cronjob / acr-secret / external-secret /
                         secret-store / monitoring.

apps/                    Per-app umbrella charts — one dir per app, each with
                         Chart.yaml + values-{common,dev,test,prod}.yaml +
                         templates/. Apps: coredns, mongodb, postgresql,
                         redis, postfix, seq, dbgate, observability, tekton,
                         image-builder.

argocd/{dev,test,prod}/  Per-env GitOps bootstrap: root-app.yaml (App-of-Apps
                         entry point) + apps/applicationset.yaml (single
                         ApplicationSet that generates one Application per
                         app, with sync waves, prune/createNamespace flags,
                         and a templatePatch for per-app conditionals).
```

## Two-host context (important)

This repo is shared between **at least two hosts** that the user operates:

- A **26.04 dev box** — see project memory `host-26-04-dev-box`. HTTPS git
  credential cache is set up here (`credential.helper=store`); commits +
  pushes work from this host directly. Active claude sessions usually run
  here under `/home/server/repos/setup-ubuntu-kubernetes`.
- A **24.04 sister host** — separately managed, you don't have access.
- A **Windows workstation** (`D:\repos\kartalbas\...`) — also has HTTPS
  credential caching. Used interchangeably with the Linux box for editing
  + committing; the installer scripts run on the Ubuntu hosts only.

Each Ubuntu host keeps its own `setup-kubernetes/configs/config.<env>`
(gitignored). Values like `STORAGE_PATH` differ between them intentionally
(e.g. `/data` on 26.04, `/mnt/data` on 24.04). **Never unify configs**;
each is per-host. Same applies to `setup-kubernetes/configs/secrets.<env>`
(also gitignored) — the per-host Vault-seed input file. Updates to the
checked-in `configs/secrets.example` (template) do NOT propagate to the
per-host `configs/secrets.<env>` files automatically; the user must
hand-update those when the schema grows.

**Any change you push to `main` runs on both hosts** the next time the user
`git pull`s. Don't merge OS-specific fixes that would regress the working
host. Existing 26.04 workarounds in the script
(`configure_kube_proxy_nftables`, `align_calico_backend`,
`fix_coredns_upstream`) are written to be idempotent and no-op on 24.04 too —
follow that pattern.

## Current pinned versions (snapshot 2026-05-14)

Single source of truth for "what's deployed right now." Bump candidates
come from comparing this against GitHub releases periodically. Charts that
are installed at `latest` (no pin) are also listed so it's clear they
auto-update on each install.

| Component | Pin | Where | Notes |
|---|---|---|---|
| MicroK8s | `1.35/stable` | `setup-kubernetes/configs/config.example` MICROK8S_CHANNEL | 1.36 is edge-only as of May 2026. |
| Zot | `v2.1.16` | `apps/registry/Chart.yaml` appVersion + `values-common.yaml` `app.image.tag` | Two places — must match. |
| Bitnami mongodb (chart / DB) | `19.0.3` / `8.3.2` | `apps/mongodb/Chart.yaml` deps[mongodb].version | OCI registry only since Aug 2025. |
| Bitnami postgresql (chart / DB) | `18.6.6` / `18.4.0` | `apps/postgresql/Chart.yaml` deps[postgresql].version | 17.x is gone from bitnamicharts + bitnamilegacy. |
| Bitnami redis (chart / DB) | `25.5.3` / `8.6.3` | `apps/redis/Chart.yaml` deps[redis].version | |
| DBGate | `7.1.11` | `apps/dbgate/Chart.yaml` appVersion + `values-common.yaml` `app.image.tag` | Two places — must match. |
| External-Secrets chart + operator | `2.4.1` / `v2.4.1` | `apps/external-secrets/Chart.yaml` deps[external-secrets].version | Operator + chart numbers track 1:1 from v2.x onward. |
| Tekton Pipelines | `v1.12.0` | `apps/tekton/values-common.yaml` `release.pipelinesVersion` (informational) + vendored YAML in `templates/release-pipelines.yaml` | Refresh procedure in `apps/tekton/README.md`. |
| Tekton Triggers | `v0.35.0` | same place | |
| Tekton Interceptors | `v0.35.0` | same place | |
| Tekton Dashboard | `v0.68.0` | `apps/tekton/values-common.yaml` `release.dashboardVersion` (informational) + vendored YAML in `apps/tekton/templates/release-dashboard.yaml` | Gated on `.Values.dashboard.enabled` (DEV only). |
| Buildah (build image) | `quay.io/buildah/stable:v1.43.1` | `apps/image-builder/templates/tasks/buildah-build-push.yaml` step image | |
| Trivy (scan image) | `aquasec/trivy:0.70.0` | `apps/image-builder/templates/tasks/trivy-scan.yaml` step image | |
| Prometheus-community mongodb-exporter chart | `3.7.0` | `apps/mongodb/Chart.yaml` | |
| Prometheus-community redis-exporter chart | `6.5.0` | `apps/redis/Chart.yaml` | |
| Headlamp / ArgoCD / Vault Helm charts | (no pin — `helm install` latest at deploy time) | `setup-kubernetes/lib/deploy-{kube,argocd,vault}.sh` | Re-running `--deploy-<app>` after a chart release picks up the new version. |
| ArgoCD Image Updater chart | (no pin — latest at deploy time) | `setup-kubernetes/lib/deploy-image-updater.sh` | Same pattern as ArgoCD/Vault: `--deploy-image-updater` re-pulls latest. Installed in the `argocd` namespace alongside ArgoCD itself. |
| cert-manager / Traefik | MicroK8s addon defaults | snap addon | Tied to MicroK8s channel. |

## Hardcoded constraints — DO NOT change without asking

### Installer side (`setup-kubernetes/`)

- `MICROK8S_CHANNEL="1.35/stable"`. 1.36 is edge-only as of May 2026; don't
  bump.
- `--proxy-mode=nftables` written into `/var/snap/microk8s/current/args/kube-proxy`
  with a kubelite restart. 1.35 defaults to IPVS, which conflicts with
  Calico's nftables backend. Removing breaks pod networking.
- Vault manifests use Traefik CRDs (`IngressRoute`, `ServersTransport`).
  MicroK8s 1.35's ingress addon is Traefik (nginx-ingress was retired
  upstream March 2026). Don't replace them with nginx-style Ingress.
- `DNS_FORCE_TCP="true"` in the dev config exists because the LAN this dev
  host runs on blocks outbound UDP/53 to public resolvers. Leave it on
  unless the user explicitly says the network changed.
- `STORAGE_PATH=/data` (on this host's `config.dev`) — not `/mnt/data`.

### GitOps tree side (`apps/`, `argocd/`, `charts/`, `platform/`)

- **Repo + branch**: `argocd/<env>/{root-app.yaml, apps/applicationset.yaml}`
  point at `https://github.com/kartalbas/setup-ubuntu-kubernetes.git` @
  `main`. The legacy placeholder shape (`<github-account>/<github-repo>` /
  `master`) is gone; if you ever see it reappear, that's a regression.
- **ClusterIssuer name**: `platform/values-common.yaml` has
  `global.clusterIssuer: letsencrypt-prod`. This MUST equal
  `CLUSTER_ISSUER_NAME` in each per-host `configs/config.<env>` because
  setup-kubernetes creates the ClusterIssuer with that name. Mismatch =
  every GitOps-deployed Certificate stuck in "ClusterIssuer not found".
  The legacy value `letsencrypt-ci` was wrong; don't reintroduce.
- **External-Secrets-Operator**: deployed as a single ArgoCD-managed
  Application at `apps/external-secrets/` (sync wave 1, **not**
  cluster-wide-installed). Vendored CRDs in `templates/` cover ONLY
  the 2 we use (`ExternalSecret`, `SecretStore`) — not the chart's 23.
  Sync option `ServerSideApply=true` is mandatory because the
  `secretstores.external-secrets.io` CRD's OpenAPI schema is ~580 KB,
  exceeding the 262 KB kubectl client-side-apply annotation limit. The
  upstream chart ships `installCRDs=false` in our values; webhook +
  cert-controller disabled.
- **`apps/tekton/`**: vendored upstream YAMLs at `templates/release-{pipelines,
  triggers,interceptors}.yaml`. Versions pinned in `values-common.yaml`
  (informational only — actual versions = whatever's in the templates).
  Currently Pipelines `v1.12.0`, Triggers + Interceptors `v0.35.0` (all
  ghcr.io; gcr.io anon-pull retired pre-v0.65, irrelevant on current
  releases). Bumping is a manual `curl` refresh of the three files from
  the tektoncd/{pipeline,triggers} GitHub releases (see
  `apps/tekton/README.md`) plus a `preserveUnknownFields: false` sed-strip
  on the result (legacy v1beta1 CRD field, stripped by K8s 1.22+ on write
  → permanent ArgoCD drift if left in).
- **Tekton Task step resources**: in v1, `steps[].resources` was renamed
  to `steps[].computeResources`. K8s silently drops the old name. Write
  `computeResources:` in `apps/image-builder/templates/tasks/*.yaml` —
  otherwise per-step CPU / memory pins disappear silently.
- **Bitnami chart deps** (`apps/{mongodb,postgresql,redis}/Chart.yaml`):
  pinned at `oci://registry-1.docker.io/bitnamicharts` — the legacy
  HTTPS index at `https://charts.bitnami.com/bitnami` started trimming
  older versions in Aug 2025 (only the latest stays). `postgresql 17.x`
  is GONE from both `bitnamicharts` and `bitnamilegacy`; we're on chart
  18.6.6 (PostgreSQL 18 appVersion). mongodb chart 19.0.3 (DB 8.x),
  redis chart 25.5.3 (DB 8.x).
- **`apps/image-builder/templates/triggers/azuredevops.yaml`** does NOT
  validate the Basic-auth secret (CEL can only check header presence).
  Phase A ships with this limitation; see
  [`apps/image-builder/README.md`](apps/image-builder/README.md) "Security
  hardening" for the two clean fixes.
- **`apps/image-builder/templates/trivy-db-cache-warmer.yaml`** keeps the
  `trivy-db-cache` PVC bound at all times. The cluster default
  StorageClass `microk8s-hostpath` is `WaitForFirstConsumer`, so without
  a consumer the PVC sits in Pending. The warmer is a 1-replica pause
  container; it co-mounts RWO with Tekton TaskRuns on the same node.
- **`apps/dbgate/values-common.yaml`** Ingress + connection FQDNs use
  Helm `tpl` to compose `gate.<env>.<domain>` and the database Service
  names (`mongodb-<env>-headless.mongodb.svc.cluster.local`, etc.) from
  platform globals — those expressions only render because the consuming
  charts (our `ingress` library; the `deployment` library after the `tpl`
  patch added in this repo) explicitly `tpl` those fields. Don't replace
  `tpl` with raw value rendering.
- **`apps/seq` cluster-issuer is hardcoded**: the datalust seq chart does
  NOT `tpl` user-provided ingress annotations, so we can't reference
  `.Values.global.clusterIssuer` inside seq's values. The literal
  `letsencrypt-prod` is in `apps/seq/values-{dev,test,prod}.yaml`.
  Must match the platform-global manually.
- **Storage class centralization is partial**: subchart values blocks
  (Bitnami mongodb / redis / postgresql / kube-prometheus-stack PVCs)
  intentionally omit `storageClass` so they fall back to either
  `global.storageClass` (when the chart honors Helm's global convention)
  or the cluster default — which on MicroK8s is `microk8s-hostpath` anyway,
  so the fallback always lands on the right thing. Don't add explicit
  `storageClass: microk8s-hostpath` back into subchart values blocks.
- **`apps/registry/` runs on DEV only**: single platform-wide Zot OCI
  registry at `zot.dev.<DOMAIN_SUFFIX>`. The ApplicationSet entry exists
  ONLY in `argocd/dev/apps/applicationset.yaml` (sync wave 7) —
  test/prod do not generate this Application. Image storage on the
  platform default StorageClass (50Gi PVC).
  - **Topology**: ONE Helm release deploys ONE pod (Zot v2.1.16) +
    ONE Service + ONE Ingress. Zot's bundled web UI is enabled
    (`extensions.ui.enable: true` in `config.json`) and serves from the
    same hostname/port as the OCI distribution API — one process, one
    UI, one cert. Joxit was removed (May 2026) as redundant once Zot's
    own UI was confirmed sufficient.
  - **htpasswd auth — three users** materialized from Vault by ESO:
    - `admin` — Zot's `accessControl.adminPolicy` (cross-repo admin:
      read+create+update+delete spanning every repo). Use for Zot UI
      interactive ops (browse, delete).
    - `push-user` — read+create+update+delete on every repo. Consumed by
      image-builder's buildah-build-push task (envFromSecret).
    - `pull-user` — read-only on every repo. Consumed by every workload
      namespace's imagePullSecret (via `charts/acr-secret/`).
    `defaultPolicy` + `anonymousPolicy` are both `[]` (no anonymous access).
  - **Zot image** pin is `ghcr.io/project-zot/zot-linux-amd64:v2.1.16`
    matching `Chart.yaml`'s `appVersion`. Don't switch to the upstream
    `project-zot/helm-charts/zot` chart — our wrapper is consistent with
    the rest of the platform's library-chart pattern.
- **Platform IdP (Authentik) lives in `setup-kubernetes/`, NOT in `apps/`**:
  the Identity Provider is INFRASTRUCTURE-tier — alongside ArgoCD, Vault,
  Headlamp. Reason: ArgoCD authenticates via the IdP, so the IdP can't be
  managed BY ArgoCD without a bootstrap cycle. Files:
    - `setup-kubernetes/lib/deploy-idp.sh` — generates secrets on first
      install (saves to `~/secrets/idp-<env>.txt`), idempotent helm
      upgrade of the upstream `authentik/authentik` chart, renders the
      Blueprints ConfigMap from `manifests/idp/blueprints/*.yaml`,
      pre-creates per-consumer K8s Secrets (`argocd-oidc` in argocd,
      `headlamp-oidc` in kubernetes-dashboard, `vault-oidc` in vault).
    - `setup-kubernetes/manifests/idp/{values.yaml, ingressroute.yaml,
       middleware-forwardauth.yaml, blueprints/*.yaml}`.
    - Dispatcher flag `--deploy-idp`, ordered FIRST in `--deploy-all`
      (`idp → kube → argocd → vault → seed-vault → image-updater`).
    - Hostname `idp.<env>.<DOMAIN_SUFFIX>`. Bundled PostgreSQL +
      Redis StatefulSets keep Authentik self-contained (NO dep on
      `apps/postgresql`, which is GitOps-managed).

  **OIDC clients (native, no proxy)**: ArgoCD, Headlamp, Vault, Grafana
  authenticate directly against the IdP via OIDC. One login at
  `idp.<env>.<DOMAIN_SUFFIX>` → all four signed in (no per-app login).
  Per-app config:
    - ArgoCD: `configs.cm.oidc.config` in `setup-kubernetes/manifests/
      argocd/values.yaml` references K8s Secret `argocd-oidc` (key
      `clientSecret`).
    - Headlamp: `config.oidc.secretName: headlamp-oidc` in
      `manifests/kube/values.yaml` — Secret has `clientID`,
      `clientSecret`, `issuerURL`.
    - Vault: OIDC auth method enabled by `enable_vault_oidc()` in
      `lib/deploy-vault.sh`, reads K8s Secret `vault-oidc`.
    - Grafana (GitOps): `grafana.grafana.ini.auth.generic_oauth.*` in
      `apps/observability/values-dev.yaml`; the client_secret comes from
      Vault via ESO (`apps/observability/Chart.yaml` dep
      `grafana-oidc-secret`, Vault path `secret/<env>/app/idp/
      grafana-client-secret`).

  **Forward-Auth Outpost (for apps without OIDC)**: Tekton Dashboard,
  dbgate, Seq don't speak OIDC. They sit behind the Authentik embedded
  Outpost via a Traefik forwardAuth Middleware annotation:
    `traefik.ingress.kubernetes.io/router.middlewares: idp-forwardauth@kubernetescrd`
  The Middleware CR lives in the `idp` namespace and is created by
  `deploy-idp.sh`. Apex-scoped session cookie (`.dev.<DOMAIN_SUFFIX>`)
  carries across all gated subdomains. Domain-level Proxy Provider
  blueprints (`manifests/idp/blueprints/99-proxy-{tekton,dbgate,seq}.yaml`)
  declare the per-app authorization.

  **Blueprints** declarative YAMLs at `manifests/idp/blueprints/` are
  mounted via ConfigMap at `/blueprints/local`; Authentik's worker
  auto-applies on every startup (idempotent). UI changes to blueprint-
  managed objects get re-overwritten on reconciliation — make changes
  to the YAML files in git, not the UI.

  **Traefik cross-namespace flag**: required because IdP Middleware lives
  in `idp` ns but every gated app Ingress is in its own namespace. The
  flag `--providers.kubernetescrd.allowCrossNamespace=true` is patched
  onto the Traefik DaemonSet by `configure_traefik_addon()` in
  `lib/install-microk8s.sh` (idempotent, runs in --install-microk8s).

- **All four setup-kubernetes apps use Traefik `IngressRoute`** (CRD),
  NOT k8s `Ingress` with annotations. IdP, ArgoCD, Headlamp, Vault each
  ship a `manifests/<app>/ingressroute.yaml` with an explicit
  `Certificate` CR (cert-manager doesn't auto-annotate IngressRoute).
  The chart-bundled Ingress is disabled where applicable (e.g.
  `server.ingress.enabled: false` in ArgoCD values).
- **PipelineRun retention**: every webhook-spawned PipelineRun carries
  `spec.ttlSecondsAfterFinished: 604800` (7 days), set in
  `apps/image-builder/templates/triggertemplate.yaml`. Manual PRs from
  `apps/image-builder/examples/pipelinerun-manual.yaml` carry the same
  field. K8s' built-in TTL controller (same one that handles Jobs)
  prunes the PR + child TaskRuns + pods after the window. To extend or
  per-status-retain, switch to a TektonPruner CRD (separate operator,
  not currently installed).
- **trivy-scan emits TaskRun results**: `apps/image-builder/templates/
  tasks/trivy-scan.yaml` runs trivy twice — once with `--format json
  --exit-code 0` to extract CVE counts (jq, `--format json` output to
  /tmp), once with `--format table --exit-code 1` for the gate + step
  logs. Three results emitted (`cve-critical`, `cve-high`, `cve-summary`)
  visible in Tekton Dashboard's PR detail panel at-a-glance. Don't move
  the result-writing AFTER the gating pass — gate exits non-zero and
  Tekton wouldn't capture the results.
- **MicroK8s built-in `registry` addon is disabled**: the snap's HTTP-only
  `:32000` registry is superseded by the GitOps-managed Zot above. The
  cleanup happens via `DISABLED_ADDONS=("registry")` in
  `setup-kubernetes/configs/config.<env>` consumed by
  `disable_addons()` in `lib/install-microk8s.sh`. Idempotent + no-op when
  the array is empty (existing test/prod hosts that never ran with the
  addon enabled). Add new names here if other snap defaults need cleanup.
- **image-builder git-clone uses HTTPS+PAT only**: no SSH anywhere. The
  `git-clone` Tekton Task envFroms a Secret `image-builder-git-https`
  (materialized by ESO from Vault path `secret/<env>/app/image-builder`,
  key `gitcredentials`) that contains a multi-line git-credentials-store
  file — one `https://<user>:<pat>@<host>` per provider. The step
  exports `GITCREDENTIALS` from envFrom, writes it to `~/.git-credentials`,
  and points git at it via `credential.helper=store`. Username
  conventions: `pat` for Azure DevOps, `oauth2` for GitHub, `x-token-auth`
  for Bitbucket. TriggerBindings emit HTTPS URLs from webhook payloads
  (`body.repository.clone_url` for GitHub, `body.resource.repository.remoteUrl`
  for Azure DevOps, composed `https://bitbucket.org/<full_name>.git` for
  Bitbucket). The old SSH-based pattern with `IMAGE_BUILDER_ID_RSA` +
  `IMAGE_BUILDER_KNOWN_HOSTS` was removed during the May 2026 migration
  — don't reintroduce. Rotate PATs by editing the single
  `IMAGE_BUILDER_GIT_CREDENTIALS` heredoc in `configs/secrets.<env>` and
  re-running `--seed-vault`.
- **image-builder push topology**: `pipeline.registry` is rendered from
  `.Values.global.domain` via Helm `tpl` at every chart-render —
  `apps/image-builder/values-common.yaml` has the literal
  `'zot.dev.{{ .Values.global.domain }}'`. The buildah-build-push and
  trivy-scan tasks both `tpl`-render this on the Pipeline param default,
  and `envFrom: secretRef` load `REGISTRY_USERNAME` / `REGISTRY_PASSWORD`
  from the `image-builder-registry-push` Secret materialized by ESO from
  Vault path `<env>/app/registry` (properties `push-user` + `push-password`).
  Buildah does `buildah login` before bud/push; Trivy re-exports those
  vars as `TRIVY_USERNAME` / `TRIVY_PASSWORD` (its built-in env names).
  Don't put `--tls-verify=false` or `--insecure` back — Zot has a real LE
  cert.
- **Pull-from-Zot is on-demand per consumer namespace**: existing apps
  (mongodb / postgresql / redis / postfix / seq / dbgate / observability)
  pull from public registries (docker.io / bitnamicharts / etc.) and do
  NOT carry an `acr-secret` chart dep. When a new workload pulls a
  `zot.dev.<DOMAIN_SUFFIX>/...` image, add `charts/acr-secret/` (aliased
  `acr-secret`) to its `Chart.yaml`, set `vaultPath: <env>/app/registry`
  + `property: pull-dockerconfigjson` in values, and reference the
  resulting Secret in the workload's `imagePullSecrets:`. The Vault entry
  is already populated on every cluster by the unified secrets-seed file;
  re-running `--seed-vault` after a namespace name change picks up the
  new bound_service_account_namespaces entry.
- **ArgoCD Image Updater is platform-tier, OPT-IN per app**: installed by
  `setup-kubernetes/lib/deploy-image-updater.sh` (Helm release
  `argocd-image-updater` in the `argocd` namespace, alongside ArgoCD
  itself — same chicken-egg reason as Authentik / Vault). Dispatcher flag
  `--deploy-image-updater`, last in the `--deploy-all` chain. Needs
  `IMAGE_BUILDER_GIT_CREDENTIALS` and `REGISTRY_PULL_USER` +
  `REGISTRY_PULL_PASSWORD` from `configs/secrets.<env>` — those are reused
  (no new secret rotation surface). Per-app annotation block syntax lives
  under "When you change the GitOps tree" below; only apps that consume
  Zot-built images add the `imageUpdater:` field. Apps pinning upstream
  Bitnami / Grafana / public-registry versions stay manual (default).

## Pre-flight requirements the script cannot fix

Before `--deploy-all`, the user must have done two things outside the
script. The script now fails fast on the first one with the host's detected
public IPv4:

1. **DNS A records** for `*.<env>.<DOMAIN_SUFFIX>` → host's public IPv4.
2. **Inbound port 80** from the public internet reachable on the host (for
   cert-manager's HTTP-01 challenge).

If a user reports certs not issuing, vault not initializing, or
`*-<env>.txt` saying "Initialization failed", check these two first
before suspecting the cluster/OS. See project memory
`dont-assume-os-diff-first`.

For the GitOps tree, an additional pre-flight applies:

3. **`build.<env>.<DOMAIN_SUFFIX>`** — needed by the image-builder
   EventListener Ingress (Phase A: DEV only). Must resolve to the host's
   public IPv4 same as the others.
4. **`tekton.dev.<DOMAIN_SUFFIX>`** — DEV-only Tekton Dashboard hostname.
   Required for the LE HTTP-01 cert-manager challenge on first deploy.
5. **`idp.<env>.<DOMAIN_SUFFIX>`** — platform Identity Provider
   (Authentik) installed by setup-kubernetes. Every UI without native
   OIDC (Tekton Dashboard, dbgate, Seq) and every OIDC client app
   (ArgoCD, Grafana, Headlamp, Vault) redirects users here for sign-in.
   LE cert. Must resolve before `--deploy-idp` runs.
6. **`zot.dev.<DOMAIN_SUFFIX>`** — DEV-only, pointing at the DEV host's
   public IPv4. Serves both the OCI distribution API + Zot's bundled
   web UI from a single hostname. Public-internet access is required
   so test/prod clusters can pull images. Inside the DEV cluster
   itself, CoreDNS has a rewrite (`apps/coredns/values-dev.yaml`
   `extraRewrites`) that points zot.dev at the Traefik service for
   in-cluster traffic; this is invisible to external clients.
7. **Vault data + auth config**: handled by `setup-kubernetes.sh
   --<env> --seed-vault`. This step is built into the installer now
   (`lib/seed-vault.sh`):
   - sources `configs/secrets.<env>` (gitignored per-host file with the
     real secret values + the `VAULT_SCHEMA` array that maps shell
     variables → Vault paths/keys)
   - mounts `kv-v2` at `secret/`, enables `kubernetes` auth, writes the
     `external-secrets` policy + role with
     `bound_service_account_namespaces` = all app namespaces
   - writes one KV-v2 entry per `(category, name)` tuple at
     `secret/<env>/<category>/<name>`. Re-runnable: each call creates
     a new KV-v2 version, latest wins.

   Two categories in use:
   - `app`     — workload secrets ESO reads via per-namespace
                 SecretStore (mongodb, postgresql, postfix, seq, dbgate,
                 observability, image-builder)
   - `system`  — control-plane creds for humans/automation (argocd
                 admin-password, kube dashboard-token, vault root-token
                 + 5 separate unseal-key-1..5 entries). Not read by ESO;
                 in Vault purely for retrieval.

   Schema format in `configs/secrets.{example,<env>}` is 4-field:
       `<SHELL_VAR>|<category>|<name>|<vault-key>`
   3-field legacy rows still parse with `category=app` defaulted.

   **Per-host drift**: edits to checked-in `secrets.example` (template)
   don't propagate to per-host `secrets.<env>` files. When the schema
   grows (e.g. new `DBGATE_ADMIN_PASSWORD` key added 2026-05-14), each
   host's `secrets.<env>` must be hand-aligned + `--seed-vault` re-run.

## When something fails

> "If you hit a real failure (not a network blip), DESCRIBE what you see
> before changing anything."

This is the user's rule. Read live state (`microk8s kubectl get …`,
`dig @1.1.1.1`, `curl` from the host's perspective) and report the actual
chain of cause and effect before proposing fixes. Especially:

- The script's `wait_for_certificate_ready` only `log_warn`s on timeout —
  it does not return an error code. A "successful" deploy run can leave
  certs Not Ready and Vault uninitialized.
- `save_credential()` always writes the file even on failure paths.
  Presence of `~/secrets/<app>-<env>.txt` does not mean credentials inside
  are real. Read the file to be sure.
- ArgoCD's "Sync OK" only means manifests applied — it does NOT mean pods
  are Ready, nor that ESO has materialized the Secrets the pods reference.
  Cross-check with `microk8s kubectl -n <ns> get pods,externalsecrets`.

## Cluster access without sudo

The user is in the `microk8s` group, so you can read live cluster state via
the wrapper alias: `microk8s kubectl …`, `microk8s helm3 …`. Use these for
diagnostics — they don't require an interactive `sudo` prompt. Sudo is
only needed for write operations the install script itself does.

## Pushing changes

- Remote: `https://github.com/kartalbas/setup-ubuntu-kubernetes.git`
- Branch: `main`.
- Both the 26.04 Linux dev box and the Windows workstation have HTTPS
  credential caching set up (`credential.helper=store`). Commits + pushes
  work from either host without further setup.
- When you commit, set author identity per-command (not via `git config`):
  ```bash
  git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' commit -m '…'
  ```
- For commits via the Bash tool, pass the message as a heredoc to preserve
  formatting:
  ```bash
  git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' commit -m "$(cat <<'EOF'
  Summary line

  Body paragraph.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
- After pushing from a host that DOES have auth, always confirm origin is in
  sync with `git fetch origin && git log --oneline -3` and
  `git rev-list --left-right --count origin/main...HEAD` (expect `0 0`).

## When you change scripts

Push any fix to `main` so both hosts can pull it (user's standing instruction).
Make changes **additive and idempotent**: on a clean install they should be a
no-op; on a partial/broken state they should converge it to healthy. The two
most recent examples to model:

- `check_ingress_dns_resolves()` — fails fast pre-deploy if DNS is missing,
  with the host's public IPv4 in the error message. Never silently waits.
- `deploy_vault()` — when the Helm release exists, skip only the helm
  install step but still run the init check (guarded by an exec-ability
  probe on `vault-0`). Preserve an existing `vault-<env>.txt` instead of
  clobbering it with a placeholder.

Always run `bash -n setup-kubernetes/setup-kubernetes.sh` after edits.

## When you change the GitOps tree

Same idempotency rule. Specific patterns to model:

- **Adding a new app** — drop `apps/<name>/` following any existing app's
  Chart.yaml + values + templates structure, then append one element to
  every `argocd/<env>/apps/applicationset.yaml` list. No new ArgoCD
  Application file per app — the ApplicationSet generates them.
- **Auto-tag-bump for a Zot-built image** — if the new app consumes an
  image pushed by `apps/image-builder/` to Zot, add an `imageUpdater:`
  block to its ApplicationSet entry to have the platform's Image Updater
  controller (installed by `setup-kubernetes/lib/deploy-image-updater.sh`,
  living in the `argocd` namespace) auto-commit tag bumps back to
  `apps/<name>/values-<env>.yaml`. Example:
  ```yaml
  - name: fleet
    syncWave: "40"
    namespace: fleet
    prune: "true"
    createNamespace: "true"
    specialOptions: ""
    imageUpdater:
      images:
        - alias: backend
          repository: zot.dev.digitaplatform.com/fleet-backend
          helmImageName: images.backend.repository
          helmImageTag: images.backend.tag
        - alias: frontend
          repository: zot.dev.digitaplatform.com/fleet-frontend
          helmImageName: images.frontend.repository
          helmImageTag: images.frontend.tag
  ```
  Apps without an `imageUpdater:` block are NOT watched (default opt-in).
  Apps that pin upstream Bitnami / Grafana / public-registry versions
  (mongodb / postgresql / redis / observability / etc.) MUST NOT add the
  block — auto-update would pull breaking changes from upstream.
- **Adding a new platform constant** — add it under `global:` in
  `platform/values-common.yaml` (or per-env if env-specific). Reference
  via `.Values.global.<key>` in chart templates. For upstream charts that
  don't `tpl` their values (Bitnami / kube-prometheus-stack subchart
  blocks, datalust seq), document the manual sync in the value's comment.
- **Adding a new library chart** — drop `charts/<name>/` following an
  existing chart's pattern; reference it as a Helm dep with
  `repository: file://../../charts/<name>` from consumer Chart.yamls.
- **Adding a new secret to Vault** — add a shell variable to
  `configs/secrets.example` (template) AND add a row to its
  `VAULT_SCHEMA` array. Each per-host `secrets.<env>` must mirror both
  changes by hand (gitignored, not auto-updated).
- **Always `helm template`** the affected chart locally before pushing:
  ```bash
  helm dependency build apps/<app>
  helm template <name> apps/<app> \
    -f platform/values-common.yaml \
    -f platform/values-<env>.yaml \
    -f apps/<app>/values-common.yaml \
    -f apps/<app>/values-<env>.yaml
  ```
- **YAML linter warnings** on ApplicationSet templates are expected (Go
  template syntax inside YAML structure trips the linter). The
  `templatePatch:` field intentionally lives inside a `|` block scalar
  for this reason — keep new conditional logic inside `templatePatch`.

## Common drift causes (defensive YAML)

K8s' API server normalizes / strips certain fields on apply. If a chart
emits the un-normalized form, ArgoCD shows OutOfSync forever, even after
successful syncs. Patterns to follow proactively:

- **CPU as Quantity**: write `cpu: "2"` (string), not `cpu: 2` (integer).
  The API stores Quantity as a string; integers get string-cast on
  persistence. Memory values always carry a suffix (`Gi`/`Mi`) so they're
  already string-typed.
- **`ExternalSecret.spec.data[].remoteRef`**: emit every defaulted field
  explicitly (`conversionStrategy: Default`, `decodingStrategy: None`,
  `metadataPolicy: None`, **`nullBytePolicy: Ignore`**). Current ESO chart
  (`oci://ghcr.io/external-secrets/charts/external-secrets:2.4.1`,
  operator v2.4.1) has `nullBytePolicy` with default `Ignore`; without
  explicit emit, live has it but desired doesn't → drift. (We removed it
  once when ESO's legacy v0.20.x CRD didn't have the field — that
  direction is now wrong. Always emit on every current and future
  release; the field is part of the stable spec.)
- **Tekton Task step**: use `computeResources:` not `resources:`. K8s
  silently strips the old name in v1, your limits get lost.
- **CRDs over the annotation limit**: kube-prometheus-stack PrometheusRule
  CRD + ESO SecretStore CRD both exceed the 262 KB
  `kubectl.kubernetes.io/last-applied-configuration` annotation cap. Apps
  installing these MUST have `ServerSideApply=true` in their sync options.
  Pattern in `argocd/<env>/apps/applicationset.yaml`: `specialOptions:
  "observability"` / `"external-secrets"` trigger this via `templatePatch`.

## ArgoCD `comparedTo_revision: null` quirk on multi-source Apps

The ApplicationSet's Application spec has two `spec.sources` entries (one
`ref: values`, one chart source). Sometimes ArgoCD's compare tracker
records `comparedTo.source.repoURL: ""` and the diff never re-renders
after a Hard Refresh. Symptoms: live + desired match per `kubectl get`,
but UI shows OutOfSync. Fix: **delete the Application** — the AppSet
re-creates it within seconds, with a fresh compare cache. Not a workload
delete, just the `Application` CR in `argocd` namespace. The pattern is
inert in `apps/observability/` (`ServerSideApply=true` + `ignoreDifferences`
in the AppSet templatePatch) but elsewhere occasionally bites.

## Project memory

Stored at `~/.claude/projects/-home-server-repos-setup-ubuntu-kubernetes/memory/`
on the Linux dev box, mirrored at
`C:\Users\mkadm\.claude\projects\D--repos-kartalbas-setup-ubuntu-kubernetes\memory\`
on Windows:

- `host-26-04-dev-box` — IPs, OS, storage path, domain for the Linux dev box.
- `dont-assume-os-diff-first` — when 24.04 works and 26.04 doesn't, check
  DNS / port-80 / configs before kernel / CNI.

Update or add to these when you learn new durable facts about the project
or environment. Especially worth tracking:

- Per-host inventory of which envs have been GitOps-bootstrapped (i.e. which
  hosts have run the `argocd/argo-manage.sh --env <env> --bootstrap` step).
- Per-host `--seed-vault` status (when Vault was last re-seeded with the
  latest `configs/secrets.<env>` schema).
