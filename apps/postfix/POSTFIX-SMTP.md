# Postfix Send-Only SMTP Pod — Deployment Guide

Cluster-internal, direct-sending SMTP pod using `boky/postfix` with DKIM/SPF/DMARC authentication.
No relay — sends directly to recipient MX servers.

```
your-app ──────┐
alertmanager ───┤──(port 587, no auth)──> postfix pod ──(DKIM signed)──> recipient MX
cronjobs ───────┘                         ClusterIP only
```

**Subdomains** (root `<your-domain>` is still used by legacy apps):

| Environment | Mail domain              | Sender address                    |
|-------------|--------------------------|-----------------------------------|
| Test        | `mail.<env>.<domain>`  | `order@mail.<env>.<domain>`     |
| Prod        | `mail.<env>.<domain>`  | `order@mail.<env>.<domain>`     |

---

## What Was Implemented

### Files Modified

| File | Change |
|------|--------|
| `setup-gitops/gitops-setup.config` | Added `POSTFIX_*` config vars, `NS_POSTFIX`, `SYNCWAVE_SMTP`, postfix in `APPLICATIONS`/`TEST_ENABLED_APPS`/`PROD_ENABLED_APPS`/`APPS_WITH_SECRETS`/`APP_SECRET_ORDER`, secret schema (`APP_SECRET_VAULT_PATH_postfix`, `APP_SECRET_FIELDS_postfix`) |
| `setup-gitops/modules/06-generation-operations.sh` | Added `postfix` to `get_sync_wave()`, added `POSTFIX_*`/`NS_POSTFIX` to all 4 `render_template` calls (Chart.yaml, values-common, values-test, values-prod) |
| `setup-gitops/modules/02-kubernetes-operations.sh` | Added `postfix` to `get_namespace_for_app()` |
| `setup-gitops/modules/load-modules.sh` | Registered `10-dkim-operations.sh` |
| `setup-gitops/setup-gitops.sh` | Added `--generate-dkim-test`/`--generate-dkim-prod` switches, argument parsing, execution block (before `check_prerequisites`), usage help, deployment guide step 1b |
| `setup-gitops/secrets.test.base.env.template` | Added `POSTFIX_DKIM_PRIVATE_KEY=` entry |
| `setup-gitops/secrets.prod.base.env.template` | Added `POSTFIX_DKIM_PRIVATE_KEY=` entry |

### Files Created

| File | Purpose |
|------|---------|
| `setup-gitops/templates/app-charts/postfix-chart.yaml` | Helm chart depending on `boky/postfix` (mail) + `external-secret` |
| `setup-gitops/templates/app-charts/postfix-values-common.yaml` | ClusterIP:587, DKIM config, rate limits, persistence, security context |
| `setup-gitops/templates/app-charts/postfix-values-test.yaml` | `mail.<env>.<domain>` hostname, resources, DKIM volume, ExternalSecret from `test/app/postfix` |
| `setup-gitops/templates/app-charts/postfix-values-prod.yaml` | `mail.<env>.<domain>` hostname, resources, DKIM volume, ExternalSecret from `prod/app/postfix` |
| `setup-gitops/modules/10-dkim-operations.sh` | `generate_dkim_keys()` — generates 2048-bit RSA keypair via openssl, stores in secrets file, outputs DNS records |
| `apps/postfix/templates/networkpolicy.yaml` | Hand-maintained NetworkPolicy (not overwritten by generation script) — restricts ingress to allowed namespaces on port 587, egress to SMTP (25/587) and DNS (53) |

### Sync Wave

Postfix deploys at wave 2 (same as cache/logging, before admin UIs):

```
Wave 0:  ExternalSecrets
Wave 1:  MongoDB (databases)
Wave 2:  Redis (cache), Postfix (SMTP), Seq (logging)
Wave 3:  DBGate (admin UI)
Wave 4:  cronjobs, vpn-monitoring (dev tools)
Wave 5:  your application charts
```

### NetworkPolicy

The postfix pod is locked down via `apps/postfix/templates/networkpolicy.yaml`:

- **Ingress**: Only from `mongodb`, `observability`, `cronjobs`, `vpn-monitoring` namespaces on TCP 587 (extend per project)
- **Egress**: Only TCP 25 + 587 (SMTP to internet) and UDP/TCP 53 (DNS resolution)
- No external access to the pod (ClusterIP only, no Ingress)

### Secret Schema

The DKIM private key follows the standard secret schema pattern:

