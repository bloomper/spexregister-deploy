#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets

infra_deploy=${INFRA_DEPLOY:-../fgv-infra-deploy}

generate() {
  local name=$1 value=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  else
    printf '%s' "$value" > "secrets/$name"
    echo "created secrets/$name"
  fi
}

# Client secrets are made by fgv-infra-deploy, which sets them in the realm
copy_client_secret() {
  local name=$1 client=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  elif [[ -s $infra_deploy/secrets/clients/$client ]]; then
    cp "$infra_deploy/secrets/clients/$client" "secrets/$name"
    echo "copied secrets/$name from $infra_deploy"
  else
    echo "missing secrets/$name: run bin/init-secrets.sh in fgv-infra-deploy first, or set INFRA_DEPLOY" >&2
  fi
}

random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

generate MYSQL_ROOT_PASSWORD "$(random 32)"
generate MYSQL_USER_PASSWORD "$(random 32)"
copy_client_secret KEYCLOAK_ADMIN_CLIENT_SECRET fgv-admin
copy_client_secret KEYCLOAK_CLIENT_SECRET spexregister
generate API_SECRET_KEY "$(random 32)"
generate WEB_AUTH_SECRET "$(random 48)"
generate SAMPLE_USER_PASSWORD "$(random 16)"

if [[ ! -e secrets/SMTP_PASSWORD ]]; then
  : > secrets/SMTP_PASSWORD
  echo "created secrets/SMTP_PASSWORD (empty, write the SMTP password into it if the relay needs one)"
fi

if [[ ! -s secrets/cloudflared.env ]]; then
  printf 'TUNNEL_TOKEN=\n' > secrets/cloudflared.env
  echo "created secrets/cloudflared.env (paste the tunnel token into it)"
fi

chmod 700 secrets
find secrets -maxdepth 1 -type f ! -name '*.env' -exec chmod 644 {} +
chmod 600 secrets/*.env
