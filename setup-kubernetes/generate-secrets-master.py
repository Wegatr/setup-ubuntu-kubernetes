#!/usr/bin/env python3
"""
generate-secrets-master.py
Generates all random secrets for the master (local) cluster and writes
secrets/secrets.master ready for --seed-vault.

Run from: ~/setup-ubuntu-kubernetes/setup-kubernetes/
  python3 generate-secrets-master.py

After --deploy-all, run again with the --post-deploy flag to fill in the
IdP / ArgoCD / Vault / Headlamp credentials from their .txt files:
  python3 generate-secrets-master.py --post-deploy
"""

import subprocess, base64, sys, os, re

SECRETS_FILE = "secrets/secrets.master"


def run(cmd):
    return subprocess.check_output(cmd, shell=True).decode().strip()


def rand_hex(n):
    return run(f"openssl rand -hex {n}")


def rand_b64(n):
    raw = run(f"openssl rand -base64 {n + 16}")
    return raw.replace("+", "").replace("/", "").replace("=", "").replace("\n", "")[:n]


def htpasswd(user, pw):
    return run(f"htpasswd -nbB '{user}' '{pw}'")


# ---------------------------------------------------------------------------
# --post-deploy mode: read the .txt credential files and patch secrets.master
# ---------------------------------------------------------------------------
def post_deploy():
    if not os.path.exists(SECRETS_FILE):
        print(f"ERROR: {SECRETS_FILE} not found. Run without --post-deploy first.")
        sys.exit(1)

    content = open(SECRETS_FILE).read()
    patched = 0

    def patch(varname, value):
        nonlocal content, patched
        # Replace  VARNAME=""  with  VARNAME="value"
        new, n = re.subn(
            rf'^({re.escape(varname)}=)"[^"]*"',
            rf'\1"{value}"',
            content,
            flags=re.MULTILINE,
        )
        if n:
            content = new
            patched += n

    # --- vault-master.txt (vault operator init output) ---
    vault_file = "secrets/vault-master.txt"
    if os.path.exists(vault_file):
        txt = open(vault_file).read()
        for i in range(1, 6):
            m = re.search(rf"^Unseal Key {i}:\s+(\S+)", txt, re.MULTILINE)
            if m:
                patch(f"VAULT_UNSEAL_KEY_{i}", m.group(1))
        m = re.search(r"^Initial Root Token:\s+(\S+)", txt, re.MULTILINE)
        if m:
            patch("VAULT_ROOT_TOKEN", m.group(1))
        print(f"✓ Vault credentials patched from {vault_file}")
    else:
        print(f"  SKIP: {vault_file} not found")

    # --- argocd-master.txt  format: "Password: <value>" ---
    argocd_file = "secrets/argocd-master.txt"
    if os.path.exists(argocd_file):
        txt = open(argocd_file).read()
        m = re.search(r"^Password:\s+(\S+)", txt, re.MULTILINE)
        if m:
            patch("ARGOCD_ADMIN_PASSWORD", m.group(1))
            print(f"✓ ArgoCD credentials patched from {argocd_file}")
        else:
            print(f"  WARN: Could not parse password from {argocd_file}")
    else:
        print(f"  SKIP: {argocd_file} not found")

    # --- kube-master.txt  format: "Token: <value>" ---
    kube_file = "secrets/kube-master.txt"
    if os.path.exists(kube_file):
        txt = open(kube_file).read()
        m = re.search(r"^Token:\s+(\S+)", txt, re.MULTILINE)
        if m:
            patch("KUBE_DASHBOARD_TOKEN", m.group(1))
            print(f"✓ Headlamp token patched from {kube_file}")
        else:
            print(f"  WARN: Could not parse token from {kube_file}")
    else:
        print(f"  SKIP: {kube_file} not found")

    # --- idp-master.txt  format: "Key label: <value>" (from deploy_idp.sh) ---
    idp_file = "secrets/idp-master.txt"
    if os.path.exists(idp_file):
        txt = open(idp_file).read()
        # Exact labels written by save_credential() in deploy_idp.sh
        mapping = {
            "Admin password":       "IDP_BOOTSTRAP_PASSWORD",
            "Secret key":           "IDP_SECRET_KEY",
            "Postgres password":    "IDP_POSTGRES_PASSWORD",
            "ArgoCD client_secret": "IDP_ARGOCD_CLIENT_SECRET",
            "Grafana client_secret":"IDP_GRAFANA_CLIENT_SECRET",
            "Headlamp client_secret":"IDP_HEADLAMP_CLIENT_SECRET",
            "Vault client_secret":  "IDP_VAULT_CLIENT_SECRET",
            "Zot client_secret":    "IDP_ZOT_CLIENT_SECRET",
        }
        for label, varname in mapping.items():
            m = re.search(rf"^{re.escape(label)}:\s+(\S+)", txt, re.MULTILINE)
            if m:
                patch(varname, m.group(1))
        print(f"✓ IdP credentials patched from {idp_file}")
    else:
        print(f"  SKIP: {idp_file} not found")

    open(SECRETS_FILE, "w").write(content)
    print(f"\n{patched} values updated in {SECRETS_FILE}")
    print("Run: sudo ./setup-kubernetes.sh --config configs/config.local --seed-vault")


