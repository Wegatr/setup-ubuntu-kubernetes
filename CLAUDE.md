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
                         secret-store / monitoring. Plus charts/common
                         (type: library) — the single copy of the shared
                         named templates (common.name / fullname / chart /
                         labels / selectorLabels) every library chart calls.
                         CONSUMPTION RULE: `common` must be declared as a
                         dependency of the consuming APP chart (not of the
                         library charts) because Helm doesn't vendor nested
                         file:// deps; defines are release-global, so the
                         app-level dep makes common.* visible to all its
                         library subcharts. Forgetting it fails loudly at
                         render ("no template common.labels").

apps/                    Per-app umbrella charts — one dir per app, each with
                         Chart.yaml + values-{common,dev,test,prod}.yaml +
                         templates/. Apps: coredns, mongodb, postgresql,
                         redis, objectstore (Garage S3 + Filestash UI),
                         postfix, seq, dbgate, observability, tekton,
                         registry, image-builder.

argocd/{dev,test,prod}/  Per-env GitOps bootstrap: root-app.yaml (App-of-Apps
                         entry point) + apps/applicationset.yaml (single
                         ApplicationSet that generates one Application per
                         app, with sync waves, prune/createNamespace flags,
                         and a templatePatch for per-app conditionals) +
                         apps/projects.yaml (AppProjects grouping the
                         platform's OWN apps by blast-radius tier:
                         core/data/services/observability/cicd) +
                         apps/tenants.yaml (one platform-owned AppProject per
                         external tenant app, e.g. fleet). cicd + tenant
                         projects exist on dev only.
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
| Garage | `v2.3.0` | `apps/objectstore/Chart.yaml` appVersion + `values-common.yaml` `garage.image.tag` | Two places — must match. v2.3 is the minimum: `--single-node` + `--default-bucket` provisioning flags appeared there. |
| Filestash | `latest@sha256:03990d…` (digest pin, 2026-06-11) | `apps/objectstore/values-common.yaml` `filestash.image.tag` | Upstream publishes NO version tags — only a moving `latest`. Refresh procedure in `apps/objectstore/README.md`. |
| External-Secrets chart + operator | `2.4.1` / `v2.4.1` | `apps/external-secrets/Chart.yaml` deps[external-secrets].version | Operator + chart numbers track 1:1 from v2.x onward. |
| Tekton Pipelines | `v1.12.0` | `apps/tekton/values-common.yaml` `release.pipelinesVersion` (informational) + vendored YAML in `templates/release-pipelines.yaml` | Refresh procedure in `apps/tekton/README.md`. |
| Tekton Triggers | `v0.35.0` | same place | |
| Tekton Interceptors | `v0.35.0` | same place | |
| Tekton Dashboard | `v0.69.0` | `apps/tekton/values-common.yaml` `release.dashboardVersion` (informational) + vendored YAML in `apps/tekton/templates/release-dashboard.yaml` | Gated on `.Values.dashboard.enabled` (DEV only). |
| Buildah (build image) | `quay.io/buildah/stable:v1.43.1` | `apps/image-builder/templates/tasks/buildah-build-push.yaml` step image | |
| Prometheus-community mongodb-exporter chart | `3.7.0` | `apps/mongodb/Chart.yaml` | |
| Prometheus-community redis-exporter chart | `6.5.0` | `apps/redis/Chart.yaml` | |
| Headlamp / ArgoCD / Vault Helm charts | (no pin — `helm install` latest at deploy time) | `setup-kubernetes/lib/deploy-{kube,argocd,vault}.sh` | Re-running `--deploy-<app>` after a chart release picks up the new version. |
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
- **`apps/seq` built-in login is OFF by design (ALL envs, declarative)**:
  `firstRunAdminPasswordSecret` was removed from
  `apps/seq/values-common.yaml` (2026-06-12) — without a first-run admin
  password a fresh Seq starts WITHOUT its own authentication, so the
  Authentik forwardAuth gate is the single login (dbgate pattern), and this
  survives PVC wipes / reinstalls. Don't re-add the block unless Seq-side
  user management is explicitly wanted (it creates a SECOND login).
  `SEQ_ADMIN_PASSWORD` stays in the Vault schema but is unused; shippers
  ingest with `SEQ_API_KEY` regardless. Existing instances that already
  HAVE auth enabled in their metastore keep it until disabled in the Seq UI
  once (or their PVC is recreated).