```
Vault path:     {env}/app/postfix
Vault key:      dkim-private-key
Schema field:   POSTFIX_DKIM_PRIVATE_KEY|env|dkim-private-key|dkim-private-key|required
Secrets file:   ~/secrets/secrets.{env}.base.env → POSTFIX_DKIM_PRIVATE_KEY=<PEM key>
```

The ExternalSecret in the Helm values pulls the key from Vault into a Kubernetes Secret (`postfix-dkim-key`), which is mounted into the pod at `/etc/opendkim/keys/mail.<env>.<domain>/mail.private`.

---

## How Receiving Mail Servers Trust Us

When our postfix pod sends an email to e.g. Gmail, the receiving MX server runs 5 checks before accepting delivery. All 5 must pass for reliable inbox delivery.

### 1. PTR / Forward-Confirmed rDNS (FCrDNS)

The first and most critical check. The receiver does a reverse DNS lookup on our connecting IP immediately.

```
Gmail sees connection from 1.2.3.4
  -> PTR lookup on 1.2.3.4     -> mail.<env>.<domain>   (reverse)
  -> A   lookup on result       -> 1.2.3.4                 (forward confirmation)
  -> Both match = FCrDNS pass
```

If there is no PTR record, or the PTR hostname does not resolve back to the same IP, most large providers (Gmail, Microsoft, Yahoo) will **reject the connection outright** or classify as spam.

The PTR record is set by the **hosting provider** (whoever owns the IP block), not in the IONOS domain panel. This must be requested separately.

### 2. EHLO Hostname

Our postfix announces itself with `EHLO mail.<env>.<domain>` (configured via `myhostname`). The receiver checks that this hostname has an A record resolving to the connecting IP.

```
EHLO mail.<env>.<domain>
  -> A lookup: mail.<env>.<domain> -> 1.2.3.4
  -> Matches connecting IP = EHLO pass
```

### 3. SPF (Sender Policy Framework)

The receiver checks whether our IP is authorized to send for the envelope-from domain.

```
MAIL FROM: order@mail.<env>.<domain>
  -> TXT lookup on mail.<env>.<domain>
  -> "v=spf1 ip4:1.2.3.4 -all"
  -> Connecting IP is in the list = SPF pass
  -> -all means: reject anything not listed (hard fail)
```

### 4. DKIM (DomainKeys Identified Mail)

Our postfix signs every outgoing email with the DKIM private key. The receiver retrieves the public key from DNS and verifies the cryptographic signature.

```
Email header contains:
  DKIM-Signature: v=1; a=rsa-sha256; d=mail.<env>.<domain>; s=mail; ...

Receiver:
  -> TXT lookup on mail._domainkey.mail.<env>.<domain>
  -> "v=DKIM1; h=sha256; k=rsa; p=<public_key>"
  -> Verifies signature against email body + selected headers
  -> Signature valid = DKIM pass
```

### 5. DMARC (Domain-based Message Authentication, Reporting & Conformance)

DMARC ties SPF and DKIM together by checking **domain alignment** — the domain in the `From:` header must match the domain verified by SPF and/or DKIM.

```
From: order@mail.<env>.<domain>

DMARC check:
  -> TXT lookup on _dmarc.mail.<env>.<domain>
  -> "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"
  -> SPF domain (mail.<env>.<domain>) aligns with From: domain? YES
  -> DKIM d= domain (mail.<env>.<domain>) aligns with From: domain? YES
  -> Policy p=none = monitor only (report but don't reject)
  -> DMARC pass
```

The `p=none` policy is correct for initial deployment (monitor mode). After confirming everything works, tighten progressively: `p=none` -> `p=quarantine` -> `p=reject`.

### Summary of DNS records per environment

| Type | Name | Value | Set Where |
|------|------|-------|-----------|
| A | `mail.<env>.<domain>` | `<CLUSTER_OUTBOUND_IP>` | IONOS DNS |
| TXT (SPF) | `mail.<env>.<domain>` | `"v=spf1 ip4:<CLUSTER_OUTBOUND_IP> -all"` | IONOS DNS |
| TXT (DKIM) | `mail._domainkey.mail.<env>.<domain>` | `"v=DKIM1; h=sha256; k=rsa; p=<PUBLIC_KEY>"` | IONOS DNS |
| TXT (DMARC) | `_dmarc.mail.<env>.<domain>` | `"v=DMARC1; p=none; rua=mailto:dmarc@<domain>"` | IONOS DNS |
| PTR | `<CLUSTER_OUTBOUND_IP>` | `mail.<env>.<domain>` | **Hosting provider** |

---

## Deployment Workflow

### Step 1: Generate DKIM keys

```bash
./setup-gitops.sh --generate-dkim-test
```

