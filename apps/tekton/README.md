# apps/tekton/ — Tekton Pipelines + Triggers + Dashboard

This chart provides the **operator/CRDs** that `apps/image-builder/`
depends on, plus the optional **Tekton Dashboard** browser UI (DEV-only,
gated by `.Values.dashboard.enabled`). It is **not** a self-contained
Tekton install — community Helm charts lag the upstream Tekton release
cadence, so we vendor the upstream release YAML directly into
`templates/release-*.yaml` (four files: pipelines, triggers,
interceptors, dashboard).

The Dashboard adds a Pipeline-DAG view, PipelineRun list with drill-in,
step-by-step live-tail logs, a manual "Create PipelineRun" form, and
inline TaskRun results (e.g. trivy CVE counts). Lives at
`https://tekton.dev.<DOMAIN_SUFFIX>/`.

## Auth — handled by apps/login/, not here

There is **no per-app oauth2-proxy, no htpasswd Secret, no Vault entry**
in this chart any more. The Dashboard Ingress carries a single Traefik
annotation:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: login-forwardauth@kubernetescrd
```

That cross-namespace reference points at the `forwardauth` Middleware
materialized by `apps/login/`. Login once at
`https://login.dev.<DOMAIN_SUFFIX>/oauth2/sign_in` → apex cookie set
on `.dev.<DOMAIN_SUFFIX>` → recognized here automatically. WebSocket
upgrades for live log-tail work because Traefik runs forwardAuth BEFORE
the WS handshake; cookies travel same-origin on the actual WS upgrade.

If `login-forwardauth@kubernetescrd` is missing (e.g. apps/login wasn't
applied or its sync wave is still pending), Traefik treats the
annotation as no-op and the Dashboard is OPEN. ArgoCD sync waves
(login=2, tekton=3) ensure the Middleware exists by the time Tekton
syncs, but be aware on first-time bootstraps where waves race.

## One-time setup (per cluster)

1. **Download the vendored release manifests** (run from the repo root,
   commit the results):

   ```bash
   PIPELINES_VERSION=v1.12.0
   TRIGGERS_VERSION=v0.35.0
   INTERCEPTORS_VERSION=v0.35.0
   DASHBOARD_VERSION=v0.68.0

   curl -fsSL -o apps/tekton/templates/release-pipelines.yaml \
     "https://github.com/tektoncd/pipeline/releases/download/${PIPELINES_VERSION}/release.yaml"

   curl -fsSL -o apps/tekton/templates/release-triggers.yaml \
     "https://github.com/tektoncd/triggers/releases/download/${TRIGGERS_VERSION}/release.yaml"

   curl -fsSL -o apps/tekton/templates/release-interceptors.yaml \
     "https://github.com/tektoncd/triggers/releases/download/${INTERCEPTORS_VERSION}/interceptors.yaml"

   # Dashboard uses the -full variant deliberately: ships --read-only=false
   # so operators can kick off manual PipelineRuns from the browser. The
   # `release.yaml` variant (without -full) is read-only and hides the
   # Run button.
   curl -fsSL -o apps/tekton/templates/release-dashboard.yaml \
     "https://github.com/tektoncd/dashboard/releases/download/${DASHBOARD_VERSION}/release-full.yaml"

   # K8s 1.22+ silently strips `preserveUnknownFields: false` on apply —
   # leaving it in the vendored YAML causes permanent ArgoCD drift. Strip it.
   sed -i '/preserveUnknownFields: false/d' \
     apps/tekton/templates/release-pipelines.yaml \
     apps/tekton/templates/release-triggers.yaml \
     apps/tekton/templates/release-interceptors.yaml \
     apps/tekton/templates/release-dashboard.yaml

   # Wrap the dashboard YAML in the Helm gate so TEST/PROD (where
   # dashboard.enabled is false) skip rendering it.
   {
     echo '{{- if .Values.dashboard.enabled }}'
     echo '{{- /*'
     echo 'Tekton Dashboard upstream release-full.yaml vendored verbatim.'
     echo 'Gated on .Values.dashboard.enabled — DEV only.'
     echo '*/ -}}'
     cat apps/tekton/templates/release-dashboard.yaml
     echo '{{- end }}'
   } > apps/tekton/templates/release-dashboard.yaml.new
   mv apps/tekton/templates/release-dashboard.yaml.new \
      apps/tekton/templates/release-dashboard.yaml

   # Disable the affinity-assistant's "coschedule by workspaces" default.
   # Our image-build pipeline uses TWO RWO PVCs in the trivy task (the per-run
   # source workspace + the persistent trivy-db-cache); with the default the
   # affinity-assistant errors with "more than one PersistentVolumeClaim is
   # bound". On single-node MicroK8s the affinity-assistant brings no benefit
   # anyway — pod placement is unambiguous.
   sed -i 's/^  coschedule: "workspaces"/  coschedule: "disabled"/' \
     apps/tekton/templates/release-pipelines.yaml
   ```

   Bump the four versions in `values-common.yaml` `release:` block so the
   chart description stays in sync. Re-run the curl + sed block to refresh.

   **Note:** Tekton release artifacts moved from `storage.googleapis.com/
   tekton-releases/` to `github.com/tektoncd/*/releases/download/` somewhere
   between v0.30 and v1.10. Both URLs returned 200 for years; the GCS one
   now 404s for newer versions.

2. **Commit + push.** ArgoCD's `tekton-dev` Application syncs at wave 3,
   applying the operator manifests; `login-dev` at wave 2 ensures the
   forwardAuth Middleware exists before this Ingress renders.

3. **DNS** — `tekton.dev.<DOMAIN_SUFFIX>` A-record → cluster's public
   IPv4. Cert-manager issues an LE cert on first reconcile.

## Verify install

```bash
kubectl -n tekton get pods
kubectl -n tekton get crds | grep tekton.dev
kubectl -n tekton get ingress tekton-dev-ingress -o jsonpath='{.metadata.annotations}'  # check the forwardAuth annotation is present
tkn version       # client + server
```

Browser → `https://tekton.dev.<DOMAIN_SUFFIX>/`. If no `_platform_session`
cookie → 302 to `https://login.dev.<DOMAIN_SUFFIX>/oauth2/start?rd=...`
→ login form → submit → cookie set on apex → 302 back → Dashboard loads.

## MicroK8s notes

- Tekton Pipelines requires the `--allow-privileged=true` kubelet flag (default
  on MicroK8s — verify with `microk8s kubectl get pods -n kube-system`).
- The Buildah Task in `apps/image-builder/` runs in privileged mode (mandatory
  for `vfs`-driver image builds). PodSecurityStandards in MicroK8s' default
  setup allow this; if you enable PSA, mark the `image-builder` namespace
  with `pod-security.kubernetes.io/enforce: privileged`.
- Refresh upstream YAML on Tekton minor releases. Patch releases are usually
  drop-in compatible.