- **Deleting an ArgoCD Application cascades into its PVCs** (the
  resources-finalizer deletes ALL managed resources). seq-dev was deleted
  once on 2026-06-11 and its UNPROTECTED PVC — with all DEV log data — went
  with it. Only `apps/objectstore` PVCs carry
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false` so far. The
  CLAUDE.md-documented "delete the Application to fix the comparedTo quirk"
  trick is therefore SAFE only for apps whose data lives in
  StatefulSet volumeClaimTemplates (mongodb/postgresql/redis) or protected
  PVCs — NOT for seq/dbgate. Prefer Hard Refresh; protect more PVCs via
  the pvc chart's `annotations` passthrough where charts allow it.
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
- **`apps/objectstore/` (Garage S3 + Filestash) runs on ALL envs**, one
  combined app in the `objectstore` namespace, AppProject `data`, wave 10.
  - **Provisioning is declarative**: Garage v2.3 starts with
    `--single-node --default-bucket`; the layout, the `documents` bucket
    and ONE access key are auto-created from env vars
    (`GARAGE_DEFAULT_{BUCKET,ACCESS_KEY,SECRET_KEY}` + `GARAGE_RPC_SECRET`
    + `GARAGE_ADMIN_TOKEN`, ESO-materialized from Vault
    `<env>/app/objectstore`). NO provisioning Job — don't add one.
  - **One shared key** for the Node.js consumers AND Filestash (deliberate;
    split via `garage key import` only if auditing demands it).
  - **db_engine = sqlite, NOT lmdb** (upstream default): lmdb is documented
    corruption-prone on unclean shutdowns; single-node rf=1 has no replica
    to rebuild from. Don't "fix" it back to lmdb.
  - **replication_factor = 1 only** — rf>1 needs multi-node + StatefulSet +
    manual `garage layout`, unsupported on these single-node clusters.
  - **PVCs (`garage-data`, `filestash-state`) carry
    `argocd.argoproj.io/sync-options: Prune=false,Delete=false`** (via the
    optional `pvc.annotations` passthrough added to `charts/pvc/`).
    Removing the app NEVER deletes data; deletion is an explicit
    `kubectl delete pvc`. Don't strip the annotations.
  - **Stable raw Services** `garage-s3` (:3900) + `garage-admin`
    (:3903 metrics) in `apps/objectstore/templates/garage-services.yaml`
    replace the deployment-chart Service (disabled) — the Filestash seed
    config.json is rendered by ESO templating which can't see Helm values,
    so it needs an env-independent DNS name. Don't re-enable the lib
    Service or rename these.
  - **Filestash image is digest-pinned** (`latest@sha256:…`) because
    upstream has no version tags. Its first-boot config.json (admin bcrypt
    hash + preconfigured S3 connection) is seeded by a `/bin/sh` command
    wrapper that copies from the ESO-rendered `filestash-seed` Secret ONLY
    when the file is absent — UI changes persist on the PVC and survive
    re-syncs. Bucket name `documents` + region `garage` are hardcoded in
    BOTH the garage env block and the ESO template (ESO can't read Helm
    values) — keep in sync manually.
  - **Filestash UI is IdP-gated** (`idp-forwardauth@kubernetescrd`, dbgate
    pattern). IdP-side: `manifests/idp/blueprints/99-proxy-filestash.yaml`
    + the filestash entries in `99-z-outpost-bindings.yaml` + the
    "Filestash Forward Auth" row in deploy-idp.sh's `expected_names` —
    three touchpoints, keep them consistent; re-run `--deploy-idp` after
    changes.
  - **CoreDNS rewrite** `s3.<env>.<domain>` → Traefik exists in every env's
    `apps/coredns/values-<env>.yaml` (zot hairpin pattern).
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
      (`idp → kube → argocd → vault → seed-vault`).
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
- **image-builder ServiceAccount split**: the EventListener pod runs as
  `eventlistener-sa` (carries the Tekton Triggers ClusterRole RoleBindings,
  incl. namespace Secret read for webhook HMAC interceptor secretRefs);
  PipelineRun pods run as `pipeline-sa`, which deliberately has NO API
  access to Secrets/ConfigMaps — steps consume credentials via envFrom /
  volume mounts only (kubelet needs no RBAC for that). Tenant pipelines
  execute under pipeline-sa too, so this split is the cross-tenant
  isolation boundary inside the image-builder namespace. Don't re-merge
  the two SAs and don't point PipelineRuns at eventlistener-sa.
- **image-builder push topology**: `pipeline.registry` is rendered from
  `.Values.global.domain` via Helm `tpl` at every chart-render —
  `apps/image-builder/values-common.yaml` has the literal
  `'zot.dev.{{ .Values.global.domain }}'`. The buildah-build-push task
  `tpl`-renders this on the Pipeline param default, and `envFrom: secretRef`
  loads `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` from the
  `image-builder-registry-push` Secret materialized by ESO from Vault path
  `<env>/app/registry` (properties `push-user` + `push-password`). Buildah
  does `buildah login` before bud/push. Don't put `--tls-verify=false` back
  — Zot has a real LE cert.
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
- **App-owned build pipelines (the contract)**: the platform's
  `apps/image-builder/` is intentionally minimal — it provides ONLY:
    - the EventListener + Trigger plumbing (per-provider webhook intake)
    - a 3-Task shared library in the `image-builder` namespace:
      `git-clone`, `credential-scan`, `buildah-build-push`

  That's all. Everything app-specific — version computation, tag format,
  write-back target, commit message convention — lives INLINE in each
  app's own Pipeline via `taskSpec`. Don't add opinion-y "helper" Tasks
  to the platform library (no `generate-image-tag`, no `yq-git-bump`,
  no `logging-summary`); they belong in the app's pipeline where the
  app team can choose semver / calver / semantic-release / whatever.

  Pipelines themselves live in each app's source repo at
  `deploy/pipelines/<image-name>.yaml` and are deployed to the
  `image-builder` namespace by the app's own ArgoCD Application
  (multi-source: chart + pipelines from the same repo).

  Routing: the EventListener spawns `PipelineRun` with
  `pipelineRef.name: $(image-name)`. `image-name` comes from the
  `X-Image-Name` header (or repo name fallback). So a push to
  fleet-tracker with `X-Image-Name: fleet-backend` resolves to the
  Pipeline `fleet-backend` in `image-builder` ns — which fleet-tracker
  shipped via `deploy/pipelines/fleet-backend.yaml`. App pipelines
  reference the 3 platform Tasks via `cluster` resolver; tasks
  app-specific go inline in the Pipeline file.

  **Anti-loop**: app pipelines push commits back to their own source
  repo (version bumps + tag bumps). Without protection, those commits
  re-trigger the webhook → infinite build loop. Mitigation: the
  bump-commit author is `image-builder@platform`, and the trigger CEL
  filter on each provider rejects pushes where every commit is from
  that author. Pushes containing ≥1 human commit still build. The
  filter lives in:
    - `apps/image-builder/templates/triggers/azuredevops.yaml`
      uses `body.resource.commits[].author.email`
    - `apps/image-builder/templates/triggers/github.yaml`
      uses `body.commits[].author.email`
    - `apps/image-builder/templates/triggers/bitbucket.yaml`
      uses `body.push.changes[].commits[].author.raw` (Bitbucket exposes
      author as `"Name <email>"` raw string)

  Onboarding a new app:
  1. App repo ships `deploy/pipelines/<image-name>.yaml` per build target
     with inline `taskSpec` for the app-specific bits.
  2. App's ArgoCD Application uses multi-source: `deploy/chart/` + 
     `deploy/pipelines/`. Pipelines have explicit `metadata.namespace:
     image-builder`; ArgoCD honors it.
  3. Webhook subscription on the provider side sets
     `X-Image-Name: <image-name>` matching the Pipeline metadata.name.
  4. Image-builder PAT must have Code: Read & Write on the app's repo
     (for the pipeline's commit-push step). Add the credential line to
     the `IMAGE_BUILDER_GIT_CREDENTIALS` heredoc in
     `configs/secrets.<env>` and re-run `--seed-vault`.
  5. Pipeline's commit-push step MUST set git author to
     `image-builder@platform` for the anti-loop filter to work.

  See `/home/server/repos/fleet-tracker/deploy/pipelines/` for working
  examples. fleet-tracker is the reference implementation; inline
  `bump-version` (jq + package.json patch bump) + `commit-push` (yq +
  git push with rebase-retry).

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
7. **`s3.<env>.<DOMAIN_SUFFIX>` + `files.<env>.<DOMAIN_SUFFIX>`** — the
   Garage S3 API and the Filestash UI (apps/objectstore, every env). Both
   need LE certs via HTTP-01 on first sync; a wildcard
   `*.<env>.<DOMAIN_SUFFIX>` record covers them. CoreDNS rewrites
   s3.<env> onto Traefik for in-cluster clients (zot pattern).
8. **Vault data + auth config**: handled by `setup-kubernetes.sh
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

