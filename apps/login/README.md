# apps/login/ — shared platform auth gate

One oauth2-proxy instance gated by an htpasswd file, exposing two things
to the rest of the cluster:

- A **public login form** at `https://login.<env>.<DOMAIN_SUFFIX>/`
  — users land here when they hit any gated app without a session cookie.
- A **Traefik forwardAuth Middleware** (`login-forwardauth` in this
  namespace) that other Ingresses reference cross-namespace to outsource
  auth checks. Naming: `login-forwardauth@kubernetescrd`.

Session cookies are scoped to the env apex (`.dev.<DOMAIN_SUFFIX>` with a
leading dot) so a single login carries to every subdomain in the same
env — tekton.dev, dbgate.dev, grafana.dev, etc.

Phase A is DEV-only. TEST/PROD have no human-facing UIs beyond the
observability stack, which is reached via VPN; values-{test,prod}.yaml
intentionally leave every dep `enabled: false`.

## How another app opts in

Single annotation on the consumer's Ingress, e.g.:

```yaml
# apps/tekton/values-dev.yaml
ingress:
  ingress:
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: login-forwardauth@kubernetescrd
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
```

That's it. No per-app oauth2-proxy, no per-app htpasswd, no per-app
Vault entry. The cookie set when the user logs in at login.dev is
recognized by oauth2-proxy on every subsequent forwardAuth check
because the cookie domain is apex.

## How the flow works

```
1. Browser → https://tekton.dev/somepage   (no _platform_session cookie)
2. Traefik picks the matching Ingress; the login-forwardauth Middleware
   triggers BEFORE the backend is hit.
3. Traefik → http://login-oauth-proxy.login.svc:4180/   (with X-Forwarded-* set)
4. oauth2-proxy: no valid cookie → 302 Location:
     https://login.dev/oauth2/start?rd=https%3A%2F%2Ftekton.dev%2Fsomepage
5. Traefik forwards the 302 back to the browser.
6. Browser → login.dev/oauth2/start → sign-in form → POST credentials
   → oauth2-proxy validates htpasswd → sets _platform_session cookie
   on .dev.<DOMAIN_SUFFIX>  (apex scope!)  → 302 back to rd= target.
7. Browser → https://tekton.dev/somepage WITH the cookie.
8. Traefik forwardAuth → oauth-proxy validates cookie → 202 Accepted.
9. Traefik routes the original request to tekton-dashboard:9097.

WebSocket upgrades from the SPA carry the cookie same-origin; step 8
runs against /oauth2/auth BEFORE the WS upgrade is negotiated, so
WS streaming works without re-prompts.
```

## One-time setup (per cluster)

1. **DNS** — `login.dev.<DOMAIN_SUFFIX>` A-record → cluster public IPv4.

2. **Vault** at `https://vault.dev.<DOMAIN_SUFFIX>:8200/ui/`:
   - Path `secret/dev/app/login` (KV-v2), Create version 1 with keys:
     - `htpasswd` — full htpasswd line. Generate:
       ```bash
       htpasswd -nbB admin '<your-password>'
       ```
     - `cookie-secret` — 32-char random:
       ```bash
       openssl rand -base64 32 | head -c 32
       ```
     - `admin` (optional) — plaintext password for your own reference.
   - `Access → Auth Methods → kubernetes/ → Roles → external-secrets →
     Edit` → append `login` to `bound_service_account_namespaces`. Save.

3. **Per-host `setup-kubernetes/configs/secrets.dev`** (gitignored):
   ```bash
   LOGIN_HTPASSWD="admin:$2y$05$..."
   LOGIN_COOKIE_SECRET="<32 chars>"
   ```
   Schema rows already in `configs/secrets.example`. The
   `setup-kubernetes.sh --dev --seed-vault` step writes these into the
   same Vault path on every re-run.

4. **Commit + push** the platform code. ArgoCD reconciles at sync wave 2.

5. Browser → `https://login.dev.<DOMAIN_SUFFIX>/oauth2/sign_in` → form
   loads. Logging in here gives you a cookie valid for every gated
   subdomain.

## Rotating credentials

- **Change password**: regenerate htpasswd, update Vault key
  `htpasswd`, force-resync the ExternalSecret + restart oauth2-proxy:
  ```bash
  microk8s kubectl -n login annotate externalsecret login-auth \
    force-sync="$(date +%s)" --overwrite
  microk8s kubectl -n login rollout restart deploy/login-dev-oauth-proxy
  ```
- **Rotate cookie-secret** (invalidates ALL existing sessions —
  everyone re-logs in): same procedure, replace `cookie-secret` key.

## Logout

The universal logout URL — bookmark it:
```
https://login.dev.<DOMAIN_SUFFIX>/oauth2/sign_out?rd=https://login.dev.<DOMAIN_SUFFIX>/oauth2/sign_in
```
Clears the `_platform_session` cookie (cookie is apex-scoped → logging
out at login.dev logs you out everywhere) and redirects to the sign-in
form.

To log out and come back to a specific app:
```
https://login.dev.<DOMAIN_SUFFIX>/oauth2/sign_out?rd=https://tekton.dev.<DOMAIN_SUFFIX>/
```
After cookie is cleared, browser hits tekton.dev → forwardAuth fails
→ 302 back to login form. After re-login, lands back on tekton.dev.

Hitting `/oauth2/sign_out` on a GATED subdomain (e.g.
`tekton.dev/oauth2/sign_out`) does NOT work — that path 404s on the
upstream because Traefik routes /oauth2/* to the consumer's backend
(tekton-dashboard), not to oauth2-proxy. The forwardAuth Middleware
only does the auth-CHECK; it doesn't route traffic. Stick to login.dev
for any /oauth2/* action.
