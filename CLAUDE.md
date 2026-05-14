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

- A **26.04 dev box** — see project memory `host-26-04-dev-box`.
- A **24.04 sister host** — separately managed, you don't have access.
- A **Windows workstation** — where this Claude session is currently running
  (path `D:\repos\kartalbas\...`). Used for editing + committing; the
  installer scripts only run on the Ubuntu hosts.

Each Ubuntu host keeps its own `setup-kubernetes/configs/config.<env>`
(gitignored). Values like `STORAGE_PATH` differ between them intentionally
(e.g. `/data` on 26.04, `/mnt/data` on 24.04). **Never unify configs**;
each is per-host.

**Any change you push to `main` runs on both hosts** the next time the user
`git pull`s. Don't merge OS-specific fixes that would regress the working
host. Existing 26.04 workarounds in the script
(`configure_kube_proxy_nftables`, `align_calico_backend`,
`fix_coredns_upstream`) are written to be idempotent and no-op on 24.04 too —
follow that pattern.

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

- The `repoURL: https://to-your-repo-folder` and `targetRevision: master`
  placeholders in `argocd/<env>/root-app.yaml` and
  `argocd/<env>/apps/applicationset.yaml` **must be replaced** with the real
  repo URL + branch before any GitOps sync will work. The README documents
  the `sed` command. ArgoCD shows `ComparisonError` until this is done.
- The image-builder's `apps/tekton/` chart is intentionally minimal — the
  upstream Tekton release manifests are NOT vendored automatically. See
  `apps/tekton/README.md` for the `curl` commands that fetch them into
  `apps/tekton/templates/release-*.yaml`. Bumping Tekton versions is a
  manual refresh.
- `apps/image-builder/templates/triggers/azuredevops.yaml` does NOT validate
  the Basic-auth secret (CEL can only check header presence). Phase A
  ships with this limitation; see
  [`apps/image-builder/README.md`](apps/image-builder/README.md)
  "Security hardening" for the two clean fixes.
- `apps/dbgate/values-common.yaml` Ingress + connection FQDNs use Helm
  `tpl` to compose `gate.<env>.<domain>` and the database Service names
  (`mongodb-<env>-headless.mongodb.svc.cluster.local`, etc.) from platform
  globals — those expressions only render because the consuming charts
  (our `ingress` library; the `deployment` library after the `tpl` patch
  added in this repo) explicitly `tpl` those fields. Don't replace `tpl`
  with raw value rendering.
- Storage class centralization is **partial**: subchart values blocks
  (Bitnami mongodb / redis / postgresql / kube-prometheus-stack PVCs)
  intentionally omit `storageClass` so they fall back to either
  `global.storageClass` (when the chart honors Helm's global convention)
  or the cluster default — which on MicroK8s is `microk8s-hostpath` anyway,
  so the fallback always lands on the right thing. Don't add explicit
  `storageClass: microk8s-hostpath` back into subchart values blocks.

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
4. **Vault data** at `<env>/app/<name>` paths for every app that has an
   ExternalSecret (mongodb, postgresql, postfix, seq, dbgate, observability,
   image-builder). The platform won't sync cleanly until ESO can pull these.
5. **Vault role bound to app namespaces** — every app namespace needs to be
   in `bound_service_account_namespaces` on the `external-secrets` role.
   This is a user-side `setup-gitops` workflow, not the installer's job.

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
- The 26.04 Linux host has **no GitHub auth configured** (no `gh` CLI, no
  SSH private keys, no credential helper). Don't try to install or generate
  credentials autonomously from that host.
- The Windows workstation **does** have HTTPS credential caching set up
  (this session pushed `3685564` successfully). Commits + pushes are
  safe from there.
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
- **Adding a new platform constant** — add it under `global:` in
  `platform/values-common.yaml` (or per-env if env-specific). Reference
  via `.Values.global.<key>` in chart templates. For upstream charts that
  don't `tpl` their values (Bitnami / kube-prometheus-stack subchart
  blocks), document the manual sync in the value's comment.
- **Adding a new library chart** — drop `charts/<name>/` following an
  existing chart's pattern; reference it as a Helm dep with
  `repository: file://../../charts/<name>` from consumer Chart.yamls.
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

## Project memory

Stored at `~/.claude/projects/-home-server-repos-setup-ubuntu-kubernetes/memory/`
on the Linux dev box, mirrored at
`C:\Users\mkadm\.claude\projects\D--repos-kartalbas-setup-ubuntu-kubernetes\memory\`
on Windows (this session):

- `host-26-04-dev-box` — IPs, OS, storage path, domain for the Linux dev box.
- `dont-assume-os-diff-first` — when 24.04 works and 26.04 doesn't, check
  DNS / port-80 / configs before kernel / CNI.

Update or add to these when you learn new durable facts about the project
or environment. Especially worth adding:

- The Git remote URL once it's been substituted into the GitOps tree
  (current state: still using the `https://to-your-repo-folder` placeholder
  literally; see "Hardcoded constraints" above).
- Per-host inventory of which envs have been GitOps-bootstrapped (i.e. which
  hosts have run the `kubectl apply -f argocd/<env>/root-app.yaml` step).
