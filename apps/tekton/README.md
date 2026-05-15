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
`https://tekton.dev.<DOMAIN_SUFFIX>/` behind a Traefik basic-auth Middleware.
DEV-only: TEST/PROD don't run image-builder so they don't need it; the
`dashboard.enabled` toggle defaults to `false` in values-common.yaml.

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
   # dashboard.enabled is false) skip rendering it. The curl downloads
   # the raw upstream YAML; after the sed-strip above, prepend +
   # append the Helm conditional:
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

   Bump the three versions in `values-common.yaml` `release:` block so the
   chart description stays in sync. Re-run the curl + sed block to refresh.

   **Note:** Tekton release artifacts moved from `storage.googleapis.com/
   tekton-releases/` to `github.com/tektoncd/*/releases/download/` somewhere
   between v0.30 and v1.10. Both URLs returned 200 for years; the GCS one
   now 404s for newer versions.

2. **Helm-template** the chart to verify the vendored YAML renders cleanly:

   ```bash
   helm dependency build apps/tekton
   helm template tekton apps/tekton \
     -f platform/values-common.yaml \
     -f platform/values-dev.yaml \
     -f apps/tekton/values-common.yaml \
     -f apps/tekton/values-dev.yaml | head -100
   ```

3. **Commit + push.** ArgoCD's `tekton-dev` Application syncs at wave 3,
   applying the operator manifests, then wave 25 brings up `image-builder`.

## Verify install

```bash
kubectl -n tekton get pods
kubectl -n tekton get crds | grep tekton.dev
tkn version       # client + server
```

## Tekton Dashboard bootstrap (DEV only — one-time)

Required before the first ArgoCD sync of the `tekton-dev` Application
with `dashboard.enabled=true`. Skip on TEST/PROD.

1. **DNS** — `tekton.dev.<DOMAIN_SUFFIX>` A-record → cluster's public IPv4.

2. **Generate admin password + bcrypt-hash**:
   ```bash
   PASS=$(openssl rand -base64 32 | tr -d /+= | head -c 40)
   echo "Login password (save in password manager): $PASS"
   htpasswd -nbB admin "$PASS"
   # → admin:$2y$05$abcdef...   (paste this whole line into Vault below)
   ```

3. **Vault UI** at `https://vault.dev.<DOMAIN_SUFFIX>:8200/ui/`:
   - Navigate to `secret/dev/app/tekton` (KV-v2)
   - Create new version → key `auth`, value = the full htpasswd line.
   - Save.

4. **Vault role**: same UI → `Access → Auth Methods → kubernetes/ →
   Roles → external-secrets → Edit` → append `tekton` to
   `bound_service_account_namespaces`. Save.

5. **Per-host `configs/secrets.dev`** — set `TEKTON_DASHBOARD_AUTH=...`
   (whole htpasswd line) so a future `--seed-vault` doesn't drop the
   key. (Gitignored per host. Schema row already in `secrets.example`.)

After ArgoCD syncs:
- Browser to `https://tekton.dev.<DOMAIN_SUFFIX>/` → basic-auth dialog →
  `admin` + the plaintext password from step 2 → DAG view loads.
- Forgot the password: regenerate, paste new htpasswd into Vault entry,
  force-resync the ExternalSecret:
  ```bash
  microk8s kubectl -n tekton annotate externalsecret \
    tekton-dashboard-auth force-sync="$(date +%s)" --overwrite
  ```

## MicroK8s notes

- Tekton Pipelines requires the `--allow-privileged=true` kubelet flag (default
  on MicroK8s — verify with `microk8s kubectl get pods -n kube-system`).
- The Buildah Task in `apps/image-builder/` runs in privileged mode (mandatory
  for `vfs`-driver image builds). PodSecurityStandards in MicroK8s' default
  setup allow this; if you enable PSA, mark the `image-builder` namespace
  with `pod-security.kubernetes.io/enforce: privileged`.
- Refresh upstream YAML on Tekton minor releases. Patch releases are usually
  drop-in compatible.
