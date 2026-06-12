# objectstore — Garage S3 store + Filestash web UI

S3-compatible object storage for the platform, deployed to every env. Two pods
in the `objectstore` namespace:

| Component | Image | Purpose |
|---|---|---|
| Garage | `dxflrs/garage:v2.3.0` | S3 API; stores object blobs on a PVC. Single-node, `replication_factor = 1`. |
| Filestash | `machines/filestash:latest@sha256:…` (digest-pinned) | Web file manager for humans, preconfigured against the Garage bucket. |

## Endpoints

| Consumer | URL |
|---|---|
| In-cluster S3 (preferred for workloads) | `http://garage-s3.objectstore.svc.cluster.local:3900` |
| Public S3 (external clients / local dev) | `https://s3.<env>.<DOMAIN_SUFFIX>` |
| Web UI (humans, Authentik SSO) | `https://files.<env>.<DOMAIN_SUFFIX>` |
| Filestash admin console | `https://files.<env>.<DOMAIN_SUFFIX>/admin` |

DNS pre-flight: `s3.<env>.<DOMAIN_SUFFIX>` and `files.<env>.<DOMAIN_SUFFIX>`
must resolve to the host's public IPv4 (wildcard `*.<env>.<DOMAIN_SUFFIX>`
covers both) before the first sync, or the LE certs won't issue.

A CoreDNS rewrite (`apps/coredns/values-<env>.yaml`) maps `s3.<env>.…` onto
Traefik for in-cluster pods that use the public URL, sidestepping NAT-hairpin
problems — same pattern as `zot.dev.…`.

## Provisioning model (no manual steps in the store itself)

Garage v2.3 starts with `--single-node --default-bucket`:

- `--single-node` auto-creates the cluster layout on first boot.
- `--default-bucket` auto-creates ONE access key + ONE bucket from env vars
  `GARAGE_DEFAULT_ACCESS_KEY` / `GARAGE_DEFAULT_SECRET_KEY` /
  `GARAGE_DEFAULT_BUCKET` (idempotent once they exist).

The key/secret values come from Vault (`secret/<env>/app/objectstore`) via
ESO; the bucket name (`documents`) is a chart value. **One key is shared** by
the Node.js app and Filestash — simplest declarative setup; tradeoff is shared
rotation and no per-consumer audit. Need separation later? `garage key import`
a second key via the admin CLI inside the pod and grant it on the bucket.

Secrets are authored in `setup-kubernetes/secrets/secrets.<env>` (see the
`objectstore` section in `secrets/secrets.example` for generation commands)
and pushed with `sudo ./setup-kubernetes.sh --<env> --seed-vault`, which also
adds the `objectstore` namespace to Vault's ESO role.

## Credentials retrieval

```bash
vault kv get -field=access-key-id     secret/<env>/app/objectstore
vault kv get -field=secret-access-key secret/<env>/app/objectstore
```

(Or read them straight from your `secrets/secrets.<env>` file.)

## Node.js usage (@aws-sdk/client-s3)

```js
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
} from "@aws-sdk/client-s3";

const s3 = new S3Client({
  // In-cluster:    http://garage-s3.objectstore.svc.cluster.local:3900
  // Outside:       https://s3.<env>.<DOMAIN_SUFFIX>
  endpoint: "https://s3.dev.digitaplatform.com",
  region: "garage",          // must match garage.toml s3_api.s3_region
  forcePathStyle: true,      // Garage serves buckets path-style
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID,         // GK…
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
  },
});

// Round-trip test
await s3.send(new PutObjectCommand({
  Bucket: "documents",
  Key: "hello/world.txt",
  Body: "it works",
  ContentType: "text/plain",
}));

const res = await s3.send(new GetObjectCommand({
  Bucket: "documents",
  Key: "hello/world.txt",
}));
console.log(await res.Body.transformToString()); // "it works"
```

## Humans: Filestash login flow

1. Open `https://files.<env>.<DOMAIN_SUFFIX>` → Traefik's forwardAuth
   middleware redirects to the platform IdP (`idp.<env>.…`) unless the apex
   session cookie is already present (one login covers dbgate/seq/tekton/files).
2. After SSO, Filestash's passthrough middleware (`strategy: direct` +
   `attribute_mapping`, see the seed config in `values-common.yaml`)
   auto-connects the session to the **documents** bucket — no credentials, no
   clicks. Browse/upload/download directly (Office files, PDFs, images
   preview in-browser).
3. The **admin console** (`/admin`) is separately protected by the bcrypt
   admin password (`filestash-admin-password` in Vault). Use it to tweak UI
   settings; changes persist on the `filestash-state` PVC.

The IdP side is a blueprint:
`setup-kubernetes/manifests/idp/blueprints/99-proxy-filestash.yaml` (plus its
entry in `99-z-outpost-bindings.yaml`). After changing blueprints, re-run
`sudo ./setup-kubernetes.sh --<env> --deploy-idp`.

## First-boot config seeding (and why edits survive)

ESO renders the Secret `filestash-seed` (admin hash + S3 connection) and the
pod's shell wrapper copies it to `/app/data/state/config/config.json` **only
when the file doesn't exist**. Later admin-console changes live on the PVC and
are never clobbered. To force a re-seed: delete the file (or the PVC) and
restart the pod:

```bash
microk8s kubectl -n objectstore exec deploy/objectstore-<env>-filestash -- \
  rm /app/data/state/config/config.json
microk8s kubectl -n objectstore rollout restart deploy/objectstore-<env>-filestash
```

Bucket name / region are intentionally written in two places
(`apps/objectstore/values-common.yaml`: garage env + the ESO template) because
ESO templates can't read Helm values — keep them in sync when changing.

## Uninstall

1. Remove the `objectstore` element from every
   `argocd/<env>/apps/applicationset.yaml` and the `objectstore` destination
   from the `data` project in `argocd/<env>/apps/projects.yaml`. Push; ArgoCD
   prunes the Application and all its resources—
2. **except the data**: both PVCs carry
   `argocd.argoproj.io/sync-options: Prune=false,Delete=false` and survive.
   Deleting data is an explicit opt-in:
   ```bash
   microk8s kubectl -n objectstore delete pvc garage-data filestash-state
   microk8s kubectl delete namespace objectstore
   ```
3. Optional cleanup: drop the `objectstore` rows from `secrets/secrets.<env>`
   + re-run `--seed-vault`, remove the CoreDNS `s3.<env>` rewrite, and remove
   the Filestash IdP blueprint + outpost-binding entry + `--deploy-idp`.

## Version maintenance

- **Garage**: bump `apps/objectstore/Chart.yaml` `appVersion` AND
  `values-common.yaml` `garage.image.tag` (two places, must match). Check the
  release notes for metadata-format migrations before jumping majors.
- **Filestash** (no upstream version tags — digest pin):
  ```bash
  # Get the current multi-arch digest of :latest
  curl -s https://hub.docker.com/v2/repositories/machines/filestash/tags/latest \
    | jq -r .digest
  ```
  Put the new `sha256:…` into `filestash.image.tag`
  (`latest@sha256:…`) in `values-common.yaml`.

## Replication factor

`replication_factor = 1` is the only supported value here: every env is a
single-node MicroK8s cluster and the chart deploys a single Deployment with
`--single-node` layout bootstrap. A real rf≥2 deployment needs multiple nodes,
a StatefulSet, per-node PVCs and manual `garage layout assign/apply` — out of
scope for this platform.
