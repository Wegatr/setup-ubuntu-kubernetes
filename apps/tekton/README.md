# apps/tekton/ — Tekton Pipelines + Triggers install

This chart provides the **operator/CRDs** that `apps/image-builder/`
depends on. It is **not** a self-contained Tekton install — community Helm
charts lag the upstream Tekton release cadence, so we vendor the upstream
release YAML directly into `templates/release-*.yaml`.

## One-time setup (per cluster)

1. **Download the vendored release manifests** (run from the repo root,
   commit the results):

   ```bash
   PIPELINES_VERSION=v1.12.0
   TRIGGERS_VERSION=v0.35.0
   INTERCEPTORS_VERSION=v0.35.0

   curl -fsSL -o apps/tekton/templates/release-pipelines.yaml \
     "https://github.com/tektoncd/pipeline/releases/download/${PIPELINES_VERSION}/release.yaml"

   curl -fsSL -o apps/tekton/templates/release-triggers.yaml \
     "https://github.com/tektoncd/triggers/releases/download/${TRIGGERS_VERSION}/release.yaml"

   curl -fsSL -o apps/tekton/templates/release-interceptors.yaml \
     "https://github.com/tektoncd/triggers/releases/download/${INTERCEPTORS_VERSION}/interceptors.yaml"

   # K8s 1.22+ silently strips `preserveUnknownFields: false` on apply —
   # leaving it in the vendored YAML causes permanent ArgoCD drift. Strip it.
   sed -i '/preserveUnknownFields: false/d' \
     apps/tekton/templates/release-pipelines.yaml \
     apps/tekton/templates/release-triggers.yaml \
     apps/tekton/templates/release-interceptors.yaml
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
kubectl -n tekton-pipelines get pods
kubectl -n tekton-pipelines get crds | grep tekton.dev
tkn version       # client + server
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
