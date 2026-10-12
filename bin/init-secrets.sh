#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets

generate() {
  local name=$1 value=$2
  if [[ -s secrets/$name ]]; then
    echo "keep secrets/$name"
  else
    printf '%s' "$value" > "secrets/$name"
    echo "created secrets/$name"
  fi
}

random() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

generate MYSQL_APP_ROOT_PASSWORD "$(random 32)"
generate MYSQL_APP_USER_PASSWORD "$(random 32)"
generate MYSQL_KEYCLOAK_ROOT_PASSWORD "$(random 32)"
generate MYSQL_KEYCLOAK_USER_PASSWORD "$(random 32)"
generate KEYCLOAK_ADMIN_PASSWORD "$(random 24)"
generate APP_KEYCLOAK_ADMIN_CLIENT_SECRET "$(random 32)"
generate APP_KEYCLOAK_CLIENT_CLIENT_SECRET "$(random 32)"
generate APP_SECRET_KEY "$(random 32)"
generate WEB_AUTH_SECRET "$(random 48)"
generate SAMPLE_USER_PASSWORD "$(random 16)"

if [[ ! -s secrets/cloudflared.env ]]; then
  printf 'TUNNEL_TOKEN=\n' > secrets/cloudflared.env
  echo "created secrets/cloudflared.env (paste the tunnel token into it)"
fi

chmod 700 secrets
find secrets -maxdepth 1 -type f ! -name '*.env' -exec chmod 644 {} +
chmod 600 secrets/*.env