- `wait_for_certificate_ready` warns on timeout and the deploy CONTINUES
  (deliberate — one slow LE cert must not abort the bring-up), but every
  such timeout is recorded via `record_deploy_issue()` and replayed in a
  summary at the end of the run; the script then exits 1. So a zero exit
  code now really means "everything came up" — but mid-run output can
  still look successful while a cert is pending.
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
  every `argocd/<env>/apps/applicationset.yaml` list. If the app consumes
  any library chart that emits common.* labels (deployment / ingress /
  middleware / external-secret / pvc / configmap / cronjob / rbac /
  acr-secret), also add `charts/common` to the app's dependencies — see
  the consumption rule in the Layout section. No new ArgoCD
  Application file per app — the ApplicationSet generates them. Each element
  MUST carry a `project:` field naming one of the AppProjects in
  `apps/projects.yaml` (`core` / `data` / `services` / `observability` /
  `cicd`) — the template sets `project: "{{ .project }}"`, there is NO
  `default` fallback. Pick the tier by what the app deploys: data stores →
  `data`, support services → `services`, cluster-foundational (CRDs/RBAC,
  kube-system) → `core`, monitoring → `observability`, build plane (dev) →
  `cicd`.
- **AppProjects (blast-radius + multi-team boundary)** — generated apps are
  pinned to purpose-scoped AppProjects, never the wide-open `default`.
  `core` / `observability` / `cicd` whitelist the cluster-scoped kinds their
  charts actually ship (CRDs, ClusterRole/Binding, admission webhooks, Tekton
  `ClusterInterceptor`, `Namespace`); `data` / `services` have
  `clusterResourceWhitelist: []` (namespaced only — the real isolation win).
  `destinations` lists the exact namespaces each tier deploys to — INCLUDING
  `kube-system` for `observability` (kube-prometheus-stack's coredns/kubelet
  scrape Services) and `core` (coredns Corefile). When a chart starts emitting
  a new cluster-scoped kind or writes to a new namespace, the owning project
  must allow it or sync fails with `… is not permitted in project`. Always
  derive the list from the REAL rendered manifests (grep the vendored YAML /
  `helm template`), not assumptions — that gap is what caused the
  ClusterInterceptor + kube-system misses on first rollout.