# ---------------------------------------------------------------------------
# Main: generate all pre-deployment secrets
# ---------------------------------------------------------------------------
def generate():
    print("Generating secrets for master (local) cluster...")

    mongo_root   = rand_b64(32)
    mongo_rs_key = run("openssl rand -base64 756 | tr -d '\\n+/='")[:756]
    pg_pw        = rand_b64(32)
    pg_repl_pw   = rand_b64(32)
    seq_admin    = rand_b64(32)
    seq_api      = rand_hex(32)
    dbgate_admin = rand_b64(32)
    dbgate_auth  = htpasswd("admin", dbgate_admin)
    grafana_pw   = rand_b64(32)
    reg_push_pw  = rand_b64(40)
    reg_pull_pw  = rand_b64(40)
    reg_admin_pw = rand_b64(40)
    garage_rpc   = rand_hex(32)
    garage_admin = rand_b64(32)
    s3_key_id    = "GK" + rand_hex(16)
    s3_secret    = rand_hex(32)
    filestash_pw = rand_b64(32)
    filestash_cfg= rand_b64(32)
    filestash_hash = htpasswd("x", filestash_pw).split(":")[-1]
    gh_webhook   = rand_hex(32)
    bb_webhook   = rand_hex(32)
    ado_webhook  = rand_hex(32)
    fleet_jwt    = rand_hex(32)
    fleet_traccar= rand_b64(32)
    fleet_app    = rand_b64(32)
    fleet_fwd    = rand_hex(32)

    print("  Generating DKIM RSA 2048 key...")
    run("openssl genrsa -out /tmp/dkim-master.pem 2048 2>/dev/null || true")
    dkim_pem = open("/tmp/dkim-master.pem").read().strip()

    htpasswd_push  = htpasswd("push-user", reg_push_pw)
    htpasswd_pull  = htpasswd("pull-user", reg_pull_pw)
    htpasswd_admin = htpasswd("admin",     reg_admin_pw)
    registry_htpasswd = f"{htpasswd_push}\n{htpasswd_pull}\n{htpasswd_admin}"

    pull_auth    = base64.b64encode(f"pull-user:{reg_pull_pw}".encode()).decode()
    dockerconfig = '{"auths":{"zot.master.local":{"auth":"' + pull_auth + '"}}}'

    content = f"""#!/bin/bash
# secrets.master — generated by generate-secrets-master.py
# Secrets for the master (local) cluster  *.master.local
#
# FILL IN AFTER DEPLOYMENT:
#   Run:  python3 generate-secrets-master.py --post-deploy
#   (reads idp/argocd/vault/kube .txt files and patches this file automatically)
#
# FILL IN MANUALLY:
#   IMAGE_BUILDER_GIT_CREDENTIALS — replace the <placeholder> PAT tokens

################################################################################
# mongodb
################################################################################
MONGODB_ROOT_PASSWORD="{mongo_root}"
MONGODB_PASSWORD="{mongo_root}"
MONGODB_REPLICA_SET_KEY="{mongo_rs_key}"

################################################################################
# postgresql
################################################################################
POSTGRES_PASSWORD="{pg_pw}"
POSTGRESQL_PASSWORD="{pg_pw}"
POSTGRESQL_REPLICATION_PASSWORD="{pg_repl_pw}"

################################################################################
# postfix
################################################################################
POSTFIX_DKIM_PRIVATE_KEY=$(cat <<'EOF'
{dkim_pem}
EOF
)

################################################################################
# seq
################################################################################
SEQ_ADMIN_PASSWORD="{seq_admin}"
SEQ_API_KEY="{seq_api}"

################################################################################
# dbgate
################################################################################
DBGATE_ADMIN_PASSWORD="{dbgate_admin}"
DBGATE_AUTH="{dbgate_auth}"
DBGATE_MONGODB_PASSWORD="{mongo_root}"
DBGATE_POSTGRESQL_PASSWORD="{pg_pw}"

################################################################################
# observability
################################################################################
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="{grafana_pw}"

################################################################################
# image-builder — replace <placeholder> with your real PAT tokens
################################################################################
IMAGE_BUILDER_GIT_CREDENTIALS=$(cat <<'EOF'
https://pat:<azdo-pat>@dev.azure.com
https://oauth2:<github-pat>@github.com
https://x-token-auth:<bitbucket-app-password>@bitbucket.org
EOF
)
IMAGE_BUILDER_GITHUB_WEBHOOK_SECRET="{gh_webhook}"
IMAGE_BUILDER_BITBUCKET_WEBHOOK_SECRET="{bb_webhook}"
IMAGE_BUILDER_AZUREDEVOPS_WEBHOOK_SECRET="{ado_webhook}"

################################################################################
# idp — auto-filled by:  python3 generate-secrets-master.py --post-deploy
################################################################################
IDP_ADMIN_USER="akadmin"
IDP_BOOTSTRAP_EMAIL="admin@master.local"
IDP_BOOTSTRAP_PASSWORD=""
IDP_SECRET_KEY=""
IDP_POSTGRES_PASSWORD=""
IDP_ARGOCD_CLIENT_SECRET=""
IDP_GRAFANA_CLIENT_SECRET=""
IDP_HEADLAMP_CLIENT_SECRET=""
IDP_VAULT_CLIENT_SECRET=""
IDP_ZOT_CLIENT_SECRET=""

################################################################################
# registry
################################################################################
REGISTRY_PUSH_USER="push-user"
REGISTRY_PUSH_PASSWORD="{reg_push_pw}"
REGISTRY_PULL_USER="pull-user"
REGISTRY_PULL_PASSWORD="{reg_pull_pw}"
REGISTRY_ADMIN_USER="admin"
REGISTRY_ADMIN_PASSWORD="{reg_admin_pw}"
REGISTRY_HTPASSWD=$(cat <<'EOF'
{registry_htpasswd}
EOF
)
REGISTRY_PULL_DOCKERCONFIGJSON='{dockerconfig}'

################################################################################
# objectstore
################################################################################
OBJECTSTORE_GARAGE_RPC_SECRET="{garage_rpc}"
OBJECTSTORE_GARAGE_ADMIN_TOKEN="{garage_admin}"
OBJECTSTORE_S3_ACCESS_KEY_ID="{s3_key_id}"
OBJECTSTORE_S3_SECRET_ACCESS_KEY="{s3_secret}"
OBJECTSTORE_FILESTASH_ADMIN_PASSWORD="{filestash_pw}"
OBJECTSTORE_FILESTASH_ADMIN_PASSWORD_HASH="{filestash_hash}"
OBJECTSTORE_FILESTASH_CONFIG_SECRET="{filestash_cfg}"

################################################################################
# argocd — auto-filled by:  python3 generate-secrets-master.py --post-deploy
################################################################################
ARGOCD_ADMIN_PASSWORD=""

################################################################################
# kube — auto-filled by:  python3 generate-secrets-master.py --post-deploy
################################################################################
KUBE_DASHBOARD_TOKEN=""

################################################################################
# vault — auto-filled by:  python3 generate-secrets-master.py --post-deploy
################################################################################
VAULT_ROOT_TOKEN=""
VAULT_UNSEAL_KEY_1=""
VAULT_UNSEAL_KEY_2=""
VAULT_UNSEAL_KEY_3=""
VAULT_UNSEAL_KEY_4=""
VAULT_UNSEAL_KEY_5=""

################################################################################
# fleet tenant
################################################################################
FLEET_JWT_SECRET="{fleet_jwt}"
FLEET_TRACCAR_APP_PASSWORD="{fleet_traccar}"
FLEET_APP_PASSWORD="{fleet_app}"
FLEET_TRACCAR_FORWARDER_SECRET="{fleet_fwd}"

################################################################################
# SCHEMA — DO NOT EDIT
################################################################################
VAULT_SCHEMA=(
  "MONGODB_ROOT_PASSWORD|app|mongodb|mongodb-root-password"
  "MONGODB_PASSWORD|app|mongodb|mongodb-password"
  "MONGODB_REPLICA_SET_KEY|app|mongodb|mongodb-replica-set-key"

  "POSTGRES_PASSWORD|app|postgresql|postgres-password"
  "POSTGRESQL_PASSWORD|app|postgresql|password"
  "POSTGRESQL_REPLICATION_PASSWORD|app|postgresql|replication-password"

  "POSTFIX_DKIM_PRIVATE_KEY|app|postfix|dkim-private-key"

  "SEQ_ADMIN_PASSWORD|app|seq|admin-password"
  "SEQ_API_KEY|app|seq|api-key"

  "DBGATE_AUTH|app|dbgate|auth"
  "DBGATE_ADMIN_PASSWORD|app|dbgate|admin-password"
  "DBGATE_MONGODB_PASSWORD|app|dbgate|mongodb-password"
  "DBGATE_POSTGRESQL_PASSWORD|app|dbgate|postgresql-password"

  "GRAFANA_ADMIN_USER|app|observability|admin-user"
  "GRAFANA_ADMIN_PASSWORD|app|observability|grafana-admin-password"

  "IMAGE_BUILDER_GIT_CREDENTIALS|app|image-builder|gitcredentials"
  "IMAGE_BUILDER_GITHUB_WEBHOOK_SECRET|app|image-builder|github-webhook-secret"
  "IMAGE_BUILDER_BITBUCKET_WEBHOOK_SECRET|app|image-builder|bitbucket-webhook-secret"
  "IMAGE_BUILDER_AZUREDEVOPS_WEBHOOK_SECRET|app|image-builder|azuredevops-webhook-secret"

  "IDP_ADMIN_USER|system|idp|admin-user"
  "IDP_BOOTSTRAP_EMAIL|system|idp|bootstrap-email"
  "IDP_BOOTSTRAP_PASSWORD|system|idp|bootstrap-password"
  "IDP_SECRET_KEY|system|idp|secret-key"
  "IDP_POSTGRES_PASSWORD|system|idp|postgres-password"
  "IDP_ARGOCD_CLIENT_SECRET|system|idp|argocd-client-secret"
  "IDP_GRAFANA_CLIENT_SECRET|system|idp|grafana-client-secret"
  "IDP_HEADLAMP_CLIENT_SECRET|system|idp|headlamp-client-secret"
  "IDP_VAULT_CLIENT_SECRET|system|idp|vault-client-secret"
  "IDP_ZOT_CLIENT_SECRET|system|idp|zot-client-secret"

  "REGISTRY_PUSH_USER|app|registry|push-user"
  "REGISTRY_PUSH_PASSWORD|app|registry|push-password"
  "REGISTRY_PULL_USER|app|registry|pull-user"
  "REGISTRY_PULL_PASSWORD|app|registry|pull-password"
  "REGISTRY_ADMIN_USER|app|registry|admin-user"
  "REGISTRY_ADMIN_PASSWORD|app|registry|admin-password"
  "REGISTRY_HTPASSWD|app|registry|htpasswd"
  "REGISTRY_PULL_DOCKERCONFIGJSON|app|registry|pull-dockerconfigjson"

  "OBJECTSTORE_GARAGE_RPC_SECRET|app|objectstore|rpc-secret"
  "OBJECTSTORE_GARAGE_ADMIN_TOKEN|app|objectstore|admin-token"
  "OBJECTSTORE_S3_ACCESS_KEY_ID|app|objectstore|access-key-id"
  "OBJECTSTORE_S3_SECRET_ACCESS_KEY|app|objectstore|secret-access-key"
  "OBJECTSTORE_FILESTASH_ADMIN_PASSWORD|app|objectstore|filestash-admin-password"
  "OBJECTSTORE_FILESTASH_ADMIN_PASSWORD_HASH|app|objectstore|filestash-admin-password-hash"
  "OBJECTSTORE_FILESTASH_CONFIG_SECRET|app|objectstore|filestash-config-secret"

  "FLEET_JWT_SECRET|app|fleet|jwt-secret"
  "FLEET_TRACCAR_APP_PASSWORD|app|fleet|traccar-app-password"
  "FLEET_APP_PASSWORD|app|fleet|fleet-app-password"
  "FLEET_TRACCAR_FORWARDER_SECRET|app|fleet|traccar-forwarder-secret"

  "ARGOCD_ADMIN_PASSWORD|system|argocd|admin-password"
  "KUBE_DASHBOARD_TOKEN|system|kube|dashboard-token"
  "VAULT_ROOT_TOKEN|system|vault|root-token"
  "VAULT_UNSEAL_KEY_1|system|vault|unseal-key-1"
  "VAULT_UNSEAL_KEY_2|system|vault|unseal-key-2"
  "VAULT_UNSEAL_KEY_3|system|vault|unseal-key-3"
  "VAULT_UNSEAL_KEY_4|system|vault|unseal-key-4"
  "VAULT_UNSEAL_KEY_5|system|vault|unseal-key-5"
)
"""

    os.makedirs("secrets", exist_ok=True)
    with open(SECRETS_FILE, "w") as f:
        f.write(content)

    print(f"✓ {SECRETS_FILE} written")
    print()
    print("Passwords to note (save somewhere safe):")
    print(f"  Grafana admin:    {grafana_pw}")
    print(f"  DBGate admin:     {dbgate_admin}")
    print(f"  Seq admin:        {seq_admin}")
    print(f"  Filestash admin:  {filestash_pw}")
    print(f"  Zot admin:        {reg_admin_pw}")
    print()
    print("Next: run the installer steps, then after --deploy-all run:")
    print("  python3 generate-secrets-master.py --post-deploy")


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if "--post-deploy" in sys.argv:
        post_deploy()
    else:
        generate()
