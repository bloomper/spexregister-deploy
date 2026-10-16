#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
. ./.env
set +a

kcadm() { docker compose exec -T auth /opt/keycloak/bin/kcadm.sh "$@"; }
client_uuid() { kcadm get clients -r "$API_AUTH_REALM" -q clientId="$1" --fields id --format csv --noquotes | tr -d '\r'; }

kcadm config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user "$AUTH_ADMIN" \
  --password "$(cat secrets/AUTH_ADMIN_PASSWORD)"

kcadm update "clients/$(client_uuid "$API_AUTH_ADMIN_CLIENT_ID")" -r "$API_AUTH_REALM" \
  -s "secret=$(cat secrets/API_AUTH_ADMIN_CLIENT_SECRET)"
echo "updated $API_AUTH_ADMIN_CLIENT_ID secret"

kcadm update "clients/$(client_uuid "$API_AUTH_CLIENT_CLIENT_ID")" -r "$API_AUTH_REALM" \
  -s "secret=$(cat secrets/API_AUTH_CLIENT_CLIENT_SECRET)"
echo "updated $API_AUTH_CLIENT_CLIENT_ID secret"

if [[ -n "${AUTH_THEME:-}" ]]; then
  kcadm update "realms/$API_AUTH_REALM" -s "loginTheme=$AUTH_THEME" -s "accountTheme=$AUTH_THEME" -s "emailTheme=$AUTH_THEME"
  echo "updated login, account and email theme to $AUTH_THEME"
fi

smtp=(
  -s "smtpServer.host=$SMTP_HOST"
  -s "smtpServer.port=$SMTP_PORT"
  -s "smtpServer.from=$MAIL_FROM"
  -s "smtpServer.auth=${SMTP_AUTH:-false}"
  -s "smtpServer.user=${SMTP_USER:-}"
  -s "smtpServer.starttls=${SMTP_STARTTLS:-false}"
  -s "smtpServer.ssl=${SMTP_SSL:-false}"
)
if [[ -s secrets/SMTP_PASSWORD ]]; then
  smtp+=(-s "smtpServer.password=$(cat secrets/SMTP_PASSWORD)")
fi
kcadm update "realms/$API_AUTH_REALM" "${smtp[@]}"
echo "updated mail settings ($SMTP_HOST:$SMTP_PORT)"