This generates:
- 2048-bit RSA keypair via openssl
- Stores private key in `~/secrets/secrets.test.base.env` as `POSTFIX_DKIM_PRIVATE_KEY`
- Outputs the DNS TXT record to add in IONOS
- Saves full DNS instructions to `~/secrets/dkim-dns-record.test.txt`

To regenerate (invalidates existing DNS records):
```bash
./setup-gitops.sh --generate-dkim-test --force
```

### Step 2: Add DNS records in IONOS

Using the output from step 1 and the DNS table above:

1. Add the A record for `mail.<env>.<domain>`
2. Add the SPF TXT record
3. Add the DKIM TXT record (from `~/secrets/dkim-dns-record.test.txt`)
4. Add the DMARC TXT record
5. Request PTR record from hosting provider

Wait for DNS propagation:
```bash
dig A mail.<env>.<domain>
dig TXT mail.<env>.<domain>
dig TXT mail._domainkey.mail.<env>.<domain>
dig TXT _dmarc.mail.<env>.<domain>
```

### Step 3: Generate GitOps manifests

```bash
./setup-gitops.sh --generate-test
```

This renders all templates including the postfix chart, values, and ArgoCD application.

### Step 4: Store secrets in Vault

```bash
./setup-gitops.sh --setup-vault-test
```

This reads `POSTFIX_DKIM_PRIVATE_KEY` from `~/secrets/secrets.test.base.env` and stores it in Vault at `secret/test/app/postfix` with key `dkim-private-key`.

### Step 5: Deploy postfix

```bash
./setup-gitops.sh --enable-test postfix
```

Or as part of enabling all apps:
```bash
./setup-gitops.sh --enable-test
```

### Step 6: Verify

```bash
# Pod running
kubectl -n postfix get pods

# Logs — OpenDKIM started, no errors
kubectl -n postfix logs <pod-name>

# Send test email to authentication verifier
kubectl -n postfix exec <pod-name> -- \
  sendmail check-auth@verifier.port25.com <<< "Subject: Test from postfix
From: order@mail.<env>.<domain>
To: check-auth@verifier.port25.com

This is a DKIM/SPF/DMARC test."

# Check mail-tester.com (get a unique address from the site first)
# Target: score 9+/10

# NetworkPolicy test (should fail — default namespace is not allowed)
kubectl run -n default test --rm -it --image=busybox -- nc -z postfix-mail.postfix 587
```

### Production deployment

Same steps, replace `test` with `prod`:

```bash
./setup-gitops.sh --generate-dkim-prod
# Add DNS records for mail.<env>.<domain>
./setup-gitops.sh --generate-prod
./setup-gitops.sh --setup-vault-prod
./setup-gitops.sh --enable-prod postfix
```

---

## Open Items

### Must do before deployment

- [ ] **Determine cluster outbound IP** — find the IP that outbound traffic from the cluster uses (`curl -s ifconfig.me` from a pod). This IP goes into the A and SPF records.
- [ ] **Request PTR record** — contact the hosting provider (whoever owns the outbound IP) to set the reverse DNS record. This is the #1 cause of email rejection if missing.
- [ ] **Verify port 25 outbound access** — many cloud/hosting providers block outbound port 25 by default to prevent spam. Test from a pod: `nc -z smtp.google.com 25`. If blocked, request unblocking from the hosting provider.
- [ ] **Add DNS records in IONOS** — A, SPF, DKIM, DMARC records for the target environment.
- [ ] **Generate DKIM keys** — run `./setup-gitops.sh --generate-dkim-{test,prod}`.
- [ ] **Verify `POSTFIX_CHART_VERSION`** — check latest version at `https://bokysan.github.io/docker-postfix/` before deploying. Currently set to `4.4.0`.

### After deployment

- [ ] **IP warming** — new IPs have zero reputation. Start with low volume (a few emails/day) and gradually increase over 2-4 weeks. Large providers (Gmail, Microsoft) throttle unknown senders.
- [ ] **Monitor DMARC reports** — reports will be sent to `dmarc@<domain>` (as configured in the DMARC record). Review them to catch alignment issues.
- [ ] **Tighten DMARC policy** — after confirming SPF/DKIM pass consistently in reports, change `p=none` to `p=quarantine`, then eventually `p=reject`.
- [ ] **App integration** — update each application's SMTP connection config to point at `postfix-{env}-mail.postfix.svc.cluster.local:587` instead of an external relay (e.g. `smtp.ionos.de:587`). This is a separate change per app.

### Not in scope (done separately)

- Per-application SMTP host/port switches (one PR per consuming app)
