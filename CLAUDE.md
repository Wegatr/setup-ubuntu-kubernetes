# CLAUDE.md

Guidance for Claude Code sessions in this repo. Read once at the start of a
session and treat the constraints below as durable instructions.

## What this repo does

Automated, idempotent installer for a **MicroK8s 1.35** Kubernetes cluster on
Ubuntu (22.04 / 24.04 / 26.04), plus Helm-managed infrastructure apps:
**Headlamp** dashboard, **ArgoCD**, and **HashiCorp Vault**. See `README.md`
for the user-facing docs — don't repeat their content here.

## Layout

- `README.md` — user docs.
- `CLAUDE.md` — this file.
- `setup-kubernetes/` — all scripts, manifests, configs. Run scripts from
  inside here. `SCRIPT_DIR` is computed dynamically so paths resolve correctly
  regardless of repo nesting.

## Two-host context (important)

This repo is shared between **at least two hosts** that the user operates:

- A **26.04 dev box** — this machine (see project memory `host-26-04-dev-box`).
- A **24.04 sister host** — separately managed, you don't have access.

Each host keeps its own `setup-kubernetes/configs/config.<env>` (gitignored).
Values like `STORAGE_PATH` differ between them intentionally (e.g. `/data` on
26.04, `/mnt/data` on 24.04). **Never unify configs**; each is per-host.

**Any change you push to `main` runs on both hosts** the next time the user
`git pull`s. Don't merge OS-specific fixes that would regress the working
host. Existing 26.04 workarounds in the script
(`configure_kube_proxy_nftables`, `align_calico_backend`,
`fix_coredns_upstream`) are written to be idempotent and no-op on 24.04 too —
follow that pattern.

## Hardcoded constraints — DO NOT change without asking

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

## Cluster access without sudo

The user is in the `microk8s` group, so you can read live cluster state via
the wrapper alias: `microk8s kubectl …`, `microk8s helm3 …`. Use these for
diagnostics — they don't require an interactive `sudo` prompt. Sudo is
only needed for write operations the install script itself does.

## Pushing changes

- Remote: `https://github.com/kartalbas/setup-ubuntu-kubernetes.git`
- This 26.04 host has no GitHub auth configured (no `gh` CLI, no SSH
  private keys, no credential helper). Don't try to install or generate
  credentials autonomously.
- When you commit, set author identity per-command (not via `git config`):
  ```bash
  git -c user.email='kartalbas@gmail.com' -c user.name='Mehmet Kartalbas' commit -m '…'
  ```
- After committing, tell the user to run `git push origin main` themselves
  (or with `!git push origin main` in this session). Always confirm origin
  is in sync afterwards with `git fetch origin && git log --oneline -3`.

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

## Project memory

Stored at `~/.claude/projects/-home-server-repos-setup-ubuntu-kubernetes/memory/`:

- `host-26-04-dev-box` — IPs, OS, storage path, domain for this machine.
- `dont-assume-os-diff-first` — when 24.04 works and 26.04 doesn't, check
  DNS/port-80/configs before kernel/CNI.

Update or add to these when you learn new durable facts about the project
or environment.
