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
`https://tekton.dev.<DOMAIN_SUFFIX>/` behind an **oauth2-proxy v7
reverse-proxy** with cookie-based session auth (htpasswd backend).
DEV-only: TEST/PROD don't run image-builder so they don't need it; the
`dashboard.enabled` toggle defaults to `false` in values-common.yaml.

## Why oauth2-proxy and not Traefik basic-auth

The first iteration of this chart gated the Dashboard with a Traefik
`basicAuth` Middleware. Functional but a poor fit for an SPA:

- Browsers cache basic-auth credentials per `(origin, realm)`, but the
  cache invalidates on 401 responses from sub-resources — Dashboard's
  React app fires dozens of XHR/Fetch requests on every navigation and
  ANY 401 along the way re-prompts the dialog.
- **WebSocket upgrades do not propagate the `Authorization` header.**
  Dashboard streams live step logs over WS; the first WS handshake
  returns 401, the browser re-prompts.
- Result: users see the basic-auth dialog repeatedly after the first
  login. Annoying enough to abandon basic-auth for any SPA-class UI.

oauth2-proxy solves both:

- The login is an **HTML form** posted to `/oauth2/sign_in`; no browser
  dialog at all. On success, oauth2-proxy issues a signed `_tekton_session`
  cookie (7d expiry, 24h refresh).
- Cookies **are** sent on same-origin WebSocket handshakes, so live
  log-tail works without re-auth.
- The same library chart (`charts/oauth2-proxy/`) can be reused later
  to gate ArgoCD, Headlamp, dbgate — anywhere basic-auth bites today.

This chart runs oauth2-proxy in **reverse-proxy mode**, not Traefik
`forwardAuth`. Single Ingress → oauth2-proxy:4180 → upstream
`tekton-dashboard:9097`. WS upgrades pass cleanly through oauth2-proxy
v7's built-in handler.

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

2. **Commit + push.** ArgoCD's `tekton-dev` Application syncs at wave 3,
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

3. **Generate cookie-secret** (32 raw bytes, base64-trimmed to length 32):
   ```bash
   COOKIE=$(openssl rand -base64 32 | head -c 32)
   echo "Cookie secret (paste into Vault, no need to save elsewhere): $COOKIE"
   ```

4. **Vault UI** at `https://vault.dev.<DOMAIN_SUFFIX>:8200/ui/`:
   - Navigate to `secret/dev/app/tekton` (KV-v2).
   - Create new version with **two keys**:
     - `htpasswd` → the full htpasswd line from step 2.
     - `cookie-secret` → the 32-char string from step 3.
   - Save.
   - If the previous `auth` key is present from an older basic-auth
     install, you can delete it now — the new schema does not reference it.

5. **Vault role**: same UI → `Access → Auth Methods → kubernetes/ →
   Roles → external-secrets → Edit` → ensure `tekton` is in
   `bound_service_account_namespaces`. Save. (Already done if the
   previous basic-auth setup ran here; first-time setups need it.)

6. **Per-host `configs/secrets.dev`** — set both
   `TEKTON_AUTH_HTPASSWD=...` and `TEKTON_AUTH_COOKIE_SECRET=...` so a
   future `setup-kubernetes.sh --dev --seed-vault` doesn't drop the keys.
   (Gitignored per host. Schema rows already in `secrets.example`.)

After ArgoCD syncs:
- Browser to `https://tekton.dev.<DOMAIN_SUFFIX>/` → oauth2-proxy login
  form (NOT a basic-auth dialog) → `admin` + the plaintext password from
  step 2 → cookie set → DAG view loads.
- Forgot the password: regenerate htpasswd (step 2), update Vault entry,
  force-resync the ExternalSecret, then restart oauth2-proxy so it
  re-reads the file:
  ```bash
  microk8s kubectl -n tekton annotate externalsecret \
    tekton-dashboard-auth force-sync="$(date +%s)" --overwrite
  microk8s kubectl -n tekton rollout restart deploy/tekton-oauth-proxy
  ```
- Rotate cookie-secret (invalidates ALL existing sessions): same
  procedure, replace `cookie-secret` key in Vault, force-resync, rollout
  restart.

## Migration from basic-auth (one-time, only if you ran the basic-auth version)

If your cluster currently runs the previous basic-auth iteration of this
chart, do the migration steps below before pulling this commit, so the
ArgoCD sync after pull lands on a working state:

1. Generate cookie-secret as in step 3 above.
2. In Vault UI, edit `secret/dev/app/tekton`: add `htpasswd` (copy the
   value from the existing `auth` key) and `cookie-secret` (new). Save.
3. Update `setup-kubernetes/configs/secrets.dev` per step 6.
4. Pull this commit. ArgoCD reconciles: removes the Traefik basicAuth
   Middleware, deploys oauth2-proxy, refreshes the K8s Secret with the
   two new keys, swings the Ingress backend to oauth2-proxy:4180.
5. Visit Dashboard URL — expect the new HTML login form.
6. (Optional) Delete the now-unused `auth` key from the Vault entry.

## MicroK8s notes

- Tekton Pipelines requires the `--allow-privileged=true` kubelet flag (default
  on MicroK8s — verify with `microk8s kubectl get pods -n kube-system`).
- The Buildah Task in `apps/image-builder/` runs in privileged mode (mandatory
  for `vfs`-driver image builds). PodSecurityStandards in MicroK8s' default
  setup allow this; if you enable PSA, mark the `image-builder` namespace
  with `pod-security.kubernetes.io/enforce: privileged`.
- Refresh upstream YAML on Tekton minor releases. Patch releases are usually
  drop-in compatible.