- **Onboarding a tenant app (multi-team)** — the cluster hosts apps from
  multiple independent teams, each from its own repo (fleet is the first; see
  project memory `multi-team-tenant-argocd-projects`). Each tenant gets its
  OWN platform-owned AppProject in `argocd/<env>/apps/tenants.yaml`:
  `sourceRepos` pinned to that team's repo, `clusterResourceWhitelist: []`,
  and `destinations` either the app's explicit namespaces OR `namespace: '*'`
  for a team that self-services many of its own namespaces (the `'*'` widens
  NAMESPACE reach, NOT resource KIND — cluster isolation still holds via the
  empty cluster whitelist). The tenant's own Application(s) set
  `spec.project: <tenant>`. Defining the project platform-side is deliberate:
  a tenant must not be able to widen its own boundary. Also add the tenant's
  namespace(s) to `EXTERNAL_ESO_NAMESPACES` in `configs/config.<env>` +
  re-run `--seed-vault` (Vault ESO binding, separate from the project).
- **Auto-tag-bump for a Zot-built image** — not handled in this repo any
  more. App pipelines bump themselves: each app's
  `<repo>/deploy/pipelines/<image-name>.yaml` ends with a `yq-git-bump`
  Task call that commits the new tag back to the app's own values file.
  See the "App-owned build pipelines (the contract)" section under
  Hardcoded constraints above, and
  `/home/server/repos/fleet-tracker/deploy/pipelines/fleet-backend.yaml`
  as the reference implementation.
- **Adding a new platform constant** — add it under `global:` in
  `platform/values-common.yaml` (or per-env if env-specific). Reference
  via `.Values.global.<key>` in chart templates. For upstream charts that
  don't `tpl` their values (Bitnami / kube-prometheus-stack subchart
  blocks, datalust seq), document the manual sync in the value's comment.
- **Adding a new library chart** — drop `charts/<name>/` following an
  existing chart's pattern; reference it as a Helm dep with
  `repository: file://../../charts/<name>` from consumer Chart.yamls.
  Don't add a per-chart `_helpers.tpl` — call the shared `common.*`
  defines (charts/common) and rely on the consuming app declaring the
  `common` dependency.
- **Touching `argocd/<env>/`** — the three env trees are hand-maintained
  near-copies. After any edit, run `bash argocd/check-env-drift.sh`: it
  compares the trees structurally (comments stripped, env names
  normalized) and fails on any asymmetry beyond the documented dev-only
  extras (tekton / registry / image-builder apps, cicd project,
  tenants.yaml). Comment-only differences stay legal.
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
